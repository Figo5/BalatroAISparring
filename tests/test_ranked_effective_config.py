#!/usr/bin/env python3
"""Source-pinned Ranked effective-config authority tests.

Everything runs against the reviewed reference Multiplayer copy under
``work/reference/certified-mods/Multiplayer`` and temp mutations of it. No live
path, game, server, network or certificate is touched.
"""
from __future__ import annotations

import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import json  # noqa: E402

import ranked_effective_config as rec  # noqa: E402
import ruleset_contract  # noqa: E402

PINNED_MOD = REPO / "work" / "reference" / "certified-mods" / "Multiplayer"
PINS_PATH = REPO / "docs" / "RANKED_SOURCE_PINS_V1.json"


# A validated host-owned completed-draft selection fixture and the catalog it
# binds against. Production fails closed without these; tests inject them.
def _catalog() -> dict:
    return {
        "decks": {
            "red": {"center_key": "b_red", "name": "Red Deck"},
            "blue": {"center_key": "b_blue", "name": "Blue Deck"},
        },
        "stakes": {"white": {"index": 1, "max_index": 8}},
    }


def _selection() -> dict:
    return {
        "schema": rec.SELECTION_SCHEMA,
        "deck_key": "red",
        "back_key": "b_red",
        "back_name": "Red Deck",
        "stake_key": "white",
        "stake_index": 1,
    }


def _derive(mod, pins, **kwargs):
    kwargs.setdefault("selection", _selection())
    kwargs.setdefault("catalog", _catalog())
    return rec.derive_effective_config(mod, pins, **kwargs)


def _copy_mod() -> tuple[tempfile.TemporaryDirectory, Path]:
    tmp = tempfile.TemporaryDirectory()
    dest = Path(tmp.name) / "Multiplayer"
    shutil.copytree(PINNED_MOD, dest, dirs_exist_ok=True)
    return tmp, dest


def _fixture_pins(mod: Path) -> str:
    """A test-only pin file matching a mutated copy, so parser-level refusals
    are exercised while pin verification stays always-on (no reference pin or
    source is re-recorded)."""
    base = json.loads(PINS_PATH.read_text(encoding="utf-8"))
    files = base["authoritative_files"]
    updated = dict(base)
    updated["authoritative_files"] = {
        rel: hashlib.sha256((Path(mod) / rel).read_bytes()).hexdigest() for rel in files
    }
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(updated, handle)
    handle.close()
    return handle.name


def test_pinned_reference_matches_every_pin():
    pins = rec.load_pins(PINS_PATH)
    assert pins["schema"] == rec.PIN_SCHEMA
    verdict = rec.verify_source_pins(PINNED_MOD, pins)
    assert verdict["ok"] is True, verdict["problems"]
    assert verdict["verified"] == verdict["total"] == 41


def test_drift_fails_closed():
    tmp, mod = _copy_mod()
    try:
        target = mod / "layers" / "pvp_timer.lua"
        target.write_text(target.read_text(encoding="utf-8") + "\n-- drift\n", encoding="utf-8")
        verdict = _derive(mod, PINS_PATH)
        assert verdict["ok"] is False
        assert any(p.startswith("ranked_source_pin_drift:") for p in verdict["problems"])
    finally:
        tmp.cleanup()


def test_ruleset_declaration_is_exact():
    source = (PINNED_MOD / "rulesets" / "ranked.lua").read_text(encoding="utf-8")
    parsed = rec.parse_ruleset_declaration(source)
    assert parsed["ok"] is True, parsed["problems"]
    assert parsed["key"] == "standard_ranked"
    assert tuple(parsed["layers"]) == ("standard", "ranked", "pvp_timer")
    assert parsed["forced_gamemode"] == "gamemode_mp_attrition"


def test_declaration_rejects_attrition_as_fourth_layer():
    source = 'MP.Ruleset({ key = "standard_ranked", layers = { "standard", "ranked", "pvp_timer", "attrition" }, forced_gamemode = "gamemode_mp_attrition" }):inject()\n'
    parsed = rec.parse_ruleset_declaration(source)
    assert parsed["ok"] is False
    assert "ranked_declared_layers_unexpected" in parsed["problems"]


