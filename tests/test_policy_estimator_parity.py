#!/usr/bin/env python3
"""Crafted edge hands: the Lua policy estimator and the Python reference agree.

Each scenario runs through the real adapter/reader/observation/sandbox path
(tests/benchmark_policy.py harness). Competitive and Major League must pick a
play whose reference score equals the best offered play. Also pins a few
reference values against hand-computed Balatro arithmetic.
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import benchmark_policy as bench  # noqa: E402


def card(rank, suit, center=None, edition=None, seal=None):
    out = {"rank": rank, "suit": suit}
    if center:
        out["center"] = center
    if edition:
        out["edition"] = edition
    if seal:
        out["seal"] = seal
    return out


FILL = [card("3", "Clubs"), card("7", "Diamonds"), card("9", "Spades")]

EDGE = {
    "glass_holo_pair_vs_kings": [card("2", "Hearts", "m_glass", "holo"), card("2", "Spades", "m_glass", "holo"),
                                 card("King", "Clubs"), card("King", "Diamonds"), card("4", "Clubs")] + FILL,
    "lucky_pair": [card("5", "Hearts", "m_lucky"), card("5", "Spades", "m_lucky"), card("Queen", "Clubs"),
                   card("Queen", "Diamonds"), card("4", "Clubs")] + FILL,
    "stone_in_quads": [card("8", "Hearts"), card("8", "Spades"), card("8", "Clubs"), card("8", "Diamonds"),
                       card("Ace", "Clubs", "m_stone")] + FILL,
    "ace_low_straight": [card("Ace", "Hearts"), card("2", "Spades"), card("3", "Hearts"), card("4", "Diamonds"),
                         card("5", "Hearts"), card("King", "Clubs"), card("King", "Spades"), card("Jack", "Diamonds")],
    "wild_flush": [card("2", "Hearts"), card("6", "Hearts"), card("9", "Hearts"), card("Jack", "Hearts"),
                   card("4", "Spades", "m_wild"), card("Queen", "Clubs"), card("Queen", "Diamonds"), card("5", "Clubs")],
}
EDGE_JOKERS = {
    "glass_holo_pair_vs_kings": [],
    "lucky_pair": ["j_fibonacci"],
    "stone_in_quads": ["j_family"],
    "ace_low_straight": ["j_crazy", "j_scholar"],
    "wild_flush": ["j_droll", "j_lusty_joker"],
}


def test_reference_pins():
    # Pair of Kings: (10 + 10 + 10) chips x 2 mult.
    assert bench.reference_score([card("King", "Clubs"), card("King", "Diamonds")], [], []) == 60
    # Lucky: expected +4 mult on a scoring card (1 in 5 for +20).
    lucky = bench.reference_score([card("5", "Hearts", "m_lucky"), card("5", "Spades")], [], [])
    assert lucky == (10 + 5 + 5) * (2 + 4), lucky
    # Glass x2 before holo +10: (2+10)x2 = 24? pair base 2 -> x2 = 4 -> +10 = 14.
    glass_holo = bench.reference_score([card("2", "Hearts", "m_glass", "holo"), card("2", "Spades")], [], [])
    assert glass_holo == (10 + 2 + 2) * 14, glass_holo
    # Red seal + Photograph: the first face card scores twice, x2 each time.
    photo = bench.reference_score([card("King", "Hearts", seal="Red")], [], ["j_photograph"])
    assert photo == (5 + 10 + 10) * (1 * 2 * 2), photo
    # Stone inside four of a kind scores its 50 chips, never its rank.
    quads = bench.reference_score(
        [card("8", "Hearts"), card("8", "Spades"), card("8", "Clubs"), card("8", "Diamonds"), card("Ace", "Clubs", "m_stone")],
        [], [],
    )
    assert quads == (60 + 32 + 50) * 7, quads


def test_policy_matches_reference_on_edge_hands():
    lua = importlib.import_module("lupa.lua51").LuaRuntime(unpack_returned_tuples=True)
    harness = lua.execute(bench.HARNESS)
    scenarios = []
    for name, hand in EDGE.items():
        scenarios.append({
            "hand": hand,
            "jokers": EDGE_JOKERS[name],
            "hands_left": 3,
            "discards_left": 0,
            "chips": 0,
            "requirement": 100000,
            "pvp": False,
            "name": name,
        })
    rows = bench.from_lua(harness(str(bench.REPO), bench.to_lua(lua, scenarios),
                                  bench.to_lua(lua, ["competitive", "major_league"])))
    for row in rows:
        scenario = scenarios[row["scenario"] - 1]
        hand, jokers = scenario["hand"], scenario["jokers"]
        values = {}
        for candidate in row["candidates"]:
            if candidate["type"] == "PLAY_CARDS":
                idx = bench.refs_to_indices(candidate["refs"])
                played = [hand[i] for i in idx]
                held = [hand[i] for i in range(len(hand)) if i not in idx]
                values[candidate["id"]] = bench.reference_score(played, held, jokers)
        best = max(values.values())
        for choice in row["choices"]:
            assert choice["ok"], (scenario["name"], choice)
            assert choice["type"] == "PLAY_CARDS", (scenario["name"], choice)
            assert abs(values[choice["id"]] - best) < 1e-6, (scenario["name"], choice["difficulty"], values[choice["id"]], best)


def main() -> int:
    tests = [test_reference_pins, test_policy_matches_reference_on_edge_hands]
    failures = 0
    for test in tests:
        try:
            test()
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {test.__name__}: {type(error).__name__}: {error}")
        else:
            print(f"ok   {test.__name__}")
    print(f"\n{len(tests) - failures}/{len(tests)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
