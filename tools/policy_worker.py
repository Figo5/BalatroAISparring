#!/usr/bin/env python3
"""Bounded development policy worker (Milestone 2 capability proof).

Standalone, opt-in development tool. It reads one bounded JSON request and runs
the supplied text-only Lua source in a fresh, separate Lua interpreter under a
whitelist environment with an instruction budget. It writes only a bounded JSON
response; on success the single payload is the selected action record.

The worker never loads game state. It loads only the trusted repository modules
`AISparring/ai/codec.lua`, `observation.lua` and `actions.lua` into the fresh
interpreter. The observation supplied by the caller is treated as an untrusted
canonical export: it is re-sanitized through `Observation.observe`, legal actions
are regenerated from the trusted generator, and the policy's selection is
re-validated against the canonical handle. A supplied action list is never
trusted. This proves the direction of a separate-interpreter capability
boundary for project-owned code; it is not an OS/process sandbox against hostile
native exploits, and production launcher process/memory isolation plus real-game
IPC remain unimplemented and disabled.

Importing this module performs no work. Execution happens only through an
explicit development command (stdin request or --input PATH). Observation
inputs are not logged or persisted.

Request shape (all keys required, no unknowns):
  {"runtime": "lua51"|"luajit21",
   "source": "<text-only Lua source returning function(observation, actions)>",
   "observation": <canonical observation export from the trusted broker>}
"""
from __future__ import annotations

import argparse
import importlib
import json
import re
import sys
from pathlib import Path

MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_SOURCE_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = 64 * 1024
MAX_MODULE_BYTES = 1024 * 1024
MAX_MEMORY_BYTES = 64 * 1024 * 1024
MAX_DEPTH = 16

ALLOWED_RUNTIMES = ("lua51", "luajit21")
REQUEST_KEYS = {"runtime", "source", "observation"}
CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,63}$")

CODE_OK = "policy_ok"
CODE_BAD_INPUT = "policy_bad_input"
CODE_BAD_RUNTIME = "policy_bad_runtime"
CODE_BAD_SOURCE = "policy_bad_source"
CODE_INPUT_TOO_LARGE = "policy_input_too_large"
CODE_OUTPUT_TOO_LARGE = "policy_output_too_large"
CODE_HELPER_MISSING = "policy_helper_missing"
CODE_MODULE_MISSING = "policy_module_missing"
CODE_RUNTIME_UNAVAILABLE = "policy_runtime_unavailable"
CODE_MEMORY_UNSUPPORTED = "policy_memory_limit_unsupported"
CODE_ENV_HARDENING_FAILED = "policy_env_hardening_failed"
CODE_INTERNAL = "policy_internal_error"

TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parent
AI_DIR = REPO_DIR / "AISparring" / "ai"
HELPER_PATH = TOOLS_DIR / "lua" / "policy_env.lua"

MODULE_FILES = ("codec.lua", "observation.lua", "actions.lua")
ACTION_ARRAY_FIELDS = ("card_refs", "target_refs", "order")


class _WorkerError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _load_factory(runtime: str):
    try:
        module = importlib.import_module(f"lupa.{runtime}")
    except Exception:
        raise _WorkerError(CODE_RUNTIME_UNAVAILABLE)
    factory = getattr(module, "LuaRuntime", None)
    if factory is None:
        raise _WorkerError(CODE_RUNTIME_UNAVAILABLE)
    return factory


def _new_runtime(runtime: str):
    factory = _load_factory(runtime)
    try:
        lua = factory(
            register_eval=False,
            register_builtins=False,
            max_memory=MAX_MEMORY_BYTES,
        )
    except TypeError:
        raise _WorkerError(CODE_MEMORY_UNSUPPORTED)
    except Exception:
        raise _WorkerError(CODE_RUNTIME_UNAVAILABLE)
    _harden_runtime(lua)
    return lua


def _harden_runtime(lua) -> None:
    try:
        globals_table = lua.globals()
        globals_table["python"] = None
        globals_table["python_builtins"] = None
        package = globals_table["package"]
        if package is not None:
            loaded = package["loaded"]
            if loaded is not None:
                loaded["python"] = None
        if globals_table["python"] is not None or globals_table["python_builtins"] is not None:
            raise _WorkerError(CODE_ENV_HARDENING_FAILED)
    except _WorkerError:
        raise
    except Exception:
        raise _WorkerError(CODE_ENV_HARDENING_FAILED)


def _read_module(name: str) -> str:
    path = AI_DIR / name
    if not path.is_file():
        raise _WorkerError(CODE_MODULE_MISSING)
    try:
        data = path.read_bytes()
    except Exception:
        raise _WorkerError(CODE_MODULE_MISSING)
    if len(data) > MAX_MODULE_BYTES:
        raise _WorkerError(CODE_MODULE_MISSING)
    try:
        return data.decode("utf-8")
    except Exception:
        raise _WorkerError(CODE_MODULE_MISSING)


def _new_table(lua):
    return lua.execute("return function() return {} end")


def _to_lua(value, new_table, depth: int = 0):
    if depth > MAX_DEPTH:
        raise _WorkerError(CODE_BAD_INPUT)
    if value is None:
        raise _WorkerError(CODE_BAD_INPUT)
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        raise _WorkerError(CODE_BAD_INPUT)
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        table = new_table()
        for index, item in enumerate(value, start=1):
            table[index] = _to_lua(item, new_table, depth + 1)
        return table
    if isinstance(value, dict):
        table = new_table()
        for key, item in value.items():
            if not isinstance(key, str):
                raise _WorkerError(CODE_BAD_INPUT)
            table[key] = _to_lua(item, new_table, depth + 1)
        return table
    raise _WorkerError(CODE_BAD_INPUT)


