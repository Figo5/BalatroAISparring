**Verdict: not accepted for this scope.** There are four unresolved High findings. Three are in `decision_loop.lua` and one is in `baseline_policy.lua`. Several of them only show up when you trace the loop against the production executor/bootstrap bindings. The fixture tests pass because their fakes hide the problem.

I couldn't diff the broker against `a991a93` because I was limited to Read/Glob/Grep, so I reviewed the whole current file against the M2 boundary doc. I only opened out-of-scope files (adapter, executor, bootstrap, reader) to confirm realistic inputs; this is not a review of them.

## High

**H1. Cash-out latch deadlocks the loop** (`decision_loop.lua` `loop.update`, control branch). Missing integration contract that becomes a real stall.
- **Failure:** in production, `controls.next` is bound to `executor.last_control_state()`. That value is only refreshed by `instance.capture()` (`production_executor.lua:1326/1333`), and the loop only reaches capture through `broker.issue`. After one successful `cash_out`, `next()` keeps returning the stale `"cash_out"`. The latch matches, `update` returns `control_pending` before `do_issue`, capture never runs again, and the loop stalls for the rest of the match. There is also no deadline on the latch.
- **Why tests pass:** the fake `Support.controls().advance` clears `name` itself.
- **Fix:** while latched, fall through to `do_issue` so capture refreshes the state (`CONTROL_REQUIRED` arrives as a transient `capture_failed`), or require a `controls.refresh()` that calls `adapter.step()`. Add a latch deadline. Add a test with a controls fake that does not clear itself.

**H2. A failed control advance aborts the match within about 3 frames** (same branch).
- **Failure:** `advance ~= true` goes to `register_error`, whose cooldown is `min_interval`, which the bootstrap sets to 0. `advance_ui` really does return `exec_element_missing` while the round-eval button is still animating in, and a gate code while the previous PLAY commit is still latched. Three consecutive frames of that trigger `finish("error")`, which revokes and stops the match at the first cash-out.
- **Fix:** treat a non-success advance as a transient wait with backoff, bounded by wall-clock time. Don't count it toward `max_consecutive_errors`.

**H3. The transient-wait bound is about 3 seconds** (`register_transient`, defaults `DEFAULT_MAX_TRANSIENT_STREAK=60`, `min_transient_backoff=0.05`).
- **Failure:** every engine state the adapter doesn't support (HAND_PLAYED scoring, DRAW_TO_HAND, NEW_ROUND, PvP waiting on the opponent) returns `engine_unsupported_state`, which becomes `broker_capture_failed`, which the loop treats as transient. 60 × 0.05s ≈ 3s, then revoke and stop. A normal scoring animation or waiting for the opponent is longer than that. The bootstrap (`runtime_bootstrap.lua:649`) uses these defaults.
- **Fix:** bound the wait by wall-clock time (e.g. `max_transient_seconds`, at least 60–120s) with a larger backoff (0.1–0.25s). Tests only cover a 5-step and a 3-step streak.

**H4. The policy loops forever in CONSUMABLE_SELECTION** (`baseline_policy.lua` `target_or_use_score`).
- **Failure:**
  - The adapter's `cert_targets` always offers `SELECT_TARGETS {target:i}` together with `USE_CONSUMABLE {target:i}` whenever `min_targets ≤ 1`.
  - The policy scores `select_targets = 200` above `consumable_targeted = 190`.
  - `SELECT_TARGETS` only highlights a card and never latches, so the next observation offers the same certificates.
  - The policy picks the same lowest-id `SELECT_TARGETS` again, every time, and never uses the consumable.
- **Why tests pass:** `consumable_frame` has no targeted `USE_CONSUMABLE` candidate, so `test_choices`/`test_lifecycle` actually lock in the looping choice.
- **Fix:** score targeted `USE_CONSUMABLE` above `SELECT_TARGETS`, or ignore `SELECT_TARGETS` whenever any `USE_CONSUMABLE` is offered. Add a frame shaped like the adapter's output and a two-step progression assertion.
- **Separate contract gap (adapter side):** when `min_targets ≥ 2`, only single-target `SELECT_TARGETS` exists, so there is no committing candidate at all.

## Medium

