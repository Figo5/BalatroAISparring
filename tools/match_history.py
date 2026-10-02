#!/usr/bin/env python3
"""Read-only match history and post-match review over practice session logs.

Scans the practice host's session workspaces (default
``work/aisparring-host/sessions/<session>/``) and reads, never writes:

* ``host.json``              the host's session report (phase, code, hand-off timings)
* ``logs/summary.jsonl``     the terminal match summary written by the service
* ``logs/decisions.jsonl``   one row per AI policy decision
* ``logs/results.jsonl``     one row per AI decision result (accepted/rejected)
* ``logs/handoff.jsonl``     hand-off stage timings

Commands::

    python tools/match_history.py                    # table of matches + per-difficulty totals
    python tools/match_history.py --json             # the same as JSON
    python tools/match_history.py review <session>   # one match: phases, actions, latency, rejects

Nothing here launches or touches Balatro, the live install, Mods or saves. Files
larger than ``MAX_FILE_BYTES`` and malformed JSON lines are skipped and counted.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable, Optional

REPO = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO / "work" / "aisparring-host" / "sessions"
MAX_FILE_BYTES = 64 * 1024 * 1024
DIFFICULTY_ORDER = ("rookie", "competitive", "major_league", "expert")

# Tarot review bounds. Only the ten hand-targeted Tarots the service logs about
# are surfaced; refs stay primitive positional strings; the detail list is
# capped so a review output cannot grow without limit.
TAROT_CENTERS = (
    "c_strength", "c_death", "c_lovers", "c_chariot", "c_justice",
    "c_devil", "c_star", "c_moon", "c_sun", "c_world",
)
TAROT_ROWS = 200
TAROT_MAX_TARGETS = 2
TEXT_MAX_CHARS = 64
SEQUENCE_MAX = 2147483647
TIMESTAMP_MAX = 1e11


PARSE_ERRORS = (ValueError, RecursionError)


def _readable(path: Path) -> bool:
    try:
        return path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_FILE_BYTES
    except OSError:
        return False


def read_jsonl(path: Path) -> tuple[list, int]:
    """Rows of a JSONL file and the number of skipped (malformed) lines."""
    if not _readable(path):
        return [], 0
    rows, skipped = [], 0
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    value = json.loads(line)
                except PARSE_ERRORS:
                    skipped += 1
                    continue
                if isinstance(value, dict):
                    rows.append(value)
                else:
                    skipped += 1
    except OSError:
        return rows, skipped
    return rows, skipped


def read_json(path: Path) -> Optional[dict]:
    if not _readable(path):
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, *PARSE_ERRORS):
        return None
    return value if isinstance(value, dict) else None


def _number(value) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def percentile(values: list, fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * (len(ordered) - 1) + 0.5))]


def handoff_seconds(report: Optional[dict]) -> Optional[float]:
    """Seconds from the live game's exit to both staged roles being launched."""
    timings = (report or {}).get("timings")
    stages = timings.get("stages") if isinstance(timings, dict) else None
    if not isinstance(stages, list):
        return None
    marks = {entry.get("stage"): _number(entry.get("start")) for entry in stages if isinstance(entry, dict)}
    start, end = marks.get("live_exited"), marks.get("roles_launched")
    if start is None or end is None or end < start:
        return None
    return round(end - start, 3)


def match_record(session_dir: Path) -> Optional[dict]:
    logs = session_dir / "logs"
    report = read_json(session_dir / "host.json")
    summaries, _ = read_jsonl(logs / "summary.jsonl")
    decisions, bad_decisions = read_jsonl(logs / "decisions.jsonl")
    if report is None and not summaries and not decisions:
        return None
    summary = summaries[-1] if summaries else {}
    difficulty = summary.get("difficulty") or next(
        (row.get("difficulty") for row in decisions if row.get("difficulty")), None
    )
    return {
        "session": session_dir.name,
        "timestamp": _number(summary.get("timestamp")),
        "difficulty": difficulty,
        "seed": summary.get("seed"),
        "result": summary.get("result"),
        "reason": summary.get("reason"),
        "ante": summary.get("ante"),
        "round": summary.get("round"),
        "human_lives": summary.get("human_lives"),
        "ai_lives": summary.get("ai_lives"),
        "duration_seconds": _number(summary.get("duration_seconds")),
        "decisions": summary.get("decisions") if summary else len(decisions),
        "rejected": summary.get("rejected"),
        "errors": summary.get("errors"),
        "no_action": summary.get("no_action"),
        # H3/M2: `rejected` is only comparable within one counter version. Version-2
        # counts a refused decision once per delivered sequence; version-1 (or a
        # missing field) is the historical idle-inflated number. The AI's real
        # loop metrics are kept under `ai_loop_*`; the generic `loop_*` fields are
        # deliberately not carried (the human runtime has no decision loop).
        "counter_version": summary.get("counter_version"),
        "human_counter_version": summary.get("human_counter_version"),
        "ai_rejected": summary.get("ai_rejected"),
        "ai_counter_version": summary.get("ai_counter_version"),
        "ai_loop_idle": summary.get("ai_loop_idle"),
        "ai_loop_transient": summary.get("ai_loop_transient"),
        "ai_loop_empty": summary.get("ai_loop_empty"),
        "ai_loop_no_action": summary.get("ai_loop_no_action"),
        "ai_loop_waits": summary.get("ai_loop_waits"),
        "host_phase": (report or {}).get("phase"),
        "host_code": (report or {}).get("code"),
        "handoff_seconds": handoff_seconds(report),
        "malformed_lines": bad_decisions,
    }


