#!/usr/bin/env python3
"""Two-layer isolation certificate and per-session live-diff tests.

Synthetic temp filesystems only: no live install, live %AppData%, Steam tree,
network, game launch or process action. The certificate is assembled only from
tool-owned *phase receipts* produced by ``isolation_certificate.record_phase_receipt``
over temp trees; the legacy caller-dict fixture, tampered receipts, staged drift,
revocation and the global lockout are asserted negative.
"""
from __future__ import annotations

import inspect
import json
import shutil
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import isolation_certificate as ic  # noqa: E402
import launch_practice  # noqa: E402
import staging  # noqa: E402

_MISSING = object()
PORT = 8788
NONCE = "cert-session-nonce"

MAIN_LUA = (
    "function love.load()\n"
    "\tG:start_up()\n"
    "\tlocal os = love.system.getOS()\n"
    "\tif os == 'Windows' then\n"
    "\t\tlocal st = require 'luasteam'\n"
    "\t\tG.STEAM = st\n"
    "\telse\n"
    "\tend\n"
    "\tlove.mouse.setVisible(false)\n"
    "end\n"
    "function love.errhand(msg)\n"
    "\tif G.SETTINGS.crashreports and _RELEASE_MODE and G.F_CRASH_REPORTS then\n"
    "\tend\n"
    "end\n"
)

SAVE_MANAGER_LUA = 'CHANNEL = love.thread.getChannel("save_request")\n'

MP_CORE_LUA = (
    "MP = SMODS.current_mod\n"
    "MP.ENV = {}\n"
    "MP.NETWORKING_THREAD = love.thread.newThread(SOCKET)\n"
    "MP.NETWORKING_THREAD:start(MP.ENV.server_url, MP.ENV.server_port)\n"
)

MP_CONFIG_LUA = 'return { ["server_url"] = "balatro.virtualized.dev", ["server_port"] = 8788 }\n'

SMODS_HTTPS_LUA = "local M = {}\nfunction M.request(url, options)\n\treturn 0\nend\nreturn M\n"

SMODS_LOGGING_LUA = (
    "function initializeSocketConnection()\n"
    "\tlocal tcp = assert(socket.tcp())\n"
    '\tlocal succ = tcp:connect("localhost", 53153)\n'
    "end\n"
    "initializeSocketConnection()\n"
)

HANDY_UPDATER_LUA = (
    "local https_updater_thread =\n"
    "\tlove.thread.newThread(love.filesystem.newFileData(updater_thread_file, 'thread'))\n"
    "https_updater_thread:start()\n"
    'local https_updater_input = love.thread.getChannel("handy_updater_input")\n'
)


@contextmanager
def patched(module, **attrs):
    saved = {}
    for name, value in attrs.items():
        saved[name] = getattr(module, name, _MISSING)
        setattr(module, name, value)
    try:
        yield
    finally:
        for name, value in saved.items():
            if value is _MISSING:
                delattr(module, name)
            else:
                setattr(module, name, value)


def _make_install(root: Path) -> Path:
    install = root / "BalatroInstall"
    (install / "resources" / "engine").mkdir(parents=True)
    (install / "Balatro.exe").write_bytes(b"MZ fake balatro")
    (install / "version.dll").write_bytes(b"lovely injector")
    (install / "steam_api64.dll").write_bytes(b"steam native")
    (install / "resources" / "main.lua").write_text(MAIN_LUA, encoding="utf-8")
    (install / "resources" / "engine" / "save_manager.lua").write_text(SAVE_MANAGER_LUA, encoding="utf-8")
    return install


def _make_mods(root: Path) -> Path:
    mods = root / "LiveAppData" / "Balatro" / "Mods"
    mp = mods / "Multiplayer"
    mp.mkdir(parents=True)
    (mp / "Multiplayer.json").write_text(json.dumps({"id": "Multiplayer"}), encoding="utf-8")
    (mp / "core.lua").write_text(MP_CORE_LUA, encoding="utf-8")
    (mp / "config.lua").write_text(MP_CONFIG_LUA, encoding="utf-8")
    (mp / ".env").write_text("server_url=balatro.virtualized.dev\n", encoding="utf-8")
    smods = mods / "Steamodded" / "libs"
    (smods / "https").mkdir(parents=True)
    (smods / "https" / "smods-https.lua").write_text(SMODS_HTTPS_LUA, encoding="utf-8")
    (smods / "logging.lua").write_text(SMODS_LOGGING_LUA, encoding="utf-8")
    handy = mods / "Handy" / "src" / "core" / "updater"
    handy.mkdir(parents=True)
    (handy / "index.lua").write_text(HANDY_UPDATER_LUA, encoding="utf-8")
    return mods


def _make_live(root: Path, profiles=("390025789", "111111111")) -> dict:
    install = root / "live" / "Balatro"
    install.mkdir(parents=True)
    (install / "Balatro.exe").write_bytes(b"MZ live")
    (install / "version.dll").write_bytes(b"lovely")
    appdata = root / "live_appdata" / "Balatro"
    (appdata / "Mods").mkdir(parents=True)
    (appdata / "Mods" / "x.lua").write_text("x", encoding="utf-8")
    for profile in profiles:
        app = root / "Steam" / "userdata" / profile / "2379780"
        (app / "remote").mkdir(parents=True)
        (app / "remote" / "state.vdf").write_text("s", encoding="utf-8")
    return {"install": install, "appdata": appdata}


def _live_map(root: Path, profiles=("390025789", "111111111")) -> dict:
    _make_live(root, profiles)
    return staging.live_roots(
        install_root=root / "live" / "Balatro",
        appdata_root=root / "live_appdata" / "Balatro",
        steam_root=root / "Steam",
    )


P2_INITIAL_ARTIFACT = (
    "connect_attempts=1\nconnect_successes=0\nconnect_failures=1\n"
    "first_result=none\nfirst_error=connection refused\nfirst_time=1.0\nfirst_success_time=0\n"
    "last_result=none\nlast_error=connection refused\nlast_time=1.0\n"
    "reconnect_attempts=0\nreconnect_failures=0\nreconnects=0\nkeepalive_failures=0\n"
    "keepalive_pushes=0\ncloses=0\n"
)

P2_CLOSE_ARTIFACT = (
    "connect_attempts=4\nconnect_successes=1\nconnect_failures=3\n"
    "first_result=1\nfirst_error=nil\nfirst_time=100.0\nfirst_success_time=100.0\n"
    "last_result=none\nlast_error=connection refused\nlast_time=115.0\n"
    "reconnect_attempts=3\nreconnect_failures=3\nreconnects=1\nkeepalive_failures=0\n"
    "keepalive_pushes=0\ncloses=1\n"
    "cycle1_cause=close\ncycle1_start_time=101.0\ncycle1_outcome=exhausted\ncycle1_end_time=115.0\n"
    "cycle1_attempt_count=3\n"
    "cycle1_attempt1_start=103.0\ncycle1_attempt1_time=103.0\ncycle1_attempt1_result=none\n"
    "cycle1_attempt2_start=107.0\ncycle1_attempt2_time=107.0\ncycle1_attempt2_result=none\n"
    "cycle1_attempt3_start=115.0\ncycle1_attempt3_time=115.0\ncycle1_attempt3_result=none\n"
    "receive_error1_value=closed\nreceive_error1_time=100.5\n"
)

# F1/F2: source-faithful SILENT artifact. The pinned source pushes five keepAlives
# (20 s then five 5 s retry timers) and then closes its own socket about 5 s after
# the fifth push, immediately starting the 2/4/8-second retry cycle. Each attempt's
# start and end are recorded separately so the scheduled gap excludes connect time.
P2_SILENT_ARTIFACT = (
    "connect_attempts=4\nconnect_successes=1\nconnect_failures=3\n"
    "first_result=1\nfirst_error=nil\nfirst_time=100.0\nfirst_success_time=100.0\n"
    "last_result=none\nlast_error=connection refused\nlast_time=159.0\n"
    "reconnect_attempts=3\nreconnect_failures=3\nreconnects=1\nkeepalive_failures=1\n"
    "keepalive_pushes=5\ncloses=0\n"
    "cycle1_cause=keepalive\ncycle1_start_time=145.0\ncycle1_outcome=exhausted\ncycle1_end_time=159.0\n"
    "cycle1_attempt_count=3\n"
    "cycle1_attempt1_start=147.0\ncycle1_attempt1_time=147.0\ncycle1_attempt1_result=none\n"
    "cycle1_attempt2_start=151.0\ncycle1_attempt2_time=151.0\ncycle1_attempt2_result=none\n"
    "cycle1_attempt3_start=159.0\ncycle1_attempt3_time=159.0\ncycle1_attempt3_result=none\n"
    "keepalive_push1_time=120.0\nkeepalive_push2_time=125.0\nkeepalive_push3_time=130.0\n"
    "keepalive_push4_time=135.0\nkeepalive_push5_time=140.0\n"
)

_P2_ARTIFACTS = {
    "P2_INITIAL": P2_INITIAL_ARTIFACT,
    "P2_CLOSE": P2_CLOSE_ARTIFACT,
    "P2_SILENT": P2_SILENT_ARTIFACT,
}
_SOCKET_DUMP = "return [[\n" + "\n".join(
    "-- " + marker for marker in staging.P2_PAYLOAD_MARKERS
) + "\n]]\n"


