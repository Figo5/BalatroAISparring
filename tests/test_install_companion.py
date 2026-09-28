#!/usr/bin/env python3
"""Packaging and gated first-install tests for the AI Sparring companion.

Every tree is a synthetic temp fixture. No live Balatro install, live
``%AppData%`` tree, Steam tree, network, game launch or process termination is
performed. Process enumeration and the isolation-certificate checker are
injected; the production defaults are exercised separately to prove they fail
closed. Backups are produced by the real ``launch_practice.create_live_backup``
helper over the fixture trees, never written by hand.
"""
from __future__ import annotations

import os
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

import install_companion  # noqa: E402
import launch_practice  # noqa: E402
import staging  # noqa: E402

_MISSING = object()


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


class FakeEnumerator(launch_practice.ProcessEnumerator):
    def __init__(self, processes=None, error=None):
        self._processes = list(processes or [])
        self._error = error

    def list(self):
        if self._error is not None:
            raise staging.StagingError(self._error)
        return list(self._processes)


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _certificate_ok(staging_root, live=None):
    return {"ok": True, "code": "ok", "problems": [], "certificate_id": "fixture"}


def _make_source(tmp: Path, version: str = install_companion.EXPECTED_VERSION) -> Path:
    source = tmp / "source" / "AISparring"
    shutil.copytree(REPO / "AISparring", source)
    if version != install_companion.EXPECTED_VERSION:
        import json

        manifest = source / install_companion.MOD_MANIFEST_NAME
        data = json.loads(manifest.read_text(encoding="utf-8"))
        data["version"] = version
        staging.write_json(manifest, data)
    _write_bytes(source / "__pycache__" / "junk.pyc", b"pyc")
    _write_bytes(source / "debug.log", b"log")
    _write_bytes(source / "save" / "1.jkr", b"save")
    _write_bytes(source / ".env", b"SECRET=never copy")
    return source


def _ready(tmp: Path, version: str = install_companion.EXPECTED_VERSION) -> dict:
    source = _make_source(tmp, version)
    install = tmp / "install"
    _write_bytes(install / "Balatro.exe", b"MZ fake balatro")
    appdata = tmp / "AppData" / "Balatro"
    mods = appdata / "Mods"
    _write_text(mods / "OtherMod" / "OtherMod.json", '{"id":"OtherMod"}')
    _write_text(mods / "OtherMod" / "core.lua", "return {}\n")
    _write_text(mods / "Multiplayer" / "Multiplayer.json", '{"id":"Multiplayer"}')
    _write_text(mods / "Multiplayer" / "core.lua", "return {}\n")
    _write_text(mods / "Handy" / "Handy.json", '{"id":"Handy"}')
    _write_text(mods / "Handy" / "core.lua", "return {}\n")
    _write_text(mods / "JokerDisplay" / "JokerDisplay.json", '{"id":"JokerDisplay"}')
    _write_text(mods / "JokerDisplay" / "core.lua", "return {}\n")
    _write_bytes(appdata / "saves" / "1.save", b"human-save-bytes")
    steam_app = tmp / "steam" / "userdata" / "123" / "2379780"
    _write_bytes(steam_app / "remote" / "cloud.bin", b"cloud")

    package_root = tmp / "work" / "package"
    discovery = tmp / "work" / "aisparring-host" / "practice_host.json"
    built = install_companion.build_package(source, package_root, discovery)
    assert built["ok"], built

    backup_root = tmp / "backups"
    backup = launch_practice.create_live_backup(
        install_root=install,
        appdata_root=appdata,
        steam_userdata_roots=[steam_app],
        backup_root=backup_root,
        enumerator=FakeEnumerator([]),
        live_install_root=install,
        label="20260101T000000Z",
        execute=True,
    )
    assert backup["ok"], backup

    acceptance = tmp / "work" / "acceptance.json"
    staging.write_json(
        acceptance,
        {
            "schema": install_companion.ACCEPTANCE_SCHEMA,
            "accepted": True,
            "reviewer": "root",
            "reviewed_unix": 1700000000,
            "package_version": install_companion.EXPECTED_VERSION,
            "package_sha256": built["digest"],
        },
    )
    return {
        "tmp": tmp,
        "source": source,
        "install": install,
        "appdata": appdata,
        "mods": mods,
        "steam_app": steam_app,
        "package_root": package_root,
        "discovery": discovery,
        "digest": built["digest"],
        "backup_root": backup_root,
        "acceptance": acceptance,
        "stage_parent": tmp / "work" / "install-stage",
    }


