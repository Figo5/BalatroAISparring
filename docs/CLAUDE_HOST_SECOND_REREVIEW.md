# Host/service re-review of the committed repair against 4ebb775

**Verdict: nearly ready, but not accepted yet. One High remains, and it's a small fix.** H-B, H-C and M-1 through M-7 are resolved against the real APIs. H-A is fixed for the case it was written about, where the game is closed. A record can still get stuck open with no way out when the live game is open at the moment of failure, or when the closing measurement is refused. Per AGENTS.md, the High must be resolved and re-reviewed before acceptance.

This was read-only: no shell, edits, agents, network or game. I did not re-run any tests. The result files say 69/69 host, 54/54 service, 4/4 independent service contracts and cross-service PASS on both lua51 and luajit21. I checked every change in the diff against the current `tools/practice_host.py`, `tools/practice_service.py`, `integration/runtime_bootstrap.lua`, `launch_practice.py` and the current shared `isolation_certificate.py` API. I did not treat the in-progress isolation work as approved.

## Prior dispositions

| # | Disposition | What I checked |
|---|---|---|
| **H-A** | **Partial** | The server, endpoint, parity and ruleset checks now run before `_prepare_session` (`practice_host.py:2029-2056`). `_record_started` is set the moment the record exists, before the backup-id parity check (`:2111-2118`). A failure with no spawn, while the game is closed, goes through `_shutdown_after_spawn` to `record_session_no_spawn`. That call reloads the record, refuses if PIDs are bound, re-measures and diffs (`isolation_certificate.py:2972-3044`). Only `live_byte_diff_revoked` now sets the byte-diff lockout (`:2391`, `:2423`, `:2325`). Remaining gap: H-A-1 below. |
| **H-B** | Resolved | `_void` terminates and waits for its own processes, closes the session, then calls `record_session_failure`. That records a `failed` receipt, closes the record and raises the certificate lockout (`:1672-1690`, `:2940-2969`). `failed` is not in `list_open_records`' blocking set (`:2514`), so `_op_acknowledge` can now clear both lockouts, with an append-only acknowledgement. |
| **H-C** | Resolved | `PracticeService.aborted` and `terminal_reason` are real properties read under the service lock (`practice_service.py:1051-1070`). `_abort` sets `aborted` and the reason (`:1257-1275`). The host fails on `aborted` and on any terminal reason other than `human_end` (`practice_host.py:2626-2648`). The real-service pre-start-timeout supervisor test exists and passes. |
| **M-1** | Resolved | Node is launched from the verified absolute path taken from the gate verdict (`:1048`, `:2563-2591`). The Job is mandatory before spawn, the process is created suspended, then assigned to the Job, resumed, and its creation time read from the retained handle (`:1642-1717`). The image path is re-read with a query handle and compared exactly. That PID lookup is safe because we hold the process handle, so the PID can't be reused. |
| **M-2** | Resolved | `pids != {expected_pid}` across both families (`:809`). |
| **M-3** | Resolved | `default_start_gate` checks the port, measurement API, lockout, certificate, server, endpoints and ruleset before the ticket is acknowledged (`:3337`, `:3223-3236`). `serve` refuses to start without `--match-port` (`:3529+`). |
| **M-4** | Resolved | The ticket slot is reserved in a single locked block before preflight, and every refusal releases it (`:3163-3236`). One Low remains, below. |
| **M-5** | Resolved | `LOG_HASH_DB_PATH` is set to `workspace.server_dir/data` (`:1598-1602`, `:2586`). The native check shows the DB is created per session. |
| **M-6** | Resolved | The checks run in the order you asked for, all under the lock (`practice_service.py:1541-1558`): role first, so an AI report is refused even with the same seed; then no first report after terminal or abort; then started required; then no overwrite, with an identical human repeat treated as a no-op; then in Gauntlet mode the seed must equal the catalog seed. This matches the real producer. The Lua sends STATUS{seed} exactly once, after the START ack and after `host_start_game` succeeds (`runtime_bootstrap.lua:1215-1240`). It compares against the SETUP seed itself. It ignores a refused STATUS unless the code is ENDED, ABORTED or CLOSED (`:987-1106`). The guest never reports a seed. The seed never reaches the worker. |
| **M-7** | Resolved | The single summary is written on the AI receipt (`:1745-1766`), when the grace expires (watchdog, `:1225-1251`), on `close()` while waiting for the AI (`:1159-1161`), or on abort. It includes the `ai_*` fields and `result_conflict`. The comparison is correct: both roles map results to the same labels (`human_win`/`ai_win`), role-aware (`runtime_bootstrap.lua:586-610`). |

## Remaining actionable defects