def _write_probes(paths, nonce=NONCE, port=PORT, phase=None):
    save = paths.data / "Balatro"
    save.mkdir(parents=True, exist_ok=True)
    (save / staging.PROBE_MAIN).write_text(
        f"probe=main\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n", encoding="utf-8"
    )
    (save / staging.PROBE_GUARD).write_text(
        f"probe=guard\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n"
        f"lovely_mod_dir={paths.mods}\nmods={paths.mods}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_SAVE_THREAD).write_text(
        f"probe=save_thread\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n", encoding="utf-8"
    )
    (save / staging.PROBE_MP).write_text(
        f"probe=mp\npatch={staging.PATCH_ID}\nnonce={nonce}\nurl=127.0.0.1\nport={port}\n"
        f"mods={paths.mods}\nsave={save}\n",
        encoding="utf-8",
    )
    (save / ic.PROBE_STEAM_MARKER).write_text(
        f"probe=steam_marker\npatch={staging.PATCH_ID}\nnonce={nonce}\nsteam_patch_applied=true\n"
        f"steam=nil\nluasteam=nil\nsave={save}\n",
        encoding="utf-8",
    )
    (save / ic.PROBE_STEAM_POST).write_text(
        f"probe=steam_post\npatch={staging.PATCH_ID}\nnonce={nonce}\nsteam=nil\nluasteam=nil\nsave={save}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_P2).write_text(
        f"probe=p2\nschema={staging.P2_OBSERVER_SCHEMA}\npatch={staging.PATCH_ID}\nnonce={nonce}\n"
        f"url=127.0.0.1\nport={port}\nmods={paths.mods}\nsave={save}\n"
        + _P2_ARTIFACTS.get(phase, P2_INITIAL_ARTIFACT),
        encoding="utf-8",
    )
    (save / staging.PROBE_CRASH).write_text(
        f"probe=crash\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n"
        f"msg=AISparring measurement stimulus {staging.MEASUREMENT_CRASH_STIMULUS}\n",
        encoding="utf-8",
    )
    if phase == "P2_SILENT":
        # F1: the listener observes the game's own expiry close (peer EOF) but keeps
        # holding its side; ``open_until`` is the tool's later release, and the
        # listener never half-closes in SILENT.
        listener_tail = (
            "closed=false\nfin=false\nclose_time=\nopen_until=160.0\n"
            "peer_eof=true\npeer_reset=false\neof_time=145.0\n"
        )
    else:
        listener_tail = (
            "closed=true\nfin=true\nclose_time=100.0\nopen_until=100.0\n"
            "peer_eof=false\npeer_reset=false\neof_time=\n"
        )
    (save / staging.PROBE_LISTENER).write_text(
        f"probe=listener\nschema={staging.LISTENER_SCHEMA}\npatch={staging.PATCH_ID}\nnonce={nonce}\n"
        f"phase={phase or 'P2_CLOSE'}\nport={port}\nfamilies=ipv4\nexclusive=true\nlistener_pid=1\n"
        "accepted=1\npeer_pid=100\npeer_host=127.0.0.1\npeer_is_owned_ai=true\nsent_bytes=0\n"
        "received_bytes=8\nreceived_total_bytes=8\n"
        "received_sha256=" + "0" * 64 + "\n"
        + listener_tail
        + f"save={save}\n",
        encoding="utf-8",
    )
    # M2: a fresh Lovely log and the actual main.lua/socket dumps under the exact staged Mods.
    for sub in ("log", "dump"):
        directory = paths.mods / staging.LOVELY_DIR_NAME / sub
        directory.mkdir(parents=True, exist_ok=True)
        (directory / ("main.lua" if sub == "dump" else "lovely.log")).write_text(
            "-- lovely %s evidence\n" % sub, encoding="utf-8"
        )
    # Official Lovely writes patched output under lovely/dump/<pretty_name>; the
    # socket evidence must be the exact SMODS/Multiplayer pretty path (not game-dump).
    socket_dump = paths.mods / staging.lovely_patched_dump_rel(staging.MP_SOCKET_DUMP_REL)
    socket_dump.parent.mkdir(parents=True, exist_ok=True)
    socket_dump.write_text(_SOCKET_DUMP, encoding="utf-8")
    return {
        "main": save / staging.PROBE_MAIN,
        "guard": save / staging.PROBE_GUARD,
        "save_thread": save / staging.PROBE_SAVE_THREAD,
        "mp": save / staging.PROBE_MP,
        "steam_marker": save / ic.PROBE_STEAM_MARKER,
        "steam_post": save / ic.PROBE_STEAM_POST,
        "p2": save / staging.PROBE_P2,
        "crash": save / staging.PROBE_CRASH,
        "listener": save / staging.PROBE_LISTENER,
    }


class _EmptyEnumerator(launch_practice.ProcessEnumerator):
    def list(self):
        return []


def _make_backup(root: Path, live_map, label="fixture-backup"):
    """A real, synthetic live backup so evidence comes from the production checker."""
    backup_root = root / "backups"
    steam_roots = [value for key, value in live_map.items() if key.startswith("steam_userdata/")]
    created = launch_practice.create_live_backup(
        install_root=live_map["install"],
        appdata_root=live_map["appdata"],
        steam_userdata_roots=steam_roots,
        backup_root=backup_root,
        enumerator=_EmptyEnumerator(),
        live_install_root=live_map["install"],
        label=label,
        execute=True,
    )
    assert created["ok"], created
    sources = {"install": live_map["install"], "appdata": live_map["appdata"]}
    for key, value in live_map.items():
        if key.startswith("steam_userdata/"):
            sources[key] = value
    return backup_root, sources


def _stage_all(root: Path):
    install = _make_install(root)
    mods = _make_mods(root)
    live_map = _live_map(root)
    staging_root = root / "staging"
    staging.stage_bootstrap(staging_root, install, live_roots_map=live_map)
    for role in staging.ROLES:
        staging.stage_role(
            staging_root,
            role,
            install,
            mods_source=mods,
            mods_closed_check=lambda: True,
            live_roots_map=live_map,
        )
        staging.configure_role_endpoint(staging_root, role, PORT)
        staging.finalize_role(staging_root, role)
    probes = {"bootstrap": _write_probes(staging.bootstrap_paths(staging_root))}
    for role in staging.ROLES:
        probes[role] = _write_probes(staging.role_paths(staging_root, role))
    backup_root, sources = _make_backup(root, live_map)
    return {
        "root": root,
        "staging_root": staging_root,
        "live_map": live_map,
        "probes": probes,
        "backup_root": backup_root,
        "sources": sources,
    }


def _backup_verify(fixture):
    """The real backup-evidence callable bound to the fixture's synthetic backup."""
    return lambda: launch_practice.check_backup_evidence(fixture["backup_root"], fixture["sources"])


# Legacy caller-dict fixture kept only so the negative test proves it is refused.
def _phases(fixture, *, role_digests=None, live_before=None, live_after=None):
    probes = fixture["probes"]
    role_install = {
        role: staging._tree_digest(
            staging.role_paths(fixture["staging_root"], role).install, staging.INSTALL_HASH_POLICY
        )
        for role in staging.ROLES
    }
    if role_digests is not None:
        role_install = role_digests
    before = live_before or staging._digest_of("measured")
    after = live_after or before
    return {
        "P1A": {
            "nonce": NONCE,
            "spawn_time": time.time() - 1,
            "measured": {
                "bootstrap_install_digest": staging._tree_digest(
                    staging.bootstrap_paths(fixture["staging_root"]).install, staging.INSTALL_HASH_POLICY
                ),
                "role_install_digests": role_install,
                "steam_absent": True,
            },
            "evidence_files": {"guard": probes["bootstrap"]["guard"]},
        },
        "P1B": {
            "nonce": NONCE,
            "spawn_time": time.time() - 1,
            "measured": {"port": PORT, "mods_digest": staging._digest_of("measured")},
            "evidence_files": {"mp": probes["ai"]["mp"]},
        },
        "FULL_P1": {
            "nonce": NONCE,
            "spawn_time": time.time() - 1,
            "measured": {"live_before_digest": before, "live_after_digest": after},
            "evidence_files": {"guard": probes["ai"]["guard"]},
        },
        "CRASH": {
            "nonce": NONCE,
            "spawn_time": time.time() - 1,
            "measured": {"crash_observed": True, "cleanup_ok": True},
            "evidence_files": {"save_thread": probes["ai"]["save_thread"]},
        },
        "P2": {
            "nonce": NONCE,
            "spawn_time": time.time() - 1,
            "measured": {"dead_port": 9, "refused": True},
            "evidence_files": {"main": probes["ai"]["main"]},
        },
    }


# --- tool-owned phase receipt fixtures -------------------------------------

class _FakeExitHandle:
    """Retained-handle stand-in with a measured exit code."""

    def __init__(self, code):
        self.returncode = code

    def poll(self):
        return self.returncode


class _FakeOwned:
    def __init__(self, role, pid, exit_code=0):
        self.role = role
        self.pid = pid
        self.handle = _FakeExitHandle(exit_code)


class _FakeSession:
    """Exited synthetic LaunchSession: records + owned handles already stopped."""

    def __init__(self, session_id, staging_root, nonce, spawn_time, roles, exit_codes=None, end_mode=None, end_code=None):
        self.session_id = session_id
        self.staging_root = Path(staging_root)
        self.nonce = nonce
        self.spawn_time = spawn_time
        self.code = "launched"
        self.end_mode = end_mode
        self.end_code = end_code
        self.ended_unix = int(time.time())
        exit_codes = exit_codes or {}
        self.records = [
            launch_practice.ProcessRecord(
                role=role,
                pid=100 + index,
                create_time=spawn_time,
                image_path=str(Path(staging_root) / "roles" / role / "install" / "Balatro.exe"),
                session_id=session_id,
            )
            for index, role in enumerate(roles)
        ]
        self.owned = [
            _FakeOwned(role, 100 + index, exit_codes.get(role, 0))
            for index, role in enumerate(roles)
        ]

    @property
    def ok(self):
        return self.code == "launched"

    def is_running(self):
        return [{"role": record.role, "pid": record.pid, "running": False} for record in self.records]

    def terminate(self, timeout=10.0):
        return []

    def close(self):
        return None


_CRASH_EXITS = {"human": staging.MEASUREMENT_END_CODES["CRASH"], "ai": staging.MEASUREMENT_END_CODES["CRASH"]}
_CRASH_END = (staging.MEASUREMENT_END_MODE, staging.MEASUREMENT_END_CODES["CRASH"])


def _fake_dead_port_setup(port=PORT):
    return {
        "ok": True,
        "kind": "dead_port",
        "dead_port": PORT,
        "host": "127.0.0.1",
        "refused": True,
        "listener_absent": {"ipv4": True, "ipv6": True},
        "attempts": 3,
        "timings": [0.001, 0.001, 0.001],
        "measured_unix": int(time.time()),
    }


def _end_kwargs(phase):
    if phase == "CRASH":
        return {"end_mode": _CRASH_END[0], "end_code": _CRASH_END[1]}
    if phase in ("P1B", "FULL_P1", "P2_INITIAL", "P2_CLOSE", "P2_SILENT"):
        return {"end_mode": staging.MEASUREMENT_END_MODE, "end_code": staging.MEASUREMENT_END_CODES[phase]}
    return {}


def _synthetic_server_binding(staging_root=None, *, config=None):
    return {
        "ok": True,
        "problems": [],
        "upstream_commit": "deadbeef",
        "package_lock_sha256": "a" * 64,
        "dependency_hashes": {"better-sqlite3": "b" * 64},
        "entry": "dist/main.js",
        "source": "synthetic",
    }


def _synthetic_tools(root: Path) -> dict:
    specs = {}
    for name in (
        "staging",
        "launcher",
        "prepare_server",
        "practice_service",
        "practice_host",
        "checker",
        "policy_worker",
        "policy_env",
        "ruleset_contract",
        "ai_baseline_policy",
        "ai_codec",
        "ai_observation",
        "ai_actions",
    ):
        target = root / "tools" / f"{name}.py"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"# {name} v1\n", encoding="utf-8")
        specs[name] = target
    return specs


