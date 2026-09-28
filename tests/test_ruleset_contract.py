#!/usr/bin/env python3
"""Ruleset-contract tests: strict Major League derivation (M10 / docs/MAJOR_LEAGUE_DIGEST.md).

Everything runs against synthetic temp trees and inline Lua sources: no live path,
game, server or network is touched. The fixtures assert that a mutated/unsupported
ruleset source is refused rather than approximated, and that the derived digest is
the shared service implementation.
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import practice_service  # noqa: E402
import ruleset_contract  # noqa: E402
import staging  # noqa: E402

PINNED_SOURCE = Path(REPO / "work" / "reference" / "mp" / "rulesets" / "majorleague.lua").read_text(
    encoding="utf-8"
)

STAGED_SOURCE = """MP.Ruleset({
\tkey = "majorleague",
\tforced_gamemode = "gamemode_mp_attrition",
\tforce_lobby_options = function(self)
\t\tMP.LOBBY.config.timer_base_seconds = 180
\t\tMP.LOBBY.config.timer_forgiveness = 0
\t\tMP.LOBBY.config.the_order = false
\t\tMP.LOBBY.config.preview_disabled = true
\t\tMP.LOBBY.config.enemy_location_disabled = true
\t\tMP.LOBBY.config.timer_display_threshold = 180
\t\treturn true
\tend,
}):inject()
"""


def _write_staged(staging_root, source=STAGED_SOURCE):
    mods = Path(staging_root) / "roles" / "human" / "appdata" / "Roaming" / "Balatro" / "Mods"
    mod = mods / "Multiplayer"
    (mod / "rulesets").mkdir(parents=True, exist_ok=True)
    (mod / "manifest.json").write_text(json.dumps({"id": "Multiplayer"}), encoding="utf-8")
    (mod / "rulesets" / "majorleague.lua").write_text(source, encoding="utf-8")
    return mod


def test_parse_pinned_source_shape():
    parsed = ruleset_contract.parse_ruleset_source(PINNED_SOURCE)
    assert parsed["ok"] is True, parsed
    assert parsed["ruleset_id"] == "ruleset_mp_majorleague"
    assert parsed["gamemode"] == "gamemode_mp_attrition"
    assert parsed["forced_options"] == {
        "timer_base_seconds": 180,
        "timer_forgiveness": 0,
        "the_order": False,
        "preview_disabled": True,
        "enemy_location_disabled": True,
        "timer_display_threshold": 180,
    }
    assert parsed["key_set"] == (
        "enemy_location_disabled",
        "preview_disabled",
        "the_order",
        "timer_base_seconds",
        "timer_display_threshold",
        "timer_forgiveness",
    )


def test_expected_ruleset_matches_shared_digest():
    with tempfile.TemporaryDirectory() as tmp:
        _write_staged(tmp)
        verdict = ruleset_contract.expected_ruleset(tmp)
        assert verdict["ok"] is True, verdict
        expected = practice_service.major_league_digest(
            "ruleset_mp_majorleague",
            "gamemode_mp_attrition",
            {
                "timer_base_seconds": 180,
                "timer_forgiveness": 0,
                "the_order": False,
                "preview_disabled": True,
                "enemy_location_disabled": True,
                "timer_display_threshold": 180,
            },
        )
        assert verdict["config_digest"] == expected
        assert ruleset_contract.expected_config_digest(tmp) == expected


def test_unsupported_statement_is_refused():
    mutated = STAGED_SOURCE.replace(
        "\t\treturn true",
        "\t\tMP.LOBBY.config.timer_base_seconds = 1 + 1\n\t\treturn true",
    )
    parsed = ruleset_contract.parse_ruleset_source(mutated)
    assert parsed["ok"] is False
    assert "unsupported_statement" in parsed["problems"]


def test_function_call_and_field_read_are_refused():
    for suspicious in (
        "\t\tMP.LOBBY.config.timer_base_seconds = os.time()",
        "\t\tlocal x = MP.LOBBY.config.timer_base_seconds",
        "\t\t-- a comment",
        "\t\tif true then end",
    ):
        mutated = STAGED_SOURCE.replace("\t\treturn true", suspicious + "\n\t\treturn true")
        parsed = ruleset_contract.parse_ruleset_source(mutated)
        assert parsed["ok"] is False, suspicious
        assert "unsupported_statement" in parsed["problems"], (suspicious, parsed)


def test_duplicate_and_wrong_gamemode_are_refused():
    duplicate = STAGED_SOURCE.replace(
        "\t\treturn true",
        "\t\tMP.LOBBY.config.timer_base_seconds = 5\n\t\treturn true",
    )
    assert "duplicate_option" in ruleset_contract.parse_ruleset_source(duplicate)["problems"]

    wrong_mode = STAGED_SOURCE.replace("gamemode_mp_attrition", "gamemode_mp_other")
    parsed = ruleset_contract.parse_ruleset_source(wrong_mode)
    assert "forced_gamemode_unexpected" in parsed["problems"]

    wrong_key = STAGED_SOURCE.replace('key = "majorleague"', 'key = "minorleague"')
    parsed = ruleset_contract.parse_ruleset_source(wrong_key)
    assert "ruleset_id_unexpected" in parsed["problems"]


def test_missing_body_is_refused():
    parsed = ruleset_contract.parse_ruleset_source('MP.Ruleset({ key = "majorleague" }):inject()')
    assert parsed["ok"] is False
    assert "force_lobby_options_body_missing" in parsed["problems"]


def test_expected_ruleset_refuses_mutated_and_missing_source():
    with tempfile.TemporaryDirectory() as tmp:
        mod = _write_staged(tmp)
        (mod / "rulesets" / "majorleague.lua").write_text(
            STAGED_SOURCE.replace("timer_base_seconds = 180", "timer_base_seconds = os.time()"),
            encoding="utf-8",
        )
        verdict = ruleset_contract.expected_ruleset(tmp)
        assert verdict["ok"] is False
        assert "unsupported_statement" in verdict["problems"]
        assert ruleset_contract.expected_config_digest(tmp) is None

        (mod / "rulesets" / "majorleague.lua").unlink()
        missing = ruleset_contract.expected_ruleset(tmp)
        assert missing["ok"] is False
        assert missing["code"] in ("ruleset_source_unreadable", "multiplayer_mod_unresolved")


def test_unresolved_multiplayer_mod_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        mods = Path(tmp) / "roles" / "human" / "appdata" / "Roaming" / "Balatro" / "Mods"
        mods.mkdir(parents=True, exist_ok=True)
        verdict = ruleset_contract.expected_ruleset(tmp)
        assert verdict["ok"] is False
        assert verdict["code"] == "multiplayer_mod_unresolved"


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
