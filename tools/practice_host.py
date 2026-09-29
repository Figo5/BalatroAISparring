#!/usr/bin/env python3
"""External practice host: local daemon and closed-game match supervisor.

This is the outside-process component the installed companion menu talks to. It
is deliberately *not* inside the game: it runs as an ordinary local Python
process, binds a loopback-only authenticated control socket, and only ever acts
after the user's ordinary Balatro process has exited naturally.

Scope of this module (repository-only, no live writes by the developer):

- **Trusted configuration.** Every path, executable, pin and root comes from
  :class:`HostConfig` built in the repository, never from a menu request. The
  menu can only send validated enums/indexes and the exact live PID/create time.
- **Private discovery marker.** The daemon writes a discovery file under
  the gitignored repository ``work/`` tree (never a save directory) recording its
  exact PID, create time, session, bound port and module hash. A live duplicate
  is refused; a stale marker is replaced explicitly.
- **Closed-game transition.** ``start`` returns an acknowledgement only when the
  request is admissible and recorded; it never launches anything. A supervisor
  thread waits for the exact original live process to exit on its own (using a
  query-only native handle that can never terminate it), re-runs every
  fail-closed gate, and only then launches the staged pair.
- **Match supervision.** The adapted pinned local server, the trusted control
  service and the two staged roles are owned by exact handles. The supervisor
  terminates only those exact owned handles on peer/server/service failure and
  preserves logs.

Importing this module performs no work and opens no socket. Tests drive the
daemon and supervisor with injected fakes. No game, live path, save or external
network is touched by the module's tests.

The immutable two-layer isolation certificate
(``tools/isolation_certificate.py``, owned by the certificate worker) is reused,
never rebased or re-recorded, and the per-session live byte diff owns
revocation/lockout. Integration notes are documented in
``docs/PRACTICE_HOST.md``; they are honest gaps, never forged evidence.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence

TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import launch_practice  # noqa: E402
import practice_service  # noqa: E402
import ruleset_contract  # noqa: E402
import staging  # noqa: E402

try:  # the certificate worker owns this module; integrate when present
    import isolation_certificate  # noqa: E402
except Exception:  # noqa: BLE001
    isolation_certificate = None

VERSION = "practice_host/1"
DISCOVERY_SCHEMA = "aisparring.practice_host.discovery.v1"
REQUEST_SCHEMA = "aisparring.practice_host.request.v1"
SESSION_MANIFEST_SCHEMA = "aisparring.practice_session.v1"
REPORT_SCHEMA = "aisparring.practice_host_report.v1"

HOST = "127.0.0.1"
DISCOVERY_NAME = "practice_host.json"
MAX_REQUEST_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
MAX_LINE_BYTES = 64 * 1024
DEFAULT_LIVE_EXIT_TIMEOUT = 300.0
DEFAULT_MATCH_TIMEOUT = 7200.0
DEFAULT_PRESTART_TIMEOUT = 120.0
DEFAULT_POLL_INTERVAL = 1.0
SERVER_ENTRY = "dist/main.js"
SERVER_SOURCE_ENTRY = "src/main.ts"
# Shared, colon-free session grammar owned by the certificate module (NM7/M6).
SESSION_ID_RE = getattr(
    isolation_certificate, "SESSION_ID_RE", re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
)

SERVER_PIN = "d664c29523b827d53dfa1a181e5b2baf1aefac4f"
SERVER_CHANGES = (
    "match listener bound to 127.0.0.1",
    "admin listener disabled",
)
SERVER_BIND_OK = "server.listen(PORT, '127.0.0.1', () => {"
SERVER_BIND_BAD = "server.listen(PORT, '0.0.0.0', () => {"
SERVER_ADMIN_OK = "// AISparring local adaptation: unused admin listener disabled."
SERVER_ADMIN_BAD = "adminServer.listen(ADMIN_PORT, '127.0.0.1', () => {"

MENU_OPS = ("available", "start", "poll", "status", "acknowledge")
PHASES = (
    "accepted",
    "waiting_live_exit",
    "blocked",
    "launching",
    "attesting",
    "running",
    "awaiting_human_exit",
    "ending",
    "completed",
    "failed",
    "void",
)

HOST_LOCKOUT_NAME = "host_lockout.json"
ATTESTATION_NAME = staging.LAUNCHER_ATTESTATION_NAME
ATTESTATION_SCHEMA = staging.LAUNCHER_ATTESTATION_SCHEMA
DEFAULT_QUIESCENCE_SECONDS = 5.0
DEFAULT_ATTESTATION_TIMEOUT = 90.0

REQUEST_KEYS = frozenset({"schema", "op", "auth", "request"})
START_REQUEST_KEYS = frozenset(
    {"session_id", "difficulty", "pacing", "mode", "gauntlet", "live_pid", "live_create_time"}
)
POLL_REQUEST_KEYS = frozenset({"ticket"})

TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
SECRET_RE = re.compile(r"^[0-9a-f]{32,128}$")

# Bounded, non-leaking failure codes. None of these strings can carry a path,
# credential, session id or exception text.
CODE_OK = "practice_host_ok"
CODE_BAD_LINE = "practice_host_bad_line"
CODE_INPUT_TOO_LARGE = "practice_host_input_too_large"
CODE_BAD_REQUEST = "practice_host_bad_request"
CODE_BAD_AUTH = "practice_host_bad_auth"
CODE_BAD_OP = "practice_host_bad_op"
CODE_BAD_ENUM = "practice_host_bad_enum"
CODE_BAD_LIVE_PID = "practice_host_bad_live_pid"
CODE_LIVE_IDENTITY_MISMATCH = "practice_host_live_identity_mismatch"
CODE_LIVE_NOT_INSTALL = "practice_host_live_not_install"
CODE_ACCEPTED = "practice_host_start_accepted"
CODE_TICKET_ACTIVE = "practice_host_ticket_active"
CODE_TICKET_UNKNOWN = "practice_host_ticket_unknown"
CODE_HOST_BUSY = "practice_host_busy"
CODE_HOST_CLOSED = "practice_host_closed"
CODE_INTERNAL = "practice_host_internal_error"
CODE_REQUIRES_FRESH_PROOF = "practice_requires_fresh_isolation_proof"
CODE_CERTIFICATE_REQUIRED = "practice_requires_isolation_certificate"
CODE_CERTIFICATE_API_MISSING = "practice_certificate_api_missing"
CODE_CERTIFICATE_LOCKED = "practice_certificate_locked_out"
CODE_QUIESCENCE = "practice_steam_userdata_not_quiescent"
CODE_FRESH_BACKUP_REQUIRED = "practice_requires_fresh_backup_baseline"
CODE_ATTESTATION = "practice_attestation_failed"
CODE_LIVE_APPEARED = "practice_live_game_appeared"
CODE_HUMAN_EXIT_UNVERIFIED = "practice_human_exit_unverified"
CODE_HUMAN_EXIT_BEFORE_END = "practice_human_exited_before_end"
CODE_ACK_REQUIRED = "practice_host_ack_required"
CODE_DESCRIPTOR_ENV_GAP = "practice_descriptor_env_unbound"
CODE_STATIC_GATES_FAILED = "practice_static_gates_failed"
CODE_SERVER_ADAPTATION = "practice_server_adaptation_unproven"
CODE_MATCH_PORT = "practice_match_port_unavailable"
CODE_MATCH_PORT_UNCONFIGURED = "practice_match_port_unconfigured"
CODE_STAGED_ENDPOINTS = "practice_staged_endpoints_unproven"
CODE_LISTENER_UNPROVEN = "practice_listener_unproven"
CODE_LISTENER_OWNER = "practice_listener_owner_unproven"
CODE_LIVE_TIMEOUT = "practice_live_exit_timeout"
CODE_LIVE_UNVERIFIED = "practice_live_exit_unverified"
CODE_LIVE_EXITED = "practice_live_exit_observed"
CODE_LAUNCH_FAILED = "practice_launch_failed"
CODE_SERVER_FAILED = "practice_server_failed"
CODE_ROLE_EXITED = "practice_role_exited"
CODE_LIVE_CHANGED = "practice_live_state_changed"
CODE_STALE_DISCOVERY = "practice_host_stale_discovery"
CODE_FOREIGN_DISCOVERY = "practice_host_foreign_discovery"
CODE_ALREADY_RUNNING = "practice_host_already_running"
CODE_OPEN_RECORD_BLOCKED = "practice_session_open_unmeasured"
CODE_CLOSURE_PENDING = "practice_host_closure_pending"
CODE_SESSION_WORKSPACE_EXISTS = "practice_session_workspace_exists"
CODE_HUMAN_ACTIVE = "practice_human_window_active"
CODE_CONFIG_DIGEST = "practice_major_league_config_unproven"
CODE_MEASUREMENT_API_MISSING = "practice_measurement_api_missing"
CODE_RUNTIME_PREFLIGHT = "practice_runtime_preflight_failed"


class HostError(Exception):
    """Bounded, non-leaking host failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code if TOKEN_RE.match(code) else CODE_INTERNAL


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
    return json.loads(text, object_pairs_hook=_no_duplicate_keys, parse_constant=_reject_constant)


def _json_bytes(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True, allow_nan=False).encode("utf-8")