def is_session_dir(root: Path, path: Path) -> bool:
    """A real session workspace directly under ``root``: not a symlink and not
    a Windows junction or any other link that resolves elsewhere. The listing
    and ``review`` share this rule."""
    try:
        if not path.is_dir() or path.is_symlink():
            return False
        is_junction = getattr(path, "is_junction", None)
        if is_junction is not None and is_junction():
            return False
        return path.resolve().parent == root.resolve()
    except OSError:
        return False


def iter_sessions(root: Path) -> Iterable[Path]:
    if not root.is_dir():
        return []
    try:
        children = list(root.iterdir())
    except OSError:
        return []
    return sorted((c for c in children if is_session_dir(root, c)), key=lambda p: p.name)


def history(root: Path) -> dict:
    matches = [record for record in (match_record(path) for path in iter_sessions(root)) if record]
    matches.sort(key=lambda m: (m["timestamp"] is None, m["timestamp"] or 0, m["session"]))
    totals: dict = {}
    for match in matches:
        key = match["difficulty"] or "unknown"
        entry = totals.setdefault(key, {"matches": 0, "ai_wins": 0, "human_wins": 0, "other": 0, "antes": [], "errors": 0})
        entry["matches"] += 1
        if match["result"] == "ai_win":
            entry["ai_wins"] += 1
        elif match["result"] == "human_win":
            entry["human_wins"] += 1
        else:
            entry["other"] += 1
        if isinstance(match["ante"], int):
            entry["antes"].append(match["ante"])
        if isinstance(match["errors"], int):
            entry["errors"] += match["errors"]
    for entry in totals.values():
        antes = entry.pop("antes")
        decided = entry["ai_wins"] + entry["human_wins"]
        entry["ai_win_rate"] = round(entry["ai_wins"] / decided, 3) if decided else None
        entry["mean_ante"] = round(statistics.mean(antes), 2) if antes else None
    return {"root": str(root), "matches": matches, "by_difficulty": totals}


