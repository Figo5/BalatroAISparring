# Re-review: baseline policy, action broker, decision loop

**Verdict: not accepted yet for this scope.** All four original Highs are closed in the code, as are M1–M3 and L1–L4/L6; L5 is closed in code but not wired. The re-review found **two new High findings**:

- **N1 (policy, one-line fix):** a direct regression caused by the M1 fix. The AI can now sell off all its jokers and consumables.
- **N2 (service/transport, loop-visible):** the loop's "cancel and reissue" recovery doesn't work end to end. One slow decision ends the match.

Both must be fixed before this milestone is accepted. This is a code-level review only. It is **not** runtime, integration or install approval.

I only read code (no commands, no edits, no game). Plan mode asked for a plan file and an exit step, but neither the Write nor the ExitPlanMode tool was available in this session, so the whole review is here.

## Closure table (original findings)

| ID | Status | Evidence |
|---|---|---|
| **H1** cash-out latch deadlock | **Closed** | `decision_loop.lua:830-840`: while latched, the loop now falls through to `do_issue`, which runs capture and refreshes `last_control_state()`. Tests: sticky-controls test and `test_pipeline.lua:95-128`. |
| **H2** failed advance aborts in 3 frames | **Closed (semantics); see N3** | `decision_loop.lua:815-824` routes it to `register_transient`, not `register_error`. |
| **H3** ~3s transient bound | **Closed in the loop** | `:90-97`: 120s wall clock, 0.25s backoff, 1200-streak guard. Holds on the capture path because `register_transient` sets the cooldown and the cooldown gates `do_issue` (`:871`). Runtime wiring gap: see N5. |
| **H4** policy loops in CONSUMABLE_SELECTION | **Closed for min_targets ≤ 1** | `baseline_policy.lua:689-709`: committing USE scores 50000, above SELECT_TARGETS at 200. Matches the adapter's `cert_targets` output (`engine_adapter.lua:1240-1246`). **min ≥ 2 or missing bounds:** no fabricated candidate, but the policy then picks SELL (N1). |
| **M1** reorder oscillation | **Closed** | `:755-757`: reorders score nil. **This caused N1.** |
| **M2** no-action treated as an error | **Closed, checked end to end** | Worker code is forwarded verbatim (`practice_service.py:1423, 1453-1456`), the transport maps it to the local sequence, and the loop handles it at `:583-591` with no error count. Residual: N6. |
| **M3** timeout after a scheduled submit | **Closed** | `:847-855` stops polling and timeout once a submit is scheduled; `:248-250` rejects `pacing >= timeout`. |
| **L1** committed dispatch reported as reentrant | Closed | `action_broker.lua:457-461` |
| **L2** live `ports` reference | Closed | `:231-233` snapshots the port functions. Nit: `check_ports` reads through the metatable but the snapshot uses `rawget`. |
| **L3** revoke contract | Closed | `revoke` is required (`decision_loop.lua:172`); terminal stop revokes (`:441`); `revoke_all` closes the authority (`action_broker.lua:622`). |
| **L4** `exec_pending` never reached the loop | Closed; residual N4 | `action_broker.lua:73-75, 270-272` |
| **L5** logging | Code closed; **wiring open** | Rejections are logged and the pre-action epoch is no longer relabelled. The bootstrap passes no `get_revision` (`runtime_bootstrap.lua:654-669`) and the broker has no `receipt`, so production `result_epoch` is always nil. |
| **L6** dead `hands` check at blind select | Closed | `blind_score` ignores `hands`. |

## New findings

### N1 — HIGH — The policy sells whenever SELL is the only scored candidate
- **Where:** `baseline_policy.lua:743-745` (SELL = −1000, still a number) and `:755-757` (reorders nil).
- **Before the M1 fix**, reorder (10) beat sell. **Now SELL is the best non-nil candidate** whenever there is no play, discard or no-target use. Each sell completes, the next observation is the same, and the policy sells again.
- **Real adapter output that triggers it:**
  - In PLAY_HAND/PvP, SELL_* is always emitted (`engine_adapter.lua:1283-1284`), while PLAY and DISCARD depend on `hands_left > 0` / `discards_left > 0` (`:1276-1281`). The previous review identified `hands_left = 0` while waiting on a PvP opponent as a reachable state.
  - In CONSUMABLE_SELECTION, SELL is also emitted (`:1292-1293`). With `min_targets >= 2` or missing bounds, the generator drops every targeted candidate (`actions.lua:289-291, 513-517, 550-556`), so only SELL/REORDER remain. This is latent until `target_selection` is wired.
- **Tests lock it in:**
  - `test_choices.lua:217-221` expects SELL_JOKER in a PLAY_HAND frame.
  - `consumable_multi_target_frame` (`support.lua:489-494`) leaves out the SELL/REORDER certificates the adapter really emits, so "no fabricated candidate" passes only because of the fixture.
- **Action:**
  - Score SELL as nil outside SHOP. In SHOP it never wins anyway, because LEAVE_SHOP is always offered (`engine_adapter.lua:1147`).
  - Optionally score DISCARD as nil when `self.hands == 0`.
  - Flip the sell test to expect `policy_no_action`.
  - Add adapter-shaped frames with SELL_* and REORDER_* for both `hands_left = 0` and `min_targets = 2`.