def encode_response(response: Mapping) -> str:
    try:
        encoded = json.dumps(response, separators=(",", ":"), sort_keys=True, allow_nan=False)
    except Exception:  # noqa: BLE001
        encoded = json.dumps({"ok": False, "code": CODE_INTERNAL}, separators=(",", ":"), sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        encoded = json.dumps(
            {"ok": False, "code": "practice_host_output_too_large"}, separators=(",", ":"), sort_keys=True
        )
    return encoded


def module_sha256(path=None) -> str:
    target = Path(path or __file__)
    return hashlib.sha256(target.read_bytes()).hexdigest()


# ---------------------------------------------------------------------------
# Runtime / policy-source preflight (bounded, read-only, never spawns)
# ---------------------------------------------------------------------------

# The Lua runtime the service actually renders policy through. At least this one
# must import and instantiate before the host acknowledges a quit/start, so a
# missing interpreter is a clear refusal instead of a late policy failure.
RUNTIME_PREFLIGHT_RUNTIMES = ("luajit21",)
RUNTIME_PREFLIGHT_SOURCES = (
    ("policy_worker", TOOLS_DIR / "policy_worker.py"),
    ("policy_env", TOOLS_DIR / "lua" / "policy_env.lua"),
    ("baseline_policy", REPO_DIR / "AISparring" / "ai" / "baseline_policy.lua"),
    ("codec", REPO_DIR / "AISparring" / "ai" / "codec.lua"),
    ("observation", REPO_DIR / "AISparring" / "ai" / "observation.lua"),
)


def _instantiate_lua_runtime(runtime: str):
    import importlib

    module = importlib.import_module(f"lupa.{runtime}")
    factory = getattr(module, "LuaRuntime", None)
    if factory is None:
        raise RuntimeError("runtime_factory_missing")
    return factory(register_eval=False, register_builtins=False)


def default_runtime_checker(config: HostConfig) -> dict:
    """Bounded read-only preflight of the policy source, canonicalizer and Lua runtime.

    No game, worker or server process is ever launched. This only reads the
    repository policy/canonicalizer sources, imports and instantiates the required
    Lua runtime, renders the baseline policy source for every difficulty and proves
    the canonicalizer chunk loads. Unavailable interpreter/dependencies return a
    bounded, useful refusal so the host never acknowledges a quit/start and then
    fails later in policy.
    """
    problems: list = []
    for label, path in RUNTIME_PREFLIGHT_SOURCES:
        if not Path(path).is_file():
            problems.append(f"runtime_source_missing:{label}")
    if problems:
        return {"ok": False, "code": CODE_RUNTIME_PREFLIGHT, "problems": sorted(problems)}
    for runtime in RUNTIME_PREFLIGHT_RUNTIMES:
        try:
            _instantiate_lua_runtime(runtime)
        except Exception:  # noqa: BLE001
            problems.append(f"runtime_unavailable:{runtime}")
    try:
        provider = practice_service.BaselineSourceProvider()
        for difficulty in practice_service.DIFFICULTIES:
            source = provider.source(difficulty)
            if not isinstance(source, str) or not source:
                problems.append("policy_source_unavailable")
                break
    except Exception:  # noqa: BLE001
        problems.append("policy_source_unavailable")
    try:
        canonicalizer = practice_service.CanonicalObservation()
        try:
            canonicalizer.sanitize({})
        except practice_service.PracticeError as error:
            if error.code == practice_service.CODE_CANONICAL_UNAVAILABLE:
                problems.append("canonicalizer_unavailable")
        except Exception:  # noqa: BLE001
            problems.append("canonicalizer_unavailable")
    except Exception:  # noqa: BLE001
        problems.append("canonicalizer_unavailable")
    return {
        "ok": not problems,
        "code": CODE_OK if not problems else CODE_RUNTIME_PREFLIGHT,
        "problems": sorted(set(problems)),
        "runtimes": list(RUNTIME_PREFLIGHT_RUNTIMES),
    }


def runtime_preflight(config: HostConfig, *, checker=None) -> dict:
    """Run the injected checker (default: the real bounded preflight) fail-closed."""
    checker = checker or default_runtime_checker
    try:
        verdict = checker(config)
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": CODE_RUNTIME_PREFLIGHT, "problems": ["runtime_preflight_failed"]}
    if not isinstance(verdict, dict) or not verdict.get("ok"):
        result = dict(verdict) if isinstance(verdict, dict) else {}
        result["ok"] = bool(result.get("ok"))
        result["code"] = result.get("code") or CODE_RUNTIME_PREFLIGHT
        result.setdefault("problems", [])
        return result
    return verdict


# ---------------------------------------------------------------------------
# Trusted configuration
# ---------------------------------------------------------------------------

@dataclass(frozen=True, eq=False)
class HostConfig:
    """Repository-owned trusted configuration. Never accepted from a menu request."""

    repo_root: Path
    work_dir: Path
    session_root: Path
    staging_root: Path
    backup_root: Path
    live_install_root: Path
    live_appdata_root: Path
    steam_root: Path
    server_root: Path
    server_manifest: Path
    node_executable: str
    python_executable: str
    match_port: Optional[int]
    gauntlet_catalog: Mapping[str, str]
    server_pin: str = SERVER_PIN
    discovery_path: Optional[Path] = None
    bind_port: int = 0
    require_fixed_match_port: bool = True
    allow_endpoint_reconfigure: bool = False
    strict_listener_verification: bool = True
    leave_human_visible: bool = True
    live_exit_timeout: float = DEFAULT_LIVE_EXIT_TIMEOUT
    match_timeout: float = DEFAULT_MATCH_TIMEOUT
    # The bounded window between spawn and ``running`` is a *separate* deadline
    # from the two-hour match timeout (H3/M9).
    prestart_timeout: float = DEFAULT_PRESTART_TIMEOUT
    poll_interval: float = DEFAULT_POLL_INTERVAL
    server_start_timeout: float = 15.0
    quiescence_seconds: float = DEFAULT_QUIESCENCE_SECONDS
    attestation_timeout: float = DEFAULT_ATTESTATION_TIMEOUT
    require_certificate: bool = True
    require_attestation: bool = True
    server_runtime_deps: tuple = ("better-sqlite3", "uuid")

    def resolved_discovery_path(self) -> Path:
        return Path(self.discovery_path) if self.discovery_path else Path(self.work_dir) / DISCOVERY_NAME


def default_config(repo_root=None, **overrides) -> HostConfig:
    repo = Path(repo_root or REPO_DIR)
    work = repo / "work" / "aisparring-host"
    values = dict(
        repo_root=repo,
        work_dir=work,
        session_root=work / "sessions",
        staging_root=Path(staging.DEFAULT_STAGING_ROOT),
        backup_root=Path(staging.DEFAULT_BACKUP_ROOT),
        live_install_root=Path(staging.DEFAULT_INSTALL),
        live_appdata_root=Path(staging.default_live_appdata()),
        steam_root=Path(staging.STEAM_ROOT_DEFAULT),
        server_root=repo / "work" / "local-server",
        server_manifest=repo / "work" / "local-server" / "AISparring-adaptation.json",
        node_executable="node",
        python_executable=sys.executable,
        match_port=None,
        gauntlet_catalog=dict(practice_service.GAUNTLET_SEEDS),
    )
    values.update(overrides)
    return HostConfig(**values)


def validate_config(config: HostConfig) -> None:
    if not isinstance(config, HostConfig):
        raise HostError(CODE_BAD_REQUEST)
    if not config.gauntlet_catalog or set(config.gauntlet_catalog) != set(practice_service.GAUNTLET_SEEDS):
        raise HostError(CODE_BAD_REQUEST)
    for label, seed in config.gauntlet_catalog.items():
        if practice_service.GAUNTLET_SEEDS.get(label) != seed:
            raise HostError(CODE_BAD_REQUEST)
    if config.match_port is not None and _bounded_int(config.match_port, 1, 65535) is None:
        raise HostError(CODE_BAD_REQUEST)
    for value in (config.live_exit_timeout, config.match_timeout, config.prestart_timeout, config.poll_interval):
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
            raise HostError(CODE_BAD_REQUEST)


# ---------------------------------------------------------------------------
# Native live-process identity (query-only; never a termination method)
# ---------------------------------------------------------------------------

def _query_handle(pid: int):
    opener = getattr(launch_practice.NativeProcessHandle, "open")
    return opener(int(pid), access=launch_practice.PROCESS_QUERY_LIMITED_INFORMATION)


def read_live_identity(pid: int, opener=None) -> Optional[dict]:
    """Read pid/create-time/image from one query-only handle. No termination."""
    opener = opener or _query_handle
    handle = None
    try:
        handle = opener(int(pid))
    except Exception:  # noqa: BLE001
        return None
    if handle is None:
        return None
    try:
        try:
            create_time = handle.create_time()
            image_path = handle.image_path()
        except Exception:  # noqa: BLE001
            return None
        return {"pid": int(pid), "create_time": create_time, "image_path": image_path}
    finally:
        try:
            handle.close()
        except Exception:  # noqa: BLE001
            pass


def verify_live_target(config: HostConfig, live_pid: int, live_create_time, opener=None) -> dict:
    """Prove the exact live PID/create-time/image is the user's installed Balatro."""
    identity = read_live_identity(live_pid, opener=opener)
    if identity is None:
        return {"ok": False, "code": "practice_live_handle_unavailable", "pid": int(live_pid)}
    create_time = identity.get("create_time")
    if create_time is None:
        return {"ok": False, "code": "practice_live_create_time_unavailable", "pid": int(live_pid)}
    if abs(float(create_time) - float(live_create_time)) > launch_practice.START_TIME_TOLERANCE:
        return {"ok": False, "code": CODE_LIVE_IDENTITY_MISMATCH, "pid": int(live_pid)}
    image_path = identity.get("image_path")
    if not launch_practice.is_live_install_path(image_path, config.live_install_root):
        return {"ok": False, "code": CODE_LIVE_NOT_INSTALL, "pid": int(live_pid)}
    return {
        "ok": True,
        "code": CODE_OK,
        "pid": int(live_pid),
        "create_time": float(create_time),
        "image_path": str(image_path),
    }


def wait_for_live_exit(
    config: HostConfig,
    live_pid: int,
    live_create_time: float,
    *,
    timeout: Optional[float] = None,
    poll_interval: Optional[float] = None,
    enumerator=None,
    opener=None,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict:
    """Wait for the exact original live process to exit on its own.

    Uses only a query-only native handle. On timeout it returns
    ``practice_live_exit_timeout`` and *never* terminates the process. A PID
    reuse (same pid, different create time) counts as the original having
    exited. If identity cannot be confirmed (no handle and enumeration is
    unavailable) it fails closed instead of assuming an exit.
    """
    deadline = clock() + (timeout if timeout is not None else float(config.live_exit_timeout))
    interval = float(poll_interval if poll_interval is not None else config.poll_interval)
    enumerator = enumerator or launch_practice.default_enumerator()
    while True:
        identity = read_live_identity(live_pid, opener=opener)
        if identity is None:
            observed = _confirm_absent(enumerator, live_pid, live_create_time)
            if observed["code"] == "practice_live_exit_unverified":
                return {"ok": False, "code": CODE_LIVE_UNVERIFIED, "pid": int(live_pid)}
            if observed["code"] == "practice_live_exit_pid_reused":
                return {"ok": True, "code": CODE_LIVE_EXITED, "pid": int(live_pid), "pid_reused": True}
            if observed["ok"]:
                return {"ok": True, "code": CODE_LIVE_EXITED, "pid": int(live_pid), "pid_reused": False}
            # still running per enumeration but the handle is gone: keep waiting
        else:
            create_time = identity.get("create_time")
            if create_time is None:
                return {"ok": False, "code": CODE_LIVE_UNVERIFIED, "pid": int(live_pid)}
            if abs(float(create_time) - float(live_create_time)) > launch_practice.START_TIME_TOLERANCE:
                return {"ok": True, "code": CODE_LIVE_EXITED, "pid": int(live_pid), "pid_reused": True}
            if not launch_practice.is_live_install_path(identity.get("image_path"), config.live_install_root):
                return {"ok": False, "code": CODE_LIVE_UNVERIFIED, "pid": int(live_pid)}
        if clock() >= deadline:
            return {"ok": False, "code": CODE_LIVE_TIMEOUT, "pid": int(live_pid), "terminated": False}
        sleeper(interval)


def _confirm_absent(enumerator, live_pid: int, live_create_time: float) -> dict:
    try:
        processes = enumerator.list()
    except staging.StagingError:
        return {"ok": False, "code": "practice_live_exit_unverified"}
    for info in processes:
        if int(getattr(info, "pid", -1)) != int(live_pid):
            continue
        info_time = float(getattr(info, "create_time", 0) or 0)
        if not info_time:
            return {"ok": False, "code": "practice_live_exit_unverified"}
        if abs(info_time - float(live_create_time)) <= launch_practice.START_TIME_TOLERANCE:
            return {"ok": False, "code": "practice_live_still_running"}
        return {"ok": True, "code": "practice_live_exit_pid_reused"}
    return {"ok": True, "code": CODE_LIVE_EXITED}


# ---------------------------------------------------------------------------
# Listener verification (native TCP table preferred; injectable)
# ---------------------------------------------------------------------------

_TCP_TABLE_OWNER_PID_LISTENER = 3
_AF_INET = 2
_AF_INET6 = 23
_TCP_STATE_LISTEN = 2


class _MibTcpRowOwnerPid(ctypes.Structure):
    _fields_ = [
        ("dwState", ctypes.c_uint32),
        ("dwLocalAddr", ctypes.c_uint32),
        ("dwLocalPort", ctypes.c_uint32),
        ("dwRemoteAddr", ctypes.c_uint32),
        ("dwRemotePort", ctypes.c_uint32),
        ("dwOwningPid", ctypes.c_uint32),
    ]


class _MibTcpTableOwnerPid(ctypes.Structure):
    _fields_ = [("dwNumEntries", ctypes.c_uint32), ("table", _MibTcpRowOwnerPid * 1)]


class _MibTcp6RowOwnerPid(ctypes.Structure):
    _fields_ = [
        ("ucLocalAddr", ctypes.c_ubyte * 16),
        ("dwLocalScopeId", ctypes.c_uint32),
        ("dwLocalPort", ctypes.c_uint32),
        ("ucRemoteAddr", ctypes.c_ubyte * 16),
        ("dwRemoteScopeId", ctypes.c_uint32),
        ("dwRemotePort", ctypes.c_uint32),
        ("dwState", ctypes.c_uint32),
        ("dwOwningPid", ctypes.c_uint32),
    ]


class _MibTcp6TableOwnerPid(ctypes.Structure):
    _fields_ = [("dwNumEntries", ctypes.c_uint32), ("table", _MibTcp6RowOwnerPid * 1)]


def _probe_tcp_table(port: int, family: int) -> Optional[dict]:
    """Return bound addresses+PIDs for one address family from the Windows table."""
    if os.name != "nt":
        return None
    try:
        iphlpapi = ctypes.WinDLL("iphlpapi", use_last_error=True)
    except OSError:
        return None
    iphlpapi.GetExtendedTcpTable.restype = ctypes.c_uint32
    iphlpapi.GetExtendedTcpTable.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_int,
        ctypes.c_uint32,
        ctypes.c_int,
        ctypes.c_uint32,
    ]
    size = ctypes.c_uint32(0)
    result = iphlpapi.GetExtendedTcpTable(None, ctypes.byref(size), False, family, _TCP_TABLE_OWNER_PID_LISTENER, 0)
    if result != 122:  # ERROR_INSUFFICIENT_BUFFER
        return None
    buffer = ctypes.create_string_buffer(size.value)
    result = iphlpapi.GetExtendedTcpTable(
        buffer, ctypes.byref(size), False, family, _TCP_TABLE_OWNER_PID_LISTENER, 0
    )
    if result != 0:
        return None
    addresses: list = []
    pids: set = set()
    if family == _AF_INET:
        table = ctypes.cast(buffer, ctypes.POINTER(_MibTcpTableOwnerPid)).contents
        rows = ctypes.cast(
            ctypes.addressof(table) + _MibTcpTableOwnerPid.dwNumEntries.size,
            ctypes.POINTER(_MibTcpRowOwnerPid),
        )
        addr_offset = _MibTcpRowOwnerPid.dwLocalAddr.offset
        for index in range(int(table.dwNumEntries)):
            row = rows[index]
            if int(row.dwState) != _TCP_STATE_LISTEN:
                continue
            if int(socket.ntohs(int(row.dwLocalPort) & 0xFFFF)) != int(port):
                continue
            # ``row.dwLocalAddr`` is a scalar field exposing a Python int, so read
            # the raw 4 network-order bytes out of the shared row memory instead of
            # taking ``byref`` of an int (which raises TypeError).
            raw = ctypes.string_at(ctypes.addressof(row) + addr_offset, 4)
            addresses.append(socket.inet_ntoa(raw))
            pids.add(int(row.dwOwningPid))
    else:
        table6 = ctypes.cast(buffer, ctypes.POINTER(_MibTcp6TableOwnerPid)).contents
        rows6 = ctypes.cast(
            ctypes.addressof(table6) + _MibTcp6TableOwnerPid.dwNumEntries.size,
            ctypes.POINTER(_MibTcp6RowOwnerPid),
        )
        addr6_offset = _MibTcp6RowOwnerPid.ucLocalAddr.offset
        for index in range(int(table6.dwNumEntries)):
            row = rows6[index]
            if int(row.dwState) != _TCP_STATE_LISTEN:
                continue
            if int(socket.ntohs(int(row.dwLocalPort) & 0xFFFF)) != int(port):
                continue
            # Native ``ucLocalAddr`` is a 16-byte array; read it from the row
            # memory (offset-based, endianness-agnostic) so the declared MIB layout
            # is what is actually inspected.
            raw = ctypes.string_at(ctypes.addressof(row) + addr6_offset, 16)
            addresses.append(socket.inet_ntop(socket.AF_INET6, raw))
            pids.add(int(row.dwOwningPid))
    return {"addresses": addresses, "pids": pids}


class WindowsTcpTableProbe:
    """Actual bound IPv4 *and* IPv6 listeners plus owning PIDs (no connect).

    The probe reports a per-family inventory status so a caller can tell a
    genuinely empty family from a family whose native table query failed. Strict
    proof refuses a partial inventory: accepting only one family could miss a
    wildcard or other-family listener.
    """

    def probe(self, port: int) -> dict:
        if os.name != "nt":
            return {
                "listening": False,
                "addresses": [],
                "pids": [],
                "source": "unsupported",
                "families": {"ipv4": "unsupported", "ipv6": "unsupported"},
            }
        v4 = _probe_tcp_table(port, _AF_INET)
        v6 = _probe_tcp_table(port, _AF_INET6)
        families = {
            "ipv4": "ok" if v4 is not None else "unavailable",
            "ipv6": "ok" if v6 is not None else "unavailable",
        }
        if v4 is None and v6 is None:
            return {
                "listening": False,
                "addresses": [],
                "pids": [],
                "source": "unavailable",
                "families": families,
            }
        addresses: list = []
        pids: set = set()
        for result in (v4, v6):
            if result:
                addresses.extend(result["addresses"])
                pids |= result["pids"]
        return {
            "listening": bool(addresses),
            "addresses": sorted(set(addresses)),
            "pids": sorted(pids),
            "source": "tcp_table",
            "families": families,
        }


def local_ipv4_addresses() -> list:
    found: set = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.add(info[4][0])
    except OSError:
        pass
    try:
        found.add(socket.gethostbyname(socket.gethostname()))
    except OSError:
        pass
    return sorted(addr for addr in found if addr and not addr.startswith("127."))


def is_loopback_address(address) -> bool:
    """Exact loopback only: IPv4 ``127.0.0.0/8`` or IPv6 ``::1``."""
    text = str(address).strip()
    if text.startswith("::ffff:"):
        text = text[len("::ffff:"):]
    try:
        return ipaddress.ip_address(text).is_loopback
    except ValueError:
        return False


class LoopbackConnectProbe:
    """Fallback probe: connects to the exact loopback addresses only."""

    def __init__(self, timeout: float = 0.4, address_provider=None) -> None:
        self.timeout = float(timeout)
        self.address_provider = address_provider or local_ipv4_addresses

    def _can_connect(self, address: str, port: int) -> bool:
        try:
            with socket.create_connection((address, int(port)), timeout=self.timeout):
                return True
        except OSError:
            return False

    def probe(self, port: int) -> dict:
        addresses: list = []
        if self._can_connect("127.0.0.1", port):
            addresses.append("127.0.0.1")
        if self._can_connect("::1", port):
            addresses.append("::1")
        for address in self.address_provider():
            if address.startswith("127.") or address in addresses:
                continue
            if self._can_connect(address, port):
                addresses.append(address)
        return {"listening": bool(addresses), "addresses": sorted(addresses), "pids": [], "source": "loopback_connect"}


def default_listener_probe():
    if os.name == "nt":
        return WindowsTcpTableProbe()
    return LoopbackConnectProbe()


def _listener_family_gaps(probe_result) -> list:
    """Families whose native inventory query failed (empty means fully read)."""
    if not isinstance(probe_result, Mapping):
        return []
    families = probe_result.get("families")
    if not isinstance(families, Mapping):
        return []
    return sorted(str(name) for name, status in families.items() if status == "unavailable")


def verify_local_listener(
    port: int,
    admin_port: int,
    *,
    probe=None,
    strict: bool = True,
    expected_pid=None,
) -> dict:
    """Prove the match listener is loopback-only, owned and admin-free (M2).

    Both IPv4 and IPv6 tables are inventoried. Every bound address must be an exact
    loopback address; a wildcard or LAN address is refused. When ``expected_pid`` is
    supplied the owning PID set (when available) must include the owned server PID,
    so a foreign process squatting the port cannot pass. The admin port must not be
    listening on either family. In strict mode a partial inventory (either family's
    native table query unavailable) is refused rather than treated as complete.
    """
    probe = probe or default_listener_probe()
    problems: list = []
    match = probe.probe(port)
    admin = probe.probe(admin_port)
    if not match.get("listening"):
        problems.append("match_listener_absent")
    addresses = [str(item) for item in match.get("addresses") or ()]
    non_loopback = [item for item in addresses if not is_loopback_address(item)]
    if non_loopback:
        problems.append("match_listener_not_loopback")
    if strict and not addresses:
        problems.append("lan_bind_unproven")
    if strict:
        if _listener_family_gaps(match):
            problems.append("match_listener_inventory_incomplete")
        if _listener_family_gaps(admin):
            problems.append("admin_listener_inventory_incomplete")
    pids = {int(item) for item in (match.get("pids") or ())}
    owner_proven = None
    if expected_pid is not None:
        if pids:
            # M-2: the owner set must be *exactly* the owned server PID across both
            # families. A foreign loopback listener squatting beside Node would add
            # its own PID and must fail, not merely have to contain the server PID.
            if pids != {int(expected_pid)}:
                problems.append("match_listener_not_owned")
            else:
                owner_proven = True
        else:
            owner_proven = False
            if strict:
                problems.append("match_listener_owner_unproven")
    host_loopback = None
    if admin.get("listening"):
        problems.append("admin_listener_active")
    code = CODE_OK
    if problems:
        code = CODE_LISTENER_OWNER if problems == ["match_listener_not_owned"] else CODE_LISTENER_UNPROVEN
    return {
        "ok": not problems,
        "code": code,
        "problems": problems,
        "match": {
            "listening": bool(match.get("listening")),
            "addresses": addresses,
            "pids": sorted(pids),
            "source": match.get("source"),
            "families": match.get("families"),
        },
        "admin": {
            "listening": bool(admin.get("listening")),
            "addresses": [str(item) for item in (admin.get("addresses") or ())],
            "source": admin.get("source"),
            "families": admin.get("families"),
        },
        "owner_proven": owner_proven,
    }


def _exclusive_socket(family: int = socket.AF_INET, kind: int = socket.SOCK_STREAM):
    """A socket that cannot be shared with an existing listener (M2).

    On Windows ``SO_EXCLUSIVEADDRUSE`` prevents a bind from hijacking a port that
    is already in use; ``SO_REUSEADDR`` is deliberately never set.
    """
    sock = socket.socket(family, kind)
    if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        except OSError:
            pass
    return sock


def port_is_free(host: str, port: int) -> bool:
    family = socket.AF_INET6 if ":" in str(host) else socket.AF_INET
    try:
        with _exclusive_socket(family) as sock:
            sock.bind((host, int(port)))
        return True
    except OSError:
        return False


def pick_free_port(host: str = HOST) -> int:
    family = socket.AF_INET6 if ":" in str(host) else socket.AF_INET
    with _exclusive_socket(family) as sock:
        sock.bind((host, 0))
        return int(sock.getsockname()[1])


def choose_match_port(config: HostConfig, *, port_free=None) -> dict:
    """Fixed, validated match port; never silently re-chosen when proof binds it."""
    port_free = port_free or port_is_free
    if config.match_port is None:
        if config.require_fixed_match_port:
            return {"ok": False, "code": CODE_MATCH_PORT_UNCONFIGURED, "port": None}
        port = pick_free_port()
        return {"ok": True, "code": CODE_OK, "port": port, "fixed": False}
    if not port_free(HOST, config.match_port):
        return {"ok": False, "code": CODE_MATCH_PORT, "port": config.match_port}
    return {"ok": True, "code": CODE_OK, "port": int(config.match_port), "fixed": True}


# ---------------------------------------------------------------------------
# Server adaptation verification
# ---------------------------------------------------------------------------

def _safe_rel_entry(rel) -> bool:
    if not isinstance(rel, str) or not rel:
        return False
    if rel.startswith(("/", "\\")) or ":" in rel:
        return False
    parts = Path(rel.replace("\\", "/")).parts
    return all(part not in ("", ".", "..") for part in parts)


def verify_server_adaptation(config: HostConfig, *, which=None) -> dict:
    """Bind the adapted server to its exact pin, hashes, loopback bind and admin-off patch.

    Only the configured manifest under the configured server root is read; the
    root must live inside the repository with no reparse point on the path, every
    recorded relative path must stay inside the root, and the package lock plus
    the complete runtime dependency/native binary set are hashed. The resolved
    Node executable is hashed and pinned (M3); the built ``dist/main.js`` must be
    recorded in ``built_files`` and must itself carry the loopback bind and the
    disabled admin listener, so a tampered/built-different bundle cannot pass on
    the ``.ts`` source alone.
    """
    repo_root = Path(config.repo_root)
    root = Path(config.server_root)
    manifest_path = Path(config.server_manifest)
    which = which or shutil.which
    problems: list = []
    try:
        staging.assert_no_reparse_between(repo_root, root, "server root")
        staging.assert_within(repo_root, root, "server root")
    except staging.StagingError as error:
        return {"ok": False, "code": "practice_server_root_unsafe", "problems": [error.code]}
    if staging._norm_path(manifest_path) != staging._norm_path(root / "AISparring-adaptation.json"):
        return {"ok": False, "code": "practice_server_manifest_path_mismatch"}
    try:
        staging.assert_no_reparse_between(root, manifest_path, "server manifest")
        staging.assert_within(root, manifest_path, "server manifest")
    except staging.StagingError as error:
        return {"ok": False, "code": "practice_server_manifest_unsafe", "problems": [error.code]}
    if not manifest_path.is_file():
        return {"ok": False, "code": "practice_server_manifest_missing"}
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError):
        return {"ok": False, "code": "practice_server_manifest_unreadable"}
    if manifest.get("schema") != "aisparring.local_server.v1":
        problems.append("schema_mismatch")
    if manifest.get("upstream_commit") != config.server_pin:
        problems.append("upstream_pin_mismatch")
    if list(manifest.get("changes") or ()) != list(SERVER_CHANGES):
        problems.append("changes_mismatch")
    # ``source_files`` and ``built_files`` are the reviewed git-tracked source and
    # the compiled bundle; ``runtime_files`` is the complete hash manifest of the
    # reviewed dependency install tree (including native binaries), which is *not*
    # git-tracked and so must be bound explicitly.
    for key in ("source_files", "built_files", "runtime_files"):
        entries = manifest.get(key) or {}
        if not entries:
            problems.append(f"{key}_missing")
            continue
        for rel, digest in entries.items():
            if not _safe_rel_entry(rel):
                problems.append(f"{key}_unsafe_path:{rel}")
                continue
            candidate = root / rel
            if not candidate.is_file():
                problems.append(f"{key}_missing:{rel}")
                continue
            if staging.sha256_file(candidate) != digest:
                problems.append(f"{key}_hash_mismatch:{rel}")
    built_files = manifest.get("built_files") or {}
    if SERVER_ENTRY not in built_files:
        problems.append("built_entry_not_in_manifest")
    lock_file = root / "package-lock.json"
    if not lock_file.is_file():
        problems.append("package_lock_missing")
    elif manifest.get("package_lock_sha256") != staging.sha256_file(lock_file):
        problems.append("package_lock_hash_mismatch")

    node_executable = None
    node_sha256 = None
    try:
        node_executable = which(config.node_executable) or which("node")
    except Exception:  # noqa: BLE001
        node_executable = None
    if not node_executable or not Path(str(node_executable)).is_file():
        problems.append("node_executable_unresolved")
    else:
        node_sha256 = staging.sha256_file(Path(str(node_executable)))
        if manifest.get("node_executable") != str(Path(str(node_executable))):
            problems.append("node_executable_mismatch")
        if manifest.get("node_sha256") != node_sha256:
            problems.append("node_hash_mismatch")

    declared_deps = manifest.get("dependency_hashes")
    if not isinstance(declared_deps, Mapping) or not declared_deps:
        problems.append("dependency_hashes_missing")
    dependency_hashes: dict = {}
    for name in config.server_runtime_deps:
        dep_dir = root / "node_modules" / name
        if not dep_dir.is_dir():
            problems.append(f"runtime_dependency_missing:{name}")
            continue
        dep_files = staging.hash_tree(dep_dir) if dep_dir.is_dir() else {}
        if not dep_files:
            problems.append(f"runtime_dependency_unbound:{name}")
            continue
        digest_of_dep = staging._digest_of(dep_files)
        dependency_hashes[name] = digest_of_dep
        if isinstance(declared_deps, Mapping) and declared_deps.get(name) != digest_of_dep:
            problems.append(f"dependency_hash_mismatch:{name}")
    native_files = sorted(
        str(path.relative_to(root)).replace("\\", "/")
        for path in (root / "node_modules").rglob("*.node")
        if path.is_file()
    ) if (root / "node_modules").is_dir() else []
    if not native_files:
        problems.append("native_binary_unbound")
    declared_native = manifest.get("native_files")
    if not isinstance(declared_native, list) or not declared_native:
        problems.append("native_files_missing")
    else:
        declared_set = sorted(str(item) for item in declared_native)
        for rel in declared_set:
            if not _safe_rel_entry(rel):
                problems.append(f"native_files_unsafe_path:{rel}")
            elif rel not in (manifest.get("runtime_files") or {}):
                problems.append(f"native_files_unbound:{rel}")
        if native_files and declared_set != native_files:
            problems.append("native_files_mismatch")

    main_source = root / SERVER_SOURCE_ENTRY
    if not main_source.is_file():
        problems.append("main_source_missing")
    else:
        text = main_source.read_text(encoding="utf-8", errors="replace")
        if SERVER_BIND_OK not in text or SERVER_BIND_BAD in text:
            problems.append("match_bind_not_loopback")
        if SERVER_ADMIN_OK not in text or SERVER_ADMIN_BAD in text:
            problems.append("admin_listener_not_disabled")
    entry = root / SERVER_ENTRY
    if not entry.is_file():
        problems.append("server_entry_missing")
    else:
        built = entry.read_text(encoding="utf-8", errors="replace")
        if SERVER_BIND_OK not in built:
            problems.append("built_match_bind_not_loopback")
        if SERVER_ADMIN_BAD in built or "adminServer.listen" in built:
            problems.append("built_admin_listener_active")
    return {
        "ok": not problems,
        "code": CODE_OK if not problems else CODE_SERVER_ADAPTATION,
        "problems": problems,
        "entry": str(entry),
        "upstream_commit": manifest.get("upstream_commit"),
        "package_lock_sha256": manifest.get("package_lock_sha256"),
        "node_executable": node_executable,
        "node_sha256": node_sha256,
        "native_files": native_files,
        "dependency_hashes": dependency_hashes,
    }


