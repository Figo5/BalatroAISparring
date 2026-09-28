#!/usr/bin/env python3
"""Root companion wiring test harness.

Static source checks plus the Lua fixture suite in tests/companion/ run under
lupa's Lua 5.1 and LuaJIT 2.1. The real AISparring/integration/companion_host.lua,
the reviewed menu modules and (for staged cases) the real runtime modules are
loaded; only the game environment (globals, marker, identity, transport,
channels) is fake. No game, Mods directory, process, socket, thread, network or
live runtime is touched.
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
COMPANION_DIR = REPO / "tests" / "companion"
RUNNER = COMPANION_DIR / "runner.lua"
SUPPORT = COMPANION_DIR / "support.lua"
COMPANION_HOST = MOD_DIR / "integration" / "companion_host.lua"
WIRE_JSON = MOD_DIR / "integration" / "wire_json.lua"
SMODS_JSON = REPO / "work" / "reference" / "offline" / "smods-json.lua"
CORE = MOD_DIR / "core.lua"
CONFIG = MOD_DIR / "config.lua"
GUIDE = REPO / "docs" / "COMPANION_BOOTSTRAP.md"

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

# The companion host must never originate a process or a shell. Loopback
# sockets and a bounded LÖVE worker are the only transport.
PROHIBITED_PATTERNS = [
    (r"os\.execute", "os.execute"),
    (r"io\.popen", "io.popen"),
    (r"taskkill", "taskkill"),
    (r"CreateProcess", "CreateProcess"),
    (r"subprocess", "subprocess"),
    (r"\bTerminateProcess\b", "TerminateProcess"),
    (r"\bOpenProcess\b[^\n]*PROCESS_TERMINATE", "terminate handle"),
    (r"\bpackage\b", "package"),
    (r"\brequire\s*\(", "require"),
    (r"\bdofile\b", "dofile"),
    (r"\bloadstring\b", "loadstring"),
    (r"\bdebug\s*[.:]", "debug"),
]


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    required = [COMPANION_HOST, WIRE_JSON, CORE, CONFIG, RUNNER, SUPPORT, GUIDE]
    missing = [path.name for path in required if not path.is_file()]
    add("companion_files_present", not missing, ",".join(missing))

    host_src = COMPANION_HOST.read_text(encoding="utf-8") if COMPANION_HOST.is_file() else ""
    core_src = CORE.read_text(encoding="utf-8") if CORE.is_file() else ""
    config_src = CONFIG.read_text(encoding="utf-8") if CONFIG.is_file() else ""
    guide_src = GUIDE.read_text(encoding="utf-8") if GUIDE.is_file() else ""

    offenders = [label for pattern, label in PROHIBITED_PATTERNS if re.search(pattern, host_src)]
    add("companion_host_no_process_or_shell_apis", not offenders, ";".join(offenders))

    add("companion_host_loopback_only", '"127.0.0.1"' in host_src and "aisparring.practice_host.discovery.v1" in host_src)
    add(
        "companion_host_validates_marker",
        all(token in host_src for token in ("MARKER_HOST", "MARKER_PORT", "MARKER_VERSION", "IDENTITY_STALE", "MARKER_ENUMS")),
    )
    add(
        "companion_host_bounds_channels",
        "max_send" in host_src and "max_receive" in host_src and "max_drain" in host_src,
    )
    add(
        "companion_host_wraps_update",
        "install_update" in host_src and "original(self, dt)" in host_src and "max_update_errors" in host_src,
    )
    add(
        "companion_host_uses_lobby_code_predicate",
        'rget(rget(MP, "LOBBY"), "code")' in host_src and "LOBBY.connected" not in host_src,
    )
    add(
        "companion_host_declares_strict_env_descriptors",
        all(
            name in host_src
            for name in (
                "BALATRO_AI_ROLE",
                "AISP_SESSION_ID",
                "AISP_ROLE_CREDENTIAL",
                "AISP_CONTROL_PORT",
                "AISP_EXPECTED_ROLE_SAVE_ROOT",
                "AISP_EXPECTED_ROLE_MODS_ROOT",
                "AISP_GAUNTLET",
            )
        )
        and "AISP_SEED" not in host_src
        and "AISP_EXPECTED_MOD_ROOT" not in host_src
        and "AISP_ROLE\"" not in host_src,
    )
    add(
        "companion_host_derives_attestation_path",
        "attestation_path" in host_src
        and "aisparring-launcher-attestation.json" in host_src
        and "STAGED_AWAITING_ATTESTATION" in host_src,
    )
    add(
        "wire_encoder_is_narrow_and_null_explicit",
        WIRE_JSON.is_file()
        and '"observation":' in WIRE_JSON.read_text(encoding="utf-8")
        and '"gauntlet":' in WIRE_JSON.read_text(encoding="utf-8"),
    )
    add(
        "core_loads_supported_json_require",
        'rawget(_G, "require")' in core_src and "integration/wire_json.lua" in core_src,
    )
    add(
        "companion_host_requires_independent_attestation",
        "launcher_attestation" in host_src and "check_attestation" in host_src and "STAGED_ATTESTATION_MISSING" in host_src,
    )
    add(
        "companion_host_never_exposes_capability",
        "production_factory" not in host_src and "mint" not in host_src,
    )
    add(
        "companion_host_stages_window_identity",
        all(
            token in host_src
            for token in (
                "Balatro AI Sparring 0.1.0-dev - Player",
                "Balatro AI Sparring 0.1.0-dev - AI runtime",
                "stage_window",
                "WINDOW_UNAVAILABLE",
                "WINDOW_FAILED",
                '"setTitle"',
                '"minimize"',
            )
        )
        and "setFocus" not in host_src
        and "restore" not in host_src
        and "window_focus" not in host_src,
    )
    add(
        "core_gates_on_flag_and_companion",
        "read_companion" in core_src and "ai.requested == true" in core_src and "integration/companion_host.lua" in core_src,
    )
    add(
        "core_loads_policy_modules_for_ai_only",
        "COMPANION_STAGED_AI" in core_src and 'if descriptors.role == "ai" then' in core_src,
    )
    add(
        "core_loads_common_codec_for_both_roles",
        "COMPANION_STAGED_CODEC" in core_src
        and "ai/codec.lua" in core_src
        and "codec = codec_module" in core_src
        and "modules.codec = policy" not in core_src,
    )
    add("config_default_disabled", bool(re.search(r"ai_enabled\s*=\s*false", config_src)))

    add(
        "companion_host_identity_handles_real_ffi",
        all(
            token in host_src
            for token in (
                "ffi_symbol",
                '"userdata"',
                '"cdata"',
                "PROCESS_QUERY_LIMITED_INFORMATION",
                "CloseHandle",
            )
        )
        and "TerminateProcess" not in host_src
        and 'type(kernel32) ~= "table"' not in host_src,
    )
    add(
        "core_resolves_ffi_via_safe_require",
        "native_ffi" in core_src
        and 'rawget(_G, "ffi")' in core_src
        and 'pcall(loader, "ffi")' in core_src,
    )

    add(
        "guide_documents_ports_and_nonclaims",
        "descriptor" in guide_src.lower()
        and "port" in guide_src.lower()
        and "not" in guide_src.lower()
        and "127.0.0.1" in guide_src,
    )

    test_files = sorted(COMPANION_DIR.glob("test_*.lua")) if COMPANION_DIR.is_dir() else []
    add("companion_test_files_present", len(test_files) >= 4, f"{len(test_files)} files")

    return cases


WIRE_LUA = """
local repo = %s
local smods = dofile(repo .. "/work/reference/offline/smods-json.lua")
local wire_mod = dofile(repo .. "/AISparring/integration/wire_json.lua")
assert(type(wire_mod) == "table" and type(wire_mod.factory) == "function", "wire module")
local wire = assert(wire_mod.factory(smods))
local service = wire.encode_service({
  session = "s", credential = "c", role = "ai", op = "hello", sequence = 1, observation = {},
})
local host = wire.encode_host({
  schema = "aisparring.practice_host.request.v1", op = "start", auth = "secret",
  request = { session_id = "s", difficulty = "rookie", pacing = "normal", mode = "normal",
              live_pid = 4242, live_create_time = 100000.0 },
})
local service_extra = wire.encode_service({
  session = "s", credential = "c", role = "ai", op = "hello", sequence = 1, observation = {}, extra = 1,
})
local host_extra = wire.encode_host({
  schema = "aisparring.practice_host.request.v1", op = "start", auth = "secret",
  request = { session_id = "s", difficulty = "rookie", pacing = "normal", mode = "normal",
              live_pid = 1, live_create_time = 2.5, extra = true },
})
return {
  base_empty = smods.encode({}),
  service = service,
  host = host,
  service_extra = service_extra == nil,
  host_extra = host_extra == nil,
}
"""


def wire_cases(runtime_factory) -> list:
    """Run the real SMODS codec + wire encoder, then parse the bytes in Python.

    Proves the shipped rxi library's empty-table-as-array / missing-null
    behaviour is neutralised by the narrow encoder, without any global JSON.
    """
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    lua = runtime_factory(unpack_returned_tuples=True)
    result = lua.execute(WIRE_LUA % json.dumps(REPO.as_posix()))
    base_empty = str(result["base_empty"])
    service_text = str(result["service"])
    host_text = str(result["host"])
    add("base_codec_encodes_empty_table_as_array", base_empty == "[]", base_empty)

    try:
        service = json.loads(service_text)
    except ValueError as exc:  # noqa: BLE001
        add("wire_service_is_valid_json", False, str(exc))
        service = {}
    else:
        add("wire_service_is_valid_json", True)
    add(
        "wire_service_exact_keys_and_object_observation",
        isinstance(service, dict)
        and set(service) == {"session", "credential", "role", "op", "sequence", "observation"}
        and isinstance(service.get("observation"), dict)
        and service.get("observation") == {},
    )

    try:
        host = json.loads(host_text)
    except ValueError as exc:  # noqa: BLE001
        add("wire_host_is_valid_json", False, str(exc))
        host = {}
    else:
        add("wire_host_is_valid_json", True)
    request = host.get("request") if isinstance(host, dict) else None
    add(
        "wire_host_exact_keys_and_explicit_null_gauntlet",
        isinstance(host, dict)
        and set(host) == {"schema", "op", "auth", "request"}
        and isinstance(request, dict)
        and set(request)
        == {"session_id", "difficulty", "pacing", "mode", "gauntlet", "live_pid", "live_create_time"}
        and request.get("gauntlet") is None,
    )
    add("wire_rejects_extra_service_key", result["service_extra"] is True)
    add("wire_rejects_extra_host_key", result["host_extra"] is True)

    # Feed the real host bytes into the real Python practice-host parser.
    try:
        tools_dir = REPO / "tools"
        if str(tools_dir) not in sys.path:
            sys.path.insert(0, str(tools_dir))
        import practice_host  # noqa: PLC0415

        parsed = practice_host.parse_json_line(host_text)
        add(
            "python_practice_host_parses_wire_host_request",
            set(parsed) == {"schema", "op", "auth", "request"}
            and parsed["request"].get("gauntlet") is None
            and set(parsed["request"]) == practice_host.START_REQUEST_KEYS,
        )
    except Exception as exc:  # noqa: BLE001
        add("python_practice_host_parses_wire_host_request", False, f"unavailable: {exc}")

    return cases


def load_runtime(module_name: str):
    try:
        module = importlib.import_module(module_name)
    except Exception as exc:  # noqa: BLE001
        return None, f"unavailable: {exc}"
    factory = getattr(module, "LuaRuntime", None) or module
    try:
        factory(unpack_returned_tuples=True)
    except Exception as exc:  # noqa: BLE001
        return None, f"runtime error: {exc}"
    return factory, None


def run_file(runtime_factory, runner_src: str, test_file: Path):
    lua = runtime_factory(unpack_returned_tuples=True)
    lua.execute(runner_src)
    runner = lua.globals()["ais_run_companion_one"]
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
    parser = argparse.ArgumentParser(description="AISparring companion wiring harness")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when any requested lupa runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring companion wiring harness")
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

    # Wire contract: real SMODS codec + real wire encoder, parsed in Python.
    wire_runtime = None
    for _display, module_name in RUNTIMES:
        candidate, _error = load_runtime(module_name)
        if candidate is not None:
            wire_runtime = candidate
            break
    if wire_runtime is not None:
        try:
            wcases = wire_cases(wire_runtime)
        except Exception as exc:  # noqa: BLE001
            wcases = [{"name": "wire_harness", "ok": False, "detail": str(exc)}]
        for case in wcases:
            unique_names.add(f"wire::{case['name']}")
            total_executions += 1
            if case["ok"]:
                print(f"PASS wire::{case['name']}")
            else:
                print(f"FAIL wire::{case['name']} :: {case['detail']}")
                failures.append(f"wire::{case['name']} :: {case['detail']}")
        print(f"wire checks: {sum(1 for c in wcases if c['ok'])}/{len(wcases)} passed")

    if not RUNNER.is_file():
        print(f"runner missing: {RUNNER}", file=sys.stderr)
        return 1

    runner_src = RUNNER.read_text(encoding="utf-8")
    test_files = sorted(COMPANION_DIR.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua test files in {COMPANION_DIR}", file=sys.stderr)
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
