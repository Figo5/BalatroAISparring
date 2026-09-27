#!/usr/bin/env python3
"""Milestone 1 scaffold test harness.

Runs the real AISparring entrypoint and modules inside synthetic Lua host
fixtures under lupa's Lua 5.1 and LuaJIT 2.1 runtimes. No game files, no Mods
directory and no network are touched.
"""
from __future__ import annotations

import argparse
import importlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MOD_DIR = REPO / "AISparring"
MANIFEST = MOD_DIR / "AISparring.json"
LUA_DIR = REPO / "tests" / "lua"
RUNNER = LUA_DIR / "runner.lua"

MODULE_PATHS = [
    "src/status.lua",
    "src/logger.lua",
    "src/ai_mode.lua",
    "src/dependency.lua",
    "src/host.lua",
]

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

FORBIDDEN_TOKENS = [
    "io.open",
    "io.write",
    "io.popen",
    "io[",
    "os.execute",
    "os.remove",
    "os.rename",
    "os.tmpname",
    "love.filesystem",
    "love.thread",
    "love.network",
    "socket.",
    "NFS.",
    "require(",
    "dofile",
    "loadstring",
    "debug.",
    "setfenv(",
    "rawset(",
]


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        add("manifest_parses", True)
    except Exception as exc:  # noqa: BLE001
        add("manifest_parses", False, str(exc))
        return cases

    required = [
        "id", "name", "author", "description", "prefix",
        "main_file", "version", "priority", "dependencies",
    ]
    missing = [key for key in required if key not in data]
    add("manifest_required_metadata", not missing, ",".join(missing))
    add("manifest_id", data.get("id") == "AISparring")

    main_file = data.get("main_file")
    add(
        "manifest_main_file_exists",
        isinstance(main_file, str) and (MOD_DIR / main_file).is_file(),
        str(main_file),
    )

    deps = data.get("dependencies")
    add(
        "manifest_exact_dependency_pin",
        isinstance(deps, list) and "Multiplayer (==0.5.5)" in deps,
    )

    priority = data.get("priority")
    add(
        "manifest_priority_after_multiplayer",
        isinstance(priority, int) and priority > 10000000,
        str(priority),
    )

    prefix = data.get("prefix")
    add(
        "manifest_prefix_valid",
        isinstance(prefix, str) and prefix != "" and "$" not in prefix,
        str(prefix),
    )

    json_files = sorted(path.name for path in MOD_DIR.rglob("*.json"))
    add("manifest_no_stray_json", json_files == ["AISparring.json"], ",".join(json_files))

    add("modules_present", all((MOD_DIR / path).is_file() for path in MODULE_PATHS))

    config_path = MOD_DIR / "config.lua"
    config_text = config_path.read_text(encoding="utf-8") if config_path.is_file() else ""
    add(
        "config_declares_ai_flag_false",
        bool(re.search(r"ai_enabled\s*=\s*false", config_text)),
    )

    offenders: list[str] = []
    sources = [MOD_DIR / "core.lua"] + [MOD_DIR / path for path in MODULE_PATHS]
    for path in sources:
        body = path.read_text(encoding="utf-8")
        for token in FORBIDDEN_TOKENS:
            if token in body:
                offenders.append(f"{path.name}:{token}")
    add("no_forbidden_io_apis_in_sources", not offenders, ";".join(offenders))

    dep_match = None
    if isinstance(deps, list) and len(deps) == 1:
        parsed = re.match(r"^\s*([A-Za-z0-9_]+)\s*\(==\s*([^)]+)\)\s*$", deps[0])
        if parsed:
            dep_match = (parsed.group(1), parsed.group(2))

    dependency_src = (MOD_DIR / "src" / "dependency.lua").read_text(encoding="utf-8")
    status_src = (MOD_DIR / "src" / "status.lua").read_text(encoding="utf-8")

    spec_block = re.search(r"Dependency\.SPEC\s*=\s*\{(.*?)\n\}", dependency_src, re.S)
    spec_id = spec_version = None
    if spec_block:
        id_match = re.search(r'id\s*=\s*"([^"]+)"', spec_block.group(1))
        version_match = re.search(r'version\s*=\s*"([^"]+)"', spec_block.group(1))
        spec_id = id_match.group(1) if id_match else None
        spec_version = version_match.group(1) if version_match else None

    add(
        "manifest_dependency_parses",
        dep_match is not None,
        str(deps),
    )
    add(
        "runtime_spec_matches_manifest",
        dep_match is not None and spec_id == dep_match[0] and spec_version == dep_match[1],
        f"spec={spec_id}:{spec_version}",
    )

    pin_matches = re.search(r'dependency_pin\s*=\s*"([^"]+)"', status_src)
    supported_matches = re.search(r'supported_version\s*=\s*"([^"]+)"', status_src)
    priority_matches = re.search(r"priority\s*=\s*(\d+)", status_src)
    expected_pin = f"{dep_match[0]} (=={dep_match[1]})" if dep_match else None
    add(
        "status_pin_matches_manifest",
        expected_pin is not None
        and pin_matches is not None
        and pin_matches.group(1) == expected_pin
        and supported_matches is not None
        and supported_matches.group(1) == dep_match[1],
        f"pin={pin_matches.group(1) if pin_matches else None}",
    )
    add(
        "status_priority_matches_manifest",
        isinstance(priority, int)
        and priority_matches is not None
        and int(priority_matches.group(1)) == priority,
        f"status={priority_matches.group(1) if priority_matches else None}",
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
    runner = lua.globals()["ais_run_one"]
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
    parser = argparse.ArgumentParser(description="AISparring Milestone 1 test harness")
    parser.add_argument(
        "--require-all",
        action="store_true",
        help="fail when any requested lupa runtime is unavailable (strict acceptance)",
    )
    args = parser.parse_args(argv)

    print("AISparring Milestone 1 test harness")
    print(f"repository: {REPO}")

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0

    statics = static_cases()
    static_passed = sum(1 for case in statics if case["ok"])
    for case in statics:
        unique_names.add(f"static::{case['name']}")
    total_executions += len(statics)
    print(f"static manifest/source checks: {static_passed}/{len(statics)} passed")
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
    test_files = sorted(LUA_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {LUA_DIR}", file=sys.stderr)
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
                    print(f"PASS {display}::{row['name']}")
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
