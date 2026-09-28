#!/usr/bin/env python3
"""Two-layer immutable isolation certificate plus per-session live-diff accounting.

Implements the reviewed split in ``docs/CLAUDE_PROOF_ARCHITECTURE.md`` and the
binding refinement in ``work/measurement-interface.txt``:

* the **native layer (N)** binds the staged exe/Lovely install tree, the Steam
  disable/crash/startup guard patches, the absence of native Steam DLLs, the
  environment allowlist names (including the strict ``AISP_*`` session descriptor
  names) and the staging/role/live roots;
* the **mods layer (M)** binds the per-role Mods tree, the Multiplayer guard,
  the network-suppression hashes, the loopback endpoint and the *measured* local
  server binding (adaptation manifest, source/build/runtime hashes, pin).

The certificate can only be assembled from **tool-owned phase receipts**, never
from caller-supplied measured/evidence dictionaries. Each receipt is produced by
this module after a real (or fixture) launch session has exited: the recorder
takes its own before/after :func:`snapshot_live`, re-parses the actual probe
files, copies them and the Lovely dump immutably, and recomputes every digest
from the current staged trees. ``build_certificate`` receives receipt IDs only and
re-validates all of it. ``check_certificate`` re-parses the copies, recomputes the
certificate identity and refuses on any drift.

Live byte diff during a session revokes the certificate and writes a **global**
persistent lockout that only an explicit append-only acknowledgement clears. This
module makes **no runtime claim** by itself.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import time
from pathlib import Path
from typing import Mapping, Optional, Sequence

import staging

SCHEMA = "aisparring.isolation_certificate.v1"
SNAPSHOT_SCHEMA = "aisparring.live_snapshot.v1"
RECEIPT_SCHEMA = "aisparring.session_receipt.v1"
PHASE_RECEIPT_SCHEMA = "aisparring.phase_receipt.v1"
OPEN_SESSION_SCHEMA = "aisparring.open_session.v1"

EVIDENCE_DIR = "evidence"
CERT_SUBDIR = "certificates"
POINTER_NAME = "isolation_certificate.current"
COPY_SUBDIR = "certificate"
RECEIPTS_SUBDIR = "receipts"
SESSIONS_SUBDIR = "sessions"
OPEN_SUBDIR = "sessions/open"
# N7 (installer second re-review): a session record that still blocks a new spawn,
# versus one known to be closed. ``list_open_records`` skips only recognized closed
# records and fails closed on anything it cannot positively classify.
OPEN_BLOCKING_STATUSES = frozenset({"open", "failed_pending"})
OPEN_CLOSED_STATUSES = frozenset({"failed", "passed", "closed"})
REVOCATION_NAME = "certificate_revocations.jsonl"
LOCKOUT_NAME = "certificate_lockout.json"
LOCKOUT_ACK_NAME = "certificate_lockout_ack.jsonl"
RECEIPTS_REL = "sessions/receipts.jsonl"

# Section 4: P2 is measured as three separate, AI-only phases, each preceded by
# FULL_P1 and each with its own nonce, backup tie, before/after snapshots and
# immutable receipt. The certificate requires all three; a single-session P2 is no
# longer accepted.
REQUIRED_PHASES = (
    "P1A",
    "P1B",
    "FULL_P1",
    "CRASH",
    "P2_INITIAL",
    "P2_CLOSE",
    "P2_SILENT",
)
P2_PHASES = ("P2_INITIAL", "P2_CLOSE", "P2_SILENT")
# Normal practice runs under a distinct MATCH session phase that requires a current
# verified certificate. The ordered measurement phases above are measurement-only
# and can never be used as a normal run.
MATCH = "MATCH"
SESSION_PHASES = REQUIRED_PHASES + (MATCH,)
PHASE_ROLES = {
    "P1A": ("bootstrap",),
    "P1B": ("human", "ai"),
    "FULL_P1": ("human", "ai"),
    "CRASH": ("human", "ai"),
    "P2_INITIAL": ("ai",),
    "P2_CLOSE": ("ai",),
    "P2_SILENT": ("ai",),
}
PHASE_REQUIRE_MP = {
    "P1A": False,
    "P1B": True,
    "FULL_P1": True,
    "CRASH": False,
    "P2_INITIAL": True,
    "P2_CLOSE": True,
    "P2_SILENT": True,
}
# NH1 (staging worker) added a nonce-bound patch marker plus a post-Steam-block probe.
PROBE_STEAM_MARKER = getattr(staging, "PROBE_STEAM_MARKER", "aisparring_probe_steam_marker.txt")
PROBE_STEAM_POST = getattr(staging, "PROBE_STEAM_POST", "aisparring_probe_steam_post.txt")
PHASE_EVIDENCE = {
    "P1A": ("steam_marker", "steam_post", "guard", "main", "save_thread"),
    "P1B": ("steam_marker", "steam_post", "guard", "mp", "main"),
    "FULL_P1": ("steam_marker", "steam_post", "guard", "mp", "save_thread", "main"),
    "CRASH": ("save_thread", "guard", "crash"),
    "P2_INITIAL": ("steam_marker", "steam_post", "mp", "guard", "p2"),
    "P2_CLOSE": ("steam_marker", "steam_post", "mp", "guard", "p2", "listener"),
    "P2_SILENT": ("steam_marker", "steam_post", "mp", "guard", "p2", "listener"),
}
PHASE_PREREQUISITE = {
    "P1A": None,
    "P1B": "P1A",
    "FULL_P1": "P1B",
    "CRASH": "FULL_P1",
    "P2_INITIAL": "FULL_P1",
    "P2_CLOSE": "FULL_P1",
    "P2_SILENT": "FULL_P1",
}
# The single exact P2 artifact schema emitted by the env-gated source observer that
# runs inside the real staged network thread. A bare start marker is never read.
P2_ARTIFACT_SCHEMA = getattr(staging, "P2_OBSERVER_SCHEMA", "aisparring.p2_observer.v1")
PROBE_BY_LABEL = {
    "main": staging.PROBE_MAIN,
    "guard": staging.PROBE_GUARD,
    "save_thread": staging.PROBE_SAVE_THREAD,
    "mp": staging.PROBE_MP,
    "steam_marker": PROBE_STEAM_MARKER,
    "steam_post": PROBE_STEAM_POST,
    "p2": staging.PROBE_P2,
    "crash": getattr(staging, "PROBE_CRASH", "aisparring_probe_crash.txt"),
    "listener": getattr(staging, "PROBE_LISTENER", "aisparring_listener.json"),
}
ALL_PROBE_NAMES = (
    staging.PROBE_MAIN,
    staging.PROBE_GUARD,
    staging.PROBE_SAVE_THREAD,
    staging.PROBE_MP,
    PROBE_STEAM_MARKER,
    PROBE_STEAM_POST,
    staging.PROBE_P2,
    getattr(staging, "PROBE_CRASH", "aisparring_probe_crash.txt"),
    getattr(staging, "PROBE_LISTENER", "aisparring_listener.json"),
)

TOOLS_DIR = Path(__file__).resolve().parent
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
# One shared, colon-free session grammar used by both the certificate and the
# launcher. A colon would create an NTFS alternate data stream in
# ``sessions/{id}.json``; 64 chars keeps the name bounded.
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
PORT_MIN = 1
PORT_MAX = 65535


class CertificateError(staging.StagingError):
    """Typed certificate failure; the code is stable and safe to log."""


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _evidence_root(staging_root) -> Path:
    return Path(staging_root).resolve() / EVIDENCE_DIR


def _canonical(payload) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)


def _digest(payload) -> str:
    return hashlib.sha256(_canonical(payload).encode("utf-8")).hexdigest()


def _norm_root(value) -> str:
    return staging._norm_path(value)


def _normalize_live(live=None) -> dict:
    return {key: str(value) for key, value in staging._normalize_live(live).items()}


def _safe_write(staging_root, path) -> Path:
    return staging.assert_safe_write(staging_root, path, "certificate write")


def _is_sha256(value) -> bool:
    return isinstance(value, str) and bool(SHA256_RE.match(value))


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_port(value) -> bool:
    return _is_int(value) and PORT_MIN <= value <= PORT_MAX


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _session_id_problems(value) -> list:
    if not isinstance(value, str) or not SESSION_ID_RE.match(value):
        return ["bad_session_id"]
    return []


def _atomic_write_text(path: Path, text: str) -> None:
    """Write to a temp sibling then ``os.replace`` so readers never see a partial file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    with open(temp, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temp, path)


def _write_immutable(staging_root, path: Path, payload: Mapping, *, text: Optional[str] = None) -> dict:
    """Write once; if the target already exists it must be byte-identical."""
    staging_root = Path(staging_root).resolve()
    _safe_write(staging_root, path)
    body = text if text is not None else json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n"
    if path.is_file():
        if path.read_text(encoding="utf-8") != body:
            raise CertificateError("immutable_conflict", f"immutable record differs: {path}")
    else:
        _atomic_write_text(path, body)
    return {"path": str(path), "sha256": staging.sha256_file(path)}