_REAL_COPY_STAGE_TREE = install_companion._copy_stage_tree


def _install(env: dict, **overrides) -> dict:
    kwargs = {
        "package_root": env["package_root"],
        "live_mods_root": env["mods"],
        "staging_root": env["tmp"] / "staging",
        "acceptance_path": env["acceptance"],
        "backup_root": env["backup_root"],
        "receipt_root": env["tmp"] / "work",
        "stage_parent": env["stage_parent"],
        "live": {"install": env["install"], "appdata": env["appdata"]},
        "live_install_root": env["install"],
        "enumerator": FakeEnumerator([]),
        "certificate_check": _certificate_ok,
        "execute": True,
    }
    kwargs.update(overrides)
    return install_companion.install_companion(**kwargs)


def _mods_temp_leaks(mods: Path) -> list:
    return sorted(
        str(child) for child in mods.iterdir() if child.name.startswith(install_companion.STAGING_TEMP_PREFIX)
    )


def _stage_leftovers(stage_parent: Path) -> list:
    if not stage_parent.exists():
        return []
    return sorted(str(child) for child in stage_parent.iterdir())


def _receipt_leftovers(receipt_root: Path) -> list:
    directory = receipt_root / "install-receipts"
    if not directory.exists():
        return []
    return sorted(str(child) for child in directory.iterdir())


def _user_file_hashes(env: dict) -> dict:
    """SHA256 of every existing user file (all mods except AISparring, and saves)."""
    hashes: dict = {}
    for root in (env["mods"], env["appdata"] / "saves"):
        for path in sorted(Path(root).rglob("*")):
            if path.is_file() and "AISparring" not in path.parts:
                hashes[str(path)] = staging.sha256_file(path)
    return hashes


def _running_process(env: dict, pid: int = 4242) -> "launch_practice.ProcessInfo":
    return launch_practice.ProcessInfo(
        pid=pid,
        create_time=time.time(),
        image_path=str(env["install"] / "Balatro.exe"),
        name="Balatro",
    )


# ---------------------------------------------------------------------------
# Package building
# ---------------------------------------------------------------------------

def test_lua_quote_escapes_paths_and_control_characters():
    assert install_companion.lua_quote('C:\\work\\aisparring-host\\practice_host.json') == (
        '"C:\\\\work\\\\aisparring-host\\\\practice_host.json"'
    )
    assert install_companion.lua_quote('a"b') == '"a\\"b"'
    assert install_companion.lua_quote("line\nbreak\ttab") == '"line\\nbreak\\ttab"'
    assert install_companion.lua_quote("\x01") == '"\\001"'


