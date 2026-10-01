#!/usr/bin/env python3
"""Synthetic-session tests for tools/match_history.py (read-only aggregator)."""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

import match_history  # noqa: E402


def write_session(root: Path, name: str, *, difficulty, result, ante, errors=0, decisions=(), results=(),
                  timestamp=1.0, host=None, handoff=(), extra_lines=()):
    session = root / name
    logs = session / "logs"
    logs.mkdir(parents=True)
    summary = {
        "timestamp": timestamp, "session": name, "difficulty": difficulty, "result": result, "ante": ante,
        "round": 3, "human_lives": 2, "ai_lives": 0 if result == "human_win" else 1, "decisions": len(decisions),
        "rejected": 0, "errors": errors, "no_action": 1, "seed": None,
    }
    (logs / "summary.jsonl").write_text(json.dumps(summary) + "\n", encoding="utf-8")
    lines = [json.dumps(row) for row in decisions] + list(extra_lines)
    (logs / "decisions.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (logs / "results.jsonl").write_text("\n".join(json.dumps(r) for r in results) + "\n", encoding="utf-8")
    (logs / "handoff.jsonl").write_text("\n".join(json.dumps(r) for r in handoff) + "\n", encoding="utf-8")
    if host is not None:
        (session / "host.json").write_text(json.dumps(host), encoding="utf-8")
    return session


def decision_row(tick, *, action=None, phase="PLAY_HAND", difficulty="major_league", session="s-tarot",
                 timestamp=1.0, reason="practice_ok", latency=0.01, errors=None):
    """One row shaped like practice_service's LocalLogger.log_decision output."""
    return {
        "timestamp": timestamp, "tick": tick, "session": session, "ruleset": "practice",
        "difficulty": difficulty, "phase": phase, "hash": "0" * 16, "legalcount": 12,
        "action": action, "reason": reason, "latency": latency, "version": "1",
        "errors": errors, "seed": None, "ui": None,
    }


def result_row(sequence, *, accepted, code, tick=0, session="s-tarot", timestamp=1.0, difficulty="major_league"):
    """One row shaped like practice_service's LocalLogger.log_result output."""
    return {
        "timestamp": timestamp, "session": session, "ruleset": "practice", "difficulty": difficulty,
        "sequence": sequence, "accepted": accepted, "code": code, "version_id": None,
        "tick": tick, "reason": None, "seed": None, "version": "1",
    }


def tarot_action(center="c_death", source_ref="consumable:1", refs=("hand:4", "hand:2")):
    return {
        "type": "USE_CONSUMABLE_ON_HAND", "cards": len(refs), "card_refs": list(refs),
        "source_ref": source_ref, "tarot": center,
    }


def test_history_aggregates_by_difficulty():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-a", difficulty="rookie", result="human_win", ante=3, timestamp=2.0)
        write_session(root, "s-b", difficulty="rookie", result="ai_win", ante=5, errors=1, timestamp=1.0)
        write_session(root, "s-c", difficulty="expert", result="aborted", ante=None, timestamp=3.0)
        (root / "not-a-session.txt").write_text("x", encoding="utf-8")
        (root / "empty").mkdir()
        data = match_history.history(root)
        assert [m["session"] for m in data["matches"]] == ["s-b", "s-a", "s-c"], data["matches"]
        rookie = data["by_difficulty"]["rookie"]
        assert rookie["matches"] == 2 and rookie["ai_wins"] == 1 and rookie["human_wins"] == 1
        assert rookie["ai_win_rate"] == 0.5 and rookie["mean_ante"] == 4.0 and rookie["errors"] == 1
        expert = data["by_difficulty"]["expert"]
        assert expert["other"] == 1 and expert["ai_win_rate"] is None


def test_review_counts_phases_actions_latency_and_rejections():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        decisions = [
            {"phase": "PLAY_HAND", "action": {"type": "PLAY_CARDS"}, "latency": 0.01, "reason": "practice_ok"},
            {"phase": "PLAY_HAND", "action": {"type": "DISCARD_CARDS"}, "latency": 0.03, "reason": "practice_ok"},
            {"phase": "BLIND_SELECTION", "action": {"type": "START_TIMER"}, "latency": 0.02, "reason": "practice_ok"},
            {"phase": "SHOP", "action": None, "reason": "policy_no_action", "latency": 0.5},
            {"phase": None, "action": None, "reason": "service_aborted", "errors": "service_aborted"},
        ]
        results = [
            {"accepted": True, "code": "broker_ok"},
            {"accepted": False, "code": "broker_stale_epoch"},
            {"accepted": False, "code": "broker_stale_epoch"},
        ]
        host = {
            "phase": "completed", "code": "practice_host_ok",
            "timings": {"stages": [
                {"stage": "live_exited", "start": 10.0, "seconds": 0.0, "milestone": True},
                {"stage": "baseline_backup", "start": 12.0, "seconds": 95.5},
                {"stage": "roles_launched", "start": 190.25, "seconds": 0.0, "milestone": True},
            ]},
        }
        handoff = [
            {"stage": "baseline_backup", "seconds": 95.5},
            {"stage": "gate_certificate", "seconds": 20.0},
            {"stage": "live_exited", "seconds": 0.0, "milestone": True},
        ]
        write_session(root, "s-r", difficulty="major_league", result="ai_win", ante=6, decisions=decisions,
                      results=results, host=host, handoff=handoff, extra_lines=["{not json"])
        report = match_history.review(root / "s-r")
        assert report["decisions"] == 4
        assert report["aborts"] == ["service_aborted"]
        assert report["phases"] == {"PLAY_HAND": 2, "BLIND_SELECTION": 1, "SHOP": 1}
        assert report["actions"]["START_TIMER"] == 1 and report["timer_presses"] == 1
        assert report["rejected_codes"] == {"broker_stale_epoch": 2}
        assert report["policy_latency"]["max"] == 0.5
        assert report["handoff_slowest"][0] == {"stage": "baseline_backup", "seconds": 95.5}
        assert report["malformed_lines"] == 1
        assert report["match"]["handoff_seconds"] == 180.25
        assert report["match"]["host_code"] == "practice_host_ok"


def test_cli_rejects_paths_outside_the_root_and_reports_empty():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "sessions"
        root.mkdir()
        assert match_history.main(["--root", str(root), "review", "../etc"]) == 2
        assert match_history.main(["--root", str(root)]) == 0
        assert match_history.main(["--root", str(root / "missing"), "--json"]) == 0


def test_bad_host_timings_and_symlinked_sessions_are_tolerated():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "sessions"
        root.mkdir()
        write_session(root, "s-odd", difficulty="rookie", result="ai_win", ante=2,
                      host={"phase": "completed", "timings": ["not", "a", "dict"]})
        write_session(root, "s-odd2", difficulty="rookie", result="ai_win", ante=2,
                      host={"phase": "completed", "timings": {"stages": "nope"}})
        outside = write_session(Path(tmp), "outside", difficulty="expert", result="ai_win", ante=9)
        try:
            (root / "linked").symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError):
            pass
        data = match_history.history(root)
        assert [m["session"] for m in data["matches"]] == ["s-odd", "s-odd2"], data["matches"]
        assert all(m["handoff_seconds"] is None for m in data["matches"])
        assert match_history.main(["--root", str(root), "review", "linked"]) == 2


