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
from typing import Optional

TOOLS_DIR = Path(__file__).resolve().parent
import sys

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import practice_service  # noqa: E402
import staging  # noqa: E402

RULESET_REL_PATH = ("rulesets", "majorleague.lua")
RULESET_ID_PREFIX = "ruleset_mp_"
EXPECTED_GAMEMODE = "gamemode_mp_attrition"

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


__all__ = [
    "EXPECTED_GAMEMODE",
    "RULESET_ID_PREFIX",
    "RULESET_REL_PATH",
    "expected_config_digest",
    "expected_ruleset",
    "majorleague_source_path",
    "parse_ruleset_source",
]
