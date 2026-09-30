# Focused re-review: overlay args, round 4 (`work/review-overlay-args-4.diff` vs `d2c5523`)

**Verdict: READY to reinstall.**

L4, I4, I5 and I6 are all fixed correctly. H1, L1, L3, M1, M2 and F3–F7 have not regressed. A late ack after `abandon` can never cause a quit. I found nothing that could crash the live game, quit it mid-run, or block the first live start.

I didn't edit or run anything, spawned no agents, and didn't touch the network or the game. I couldn't re-run the suites, so I have not confirmed the claim that the new tests failed on the old code.

## Closure status

| Item | Status | Evidence |
|---|---|---|
| **L4** | **Closed** | `host.abandon` (`companion_host.lua:1089-1096`) clears `pending` only if the id matches, then calls `drop_transport()` (`:1005-1011`). `fail()` calls it before clearing `pending_request` (`menu_controller.lua:388-391`), so the ACK_TIMEOUT path (`:772-774`) now frees the host. The next `request_start` passes the `BUSY` check (`companion_host.lua:1014`) and builds a new transport. The `rawget` check and `pcall` keep the port optional and unable to throw. In the other `fail` paths the host has already cleared `pending` (`:1121, 1131, 1135`), so abandon there only drops a transport that is already `nil`. In `confirm_start`, `fail(HOST_ERROR)` at `:724` runs with `pending_request == nil`, so abandon isn't called, which is correct because the host never set `pending`. |
| **I4** | **Closed** | `transport = { _thread = thread }` (`companion_host.lua:713`). The handle now lives as long as the transport. Nothing else reads the field, and it doesn't interfere with the `rawget` method checks (`:879-895`). |
| **I5** | **Closed** | Validation, marker refresh, identity, gauntlet label and encode (`:1018-1062`) all run before `drop_transport`/`ensure_transport`/`send` (`:1066-1074`). A refusal no longer opens a connection. `pending` is still set only after a successful send (`:1077`). |
| **I6** | **Closed** | `detail.code = "companion_update_unavailable"` (`core.lua:561`), so `companion_label` now returns `companion_unavailable` (`:568-578`) and `apply_companion` reports ok=false (`:586`). This is diagnostics only; the menu itself was already uninstalled (`:560`). |
| **I7** | **Closed** | The evidence now shows `run_companion` 86/86 on both runtimes (`overlay-args-verify4.txt:6-10`), up from 83 by the 3 new tests. |
| **I8** | **Partly closed** | The L1 case now has a real test: the quit throws, then `failed` is checked, then the waiting screen is checked to have been replaced (delta lines 74-86). The no-replay test still fakes `ControlThread.start`. I checked the channel-name length by hand last round. |
| **H1** | **No regression** | Channels are still per transport with new serials (`:691-703`). Connect and send still happen together (`:1066-1071`). Ack-before-close ordering (`:731-736`) and drop-on-every-answer (`:1123, 1129`) are unchanged. |
| **L1** | **No regression** | `quit_once` still needs `pcall` to succeed and `host.quit` to return `true` (`menu_controller.lua:749-757`). `host.quit` returns `false` if the quit throws (`companion_host.lua:1144-1150`). |
| **L3 / M1 / M2 / F3–F7** | **No regression** | The waiting screen is still modal (`menu_controller.lua:734-738`). The ack re-check is intact (`:796-802`). `ACK_TIMEOUT = 120` is unchanged (`:75`). The overlay, `show`, uninstall and quit paths are untouched by this delta. |

## A late ack after abandon (the question you asked)

- **Menu side:** after `fail()`, the menu's state is `failed`, and `update` returns early for anything that isn't `awaiting_ack` (`menu_controller.lua:762-764`). It never polls again, and `quit_once` can only run from the `ok` branch (`:792-807`).
- **Host side:** `pending == nil`, so `poll_start` returns `nil` for any id (`companion_host.lua:1099-1100`).
- **Worker:** the dropped worker gets `stop`, closes its socket and exits (`control_thread.lua:166-168, 205-208`). Any ack it had already queued stays on its own `_fw` channel. A retry uses a new serial and new channel names (`companion_host.lua:691-694`), so the old ack can't reach the new request's poll.
- **Launcher:** writing to the closed socket fails silently (`practice_host.py:3701-3707`).

A late ack therefore can't quit the game. The request that abandon drops is the one already past the 120 s deadline. M2 accepted that quitting after the player has been shown the error would be worse.

## Findings

| # | Sev | Location | Issue | Fix |
|---|---|---|---|---|
| I9 | Info (existing L2 behaviour, now easier to reach) | `practice_host.py:3441-3459, 3554-3560`; `:478-521` | Suppose the launcher accepts after the menu has timed out, or the ack was already sitting in the channel when the timeout fired (`menu_controller.lua:772` runs before the poll at `:776`). The ticket then stays in `waiting_live_exit` until `live_exit_timeout`. A retry in that window gets `CODE_TICKET_ACTIVE`, which shows the closable error: safe, but a confusing message. If the player closes Balatro by hand during that window, practice starts anyway. The game is never quit by the mod. | Keep this under the deferred L2 `cancel` op. When it lands, `abandon` should also send `cancel(ticket)`. Optionally, poll once before declaring the timeout. |
| I10 | Info | `companion_host.lua:1089-1095` | `abandon` calls `drop_transport()` even when the id doesn't match the pending request. There is only one controller per host today, so a stale id can't occur. If one ever did, it would cut off a live request's connection, and that request would sit until its own timeout. It would never cause a quit. | Optionally only drop the transport when the id matches or `pending == nil`. |
| I11 | Info | `menu_controller.lua:600-609` | `instance.reset()` clears `pending_request` without calling abandon. Its only production caller is `uninstall` (`:596`), and uninstall closes the host anyway, so there's no live effect. | None needed. Keep in mind if `reset` gets new callers. |

## First live start and crash/quit risk

- **First start:** marker → Play → confirm → encode → new connection and send in the same frame → launcher gates → ack → `start_preconditions` re-check → one quit. None of the round-4 changes adds a step that can fail on the real worker or launcher.
- **Mid-run:** unchanged. `update` does nothing unless it's `awaiting_ack`. No socket is open during a run. Abandon only runs from `fail()`, which can't quit.