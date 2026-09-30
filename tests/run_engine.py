#!/usr/bin/env python3
"""Engine adapter / production executor test harness.

Static source checks for the trusted integration modules plus the Lua fixture
suite in tests/engine/ run under lupa's Lua 5.1 and LuaJIT 2.1. The real schema
(codec/observation/actions), state reader, engine adapter, production executor
and action broker sources are loaded; no game, Mods directory, network or live
runtime is touched.
"""
from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE_DIR = REPO / "tests" / "engine"
RUNNER = ENGINE_DIR / "runner.lua"
INTEGRATION = REPO / "AISparring" / "integration"
ADAPTER = INTEGRATION / "engine_adapter.lua"
EXECUTOR = INTEGRATION / "production_executor.lua"
REVISION = INTEGRATION / "state_revision.lua"
GUIDE = REPO / "docs" / "ENGINE_ADAPTER.md"

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

FORBIDDEN_FIELDS = [
    "real_score",
    "highest_score",
    "last_timer",
    "pvp_timer_order",
    "pvpTimerOrder",
    "spent_in_shop",
    "mod_hash",
    "hardware_id",
]

# UI `can_*` predicates mutate colour/visibility and must never be invoked by
# the producer or on hypothetical executor candidates.
MUTATING_PREDICATES = [
    "can_play",
    "can_buy",
    "can_buy_and_use",
    "can_discard",
    "can_open",
    "can_reroll",
    "can_redeem",
    "can_select_card",
    "can_skip_booster",
    "check_for_buy_space",
]

COMMITTED_CALLBACKS = [
    "play_cards_from_highlighted",
    "discard_cards_from_highlighted",
    "buy_from_shop",
    "sell_card",
    "reroll_shop",
    "toggle_shop",
    "use_card",
    "select_blind",
    "skip_blind",
    "skip_booster",
    "cash_out",
    "mp_toggle_ready",
]


def strip_lua(src: str) -> str:
    """Blank out Lua comments and short string literals.

    Used so absence checks (no io/os/require, no raw opponent fields) inspect
    real code rather than documentation comments or symbol-name strings.
    """
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == "-" and i + 1 < n and src[i + 1] == "-":
            j = i + 2
            long_level = 0
            if j < n and src[j] == "[":
                k = j + 1
                while k < n and src[k] == "=":
                    long_level += 1
                    k += 1
                if k < n and src[k] == "[":
                    close = "]" + "=" * long_level + "]"
                    end = src.find(close, k + 1)
                    i = n if end == -1 else end + len(close)
                    continue
            end = src.find("\n", i)
            i = n if end == -1 else end
            continue
        if ch == "[":
            k = i + 1
            long_level = 0
            while k < n and src[k] == "=":
                long_level += 1
                k += 1
            if k < n and src[k] == "[":
                close = "]" + "=" * long_level + "]"
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

    add("engine_files_present", all(p.is_file() for p in (ADAPTER, EXECUTOR, REVISION, RUNNER, GUIDE)))

    adapter_src = ADAPTER.read_text(encoding="utf-8") if ADAPTER.is_file() else ""
    executor_src = EXECUTOR.read_text(encoding="utf-8") if EXECUTOR.is_file() else ""
    revision_src = REVISION.read_text(encoding="utf-8") if REVISION.is_file() else ""
    guide_src = GUIDE.read_text(encoding="utf-8") if GUIDE.is_file() else ""

    adapter_code = strip_lua(adapter_src)
    executor_code = strip_lua(executor_src)
    revision_code = strip_lua(revision_src)

    offenders: list[str] = []
    for label, src in (("adapter", adapter_code), ("executor", executor_code), ("revision", revision_code)):
        for token in FORBIDDEN_TOKENS:
            if token in src:
                offenders.append(f"{label}:{token}")
    add("modules_no_forbidden_apis", not offenders, ";".join(offenders))

    field_offenders: list[str] = []
    for label, src in (("adapter", adapter_code), ("executor", executor_code)):
        for field in FORBIDDEN_FIELDS:
            if field in src:
                field_offenders.append(f"{label}:{field}")
    add("modules_no_forbidden_fields", not field_offenders, ";".join(field_offenders))

    adapter_predicates = [name for name in MUTATING_PREDICATES if name in adapter_code]
    add(
        "adapter_no_speculative_ui_predicates",
        not adapter_predicates,
        ",".join(adapter_predicates),
    )

    executor_predicates = [name for name in ("can_play", "can_buy", "can_discard", "can_open", "can_reroll", "check_for_buy_space") if name in executor_code]
    add(
        "executor_no_mutating_ui_predicates",
        not executor_predicates,
        ",".join(executor_predicates),
    )

    add(
        "executor_calls_committed_callbacks",
        all(name in executor_src for name in COMMITTED_CALLBACKS),
    )
    add("executor_pure_predicates_only", "can_sell_card" in executor_src and "can_use_consumeable" in executor_src)
    add("executor_stale_revision_code", "exec_stale_revision" in executor_src)
    add("executor_production_sentinel", '"M3_PRODUCTION"' in executor_src and "broker_ports" in executor_src)
    add("adapter_reports_cash_out_control", '"cash_out"' in adapter_src)

    # Owned scaling Joker values (docs/SCALING_VALUES_DESIGN.md): the reader
    # recomputes what the adapter exports, so both copies must be identical.
    reader_src = (INTEGRATION / "state_reader.lua").read_text(encoding="utf-8")

    def lua_block(src: str, head: str, end: str) -> str | None:
        start = src.find(head)
        if start == -1:
            return None
        stop = src.find(end, start)
        return None if stop == -1 else src[start:stop + len(end)]

    same = []
    for head, end in (("local SCALING_CURRENT = {", "\n}\n"), ("local function scaling_number(", "\nend\n")):
        a_block, r_block = lua_block(adapter_src, head, end), lua_block(reader_src, head, end)
        same.append(a_block is not None and a_block == r_block)
    add("adapter_reader_scaling_tables_identical", all(same), str(same))
    add(
        "executor_routes_pvp_ready_through_select_blind",
        "pvp_blind_on_deck" in executor_src and "mp_toggle_ready" in executor_src and "select_blind" in executor_src,
    )
    add(
        "executor_supports_sell_consumable",
        "SELL_CONSUMABLE" in executor_src and "consumable_ref" in executor_src and "can_sell_card" in executor_src,
    )
    add("adapter_engine_symbols_by_name", "SMODS_BOOSTER_OPENED" in adapter_src and "ROUND_EVAL" in adapter_src)
    add("revision_monotonic_contract", "sync" in revision_src and "bump" in revision_src and "revision_overflow" in revision_src)
    add("guide_documents_broker_extension", "broker" in guide_src.lower() and "M3_PRODUCTION" in guide_src)

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
    runner = lua.globals()["ais_run_engine_one"]
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
    parser = argparse.ArgumentParser(description="AISparring engine adapter test harness")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when any requested lupa runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring engine adapter harness")
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
    test_files = sorted(ENGINE_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {ENGINE_DIR}", file=sys.stderr)
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