def test_layer_scalars_parse():
    standard = rec.parse_layer((PINNED_MOD / "layers" / "standard.lua").read_text(encoding="utf-8"), "standard")
    assert standard["multiplayer_content"] is True
    assert standard["standard"] is True
    ranked = rec.parse_layer((PINNED_MOD / "layers" / "ranked.lua").read_text(encoding="utf-8"), "ranked")
    assert ranked["forced_lobby_options"] is True
    assert isinstance(ranked["is_disabled"], rec._Function)
    pvp = rec.parse_layer((PINNED_MOD / "layers" / "pvp_timer.lua").read_text(encoding="utf-8"), "pvp_timer")
    assert pvp["pvp_timer_base_seconds"] == 60
    assert pvp["pvp_timer_hand_played_increment_seconds"] == 10


def test_lobby_defaults_parse():
    defaults = rec.parse_lobby_defaults((PINNED_MOD / "core.lua").read_text(encoding="utf-8"))
    assert defaults["gold_on_life_loss"] is True
    assert defaults["no_gold_on_round_loss"] is False
    assert defaults["death_on_round_loss"] is True
    assert defaults["starting_lives"] == 4
    assert defaults["timer_base_seconds"] == 150
    assert defaults["timer_increment_seconds"] == 60
    assert defaults["pvp_countdown_seconds"] == 3
    assert defaults["showdown_starting_antes"] == 3
    assert defaults["sleeve"] == "sleeve_casl_none"
    assert defaults["challenge"] == ""
    assert defaults["back"] == "Red Deck"
    assert defaults["stake"] == 1


def test_derivation_is_ok_and_deterministic():
    first = _derive(PINNED_MOD, PINS_PATH, cocktail="1H")
    assert first["ok"] is True, first["problems"]
    second = _derive(PINNED_MOD, PINS_PATH, cocktail="1H")
    assert first["checksum"] == second["checksum"]
    assert first["canonical"] == second["canonical"]
    assert first["canonical"].startswith(rec.DOMAIN + "|")


def test_unmeasured_cocktail_fails_closed():
    verdict = _derive(PINNED_MOD, PINS_PATH)
    assert verdict["ok"] is False
    assert "ranked_cocktail_unmeasured" in verdict["problems"]


def test_cocktail_role_parity_enforced():
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="11H", guest_cocktail="111H")
    assert verdict["ok"] is False
    assert "ranked_cocktail_role_parity" in verdict["problems"]


def test_derived_host_guest_and_resolved_values():
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="11H")
    assert verdict["ok"] is True, verdict["problems"]
    host = verdict["host"]
    assert host["the_order"] is True
    assert host["hide_score_until_played"] is True
    assert host["multiplayer_jokers"] is True
    assert host["forced_config"] is True
    assert host["disable_live_and_timer_hud"] is False
    assert host["modifier_layers"] == ""
    assert host["enemy_location_disabled"] is False
    assert host["different_decks"] is False
    assert host["random_loadout"] is False
    assert host["weekly"] is None
    for key in rec.NIL_OVERRIDE_KEYS:
        assert host[key] is None
    assert host["cocktail"].endswith("H") and set(host["cocktail"][:-1]) <= {"1"}
    guest = verdict["guest"]
    assert guest == host  # reviewed defaults are identical on both roles
    resolved = verdict["resolved"]
    assert tuple(resolved["declared_layers"]) == ("standard", "ranked", "pvp_timer")
    assert tuple(resolved["active_layer_chain"]) == ("standard", "ranked", "pvp_timer", "standard_ranked")
    assert resolved["modifier_list"] == []
    assert resolved["pvp_timer_base_seconds_resolved"] == 60
    assert resolved["pvp_timer_hand_played_increment_seconds_resolved"] == 10
    assert resolved["effective_timer_base_seconds"] == 150
    assert resolved["timer_base_multiplier_resolved"] == 1
    assert resolved["standard"] is True
    assert resolved["multiplayer_content"] is True
    assert resolved["is_disabled"] is False


def test_unknown_config_key_fails_closed():
    tmp, mod = _copy_mod()
    try:
        path = mod / "core.lua"
        text = path.read_text(encoding="utf-8")
        text = text.replace("\t\ttimer_display_threshold = 0,", "\t\ttimer_display_threshold = 0,\n\t\ttotally_unknown = 7,")
        path.write_text(text, encoding="utf-8")
        verdict = _derive(mod, _fixture_pins(mod), cocktail="1H")
        assert verdict["ok"] is False
        assert "ranked_source_unknown_config_key" in verdict["problems"]
    finally:
        tmp.cleanup()


