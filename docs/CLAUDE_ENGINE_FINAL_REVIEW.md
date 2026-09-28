Review captured 2026-09-28. Invocation: `claude-opus-5-5 --effort high`; read-only. Reviewed HEAD `bbf61bf43f1a8be93ac71cc9ca7c0b96a670be8f`.

I've re-reviewed the current code at `bbf61bf` against the pinned game, Multiplayer and SMODS sources. My verdict is **blocked, with three small, local High findings.** Most of the prior findings are properly fixed, but one fix went too far and two new ways for the AI to stop permanently remain. I made no edits, ran nothing, and used no subagents or network. This session had no file-write or plan-exit tool, so the plan-mode file wasn't created and the whole report is below.

## Prior findings

| ID | Status | Evidence |
|---|---|---|
| C1 pack consumables | **Fixed.** One gap remains (new High B). | Adapter and executor both require `can_use_consumeable` (`engine_adapter.lua:1423`, `production_executor.lua:996`). The free-slot check is gone. |
| C2 `element_for` / cash-out | **Fixed** | Elements are now built from the real UI: `cash_out_button` (matches `common_events.lua:1071`), `{UIBox=blind_select_opts[on_deck]}` for skip, and `select_blind_button` for PvP ready (`blind_choice.lua:210-228`). |
| H1 SMODS pack skip | **Over-corrected** (new High A) | The state was added, but the check that pack cards exist was dropped. |
| H2 hidden-card leak / Stone | **Fixed** | `grouping_identity` (`engine_adapter.lua:396`) only uses cards that are face-up and not Stone, `replace_base_card`, `no_rank` or `no_suit`. The reader masks Stone rank and suit (`state_reader.lua:327-373`). The candidate list now depends only on visible data. |
| H3 forced selection | **Fixed in the executor.** The adapter still offers selections the executor refuses (Medium 1). | Highlights are removed without force, forced cards must be in the selection, and the highlighted set must match exactly after adding. |
| H4a PvP after ready | **Fixed** | After readying, the remaining joker-reorder candidates settle, because `reorder_score` only accepts a strict improvement. |
| H4b Boss skip | **Fixed** | Skips are limited to Small and Big in both the adapter and the executor. |
| H4c use optimism | **Fixed for held consumables** | Adapter uses the predicate plus an Ankh check. |
| H5 no-op callback | **Fixed for `USE_CONSUMABLE`** | Checks the card left its area right after the callback (`production_executor.lua:1548-1551`). The same no-op still happens via a pack pick (High B). |
| M1, M2, L1–L4 | **Fixed** | M3: targeted consumables fail closed, which is acceptable. |
| L5 wall-clock stall | Open | Needs an actual-engine check. |
| Stale / ABA revision, pending latch | **Correct** | Completion anchors are taken before the callback. `broker.cancel` doesn't clear the executor's fault. ABA changes that happen entirely between two captures can't be detected, as documented. |
| Timer continuity | **Correct in code** | The AI side never writes to any timer. Needs an actual-engine check. |
| `G.CONTROLLER.locked` evidence gap | **Closed** | `controller.lua:186-194` rebuilds `locked` from `locks` every frame. `Game:update` runs `CONTROLLER:update` (`game.lua:2638`) before the companion step. So the capture one frame after a dispatch sees `locks.use`. |

## High (blocking)

**A. SMODS packs can be skipped before any cards appear.**
- **Where:** `engine_adapter.lua:1449-1450` and `production_executor.lua:1019-1020`.
- **Reason:**
  - The SMODS patch only adds its state inside the check (`smods-booster.toml:124-126`). Its skip button still requires `G.pack_cards and G.pack_cards.cards[1]` (`button_callbacks.lua:2133-2134`).
  - After opening, the pack's cards are created 0.4 + 1.3·√gamespeed seconds later (`card.lua:1721-1790`). The opened booster leaves the play area about halfway through.
  - That leaves a gap where `G.pack_cards` is empty, all gates are clear, and `SKIP_BOOSTER` is the only candidate. The AI would skip every pack it pays for without seeing it, which the real UI never allows.
