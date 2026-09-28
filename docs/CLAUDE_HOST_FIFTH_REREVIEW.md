# H-A-1-R2 focused re-review of the committed host repair (`4516e60`, parent `5e045ec`)

**Host/service verdict: accepted.** H-A-1-R2 is fixed. The two adjacent retry guards (acknowledge/start refusal, and serialized retry) are correct. I found no regression in the public recovery or completion paths accepted in the fourth review. I have one Low, non-blocking note below. I am not accepting native isolation or gameplay; both remain separate gates that have not been passed.

This review was read-only. I read `AGENTS.md`, `docs/CLAUDE_HOST_FOURTH_REREVIEW.md`, `work/review-host-revocation.diff` and the task file. In `tools/practice_host.py` I read the byte-diff branch, the refused-closure and void paths, `_shutdown_after_spawn`, `retry_pending_closure`, the daemon's `_retry_pending_closure`, `stop`, `_op_acknowledge`, `_op_start` and the `serve` loop. I also read the three new tests. For compatibility only, I read `isolation_certificate.record_session_verdict`/`record_session_failure` and `launch_practice.OwnedProcess`/`LaunchSession`. I ran nothing. The 87/87 and negative-root PASS figures are Astra's results.

## Dispositions

**H-A-1-R2 (High): resolved.**
- **Byte-diff branch** (`practice_host.py:2357-2365`): it clears `_record_started` and goes through `_finalize_refused_closure(CODE_LIVE_CHANGED, live_verdict=verdict)`. It no longer goes through `_fail`/`_shutdown_after_spawn`.
- **No duplicate verdict or failure record:** the record was already closed as `failed` at `isolation_certificate.py:3001`, with the revoked receipt and lockout written at `:2992-3000`. With `_record_started` now False:
  - `_finalize_refused_closure` skips `_record_failure_closure` (`:2607`).
  - Nothing calls `record_session_verdict` a second time.
  - `session_already_closed` / `open_session_missing` can no longer be reached, so the wedge from the fourth review is gone.
- **`CODE_LIVE_CHANGED` and lockouts are kept:** the code is set at `:2598`. The host's `live_byte_diff` lockout is still raised in `_record_live_verdict` (`:2452-2458`), and the certificate lockout comes from the certificate. The pre-spawn `session_unmeasured` flag is not cleared, because `_clear_unmeasured_lockout` runs only on a pass (`:2374`).
- **The old `_fail` path lost nothing:** `service.abort` is irrelevant here because `_stop_service()` already ran at `:2341`. Terminate, close and reap are all done by `_retire_session`. A byte-diff verdict can only happen when `require_certificate` is on (`:2424-2425`), so `_fail`'s `cleanup()` branch never applied to this case.
- **Retirement not proven:** the closure stays pending until it is safe.
  - If `_retire_session` fails, `_pending_closure = CODE_LIVE_CHANGED`, `human_retained = True`, and the handles are kept (`:2600-2605`).
  - A later `retry_pending_closure` only needs to retire. It skips persistence because `_record_started` is False (`:2693`), then clears the pending state, keeps `CODE_LIVE_CHANGED` and rewrites the report. Until then, a non-forced `stop` refuses (`:3252-3253`).
  - In practice this branch is barely reachable. The certificate has just proven every owned handle stopped (`:2880-2887`). `Popen.poll()` then returns the cached return code, and `LaunchSession.close` never raises (`launch_practice.py:567-574, 683-690`).
- **Public stop succeeds:** with nothing pending, `stop()` → `_retry_pending_closure()` returns True, `human_active()` is False because the session is None (`:1928`), and `stop` reaches `stopped: True`. The `serve` loop (`:3831-3834`) therefore ends.
- **Test** `test_supervisor_real_certificate_live_byte_diff_closes_failed_record_and_stop` uses the real certificate (`verdict_recorder=None`) and a real temp-file change. It asserts:
  - code `CODE_LIVE_CHANGED`
  - `_pending_closure is None`, `_record_started` False, session None
  - no open records, status `failed`, certificate lockout present
  - the last receipt is `revoked`, so no `failed` receipt was appended after it
  - `daemon.stop()["stopped"] is True`

  This meets the reviewed requirement.

