#!/usr/bin/env python3
"""Baseline policy harness.

Runs the real generated baseline policy source through the restricted policy
environment and the standalone subprocess worker under lupa's Lua 5.1 and LuaJIT
2.1 runtimes. It loads only repository modules (`AISparring/ai/*.lua`,
`tools/lua/policy_env.lua`, `tools/policy_worker.py`); no game, Mods directory,
network or live runtime is touched.

Cross-runtime chosen-action vectors are recorded and compared exactly, and a
subprocess round trip proves the generated source is loadable by the existing
restricted policy worker.
"""
from __future__ import annotations

import argparse
import importlib
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
POLICY_DIR = REPO / "tests" / "policy"
RUNNER = POLICY_DIR / "runner.lua"
MODULE = REPO / "AISparring" / "ai" / "baseline_policy.lua"
DOC = REPO / "docs" / "BASELINE_POLICY.md"
WORKER = REPO / "tools" / "policy_worker.py"

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]
DIFFICULTIES = ("rookie", "competitive", "major_league")
WORKER_TIMEOUT = 10.0

PROHIBITED_PATTERNS = [
    (r"\brequire\b", "require"),
    (r"\bdofile\b", "dofile"),
    (r"\bloadstring\b", "loadstring"),
    (r"(?<![\w.])load\s*\(", "load"),
    (r"\bsetfenv\b", "setfenv"),
    (r"\bgetfenv\b", "getfenv"),
    (r"\brawset\b", "rawset"),
    (r"\bcollectgarbage\b", "collectgarbage"),
    (r"\bdebug\s*[.:]", "debug"),
    (r"\bio\s*[.:]", "io"),
    (r"\bos\s*[.:]", "os"),
    (r"\bmath\s*\.\s*random", "math.random"),
    (r"\blove\s*\.", "love"),
    (r"\bSMODS\b", "SMODS"),
    (r"(?<![\w.])G(?![\w])", "G"),
    (r"(?<![\w.])MP(?![\w])", "MP"),
    (r"\b_G\b", "_G"),
    (r"\bpackage\b", "package"),
    (r"\bstring\s*\.\s*dump\b", "string.dump"),
    (r"\bClient\b", "Client"),
]

_LINE_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
_SHORT_COMMENT = re.compile(r"--[^\n]*")


