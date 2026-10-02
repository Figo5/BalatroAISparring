#!/usr/bin/env python3
"""Source-pinned Ranked effective-configuration authority.

Architecture specification: ``docs/RANKED_EFFECTIVE_CONFIG_V1.md``. This module
derives the *expected* Standard Ranked Multiplayer lobby configuration from the
actual pinned Multiplayer source and exposes a domain-separated canonical binding
with an FNV1a-32 equality checksum.

Scope and honesty:

* Nothing is hardcoded. Every expected value is parsed from the SHA-256-pinned
  source files enumerated in ``docs/RANKED_SOURCE_PINS_V1.json``; a byte change
  fails closed (``ranked_source_pin_drift``) rather than being approximated.
* The checksum is an *equality* primitive only, matching ``Codec.hash_string``.
  It is not authentication; the authenticated control channel and the immutable
  source/native certificate remain the authority.
* This module performs no I/O at import. ``verify_source_pins`` and
  ``derive_effective_config`` read files explicitly.
* The pinned source is the reviewed Multiplayer generation (expected under
  ``work/reference/certified-mods/Multiplayer`` for tests and under the staged
  role's Mods tree in production). It is evidence and is never modified.

Importing this module performs no I/O and no work.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Mapping, Optional

DOMAIN = "aisparring.ranked_effective_config.v1"
# The explicit versioned contract tag carried through Setup/Ready/Start. It is the
# canonical domain; legacy fixtures/history keep their own semantics and are never
# silently relabelled with this value.
RANKED_CONFIG_SCHEMA = DOMAIN
PIN_SCHEMA = "aisparring.ranked_source_pins.v1"

RULESET_KEY = "standard_ranked"
RULESET_ID = "ruleset_mp_standard_ranked"
FORCED_GAMEMODE = "gamemode_mp_attrition"
DECLARED_LAYERS = ("standard", "ranked", "pvp_timer")
ACTIVE_LAYER_CHAIN = ("standard", "ranked", "pvp_timer", "standard_ranked")

RULESET_REL = "rulesets/ranked.lua"
LAYER_STANDARD_REL = "layers/standard.lua"
LAYER_RANKED_REL = "layers/ranked.lua"
LAYER_PVP_TIMER_REL = "layers/pvp_timer.lua"
CORE_REL = "core.lua"
START_LOBBY_REL = "ui/main_menu/play_button/play_button_callbacks.lua"

# Resolved PvP timer layer scalars and the ordinary default timer.
PVP_TIMER_BASE_SECONDS = 60
PVP_TIMER_HAND_INCREMENT_SECONDS = 10
ORDINARY_TIMER_BASE_SECONDS = 150
TIMER_BASE_MULTIPLIER = 1

FNV1A32_OFFSET = 2166136261
FNV1A32_PRIME = 16777619
MAX_CANONICAL_BYTES = 262144
MAX_STRING = 64
INT32_MIN = -2147483648
INT32_MAX = 2147483647

# The reviewed primitive lobby defaults parsed out of ``MP.reset_lobby_config``.
# ``ruleset``/``gamemode`` are expressions there (overridden by ruleset selection)
# and are deliberately excluded; every other key must be a strict primitive and
# must be one of the enumerated keys, otherwise the source fails closed.
_DEFAULTS_EXPRESSION_KEYS = frozenset({"ruleset", "gamemode"})

KNOWN_DEFAULT_KEYS = frozenset(
    {
        "gold_on_life_loss",
        "no_gold_on_round_loss",
        "death_on_round_loss",
        "different_seeds",
        "the_order",
        "starting_lives",
        "pvp_start_round",
        "timer_base_seconds",
        "timer_increment_seconds",
        "pvp_countdown_seconds",
        "showdown_starting_antes",
        "weekly",
        "custom_seed",
        "different_decks",
        "random_loadout",
        "back",
        "sleeve",
        "stake",
        "challenge",
        "cocktail",
        "multiplayer_jokers",
        "timer",
        "timer_forgiveness",
        "forced_config",
        "preview_disabled",
        "legacy_smallworld",
        "hide_score_until_played",
        "enemy_location_disabled",
        "timer_display_threshold",
    }
)

KNOWN_LAYER_KEYS = {
    "standard": frozenset(
        {
            "multiplayer_content",
            "standard",
            "banned_silent",
            "banned_jokers",
            "banned_consumables",
            "reworked_jokers",
            "reworked_consumables",
            "reworked_enhancements",
        }
    ),
    "ranked": frozenset({"forced_lobby_options", "is_disabled", "force_lobby_options"}),
    "pvp_timer": frozenset({"pvp_timer_base_seconds", "pvp_timer_hand_played_increment_seconds"}),
}

# Typed default expected values for keys the doc marks as "no lobby override"
# (typed nil). Any non-nil value is an injected override and must fail closed.
NIL_OVERRIDE_KEYS = (
    "pvp_timer_base_seconds",
    "pvp_timer_hand_played_increment_seconds",
    "normal_bosses",
    "timer_hand_played_increment_seconds",
    "timer_base_multiplier",
    "preview_calculate_delay",
    "preview_calculate_cost",
)


class RankedConfigError(Exception):
    """Bounded, non-leaking authority failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


# ---------------------------------------------------------------------------
# Strict Lua literal parsing
# ---------------------------------------------------------------------------
# We accept only the reviewed primitive/table shapes: string, integer, boolean,
# table literals and `function` bodies (represented as a sentinel). Every other
# token (calls, field reads, operators, concatenation, comments) is rejected, so
# a mutated source fails closed instead of being silently approximated.