def test_review_reports_ui_facts_for_lv7():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        levels = {"pair": [3, 30, 4]}
        decisions = [
            {"tick": 1, "phase": "PLAY_HAND", "action": {"type": "PLAY_CARDS"}, "latency": 0.02, "reason": "practice_ok",
             "ui": {"hand_size": 8, "blind_requirement": "300", "current_score": "0", "hand_levels": levels}},
            {"tick": 2, "phase": "MULTIPLAYER_PVP", "action": {"type": "DISCARD_CARDS"}, "latency": 0.08, "reason": "practice_ok",
             "ui": {"hand_size": 11, "current_score": "120"}},
            {"tick": 3, "phase": "PLAY_HAND", "action": None, "latency": 0.2, "reason": "policy_budget_exceeded",
             "errors": "policy_budget_exceeded", "ui": {"hand_size": 12}},
            {"tick": 4, "phase": "SHOP", "action": {"type": "LEAVE_SHOP"}, "latency": 0.01, "reason": "practice_ok", "ui": None},
        ]
        write_session(root, "s-ui", difficulty="expert", result="ai_win", ante=4, decisions=decisions)
        check = match_history.review(root / "s-ui")["ui_check"]
        assert check["budget_errors"] == 1
        assert check["decisions_with_10_plus_cards"] == 2
        assert check["max_hand_size"] == 12
        assert check["latency_by_hand_size"]["10+"]["max"] == 0.2
        assert check["latency_by_hand_size"]["<=9"]["max"] == 0.02
        assert [r["tick"] for r in check["rows"]] == [1, 2, 3]
        assert check["rows"][0]["hand_levels"] == levels
        assert check["rows"][1]["blind_requirement"] is None
        assert check["rows_truncated"] is False


