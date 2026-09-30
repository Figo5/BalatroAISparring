I finished reading the worker, the launcher handler and the H1, L1 and L3 paths, and I'm writing up the verdict now.

# Re-review: overlay args, round 3 (`work/review-overlay-args-3.diff` vs `d2c5523`)

**Verdict: READY to reinstall.**

H1 is fixed end to end against the real worker and launcher. L1 and L3 are also fixed, and M1, M2 and F3–F7 have not regressed. I found no path that would stop a first live start or that could crash or quit the game mid-run.

There is one new Low finding (L4, below). It only happens if the launcher takes longer than 120 s to answer, and it doesn't block the reinstall. Separately, the evidence file doesn't show the "83/83" count claimed for `run_companion`.

I didn't edit or run anything, spawned no agents, and didn't touch the network or the game.

## Findings

| # | Sev | Location | Issue | Fix |
|---|---|---|---|---|
| L4 | Low (existing code, now the main retry blocker) | `menu_controller.lua:767-769, 383-386`; `companion_host.lua:1012-1013` | When the 120 s ack timeout fires, the menu clears its own `pending_request`, but the host's `pending` is only cleared inside `poll_start`, which never runs again. Every later Start in that game session gets `BUSY` back from the host, and the menu shows the generic error screen (`fail(HOST_ERROR)`, `:718-719`). The old connection also stays open. It is safe (closable screen, no quit), but retrying needs a game restart. It is reachable if a cold-cache start takes over 120 s (see I3). | Add `host.abandon(id)`, which clears `pending` and calls `drop_transport()`. Call it from `fail()` when a request is pending. Combine it with the L2 `cancel` op later. |
| I4 | Info | `companion_host.lua:704-707` | The LÖVE `Thread` handle is discarded right after `start`. The engine and Multiplayer both keep theirs: `game.lua:83,110,118` in the dump and `Multiplayer/core.lua:342`. With a new thread per start, the handle is now more often unreferenced while the worker is still starting. | Store it in the transport (`transport._thread = thread`) for the transport's lifetime. |
| I5 | Info | `companion_host.lua:1026-1068` | `request_start` builds the transport (so it connects) before the identity and encode steps. If one of those fails, a worker connects and sends nothing. The launcher drops it after 10 s idle, and the next start drops it again. Nothing is replayed, but the connection was wasted. | Build the transport just before `built.send`. |
| I6 | Info | `core.lua:556-561` | After the L3 uninstall, the `detail` object still says `code = "companion_ok"`, and `companion_label` reports `companion_live_menu`. The diagnostics wrongly say the menu is installed. | Set `detail.code = "companion_update_unavailable"` in that branch. |
| I7 | Info | `work/overlay-args-verify3.txt:6-10` | The evidence shows `run_companion` as "113 unique / 196 executions, PASS". It doesn't show the "83/83 on lua51 and luajit21" you quoted. All 14 suites do show `exit=0`. | Re-record, or correct the claim. |
| I8 | Info | `tests/companion/test_live.lua:627-670` | The no-replay test fakes `control_thread.start`, so it skips the real channel-name check (`control_thread.lua:244`, token pattern, at most 64 chars). I checked by hand: the live marker has no nonce, so names are `aisp_host_p<pid>_<n>_tw`, about 25 chars, which passes. There is also no test for the L1 path where `host.quit` returns `false`. | Optionally run the test through the real `ControlThread.start` with a fake `newThread`, and add the L1 case. |

## Closure status