# ---------------------------------------------------------------------------
# Staged content hash, ports and static gates
# ---------------------------------------------------------------------------

def staged_content_hash(config: HostConfig, roles: Sequence[str] = ("human", "ai")) -> dict:
    """Role-independent trusted content digest injected into both roles."""
    try:
        first_role = roles[0]
    except IndexError:
        return {"ok": False, "code": CODE_BAD_REQUEST}
    try:
        baseline = _role_content_digest(config.staging_root, first_role)
    except staging.StagingError as error:
        return {"ok": False, "code": error.code}
    for role in roles[1:]:
        try:
            other = _role_content_digest(config.staging_root, role)
        except staging.StagingError as error:
            return {"ok": False, "code": error.code}
        if other != baseline:
            return {"ok": False, "code": "practice_staged_content_mismatch"}
    payload = json.dumps(baseline, sort_keys=True, separators=(",", ":"))
    return {"ok": True, "code": CODE_OK, "digest": hashlib.sha256(payload.encode("utf-8")).hexdigest()}


def _role_content_digest(staging_root, role: str) -> dict:
    paths = staging.role_paths(staging_root, role)
    install = staging.hash_tree(paths.install, staging.INSTALL_HASH_POLICY)
    mods = staging.hash_tree(paths.mods, staging.MODS_HASH_POLICY)
    return {"install": install, "mods": mods}


def static_isolation_gates(config: HostConfig, enumerator=None) -> dict:
    """Code/path-level proof (no runtime probes): manifests, guards, roots, no links."""
    enumerator = enumerator or launch_practice.default_enumerator()
    live_map = staging.live_roots(
        install_root=config.live_install_root,
        appdata_root=config.live_appdata_root,
        steam_root=config.steam_root,
    )
    gates: dict = {}
    try:
        staging.assert_no_overlap(config.staging_root, live_map)
        gates["overlap"] = {"ok": True}
    except staging.StagingError as error:
        gates["overlap"] = {"ok": False, "code": error.code}
    gates["live_balatro_closed"] = launch_practice.check_live_balatro_closed(enumerator, config.live_install_root)
    gates["staged_roles"] = {
        role: staging.verify_staged_role(config.staging_root, role) for role in staging.ROLES
    }
    gates["steam_guard"] = {role: staging.check_steam_guard(config.staging_root, role, live=live_map) for role in staging.ROLES}
    return {
        "ok": all(_gate_ok(gate) for gate in gates.values()),
        "code": CODE_OK if all(_gate_ok(gate) for gate in gates.values()) else CODE_STATIC_GATES_FAILED,
        "gates": gates,
    }


def _gate_ok(gate) -> bool:
    if isinstance(gate, dict) and "roles" in gate:
        return all(bool(item.get("ok")) for item in gate["roles"].values())
    if isinstance(gate, dict) and "ok" in gate:
        return bool(gate["ok"])
    if isinstance(gate, dict):
        return all(_gate_ok(item) for item in gate.values())
    return False


def fresh_backup_baseline(config: HostConfig) -> dict:
    """Fresh, zero-diff backup baseline: live trees must still match the backup."""
    sources = launch_practice.live_source_map(
        config.live_install_root, config.live_appdata_root, config.steam_root
    )
    verdict = launch_practice.check_backup_evidence(Path(config.backup_root), sources)
    if not verdict.get("ok"):
        verdict["code"] = CODE_FRESH_BACKUP_REQUIRED
    return verdict


_MISSING_API = object()


def certificate_gate(config: HostConfig, live_map=None, port=None, api=_MISSING_API) -> dict:
    """Reuse the immutable two-layer certificate; never rebase or rewrite evidence.

    The certificate is a historical, immutable artifact. This gate only checks it
    against the current bound layers/tools and the explicit live-roots map, and
    honours the persistent lockout. Live *contents* are never compared here; the
    per-session zero-diff check owns that.
    """
    if api is _MISSING_API:
        api = isolation_certificate
    if api is None:
        return {
            "ok": False,
            "code": CODE_CERTIFICATE_API_MISSING,
            "problems": ["certificate_api_missing"],
        }
    live_map = live_map or staging.live_roots(
        install_root=config.live_install_root,
        appdata_root=config.live_appdata_root,
        steam_root=config.steam_root,
    )
    lock = _certificate_lockout(api, config)
    if lock.get("locked"):
        return {"ok": False, "code": CODE_CERTIFICATE_LOCKED, "lockout": lock, "problems": ["certificate_locked_out"]}
    try:
        verdict = api.check_certificate(config.staging_root, live=live_map, port=port)
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED, "problems": ["certificate_check_failed"]}
    if not verdict.get("ok"):
        result = dict(verdict)
        result["code"] = CODE_CERTIFICATE_REQUIRED
        return result
    return verdict


def _certificate_lockout(api, config: HostConfig) -> dict:
    try:
        return dict(api.lockout(config.staging_root))
    except Exception:  # noqa: BLE001
        return {"locked": True, "reason": "certificate_lockout_unreadable"}


# The measurement/lifecycle API the host requires. There is deliberately no host
# fallback: if the certificate worker has not yet published these, a real session
# refuses instead of inventing unchecked evidence (measurement-interface.txt).
_MEASUREMENT_API_METHODS = (
    "check_certificate",
    "lockout",
    "acknowledge_lockout",
    "prepare_session",
    "bind_open_session",
    "record_session_verdict",
    "record_session_failure",
    "record_session_no_spawn",
    "write_launcher_attestation",
    "list_open_records",
    "collect_layer_m",
)
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _trusted_config_digest(value) -> Optional[str]:
    """A real host-derived Major League config digest; never a content-hash fallback.

    The digest is the shared FNV1a-32 ``major_league_digest`` (or, on the non-
    certificate path, the source-derived staged content digest). It must match the
    service's own digest grammar; a missing or malformed value fails closed instead
    of silently falling back to the role-parity ``content_hash``.
    """
    if isinstance(value, str) and practice_service.DIGEST_PATTERN.match(value):
        return value
    return None


def measurement_api_problems(api) -> list:
    if api is None:
        return ["certificate_api_missing"]
    return [f"missing:{name}" for name in _MEASUREMENT_API_METHODS if not callable(getattr(api, name, None))]


def certificate_open_records(api, config: HostConfig) -> list:
    """Any earlier open (unmeasured) session record blocks a new ticket/ack (C1)."""
    if api is None or not callable(getattr(api, "list_open_records", None)):
        return []
    try:
        records = api.list_open_records(config.staging_root)
    except Exception:  # noqa: BLE001
        return [{"status": "open", "session_id": None, "unreadable": True}]
    return list(records or ())


def certificate_content_hash(api, staging_root) -> Optional[str]:
    """The certificate's role-normalized Mods parity digest for both descriptors (M10)."""
    if api is None:
        return None
    roles: Mapping = {}
    try:
        if callable(getattr(api, "certificate_or_empty", None)):
            roles = api.certificate_or_empty(staging_root, "mods_layer", "roles") or {}
        elif callable(getattr(api, "collect_layer_m", None)):
            roles = (api.collect_layer_m(staging_root) or {}).get("roles") or {}
    except Exception:  # noqa: BLE001
        return None
    digests = {
        entry.get("role_parity_digest")
        for entry in roles.values()
        if isinstance(entry, Mapping)
    }
    if len(digests) == 1:
        digest = next(iter(digests))
        if isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest):
            return digest
    return None


def _call_prepare_session(api, config: HostConfig, live_map, *, session_id: str, port: int, backup_id, backup_verify, enumerator=None):
    """Call the certificate ``prepare_session`` with the documented contract.

    The tool-owned ``backup_verify`` callable is always supplied so the certificate
    re-verifies the fresh backup itself; ``closed_check`` is always the real
    enumerator check, never a caller boolean. Extra keyword support
    (``backup_root``) is detected by signature inspection so the host tracks the
    worker's published API without a silent fake fallback.
    """
    import inspect

    observed = enumerator or launch_practice.default_enumerator()
    signature = inspect.signature(api.prepare_session)
    kwargs = dict(
        live=live_map,
        session_id=session_id,
        port=int(port),
        closed_check=lambda: bool(
            launch_practice.check_live_balatro_closed(observed, config.live_install_root).get("ok")
        ),
        backup_id=backup_id,
        backup_verify=backup_verify,
    )
    if "backup_root" in signature.parameters:
        kwargs["backup_root"] = str(config.backup_root)
    return api.prepare_session(config.staging_root, **kwargs)


def check_quiescence(config: HostConfig, live_map, *, api=None, samples: int = 2, interval=None, sleeper=None) -> dict:
    """Steam userdata must be byte-stable across two identical hashes N seconds apart."""
    api = api if api is not None else isolation_certificate
    if api is None:
        return {"ok": False, "code": CODE_CERTIFICATE_API_MISSING}
    sleeper = sleeper or time.sleep
    interval = config.quiescence_seconds if interval is None else float(interval)
    keys = [key for key in live_map if key.startswith("steam_userdata")]
    steam_live = {key: live_map[key] for key in keys}
    if not steam_live:
        return {"ok": True, "code": CODE_OK, "digests": [], "note": "no steam userdata roots"}
    digests: list = []
    for index in range(max(2, int(samples))):
        try:
            snapshot = api.snapshot_live(steam_live, label=f"quiescence{index}")
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_QUIESCENCE, "problems": ["quiescence_snapshot_failed"]}
        digests.append(snapshot.get("digest"))
        if index < max(2, int(samples)) - 1:
            sleeper(interval)
    if len(set(digests)) != 1 or digests[0] is None:
        return {"ok": False, "code": CODE_QUIESCENCE, "problems": ["steam_userdata_not_quiescent"], "digests": digests}
    return {"ok": True, "code": CODE_OK, "digests": digests}


def _is_content_id(value) -> bool:
    """A verifier-derived content identity: the 64-hex digest the backup evidence mints."""
    return isinstance(value, str) and bool(_SHA256_RE.match(value))


def prepare_live_baseline(config: HostConfig, live_map, *, api=None, backup_runner=None, sleeper=None, label=None) -> dict:
    """Quiescence, a fresh verified full byte backup, then the fresh before-manifest.

    R1/the backup contract: the returned ``backup_id`` is **only** the
    verifier-derived content identity from the real ``check_backup_evidence`` (the
    manifest hash bound over every verified per-root file map). A backup-runner
    label, ``digest`` alias or ``id`` is display/directory metadata and can never
    stand in for that identity; a result without a real content id is refused
    rather than passed on. The complete verified per-root ``roots`` evidence (and
    the manifest hash) is preserved so ``prepare_session`` can bind its own
    before-snapshot to the identical digests.
    """
    api = api if api is not None else isolation_certificate
    if api is None:
        return {"ok": False, "code": CODE_CERTIFICATE_API_MISSING}
    quiet = check_quiescence(config, live_map, api=api, sleeper=sleeper)
    if not quiet.get("ok"):
        return quiet
    backup_runner = backup_runner or _default_backup_runner
    backup = backup_runner(config, live_map, label)
    if not isinstance(backup, dict) or not backup.get("ok"):
        return {"ok": False, "code": CODE_FRESH_BACKUP_REQUIRED, "backup": backup}
    verify = _verify_fresh_backup(config, live_map)
    if not isinstance(verify, dict) or not verify.get("ok"):
        return {"ok": False, "code": CODE_FRESH_BACKUP_REQUIRED, "backup": backup, "verify": verify}
    backup_id = verify.get("backup_id")
    if not _is_content_id(backup_id):
        return {"ok": False, "code": CODE_FRESH_BACKUP_REQUIRED, "problems": ["backup_id_missing"], "backup": backup, "verify": verify}
    roots = verify.get("roots")
    if not isinstance(roots, Mapping) or not roots:
        return {"ok": False, "code": CODE_FRESH_BACKUP_REQUIRED, "problems": ["backup_roots_missing"], "backup": backup, "verify": verify}
    return {
        "ok": True,
        "code": CODE_OK,
        "backup_id": backup_id,
        "backup_label": verify.get("backup_label"),
        "manifest_sha256": verify.get("manifest_sha256"),
        "roots": {str(key): dict(value) for key, value in roots.items()},
        "backup": backup,
        "verify": verify,
    }


def _default_backup_runner(config: HostConfig, live_map, label):
    ensured_label = label if isinstance(label, str) and _SAFE_ID_RE.match(label) else "session-" + secrets.token_hex(8)
    result = launch_practice.create_live_backup(
        install_root=config.live_install_root,
        appdata_root=config.live_appdata_root,
        steam_root=config.steam_root,
        backup_root=config.backup_root,
        enumerator=launch_practice.default_enumerator(),
        live_install_root=config.live_install_root,
        label=ensured_label,
        execute=True,
    )
    if isinstance(result, dict) and result.get("ok"):
        result["label"] = result.get("label") or ensured_label
    return result


def _verify_fresh_backup(config: HostConfig, live_map) -> dict:
    sources = launch_practice.live_source_map(
        config.live_install_root, config.live_appdata_root, config.steam_root
    )
    return launch_practice.check_backup_evidence(Path(config.backup_root), sources)