def test_links_resolving_outside_the_root_are_not_listed():
    # A Windows junction is not a symlink to Python < 3.12; the shared rule
    # also rejects any directory that resolves outside the root.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "sessions"
        outside = Path(tmp) / "elsewhere" / "s9"
        root.mkdir()
        outside.mkdir(parents=True)
        (root / "real").mkdir()
        (root / "linked").symlink_to(outside, target_is_directory=True)
        names = [p.name for p in match_history.iter_sessions(root)]
        assert names == ["real"], names
        assert match_history.is_session_dir(root, root / "real")
        assert not match_history.is_session_dir(root, root / "linked")
        assert not match_history.is_session_dir(root, outside)


def test_oversized_files_are_skipped():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        session = write_session(root, "s-big", difficulty="rookie", result="ai_win", ante=2)
        old = match_history.MAX_FILE_BYTES
        match_history.MAX_FILE_BYTES = 10
        try:
            assert match_history.read_jsonl(session / "logs" / "summary.jsonl") == ([], 0)
        finally:
            match_history.MAX_FILE_BYTES = old


def test_tarot_selection_joins_by_decision_tick_not_result_tick():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        decisions = [decision_row(5, action=tarot_action("c_death", "consumable:1", ("hand:4", "hand:2")))]
        results = [
            result_row(5, accepted=True, code="broker_ok", tick=999),
            result_row(999, accepted=False, code="broker_stale_epoch", tick=5),
        ]
        write_session(root, "s-tarot", difficulty="major_league", result="ai_win", ante=6,
                      decisions=decisions, results=results)
        selection = match_history.review(root / "s-tarot")["tarot_selection"]
        assert selection["uses"] == 1 and selection["centers"] == {"c_death": 1}
        assert selection["rows_truncated"] is False
        row = selection["rows"][0]
        assert row["sequence"] == 5
        assert row["center"] == "c_death"
        assert row["source_ref"] == "consumable:1"
        assert row["card_refs"] == ["hand:4", "hand:2"], "Death targets stay in the logged order"
        assert row["targets"] == 2 and row["targets_truncated"] is False
        assert row["phase"] == "PLAY_HAND" and row["difficulty"] == "major_league" and row["timestamp"] == 1.0
        assert row["receipt_status"] == "matched"
        assert row["broker_accepted"] is True and row["broker_code"] == "broker_ok"
        assert selection["receipts"] == {"matched": 1, "absent": 0, "ambiguous": 0, "invalid": 0}


def test_tarot_selection_reports_declined_receipt_but_never_infers_effect():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        decisions = [decision_row(2, action=tarot_action("c_strength", "consumable:2", ("hand:1",)))]
        results = [result_row(2, accepted=False, code="broker_stale_epoch")]
        write_session(root, "s-tarot", difficulty="expert", result="human_win", ante=2,
                      decisions=decisions, results=results)
        row = match_history.review(root / "s-tarot")["tarot_selection"]["rows"][0]
        assert row["receipt_status"] == "matched"
        assert row["broker_accepted"] is False and row["broker_code"] == "broker_stale_epoch"
        assert "effect" not in row and "highlight" not in row


def test_tarot_selection_missing_duplicate_and_conflicting_receipts_are_not_guessed():
    decisions = [
        decision_row(1, action=tarot_action("c_sun", "consumable:1", ("hand:1",))),
        decision_row(2, action=tarot_action("c_moon", "consumable:1", ("hand:2",))),
        decision_row(3, action=tarot_action("c_star", "consumable:1", ("hand:3",))),
        decision_row(4, action=tarot_action("c_world", "consumable:1", ("hand:5",))),
        decision_row(6, action=tarot_action("c_lovers", "consumable:1", ("hand:6",)), session="elsewhere"),
    ]
    results = [
        result_row(2, accepted=True, code="broker_ok"),
        result_row(2, accepted=True, code="broker_ok"),
        result_row(3, accepted=True, code="broker_ok"),
        result_row(3, accepted=False, code="broker_declined"),
        result_row(4, accepted=True, code="broker_ok", session="elsewhere"),
        result_row(6, accepted=True, code="broker_ok", session="elsewhere"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="competitive", result="ai_win", ante=4,
                      decisions=decisions, results=results)
        selection = match_history.review(root / "s-tarot")["tarot_selection"]
        assert selection["uses"] == 4, "a row declaring another session is not this session's evidence"
        statuses = {row["sequence"]: row["receipt_status"] for row in selection["rows"]}
        assert statuses == {1: "absent", 2: "ambiguous", 3: "ambiguous", 4: "absent"}
        assert selection["receipts"] == {"matched": 0, "absent": 2, "ambiguous": 2, "invalid": 0}
        assert all(row["broker_accepted"] is None for row in selection["rows"])


def test_tarot_selection_rows_are_bounded_and_truncation_is_truthful():
    total = match_history.TAROT_ROWS + 1
    decisions = [decision_row(index + 1, action=tarot_action("c_sun", "consumable:1", ("hand:1",)))
                 for index in range(total)]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=9, decisions=decisions)
        selection = match_history.review(root / "s-tarot")["tarot_selection"]
        assert selection["uses"] == total
        assert selection["centers"] == {"c_sun": total}
        assert len(selection["rows"]) == match_history.TAROT_ROWS == 200
        assert selection["rows_truncated"] is True


