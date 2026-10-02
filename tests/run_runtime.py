#!/usr/bin/env python3
"""Staged runtime integration test harness.

Static source checks for the staged runtime bootstrap, MP driver, control
transport and control thread, plus the Lua fixture suite in tests/runtime/ run
under lupa's Lua 5.1 and LuaJIT 2.1. The real protocol/transport/thread/driver
and bootstrap sources plus the real M2/engine modules are loaded; only the game
environment (channels, clock, G/MP) is fake. No game, Mods directory, socket,
thread, network or live runtime is touched.
"""
from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUNTIME_DIR = REPO / "tests" / "runtime"
RUNNER = RUNTIME_DIR / "runner.lua"
SUPPORT = RUNTIME_DIR / "support.lua"
INTEGRATION = REPO / "AISparring" / "integration"
BOOTSTRAP = INTEGRATION / "runtime_bootstrap.lua"
DRIVER = INTEGRATION / "mp_driver.lua"
TRANSPORT = INTEGRATION / "control_transport.lua"
THREAD = INTEGRATION / "control_thread.lua"
GUIDE = REPO / "docs" / "STAGED_RUNTIME.md"

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

FORBIDDEN_TOKENS = [
    "require(",
    "dofile",
    "loadstring",
    "setfenv",
    "getfenv",
    "rawset(",
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


def strip_lua(src: str) -> str:
    """Blank out Lua comments and long/short string literals."""
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

    add("runtime_files_present", all(p.is_file() for p in (BOOTSTRAP, DRIVER, TRANSPORT, THREAD, RUNNER, SUPPORT, GUIDE)))

    bootstrap_src = BOOTSTRAP.read_text(encoding="utf-8") if BOOTSTRAP.is_file() else ""
    driver_src = DRIVER.read_text(encoding="utf-8") if DRIVER.is_file() else ""
    transport_src = TRANSPORT.read_text(encoding="utf-8") if TRANSPORT.is_file() else ""
    thread_src = THREAD.read_text(encoding="utf-8") if THREAD.is_file() else ""
    guide_src = GUIDE.read_text(encoding="utf-8") if GUIDE.is_file() else ""

    bootstrap_code = strip_lua(bootstrap_src)
    driver_code = strip_lua(driver_src)
    transport_code = strip_lua(transport_src)
    thread_code = strip_lua(thread_src)

    offenders: list[str] = []
    for label, src in (
        ("bootstrap", bootstrap_code),
        ("driver", driver_code),
        ("transport", transport_code),
        ("thread", thread_code),
    ):
        for token in FORBIDDEN_TOKENS:
            if token in src:
                offenders.append(f"{label}:{token}")
    add("modules_no_forbidden_apis", not offenders, ";".join(offenders))

    add(
        "bootstrap_saturates_summary_metrics",
        "clamp_metric" in bootstrap_src and "max_sequence" in bootstrap_src,
    )
    add(
        "bootstrap_mints_capability_via_registrar",
        "production_factory" in bootstrap_src and "mint" in bootstrap_src and "authorize" in bootstrap_src,
    )
    add(
        "bootstrap_requires_hello_ack_before_activation",
        'handshake ~= "acked"' in bootstrap_src and "NOT_ARMED" in bootstrap_src,
    )
    add(
        "bootstrap_only_ai_activates",
        'role == "ai"' in bootstrap_src and "WRONG_ROLE" in bootstrap_src,
    )
    add(
        "bootstrap_no_official_transport_redirect",
        "uiToNetwork" not in bootstrap_code and "networkToUi" not in bootstrap_code,
    )
    add(
        "bootstrap_bounds_update_and_heartbeat",
        "max_update_errors" in bootstrap_src and "max_status_per_second" in bootstrap_src,
    )
    add(
        "bootstrap_teardown_stops_local_only",
        "leave_local" in bootstrap_src and "revoke" in bootstrap_src,
    )

    add(
        "driver_uses_original_mp_callbacks",
        all(name in driver_src for name in ("start_lobby", "lobby_ready_up", "lobby_start_game")),
    )
    add(
        "driver_selects_actual_standard_ranked_ruleset",
        "ruleset_mp_standard_ranked" in driver_src
        and "forced_gamemode" in driver_src
        and "force_lobby_options" in driver_src,
    )
    add(
        "driver_calls_real_is_disabled_before_create_join",
        "ruleset_disabled" in driver_src
        and "NO_DISABLED" in driver_src
        and "RULESET_DISABLED" in driver_src,
    )
    add(
        "driver_reads_actual_ranked_config",
        "ranked_config_digest" in driver_src and "LOBBY_ORDER" in driver_src and "_layer_order" in driver_src,
    )
    add(
        "driver_uses_original_force_lobby_options",
        # The real `MP.current_ruleset()` is a metatable proxy, so the field must
        # be resolved with protected normal indexing, never rawget.
        "return resolved.force_lobby_options" in driver_src and "pcall(function()" in driver_src,
    )
    add(
        "driver_seed_after_reset",
        "config.custom_seed = bounded_seed" in driver_src and "start_lobby" in driver_src,
    )
    add(
        "driver_protocol_send_allowlist",
        "SEND_BLOCKED" in driver_src
        and "ENDGAME_REVEAL" in driver_src
        and "match_complete()" in driver_src
        and "getEndGameJokers" in driver_src
        and "getNemesisDeck" in driver_src
        and "guard_allows" in driver_src,
    )
    # The Ranked digest reads the actual `timer_base_seconds` field name, so the
    # check forbids a hardcoded timer *value* (the old 180), not the field read.
    add(
        "driver_no_hardcoded_majorleague_timer",
        "180" not in driver_code and "= 150" not in driver_code and "= 60" not in driver_code,
    )
    add(
        "driver_resolves_real_ready_element",
        "lobby_menu_start" in driver_src and "get_UIE_by_ID" in driver_src and "resolve_ready_element" in driver_src,
    )
    add(
        "driver_derives_source_config_digest",
        "force_lobby_options" in driver_src and "config_digest" in driver_src and "hash_string" in driver_src,
    )
    add(
        "driver_verifies_ready_toggle",
        'rpath(mp, "LOBBY", "ready_to_start") ~= true' in driver_src,
    )
    add(
        "driver_c1_real_run_stage_no_invented_flag",
        "STAGES" in driver_src
        and 'rget(stages, "RUN")' in driver_src
        and 'rget(mp, "is_started")' not in driver_code
        and 'rpath(mp, "LOBBY", "started")' not in driver_code,
    )
    add(
        "driver_c2_protected_force_lookup_and_fatal_rearm",
        "return resolved.force_lobby_options" in driver_src
        and "FORCE_FAILED" in driver_src,
    )
    add(
        "driver_m5_requires_menu_state_and_ui",
        'rget(states, "MENU")' in driver_src and 'rget(G, "MAIN_MENU_UI")' in driver_src,
    )
    add(
        "bootstrap_coordinates_setup_and_join_code",
        "JOIN_CODE" in bootstrap_src and "connected" in bootstrap_src and "compute_digest" in bootstrap_src,
    )
    add(
        "bootstrap_gates_loop_on_match_start",
        "is_started" in bootstrap_src and "match_running" in bootstrap_src,
    )
    add(
        "bootstrap_prestart_deadline_and_abort_are_fatal",
        "prestart_timeout" in bootstrap_src
        and "PRESTART_TIMEOUT" in bootstrap_src
        and 'rawget(response, "aborted")' in bootstrap_src,
    )
    add(
        "bootstrap_installs_guard_for_both_roles",
        "install_send_guard" in bootstrap_src and 'driver_role == "ai"' not in bootstrap_src,
    )

    add(
        "transport_separates_sequence_spaces",
        "decision_base" in transport_src and "SEQUENCE_EXHAUSTED" in transport_src and "transport_replay" in transport_src,
    )
    add(
        "transport_is_nonblocking_and_bounded",
        "poll_decision" in transport_src
        and "max_send" in transport_src
        and "max_receive" in transport_src
        and "TIMEOUT" in transport_src,
    )
    add(
        "transport_keeps_credentials_private",
        "credential_configured" in transport_src and "credential = credential" not in transport_src,
    )
    add(
        "transport_cancels_on_the_wire_before_clearing",
        "DECIDE_CANCEL" in transport_src
        and "send_cancel" in transport_src
        and "decision_sequence" in transport_src,
    )
    add(
        "transport_ordered_inflight_frame_matching",
        "reserve_inflight" in transport_src
        and "take_inflight" in transport_src
        and "deliver_decision" in transport_src
        and "entry.kind" in transport_src,
    )
    add(
        "transport_keeps_owned_cancel_slot_on_failed_push",
        "cancel_code ~= CODE.OK" in transport_src,
    )

    add(
        "thread_bounded_and_loopback_only",
        "127.0.0.1" in thread_src
        and "MAX_SEND" in thread_src
        and "MAX_RECEIVE" in thread_src
        and "READ_TIMEOUT" in thread_src,
    )
    add(
        "thread_uses_dedicated_channels",
        "to_worker" in thread_src and "from_worker" in thread_src and "aisp_ctrl_" in thread_src,
    )
    add(
        "thread_reports_missing_dependency_without_json",
        "emit_fixed" in thread_src
        and '{"t":"error","code":"control_thread_dependency"}' in thread_src
        and "emit_fixed('{\"t\":\"error\",\"code\":\"control_thread_dependency\"}')" in thread_src,
    )

    add(
        "guide_documents_ports_and_nonclaims",
        "bootstrap" in guide_src.lower()
        and "capability" in guide_src.lower()
        and "not" in guide_src.lower(),
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
    runner = lua.globals()["ais_run_runtime_one"]
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
    parser = argparse.ArgumentParser(description="AISparring staged runtime harness")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when any requested lupa runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring staged runtime harness")
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
    test_files = sorted(RUNTIME_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {RUNTIME_DIR}", file=sys.stderr)
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
