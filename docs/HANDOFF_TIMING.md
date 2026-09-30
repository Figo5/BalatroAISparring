# Practice hand-off timing

The first human-played match measured about 3.5 minutes from the live game's
exit to the staged roles' launch (`NATIVE_TEST_PROGRESS.md`). That session had
no per-stage timing, so this document records the instrumentation added in the
cloud period, what the code path suggests, and what the next local run should
measure. **No improved real-world hand-off time is claimed until the next local
run.**

## Instrumentation

`MatchSupervisor` owns a `StageTimer` (`tools/practice_host.py`).

- It uses its own `perf_counter` clock, never the injected supervisor clock. It
  cannot change a deadline or a poll, and a recording failure never changes a
  verdict.
- Each finished stage is appended at once to
  `<session>/logs/handoff.jsonl` as `{"stage","start","seconds","ok","code"?}`.
  Instant milestones have `"seconds": 0` and `"milestone": true`, plus small
  primitive extras (for example `pid_reused`).
  A hand-off that never completes still shows where its time went.
- At the end, the session report `<session>/host.json` has a `timings`
  object with these fields:
  - `stages`: every stage and milestone in order.
  - `totals`: seconds per stage name.
  - `slowest`: the top five stages.
  - `counters.process_enumeration`: `calls` and `seconds` across every process
    listing made through the supervisor's enumerator, including the default
    backup runner's closed-game check. The launcher's own internal listings
    inside `roles_launch` also go through it. Listings made inside the
    certificate API with its own enumerator are not counted. On Windows each
    listing is a PowerShell `Get-Process` run.
  - `service_milestones`: seconds since the control service object was created
    (inside `service_start`), for
    `hello_human`/`hello_ai`, `lobby_code`, `join_code_served`,
    `ready_human`/`ready_ai` and `match_started`.

Recorded stages, in order:

| Stage | What it covers |
|---|---|
| `wait_live_exit`, milestone `live_exited` | from the start acknowledgement until the live game has exited |
| `gates_total` | everything below until the exclusive open record exists |
| `gate_lockouts` | host lockout, certificate open records, certificate lockout |
| `gate_runtime_preflight` | Lua runtime, policy source and canonicalizer |
| `gate_static_isolation` | staged isolation gates, including a process listing |
| `gate_certificate` | certificate check against live and staging |
| `gate_server_adaptation` | pinned local server adaptation |
| `gate_staged_endpoints` | staged endpoint configuration |
| `gate_content_hash` | role-parity content hash of the staging trees |
| `gate_ruleset` | Major League ruleset digest from staged sources |
| `prepare_session_total` | the three steps below plus the certificate record |
| `baseline_quiescence` | two Steam userdata snapshots 5 s apart (required) |
| `baseline_backup` | the fresh full byte backup of the live roots |
| `baseline_verify_backup` | re-hash the backup against live |
| `certificate_prepare_session` | the certificate re-reads backup and live itself, then writes the open record |
| `service_start` | control service |
| `attestation_rotate` | old attestation files cleared |
| `server_start` | local match server plus the listener owner proof |
| `roles_launch`, milestone `roles_launched` | suspended spawn, Job Object, resume for both roles |
| `certificate_bind_open_record` | bind the spawned PIDs to the record |
| `attestation_wait`, milestone `attested` | both roles' startup attestations |
| milestone `match_started` | first supervision poll that sees the service started |

## What the code path suggests (hypotheses to confirm locally)

1. **Full live backup, then verification three times.** `baseline_backup`
   copies AppData (983 files, including Mods and saves), the install and Steam
   userdata. The backup is then hashed against live in `baseline_verify_backup`,
   and again inside `certificate_prepare_session` via `backup_verify`, which is
   deliberate: the certificate re-reads the evidence itself instead of trusting
   a cached verdict. Expected to be the largest block. Any reduction, such as an
   incremental backup keyed on the previous verified manifest, changes the
   backup contract. It needs its own review and full re-certification, so it
   was **not** done in the cloud.
2. **Repeated PowerShell process listings.** The static gates, the backup's
   closed-game check, the pre-spawn live check and the launcher's
   `_spawn_verified` each run `Get-Process` over every process. Typically each
   run takes 1–3 s on Windows. `counters.process_enumeration` will show the real
   count and cost. A native Toolhelp32 enumerator (ctypes, milliseconds per
   listing) is the obvious follow-up if this is large. It changes
   isolation-critical code and needs native validation.
3. **Staging tree hashing.** `gate_certificate` and `gate_content_hash` hash
   both staged roles, including two copies of the game.
4. **Fixed waits.** `baseline_quiescence` sleeps 5 s by design. That is required
   for Steam userdata stability and is unchanged.

## Changes made (cloud)

- The live-exit and attestation waits now poll every 0.25 s
  (`handoff_poll_interval`) instead of every 1 s. Each poll is a query-only
  handle read or a small file read. The one exception is when the live handle
  cannot be opened but the process listing still shows the game running. That
  fallback runs a full PowerShell listing, so it still waits the general 1 s
  `poll_interval` between checks, and a shutting-down game is not slowed down.
  The match supervision loop keeps its 1 s `poll_interval`.
- No verification, backup, hashing, quiescence or isolation step was removed or
  weakened.

## Local measurement (LV-5)

After the next re-certification and reinstall, run one normal Play → AI
Sparring hand-off. Then send `<session>/host.json` `timings` and
`<session>/logs/handoff.jsonl`. The `slowest` list and
`counters.process_enumeration` should settle hypotheses 1–3 and pick the next
optimization.
