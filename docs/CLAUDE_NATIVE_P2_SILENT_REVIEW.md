# Claude review — native P2_SILENT post-cycle receive-error classification

Reviewer: Claude Code 2.1.283, `claude-opus-5-5`, effort high, read-only tools. Brief: `work/claude-native-p2-silent-review.txt`. Date: 2026-09-28.

**Verdict: READY TO RERUN NATIVE P2_SILENT**

I found no Critical, High or Medium issues. The analysis of what went wrong matches the pinned source, and the narrower rule is still at least as strict as the reviewed SILENT definition. Three Low items don't block the rerun. This was a read-only review: I didn't run any tests, and the results I cite come from the fix note.

## 1. Root cause checked against the pinned source

The analysis is correct, with one small correction: the post-cycle error is likely but not guaranteed.

- **How the packet reader works:** the packet coroutine checks `hasGivenUp` only at the top of its outer loop (`socket.lua:262`). While the server is silent, each `receive()` returns `timeout`, and the coroutine pauses inside its 25-step inner loop (`socket.lua:265-266`, `313-314`). It also pauses at `:318` and `:321`.
- **Reconnects happen while the reader is paused:** the keepalive path closes the game's own socket (`:342`), opens the cycle (`:348`) and runs `tryReconnect()` inside the main loop (`:357`). Each attempt replaces `Networking.Client` before connecting (`:115`). The coroutine can't run until `tryReconnect()` returns, so it never sees the closed socket. When all attempts fail, `end_time` is stamped (`:203-204`), then `hasGivenUp=true` (`:358`), then the loop sleeps 50 ms (`:381`). On the next tick (`:332`) the coroutine picks up where it paused and calls `receive()` on the replacement socket, whose connect just failed.
- **Why that call returns this error:** this part comes from upstream LuaSocket, not from the repo. After a failed connect LuaSocket still marks the socket as a client and keeps it open, so `receive()` is allowed and Windows returns "Socket is not connected". The P2_INITIAL evidence shows the same error after its failed first connect, which supports this.
- **The refused evidence matches exactly:**
  - Attempt 3 was refused at `…300.1603`; the cycle ended at `…300.1658`; the error followed at `…300.2179`. That is +52 ms, one tick.
  - The listener saw the game's own close at `eof_time 283.088567`. That matches the fifth push + 5 s (`283.0905`) and comes just before the cycle start (`283.0886`).
  - The listener shows `sent_bytes=0`, `closed=False`, `fin=False`, `peer_reset=False` and `accepted=1`.
  - It received 115 bytes, which is exactly 5 × the 23-byte keepAlive message.
  - There were 4 connect attempts: the first plus 3 retries. The Lovely log shows reconnecting, then 3 failures, then disconnected, with no extra connect.
- **It can't be a server close or reset, or the tool touching the connection.** The error is on a socket that never connected, created after the game had already closed the original connection itself.
- **Correction:** the error isn't strictly deterministic. It appears only if the coroutine was paused mid-loop, which is about 24 of every 27 ticks. In the other states it re-checks `hasGivenUp` and makes no call. The new rule also accepts a run with no receive errors, so this doesn't affect correctness; only the "deterministic" wording is off (L1).

## 2. Does the narrower rule keep the F1–F4 SILENT proof?

Yes. The rule is stricter than the original definition, which only required no receive error other than `timeout` before expiry (`docs/CLAUDE_ISOLATION_REREVIEW.md:161`). The new rule also refuses errors during the cycle.

- **Other conditions are unchanged** (`isolation_certificate.py:1455-1469`): zero bytes sent, no close or FIN, a hold through the cycle end (`:1329-1341`), EOF only at keepalive expiry and no reset (`:1344-1369`), and exactly one exhausted keepalive cycle (`:1190-1194`). The only line that changed is `:1466`.
- **A real server close or reset before the cycle:** the reader calls `receive()` on nearly every tick while connected, so the error is recorded with its earlier time and refused (`:1391`). The observer keeps only the first time each distinct error message appears (`socket.lua:268-276`). If a later error repeats the same message, the earlier timestamp is kept, which also refuses. On top of that, the listener's own `closed`/`fin`/`peer_reset`/`eof_time` checks refuse a server close or reset on their own.
- **A close in the last ~150 ms before expiry, which the observer might miss:** the listener's fields still refuse it. SILENT's proof that the tool never touched the connection never depended on receive errors.
- **A second connection:** `accepted==1` refuses it. A successful reconnect gives a `recovered` cycle, which isn't an exhausted cycle.
- **An error that happened before the cycle but is timestamped after it:** timestamps come from one thread and one clock, and the cycle lasts about 17 s. Only a backwards clock jump of more than 14 s could do this, and the listener checks would still apply.
- **Bad timestamps:** NaN, inf, strings, `None` and non-mapping entries are all refused (`:1390-1391`). A missing `end_time` keeps the old refuse-if-any-error behaviour (`:1387-1388`).

