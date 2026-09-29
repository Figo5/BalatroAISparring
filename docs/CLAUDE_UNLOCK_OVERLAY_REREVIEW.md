# Re-review: unlock-overlay fixes (M1, L1, L2, L3, L4, I1)

## Verdict: **BLOCKED**

There are no Critical or High findings. The block is on M1's closure, which was the point of this fix round:

- **M1 is only partly closed.** After either cap is reached, a new unlock overlay gates the in-match AI loop forever and never stops it. That is the original M1 symptom on a narrower path.
- **The L2 + M1 combination adds a regression.** A human with 4 or more chained pre-start unlock popups is stopped with `unlock_overlay_stuck`, even though every dismissal succeeds.

Both fixes are a few lines each. I did not run anything. Everything below comes from reading the current tree, including `tests/runtime/support.lua`.

## Findings

| # | Sev | Location | Finding | Fix |
|---|---|---|---|---|
| R1 | Medium | `runtime_bootstrap.lua:1464-1481` vs `:1488-1490` | **The M1 clock only starts on an attempt, and the cap paths never attempt.** Once `unlock_attempts >= 64` or `unlock_dismissals >= 32`, the handler returns `true` before the clock is set at `:1488`. So if the clock is nil when an overlay appears, it stays nil. That happens after any clear tick (`:1438` or `:1509`), or when a chained popup mounts one frame after the dismissal. `:1458` then never fires, `loop.update` stays gated (`:1753`) and heartbeats keep flowing (`:1788`). Before the match, the deadline (`:1724`) hides this. In a match (`coordination_done()` is true) nothing ends it. The test `unlock_attempt_cap_bounds_failed_attempts_once` (`test_runtime_bootstrap.lua:402-441`) walks straight into this state. It only checks one tick, and it is pre-start (no `lobby_code`), so the deadline would hide it anyway. | After the human-grace block, start the clock on any permitted, non-graced blocking tick: `if unlock_block_since == nil then unlock_block_since = current end`. This makes `:1488-1490` redundant. Add in-match AI tests (`lobby_code="ABC12"`): (a) hit the attempt cap, then keep an overlay up past `unlock_block_timeout`, expecting `stopped`/`unlock_overlay_stuck`; (b) hit the success cap, clear for one tick, then a new popup appears, with the same expectation. |
| N1 | Medium | `runtime_bootstrap.lua:1445-1453` with `:1488-1490`, `:1507-1510` | **The human grace counts toward a running stuck clock when popups chain.** Popup A is dismissed at t=8, which starts the clock. The chained popup B mounts in the same pass (as established in the first review), so `still_blocking` is true and the clock is not reset. B, C and D each get their own 8 s grace while the clock keeps running. At D's grace end, t=32, `32-8 > 20` stops a healthy human boot. That breaks the task's rule "grace must not count toward unlock_block_timeout" (`unlock-overlay-fixes-task.txt:9`). Even without the stop, N popups cost 8·N seconds against the 90 s service pre-start window, so about 10 or more popups would lose the start. Before L2 this cost 0.5·N seconds. | Reset the clock whenever the grace restarts for a new object: `unlock_block_since = nil` inside the `not rawequal` branch at `:1446`. Also cap the total human grace, e.g. grace only the first popup of a pre-start chain, or a cumulative budget of about 24 s, then dismiss immediately. Add a test: human pre-start, `chain=true`, 4 or more popups; expect all dismissed, not stopped, and `start_lobby` called. |
| N2 | Info | `test_runtime_bootstrap.lua:443-457`; note `:199-202` | **The L4(a) pin is not a real window.** `host_start_game` latches `started = true` synchronously (`mp_driver.lua:805`), in the same call that sets `start_committed` (`runtime_bootstrap.lua:1341-1344`). The fixture's `lobby_start_game` also sets RUN synchronously (`support.lua:140-144`). With the real driver, `start_committed` always implies `is_started()`, so `not start_committed` is currently redundant, defence-in-depth only. The test is still a valid, non-vacuous check for that clause (the isolated discriminator run proves it). The comment's "real window" rationale is wrong. | Reword the test comment and note: this is defence-in-depth against a driver whose `is_started` is not latched by `host_start_game`, not an observed engine window. No code change. |
| N3 | Info | `test_runtime_bootstrap.lua:207-218` | In the L3 human half, `start_lobby_calls == 0` cannot fail: no SETUP reply is ever sent and `MAIN_MENU_UI` is nil. The `dismissed == 0` and `rawequal` assertions are non-vacuous. A broken identity check would dismiss at the step-9 tick (first seen at t+1, 8 s grace), inside the 10 steps. | Optional: drop that assertion or label it as frozen-menu context. The margin is 2 ticks, so a 12–15 step loop would be sturdier. |
| N4 | Info | `test_runtime_bootstrap.lua:537-539`; `runtime_bootstrap.lua:471` | The allowlist test does not cover the new `unlock_attempt_cap` event or the `record_error` from the stuck path. `record_error` passes `role`, which is not in `Logger.ALLOWED_FIELDS`. That is existing behaviour for every `record_error` call and is dropped by `Logger.log` (`logger.lua:89-93`), so it is not new. The new records use only `event` and `count`, which are allowed. | Optionally add `unlock_attempt_cap` to the event filter. |

