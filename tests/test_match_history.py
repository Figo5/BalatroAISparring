#!/usr/bin/env python3
"""Synthetic-session tests for tools/match_history.py (read-only aggregator)."""
from __future__ import annotations

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