- **Minimal fix:**
  - Use the SMODS-patched rule in both files: `pack_cards.cards[1] and (SMODS or PLANET or STANDARD or BUFFOON or hand cards[1] or hand limit <= 0)`.
  - Update `astra_playable_attacks.py:57-65` and `test_executor.lua:585-592`, which currently lock in the empty-pack skip. The fixture should have a pack card and an empty hand.

**B. Ankh picked from a Spectral pack with full joker slots stops the AI.**
- **Where:** `engine_adapter.lua:1423` and `production_executor.lua:992-998`.
- **Reproduction:**
  1. Ankh's `can_use_consumeable` passes (`card.lua:1536-1543`), so it is offered.
  2. `use_card` returns early at `check_use` (`card.lua:1581-1588`, `button_callbacks.lua:2163-2169`). Ankh stays in `pack_cards`, and `CALLBACK_FAILED` is reported.
  3. The policy scores every pack pick at 180 against 60 for a skip, and it is deterministic. It picks Ankh again, and after 3 errors the loop stops (`decision_loop.lua:501-508`).
- **Minimal fix:** move the existing Ankh slot check into a shared helper and apply it in `cert_booster` and `validate_select_booster`.

**C. Waiting for the human's PvP turn ends the AI after 120 seconds.**
- **Where:** `runtime_bootstrap.lua:267-272`.
- **Reason:**
  - The PvP "no hands left" wait is only recognised when `MP.GAME.pvp_reached` is true. Multiplayer sets that only when the player readies (`functions.lua:20`) and resets it to false when the PvP blind starts (`action_handlers.lua:353`).
  - After the AI's last PvP hand, it stays in `HAND_PLAYED` until `end_pvp` (`game_state.lua:188-233`). Capture keeps failing there, which counts as a transient error, and no wait state applies.
  - The loop stops after 120 seconds (`decision_loop.lua:102, 527-536`). The human commonly takes longer than that after the AI finishes.
  - The fixture at `test_runtime_bootstrap.lua:447-452` sets `pvp_reached = true`, which can't happen at that point in a real match.
- **Minimal fix:** report `PVP_NO_HANDS` when the current blind is PvP (`blind.pvp` or `bl_mp_nemesis`), hands left is 0 or less, and neither `end_pvp` nor `round_ended` is set. Don't depend on `pvp_reached`.

## Medium (not blocking)

1. **Forced selection candidates:** `hand_selections` offers plays that leave out a Cerulean Bell forced card, which the executor refuses (`production_executor.lua:859-867`). With a deterministic policy, 3 refusals stop the loop. This can't happen in Attrition or Major League (the showdown boss slot is PvP). Fix: filter those selections out in `cert_play_discard`.
2. **Repeated failures:** the loop asks the same deterministic policy again after a validate or dispatch failure when the revision (epoch) hasn't changed. Any future adapter/executor mismatch therefore stops the AI. As a safety net, exclude a failed action id for that epoch.

## Low

- Cash-out (`production_executor.lua:1574-1593`) doesn't check `G.CONTROLLER.locked` or `e.config.button == 'cash_out'` (the button has `one_press`).
- The skip element (`production_executor.lua:598-602`) doesn't check that `tag_container` exists. The Multiplayer skip wrapper sends a skip even when the skip had no effect.
- Selling a card with a Multiplayer persistent sticker isn't gated on its sell price (`1_persistent.lua:39-41`). This only matters if a ruleset turns that sticker on.

## Pending actual-engine checks (not defects)

- The exact pack-open timing gap (confirms A).
- Timing of the cash-out button appearing.
- The 10-second stall limit under different game speeds, a minimised window, or window dragging (L5).
- The PvP ready → server `startBlind` → `select_blind` round trip, including Handy (`Handy.lua:103-119` uses `select_blind_button`).
- Timer continuity while the AI waits.
- Stone and face-down behaviour in the actual engine.
- The next-frame lock checks after `use_card`, `sell_card` and `skip_blind`.

## Verdict

**Blocked** for staged testing where the AI actually plays, until A, B and C are fixed and pass a targeted re-review. Each fix is a few lines. Nothing here requires unsafe live testing first. Once the three are fixed, I see nothing else in scope that should stop controlled staged measurement.
