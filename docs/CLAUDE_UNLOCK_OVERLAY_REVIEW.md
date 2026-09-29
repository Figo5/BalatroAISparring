# Review: vanilla unlock-overlay dismissal (on 57fb6f4 + reviewed diagnostics)

## Verdict: **READY for re-certification**

There are no Critical or High findings. The identity check is exact against the loaded source, calling `continue_unlock` from the update hook behaves like a real click, and none of the new code sends any Multiplayer traffic. One Medium and a few Low findings should be fixed before V1 acceptance, but none blocks re-certification.

## Answers to the five questions

**1. Identity precision: exact.**
- The only two uses of `'continue_unlock'` in the loaded, patched source are `functions/UI_definitions.lua:4584` (card unlock) and `:4651` (deck unlock). Neither passes `back_id`, so the back element is `id='overlay_menu_back_button'` with `button=back_func` (`UI_definitions.lua:6815`).
- The Multiplayer, SMODS and HandyBalatro sources contain no `continue_unlock`, no `back_id` and no replacement of `create_UIBox_{card,deck}_unlock`.
- SMODS's only unlock-UI patch (`smods/lovely/ui_elements.toml:188-206`) adds description text and leaves the back button alone.
- `button_delay` would move `config.button` into `button_temp` (`engine/ui.lua:1043-1045`), but unlock popups never set `back_delay`, so `config.button` is there on the first frame.
- `UIBox:get_UIE_by_ID` (`engine/ui.lua:101-116`) walks depth-first and finds the back R node before its T child. That child's `id` is `args.back_id or nil`, which is nil here.
- Protected normal indexing is correct: the method is inherited, `G`, `G.FUNCS` and `G.OVERLAY_MENU` are raw fields, and the transient `G.OVERLAY_MENU = true` (`button_callbacks.lua:1372`) is rejected by the `type(...) == "table"` check (`mp_driver.lua:444-466`).

**2. Calling `continue_unlock` from the update hook: no hazard found.**
- It runs after the original `Game:update` returns, so the forced `G.E_MANAGER:update(0, true)` (`button_callbacks.lua:1404`) does not re-enter the event manager.
- A real click only adds `mod_cursor_context_layer(-1)`, `G.NO_MOD_CURSOR_STACK`, a click sound and some jiggle (`engine/ui.lua:1074-1094`). The `-1000`/`-2000` resets inside the callback (`controller.lua:489-496`) make the `-1` irrelevant.
- `locks.frame` clears after 0.1 s (`controller.lua:196-210`). Nothing in AISparring reads `G.CONTROLLER.locks` or `G.SETTINGS.paused`.
- Chaining works: queued `create_unlock_overlay` events were created unpaused, so they pause-skip (`event.lua:50`) until `exit_overlay_menu` unpauses. The forced pass then opens the next popup, which is a new UIBox and correctly counts as success (`mp_driver.lua:488`).
- `G:save_settings()` is identical to what a click does and only writes to the staged role's appdata.
- The `exit_overlay_menu` wrappers are all local-only:
  - SMODS `run_select.lua:749-753` (cleanup)
  - HandyBalatro `ui/index.lua:85-90` and `regular_keybinds/hooks.lua:1-5`
  - Multiplayer `game_end.lua:519-528` (saves the username only if the overlay has a `username_input_box`)
  - Multiplayer `game_state.lua:625-632` (removes the practice Jimbo)

**3. Fairness, isolation, rules fidelity: acceptable.**
- Dismissal reads nothing into `AIObservation`, returns nothing, logs only `count`/`code`, and never logs the popup's card key.
- It sends no protocol traffic and changes no RNG: popup content is built when the popup is created, which happens with or without dismissal, and dismissal only runs the same events a click would.
- The human's in-match popups are never touched. The AI's are dismissed within about one frame, and the human spends a click on theirs, so the AI's timing edge is negligible.
- Human pre-start dismissal is acceptable because the unlock itself is already saved in the profile. However, `unlock_notify.jkr` is deleted as soon as the popups are queued (`common_events.lua:2257`), so an attended user never sees that notification again (see L2).

**4. Policy and bounds: correct as specified.**
- Role gating: `runtime_bootstrap.lua:1396-1407`.
- Rate limit, with the first attempt immediate: `:1420-1424`.
- The cap counts successes only: `:1411-1419`.
- Each refusal code is logged once: `:1431-1439`.
- Placement is after the terminal and `coord_failure` exits (`:1611-1627`).
- It never throws, since every engine touch is protected, and it never touches `update_errors`.
- All logged fields are in `Logger.ALLOWED_FIELDS` (`src/logger.lua:4-7`).
- The loop gate (`:1676`) can starve the loop, though (M1).

