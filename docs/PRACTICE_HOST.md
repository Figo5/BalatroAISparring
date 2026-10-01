# External practice host (`tools/practice_host.py`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded implementation of the outside-process daemon and closed-game match
supervisor described in `docs/PLAYABLE_RUNTIME_CONTRACT.md` and
`docs/RUNTIME_LAUNCHER.md` §4a. Ships with `tests/test_practice_host.py`,
`tests/test_prepare_server.py` and a minimal typed extension to
`tools/launch_practice.py`.

**Not accepted.** This module has not been reviewed or accepted, and no native or
runtime proof is current. Its fixture suites (and `tests/test_prepare_server.py`)
run against synthetic trees and injected fakes only: they are **not** evidence that
a real server build, real policy runtime, real Windows listener/TCP table or a real
match works. Only Astra's independent real build and execution may establish that.
Nothing here launches a game, writes to a live path, copies a live tree or
terminates a live process; Astra owns every real execution.

## 1. Purpose and placement

The installed companion menu (`AISparring/integration/menu_controller.lua`) must
not spawn, kill, copy or automate anything. It talks to this host, which is a
separate ordinary local process the user starts before opening normal Balatro.
The host owns:

1. a **loopback-only authenticated daemon** the live menu adapter can query
   (`available`) and ask to begin a closed-game transition (`start`/`poll`); and
2. a **match supervisor** that, once the exact original live process has exited
   naturally, re-runs every fail-closed gate and then owns the adapted pinned
   local server, the trusted control service and the two staged roles.

There is deliberately **no concurrent-live mode**: the host never redirects the
live Multiplayer transport, never copies while the live game is running and never
terminates the live process.

## 2. Trust model

Trusted configuration lives only in :class:`HostConfig`, built in the repository
by `default_config()` / `config_from_args()`. A menu request can supply **only**
validated enums/indexes and the exact live PID/create time; it can never supply a
path, root, executable, port, content hash, credential, server manifest or proof.

| Value | Source | Menu can change? |
|---|---|---|
| staging/backup/work/session roots, live install/AppData/Steam roots | repo config | no |
| server root, `AISparring-adaptation.json`, upstream pin, node/python exe | repo config | no |
| difficulty / pacing / mode / gauntlet label | menu request enums | yes (enum only) |
| match port | repo config (fixed) | no |
| session id, credentials, control port, content hash, probe nonce | host-generated | no |
| live PID / create time | menu request | yes (exact identity checked) |

`HostConfig` also fixes the gauntlet catalogue to the exact stable
`AISP0001..AISP0005` / `Test1..Test5` seeds from `practice_service`, so a menu
request cannot introduce a seed, search or reorder.

## 3. Discovery marker

`serve` writes `work/aisparring-host/practice_host.json` (gitignored `work/`, never
a save directory) with:

- `schema`, `version`, `daemon_id`, `session`;
- exact `pid` and native `create_time` of the daemon process;
- `module_sha256` of this module;
- loopback `host`/`port`, the random `secret`, `started_unix` and the op/enum
  catalogue.

`discovery_state()` classifies an existing marker. The marker's process is
checked query-only: one handle read, where an exited-but-held Windows handle
counts as exited, else the process listing. Nothing is ever terminated.

| State | Meaning | Action |
|---|---|---|
| `absent` | no marker | start |
| `live` | this build's daemon, exact PID and create time running | refuse `practice_host_already_running` |
| `stale` / `stale_pid_reused` | this build's daemon, proven exited, or its PID now belongs to another process | replace (`stale_replaced: true`) |
| `previous_build_live` | well-formed marker in our schema with another `module_sha256`, and its exact process is still running | refuse `practice_host_previous_build_running`; never clobbered |
| `stale_previous_build` | the same, with its process proven gone or its PID reused | replace (`stale_replaced: true`; `replaced` reports the old pid, hash and version) |
| `unverified` | liveness could not be proven either way | refuse |
| `foreign` | unreadable, or not our well-formed schema (`pid` not a positive DWORD, `create_time` not a finite positive number, or `module_sha256` not 64 lowercase hex) | refuse; never clobbered |

`serve` on Windows refuses to start (`practice_host_create_time_unavailable`)
when it cannot read its own create time, because a marker without one would read
as foreign next time. `ok` in the result follows one convention for both builds:
a reused PID is reported `ok: false` and still replaced by `serve`. Any failure
of the process listing counts as `unverified`. Note that the live menu matches
the marker's `version` (`practice_host/1`), not the module hash. While a
previous build is still running, the menu keeps talking to that build until it
is stopped.

A previous build is recognised by structure only: our exact schema string and
field shapes, in our private `work/` directory. That is enough, because it is
replaced only when its owning process is proven gone. `reissue-certificate`
refuses on `live`, `previous_build_live`, `unverified` and `foreign`. Before
this change, the first human-played match needed a manual marker rename after
the exit fix, because an exited previous-build daemon was classified `foreign`.
The secret is only in this private file and is never logged or returned in a
response.

## 4. Daemon wire protocol

Transport: TCP `127.0.0.1` only, one JSON object per line, 64 KiB caps, duplicate
JSON keys and `NaN`/`Infinity` rejected. Every request is exactly four keys:

```json
{"schema":"aisparring.practice_host.request.v1","op":"available|start|poll|status",
 "auth":"<discovery secret>","request": { ... }}
```

`auth` is compared with `hmac.compare_digest`. Unknown schema/op/shape returns a
bounded code; no path, credential or exception text ever leaves the host.

### 4.1 `available`

`request` = `{}` (an optional `live_pid` is accepted). Returns the host version,
daemon id, whether a ticket is active and the exact enum catalogue. This is what
the menu uses to decide whether the host is present and which settings are legal.
A missing host (connection refused) leaves the menu usable with a setup
diagnostic — the host never forces a quit.

