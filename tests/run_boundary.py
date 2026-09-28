#!/usr/bin/env python3
"""Milestone 2 execution-boundary test harness.

Runs the trusted action broker inside lupa Lua 5.1 and LuaJIT 2.1 fixtures, and
exercises the standalone policy worker as a real subprocess with one bounded
JSON request per case. No game files, Mods directory, network or live install is
touched. Independent of the observation/action harness.
"""
from __future__ import annotations

import argparse
import importlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BOUNDARY = REPO / "tests" / "boundary"
RUNNER = BOUNDARY / "runner.lua"
WORKER = REPO / "tools" / "policy_worker.py"
HELPER = REPO / "tools" / "lua" / "policy_env.lua"
BROKER = REPO / "AISparring" / "integration" / "action_broker.lua"
GUIDE = REPO / "docs" / "M2_EXECUTION_BOUNDARY.md"

RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]
WORKER_TIMEOUT = 10.0
WORKER_MAX_INPUT_BYTES = 2 * 1024 * 1024

BROKER_FORBIDDEN = ["SMODS", "MP.", "Client", "require(", "os.", "io.", "G.", "love."]


def static_cases() -> list[dict]:
    cases: list[dict] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        cases.append({"name": name, "ok": bool(ok), "detail": detail})

    add("boundary_files_present", all(p.is_file() for p in (BROKER, WORKER, HELPER, RUNNER, GUIDE)))

    broker_src = BROKER.read_text(encoding="utf-8") if BROKER.is_file() else ""
    worker_src = WORKER.read_text(encoding="utf-8") if WORKER.is_file() else ""
    helper_src = HELPER.read_text(encoding="utf-8") if HELPER.is_file() else ""

    add("broker_declares_executor_disabled", "executor_disabled" in broker_src)
    # Production snapshots the trusted capture function at authorization. The
    # handle and epoch must still come from one invocation, not separate reads.
    add("broker_atomic_capture_epoch", "local ok, handle, epoch = pcall(capture_fn)" in broker_src
        and 'local capture_port = rawget(ports, "capture")' in broker_src)
    add("broker_rechecks_after_validator", "canonical_end" in broker_src and "epoch_end" in broker_src)
    add("broker_single_pending_token", "pending_token" in broker_src and "pending_record" in broker_src)
    offenders = [token for token in BROKER_FORBIDDEN if token in broker_src]
    add("broker_no_game_globals", not offenders, ",".join(offenders))

    keys_match = re.search(r"REQUEST_KEYS\s*=\s*\{([^}]*)\}", worker_src)
    keys = set(re.findall(r'"([a-z_]+)"', keys_match.group(1))) if keys_match else set()
    add("worker_protocol_keys", keys == {"runtime", "source", "observation"}, str(sorted(keys)))
    add("worker_requires_memory_limit", "max_memory=MAX_MEMORY_BYTES" in worker_src)
    add("worker_no_inspect_signature", "inspect" not in worker_src)
    add("worker_clears_python_global", 'globals_table["python"] = None' in worker_src)
    add("worker_hardens_runtime_fail_closed",
        "_harden_runtime" in worker_src and 'loaded["python"] = None' in worker_src
        and "policy_env_hardening_failed" in worker_src)
    add("broker_fixture_sentinel", '"M2_FIXTURE_ONLY"' in broker_src)
    add("helper_engine_tripwire", "engine_vm_present" in helper_src and '"G", "MP", "SMODS", "love"' in helper_src)
    add("helper_source_cap", "MAX_SOURCE_BYTES" in helper_src)
    add("helper_jit_off_guarded", "(not engine_vm_present()) and jit" in helper_src)
    add("helper_format_guard",
        "FORMAT_CONVERSIONS" in helper_src and "policy_bad_format_argument" in helper_src)

    add("helper_loads_only_trusted_modules", all(
        name in helper_src for name in ("ai/codec.lua", "ai/observation.lua", "ai/actions.lua")
    ))
    add("helper_saves_and_restores_hook", "debug.gethook()" in helper_src and "debug.sethook(prev_hook" in helper_src)
    add("helper_no_pcall_in_policy_env", "env.pcall" not in helper_src)
    add("helper_revalidates_selection", "ActionSet.validate" in helper_src)
    add("broker_exception_safe_guard", "pcall(fn, ...)" in broker_src and "broker_internal_error" in broker_src)
    add("helper_string_metatable_whitelist",
        "string_meta.__index = strlib" in helper_src and "bounded_rep" in helper_src)
    add("worker_normalizes_action_arrays",
        "ACTION_ARRAY_FIELDS" in worker_src and "_normalize_action" in worker_src)

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
    runner = lua.globals()["ais_run_boundary_one"]
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