### N2 — HIGH (owned by service/transport; breaks the loop's timeout contract) — An abandoned decision permanently occupies the service's decision slot
- **Chain:**
  1. The loop's `abandon_pending` (`decision_loop.lua:405-412`) calls `transport.cancel`, which only clears local state (`control_transport.lua:571-579`). There is no cancel on the wire; `cancel_decision()` exists only in Python (`practice_service.py:923`).
  2. The service refuses `decide_begin` while `_pending` is set (`:1348-1349`), and `_pending` is only cleared by a `decide_poll` for the matching sequence (`:1407-1413`).
  3. The reissued request's polls therefore get `practice_decision_unknown`, or the loop times out. Either way it's a `RESPONSE_REJECTED`/timeout error, and three of them stop the match.
- **Trigger:** the loop timeout is 10s (`runtime_bootstrap.lua:663`), and so is the service's worker timeout (`practice_service.py:797`). The loop always gives up before the service can report its own timeout, so **one slow decision ends the match**.
- **Why tests pass:** the fake transports hide this.
- **Action:**
  - Add a wire-level cancel keyed by sequence, or let `decide_begin` with a higher sequence replace a stale job.
  - Make the loop timeout larger than the service timeout plus poll latency.
  - Add a timeout-then-reissue test through the real transport and service.

### N3 — MEDIUM — A failed control advance skips the cooldown
- **Where:** the control branch (`decision_loop.lua:807-829`) runs before the cooldown check (`:871`).
- **Effect:**
  - `advance_ui` (which calls `adapter.step()`) runs every frame.
  - The operative bound is the 1200-step streak guard, not the wall clock: about 20s at 60 FPS, about 8s at 144 FPS.
  - A failed advance never falls through to capture, so a stale `cash_out` is never refreshed.
- **Why tests pass:** `test_decision_loop.lua:298-320` advances the clock by exactly the backoff each step.
- **Action:** respect `cooldown_until` before advancing, and let capture run on the next eligible step.
- **Note for the engine reviewer:** whatever `element_for` becomes (engine review C2), `advance` must wait for the real cash-out readiness signal and not fire before the round tally finishes.

### N4 — MEDIUM — Terminal executor faults are treated as transient
- **Where:** `gate()` returns `exec_stall_timeout`/`exec_revoked` permanently (`production_executor.lua:691-701`), and the broker collapses both into `broker_capture_failed`.
- **Effect:**
  - The AI sits dead for 120s before stopping.
  - If `wait_state` is later wired, the wait could last forever.
- **Why tests pass:** `test_pipeline.lua:130-149` uses a 2s stall timeout (line 53), runs for 5s with the executor already faulted, and asserts only that the broker isn't revoked. The test name, "not deadline-aborted", overclaims.
- **Action:** pass these two codes through as fatal (stop immediately), and fix the test so it asserts that behaviour.

### N5 — MEDIUM (runtime gate, bootstrap-owned) — Missing waits and logging hooks
- **Where:** the bootstrap wires no `wait_state` and no `get_revision` (`runtime_bootstrap.lua:654-669`).
- **Effect:**
  - Opponent waits that show up as unsupported engine states hit the 120s cap. A human's PvP turn can take longer than that.
  - L5 logging has no post-action revision.
- **Action:** verify the real wait-state shape in a live runtime before any playable gate.

### N6 — LOW/MEDIUM — Waiting with no action has no throttle
- **Where:** `:587-590` retries every 0.25s at a flat rate.
- **Effect:** the service spawns a new worker process for each decision (`practice_service.py:665-672`), so a long wait means about 4 process spawns per second while the human is playing. The policy is deterministic, so asking again with the same epoch is wasted work.
- **Action:** don't re-ask while the epoch is unchanged since the last `no_action`, or use exponential backoff capped at about 2s. Consider a long "no progress" status for the UI.

### Cross-references (engine review, not re-raised)
- **Engine H4a:** SELECT_BLIND is offered after readying, then refused, and the loop hits its 3-error budget.
- **Engine H4c/M3:** targeted `USE_CONSUMABLE` can never pass validation. End-to-end consumable progression is still blocked there even with this H4 fix.

## Requested checks
- **Callbacks run once:** OK.
  - Tokens are single-use and consumed before capture.
  - `pending` is cleared before submit.
  - Duplicate or late responses are dropped by sequence.
  - After a successful cash-out, the latch prevents a second advance.
- **Post-commit reentry:** OK. A dispatch that returns `true` always reports success (`action_broker.lua:461`). A reentrant `loop.update` during dispatch would only count as one `broker_busy` error; this is theoretical.
- **Capability revocation:** OK.
  - `is_revoked` is checked at the start of every update.
  - Revocation is re-checked just before dispatch (`:439`).
  - `finish` and `finish_terminal` both revoke.
- **Reorder abstention is a strength/feature gap, not a safety issue.** If basic ordering is wanted, a safe design is:
  - Pick a fixed target order computed from visible joker identities only (e.g., chips/+mult jokers first, ×mult last, ties broken by center key).
  - Choose an adjacent-swap reorder only if it strictly reduces the number of inversions against that target.
  - Termination is guaranteed and cycles are impossible.
  - Leave `REORDER_HAND` nil.
- **Fixture honesty:**
  - Policy frames omit the certificates the adapter really emits (hides N1).
  - The pipeline test has no policy in it (the action is hand-picked) and uses a fake transport with no service-slot behaviour (hides N2).
  - Clock steps equal the backoff (hides N3).
  - The pipeline test runs past the stall fault (hides N4).
  - Tests inject `get_revision`, `element_for` and `target_selection`, but production doesn't wire them.

## Must-fix before accepting this scope
1. **N1:** make SELL nil outside SHOP and update the tests.
2. **N2:** give the service/transport a working cancel, and set the loop timeout above the service timeout.

Then re-review. N3/N4 should be fixed in the same pass. N5/N6 are runtime-gate items.

The Gmail, Google Calendar and Google Drive connectors need authorizing in claude.ai connector settings before they can be used.
