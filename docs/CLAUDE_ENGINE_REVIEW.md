# Engine boundary review: adapter, executor and revision (read-only)

**Verdict: not accepted as playable.** I found 2 critical and 5 high findings. Each one either stops the AI permanently or breaks a privacy or rules requirement. The revision/stale-state chain and the callback argument shapes are correct. Once the items below are fixed, the boundary looks sufficient for a baseline AI.

## Critical

**C1. Picking a consumable from a booster pack skips the "can use" check, which can crash the game.**
- **Where:** `production_executor.lua:830-856` and `engine_adapter.lua:1198-1201`.
- **What vanilla does:** a consumable in a pack is used immediately, not stored. The UI only enables it when `can_use_consumeable` passes (`button_callbacks.lua:2102-2110`); `can_select_card` is only for non-consumables.
- **What goes wrong:** the executor only checks free consumable slots.
  - Picking Talisman, Deja Vu, Trance or Medium (`card.lua:1179-1186`), Aura (`1196`) or Cryptid (`1208`) with nothing highlighted crashes the game. The error happens inside a queued event, where `pcall` can't catch it.
  - Judgement, Soul or Wraith can over-fill the joker slots.
  - Planets and Tarots can't be picked at all when the consumable slots are full.
- **Fix:** for consumable pack cards, require `call_predicate(card, "can_use_consumeable") == true` in both files and drop the slot check.

**C2. `element_for` is never wired in production, so the AI stops at its first round evaluation.**
- **Where:** `core.lua:302` doesn't pass it, and `companion_host.lua:1304-1308` defaults it to "return nil".
- **Effect:**
  - Cash-out always fails (`production_executor.lua:1301-1306`), so the AI stops at the first round evaluation.
  - A PvP ready always fails (`892-896`).
  - `SKIP_BLIND` always fails.
- **Source-derived way to build the elements** inside the trusted executor:
  - **Cash-out:** `cash_out` only *writes* `e.config.button = nil` (`button_callbacks.lua:2915`). The claim in `ENGINE_ADAPTER.md:75` that it "reads" it is wrong.
  - **Skip:** `skip_blind` needs `e.UIBox:get_UIE_by_ID('tag_container')` (`2754`). Use `{UIBox = G.blind_select_opts[lower(on_deck)]}`.
  - **PvP ready:** use `G.blind_select_opts[lower(on_deck)]:get_UIE_by_ID('select_blind_button')`. Its `config.ref_table` is the blind config (`mp/ui/game/blind_choice.lua:210-228`).

## High

**H1. Packs opened under SMODS can never be skipped.**
- SMODS puts every pack in the `SMODS_BOOSTER_OPENED` state (`smods-booster.toml:34-37`). It also patches `can_skip_booster` to always allow a skip in that state (`toml:124-126`).
- The adapter (`engine_adapter.lua:1217`) and executor (`production_executor.lua:869`) don't include that state. So Buffoon, Celestial and Standard packs (no hand drawn) never offer a skip.
- A Buffoon pack with full joker slots, or a Celestial pack with full consumable slots (see C1), leaves no legal action and the AI gets stuck.
- The tests use the vanilla `STANDARD_PACK` state (`test_executor.lua:333`, `astra_playable_attacks.py:91`), which never occurs under SMODS.
- **Fix:** add `SMODS_BOOSTER_OPENED` to both skip checks.

**H2. Candidate generation leaks the identity of face-down cards.**
- `hand_selections` (`engine_adapter.lua:872-920`) groups cards by the raw rank and suit of every hand card, without checking whether the card is face-up.
- `actions.lua:298-344` accepts hand ids that point at hidden cards.
- Under The House, Wheel, Mark or Fish, a rank-pair or five-card suit group reveals hidden ranks and suits.
- **Fix:** exclude face-down cards, and Stone/no-rank/no-suit cards, from rank and suit grouping.

**H3. The AI can bypass Cerulean Bell's forced selection.**
- `production_executor.lua:1101-1106` calls `remove_from_highlighted(card, true)`. The `true` (force) skips the forced-selection guard (`cardarea.lua:187-188`).
- Play and discard then clear the forced flag (`state_events.lua:384-386`, `459-461`), so the rule is gone.
- The same code also misses a silent drop when `add_to_highlighted` hits the 5-card limit (`cardarea.lua:149-150`).
- **Fix:** remove highlights without force, and require forced cards to be part of the selection with a total of 5 or fewer. After adding, check that the actual highlighted set equals the requested set before calling the callback.

**H4. Actions the adapter offers but the executor refuses end the AI's session.**
The loop stops after 3 consecutive errors (`decision_loop.lua:264-266`), and a deterministic policy will pick the same refused action again. Systematic cases:
- **(a) PvP after readying.** `SELECT_BLIND` is still offered while `ready_blind == true` (`engine_adapter.lua:1150-1161`), but the executor refuses it (`production_executor.lua:898-900`). While the human hasn't readied yet, the AI dies. Emit no blind actions in that state; an empty set makes the loop back off and wait (`decision_loop.lua:682-698`).
- **(b) `SKIP_BLIND` on the Boss.** The Boss's state becomes `'Select'`, but vanilla only has a skip button on Small/Big. If `element_for` were wired naively, the MP wrapper would count a skip that has no effect (`mp functions.lua:83-106`), and the executor would stall until its fault. Limit skips to Small/Big where a `tag_container` exists.
- **(c) `USE_CONSUMABLE` is offered optimistically** (`engine_adapter.lua:1018-1034`), but the executor then refuses it (e.g. Familiar or Aura in the shop, Emperor with full slots). Either let the adapter call the same read-only checks the executor uses (`Card:can_use_consumeable`, `Card:can_sell_card`), or have the executor filter the offered actions.