### 4.2 `start`

`request` must be exactly
`{session_id, difficulty, pacing, mode, gauntlet, live_pid, live_create_time}`.

The host validates `session_id`, `difficulty ∈ {rookie, competitive,
major_league, expert}`, `pacing ∈ {instant, normal}`, `mode ∈ {normal, gauntlet}`,
`gauntlet ∈ {Test1..Test5}` (required iff `mode == "gauntlet"`, forbidden
otherwise) and a bounded integer `live_pid` / positive `live_create_time`. It then
opens a **query-only** native handle to `live_pid` and requires the create time to
match and the image path to resolve inside the configured live install. The ticket
slot is reserved **atomically in one locked block before any preflight** (M-4), so
two concurrent `start` requests can never both be admitted and overwrite each
other; a refused request releases the reservation.

Only when the request is admissible, the live target is verified, the bounded
runtime/policy preflight passes (§4.5) **and the pre-acknowledgement gates pass**
(§6) does it return `practice_host_start_accepted` with a `ticket`; a second
`start` while a ticket is active returns `practice_host_ticket_active`. **No
process is launched here.** The menu may then quit the game through its own normal
quit path. If the preflight fails (missing Lua runtime, policy source or
canonicalizer) the host refuses with `practice_runtime_preflight_failed`, and if a
pre-acknowledgement gate fails (unconfigured match port, invalid certificate,
server adaptation, staged endpoints, ruleset digest) it refuses with that gate's
code — in both cases **before** the menu is told it may quit, so an unavailable
dependency is never discovered after the game has closed (M-3).

The host assumes the menu has already confirmed the *idle main menu* predicate:
the ordinary main menu may have the official socket connected, but there must be
no active lobby/run (`MP.LOBBY.code` nil/empty, no active game). The host never
requires or alters the official connection; it only records the exact live
PID/create time the menu supplied.

### 4.3 `poll`

`request` = `{ticket}`. Returns the live phase (`accepted`, `waiting_live_exit`,
`launching`, `running`, `ending`, `completed`, `failed`) and, on failure, a
compact error string. Unknown tickets return `practice_host_ticket_unknown`.

### 4.4 `status`

Returns the daemon id/session/port and the current ticket (or null). Read-only.

### 4.5 Runtime/policy preflight (before acknowledgement)

`runtime_preflight()` is a bounded, read-only check run before the host acknowledges
`quit`/`start` (in the daemon `start` op, and again in the supervisor gates). It
never launches a game, worker or server process. The production default
(`default_runtime_checker`) checks that the real policy source
(`AISparring/ai/baseline_policy.lua`), the canonicalizer sources (`codec.lua`,
`observation.lua`), the worker and `tools/lua/policy_env.lua` exist; that the
required Lua runtime (`luajit21`) imports and instantiates; that the baseline policy
source renders for every difficulty; and that the canonicalizer chunk loads. Any
failure returns `practice_runtime_preflight_failed` with bounded problems. The
checker is injectable (`runtime_checker=`) so fixtures never depend on `lupa`.

## 5. Closed-game transition

`MatchSupervisor.run()` (on a daemon worker thread):

1. **Wait for natural live exit.** `wait_for_live_exit()` polls a query-only native
   handle. It never calls a termination method. A PID reuse (same pid, different
   create time) is treated as the original having exited. On timeout it returns
   `practice_live_exit_timeout` and leaves the live process running. If identity
   cannot be confirmed it fails closed (`practice_live_exit_unverified`).
2. **Re-run every fail-closed gate** (§6). Any failure aborts before a launch.
3. **Open the persistent unmeasured record.** The host first runs quiescence, a
   fresh full byte backup, and the real `check_backup_evidence(backup_root, sources)`
   verifier (`prepare_live_baseline`). The only accepted `backup_id` is that
   verifier's **content-derived identity** (the manifest sha256 bound over every
   verified per-root `files_digest`); a runner label, `digest` alias or `id` is
   display/directory metadata and can never stand in for it, and the complete
   per-root evidence is preserved. The certificate's `prepare_session(...)` is then
   called with the real enumerator `closed_check`, that content identity and a
   `backup_verify` callable that **re-runs the real verifier** (fresh identity plus
   full `roots` evidence); it mints the single session nonce, binds its own
   before-snapshot to those root digests, and stores everything in an exclusive
   open record. The host requires the certificate's *returned* identity to equal
   the verifier identity and never overwrites it. Immediately after, and before *any* spawn, a
   persistent `session_unmeasured` host lockout is written. A prior unclosed
   record refuses the session (`practice_session_open_unmeasured`), and live drift
   or a missing root map is refused by the real verifier before preparation.
4. **Verified server before roles.** The server adaptation is verified, the server
   is spawned and its owning-PID loopback listener proven **before** the roles
   spawn (H3), so the MP client never starts against a missing server.
5. **Launch the two roles** with the trusted typed descriptors **and the prepared
   open record**: `execute_launch(..., open_session=<prepared record>,
   session_descriptors=...)` (the launcher reads the single nonce from the record;
   there is no `nonce_factory` and no spawn without an open record), bind their
   exact PIDs on the open record, then require a fresh nonce attestation from
   **both** roles.
6. **Mark attested, then publish.** Only after both probes pass does the host call
   the trusted `service.mark_attested(expected_config_digest)` and then the
   certificate's atomic `write_launcher_attestation` (§6.4), and immediately after
   the files are published it calls the trusted host-only
   `service.start_prestart_window()` so the bounded pre-start budget starts when the
   companions can actually read the attestation (a failure to call it is a no-op that
   leaves the earlier `mark_attested` clock in force, so the timeout is never
   bypassed).