def test_unknown_layer_key_fails_closed():
    tmp, mod = _copy_mod()
    try:
        path = mod / "layers" / "pvp_timer.lua"
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            "\tpvp_timer_base_seconds = 60,",
            "\tpvp_timer_base_seconds = 60,\n\tsurprise_key = true,",
        )
        path.write_text(text, encoding="utf-8")
        verdict = _derive(mod, _fixture_pins(mod), cocktail="1H")
        assert verdict["ok"] is False
        assert "ranked_source_unknown_layer_key" in verdict["problems"]
    finally:
        tmp.cleanup()


def test_nil_override_injection_fails_closed():
    tmp, mod = _copy_mod()
    try:
        path = mod / "core.lua"
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            "\t\ttimer_display_threshold = 0,",
            "\t\ttimer_display_threshold = 0,\n\t\tnormal_bosses = \"bl_mp_nemesis\",",
        )
        path.write_text(text, encoding="utf-8")
        verdict = _derive(mod, _fixture_pins(mod), cocktail="1H")
        assert verdict["ok"] is False
        # The injected nil-override key is rejected either as an unknown config
        # key or explicitly as an injected override; both fail closed.
        text = " ".join(verdict["problems"])
        assert "normal_bosses" in text or "ranked_source_unknown_config_key" in text
    finally:
        tmp.cleanup()


def test_edited_cocktail_composition_fails_closed():
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="12H")
    assert verdict["ok"] is False
    assert "ranked_cocktail_shape_unexpected" in verdict["problems"]


def test_cocktail_shape_and_count_helpers():
    assert rec.cocktail_default_shape_ok("1H") is True
    assert rec.cocktail_default_shape_ok("111H") is True
    assert rec.cocktail_default_shape_ok("12H") is False
    assert rec.cocktail_default_shape_ok("111") is False
    assert rec.cocktail_default_shape_ok("") is False
    assert rec.expected_cocktail_for_count(3) == "111H"


def test_canonical_binding_is_domain_separated_and_sensitive():
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="1H")
    lobby = dict(verdict["host"])
    resolved = verdict["resolved"]
    base = rec.canonical_bytes(lobby, resolved)
    assert base.startswith(rec.DOMAIN + "|")
    assert rec.fnv1a32_hex(base) == verdict["checksum"]
    changed = dict(lobby)
    changed["the_order"] = False
    assert rec.canonical_bytes(changed, resolved) != base
    assert rec.fnv1a32_hex(rec.canonical_bytes(changed, resolved)) != verdict["checksum"]
    # nil and empty string are distinct in the typed binding.
    assert rec._type_tag(None) != rec._type_tag("")


def test_domain_differs_from_legacy_major_league():
    # The new binding must never be byte-identical to a legacy-shaped digest.
    assert rec.DOMAIN == "aisparring.ranked_effective_config.v1"
    assert "major_league" not in rec.DOMAIN


