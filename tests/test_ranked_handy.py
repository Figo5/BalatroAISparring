"""Execute pinned Handy reset/MP predicates and real driver on both Lua engines."""
from pathlib import Path
import importlib, sys
REPO=Path(__file__).resolve().parents[1]
HANDY=REPO/'work/reference/Handy-2.0.6-ranked'

SCRIPT=r'''
MP={LOBBY={config={},ready_to_start=true,is_host=true},Rulesets={}}
G={STAGES={MAIN_MENU=1,RUN=2},STAGE=1}
Handy={controls={is_module_enabled=function()return false end},cc={},ARGS={global_empty_table={}},
 load_file=function()end,buffered=function(_,fn)return fn end,b_is_mod_active=function()return true end,
 b_is_dangerous_actions_active=function()return true end}
MP.reset_lobby_config=function()MP.LOBBY.config={ruleset='ruleset_mp_standard_ranked',gamemode='gamemode_mp_attrition'}end
assert(loadstring(HANDY_INDEX))()
assert(loadstring(HANDY_RESET))()
assert(loadstring(HANDY_API))()
assert(loadstring(HANDY_SPEED))()
assert(loadstring(HANDY_ANIMATION))()
assert(loadstring(HANDY_DANGER))()
Handy.MP.mod_type='pre_release'
local source_config=CONFIG()
local ruleset={forced_gamemode='gamemode_mp_attrition',_layer_order={'standard','ranked','pvp_timer'},
 standard=true,multiplayer_content=true,pvp_timer_base_seconds=60,pvp_timer_hand_played_increment_seconds=10,
 is_disabled=function()return false end,force_lobby_options=function()return true end}
MP.Rulesets.ruleset_mp_standard_ranked=ruleset
MP.current_ruleset=function()return ruleset end
local packet
local funcs={start_lobby=function()
 MP.reset_lobby_config()
 for k,v in pairs(source_config)do MP.LOBBY.config[k]=v end
 MP.current_ruleset():force_lobby_options()
 MP.LOBBY.code='TEST1'
 packet={};for k,v in pairs(MP.LOBBY.config)do packet[k]=v end
end,lobby_start_game=function()end}
local ranked=assert(loadfile(RANKED_PATH))()
local Driver=assert(loadfile(DRIVER_PATH))()
local driver=assert(Driver.factory({role='human',G=G,mp=MP,funcs=funcs,ranked_config=ranked}))
assert(driver.host_start())
assert(packet.handy_allow_mp_extension==false and packet.handy_speed_multiplier_mode==1)
MP.LOBBY.handy_mp_extension_all_players_enabled=true -- even forged consent cannot enable it
Handy.speed_multiplier.value=128
Handy.animation_skip.value=5
assert(Handy.speed_multiplier.get_value()==1)
assert(Handy.animation_skip.get_value()==1)
assert(Handy.dangerous_actions.is_sell_disabled_in_mp()==true)
assert(Handy.dangerous_actions.is_remove_disabled_in_mp()==true)
assert(Handy.is_mp_lobby_extension_active()==false)
local profile=assert(loadfile(PROFILE_PATH))()
assert(profile.handy_safe(MP,Handy)==true)
local digest=assert(driver.ranked_config_digest())
MP.LOBBY.config.action='lobbyOptions'
assert(driver.ranked_config_digest()==digest)
for _,key in ipairs({'handy_speed_multiplier_mode','handy_animation_skip_mode','handy_dangerous_actions_mode'})do
 MP.LOBBY.config[key]=2;assert(driver.ranked_config_digest()==nil);assert(profile.handy_safe(MP,Handy)==false)
 MP.LOBBY.config[key]=1
end
MP.LOBBY.config.handy_allow_mp_extension=true
assert(driver.ranked_config_digest()==nil);assert(profile.handy_safe(MP,Handy)==false)
MP.LOBBY.config.handy_allow_mp_extension=false
MP.LOBBY.config.handy_speed_multiplier_mode_force=2;assert(driver.ranked_config_digest()==nil)
MP.LOBBY.config.handy_speed_multiplier_mode_force=nil
MP.LOBBY.config.handy_animation_skip_mode=nil;assert(driver.ranked_config_digest()==nil)
MP.LOBBY.config.handy_animation_skip_mode=1
assert(driver.ranked_config_digest()==digest)
assert(driver.host_start_game());assert(not driver.is_started())
assert(not driver.guard_allows('lobbyOptions'))
G.STAGE=G.STAGES.RUN;assert(driver.is_started())
return true
'''

def main():
    sys.path.insert(0,str(REPO/'tools'))
    import ranked_effective_config as rec
    catalog={'schema':'aisparring.ranked_catalog.v1','eligible_decks':['b_red'],
        'decks':{'red':{'center_key':'b_red','name':'Red Deck'}},'stakes':{'white':{'index':1,'max_index':8}}}
    selection={'schema':'aisparring.ranked_selection.v1','deck_key':'red','back_key':'b_red',
        'back_name':'Red Deck','stake_key':'white','stake_index':1}
    derived=rec.derive_effective_config(REPO/'work/reference/certified-mods/Multiplayer',
        REPO/'docs/RANKED_SOURCE_PINS_V1.json', cocktail='1H',selection=selection,catalog=catalog)
    assert derived['ok'],derived
    config=derived['host']
    # These are real unchanged functions from the exact dependency pin, not reimplementations.
    reset=(HANDY/'src/mp_extension/pre_release.lua').read_text()
    index=(HANDY/'src/mp_extension/index.lua').read_text()
    for name in ('lua51','luajit21'):
        lua=importlib.import_module('lupa.'+name).LuaRuntime(unpack_returned_tuples=True)
        g=lua.globals()
        g.HANDY_INDEX=index.split('--\n\nHandy.e_mitter.on')[0]
        g.HANDY_RESET=reset.split('G.FUNCS.handy_set_mp_option_cycle')[0]
        g.HANDY_API='local mp_pre_release=Handy.MP.current\n'+reset.split('-- Api\n')[1].split('-- Events\n')[0]
        g.HANDY_SPEED=(HANDY/'src/controls/speed_multiplier/index.lua').read_text().split('function Handy.speed_multiplier.get_buffered_value')[0]
        g.HANDY_ANIMATION=(HANDY/'src/controls/animation_skip/index.lua').read_text().split('function Handy.animation_skip.get_buffered_value')[0]
        g.HANDY_DANGER=(HANDY/'src/controls/dangerous_actions/index.lua').read_text().split('Handy.dangerous_actions.queues =')[0]
        g.DRIVER_PATH=str(REPO/'AISparring/integration/mp_driver.lua')
        g.PROFILE_PATH=str(REPO/'AISparring/integration/ranked_profile.lua')
        g.RANKED_PATH=str(REPO/'AISparring/integration/ranked_config.lua')
        def fresh():return lua.table_from({k:v for k,v in config.items() if v is not None})
        g.CONFIG=fresh
        assert lua.execute(SCRIPT)
        print(name+': actual Handy reset, disabled banned features, digest tamper controls and asynchronous start passed')
    return 0
if __name__=='__main__':sys.exit(main())
