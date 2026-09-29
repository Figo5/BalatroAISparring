# Re-review 3: unlock-overlay fixes (R1, N1, N2)

## Verdict: **READY for re-certification**

R1 and N1 are closed. I found no Critical, High or Medium issues, and the earlier closures have not regressed. What's left is comment wording, optional test tightening, and one evidence gap (E1) that should be fixed before Astra's acceptance. I did not run anything; this is from reading the current tree, including `mp_driver.lua` and `tests/runtime/support.lua`.

## Findings

| # | Sev | Location | Finding | Fix |
|---|---|---|---|---|
| E1 | Low (evidence) | `work/unlock-overlay-verify3.txt:67-72` | The recorded `test_practice_service.py` run is **56/57, exit=1**, and the file doesn't say which case failed or why. The WinError 145 explanation and the "3 of 4 runs pass" claim aren't backed by anything in the evidence. The change itself touches no Python (per git status only Lua files are modified), so an unrelated flake is plausible. It still isn't recorded. | Add the failing case name and traceback plus one full 57/57 run to the evidence before Astra accepts. |
| N5 | Info | `runtime_bootstrap.lua:100-102`; `test_runtime_bootstrap.lua:415-416` | Two comments are out of date. The LIMITS comment says the clock "only starts once a dismissal was actually permitted", but it now starts on every allowed, non-graced tick with an overlay up. The attempt-cap test says "the continuous-block bound never starts", but it now starts and resets on every episode. | Reword both. No code change. |
| N6 | Info | `runtime_bootstrap.lua:1449-1459`, comments `:466-467`, `:1444-1448` | `human_grace_done` is only set when a grace runs out without the human acting. If the human clicks each popup before 8 s, each new popup gets a fresh grace. So "only the first pre-start popup is graced" is really "graces continue until one runs out". This isn't a defect: the pace is the human's, the stuck clock is cleared on graced ticks (`:1456`), and the deadline at `:1730-1734` still applies. Also, `:1456` can no longer clear a running clock for the human, because the clock can only start once `human_grace_done` is true (`:1465`). It is defence in depth. | Reword the comments, or set the flag the first time a popup is seen if strictly one grace is wanted. Keep `:1456`. |
| N7 | Info | `test_runtime_bootstrap.lua:446-505` | The two R1 tests check one tick just after the cap tick and one tick past 20 s. They don't check "still alive at 19 s after the cap tick", and they don't assert that no `decide_begin` is sent while in the match. Both behaviours use the same code as tests that already cover them (`:1468` via `:357-359`, `:1759` via `:186-202`), so this is optional. | Optional: add the 19 s check and an empty `decide_begin` check. |
| N3, N4 | Info | as before | Unchanged from the last review and still cosmetic. | As before. |

## R1: closed

**The AI can't be gated forever.** The AI is never graced (`:1426`, `:1449`). The clock is only cleared on paths that return `false`: `:1436`, `:1441` and `:1515`. Every path that returns `true` (attempt cap `:1480`, success cap `:1489`, rate limit `:1493`, still blocking `:1517`) goes through `:1465-1471` first. So any unbroken run of `true` ticks has a clock that starts on its first tick and is never reset during the run, and it stops within `unlock_block_timeout` plus one tick. The `(blocking, stopped)` result is still used correctly at `:1711-1717` and `:1759`.

**Healthy AI chains are unaffected.** For the AI, the first overlay tick is also its first attempt tick, give or take one 0.5 s rate-limit interval. 32 dismissals at 0.5 s take 15.5 s, which is under 20 s. Only a chain that runs past the success cap ends in the stuck stop, which is intended.

**Theoretical leftover (acceptable):** once a cap is reached, an overlay that disappears by itself for exactly one tick every 20 s or less would keep the loop running at a very low rate without stopping. That isn't "forever", because the loop runs on the gap ticks, and unlock popups don't dismiss themselves. No fix needed.

## N1: closed

