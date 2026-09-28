#!/usr/bin/env python3
"""Two-layer isolation certificate and per-session live-diff tests.

Synthetic temp filesystems only: no live install, live %AppData%, Steam tree,
network, game launch or process action. The certificate is assembled only from
tool-owned *phase receipts* produced by ``isolation_certificate.record_phase_receipt``
over temp trees; the legacy caller-dict fixture, tampered receipts, staged drift,
revocation and the global lockout are asserted negative.
"""
from __future__ import annotations

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


def _write_probes(paths, nonce=NONCE, port=PORT):
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
    return {
        "main": save / staging.PROBE_MAIN,
        "guard": save / staging.PROBE_GUARD,
        "save_thread": save / staging.PROBE_SAVE_THREAD,
        "mp": save / staging.PROBE_MP,
        "steam_marker": save / ic.PROBE_STEAM_MARKER,
        "steam_post": save / ic.PROBE_STEAM_POST,
    }


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
    return {"root": root, "staging_root": staging_root, "live_map": live_map, "probes": probes}


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

class _FakeSession:
    """Exited synthetic LaunchSession: records + owned all stopped."""

    def __init__(self, session_id, staging_root, nonce, spawn_time, roles):
        self.session_id = session_id
        self.staging_root = Path(staging_root)
        self.nonce = nonce
        self.spawn_time = spawn_time
        self.code = "launched"
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
        self.owned = []

    @property
    def ok(self):
        return self.code == "launched"

    def is_running(self):
        return [{"role": record.role, "pid": record.pid, "running": False} for record in self.records]

    def terminate(self, timeout=10.0):
        return []

    def close(self):
        return None


_CRASH_OBS = {"crash_exit_codes": {"human": 1, "ai": 1}, "cleanup_ok": True, "crash_observed": True}
_P2_OBS = {"dead_port": 9, "refused": True, "attempts": 3}


def _backup_verify(digest="backup-digest"):
    return lambda: {"ok": True, "digest": digest}


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


def _record_phase(fixture, phase, observation=None):
    staging_root = fixture["staging_root"]
    live = fixture["live_map"]
    session_id = f"phase-{phase.lower()}"
    prepared = ic.prepare_session(
        staging_root,
        live=live,
        session_id=session_id,
        port=PORT if phase != "P1A" else None,
        closed_check=lambda: True,
        phase=phase,
        backup_verify=_backup_verify(f"backup-{phase.lower()}"),
    )
    assert prepared["ok"], (phase, prepared)
    nonce = prepared["nonce"]
    spawn_time = time.time() - 1
    ic.bind_open_session(staging_root, session_id, pids={"bootstrap": [1]}, spawn_time=spawn_time)
    _write_probes(staging.bootstrap_paths(staging_root), nonce=nonce)
    for role in staging.ROLES:
        _write_probes(staging.role_paths(staging_root, role), nonce=nonce)
    session = _FakeSession(session_id, staging_root, nonce, spawn_time, ic.PHASE_ROLES[phase])
    return ic.record_phase_receipt(
        staging_root,
        phase=phase,
        session_id=session_id,
        session=session,
        live=live,
        port=PORT if phase != "P1A" else None,
        observation=observation,
    )


def _receipt_ids(fixture) -> dict:
    receipt_ids: dict = {}
    for phase in ic.REQUIRED_PHASES:
        observation = _CRASH_OBS if phase == "CRASH" else (_P2_OBS if phase == "P2" else None)
        result = _record_phase(fixture, phase, observation=observation)
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
            receipt_ids.pop("P2")
            verdict = ic.build_certificate(
                fixture["staging_root"], receipt_ids=receipt_ids, live=fixture["live_map"], port=PORT
            )
        assert not verdict["ok"] and verdict["status"] == "partial"
        assert "phase_crash_missing" in verdict["problems"]
        assert "phase_p2_missing" in verdict["problems"]
        assert verdict["certificate_id"] is None


