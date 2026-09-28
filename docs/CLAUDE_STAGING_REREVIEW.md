**Verdict: rejected for milestone acceptance.** The fixes in `staging.py` and in the launcher's process handling are real, and most of the original findings are closed. But the certificate that gates launching can still be completed from caller-supplied claims, so the "no forged evidence" requirement isn't met. I also found one new High: the `steam=nil` probe proves nothing.

This was read-only. I ran no commands, made no edits and didn't re-run any tests; I relied on your 34/34, 18/18 and 36/36 results. Integration approval is not claimed, and every runtime gate is still pending.

## Closure matrix for the original findings

| ID | Status | Evidence / what remains |
|---|---|---|
| C1 Lovely Mods dir | **Mostly closed** | `LOVELY_MOD_DIR` pinned; child env built from an allowlist (`staging.py:796-830`); the launcher checks it (`launch_practice.py:1028-1046`). What remains is in NM8 below. |
| C2 self-attested proofs | **Reopened one layer up** | `record_isolation_proof` now measures, but the certificate that actually gates launch accepts caller-asserted phase data (NC1). |
| H1 bootstrap deadlock | **Closed for launch** | Now gates on preflight (`launch_practice.py:1348`). But no code turns a bootstrap run into P1A certificate evidence (NC1). |
| H2 weak probes | **Mostly closed** | Exact `save=` parsing, nonce, modification time and patch ID (`staging.py:1641-1701`). Remaining: the Steam probe is vacuous (NH1). |
| H3 role trees unverified | **Closed** | `verify_staged_role` is in the plan; a missing binding aborts (`:1476-1480`); the Mods tree is in the manifest; native Steam DLLs are checked at spawn. |
| H4 endpoint fallback | **Closed** | Multiplayer is found by its JSON id; config regex fixed; the MP guard anchor matches `work/reference/mp/core.lua:349`, and `.env` takes precedence per `:343-344`. |
| H5 cleanup containment | **Closed** | `staging_root` required, records must be inside staging and named `Balatro.exe`, session files can't be overwritten. |
| H6 backup integrity | **Closed for creation** | Source and copy compared, game rechecked as closed, manifests stored beside copies, live state checked against the backup. Binding each session to its backup is still open (NH2). |
| H7 network suppression | **Mostly closed** | Anchors match the reference sources: Handy updater `handy-updater.lua:6-8`, SMODS logging `:8,56`, SMODS HTTPS `:291`. Remaining: detection relies on folder names (NM4). |
| M1 junction redirects | **Closed** | `assert_safe_write` does a lexical reparse-point check before every write (`staging.py:453-504`). |
| M2 overlap defaults | **Closed** | Explicit install path, all Steam profiles, all libraries and custom roots. |
| M3 dead guard module | **Closed** | The shim claim is gone. |
| M4 duplicate sessions | **Closed** | `check_no_staged_session` runs before each spawn. |
| M5 termination | **Mostly closed** | Job Object, handle-based terminate and exit verification. What remains is in NM2. |
| M6 enumeration fails open | **Closed** | A Balatro process without a readable path now raises. The related scope gap is NM3. |

## Critical

**NC1. The certificate can be completed from caller-asserted data** (`isolation_certificate.py:330-403`, `472-562`, `579-637`).
- **What's accepted:**
  - `_validate_measured` accepts any bool, int or 64-hex string.
  - CRASH and P2 accept bare `True`, even though the docstring says bare booleans are rejected.
  - FULL_P1 accepts any two equal hex strings.
  - The P1A and P1B digests are never compared with the current layer N and layer M.
  - P1A and P1B don't require a live before/after diff.
  - `evidence_files` can be any non-empty file. It is never parsed or matched to the phase's nonce, spawn time or paths.
  - Phase nonces don't have to be distinct.
  - `check_certificate` never re-validates the phases and never recomputes `certificate_id`.