@contextmanager
def synthetic_tools(root: Path):
    specs = _synthetic_tools(root)
    with patched(
        ic,
        bound_tool_specs=lambda: specs,
        measure_server_binding=_synthetic_server_binding,
    ):
        yield specs


def _record_phase(fixture, phase, exit_codes=None, prepared=None, session_id=None):
    staging_root = fixture["staging_root"]
    live = fixture["live_map"]
    session_id = session_id or f"phase-{phase.lower()}"
    if prepared is None:
        setup = _phase_setup(phase)
        prepared = ic.prepare_session(
            staging_root,
            live=live,
            session_id=session_id,
            port=PORT if phase != "P1A" else None,
            closed_check=lambda: True,
            phase=phase,
            backup_verify=_backup_verify(fixture),
            measurement_setup=setup,
        )
    assert prepared["ok"], (phase, prepared)
    nonce = prepared["nonce"]
    spawn_time = time.time() - 1
    ic.bind_open_session(staging_root, session_id, pids={"bootstrap": [1]}, spawn_time=spawn_time)
    _write_probes(staging.bootstrap_paths(staging_root), nonce=nonce, phase=phase)
    for role in staging.ROLES:
        _write_probes(staging.role_paths(staging_root, role), nonce=nonce, phase=phase)
    session = _FakeSession(
        session_id, staging_root, nonce, spawn_time, ic.PHASE_ROLES[phase],
        exit_codes=exit_codes, **_end_kwargs(phase),
    )
    return ic.record_phase_receipt(
        staging_root,
        phase=phase,
        session_id=session_id,
        session=session,
        live=live,
        port=PORT if phase != "P1A" else None,
        live_closed=lambda: True,
        after_exit_proof=_fake_dead_port_setup() if phase == "P2_INITIAL" else None,
    )


def _receipt_ids(fixture) -> dict:
    receipt_ids: dict = {}
    for phase in ic.REQUIRED_PHASES:
        exit_codes = _CRASH_EXITS if phase == "CRASH" else None
        result = _record_phase(fixture, phase, exit_codes=exit_codes)
        assert result["ok"], (phase, result)
        receipt_ids[phase] = result["receipt_id"]
    return receipt_ids


def _build(fixture, *, tools_root, receipt_ids=None, phases=None, **kwargs):
    with synthetic_tools(tools_root):
        if receipt_ids is None and phases is None:
            receipt_ids = _receipt_ids(fixture)
        if phases is not None:
            return ic.build_certificate(
                fixture["staging_root"], phases=phases, live=fixture["live_map"], port=PORT, **kwargs
            )
        return ic.build_certificate(
            fixture["staging_root"],
            receipt_ids=receipt_ids,
            live=fixture["live_map"],
            port=PORT,
            **kwargs,
        )


def test_bound_tools_and_env_names_align_with_real_launcher():
    specs = ic.bound_tool_specs()
    assert set(specs) == {
        "staging",
        "launcher",
        "prepare_server",
        "practice_service",
        "practice_host",
        "certificate_checker",
        "policy_worker",
        "policy_env",
        "ruleset_contract",
        "ai_baseline_policy",
        "ai_codec",
        "ai_observation",
        "ai_actions",
    }
    assert any(str(path).endswith("isolation_certificate.py") for path in specs.values())
    assert any(str(path).endswith("baseline_policy.lua") for path in specs.values())
    names = ic.launcher_session_env_names()
    assert names == sorted(launch_practice.SESSION_ENV_KEYS.values())
    assert tuple(launch_practice.SESSION_ENV_KEYS.values()) == staging.SESSION_DESCRIPTOR_VARS
    assert isinstance(staging.SESSION_DESCRIPTOR_VARS, tuple)
    assert not (set(names) & set(staging.FORBIDDEN_ENV_ALIASES))
    assert launch_practice.SESSION_ID_PATTERN is ic.SESSION_ID_RE
    with tempfile.TemporaryDirectory() as tmp:
        layer_n = ic.collect_layer_n(Path(tmp))
        env_index = layer_n["env_names"]
        assert "BALATRO_AI_ROLE" in env_index["role_overrides"]
        assert env_index["session_descriptor"] == names


def test_build_and_check_certificate_roundtrip():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        verdict = _build(fixture, tools_root=root)
        assert verdict["ok"] and verdict["status"] == "complete", verdict
        with synthetic_tools(root):
            checked = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert checked["ok"], checked
        assert checked["certificate_id"] == verdict["certificate_id"]


def test_legacy_caller_phase_dict_is_refused_not_a_type_error():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        verdict = _build(fixture, tools_root=root, phases=_phases(fixture))
        assert not verdict["ok"] and verdict["code"] == "certificate_receipts_required"
        assert verdict["problems"] == ["caller_phase_data_rejected"]


def test_certificate_partial_without_crash_and_p2():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            receipt_ids = _receipt_ids(fixture)
            receipt_ids.pop("CRASH")
            receipt_ids.pop("P2_CLOSE")
            receipt_ids.pop("P2_SILENT")
            verdict = ic.build_certificate(
                fixture["staging_root"], receipt_ids=receipt_ids, live=fixture["live_map"], port=PORT
            )
        assert not verdict["ok"] and verdict["status"] == "partial"
        assert "phase_crash_missing" in verdict["problems"]
        assert "phase_p2_close_missing" in verdict["problems"]
        assert "phase_p2_silent_missing" in verdict["problems"]
        assert verdict["certificate_id"] is None


def test_receipts_must_have_distinct_nonces():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root), patched(ic.secrets, token_hex=lambda size: "f" * 32):
            receipt_ids = {}
            for phase in ic.REQUIRED_PHASES:
                exit_codes = _CRASH_EXITS if phase == "CRASH" else None
                result = _record_phase(fixture, phase, exit_codes=exit_codes, session_id=f"dup-{phase.lower()}")
                assert result["ok"], (phase, result)
                receipt_ids[phase] = result["receipt_id"]
            verdict = ic.build_certificate(
                fixture["staging_root"], receipt_ids=receipt_ids, live=fixture["live_map"], port=PORT
            )
        assert not verdict["ok"]
        assert "phase_nonces_not_distinct" in verdict["problems"]


def test_tampered_receipt_is_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            receipt_ids = _receipt_ids(fixture)
            path = ic._receipt_path(fixture["staging_root"], receipt_ids["P1A"])
            body = json.loads(path.read_text(encoding="utf-8"))
            body["nonce"] = "forged-nonce"
            path.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            verdict = ic.build_certificate(
                fixture["staging_root"], receipt_ids=receipt_ids, live=fixture["live_map"], port=PORT
            )
        assert not verdict["ok"]
        assert any("receipt_id_mismatch" in problem for problem in verdict["problems"])

def test_check_rejects_native_and_mods_layer_changes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert _build(fixture, tools_root=root)["ok"]
        ai_paths = staging.role_paths(fixture["staging_root"], "ai")
        (ai_paths.install / "Balatro.exe").write_bytes(b"MZ tampered")
        with synthetic_tools(root):
            native = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert not native["ok"] and "native_layer_changed" in native["problems"]

        fixture2 = _stage_all(root / "second")
        assert _build(fixture2, tools_root=root / "second")["ok"]
        ai2 = staging.role_paths(fixture2["staging_root"], "ai")
        (ai2.mods / "Handy" / "src" / "core" / "updater" / "index.lua").write_text("return {}\n", encoding="utf-8")
        with synthetic_tools(root / "second"):
            mods = ic.check_certificate(fixture2["staging_root"], live=fixture2["live_map"], port=PORT)
        assert not mods["ok"] and "mods_layer_changed" in mods["problems"]


def test_generated_game_dump_cache_does_not_change_certificate_mods_layer():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert _build(fixture, tools_root=root)["ok"]
        paths = staging.role_paths(fixture["staging_root"], "ai")
        # The real run regenerates Lovely's separate unpatched game-dump cache; only
        # the exact generated prefix is ignored, so layer M is unaffected.
        regenerated = (
            paths.mods / staging.LOVELY_DIR_NAME / staging.LOVELY_GAME_DUMP_DIR_NAME / "SMODS" / "Multiplayer"
        )
        (regenerated / "networking").mkdir(parents=True)
        (regenerated / "core.lua").write_text("-- regenerated core\n", encoding="utf-8")
        (regenerated / "networking" / "socket.lua").write_text("-- regenerated socket\n", encoding="utf-8")
        with synthetic_tools(root):
            verdict = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert verdict["ok"], verdict
        # A same-named sibling tree is still ordinary source and still refuses.
        sibling = paths.mods / staging.LOVELY_DIR_NAME / (staging.LOVELY_GAME_DUMP_DIR_NAME + "-extra")
        sibling.mkdir(parents=True)
        (sibling / "keep.lua").write_text("-- sibling\n", encoding="utf-8")
        with synthetic_tools(root):
            changed = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert not changed["ok"] and "mods_layer_changed" in changed["problems"]


def test_certificate_requires_staged_role_parity():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods_a = _make_mods(root)
        mods_b = root / "other_mods" / "Balatro" / "Mods"
        shutil.copytree(mods_a, mods_b)
        (mods_b / "role_divergence.txt").write_text("human/ai drift\n", encoding="utf-8")
        live_map = _live_map(root)
        staging_root = root / "staging"
        staging.stage_bootstrap(staging_root, install, live_roots_map=live_map)
        staging.stage_role(
            staging_root, "human", install, mods_source=mods_a, mods_closed_check=lambda: True, live_roots_map=live_map
        )
        staging.stage_role(
            staging_root, "ai", install, mods_source=mods_b, mods_closed_check=lambda: True, live_roots_map=live_map
        )
        for role in staging.ROLES:
            staging.configure_role_endpoint(staging_root, role, PORT)
            staging.finalize_role(staging_root, role)
        fixture = {"root": root, "staging_root": staging_root, "live_map": live_map}
        with synthetic_tools(root):
            layer_n = ic.collect_layer_n(staging_root, live=live_map)
            layer_m = ic.collect_layer_m(staging_root, live=live_map)
            problems = ic._layer_problems(layer_n, layer_m, PORT)
            build = ic.build_certificate(staging_root, receipt_ids={}, live=live_map, port=PORT)
        assert "staged_roles_content_mismatch" in problems
        assert not build["ok"] and "staged_roles_content_mismatch" in build["problems"]


