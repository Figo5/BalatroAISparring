#!/usr/bin/env python3
"""Fail-closed packaging and first-install helper for the AI Sparring companion.

This module does two strictly separated things:

* :func:`build_package` copies the ``AISparring`` module into an isolated
  ``repo/work`` package tree, rewrites the *copied* ``config.lua`` for the live
  role and for two byte-identical staged roles, and records an immutable
  SHA256 manifest of every package file. Building a package never needs live
  access, a certificate or a running/closed game.
* :func:`install_companion` installs exactly one new ``<live Mods>/AISparring``
  directory, and only after every gate passes: the package manifest verifies,
  an explicit reviewed acceptance record binds the reviewed package hash, the
  real isolation certificate checker accepts the staging root, the target is the
  exact owned path, a complete current Mods backup verifies from the backup
  copy hashes, and the live game is closed. The complete module is staged in an
  owned temporary directory under a known staging parent that is proved to be on
  the *same filesystem volume* as the live Mods target; every staged file is then
  re-hashed against the previously verified immutable package manifest. Only a
  final atomic ``os.rename`` of that fully prepared, fully re-verified directory
  introduces ``Mods/AISparring``; a cross-volume staging parent is refused rather
  than silently copied. The process, target and source-integrity checks are all
  repeated immediately before the rename, and only the created staging temp is
  ever removed on failure.

Hard guarantees:

* nothing is ever written *inside* live Mods until the final atomic rename, so a
  game launch during preparation can never observe a partly formed mod;
* no save, other mod, symlink/junction/reparse point, arbitrary target or
  running game is ever written or deleted;
* the repository source and every other module are never modified;
* the installer never launches or terminates Balatro and never writes a secret;
* an existing target is refused: replace/upgrade is explicitly out of scope;
* only the created staging temp under the known staging parent is ever cleaned,
  never an arbitrary directory;
* the success receipt is committed only *after* the rename: a failed rename
  never leaves a successful-looking receipt, and a receipt-finalization failure
  after the rename keeps the pending receipt and reports the mod as installed;
* the certificate is bound to the exact staged role bytes and to the accepted
  package digest: a certificate measured for older modules cannot authorize a
  newer package, and the target root must be the validated live ``appdata/Mods``;
* unreadable process enumeration, volume mismatch and root mismatches fail closed.

Nothing here is a live-operation claim. Actual installation remains a reviewed,
root-run step after the P1 gates, per ``AGENTS.md`` and
``docs/PLAYABLE_WIRING_CONTRACT.md``.

The isolation certificate gate calls the real reusable checker
(``staging.check_isolation_proof`` -> ``isolation_certificate.check_certificate``).
In unit fixtures that checker is injected; the production default always calls
the real one and therefore refuses when no complete certificate exists.

Cross-owner dependency (not implemented here): placing the package's
``staged/<role>/AISparring`` copies into the real staging area before the
certificate is measured is owned by the staging root/isolation owner. This
installer only *verifies* that binding through :func:`package_staging_binding`
and refuses when it does not hold; it never writes into the staging area.
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import launch_practice  # noqa: E402
import staging  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PACKAGE_ROOT = REPO_ROOT / "work" / "aisparring-package"
DEFAULT_DISCOVERY_PATH = REPO_ROOT / "work" / "aisparring-host" / "practice_host.json"
DEFAULT_BACKUP_ROOT = REPO_ROOT / "backups"
DEFAULT_RECEIPT_ROOT = REPO_ROOT / "work"
DEFAULT_STAGE_PARENT = REPO_ROOT / "work" / "aisparring-install-stage"

TARGET_NAME = "AISparring"
MOD_MANIFEST_NAME = "AISparring.json"
CONFIG_NAME = "config.lua"
PACKAGE_MANIFEST_NAME = "manifest.json"
EXPECTED_VERSION = "0.1.0-dev"

PACKAGE_SCHEMA = "aisparring.package_manifest.v1"
ACCEPTANCE_SCHEMA = "aisparring.install_acceptance.v1"
RECEIPT_SCHEMA = "aisparring.install_receipt.v1"
REPORT_SCHEMA = "aisparring.install_result.v1"

STAGED_ROLES = ("human", "ai")
STAGING_TEMP_PREFIX = ".aisparring-install-"

PACKAGE_EXCLUDE_DIRNAMES = frozenset(
    name.lower()
    for name in (
        *sorted(staging.COPY_EXCLUDE_DIRNAMES),
        ".idea",
        ".vscode",
        ".pytest_cache",
    )
)
PACKAGE_EXCLUDE_NAMES = frozenset(
    name.lower()
    for name in (
        *sorted(staging.RUNTIME_STATE_NAMES),
        ".ds_store",
        "thumbs.db",
        "desktop.ini",
    )
)
PACKAGE_EXCLUDE_SUFFIXES = tuple(
    dict.fromkeys((*staging.RUNTIME_STATE_SUFFIXES, ".pyc", ".pyo", ".tmp"))
)

PACKAGE_HASH_POLICY = staging.HashPolicy(exclude_names=(PACKAGE_MANIFEST_NAME,))
# Role bodies (live/staged) may differ only by their generated ``config.lua``; the
# shared module bytes must be identical, so the body comparison ignores the config.
PACKAGE_BODY_POLICY = staging.HashPolicy(exclude_names=(PACKAGE_MANIFEST_NAME, CONFIG_NAME))


class InstallError(staging.StagingError):
    """Typed packaging/install failure; ``code`` is stable and safe to log."""


# ---------------------------------------------------------------------------
# Lua-safe config rendering
# ---------------------------------------------------------------------------

def lua_quote(value: str) -> str:
    """Render ``value`` as a double-quoted Lua string literal.

    Backslash, quote and control characters are escaped; other control bytes use
    Lua's decimal ``\\ddd`` escape so a Windows path can never terminate or
    corrupt the generated config.
    """
    text = str(value)
    if "\x00" in text:
        raise InstallError("lua_path_unrepresentable", "value contains NUL")
    out = ['"']
    for ch in text:
        code = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code == 0x7F:
            out.append("\\%03d" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


CONFIG_HEADER = (
    "-- AISparring companion configuration (installer-generated copy).\n"
    "-- Edit the repository source, never this installed copy.\n"
)


def render_live_config(discovery_path) -> str:
    return (
        CONFIG_HEADER
        + "return {\n"
        + "\tai_enabled = true,\n"
        + "\tcompanion = {\n"
        + '\t\trole = "live",\n'
        + f"\t\tdiscovery_path = {lua_quote(str(discovery_path))},\n"
        + "\t},\n"
        + "}\n"
    )


def render_staged_config() -> str:
    return (
        CONFIG_HEADER
        + "return {\n"
        + "\tai_enabled = true,\n"
        + "\tcompanion = {\n"
        + '\t\trole = "staged",\n'
        + "\t},\n"
        + "}\n"
    )


# ---------------------------------------------------------------------------
# Source / package verification
# ---------------------------------------------------------------------------

def _refuse(code: str, problems: Optional[Sequence[str]] = None, **extra) -> dict:
    payload = {"ok": False, "code": code, "problems": list(problems or (code,))}
    payload.update(extra)
    return payload


def verify_source_version(source_mod_dir, version: str = EXPECTED_VERSION) -> dict:
    source = Path(source_mod_dir)
    manifest = source / MOD_MANIFEST_NAME
    if not source.is_dir():
        return _refuse("source_missing", [str(source)])
    if not manifest.is_file():
        return _refuse("source_manifest_missing", [str(manifest)])
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return _refuse("source_manifest_unreadable", [str(error)])
    problems: list = []
    if not isinstance(data, dict):
        return _refuse("source_manifest_invalid", [str(manifest)])
    if data.get("id") != TARGET_NAME:
        problems.append("source_id_mismatch")
    if data.get("version") != version:
        problems.append("source_version_mismatch")
    if problems:
        return _refuse("source_version_unverified", problems, version=data.get("version"))
    return {"ok": True, "code": "ok", "problems": [], "version": data.get("version")}


def _package_ignore(omitted: list):
    def ignore(dirpath, names):
        skip: list = []
        base = Path(dirpath)
        for name in sorted(names):
            lower = name.lower()
            full = base / name
            if full.is_dir() and lower in PACKAGE_EXCLUDE_DIRNAMES:
                skip.append(name)
                omitted.append({"rel": name, "kind": "excluded_dir"})
                continue
            if lower in PACKAGE_EXCLUDE_NAMES or lower in staging.STEAM_NATIVE_FILES:
                skip.append(name)
                omitted.append({"rel": name, "kind": "excluded_file"})
                continue
            if lower.endswith(PACKAGE_EXCLUDE_SUFFIXES):
                skip.append(name)
                omitted.append({"rel": name, "kind": "runtime_state"})
                continue
        return skip

    return ignore


def _copy_module(source: Path, destination: Path, omitted: list) -> None:
    shutil.copytree(source, destination, ignore=_package_ignore(omitted))


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _volume_key(path):
    """Filesystem-volume identity of the nearest existing ancestor of ``path``.

    On Windows ``os.stat().st_dev`` is the volume serial number; on POSIX it is the
    device id. The installer compares these keys to prove the staging temp and the
    live Mods target share one filesystem, so the final ``os.rename`` is a real
    atomic move instead of a cross-volume copy that could expose a partial mod.
    Resolution never follows a reparse point beyond ``os.stat``'s normal behaviour
    here; the staging parent is separately reparse-checked before use.
    """
    probe = Path(os.path.abspath(str(path)))
    while True:
        try:
            return os.stat(probe).st_dev
        except OSError:
            parent = probe.parent
            if parent == probe:
                raise
            probe = parent


def _same_filesystem(first, second) -> bool:
    """Fail closed: an unreadable/unresolvable path is never treated as same-volume."""
    try:
        return _volume_key(first) == _volume_key(second)
    except OSError:
        return False


def _live_files_from_verified_manifest(package_root, accepted_digest):
    """Re-read the package manifest at execute time and revalidate the accepted digest.

    Returns ``(files, code)``. ``files`` is the ``live/AISparring`` subtree of the
    manifest, or ``None`` on refusal. A manifest that was swapped together with the
    live files between verification and staging recomputes a different
    ``package_digest`` and is refused (``package_changed_after_acceptance``), so the
    reviewer-approved bytes can never be silently replaced by a self-consistent
    newer manifest.
    """
    root = Path(package_root)
    try:
        manifest = staging.read_json(root / PACKAGE_MANIFEST_NAME)
    except (OSError, ValueError):
        return None, "package_manifest_unreadable"
    if not isinstance(manifest, Mapping) or manifest.get("schema") != PACKAGE_SCHEMA:
        return None, "package_manifest_invalid"
    files = manifest.get("files")
    if not isinstance(files, Mapping):
        return None, "package_manifest_invalid"
    recomputed = package_digest(
        manifest.get("package_version"), manifest.get("discovery_path"), files
    )
    if recomputed != manifest.get("digest"):
        return None, "package_manifest_invalid"
    if accepted_digest is not None and recomputed != accepted_digest:
        return None, "package_changed_after_acceptance"
    prefix = f"live/{TARGET_NAME}/"
    subset = {
        rel[len(prefix):]: meta for rel, meta in files.items() if rel.startswith(prefix)
    }
    if not subset:
        return None, "package_live_manifest_missing"
    return subset, "ok"


def package_staging_binding(staging_root, package_root, roles=STAGED_ROLES) -> dict:
    """Bind the certificate's measured staging area to the exact package staged roles.

    The isolation certificate measures ``staging/roles/<role>/.../Mods`` (including
    ``AISparring``) as its layer M. Requiring the staged ``AISparring`` digest to equal
    the package's ``staged/<role>/AISparring`` digest under the same hash policy means
    a certificate measured for older module bytes can never authorize a newer package.
    """
    problems: list = []
    for role in roles:
        package_dir = Path(package_root) / "staged" / role / TARGET_NAME
        try:
            staged_mods = staging.role_paths(staging_root, role).mods
        except staging.StagingError:
            problems.append(f"staged_role_unavailable:{role}")
            continue
        try:
            package_digest_value = staging._tree_digest(package_dir, PACKAGE_HASH_POLICY)
            staged_digest_value = staging._tree_digest(
                staged_mods / TARGET_NAME, PACKAGE_HASH_POLICY
            )
        except staging.StagingError:
            problems.append(f"staged_role_unreadable:{role}")
            continue
        if package_digest_value is None or staged_digest_value is None:
            problems.append(f"staged_role_missing:{role}")
        elif package_digest_value != staged_digest_value:
            problems.append(f"staged_role_mismatch:{role}")
    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "code": "ok" if not problems else "staged_package_mismatch",
        "problems": problems,
    }


def _copy_stage_tree(source, destination) -> None:
    """Copy the already-excluded package live tree into the staging directory."""
    shutil.copytree(source, destination, dirs_exist_ok=True)


def _verify_stage_tree(stage_dir, expected) -> None:
    """Re-hash *every* staged file against the immutable manifest's live subtree.

    ``hash_tree`` refuses links/reparse points and unreadable entries, so a
    corrupted non-config file and a redirected subtree both fail closed.
    """
    staging.assert_no_links(stage_dir, "install staging copy")
    try:
        current = staging.hash_tree(stage_dir, PACKAGE_HASH_POLICY)
    except staging.StagingError as error:
        raise InstallError(error.code, error.message)
    if current != expected:
        missing = sorted(set(expected) - set(current))
        added = sorted(set(current) - set(expected))
        changed = sorted(
            rel for rel in set(expected) & set(current) if expected[rel] != current[rel]
        )
        raise InstallError(
            "staged_verify_failed",
            f"missing={missing} added={added} changed={changed}",
        )


def package_digest(version: str, discovery_path: str, files: Mapping) -> str:
    return staging._digest_of(
        {"version": version, "discovery_path": discovery_path, "files": dict(files)}
    )


def build_package(
    source_mod_dir=None,
    package_root=None,
    discovery_path=None,
    version: str = EXPECTED_VERSION,
) -> dict:
    """Build an isolated package tree; never touches the live game or repository source."""
    source = Path(source_mod_dir or (REPO_ROOT / TARGET_NAME)).resolve()
    root = Path(package_root or DEFAULT_PACKAGE_ROOT)
    if discovery_path is None:
        discovery_path = DEFAULT_DISCOVERY_PATH
    discovery = Path(os.path.abspath(str(discovery_path)))

    if root.exists():
        return _refuse("package_exists", [str(root)])
    version_verdict = verify_source_version(source, version)
    if not version_verdict["ok"]:
        return version_verdict
    if not discovery.is_absolute():
        return _refuse("discovery_path_not_absolute", [str(discovery)])
    try:
        staging.assert_no_links(source, "mod source")
    except staging.StagingError as error:
        return _refuse(error.code, [error.message])

    omitted: list = []
    live_dir = root / "live" / TARGET_NAME
    staged_dirs = {role: root / "staged" / role / TARGET_NAME for role in STAGED_ROLES}
    try:
        _copy_module(source, live_dir, omitted)
        _write_text(live_dir / CONFIG_NAME, render_live_config(discovery))
        staged_text = render_staged_config()
        for directory in staged_dirs.values():
            _copy_module(source, directory, omitted)
            _write_text(directory / CONFIG_NAME, staged_text)
    except OSError as error:
        return _refuse("package_write_failed", [str(error)])

    staged_digests = {
        role: staging._tree_digest(directory, PACKAGE_HASH_POLICY)
        for role, directory in staged_dirs.items()
    }
    if len(set(staged_digests.values())) != 1 or None in staged_digests.values():
        return _refuse("staged_copies_differ", [str(staged_digests)])

    try:
        files = staging.hash_tree(root, PACKAGE_HASH_POLICY)
    except staging.StagingError as error:
        return _refuse(error.code, [error.message])
    digest = package_digest(version, str(discovery), files)
    manifest = {
        "schema": PACKAGE_SCHEMA,
        "package_version": version,
        "discovery_path": str(discovery),
        "staged_roles": list(STAGED_ROLES),
        "files": files,
        "digest": digest,
    }
    staging.write_json(root / PACKAGE_MANIFEST_NAME, manifest)
    return {
        "ok": True,
        "code": "package_built",
        "problems": [],
        "package_root": str(root),
        "manifest": str(root / PACKAGE_MANIFEST_NAME),
        "digest": digest,
        "version": version,
        "discovery_path": str(discovery),
        "files": len(files),
        "omitted": omitted,
    }


def verify_package(package_root=None, version: str = EXPECTED_VERSION) -> dict:
    root = Path(package_root or DEFAULT_PACKAGE_ROOT)
    manifest_path = root / PACKAGE_MANIFEST_NAME
    if not manifest_path.is_file():
        return _refuse("package_manifest_missing", [str(manifest_path)])
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError) as error:
        return _refuse("package_manifest_unreadable", [str(error)])
    if not isinstance(manifest, dict):
        return _refuse("package_manifest_invalid", ["package_manifest_not_an_object"])
    problems: list = []
    if manifest.get("schema") != PACKAGE_SCHEMA:
        problems.append("package_schema_mismatch")
    if manifest.get("package_version") != version:
        problems.append("package_version_mismatch")
    recorded = manifest.get("files") or {}
    if not isinstance(recorded, Mapping):
        return _refuse("package_manifest_invalid", ["package_files_not_an_object"])
    try:
        current = staging.hash_tree(root, PACKAGE_HASH_POLICY)
    except staging.StagingError as error:
        return _refuse(error.code, [error.message])
    for label, difference in (
        ("missing", sorted(set(recorded) - set(current))),
        ("added", sorted(set(current) - set(recorded))),
        ("changed", sorted(rel for rel in set(recorded) & set(current) if recorded[rel] != current[rel])),
    ):
        if difference:
            problems.append(f"package_{label}:{difference[0]}")
    digest = package_digest(
        manifest.get("package_version"), manifest.get("discovery_path"), recorded
    )
    if digest != manifest.get("digest"):
        problems.append("package_digest_mismatch")

    discovery = manifest.get("discovery_path")
    live_config = root / "live" / TARGET_NAME / CONFIG_NAME
    expected_live = render_live_config(discovery) if discovery else ""
    if not live_config.is_file() or live_config.read_text(encoding="utf-8") != expected_live:
        problems.append("live_config_mismatch")
    staged_text = render_staged_config()
    staged_digests: list = []
    staged_roles = list(manifest.get("staged_roles") or ())
    for role in staged_roles:
        staged_config = root / "staged" / role / TARGET_NAME / CONFIG_NAME
        if not staged_config.is_file() or staged_config.read_text(encoding="utf-8") != staged_text:
            problems.append(f"staged_config_mismatch:{role}")
        staged_digests.append(
            staging._tree_digest(root / "staged" / role / TARGET_NAME, PACKAGE_HASH_POLICY)
        )
    if len(set(staged_digests)) != 1:
        problems.append("staged_copies_differ")
    try:
        live_body = staging._tree_digest(root / "live" / TARGET_NAME, PACKAGE_BODY_POLICY)
        staged_bodies = [
            staging._tree_digest(root / "staged" / role / TARGET_NAME, PACKAGE_BODY_POLICY)
            for role in staged_roles
        ]
    except staging.StagingError as error:
        return _refuse(error.code, [error.message])
    if live_body is None or any(body is None or body != live_body for body in staged_bodies):
        problems.append("live_staged_body_mismatch")

    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "code": "ok" if not problems else "package_unverified",
        "problems": problems,
        "path": str(root),
        "manifest": str(manifest_path),
        "digest": manifest.get("digest"),
        "version": manifest.get("package_version"),
        "discovery_path": discovery,
    }


# ---------------------------------------------------------------------------
# Acceptance record and certificate gate
# ---------------------------------------------------------------------------

def load_acceptance(acceptance_path, package_sha256) -> dict:
    """Read and validate the explicit reviewed acceptance record. Never a bare bool."""
    if not acceptance_path:
        return _refuse("acceptance_missing", ["acceptance_path_required"])
    path = Path(acceptance_path)
    if not path.is_file():
        return _refuse("acceptance_missing", ["acceptance_record_missing"])
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return _refuse("acceptance_unreadable", [str(error)])
    problems: list = []
    if not isinstance(record, dict):
        return _refuse("acceptance_invalid", ["acceptance_record_invalid"])
    if record.get("schema") != ACCEPTANCE_SCHEMA:
        problems.append("acceptance_schema_mismatch")
    if record.get("accepted") is not True:
        problems.append("acceptance_not_accepted")
    reviewer = record.get("reviewer")
    if not isinstance(reviewer, str) or not reviewer.strip():
        problems.append("acceptance_reviewer_missing")
    reviewed_unix = record.get("reviewed_unix")
    if isinstance(reviewed_unix, bool) or not isinstance(reviewed_unix, int):
        problems.append("acceptance_reviewed_unix_missing")
    if record.get("package_version") != EXPECTED_VERSION:
        problems.append("acceptance_version_mismatch")
    if not isinstance(package_sha256, str) or record.get("package_sha256") != package_sha256:
        problems.append("acceptance_package_mismatch")
    accepted_certificate_id = record.get("certificate_id")
    if not isinstance(accepted_certificate_id, str) or not accepted_certificate_id.strip():
        problems.append("acceptance_certificate_missing")
    if problems:
        return _refuse("acceptance_unverified", problems)
    reference = {
        "path": str(path),
        "sha256": staging.sha256_file(path),
        "package_sha256": package_sha256,
        "certificate_id": accepted_certificate_id,
        "reviewer": reviewer,
        "reviewed_unix": reviewed_unix,
    }
    return {"ok": True, "code": "ok", "problems": [], "reference": reference}


def default_certificate_check(staging_root, live=None) -> dict:
    """Call the real reusable isolation certificate checker. Fail closed."""
    try:
        verdict = staging.check_isolation_proof(staging_root, live=live)
    except staging.StagingError as error:
        return _refuse(error.code, [error.code])
    except Exception as error:  # noqa: BLE001
        return _refuse("certificate_check_failed", [str(error)])
    if not isinstance(verdict, dict):
        return _refuse("certificate_check_invalid", ["certificate_check_invalid"])
    verdict.setdefault("ok", False)
    verdict.setdefault("code", "ok" if verdict["ok"] else "certificate_invalid")
    return verdict


# ---------------------------------------------------------------------------
# Live backup gate
# ---------------------------------------------------------------------------

def mods_backup_verdict(backup_root, live_mods_root) -> dict:
    """Require a verified backup copy whose Mods subtree still matches live bytes."""
    root = Path(backup_root)
    manifest_path = root / launch_practice.BACKUP_MANIFEST_NAME
    if not manifest_path.is_file():
        return _refuse("mods_backup_missing", [str(manifest_path)])
    try:
        manifest = staging.read_json(manifest_path)
    except (OSError, ValueError) as error:
        return _refuse("mods_backup_unreadable", [str(error)])
    if manifest.get("schema") != launch_practice.BACKUP_SCHEMA:
        return _refuse("mods_backup_schema_mismatch", [str(manifest_path)])
    live_mods = Path(live_mods_root).resolve()
    try:
        live_files = staging.hash_tree(live_mods)
    except staging.StagingError as error:
        return _refuse("mods_unreadable", [error.message])

    problems: list = []
    for key, entry in (manifest.get("entries") or {}).items():
        if not isinstance(entry, Mapping):
            problems.append(f"{key}_entry_invalid")
            continue
        entry_verdict = launch_practice.verify_backup_entry(entry, root)
        if not entry_verdict.get("ok"):
            problems.append(f"{key}_{entry_verdict.get('code')}")
            continue
        source_root = Path(str(entry.get("source_root", ""))).resolve()
        try:
            prefix = live_mods.relative_to(source_root).as_posix()
        except ValueError:
            continue
        if prefix == ".":
            prefix = ""
        try:
            entry_manifest = staging.read_json(entry["manifest"])
        except (OSError, ValueError, KeyError):
            problems.append(f"{key}_entry_unreadable")
            continue
        token = prefix + "/" if prefix else ""
        subset = {
            rel[len(token):]: meta
            for rel, meta in (entry_manifest.get("files") or {}).items()
            if rel.startswith(token)
        }
        if subset != live_files:
            problems.append(f"{key}_live_mods_changed_since_backup")
            continue
        return {
            "ok": True,
            "code": "ok",
            "problems": [],
            "reference": {
                "manifest": str(manifest_path),
                "label": manifest.get("label"),
                "entry": str(key),
                "source_root": str(source_root),
                "entry_manifest": str(entry.get("manifest")),
                "files": len(live_files),
            },
        }
    return _refuse("mods_backup_unverified", problems or ["mods_backup_missing"])


# ---------------------------------------------------------------------------
# Target resolution / process gate
# ---------------------------------------------------------------------------

def _assert_clean_root(path: Path, what: str) -> None:
    raw = Path(os.path.abspath(str(path)))
    staging.assert_no_reparse_between(Path(raw.anchor), raw, what=what, allow_root=True)


def resolve_install_target(live_mods_root, target_dir=None, live=None, overlap_roots=None):
    """Resolve exactly ``<validated live appdata>/Mods/AISparring`` or refuse.

    The given root must be, character for character, the resolved live Mods root
    derived from the validated live roots. ``live=None`` is refused rather than
    falling back to an unchecked path, and a root that overlaps the staging,
    package or backup roots is refused before anything is written.
    """
    if not live_mods_root:
        raise InstallError("mods_root_required")
    if not isinstance(live, Mapping) or not live.get("appdata"):
        raise InstallError("live_roots_unavailable", "live_appdata_missing")
    expected_mods = Path(os.path.abspath(str(Path(live["appdata"]) / "Mods")))
    mods_raw = Path(os.path.abspath(str(live_mods_root)))
    try:
        _assert_clean_root(mods_raw, "live Mods root")
    except staging.StagingError as error:
        raise InstallError(error.code, error.message)
    if os.path.normcase(str(mods_raw)) != os.path.normcase(str(expected_mods)):
        raise InstallError("mods_root_not_live", str(mods_raw))
    for name, root in (overlap_roots or {}).items():
        if _paths_collide(mods_raw, root):
            raise InstallError(
                "mods_root_overlaps_owned_root", f"{mods_raw} overlaps {name} {root}"
            )
    mods = mods_raw.resolve()
    if not mods.is_dir():
        raise InstallError("mods_root_missing", str(mods))
    target = Path(target_dir) if target_dir is not None else mods / TARGET_NAME
    target_raw = Path(os.path.abspath(str(target)))
    if os.path.normcase(str(target_raw.parent)) != os.path.normcase(str(mods_raw)):
        raise InstallError("target_not_owned", str(target_raw))
    if target_raw.name != TARGET_NAME:
        raise InstallError("target_not_owned", str(target_raw))
    return mods, target_raw


def _target_present(target) -> bool:
    """True for a real target, a symlink *or* a dangling junction/reparse point.

    ``Path.exists()``/``is_symlink()`` both return false for a dangling junction, so
    the target check must use ``lexists`` plus the staging reparse probe. Nothing is
    ever deleted here; a present target is merely refused.
    """
    path = Path(target)
    try:
        if os.path.lexists(str(path)):
            return True
        return staging._is_reparse_point(path)
    except OSError:
        return True


def _safe_closed(closed_check) -> dict:
    try:
        verdict = closed_check()
    except staging.StagingError as error:
        return _refuse(error.code, [error.code])
    except Exception as error:  # noqa: BLE001
        return _refuse("closed_check_failed", [str(error)])
    if not isinstance(verdict, dict):
        return _refuse("closed_check_invalid", ["closed_check_invalid"])
    verdict.setdefault("ok", False)
    verdict.setdefault("code", "ok" if verdict["ok"] else "live_balatro_running")
    return verdict


def _combined_process_gate(closed_check, enumerator, staging_root, live_install_root) -> dict:
    """Refuse a live game *and* any non-owned Balatro process at any image path.

    The default closed-game check only recognises a Balatro process under the given
    install root, so a game started from another Steam library would pass. This adds
    the launch-practice unowned-process gate (`check_no_staged_session`, an API owned
    by the launcher/isolation owner): a staged session or a foreign Balatro.exe is
    refused regardless of its image path. The installer never launches or owns a
    staged process, so the only acceptable state is no Balatro process at all.
    """
    verdict = _safe_closed(closed_check)
    if not verdict.get("ok"):
        return verdict
    return _safe_closed(
        lambda: launch_practice.check_no_staged_session(
            enumerator, staging_root, live_install_root=live_install_root
        )
    )


def _assert_no_reparse_under(anchor, path, what: str) -> None:
    try:
        staging.assert_no_reparse_between(Path(anchor), Path(os.path.abspath(str(path))), what=what, allow_root=True)
    except staging.StagingError as error:
        raise InstallError(error.code, error.message)


def _ensure_stage_parent(stage_parent, mods_root) -> Path:
    """Create/reuse the known staging parent, refusing Mods overlap or a reparse point.

    The staging parent must never be inside (or contain) live Mods, so nothing is
    ever written into the user's Mods tree before the final atomic rename.
    """
    raw = Path(os.path.abspath(str(stage_parent)))
    if staging.is_within(mods_root, raw, allow_root=True) or staging.is_within(raw, mods_root, allow_root=True):
        raise InstallError("stage_parent_unsafe", str(raw))
    if not _same_filesystem(raw, mods_root):
        raise InstallError("cross_volume_refused", str(raw))
    _assert_no_reparse_under(Path(raw.anchor), raw, "install staging parent")
    raw.mkdir(parents=True, exist_ok=True)
    return raw


def _recheck_target(mods_raw, target) -> None:
    """Recheck owned-parent containment and reparse immediately before the rename."""
    _assert_no_reparse_under(Path(os.path.abspath(str(target))).anchor, target, "install target")
    parent = Path(os.path.abspath(str(target.parent)))
    if os.path.normcase(str(parent)) != os.path.normcase(str(mods_raw)):
        raise InstallError("target_not_owned", str(target))
    if Path(target).name != TARGET_NAME:
        raise InstallError("target_not_owned", str(target))


def _cleanup_stage(stage_dir, stage_parent) -> None:
    """Remove only a created staging temp under the known staging parent."""
    if stage_dir is None:
        return
    path = Path(stage_dir)
    if not path.name.startswith(STAGING_TEMP_PREFIX):
        return
    if not staging.is_within(stage_parent, path):
        return
    shutil.rmtree(path, ignore_errors=True)


def _paths_collide(first, second) -> bool:
    a = os.path.normcase(os.path.abspath(str(first)))
    b = os.path.normcase(os.path.abspath(str(second)))
    return (
        a == b
        or staging.is_within(first, second, allow_root=True)
        or staging.is_within(second, first, allow_root=True)
    )


def _safe_receipt_root(receipt_root, target, mods_root=None) -> None:
    root = Path(os.path.abspath(str(receipt_root)))
    if _paths_collide(root, target):
        raise InstallError("receipt_root_unsafe", str(root))
    if mods_root is not None and _paths_collide(root, mods_root):
        raise InstallError("receipt_root_unsafe", str(root))


def _receipt_paths(receipt_root, target, mods_root=None, now=None):
    """Return ``(final, pending)`` receipt paths under the isolated receipt root."""
    _safe_receipt_root(receipt_root, target, mods_root=mods_root)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now if now is not None else time.time()))
    token = secrets.token_hex(4)
    directory = Path(receipt_root) / "install-receipts"
    final = directory / f"aisparring-install-{stamp}-{token}.json"
    return final, final.with_name(final.name + ".pending")


def _receipt_payload(target, package_root, package_verdict, backup_verdict, acceptance_verdict,
                     certificate_verdict=None, now=None) -> dict:
    reference = backup_verdict.get("reference") or {}
    acceptance = acceptance_verdict.get("reference") or {}
    return {
        "schema": RECEIPT_SCHEMA,
        "recorded_unix": int(now if now is not None else time.time()),
        "version": package_verdict.get("version"),
        "target": str(target),
        "package_root": str(package_root),
        "package_manifest": str(Path(package_root) / PACKAGE_MANIFEST_NAME),
        "package_sha256": package_verdict.get("digest"),
        "certificate_id": (certificate_verdict or {}).get("certificate_id"),
        "backup_manifest": reference.get("manifest"),
        "backup_label": reference.get("label"),
        "backup_entry": reference.get("entry"),
        "acceptance_path": acceptance.get("path"),
        "acceptance_sha256": acceptance.get("sha256"),
        "acceptance_reviewer": acceptance.get("reviewer"),
        "acceptance_reviewed_unix": acceptance.get("reviewed_unix"),
    }


def write_receipt(receipt_root, target, package_root, package_verdict, backup_verdict,
                  acceptance_verdict, certificate_verdict=None, now=None, path=None,
                  mods_root=None) -> Path:
    final, _ = _receipt_paths(receipt_root, target, mods_root=mods_root, now=now)
    write_path = Path(path) if path is not None else final
    payload = _receipt_payload(target, package_root, package_verdict, backup_verdict,
                               acceptance_verdict, certificate_verdict=certificate_verdict, now=now)
    staging.write_json(write_path, payload)
    return write_path


def _cleanup_receipt(path) -> None:
    if path is None:
        return
    try:
        Path(path).unlink(missing_ok=True)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

def install_companion(
    package_root=None,
    live_mods_root=None,
    staging_root=None,
    acceptance_path=None,
    target_dir=None,
    backup_root=None,
    receipt_root=None,
    stage_parent=None,
    live=None,
    live_install_root=None,
    enumerator=None,
    certificate_check: Optional[Callable] = None,
    acceptance_check: Optional[Callable] = None,
    package_check: Optional[Callable] = None,
    closed_check: Optional[Callable] = None,
    execute: bool = False,
    now=None,
) -> dict:
    """Install one new ``<live Mods>/AISparring`` after every gate passes.

    ``execute`` only controls whether a fully gated run performs the staging,
    verification and final rename; it can never substitute for the acceptance
    record or the certificate. The production defaults for ``acceptance_check``
    and ``certificate_check`` read the real record file and call the real
    certificate checker. ``stage_parent`` is the known staging parent (an
    isolated repo/work area in production, an explicit fixture staging root in
    tests); it must share a filesystem volume with the live Mods target.
    """
    package_root = Path(package_root or DEFAULT_PACKAGE_ROOT)
    staging_root = Path(staging_root or staging.DEFAULT_STAGING_ROOT)
    backup_root = Path(backup_root or DEFAULT_BACKUP_ROOT)
    receipt_root = Path(receipt_root or DEFAULT_RECEIPT_ROOT)
    stage_parent = Path(stage_parent or DEFAULT_STAGE_PARENT)
    live_install_root = Path(live_install_root or staging.DEFAULT_INSTALL)
    enumerator = enumerator or launch_practice.default_enumerator()
    package_check = package_check or verify_package
    acceptance_check = acceptance_check or load_acceptance
    certificate_check = certificate_check or default_certificate_check
    if closed_check is None:
        def closed_check():
            return launch_practice.check_live_balatro_closed(enumerator, live_install_root)

    base = {"schema": REPORT_SCHEMA, "execute": bool(execute), "problems": []}

    if live is None:
        try:
            live = staging.live_roots(install_root=live_install_root)
        except Exception as error:  # noqa: BLE001
            return {**base, "ok": False, "code": "live_roots_unavailable", "problems": [str(error)]}
    if not isinstance(live, Mapping) or not live.get("appdata"):
        return {**base, "ok": False, "code": "live_roots_unavailable", "problems": ["live_appdata_missing"]}

    try:
        package_verdict = package_check(package_root)
    except staging.StagingError as error:
        return {**base, "ok": False, "code": error.code, "problems": [error.code]}
    if not package_verdict.get("ok"):
        return {**base, "ok": False, "code": package_verdict.get("code", "package_unverified"),
                "problems": package_verdict.get("problems", [])}

    acceptance_verdict = acceptance_check(acceptance_path, package_verdict.get("digest"))
    if not acceptance_verdict.get("ok"):
        return {**base, "ok": False, "code": "acceptance_unverified", "problems": acceptance_verdict.get("problems", [])}

    try:
        certificate_verdict = certificate_check(staging_root, live=live)
    except staging.StagingError as error:
        return {**base, "ok": False, "code": error.code, "problems": [error.code]}
    if not isinstance(certificate_verdict, dict):
        return {**base, "ok": False, "code": "certificate_check_invalid", "problems": ["certificate_check_invalid"]}
    if not certificate_verdict.get("ok"):
        return {**base, "ok": False, "code": "certificate_unverified", "problems": certificate_verdict.get("problems", [])}

    accepted_certificate_id = (acceptance_verdict.get("reference") or {}).get("certificate_id")
    actual_certificate_id = certificate_verdict.get("certificate_id")
    if not actual_certificate_id or accepted_certificate_id != actual_certificate_id:
        return {**base, "ok": False, "code": "certificate_mismatch",
                "problems": ["acceptance_certificate_mismatch"]}

    try:
        binding_verdict = package_staging_binding(staging_root, package_root)
    except staging.StagingError as error:
        return {**base, "ok": False, "code": error.code, "problems": [error.code]}
    if not binding_verdict.get("ok"):
        return {**base, "ok": False, "code": binding_verdict["code"],
                "problems": binding_verdict.get("problems", [])}

    overlap_roots = {"staging": staging_root, "package": package_root, "backup": backup_root}
    try:
        mods_root, target = resolve_install_target(
            live_mods_root, target_dir, live=live, overlap_roots=overlap_roots
        )
    except InstallError as error:
        return {**base, "ok": False, "code": error.code, "problems": [error.message]}
    if _target_present(target):
        return {**base, "ok": False, "code": "target_exists", "target": str(target), "problems": ["replace_upgrade_out_of_scope"]}

    try:
        backup_verdict = mods_backup_verdict(backup_root, mods_root)
    except staging.StagingError as error:
        return {**base, "ok": False, "code": error.code, "problems": [error.code]}
    if not backup_verdict.get("ok"):
        return {**base, "ok": False, "code": "mods_backup_unverified", "problems": backup_verdict.get("problems", [])}

    closed_verdict = _combined_process_gate(closed_check, enumerator, staging_root, live_install_root)
    if not closed_verdict.get("ok"):
        return {**base, "ok": False, "code": closed_verdict.get("code", "live_balatro_running"),
                "problems": closed_verdict.get("problems", []), "target": str(target)}

    plan = {
        **base,
        "ok": True,
        "code": "install_planned",
        "target": str(target),
        "mods_root": str(mods_root),
        "stage_parent": str(stage_parent),
        "package_sha256": package_verdict.get("digest"),
        "backup": backup_verdict.get("reference"),
        "acceptance": acceptance_verdict.get("reference"),
        "certificate_id": certificate_verdict.get("certificate_id"),
    }
    if not execute:
        return plan

    live_source = package_root / "live" / TARGET_NAME
    if not (live_source / CONFIG_NAME).is_file():
        return {**base, "ok": False, "code": "package_live_missing", "problems": [str(live_source)]}

    mods_raw = Path(os.path.abspath(str(live_mods_root))) if live_mods_root else target.parent
    temp_dir = None
    pending_receipt = None
    final_receipt = None
    try:
        stage_parent = _ensure_stage_parent(stage_parent, mods_root)
        temp_dir = Path(tempfile.mkdtemp(prefix=STAGING_TEMP_PREFIX, dir=str(stage_parent)))
        staging.assert_no_reparse_between(stage_parent, temp_dir, what="install staging dir")

        expected_live, live_code = _live_files_from_verified_manifest(
            package_root, package_verdict.get("digest")
        )
        if expected_live is None:
            raise InstallError(live_code)

        _copy_stage_tree(live_source, temp_dir)
        _verify_stage_tree(temp_dir, expected_live)

        final_receipt, pending_receipt = _receipt_paths(receipt_root, target, mods_root=mods_root, now=now)
        try:
            write_receipt(receipt_root, target, package_root, package_verdict, backup_verdict,
                          acceptance_verdict, certificate_verdict, now=now, path=pending_receipt,
                          mods_root=mods_root)
        except OSError as error:
            raise InstallError("receipt_write_failed", str(error))

        # Final integrity re-hash first, then a fresh backup recheck, then the
        # immediate process and target checks, then the atomic rename. Nothing is
        # written inside Mods before that rename.
        if not staging.is_within(stage_parent, temp_dir):
            raise InstallError("install_stage_escape", str(temp_dir))
        staging.assert_no_reparse_between(stage_parent, temp_dir, what="install staging dir")
        _verify_stage_tree(temp_dir, expected_live)

        try:
            backup_recheck = mods_backup_verdict(backup_root, mods_root)
        except staging.StagingError as error:
            raise InstallError(error.code, error.message)
        if not backup_recheck.get("ok"):
            raise InstallError("mods_backup_unverified", ",".join(backup_recheck.get("problems", [])))

        closed_recheck = _combined_process_gate(closed_check, enumerator, staging_root, live_install_root)
        if not closed_recheck.get("ok"):
            raise InstallError(closed_recheck.get("code", "live_balatro_running"))

        _recheck_target(mods_raw, target)
        if _target_present(target):
            raise InstallError("target_exists")

        os.rename(str(temp_dir), str(target))
        temp_dir = None
        try:
            os.replace(str(pending_receipt), str(final_receipt))
            pending_receipt = None
        except OSError as error:
            # The mod is live: never delete the pending receipt, never claim the
            # install failed, and never roll back the installed directory.
            return {
                **plan,
                "ok": False,
                "code": "installed_receipt_uncommitted",
                "installed": True,
                "problems": [f"receipt_finalize_failed:{error}"],
                "target": str(target),
                "pending_receipt": str(pending_receipt),
            }
    except InstallError as error:
        _cleanup_stage(temp_dir, stage_parent)
        _cleanup_receipt(pending_receipt)
        _cleanup_receipt(final_receipt)
        return {**base, "ok": False, "code": error.code, "problems": [error.message], "target": str(target)}
    except OSError as error:
        _cleanup_stage(temp_dir, stage_parent)
        _cleanup_receipt(pending_receipt)
        _cleanup_receipt(final_receipt)
        return {**base, "ok": False, "code": "install_failed", "problems": [str(error)], "target": str(target)}

    return {
        **plan,
        "code": "installed",
        "receipt": str(final_receipt),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="install_companion",
        description="Package and (gated) first-install the AI Sparring companion. No live operation without --execute.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    package = sub.add_parser("package", help="build an isolated repo/work package tree")
    package.add_argument("--source", default=str(REPO_ROOT / TARGET_NAME))
    package.add_argument("--package-root", default=str(DEFAULT_PACKAGE_ROOT))
    package.add_argument("--discovery-path", default=str(DEFAULT_DISCOVERY_PATH))
    package.add_argument("--version", default=EXPECTED_VERSION)

    verify = sub.add_parser("verify-package", help="re-verify a package manifest and configs")
    verify.add_argument("--package-root", default=str(DEFAULT_PACKAGE_ROOT))
    verify.add_argument("--version", default=EXPECTED_VERSION)

    install = sub.add_parser("install", help="gated first install (dry-run unless --execute)")
    install.add_argument("--package-root", default=str(DEFAULT_PACKAGE_ROOT))
    install.add_argument("--mods-root", default=None)
    install.add_argument("--staging-root", default=str(staging.DEFAULT_STAGING_ROOT))
    install.add_argument("--acceptance", default=None)
    install.add_argument("--backup-root", default=str(DEFAULT_BACKUP_ROOT))
    install.add_argument("--receipt-root", default=str(DEFAULT_RECEIPT_ROOT))
    install.add_argument("--stage-parent", default=str(DEFAULT_STAGE_PARENT))
    install.add_argument("--install-root", default=str(staging.DEFAULT_INSTALL))
    install.add_argument("--execute", action="store_true")
    return parser


def _emit(payload: Mapping) -> None:
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "package":
        result = build_package(args.source, args.package_root, args.discovery_path, args.version)
        _emit(result)
        return 0 if result["ok"] else 3
    if args.command == "verify-package":
        result = verify_package(args.package_root, args.version)
        _emit(result)
        return 0 if result["ok"] else 3
    if args.command == "install":
        result = install_companion(
            package_root=args.package_root,
            live_mods_root=args.mods_root,
            staging_root=args.staging_root,
            acceptance_path=args.acceptance,
            backup_root=args.backup_root,
            receipt_root=args.receipt_root,
            stage_parent=args.stage_parent,
            live_install_root=args.install_root,
            execute=args.execute,
        )
        _emit(result)
        return 0 if result["ok"] else 3
    _emit({"ok": False, "code": "unknown_command"})
    return 2


if __name__ == "__main__":
    sys.exit(main())