- **Proof it works:** the roundtrip test (`test_isolation_certificate.py:201-250`) certifies a "complete" certificate using `sha256("measured")` as the live digests, a save-thread probe as crash evidence, and `refused: True` for P2.
- **Impact:** forging is still the only way to reach `may_launch`. The chicken-and-egg problem is only "solved" by hand-assembled evidence.
- **Fix:**
  - Add tool-owned phase recorders that take the `LaunchSession` and take their own before/after `snapshot_live`. After the owned processes exit, they run `check_bootstrap_evidence` / `collect_role_probes` and immutably copy the probes, snapshots and the Lovely dump of `main.lua`. Each writes a phase receipt.
  - `build_certificate` accepts only receipt IDs. It re-parses the copies and requires:
    - per-probe nonce equality and distinct nonces per phase;
    - P1A bootstrap digest equal to both role digests and to the current layer N;
    - P1B and FULL_P1 Mods digests equal to the current layer M;
    - zero diff across every snapshot root.
  - CRASH and P2 evidence comes from launcher-produced receipts, never booleans.
  - `check_certificate` re-validates all of this and recomputes the ID.
  - Add a negative test that the current `_phases` fixture is rejected.

## High

**NH1. The Steam-absent probe is vacuous** (`staging.py:1175-1211`).
- **Problem:** the guard is inserted *before* `G:start_up()`. But in the reference `main.lua:87-112`, `G:start_up()` runs first and the Steam block runs after it. So `steam=tostring(G.STEAM)` is always `nil`, whether or not the disable patch applied.
- **Where it's trusted:** `collect_role_probes:1683`, `record_isolation_proof:2008` and the certificate.
- **What actually protects you today:** the omitted `luasteam.dll`, which makes `require` fail at `:100`.
- **Fix:**
  - Have the Steam regex payload write a nonce-bound `steam_patch_applied` marker.
  - Add a probe placed before `love.mouse.setVisible(false)` that records `G.STEAM` and `package.loaded.luasteam`.
  - Require both, and store the Lovely dump of `main.lua` as evidence.

**NH2. The per-session lifecycle isn't enforced, and the session diff trusts its inputs.**
- **Launch side:** `build_launch_plan` and `execute_launch` don't require a prepared session, its nonce, a stored before-snapshot, or a verdict for the previous session. The CLI `launch` and `bootstrap --execute` (`launch_practice.py:1968-2049`) spawn processes and exit with no after-snapshot and no verdict.
- **Verdict side:** `record_session_verdict` (`isolation_certificate.py:966-1043`):
  - trusts the per-root `digest` values it is given, without recomputing them from `files`;
  - doesn't check the root set against the live roots (install, AppData, every Steam profile);
  - doesn't check timestamp ordering;
  - doesn't bind `backup_id`, which is optional and never verified;
  - allows a session ID to be reused.
- **Proof it's exploitable:** passing `after=before` returns `session_passed`.
- **Fix:**
  - `prepare_session` creates an exclusive open record containing the before-snapshot, the backup manifest digest (which must equal the before-snapshot per root), the nonce and the certificate ID. It refuses while any earlier session has no verdict.
  - `execute_launch` requires that record and uses its nonce.
  - The verdict step takes or recomputes the after-snapshot itself and closes the record.
  - The CLI `launch` either refuses (host-only) or runs this whole lifecycle.

**NH3. The layer M server bind isn't measured** (`isolation_certificate.py:270-273`, `614`).
- `server_bind` is a caller-supplied dict. It is only checked for truthiness and is excluded from the recompute.
- A changed server tree or bind patch therefore doesn't force a new P1B or full P1.
- **Fix:** compute the digest from the prepared server tree, the bind patch and the pinned commit, and compare it on every check.

## Medium

- **NM1. Lockout is scoped to one certificate ID** (`:711`). Building a new certificate lifts it, and each lockout overwrites the previous record.
  - **Fix:** use a global lockout that is cleared only by an append-only user acknowledgement, and have `build_certificate` refuse while locked.
- **NM2. Job Object ownership fails open** (`launch_practice.py:1497-1510`).
  - If there is no job, or assignment fails, the launch continues.
  - The process is assigned to the job only after it starts.
  - The `terminate(pid)` callback is called with a bare PID after the handle is killed (`:593-603`), which risks hitting a reused PID. `test_launcher_safety.py:429-443` encodes this behaviour.
  - The create time is read by reopening the PID (`:1521`) instead of from the handle.
  - **Fix:** on Windows, require an assigned job or abort; start the process suspended, assign it, then resume; drop the PID callback; read `GetProcessTimes` from the Popen handle.
- **NM3. The live-process check only watches one install path** (`:882-931`). A Balatro running from any other path (another library, a copy, or a wrong `--install`) is ignored.
  - **Fix:** any Balatro-named process that isn't inside staging and isn't owned should block. Also re-check after a short settle delay.