def wait_for_attestation(
    config: HostConfig,
    *,
    nonce: str,
    spawn_time: float,
    port: int,
    collector=None,
    timeout=None,
    poll_interval=None,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict:
    """Both staged roles must return nonce-bound startup attestations before a match."""
    collector = collector or _default_attestation_collector
    deadline = clock() + (config.attestation_timeout if timeout is None else float(timeout))
    interval = config.poll_interval if poll_interval is None else float(poll_interval)
    last: dict = {}
    while True:
        last = collector(config, nonce, spawn_time, port)
        if last.get("ok"):
            return last
        if clock() >= deadline:
            result = dict(last)
            result["code"] = CODE_ATTESTATION
            return result
        sleeper(interval)


def _default_attestation_collector(config: HostConfig, nonce: str, spawn_time: float, port: int) -> dict:
    problems: list = []
    roles: dict = {}
    for role in staging.ROLES:
        paths = staging.role_paths(config.staging_root, role)
        try:
            verdict = staging.collect_role_probes(
                paths, nonce, spawn_time, require_mp=True, expected_port=port
            )
        except Exception:  # noqa: BLE001
            verdict = {"ok": False, "problems": ["attestation_unreadable"]}
        roles[role] = verdict
        problems.extend(f"{role}:{item}" for item in verdict.get("problems", ()))
    return {
        "ok": not problems,
        "code": CODE_OK if not problems else CODE_ATTESTATION,
        "problems": problems,
        "roles": roles,
    }


def attestation_path(config: HostConfig, role: str) -> Path:
    """The fixed session-bound attestation path the companion derives from its descriptor."""
    return staging.launcher_attestation_path(staging.role_paths(config.staging_root, role))


def rotate_role_attestations(config: HostConfig) -> list:
    """Remove any previous session's attestation before a role launch."""
    removed: list = []
    for role in staging.ROLES:
        target = attestation_path(config, role)
        try:
            staging.assert_safe_write(config.staging_root, target, "attestation rotation")
        except staging.StagingError:
            continue
        if target.exists():
            target.unlink()
            removed.append(str(target))
    return removed


def write_role_attestations(config: HostConfig, *, session_id: str, nonce: str, control_port: int, port: int) -> dict:
    """Delegate to the certificate's frozen, re-verifying attestation writer (H1).

    There is deliberately no alternate host-side writer: the contract's
    ``isolation_certificate.write_launcher_attestation`` requires the open record,
    the owned PIDs, the nonce and both roles' fresh probes before it writes, uses
    ``control_port`` for the control service and ``port`` for the match listener
    separately, and is atomic. A missing or non-conforming certificate API fails
    closed instead of falling back to an unchecked writer.
    """
    api = isolation_certificate
    if api is None or not hasattr(api, "write_launcher_attestation"):
        return {"ok": False, "code": CODE_MEASUREMENT_API_MISSING, "problems": ["write_launcher_attestation_missing"]}
    try:
        verdict = api.write_launcher_attestation(
            config.staging_root,
            session_id=session_id,
            nonce=nonce,
            control_port=int(control_port),
            port=int(port),
        )
    except Exception:  # noqa: BLE001
        return {"ok": False, "code": CODE_ATTESTATION, "problems": ["attestation_write_failed"]}
    if not isinstance(verdict, dict) or not verdict.get("ok"):
        result = dict(verdict) if isinstance(verdict, dict) else {}
        result["code"] = result.get("code") or CODE_ATTESTATION
        return result
    return verdict


# ---------------------------------------------------------------------------
# Host ack lockout (persistent, requires explicit user acknowledgement)
# ---------------------------------------------------------------------------

def host_lockout_path(config: HostConfig) -> Path:
    return Path(config.work_dir) / HOST_LOCKOUT_NAME


def read_host_lockout(config: HostConfig) -> dict:
    path = host_lockout_path(config)
    if not path.is_file():
        return {"locked": False, "path": str(path)}
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"locked": True, "path": str(path), "reason": "unreadable"}
    record = dict(record)
    record["locked"] = bool(record.get("locked", True))
    record["path"] = str(path)
    return record


def set_host_lockout(config: HostConfig, *, reason: str, session_id=None, extra=None) -> Path:
    path = host_lockout_path(config)
    record = {
        "schema": "aisparring.practice_host.lockout.v1",
        "locked": True,
        "reason": reason,
        "session_id": session_id,
        "locked_unix": int(time.time()),
    }
    if extra:
        record.update(extra)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
    return path


def clear_host_lockout(config: HostConfig, *, acknowledged_by="user") -> dict:
    path = host_lockout_path(config)
    if not path.is_file():
        return {"ok": True, "code": CODE_OK, "cleared": False}
    path.unlink()
    return {"ok": True, "code": CODE_OK, "cleared": True, "acknowledged_by": acknowledged_by}


# ---------------------------------------------------------------------------
# Session workspace / manifest
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SessionWorkspace:
    session_id: str
    root: Path
    server_dir: Path
    log_dir: Path
    report_path: Path


def mint_session_id() -> str:
    """Mint a bounded, colon-free session id owned by the host (M6)."""
    return "s-" + secrets.token_hex(12)


def create_session_workspace(config: HostConfig, session_id: str) -> SessionWorkspace:
    """Create the exclusive per-session workspace; an existing id is refused (M6)."""
    if not isinstance(session_id, str) or not SESSION_ID_RE.match(session_id):
        raise HostError(CODE_BAD_REQUEST)
    root = staging.assert_within(config.session_root, Path(config.session_root) / session_id)
    if Path(root).exists():
        raise HostError(CODE_SESSION_WORKSPACE_EXISTS)
    server_dir = staging.assert_within(config.session_root, root / "server")
    log_dir = staging.assert_within(config.session_root, root / "logs")
    server_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    return SessionWorkspace(session_id, root, server_dir, log_dir, root / "host.json")


def write_session_report(workspace: SessionWorkspace, report: Mapping) -> Path:
    payload = dict(report)
    payload.setdefault("schema", REPORT_SCHEMA)
    payload["version"] = VERSION
    target = workspace.report_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
    return target


# ---------------------------------------------------------------------------
# Server environment / runner
# ---------------------------------------------------------------------------

_SERVER_ENV_ALLOW = frozenset(
    name.upper()
    for name in (
        "PATH",
        "PATHEXT",
        "SYSTEMROOT",
        "SYSTEMDRIVE",
        "WINDIR",
        "COMSPEC",
        "OS",
        "NUMBER_OF_PROCESSORS",
        "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_IDENTIFIER",
        "TEMP",
        "TMP",
        "PROGRAMDATA",
    )
)
_SERVER_ENV_DENY_PREFIXES = ("STEAM", "SDL", "LOVELY", "PYTHON", "AISP_")


def server_environment(config: HostConfig, port: int, admin_port: int, base_env=None, *, session_dir=None) -> dict:
    source = os.environ if base_env is None else base_env
    env: dict = {}
    for key, value in source.items():
        upper = str(key).upper()
        if upper in _SERVER_ENV_ALLOW and not upper.startswith(_SERVER_ENV_DENY_PREFIXES):
            env[key] = value
    env["PORT"] = str(int(port))
    env["ADMIN_PORT"] = str(int(admin_port))
    # M-5: the server's persistent SQLite ban/rate database is session-local, so
    # three rate disconnects in one practice session can never ban ``127.0.0.1``
    # for every later session. The real caller always passes the session workspace.
    db_root = Path(session_dir) if session_dir is not None else Path(config.work_dir) / "server-data"
    env["LOG_HASH_DB_PATH"] = str(db_root / "data" / "log_hashes.db")
    env["BAN_RELOAD_INTERVAL_MS"] = "60000"
    return env


def _query_image_path(pid: int) -> Optional[str]:
    """Read the image path of a PID through a single query-only native handle."""
    handle = None
    try:
        handle = launch_practice.NativeProcessHandle.open(
            int(pid), access=launch_practice.PROCESS_QUERY_LIMITED_INFORMATION
        )
        if handle is None:
            return None
        return handle.image_path()
    except Exception:  # noqa: BLE001
        return None
    finally:
        if handle is not None:
            try:
                handle.close()
            except Exception:  # noqa: BLE001
                pass


def _same_image_path(left, right) -> bool:
    if not left or not right:
        return False
    try:
        return os.path.normcase(os.path.abspath(str(left))) == os.path.normcase(os.path.abspath(str(right)))
    except Exception:  # noqa: BLE001
        return False


def default_server_runner(
    command: Sequence[str],
    cwd,
    env: Mapping,
    log_dir: Path,
    *,
    popen=None,
    job_factory=None,
    create_time_reader=None,
    resume=None,
    image_reader=None,
    on_windows=None,
):
    """Spawn the pinned Node server with the roles' exact retained-ownership sequence (M-1).

    The verified absolute Node path is ``command[0]``. On Windows the server is
    created *suspended*, assigned to a mandatory kill-on-close Job Object and only
    then resumed, and its create time is read from the retained handle. Its image
    path is re-read through a separate query handle and must equal the launched
    executable, so the record can never name a bare ``node`` resolved by PATH.
    Every failure terminates the exact spawned child and raises ``HostError``.
    """
    popen = popen or subprocess.Popen
    job_factory = job_factory or launch_practice.JobObject.create
    create_time_reader = create_time_reader or launch_practice.read_owned_create_time
    resume = resume or launch_practice._resume_process
    image_reader = image_reader or _query_image_path
    on_windows = os.name == "nt" if on_windows is None else bool(on_windows)
    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    executable = str(command[0])

    def _abort(proc=None, job=None):
        if job is not None:
            try:
                job.close()
            except Exception:  # noqa: BLE001
                pass
        if proc is not None:
            try:
                proc.kill()
            except Exception:  # noqa: BLE001
                pass
        raise HostError(CODE_SERVER_FAILED)

    job = job_factory()
    if on_windows and job is None:
        # Mandatory suspended-before-Job: never start a server we cannot own.
        _abort(job=job)
    out_handle = open(log_dir / "server.out.log", "ab")
    err_handle = open(log_dir / "server.err.log", "ab")
    creationflags = launch_practice.CREATE_SUSPENDED if on_windows else 0
    try:
        proc = popen(
            [str(item) for item in command],
            cwd=str(cwd),
            env=dict(env),
            close_fds=True,
            stdout=out_handle,
            stderr=err_handle,
            creationflags=creationflags,
        )
    except (TypeError, ValueError):
        _abort(job=job)
    except OSError:
        _abort(job=job)
    finally:
        out_handle.close()
        err_handle.close()

    if on_windows:
        assigned = False
        try:
            assigned = bool(job.assign(proc))
        except Exception:  # noqa: BLE001
            assigned = False
        if not assigned:
            _abort(proc=proc, job=job)
    elif job is not None:
        try:
            job.assign(proc)
        except Exception:  # noqa: BLE001
            pass

    owned = launch_practice.OwnedProcess(
        role="server",
        handle=proc,
        pid=int(proc.pid),
        create_time=None,
        image_path=executable,
        job=job,
    )
    if on_windows and not resume(proc):
        _abort(proc=proc, job=job)
    create_time = create_time_reader(owned)
    if create_time is None:
        _abort(proc=proc, job=job)
    owned.create_time = float(create_time)
    image_path = image_reader(int(proc.pid))
    if not _same_image_path(image_path, executable):
        _abort(proc=proc, job=job)
    owned.image_path = str(image_path)
    return owned


def wait_for_listener(port: int, *, probe=None, timeout: float = 15.0, interval: float = 0.25, clock=time.monotonic, sleeper=time.sleep) -> bool:
    probe = probe or default_listener_probe()
    deadline = clock() + float(timeout)
    while clock() < deadline:
        if probe.probe(port).get("listening"):
            return True
        sleeper(interval)
    return probe.probe(port).get("listening")


# ---------------------------------------------------------------------------
# Match supervisor
# ---------------------------------------------------------------------------

@dataclass
class MatchTicket:
    ticket: str
    request: dict
    phase: str = "accepted"
    code: str = CODE_ACCEPTED
    error: Optional[str] = None
    accepted_unix: float = 0.0
    supervisor: object = None
    thread: Optional[threading.Thread] = None

    def poll(self) -> dict:
        phase, error = self.phase, self.error
        if self.supervisor is not None:
            phase = getattr(self.supervisor, "phase", phase)
            error = getattr(self.supervisor, "error", error)
        return {
            "ok": True,
            "code": self.code,
            "ticket": self.ticket,
            "phase": phase if phase in PHASES else self.phase,
            "error": error,
        }