7. **Supervise**, retain the human results window until it exits, then retire the
   server/service and record the measured per-session live diff (§8, §9).

## 6. Gates (all must pass before launch)

| Gate | Function | Failure code |
|---|---|---|
| policy source / canonicalizer / Lua runtime available | `runtime_preflight` | `practice_runtime_preflight_failed` |
| measurement API published (no fake fallback) | `measurement_api_problems` | `practice_measurement_api_missing` |
| host acknowledgement lockout clear | `read_host_lockout` | `practice_host_ack_required` |
| no prior open/unmeasured record | `isolation_certificate.list_open_records` | `practice_session_open_unmeasured` |
| live Balatro closed | `launch_practice.check_live_balatro_closed` | `practice_live_balatro_running` |
| no staging/live overlap | `staging.assert_no_overlap` | `staging_overlaps_live` |
| staged roles verified | `staging.verify_staged_role` | `practice_static_gates_failed` |
| Steam guard measured | `staging.check_steam_guard` | `practice_static_gates_failed` |
| **immutable two-layer certificate** | `isolation_certificate.check_certificate` | `practice_requires_isolation_certificate` |
| **quiescent fresh verified backup + exclusive open record** | `check_backup_evidence` (content `backup_id` + per-root `files_digest`) then `isolation_certificate.prepare_session` (+ real `closed_check`, `backup_verify`) | `practice_requires_fresh_backup_baseline` / `practice_requires_isolation_certificate` |
| **role-normalized Mods parity hash** | `certificate_content_hash` (`collect_layer_m`/`current mods role_parity_digest`) | `practice_requires_isolation_certificate` |
| **Major League config digest (derived only, no content-hash fallback)** | `ruleset_contract.expected_ruleset` / source-derived staged content digest | `practice_major_league_config_unproven` |
| server adaptation pin/hashes/lock/deps/node/built patch | `verify_server_adaptation` | `practice_server_adaptation_unproven` |
| fixed validated match port | `choose_match_port` | `practice_match_port_unavailable` / `..._unconfigured` |
| staged endpoints on that port | `staging.verify_staged_endpoints` | `practice_staged_endpoints_unproven` |
| descriptor env fully bound | `_descriptor_env_gap` | `practice_descriptor_env_unbound` |
| pre-acknowledgement gates (no game closed needed) | `default_start_gate` | `practice_match_port_unconfigured` / `practice_requires_isolation_certificate` / `practice_server_adaptation_unproven` / `practice_staged_endpoints_unproven` / `practice_major_league_config_unproven` |

Every check that does not need the user's game closed runs **before** the `start`
acknowledgement (M-3): the fixed match port must be configured, the measurement API
and certificate must be valid, the server adaptation must be proven, the staged
endpoints must exist, the certificate's role-parity Mods digest must be available
and the Major League ruleset digest must be derivable. A
failure here refuses the acknowledgement (`HostDaemon._op_start` → `default_start_gate`)
so the user never quits Balatro only to watch the session fail after launch. The
`serve` subcommand also refuses to start without `--match-port`. The exclusive open
record is written only after these checks, so a refusal can never strand an open
record (H-A).

### 6.1 The certificate is immutable and never rebased

Real practice reuses the historical two-layer certificate built by
`tools/isolation_certificate.py`. `certificate_gate()` only re-checks the bound
layers, the bound tools, the explicit live-roots map and the persistent lockout;
it **never** rewrites, rebases or re-records evidence and never compares live
*contents* (that is the per-session job in §9). There is deliberately no
`rebase_isolation_proof`/`record_isolation_proof` path in this host. The
**static** code/path proof (manifests, guards, overlap, no native Steam DLLs) and
the **fresh per-session backup baseline** are tracked separately and are not
substitutes for the certificate.

### 6.2 Fixed port, no endpoint rewrite

The host refuses to rewrite a role's staged `.env`/`config.lua` fallback. The
fixed, pre-validated match port must already be configured and must match the
certificate's bound endpoint (`verify_staged_endpoints` + `check_certificate`
port), so an ordinary match never invalidates the certificate.

### 6.3 No arbitrary boolean proof

Every gate value is a measured digest/flag produced by the certificate or staging
code (`check_certificate`, `collect_role_probes`, `verify_staged_role`,
`verify_server_adaptation`). A bare hand-written boolean is never accepted.

### 6.4 Both roles must attest before match authority

After the roles are spawned, the host binds their exact PIDs on the open record
(`bind_open_session`) and `wait_for_attestation()` requires each role's nonce-bound
startup probes (`staging.collect_role_probes` with `require_mp=True` and the fixed
port): the session nonce, the correct save directory, a Lovely Mods directory
inside the role root, `steam=nil` and the loopback endpoint, all bounded by the
separate `prestart_timeout`.

Only after **both** probes pass does the host call
`service.mark_attested(expected_config_digest)` (M8: the service refuses a
mismatched digest and is the trusted gate too), and then the certificate's
`isolation_certificate.write_launcher_attestation(session_id, nonce,
control_port=service.port, port=match_port)` writes the fixed session-bound file.
There is **no** host-side attestation writer: the certificate writer re-verifies
the open record, the owned PIDs and both roles' fresh probes before writing
atomically, and passes the control port (`service.port`) and the match port
separately (H1). It carries `expected_role_save_root`/`expected_role_mods_root`
(the frozen schema) and no credential. The companion derives the same path from
its validated descriptor; until the file matches, it keeps staged bootstrap in a
bounded pending state and does not mark boot failed. The secret gauntlet seed is
delivered only through the authenticated service `setup` op to the human role —
never through policy, and never to the AI role.

### 6.5 Expected Major League configuration is derived, never assumed (M10)