def _bounded_text(value, limit: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    cleaned = value.replace("\r", " ").replace("\n", " ")
    return cleaned[:limit] or None


def _bounded_number(value, high: float) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except (OverflowError, ValueError, TypeError):
        return None
    if not math.isfinite(number) or number < 0 or number > high:
        return None
    return number


def _sequence(value) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < 1 or value > SEQUENCE_MAX:
        return None
    return value


def _positional_ref(value, prefix: str) -> Optional[str]:
    if not isinstance(value, str):
        return None
    head, sep, tail = value.partition(":")
    if sep != ":" or head != prefix:
        return None
    if not (1 <= len(tail) <= 3) or not tail.isascii() or not tail.isdigit():
        return None
    if tail.startswith("0"):
        return None
    return value


def _foreign_session(row: dict, session_name: str) -> bool:
    declared = row.get("session")
    return declared is not None and declared != session_name


def _receipt_index(results: Iterable[dict], session_name: str) -> tuple[Counter, dict]:
    """In-session result rows by sequence, counted before payload validation.

    ``occurrences`` counts every row that declares a valid sequence, even one
    whose ``accepted``/``code`` payload is malformed, so a bad row cannot make a
    duplicated sequence look unique. ``receipts`` holds only structurally valid
    payloads.
    """
    occurrences: Counter = Counter()
    receipts: dict = {}
    for row in results:
        if not isinstance(row, dict) or _foreign_session(row, session_name):
            continue
        sequence = _sequence(row.get("sequence"))
        if sequence is None:
            continue
        occurrences[sequence] += 1
        code = _bounded_text(row.get("code"), TEXT_MAX_CHARS)
        accepted = row.get("accepted")
        if isinstance(accepted, bool) and code is not None:
            receipts.setdefault(sequence, []).append({"accepted": accepted, "code": code})
    return occurrences, receipts


def tarot_selection(decisions: Iterable[dict], results: Iterable[dict], session_name: str = "") -> dict:
    """Bounded, allowlisted evidence for hand-targeted Tarot uses.

    Only reads what the service already logged: a decision's ``action``
    (``tarot``, ``source_ref``, ordered ``card_refs``) and the broker receipt
    whose ``result.sequence`` equals the decision's ``tick`` (the decision
    sequence). ``result.tick`` is the runtime tick and is never a join key.

    A receipt is broker acceptance/commit only. It is not proof of an engine
    effect or of highlight cleanup - that evidence lives in the native/runtime
    event log and in human validation.

    ``receipt_status`` is ``matched`` only for a decision sequence used exactly
    once and a single structurally valid receipt at that sequence. A sequence
    used by more than one decision, or with more than one result row (even one
    of them malformed), is ``ambiguous``. No result row is ``absent``. A single
    result row whose payload cannot be read is ``invalid``. A decision row with
    no usable sequence is ``invalid``. None of these is guessed.
    """
    in_session = [row for row in decisions if isinstance(row, dict) and not _foreign_session(row, session_name)]
    occurrences, receipts = _receipt_index(results, session_name)
    sequence_uses: Counter = Counter(
        sequence for sequence in (_sequence(row.get("tick")) for row in in_session) if sequence is not None
    )

    centers: Counter = Counter()
    tally: Counter = Counter()
    rows: list = []
    uses = 0
    for row in in_session:
        action = row.get("action")
        if not isinstance(action, dict) or action.get("type") != "USE_CONSUMABLE_ON_HAND":
            continue
        center = action.get("tarot")
        if not isinstance(center, str) or center not in TAROT_CENTERS:
            continue
        uses += 1
        centers[center] += 1
        sequence = _sequence(row.get("tick"))
        if sequence is None or sequence_uses[sequence] > 1:
            status, receipt = ("invalid" if sequence is None else "ambiguous"), None
        elif occurrences.get(sequence, 0) == 0:
            status, receipt = "absent", None
        elif occurrences[sequence] > 1:
            status, receipt = "ambiguous", None
        else:
            unique = receipts.get(sequence)
            status, receipt = ("matched", unique[0]) if unique else ("invalid", None)
        tally[status] += 1
        if len(rows) >= TAROT_ROWS:
            continue
        valid_refs = []
        refs = action.get("card_refs")
        if isinstance(refs, list):
            valid_refs = [ref for ref in (_positional_ref(value, "hand") for value in refs) if ref]
        targets = valid_refs[:TAROT_MAX_TARGETS]
        difficulty = row.get("difficulty")
        rows.append({
            "sequence": sequence,
            "timestamp": _bounded_number(row.get("timestamp"), TIMESTAMP_MAX),
            "phase": _bounded_text(row.get("phase"), TEXT_MAX_CHARS),
            "difficulty": difficulty if difficulty in DIFFICULTY_ORDER else None,
            "center": center,
            "source_ref": _positional_ref(action.get("source_ref"), "consumable"),
            "card_refs": targets,
            "targets": len(targets),
            "targets_truncated": len(valid_refs) > TAROT_MAX_TARGETS,
            "broker_accepted": receipt["accepted"] if receipt else None,
            "broker_code": receipt["code"] if receipt else None,
            "receipt_status": status,
        })
    return {
        "centers": dict(centers.most_common()),
        "uses": uses,
        "rows": rows,
        "rows_truncated": uses > len(rows),
        "receipts": {key: tally.get(key, 0) for key in ("matched", "absent", "ambiguous", "invalid")},
    }


def review(session_dir: Path) -> dict:
    """Post-match review foundations for one session."""
    logs = session_dir / "logs"
    decisions, bad = read_jsonl(logs / "decisions.jsonl")
    results, bad_results = read_jsonl(logs / "results.jsonl")
    phases, actions, reasons = Counter(), Counter(), Counter()
    latencies = []
    # Terminal abort rows (reason=code, errors=code, no phase or action) are
    # counted separately, not as policy decisions.
    aborts = [row for row in decisions if row.get("phase") is None and row.get("action") is None
              and isinstance(row.get("errors"), str)]
    abort_ids = {id(row) for row in aborts}
    decisions = [row for row in decisions if id(row) not in abort_ids]
    for row in decisions:
        if row.get("phase"):
            phases[str(row["phase"])] += 1
        action = row.get("action")
        if isinstance(action, dict) and action.get("type"):
            actions[str(action["type"])] += 1
        if row.get("reason"):
            reasons[str(row["reason"])] += 1
        latency = _number(row.get("latency"))
        if latency is not None:
            latencies.append(latency)
    rejected = Counter(
        str(row.get("code")) for row in results if row.get("accepted") is False and row.get("code")
    )
    handoff, _ = read_jsonl(logs / "handoff.jsonl")
    slowest = sorted(
        (entry for entry in handoff if not entry.get("milestone") and _number(entry.get("seconds")) is not None),
        key=lambda entry: -float(entry["seconds"]),
    )[:5]
    record = match_record(session_dir) or {"session": session_dir.name}
    return_value = {
        "match": record,
        "decisions": len(decisions),
        "aborts": [str(row.get("errors")) for row in aborts],
        "phases": dict(phases.most_common()),
        "actions": dict(actions.most_common()),
        "reasons": dict(reasons.most_common(10)),
        "timer_presses": actions.get("START_TIMER", 0),
        "policy_latency": {
            "p50": percentile(latencies, 0.5),
            "p95": percentile(latencies, 0.95),
            "max": max(latencies) if latencies else None,
        },
        "rejected_codes": dict(rejected.most_common()),
        "handoff_slowest": [{"stage": e.get("stage"), "seconds": e.get("seconds")} for e in slowest],
        "malformed_lines": bad + bad_results,
        "ui_check": ui_check(decisions),
        "tarot_selection": tarot_selection(decisions, results, session_dir.name),
    }
    return return_value


UI_ROWS = 200


def ui_check(decisions) -> dict:
    """LV-7 evidence: the AI's logged UI-visible play facts (`ui`, written by
    the practice service) to compare with screenshots, plus the large-hand and
    budget checks the queue asks for."""
    rows = []
    budget_errors = 0
    large = 0
    max_hand = None
    by_size = {}
    for row in decisions:
        if row.get("errors") == "policy_budget_exceeded" or row.get("reason") == "policy_budget_exceeded":
            budget_errors += 1
        ui = row.get("ui")
        if not isinstance(ui, dict):
            continue
        size = ui.get("hand_size")
        if isinstance(size, int) and not isinstance(size, bool):
            max_hand = size if max_hand is None else max(max_hand, size)
            if size >= 10:
                large += 1
            latency = _number(row.get("latency"))
            if latency is not None:
                by_size.setdefault("10+" if size >= 10 else "<=9", []).append(latency)
        if len(rows) < UI_ROWS:
            rows.append({
                "tick": row.get("tick"),
                "phase": row.get("phase"),
                "hand_size": size,
                "blind_requirement": ui.get("blind_requirement"),
                "current_score": ui.get("current_score"),
                "hand_levels": ui.get("hand_levels"),
            })
    return {
        "budget_errors": budget_errors,
        "decisions_with_10_plus_cards": large,
        "max_hand_size": max_hand,
        "latency_by_hand_size": {
            key: {"p50": percentile(values, 0.5), "p95": percentile(values, 0.95), "max": max(values)}
            for key, values in sorted(by_size.items())
        },
        "rows": rows,
        "rows_truncated": sum(1 for row in decisions if isinstance(row.get("ui"), dict)) > UI_ROWS,
    }


def _fmt(value, width) -> str:
    text = "-" if value is None else str(value)
    return text[:width].ljust(width)


def print_history(data: dict) -> None:
    matches = data["matches"]
    if not matches:
        print(f"No practice sessions found under {data['root']}")
        return
    header = ("session", "difficulty", "result", "ante", "lives h/ai", "decisions", "errors", "handoff s")
    widths = (27, 12, 10, 5, 10, 9, 6, 9)
    print(" ".join(_fmt(h, w) for h, w in zip(header, widths)))
    for m in matches:
        lives = f"{m['human_lives'] if m['human_lives'] is not None else '-'}/{m['ai_lives'] if m['ai_lives'] is not None else '-'}"
        row = (m["session"], m["difficulty"], m["result"], m["ante"], lives, m["decisions"], m["errors"], m["handoff_seconds"])
        print(" ".join(_fmt(v, w) for v, w in zip(row, widths)))
    print()
    order = [d for d in DIFFICULTY_ORDER if d in data["by_difficulty"]] + sorted(
        d for d in data["by_difficulty"] if d not in DIFFICULTY_ORDER
    )
    for difficulty in order:
        t = data["by_difficulty"][difficulty]
        print(
            f"{difficulty}: {t['matches']} matches, AI {t['ai_wins']} / human {t['human_wins']} / other {t['other']}, "
            f"AI win rate {t['ai_win_rate']}, mean ante {t['mean_ante']}, errors {t['errors']}"
        )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Practice match history and post-match review (read-only).")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="session workspace root")
    parser.add_argument("--json", action="store_true", help="print JSON")
    sub = parser.add_subparsers(dest="command")
    review_parser = sub.add_parser("review", help="review one session")
    review_parser.add_argument("session")
    args = parser.parse_args(argv)
    if args.command == "review":
        session_dir = args.root / args.session
        if not is_session_dir(args.root, session_dir):
            print(f"unknown session: {args.session}", file=sys.stderr)
            return 2
        print(json.dumps(review(session_dir), indent=2, sort_keys=True, default=str))
        return 0
    data = history(args.root)
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True, default=str))
    else:
        print_history(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