def _load_certificate(fixture) -> dict:
    pointer = (fixture["staging_root"] / "evidence" / ic.POINTER_NAME).read_text(encoding="utf-8").strip()
    return json.loads(
        (fixture["staging_root"] / "evidence" / ic.CERT_SUBDIR / f"{pointer}.json").read_text(encoding="utf-8")
    )


def test_check_rejects_live_root_and_evidence_changes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert _build(fixture, tools_root=root)["ok"]

        other_live = staging.live_roots(
            install_root=root / "elsewhere" / "Balatro",
            appdata_root=fixture["live_map"]["appdata"],
            steam_root=root / "Steam",
        )
        with synthetic_tools(root):
            live = ic.check_certificate(fixture["staging_root"], live=other_live, port=PORT)
        assert not live["ok"] and "live_roots_mismatch" in live["problems"]

        certificate = _load_certificate(fixture)
        evidence_rel = certificate["evidence"]["P1A"]["probes"]["bootstrap"]["guard"]["copy"]
        (fixture["staging_root"] / evidence_rel).write_bytes(b"tampered evidence")
        with synthetic_tools(root):
            tampered = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert not tampered["ok"] and any(problem.startswith("evidence_tampered") for problem in tampered["problems"])


def test_check_rejects_bound_tool_change():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        specs = _synthetic_tools(root)
        with patched(
            ic,
            bound_tool_specs=lambda: specs,
            measure_server_binding=_synthetic_server_binding,
        ):
            assert ic.build_certificate(
                fixture["staging_root"],
                receipt_ids=_receipt_ids(fixture),
                live=fixture["live_map"],
                port=PORT,
            )["ok"]
            specs["prepare_server"].write_text("# prepare_server v2\n", encoding="utf-8")
            changed = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert not changed["ok"] and "bound_tool_changed:prepare_server" in changed["problems"]


def test_check_rejects_forged_boolean_certificate():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        evidence = fixture["staging_root"] / "evidence"
        (evidence / "certificates").mkdir(parents=True, exist_ok=True)
        (evidence / "certificates" / "forgedcert.json").write_text(
            json.dumps(
                {
                    "schema": ic.SCHEMA,
                    "status": "complete",
                    "certificate_id": "forgedcert",
                    "p1a": {"passed": True},
                    "live_roots": {},
                    "evidence": {},
                }
            ),
            encoding="utf-8",
        )
        (evidence / "isolation_certificate.current").write_text("forgedcert\n", encoding="utf-8")
        with synthetic_tools(root):
            forged = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert not forged["ok"]
        assert "native_layer_changed" in forged["problems"]


def test_snapshot_live_is_full_byte_manifest_over_all_profiles_only():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        live_map = _live_map(root)
        snapshot = ic.snapshot_live(live_map)
        assert snapshot["schema"] == ic.SNAPSHOT_SCHEMA
        keys = set(snapshot["roots"])
        assert "install" in keys and "appdata" in keys
        assert "steam_root" not in keys and "install_steamapps" not in keys
        for profile in ("390025789", "111111111"):
            assert f"steam_userdata/{profile}" in keys
            entry = snapshot["roots"][f"steam_userdata/{profile}"]
            assert entry["files"] and all("sha256" in item for item in entry["files"].values())
        assert ic.snapshot_live({"install": root / "missing"})["roots"]["install"]["digest"] is None
        assert ic._recompute_snapshot_digest(snapshot) == snapshot["digest"]


def test_live_snapshot_still_includes_lovely_dump_and_game_dump_content():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        live_map = _live_map(root)
        mods = Path(live_map["appdata"]) / "Mods"
        for rel in (
            "lovely/log/lovely.log",
            "lovely/dump/main.lua",
            "lovely/game-dump/SMODS/Multiplayer/core.lua",
        ):
            path = mods / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("-- " + rel + "\n", encoding="utf-8")
        files = ic.snapshot_live(live_map)["roots"]["appdata"]["files"]
        # The immutable live snapshot stays complete: generated Lovely output is
        # captured byte-for-byte even though the staged policies ignore it.
        assert "Mods/lovely/log/lovely.log" in files
        assert "Mods/lovely/dump/main.lua" in files
        assert "Mods/lovely/game-dump/SMODS/Multiplayer/core.lua" in files


def _prepare_for_verdict(fixture, session_id="s1", backup_id=None):
    prepared = ic.prepare_session(
        fixture["staging_root"],
        live=fixture["live_map"],
        session_id=session_id,
        closed_check=lambda: True,
        phase="P1A",
        backup_id=backup_id,
        backup_verify=_backup_verify(fixture),
    )
    assert prepared["ok"], prepared
    return prepared


def _retained(fixture, session_id, nonce, roles=("bootstrap",), running=False):
    session = _FakeSession(session_id, fixture["staging_root"], nonce, 1.0, roles)
    if running:
        session.is_running = lambda: [
            {"role": record.role, "pid": record.pid, "running": True} for record in session.records
        ]
    return session


def test_session_live_diff_revokes_and_locks_out():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared = _prepare_for_verdict(fixture, "s1")
        (fixture["live_map"]["appdata"] / "Mods" / "x.lua").write_text("changed", encoding="utf-8")
        verdict = ic.record_session_verdict(
            fixture["staging_root"],
            session_id="s1",
            live=fixture["live_map"],
            session=_retained(fixture, "s1", prepared["nonce"]),
            live_closed=lambda: True,
        )
        assert not verdict["ok"] and verdict["code"] == "live_byte_diff_revoked"
        assert verdict["changed_roots"] == ["appdata"]
        assert ic.lockout(fixture["staging_root"])["locked"] is True
        check = ic.check_certificate(fixture["staging_root"], live=fixture["live_map"], port=PORT)
        assert check["code"] == "certificate_locked_out"
        receipts = (fixture["staging_root"] / "evidence" / "sessions" / "receipts.jsonl").read_text(encoding="utf-8")
        assert "s1" in receipts and '"verdict":"revoked"' in receipts
        revocations = ic.read_revocations(fixture["staging_root"])
        assert any(item["reason"] == "live_byte_diff" for item in revocations)


def test_session_no_diff_passes_and_appends_receipt():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared = _prepare_for_verdict(fixture, "clean")
        verdict = ic.record_session_verdict(
            fixture["staging_root"],
            session_id="clean",
            live=fixture["live_map"],
            session=_retained(fixture, "clean", prepared["nonce"]),
            live_closed=lambda: True,
        )
        assert verdict["ok"] and verdict["code"] == "session_passed"
        assert ic.lockout(fixture["staging_root"])["locked"] is False
        assert "clean" in (
            fixture["staging_root"] / "evidence" / "sessions" / "receipts.jsonl"
        ).read_text(encoding="utf-8")


def test_verdict_requires_retained_session_and_closed_live_game():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared = _prepare_for_verdict(fixture, "closure")
        no_session = ic.record_session_verdict(
            fixture["staging_root"], session_id="closure", live=fixture["live_map"], live_closed=lambda: True
        )
        assert not no_session["ok"] and no_session["code"] == "session_closure_unproven"
        assert "retained_session_required" in no_session["problems"]
        no_live = ic.record_session_verdict(
            fixture["staging_root"],
            session_id="closure",
            live=fixture["live_map"],
            session=_retained(fixture, "closure", prepared["nonce"]),
        )
        assert not no_live["ok"] and "live_closed_check_unavailable" in no_live["problems"]
        still_running = ic.record_session_verdict(
            fixture["staging_root"],
            session_id="closure",
            live=fixture["live_map"],
            session=_retained(fixture, "closure", prepared["nonce"], running=True),
            live_closed=lambda: True,
        )
        assert not still_running["ok"] and "owned_processes_running" in still_running["problems"]
        concurrent_live = ic.record_session_verdict(
            fixture["staging_root"],
            session_id="closure",
            live=fixture["live_map"],
            session=_retained(fixture, "closure", prepared["nonce"]),
            live_closed=lambda: False,
        )
        assert not concurrent_live["ok"] and "live_game_running" in concurrent_live["problems"]
        assert ic.load_open_record(fixture["staging_root"], "closure")["status"] == "open"


def test_failed_session_leaves_persistent_global_lockout():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "failed")
        failed = ic.record_session_failure(fixture["staging_root"], session_id="failed", reason="supervision_failed")
        assert failed["ok"] and failed["lockout"] is True
        assert ic.lockout(fixture["staging_root"])["locked"] is True
        blocked = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="next",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert not blocked["ok"] and "certificate_locked_out" in blocked["problems"]
        assert ic.acknowledge_lockout(fixture["staging_root"], operator="user", reason="reviewed")["ok"]
        allowed = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="next",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert allowed["ok"], allowed
        receipts = (fixture["staging_root"] / "evidence" / "sessions" / "receipts.jsonl").read_text(encoding="utf-8")
        assert '"verdict":"failed"' in receipts


def test_no_spawn_closure_is_measured():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "never-spawned")
        closed = ic.record_session_no_spawn(
            fixture["staging_root"], session_id="never-spawned", live=fixture["live_map"]
        )
        assert closed["ok"] and closed["code"] == "session_no_spawn_closed"
        assert closed["receipt"]["verdict"] == "no_spawn"
        assert ic.lockout(fixture["staging_root"])["locked"] is False

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "diff")
        (fixture["live_map"]["appdata"] / "Mods" / "x.lua").write_text("changed", encoding="utf-8")
        revoked = ic.record_session_no_spawn(fixture["staging_root"], session_id="diff", live=fixture["live_map"])
        assert not revoked["ok"] and revoked["code"] == "live_byte_diff_revoked"
        assert ic.lockout(fixture["staging_root"])["locked"] is True

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "spawned")
        ic.bind_open_session(fixture["staging_root"], "spawned", pids={"bootstrap": [7]}, spawn_time=time.time() - 1)
        refused = ic.record_session_no_spawn(
            fixture["staging_root"], session_id="spawned", live=fixture["live_map"]
        )
        assert not refused["ok"] and refused["problems"] == ["session_was_spawned"]


def test_verdict_requires_backup_and_refuses_reuse():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        unverified = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="nobackup",
            closed_check=lambda: True,
            phase="P1A",
        )
        assert not unverified["ok"] and "backup_verify_required" in unverified["problems"]
        denied = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="denied",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=lambda: {"ok": False},
        )
        assert not denied["ok"] and "backup_not_verified" in denied["problems"]
        prepared = _prepare_for_verdict(fixture, "reuse")
        assert ic.record_session_verdict(
            fixture["staging_root"],
            session_id="reuse",
            live=fixture["live_map"],
            session=_retained(fixture, "reuse", prepared["nonce"]),
            live_closed=lambda: True,
        )["ok"]
        again = ic.record_session_verdict(
            fixture["staging_root"], session_id="reuse", live=fixture["live_map"]
        )
        assert not again["ok"] and again["code"] == "session_already_closed"


