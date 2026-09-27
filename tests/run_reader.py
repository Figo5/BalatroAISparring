#!/usr/bin/env python3
"""State reader (state_reader.lua) test harness.

Runs tests/reader/test_*.lua inside lupa's Lua 5.1 and LuaJIT 2.1 runtimes,
loading the real AISparring ai modules (codec, observation) and the trusted
state reader. No game, Mods directory, network or live runtime is touched.
"""
from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
READER_DIR = REPO / "tests" / "reader"
RUNNER = READER_DIR / "runner.lua"
RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]


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
    runner = lua.globals()["ais_run_reader_one"]
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
    parser = argparse.ArgumentParser(description="AISparring state reader test harness")
    parser.add_argument(
        "--require-all",
        action="store_true",
        help="fail when any requested lupa runtime is unavailable (strict acceptance)",
    )
    args = parser.parse_args(argv)

    print("AISparring state reader test harness")
    print(f"repository: {REPO}")

    if not RUNNER.is_file():
        print(f"runner missing: {RUNNER}", file=sys.stderr)
        return 1

    test_files = sorted(READER_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {READER_DIR}", file=sys.stderr)
        return 1

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0
    available = 0

    runner_src = RUNNER.read_text(encoding="utf-8")
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
        print(
            "No lupa runtimes available. Install with: "
            "python -m pip install -r tests/requirements.txt",
            file=sys.stderr,
        )
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
