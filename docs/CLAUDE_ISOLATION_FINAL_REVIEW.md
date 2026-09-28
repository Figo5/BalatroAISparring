Review captured 2026-09-28. Invocation: `claude-opus-5-5 --effort high`; read-only. Reviewed HEAD `bbf61bf43f1a8be93ac71cc9ca7c0b96a670be8f`.

# Re-review of HEAD bbf61bf: isolation, launcher and staging (read-only)

**Verdict: blocked, but only by three small repairs.** Once R1–R3 below are fixed, the code is safe to proceed to controlled staged P1A → P1B → FULL_P1 measurement. The CRASH and P2 receipts, `build_certificate`, and any MATCH launch stay blocked until H3 and M1 are also fixed.

I read the code only. I ran no commands or tests and made no edits. Where I relied on test results, they are Astra's reported counts, not reruns.

## What happened to each earlier finding

| ID | Status | What the code shows |
|---|---|---|
| **NC1** (certificate could be completed from caller claims) | **Mostly closed** | P1A, P1B and FULL_P1 receipts are now produced by the tool. `build_certificate` accepts receipt IDs only and refuses the old `phases` dict. It checks that each phase has a distinct nonce, that recorded digests still match the current layer N/M, and that live state has zero diff. `check_certificate` re-validates the receipts and recomputes the certificate ID (`isolation_certificate.py:1398-1475`). **Still open:** CRASH and P2 evidence (H3 below). |
| **NH1** (Steam probe proved nothing) | **Closed in code** | A nonce-bound marker is written inside the Steam-block replacement, and a second probe runs after the Steam block, before `setVisible` (`staging.py:1248-1348`). Receipts require `steam_patch_applied=true`, `steam=nil` and `luasteam=nil`. Whether it works in the real game is still untested. |
| **NH2** (session lifecycle not enforced) | **Mostly closed** | `prepare_session` now creates one exclusive open record holding the before-snapshot, the nonce and the certificate ID. The verdict step measures the after-snapshot itself and recomputes the before-digests. It also checks the root set, timestamp order, backup ID and session-ID reuse. A bare CLI `launch` is refused. **Still open:** R1 and M1. |
| **NH3** (server bind not measured) | **Closed** | The server binding is measured through `practice_host.verify_server_adaptation`. The caller's `server_bind` is ignored, and the binding is compared on every check. |
| **NM1** (lockout tied to one certificate) | **Closed** | The lockout is now global and cleared only by an append-only acknowledgement. `build_certificate` refuses while locked. Minor leftover: L1. |
| **NM2** (Job Object failed open) | **Closed** | The Job Object is created before `Popen`. The process starts suspended, is assigned to the Job, and only then resumes. There is no unsuspended retry on `TypeError`, no bare-PID callback, and the create time is read from the retained handle (`launch_practice.py:1587-1651`). The native helper test (`astra_job_native.py`) matches this. |
| **NM3** (only one install path watched) | **Closed for spawning** | A Balatro running from any other path now blocks a spawn (`:933-979`). Minor leftover: L2. |
| **NM4** (network guards relied on folder names) | **Closed** | Mods are identified by manifest id and checked by content. This is enforced through `verify_staged_role` on every launch. |
| **NM5** (old mutable proof on launch path) | **Closed** | `check_isolation_proof` now delegates to the certificate, and `check_steam_guard` is static. `record_isolation_proof` is dead code (L3). |
| **NM6** (loose attestation inputs) | **Mostly closed** | All inputs are required, `content_hash` is derived, ports are range-checked, and the write is atomic. It is bound to the open record, nonce and PIDs. Leftover: L4. |
| **NM7** (session/nonce mismatch) | **Closed** | One shared session-ID grammar. Minor leftover: L5. |
| **NM8** (Lovely Mods dir unverified) | **Closed in code** | The launcher passes both `--mod-dir` and `LOVELY_MOD_DIR`. `collect_role_probes` and `check_lovely_evidence` check exact paths. But receipts don't call them (M2). Runtime still untested. |
| Old Lows | Mostly closed | `hash_tree` now fails closed and the exact Mods path is required. `LaunchSession.terminate` still ignores its `timeout` (`:664`). A new Steam profile still invalidates the certificate; this fails safe. |

