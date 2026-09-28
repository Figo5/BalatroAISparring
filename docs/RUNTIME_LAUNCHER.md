# Runtime launcher contract

Owner: `tools/launch_practice.py` with `tests/test_launcher_safety.py`.
`tools/isolation_certificate.py` owns the two-layer certificate, the tool-owned
phase receipts, the exclusive per-session records and the global lockout; its
tests live in `tests/test_isolation_certificate.py` and
`tests/test_measurement_lifecycle.py`. Worker A owns `tools/staging.py`,
`tests/test_staging.py` and `docs/RUNTIME_ISOLATION.md`.

Nothing here authorises a launch. The default `launch`/`bootstrap --execute`
paths stay blocked until the review gates pass and Astra runs them; this slice
only makes the previously approved gates enforceable.

## 1. One session grammar, one nonce owner (NM7)

- `isolation_certificate.SESSION_ID_RE = ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` is the
  only session-id grammar. `launch_practice.SESSION_ID_PATTERN` is that same
  object, and `write_session` refuses anything else. There is no `:` in the
  grammar, so `sessions/{id}.json` can never become an NTFS alternate data stream.
- The session **nonce is minted once**, by `isolation_certificate.prepare_session`,
  and stored in the exclusive open record. `execute_launch`/`execute_bootstrap`
  require that open record and use its nonce; `_spawn_verified` no longer mints a
  nonce. A descriptor's `session_id` must equal the prepared session id.

## 2. Host-only CLI

`python tools/launch_practice.py launch ...` is **refused**: a bare CLI launch has
no prepared open session and no current certificate, so it returns
`host_only_launch_requires_lifecycle` (exit 3). Only the practice host runs the
normal match lifecycle (prepared open session + current certificate + live
attestation). The tool-owned measurement path is separate and cannot enable an
AI/match capability:

- `bootstrap --execute` runs the **P1A phase lifecycle** (prepare → launch →
  supervise → record the measured receipt).
- `measure --phase P1B|FULL_P1|CRASH|P2` runs a role measurement phase, gated on
  the previous phase receipt (P1A→P1B→FULL_P1→CRASH/P2).
- `acknowledge-lockout --operator --reason` appends the only record that clears
  the global lockout.

## 3. Phase receipts and the certificate (NC1)

`build_certificate` accepts **receipt IDs only**. The legacy caller-dict
`phases=` argument is still accepted but always refused with
`certificate_receipts_required` / `caller_phase_data_rejected` (never a
`TypeError`), so the old hand-assembled fixture cannot certify anything.

Each receipt is produced by `isolation_certificate.record_phase_receipt` after an
exited launch session. The recorder:

- loads the exclusive open record and requires the session id/nonce to match;
- takes its own `after` `snapshot_live` and requires zero live byte diff against
  the prepared `before` snapshot (per root, recomputed from the file maps);
- re-parses the actual staged probe files and validates nonce, patch id and (NH1)
  the patch-applied marker plus the post-Steam-block probe (`steam=nil`,
  `luasteam=nil`), and the exact `Mods` paths;
- copies the probes immutably under `evidence/receipts/` and writes the receipt
  content-addressed;
- asserts P1A binds the bootstrap install digest to **both** role digests, and
  P1B/FULL_P1 bind the role Mods digests and parity digest.

`build_certificate` re-parses every receipt copy, requires **distinct nonces per
phase**, and refuses P1B/FULL_P1 whose Mods digest no longer matches the current
layer M. `check_certificate` re-validates the receipts, recomputes the
certificate id from the layers/tools/receipts/evidence and refuses on any drift.

## 4. Per-session lifecycle (NH2)

- `prepare_session` requires a passing `closed_check`, a **verified backup**
  (`backup_verify`), the phase prerequisite receipt, and no other open record.
  It rotates stale probes/attestations, takes the `before` full snapshot and
  writes one exclusive open record holding the single nonce, certificate id,
  backup id and the before file maps.
- `execute_launch` requires that open record; `bind_open_session` records the
  exact owned PIDs and spawn time.
- `record_session_verdict` **computes the after snapshot itself** after the owned
  processes exit, re-derives the before digest from the stored file maps, checks
  the root set, the timestamp order and the backup id, refuses a reused session
  id, then closes the record. Any live byte diff writes the global lockout,
  appends a revocation and records `verdict: revoked` (never a false pass).
  `record_session_failure` closes with `verdict: failed`.