def _read_json(path: Path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _append_jsonl(staging_root, relative: str, payload: Mapping) -> Path:
    staging_root = Path(staging_root).resolve()
    path = staging_root / EVIDENCE_DIR / relative
    _safe_write(staging_root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(_canonical(payload) + "\n")
    return path


def _read_jsonl(path: Path) -> list:
    if not Path(path).is_file():
        return []
    records: list = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


# ---------------------------------------------------------------------------
# Bound tools (isolation-critical surface)
# ---------------------------------------------------------------------------

def bound_tool_specs() -> dict:
    """Every module that builds env, stages files, patches, binds endpoints or checks.

    Also binds the external repository policy/runtime code the service actually
    loads (``tools/policy_worker.py``, ``tools/lua/policy_env.lua``,
    ``AISparring/ai/*.lua``) and the trusted ruleset derivation
    (``tools/ruleset_contract.py``), so an ordinary repository edit after
    certification cannot silently change policy code under an old certificate. A
    missing entry fails closed (``bound_tool_missing``).
    """
    ai_dir = staging.REPO_ROOT / "AISparring" / "ai"
    return {
        "staging": Path(staging.__file__).resolve(),
        "launcher": TOOLS_DIR / "launch_practice.py",
        "prepare_server": TOOLS_DIR / "prepare_server.py",
        "practice_service": TOOLS_DIR / "practice_service.py",
        "practice_host": TOOLS_DIR / "practice_host.py",
        "certificate_checker": Path(__file__).resolve(),
        "policy_worker": TOOLS_DIR / "policy_worker.py",
        "policy_env": TOOLS_DIR / "lua" / "policy_env.lua",
        "ruleset_contract": TOOLS_DIR / "ruleset_contract.py",
        "ai_baseline_policy": ai_dir / "baseline_policy.lua",
        "ai_codec": ai_dir / "codec.lua",
        "ai_observation": ai_dir / "observation.lua",
        "ai_actions": ai_dir / "actions.lua",
    }


BOUND_RUNTIME_SOURCES = (
    "policy_worker",
    "policy_env",
    "ruleset_contract",
    "ai_baseline_policy",
    "ai_codec",
    "ai_observation",
    "ai_actions",
)


def collect_bound_tools(specs: Optional[Mapping] = None) -> dict:
    result: dict = {}
    for name, path in (specs or bound_tool_specs()).items():
        target = Path(path)
        if target.is_file():
            result[name] = {
                "path": str(target),
                "sha256": staging.sha256_file(target),
                "present": True,
            }
        else:
            result[name] = {"path": str(target), "sha256": None, "present": False}
    return result


def _validate_tools(tools: Mapping) -> tuple:
    problems: list = []
    normalized: dict = {}
    if not isinstance(tools, Mapping):
        return normalized, ["tools_not_mapping"]
    for name, entry in tools.items():
        if not isinstance(entry, Mapping):
            problems.append(f"tool_{name}_bad_entry")
            continue
        present = entry.get("present")
        digest = entry.get("sha256")
        if present is not True:
            problems.append(f"bound_tool_missing:{name}")
        elif not _is_sha256(digest):
            problems.append(f"tool_{name}_bad_hash")
        normalized[str(name)] = {
            "path": str(entry.get("path", "")),
            "sha256": digest if _is_sha256(digest) else None,
            "present": bool(present),
        }
    return normalized, problems


# ---------------------------------------------------------------------------
# Layer N / layer M collection
# ---------------------------------------------------------------------------

def launcher_session_env_names() -> Optional[list]:
    """The exact session-descriptor env names from the real typed launcher descriptor.

    Derived from ``launch_practice.SESSION_ENV_KEYS`` so the bound names cannot drift
    into speculative aliases. ``None`` means the launcher is unavailable and the
    certificate must stay partial.
    """
    try:
        import launch_practice
    except Exception:  # noqa: BLE001
        return None
    keys = getattr(launch_practice, "SESSION_ENV_KEYS", None)
    if not isinstance(keys, Mapping) or not keys:
        return None
    return sorted(str(name) for name in keys.values())


def _env_name_sets(staging_root) -> dict:
    """Names only (never values) of every environment variable a staged role receives."""
    paths = staging.role_paths(staging_root, staging.ROLES[0])
    return {
        "allowed_env": sorted(staging.ALLOWED_ENV_KEYS),
        "role_overrides": sorted(str(name) for name in staging.role_environment_overrides(paths)),
        "session_descriptor": launcher_session_env_names(),
    }


def _guard_meta_digest(paths) -> Optional[str]:
    meta = paths.root / "steam_guard" / staging.STEAM_GUARD_META_NAME
    return staging.sha256_file(meta) if meta.is_file() else None


def _native_role_entry(paths) -> dict:
    guard = staging._read_guard_meta(paths) or {}
    patch_path = (guard.get("patch") or {}).get("path")
    exe = paths.exe()
    version_dll = paths.install / "version.dll"
    return {
        "install_digest": staging._tree_digest(paths.install, staging.INSTALL_HASH_POLICY),
        "exe_sha256": staging.sha256_file(exe) if exe.is_file() else None,
        "version_dll_sha256": staging.sha256_file(version_dll) if version_dll.is_file() else None,
        "steam_guard_patch_sha256": (
            staging.sha256_file(patch_path) if patch_path and Path(patch_path).is_file() else None
        ),
        "steam_guard_meta_sha256": _guard_meta_digest(paths),
        "steam_native_absent": not bool(staging._steam_natives_in(paths.install)),
    }


def collect_layer_n(staging_root, live=None) -> dict:
    staging_root = Path(staging_root).resolve()
    bootstrap = staging.bootstrap_paths(staging_root)
    roles = {role: staging.role_paths(staging_root, role) for role in staging.ROLES}
    bootstrap_entry = _native_role_entry(bootstrap)
    role_entries = {role: _native_role_entry(paths) for role, paths in roles.items()}
    digests = [entry["install_digest"] for entry in role_entries.values()]
    equals = (
        bootstrap_entry["install_digest"] is not None
        and all(digest is not None for digest in digests)
        and len(set(digests)) == 1
        and bootstrap_entry["install_digest"] == digests[0]
    )
    return {
        "bootstrap": bootstrap_entry,
        "roles": role_entries,
        "bootstrap_equals_roles": equals,
        "env_names": _env_name_sets(staging_root),
        "roots": {
            "staging_root": str(staging_root),
            "bootstrap_root": str(bootstrap.root),
            "role_roots": {role: str(paths.root) for role, paths in roles.items()},
        },
    }


def _guard_patch_path(paths) -> Path:
    return paths.mods / staging.PATCH_MOD_ROLE / "lovely" / "bootstrap.toml"


def _role_parity_digest(paths) -> Optional[str]:
    """Mods digest with the role-specific absolute paths in the guard patch masked.

    The generated guard patch legitimately embeds each role's own save/Mods paths,
    so a raw byte digest differs per role. Masking just those strings lets the two
    staged roles prove identical mod content/config while the per-role path binding
    stays bound by the (unmasked) ``mods_digest``.
    """
    if not paths.mods.is_dir():
        return None
    files = staging.hash_tree(paths.mods, staging.MODS_HASH_POLICY)
    patch_rel = f"{staging.PATCH_MOD_ROLE}/lovely/bootstrap.toml"
    patch = _guard_patch_path(paths)
    if patch_rel in files and patch.is_file():
        text = patch.read_text(encoding="utf-8", errors="replace")
        save = staging._lua_path(paths.data / "Balatro")
        mods = staging._lua_path(paths.mods)
        masked = text.replace(save, "<ROLE_SAVE>").replace(mods, "<ROLE_MODS>")
        files[patch_rel] = {"sha256": hashlib.sha256(masked.encode("utf-8")).hexdigest()}
    return staging._digest_of(files)


def _mods_role_entry(staging_root, role: str) -> dict:
    paths = staging.role_paths(staging_root, role)
    endpoint = staging.verify_staged_endpoints(staging_root, roles=(role,))["roles"].get(role, {"ok": False})
    matches = staging.find_multiplayer_mod(paths.mods)
    if paths.mods.is_dir():
        scan = staging.scan_network_suppressions(paths.mods)
        suppression = {"applied": scan.get("applied") or {}, "ok": bool(scan.get("ok"))}
    else:
        suppression = {"applied": {}, "ok": False}
    return {
        "mods_digest": staging._tree_digest(paths.mods, staging.MODS_HASH_POLICY),
        "role_parity_digest": _role_parity_digest(paths),
        "multiplayer_mod_present": len(matches) == 1,
        "network_suppression": suppression,
        "endpoint": {
            "ok": bool(endpoint.get("ok")),
            "host": endpoint.get("url"),
            "port": endpoint.get("port"),
            "problems": list(endpoint.get("problems") or []),
        },
    }


def measure_server_binding(staging_root, *, config=None) -> dict:
    """Measure the adapted local server from its real manifest, hashes and pin.

    The binding is recomputed from the prepared server tree via
    ``practice_host.verify_server_adaptation`` (lazy import avoids any import
    cycle). Callers may inject ``config`` in tests; the default is the concrete
    repository configuration.
    """
    try:
        import practice_host
    except Exception:  # noqa: BLE001
        return {"ok": False, "problems": ["practice_server_module_unavailable"], "source": "unavailable"}
    try:
        if config is None:
            config = practice_host.default_config(repo_root=staging.REPO_ROOT)
        verdict = practice_host.verify_server_adaptation(config)
    except Exception:  # noqa: BLE001
        return {"ok": False, "problems": ["practice_server_adaptation_error"], "source": "error"}
    if not isinstance(verdict, Mapping):
        return {"ok": False, "problems": ["practice_server_adaptation_invalid"], "source": "invalid"}
    return {
        "ok": bool(verdict.get("ok")),
        "problems": sorted(str(item) for item in (verdict.get("problems") or [])),
        "upstream_commit": verdict.get("upstream_commit"),
        "package_lock_sha256": verdict.get("package_lock_sha256"),
        "dependency_hashes": dict(verdict.get("dependency_hashes") or {}),
        "entry": verdict.get("entry"),
        "source": "practice_host.verify_server_adaptation",
    }


def collect_layer_m(staging_root, live=None, server_bind=None) -> dict:
    """Layer M is always *measured*; a caller-supplied ``server_bind`` is ignored.

    ``server_bind`` remains in the signature only for backward compatibility with
    the old caller-dict contract (NH3). The measured binding comes from the real
    adapted server tree via :func:`measure_server_binding`.
    """
    staging_root = Path(staging_root).resolve()
    roles = {role: _mods_role_entry(staging_root, role) for role in staging.ROLES}
    return {"roles": roles, "server_bind": dict(measure_server_binding(staging_root))}


def _layer_problems(layer_n: Mapping, layer_m: Mapping, port) -> list:
    problems: list = []
    if not layer_n.get("bootstrap_equals_roles"):
        problems.append("p1a_bootstrap_role_mismatch")
    entries = [("bootstrap", layer_n.get("bootstrap") or {})]
    entries.extend((layer_n.get("roles") or {}).items())
    for _label, entry in entries:
        if not _is_sha256(entry.get("install_digest")):
            problems.append("native_install_digest_missing")
        if not _is_sha256(entry.get("exe_sha256")):
            problems.append("native_exe_missing")
        if not _is_sha256(entry.get("steam_guard_patch_sha256")):
            problems.append("native_guard_patch_missing")
        if entry.get("steam_native_absent") is not True:
            problems.append("steam_native_present")
    names = layer_n.get("env_names") or {}
    role_overrides = names.get("role_overrides") or []
    session_names = names.get("session_descriptor")
    if not names.get("allowed_env") or not role_overrides:
        problems.append("env_names_missing")
    if "BALATRO_AI_ROLE" not in role_overrides:
        problems.append("role_env_name_missing")
    if not session_names:
        problems.append("session_descriptor_names_missing")
    elif set(session_names) & set(staging.FORBIDDEN_ENV_ALIASES):
        problems.append("session_descriptor_alias_present")
    for role, entry in (layer_m.get("roles") or {}).items():
        if not _is_sha256(entry.get("mods_digest")):
            problems.append(f"mods_digest_missing:{role}")
        if entry.get("multiplayer_mod_present") is not True:
            problems.append(f"multiplayer_mod_missing:{role}")
        endpoint = entry.get("endpoint") or {}
        if endpoint.get("ok") is not True or endpoint.get("host") != "127.0.0.1":
            problems.append(f"endpoint_not_loopback:{role}")
        elif not _is_port(endpoint.get("port")):
            problems.append(f"endpoint_port_missing:{role}")
        elif port is not None and int(endpoint["port"]) != int(port):
            problems.append(f"endpoint_port_mismatch:{role}")
    role_entries = list((layer_m.get("roles") or {}).values())
    if len(role_entries) == len(staging.ROLES):
        parities = {entry.get("role_parity_digest") for entry in role_entries}
        if len(parities) != 1 or not all(_is_sha256(value) for value in parities):
            problems.append("staged_roles_content_mismatch")
        if len({(entry.get("endpoint") or {}).get("port") for entry in role_entries}) != 1:
            problems.append("staged_roles_endpoint_mismatch")
    binding = layer_m.get("server_bind") or {}
    if binding.get("ok") is not True:
        problems.append("server_bind_unproven")
        problems.extend(f"server_bind:{item}" for item in (binding.get("problems") or []))
    return problems


# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

def snapshot_root_keys(live: Mapping) -> list:
    """Game-relevant live roots only (never the whole Steam installation).

    The bare ``steam_userdata`` key duplicates the first profile app dir, so only
    the explicit ``steam_userdata/<profile>`` keys are snapshotted; that keeps the
    snapshot root keys identical to the verified backup root keys.
    """
    keys: list = []
    for key in live:
        if key in ("install", "appdata") or key.startswith("steam_userdata/"):
            keys.append(key)
    return sorted(keys)


def _snapshot_digest(roots: Mapping) -> str:
    return staging._digest_of({key: (entry or {}).get("digest") for key, entry in roots.items()})


def snapshot_live(live, *, label=None) -> dict:
    """Full byte manifest of the live install, AppData and every Steam profile app dir."""
    resolved = staging._normalize_live(live)
    roots: dict = {}
    file_count = 0
    for key in snapshot_root_keys(resolved):
        root = Path(resolved[key])
        if root.is_dir():
            files = staging.hash_tree(root, staging.HashPolicy())
            roots[key] = {"root": str(root), "digest": staging._digest_of(files), "files": files}
            file_count += len(files)
        else:
            roots[key] = {"root": str(root), "digest": None, "files": {}}
    return {
        "schema": SNAPSHOT_SCHEMA,
        "label": label,
        "roots": roots,
        "digest": _snapshot_digest(roots),
        "file_count": file_count,
        "measured_unix": int(time.time()),
    }


def _recompute_snapshot_digest(snapshot: Mapping) -> Optional[str]:
    """Recompute the snapshot digest from its own ``files`` maps, never trusting ``digest``."""
    roots = snapshot.get("roots")
    if not isinstance(roots, Mapping):
        return None
    recomputed: dict = {}
    for key, entry in roots.items():
        if not isinstance(entry, Mapping):
            return None
        files = entry.get("files")
        if not isinstance(files, Mapping):
            return None
        recomputed[key] = staging._digest_of(files)
    return staging._digest_of(recomputed)


def _validate_snapshot(snapshot, label: str) -> list:
    problems: list = []
    if not isinstance(snapshot, Mapping):
        return [f"{label}_snapshot_missing"]
    if snapshot.get("schema") != SNAPSHOT_SCHEMA:
        problems.append(f"{label}_snapshot_schema")
    roots = snapshot.get("roots")
    if not isinstance(roots, Mapping) or not roots:
        problems.append(f"{label}_snapshot_roots_missing")
        return problems
    recomputed = _recompute_snapshot_digest(snapshot)
    if not _is_sha256(recomputed):
        problems.append(f"{label}_snapshot_digest_missing")
    elif snapshot.get("digest") != recomputed:
        problems.append(f"{label}_snapshot_digest_mismatch")
    return problems


def rotate_probe_files(staging_root) -> list:
    """Remove stale nonce probes inside staging only, at closed-game preparation."""
    staging_root = Path(staging_root).resolve()
    removed: list = []
    for role in [staging.BOOTSTRAP_ROLE] + list(staging.ROLES):
        paths = staging._paths_for_role(staging_root, role)
        save_dir = paths.data / "Balatro"
        for name in ALL_PROBE_NAMES:
            target = save_dir / name
            staging.assert_safe_write(staging_root, target, "probe rotation")
            if target.exists():
                target.unlink()
                removed.append(str(target))
    return removed


def restore_mutable_paths(staging_root) -> dict:
    """No path is declared mutable. config.lua stays canonically hashed and pinned."""
    return {
        "restored": [],
        "declared_mutable": [],
        "note": "no mutable paths declared; config.lua is canonical and included in the M digest",
    }


def rotate_attestation_files(staging_root) -> list:
    """Remove any previous session's host attestation inside staging only."""
    staging_root = Path(staging_root).resolve()
    removed: list = []
    for role in [staging.BOOTSTRAP_ROLE] + list(staging.ROLES):
        paths = staging._paths_for_role(staging_root, role)
        target = staging.launcher_attestation_path(paths)
        staging.assert_safe_write(staging_root, target, "attestation rotation")
        if target.exists():
            target.unlink()
            removed.append(str(target))
    return removed


# ---------------------------------------------------------------------------
# Global persistent lockout (NM1)
# ---------------------------------------------------------------------------

def _lockout_path(staging_root) -> Path:
    return _evidence_root(staging_root) / LOCKOUT_NAME


def _lockout_ack_path(staging_root) -> Path:
    return _evidence_root(staging_root) / LOCKOUT_ACK_NAME


def _lockout_id(record: Mapping) -> str:
    body = {key: value for key, value in record.items() if key != "lockout_id"}
    return _digest(body)


def read_lockout_acks(staging_root) -> list:
    return _read_jsonl(_lockout_ack_path(staging_root))


def lockout(staging_root) -> dict:
    """Global lockout independent of any certificate ID; cleared only by an explicit ack."""
    staging_root = Path(staging_root).resolve()
    path = _lockout_path(staging_root)
    if not path.is_file():
        return {"locked": False, "path": str(path)}
    record = _read_json(path)
    if not isinstance(record, Mapping):
        return {
            "locked": True,
            "path": str(path),
            "lockout_id": None,
            "reason": "unreadable",
        }
    lock_id = record.get("lockout_id") or _lockout_id(record)
    acked = any(item.get("lockout_id") == lock_id for item in read_lockout_acks(staging_root))
    result = dict(record)
    result["locked"] = not acked
    result["lockout_id"] = lock_id
    result["path"] = str(path)
    return result


def _write_lockout(staging_root, record: Mapping) -> Path:
    staging_root = Path(staging_root).resolve()
    path = _lockout_path(staging_root)
    payload = dict(record)
    if not payload.get("lockout_id"):
        payload["lockout_id"] = _lockout_id(payload)
    _safe_write(staging_root, path)
    _atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")
    return path


def acknowledge_lockout(staging_root, *, operator: str, reason: str) -> dict:
    """Append-only acknowledgement of the *current* lockout. Never auto-clears."""
    staging_root = Path(staging_root).resolve()
    current = lockout(staging_root)
    if not current.get("locked"):
        return {"ok": False, "code": "no_active_lockout", "problems": ["no_active_lockout"]}
    record = {
        "lockout_id": current.get("lockout_id"),
        "operator": str(operator),
        "reason": str(reason),
        "acknowledged_unix": int(time.time()),
    }
    path = _append_jsonl(staging_root, LOCKOUT_ACK_NAME, record)
    return {"ok": True, "code": "lockout_acknowledged", "path": str(path), "record": record}


# ---------------------------------------------------------------------------
# Phase receipts (tool-owned measured evidence)
# ---------------------------------------------------------------------------

def _receipts_dir(staging_root) -> Path:
    return _evidence_root(staging_root) / RECEIPTS_SUBDIR


def _receipt_path(staging_root, receipt_id: str) -> Path:
    return _receipts_dir(staging_root) / f"{receipt_id}.json"


def load_phase_receipt(staging_root, receipt_id: str) -> Optional[dict]:
    if not _is_sha256(receipt_id):
        return None
    return _read_json(_receipt_path(staging_root, receipt_id))


def _phase_receipt_problems(phase: str) -> list:
    problems: list = []
    if phase not in REQUIRED_PHASES:
        problems.append("unknown_phase")
    return problems


def _copy_receipt_evidence(staging_root, evidence_key: str, items: Mapping) -> dict:
    """Copy probe/dump files into ``evidence/receipts/<evidence_key>/`` immutably."""
    root = _receipts_dir(staging_root) / evidence_key
    stored: dict = {}
    for role, labels in items.items():
        stored[role] = {}
        for label, source in labels.items():
            source = Path(source)
            digest = staging.sha256_file(source)
            target = root / f"{role}_{label}_{digest}{source.suffix}"
            _safe_write(staging_root, target)
            if target.is_file():
                if staging.sha256_file(target) != digest:
                    raise CertificateError("receipt_evidence_conflict", str(target))
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            stored[role][label] = {
                "copy": target.relative_to(Path(staging_root).resolve()).as_posix(),
                "copy_sha256": staging.sha256_file(target),
                "source_sha256": digest,
            }
    return stored


def _select_dump_files(paths, fresh_dumps: Sequence, *, require_socket: bool = False) -> dict:
    """N8: bind the actual Lovely *patched* dumps by exact pretty path.

    Official Lovely writes patched output under ``lovely/dump/<pretty_name>`` (the
    unpatched ``game-dump`` tree is never evidence). The main dump is
    ``lovely/dump/main.lua``; the Multiplayer source is
    ``lovely/dump/SMODS/Multiplayer/networking/socket.lua`` (lib.rs:308-331). A
    same-basename file anywhere else is refused, and ``require_socket`` additionally
    requires the patched socket dump for the CLOSE/SILENT phases. Missing dumps
    return an empty selection so the receipt is refused rather than downgraded.
    """
    mods = Path(paths.mods)

    def normalize(value) -> str:
        text = str(value).replace("\\", "/")
        while text.startswith("./"):
            text = text[2:]
        return text

    available = {normalize(rel) for rel in fresh_dumps}
    main_rel = staging.lovely_patched_dump_rel(staging.LOVELY_PATCHED_MAIN_REL)
    socket_rel = staging.lovely_patched_dump_rel(staging.MP_SOCKET_DUMP_REL)
    selected: dict = {}
    if main_rel in available:
        selected["lovely_dump"] = main_rel
    if socket_rel in available:
        selected["socket_dump"] = socket_rel
    if "lovely_dump" not in selected:
        return {}
    if require_socket and "socket_dump" not in selected:
        return {}
    sources: dict = {}
    for label, rel in selected.items():
        source = mods / rel
        if not source.is_file():
            return {}
        sources[label] = source
    return sources


def _write_measurement_artifact(staging_root, evidence_key: str, phase: str, measured: Mapping) -> dict:
    """Persist the tool-derived measurement as an immutable, hashed raw artifact."""
    staging_root = Path(staging_root).resolve()
    payload = {
        "schema": "aisparring.phase_measurement.v1",
        "phase": phase,
        "measured": dict(measured),
        "measured_unix": int(time.time()),
    }
    text = json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n"
    path = _receipts_dir(staging_root) / evidence_key / "measurement.json"
    written = _write_immutable(staging_root, path, None, text=text)
    return {
        "copy": path.relative_to(staging_root).as_posix(),
        "copy_sha256": written["sha256"],
    }


def _receipt_open_record(staging_root, session_id: str):
    return _read_json(_open_record_path(staging_root, session_id))


def _owned_pids(session) -> dict:
    pids: dict = {}
    for record in getattr(session, "records", ()) or ():
        role = getattr(record, "role", None)
        pid = getattr(record, "pid", None)
        if role is not None and pid is not None:
            pids.setdefault(str(role), []).append(int(pid))
    if not pids:
        for owned in getattr(session, "owned", ()) or ():
            role = getattr(owned, "role", None)
            pid = getattr(owned, "pid", None)
            if role is not None and pid is not None:
                pids.setdefault(str(role), []).append(int(pid))
    return pids


def _owned_all_exited(session) -> bool:
    try:
        statuses = session.is_running()
    except Exception:  # noqa: BLE001
        return False
    if not isinstance(statuses, (list, tuple)):
        return False
    return not any(bool((item or {}).get("running")) for item in statuses)


def _owned_exit_code(owned):
    """Read the exit code from a *retained* owned handle, never by reopening a PID."""
    handle = getattr(owned, "handle", None)
    if handle is None:
        return None
    code = getattr(handle, "returncode", None)
    if code is None and hasattr(handle, "poll"):
        try:
            code = handle.poll()
        except Exception:  # noqa: BLE001
            code = None
    if isinstance(code, int) and not isinstance(code, bool):
        return code
    return None


def _owned_exit_codes(session) -> dict:
    """Per-role exit codes read from the retained handles (tool-owned, not caller)."""
    codes: dict = {}
    for record in getattr(session, "records", ()) or ():
        role = getattr(record, "role", None)
        if role is not None:
            codes.setdefault(str(role), None)
    for owned in getattr(session, "owned", ()) or ():
        role = getattr(owned, "role", None)
        if role is None:
            continue
        codes[str(role)] = _owned_exit_code(owned)
    return codes


def _read_crash_probes(staging_root, record: Mapping, roles: Sequence[str]) -> dict:
    """Read the fresh, nonce-bound crash probes the wrapped error handler wrote."""
    nonce = record.get("nonce") if isinstance(record, Mapping) else None
    spawn_time = record.get("spawn_time") if isinstance(record, Mapping) else None
    probes: dict = {}
    for role in roles:
        try:
            paths = staging._paths_for_role(staging_root, role)
        except Exception:  # noqa: BLE001
            continue
        target = paths.data / "Balatro" / getattr(staging, "PROBE_CRASH", "aisparring_probe_crash.txt")
        if not target.is_file():
            continue
        try:
            mtime = target.stat().st_mtime
            fields = staging.parse_probe(target.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        fresh = spawn_time is None or mtime >= (float(spawn_time) - staging.START_TIME_TOLERANCE)
        probes[str(role)] = {
            "mtime": mtime,
            "fields": fields,
            "fresh": bool(fresh),
            "nonce_bound": bool(nonce) and fields.get("nonce") == nonce,
            "patch_bound": fields.get("patch") == staging.PATCH_ID,
        }
    return probes


def _measure_crash(staging_root, session, record: Mapping) -> dict:
    """CRASH evidence from fresh nonce-bound crash probes plus the tool end code.

    N2: a nonzero exit is never a crash on its own. The stimulus must have been the
    prepared CRASH setup, the *active original* error handler must have written a
    fresh nonce-bound crash probe for every role, and the tool-owned end code must
    match every role's measured exit code. No caller observation is read.
    """
    setup = record.get("measurement_setup") if isinstance(record, Mapping) else None
    stimulus = setup.get("stimulus") if isinstance(setup, Mapping) else None
    prepared_crash = bool(
        isinstance(record, Mapping)
        and record.get("phase") == "CRASH"
        and isinstance(setup, Mapping)
        and setup.get("kind") == "crash"
        and stimulus == staging.MEASUREMENT_CRASH_STIMULUS
    )
    roles = list(PHASE_ROLES.get("CRASH", ()))
    probes = _read_crash_probes(staging_root, record, roles)
    codes = _owned_exit_codes(session)
    end_code = staging.MEASUREMENT_END_CODES["CRASH"]
    end_mode = getattr(session, "end_mode", None)
    exited = _owned_all_exited(session)
    probes_ok = bool(probes) and all(
        probes.get(role, {}).get("fresh")
        and probes.get(role, {}).get("nonce_bound")
        and probes.get(role, {}).get("patch_bound")
        for role in roles
    )
    codes_ok = bool(codes) and all(code == end_code for code in codes.values())
    return {
        "crash_stimulus": stimulus if prepared_crash else None,
        "crash_stimulus_bound": prepared_crash,
        "crash_stimulus_prepared_phase": record.get("phase") if isinstance(record, Mapping) else None,
        "crash_exit_codes": codes,
        "crash_end_mode": end_mode,
        "crash_end_code_expected": end_code,
        "crash_probes": {
            role: {
                "fresh": bool(item.get("fresh")),
                "nonce_bound": bool(item.get("nonce_bound")),
                "patch_bound": bool(item.get("patch_bound")),
            }
            for role, item in probes.items()
        },
        "crash_observed": bool(prepared_crash and probes_ok and codes_ok),
        "cleanup_ok": bool(exited),
        "owned_exited": bool(exited),
        "exit_code_measured": all(value is not None for value in codes.values()) if codes else False,
    }


P2_REQUIRED_SUBGATES = ("initial_failure", "reconnect", "keepalive")
# Section 4: each P2 phase proves exactly one coverage definition.
P2_PHASE_SUBGATE = {
    "P2_INITIAL": "initial_failure",
    "P2_CLOSE": "closure",
    "P2_SILENT": "keepalive",
}
# Source-derived original timers (pinned ``networking/socket.lua``): reconnectDelays
# = {2,4,8}; keepAliveInitialTimeout = 20; keepAliveRetryTimeout = 5;
# keepAliveRetryCount = 4 (five keepAlive pushes). Tolerances are stated, not exact.
P2_RECONNECT_DELAYS = (2.0, 4.0, 8.0)
P2_KEEPALIVE_INITIAL = 20.0
P2_KEEPALIVE_INTERVAL = 5.0
P2_KEEPALIVE_PUSHES = 5
P2_DELAY_TOLERANCE = 1.0
P2_KEEPALIVE_TOLERANCE = 2.0


def _as_float(value):
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _p2_counter(value):
    """A non-negative integer counter from the observer artifact, else ``None``."""
    if _is_int(value) and value >= 0:
        return int(value)
    return None


def _p2_cycles(fields: Mapping) -> list:
    cycles: list = []
    index = 1
    while f"cycle{index}_cause" in fields:
        attempts: list = []
        attempt = 1
        while f"cycle{index}_attempt{attempt}_time" in fields:
            attempts.append(
                {
                    "time": _as_float(fields.get(f"cycle{index}_attempt{attempt}_time")),
                    "result": fields.get(f"cycle{index}_attempt{attempt}_result"),
                }
            )
            attempt += 1
        cycles.append(
            {
                "cause": fields.get(f"cycle{index}_cause"),
                "start_time": _as_float(fields.get(f"cycle{index}_start_time")),
                "outcome": fields.get(f"cycle{index}_outcome"),
                "end_time": _as_float(fields.get(f"cycle{index}_end_time")),
                "attempts": attempts,
            }
        )
        index += 1
    return cycles


def _p2_receive_errors(fields: Mapping) -> list:
    errors: list = []
    index = 1
    while f"receive_error{index}_value" in fields:
        errors.append(
            {
                "value": fields.get(f"receive_error{index}_value"),
                "time": _as_float(fields.get(f"receive_error{index}_time")),
            }
        )
        index += 1
    return errors


def _p2_keepalive_push_times(fields: Mapping) -> list:
    times: list = []
    index = 1
    while f"keepalive_push{index}_time" in fields:
        times.append(_as_float(fields.get(f"keepalive_push{index}_time")))
        index += 1
    return times


def _p2_cycle_delays(cycle: Mapping) -> Optional[list]:
    times = [item.get("time") for item in (cycle.get("attempts") or [])]
    start = cycle.get("start_time")
    if start is None or any(value is None for value in times) or len(times) != len(P2_RECONNECT_DELAYS):
        return None
    return [times[0] - start] + [times[i] - times[i - 1] for i in range(1, len(times))]


def _cycle_is_bounded_exhausted(cycle: Mapping) -> bool:
    """A cycle proves bounded retry exhaustion only if it *completed* and failed."""
    attempts = cycle.get("attempts") or []
    if cycle.get("outcome") != "exhausted" or len(attempts) != len(P2_RECONNECT_DELAYS):
        return False
    if any(str(item.get("result")).strip() == "1" for item in attempts):
        return False
    delays = _p2_cycle_delays(cycle)
    if delays is None:
        return False
    return all(abs(delay - expected) <= P2_DELAY_TOLERANCE for delay, expected in zip(delays, P2_RECONNECT_DELAYS))


def _single_exhausted_cycle(derived: Mapping) -> Optional[dict]:
    cycles = derived.get("cycles") or []
    if len(cycles) != 1 or not _cycle_is_bounded_exhausted(cycles[0]):
        return None
    return cycles[0]


def _listener_view(fields: Optional[Mapping]) -> dict:
    fields = fields if isinstance(fields, Mapping) else {}

    def flag(key):
        value = fields.get(key)
        if value is None:
            return None
        return str(value).strip().lower() == "true"

    return {
        "present": bool(fields),
        "accepted": _p2_counter(_coerce_int(fields.get("accepted"))),
        "peer_is_owned_ai": flag("peer_is_owned_ai"),
        "sent_bytes": _p2_counter(_coerce_int(fields.get("sent_bytes"))),
        "closed": flag("closed"),
        "fin": flag("fin"),
        "close_time": _as_float(fields.get("close_time")),
        "open_until": _as_float(fields.get("open_until")),
        "peer_eof": flag("peer_eof"),
        "eof_time": _as_float(fields.get("eof_time")),
    }


def _p2_derive(fields: Mapping, dead) -> dict:
    """Derive the observed P2 signals from one parsed observer artifact.

    This is the single exact-schema classifier: the same function classifies the
    freshly read staged artifact at record time and re-derives coverage from the
    immutable *copied* artifact at validation time, so a receipt can never claim a
    subgate its own copied evidence does not support. A reconnect/closure subgate is
    never inferred from an aggregate count: it requires one *completed, bounded,
    exhausted* retry cycle (attempts == 3, all failed, 2/4/8-second delays).
    """
    fields = fields if isinstance(fields, Mapping) else {}
    schema_ok = str(fields.get("schema") or "") == P2_ARTIFACT_SCHEMA

    def counter(key):
        # Raw parsed probe fields are strings; coerce before classifying so the
        # record-time path and the copied-artifact re-derivation agree exactly.
        return _p2_counter(_coerce_int(fields.get(key))) if schema_ok else None

    connect_attempts = counter("connect_attempts")
    connect_successes = counter("connect_successes")
    connect_failures = counter("connect_failures")
    reconnect_attempts = counter("reconnect_attempts")
    reconnect_failures = counter("reconnect_failures")
    reconnects = counter("reconnects")
    keepalive_failures = counter("keepalive_failures")
    keepalive_pushes = counter("keepalive_pushes")
    closes = counter("closes")
    first_result = fields.get("first_result")
    cycles = _p2_cycles(fields) if schema_ok else []
    receive_errors = _p2_receive_errors(fields) if schema_ok else []
    keepalive_push_times = _p2_keepalive_push_times(fields) if schema_ok else []
    # The pinned thread tests a connect failure as ``connectionResult ~= 1``. The
    # *initial* failure is the first returned attempt's own result (``none`` when the
    # socket returned nil, matching the pinned comparison), never a later reconnect
    # retry and never an attempt count alone.
    first_failed = bool(
        schema_ok
        and connect_attempts is not None
        and connect_attempts >= 1
        and first_result is not None
        and str(first_result).strip() != "1"
    )
    failed_attempt = bool(
        first_failed
        and connect_failures is not None
        and connect_failures >= 1
        and connect_failures <= connect_attempts
    )
    endpoint_url = fields.get("url")
    endpoint_port = _p2_counter(_coerce_int(fields.get("port")))
    endpoint_bound = bool(
        endpoint_url == "127.0.0.1"
        and _is_port(endpoint_port)
        and _is_port(dead)
        and int(endpoint_port) == int(dead)
    )
    exhausted = [cycle for cycle in cycles if _cycle_is_bounded_exhausted(cycle)]
    covered: list = []
    if failed_attempt and endpoint_bound:
        covered.append("initial_failure")
    # Only a completed bounded retry cycle whose attempts all failed proves the
    # reconnect subgate; a recovered cycle or an unfinished one never does.
    if schema_ok and exhausted:
        covered.append("reconnect")
    if schema_ok and any(cycle.get("cause") == "keepalive" for cycle in exhausted):
        covered.append("keepalive")
    return {
        "schema_ok": bool(schema_ok),
        "connect_attempts": connect_attempts,
        "connect_successes": connect_successes,
        "connect_failures": connect_failures,
        "reconnect_attempts": reconnect_attempts,
        "reconnect_failures": reconnect_failures,
        "reconnects": reconnects,
        "keepalive_failures": keepalive_failures,
        "keepalive_pushes": keepalive_pushes,
        "closes": closes,
        "first_result": first_result,
        "first_success_time": _as_float(fields.get("first_success_time")),
        "endpoint_url": endpoint_url,
        "endpoint_port": endpoint_port,
        "endpoint_bound": endpoint_bound,
        "cycles": cycles,
        "receive_errors": receive_errors,
        "keepalive_push_times": keepalive_push_times,
        "exhausted_cycles": exhausted,
        "covered": covered,
        "pending": [name for name in P2_REQUIRED_SUBGATES if name not in covered],
    }


def _listener_held_through(listener: Mapping, cycle: Mapping) -> bool:
    """True only when the listener held the peer connection through cycle completion.

    The SILENT phase requires the connection stay open until the bounded retry cycle
    is exhausted; an honest premature peer EOF caps the hold at ``eof_time`` so a
    receipt can never claim a hold that production already ended (this is the final
    immutable-evidence check, distinct from the ongoing settle readiness check).
    """
    hold = listener.get("open_until")
    end = cycle.get("end_time")
    if hold is None or end is None:
        return False
    if listener.get("peer_eof") is True:
        eof = listener.get("eof_time")
        if eof is None:
            return False
        hold = min(hold, eof)
    return float(hold) >= float(end)


def _p2_phase_coverage(phase: str, derived: Mapping, listener: Mapping) -> dict:
    """The exact section 4 coverage definitions, one per P2 phase."""
    listener = _listener_view(listener)
    covered: list = []
    closure_path = None
    if phase == "P2_INITIAL":
        if (
            derived.get("schema_ok")
            and derived.get("endpoint_bound")
            and derived.get("first_result") is not None
            and str(derived.get("first_result")).strip() != "1"
            and (derived.get("connect_attempts") or 0) >= 1
            and (derived.get("connect_failures") or 0) >= 1
            and derived.get("connect_successes") == 0
            and not derived.get("cycles")
        ):
            covered.append("initial_failure")
    elif phase == "P2_CLOSE":
        cycle = _single_exhausted_cycle(derived)
        if (
            listener.get("accepted") == 1
            and listener.get("peer_is_owned_ai") is True
            and listener.get("sent_bytes") == 0
            and listener.get("closed") is True
            and listener.get("fin") is True
            and derived.get("schema_ok")
            and str(derived.get("first_result")).strip() == "1"
            and cycle is not None
            and cycle.get("cause") in ("close", "keepalive")
        ):
            close_time = listener.get("close_time")
            after_close = [
                item
                for item in (derived.get("receive_errors") or [])
                if item.get("time") is not None and close_time is not None and item["time"] >= close_time
            ]
            if after_close:
                covered.append("closure")
                closure_path = "close_branch" if cycle.get("cause") == "close" else "keepalive_fallback"
    elif phase == "P2_SILENT":
        cycle = _single_exhausted_cycle(derived)
        pushes = derived.get("keepalive_push_times") or []
        spacing_ok = False
        base = derived.get("first_success_time")
        if len(pushes) == P2_KEEPALIVE_PUSHES and base is not None and all(item is not None for item in pushes):
            deltas = [pushes[0] - base] + [pushes[i] - pushes[i - 1] for i in range(1, len(pushes))]
            expected = [P2_KEEPALIVE_INITIAL] + [P2_KEEPALIVE_INTERVAL] * (len(pushes) - 1)
            spacing_ok = all(
                abs(delta - want) <= P2_KEEPALIVE_TOLERANCE for delta, want in zip(deltas, expected)
            )
        if (
            listener.get("accepted") == 1
            and listener.get("peer_is_owned_ai") is True
            and listener.get("sent_bytes") == 0
            and cycle is not None
            and cycle.get("cause") == "keepalive"
            and derived.get("schema_ok")
            and str(derived.get("first_result")).strip() == "1"
            and not derived.get("receive_errors")
            and spacing_ok
            and _listener_held_through(listener, cycle)
        ):
            covered.append("keepalive")
    subgate = P2_PHASE_SUBGATE.get(phase)
    pending = [] if (subgate and subgate in covered) else ([subgate] if subgate else [])
    return {"covered": covered, "pending": pending, "closure_path": closure_path}


def _p2_probe_problems(derived: Mapping, measured: Mapping, phase: Optional[str]) -> list:
    """Compare a re-derived classifier view against the recorded measured block."""
    problems: list = []
    coverage = _p2_phase_coverage(phase, derived, _listener_view(measured.get("listener"))) if phase in P2_PHASES else None
    expected_covered = coverage["covered"] if coverage else derived["covered"]
    expected_pending = coverage["pending"] if coverage else derived["pending"]
    if list(expected_covered) != list(measured.get("covered_subgates") or []):
        problems.append("P2_coverage_not_rederived")
    if list(expected_pending) != list(measured.get("pending_subgates") or []):
        problems.append("P2_pending_not_rederived")
    if coverage is not None and coverage.get("closure_path") != measured.get("closure_path"):
        problems.append("P2_closure_path_not_rederived")
    for key in (
        "connect_attempts",
        "connect_successes",
        "connect_failures",
        "reconnect_attempts",
        "reconnect_failures",
        "reconnects",
        "keepalive_failures",
        "keepalive_pushes",
        "closes",
    ):
        if derived.get(key) != measured.get(key):
            problems.append(f"P2_{key}_not_rederived")
    endpoint = measured.get("pinned_endpoint") or {}
    if derived["endpoint_url"] != endpoint.get("url") or derived["endpoint_port"] != endpoint.get("port"):
        problems.append("P2_endpoint_not_rederived")
    return problems


def _measure_p2(staging_root, record: Mapping, session, port, phase: Optional[str] = None) -> dict:
    """P2 evidence derived from the tool's setup, the staged artifact and listener.

    The dead-port setup (both-family listener absence + a real refused connect) is
    measured and persisted by the tool *before* spawn. For P2_CLOSE/P2_SILENT the
    tool-owned listener log is bound in as well. Coverage is computed from the exact
    schema emitted by the env-gated observer *inside the real staged network thread*
    and the tool's captured listener events, using the section 4 definitions.
    """
    setup = record.get("measurement_setup") or {}
    phase = phase if phase is not None else (record.get("phase") if isinstance(record, Mapping) else None)
    dead = None
    listener_absent = {"ipv4": False, "ipv6": False}
    refused = False
    probe_attempts = 0
    timings: list = []
    if isinstance(setup, Mapping) and setup.get("kind") == "dead_port":
        dead = setup.get("dead_port")
        listener_absent = {
            "ipv4": bool((setup.get("listener_absent") or {}).get("ipv4")),
            "ipv6": bool((setup.get("listener_absent") or {}).get("ipv6")),
        }
        refused = bool(setup.get("refused"))
        probe_attempts = setup.get("attempts") if _is_int(setup.get("attempts")) else 0
        timings = list(setup.get("timings") or [])
    if not _is_port(dead):
        dead = int(port) if _is_port(port) else None

    artifact = _read_p2_probe_fields(staging_root, record) or {}
    listener_fields = _read_listener_fields(staging_root, record) or {}
    derived = _p2_derive(artifact, dead)
    if phase in P2_PHASES:
        coverage = _p2_phase_coverage(phase, derived, _listener_view(listener_fields))
        covered = coverage["covered"]
        pending = coverage["pending"]
        closure_path = coverage["closure_path"]
    else:
        covered = derived["covered"]
        pending = derived["pending"]
        closure_path = None
    return {
        "dead_port": dead,
        "refused": bool(refused),
        "attempts": probe_attempts,
        "probe_attempts": probe_attempts,
        "connect_attempts": derived["connect_attempts"],
        "connect_successes": derived["connect_successes"],
        "connect_failures": derived["connect_failures"],
        "attempt_timings": timings,
        "listener_absent": listener_absent,
        "pinned_endpoint": {
            "schema": artifact.get("schema"),
            "url": derived["endpoint_url"],
            "port": derived["endpoint_port"],
            "nonce": artifact.get("nonce"),
            "first_result": artifact.get("first_result"),
            "first_error": artifact.get("first_error"),
            "first_time": artifact.get("first_time"),
            "first_success_time": derived.get("first_success_time"),
            "last_result": artifact.get("last_result"),
            "last_error": artifact.get("last_error"),
            "last_time": artifact.get("last_time"),
        },
        "reconnect_attempts": derived["reconnect_attempts"],
        "reconnect_failures": derived["reconnect_failures"],
        "reconnects": derived["reconnects"],
        "keepalive_failures": derived["keepalive_failures"],
        "keepalive_pushes": derived["keepalive_pushes"],
        "closes": derived["closes"],
        "cycles": derived["cycles"],
        "listener": _listener_view(listener_fields),
        "closure_path": closure_path,
        "artifact_schema_ok": derived["schema_ok"],
        "covered_subgates": covered,
        "pending_subgates": pending,
        "coverage_complete": bool(covered),
        "p2_artifact_present": bool(artifact),
    }


def _validate_p2_artifact_binding(staging_root, receipt: Mapping) -> list:
    """Re-derive P2 coverage from the immutable copied artifacts and compare.

    The receipt's measured coverage is never trusted on its own: the copied, hashed
    ``p2`` probe (and, for CLOSE/SILENT, the copied listener log) are re-parsed and
    the same classifier must reproduce the counters, endpoint, closure path and
    covered/pending subgates.
    """
    parsed = _probe_fields(staging_root, "ai", receipt)
    artifact = parsed.get("p2")
    if not isinstance(artifact, Mapping):
        return []
    measured = receipt.get("measured") or {}
    derived = _p2_derive(artifact.get("fields") or {}, measured.get("dead_port"))
    return _p2_probe_problems(derived, measured, receipt.get("phase"))


def _read_p2_probe_fields(staging_root, record: Mapping) -> dict:
    """Parse the staged P2 instrumentation artifact if the tool launcher left it."""
    try:
        paths = staging.role_paths(staging_root, "ai")
    except Exception:  # noqa: BLE001
        return {}
    target = paths.data / "Balatro" / staging.PROBE_P2
    if not target.is_file():
        return {}
    try:
        fields = staging.parse_probe(target.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}
    # N9: the artifact must carry the prepared session's own nonce; an artifact with
    # no nonce at all is refused here, not only in the later strict probe check.
    if not record.get("nonce") or fields.get("nonce") != record.get("nonce"):
        return {}
    for key in (
        "port",
        "connect_attempts",
        "connect_successes",
        "connect_failures",
        "reconnect_attempts",
        "reconnect_failures",
        "reconnects",
        "keepalive_failures",
        "keepalive_pushes",
        "closes",
    ):
        if key in fields:
            fields[key] = _coerce_int(fields[key])
    return fields


def _read_listener_fields(staging_root, record: Mapping) -> dict:
    """Parse the staged tool-owned listener log (CLOSE/SILENT phases) if present."""
    try:
        paths = staging.role_paths(staging_root, "ai")
    except Exception:  # noqa: BLE001
        return {}
    target = paths.data / "Balatro" / staging.PROBE_LISTENER
    if not target.is_file():
        return {}
    try:
        fields = staging.parse_probe(target.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}
    if not record.get("nonce") or fields.get("nonce") != record.get("nonce"):
        return {}
    return fields


def _coerce_int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return value


def _probe_fields(staging_root, role: str, receipt: Mapping) -> dict:
    """Re-parse a copied probe from disk; never trust stored field values."""
    entry = ((receipt.get("probes") or {}).get(role) or {})
    parsed: dict = {}
    for label, item in entry.items():
        copy = staging_root / item.get("copy", "")
        if not copy.is_file():
            parsed[label] = None
            continue
        parsed[label] = {
            "fields": staging.parse_probe(copy.read_text(encoding="utf-8", errors="replace")),
            "mtime": copy.stat().st_mtime,
            "copy_sha256": staging.sha256_file(copy),
        }
    return parsed


def _validate_receipt_probes(staging_root, phase: str, receipt: Mapping) -> list:
    problems: list = []
    roles = PHASE_ROLES.get(phase, ())
    nonce = receipt.get("nonce")
    for role in roles:
        parsed = _probe_fields(staging_root, role, receipt)
        for label in PHASE_EVIDENCE.get(phase, ()):
            item = parsed.get(label)
            if not item:
                problems.append(f"{phase}_{role}_{label}_missing")
                continue
            fields = item["fields"]
            if fields.get("nonce") != nonce:
                problems.append(f"{phase}_{role}_{label}_nonce_mismatch")
            if fields.get("patch") != staging.PATCH_ID:
                problems.append(f"{phase}_{role}_{label}_patch_mismatch")
            if label == "steam_marker" and fields.get("steam_patch_applied") != "true":
                problems.append(f"{phase}_{role}_steam_patch_not_applied")
            if label == "steam_post":
                if fields.get("steam") != "nil":
                    problems.append(f"{phase}_{role}_steam_present")
                if fields.get("luasteam") != "nil":
                    problems.append(f"{phase}_{role}_luasteam_present")
    return problems


def _validate_crash_observation(receipt: Mapping) -> list:
    problems: list = []
    measured = receipt.get("measured") or {}
    codes = measured.get("crash_exit_codes")
    expected = measured.get("crash_end_code_expected")
    if not isinstance(codes, Mapping) or not codes:
        problems.append("CRASH_exit_codes_missing")
    elif not (_is_int(expected) and all(code == expected for code in codes.values())):
        problems.append("CRASH_exit_code_not_tool_owned")
    if measured.get("crash_end_mode") != staging.MEASUREMENT_END_MODE:
        problems.append("CRASH_end_mode_unbound")
    if measured.get("exit_code_measured") is not True:
        problems.append("CRASH_exit_code_unmeasured")
    if measured.get("cleanup_ok") is not True:
        problems.append("CRASH_cleanup_missing")
    # N2: only the fresh, nonce-bound crash probes from every role prove the crash.
    probes = measured.get("crash_probes")
    roles = set(PHASE_ROLES.get("CRASH", ()))
    if not isinstance(probes, Mapping) or set(probes) != roles:
        problems.append("CRASH_probes_missing")
    elif not all(
        item.get("fresh") is True and item.get("nonce_bound") is True and item.get("patch_bound") is True
        for item in probes.values()
    ):
        problems.append("CRASH_probe_unbound")
    if measured.get("crash_observed") is not True:
        problems.append("CRASH_not_observed")
    # The stimulus label must be bound to the *prepared* open record (CRASH phase +
    # the tool's crash setup); an arbitrary abnormal exit is never relabelled.
    if measured.get("crash_stimulus_bound") is not True:
        problems.append("CRASH_stimulus_unbound")
    elif measured.get("crash_stimulus") != staging.MEASUREMENT_CRASH_STIMULUS:
        problems.append("CRASH_stimulus_unbound")
    return problems


def _validate_p2_observation(phase: str, receipt: Mapping) -> list:
    problems: list = []
    measured = receipt.get("measured") or {}
    if phase == "P2_INITIAL":
        if not _is_port(measured.get("dead_port")):
            problems.append("P2_dead_port_missing")
        if measured.get("refused") is not True:
            problems.append("P2_refused_missing")
        absent = measured.get("listener_absent") or {}
        if absent.get("ipv4") is not True:
            problems.append("P2_listener_absent_ipv4_missing")
        if absent.get("ipv6") is not True:
            problems.append("P2_listener_absent_ipv6_missing")
        if not _is_int(measured.get("attempts")) or measured.get("attempts", 0) < 1:
            problems.append("P2_attempts_missing")
    endpoint = measured.get("pinned_endpoint") or {}
    if endpoint.get("url") != "127.0.0.1":
        problems.append("P2_endpoint_not_loopback")
    elif not _is_port(endpoint.get("port")):
        problems.append("P2_endpoint_port_missing")
    elif _is_port(measured.get("dead_port")) and int(endpoint["port"]) != int(measured["dead_port"]):
        problems.append("P2_endpoint_port_mismatch")
    # Coverage is never a caller/stored claim: the exact section 4 definition must be
    # satisfied by the same measured block (re-derived from the copied artifacts in
    # ``_validate_p2_artifact_binding``).
    subgate = P2_PHASE_SUBGATE.get(phase)
    covered = measured.get("covered_subgates")
    pending = measured.get("pending_subgates")
    if not isinstance(covered, list) or not isinstance(pending, list):
        problems.append("P2_coverage_unbound")
        return problems
    if measured.get("coverage_complete") is not True or subgate not in covered or pending:
        problems.append(f"P2_coverage_incomplete:{subgate}")
    if phase in ("P2_CLOSE", "P2_SILENT"):
        listener = measured.get("listener") or {}
        if listener.get("present") is not True:
            problems.append(f"{phase}_listener_missing")
        if phase == "P2_CLOSE" and measured.get("closure_path") not in ("close_branch", "keepalive_fallback"):
            problems.append("P2_CLOSE_closure_path_missing")
        if phase == "P2_SILENT" and measured.get("closure_path") is not None:
            problems.append("P2_SILENT_closure_path_unexpected")
    return problems


def _validate_p2_coverage(phase: str, receipt: Mapping) -> list:
    """Never stamp a broad P2 pass: only the phase's own defined coverage passes."""
    measured = receipt.get("measured") or {}
    pending = measured.get("pending_subgates")
    if not isinstance(pending, list) or measured.get("coverage_complete") is not True:
        return ["P2_coverage_unbound"]
    return [f"P2_pending:{str(name)}" for name in pending]


def _validate_receipt_against_layers(phase: str, receipt: Mapping, layer_n: Mapping, layer_m: Mapping, port) -> list:
    problems: list = []
    measured = receipt.get("measured") or {}
    if phase == "P1A":
        boot = measured.get("bootstrap_install_digest")
        role_digests = measured.get("role_install_digests")
        if not _is_sha256(boot):
            problems.append("P1A_bootstrap_digest_missing")
        if not isinstance(role_digests, Mapping) or set(role_digests) != set(staging.ROLES):
            problems.append("P1A_role_digests_missing")
        elif not all(_is_sha256(value) for value in role_digests.values()):
            problems.append("P1A_role_digest_invalid")
        elif boot not in role_digests.values():
            problems.append("P1A_bootstrap_not_equal_roles")
        current_boot = (layer_n.get("bootstrap") or {}).get("install_digest")
        current_roles = {role: (entry or {}).get("install_digest") for role, entry in (layer_n.get("roles") or {}).items()}
        if _is_sha256(boot) and boot != current_boot:
            problems.append("P1A_bootstrap_digest_stale")
        if isinstance(role_digests, Mapping):
            for role, digest in role_digests.items():
                if current_roles.get(role) != digest:
                    problems.append(f"P1A_role_digest_stale:{role}")
    elif phase in ("P1B", "FULL_P1"):
        mods = measured.get("mods_digests")
        if not isinstance(mods, Mapping) or set(mods) != set(staging.ROLES):
            problems.append(f"{phase}_mods_digests_missing")
        else:
            current = {role: (entry or {}).get("mods_digest") for role, entry in (layer_m.get("roles") or {}).items()}
            for role, digest in mods.items():
                if not _is_sha256(digest):
                    problems.append(f"{phase}_mods_digest_invalid:{role}")
                elif current.get(role) != digest:
                    problems.append(f"{phase}_mods_digest_stale:{role}")
        parity = measured.get("role_parity_digest")
        if not _is_sha256(parity):
            problems.append(f"{phase}_role_parity_missing")
        else:
            current_parity = {(entry or {}).get("role_parity_digest") for entry in (layer_m.get("roles") or {}).values()}
            if parity not in current_parity or len(current_parity) != 1:
                problems.append(f"{phase}_role_parity_stale")
        if not _is_port(measured.get("port")):
            problems.append(f"{phase}_port_missing")
        elif port is not None and int(measured["port"]) != int(port):
            problems.append(f"{phase}_port_mismatch")
    elif phase == "CRASH":
        problems.extend(_validate_crash_observation(receipt))
    elif phase in P2_PHASES:
        problems.extend(_validate_p2_observation(phase, receipt))
    return problems


def _measured_for_phase(phase: str, session, staging_root, record, layer_n, layer_m, port) -> dict:
    measured: dict = {}
    if phase == "P1A":
        measured["bootstrap_install_digest"] = (layer_n.get("bootstrap") or {}).get("install_digest")
        measured["role_install_digests"] = {
            role: (entry or {}).get("install_digest") for role, entry in (layer_n.get("roles") or {}).items()
        }
    elif phase in ("P1B", "FULL_P1"):
        measured["mods_digests"] = {
            role: (entry or {}).get("mods_digest") for role, entry in (layer_m.get("roles") or {}).items()
        }
        parities = {(entry or {}).get("role_parity_digest") for entry in (layer_m.get("roles") or {}).values()}
        measured["role_parity_digest"] = next(iter(parities)) if len(parities) == 1 else None
        measured["port"] = int(port) if _is_port(port) else None
    elif phase == "CRASH":
        measured.update(_measure_crash(staging_root, session, record))
    elif phase in P2_PHASES:
        measured.update(_measure_p2(staging_root, record, session, port, phase=phase))
    return measured


def _fail_open_record(staging_root, session_id: str, problems: list, *, reason: str) -> dict:
    """Fail closed: close the record *and* raise the persistent global lockout.

    An unknown or failed session must never let a later launch silently rebaseline.
    Only an explicit append-only :func:`acknowledge_lockout` clears the lockout.
    """
    problems = sorted(set(problems))
    _close_open_record(staging_root, session_id, status="failed", problems=problems)
    _write_lockout(
        staging_root,
        {
            "locked": True,
            "session_id": session_id,
            "reason": reason,
            "problems": problems,
            "locked_unix": int(time.time()),
        },
    )
    return problems


def _record_receipt_failure(staging_root, session_id: str, problems: list) -> dict:
    problems = _fail_open_record(
        staging_root, session_id, problems, reason="phase_receipt_refused"
    )
    return {
        "ok": False,
        "code": "phase_receipt_refused",
        "session_id": session_id,
        "problems": problems,
    }


def record_phase_receipt(
    staging_root,
    *,
    phase: str,
    session_id: str,
    session,
    live,
    port=None,
    live_closed=None,
) -> dict:
    """Tool-owned recorder: take after-snapshot, re-verify probes, write an immutable receipt.

    The caller supplies only the completed ``session`` (an exited ``LaunchSession``),
    the session id and a real ``live_closed`` callable. Every digest, nonce binding,
    snapshot and the CRASH/P2 measurement are recomputed here from retained handles,
    the tool's dead-port setup and the staged artifacts. No caller-supplied
    measured/evidence/observation dictionary is accepted.
    """
    staging_root = Path(staging_root).resolve()
    problems = _phase_receipt_problems(phase)
    problems.extend(_session_id_problems(session_id))
    if getattr(session, "ok", False) is not True:
        problems.append("session_not_launched")
    if getattr(session, "session_id", session_id) != session_id:
        problems.append("session_id_mismatch")
    if not _owned_all_exited(session):
        problems.append("owned_processes_running")
    record = _receipt_open_record(staging_root, session_id)
    if record is None:
        problems.append("open_session_missing")
    elif record.get("status") != "open":
        problems.append("open_session_not_open")
    if record is not None:
        # Bind the requested phase/port to the persisted prepared record *before*
        # any evidence is derived, so a receipt can never relabel a different
        # phase's or port's prepared/launched session as the one it claims.
        if record.get("phase") != phase:
            problems.append("prepared_phase_mismatch")
        record_port = record.get("port")
        if _is_port(record_port) != _is_port(port):
            problems.append("prepared_port_mismatch")
        elif _is_port(record_port) and int(record_port) != int(port):
            problems.append("prepared_port_mismatch")
    if not callable(live_closed):
        problems.append("live_closed_check_unavailable")
    else:
        try:
            if not bool(live_closed()):
                problems.append("live_game_running")
        except Exception:  # noqa: BLE001
            problems.append("live_closed_check_failed")
    if problems:
        return _record_receipt_failure(staging_root, session_id, problems)

    nonce = record.get("nonce")
    spawn_time = record.get("spawn_time")
    if getattr(session, "nonce", None) != nonce:
        return _record_receipt_failure(staging_root, session_id, ["session_nonce_mismatch"])
    end_mode = getattr(session, "end_mode", None)
    end_code = getattr(session, "end_code", None)
    closure = {
        "owned_exited": True,
        "live_closed": True,
        "checked_unix": int(time.time()),
        "ended_by": end_mode,
        "end_code": end_code if _is_int(end_code) else None,
        "ended_unix": getattr(session, "ended_unix", None),
    }
    live_roots = record.get("live_roots") or {}
    current_live = {key: str(value) for key, value in _normalize_live(live).items()}
    if {key: _norm_root(value) for key, value in live_roots.items()} != {
        key: _norm_root(value) for key, value in current_live.items()
    }:
        return _record_receipt_failure(staging_root, session_id, ["live_roots_mismatch"])

    before = record.get("before") or {}
    after = snapshot_live(live)
    snapshot_problems = _validate_snapshot(after, "after")
    if snapshot_problems:
        return _record_receipt_failure(staging_root, session_id, snapshot_problems)

    roles = PHASE_ROLES[phase]
    labels = PHASE_EVIDENCE.get(phase, ())
    probe_problems: list = []
    evidence_items: dict = {}
    dump_items: dict = {}
    for role in roles:
        paths = staging._paths_for_role(staging_root, role)
        save_dir = paths.data / "Balatro"
        evidence_items[role] = {}
        for label in labels:
            source = save_dir / PROBE_BY_LABEL[label]
            if not source.is_file():
                probe_problems.append(f"{role}_{label}_missing")
                continue
            evidence_items[role][label] = source
    if probe_problems:
        return _record_receipt_failure(staging_root, session_id, probe_problems)

    # M2: use the strong exact-path/MP-endpoint/probe and fresh Lovely checkers for
    # every required role, and copy the actual Lovely dump into receipt evidence.
    strong_problems: list = []
    for role in roles:
        paths = staging._paths_for_role(staging_root, role)
        probe_verdict = staging.collect_role_probes(
            paths,
            nonce,
            spawn_time,
            require_mp=bool(PHASE_REQUIRE_MP.get(phase, False)),
            expected_port=port if _is_port(port) else None,
            required_names=[PROBE_BY_LABEL[label] for label in labels if label in PROBE_BY_LABEL],
        )
        strong_problems.extend(f"{role}:{item}" for item in probe_verdict.get("problems", ()))
        lovely = staging.check_lovely_evidence(
            staging_root, role, spawn_time, require_dump=True
        )
        strong_problems.extend(f"{role}:{item}" for item in lovely.get("problems", ()))
        selected = _select_dump_files(
            paths, lovely.get("fresh_dumps") or [], require_socket=(phase in ("P2_CLOSE", "P2_SILENT"))
        )
        if not selected:
            strong_problems.append(f"{role}:lovely_dump_required_missing")
        dump_items[role] = selected
    if strong_problems:
        return _record_receipt_failure(staging_root, session_id, strong_problems)

    layer_n = collect_layer_n(staging_root, live=live)
    layer_m = collect_layer_m(staging_root, live=live)
    measured = _measured_for_phase(phase, session, staging_root, record, layer_n, layer_m, port)
    # N10/section 4: a P2 receipt is never closed as passed while its own defined
    # coverage is still pending. Each P2 phase proves exactly one coverage definition.
    if phase in P2_PHASES and measured.get("coverage_complete") is not True:
        return _record_receipt_failure(
            staging_root,
            session_id,
            [f"P2_coverage_incomplete:{P2_PHASE_SUBGATE.get(phase)}"],
        )

    evidence_key = _digest(
        {
            "phase": phase,
            "session_id": session_id,
            "nonce": nonce,
            "sources": {
                role: {label: staging.sha256_file(str(source)) for label, source in items.items()}
                for role, items in evidence_items.items()
            },
        }
    )
    copies = _copy_receipt_evidence(staging_root, evidence_key, evidence_items)
    dump_copies = (
        _copy_receipt_evidence(staging_root, evidence_key, dump_items) if any(dump_items.values()) else {}
    )
    measurement_artifact = _write_measurement_artifact(
        staging_root, evidence_key, phase, measured
    )

    probes: dict = {}
    for role in roles:
        probes[role] = {}
        for label in labels:
            source = evidence_items[role][label]
            probes[role][label] = {
                "copy": copies[role][label]["copy"],
                "copy_sha256": copies[role][label]["copy_sha256"],
                "source_sha256": copies[role][label]["source_sha256"],
            }
    dumps: dict = {}
    for role, items in dump_copies.items():
        dumps[role] = {
            label: {
                "copy": item["copy"],
                "copy_sha256": item["copy_sha256"],
                "source_sha256": item["source_sha256"],
            }
            for label, item in items.items()
        }

    before_roots = (before.get("roots") or {}) if isinstance(before, Mapping) else {}
    after_roots = after.get("roots") or {}
    all_roots = sorted(set(before_roots) | set(after_roots))
    changed = [
        key
        for key in all_roots
        if (before_roots.get(key) or {}).get("digest") != (after_roots.get(key) or {}).get("digest")
    ]

    body = {
        "schema": PHASE_RECEIPT_SCHEMA,
        "phase": phase,
        "staging_root": str(staging_root),
        "session_id": session_id,
        "nonce": nonce,
        "spawn_time": spawn_time,
        "exited_unix": int(time.time()),
        "roles": list(roles),
        "pids": _owned_pids(session),
        "port": int(port) if _is_port(port) else None,
        "live_roots": current_live,
        "before": {"digest": before.get("digest"), "roots": before.get("roots") or {}},
        "after": {"digest": after.get("digest"), "roots": _digest_roots(after)},
        "before_files": record.get("before_files") or {},
        "after_files": after_roots,
        "changed_roots": changed,
        "closure": closure,
        "probes": probes,
        "dumps": dumps,
        "measurement_artifact": measurement_artifact,
        "measured": measured,
        "evidence_key": evidence_key,
    }
    receipt_id = _digest(body)
    receipt = dict(body)
    receipt["receipt_id"] = receipt_id

    validation = _validate_receipt(staging_root, phase, receipt)
    if validation:
        return _record_receipt_failure(staging_root, session_id, validation)

    _write_immutable(staging_root, _receipt_path(staging_root, receipt_id), receipt)
    _close_open_record(staging_root, session_id, status="passed", problems=[])
    return {
        "ok": True,
        "code": "phase_receipt_recorded",
        "phase": phase,
        "receipt_id": receipt_id,
        "session_id": session_id,
        "path": str(_receipt_path(staging_root, receipt_id)),
        "changed_roots": changed,
        "problems": [],
    }


def _digest_roots(snapshot: Mapping) -> dict:
    roots = (snapshot.get("roots") or {}) if isinstance(snapshot, Mapping) else {}
    return {
        key: {
            "root": (entry or {}).get("root"),
            "digest": staging._digest_of((entry or {}).get("files") or {}),
        }
        for key, entry in roots.items()
    }


def _validate_receipt(staging_root, phase: str, receipt: Mapping) -> list:
    problems: list = []
    if receipt.get("schema") != PHASE_RECEIPT_SCHEMA:
        problems.append("receipt_schema_mismatch")
    if receipt.get("phase") != phase:
        problems.append("receipt_phase_mismatch")
    problems.extend(_session_id_problems(receipt.get("session_id")))
    if not isinstance(receipt.get("nonce"), str) or not receipt["nonce"]:
        problems.append("receipt_nonce_missing")
    if not _is_number(receipt.get("spawn_time")):
        problems.append("receipt_spawn_time_missing")
    if not isinstance(receipt.get("roles"), list) or set(receipt["roles"]) != set(PHASE_ROLES.get(phase, ())):
        problems.append("receipt_roles_mismatch")
    if receipt.get("changed_roots"):
        problems.append("receipt_live_diff")
    if receipt.get("before", {}).get("digest") != receipt.get("after", {}).get("digest"):
        problems.append("receipt_snapshot_digest_mismatch")
    closure = receipt.get("closure")
    if not isinstance(closure, Mapping):
        problems.append("receipt_closure_missing")
    else:
        if closure.get("owned_exited") is not True:
            problems.append("receipt_owned_process_running")
        if closure.get("live_closed") is not True:
            problems.append("receipt_live_game_open")
        # N2/N3: every tool-owned measurement run records a defined end mode/code.
        # P1A ends itself (bootstrap_exit_patch), so it carries no tool end code.
        if phase != "P1A":
            expected_end = staging.MEASUREMENT_END_CODES.get(phase)
            if closure.get("ended_by") != staging.MEASUREMENT_END_MODE:
                problems.append("receipt_end_mode_undefined")
            elif not _is_int(closure.get("end_code")) or closure.get("end_code") != expected_end:
                problems.append("receipt_end_code_mismatch")
    before_files = receipt.get("before_files")
    after_files = receipt.get("after_files")
    if not isinstance(before_files, Mapping) or not isinstance(after_files, Mapping):
        problems.append("receipt_raw_manifest_missing")
    else:
        recomputed_before = {
            key: staging._digest_of(entry or {})
            for key, entry in _raw_root_files(before_files).items()
        }
        declared_before = {key: (entry or {}).get("digest") for key, entry in (receipt.get("before", {}).get("roots") or {}).items()}
        if recomputed_before != declared_before:
            problems.append("receipt_before_manifest_unbound")
        recomputed_after = {
            key: staging._digest_of(entry or {})
            for key, entry in _raw_root_files(after_files).items()
        }
        declared_after = {key: (entry or {}).get("digest") for key, entry in (receipt.get("after", {}).get("roots") or {}).items()}
        if recomputed_after != declared_after:
            problems.append("receipt_after_manifest_unbound")
    problems.extend(_validate_receipt_probes(staging_root, phase, receipt))
    problems.extend(_validate_receipt_dumps(staging_root, phase, receipt))
    problems.extend(_validate_measurement_artifact(staging_root, receipt))
    if phase in P2_PHASES:
        problems.extend(_validate_p2_artifact_binding(staging_root, receipt))
    layer_n = collect_layer_n(staging_root, live=receipt.get("live_roots"))
    layer_m = collect_layer_m(staging_root, live=receipt.get("live_roots"))
    problems.extend(_validate_receipt_against_layers(phase, receipt, layer_n, layer_m, receipt.get("port")))
    return problems


def _raw_root_files(manifest: Mapping) -> dict:
    """Normalize both receipt raw-manifest shapes to ``key -> files`` maps."""
    normalized: dict = {}
    for key, entry in manifest.items():
        if isinstance(entry, Mapping) and "files" in entry:
            normalized[key] = entry.get("files") or {}
        else:
            normalized[key] = entry or {}
    return normalized


def _validate_receipt_dumps(staging_root, phase: str, receipt: Mapping) -> list:
    problems: list = []
    dumps = receipt.get("dumps") or {}
    for role in PHASE_ROLES.get(phase, ()):
        if not dumps.get(role):
            problems.append(f"{phase}_{role}_lovely_dump_missing")
            continue
        for label, item in dumps[role].items():
            copy = Path(staging_root) / item.get("copy", "")
            if not copy.is_file() or staging.sha256_file(copy) != item.get("copy_sha256"):
                problems.append(f"{phase}_{role}_{label}_dump_tampered")
        # N1/section 4: the copied Lovely dump of the patched socket source must
        # carry every observer payload marker, so a partially applied observer can
        # never be presented as a full one.
        if phase in P2_PHASES:
            socket_item = dumps[role].get("socket_dump")
            if not socket_item:
                problems.append(f"{phase}_{role}_socket_dump_missing")
            else:
                copy = Path(staging_root) / socket_item.get("copy", "")
                if copy.is_file():
                    text = copy.read_text(encoding="utf-8", errors="replace")
                    for marker in staging.P2_PAYLOAD_MARKERS:
                        if marker not in text:
                            problems.append(f"{phase}_{role}_socket_dump_marker_missing:{marker}")
    return problems


def _validate_measurement_artifact(staging_root, receipt: Mapping) -> list:
    """N10: the persisted raw measurement must equal the receipt's measured block."""
    problems: list = []
    artifact = receipt.get("measurement_artifact")
    if not isinstance(artifact, Mapping):
        return ["receipt_measurement_artifact_missing"]
    copy = Path(staging_root) / artifact.get("copy", "")
    if not copy.is_file() or staging.sha256_file(copy) != artifact.get("copy_sha256"):
        problems.append("receipt_measurement_artifact_tampered")
        return problems
    try:
        payload = json.loads(copy.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return problems + ["receipt_measurement_artifact_unreadable"]
    if payload.get("phase") != receipt.get("phase") or dict(payload.get("measured") or {}) != dict(
        receipt.get("measured") or {}
    ):
        problems.append("receipt_measurement_artifact_mismatch")
    return problems


def _valid_receipt_id(staging_root, phase: str, receipt_id) -> list:
    problems: list = []
    if not _is_sha256(receipt_id):
        problems.append(f"phase_{phase.lower()}_receipt_missing")
        return problems
    receipt = load_phase_receipt(staging_root, receipt_id)
    if not isinstance(receipt, Mapping):
        problems.append(f"phase_{phase.lower()}_receipt_unreadable")
        return problems
    if receipt.get("receipt_id") != receipt_id:
        problems.append(f"phase_{phase.lower()}_receipt_id_mismatch")
    else:
        body = {key: value for key, value in receipt.items() if key != "receipt_id"}
        if _digest(body) != receipt_id:
            problems.append(f"phase_{phase.lower()}_receipt_id_mismatch")
    if receipt.get("phase") != phase:
        problems.append(f"phase_{phase.lower()}_receipt_phase_mismatch")
    problems.extend(f"{phase}_{item}" for item in _validate_receipt(staging_root, phase, receipt))
    return problems


def _phase_prerequisite_problems(staging_root, phase: str) -> list:
    problems: list = []
    if phase not in REQUIRED_PHASES:
        return ["unknown_phase"]
    prior = PHASE_PREREQUISITE[phase]
    if prior is None:
        return problems
    receipts = collect_phase_receipts(staging_root)
    receipt_id = receipts.get(prior)
    if not receipt_id:
        problems.append(f"phase_prerequisite_missing:{prior.lower()}")
        return problems
    problems.extend(_valid_receipt_id(staging_root, prior, receipt_id))
    return problems


def collect_phase_receipts(staging_root) -> dict:
    """Map phase -> most recent receipt id found on disk (read-only).

    N10: "most recent" is chosen by the receipt's own recorded exit time, not by a
    hash-sorted filename.
    """
    directory = _receipts_dir(staging_root)
    if not directory.is_dir():
        return {}
    candidates: dict = {}
    for path in sorted(directory.glob("*.json")):
        receipt = _read_json(path)
        if not isinstance(receipt, Mapping):
            continue
        phase = receipt.get("phase")
        receipt_id = receipt.get("receipt_id")
        if phase in REQUIRED_PHASES and _is_sha256(receipt_id):
            exited = receipt.get("exited_unix")
            candidates.setdefault(phase, []).append((exited if _is_int(exited) else 0, receipt_id))
    return {
        phase: max(entries, key=lambda item: (item[0], item[1]))[1]
        for phase, entries in candidates.items()
    }


# ---------------------------------------------------------------------------
# Certificate build / check
# ---------------------------------------------------------------------------

def _certificates_dir(staging_root) -> Path:
    return _evidence_root(staging_root) / CERT_SUBDIR


def _pointer_path(staging_root) -> Path:
    return _evidence_root(staging_root) / POINTER_NAME


def _load_current(staging_root):
    pointer = _pointer_path(staging_root)
    if not pointer.is_file():
        return None, None
    certificate_id = pointer.read_text(encoding="utf-8").strip()
    if not certificate_id or not SESSION_ID_RE.match(certificate_id):
        return None, None
    path = _certificates_dir(staging_root) / f"{certificate_id}.json"
    if not path.is_file():
        return path, None
    try:
        return path, json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return path, None


def _write_certificate(staging_root, certificate: Mapping) -> Path:
    staging_root = Path(staging_root).resolve()
    certificate_id = certificate["certificate_id"]
    path = _certificates_dir(staging_root) / f"{certificate_id}.json"
    text = json.dumps(certificate, indent=2, sort_keys=True, default=str) + "\n"
    _safe_write(staging_root, path)
    if path.is_file():
        if path.read_text(encoding="utf-8") != text:
            raise CertificateError("certificate_conflict", f"immutable certificate differs: {path}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    _safe_write(staging_root, _pointer_path(staging_root))
    _pointer_path(staging_root).parent.mkdir(parents=True, exist_ok=True)
    _atomic_write_text(_pointer_path(staging_root), certificate_id + "\n")
    return path


def _certificate_provisional(certificate: Mapping) -> dict:
    return {
        "schema": SCHEMA,
        "native_layer": certificate.get("native_layer"),
        "mods_layer": certificate.get("mods_layer"),
        "tools": certificate.get("tools"),
        "live_roots": certificate.get("live_roots"),
        "receipts": certificate.get("receipts"),
        "evidence": {
            phase: {
                "probes": {
                    role: {label: item.get("copy_sha256") for label, item in labels.items()}
                    for role, labels in (bundle.get("probes") or {}).items()
                },
                "dumps": {
                    role: {label: item.get("copy_sha256") for label, item in labels.items()}
                    for role, labels in (bundle.get("dumps") or {}).items()
                },
            }
            for phase, bundle in (certificate.get("evidence") or {}).items()
        },
    }


def build_certificate(
    staging_root,
    *,
    receipt_ids: Optional[Mapping] = None,
    phases: Optional[Mapping] = None,
    live=None,
    port=None,
    server_bind=None,
    tools: Optional[Mapping] = None,
    extra: Optional[Mapping] = None,
) -> dict:
    """Assemble the certificate from tool-owned phase receipt IDs only.

    ``phases`` is accepted for backward compatibility with callers that used to
    hand-assemble measured dictionaries; it is always refused with a bounded code
    (never a ``TypeError``) because the certificate may only be built from
    receipts produced by :func:`record_phase_receipt`.
    """
    if phases:
        return {
            "ok": False,
            "code": "certificate_receipts_required",
            "status": "partial",
            "problems": ["caller_phase_data_rejected"],
            "certificate_id": None,
            "path": None,
        }
    staging_root = Path(staging_root).resolve()
    receipt_ids = dict(receipt_ids or {})
    problems: list = []
    lock = lockout(staging_root)
    if lock.get("locked"):
        return {
            "ok": False,
            "code": "certificate_locked_out",
            "status": "partial",
            "problems": ["certificate_locked_out"],
            "certificate_id": None,
            "path": lock.get("path"),
        }
    for name in REQUIRED_PHASES:
        receipt_id = receipt_ids.get(name)
        if not receipt_id:
            problems.append(f"phase_{name.lower()}_missing")
        else:
            problems.extend(_valid_receipt_id(staging_root, name, receipt_id))
    nonces = []
    for name in REQUIRED_PHASES:
        receipt = load_phase_receipt(staging_root, receipt_ids.get(name) or "")
        if isinstance(receipt, Mapping):
            nonces.append(receipt.get("nonce"))
    if len(set(nonces)) != len(nonces):
        problems.append("phase_nonces_not_distinct")
    problems.extend(_p2_coverage_problems(staging_root, receipt_ids))
    layer_n = collect_layer_n(staging_root, live=live)
    layer_m = collect_layer_m(staging_root, live=live, server_bind=server_bind)
    problems.extend(_layer_problems(layer_n, layer_m, port))
    required_tools = set(bound_tool_specs())
    if tools is None:
        tools_map = collect_bound_tools()
        for name, entry in tools_map.items():
            if not entry.get("present"):
                problems.append(f"bound_tool_missing:{name}")
    else:
        if set(tools) != required_tools:
            problems.append("bound_tools_incomplete")
            for name in sorted(required_tools - set(tools)):
                problems.append(f"bound_tool_missing:{name}")
            for name in sorted(set(tools) - required_tools):
                problems.append(f"bound_tool_unknown:{name}")
        tools_map, tool_problems = _validate_tools(tools)
        problems.extend(tool_problems)
    problems = sorted(set(problems))
    if problems:
        return {
            "ok": False,
            "code": "certificate_partial",
            "status": "partial",
            "problems": problems,
            "certificate_id": None,
            "path": None,
        }
    evidence = {}
    for name in REQUIRED_PHASES:
        receipt = load_phase_receipt(staging_root, receipt_ids[name])
        evidence[name] = {
            "receipt_id": receipt_ids[name],
            "probes": {
                role: {
                    label: {"copy": item.get("copy"), "copy_sha256": item.get("copy_sha256")}
                    for label, item in labels.items()
                }
                for role, labels in (receipt.get("probes") or {}).items()
            },
            "dumps": {
                role: {
                    label: {"copy": item.get("copy"), "copy_sha256": item.get("copy_sha256")}
                    for label, item in labels.items()
                }
                for role, labels in (receipt.get("dumps") or {}).items()
            },
        }
    certificate = {
        "schema": SCHEMA,
        "status": "complete",
        "native_layer": layer_n,
        "mods_layer": layer_m,
        "tools": tools_map,
        "live_roots": _normalize_live(live),
        "receipts": {name: receipt_ids[name] for name in REQUIRED_PHASES},
        "phases": {
            name: {
                "nonce": load_phase_receipt(staging_root, receipt_ids[name]).get("nonce"),
                "measured": load_phase_receipt(staging_root, receipt_ids[name]).get("measured"),
            }
            for name in REQUIRED_PHASES
        },
        "evidence": evidence,
        "metadata": dict(extra) if extra else {},
        "created_unix": int(time.time()),
    }
    certificate["certificate_id"] = _digest(_certificate_provisional(certificate))
    path = _write_certificate(staging_root, certificate)
    return {
        "ok": True,
        "code": "certificate_complete",
        "status": "complete",
        "problems": [],
        "certificate_id": certificate["certificate_id"],
        "path": str(path),
    }


def collect_bound_tools_check(proof: Mapping) -> tuple:
    problems: list = []
    current = collect_bound_tools()
    stored = proof.get("tools") or {}
    if set(stored) != set(current):
        problems.append("bound_tools_incomplete")
        for name in sorted(set(current) - set(stored)):
            problems.append(f"bound_tool_missing:{name}")
        for name in sorted(set(stored) - set(current)):
            problems.append(f"bound_tool_unknown:{name}")
    for name, entry in stored.items():
        actual = current.get(name)
        if actual is None or not actual.get("present"):
            problems.append(f"bound_tool_missing:{name}")
        elif not entry.get("present"):
            problems.append(f"bound_tool_missing:{name}")
        elif actual.get("sha256") != entry.get("sha256"):
            problems.append(f"bound_tool_changed:{name}")
    return current, problems


def _p2_coverage_problems(staging_root, receipt_ids: Mapping) -> list:
    """All three P2 phases must individually prove their own coverage."""
    problems: list = []
    for phase in P2_PHASES:
        receipt_id = (receipt_ids or {}).get(phase)
        receipt = load_phase_receipt(staging_root, receipt_id) if _is_sha256(receipt_id) else None
        if not isinstance(receipt, Mapping):
            continue
        problems.extend(_validate_p2_coverage(phase, receipt))
    return problems


def _certificate_receipt_problems(staging_root, certificate: Mapping) -> list:
    problems: list = []
    receipts = certificate.get("receipts")
    if not isinstance(receipts, Mapping):
        problems.append("certificate_receipts_missing")
        return problems
    nonces = []
    for phase in REQUIRED_PHASES:
        receipt_id = receipts.get(phase)
        if not receipt_id:
            problems.append(f"phase_{phase.lower()}_missing")
            continue
        problems.extend(_valid_receipt_id(staging_root, phase, receipt_id))
        receipt = load_phase_receipt(staging_root, receipt_id)
        if isinstance(receipt, Mapping):
            nonces.append(receipt.get("nonce"))
    if len(set(nonces)) != len(nonces):
        problems.append("phase_nonces_not_distinct")
    problems.extend(_p2_coverage_problems(staging_root, receipts))
    return problems


def check_certificate(staging_root, live=None, port=None, server_bind=None) -> dict:
    """Recompute the bound layers/tools/receipts; never compare live contents."""
    staging_root = Path(staging_root).resolve()
    lock = lockout(staging_root)
    if lock.get("locked"):
        return {
            "ok": False,
            "code": "certificate_locked_out",
            "problems": ["certificate_locked_out"],
            "path": lock.get("path"),
            "certificate_id": None,
        }
    path, certificate = _load_current(staging_root)
    if path is None:
        return {"ok": False, "code": "certificate_missing", "problems": ["certificate_missing"], "path": None}
    if certificate is None:
        return {"ok": False, "code": "certificate_unreadable", "problems": ["certificate_unreadable"], "path": str(path)}
    problems: list = []
    if certificate.get("schema") != SCHEMA:
        problems.append("certificate_schema_mismatch")
    if certificate.get("status") != "complete":
        problems.append("certificate_partial")
    certificate_id = certificate.get("certificate_id")
    if any(item.get("certificate_id") == certificate_id for item in read_revocations(staging_root)):
        problems.append("certificate_revoked")
    stored_live = {key: _norm_root(value) for key, value in (certificate.get("live_roots") or {}).items()}
    current_live = {key: _norm_root(value) for key, value in _normalize_live(live).items()}
    if stored_live != current_live:
        problems.append("live_roots_mismatch")
    current_n = collect_layer_n(staging_root, live=live)
    if current_n != certificate.get("native_layer"):
        problems.append("native_layer_changed")
    current_m = collect_layer_m(staging_root, live=live, server_bind=server_bind)
    if current_m != certificate.get("mods_layer"):
        if current_m.get("roles") != (certificate.get("mods_layer") or {}).get("roles"):
            problems.append("mods_layer_changed")
        else:
            problems.append("server_bind_changed")
    _current_tools, tool_problems = collect_bound_tools_check(certificate)
    problems.extend(tool_problems)
    if port is not None:
        stored_ports = {
            entry.get("endpoint", {}).get("port")
            for entry in (certificate.get("mods_layer") or {}).get("roles", {}).values()
        }
        if stored_ports != {int(port)}:
            problems.append("match_port_mismatch")
    problems.extend(_certificate_receipt_problems(staging_root, certificate))
    for phase, bundle in (certificate.get("evidence") or {}).items():
        for kind in ("probes", "dumps"):
            for role, labels in (bundle.get(kind) or {}).items():
                for label, item in labels.items():
                    copy_path = staging_root / item.get("copy", "")
                    if not copy_path.is_file() or staging.sha256_file(copy_path) != item.get("copy_sha256"):
                        problems.append(f"evidence_tampered:{phase}:{role}:{label}")
    recomputed = _digest(_certificate_provisional(certificate))
    if certificate_id != recomputed:
        problems.append("certificate_id_mismatch")
    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "code": "ok" if not problems else "certificate_invalid",
        "problems": problems,
        "path": str(path),
        "certificate_id": certificate_id,
    }


def certificate_status(staging_root) -> dict:
    path, certificate = _load_current(staging_root)
    if certificate is None:
        return {"present": False, "path": str(path) if path else None, "lockout": lockout(staging_root)}
    return {
        "present": True,
        "path": str(path),
        "certificate_id": certificate.get("certificate_id"),
        "status": certificate.get("status"),
        "live_roots": certificate.get("live_roots"),
        "lockout": lockout(staging_root),
        "revocations": len(read_revocations(staging_root)),
    }


# ---------------------------------------------------------------------------
# Revocation
# ---------------------------------------------------------------------------

def read_revocations(staging_root) -> list:
    return _read_jsonl(_evidence_root(staging_root) / REVOCATION_NAME)


def revoke_certificate(staging_root, *, certificate_id=None, reason: str, session_id=None) -> dict:
    staging_root = Path(staging_root).resolve()
    if certificate_id is None:
        _path, certificate = _load_current(staging_root)
        certificate_id = (certificate or {}).get("certificate_id")
    record = {
        "certificate_id": certificate_id,
        "reason": reason,
        "session_id": session_id,
        "revoked_unix": int(time.time()),
    }
    path = _append_jsonl(staging_root, REVOCATION_NAME, record)
    return {"ok": True, "code": "certificate_revoked", "path": str(path), "record": record}


# ---------------------------------------------------------------------------
# Open session records (exclusive, single nonce owner)
# ---------------------------------------------------------------------------

def _open_dir(staging_root) -> Path:
    return _evidence_root(staging_root) / OPEN_SUBDIR


def _open_record_path(staging_root, session_id: str) -> Path:
    return _open_dir(staging_root) / f"{session_id}.json"


def _session_dir(staging_root, session_id: str) -> Path:
    return _evidence_root(staging_root) / SESSIONS_SUBDIR / session_id


def list_open_records(staging_root) -> list:
    """Every session that still blocks a new spawn: open or failed-pending.

    N7: strict listing. A corrupt/unreadable file, a non-dict record, a directory
    that cannot be enumerated or a record with an unrecognized status all raise a
    :class:`staging.StagingError` so the host and installer (which already wrap this
    call) fail closed instead of treating the anomaly as "no session". Only records
    with a recognized *closed* status are skipped; every blocking status is returned.
    """
    directory = _open_dir(staging_root)
    try:
        entries = os.scandir(directory)
    except FileNotFoundError:
        return []
    except OSError as error:
        raise staging.StagingError("open_records_unreadable", str(error))
    records: list = []
    try:
        for entry in entries:
            if not entry.name.endswith(".json"):
                continue
            try:
                if not entry.is_file():
                    raise staging.StagingError("open_record_unreadable", entry.name)
            except OSError as error:
                raise staging.StagingError("open_record_unreadable", str(error))
            try:
                text = Path(entry.path).read_text(encoding="utf-8")
            except OSError as error:
                raise staging.StagingError("open_record_unreadable", str(error))
            try:
                record = json.loads(text)
            except ValueError:
                raise staging.StagingError("open_record_corrupt", entry.name)
            if not isinstance(record, Mapping):
                raise staging.StagingError("open_record_invalid", entry.name)
            status = record.get("status")
            if status in OPEN_BLOCKING_STATUSES:
                records.append(record)
            elif status in OPEN_CLOSED_STATUSES:
                continue
            else:
                raise staging.StagingError("open_record_unknown_status", entry.name)
    finally:
        entries.close()
    return records


def load_open_record(staging_root, session_id: str):
    if not SESSION_ID_RE.match(str(session_id)):
        return None
    return _read_json(_open_record_path(staging_root, session_id))


def _write_open_record(staging_root, record: Mapping) -> Path:
    staging_root = Path(staging_root).resolve()
    path = _open_record_path(staging_root, record["session_id"])
    _safe_write(staging_root, path)
    _atomic_write_text(path, json.dumps(record, indent=2, sort_keys=True, default=str) + "\n")
    return path


def _close_open_record(staging_root, session_id: str, *, status: str, problems: Optional[list] = None) -> Optional[dict]:
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping):
        return None
    record = dict(record)
    record["status"] = status
    record["closed_unix"] = int(time.time())
    record["close_problems"] = sorted(set(problems or []))
    _write_open_record(staging_root, record)
    return record


def bind_open_session(staging_root, session_id: str, *, pids: Mapping, spawn_time=None) -> dict:
    """Record the exact owned PIDs and spawn time on the open record before any attestation."""
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping) or record.get("status") != "open":
        return {"ok": False, "code": "open_session_missing"}
    record = dict(record)
    record["pids"] = {str(role): [int(pid) for pid in values] for role, values in (pids or {}).items()}
    if spawn_time is not None:
        record["spawn_time"] = float(spawn_time)
    _write_open_record(staging_root, record)
    return {"ok": True, "code": "open_session_bound", "pids": record["pids"]}


def bind_open_session_pids(staging_root, session_id: str, pids: Mapping) -> dict:
    return bind_open_session(staging_root, session_id, pids=pids)


def _measurement_setup_problems(phase: str, port, setup) -> list:
    """N6: bind the pre-spawn setup to the phase; reject a loose caller mapping.

    The setup is the tool's own persisted pre-spawn measurement. Its presence and
    shape are fixed per phase: CRASH is exactly the crash stimulus constant; the P2
    phases carry a ``dead_port`` setup whose measured port equals the session port;
    every other phase must carry no setup at all.
    """
    problems: list = []
    if phase == "CRASH":
        if setup != {"kind": "crash", "stimulus": staging.MEASUREMENT_CRASH_STIMULUS}:
            problems.append("measurement_setup_invalid")
    elif phase == "P2_INITIAL":
        if not isinstance(setup, Mapping) or setup.get("kind") != "dead_port":
            problems.append("measurement_setup_invalid")
        elif not _is_port(setup.get("dead_port")) or not _is_port(port) or int(setup["dead_port"]) != int(port):
            problems.append("measurement_setup_port_mismatch")
        elif setup.get("refused") is not True:
            problems.append("measurement_setup_unmeasured")
    elif phase in ("P2_CLOSE", "P2_SILENT"):
        if not isinstance(setup, Mapping) or setup.get("kind") != "listener":
            problems.append("measurement_setup_invalid")
        elif not _is_port(setup.get("port")) or not _is_port(port) or int(setup["port"]) != int(port):
            problems.append("measurement_setup_port_mismatch")
        elif setup.get("mode") != phase:
            problems.append("measurement_setup_mode_mismatch")
    elif setup is not None:
        problems.append("measurement_setup_unexpected")
    return problems


# ---------------------------------------------------------------------------
# Per-session prepare / verdict
# ---------------------------------------------------------------------------

def prepare_session(
    staging_root,
    *,
    live,
    session_id: str,
    port=None,
    closed_check=None,
    phase: str = MATCH,
    backup_id=None,
    backup_verify=None,
    measurement_setup=None,
) -> dict:
    """Closed-game preparation: verify prerequisites/backup, mint one nonce, open exclusively.

    ``phase`` defaults to the normal-practice ``MATCH`` record, which requires a
    **current verified certificate**. The ordered ``P1A``/``P1B``/``FULL_P1``/
    ``CRASH``/``P2`` phases are measurement-only and are gated on the previous
    phase receipt instead of a certificate. A second open record is refused until
    the previous one is closed by :func:`record_phase_receipt`,
    :func:`record_session_verdict` or :func:`record_session_no_spawn`.

    ``backup_verify`` is a callable returning the **real** ``check_backup_evidence``
    verdict: the record binds its cryptographic manifest identity and every
    verified per-root digest, and the before-snapshot is required to match those
    digests for the identical live-root keys. A caller-supplied ``backup_id`` must
    equal that evidence id (or the manifest label it authenticated); it can never
    stand in for missing evidence. The nonce is always minted here (never a caller
    value), and a session id can never be reused.
    """
    staging_root = Path(staging_root).resolve()
    problems = _session_id_problems(session_id)
    if phase not in SESSION_PHASES:
        problems.append("unknown_phase")
    if port is not None and not _is_port(port):
        problems.append("bad_port")
    if not callable(closed_check):
        problems.append("closed_check_required")
    else:
        try:
            if not bool(closed_check()):
                problems.append("live_not_closed")
        except Exception:  # noqa: BLE001
            problems.append("closed_check_failed")
    lock = lockout(staging_root)
    if lock.get("locked"):
        problems.append("certificate_locked_out")
    if list_open_records(staging_root):
        problems.append("session_already_open")
    if _receipt_open_record(staging_root, session_id) is not None:
        problems.append("session_id_reused")
    if phase == MATCH:
        verdict = check_certificate(staging_root, live=live, port=port)
        if not verdict.get("ok"):
            problems.append(f"certificate_not_valid:{verdict.get('code')}")
    else:
        problems.extend(_phase_prerequisite_problems(staging_root, phase))
    problems.extend(_measurement_setup_problems(phase, port, measurement_setup))

    evidence_id: Optional[str] = None
    evidence_label = None
    evidence_roots: dict = {}
    if not callable(backup_verify):
        problems.append("backup_verify_required")
    else:
        try:
            verdict = backup_verify()
        except Exception:  # noqa: BLE001
            problems.append("backup_verify_failed")
        else:
            if not isinstance(verdict, Mapping) or not verdict.get("ok"):
                problems.append("backup_not_verified")
            else:
                evidence_id = verdict.get("backup_id")
                evidence_label = verdict.get("backup_label")
                roots_raw = verdict.get("roots")
                if (
                    not _is_sha256(evidence_id)
                    or not isinstance(roots_raw, Mapping)
                    or not roots_raw
                ):
                    problems.append("backup_evidence_unbound")
                else:
                    for key, entry in roots_raw.items():
                        digest = (entry or {}).get("files_digest") if isinstance(entry, Mapping) else None
                        evidence_roots[str(key)] = digest
                    if not all(_is_sha256(value) for value in evidence_roots.values()):
                        problems.append("backup_evidence_unbound")
                if backup_id is not None and backup_id not in (evidence_id, evidence_label):
                    problems.append("backup_id_mismatch")
    if problems:
        return {
            "ok": False,
            "code": "session_prepare_refused",
            "session_id": session_id,
            "phase": phase,
            "nonce": None,
            "problems": sorted(set(problems)),
        }
    removed = rotate_probe_files(staging_root)
    removed_attestations = rotate_attestation_files(staging_root)
    restore_mutable_paths(staging_root)
    before = snapshot_live(live)
    before_roots = {
        key: (entry or {}).get("digest") for key, entry in (before.get("roots") or {}).items()
    }
    tie_problems: list = []
    if set(evidence_roots) != set(before_roots):
        tie_problems.append("backup_roots_mismatch")
    else:
        for key, digest in evidence_roots.items():
            if before_roots.get(key) != digest:
                tie_problems.append(f"backup_snapshot_mismatch:{key}")
    if tie_problems:
        return {
            "ok": False,
            "code": "session_prepare_refused",
            "session_id": session_id,
            "phase": phase,
            "nonce": None,
            "problems": sorted(set(tie_problems)),
        }
    session_nonce = secrets.token_hex(16)
    _path, certificate = _load_current(staging_root)
    record = {
        "schema": OPEN_SESSION_SCHEMA,
        "session_id": session_id,
        "phase": phase,
        "nonce": session_nonce,
        "port": int(port) if port is not None else None,
        "certificate_id": (certificate or {}).get("certificate_id"),
        "backup_id": evidence_id,
        "backup_label": evidence_label,
        "backup_roots": evidence_roots,
        "live_roots": _normalize_live(live),
        "before": {"digest": before.get("digest"), "roots": _digest_roots(before)},
        "before_files": before.get("roots"),
        "measurement_setup": dict(measurement_setup) if measurement_setup else None,
        "measurement_setup_by": "launch_practice" if measurement_setup else None,
        "measurement_setup_unix": int(time.time()) if measurement_setup else None,
        "spawn_time": None,
        "pids": {},
        "status": "open",
        "created_unix": int(time.time()),
    }
    path = _write_open_record(staging_root, record)
    return {
        "ok": True,
        "code": "session_prepared",
        "session_id": session_id,
        "phase": phase,
        "nonce": session_nonce,
        "port": port,
        "certificate_id": record["certificate_id"],
        "backup_id": evidence_id,
        "backup_label": evidence_label,
        "open_record": str(path),
        "record": record,
        "removed_probes": removed,
        "removed_attestations": removed_attestations,
        "problems": [],
    }


def _write_session_manifest(staging_root, session_id: str, label: str, payload: Mapping) -> dict:
    staging_root = Path(staging_root).resolve()
    directory = _session_dir(staging_root, session_id)
    body = json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n"
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    target = directory / f"{label}_{digest}.json"
    _safe_write(staging_root, target)
    if target.is_file():
        if target.read_text(encoding="utf-8") != body:
            raise CertificateError("session_evidence_conflict", str(target))
    else:
        _atomic_write_text(target, body)
    return {
        "copy": target.relative_to(staging_root).as_posix(),
        "copy_sha256": staging.sha256_file(target),
        "digest": digest,
    }


def _closure_problems(record: Mapping, session, session_id: str, live_closed) -> list:
    """Fail-closed closure measurement: retained owned handles stopped + live game closed.

    A verdict can never certify a still-running role, nor a concurrent user
    Balatro. Production callers pass the retained ``LaunchSession`` and a real
    live-closed check; fixtures may inject synthized ports. Missing either check is
    a refusal, never an implicit success.
    """
    problems: list = []
    if session is None:
        problems.append("retained_session_required")
    else:
        if getattr(session, "session_id", None) != session_id:
            problems.append("retained_session_mismatch")
        if getattr(session, "nonce", None) != record.get("nonce"):
            problems.append("retained_session_nonce_mismatch")
        try:
            statuses = session.is_running()
        except Exception:  # noqa: BLE001
            problems.append("owned_process_check_unavailable")
        else:
            if not isinstance(statuses, (list, tuple)):
                problems.append("owned_process_check_unavailable")
            elif any(bool((item or {}).get("running")) for item in statuses):
                problems.append("owned_processes_running")
    if not callable(live_closed):
        problems.append("live_closed_check_unavailable")
    else:
        try:
            if not bool(live_closed()):
                problems.append("live_game_running")
        except Exception:  # noqa: BLE001
            problems.append("live_closed_check_failed")
    return problems


def record_session_verdict(
    staging_root,
    *,
    session_id: str,
    live,
    backup_id=None,
    certificate_id=None,
    session=None,
    live_closed=None,
) -> dict:
    """Measure owned-process exit + live-closed, compute the after-snapshot, then close.

    The after-snapshot is measured here, not accepted from the caller. The retained
    ``session`` (with its exact owned handles) must show every owned process
    stopped, and ``live_closed`` must confirm the user's game is not running, or the
    verdict is refused. The root set must match the prepared before-snapshot, the
    digest is recomputed from the file maps, the guarded backup id is required, and
    a session id can only be closed once. Any live byte diff revokes the certificate
    and writes the global lockout.
    """
    staging_root = Path(staging_root).resolve()
    problems: list = []
    if _session_id_problems(session_id):
        return {"ok": False, "code": "session_verdict_invalid", "problems": _session_id_problems(session_id)}
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping):
        return {"ok": False, "code": "open_session_missing", "problems": ["open_session_missing"]}
    if record.get("status") != "open":
        return {"ok": False, "code": "session_already_closed", "problems": ["session_already_closed"]}
    if any(item.get("session_id") == session_id for item in _read_jsonl(staging_root / EVIDENCE_DIR / RECEIPTS_REL)):
        return {"ok": False, "code": "session_id_reused", "problems": ["session_id_reused"]}
    closure = _closure_problems(record, session, session_id, live_closed)
    if closure:
        return {"ok": False, "code": "session_closure_unproven", "problems": sorted(set(closure))}
    after = snapshot_live(live)
    problems.extend(_validate_snapshot(after, "after"))
    if problems:
        return {"ok": False, "code": "session_verdict_invalid", "problems": sorted(set(problems))}
    before = record.get("before") or {}
    before_roots = before.get("roots") or {}
    after_roots = after.get("roots") or {}
    recomputed_before = {
        key: staging._digest_of((entry or {}).get("files") or {})
        for key, entry in (record.get("before_files") or {}).items()
    }
    declared_before = {key: (entry or {}).get("digest") for key, entry in before_roots.items()}
    if not recomputed_before or recomputed_before != declared_before:
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["before_snapshot_unbound"]}
    if sorted(before_roots) != sorted(after_roots):
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["snapshot_root_set_changed"]}
    if after.get("measured_unix", 0) < int(record.get("created_unix") or 0):
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["snapshot_time_order"]}
    expected_backup = record.get("backup_id")
    allowed_backups = {expected_backup, record.get("backup_label")} - {None}
    if not _is_sha256(expected_backup):
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["backup_evidence_missing"]}
    effective_backup = backup_id if backup_id is not None else expected_backup
    if not effective_backup:
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["backup_id_required"]}
    if backup_id is not None and backup_id not in allowed_backups:
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["backup_id_mismatch"]}
    if certificate_id is None:
        certificate_id = record.get("certificate_id")
    changed = [
        key
        for key in sorted(set(before_roots) | set(after_roots))
        if (before_roots.get(key) or {}).get("digest") != (after_roots.get(key) or {}).get("digest")
    ]
    before_manifest = _write_session_manifest(staging_root, session_id, "before", record.get("before_files") or {})
    after_manifest = _write_session_manifest(staging_root, session_id, "after", after.get("roots") or {})
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "session_id": session_id,
        "phase": record.get("phase"),
        "certificate_id": certificate_id,
        "backup_id": effective_backup,
        "before_digest": before.get("digest"),
        "after_digest": after.get("digest"),
        "changed_roots": changed,
        "before_manifest": before_manifest,
        "after_manifest": after_manifest,
        "measured_unix": int(time.time()),
    }
    if changed:
        lock_record = {
            "locked": True,
            "session_id": session_id,
            "reason": "live_byte_diff",
            "changed_roots": changed,
            "before_digest": before.get("digest"),
            "after_digest": after.get("digest"),
            "locked_unix": int(time.time()),
        }
        lock_path = _write_lockout(staging_root, lock_record)
        revoke_certificate(
            staging_root,
            certificate_id=certificate_id,
            reason="live_byte_diff",
            session_id=session_id,
        )
        receipt["verdict"] = "revoked"
        _append_jsonl(staging_root, RECEIPTS_REL, receipt)
        _close_open_record(staging_root, session_id, status="failed", problems=["live_byte_diff"])
        return {
            "ok": False,
            "code": "live_byte_diff_revoked",
            "session_id": session_id,
            "changed_roots": changed,
            "lockout": str(lock_path),
            "receipt": receipt,
            "problems": [],
        }
    receipt["verdict"] = "passed"
    _append_jsonl(staging_root, RECEIPTS_REL, receipt)
    _close_open_record(staging_root, session_id, status="closed", problems=[])
    return {
        "ok": True,
        "code": "session_passed",
        "session_id": session_id,
        "changed_roots": [],
        "receipt": receipt,
        "problems": [],
    }


