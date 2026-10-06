#!/usr/bin/env python3
"""Retriggers pinned to private installed Joker and Steamodded scoring code.

The fixture runs native repetition collection and score-card iteration. UI,
card enhancement evaluation and effect application are isolated test doubles;
the independent scorer separately checks totals. No proprietary code is saved.
"""
import argparse
import importlib
import itertools
import math
import random

import benchmark_policy as bp
import test_copying_strategy as copies
from test_arm_forecast import native_function

REPEATERS = ('j_hanging_chad', 'j_mp_hanging_chad', 'j_sock_and_buskin', 'j_hack', 'j_mime')


def native_fixture(lua, required):
    dump = bp.REPO / 'staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump'
    utils = bp.REPO / 'work/local-ownership/native-mods-source/smods/src/utils.lua'
    if not (dump / 'card.lua').exists() or not utils.exists():
        assert not required, 'Native retrigger fixtures required for release'
        return None
    centers = copies.native_centers(lua, dump)
    for key, count in zip(REPEATERS, (2, 1, 1, 1, 1)):
        assert centers[key]['blueprint_compat'] and centers[key]['config']['extra'] == count
    lua.execute('''
        Card={}; SMODS={Ranks={},optional_features={}};
        G={play={},hand={},jokers={cards={}},C={BLUE=1,RED=2},GAME={}};
        percent=0; percent_delta=0; localize=function() return 'fixture' end;
        copy_table=function(t) if type(t)~='table' then return t end
            local c={}; for k,v in pairs(t) do c[k]=copy_table(v) end; return c end;
        SMODS.calculate_quantum_enhancements=function() end;
        SMODS.get_card_areas=function(kind) return kind=='jokers' and {G.jokers} or {} end;
        SMODS.calculate_effect=function() end;
        find_joker=function(name) if name=='Pareidolia' and PAREIDOLIA then return {true} end return {} end;
        for i,key in ipairs({'2','3','4','5','6','7','8','9','10','Jack','Queen','King','Ace'}) do
            SMODS.Ranks[key]={id=i+1,face=i>=10 and i<=12} end;
    ''')
    body = (dump / 'card.lua').read_text(encoding='utf-8')
    start = body.index('function Card:calculate_joker(context)')
    lua.execute(body[start:body.index('function Card:is_suit(', start)])
    lua.execute(native_function(dump / 'card.lua', 'function Card:is_face(from_boss)'))
    lua.execute(native_function(utils, 'function SMODS.blueprint_effect('))
    for header in ('SMODS.insert_repetitions = function(', 'SMODS.calculate_repetitions = function(',
                   'function SMODS.score_card('):
        lua.execute(native_function(utils, header))
    start = body.index('local new_ability = {')
    ability = body[start:body.index('\n    }', start) + len('\n    }')]
    lua.globals().MAKE = lua.execute('return function(center) local self={}; ' + ability + '\nreturn new_ability end')
    lua.globals().CENTERS = lua.table_from(centers)
    lua.execute('''
        eval_card=function(c,ctx)
            if c.calculate_joker then
                if c.debuff then return {},{} end
                local e=c:calculate_joker(ctx); return e and {jokers=e} or {},{}
            end
            if ctx.repetition_only then
                return c.seal=='Red' and {seals={repetitions=1}} or {},{}
            end
            if ctx.cardarea==G.play then
                local e={chips=c.nominal+(c.bonus_chips or 0)};
                if c.center=='m_bonus' and c.bonus_chips==nil then e.chips=e.chips+30 end
                if c.center=='m_stone' and c.bonus_chips==nil then e.chips=e.chips+50 end
                if c.center=='m_mult' then e.mult=4 end
                if c.center=='m_glass' then e.x_mult=(c.xmult or 200)/100 end
                return e,{}
            end
            return c.center=='m_steel' and {h_x_mult=1.5} or {},{}
        end;
        SMODS.calculate_card_areas=function(kind,ctx,effects)
            if kind=='jokers' then for _,j in ipairs(G.jokers.cards) do
                local e=eval_card(j,ctx); if next(e) then effects[#effects+1]=e end end end
        end;
        SMODS.trigger_effects=function(effects)
            local calculated=false;
            local function apply(e)
                if next(e) then calculated=true end
                CHIPS=CHIPS+(e.chips or e.chip_mod or 0);
                MULT=(MULT+(e.mult or e.mult_mod or e.h_mult or 0))
                    *(e.x_mult or e.Xmult_mod or e.h_x_mult or 1);
            end
            for _,e in ipairs(effects) do if e.jokers then apply(e.jokers) else apply(e) end end;
            return {calculated=calculated}
        end;
    ''')
    # Native final scoring-hand assembly restores the actual played order,
    # including Stone cards, before Chad/Photograph inspect positions.
    events = (dump / 'functions/state_events.lua').read_text(encoding='utf-8')
    start = events.index('    local final_scoring_hand = {}')
    assembly = events[start:events.index('    scoring_hand = final_scoring_hand',start)]
    lua.execute("SMODS.always_scores=function(c) return c.center=='m_stone' end; SMODS.never_scores=function() return false end; SMODS.calculate_context=function() end")
    lua.globals().ASSEMBLE = lua.execute('return function(played,scoring_hand) G.play.cards=played;\n' + assembly + '\nreturn final_scoring_hand end')
    return lua.eval('''function(played,held,indices,keys,chips,mult,balanced)
        CHIPS=chips; MULT=mult; PAREIDOLIA=false; local row={}; local events={};
        for i,key in ipairs(keys) do local center=CENTERS[key];
            row[i]={config={center=center},ability=MAKE(center),calculate_joker=Card.calculate_joker};
            if key=='j_pareidolia' then PAREIDOLIA=true end end;
        G.jokers.cards=row;
        local function cards(list)
            local out={}; for i,c in ipairs(list) do
                local rv=SMODS.Ranks[c.rank].id; c.base={id=rv,value=c.rank};
                c.nominal=c.center=='m_stone' and 0 or (rv==14 and 11 or math.min(rv,10));
                c.get_id=function() return c.center=='m_stone' and -i or rv end;
                c.is_face=Card.is_face; out[i]=c end; return out
        end
        played=cards(played); held=cards(held); local scoring={};
        for _,i in ipairs(indices) do scoring[#scoring+1]=played[i+1] end;
        scoring=ASSEMBLE(played,scoring);
        local original=SMODS.trigger_effects;
        SMODS.trigger_effects=function(e,c) events[c]=(events[c] or 0)+1; return original(e,c) end;
        for _,c in ipairs(scoring) do if not c.debuff then
            SMODS.score_card(c,{cardarea=G.play,scoring_hand=scoring,full_hand=played}) end end;
        for _,c in ipairs(held) do if not c.debuff then
            SMODS.score_card(c,{cardarea=G.hand,scoring_hand=scoring,full_hand=played}) end end;
        SMODS.trigger_effects=original;
        for _,j in ipairs(row) do local e=eval_card(j,{joker_main=true,cardarea=G.jokers,
            scoring_hand=scoring,full_hand=played,poker_hands={}});
            SMODS.trigger_effects({e},j) end;
        local counts={}; for _,c in ipairs(played) do counts[#counts+1]=events[c] or 0 end;
        return balanced and math.floor((CHIPS+MULT)/2)^2 or CHIPS*MULT, counts
    end''')


