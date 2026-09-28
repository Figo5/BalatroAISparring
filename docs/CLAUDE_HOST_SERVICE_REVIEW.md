# Host/service review: tools/practice_host.py and tools/practice_service.py

**Verdict: REJECT this slice as integrated.** There is 1 Critical and 5 High findings. Most of the building blocks are sound. The problems are in how the session lifecycle is sequenced and in the ports shared with the companion.

This was read-only. I didn't run any tests, so the 36/36 and 32/32 pass counts are yours, not re-checked by me. Nothing was launched or edited.

## What passes

- **Local only:** the host and service both bind `127.0.0.1`, and the service refuses any other host (`practice_service.py:806`). The server environment is an allowlist and drops `AISP_*` (`practice_host.py:1099-1131`). Neither Python process makes any outbound call.
- **Live identity:** the live game is watched through a query-only handle (`PROCESS_QUERY_LIMITED_INFORMATION`, `practice_host.py:316-318`). A timeout returns `terminated: False`. PID reuse is treated as an exit. If the process can't be enumerated, it fails closed.
- **Certificate reuse:** `check_certificate` never compares live contents and never rebases. Revocation plus lockout come from `record_session_verdict` (`isolation_certificate.py:966-1043`).
- **Before launch:** quiescence (two equal hashes) → fresh backup → closed recheck → before-snapshot → `prepare_session`, which rotates the probe files. The nonce is fresh.
- **Service wire:** one sequence counter per role, checked after auth. Polling repeats only the pending sequence. There is one outstanding decision at a time. The worker runs as a separate OS process with a `communicate` timeout and kills only its own child. The worker request contains only runtime, source and the sanitized observation, and the observation is canonicalized and round-tripped before the worker starts. The gauntlet seed goes to the human role only.

## Critical

**C1. A failed or unmeasured session never gets a live diff, and the next session silently re-baselines.**
- `_fail` (`practice_host.py:1795-1805`) cleans up and finalizes with no `_record_live_verdict` at all. That covers AI crash, server death, match timeout, service abort and listener failure after spawn.
- When the after-snapshot or the verdict call throws, the result is `ok: None` (`:1605`, `:1614`, `:1632`). The lockout is only set when `ok is False` (`:1633`).
- **Effect:** the next session takes a fresh before-snapshot that absorbs any live write the failed runtime made, and the certificate stays valid. That is exactly the rebase the proof architecture forbids (B7), and failure sessions are where an isolation break is most likely.
- **Fix:**
  - Write a persistent `session_unmeasured` lockout immediately before spawn. Only a passed `record_session_verdict` receipt clears it.
  - On every path after spawn, wait for the owned processes to exit, recheck that live is closed, snapshot, and record the verdict.
  - Any snapshot or verdict exception keeps the lockout.

## High

**H1. The attestation port mismatch means every real session fails attestation.**
- The host writes `control_port=self.match_port` (`practice_host.py:1551,1561`).
- The descriptor carries the service port (`:1694`), and the companion compares against that (`companion_host.lua:1216`, `runtime_bootstrap.lua:381`).
- The test locks the bug in: it asserts `record["control_port"] == 8788`, the match port, while `FakeService.port` is 51234 (`test_practice_host.py:948`).
- There are also two writers with different schemas. The host writes `expected_save_root`, `expected_mods_root`, `expected_companion_root` and no `match_port`. The frozen contract's writer, `isolation_certificate.write_launcher_attestation` (`:823`), writes `expected_role_save_root` and `match_port`, and re-verifies the probes before writing.
- **Fix:** delete the host writer and call the certificate writer with `control_port=service.port, port=match_port`. Make that write atomic (tmp file then `os.replace`). Add a test that feeds the real Lua `check_attestation` the file the host produced.

**H2. The companion does not read the frozen environment names (cross-boundary blocker).**
- `companion_host.lua:42-59` reads the forbidden aliases `AISP_ROLE`, `AISP_EXPECTED_SAVE_DIR`, `AISP_EXPECTED_MODS_ROOT`, `AISP_EXPECTED_MOD_ROOT` and `AISP_SEED`.
- It also requires `mod_root` (`:1077-1081`).
- The launcher emits `BALATRO_AI_ROLE` and `AISP_EXPECTED_ROLE_*`, per `launch_practice.py:70-82`.
- The staged config has no `attestation_path`, so `build_launcher` returns nil and the companion reports `STAGED_ATTESTATION_MISSING` at first load. The contract requires a bounded pending state instead.
- It fails closed, but no staged session can boot. The companion itself belongs to the other review; I'm flagging it here because it's the host's port.

**H3. The match server starts only after attestation, so the MP client may start without a server to reach.**
- The MP probe is written immediately before `MP_THREAD_START` (`staging.py:1253-1278`), so the MP network thread tries `127.0.0.1:port` right away.
- The listener only comes up after attestation, which can take up to 90 seconds (`practice_host.py:1503-1515`).
- Nothing proves the pinned client retries. If it doesn't, the human is stuck disconnected.
- **Fix:** the contract allows the server to listen first. Verify the adaptation, start the server and verify the listener, including the owning PID, all **before** spawning the roles. Keep "no match before attestation" enforced separately.