## 3. Record-time vs copied-artifact re-derivation

They still agree. Both paths use the same derive and coverage functions: record time at `:1566-1568`, and the copy at `:1637` and `:1649` via `_p2_probe_problems` (`:1482`). The helper reads only the artifact's own fields, so staged and copied bytes give the same result.

## 4. Effect beyond SILENT

None. The P2_INITIAL (`:1401-1412`) and P2_CLOSE (`:1413-1443`) branches and `_p2_derive` are unchanged; the only other change is the new `import math`. The tool's hash will change, and the certificate records it when issued. Re-deriving the INITIAL and CLOSE receipts at that point gives the same results as before.

## Findings

| ID | Severity | file:line | Concrete scenario | Required fix |
|---|---|---|---|---|
| L1 | Low | `tools/isolation_certificate.py:1380`; `tests/test_isolation_certificate.py:1982` | The comments call the post-cycle error "deterministic". It happens only when the coroutine was paused mid-loop (about 24 of 27 states, `socket.lua:314/318/321`). A clean rerun with no receive error at all is valid, and the rule correctly accepts it. | Change "deterministic" to "expected (when the coroutine was paused mid-loop)". Documentation only; not required before the rerun. |
| L2 | Low | `tools/isolation_certificate.py:1177-1187` (feeds `:1385`, `:1338`) | The artifact writes `end_time or 0` (`socket.lua:65`). A damaged or edited artifact with an exhausted outcome but `end_time=0` would make both "error after cycle end" and "hold through cycle" trivially true. The honest Lua sets `end_time` together with the outcome (`:203-204`), so a real run can't reach this. | Optional: in `_cycle_is_bounded_exhausted`, require `end_time >= attempts[-1].time`. Not required for the rerun. |
| L3 | Low | `tests/test_isolation_certificate.py:1968-2008` | There's no test that mixes one error before the cycle end and one after, which is the dedup/second-message case. It is correct by inspection: the first bad entry refuses (`:1391-1392`). The copy-agreement test also compares only the pure functions, not `_validate_p2_artifact_binding`. | Optional: add a mixed-errors refusal test. |

## 5. Evidence and lockout verdict

It's sound to acknowledge the lockout and rerun P2_SILENT fresh.

- **The refusal is fully explained by this classifier defect.**
  - The artifacts I inspected show one owned AI peer (`peer_pid=8616`, `peer_is_owned_ai=True`) and a single accepted connection.
  - No bytes were sent, and there was no FIN or reset.
  - There was one exhausted keepalive cycle with correct 2/4/8 s gaps.
  - The lockout reason is only `P2_coverage_incomplete:keepalive` (`lockout.json:5-6`).
- **Two claims I couldn't check:** "zero live changes" and the independent process sampler are the orchestrator's reports. Their artifacts aren't in `work/native-p2-silent-refused/`. Record them in the lockout acknowledgment as the orchestrator's evidence.
- **Rerun fresh; don't promote the refused session.** Its receipt was refused under the tool hash in force at the time, so accepting it after the fact would change a recorded refusal.
- **Keep the P1A/P1B/FULL_P1/CRASH/P2_INITIAL/P2_CLOSE receipts.** None of them depends on the changed code path. The certificate re-derives them and binds the new tool hash when it's issued.
- **Before the rerun:** per AGENTS.md, check that Balatro isn't running immediately before, take a fresh backup, and use a new session and nonce. Don't kill the user's game.

## Orchestrator resolution

- L1: applied — comments now say *expected* (when the coroutine was paused mid-loop), not deterministic.
- L2: recorded, not applied — reachable only through a tampered artifact; copied artifacts are hash-bound in receipts. Not required for the rerun.
- L3: applied — `test_p2_silent_rejects_mixed_pre_and_post_cycle_receive_errors` (both orders refused). Certificate suite 65/65.
- Item 5 orchestrator evidence: independent sampler `work/procs-p2-silent.csv` (single staged AI `Balatro.exe`, PID 8616) and independent live snapshots `work/live-snapshot-before-p2.json` / `work/live-snapshot-after-p2.json` (982 AppData + 15 install files byte-identical across all three P2 runs).
