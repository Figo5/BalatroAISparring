# Claude reviews — first real staged match fixes

Reviewer: Claude Code 2.1.283, `claude-opus-5-5`, effort high, read-only. Date: 2026-09-29.

## Review 1 (Parts A/B; blocked on F1/F2)

# Review: match-start fixes (Part A: SELECT_BLIND element, Part B: pre-start window)

## Verdict: **BLOCKED**

Part A and Part B are both correct, and I accept them as written. The blocker is a separate defect in the round loop that the fake test fixtures hide. The AI cannot cash out after its first won blind, so a staged match would still end with the AI loop failing, just one round later. Since every staged-content change costs a full native re-certification, fix F1 (and ideally F2) before re-certifying.

This review was read-only. I read the code and the loaded game/mod source; I ran no tests.

## Findings

| ID | Severity | file:line | Scenario | Required fix |
|---|---|---|---|---|
| F1 | **High (blocker)** | `production_executor.lua:633-651`, `:1654-1667`; real source: `dump/functions/common_events.lua:1430-1443`, `dump/engine/ui.lua:101-116`, `dump/engine/moveable.lua:473-489`; fixture: `tests/engine/test_executor.lua:400-416` | The real cash-out button is built as its own UIBox that is only *positioned* relative to `G.round_eval` (`major = G.round_eval`). The box is thrown away after creation and is never added to `G.round_eval`'s element tree. `UIBox:get_UIE_by_ID` only searches its own tree, and `set_role` only stores `role.major`. So `G.round_eval:get_UIE_by_ID('cash_out_button')` always returns nil in the real game. After the AI wins its first blind, every `advance_ui` call returns `exec_element_missing`. The loop treats that as a transient wait (`decision_loop.lua:910-920`) and gives up after 120 s (`:102`, `:534-535`), which ends in `finish("error")` and the role is lost. If `wait_state` reports an external wait, it stalls forever instead. The fixture fakes a `round_eval` that directly contains the button, which the real engine never does. | Find the button through the UIBox registry: scan `G.I.UIBOX` (`dump/globals.lua:337-341`; boxes register at `ui.lua:92-97`) for a box whose `role.major == G.round_eval` and whose `get_UIE_by_ID('cash_out_button')` (normal indexing, pcall) returns an element with `config.button == 'cash_out'`. Keep the "wait until the tally button exists" behaviour. Rewrite the fixture so `round_eval:get_UIE_by_ID` returns nil and the button lives in a separate registry box. Add a test that a box belonging to an older `round_eval` is ignored. `G.FUNCS.cash_out` only reads and writes `e.config.button` (`button_callbacks.lua:2983-2986`). |
| F2 | High (rules fidelity; no crash) | `production_executor.lua:348`, `:476`, `:1065`; `engine_adapter.lua:558`, `:645-647`, `:1234`, `:1499`; real source: `dump/cardarea.lua:13-28, 35-36`, `smods/src/utils.lua:681-684`; fixture: `tests/engine/support.lua:134` | In this SMODS build, `CardArea.config` has a metatable and `card_limit` is computed by `__index`; writes go to `card_limits`, so it is never stored as a plain field. Both modules read it with `rawget`, which always returns nil, so `slot_room` always returns nil. Effects in real play: the adapter never offers and the executor never accepts buying a joker or consumable. Non-negative jokers from Buffoon packs are never offered, Ankh is never usable, and `joker_slots`/`hand_size`/`consumable_slots` are missing from the observation. The AI plays a degenerate game with no purchases. Fixtures pass because they use plain `config.card_limit`. | Read `area.config.card_limit` with protected normal indexing in both modules. Ideally mirror `check_for_buy_space` (`button_callbacks.lua:2444-2453`, which accounts for `ability.card_limit - extra_slots_used`) instead of the current "negative gets +1" rule. Make the fixture `config` metatable-backed like `cardarea.lua:13-28`. `highlighted_limit` is stored as a plain field and is fine. |
| F3 | Low (residual, fails safe) | `practice_host.py:2247-2257`, `practice_service.py:1279-1288` | The new window starts only after `_write_attestations` returns. If that write takes more than 90 s after `mark_attested` (it measured ~55 s; each role runs a ~40 s `check_certificate`), the watchdog still aborts before the files are published. That is correct fail-safe behaviour, but it is a timeout risk on a slow disk. | No change is required for this milestone. Record the margin (~35 s), or later make `write_launcher_attestation` reuse the certificate check result. |

## Part A: correctness (accepted)