## 5. Global lockout (NM1)

`certificate_lockout.json` is global and independent of any certificate id. A new
certificate never clears it. It is cleared only by an append-only
`certificate_lockout_ack.jsonl` record whose `lockout_id` matches the current
lockout (`acknowledge_lockout`). `build_certificate` and `prepare_session` both
refuse while locked.

## 6. Windows Job Object is mandatory (NM2)

`_spawn_verified` starts every child with `CREATE_SUSPENDED`, creates a Job
Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, assigns the child, and only then
resumes it through the retained handle (`NtResumeProcess`). On Windows the Job
Object is created **before** `Popen`, so a missing job aborts with no spawn at all
(`job_object_unavailable`), and a failed assignment terminates the owned handle and
aborts (`job_object_assignment_failed`); the launch never continues unsuspended or
unassigned. There is no unsuspended `Popen` fallback: a wrapper that rejects
`creationflags` (`TypeError`/`ValueError`) or a bounded spawn failure (`OSError`)
closes the unused Job Object and aborts (`spawn_flags_unsupported` /
`spawn_failed`) without a second attempt or an untracked orphan. Create time is read
from the retained `Popen` handle, never by reopening a PID, and no callback is
invoked with a bare PID (rollback reports `OwnedProcess` handles).

## 7. Any non-owned Balatro process blocks (NM3)

`check_no_staged_session` refuses when any Balatro-named process is running that
is not the user's installed game: one inside staging is
`staged_session_running`, one anywhere else (another Steam library, a copied exe)
is `foreign_balatro_running`. Unreadable Balatro image paths still fail closed
during enumeration. The check runs again immediately before each spawn.

## 8. Exact `--mod-dir` (NM8)

Each role command is `[<role exe>, "--mod-dir", "<exact role Mods>"]` in addition
to pinned `LOVELY_MOD_DIR`. Lovely honours both (`--mod-dir` at
`../../work/lovely-source/crates/lovely-core/src/lib.rs:141`; env at `:110`).
`_spawn_verified` aborts with `mod_dir_command_mismatch` if the plan command does
not carry the exact flag.

## 9. Measured server binding (NH3)

Layer M's `server_bind` is no longer caller data. `measure_server_binding` lazily
calls `practice_host.verify_server_adaptation` on the real adapted server tree
(manifest, source/build hashes, package lock, runtime dependency hashes, upstream
pin, loopback bind, admin-off) and is recomputed on **every** build and check. A
changed server tree or bind patch changes the M layer and forces P1B/full P1.

## 10. Attestation writer (NM6)

`write_launcher_attestation` requires the open session (id + nonce), range-checked
control/match ports, a current certificate, the recorded owned PIDs and a spawn
time; it derives the content hash from the certificate Mods layer and re-verifies
both roles' probes. It writes each fixed-path file atomically (`temp` +
`os.replace`). No caller-supplied content hash or arbitrary session is accepted.
The normal host should delegate to this writer and not maintain a second,
unchecked writer.

## 11. Shared staging API (worker A)

Unchanged from before unless noted: `role_environment`, `role_environment_overrides`,
`verify_staged_role`, `check_bootstrap_preflight`, `check_bootstrap_evidence`,
`check_isolation_proof`, `check_steam_guard`, `verify_staged_endpoints`,
`assert_no_overlap`, `find_links`, `hash_tree`, `verify_manifest`, `read_json`,
`write_json`, `sha256_file`, `is_within`, `assert_within`.

Added by the NH1 landing in `staging.py`: `PROBE_STEAM_MARKER`,
`PROBE_STEAM_POST`, `check_steam_probes`, `lovely_evidence_paths`. The
certificate and its receipts require both new probes for role phases.

## 12. MATCH vs measurement (final integration)

`prepare_session` now defaults to `phase=MATCH`, a **distinct normal-practice
record** that requires a current verified certificate (`check_certificate` ok).
The ordered `P1A`/`P1B`/`FULL_P1`/`CRASH`/`P2` phases are **measurement-only**,
gated on the previous phase receipt, and can never be recorded as normal practice
(`record_phase_receipt` refuses `MATCH` with `unknown_phase`, and a non-`MATCH`
open record cannot carry session descriptors:
`execute_launch(..., session_descriptors=...)` aborts with
`session_descriptors_require_match_phase`). The no-other-open-record gate applies
to every spawn regardless of phase.

