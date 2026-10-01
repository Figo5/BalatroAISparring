#!/usr/bin/env python3
"""Permanent portable fault-injection regressions for the reviewed companion upgrade.

Runs the real tracked ``tools/upgrade_reviewed_companion.main`` with every
live/process/backup/installer/acceptance/certificate/native-report dependency
replaced by fake roots under a TemporaryDirectory. No real main, helper, game,
Mods, save, staging, package or certificate is ever touched: nothing is written
into the real checkout and no ignored ``work/`` file is read, so the suite is
portable to a tracked-only copy of the repository.

The recovered old package is pinned: the fixture writes a fake, well-formed,
self-consistent recovered manifest plus its receipt digest, and the real
read-only ``install_companion._live_files_from_verified_manifest`` binds it (no
mocked digest logic for the old root). The actual main callable is exercised, so
the original-failure, rollback and refusal behavior is asserted, not simulated.

Source is inert on import (every case runs only from the explicit runner below).
"""
from pathlib import Path
import contextlib
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import types
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
TOOLS = REPO / "tools"


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


upgrade = _load("upgrade_reviewed_companion_under_test", "upgrade_reviewed_companion.py")

# The real read-only manifest checker, captured before any per-scenario patching.
REAL_INSTALLER = upgrade.installer
DISCOVERY = "/fake/discovery"
VERSION = "0.1.0-dev"


class BrokenStderr:
    """A stderr whose write/flush raise, to prove warnings are best-effort."""

    def write(self, text):
        raise OSError("injected stderr write failure")

    def flush(self):
        raise OSError("injected stderr flush failure")


