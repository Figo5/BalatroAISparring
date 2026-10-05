#!/usr/bin/env python3
"""Deck/Joker interaction checks through the real observation and sandbox.

Native rules are loaded only from private local fixtures, never distributed.
Seeded decision scenarios are model agreement checks, not multiplayer win rates.
"""
import argparse
import importlib
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import benchmark_policy as bp


def native_rules(lua, required):
    dump = bp.REPO / "staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump"
    back = dump / "back.lua"
    utils = bp.REPO / "work/local-ownership/native-mods-source/smods/src/utils.lua"
    if not back.exists() or not utils.exists():
        if required:
            raise AssertionError("native rules fixtures required for release")
        print("SKIP native rule pins: private fixtures unavailable")
        return
    body = back.read_text(encoding="utf-8")
    trigger = body[body.index("function Back:trigger_effect(args)"):]
    trigger = trigger[:trigger.index("\nend") + 4]
    lua.execute("Back={}; G={E_MANAGER={add_event=function() end}}; Event=function(v) return v end; update_hand_text=function() end; delay=function() end")
    lua.execute(trigger)
    actual = lua.eval("function(chips,mult) local a,b=Back.trigger_effect({name='Plasma Deck',effect={center={}}},{context='final_scoring_step',chips=chips,mult=mult}); return a*b end")
    for chips, mult, expected in ((30, 2, 256), (46, 1, 529), (92, 10, 2601), (35, 10.5, 484)):
        assert actual(chips, mult) == expected
    body = utils.read_text(encoding="utf-8")
    start = body.index("function SMODS.smeared_check(card, suit)")
    function = body[start:body.index("\nend", start) + 4]
    lua.execute("SMODS={}; find_joker=function() return {true} end")
    lua.execute(function)
    check = lua.eval("function(a,b) return SMODS.smeared_check({base={suit=a}},b) end")
    for a in bp.SUITS:
        for b in bp.SUITS:
            assert bool(check(a, b)) == ((a in ("Hearts", "Diamonds")) == (b in ("Hearts", "Diamonds")))
    def native_function(path, header):
        text = path.read_text(encoding="utf-8")
        start = text.index(header)
        return text[start:text.index("\nend", start) + 4]
    lua.execute("Blind={}; Card={}")
    lua.execute(native_function(dump / "blind.lua", "function Blind:modify_hand(cards, poker_hands, text, mult, hand_chips, scoring_hand)"))
    flint = lua.eval("function(chips,mult,disabled) return Blind.modify_hand({name='The Flint',disabled=disabled,config={blind={}}},{},{},'',mult,chips,{}) end")
    for chips, mult in ((5, 1), (35, 4), (65, 10.5), (0, 0)):
        m, c, active = flint(chips, mult, False)
        assert (m, c, active) == (max(1, int(mult / 2 + .5)), max(0, int(chips / 2 + .5)), True)
        assert flint(chips, mult, True) == (mult, chips, False)
    lua.execute(native_function(dump / "card.lua", "function Card:get_chip_bonus()"))
    bonus = lua.eval("function(nominal,base,permanent,stone) return Card.get_chip_bonus({base={nominal=nominal},ability={bonus=base,perma_bonus=permanent,effect=stone and 'Stone Card' or ''},config={center={}}}) end")
    assert bonus(11, 30, 40, False) == 81
    assert bonus(11, 50, 40, True) == 90
    print("PASS native Plasma flooring, Flint enabled/disabled, permanent chips and all 16 Smeared suit combinations")