def valid_export() -> dict:
    return {
        "schema_version": 1,
        "phase": "PLAY_HAND",
        "match": {
            "ruleset": "majorleague",
            "ante": 1,
            "round": 1,
            "lives": 1,
            "hands_per_round": 4,
            "discards_per_round": 3,
            "hand_size": 8,
            "joker_slots": 5,
            "consumable_slots": 2,
        },
        "self": {
            "money": 10,
            "credit_limit": 0,
            "hands": 3,
            "discards": 3,
            "current_score": "0",
            "blind_requirement": "300",
            "hand_visible": True,
            "hand": [
                {"id": "hand:1", "face_down": False, "kind": "card", "rank": "A", "suit": "Spades", "center": "c_ace"},
                {"id": "hand:2", "face_down": False, "kind": "card", "rank": "K", "suit": "Hearts", "center": "c_king"},
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
            "items": [{"type": "PLAY_CARDS", "certified": True, "card_refs": ["hand:1"]}],
        },
    }


def expect_action(action_type: str):
    def check(response: dict):
        if response.get("ok") is not True:
            return False, f"ok=false code={response.get('code')}"
        action = response.get("action")
        if not isinstance(action, dict):
            return False, "action is not an object"
        if action.get("type") != action_type:
            return False, f"type={action.get('type')}"
        return True, ""

    return check


def expect_code(code: str):
    def check(response: dict):
        if response.get("ok") is not False:
            return False, "ok is not false"
        if response.get("code") != code:
            return False, f"code={response.get('code')}"
        return True, ""

    return check


def expect_code_in(codes):
    def check(response: dict):
        if response.get("ok") is not False:
            return False, "ok is not false"
        if response.get("code") not in codes:
            return False, f"code={response.get('code')}"
        return True, ""

    return check


ESCAPE_SOURCE = (
    "return function(observation, actions) "
    "local bad = (_G ~= nil) or (type(getfenv) ~= 'nil') or (type(setfenv) ~= 'nil') "
    "or (type(require) ~= 'nil') or (type(package) ~= 'nil') or (type(io) ~= 'nil') "
    "or (type(os) ~= 'nil') or (type(debug) ~= 'nil') or (type(G) ~= 'nil') "
    "or (type(MP) ~= 'nil') or (type(SMODS) ~= 'nil') or (type(Client) ~= 'nil') "
    "or (type(python) ~= 'nil') or (type(loadstring) ~= 'nil') or (type(load) ~= 'nil') "
    "or (type(dofile) ~= 'nil') or (type(pcall) ~= 'nil') "
    "or (string.dump ~= nil) or (math.random ~= nil) "
    "if bad then return { type = 'LEAVE_SHOP' } end "
    "if ('x').dump ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if ('ab'):rep(2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
    "if ('x').aisparring ~= nil then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

STRING_ROUTE_SOURCE = (
    "return function(observation, actions) "
    "if string.dump ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if ('x').dump ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if ('ab'):rep(2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
    "if string.rep('ab', 2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
    "if ('AB'):lower() ~= 'ab' then return { type = 'LEAVE_SHOP' } end "
    "if string.format('%d', 7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

STRING_REP_EDGE_SOURCE = (
    "return function(observation, actions) "
    "if string.rep('', 65536) ~= '' then return { type = 'LEAVE_SHOP' } end "
    "if ('x'):rep(0) ~= '' then return { type = 'LEAVE_SHOP' } end "
    "if string.rep('ab', 3) ~= 'ababab' then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

TOSTRING_SOURCE = (
    "return function(observation, actions) "
    "if tostring(7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
    "if tostring('x') ~= 'x' then return { type = 'LEAVE_SHOP' } end "
    "if tostring(true) ~= 'true' then return { type = 'LEAVE_SHOP' } end "
    "if tostring(nil) ~= 'nil' then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

FORMAT_PRIMITIVES_SOURCE = (
    "return function(observation, actions) "
    "if string.format('%d/%s/%.2f', 7, 'x', 1.5) ~= '7/x/1.50' then return { type = 'LEAVE_SHOP' } end "
    "if string.format('%%') ~= '%' then return { type = 'LEAVE_SHOP' } end "
    "if ('%d'):format(7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

SECRET_SOURCE = (
    "return function(observation, actions) "
    "if observation.secret_token ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if observation.pvp_timer_order ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if observation.self.secret ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if observation.self.deck_order ~= nil then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)


def poisoned_export() -> dict:
    export = valid_export()
    export["secret_token"] = "leak"
    export["pvp_timer_order"] = [1, 2]
    export["self"]["secret"] = "leak"
    export["self"]["deck_order"] = ["hand:1"]
    return export


def redacted_export() -> dict:
    export = valid_export()
    export["self"]["hand"][0] = {"id": "hand:1", "redacted": True}
    return export


def opponent_export() -> dict:
    export = valid_export()
    export["opponent"] = {"displayed_score": "42", "hands": 4, "lives": 1}
    return export


def consumable_export() -> dict:
    return {
        "schema_version": 1,
        "phase": "CONSUMABLE_SELECTION",
        "match": valid_export()["match"],
        "self": {
            "money": 10,
            "credit_limit": 0,
            "hands": 3,
            "discards": 3,
            "current_score": "0",
            "blind_requirement": "300",
            "hand_visible": False,
            "jokers": [],
            "consumables": [{"id": "consumable:1", "face_down": False, "center": "c_hermit"}],
            "vouchers": [],
            "tags": [],
            "deck": {"total": 52},
        },
        "context": {
            "blocked": False,
            "timer_expired": False,
            "target_selection": True,
            "min_targets": 0,
            "max_targets": 2,
        },
        "consumable_target": {
            "source": {"id": "source:1", "face_down": False, "center": "c_hermit"},
            "source_ref": "consumable:1",
            "min_targets": 0,
            "max_targets": 2,
            "targets": [
                {"id": "target:1", "face_down": False, "kind": "card", "rank": "A", "suit": "Spades", "center": "c_ace"},
            ],
        },
        "certificates": {
            "version": 1,
            "items": [{"type": "USE_CONSUMABLE", "certified": True, "source_ref": "consumable:1", "target_refs": []}],
        },
    }


def expect_consumable_wire():
    def check(response: dict):
        ok, detail = expect_action("USE_CONSUMABLE")(response)
        if not ok:
            return ok, detail
        action = response["action"]
        if action.get("source_ref") != "consumable:1":
            return False, f"source_ref={action.get('source_ref')}"
        targets = action.get("target_refs")
        if not isinstance(targets, list) or targets != []:
            return False, f"target_refs={targets!r}"
        return True, ""

    return check


def expect_memory_failure():
    def check(response: dict):
        if response.get("ok") is not False:
            return False, "ok is not false"
        if response.get("code") != "policy_runtime_error":
            return False, f"code={response.get('code')}"
        if "action" in response:
            return False, "action present on failure"
        return True, ""

    return check


REDACTED_PROBE_SOURCE = (
    "return function(observation, actions) "
    "if observation.self.hand[1].redacted ~= true then return { type = 'LEAVE_SHOP' } end "
    "if observation.self.hand[1].center ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if observation.self.hand[1].rank ~= nil then return { type = 'LEAVE_SHOP' } end "
    "if observation.self.hand[1].suit ~= nil then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)

OPPONENT_PROBE_SOURCE = (
    "return function(observation, actions) "
    "if type(observation.opponent) ~= 'table' then return { type = 'LEAVE_SHOP' } end "
    "if observation.opponent.displayed_score ~= '42' then return { type = 'LEAVE_SHOP' } end "
    "if observation.opponent.hands ~= 4 then return { type = 'LEAVE_SHOP' } end "
    "if observation.opponent.location ~= nil then return { type = 'LEAVE_SHOP' } end "
    "return actions[1] end"
)


def worker_cases() -> list[dict]:
    select_first = "return function(observation, actions) return actions[1] end"
    cases = [
        {"name": "worker_selects_valid_action", "source": select_first, "check": expect_action("PLAY_CARDS")},
        {"name": "worker_rejects_extra_actions_key", "source": select_first,
         "extra": {"actions": [{"type": "REROLL"}]}, "check": expect_code("policy_bad_input")},
        {"name": "worker_rejects_missing_observation", "source": select_first,
         "omit_observation": True, "check": expect_code("policy_bad_input")},
        {"name": "worker_rejects_non_object_observation", "source": select_first,
         "observation": [], "check": expect_code("policy_bad_input")},
        {"name": "worker_rejects_bad_runtime", "source": select_first,
         "request_runtime": "julia", "run_once": True, "check": expect_code("policy_bad_runtime")},
        {"name": "worker_rejects_empty_source", "source": "", "check": expect_code("policy_bad_source")},
        {"name": "worker_rejects_bytecode_source", "source": "\x1bLuaQpolicybytes",
         "check": expect_code("policy_bad_source")},
        {"name": "worker_rejects_malformed_json", "raw": b"this is not json",
         "run_once": True, "check": expect_code("policy_bad_input")},
        {"name": "worker_compile_failure", "source": "this is not valid lua !!!",
         "check": expect_code("policy_compile_failed")},
        {"name": "worker_load_failure", "source": "return 5", "check": expect_code("policy_load_failed")},
        {"name": "worker_no_action", "source": "return function() return nil end",
         "check": expect_code("policy_no_action")},
        {"name": "worker_index_out_of_range", "source": "return function(observation, actions) return 99 end",
         "check": expect_code("policy_bad_index")},
        {"name": "worker_forged_action_rejected",
         "source": "return function(observation, actions) return { type = 'LEAVE_SHOP' } end",
         "check": expect_code("policy_bad_action")},
        {"name": "worker_candidate_mutation_rejected",
         "source": "return function(observation, actions) actions[1].card_refs[1] = 'hand:999'; return actions[1] end",
         "check": expect_code("policy_bad_action")},
        {"name": "worker_nested_closure_rejected",
         "source": "return function() return { f = function() end } end",
         "check": expect_code("policy_bad_action")},
        {"name": "worker_cycle_result_rejected",
         "source": "return function() local t = {}; t.self = t; return t end",
         "check": expect_code("policy_bad_action")},
        {"name": "worker_runtime_error_bounded",
         "source": "return function() local t = nil; return t.y end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_escape_blocked", "source": ESCAPE_SOURCE, "check": expect_action("PLAY_CARDS")},
        {"name": "worker_extra_fields_sanitized", "source": SECRET_SOURCE,
         "observation": None, "use_poisoned": True, "check": expect_action("PLAY_CARDS")},
        {"name": "worker_loop_budget",
         "source": "return function() while true do end end",
         "check": expect_code_in({"policy_budget_exceeded"})},
        {"name": "worker_memory_16m_ok",
         "source": "return function(observation, actions) local s = ('x'):rep(65536); "
                   "for i = 1, 8 do s = s .. s end; return actions[1] end",
         "check": expect_action("PLAY_CARDS")},
        {"name": "worker_memory_128m_fails",
         "source": "return function(observation, actions) local s = ('x'):rep(65536); "
                   "for i = 1, 11 do s = s .. s end; return actions[1] end",
         "check": expect_memory_failure()},
        {"name": "worker_oversized_input_file",
         "input_file_bytes": WORKER_MAX_INPUT_BYTES + 16, "run_once": True,
         "check": expect_code("policy_input_too_large")},
        {"name": "worker_redacted_card_stays_redacted", "source": REDACTED_PROBE_SOURCE,
         "observation": redacted_export(), "check": expect_action("PLAY_CARDS")},
        {"name": "worker_public_opponent_preserved", "source": OPPONENT_PROBE_SOURCE,
         "observation": opponent_export(), "check": expect_action("PLAY_CARDS")},
        {"name": "worker_consumable_source_ref_preserved", "source": select_first,
         "observation": consumable_export(), "check": expect_consumable_wire()},
        {"name": "worker_no_caller_action_authority", "source": select_first,
         "extra": {"actions": [{"type": "REROLL"}]}, "check": expect_code("policy_bad_input")},
        {"name": "worker_string_routes_share_whitelist", "source": STRING_ROUTE_SOURCE,
         "check": expect_action("PLAY_CARDS")},
        {"name": "worker_string_rep_bound_direct",
         "source": "return function() local s = string.rep('x', 100000000); return nil end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_string_rep_bound_indirect",
         "source": "return function() local s = ('x'):rep(100000000); return nil end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_string_rep_empty_count_bound",
         "source": "return function() local s = string.rep('', 100000000); return nil end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_string_rep_edge_ok", "source": STRING_REP_EDGE_SOURCE,
         "check": expect_action("PLAY_CARDS")},
        {"name": "worker_tostring_primitives_ok", "source": TOSTRING_SOURCE,
         "check": expect_action("PLAY_CARDS")},
        {"name": "worker_tostring_table_rejected",
         "source": "return function() return tostring({}) end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_table_arg_rejected",
         "source": "return function() return string.format('%s', {}) end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_function_arg_rejected",
         "source": "return function() return ('%s'):format(function() end) end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_pointer_rejected",
         "source": "return function() return string.format('%p', 'x') end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_pointer_method_rejected",
         "source": "return function() return ('%p'):format('x') end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_pointer_width_rejected",
         "source": "return function() return string.format('%5p', 1) end",
         "check": expect_code("policy_runtime_error")},
        {"name": "worker_format_primitives_ok", "source": FORMAT_PRIMITIVES_SOURCE,
         "check": expect_action("PLAY_CARDS")},
        {"name": "worker_rejects_oversized_source", "source": "x" * 70000,
         "run_once": True, "request_runtime": "lua51", "check": expect_code("policy_bad_source")},
    ]
    return cases


def build_request(case: dict, runtime: str) -> dict:
    request: dict = {"runtime": case.get("request_runtime") or runtime, "source": case["source"]}
    if not case.get("omit_observation") and "observation" not in case:
        request["observation"] = valid_export()
    elif "observation" in case and case["observation"] is not None:
        request["observation"] = case["observation"]
    elif case.get("use_poisoned"):
        request["observation"] = poisoned_export()
    for key, value in case.get("extra", {}).items():
        request[key] = value
    return request


def _decode_worker_stdout(proc):
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        return None, f"exit={proc.returncode}"
    if "Traceback" in text or ".lua" in text or "C:" in text or "/" in text or "\\" in text:
        return None, "unsafe_response_text"
    try:
        return json.loads(text), None
    except Exception:  # noqa: BLE001
        return None, "invalid_json"


def run_worker_process(case: dict, runtime: str):
    if case.get("input_file_bytes") is not None:
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "request.json"
                path.write_bytes(b"x" * case["input_file_bytes"])
                proc = subprocess.run(
                    [sys.executable, str(WORKER), "--input", str(path)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=WORKER_TIMEOUT,
                )
        except subprocess.TimeoutExpired:
            return None, "timeout"
        return _decode_worker_stdout(proc)
    raw = case.get("raw")
    if raw is None:
        raw = json.dumps(build_request(case, runtime)).encode("utf-8")
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
    return _decode_worker_stdout(proc)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring Milestone 2 boundary harness")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when a requested runtime or the worker is unavailable")
    args = parser.parse_args(argv)

    print("AISparring Milestone 2 boundary harness")
    print(f"repository: {REPO}")

    failures: list[str] = []
    unique_names: set[str] = set()
    total_executions = 0

    statics = static_cases()
    static_passed = sum(1 for case in statics if case["ok"])
    for case in statics:
        unique_names.add(f"static::{case['name']}")
    total_executions += len(statics)
    print(f"static boundary checks: {static_passed}/{len(statics)} passed")
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
    test_files = sorted(BOUNDARY.glob("test_*.lua"))
    if not test_files:
        print(f"no Lua boundary tests in {BOUNDARY}", file=sys.stderr)
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

    if available == 0 and not args.require_all:
        print("No lupa runtimes available; skipping subprocess policy cases.")
    else:
        worker_passes = 0
        worker_count = 0
        for case in worker_cases():
            runtimes = ["single"] if case.get("run_once") else ["lua51", "luajit21"]
            for runtime in runtimes:
                worker_count += 1
                total_executions += 1
                label = f"worker[{runtime}]::{case['name']}"
                unique_names.add(f"worker::{case['name']}")
                response, error = run_worker_process(case, runtime)
                if response is None:
                    print(f"FAIL {label} :: {error}")
                    failures.append(f"{label} :: {error}")
                    continue
                ok, detail = case["check"](response)
                if ok:
                    worker_passes += 1
                    print(f"PASS {label}")
                else:
                    print(f"FAIL {label} :: {detail}")
                    failures.append(f"{label} :: {detail}")
        print(f"worker subprocess cases: {worker_passes}/{worker_count} passed")
        if worker_count == 0:
            failures.append("worker subprocess suite executed zero cases")

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