- **M1. Reorders oscillate** (`reorder_score`).
  - The adapter always offers the reversed order and adjacent swaps, never a no-op, so the no-op guard never fires.
  - Reorder (score 10) is picked whenever only SELL/REORDER are available: `hands_left = 0` in PLAY_HAND/PvP, or a booster with no select or skip. The result is an A → reverse(A) → A cycle.
  - Reorders don't latch, so the AI spams them, and the final joker order (which affects scoring) depends on timing.
  - `policy_reorders_when_it_is_the_only_progress_option` locks this in.
  - **Fix:** the baseline should never choose REORDER. Return nil and pair that with M2.
- **M2. A legitimate "no action" aborts the match** (`handle_response`).
  - Any `ok ~= true`, including `policy_no_action`, counts toward `max_consecutive_errors` (default 3), then revoke and stop.
  - `BASELINE_POLICY.md` §9 says `policy_no_action` is a legitimate "no legal choice".
  - **Fix:** treat that code like the empty-actions case: back off, not an error.
- **M3. Timeout keeps running after a valid response is scheduled** (`update`/`handle_response`).
  - The timeout is measured from `request_sent_at` even after a response has been accepted and scheduled. If pacing is at least the timeout minus latency, valid decisions are abandoned, and three of those abort the match.
  - This is dormant today because the bootstrap sets pacing to 0.
  - Polling also continues while a submit is scheduled, so a duplicate response with the same sequence overwrites the action and resets `submit_at`.
  - **Fix:** once `submit_at` is set, skip both the timeout and polling. Validate `pacing < timeout`.

## Low

- **L1** (`action_broker.submit_impl`): the reentry check after dispatch returns `broker_reentrant` for an action that was already committed, and the loop then counts it as `DISPATCH_FAILED`. Report the commit as successful after dispatch returns true.
- **L2** (`authorize`): the broker keeps a live reference to `ports`. The verifier approves the table identity, but `capture`/`validate`/`dispatch` can be swapped afterwards. Copy the three functions at authorize time. This only matters for trusted code.
- **L3:** `DecisionLoop.factory` doesn't require `broker.revoke`, and `finish` only calls it through `pcall`, so a missing revoke is silent. `finish_terminal` doesn't revoke at all. `revoke_all` doesn't close the authority, so `mint` still works afterwards.
- **L4:** the `transient_codes` extension point doesn't work, because the broker collapses port codes into fixed broker codes and `exec_pending` never reaches the loop. Integration contract needed: the executor must report pending only as a capture failure, or the broker must pass through an allowlisted code.
- **L5:** the log records the epoch from before the action, not the post-action revision, and rejections aren't logged. Both are in the runtime contract.
- **L6:** `blind_skip_no_hands` is dead code with the real reader (`hands` isn't exported at BLIND_SELECTION). If a producer ever exports leftover hands of 0, it would skip every non-boss blind. Remove it.

## Verified OK in this scope

- **Default factory:** still production-disabled with production-looking flags. The test asserts zero dispatch calls.
- **Production path:** dispatch requires an explicit `true`, and `false`/`nil`/throw all return `DISPATCH_FAILED`.
- **Capability:** forged or cross-instance capabilities are rejected, and it can't be serialized.
- **Revoke and tokens:** revocation is re-checked right before dispatch. Tokens are single-use and consumed immediately; replays and responses with the wrong sequence are dropped.
- **Stale handling:** stale-epoch and A→B→A cases are handled.
- **Payload:** contains only `sequence` and `observation`.
- **Policy information use:** reads only the exported fields, writes only locals, uses no `pairs`, RNG or seed, and its work per decision is bounded.
- **Shop progression:** reroll/buy/sell/leave cycles always end. Money strictly decreases per reroll apart from the limited free rerolls, SELL (−1000) never beats LEAVE_SHOP, and every purchase removes the item.

## Test assessment

The broker tests make real assertions against the real M2 modules. The weak spots are:
- The loop's "progression" test injects hand-picked actions instead of policy output.
- The controls fake clears itself, which hides H1/H2.
- Nothing tests long transient waits, `pacing > timeout`, or `policy_no_action` in the loop.
- The policy tests check one step at a time against certificate sets that don't match what the adapter actually emits, so H4 and M1 can't show up.