def native_classifier(lua, required):
    """Run installed native hand evaluators, independently of both scorers."""
    dump = bp.REPO / "staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump"
    smods = bp.REPO / "work/local-ownership/native-mods-source/smods/src"
    paths = [dump / "functions/misc_functions.lua", dump / "card.lua",
             smods / "overrides.lua", smods / "game_object.lua", smods / "utils.lua"]
    if not all(path.exists() for path in paths):
        assert not required, "native hand evaluator fixtures required for release"
        return None

    def function(path, header):
        body = path.read_text(encoding="utf-8")
        start = body.index(header)
        return body[start:body.index("\nend", start) + 4]

    lua.execute("""
        local labels={'2','3','4','5','6','7','8','9','10','Jack','Queen','King','Ace'}
        SMODS={Ranks={},Rank={obj_buffer=labels,max_id={value=14}},
            Suit={obj_buffer={'Spades','Hearts','Clubs','Diamonds'}}}; Card={}; RULES={}
        for i,key in ipairs(labels) do SMODS.Ranks[key]={id=i+1,
            next={labels[i+1] or '2'},straight_edge=key=='Ace'} end
        SMODS.four_fingers=function() return RULES.j_four_fingers and 4 or 5 end
        SMODS.has_no_suit=function(c) return c.center=='m_stone' end
        SMODS.has_any_suit=function(c) return c.center=='m_wild' end
        find_joker=function(name) return name=='Smeared Joker' and RULES.j_smeared and {true} or {} end
    """)
    for path, header in ((paths[0], "function get_flush(hand)"),
                         (paths[0], "function get_X_same(num, hand, or_more)"),
                         (paths[0], "function get_highest(hand)"),
                         (paths[1], "function Card:is_suit(suit, bypass_debuff, flush_calc)"),
                         (paths[2], "function get_straight(hand, min_length, skip, wrap)"),
                         (paths[4], "function SMODS.smeared_check(card, suit)"),
                         (paths[4], "function SMODS.merge_lists(...)")):
        lua.execute(function(path, header))
    body = paths[3].read_text(encoding="utf-8")
    start = body.index("    local eval_functions = {")
    end = body.index("    for _, v in ipairs(handlist) do", start)
    evaluate = lua.execute(body[start:end] + "\nreturn eval_functions")
    lua.globals().EVALUATE = evaluate
    return lua.eval("""function(cards,jokers)
        RULES={}; for _,key in ipairs(jokers) do RULES[key]=true end
        local hand={}
        for i,c in ipairs(cards) do
            local card={base={suit=c.suit},center=c.center,debuff=c.debuff,index=i-1}
            -- Synthetic public identities only. Native Stone identity uses RNG;
            -- a unique negative ID has the same no-rank classification effect.
            card.get_id=function() return c.center=='m_stone' and -i or SMODS.Ranks[c.rank].id end
            card.get_nominal=function() return c.center=='m_stone' and -1 or SMODS.Ranks[c.rank].id end
            card.can_calculate=function() return not c.debuff end
            card.is_suit=Card.is_suit; hand[i]=card
        end
        local parts={_highest=get_highest(hand),_flush=get_flush(hand),
            _straight=get_straight(hand,SMODS.four_fingers(),RULES.j_shortcut,false)}
        for i=2,5 do parts['_'..i]=get_X_same(i,hand,true) end
        parts._all_pairs={SMODS.merge_lists(parts._2)}
        local order={'Flush Five','Flush House','Five of a Kind','Straight Flush',
            'Four of a Kind','Full House','Flush','Straight','Three of a Kind','Two Pair','Pair','High Card'}
        for _,name in ipairs(order) do
            local result=EVALUATE[name](parts)
            if result and next(result) then
                local scoring={}; for _,c in ipairs(result[1]) do scoring[c.index]=true end
                for _,c in ipairs(hand) do if c.center=='m_stone' or RULES.j_splash then scoring[c.index]=true end end
                local indices={}; for i=0,#hand-1 do if scoring[i] then indices[#indices+1]=i end end
                return name,indices
            end
        end
    end""")