def strip_comments(source: str) -> str:
    """Remove Lua long and line comments so the scanner sees code only."""
    without_long = _LINE_COMMENT.sub(" ", source)
    return _SHORT_COMMENT.sub(" ", without_long)


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    required = [MODULE, DOC, RUNNER, WORKER]
    missing = [str(path.relative_to(REPO)) for path in required if not path.is_file()]
    add("policy_files_present", not missing, ",".join(missing))

    tests = sorted(POLICY_DIR.glob("test_*.lua")) if POLICY_DIR.is_dir() else []
    add("policy_lua_tests_present", len(tests) >= 4, f"{len(tests)} files")

    body = MODULE.read_text(encoding="utf-8") if MODULE.is_file() else ""
    code = strip_comments(body)
    offenders = [label for pattern, label in PROHIBITED_PATTERNS if re.search(pattern, code)]
    add("policy_module_no_forbidden_apis", not offenders, ",".join(offenders))

    add("policy_module_declares_source", "function BaselinePolicy.source" in body)
    add("policy_module_declares_difficulties", all(name in body for name in DIFFICULTIES))
    add("policy_module_declares_factory_names", "local CONFIGS" in body and "TEMPLATE" in body)

    doc = DOC.read_text(encoding="utf-8") if DOC.is_file() else ""
    add("policy_doc_invocation", "PolicyEnv.run" in doc and "policy_worker.py" in doc)
    add("policy_doc_difficulties", all(name in doc for name in DIFFICULTIES))
    add("policy_doc_contract", "function(observation, actions)" in doc)

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
    runner = lua.globals()["ais_run_policy_one"]
    result = runner(REPO.as_posix(), test_file.as_posix())

    rows = []
    raw_cases = result["cases"]
    if raw_cases is not None:
        for row in raw_cases.values():
            err = row["err"]
            rows.append(
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
    return rows, vectors


def generate_sources(runtime_factory) -> dict:
    lua = runtime_factory(unpack_returned_tuples=True)
    lua.execute(
        "function ais_policy_sources(repo) "
        "local mod = dofile(repo .. '/AISparring/ai/baseline_policy.lua') "
        "return mod.source('rookie'), mod.source('competitive'), mod.source('major_league') end"
    )
    values = lua.globals()["ais_policy_sources"](REPO.as_posix())
    return {"rookie": values[0], "competitive": values[1], "major_league": values[2]}


def valid_export() -> dict:
    return {
        "schema_version": 1,
        "phase": "PLAY_HAND",
        "match": {
            "ruleset": "majorleague",
            "blind": "Small Blind",
            "timer": "120",
            "ante": 1,
            "round": 1,
            "lives": 4,
            "hands_per_round": 4,
            "discards_per_round": 3,
            "hand_size": 8,
            "joker_slots": 5,
            "consumable_slots": 2,
        },
        "self": {
            "money": 10,
            "credit_limit": 0,
            "hands": 4,
            "discards": 3,
            "current_score": "0",
            "blind_requirement": "300",
            "hand_visible": True,
            "hand": [
                {"id": "hand:1", "face_down": False, "kind": "card", "rank": "Ace", "suit": "Spades", "center": "c_ace"},
                {"id": "hand:2", "face_down": False, "kind": "card", "rank": "King", "suit": "Hearts", "center": "c_king"},
            ],
            "jokers": [],
            "consumables": [],
            "vouchers": [],
            "tags": [],
            "deck": {"total": 52},
        },
        "context": {
            "blocked": False,
            "timer_expired": False,
            "target_selection": False,
            "max_play": 5,
            "max_discard": 5,
        },
        "certificates": {
            "version": 1,
            "items": [
                {"type": "PLAY_CARDS", "certified": True, "card_refs": ["hand:1"]},
                {"type": "PLAY_CARDS", "certified": True, "card_refs": ["hand:1", "hand:2"]},
            ],
        },
    }


def run_worker(runtime: str, source: str, observation: dict):
    request = {"runtime": runtime, "source": source, "observation": observation}
    raw = json.dumps(request).encode("utf-8")
    try:
        proc = subprocess.run(
            [sys.executable, str(WORKER)],
            input=raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=WORKER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if proc.returncode != 0:
        return None, f"exit={proc.returncode}"
    text = proc.stdout.decode("utf-8", "replace")
    if "Traceback" in text:
        return None, "unsafe_response_text"
    try:
        return json.loads(text), None
    except Exception:  # noqa: BLE001
        return None, "invalid_json"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring baseline policy harness")
    parser.add_argument("--require-all", action="store_true", help="fail when a runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring baseline policy harness")
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
    test_files = sorted(POLICY_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua policy tests in {POLICY_DIR}", file=sys.stderr)
        return 1

    vectors_by_runtime: dict[str, dict[str, str]] = {}
    available = 0
    first_factory = None
    available_displays: list[str] = []

    for display, module_name in RUNTIMES:
        runtime_factory, error = load_runtime(module_name)
        if runtime_factory is None:
            print(f"runtime {display}: SKIPPED ({error})")
            if args.require_all:
                failures.append(f"{display} runtime required but unavailable ({error})")
            continue
        available += 1
        available_displays.append(display)
        if first_factory is None:
            first_factory = runtime_factory
        vectors_by_runtime[display] = {}
        runtime_pass = 0
        runtime_count = 0
        for test_file in test_files:
            try:
                rows, vectors = run_file(runtime_factory, runner_src, test_file)
            except Exception as exc:  # noqa: BLE001
                unique_names.add(f"harness::{test_file.stem}")
                total_executions += 1
                failures.append(f"{display} harness::{test_file.stem} :: {exc}")
                continue
            for key, value in vectors.items():
                vectors_by_runtime[display][f"{test_file.stem}::{key}"] = value
            for row in rows:
                name = str(row["name"])
                runtime_count += 1
                total_executions += 1
                unique_names.add(name)
                if row["ok"]:
                    runtime_pass += 1
                else:
                    failures.append(f"{display} {name} :: {row['err']}")
                    print(f"FAIL {display}::{name} :: {row['err']}")
            print(f"runtime {display} {test_file.stem}: {sum(1 for r in rows if r['ok'])}/{len(rows)} passed")
        print(f"runtime {display}: {runtime_pass}/{runtime_count} passed")
        if runtime_count == 0:
            failures.append(f"{display} runtime discovered and executed zero tests")

    if available == 0:
        print(
            "No lupa runtimes available. Install with: python -m pip install -r tests/requirements.txt",
            file=sys.stderr,
        )
        return 1

    if len(vectors_by_runtime) == 2:
        left = vectors_by_runtime["lua51"]
        right = vectors_by_runtime["luajit21"]
        for key in sorted(set(left) | set(right)):
            if left.get(key) != right.get(key):
                failures.append(f"vector mismatch {key}: lua51={left.get(key)!r} luajit21={right.get(key)!r}")
    elif args.require_all:
        failures.append("cross-runtime vector comparison requires both runtimes")

    if first_factory is not None:
        try:
            sources = generate_sources(first_factory)
        except Exception as exc:  # noqa: BLE001
            sources = None
            failures.append(f"policy_source_generation :: {exc}")
        if sources is not None:
            for difficulty in DIFFICULTIES:
                source = sources.get(difficulty)
                if not isinstance(source, str) or not source:
                    failures.append(f"worker::{difficulty} :: missing source")
                    continue
                for runtime in available_displays:
                    label = f"worker[{runtime}]::policy_{difficulty}"
                    unique_names.add(f"worker::policy_{difficulty}")
                    total_executions += 1
                    response, error = run_worker(runtime, source, valid_export())
                    if response is None:
                        print(f"FAIL {label} :: {error}")
                        failures.append(f"{label} :: {error}")
                        continue
                    if response.get("ok") is not True:
                        print(f"FAIL {label} :: ok=false code={response.get('code')}")
                        failures.append(f"{label} :: ok=false code={response.get('code')}")
                        continue
                    action = response.get("action")
                    if not isinstance(action, dict) or action.get("type") != "PLAY_CARDS":
                        print(f"FAIL {label} :: action={action!r}")
                        failures.append(f"{label} :: action={action!r}")
                        continue
                    print(f"PASS {label}")

    print(f"unique cases: {len(unique_names)}")
    print(f"total executions: {total_executions}")
    print(f"runtimes available: {available}")

    for failure in failures:
        print(f"FAIL {failure}")

    if failures:
        print(f"RESULT: FAIL ({len(failures)} failing cases)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
