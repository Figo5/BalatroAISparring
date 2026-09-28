#!/usr/bin/env python3
"""Staging tests over synthetic temp trees using the real staging functions.

No live install, live %AppData%, Steam tree, network, game launch or process
termination is performed. Every tree is a temp fixture. Proofs are never
hand-written: the measured collect/record API produces them, and the tests assert
that hand-written booleans are rejected. The Lovely patch placement is validated
against the read-only vanilla reference in work/reference/game when present, and
skipped otherwise.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import staging  # noqa: E402

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
    "local env_path = MP.path .. '/.env'\n"
    "MP.NETWORKING_THREAD = love.thread.newThread(SOCKET)\n"
    "local server_url = MP.ENV.server_url or SMODS.Mods['Multiplayer'].config.server_url\n"
    "local server_port = tonumber(MP.ENV.server_port) or SMODS.Mods['Multiplayer'].config.server_port\n"
    "MP.NETWORKING_THREAD:start(server_url, server_port)\n"
)

MP_CONFIG_LUA = (
    "return {\n"
    '\t["username"] = "Guest",\n'
    '\t["server_url"] = "balatro.virtualized.dev",\n'
    "\t[\"server_port\"] = 8788,\n"
    "}\n"
)

SMODS_HTTPS_LUA = (
    "local M = {}\n"
    "function M.request(url, options)\n"
    '\treturn 0, "stub", {}\n'
    "end\n"
    "return M\n"
)

SMODS_LOGGING_LUA = (
    "function initializeSocketConnection()\n"
    '\tlocal socket = require("socket")\n'
    "\tlocal tcp = assert(socket.tcp())\n"
    '\tlocal succ = tcp:connect("localhost", 53153)\n'
    "end\n"
    "initializeSocketConnection()\n"
)

HANDY_UPDATER_LUA = (
    "local https_updater_thread =\n"
    "\tlove.thread.newThread(love.filesystem.newFileData(updater_thread_file, '=[SMODS Handy \"threads/updater\"]'))\n"
    "https_updater_thread:start()\n"
    'local https_updater_input = love.thread.getChannel("handy_updater_input")\n'
)


def _make_install(root: Path) -> Path:
    install = root / "BalatroInstall"
    (install / "resources" / "engine").mkdir(parents=True)
    (install / "Balatro.exe").write_bytes(b"MZ fake balatro")
    (install / "version.dll").write_bytes(b"lovely injector")
    (install / "steam_api64.dll").write_bytes(b"steam native")
    (install / "luasteam.dll").write_bytes(b"luasteam native")
    (install / "resources" / "main.lua").write_text(MAIN_LUA, encoding="utf-8")
    (install / "resources" / "engine" / "save_manager.lua").write_text(SAVE_MANAGER_LUA, encoding="utf-8")
    (install / "Mods" / "Multiplayer").mkdir(parents=True)
    (install / "Mods" / "Multiplayer" / "core.lua").write_text("return {}\n", encoding="utf-8")
    (install / "1").mkdir()
    (install / "1" / "save.jkr").write_bytes(b"save")
    (install / "lovely.log").write_text("log\n", encoding="utf-8")
    return install


def _make_mods(root: Path) -> Path:
    mods = root / "LiveAppData" / "Balatro" / "Mods"
    mp = mods / "Multiplayer"
    mp.mkdir(parents=True)
    (mp / "Multiplayer.json").write_text(
        json.dumps({"id": "Multiplayer", "name": "Multiplayer"}), encoding="utf-8"
    )
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


def _make_live(root: Path) -> dict:
    live_install = root / "live" / "Balatro"
    live_install.mkdir(parents=True)
    (live_install / "Balatro.exe").write_bytes(b"MZ live")
    live_appdata = root / "live_appdata" / "Balatro"
    (live_appdata / "Mods").mkdir(parents=True)
    (live_appdata / "Mods" / "x.lua").write_text("x", encoding="utf-8")
    steam = root / "Steam" / "userdata" / "390025789" / "2379780"
    (steam / "remote").mkdir(parents=True)
    (steam / "remote" / "state.vdf").write_text("s", encoding="utf-8")
    return {"install": live_install, "appdata": live_appdata, "steam_userdata": steam}


def _stage_role(staging_root, role, install, mods, live=None, port=8788):
    staging.stage_role(
        staging_root,
        role,
        install,
        mods_source=mods,
        mods_closed_check=lambda: True,
        live_roots_map=live,
    )
    staging.configure_role_endpoint(staging_root, role, port)
    staging.finalize_role(staging_root, role)


def _write_probes(paths, nonce, port, mp=True, steam="nil", luasteam="nil", marker="true"):
    save = paths.data / "Balatro"
    save.mkdir(parents=True, exist_ok=True)
    (save / staging.PROBE_MAIN).write_text(
        f"probe=main\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\nexpected={save}\nmods={paths.mods}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_GUARD).write_text(
        f"probe=guard\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n"
        f"lovely_mod_dir={paths.mods}\nmods={paths.mods}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_SAVE_THREAD).write_text(
        f"probe=save_thread\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_STEAM_MARKER).write_text(
        f"probe=steam_marker\npatch={staging.PATCH_ID}\nnonce={nonce}\n"
        f"steam_patch_applied={marker}\nsteam={steam}\nluasteam={luasteam}\nsave={save}\n",
        encoding="utf-8",
    )
    (save / staging.PROBE_STEAM_POST).write_text(
        f"probe=steam_post\npatch={staging.PATCH_ID}\nnonce={nonce}\n"
        f"steam={steam}\nluasteam={luasteam}\nsave={save}\n",
        encoding="utf-8",
    )
    if mp:
        (save / staging.PROBE_MP).write_text(
            f"probe=mp\npatch={staging.PATCH_ID}\nnonce={nonce}\nurl=127.0.0.1\nport={port}\n"
            f"mods={paths.mods}\nsave={save}\n",
            encoding="utf-8",
        )


def test_parse_env_trims_comments_and_blanks():
    text = "\n  # comment\n   server_url = 127.0.0.1   \n\nserver_port=8788\n"
    env = staging.parse_env(text)
    assert env == {"server_url": "127.0.0.1", "server_port": "8788"}, env


def test_parse_env_booleans_and_duplicates():
    env = staging.parse_env("show_sandbox_collection=true\nalt_stakes=false\nother=maybe\nserver_url=first\nserver_url=second\n")
    assert env["show_sandbox_collection"] is True
    assert env["alt_stakes"] is False
    assert env["other"] == "maybe"
    assert env["server_url"] == "second"


def test_parse_env_key_pattern_and_empty_value():
    env = staging.parse_env("server-url=ignored\nserver_url=\nport 8788\n")
    assert env == {}, env


def test_render_and_validate_roundtrip_and_rejections():
    text = staging.render_env("127.0.0.1", 9090)
    assert staging.validate_local_endpoint(staging.parse_env(text), port=9090)["ok"]
    assert not staging.validate_local_endpoint({"server_url": "balatro.virtualized.dev", "server_port": "8788"})["ok"]
    assert not staging.validate_local_endpoint({"server_url": "localhost", "server_port": "8788"})["ok"]
    assert "server_port_missing" in staging.validate_local_endpoint({"server_url": "127.0.0.1"})["problems"]
    for value in ("abc", "0", "70000", True):
        assert not staging.validate_local_endpoint({"server_url": "127.0.0.1", "server_port": value})["ok"], value


def test_is_within_and_assert_within():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "root"
        root.mkdir()
        assert staging.is_within(root, root / "a" / "b.txt")
        assert not staging.is_within(root, root / ".." / "evil.txt")
        assert not staging.is_within(root, Path(tmp) / "rootx" / "b.txt")
        assert not staging.is_within(root, root)
        assert staging.is_within(root, root, allow_root=True)
        try:
            staging.assert_within(root, Path(tmp) / "outside.txt")
        except staging.StagingError as error:
            assert error.code == "path_escape"
        else:
            raise AssertionError("expected path_escape")


def test_role_paths_are_distinct_and_contained():
    with tempfile.TemporaryDirectory() as tmp:
        human = staging.role_paths(tmp, "human")
        ai = staging.role_paths(tmp, "ai")
        for paths in (human, ai):
            assert staging.is_within(tmp, paths.root)
            assert staging.is_within(tmp, paths.exe())
        assert human.root != ai.root and human.mods != ai.mods
        try:
            staging.role_paths(tmp, "spectator")
        except staging.StagingError as error:
            assert error.code == "unknown_role"
        else:
            raise AssertionError("expected unknown_role")


def test_role_environment_allowlist_pins_lovely_and_strips_injection():
    with tempfile.TemporaryDirectory() as tmp:
        paths = staging.role_paths(tmp, "ai")
        overrides = staging.role_environment_overrides(paths)
        assert staging.is_within(paths.root, overrides["LOVELY_MOD_DIR"], allow_root=True)
        assert staging.is_within(paths.root, overrides["APPDATA"], allow_root=True)
        assert overrides["LOVELY_MOD_DIR"] == str(paths.mods)
        assert overrides["AIS_RUNTIME_ROLE"] == "ai_staged"
        base = {
            "PATH": "x",
            "SteamAppId": "1",
            "SDL_VIDEODRIVER": "y",
            "LOVELY_MOD_DIR": "C:/live/Mods",
            "PYTHONPATH": "z",
            "AISP_PROBE_NONCE": "stale",
        }
        env = staging.role_environment(paths, base_env=base)
        assert env["PATH"] == "x"
        assert env["LOVELY_MOD_DIR"] == str(paths.mods)
        assert staging.is_within(paths.root, env["APPDATA"], allow_root=True)
        for forbidden in ("SteamAppId", "SDL_VIDEODRIVER", "PYTHONPATH", "AISP_PROBE_NONCE"):
            assert forbidden not in env, forbidden


def test_hash_tree_scopes_to_install_and_mods_only():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "role"
        (root / "install").mkdir(parents=True)
        (root / "install" / "a.txt").write_text("a", encoding="utf-8")
        mods = root / "appdata" / "Roaming" / "Balatro" / "Mods"
        (mods / "lovely" / "log").mkdir(parents=True)
        (mods / "m.lua").write_text("m", encoding="utf-8")
        (mods / "lovely" / "log" / "l.txt").write_text("l", encoding="utf-8")
        (root / "appdata" / "Roaming" / "Balatro" / "settings.jkr").write_text("s", encoding="utf-8")
        (root / "logs").mkdir()
        (root / "logs" / "x.log").write_text("x", encoding="utf-8")
        files = staging.hash_tree(root, staging.STAGING_POLICY)
        assert "install/a.txt" in files
        assert "appdata/Roaming/Balatro/Mods/m.lua" in files
        assert "appdata/Roaming/Balatro/settings.jkr" not in files
        assert not any("lovely/log" in rel for rel in files)
        assert not any(rel.startswith("logs/") for rel in files)


def test_stage_install_omits_steam_natives_mods_saves_and_logs():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        staging_root = root / "staging"
        result = staging.stage_install(install, staging_root / "roles" / "human" / "install", staging_root)
        dest = Path(result["dest"])
        assert (dest / "Balatro.exe").is_file()
        assert (dest / "version.dll").is_file()
        assert (dest / "resources" / "main.lua").is_file()
        assert not (dest / "steam_api64.dll").exists()
        assert not (dest / "luasteam.dll").exists()
        assert not (dest / "Mods").exists()
        assert not (dest / "1" / "save.jkr").exists()
        assert not (dest / "lovely.log").exists()
        assert set(result["omitted_steam_natives"]) == {"steam_api64.dll", "luasteam.dll"}


def test_stage_install_refuses_escape_and_recursive_source():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        staging_root = root / "staging"
        staging_root.mkdir()
        try:
            staging.stage_install(install, root / "outside" / "install", staging_root)
        except staging.StagingError as error:
            assert error.code == "path_escape"
        else:
            raise AssertionError("expected path_escape")
        nested_source = staging_root / "inner"
        nested_source.mkdir()
        try:
            staging.stage_install(nested_source, staging_root / "roles" / "ai" / "install", staging_root)
        except staging.StagingError as error:
            assert error.code == "install_source_inside_staging"
        else:
            raise AssertionError("expected install_source_inside_staging")


def test_stage_overlap_with_explicit_custom_roots_refused():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        custom_appdata = root / "custom" / "Balatro"
        custom_appdata.mkdir(parents=True)
        staging_root = custom_appdata / "staging"
        roots = staging.live_roots(
            install_root=root / "live" / "Balatro",
            appdata_root=custom_appdata,
            steam_root=root / "Steam",
        )
        try:
            staging.assert_no_overlap(staging_root, roots)
        except staging.StagingError as error:
            assert error.code == "staging_overlaps_live"
        else:
            raise AssertionError("expected staging_overlaps_live")
        assert staging.assert_no_overlap(root / "other", roots) is None


def test_steamapps_parent_only_infers_real_structure():
    assert staging.steamapps_parent(Path("C:/x/live/Balatro")) is None
    assert staging.steamapps_parent(Path("C:/x/steamapps/common/Balatro")) == Path("C:/x/steamapps")
    assert staging.steamapps_parent(Path("C:/x/steamapps/Aquarium")) is None


def test_find_steam_userdata_apps_enumerates_all_profiles():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for profile in ("390025789", "111111111"):
            app = root / "Steam" / "userdata" / profile / "2379780"
            (app / "remote").mkdir(parents=True)
            (app / "remote" / "state.vdf").write_text("s", encoding="utf-8")
        found = staging.find_steam_userdata_apps(root / "Steam")
        assert len(found) == 2
        assert staging.find_steam_userdata_app(root / "Steam") == found[0]
        assert staging.find_steam_userdata_apps(root / "empty") == []


def test_stage_mods_requires_closed_check_and_omits_live_env():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        mods = _make_mods(root)
        staging_root = root / "staging"
        dest = staging_root / "roles" / "ai" / "appdata" / "Roaming" / "Balatro" / "Mods"
        try:
            staging.stage_mods(mods, dest, staging_root, closed_check=lambda: False)
        except staging.StagingError as error:
            assert error.code == "live_source_not_closed"
        else:
            raise AssertionError("expected live_source_not_closed")
        try:
            staging.stage_mods(mods, dest, staging_root)
        except staging.StagingError as error:
            assert error.code == "closed_check_required"
        else:
            raise AssertionError("expected closed_check_required")
        result = staging.stage_mods(mods, dest, staging_root, closed_check=lambda: True)
        staged = Path(result["dest"])
        assert (staged / "Multiplayer" / "core.lua").is_file()
        assert not (staged / "Multiplayer" / ".env").exists()
        assert not (staged / "Handy" / "src" / "core" / "updater" / "index.lua").read_text().startswith(
            staging.NETWORK_SUPPRESSION_MARKER
        )


def test_suppression_disables_handy_updater_smods_https_and_debug_socket():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        handy = (paths.mods / "Handy" / "src" / "core" / "updater" / "index.lua").read_text()
        assert staging.NETWORK_SUPPRESSION_MARKER + " handy_updater" in handy
        assert "https_updater_thread:start()" not in handy
        smods_https = (paths.mods / "Steamodded" / "libs" / "https" / "smods-https.lua").read_text()
        assert staging.NETWORK_SUPPRESSION_MARKER + " smods_https" in smods_https
        assert "external HTTPS disabled" in smods_https
        logging = (paths.mods / "Steamodded" / "libs" / "logging.lua").read_text()
        assert staging.NETWORK_SUPPRESSION_MARKER + " smods_debug_socket" in logging
        assert staging.SMODS_DEBUG_SOCKET_LITERAL not in logging
        guards = staging.check_network_guards(staging_root, "ai")
        assert guards["ok"], guards
        (paths.mods / "Handy" / "src" / "core" / "updater" / "index.lua").write_text(
            HANDY_UPDATER_LUA, encoding="utf-8"
        )
        assert not staging.check_network_guards(staging_root, "ai")["ok"]


def test_find_multiplayer_mod_by_manifest_id():
    with tempfile.TemporaryDirectory() as tmp:
        mods = _make_mods(Path(tmp))
        matches = staging.find_multiplayer_mod(mods)
        assert len(matches) == 1 and matches[0].name == "Multiplayer"
        assert staging.find_multiplayer_mod(Path(tmp) / "missing") == []


def test_configure_requires_exactly_one_multiplayer_mod():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        live = _make_live(root)
        staging_root = root / "staging"
        staging.stage_role(staging_root, "ai", install, live_roots_map=live)
        try:
            staging.configure_role_endpoint(staging_root, "ai", 8788)
        except staging.StagingError as error:
            assert error.code == "multiplayer_mod_unresolved"
        else:
            raise AssertionError("expected multiplayer_mod_unresolved")


def test_configure_writes_loopback_env_rewrites_config_and_adds_mp_guard():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        staging.stage_role(
            staging_root, "ai", install, mods_source=mods, mods_closed_check=lambda: True, live_roots_map=live
        )
        result = staging.configure_role_endpoint(staging_root, "ai", 9090)
        paths = staging.role_paths(staging_root, "ai")
        mp = staging.find_multiplayer_mod(paths.mods)[0]
        assert staging.parse_env((mp / ".env").read_text(encoding="utf-8")) == {
            "server_url": "127.0.0.1",
            "server_port": "9090",
        }
        persisted = staging.read_persisted_endpoint(mp)
        assert persisted["url"] == "127.0.0.1" and persisted["port"] == 9090
        assert result["config_rewrite"]["changed"] is True
        patch = paths.mods / staging.PATCH_MOD_ROLE / "lovely" / "bootstrap.toml"
        text = patch.read_text(encoding="utf-8")
        assert staging.MP_THREAD_START_LITERAL in text
        assert "MP.ENV" in text and staging.PROBE_MP in text and "9090" in text
        assert staging.verify_staged_endpoints(staging_root, port=9090, roles=("ai",))["ok"]


def test_configure_refuses_external_persisted_saved_config():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        staging.stage_role(
            staging_root, "ai", install, mods_source=mods, mods_closed_check=lambda: True, live_roots_map=live
        )
        paths = staging.role_paths(staging_root, "ai")
        saved = paths.data / "Balatro" / "config" / "Multiplayer.jkr"
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_text('return { ["server_url"] = "balatro.virtualized.dev" }\n', encoding="utf-8")
        try:
            staging.configure_role_endpoint(staging_root, "ai", 8788)
        except staging.StagingError as error:
            assert error.code == "persisted_mod_config_not_loopback"
        else:
            raise AssertionError("expected persisted_mod_config_not_loopback")


def test_verify_staged_endpoints_requires_both_roles():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        verdict = staging.verify_staged_endpoints(staging_root, port=8788)
        assert not verdict["ok"]
        assert verdict["roles"]["ai"]["problems"] == ["multiplayer_mod_unresolved"]


def test_no_dead_steam_shim_claims():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        paths = staging.role_paths(staging_root, "ai")
        meta = staging.write_steam_guard(paths)
        assert meta["mode"] == "disable_native"
        assert meta["shim"] is False and meta["approved"] is False
        text = Path(meta["patch"]["path"]).read_text(encoding="utf-8")
        assert "G.STEAM = nil" in text
        assert "make_shim" not in text
        assert "return true end" not in text
        assert not hasattr(staging, "steam_guard_lua")
        assert not staging.check_steam_guard(staging_root, "ai")["ok"]


def test_bootstrap_preflight_and_nonce_bound_evidence():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        live = _make_live(root)
        staging_root = root / "staging"
        staging.stage_bootstrap(staging_root, install, live_roots_map=live)
        preflight = staging.check_bootstrap_preflight(staging_root)
        assert preflight["ok"], preflight
        assert not staging.check_bootstrap_evidence(staging_root)["ok"]

        paths = staging.bootstrap_paths(staging_root)
        nonce = "boot-nonce"
        spawn_time = time.time() - 1
        _write_probes(paths, nonce, 8788, mp=False)
        assert not staging.check_bootstrap_preflight(staging_root)["ok"]
        evidence = staging.check_bootstrap_evidence(staging_root, expected_nonce=nonce, spawn_time=spawn_time)
        assert evidence["ok"], evidence
        assert not staging.check_bootstrap_evidence(
            staging_root, expected_nonce="other", spawn_time=spawn_time
        )["ok"]
        assert not staging.check_bootstrap_evidence(
            staging_root, expected_nonce=nonce, spawn_time=time.time() + 100
        )["ok"]
        save_dir = paths.data / "Balatro"
        post = save_dir / staging.PROBE_STEAM_POST
        post.write_text(
            f"probe=steam_post\npatch={staging.PATCH_ID}\nnonce={nonce}\n"
            f"steam=table\nluasteam=nil\nsave={save_dir}\n",
            encoding="utf-8",
        )
        assert "steam_present" in staging.check_bootstrap_evidence(
            staging_root, expected_nonce=nonce, spawn_time=spawn_time
        )["problems"]


def test_stage_bootstrap_layout_has_no_multiplayer_and_no_native_steam():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        staging_root = root / "staging"
        result = staging.stage_bootstrap(staging_root, install, live_roots_map=_make_live(root))
        assert result["role"] == "bootstrap"
        paths = staging.bootstrap_paths(staging_root)
        patch = paths.mods / staging.PATCH_MOD_BOOTSTRAP / "lovely" / "bootstrap.toml"
        text = patch.read_text(encoding="utf-8")
        assert "love.event.quit()" in text
        assert staging.PROBE_SAVE_THREAD in text
        assert not (paths.install / "steam_api64.dll").exists()
        assert not (paths.install / "Mods").exists()
        assert (paths.install / "Balatro.exe").is_file()


def test_disable_mod_by_lovelyignore():
    with tempfile.TemporaryDirectory() as tmp:
        mods = _make_mods(Path(tmp))
        result = staging.disable_mod_by_lovelyignore(mods, "Handy")
        assert result["ok"]
        assert (mods / "Handy" / ".lovelyignore").is_file()
        assert not staging.disable_mod_by_lovelyignore(mods, "Missing")["ok"]


def test_parse_appmanifest_and_detect_versions():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        manifest = root / "appmanifest_2379780.acf"
        manifest.write_text(
            '"AppState"\n{\n\t"appid"\t\t"2379780"\n\t"name"\t\t"Balatro"\n'
            '\t"buildid"\t\t"12345678"\n\t"installdir"\t\t"' + install.name + '"\n'
            '\t"LastUpdated"\t\t"1700000000"\n}\n',
            encoding="utf-8",
        )
        parsed = staging.parse_appmanifest(manifest.read_text(encoding="utf-8"))
        assert parsed["appid"] == "2379780" and parsed["buildid"] == "12345678"
        info = staging.detect_versions(install, steam_manifest_path=manifest)
        assert info["appmanifest"]["buildid"] == "12345678"
        assert "Balatro.exe" in info["files"]


def test_verify_staged_role_roundtrip_and_tamper():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        verify = staging.verify_staged_role(staging_root, "ai")
        assert verify["ok"], verify
        paths = staging.role_paths(staging_root, "ai")
        (paths.install / "resources" / "main.lua").write_text("tampered\n", encoding="utf-8")
        verify = staging.verify_staged_role(staging_root, "ai")
        assert not verify["ok"]
        assert "manifest_mismatch" in verify["problems"]


def test_measured_proof_recorded_and_recomputed_not_self_attested():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        for role in staging.ROLES:
            _stage_role(staging_root, role, install, mods, live=live)
        nonce = "nonce-abc"
        spawn_time = time.time() - 1
        before = staging.measure_isolation_state(staging_root, live=live)
        for role in staging.ROLES:
            _write_probes(staging.role_paths(staging_root, role), nonce, 8788, mp=True)
        after = staging.measure_isolation_state(staging_root, live=live)
        recorded = staging.record_isolation_proof(
            staging_root, before, after, nonce, spawn_time, live=live, expected_port=8788
        )
        assert recorded["ok"], recorded
        assert staging.check_steam_guard(staging_root, "ai")["ok"]
        # The reused certificate gate must refuse while no measured certificate exists.
        assert staging.check_isolation_proof(staging_root, live=live)["code"] == "certificate_missing"
        # A hand-written v1 boolean proof must not become a certificate either.
        forged = staging_root / "evidence" / staging.EVIDENCE_NAME
        forged.write_text(
            json.dumps(
                {
                    "schema": "aisparring.isolation_proof.v1",
                    "p1a": {"passed": True},
                    "zero_live_diff": True,
                    "steam_isolation": "proven",
                }
            ),
            encoding="utf-8",
        )
        assert not staging.check_isolation_proof(staging_root, live=live)["ok"]


def test_record_isolation_proof_metadata_cannot_override_measured_fields():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        for role in staging.ROLES:
            _stage_role(staging_root, role, install, mods, live=live)
        nonce = "nonce-meta"
        spawn_time = time.time() - 1
        before = staging.measure_isolation_state(staging_root, live=live)
        for role in staging.ROLES:
            _write_probes(staging.role_paths(staging_root, role), nonce, 8788, mp=True)
        after = staging.measure_isolation_state(staging_root, live=live)
        hostile = {
            "zero_live_diff": False,
            "steam_isolation": "forged",
            "tool_sha256": "0" * 64,
            "roles": {"ai": {"steam_absent": False}},
            "nonce": "forged",
        }
        recorded = staging.record_isolation_proof(
            staging_root, before, after, nonce, spawn_time, live=live, extra=hostile
        )
        assert recorded["ok"], recorded
        proof = json.loads((staging_root / "evidence" / staging.EVIDENCE_NAME).read_text(encoding="utf-8"))
        assert proof["zero_live_diff"] is True
        assert proof["steam_isolation"] == "proven"
        assert proof["tool_sha256"] != "0" * 64
        assert proof["nonce"] == nonce
        assert proof["roles"]["ai"]["steam_absent"] is True
        assert proof["metadata"] == hostile


def test_measured_proof_detects_staged_immutable_change():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        for role in staging.ROLES:
            _stage_role(staging_root, role, install, mods, live=live)
        nonce = "nonce-xyz"
        spawn_time = time.time() - 1
        before = staging.measure_isolation_state(staging_root, live=live)
        (staging.role_paths(staging_root, "ai").install / "Balatro.exe").write_bytes(b"MZ tampered")
        for role in staging.ROLES:
            _write_probes(staging.role_paths(staging_root, role), nonce, 8788, mp=True)
        after = staging.measure_isolation_state(staging_root, live=live)
        verdict = staging.record_isolation_proof(staging_root, before, after, nonce, spawn_time, live=live)
        assert not verdict["ok"] and "staged_immutable_changed" in verdict["problems"]


def test_finalize_role_extra_cannot_replace_critical_fields():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        hostile = {"role": "human", "staged_install": "/evil", "exe_sha256": "0" * 64}
        staging.finalize_role(staging_root, "ai", extra=hostile)
        paths = staging.role_paths(staging_root, "ai")
        manifest = json.loads((paths.root / staging.MANIFEST_NAME).read_text(encoding="utf-8"))
        assert manifest["role"] == "ai"
        assert manifest["staged_install"] == str(paths.install)
        assert manifest["exe_sha256"] != "0" * 64
        assert manifest["metadata"] == hostile


def test_safe_write_rejects_lexical_escape_and_link_components():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "staging"
        root.mkdir()
        try:
            staging.assert_safe_write(root, Path(tmp) / "outside.txt")
        except staging.StagingError as error:
            assert error.code == "path_escape"
        else:
            raise AssertionError("expected path_escape")
        linked = root / "linked"
        try:
            os.symlink(Path(tmp) / "target", linked, target_is_directory=True)
        except (OSError, NotImplementedError):
            return
        try:
            staging.assert_safe_write(root, linked / "x.txt")
        except staging.StagingError as error:
            assert error.code in ("link_or_junction_refused", "path_escape")
        else:
            raise AssertionError("expected link refusal")


def test_measured_proof_rejects_live_change_between_before_and_after():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        for role in staging.ROLES:
            _stage_role(staging_root, role, install, mods, live=live)
        nonce = "nonce-live"
        spawn_time = time.time() - 1
        before = staging.measure_isolation_state(staging_root, live=live)
        (live["appdata"] / "Mods" / "x.lua").write_text("changed", encoding="utf-8")
        for role in staging.ROLES:
            _write_probes(staging.role_paths(staging_root, role), nonce, 8788, mp=True)
        after = staging.measure_isolation_state(staging_root, live=live)
        verdict = staging.record_isolation_proof(staging_root, before, after, nonce, spawn_time, live=live)
        assert not verdict["ok"] and "live_state_changed" in verdict["problems"]


def test_lovely_patch_matches_reference_main_and_save_manager():
    reference = staging.REFERENCE_GAME_DIR
    if not (reference / "main.lua").is_file():
        return
    main = (reference / "main.lua").read_text(encoding="utf-8")
    save = (reference / "engine" / "save_manager.lua").read_text(encoding="utf-8")
    block = re.search(staging.STEAM_BLOCK_PATTERN, main)
    assert block is not None, "steam block regex must match actual main.lua"
    assert "require 'luasteam'" in block.group(0)
    assert main.count("G:start_up()") == 1 and staging.START_UP_LITERAL in main
    assert staging.LOVE_LOAD_END_LITERAL in main
    # NH1: the Steam block runs after G:start_up() and before mouse.setVisible(false),
    # so only a probe placed before the latter can observe the patched G.STEAM.
    assert main.index(staging.START_UP_LITERAL) < block.start()
    assert block.end() < main.index(staging.LOVE_LOAD_END_LITERAL)
    assert re.search(staging.CRASH_REPORT_PATTERN, main)
    assert staging.SAVE_THREAD_LITERAL in save


def test_render_lovely_toml_structure():
    patches = staging.staging_patches("C:/stage/save", "C:/stage/Mods", mp_guard=8788)
    text = staging.render_lovely_toml(patches)
    assert "[manifest]" in text and "[[patches]]" in text
    assert text.count("[[patches]]") == len(patches)
    assert staging.MP_THREAD_START_LITERAL in text
    assert "love.event.quit()" not in text
    bootstrap = staging.render_lovely_toml(
        staging.staging_patches("C:/stage/save", "C:/stage/Mods", bootstrap=True)
    )
    assert "love.event.quit()" in bootstrap


def test_steam_patch_emits_nonce_bound_marker_and_post_block_probe():
    patches = staging.staging_patches("C:/stage/save", "C:/stage/Mods")
    steam = next(patch for patch in patches if patch["target"] == "main.lua" and patch["pattern"] == staging.STEAM_BLOCK_PATTERN)
    assert "G.STEAM = nil" in steam["payload"]
    assert staging.PROBE_STEAM_MARKER in steam["payload"]
    assert "steam_patch_applied=true" in steam["payload"]
    assert "AISP_PROBE_NONCE" in steam["payload"]
    post = next(patch for patch in patches if patch["pattern"] == staging.LOVE_LOAD_END_LITERAL)
    assert staging.PROBE_STEAM_POST in post["payload"]
    assert "package.loaded.luasteam" in post["payload"]
    assert "tostring(G and G.STEAM)" in post["payload"]
    # The old vacuous pre-start guard no longer claims steam at all.
    guard = next(patch for patch in patches if patch["pattern"] == staging.START_UP_LITERAL)
    assert "steam=" not in guard["payload"]


def test_vacuous_pre_probe_rejected_and_post_probe_required():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        nonce = "steam-nonce"
        spawn_time = time.time() - 1
        assert not staging.collect_role_probes(paths, nonce, spawn_time)["ok"]
        # The old vacuous guard-only probe (steam=nil before G:start_up) is not proof.
        save = paths.data / "Balatro"
        (save / staging.PROBE_MAIN).write_text(
            f"probe=main\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\nexpected={save}\nmods={paths.mods}\n",
            encoding="utf-8",
        )
        (save / staging.PROBE_GUARD).write_text(
            f"probe=guard\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n"
            f"lovely_mod_dir={paths.mods}\nmods={paths.mods}\n",
            encoding="utf-8",
        )
        (save / staging.PROBE_SAVE_THREAD).write_text(
            f"probe=save_thread\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n",
            encoding="utf-8",
        )
        vacuous = staging.collect_role_probes(paths, nonce, spawn_time)
        assert not vacuous["ok"]
        assert f"{staging.PROBE_STEAM_POST}_missing" in vacuous["problems"]
        assert f"{staging.PROBE_STEAM_MARKER}_missing" in vacuous["problems"]
        # Full evidence passes; a real G.STEAM/luasteam leak still fails.
        _write_probes(paths, nonce, 8788, mp=False)
        assert staging.collect_role_probes(paths, nonce, spawn_time)["ok"]
        _write_probes(paths, nonce, 8788, mp=False, luasteam="table")
        leaked = staging.collect_role_probes(paths, nonce, spawn_time)
        assert not leaked["ok"] and "luasteam_present" in leaked["problems"]


def test_check_steam_probes_requires_marker_and_absent_luasteam():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        nonce = "probe-nonce"
        spawn_time = time.time() - 1
        _write_probes(paths, nonce, 8788, mp=False)
        assert staging.check_steam_probes(staging_root, "ai", nonce, spawn_time)["ok"]
        _write_probes(paths, nonce, 8788, mp=False, marker="false")
        marker = staging.check_steam_probes(staging_root, "ai", nonce, spawn_time)
        assert not marker["ok"] and "steam_patch_marker_not_applied" in marker["problems"]
        _write_probes(paths, nonce, 8788, mp=False, luasteam="table")
        leaked = staging.check_steam_probes(staging_root, "ai", nonce, spawn_time)
        assert not leaked["ok"] and "luasteam_present" in leaked["problems"]
        assert not staging.check_steam_probes(staging_root, "ai", "other", spawn_time)["ok"]


def test_check_steam_guard_is_static_and_ignores_stored_proof():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        assert not (staging_root / "evidence" / staging.EVIDENCE_NAME).exists()
        assert staging.check_steam_guard(staging_root, "ai")["ok"]
        # A forged stored proof cannot influence the static guard.
        forged = {"roles": {"ai": {"steam_absent": False}}}
        assert staging.check_steam_guard(staging_root, "ai", proof=forged)["ok"]
        paths = staging.role_paths(staging_root, "ai")
        patch_path = Path(staging._read_guard_meta(paths)["patch"]["path"])
        patch_path.write_text(patch_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        tampered = staging.check_steam_guard(staging_root, "ai")
        assert not tampered["ok"] and "patch_hash_mismatch" in tampered["problems"]


def test_lovely_mod_dir_and_mods_must_be_exact_staged_paths():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        nonce = "exact-nonce"
        spawn_time = time.time() - 1
        _write_probes(paths, nonce, 8788, mp=True)
        save = paths.data / "Balatro"
        (save / staging.PROBE_GUARD).write_text(
            f"probe=guard\npatch={staging.PATCH_ID}\nnonce={nonce}\nsave={save}\n"
            f"lovely_mod_dir={paths.root}\nmods={paths.mods}\n",
            encoding="utf-8",
        )
        verdict = staging.collect_role_probes(paths, nonce, spawn_time, require_mp=True, expected_port=8788)
        assert not verdict["ok"]
        assert "lovely_mod_dir_not_exact" in verdict["problems"]


def test_network_guard_detects_renamed_mod_by_content():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        (mods / "Handy").rename(mods / "NotHandy")
        (mods / "Steamodded").rename(mods / "RenamedSMODS")
        live = _make_live(root)
        staging_root = root / "staging"
        staging.stage_role(
            staging_root, "ai", install, mods_source=mods, mods_closed_check=lambda: True, live_roots_map=live
        )
        assert staging.check_network_guards(staging_root, "ai")["ok"]
        paths = staging.role_paths(staging_root, "ai")
        (paths.mods / "NotHandy" / "src" / "core" / "updater" / "index.lua").write_text(
            HANDY_UPDATER_LUA, encoding="utf-8"
        )
        assert not staging.check_network_guards(staging_root, "ai")["ok"]


def test_network_guard_requires_known_manifest_id_suppression():
    with tempfile.TemporaryDirectory() as tmp:
        mods = Path(tmp) / "Mods"
        renamed = mods / "zzz"
        renamed.mkdir(parents=True)
        (renamed / "zzz.json").write_text(json.dumps({"id": "Handy", "name": "Handy"}), encoding="utf-8")
        (renamed / "thing.lua").write_text("return {}\n", encoding="utf-8")
        scan = staging.scan_network_suppressions(mods)
        assert not scan["ok"]
        assert any(problem.startswith("handy_updater_not_suppressed_for_id") for problem in scan["problems"])


def test_mp_persisted_config_opaque_is_not_loopback_proof():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        saved = paths.data / "Balatro" / "config" / "Multiplayer.jkr"
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(b"\x00\x01server_url=balatro.virtualized.dev\x00")
        read = staging.read_persisted_mod_config(paths.data / "Balatro", "Multiplayer")
        assert read["opaque"] is True and read["url"] is None
        result = staging.configure_role_endpoint(staging_root, "ai", 8788)
        assert result["saved_config_opaque"] is True
        assert staging.verify_staged_endpoints(staging_root, port=8788, roles=("ai",))["ok"]


def test_lovely_evidence_binds_exact_mods_and_freshness():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = _make_install(root)
        mods = _make_mods(root)
        live = _make_live(root)
        staging_root = root / "staging"
        _stage_role(staging_root, "ai", install, mods, live=live)
        paths = staging.role_paths(staging_root, "ai")
        log_dir = paths.mods / "lovely" / "log"
        dump_dir = paths.mods / "lovely" / "dump"
        log_dir.mkdir(parents=True, exist_ok=True)
        dump_dir.mkdir(parents=True, exist_ok=True)
        (log_dir / "lovely.log").write_text("log\n", encoding="utf-8")
        (dump_dir / "main.lua").write_text("dumped\n", encoding="utf-8")
        spawn_time = time.time() - 1
        verdict = staging.check_lovely_evidence(staging_root, "ai", spawn_time)
        assert verdict["ok"], verdict
        assert verdict["paths"]["log_dir"] == str(log_dir)
        assert verdict["paths"]["dump_dir"] == str(dump_dir)
        wrong = staging.check_lovely_evidence(staging_root, "ai", spawn_time, expected_mods=paths.root)
        assert not wrong["ok"] and "lovely_mods_not_exact" in wrong["problems"]
        stale = staging.check_lovely_evidence(staging_root, "ai", time.time() + 100)
        assert not stale["ok"] and "lovely_log_not_fresh" in stale["problems"]


def test_hash_tree_fails_closed_on_link():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "tree"
        (root / "sub").mkdir(parents=True)
        (root / "sub" / "a.txt").write_text("a", encoding="utf-8")
        try:
            os.symlink(Path(tmp) / "target", root / "linked", target_is_directory=True)
        except (OSError, NotImplementedError):
            return
        try:
            staging.hash_tree(root)
        except staging.StagingError as error:
            assert error.code == "hash_reparse_refused"
        else:
            raise AssertionError("expected hash_reparse_refused")


def test_write_helpers_use_safe_writes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "staging"
        root.mkdir()
        try:
            staging.write_json(Path(tmp) / "outside.json", {"a": 1}, staging_root=root)
        except staging.StagingError as error:
            assert error.code == "path_escape"
        else:
            raise AssertionError("expected path_escape")
        mods = root / "roles" / "ai" / "appdata" / "Roaming" / "Balatro" / "Mods"
        (mods / "Handy").mkdir(parents=True)
        result = staging.disable_mod_by_lovelyignore(mods, "Handy")
        assert result["ok"] and (mods / "Handy" / ".lovelyignore").is_file()
        outside = Path(tmp) / "outside_mods"
        (outside / "Handy").mkdir(parents=True)
        try:
            staging.disable_mod_by_lovelyignore(outside, "Handy", staging_root=root)
        except staging.StagingError as error:
            assert error.code == "path_escape"
        else:
            raise AssertionError("expected path_escape")


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