Measured closure is mandatory:

- `record_session_verdict(..., session=<retained LaunchSession>, live_closed=<real check>)`
  recomputes the after snapshot itself, requires every owned handle stopped and
  the user's game closed, and refuses with `session_closure_unproven`
  (`retained_session_required`, `owned_processes_running`, `live_game_running`,
  `live_closed_check_unavailable`) otherwise. It can never certify a still-running
  role or a concurrent user Balatro.
- `record_session_no_spawn(..., session_id, live)` is the only way to close a
  prepared-but-never-spawned session: it requires no bound PIDs and measures zero
  live diff itself (caller booleans do not suffice); a diff revokes and locks out.
- `record_session_failure` and any receipt-recording failure now **raise the
  persistent global lockout** as well as closing the record, so an unknown/missing
  post-session diff can never lead to a silent rebaseline; only an explicit
  `acknowledge_lockout` clears it.

## 13. Bound policy/runtime code

`bound_tool_specs()` additionally binds the external repository code the service
actually loads: `tools/policy_worker.py`, `tools/lua/policy_env.lua`,
`tools/ruleset_contract.py`, `AISparring/ai/baseline_policy.lua`, `codec.lua`,
`observation.lua`, `actions.lua`. Any ordinary edit after certification changes
the bound surface and invalidates the certificate; a missing required entry fails
closed (`bound_tool_missing`). Live progression contents are never compared.

## 14. Safe host usage (no lambdas, no fake exits)

Normal practice uses the concrete wrappers so the host cannot pass `lambda: True`
or fabricated exits:

- `launch_practice.prepare_match_session(staging_root, session_id=, port=,
  live_install_root=, live_appdata_root=, steam_root=, backup_root=)` — internally
  runs the real certificate, live-closed and fresh-backup checks.
- `launch_practice.finalize_match_session(staging_root, session=,
  live_install_root=, live_appdata_root=, steam_root=, backup_id=)` — uses the
  retained `LaunchSession` handles and the real closed-game check.
- `launch_practice.abandon_prepared_session(staging_root, session_id=, ...)` — the
  measured no-spawn closure.

## 15. API deltas for the host

- `execute_launch(..., open_session=<open record>, require_certificate=True)` and
  `execute_bootstrap(..., open_session=<open record>)`: no `nonce_factory`,
  `terminate`, or implicit nonce.
- `_spawn_verified(..., nonce=..., on_terminate=..., resume=..., expected_session_id=...)`.
- `build_launch_plan(..., require_certificate=True)`: measurement role plans pass
  `False` to skip the certificate-backed `isolation_proof`/`steam_guard` gates.
- Plan `command` now includes `--mod-dir`.
- `isolation_certificate.prepare_session(phase=MATCH|P1A|P1B|FULL_P1|CRASH|P2,
  backup_verify=..., backup_id=...)`, `bind_open_session`,
  `record_phase_receipt`, `record_session_verdict(session=, live_closed=)`,
  `record_session_no_spawn`, `record_session_failure`,
  `build_certificate(receipt_ids=...)` (no measured dicts), `acknowledge_lockout`,
  `MATCH`/`SESSION_PHASES`.

## 16. Running

```
python tools/launch_practice.py plan --staging-root staging --backup-root backups \
  --install "<install>" --appdata "<live AppData>\\Balatro" --steam-root "<Steam>"
python tools/launch_practice.py bootstrap --staging-root staging --backup-root backups
python tools/launch_practice.py measure --phase P1B --staging-root staging --backup-root backups
python tools/launch_practice.py backup --install "<install>" --steam-root "<Steam>" --execute
python tools/launch_practice.py acknowledge-lockout --operator "<you>" --reason "<why>"
python tests/test_launcher_safety.py
python tests/test_isolation_certificate.py
python tests/test_measurement_lifecycle.py
python tests/astra_certificate_attacks.py
```

All tests are fixture-only. No live install, live AppData, Steam tree, network,
game launch or OS process termination is performed in this repair. Fixtures are
**not** runtime proof: P1a/P1b/full P1/crash/P2, Steam behaviour, patch targeting
and host integration remain real, pending gates.