def probe(lua):
    policy = lua.execute('return assert(loadfile(...))()', str(bp.REPO / 'AISparring/ai/baseline_policy.lua'))
    source = policy['readable_source']('expert')
    return lua.execute(source[:source.index('return function(obs, actions)')] + '''return function(played,held,jokers,balanced)
        set_rules(jokers); CURRENT_EFF={}; JOKER_CACHE={}; LEVELS=nil; HAND_BLIND=nil;
        BALANCED=balanced; WORK=0; return estimate(played,held,jokers)
    end''')


def scenarios():
    rng = random.Random(20261006)
    out = []
    rows = [(key,) for key in REPEATERS]
    rows += [('j_photograph', key) for key in REPEATERS[:3]]
    rows += [('j_blueprint', key, 'j_brainstorm') for key in REPEATERS]
    rows += [('j_mime', 'j_baron', 'j_shoot_the_moon'), ('j_mime', 'j_blueprint', 'j_baron')]
    for i in range(120):
        sc = bp.make_scenario(rng)
        sc.update(jokers=list(rows[i % len(rows)]), discards_left=0, chips=0,
                  requirement=1000000000000, pvp=False, deck='Plasma Deck' if i % 2 else 'Red Deck')
        sc['hand'] = [dict(c, center='m_mult' if c.get('center')=='m_lucky' else c.get('center','c_base')) for c in sc['hand']]
        for c in sc['hand']:
            if c.get('center')=='m_glass': c['xmult']=150 if i % 3 else 200
        out.append(sc)
    return out


