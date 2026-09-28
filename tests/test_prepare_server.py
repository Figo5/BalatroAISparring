#!/usr/bin/env python3
"""prepare_server tests: source filtering, dependency copy and manifest binding.

Everything is a synthetic temp tree with an injected git provider and builder: no
real git, npm, node, server launch, network or live path is touched. The fixtures
expose the real defect the root build hit: the dependency install tree is
gitignored, so filtering every copied input by git-tracking dropped
``node_modules/typescript/bin/tsc`` (and the native binaries) and the build failed.
They also prove the produced ``AISparring-adaptation.json`` is the exact manifest
``practice_host.verify_server_adaptation`` consumes, so producer and checker cannot
drift apart.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import practice_host  # noqa: E402
import prepare_server  # noqa: E402
import staging  # noqa: E402

PIN = prepare_server.PIN

MOTHER_MAIN = (
    "import { createServer } from 'node:http'\n"
    "const server = createServer()\n"
    "server.listen(PORT, '0.0.0.0', () => {\n"
    "\tconsole.log(`Match server listening on 0.0.0.0:${PORT}`)\n"
    "})\n"
    "adminServer.listen(ADMIN_PORT, '127.0.0.1', () => {\n"
    "\tconsole.log(`Admin server listening on 127.0.0.1:${ADMIN_PORT}`)\n"
    "})\n"
)

TRACKED = (
    "LICENSE.md",
    "package-lock.json",
    "package.json",
    "src/Client.ts",
    "src/main.ts",
    "tsconfig.json",
)
UNTRACKED_SOURCE = "src/extra_unreviewed.ts"
# Dependencies are gitignored: nothing under node_modules is ever in the tracked set.
DEPENDENCY_FILES = (
    "node_modules/better-sqlite3/build/Release/better_sqlite3.node",
    "node_modules/better-sqlite3/package.json",
    "node_modules/typescript/bin/tsc",
    "node_modules/uuid/index.js",
    "node_modules/uuid/package.json",
)


def _make_upstream(tmp: Path) -> Path:
    source = tmp / "upstream"
    (source / "src").mkdir(parents=True, exist_ok=True)
    (source / "src" / "main.ts").write_text(MOTHER_MAIN, encoding="utf-8")
    (source / "src" / "Client.ts").write_text("export const client = 1\n", encoding="utf-8")
    (source / "src" / "extra_unreviewed.ts").write_text("export const extra = 1\n", encoding="utf-8")
    for name in ("package.json", "package-lock.json", "tsconfig.json", "LICENSE.md"):
        (source / name).write_text("{}\n" if name.endswith(".json") else "license\n", encoding="utf-8")
    for rel in DEPENDENCY_FILES:
        target = source / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"dependency:" + rel.encode("utf-8") + b"\x00")
    return source


def make_git(*, commit=PIN, dirty="", untracked="", tracked=TRACKED):
    def git(args):
        if "rev-parse" in args:
            return commit + "\n"
        if "status" in args and "--untracked-files=no" in args:
            return dirty
        if "status" in args and "--untracked-files=all" in args:
            return untracked
        if "ls-files" in args:
            return "\0".join(tracked) + "\0"
        raise AssertionError(f"unexpected git args: {args}")

    return git


def fake_build(destination, node_executable):
    dist = Path(destination) / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(destination) / "src" / "main.ts", dist / "main.js")


def _config(tmp: Path, repo: Path, destination: Path):
    return practice_host.default_config(
        repo_root=repo,
        work_dir=repo / "work" / "aisparring-host",
        session_root=repo / "work" / "aisparring-host" / "sessions",
        staging_root=repo / "staging",
        backup_root=repo / "backups",
        live_install_root=tmp / "live" / "Balatro",
        live_appdata_root=tmp / "appdata" / "Balatro",
        steam_root=tmp / "Steam",
        server_root=destination,
        server_manifest=destination / "AISparring-adaptation.json",
        node_executable=sys.executable,
        match_port=8788,
    )


def _prepare(tmp: Path, *, git=None, build=fake_build):
    repo = tmp / "repo"
    repo.mkdir(parents=True, exist_ok=True)
    source = _make_upstream(tmp)
    destination = repo / "work" / "local-server"
    result = prepare_server.prepare(
        source,
        destination,
        sys.executable,
        repo=repo,
        git=git or make_git(),
        which=lambda name: sys.executable,
        build=build,
    )
    return repo, destination, result


def test_prepare_copies_dependencies_independent_of_git_tracking():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo, destination, result = _prepare(tmp)

        # Dependencies are gitignored, yet the compiler and native binary must be
        # present: this is exactly the root build failure (MODULE_NOT_FOUND tsc).
        assert (destination / "node_modules" / "typescript" / "bin" / "tsc").is_file()
        assert (destination / "node_modules" / "better-sqlite3" / "build" / "Release" / "better_sqlite3.node").is_file()
        assert (destination / "node_modules" / "uuid" / "index.js").is_file()

        # Tracked source is copied; the patched original is the loopback/admin build.
        assert (destination / "src" / "Client.ts").is_file()
        patched = (destination / "src" / "main.ts").read_text(encoding="utf-8")
        assert practice_host.SERVER_BIND_OK in patched
        assert practice_host.SERVER_ADMIN_OK in patched
        assert practice_host.SERVER_BIND_BAD not in patched
        assert prepare_server.ADMIN_OLD not in patched

        manifest = json.loads((destination / "AISparring-adaptation.json").read_text(encoding="utf-8"))
        assert manifest["upstream_commit"] == PIN
        assert manifest["changes"] == list(practice_host.SERVER_CHANGES)
        assert manifest["runtime_files"]
        assert set(manifest["dependency_hashes"]) == {"better-sqlite3", "uuid"}
        assert manifest["native_files"] == ["node_modules/better-sqlite3/build/Release/better_sqlite3.node"]
        assert manifest["original_main_sha256"] == prepare_server.digest(
            (tmp / "upstream" / "src" / "main.ts")
        )
        assert result["native_files"] == 1
        # Preserve the upstream original: prepare must never write into the source.
        assert (tmp / "upstream" / "src" / "main.ts").read_text(encoding="utf-8") == MOTHER_MAIN

        # Producer/checker compatibility: the manifest passes the real verifier.
        config = _config(tmp, repo, destination)
        verdict = practice_host.verify_server_adaptation(config, which=lambda name: sys.executable)
        assert verdict["ok"] is True, verdict.get("problems")


def test_prepare_filters_source_by_git_tracking_only():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        _repo, destination, _result = _prepare(tmp)
        assert (destination / "src" / "Client.ts").is_file()
        # An untracked source file is never copied, even though it exists upstream.
        assert not (destination / UNTRACKED_SOURCE).exists()
        # The gitignored dependency tree is copied despite not being tracked.
        assert (destination / "node_modules" / "typescript" / "bin" / "tsc").is_file()


def test_prepare_refuses_untracked_upstream_source():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        source = _make_upstream(tmp)
        try:
            prepare_server.prepare(
                source,
                repo / "work" / "local-server",
                sys.executable,
                repo=repo,
                git=make_git(untracked="?? src/extra_unreviewed.ts\n"),
                which=lambda name: sys.executable,
                build=fake_build,
            )
        except ValueError as error:
            assert "untracked" in str(error)
        else:
            raise AssertionError("expected untracked-source refusal")


def test_prepare_refuses_wrong_pin():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        source = _make_upstream(tmp)
        try:
            prepare_server.prepare(
                source,
                repo / "work" / "local-server",
                sys.executable,
                repo=repo,
                git=make_git(commit="deadbeef"),
                which=lambda name: sys.executable,
                build=fake_build,
            )
        except ValueError as error:
            assert "pinned" in str(error)
        else:
            raise AssertionError("expected pin refusal")


def test_prepare_refuses_missing_reviewed_dependency():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        source = _make_upstream(tmp)
        shutil.rmtree(source / "node_modules" / "uuid")
        try:
            prepare_server.prepare(
                source,
                repo / "work" / "local-server",
                sys.executable,
                repo=repo,
                git=make_git(),
                which=lambda name: sys.executable,
                build=fake_build,
            )
        except ValueError as error:
            assert "uuid" in str(error)
        else:
            raise AssertionError("expected missing-dependency refusal")


def test_prepare_refuses_build_without_dist_entry():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        source = _make_upstream(tmp)
        try:
            prepare_server.prepare(
                source,
                repo / "work" / "local-server",
                sys.executable,
                repo=repo,
                git=make_git(),
                which=lambda name: sys.executable,
                build=lambda destination, node_executable: None,
            )
        except ValueError as error:
            assert "dist/main.js" in str(error)
        else:
            raise AssertionError("expected build refusal")


def test_prepare_refuses_destination_outside_work_and_existing():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        repo.mkdir(parents=True, exist_ok=True)
        source = _make_upstream(tmp)
        for destination in (tmp / "elsewhere", repo / "work"):
            try:
                prepare_server.prepare(
                    source,
                    destination,
                    sys.executable,
                    repo=repo,
                    git=make_git(),
                    which=lambda name: sys.executable,
                    build=fake_build,
                )
            except ValueError:
                pass
            else:
                raise AssertionError(f"expected destination refusal for {destination}")
        # Existing destination is refused too.
        existing = repo / "work" / "local-server"
        existing.mkdir(parents=True)
        try:
            prepare_server.prepare(
                source,
                existing,
                sys.executable,
                repo=repo,
                git=make_git(),
                which=lambda name: sys.executable,
                build=fake_build,
            )
        except ValueError:
            pass
        else:
            raise AssertionError("expected existing-destination refusal")


def test_dependency_hashes_match_staging_hash_tree():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        _repo, destination, _result = _prepare(tmp)
        manifest = json.loads((destination / "AISparring-adaptation.json").read_text(encoding="utf-8"))
        for name, declared in manifest["dependency_hashes"].items():
            recomputed = staging._digest_of(staging.hash_tree(destination / "node_modules" / name))
            assert declared == recomputed, name


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
