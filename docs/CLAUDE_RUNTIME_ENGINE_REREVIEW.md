# Targeted re-review of runtime, engine and policy repairs (base `bbf61bf`, repairs `03a4442` and `83bb4fd`)

## Verdict: approved for controlled staged testing

This approval covers only the runtime, engine and policy scope. The isolation and host gates are owned separately and are still blocked, and no actual game measurement or install has happened.

All the Critical and High findings, and all the Engine A/B/C items, are fixed in the real source. I checked each fix against the pinned game, Multiplayer and SMODS code under `work/reference`, not just the reports. The fixtures no longer invent engine flags: nothing in `AISparring/` or `tests/` sets `MP.is_started` or `MP.LOBBY.started`, or depends on `pvp_reached`. Three Low issues remain, none of them blocking.

**How I reviewed:** read-only. I ran no commands, made no edits, and used no agents or network. Because I couldn't run `git`, I read the two repair diffs and the current files at HEAD `4ebb775`. The relevant parts of those files match the diffs.

**Test evidence:** the counts in `work/review-repair-*.txt` match the pass totals you reported:
- runtime: 34 + 78 + 78
- menu: 14 + 36 + 36
- companion: 22 + 8 + 74 + 74
- engine: 15 + 96 + 96
- root contracts: 22
- adapter attacks: 28

**Plan mode:** this session had no file-write or plan-exit tool, so there is no plan file and the full report is here.

## Disposition

| ID | Status | What I checked against the real source |
|---|---|---|
| **Runtime C1** | Fixed | `mp_driver.lua:287-308`: the match counts as started only when the lobby has a code and the game stage is RUN, and it then stays latched. The real game sets the stage as a normal field (`game.lua:1244`), and Multiplayer sets the lobby code when the lobby is created or joined (`action_handlers.lua:85,98`). The test fixtures now drive the stage instead of a fake flag (`support.lua:138-176`). |
| **Runtime C2** | Fixed | `mp_driver.lua:540-542` reads `force_lobby_options` with normal indexing, so it works through the real metatable proxy (`_rulesets.lua:151-161`). The real `start_lobby` resets the lobby config but keeps the ruleset (`core.lua:183`) before calling the forcing function (`play_button_callbacks.lua:109-117`). A failure after the lobby has been created is now fatal and never retried (`runtime_bootstrap.lua:1152-1165`); refusals before that call can still retry. |
| **Runtime H1** | Fixed | `practice_menu.lua:36` now accepts the real `G`, which has a metatable. The colour and UI constant tables are plain fields set in `globals.lua:353,476`. |
| **Runtime H2** | Fixed | The transport now keeps an ordered list of every frame it sends and matches each reply to the oldest one (`control_transport.lua:302-351, 470-506`). This holds because the service answers exactly one line per request, in order (`practice_service.py:2000-2017`; every path in `_dispatch` returns a reply). The reservation is taken before the push and undone if the push fails (`:527-536`). Rejections with no sequence, result replies, heartbeats and cancels each land on their own entry. END is routed by its tagged operation name (`runtime_bootstrap.lua:1265-1267`). |
| **Runtime M1** | Fixed (see Low 1) | Adds a 120 s pre-start deadline (`:1476-1481`). Replies saying aborted, closed, ended or pre-start timeout, and a heartbeat with `aborted=true`, now stop coordination (`:992-1004`). Retryable failures of lobby code, READY and START re-send (`:1073-1103`). The protocol constants match the service's strings. |
| **Runtime M2** | Fixed | The companion's attestation timeout is now 120 s, longer than the host's 90 s wait. |
| **Runtime M3** | Fixed | `controller.update()` is now called with no argument, so the controller uses its own clock (`menu_controller.lua:722-724`). |
| **Runtime M4** | Fixed | A transport whose worker has errored or stopped is rebuilt instead of reused (`companion_host.lua:862-885`). |
| **Runtime M5** | Fixed | The main-menu check now also requires the MENU state, not the splash screen, plus the main-menu UI handle. The splash and menu states are set at `game.lua:1380,1528`. |
| **Engine A** | Fixed | Both the adapter and the executor now require a pack card to exist before allowing a skip, in every pack state, as the real skip rule does after the SMODS patch (`smods-booster.toml:124-126`). The test fixtures were updated to match. |
| **Engine B** | Fixed | A shared Ankh check (matching `card.lua:1581-1588`) now also runs on the pack-pick path in the adapter (`:1502`) and the executor (`:1020`). |
| **Engine C** | Fixed | The PvP wait now depends on the current blind being a PvP blind, the same test as `MP.is_pvp_boss()` (`nemesis.lua:34`), plus hands left ≤ 0, and not on `round_ended`/`end_pvp`. It no longer relies on `pvp_reached`. The reset points agree with the real Multiplayer code (`game_state.lua:232,244`, `end_round.toml:18`, `action_handlers.lua:1255`). |
| Engine Medium 1 (bonus) | Fixed | Selections that leave out a forced card are no longer offered (`engine_adapter.lua:1131-1175`). |
| **Policy NEW-1** | Fixed, and it holds against the real engine | After a reorder, the executor checks the live card order (`production_executor.lua:1520-1534`). The real `align_cards` places each card by its new index before sorting (`cardarea.lua:509-528`). Pinned jokers are the only thing that sort would move, and they are already refused (`:1101-1108`). So a valid reorder sticks and the check won't cause false failures. |
| **Policy NEW-2** | Fixed | `advance_ui` clears the stale control when nothing is pending (`:1605-1611`). `controls.next` reads the executor's latch (`runtime_bootstrap.lua:846-848`), so capture resumes. |
| **Policy NEW-3** | Partly fixed (Low 3) | The transport now keeps its pending slot when a cancel can't be sent, but the decision loop still forgets it. |