- **Real element is used.** Non-PvP SELECT_BLIND now passes the real `select_blind_button` (`production_executor.lua:1467-1476`). That element's `UIBox` is the choice box, and its `ref_table` is `blind_choice.config = G.P_BLINDS[blind_choices[type]]` (`Multiplayer/ui/game/blind_choice.lua:13-15, 209-228`). That is exactly what `resolve_action_blind` returns (`production_executor.lua:206-219`), so the identity check holds.
- **`button` is always `select_blind` on the on-deck blind.** The definition sets it for every non-run_info choice. The choice handler re-sets it on the on-deck blind and clears it only on off-deck blinds (`button_callbacks.lua:2725-2731, 2770-2774`). The deferred event's reads (`:2596-2598`) and the MP wrapper's reads of `e.config.ref_table.key` (`Multiplayer/ui/game/functions.lua:72, 76`) are both satisfied.
- **Refusal cases are correct.** Missing element, wrong or absent `button`, and a `ref_table` mismatch all return `ELEMENT_MISSING` without invoking the callback (`:1468-1475`).
- **No `rawget` on the method.** The helper uses protected normal indexing for `get_UIE_by_ID` (`:269-275`).
- **The run_info variant is excluded.** It has no `button` field (`blind_choice.lua:243-254`).
- **PvP path is unchanged.** It still goes through `mp_toggle_ready` with the same lookup (`:1448-1456`, `:652-667`). The stored context replayed by `begin_pvp_blind` (`action_handlers.lua:322-324`) is the real element, so the deferred `e.UIBox` read is safe.
- **No authority or hidden-info change.** The executor still dispatches only the validated action type, re-validates under an unchanged epoch (`:1596-1606`), and nothing new reaches the policy.
- **Transient windows are covered.** After a skip, the on-deck button can be nil for about one frame. `skip_blind` sets `locks.skip_blind` for 2.5 s (`button_callbacks.lua:2805-2816`), and both the adapter (`engine_adapter.lua:760-761`) and the executor (`:395-398`) treat `CONTROLLER.locked` as blocked. `locked` is rebuilt from `locks` each frame (`dump/engine/controller.lua:189-194`).

## Part B: correctness (accepted)

- **Cannot extend past publication + 90 s.** The first call wins (`practice_service.py:1143`), and the host calls it only after a successful write (`practice_host.py:2250-2257`). If it is never called, the watchdog keeps using `attested_at` (`:1248-1253`).
- **Host-only.** It is not in `OPS` (`:82`), and unknown ops are rejected at `:1398`.
- **Correct no-op cases.** It does nothing before attestation or after start, end or abort (`:1138-1145`).
- **M8 order unchanged.** `mark_attested` still runs before the write (`practice_host.py:2247-2250`).
- **Early hello/setup is harmless.** Those ops are refused until attested (`ATTESTED_OPS`, `:117-125`). A hello arriving between attestation and publication can only start the window later, never beyond the host's call time.
- **Failed-write path is tested.** A failing write never starts the window (new host test).

## Further real-loop risks (item 3), ranked by likelihood

1. **Certain: cash-out never resolves (F1).** This hits at the first ROUND_EVAL, right after the AI's first won blind (Small blind, ante 1).
2. **Certain: no joker or consumable purchases, no Buffoon joker picks, Ankh unusable (F2).** It won't crash or stall, but it breaks rules fidelity for the whole match.
3. **The staged AI Mods tree still holds the old executor** (`staging/roles/ai/.../Mods/AISparring/integration/production_executor.lua:606, 619`). This is expected until re-certification. Confirm that the re-staged content hash includes F1 and F2.

Every other step of the loop matched the real source with no mismatch:

- **Hand draw and PLAY/DISCARD.** `apply_hand_selection` uses the real `CardArea` methods (`cardarea.lua:161-251`); `highlighted_limit` is stored as a plain field. Play ignores `e`, including through the MP timer wrapper (`timer.lua:582-588`). Discard changes state synchronously (`state_events.lua:506`).
- **Shop.** `buy_from_shop` reads only `e.config.ref_table` and `e.config.id` (`button_callbacks.lua:2456-2534`). `sell_card` reads only `e.config.ref_table` (`:2374-2378`). Reroll and `toggle_shop` ignore `e` (`:2926+`, `:2536-2566`).
- **Booster and voucher buttons.** They really do call `use_card`: `can_open`/`can_redeem` rewrite the button every frame (`:96-119`). No loaded mod defines `select_card`, so the fabricated element's missing `SMODS_use_card` is harmless. `skip_booster` ignores `e` (`:2616-2620`, `overrides/game.lua:107-113`). No stale shop area is possible because `CardArea:remove` sets `cards = nil` (`cardarea.lua:758-760`).
- **SKIP_BLIND.** The real choice UIBox is passed (`:2803-2843`, MP wrappers at `functions.lua:32-36, 82-107`).
- **First PvP blind.** Ready waits with no SELECT_BLIND offered (`engine_adapter.lua:1417-1420`). The countdown sets `locks.enter_pvp` (`timer.lua:203`). A one-frame stale `locked` after a `startBlind` message cannot lead to a dispatch, because submission always happens on a later update after `Controller:update`, and the broker re-captures before dispatching.

