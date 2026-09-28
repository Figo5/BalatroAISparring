#!/usr/bin/env python3
"""Production broker / decision loop test harness.

Static source checks for the production capability path and the injected-port
decision loop, plus the Lua fixture suite in tests/decision/ run under lupa's
Lua 5.1 and LuaJIT 2.1. The real M2 codec/observation/actions, the real action
broker and the real decision loop are loaded; only the async transport and the
clock are fake. No game, Mods directory, network, engine callback or live
runtime is touched.
"""
from __future__ import annotations

import argparse
import importlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DECISION_DIR = REPO / "tests" / "decision"
RUNNER = DECISION_DIR / "runner.lua"
SUPPORT = DECISION_DIR / "support.lua"
BROKER = REPO / "AISparring" / "integration" / "action_broker.lua"
LOOP = REPO / "AISparring" / "integration" / "decision_loop.lua"
GUIDE = REPO / "docs" / "DECISION_LOOP.md"

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

FORBIDDEN_TOKENS = [
    "require(",
    "dofile",
    "loadstring",
    "setfenv",
    "getfenv",
    "collectgarbage",
    "debug.",
    "io.",
    "os.",
    "math.random",
    "love.",
    "SMODS",
    "Client",
    "NFS.",
    "_G",
    "package.",
]

GLOBAL_PATTERNS = [
    (r"\bG\b", "G"),
    (r"\bMP\b", "MP"),
]


def strip_lua(src: str) -> str:
    """Blank out Lua comments and short string literals.

    Absence checks must inspect real code, not documentation or symbol names.
    """
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == "-" and i + 1 < n and src[i + 1] == "-":
            j = i + 2
            if j < n and src[j] == "[":
                k = j + 1
                level = 0
                while k < n and src[k] == "=":
                    level += 1
                    k += 1
                if k < n and src[k] == "[":
                    close = "]" + "=" * level + "]"
                    end = src.find(close, k + 1)
                    i = n if end == -1 else end + len(close)
                    continue
            end = src.find("\n", i)
            i = n if end == -1 else end
            continue
        if ch == "[":
            k = i + 1
            level = 0
            while k < n and src[k] == "=":
                level += 1
                k += 1
            if k < n and src[k] == "[":
                close = "]" + "=" * level + "]"
                end = src.find(close, k + 1)
                i = n if end == -1 else end + len(close)
                continue
        if ch == '"' or ch == "'":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == ch:
                    i += 1
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    add("decision_files_present", all(p.is_file() for p in (BROKER, LOOP, RUNNER, SUPPORT, GUIDE)))

    broker_src = BROKER.read_text(encoding="utf-8") if BROKER.is_file() else ""
    loop_src = LOOP.read_text(encoding="utf-8") if LOOP.is_file() else ""
    guide_src = GUIDE.read_text(encoding="utf-8") if GUIDE.is_file() else ""

    broker_code = strip_lua(broker_src)
    loop_code = strip_lua(loop_src)

    add("broker_production_factory", all(name in broker_src for name in ("production_factory", "authorize", "mint")))
    add("broker_capability_identity", "AISparring.ActionBroker.capability" in broker_src)
    add("broker_revoke_support", "function instance.revoke" in broker_src and "revoke_all" in broker_src)
    add("broker_cancel_support", "function instance.cancel" in broker_src)
    add("broker_keeps_fixture_sentinel", '"M2_FIXTURE_ONLY"' in broker_src)
    add("broker_keeps_executor_disabled", "broker_executor_disabled" in broker_src)
    add("broker_production_requires_explicit_true", "explicit ~= true" in broker_src)
    add("broker_default_mode_disabled", "MODE_DISABLED" in broker_src)
    add(
        "broker_revocation_checked_for_issue_and_submit",
        broker_code.count("revoked_now()") >= 3,
        f"count={broker_code.count('revoked_now()')}",
    )

    broker_offenders = [token for token in FORBIDDEN_TOKENS if token in broker_code]
    add("broker_no_forbidden_apis", not broker_offenders, ";".join(broker_offenders))

    loop_offenders = [token for token in FORBIDDEN_TOKENS if token in loop_code]
    add("loop_no_forbidden_apis", not loop_offenders, ";".join(loop_offenders))

    global_offenders: list[str] = []
    for pattern, label in GLOBAL_PATTERNS:
        if re.search(pattern, loop_code):
            global_offenders.append(label)
    add("loop_no_engine_globals", not global_offenders, ",".join(global_offenders))

    add("loop_no_fixture_string", "M2_FIXTURE_ONLY" not in loop_src)
    add(
        "loop_payload_is_sequence_and_observation",
        "sequence = sequence, observation = observation" in loop_src,
    )
    add("loop_control_allowlist", "CONTROL_ALLOWLIST" in loop_src and '"cash_out"' in loop_src)
    add("loop_has_no_advance_ui_call", "advance_ui" not in loop_src)
    add("loop_revokes_on_abort", "broker.revoke()" in loop_src)
    add("loop_caps_pending", "local pending = nil" in loop_src and "pending = {" in loop_src)
    add("loop_matches_exact_sequence", "sequence ~= pending.sequence" in loop_src)
    add(
        "loop_transient_contract",
        all(name in loop_src for name in ("transient_codes", "max_transient_streak", "register_transient")),
    )
    add("loop_control_latch", "control_latch" in loop_src and "abandon_pending()" in loop_src)

    add(
        "guide_documents_trusted_mint",
        "bootstrap" in guide_src.lower() and "capability" in guide_src.lower(),
    )
    add(
        "guide_documents_no_sandbox_claim",
        "not a sandbox" in guide_src.lower() or "no security claim" in guide_src.lower(),
    )

    return cases


