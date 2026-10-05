#!/usr/bin/env python3
"""Copy chains: installed native effects, independent scores and legal choices.

Proprietary fixtures are read privately; no game source is distributed.
"""
import argparse
import importlib
import itertools
import re
import benchmark_policy as bp


def native_copy(lua, required):
    dump = bp.REPO / 'staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump'
    utils = bp.REPO / 'work/local-ownership/native-mods-source/smods/src/utils.lua'
    if not (dump / 'card.lua').exists() or not utils.exists():
        assert not required, 'Native copy fixtures required for release'
        return None
    game = (dump / 'game.lua').read_text(encoding='utf-8')
    centers = {m[1]: lua.eval(m[2].rstrip(',')) for m in
               re.finditer(r'^\s*(j_\w+)\s*=\s*({.*}),?\s*$', game, re.M)}
    policy = (bp.REPO / 'AISparring/ai/baseline_policy.lua').read_text()
    section = policy[policy.index('local JOKER_EFFECTS'):policy.index('-- Owned scaling')]
    incompatible = {'j_smeared', 'j_four_fingers', 'j_shortcut', 'j_splash', 'j_pareidolia'}
    reader=(bp.REPO/'AISparring/integration/state_reader.lua').read_text()
    current=reader[reader.index('local SCALING_CURRENT'):reader.index('local function scaling_number')]
    for key in set(re.findall(r'\bj_\w+\b', section + current)):
        assert bool(centers[key]['blueprint_compat']) == (key not in incompatible), key
    body = (dump / 'card.lua').read_text(encoding='utf-8')
    start = body.index('function Card:calculate_joker(context)')
    function = body[start:body.index('function Card:is_suit(', start)]
    start = body.index('local new_ability = {')
    ability = body[start:body.index('\n    }', start) + len('\n    }')]
    lua.execute('''Card={}; SMODS={}; G={jokers={cards={}},C={BLUE=1,RED=2},GAME={}};
        localize=function() return 'fixture' end;
        copy_table=function(t) if type(t)~='table' then return t end
            local c={}; for k,v in pairs(t) do c[k]=copy_table(v) end; return c end''')
    lua.execute(function)
    body = utils.read_text(encoding='utf-8')
    start = body.index('function SMODS.blueprint_effect(')
    lua.execute(body[start:body.index('\nend', start) + 4])
    lua.globals().CENTERS = lua.table_from(centers)
    make = lua.execute('return function(center) local self={}; ' + ability + '\nreturn new_ability end')
    lua.globals().MAKE = make
    return lua.eval('''function(keys, debuffed)
        local row={}; for i,key in ipairs(keys) do local center=CENTERS[key];
            row[i]={config={center=center},ability=MAKE(center),
                calculate_joker=Card.calculate_joker,debuff=i==debuffed} end
        G.jokers.cards=row; local mult=2
        for _,j in ipairs(row) do if not j.debuff then
            local context={joker_main=true,cardarea=G.jokers,scoring_hand={},full_hand={},poker_hands={}}
            local e=j:calculate_joker(context)
            if e then mult=(mult+(e.mult_mod or 0))*(e.Xmult_mod or 1) end
            assert(context.blueprint==nil and context.blueprint_card==nil,
                'native copy context must unwind') end end
        return 30*mult
    end''')


def model_probe(lua):
    policy = lua.execute('return assert(loadfile(...))()', str(bp.REPO / 'AISparring/ai/baseline_policy.lua'))
    readable = policy['readable_source']('expert')
    prefix = readable[:readable.index('return function(obs, actions)')]
    return lua.execute(prefix + '''return function(jokers)
        set_rules(jokers); CURRENT_EFF={}; JOKER_CACHE={}; BALANCED=false; FLINT=false; LEVELS=nil
        return estimate({{rank='King',suit='Spades'},{rank='King',suit='Hearts'}},{},jokers)
    end''')