def hashes(root):
    """Match the real `staging.hash_tree` shape: rel -> {sha256, size}."""
    root = Path(root)
    if not root.exists():
        return {}
    out = {}
    for p in root.rglob("*"):
        if p.is_file():
            data = p.read_bytes()
            out[p.relative_to(root).as_posix()] = {
                "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    return out


def manifest_for(files):
    digest = REAL_INSTALLER.package_digest(VERSION, DISCOVERY, files)
    return {"schema": REAL_INSTALLER.PACKAGE_SCHEMA, "package_version": VERSION,
            "discovery_path": DISCOVERY, "files": files, "digest": digest}, digest


def scenario(fault):
    with tempfile.TemporaryDirectory(prefix="aisparring-upgrade-portable-") as tmp:
        root = Path(tmp)
        repo = root / "repo"
        app = root / "fake-live/appdata"
        mods = app / "Mods"
        target = mods / "AISparring"
        target.mkdir(parents=True)
        (target / "old.lua").write_text("OLD")
        (mods / "Handy").mkdir()
        (mods / "Handy/sentinel").write_text("PRESERVE")
        (app / "save.jkr").write_text("PRESERVE SAVE")
        install = root / "fake-live/install"
        install.mkdir(parents=True)
        (install / "Balatro.exe").write_text("FAKE ONLY")
        (repo / "work/local-ownership").mkdir(parents=True)
        package = repo / "package"
        package.mkdir()
        backup = repo / "backups"
        backup.mkdir()
        digest = "d" * 64
        old = hashes(target)
        new = {"new.lua": {"sha256": hashlib.sha256(b"NEW").hexdigest(), "size": 3}}

        # The recovered old package: a fake but well-formed, self-consistent
        # manifest, pinned by its digest in the recovered receipt.
        recovered_dir = repo / "recovered-old"
        recovered_dir.mkdir(parents=True)
        old_manifest_path = recovered_dir / REAL_INSTALLER.PACKAGE_MANIFEST_NAME
        files_old = {"live/AISparring/" + k: v for k, v in old.items()}
        manifest_old, old_digest = manifest_for(files_old)
        pinned_digest = old_digest
        if fault == "old-package-replaced":
            # A later legitimate repackage replaces BOTH the installed bytes and
            # the old manifest self-consistently; the pin still refers to the
            # originally recovered package, so the pair must be refused.
            (target / "old.lua").write_text("REPLACED")
            files_replaced = {"live/AISparring/" + k: v for k, v in hashes(target).items()}
            manifest_replaced, _ = manifest_for(files_replaced)
            old_manifest_path.write_text(json.dumps(manifest_replaced))
        elif fault == "old-manifest-invalid":
            old_manifest_path.write_text(json.dumps({"schema": "not-aisparring", "files": {}}))
        else:
            old_manifest_path.write_text(json.dumps(manifest_old))
        receipt = {"package_manifest": str(old_manifest_path), "package_sha256": pinned_digest}
        if fault == "old-pin-missing":
            receipt.pop("package_sha256")
        (repo / "work/local-ownership/recovery-state.json").write_text(
            json.dumps({"installed_receipt": receipt}))
        (package / "manifest.json").write_text(json.dumps({"digest": digest}))
        (backup / "backup.json").write_text("{}")
        acceptance = repo / "acceptance.json"
        acceptance.write_text("{}")
        # The native certification report this upgrade requires: it must name
        # the reviewed commit and the package/certificate this session verified.
        native_report = repo / "native-report.json"
        native_report.write_text(json.dumps({"source_commit": "fixture-tip",
                                             "package_sha256": digest, "certificate_id": "cert"}))
        live = {"appdata": str(app), "install": str(install)}
        preserved = hashes(app)
        calls = []
        count = 0
        no_game_count = 0

        def snapshot(_):
            return {"roots": {k: {"files": hashes(Path(v))} for k, v in live.items()}}

        def create_backup(**kw):
            nonlocal count
            count += 1
            calls.append("backup" + str(count))
            if count == 2 and fault in ("backup2", "backup2-and-log", "backup2-and-log-stderr"):
                raise OSError("injected backup failure")
            if count == 2 and fault == "interrupt-after-rename":
                raise KeyboardInterrupt()
            if count == 2 and fault == "systemexit-after-rename":
                raise SystemExit()
            if count == 2 and fault == "existing-target":
                target.mkdir()
                (target / "partial.lua").write_text("PARTIAL INSTALLER CONTENT")
                raise OSError("injected backup failure with partial target")
            if count == 2 and fault == "altered-archive":
                archived = list((backup / "companion-archives").glob("*"))
                if archived:
                    (archived[0] / "old.lua").write_text("ALTERED")
                raise OSError("injected backup failure after archive change")
            return {"ok": True}

        def install_companion(**kw):
            calls.append("installer-execute" if kw["execute"] else "installer-dry")
            if fault == "installer":
                return {"ok": False, "code": "injected"}
            if kw["execute"]:
                target.mkdir()
                if fault == "interrupt-partial-install":
                    (target / "partial-new.lua").write_text("PARTIAL")
                    raise KeyboardInterrupt()
                (target / "new.lua").write_text("NEW")
            return {"ok": True}

        def live_files_from_manifest(package_root, accepted_digest, prefix=None,
                                     missing_code="package_live_manifest_missing"):
            # The new package is faked; the recovered old manifest is bound by
            # the REAL digest-checked checker, so the pin is genuinely enforced.
            if Path(package_root) == package:
                return new, "ok"
            return REAL_INSTALLER._live_files_from_verified_manifest(
                package_root, accepted_digest, prefix=prefix, missing_code=missing_code)

        def safe_links(path, label):
            assert root in Path(path).resolve().parents or Path(path).resolve() == root
            assert not Path(path).is_symlink()

        def no_game():
            nonlocal no_game_count
            no_game_count += 1
            calls.append("no-game")
            if fault == "game-started" and not target.exists():
                raise RuntimeError("injected game started before rollback")
            if fault == "closed-before-snapshot" and no_game_count == 2:
                raise RuntimeError("injected live balatro running before snapshot")

        stage = types.SimpleNamespace(
            live_roots=lambda: live, DEFAULT_STAGING_ROOT=repo / "stage",
            DEFAULT_BACKUP_ROOT=backup, default_live_appdata=lambda: app,
            read_json=lambda p: json.loads(Path(p).read_text()), hash_tree=hashes,
            assert_no_links=safe_links,
            is_within=lambda anchor, p, allow_root=False: Path(anchor).resolve() in Path(p).resolve().parents)
        inst = types.SimpleNamespace(
            TARGET_NAME="AISparring", DEFAULT_PACKAGE_ROOT=package,
            PACKAGE_MANIFEST_NAME="manifest.json",
            resolve_install_target=lambda *a, **k: (mods, target),
            verify_package=lambda: {"ok": True, "digest": digest},
            load_acceptance=lambda *a: {"ok": True, "reference": {"certificate_id": "cert"}},
            _live_files_from_verified_manifest=live_files_from_manifest,
            _assert_clean_root=safe_links, install_companion=install_companion)
        lp = types.SimpleNamespace(
            create_live_backup=create_backup, check_backup_evidence=lambda *a: {"ok": True},
            BACKUP_MANIFEST_NAME="backup.json")
        ic = types.SimpleNamespace(
            check_certificate=lambda *a, **k: {"ok": True, "certificate_id": "cert"},
            snapshot_live=snapshot)
        original_write = upgrade.write

        def write(path, value):
            name = Path(path).name
            if fault == "archive-log" and name == "archive.json":
                raise OSError("injected archive evidence failure")
            if fault in ("backup2-and-log", "backup2-and-log-stderr") and name == "failure.json":
                raise OSError("injected failure evidence failure")
            if fault == "success-log" and name == "verified.json":
                raise OSError("injected success evidence failure")
            original_write(path, value)

        def fail_rename(self, dest):
            raise OSError("injected rename failure")

        rename_ctx = (patch.object(pathlib.Path, "rename", fail_rename)
                      if fault == "rename-fail" else contextlib.nullcontext())
        stderr_ctx = (patch.object(sys, "stderr", BrokenStderr())
                      if fault == "backup2-and-log-stderr" else contextlib.nullcontext())
        error = None
        with patch.multiple(upgrade, REPO=repo, staging=stage, installer=inst, lp=lp, ic=ic,
                            no_game=no_game, write=write), \
                patch.object(upgrade.subprocess, "check_output",
                             lambda args, **kw: b"fixture-tip\n" if args[1] == "rev-parse" else b""), \
                patch.object(sys, "argv", ["fixture", "--acceptance", str(acceptance),
                                           "--reviewed-commit", "fixture-tip",
                                           "--native-report", str(native_report), "--execute"]), \
                rename_ctx, stderr_ctx:
            try:
                upgrade.main()
            except BaseException as exc:
                error = type(exc).__name__ + ": " + str(exc)

        outside = lambda d: {k: v for k, v in d.items() if not k.startswith("Mods/AISparring/")}
        upgrade_dirs = sorted((repo / "work/local-ownership").glob("upgrade-*"))
        archives = sorted((backup / "companion-archives").glob("*")) if (backup / "companion-archives").exists() else []
        return {
            "fault": fault,
            "error": error,
            "old_companion_restored": hashes(target) == old,
            "new_companion_installed": hashes(target) == new,
            "target_present": target.exists(),
            "partial_target_present": target.exists() and hashes(target) not in (old, new),
            "archive_present": len(archives) > 0,
            "archive_intact": bool(archives) and hashes(archives[0]) == old,
            "outside_companion_unchanged": outside(preserved) == outside(hashes(app)),
            "before_json_written": bool(upgrade_dirs) and (upgrade_dirs[0] / "before.json").is_file(),
            "failure_json_written": bool(upgrade_dirs) and (upgrade_dirs[0] / "failure.json").is_file(),
            "rollback_json_written": bool(upgrade_dirs) and (upgrade_dirs[0] / "rollback.json").is_file(),
            "backup_started": any(c.startswith("backup") for c in calls),
            "installer_started": any(c.startswith("installer") for c in calls),
            "calls": calls,
            "fixture_only": True,
        }


def real_checker_pin_proof():
    """Prove the real checker refuses a self-consistent changed manifest whose
    digest differs from the pinned one (no package installation involved)."""
    with tempfile.TemporaryDirectory(prefix="aisparring-pin-proof-") as tmp:
        root = Path(tmp) / "pkg"
        root.mkdir()
        files_a = {"live/AISparring/a.lua": {"sha256": "a" * 64, "size": 1}}
        manifest_a, digest_a = manifest_for(files_a)
        (root / REAL_INSTALLER.PACKAGE_MANIFEST_NAME).write_text(json.dumps(manifest_a))
        ok_subset, ok_code = REAL_INSTALLER._live_files_from_verified_manifest(
            root, digest_a, prefix="live/AISparring/")
        # A later self-consistent manifest (digest recomputes to its own digest),
        # checked against the ORIGINAL pinned digest.
        files_b = {"live/AISparring/a.lua": {"sha256": "b" * 64, "size": 1}}
        manifest_b, digest_b = manifest_for(files_b)
        (root / REAL_INSTALLER.PACKAGE_MANIFEST_NAME).write_text(json.dumps(manifest_b))
        changed_subset, changed_code = REAL_INSTALLER._live_files_from_verified_manifest(
            root, digest_a, prefix="live/AISparring/")
        own_subset, own_code = REAL_INSTALLER._live_files_from_verified_manifest(
            root, digest_b, prefix="live/AISparring/")
    assert ok_code == "ok", ok_code
    assert own_code == "ok", own_code
    assert changed_code == "package_changed_after_acceptance", changed_code
    assert changed_subset is None, changed_subset
    assert digest_b == manifest_b["digest"] != digest_a
    return {
        "original_pin_code": ok_code,
        "changed_manifest_self_consistent": digest_b == manifest_b["digest"],
        "changed_manifest_with_original_pin_code": changed_code,
        "changed_manifest_with_own_pin_code": own_code,
        "no_install_performed": True,
        "fixture_only": True,
    }


FAULTS = [
    "none",                     # successful installation
    "archive-log",              # archive evidence write failure
    "backup2",                  # second backup failure (rollback path sanity)
    "backup2-and-log",          # second backup failure + failure evidence failure
    "rename-fail",              # initial live rename failure
    "installer",                # installer refuses
    "game-started",             # game starts before rollback
    "altered-archive",          # archive altered before rollback
    "existing-target",          # partial installer content present at rollback
    "success-log",              # success-evidence write failure after install
    "backup2-and-log-stderr",   # + the evidence warning's stderr write fails
    "old-package-replaced",     # old package + installed bytes self-consistently replaced
    "old-pin-missing",          # recovered receipt has no pinned package digest
    "old-manifest-invalid",     # recovered old manifest fails the digest checker
    "interrupt-after-rename",   # Ctrl-C after the rename (BaseException rollback)
    "interrupt-partial-install",# Ctrl-C after the installer created the target
    "systemexit-after-rename",  # SystemExit after the rename (same BaseException scope)
    "closed-before-snapshot",   # live game reappears after backup plan, before snapshot
]

# Refusals that must happen in preflight, before any backup/archive/installer.
PREFLIGHT_REFUSALS = {
    "old-package-replaced": "package_changed_after_acceptance",
    "old-pin-missing": "Recovered package pin missing",
    "old-manifest-invalid": "package_manifest_invalid",
}


def check_expected(row):
    """Assert the exact outcome of one scenario; any mismatch fails the run."""
    fault = row["fault"]
    assert row["outside_companion_unchanged"], row
    if fault in PREFLIGHT_REFUSALS:
        assert not row["before_json_written"], row
        assert not row["backup_started"], row
        assert not row["installer_started"], row
        assert row["target_present"] and not row["archive_present"], row
        assert not row["rollback_json_written"], row
        assert PREFLIGHT_REFUSALS[fault] in (row["error"] or ""), row
        return
    if fault == "closed-before-snapshot":
        # The live game reappears after the preflight gate but before the very
        # first snapshot: refuse with no backup, archive, install or rollback.
        assert not row["before_json_written"], row
        assert not row["backup_started"] and not row["installer_started"], row
        assert row["target_present"] and not row["archive_present"], row
        assert not row["rollback_json_written"], row
        assert "injected live balatro running before snapshot" in (row["error"] or ""), row
        return
    assert row["before_json_written"], row
    if fault == "none":
        assert row["new_companion_installed"] and not row["old_companion_restored"], row
        assert row["archive_present"] and row["archive_intact"], row
        assert row["error"] is None, row
    elif fault == "archive-log":
        assert row["old_companion_restored"] and not row["new_companion_installed"], row
        assert row["failure_json_written"] and row["rollback_json_written"], row
        assert "archive evidence failure" in (row["error"] or ""), row
    elif fault == "backup2":
        assert row["old_companion_restored"] and row["rollback_json_written"], row
        assert row["error"] == "OSError: injected backup failure", row
    elif fault in ("backup2-and-log", "backup2-and-log-stderr"):
        # The original second-backup failure must survive the evidence/stderr
        # failures, and the target must be restored.
        assert row["old_companion_restored"] and not row["new_companion_installed"], row
        assert row["error"] == "OSError: injected backup failure", row
        assert not row["failure_json_written"], row
        assert row["rollback_json_written"], row
    elif fault == "rename-fail":
        assert row["old_companion_restored"] and not row["archive_present"], row
        assert not row["rollback_json_written"], row
        assert "rename failure" in (row["error"] or ""), row
    elif fault == "installer":
        assert row["old_companion_restored"] and row["rollback_json_written"], row
        assert "injected" in (row["error"] or ""), row
    elif fault == "game-started":
        assert not row["target_present"] and row["archive_present"] and row["archive_intact"], row
        assert not row["rollback_json_written"], row
        assert "game started" in (row["error"] or ""), row
    elif fault == "altered-archive":
        assert not row["target_present"] and row["archive_present"] and not row["archive_intact"], row
        assert not row["old_companion_restored"], row
        assert "backup failure" in (row["error"] or ""), row
    elif fault == "existing-target":
        assert row["partial_target_present"] and row["archive_intact"], row
        assert not row["old_companion_restored"], row
        assert "partial target" in (row["error"] or ""), row
    elif fault == "success-log":
        assert row["new_companion_installed"] and not row["old_companion_restored"], row
        assert "success evidence failure" in (row["error"] or ""), row
    elif fault == "interrupt-after-rename":
        # A Ctrl-C after the rename must still restore the verified archive.
        assert row["old_companion_restored"] and not row["new_companion_installed"], row
        assert row["rollback_json_written"] and not row["archive_present"], row
        assert (row["error"] or "").startswith("KeyboardInterrupt"), row
    elif fault == "interrupt-partial-install":
        # A Ctrl-C after the installer created the target must never overwrite
        # or delete the partial install: the archive stays intact.
        assert row["partial_target_present"] and row["archive_present"] and row["archive_intact"], row
        assert not row["old_companion_restored"] and not row["rollback_json_written"], row
        assert (row["error"] or "").startswith("KeyboardInterrupt"), row
    elif fault == "systemexit-after-rename":
        # A SystemExit after the rename is inside the same protected BaseException
        # scope and must restore the verified archive.
        assert row["old_companion_restored"] and not row["new_companion_installed"], row
        assert row["rollback_json_written"] and not row["archive_present"], row
        assert (row["error"] or "").startswith("SystemExit"), row
    else:
        raise AssertionError("unexpected fault " + str(fault))


def run_case(fault):
    """Run one scenario end to end and assert its exact outcome."""
    row = scenario(fault)
    check_expected(row)
    return row


def test_upgrade_fault_scenarios():
    problems = []
    for fault in FAULTS:
        try:
            run_case(fault)
        except BaseException as error:  # noqa: BLE001
            problems.append(fault + ": " + type(error).__name__ + ": " + str(error))
    assert not problems, problems


def test_recovered_package_pin_binding():
    real_checker_pin_proof()


def main():
    total = 0
    failed = []
    for fault in FAULTS:
        total += 1
        try:
            run_case(fault)
        except BaseException as error:  # noqa: BLE001
            failed.append(fault)
            print("FAIL scenario:" + fault + ": " + type(error).__name__ + ": " + str(error))
        else:
            print("ok   scenario:" + fault)
    total += 1
    try:
        real_checker_pin_proof()
    except BaseException as error:  # noqa: BLE001
        failed.append("old-package-pin-proof")
        print("FAIL old-package-pin-proof: " + type(error).__name__ + ": " + str(error))
    else:
        print("ok   old-package-pin-proof")
    print(str(total - len(failed)) + "/" + str(total) + " cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
