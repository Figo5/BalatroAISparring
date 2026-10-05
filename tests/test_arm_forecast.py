#!/usr/bin/env python3
"""The Arm forecast pinned to private native blind and hand-upgrade functions."""
import argparse
import copy
import importlib
import math
import re

import benchmark_policy as bp


def native_function(path, header):
    body = path.read_text(encoding="utf-8")
    start = body.index(header)
    return body[start:body.index("\nend", start) + 4]


def native_fixture(lua, required):
    dump = bp.REPO / "staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump"
    utils = bp.REPO / "work/local-ownership/native-mods-source/smods/src/utils.lua"
    paths = [dump / "game.lua", dump / "blind.lua", dump / "functions/common_events.lua", utils]
    if not all(p.exists() for p in paths):
        assert not required, "Native Arm fixtures required for release"
        return None, None
    # Read actual installed public hand definitions; proprietary code/data
    # never leaves private staging and is not copied into this repository.
    names = {key: value[2] for key, value in bp.LEVEL_UP.items()}
    names.update(five="Five of a Kind", flush_house="Flush House", flush_five="Flush Five")
    game = paths[0].read_text(encoding="utf-8")
    hands = {}
    for key, name in names.items():
        row = re.search(r'\["' + re.escape(name) + r'"\]\s*=\s*\{([^\n]+)', game).group(1)
        hands[key] = {field: int(re.search(r'\b' + field + r'\s*=\s*(\d+)', row).group(1))
                      for field in ("chips", "mult", "level", "l_chips", "l_mult")}
        assert (hands[key]["chips"], hands[key]["mult"]) == bp.HAND_BASE[key]
    lua.execute("""
        Blind={}; SMODS={Scoring_Parameter={obj_buffer={'chips','mult'}},
            Scoring_Parameters={chips={default_value=0},mult={default_value=1}},
            calculate_context=function() end};
        Handy={animation_skip={should_skip_messages=function() return false end}};
        G={GAME={hands={}},E_MANAGER={add_event=function() end}};
        Event=function(e) return e end; update_hand_text=function() end;
        localize=function(s) return s end; delay=function() end;
    """)
    lua.execute(native_function(utils, "function SMODS.upgrade_poker_hands(args)"))
    lua.execute(native_function(paths[2], "function level_up_hand(card, hand, instant, amount, statustext)"))
    lua.execute(native_function(paths[1], "function Blind:debuff_hand(cards, hand, handname, check)"))
    run = lua.eval("""function(name,entry,disabled,check)
        local e={}; for k,v in pairs(entry) do e[k]=v end; G.GAME.hands={[name]=e};
        local b={name='The Arm',disabled=disabled,config={blind={}},
            children={animatedSprite={}},wiggle=function() end};
        local debuffed=Blind.debuff_hand(b,{}, {},name,check);
        assert(not debuffed,'The Arm changes level, not hand legality');
        return e,b.triggered==true
    end""")
    return hands, run


def cards(ranks, suits):
    return [{"rank": rank, "suit": suit} for rank, suit in zip(ranks, suits)]


HANDS = {
    "high_card": cards(["King"], ["Spades"]),
    "pair": cards(["King"] * 2, ["Spades", "Hearts"]),
    "two_pair": cards(["King", "King", "2", "2"], bp.SUITS),
    "three": cards(["7"] * 3, bp.SUITS[:3]),
    "straight": cards(["2", "3", "4", "5", "6"], bp.SUITS + ["Spades"]),
    "flush": cards(["Ace", "8", "10", "6", "3"], ["Hearts"] * 5),
    "full_house": cards(["Queen"] * 3 + ["6"] * 2, bp.SUITS + ["Hearts"]),
    "four": cards(["Jack"] * 4, bp.SUITS),
    "straight_flush": cards(["2", "3", "4", "5", "6"], ["Hearts"] * 5),
    "five": cards(["3"] * 5, bp.SUITS + ["Spades"]),
    "flush_house": cards(["2"] * 3 + ["3"] * 2, ["Hearts"] * 5),
    "flush_five": cards(["4"] * 5, ["Hearts"] * 5),
}


def model_probe(lua):
    policy = lua.execute("return assert(loadfile(...))()", str(bp.REPO / "AISparring/ai/baseline_policy.lua"))
    readable = policy["readable_source"]("expert")
    prefix = readable[:readable.index("return function(obs, actions)")]
    return lua.execute(prefix + """return function(hand,name,level,balanced,blind)
        set_rules({}); CURRENT_EFF={}; JOKER_CACHE={}; WORK=0;
        BALANCED=balanced; HAND_BLIND=blind; LEVELS={[name]=level};
        return (estimate(hand,{}, {}))
    end""")


