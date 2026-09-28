#!/usr/bin/env python3
"""Fail-closed local staging for the two-role Balatro AI Sparring topology.

Staging only. This module never launches a game, never writes to the live Balatro
installation, never writes to the live %AppData%\\Balatro tree and never kills a
process. It builds two role-separated staged trees (``human`` and ``ai``), writes
a loopback-only Multiplayer endpoint into the *discovered* Multiplayer mod, applies
deterministic staged-only suppressions to network-capable mods (Handy updater,
SMODS HTTPS and the SMODS debug socket), records explicit content/version manifests
and produces the measured facts the runtime isolation report cites.

Isolation is treated as *measured*, never self-attested:

* ``role_environment`` builds a child environment from an allowlist with an explicit
  ``LOVELY_MOD_DIR`` and ``APPDATA`` inside the role root, so no inherited
  Steam/SDL/LOVELY/Python variable can redirect the staged process at the live tree.
* ``check_bootstrap_preflight`` is the PRE-run gate (manifest, patch binding, absent
  stale probes, no native Steam DLLs, correct paths).
* ``check_bootstrap_evidence`` is the POST-run gate and requires an exact per-run
  nonce and a spawn time, parsed probe-by-probe; substring checks never pass.
* ``measure_isolation_state`` / ``record_isolation_proof`` write the measured
  per-session ``isolation_proof.json``; caller ``extra`` is isolated under a
  ``metadata`` key so it can never overwrite a measured gate field.
* ``check_isolation_proof`` is the host-facing wrapper for the reusable two-layer
  isolation certificate implemented in ``tools/isolation_certificate.py``. The
  certificate binds the staged native layer (N) and Mods layer (M), every
  isolation-critical tool hash, the endpoint and the live-root paths; a live
  content change never falsifies it, and per-session live byte diff is recorded
  separately (``snapshot_live`` / ``prepare_session`` / ``record_session_verdict``).
* ``check_steam_guard`` is a *static* staged guard: it binds the staged patch hash
  and requires the nonce-bound ``steam_patch_applied`` marker plus both Steam probes.
  It never reads the mutable ``isolation_proof.json``. The fresh real-probe checker
  is ``check_steam_probes``; the immutable certificate remains the launch gate.
* ``collect_role_probes`` requires the post-Steam-block probe (real ``G.STEAM`` and
  ``package.loaded.luasteam``) and the nonce-bound patch-applied marker, so a
  pre-``G:start_up()`` ``steam=nil`` echo can no longer pass.
* ``check_lovely_evidence`` binds the exact staged ``Mods`` path and a *fresh* log
  and ``main.lua`` dump under ``Mods/lovely/{log,dump}`` (NH1/NM8).

Nothing in this module proves native save, Mods, Lovely or Steam isolation on its
own. The default launch gate stays closed until the certificate described in
docs/RUNTIME_ISOLATION.md is complete.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STAGING_ROOT = REPO_ROOT / "staging"
DEFAULT_BACKUP_ROOT = REPO_ROOT / "backups"
DEFAULT_INSTALL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Balatro")
DEFAULT_STEAM_APPMANIFEST_NAME = "appmanifest_2379780.acf"

ROLES = ("human", "ai")
BOOTSTRAP_ROLE = "bootstrap"
EXECUTOR_RUNTIME_ROLE = "ai_staged"
LAUNCH_ROLES = ("human", "ai")
MANIFEST_NAME = "staging_manifest.json"
ENV_NAME = ".env"
EVIDENCE_NAME = "isolation_proof.json"
STEAM_GUARD_META_NAME = "steam_guard.json"
BOOTSTRAP_EXPECTED_NAME = "bootstrap_expected.json"

PATCH_ID = "aisparring-staging-v1"
PATCH_MOD_ROLE = "aisparring-staging"
PATCH_MOD_BOOTSTRAP = "aisparring-bootstrap"
PROBE_MAIN = "aisparring_probe_main.txt"
PROBE_GUARD = "aisparring_probe_guard.txt"
PROBE_SAVE_THREAD = "aisparring_probe_save_thread.txt"
PROBE_MP = "aisparring_probe_mp.txt"
# NH1: the old guard probe ran *before* ``G:start_up()``, so ``G.STEAM`` was always
# nil there. Steam absence is now proven by (a) a nonce-bound patch-applied marker
# written by the Steam-disable payload and (b) a post-Steam-block probe placed just
# before ``love.mouse.setVisible(false)`` that records the real ``G.STEAM`` and
# ``package.loaded.luasteam`` values.
PROBE_STEAM_MARKER = "aisparring_probe_steam_marker.txt"
PROBE_STEAM_POST = "aisparring_probe_steam_post.txt"
# Measurement-only P2 dead-port instrumentation artifact. It is written from the
# *real staged network thread* (Multiplayer ``networking/socket.lua``) immediately
# after each actual ``Networking.Client:connect`` returns, and copied immutably into
# the phase receipt. The tool never accepts a caller-supplied attempt count, and a
# startup/``started`` marker is never a substitute for these observed fields.
PROBE_P2 = "aisparring_probe_p2.txt"
# N2: a nonce-bound crash probe written by the wrapper around the *active* original
# error handler (``love.errorhandler`` or ``love.errhand``) before it chains to that
# handler. A nonzero exit alone is never a crash; only this fresh probe is.
PROBE_CRASH = "aisparring_probe_crash.txt"
# Section 4: the tool-owned measurement listener log (immutable, hashed receipt
# artifact). It is written by the tool before the phase receipt is recorded, in the
# same key=value probe shape so it flows through the existing immutable evidence
# pipeline and nonce binding.
PROBE_LISTENER = "aisparring_probe_listener.txt"
LISTENER_SCHEMA = "aisparring.measurement_listener.v1"
# Bounded retention for the measurement listener: it never sends a byte and keeps at
# most this many received bytes (anything past it is discarded, only the byte count
# and digest of the retained prefix are recorded). Parsing of the JSON ``action``
# names is likewise bounded so a hostile/garbage peer cannot exhaust memory.
LISTENER_MAX_RECEIVED_BYTES = 65536
LISTENER_MAX_ACTIONS = 64
LISTENER_MAX_ACTION_NAME = 64
# Exact artifact schema emitted by the env-gated source observer. The receipt
# classifier binds to these exact fields; no hypothetical future flags are read.
P2_OBSERVER_SCHEMA = "aisparring.p2_observer.v1"
# Measurement-only env gates. They are set by the tool launcher for the CRASH and
# P2 phases only and can never change normal MATCH runtime behavior.
MEASURE_CRASH_ENV = "AISP_MEASURE_CRASH"
MEASURE_P2_ENV = "AISP_MEASURE_P2"
# Tool-owned measurement end modes/codes (section 4; N2/N3). Each measurement run
# is ended by the tool once its required evidence has settled, with a distinct code
# that is never 0 (a clean self-exit) and never 1 (the TerminateJobObject default),
# so a recorded end can never be confused with a crash or a natural exit.
MEASUREMENT_END_MODE = "tool_owned_end"
MEASUREMENT_END_CODES = {
    "CRASH": 101,
    "P1B": 102,
    "FULL_P1": 103,
    "P2_INITIAL": 104,
    "P2_CLOSE": 105,
    "P2_SILENT": 106,
}
MEASUREMENT_END_CODE_VALUES = frozenset(MEASUREMENT_END_CODES.values())
MEASUREMENT_CRASH_STIMULUS = "env_gated_guard_error"
# Hard deadline for any tool-owned measurement run: exceeding it is a failure and
# raises the persistent lockout (never a silent success).
MEASUREMENT_DEADLINE_SECONDS = 240.0
# Pinned Multiplayer source the P2 observer binds to. ``MP.load_mp_file`` returns
# the network-thread long string, so a pattern insertion after this exact call runs
# inside the real thread (not the UI/main thread).
#
# N1: Lovely matches each *whole trimmed line* against the pattern with ``*``/``?``
# wildcards. Every anchor below is therefore the exact full trimmed pinned line, so
# it applies identically under a literal-substring or a Lovely wildcard rule (see
# ``_lovely_line_match`` / ``apply_source_pattern_patch``). A fragment anchor is
# refused by design.
MP_SOCKET_CONNECT_LITERAL = (
    "local connectionResult, errorMessage = Networking.Client:connect(CONFIG_URL, CONFIG_PORT)"
    " -- Not sure if I want to make these values public yet"
)
MP_SOCKET_SOURCE_TARGET = '=[SMODS Multiplayer "networking/socket.lua"]'
MP_SOCKET_SOURCE_REL = ("networking", "socket.lua")
MP_SOCKET_REQUIRE_LITERAL = 'local socket = require("socket")'
MP_RECONNECT_START_LITERAL = 'SEND_THREAD_DEBUG_MESSAGE("Connection lost, attempting automatic reconnection...")'
MP_RECONNECT_OK_LITERAL = 'SEND_THREAD_DEBUG_MESSAGE("Reconnected successfully!")'
MP_RECONNECT_FAIL_LITERAL = 'SEND_THREAD_DEBUG_MESSAGE("All reconnection attempts failed.")'
MP_CLOSE_COMMENT_LITERAL = "-- Connection closed, attempt automatic reconnection"
MP_KEEPALIVE_COMMENT_LITERAL = "-- Keepalive failed, attempt automatic reconnection"
# Section 4 observer additions: the pinned receive and keepalive-push lines.
MP_RECEIVE_LITERAL = "local data, error, partial = Networking.Client:receive()"
MP_KEEPALIVE_PUSH_LITERAL = r'uiToNetworkChannel:push("{\"action\":\"keepAlive\"}")'
# N1/section 4: one unique marker comment is emitted by each observer payload. The
# runtime MP guard requires *all* of them in the loaded network-thread string, and
# the receipt requires all of them in Lovely's patched socket dump, so a partially
# applied observer can never pass.
P2_PAYLOAD_MARKERS = (
    "AISP_P2_STATE",
    "AISP_P2_CONNECT",
    "AISP_P2_RECONNECT_START",
    "AISP_P2_RECONNECT_OK",
    "AISP_P2_RECONNECT_FAIL",
    "AISP_P2_CLOSE",
    "AISP_P2_KEEPALIVE",
    "AISP_P2_RECV",
    "AISP_P2_KEEPALIVE_PUSH",
    # F2: a tenth env-gated marker stamped *before* the pinned connect call so the
    # retry-gap measurement uses each attempt's start (previous attempt end -> next
    # attempt start) instead of the connect duration being folded into the sleep.
    "AISP_P2_CONNECT_BEFORE",
)

PROOF_SCHEMA = "aisparring.isolation_proof.v2"
MEASURE_SCHEMA = "aisparring.isolation_measure.v1"
SUPPRESSION_SCHEMA = "aisparring.network_suppression.v1"
PROBE_NONCE_VAR = "AISP_PROBE_NONCE"
# Canonical session-descriptor env names, frozen to the typed launcher descriptor
# (docs/PLAYABLE_WIRING_CONTRACT.md). Mirrors launch_practice.SESSION_ENV_KEYS
# exactly; no speculative aliases. The certificate binds these names.
SESSION_DESCRIPTOR_VARS = (
    "AISP_SESSION_ID",
    "AISP_ROLE_CREDENTIAL",
    "AISP_CONTROL_PORT",
    "AISP_CONTENT_HASH",
    "AISP_PROBE_NONCE",
    "AISP_EXPECTED_ROLE_SAVE_ROOT",
    "AISP_EXPECTED_ROLE_MODS_ROOT",
    "AISP_MODE",
    "AISP_DIFFICULTY",
    "AISP_PACING",
    "AISP_GAUNTLET",
)
LAUNCHER_ATTESTATION_NAME = "aisparring-launcher-attestation.json"
LAUNCHER_ATTESTATION_SCHEMA = "aisparring.launcher_attestation.v1"
# Names the certificate must never accept as bound session-descriptor aliases.
FORBIDDEN_ENV_ALIASES = (
    "AISP_ROLE",
    "AISP_EXPECTED_SAVE_DIR",
    "AISP_EXPECTED_MODS_ROOT",
    "AISP_EXPECTED_MOD_ROOT",
    "AISP_SEED",
)

START_TIME_TOLERANCE = 2.0
REPARSE_POINT_FLAG = 0x400

MODS_REL_PREFIX = "appdata/Roaming/Balatro/Mods"
# NM8: exact staged Lovely artefacts (never "anywhere under the role root").
LOVELY_DIR_NAME = "lovely"
LOVELY_LOG_DIR_NAME = "log"
LOVELY_DUMP_DIR_NAME = "dump"
# Official Lovely v0.10.0 (lib.rs:308-331) writes the *patched* buffer under
# ``lovely/dump/<pretty_name>`` and the unpatched buffer under
# ``lovely/game-dump/<pretty_name>``. ``=[SMODS Multiplayer "networking/socket.lua"]``
# becomes the pretty name ``SMODS/Multiplayer/networking/socket.lua``. Evidence must
# bind these exact patched relative paths, never any same-basename file.
MP_SOCKET_DUMP_REL = "SMODS/Multiplayer/networking/socket.lua"
LOVELY_PATCHED_MAIN_REL = "main.lua"


def lovely_patched_dump_rel(pretty_name: str) -> str:
    """The exact staged rel path of one Lovely *patched* dump (not game-dump)."""
    return f"{LOVELY_DIR_NAME}/{LOVELY_DUMP_DIR_NAME}/{pretty_name.replace(chr(92), '/').lstrip('/')}"

STEAM_NATIVE_FILES = frozenset(
    name.lower()
    for name in (
        "steam_api.dll",
        "steam_api64.dll",
        "luasteam.dll",
        "steamclient.dll",
        "steamclient64.dll",
    )
)

COPY_EXCLUDE_DIRNAMES = frozenset(
    name.lower()
    for name in (
        "mods",
        "save",
        "saves",
        "steamapps",
        "staging",
        "backups",
        "work",
        "node_modules",
        ".git",
        "__pycache__",
    )
)

RUNTIME_STATE_SUFFIXES = (".jkr", ".log", ".sqlite", ".sqlite3")
RUNTIME_STATE_NAMES = frozenset(name.lower() for name in (".env",))

ENV_LINE_RE = re.compile(r"^([A-Za-z0-9_]+)\s*=\s*(.+)$")
CONFIG_URL_RE = re.compile(r"\[?['\"]?server_url['\"]?\]?\s*=\s*['\"]([^'\"]+)['\"]")
CONFIG_PORT_RE = re.compile(r"\[?['\"]?server_port['\"]?\]?\s*=\s*([0-9]+)")
APPMANIFEST_RE_PAIR = re.compile(r'"([^"]+)"\s+"([^"]*)"')

STEAM_ROOT_DEFAULT = DEFAULT_INSTALL.parent.parent.parent
STEAM_USERDATA_DEFAULT = STEAM_ROOT_DEFAULT / "userdata"
STEAM_APPID = "2379780"
REFERENCE_GAME_DIR = REPO_ROOT / "work" / "reference" / "game"
# Pinned upstream Multiplayer socket source, used by the source-observer tests to
# prove the generated patch applies to the real thread text. Absent on a clean
# checkout (``work/`` is never committed); tests skip when it is missing.
REFERENCE_MP_SOCKET = REPO_ROOT / "work" / "reference" / "mp" / "networking" / "socket.lua"
LOVELY_PATCH_PRIORITY = 2147483600
LOVELY_MANIFEST_VERSION = "1.0.0"

ALLOWED_ENV_KEYS = frozenset(
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
        "PROCESSOR_LEVEL",
        "PROCESSOR_REVISION",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TZ",
        "HOME",
        "HOMEDRIVE",
        "HOMEPATH",
        "USERNAME",
        "USERDOMAIN",
    )
)

NETWORK_SUPPRESSION_MARKER = "-- AISparring staging suppression:"

STEAM_BLOCK_PATTERN = r"local os = love\.system\.getOS\(\)[\s\S]*?G\.STEAM = st[\s]*else[\s]*end"
CRASH_REPORT_PATTERN = r"if G\.SETTINGS\.crashreports and _RELEASE_MODE and G\.F_CRASH_REPORTS then"
START_UP_LITERAL = "G:start_up()"
LOVE_LOAD_END_LITERAL = "love.mouse.setVisible(false)"
SAVE_THREAD_LITERAL = 'CHANNEL = love.thread.getChannel("save_request")'
MP_THREAD_START_LITERAL = "MP.NETWORKING_THREAD:start(server_url, server_port)"
SMODS_DEBUG_SOCKET_LITERAL = 'tcp:connect("localhost", 53153)'
HANDY_UPDATER_START_RE = re.compile(
    r"local\s+https_updater_thread\s*=[\s\S]*?https_updater_thread:start\(\)"
)

# NM4: fail closed on *content*, not on a mod folder name. Each rule is satisfied
# when its suppression marker is present (staged-only suppression applied) or when
# the live network pattern is absent. A live pattern without its marker is refused.
SMODS_HTTPS_PATTERN = re.compile(
    r"\bM\.asyncRequest\b"
    r"|function\s+M\.request\b"
    r"|M\.request\s*=\s*function"
    r"|pcall\s*\(\s*require\s*,\s*[\"']https[\"']"
    r"|require\s*\(\s*[\"']luajit-curl[\"']"
)
SMODS_DEBUG_SOCKET_PATTERN = re.compile(
    r"tcp\s*:\s*connect\s*\(\s*[\"']localhost[\"']\s*,\s*53153\s*\)"
)
HANDY_UPDATER_START_PATTERN = re.compile(r"https_updater_thread\s*:\s*start\s*\(\s*\)")

NETWORK_SUPPRESSION_RULES = (
    {"id": "handy_updater", "marker": "handy_updater", "pattern": HANDY_UPDATER_START_PATTERN},
    {"id": "smods_debug_socket", "marker": "smods_debug_socket", "pattern": SMODS_DEBUG_SOCKET_PATTERN},
    {"id": "smods_https", "marker": "smods_https", "pattern": SMODS_HTTPS_PATTERN},
)
# Known network-capable mod manifest ids (matched case-insensitively) and the
# suppression rule each must carry, independent of the folder name.
KNOWN_NETWORK_MOD_IDS = {
    "handy": ("handy_updater",),
    "steamodded": ("smods_https", "smods_debug_socket"),
    "smods": ("smods_https", "smods_debug_socket"),
}


class StagingError(Exception):
    """Typed staging failure. ``code`` is stable and safe to log."""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message or code


def runtime_role(role: str) -> str:
    """Source role names stay human/ai; the AI executor runs as ``ai_staged``."""
    return EXECUTOR_RUNTIME_ROLE if role == "ai" else role


def _norm_path(value) -> str:
    return str(value).replace("\\", "/").rstrip("/").lower()


def _tree_digest(root, policy: Optional["HashPolicy"] = None) -> Optional[str]:
    root = Path(root)
    if not root.is_dir():
        return None
    files = hash_tree(root, policy)
    payload = json.dumps(files, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _digest_of(value) -> Optional[str]:
    if value is None:
        return None
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def known_folder_roaming_appdata() -> Optional[Path]:
    """Resolve %AppData% via the Windows known-folder API, not a child APPDATA var."""
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        class _GUID(ctypes.Structure):
            _fields_ = [
                ("Data1", ctypes.c_uint32),
                ("Data2", ctypes.c_uint16),
                ("Data3", ctypes.c_uint16),
                ("Data4", ctypes.c_ubyte * 8),
            ]

        guid = _GUID(
            0x3EB685DB,
            0x65F9,
            0x4CF6,
            (ctypes.c_ubyte * 8)(0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D),
        )
        shell32 = ctypes.WinDLL("shell32", use_last_error=True)
        ole32 = ctypes.WinDLL("ole32", use_last_error=True)
        shell32.SHGetKnownFolderPath.restype = ctypes.c_long
        shell32.SHGetKnownFolderPath.argtypes = [
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_wchar_p),
        ]
        ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]
        ptr = ctypes.c_wchar_p()
        result = shell32.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(ptr))
        if result != 0 or not ptr.value:
            return None
        try:
            return Path(ptr.value)
        finally:
            ole32.CoTaskMemFree(ptr)
    except Exception:
        return None


def default_live_appdata() -> Path:
    """Live ``%AppData%\\Balatro``, independent of a potentially redirected APPDATA."""
    known = known_folder_roaming_appdata()
    if known is not None:
        return known / "Balatro"
    root = os.environ.get("APPDATA") or os.environ.get("appdata")
    return (Path(root) / "Balatro") if root else (Path.home() / "AppData" / "Roaming" / "Balatro")


def find_steam_userdata_apps(steam_root=None, appid: str = STEAM_APPID) -> list:
    """Every Steam profile that contains the Balatro app dir, not just the first."""
    base = Path(steam_root or STEAM_ROOT_DEFAULT)
    userdata = base if base.name.lower() == "userdata" else base / "userdata"
    if not userdata.is_dir():
        return []
    found: list = []
    for child in sorted(userdata.iterdir()):
        if not child.is_dir():
            continue
        app = child / appid
        if app.is_dir():
            found.append(app)
    return found


def find_steam_userdata_app(steam_root=None, appid: str = STEAM_APPID) -> Optional[Path]:
    apps = find_steam_userdata_apps(steam_root, appid)
    return apps[0] if apps else None


def discover_steam_libraries(steam_root=None) -> list:
    """Custom Steam library roots from ``libraryfolders.vdf`` plus the default root."""
    root = Path(steam_root or STEAM_ROOT_DEFAULT)
    libraries: list = []
    default_steamapps = root / "steamapps"
    if default_steamapps.is_dir():
        libraries.append(root)
    vdf = default_steamapps / "libraryfolders.vdf"
    if vdf.is_file():
        try:
            text = vdf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        for match in re.finditer(r'"path"\s+"([^"]+)"', text):
            candidate = Path(match.group(1).replace("\\\\", "\\"))
            if candidate.is_dir() and candidate not in libraries:
                libraries.append(candidate)
    return libraries


def steamapps_parent(install_root) -> Optional[Path]:
    """The ``steamapps`` dir only when the install really is ``<root>/steamapps/common/<game>``.

    An explicit custom install (or a temp test install) must not be broadened to an
    inferred Steam parent: that would protect an unrelated parent directory and
    reject valid staging siblings. The explicit ``steam_root`` is protected on its own.
    """
    install = Path(install_root)
    parent = install.parent
    if parent.name.lower() == "common" and parent.parent.name.lower() == "steamapps":
        return parent.parent
    return None


def live_roots(
    install_root=None,
    appdata_root=None,
    steam_root=None,
    steam_userdata_root=None,
    custom_roots=None,
) -> dict:
    install = Path(install_root or DEFAULT_INSTALL)
    steam = Path(steam_root or STEAM_ROOT_DEFAULT)
    roots = {
        "install": install,
        "appdata": Path(appdata_root or default_live_appdata()),
        "steam_root": steam,
    }
    inferred_steamapps = steamapps_parent(install)
    if inferred_steamapps is not None:
        roots["install_steamapps"] = inferred_steamapps
    apps = find_steam_userdata_apps(steam)
    if steam_userdata_root is not None:
        roots["steam_userdata"] = Path(steam_userdata_root)
    elif apps:
        roots["steam_userdata"] = apps[0]
    else:
        roots["steam_userdata"] = steam / "userdata"
    for app in apps:
        roots[f"steam_userdata/{app.parent.name}"] = app
    for index, library in enumerate(discover_steam_libraries(steam)):
        roots[f"steam_library_{index}_steamapps"] = library / "steamapps"
    for index, extra in enumerate(custom_roots or ()):
        roots[f"custom_{index}"] = Path(extra)
    return roots


def assert_no_overlap(staging_root, roots=None) -> None:
    staging_resolved = Path(staging_root).resolve()
    for name, live in (roots or live_roots()).items():
        live_resolved = Path(live).resolve()
        if is_within(live_resolved, staging_resolved, allow_root=True) or is_within(
            staging_resolved, live_resolved, allow_root=True
        ):
            raise StagingError("staging_overlaps_live", f"{staging_resolved} overlaps {name} {live_resolved}")


def find_links(root) -> list:
    """Return symlink / junction / reparse-point paths under root (never followed)."""
    root = Path(root)
    found: list = []
    if not root.is_dir():
        return found
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)
        for name in sorted(dirnames + filenames):
            full = base / name
            try:
                stat = os.lstat(full)
            except OSError:
                continue
            attributes = getattr(stat, "st_file_attributes", 0)
            if full.is_symlink() or (attributes & REPARSE_POINT_FLAG):
                found.append(str(full))
    return found


def assert_no_links(root, what: str = "tree") -> None:
    links = find_links(root)
    if links:
        raise StagingError("link_or_junction_refused", f"{what} contains links: {links[0]}")


def sha256_file(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_within(root, candidate, allow_root: bool = False) -> bool:
    """True when ``candidate`` resolves inside ``root`` and not outside via ``..``.

    Compares normalised absolute paths, so a sibling whose name merely starts
    with the root name (``root`` vs ``rootx``) is rejected.
    """
    try:
        root_r = Path(root).resolve()
        cand_r = Path(candidate).resolve()
    except OSError:
        return False
    try:
        common = os.path.commonpath([str(root_r), str(cand_r)])
    except ValueError:
        return False
    if os.path.normcase(common) != os.path.normcase(str(root_r)):
        return False
    if not allow_root and os.path.normcase(str(cand_r)) == os.path.normcase(str(root_r)):
        return False
    return True


def assert_within(root, candidate, what: str = "path", allow_root: bool = False) -> Path:
    resolved = Path(candidate).resolve()
    if not is_within(root, resolved, allow_root=allow_root):
        raise StagingError("path_escape", f"{what} escapes staging root: {resolved}")
    return resolved


def _lexical_within(root, candidate) -> bool:
    """Containment on the *unresolved* absolute paths, before any symlink following."""
    root_abs = os.path.abspath(str(root))
    cand_abs = os.path.abspath(str(candidate))
    try:
        common = os.path.commonpath([root_abs, cand_abs])
    except ValueError:
        return False
    return os.path.normcase(common) == os.path.normcase(root_abs)


def assert_no_reparse_between(root, candidate, what: str = "path", allow_root: bool = False) -> Path:
    """Refuse a write when any lexical component (root included) is a link/reparse point.

    This runs *before* ``.resolve()`` so a junction that could redirect a staged write
    into the live tree is reported as junction evidence instead of being silently
    followed. Root containment is also checked lexically first.
    """
    root_abs = Path(os.path.abspath(str(root)))
    cand_abs = Path(os.path.abspath(str(candidate)))
    if not _lexical_within(root_abs, cand_abs):
        raise StagingError("path_escape", f"{what} escapes staging root: {cand_abs}")
    same = os.path.normcase(str(cand_abs)) == os.path.normcase(str(root_abs))
    if same and not allow_root:
        raise StagingError("path_escape", f"{what} escapes staging root: {cand_abs}")
    components = [root_abs]
    if not same:
        try:
            parts = cand_abs.relative_to(root_abs).parts
        except ValueError:
            raise StagingError("path_escape", f"{what} escapes staging root: {cand_abs}")
        current = root_abs
        for part in parts:
            current = current / part
            components.append(current)
    for target in components:
        try:
            stat = os.lstat(target)
        except OSError:
            break
        attributes = getattr(stat, "st_file_attributes", 0)
        if Path(target).is_symlink() or (attributes & REPARSE_POINT_FLAG):
            raise StagingError("link_or_junction_refused", f"{what} contains a link: {target}")
    return cand_abs


def assert_safe_write(staging_root, path, what: str = "staged write", allow_root: bool = False) -> Path:
    """Junction/reparse + escape check that must pass before every staged write/copy."""
    assert_no_reparse_between(staging_root, path, what=what, allow_root=allow_root)
    return assert_within(staging_root, path, what=what, allow_root=allow_root)


def _ensure_dir(staging_root, directory, allow_root: bool = False) -> Path:
    resolved = assert_safe_write(staging_root, directory, allow_root=allow_root)
    resolved.mkdir(parents=True, exist_ok=True)
    return resolved


def _write_text(staging_root, path, text: str) -> Path:
    resolved = assert_safe_write(staging_root, path)
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_text(text, encoding="utf-8")
    return resolved


@dataclass(frozen=True)
class HashPolicy:
    exclude_rel: tuple = ()
    exclude_dirnames: tuple = ()
    exclude_names: tuple = ()
    exclude_rel_prefixes: tuple = ()
    include_rel_prefixes: tuple = ()

    def to_dict(self) -> dict:
        return {
            "exclude_rel": list(self.exclude_rel),
            "exclude_dirnames": list(self.exclude_dirnames),
            "exclude_names": list(self.exclude_names),
            "exclude_rel_prefixes": list(self.exclude_rel_prefixes),
            "include_rel_prefixes": list(self.include_rel_prefixes),
        }


def policy_from_dict(data: Mapping) -> HashPolicy:
    return HashPolicy(
        exclude_rel=tuple(data.get("exclude_rel") or ()),
        exclude_dirnames=tuple(data.get("exclude_dirnames") or ()),
        exclude_names=tuple(data.get("exclude_names") or ()),
        exclude_rel_prefixes=tuple(data.get("exclude_rel_prefixes") or ()),
        include_rel_prefixes=tuple(data.get("include_rel_prefixes") or ()),
    )


def _under_any(rel: str, prefixes: Sequence[str]) -> bool:
    return any(rel == prefix or rel.startswith(prefix + "/") for prefix in prefixes)


def _related_to_any(rel: str, prefixes: Sequence[str]) -> bool:
    return any(
        rel == prefix or rel.startswith(prefix + "/") or prefix.startswith(rel + "/")
        for prefix in prefixes
    )


STAGING_POLICY = HashPolicy(
    include_rel_prefixes=("install", MODS_REL_PREFIX, "steam_guard"),
    exclude_rel_prefixes=(f"{MODS_REL_PREFIX}/lovely/log", f"{MODS_REL_PREFIX}/lovely/dump"),
    exclude_names=(MANIFEST_NAME,),
)
BOOTSTRAP_POLICY = HashPolicy(
    include_rel_prefixes=("install", MODS_REL_PREFIX, "steam_guard", BOOTSTRAP_EXPECTED_NAME),
    exclude_rel_prefixes=(f"{MODS_REL_PREFIX}/lovely/log", f"{MODS_REL_PREFIX}/lovely/dump"),
    exclude_names=(MANIFEST_NAME,),
)
BACKUP_POLICY = HashPolicy()
INSTALL_HASH_POLICY = HashPolicy(exclude_names=(MANIFEST_NAME,))
MODS_HASH_POLICY = HashPolicy(exclude_rel_prefixes=("lovely/log", "lovely/dump"))


def _is_reparse_point(path) -> bool:
    """True for a symlink, junction or any other NTFS reparse point."""
    try:
        stat = os.lstat(path)
    except OSError:
        return False
    attributes = getattr(stat, "st_file_attributes", 0)
    return bool(attributes & REPARSE_POINT_FLAG) or os.path.islink(path)


def hash_tree(root, policy: Optional[HashPolicy] = None) -> dict:
    """Hash a tree, failing closed on any link/junction or unreadable entry.

    Low finding: the old walk descended into junctioned directories and silently
    skipped files whose ``stat`` failed. Both are now refusals, so a redirected or
    unreadable subtree can never be hashed as if it were the staged tree.
    """
    root = Path(root)
    if not root.is_dir():
        raise StagingError("hash_root_missing", str(root))
    policy = policy or HashPolicy()
    exclude_dirnames = {name.lower() for name in policy.exclude_dirnames}
    exclude_names = {name.lower() for name in policy.exclude_names}
    exclude_rel = set(policy.exclude_rel)
    exclude_prefixes = tuple(str(item).strip("/") for item in policy.exclude_rel_prefixes)
    include_prefixes = tuple(str(item).strip("/") for item in policy.include_rel_prefixes)
    files: dict = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)
        rel_dir = "" if base == root else base.relative_to(root).as_posix()
        kept: list = []
        for name in sorted(dirnames):
            full = base / name
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if _is_reparse_point(full):
                raise StagingError("hash_reparse_refused", rel)
            if name.lower() in exclude_dirnames:
                continue
            if exclude_prefixes and _under_any(rel, exclude_prefixes):
                continue
            if include_prefixes and not _related_to_any(rel, include_prefixes):
                continue
            kept.append(name)
        dirnames[:] = kept
        for name in sorted(filenames):
            full = base / name
            rel = full.relative_to(root).as_posix()
            if _is_reparse_point(full):
                raise StagingError("hash_reparse_refused", rel)
            if rel in exclude_rel or name.lower() in exclude_names:
                continue
            if exclude_prefixes and _under_any(rel, exclude_prefixes):
                continue
            if include_prefixes and not _under_any(rel, include_prefixes):
                continue
            try:
                stat = full.stat()
            except OSError as error:
                raise StagingError("hash_stat_failed", f"{rel}: {error}")
            files[rel] = {"sha256": sha256_file(full), "size": stat.st_size}
    return dict(sorted(files.items()))


def build_manifest(root, policy: Optional[HashPolicy] = None, extra: Optional[Mapping] = None) -> dict:
    policy = policy or HashPolicy()
    manifest = {
        "schema": "aisparring.staging_manifest.v1",
        "root": str(Path(root).resolve()),
        "policy": policy.to_dict(),
        "files": hash_tree(root, policy),
    }
    if extra:
        for key, value in extra.items():
            manifest[key] = value
    return manifest


def write_json(path, data: Mapping, staging_root=None) -> Path:
    """Write JSON. Pass ``staging_root`` for any staged/backup write.

    Low finding: ``write_json`` bypassed the junction/escape check. When a
    ``staging_root`` is supplied the write goes through ``assert_safe_write``;
    callers that write outside a staging root keep the explicit raw behaviour.
    """
    target = Path(path)
    if staging_root is not None:
        target = assert_safe_write(staging_root, target, "json write")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")
    return target


def read_json(path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def verify_manifest(manifest: Mapping, root) -> dict:
    policy = policy_from_dict(manifest.get("policy") or {})
    expected = manifest.get("files") or {}
    current = hash_tree(root, policy)
    missing = sorted(set(expected) - set(current))
    added = sorted(set(current) - set(expected))
    changed = sorted(rel for rel in set(expected) & set(current) if expected[rel] != current[rel])
    return {
        "ok": not (missing or added or changed),
        "missing": missing,
        "added": added,
        "changed": changed,
        "count": len(expected),
    }


def parse_env(text: str) -> dict:
    """Mirror Multiplayer's trimmed-line / key matching semantics exactly.

    Source of truth: work/reference/mp/core.lua:78-94. Lines are trimmed, blank
    and ``#`` lines are skipped, keys match ``[A-Za-z0-9_]+`` (Lua ``%w_``),
    values require at least one character, ``true``/``false`` become booleans and
    duplicate keys keep the last value because assignment happens in order.
    """
    env: dict = {}
    for raw in text.splitlines():
        line = raw.strip()
        if line == "" or line.startswith("#"):
            continue
        match = ENV_LINE_RE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if value == "true":
            value = True
        elif value == "false":
            value = False
        env[key] = value
    return env


def render_env(host: str = "127.0.0.1", port: int = 8788) -> str:
    return (
        "# AISparring staging: loopback-only Multiplayer endpoint.\n"
        "# Written into a staged copy only; never into the live Mods tree.\n"
        f"server_url={host}\n"
        f"server_port={port}\n"
    )


def validate_local_endpoint(
    env: Mapping,
    host: str = "127.0.0.1",
    port: Optional[int] = None,
    port_min: int = 1024,
    port_max: int = 65535,
) -> dict:
    problems: list = []
    url = env.get("server_url")
    raw_port = env.get("server_port")
    if url != host:
        problems.append("server_url_not_exact_loopback")
    resolved_port: Optional[int] = None
    if raw_port is None or isinstance(raw_port, bool):
        problems.append("server_port_missing")
    else:
        try:
            resolved_port = int(str(raw_port).strip())
        except (TypeError, ValueError):
            problems.append("server_port_not_integer")
        else:
            if not (port_min <= resolved_port <= port_max):
                problems.append("server_port_out_of_range")
    if port is not None:
        if resolved_port is None:
            problems.append("server_port_unresolved")
        elif resolved_port != port:
            problems.append("server_port_mismatch")
    return {
        "ok": not problems,
        "problems": problems,
        "url": url,
        "port": resolved_port,
        "host": host,
    }


@dataclass(frozen=True)
class RolePaths:
    role: str
    root: Path
    install: Path
    data: Path
    local_appdata: Path
    userprofile: Path
    temp: Path
    mods: Path
    logs: Path
    ipc: Path

    def exe(self) -> Path:
        return self.install / "Balatro.exe"


def role_paths(staging_root, role: str) -> RolePaths:
    if role not in ROLES:
        raise StagingError("unknown_role", role)
    root = Path(staging_root).resolve() / "roles" / role
    data = root / "appdata" / "Roaming"
    return RolePaths(
        role=role,
        root=root,
        install=root / "install",
        data=data,
        local_appdata=root / "appdata" / "Local",
        userprofile=root / "userprofile",
        temp=root / "temp",
        mods=data / "Balatro" / "Mods",
        logs=root / "logs",
        ipc=root / "ipc",
    )


def bootstrap_paths(staging_root) -> RolePaths:
    root = Path(staging_root).resolve() / BOOTSTRAP_ROLE
    data = root / "appdata" / "Roaming"
    return RolePaths(
        role=BOOTSTRAP_ROLE,
        root=root,
        install=root / "install",
        data=data,
        local_appdata=root / "appdata" / "Local",
        userprofile=root / "userprofile",
        temp=root / "temp",
        mods=data / "Balatro" / "Mods",
        logs=root / "logs",
        ipc=root / "ipc",
    )


def _paths_for_role(staging_root, role: str) -> RolePaths:
    if role == BOOTSTRAP_ROLE:
        return bootstrap_paths(staging_root)
    return role_paths(staging_root, role)


def launcher_attestation_path(paths: RolePaths) -> Path:
    """Fixed session-bound host attestation path, outside the Mods/code manifests."""
    return paths.data / "Balatro" / LAUNCHER_ATTESTATION_NAME


def _staging_root_for(paths: RolePaths) -> Path:
    if paths.role == BOOTSTRAP_ROLE:
        return paths.root.parent
    return paths.root.parent.parent


def _staging_root_from_mods(mods_dir) -> Path:
    parts = Path(mods_dir).resolve().parts
    for index in range(len(parts) - 1, -1, -1):
        if parts[index].lower() in ("roles", BOOTSTRAP_ROLE):
            return Path(*parts[:index]) if index > 0 else Path(parts[0])
    return Path(mods_dir).resolve().parent.parent


def role_environment_overrides(paths: RolePaths) -> dict:
    """Explicit per-role native redirect plus the pinned Lovely Mods directory.

    Only the values this project deliberately changes are returned, so the full
    process environment is never logged. ``BALATRO_AI_ISOLATION`` is a constant
    reminder that the redirect is unverified.
    """
    return {
        "APPDATA": str(paths.data),
        "LOCALAPPDATA": str(paths.local_appdata),
        "USERPROFILE": str(paths.userprofile),
        "TEMP": str(paths.temp),
        "TMP": str(paths.temp),
        "LOVELY_MOD_DIR": str(paths.mods),
        "BALATRO_AI_ROLE": paths.role,
        "AIS_RUNTIME_ROLE": runtime_role(paths.role),
        "BALATRO_AI_STAGING_ROOT": str(paths.root),
        "BALATRO_AI_ISOLATION": "unproven",
    }


def role_environment(paths: RolePaths, base_env: Optional[Mapping] = None) -> dict:
    """Allowlisted child environment; no inherited Steam/SDL/LOVELY/Python vars.

    ``LOVELY_MOD_DIR`` and ``APPDATA`` are pinned inside the role root. The
    launcher sets a fresh ``AISP_PROBE_NONCE`` on the returned mapping immediately
    before spawn; any inherited value is deliberately not copied.
    """
    source = os.environ if base_env is None else base_env
    env: dict = {}
    for key, value in source.items():
        if str(key).upper() in ALLOWED_ENV_KEYS:
            env[key] = value
    env.update(role_environment_overrides(paths))
    return env


def _install_ignore(omitted: list):
    def ignore(dirpath, names):
        skip = []
        base = Path(dirpath)
        for name in sorted(names):
            lower = name.lower()
            full = base / name
            if full.is_dir() and lower in COPY_EXCLUDE_DIRNAMES:
                skip.append(name)
                omitted.append({"rel": name, "kind": "excluded_dir", "reason": lower})
                continue
            if lower in STEAM_NATIVE_FILES:
                skip.append(name)
                omitted.append({"rel": name, "kind": "steam_native", "reason": "omit_steam_native"})
                continue
            if lower in RUNTIME_STATE_NAMES:
                skip.append(name)
                omitted.append({"rel": name, "kind": "runtime_config", "reason": "live_env_never_copied"})
                continue
            if lower.endswith(RUNTIME_STATE_SUFFIXES):
                skip.append(name)
                omitted.append({"rel": name, "kind": "runtime_state", "reason": "save_or_log_never_copied"})
                continue
        return skip

    return ignore


def stage_install(source_install, dest_install, staging_root, live_roots_map=None) -> dict:
    source = Path(source_install).resolve()
    if not source.is_dir():
        raise StagingError("install_source_missing", str(source))
    assert_no_links(source, "install source")
    assert_no_overlap(staging_root, live_roots_map)
    staging_resolved = Path(staging_root).resolve()
    if is_within(staging_resolved, source, allow_root=True):
        raise StagingError("install_source_inside_staging", str(source))
    if is_within(source, staging_resolved):
        raise StagingError("staging_root_inside_install_source", str(staging_resolved))
    dest = assert_safe_write(staging_root, dest_install, "staged install")
    if dest.exists():
        raise StagingError("staging_target_exists", str(dest))
    dest.parent.mkdir(parents=True, exist_ok=True)
    omitted: list = []
    shutil.copytree(source, dest, ignore=_install_ignore(omitted))
    return {
        "source": str(source),
        "dest": str(dest),
        "omitted": omitted,
        "omitted_steam_natives": [entry["rel"] for entry in omitted if entry["kind"] == "steam_native"],
    }


def stage_mods(
    source_mods,
    dest_mods,
    staging_root,
    closed_check: Optional[Callable[[], bool]] = None,
    live_roots_map=None,
) -> dict:
    source = Path(source_mods).resolve()
    if not source.is_dir():
        raise StagingError("mods_source_missing", str(source))
    if closed_check is None:
        raise StagingError("closed_check_required", "refusing to copy a Mods tree without a closed-game check")
    if not closed_check():
        raise StagingError("live_source_not_closed", str(source))
    assert_no_links(source, "mods source")
    assert_no_overlap(staging_root, live_roots_map)
    dest = assert_safe_write(staging_root, dest_mods, "staged mods")
    if dest.exists():
        raise StagingError("staging_target_exists", str(dest))
    _ensure_dir(staging_root, dest.parent)
    omitted: list = []
    shutil.copytree(source, dest, ignore=_install_ignore(omitted))
    return {"source": str(source), "dest": str(dest), "omitted": omitted}


def detect_versions(install_root, steam_manifest_path=None) -> dict:
    install = Path(install_root)
    info: dict = {"install_root": str(install), "files": {}, "appmanifest": None}
    for name in ("Balatro.exe", "version.dll", "steam_api64.dll", "luasteam.dll", "love.dll", "lua51.dll"):
        candidate = install / name
        if candidate.is_file():
            info["files"][name] = {"sha256": sha256_file(candidate), "size": candidate.stat().st_size}
    manifest_path = (
        Path(steam_manifest_path)
        if steam_manifest_path
        else install.parent.parent / DEFAULT_STEAM_APPMANIFEST_NAME
    )
    if manifest_path.is_file():
        parsed = parse_appmanifest(manifest_path.read_text(encoding="utf-8", errors="replace"))
        info["appmanifest"] = {
            "path": str(manifest_path),
            "sha256": sha256_file(manifest_path),
            "appid": parsed.get("appid"),
            "buildid": parsed.get("buildid"),
            "installdir": parsed.get("installdir"),
            "last_updated": parsed.get("LastUpdated"),
            "name": parsed.get("name"),
        }
    return info


def parse_appmanifest(text: str) -> dict:
    return {key: value for key, value in APPMANIFEST_RE_PAIR.findall(text)}


def _steam_natives_in(install_root) -> list:
    install = Path(install_root)
    if not install.is_dir():
        return []
    return sorted(
        child.name for child in install.iterdir() if child.name.lower() in STEAM_NATIVE_FILES
    )


def find_multiplayer_mod(mods_dir) -> list:
    """Mods whose manifest JSON declares ``"id": "Multiplayer"`` (H4: not a name guess)."""
    mods = Path(mods_dir)
    if not mods.is_dir():
        return []
    matches: list = []
    for child in sorted(mods.iterdir()):
        if not child.is_dir():
            continue
        for manifest_file in sorted(child.glob("*.json")):
            try:
                data = json.loads(manifest_file.read_text(encoding="utf-8", errors="replace"))
            except (OSError, ValueError):
                continue
            if isinstance(data, dict) and str(data.get("id")) == "Multiplayer":
                matches.append(child)
                break
    return matches


def _resolve_multiplayer_mod(paths: RolePaths, mod_dir=None) -> Path:
    if mod_dir is not None:
        return assert_within(_staging_root_for(paths), mod_dir, "staged Multiplayer mod dir")
    matches = find_multiplayer_mod(paths.mods)
    if len(matches) != 1:
        raise StagingError(
            "multiplayer_mod_unresolved",
            f"expected exactly one Multiplayer mod under {paths.mods}, found {len(matches)}",
        )
    return matches[0]


def read_persisted_endpoint(mod_dir) -> Optional[dict]:
    config = Path(mod_dir) / "config.lua"
    try:
        if not config.is_file():
            return None
        text = config.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    url_match = CONFIG_URL_RE.search(text)
    port_match = CONFIG_PORT_RE.search(text)
    return {
        "path": str(config),
        "url": url_match.group(1) if url_match else None,
        "port": int(port_match.group(1)) if port_match else None,
    }


def read_persisted_mod_config(save_dir, mod_id: str = "Multiplayer") -> Optional[dict]:
    """Read the SMODS saved mod config (``config/<id>.jkr``) without assuming text.

    The ``.jkr`` container is compressed, so a plaintext regex is not proof. When
    the file is binary/compressed this returns ``opaque: True`` and no endpoint
    claim instead of pretending a missing URL is a verified loopback. The real
    protection is the pre-thread MP guard on the staged ``core.lua`` source.
    """
    base = Path(save_dir)
    for name in (f"{mod_id}.jkr", f"{mod_id}.lua"):
        candidate = base / "config" / name
        if not candidate.is_file():
            continue
        try:
            raw = candidate.read_bytes()
        except OSError:
            continue
        text: Optional[str] = None
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        if text is None or "\x00" in text:
            return {
                "path": str(candidate),
                "url": None,
                "port": None,
                "opaque": True,
                "encoding": "binary_or_compressed",
            }
        url_match = CONFIG_URL_RE.search(text)
        port_match = CONFIG_PORT_RE.search(text)
        return {
            "path": str(candidate),
            "url": url_match.group(1) if url_match else None,
            "port": int(port_match.group(1)) if port_match else None,
            "opaque": False,
            "encoding": "text",
        }
    return None


def rewrite_staged_config_endpoint(mod_dir, host: str = "127.0.0.1", port: int = 8788, staging_root=None) -> Optional[dict]:
    """Rewrite the staged Multiplayer ``config.lua`` fallback to loopback.

    Staged-only defence in depth: even if ``.env`` were removed, the mod's own
    default must not point at the official server.
    """
    config = Path(mod_dir) / "config.lua"
    if not config.is_file():
        return None
    try:
        text = config.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    before = sha256_file(config)
    new_text = CONFIG_URL_RE.sub(lambda match: match.group(0).replace(match.group(1), host), text, count=1)
    new_text = CONFIG_PORT_RE.sub(lambda match: match.group(0).replace(match.group(1), str(int(port))), new_text, count=1)
    if new_text != text:
        _write_text(staging_root if staging_root else _staging_root_from_mods(mod_dir), config, new_text)
    return {
        "path": str(config),
        "changed": new_text != text,
        "before_sha256": before,
        "after_sha256": sha256_file(config),
    }


def configure_role_endpoint(staging_root, role: str, port: int, host: str = "127.0.0.1", mod_dir=None) -> dict:
    paths = role_paths(staging_root, role)
    target_dir = _resolve_multiplayer_mod(paths, mod_dir=mod_dir)
    _ensure_dir(staging_root, target_dir)
    env_path = _write_text(staging_root, target_dir / ENV_NAME, render_env(host, port))
    parsed = parse_env(env_path.read_text(encoding="utf-8"))
    verdict = validate_local_endpoint(parsed, host=host, port=port)
    if not verdict["ok"]:
        raise StagingError("staged_endpoint_invalid", ",".join(verdict["problems"]))
    config_rewrite = rewrite_staged_config_endpoint(target_dir, host=host, port=port, staging_root=staging_root)
    persisted = read_persisted_endpoint(target_dir)
    if persisted and persisted.get("url") not in (None, host):
        raise StagingError("persisted_config_not_loopback", str(persisted))
    saved = read_persisted_mod_config(paths.data / "Balatro", "Multiplayer")
    if saved and saved.get("url") not in (None, host):
        raise StagingError("persisted_mod_config_not_loopback", str(saved))
    guard = write_steam_guard(paths, mp_guard=port, staging_root=staging_root)
    return {
        "role": role,
        "mod_dir": str(target_dir),
        "path": str(env_path),
        "url": host,
        "port": port,
        "sha256": sha256_file(env_path),
        "config_rewrite": config_rewrite,
        "persisted": persisted,
        "saved_config": saved,
        "saved_config_opaque": bool(saved and saved.get("opaque")),
        "patch": guard["patch"],
    }


def verify_staged_endpoints(staging_root, host: str = "127.0.0.1", port: Optional[int] = None, roles: Sequence[str] = ROLES) -> dict:
    results: dict = {}
    for role in roles:
        paths = role_paths(staging_root, role)
        matches = find_multiplayer_mod(paths.mods)
        if len(matches) != 1:
            results[role] = {
                "ok": False,
                "problems": ["multiplayer_mod_unresolved"],
                "path": str(paths.mods),
            }
            continue
        mod_dir = matches[0]
        env_path = mod_dir / ENV_NAME
        if not env_path.is_file():
            results[role] = {"ok": False, "problems": ["staged_env_missing"], "path": str(env_path)}
            continue
        try:
            raw_env = env_path.read_text(encoding="utf-8")
        except OSError:
            results[role] = {"ok": False, "problems": ["staged_env_unreadable"], "path": str(env_path)}
            continue
        parsed = parse_env(raw_env)
        verdict = validate_local_endpoint(parsed, host=host, port=port)
        persisted = read_persisted_endpoint(mod_dir)
        if persisted and persisted.get("url") not in (None, host):
            verdict["problems"].append("persisted_config_not_loopback")
            verdict["ok"] = False
        saved = read_persisted_mod_config(paths.data / "Balatro", "Multiplayer")
        if saved and saved.get("url") not in (None, host):
            verdict["problems"].append("persisted_mod_config_not_loopback")
            verdict["ok"] = False
        results[role] = {
            "ok": verdict["ok"],
            "problems": verdict["problems"],
            "path": str(env_path),
            "url": verdict["url"],
            "port": verdict["port"],
            "persisted": persisted,
            "saved_config": saved,
            "saved_config_opaque": bool(saved and saved.get("opaque")),
        }
    return {"ok": all(item["ok"] for item in results.values()), "roles": results}


def _toml_str(text: str) -> str:
    if "'''" in text:
        raise StagingError("toml_string_unrepresentable", "value contains triple quote")
    return "'''" + text + "'''"


def render_lovely_toml(patches: Sequence[Mapping], priority: int = LOVELY_PATCH_PRIORITY) -> str:
    lines = [
        "[manifest]",
        f'version = "{LOVELY_MANIFEST_VERSION}"',
        "dump_lua = true",
        f"priority = {priority}",
        "",
    ]
    for patch in patches:
        lines.append("[[patches]]")
        lines.append(f"[patches.{patch['kind']}]")
        lines.append(f"target = {_toml_str(str(patch['target']))}")
        lines.append(f"pattern = {_toml_str(str(patch['pattern']))}")
        lines.append(f"position = \"{patch['position']}\"")
        lines.append(f"payload = {_toml_str(str(patch['payload']))}")
        if "match_indent" in patch:
            lines.append(f"match_indent = {str(bool(patch['match_indent'])).lower()}")
        lines.append(f"times = {int(patch.get('times', 1))}")
        lines.append("")
    return "\n".join(lines)


def _lua_path(path) -> str:
    return str(path).replace("\\", "/")


def steam_disable_payload(patch_id: str = PATCH_ID) -> str:
    """NH1: the Steam block is replaced *and* a nonce-bound patch-applied marker is
    written at that exact point, so a missing/failed patch cannot look like success.
    """
    return (
        "-- AISparring staging: native Steam startup disabled (staged copy only).\n"
        "G.STEAM = nil\n"
        "do\n"
        "  local ai_patch = '" + patch_id + "'\n"
        "  local ai_nonce = os.getenv('AISP_PROBE_NONCE') or ''\n"
        "  local ai_save = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ''\n"
        "  love.filesystem.write('" + PROBE_STEAM_MARKER + "', 'probe=steam_marker\\npatch=' .. ai_patch .. '\\nnonce=' .. ai_nonce .. '\\nsteam_patch_applied=true\\nsteam=' .. tostring(G and G.STEAM) .. '\\nluasteam=' .. tostring(package.loaded and package.loaded.luasteam) .. '\\nsave=' .. tostring(ai_save))\n"
        "end"
    )


def steam_disable_patch(patch_id: str = PATCH_ID) -> dict:
    return {
        "kind": "regex",
        "target": "main.lua",
        "pattern": STEAM_BLOCK_PATTERN,
        "position": "at",
        "payload": steam_disable_payload(patch_id),
        "times": 1,
    }


def crash_reports_disable_patch() -> dict:
    return {
        "kind": "regex",
        "target": "main.lua",
        "pattern": CRASH_REPORT_PATTERN,
        "position": "at",
        "payload": "-- AISparring staging: vanilla crash-report POST disabled.\nif false then",
        "times": 1,
    }


def startup_guard_payload(expected_save_dir, expected_mods_dir, patch_id: str = PATCH_ID) -> str:
    save = _lua_path(expected_save_dir)
    mods = _lua_path(expected_mods_dir)
    return (
        "do\n"
        "  local ai_patch = '" + patch_id + "'\n"
        "  local ai_nonce = os.getenv('AISP_PROBE_NONCE') or ''\n"
        "  local ai_expected_save = '" + save + "'\n"
        "  local ai_expected_mods = '" + mods + "'\n"
        "  local function ai_norm(p) return (tostring(p):gsub('\\\\', '/'):lower()) end\n"
        "  local ai_ok, ai_actual = pcall(function() return love.filesystem.getSaveDirectory() end)\n"
        "  if (not ai_ok) or ai_norm(ai_actual) ~= ai_norm(ai_expected_save) then\n"
        "    error('AISparring staging refused: save directory ' .. tostring(ai_actual) .. ' != ' .. ai_expected_save, 0)\n"
        "  end\n"
        "  if ai_norm(ai_actual .. '/Mods') ~= ai_norm(ai_expected_mods) then\n"
        "    error('AISparring staging refused: Mods directory mismatch under ' .. ai_actual, 0)\n"
        "  end\n"
        "  if not love.filesystem.getInfo('Mods') then\n"
        "    error('AISparring staging refused: Mods missing under ' .. ai_expected_save, 0)\n"
        "  end\n"
        "  local ai_mods = os.getenv('LOVELY_MOD_DIR') or ''\n"
        "  love.filesystem.write('" + PROBE_MAIN + "', 'probe=main\\npatch=' .. ai_patch .. '\\nnonce=' .. ai_nonce .. '\\nsave=' .. tostring(ai_actual) .. '\\nexpected=' .. ai_expected_save .. '\\nmods=' .. ai_expected_mods)\n"
        "  love.filesystem.write('" + PROBE_GUARD + "', 'probe=guard\\npatch=' .. ai_patch .. '\\nnonce=' .. ai_nonce .. '\\nsave=' .. tostring(ai_actual) .. '\\nlovely_mod_dir=' .. ai_mods .. '\\nmods=' .. ai_expected_mods)\n"
        "end"
    )


def main_guard_patch(expected_save_dir, expected_mods_dir) -> dict:
    return {
        "kind": "pattern",
        "target": "main.lua",
        "pattern": START_UP_LITERAL,
        "position": "before",
        "payload": startup_guard_payload(expected_save_dir, expected_mods_dir),
        "match_indent": False,
        "times": 1,
    }


def steam_post_probe_payload(patch_id: str = PATCH_ID) -> str:
    """NH1: placed after the Steam block and before ``love.mouse.setVisible(false)``,
    this records the real ``G.STEAM`` and ``package.loaded.luasteam`` values.
    """
    return (
        "do\n"
        "  local ai_patch = '" + patch_id + "'\n"
        "  local ai_nonce = os.getenv('AISP_PROBE_NONCE') or ''\n"
        "  local ai_save = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ''\n"
        "  love.filesystem.write('" + PROBE_STEAM_POST + "', 'probe=steam_post\\npatch=' .. ai_patch .. '\\nnonce=' .. ai_nonce .. '\\nsteam=' .. tostring(G and G.STEAM) .. '\\nluasteam=' .. tostring(package.loaded and package.loaded.luasteam) .. '\\nsave=' .. tostring(ai_save))\n"
        "end"
    )


def steam_post_probe_patch(patch_id: str = PATCH_ID) -> dict:
    return {
        "kind": "pattern",
        "target": "main.lua",
        "pattern": LOVE_LOAD_END_LITERAL,
        "position": "before",
        "payload": steam_post_probe_payload(patch_id),
        "match_indent": False,
        "times": 1,
    }


def bootstrap_exit_patch() -> dict:
    payload = (
        "do\n"
        "  local ai_deadline = (love.timer and love.timer.getTime and love.timer.getTime() or 0) + 5\n"
        "  while (love.timer and love.timer.getTime and love.timer.getTime() or 0) < ai_deadline do\n"
        "    if love.filesystem.getInfo('" + PROBE_SAVE_THREAD + "') then break end\n"
        "    if love.timer and love.timer.sleep then love.timer.sleep(0.1) end\n"
        "  end\n"
        "  love.event.quit()\n"
        "end"
    )
    return {
        "kind": "pattern",
        "target": "main.lua",
        "pattern": LOVE_LOAD_END_LITERAL,
        "position": "before",
        "payload": payload,
        "match_indent": False,
        "times": 1,
    }


def measurement_crash_patch(patch_id: str = PATCH_ID) -> dict:
    """Measurement-only CRASH stimulus, gated by ``AISP_MEASURE_CRASH``.

    N2: it is placed after every probe patch and only fires when the tool sets the
    gate env var for the CRASH phase, so a normal match can never abort here. Before
    raising, it wraps the *active original* error handler
    (``love.errorhandler`` or ``love.errhand``) so the wrapper writes a fresh,
    nonce-bound crash probe and then chains to the original handler. A nonzero exit
    code alone is never accepted as a crash; only that fresh probe is (see
    ``_validate_crash_observation``).
    """
    payload = (
        "do\n"
        "  if os.getenv('" + MEASURE_CRASH_ENV + "') == '1' then\n"
        "    local ai_orig = love.errorhandler or love.errhand\n"
        "    local ai_nonce = os.getenv('" + PROBE_NONCE_VAR + "') or ''\n"
        "    local function ai_crash_handler(ai_msg)\n"
        "      local ai_save = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ''\n"
        "      if love.filesystem and love.filesystem.write then\n"
        "        love.filesystem.write('" + PROBE_CRASH + "', 'probe=crash\\npatch=" + patch_id + "\\nnonce=' .. ai_nonce .. '\\nsave=' .. tostring(ai_save) .. '\\nmsg=' .. tostring(ai_msg))\n"
        "      end\n"
        "      if ai_orig then return ai_orig(ai_msg) end\n"
        "    end\n"
        "    if love.errorhandler ~= nil then love.errorhandler = ai_crash_handler else love.errhand = ai_crash_handler end\n"
        "    error('AISparring measurement stimulus " + MEASUREMENT_CRASH_STIMULUS + " (" + patch_id + ")', 0)\n"
        "  end\n"
        "end"
    )
    return {
        "kind": "pattern",
        "target": "main.lua",
        "pattern": LOVE_LOAD_END_LITERAL,
        "position": "before",
        "payload": payload,
        "match_indent": False,
        "times": 1,
    }


def save_thread_probe_patch(patch_id: str = PATCH_ID) -> dict:
    payload = (
        "love.filesystem.write('" + PROBE_SAVE_THREAD + "', "
        "'probe=save_thread\\npatch=" + patch_id + "\\nnonce=' .. (os.getenv('AISP_PROBE_NONCE') or '') .. "
        "'\\nsave=' .. tostring(love.filesystem.getSaveDirectory()))"
    )
    return {
        "kind": "pattern",
        "target": "engine/save_manager.lua",
        "pattern": SAVE_THREAD_LITERAL,
        "position": "after",
        "payload": payload,
        "match_indent": False,
        "times": 1,
    }


def mp_guard_payload(port: int, patch_id: str = PATCH_ID) -> str:
    port_text = str(int(port))
    return (
        "do\n"
        "  local ai_patch = '" + patch_id + "'\n"
        "  local ai_nonce = os.getenv('AISP_PROBE_NONCE') or ''\n"
        "  local ai_url = MP.ENV and MP.ENV.server_url\n"
        "  local ai_port = tonumber(MP.ENV and MP.ENV.server_port)\n"
        "  if ai_url ~= '127.0.0.1' or ai_port ~= " + port_text + " then\n"
        "    error('AISparring staging refused: Multiplayer endpoint ' .. tostring(ai_url) .. ':' .. tostring(ai_port) .. ' != 127.0.0.1:" + port_text + "', 0)\n"
        "  end\n"
        "  local ai_mods = os.getenv('LOVELY_MOD_DIR') or ''\n"
        "  local ai_save = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ''\n"
        "  love.filesystem.write('" + PROBE_MP + "', 'probe=mp\\npatch=' .. ai_patch .. '\\nnonce=' .. ai_nonce .. '\\nurl=' .. tostring(ai_url) .. '\\nport=' .. tostring(ai_port) .. '\\nmods=' .. ai_mods .. '\\nsave=' .. tostring(ai_save))\n"
        "  if os.getenv('" + MEASURE_P2_ENV + "') == '1' then\n"
        "    local ai_markers = { " + ", ".join("'" + marker + "'" for marker in P2_PAYLOAD_MARKERS) + " }\n"
        "    if type(SOCKET) ~= 'string' then\n"
        "      error('AISparring staging refused: P2 source observer not applied to the network thread', 0)\n"
        "    end\n"
        "    for ai_i = 1, #ai_markers do\n"
        "      if not string.find(SOCKET, ai_markers[ai_i], 1, true) then\n"
        "        error('AISparring staging refused: P2 observer payload ' .. ai_markers[ai_i] .. ' missing from the network thread', 0)\n"
        "      end\n"
        "    end\n"
        "    if not string.find(SOCKET, 'AISP_P2_FLUSH', 1, true) then\n"
        "      error('AISparring staging refused: P2 source observer not applied to the network thread', 0)\n"
        "    end\n"
        "  end\n"
        "end"
    )


def _mp_p2_observer_state_payload(patch_id: str) -> str:
    """Thread-scope observer state + env-gated flush, injected once.

    ``MP.load_mp_file`` returns the network-thread long string, so everything here
    runs in the real separate LÖVE thread with the pinned ``love.filesystem`` and
    ``socket`` already required by that source. The observer only writes the
    artifact when ``AISP_MEASURE_P2`` is set; with the gate off it is inert.
    """
    return (
        "-- " + P2_PAYLOAD_MARKERS[0] + "\n"
        "local AISP_P2 = {\n"
        "  attempts = 0, successes = 0, failures = 0,\n"
        "  reconnect_attempts = 0, reconnect_failures = 0, reconnects = 0,\n"
        "  keepalive_failures = 0, closes = 0, keepalive_pushes = 0,\n"
        "  receive_errors = {}, keepalive_push_times = {}, cycles = {}, current_cycle = nil,\n"
        "  pending_start = nil,\n"
        "}\n"
        "local AISP_P2_ON = (os.getenv('" + MEASURE_P2_ENV + "') == '1')\n"
        "local function AISP_P2_NOW() return (socket.gettime and socket.gettime()) or os.clock() end\n"
        "local function AISP_P2_FLUSH()\n"
        "  if not AISP_P2_ON then return end\n"
        "  local ai_save = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ''\n"
        "  local ai_mods = os.getenv('LOVELY_MOD_DIR') or ''\n"
        "  local ai_nonce = os.getenv('AISP_PROBE_NONCE') or ''\n"
        "  local function ai_show(v) if v == nil then return 'none' end return tostring(v) end\n"
        "  local ai_lines = {\n"
        "    'probe=p2',\n"
        "    'schema=" + P2_OBSERVER_SCHEMA + "',\n"
        "    'patch=" + patch_id + "',\n"
        "    'nonce=' .. ai_nonce,\n"
        "    'url=' .. tostring(CONFIG_URL),\n"
        "    'port=' .. tostring(CONFIG_PORT),\n"
        "    'mods=' .. ai_mods,\n"
        "    'save=' .. tostring(ai_save),\n"
        "    'connect_attempts=' .. tostring(AISP_P2.attempts),\n"
        "    'connect_successes=' .. tostring(AISP_P2.successes),\n"
        "    'connect_failures=' .. tostring(AISP_P2.failures),\n"
        "    'first_result=' .. ai_show(AISP_P2.first_result),\n"
        "    'first_error=' .. tostring(AISP_P2.first_error or ''),\n"
        "    'first_time=' .. tostring(AISP_P2.first_time or 0),\n"
        "    'first_success_time=' .. tostring(AISP_P2.first_success_time or 0),\n"
        "    'last_result=' .. ai_show(AISP_P2.last_result),\n"
        "    'last_error=' .. tostring(AISP_P2.last_error or ''),\n"
        "    'last_time=' .. tostring(AISP_P2.last_time or 0),\n"
        "    'reconnect_attempts=' .. tostring(AISP_P2.reconnect_attempts),\n"
        "    'reconnect_failures=' .. tostring(AISP_P2.reconnect_failures),\n"
        "    'reconnects=' .. tostring(AISP_P2.reconnects),\n"
        "    'keepalive_failures=' .. tostring(AISP_P2.keepalive_failures),\n"
        "    'keepalive_pushes=' .. tostring(AISP_P2.keepalive_pushes),\n"
        "    'closes=' .. tostring(AISP_P2.closes),\n"
        "  }\n"
        "  for ai_i = 1, #AISP_P2.receive_errors do\n"
        "    ai_lines[#ai_lines + 1] = 'receive_error' .. ai_i .. '_value=' .. tostring(AISP_P2.receive_errors[ai_i].value)\n"
        "    ai_lines[#ai_lines + 1] = 'receive_error' .. ai_i .. '_time=' .. tostring(AISP_P2.receive_errors[ai_i].time)\n"
        "  end\n"
        "  for ai_i = 1, #AISP_P2.keepalive_push_times do\n"
        "    ai_lines[#ai_lines + 1] = 'keepalive_push' .. ai_i .. '_time=' .. tostring(AISP_P2.keepalive_push_times[ai_i])\n"
        "  end\n"
        "  for ai_i = 1, #AISP_P2.cycles do\n"
        "    local ai_c = AISP_P2.cycles[ai_i]\n"
        "    ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_cause=' .. tostring(ai_c.cause or '')\n"
        "    ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_start_time=' .. tostring(ai_c.start_time or 0)\n"
        "    ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_outcome=' .. tostring(ai_c.outcome or '')\n"
        "    ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_end_time=' .. tostring(ai_c.end_time or 0)\n"
        "    local ai_attempts = ai_c.attempts or {}\n"
        "    ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_attempt_count=' .. tostring(#ai_attempts)\n"
        "    for ai_j = 1, #ai_attempts do\n"
        "      ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_attempt' .. ai_j .. '_start=' .. tostring(ai_attempts[ai_j].start_time or 0)\n"
        "      ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_attempt' .. ai_j .. '_time=' .. tostring(ai_attempts[ai_j].time or 0)\n"
        "      ai_lines[#ai_lines + 1] = 'cycle' .. ai_i .. '_attempt' .. ai_j .. '_result=' .. ai_show(ai_attempts[ai_j].result)\n"
        "    end\n"
        "  end\n"
        "  love.filesystem.write('" + PROBE_P2 + "', table.concat(ai_lines, '\\n'))\n"
        "end"
    )


def _mp_p2_connect_observer_payload() -> str:
    """Injected immediately after the pinned ``connect`` call (inside the thread)."""
    return (
        "-- " + P2_PAYLOAD_MARKERS[1] + "\n"
        "if AISP_P2_ON then\n"
        "  AISP_P2.attempts = AISP_P2.attempts + 1\n"
        "  local ai_now = AISP_P2_NOW()\n"
        "  local ai_start = AISP_P2.pending_start or ai_now\n"
        "  AISP_P2.pending_start = nil\n"
        "  if AISP_P2.attempts == 1 then\n"
        "    AISP_P2.first_result = connectionResult\n"
        "    AISP_P2.first_error = tostring(errorMessage)\n"
        "    AISP_P2.first_time = ai_now\n"
        "  end\n"
        "  AISP_P2.last_result = connectionResult\n"
        "  AISP_P2.last_error = tostring(errorMessage)\n"
        "  AISP_P2.last_time = ai_now\n"
        "  if AISP_P2.current_cycle then\n"
        "    AISP_P2.reconnect_attempts = AISP_P2.reconnect_attempts + 1\n"
        "    local ai_attempts = AISP_P2.current_cycle.attempts\n"
        "    ai_attempts[#ai_attempts + 1] = { start_time = ai_start, time = ai_now, result = connectionResult }\n"
        "  end\n"
        "  if connectionResult == 1 then\n"
        "    AISP_P2.successes = AISP_P2.successes + 1\n"
        "    if not AISP_P2.first_success_time then AISP_P2.first_success_time = ai_now end\n"
        "  else\n"
        "    AISP_P2.failures = AISP_P2.failures + 1\n"
        "    if AISP_P2.current_cycle then AISP_P2.reconnect_failures = AISP_P2.reconnect_failures + 1 end\n"
        "  end\n"
        "  AISP_P2_FLUSH()\n"
        "end"
    )


def mp_p2_observer_patches(port: int, patch_id: str = PATCH_ID) -> list:
    """Measurement-only source observers for the real Multiplayer network thread.

    Every insertion is env-gated and additive: the pinned connect/reconnect/
    keepalive statements, the ``error == 'close'`` comparison, timeouts and RNG are
    untouched. The dead-port refusal only ever produces the *initial-failure* path;
    reconnect and keepalive stay unreported (pending) until those real branches run.
    The expected ``port`` is validated here but deliberately not embedded: the
    observer records the runtime ``CONFIG_PORT`` it actually used, and the receipt
    classifier binds that value to the tool-measured dead port.
    """
    if isinstance(port, bool) or not isinstance(port, int) or not (1 <= port <= 65535):
        raise StagingError("mp_p2_observer_bad_port", str(port))
    return [
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_SOCKET_REQUIRE_LITERAL,
            "position": "after",
            "payload": _mp_p2_observer_state_payload(patch_id),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_SOCKET_CONNECT_LITERAL,
            "position": "after",
            "payload": _mp_p2_connect_observer_payload(),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_SOCKET_CONNECT_LITERAL,
            "position": "before",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[9] + "\n"
                "if AISP_P2_ON then AISP_P2.pending_start = AISP_P2_NOW() end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_RECONNECT_START_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[2] + "\n"
                "if AISP_P2_ON then AISP_P2.reconnect_active = true end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_RECONNECT_OK_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[3] + "\n"
                "if AISP_P2_ON then\n"
                "  AISP_P2.reconnects = AISP_P2.reconnects + 1\n"
                "  AISP_P2.reconnect_active = false\n"
                "  if AISP_P2.current_cycle then\n"
                "    AISP_P2.current_cycle.outcome = 'recovered'\n"
                "    AISP_P2.current_cycle.end_time = AISP_P2_NOW()\n"
                "    AISP_P2.cycles[#AISP_P2.cycles + 1] = AISP_P2.current_cycle\n"
                "    AISP_P2.current_cycle = nil\n"
                "  end\n"
                "  AISP_P2_FLUSH()\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_RECONNECT_FAIL_LITERAL,
            "position": "before",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[4] + "\n"
                "if AISP_P2_ON then\n"
                "  AISP_P2.reconnects = AISP_P2.reconnects + 1\n"
                "  AISP_P2.reconnect_active = false\n"
                "  if AISP_P2.current_cycle then\n"
                "    AISP_P2.current_cycle.outcome = 'exhausted'\n"
                "    AISP_P2.current_cycle.end_time = AISP_P2_NOW()\n"
                "    AISP_P2.cycles[#AISP_P2.cycles + 1] = AISP_P2.current_cycle\n"
                "    AISP_P2.current_cycle = nil\n"
                "  end\n"
                "  AISP_P2_FLUSH()\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_CLOSE_COMMENT_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[5] + "\n"
                "if AISP_P2_ON then\n"
                "  AISP_P2.closes = AISP_P2.closes + 1\n"
                "  AISP_P2.current_cycle = { cause = 'close', start_time = AISP_P2_NOW(), attempts = {} }\n"
                "  AISP_P2_FLUSH()\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_KEEPALIVE_COMMENT_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[6] + "\n"
                "if AISP_P2_ON then\n"
                "  AISP_P2.keepalive_failures = AISP_P2.keepalive_failures + 1\n"
                "  AISP_P2.current_cycle = { cause = 'keepalive', start_time = AISP_P2_NOW(), attempts = {} }\n"
                "  AISP_P2_FLUSH()\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_RECEIVE_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[7] + "\n"
                "if AISP_P2_ON and error ~= nil and error ~= 'timeout' then\n"
                "  local ai_seen = false\n"
                "  for ai_i = 1, #AISP_P2.receive_errors do\n"
                "    if AISP_P2.receive_errors[ai_i].value == tostring(error) then ai_seen = true end\n"
                "  end\n"
                "  if not ai_seen then\n"
                "    AISP_P2.receive_errors[#AISP_P2.receive_errors + 1] = { value = tostring(error), time = AISP_P2_NOW() }\n"
                "    AISP_P2_FLUSH()\n"
                "  end\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
        {
            "kind": "pattern",
            "target": MP_SOCKET_SOURCE_TARGET,
            "pattern": MP_KEEPALIVE_PUSH_LITERAL,
            "position": "after",
            "payload": (
                "-- " + P2_PAYLOAD_MARKERS[8] + "\n"
                "if AISP_P2_ON then\n"
                "  AISP_P2.keepalive_pushes = AISP_P2.keepalive_pushes + 1\n"
                "  AISP_P2.keepalive_push_times[#AISP_P2.keepalive_push_times + 1] = AISP_P2_NOW()\n"
                "  AISP_P2_FLUSH()\n"
                "end"
            ),
            "match_indent": False,
            "times": 1,
        },
    ]


def multiplayer_guard_patch(port: int) -> dict:
    return {
        "kind": "pattern",
        "target": '=[SMODS Multiplayer "core.lua"]',
        "pattern": MP_THREAD_START_LITERAL,
        "position": "before",
        "payload": mp_guard_payload(port),
        "match_indent": False,
        "times": 1,
    }


def _lovely_line_match(line: str, pattern: str) -> bool:
    """N1: match one whole trimmed line against a Lovely pattern.

    Lovely pattern patches compare the *trimmed* source line to the pattern, where
    ``*`` matches any run of characters and ``?`` matches a single character; every
    other character is literal. This mirrors that rule exactly (a full-line anchor
    with no wildcards therefore matches one and only one identical line).
    """
    trimmed = line.strip()
    pattern = pattern.strip()
    regex = "".join(
        ".*" if char == "*" else "." if char == "?" else re.escape(char)
        for char in pattern
    )
    return re.fullmatch(regex, trimmed) is not None


def matching_source_lines(text: str, pattern: str) -> list:
    """N1: the 1-based line numbers of every line that matches ``pattern``."""
    return [
        number
        for number, line in enumerate(text.splitlines(), start=1)
        if _lovely_line_match(line, pattern)
    ]


def apply_source_pattern_patch(text: str, patch: Mapping) -> str:
    """Apply one generated ``pattern`` patch to source text exactly like Lovely.

    N1: each trimmed line is matched against the wildcard pattern and the patch is
    applied only when the match count equals ``times`` (fail closed otherwise), so
    the tests exercise the same full-line rule the real Lovely runtime uses instead
    of a looser substring search.
    """
    pattern = str(patch["pattern"])
    position = str(patch.get("position", "after"))
    payload = str(patch["payload"])
    limit = int(patch.get("times", 1))
    spans: list = []
    offset = 0
    for raw in text.splitlines(keepends=True):
        spans.append((offset, offset + len(raw)))
        offset += len(raw)
    insertions: list = []
    for start, end in spans:
        if _lovely_line_match(text[start:end], pattern):
            insertions.append(start if position == "before" else end)
    if len(insertions) != limit:
        raise StagingError(
            "source_pattern_match_count",
            f"{pattern!r} matched {len(insertions)} line(s), expected {limit}",
        )
    out = text
    for insert_at in sorted(set(insertions), reverse=True):
        prefix = "" if (insert_at == 0 or out[insert_at - 1] == "\n") else "\n"
        out = out[:insert_at] + prefix + payload + "\n" + out[insert_at:]
    return out


def p2_observer_anchor_problems(source_text: str, port: int = 1) -> list:
    """N1: every observer anchor must match exactly one full line of the socket source."""
    problems: list = []
    for patch in mp_p2_observer_patches(port):
        matches = matching_source_lines(source_text, str(patch["pattern"]))
        if len(matches) != 1:
            problems.append(f"mp_p2_anchor_not_unique:{patch['pattern']}")
    return problems


def staging_patches(expected_save_dir, expected_mods_dir, bootstrap: bool = False, mp_guard=None) -> list:
    patches = [
        steam_disable_patch(),
        crash_reports_disable_patch(),
        main_guard_patch(expected_save_dir, expected_mods_dir),
        steam_post_probe_patch(),
        save_thread_probe_patch(),
        measurement_crash_patch(),
    ]
    if bootstrap:
        patches.append(bootstrap_exit_patch())
    if mp_guard is not None:
        patches.append(multiplayer_guard_patch(mp_guard))
        patches.extend(mp_p2_observer_patches(mp_guard))
    return patches


def write_lovely_patch(
    mods_dir,
    mod_name: str,
    expected_save_dir,
    expected_mods_dir,
    bootstrap: bool = False,
    mp_guard=None,
    staging_root=None,
) -> dict:
    staging_root = Path(staging_root) if staging_root else _staging_root_from_mods(mods_dir)
    mod_root = _ensure_dir(staging_root, Path(mods_dir) / mod_name)
    patch_dir = _ensure_dir(staging_root, mod_root / "lovely")
    patch_path = patch_dir / "bootstrap.toml"
    patches = staging_patches(expected_save_dir, expected_mods_dir, bootstrap=bootstrap, mp_guard=mp_guard)
    _write_text(staging_root, patch_path, render_lovely_toml(patches))
    return {
        "mod": mod_name,
        "path": str(patch_path),
        "sha256": sha256_file(patch_path),
        "patches": len(patches),
    }


def write_steam_guard(paths: RolePaths, bootstrap: bool = False, mp_guard=None, staging_root=None) -> dict:
    """Write the staged-only Steam-disable Lovely patch (no shim, no dead module)."""
    staging_root = Path(staging_root) if staging_root else _staging_root_for(paths)
    guard_dir = _ensure_dir(staging_root, paths.root / "steam_guard")
    expected_save = paths.data / "Balatro"
    mod_name = PATCH_MOD_BOOTSTRAP if bootstrap else PATCH_MOD_ROLE
    patch = write_lovely_patch(
        paths.mods,
        mod_name,
        expected_save,
        paths.mods,
        bootstrap=bootstrap,
        mp_guard=mp_guard,
        staging_root=staging_root,
    )
    meta = {
        "schema": "aisparring.steam_guard.v2",
        "role": paths.role,
        "mode": "disable_native",
        "shim": False,
        "approved": False,
        "expected_save_dir": str(expected_save),
        "expected_mods_dir": str(paths.mods),
        "patch": patch,
        "patch_sha256": patch["sha256"],
        "patch_id": PATCH_ID,
    }
    _write_text(
        staging_root,
        guard_dir / STEAM_GUARD_META_NAME,
        json.dumps(meta, indent=2, sort_keys=True, default=str) + "\n",
    )
    return meta


def _read_guard_meta(paths: RolePaths) -> Optional[dict]:
    meta_path = paths.root / "steam_guard" / STEAM_GUARD_META_NAME
    if not meta_path.is_file():
        return None
    try:
        return read_json(meta_path)
    except (OSError, ValueError):
        return None


def check_steam_guard(staging_root, role: str, live=None, proof=None) -> dict:
    """Static staged Steam guard (NM5): patch hash + markers + absent native DLLs.

    This is deliberately **static**. It never reads the mutable
    ``isolation_proof.json`` and never claims Steam isolation from a recorded
    boolean. The fresh real-probe checker is ``check_steam_probes``; the immutable
    two-layer certificate remains the only launch gate. ``live`` and ``proof`` are
    accepted for signature compatibility with existing callers and are ignored.
    """
    paths = role_paths(staging_root, role)
    problems: list = []
    meta = _read_guard_meta(paths)
    patch = {}
    if meta is None:
        problems.append("steam_guard_missing")
    else:
        if meta.get("mode") != "disable_native":
            problems.append("mode_not_disable_native")
        if meta.get("shim") is not False:
            problems.append("shim_claim_present")
        patch = meta.get("patch") or {}
        patch_path = Path(patch.get("path", ""))
        if not patch_path.is_file():
            problems.append("patch_missing")
        else:
            if patch.get("sha256") != sha256_file(patch_path):
                problems.append("patch_hash_mismatch")
            try:
                text = patch_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            if "G.STEAM = nil" not in text:
                problems.append("steam_block_not_removed")
            if "steam_patch_applied=true" not in text:
                problems.append("steam_patch_marker_missing")
            if PROBE_STEAM_MARKER not in text:
                problems.append("steam_probe_marker_missing")
            if PROBE_STEAM_POST not in text:
                problems.append("steam_probe_post_missing")
    if not paths.install.is_dir():
        problems.append("install_missing")
    natives = _steam_natives_in(paths.install)
    if natives:
        problems.append("steam_native_present")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "steam_guard_unproven",
        "problems": problems,
        "path": str(paths.root / "steam_guard" / STEAM_GUARD_META_NAME),
        "root": str(paths.root),
        "mods": str(paths.mods),
        "patch": patch,
        "steam_natives": natives,
        "static_only": True,
    }


# ---------------------------------------------------------------------------
# Staged-only network suppression (Handy updater, SMODS HTTPS, SMODS debug socket)
# ---------------------------------------------------------------------------

def _suppress_handy_updater(text: str) -> Optional[str]:
    if NETWORK_SUPPRESSION_MARKER + " handy_updater" in text:
        return text
    if "https_updater_thread" not in text or "handy_updater_input" not in text:
        return None
    match = HANDY_UPDATER_START_RE.search(text)
    if not match:
        return None
    replacement = (
        NETWORK_SUPPRESSION_MARKER + " handy_updater\n"
        "local https_updater_thread = { start = function() end, wait = function() end }\n"
    )
    return text[: match.start()] + replacement + text[match.end():]


def _suppress_smods_debug_socket(text: str) -> Optional[str]:
    if NETWORK_SUPPRESSION_MARKER + " smods_debug_socket" in text:
        return text
    if "initializeSocketConnection" not in text:
        return None
    new = text
    new = new.replace(
        f"local succ = {SMODS_DEBUG_SOCKET_LITERAL}",
        "local succ = false " + NETWORK_SUPPRESSION_MARKER + " smods_debug_socket",
        1,
    )
    new = re.sub(
        r"(?m)^initializeSocketConnection\(\)\s*$",
        NETWORK_SUPPRESSION_MARKER + " smods_debug_socket (call disabled)",
        new,
        count=1,
    )
    return new if new != text else None


def _suppress_smods_https(text: str) -> Optional[str]:
    if NETWORK_SUPPRESSION_MARKER + " smods_https" in text:
        return text
    if "M.request" not in text:
        return None
    index = text.rfind("return M")
    if index == -1:
        return None
    override = (
        NETWORK_SUPPRESSION_MARKER + " smods_https\n"
        'M.request = function() return 0, "AISparring staging: external HTTPS disabled", {} end\n'
        'M.asyncRequest = function(url, options, cb) if type(cb) == "function" then cb(0, "AISparring staging: external HTTPS disabled", {}) end end\n\n'
    )
    return text[:index] + override + text[index:]


def _classify_suppression(text: str):
    if "https_updater_thread" in text and "handy_updater_input" in text and "love.thread.newThread" in text:
        return "handy_updater", _suppress_handy_updater(text)
    if "function initializeSocketConnection" in text or "initializeSocketConnection()" in text:
        return "smods_debug_socket", _suppress_smods_debug_socket(text)
    if "function M.request" in text or "M.request = function" in text:
        return "smods_https", _suppress_smods_https(text)
    return None, None


def _mod_manifest_ids(mods_dir) -> dict:
    """Map each mod directory to its manifest ``id`` (lowercased), never its name."""
    mods = Path(mods_dir)
    ids: dict = {}
    if not mods.is_dir():
        return ids
    for child in sorted(mods.iterdir()):
        if not child.is_dir():
            continue
        for manifest_file in sorted(child.glob("*.json")):
            try:
                data = json.loads(manifest_file.read_text(encoding="utf-8", errors="replace"))
            except (OSError, ValueError):
                continue
            if isinstance(data, dict) and data.get("id"):
                ids[child] = str(data["id"]).lower()
                break
    return ids


def _suppression_guarded(rule_id: str, text: str) -> bool:
    """A marker only counts when the staged guard it claims is really present."""
    if rule_id == "smods_https":
        return "external HTTPS disabled" in text
    if rule_id == "handy_updater":
        return HANDY_UPDATER_START_PATTERN.search(text) is None
    if rule_id == "smods_debug_socket":
        return SMODS_DEBUG_SOCKET_PATTERN.search(text) is None
    return False


def scan_network_suppressions(mods_dir) -> dict:
    """Re-detect suppressions by manifest id *and content*, never by folder name.

    NM4: a renamed Handy/Steamodded folder cannot pass silently. Any file that still
    contains an un-suppressed network pattern is refused, and any known network mod
    id must carry its suppression markers. No mod is blocked merely by its name.
    """
    mods = Path(mods_dir)
    result = {"schema": SUPPRESSION_SCHEMA, "ok": True, "applied": {}, "problems": [], "mod_ids": {}}
    if not mods.is_dir():
        result["ok"] = False
        result["problems"].append("mods_missing")
        return result
    for dirpath, _dirnames, filenames in os.walk(mods):
        for name in sorted(filenames):
            if not name.lower().endswith(".lua"):
                continue
            full = Path(dirpath) / name
            try:
                text = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            rel = full.relative_to(mods).as_posix()
            for rule in NETWORK_SUPPRESSION_RULES:
                marker = NETWORK_SUPPRESSION_MARKER + " " + rule["marker"]
                marker_present = marker in text
                guarded = marker_present and _suppression_guarded(rule["id"], text)
                if guarded:
                    result["applied"].setdefault(rule["id"], {"rel": rel, "sha256": sha256_file(full)})
                    continue
                if marker_present:
                    result["problems"].append(f"{rule['id']}_marker_without_guard:{rel}")
                if rule["pattern"].search(text):
                    result["problems"].append(f"{rule['id']}_unguarded:{rel}")
    mod_ids = _mod_manifest_ids(mods)
    result["mod_ids"] = {child.relative_to(mods).as_posix(): mod_id for child, mod_id in mod_ids.items()}
    for child, mod_id in mod_ids.items():
        required = KNOWN_NETWORK_MOD_IDS.get(mod_id)
        if not required:
            continue
        dir_markers: set = set()
        for lua in sorted(child.rglob("*.lua")):
            try:
                text = lua.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for rule in NETWORK_SUPPRESSION_RULES:
                if NETWORK_SUPPRESSION_MARKER + " " + rule["marker"] in text and _suppression_guarded(rule["id"], text):
                    dir_markers.add(rule["id"])
        for needed in required:
            if needed not in dir_markers:
                result["problems"].append(f"{needed}_not_suppressed_for_id:{mod_id}")
    result["ok"] = not result["problems"]
    return result


def suppress_staged_network_paths(mods_dir, staging_root) -> dict:
    """Apply deterministic staged-only suppressions and fail closed if incomplete."""
    mods = Path(mods_dir)
    entries: list = []
    if not mods.is_dir():
        return {"ok": False, "entries": [], "applied": {}, "problems": ["mods_missing"]}
    for dirpath, _dirnames, filenames in os.walk(mods):
        for name in sorted(filenames):
            if not name.lower().endswith(".lua"):
                continue
            full = Path(dirpath) / name
            try:
                text = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            kind, new_text = _classify_suppression(text)
            if kind is None or new_text is None or new_text == text:
                continue
            before = sha256_file(full)
            _write_text(staging_root, full, new_text)
            entries.append(
                {
                    "rel": full.relative_to(mods).as_posix(),
                    "kind": kind,
                    "before_sha256": before,
                    "after_sha256": sha256_file(full),
                }
            )
    scan = scan_network_suppressions(mods)
    if not scan["ok"]:
        raise StagingError("network_suppression_incomplete", ",".join(scan["problems"]))
    return {"ok": True, "entries": entries, "applied": scan["applied"], "problems": []}


def check_network_guards(staging_root, role: str) -> dict:
    paths = role_paths(staging_root, role)
    scan = scan_network_suppressions(paths.mods)
    return {
        "ok": scan["ok"],
        "code": "ok" if scan["ok"] else "network_guards_unproven",
        "problems": scan["problems"],
        "applied": scan["applied"],
        "path": str(paths.mods),
    }


def check_multiplayer_guard(staging_root, role: str, manifest: Optional[Mapping] = None) -> dict:
    paths = role_paths(staging_root, role)
    problems: list = []
    matches = find_multiplayer_mod(paths.mods)
    mod_dir = matches[0] if len(matches) == 1 else None
    if mod_dir is None:
        problems.append("multiplayer_mod_unresolved")
    env_path = (mod_dir / ENV_NAME) if mod_dir else None
    port: Optional[int] = None
    if env_path is not None and env_path.is_file():
        verdict = validate_local_endpoint(parse_env(env_path.read_text(encoding="utf-8")))
        if verdict["ok"]:
            port = verdict["port"]
        else:
            problems.extend(f"env_{item}" for item in verdict["problems"])
    else:
        problems.append("staged_env_missing")
    # Inspect the staged source, do not assume a compressed saved config is proof.
    env_read_in_source = False
    if mod_dir is not None:
        for source in sorted(mod_dir.rglob("*.lua")):
            try:
                source_text = source.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if ".env" in source_text:
                env_read_in_source = True
                break
    if mod_dir is not None and not env_read_in_source:
        problems.append("mp_env_read_missing")
    saved = read_persisted_mod_config(paths.data / "Balatro", "Multiplayer")
    patch_path = paths.mods / PATCH_MOD_ROLE / "lovely" / "bootstrap.toml"
    if not patch_path.is_file():
        problems.append("staging_patch_missing")
    else:
        text = patch_path.read_text(encoding="utf-8", errors="replace")
        if MP_THREAD_START_LITERAL not in text:
            problems.append("mp_guard_target_missing")
        if "MP.ENV" not in text:
            problems.append("mp_guard_env_check_missing")
        if PROBE_MP not in text:
            problems.append("mp_guard_probe_missing")
        if port is not None and str(port) not in text:
            problems.append("mp_guard_port_missing")
        # The P2 observer must be present (and env-gated) in the same staged patch:
        # without it the receipt can never observe a real connect outcome, and a
        # start marker or the tool's own refused probe is not accepted instead.
        if MP_SOCKET_CONNECT_LITERAL not in text:
            problems.append("mp_p2_observer_anchor_missing")
        if PROBE_P2 not in text:
            problems.append("mp_p2_observer_probe_missing")
        if P2_OBSERVER_SCHEMA not in text:
            problems.append("mp_p2_observer_schema_missing")
        if MEASURE_P2_ENV not in text:
            problems.append("mp_p2_observer_gate_missing")
        for marker in P2_PAYLOAD_MARKERS:
            if marker not in text:
                problems.append(f"mp_p2_payload_marker_missing:{marker}")
        # N1: the observer anchors are only applied if they match the staged
        # Multiplayer socket source exactly (one whole trimmed line each). A loose
        # fragment anchor that would silently never match is refused here.
        if mod_dir is not None:
            socket_source = mod_dir.joinpath(*MP_SOCKET_SOURCE_REL)
            if not socket_source.is_file():
                problems.append("mp_socket_source_missing")
            else:
                problems.extend(
                    p2_observer_anchor_problems(
                        socket_source.read_text(encoding="utf-8", errors="replace"),
                        port if port is not None else 1,
                    )
                )
        if manifest is not None:
            recorded = (manifest.get("steam_guard") or {}).get("patch_sha256")
            if recorded and recorded != sha256_file(patch_path):
                problems.append("mp_guard_patch_hash_mismatch")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "mp_guard_unproven",
        "problems": problems,
        "port": port,
        "mod_dir": str(mod_dir) if mod_dir else None,
        "env_path": str(env_path) if env_path else None,
        "patch_path": str(patch_path),
        "env_read_in_source": env_read_in_source,
        "saved_config": saved,
        "saved_config_opaque": bool(saved and saved.get("opaque")),
    }


def disable_mod_by_lovelyignore(mods_dir, name: str, staging_root=None) -> dict:
    """Write ``<mod>/.lovelyignore`` through the junction/escape safe-write check."""
    target = Path(mods_dir) / name
    if not target.is_dir():
        return {"ok": False, "code": "mod_missing", "name": name}
    root = Path(staging_root) if staging_root is not None else _staging_root_from_mods(mods_dir)
    marker = _write_text(root, target / ".lovelyignore", "")
    return {"ok": True, "code": "disabled", "name": name, "path": str(marker)}


# ---------------------------------------------------------------------------
# Probe parsing / bootstrap preflight and post-run evidence
# ---------------------------------------------------------------------------

def parse_probe(text: str) -> dict:
    fields: dict = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def _read_probe_entry(
    save_dir,
    name: str,
    expected_nonce: Optional[str],
    spawn_time: Optional[float],
    problems: list,
    time_tolerance: float = START_TIME_TOLERANCE,
) -> Optional[dict]:
    probe_path = Path(save_dir) / name
    if not probe_path.is_file():
        problems.append(f"{name}_missing")
        return None
    try:
        mtime = probe_path.stat().st_mtime
        text = probe_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        problems.append(f"{name}_unreadable")
        return None
    fields = parse_probe(text)
    entry = {"path": str(probe_path), "mtime": mtime, "fields": fields}
    if spawn_time is not None and mtime < (spawn_time - time_tolerance):
        problems.append(f"{name}_stale")
    if expected_nonce is not None and fields.get("nonce") != expected_nonce:
        problems.append(f"{name}_nonce_mismatch")
    if fields.get("patch") != PATCH_ID:
        problems.append(f"{name}_patch_mismatch")
    return entry


def _check_steam_probe_fields(probes: dict, problems: list) -> None:
    marker = probes.get(PROBE_STEAM_MARKER)
    if marker is not None and marker["fields"].get("steam_patch_applied") != "true":
        problems.append("steam_patch_marker_not_applied")
    post = probes.get(PROBE_STEAM_POST)
    if post is not None:
        if post["fields"].get("steam") != "nil":
            problems.append("steam_present")
        if post["fields"].get("luasteam") != "nil":
            problems.append("luasteam_present")


def check_steam_probes(
    staging_root,
    role: str,
    expected_nonce: Optional[str],
    spawn_time: Optional[float],
    time_tolerance: float = START_TIME_TOLERANCE,
) -> dict:
    """NM5 fresh real-probe Steam checker (the certificate's partner, not a gate).

    Requires the nonce-bound patch-applied marker *and* the post-Steam-block probe
    with absent ``G.STEAM`` and absent ``package.loaded.luasteam``. It reads only
    the staged probe files; it never consults a stored proof.
    """
    paths = role_paths(staging_root, role)
    save_dir = paths.data / "Balatro"
    problems: list = []
    probes: dict = {}
    for name in (PROBE_STEAM_MARKER, PROBE_STEAM_POST):
        entry = _read_probe_entry(save_dir, name, expected_nonce, spawn_time, problems, time_tolerance)
        if entry is not None:
            probes[name] = entry
    expected_save = _norm_path(save_dir)
    for name in (PROBE_STEAM_MARKER, PROBE_STEAM_POST):
        entry = probes.get(name)
        if entry is None:
            continue
        if _norm_path(entry["fields"].get("save")) != expected_save:
            problems.append(f"{name}_wrong_save_dir")
    _check_steam_probe_fields(probes, problems)
    return {
        "ok": not problems,
        "code": "ok" if not problems else "steam_probes_unproven",
        "problems": problems,
        "probes": probes,
        "path": str(save_dir),
        "root": str(paths.mods),
    }


def collect_role_probes(
    paths: RolePaths,
    expected_nonce: Optional[str],
    spawn_time: Optional[float],
    require_mp: bool = False,
    expected_port: Optional[int] = None,
    time_tolerance: float = START_TIME_TOLERANCE,
    required_names: Optional[Sequence[str]] = None,
) -> dict:
    """Exact parsed probe evidence for a role run.

    NH1: the pre-``G:start_up()`` guard no longer carries a vacuous ``steam=nil``
    field. Steam absence comes from the patch-applied marker plus the post-block
    probe. NM8: ``lovely_mod_dir``/``mods`` must equal the exact staged ``Mods``
    path, not merely sit anywhere under the role root.
    """
    save_dir = paths.data / "Balatro"
    problems: list = []
    probes: dict = {}
    if required_names is not None:
        required = [str(name) for name in required_names]
    else:
        required = [PROBE_MAIN, PROBE_GUARD, PROBE_STEAM_MARKER, PROBE_STEAM_POST, PROBE_SAVE_THREAD]
        if require_mp:
            required.append(PROBE_MP)
    for name in required:
        entry = _read_probe_entry(save_dir, name, expected_nonce, spawn_time, problems, time_tolerance)
        if entry is not None:
            probes[name] = entry
    expected_save = _norm_path(save_dir)
    expected_mods = _norm_path(paths.mods)
    for name in required:
        entry = probes.get(name)
        if entry is None:
            continue
        if _norm_path(entry["fields"].get("save")) != expected_save:
            problems.append(f"{name}_wrong_save_dir")
    guard = probes.get(PROBE_GUARD)
    if guard is not None:
        lovely = guard["fields"].get("lovely_mod_dir")
        if not lovely:
            problems.append("lovely_mod_dir_missing")
        elif _norm_path(lovely) != expected_mods:
            problems.append("lovely_mod_dir_not_exact")
        mods = guard["fields"].get("mods")
        if not mods:
            problems.append("guard_mods_missing")
        elif _norm_path(mods) != expected_mods:
            problems.append("guard_mods_not_exact")
    _check_steam_probe_fields(probes, problems)
    mp_probe = probes.get(PROBE_MP)
    if mp_probe is not None:
        if mp_probe["fields"].get("url") != "127.0.0.1":
            problems.append("mp_probe_url_not_loopback")
        if expected_port is not None and str(expected_port) != mp_probe["fields"].get("port"):
            problems.append("mp_probe_port_mismatch")
        mods = mp_probe["fields"].get("mods")
        if not mods:
            problems.append("mp_probe_mods_missing")
        elif _norm_path(mods) != expected_mods:
            problems.append("mp_probe_mods_not_exact")
    return {"ok": not problems, "problems": problems, "probes": probes, "path": str(save_dir), "root": str(paths.mods)}


def lovely_evidence_paths(paths: RolePaths) -> dict:
    """NM8: the exact staged Lovely log/dump locations (never a role-wide search)."""
    mods = Path(paths.mods)
    lovely = mods / LOVELY_DIR_NAME
    return {
        "mods": str(mods),
        "log_dir": str(lovely / LOVELY_LOG_DIR_NAME),
        "dump_dir": str(lovely / LOVELY_DUMP_DIR_NAME),
    }


def check_lovely_evidence(
    staging_root,
    role: str,
    spawn_time: Optional[float],
    expected_mods=None,
    time_tolerance: float = START_TIME_TOLERANCE,
    require_dump: bool = True,
) -> dict:
    """NM8: bind the exact staged ``Mods`` path and *fresh* Lovely log/dump files.

    The phase owner collects the actual ``main.lua`` dump as certificate evidence;
    this checker proves the artefacts are under the exact staged ``Mods`` tree and
    were written after the run's spawn time.
    """
    paths = _paths_for_role(staging_root, role)
    problems: list = []
    expected = expected_mods if expected_mods is not None else paths.mods
    if _norm_path(expected) != _norm_path(paths.mods):
        problems.append("lovely_mods_not_exact")
    if spawn_time is None:
        problems.append("spawn_time_required")
    fresh_logs: list = []
    log_dir = paths.mods / LOVELY_DIR_NAME / LOVELY_LOG_DIR_NAME
    if not log_dir.is_dir():
        problems.append("lovely_log_missing")
    else:
        for entry in sorted(log_dir.rglob("*")):
            if entry.is_file():
                try:
                    if spawn_time is not None and entry.stat().st_mtime >= (spawn_time - time_tolerance):
                        fresh_logs.append(entry.relative_to(paths.mods).as_posix())
                except OSError:
                    problems.append("lovely_log_unreadable")
        if not fresh_logs:
            problems.append("lovely_log_not_fresh")
    fresh_dumps: list = []
    dump_dir = paths.mods / LOVELY_DIR_NAME / LOVELY_DUMP_DIR_NAME
    if require_dump:
        if not dump_dir.is_dir():
            problems.append("lovely_dump_missing")
        else:
            for entry in sorted(dump_dir.rglob("*")):
                if entry.is_file():
                    try:
                        if spawn_time is not None and entry.stat().st_mtime >= (spawn_time - time_tolerance):
                            fresh_dumps.append(entry.relative_to(paths.mods).as_posix())
                    except OSError:
                        problems.append("lovely_dump_unreadable")
            if not fresh_dumps:
                problems.append("lovely_dump_not_fresh")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "lovely_evidence_unproven",
        "problems": problems,
        "root": str(paths.mods),
        "paths": lovely_evidence_paths(paths),
        "fresh_logs": fresh_logs,
        "fresh_dumps": fresh_dumps,
    }


def _read_bootstrap_manifest(paths: RolePaths):
    manifest_path = paths.root / MANIFEST_NAME
    if not manifest_path.is_file():
        return None, ["bootstrap_manifest_missing"]
    try:
        manifest = read_json(manifest_path)
    except (OSError, ValueError):
        return None, ["bootstrap_manifest_unreadable"]
    problems: list = []
    if not verify_manifest(manifest, paths.root)["ok"]:
        problems.append("bootstrap_manifest_mismatch")
    if manifest.get("patch_id") != PATCH_ID:
        problems.append("bootstrap_patch_id_mismatch")
    patch_path = manifest.get("patch_path")
    if not patch_path or not Path(patch_path).is_file():
        problems.append("bootstrap_patch_missing")
    elif manifest.get("patch_sha256") != sha256_file(patch_path):
        problems.append("bootstrap_patch_hash_mismatch")
    return manifest, problems


def check_bootstrap_preflight(staging_root) -> dict:
    """PRE-run bootstrap gate: manifest, patch binding, absent stale probes, paths."""
    paths = bootstrap_paths(staging_root)
    problems: list = []
    manifest, manifest_problems = _read_bootstrap_manifest(paths)
    problems.extend(manifest_problems)
    save_dir = paths.data / "Balatro"
    for name in (
        PROBE_MAIN,
        PROBE_GUARD,
        PROBE_SAVE_THREAD,
        PROBE_MP,
        PROBE_STEAM_MARKER,
        PROBE_STEAM_POST,
    ):
        if (save_dir / name).exists():
            problems.append(f"{name}_present_pre_run")
    if not paths.install.is_dir():
        problems.append("bootstrap_install_missing")
    natives = _steam_natives_in(paths.install)
    if natives:
        problems.append("steam_native_present")
    if not paths.mods.is_dir():
        problems.append("bootstrap_mods_missing")
    if paths.root.is_dir():
        links = find_links(paths.root)
        if links:
            problems.append("links_present")
    if isinstance(manifest, dict):
        if _norm_path(manifest.get("expected_save_dir")) != _norm_path(save_dir):
            problems.append("expected_save_dir_mismatch")
        if _norm_path(manifest.get("expected_mods_dir")) != _norm_path(paths.mods):
            problems.append("expected_mods_dir_mismatch")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "bootstrap_preflight_incomplete",
        "problems": problems,
        "path": str(paths.root),
    }


def check_bootstrap_evidence(staging_root, expected_nonce=None, spawn_time=None, expected_port=None) -> dict:
    """POST-run bootstrap gate: exact nonce- and time-bound parsed probes only."""
    paths = bootstrap_paths(staging_root)
    problems: list = []
    if not expected_nonce:
        problems.append("expected_nonce_required")
    if spawn_time is None:
        problems.append("spawn_time_required")
    _manifest, manifest_problems = _read_bootstrap_manifest(paths)
    problems.extend(manifest_problems)
    verdict = collect_role_probes(
        paths,
        expected_nonce,
        spawn_time,
        require_mp=False,
        expected_port=expected_port,
    )
    problems.extend(verdict["problems"])
    return {
        "ok": not problems,
        "code": "ok" if not problems else "bootstrap_evidence_incomplete",
        "problems": problems,
        "path": str(paths.data / "Balatro"),
        "probes": verdict["probes"],
    }


# ---------------------------------------------------------------------------
# Role staging / manifests / measured isolation proof
# ---------------------------------------------------------------------------

def stage_role(
    staging_root,
    role: str,
    install_source,
    mods_source=None,
    mods_closed_check=None,
    live_roots_map=None,
) -> dict:
    assert_no_overlap(staging_root, live_roots_map)
    paths = role_paths(staging_root, role)
    for directory in (paths.data, paths.local_appdata, paths.userprofile, paths.temp, paths.logs, paths.ipc):
        _ensure_dir(staging_root, directory)
    install_result = stage_install(install_source, paths.install, staging_root, live_roots_map=live_roots_map)
    mods_result = None
    suppression = None
    if mods_source:
        mods_result = stage_mods(
            mods_source,
            paths.mods,
            staging_root,
            closed_check=mods_closed_check,
            live_roots_map=live_roots_map,
        )
        suppression = suppress_staged_network_paths(paths.mods, staging_root)
    guard = write_steam_guard(paths, staging_root=staging_root)
    manifest_path = Path(install_source).resolve().parent.parent / DEFAULT_STEAM_APPMANIFEST_NAME
    return {
        "role": role,
        "paths": {key: str(value) for key, value in asdict(paths).items()},
        "install": install_result,
        "mods": mods_result,
        "suppression": suppression,
        "steam_guard": guard,
        "versions": detect_versions(paths.install, steam_manifest_path=manifest_path),
    }


def finalize_role(staging_root, role: str, extra: Optional[Mapping] = None) -> dict:
    paths = role_paths(staging_root, role)
    guard = _read_guard_meta(paths) or {}
    patch = guard.get("patch") or {}
    endpoint = verify_staged_endpoints(staging_root, roles=(role,))["roles"].get(role, {})
    network = scan_network_suppressions(paths.mods) if paths.mods.is_dir() else {"ok": False, "applied": {}}
    payload = {
        "role": role,
        "staged_install": str(paths.install),
        "identity": {
            "save_dir": str(paths.data / "Balatro"),
            "mods_dir": str(paths.mods),
            "appdata": str(paths.data),
            "userprofile": str(paths.userprofile),
        },
        "patch_version": patch.get("sha256"),
        "exe_sha256": sha256_file(paths.exe()) if paths.exe().is_file() else None,
        "steam_guard": {
            "mode": guard.get("mode"),
            "patch_sha256": patch.get("sha256"),
            "patch_path": patch.get("path"),
        },
        "endpoint": {
            "path": endpoint.get("path"),
            "url": endpoint.get("url"),
            "port": endpoint.get("port"),
        },
        "network_guards": {
            "ok": network.get("ok"),
            "applied": network.get("applied"),
        },
    }
    if extra:
        payload["metadata"] = dict(extra)
    manifest = build_manifest(paths.root, STAGING_POLICY, payload)
    manifest_path = _write_text(
        staging_root,
        paths.root / MANIFEST_NAME,
        json.dumps(manifest, indent=2, sort_keys=True, default=str) + "\n",
    )
    return {"path": str(manifest_path), "files": len(manifest["files"])}


def verify_staged_role(staging_root, role: str) -> dict:
    paths = role_paths(staging_root, role)
    manifest_path = paths.root / MANIFEST_NAME
    if not manifest_path.is_file():
        return {"ok": False, "code": "manifest_missing", "path": str(manifest_path), "problems": ["manifest_missing"]}
    try:
        manifest = read_json(manifest_path)
    except (OSError, ValueError):
        return {"ok": False, "code": "manifest_unreadable", "path": str(manifest_path), "problems": ["manifest_unreadable"]}
    problems: list = []
    manifest_verdict = verify_manifest(manifest, paths.root)
    if not manifest_verdict["ok"]:
        problems.append("manifest_mismatch")
    if not paths.mods.is_dir():
        problems.append("mods_missing")
    natives = _steam_natives_in(paths.install)
    if natives:
        problems.append("steam_native_present")
    if paths.root.is_dir() and find_links(paths.root):
        problems.append("links_present")
    network = check_network_guards(staging_root, role)
    if not network["ok"]:
        problems.append("network_guards_unproven")
    mp_guard = check_multiplayer_guard(staging_root, role, manifest=manifest)
    if not mp_guard["ok"]:
        problems.append("mp_guard_unproven")
    endpoint = verify_staged_endpoints(staging_root, roles=(role,))["roles"].get(role, {"ok": False})
    if not endpoint.get("ok"):
        problems.append("endpoint_unproven")
    recorded_network = (manifest.get("network_guards") or {}).get("applied") or {}
    current_network = network.get("applied") or {}
    if recorded_network != current_network:
        problems.append("network_guard_hash_mismatch")
    return {
        "ok": not problems,
        "code": "ok" if not problems else "staged_role_unproven",
        "problems": problems,
        "path": str(manifest_path),
        "manifest": manifest_verdict,
        "network_guards": network,
        "mp_guard": mp_guard,
        "endpoint": endpoint,
        "steam_natives": natives,
    }


def _role_immutable_state(staging_root, role: str) -> dict:
    paths = _paths_for_role(staging_root, role)
    guard = _read_guard_meta(paths) or {}
    patch_path = (guard.get("patch") or {}).get("path")
    exe = paths.exe()
    return {
        "install_digest": _tree_digest(paths.install, INSTALL_HASH_POLICY),
        "mods_digest": _tree_digest(paths.mods, MODS_HASH_POLICY),
        "patch_sha256": sha256_file(patch_path) if patch_path and Path(patch_path).is_file() else None,
        "exe_sha256": sha256_file(exe) if exe.is_file() else None,
    }


def _normalize_live(live) -> dict:
    roots = live if live is not None else live_roots()
    resolved: dict = {}
    for key, value in roots.items():
        try:
            resolved[key] = Path(value).resolve()
        except OSError:
            resolved[key] = Path(value)
    return resolved


def _live_state(live) -> dict:
    install = live.get("install")
    appdata = live.get("appdata")
    steam = live.get("steam_userdata")
    return {
        "install": _digest_of(detect_versions(install)) if install and Path(install).is_dir() else None,
        "appdata": _tree_digest(appdata, HashPolicy()) if appdata and Path(appdata).is_dir() else None,
        "steam_userdata": _tree_digest(steam, HashPolicy()) if steam and Path(steam).is_dir() else None,
    }


def measure_isolation_state(staging_root, roles: Sequence[str] = ROLES, live=None) -> dict:
    """Documented collector: before/after hashes for staged immutables and live roots."""
    resolved_live = _normalize_live(live)
    return {
        "schema": MEASURE_SCHEMA,
        "staging_root": str(Path(staging_root).resolve()),
        "live_roots": {key: str(value) for key, value in resolved_live.items()},
        "roles": {role: _role_immutable_state(staging_root, role) for role in roles},
        "live": _live_state(resolved_live),
        "measured_unix": int(time.time()),
    }


def record_isolation_proof(
    staging_root,
    before: Mapping,
    after: Mapping,
    expected_nonce: str,
    spawn_time: float,
    roles: Sequence[str] = ROLES,
    live=None,
    expected_port: Optional[int] = None,
    extra: Optional[Mapping] = None,
) -> dict:
    """The only code path that writes ``isolation_proof.json``, from measurements."""
    problems: list = []
    staging_resolved = str(Path(staging_root).resolve())
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        return {"ok": False, "code": "isolation_proof_incomplete", "problems": ["measurement_missing"]}
    for label, state in (("before", before), ("after", after)):
        if state.get("staging_root") != staging_resolved:
            problems.append(f"{label}_staging_root_mismatch")
    if before.get("live_roots") != after.get("live_roots"):
        problems.append("live_roots_changed")
    if before.get("live") != after.get("live"):
        problems.append("live_state_changed")
    if before.get("roles") != after.get("roles"):
        problems.append("staged_immutable_changed")
    if not expected_nonce:
        problems.append("expected_nonce_required")
    if spawn_time is None:
        problems.append("spawn_time_required")
    role_proofs: dict = {}
    role_state = after.get("roles") or {}
    for role in roles:
        paths = _paths_for_role(staging_root, role)
        require_mp = role != BOOTSTRAP_ROLE and len(find_multiplayer_mod(paths.mods)) == 1
        verdict = collect_role_probes(
            paths,
            expected_nonce,
            spawn_time,
            require_mp=require_mp,
            expected_port=expected_port,
        )
        problems.extend(f"{role}:{item}" for item in verdict["problems"])
        marker_fields = (verdict["probes"].get(PROBE_STEAM_MARKER) or {}).get("fields", {})
        post_fields = (verdict["probes"].get(PROBE_STEAM_POST) or {}).get("fields", {})
        entry = {
            "steam_absent": post_fields.get("steam") == "nil",
            "luasteam_absent": post_fields.get("luasteam") == "nil",
            "steam_patch_applied": marker_fields.get("steam_patch_applied") == "true",
            "nonce": post_fields.get("nonce") or marker_fields.get("nonce"),
            "patch_sha256": (role_state.get(role) or {}).get("patch_sha256"),
            "immutable_digest": _digest_of(role_state.get(role)),
        }
        if entry["steam_absent"] is not True:
            problems.append(f"{role}:steam_absent_not_proven")
        if entry["luasteam_absent"] is not True:
            problems.append(f"{role}:luasteam_absent_not_proven")
        if entry["steam_patch_applied"] is not True:
            problems.append(f"{role}:steam_patch_marker_not_proven")
        role_proofs[role] = entry
    if problems:
        return {"ok": False, "code": "isolation_proof_incomplete", "problems": problems}
    proof = {
        "schema": PROOF_SCHEMA,
        "recorded_unix": int(time.time()),
        "staging_root": staging_resolved,
        "live_roots": after.get("live_roots"),
        "roles": role_proofs,
        "role_state": role_state,
        "live": after.get("live"),
        "nonce": expected_nonce,
        "spawn_time": spawn_time,
        "zero_live_diff": True,
        "steam_isolation": "proven",
        "tool_sha256": sha256_file(Path(__file__).resolve()),
    }
    if extra:
        proof["metadata"] = dict(extra)
    proof_path = _write_text(
        staging_root,
        Path(staging_root) / "evidence" / EVIDENCE_NAME,
        json.dumps(proof, indent=2, sort_keys=True, default=str) + "\n",
    )
    return {"ok": True, "code": "isolation_proof_recorded", "path": str(proof_path), "problems": []}


def check_isolation_proof(staging_root, live=None, roles: Sequence[str] = ROLES) -> dict:
    """Host-facing reusable certificate gate (docs/CLAUDE_PROOF_ARCHITECTURE.md).

    Checks the current staged immutable code against the two-layer certificate,
    the bound tool hashes, endpoint and live-root paths. Live *contents* are never
    compared here; per-session byte diff is recorded separately through
    ``isolation_certificate.snapshot_live`` / ``record_session_verdict``. ``roles``
    is accepted for backwards compatibility and is unused.
    """
    import isolation_certificate

    verdict = dict(isolation_certificate.check_certificate(staging_root, live=live))
    verdict.setdefault("problems", [])
    return verdict


def build_isolation_certificate(staging_root, **kwargs) -> dict:
    """Wrapper for isolation_certificate.build_certificate (see docs for the API)."""
    import isolation_certificate

    return isolation_certificate.build_certificate(staging_root, **kwargs)


def snapshot_live(live, **kwargs) -> dict:
    """Full byte manifest of the live install/AppData/Steam-profile trees."""
    import isolation_certificate

    return isolation_certificate.snapshot_live(live, **kwargs)


def prepare_session(staging_root, **kwargs) -> dict:
    """Closed-game preparation: certificate + probe rotation + fresh session nonce."""
    import isolation_certificate

    return isolation_certificate.prepare_session(staging_root, **kwargs)


def record_session_verdict(staging_root, **kwargs) -> dict:
    """Append-only session receipt; live byte diff revokes and locks out."""
    import isolation_certificate

    return isolation_certificate.record_session_verdict(staging_root, **kwargs)


def write_launcher_attestation(staging_root, **kwargs) -> dict:
    """Measured session-bound host attestation writer (both roles must verify)."""
    import isolation_certificate

    return isolation_certificate.write_launcher_attestation(staging_root, **kwargs)


def stage_bootstrap(staging_root, install_source, live_roots_map=None) -> dict:
    assert_no_overlap(staging_root, live_roots_map)
    paths = bootstrap_paths(staging_root)
    for directory in (paths.data, paths.local_appdata, paths.userprofile, paths.temp, paths.logs, paths.ipc):
        _ensure_dir(staging_root, directory)
    install_result = stage_install(install_source, paths.install, staging_root, live_roots_map=live_roots_map)
    guard = write_steam_guard(paths, bootstrap=True, staging_root=staging_root)
    expected = {
        "role": BOOTSTRAP_ROLE,
        "save_dir": str(paths.data / "Balatro"),
        "mods_dir": str(paths.mods),
        "install": str(paths.install),
    }
    _write_text(
        staging_root,
        paths.root / BOOTSTRAP_EXPECTED_NAME,
        json.dumps(expected, indent=2, sort_keys=True) + "\n",
    )
    manifest = build_manifest(
        paths.root,
        BOOTSTRAP_POLICY,
        {
            "role": BOOTSTRAP_ROLE,
            "kind": "bootstrap",
            "patch_id": PATCH_ID,
            "patch_sha256": guard["patch"]["sha256"],
            "patch_path": guard["patch"]["path"],
            "expected_save_dir": expected["save_dir"],
            "expected_mods_dir": expected["mods_dir"],
            "expected_probe_files": [PROBE_MAIN, PROBE_GUARD, PROBE_SAVE_THREAD],
        },
    )
    manifest_path = _write_text(
        staging_root,
        paths.root / MANIFEST_NAME,
        json.dumps(manifest, indent=2, sort_keys=True, default=str) + "\n",
    )
    return {
        "role": BOOTSTRAP_ROLE,
        "paths": {key: str(value) for key, value in asdict(paths).items()},
        "install": install_result,
        "steam_guard": guard,
        "expected": expected,
        "manifest": {"path": str(manifest_path), "files": len(manifest["files"])},
    }


def _emit(payload: Mapping) -> None:
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="staging",
        description="Fail-closed local staging for the two-role AI Sparring topology.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    stage = sub.add_parser("stage", help="build role-separated staged trees (local writes only)")
    stage.add_argument("--install", default=str(DEFAULT_INSTALL))
    stage.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))
    stage.add_argument("--mods-source", default=None)
    stage.add_argument("--appdata", default=None)
    stage.add_argument("--steam-root", default=None)
    stage.add_argument("--roles", default=",".join(ROLES))
    stage.add_argument("--port", type=int, default=8788)

    verify = sub.add_parser("verify", help="re-hash staged manifests, guards and endpoints")
    verify.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))
    verify.add_argument("--roles", default=",".join(ROLES))

    status = sub.add_parser("status", help="report static isolation gate status")
    status.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))
    status.add_argument("--install", default=str(DEFAULT_INSTALL))
    status.add_argument("--appdata", default=None)
    status.add_argument("--steam-root", default=None)

    bootstrap = sub.add_parser("bootstrap", help="stage a minimal Steam-disabled bootstrap tree (no Multiplayer)")
    bootstrap.add_argument("--install", default=str(DEFAULT_INSTALL))
    bootstrap.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))
    bootstrap.add_argument("--appdata", default=None)
    bootstrap.add_argument("--steam-root", default=None)

    preflight = sub.add_parser("bootstrap-preflight", help="check pre-run bootstrap readiness")
    preflight.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))

    bootstrap_verify = sub.add_parser("bootstrap-verify", help="check post-run bootstrap probe evidence")
    bootstrap_verify.add_argument("--staging-root", default=str(DEFAULT_STAGING_ROOT))
    bootstrap_verify.add_argument("--nonce", default=None)
    bootstrap_verify.add_argument("--spawn-time", type=float, default=None)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "stage":
            roles = [role.strip() for role in args.roles.split(",") if role.strip()]
            roots = live_roots(install_root=args.install, appdata_root=args.appdata, steam_root=args.steam_root)
            mods_closed_check = None
            if args.mods_source:
                import launch_practice

                enumerator = launch_practice.default_enumerator()

                def mods_closed_check():
                    return launch_practice.check_live_balatro_closed(enumerator, args.install)["ok"]

            outputs = []
            for role in roles:
                result = stage_role(
                    args.staging_root,
                    role,
                    args.install,
                    mods_source=args.mods_source,
                    mods_closed_check=mods_closed_check,
                    live_roots_map=roots,
                )
                result["endpoint"] = configure_role_endpoint(args.staging_root, role, args.port)
                result["manifest"] = finalize_role(args.staging_root, role)
                result["verify"] = verify_staged_role(args.staging_root, role)
                outputs.append(result)
            _emit({"staging_root": str(Path(args.staging_root).resolve()), "roles": outputs})
            return 0
        if args.command == "verify":
            roles = [role.strip() for role in args.roles.split(",") if role.strip()]
            results = {role: verify_staged_role(args.staging_root, role) for role in roles}
            _emit({"ok": all(item["ok"] for item in results.values()), "roles": results})
            return 0
        if args.command == "bootstrap":
            roots = live_roots(install_root=args.install, appdata_root=args.appdata, steam_root=args.steam_root)
            result = stage_bootstrap(args.staging_root, args.install, live_roots_map=roots)
            _emit(result)
            return 0
        if args.command == "bootstrap-preflight":
            _emit(check_bootstrap_preflight(args.staging_root))
            return 0
        if args.command == "bootstrap-verify":
            _emit(
                check_bootstrap_evidence(
                    args.staging_root,
                    expected_nonce=args.nonce,
                    spawn_time=args.spawn_time,
                )
            )
            return 0
        if args.command == "status":
            proof = check_isolation_proof(args.staging_root)
            _emit(
                {
                    "staging_root": str(Path(args.staging_root).resolve()),
                    "endpoints": verify_staged_endpoints(args.staging_root),
                    "steam_guard": {role: check_steam_guard(args.staging_root, role) for role in ROLES},
                    "network_guards": {role: check_network_guards(args.staging_root, role) for role in ROLES},
                    "isolation_proof": proof,
                    "native_isolation_proven": proof["ok"],
                    "note": "unproven unless measured isolation_proof.json satisfies the P1 gates",
                }
            )
            return 0
    except StagingError as error:
        _emit({"ok": False, "code": error.code, "message": error.message})
        return 2
    except OSError as error:
        _emit({"ok": False, "code": "staging_io_error", "message": str(error)})
        return 2
    _emit({"ok": False, "code": "unknown_command"})
    return 2


if __name__ == "__main__":
    sys.exit(main())