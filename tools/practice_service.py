#!/usr/bin/env python3
"""Loopback-only authenticated control/policy service for AI Sparring.

Standalone, launcher-owned development component. It is the small trusted
service the outer launcher starts next to the two staged Balatro runtimes. It
serves exactly two purposes over one newline-delimited JSON control channel on
``127.0.0.1`` only:

- narrow match coordination relay (hello / lobby+join code / ready / start /
  status / end / error) with fixed op enums and no Multiplayer transport
  commands; and
- bounded AI policy decisions: one outstanding decision per AI session,
  strictly increasing integer sequence, canonical exported observation in
  (re-sanitized through the repository observation factory before any worker is
  launched), repository-owned baseline source rendered outside the game, and the
  existing ``tools/policy_worker.py`` invoked as a separate bounded process.

Trust decisions made at construction (session id, the two random role
credentials, difficulty, pacing, mode, gauntlet selection, match port, log root
and verified content hash) are never accepted from, or mutable by, a network
client. A worker request is rebuilt from scratch and contains only
``runtime``/``source``/``observation``; no credential, seed, private token, raw
engine state, client-supplied source, config or log enters it. Actions are
regenerated and re-validated by the worker, which stays the capability
boundary; this service holds no game authority and never connects to a game
match server.

Importing this module performs no work and opens no socket. Tests drive
``PracticeService.handle_request`` directly and, when they want a real channel,
call ``start``/``stop`` against ``127.0.0.1``. No game, Mods directory, live
path or external network is touched.
"""
from __future__ import annotations

import hmac
import importlib
import importlib.util
import json
import re
import secrets
import socket as _socket
import socketserver
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping, Optional

import ranked_draft as ranked_draft_authority
import ranked_effective_config as ranked_authority

TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parent
WORKER_PATH = TOOLS_DIR / "policy_worker.py"
BASELINE_PATH = REPO_DIR / "AISparring" / "ai" / "baseline_policy.lua"
CODEC_PATH = REPO_DIR / "AISparring" / "ai" / "codec.lua"
OBSERVATION_PATH = REPO_DIR / "AISparring" / "ai" / "observation.lua"

VERSION = "practice_service/1"
RULESET = "majorleague"
WORKER_RUNTIME = "luajit21"

HOST = "127.0.0.1"
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
MAX_OBSERVATION_BYTES = 1 * 1024 * 1024
MAX_OBSERVATION_DEPTH = 16
MAX_SEQUENCE = 2147483647

ROLES = ("human", "ai")
DIFFICULTIES = ("rookie", "competitive", "major_league", "expert")
PACING = ("instant", "normal")
MODES = ("normal", "gauntlet")
GAUNTLET_SEEDS = {
    "Test1": "AISP0001",
    "Test2": "AISP0002",
    "Test3": "AISP0003",
    "Test4": "AISP0004",
    "Test5": "AISP0005",
}

OPS = (
    "hello",
    "lobby_code",
    "join_code",
    "ready",
    "start",
    "status",
    "end",
    "error",
    "heartbeat",
    "setup",
    "decide_begin",
    "decide_poll",
    "decide_cancel",
    "decision_result",
)
COORDINATION_OPS = (
    "hello",
    "lobby_code",
    "join_code",
    "ready",
    "start",
    "status",
    "end",
    "error",
    "heartbeat",
    "setup",
)
DECISION_OPS = ("decide_begin", "decide_poll", "decide_cancel")
AI_ONLY_OPS = DECISION_OPS + ("decision_result",)
OP_ROLE = {"lobby_code": "human", "join_code": "ai", "start": "human"}

# Frozen after start: these coordination requests are rejected as config changes.
FROZEN_OPS = ("hello", "lobby_code", "join_code", "ready")

# Operations refused until the trusted host has attested the session. The
# attestation is set only through the trusted ``mark_attested`` Python port,
# never over the wire: a network client can never assert its own attestation.
# ``status``/``heartbeat``/``end``/``error`` stay available so a launcher can
# still observe, abort and report a failure on an unattested session.
ATTESTED_OPS = frozenset(
    {
        "hello",
        "lobby_code",
        "join_code",
        "ready",
        "start",
        "setup",
        "decide_begin",
        "decide_poll",
        "decide_cancel",
        "decision_result",
    }
)

# Trusted terminal results a launcher/engine role may report through `end`.
TERMINAL_RESULTS = ("human_win", "ai_win", "draw", "aborted", "unknown")

# Terminal lifecycle phases exposed to the host through `status`/`terminal_summary`.
TERMINAL_NONE = "none"
TERMINAL_AWAITING_AI = "awaiting_ai"
TERMINAL_CLOSED = "closed"
TERMINAL_PHASES = (TERMINAL_NONE, TERMINAL_AWAITING_AI, TERMINAL_CLOSED)

# Frozen Major League digest contract (docs/MAJOR_LEAGUE_DIGEST.md): FNV1a32
# over a fixed canonical string, eight lowercase hex digits.
MAJOR_LEAGUE_RULESET_ID = "ruleset_mp_majorleague"

# The explicit versioned Ranked contract. Legacy fixtures/history keep their own
# semantics; this value is never used to relabel the Major League digest.
RANKED_CONFIG_SCHEMA = ranked_authority.RANKED_CONFIG_SCHEMA
# The exact readiness record keys (primitives only) the runtime must report on
# READY under the Ranked schema. Every value must be exactly true.
RANKED_READINESS_KEYS = (
    "unlock_check",
    "all_unlocked",
    "advertised_unlocked",
    "advertised_preview",
    "advertised_preview_valid",
    "live_preview",
    "preview_consistent",
    "peer_unlocked",
    "peer_cached",
    "banned_mods_empty",
    "mods_approved",
    "release_mode",
    "game_speed_ok",
    "debug_disabled",
    "animations_normal",
    "handy_ranked_safe",
)
# Raw integration evidence booleans may legitimately be false; every other key
# must be exactly true.
RANKED_READINESS_EVIDENCE_KEYS = frozenset({"advertised_preview", "live_preview"})
# Receipt-counter schema. Version 2 counts a refused decision once per delivered
# sequence; version 1 (and an absent field) is the historical idle-inflated
# semantics. The service's own final summary always reports the current version.
SERVICE_COUNTER_VERSION = 2
LEGACY_COUNTER_VERSION = 1
FNV1A32_OFFSET = 2166136261
FNV1A32_PRIME = 16777619
MAX_DIGEST_LEN = 64
MAX_FORCED_OPTIONS = 64
MAX_FORCED_STRING = 64
MAX_RESULT_RECEIPTS = 256

REQUEST_KEYS = frozenset({"session", "credential", "role", "op", "sequence", "observation"})

CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
LOBBY_PATTERN = re.compile(r"^[0-9A-Za-z_-]{1,32}$")
SEED_PATTERN = re.compile(r"(?=.{1,32}\Z)\*?[0-9A-Za-z_-]+\Z")
DIGEST_PATTERN = re.compile(r"^[0-9A-Za-z_-]{1,64}$")

CODE_OK = "practice_ok"
CODE_BAD_LINE = "practice_bad_line"
CODE_INPUT_TOO_LARGE = "practice_input_too_large"
CODE_OUTPUT_TOO_LARGE = "practice_output_too_large"
CODE_BAD_REQUEST = "practice_bad_request"
CODE_BAD_SHAPE = "practice_bad_shape"
CODE_BAD_SESSION = "practice_bad_session"
CODE_BAD_CREDENTIAL = "practice_bad_credential"
CODE_BAD_ROLE = "practice_bad_role"
CODE_BAD_OP = "practice_bad_op"
CODE_BAD_SEQUENCE = "practice_bad_sequence"
CODE_REPLAY = "practice_replay"
CODE_RATE_LIMITED = "practice_rate_limited"
CODE_BUSY = "practice_busy"
CODE_NOT_READY = "practice_not_ready"
CODE_CONFIG_MISMATCH = "practice_config_mismatch"
CODE_CONTENT_MISMATCH = "practice_content_mismatch"
CODE_NO_LOBBY = "practice_no_lobby"
CODE_ALREADY_STARTED = "practice_already_started"
CODE_FROZEN = "practice_config_frozen"
CODE_NOT_STARTED = "practice_not_started"
CODE_ENDED = "practice_ended"
CODE_SERVICE_CLOSED = "practice_closed"
CODE_BAD_PAYLOAD = "practice_bad_payload"
CODE_BAD_OBSERVATION = "practice_bad_observation"
CODE_DECISION_OUTSTANDING = "practice_decision_outstanding"
CODE_DECISION_UNKNOWN = "practice_decision_unknown"
CODE_DECISION_PENDING = "practice_decision_pending"
CODE_DECISION_READY = "practice_decision_ready"
CODE_DECISION_FAILED = "practice_decision_failed"
CODE_DECISION_TIMEOUT = "practice_decision_timeout"
CODE_DECISION_CANCELLED = "practice_decision_cancelled"
CODE_SOURCE_UNAVAILABLE = "practice_source_unavailable"
CODE_CANONICAL_UNAVAILABLE = "practice_canonical_unavailable"
CODE_WORKER_FAILED = "practice_worker_failed"
CODE_ABORTED = "practice_aborted"
CODE_ROLE_LOST = "practice_role_lost"
CODE_NOT_ATTESTED = "practice_not_attested"
CODE_PRESTART_TIMEOUT = "practice_prestart_timeout"
# The policy's own "no legal choice" answer (tools/lua/policy_env.lua). A
# legitimate outcome, counted as ``no_action``, never as a failure.
CODE_POLICY_NO_ACTION = "policy_no_action"
CODE_RESULT_CONFLICT = "practice_result_conflict"
CODE_INTERNAL = "practice_internal_error"

DEFAULT_ACTION_TYPES = (
    "PLAY_CARDS",
    "DISCARD_CARDS",
    "SELECT_BLIND",
    "SKIP_BLIND",
    "START_TIMER",
    "BUY_ITEM",
    "BUY_VOUCHER",
    "OPEN_BOOSTER",
    "REROLL",
    "LEAVE_SHOP",
    "SELL_JOKER",
    "SELL_CONSUMABLE",
    "SELECT_BOOSTER_ITEM",
    "SKIP_BOOSTER",
    "USE_CONSUMABLE",
    "USE_CONSUMABLE_ON_HAND",
    "SELECT_TARGETS",
    "REORDER_JOKERS",
    "REORDER_HAND",
)