`ruleset_contract.expected_ruleset(staging_root)` strictly parses the pinned staged
`rulesets/majorleague.lua` (rejecting any statement that is not an
`MP.LOBBY.config.<key> = <primitive>` assignment or a trailing `return`), derives
the registry ruleset id and forced gamemode, and computes the expected digest with
the shared `practice_service.major_league_digest` (FNV1a-32 per
`docs/MAJOR_LEAGUE_DIGEST.md`). The digest, ruleset id, gamemode and forced-option
mapping are passed into `ServiceConfig`; the service requires that exact
`expected_config_digest` before `mark_attested`. That digest is mandatory and
fail-closed: `_evaluate_gates` refuses a missing/malformed value
(`practice_major_league_config_unproven`) and `_launch_and_supervise` validates it
again **before** the control service starts or any role spawns. It is **never**
permitted to fall back to the role-parity `content_hash` (a different quantity).
The descriptors' `content_hash` is the certificate's role-normalized Mods parity
digest, not a locally hashed tree.

## 7. Server, service and roles

- **Server adaptation.** `verify_server_adaptation()` binds
  `AISparring-adaptation.json` to the trusted `SERVER_PIN`, the exact two
  `changes`, every recorded source/build hash (recomputed), the resolved Node
  executable path and hash, the package lock, the complete dependency hash manifest
  (`runtime_files`, including native binaries), each declared runtime dependency
  (`dependency_hashes`, recomputed from the tree) and the native `*.node` set
  (`native_files`, which must be a subset of `runtime_files` and match disk), the
  patched `src/main.ts` (loopback `server.listen(PORT, '127.0.0.1', ...)`, admin
  listener disabled), and the built `dist/main.js` — which must be present in
  `built_files` and itself carry the loopback bind and no `adminServer.listen` (M3).
  The pinned `dist/main.js` is what Node runs. `tools/prepare_server.py` produces
  exactly this manifest: it copies **tracked source only**, and copies the reviewed
  (gitignored) dependency install tree wholesale, so the compiler and native
  binaries survive; it never writes the upstream tree.
- **Server process.** `default_server_runner()` launches the **verified absolute
  Node path** that `verify_server_adaptation` hashed (never a bare `node` resolved
  by PATH; `_verified_node_path` has no `which` fallback and fails closed) with the
  roles' exact retained-ownership sequence (M-1): on Windows the
  server is created `CREATE_SUSPENDED`, assigned to a **mandatory** kill-on-close
  Job Object, resumed, and its create time is read from the retained handle. Its
  image path is re-read through a separate query handle and must equal the launched
  executable. A missing job, create time or mismatched image terminates the exact
  child and fails closed. `cwd` is the private per-session data directory;
  `LOG_HASH_DB_PATH` is forced to the **per-session** `workspace.server_dir` (M-5)
  so the persistent SQLite ban/rate store can never ban `127.0.0.1` across
  sessions. The environment is an allowlist that strips `AISP_*`, `STEAM*`, `SDL*`,
  `LOVELY*` and `PYTHON*`.
- **Listener proof.** `verify_local_listener()` uses the Windows TCP table for
  **both** IPv4 and IPv6 (`WindowsTcpTableProbe`), else a loopback-connect probe.
  Every bound address must be an exact loopback address (`127.0.0.0/8` or `::1`);
  a wildcard/LAN address is refused. When the owned server PID is known the
  owning-PID set must be **exactly** `{server PID}` across both families (M-2), so
  a foreign loopback listener squatting beside Node cannot pass. The admin port must
  be closed on both
  families. `WindowsTcpTableProbe` reports a per-family inventory status and strict
  proof **refuses a partial inventory** (`match_listener_inventory_incomplete` /
  `admin_listener_inventory_incomplete`): if either family's native table query is
  unavailable, the remaining family's data is not accepted as complete, so a
  wildcard or other-family listener cannot slip through. `port_is_free`/
  `pick_free_port` use exclusive Windows sockets and never `SO_REUSEADDR` (M2).
  The native table rows are read from their raw Win32 field bytes (IPv4 `DWORD`
  network-order address bytes and the IPv6 16-byte `ucLocalAddr` at its declared
  offset), never by taking a `byref` of a scalar field.
- **Control service.** A `practice_service.PracticeService` is constructed from
  trusted config + the request enums and started on an ephemeral loopback port.
  Its lifecycle state is read in-process through the real, locked
  `started`/`ended`/`aborted`/`terminal_phase`/`terminal_reason` properties, never
  over the wire and never through a caller-invented attribute: a network heartbeat
  would have to share a role's strictly-increasing sequence counter with the real
  role runtime. The supervisor treats a terminal phase as a normal completion
  **only** when `terminal_reason == "human_end"`; a role loss, pre-start timeout or
  abort is a failure even though its phase reads `closed` (H-C). The staged human
  window exiting is likewise a completion **only** when the service's real
  `terminal_reason` is `human_end`; an unexpected mid-match human exit fails with
  `practice_human_exited_before_end` and runs the measured failure cleanup (N-1).
  The host calls the
  trusted `service.abort(code)` on any failure or void so both roles see
  `practice_aborted` and can stop through their normal MP flow. The secret
  gauntlet seed is served by the authenticated `setup` op to the human role only.
- **Roles.** `_build_descriptors()` builds one typed
  `launch_practice.SessionDescriptor` per role and passes them, together with the
  certificate's prepared open record, to
  `launch_practice.execute_launch(..., open_session=<record>, session_descriptors=...)`,
  which returns the **retained** `LaunchSession` (exact Popen handles + kill-on-close
  Jobs). The record's `phase` must be `MATCH`; a missing/closed record makes the
  launcher refuse (`open_session_required`) instead of spawning. Old
  launcher-attestation files are rotated before the spawn and fresh ones are
  written only after both roles attest (§6.4).

