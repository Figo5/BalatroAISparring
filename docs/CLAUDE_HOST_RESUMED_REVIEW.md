# Host/service review at bf80234: **blocked for controlled staged testing**

**Verdict: blocked**, for three narrow reasons. I found no defect that could touch the user's running game, leak the seed or hidden state to the policy, or open a non-loopback listener. The blockers are lifecycle defects. Two leave the certificate evidence stuck in a state that nothing in the product can clear. The third makes aborted matches report as "completed". Each one is likely to show up on the first staged runs.

This was read-only: no commands, tests, agents, network, edits or game. I did not re-run your pass counts. Fixture and synthetic-receipt results are not engine proof.

**What changed since bbf61bf:**
- `practice_service.py` is byte-identical (blob `dd91a93`).
- In `practice_host.py`, only the backup-identity helpers changed, plus `_evaluate_gates`, `_prepare_session` and `_launch_and_supervise`. Every other method is the same code shifted by 51 lines.
- I re-read the current certificate `prepare_session`, `record_session_verdict`, `record_session_failure`, `record_session_no_spawn` and `check_backup_evidence`.

## High

**H-A. A failure after `prepare_session` but before spawn leaves an open record nothing in the product can close.**
- **Where:** `practice_host.py:1932` calls `_prepare_session`, which writes the open record, fresh backup and before-snapshot. Server adaptation, staged endpoints, ruleset and the config digest are only checked afterwards (`:1938-1958`), and the new `prepared_backup_id_mismatch` check (`:2019-2021`) also runs after the record is written. `_record_started` is only set at `:1961-1965`, so `run()` → `_fail` → `cleanup()` never closes the record.
- **Second path:** once `_record_started` is true, a failure before roles spawn (service start, descriptor gap, live game reappearing, server/listener proof, launch exception) goes through `_shutdown_after_spawn` (`:2515`) to `record_session_verdict(session=None)`. The certificate refuses that with `retained_session_required` / `session_closure_unproven`, and `_record_live_verdict` (`~:2284`) then writes a host lockout labelled `live_byte_diff` for a diff that never happened.
- **Why it matters:** the host never calls `record_session_no_spawn`, and `launch_practice.abandon_prepared_session` has no CLI command. `_op_start` and `_op_acknowledge` both refuse while the record is open, so the only way out is hand-editing evidence files.
- **Likely triggers:** a Node update (node hash mismatch), a Node shim making the listener owner PID differ from the Popen PID, or incomplete IPv6 inventory.
- **Minimal repair:**
  1. Run `verify_server_adaptation`, `verify_staged_endpoints`, the ruleset digest and a `certificate_or_empty` parity check before `_prepare_session`.
  2. On any failure while the record has no bound PIDs, stop the server, confirm the game is closed, then call `record_session_no_spawn`.
  3. Treat only `code == "live_byte_diff_revoked"` as a byte diff. For any other `ok: False`, keep `session_unmeasured`.

**H-B. A void (user relaunches Balatro during practice) wedges the system permanently.**
- **Where:** `_void` (`:2340-2371`) deliberately leaves the open record open. `_op_acknowledge` (`:2932`) and `_op_start` both refuse while any open record exists.
- **Why it matters:** the "void → acknowledge" recovery that H4 asked for can't actually be completed.
- **Minimal repair:** after the owned handles are confirmed exited, `_void` calls `record_session_failure(session_id, reason=code)`. That closes the record as failed and raises the certificate lockout. The existing `acknowledge` op then calls `acknowledge_lockout`, which leaves an append-only acknowledgement. Nothing gets silently re-baselined.

**H-C. Service aborts are reported as successful completions (regression of prior H5).**
- **Where:** the host checks `getattr(self.service, "aborted", False)` (`practice_host.py:2451`), but the real `PracticeService` has no `aborted` attribute (its properties are at `practice_service.py:1021-1039`). Only the test fake has one (`tests/test_practice_host.py:198,225`).
- **Effect:** `_abort` sets `terminal_phase="closed"` (`practice_service.py:1226-1232`), so the host's `terminal` check sees a normal end. A pre-start timeout, a lost role or an error then finishes as `completed` with `practice_host_ok`. That produces false passes in exactly the controlled failure checks.
- **Minimal repair:**
  1. Add an `aborted` property to the service, read under its lock.
  2. Have the host fail unless `terminal_reason == "human_end"`.
  3. Add a supervisor test that drives the real `PracticeService` through a pre-start timeout.

## Medium

