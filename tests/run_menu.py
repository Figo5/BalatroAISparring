#!/usr/bin/env python3
"""AI Sparring menu-controller test harness.

Runs the real AISparring/ui/practice_menu.lua and
AISparring/integration/menu_controller.lua sources inside lupa's Lua 5.1 and
LuaJIT 2.1 runtimes over tests/menu/test_*.lua, wired to the honest fake UI tree
in tests/menu/fakeui.lua. No game files, Mods directory, process, network, save
or engine callback is touched.

Static checks assert the UI layer performs no engine mutation, randomness or
process IO, exposes the fixed selection enums, and keeps gauntlet seeds out of
the UI (the trusted host maps index to seed).
"""
from __future__ import annotations

import argparse
import importlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MOD_DIR = REPO / "AISparring"
MENU_DIR = REPO / "tests" / "menu"
RUNNER = MENU_DIR / "runner.lua"
PRACTICE_MENU = MOD_DIR / "ui" / "practice_menu.lua"
MENU_CONTROLLER = MOD_DIR / "integration" / "menu_controller.lua"
DOCS = [REPO / "docs" / "PRACTICE_MENU.md"]

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

UI_SOURCES = [PRACTICE_MENU, MENU_CONTROLLER]

PROHIBITED_PATTERNS = [
    (r"(^|[^%w_.])os\s*[.:]", "os"),
    (r"(^|[^%w_.])io\s*[.:]", "io"),
    (r"(^|[^%w_.])love\s*[.:]", "love"),
    (r"math\s*\.\s*random", "math.random"),
    (r"\brequire\s*\(", "require"),
    (r"\bdofile\b", "dofile"),
    (r"\bloadstring\b", "loadstring"),
    (r"\bload\s*\(", "load"),
    (r"\bsetfenv\b", "setfenv"),
    (r"\bgetfenv\b", "getfenv"),
    (r"\bdebug\s*[.:]", "debug"),
    (r"\bcollectgarbage\b", "collectgarbage"),
    (r"\bpackage\b", "package"),
    (r"(^|[^%w_.])SMODS\b", "SMODS"),
    (r"(^|[^%w_.])MP\b", "MP"),
    (r"(^|[^%w_.])Client\b", "Client"),
    (r"\b_G\b", "_G"),
]

REQUIRED_ENUM_IDS = ["rookie", "competitive", "major_league", "instant", "gauntlet", "normal"]
GAUNTLET_LABELS = ["Test1", "Test2", "Test3", "Test4", "Test5"]
ERROR_MESSAGE = (
    "AI Sparring encountered an error. The match has been stopped. "
    "Diagnostics were written to the log."
)

EXPECTED_VECTORS = {
    "default-payload-keys": "difficulty,mode,pacing",
    "modes": "normal,gauntlet",
    "difficulties": "rookie,competitive,major_league,expert",
    "pacings": "instant,normal",
}


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    missing = [path.name for path in UI_SOURCES if not path.is_file()]
    add("menu_modules_present", not missing, ",".join(missing))

    docs_missing = [path.name for path in DOCS if not path.is_file()]
    add("menu_docs_present", not docs_missing, ",".join(docs_missing))

    offenders: list[str] = []
    for path in UI_SOURCES:
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8")
        relative = path.relative_to(REPO).as_posix()
        for pattern, label in PROHIBITED_PATTERNS:
            if re.search(pattern, body):
                offenders.append(f"{relative}:{label}")
    add("ui_no_engine_mutators_rng_or_process_io", not offenders, ";".join(offenders))

    seed_offenders: list[str] = []
    for path in UI_SOURCES:
        if path.is_file() and "AISP0" in path.read_text(encoding="utf-8"):
            seed_offenders.append(path.relative_to(REPO).as_posix())
    add("ui_contains_no_gauntlet_seed_literals", not seed_offenders, ";".join(seed_offenders))

    controller_text = MENU_CONTROLLER.read_text(encoding="utf-8") if MENU_CONTROLLER.is_file() else ""
    menu_text = PRACTICE_MENU.read_text(encoding="utf-8") if PRACTICE_MENU.is_file() else ""
    combined = controller_text + "\n" + menu_text

    missing_ids = [token for token in REQUIRED_ENUM_IDS if f'"{token}"' not in combined]
    add("ui_declares_required_selection_ids", not missing_ids, ",".join(missing_ids))

    missing_labels = [label for label in GAUNTLET_LABELS if f'"{label}"' not in combined]
    add("ui_declares_stable_gauntlet_labels", not missing_labels, ",".join(missing_labels))

    add("ui_declares_exact_error_message", ERROR_MESSAGE in controller_text)
    add("ui_declares_development_label", "0.1.0-dev" in controller_text)
    add(
        "ui_declares_fixed_major_league_ruleset",
        '"major_league"' in controller_text and '"Major League"' in controller_text,
    )
    add(
        "ui_declares_no_process_launch_calls",
        not re.search(r"\b(os\.execute|io\.popen|spawn|taskkill|CreateProcess)\b", combined),
    )

    test_files = sorted(MENU_DIR.glob("test_*.lua")) if MENU_DIR.is_dir() else []
    add("menu_test_files_present", len(test_files) >= 3, f"{len(test_files)} files")
    add("menu_fakeui_present", (MENU_DIR / "fakeui.lua").is_file())

    doc_text = DOCS[0].read_text(encoding="utf-8") if DOCS[0].is_file() else ""
    add("docs_document_wiring_api", "wiring" in doc_text.lower() or "bootstrap" in doc_text.lower())
    add(
        "docs_disclaim_playable",
        "not playable" in doc_text.lower() or "no dummy opponent" in doc_text.lower(),
    )

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
    runner = lua.globals()["ais_menu_run"]
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
    error = result["error"]
    return {
        "cases": cases,
        "vectors": vectors,
        "error": None if error is None else str(error),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring menu-controller test harness")
    parser.add_argument("--require-all", action="store_true", help="fail when a runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring menu-controller test harness")
    print(f"repository: {REPO}")

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0

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

    test_files = sorted(MENU_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {MENU_DIR}", file=sys.stderr)
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
            print(
                f"runtime {display} {stem}: "
                f"{sum(1 for r in result['cases'] if r['ok'])}/{len(result['cases'])} passed"
            )
        print(f"runtime {display}: {runtime_pass}/{runtime_count} passed")
        if runtime_count == 0:
            failures.append(f"{display} runtime discovered and executed zero tests")

    if available == 0:
        print(
            "No lupa runtimes available. Install with: "
            "python -m pip install -r tests/requirements.txt",
            file=sys.stderr,
        )
        return 1

    if len(vectors_by_runtime) == 2:
        left = vectors_by_runtime["lua51"]
        right = vectors_by_runtime["luajit21"]
        for key in sorted(set(left) | set(right)):
            if left.get(key) != right.get(key):
                failures.append(
                    f"vector mismatch {key}: lua51={left.get(key)!r} luajit21={right.get(key)!r}"
                )
    elif args.require_all:
        failures.append("cross-runtime vector comparison requires both runtimes")

    for runtime_vectors in vectors_by_runtime.values():
        for key, value in sorted(runtime_vectors.items()):
            suffix = key.rsplit("::", 1)[-1]
            expected = EXPECTED_VECTORS.get(suffix)
            if expected is not None and value != expected:
                failures.append(f"vector oracle {key}: got {value!r}, expected {expected!r}")

    print(f"unique cases: {len(unique_names)}")
    print(f"total case executions: {total_executions}")
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