| Item | Status | Evidence |
|---|---|---|
| **H1(a) channels** | **Closed** | Each transport gets `aisp_host_<nonce\|p<pid>>_<serial>_{tw,fw}` (`companion_host.lua:691-694`), and both channels are cleared before the worker starts (`:700-703`). The stop frame from `transport.close` goes to that transport's own captured `to_worker` (`:762-763`). An old worker's leftover queue can no longer reach a new worker, so nothing is replayed. |
| **H1(b) connect timing** | **Closed** | `available()` only reads the marker (`:992-1001`), so the Play menu and settings screens open no socket. `request_start` calls `drop_transport()` and `ensure_transport`, then `built.send` in the same call (`:1026-1068`). The worker connects on its own thread (`control_thread.lua:121-133`), so the main thread never blocks. It pops the request right after `ready` (`:155-174`), so the launcher's `readline` (`practice_host.py:3685-3690`) gets the line within milliseconds. While `_op_start` runs for about 45 s (`:3424-3560`), the launcher isn't reading, so its 10 s timeout doesn't apply. The ack is written at `:3703`, and its 10 s idle close afterwards doesn't matter because the menu has already released the connection. `ThreadingTCPServer` (`:3710`) means an earlier connection can't delay a later one. |
| **H1(c) answers and stopped worker** | **Closed** | `poll` returns the ack before it handles any later `closed`/`stopped` event (`companion_host.lua:729-735`), so an ack followed by a close is never mistaken for an error. If there's no response, `last_error` covers `error`/`closed`, and `worker_stopped()` is now treated as an error too (`:1100-1105`). If connecting fails, the worker sends `error` and returns (`control_thread.lua:125-131`), which also surfaces as an error. Every final answer (ok, rejected, error, or a non-table response) calls `drop_transport` (`:1109, 1115`). |
| **H1 old workers terminate** | **Closed** | After an answer, the worker reads `stop` within about 0.1 s (`control_thread.lua:166-168`, `185-201`) and closes its socket (`:205-208`). A worker the launcher already closed has already exited (`:197-199`). A worker still connecting times out after at most 5 s (`:122`). |
| **H1 leak bound** | **Closed** | Each start leaves at most two named channels, holding a `stop` frame plus a `stopped` event (and on connect failure, the unsent request), plus one finished thread. It's a few hundred bytes per player click, with no leak per frame. |
| **L1** | **Closed** | `quit_once` now needs `pcall` to succeed **and** `host.quit` to return `true` (`menu_controller.lua:744-751`). `host.quit` returns `false` if the quit function is missing or throws (`companion_host.lua:1130-1135`). `default_quit` returns `true` only after `love.event.quit()` (`:464-467`). If the quit fails, the closable error screen replaces the modal waiting screen. |
| **L3** | **Closed** | `boot_live` always returns `role = "live"` (`core.lua:351-353`), and a nil handle uninstalls the live menu (`:556-561`). `instance.uninstall` closes the menu's own screen and the host (`companion_host.lua:1275-1281`). The labelling issue is I6. |
| **I2** | **Closed** | The waiting text now says "up to two minutes" (`practice_menu.lua:362`). |
| **L2, I1, I3** | **Deferred** (documented) | Unchanged. L4 is the part of L2 that affects the menu. |
| **M1** | **No regression** | The waiting screen is still modal (`menu_controller.lua:729-733`). The ack re-check is still in place (`:791-797`). `available()` returning `true` without a connection doesn't weaken `start_preconditions`. |
| **M2** | **No regression** | `ACK_TIMEOUT = 120` is unchanged. Connecting per start adds only milliseconds of loopback connect time. |
| **F3–F7** | **No regression** | `build_ui` and the overlay, `show`/`own_overlay`, uninstall ordering and the quit-without-exit path are all untouched by this delta (`companion_host.lua:1166-1212`, `menu_controller.lua:340-357, 577-593`). |

## First live start and crash/quit risk

- **First start:** marker → Play button → confirm → fresh connection and send in the same frame → launcher gates (about 45 s) → ack → `start_preconditions` re-check → one quit. I found no step that fails on the real worker or launcher. The worker module is loaded as `COMPANION_LIVE_OPTIONAL[1]` (`core.lua:23-25, 329-333`). If it's missing, the start fails cleanly with a closable error screen instead of hanging.
- **Mid-run:** `update` does nothing unless it's `awaiting_ack` (`menu_controller.lua:757-759`). Building the Play menu only reads the marker file. No socket is open during a run. The only quit is behind the ack plus the main-menu re-check.