def test_prepare_session_is_exclusive_and_single_nonce_owner():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        first = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="one",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert first["ok"] and isinstance(first["nonce"], str) and first["nonce"]
        second = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="two",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert not second["ok"] and "session_already_open" in second["problems"]


def test_prepare_session_requires_closed_check_and_rotates_probes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        refused = ic.prepare_session(fixture["staging_root"], live=fixture["live_map"], session_id="p1")
        assert not refused["ok"] and "closed_check_required" in refused["problems"]
        open_game = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="p1",
            closed_check=lambda: False,
        )
        assert not open_game["ok"] and "live_not_closed" in open_game["problems"]
        prepared = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="p1",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert prepared["ok"] and isinstance(prepared["nonce"], str) and prepared["nonce"]
        assert prepared["removed_probes"]
        for role in list(staging.ROLES) + [staging.BOOTSTRAP_ROLE]:
            save = staging._paths_for_role(fixture["staging_root"], role).data / "Balatro"
            assert not (save / staging.PROBE_MAIN).exists()


def test_prepare_session_rotates_old_attestation():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        paths = staging.role_paths(fixture["staging_root"], "ai")
        target = staging.launcher_attestation_path(paths)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("{}\n", encoding="utf-8")
        prepared = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="new",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert prepared["ok"] and prepared["removed_attestations"]
        for role in staging.ROLES:
            assert not staging.launcher_attestation_path(staging.role_paths(fixture["staging_root"], role)).exists()


def test_lockout_is_global_and_only_cleared_by_explicit_ack():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        staging_root = fixture["staging_root"]
        ic._write_lockout(staging_root, {"locked": True, "reason": "live_byte_diff", "session_id": "x"})
        locked = ic.lockout(staging_root)
        assert locked["locked"] is True and locked["lockout_id"]
        withdrawn = ic.prepare_session(
            staging_root, live=fixture["live_map"], session_id="after", closed_check=lambda: True
        )
        assert not withdrawn["ok"] and "certificate_locked_out" in withdrawn["problems"]
        ack = ic.acknowledge_lockout(staging_root, operator="user", reason="reviewed")
        assert ack["ok"]
        assert ic.lockout(staging_root)["locked"] is False
        prepared = ic.prepare_session(
            staging_root,
            live=fixture["live_map"],
            session_id="after",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(fixture),
        )
        assert prepared["ok"], prepared


def test_launcher_attestation_derives_inputs_and_writes_atomically():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            assert _build(fixture, tools_root=root)["ok"]
            staging_root = fixture["staging_root"]
            spawn_time = time.time() - 1
            prepared = ic.prepare_session(
                staging_root,
                live=fixture["live_map"],
                session_id="att",
                port=PORT,
                closed_check=lambda: True,
                phase=ic.MATCH,
                backup_verify=_backup_verify(fixture),
            )
            assert prepared["ok"], prepared
            nonce = prepared["nonce"]
            ic.bind_open_session(staging_root, "att", pids={"human": [1], "ai": [2]}, spawn_time=spawn_time)
            for role in staging.ROLES:
                _write_probes(staging.role_paths(staging_root, role), nonce=nonce)

            wrong_port = ic.write_launcher_attestation(
                staging_root,
                session_id="att",
                nonce=nonce,
                control_port=0,
                port=PORT,
                spawn_time=spawn_time,
                live=fixture["live_map"],
            )
            assert not wrong_port["ok"] and "bad_control_port" in wrong_port["problems"]
            no_pids = ic.write_launcher_attestation(
                staging_root,
                session_id="missing",
                nonce=nonce,
                control_port=9000,
                port=PORT,
                spawn_time=spawn_time,
                live=fixture["live_map"],
            )
            assert not no_pids["ok"] and "open_session_missing" in no_pids["problems"]

            ai_paths = staging.role_paths(staging_root, "ai")
            ai_save = ai_paths.data / "Balatro"
            (ai_save / staging.PROBE_MP).write_text(
                f"probe=mp\npatch={staging.PATCH_ID}\nnonce=wrong\nurl=127.0.0.1\nport={PORT}\nmods={ai_paths.mods}\n",
                encoding="utf-8",
            )
            refused = ic.write_launcher_attestation(
                staging_root,
                session_id="att",
                nonce=nonce,
                control_port=9000,
                port=PORT,
                spawn_time=spawn_time,
                live=fixture["live_map"],
            )
            assert not refused["ok"] and any(problem.startswith("ai:") for problem in refused["problems"])
            for role in staging.ROLES:
                assert not staging.launcher_attestation_path(staging.role_paths(staging_root, role)).exists()

            _write_probes(ai_paths, nonce=nonce)
            written = ic.write_launcher_attestation(
                staging_root,
                session_id="att",
                nonce=nonce,
                control_port=9000,
                port=PORT,
                spawn_time=spawn_time,
                live=fixture["live_map"],
            )
            assert written["ok"], written
        for role in staging.ROLES:
            paths = staging.role_paths(fixture["staging_root"], role)
            path = Path(written["attestations"][role])
            assert path == staging.launcher_attestation_path(paths)
            assert not staging.is_within(paths.mods, path, allow_root=True)
            payload = json.loads(path.read_text(encoding="utf-8"))
            assert payload["schema"] == staging.LAUNCHER_ATTESTATION_SCHEMA
            assert payload["ok"] is True and payload["nonce"] == nonce and payload["role"] == role
            assert payload["expected_role_mods_root"] == str(paths.mods)
            assert payload["expected_role_save_root"] == str(paths.data / "Balatro")
            assert payload["probe_sha256"]
            assert ic._is_sha256(payload["content_hash"])
            assert "credential" not in json.dumps(payload).lower()


def test_prepare_session_requires_prerequisite_receipts():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            refused = ic.prepare_session(
                fixture["staging_root"],
                live=fixture["live_map"],
                session_id="p1b-first",
                port=PORT,
                closed_check=lambda: True,
                phase="P1B",
            )
        assert not refused["ok"] and "phase_prerequisite_missing:p1a" in refused["problems"]


def test_host_wrapper_check_isolation_proof_delegates():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert _build(fixture, tools_root=root)["ok"]
        with synthetic_tools(root):
            wrapped = staging.check_isolation_proof(fixture["staging_root"], live=fixture["live_map"])
        assert wrapped["ok"] and wrapped["certificate_id"]


def test_match_phase_requires_a_current_certificate():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert ic.MATCH not in ic.REQUIRED_PHASES
        without = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="match-a",
            port=PORT,
            closed_check=lambda: True,
            phase=ic.MATCH,
            backup_verify=_backup_verify(fixture),
        )
        assert not without["ok"]
        assert any(problem.startswith("certificate_not_valid") for problem in without["problems"])
        with synthetic_tools(root):
            assert _build(fixture, tools_root=root)["ok"]
            prepared = ic.prepare_session(
                fixture["staging_root"],
                live=fixture["live_map"],
                session_id="match-b",
                port=PORT,
                closed_check=lambda: True,
                phase=ic.MATCH,
                backup_verify=_backup_verify(fixture),
            )
        assert prepared["ok"], prepared
        assert prepared["phase"] == ic.MATCH
        assert prepared["certificate_id"]


def test_match_phase_cannot_be_recorded_as_a_measurement_receipt():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        problems = ic._phase_receipt_problems(ic.MATCH)
        assert problems == ["unknown_phase"]


def test_record_receipt_failure_raises_global_lockout():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            prepared = ic.prepare_session(
                fixture["staging_root"],
                live=fixture["live_map"],
                session_id="bad-receipt",
                closed_check=lambda: True,
                phase="P1A",
                backup_verify=_backup_verify(fixture),
            )
            assert prepared["ok"]
            session = _retained(fixture, "bad-receipt", prepared["nonce"], running=True)
            result = ic.record_phase_receipt(
                fixture["staging_root"],
                phase="P1A",
                session_id="bad-receipt",
                session=session,
                live=fixture["live_map"],
            )
        assert not result["ok"] and "owned_processes_running" in result["problems"]
        assert ic.lockout(fixture["staging_root"])["locked"] is True


def _phase_setup(phase):
    """The tool-owned pre-spawn setup the launcher persists for a measurement phase."""
    if phase == "P2_INITIAL":
        return _fake_dead_port_setup()
    if phase in ("P2_CLOSE", "P2_SILENT"):
        return {"kind": "listener", "port": PORT, "mode": phase}
    if phase == "CRASH":
        return {"kind": "crash", "stimulus": staging.MEASUREMENT_CRASH_STIMULUS}
    return None


def _prepare_and_probes(fixture, phase, session_id, **kwargs):
    setup = _phase_setup(phase)
    prepared = ic.prepare_session(
        fixture["staging_root"],
        live=fixture["live_map"],
        session_id=session_id,
        port=PORT if phase != "P1A" else None,
        closed_check=lambda: True,
        phase=phase,
        backup_verify=_backup_verify(fixture),
        measurement_setup=setup,
        **kwargs,
    )
    assert prepared["ok"], prepared
    bind = time.time() - 1
    ic.bind_open_session(fixture["staging_root"], session_id, pids={"bootstrap": [1]}, spawn_time=bind)
    _write_probes(staging.bootstrap_paths(fixture["staging_root"]), nonce=prepared["nonce"], phase=phase)
    for role in staging.ROLES:
        _write_probes(staging.role_paths(fixture["staging_root"], role), nonce=prepared["nonce"], phase=phase)
    return prepared, bind


# --- R1: real backup evidence bound to the measured before-snapshot -----------

def test_r1_backup_evidence_binds_before_snapshot():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        staging_root = fixture["staging_root"]
        bogus = ic.prepare_session(
            staging_root, live=fixture["live_map"], session_id="r1-bogus",
            closed_check=lambda: True, phase="P1A", backup_id="caller-label",
            backup_verify=_backup_verify(fixture),
        )
        assert not bogus["ok"] and "backup_id_mismatch" in bogus["problems"]

        label = launch_practice.check_backup_evidence(fixture["backup_root"], fixture["sources"])["backup_label"]
        accepted = ic.prepare_session(
            staging_root, live=fixture["live_map"], session_id="r1-label",
            closed_check=lambda: True, phase="P1A", backup_id=label,
            backup_verify=_backup_verify(fixture),
        )
        assert accepted["ok"] and ic._is_sha256(accepted["backup_id"])
        assert ic.load_open_record(staging_root, "r1-label")["backup_label"] == label
        assert ic.record_session_no_spawn(
            staging_root, session_id="r1-label", live=fixture["live_map"]
        )["ok"]

        # A live byte drift makes the fresh-check refuse it.
        (fixture["live_map"]["appdata"] / "Mods" / "x.lua").write_text("drift", encoding="utf-8")
        drifted = ic.prepare_session(
            staging_root, live=fixture["live_map"], session_id="r1-drift",
            closed_check=lambda: True, phase="P1A", backup_verify=_backup_verify(fixture),
        )
        assert not drifted["ok"] and "backup_not_verified" in drifted["problems"]

        # A stale-but-consistent manifest is caught by the before-snapshot tie.
        tie = ic.prepare_session(
            staging_root, live=fixture["live_map"], session_id="r1-tie",
            closed_check=lambda: True, phase="P1A",
            backup_verify=lambda: launch_practice.check_backup_evidence(fixture["backup_root"]),
        )
        assert not tie["ok"]
        assert any(problem.startswith("backup_snapshot_mismatch") for problem in tie["problems"])