**H4. Handling of the human window leaves live state unmeasured and can kill the user's window.**
- The grace period is 120 seconds (`:118`). After it, `_finalize_unverified_human` returns failed with no diff and no lockout. A human sitting on the results screen will routinely hit this.
- Once the phase is `failed`, the daemon accepts a new `start` (`:2174`) and calls `previous.supervisor.cleanup()` (`:2178-2182`), which terminates the retained human window. `stop()` does the same (`:2045-2049`).
- `_await_human_exit` (`:1588-1601`) never checks whether the live game has reopened. `_record_live_verdict` never rechecks that live is closed before the after-snapshot. So a user relaunching Balatro gets no void, and then a false revocation.
- **Fix:**
  - Keep supervising in `awaiting_human_exit` with no short timeout, and include the live-appearance → void check.
  - Refuse `start` while any session has an unmeasured post-state (C1's lockout covers this).
  - Never terminate a retained human window from a new ticket.
  - Check that live is closed immediately before and after the after-snapshot.

**H5. Terminal/end handling is one-sided and tears everything down under the human.**
- `end` is accepted from either role, even before `started`, and with no result (`practice_service.py:1094-1095`, `:1275-1315`).
- `ended` makes the host immediately stop the server, close the service and kill the AI (`practice_host.py:1759-1760`, `:1337-1351`).
- **Effects:**
  - The human's MP client loses the server on the game-over screen.
  - The AI's end summary and result receipts are lost.
  - A pre-start `end` is reported as `completed`.
- **Fix:**
  - Require a terminal result from the human coordinator after start, then allow a bounded wait for the AI's end receipt before stopping the AI.
  - Leave the owned loopback server and the service (status/end only) running until the human exits.

## Medium

- **M1. Summary and decision-result completeness.**
  - The summary uses only counters the client sent (`:403-418`). It doesn't merge the service's own decisions, failures, terminal code or seed.
  - No summary row is written on abort, role-lost, timeout or `close()` (`:905-914`).
  - Duplicate `end` messages log multiple summaries.
  - `decision_result` can be logged repeatedly, with conflicting values, for the same sequence (`:1390-1401`).
  - `MatchTicket.poll` only returns phase and error, so the menu can't show a result.
- **M2. Listener check.**
  - It reads the IPv4 table only (`:455-503`), so `::` or IPv6 admin listeners are invisible.
  - `dwOwningPid` isn't compared against the owned server's PID.
  - `port_is_free` sets `SO_REUSEADDR` (`:580`). On Windows that bind can succeed on a port that's already in use, so a foreign listener could be accepted.
- **M3. The server runtime isn't fully bound.**
  - `node` is resolved from PATH and not hashed (`:288`).
  - Only two dependency `package.json` files are hashed (`:676-686`). The native better-sqlite3 binary and transitive dependencies are unverified.
  - The host never checks that `dist/main.js` is in `built_files`, or that the built JS carries the loopback bind.
  - `prepare_server.py:43,46` ignores untracked files but copies `src/` wholesale.
  - The certificate only checks that `server_bind` is present (`isolation_certificate.py:614`); it's never compared with the current adaptation manifest.
- **M4.** `closed_check=lambda: True` (`practice_host.py:1434`) defeats the certificate API's own live-closed check. Pass the real enumerator check.
- **M5. `backup_id` is always null.** The label is `None` (`:887-900`), and `create_live_backup` never returns the label it generates. B8 requires a backup ID in the session record.
- **M6. Session ID comes from the menu.**
  - `TOKEN_RE` allows `:` and up to 128 characters. The certificate regex is `[A-Za-z0-9._-]{1,80}`.
  - Windows reserved names and trailing dots aren't rejected.
  - Reusing an ID silently reuses the workspace (`:1076-1082`).
  - **Fix:** have the host mint the session ID.
- **M7. The descriptor-environment gap check fails open.** `CODE_DESCRIPTOR_ENV_GAP` is defined (`:157`) but never used; `_build_descriptors` only records the gap (`:1704`). Refuse to launch when the gap is non-empty.
- **M8. The service has no attestation gate.** `hello`, `setup` and `start` are accepted before the host confirms attestation. Add something like `mark_attested()` so this is enforced at the trusted boundary too.
- **M9. No pre-start deadline.** Only the 2-hour `match_timeout` applies before `started`.
- **M10. Major League rules aren't checked against anything trusted.** `ready.config_digest` is only compared between the two roles (`:1200`), never against a Major League config digest pinned by the host.

## Low

- `allow_reuse_address=True` on both control servers. Use `SO_EXCLUSIVEADDRUSE` on Windows.
- The worker inherits the full environment, runs without a Job object and isn't started with `-I`.
- Canonicalization runs while holding the service-wide lock.
- `acknowledge` works while a ticket is active and leaves no append-only record.
- Attestation rotation silently skips an unsafe path (`:970-972`).

## Still unresolved, even after fixes

1. Real behaviour of the pinned MP client when its first connection fails (only relevant if H3 isn't adopted).
2. Heartbeat cadence against the 10-second service socket idle timeout and the 60-second watchdog, under normal pacing and idle shop/menu time.
3. The real Windows TCP-table probe against a real Node server, and the real PowerShell process enumerator.
4. No certificate exists yet: no P1a, P1b, full P1, crash or P2 evidence.
5. The companion env/attestation-path fix (H2) and a re-review.
6. The integrated engine and actual gate evidence.

Full acceptance stays withheld until C1 and H1–H5 are fixed, re-reviewed, and integrated with the engine and actual gates.
