#!/usr/bin/env python3
"""Milestone 2 test harness: codec, observation and legal-action boundaries.

Runs the real AISparring/ai/*.lua sources under lupa's Lua 5.1 and LuaJIT 2.1
runtimes over tests/m2/test_*.lua. No game files, Mods directory, network or
engine callbacks are touched. Cross-runtime canonical/hash/action vectors are
recorded and compared exactly, and codec checksums are independently
recomputed in Python.
"""
from __future__ import annotations

import argparse
import importlib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
M2_DIR = REPO / "tests" / "m2"
RUNNER = M2_DIR / "runner.lua"
AI_DIR = REPO / "AISparring" / "ai"
AI_FILES = ["codec.lua", "observation.lua", "actions.lua"]
DOCS = [
    REPO / "docs" / "AI_OBSERVATION.md",
    REPO / "docs" / "LEGAL_ACTIONS.md",
]

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

PROHIBITED_PATTERNS = [
    (r"\brequire\s*\(", "require"),
    (r"\bdofile\b", "dofile"),
    (r"\bloadstring\b", "loadstring"),
    (r"\bload\s*\(", "load"),
    (r"\bsetfenv\b", "setfenv"),
    (r"\bgetfenv\b", "getfenv"),
    (r"\brawset\b", "rawset"),
    (r"\bcollectgarbage\b", "collectgarbage"),
    (r"\bdebug\s*[.:]", "debug"),
    (r"\bio\s*[.:]", "io"),
    (r"\bos\s*[.:]", "os"),
    (r"\bmath\s*\.\s*random\b", "math.random"),
    (r"\blove\s*\.", "love"),
    (r"\bSMODS\b", "SMODS"),
    (r"\bG\b", "G"),
    (r"\bMP\b", "MP"),
    (r"\b_G\b", "_G"),
    (r"\bpackage\b", "package"),
    (r"\bstring\s*\.\s*dump\b", "string.dump"),
    (r"\bClient\b", "Client"),
]

FNV_CASES = {
    "fnv-empty": b"",
    "fnv-a": b"a",
    "fnv-abc": b"abc",
    "fnv-hello": b"hello",
}

EXPECTED_VECTORS = {
    "enc-map-order": "o2:s1:a;s1:x;s1:b;i1;",
    "enc-array": "a3:i1;i2;i3;",
}


def fnv1a_32(data: bytes) -> str:
    value = 2166136261
    for byte in data:
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return f"{value:08x}"


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    missing = [name for name in AI_FILES if not (AI_DIR / name).is_file()]
    add("ai_modules_present", not missing, ",".join(missing))

    docs_missing = [path.name for path in DOCS if not path.is_file()]
    add("ai_docs_present", not docs_missing, ",".join(docs_missing))

    sources = sorted(AI_DIR.rglob("*.lua"))
    add("ai_sources_discovered", len(sources) >= len(AI_FILES), f"{len(sources)} files")

    offenders: list[str] = []
    for path in sources:
        body = path.read_text(encoding="utf-8")
        relative = path.relative_to(REPO).as_posix()
        for pattern, label in PROHIBITED_PATTERNS:
            if re.search(pattern, body):
                offenders.append(f"{relative}:{label}")
    add("ai_no_forbidden_apis_recursive", not offenders, ";".join(offenders))

    return cases


def load_runtime(module_name: str):
    try:
        module = importlib.import_module(module_name)
    except Exception as exc:  # noqa: BLE001
        return None, f"unavailable: {exc}"
    factory = getattr(module, "LuaRuntime", None)
    if factory is None:
        return None, "no LuaRuntime"
    try:
        factory(unpack_returned_tuples=True)
    except Exception as exc:  # noqa: BLE001
        return None, f"runtime error: {exc}"
    return factory, None


def run_file(runtime_factory, runner_src: str, test_file: Path) -> dict:
    lua = runtime_factory(unpack_returned_tuples=True)
    lua.execute(runner_src)
    runner = lua.globals()["ais_m2_run"]
    result = runner(REPO.as_posix(), test_file.as_posix())

    cases: list[dict] = []
    raw_cases = result["cases"]
    if raw_cases is not None:
        for row in raw_cases.values():
            err = row["err"]
            cases.append(
                {
                    "name": str(row["name"]),
                    "ok": bool(row["ok"]),
                    "err": "" if err is None else str(err),
                }
            )
    vectors: dict[str, str] = {}
    raw_vectors = result["vectors"]
    if raw_vectors is not None:
        for key, value in raw_vectors.items():
            vectors[str(key)] = str(value)
    iterations = result["iterations"]
    error = result["error"]
    return {
        "cases": cases,
        "vectors": vectors,
        "iterations": int(iterations) if iterations is not None else 0,
        "error": None if error is None else str(error),
    }


