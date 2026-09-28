# Claude isolation source corrections re-review

Reviewed commit: fddea7e0215bf4014f9706bbfb96c49c7d0f1770
Reviewer: Claude Code / claude-opus-5-5 / High
Scope: actual source and scoped diff; read-only. Test runs were independently performed by Astra, not Claude.

**Verdict: F1–F4 are all resolved in the actual code, and I found no Critical or High issues.** Nothing blocks the controlled native runs. Two new Low issues are worth fixing before the P2 runs; both fail closed, so neither can produce a false pass.

I only read code and the captured results. I didn't run tests, git or any shell, didn't compare `fddea7e` against the diff file, and didn't reopen the separately accepted host/service work. The locally modified `docs/PLAYABLE_ACCEPTANCE.md` wasn't reviewed.

## F1–F4

| ID | Status | Evidence |
|---|---|---|
| **F1** SILENT expiry EOF | **Closed** | The pinned source closes the game's socket (`socket.lua:204`) before the cycle-start hook (`:206`). The timer counts in whole seconds (`:119-126`), so the gap from the fifth push to the close is 4–5 s plus up to 0.05 s. That fits comfortably inside the 5 ± 2 s window. The listener never sends, so the game's close is a normal FIN, not a reset.<br>• The listener records a normal EOF as `peer_eof`/`eof_time` and a reset as `peer_reset`. Neither sets `open_until` (`launch_practice.py:2740-2759`); only the tool's own release in `finish()` does (`:2779-2794`).<br>• Coverage requires: no `closed`/`fin`, no reset, an EOF inside the expiry window and no later than cycle start + 2 s, and a hold through the end of the cycle (`isolation_certificate.py:1290-1330`, `:1392-1408`).<br>• The missing-hold and early-hold negatives still fail, and a positive control now passes. New negatives cover an early EOF, a reset and an early release. The native Windows check passed. |
| **F2** sleep vs connect time | **Closed** (Low L1 below) | A tenth `before` patch on the same exact connect line stamps `pending_start` (`staging.py:1711-1722`). The state it uses is a file-level local, so it's in scope. Each gap is now measured from the previous attempt's end to the next attempt's start (or from the cycle start); an attempt with no start time is refused.<br>• Connect durations are kept separately and re-derived (`P2_connect_durations_not_rederived`).<br>• The 2/4/8 delays and the ±1.0 s tolerance are unchanged. Your measured 1.0–1.03 s refusals now sit entirely inside the connect duration.<br>• The gate-off check uses the full patch list, including the tenth patch: all three traces match the unpatched source on both Lua runtimes (6/6). The classifier accepts the start fields that the real patched source emits.<br>• All 10 markers are required at runtime (`staging.py:1551`) and in the copied socket dump (`isolation_certificate.py:2293`). |
| **F3** listener evidence from the copy | **Closed** | For CLOSE/SILENT, the listener view is now rebuilt from the copied log. It must equal `measured["listener"]` (`P2_listener_not_rederived`), and coverage uses the copy's view, so the stored measured block can't override it.<br>`_validate_listener_binding` checks: probe, schema, patch, nonce, phase, port, `peer_host` = 127.0.0.1, `peer_pid` in the receipt's AI PIDs, listener PID > 0, zero sends, `exclusive`, and total bytes ≥ retained bytes. A missing copy is refused. |
| **F4** after-exit dead port | **Closed** (Low L3 below) | After supervision and listener shutdown, the same port is probed again (`launch_practice.py:3181-3196`). The receipt refuses the result unless it is ok, refused and absent on both families, not timed out, and for the same port (`isolation_certificate.py:1796-1804`).<br>A timeout never counts as refused: only `ConnectionRefusedError` counts, every attempt must be a refusal, and `measure_dead_port` also rejects `timed_out`. The 3 s probe limit now exceeds the measured 1.03 s refusal time. The native run shows three real refusals (1.026/1.006/1.008 s) with both families absent. |

## F5–F11 (measurement correctness only)

F5 through F11 are all correct as implemented:
- **F5:** the close is time-stamped before the `shutdown` attempt, and the order FIN ≤ first receive error ≤ cycle start is enforced.
- **F6:** the socket dump is now required for every P2 phase.
- **F7:** the run aborts promptly once the listener finishes without an owned AI peer, with no race on its state.
- **F8:** `exclusive` is recorded from the actual socket option, and total and retained byte counts are recorded separately.
- **F9:** the crash message must contain the stimulus text, which the payload now emits.
- **F10:** an unreadable open-records listing becomes a `open_records_unreadable` problem instead of an escaping exception.
- **F11:** timeouts are handled as above, the refusal result now has `"ok": False`, and the settle check verifies the nonce.

## New Low findings (non-blocking)

- **L1 — marker names overlap.** The new `AISP_P2_CONNECT_BEFORE` contains `AISP_P2_CONNECT`, and the older `AISP_P2_KEEPALIVE_PUSH` contains `AISP_P2_KEEPALIVE`. Because both checks use plain substring search, they can't prove markers 1 and 6 were applied independently.
  - **Why it isn't a false pass:** without the after-connect hook no attempt is recorded, and without the keepalive hook no keepalive cycle exists, so coverage fails.
  - **Fix:** match whole marker lines (`-- MARKER` followed by end of line) in both the Lua runtime guard and the dump check, or rename to names that aren't prefixes of each other.
- **L2 — the P2_CLOSE ordering check spans two clocks.** It compares Python's `time.time()` for the FIN with LuaSocket's `gettime()` for the error, and the margin is only milliseconds. If the tool's Python uses the precise Windows clock while LuaSocket uses the tick-based one, a genuine first error can read up to one clock tick earlier than the FIN. The game's 50 ms polling usually hides this, but not always.
  - **Cost:** a spurious failure closes the session as failed and needs a manual acknowledgement.
  - **Fix:** allow a small skew (for example 0.1 s) on this one comparison only.
- **L3 — after-exit freshness isn't recorded as evidence.** `measured_unix` is kept but never checked; the proof is fresh only because of where the call sits.
  - **Fix:** require `int(spawn_time) <= measured_unix <= exited_unix`.
- **Test gap (optional):** the fake `connect` in `test_p2_observer.py:105-119` returns instantly, so no test shows the start and duration being separated. Advancing the fake clock by about 1.03 s on each refused connect would make the reconnect classifier case able to tell them apart. Optionally, write no start time when `pending_start` is nil instead of falling back to the end time (`staging.py:1652`).

## Remaining blockers

None. I recommend fixing L1 and L2 as one small batch before P2_CLOSE and P2_SILENT; L3 is optional.

## Readiness for controlled native runs

| Phase | Verdict |
|---|---|
| P1A, P1B, FULL_P1 | May proceed |
| CRASH | May proceed after the FULL_P1 receipt |
| P2_INITIAL | May proceed |
| P2_CLOSE | May proceed (L2 recommended first) |
| P2_SILENT | May proceed (L1 recommended first) |
| `build_certificate` / MATCH | Blocked until all seven real receipts exist with distinct nonces |

**Conditions for every run:**
- Balatro is running right now, so nothing may proceed until it's closed.
- Immediately before each run: a fresh check that Balatro isn't running, plus a fresh backup.
- Before any P2 run: confirm the `SMODS/Multiplayer/networking/socket.lua` dump path in the first Multiplayer-enabled native dump.

All of these remain real-game gates that fixtures can't satisfy. This review doesn't itself authorise any launch, installation or live write, and it says nothing yet about gameplay, compatibility or playability.