def test_receipts_must_have_distinct_nonces():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        with synthetic_tools(root):
            receipt_ids = {}
            for phase in ic.REQUIRED_PHASES:
                observation = _CRASH_OBS if phase == "CRASH" else (_P2_OBS if phase == "P2" else None)
                staging_root = fixture["staging_root"]
                session_id = f"dup-{phase.lower()}"
                prepared = ic.prepare_session(
                    staging_root,
                    live=fixture["live_map"],
                    session_id=session_id,
                    port=PORT if phase != "P1A" else None,
                    nonce="fixed-nonce",
                    closed_check=lambda: True,
                    phase=phase,
                    backup_verify=_backup_verify("b"),
                )
                assert prepared["ok"], (phase, prepared)
                ic.bind_open_session(staging_root, session_id, pids={"bootstrap": [1]}, spawn_time=time.time() - 1)
                _write_probes(staging.bootstrap_paths(staging_root), nonce="fixed-nonce")
                for role in staging.ROLES:
                    _write_probes(staging.role_paths(staging_root, role), nonce="fixed-nonce")
                session = _FakeSession(session_id, staging_root, "fixed-nonce", time.time() - 1, ic.PHASE_ROLES[phase])
                result = ic.record_phase_receipt(
                    staging_root,
                    phase=phase,
                    session_id=session_id,
                    session=session,
                    live=fixture["live_map"],
                    port=PORT if phase != "P1A" else None,
                    observation=observation,
                )
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


def _prepare_for_verdict(fixture, session_id="s1", backup_id="b1"):
    prepared = ic.prepare_session(
        fixture["staging_root"],
        live=fixture["live_map"],
        session_id=session_id,
        closed_check=lambda: True,
        phase="P1A",
        backup_verify=_backup_verify(backup_id),
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
            backup_verify=_backup_verify(),
        )
        assert not blocked["ok"] and "certificate_locked_out" in blocked["problems"]
        assert ic.acknowledge_lockout(fixture["staging_root"], operator="user", reason="reviewed")["ok"]
        allowed = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="next",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(),
        )
        assert allowed["ok"], allowed
        receipts = (fixture["staging_root"] / "evidence" / "sessions" / "receipts.jsonl").read_text(encoding="utf-8")
        assert '"verdict":"failed"' in receipts


def test_no_spawn_closure_is_measured():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "never-spawned", backup_id="nb")
        closed = ic.record_session_no_spawn(
            fixture["staging_root"], session_id="never-spawned", live=fixture["live_map"]
        )
        assert closed["ok"] and closed["code"] == "session_no_spawn_closed"
        assert closed["receipt"]["verdict"] == "no_spawn"
        assert ic.lockout(fixture["staging_root"])["locked"] is False

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "diff", backup_id="df")
        (fixture["live_map"]["appdata"] / "Mods" / "x.lua").write_text("changed", encoding="utf-8")
        revoked = ic.record_session_no_spawn(fixture["staging_root"], session_id="diff", live=fixture["live_map"])
        assert not revoked["ok"] and revoked["code"] == "live_byte_diff_revoked"
        assert ic.lockout(fixture["staging_root"])["locked"] is True

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = _stage_all(root)
        _prepare_for_verdict(fixture, "spawned", backup_id="sp")
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
        prepared = _prepare_for_verdict(fixture, "reuse", backup_id="b")
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
            nonce="n-one",
            phase="P1A",
            backup_verify=_backup_verify(),
        )
        assert first["ok"] and first["nonce"] == "n-one"
        second = ic.prepare_session(
            fixture["staging_root"],
            live=fixture["live_map"],
            session_id="two",
            closed_check=lambda: True,
            phase="P1A",
            backup_verify=_backup_verify(),
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
            nonce="fresh-nonce",
            phase="P1A",
            backup_verify=_backup_verify(),
        )
        assert prepared["ok"] and prepared["nonce"] == "fresh-nonce"
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
            backup_verify=_backup_verify(),
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
            backup_verify=_backup_verify(),
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
                phase="P1B",
                backup_verify=_backup_verify(),
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
            backup_verify=_backup_verify(),
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
                backup_verify=_backup_verify(),
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
                backup_verify=_backup_verify(),
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
