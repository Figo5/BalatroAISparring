#!/usr/bin/env python3
"""Bounded discard estimates use public initial-deck counts only."""
import argparse
import importlib
import math
import re
import benchmark_policy as bp


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--require-all',action='store_true')
    required=parser.parse_args().require_all
    dump=bp.REPO/'staging/roles/ai/appdata/Roaming/Balatro/Mods/lovely/dump'
    if (dump/'game.lua').exists():
        game=(dump/'game.lua').read_text(encoding='utf-8')
        back=(dump/'back.lua').read_text(encoding='utf-8')
        assert re.search(r'b_abandoned\s*=.*remove_faces\s*=\s*true',game)
        assert re.search(r'b_erratic\s*=.*randomize_rank_suit\s*=\s*true',game)
        # Native Checkered setup maps Clubs to Spades and Diamonds to Hearts.
        assert "v.base.suit == 'Clubs'" in back and "v.base.suit == 'Diamonds'" in back
        assert "v:change_suit('Spades')" in back and "v:change_suit('Hearts')" in back
    else:
        assert not required,'Native deck fixtures required'
    for runtime in ('lupa.lua51','lupa.luajit21'):
        lua=importlib.import_module(runtime).LuaRuntime(unpack_returned_tuples=True)
        policy=lua.execute('return assert(loadfile(...))()',str(bp.REPO/'AISparring/ai/baseline_policy.lua'))
        readable=policy['readable_source']('expert')
        prefix=readable[:readable.index('return function(obs, actions)')]
        prefix=prefix.replace('local function synthetic(rank, suit)', '''local function synthetic(rank, suit)
            assert(DRAW_PROFILE~='checkered' or suit=='H' or suit=='S','impossible Checkered draw suit')
            assert(DRAW_PROFILE~='abandoned' or rank<=10 or rank==14,'impossible Abandoned draw rank')''')
        probe=lua.execute(prefix+'''return function(profile,bonus)
            DRAW_PROFILE=profile; CURRENT_EFF={}; JOKER_CACHE={}; WORK=0; MIN_CARDS=0;
            BALANCED=false; HAND_BLIND=nil; LEVELS=nil; PANEL=nil
            local jokers=bonus and {{center='j_lusty_joker'},{center='j_wrathful_joker'}} or {{center='j_droll'}}; set_rules(jokers)
            local ranks=bonus and {'6','7','8','9','King'} or {'2','4','6','8','10'}
            local hand={}; for i,rank in ipairs(ranks) do
                hand[i]={id='hand:'..i,rank=rank,suit=(i==5 or (bonus and i%2==0)) and 'Spades' or 'Hearts',center='c_base'} end
            local ev=discard_ev({self={hand=hand}},{'hand:5'},jokers,nil)
            local panel=panel_hands(); for _,h in ipairs(panel) do
                for _,cards in ipairs({h.play,h.held}) do for _,c in ipairs(cards) do
                    if profile=='abandoned' then assert(c.rank~='King' and c.rank~='Queen' and c.rank~='Jack') end
                    if profile=='checkered' then assert(c.suit=='Spades' or c.suit=='Hearts') end
                end end end
            return ev,rank_stock(13),suit_stock('H'),suit_stock('D')
        end''')
        for profile,outs,pool,king,heart,diamond in (
                ('standard',9,47,4,13,13),('checkered',22,47,4,26,0),('abandoned',6,35,0,10,10)):
            value,k,h,d=probe(profile)
            expected=13+(812-13)*outs/pool
            assert math.isclose(value,expected,rel_tol=1e-12),(profile,value,expected)
            assert (k,h,d)==(king,heart,diamond)
        probe('checkered',True)  # Both suits reward draws; fallback must still be a real initial suit.
        assert math.isclose(probe('standard')[0],13+(812-13)*9/47,rel_tol=1e-12),'state must reset'
        print(f'PASS {runtime}: native deck pins, independent flush probabilities, rank/suit stocks and shop panel reset')


if __name__=='__main__':
    main()