**5. Test quality: good fixtures, with one gap.**
- The metatable-only overlay, the chained popup and the frozen main-menu fixtures would catch a rawget-only regression, a removed loop gate, and a return of the match-9 symptom (confirmed by the orchestrator's failing-first run).
- The gap: the human half of the foreign-overlay test is vacuous (L3).

## Findings

| # | Sev | Location | Finding | Fix |
|---|---|---|---|---|
| M1 | Medium | `runtime_bootstrap.lua:1411-1419`, `:1420-1441`, `:1676` | **The AI loop can be starved forever without any error.** Once the 32-success cap is hit, or while `continue_unlock` keeps failing, `handle_unlock_overlay` returns true every tick. `loop.update` is then never called, so the loop's own timeouts (`decision_loop.lua:958`) can never fire. After coordination the pre-start deadline no longer applies, and heartbeats keep flowing (`:1711`), so the service sees a healthy AI that never acts. Failed attempts are also unbounded (one every 0.5 s forever). This deviates from the promise that "existing loop timeouts remain the only bounds". | Add `LIMITS.unlock_block_timeout` (e.g. 20 s). If `unlock_blocking` stays true continuously past it, `record_error("unlock_overlay_stuck")` and `instance.shutdown(...)`, following the existing clean-stop pattern. Also cap total attempts (e.g. `max_unlock_attempts = 64`). Add a test with a callback that always leaves the overlay (BAD_STATE) and one where the cap is hit while a popup is still up. |
| L1 | Low | `runtime_bootstrap.lua:1639-1642` | `advance_coordinator` still runs in the same tick when a chained popup is up. If `MAIN_MENU_UI` had already mounted, `host_start`/`ai_join` could fire while the game is paused under an unlock overlay. | `if auto_coordinate and not unlock_blocking then advance_coordinator(current) end`. Keep the deadline check outside the gate so a stuck pre-start popup still ends in a clean `coord_timeout`. The AI's in-match coordinator already returns early, so this does not affect matches. |
| L2 | Low | `runtime_bootstrap.lua:1397-1403` | The human's pre-start notification is acknowledged without being shown, and it will not re-appear (`common_events.lua:2257`). This is harmless unattended but a small UX loss for an attended user. | For the human role only, dismiss after the popup has been up for a grace period (e.g. ≥ 8 s, well inside the 90 s window), or document the behaviour. The AI stays immediate. |
| L3 | Low | `tests/runtime/test_runtime_bootstrap.lua:172-187` | `non_unlock_overlays_are_never_touched_for_either_role` passes `lobby_code="ABC12"`, so `support.lua:171-174` puts the run stage in and `is_started()` is true. For the human, the policy gate refuses before the identity check ever runs, so this half would pass even with a broken identity check. | Run the human case pre-start (`started=false` or no code, frozen menu) and assert `dismissed == 0`, the overlay is unchanged, and `start_lobby_calls == 0`. |
| L4 | Low | `tests/runtime/test_runtime_bootstrap.lua:138-154` (and missing cases) | Missing tests: (a) the `start_committed`-only gate (committed, run stage not yet reached), where dropping `not start_committed` would go uncaught; (b) the AI's pre-start `ai_join` being blocked by a main-menu popup, the likeliest AI case; (c) the M1 starvation behaviour. | Add all three. For (a), drive the human through `host_start_game` with `started=false` and then install the overlay. |
| L5 | Low | `runtime_bootstrap.lua:1676`, `decision_loop.lua:958` | If a request is already pending when a chain of 11 or more popups appears, the 5 s request timeout is counted on resume. This is rare, since in-match popups only show at the next `start_run`. | Accept and document, or let M1's watchdog cover it. |
| I1 | Info | `test_runtime_bootstrap.lua:89-104` | The fixture `continue_unlock` does not clear `G.SETTINGS.paused` as the spec said it should. Only `menu_detail` reads that value, so the tests are still valid. | Set `G.SETTINGS.paused=false` in the fixture for fidelity. |
| I2 | Info | `runtime_bootstrap.lua:1408`, `:1441`; `mp_driver.lua:474` | With any overlay up, there is one full `get_UIE_by_ID` tree walk per tick for allowed roles, and up to three per attempt. This is negligible. | Optionally remember the last non-matching overlay (by `rawequal`) and skip re-walking it. |
| I3 | Info | Scope | Other overlays that would block an unattended role are not handled: Multiplayer's `dev_warning` and `version_mismatch_warning`, and `G.OVERLAY_TUTORIAL` on fresh profiles. The `overlay_opened` fingerprint would name them if they appear. | Keep the scope narrow. Consider having launcher-owned AI profiles pre-acknowledge unlocks, which also avoids Multiplayer's not-fully-unlocked warning. |

I did not run any tests myself. Pass/fail claims come from `work/unlock-overlay-verify.txt` and the implementer note. Everything above comes from reading the code and the staged source.