## Re-review (F1/F2 fixed on top of A/B)

# Re-review: round-loop fixes F1 and F2, on top of Parts A and B

## Verdict: **READY FOR RE-CERTIFICATION AND STAGED MATCH**

F1 and F2 are both fixed correctly against the real loaded source, and Parts A and B have not regressed. The item-4 sweep found no other raw read of an inherited or computed field. This was a read-only review: I used Read/Grep only and ran no tests. For test results I'm relying on the orchestrator's rerun you quoted.

## Findings

| ID | Severity | file:line | Scenario | Fix |
|---|---|---|---|---|
| — | — | — | No new High, Medium or Low findings. | — |
| F3 (carried) | Low, fails safe | `practice_host.py:2250-2257` | Unchanged from last review. The pre-start window still aborts if publishing takes more than 90 s. | None needed for this milestone. |
| Staging (carried) | Process | `staging/.../Mods/AISparring/integration/production_executor.lua:592-606` | The staged AI tree still has the old `G.round_eval:get_UIE_by_ID` resolver. This is expected before re-staging. | Check that the re-staged content hash includes this diff. |

**One non-blocking note (not reachable as far as I found):**
- Both the executor's booster pick (`production_executor.lua:1133`) and the adapter's (`engine_adapter.lua:1527`) still accept a negative joker unconditionally.
- This build's `can_select_card` (`button_callbacks.lua:2135-2145`) actually allows a Joker only when `#G.jokers.cards < card_limit + (ability.card_limit - ability.extra_slots_used)`. For a negative joker that means "fits one over the limit", not "always fits".
- The two only disagree if the joker count is already above the area limit at rest. I found no content in the AI tree (vanilla, SMODS, Multiplayer with majorleague) that produces that state.
- Optional tidy-up: drop the `is_negative(card) or` short-circuit and use `slot_room(G, "jokers", card, true) == true`.

## 1. F1 (cash-out button): correct

- **Registry scan.** `cash_out_button` (`production_executor.lua:349`) reads `G.I.UIBOX` as a dense array. That matches the real registry: boxes are added with `table.insert` (`ui.lua:96`) and removed with `table.remove` (`ui.lua:293-298`). It reads `role` and `get_UIE_by_ID` with protected normal indexing, and calls the method through `pcall`.
- **Current-round binding.** The box's `role.major` is set by `set_alignment` then `set_role` (`moveable.lua:97-105`, `478-481`). The later `set_role{xy_bond…}` call in `UIBox:init` (`ui.lua:33-45`) passes no `major`, so it keeps `major = G.round_eval`. `G.round_eval` has `set_role`, so the guard at `moveable.lua:474` does not return early.
- **No timing gap.** The box registers inside `UIBox:init` (`ui.lua:92-97`). That happens in the same event that later sets `G.GAME.current_round.dollars` (`common_events.lua:1433-1451`). So whenever the tally amount exists, the box is already registered. Position doesn't matter because `G.FUNCS.cash_out` only reads and writes `e.config.button` (`button_callbacks.lua:2983, 2986`).
- **Older rounds cannot match.**
  - `G.round_eval:remove()` (`button_callbacks.lua:2996`) doesn't remove the cash-out box, because the box isn't one of its children (`ui.lua:290-301`, `node.lua:344-348`). I found no other code path that removes it, so old boxes probably stay in `G.I.UIBOX` with `major` pointing at the removed round_eval.
  - Each round builds a fresh `G.round_eval` (`game.lua:3536`), so the `rawequal` check rejects every older box. That's about one extra box per round, far below `MAX_SCAN = 4096`.
- **Button validation.** It requires `config.button == 'cash_out'`, which matches `common_events.lua:1435`. The real callback clears `e.config.button` synchronously (`:2986`), so a second resolve before the removal event returns `ELEMENT_MISSING`. That blocks a double cash-out.
- **Transient wait kept.** A missing registry, box or button returns nil, and `advance_ui` (`:1757-1760`) turns that into `ELEMENT_MISSING`. `element_for` is still consulted first (`:727-732`).
- **Handy.** Its early return (`button_callbacks.lua:2983`) only fires after a human keybind sets `cashout_skipped` (`HandyBalatro/.../round.lua:59`). It doesn't apply to the AI role.
- **Fixtures now match the real shape.** `round_eval:get_UIE_by_ID` returns nil, and the button lives in a separate box with a metatable. There are tests for a stale major, a missing `button`, no registry, and a box with no button yet.

## 2. F2 (`card_limit` reads): correct at every site