def test_build_package_contents_configs_junk_and_version():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        root = env["package_root"]
        assert (root / install_companion.PACKAGE_MANIFEST_NAME).is_file()
        live = root / "live" / "AISparring"
        staged = {role: root / "staged" / role / "AISparring" for role in install_companion.STAGED_ROLES}
        assert (live / "core.lua").is_file() and (live / "ai" / "actions.lua").is_file()
        live_config = (live / install_companion.CONFIG_NAME).read_text(encoding="utf-8")
        assert "ai_enabled = true" in live_config
        assert 'role = "live"' in live_config
        assert install_companion.lua_quote(str(env["discovery"])) in live_config

        staged_text = install_companion.render_staged_config()
        for directory in staged.values():
            text = (directory / install_companion.CONFIG_NAME).read_text(encoding="utf-8")
            assert text == staged_text
            assert "discovery_path" not in text
        assert staging._tree_digest(staged["human"], install_companion.PACKAGE_HASH_POLICY) == staging._tree_digest(
            staged["ai"], install_companion.PACKAGE_HASH_POLICY
        )

        for junk in ("__pycache__", "debug.log", "save", ".env"):
            assert not (live / junk).exists(), junk

        manifest = staging.read_json(root / install_companion.PACKAGE_MANIFEST_NAME)
        assert manifest["package_version"] == install_companion.EXPECTED_VERSION
        assert manifest["digest"] == env["digest"]
        verified = install_companion.verify_package(root)
        assert verified["ok"] and verified["digest"] == env["digest"]

        repo_config = (REPO / "AISparring" / "config.lua").read_text(encoding="utf-8")
        assert "ai_enabled = false" in repo_config


def test_build_package_refuses_version_mismatch():
    with tempfile.TemporaryDirectory() as tmp:
        source = _make_source(Path(tmp), version="9.9.9")
        result = install_companion.build_package(source, Path(tmp) / "pkg", Path(tmp) / "host.json")
        assert not result["ok"] and result["code"] == "source_version_unverified", result
        assert "source_version_mismatch" in result["problems"]


def test_verify_package_detects_tamper():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        target = env["package_root"] / "live" / "AISparring" / "core.lua"
        target.write_text("-- tampered\n", encoding="utf-8")
        verdict = install_companion.verify_package(env["package_root"])
        assert not verdict["ok"] and verdict["code"] == "package_unverified", verdict
        assert any(item.startswith("package_changed") for item in verdict["problems"]), verdict


# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------

def test_install_refuses_wrong_target():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, target_dir=env["mods"] / "AnotherMod")
        assert result["code"] == "target_not_owned", result
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_target_outside_mods():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, target_dir=env["tmp"] / "elsewhere" / "AISparring")
        assert result["code"] == "target_not_owned", result


def test_install_refuses_linked_mods_root():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        link = env["tmp"] / "linked-mods"
        try:
            os.symlink(env["mods"], link, target_is_directory=True)
        except (OSError, NotImplementedError):
            return
        result = _install(env, live_mods_root=link)
        assert result["code"] in ("link_or_junction_refused", "target_not_owned"), result
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_existing_target():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        _write_text(env["mods"] / "AISparring" / "core.lua", "-- pre-existing\n")
        result = _install(env)
        assert result["code"] == "target_exists", result
        assert "replace_upgrade_out_of_scope" in result["problems"]
        assert (env["mods"] / "AISparring" / "core.lua").read_text(encoding="utf-8") == "-- pre-existing\n"


# ---------------------------------------------------------------------------
# Process / backup gates
# ---------------------------------------------------------------------------

def test_install_refuses_running_game_and_leaves_no_mutation():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        running = launch_practice.ProcessInfo(
            pid=4242,
            create_time=time.time(),
            image_path=str(env["install"] / "Balatro.exe"),
            name="Balatro",
        )
        result = _install(env, enumerator=FakeEnumerator([running]))
        assert result["code"] == "live_balatro_running", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []


def test_install_refuses_unavailable_process_enumeration():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, enumerator=FakeEnumerator(error="process_enumeration_failed"))
        assert result["code"] == "process_enumeration_failed", result
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_backup_failure():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        with (env["mods"] / "OtherMod" / "core.lua").open("a", encoding="utf-8") as handle:
            handle.write("-- changed after backup\n")
        result = _install(env)
        assert result["code"] == "mods_backup_unverified", result
        assert any("changed_since_backup" in item for item in result["problems"]), result
        assert not (env["mods"] / "AISparring").exists()


# ---------------------------------------------------------------------------
# Acceptance / certificate gates
# ---------------------------------------------------------------------------