def pipeline_cases(hands):
    hand = cards(["Ace", "7", "8", "9", "3", "King", "King", "2"],
                 ["Hearts"] * 5 + ["Spades", "Clubs", "Diamonds"])
    levels = {"pair": {"level": 4, "chips": 55, "mult": 5}}
    base = dict(hand=hand, jokers=[], levels=levels, hands_left=4, discards_left=0,
                chips=0, requirement=1000000000, pvp=False, deck="Red Deck", boss="bl_arm")
    out = [base, dict(base, blind_disabled=True), dict(base, boss=None)]
    # Identical catalogs with randomized public hand levels: candidates are
    # scored using native post-Arm levels, not the policy's forecast helper.
    import random
    rng = random.Random(2051005)
    for i in range(60):
        sc = bp.make_scenario(rng)
        sc.update(boss="bl_arm", discards_left=0, requirement=1000000000, chips=0,
                  pvp=False, deck="Plasma Deck" if i % 2 else "Red Deck")
        sc["hand"] = [{"rank": c["rank"], "suit": c["suit"]} for c in sc["hand"]]
        sc["jokers"] = []
        # Explicit levels ensure even early families exercise the decrement.
        sc["levels"] = {}
        for name, definition in hands.items():
            if name not in bp.LEVEL_UP:
                continue
            level = rng.randint(1, 8)
            sc["levels"][name] = {"level": level,
                "chips": definition["chips"] + definition["l_chips"] * (level - 1),
                "mult": definition["mult"] + definition["l_mult"] * (level - 1)}
        out.append(sc)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-all", action="store_true")
    required = parser.parse_args().require_all
    vectors = None
    for runtime in ("lupa.lua51", "lupa.luajit21"):
        module = importlib.import_module(runtime)
        native = module.LuaRuntime(unpack_returned_tuples=True)
        hands, run = native_fixture(native, required)
        if hands is None:
            print("SKIP native fixtures unavailable")
            continue
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        probe = model_probe(lua)
        checked = 0
        for name, definition in hands.items():
            assert bp.classify(HANDS[name])[0] == name
            for level in (0, 1, 2, 4, 100000):
                entry = dict(definition, level=level,
                    chips=max(0, definition["chips"] + definition["l_chips"] * (level - 1)),
                    mult=max(1, definition["mult"] + definition["l_mult"] * (level - 1)))
                for disabled, check in ((False, False), (True, False), (False, True)):
                    result, triggered = run(name, bp.to_lua(native, entry), disabled, check)
                    after = bp.from_lua(result)
                    active = not disabled and level > 1
                    assert triggered == active
                    assert after["level"] == level - int(active and not check)
                    for balanced in (False, True):
                        expected = bp.reference_score(HANDS[name], [], [], {name: after}, balanced=balanced)
                        estimate = probe(bp.to_lua(lua, HANDS[name]), name, bp.to_lua(lua, entry), balanced,
                                         "bl_arm" if active and not check else None)
                        assert math.isclose(estimate, expected, rel_tol=1e-12), (name, level, disabled, check, balanced)
                        checked += 1
            # Non-native displayed progression stays conservative, not guessed.
            changed = dict(definition, level=4, chips=definition["chips"] + definition["l_chips"] * 3 + 1,
                           mult=definition["mult"] + definition["l_mult"] * 3)
            assert probe(bp.to_lua(lua, HANDS[name]), name, bp.to_lua(lua, changed), False, "bl_arm") == bp.reference_score(HANDS[name], [], [], {name: changed})
        cases = pipeline_cases(hands)
        rows = bp.from_lua(lua.execute(bp.HARNESS)(str(bp.REPO), bp.to_lua(lua, bp.lua_scenarios(cases)),
                                                 bp.to_lua(lua, ["competitive", "major_league", "expert"])))
        decisions = []
        for sc, row in zip(cases, rows):
            predicted = copy.deepcopy(sc["levels"])
            for name, entry in predicted.items():
                native_entry = dict(hands[name], **entry)
                after, _ = run(name, bp.to_lua(native, native_entry), sc.get("blind_disabled") or sc.get("boss") != "bl_arm", False)
                predicted[name] = bp.from_lua(after)
            values = {}
            for candidate in row["candidates"]:
                if candidate["type"] != "PLAY_CARDS":
                    continue
                indices = bp.refs_to_indices(candidate["refs"])
                played = [sc["hand"][i] for i in indices]
                held = [c for i, c in enumerate(sc["hand"]) if i not in indices]
                values[candidate["id"]] = bp.reference_score(played, held, [], predicted,
                                                           balanced=sc["deck"] == "Plasma Deck")
            for choice in row["choices"]:
                assert choice["ok"] and choice["type"] == "PLAY_CARDS", (runtime, row)
                assert math.isclose(values[choice["id"]], max(values.values())), (runtime, row, values)
                assert choice["instructions"] < 1000000
                decisions.append(choice["id"])
        assert decisions[0] != decisions[3] == decisions[6], "active Arm must change the crafted choice"
        assert vectors is None or vectors == decisions, "Lua engines must agree"
        vectors = decisions
        print(f"PASS {runtime}: {checked} native forecasts across 12 hand types; {len(decisions)} legal best-offered decisions, disabled/state reset, budget")


if __name__ == "__main__":
    main()