class MatchSupervisor:
    """Owns one closed-game practice session: live-exit wait, gates, launch, teardown."""

    def __init__(
        self,
        config: HostConfig,
        request: Mapping,
        *,
        session_id: Optional[str] = None,
        service_factory=None,
        launch_runner=None,
        server_runner=None,
        listener_probe=None,
        enumerator=None,
        opener=None,
        gate_evaluator=None,
        post_verifier=None,
        port_free=None,
        certificate_api=None,
        backup_runner=None,
        baseline_preparer=None,
        attestation_collector=None,
        attestation_rotator=None,
        attestation_writer=None,
        verdict_recorder=None,
        no_spawn_recorder=None,
        human_exit_waiter=None,
        ruleset_reader=None,
        runtime_checker=None,
        which=None,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
        workspace: Optional[SessionWorkspace] = None,
    ) -> None:
        validate_config(config)
        self.config = config
        self.request = dict(request)
        # The menu's session value is request *correlation* only, never a path (M6).
        self.correlation_id = str(request.get("session_id") or "")
        self.session_id = session_id or mint_session_id()
        self._service_factory = service_factory or _default_service_factory
        self._launch_runner = launch_runner or _default_launch_runner
        self._server_runner = server_runner or default_server_runner
        self._listener_probe = listener_probe or default_listener_probe()
        self._enumerator = enumerator or launch_practice.default_enumerator()
        self._opener = opener
        self._gate_evaluator = gate_evaluator or self._evaluate_gates
        self._post_verifier = post_verifier
        self._port_free = port_free or port_is_free
        self._certificate_api = certificate_api if certificate_api is not None else isolation_certificate
        self._backup_runner = backup_runner
        self._baseline_preparer = baseline_preparer
        self._attestation_collector = attestation_collector
        self._attestation_rotator = attestation_rotator
        self._attestation_writer = attestation_writer
        self._verdict_recorder = verdict_recorder
        self._no_spawn_recorder = no_spawn_recorder
        self._human_exit_waiter = human_exit_waiter
        self._ruleset_reader = ruleset_reader or ruleset_contract.expected_ruleset
        self._runtime_checker = runtime_checker
        self._which = which
        self._clock = clock
        self._sleeper = sleeper
        self.workspace = workspace or create_session_workspace(config, self.session_id)

        self.phase = "accepted"
        self.code = CODE_ACCEPTED
        self.error: Optional[str] = None
        self.service = None
        self.session = None
        self.server = None
        self.match_port: Optional[int] = None
        self.admin_port: Optional[int] = None
        self.human_retained = False
        self.voided = False
        self.certificate_id: Optional[str] = None
        self.backup_id: Optional[str] = None
        self.attestation: Optional[dict] = None
        self.live_verdict: Optional[dict] = None
        self.config_digest: Optional[str] = None
        self.open_record: Optional[str] = None
        self._open_session_record: Optional[dict] = None
        self._live_exit: Optional[dict] = None
        self._gates: dict = {}
        self._report: dict = {}
        self._role_records: list = []
        self._descriptor_env_gap: list = []
        # True once the persistent open/unmeasured certificate record exists (i.e.
        # before ANY server/role spawn). Failure then closes owned handles and takes
        # the measured after-verdict; it can never silently rebaseline (C1).
        self._record_started = False
        self._unmeasured_lockout = False
        # H-A-1-R: a closure that could not be retired/persisted is remembered and
        # retried through the public daemon once the owned process finally exits.
        self._pending_closure: Optional[str] = None
        # Serializes concurrent ``retry_pending_closure`` calls (the control server is
        # threaded) so two retries can never append duplicate receipts or race the
        # ownership retire.
        self._closure_lock = threading.Lock()

    # -- public ---------------------------------------------------------------

    def run(self) -> dict:
        try:
            self._set_phase("waiting_live_exit")
            exit_verdict = self._wait_live()
            if not exit_verdict.get("ok"):
                return self._fail(exit_verdict.get("code", CODE_LIVE_UNVERIFIED), live_exit=exit_verdict)

            self._set_phase("launching")
            gate_verdict = self._gate_evaluator()
            self._gates = gate_verdict
            if not gate_verdict.get("ok"):
                return self._fail(gate_verdict.get("code", CODE_STATIC_GATES_FAILED), gates=_gate_summary(gate_verdict))
            if self.config.require_certificate and self._gates.get("open_record") is not None:
                self._record_started = True
                self.open_record = self._gates.get("open_record")
                if not self._unmeasured_lockout:
                    set_host_lockout(self.config, reason="session_unmeasured", session_id=self.session_id)
                    self._unmeasured_lockout = True

            return self._launch_and_supervise()
        except HostError as error:
            return self._fail(error.code)
        except Exception:  # noqa: BLE001
            return self._fail(CODE_INTERNAL)

    def cleanup(self) -> None:
        """Terminate every owned handle and close the session. Never touches live."""
        self._stop_server()
        self._stop_service()
        self.human_retained = False
        if self.session is not None:
            try:
                self._terminate_roles()
            except Exception:  # noqa: BLE001
                pass
            try:
                self.session.close()
            except Exception:  # noqa: BLE001
                pass
            self.session = None

    def human_active(self) -> bool:
        """True while the retained staged human window is still running (H4)."""
        if not self.human_retained or self.session is None:
            return False
        statuses = self.session.is_running()
        human = [item for item in statuses if item.get("role") == "human"]
        return bool(human and human[0].get("running"))

    def _teardown_for_completion(self) -> None:
        """Retire the AI role after its bounded receipt, keep server/service + human.

        The human's MP client keeps its loopback server and the status/end service
        until the human window exits (H5); only the AI role is retired here.
        """
        if self.session is None:
            self._stop_server()
            self._stop_service()
            return
        if not self.config.leave_human_visible:
            self._retire_or_cleanup()
            return
        self._await_ai_receipt()
        self._terminate_roles(only=("ai",))
        statuses = self.session.is_running()
        human = [item for item in statuses if item.get("role") == "human"]
        self.human_retained = bool(human and human[0].get("running"))
        if not self.human_retained:
            self._retire_or_cleanup()

    def _retire_or_cleanup(self) -> None:
        """Retire the server/service/roles but keep the retained session (N-1-R).

        With a certificate the retained ``LaunchSession`` is the only evidence the
        measured after-verdict can close against, so it is held until the
        certificate closes the record. Dropping it here (through ``cleanup``) would
        make a genuine ``human_end`` fail with ``session_closure_unproven`` whenever
        the human window had already exited. Without a certificate there is nothing
        to retain and the historical ``cleanup`` applies.
        """
        self._stop_server()
        self._stop_service()
        if self.config.require_certificate and self._record_started:
            self._terminate_roles()
            self.human_retained = False
            return
        self.cleanup()

    def _await_ai_receipt(self) -> None:
        """Bounded wait for the AI end receipt; never touches the human connection."""
        service = self.service
        if service is None:
            return
        grace = getattr(service, "ai_receipt_grace", None)
        summary_fn = getattr(service, "terminal_summary", None)
        if not callable(summary_fn) or not isinstance(grace, (int, float)) or grace <= 0:
            return
        deadline = self._clock() + float(grace)
        while self._clock() < deadline:
            try:
                summary = summary_fn()
            except Exception:  # noqa: BLE001
                return
            if not isinstance(summary, dict):
                return
            if summary.get("ai_end_received") or summary.get("terminal_phase") not in (
                "awaiting_ai",
                None,
            ):
                return
            self._sleeper(min(float(self.config.poll_interval), 1.0))

    # -- phases ---------------------------------------------------------------

    def _wait_live(self) -> dict:
        verdict = wait_for_live_exit(
            self.config,
            int(self.request["live_pid"]),
            float(self.request["live_create_time"]),
            enumerator=self._enumerator,
            opener=self._opener,
            clock=self._clock,
            sleeper=self._sleeper,
        )
        self._live_exit = verdict
        return verdict

    def _evaluate_gates(self) -> dict:
        live_map = staging.live_roots(
            install_root=self.config.live_install_root,
            appdata_root=self.config.live_appdata_root,
            steam_root=self.config.steam_root,
        )
        api = self._certificate_api
        if self.config.require_certificate:
            missing = measurement_api_problems(api)
            if missing:
                return {"ok": False, "code": CODE_MEASUREMENT_API_MISSING, "problems": missing}
        lockout = read_host_lockout(self.config)
        if lockout.get("locked"):
            return {"ok": False, "code": CODE_ACK_REQUIRED, "lockout": lockout}
        if self.config.require_certificate:
            open_records = certificate_open_records(api, self.config)
            if open_records:
                return {"ok": False, "code": CODE_OPEN_RECORD_BLOCKED, "open_records": open_records}
            cert_lock = _certificate_lockout(api, self.config)
            if cert_lock.get("locked"):
                return {"ok": False, "code": CODE_CERTIFICATE_LOCKED, "lockout": cert_lock}
        # Runtime/policy preflight: a missing Lua runtime, policy source or
        # canonicalizer is a refusal before any spawn, never a late policy failure.
        preflight = runtime_preflight(self.config, checker=self._runtime_checker)
        if not preflight.get("ok"):
            return {"ok": False, "code": CODE_RUNTIME_PREFLIGHT, "problems": preflight.get("problems")}
        static = static_isolation_gates(self.config, enumerator=self._enumerator)
        if not static["ok"]:
            return {"ok": False, "code": CODE_STATIC_GATES_FAILED, "static": static}
        port = choose_match_port(self.config, port_free=self._port_free)
        if not port.get("ok"):
            return {"ok": False, "code": port.get("code", CODE_MATCH_PORT)}
        self.match_port = port["port"]

        prepared: dict = {"ok": True, "nonce": None, "backup_id": None, "certificate_id": None}
        content_hash: Optional[str] = None
        config_digest: Optional[str] = None
        ruleset: dict = {}
        if self.config.require_certificate:
            cert = certificate_gate(self.config, live_map=live_map, port=self.match_port, api=api)
            if not cert.get("ok"):
                return {"ok": False, "code": cert.get("code", CODE_CERTIFICATE_REQUIRED), "certificate": cert}
        # H-A: every check that does not need the game closed runs BEFORE the
        # exclusive open record is written, so a refusal here can never strand an
        # open record that nothing in the product can close.
        server = verify_server_adaptation(self.config, which=self._which)
        if not server.get("ok"):
            return {"ok": False, "code": CODE_SERVER_ADAPTATION, "server": server}
        endpoints = staging.verify_staged_endpoints(self.config.staging_root, port=self.match_port)
        if not endpoints.get("ok"):
            return {"ok": False, "code": CODE_STAGED_ENDPOINTS, "endpoints": endpoints}
        if self.config.require_certificate:
            content_hash = certificate_content_hash(api, self.config.staging_root)
            if not content_hash:
                return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED, "problems": ["role_parity_digest_unavailable"]}
            ruleset = self._ruleset_reader(self.config.staging_root)
            if not ruleset.get("ok"):
                return {"ok": False, "code": CODE_CONFIG_DIGEST, "ruleset": ruleset}
            config_digest = _trusted_config_digest(ruleset.get("config_digest"))
            if config_digest is None:
                return {"ok": False, "code": CODE_CONFIG_DIGEST, "problems": ["config_digest_missing"]}
        else:
            content = staged_content_hash(self.config)
            if not content.get("ok"):
                return {"ok": False, "code": content.get("code", CODE_STATIC_GATES_FAILED)}
            content_hash = content["digest"]
            config_digest = _trusted_config_digest(content.get("digest"))
            if config_digest is None:
                return {"ok": False, "code": CODE_CONFIG_DIGEST, "problems": ["config_digest_missing"]}
        if self.config.require_certificate:
            prepared = self._prepare_session(live_map)
            if not prepared.get("ok"):
                return {"ok": False, "code": prepared.get("code", CODE_CERTIFICATE_REQUIRED), "prepared": prepared}
        # `_prepare_session` records the persistent unmeasured state BEFORE any
        # server/role spawn (C1); only a measured pass/failure receipts clears it.
        return {
            "ok": True,
            "code": CODE_OK,
            "content_hash": content_hash,
            "match_port": self.match_port,
            "live_map": live_map,
            "nonce": prepared.get("nonce"),
            "backup_id": prepared.get("backup_id"),
            "certificate_id": prepared.get("certificate_id"),
            "config_digest": config_digest,
            "ruleset": ruleset,
            "open_record": prepared.get("open_record"),
            "open_session": self._open_session_record,
            "server": server,
        }

    def _prepare_session(self, live_map) -> dict:
        """Fresh quiescent verified backup, then the certificate's exclusive open record."""
        api = self._certificate_api
        if self._baseline_preparer is not None:
            baseline = self._baseline_preparer(self.config, live_map)
        else:
            baseline = prepare_live_baseline(
                self.config, live_map, api=api, backup_runner=self._backup_runner, sleeper=self._sleeper
            )
        if not baseline.get("ok"):
            return baseline
        if not _is_content_id(baseline.get("backup_id")):
            return {"ok": False, "code": CODE_FRESH_BACKUP_REQUIRED, "problems": ["backup_id_missing"]}
        try:
            prepared = _call_prepare_session(
                api,
                self.config,
                live_map,
                session_id=self.session_id,
                port=self.match_port,
                backup_id=baseline.get("backup_id"),
                # Re-run the real verifier so the certificate re-reads the current
                # backup/live files itself (identity + full roots evidence), rather
                # than binding a cached baseline verdict.
                backup_verify=lambda: _verify_fresh_backup(self.config, live_map),
                enumerator=self._enumerator,
            )
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED, "problems": ["prepare_session_failed"]}
        if not prepared.get("ok"):
            result = dict(prepared)
            result["code"] = CODE_CERTIFICATE_REQUIRED
            return result
        # H-A: the open record now exists, so record the persistent unmeasured
        # state immediately. Even if the id-parity check below refuses, `_fail`
        # will close this never-spawned record instead of stranding it.
        self._open_record = prepared.get("open_record")
        self.open_record = prepared.get("open_record")
        if prepared.get("record") is not None:
            self._open_session_record = prepared.get("record")
        if self._open_record is not None:
            set_host_lockout(self.config, reason="session_unmeasured", session_id=self.session_id)
            self._unmeasured_lockout = True
            self._record_started = True
        # The certificate's own evidence id is authoritative: never overwrite it with
        # a runner label, and require it to agree with the verifier-derived baseline
        # identity. The label stays display/directory metadata on the open record.
        returned_id = prepared.get("backup_id")
        if not _is_content_id(returned_id) or returned_id != baseline.get("backup_id"):
            return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED, "problems": ["prepared_backup_id_mismatch"]}
        return prepared

    def _launch_and_supervise(self) -> dict:
        content_hash = self._gates.get("content_hash")
        if not content_hash:
            return self._fail(CODE_INTERNAL)
        match_port = self.match_port if self.match_port is not None else self._gates.get("match_port")
        if isinstance(match_port, bool) or not isinstance(match_port, int):
            return self._fail(CODE_MATCH_PORT)
        self.match_port = int(match_port)
        self.certificate_id = self._gates.get("certificate_id")
        self.backup_id = self._gates.get("backup_id")
        nonce = self._gates.get("nonce")
        if not isinstance(nonce, str) or not nonce:
            return self._fail(CODE_INTERNAL)
        # The required Major League config digest is never allowed to fall back to the
        # role-parity content hash: a missing or malformed digest fails closed before
        # the control service starts or any role spawns (regression: no service start
        # or spawn without a real source-derived digest).
        self.config_digest = _trusted_config_digest(self._gates.get("config_digest"))
        if self.config_digest is None:
            return self._fail(CODE_CONFIG_DIGEST, problems=["config_digest_missing"])
        ruleset = self._gates.get("ruleset") or {}
        self.admin_port = pick_free_port()
        service_config = practice_service.ServiceConfig(
            session_id=self.session_id,
            difficulty=str(self.request["difficulty"]),
            pacing=str(self.request["pacing"]),
            mode=str(self.request["mode"]),
            match_port=int(self.match_port),
            log_root=self.workspace.log_dir,
            content_hash=str(content_hash),
            expected_config_digest=str(self.config_digest),
            gauntlet=self.request.get("gauntlet"),
            ruleset_id=str(ruleset.get("ruleset_id") or practice_service.MAJOR_LEAGUE_RULESET_ID),
            gamemode=ruleset.get("gamemode"),
            forced_options=ruleset.get("forced_options"),
        )
        try:
            self.service = self._service_factory(service_config)
            self.service.start()
        except practice_service.PracticeError as error:
            return self._fail(error.code)
        except Exception:  # noqa: BLE001
            return self._fail(CODE_INTERNAL)

        descriptors = self._build_descriptors(nonce, str(content_hash))
        if self._descriptor_env_gap:
            return self._fail(CODE_DESCRIPTOR_ENV_GAP, descriptor_env_unbound=list(self._descriptor_env_gap))
        plan = self._build_plan()
        pre_live = self._live_closed()
        if not pre_live.get("ok"):
            # H-A-1: a live game reappearing before the roles spawn takes the reviewed
            # void/failure-closure path, exactly like an in-run reappearance, so a
            # never-spawned record can never be left open with no way to close it.
            return self._void(CODE_LIVE_APPEARED)
        if self._attestation_rotator is not None:
            self._attestation_rotator(self.config)
        else:
            rotate_role_attestations(self.config)

        # H3: the verified server and its owning-PID listener proof come BEFORE the
        # roles spawn, so the MP client never starts against a missing server.
        self._set_phase("launching")
        started = self._start_server()
        if not started.get("ok"):
            return self._fail(started.get("code", CODE_SERVER_FAILED), listener=_gate_summary(started.get("listener") or {}))

        open_session = self._gates.get("open_session") or self._open_session_record
        try:
            session = self._launch_runner(
                plan,
                session_descriptors=descriptors,
                nonce=nonce,
                enumerator=self._enumerator,
                open_session=open_session,
            )
        except Exception:  # noqa: BLE001
            return self._fail(CODE_LAUNCH_FAILED)
        self.session = session
        if not getattr(session, "ok", False):
            code = getattr(session, "code", CODE_LAUNCH_FAILED) or CODE_LAUNCH_FAILED
            return self._fail(code)
        self._role_records = _role_records(session)
        bound = self._bind_open_record(session)
        if not bound.get("ok"):
            return self._fail(bound.get("code", CODE_CERTIFICATE_REQUIRED))

        if self.config.require_attestation:
            self._set_phase("attesting")
            attestation = self._wait_attestation(nonce)
            self.attestation = attestation
            if not attestation.get("ok"):
                return self._fail(attestation.get("code", CODE_ATTESTATION), attestation=_gate_summary(attestation))
            marked = self._mark_attested()
            if not marked.get("ok"):
                return self._fail(marked.get("code", CODE_ATTESTATION), attestation=_gate_summary(attestation))
            written = self._write_attestations(nonce)
            if not written.get("ok"):
                return self._fail(written.get("code", CODE_ATTESTATION), attestation=_gate_summary(attestation))
            # The companions only act after reading the published attestation
            # files, so the bounded pre-start budget starts now, not at
            # ``mark_attested``. A failure here is a no-op: the service keeps
            # its earlier clock and the timeout is never bypassed.
            self._start_prestart_window()

        self._set_phase("running")
        verdict = self._supervise_loop()
        if not verdict.get("ok"):
            if verdict.get("code") == CODE_LIVE_APPEARED:
                return self._void(CODE_LIVE_APPEARED, supervision=verdict)
            return self._fail(verdict.get("code", CODE_INTERNAL), supervision=verdict)
        self._set_phase("ending")
        return self._finalize_after_run()

    def _bind_open_record(self, session) -> dict:
        api = self._certificate_api
        if not self.config.require_certificate or not callable(getattr(api, "bind_open_session", None)):
            return {"ok": True}
        pids: dict = {}
        for item in getattr(session, "owned", ()):
            pids.setdefault(getattr(item, "role", "?"), []).append(int(getattr(item, "pid", 0)))
        spawn_time = float(getattr(session, "spawn_time", 0.0) or 0.0)
        try:
            verdict = api.bind_open_session(
                self.config.staging_root, self.session_id, pids=pids, spawn_time=spawn_time
            )
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED}
        if not isinstance(verdict, dict) or not verdict.get("ok"):
            return {"ok": False, "code": CODE_CERTIFICATE_REQUIRED}
        return verdict

    def _mark_attested(self) -> dict:
        """Trusted host-only attestation gate: only after both probes, before files (M8)."""
        fn = getattr(self.service, "mark_attested", None)
        if not callable(fn):
            return {"ok": False, "code": CODE_ATTESTATION, "problems": ["service_mark_attested_missing"]}
        if not isinstance(self.config_digest, str) or not self.config_digest:
            return {"ok": False, "code": CODE_CONFIG_DIGEST}
        try:
            ok = bool(fn(self.config_digest))
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_ATTESTATION}
        return {"ok": True, "code": CODE_OK} if ok else {"ok": False, "code": CODE_ATTESTATION}

    def _wait_attestation(self, nonce: str) -> dict:
        spawn_time = float(getattr(self.session, "spawn_time", 0.0) or 0.0)
        if self._attestation_collector is not None:
            return self._attestation_collector(self.config, nonce, spawn_time, self.match_port)
        deadline = min(float(self.config.attestation_timeout), float(self.config.prestart_timeout))
        return wait_for_attestation(
            self.config,
            nonce=nonce,
            spawn_time=spawn_time,
            port=self.match_port,
            timeout=deadline,
            clock=self._clock,
            sleeper=self._sleeper,
        )

    def _write_attestations(self, nonce: str) -> dict:
        control_port = int(getattr(self.service, "port", None) or self.match_port)
        port = int(self.match_port)
        if self._attestation_writer is not None:
            try:
                verdict = self._attestation_writer(
                    self.config,
                    session_id=self.session_id,
                    nonce=nonce,
                    control_port=control_port,
                    port=port,
                )
            except Exception:  # noqa: BLE001
                return {"ok": False, "code": CODE_ATTESTATION, "problems": ["attestation_write_failed"]}
            return verdict if isinstance(verdict, dict) else {"ok": False, "code": CODE_ATTESTATION}
        return write_role_attestations(
            self.config, session_id=self.session_id, nonce=nonce, control_port=control_port, port=port
        )

    def _start_prestart_window(self) -> dict:
        """Trusted host-only: open the pre-start clock after the files are published.

        Called immediately after a successful ``_write_attestations`` (M8 order
        unchanged). A missing/refusing service method is a no-op rather than a
        failure: the service keeps its earlier ``attested_at`` start, so the
        pre-start timeout is never bypassed by not resetting it.
        """
        fn = getattr(self.service, "start_prestart_window", None)
        if not callable(fn):
            return {"ok": False, "code": CODE_ATTESTATION, "problems": ["service_start_prestart_window_missing"]}
        try:
            started = bool(fn())
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_ATTESTATION}
        return {"ok": True, "code": CODE_OK} if started else {"ok": False, "code": CODE_ATTESTATION}

    def _finalize_after_run(self) -> dict:
        """Retain the human window, retire server/service only after it exits, then diff."""
        self._teardown_for_completion()
        if self.human_retained:
            self._set_phase("awaiting_human_exit")
            outcome = self._await_human_exit()
            if outcome == "void":
                return self._void(CODE_LIVE_APPEARED)
            if outcome != "exited":
                return self._finalize_unverified_human()
        # The human window has closed: now the owned loopback server and service
        # can be retired before the (real, closed) after-diff.
        self._stop_server()
        self._stop_service()
        self._reap_owned()
        if self._post_verifier is not None:
            self._post_verifier()
            if self.error is not None:
                return self._fail(self.error)
        # No after-diff is taken while a live game is open (must be actually closed).
        live = self._live_closed()
        if not live.get("ok"):
            return self._void(CODE_LIVE_APPEARED, live=live)
        verdict = self._record_live_verdict()
        self.live_verdict = verdict
        if verdict is not None and verdict.get("ok") is False:
            # H-A: only a real measured byte diff is a live change. Any other refusal
            # (an unmeasured closure) closes the record as failed + persistent lockout
            # so the next ticket/acknowledge is not wedged (H-A-1).
            if verdict.get("code") == "live_byte_diff_revoked":
                # H-A-1-R2: the certificate already persisted the record as failed
                # (and raised the byte-diff lockout); only ownership remains to be
                # retired. Clearing ``_record_started`` first means a retire failure
                # becomes a pending closure that only needs retiring, and no second
                # verdict/failure persistence can wedge it (``session_already_closed``
                # -> ``open_session_missing`` forever).
                self._record_started = False
                return self._finalize_refused_closure(CODE_LIVE_CHANGED, live_verdict=verdict)
            if self._record_started and self.config.require_certificate:
                return self._finalize_refused_closure(verdict.get("code") or "live_verdict_failed")
            return self._finalize_unverified_human()
        if verdict is None or verdict.get("ok") is not True:
            if self._record_started and self.config.require_certificate:
                code = verdict.get("code") if isinstance(verdict, dict) else None
                return self._finalize_refused_closure(code or "live_verdict_failed")
            return self._finalize_unverified_human()
        self._clear_unmeasured_lockout()
        self._set_phase("completed")
        self.code = CODE_OK
        # N-1-R: the certificate has measured and closed the record against the
        # retained handles; only now may ownership be dropped. If a retained owned
        # handle still cannot be proven exited, remember the pending closure so the
        # public acknowledge/start retry completes the retire instead of wedging.
        retained_record = self._record_started
        self._record_started = False
        if (
            retained_record
            and self.config.require_certificate
            and not self._retire_session()
        ):
            self._pending_closure = "session_closure_unproven"
            self.code = "session_closure_unproven"
            self.error = _compact_error(self.code)
            self._set_phase("failed")
            self.human_retained = True
            return self._finalize(error_code=self.code, closure_unproven=True)
        return self._finalize()

    def _await_human_exit(self) -> str:
        """Retain the human results window until it exits; no short deadline (H4).

        While retained, any newly appeared live Balatro process voids the session
        and writes the acknowledgement lockout. ``exited`` / ``void`` / ``unverified``
        are returned; the human staged handle is never terminated here.
        """
        if self._human_exit_waiter is not None:
            return "exited" if self._human_exit_waiter(self.session, None) else "unverified"
        if self.session is None:
            return "exited"
        while True:
            live = self._live_closed()
            if not live.get("ok"):
                return "void"
            statuses = self.session.is_running()
            human = [item for item in statuses if item.get("role") == "human"]
            if not human or not human[0].get("running"):
                return "exited"
            self._sleeper(min(float(self.config.poll_interval), 1.0))

    def _record_live_verdict(self):
        """Ask the certificate to measure and bind the after-snapshot itself.

        No caller snapshot or ``closed_check`` boolean is passed: the certificate
        recomputes the after-snapshot, recomputes the digests and closes/records the
        open record (zero-diff pass, revocation + lockout on a byte change).
        """
        if not self.config.require_certificate:
            return {"ok": None, "code": "live_diff_not_measured"}
        api = self._certificate_api
        try:
            if self._verdict_recorder is not None:
                verdict = self._verdict_recorder(
                    self.config,
                    self.session_id,
                    self.open_record,
                    None,
                    self.backup_id,
                    self.certificate_id,
                )
            else:
                verdict = api.record_session_verdict(
                    self.config.staging_root,
                    session_id=self.session_id,
                    live=self._live_map(),
                    session=self.session,
                    live_closed=self._live_closed_check,
                    backup_id=self.backup_id,
                    certificate_id=self.certificate_id,
                )
        except Exception:  # noqa: BLE001
            return {"ok": None, "code": "live_verdict_failed"}
        # H-A: only a measured byte diff raises the byte-diff lockout. A refusal for
        # any other reason keeps the pre-spawn ``session_unmeasured`` lockout, so a
        # run that never happened is never labelled ``live_byte_diff``.
        if isinstance(verdict, dict) and verdict.get("ok") is False and verdict.get("code") == "live_byte_diff_revoked":
            set_host_lockout(
                self.config,
                reason="live_byte_diff",
                session_id=self.session_id,
                extra={"changed_roots": verdict.get("changed_roots")},
            )
        return verdict

    def _record_no_spawn_verdict(self):
        """Measured closure of a prepared session that never spawned (H-A).

        Used when the open record exists but no owned role handles do. The
        certificate re-measures the after-snapshot and refuses if the live tree
        changed; the returned receipt closes the record so the next ticket and the
        acknowledgement are no longer wedged.
        """
        if not self.config.require_certificate:
            return {"ok": None, "code": "no_spawn_not_measured"}
        api = self._certificate_api
        try:
            if self._no_spawn_recorder is not None:
                verdict = self._no_spawn_recorder(self.config, self.session_id, self.open_record)
            else:
                verdict = api.record_session_no_spawn(
                    self.config.staging_root,
                    session_id=self.session_id,
                    live=self._live_map(),
                    backup_id=self.backup_id,
                )
        except Exception:  # noqa: BLE001
            return {"ok": None, "code": "no_spawn_failed"}
        if isinstance(verdict, dict) and verdict.get("ok") is False and verdict.get("code") == "live_byte_diff_revoked":
            set_host_lockout(
                self.config,
                reason="live_byte_diff",
                session_id=self.session_id,
                extra={"changed_roots": verdict.get("changed_roots")},
            )
        return verdict

    def _clear_unmeasured_lockout(self) -> None:
        """Only a measured passed verdict may clear the pre-spawn unmeasured lockout."""
        if self._unmeasured_lockout:
            try:
                clear_host_lockout(self.config, acknowledged_by="measured_pass")
            except Exception:  # noqa: BLE001
                pass
            self._unmeasured_lockout = False

    def _live_closed(self) -> dict:
        return launch_practice.check_live_balatro_closed(self._enumerator, self.config.live_install_root)

    def _live_closed_check(self) -> bool:
        """Enumerator-backed live-closed boolean for the certificate closure check."""
        try:
            return bool(self._live_closed().get("ok"))
        except Exception:  # noqa: BLE001
            return False

    def _reap_owned(self, timeout: float = 10.0) -> None:
        if self.session is None:
            return
        deadline = time.monotonic() + float(timeout)
        while time.monotonic() < deadline:
            if not any(item.is_running() for item in getattr(self.session, "owned", ())):
                return
            self._sleeper(0.1)

    def _live_map(self) -> dict:
        return self._gates.get("live_map") or staging.live_roots(
            install_root=self.config.live_install_root,
            appdata_root=self.config.live_appdata_root,
            steam_root=self.config.steam_root,
        )

    def _owned_exit_proven(self) -> bool:
        """True only when every retained owned handle reports it has exited.

        The proof is over the session's own retained process handles, never the
        synthetic role statuses, so a still-running owned process always fails
        closed. A query failure is itself treated as unproven (never a success).
        """
        session = self.session
        if session is None:
            return True
        try:
            return not any(
                bool(item.is_running()) for item in getattr(session, "owned", ()) or ()
            )
        except Exception:  # noqa: BLE001
            return False

    def _retire_session(self) -> bool:
        """Close owned handles and prove exit before dropping ownership (H-A-1).

        Returns ``True`` only once ``session.close()`` succeeded *and* every
        retained owned handle reports it has exited (bounded reaping window). A
        close/query failure, or an owned handle that is still running, returns
        ``False`` and keeps ``self.session`` so an open record can never be
        falsely closed while an owned process remains.
        """
        if self.session is None:
            return True
        self._terminate_roles()
        try:
            self.session.close()
        except Exception:  # noqa: BLE001
            return False
        try:
            self._reap_owned()
        except Exception:  # noqa: BLE001
            return False
        if not self._owned_exit_proven():
            return False
        self.session = None
        return True

    def _finalize_unverified_human(self) -> dict:
        """Human window still open / unmeasured: never claim a post-run zero diff.

        The open record is deliberately left open (and the lockout retained), so a
        new ticket or acknowledgement is refused until a measured closure exists.
        """
        self.phase = "failed"
        self.code = CODE_HUMAN_EXIT_UNVERIFIED
        self.error = _compact_error(CODE_HUMAN_EXIT_UNVERIFIED)
        self.human_retained = True
        return self._finalize(error_code=CODE_HUMAN_EXIT_UNVERIFIED, human_retained=True)

    def _finalize_refused_closure(self, code: str, **extra) -> dict:
        """A refused/unmeasurable after-verdict closes the open record as failed.

        H-A-1: the record may only be closed as a measured *failure* once the
        owned session is proven closed and exited. If ``close``/the owned-handle
        query fails, or an owned handle still runs, ownership is retained, the
        record stays open and no failure closure is written: a refused closure
        must never falsely close a record while an owned process remains.

        Once safe, the certificate closes the record as failed (raising its
        persistent lockout) and the host's own ``session_unmeasured`` lockout
        stands, so the next ticket and ``acknowledge`` behave exactly as a void.
        """
        self._stop_server()
        self._stop_service()
        self.phase = "failed"
        self.code = code
        self.error = _compact_error(code)
        if not self._retire_session():
            self._pending_closure = code
            self.human_retained = True
            return self._finalize(
                error_code=code, human_retained=True, closure_unproven=True, **extra
            )
        self.human_retained = False
        if self._record_started and self.config.require_certificate:
            if not self._record_failure_closure(code):
                self._pending_closure = code
                return self._finalize(error_code=code, closure_unproven=True, **extra)
        return self._finalize(error_code=code, **extra)

    def _void(self, code: str, **extra) -> dict:
        """A live game appeared: stop practice, close the record as failed, lock out.

        H-B: the live tree is changing, so no after-snapshot is taken, but the open
        record must not be left open forever. Once the owned handles are confirmed
        exited the certificate closes the record as a measured *failure* and raises
        its persistent lockout; the existing ``acknowledge`` op then records an
        append-only acknowledgement. Nothing is silently re-baselined. If an owned
        handle cannot be proven exited, ownership is retained and the record stays
        open rather than being falsely closed.
        """
        self.voided = True
        self._set_phase("void")
        if self.service is not None:
            try:
                self.service.abort(code)
            except Exception:  # noqa: BLE001
                pass
        set_host_lockout(self.config, reason=code, session_id=self.session_id)
        self._stop_server()
        self._stop_service()
        self.code = code
        self.error = _compact_error(code)
        if not self._retire_session():
            self._pending_closure = code
            self.human_retained = True
            return self._finalize(
                error_code=code, void=True, human_retained=True, closure_unproven=True, **extra
            )
        self.human_retained = False
        if self._record_started and self.config.require_certificate:
            if not self._record_failure_closure(code):
                self._pending_closure = code
                return self._finalize(error_code=code, void=True, closure_unproven=True, **extra)
        return self._finalize(error_code=code, void=True, **extra)

    def _record_failure_closure(self, code: str) -> bool:
        """Close the open record as a measured failure and raise the cert lockout (H-B).

        ``_record_started`` is cleared only after the certificate actually
        persisted the closure. A raised or refused persistence leaves the record
        open (and the caller's ownership intact) rather than pretending it closed.
        """
        api = self._certificate_api
        if api is None or not callable(getattr(api, "record_session_failure", None)):
            return False
        try:
            verdict = api.record_session_failure(
                self.config.staging_root, session_id=self.session_id, reason=str(code)
            )
        except Exception:  # noqa: BLE001
            return False
        if isinstance(verdict, Mapping) and verdict.get("ok") is False:
            return False
        self._record_started = False
        return True

    def retry_pending_closure(self) -> bool:
        """Retry a closure that could not be retired/persisted (H-A-1-R).

        A refused closure (a stuck owned handle, or a persistence that raised once)
        is remembered in ``_pending_closure`` and re-attempted here, so the public
        ``acknowledge``/``start`` ops can complete it once the owned process finally
        exits. Returns ``True`` only when no pending closure remains: a handle that
        still cannot be proven exited, or a still-refused persistence, returns
        ``False`` and keeps the record/handles exactly as they were (a refused
        closure is never turned into a false one). Only a finished supervisor may be
        retried; the daemon enforces that before calling.
        """
        code = self._pending_closure
        if code is None:
            return True
        with self._closure_lock:
            # Re-read under the lock: a concurrent retry may have completed it.
            code = self._pending_closure
            if code is None:
                return True
            if not self._retire_session():
                return False
            self.human_retained = False
            if self._record_started and self.config.require_certificate:
                if not self._record_failure_closure(code):
                    return False
            self._pending_closure = None
            self.code = code
            self.error = _compact_error(code)
            self._set_phase("failed")
            self._finalize(error_code=code)
            return True

    def _build_plan(self) -> dict:
        return {
            "schema": "aisparring.launch_plan.v1",
            "session_id": self.session_id,
            "staging_root": str(self.config.staging_root),
            "backup_root": str(self.config.backup_root),
            "live_install_root": str(self.config.live_install_root),
            "port": int(self.match_port),
            "may_launch": True,
        }

    def _build_descriptors(self, nonce: str, content_hash: str):
        descriptors: dict = {}
        mode = str(self.request["mode"])
        gauntlet = str(self.request.get("gauntlet") or "") if mode == "gauntlet" else ""
        for role in staging.ROLES:
            paths = staging.role_paths(self.config.staging_root, role)
            credential = self.service.human_credential if role == "human" else self.service.ai_credential
            descriptors[role] = launch_practice.SessionDescriptor(
                role=role,
                session_id=self.session_id,
                role_credential=credential,
                control_port=int(self.service.port),
                content_hash=content_hash,
                probe_nonce=nonce,
                expected_role_save_root=str(paths.data / "Balatro"),
                expected_role_mods_root=str(paths.mods),
                mode=mode,
                difficulty=str(self.request["difficulty"]),
                pacing=str(self.request["pacing"]),
                gauntlet=gauntlet,
            )
        self._descriptor_env_gap = _descriptor_env_gap()
        return descriptors

    def _verified_node_path(self) -> Optional[str]:
        """The verified absolute Node path (M-1), never a bare PATH-resolved name.

        Only the path ``verify_server_adaptation`` hashed and recorded in the gate
        verdict is accepted; there is deliberately no ``shutil.which`` fallback, so
        an unverified PATH-resolved interpreter can never be launched (fail closed).
        """
        verdict = self._gates.get("server") if isinstance(self._gates, Mapping) else None
        candidate = verdict.get("node_executable") if isinstance(verdict, Mapping) else None
        if isinstance(candidate, str) and candidate and Path(candidate).is_file():
            return candidate
        return None

    def _start_server(self) -> dict:
        if self.match_port is None or self.admin_port is None:
            return {"ok": False, "code": CODE_MATCH_PORT}
        if not port_is_free(HOST, self.admin_port):
            self.admin_port = pick_free_port()
        entry = Path(self.config.server_root) / SERVER_ENTRY
        node = self._verified_node_path()
        if node is None:
            return {"ok": False, "code": CODE_SERVER_ADAPTATION, "problems": ["node_executable_unresolved"]}
        env = server_environment(
            self.config, self.match_port, self.admin_port, session_dir=self.workspace.server_dir
        )
        try:
            self.server = self._server_runner(
                [node, str(entry)],
                self.workspace.server_dir,
                env,
                self.workspace.log_dir,
            )
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_SERVER_FAILED}
        if not wait_for_listener(
            self.match_port,
            probe=self._listener_probe,
            timeout=self.config.server_start_timeout,
            clock=self._clock,
            sleeper=self._sleeper,
        ):
            return {"ok": False, "code": CODE_SERVER_FAILED}
        listener = verify_local_listener(
            self.match_port,
            self.admin_port,
            probe=self._listener_probe,
            strict=self.config.strict_listener_verification,
            expected_pid=getattr(self.server, "pid", None),
        )
        if not listener.get("ok"):
            return {"ok": False, "code": listener.get("code", CODE_LISTENER_UNPROVEN), "listener": listener}
        self._listener = listener
        return {"ok": True, "code": CODE_OK, "listener": listener}

    def _supervise_loop(self) -> dict:
        deadline = self._clock() + float(self.config.match_timeout)
        while True:
            live = self._live_closed()
            if not live.get("ok"):
                return {"ok": False, "code": CODE_LIVE_APPEARED, "live": live}
            if self.server is not None and not self.server.is_running():
                return {"ok": False, "code": CODE_SERVER_FAILED}
            if self.service is not None and getattr(self.service, "aborted", False):
                # H-C: a role-loss/timeout/abort is an abnormal end, never a
                # completion, even though its terminal phase reads ``closed``.
                reason = getattr(self.service, "terminal_reason", None) or CODE_ROLE_EXITED
                return {"ok": False, "code": "practice_service_aborted", "reason": reason}
            terminal = str(getattr(self.service, "terminal_phase", "none")) not in ("none", "", "None")
            if self.session is not None:
                statuses = self.session.is_running()
                exited = [item["role"] for item in statuses if not item["running"]]
                if "ai" in exited and not terminal:
                    return {"ok": False, "code": CODE_ROLE_EXITED, "role": "ai"}
                if "human" in exited:
                    # N-1: the human closing its staged window ends the isolated
                    # session only when the real service terminal reason is the
                    # authoritative human END. A mid-match close or crash is an
                    # abnormal end the host must report (measured cleanup follows).
                    reason = str(getattr(self.service, "terminal_reason", "") or "")
                    if reason != "human_end":
                        return {
                            "ok": False,
                            "code": CODE_HUMAN_EXIT_BEFORE_END,
                            "reason": reason,
                        }
                    return {"ok": True, "code": CODE_OK, "role": "human"}
            if terminal:
                # Only the human coordinator END authorizes a normal completion.
                # Any other terminal reason (abort/role lost/close) is a failure.
                reason = str(getattr(self.service, "terminal_reason", "") or "")
                if reason != "human_end":
                    return {"ok": False, "code": "practice_service_terminal_failed", "reason": reason}
                # Human coordinator END authorizes teardown; the server/service stay
                # up until the human window is retained/handled in _finalize_after_run.
                return {"ok": True, "code": CODE_OK, "service_terminal": True}
            if self._clock() >= deadline:
                return {"ok": False, "code": "practice_match_timeout"}
            self._sleeper(min(float(self.config.poll_interval), 1.0))

    def _stop_server(self) -> None:
        if self.server is not None:
            try:
                self.server.terminate()
            except Exception:  # noqa: BLE001
                pass
            self.server = None

    def _stop_service(self) -> None:
        if self.service is not None:
            try:
                self.service.close()
            except Exception:  # noqa: BLE001
                pass
            self.service = None

    def _terminate_roles(self, only=None) -> None:
        if self.session is None:
            return
        for item in list(getattr(self.session, "owned", ())):
            if only is not None and getattr(item, "role", None) not in only:
                continue
            try:
                item.terminate()
            except Exception:  # noqa: BLE001
                pass

    def _set_phase(self, phase: str) -> None:
        self.phase = phase

    def _fail(self, code: str, **extra) -> dict:
        self.phase = "failed"
        self.code = code
        self.error = _compact_error(code)
        if self.service is not None and not getattr(self.service, "ended", False):
            try:
                self.service.abort(code)
            except Exception:  # noqa: BLE001
                pass
        if self._record_started and self.config.require_certificate:
            self._shutdown_after_spawn()
        else:
            self.cleanup()
        return self._finalize(error_code=code, **extra)

    def _shutdown_after_spawn(self) -> None:
        """Close owned handles, then measure the after-diff or close as failed.

        Every exit after the persistent record exists takes the certificate's own
        measured verdict once live is actually closed. If no role was ever spawned
        (the record has no bound PIDs) the certificate's no-spawn closure is used
        instead, so a pre-spawn failure cannot strand an open record (H-A). If the
        closure cannot be measured -- a live game is open, or the verdict is refused
        for any non-diff reason -- the owned session is closed and, only once its
        exit is proven, the record is closed as a measured *failure* (H-A-1), which
        raises the certificate lockout while the host's ``session_unmeasured``
        lockout stands. If an owned handle cannot be proven exited, ownership is
        retained and the record stays open. Only a real measured
        ``live_byte_diff_revoked`` verdict raises the byte-diff lockout, and only a
        measured pass clears the unmeasured lockout, so a session can never silently
        rebaseline (C1).
        """
        self._stop_server()
        self._stop_service()
        self._terminate_roles()
        self._reap_owned()
        failure_code: Optional[str] = None
        live = self._live_closed()
        if not live.get("ok"):
            # The live tree is changing: no after-snapshot is taken, but a still-open
            # record is closed as failed so it can never be left open forever.
            failure_code = CODE_LIVE_APPEARED
        else:
            spawned = self.session is not None and bool(getattr(self.session, "owned", ()))
            verdict = self._record_live_verdict() if spawned else self._record_no_spawn_verdict()
            if isinstance(verdict, dict) and verdict.get("ok") is True:
                self._clear_unmeasured_lockout()
            elif not (
                isinstance(verdict, dict)
                and verdict.get("ok") is False
                and verdict.get("code") == "live_byte_diff_revoked"
            ):
                # Refused/unmeasured for a non-diff reason: close the record as failed
                # after the owned session is closed, so the next ticket/acknowledge is
                # not wedged (H-A-1). The exact byte-diff classification is preserved:
                # only the measured revocation branch above raises it.
                failure_code = (verdict or {}).get("code") if isinstance(verdict, dict) else None
                failure_code = failure_code or "session_closure_unproven"
        if not self._retire_session():
            # An owned handle could not be proven exited (or close/query failed):
            # retain ownership and leave the record open rather than falsely
            # recording a failure closure while an owned process remains. The
            # closure stays pending so the public ops can retry it later.
            self._pending_closure = failure_code or "session_closure_unproven"
            self.human_retained = True
            return
        self.human_retained = False
        if failure_code is not None and self._record_started and self.config.require_certificate:
            if not self._record_failure_closure(failure_code):
                self._pending_closure = failure_code

    def _finalize(self, error_code: Optional[str] = None, **extra) -> dict:
        report = {
            "schema": REPORT_SCHEMA,
            "version": VERSION,
            "session_id": self.session_id,
            "phase": self.phase,
            "code": self.code,
            "error": self.error,
            "match_port": self.match_port,
            "paths": {
                "workspace": str(self.workspace.root),
                "logs": str(self.workspace.log_dir),
                "server_logs": str(self.workspace.log_dir),
            },
            "log_index": _log_index(self.workspace),
            "live_exit": self._live_exit,
            "gates": _gate_summary(self._gates) if self._gates else None,
            "role_records": list(self._role_records),
            "human_retained": self.human_retained,
            "voided": self.voided,
            "certificate_id": self.certificate_id,
            "backup_id": self.backup_id,
            "config_digest": self.config_digest,
            "open_record": self.open_record,
            "attestation": _gate_summary(self.attestation) if self.attestation else None,
            "live_verdict": self.live_verdict,
            "open_record": self.open_record,
            "after_digest": (self.live_verdict or {}).get("after_digest") if isinstance(self.live_verdict, dict) else None,
            "descriptor_env_unbound": list(self._descriptor_env_gap),
            "host_lockout": read_host_lockout(self.config),
        }
        report.update(extra)
        try:
            write_session_report(self.workspace, report)
        except Exception:  # noqa: BLE001
            report["report_write"] = "failed"
        self._report = report
        return {"ok": error_code is None and self.error is None, "code": self.code, "phase": self.phase, "report": report}