class PracticeError(Exception):
    """Bounded, non-leaking service failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code if CODE_PATTERN.match(code) else CODE_INTERNAL


def _bounded_text(value, limit: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    cleaned = value.replace("\r", " ").replace("\n", " ")
    if len(cleaned) > limit:
        cleaned = cleaned[:limit]
    return cleaned


def _bounded_int(value, low: int, high: int) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < low or value > high:
        return None
    return value


def _no_duplicate_keys(pairs):
    out: dict = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate_key")
        out[key] = value
    return out


def _reject_constant(name: str):
    raise ValueError(name)


def parse_json_line(text: str):
    return json.loads(
        text,
        object_pairs_hook=_no_duplicate_keys,
        parse_constant=_reject_constant,
    )


def _json_bytes(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True, allow_nan=False).encode("utf-8")


def _max_depth(value) -> int:
    deepest = 0
    stack = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        if depth > deepest:
            deepest = depth
        if isinstance(current, dict):
            for item in current.values():
                stack.append((item, depth + 1))
        elif isinstance(current, list):
            for item in current:
                stack.append((item, depth + 1))
    return deepest


def fnv1a32_hex(text: str) -> str:
    """FNV1a-32 over the UTF-8 bytes, eight lowercase hex digits.

    Mirrors ``Codec.hash_string`` (``AISparring/ai/codec.lua``) exactly so the
    host-derived expected digest and the runtime-computed actual digest can be
    compared as trusted configuration equality (not authentication).
    """
    if not isinstance(text, str):
        raise PracticeError(CODE_BAD_REQUEST)
    if len(text.encode("utf-8")) > 262144:
        raise PracticeError(CODE_BAD_REQUEST)
    value = FNV1A32_OFFSET
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * FNV1A32_PRIME) & 0xFFFFFFFF
    return "%08x" % value


def _digest_primitive(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        if value < -2147483648 or value > 2147483647:
            raise PracticeError(CODE_BAD_REQUEST)
        return str(value)
    if isinstance(value, str):
        if len(value) > MAX_FORCED_STRING or any(ch in value for ch in ("|", "=", "\r", "\n")):
            raise PracticeError(CODE_BAD_REQUEST)
        return value
    raise PracticeError(CODE_BAD_REQUEST)


def major_league_digest(ruleset_id: str, gamemode: str, forced_options: Mapping) -> str:
    """Canonical Major League configuration digest (docs/MAJOR_LEAGUE_DIGEST.md).

    Input is ``ruleset_id | gamemode`` followed by each forced config key in
    bytewise ascending order as ``| key=primitive``, hashed with FNV1a-32. The
    host derives this from the pinned staged ``rulesets/majorleague.lua`` source;
    the service only holds it as trusted expected configuration.
    """
    if not isinstance(ruleset_id, str) or not DIGEST_PATTERN.match(ruleset_id):
        raise PracticeError(CODE_BAD_REQUEST)
    if not isinstance(gamemode, str) or not DIGEST_PATTERN.match(gamemode):
        raise PracticeError(CODE_BAD_REQUEST)
    if not isinstance(forced_options, Mapping) or len(forced_options) > MAX_FORCED_OPTIONS:
        raise PracticeError(CODE_BAD_REQUEST)
    parts = [ruleset_id, gamemode]
    for key in sorted(forced_options.keys(), key=lambda k: str(k).encode("utf-8")):
        if not isinstance(key, str) or not DIGEST_PATTERN.match(key):
            raise PracticeError(CODE_BAD_REQUEST)
        parts.append(key + "=" + _digest_primitive(forced_options[key]))
    return fnv1a32_hex("|".join(parts))


def _encode_response(response: Mapping) -> str:
    try:
        encoded = json.dumps(response, separators=(",", ":"), sort_keys=True, allow_nan=False)
    except Exception:  # noqa: BLE001
        encoded = json.dumps({"ok": False, "code": CODE_INTERNAL}, separators=(",", ":"), sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        encoded = json.dumps(
            {"ok": False, "code": CODE_OUTPUT_TOO_LARGE}, separators=(",", ":"), sort_keys=True
        )
    return encoded


class RateLimiter:
    """Bounded per-connection request rate (count within a sliding window)."""

    def __init__(self, max_events: int, window: float) -> None:
        if max_events < 1 or window <= 0:
            raise PracticeError(CODE_INTERNAL)
        self.max_events = max_events
        self.window = float(window)
        self._events: deque = deque()

    def allow(self, now: Optional[float] = None) -> bool:
        now = time.monotonic() if now is None else float(now)
        cutoff = now - self.window
        while self._events and self._events[0] < cutoff:
            self._events.popleft()
        if len(self._events) >= self.max_events:
            return False
        self._events.append(now)
        return True


class LocalLogger:
    """Bounded local JSONL diagnostics. Never receives credentials."""

    DECISION_KEYS = (
        "timestamp",
        "tick",
        "session",
        "ruleset",
        "difficulty",
        "phase",
        "hash",
        "legalcount",
        "action",
        "reason",
        "latency",
        "version",
        "errors",
        "seed",
        "ui",
    )
    SUMMARY_KEYS = (
        "timestamp",
        "session",
        "ruleset",
        "difficulty",
        "result",
        "reason",
        "human_lives",
        "ai_lives",
        "ante",
        "round",
        "duration_seconds",
        "decisions",
        "rejected",
        "errors",
        "no_action",
        "terminal",
        "terminal_phase",
        "human_end_received",
        "ai_end_received",
        "ai_result",
        "ai_human_lives",
        "ai_ai_lives",
        "ai_ante",
        "ai_round",
        "ai_duration_seconds",
        "ai_decisions",
        "ai_rejected",
        "ai_errors",
        "ai_counter_version",
        "ai_loop_idle",
        "ai_loop_transient",
        "ai_loop_empty",
        "ai_loop_no_action",
        "ai_loop_waits",
        "counter_version",
        "human_counter_version",
        "result_conflict",
        "seed",
        "version",
    )
    RESULT_KEYS = (
        "timestamp",
        "session",
        "ruleset",
        "difficulty",
        "sequence",
        "accepted",
        "code",
        "version_id",
        "tick",
        "reason",
        "seed",
        "version",
    )

    def __init__(self, root, session_id: str, difficulty: str) -> None:
        self.root = Path(root)
        self.session_id = session_id
        self.difficulty = difficulty
        self.decisions_path = self.root / "decisions.jsonl"
        self.summary_path = self.root / "summary.jsonl"
        self.results_path = self.root / "results.jsonl"
        self._lock = threading.Lock()
        self._seed: Optional[str] = None
        try:
            self.root.mkdir(parents=True, exist_ok=True)
        except Exception:  # noqa: BLE001
            raise PracticeError("practice_log_root_unavailable")

    def set_seed(self, seed: str) -> None:
        with self._lock:
            self._seed = seed

    @property
    def seed(self) -> Optional[str]:
        with self._lock:
            return self._seed

    def _write(self, path: Path, row: Mapping) -> None:
        try:
            line = json.dumps(row, separators=(",", ":"), sort_keys=True, allow_nan=False)
        except Exception:  # noqa: BLE001
            return
        if len(line.encode("utf-8")) > MAX_RESPONSE_BYTES:
            return
        with self._lock:
            try:
                with path.open("a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
            except Exception:  # noqa: BLE001
                return

    def log_decision(self, **fields) -> None:
        row = {key: None for key in self.DECISION_KEYS}
        row["timestamp"] = round(time.time(), 6)
        row["session"] = self.session_id
        row["ruleset"] = RULESET
        row["difficulty"] = self.difficulty
        row["version"] = VERSION
        for key in self.DECISION_KEYS:
            if key in fields:
                row[key] = fields[key]
        # The seed is trusted metadata only; it is never read from a request or
        # an observation.
        row["seed"] = self._seed
        row["session"] = self.session_id
        row["difficulty"] = self.difficulty
        self._write(self.decisions_path, row)

    def log_result(self, **fields) -> None:
        row = {key: None for key in self.RESULT_KEYS}
        row["timestamp"] = round(time.time(), 6)
        row["session"] = self.session_id
        row["ruleset"] = RULESET
        row["difficulty"] = self.difficulty
        row["version"] = VERSION
        for key in self.RESULT_KEYS:
            if key in fields:
                row[key] = fields[key]
        row["seed"] = self._seed
        row["session"] = self.session_id
        row["difficulty"] = self.difficulty
        self._write(self.results_path, row)

    def log_summary(self, **fields) -> None:
        row = {key: None for key in self.SUMMARY_KEYS}
        row["timestamp"] = round(time.time(), 6)
        row["session"] = self.session_id
        row["ruleset"] = RULESET
        row["difficulty"] = self.difficulty
        row["version"] = VERSION
        row["seed"] = self._seed
        for key in self.SUMMARY_KEYS:
            if key in fields:
                row[key] = fields[key]
        row["session"] = self.session_id
        row["difficulty"] = self.difficulty
        row["version"] = VERSION
        row["seed"] = self._seed
        self._write(self.summary_path, row)


RESTRICTED_GLOBALS = (
    "io",
    "os",
    "debug",
    "package",
    "require",
    "dofile",
    "loadfile",
    "load",
    "loadstring",
    "collectgarbage",
)


def _restrict_runtime(lua) -> None:
    """Remove host/escape globals from a dedicated, repo-module-only runtime.

    This is defense in depth for trusted repository modules; it is not a claim
    of OS-level sandboxing.
    """
    globals_table = lua.globals()
    for name in RESTRICTED_GLOBALS:
        try:
            globals_table[name] = None
        except Exception:  # noqa: BLE001
            continue


def _worker_module():
    try:
        import policy_worker  # type: ignore

        return policy_worker
    except Exception:  # noqa: BLE001
        spec = importlib.util.spec_from_file_location("policy_worker", WORKER_PATH)
        if spec is None or spec.loader is None:
            raise PracticeError(CODE_CANONICAL_UNAVAILABLE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module


class BaselineSourceProvider:
    """Renders repository baseline policy source in a restricted Lua runtime.

    Only ``AISparring/ai/baseline_policy.lua`` is loaded into a dedicated
    interpreter with the host globals removed (``io``/``os``/``debug``/
    ``package``/``require``/``dofile``/``load*``/``collectgarbage``). No engine
    globals, no filesystem access from the rendered chunk and no client-supplied
    source. The rendered chunk is still loaded behind the worker's own
    whitelist environment; this renderer is trusted code.
    """

    def __init__(self, module_path=BASELINE_PATH) -> None:
        self.module_path = Path(module_path)
        self._cache: dict = {}
        self._lock = threading.Lock()

    def _runtime(self):
        for name in ("lupa.lua51", "lupa.luajit21"):
            try:
                module = importlib.import_module(name)
            except Exception:  # noqa: BLE001
                continue
            try:
                lua = module.LuaRuntime(register_eval=False, register_builtins=False)
            except Exception:  # noqa: BLE001
                continue
            _restrict_runtime(lua)
            return lua
        raise PracticeError(CODE_SOURCE_UNAVAILABLE)

    def source(self, difficulty: str) -> str:
        with self._lock:
            if difficulty in self._cache:
                return self._cache[difficulty]
        try:
            text = self.module_path.read_text(encoding="utf-8")
        except Exception:  # noqa: BLE001
            raise PracticeError(CODE_SOURCE_UNAVAILABLE)
        try:
            lua = self._runtime()
            module = lua.execute(text)
            render = module["source"]
            source = render(difficulty)
        except PracticeError:
            raise
        except Exception:  # noqa: BLE001
            raise PracticeError(CODE_SOURCE_UNAVAILABLE)
        if not isinstance(source, str) or not source:
            raise PracticeError(CODE_SOURCE_UNAVAILABLE)
        with self._lock:
            self._cache[difficulty] = source
        return source


_CANONICAL_LUA = """
local function sanitize(observer, frame)
	if type(observer) ~= "table" or type(frame) ~= "table" then
		return { ok = false, code = "input" }
	end
	local ok_observe, handle = pcall(observer.observe, frame)
	if not ok_observe or handle == nil then
		return { ok = false, code = "observe" }
	end
	local canonical = observer.canonical(handle)
	if canonical == nil then
		return { ok = false, code = "canonical" }
	end
	local hash = observer.hash(handle)
	local export = observer.export(handle)
	if export == nil then
		return { ok = false, code = "export" }
	end
	if type(export.opponent) == "table" then
		export.opponent.certified = true
	end
	local ok_round, handle2 = pcall(observer.observe, export)
	if not ok_round or handle2 == nil then
		return { ok = false, code = "roundtrip" }
	end
	local canonical2 = observer.canonical(handle2)
	if canonical2 ~= canonical then
		return { ok = false, code = "mismatch" }
	end
	return { ok = true, export = export, canonical = canonical, hash = hash }