## Remaining issues (all Low, none blocking)

**Low 1: the AI treats the service's normal "ended" state as a failure.**
- **Where:** `runtime_bootstrap.lua:992-996`.
- **What goes wrong:** the "ended is fatal" check applies at every stage of the match, not just before it starts.
  - The human's END sets `ended` on the service (`practice_service.py:1630`), and the service then answers AI heartbeats with `practice_ended` (`:1328`).
  - If that reply arrives before the AI notices the game is over itself, the AI shuts down and records `practice_ended` as an error. It never sends its END receipt.
  - The service then just closes the receipt phase after its grace period (`:1188-1192`). Fairness, safety and play are unaffected.
- **Minimal fix:** only treat `ENDED` as fatal while `not (start_committed or guest_ready_committed)`. After that, let `handle_terminal`/`report_summary` send the AI's END, which the service still accepts. Aborted and closed stay fatal.

**Low 2: the new reply-matching assumes no frame is ever lost.**
- **Where:** `control_thread.lua:173-179`.
- **What goes wrong:** the worker ignores a send timeout and throws away the partial-send index. A dropped or cut-off frame means one missing reply, and every later reply would then be matched to the wrong request.
- **Related spot:** `control_transport.lua:451-460` drops an oversized or unreadable line without consuming its list entry, which shifts the matching in the same way.
- **Risk:** very unlikely on loopback, because the service reads continuously. But the H2 design now depends on it.
- **Minimal fix:** in the worker, keep re-sending from the last byte sent until the frame is complete, or treat a timeout as `closed` and stop. In the transport, consume the oldest entry for a dropped non-event line, or fail the transport.

**Low 3: the rest of NEW-3.**
- **Where:** `decision_loop.lua:459-465`.
- **What goes wrong:** `abandon_pending` clears `pending` even when `transport.cancel` returns false. The transport keeps its slot, so the next request gets `transport_busy`, which counts as an error. This only happens if the LÖVE channel push itself throws.
- **Minimal fix:** keep `pending` when the cancel fails, and retry `transport.cancel` before `do_issue`.

**Latent, no action needed:** after the candidate cap, the forced-card filter could in theory leave no PLAY candidates. That can't happen under Attrition or Major League, because Cerulean Bell never appears there.

## Waiting on real-game observation (not code defects)

- **SMODS colour/UI tables:** whether `G.C` and `G.UIT` stay plain tables once SMODS loads. I couldn't check this: only `smods-booster.toml` and `smods-loader.lua` are held locally. If they aren't plain, the menu fails closed.
- **Lobby setup:** the real create → force → `createLobby` sequence, whether the config digest matches after the JSON round trip, and the AI's ready button element.
- **Match start:** when the guest actually latches the RUN stage.
- **PvP wait:** the no-hands wait during a real human PvP turn.
- **Booster packs:** the timing gap while a pack opens.
- **Reorders:** that a reorder really sticks on a live joker area.
- **Minimized AI:** that it keeps updating.
- **Service timeout:** the service drops the connection after 10 s without a line. That matters if the game's main loop stalls, for example while a window is being dragged.