**High: H-A-1. A record can still get stuck open when the live game is open at failure time, or when closing it can't be measured.**
- **Where:**
  - `practice_host.py:2175-2177`: the pre-launch live check calls `_fail(CODE_LIVE_APPEARED)`, not `_void`.
  - `_shutdown_after_spawn` (`:2713-2718`) records nothing when `_live_closed()` fails.
  - `_finalize_after_run` (`:2322-2329`) sends any non-byte-diff refusal to `_finalize_unverified_human`. That covers `session_closure_unproven` after the 10 s wait for processes to exit runs out, and `live_verdict_failed`. That function also sets `human_retained=True` after the human window has actually exited (`:2476`).
- **Why it matters:** each of these leaves `status: open` plus `session_unmeasured`. `_op_start` and `_op_acknowledge` both refuse while a record is open (`:3139-3141`, `:3188-3191`). Nothing in the product ever retries a closure: no daemon op, and no host or launcher CLI command. So it is the same hand-edit dead end as the original H-A, reached by a trigger H-A named: "live game reappearing".
- **Likely trigger:** the user reopens Balatro while the launch or attestation (up to about 90 s) looks stuck, and some failure happens during that window.
- **Minimal repair (the reviewed H-B pattern):**
  1. `:2177`: call `self._void(CODE_LIVE_APPEARED)`.
  2. In `_shutdown_after_spawn`, if live is not closed after the processes are stopped and the record is still open, call `_record_failure_closure(CODE_LIVE_APPEARED)`.
  3. In `_finalize_after_run`, and in `_shutdown_after_spawn` when the verdict is refused for any non-diff reason, call `_record_failure_closure(verdict code)` after `session.close()`. Stop setting `human_retained` there.
  4. Add tests: a pre-launch live reappearance, and a real-certificate `session_closure_unproven`, each followed by a successful `acknowledge`.

**Medium: N-1. The human window exiting before any human END is reported as a completed session.**
- **Where:** `practice_host.py:2637-2639` returns `ok` whenever the human window has exited, without checking `terminal_reason`.
- **Effect:** a crashed or closed human runtime mid-match finishes as `completed` / `practice_host_ok`, with a `service_closed`/`unknown` summary. This isn't a service abort, but it's the same false-pass family as H-C.
- **Repair:** return `ok` only when `service.terminal_reason == "human_end"`. Otherwise `_fail("practice_human_exited_before_end")`. The measured closure still runs through `_shutdown_after_spawn`.

**Low:**
- **Abort during the AI-receipt wait mislabels the summary** (`practice_service.py:1269-1275`). An abort or void in that window writes the summary as `result="aborted"` and overwrites `terminal_reason="human_end"`, losing the human's authoritative result. This only became reachable because M-7 delayed the summary. Repair: if `human_end` is set, finalize with `terminal_result` and `"human_end"`, and record the abort code only in `last_error`.
- **Reserved tickets can leak** (`practice_host.py:3237-3256`). An exception after reservation, such as `_supervisor_factory` or workspace `mkdir` failing or `thread.start` failing, leaves an `accepted` ticket with no supervisor. Every later start then gets `ticket_active` until the daemon restarts. Also, a concurrent `stop()` can null the ticket and a thread still starts. Repair: wrap the section in `try/except BaseException: _release(); raise`. Before `thread.start()`, re-check under the lock that `self._ticket is ticket and self._server is not None`.
- **Unverified Node fallback** (`practice_host.py:2567-2572`). `_verified_node_path` still falls back to an unverified `which("node")`. Production never reaches it, but it should fail closed instead.
- **`record_session_no_spawn` is not a required API method** (`_MEASUREMENT_API_METHODS`, `:1182-1193`). If the isolation rework drops or renames it, pre-spawn closure silently degrades to a wedge. Add it so the host refuses before the record is written.
- **Parity digest checked only after the user quits.** `default_start_gate` omits the `certificate_content_hash` role-parity check, which still runs only after quit (`:2036-2038`). No record gets stranded, but the user quits for nothing.
- **Prior Lows unchanged:** server provenance, `return false` in the ruleset parser, backup label binding, `allow_reuse_address`, worker without `-I`/Job, canonicalization under the lock, lockout clear not append-only, `poll` result, and the listener probe retry.

## Confirmed sound (no action)
- The seed never reaches the policy or worker, and the AI can't author it.
- The listener proof requires both families and the exact owner.
- Only owned handles are ever terminated, and the user's game is only queried.
- The no-spawn closure is a real re-measurement, not a flag the caller sets.
- A launcher bind failure (`_abort_spawned_session`) closes the record as failed, so `acknowledge` recovers.
- The native helper and pinned-Node checks launch nothing but owned, hidden processes.

## Host/service scope verdict
**Blocked on H-A-1.** Fix it, preferably with N-1 in the same small change, since both are a few lines, then send it for a focused re-review of those paths. Everything else in host/service scope is acceptable. Native Balatro isolation, the three-phase isolation design and playability still need their own gates.
