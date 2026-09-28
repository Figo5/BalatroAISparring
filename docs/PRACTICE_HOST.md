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

`discovery_state()` classifies an existing marker as `live` (refused with
`practice_host_already_running`), `stale` / `stale_pid_reused` (replaced explicitly,
`stale_replaced: true`), `foreign` (wrong schema or module hash; refused, never
clobbered) or `unverified` (identity could not be confirmed; refused). The secret
is only in this private file and is never logged or returned in a response.

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
major_league}`, `pacing ∈ {instant, normal}`, `mode ∈ {normal, gauntlet}`,
`gauntlet ∈ {Test1..Test5}` (required iff `mode == "gauntlet"`, forbidden
otherwise) and a bounded integer `live_pid` / positive `live_create_time`. It then
opens a **query-only** native handle to `live_pid` and requires the create time to
match and the image path to resolve inside the configured live install.

Only when the request is admissible, the live target is verified **and the bounded
runtime/policy preflight passes** (§4.5) does it return
`practice_host_start_accepted` with a `ticket`; a second `start` while a ticket is
active returns `practice_host_ticket_active`. **No process is launched here.** The
menu may then quit the game through its own normal quit path. If the preflight
fails (missing Lua runtime, policy source or canonicalizer) the host refuses with
`practice_runtime_preflight_failed` **before** the menu is told it may quit, so an
unavailable interpreter is never discovered after the game has closed.

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
3. **Open the persistent unmeasured record.** The certificate's
   `prepare_session(...)` is called with the real enumerator `closed_check`, the
   fresh backup id and a `backup_verify` callable; it mints the single session
   nonce and stores the before-snapshot in an exclusive open record. Immediately
   after, and before *any* spawn, a persistent `session_unmeasured` host lockout is
   written. A prior unclosed record refuses the session (`practice_session_open_unmeasured`).
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
   certificate's atomic `write_launcher_attestation` (§6.4).
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
| **quiescent fresh verified backup + exclusive open record** | `isolation_certificate.prepare_session` (+ real `closed_check`) | `practice_requires_isolation_certificate` |
| **role-normalized Mods parity hash** | `certificate_content_hash` (`collect_layer_m`/`current mods role_parity_digest`) | `practice_requires_isolation_certificate` |
| **Major League config digest** | `ruleset_contract.expected_ruleset` | `practice_major_league_config_unproven` |
| server adaptation pin/hashes/lock/deps/node/built patch | `verify_server_adaptation` | `practice_server_adaptation_unproven` |
| fixed validated match port | `choose_match_port` | `practice_match_port_unavailable` / `..._unconfigured` |
| staged endpoints on that port | `staging.verify_staged_endpoints` | `practice_staged_endpoints_unproven` |
| descriptor env fully bound | `_descriptor_env_gap` | `practice_descriptor_env_unbound` |

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
`expected_config_digest` before `mark_attested`. The descriptors' `content_hash`
is the certificate's role-normalized Mods parity digest, not a locally hashed
tree.

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
- **Server process.** `default_server_runner()` spawns the exact Node command with
  a Windows kill-on-close Job Object and a retained `OwnedProcess` handle. `cwd`
  is the private per-session data directory; `LOG_HASH_DB_PATH` is forced to a
  repository path so the SQLite store stays in the repo. The environment is an
  allowlist that strips `AISP_*`, `STEAM*`, `SDL*`, `LOVELY*` and `PYTHON*`.
- **Listener proof.** `verify_local_listener()` uses the Windows TCP table for
  **both** IPv4 and IPv6 (`WindowsTcpTableProbe`), else a loopback-connect probe.
  Every bound address must be an exact loopback address (`127.0.0.0/8` or `::1`);
  a wildcard/LAN address is refused. When the owned server PID is known the
  owning-PID set must include it (`practice_listener_owner_unproven`), so a foreign
  process squatting the port cannot pass. The admin port must be closed on both
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
  Its heartbeat/abort state is read in-process (`started`/`ended`/`aborted`),
  never over the wire: a network heartbeat would have to share a role's
  strictly-increasing sequence counter with the real role runtime. The host calls
  the trusted `service.abort(code)` on any failure or void so both roles see
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
`service.abort`, terminates owned handles, marks the session **void** and writes a
persistent host acknowledgement lockout
(`work/aisparring-host/host_lockout.json`). The next `start` is refused with
`practice_host_ack_required` until the user sends the `acknowledge` op; the live
game itself is never touched.

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
kill it); the CLI keeps the daemon alive until the human exits.

### 8.1 A prior open/unmeasured record blocks the next session

Any exit after the open record exists closes the owned processes (except a
retained human), rechecks that live is actually closed, and asks the certificate
for the measured after-verdict. If the after-diff cannot be measured (a live game
is open, or the verdict errors), the open record **and** the `session_unmeasured`
host lockout are retained; a new ticket (`practice_session_open_unmeasured`) and an
`acknowledge` are both refused until a measured closure exists. A failed session
can therefore never silently re-baseline the next one (C1).

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
check>, backup_id=..., certificate_id=...)`. The certificate takes and binds the
`after`-snapshot itself, requires every owned handle stopped and the user's game
closed (`session_closure_unproven` otherwise) — the host never passes caller
snapshots or a `closed_check` boolean. Any live byte difference revokes the
certificate generation, writes the append-only receipt and the persistent lockout
plus the diff, and the host adds its own acknowledgement lockout. Only a measured
passed verdict clears the `session_unmeasured` lockout. The host **never**
auto-restores live from a backup: that is itself a live write and requires
explicit user approval.

## 10. CLI and developer launcher

```
python tools/practice_host.py serve --staging-root staging --backup-root backups \
  --install "<install>" --appdata "<live AppData>\Balatro" --steam-root "<Steam>" \
  --server-root work/local-server --match-port 8788
python tools/practice_host.py status
python tools/practice_host.py dev-launcher
```

`serve` runs the daemon until interrupted and keeps it alive for repeated
sessions/cleanup. `dev-launcher` writes `start_practice_host.cmd` / `.ps1` under
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
  backup-id requirement and two-role nonce attestation;
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
  unmeasured-failure lockout that is never silently re-baselined (and is cleared
  only on a measured pass), live-game-appears void + lockout, live-diff
  revocation lockout, listener-failure cleanup (roles never spawned) and
  launch-failure cleanup;
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
- `isolation_certificate.prepare_session(staging_root, live=, session_id=, port=,
  closed_check=, backup_id=, backup_verify=, phase=MATCH)` — returns `nonce`,
  `certificate_id`, `backup_id`, `open_record` **and the open record mapping**
  (`record`). The host passes that mapping to `execute_launch(open_session=...)`. If
  the worker adds a `backup_root` keyword the host passes `config.backup_root`
  automatically (signature-detected); otherwise `backup_verify` (a callable
  re-running the fresh-backup check) is always passed;
- `isolation_certificate.list_open_records(staging_root)`,
  `bind_open_session(staging_root, session_id, pids=, spawn_time=)`,
  `record_session_verdict(staging_root, session_id=, live=, **session=<retained
  LaunchSession>**, **live_closed=<enumerator check>**, backup_id=,
  certificate_id=)`, `record_session_failure(staging_root, session_id=, reason=)`;
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