## Answers to the five questions

**1. M1: partly closed.**

What is now correct:
- A never-clearing overlay stops cleanly via `record_error` then `shutdown` (`:1458-1463`) within 20 s of the first permitted attempt. The test (`:347-367`) pins "no stop at 19 s, stop at 21 s".
- Hitting the success cap while a synchronous chain is still up stops cleanly (`:369-400`).
- Failed attempts are capped at 64 (`:1464-1472`).
- The clock resets when the policy refuses (`:1433`), when no overlay is up (`:1438`) and when a dismissal clears it (`:1508-1510`).
- The grace does not start the clock, because `:1452` returns before `:1488`.
- A human after match start is never gated: `allowed=false` returns false at `:1432-1435`.
- `shutdown` is idempotent (`:1812`). The next update returns at `:1602`, so there is no double stop.
- The `(blocking, stopped)` return is used correctly at `:1705-1711`. Single-value returns leave `stopped` nil, which is falsy.

What is still open:
- Gated forever after either cap (R1).
- A spurious stop on human chains (N1).

**2. L1: closed.**
- The coordinator is gated at `:1717`.
- The pre-start deadline sits outside the gate (`:1724-1729`).
- The test (`:317-345`) replaces the popup every tick, so the grace restarts and the stuck clock never starts. It proves both "no `start_lobby` under the popup" and "`boot_coord_timeout` still fires". It failed first.

**3. L2: closed as specified, but the interplay is wrong for chains.**
- The grace is keyed with `rawequal` on the same object (`:1446-1449`), it is 8 s, and the AI is not graced.
- The test (`:274-303`) would catch both a missing restart and a grace keyed on time only.
- A single popup costs 8 s plus at most 20 s, which is fine inside 90 s.
- Rate limiting and caps behave correctly after the grace, because the first attempt is immediate.
- Chains fail (N1).

**4. Tests: L3, L4(b), (d), (e) and I1 are sound.** L4(a) holds, with the N2 caveat. L4(c) covers the paths that were fixed, but its attempt-cap test encodes the R1 gap and does not detect it.

**5. New defects:** R1 (residual) and N1 (regression). Nothing else:
- No state leaks after a stop.
- No double shutdown.
- The update call site is correct.
- The handler never runs in terminal or stopped state (`:1602`, `:1617-1620`, `:1681-1697` all return first).
- New log fields are all allowlisted.
- No consumer enumerates `boot_*` codes, so the unprefixed `unlock_overlay_stuck` is harmless.

## Closure status

| Item | Status |
|---|---|
| **M1** | **Partly closed.** The continuous-block stop and the attempt cap work, but the paths after a cap are still unbounded in a match (R1), and the clock is not reset when the human grace restarts (N1). |
| **L1** | **Closed** |
| **L2** | **Closed as specified**, with the chain interplay defect N1 |
| **L3** | **Closed** (N3 is cosmetic) |
| **L4** | **Mostly closed.** (a), (b), (d) and (e) are done, with N2 on (a). (c) is missing the post-cap stuck cases (R1 tests). |
| **I1** | **Closed** (`test_runtime_bootstrap.lua:98`, `:112`) |

L5, I2 and I3 remain accepted as documented. For re-review after the fixes, I'd like failing-first evidence for the three new tests from R1 and N1.