- **Every site now uses `area_limit`**, which reads through `nget`. In the executor: `:440`, `:576`, `:1158`. In the adapter: `:610`, `:703-705`, `:1292`, `:1557`. Grep shows no `card_limit` read left on the raw path. `highlighted_limit` is correctly still read raw (`cardarea.lua:35`, which is a `__newindex` → `rawset`).
- **The metatable matches.** It's the same in `CardArea:init` (`cardarea.lua:13-28`) and on the save-load path (`cardarea.lua:719-728`), so reads work after loading a save too.
- **`buy_room` matches `check_for_buy_space`.** The formula `count + 1 + extra_slots_used <= limit + card_limit` is exactly `button_callbacks.lua:2448-2449`.
  - The area limit already subtracts slots used by cards in the area (`total_slots − extra_slots_used`, `utils.lua:3924-3927`).
  - `ability.card_limit` and `ability.extra_slots_used` are always stored as plain numbers (`card.lua:378-379, 398-399`). A negative edition adds `card_limit = 1` as a plain field (`overrides.lua:2216`; its config is `game_object.lua:3750`).
  - Negative ability values fall back to the old rule. Nothing in the AI tree produces them: Multiplayer's only edition, phantom, has `config = {}` (`phantom.lua:17`).
- **No slot check where the engine has none.** Playing cards (`kind "card"`, i.e. Default/Enhanced) are not slot-checked, matching `:2446-2447`. Vouchers and boosters go through their own validators (`production_executor.lua:1066-1108`) and are never slot-checked, which matches because they are opened/redeemed through `use_card`, not `buy_from_shop`.
- **Ankh.** `check_use_ok` (`count < limit`) matches `Card:check_use` (`card.lua:1928-1935`).
- **Observation.** `hand_size`, `joker_slots` and `consumable_slots` now carry the real computed values. MajorLeague has no layers, so the `1e5` shared-pockets slot inflation (`layers/shared_pockets.lua:7-8`) is not active.

## 3. Parts A and B: no regression

- `on_deck_blind_box` and `select_blind_button_of` are a straight extraction of the reviewed code. The same `blind_on_deck` and `blind_select_opts` lookups are used for skip, select and PvP-ready.
- `SELECT_BLIND` still checks `button == 'select_blind'` and the `ref_table` identity before invoking.
- The Python and doc parts of the diff are the Part B changes I reviewed last time.

## 4. Same-class sweep (inherited or computed fields): nothing found

| Raw read | Real runtime | Evidence |
|---|---|---|
| `center.key` (Ankh check, `center_key`) | Stored raw for vanilla centers, for SMODS/Multiplayer `j_mp_*` centers (the key is rewritten raw as `obj[key] = prefix..`), and for taken-over centers (fields copied raw). | `game_object.lua:24-37, 49, 269` |
| `center.replace_base_card`, `no_rank`, `no_suit` (`state_reader.lua:337`, `engine_adapter.lua:455`) | Stone gets them through `take_ownership`, which copies raw. The `SMODS.Enhancement` class has no class-level defaults for them, so inheritance can't hide them. Multiplayer defines no enhancements. | `game_object.lua:3371-3442, 269` |
| `ability.set`, `name`, `effect`, `consumeable`, `card_limit`, `extra_slots_used` | `Card:set_ability` builds a plain `ability` table by normally indexing the center. So a class-default `center.set` or `consumeable` on SMODS Jokers/Consumables ends up stored raw in `ability`. | `card.lua:344-395, 425-427`; `overrides.lua:2775-2851` |
| `card.edition.type` (and the edition table) | A plain table from `Card:set_edition`. `pairs(p_edition.config)` copies raw fields. The metatable `extra` alias on foil/holo/polychrome/negative is never copied or read by us. | `overrides.lua:2141-2161`; `game_object.lua:3650-3761` |
| `seal`, `debuff`, `cost`, `sell_cost`, `base.value`/`suit`, `facing`, `sprite_facing` | Plain fields on the card instance. | — |
| `game_object.lua:4066/4077` | These are scoring-calculation objects, and no integration module reads them (grep: 0 hits). | — |
| Multiplayer metatables | None on centers, cards or editions. The only `setmetatable` calls are the ruleset resolver (`rulesets/_rulesets.lua:151`) and timer UI `ref_table`s. | grep |

## Orchestrator resolution

- DeepSeek's first Part A helper fetched `get_UIE_by_ID` with rawget (nil on real UIBoxes, whose methods come from the class metatable); replaced with protected normal indexing and a metatable-backed fixture that fails on the rawget version.
- F1: G.I.UIBOX scan ceiling raised 256 -> 4096 and `role.major` compared with rawequal.
- Optional note applied: booster joker picks in executor and adapter now use the real `can_select_card` arithmetic (negative fits one over the limit, not unconditionally); test updated to real ability fields.
- F3 (pre-start margin ~35 s if publication exceeds 90 s) recorded; fails safe.