- **NM4. Network-guard requirements depend on folder names** (`staging.py:1514-1521`). A renamed SMODS or Handy folder combined with a pattern that fails to match passes silently.
  - **Fix:** identify mods by their manifest id, and fail on content: any file that still contains an un-suppressed `https_updater_thread:start()`, `tcp:connect("localhost", 53153)` or `asyncRequest`.
- **NM5. The old mutable proof is still on the launch path.** The `steam_guard` gate (`:1364-1416`, used at `launch_practice.py:1252`) requires `isolation_proof.json`.
  - That file is rewritten on every record (`:2034`) with a weaker live check: install metadata only, and only `apps[0]` (`:1945`).
  - This contradicts the frozen contract's "certificate API only, never rebase."
  - **Fix:** remove it from the launch gates.
- **NM6. The attestation writer's inputs are too loose** (`isolation_certificate.py:823-893`).
  - `spawn_time` and `port` may be `None`, which skips the staleness and port checks.
  - `content_hash` is arbitrary.
  - `control_port` has no range check.
  - The file isn't bound to the open session, the certificate or live owned processes.
  - The write isn't atomic.
  - **Fix:** require every input, derive `content_hash`, check the port range and the session/certificate/process binding, and write to a temp file then `os.replace`.
- **NM7. The session and nonce interfaces don't match.**
  - The launcher's session-ID pattern allows `:` and 128 characters (`:84`); the certificate's allows neither (`:51`).
  - `_spawn_verified` never validates the plan's session ID, and doesn't require `descriptor.session_id` to equal it.
  - `sessions/{id}.json` with a `:` creates an NTFS alternate data stream.
  - The nonce is minted twice: once by `prepare_session` and once by the launcher.
  - **Fix:** use one shared grammar with one nonce owner.
- **NM8. What's left of C1.**
  - Whether Lovely actually honours `LOVELY_MOD_DIR` is unverified, because there is no Lovely source under `work/`.
  - The probe just echoes the environment variable back.
  - **Fix:** also pass `--mod-dir <role mods>` on the command line. Require P1a evidence to show a new log under the staged `Mods/lovely/log`, and no change to live Mods.

## Low

- `hash_tree` descends into junctioned directories and silently skips files it can't stat (`staging.py:572-602`). It should fail closed.
- `write_json`, `disable_mod_by_lovelyignore` and the backup-root writes don't go through the safe-write check.
- The `lovely_mod_dir` / `mods` checks accept any path under the role root rather than the exact expected Mods path (`staging.py:1688,1699`; `launch_practice.py:1033`).
- The `config/Multiplayer.jkr` regex check is probably vacuous because the file is likely compressed. The MP guard makes this moot.
- The evidence-copy `label` is used in a filename without validation (`isolation_certificate.py:410`).
- Adding a new Steam profile invalidates the certificate. This fails safe, but the architecture allows new profiles.
- `LaunchSession.terminate` ignores its `timeout` argument.

## Pass/reject by scope

| Module | Verdict | Condition |
|---|---|---|
| `staging.py` | **Conditional pass** | Path/reparse safety, endpoint and suppression code accepted. Must fix NH1, NM4, NM5, NM8. |
| `launch_practice.py` | **Reject** | Cleanup, handles and backups are good. The launch lifecycle needs NH2, NM2, NM3, NM7. |
| `isolation_certificate.py` | **Reject** | Needs NC1, NH2, NH3, NM1, NM6. |

What the certificate design gets right, when checked against the code:
- It ignores live *contents*: only root paths are compared.
- Nothing is declared mutable, so there are no broad exclusions.
- Evidence copies are content-addressed.
- Tool hashes cover all six isolation-critical modules.

**Before running P1a:** fix NH1 and NM8, make the Job Object mandatory (NM2), and put a tool-owned before/after snapshot around the bootstrap run. Role launches stay blocked until NC1 and NH2 are fixed.

**Runtime gates still pending:**
- P0, P1a, P1b, full P1, the crash fixture and P2.
- Whether Lovely honours `LOVELY_MOD_DIR`.
- Whether patches hit the SMODS chunk-name target and the save-thread chunk.
- Patch order relative to SMODS.
- Steam relaunch behaviour, Steam quiescence and overlay injection.
- Companion consumption of the attestation, and host integration.
