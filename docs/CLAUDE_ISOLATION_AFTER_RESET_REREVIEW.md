# Isolation actual-diff re-review (read-only, `4ebb775..9c698ae` plus current tool source)

**Verdict: no Critical findings, and every gap I found fails closed.** You can run P1A, P1B, FULL_P1 and CRASH as controlled native measurements now. P2_INITIAL is ready after one small fix (F4). P2_CLOSE and P2_SILENT are blocked:

- **P2_SILENT can't pass on a real run as written (F1).**
- **P2_CLOSE and P2_SILENT will probably both fail the 2/4/8-second timing check on Windows (F2).**

I only read code. I ran nothing, wrote nothing, and used no agents, network or game actions. Test counts are Astra's captures; I didn't rerun them. The host commits after `9c698ae` (`47e1f64`, `776fd47`) aren't in this diff and aren't approved here.

## Earlier findings

| ID | Status | Notes |
|---|---|---|
| N1 (connect anchor wouldn't match in Lovely) | **Closed** | All nine anchors are exact full lines. I checked each against the pinned `socket.lua` (55, 76, 84, 89, 145, 162, 206, 222) and each is unique. The test helper now matches Lovely: whole trimmed line, `*`/`?` wildcards, and it fails unless the match count equals `times`. All 9 markers are required in three places: the staged TOML, the runtime `SOCKET` string, and the copied socket dump. The TOML uses `'''` literal strings, so the `\"` in the keepalive anchor survives. Leftovers: F6. |
| N2 (crash needs a person; exit code proves nothing) | **Closed** | The payload wraps whichever handler is active (`love.errorhandler or love.errhand`), writes a nonce-bound probe, then calls the original. Both roles need fresh probes, and every exit code must equal the tool's code 101. Leftover: F9. |
| N3 (runs have no defined end) | **Closed** | 240 s default deadline, a `--timeout` flag, tool-decided settling, and end codes 101–106 (never 0 or 1). Every receipt except P1A must record the end mode and the right code. |
| N4 (reconnect coverage overstated) | **Closed** | The aggregate rule is gone. Only a single completed cycle with 3 failed attempts counts; recovered or unfinished cycles never do. The timing rule itself is wrong on real hardware (F2). |
| N5 (observer tests overclaimed) | **Closed** | Gate-off traces match the unpatched source in three scenarios on both Lua runtimes. A `"closed"` case shows the close branch never runs and the result is labelled `keepalive_fallback`. These remain fixture guarantees, not native proof. |
| N6 (setup was a caller-supplied dict) | **Closed** | `record_measurement_setup` is deleted, and the setup's shape is checked per phase. |
| N7 (measurement flags not tied to phase) | **Closed** | The flags now come from the prepared record. The old `execute_launch` parameters remain but are ignored (`launch_practice.py:1768-1769`); remove them. |
| N8 (any fresh dump accepted) | **Closed** | Exact patched-dump paths are required. The SMODS dump path itself is unverified (F6). |
| N9 (P2 artifact with no nonce) | **Closed** | |
| N10 (receipt bookkeeping) | **Closed** | `coverage_complete` is added, a pending P2 receipt is refused, receipts are picked by `exited_unix`, and `measurement.json` must equal the receipt's `measured` block. |

**Astra's independent findings:**
- **Inventory acceptance:** fixed. An empty, failed or foreign inventory is refused. "Own" requires `127.0.0.1` plus this process's PID.
- **Failed FIN stamped as success:** fixed. `fin` is set only if `shutdown` succeeds.
- **SILENT hold proof missing or early:** both of Astra's negatives now fail, but the fix went too far (F1).
- **`list_open_records` ignoring malformed records:** fixed. The installer refuses and the host treats the anomaly as an open session. One unwrapped caller remains (F10).

## Remaining findings

**F1 — High (blocks P2_SILENT; fails closed). A real SILENT run can never pass.**
- **Where:** `launch_practice.py:2712-2721` (end-of-stream handling in `_serve`) and `isolation_certificate.py:1234-1251` (`_listener_held_through`).
- **Why:** at keepalive expiry the pinned code closes the game's own socket (`socket.lua:203-204`, `Networking.Client:close()`) just before starting the retry cycle.
  - The listener sees that as end-of-stream. It sets `peer_eof`, caps `open_until` at that moment and stops.
  - That moment is roughly the cycle's start, about 14 s before the cycle ends. The coverage check requires `open_until >= cycle end`, so it always fails.
  - The fixtures never model the game closing its own socket, so they can't catch this.
- **Minimal fix:**
  - Record `peer_eof`/`eof_time` separately and keep holding. Set `open_until` only when the tool itself releases the connection in `finish()`.
  - Coverage should require: `open_until >= cycle.end_time`, no listener close or shutdown before then, and, if the game closed, `eof_time` falls after the fifth keepAlive push plus about 5 s (within tolerance) and no later than the cycle start plus tolerance.
  - Keep Astra's two negatives. Add three cases: a close before the fifth push fails; a reset before the cycle ends fails; a close at expiry with the listener still holding passes.

**F2 — High (probably blocks P2_CLOSE and P2_SILENT; fails closed). The retry-gap timing includes how long each connect takes.**
- **Where:** `staging.py:1639` (attempts are timestamped after `connect` returns), `isolation_certificate.py:1092-1110` (gaps compared to 2/4/8 s ±1.0 s).
- **Why:** each measured gap is the pinned sleep plus the time a refused connect takes.
  - Windows usually takes about 1–2 s to report a refused loopback connect, because it retries the connection after being refused. That's from known Windows behaviour; I haven't measured it here.
  - At 2 s, every gap is outside tolerance. The fixture's fake `connect` returns instantly, so tests can't show this.
  - My own section 4 wording ("gaps between attempts") missed this too.
- **Minimal fix:**
  - Add a tenth env-gated `before` patch on the same connect line that records the attempt's start time (with a new marker).
  - Measure each gap from the previous attempt's end (or the cycle start) to the next attempt's start.
  - Record connect durations separately.
  - Optionally, first time a refused loopback connect with Astra's non-game helper.

**F3 — Medium. The listener evidence isn't re-derived from the copied listener log.**
- **Where:** `isolation_certificate.py:1325` feeds coverage from `measured["listener"]`. The copied `listener` probe only gets nonce and patch checks (`:1526-1549`).
- **Why:** nothing compares the copied log's `peer_pid` with the receipt's `pids["ai"]`, or checks its `peer_host`, `port`, `listener_pid`, schema, phase or `sent_bytes`.
- **Minimal fix:** in `_validate_p2_artifact_binding`, parse the copied listener fields and build the listener view from them. Require it to equal `measured["listener"]`, use it for coverage, and add the field checks above.

**F4 — Medium (the adopted design requires this; it isn't a false-pass risk). P2_INITIAL has no after-exit dead-port proof.**
- **Where:** the dead port is measured only before spawn (`launch_practice.py:2971-2977`).
- **Minimal fix:** after supervision ends, re-run `measure_dead_port(port=launch_port)`. Bind the result into the receipt and require the port to be refused and absent on both families after exit.

**Low findings:**
- **F5 — P2_CLOSE ordering** (`isolation_certificate.py:~1283-1290`; `launch_practice.py:2734`):
  - Nothing requires FIN ≤ first receive error ≤ cycle start.
  - `close_time` is stamped after `shutdown` returns.
  - **Fix:** stamp the time before `shutdown` and require that order.
- **F6 — socket dump rules** (`:1864` vs `:2079`):
  - The record step requires the socket dump only for CLOSE/SILENT, but validation requires it for all P2 phases. Use `require_socket=phase in P2_PHASES`.
  - The marker check is skipped if the copied file is missing; the tamper check still catches that.
  - The `SMODS/Multiplayer/networking/socket.lua` dump path is taken from Lovely's source, not observed. Confirm it in the first MP-enabled P1B dump tree before any P2 run.
- **F7 — slow abort on a wrong peer** (`launch_practice.py:3093-3117`): a wrong-owner or never-accepted listener keeps running until settle or the 240 s deadline. **Fix:** make the `unexpected` check abort once the listener has finished without an owned AI peer.
- **F8 — log labelling** (`launch_practice.py:2772`, `:2764`):
  - `received_bytes` is the capped retained count, not the total.
  - `exclusive=true` is hardcoded.
  - **Fix:** record the total and the retained count separately, and record exclusivity only if `setsockopt` succeeded.
- **F9 — crash message not bound:** require the crash probe's `msg` to contain the stimulus text (`staging.py:1476`, `isolation_certificate.py:929`).
- **F10 — unwrapped strict listing:** `prepare_session` calls the strict `list_open_records` unwrapped (`isolation_certificate.py:2727`). A malformed record then escapes as an exception, and a failure gets recorded for a session that was never prepared. **Fix:** convert it to an `open_records_unreadable` problem.
- **F11 — tidy-ups:**
  - `_default_port_probe` counts a timeout as "refused" (`:2307`; this predates the diff).
  - The `measurement_refused` result has no `"ok": False` (`:3005`).
  - `_make_p2_settle` doesn't check the nonce. Probe rotation covers this today.

**Unchanged, as required:** all Multiplayer insertions are additive and env-gated. The `error == "close"` comparison, timeouts, retry counts, 2/4/8 delays, keepalive values and RNG are untouched in the pinned source. Gate-off equivalence on both Lua runtimes is a fixture guarantee, not native Lovely or game proof.

## Scope verdict for controlled native measurement

| Phase | Verdict |
|---|---|
| P1A | May proceed (unchanged) |
| P1B, FULL_P1 | May proceed |
| CRASH | May proceed after the FULL_P1 receipt; F9 is optional |
| P2_INITIAL | May proceed after F4 (F6 recommended) |
| P2_CLOSE | Blocked on F2 and F3 |
| P2_SILENT | Blocked on F1, F2 and F3 |
| `build_certificate` / MATCH | Blocked until all seven real receipts exist with distinct nonces |

Every native run still needs a fresh check that Balatro isn't running and a fresh backup immediately before it, never while the game is open. F1–F4 need a short targeted Claude re-review of the fix diff; the Lows can go in the same batch.

Nothing here demonstrates playability or compatibility. P1A through P2_SILENT, actual gameplay and compatibility all remain unmeasured, and this review doesn't itself authorise any launch.
