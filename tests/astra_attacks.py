"""Independent Astra regression probes. Synthetic state only; no game access."""
import importlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = r'''
local C = dofile(root .. '/AISparring/ai/codec.lua')
local O = dofile(root .. '/AISparring/ai/observation.lua').factory(C)
local A = dofile(root .. '/AISparring/ai/actions.lua').factory(O,C)
local R = dofile(root .. '/AISparring/integration/state_reader.lua').factory(O)
function frame()
 return {schema_version=1,phase='SHOP',match={ruleset='mp',joker_slots=5},
 self={money=20,credit_limit=0,jokers={}},shop={items={{face_down=false,kind='joker',edition='negative',cost=2}}},
 context={blocked=false,timer_expired=false},certificates={version=1,items={{type='BUY_ITEM',item_ref='shop:1',certified=true}}}}
end
function reader_fixture()
 local card={facing='front',sprite_facing='front',config={center={}},ability={}}
 local runtime={role='ai_staged',epoch=7,G={STATE=1,STATES={SELECTING_HAND=1},GAME={dollars=5,bankrupt_at=0,current_round={hands_left=4,discards_left=3,hands_played=0}},hand={cards={card}}},MP={GAME={enemy={info_received=true,score_text='999',real_score=123456}},LOBBY={code='fixture',config={hide_score_until_played=true,timer=true,enemy_location_disabled=true}}}}
 local view={epoch=7,phase='PLAY_HAND',match={ruleset='mp'},self={hand_visible=true,cards={hand={{face_down=false,rank='A',suit='Spades',shown={rank=true,suit=true}}}}},recognition={pvp_context=true},context={blocked=false,timer_expired=false}}
 return runtime,view,card
end
codec,obs,acts,reader=C,O,A,R
'''
ATTACKS = {
    'negative_capacity_denied': "local f=frame(); f.certificates.items[1].capacity_ok=false; assert(#acts.generate(assert(obs.observe(f)))==0)",
    'missing_owned_capacity_denied': "local f=frame(); f.shop.items[1].edition=nil; f.self.jokers=nil; f.certificates.items[1].capacity_ok=true; assert(#acts.generate(assert(obs.observe(f)))==0)",
    'stone_rank_hidden': "local r,v,c=reader_fixture(); c.ability.effect='Stone Card'; local p=obs.export(assert(reader.capture(r,v))); assert(p.self.hand[1].rank==nil and p.self.hand[1].suit==nil)",
    'unknown_facing_denied': "local r,v=reader_fixture(); v.self.cards.hand[1].face_down=nil; local p=obs.export(assert(reader.capture(r,v))); assert(p.self.hand[1].rank==nil)",
    'masked_score_poison': "local r,v=reader_fixture(); v.opponent={certified=true,score_visible=true,displayed_score='123456'}; local p=obs.export(assert(reader.capture(r,v))); assert(p.opponent==nil or p.opponent.displayed_score==nil)",
    'raw_hidden_perturbation': "local r,v=reader_fixture(); local h=assert(reader.capture(r,v)); r.G.deck=setmetatable({}, {__index=function() error('hidden read') end}); r.G.GAME.pseudorandom={seed='SECRET'}; r.MP.GAME.enemy.real_score=999999; assert(obs.canonical(h)==obs.canonical(assert(reader.capture(r,v))))",
    'negative_epoch_denied': "local r,v=reader_fixture(); r.epoch=-1; v.epoch=-1; assert(reader.capture(r,v)==nil)",
    'handle_and_export_mutation': "local f=frame(); local h=assert(obs.observe(f)); local before=obs.canonical(h); rawset(h,'self',f.self); local p=obs.export(h); p.self.money=100000; p.shop.items[1].cost=0; f.self.money=-99; assert(obs.canonical(h)==before and obs.export(h).self.money==20)",
    'unknown_callback_and_cycle': "local f=frame(); f.seed=function() error('seed') end; f.future=f; local h=assert(obs.observe(f)); local p=obs.export(h); assert(p.seed==nil and p.future==nil)",
    'action_id_is_not_authority': "local f=frame(); f.certificates.items[1].capacity_ok=true; local h=assert(obs.observe(f)); local a=acts.generate(h)[1]; assert(a); a.item_ref='shop:999'; assert(acts.validate(h,a)==nil)",
    'validator_changed_fresh_state': "local f=frame(); f.certificates.items[1].capacity_ok=true; local epoch=1; local h=assert(obs.observe(f)); local calls=0; local B=dofile(root..'/AISparring/integration/action_broker.lua').factory(obs,acts,{fixture='M2_FIXTURE_ONLY',capture=function() return h,epoch end,validate=function() f.self.money=-10; h=assert(obs.observe(f)); return true end,dispatch=function() calls=calls+1 end}); local t,p=B.issue(); assert(t); assert(B.submit(t,p.actions[1])==nil and calls==0)",
    'replay_and_cross_broker': "local f=frame(); f.certificates.items[1].capacity_ok=true; local h=assert(obs.observe(f)); local calls=0; local ports={fixture='M2_FIXTURE_ONLY',capture=function() return h,1 end,validate=function() return true end,dispatch=function() calls=calls+1 end}; local M=dofile(root..'/AISparring/integration/action_broker.lua'); local b=M.factory(obs,acts,ports); local b2=M.factory(obs,acts,ports); local t,p=b.issue(); assert(b2.submit(t,p.actions[1])==nil); assert(b.submit(t,p.actions[1])==true); assert(b.submit(t,p.actions[1])==nil and calls==1)",
    'deck_aggregate_inference_denied': "local r,v,c=reader_fixture(); c.facing='back'; v.self.deck={total=44,by_rank={A=3},by_suit={Spades=12}}; local p=obs.export(assert(reader.capture(r,v))); assert(p.self.deck.total==44 and p.self.deck.by_rank==nil and p.self.deck.by_suit==nil)",
    'contradictory_pvp_flag_denied': "local r,v=reader_fixture(); v.phase='MULTIPLAYER_PVP'; v.recognition.pvp_context=false; r.G.GAME.blind={config={blind={key='bl_mp_nemesis'}},pvp=true}; v.opponent={certified=true,score_visible=true,displayed_score='SECRET'}; local p=obs.export(assert(reader.capture(r,v))); assert(p.opponent==nil or p.opponent.displayed_score==nil)",
    'failed_submit_consumes_token_before_aba': "local f=frame(); f.certificates.items[1].capacity_ok=true; local h=assert(obs.observe(f)); local original=h; local calls=0; local B=dofile(root..'/AISparring/integration/action_broker.lua').factory(obs,acts,{fixture='M2_FIXTURE_ONLY',capture=function() return h,1 end,validate=function() return true end,dispatch=function() calls=calls+1 end}); local t,p=B.issue(); f.self.money=999; h=assert(obs.observe(f)); assert(B.submit(t,p.actions[1])==nil); h=original; assert(not B.has_pending()); assert(B.submit(t,p.actions[1])==nil and calls==0)",
    'unobserved_aba_requires_revision': "local f=frame(); f.certificates.items[1].capacity_ok=true; local h=assert(obs.observe(f)); local epoch=1; local calls=0; local B=dofile(root..'/AISparring/integration/action_broker.lua').factory(obs,acts,{fixture='M2_FIXTURE_ONLY',capture=function() return h,epoch end,validate=function() return true end,dispatch=function() calls=calls+1 end}); local t,p=B.issue(); epoch=3; assert(B.submit(t,p.actions[1])==nil and calls==0)",
    'engine_vm_tripwire_precedes_mutation': "local mutations=0; local e=setmetatable({G={},jit={off=function() mutations=mutations+1 end}},{__index=_G}); e._G=e; local c=assert(loadfile(root..'/tools/lua/policy_env.lua')); setfenv(c,e); local helper=c(); assert(mutations==0); local function source(name) local f=assert(io.open(root..'/AISparring/ai/'..name..'.lua','rb')); local s=f:read('*a'); f:close(); return s end; assert(helper.configure(source('codec'),source('observation'),source('actions'))==false)",
    'lua_truthy_pvp_flag_masks': "local r,v=reader_fixture(); r.G.GAME.blind={config={blind={key='bl_small'}},pvp=0}; v.recognition.pvp_context=false; v.opponent={certified=true,score_visible=true,displayed_score='SECRET'}; local p=obs.export(assert(reader.capture(r,v))); assert(p.opponent==nil or p.opponent.displayed_score==nil)",
}

def main():
    failures = []
    executions = 0
    for runtime in ('lua51', 'luajit21'):
        factory = importlib.import_module('lupa.' + runtime).LuaRuntime
        for name, attack in ATTACKS.items():
            lua = factory()
            lua.globals().root = ROOT.as_posix()
            try:
                lua.execute(SETUP)
                lua.execute(attack)
                print('PASS', runtime, name)
            except Exception as exc:
                failures.append((runtime, name))
                print('FAIL', runtime, name, str(exc).splitlines()[0])
            executions += 1
    print(f'Unique Astra attacks: {len(ATTACKS)}; executions: {executions}; failures: {len(failures)}')
    return bool(failures)

if __name__ == '__main__':
    raise SystemExit(main())