**H5. A callback that does nothing causes a permanent stall.**
- Ankh with full joker slots passes `can_use_consumeable` (`card.lua:1536`). `use_card` then returns early after `check_use` (`button_callbacks.lua:2163-2169`).
- `invoke` treats the `nil` return as success. The "card left its area" anchor never fires, and after 10 seconds the stall fault is raised.
- `executor.cancel` is never called by the broker or loop, so the fault is terminal.
- **Fix:** `use_card` removes the card synchronously (`2209`). For use-based commits, check right after the callback that the card left its area; if it didn't, return `CALLBACK_FAILED` with no latch. Also mirror the Ankh `check_use` in validation.

## Medium
- **M1. Hand candidates are too narrow for a baseline.** With an 8-card hand, singles plus all 28 pairs fill the cap of 40 before any 3–5 card groups (`engine_adapter.lua:922-939`).
  - The AI never gets two pair, full house, straights, or 3–5 card junk discards.
  - Fix: build structured hands first (groups, two pair, full house, straights over visible ranks, flushes, discard sets), put the lexicographic pairs last, and cap each type.
- **M2. Several executor checks rely entirely on the offered actions.** Buy, open, voucher, reroll, leave, blind, skip and booster-select never check `gates_clear`. They are only safe because a blocked view offers no actions. Add `gates_clear` so the executor's legality check holds on its own.
- **M3. Targeted consumables can't be used.** `target_selection` is unwired, so the consumable-target phase never occurs. Separately, `validate_use_consumeable` checks `can_use` before applying the target highlights, so a `USE_CONSUMABLE` with targets can never pass validation. The doc's `engine_no_decision_state` code is never returned. It's acceptable for the baseline to exclude targeted consumables, but then drop them per H4c.

## Low
- **L1.** Reordering reads `align_cards` via `rawget` (`production_executor.lua:1227`), which is always nil on a real card area. It only works because `CardArea:move` aligns every frame. `set_ranks` is never called, and pinned jokers get re-sorted (`cardarea.lua:528`).
- **L2.** The real discard area's `card_limit` is 500 (`game.lua:2250`), so the observation reports `max_discard = 500`. Use the hand's highlight limit (5) instead.
- **L3.** The executor is stricter than vanilla for negative jokers in packs (vanilla: `button_callbacks.lua:2113`).
- **L4.** Selling is under-offered at ante 1 on a fresh staged profile (vanilla also allows it for non-tutorial seeds: `card.lua:1646`).
- **L5.** The stall clock uses wall time, so pausing or dragging the window can cause false stall faults.

## Verified correct
- **Callback argument shapes:** buy, sell and use callbacks take `{config={ref_table=card}}`, matching vanilla and the MP wrappers. `select_blind` takes the blind config as `ref_table`, which is what the MP wrapper reads. `mp_toggle_ready` stores the element for the server's later `startBlind`.
- **Raw reads and method calls:** all raw reads hit instance fields, and predicate/highlight methods correctly go through normal metatable indexing.
- **Completion anchors:** each anchor is captured before its callback, is specific to the action, and no generic revision change releases it.
- **Stale state:** stale state is caught by the epoch-plus-canonical checks around validation. Validate and dispatch run in the same synchronous submit, so positional refs stay stable.
- **Timer:** not projecting a timer veto is correct.
- **Opponent visibility:** the opponent projection respects the hands/score/location masks.
- **Terminal detection:** `runtime_bootstrap.lua:695` reads `MP.GAME.won`.

One gap in my evidence: `engine/controller.lua` isn't in the extracted references, so I couldn't confirm from source how `G.CONTROLLER.locked` is derived. Its use in MP `timer.lua:455` is consistent with the adapter's reading.

## What the fixtures hide
- **Callbacks:** they are recorders, with no event queue, no queued errors, no `false` or no-op returns, and no `Card:is` method.
- **Card areas:** the highlight functions ignore the 5-card limit, the force flag and forced selection. There is no `align_cards`/`set_ranks`, discard is 5 instead of 500, and consumeables have a different area type than the real `'joker'`.
- **Predicates:** they are fake, and `can_use_consumeable` ignores state and highlights.
- **Pack states:** the tests use vanilla pack states that can't occur under SMODS.
- **Wiring:** tests inject `element_for` and `target_selection`, but production wires neither.
- **Face-down cards:** no test covers face-down or Stone cards in candidate grouping.

I ran no commands and made no edits. Plan mode asked for a plan file and an exit step, but neither tool was available in this session, so the whole review is here. Separately, the Gmail, Google Calendar and Google Drive connectors need authorizing in claude.ai connector settings before they can be used.
