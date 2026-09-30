**Verdict: READY to reinstall.** The fix correctly closes the September 29 crash. I found no other mismatch between the test fixtures and the real engine that would crash the live menu. There are 2 Medium issues on the start/quit handoff that should be fixed before the next live *match*, but neither blocks reinstalling. Nothing blocks at High or Critical.

This was a read-only review: I edited nothing, ran nothing and spawned no agents.

## 1. The fix for the crash (`companion_host.lua:1150-1160`)

It is correct and complete:

- **Call shape.** It now calls the real function with `{ definition = definition }`, which is what `button_callbacks.lua:1352-1377` expects. When no `config` is passed, the engine builds a fresh config at `:1361-1368`. So Handy's `args.config.offset.y = 0` (`:1369-1371`) has a real table to write to.
- **`rawget(G, "OVERLAY_MENU")`.** `G.OVERLAY_MENU = true` (`:1372`) is written directly on the `Game` instance, and `Object` only has `__index`. So `rawget` sees the flag, and clearing it to `nil` is right: the old overlay was already removed at `:1355`. This also covers the Esc key, which would otherwise crash on `true.config` (`engine/controller.lua:836`).
- **Re-raise.** `error(err, 0)` is caught by `show()`'s `pcall` (`menu_controller.lua:326`), and `show()` is the only caller. So the error goes nowhere unexpected.
- **Call-time lookup.** Resolving `overlay_menu` at call time honours later wrappers from other mods. The new failing-build test at `test_live.lua` proves it.
- **Paused state.** The settings screen is only reachable from Multiplayer's `play_options`, which already sets `G.SETTINGS.paused = true` (`play_button_callbacks.lua:30`). The engine's `exit_overlay_menu` clears it again (`button_callbacks.lua:1394`). This is consistent.

## 2. End-to-end audit of the live menu path

These parts are verified correct against the real sources:

| Path | Evidence |
|---|---|
| `contents_of` walk (root → outer row → column → contents row) | Matches `UI_definitions.lua:6809-6813` exactly |
| Appending into Multiplayer's play menu, which has `or nil` gaps when not connected (`play_button.lua:55-80`) | `append_node` uses the highest key (`menu_controller.lua:394-402`), and the engine builds children with `pairs` (`engine/ui.lua:275`), so the button still renders |
| AI Sparring button node | `UIBox_button` places `args.id` and `args.button` on the clickable column (`UI_definitions.lua:6898,6905`) |
| Callback element | The engine calls `G.FUNCS[button](self)` with that element (`engine/ui.lua:1081`), so `aisp_select`'s `event.config.id` is correct |
| `back_func = "aisp_close_overlay"` | Wired as the back button's `button` (`UI_definitions.lua:6786,6815`) |
| `no_back` | Honoured (`:6815`) |
| Refreshing while an overlay is open | The engine removes the old overlay first (`button_callbacks.lua:1355`), the same pattern vanilla uses |
| Quit handoff | `love.event.quit()` is identical to vanilla `G.FUNCS.quit` (`button_callbacks.lua:1702-1703`). `love.quit` only stops sound and Steam (`main.lua:1039-1043`) |
| Update loop | `install_update(Game, …)` wraps the class method. When not awaiting an ack, the controller returns immediately (`menu_controller.lua:719`) |

## Findings

| # | Severity | Location | Issue | Fix |
|---|---|---|---|---|
| 1 | **Medium** | `menu_controller.lua:749-755` (with `:697`) | When the ack arrives, the game quits without re-checking that it is still on the main menu. `confirm_start` closes the overlay before the ack (`:697`). The host runs its runtime preflight and start gate *before* acking (`tools/practice_host.py:3489-3514`), which can take a while. If the player clicks Play → Singleplayer in that window, the live game quits mid-run and loses progress since the last autosave. | On `outcome == "ok"`, re-run `start_preconditions()` and skip the quit if it fails. Also, while awaiting the ack, keep a modal "Starting practice…" overlay open that Esc can't close (needs finding 3). |
| 2 | **Medium** | `menu_controller.lua:729-731` vs `practice_host.py:3554` | An ack arriving after the 10 s timeout is ignored. The live game then shows an error while the host has already accepted and waits for the live game to exit. This leaves the two sides out of step; it can't crash the live game. | Either make `ACK_TIMEOUT` longer than the host's worst-case preflight, or send a cancel to the host on timeout. |
| 3 | Low | `practice_menu.lua:220,242,264,293`; `companion_host.lua:1152` | `no_esc = true` is passed to `create_UIBox_generic_options`, which ignores it (`UI_definitions.lua:6784-6826`). The engine only reads `no_esc` from the overlay config (`button_callbacks.lua:1367`, `controller.lua:836`), so Esc closes the confirm, diagnostic and error screens. No crash, but the screens aren't modal as intended. | Let the overlay port accept a config and pass `{ definition = d, config = { no_esc = true } }` for those screens. |
| 4 | Low | `menu_controller.lua:554-564` + `core.lua:547-552` | After 5 update errors, `on_failure` uninstalls and unregisters the `aisp_*` callbacks. If an AI Sparring overlay is still open, clicking its button calls a nil `G.FUNCS[...]` (`engine/ui.lua:1081`) and crashes the game. It's rare but a real crash path. | In `uninstall()`, exit the overlay if one of ours is open, or leave no-op stubs registered instead of removing the callbacks. |
| 5 | Low | `menu_controller.lua:577-584`, `:586-597` | `refresh_overlay` ignores `show()`'s result. If an overlay build fails, the player is left on the main menu with no overlay and `paused = true`. The cursor layer also stays shifted by one: the engine raised it at `button_callbacks.lua:1359` and the error path never undoes it. It can be recovered with Esc; no crash. | When `show()` returns false, notify the player and set `G.SETTINGS.paused = false`. |
| 6 | Low | `companion_host.lua:1167` | `exit_overlay_menu` is captured once when the UI is built, unlike `overlay_menu`, which is now looked up at call time. | Look it up at call time too, for consistency. |
| 7 | Low | `menu_controller.lua:697` → `button_callbacks.lua:1397`; `companion_host.lua:464-466` | `exit_overlay_menu` queues `G:save_settings()` on the save thread, and the quit can follow a few frames later. Only `settings.jkr` is at risk, not the profile or runs, and the window is small. | Delay `quit_once` by about 0.5 s after the ack. This combines naturally with the fix for finding 1. |
| 8 | Low (tests only) | `tests/companion/support.lua:57-59`, `:85-111` | The fake `options` builder is flat rather than using the real 4-level nesting. The fake play menu has no `or nil` gaps like Multiplayer's disconnected branch has. The fake `exit_overlay_menu` doesn't model `paused = false` or the settings save. | Mirror `UI_definitions.lua:6809-6819` and add a test for the disconnected play menu with gaps. |
| 9 | Info | `play_button.lua:2-37` | The AI Sparring button is also added to Multiplayer's "tutorial not complete" play menu. It's cosmetic, but it gives a path around the tutorial gate. | Optionally skip decorating when `not G.SETTINGS.tutorial_complete`. |

## 3. Remaining crash or save risks

After this fix, the only live-crash path I found is finding 4, and it needs 5 update errors first. The save and progress risks are finding 1 (possible mid-run quit, Medium) and finding 7 (`settings.jkr` only, Low). Nothing in the menu path writes save files directly.

I also checked the evidence file `work/overlay-args-verify.txt`: every suite shows `RESULT: PASS` / `exit=0`.