## 8. Teardown, void and lockout

On peer/server/service failure the supervisor first calls the trusted in-process
`service.abort(code)` (so the peer sees `practice_aborted` and can stop through
its normal MP flow), then terminates only the exact owned handles
(`OwnedProcess.terminate` for the server and each staged role, then
`LaunchSession.close`), preserving logs.

If a **new live Balatro process appears during practice**, the supervisor calls
`service.abort`, terminates owned handles, marks the session **void**, closes the
open record as a measured **failure** through
`isolation_certificate.record_session_failure(session_id, reason=<code>)` (which
raises the certificate's persistent lockout), and writes its own persistent host
acknowledgement lockout (`work/aisparring-host/host_lockout.json`) (H-B). The next
`start` is refused with `practice_host_ack_required` until the user sends the
`acknowledge` op, which clears both lockouts (`acknowledge_lockout` leaves an
append-only acknowledgement); the live game itself is never touched. A void can
therefore always be recovered from, and nothing is silently re-baselined.

On normal completion the supervisor retires the **AI** role after the service's
bounded AI-receipt grace, but keeps the owned loopback server and the service
(status/end) running so the human's MP client never loses its server on the
game-over screen, and **leaves the human staged window visible** until the user
closes it. There is **no 120-second deadline**: the supervisor waits for the human
window to exit normally, continuing to poll for a newly opened live Balatro
process. If a live game appears while the human window is retained, the session is
voided and the acknowledgement lockout is written. Only after the human exits does
it retire the server/service and take the measured after-diff. The live process is
never in any cleanup set.

A new `start` ticket is refused while a retained human window is still running
(`practice_human_window_active`); a new ticket never terminates a retained human
window. The daemon's `stop()` **defers** while that window is active (the staged
human is owned through a kill-on-close Job Object, so exiting the daemon would
kill it); the CLI keeps the daemon alive until the human exits. A non-forced
`stop()` **also defers** while a match supervisor still owns its lifecycle - its
worker may be assigned-but-not-yet-started or still running - refusing
`practice_supervisor_active` (`stopped: false`) without cleaning up the
supervisor, discarding its ticket or closing the loopback server/Job. The worker
check and the ticket removal share the daemon lock, so a worker assigned by a
concurrent `start` can never slip past the guard; a later `stop()` after the
worker exits succeeds. The explicit `stop(force=True)` is unchanged.

### 8.1 A prior open/unmeasured record blocks the next session

Any exit after the open record exists closes the owned processes (except a
retained human), rechecks that live is actually closed, and asks the certificate
for the measured after-verdict. If the record has **no bound owned PIDs** (a
failure before any role spawned), the certificate's measured
`record_session_no_spawn` closure is used instead, so a pre-spawn failure cannot
strand an open record that nothing in the product can close (H-A). If the
after-diff cannot be measured — a live game is open, or the verdict is refused for
any reason other than a real byte diff — the owned session is closed and its
retained handles must prove exit before the record is closed as a measured
**failure** through
`record_session_failure(session_id, reason=<code>)`, which raises the certificate's
persistent lockout (H-A-1); the host's `session_unmeasured` lockout stands. If
`close`/the owned-handle query fails, or an owned handle still runs, ownership is
retained and the record is deliberately left open — a refused closure never
falsely closes a record while an owned process remains, and a delayed (but proven)
exit still completes the same closure. The
next `start` is refused (`practice_host_ack_required` /
`practice_session_open_unmeasured`) and the `acknowledge` op is refused until that
explicit closure exists; once the record is closed as failed, `acknowledge` clears
both lockouts so a stuck session is always recoverable without hand-editing
evidence. A pre-launch live reappearance takes the same reviewed void/failure
path. Only a real `live_byte_diff_revoked` verdict raises the byte-diff lockout;
any other refusal closes as failed with `session_unmeasured`. When the certificate
has itself already closed the record as `failed` for a measured byte diff, the host
clears `_record_started` and retires the handles through the same refused-closure
path: it never asks for a second verdict or calls `record_session_failure` again
(which would only return `session_already_closed`/`open_session_missing` and wedge a
permanent pending closure). The byte-diff lockout set by the measured verdict is
kept (H-A-1-R2). A failed session can therefore never silently re-baseline the next
one (C1).

A closure that cannot yet be **retired or persisted** (a stuck owned handle, or a
`record_session_failure` that raised/refused) is remembered as a **pending closure**
on the supervisor. Once the supervisor thread has finished, the public `acknowledge`
and `start` ops first call the supervisor's `retry_pending_closure()`, which
re-proves the owned-handle exit, persists the failure closure, rewrites the session
report and clears the pending state. A delayed but proven exit therefore always
completes the *same* closure through the public API, with no hand edit and no
fabricated success; a still-stuck handle or still-failing persistence returns
`False` and leaves the record/handles exactly as they were. `acknowledge` and
`start` therefore refuse (`practice_host_closure_pending`) when that retry cannot
complete, instead of clearing the lockout or reaching `cleanup()` and dropping the
kept handles. `retry_pending_closure()` is serialized by a supervisor lock, so two
concurrent authenticated requests persist the closure exactly once (never duplicate
receipts). A non-forced daemon
`stop()` also retries first and refuses (`practice_host_closure_pending`,
`stopped: false`) while a closure is still pending, so it never reaches `cleanup()`
and drops the handles that are the only proof of exit (H-A-1-R). Its non-forced
order is: pending-closure retry, then retained human
(`practice_human_window_active`), then an active match-supervisor worker
(`practice_supervisor_active`).

## 9. Session report and per-session live diff