def load_runtime(module_name: str):
    try:
        module = importlib.import_module(module_name)
    except Exception as exc:  # noqa: BLE001
        return None, f"unavailable: {exc}"
    runtime_factory = getattr(module, "LuaRuntime", None) or module
    try:
        runtime_factory(unpack_returned_tuples=True)
    except Exception as exc:  # noqa: BLE001
        return None, f"runtime error: {exc}"
    return runtime_factory, None


def run_file(runtime_factory, runner_src: str, test_file: Path):
    lua = runtime_factory(unpack_returned_tuples=True)
    lua.execute(runner_src)
    runner = lua.globals()["ais_run_decision_one"]
    results = runner(REPO.as_posix(), test_file.as_posix())
    rows = []
    for row in results.values():
        rows.append(
            {
                "name": str(row["name"]),
                "ok": bool(row["ok"]),
                "err": "" if row["err"] is None else str(row["err"]),
            }
        )
    return rows


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring decision loop test harness")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when any requested lupa runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring decision loop harness")
    print(f"repository: {REPO}")

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0

    statics = static_cases()
    static_passed = sum(1 for case in statics if case["ok"])
    for case in statics:
        unique_names.add(f"static::{case['name']}")
        if case["ok"]:
            print(f"PASS static::{case['name']}")
        else:
            print(f"FAIL static::{case['name']} :: {case['detail']}")
            failures.append(f"static::{case['name']} :: {case['detail']}")
    total_executions += len(statics)
    print(f"static checks: {static_passed}/{len(statics)} passed")

    if not RUNNER.is_file():
        print(f"runner missing: {RUNNER}", file=sys.stderr)
        return 1

    runner_src = RUNNER.read_text(encoding="utf-8")
    test_files = sorted(DECISION_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {DECISION_DIR}", file=sys.stderr)
        return 1

    available = 0
    for display, module_name in RUNTIMES:
        runtime_factory, error = load_runtime(module_name)
        if runtime_factory is None:
            print(f"runtime {display}: SKIPPED ({error})")
            if args.require_all:
                failures.append(f"{display} runtime required but unavailable ({error})")
            continue
        available += 1
        passed = 0
        count = 0
        for test_file in test_files:
            try:
                rows = run_file(runtime_factory, runner_src, test_file)
            except Exception as exc:  # noqa: BLE001
                unique_names.add(f"harness::{test_file.stem}")
                total_executions += 1
                failures.append(f"{display} harness::{test_file.stem} :: {exc}")
                continue
            for row in rows:
                count += 1
                total_executions += 1
                unique_names.add(row["name"])
                if row["ok"]:
                    passed += 1
                else:
                    print(f"FAIL {display}::{row['name']} :: {row['err']}")
                    failures.append(f"{display} {row['name']} :: {row['err']}")
        print(f"runtime {display}: {passed}/{count} passed")
        if count == 0:
            failures.append(f"{display} runtime discovered and executed zero tests")

    if available == 0:
        print("No lupa runtimes available. Install with: python -m pip install -r tests/requirements.txt",
              file=sys.stderr)
        return 1

    print(f"unique cases: {len(unique_names)}")
    print(f"total executions: {total_executions}")

    for failure in failures:
        print(f"FAIL {failure}")

    if failures:
        print(f"RESULT: FAIL ({len(failures)} failing cases)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