def test_r1_backup_manifest_mutation_changes_identity_and_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        first = launch_practice.check_backup_evidence(fixture["backup_root"], fixture["sources"])
        manifest_path = fixture["backup_root"] / launch_practice.BACKUP_MANIFEST_NAME
        body = json.loads(manifest_path.read_text(encoding="utf-8"))
        body["label"] = body.get("label", "") + "-mutated"
        manifest_path.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        second = launch_practice.check_backup_evidence(fixture["backup_root"])
        assert second["manifest_sha256"] != first["manifest_sha256"]
        assert second["backup_id"] != first["backup_id"]
        stale = ic.prepare_session(
            fixture["staging_root"], live=fixture["live_map"], session_id="r1-stale",
            closed_check=lambda: True, phase="P1A", backup_id=first["backup_id"],
            backup_verify=_backup_verify(fixture),
        )
        assert not stale["ok"] and "backup_id_mismatch" in stale["problems"]

        # A mutated copy is caught by the verified entry manifest, not just the id.
        entry = body["entries"]["appdata"]
        Path(entry["dir"], "Mods", "x.lua").write_text("tampered copy", encoding="utf-8")
        assert not launch_practice.check_backup_evidence(fixture["backup_root"])["ok"]


def test_r1_missing_live_root_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        short_live = dict(fixture["live_map"])
        dropped = next(key for key in short_live if key.startswith("steam_userdata/"))
        short_live.pop(dropped)
        verdict = ic.prepare_session(
            fixture["staging_root"], live=short_live, session_id="r1-missing",
            closed_check=lambda: True, phase="P1A",
            backup_verify=lambda: launch_practice.check_backup_evidence(fixture["backup_root"]),
        )
        assert not verdict["ok"] and "backup_roots_mismatch" in verdict["problems"]


# --- R2: required live-closed callback and unexpected-game supervision ---------