def check_shop_gains(lua):
    policy=lua.execute('return assert(loadfile(...))()',str(bp.REPO/'AISparring/ai/baseline_policy.lua'))
    readable=policy['readable_source']('expert')
    prefix=readable[:readable.index('return function(obs, actions)')]
    probe=lua.execute(prefix+'''return function(keys,center)
        CURRENT_EFF={}; JOKER_CACHE={}; GAIN_CACHE={}; DRAW_PROFILE=nil; PANEL=nil; LEVELS=nil; BALANCED=false; FLINT=false
        local owned={}; for _,key in ipairs(keys) do owned[#owned+1]={center=key} end
        return joker_gain({self={jokers=owned},match={ante=1}},center,nil),panel_hands()
    end''')
    for row in itertools.product(('j_blueprint','j_brainstorm','j_cavendish','j_joker','j_abstract'),repeat=3):
        for center in ('j_blueprint','j_brainstorm'):
            gain,panel=probe(bp.to_lua(lua,row),center)
            hands=bp.from_lua(panel)
            def total(keys):
                return sum(h['w']*bp.reference_score(h['play'],h['held'] if h['held'] else [],keys) for h in hands)
            before=total(row)
            variants=[[*row,center]]
            for target,key in enumerate(row):
                rest=[k for i,k in enumerate(row) if i!=target]
                if center=='j_brainstorm': variants.append([key,*rest,center])
                else: variants.extend([[*rest,center,key],[center,key,*rest]])
            expected=max(0,min(3,(max(map(total,variants))-before)/before))
            assert abs(gain-expected)<1e-12,(row,center,gain,expected)
    return 250


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-all', action='store_true')
    required = parser.parse_args().require_all
    keys = ('j_blueprint', 'j_brainstorm', 'j_cavendish', 'j_joker', 'j_abstract', 'j_four_fingers')
    rows = list(itertools.product(keys, repeat=3)) + [(), ('j_blueprint',), ('j_brainstorm',)]
    vectors = None
    for runtime in ('lupa.lua51', 'lupa.luajit21'):
        module = importlib.import_module(runtime)
        native_lua = module.LuaRuntime(unpack_returned_tuples=True)
        native = native_copy(native_lua, required)
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        probe = model_probe(lua)
        gains = check_shop_gains(lua)
        for row in rows:
            actual = probe(bp.to_lua(lua, [{'center': k} for k in row]))[0]
            expected = bp.reference_score([{'rank':'King','suit':'Spades'}, {'rank':'King','suit':'Hearts'}], [], row)
            assert actual == expected, (runtime, row, actual, expected)
            if native is not None:
                assert native(bp.to_lua(native_lua, row), None) == expected, row
        # Debuff, invisible targets, missing neighbors and cycle effects are neutral.
        for field in ('debuff', 'redacted'):
            assert probe(bp.to_lua(lua, [{'center':'j_blueprint'}, {'center':'j_joker',field:True}]))[0] == 60
        assert probe(bp.to_lua(lua, [{'center':'j_brainstorm'}, {'center':'j_blueprint'}]))[0] == 60
        if native is not None:
            assert native(bp.to_lua(native_lua, ['j_blueprint','j_joker']), 2) == 60
        # The copied Joker's edition is never duplicated; the copier's own edition applies.
        assert probe(bp.to_lua(lua, [{'center':'j_blueprint','edition':'holo'}, {'center':'j_joker','edition':'polychrome'}]))[0] == 900
        cases = []
        import test_expert_performance as expert
        hands = expert.scenarios()[2:22]
        for i, row in enumerate(rows[:216]):
            sc = dict(hands[i % len(hands)], jokers=list(row))
            cases.append(sc)
        harness = lua.execute(bp.HARNESS)
        result = bp.from_lua(harness(str(bp.REPO), bp.to_lua(lua,bp.lua_scenarios(cases)), bp.to_lua(lua,['expert'])))
        choices=[]
        for row in result:
            assert not row.get('error'), row
            sc=cases[row['scenario']-1]; scores={}
            for a in row['candidates']:
                if a['type']!='PLAY_CARDS': continue
                indices=bp.refs_to_indices(a['refs'])
                scores[a['id']]=bp.reference_score([sc['hand'][i] for i in indices],
                    [c for i,c in enumerate(sc['hand']) if i not in indices],sc['jokers'],levels=sc.get('levels'),
                    balanced=sc['deck']=='Plasma Deck',flint=sc.get('boss')=='bl_flint' and not sc.get('blind_disabled'))
            choice=row['choices'][0]
            assert choice['ok'] and choice['type']=='PLAY_CARDS', choice
            assert scores[choice['id']]==max(scores.values()), (runtime,sc['jokers'],choice)
            assert choice['instructions']<=1000000
            choices.append(choice['id'])
        assert vectors is None or vectors==choices, 'cross-runtime copying decisions'
        vectors=choices
        print(f'PASS {runtime}: {len(rows)} native copy-chain scores, {gains} independent shop gains, editions/redaction/debuffs, {len(cases)} legal optimal offered decisions')


if __name__=='__main__':
    main()