Each session writes `work/aisparring-host/sessions/<session_id>/host.json` with the
schema/version, phase/code, compact error, ports, workspace/log paths, a bounded
log index, the live-exit verdict, certificate/backup ids, the derived Major League
`config_digest`, the open-record path, the after-digest, the attestation result,
the gate summary and the exact role records. **No credential, session secret or
policy source is written.**

After the human window has exited (and only then, with live actually closed), the
supervisor calls `isolation_certificate.record_session_verdict(staging_root,
session_id=..., live=..., session=<retained LaunchSession>, live_closed=<enumerator
check>, backup_id=..., certificate_id=...)`. When no role ever spawned, it calls
`record_session_no_spawn(staging_root, session_id=..., live=..., backup_id=...)`
instead (H-A). The certificate takes and binds the `after`-snapshot itself,
requires every owned handle stopped and the user's game closed
(`session_closure_unproven` otherwise) — the host never passes caller
snapshots or a `closed_check` boolean. Any live byte difference revokes the
certificate generation, writes the append-only receipt and the persistent lockout
plus the diff, and the host adds its own acknowledgement lockout. A refusal for any
other reason (`session_closure_unproven`, `live_verdict_failed`, or a live game
open at the measured check) closes the record as a measured **failure** through
`record_session_failure` — but only once the owned handles are proven exited;
otherwise ownership is retained and the record stays open, so the daemon is never
wedged by a false closure (H-A-1). Only a measured
passed verdict clears the `session_unmeasured` lockout. The host **never**
auto-restores live from a backup: that is itself a live write and requires
explicit user approval.

When the open record exists (`_record_started`) the retained session is deliberately
**not** dropped before the verdict: the human-window teardown retires the
server/service/roles but keeps `session` so `record_session_verdict` can measure the
exact owned handles. This is what makes a genuine `human_end` with the human window
already closed (or `leave_human_visible=False`) pass instead of failing with
`session_closure_unproven`, and it also stops a failure closure being written while
an owned process may still run. Only **after** a passed verdict does the host call
`_retire_session()` to drop ownership; if that cannot be proven, it is kept as a
pending closure (H-A-1-R/N-1-R).

## 10. CLI and developer launcher

```
python tools/practice_host.py serve --staging-root staging --backup-root backups \
  --install "<install>" --appdata "<live AppData>\Balatro" --steam-root "<Steam>" \
  --server-root work/local-server --match-port 8788
python tools/practice_host.py status
python tools/practice_host.py dev-launcher
```

`serve` runs the daemon until interrupted and keeps it alive for repeated
sessions/cleanup. It refuses to start when no fixed `--match-port` is configured
(`practice_match_port_unconfigured`), so a daemon whose every acknowledgement would
fail after the user quit is never started (M-3). `dev-launcher` writes
`start_practice_host.cmd` / `.ps1` under
the repository `work/` tree only — **no registry entries, services or scheduled
tasks**. The user starts the host before opening ordinary Balatro.

## 11. Launcher extension (`tools/launch_practice.py`)

Minimal, typed addition: `SessionDescriptor` plus `session_env_overrides`,
`session_descriptor_problems`, `session_env_collisions` and the
`session_descriptors=` parameter on `_spawn_verified`/`execute_launch`. The
descriptor is a typed value, never an arbitrary environment dict; a plain dict, a
missing descriptor or a bad value aborts with a bounded code before any spawn.
Exactly these allowlisted keys reach the child:

`AISP_SESSION_ID`, `AISP_ROLE_CREDENTIAL`, `AISP_CONTROL_PORT`,
`AISP_CONTENT_HASH`, `AISP_PROBE_NONCE`, `AISP_EXPECTED_ROLE_SAVE_ROOT`,
`AISP_EXPECTED_ROLE_MODS_ROOT`, `AISP_MODE`, `AISP_DIFFICULTY`, `AISP_PACING`,
`AISP_GAUNTLET`.

The probe nonce must equal the launcher's session nonce; the expected save and
Mods roots must equal the role's staged directories; and mode/difficulty/pacing/
gauntlet must be exact trusted enums (gauntlet empty unless mode is `gauntlet`).
Pinned paths, `LOVELY_MOD_DIR`, Steam and the isolation-proof state cannot be
overridden. The returned `LaunchSession` is unchanged and still retains the exact
handles.

The certificate's bound descriptor surface (`staging.SESSION_DESCRIPTOR_VARS`,
owned by the staging worker) lists all eleven names, so layer N covers the whole
descriptor. The host still records `descriptor_env_unbound` in every report as a
drift alarm: if a future name is emitted but not bound, it surfaces instead of
being silently uncovered.

## 12. Tests

`python tests/test_practice_host.py` runs the real module against synthetic temp
trees and injected fakes (with `work/runtime-venv/Scripts/python.exe`);
`python tests/test_prepare_server.py` covers the source/dependency copy and
manifest binding with an injected git provider and builder (no real git/node/npm);
`python tests/test_ruleset_contract.py` covers the strict Major League derivation
(M10). Together they assert:

- daemon auth/shape/op rejection, enum and live-PID validation, exact live
  identity checks, ack-only-when-recorded, duplicate-ticket refusal and the
  acknowledgement lockout (`acknowledge`); a prior open/unmeasured record refuses
  both `start` and `acknowledge`, and a retained human window refuses a new ticket
  and defers the daemon `stop()`;
- discovery duplicate/stale/foreign handling and a real loopback socket round trip;
- live-exit wait timeout (asserting `terminate` is never called), absence and PID
  reuse detection, and fail-closed unverified enumeration;
- certificate reuse/lockout/missing-api, the absence of any rebase/record-proof
  path and any unchecked host attestation writer (the host delegates to the
  certificate writer with separate `control_port`/`port`), quiescence, the real
  backup content-identity requirement and two-role nonce attestation;