def test_r2_phase_receipt_requires_live_closed_callback():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "r2-a")
        session = _FakeSession("r2-a", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        result = ic.record_phase_receipt(
            fixture["staging_root"], phase="P1A", session_id="r2-a", session=session,
            live=fixture["live_map"],
        )
        assert not result["ok"] and "live_closed_check_unavailable" in result["problems"]
        assert ic.lockout(fixture["staging_root"])["locked"] is True

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "r2-b")
        session = _FakeSession("r2-b", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        result = ic.record_phase_receipt(
            fixture["staging_root"], phase="P1A", session_id="r2-b", session=session,
            live=fixture["live_map"], live_closed=lambda: False,
        )
        assert not result["ok"] and "live_game_running" in result["problems"]
        assert ic.load_open_record(fixture["staging_root"], "r2-b")["status"] == "failed"
        assert ic.lockout(fixture["staging_root"])["locked"] is True


# --- H3: CRASH/P2 are tool-derived; the caller observation is gone -------------

def test_h3_caller_observation_is_not_accepted():
    assert "observation" not in inspect.signature(ic.record_phase_receipt).parameters
    assert "observation" not in inspect.signature(launch_practice.execute_measurement_phase).parameters
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "h3-a")
        session = _FakeSession("h3-a", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        try:
            ic.record_phase_receipt(
                fixture["staging_root"], phase="P1A", session_id="h3-a", session=session,
                live=fixture["live_map"], live_closed=lambda: True,
                observation={"crash_observed": True},
            )
        except TypeError:
            pass
        else:
            raise AssertionError("caller observation must not be accepted")


def test_receipt_binds_requested_phase_and_port_to_prepared_record():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "bind-phase")
        session = _FakeSession("bind-phase", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        wrong_phase = ic.record_phase_receipt(
            fixture["staging_root"], phase="P1B", session_id="bind-phase", session=session,
            live=fixture["live_map"], live_closed=lambda: True,
        )
        assert not wrong_phase["ok"] and "prepared_phase_mismatch" in wrong_phase["problems"]
        assert ic.load_open_record(fixture["staging_root"], "bind-phase")["status"] == "failed"

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            for phase in ("P1A", "P1B", "FULL_P1"):
                assert _record_phase(fixture, phase)["ok"]
        prepared, bind = _prepare_and_probes(fixture, "P2_INITIAL", "bind-port")
        session = _FakeSession(
            "bind-port", fixture["staging_root"], prepared["nonce"], bind, ("ai",), **_end_kwargs("P2_INITIAL")
        )
        wrong_port = ic.record_phase_receipt(
            fixture["staging_root"], phase="P2_INITIAL", session_id="bind-port", session=session,
            live=fixture["live_map"], port=PORT + 1, live_closed=lambda: True,
        )
        assert not wrong_port["ok"] and "prepared_port_mismatch" in wrong_port["problems"]


def test_p2_classifier_ignores_foreign_flags_and_start_marker():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            for phase in ("P1A", "P1B", "FULL_P1"):
                assert _record_phase(fixture, phase)["ok"]
        prepared, bind = _prepare_and_probes(fixture, "P2_INITIAL", "p2-foreign")
        role = staging.role_paths(fixture["staging_root"], "ai")
        artifact = role.data / "Balatro" / staging.PROBE_P2
        # No schema and only foreign flags: the classifier never infers a covered
        # subgate from a start marker or an invented flag, so the P2 phase refuses.
        artifact.write_text(
            f"probe=p2\npatch={staging.PATCH_ID}\nnonce={prepared['nonce']}\nurl=127.0.0.1\nport={PORT}\n"
            f"mods={role.mods}\nsave={role.data / 'Balatro'}\nattempts=1\nstarted=1\n"
            "connect_refused=true\nconnect_failed=true\nfailure=true\nreconnect=3\nkeepalive=true\n",
            encoding="utf-8",
        )
        session = _FakeSession(
            "p2-foreign", fixture["staging_root"], prepared["nonce"], bind, ("ai",), **_end_kwargs("P2_INITIAL")
        )
        result = ic.record_phase_receipt(
            fixture["staging_root"], phase="P2_INITIAL", session_id="p2-foreign", session=session,
            live=fixture["live_map"], port=PORT, live_closed=lambda: True,
        )
        assert not result["ok"]
        assert any(problem.startswith("P2_coverage_incomplete") for problem in result["problems"]), result


def test_p2_receipt_coverage_is_rederived_from_copied_artifact():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            receipt_ids = _receipt_ids(fixture)
            old_id = receipt_ids["P2_INITIAL"]
            path = ic._receipt_path(fixture["staging_root"], old_id)
            body = json.loads(path.read_text(encoding="utf-8"))
            # A forged receipt under-claims what its own copied artifact observed.
            body["measured"]["covered_subgates"] = []
            body["measured"]["pending_subgates"] = ["initial_failure"]
            body["measured"]["coverage_complete"] = False
            forged = {key: value for key, value in body.items() if key != "receipt_id"}
            new_id = ic._digest(forged)
            body["receipt_id"] = new_id
            ic._receipt_path(fixture["staging_root"], new_id).write_text(
                json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            receipt_ids["P2_INITIAL"] = new_id
            verdict = ic.build_certificate(
                fixture["staging_root"], receipt_ids=receipt_ids, live=fixture["live_map"], port=PORT
            )
        assert not verdict["ok"]
        assert any("P2_coverage_not_rederived" in problem for problem in verdict["problems"]), verdict


def test_h3_crash_and_p2_derive_from_tool_evidence():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            ids = _receipt_ids(fixture)
        crash = ic.load_phase_receipt(fixture["staging_root"], ids["CRASH"])
        assert crash["measured"]["crash_exit_codes"] == _CRASH_EXITS
        assert crash["measured"]["crash_stimulus"] == staging.MEASUREMENT_CRASH_STIMULUS
        assert crash["measured"]["crash_end_mode"] == staging.MEASUREMENT_END_MODE
        assert crash["measured"]["crash_observed"] is True
        p2 = ic.load_phase_receipt(fixture["staging_root"], ids["P2_INITIAL"])
        assert p2["measured"]["dead_port"] == PORT
        assert p2["measured"]["pinned_endpoint"]["url"] == "127.0.0.1"
        assert p2["measured"]["covered_subgates"] == ["initial_failure"]
        assert p2["measured"]["pending_subgates"] == []
        assert p2["probes"]["ai"]["p2"]["copy_sha256"]
        assert p2["measurement_artifact"]["copy_sha256"]
        close = ic.load_phase_receipt(fixture["staging_root"], ids["P2_CLOSE"])
        assert close["measured"]["closure_path"] == "close_branch"
        silent = ic.load_phase_receipt(fixture["staging_root"], ids["P2_SILENT"])
        assert silent["measured"]["covered_subgates"] == ["keepalive"]


def test_h3_p2_pending_subgates_do_not_broad_pass():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            ids = {}
            for phase in ("P1A", "P1B", "FULL_P1"):
                result = _record_phase(fixture, phase)
                assert result["ok"], (phase, result)
                ids[phase] = result["receipt_id"]
            prepared, bind = _prepare_and_probes(fixture, "P2_INITIAL", "p2-pending")
            # A real stage-start marker is NOT a measured connection failure: with no
            # schema/attempt evidence, the P2 phase can never be recorded as passed.
            p2_path = staging.role_paths(fixture["staging_root"], "ai").data / "Balatro" / staging.PROBE_P2
            p2_path.write_text(
                f"probe=p2\npatch={staging.PATCH_ID}\nnonce={prepared['nonce']}\nurl=127.0.0.1\n"
                f"port={PORT}\nmods={staging.role_paths(fixture['staging_root'], 'ai').mods}\n"
                f"save={staging.role_paths(fixture['staging_root'], 'ai').data / 'Balatro'}\nstarted=1\n",
                encoding="utf-8",
            )
            session = _FakeSession(
                "p2-pending", fixture["staging_root"], prepared["nonce"], bind, ("ai",), **_end_kwargs("P2_INITIAL")
            )
            result = ic.record_phase_receipt(
                fixture["staging_root"], phase="P2_INITIAL", session_id="p2-pending", session=session,
                live=fixture["live_map"], port=PORT, live_closed=lambda: True,
            )
            assert not result["ok"]
            assert "P2_coverage_incomplete:initial_failure" in result["problems"], result
        # A P2 phase that cannot prove its own coverage fails closed and locks out;
        # it is never recorded as a passed receipt.
        assert ic.lockout(fixture["staging_root"])["locked"] is True
        assert ic.load_open_record(fixture["staging_root"], "p2-pending")["status"] == "failed"


def _run_phase_with_listener_overrides(fixture, session_id, artifact, listener_overrides):
    ai = staging.role_paths(fixture["staging_root"], "ai")
    save = ai.data / "Balatro"
    (save / staging.PROBE_P2).write_text(
        f"probe=p2\nschema={staging.P2_OBSERVER_SCHEMA}\npatch={staging.PATCH_ID}\nnonce=<NONCE>\n"
        f"url=127.0.0.1\nport={PORT}\nmods={ai.mods}\nsave={save}\n" + artifact,
        encoding="utf-8",
    )
    listener = {
        "accepted": "1", "peer_is_owned_ai": "true", "sent_bytes": "0",
        "peer_pid": "100", "peer_host": "127.0.0.1", "listener_pid": "1",
        "received_bytes": "8", "received_total_bytes": "8",
        "closed": "true", "fin": "true", "close_time": "100.0", "open_until": "100.0",
        "peer_eof": "false", "peer_reset": "false", "eof_time": "",
    }
    listener.update(listener_overrides)
    (save / staging.PROBE_LISTENER).write_text(
        f"probe=listener\nschema={staging.LISTENER_SCHEMA}\npatch={staging.PATCH_ID}\nnonce=<NONCE>\n"
        f"phase=P2_CLOSE\nport={PORT}\nfamilies=ipv4\nexclusive=true\nsave={save}\n"
        + "\n".join(f"{key}={value}" for key, value in listener.items()) + "\n",
        encoding="utf-8",
    )


def _p2_close_refusal(fixture, session_id, listener_overrides, artifact=P2_CLOSE_ARTIFACT):
    with synthetic_tools(fixture["root"]):
        for phase in ("P1A", "P1B", "FULL_P1"):
            assert _record_phase(fixture, phase)["ok"], phase
    prepared, bind = _prepare_and_probes(fixture, "P2_CLOSE", session_id)
    _run_phase_with_listener_overrides(fixture, session_id, artifact, listener_overrides)
    # Rewrite the nonce placeholders to the real session nonce.
    ai = staging.role_paths(fixture["staging_root"], "ai")
    for name in (staging.PROBE_P2, staging.PROBE_LISTENER):
        target = ai.data / "Balatro" / name
        target.write_text(target.read_text(encoding="utf-8").replace("<NONCE>", prepared["nonce"]), encoding="utf-8")
    session = _FakeSession(
        session_id, fixture["staging_root"], prepared["nonce"], bind, ("ai",), **_end_kwargs("P2_CLOSE")
    )
    return ic.record_phase_receipt(
        fixture["staging_root"], phase="P2_CLOSE", session_id=session_id, session=session,
        live=fixture["live_map"], port=PORT, live_closed=lambda: True,
    )


def test_p2_close_refuses_wrong_owner_and_sent_bytes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        wrong_owner = _p2_close_refusal(fixture, "p2-wrong-owner", {"peer_is_owned_ai": "false"})
        assert not wrong_owner["ok"]
        assert "P2_coverage_incomplete:closure" in wrong_owner["problems"], wrong_owner

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        sent = _p2_close_refusal(fixture, "p2-sent-bytes", {"sent_bytes": "1"})
        assert not sent["ok"]
        assert "P2_coverage_incomplete:closure" in sent["problems"], sent


def test_p2_reconnect_coverage_never_less_from_recovered_or_unfinished_cycles():
    # N4: neither "failed once then recovered" nor "recovered then unfinished"
    # proves a bounded exhausted retry cycle.
    dead = PORT
    base = {
        "schema": staging.P2_OBSERVER_SCHEMA, "url": "127.0.0.1", "port": str(PORT),
        "connect_attempts": "4", "connect_successes": "1", "connect_failures": "3",
        "first_result": "1", "reconnects": "1", "reconnect_failures": "1",
    }
    # Case 1: a cycle that recovered (outcome recovered) is never a bounded failure.
    recovered = dict(base)
    recovered.update({
        "cycle1_cause": "close", "cycle1_start_time": "100.0", "cycle1_outcome": "recovered",
        "cycle1_end_time": "106.0", "cycle1_attempt_count": "2",
        "cycle1_attempt1_start": "102.0", "cycle1_attempt1_time": "102.0", "cycle1_attempt1_result": "none",
        "cycle1_attempt2_start": "106.0", "cycle1_attempt2_time": "106.0", "cycle1_attempt2_result": "1",
    })
    assert "reconnect" not in ic._p2_derive(recovered, dead)["covered"]
    # Case 2: a recovered cycle followed by an unfinished cycle with one failure.
    overstate = dict(base)
    overstate.update({
        "cycle1_cause": "close", "cycle1_start_time": "100.0", "cycle1_outcome": "recovered",
        "cycle1_end_time": "106.0", "cycle1_attempt_count": "2",
        "cycle1_attempt1_start": "102.0", "cycle1_attempt1_time": "102.0", "cycle1_attempt1_result": "none",
        "cycle1_attempt2_start": "106.0", "cycle1_attempt2_time": "106.0", "cycle1_attempt2_result": "1",
        "cycle2_cause": "close", "cycle2_start_time": "110.0", "cycle2_outcome": "unfinished",
        "cycle2_end_time": "112.0", "cycle2_attempt_count": "1",
        "cycle2_attempt1_start": "112.0", "cycle2_attempt1_time": "112.0", "cycle2_attempt1_result": "none",
    })
    assert "reconnect" not in ic._p2_derive(overstate, dead)["covered"]
    # A genuinely completed, bounded, exhausted cycle does cover it.
    exhausted = dict(base)
    exhausted.update({
        "cycle1_cause": "close", "cycle1_start_time": "100.0", "cycle1_outcome": "exhausted",
        "cycle1_end_time": "114.0", "cycle1_attempt_count": "3",
        "cycle1_attempt1_start": "102.0", "cycle1_attempt1_time": "102.0", "cycle1_attempt1_result": "none",
        "cycle1_attempt2_start": "106.0", "cycle1_attempt2_time": "106.0", "cycle1_attempt2_result": "none",
        "cycle1_attempt3_start": "114.0", "cycle1_attempt3_time": "114.0", "cycle1_attempt3_result": "none",
    })
    assert "reconnect" in ic._p2_derive(exhausted, dead)["covered"]


# --- F1: SILENT listener hold vs the game's own expiry EOF ---------------------

def _silent_derived():
    cycle = {
        "cause": "keepalive", "start_time": 145.0, "outcome": "exhausted", "end_time": 159.0,
        "attempts": [
            {"start": 147.0, "time": 147.0, "result": "none"},
            {"start": 151.0, "time": 151.0, "result": "none"},
            {"start": 159.0, "time": 159.0, "result": "none"},
        ],
    }
    return {
        "schema_ok": True, "first_result": "1", "first_success_time": 100.0,
        "cycles": [cycle], "receive_errors": [],
        "keepalive_push_times": [120.0, 125.0, 130.0, 135.0, 140.0],
    }


def _silent_listener(**override):
    listener = {
        "accepted": 1, "peer_is_owned_ai": True, "sent_bytes": 0,
        "closed": False, "fin": False, "open_until": 160.0,
        "peer_eof": True, "peer_reset": False, "eof_time": 145.0,
    }
    listener.update(override)
    return listener


def test_p2_silent_requires_a_legitimate_expiry_eof_and_hold_through_cycle():
    derived = _silent_derived()
    positive = ic._p2_phase_coverage("P2_SILENT", derived, _silent_listener())
    assert "keepalive" in positive["covered"], positive

    # A close well before the fifth push + retry timeout is an early EOF, not the
    # game's expiry close, and must not cover.
    early = ic._p2_phase_coverage("P2_SILENT", derived, _silent_listener(eof_time=120.0))
    assert "keepalive" not in early["covered"], early

    # A reset is never the legitimate expiry close, even in the right window.
    reset = ic._p2_phase_coverage(
        "P2_SILENT", derived, _silent_listener(peer_eof=False, peer_reset=True, eof_time=147.0)
    )
    assert "keepalive" not in reset["covered"], reset

    # A tool that released the connection before the cycle ended never held through.
    released = ic._p2_phase_coverage("P2_SILENT", derived, _silent_listener(open_until=150.0))
    assert "keepalive" not in released["covered"], released

    # A missing hold is still refused.
    missing = ic._p2_phase_coverage("P2_SILENT", derived, _silent_listener(open_until=None))
    assert "keepalive" not in missing["covered"], missing


def _p2_initial_refusal(fixture, session_id, *, after_exit_proof, artifact=None):
    with synthetic_tools(fixture["root"]):
        for phase in ("P1A", "P1B", "FULL_P1"):
            assert _record_phase(fixture, phase)["ok"], phase
    prepared, bind = _prepare_and_probes(fixture, "P2_INITIAL", session_id)
    if artifact is not None:
        ai = staging.role_paths(fixture["staging_root"], "ai")
        (ai.data / "Balatro" / staging.PROBE_P2).write_text(
            f"probe=p2\nschema={staging.P2_OBSERVER_SCHEMA}\npatch={staging.PATCH_ID}\n"
            f"nonce={prepared['nonce']}\nurl=127.0.0.1\nport={PORT}\nmods={ai.mods}\n"
            f"save={ai.data / 'Balatro'}\n" + artifact,
            encoding="utf-8",
        )
    session = _FakeSession(
        session_id, fixture["staging_root"], prepared["nonce"], bind, ("ai",), **_end_kwargs("P2_INITIAL")
    )
    return ic.record_phase_receipt(
        fixture["staging_root"], phase="P2_INITIAL", session_id=session_id, session=session,
        live=fixture["live_map"], port=PORT, live_closed=lambda: True,
        after_exit_proof=after_exit_proof,
    )


def test_p2_initial_requires_the_after_exit_dead_port_proof():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        missing = _p2_initial_refusal(fixture, "p2-no-after", after_exit_proof=None)
        assert not missing["ok"], missing
        assert "P2_after_exit_dead_port_missing" in missing["problems"], missing

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        # F4/F11: a timed-out probe is never a refusal, so it cannot prove the port
        # is dead after exit.
        timed_out = {
            "ok": True, "kind": "dead_port", "dead_port": PORT, "host": "127.0.0.1",
            "refused": True, "timed_out": True,
            "listener_absent": {"ipv4": True, "ipv6": True}, "attempts": 3,
            "timings": [0.5, 0.5, 0.5], "measured_unix": int(time.time()),
        }
        bad = _p2_initial_refusal(fixture, "p2-timeout-after", after_exit_proof=timed_out)
        assert not bad["ok"], bad
        assert "P2_after_exit_dead_port_missing" in bad["problems"], bad


def test_p2_listener_copy_is_bound_to_receipt_identity_and_ownership():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        wrong_peer = _p2_close_refusal(fixture, "p2-peer-pid", {"peer_pid": "999"})
        assert not wrong_peer["ok"], wrong_peer
        assert "P2_listener_peer_pid_not_owned" in wrong_peer["problems"], wrong_peer

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        bad_total = _p2_close_refusal(
            fixture, "p2-total", {"received_bytes": "8", "received_total_bytes": "4"}
        )
        assert not bad_total["ok"], bad_total
        assert "P2_listener_received_total_inconsistent" in bad_total["problems"], bad_total


def test_crash_probe_message_must_carry_the_stimulus():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            for phase in ("P1A", "P1B", "FULL_P1"):
                assert _record_phase(fixture, phase)["ok"], phase
        prepared, bind = _prepare_and_probes(fixture, "CRASH", "crash-msg")
        # F9: a probe whose message omits the prepared stimulus cannot prove this
        # crash was the tool's own env-gated one.
        for role in ("human", "ai"):
            paths = staging.role_paths(fixture["staging_root"], role)
            (paths.data / "Balatro" / staging.PROBE_CRASH).write_text(
                f"probe=crash\npatch={staging.PATCH_ID}\nnonce={prepared['nonce']}\n"
                f"save={paths.data / 'Balatro'}\nmsg=staged crash without the marker\n",
                encoding="utf-8",
            )
        session = _FakeSession(
            "crash-msg", fixture["staging_root"], prepared["nonce"], bind, ic.PHASE_ROLES["CRASH"],
            exit_codes=_CRASH_EXITS, **_end_kwargs("CRASH"),
        )
        result = ic.record_phase_receipt(
            fixture["staging_root"], phase="CRASH", session_id="crash-msg", session=session,
            live=fixture["live_map"], port=PORT, live_closed=lambda: True,
        )
        assert not result["ok"], result
        assert "CRASH_probe_unbound" in result["problems"], result


# --- M2: strong probe/lovely checkers inside receipts -------------------------

def test_m2_receipt_rejects_wrong_mods_root_and_missing_dump():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "m2-a")
        paths = staging.bootstrap_paths(fixture["staging_root"])
        save = paths.data / "Balatro"
        (save / staging.PROBE_GUARD).write_text(
            f"probe=guard\npatch={staging.PATCH_ID}\nnonce={prepared['nonce']}\nsave={save}\n"
            f"lovely_mod_dir={root / 'elsewhere'}\nmods={paths.mods}\n",
            encoding="utf-8",
        )
        session = _FakeSession("m2-a", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        wrong = ic.record_phase_receipt(
            fixture["staging_root"], phase="P1A", session_id="m2-a", session=session,
            live=fixture["live_map"], live_closed=lambda: True,
        )
        assert not wrong["ok"] and any("lovely_mod_dir_not_exact" in problem for problem in wrong["problems"])

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "m2-b")
        dump_dir = staging.bootstrap_paths(fixture["staging_root"]).mods / staging.LOVELY_DIR_NAME / staging.LOVELY_DUMP_DIR_NAME
        shutil.rmtree(dump_dir)
        session = _FakeSession("m2-b", fixture["staging_root"], prepared["nonce"], bind, ("bootstrap",))
        missing = ic.record_phase_receipt(
            fixture["staging_root"], phase="P1A", session_id="m2-b", session=session,
            live=fixture["live_map"], live_closed=lambda: True,
        )
        assert not missing["ok"] and any("lovely_dump_missing" in problem for problem in missing["problems"])


# --- M3: the bound tool map cannot be emptied ---------------------------------

def test_m3_tool_binding_cannot_be_emptied():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            ids = _receipt_ids(fixture)
            empty = ic.build_certificate(
                fixture["staging_root"], receipt_ids=ids, live=fixture["live_map"], port=PORT, tools={}
            )
        assert not empty["ok"] and "bound_tools_incomplete" in empty["problems"]
        _current, problems = ic.collect_bound_tools_check({"tools": {}})
        assert "bound_tools_incomplete" in problems


# --- Easy lows in the same code ----------------------------------------------

def test_low_session_id_reuse_and_copy_manifests():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        assert "nonce" not in inspect.signature(ic.prepare_session).parameters
        prepared = ic.prepare_session(
            fixture["staging_root"], live=fixture["live_map"], session_id="low-reuse",
            closed_check=lambda: True, phase="P1A", backup_verify=_backup_verify(fixture),
        )
        assert prepared["ok"], prepared
        closed = ic.record_session_no_spawn(
            fixture["staging_root"], session_id="low-reuse", live=fixture["live_map"]
        )
        assert closed["ok"]
        again = ic.prepare_session(
            fixture["staging_root"], live=fixture["live_map"], session_id="low-reuse",
            closed_check=lambda: True, phase="P1A", backup_verify=_backup_verify(fixture),
        )
        assert not again["ok"] and "session_id_reused" in again["problems"]

        with synthetic_tools(root):
            receipt_ids = _receipt_ids(fixture)
        receipt = ic.load_phase_receipt(fixture["staging_root"], receipt_ids["P1A"])
        assert receipt["before_files"] and receipt["after_files"]
        layers = ic.collect_layer_m(fixture["staging_root"])
        assert layers["roles"]["ai"]["network_suppression"]["ok"] is True


def test_low_attestation_requires_match_phase():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        prepared, bind = _prepare_and_probes(fixture, "P1A", "low-att")
        refused = ic.write_launcher_attestation(
            fixture["staging_root"], session_id="low-att", nonce=prepared["nonce"],
            control_port=9000, port=PORT, spawn_time=bind, live=fixture["live_map"],
        )
        assert not refused["ok"] and "attestation_phase_not_match" in refused["problems"]


def _expect_open_records_error(staging_root, expected_code):
    try:
        ic.list_open_records(staging_root)
    except staging.StagingError as error:
        assert error.code == expected_code, (error.code, expected_code)
        return
    raise AssertionError(f"expected StagingError {expected_code}")


def test_list_open_records_fails_closed_on_corrupt_unknown_and_unenumerable():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp)
        open_dir = ic._open_dir(staging_root)
        open_dir.mkdir(parents=True, exist_ok=True)
        for name, status in (
            ("s-open", "open"),
            ("s-pending", "failed_pending"),
            ("s-passed", "passed"),
            ("s-closed", "closed"),
            ("s-failed", "failed"),
        ):
            (open_dir / f"{name}.json").write_text(
                json.dumps({"session_id": name, "status": status}), encoding="utf-8"
            )
        # Only blocking statuses are returned; recognized closed records are skipped.
        records = ic.list_open_records(staging_root)
        assert sorted(record["session_id"] for record in records) == ["s-open", "s-pending"]
        # Corrupt JSON is not "no session".
        corrupt = open_dir / "corrupt.json"
        corrupt.write_text("{not json", encoding="utf-8")
        _expect_open_records_error(staging_root, "open_record_corrupt")
        corrupt.unlink()
        # A non-dict record is refused.
        nondict = open_dir / "nondict.json"
        nondict.write_text("[1, 2, 3]", encoding="utf-8")
        _expect_open_records_error(staging_root, "open_record_invalid")
        nondict.unlink()
        # An unknown status is refused rather than silently dropped.
        unknown = open_dir / "unknown.json"
        unknown.write_text(json.dumps({"status": "teleported"}), encoding="utf-8")
        _expect_open_records_error(staging_root, "open_record_unknown_status")
        unknown.unlink()
        # A missing open directory genuinely lists nothing.
        assert ic.list_open_records(Path(tmp) / "absent") == []

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        open_dir = ic._open_dir(root)
        open_dir.parent.mkdir(parents=True, exist_ok=True)
        open_dir.write_text("not a directory", encoding="utf-8")
        _expect_open_records_error(root, "open_records_unreadable")


