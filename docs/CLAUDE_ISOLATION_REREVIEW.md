# Isolation repair re-review (read-only, HEAD after `bbf61bf`)

I read the code only, using file-read and search tools. I ran nothing, edited nothing and used no other agents. All test counts below are Astra's reported numbers, not reruns. It is September 28, but I couldn't check the clock against the 05:00 Eastern reset without a shell.

`tools/runtime_launcher.py` and `tools/measure_isolation.py` don't exist. The launcher and measurement code are in `tools/launch_practice.py`, which isn't in the repair diff, so I reviewed its current source instead.

**Summary:** no Critical findings and nothing unsafe. Every gap I found fails closed, either as a refusal or a global lockout. Controlled P1A can proceed once the fresh process checks and backups pass. P1B, FULL_P1, CRASH, P2, the certificate and MATCH are blocked on the items below. The single-session P2 design is not approved; a three-phase alternative is in section 4.

## 1. What happened to each earlier finding

| ID | Status | What the code shows |
|---|---|---|
| **R1** (backup not tied to the session) | **Closed** | `check_backup_evidence` now returns a content ID built from the manifest hash and every per-root file digest (`launch_practice.py:2018-2085`). `prepare_session` requires a sha256 ID and a digest for each root. It refuses a caller ID that doesn't match, and it requires the before-snapshot to have the same root keys and digests as the backup (`isolation_certificate.py:2248-2310`). The verdict step also requires the sha256 ID (`:2458-2466`). Tests use the real backup code. The snapshot-key change only drops the duplicate bare `steam_userdata` key (`staging.py:427-435`). |
| **R2** (receipts didn't check the user's game is closed) | **Closed** | `live_closed` is required, and a failure raises the lockout (`isolation_certificate.py:1411-1420`). Supervision also checks for a live Balatro or a foreign staged session on every tick (`launch_practice.py:2446-2462`). |
| **R3** (error or Ctrl+C left a stuck record) | **Closed** | An `except BaseException` block records the failure and lockout, then re-raises, and a `finally` closes the Job (`:2478-2488`). A failed PID bind now aborts and locks out (`:1795-1800`, `:1919-1937`). |
| **H3** (CRASH/P2 evidence was caller claims) | **Partly closed** | The caller `observation` argument is gone. CRASH now comes from the retained handles plus the prepared setup, and P2 from the copied observer artifact. **Still open:** N1, N2, N4 and N6 below. |
| **M1** (caller's open-session mapping trusted) | **Closed** | `_resolved_open_session` reloads the record from disk. It checks status, nonce, phase, certificate, port and that no PIDs are bound yet, and it requires phase MATCH exactly when a certificate is required (`:1806-1828`). Leftover: N7. |
| **M2** (receipts skipped the strong checks) | **Closed** | Receipts now call `collect_role_probes` and `check_lovely_evidence(require_dump=True)` (`isolation_certificate.py:1462-1482`). The Lovely dump is copied, hashed, and bound into the certificate and its check. Leftover: N8. |
| **M3** (tool binding could be empty) | **Closed** | Both build and check require exactly the bound tool set. |
| L4, L5, L6, L7, L8 | **Closed** | Attestation requires phase MATCH and a matching certificate ID. The caller-supplied nonce is gone. Session-ID reuse is refused. Receipts store raw before/after manifests and validation recomputes them. The suppression scan's `ok` is now bound. |
| L9 (`bootstrap --timeout` ignored) | **Closed** | Now passed through (`:2719`). But `measure` still has no timeout (N3). |
| L1–L3 | **Unchanged** | Not touched by this diff. Still Low. |
| Phase/port bound to the prepared record | **Closed** | `record_phase_receipt` checks both before deriving any evidence (`isolation_certificate.py:1400-1410`). |
| P2 coverage re-derived from the copied artifact | **Closed** | The copied artifact is re-parsed and run through the same classifier. Counters, endpoint and covered/pending lists must all match. |
| Changes to gameplay, network protocol, timeouts or RNG | **None found** | All added Lua is additive and gated by an environment variable. The child environment is allowlisted, so those gates can't be inherited (`staging.py:917-930`). The gate-off trace matches the unpatched source, but only one scenario is tested (N5). |

## 2. New actionable findings

**N1 — High (blocks P2; fails closed). The connect observer's anchor won't match in native Lovely, and nothing in the checks would notice.**
- **Where:** `staging.py:104` and the connect patch in `mp_p2_observer_patches` (`:1535+`). The guard is at `:1444-1462`, the test helper at `:1636-1660`, and the test check at `tests/test_p2_observer.py:190`.
- **Failure:**
  - Lovely pattern patches match the whole trimmed line, with `*`/`?` wildcards. Please confirm this against the pinned Lovely version.
  - The pinned line (`socket.lua:55`) is `local connectionResult, errorMessage = Networking.Client:connect(CONFIG_URL, CONFIG_PORT) -- Not sure…`. The anchor is only a fragment of it.
  - The other six anchors are full lines, as are all the other staging patches and the MP mod's own patches. So the state block would still apply and the guard's `AISP_P2_FLUSH` check would pass.
  - Natively, the dead-port connect is then never observed and no artifact is written. The receipt is refused, which raises the lockout and wastes the run.
  - The only proof that the patch applies is the substring helper, which matches more loosely than Lovely.
- **Minimal repair:**
  - Use the exact full trimmed line as the anchor. That works under either matching rule.
  - Put a unique marker comment in each of the 7 payloads. When the P2 gate is on, the guard should require all 7 markers in `SOCKET`.
  - Make `apply_source_pattern_patch` behave like Lovely: match each stripped line against the wildcard pattern, and fail unless the match count equals `times`.
  - Have `check_multiplayer_guard` verify that each anchor matches exactly one line of the staged MP `networking/socket.lua`.
  - Have P2 receipts copy Lovely's dump of the patched socket source and require all 7 markers in it.

**N2 — High (blocks CRASH). The crash stimulus can't finish without a person, and its exit code doesn't prove a crash.**
- **Where:** `staging.py:1401-1422`, `isolation_certificate.py:865-900`, `launch_practice.py:2454-2467` and `:542`. Game side: `work/reference/game/main.lua:198-322`.
- **Failure:**
  - The `error()` at the end of `love.load` goes to Balatro's `love.errhand`. It draws the crash screen and loops until a quit event or Escape (`:296-320`). SMODS's replacement crash screen should behave the same way; I didn't check its source.
  - With no timeout, supervision waits forever. With a timeout, it records `supervision_timeout` and raises the lockout.
  - The only passing path is a person closing both windows, and nothing records that. LÖVE then exits with 1, which is the same code `TerminateJobObject(…, 1)` produces.
  - `crash_observed` (prepared CRASH plus any nonzero exit) can't tell a crash from a kill.
- **Minimal repair:**
  - Inside the same env-gated payload, wrap the active handler (`love.errorhandler or love.errhand`). The wrapper writes a nonce-bound crash probe, then calls the original handler.
  - The supervisor waits for fresh crash probes from every role, pauses briefly, then ends the Job with a distinct exit code (not 1). The receipt records `ended_by`, the time and the code.
  - Define `crash_observed` as fresh, nonce-bound crash probes for every role, with exit codes equal to the tool's code.

**N3 — Medium (fails closed). P1B, FULL_P1 and P2 runs have no defined end.**
- **Where:** `launch_practice.py:2725-2734` (the `measure` command passes no timeout) and `:2459` (the plan has none). Only P1A quits on its own (`staging.py:1379`).
- **Failure:** the staged games sit at the main menu. Run unattended, they hang; with a timeout, they lock out. Closing the windows by hand passes, but that manual step is never recorded.
- **Minimal repair:**
  - Require a deadline for every `measure` run.
  - Once the required fresh artifacts have settled, the tool ends the run with a distinct exit code and records the end mode in the receipt.
  - Receipt validation should accept only defined end modes. This shares its mechanism with N2.

**N4 — Medium. The P2 classifier overstates reconnect coverage.**
- **Where:** `isolation_certificate.py:966-975` and `:1237-1246`; the observer counters are in `staging.py:1512-1620`.
- **Failure:**
  - `reconnects` counts completed cycles, whether they recovered or gave up. `reconnect_failures` counts failed attempts across all cycles.
  - Two cases pass the current rule without any exhausted, bounded retry:
    - "failed once, then recovered";
    - "a recovered cycle, followed by an unfinished cycle with one failure".
  - Nothing records what caused a cycle, and `closes` only counts the pinned `error == "close"` branch.
- **Minimal repair:** record per-cycle fields and use the precise definitions in section 4. Add negative checks for both cases above.

**N5 — Low. The observer tests prove less than their names suggest.**
- **Where:** the fake receive in `tests/test_p2_observer.py` returns `"close"` (`:311`, `:337`).
- **Failure:**
  - LuaSocket's peer-close result is `"closed"`; I'm going by the LuaSocket source, not a native run.
  - The fake allows every socket method in every socket state, which native LuaSocket doesn't.
  - So the reconnect test shows the branch runs *if* the library returned `"close"`. It isn't evidence of native closure handling.
  - Gate-off equivalence covers only one scenario (`:308-311`).
- **Minimal repair:**
  - Label these as branch-reachability tests.
  - Add gate-off comparisons for the dead-port and keepalive scenarios.
  - Add a `"closed"` scenario showing the close branch doesn't fire, the keepalive path takes over, and the classifier labels it correctly.

**N6 — Low. The measurement setup is still a caller-supplied dict at the library boundary.**
- **Where:** `prepare_session` stores any mapping (`isolation_certificate.py:2326`). The unused `record_measurement_setup` (`:2171-2184`) can rewrite it on an open record even after PIDs are bound.
- **Failure:** P2's `refused`/`listener_absent` values and the CRASH label come from this dict.
- **Minimal repair:** delete `record_measurement_setup`. Validate the setup's shape per phase in `prepare_session`: the exact CRASH constant; for P2, `dead_port == port`. Record who measured it.

**N7 — Low. The measurement flags aren't tied to the prepared phase.**
- **Where:** `execute_launch(measure_crash=…, measure_p2=…)` (`launch_practice.py:1727-1728`, `:1605-1608`).
- **Failure:** a MATCH launch can switch on the measurement gates. The in-repo callers are correct.
- **Minimal repair:** derive both flags from `record["phase"]`.

**N8 — Low. `_select_dump_files` falls back to any fresh dump** (`isolation_certificate.py:777`). **Minimal repair:** require the `main.lua` dump, plus the socket dump for P2.

**N9 — Low. `_read_p2_probe_fields` accepts an artifact with no nonce** (`:1104`). Strict probe validation catches this later. **Minimal repair:** make this check strict too.

**N10 — Low. Small receipt-bookkeeping gaps.**
- **Failure:**
  - A P2 receipt with pending coverage still closes its record as `passed`.
  - `collect_phase_receipts` picks by hash-sorted filename, not by time (`:1722-1736`).
  - `measurement.json` is hash-checked but never compared with the receipt's `measured` block (`:1674`).
- **Minimal repair:** add a `coverage_complete` flag, select receipts by exit time or explicit ID, and compare the parsed artifact with the receipt.

## 3. Verdict on the repository repairs

- **No Critical and no safety regression.** R1–R3, M1–M3 and L4–L9 are closed. H3 is closed as far as caller claims go.
- **P1A:** may proceed with controlled staged measurement, after fresh process checks and a fresh backup. It quits on its own.
- **P1B and FULL_P1:** blocked until N3 is fixed.
- **CRASH:** blocked until N2 and N3 are fixed.
- **P2, `build_certificate` and MATCH:** blocked by N1, N4, the design below and native evidence.
- N1–N4 are significant repairs, so they need a targeted Claude re-review of the actual diff. The Lows can be batched into that.

## 4. Verdict on the native P2 stimulus design

**The single-session design in the proposal is not approved.** It needs a new in-game way to trigger Connect, or a person clicking it without any record. After the first failure, the thread is in whatever state native LuaSocket leaves a failed socket in, which has never been measured. And one session's reconnect can't be attributed to a specific scenario.

MP connects on its own at startup (`core.lua:349-350`). That makes a smaller design possible with no in-game control at all.

**Required design: three complete, separate measurement phases.** `P2_INITIAL`, `P2_CLOSE` and `P2_SILENT` each have FULL_P1 as their prerequisite and use the AI role only.
- Each gets its own prepare step, nonce, backup tie, before/after snapshots, live-closed check and immutable receipt.
- The certificate requires all three receipt IDs. IDs stay content digests, and the existing distinct-nonce check applies.
- The pinned server is not running, and MATCH is unchanged.

**Tool-owned listener (measurement only):**
- It binds `127.0.0.1` on the fixed MP port only, with exclusive address use. Never `::1`, a wildcard or the admin port.
- Before spawning, the native listener inventory must show that only the tool's PID is listening.
- It accepts exactly one connection. The peer endpoint's owning PID must be the owned AI PID, checked through the TCP table; otherwise abort and lock out.
- It closes the listening socket right after accepting, so every reconnect is refused and the retry cycle runs to exhaustion.
- It never sends a byte. It records only the received byte count, a sha256 and the JSON `action` names.
- `P2_CLOSE`: drain, then close gracefully (FIN, not RST) at a recorded time.
- `P2_SILENT`: keep the connection open and discard everything received.
- The tool writes its listener log as an immutable, hashed receipt artifact.

**Observer additions.** These stay additive, env-gated and anchored on full lines. The `"close"` comparison, timeouts and retry counts are not touched.
- Count and time of successful connects.
- The first time each distinct non-`timeout` receive error appears, recorded verbatim (after `socket.lua:145`).
- The count and times of `keepAlive` pushes (after `:222`).
- For each retry cycle:
  - its cause (`close` from the close-branch comment, `keepalive` from the keepalive comment);
  - its start time;
  - each attempt's time and result;
  - its outcome: `recovered` at the success literal, `exhausted` at the failure literal.
- Flush the artifact on each of these events, not on every receive.

**Coverage definitions (these replace the aggregate reconnect rule; recovered cycles are never claimed):**
- **initial_failure (`P2_INITIAL`):**
  - The tool proves the port is dead before spawn and after exit.
  - The first attempt to `127.0.0.1:dead_port` returns something other than 1.
  - There are zero successful connects and zero cycles.
- **closure (`P2_CLOSE`):**
  - The listener log shows one accepted connection from the owned AI PID and a FIN close at a recorded time.
  - The first connect result is 1, and a receive error is recorded after the close.
  - There is exactly one exhausted cycle in which attempts = failures = 3.
  - The gaps between attempts fit 2, 4 and 8 seconds within tolerance.
  - It gets `closure_path = close_branch` only if that cycle's cause is `close`; otherwise it is `keepalive_fallback`.
- **keepalive (`P2_SILENT`):**
  - The listener sent 0 bytes and held the connection open until after the cycle.
  - The first connect result is 1, and no receive error other than `timeout` appears before expiry.
  - There are 5 keepAlive pushes: the first about 20 seconds after the last data, then about every 5 seconds. Allow roughly ±2 seconds, because the pinned timer uses whole-second `os.time`.
  - There is one exhausted cycle with cause `keepalive`, attempts = failures = 3, and delays of 2, 4 and 8 seconds.

**How closure should be represented (my recommendation; a policy call for you/Astra):**
- LuaSocket most likely returns `"closed"`, so the pinned `== "close"` branch probably never runs natively and closure would be handled by the keepalive path.
- I recommend counting that as a P2 closure pass, with `closure_path` carried into the certificate and the docs. The requirement is bounded, loopback-only failure handling after a server close; it isn't that one particular branch runs.
- Never infer the close branch from the fixture counter.
- If you require the branch itself, native P2 can't pass without changing MP code, which is out of scope.

**How each run ends:**
- The tool ends the run with a distinct, recorded exit code once the terminal state has settled:
  - `P2_INITIAL`: the first attempt is recorded, then 5 seconds pass with no further attempt.
  - `P2_CLOSE` / `P2_SILENT`: the exhausted cycle has been flushed, then 3 seconds pass.
- A hard deadline (about 240 seconds) counts as failure and raises the lockout.

**Remaining implementation work, in order:**
1. Fix N1: full-line anchor, Lovely-faithful helper, all-marker guard, socket dump check.
2. Add the observer fields above, plus gate-off-versus-unpatched comparisons for all three scenarios on both Lua runtimes.
3. Split the phases in `isolation_certificate.py` (phase lists, roles, evidence, prerequisites, per-phase classifiers, certificate bundles) and remove the aggregate reconnect rule.
4. Add the listener, its log, and the inventory and owner-PID checks in `launch_practice.py`. Add `measure --phase P2_CLOSE|P2_SILENT`, with nothing injectable from the CLI.
5. Implement the tool-owned end mode (N3), shared with CRASH (N2).
6. Add fixtures for:
   - `"closed"` versus `"close"` labeling;
   - both cross-cycle overstatement cases;
   - a wrong-owner connection being refused;
   - a listener that sent bytes being refused.
7. Claude re-review of that diff before any native run.

Native Lovely matching, real socket results, real timer behavior and game isolation are still unproven. Only native runs can prove them, and those still require fresh process checks, fresh backups and all the existing gates. This review doesn't authorize any launch, and I didn't write the plan file because no write tool was available in this session.

Separately: the claude.ai Gmail, Google Calendar and Google Drive connectors need authorizing in your claude.ai connector settings. They weren't needed for this review.
