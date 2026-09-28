"""Prepare the reviewed minimal local adaptation of the pinned upstream server.

Does not start a listener. Source and dependencies remain ignored local staging.
Adjudication is unchanged: only the listener address and admin listener change.

Produce/verify contract (single owned path, no incompatible producer/checker):

- **Source** (``src/``, ``package.json``, ``package-lock.json``, ``tsconfig.json``,
  ``LICENSE.md``) is copied **only** for paths that are git-tracked in the pinned
  upstream, so an unreviewed file can never enter the adaptation.
- **Dependencies** (``node_modules``) are the reviewed lock/install tree. They are
  copied wholesale, *not* filtered by git-tracking (the tree is gitignored), so the
  compiler and native binaries are present. Every dependency file is hashed into
  ``runtime_files`` and each declared runtime dependency into ``dependency_hashes``;
  native ``*.node`` binaries are listed in ``native_files``.
- The upstream tree is never written: only the destination copy's ``src/main.ts`` is
  patched and the pinned compiler builds ``dist/main.js`` from it.

The produced ``AISparring-adaptation.json`` is exactly the manifest consumed by
``practice_host.verify_server_adaptation``.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import staging  # noqa: E402

PIN = "d664c29523b827d53dfa1a181e5b2baf1aefac4f"
UPSTREAM = "https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI-Server"
MATCH_OLD = "server.listen(PORT, '0.0.0.0', () => {"
MATCH_NEW = "server.listen(PORT, '127.0.0.1', () => {"
ADMIN_OLD = "adminServer.listen(ADMIN_PORT, '127.0.0.1', () => {\n\tconsole.log(`Admin server listening on 127.0.0.1:${ADMIN_PORT}`)\n})"
ADMIN_NEW = "// AISparring local adaptation: unused admin listener disabled."
# Reviewed git-tracked source and the reviewed (gitignored) dependency install tree.
SOURCE_ITEMS = ("src", "package.json", "package-lock.json", "tsconfig.json", "LICENSE.md")
DEPENDENCY_ITEMS = ("node_modules",)
DEFAULT_RUNTIME_DEPS = ("better-sqlite3", "uuid")

def adapt(source: str) -> str:
    source = source.replace("\r\n", "\n")
    for old, new in ((MATCH_OLD, MATCH_NEW), (ADMIN_OLD, ADMIN_NEW)):
        if source.count(old) != 1:
            raise ValueError("Pinned listener source did not match exactly once")
        source = source.replace(old, new, 1)
    return source

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def _default_git(args):
    return subprocess.check_output(["git", *args], text=True)

def _copy_items(source_root: Path, destination_root: Path, names, tracked, *, filter_tracked: bool) -> None:
    """Copy input items; only git-tracked paths are copied when ``filter_tracked``."""
    for name in names:
        item = source_root / name
        if not item.exists():
            raise ValueError(f"Missing prepared upstream input: {name}")
        if item.is_dir():
            for path in sorted(item.rglob("*")):
                if path.is_symlink() or path.is_junction():
                    raise ValueError(f"Refusing input reparse point: {path}")
                if not path.is_file():
                    continue
                rel = path.relative_to(source_root).as_posix()
                if filter_tracked and rel not in tracked:
                    continue
                target = destination_root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
        else:
            if item.is_symlink() or item.is_junction():
                raise ValueError(f"Refusing input reparse point: {item}")
            shutil.copy2(item, destination_root / item.relative_to(source_root))

def _default_build(destination: Path, node_executable: str) -> None:
    tsc = destination / "node_modules" / "typescript" / "bin" / "tsc"
    if not tsc.is_file():
        raise ValueError("Refusing: reviewed dependency tree has no TypeScript compiler")
    subprocess.run(
        [node_executable, str(tsc), "-p", str(destination / "tsconfig.json")],
        cwd=destination,
        check=True,
        timeout=120,
    )

def _runtime_manifest(destination: Path, runtime_deps) -> tuple:
    """Full hash manifest of the copied dependency tree, with native binaries."""
    node_modules = destination / "node_modules"
    runtime_files: dict = {}
    for path in sorted(node_modules.rglob("*")):
        if path.is_file():
            runtime_files[path.relative_to(destination).as_posix()] = staging.sha256_file(path)
    dependency_hashes: dict = {}
    for name in runtime_deps:
        dep_dir = node_modules / name
        if not dep_dir.is_dir():
            raise ValueError(f"Missing reviewed runtime dependency: {name}")
        dependency_hashes[name] = staging._digest_of(staging.hash_tree(dep_dir))
    native_files = sorted(
        path.relative_to(destination).as_posix() for path in node_modules.rglob("*.node") if path.is_file()
    )
    return runtime_files, dependency_hashes, native_files

def prepare(source: Path, destination: Path, node: str = "node", *, repo=None, git=None, which=None, build=None, runtime_deps=None) -> dict:
    repo = Path(repo or REPO).resolve()
    git = git or _default_git
    which = which or shutil.which
    build = build or _default_build
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if not destination.is_relative_to(repo / "work") or destination == (repo / "work").resolve():
        raise ValueError("Server output must be a new subdirectory of repository work/")
    if destination.exists() or source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError("Refusing existing or overlapping server destination")
    for parent in (destination, *destination.parents):
        if parent.is_symlink() or parent.is_junction():
            raise ValueError("Refusing destination reparse point")
    node_executable = which(node)
    if not node_executable:
        raise ValueError("Refusing: Node executable could not be resolved")
    commit = git(["-C", str(source), "rev-parse", "HEAD"]).strip()
    dirty = git(["-C", str(source), "status", "--porcelain", "--untracked-files=no"])
    if commit != PIN or dirty.strip():
        raise ValueError("Upstream must be the clean pinned revision")
    # M3: refuse any untracked source so only the reviewed tree is copied.
    untracked = git(["-C", str(source), "status", "--porcelain", "--untracked-files=all"])
    if untracked.strip():
        raise ValueError("Refusing untracked upstream source")
    tracked = set(git(["-C", str(source), "ls-files", "-z"]).split("\0"))
    for name in SOURCE_ITEMS + DEPENDENCY_ITEMS:
        if not (source / name).exists():
            raise ValueError(f"Missing prepared upstream input: {name}")
    original = source / "src" / "main.ts"
    patched = adapt(original.read_text(encoding="utf-8"))
    destination.mkdir(parents=True)
    # Source filtered by git-tracking; dependencies copied from the reviewed
    # install tree wholesale so tsc and native binaries survive.
    _copy_items(source, destination, SOURCE_ITEMS, tracked, filter_tracked=True)
    _copy_items(source, destination, DEPENDENCY_ITEMS, tracked, filter_tracked=False)
    (destination / "src" / "main.ts").write_text(patched, encoding="utf-8", newline="\n")
    build(destination, node_executable)
    built_entry = destination / "dist" / "main.js"
    if not built_entry.is_file():
        raise ValueError("Refusing: build produced no dist/main.js")
    built_text = built_entry.read_text(encoding="utf-8", errors="replace")
    if MATCH_NEW not in built_text or "adminServer.listen" in built_text:
        raise ValueError("Refusing: built dist/main.js is not the reviewed loopback/admin-disabled adaptation")
    runtime_files, dependency_hashes, native_files = _runtime_manifest(
        destination, runtime_deps if runtime_deps is not None else DEFAULT_RUNTIME_DEPS
    )
    if not native_files:
        raise ValueError("Refusing: reviewed dependency tree binds no native binaries")
    manifest = {
        "schema": "aisparring.local_server.v1",
        "upstream_commit": PIN,
        "upstream_url": UPSTREAM,
        "original_main_sha256": digest(original),
        "changes": ["match listener bound to 127.0.0.1", "admin listener disabled"],
        "node_executable": str(Path(node_executable)),
        "node_sha256": digest(Path(node_executable)),
        "source_files": {
            p.relative_to(destination).as_posix(): digest(p)
            for p in sorted((destination / "src").rglob("*"))
            if p.is_file()
        },
        "built_files": {
            p.relative_to(destination).as_posix(): digest(p)
            for p in sorted((destination / "dist").rglob("*"))
            if p.is_file()
        },
        "runtime_files": runtime_files,
        "dependency_hashes": dependency_hashes,
        "native_files": native_files,
        "package_lock_sha256": digest(destination / "package-lock.json"),
    }
    (destination / "AISparring-adaptation.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    return {
        "destination": str(destination),
        "commit": PIN,
        "built_files": len(manifest["built_files"]),
        "runtime_files": len(manifest["runtime_files"]),
        "native_files": len(manifest["native_files"]),
        "started": False,
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, default=REPO / "work" / "local-server")
    parser.add_argument("--node", default="node")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.destination, args.node), indent=2))