def test_install_refuses_missing_acceptance():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, acceptance_path=env["tmp"] / "work" / "absent.json")
        assert result["code"] == "acceptance_unverified", result
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_bad_acceptance_schema():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        staging.write_json(env["acceptance"], {"schema": "evil", "accepted": True})
        result = _install(env)
        assert result["code"] == "acceptance_unverified", result
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_acceptance_bound_to_other_package():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        staging.write_json(
            env["acceptance"],
            {
                "schema": install_companion.ACCEPTANCE_SCHEMA,
                "accepted": True,
                "reviewer": "root",
                "reviewed_unix": 1700000000,
                "package_version": install_companion.EXPECTED_VERSION,
                "package_sha256": "0" * 64,
            },
        )
        result = _install(env)
        assert result["code"] == "acceptance_unverified", result
        assert "acceptance_package_mismatch" in result["problems"]
        assert not (env["mods"] / "AISparring").exists()


def test_install_refuses_certificate_failure():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(
            env,
            certificate_check=lambda staging_root, live=None: {
                "ok": False,
                "code": "certificate_missing",
                "problems": ["certificate_missing"],
            },
        )
        assert result["code"] == "certificate_unverified", result
        assert not (env["mods"] / "AISparring").exists()


def test_install_default_certificate_check_fails_closed_without_certificate():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, certificate_check=None, execute=False)
        assert result["code"] == "certificate_unverified", result
        assert not (env["mods"] / "AISparring").exists()


def test_default_certificate_check_uses_real_checker():
    calls = []

    def fake_check(staging_root, live=None):
        calls.append((staging_root, live))
        return {"ok": False, "code": "certificate_missing", "problems": []}

    with patched(staging, check_isolation_proof=fake_check):
        verdict = install_companion.default_certificate_check("SR", live={"install": "x"})
    assert calls == [("SR", {"install": "x"})], calls
    assert verdict["ok"] is False and verdict["code"] == "certificate_missing"


# ---------------------------------------------------------------------------
# Dry run and successful temporary fixture
# ---------------------------------------------------------------------------

def test_install_planned_dry_run_makes_no_mutation():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        result = _install(env, execute=False)
        assert result["ok"] and result["code"] == "install_planned", result
        assert result["target"] == str(env["mods"] / "AISparring")
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert not (env["tmp"] / "work" / "install-receipts").exists()


def test_install_success_fixture_touches_only_own_mod_and_writes_receipt():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        before_other = staging.sha256_file(env["mods"] / "OtherMod" / "core.lua")
        before_save = staging.sha256_file(env["appdata"] / "saves" / "1.save")
        before_mods_children = sorted(child.name for child in env["mods"].iterdir())
        before_user_hashes = _user_file_hashes(env)

        result = _install(env)
        assert result["ok"] and result["code"] == "installed", result
        target = env["mods"] / "AISparring"
        assert target.is_dir() and (target / "core.lua").is_file()
        config = (target / install_companion.CONFIG_NAME).read_text(encoding="utf-8")
        assert 'role = "live"' in config and "ai_enabled = true" in config
        assert install_companion.lua_quote(str(env["discovery"])) in config

        assert staging.sha256_file(env["mods"] / "OtherMod" / "core.lua") == before_other
        assert staging.sha256_file(env["appdata"] / "saves" / "1.save") == before_save
        assert _user_file_hashes(env) == before_user_hashes
        assert sorted(child.name for child in env["mods"].iterdir()) == sorted(
            before_mods_children + ["AISparring"]
        )
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []

        receipt = Path(result["receipt"])
        assert receipt.is_file() and receipt.parent.parent == env["tmp"] / "work"
        assert not staging.is_within(env["mods"], receipt)
        payload = staging.read_json(receipt)
        assert payload["package_sha256"] == env["digest"]
        assert payload["backup_entry"] == "appdata"
        assert payload["acceptance_reviewer"] == "root"
        assert payload["target"] == str(target)

        repo_config = (REPO / "AISparring" / "config.lua").read_text(encoding="utf-8")
        assert "ai_enabled = false" in repo_config