class _DumpPaths:
    def __init__(self, mods):
        self.mods = mods


def test_select_dump_files_binds_only_the_exact_patched_pretty_paths():
    with tempfile.TemporaryDirectory() as tmp:
        mods = Path(tmp) / "Mods"
        main_rel = staging.lovely_patched_dump_rel(staging.LOVELY_PATCHED_MAIN_REL)
        socket_rel = staging.lovely_patched_dump_rel(staging.MP_SOCKET_DUMP_REL)
        for rel in (main_rel, socket_rel):
            target = mods / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("-- patched dump\n", encoding="utf-8")
        paths = _DumpPaths(mods)
        selected = ic._select_dump_files(paths, [main_rel, socket_rel], require_socket=True)
        assert selected["lovely_dump"] == mods / main_rel
        assert selected["socket_dump"] == mods / socket_rel
        # The unpatched game-dump tree and any same-basename file are never evidence.
        game_dump_rel = f"{staging.LOVELY_DIR_NAME}/game-dump/{staging.MP_SOCKET_DUMP_REL}"
        game_dump = mods / game_dump_rel
        game_dump.parent.mkdir(parents=True, exist_ok=True)
        game_dump.write_text("-- unpatched\n", encoding="utf-8")
        assert ic._select_dump_files(paths, [main_rel, game_dump_rel], require_socket=True) == {}
        (mods / staging.LOVELY_DIR_NAME / staging.LOVELY_DUMP_DIR_NAME / "socket.lua").write_text(
            "-- arbitrary basename\n", encoding="utf-8"
        )
        arbitrary = f"{staging.LOVELY_DIR_NAME}/{staging.LOVELY_DUMP_DIR_NAME}/socket.lua"
        assert ic._select_dump_files(paths, [main_rel, arbitrary], require_socket=True) == {}


def _run_all() -> int:
    tests = sorted(
        (name, value)
        for name, value in globals().items()
        if name.startswith("test_") and callable(value)
    )
    failures = 0
    for name, function in tests:
        try:
            function()
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {name}: {type(error).__name__}: {error}")
        else:
            print(f"ok   {name}")
    print(f"\n{len(tests) - failures}/{len(tests)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_run_all())