end
return sanitize
"""


class CanonicalObservation:
    """Rebuilds the canonical sanitized export through the real observation factory.

    Uses a dedicated restricted interpreter that loads only
    ``AISparring/ai/codec.lua`` and ``AISparring/ai/observation.lua``. The raw
    client frame is re-observed, re-exported and re-observed again (with the
    worker's ``opponent.certified`` reconstruction) so unknown/extra fields are
    dropped before any worker subprocess is launched and an unequal canonical
    roundtrip is rejected.
    """

    def __init__(self, codec_path=CODEC_PATH, observation_path=OBSERVATION_PATH) -> None:
        self.codec_path = Path(codec_path)
        self.observation_path = Path(observation_path)
        self._lock = threading.Lock()
        self._lua = None
        self._observer = None
        self._sanitize = None
        self._worker = None
        self._new_table = None

    def _build_locked(self) -> None:
        if self._sanitize is not None:
            return
        try:
            codec_src = self.codec_path.read_text(encoding="utf-8")
            observation_src = self.observation_path.read_text(encoding="utf-8")
        except Exception:  # noqa: BLE001
            raise PracticeError(CODE_CANONICAL_UNAVAILABLE)
        for name in ("lupa.lua51", "lupa.luajit21"):
            try:
                module = importlib.import_module(name)
            except Exception:  # noqa: BLE001
                continue
            try:
                lua = module.LuaRuntime(register_eval=False, register_builtins=False)
            except Exception:  # noqa: BLE001
                continue
            _restrict_runtime(lua)
            try:
                codec = lua.execute(codec_src)
                observation_module = lua.execute(observation_src)
                observer = observation_module["factory"](codec)
                sanitize = lua.execute(_CANONICAL_LUA)
                # Lua-owned factory so every table the raw frame is rebuilt
                # into is a genuine Lua table, never a wrapped Python object.
                new_table = lua.execute("return function() return {} end")
            except Exception:  # noqa: BLE001
                continue
            if observer is None or sanitize is None or new_table is None:
                continue
            self._lua = lua
            self._observer = observer
            self._sanitize = sanitize
            self._new_table = new_table
            self._worker = _worker_module()
            return
        raise PracticeError(CODE_CANONICAL_UNAVAILABLE)

    def sanitize(self, frame) -> "tuple[dict, str]":
        if not isinstance(frame, dict):
            raise PracticeError(CODE_BAD_OBSERVATION)
        with self._lock:
            self._build_locked()
            try:
                # Rebuild the raw client frame as a real Lua table through the
                # worker's own bounded converter; a wrapped Python mapping is
                # userdata inside Lua and would be rejected by the observer.
                lua_frame = self._worker._to_lua(frame, self._new_table)
            except Exception:  # noqa: BLE001
                raise PracticeError(CODE_BAD_OBSERVATION)
            try:
                result = self._sanitize(self._observer, lua_frame)
                ok = result["ok"]
                export = result["export"]
                canonical = result["canonical"]
            except Exception:  # noqa: BLE001
                raise PracticeError(CODE_BAD_OBSERVATION)
            if ok is not True or export is None or not isinstance(canonical, str):
                raise PracticeError(CODE_BAD_OBSERVATION)
            try:
                export_python = self._worker._from_lua(export)
            except Exception:  # noqa: BLE001
                raise PracticeError(CODE_BAD_OBSERVATION)
        if not isinstance(export_python, dict):
            raise PracticeError(CODE_BAD_OBSERVATION)
        return export_python, canonical


def _kill_process(proc) -> None:
    try:
        proc.kill()
    except Exception:  # noqa: BLE001
        return
    try:
        proc.communicate(timeout=5)
    except Exception:  # noqa: BLE001
        return


def run_policy_worker(request: Mapping, timeout: float, register: Callable, *, popen=None, python=None) -> dict:
    """Run the existing bounded worker in a separate process.

    Returns the worker's parsed response, or a bounded failure dict. Only the
    exact spawned child is ever terminated.
    """
    python = python or sys.executable
    try:
        raw = _json_bytes(request)
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": CODE_WORKER_FAILED}
    if len(raw) > MAX_REQUEST_BYTES:
        return {"ok": False, "code": "practice_worker_request_too_large"}
    spawn = popen or subprocess.Popen
    try:
        proc = spawn(
            [python, str(WORKER_PATH)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": "practice_worker_unavailable"}
    if register is not None:
        try:
            register(proc)
        except Exception:  # noqa: BLE001
            _kill_process(proc)
            return {"ok": False, "code": CODE_WORKER_FAILED}
    try:
        out, _err = proc.communicate(raw, timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_process(proc)
        return {"ok": False, "code": CODE_DECISION_TIMEOUT}
    except Exception:  # noqa: BLE001
        _kill_process(proc)
        return {"ok": False, "code": CODE_WORKER_FAILED}
    if not isinstance(out, (bytes, bytearray)) or len(out) > MAX_RESPONSE_BYTES:
        return {"ok": False, "code": "practice_worker_bad_response"}
    try:
        response = json.loads(out.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": "practice_worker_bad_response"}
    if not isinstance(response, dict):
        return {"ok": False, "code": "practice_worker_bad_response"}
    return response


@dataclass(frozen=True)
class ServiceConfig:
    session_id: str
    difficulty: str
    pacing: str
    mode: str
    match_port: int
    log_root: Path
    content_hash: str
    expected_config_digest: str
    gauntlet: Optional[str] = None
    ruleset_id: str = MAJOR_LEAGUE_RULESET_ID
    gamemode: Optional[str] = None
    forced_options: Optional[Mapping] = None
    # Explicit versioned Ranked contract (None = legacy Major League path). When
    # set, the service performs a consistency check: it re-hashes the
    # host-supplied typed views and requires the result to equal the digest the
    # host pinned. This is NOT an independent source derivation; the host's
    # pinned-source derivation and the immutable certificate remain the authority.
    config_schema: Optional[str] = None
    ranked_host: Optional[Mapping] = None
    ranked_resolved: Optional[Mapping] = None
    # Host-owned completed-draft selection and the validated catalog it binds
    # against. Both are required under the Ranked schema; the service
    # re-validates the exact selection keys/types and requires the canonical
    # host view's back/stake to equal the selection.
    selection: Optional[Mapping] = None
    ranked_catalog: Optional[Mapping] = None
    # The dedicated completed-draft commitment (public profile/first actor/pool/
    # transcript/final) and its FNV1a-32 digest. When present the service
    # independently re-validates the bounded transcript, requires the digest to
    # match the host's expected value, and requires the final option to map back
    # to the validated selection.
    draft: Optional[Mapping] = None
    expected_draft_digest: Optional[str] = None

    def __post_init__(self) -> None:
        if not isinstance(self.session_id, str) or not (1 <= len(self.session_id) <= 128):
            raise PracticeError(CODE_BAD_REQUEST)
        if self.difficulty not in DIFFICULTIES:
            raise PracticeError(CODE_BAD_REQUEST)
        if self.pacing not in PACING:
            raise PracticeError(CODE_BAD_REQUEST)
        if self.mode not in MODES:
            raise PracticeError(CODE_BAD_REQUEST)
        port = _bounded_int(self.match_port, 1, 65535)
        if port is None:
            raise PracticeError(CODE_BAD_REQUEST)
        if not isinstance(self.content_hash, str) or not (1 <= len(self.content_hash) <= 256):
            raise PracticeError(CODE_BAD_REQUEST)
        # Trusted host-derived Major League configuration digest (required; no
        # content-hash fallback). See docs/MAJOR_LEAGUE_DIGEST.md.
        if not isinstance(self.expected_config_digest, str) or not DIGEST_PATTERN.match(self.expected_config_digest):
            raise PracticeError(CODE_BAD_REQUEST)
        if not isinstance(self.ruleset_id, str) or not DIGEST_PATTERN.match(self.ruleset_id):
            raise PracticeError(CODE_BAD_REQUEST)
        if self.gamemode is not None and (
            not isinstance(self.gamemode, str) or not DIGEST_PATTERN.match(self.gamemode)
        ):
            raise PracticeError(CODE_BAD_REQUEST)
        if self.forced_options is not None:
            if not isinstance(self.forced_options, Mapping) or len(self.forced_options) > MAX_FORCED_OPTIONS:
                raise PracticeError(CODE_BAD_REQUEST)
            for key, value in self.forced_options.items():
                if not isinstance(key, str) or not DIGEST_PATTERN.match(key):
                    raise PracticeError(CODE_BAD_REQUEST)
                _digest_primitive(value)
        if self.config_schema is not None:
            if self.config_schema != RANKED_CONFIG_SCHEMA:
                raise PracticeError(CODE_BAD_REQUEST)
            # The Ranked contract pins the exact registry ruleset and gamemode;
            # a caller cannot substitute another ruleset under this schema.
            if self.ruleset_id != ranked_authority.RULESET_ID:
                raise PracticeError(CODE_BAD_REQUEST)
            if self.gamemode != ranked_authority.FORCED_GAMEMODE:
                raise PracticeError(CODE_BAD_REQUEST)
            if not isinstance(self.ranked_host, Mapping) or not isinstance(self.ranked_resolved, Mapping):
                raise PracticeError(CODE_BAD_REQUEST)
            # Consistency check (not an independent source derivation): the
            # service re-hashes the typed host view it was handed and requires it
            # to equal the digest the host pinned. The host's pinned-source
            # derivation and the immutable certificate remain the authority.
            try:
                canonical = ranked_authority.canonical_bytes(self.ranked_host, self.ranked_resolved)
                derived = ranked_authority.fnv1a32_hex(canonical)
            except ranked_authority.RankedConfigError:
                raise PracticeError(CODE_BAD_REQUEST)
            if not hmac.compare_digest(derived.encode("utf-8"), self.expected_config_digest.encode("utf-8")):
                raise PracticeError(CODE_BAD_REQUEST)
            # A validated host-owned selection is mandatory; the service
            # re-validates its exact keys/types against the catalog. There is no
            # fixed-deck fallback.
            if not isinstance(self.selection, Mapping) or not isinstance(self.ranked_catalog, Mapping):
                raise PracticeError(CODE_BAD_REQUEST)
            catalog = {
                "decks": self.ranked_catalog.get("decks"),
                "stakes": self.ranked_catalog.get("stakes"),
            }
            selection_verdict = ranked_authority.validate_selection(self.selection, catalog)
            if not selection_verdict.get("ok"):
                raise PracticeError(CODE_BAD_REQUEST)
            # The canonical host view's back/stake must equal the validated
            # selection independently; a host-supplied view that disagrees with
            # its own selection is refused before service setup.
            if (
                self.ranked_host.get("back") != selection_verdict["back_name"]
                or self.ranked_host.get("stake") != selection_verdict["stake_index"]
            ):
                raise PracticeError(CODE_BAD_REQUEST)
            # The dedicated draft commitment is MANDATORY under the Ranked
            # schema. The service independently re-validates the bounded
            # transcript, requires the digest to match the host's dedicated
            # expected value (a caller-supplied digest is never trusted), and
            # requires the final option to map back to the validated selection.
            if not isinstance(self.draft, Mapping):
                raise PracticeError(CODE_BAD_REQUEST)
            if not isinstance(self.expected_draft_digest, str) or not DIGEST_PATTERN.match(
                self.expected_draft_digest
            ):
                raise PracticeError(CODE_BAD_REQUEST)
            commitment = ranked_draft_authority.commitment_from_public(self.draft)
            if not commitment.get("ok"):
                raise PracticeError(CODE_BAD_REQUEST)
            if not hmac.compare_digest(
                commitment["digest"].encode("utf-8"), self.expected_draft_digest.encode("utf-8")
            ):
                raise PracticeError(CODE_BAD_REQUEST)
            # Resolve the final option against the catalog and require it to
            # equal the selection bound into the lobby view.
            decks = self.ranked_catalog.get("decks")
            stakes = self.ranked_catalog.get("stakes")
            try:
                final_selection = ranked_draft_authority.selection_for_option(
                    {"decks": decks, "stakes": stakes}, commitment["final"]
                )
            except ranked_draft_authority.DraftError:
                raise PracticeError(CODE_BAD_REQUEST)
            if final_selection != dict(self.selection):
                raise PracticeError(CODE_BAD_REQUEST)
            # M2: the trusted host gauntlet-seed derivation/binding is not
            # provisioned in this source pass, so a Ranked gauntlet is refused
            # explicitly before any quit rather than failing after launch.
            if self.mode == "gauntlet":
                raise PracticeError(CODE_BAD_REQUEST)
        if self.mode == "gauntlet":
            if self.gauntlet not in GAUNTLET_SEEDS:
                raise PracticeError(CODE_BAD_REQUEST)
        elif self.gauntlet is not None:
            raise PracticeError(CODE_BAD_REQUEST)

    @property
    def forced_option_keys(self) -> tuple:
        if self.forced_options is None:
            return ()
        return tuple(sorted(self.forced_options.keys(), key=lambda k: k.encode("utf-8")))

    @property
    def gauntlet_seed(self) -> Optional[str]:
        if self.mode == "gauntlet":
            return GAUNTLET_SEEDS[self.gauntlet]
        return None


class _DecisionJob:
    def __init__(self, sequence: int, observation: dict, phase: Optional[str], canonical: str = "") -> None:
        self.sequence = sequence
        self.observation = observation
        self.canonical = canonical
        self.phase = phase
        self.done = threading.Event()
        self.ok = False
        self.code = CODE_DECISION_FAILED
        self.action: Optional[dict] = None
        self.latency: Optional[float] = None
        self.cancelled = False
        self.proc = None
        self.thread: Optional[threading.Thread] = None
        self.started_at = time.monotonic()

    def register_process(self, proc) -> None:
        self.proc = proc
        if self.cancelled:
            _kill_process(proc)

    def cancel(self) -> None:
        self.cancelled = True
        if self.proc is not None:
            _kill_process(self.proc)


@dataclass
class _SessionState:
    last_sequence: dict = field(default_factory=lambda: {role: -1 for role in ROLES})
    hello: dict = field(default_factory=dict)
    ready: dict = field(default_factory=dict)
    lobby_code: Optional[str] = None
    started: bool = False
    ended: bool = False
    aborted: bool = False
    attested: bool = False
    attested_at: Optional[float] = None
    prestart_started_at: Optional[float] = None
    last_error: Optional[str] = None
    last_decision_sequence: Optional[int] = None
    last_seen: dict = field(default_factory=dict)
    issued_sequences: deque = field(default_factory=lambda: deque(maxlen=64))
    decisions: int = 0
    failures: int = 0
    no_action: int = 0
    rejected: int = 0
    # Terminal lifecycle. ``terminal`` is set only by a valid human coordinator
    # END; the AI END is a receipt recorded beside it.
    terminal: bool = False
    terminal_phase: str = TERMINAL_NONE
    terminal_result: Optional[str] = None
    terminal_reason: Optional[str] = None
    human_end: Optional[dict] = None
    ai_end: Optional[dict] = None
    ai_receipt_deadline: Optional[float] = None
    terminal_summary: Optional[dict] = None
    human_lives: Optional[int] = None
    ai_lives: Optional[int] = None
    ante: Optional[int] = None
    round_number: Optional[int] = None
    duration_seconds: Optional[float] = None
    result_receipts: dict = field(default_factory=dict)
    result_order: deque = field(default_factory=deque)


class PracticeService:
    """Small real loopback control/policy service. See docs/PRACTICE_SERVICE.md."""

    def __init__(
        self,
        config: ServiceConfig,
        *,
        host: str = HOST,
        port: int = 0,
        human_credential: Optional[str] = None,
        ai_credential: Optional[str] = None,
        source_provider=None,
        canonicalizer=None,
        worker_runner=None,
        logger=None,
        decision_timeout: float = 10.0,
        role_timeout: float = 60.0,
        prestart_timeout: float = 90.0,
        ai_receipt_grace: float = 30.0,
        watchdog_interval: float = 0.1,
        max_connections: int = 8,
        requests_per_window: int = 120,
        rate_window: float = 1.0,
        socket_timeout: float = 10.0,
        clock: Optional[Callable[[], float]] = None,
    ) -> None:
        if host != HOST:
            raise PracticeError(CODE_BAD_REQUEST)
        self.config = config
        self.host = host
        self.requested_port = _bounded_int(port, 0, 65535)
        if self.requested_port is None:
            raise PracticeError(CODE_BAD_REQUEST)
        self.port: Optional[int] = None

        human = human_credential or secrets.token_hex(32)
        ai = ai_credential or secrets.token_hex(32)
        if not (isinstance(human, str) and isinstance(ai, str) and human and ai and human != ai):
            raise PracticeError(CODE_BAD_REQUEST)
        self._credentials = {"human": human, "ai": ai}

        self.session_id = config.session_id
        self.difficulty = config.difficulty
        self.content_hash = config.content_hash
        self.expected_config_digest = config.expected_config_digest
        # The reported ruleset label is the actual registry key, never the policy
        # difficulty relabelled as a ruleset.
        self.config_schema = config.config_schema
        self.ranked_host = config.ranked_host
        self.ranked_resolved = config.ranked_resolved
        self.selection = config.selection
        self.ranked_catalog = config.ranked_catalog
        self.draft = config.draft
        self.expected_draft_digest = config.expected_draft_digest
        self.ruleset_label = (
            ranked_authority.RULESET_KEY if config.config_schema == RANKED_CONFIG_SCHEMA else RULESET
        )
        self.decision_timeout = float(decision_timeout)
        self.role_timeout = float(role_timeout)
        # Bounded pre-start deadline: measured only after attestation, so an
        # attested session that never reaches `start` cannot idle for the whole
        # multi-hour match budget. Disabled when <= 0.
        self.prestart_timeout = float(prestart_timeout)
        # Bounded grace to collect the AI END receipt after the human coordinator
        # authorizes the match end. The host keeps the loopback server/service
        # until the human exits; this only bounds the receipt wait.
        self.ai_receipt_grace = float(ai_receipt_grace)
        self.watchdog_interval = max(0.01, float(watchdog_interval))
        self.socket_timeout = float(socket_timeout)

        self._source_provider = source_provider or BaselineSourceProvider()
        self._canonicalizer = canonicalizer or CanonicalObservation()
        self._worker_runner = worker_runner or run_policy_worker
        self._logger = logger or LocalLogger(config.log_root, config.session_id, config.difficulty)

        self._clock = clock or time.monotonic
        self._lock = threading.RLock()
        self._state = _SessionState()
        # Hand-off milestones (first occurrence only), seconds since service
        # creation on a private perf_counter clock. Instrumentation only: never
        # read by any decision and independent of the injectable clock.
        self._milestone_origin = time.perf_counter()
        self._milestones: dict = {}
        self._pending: Optional[_DecisionJob] = None
        self._closed = False
        self._watchdog_stop: Optional[threading.Event] = None
        self._watchdog_thread: Optional[threading.Thread] = None

        self._connection_slots = threading.BoundedSemaphore(max(1, int(max_connections)))
        self._rate_max = max(1, int(requests_per_window))
        self._rate_window = float(rate_window)
        self._server: Optional[socketserver.ThreadingTCPServer] = None
        self._server_thread: Optional[threading.Thread] = None

    # -- trusted accessors (launcher wiring only; never logged) --------------

    @property
    def human_credential(self) -> str:
        return self._credentials["human"]

    @property
    def ai_credential(self) -> str:
        return self._credentials["ai"]

    @property
    def gauntlet_seed(self) -> Optional[str]:
        return self.config.gauntlet_seed

    def _milestone(self, name: str) -> None:
        with self._lock:
            if name not in self._milestones and len(self._milestones) < 32:
                self._milestones[name] = round(time.perf_counter() - self._milestone_origin, 6)

    def milestones(self) -> dict:
        """Copy of the first-occurrence hand-off milestones (seconds since creation)."""
        with self._lock:
            return dict(self._milestones)

    @property
    def started(self) -> bool:
        with self._lock:
            return self._state.started

    @property
    def ended(self) -> bool:
        with self._lock:
            return self._state.ended

    @property
    def attested(self) -> bool:
        with self._lock:
            return self._state.attested

    @property
    def terminal_phase(self) -> str:
        with self._lock:
            return self._state.terminal_phase

    @property
    def terminal_reason(self) -> Optional[str]:
        """Trusted host view of the terminal reason; read under the service lock.

        ``human_end`` is the only reason that authorizes a normal completion; every
        other value (role lost, pre-start timeout, abort, close) is an abnormal end
        the host must report as a failure (H-C).
        """
        with self._lock:
            return self._state.terminal_reason

    @property
    def aborted(self) -> bool:
        """True once a role-loss/timeout/abort closed the session (read under lock).

        The host must not rely on a caller-invented attribute: the real service
        exposes its own lifecycle state (H-C).
        """
        with self._lock:
            return self._state.aborted

    def terminal_summary(self) -> dict:
        """Trusted host view of the terminal flags; never mutates the session.

        The human's retained results state is preserved: this reports what was
        recorded, it does not consume or clear it.
        """
        with self._lock:
            state = self._state
            return {
                "terminal": state.terminal,
                "terminal_phase": state.terminal_phase,
                "terminal_result": state.terminal_result,
                "terminal_reason": state.terminal_reason,
                "human_end_received": state.human_end is not None,
                "ai_end_received": state.ai_end is not None,
                "summary_written": state.terminal_summary is not None,
                "decisions": state.decisions,
                "rejected": state.rejected,
                "errors": state.failures,
                "no_action": state.no_action,
                "summary": dict(state.terminal_summary) if state.terminal_summary else None,
            }

    def mark_attested(self, expected_config_digest: str) -> bool:
        """Trusted host-only attestation gate. Never a wire op.

        Called by the launcher host *after* it has verified both staged role
        probes and the open-record state, and *before* the atomic attestation
        writer publishes the file the companions poll. ``expected_config_digest``
        is required and must equal the digest the service was constructed with,
        so the host cannot attest with one configuration and pin another.
        """
        if self._closed:
            raise PracticeError(CODE_SERVICE_CLOSED)
        if not isinstance(expected_config_digest, str) or not DIGEST_PATTERN.match(expected_config_digest):
            raise PracticeError(CODE_BAD_REQUEST)
        if not hmac.compare_digest(
            expected_config_digest.encode("utf-8"), self.expected_config_digest.encode("utf-8")
        ):
            raise PracticeError(CODE_BAD_REQUEST)
        with self._lock:
            self._state.attested = True
            if self._state.attested_at is None:
                self._state.attested_at = self._clock()
        return True

    def start_prestart_window(self) -> bool:
        """Trusted host-only: start the pre-start clock once roles can act.

        The reviewed order is unchanged (M8): the host attests the service
        first, then publishes the launcher-attestation files the companions
        poll. Both roles' probes can finish well before that (slow) publication,
        so the bounded pre-start budget is measured from publication rather than
        from ``mark_attested``. Called by the supervisor immediately after a
        successful attestation write.

        A session that is not attested, or already started/ended/aborted, is
        left untouched and ``False`` is returned, so this can never be used to
        bypass the deadline: if it is never called the watchdog keeps using the
        earlier ``attested_at`` start. Never a wire op (not in ``OPS``), and the
        first call wins so a repeated call is an idempotent no-op.
        """
        if self._closed:
            raise PracticeError(CODE_SERVICE_CLOSED)
        with self._lock:
            state = self._state
            if (
                not state.attested
                or state.started
                or state.ended
                or state.aborted
                or state.prestart_started_at is not None
            ):
                return False
            state.prestart_started_at = self._clock()
            return True

    # -- lifecycle -----------------------------------------------------------

    def start(self) -> int:
        if self._closed:
            raise PracticeError(CODE_SERVICE_CLOSED)
        if self._server is not None:
            raise PracticeError(CODE_BAD_REQUEST)
        server = _ControlServer((self.host, self.requested_port), self)
        self._server = server
        self.port = server.server_address[1]
        self._server_thread = threading.Thread(target=server.serve_forever, name="practice-service", daemon=True)
        self._server_thread.start()
        self._start_watchdog()
        return self.port

    def stop(self) -> None:
        self._stop_watchdog()
        server = self._server
        if server is not None:
            try:
                server.shutdown()
            except Exception:  # noqa: BLE001
                pass
            try:
                server.server_close()
            except Exception:  # noqa: BLE001
                pass
        thread = self._server_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=5.0)
        self._server = None
        self._server_thread = None

    def close(self) -> None:
        summary = None
        with self._lock:
            self._closed = True
            job = self._pending
            self._pending = None
            state = self._state
            # A human-authorized match whose AI receipt grace is still open is
            # closed here as a normal human end, writing its one terminal summary.
            if state.terminal and state.terminal_summary is None and state.terminal_phase == TERMINAL_AWAITING_AI:
                state.terminal_phase = TERMINAL_CLOSED
                summary = self._finalize_terminal_locked(state.terminal_result, state.terminal_reason, {})
            # A started, not-yet-summarized session gets exactly one terminal
            # summary on close so an abandoned match is recorded, not silent.
            elif state.started and state.terminal_summary is None:
                state.terminal = True
                state.terminal_phase = TERMINAL_CLOSED
                state.terminal_reason = CODE_SERVICE_CLOSED
                if state.terminal_result is None:
                    state.terminal_result = "unknown"
                summary = self._finalize_terminal_locked("unknown", CODE_SERVICE_CLOSED, {})
        if job is not None:
            job.cancel()
            if job.thread is not None and job.thread.is_alive():
                job.thread.join(timeout=5.0)
        if summary is not None:
            self._logger.log_summary(**summary)
        self.stop()

    def __enter__(self) -> "PracticeService":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def cancel_decision(self) -> bool:
        with self._lock:
            job = self._pending
            self._pending = None
        if job is None:
            return False
        job.cancel()
        return True

    # -- role watchdog -------------------------------------------------------

    def _start_watchdog(self) -> None:
        if self.role_timeout <= 0 and self.prestart_timeout <= 0:
            return
        if self._watchdog_thread is not None and self._watchdog_thread.is_alive():
            return
        self._watchdog_stop = threading.Event()
        self._watchdog_thread = threading.Thread(target=self._watchdog_loop, name="practice-watchdog", daemon=True)
        self._watchdog_thread.start()

    def _stop_watchdog(self) -> None:
        event = self._watchdog_stop
        if event is not None:
            event.set()
        thread = self._watchdog_thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)
        self._watchdog_stop = None
        self._watchdog_thread = None

    @staticmethod
    def _prestart_start(state: _SessionState) -> Optional[float]:
        """Pre-start clock: the publication time when set, else the attestation time."""
        if state.prestart_started_at is not None:
            return state.prestart_started_at
        return state.attested_at

    def _watchdog_loop(self) -> None:
        event = self._watchdog_stop
        while event is not None and not event.wait(self.watchdog_interval):
            now = self._clock()
            lost = None
            prestart_expired = False
            summary = None
            with self._lock:
                state = self._state
                if state.terminal and state.terminal_phase == TERMINAL_AWAITING_AI:
                    if state.ai_receipt_deadline is not None and now >= state.ai_receipt_deadline:
                        # The AI receipt grace elapsed. The host owns the service
                        # lifetime; this only closes the receipt phase and writes
                        # the one terminal summary for the ended match (M-7).
                        state.terminal_phase = TERMINAL_CLOSED
                        summary = self._finalize_terminal_locked(
                            state.terminal_result, state.terminal_reason, {}
                        )
                if state.started and not state.ended and not state.aborted:
                    for role in ROLES:
                        seen = state.last_seen.get(role)
                        if seen is not None and self.role_timeout > 0 and now - seen > self.role_timeout:
                            lost = role
                            break
                elif (
                    self.prestart_timeout > 0
                    and state.attested
                    and not state.started
                    and not state.ended
                    and not state.aborted
                    and self._prestart_start(state) is not None
                    and now - self._prestart_start(state) > self.prestart_timeout
                ):
                    prestart_expired = True
            if summary is not None:
                self._logger.log_summary(**summary)
            if lost is not None:
                self._abort(CODE_ROLE_LOST)
            elif prestart_expired:
                self._abort(CODE_PRESTART_TIMEOUT)

    def _abort(self, code: str) -> None:
        summary = None
        with self._lock:
            if self._state.aborted:
                return
            self._state.aborted = True
            self._state.last_error = code
            self._state.failures += 1
            job = self._pending
            self._pending = None
            # Exactly one terminal summary per session for error/role-lost/
            # timeout/abort, including the service's own counters and seed.
            if self._state.terminal_summary is None:
                self._state.terminal = True
                self._state.terminal_phase = TERMINAL_CLOSED
                if self._state.human_end is not None:
                    # An abort/void that lands during the AI-receipt wait must not
                    # overwrite the human's authoritative result: keep the human
                    # terminal result and reason, recording the abort code only as
                    # ``last_error`` (already set above).
                    result = self._state.terminal_result if self._state.terminal_result is not None else "aborted"
                    reason = self._state.terminal_reason or "human_end"
                else:
                    self._state.terminal_reason = code
                    if self._state.terminal_result is None:
                        self._state.terminal_result = "aborted"
                    result = "aborted"
                    reason = code
                summary = self._finalize_terminal_locked(result, reason, {})
        if job is not None:
            job.cancel()
        if summary is not None:
            self._logger.log_summary(**summary)
        self._logger.log_decision(reason=code, errors=code)

    def abort(self, code: str = CODE_ABORTED) -> None:
        """Explicit trusted abort usable by the launcher on session close."""
        self._abort(code)

    # -- connection management ----------------------------------------------

    def acquire_connection(self) -> bool:
        return self._connection_slots.acquire(blocking=False)

    def release_connection(self) -> None:
        try:
            self._connection_slots.release()
        except ValueError:
            pass

    def new_rate_limiter(self) -> RateLimiter:
        return RateLimiter(self._rate_max, self._rate_window)

    # -- wire entrypoint -----------------------------------------------------

    def handle_line(self, line) -> dict:
        if isinstance(line, str):
            raw = line.encode("utf-8", "replace")
        elif isinstance(line, (bytes, bytearray)):
            raw = bytes(line)
        else:
            return {"ok": False, "code": CODE_BAD_LINE}
        if len(raw) > MAX_REQUEST_BYTES + 1:
            return {"ok": False, "code": CODE_INPUT_TOO_LARGE}
        text = raw.decode("utf-8", "replace").strip()
        if not text:
            return {"ok": False, "code": CODE_BAD_LINE}
        if len(text.encode("utf-8")) > MAX_REQUEST_BYTES:
            return {"ok": False, "code": CODE_INPUT_TOO_LARGE}
        try:
            payload = parse_json_line(text)
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_BAD_LINE}
        return self.handle_request(payload)

    def handle_request(self, message) -> dict:
        try:
            return self._dispatch(message)
        except PracticeError as error:
            return {"ok": False, "code": error.code}
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_INTERNAL}

    # -- dispatch ------------------------------------------------------------

    def _dispatch(self, message) -> dict:
        if self._closed:
            return {"ok": False, "code": CODE_SERVICE_CLOSED}
        if not isinstance(message, dict):
            return {"ok": False, "code": CODE_BAD_REQUEST}
        if set(message.keys()) != REQUEST_KEYS:
            return {"ok": False, "code": CODE_BAD_SHAPE}
        session = message.get("session")
        credential = message.get("credential")
        role = message.get("role")
        op = message.get("op")
        sequence = message.get("sequence")
        observation = message.get("observation")
        if not isinstance(session, str) or not isinstance(credential, str) or not session or not credential:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        if not isinstance(role, str) or role not in ROLES:
            return {"ok": False, "code": CODE_BAD_ROLE}
        if not isinstance(op, str) or op not in OPS:
            return {"ok": False, "code": CODE_BAD_OP}
        if sequence is None or isinstance(sequence, bool) or not isinstance(sequence, int):
            return {"ok": False, "code": CODE_BAD_SEQUENCE}
        if sequence < 0 or sequence > MAX_SEQUENCE:
            return {"ok": False, "code": CODE_BAD_SEQUENCE}

        expected_role = OP_ROLE.get(op)
        if expected_role is not None and role != expected_role:
            return {"ok": False, "code": CODE_BAD_ROLE}
        if op in AI_ONLY_OPS and role != "ai":
            return {"ok": False, "code": CODE_BAD_ROLE}

        if not hmac.compare_digest(session.encode("utf-8"), self.session_id.encode("utf-8")):
            return {"ok": False, "code": CODE_BAD_SESSION}
        if not hmac.compare_digest(credential.encode("utf-8"), self._credentials[role].encode("utf-8")):
            return {"ok": False, "code": CODE_BAD_CREDENTIAL}

        with self._lock:
            self._state.last_seen[role] = self._clock()
            if self._state.aborted and op not in ("status", "end"):
                return {"ok": False, "code": CODE_ABORTED}
            if self._state.ended and op not in ("status", "end", "decision_result"):
                return {"ok": False, "code": CODE_ENDED}
            if op in ATTESTED_OPS and not self._state.attested:
                return {"ok": False, "code": CODE_NOT_ATTESTED}

        if op == "decide_poll":
            return self._op_decide_poll(role, sequence, observation)

        if not self._advance_sequence(role, sequence):
            return {"ok": False, "code": CODE_REPLAY}

        return self._dispatch_op(role, op, observation, sequence)

    def _advance_sequence(self, role: str, sequence: int) -> bool:
        with self._lock:
            last = self._state.last_sequence[role]
            if sequence <= last:
                return False
            self._state.last_sequence[role] = sequence
            return True

    def _dispatch_op(self, role: str, op: str, payload, sequence: int) -> dict:
        with self._lock:
            frozen = self._state.started
            ended = self._state.ended
        if op in COORDINATION_OPS:
            if frozen and op in FROZEN_OPS:
                return {"ok": False, "code": CODE_FROZEN}
            if op == "end":
                return self._op_end(role, payload)
            if op == "status":
                return self._op_status(role, payload)
            if op == "error":
                return self._op_error(role, payload)
            if op == "heartbeat":
                return self._op_heartbeat(role, payload)
            if op == "setup":
                return self._op_setup(role)
            if op == "hello":
                return self._op_hello(role, payload)
            if op == "lobby_code":
                return self._op_lobby_code(payload)
            if op == "join_code":
                return self._op_join_code()
            if op == "ready":
                return self._op_ready(role, payload)
            if op == "start":
                return self._op_start()
        if op == "decide_begin":
            if not self._state.started or ended:
                return {"ok": False, "code": CODE_NOT_STARTED}
            return self._op_decide_begin(payload, sequence)
        if op == "decide_cancel":
            if not self._state.started or ended:
                return {"ok": False, "code": CODE_NOT_STARTED}
            return self._op_decide_cancel(payload, sequence)
        if op == "decision_result":
            if not self._state.started:
                return {"ok": False, "code": CODE_NOT_STARTED}
            # Post-end decision receipts are accepted for recent pending commits
            # within bounds; dedupe/conflict handling lives in the op.
            return self._op_decision_result(payload)
        return {"ok": False, "code": CODE_BAD_OP}

    # -- payload validation --------------------------------------------------

    def _payload_dict(self, payload) -> Optional[dict]:
        if payload is None:
            return {}
        if isinstance(payload, dict):
            return payload
        return None

    def _bounded_field(self, value, limit: int) -> Optional[str]:
        text = _bounded_text(value, limit)
        if text is None or text == "":
            return None
        return text

    # -- coordination ops ----------------------------------------------------

    def _op_hello(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or set(data.keys()) != {"version", "content_digest"}:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        version = self._bounded_field(data.get("version"), 64)
        digest = self._bounded_field(data.get("content_digest"), 256)
        if version is None or digest is None:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        if not hmac.compare_digest(digest.encode("utf-8"), self.content_hash.encode("utf-8")):
            return {"ok": False, "code": CODE_CONTENT_MISMATCH}
        with self._lock:
            if self._state.started:
                return {"ok": False, "code": CODE_FROZEN}
            self._state.hello[role] = {"version": version, "content_digest": digest}
        self._milestone(f"hello_{role}")
        return {
            "ok": True,
            "code": CODE_OK,
            "role": role,
            "ruleset": self.ruleset_label,
            "config_schema": self.config_schema,
        }

    def _op_lobby_code(self, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or set(data.keys()) != {"lobby_code"}:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        code = data.get("lobby_code")
        if not isinstance(code, str) or not LOBBY_PATTERN.match(code):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        with self._lock:
            if self._state.started:
                return {"ok": False, "code": CODE_FROZEN}
            self._state.lobby_code = code
        self._milestone("lobby_code")
        return {"ok": True, "code": CODE_OK}

    def _op_join_code(self) -> dict:
        with self._lock:
            if self._state.started:
                return {"ok": False, "code": CODE_FROZEN}
            code = self._state.lobby_code
        if code is None:
            return {"ok": False, "code": CODE_NO_LOBBY}
        self._milestone("join_code_served")
        return {"ok": True, "code": CODE_OK, "lobby_code": code}

    def _op_ready(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        allowed = {"config_digest", "config_schema", "readiness", "draft_digest"}
        if data is None or not set(data.keys()).issubset(allowed) or "config_digest" not in data:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        digest = self._bounded_field(data.get("config_digest"), MAX_DIGEST_LEN)
        if digest is None or not DIGEST_PATTERN.match(digest):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        schema = data.get("config_schema")
        if self.config_schema is not None:
            # The versioned Ranked contract must be carried explicitly and agree
            # with the pinned schema; it is never inferred or defaulted.
            if schema != self.config_schema:
                return {"ok": False, "code": CODE_CONFIG_MISMATCH}
            # The exact readiness record must be present and every value exactly
            # true. This is not a generic client field: it is the record the
            # source-authenticated runtime produces over the control channel.
            readiness = data.get("readiness")
            if not isinstance(readiness, Mapping) or set(readiness.keys()) != set(RANKED_READINESS_KEYS):
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            for key in RANKED_READINESS_KEYS:
                value = readiness.get(key)
                if key in RANKED_READINESS_EVIDENCE_KEYS:
                    if not isinstance(value, bool):
                        return {"ok": False, "code": CODE_NOT_READY}
                elif value is not True:
                    return {"ok": False, "code": CODE_NOT_READY}
        elif schema is not None or "readiness" in data or "draft_digest" in data:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        # The dedicated draft commitment digest must be carried and match the
        # host's expected value whenever a draft is bound to this session. The
        # runtime derives it independently from the public transcript; a missing
        # or wrong digest is a config mismatch, never an echo of another role.
        draft_digest = data.get("draft_digest")
        if self.draft is not None:
            if not isinstance(draft_digest, str) or not DIGEST_PATTERN.match(draft_digest):
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            if not hmac.compare_digest(draft_digest.encode("utf-8"), self.expected_draft_digest.encode("utf-8")):
                return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        elif draft_digest is not None:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        # M10: the runtime-computed actual digest must equal the trusted
        # host-derived expected digest, never just the other role's value.
        if not hmac.compare_digest(digest.encode("utf-8"), self.expected_config_digest.encode("utf-8")):
            return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        with self._lock:
            if self._state.started:
                return {"ok": False, "code": CODE_FROZEN}
            self._state.ready[role] = {
                "config_digest": digest,
                "config_schema": schema,
                "draft_digest": draft_digest,
            }
        self._milestone(f"ready_{role}")
        return {"ok": True, "code": CODE_OK, "role": role}

    def _op_start(self) -> dict:
        with self._lock:
            if self._state.started:
                return {"ok": False, "code": CODE_ALREADY_STARTED}
            hello = dict(self._state.hello)
            ready = dict(self._state.ready)
        if set(hello.keys()) != set(ROLES) or set(ready.keys()) != set(ROLES):
            return {"ok": False, "code": CODE_NOT_READY}
        if ready["human"]["config_digest"] != ready["ai"]["config_digest"]:
            return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        if ready["human"]["config_digest"] != self.expected_config_digest:
            return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        if self.config_schema is not None:
            for role in ROLES:
                if ready[role].get("config_schema") != self.config_schema:
                    return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        # Every role must have reported the same, expected draft commitment
        # digest whenever a draft is bound.
        if self.draft is not None:
            for role in ROLES:
                if ready[role].get("draft_digest") != self.expected_draft_digest:
                    return {"ok": False, "code": CODE_CONFIG_MISMATCH}
        with self._lock:
            self._state.started = True
        self._milestone("match_started")
        return {"ok": True, "code": CODE_OK, "started": True}

    def _op_status(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or not set(data.keys()).issubset({"seed"}):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        seed = data.get("seed")
        if seed is not None:
            if not isinstance(seed, str) or not SEED_PATTERN.match(seed):
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            # M-6: the seed is trusted human-only audit metadata, accepted exactly
            # once for an initialized active session. The AI role can never set or
            # rewrite it (even by guessing the same value); the role check is
            # deliberately first so an idempotent same-value human duplicate can
            # never become a way to bypass it. A terminal/aborted session never
            # accepts a late first seed after its summary, and the first seed is
            # only accepted once the human's `start` has initialized the run - the
            # real human runtime reports the *resolved* run seed through STATUS
            # after `start` and `host_start_game`, never a menu or prior-run value.
            # In Gauntlet mode the first seed must equal the trusted catalog seed.
            with self._lock:
                state = self._state
                if role != "human":
                    return {"ok": False, "code": CODE_BAD_ROLE}
                if state.terminal or state.aborted:
                    return {"ok": False, "code": CODE_ENDED}
                if not state.started:
                    return {"ok": False, "code": CODE_NOT_STARTED}
                existing = self._logger.seed
                if existing is not None:
                    if existing == seed:
                        pass
                    else:
                        return {"ok": False, "code": CODE_CONFIG_MISMATCH}
                elif self.config.mode == "gauntlet" and seed != self.config.gauntlet_seed:
                    return {"ok": False, "code": CODE_CONFIG_MISMATCH}
                else:
                    self._logger.set_seed(seed)
        with self._lock:
            state = self._state
            return {
                "ok": True,
                "code": CODE_OK,
                "role": role,
                "ruleset": self.ruleset_label,
                "config_schema": self.config_schema,
                "started": state.started,
                "ended": state.ended,
                "aborted": state.aborted,
                "attested": state.attested,
                "error": state.last_error,
                "decisions": state.decisions,
                "failures": state.failures,
                "rejected": state.rejected,
                "difficulty": self.difficulty,
                "pacing": self.config.pacing,
                "mode": self.config.mode,
                "decision_pending": self._pending is not None and not self._pending.done.is_set(),
                "seed_set": self._logger.seed is not None,
                "terminal": state.terminal,
                "terminal_phase": state.terminal_phase,
                "terminal_result": state.terminal_result,
                "terminal_reason": state.terminal_reason,
                "human_end_received": state.human_end is not None,
                "ai_end_received": state.ai_end is not None,
                "result_receipts": len(state.result_receipts),
            }

    def _op_heartbeat(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or not set(data.keys()).issubset({"tick"}):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        if "tick" in data and _bounded_int(data["tick"], 0, MAX_SEQUENCE) is None:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        with self._lock:
            started = self._state.started
            aborted = self._state.aborted
        return {"ok": True, "code": CODE_OK, "role": role, "started": started, "aborted": aborted}

    def _op_setup(self, role: str) -> dict:
        config = self.config
        # The gauntlet seed is trusted setup bound to the coordinator host; the
        # AI role never receives it. It is never forwarded to the worker.
        seed = config.gauntlet_seed if role == "human" else None
        return {
            "ok": True,
            "code": CODE_OK,
            "role": role,
            "ruleset": self.ruleset_label,
            "config_schema": config.config_schema,
            "ruleset_id": config.ruleset_id,
            "gamemode": config.gamemode,
            # Forced config key names only (keyset metadata): the runtime must
            # read the actual values from the live ruleset locally and compute
            # its own digest, never echo the expected digest back. The Ranked
            # path carries no forced-option keyset: the runtime reads the actual
            # layered configuration itself.
            "forced_options": list(config.forced_option_keys),
            "expected_config_digest": self.expected_config_digest,
            # The host-owned completed draft selection (exact keys/types) is
            # carried under the Ranked schema; the runtime independently binds
            # its final deck/stake against the actual initialized lobby.
            "selection": dict(self.selection) if (config.config_schema and self.selection) else None,
            # The dedicated completed-draft commitment (bounded public transcript
            # and final option). The runtime independently validates it and
            # derives the digest; the expected digest is never sent as evidence.
            "draft": dict(config.draft) if (config.config_schema and config.draft) else None,
            "difficulty": self.difficulty,
            "pacing": config.pacing,
            "mode": config.mode,
            "gauntlet": config.gauntlet,
            "gauntlet_seed": seed,
            "match_port": config.match_port,
            "content_hash": self.content_hash,
        }

    def _op_error(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or set(data.keys()) != {"error"}:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        code = data.get("error")
        if not isinstance(code, str) or not CODE_PATTERN.match(code):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        self._mark_error(code)
        return {"ok": True, "code": CODE_OK, "role": role}

    def _op_end(self, role: str, payload) -> dict:
        data = self._payload_dict(payload)
        allowed = {
            "result",
            "human_lives",
            "ai_lives",
            "ante",
            "round",
            "duration_seconds",
            "decisions",
            "rejected",
            "errors",
            # Version-2 receipt-counter semantics (H3). `rejected` counts a refused
            # decision once per delivered sequence; the loop_* fields are separate,
            # bounded wait/backoff metrics so idle frames are never mis-read as
            # refused choices. `counter_version` lets a consumer tell the honest
            # count apart from the historical idle-inflated `ai_rejected` totals.
            "counter_version",
            "loop_idle",
            "loop_transient",
            "loop_empty",
            "loop_no_action",
            "loop_waits",
        }
        if data is None or not set(data.keys()).issubset(allowed):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        summary = {}
        result = data.get("result")
        if result is not None:
            text = self._bounded_field(result, 32)
            if text is None or text not in TERMINAL_RESULTS:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            summary["result"] = text
        # H3/M2: the receipt-counter schema version is explicit. Only the current
        # version is accepted; its absence is an older (legacy) receipt whose
        # `rejected` counted idle frames. Booleans, fractional or unknown versions
        # are refused so a malformed receipt can never masquerade as current.
        if "counter_version" in data:
            version = data["counter_version"]
            if isinstance(version, bool) or not isinstance(version, int) or version != SERVICE_COUNTER_VERSION:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            summary["counter_version"] = SERVICE_COUNTER_VERSION
        else:
            summary["counter_version"] = LEGACY_COUNTER_VERSION
        for key in (
            "human_lives",
            "ai_lives",
            "ante",
            "round",
            "decisions",
            "rejected",
            "errors",
            "loop_idle",
            "loop_transient",
            "loop_empty",
            "loop_no_action",
            "loop_waits",
        ):
            if key in data:
                value = _bounded_int(data[key], 0, MAX_SEQUENCE)
                if value is None:
                    return {"ok": False, "code": CODE_BAD_PAYLOAD}
                summary[key] = value
        if "duration_seconds" in data:
            value = data["duration_seconds"]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            summary["duration_seconds"] = round(float(value), 3)
        with self._lock:
            if not self._state.started:
                return {"ok": False, "code": CODE_NOT_STARTED}
        if role == "ai":
            return self._op_ai_end(summary)
        return self._op_human_end(summary)

    def _op_human_end(self, summary: dict) -> dict:
        """Human coordinator END: the only authorizer of match termination.

        Requires ``started`` and a valid terminal ``result``. Idempotent: a
        duplicate human END returns the same stable ``practice_ok`` code without
        writing another summary. The single terminal summary is written only once
        the terminal phase reaches ``closed`` - either because the AI receipt is
        already present or after the bounded grace expires (M-7).
        """
        with self._lock:
            state = self._state
            if state.human_end is not None:
                return {
                    "ok": True,
                    "code": CODE_OK,
                    "role": "human",
                    "ended": True,
                    "terminal": True,
                    "terminal_phase": state.terminal_phase,
                    "duplicate": True,
                }
            if "result" not in summary:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
            state.human_end = dict(summary)
            state.terminal = True
            state.terminal_result = summary["result"]
            state.terminal_reason = "human_end"
            state.ended = True
            if "human_lives" in summary:
                state.human_lives = summary["human_lives"]
            if "ai_lives" in summary:
                state.ai_lives = summary["ai_lives"]
            if "ante" in summary:
                state.ante = summary["ante"]
            if "round" in summary:
                state.round_number = summary["round"]
            if "duration_seconds" in summary:
                state.duration_seconds = summary["duration_seconds"]
            job = self._pending
            self._pending = None
            row = None
            if state.ai_end is not None:
                state.terminal_phase = TERMINAL_CLOSED
                row = self._finalize_terminal_locked(state.terminal_result, state.terminal_reason, summary)
            else:
                state.terminal_phase = TERMINAL_AWAITING_AI
                state.ai_receipt_deadline = self._clock() + self.ai_receipt_grace
            phase = state.terminal_phase
        if job is not None:
            job.cancel()
        if row is not None:
            self._logger.log_summary(**row)
        return {
            "ok": True,
            "code": CODE_OK,
            "role": "human",
            "ended": True,
            "terminal": True,
            "terminal_phase": phase,
        }

    def _op_ai_end(self, summary: dict) -> dict:
        """AI END receipt: recorded, never authorizes teardown on its own.

        The service exposes the receipt through ``status``/``terminal_summary``
        so the host can bound the wait while it retains the loopback server and
        the service until the human exits. If the human coordinator has already
        ended, the receipt closes the terminal phase and writes the single
        summary now (M-7).
        """
        receipt = dict(summary)
        row = None
        with self._lock:
            state = self._state
            first = state.ai_end is None
            if first:
                state.ai_end = receipt
            if state.terminal and state.terminal_phase == TERMINAL_AWAITING_AI:
                state.terminal_phase = TERMINAL_CLOSED
                row = self._finalize_terminal_locked(state.terminal_result, state.terminal_reason, {})
            response = {
                "ok": True,
                "code": CODE_OK,
                "role": "ai",
                "recorded": first,
                "terminal": state.terminal,
                "ended": state.ended,
                "terminal_phase": state.terminal_phase,
            }
        if row is not None:
            self._logger.log_summary(**row)
        return response

    def _finalize_terminal_locked(self, result: Optional[str], reason: Optional[str], client: Mapping) -> Optional[dict]:
        """Build exactly one terminal summary row; never writes duplicate rows.

        Merges the service's own counters with bounded client counts without
        trusting the client to overwrite them, and includes only known lives,
        duration and result/reason - never full engine state. The AI END's own
        reported result/lives/counters are recorded beside the human's, and a
        human/AI result disagreement is flagged as ``result_conflict`` (M-7).
        """
        state = self._state
        if state.terminal_summary is not None:
            return None
        client = client if isinstance(client, Mapping) else {}
        ai = state.ai_end if isinstance(state.ai_end, Mapping) else {}
        # The human receipt is always stored on the state (whichever END closes
        # the phase), so its own counter version is read from there and is
        # independent of END order.
        human = state.human_end if isinstance(state.human_end, Mapping) else {}

        def merged(key: str, service_value: int) -> int:
            value = client.get(key)
            if isinstance(value, int) and not isinstance(value, bool):
                return max(service_value, value)
            return service_value

        state.terminal = True
        human_result = result if result is not None else client.get("result")
        ai_result = ai.get("result")
        row = {
            "result": human_result,
            "reason": reason,
            "human_lives": state.human_lives if state.human_lives is not None else client.get("human_lives"),
            "ai_lives": state.ai_lives if state.ai_lives is not None else client.get("ai_lives"),
            "ante": state.ante if state.ante is not None else client.get("ante"),
            "round": state.round_number if state.round_number is not None else client.get("round"),
            "duration_seconds": (
                state.duration_seconds if state.duration_seconds is not None else client.get("duration_seconds")
            ),
            "decisions": merged("decisions", state.decisions),
            # Legacy aggregate: the service's own refused-decision total (one per
            # delivered rejection receipt it received), max-merged with the human
            # client's count. It is NOT per-role and is NOT the AI's loop metric.
            "rejected": merged("rejected", state.rejected),
            "errors": merged("errors", state.failures),
            "no_action": state.no_action,
            # H3/M2: the service's OWN final summary always reports the current
            # receipt-counter schema version, independent of which END arrived
            # first and of the human client (who has no loop). The human receipt's
            # own version is kept separately for provenance.
            "counter_version": SERVICE_COUNTER_VERSION,
            "human_counter_version": human.get("counter_version"),
            "terminal": True,
            "terminal_phase": state.terminal_phase,
            "human_end_received": state.human_end is not None,
            "ai_end_received": state.ai_end is not None,
            "ai_result": ai_result,
            "ai_human_lives": ai.get("human_lives"),
            "ai_ai_lives": ai.get("ai_lives"),
            "ai_ante": ai.get("ante"),
            "ai_round": ai.get("round"),
            "ai_duration_seconds": ai.get("duration_seconds"),
            "ai_decisions": ai.get("decisions"),
            "ai_rejected": ai.get("rejected"),
            "ai_errors": ai.get("errors"),
            # Version-2 receipt-counter semantics: the AI's honest receipt count
            # and its separate wait/backoff metrics. `ai_rejected` from a legacy
            # (version-1) AI receipt counted idle frames and is not comparable;
            # `ai_counter_version` states which semantics produced it.
            "ai_counter_version": ai.get("counter_version"),
            "ai_loop_idle": ai.get("loop_idle"),
            "ai_loop_transient": ai.get("loop_transient"),
            "ai_loop_empty": ai.get("loop_empty"),
            "ai_loop_no_action": ai.get("loop_no_action"),
            "ai_loop_waits": ai.get("loop_waits"),
            "result_conflict": bool(
                human_result is not None and ai_result is not None and human_result != ai_result
            ),
        }
        state.terminal_summary = row
        return row

    def _mark_error(self, code: str) -> None:
        with self._lock:
            self._state.last_error = code
            self._state.failures += 1
        self._logger.log_decision(reason=code, errors=code)

    # -- decision ops --------------------------------------------------------

    def _op_decide_begin(self, payload, sequence: int) -> dict:
        observation = payload
        if not isinstance(observation, dict):
            return {"ok": False, "code": CODE_BAD_OBSERVATION}
        try:
            encoded = _json_bytes(observation)
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_BAD_OBSERVATION}
        if len(encoded) > MAX_OBSERVATION_BYTES:
            return {"ok": False, "code": CODE_BAD_OBSERVATION}
        try:
            if _max_depth(observation) > MAX_OBSERVATION_DEPTH:
                return {"ok": False, "code": CODE_BAD_OBSERVATION}
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_BAD_OBSERVATION}

        with self._lock:
            if self._state.aborted:
                return {"ok": False, "code": CODE_ABORTED}
            if self._state.ended:
                return {"ok": False, "code": CODE_ENDED}
            if not self._state.started:
                return {"ok": False, "code": CODE_NOT_STARTED}
            if self._pending is not None:
                return {"ok": False, "code": CODE_DECISION_OUTSTANDING}
            try:
                sanitized, canonical = self._canonicalizer.sanitize(observation)
            except PracticeError as error:
                return {"ok": False, "code": error.code}
            phase = sanitized.get("phase")
            phase = phase if isinstance(phase, str) else None
            job = _DecisionJob(sequence, sanitized, phase, canonical)
            self._pending = job
            self._state.last_decision_sequence = sequence
            self._state.issued_sequences.append(sequence)
            thread = threading.Thread(target=self._run_decision, args=(job,), name="practice-decision", daemon=True)
            job.thread = thread
            thread.start()
        return {"ok": True, "code": CODE_DECISION_PENDING, "sequence": sequence}

    def _op_decision_result(self, payload) -> dict:
        data = self._payload_dict(payload)
        if data is None or not set(data.keys()).issubset({"sequence", "accepted", "code", "version", "tick", "reason"}):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        if "sequence" not in data or "accepted" not in data or "code" not in data:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        sequence = _bounded_int(data["sequence"], 0, MAX_SEQUENCE)
        if sequence is None or not isinstance(data["accepted"], bool):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        code = data["code"]
        if not isinstance(code, str) or not CODE_PATTERN.match(code):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        version = tick = reason = None
        if "version" in data:
            version = _bounded_int(data["version"], 0, MAX_SEQUENCE)
            if version is None:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
        if "tick" in data:
            tick = _bounded_int(data["tick"], 0, MAX_SEQUENCE)
            if tick is None:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
        if "reason" in data:
            reason = self._bounded_field(data["reason"], 128)
            if reason is None:
                return {"ok": False, "code": CODE_BAD_PAYLOAD}
        fingerprint = (data["accepted"], code, version, tick, reason)
        with self._lock:
            known = sequence in self._state.issued_sequences
            if not known:
                return {"ok": False, "code": CODE_DECISION_UNKNOWN, "sequence": sequence}
            prior = self._state.result_receipts.get(sequence)
            if prior is None:
                self._state.result_receipts[sequence] = fingerprint
                self._state.result_order.append(sequence)
                while len(self._state.result_order) > MAX_RESULT_RECEIPTS:
                    oldest = self._state.result_order.popleft()
                    self._state.result_receipts.pop(oldest, None)
                first = True
            elif prior == fingerprint:
                first = False
            else:
                # Exactly-once per sequence: a conflicting second receipt is
                # rejected and neither logged nor allowed to overwrite the first.
                return {"ok": False, "code": CODE_RESULT_CONFLICT, "sequence": sequence}
            if first and not data["accepted"]:
                self._state.rejected += 1
        if not first:
            return {"ok": True, "code": CODE_OK, "sequence": sequence, "duplicate": True}
        self._logger.log_result(
            sequence=sequence,
            accepted=data["accepted"],
            code=code,
            version_id=version,
            tick=tick,
            reason=reason,
        )
        return {"ok": True, "code": CODE_OK, "sequence": sequence, "duplicate": False}

    def _op_decide_poll(self, role: str, sequence: int, payload) -> dict:
        if payload not in (None, {}):
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        with self._lock:
            job = self._pending
            if job is None or job.sequence != sequence:
                return {"ok": False, "code": CODE_DECISION_UNKNOWN, "sequence": sequence}
            if not job.done.is_set():
                return {"ok": True, "code": CODE_DECISION_PENDING, "sequence": sequence}
            self._pending = None
            if job.cancelled:
                return {"ok": False, "code": CODE_DECISION_FAILED, "sequence": sequence}
            if job.ok and isinstance(job.action, dict):
                return {
                    "ok": True,
                    "code": CODE_DECISION_READY,
                    "sequence": sequence,
                    "action": job.action,
                }
            return {"ok": False, "code": job.code, "sequence": sequence}

    def _op_decide_cancel(self, payload, sequence: int) -> dict:
        """Cancel exactly the pending job the caller names, never another one.

        The envelope takes a fresh monotonic sequence; the payload carries the
        original ``decide_begin`` wire sequence the caller owns. A duplicate or
        unknown ``decision_sequence`` is a bounded, non-fatal code and leaves the
        outstanding job untouched. The cancel flags the owned job under the lock
        before clearing the slot so a worker that races completion cannot finish
        the job after the cancel is accepted.
        """
        data = self._payload_dict(payload)
        if data is None or set(data.keys()) != {"decision_sequence"}:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        decision_sequence = _bounded_int(data.get("decision_sequence"), 0, MAX_SEQUENCE)
        if decision_sequence is None:
            return {"ok": False, "code": CODE_BAD_PAYLOAD}
        with self._lock:
            if self._state.aborted:
                return {"ok": False, "code": CODE_ABORTED}
            if self._state.ended:
                return {"ok": False, "code": CODE_ENDED}
            if not self._state.started:
                return {"ok": False, "code": CODE_NOT_STARTED}
            job = self._pending
            if job is None or job.sequence != decision_sequence:
                return {"ok": False, "code": CODE_DECISION_UNKNOWN, "sequence": decision_sequence}
            job.cancelled = True
            self._pending = None
        job.cancel()
        return {"ok": True, "code": CODE_DECISION_CANCELLED, "sequence": decision_sequence}

    def _run_decision(self, job: _DecisionJob) -> None:
        start = self._clock()
        try:
            source = self._source_provider.source(self.difficulty)
        except PracticeError as error:
            self._finish(job, ok=False, code=error.code, latency=self._clock() - start)
            return
        except Exception:  # noqa: BLE001
            self._finish(job, ok=False, code=CODE_SOURCE_UNAVAILABLE, latency=self._clock() - start)
            return
        request = {"runtime": WORKER_RUNTIME, "source": source, "observation": job.observation}
        try:
            response = self._worker_runner(request, self.decision_timeout, job.register_process)
        except Exception:  # noqa: BLE001
            response = {"ok": False, "code": CODE_WORKER_FAILED}
        if job.cancelled:
            return
        latency = self._clock() - start
        if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
            self._finish(job, ok=False, code=CODE_WORKER_FAILED, latency=latency)
            return
        if response.get("ok") is True:
            action = response.get("action")
            if not isinstance(action, dict):
                self._finish(job, ok=False, code=CODE_WORKER_FAILED, latency=latency)
                return
            self._finish(job, ok=True, code=CODE_OK, action=action, latency=latency)
            return
        code = response.get("code")
        if not isinstance(code, str) or not CODE_PATTERN.match(code):
            code = CODE_WORKER_FAILED
        self._finish(job, ok=False, code=code, latency=latency)

    def _finish(self, job: _DecisionJob, *, ok: bool, code: str, action=None, latency=None) -> None:
        with self._lock:
            if job.cancelled:
                return
            job.ok = bool(ok)
            job.code = code
            job.action = action if isinstance(action, dict) else None
            job.latency = latency
            self._state.decisions += 1
            no_action = not ok and code == CODE_POLICY_NO_ACTION
            if no_action:
                self._state.no_action += 1
            elif not ok:
                self._state.failures += 1
                self._state.last_error = code
            job.done.set()
        self._logger.log_decision(
            tick=job.sequence,
            phase=job.phase,
            hash=_canonical_hash(job.canonical) if job.canonical else _observation_hash(job.observation),
            action=_action_summary(job.action, job.observation),
            reason=code,
            latency=round(latency, 6) if isinstance(latency, (int, float)) else None,
            errors=None if ok or no_action else code,
            ui=_ui_facts(job.observation),
        )


_UI_TEXT_MAX = 32
_UI_LEVELS_MAX = 16


def _ui_facts(observation) -> Optional[dict]:
    """The AI's own UI-visible play-phase facts, so a local run can be checked
    against the Balatro screen (LV-7): hand size, the displayed blind
    requirement and score, and Run Info hand levels. Bounded; nothing that is
    not already in the sanitized observation."""
    if not isinstance(observation, dict):
        return None
    own = observation.get("self")
    if not isinstance(own, dict) or not isinstance(own.get("hand"), list):
        return None
    facts: dict = {"hand_size": len(own["hand"])}
    for key in ("blind_requirement", "current_score"):
        value = own.get(key)
        if isinstance(value, str) and len(value) <= _UI_TEXT_MAX:
            facts[key] = value
    levels = own.get("hand_levels")
    if isinstance(levels, dict):
        out = {}
        for name in sorted(levels)[:_UI_LEVELS_MAX]:
            entry = levels[name]
            if isinstance(name, str) and len(name) <= _UI_TEXT_MAX and isinstance(entry, dict):
                triple = [entry.get("level"), entry.get("chips"), entry.get("mult")]
                if all(isinstance(v, int) and not isinstance(v, bool) for v in triple):
                    out[name] = triple
        if out:
            facts["hand_levels"] = out
    return facts


def _canonical_hash(canonical: str) -> str:
    try:
        import hashlib

        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]
    except Exception:  # noqa: BLE001
        return ""


def _observation_hash(observation) -> str:
    try:
        import hashlib

        return hashlib.sha256(_json_bytes(observation)).hexdigest()[:16]
    except Exception:  # noqa: BLE001
        return ""


# Allowlisted hand-targeted Tarots only (docs/HAND_TARGETS_DESIGN.md v1). A
# center outside this set is never written to the decision log.
_HAND_TAROT_CENTERS = frozenset({
    "c_strength", "c_death", "c_lovers", "c_chariot", "c_justice", "c_devil",
    "c_star", "c_moon", "c_sun", "c_world",
})


def _tarot_center(observation, source_ref) -> Optional[str]:
    """The allowlisted Tarot center for a hand-targeted use.

    Derived only from the sanitized observation's own consumables, by the exact
    ``source_ref`` the policy selected. Any other or missing center is omitted,
    so a hidden or unexpected value can never be logged.
    """
    if not isinstance(source_ref, str) or not isinstance(observation, dict):
        return None
    self_view = observation.get("self")
    if not isinstance(self_view, dict):
        return None
    consumables = self_view.get("consumables")
    if not isinstance(consumables, list):
        return None
    for item in consumables:
        if isinstance(item, dict) and item.get("id") == source_ref:
            center = item.get("center")
            if isinstance(center, str) and center in _HAND_TAROT_CENTERS:
                return center
            return None
    return None


def _action_summary(action, observation=None) -> Optional[dict]:
    if not isinstance(action, dict):
        return None
    kind = _bounded_text(action.get("type"), 32)
    summary = {"type": kind}
    refs = action.get("card_refs")
    if isinstance(refs, list):
        summary["cards"] = len(refs)
        if kind == "USE_CONSUMABLE_ON_HAND":
            # Exact positional hand refs, bounded and without any card value.
            summary["card_refs"] = [
                bounded for bounded in (_bounded_text(ref, 16) for ref in refs[:8]) if bounded is not None
            ]
    targets = action.get("target_refs")
    if isinstance(targets, list):
        summary["targets"] = len(targets)
    order = action.get("order")
    if isinstance(order, list):
        summary["order"] = len(order)
    if kind == "USE_CONSUMABLE_ON_HAND":
        source_ref = action.get("source_ref")
        bounded_source = _bounded_text(source_ref, 32)
        if bounded_source is not None:
            summary["source_ref"] = bounded_source
        center = _tarot_center(observation, source_ref)
        if center is not None:
            summary["tarot"] = center
    return summary


class _ControlHandler(socketserver.StreamRequestHandler):
    def setup(self) -> None:
        super().setup()
        try:
            self.connection.settimeout(self.server.service.socket_timeout)
        except Exception:  # noqa: BLE001
            pass

    def _send(self, response: dict) -> bool:
        try:
            self.wfile.write((_encode_response(response) + "\n").encode("utf-8"))
            self.wfile.flush()
            return True
        except Exception:  # noqa: BLE001
            return False

    def handle(self) -> None:
        service: PracticeService = self.server.service
        if not service.acquire_connection():
            self._send({"ok": False, "code": CODE_BUSY})
            return
        limiter = service.new_rate_limiter()
        try:
            while True:
                try:
                    line = self.rfile.readline(MAX_REQUEST_BYTES + 2)
                except (_socket.timeout, OSError):
                    break
                except Exception:  # noqa: BLE001
                    break
                if not line:
                    break
                if len(line) > MAX_REQUEST_BYTES + 1:
                    self._send({"ok": False, "code": CODE_INPUT_TOO_LARGE})
                    break
                if not limiter.allow():
                    self._send({"ok": False, "code": CODE_RATE_LIMITED})
                    break
                response = service.handle_line(line)
                if not self._send(response):
                    break
        finally:
            service.release_connection()


class _ControlServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, service: PracticeService) -> None:
        self.service = service
        super().__init__(address, _ControlHandler)


def encode_response(response: Mapping) -> str:
    """Public bounded encoder used by tests and future wrappers."""
    return _encode_response(response)


__all__ = [
    "PracticeError",
    "PracticeService",
    "ServiceConfig",
    "RateLimiter",
    "LocalLogger",
    "BaselineSourceProvider",
    "CanonicalObservation",
    "run_policy_worker",
    "encode_response",
    "fnv1a32_hex",
    "major_league_digest",
    "ATTESTED_OPS",
    "TERMINAL_RESULTS",
    "TERMINAL_PHASES",
    "MAJOR_LEAGUE_RULESET_ID",
    "GAUNTLET_SEEDS",
    "DIFFICULTIES",
    "PACING",
    "MODES",
    "ROLES",
    "OPS",
    "VERSION",
    "DEFAULT_ACTION_TYPES",
]
