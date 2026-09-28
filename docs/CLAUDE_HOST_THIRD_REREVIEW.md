# Host/service final-paths re-review (10245ea)

**Verdict: blocked. Two High defects remain.** Both are on the exact H-A-1 and N-1 requirements, not new scope. Everything else in host/service scope is acceptable.

I read `AGENTS.md`, `docs/CLAUDE_HOST_SECOND_REREVIEW.md`, `work/review-host-final-paths.diff`, the current `tools/practice_host.py`, `tools/practice_service.py`, the `isolation_certificate.py` and `launch_practice.py` APIs the host calls, the touched tests, `tests/astra_service_lifecycle.py` and the root result files. This was read-only: no shell, edits, agents, network or game. I did not re-run anything. The captured results show 77/77 host, 55/55 service and 5/5 independent contracts, with no FAIL lines.

## Your question: does anything in production retry a refused closure after the process finally exits?

**No.** Once `_retire_session()` returns False, no public daemon path ever retries the closure. A delayed safe exit therefore leaves the record permanently open, and only a hand edit can clear it.

Tracing every entry point:
- **`_run_ticket`** (`practice_host.py:3427-3432`) runs `supervisor.run()` once and stores the result. There is no retry loop.
- **`_op_acknowledge`** (`:3252-3271`) refuses `human_active` while the human runs. After the human exits, the still-open record hits `CODE_OPEN_RECORD_BLOCKED` at `:3258-3260`. It never calls back into the supervisor.
- **`_op_start`** refuses on the open record at `:3307-3310`. That is before it would clean up the previous supervisor (`:3360-3369`), and `cleanup()` records no closure anyway.
- **`_op_poll`, `_op_status` and `_op_available`** only read state.
- **`stop()`** (`:3126-3142`, and the `serve` shutdown loop at `:3689-3696`) calls `cleanup()` (`:1902-1916`) once the human is gone. That drops the only handles that could prove exit, without recording anything. After a daemon restart the record can never be closed.

The same wedge happens when `_record_failure_closure()` returns False (a persistence exception or refusal). All three callers ignore that return value (`:2557`, `:2590`, `:2844`).

`tests/astra_host_failed_close.py` and `test_supervisor_eventual_exit_closes_record_and_recovers` prove that the helper is safe and works when called directly. The eventual-exit test only covers an exit that happens within the in-call reap window. Neither test drives recovery through the daemon.

## Remaining defects

### High H-A-1-R: a refused closure can never be retried after the owned process exits
- **Where:** `_finalize_refused_closure` (`:2550-2557`), `_void` (`:2583-2590`), `_shutdown_after_spawn` (`:2836-2844`), plus the daemon paths listed above.
- **Minimal repair:**
  1. **Remember the pending closure.** Add `self._pending_closure: Optional[str] = None` to `MatchSupervisor`. In all three branches, set it to the failure code when `_retire_session()` is False or when `_record_failure_closure()` returns False.
  2. **Add a public retry.** New method `MatchSupervisor.retry_pending_closure() -> bool`:
     - no pending closure → return True;
     - `_retire_session()` fails → return False;
     - `_record_failure_closure(code)` fails → return False;
     - otherwise clear the pending closure, set `human_retained=False`, rewrite the report through `_finalize(error_code=self.code)` and return True.
  3. **Call it from the daemon.** In `HostDaemon`, call the retry (only when `ticket.thread` is not alive) at the top of `_op_acknowledge`, before the `human_active` and open-record checks, and in `_op_start` before the open-record check.
  4. **Don't let `stop()` drop the handles.** A non-forced `stop()` should try the retry first. If a closure is still pending it should refuse (`stopped: False`, e.g. `practice_host_closure_pending`), so it never reaches `cleanup()` while the handles are still needed.
  5. **Test through the public API.** A daemon ticket whose supervisor ended with a stuck owned handle:
     - `_op_acknowledge` is refused;
     - then the handle exits;
     - `_op_acknowledge` succeeds, the record is `failed`, and both lockouts are cleared.
     
     Add a variant where `record_session_failure` raises once and then succeeds.