def test_tarot_selection_drops_malformed_and_nonprimitive_refs_and_extra_fields():
    action = {
        "type": "USE_CONSUMABLE_ON_HAND", "tarot": "c_sun", "source_ref": "not-a-ref",
        "card_refs": ["hand:2", 7, {"id": "hand:3"}, "hand:", "hand:xx", "consumable:1", "hand:1", "h" * 40],
        "secret": "leak", "table": {"a": 1}, "target_refs": ["nope"], "order": [1, 2],
    }
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3,
                      decisions=[decision_row(1, action=action)])
        row = match_history.review(root / "s-tarot")["tarot_selection"]["rows"][0]
        assert row["card_refs"] == ["hand:2", "hand:1"]
        assert row["targets"] == 2 and row["targets_truncated"] is False
        assert row["source_ref"] is None
        for leaked in ("secret", "table", "target_refs", "order", "cards"):
            assert leaked not in row, leaked
    oversized = tarot_action("c_sun", "consumable:" + "9" * 40, ("hand:1",))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3,
                      decisions=[decision_row(1, action=oversized)])
        row = match_history.review(root / "s-tarot")["tarot_selection"]["rows"][0]
        assert row["source_ref"] is None


def test_tarot_selection_ignores_unsupported_centers_and_tolerates_legacy_rows():
    legacy_action = {"type": "USE_CONSUMABLE_ON_HAND", "source_ref": "consumable:1", "card_refs": ["hand:1"]}
    decisions = [
        decision_row(1, action=tarot_action("c_hanged_man")),
        decision_row(2, action=tarot_action(None)),
        decision_row(3, action=tarot_action("c_mystery")),
        decision_row(4, action=legacy_action),
        decision_row(5, action=tarot_action("c_justice", "consumable:1", ("hand:1",))),
        {"timestamp": 1.0, "tick": 6, "action": "not-a-dict", "phase": "SHOP"},
        {"timestamp": 1.0, "tick": 7},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="major_league", result="ai_win", ante=5,
                      decisions=decisions)
        review = match_history.review(root / "s-tarot")
        selection = review["tarot_selection"]
        assert selection["uses"] == 1 and selection["centers"] == {"c_justice": 1}
        assert len(selection["rows"]) == 1 and selection["rows"][0]["receipt_status"] == "absent"
        assert review["actions"]["USE_CONSUMABLE_ON_HAND"] == 5, "existing action counts are unchanged"


def test_review_is_read_only_for_session_files():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        session = write_session(root, "s-ro", difficulty="rookie", result="ai_win", ante=2,
                                decisions=[decision_row(1, session="s-ro", action=tarot_action("c_death", "consumable:1", ("hand:1", "hand:2")))],
                                results=[result_row(1, accepted=True, code="broker_ok", tick=4, session="s-ro")])
        paths = sorted((session / "logs").glob("*.jsonl"))
        before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        review = match_history.review(session)
        assert review["tarot_selection"]["uses"] == 1
        assert match_history.main(["--root", str(root), "--json"]) == 0
        assert match_history.main(["--root", str(root), "review", "s-ro"]) == 0
        after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        assert before == after and len(before) == 4


def _selection(root, name="s-tarot"):
    return match_history.review(root / name)["tarot_selection"]