def _default_service_factory(service_config):
    return practice_service.PracticeService(service_config)


def _default_launch_runner(plan, *, session_descriptors=None, nonce=None, enumerator=None, open_session=None):
    """Delegate to the real launcher with the prepared open record.

    The launcher owns the single session nonce: it is read from ``open_session``
    (the certificate's exclusive open record) and never re-minted here. There is no
    permissive fallback: a missing/closed open record makes the launcher refuse with
    ``open_session_required`` rather than spawning.
    """
    return launch_practice.execute_launch(
        plan,
        port=plan.get("port"),
        enumerator=enumerator,
        session_descriptors=session_descriptors,
        open_session=open_session,
    )


def _gate_summary(gates: Mapping) -> dict:
    out: dict = {}
    for key, value in (gates or {}).items():
        if isinstance(value, Mapping) and "ok" in value:
            out[key] = {"ok": bool(value.get("ok")), "code": value.get("code")}
        elif key in ("content_hash", "match_port", "live_map"):
            out[key] = value if key == "content_hash" else bool(value)
    return out


def _descriptor_env_gap() -> list:
    """Names the host emits that the certificate's bound descriptor surface does not yet cover."""
    bound = set(getattr(staging, "SESSION_DESCRIPTOR_VARS", ()))
    return sorted(name for name in launch_practice.SESSION_ENV_KEYS.values() if name not in bound)