### High N-1-R: a genuine `human_end` fails with the real certificate whenever the human window has already exited at teardown
- **Where:** `_teardown_for_completion` (`:1936-1937`, `:1944-1945`) calls `self.cleanup()`, which sets `self.session = None`. `_finalize_after_run` then passes `session=None` to the real `record_session_verdict`. `_closure_problems` refuses that with `retained_session_required` (`isolation_certificate.py:2872-2873`). The refusal becomes `session_closure_unproven`, and `_finalize_refused_closure` runs. `_retire_session()` sees no session and returns True, so the record is stamped **failed** with a certificate lockout.
- **Effect:** the new N-1 completion branch (`:2722-2734`: human exited after `human_end`) *always* ends as a failure that needs `acknowledge` in production. So does a user who closes the results window during the AI receipt grace, and every run with `leave_human_visible=False`.
- **Second effect, same cause:** if the AI survives termination, `cleanup()` drops its handle without proving exit. A failure closure is then written while an owned process may still be running, which the requirement forbids.
- **Why the tests pass:** `test_supervisor_accepts_human_exit_after_authoritative_end` uses the default pass-always `verdict_recorder` (`tests/test_practice_host.py:1524`), so it never reaches the real certificate.
- **Minimal repair:** when `_record_started and require_certificate`, replace those two `cleanup()` calls with `self._terminate_roles()` and keep `self.session`. The certificate then measures the retained handles itself. After a passed verdict, call `_retire_session()`; if that fails, route it through the pending-closure mechanism from H-A-1-R.
- **Test:** a real-certificate version of the N-1 accept test (`certificate_api=isolation_certificate`, `verdict_recorder=None`, bound PIDs, a session with matching `session_id` and nonce, human exited before teardown) must end `ok True` with the record `closed` and no lockouts. Add a stuck-AI variant: no failure stamp and ownership retained.

### Low
- **Stop race still open** (`practice_host.py:3379-3388`). The "retired" re-check and `thread.start()` are not under one lock, so a `stop()` between them can still start an orphaned supervisor. Fix: run the re-check and `thread.start()` inside the same `with self._lock:` block.
- **Launcher/isolation scope, not a host blocker:** `OwnedProcess.is_running` (`launch_practice.py:567-571`) returns False when the handle query raises. A query failure therefore reads as "exited", which contradicts the fail-closed claim in `_owned_exit_proven`. Route this to whoever owns the launcher.

## Verified resolved (no action)
- **Pre-launch live reappearance** now goes through `_void` (`:2177-2182`). The never-spawned record is closed as failed, and a real-certificate `acknowledge` recovers it.
- **`_shutdown_after_spawn`** closes the record as failed when live is open or the verdict is refused for any non-diff reason. The byte-diff classification is kept: only `live_byte_diff_revoked` sets that lockout. The second verdict after a diff returns `session_already_closed`, the failure-closure attempt is refused, and nothing is relabelled.
- **Retained ownership:** a failed `close()`, a failed query or a still-running handle never stamps a failure closure and never drops the session (`_retire_session`, `:2495-2518`).
- **`_record_failure_closure`** clears `_record_started` only after the closure has actually been persisted (`:2593-2612`).
- **N-1 failure branch:** a human exit before `human_end` now fails with `practice_human_exited_before_end`.
- **Abort during the AI receipt wait** keeps the human's result and `human_end` (`practice_service.py:1272-1285`). The watchdog cannot trigger this after END because it checks `not state.ended`. All five `astra_service_lifecycle.py` cases are independent and sound.
- **Ticket reservation:** exceptions release the reservation (`:3389-3393`), and the retired branch releases it and cleans up.
- **Node fallback removed:** `_verified_node_path` (`:2649-2660`) only accepts the path the verifier hashed.
- **`record_session_no_spawn`** is now required (`:1191`), and both gates check the API before `_prepare_session` runs (`:1994-1996`, `:3486-3488`).
- **Role-parity digest** is checked before the user quits (`:3505-3510`).
- **Isolation API compatibility:** the host's calls to `record_session_verdict`, `record_session_failure`, `record_session_no_spawn` and `list_open_records` match the current signatures. I checked compatibility only; the separately repaired isolation scope is **not** approved.

## Host/service scope verdict
**Not accepted.** Fix H-A-1-R and N-1-R; each change is small and contained. Then send only those paths back for a focused re-review. Native Balatro isolation and playability remain separate, unfulfilled gates.