def test_tarot_selection_tolerates_malformed_timestamps_without_raising():
    stamps = [10 ** 400, -5.0, float("nan"), float("inf"), float("-inf"), True, None, "1.0", 1.25]
    decisions = []
    for index, stamp in enumerate(stamps, start=1):
        row = decision_row(index, action=tarot_action("c_sun", "consumable:1", ("hand:1",)))
        row["timestamp"] = stamp
        decisions.append(row)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3, decisions=decisions)
        selection = _selection(root)
        assert selection["uses"] == len(stamps)
        assert [row["timestamp"] for row in selection["rows"]] == [None] * (len(stamps) - 1) + [1.25]


def test_tarot_selection_refuses_correlation_when_a_decision_sequence_repeats():
    decisions = [
        decision_row(7, action=tarot_action("c_death", "consumable:1", ("hand:4", "hand:2"))),
        decision_row(7, action=tarot_action("c_death", "consumable:1", ("hand:4", "hand:2"))),
        decision_row(8, action={"type": "PLAY_CARDS", "card_refs": ["hand:1"]}),
        decision_row(8, action=tarot_action("c_star", "consumable:3", ("hand:2",))),
    ]
    results = [result_row(7, accepted=True, code="broker_ok"),
               result_row(8, accepted=True, code="broker_ok")]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=5,
                      decisions=decisions, results=results)
        selection = _selection(root)
        assert [row["receipt_status"] for row in selection["rows"]] == ["ambiguous"] * 3
        assert all(row["broker_accepted"] is None and row["broker_code"] is None for row in selection["rows"])
        assert selection["receipts"] == {"matched": 0, "absent": 0, "ambiguous": 3, "invalid": 0}


def test_tarot_selection_keeps_malformed_receipts_from_becoming_matched():
    decisions = [
        decision_row(1, action=tarot_action("c_sun", "consumable:1", ("hand:1",))),
        decision_row(2, action=tarot_action("c_moon", "consumable:2", ("hand:2",))),
    ]
    results = [
        result_row(1, accepted=True, code="broker_ok"),
        {"session": "s-tarot", "sequence": 1, "accepted": "not-a-bool", "code": "broker_ok"},
        {"session": "s-tarot", "sequence": 2, "accepted": "not-a-bool", "code": "broker_ok"},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=5,
                      decisions=decisions, results=results)
        selection = _selection(root)
        statuses = {row["sequence"]: row["receipt_status"] for row in selection["rows"]}
        assert statuses == {1: "ambiguous", 2: "invalid"}
        assert all(row["broker_accepted"] is None and row["broker_code"] is None for row in selection["rows"])
        assert selection["receipts"] == {"matched": 0, "absent": 0, "ambiguous": 1, "invalid": 1}


def test_tarot_selection_accepts_only_canonical_positive_positional_refs():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        good = tarot_action("c_sun", "consumable:999", ("hand:1", "hand:999"))
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3,
                      decisions=[decision_row(1, action=good)])
        row = _selection(root)["rows"][0]
        assert row["source_ref"] == "consumable:999"
        assert row["card_refs"] == ["hand:1", "hand:999"]
        assert row["targets"] == 2 and row["targets_truncated"] is False
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bad = tarot_action("c_death", "consumable:0", ("hand:0", "hand:01", "hand:1000", "hand:12345678901", "hand:007"))
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3,
                      decisions=[decision_row(1, action=bad)])
        row = _selection(root)["rows"][0]
        assert row["source_ref"] is None
        assert row["card_refs"] == [] and row["targets"] == 0 and row["targets_truncated"] is False
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        three = tarot_action("c_sun", "consumable:1", ("hand:1", "hand:2", "hand:3"))
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3,
                      decisions=[decision_row(1, action=three)])
        row = _selection(root)["rows"][0]
        assert row["card_refs"] == ["hand:1", "hand:2"] and row["targets"] == 2
        assert row["targets_truncated"] is True


def test_tarot_selection_requires_positive_integer_sequences():
    ticks = [0, -1, True, 1.5, 10 ** 30, None, "3", 4]
    decisions = [decision_row(tick, action=tarot_action("c_world", "consumable:1", ("hand:1",))) for tick in ticks]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write_session(root, "s-tarot", difficulty="expert", result="ai_win", ante=3, decisions=decisions)
        rows = _selection(root)["rows"]
        assert [row["sequence"] for row in rows] == [None] * 7 + [4]
        assert [row["receipt_status"] for row in rows] == ["invalid"] * 7 + ["absent"]


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_") and callable(value)]
    failures = 0
    for test in tests:
        try:
            test()
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {test.__name__}: {type(error).__name__}: {error}")
        else:
            print(f"ok   {test.__name__}")
    print(f"\n{len(tests) - failures}/{len(tests)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