def scenarios():
    rng = random.Random(8042761)
    out = []
    hand = [{"rank": r, "suit": s} for r, s in (("Ace", "Hearts"), ("King", "Spades"), ("King", "Clubs"), ("2", "Diamonds"), ("4", "Spades"), ("7", "Hearts"), ("9", "Clubs"), ("Jack", "Diamonds"))]
    hand[0]["center"] = "m_bonus"
    for deck in ("Red Deck", "Plasma Deck"):
        out.append(dict(hand=hand, jokers=[], hands_left=4, discards_left=0, chips=0, requirement=1000000000, pvp=False, deck=deck))
    for i in range(120):
        sc = bp.make_scenario(rng, ("early", "mixed", "late")[i % 3])
        sc.update(deck="Plasma Deck" if i % 2 else "Red Deck", discards_left=0, chips=0, requirement=1000000000, boss=None)
        # Misprint's expectation is a pre-existing model discrepancy; test
        # deterministic rules here rather than pretend this is RNG parity.
        sc["jokers"] = [j for j in sc["jokers"] if j != "j_misprint"]
        for c in sc["hand"]:
            if c.get("center") == "m_lucky":
                c["center"] = "m_bonus"
        if i % 3 == 0:
            rules = ["j_smeared", "j_four_fingers", "j_shortcut", "j_splash", "j_pareidolia"]
            sc["jokers"] = sc["jokers"][:3] + [rules[i % 5], rules[(i + 1) % 5]]
        if i % 7 == 0:
            sc["boss"] = "bl_flint"
            sc["blind_disabled"] = i % 14 == 0
        if i % 4 == 0:
            sc["hand"][0]["bonus_chips"] = 70
        if i % 10 == 0:
            # The user's final Joker combination, on synthetic visible hands.
            sc["jokers"] = ["j_green_joker", "j_lusty_joker", "j_constellation", "j_swashbuckler", "j_smeared"]
            sc["abilities"] = {"j_green_joker": {"mult": 16, "extra": {"hand_add": 1, "discard_sub": 1}}, "j_constellation": {"x_mult": 1.5}, "j_swashbuckler": {"mult": 17}}
            sc["scaled"] = {"j_green_joker": ("mult", 16, 1), "j_constellation": ("xmult", 1.5, 0), "j_swashbuckler": ("mult", 17, 0)}
        out.append(sc)
    # Four Fingers: the fifth off-suit card is not paid, but Stone is paid.
    # Shortcut may skip several individual ranks, and Ace cannot wrap K-A-2.
    for ranks, centers in ((["2", "3", "4", "5", "King"], [None]*5),
                           (["2", "3", "4", "5", "King"], [None]*4+["m_stone"]),
                           (["Ace", "3", "5", "7", "9"], [None]*5),
                           (["Queen", "King", "Ace", "2", "3"], [None]*5)):
        hand = [{"rank": rank, "suit": "Hearts" if i < 4 else "Clubs",
                 **({"center": centers[i]} if centers[i] else {})} for i, rank in enumerate(ranks)]
        for deck in ("Red Deck", "Plasma Deck"):
            out.append(dict(hand=hand, jokers=["j_four_fingers", "j_shortcut", "j_pareidolia", "j_splash", "j_scary_face"], hands_left=4,
                            discards_left=0, chips=0, requirement=1000000000, pvp=False, deck=deck))
    return out


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--require-all", action="store_true")
    required = args.parse_args().require_all
    cases = scenarios()
    vectors = None
    for runtime in ("lupa.lua51", "lupa.luajit21"):
        module = importlib.import_module(runtime)
        native_rules(module.LuaRuntime(unpack_returned_tuples=True), required)
        native_lua = module.LuaRuntime(unpack_returned_tuples=True)
        classify = native_classifier(native_lua, required)
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(bp.HARNESS)
        rows = bp.from_lua(harness(str(bp.REPO), bp.to_lua(lua, bp.lua_scenarios(cases)), bp.to_lua(lua, ["expert"])))
        choices = []
        for row in rows:
            sc = cases[row["scenario"] - 1]
            values = {}
            for a in row["candidates"]:
                if a["type"] != "PLAY_CARDS":
                    continue
                indices = bp.refs_to_indices(a["refs"])
                played = [sc["hand"][i] for i in indices]
                held = [c for i, c in enumerate(sc["hand"]) if i not in indices]
                if classify:
                    name, scoring = classify(bp.to_lua(native_lua, played), bp.to_lua(native_lua, sc["jokers"]))
                    py_name, py_scoring = bp.classify(played, "j_smeared" in sc["jokers"], "j_four_fingers" in sc["jokers"], "j_shortcut" in sc["jokers"])
                    if "j_splash" in sc["jokers"]:
                        py_scoring = list(range(len(played)))
                    names = {entry[2]: key for key, entry in bp.LEVEL_UP.items()}
                    names.update({"Five of a Kind": "five", "Flush House": "flush_house", "Flush Five": "flush_five"})
                    assert names[name] == py_name and set(bp.from_lua(scoring)) == set(py_scoring), (runtime, row["scenario"], name, py_name, bp.from_lua(scoring), py_scoring, played)
                values[a["id"]] = bp.reference_score(played, held, sc["jokers"], sc.get("levels"), sc.get("scaled"), balanced=sc["deck"] == "Plasma Deck", flint=sc.get("boss") == "bl_flint" and not sc.get("blind_disabled"))
            choice = row["choices"][0]
            assert choice["ok"] and choice["type"] == "PLAY_CARDS", (runtime, row)
            best = max(values.values())
            assert abs(values[choice["id"]] - best) < 1e-6, (runtime, row["scenario"], values[choice["id"]], best, sc)
            assert choice["instructions"] < 1000000
            choices.append(choice["id"])
        assert choices[0] != choices[1], "deck balancing must change the crafted decision"
        if vectors is not None:
            assert vectors == choices, "cross-runtime decisions differ"
        vectors = choices
        print(f"PASS {runtime}: {len(rows)} deck/Joker/level/enhancement combinations; legal best offered plays and budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