## Required before P1A

**R1 — High (it blocks, but fails safe). The real measurement path can never prepare a session, and the backup isn't tied to the session.**
- **Where:** `isolation_certificate.py:1656-1661`, `launch_practice.py:1907-1936` and `:2111-2122`.
- **Failure:** `prepare_session` takes the backup ID from `backup_id or verdict["digest"] or verdict["id"]`. `execute_measurement_phase` passes no `backup_id`, and `check_backup_evidence` returns neither `digest` nor `id`. So every real `bootstrap --execute` or `measure` run is refused with `backup_id_missing`.
- **Why tests missed it:** the fixtures inject `{"ok": True, "digest": ...}` (`test_isolation_certificate.py:304`).
- **Second gap:** the before-snapshot is never compared with the backup manifest, so the backup ID is just a label.
- **Minimal repair:**
  - Have `check_backup_evidence` return a content digest: the sha256 of `BACKUP_MANIFEST.json` plus its per-entry file maps.
  - In `prepare_session`, require each before-snapshot root digest to equal `_digest_of(entry_manifest["files"])` for the same key.
  - Add one lifecycle test that uses the real `check_backup_evidence` against a synthetic backup and runs with a fake `popen`.

**R2 — High. Measurement receipts never check that the user's game is closed.**
- **Where:** `record_phase_receipt` (`isolation_certificate.py:967-1010`), `execute_measurement_phase` (`launch_practice.py:2179-2197`) and `supervise_session` (`:708-738`).
- **Failure:** `record_session_verdict` requires a `live_closed` callable, but `record_phase_receipt` does not. The supervision loop also never looks for a live Balatro. A user game started during P1A–FULL_P1 is caught only if it happens to change bytes before the after-snapshot.
- **Minimal repair:**
  - Make a `live_closed` callable a required argument of `record_phase_receipt`.
  - Check it the same way `_closure_problems` does. A missing check, `False` or an exception should go through `_record_receipt_failure`, which raises the lockout.
  - Pass `closed_check` from `execute_measurement_phase`.
  - Optionally, add an `on_tick` in `supervise_session` that voids the run if a live game appears.

**R3 — Medium. An error or Ctrl+C leaves a stuck open record and no lockout.**
- **Where:** `launch_practice.py:2178-2200`, `isolation_certificate.py:1540-1550` and `:1936`.
- **Failure:** an exception in the supervisor or receipt step, or Ctrl+C during the unbounded supervision wait, closes the Job (the kill-on-close is fine). But it never calls `record_session_failure`.
  - The record stays `open`, so every later prepare returns `session_already_open`.
  - `abandon_prepared_session` refuses because PIDs are already bound.
  - The only way out is hand-editing evidence files. This also breaks your requirement of a global lockout on any unknown outcome.
- **Minimal repair:** wrap the post-spawn block in `except BaseException:`, call `record_session_failure(reason="exception:<type>")`, then re-raise. Treat a failure in `_bind_open_session` (`:1816-1826`) as an abort, not best-effort.

## Required before recording CRASH/P2, building the certificate, or any MATCH

**H3 — High. CRASH and P2 evidence is still whatever the caller says.**
- **Where:** `isolation_certificate.py:921-930` and `829-853`; `launch_practice.py:2085` and `2196`.
- **Failure:** `crash_exit_codes`, `cleanup_ok`, `crash_observed`, `dead_port`, `refused` and `attempts` are copied straight from the caller's `observation` dict. The "complete" certificate in the tests uses exactly those dicts (`_CRASH_OBS`, `_P2_OBS`).
- **Side effect:** the CLI `measure --phase CRASH|P2` passes no observation, so it always fails and raises the global lockout. Don't run it yet.
- **Minimal repair:** remove `observation`.
  - For CRASH, derive the result from the retained handles: a tool-triggered abnormal exit (Job termination, or an env-gated `error()` in the staged guard after the probes are written), exit codes read from the handles, and verified cleanup.
  - For P2, derive it from an MP-guard probe that records the connect failure against the dead port, plus the listener inventory showing nothing bound to that port.