def shop_gains(lua):
    policy=lua.execute('return assert(loadfile(...))()',str(bp.REPO/'AISparring/ai/baseline_policy.lua'))
    source=policy['readable_source']('expert')
    gain=lua.execute(source[:source.index('return function(obs, actions)')]+'''return function(keys,center)
        CURRENT_EFF={}; JOKER_CACHE={}; GAIN_CACHE={}; PANEL=nil; DRAW_PROFILE=nil;
        LEVELS=nil; BALANCED=false; HAND_BLIND=nil; local row={};
        for _,key in ipairs(keys) do row[#row+1]={center=key} end
        return joker_gain({self={jokers=row},match={ante=1}},center,nil),panel_hands()
    end''')
    rows=[(),('j_photograph',),('j_baron','j_shoot_the_moon'),('j_blueprint','j_photograph'),
          ('j_mp_hanging_chad','j_photograph','j_brainstorm'),('j_sock_and_buskin','j_pareidolia')]
    for keys,center in itertools.product(rows,REPEATERS):
        actual,panel=gain(bp.to_lua(lua,keys),center)
        hands=bp.from_lua(panel)
        def total(row):
            return sum(h['w']*bp.reference_score(h['play'],h['held'] or [],row) for h in hands)
        before,after=total(keys),total([*keys,center])
        expected=max(0,min(3,(after-before)/before))
        assert math.isclose(actual,expected,rel_tol=1e-12,abs_tol=1e-12),(keys,center,actual,expected)
    return len(rows)*len(REPEATERS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-all', action='store_true')
    required = parser.parse_args().require_all
    previous = None
    for runtime in ('lupa.lua51', 'lupa.luajit21'):
        module = importlib.import_module(runtime)
        native = module.LuaRuntime(unpack_returned_tuples=True)
        run = native_fixture(native, required)
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        model = probe(lua)
        gains = shop_gains(lua)
        checked = 0
        plays = [
            [dict(rank=r,suit='Hearts') for r in ('King','Queen','2','3','4')],
            [dict(rank=r,suit=s) for r,s in zip(('2','7','7','Queen','King'),bp.SUITS+['Hearts'])],
            [dict(rank='2',suit='Hearts',center='m_stone'),dict(rank='King',suit='Clubs')],
            [dict(rank='King',suit='Hearts',center='m_glass',xmult=150),dict(rank='Queen',suit='Hearts',center='m_mult')],
        ]
        held = [dict(rank='King',suit='Clubs',center='m_steel',seal='Red'),
                dict(rank='Queen',suit='Spades'),dict(rank='7',suit='Diamonds')]
        rows = [(key,) for key in REPEATERS]
        rows += list(itertools.product(REPEATERS, repeat=2))
        rows += [('j_photograph',key,'j_blueprint',key,'j_brainstorm') for key in REPEATERS]
        rows += [('j_mime','j_baron','j_shoot_the_moon'),('j_mime','j_blueprint','j_baron'),
                 ('j_sock_and_buskin','j_pareidolia'),('j_hack','j_sock_and_buskin','j_pareidolia')]
        for played, keys, first_debuff, red, balanced in itertools.product(plays,rows,(False,True),(False,True),(False,True)):
            played = [dict(c) for c in played]
            played[0].update(debuff=first_debuff, seal='Red' if red else None)
            expected = bp.reference_score(played,held,keys,balanced=balanced)
            actual = model(bp.to_lua(lua,played),bp.to_lua(lua,held),bp.to_lua(lua,[{'center':k} for k in keys]),balanced)[0]
            assert math.isclose(actual,expected,rel_tol=1e-12),(runtime,played,keys,actual,expected)
            if run:
                name,indices = bp.classify(played)
                actual,_ = run(bp.to_lua(native,played),bp.to_lua(native,held),bp.to_lua(native,indices),
                    bp.to_lua(native,keys),*bp.HAND_BASE[name],balanced)
                assert math.isclose(actual,expected,rel_tol=1e-12),(runtime,played,keys,balanced,actual,expected)
            checked += 1
        # A debuffed first scoring card consumes Chad's position, not a new target.
        if run:
            hand=[dict(rank='King',suit='Spades',debuff=True),dict(rank='King',suit='Hearts')]
            for key,counts in (('j_hanging_chad',[0,1]),('j_mp_hanging_chad',[0,2])):
                _,actual=run(bp.to_lua(native,hand),bp.to_lua(native,[]),bp.to_lua(native,[0,1]),bp.to_lua(native,[key]),10,2,False)
                assert bp.from_lua(actual)==counts
        for field in ('debuff','redacted'):
            hand=[dict(rank='King',suit='Spades')]
            assert model(bp.to_lua(lua,hand),bp.to_lua(lua,[]),bp.to_lua(lua,[{'center':'j_hanging_chad',field:True}]),False)[0]==15
            assert model(bp.to_lua(lua,hand),bp.to_lua(lua,[]),bp.to_lua(lua,[{'center':'j_blueprint'},{'center':'j_hanging_chad',field:True}]),False)[0]==15
        cases=scenarios()
        results=bp.from_lua(lua.execute(bp.HARNESS)(str(bp.REPO),bp.to_lua(lua,bp.lua_scenarios(cases)),bp.to_lua(lua,['competitive','major_league','expert'])))
        vectors=[]; worst=0
        for sc,row in zip(cases,results):
            assert not row.get('error'),row
            values={}
            for a in row['candidates']:
                if a['type']=='PLAY_CARDS':
                    indices=bp.refs_to_indices(a['refs'])
                    values[a['id']]=bp.reference_score([sc['hand'][i] for i in indices],
                        [c for i,c in enumerate(sc['hand']) if i not in indices],sc['jokers'],sc.get('levels'),balanced=sc['deck']=='Plasma Deck')
            for choice in row['choices']:
                assert choice['ok'] and choice['type']=='PLAY_CARDS',choice
                assert values[choice['id']]==max(values.values()),(runtime,sc,choice)
                assert choice['instructions']<1600000,choice
                worst=max(worst,choice['instructions']); vectors.append(choice['id'])
        assert previous is None or vectors==previous,'cross-runtime retrigger decisions'
        previous=vectors
        print(f'PASS {runtime}: {checked} native/independent retrigger totals; debuffs, Red seals, copying, Ranked Chad; {gains} independent shop gains; {len(vectors)} optimal offered decisions; max {worst} instructions')


if __name__=='__main__':
    main()
