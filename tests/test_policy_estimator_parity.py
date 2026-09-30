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

# Owned scaling Jokers with shown values (docs/SCALING_VALUES_DESIGN.md):
# engine ability fields for the harness, and (kind, value, step) for the
# reference. Each hand offers a choice the growth rule changes.
SCALED = {
    "ride_the_bus_face_resets": (
        [card("King", "Clubs"), card("King", "Diamonds"), card("7", "Hearts"), card("7", "Spades"),
         card("Ace", "Clubs"), card("3", "Diamonds"), card("9", "Hearts"), card("5", "Spades")],
        {"j_ride_the_bus": ({"mult": 20, "extra": 1}, ("mult", 20, 1))}),
    "wee_counts_scoring_twos": (
        [card("2", "Clubs"), card("2", "Diamonds"), card("3", "Hearts"), card("3", "Spades"),
         card("Jack", "Clubs"), card("8", "Diamonds"), card("9", "Hearts"), card("5", "Spades")],
        {"j_wee": ({"extra": {"chips": 40, "chip_mod": 8}}, ("chips", 40, 8))}),
    "runner_on_straights": (
        [card("5", "Clubs"), card("6", "Diamonds"), card("7", "Hearts"), card("8", "Spades"),
         card("9", "Clubs"), card("Ace", "Diamonds"), card("Ace", "Hearts"), card("2", "Spades")],
        {"j_runner": ({"extra": {"chips": 60, "chip_mod": 15}}, ("chips", 60, 15))}),
    "square_on_four_cards": (
        [card("4", "Clubs"), card("4", "Diamonds"), card("6", "Hearts"), card("6", "Spades"),
         card("King", "Clubs"), card("King", "Diamonds"), card("9", "Hearts"), card("2", "Spades")],
        {"j_square": ({"extra": {"chips": 16, "chip_mod": 4}}, ("chips", 16, 4))}),
    "trousers_and_green_and_fractional_hologram": (
        [card("10", "Clubs"), card("10", "Diamonds"), card("Queen", "Hearts"), card("Queen", "Spades"),
         card("Ace", "Clubs"), card("Ace", "Diamonds"), card("3", "Hearts"), card("5", "Spades")],
        {"j_trousers": ({"mult": 6, "extra": 2}, ("mult", 6, 2)),
         "j_green_joker": ({"mult": 4, "extra": {"hand_add": 1, "discard_sub": 1}}, ("mult", 4, 1)),
         "j_hologram": ({"x_mult": 1.25}, ("xmult", 1.25, 0))}),
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
    # Ride the Bus: +1 then scores, unless a face card scores (reset to 0).
    bus = {"j_ride_the_bus": ("mult", 20, 1)}
    sevens = bench.reference_score([card("7", "Hearts"), card("7", "Spades")], [], ["j_ride_the_bus"], scaled=bus)
    assert sevens == (10 + 14) * (2 + 21), sevens
    kings = bench.reference_score([card("King", "Clubs"), card("King", "Hearts")], [], ["j_ride_the_bus"], scaled=bus)
    assert kings == 60, kings
    # Wee Joker grows per scoring 2, each retrigger included.
    wee = bench.reference_score([card("2", "Hearts", seal="Red"), card("2", "Spades")], [], ["j_wee"],
                                scaled={"j_wee": ("chips", 40, 8)})
    assert wee == (10 + 2 * 3 + 40 + 3 * 8) * 2, wee
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
    for name, (hand, spec) in SCALED.items():
        scenarios.append({
            "hand": hand,
            "jokers": list(spec),
            "abilities": {key: fields for key, (fields, _) in spec.items()},
            "scaled": {key: ref for key, (_, ref) in spec.items()},
            "hands_left": 3,
            "discards_left": 0,
            "chips": 0,
            "requirement": 100000,
            "pvp": False,
            "name": name,
        })
    rows = bench.from_lua(harness(str(bench.REPO), bench.to_lua(lua, scenarios),
                                  bench.to_lua(lua, ["competitive", "major_league"])))
    assert len(rows) == len(scenarios), (len(rows), len(scenarios))
    for row in rows:
        scenario = scenarios[row["scenario"] - 1]
        hand, jokers = scenario["hand"], scenario["jokers"]
        scaled = scenario.get("scaled")
        values = {}
        for candidate in row["candidates"]:
            if candidate["type"] == "PLAY_CARDS":
                idx = bench.refs_to_indices(candidate["refs"])
                played = [hand[i] for i in idx]
                held = [hand[i] for i in range(len(hand)) if i not in idx]
                values[candidate["id"]] = bench.reference_score(played, held, jokers, scaled=scaled)
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