**M1 — Medium. `execute_launch` / `execute_bootstrap` trust the caller's `open_session` mapping.**
- **Where:** `launch_practice.py:1716-1721` and `1780-1785`.
- **Failure:** any mapping with `{"status": "open", ...}` is accepted without re-reading it from disk. With `require_certificate=False`, that means a spawn with no before-snapshot or lockout check.
- **Minimal repair:** reload the record with `load_open_record(session_id)`. Require status `open`, a matching nonce and phase, no PIDs bound yet, and phase `MATCH` exactly when `require_certificate` is true.

**M2 — Medium. Receipts don't use the strong probe checkers, and the docstring overclaims.**
- **Where:** `isolation_certificate.py:15-22` versus `803-826` and `1018-1033`.
- **Failure:** receipts check only the nonce, patch ID and Steam fields. They never call `collect_role_probes` (exact save/Mods/`lovely_mod_dir`, MP host and port) or `check_lovely_evidence` (fresh staged log and dump). The Lovely `main.lua` dump is not copied, even though the module docstring says it is.
- **Minimal repair:** in `record_phase_receipt`, call `collect_role_probes(paths, nonce, spawn_time, require_mp=PHASE_REQUIRE_MP[phase], expected_port=port)` and `check_lovely_evidence`. Copy the dump into the receipt evidence.

**M3 — Medium. The certificate's tool binding can be empty.**
- **Where:** `isolation_certificate.py:1322-1329` and `1384-1395`.
- **Failure:** `build_certificate(tools={})` passes validation. `check_certificate` then only checks the tools stored in the certificate, which is none.
- **Minimal repair:** drop the `tools` parameter, or require `set(tools) == set(bound_tool_specs())` at both build and check time.

## Low
- **L1:** the single lockout file is overwritten (`:679-687`). Low impact, since prepare is refused while locked.
- **L2:** `check_live_balatro_closed` still only watches the live install path (`:913-930`), and the measurement path has no Steam quiescence check (the host path has one).
- **L3:** the dead `record_isolation_proof` still writes the mutable proof file.
- **L4:** the attestation writer doesn't require phase `MATCH` or that the record's certificate ID equals the current one (`:2041-2048`).
- **L5:** `prepare_session(nonce=...)` still accepts a caller-supplied nonce (`:1606, 1675`).
- **L6:** `prepare_session` doesn't refuse a reused session ID. It overwrites the old record, and the reuse is only caught after the spawn (`:1640, 1559`).
- **L7:** phase receipts store only per-root digests, not the raw before/after manifests (MATCH sessions do store them).
- **L8:** layer M records `network_suppression.applied` but not the scan's `ok` (`:410-412`). It's enforced at launch but not bound into the certificate.
- **L9:** the CLI `bootstrap --timeout` flag is parsed but never passed through (`:2333` vs `2424-2431`).

## Confirmed sound
- Safe-write and reparse checks cover every staging and evidence write.
- Live roots cover the install, AppData and every Steam profile's `2379780` folder, including remote storage, and nothing wider.
- The MP guard errors before `NETWORKING_THREAD:start` unless the endpoint is `127.0.0.1` plus the fixed port. The locals used by the reference `core.lua:343-349` come from `MP.ENV`, so the guard covers them.
- Cleanup acts only on owned processes: same-handle identity check, inside staging, named `Balatro.exe`, and it refuses the live install path.

The native evidence so far (the harmless Job helper and the socket/identity checks) supports the process-ownership code. It says nothing yet about isolating Balatro, and I haven't treated fixture receipts as real isolation.
