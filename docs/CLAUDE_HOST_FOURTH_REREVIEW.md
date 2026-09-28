# Host/service focused re-review (`47e1f64`)

**Verdict: not accepted. There is one new High defect, and this diff introduced it.** N-1-R is resolved and so is the stop race. The public recovery path for H-A-1-R works for both scenarios you asked me to trace. But the new pending-closure bookkeeping creates a pending state that can never be resolved on the real live-byte-diff path. The fix is one branch plus one test.

This review was read-only. I read `AGENTS.md`, the third review, `work/review-host-public-recovery.diff`, `tools/practice_host.py` and the changed tests. I also read the `isolation_certificate.py` closure/failure functions and the `launch_practice.py` `OwnedProcess`/`LaunchSession` code for compatibility only. I ran nothing; the 84/84 and PASS figures are Astra's reported results.

## Dispositions

**H-A-1-R: public recovery path resolved; acceptance blocked by the new defect below.**
- **Initial exit refusal, then recovery:**
  - `_finalize_refused_closure` (`practice_host.py:2589-2594`), `_void` (`:2625-2630`) and `_shutdown_after_spawn` (`:2909-2916`) set `_pending_closure` and keep `self.session`. `_retire_session` only sets `session = None` after close succeeded and exit was proven (`:2546-2557`).
  - While the handle is still stuck, acknowledge is refused in two ways: by `human_active` (`:3365`), or by the open record (`:3368-3370`). The record stays open because no failure closure is written.
  - Once the handle exits, `retry_pending_closure` (`:2671-2685`) retires the session, runs the real `record_session_failure`, and only then clears the pending state and rewrites the report. Acknowledge then clears both lockouts.
  - No private helper calls or hand edits are needed; `test_daemon_acknowledge_retries_pending_closure_and_recovers` drives this end to end.
- **Persistence raises once:** the pending state and `_record_started` survive (`:2597-2599`). The next acknowledge or start persists the closure for real. `_record_started` is cleared only after the certificate returns ok (`:2654-2657`), and `_pending_closure` only after that (`:2680`).
- **Non-forced `stop()`:** it retries first and refuses with `practice_host_closure_pending` before `cleanup()` (`:3236-3237`).
- **Only finished threads are retried** (`:3202-3204`). During the gap before `thread.start()`, a retry can reach the newly created supervisor. That is harmless, because it has no pending closure (`_pending_closure is None`).
- **Start test:** it now requires acknowledge before a new start, as production does.

**N-1-R: resolved.**
- `_retire_or_cleanup` (`:1951-1967`) terminates the roles but keeps `session` when a certificate is required and the record has started. This applies both to a human who exited before teardown and to `leave_human_visible=False`.
- The real `record_session_verdict` then measures the retained handles. It checks the session id and nonce against the record at `isolation_certificate.py:2875-2878`.
- Ownership is dropped only after a passed verdict (`:2370-2383`). `_record_started` is cleared first, which is correct because the certificate has already persisted the closure.
- `test_supervisor_real_certificate_human_end_after_exit_completes` uses the real certificate (`verdict_recorder=None`), not the pass-always injector. It checks that the record is `closed` with no problems and that neither lockout remains.
- **Stuck AI:** the real verdict returns `session_closure_unproven` at `isolation_certificate.py:2930-2932` without writing anything. `_retire_session` then fails, so the handles are kept, the record stays open and no failure is stamped. I confirmed this by tracing the source. The test only calls `_finalize_refused_closure` directly (see test gaps below).

**Stop race (Low): resolved.** The re-check and `thread.start()` now run under the same lock (`:3494-3497`).

**Launcher compatibility:** `OwnedProcess.is_running` (`launch_practice.py:567-574`) now treats a failed query as still running. `_owned_exit_proven` and `_closure_problems` agree with that. `LaunchSession.close` (`:683-690`) never raises. This is a compatibility check only; I am not approving isolation scope.

## Blocking defect

### High H-A-1-R2: a live byte diff leaves a pending closure that can never resolve, so `serve` can never shut down
This is a new regression from this diff; the third review noted this path as safe only because the return value was ignored.