def _role_records(session) -> list:
    if session is None:
        return []
    records = []
    for item in getattr(session, "records", ()):
        records.append(
            {
                "role": getattr(item, "role", None),
                "pid": getattr(item, "pid", None),
                "create_time": getattr(item, "create_time", None),
                "image_path": getattr(item, "image_path", None),
            }
        )
    return records


def _log_index(workspace: SessionWorkspace) -> dict:
    index: dict = {"report": str(workspace.report_path), "files": {}}
    if workspace.log_dir.is_dir():
        for child in sorted(workspace.log_dir.iterdir()):
            if child.is_file():
                index["files"][child.name] = {"bytes": child.stat().st_size}
    return index


def _compact_error(code: str) -> str:
    return f"AI Sparring practice stopped: {code}"


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------

def write_discovery(path, marker: Mapping) -> Path:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(marker, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
    os.replace(tmp, target)
    return target


def read_discovery(path) -> Optional[dict]:
    target = Path(path)
    if not target.is_file():
        return None
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def discovery_state(config: HostConfig, *, opener=None, enumerator=None) -> dict:
    """Classify the current discovery marker: live | stale | foreign | absent."""
    discovery = Path(config.resolved_discovery_path())
    marker = read_discovery(discovery)
    if marker is None:
        if discovery.exists():
            return {"ok": False, "code": CODE_FOREIGN_DISCOVERY, "state": "foreign"}
        return {"ok": True, "code": "practice_host_discovery_absent", "state": "absent"}
    if marker.get("schema") != DISCOVERY_SCHEMA:
        return {"ok": False, "code": CODE_FOREIGN_DISCOVERY, "state": "foreign"}
    if marker.get("module_sha256") != module_sha256():
        return {"ok": False, "code": CODE_FOREIGN_DISCOVERY, "state": "foreign"}
    pid, create_time = marker.get("pid"), marker.get("create_time")
    if not isinstance(pid, int) or not isinstance(create_time, (int, float)):
        return {"ok": False, "code": CODE_FOREIGN_DISCOVERY, "state": "foreign"}
    identity = read_live_identity(pid, opener=opener)
    if identity is not None and identity.get("create_time") is not None:
        if abs(float(identity["create_time"]) - float(create_time)) <= launch_practice.START_TIME_TOLERANCE:
            return {"ok": False, "code": CODE_ALREADY_RUNNING, "state": "live", "marker": marker}
        return {"ok": False, "code": CODE_STALE_DISCOVERY, "state": "stale_pid_reused", "marker": marker}
    absent = _confirm_absent(enumerator or launch_practice.default_enumerator(), pid, float(create_time))
    if absent.get("code") == "practice_live_exit_unverified":
        return {"ok": False, "code": "practice_host_discovery_unverified", "state": "unverified", "marker": marker}
    if absent.get("code") == "practice_live_still_running":
        return {"ok": False, "code": CODE_ALREADY_RUNNING, "state": "live", "marker": marker}
    return {"ok": True, "code": CODE_STALE_DISCOVERY, "state": "stale", "marker": marker}


class HostDaemon:
    """Loopback-only authenticated daemon the live menu adapter talks to."""

    def __init__(
        self,
        config: HostConfig,
        *,
        supervisor_factory=None,
        listener_probe=None,
        opener=None,
        enumerator=None,
        certificate_api=None,
        runtime_checker=None,
        which=None,
        ruleset_reader=None,
        start_gate=None,
        secret: Optional[str] = None,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        validate_config(config)
        self.config = config
        self._supervisor_factory = supervisor_factory or _default_supervisor_factory
        self._listener_probe = listener_probe
        self._opener = opener
        self._enumerator = enumerator
        self._runtime_checker = runtime_checker
        self._certificate_api = certificate_api if certificate_api is not None else isolation_certificate
        self._which = which
        self._ruleset_reader = ruleset_reader
        # M-3: the pre-acknowledgement gate. Production always runs the real
        # default; tests inject it so acceptance paths need no on-disk server.
        self._start_gate = start_gate or (
            lambda: default_start_gate(
                config,
                certificate_api=self._certificate_api,
                which=self._which,
                ruleset_reader=self._ruleset_reader,
            )
        )
        self._clock = clock
        self._sleeper = sleeper
        self._secret = secret or secrets.token_hex(32)
        self.daemon_id = "host-" + secrets.token_hex(8)
        self.session = "host-" + secrets.token_hex(16)
        self.port: Optional[int] = None
        self.started_unix: Optional[float] = None
        self.start_code: Optional[str] = None
        self._server = None
        self._thread = None
        self._lock = threading.RLock()
        self._ticket: Optional[MatchTicket] = None

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> dict:
        if self._server is not None:
            raise HostError(CODE_BAD_REQUEST)
        state = discovery_state(self.config, opener=self._opener, enumerator=self._enumerator)
        if state["state"] == "live":
            raise HostError(CODE_ALREADY_RUNNING)
        if state["state"] == "foreign":
            raise HostError(CODE_FOREIGN_DISCOVERY)
        if state["state"] == "unverified":
            raise HostError("practice_host_discovery_unverified")
        if state["state"] in ("stale", "stale_pid_reused"):
            self.start_code = CODE_STALE_DISCOVERY
        server = _HostControlServer((HOST, int(self.config.bind_port)), self)
        self._server = server
        self.port = int(server.server_address[1])
        self.started_unix = time.time()
        self._thread = threading.Thread(target=server.serve_forever, name="practice-host", daemon=True)
        self._thread.start()
        marker = {
            "schema": DISCOVERY_SCHEMA,
            "version": VERSION,
            "daemon_id": self.daemon_id,
            "session": self.session,
            "pid": os.getpid(),
            "create_time": launch_practice.read_process_create_time(os.getpid()),
            "module_sha256": module_sha256(),
            "host": HOST,
            "port": self.port,
            "secret": self._secret,
            "started_unix": self.started_unix,
            "ops": list(MENU_OPS),
            "enums": {
                "difficulty": list(practice_service.DIFFICULTIES),
                "pacing": list(practice_service.PACING),
                "mode": list(practice_service.MODES),
                "gauntlet": sorted(self.config.gauntlet_catalog),
            },
        }
        write_discovery(self.config.resolved_discovery_path(), marker)
        return {
            "ok": True,
            "code": self.start_code or CODE_OK,
            "daemon_id": self.daemon_id,
            "session": self.session,
            "port": self.port,
            "discovery": str(self.config.resolved_discovery_path()),
            "stale_replaced": self.start_code == CODE_STALE_DISCOVERY,
        }

    def _active_supervisor(self):
        with self._lock:
            ticket = self._ticket
        return ticket.supervisor if ticket is not None else None

    def _retry_pending_closure(self) -> bool:
        """Retry a finished supervisor's pending closure (H-A-1-R).

        Only a supervisor whose worker thread has actually finished is retried: a
        still-running supervisor owns its own closure and must never be touched
        concurrently. Returns ``False`` only when a pending closure still cannot be
        completed (a stuck owned handle, or a still-failing persistence), so the
        caller can refuse rather than reach ``cleanup`` while it is needed.
        """
        with self._lock:
            ticket = self._ticket
        if ticket is None or ticket.supervisor is None:
            return True
        thread = ticket.thread
        if thread is not None and thread.is_alive():
            return True
        fn = getattr(ticket.supervisor, "retry_pending_closure", None)
        if not callable(fn):
            return True
        try:
            return bool(fn())
        except Exception:  # noqa: BLE001
            return False

    def human_active(self) -> bool:
        """True while a retained staged human window is still owned (H4)."""
        supervisor = self._active_supervisor()
        if not callable(getattr(supervisor, "human_active", None)):
            return False
        try:
            return bool(supervisor.human_active())
        except Exception:  # noqa: BLE001
            return False

    def _runtime_preflight(self) -> dict:
        return runtime_preflight(self.config, checker=self._runtime_checker)

    def stop(self, *, force: bool = False) -> dict:
        """Shut the daemon down. Refuses while a staged human window is retained.

        The staged human process is owned through a kill-on-close Job Object, so
        exiting the daemon while it is still open would kill the user's window.
        A deferred stop leaves the daemon and the loopback socket alive (H4).
        """
        if not force:
            # H-A-1-R: never reach cleanup() while a finished supervisor still holds
            # a pending closure that needs its retained handles.
            if not self._retry_pending_closure():
                return {"ok": False, "code": CODE_CLOSURE_PENDING, "stopped": False}
            if self.human_active():
                return {"ok": False, "code": CODE_HUMAN_ACTIVE, "stopped": False}
        with self._lock:
            ticket = self._ticket
            self._ticket = None
        if ticket is not None and ticket.supervisor is not None:
            try:
                ticket.supervisor.cleanup()
            except Exception:  # noqa: BLE001
                pass
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
        thread = self._thread
        if thread is not None and thread.is_alive():
            thread.join(timeout=5.0)
        self._server = None
        self._thread = None
        marker = read_discovery(self.config.resolved_discovery_path())
        if marker is not None and marker.get("daemon_id") == self.daemon_id:
            try:
                Path(self.config.resolved_discovery_path()).unlink()
            except OSError:
                pass
        return {"ok": True, "code": CODE_OK, "stopped": True}

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.stop()

    # -- wire ----------------------------------------------------------------

    def handle_line(self, line) -> dict:
        if isinstance(line, str):
            raw = line.encode("utf-8", "replace")
        elif isinstance(line, (bytes, bytearray)):
            raw = bytes(line)
        else:
            return {"ok": False, "code": CODE_BAD_LINE}
        if len(raw) > MAX_LINE_BYTES:
            return {"ok": False, "code": CODE_INPUT_TOO_LARGE}
        text = raw.decode("utf-8", "replace").strip()
        if not text:
            return {"ok": False, "code": CODE_BAD_LINE}
        try:
            payload = parse_json_line(text)
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_BAD_LINE}
        return self.handle_request(payload)

    def handle_request(self, message) -> dict:
        try:
            return self._dispatch(message)
        except HostError as error:
            return {"ok": False, "code": error.code}
        except Exception:  # noqa: BLE001
            return {"ok": False, "code": CODE_INTERNAL}

    def _dispatch(self, message) -> dict:
        if self._server is None:
            return {"ok": False, "code": CODE_HOST_CLOSED}
        if not isinstance(message, dict) or set(message.keys()) != REQUEST_KEYS:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        if message.get("schema") != REQUEST_SCHEMA:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        auth = message.get("auth")
        if not isinstance(auth, str) or not hmac.compare_digest(auth.encode("utf-8"), self._secret.encode("utf-8")):
            return {"ok": False, "code": CODE_BAD_AUTH}
        op = message.get("op")
        if op not in MENU_OPS:
            return {"ok": False, "code": CODE_BAD_OP}
        request = message.get("request")
        request = {} if request is None else request
        if not isinstance(request, dict):
            return {"ok": False, "code": CODE_BAD_REQUEST}
        if op == "available":
            return self._op_available(request)
        if op == "start":
            return self._op_start(request)
        if op == "poll":
            return self._op_poll(request)
        if op == "acknowledge":
            return self._op_acknowledge(request)
        return self._op_status(request)

    def _op_available(self, request) -> dict:
        if set(request.keys()) - {"live_pid"}:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        with self._lock:
            active = self._ticket is not None
        return {
            "ok": True,
            "code": CODE_OK,
            "version": VERSION,
            "host": HOST,
            "daemon_id": self.daemon_id,
            "session": self.session,
            "ticket_active": active,
            "human_active": self.human_active(),
            "open_records": certificate_open_records(self._certificate_api, self.config),
            "lockout": read_host_lockout(self.config),
            "enums": {
                "difficulty": list(practice_service.DIFFICULTIES),
                "pacing": list(practice_service.PACING),
                "mode": list(practice_service.MODES),
                "gauntlet": sorted(self.config.gauntlet_catalog),
            },
        }

    def _op_acknowledge(self, request) -> dict:
        if set(request.keys()) != {"confirm"} or request.get("confirm") is not True:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        # H-A-1-R: a finished supervisor may hold a pending closure (a stuck owned
        # handle that has since exited, or a persistence that failed once). Retry it
        # through this public op before the human/open-record checks so a delayed
        # safe exit can always be closed without hand-editing evidence. A retry that
        # still cannot retire/persist must refuse: acknowledging would otherwise
        # pretend the still-open record/kept handles are resolved.
        if not self._retry_pending_closure():
            return {"ok": False, "code": CODE_CLOSURE_PENDING}
        if self.human_active():
            return {"ok": False, "code": CODE_HUMAN_ACTIVE}
        # A prior unclosed/unmeasured record blocks acknowledgement until closure.
        open_records = certificate_open_records(self._certificate_api, self.config)
        if open_records:
            return {"ok": False, "code": CODE_OPEN_RECORD_BLOCKED, "open_records": open_records}
        clear_host_lockout(self.config)
        api = self._certificate_api
        acked = None
        try:
            if callable(getattr(api, "lockout", None)) and dict(api.lockout(self.config.staging_root)).get("locked"):
                acked = api.acknowledge_lockout(
                    self.config.staging_root, operator="user", reason="explicit_acknowledge"
                )
        except Exception:  # noqa: BLE001
            acked = None
        return {"ok": True, "code": CODE_OK, "cleared": True, "certificate_lockout": acked}

    def _op_start(self, request) -> dict:
        if set(request.keys()) != START_REQUEST_KEYS:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        # H-A-1-R: retry a finished prior supervisor's pending closure before the
        # open-record check, so a delayed safe exit never wedges the next ticket.
        # This runs before the ticket slot is reserved, so it always targets the
        # prior (finished) supervisor, never the one about to be created. A retry
        # that still cannot retire/persist must refuse before ``cleanup`` can drop
        # the kept handles that are the only proof of exit.
        if not self._retry_pending_closure():
            return {"ok": False, "code": CODE_CLOSURE_PENDING}
        if self.human_active():
            # A new ticket must never terminate a retained human window (H4).
            return {"ok": False, "code": CODE_HUMAN_ACTIVE}
        # M-4: reserve the ticket slot atomically in one locked block *before* any
        # preflight. Two concurrent starts can no longer both be admitted and
        # overwrite each other, which would orphan a retained human window.
        with self._lock:
            current = self._ticket
            if current is not None and current.phase in (
                "accepted",
                "waiting_live_exit",
                "launching",
                "running",
                "ending",
            ):
                return {"ok": False, "code": CODE_TICKET_ACTIVE}
            previous = current
            ticket = MatchTicket(
                ticket="ticket-" + secrets.token_hex(8),
                request={},
                phase="accepted",
                code=CODE_ACCEPTED,
                accepted_unix=time.time(),
            )
            self._ticket = ticket

        def _release() -> None:
            with self._lock:
                if self._ticket is ticket:
                    self._ticket = previous

        open_records = certificate_open_records(self._certificate_api, self.config)
        if open_records:
            _release()
            return {"ok": False, "code": CODE_OPEN_RECORD_BLOCKED, "open_records": open_records}
        lockout = read_host_lockout(self.config)
        if lockout.get("locked"):
            _release()
            return {"ok": False, "code": CODE_ACK_REQUIRED, "lockout": lockout}
        cert_lock = _certificate_lockout(self._certificate_api, self.config)
        if cert_lock.get("locked"):
            _release()
            return {"ok": False, "code": CODE_CERTIFICATE_LOCKED, "lockout": cert_lock}
        try:
            clean = self._validate_start_request(request)
        except HostError as error:
            _release()
            return {"ok": False, "code": error.code}
        live = verify_live_target(
            self.config, clean["live_pid"], clean["live_create_time"], opener=self._opener
        )
        if not live.get("ok"):
            _release()
            return live
        # Runtime/policy preflight before acknowledgement (item 15): the menu may
        # only quit the game once the host has proven the real policy source,
        # canonicalizer and required Lua runtime are available. No process is
        # launched by this check.
        preflight = self._runtime_preflight()
        if not preflight.get("ok"):
            _release()
            return {
                "ok": False,
                "code": CODE_RUNTIME_PREFLIGHT,
                "problems": preflight.get("problems") or [],
            }
        # M-3: every gate that does not need the game closed runs before the
        # acknowledgement, so the user never quits Balatro only to fail afterwards.
        try:
            gate = self._start_gate()
        except Exception:  # noqa: BLE001
            gate = {"ok": False, "code": CODE_INTERNAL}
        if not isinstance(gate, dict) or not gate.get("ok"):
            _release()
            gate = gate if isinstance(gate, dict) else {}
            return {
                "ok": False,
                "code": gate.get("code") or CODE_INTERNAL,
                "problems": gate.get("problems") or [],
            }
        try:
            ticket.request = clean
            # Retire a finished previous ticket's owned handles, but never a retained
            # human window (its handle stays owned by this daemon until it exits).
            if previous is not None and previous.supervisor is not None:
                try:
                    still_human = callable(getattr(previous.supervisor, "human_active", None)) and previous.supervisor.human_active()
                except Exception:  # noqa: BLE001
                    still_human = False
                if not still_human:
                    try:
                        previous.supervisor.cleanup()
                    except Exception:  # noqa: BLE001
                        pass
            supervisor = self._supervisor_factory(self.config, clean)
            ticket.supervisor = supervisor
            thread = threading.Thread(
                target=self._run_ticket, args=(ticket, supervisor), name="practice-host-supervisor", daemon=True
            )
            ticket.thread = thread
            # A concurrent stop() can retire this daemon (and this ticket) after the
            # reservation ran. Re-check and start under the same lock so a stop()
            # between the two can never start an orphaned supervisor thread.
            with self._lock:
                retired = self._ticket is not ticket or self._server is None
                if not retired:
                    thread.start()
            if retired:
                _release()
                try:
                    supervisor.cleanup()
                except Exception:  # noqa: BLE001
                    pass
                return {"ok": False, "code": CODE_HOST_CLOSED}
        except BaseException:
            # A factory/workspace-mkdir/thread-start failure must never leak the
            # reserved slot (a later start would otherwise be stuck ``ticket_active``).
            _release()
            raise
        return {
            "ok": True,
            "code": CODE_ACCEPTED,
            "ticket": ticket.ticket,
            "phase": ticket.phase,
            "session_id": getattr(supervisor, "session_id", None),
        }

    def _op_poll(self, request) -> dict:
        if set(request.keys()) != POLL_REQUEST_KEYS:
            return {"ok": False, "code": CODE_BAD_REQUEST}
        ticket_id = request.get("ticket")
        with self._lock:
            ticket = self._ticket
        if ticket is None or ticket.ticket != ticket_id:
            return {"ok": False, "code": CODE_TICKET_UNKNOWN}
        return ticket.poll()

    def _op_status(self, request) -> dict:
        with self._lock:
            ticket = self._ticket
        return {
            "ok": True,
            "code": CODE_OK,
            "daemon_id": self.daemon_id,
            "session": self.session,
            "port": self.port,
            "human_active": self.human_active(),
            "open_records": certificate_open_records(self._certificate_api, self.config),
            "lockout": read_host_lockout(self.config),
            "ticket": None if ticket is None else ticket.poll(),
        }

    def _run_ticket(self, ticket: MatchTicket, supervisor: MatchSupervisor) -> None:
        result = supervisor.run()
        with self._lock:
            ticket.phase = supervisor.phase if supervisor.phase in PHASES else "failed"
            ticket.code = result.get("code", CODE_INTERNAL)
            ticket.error = supervisor.error

    def _validate_start_request(self, request) -> dict:
        session_id = request.get("session_id")
        if not isinstance(session_id, str) or not TOKEN_RE.match(session_id):
            raise HostError(CODE_BAD_REQUEST)
        difficulty = request.get("difficulty")
        if difficulty not in practice_service.DIFFICULTIES:
            raise HostError(CODE_BAD_ENUM)
        pacing = request.get("pacing")
        if pacing not in practice_service.PACING:
            raise HostError(CODE_BAD_ENUM)
        mode = request.get("mode")
        if mode not in practice_service.MODES:
            raise HostError(CODE_BAD_ENUM)
        gauntlet = request.get("gauntlet")
        if mode == "gauntlet":
            if gauntlet not in self.config.gauntlet_catalog:
                raise HostError(CODE_BAD_ENUM)
        elif gauntlet is not None:
            raise HostError(CODE_BAD_ENUM)
        live_pid = _bounded_int(request.get("live_pid"), 1, 0x7FFFFFFF)
        if live_pid is None:
            raise HostError(CODE_BAD_LIVE_PID)
        create_time = request.get("live_create_time")
        if isinstance(create_time, bool) or not isinstance(create_time, (int, float)) or float(create_time) <= 0:
            raise HostError(CODE_BAD_LIVE_PID)
        return {
            "session_id": session_id,
            "difficulty": difficulty,
            "pacing": pacing,
            "mode": mode,
            "gauntlet": gauntlet if mode == "gauntlet" else None,
            "live_pid": live_pid,
            "live_create_time": float(create_time),
        }


def _default_supervisor_factory(config, request):
    return MatchSupervisor(config, request)


def default_start_gate(config, *, certificate_api=None, which=None, ruleset_reader=None) -> dict:
    """Gates that do not need the game closed, run before the quit acknowledgement (M-3).

    A missing fixed match port, a missing certificate, a drifted server adaptation,
    missing staged endpoints or a ruleset-digest failure must refuse the
    acknowledgement, so the user never quits Balatro only to watch the session fail
    after launch. Nothing here spawns a process or touches the live tree.
    """
    if config.require_fixed_match_port and config.match_port is None:
        return {"ok": False, "code": CODE_MATCH_PORT_UNCONFIGURED, "problems": ["match_port_unconfigured"]}
    port = config.match_port
    if config.require_certificate:
        missing = measurement_api_problems(certificate_api)
        if missing:
            return {"ok": False, "code": CODE_MEASUREMENT_API_MISSING, "problems": missing}
        cert_lock = _certificate_lockout(certificate_api, config)
        if cert_lock.get("locked"):
            return {"ok": False, "code": CODE_CERTIFICATE_LOCKED, "lockout": cert_lock}
        cert = certificate_gate(config, port=port, api=certificate_api)
        if not cert.get("ok"):
            return {"ok": False, "code": cert.get("code", CODE_CERTIFICATE_REQUIRED), "certificate": cert}
    server = verify_server_adaptation(config, which=which)
    if not server.get("ok"):
        return {"ok": False, "code": CODE_SERVER_ADAPTATION, "server": server}
    endpoints = staging.verify_staged_endpoints(config.staging_root, port=port)
    if not endpoints.get("ok"):
        return {"ok": False, "code": CODE_STAGED_ENDPOINTS, "endpoints": endpoints}
    if config.require_certificate:
        # The role-parity Mods digest is also checked here, before the user quits the
        # game, so a stale certificate refuses the acknowledgement instead of only
        # failing after the human window has already been closed.
        if not certificate_content_hash(certificate_api, config.staging_root):
            return {
                "ok": False,
                "code": CODE_CERTIFICATE_REQUIRED,
                "problems": ["role_parity_digest_unavailable"],
            }
        reader = ruleset_reader or ruleset_contract.expected_ruleset
        try:
            ruleset = reader(config.staging_root)
        except Exception:  # noqa: BLE001
            ruleset = {"ok": False, "problems": ["ruleset_unreadable"]}
        if not isinstance(ruleset, dict) or not ruleset.get("ok"):
            return {"ok": False, "code": CODE_CONFIG_DIGEST, "ruleset": ruleset}
    return {"ok": True, "code": CODE_OK}


class _HostHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        daemon: HostDaemon = self.server.daemon
        try:
            self.connection.settimeout(10.0)
        except Exception:  # noqa: BLE001
            pass
        while True:
            try:
                line = self.rfile.readline(MAX_LINE_BYTES + 2)
            except OSError:
                break
            if not line:
                break
            if len(line) > MAX_LINE_BYTES + 1:
                self._send({"ok": False, "code": CODE_INPUT_TOO_LARGE})
                break
            if not self._send(daemon.handle_line(line)):
                break

    def _send(self, response: Mapping) -> bool:
        try:
            self.wfile.write((encode_response(response) + "\n").encode("utf-8"))
            self.wfile.flush()
            return True
        except Exception:  # noqa: BLE001
            return False


class _HostControlServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, daemon: HostDaemon) -> None:
        self.daemon = daemon
        super().__init__(address, _HostHandler)


