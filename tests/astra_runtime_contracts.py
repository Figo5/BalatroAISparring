"""Independent cross-module protocol checks. No game, socket or live files."""
from pathlib import Path
import importlib
import sys

ROOT = Path(__file__).resolve().parent.parent
CASES = {
    "control_throwing_push_preserves_capacity_and_sequence": r'''
local support=dofile(ROOT..'/tests/runtime/support.lua')
local Transport=dofile(ROOT..'/AISparring/integration/control_transport.lua')
local json=support.json(ROOT)
local fail=true
local sent={}
local transport=assert(support.transport(ROOT,{channels={
  to_worker={push=function(_,line)
    if fail then error('synthetic channel failure') end
    sent[#sent+1]=json.decode(line)
  end},
  from_worker={pop=function() return nil end}
}}))
assert(transport.start())
local id,code=transport.send('status',{})
assert(id==nil and code=='transport_push_failed')
fail=false
for i=1,Transport.LIMITS.max_inflight do assert(transport.send('status',{})) end
assert(#sent==Transport.LIMITS.max_inflight and sent[1].sequence==1)
assert(transport.send('status',{})==nil)
''',
    "control_queue_refusal_does_not_send_untracked_frame": r'''
local support=dofile(ROOT..'/tests/runtime/support.lua')
local Transport=dofile(ROOT..'/AISparring/integration/control_transport.lua')
local sent={}
local transport=assert(support.transport(ROOT,{channels={
  to_worker={push=function(_,line) sent[#sent+1]=line end},
  from_worker={pop=function() return nil end}
}}))
assert(transport.start())
for i=1,Transport.LIMITS.max_inflight do assert(transport.send('status',{})) end
local before=#sent
local id,code=transport.send('end',{result='aborted'})
assert(id==nil and code=='transport_queue_full')
assert(#sent==before,'queue refusal nevertheless sent an untracked command')
''',
    "menu_accepts_actual_object_instance_shape": r'''
dofile(ROOT..'/work/reference/game/engine/object.lua')
local GameShape=Object:extend()
local ui=dofile(ROOT..'/tests/menu/fakeui.lua').new()
local game=GameShape()
for k,v in pairs(ui.G) do game[k]=v end
assert(getmetatable(game)~=nil)
ui.G=game
local menu,code=dofile(ROOT..'/AISparring/ui/practice_menu.lua').factory(ui)
assert(menu~=nil,'real Object instance G rejected: '..tostring(code))
''',
    "ai_start_uses_real_run_stage_without_invented_flags": r'''
local Driver=dofile(ROOT..'/AISparring/integration/mp_driver.lua')
local mp={LOBBY={code='ABC12',config={}}}
local game={STAGES={RUN=2,MAIN_MENU=1},STAGE=1}
local d=assert(Driver.factory({role='ai',mp=mp,G=game,funcs={}}))
assert(not d.is_started())
game.STAGE=game.STAGES.RUN
assert(mp.is_started==nil and mp.LOBBY.started==nil)
assert(d.is_started(),'AI failed to observe actual Multiplayer RUN stage')
''',
    "majorleague_force_resolves_real_proxy_shape": r'''
local Driver=dofile(ROOT..'/AISparring/integration/mp_driver.lua')
local mp={LOBBY={config={ruleset='ruleset_mp_majorleague'}}}
local forced=0
local rules={forced_gamemode='gamemode_mp_attrition',is_disabled=function() return false end,
force_lobby_options=function()
  forced=forced+1
  mp.LOBBY.config.timer_base_seconds=180
end}
mp.Rulesets={ruleset_mp_majorleague=rules}
mp.current_ruleset=function() return setmetatable({}, {__index=function(_,k) return rules[k] end}) end
local funcs={start_lobby=function()
  mp.LOBBY.config.custom_seed='random'
  mp.current_ruleset():force_lobby_options()
  mp.LOBBY.code='ABC12'
end}
-- A legacy Major League fixture opts into its own registry explicitly; the
-- production default remains the Standard Ranked registry.
local d=assert(Driver.factory({role='human',mp=mp,funcs=funcs,
  ruleset_key='ruleset_mp_majorleague',ruleset_short='majorleague'}))
local ok,code=d.host_start(nil)
assert(ok==true and forced==1 and mp.LOBBY.config.timer_base_seconds==180,
  'real proxy force_lobby_options was skipped: '..tostring(code))
''',
    "control_channels_accept_userdata_methods": r'''
local support=dofile(ROOT..'/tests/runtime/support.lua')
local sent={}
local function channel(methods)
  local value=newproxy(true)
  getmetatable(value).__index=methods
  return value
end
local outbound=channel({push=function(self,line) sent[#sent+1]=line end})
local inbound=channel({pop=function() return nil end})
local transport,code=support.transport(ROOT,{channels={to_worker=outbound,from_worker=inbound}})
assert(transport~=nil,'LÖVE Channel userdata rejected: '..tostring(code))
assert(transport.start())
assert(transport.send('status',{}))
assert(#sent==1,'channel method not called')
''',
    "ready_lookup_supports_real_uibox_inherited_method": r'''
local Driver=dofile(ROOT..'/AISparring/integration/mp_driver.lua')
local mp={LOBBY={code='TEST12',ready_to_start=false,config={}}}
-- Execute the locally held engine's actual class and lookup definitions.
-- Nothing is rendered or initialized; only its real lookup is exercised.
dofile(ROOT..'/work/reference/game/engine/object.lua')
Moveable=Object:extend()
dofile(ROOT..'/work/reference/game/engine/ui.lua')
local button={config={id='lobby_menu_start'},children={},UIBox={}}
local box=setmetatable({UIRoot={config={},children={button}}},UIBox)
assert(rawget(box,'get_UIE_by_ID')==nil and box:get_UIE_by_ID('lobby_menu_start')==button)
local called=0
local driver=assert(Driver.factory({role='ai',mp=mp,G={MAIN_MENU_UI=box},
  funcs={lobby_ready_up=function(e)
    assert(e==button)
    called=called+1
    mp.LOBBY.ready_to_start=true
  end}}))
local ok,code=driver.ai_ready()
assert(ok==true,'real UIBox method was not resolved: '..tostring(code))
assert(driver.ai_ready()==true and called==1,'ready toggled more than once')
''',
    "revision_wrapper_preserves_return_arity_and_nil_holes": r'''
local Runtime = dofile(ROOT .. '/AISparring/integration/runtime_bootstrap.lua')
local owner = {f=function(x) return x, nil, 'third' end}
local bumps=0
local restore=Runtime.install_hooks({{table=owner,name='f',reason='test'}},
  {bump=function() bumps=bumps+1 end})
local function pack(...) return {n=select('#',...),...} end
local result=pack(owner.f('first'))
assert(result.n==3 and result[1]=='first' and result[2]==nil and result[3]=='third',
  'revision hook changed engine callback return values')
assert(bumps==1)
restore()
assert(pack(owner.f('restored')).n==3)
''',
    "control_wire_sequence_monotonic_across_decision": r'''
local support = dofile(ROOT .. '/tests/runtime/support.lua')
local json = support.json(ROOT)
local sent = {}
local to_worker = {push=function(self, line) sent[#sent+1] = json.decode(line) end}
local from_worker = {pop=function() return nil end}
local t = assert(support.transport(ROOT, {channels={to_worker=to_worker,from_worker=from_worker}}))
assert(t.start())
assert(t.send('status', {}))
assert(t.request({sequence=1000000, observation={}}))
assert(t.send('status', {}))
assert(#sent == 3)
assert(sent[1].sequence < sent[2].sequence and sent[2].sequence < sent[3].sequence,
  'one service role sequence counter rejects heartbeat following decision')
''',
    "timer_penalty_messages_are_not_silenced": r'''
local Driver = dofile(ROOT .. '/AISparring/integration/mp_driver.lua')
local d = assert(Driver.factory({role='ai',mp={LOBBY={config={}}},funcs={}}))
for _,action in ipairs({'failTimer','failPvPTimer','startAnteTimer','pauseAnteTimer'}) do
  assert(d.guard_allows(action), 'legitimate timer action suppressed: '..action)
end
''',
    "guest_cannot_change_lobby_options": r'''
local Driver = dofile(ROOT .. '/AISparring/integration/mp_driver.lua')
local d = assert(Driver.factory({role='ai',mp={LOBBY={is_host=false,config={}}},funcs={}}))
assert(not d.guard_allows('lobbyOptions'), 'guest lobby configuration not blocked')
''',
}

def main():
    failures = 0
    for runtime in ('lua51', 'luajit21'):
        factory = importlib.import_module('lupa.' + runtime).LuaRuntime
        for name, source in CASES.items():
            lua = factory(unpack_returned_tuples=True)
            lua.globals().ROOT = ROOT.as_posix()
            try:
                lua.execute(source)
                print(f'PASS {runtime}::{name}')
            except Exception as exc:
                failures += 1
                print(f'FAIL {runtime}::{name}: {exc}')
    print(f'{len(CASES)} cases / {2*len(CASES)} executions / {failures} failures')
    return bool(failures)

if __name__ == '__main__':
    sys.exit(main())