def _from_lua(value, depth: int = 0):
    if depth > MAX_DEPTH:
        raise _WorkerError(CODE_BAD_INPUT)
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if not value.is_integer():
            raise _WorkerError(CODE_BAD_INPUT)
        return int(value)
    items = getattr(value, "items", None)
    if not callable(items):
        raise _WorkerError(CODE_BAD_INPUT)
    entries = list(value.items())
    keys = [key for key, _ in entries]
    if keys and all(isinstance(key, int) and not isinstance(key, bool) for key in keys):
        if sorted(keys) == list(range(1, len(keys) + 1)):
            ordered = dict(entries)
            return [_from_lua(ordered[index], depth + 1) for index in range(1, len(keys) + 1)]
    out: dict = {}
    for key, item in entries:
        if not isinstance(key, str):
            raise _WorkerError(CODE_BAD_INPUT)
        out[key] = _from_lua(item, depth + 1)
    return out


def _normalize_action(action: dict) -> dict:
    for field in ACTION_ARRAY_FIELDS:
        value = action.get(field)
        if isinstance(value, dict) and not value:
            action[field] = []
    return action


def _bounded_code(value) -> str:
    if isinstance(value, str) and CODE_PATTERN.match(value):
        return value
    return CODE_INTERNAL


def _validate_request(request) -> None:
    if not isinstance(request, dict):
        raise _WorkerError(CODE_BAD_INPUT)
    if set(request.keys()) != REQUEST_KEYS:
        raise _WorkerError(CODE_BAD_INPUT)
    runtime = request["runtime"]
    if runtime not in ALLOWED_RUNTIMES:
        raise _WorkerError(CODE_BAD_RUNTIME)
    source = request["source"]
    if not isinstance(source, str) or source == "":
        raise _WorkerError(CODE_BAD_SOURCE)
    try:
        source_bytes = len(source.encode("utf-8"))
    except Exception:
        raise _WorkerError(CODE_BAD_SOURCE)
    if source_bytes > MAX_SOURCE_BYTES:
        raise _WorkerError(CODE_BAD_SOURCE)
    if source[0] == "\x1b":
        raise _WorkerError(CODE_BAD_SOURCE)
    if not isinstance(request["observation"], dict):
        raise _WorkerError(CODE_BAD_INPUT)


def run_request(request: dict) -> dict:
    """Execute one validated request and return a bounded response dict."""
    try:
        _validate_request(request)
    except _WorkerError as error:
        return {"ok": False, "code": error.code}
    try:
        module_sources = [_read_module(name) for name in MODULE_FILES]
        helper_source = HELPER_PATH.read_text(encoding="utf-8")
    except _WorkerError as error:
        return {"ok": False, "code": error.code}
    except Exception:
        return {"ok": False, "code": CODE_HELPER_MISSING}
    try:
        lua = _new_runtime(request["runtime"])
        helper = lua.execute(helper_source)
        if helper.configure(module_sources[0], module_sources[1], module_sources[2]) is not True:
            return {"ok": False, "code": CODE_INTERNAL}
        new_table = _new_table(lua)
        observation = _to_lua(request["observation"], new_table)
        result = _from_lua(helper.run(request["source"], observation))
    except _WorkerError as error:
        return {"ok": False, "code": error.code}
    except Exception:
        return {"ok": False, "code": CODE_INTERNAL}
    if not isinstance(result, dict):
        return {"ok": False, "code": CODE_INTERNAL}
    if result.get("ok") is True:
        action = result.get("action")
        if not isinstance(action, dict):
            return {"ok": False, "code": CODE_INTERNAL}
        return {"ok": True, "code": CODE_OK, "action": _normalize_action(action)}
    return {"ok": False, "code": _bounded_code(result.get("code"))}


def run_request_bytes(raw: bytes) -> dict:
    if len(raw) > MAX_INPUT_BYTES:
        return {"ok": False, "code": CODE_INPUT_TOO_LARGE}
    try:
        request = json.loads(raw.decode("utf-8"))
    except Exception:
        return {"ok": False, "code": CODE_BAD_INPUT}
    return run_request(request)


def _encode(response: dict) -> str:
    encoded = json.dumps(response, separators=(",", ":"), sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_OUTPUT_BYTES:
        fallback = {"ok": False, "code": CODE_OUTPUT_TOO_LARGE}
        return json.dumps(fallback, separators=(",", ":"), sort_keys=True)
    return encoded


def _read_input_file(path) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            return handle.read(MAX_INPUT_BYTES + 1)
    except Exception:
        return None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Bounded development policy worker")
    parser.add_argument("--input", default=None, help="read the JSON request from PATH instead of stdin")
    args = parser.parse_args(argv)
    if args.input is not None:
        raw = _read_input_file(args.input)
        if raw is None:
            response = {"ok": False, "code": CODE_BAD_INPUT}
        else:
            response = run_request_bytes(raw)
    else:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        response = run_request_bytes(raw)
    sys.stdout.write(_encode(response))
    return 0


if __name__ == "__main__":
    sys.exit(main())