# ---------------------------------------------------------------------------
# Developer launcher script generation (repo outputs only)
# ---------------------------------------------------------------------------

def generate_developer_launcher(config: HostConfig, directory=None) -> dict:
    """Write developer start scripts under the repository work/ tree only."""
    target_dir = Path(directory) if directory else Path(config.work_dir) / "dev"
    if not staging.is_within(config.repo_root, target_dir, allow_root=True):
        return {"ok": False, "code": "practice_host_output_outside_repo"}
    target_dir.mkdir(parents=True, exist_ok=True)
    host_path = TOOLS_DIR / "practice_host.py"
    arguments = [
        f'--staging-root "{config.staging_root}"',
        f'--backup-root "{config.backup_root}"',
        f'--install "{config.live_install_root}"',
        f'--appdata "{config.live_appdata_root}"',
        f'--steam-root "{config.steam_root}"',
        f'--server-root "{config.server_root}"',
    ]
    if config.match_port:
        arguments.append(f"--match-port {int(config.match_port)}")
    invocation = f'"{sys.executable}" "{host_path}" serve'
    cmd_lines = [invocation] + [f"  {item}" for item in arguments]
    cmd = "@echo off\r\nsetlocal\r\n" + " ^\r\n".join(cmd_lines) + "\r\n"
    ps1 = (
        "$Host.UI.RawUI.WindowTitle = 'AI Sparring practice host'\r\n"
        f"& {invocation} " + " ".join(arguments) + "\r\n"
    )
    cmd_path = target_dir / "start_practice_host.cmd"
    ps1_path = target_dir / "start_practice_host.ps1"
    cmd_path.write_text(cmd, encoding="utf-8")
    ps1_path.write_text(ps1, encoding="utf-8")
    return {
        "ok": True,
        "code": CODE_OK,
        "directory": str(target_dir),
        "scripts": [str(cmd_path), str(ps1_path)],
        "note": "developer scripts only; no registry entries or scheduled tasks are created",
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="practice_host",
        description="External local practice host daemon and closed-game match supervisor.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--repo", default=str(REPO_DIR))
        p.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
        p.add_argument("--backup-root", default=str(staging.DEFAULT_BACKUP_ROOT))
        p.add_argument("--install", default=str(staging.DEFAULT_INSTALL))
        p.add_argument("--appdata", default=None)
        p.add_argument("--steam-root", default=None)
        p.add_argument("--server-root", default=None)
        p.add_argument("--match-port", type=int, default=None)
        p.add_argument("--node", default="node")
        p.add_argument("--live-exit-timeout", type=float, default=DEFAULT_LIVE_EXIT_TIMEOUT)

    serve = sub.add_parser("serve", help="run the external host daemon until interrupted")
    common(serve)
    status = sub.add_parser("status", help="report discovery/daemon state (read-only)")
    common(status)
    dev = sub.add_parser("dev-launcher", help="generate developer start scripts under repo work/")
    common(dev)
    dev.add_argument("--output", default=None)

    return parser


def config_from_args(args) -> HostConfig:
    overrides = dict(
        staging_root=Path(args.staging_root),
        backup_root=Path(args.backup_root),
        live_install_root=Path(args.install),
        live_appdata_root=Path(args.appdata) if args.appdata else Path(staging.default_live_appdata()),
        steam_root=Path(args.steam_root) if args.steam_root else Path(staging.STEAM_ROOT_DEFAULT),
        server_root=Path(args.server_root) if args.server_root else Path(args.repo) / "work" / "local-server",
        server_manifest=(Path(args.server_root) if args.server_root else Path(args.repo) / "work" / "local-server")
        / "AISparring-adaptation.json",
        node_executable=args.node,
        match_port=args.match_port,
        live_exit_timeout=args.live_exit_timeout,
        work_dir=Path(args.repo) / "work" / "aisparring-host",
        session_root=Path(args.repo) / "work" / "aisparring-host" / "sessions",
    )
    return default_config(repo_root=args.repo, **overrides)


def _emit(payload: Mapping) -> None:
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    config = config_from_args(args)
    if args.command == "dev-launcher":
        output = generate_developer_launcher(config, directory=args.output)
        _emit(output)
        return 0 if output["ok"] else 3
    if args.command == "status":
        state = discovery_state(config)
        _emit(
            {
                "schema": DISCOVERY_SCHEMA,
                "state": state,
                "module_sha256": module_sha256(),
                "discovery": str(config.resolved_discovery_path()),
            }
        )
        return 0
    if args.command == "serve":
        if config.require_fixed_match_port and config.match_port is None:
            # M-3: never start a daemon whose every acknowledgement would fail after
            # the user has already quit Balatro for a fixed, unconfigured port.
            _emit({"ok": False, "code": CODE_MATCH_PORT_UNCONFIGURED})
            return 3
        daemon = HostDaemon(config)
        result = daemon.start()
        _emit(result)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
        finally:
            # Defer shutdown while a retained staged human window is still open:
            # closing the daemon would close its kill-on-close Job Object.
            stop = daemon.stop()
            while not stop.get("stopped"):
                _emit(stop)
                time.sleep(2.0)
                stop = daemon.stop()
        return 0
    _emit({"ok": False, "code": CODE_BAD_REQUEST})
    return 2


__all__ = [
    "HostConfig",
    "HostDaemon",
    "HostError",
    "MatchSupervisor",
    "MatchTicket",
    "SessionWorkspace",
    "VERSION",
    "ATTESTATION_NAME",
    "ATTESTATION_SCHEMA",
    "attestation_path",
    "certificate_content_hash",
    "certificate_gate",
    "certificate_open_records",
    "check_quiescence",
    "choose_match_port",
    "clear_host_lockout",
    "create_session_workspace",
    "default_config",
    "default_runtime_checker",
    "default_server_runner",
    "default_start_gate",
    "discovery_state",
    "fresh_backup_baseline",
    "generate_developer_launcher",
    "host_lockout_path",
    "is_loopback_address",
    "measurement_api_problems",
    "mint_session_id",
    "module_sha256",
    "prepare_live_baseline",
    "read_discovery",
    "read_host_lockout",
    "rotate_role_attestations",
    "runtime_preflight",
    "server_environment",
    "set_host_lockout",
    "static_isolation_gates",
    "verify_local_listener",
    "verify_live_target",
    "verify_server_adaptation",
    "wait_for_attestation",
    "wait_for_live_exit",
    "write_discovery",
    "write_role_attestations",
]


if __name__ == "__main__":
    sys.exit(main())