def run_python_plugins(failures: list[str]) -> int:
    plugin_dir = M2_DIR / "py"
    if not plugin_dir.is_dir():
        return 0
    count = 0
    for script in sorted(plugin_dir.glob("test_*.py")):
        count += 1
        completed = subprocess.run(
            [sys.executable, str(script)],
            cwd=str(REPO),
            capture_output=True,
            text=True,
        )
        if completed.stdout:
            print(completed.stdout, end="")
        if completed.returncode != 0:
            failures.append(f"python_plugin::{script.stem} :: exit {completed.returncode}")
            if completed.stderr:
                print(completed.stderr, file=sys.stderr)
    return count


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring Milestone 2 test harness")
    parser.add_argument("--require-all", action="store_true", help="fail when a runtime is unavailable")
    parser.add_argument("--benchmark", action="store_true", help="run the fixture benchmark after the tests")
    args = parser.parse_args(argv)

    print("AISparring Milestone 2 test harness")
    print(f"repository: {REPO}")

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0
    total_iterations = 0

    statics = static_cases()
    for case in statics:
        unique_names.add(f"static::{case['name']}")
    total_executions += len(statics)
    passed = sum(1 for case in statics if case["ok"])
    print(f"static checks: {passed}/{len(statics)} passed")
    for case in statics:
        if case["ok"]:
            print(f"PASS static::{case['name']}")
        else:
            print(f"FAIL static::{case['name']} :: {case['detail']}")
            failures.append(f"static::{case['name']} :: {case['detail']}")

    if not RUNNER.is_file():
        print(f"runner missing: {RUNNER}", file=sys.stderr)
        return 1
    runner_src = RUNNER.read_text(encoding="utf-8")

    test_files = sorted(M2_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {M2_DIR}", file=sys.stderr)
        return 1

    vectors_by_runtime: dict[str, dict[str, str]] = {}
    available = 0

    for display, module_name in RUNTIMES:
        runtime_factory, error = load_runtime(module_name)
        if runtime_factory is None:
            print(f"runtime {display}: SKIPPED ({error})")
            if args.require_all:
                failures.append(f"{display} runtime required but unavailable ({error})")
            continue
        available += 1
        vectors_by_runtime[display] = {}
        runtime_pass = 0
        runtime_count = 0
        for test_file in test_files:
            stem = test_file.stem
            try:
                result = run_file(runtime_factory, runner_src, test_file)
            except Exception as exc:  # noqa: BLE001
                unique_names.add(f"{stem}::harness")
                total_executions += 1
                failures.append(f"{display} {stem}::harness :: {exc}")
                continue
            if result["error"] is not None:
                unique_names.add(f"{stem}::harness")
                total_executions += 1
                failures.append(f"{display} {stem}::harness :: {result['error']}")
                continue
            total_iterations += result["iterations"]
            for key, value in result["vectors"].items():
                vectors_by_runtime[display][f"{stem}::{key}"] = value
            for row in result["cases"]:
                name = f"{stem}::{row['name']}"
                runtime_count += 1
                total_executions += 1
                unique_names.add(name)
                if row["ok"]:
                    runtime_pass += 1
                else:
                    failures.append(f"{display} {name} :: {row['err']}")
                    print(f"FAIL {display}::{name} :: {row['err']}")
            print(f"runtime {display} {stem}: {sum(1 for r in result['cases'] if r['ok'])}/{len(result['cases'])} passed")
        print(f"runtime {display}: {runtime_pass}/{runtime_count} passed")
        if runtime_count == 0:
            failures.append(f"{display} runtime discovered and executed zero tests")

    if available == 0:
        print("No lupa runtimes available. Install with: python -m pip install -r tests/requirements.txt", file=sys.stderr)
        return 1

    if len(vectors_by_runtime) == 2:
        left = vectors_by_runtime["lua51"]
        right = vectors_by_runtime["luajit21"]
        keys = sorted(set(left) | set(right))
        for key in keys:
            if left.get(key) != right.get(key):
                failures.append(f"vector mismatch {key}: lua51={left.get(key)!r} luajit21={right.get(key)!r}")
    elif args.require_all:
        failures.append("cross-runtime vector comparison requires both runtimes")

    all_vectors: dict[str, str] = {}
    for runtime_vectors in vectors_by_runtime.values():
        all_vectors.update(runtime_vectors)

    for key, value in sorted(all_vectors.items()):
        for name, data in FNV_CASES.items():
            if key.endswith("::" + name):
                expected = fnv1a_32(data)
                if value != expected:
                    failures.append(f"fnv oracle {key}: got {value}, expected {expected}")
        for name, expected in EXPECTED_VECTORS.items():
            if key.endswith("::" + name) and value != expected:
                failures.append(f"vector oracle {key}: got {value!r}, expected {expected!r}")

    if args.benchmark:
        bench_path = REPO / "tests" / "benchmark_m2.py"
        spec = importlib.util.spec_from_file_location("benchmark_m2", bench_path)
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        if bench.main([]) != 0:
            failures.append("benchmark exited nonzero")

    plugin_count = run_python_plugins(failures)
    if plugin_count == 0:
        print("python plug-in tests: none discovered (tests/m2/py/)")

    print(f"unique cases: {len(unique_names)}")
    print(f"total case executions: {total_executions}")
    print(f"property iterations: {total_iterations}")
    print(f"runtimes available: {available}")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        print(f"RESULT: FAIL ({len(failures)} failures)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