- the backup contract through the **real** `check_backup_evidence` on synthetic
  backup trees (created with the real `create_live_backup`): the baseline id is the
  verifier content identity (never the runner label), the verified per-root
  evidence is preserved, live drift and a missing root map are refused before any
  preparation, and the **real** `prepare_session` binds its open record to that
  identity and root digests while keeping the label as display metadata only (the
  supervisor never overwrites the certificate's returned identity);
- the required Major League `config_digest` is fail-closed: a missing/malformed
  digest refuses before the control service starts or any role spawns, with no
  content-hash fallback;
- server adaptation pin/hash/bind/admin, package-lock and runtime-dependency
  binding, the full `runtime_files` dependency manifest, `dependency_hashes` and the
  declared `native_files` set, the built `dist/main.js` patch and `built_files`
  membership, the resolved Node hash, and manifest/root path confinement;
- prepare_server copies the gitignored dependency install tree (compiler + native
  binaries) despite not being git-tracked, filters source by git-tracking only, and
  writes a manifest that the real `verify_server_adaptation` accepts;
- the bounded runtime/policy preflight is injectable and fail-closed, refuses a
  daemon `start` before acknowledgement when the Lua runtime/policy source is
  unavailable, and the default launch runner passes the prepared open record (never
  a `nonce_factory`); the real certificate closure API (`session=`, `live_closed=`)
  is exercised against a real open record, not just a fake signature;
- listener loopback-only (IPv4 **and** IPv6) / owning-PID / admin-closed
  enforcement, partial-family inventory refusal (`WindowsTcpTableProbe` per-family
  status, including an admin family whose query is unavailable), non-strict
  retention of the historical result, exclusive port probing and fixed-port policy;

Separately, `tests/astra_listener_native.py` (owned and run by root, not part of
this fixture suite) is an independent Windows-only checker that queries the real
TCP table for this process's own ephemeral `127.0.0.1` and `::1` listeners and
exact PID, then closes them. It is a native OS-socket proof; it does not start
Balatro and is not game/review acceptance.
- typed descriptor construction (all keys + roots + enums), the derived Major
  League digest passed into `ServiceConfig`, certificate-parity content hashing,
  `mark_attested` strictly after both probes and before the attestation files,
  server-before-roles ordering, descriptor-env-gap refusal, fail-closed-before-
  launch, attestation failure, the human-retention / no-deadline honesty, the
  unmeasured-failure **failure closure and persistent lockout** that is never
  silently re-baselined (and is cleared only by an explicit `acknowledge`), a real
  certificate `session_closure_unproven` followed by a successful `acknowledge`, a
  pre-launch live reappearance that closes the never-spawned record as failed and
  then recovers through `acknowledge`, a failed `Job.close` with a still-running
  owned human (ownership retained, no failure closure, record stays open), a
  delayed-but-proven owned exit that still completes the failure closure and
  `acknowledge`, a persistence exception/refusal that leaves `_record_started`
  set, an unexpected human exit (failure) versus a
  service-authoritative `human_end` (completion), a real-certificate `human_end` with
  the human window already exited (record `closed`, no lockouts) and its stuck-AI
  variant (ownership retained, record stays open, no failure stamp), the public
  `acknowledge` and `start` ops driving the pending-closure retry after both a stuck
  owned handle and a one-shot persistence failure (and never retrying a still-running
  supervisor thread), a non-forced `stop()` refusing with
  `practice_host_closure_pending` and deferring (`practice_supervisor_active`) for an
  active or assigned-but-unstarted supervisor worker while still retiring once it
  exits (plus the retained-human-with-worker and forced-stop variants),
  live-game-appears void + lockout, a
  real-certificate live byte diff (record `failed` + byte-diff lockout, no pending
  closure, and a public `stop()` that actually stops), `acknowledge`/`start`
  refusing with `practice_host_closure_pending` while a retry still cannot close
  without dropping the kept handles, concurrent pending-closure retries persisting
  exactly once, listener-failure cleanup (roles never spawned) and
  launch-failure cleanup, and the reserved-ticket release when the supervisor
  factory raises;
- server environment allowlisting (SQLite path stays in the repo) and developer
  launcher output confinement.

`tests/test_launcher_safety.py` adds the descriptor env allowlist (all keys),
typed-only requirement, nonce/save-root/Mods-root/enum rejection and per-role
requirement, without weakening the existing launcher cases. No test starts
Balatro, touches a live path or contacts an external network.

## 13. Explicitly not implemented here

- No game launch, live-process termination, live copy or live write.
- No concurrent-live mode and no live Multiplayer redirect.
- No server adjudication change; only the reviewed loopback/admin adaptation.
- No policy strategy; the control service and `policy_worker` remain the boundary.
- No registry/service/task installation; developer scripts only.
- No certificate rebase, re-record or live-content comparison: the immutable
  certificate is only re-checked.
- No staged-data refresh: the host performs none. Any refresh is the certificate/
  staging owner's path and is allowed only from the fresh *verified* backup, for
  allowlisted profile-unlock files, and never from live Mod config/`.env`.
- No live auto-restore after a diff: revocation + lockout + saved diff only, with
  explicit user approval required for any restore.
- The runtime worker must still gate its own `hello`/`ready`/`start` on the same
  nonce attestation; the host enforces it before server start/match authority.

## 14. API deltas and remaining dependencies (for root reconciliation)

This host slice assumes the certificate/launcher worker's
`work/measurement-interface.txt` API. It fails closed
(`practice_measurement_api_missing`) rather than substituting a fake fallback if
any method is absent. The exact surface it calls:

- `isolation_certificate.check_certificate(staging_root, live=, port=)` and
  `lockout(staging_root)` / `acknowledge_lockout(staging_root, operator=, reason=)`;
- `launch_practice.check_backup_evidence(backup_root, sources=)` (owned by the
  launcher/backup worker): returns `ok`, `backup_id` (content-derived, 64-hex),
  `backup_label` (display only), `manifest_sha256` and
  `roots[key] = {source_root, files_digest, entry_manifest_sha256, file_count}`.
  The host treats `backup_id` as the only backup identity, preserves the full
  `roots` evidence, and passes both to `prepare_session`; it never substitutes a
  runner label, `digest` alias or `id`;
- `isolation_certificate.prepare_session(staging_root, live=, session_id=, port=,
  closed_check=, backup_id=, backup_verify=, phase=MATCH)` — returns `nonce`,
  `certificate_id`, `backup_id` (the evidence id it authenticated), `backup_label`,
  `open_record` **and the open record mapping** (`record`). The host passes the
  verifier content id and a `backup_verify` that re-runs the real verifier (fresh
  identity plus `roots` evidence), requires the returned `backup_id` to equal that
  verifier identity and never overwrites it. If the worker adds a `backup_root`
  keyword the host passes `config.backup_root` automatically (signature-detected);
  `backup_verify` is always passed; and the returned `record` mapping is what the
  host forwards to `execute_launch(open_session=...)`;
- `isolation_certificate.list_open_records(staging_root)`,
  `bind_open_session(staging_root, session_id, pids=, spawn_time=)`,
  `record_session_verdict(staging_root, session_id=, live=, **session=<retained
  LaunchSession>**, **live_closed=<enumerator check>**, backup_id=,
  certificate_id=)`, `record_session_failure(staging_root, session_id=, reason=)`,
  `record_session_no_spawn(staging_root, session_id=, live=, backup_id=)`. All of
  these (including `record_session_no_spawn`) are required
  `_MEASUREMENT_API_METHODS` members, so a missing/renamed closure method refuses
  the session before the open record is written instead of degrading to a wedge;
- `isolation_certificate.write_launcher_attestation(staging_root, session_id=,
  nonce=, control_port=, port=)`;
- `isolation_certificate.collect_layer_m(staging_root)` (or
  `certificate_or_empty(...)`) for the role-normalized Mods parity digest used as
  both descriptors' `content_hash`.

Launcher deltas the host now follows (see `docs/RUNTIME_LAUNCHER.md` §15):
`execute_launch(..., open_session=<prepared record>, session_descriptors=...)` with
no `nonce_factory`; the prepared record's `phase` must be `MATCH`. The host's
default launch runner passes the real prepared record and refuses
(`open_session_required`) without it.

Service deltas this host depends on (already present in `practice_service.py`):
`ServiceConfig.expected_config_digest` is required, `PracticeService.mark_attested(
expected_config_digest)` is a trusted host-only gate, and the human-coordinator
terminal lifecycle (`terminal_phase`, `terminal_summary`, `ai_receipt_grace`)
provides the bounded AI receipt wait.

Remaining dependencies / honest gaps:

1. **No certificate exists yet** (no P1a/P1b/full-P1/crash/P2 evidence). With no
   certificate, `check_certificate` fails and real sessions refuse — correct, not
   a fallback.
2. **The prepared server is owned by root, not this worker.** `verify_server_adaptation`
   requires the resolved Node executable/hash, the full `runtime_files` dependency
   hash manifest, `dependency_hashes` for each declared runtime dependency, the
   `native_files` set and the built `dist/main.js` loopback/admin patch. Root has
   already run the real isolated build with `tools/prepare_server.py` (tracked
   source only plus the reviewed gitignored dependency install tree wholesale,
   including `typescript/bin/tsc` and native binaries), confirmed the resulting
   manifest passes `verify_server_adaptation`, and moved the verified build to the
   default `work/local-server` (`work/local-server-before-runtime-manifest` keeps
   the prior one), so the default `HostConfig` no longer needs a rebuild. This
   worker still does not run the build; root owns every real build and TCP test.
   That is a build/verification result and is **not** game, launcher or Claude
   review acceptance.
3. The real Windows IPv4+IPv6 TCP-table probe has an independent native checker
   (`tests/astra_listener_native.py`, run by root with the venv) that exercises the
   OS socket inventory against only its own ephemeral `127.0.0.1`/`::1` sockets and
   exact PID, then closes them. Passing it is an OS-socket-level result, **not**
   Balatro engine isolation, and is **not** review acceptance. Root also verified
   the native PowerShell enumerator against the checking process's own PID,
   actual executable and creation-time record. The pinned MP client's retry
   behaviour remains an actual-engine gate.
4. The companion's own env/attestation-path behaviour (H2) is owned by the
   companion worker; this host consumes the frozen `expected_role_*` schema and
   fixed path only.
5. Root ran `tests/astra_attestation_contract.py`: the actual certificate writer
   produces files consumed by the Lua companion reader for both roles and both
   runtimes. Matching records pass; changed nonces fail (eight checks). These
   are synthetic certificate fixtures, not native Balatro attestation evidence.
6. **The backup/session identity contract is owned by the isolation/launcher
   worker.** This host consumes `check_backup_evidence` → `backup_id`
   (content-derived), `backup_label`, `manifest_sha256` and
   `roots[key] = {source_root, files_digest, entry_manifest_sha256, file_count}`,
   and relies on `prepare_session` binding its before-snapshot to those root
   digests and returning the authenticated `backup_id`. At the time of this
   repair, root's `tests/astra_backup_session_contracts.py` was failing on an
   in-progress `staging._digest` reference inside that worker; it now passes
   against the landed API (verified independently by this worker). If those
   fields are renamed or reshaped, the host fails closed
   (`practice_requires_fresh_backup_baseline`) rather than substituting a label or
   `digest` alias; it never edits the isolation-owned files.
