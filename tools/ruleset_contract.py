#!/usr/bin/env python3
"""Strict Major League ruleset derivation for the practice host.

The host must pin the *expected* Major League configuration before it can attest a
service or start a match (``docs/MAJOR_LEAGUE_DIGEST.md``). The trusted source is
the pinned staged Multiplayer mod's ``rulesets/majorleague.lua``; nothing is
hardcoded here and no value is accepted from a menu request.

This module parses only the pinned primitive assignment shape in the
``force_lobby_options`` body and rejects any other statement, then derives the
registry ruleset id, the forced gamemode and the forced-option key set. The digest
itself is the shared ``practice_service.major_league_digest`` implementation, so
the host and service cannot drift.

Importing this module performs no I/O and no work.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Mapping, Optional

TOOLS_DIR = Path(__file__).resolve().parent
import sys

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import practice_service  # noqa: E402
import ranked_effective_config  # noqa: E402
import staging  # noqa: E402

RULESET_REL_PATH = ("rulesets", "majorleague.lua")
RULESET_ID_PREFIX = "ruleset_mp_"
EXPECTED_GAMEMODE = "gamemode_mp_attrition"

# Standard Ranked (production practice default). The authority is the pinned
# Multiplayer source generation verified by ``docs/RANKED_SOURCE_PINS_V1.json``.
RANKED_PINS_REL = ("docs", "RANKED_SOURCE_PINS_V1.json")

# Strict, source-bound measured-catalog schema. The eligible deck count is a real
# runtime fact (``MP.get_cocktail_decks`` against the live ``G.P_CENTERS`` and the
# blacklist/whitelist), not a source constant, so it is reported by a trusted
# runtime attestation. A missing/unverified catalog fails closed; a synthetic
# count is never accepted in production.
RANKED_CATALOG_SCHEMA = "aisparring.ranked_catalog.v1"
_MAX_CATALOG_ENTRIES = 64

# ``MP.LOBBY.config.key = <primitive>`` where the primitive is a Lua boolean,
# integer or single-quoted/double-quoted string. No expressions, calls or field
# reads are permitted.
_ASSIGN_RE = re.compile(
    r"^MP\.LOBBY\.config\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(true|false|-?[0-9]+|\"[^\"]*\"|'[^']*')$"
)
_RETURN_RE = re.compile(r"^return\s+(true|false)$")
_KEY_RE = re.compile(r"(?<![A-Za-z0-9_])key\s*=\s*\"([^\"]+)\"")
_GAMEMODE_RE = re.compile(r"forced_gamemode\s*=\s*\"([^\"]+)\"")
_BODY_MARKER = "force_lobby_options = function"
_INT32_MIN = -2147483648
_INT32_MAX = 2147483647


def _unquote(token: str) -> str:
    return token[1:-1]


def _primitive(token: str):
    """Convert one Lua primitive literal to its typed Python value."""
    if token in ("true", "false"):
        return token == "true"
    if token[0] in ("\"", "'"):
        return _unquote(token)
    return int(token)


def _extract_body(source: str) -> Optional[list]:
    """Return the stripped lines of the ``force_lobby_options`` body, or ``None``."""
    lines = source.splitlines()
    start = None
    for index, line in enumerate(lines):
        if _BODY_MARKER in line:
            start = index + 1
            break
    if start is None:
        return None
    body: list = []
    for line in lines[start:]:
        stripped = line.strip()
        if stripped in ("end", "end,"):
            return body
        body.append(stripped)
    return None


def parse_ruleset_source(source: str) -> dict:
    """Strictly parse the pinned ``majorleague.lua`` source shape.

    Only blank lines, ``MP.LOBBY.config.key = primitive`` assignments and one
    trailing ``return true|false`` are accepted in the ``force_lobby_options``
    body. Anything else (calls, field reads, comments, nested statements) is an
    ``unsupported_statement`` problem, so a mutated ruleset is refused rather than
    silently approximated.
    """
    problems: list = []
    if not isinstance(source, str) or not source.strip():
        return {"ok": False, "problems": ["ruleset_source_empty"]}

    key_match = _KEY_RE.search(source)
    gamemode_match = _GAMEMODE_RE.search(source)
    if key_match is None:
        problems.append("ruleset_key_missing")
    if gamemode_match is None:
        problems.append("forced_gamemode_missing")

    options: dict = {}
    body = _extract_body(source)
    if body is None:
        problems.append("force_lobby_options_body_missing")
    else:
        returned = False
        for stripped in body:
            if not stripped:
                continue
            if _RETURN_RE.fullmatch(stripped):
                if returned:
                    problems.append("duplicate_return")
                returned = True
                continue
            match = _ASSIGN_RE.fullmatch(stripped)
            if match is None:
                problems.append("unsupported_statement")
                continue
            name, token = match.group(1), match.group(2)
            if name in options:
                problems.append("duplicate_option")
                continue
            value = _primitive(token)
            if isinstance(value, int) and not isinstance(value, bool):
                if value < _INT32_MIN or value > _INT32_MAX:
                    problems.append("option_out_of_range")
                    continue
            options[name] = value

    if not options:
        problems.append("force_lobby_options_empty")

    ruleset_id = None
    gamemode = None
    if key_match is not None:
        ruleset_id = RULESET_ID_PREFIX + key_match.group(1)
        if ruleset_id != practice_service.MAJOR_LEAGUE_RULESET_ID:
            problems.append("ruleset_id_unexpected")
    if gamemode_match is not None:
        gamemode = gamemode_match.group(1)
        if gamemode != EXPECTED_GAMEMODE:
            problems.append("forced_gamemode_unexpected")

    problems = sorted(set(problems))
    return {
        "ok": not problems,
        "problems": problems,
        "ruleset_id": ruleset_id,
        "gamemode": gamemode,
        "forced_options": options,
        "key_set": tuple(sorted(options, key=lambda item: item.encode("utf-8"))),
    }


def majorleague_source_path(staging_root, role: str = "human", mod_dir=None) -> Path:
    """Resolve the pinned staged ``rulesets/majorleague.lua`` for one role."""
    paths = staging.role_paths(staging_root, role)
    resolved_mod = staging._resolve_multiplayer_mod(paths, mod_dir=mod_dir)
    return Path(resolved_mod).joinpath(*RULESET_REL_PATH)


def expected_ruleset(staging_root, role: str = "human", mod_dir=None) -> dict:
    """Derive the expected Major League configuration from the staged ruleset.

    Returns a bounded result with ``ruleset_id``, ``gamemode``, the forced option
    mapping, its bytewise-ascending key set and the shared FNV1a-32
    ``config_digest``. Any unreadable, mutated or unsupported source fails closed
    with ``problems``; no caller-supplied ruleset value is ever trusted.
    """
    try:
        source_path = majorleague_source_path(staging_root, role=role, mod_dir=mod_dir)
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "problems": [error.code]}
    try:
        source = source_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {"ok": False, "code": "ruleset_source_unreadable", "problems": ["ruleset_source_unreadable"]}

    parsed = parse_ruleset_source(source)
    if not parsed.get("ok"):
        return {
            "ok": False,
            "code": "ruleset_contract_unproven",
            "problems": list(parsed.get("problems") or ()),
            "ruleset_id": parsed.get("ruleset_id"),
            "gamemode": parsed.get("gamemode"),
        }

    forced = dict(parsed["forced_options"])
    key_set = tuple(sorted(forced.keys(), key=lambda item: item.encode("utf-8")))
    try:
        digest = practice_service.major_league_digest(parsed["ruleset_id"], parsed["gamemode"], forced)
    except practice_service.PracticeError:
        return {"ok": False, "code": "ruleset_digest_invalid", "problems": ["ruleset_digest_invalid"]}
    return {
        "ok": True,
        "code": "ruleset_contract_ok",
        "source": str(source_path),
        "ruleset_id": parsed["ruleset_id"],
        "gamemode": parsed["gamemode"],
        "forced_options": forced,
        "key_set": key_set,
        "config_digest": digest,
        "problems": [],
    }


def expected_config_digest(staging_root, role: str = "human", mod_dir=None) -> Optional[str]:
    verdict = expected_ruleset(staging_root, role=role, mod_dir=mod_dir)
    return verdict.get("config_digest") if verdict.get("ok") else None


def ranked_source_path(staging_root, role: str = "human", mod_dir=None) -> Path:
    """Resolve the pinned staged Multiplayer mod dir for the Ranked authority."""
    paths = staging.role_paths(staging_root, role)
    return Path(staging._resolve_multiplayer_mod(paths, mod_dir=mod_dir))


def ranked_pins_path() -> Path:
    """The production pin file, anchored to the loaded authority module."""
    return ranked_effective_config.production_pins_path()


def expected_ranked_config(
    staging_root,
    role: str = "human",
    mod_dir=None,
    cocktail=None,
    guest_cocktail=None,
    pins_path=None,
    selection=None,
    catalog=None,
    custom_seed=None,
    draft=None,
) -> dict:
    """Derive the expected Standard Ranked configuration from the staged source.

    Verifies every enumerated Multiplayer file's SHA-256 against the reviewed
    pins before deriving values, so any byte drift fails closed. ``pins_path``
    defaults to the anchored production pin file; a test/helper may pass an
    explicit fixture pin path, but there is no repo-root or re-record override.
    The returned ``config_digest`` is the new domain-separated
    ``aisparring.ranked_effective_config.v1`` equality checksum; it never reuses
    ``major_league_digest``.
    """
    try:
        source_dir = ranked_source_path(staging_root, role=role, mod_dir=mod_dir)
    except staging.StagingError as error:
        return {"ok": False, "code": error.code, "problems": [error.code]}
    if pins_path is None:
        pins_path = ranked_pins_path()
    verdict = ranked_effective_config.derive_effective_config(
        source_dir,
        pins_path,
        cocktail=cocktail,
        guest_cocktail=guest_cocktail,
        selection=selection,
        catalog=catalog,
        custom_seed=custom_seed,
    )
    if not verdict.get("ok"):
        return {
            "ok": False,
            "code": "ranked_contract_unproven",
            "problems": list(verdict.get("problems") or ()),
        }
    resolved = verdict["resolved"]
    result = {
        "ok": True,
        "code": "ranked_contract_ok",
        "source": str(source_dir),
        "ruleset_id": resolved["ruleset_id"],
        "ruleset_key": resolved["ruleset_key"],
        "gamemode": resolved["forced_gamemode"],
        "declared_layers": resolved["declared_layers"],
        "active_layer_chain": resolved["active_layer_chain"],
        "config_digest": verdict["checksum"],
        "canonical": verdict["canonical"],
        "host": verdict["host"],
        "guest": verdict["guest"],
        "resolved": resolved,
        "problems": [],
    }
    # The dedicated draft commitment is validated independently and carried
    # separately from the canonical lobby configuration. A transcript/selection
    # disagreement fails the whole derivation.
    if draft is not None:
        import ranked_draft as ranked_draft_authority

        commitment = ranked_draft_authority.commitment_from_public(draft)
        if not commitment.get("ok"):
            return {
                "ok": False,
                "code": "ranked_draft_commitment_invalid",
                "problems": list(commitment.get("problems") or ()),
            }
        if selection is not None and draft.get("final") != selection_option(selection, catalog):
            return {
                "ok": False,
                "code": "ranked_draft_selection_mismatch",
                "problems": ["ranked_draft_selection_mismatch"],
            }
        result["draft"] = dict(draft)
        result["draft_digest"] = commitment["digest"]
    return result


def selection_option(selection, catalog):
    """Map a validated selection back to its option id, or ``None``."""
    if not isinstance(selection, Mapping) or not isinstance(catalog, Mapping):
        return None
    decks = catalog.get("decks")
    stakes = catalog.get("stakes")
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping):
        return None
    deck_key = selection.get("deck_key")
    stake_key = selection.get("stake_key")
    entry = decks.get(deck_key) if isinstance(deck_key, str) else None
    if not isinstance(entry, Mapping):
        return None
    if entry.get("center_key") != selection.get("back_key") or entry.get("name") != selection.get("back_name"):
        return None
    if stake_key not in stakes:
        return None
    return deck_key + "~" + stake_key


def expected_ranked_checksum(staging_root, role: str = "human", **kwargs) -> Optional[str]:
    verdict = expected_ranked_config(staging_root, role=role, **kwargs)
    return verdict.get("config_digest") if verdict.get("ok") else None


# The Cocktail Back center is the boot-generated composition container; it is
# never a selectable draft deck and must be absent from both measured catalogs.
COCKTAIL_BACK_KEY = "b_mp_cocktail"


def _validate_catalog_shape(measurement, problems: list) -> None:
    eligible = measurement.get("eligible_decks")
    decks = measurement.get("decks")
    stakes = measurement.get("stakes")
    if not isinstance(eligible, (list, tuple)) or not eligible:
        problems.append("ranked_catalog_eligible_missing")
        return
    if len(eligible) > _MAX_CATALOG_ENTRIES:
        problems.append("ranked_catalog_too_large")
        return
    seen = set()
    for key in eligible:
        if not isinstance(key, str) or not (1 <= len(key) <= 64):
            problems.append("ranked_catalog_eligible_invalid")
            continue
        if key in seen:
            problems.append("ranked_catalog_eligible_duplicate")
        seen.add(key)
        if key == COCKTAIL_BACK_KEY:
            problems.append("ranked_catalog_cocktail_present")
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping):
        problems.append("ranked_catalog_mapping_missing")
        return
    if COCKTAIL_BACK_KEY in decks:
        problems.append("ranked_catalog_cocktail_present")
    for key, entry in decks.items():
        if not isinstance(key, str) or not isinstance(entry, Mapping):
            problems.append("ranked_catalog_deck_invalid")
            continue
        if not isinstance(entry.get("center_key"), str) or not isinstance(entry.get("name"), str):
            problems.append("ranked_catalog_deck_invalid")
        if entry.get("center_key") == COCKTAIL_BACK_KEY:
            problems.append("ranked_catalog_cocktail_present")
    for key, entry in stakes.items():
        if not isinstance(key, str) or not isinstance(entry, Mapping):
            problems.append("ranked_catalog_stake_invalid")
            continue
        index = entry.get("index")
        max_index = entry.get("max_index", ranked_effective_config.MAX_STAKE_INDEX)
        if isinstance(index, bool) or not isinstance(index, int):
            problems.append("ranked_catalog_stake_invalid")
        if isinstance(max_index, bool) or not isinstance(max_index, int) or max_index > ranked_effective_config.MAX_STAKE_INDEX:
            problems.append("ranked_catalog_stake_invalid")


def build_ranked_catalog(host_measurement, guest_measurement=None) -> dict:
    """Validate the *shape* of a measured catalog and derive the Cocktail default.

    This is a strict shape validator, NOT provenance: the measured catalogs are
    produced by the real runtime (eligible Back centers from
    ``MP.get_cocktail_decks``) and their authenticity is a future deployment
    dependency. Both role measurements are required and must be equal; eligible
    decks must be unique, Cocktail must be absent, and no count is guessed.
    Returns ``{"ok", "cocktail", "decks", "stakes", "count"}`` or a failure.
    """
    problems: list[str] = []
    if not isinstance(host_measurement, Mapping) or host_measurement.get("schema") != RANKED_CATALOG_SCHEMA:
        return {"ok": False, "problems": ["ranked_catalog_schema_invalid"]}
    if guest_measurement is None:
        # Both measured role catalogs are mandatory; a single-role measurement
        # is never accepted.
        return {"ok": False, "problems": ["ranked_catalog_guest_missing"]}
    if not isinstance(guest_measurement, Mapping) or guest_measurement.get("schema") != RANKED_CATALOG_SCHEMA:
        return {"ok": False, "problems": ["ranked_catalog_guest_schema_invalid"]}
    _validate_catalog_shape(host_measurement, problems)
    _validate_catalog_shape(guest_measurement, problems)
    if (
        list(host_measurement.get("eligible_decks") or ()) != list(guest_measurement.get("eligible_decks") or ())
        or dict(host_measurement.get("decks") or {}) != dict(guest_measurement.get("decks") or {})
        or dict(host_measurement.get("stakes") or {}) != dict(guest_measurement.get("stakes") or {})
    ):
        problems.append("ranked_catalog_role_parity")
    problems = sorted(set(problems))
    if problems:
        return {"ok": False, "problems": problems}
    eligible = host_measurement["eligible_decks"]
    try:
        cocktail = ranked_effective_config.expected_cocktail_for_count(len(eligible))
    except ranked_effective_config.RankedConfigError as error:
        return {"ok": False, "problems": [error.code]}
    return {
        "ok": True,
        "problems": [],
        "cocktail": cocktail,
        "decks": dict(host_measurement["decks"]),
        "stakes": dict(host_measurement["stakes"]),
        "count": len(eligible),
    }


def production_ranked_reader(catalog=None, guest_catalog=None, selection=None, custom_seed=None, draft=None):
    """Build the production Standard Ranked reader for the host.

    The reader verifies the pinned staged source and derives every value from it.
    The measured catalogs (and therefore the exact Cocktail default) must be
    supplied by the trusted deployment slice; until then the reader fails closed
    with ``ranked_catalog_unmeasured``. A missing validated draft selection fails
    closed with ``ranked_draft_unbound`` (never a Red Deck / White Stake
    fallback). ``custom_seed`` is the trusted host gauntlet seed only.
    """

    def reader(staging_root, role: str = "human"):
        if catalog is None:
            return {
                "ok": False,
                "code": "ranked_catalog_unmeasured",
                "problems": ["ranked_catalog_unmeasured"],
            }
        built = build_ranked_catalog(catalog, guest_measurement=guest_catalog)
        if not built.get("ok"):
            return {
                "ok": False,
                "code": "ranked_catalog_invalid",
                "problems": list(built.get("problems") or ()),
            }
        # The Ranked schema requires BOTH the host-owned validated selection and
        # the completed draft commitment: a selection-only launch is refused (no
        # Red Deck / White Stake fallback).
        if selection is None or draft is None:
            return {
                "ok": False,
                "code": "ranked_draft_unbound",
                "problems": ["ranked_draft_unbound"],
            }
        # The production pin path is anchored to the loaded authority module;
        # there is no repo-root or caller pin override here.
        verdict = expected_ranked_config(
            staging_root,
            role=role,
            cocktail=built["cocktail"],
            pins_path=ranked_effective_config.production_pins_path(),
            selection=selection,
            catalog={"decks": built["decks"], "stakes": built["stakes"]},
            custom_seed=custom_seed,
            draft=draft,
        )
        if not verdict.get("ok"):
            return verdict
        verdict = dict(verdict)
        verdict["config_schema"] = ranked_effective_config.RANKED_CONFIG_SCHEMA
        verdict["catalog"] = {
            "decks": built["decks"],
            "stakes": built["stakes"],
            "count": built["count"],
        }
        # Carry the validated selection so the service can re-validate it and
        # send it in SETUP (exact keys/types).
        verdict["selection"] = dict(selection)
        return verdict

    # Tag the reader so the host can identify the trusted Standard Ranked
    # authority (used to refuse an unsupported Ranked gauntlet pre-ACK).
    reader.is_ranked = True
    return reader


__all__ = [
    "EXPECTED_GAMEMODE",
    "RANKED_CATALOG_SCHEMA",
    "RANKED_PINS_REL",
    "RULESET_ID_PREFIX",
    "RULESET_REL_PATH",
    "build_ranked_catalog",
    "expected_config_digest",
    "expected_ranked_checksum",
    "expected_ranked_config",
    "expected_ruleset",
    "majorleague_source_path",
    "parse_ruleset_source",
    "production_ranked_reader",
    "ranked_pins_path",
    "ranked_source_path",
]
