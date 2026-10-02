"""Both-Lua tests of the privileged, read-only native profile producers."""
from pathlib import Path
import importlib, sys
REPO = Path(__file__).resolve().parents[1]

SCRIPT = r'''
local profile = assert(loadfile(PROFILE_PATH))()
local mods = {
 Steamodded={version='1.0.0~BETA-1620a',can_load=true},Lovely={version='0.9.0',can_load=true},
 Multiplayer={version='0.5.5',can_load=true},AISparring={version='0.1.0-dev',can_load=true},Balatro={version='1.0.1o'},
 ['lovely-compat-aisparring-staging']={version='0.0.0',can_load=true,lovely=true,lovely_only=true,meta_mod=true},
}
local smods = {booted=true,Mods=mods,stake_from_index=function(i)
 return ({'stake_white','stake_red','stake_green','stake_black','stake_blue','stake_purple','stake_orange','stake_gold'})[i]
end}
local G = {DEBUG=false,SETTINGS={profile=1,GAMESPEED=1,tutorial_complete=true},PROFILES={{all_unlocked=true}},
 P_CENTERS={b_red={set='Back',name='Red Deck',unlocked=true},b_blue={set='Back',name='Blue Deck',unlocked=true},
 j_test={unlocked=true},j_demo={demo=true}}, P_BLINDS={a={unlocked=true}},P_TAGS={a={unlocked=true}}}
local mp={INTEGRATIONS={Preview=false},DECK={MAX_STAKE=0},get_cocktail_decks=function()return {'b_red','b_blue'}end}
assert(profile.inventory_ok(smods,mp)==true)
local guard=mods['lovely-compat-aisparring-staging']
guard.version='0.0.1';assert(profile.inventory_ok(smods,mp)==false);guard.version='0.0.0'
guard.lovely_only=false;assert(profile.inventory_ok(smods,mp)==false);guard.lovely_only=true
mods['lovely-compat-aisparring-staging']=nil;assert(profile.inventory_ok(smods,mp)==false)
mods['lovely-compat-aisparring-staging']=guard
assert(profile.approved_mods()['lovely-compat-aisparring-staging']=='0.0.0')
assert(profile.content_unlocked(G)==true)
local facts=profile.facts(G,smods,mp,true)
assert(facts.debug_disabled==true and facts.animations_normal==true and facts.handy_disabled==true)
assert(facts.tutorial_ready==true)
G.SETTINGS.tutorial_progress={};assert(profile.facts(G,smods,mp,true).tutorial_ready==false);G.SETTINGS.tutorial_progress=nil
G.SETTINGS.tutorial_complete='true';assert(profile.facts(G,smods,mp,true).tutorial_ready==false);G.SETTINGS.tutorial_complete=true
local catalog=profile.catalog(G,smods,mp)
assert(catalog.decks.red.center_key=='b_red' and catalog.stakes.green.index==3 and catalog.stakes.gold.index==8)
assert(catalog.stakes.orange==nil and catalog.stakes.blue==nil)
G.DEBUG=true;assert(profile.facts(G,smods,mp,true).debug_disabled==false)
G.DEBUG=nil;assert(profile.facts(G,smods,mp,true).debug_disabled=='unknown');G.DEBUG=false
G.P_TAGS.a.unlocked=false;assert(profile.content_unlocked(G)==false);G.P_TAGS.a.unlocked=true
G.P_BLINDS=nil;assert(profile.content_unlocked(G)==nil);G.P_BLINDS={a={unlocked=true}}
mods.Handy={version='2.0.6',can_load=true};assert(profile.inventory_ok(smods,mp)==false)
assert(profile.catalog(G,smods,mp)==nil);mods.Handy=nil
mods.Multiplayer.version='0.5.4';assert(profile.inventory_ok(smods,mp)==false);mods.Multiplayer.version='0.5.5'
mods.AISparring.disabled=true;assert(profile.inventory_ok(smods,mp)==false);mods.AISparring.disabled=nil
mp.INTEGRATIONS.Preview=true;assert(profile.inventory_ok(smods,mp)==false);mp.INTEGRATIONS.Preview=false
smods.booted=false;assert(profile.inventory_ok(smods,mp)==nil);smods.booted=true
mp.get_cocktail_decks=function() error('fault') end;assert(profile.catalog(G,smods,mp)==nil)
mp.get_cocktail_decks=function() return {'b_red','b_red'} end;assert(profile.catalog(G,smods,mp)==nil)
mp.get_cocktail_decks=function() return {'b_mp_cocktail'} end;assert(profile.catalog(G,smods,mp)==nil)
assert(profile.approved_mods()['AISparring-0.1.0']=='dev')
return true
'''

def main():
    for name in ('lua51','luajit21'):
        module=importlib.import_module('lupa.'+name)
        runtime=module.LuaRuntime(unpack_returned_tuples=True)
        runtime.globals().PROFILE_PATH=str(REPO/'AISparring/integration/ranked_profile.lua')
        assert runtime.execute(SCRIPT)
        print(name+': 18 readiness/catalog controls passed; no native unlock claim')
    return 0
if __name__=='__main__':sys.exit(main())
