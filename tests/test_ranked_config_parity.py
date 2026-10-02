#!/usr/bin/env python3
"""Lua/Python canonical parity for the Ranked effective-config contract.

Loads the real ``AISparring/integration/ranked_config.lua`` under lupa's Lua 5.1
and LuaJIT 2.1 and asserts byte-identical canonical strings and FNV1a-32
checksums against the Python authority ``tools/ranked_effective_config.py`` for
the same typed field tables. No game, Mods, network or live runtime is touched.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import ranked_effective_config as rec  # noqa: E402

RANKED_LUA = REPO / "AISparring" / "integration" / "ranked_config.lua"
RUNTIMES = (("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21"))


def _resolved(**overrides) -> dict:
    base = {
        "ruleset_key": "standard_ranked",
        "ruleset_id": "ruleset_mp_standard_ranked",
        "forced_gamemode": "gamemode_mp_attrition",
        "declared_layers": ["standard", "ranked", "pvp_timer"],
        "active_layer_chain": ["standard", "ranked", "pvp_timer", "standard_ranked"],
        "standard": True,
        "multiplayer_content": True,
        "modifier_list": [],
        "pvp_timer_base_seconds_resolved": 60,
        "pvp_timer_hand_played_increment_seconds_resolved": 10,
        "effective_timer_base_seconds": 150,
        "timer_base_multiplier_resolved": 1,
        "is_disabled": False,
    }
    base.update(overrides)
    return base


def _lobby(**overrides) -> dict:
    base = {
        "gold_on_life_loss": True,
        "no_gold_on_round_loss": False,
        "death_on_round_loss": True,
        "different_seeds": False,
        "the_order": True,
        "starting_lives": 4,
        "pvp_start_round": 2,
        "timer_base_seconds": 150,
        "timer_increment_seconds": 60,
        "pvp_countdown_seconds": 3,
        "showdown_starting_antes": 3,
        "weekly": None,
        "custom_seed": "random",
        "different_decks": False,
        "random_loadout": False,
        "back": "Red Deck",
        "sleeve": "sleeve_casl_none",
        "stake": 1,
        "challenge": "",
        "cocktail": "1H",
        "multiplayer_jokers": True,
        "timer": True,
        "timer_forgiveness": 0,
        "forced_config": True,
        "preview_disabled": False,
        "legacy_smallworld": False,
        "hide_score_until_played": True,
        "enemy_location_disabled": False,
        "timer_display_threshold": 0,
        "modifier_layers": "",
        "disable_live_and_timer_hud": False,
        "pvp_timer_base_seconds": None,
        "pvp_timer_hand_played_increment_seconds": None,
        "normal_bosses": None,
        "timer_hand_played_increment_seconds": None,
        "timer_base_multiplier": None,
        "preview_calculate_delay": None,
        "preview_calculate_cost": None,
    }
    base.update(overrides)
    return base


def _load_lua(module_name: str):
    import importlib

    module = importlib.import_module(module_name)
    factory = getattr(module, "LuaRuntime", None) or module
    lua = factory(unpack_returned_tuples=True)
    result = lua.execute(RANKED_LUA.read_text(encoding="utf-8"))
    config = result if result is not None else lua.globals()["RankedConfig"]
    return lua, config


def _pair(result):
    """Normalize a lupa return (single value or multi-value tuple) to a pair."""
    if isinstance(result, tuple):
        return (result[0] if len(result) > 0 else None), (result[1] if len(result) > 1 else None)
    return result, None


def _to_lua(lua, config, value):
    """Convert a Python fixture value to the Lua table shape the module expects.

    ``None`` becomes the explicit ``RankedConfig.NIL`` sentinel so typed-nil
    fields stay present instead of disappearing from the Lua table.
    """
    if value is None:
        return config.NIL
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = _to_lua(lua, config, item)
        return table
    if isinstance(value, (list, tuple)):
        return lua.table_from([_to_lua(lua, config, item) for item in value])
    return value


FIXTURES = [
    ("base", _lobby(), _resolved()),
    ("nil_vs_empty", _lobby(weekly=None, challenge=""), _resolved()),
    ("bool_vs_string", _lobby(the_order=True), _resolved()),
    ("stake_wire_int", _lobby(stake=8), _resolved()),
    ("reordered_layers", _lobby(), _resolved(declared_layers=["ranked", "standard", "pvp_timer"])),
    ("empty_modifiers", _lobby(), _resolved(modifier_list=[])),
    ("nonempty_modifiers", _lobby(), _resolved(modifier_list=["pressure_timer"])),
    ("float_field", _lobby(timer_base_seconds=150.5), _resolved()),
    ("out_of_range_int", _lobby(starting_lives=3000000000), _resolved()),
    ("separator_string", _lobby(custom_seed="a|b"), _resolved()),
]


def run_suite(module_name: str) -> int:
    lua, lua_config = _load_lua(module_name)
    failures = 0
    checks = 0
    for name, lobby, resolved in FIXTURES:
        checks += 1
        lua_lobby = _to_lua(lua, lua_config, lobby)
        lua_resolved = _to_lua(lua, lua_config, resolved)
        lua_canonical, lua_code = _pair(lua_config.canonical_bytes(lua_lobby, lua_resolved))
        if name in ("float_field", "out_of_range_int", "separator_string"):
            # Both sides must refuse the malformed value.
            if lua_canonical is not None:
                failures += 1
                print(f"FAIL {module_name}::{name}: Lua accepted malformed value")
            try:
                rec.canonical_bytes(lobby, resolved)
            except rec.RankedConfigError:
                pass
            else:
                failures += 1
                print(f"FAIL {module_name}::{name}: Python accepted malformed value")
            continue
        py_canonical = rec.canonical_bytes(lobby, resolved)
        py_digest = rec.fnv1a32_hex(py_canonical)
        if lua_canonical != py_canonical:
            failures += 1
            print(f"FAIL {module_name}::{name}: canonical mismatch\n  py={py_canonical!r}\n  lua={lua_canonical!r} ({lua_code})")
            continue
        lua_digest = lua_config.fnv1a32_hex(lua_canonical)
        if lua_digest != py_digest:
            failures += 1
            print(f"FAIL {module_name}::{name}: digest mismatch py={py_digest} lua={lua_digest}")
    print(f"{module_name}: {checks - failures}/{checks} parity cases passed")
    return failures


def test_missing_required_key_refused_on_both_sides():
    module = "lupa.lua51"
    lua, lua_config = _load_lua(module)
    lobby = _lobby()
    del lobby["cocktail"]
    resolved = _resolved()
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(
            _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
        )
    )
    assert lua_canonical is None
    assert lua_code == "ranked_canonical_missing_lobby_key"
    try:
        rec.canonical_bytes(lobby, resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_missing_lobby_key"
    else:
        raise AssertionError("python accepted a missing required key")


def test_unknown_key_refused_on_both_sides():
    lua, lua_config = _load_lua("lupa.lua51")
    lobby = _lobby()
    lobby["surprise"] = 1
    resolved = _resolved()
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(
            _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
        )
    )
    assert lua_canonical is None
    assert lua_code == "ranked_canonical_unknown_lobby_key"
    try:
        rec.canonical_bytes(lobby, resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_unknown_lobby_key"
    else:
        raise AssertionError("python accepted an unknown key")


FIELD_TYPE_SWAPS = [
    ("lobby", "the_order", 1),
    ("lobby", "different_decks", "false"),
    ("lobby", "starting_lives", True),
    ("lobby", "timer_base_seconds", "150"),
    ("lobby", "back", 5),
    ("lobby", "sleeve", True),
    ("lobby", "weekly", False),
    ("lobby", "normal_bosses", 1),
    ("lobby", "timer_base_multiplier", "2"),
    ("resolved", "ruleset_key", 1),
    ("resolved", "standard", 1),
    ("resolved", "effective_timer_base_seconds", True),
    ("resolved", "declared_layers", "standard"),
    ("resolved", "modifier_list", [1]),
]


def test_field_type_swaps_refused_on_both_sides():
    lua, lua_config = _load_lua("lupa.lua51")
    assert len(FIELD_TYPE_SWAPS) == 14
    for scope, key, value in FIELD_TYPE_SWAPS:
        lobby, resolved = _lobby(), _resolved()
        (lobby if scope == "lobby" else resolved)[key] = value
        py_code = None
        try:
            rec.canonical_bytes(lobby, resolved)
        except rec.RankedConfigError as error:
            py_code = error.code
        assert py_code == "ranked_canonical_field_type", (scope, key, py_code)
        lua_canonical, lua_code = _pair(
            lua_config.canonical_bytes(
                _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
            )
        )
        assert lua_canonical is None and lua_code == "ranked_canonical_field_type", (scope, key, lua_code)


def test_required_nil_and_override_int_refused_on_both_sides():
    lua, lua_config = _load_lua("lupa.lua51")
    cases = [
        ("starting_lives", None),
        ("the_order", None),
        ("back", None),
        ("normal_bosses", 1),
        ("weekly", ""),
        ("pvp_timer_base_seconds", True),
    ]
    for key, value in cases:
        lobby, resolved = _lobby(), _resolved()
        lobby[key] = value
        py_code = None
        try:
            rec.canonical_bytes(lobby, resolved)
        except rec.RankedConfigError as error:
            py_code = error.code
        assert py_code == "ranked_canonical_field_type", (key, py_code)
        lua_canonical, lua_code = _pair(
            lua_config.canonical_bytes(
                _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
            )
        )
        assert lua_canonical is None and lua_code == "ranked_canonical_field_type", (key, lua_code)


def test_control_bytes_and_utf8_length_on_both_sides():
    lua, lua_config = _load_lua("lupa.lua51")
    for bad in ("a\tb", "a\x00b", "a\x1fb", "a\x7fb", "a|b", "a=b", "a\nb", "a\rb"):
        lobby, resolved = _lobby(), _resolved()
        lobby["challenge"] = bad
        lua_canonical, lua_code = _pair(
            lua_config.canonical_bytes(
                _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
            )
        )
        assert lua_canonical is None, repr(bad)
        assert lua_code in ("ranked_canonical_field_type", "ranked_canonical_string_invalid"), repr(bad)
    # Byte-length parity: 65 ASCII bytes exceeds the 64-byte bound on both.
    lobby, resolved = _lobby(), _resolved()
    lobby["challenge"] = "a" * 65
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(
            _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
        )
    )
    assert lua_canonical is None and lua_code == "ranked_canonical_field_type"


def test_utf8_byte_length_parity():
    lua, lua_config = _load_lua("lupa.lua51")
    # 33 two-byte chars = 66 bytes > 64; refused by byte length on both sides.
    lobby, resolved = _lobby(), _resolved()
    lobby["challenge"] = "\u00e9" * 33
    py_code = None
    try:
        rec.canonical_bytes(lobby, resolved)
    except rec.RankedConfigError as error:
        py_code = error.code
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(
            _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
        )
    )
    assert py_code == "ranked_canonical_field_type"
    assert lua_canonical is None and lua_code == "ranked_canonical_field_type"
    # 32 two-byte chars = exactly 64 bytes; accepted by both.
    lobby["challenge"] = "\u00e9" * 32
    py_canonical = rec.canonical_bytes(lobby, resolved)
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(
            _to_lua(lua, lua_config, lobby), _to_lua(lua, lua_config, resolved)
        )
    )
    assert lua_canonical == py_canonical, (lua_code, len(py_canonical or ""))


def test_lua_list_hole_refused():
    lua, lua_config = _load_lua("lupa.lua51")
    resolved = _to_lua(lua, lua_config, _resolved())
    sparse = lua.table()
    sparse[1] = "standard"
    sparse[3] = "pvp_timer"
    resolved["declared_layers"] = sparse
    lua_canonical, lua_code = _pair(
        lua_config.canonical_bytes(_to_lua(lua, lua_config, _lobby()), resolved)
    )
    assert lua_canonical is None and lua_code == "ranked_canonical_field_type"


def _run_all() -> int:
    failures = 0
    available = 0
    for display, module_name in RUNTIMES:
        try:
            failures += run_suite(module_name)
            available += 1
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {display}: runtime unavailable: {error}")
    if available != len(RUNTIMES):
        failures += 1
        print("both Lua runtimes are mandatory; no silent skip")
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            try:
                function()
            except Exception as error:  # noqa: BLE001
                failures += 1
                print(f"FAIL {name}: {type(error).__name__}: {error}")
    print(f"\nparity result: {'FAIL' if failures else 'PASS'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_run_all())