**Retry result ignored in acknowledge/start (Low): resolved.**
- Both ops now return `CODE_CLOSURE_PENDING` when `_retry_pending_closure()` is False (`:3382-3383`, `:3411-3412`), so start can no longer reach `previous.supervisor.cleanup()` (`:3504`) while a pending closure still needs the kept handles.
- The daemon wrapper treats an exception from the retry as False, so it fails closed (`:3224-3227`).
- It still retries only finished threads (`:3218-3220`).
- Because of the High fix, acknowledge after a real revocation returns True from the retry and proceeds to the explicit lockout acknowledgement. It no longer wedges.
- **Test:** `test_daemon_refuses_acknowledge_and_start_while_retry_cannot_close` uses `_FailedCloseSession`. It shows that both ops refuse and that the session, the pending code and the open record are all unchanged.

**Concurrent retries (Low): resolved.**
- There is a `_closure_lock` per supervisor (`:1878-1881`). `retry_pending_closure` re-reads `_pending_closure` under the lock (`:2685-2689`). Pending is cleared only after persistence succeeds, so a second waiter sees None and returns True without a second `record_session_failure`.
- The unlocked fast-path read (`:2682-2684`) can only return True after the closure has already been persisted.
- **No deadlock:** the daemon's `_lock` is released before `fn()` is called (`:3214-3225`), and nothing under `_closure_lock` re-enters it.
- **Test:** `test_concurrent_pending_closure_retry_persists_once` patches a slow real `record_session_failure`. It asserts one call and exactly one `failed` receipt.

**Earlier public recovery and successful completion:** no regression found.
- The diff only adds tests. `_finalize_refused_closure`, `_void`, the pass path of `_finalize_after_run` (`:2374-2394`), `_retire_or_cleanup` and forced `stop` are all unchanged.
- Stuck-handle and one-shot-persistence recovery still complete through the same `retry_pending_closure` body, now inside the lock.
- The stuck-handle case still fails closed (retry False → refuse). Previously a later ticket could replace the ticket, which is now blocked. That is the intended stricter behaviour.

## Residual (Low, non-blocking, predates this diff)

**Same-class wedge in the `_shutdown_after_spawn` path (`:2910-2936`).**
- This path is reached from `_fail` while `_record_started` is True.
- If the verdict is `ok: True` or `live_byte_diff_revoked`, the certificate has already closed the record, but `_record_started` stays True.
- If `_retire_session` then failed, pending would become `session_closure_unproven`. Every retry would then call `record_session_failure`, which returns `open_session_missing` forever. With the new guard, that would also block acknowledge and start, leaving only a forced stop.
- This is theoretical with the real launcher, for the same reason as above: retirement cannot fail after the certificate has proven every handle stopped.
- **Optional one-line hardening:** set `self._record_started = False` in `_shutdown_after_spawn` when the verdict is `ok is True` or `live_byte_diff_revoked`, mirroring `:2382` and `:2364`. This does not block acceptance.

**Test gaps (informational):**
- The new byte-diff test does not assert that the host-side `read_host_lockout(...)` reason is `live_byte_diff`. The code at `:2452-2458` is unchanged.
- The retire-failure → retry case on the byte-diff path is not tested directly. My source trace above shows it is correct.

## Scope verdict

**Host/service: accepted for this milestone gate.** H-A-1-R2 and both adjacent Lows are resolved. Everything accepted in the fourth review stands. I found no concrete regression to reopen it, and the unchanged service results (55/55, 5/5, 6/6) still stand.

**Native Balatro isolation (including the in-progress F1–F4 measurement corrections) and gameplay/playability are separate gates and have not been passed.** This verdict does not cover them.
