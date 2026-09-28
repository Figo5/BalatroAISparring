"""Independent source-shape regressions for the playable adapter/executor.

No game launch, live writes or network. Run with bundled Python + lupa deps.
"""
from pathlib import Path
import importlib
import sys

ROOT = Path(__file__).resolve().parent.parent
PREFIX = """
local support = dofile(ROOT .. '/tests/engine/support.lua')
local bundle = support.bundle(ROOT)
local function setup(opts)
  local engine = support.engine(opts or {})
  local pipe = support.pipeline(bundle, engine)
  return engine, pipe
end
local function candidates(pipe)
  local handle, code = pipe.executor.capture()
  assert(handle, tostring(code))
  return bundle.actions.generate(handle), bundle.obs.export(handle)
end
"""
CASES = {
    "cash_out_waits_for_round_tally_button": """
local e,p = setup({state=support.STATES.ROUND_EVAL})
e.G.round_eval = {get_UIE_by_ID=function() return nil end}
e.G.GAME.current_round.dollars = nil
local ok = p.executor.advance_ui()
assert(ok ~= true, 'cash-out dispatched before actual button/tally exists')
for _,call in ipairs(e.calls) do assert(call.name~='cash_out') end
""",
    "hidden_rank_suit_cannot_change_candidates": """
local function catalogue(rank, suit)
  local hand = {
    support.card({rank='Ace',suit='Hearts'}),
    support.card({rank='7',suit='Clubs'}),
    support.card({rank=rank,suit=suit,facing='back',sprite_facing='back'}),
    support.card({rank='Queen',suit='Hearts'}),
    support.card({rank='4',suit='Hearts'}),
    support.card({rank='9',suit='Hearts'}),
    support.card({rank='2',suit='Diamonds'}),
    support.card({rank='6',suit='Spades'}),
  }
  local e,p = setup({hand=hand})
  local list = candidates(p)
  local out = {}
  for _,a in ipairs(list) do
    if a.card_refs then out[#out+1] = a.type .. ':' .. table.concat(a.card_refs, ',') end
  end
  table.sort(out)
  return table.concat(out, '|')
end
assert(catalogue('Ace','Hearts') == catalogue('3','Clubs'),
  'hidden rank/suit changed the policy-visible candidate catalogue')
""",
    "smods_booster_can_skip_with_no_hand": """
local e,p = setup({state=support.STATES.SMODS_BOOSTER_OPENED,pack_cards={},hand={}})
local list = candidates(p)
for _,a in ipairs(list) do if a.type=='SKIP_BOOSTER' then
  assert(p.executor.validate(a), 'SMODS skip rejected by executor')
  return
end end
error('SMODS booster with no usable card has no escape action')
""",
    "pack_targeted_card_not_offered_without_targets": """
local card = support.card({set='Spectral',center_set='Spectral',consumeable_data={},center='c_cryptid',usable=false})
local e,p = setup({state=support.STATES.SMODS_BOOSTER_OPENED,pack_cards={card},hand={}})
local list = candidates(p)
for _,a in ipairs(list) do
  assert(a.type~='SELECT_BOOSTER_ITEM', 'unusable pack consumable offered as executable')
end
""",
    "opponent_update_does_not_release_queued_purchase": """
local card = support.card({set='Joker',center_set='Joker',center='j_joker',cost=3})
local e,p = setup({state=support.STATES.SHOP,shop_jokers={card}})
local calls = 0
e.G.FUNCS.buy_from_shop = function() calls = calls + 1 end
local list = candidates(p)
for _,a in ipairs(list) do if a.type=='BUY_ITEM' then
  assert(p.executor.validate(a))
  assert(p.executor.dispatch(a))
  e.MP.GAME.enemy.lives = (e.MP.GAME.enemy.lives or 3) - 1
  if p.executor.validate(a) then p.executor.dispatch(a) end
  assert(calls == 1, 'unrelated opponent update released pending purchase')
  return
end end
error('missing purchase positive control')
""",
    "deferred_purchase_cannot_dispatch_twice": """
local card = support.card({set='Joker',center_set='Joker',center='j_joker',cost=3})
local e,p = setup({state=support.STATES.SHOP,shop_jokers={card}})
local calls = 0
e.G.FUNCS.buy_from_shop = function() calls = calls + 1 end
local list = candidates(p)
for _,a in ipairs(list) do if a.type=='BUY_ITEM' then
  assert(p.executor.validate(a))
  assert(p.executor.dispatch(a))
  local valid = p.executor.validate(a)
  if valid then p.executor.dispatch(a) end
  assert(calls == 1, 'same queued purchase committed twice before engine transition')
  return
end end
error('missing purchase positive control')
""",
    "consumable_table_classification": """
local card = support.card({set='Tarot',center_set='Tarot',consumeable_data={},center='c_hermit',cost=3})
local e,p = setup({state=support.STATES.SHOP,shop_jokers={card}})
local list,obs = candidates(p)
assert(obs.shop.items[1].kind == 'consumable', 'real consumeable table classified as card')
""",
    "opponent_masked_hands_not_raw": """
local e,p = setup({info_received=true,enemy_hands=3,hands_text='???'})
local list,obs = candidates(p)
assert(not obs.opponent or obs.opponent.hands == nil, 'raw hidden hands leaked')
""",
    "nonadjacent_pair_candidate": """
local e,p = setup({hand={support.card({rank='Ace'}),support.card({rank='2'}),support.card({rank='Ace'})}})
local list = candidates(p)
for _,a in ipairs(list) do
  if a.type == 'PLAY_CARDS' and #a.card_refs == 2 and a.card_refs[1]=='hand:1' and a.card_refs[2]=='hand:3' then return end
end
error('bounded catalogue missed obvious nonadjacent pair')
""",
    "explicit_engine_rejection_not_success": """
local card = support.card({set='Joker',center_set='Joker',center='j_joker',cost=3})
local e,p = setup({state=support.STATES.SHOP,shop_jokers={card}})
e.G.FUNCS.buy_from_shop = function() return false end
local list = candidates(p)
for _,a in ipairs(list) do if a.type=='BUY_ITEM' then
  assert(p.executor.validate(a))
  local ok = p.executor.dispatch(a)
  assert(ok ~= true, 'callback false reported as successful dispatch')
  return
end end
error('missing buy positive control')
""",
    "certified_skip_booster_dispatches": """
local card = support.card({rank='2'})
local e,p = setup({state=support.STATES.STANDARD_PACK,pack_cards={card}})
local list = candidates(p)
for _,a in ipairs(list) do if a.type=='SKIP_BOOSTER' then
  assert(p.executor.validate(a))
  local ok,code = p.executor.dispatch(a)
  assert(ok == true, 'certified skip cannot dispatch: '..tostring(code))
  assert(e.calls[#e.calls].name=='skip_booster')
  return
end end
error('missing skip positive control')
""",
}

def main():
    failed = 0
    for runtime in ("lua51", "luajit21"):
        LuaRuntime = importlib.import_module("lupa." + runtime).LuaRuntime
        for name, source in CASES.items():
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().ROOT = ROOT.as_posix()
            try:
                lua.execute(PREFIX + source)
            except Exception as exc:
                failed += 1
                print(f"FAIL {runtime}::{name}: {exc}")
            else:
                print(f"PASS {runtime}::{name}")
    print(f"{len(CASES)} cases / {len(CASES)*2} executions / {failed} failures")
    return bool(failed)

if __name__ == "__main__":
    sys.exit(main())
