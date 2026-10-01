#!/usr/bin/env python3
"""Fake-root / Temp-Git regression tests for the reviewed native runner.

Every repository and package is a temporary fixture. No live install, staging
root, Mods directory, save, process enumeration, game launch or native
operation is performed: only the pure review/binding helpers and the early
refusals of ``main`` (which run before any native call) are exercised.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = _load("native_cert_runner", "run_native_certification.py")
upgrade = _load("upgrade_reviewed_companion", "upgrade_reviewed_companion.py")


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _temp_repo(tmp: Path) -> tuple:
    repo = tmp / "repo"
    shutil.copytree(REPO / "AISparring", repo / "AISparring")
    _git(repo, "init")
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=t@example.invalid", "-c", "user.name=fixture", "commit", "-m", "fixture")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo).decode().strip()
    return repo, head


def test_clean_reviewed_head_passes_and_manifest_matches_source():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head = _temp_repo(Path(tmp))
        native.require_reviewed_source(repo, head, "start")
        manifest = native.reviewed_source_manifest(repo, head)
        tracked = subprocess.check_output(
            ["git", "ls-tree", "-r", "--name-only", head, "--", "AISparring"], cwd=repo
        ).decode().splitlines()
        expected = {rel[len("AISparring/"):] for rel in tracked}
        assert set(manifest) == expected, (set(manifest) ^ expected)
        assert "core.lua" in manifest and "ai/baseline_policy.lua" in manifest
        for rel, meta in manifest.items():
            blob = subprocess.check_output(["git", "cat-file", "blob", meta["oid"]], cwd=repo)
            assert meta["size"] == len(blob), rel
            assert meta["sha256"] == hashlib.sha256(blob).hexdigest(), rel
            # The working tree may differ by the checkout's line endings; git
            # still binds it to the reviewed blob.
            oid = native._git_blob_id(repo, rel, (repo / "AISparring" / rel).read_bytes())
            assert oid == meta["oid"], rel
        assert manifest["core.lua"]["oid"] == subprocess.check_output(
            ["git", "rev-parse", head + ":AISparring/core.lua"], cwd=repo).decode().strip()


def test_wrong_head_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head = _temp_repo(Path(tmp))
        try:
            native.require_reviewed_source(repo, "0" * 40, "start")
        except RuntimeError as error:
            assert str(error).startswith("reviewed_commit_mismatch:start"), error
        else:
            raise AssertionError("wrong HEAD accepted")


def test_moved_head_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head = _temp_repo(Path(tmp))
        (repo / "AISparring" / "core.lua").write_text("-- moved\n", encoding="utf-8")
        _git(repo, "add", "-A")
        _git(repo, "-c", "user.email=t@example.invalid", "-c", "user.name=fixture", "commit", "-m", "moved")
        try:
            native.require_reviewed_source(repo, head, "start")
        except RuntimeError as error:
            assert str(error).startswith("reviewed_commit_mismatch:start"), error
        else:
            raise AssertionError("moved HEAD accepted")


def test_tracked_and_untracked_changes_are_refused():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head = _temp_repo(Path(tmp))
        (repo / "AISparring" / "core.lua").write_text("-- dirty\n", encoding="utf-8")
        try:
            native.require_reviewed_source(repo, head, "start")
        except RuntimeError as error:
            assert str(error) == "source_dirty:start", error
        else:
            raise AssertionError("tracked change accepted")
        _git(repo, "checkout", "--", ".")
        (repo / "AISparring" / "untracked.lua").write_text("-- new\n", encoding="utf-8")
        try:
            native.require_reviewed_source(repo, head, "start")
        except RuntimeError as error:
            assert str(error) == "source_dirty:start", error
        else:
            raise AssertionError("untracked change accepted")


def test_main_refuses_existing_attempt_directory_before_any_native_call():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        repo, head = _temp_repo(tmp_path)
        out = tmp_path / "native-certification"
        out.mkdir()
        (out / "old.json").write_text("{}", encoding="utf-8")
        try:
            native.main(["--repo", str(repo), "--reviewed-commit", head, "--out", str(out)])
        except RuntimeError as error:
            assert "existing attempt directory" in str(error), error
        else:
            raise AssertionError("existing attempt directory accepted")
        assert (out / "old.json").read_text(encoding="utf-8") == "{}"


def test_main_refuses_dirty_source_before_writing_output():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        repo, head = _temp_repo(tmp_path)
        (repo / "AISparring" / "untracked.lua").write_text("-- new\n", encoding="utf-8")
        out = tmp_path / "native-certification"
        try:
            native.main(["--repo", str(repo), "--reviewed-commit", head, "--out", str(out)])
        except RuntimeError as error:
            assert str(error) == "source_dirty:start", error
        else:
            raise AssertionError("dirty source accepted")
        assert not out.exists()


def _build_fixture_package(tmp: Path) -> tuple:
    repo, head = _temp_repo(tmp)
    package = tmp / "package"
    discovery = tmp / "discovery.json"
    built = native.installer.build_package(repo / "AISparring", package, discovery)
    assert built["ok"], built
    return repo, head, package


def test_source_binding_accepts_the_reviewed_package():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        verdict = native.bind_package_sources(package, manifest, repo)
        assert verdict["ok"], verdict


def test_source_binding_refuses_a_byte_mismatch():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        (package / "live" / "AISparring" / "core.lua").write_text("-- tampered\n", encoding="utf-8")
        verdict = native.bind_package_sources(package, manifest, repo)
        assert not verdict["ok"], verdict
        assert any(problem.startswith("byte_mismatch:live/AISparring/core.lua") for problem in verdict["problems"]), verdict


def test_source_binding_refuses_a_file_set_mismatch():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        (package / "staged" / "ai" / "AISparring" / "extra.lua").write_text("-- extra\n", encoding="utf-8")
        verdict = native.bind_package_sources(package, manifest, repo)
        assert not verdict["ok"], verdict
        assert "file_set_mismatch:staged/ai/AISparring/" in verdict["problems"], verdict


def test_source_binding_refuses_an_unverified_package():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        record = native.staging.read_json(package / native.installer.PACKAGE_MANIFEST_NAME)
        record["digest"] = "0" * 64
        native.staging.write_json(package / native.installer.PACKAGE_MANIFEST_NAME, record)
        verdict = native.bind_package_sources(package, manifest, repo)
        assert not verdict["ok"], verdict
        assert any(problem.startswith("package_unverified") for problem in verdict["problems"]), verdict


def test_source_binding_excludes_only_the_top_level_config():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        assert native.bind_package_sources(package, manifest, repo)["ok"]
        nested = package / "live" / "AISparring" / "ai" / "config.lua"
        nested.write_text("return {}\n", encoding="utf-8")
        verdict = native.bind_package_sources(package, manifest, repo)
        assert not verdict["ok"], verdict
        assert "file_set_mismatch:live/AISparring/" in verdict["problems"], verdict


def test_source_binding_handles_binary_modules():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        repo = tmp_path / "repo"
        shutil.copytree(REPO / "AISparring", repo / "AISparring")
        (repo / "AISparring" / "blob.bin").write_bytes(bytes(range(256)) * 4)
        _git(repo, "init")
        _git(repo, "add", "-A")
        _git(repo, "-c", "user.email=t@example.invalid", "-c", "user.name=fixture", "commit", "-m", "binary fixture")
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo).decode().strip()
        package = tmp_path / "package"
        built = native.installer.build_package(repo / "AISparring", package, tmp_path / "discovery.json")
        assert built["ok"], built
        manifest = native.reviewed_source_manifest(repo, head)
        assert native.bind_package_sources(package, manifest, repo)["ok"]
        (package / "live" / "AISparring" / "blob.bin").write_bytes(b"tampered")
        verdict = native.bind_package_sources(package, manifest, repo)
        assert not verdict["ok"], verdict
        assert "byte_mismatch:live/AISparring/blob.bin" in verdict["problems"], verdict


def test_final_package_pin_refuses_a_self_consistent_replacement():
    with tempfile.TemporaryDirectory() as tmp:
        repo, head, package = _build_fixture_package(Path(tmp))
        manifest = native.reviewed_source_manifest(repo, head)
        original = native.installer.verify_package(package)["digest"]
        assert native.verify_final_package(package, original, manifest, repo)["ok"]
        # Replace every module subtree self-consistently and rewrite the manifest
        # (files and digest together), exactly like a swap during the long run.
        replaced = b"-- replaced self-consistent\n"
        for prefix in ("live", "staged/human", "staged/ai"):
            (package / prefix / "AISparring" / "core.lua").write_bytes(replaced)
        record = native.staging.read_json(package / native.installer.PACKAGE_MANIFEST_NAME)
        replaced_meta = {"sha256": hashlib.sha256(replaced).hexdigest(), "size": len(replaced)}
        for key in list(record["files"]):
            if key.endswith("AISparring/core.lua"):
                record["files"][key] = dict(replaced_meta)
        record["digest"] = native.installer.package_digest(
            record["package_version"], record["discovery_path"], record["files"])
        native.staging.write_json(package / native.installer.PACKAGE_MANIFEST_NAME, record)
        assert native.installer.verify_package(package)["ok"], "replacement must be self-consistent"
        verdict = native.verify_final_package(package, original, manifest, repo)
        assert not verdict["ok"], verdict
        assert any(problem.startswith("package_pin:package_changed_after_acceptance") for problem in verdict["problems"]), verdict
        assert any(problem.startswith("source_binding:") for problem in verdict["problems"]), verdict


def test_upgrade_requires_a_matching_native_report():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "certificate.json"
        path.write_text(json.dumps({"source_commit": "a" * 40, "package_sha256": "b" * 64,
                                    "certificate_id": "cert-1"}), encoding="utf-8")
        report = upgrade.require_native_report(path, "a" * 40, "b" * 64, "cert-1")
        assert report["certificate_id"] == "cert-1"
        for kwargs in (
            {"reviewed_commit": "c" * 40, "package_sha256": "b" * 64, "certificate_id": "cert-1"},
            {"reviewed_commit": "a" * 40, "package_sha256": "d" * 64, "certificate_id": "cert-1"},
            {"reviewed_commit": "a" * 40, "package_sha256": "b" * 64, "certificate_id": "cert-2"},
        ):
            try:
                upgrade.require_native_report(path, kwargs["reviewed_commit"], kwargs["package_sha256"],
                                              kwargs["certificate_id"])
            except RuntimeError as error:
                assert "Native certification report mismatch" in str(error), error
            else:
                raise AssertionError("mismatched report accepted: " + repr(kwargs))


def test_upgrade_refuses_a_missing_native_report():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            upgrade.require_native_report(Path(tmp) / "absent.json", "a" * 40, "b" * 64, "cert")
        except RuntimeError as error:
            assert "report missing" in str(error), error
        else:
            raise AssertionError("missing report accepted")


def _run_all() -> int:
    tests = sorted(
        (name, value) for name, value in globals().items()
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