def test_canonical_requires_every_enumerated_key():
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="1H")
    lobby = dict(verdict["host"])
    resolved = dict(verdict["resolved"])
    rec.canonical_bytes(lobby, resolved)  # complete table is accepted
    missing = dict(lobby)
    del missing["cocktail"]
    try:
        rec.canonical_bytes(missing, resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_missing_lobby_key"
    else:
        raise AssertionError("missing required key was silently treated as nil")
    unknown = dict(lobby)
    unknown["surprise"] = 1
    try:
        rec.canonical_bytes(unknown, resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_unknown_lobby_key"
    else:
        raise AssertionError("unknown key was accepted")
    missing_resolved = dict(resolved)
    del missing_resolved["is_disabled"]
    try:
        rec.canonical_bytes(lobby, missing_resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_missing_resolved_key"
    else:
        raise AssertionError("missing resolved key was accepted")


def _selection_catalog() -> dict:
    return {
        "decks": {
            "red": {"center_key": "b_red", "name": "Red Deck"},
            "blue": {"center_key": "b_blue", "name": "Blue Deck"},
        },
        "stakes": {
            "white": {"index": 1, "max_index": 8},
            "gold": {"index": 8, "max_index": 8},
        },
    }


def _selection(**overrides) -> dict:
    base = {
        "schema": rec.SELECTION_SCHEMA,
        "deck_key": "red",
        "back_key": "b_red",
        "back_name": "Red Deck",
        "stake_key": "white",
        "stake_index": 1,
    }
    base.update(overrides)
    return base


def test_selection_contract_accepts_and_refuses():
    catalog = _selection_catalog()
    assert rec.validate_selection(_selection(), catalog)["ok"] is True
    # Unknown deck/stake fail closed.
    assert rec.validate_selection(_selection(deck_key="green", back_key="b_green", back_name="Green"), catalog)["ok"] is False
    assert rec.validate_selection(_selection(stake_key="planet"), catalog)["ok"] is False
    # A clamped/out-of-range stake is refused (MAX_STAKE).
    assert "ranked_selection_stake_clamped" in rec.validate_selection(
        _selection(stake_index=9), catalog
    )["problems"]
    # An ambiguous Back center (two decks) is refused.
    ambiguous = {"decks": {
        "red": {"center_key": "b_shared", "name": "Red Deck"},
        "blue": {"center_key": "b_shared", "name": "Blue Deck"},
    }, "stakes": catalog["stakes"]}
    verdict = rec.validate_selection(_selection(back_key="b_shared"), ambiguous)
    assert "ranked_selection_deck_ambiguous" in verdict["problems"]
    # An ambiguous Back NAME (the value that travels on the wire) is refused.
    name_ambiguous = {"decks": {
        "red": {"center_key": "b_red", "name": "Shared Name"},
        "blue": {"center_key": "b_blue", "name": "Shared Name"},
    }, "stakes": catalog["stakes"]}
    verdict = rec.validate_selection(_selection(back_name="Shared Name"), name_ambiguous)
    assert "ranked_selection_name_ambiguous" in verdict["problems"]


def test_post_start_selection_check_retries_and_aborts():
    selection = _selection()
    retry = rec.check_post_start_selection(selection, None, None)
    assert retry["retry"] is True and retry["ok"] is False
    assert rec.check_post_start_selection(selection, "b_red", 1)["ok"] is True
    mismatch = rec.check_post_start_selection(selection, "b_blue", 1)
    assert mismatch["ok"] is False and "ranked_post_start_back_mismatch" in mismatch["problems"]
    stake_mismatch = rec.check_post_start_selection(selection, "b_red", 2)
    assert "ranked_post_start_stake_mismatch" in stake_mismatch["problems"]


def test_ranked_requires_validated_selection():
    # No selection: fail closed with ranked_draft_unbound, never a fallback deck.
    verdict = rec.derive_effective_config(PINNED_MOD, PINS_PATH, cocktail="1H", catalog=_catalog())
    assert verdict["ok"] is False
    assert "ranked_draft_unbound" in verdict["problems"]
    # A selection that does not match its catalog binding is refused.
    bad = _selection()
    bad["back_name"] = "Blue Deck"
    verdict = rec.derive_effective_config(
        PINNED_MOD, PINS_PATH, cocktail="1H", selection=bad, catalog=_catalog()
    )
    assert verdict["ok"] is False
    assert "ranked_selection_deck_mismatch" in verdict["problems"]
    # A valid selection binds back/stake into the expected lobby.
    ok = rec.derive_effective_config(
        PINNED_MOD, PINS_PATH, cocktail="1H", selection=_selection(), catalog=_catalog()
    )
    assert ok["ok"] is True, ok["problems"]
    assert ok["host"]["back"] == "Red Deck" and ok["host"]["stake"] == 1


def test_catalog_role_parity_and_cocktail_exclusion():
    host = {
        "schema": ruleset_contract.RANKED_CATALOG_SCHEMA,
        "eligible_decks": ["b_red", "b_blue"],
        "decks": {
            "red": {"center_key": "b_red", "name": "Red Deck"},
            "blue": {"center_key": "b_blue", "name": "Blue Deck"},
        },
        "stakes": {"white": {"index": 1, "max_index": 8}},
    }
    guest = json.loads(json.dumps(host))
    assert ruleset_contract.build_ranked_catalog(host, guest)["ok"] is True
    # Mismatched role catalogs are refused.
    guest["eligible_decks"] = ["b_red"]
    assert "ranked_catalog_role_parity" in ruleset_contract.build_ranked_catalog(host, guest)["problems"]
    # A missing guest measurement is refused outright (both roles mandatory).
    assert "ranked_catalog_guest_missing" in ruleset_contract.build_ranked_catalog(host)["problems"]
    # Duplicate eligible decks and Cocktail presence are refused (both roles).
    dup = json.loads(json.dumps(host))
    dup["eligible_decks"] = ["b_red", "b_red"]
    assert "ranked_catalog_eligible_duplicate" in ruleset_contract.build_ranked_catalog(dup, dup)["problems"]
    cocktail = json.loads(json.dumps(host))
    cocktail["eligible_decks"] = ["b_red", "b_mp_cocktail"]
    assert "ranked_catalog_cocktail_present" in ruleset_contract.build_ranked_catalog(cocktail, cocktail)["problems"]


def test_measured_catalog_derives_exact_cocktail_and_refuses_guesswork():
    measurement = {
        "schema": ruleset_contract.RANKED_CATALOG_SCHEMA,
        "eligible_decks": ["b_red", "b_blue"],
        "decks": {
            "red": {"center_key": "b_red", "name": "Red Deck"},
            "blue": {"center_key": "b_blue", "name": "Blue Deck"},
        },
        "stakes": {"white": {"index": 1, "max_index": 8}},
    }
    guest = json.loads(json.dumps(measurement))
    built = ruleset_contract.build_ranked_catalog(measurement, guest)
    assert built["ok"] is True, built["problems"]
    assert built["cocktail"] == "11H"
    assert built["count"] == 2
    # A single-role measurement is refused outright.
    assert "ranked_catalog_guest_missing" in ruleset_contract.build_ranked_catalog(measurement)["problems"]
    # No guessed count / invented nil: an absent eligible list fails closed.
    assert ruleset_contract.build_ranked_catalog({"schema": ruleset_contract.RANKED_CATALOG_SCHEMA}, guest)["ok"] is False
    # A bad schema is refused.
    assert ruleset_contract.build_ranked_catalog({"schema": "other", "eligible_decks": ["b_red"]}, guest)["ok"] is False
    # A malformed deck mapping fails closed.
    bad = dict(measurement)
    bad["decks"] = {"red": {"center_key": "b_red"}}
    assert ruleset_contract.build_ranked_catalog(bad, guest)["ok"] is False


def test_production_ranked_reader_fails_closed_without_catalog():
    with tempfile.TemporaryDirectory() as tmp:
        _write_staged_ranked(tmp)
        verdict = ruleset_contract.production_ranked_reader()(tmp)
        assert verdict["ok"] is False
        assert verdict["code"] == "ranked_catalog_unmeasured"


def test_production_pins_path_is_fixed_and_unoverridable():
    path = rec.production_pins_path()
    assert path == REPO / "docs" / "RANKED_SOURCE_PINS_V1.json"
    pins = rec.load_production_pins()
    assert pins["schema"] == rec.PIN_SCHEMA
    assert rec.RANKED_CONFIG_SCHEMA == rec.DOMAIN
    # The production path takes no caller repo_root and cannot be substituted.
    import inspect

    assert list(inspect.signature(rec.production_pins_path).parameters) == []
    # derive_effective_config requires explicit pins; it never silently skips
    # verification.
    try:
        rec.derive_effective_config(PINNED_MOD, cocktail="1H")
    except TypeError:
        pass
    else:
        raise AssertionError("derive_effective_config accepted a missing pins_path")


def _base_views() -> tuple:
    verdict = _derive(PINNED_MOD, PINS_PATH, cocktail="1H")
    assert verdict["ok"] is True, verdict["problems"]
    return dict(verdict["host"]), dict(verdict["resolved"])


def _expect_field_type(lobby, resolved):
    try:
        rec.canonical_bytes(lobby, resolved)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_field_type", error.code
        return
    raise AssertionError("bad field type was accepted")


def test_field_type_schema_refuses_every_swap():
    lobby, resolved = _base_views()
    swaps = [
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
    assert len(swaps) == 14
    for scope, key, value in swaps:
        mutated_lobby, mutated_resolved = dict(lobby), dict(resolved)
        (mutated_lobby if scope == "lobby" else mutated_resolved)[key] = value
        _expect_field_type(mutated_lobby, mutated_resolved)


def test_required_nil_and_nil_override_are_refused():
    lobby, resolved = _base_views()
    # nil in a required bool/int/str field is a field-type error, never accepted.
    for key in ("starting_lives", "the_order", "back"):
        mutated = dict(lobby)
        mutated[key] = None
        _expect_field_type(mutated, resolved)
    # weekly and the 7 overrides are nil only: any real value is refused.
    for key in ("weekly", "normal_bosses", "pvp_timer_base_seconds", "timer_base_multiplier"):
        for bad in (1, True, "x", "", []):
            mutated = dict(lobby)
            mutated[key] = bad
            _expect_field_type(mutated, resolved)
    # The valid typed-nil/empty distinction is preserved for allowed str fields.
    assert rec._type_tag(None) != rec._type_tag("")


def test_control_bytes_utf8_length_and_separators():
    lobby, resolved = _base_views()
    for bad in ("a\tb", "a\x00b", "a\x1fb", "a\x7fb", "a|b", "a=b", "a\nb", "a\rb"):
        mutated = dict(lobby)
        mutated["challenge"] = bad
        try:
            rec.canonical_bytes(mutated, resolved)
        except rec.RankedConfigError as error:
            assert error.code in ("ranked_canonical_field_type", "ranked_canonical_string_invalid"), repr(bad)
        else:
            raise AssertionError(f"control/separator accepted: {bad!r}")
    # Byte-length parity: 65 ASCII bytes exceeds the 64-byte bound.
    mutated = dict(lobby)
    mutated["challenge"] = "a" * 65
    _expect_field_type(mutated, resolved)


def test_resolved_list_density_and_unknown_keys():
    lobby, resolved = _base_views()
    # Empty list item is refused (dense list of non-empty str).
    mutated = dict(resolved)
    mutated["modifier_list"] = ["pressure_timer", ""]
    _expect_field_type(lobby, mutated)
    # A non-list value is refused.
    mutated = dict(resolved)
    mutated["active_layer_chain"] = {"standard": True}
    _expect_field_type(lobby, mutated)
    # Unknown resolved key is refused.
    mutated = dict(resolved)
    mutated["extra_key"] = True
    try:
        rec.canonical_bytes(lobby, mutated)
    except rec.RankedConfigError as error:
        assert error.code == "ranked_canonical_unknown_resolved_key"
    else:
        raise AssertionError("unknown resolved key accepted")


def _write_staged_ranked(staging_root) -> Path:
    mods = Path(staging_root) / "roles" / "human" / "appdata" / "Roaming" / "Balatro" / "Mods"
    mod = mods / "Multiplayer"
    shutil.copytree(PINNED_MOD, mod)
    (mod / "manifest.json").write_text(json.dumps({"id": "Multiplayer"}), encoding="utf-8")
    return mod


def test_expected_ranked_config_from_staged_source():
    with tempfile.TemporaryDirectory() as tmp:
        _write_staged_ranked(tmp)
        verdict = ruleset_contract.expected_ranked_config(
            tmp, cocktail="11H", pins_path=PINS_PATH, selection=_selection(), catalog=_catalog()
        )
        assert verdict["ok"] is True, verdict["problems"]
        assert verdict["ruleset_id"] == "ruleset_mp_standard_ranked"
        assert verdict["ruleset_key"] == "standard_ranked"
        assert verdict["gamemode"] == "gamemode_mp_attrition"
        assert tuple(verdict["declared_layers"]) == ("standard", "ranked", "pvp_timer")
        assert tuple(verdict["active_layer_chain"]) == ("standard", "ranked", "pvp_timer", "standard_ranked")
        assert verdict["config_digest"] == _derive(
            PINNED_MOD, PINS_PATH, cocktail="11H"
        )["checksum"]


def test_expected_ranked_config_rejects_staged_drift():
    with tempfile.TemporaryDirectory() as tmp:
        mod = _write_staged_ranked(tmp)
        target = mod / "rulesets" / "ranked.lua"
        target.write_text(target.read_text(encoding="utf-8") + "\n-- drift\n", encoding="utf-8")
        verdict = ruleset_contract.expected_ranked_config(
            tmp, cocktail="1H", pins_path=PINS_PATH, selection=_selection(), catalog=_catalog()
        )
        assert verdict["ok"] is False
        assert any(p.startswith("ranked_source_pin_drift:") for p in verdict["problems"])


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