- Only the grace-expiry path sets `human_grace_done` (`:1459`). On that same tick the handler falls through to an attempt, and the first attempt is immediate because `last_unlock_attempt_at == nil` (`:1491`).
- Later popups in the chain are dismissed at the AI's pace.
- Graced ticks clear the clock (`:1456`), so grace time never counts toward the stuck bound.
- **Bounds against the service's 90 s window (unattended human):**
  - Continuous chain: at most 8 s of grace plus one tick, then at most 20 s continuous, so about 29 s at worst. A 32-popup chain fits inside the 20 s (15.5 s).
  - Chains with one-tick gaps: the clock resets on each gap, but the coordinator also advances on those gap ticks. The 32-success and 64-attempt caps keep total gated time well under 90 s.
  - Anything pathological (for example a popup replaced every tick, as in L1) still ends in the clean `boot_coord_timeout`. Note that this runtime deadline is `prestart_timeout = 120` (`:112`); it sits deliberately above the service's 90 s, and that design is unchanged.
- A human after the start is never gated (`:1433-1437`).

## The new tests are faithful and discriminating

**`in_match_ai_after_the_attempt_cap_still_ends_in_a_stuck_stop` (`:446-479`).**
- It discriminates. In the old handler the cap tick came right after a clear tick (`:464-465` then `:471-472`), so the clock stayed nil and the result was "active".
- The final assertion is on `unlock_overlay_stuck`, and that stop comes from the handler, which runs before the deadline check. So the result can't be hidden by the coord timeout.
- **Moving the AI into the match is a fair model, not just a workaround.** The AI branch doesn't depend on the match phase (`:1426`), and the caps and counters are never reset (`:457-468`). A cap reached before the match that carries into it is a real production path.
- `set_match_code` plus `set_run` flips the driver's real start signal (`mp_driver.lua:316-336`: lobby code set and `STAGE == RUN`), so `match_running` becomes true exactly as it would in production.

**`in_match_ai_after_the_success_cap_and_a_clear_still_ends_in_a_stuck_stop` (`:481-505`).**
- It starts in the match, reaches 32 successes at about 16 s (under the bound), clears for one tick, then shows a new popup at the cap.
- The old handler left the clock nil here, so it returned "active". It discriminates.

**`human_prestart_unlock_chain_is_dismissed_without_a_stuck_stop` (`:510-526`).**
- Six popups arrive with synchronous remounts. Grace ends around step 8, then one dismissal per 1 s step.
- The old handler dismissed only about 3 in 30 steps (A about 8, B about 16, C about 24), which matches the reported 3 of 6.
- The `dismissed == 6`, overlay-nil and `start_lobby_calls == 1` assertions discriminate. The "not stopped" assertion no longer discriminates, as explained under N6, but it is harmless.

## Closure status

| Item | Status |
|---|---|
| **M1** | **Closed.** Continuous-block stop `:1465-1471`, before both caps and the rate limit, so no path returning `true` for the AI is unbounded. |
| **R1** | **Closed.** See the argument above; tests `:446-505`. |
| **N1** | **Closed.** One grace per unattended chain (`:1449-1459`), clock cleared while graced; test `:510-526`. Wording caveat in N6. |
| **N2** | **Closed.** Comment at `:530-533` now says defence in depth. |
| **L1** | **Closed, no regression.** Coordinator gate at `:1723`, deadline outside the gate at `:1730-1735`, test `:318-346` still valid (a popup replaced every tick never finishes a grace). |
| **L2** | **Closed, no regression.** Grace keyed by identity (`:1450-1453`; `unlock_overlay` returns the per-popup element, `mp_driver.lua:444-466`); replacing the popup before the first grace ends still restarts it (test `:275-304`). |
| **L3** | **Closed.** Identity refusal happens in the driver, `mp_driver.lua:459-464`; N3 is cosmetic. |
| **L4** | **Closed.** (a) `:1433` plus test `:528ff`; (c) now includes the post-cap stuck cases. |
| **I1** | **Closed, no regression.** Fixture unpauses on continue (`test_runtime_bootstrap.lua:112-114`). |

L5, I2 and I3 remain accepted as documented. For re-certification, fix E1; the rest is optional.