# ---------------------------------------------------------------------------
# Atomic staging: preparation happens outside live Mods
# ---------------------------------------------------------------------------

def test_install_partial_copy_is_outside_mods_and_cleaned():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        before = sorted(child.name for child in env["mods"].iterdir())

        def bad_copy(source, destination):
            _write_bytes(Path(destination) / "core.lua", b"-- partial copy\n")
            raise OSError("simulated_partial_copy")

        with patched(install_companion, _copy_stage_tree=bad_copy):
            result = _install(env)
        assert not result["ok"] and result["code"] == "install_failed", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert sorted(child.name for child in env["mods"].iterdir()) == before
        assert _stage_leftovers(env["stage_parent"]) == []


def test_install_refuses_corrupted_non_config_staging_copy():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))

        def corrupt(source, destination):
            _REAL_COPY_STAGE_TREE(source, destination)
            _write_text(Path(destination) / "core.lua", "-- corrupted non-config file\n")

        with patched(install_companion, _copy_stage_tree=corrupt):
            result = _install(env)
        assert result["code"] == "staged_verify_failed", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []


def test_install_refuses_target_created_during_preparation():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        marker = env["mods"] / "AISparring" / "marker.txt"

        def create_target(source, destination):
            _REAL_COPY_STAGE_TREE(source, destination)
            _write_text(marker, "appeared mid-copy\n")

        with patched(install_companion, _copy_stage_tree=create_target):
            result = _install(env)
        assert result["code"] == "target_exists", result
        assert marker.read_text(encoding="utf-8") == "appeared mid-copy\n"
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []


def test_install_refuses_linked_stage_parent():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        real = env["tmp"] / "real-stage"
        real.mkdir()
        link = env["tmp"] / "linked-stage"
        try:
            os.symlink(real, link, target_is_directory=True)
        except (OSError, NotImplementedError):
            return
        result = _install(env, stage_parent=link)
        assert result["code"] == "link_or_junction_refused", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []


def test_install_refuses_cross_volume_staging_parent():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        with patched(install_companion, _same_filesystem=lambda first, second: False):
            result = _install(env)
        assert result["code"] == "cross_volume_refused", result
        assert result["problems"], result
        assert not (env["mods"] / "AISparring").exists()
        assert not env["stage_parent"].exists()


def test_install_refuses_game_started_during_preparation():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        enumerator = FakeEnumerator([])
        running = _running_process(env, pid=5151)

        def start_game(source, destination):
            _REAL_COPY_STAGE_TREE(source, destination)
            enumerator._processes = [running]

        with patched(install_companion, _copy_stage_tree=start_game):
            result = _install(env, enumerator=enumerator)
        assert result["code"] == "live_balatro_running", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []


def test_install_receipt_failure_leaves_no_receipt_and_no_target():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))

        def failing_write(*args, **kwargs):
            raise OSError("simulated_receipt_write_failure")

        with patched(staging, write_json=failing_write):
            result = _install(env)
        assert result["code"] == "receipt_write_failed", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []
        assert _receipt_leftovers(env["tmp"] / "work") == []


def test_install_rename_failure_leaves_no_success_receipt():
    with tempfile.TemporaryDirectory() as tmp:
        env = _ready(Path(tmp))
        before = _user_file_hashes(env)

        def failing_rename(*args, **kwargs):
            raise OSError("simulated_rename_failure")

        with patched(install_companion.os, rename=failing_rename):
            result = _install(env)
        assert result["code"] == "install_failed", result
        assert not (env["mods"] / "AISparring").exists()
        assert _mods_temp_leaks(env["mods"]) == []
        assert _stage_leftovers(env["stage_parent"]) == []
        assert _receipt_leftovers(env["tmp"] / "work") == []
        assert _user_file_hashes(env) == before


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