def record_session_failure(staging_root, *, session_id: str, reason: str) -> dict:
    """Close an open record as failed **and** raise the persistent global lockout.

    A failure/unknown outcome must not permit a later silent rebaseline: the lockout
    stays until an explicit :func:`acknowledge_lockout`, and the closed receipt has
    verdict ``failed`` (never a pass).
    """
    staging_root = Path(staging_root).resolve()
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping) or record.get("status") != "open":
        return {"ok": False, "code": "open_session_missing", "problems": ["open_session_missing"]}
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "session_id": session_id,
        "phase": record.get("phase"),
        "certificate_id": record.get("certificate_id"),
        "backup_id": record.get("backup_id"),
        "verdict": "failed",
        "reason": str(reason),
        "measured_unix": int(time.time()),
    }
    _append_jsonl(staging_root, RECEIPTS_REL, receipt)
    _fail_open_record(staging_root, session_id, [str(reason)], reason="session_failed")
    return {
        "ok": True,
        "code": "session_failed_recorded",
        "session_id": session_id,
        "lockout": True,
        "receipt": receipt,
    }


def record_session_no_spawn(staging_root, *, session_id: str, live, backup_id=None) -> dict:
    """Measured closure of a prepared session that was never spawned.

    Requires the open record to have no bound owned PIDs, then measures the after
    snapshot itself and requires zero live byte diff. This is the only legitimate
    way to abandon a prepared session without retained process handles; a caller
    boolean is never enough. Any live diff raises the global lockout.
    """
    staging_root = Path(staging_root).resolve()
    if _session_id_problems(session_id):
        return {"ok": False, "code": "session_verdict_invalid", "problems": _session_id_problems(session_id)}
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping):
        return {"ok": False, "code": "open_session_missing", "problems": ["open_session_missing"]}
    if record.get("status") != "open":
        return {"ok": False, "code": "session_already_closed", "problems": ["session_already_closed"]}
    if record.get("pids"):
        return {"ok": False, "code": "session_no_spawn_invalid", "problems": ["session_was_spawned"]}
    if any(item.get("session_id") == session_id for item in _read_jsonl(staging_root / EVIDENCE_DIR / RECEIPTS_REL)):
        return {"ok": False, "code": "session_id_reused", "problems": ["session_id_reused"]}
    problems = _validate_snapshot(snapshot_live(live), "after")
    if problems:
        return {"ok": False, "code": "session_verdict_invalid", "problems": sorted(set(problems))}
    after = snapshot_live(live)
    before = record.get("before") or {}
    before_roots = before.get("roots") or {}
    after_roots = after.get("roots") or {}
    recomputed_before = {
        key: staging._digest_of((entry or {}).get("files") or {})
        for key, entry in (record.get("before_files") or {}).items()
    }
    declared_before = {key: (entry or {}).get("digest") for key, entry in before_roots.items()}
    if not recomputed_before or recomputed_before != declared_before:
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["before_snapshot_unbound"]}
    if sorted(before_roots) != sorted(after_roots):
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["snapshot_root_set_changed"]}
    effective_backup = backup_id if backup_id is not None else record.get("backup_id")
    if not effective_backup:
        return {"ok": False, "code": "session_verdict_invalid", "problems": ["backup_id_required"]}
    changed = [
        key
        for key in sorted(set(before_roots) | set(after_roots))
        if (before_roots.get(key) or {}).get("digest") != (after_roots.get(key) or {}).get("digest")
    ]
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "session_id": session_id,
        "phase": record.get("phase"),
        "certificate_id": record.get("certificate_id"),
        "backup_id": effective_backup,
        "before_digest": before.get("digest"),
        "after_digest": after.get("digest"),
        "changed_roots": changed,
        "measured_unix": int(time.time()),
    }
    if changed:
        lock_path = _write_lockout(
            staging_root,
            {
                "locked": True,
                "session_id": session_id,
                "reason": "live_byte_diff_no_spawn",
                "changed_roots": changed,
                "locked_unix": int(time.time()),
            },
        )
        receipt["verdict"] = "revoked"
        _append_jsonl(staging_root, RECEIPTS_REL, receipt)
        _close_open_record(staging_root, session_id, status="failed", problems=["live_byte_diff"])
        return {
            "ok": False,
            "code": "live_byte_diff_revoked",
            "session_id": session_id,
            "changed_roots": changed,
            "lockout": str(lock_path),
            "receipt": receipt,
            "problems": [],
        }
    receipt["verdict"] = "no_spawn"
    _append_jsonl(staging_root, RECEIPTS_REL, receipt)
    _close_open_record(staging_root, session_id, status="closed", problems=[])
    return {
        "ok": True,
        "code": "session_no_spawn_closed",
        "session_id": session_id,
        "receipt": receipt,
        "problems": [],
    }