| # | Where | Concrete failure | Minimal repair |
|---|---|---|---|
| M-1 | `practice_host.py:2416`, `:1600-1646` | The server is launched as bare `node`, which Windows resolves by its own search order, not the path `verify_server_adaptation` hashed. `default_server_runner` isn't suspended before job assignment, silently continues if the job fails, allows a missing create time, and records `image_path="node"`. That is weaker retained identity than the roles get. | Launch the verified absolute Node path. Use the roles' suspended-create + mandatory job + create-time sequence. Verify the image path through a query handle. |
| M-2 | `practice_host.py:802-813` | Owner proof only requires the server PID to be *among* the owners. A foreign `[::1]:port` listener next to Node's `127.0.0.1:port` passes. | Require the owner set to be exactly `{server PID}` across both families. |
| M-3 | `practice_host.py:2953-3024` | Quit acknowledgement happens after runtime preflight only. With the CLI default `--match-port None` (`:3196`) and `require_fixed_match_port=True` (`:877`), every start is accepted, the user quits, and the session then fails. A missing certificate, server-hash drift or ruleset drift behaves the same way. | Before acknowledging, run the gates that don't need the game closed: measurement API, fixed port configured, `check_certificate`, server adaptation, endpoints, ruleset. Make `serve` refuse to start without `--match-port`. |
| M-4 | `practice_host.py:~2985-3010` | Admission is check-then-set across two separate lock blocks, with Lua rendering in between. Two concurrent `start` requests can both be admitted; the second overwrites `_ticket`, and the orphaned supervisor's retained human window is invisible to `stop()`. | Reserve the ticket slot atomically in one locked block before preflight. |
| M-5 | `practice_host.py:1595` together with server `abuse.ts:57-62,137` | Both clients connect from `127.0.0.1`, and the persistent SQLite ban database is shared in `server_root/data`. Three rate disconnects in five minutes ban `127.0.0.1` for 1–24 hours across all sessions. | Set `LOG_HASH_DB_PATH` to a per-session `workspace.server_dir`. |
| M-6 | `practice_service.py:1480-1488` | The `status` op accepts `seed` from either role at any time, last writer wins, and it's never compared with the trusted Gauntlet seed. The AI role can rewrite the seed in summaries and logs. No privacy leak: the seed never reaches the policy. | Accept it from the human role only, once, before start. In Gauntlet mode it must equal `config.gauntlet_seed`. |
| M-7 | `practice_service.py:1643-1653`, `:1663-1686` | The single summary is written at human END, before the AI receipt usually arrives, so it records `ai_end_received=false`. The AI's END counters and result are never persisted, and a human/AI result disagreement goes undetected. | Write the summary once the terminal phase reaches `closed` (receipt, grace expiry or close). Include the AI END fields and flag orientation conflicts. |

## Low
- **Server provenance** (`prepare_server.py:90-113`):
  - The build inherits `NODE_OPTIONS`.
  - The manifest doesn't record Node/npm versions, the native ABI, or a check that `node_modules` matches the lockfile.
  - The host doesn't reject unlisted files in `node_modules/` or `dist/` (`practice_host.py:944-958`).
- **Ruleset parser:** accepts `return false` (`ruleset_contract.py:43,112`), so the digest doesn't bind "fully locked" lobby options.
- **Backup freshness:** the backup runner's result isn't tied to the verified manifest (`practice_host.py:1326-1332`). Comparing the runner's label with `verify.backup_label` would close this.
- **Prior Lows still present:**
  - `allow_reuse_address=True` (`practice_host.py:3128`, `practice_service.py:2023`).
  - The worker runs without `-I` or a Job object (`practice_service.py:768`).
  - Canonicalization runs under the service lock (`:1752-1762`).
  - Clearing the host lockout leaves no append-only record.
  - `MatchTicket.poll` returns no result for the menu.
- **Listener probe flake:** if the TCP table grows between its two calls, the probe reports that family as unavailable, which fails closed (`practice_host.py:600-608`). A retry would stop the flake.

## Prior finding dispositions
- **C1:** partial. Nothing can silently re-baseline any more, but pre-spawn and void paths get stuck (H-A, H-B).
- **H1:** resolved. The frozen certificate writer is used, with the control port and match port kept separate.
- **H2:** companion side, outside this scope.
- **H3:** resolved. The server starts and its listener owner is proven before the roles spawn.
- **H4:** mostly resolved. Remaining: H-B and M-4.
- **H5:** resolved in the service, but regressed through H-C.
- **M1:** partial. Remaining: M-6, M-7, and `poll` returning no result.
- **M2:** mostly resolved. Remaining: M-2.
- **M3:** mostly resolved. Remaining: M-1 and the Low provenance items.
- **M4, M5, M6, M7, M8:** resolved. For M5, the backup id is now content-derived, bound to per-root evidence, and must equal the certificate's own id.
- **M9:** resolved, but the pre-start timeout is misreported (H-C).
- **M10:** resolved. The digest is the source-derived FNV1a-32, and the certificate path has no content-hash fallback (`:1948-1950`, `:2044-2046`). The non-certificate dev path still reuses the content digest (`:1956`), which is Low.

## Confirmed sound
- **User's game:** only query handles are used, the exit timeout never terminates it, a reappearing game voids the session, termination is limited to exact owned handles with one Job per role, the after-diff is taken only once the game is confirmed closed, and closing the daemon is deferred while the retained human window is open.
- **Worker and seed:** the worker request contains only runtime, source and the canonicalized observation. The seed goes to the human role only. Cancellation and timeouts kill only the worker's own child.
- **Discovery:** loopback only, constant-time secret comparison, written atomically.
- **Server:** the only listeners in the pinned server source are the match listener (now loopback) and the admin listener (removed). There are no outbound calls.

## Engine gates still pending (not defects)
Real Windows two-family inventory against the real Node server, the real P1A/P1B/FULL_P1/CRASH/P2 certificate, heartbeat pacing against the 60-second role timeout and 90-second pre-start timeout, and actual engine lifecycle and HUD. The P2 repair is still in progress.

Re-review after H-A, H-B and H-C are fixed. Ideally M-1 through M-5 go in the same change, since each is small.