class _Function:
    """Sentinel for a `function(...) ... end` value (never called here)."""

    __slots__ = ()


FUNCTION = _Function()


def _strip_comments(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "-" and i + 1 < n and text[i + 1] == "-":
            j = i + 2
            if j < n and text[j] == "[":
                k = j + 1
                level = 0
                while k < n and text[k] == "=":
                    level += 1
                    k += 1
                if k < n and text[k] == "[":
                    close = "]" + "=" * level + "]"
                    end = text.find(close, k + 1)
                    i = n if end == -1 else end + len(close)
                    continue
            end = text.find("\n", i)
            i = n if end == -1 else end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _tokenize(text: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        if ch == '"' or ch == "'":
            j = i + 1
            buf: list[str] = []
            while j < n and text[j] != ch:
                if text[j] == "\\":
                    # Backslash is unsupported in the pinned literals; reject.
                    raise RankedConfigError("ranked_source_unsupported_syntax")
                buf.append(text[j])
                j += 1
            if j >= n:
                raise RankedConfigError("ranked_source_unsupported_syntax")
            tokens.append(("string", "".join(buf)))
            i = j + 1
            continue
        if ch.isdigit() or (ch == "-" and i + 1 < n and text[i + 1].isdigit()):
            j = i + 1
            while j < n and (text[j].isdigit() or text[j] == "."):
                j += 1
            tokens.append(("number", text[i:j]))
            i = j
            continue
        if ch.isalpha() or ch == "_":
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            tokens.append(("name", text[i:j]))
            i = j
            continue
        if ch in "{}[]=,;.()":
            tokens.append((ch, ch))
            i += 1
            continue
        raise RankedConfigError("ranked_source_unsupported_syntax")
    return tokens


class _Parser:
    def __init__(self, tokens: list[tuple[str, str]]) -> None:
        self.tokens = tokens
        self.pos = 0

    def peek(self) -> Optional[tuple[str, str]]:
        if self.pos >= len(self.tokens):
            return None
        return self.tokens[self.pos]

    def next(self) -> tuple[str, str]:
        token = self.peek()
        if token is None:
            raise RankedConfigError("ranked_source_unsupported_syntax")
        self.pos += 1
        return token

    def value(self):
        kind, text = self.next()
        if kind == "string":
            return text
        if kind == "number":
            if "." in text:
                raise RankedConfigError("ranked_source_unsupported_syntax")
            value = int(text)
            if value < INT32_MIN or value > INT32_MAX:
                raise RankedConfigError("ranked_source_unsupported_syntax")
            return value
        if kind == "name":
            if text == "true":
                return True
            if text == "false":
                return False
            if text == "nil":
                return None
            if text == "function":
                self._skip_function()
                return FUNCTION
            raise RankedConfigError("ranked_source_unsupported_syntax")
        if kind == "{":
            return self.table()
        raise RankedConfigError("ranked_source_unsupported_syntax")

    def _skip_function(self):
        # function(params) ... end ; we never interpret the body, only verify it.
        _skip_function_tokens(self)

    def table(self) -> dict:
        result: dict = {}
        array: list = []
        while True:
            token = self.peek()
            if token is None:
                raise RankedConfigError("ranked_source_unsupported_syntax")
            kind, text = token
            if kind == "}":
                self.next()
                break
            if kind in (",", ";"):
                self.next()
                continue
            if kind == "name" and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1][0] == "=":
                self.next()
                self.next()  # '='
                value = self.value()
                if text in result:
                    raise RankedConfigError("ranked_source_duplicate_key")
                result[text] = value
                continue
            # Array element.
            array.append(self.value())
        if array and result:
            raise RankedConfigError("ranked_source_unsupported_syntax")
        if array:
            result["__array__"] = array
        return result


def parse_literal(text: str):
    parser = _Parser(_tokenize(_strip_comments(text)))
    value = parser.value()
    if parser.peek() is not None:
        raise RankedConfigError("ranked_source_unsupported_syntax")
    return value


def _extract_call_argument(source: str, call_head: str) -> str:
    """Return the text of the first ``{ ... }`` argument to ``call_head``."""
    start = source.find(call_head)
    if start == -1:
        raise RankedConfigError("ranked_source_shape_missing")
    brace = source.find("{", start)
    if brace == -1:
        raise RankedConfigError("ranked_source_shape_missing")
    depth = 0
    i = brace
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == '"' or ch == "'":
            quote = ch
            i += 1
            while i < n and source[i] != quote:
                i += 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[brace : i + 1]
        i += 1
    raise RankedConfigError("ranked_source_shape_missing")


def _extract_assignment_table(source: str, marker: str) -> str:
    start = source.find(marker)
    if start == -1:
        raise RankedConfigError("ranked_source_shape_missing")
    brace = source.find("{", start + len(marker))
    if brace == -1:
        raise RankedConfigError("ranked_source_shape_missing")
    depth = 0
    i = brace
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == '"' or ch == "'":
            quote = ch
            i += 1
            while i < n and source[i] != quote:
                i += 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[brace : i + 1]
        i += 1
    raise RankedConfigError("ranked_source_shape_missing")


# ---------------------------------------------------------------------------
# Pinned-source verification
# ---------------------------------------------------------------------------

def verify_source_pins(mod_root, pins: Mapping) -> dict:
    """Verify every enumerated authoritative file's SHA-256.

    ``mod_root`` is the Multiplayer mod directory; the pin keys are relative to
    it. Returns ``{"ok", "problems", "verified", "total"}``; any missing file or
    byte drift fails closed with ``ranked_source_pin_drift``.
    """
    files = pins.get("authoritative_files")
    if not isinstance(files, Mapping) or not files:
        return {"ok": False, "problems": ["ranked_source_pins_invalid"], "verified": 0, "total": 0}
    root = Path(mod_root)
    problems: list[str] = []
    verified = 0
    for rel, want in files.items():
        if not isinstance(rel, str) or not isinstance(want, str):
            problems.append("ranked_source_pins_invalid")
            continue
        path = root / rel
        try:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            problems.append("ranked_source_missing:" + rel)
            continue
        if digest != want:
            problems.append("ranked_source_pin_drift:" + rel)
        else:
            verified += 1
    return {
        "ok": not problems,
        "problems": problems,
        "verified": verified,
        "total": len(files),
    }


def load_pins(pins_path) -> dict:
    try:
        data = json.loads(Path(pins_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise RankedConfigError("ranked_source_pins_unreadable")
    if not isinstance(data, dict) or data.get("schema") != PIN_SCHEMA:
        raise RankedConfigError("ranked_source_pins_invalid")
    return data


# The production pin file is a fixed, reviewed path under the repository. It is
# never selected from a menu/role request, an arbitrary stage manifest or an
# automatic re-record; callers cannot substitute their own pins in production.
PRODUCTION_PINS_REL = ("docs", "RANKED_SOURCE_PINS_V1.json")


def production_pins_path() -> Path:
    """The single reviewed production pin file, anchored to the loaded module.

    The path is derived from this measured module's own ``__file__`` repository
    root; there is no caller/repo-root override and no re-record entry point.
    """
    return Path(__file__).resolve().parent.parent.joinpath(*PRODUCTION_PINS_REL)


def load_production_pins() -> dict:
    """Load the single reviewed production pin file (no caller override)."""
    return load_pins(production_pins_path())


# ---------------------------------------------------------------------------
# Source parsing
# ---------------------------------------------------------------------------

def parse_ruleset_declaration(source: str) -> dict:
    """Strictly parse ``rulesets/ranked.lua``'s ``MP.Ruleset({...})`` table."""
    literal = parse_literal(_extract_call_argument(source, "MP.Ruleset("))
    problems: list[str] = []
    key = literal.get("key")
    if key != RULESET_KEY:
        problems.append("ranked_ruleset_key_unexpected")
    layers = literal.get("layers")
    if not isinstance(layers, dict) or "__array__" not in layers:
        problems.append("ranked_declared_layers_missing")
        layers_list: list = []
    else:
        layers_list = layers["__array__"]
        if tuple(layers_list) != DECLARED_LAYERS:
            problems.append("ranked_declared_layers_unexpected")
    if literal.get("forced_gamemode") != FORCED_GAMEMODE:
        problems.append("ranked_forced_gamemode_unexpected")
    extra = sorted(set(literal.keys()) - {"key", "layers", "forced_gamemode"})
    if extra:
        problems.append("ranked_ruleset_unknown_keys")
    return {
        "ok": not problems,
        "problems": problems,
        "key": key,
        "layers": layers_list,
        "forced_gamemode": literal.get("forced_gamemode"),
    }


def parse_layer(source: str, name: str) -> dict:
    """Strictly parse an ``MP.Layer("name", {...})`` literal.

    Rejects any key outside the reviewed set for that layer.
    """
    literal = parse_literal(_extract_call_argument(source, 'MP.Layer("%s"' % name))
    if not isinstance(literal, dict):
        raise RankedConfigError("ranked_source_unsupported_syntax")
    allowed = KNOWN_LAYER_KEYS.get(name, frozenset())
    if set(literal.keys()) - allowed:
        raise RankedConfigError("ranked_source_unknown_layer_key")
    return literal


def parse_lobby_defaults(core_source: str) -> dict:
    """Parse the primitive default table in ``MP.reset_lobby_config``.

    The two expression-valued keys (``ruleset``/``gamemode``) are skipped; every
    other entry must be a strict primitive, and a mutated/unsupported entry is
    rejected.
    """
    body = core_source[core_source.find("function MP.reset_lobby_config"):]
    end = body.find("\nend")
    body = body[: end if end != -1 else len(body)]
    table_text = _extract_assignment_table(body, "MP.LOBBY.config = ")
    parser = _Parser(_tokenize(_strip_comments(table_text)))
    defaults: dict = {}
    opening = parser.next()
    if opening[0] != "{":
        raise RankedConfigError("ranked_source_unsupported_syntax")
    # Reparse manually so we can allow the two expression keys to be skipped.
    while True:
        token = parser.peek()
        if token is None:
            raise RankedConfigError("ranked_source_unsupported_syntax")
        kind, text = token
        if kind == "}":
            parser.next()
            break
        if kind in (",", ";"):
            parser.next()
            continue
        if kind != "name":
            raise RankedConfigError("ranked_source_unsupported_syntax")
        parser.next()
        if parser.peek() is None or parser.peek()[0] != "=":
            raise RankedConfigError("ranked_source_unsupported_syntax")
        parser.next()
        if text in _DEFAULTS_EXPRESSION_KEYS:
            _skip_expression(parser)
            continue
        defaults[text] = parser.value()
    if not defaults:
        raise RankedConfigError("ranked_source_shape_missing")
    if set(defaults.keys()) - KNOWN_DEFAULT_KEYS:
        raise RankedConfigError("ranked_source_unknown_config_key")
    return defaults


def _skip_expression(parser: _Parser):
    """Skip one ``a and b or c`` expression (only the two reviewed keys use it)."""
    depth = 0
    while True:
        token = parser.peek()
        if token is None:
            raise RankedConfigError("ranked_source_unsupported_syntax")
        kind, text = token
        if depth == 0 and kind in (",", ";", "}"):
            return
        if kind == "{":
            depth += 1
        elif kind == "}":
            if depth == 0:
                return
            depth -= 1
        if kind == "function":
            parser.next()
            _skip_function_tokens(parser)
            continue
        parser.next()


def _skip_function_tokens(parser: _Parser):
    depth = 1
    while depth > 0:
        token = parser.next()
        if token[0] == "name" and token[1] == "function":
            depth += 1
        elif token[0] == "name" and token[1] == "end":
            depth -= 1


# ---------------------------------------------------------------------------
# Derivations
# ---------------------------------------------------------------------------

def _require(defaults: Mapping, key: str, kind, problems: list):
    value = defaults.get(key, None)
    if kind is bool:
        if not isinstance(value, bool):
            problems.append("ranked_default_missing:" + key)
            return None
        return value
    if kind is int:
        if isinstance(value, bool) or not isinstance(value, int):
            problems.append("ranked_default_missing:" + key)
            return None
        return value
    if kind is str:
        if not isinstance(value, str):
            problems.append("ranked_default_missing:" + key)
            return None
        return value
    if kind is type(None):
        if value is not None:
            problems.append("ranked_default_not_nil:" + key)
        return value
    problems.append("ranked_default_type_unknown:" + key)
    return None


def _type_tag(value) -> str:
    if value is None:
        return "n"
    if isinstance(value, bool):
        return "b1" if value else "b0"
    if isinstance(value, int):
        if value < INT32_MIN or value > INT32_MAX:
            raise RankedConfigError("ranked_canonical_int_out_of_range")
        return "i%d" % value
    if isinstance(value, str):
        if _string_invalid(value):
            raise RankedConfigError("ranked_canonical_string_invalid")
        return "s%d:%s" % (len(value.encode("utf-8")), value)
    raise RankedConfigError("ranked_canonical_type_invalid")


def _type_tag_list(values) -> str:
    if not isinstance(values, (list, tuple)):
        raise RankedConfigError("ranked_canonical_type_invalid")
    return "l%d[%s]" % (len(values), ",".join(_type_tag(v) for v in values))


def cocktail_default_shape_ok(value) -> bool:
    """The boot-generated default is one ``1`` per eligible deck, then ``H``."""
    if not isinstance(value, str) or len(value) == 0 or len(value) > MAX_STRING:
        return False
    if value[-1] != "H":
        return False
    body = value[:-1]
    return body != "" and all(ch == "1" for ch in body)


def expected_cocktail_for_count(count: int) -> str:
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        raise RankedConfigError("ranked_cocktail_count_invalid")
    return "1" * count + "H"


def derive_effective_config(
    mod_root,
    pins_path,
    cocktail: Optional[str] = None,
    guest_cocktail: Optional[str] = None,
    selection=None,
    catalog=None,
    custom_seed: Optional[str] = None,
) -> dict:
    """Derive the expected Standard Ranked lobby configuration.

    Reads only the pinned Multiplayer source. ``pins_path`` is mandatory: the
    enumerated files are always SHA-256-verified first and any drift fails
    closed. There is no unpinned derivation path; fixture pins are supplied
    explicitly by the caller (test/helper interface only).

    ``cocktail`` is the boot-generated default composition measured from the
    role catalog (one ``1`` per eligible deck then ``H``). It is a measured
    catalog fact, not a static source constant, so it must be supplied; the
    reviewed shape and (when given) host/guest parity are enforced.

    ``selection`` is the host-owned completed-draft binding. The expected
    ``back``/``stake`` come ONLY from ``validate_selection``; without a validated
    selection the derivation fails closed with ``ranked_draft_unbound`` (there is
    no Red Deck / White Stake fallback). ``custom_seed`` is the trusted gauntlet
    seed, supplied by the host from its catalog, never a raw caller seed.
    Returns ``{"ok", "problems", "host", "guest", "resolved", "canonical",
    "checksum"}``.
    """
    root = Path(mod_root)
    problems: list[str] = []
    try:
        pins = load_pins(pins_path)
    except RankedConfigError as error:
        return {"ok": False, "problems": [error.code]}
    verdict = verify_source_pins(root, pins)
    if not verdict["ok"]:
        return {"ok": False, "problems": verdict["problems"], "verified": verdict["verified"]}

    def read(rel: str):
        try:
            return (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            problems.append("ranked_source_unreadable:" + rel)
            return ""

    ruleset = parse_ruleset_declaration(read(RULESET_REL))
    problems.extend(ruleset["problems"])
    try:
        standard_layer = parse_layer(read(LAYER_STANDARD_REL), "standard")
        ranked_layer = parse_layer(read(LAYER_RANKED_REL), "ranked")
        pvp_layer = parse_layer(read(LAYER_PVP_TIMER_REL), "pvp_timer")
    except RankedConfigError as error:
        return {"ok": False, "problems": [error.code]}

    if standard_layer.get("standard") is not True:
        problems.append("ranked_standard_layer_flag_missing")
    if standard_layer.get("multiplayer_content") is not True:
        problems.append("ranked_multiplayer_content_missing")
    if ranked_layer.get("forced_lobby_options") is not True:
        problems.append("ranked_forced_lobby_options_missing")
    if not isinstance(ranked_layer.get("is_disabled"), _Function):
        problems.append("ranked_is_disabled_missing")
    if not isinstance(ranked_layer.get("force_lobby_options"), _Function):
        problems.append("ranked_force_lobby_options_missing")
    if pvp_layer.get("pvp_timer_base_seconds") != PVP_TIMER_BASE_SECONDS:
        problems.append("ranked_pvp_timer_base_unexpected")
    if pvp_layer.get("pvp_timer_hand_played_increment_seconds") != PVP_TIMER_HAND_INCREMENT_SECONDS:
        problems.append("ranked_pvp_timer_increment_unexpected")

    try:
        defaults = parse_lobby_defaults(read(CORE_REL))
    except RankedConfigError as error:
        return {"ok": False, "problems": [error.code]}

    # Reviewed derivations from the pinned start_lobby callback.
    defaults["multiplayer_jokers"] = standard_layer.get("multiplayer_content")
    defaults.setdefault("hide_score_until_played", True)
    defaults["hide_score_until_played"] = True  # standard == true
    defaults["forced_config"] = True  # ranked force_lobby_options() result
    defaults["the_order"] = True
    defaults["disable_live_and_timer_hud"] = False  # attrition
    defaults["modifier_layers"] = ""  # modifiers_serialize() with no modifiers
    if custom_seed is not None:
        if not isinstance(custom_seed, str) or not custom_seed:
            problems.append("ranked_custom_seed_invalid")
        else:
            defaults["custom_seed"] = custom_seed
    for key in NIL_OVERRIDE_KEYS:
        if key not in defaults:
            defaults[key] = None
        elif defaults[key] is not None:
            problems.append("ranked_override_injected:" + key)

    # The lobby cocktail comes from the boot-generated mod-config default (NOT
    # the reset_lobby_config placeholder): one 1 per eligible deck, then H.
    if cocktail is None:
        problems.append("ranked_cocktail_unmeasured")
    elif not cocktail_default_shape_ok(cocktail):
        problems.append("ranked_cocktail_shape_unexpected")
    else:
        defaults["cocktail"] = cocktail
        if guest_cocktail is not None and guest_cocktail != cocktail:
            problems.append("ranked_cocktail_role_parity")

    # The expected back/stake come ONLY from the host-owned completed draft. The
    # source placeholders ("Red Deck" / 1) are never a production fallback.
    if selection is None:
        problems.append("ranked_draft_unbound")
    else:
        selection_verdict = validate_selection(selection, catalog)
        if not selection_verdict.get("ok"):
            problems.extend(selection_verdict.get("problems") or ("ranked_selection_schema_invalid",))
        else:
            defaults["back"] = selection_verdict["back_name"]
            defaults["stake"] = selection_verdict["stake_index"]

    if not isinstance(defaults.get("back"), str):
        problems.append("ranked_default_back_missing")
    if isinstance(defaults.get("stake"), bool) or not isinstance(defaults.get("stake"), int):
        problems.append("ranked_default_stake_missing")

    host = _lobby_view(defaults, role="host", problems=problems)
    guest = _lobby_view(defaults, role="guest", problems=problems)
    resolved = _resolved_view(problems)

    if problems:
        return {"ok": False, "problems": sorted(set(problems))}

    canonical = canonical_bytes(host, resolved)
    checksum = fnv1a32_hex(canonical)
    return {
        "ok": True,
        "problems": [],
        "host": host,
        "guest": guest,
        "resolved": resolved,
        "canonical": canonical,
        "checksum": checksum,
    }


def _lobby_view(defaults: Mapping, role: str, problems: list) -> dict:
    """Typed lobby view for one role.

    ``weekly`` is absent on both roles (typed nil). Other nil-override keys are
    nil on the host (never sent) and derived from the guest's own load-time state
    (also nil for the reviewed defaults). Cocktail is the same boot-generated
    default string on both roles.
    """
    view = {
        "gold_on_life_loss": _require(defaults, "gold_on_life_loss", bool, problems),
        "no_gold_on_round_loss": _require(defaults, "no_gold_on_round_loss", bool, problems),
        "death_on_round_loss": _require(defaults, "death_on_round_loss", bool, problems),
        "different_seeds": _require(defaults, "different_seeds", bool, problems),
        "the_order": _require(defaults, "the_order", bool, problems),
        "starting_lives": _require(defaults, "starting_lives", int, problems),
        "pvp_start_round": _require(defaults, "pvp_start_round", int, problems),
        "timer_base_seconds": _require(defaults, "timer_base_seconds", int, problems),
        "timer_increment_seconds": _require(defaults, "timer_increment_seconds", int, problems),
        "pvp_countdown_seconds": _require(defaults, "pvp_countdown_seconds", int, problems),
        "showdown_starting_antes": _require(defaults, "showdown_starting_antes", int, problems),
        "weekly": None,
        "custom_seed": _require(defaults, "custom_seed", str, problems),
        "different_decks": _require(defaults, "different_decks", bool, problems),
        "random_loadout": _require(defaults, "random_loadout", bool, problems),
        "back": _require(defaults, "back", str, problems),
        "sleeve": _require(defaults, "sleeve", str, problems),
        "stake": _require(defaults, "stake", int, problems),
        "challenge": _require(defaults, "challenge", str, problems),
        "cocktail": _require(defaults, "cocktail", str, problems),
        "multiplayer_jokers": _require(defaults, "multiplayer_jokers", bool, problems),
        "timer": _require(defaults, "timer", bool, problems),
        "timer_forgiveness": _require(defaults, "timer_forgiveness", int, problems),
        "forced_config": _require(defaults, "forced_config", bool, problems),
        "preview_disabled": _require(defaults, "preview_disabled", bool, problems),
        "legacy_smallworld": _require(defaults, "legacy_smallworld", bool, problems),
        "hide_score_until_played": _require(defaults, "hide_score_until_played", bool, problems),
        "enemy_location_disabled": _require(defaults, "enemy_location_disabled", bool, problems),
        "timer_display_threshold": _require(defaults, "timer_display_threshold", int, problems),
        "modifier_layers": _require(defaults, "modifier_layers", str, problems),
        "disable_live_and_timer_hud": _require(defaults, "disable_live_and_timer_hud", bool, problems),
    }
    for key in NIL_OVERRIDE_KEYS:
        view[key] = None
    return view


# ---------------------------------------------------------------------------
# Draft selection contract (host-owned; completed by the future draft slice)
# ---------------------------------------------------------------------------
# This slice deliberately does NOT implement a production draft or a fallback
# deck. It only defines the strict internal binding the completed draft must
# satisfy, so the next slice can wire the real state machine. The catalog is
# host-owned and source-validated; a missing/ambiguous entry is refused.

SELECTION_SCHEMA = "aisparring.ranked_selection.v1"
MAX_STAKE_INDEX = 8
_SELECTION_KEYS = frozenset(
    {"schema", "deck_key", "back_key", "back_name", "stake_key", "stake_index"}
)


def validate_selection(selection, catalog) -> dict:
    """Validate one host-owned deck/stake selection against a source catalog.

    Refuses unknown decks/stakes, ambiguous deck->center mappings, a clamped
    (``MAX_STAKE``) index and any malformed primitive. Returns ``ok`` plus the
    resolved ``back_key``/``stake_index``; it never invents a fallback.
    """
    problems: list[str] = []
    if not isinstance(selection, Mapping) or set(selection.keys()) != _SELECTION_KEYS:
        return {"ok": False, "problems": ["ranked_selection_schema_invalid"]}
    if selection.get("schema") != SELECTION_SCHEMA:
        problems.append("ranked_selection_schema_invalid")
    deck_key = selection.get("deck_key")
    back_key = selection.get("back_key")
    back_name = selection.get("back_name")
    stake_key = selection.get("stake_key")
    stake_index = selection.get("stake_index")
    for name, value in (
        ("deck_key", deck_key),
        ("back_key", back_key),
        ("back_name", back_name),
        ("stake_key", stake_key),
    ):
        if not isinstance(value, str) or len(value) == 0 or len(value) > MAX_STRING:
            problems.append("ranked_selection_" + name + "_invalid")
    if isinstance(stake_index, bool) or not isinstance(stake_index, int):
        problems.append("ranked_selection_stake_index_invalid")
    elif stake_index < 1 or stake_index > MAX_STAKE_INDEX:
        # A value outside the engine range would be silently clamped (MAX_STAKE).
        problems.append("ranked_selection_stake_clamped")
    if not isinstance(catalog, Mapping):
        return {"ok": False, "problems": sorted(set(problems + ["ranked_selection_catalog_missing"]))}
    decks = catalog.get("decks")
    stakes = catalog.get("stakes")
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping):
        return {"ok": False, "problems": sorted(set(problems + ["ranked_selection_catalog_invalid"]))}

    entry = decks.get(deck_key) if isinstance(deck_key, str) else None
    if not isinstance(entry, Mapping):
        problems.append("ranked_selection_deck_unknown")
    else:
        if entry.get("center_key") != back_key or entry.get("name") != back_name:
            problems.append("ranked_selection_deck_mismatch")
    # Ambiguity: a Back center AND the Back name that actually travels on the
    # wire must each map to exactly one deck key.
    if isinstance(back_key, str):
        owners = [
            key
            for key, value in decks.items()
            if isinstance(value, Mapping) and value.get("center_key") == back_key
        ]
        if len(owners) > 1:
            problems.append("ranked_selection_deck_ambiguous")
    if isinstance(back_name, str):
        name_owners = [
            key
            for key, value in decks.items()
            if isinstance(value, Mapping) and value.get("name") == back_name
        ]
        if len(name_owners) > 1:
            problems.append("ranked_selection_name_ambiguous")

    stake_entry = stakes.get(stake_key) if isinstance(stake_key, str) else None
    if not isinstance(stake_entry, Mapping):
        problems.append("ranked_selection_stake_unknown")
    else:
        index = stake_entry.get("index")
        max_index = stake_entry.get("max_index", MAX_STAKE_INDEX)
        if isinstance(index, bool) or not isinstance(index, int) or index != stake_index:
            problems.append("ranked_selection_stake_mismatch")
        if isinstance(max_index, bool) or not isinstance(max_index, int) or max_index > MAX_STAKE_INDEX:
            problems.append("ranked_selection_catalog_invalid")
        elif isinstance(stake_index, int) and stake_index > max_index:
            problems.append("ranked_selection_stake_clamped")

    problems = sorted(set(problems))
    if problems:
        return {"ok": False, "problems": problems}
    return {
        "ok": True,
        "problems": [],
        "deck_key": deck_key,
        "back_key": back_key,
        "back_name": back_name,
        "stake_key": stake_key,
        "stake_index": stake_index,
    }


def check_post_start_selection(selection, actual_back_key, actual_stake) -> dict:
    """Both roles verify the actual initialized ``selected_back`` and stake.

    ``actual_back_key`` is ``selected_back.effect.center.key`` and
    ``actual_stake`` is ``G.GAME.stake``. A loading frame is a bounded retry, not
    a mismatch; callers pass ``None`` for "not initialized yet". A real mismatch
    aborts.
    """
    problems: list[str] = []
    if actual_back_key is None or actual_stake is None:
        return {"ok": False, "problems": ["ranked_post_start_uninitialized"], "retry": True}
    if not isinstance(selection, Mapping):
        return {"ok": False, "problems": ["ranked_selection_schema_invalid"]}
    if actual_back_key != selection.get("back_key"):
        problems.append("ranked_post_start_back_mismatch")
    if isinstance(actual_stake, bool) or not isinstance(actual_stake, int):
        problems.append("ranked_post_start_stake_invalid")
    elif actual_stake != selection.get("stake_index"):
        problems.append("ranked_post_start_stake_mismatch")
    return {"ok": not problems, "problems": problems, "retry": False}


def _resolved_view(problems: list) -> dict:
    return {
        "ruleset_key": RULESET_KEY,
        "ruleset_id": RULESET_ID,
        "forced_gamemode": FORCED_GAMEMODE,
        "declared_layers": list(DECLARED_LAYERS),
        "active_layer_chain": list(ACTIVE_LAYER_CHAIN),
        "standard": True,
        "multiplayer_content": True,
        "modifier_list": [],
        "pvp_timer_base_seconds_resolved": PVP_TIMER_BASE_SECONDS,
        "pvp_timer_hand_played_increment_seconds_resolved": PVP_TIMER_HAND_INCREMENT_SECONDS,
        "effective_timer_base_seconds": ORDINARY_TIMER_BASE_SECONDS,
        "timer_base_multiplier_resolved": TIMER_BASE_MULTIPLIER,
        "is_disabled": False,
    }


# ---------------------------------------------------------------------------
# Canonical binding
# ---------------------------------------------------------------------------

_LOBBY_ORDER = (
    "gold_on_life_loss",
    "no_gold_on_round_loss",
    "death_on_round_loss",
    "different_seeds",
    "the_order",
    "starting_lives",
    "pvp_start_round",
    "timer_base_seconds",
    "timer_increment_seconds",
    "pvp_countdown_seconds",
    "showdown_starting_antes",
    "weekly",
    "custom_seed",
    "different_decks",
    "random_loadout",
    "back",
    "sleeve",
    "stake",
    "challenge",
    "cocktail",
    "multiplayer_jokers",
    "timer",
    "timer_forgiveness",
    "forced_config",
    "preview_disabled",
    "legacy_smallworld",
    "hide_score_until_played",
    "enemy_location_disabled",
    "timer_display_threshold",
    "modifier_layers",
    "disable_live_and_timer_hud",
    "pvp_timer_base_seconds",
    "pvp_timer_hand_played_increment_seconds",
    "normal_bosses",
    "timer_hand_played_increment_seconds",
    "timer_base_multiplier",
    "preview_calculate_delay",
    "preview_calculate_cost",
)

_RESOLVED_ORDER = (
    "ruleset_key",
    "ruleset_id",
    "forced_gamemode",
    "declared_layers",
    "active_layer_chain",
    "standard",
    "multiplayer_content",
    "modifier_list",
    "pvp_timer_base_seconds_resolved",
    "pvp_timer_hand_played_increment_seconds_resolved",
    "effective_timer_base_seconds",
    "timer_base_multiplier_resolved",
    "is_disabled",
)

# Per-field type schema. Identical to the Lua ``FIELD_TYPES`` and enforced
# before any tag is written: the type is declared by the field, never inferred
# from the runtime value. ``nil`` means the field must be exactly typed-nil;
# ``str_list`` is a dense ordered list of non-empty bounded strings.
FIELD_TYPES = {
    "lobby": {
        "gold_on_life_loss": "bool",
        "no_gold_on_round_loss": "bool",
        "death_on_round_loss": "bool",
        "different_seeds": "bool",
        "the_order": "bool",
        "starting_lives": "int",
        "pvp_start_round": "int",
        "timer_base_seconds": "int",
        "timer_increment_seconds": "int",
        "pvp_countdown_seconds": "int",
        "showdown_starting_antes": "int",
        "weekly": "nil",
        "custom_seed": "str",
        "different_decks": "bool",
        "random_loadout": "bool",
        "back": "str",
        "sleeve": "str",
        "stake": "int",
        "challenge": "str",
        "cocktail": "str",
        "multiplayer_jokers": "bool",
        "timer": "bool",
        "timer_forgiveness": "int",
        "forced_config": "bool",
        "preview_disabled": "bool",
        "legacy_smallworld": "bool",
        "hide_score_until_played": "bool",
        "enemy_location_disabled": "bool",
        "timer_display_threshold": "int",
        "modifier_layers": "str",
        "disable_live_and_timer_hud": "bool",
        "pvp_timer_base_seconds": "nil",
        "pvp_timer_hand_played_increment_seconds": "nil",
        "normal_bosses": "nil",
        "timer_hand_played_increment_seconds": "nil",
        "timer_base_multiplier": "nil",
        "preview_calculate_delay": "nil",
        "preview_calculate_cost": "nil",
    },
    "resolved": {
        "ruleset_key": "str",
        "ruleset_id": "str",
        "forced_gamemode": "str",
        "declared_layers": "str_list",
        "active_layer_chain": "str_list",
        "standard": "bool",
        "multiplayer_content": "bool",
        "modifier_list": "str_list",
        "pvp_timer_base_seconds_resolved": "int",
        "pvp_timer_hand_played_increment_seconds_resolved": "int",
        "effective_timer_base_seconds": "int",
        "timer_base_multiplier_resolved": "int",
        "is_disabled": "bool",
    },
}

_CONTROL_MAX = 0x20
_CONTROL_DEL = 0x7F


def _string_invalid(value: str) -> bool:
    """Byte-bounded, no control byte (<0x20 or 0x7f) and no separator."""
    if len(value.encode("utf-8")) > MAX_STRING:
        return True
    for ch in value:
        code = ord(ch)
        if code < _CONTROL_MAX or code == _CONTROL_DEL or ch in ("|", "="):
            return True
    return False


def _field_type_ok(kind: str, value) -> bool:
    if kind == "nil":
        return value is None
    if kind == "bool":
        return isinstance(value, bool)
    if kind == "int":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "str":
        return isinstance(value, str) and not _string_invalid(value)
    if kind == "str_list":
        if not isinstance(value, (list, tuple)):
            return False
        return all(isinstance(item, str) and len(item) > 0 and not _string_invalid(item) for item in value)
    return False


def canonical_bytes(lobby: Mapping, resolved: Mapping) -> str:
    """Fixed-order, type-tagged, domain-separated canonical string.

    Every enumerated key is required. A missing required field is an error rather
    than being silently treated as typed nil, and an unknown key is refused. The
    type tag is derived from the actual value, never from an arbitrary caller tag.
    """
    if not isinstance(lobby, Mapping) or not isinstance(resolved, Mapping):
        raise RankedConfigError("ranked_canonical_type_invalid")
    lobby_keys = set(lobby.keys())
    if lobby_keys - set(_LOBBY_ORDER):
        raise RankedConfigError("ranked_canonical_unknown_lobby_key")
    missing_lobby = set(_LOBBY_ORDER) - lobby_keys
    if missing_lobby:
        raise RankedConfigError("ranked_canonical_missing_lobby_key")
    resolved_keys = set(resolved.keys())
    if resolved_keys - set(_RESOLVED_ORDER):
        raise RankedConfigError("ranked_canonical_unknown_resolved_key")
    missing_resolved = set(_RESOLVED_ORDER) - resolved_keys
    if missing_resolved:
        raise RankedConfigError("ranked_canonical_missing_resolved_key")
    parts = [DOMAIN]
    for key in _LOBBY_ORDER:
        value = lobby.get(key)
        if not _field_type_ok(FIELD_TYPES["lobby"][key], value):
            raise RankedConfigError("ranked_canonical_field_type")
        parts.append(key + "=" + _type_tag(value))
    for key in _RESOLVED_ORDER:
        value = resolved.get(key)
        if not _field_type_ok(FIELD_TYPES["resolved"][key], value):
            raise RankedConfigError("ranked_canonical_field_type")
        if key in ("declared_layers", "active_layer_chain", "modifier_list"):
            parts.append(key + "=" + _type_tag_list(value))
        else:
            parts.append(key + "=" + _type_tag(value))
    canonical = "|".join(parts)
    if len(canonical.encode("utf-8")) > MAX_CANONICAL_BYTES:
        raise RankedConfigError("ranked_canonical_too_large")
    return canonical


def fnv1a32_hex(text: str) -> str:
    if not isinstance(text, str):
        raise RankedConfigError("ranked_canonical_type_invalid")
    value = FNV1A32_OFFSET
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * FNV1A32_PRIME) & 0xFFFFFFFF
    return "%08x" % value


__all__ = [
    "ACTIVE_LAYER_CHAIN",
    "DECLARED_LAYERS",
    "DOMAIN",
    "FIELD_TYPES",
    "FORCED_GAMEMODE",
    "MAX_STAKE_INDEX",
    "NIL_OVERRIDE_KEYS",
    "PIN_SCHEMA",
    "PRODUCTION_PINS_REL",
    "RANKED_CONFIG_SCHEMA",
    "RULESET_ID",
    "RULESET_KEY",
    "SELECTION_SCHEMA",
    "RankedConfigError",
    "canonical_bytes",
    "check_post_start_selection",
    "cocktail_default_shape_ok",
    "derive_effective_config",
    "expected_cocktail_for_count",
    "fnv1a32_hex",
    "load_pins",
    "load_production_pins",
    "parse_layer",
    "parse_literal",
    "parse_lobby_defaults",
    "parse_ruleset_declaration",
    "production_pins_path",
    "validate_selection",
    "verify_source_pins",
]