# ---------------------------------------------------------------------------
# Launcher attestation (strict, derived, atomic)
# ---------------------------------------------------------------------------

def write_launcher_attestation(
    staging_root,
    *,
    session_id: str,
    nonce: str,
    control_port: int,
    port: int,
    spawn_time=None,
    live=None,
) -> dict:
    """Write the fixed session-bound attestation outside Mods, only after both probes.

    Every input is required and re-derived: the open session record is bound by
    session id/nonce, the certificate must be current, the content hash is derived
    from the certificate mods layer, the control/match ports are range-checked, the
    exact owned PIDs must already be recorded, and both roles' fresh probes are
    re-verified. Each file is written atomically to its fixed path.
    """
    staging_root = Path(staging_root).resolve()
    problems: list = []
    problems.extend(_session_id_problems(session_id))
    if not isinstance(nonce, str) or not nonce:
        problems.append("bad_nonce")
    if not _is_port(control_port):
        problems.append("bad_control_port")
    if not _is_port(port):
        problems.append("bad_match_port")
    record = _receipt_open_record(staging_root, session_id)
    if not isinstance(record, Mapping) or record.get("status") != "open":
        problems.append("open_session_missing")
    else:
        if record.get("nonce") != nonce:
            problems.append("open_session_nonce_mismatch")
        if not record.get("pids"):
            problems.append("open_session_pids_missing")
        if record.get("phase") != MATCH:
            problems.append("attestation_phase_not_match")
    if spawn_time is None and isinstance(record, Mapping):
        spawn_time = record.get("spawn_time")
    if not _is_number(spawn_time):
        problems.append("bad_spawn_time")
    if problems:
        return {"ok": False, "code": "attestation_refused", "problems": sorted(set(problems))}

    verdict = check_certificate(staging_root, live=live, port=port)
    if not verdict.get("ok"):
        return {
            "ok": False,
            "code": "attestation_refused",
            "problems": [f"certificate_not_valid:{verdict.get('code')}"],
        }
    if record.get("certificate_id") != verdict.get("certificate_id"):
        return {"ok": False, "code": "attestation_refused", "problems": ["attestation_certificate_mismatch"]}
    content_hash = next(
        (
            entry.get("role_parity_digest")
            for entry in ((certificate_or_empty(staging_root, "mods_layer", "roles")).values())
        ),
        None,
    )
    if not _is_sha256(content_hash):
        return {"ok": False, "code": "attestation_refused", "problems": ["content_hash_unavailable"]}

    probe_problems: list = []
    for role in staging.ROLES:
        paths = staging.role_paths(staging_root, role)
        role_verdict = staging.collect_role_probes(
            paths, nonce, spawn_time, require_mp=True, expected_port=port
        )
        probe_problems.extend(f"{role}:{item}" for item in role_verdict.get("problems", ()))
    if probe_problems:
        return {"ok": False, "code": "attestation_refused", "problems": sorted(set(probe_problems))}

    written: dict = {}
    for role in staging.ROLES:
        paths = staging.role_paths(staging_root, role)
        save_dir = paths.data / "Balatro"
        probe_hashes = {
            name: staging.sha256_file(save_dir / name)
            for name in ALL_PROBE_NAMES
            if (save_dir / name).is_file()
        }
        payload = {
            "schema": staging.LAUNCHER_ATTESTATION_SCHEMA,
            "ok": True,
            "session": session_id,
            "role": role,
            "nonce": nonce,
            "content_hash": content_hash,
            "control_port": int(control_port),
            "match_port": int(port),
            "expected_role_save_root": str(save_dir),
            "expected_role_mods_root": str(paths.mods),
            "probe_sha256": probe_hashes,
            "written_unix": int(time.time()),
        }
        target = staging.launcher_attestation_path(paths)
        staging.assert_safe_write(staging_root, target, "launcher attestation")
        _atomic_write_text(target, json.dumps(payload, indent=2, sort_keys=True) + "\n")
        written[role] = str(target)
    return {"ok": True, "code": "attestation_written", "attestations": written, "problems": []}


def certificate_or_empty(staging_root, *keys) -> dict:
    _path, certificate = _load_current(staging_root)
    node = certificate or {}
    for key in keys:
        node = (node or {}).get(key) or {}
    return node