**Trace (real certificate):**
1. `_finalize_after_run` gets `live_byte_diff_revoked` and calls `_fail(CODE_LIVE_CHANGED)` (`:2353-2354`).
2. The certificate has already closed the record as `failed` (`isolation_certificate.py:3001`), but `_record_started` is still True.
3. `_fail` therefore calls `_shutdown_after_spawn` (`:2860-2861`). Because of N-1-R the session is now retained, so `spawned` is True and it asks for a second verdict (`:2895`).
4. That verdict returns `session_already_closed` (`isolation_certificate.py:2926-2927`), so `failure_code = "session_already_closed"` (`:2907-2908`).
5. `_retire_session` succeeds. `_record_failure_closure` then gets `open_session_missing` (`isolation_certificate.py:3033-3034`) and returns False. `_pending_closure` is set (`:2919-2920`).
6. Every later `retry_pending_closure` call repeats step 5 and returns False, forever.

**Effect:**
- Non-forced `stop()` always refuses with `practice_host_closure_pending` (`:3236-3237`). The `serve` shutdown loop spins every 2 s indefinitely (`:3808-3812`), and `__exit__` silently leaves the daemon running.
- The daemon reports a closure as pending when the record is in fact already closed as failed.
- Acknowledge still succeeds, but it never clears the pending state. Only replacing the ticket with a new start does.
- This hits every real revocation, which is the most safety-critical path.
- `test_supervisor_records_revocation_lockout_on_live_diff` misses it because its injected recorder returns the diff on both calls.

**Minimal fix** (`practice_host.py:2353-2354`):
```python
if verdict.get("code") == "live_byte_diff_revoked":
    # The certificate already persisted the record as failed (+ lockout);
    # only ownership remains to be retired.
    self._record_started = False
    return self._finalize_refused_closure(CODE_LIVE_CHANGED, live_verdict=verdict)
```
With this change, a retire failure still becomes a pending closure. A later retry then only needs to retire, and the byte-diff lockout set by `_record_live_verdict` is kept.

**Test:**
1. Use the real certificate and an open record.
2. Modify a file in the live install after `_real_open_record`, with every owned handle exited.
3. Call `_finalize_after_run()`.
4. Assert: code `CODE_LIVE_CHANGED`, `_pending_closure is None`, record status `failed`, byte-diff lockout set.
5. Then build a `HostDaemon` holding that supervisor and assert `daemon.stop()["stopped"] is True`.

## Non-blocking (Low)
- **Retry result ignored:** `_op_acknowledge` and `_op_start` ignore the retry's return value (`:3364`, `:3390`).
  - This is safe whenever the record is still open, because the open-record gate refuses.
  - The one exception is a closure passed by the certificate whose retire is still unproven (`:2372-2382`). There, start can reach `previous.supervisor.cleanup()` (`:3480-3482`) and drop the kept handles. In practice this is a very narrow race: the certificate had already verified every owned status stopped, and `close` never raises.
  - Suggested fix: `if not self._retry_pending_closure(): return {"ok": False, "code": CODE_CLOSURE_PENDING}` in both ops. Apply it only after the High fix, or acknowledge would wedge as well.
- **Concurrent retries:** the control server is a `ThreadingTCPServer` (`:3666`) and `retry_pending_closure` has no lock. Two simultaneous authenticated requests could append duplicate failure receipts. A supervisor-level lock around the retry would fix it.
- **Report after pass-path retry:** the report is rewritten as `failed`/`session_closure_unproven` even though the record closed as passed. This is conservative, not a false success.
- **Test gaps:**
  - The stuck-AI test calls `_finalize_refused_closure` directly instead of going through `_finalize_after_run` and the real verdict. The source trace above shows it is correct.
  - `leave_human_visible=False` is not tested directly, but it runs the same `_retire_or_cleanup` code.

## Host/service scope verdict
**Not accepted.** Fix H-A-1-R2 and add its real-certificate test. After that, only that branch and the stop/serve shutdown need a focused re-check. Everything else in host/service scope is acceptable, and all issues resolved in the third review remain resolved. The unchanged service results (55/55, 5/5, 6/6) still stand. Native Balatro isolation and playability remain separate gates that have not yet been passed.
