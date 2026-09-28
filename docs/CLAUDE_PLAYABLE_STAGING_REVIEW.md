# BalatroAISparring staging/launcher review — early architecture pass

**Verdict: not approved.** There are 2 Critical and 7 High findings, all fixable. The code does several things right:
- It ignores a cached `may_launch`.
- It re-checks the live process before and after each spawn.
- It reads the real OS create time.
- Cleanup rolls back only recorded PIDs.
- The Steam-block regex, `G:start_up()`, `love.mouse.setVisible(false)` and `save_request` anchors all match the reference `main.lua:86-117` and `save_manager.lua:12`.

This was a read-only review. I ran nothing, including the tests.

## Critical

**C1. The Lovely Mods directory is never pinned, so a staged exe may load the live Mods tree.**
- **Where:** `staging.py:394-410` (`role_environment_overrides`) and `staging.py:413-416`, which inherit the whole parent environment.
- **Problem:** The code sets `APPDATA` but not `LOVELY_MOD_DIR` and passes no `--mod-dir`.
  - LÖVE's use of `APPDATA` is source-backed.
  - Lovely's default mod-dir resolution is not. Rust `dirs::config_dir()` normally calls the Windows known-folder API and ignores `APPDATA`. This is unverified because `work/lovely-source` is missing.
  - An inherited `LOVELY_MOD_DIR` would also point the child at live Mods.
- **Impact:** The very first P1a bootstrap run could load live SMODS, live Multiplayer with its official endpoint, the Handy updater and the SMODS debug socket. It would also write Lovely logs and dumps into live Mods (`dump_lua = true`, `staging.py:644`).
- **Why the guard doesn't catch it:** The staged guard patch lives only in staged Mods, so it would never load. Its Mods check (`staging.py:707`) just re-derives the Mods path from the save directory, so it proves nothing about what Lovely loaded.
- **Fix:**
  - Set `LOVELY_MOD_DIR=<role mods>` explicitly.
  - Build the child environment from an allowlist. Strip `Steam*`, `LOVELY_*` and `SDL_*`.
  - Have `_spawn_verified` assert that the value resolves inside the role root.
  - Have the guard write `os.getenv('LOVELY_MOD_DIR')` into its probe.
  - Evidence must show a new Lovely log in the staged `Mods/lovely/log` and no change in the live one.

**C2. The isolation and Steam proofs are self-attested JSON checkboxes.**
- **Where:** `check_isolation_proof` (`staging.py:1050-1072`) and the `steam_absent.json` check (`staging.py:837-849`).
- **Problem:** They accept any hand-written booleans. No code produces these files from real measurements, and nothing binds them to:
  - the exe or patch hashes, or a Mods manifest;
  - tool source hashes or the Steam `buildid`;
  - a backup label or a timestamp.
- The tests hand-write them (`test_staging.py:93-128`). Together with H1 below, forging these files is currently the only way to reach `may_launch`.
- **Fix:**
  - Only a code path should write proofs, derived from the checked probes plus a before/after live hash diff.
  - Record those binding digests in the proof.
  - `check_isolation_proof` and `check_steam_guard` should recompute the digests and fail on any mismatch.

## High

**H1. The bootstrap plan deadlocks.** `build_bootstrap_plan` (`launch_practice.py:408-413`) requires `bootstrap_evidence`, but only the bootstrap run can produce that evidence. `test_staging.py:815-831` encodes this deadlock as expected behaviour.
- **Fix — before the run, gate on:** game closed, fresh verified backups, bootstrap manifest and patch hash verified, probe files absent, `LOVELY_MOD_DIR` pinned.
- **After the run:** wait for the owned process to exit, check the probes, diff live state, then write the proof.

**H2. The probe evidence is weak.**
- **Vacuous save-dir check:** `staging.py:944` does a substring match against a probe that always contains `expected=<save_dir>` (written at `staging.py:713`). The check passes whatever the real save directory was.
- **Stale probes are accepted:** there is no nonce or spawn-time binding.
- **No live diff** is checked.
- **Fix:**
  - Parse the `save=` line exactly.
  - Add a per-run nonce via the environment and echo it in all three probes.
  - Require probe modification times after the spawn.
  - Include the patch SHA in the probe.

**H3. Role launch doesn't verify the staged trees.**
- **Missing gate:** `build_launch_plan` (`launch_practice.py:340-350`) never calls `verify_staged_role`.
- **Fails open:** `_exe_binding` returning `None` skips the hash check (`launch_practice.py:492-494`).
- **Mods tree unhashed:** `STAGING_POLICY` excludes any folder named `appdata` (`staging.py:212-215`). So the entire staged Mods tree — Multiplayer code, `.env`, the guard patch, any extra mod's Lovely patch — is outside the manifest.
- **Fix:**
  - Add a per-role manifest gate plus a Mods manifest that excludes only runtime output (`lovely/log`, `lovely/dump`).
  - Treat a missing binding as an abort.
  - Assert at launch that no `STEAM_NATIVE_FILES` are present in the staged install.

**H4. The endpoint can silently fall back to the official server.**
- **Hardcoded folder:** `.env` is written to and verified at a hardcoded `Mods/Multiplayer` (`staging.py:521,564`).
- **How Multiplayer actually reads it:** from `MP.path .. "/.env"` (`core.lua:73`). If that file is missing, it uses the SMODS config default `balatro.virtualized.dev` (`config.lua:4`, `core.lua:343-344`). A differently named or missing mod folder therefore passes verification on a phantom directory, while the real mod connects to the official server.
- **Persisted-config check is vacuous:** `CONFIG_URL_RE` (`staging.py:73`) cannot match the `["server_url"] = …` format, so the check always sees nothing.
- **Fix:**
  - Locate the mod whose JSON has `"id": "Multiplayer"`, require exactly one, and write `.env` there.
  - Add the startup guard that `PROTOTYPE_GATES` P0 requires: a Lovely patch on Multiplayer's `core.lua`, placed before `MP.NETWORKING_THREAD:start`, that errors unless `MP.ENV` holds `127.0.0.1` and the expected port.
  - Check the staged save directory's `config/Multiplayer.jkr` too.

**H5. Cleanup doesn't enforce staging containment.**
- `cleanup_session` (`launch_practice.py:276-309`) trusts `image_path` from the session JSON and refuses only the live install path.
- `staging_root` is optional, and the session file is read before its containment is checked. The docstring's promise at `launch_practice.py:9-12` is therefore not met.
- A corrupted or forged session file can terminate any process whose PID, path and start time match.
- **Fix:**
  - Require `staging_root`.
  - Require `is_within(staging_root, info.image_path)` and the name `Balatro.exe`.
  - Refuse to overwrite an existing session file (`write_session`, `launch_practice.py:312-321`).

**H6. Backup integrity isn't verified.** In `create_live_backup` (`launch_practice.py:620-703`):
- **Copy vs. source:** it hashes the copy but never compares it with the source, so a torn copy goes unnoticed.
- **Closed check:** the game is checked as closed only before copying.
- **Evidence paths:** `verify_backup_entry` trusts the absolute `dir`/`manifest` paths in the JSON (`:606-617`). They could point at the live tree.
- **Manifest placement:** entry manifests are written inside the copy root, and `manifest.json` is excluded at every depth.
- **No freshness check.**
- **Fix:**
  - Hash the source, copy, then verify the two match, and re-check that the game is closed afterwards.
  - Require entries to sit inside `backup_root`, and keep manifests beside the copies, not inside them.
  - Before each closed-game launch, compare live state against the backup; this doubles as the "before" snapshot.

**H7. Network and updater suppression is missing for the role trees.**
- `stage_role` never neutralises Handy's updater.
- Nothing guards the SMODS debug socket (`localhost:53153`, `smods-logging.lua:4-15,56`) or SMODS HTTPS.
- No gate checks any of this.
- Disabling Handy entirely conflicts with the human Handy-parity requirement. Patch out the updater thread start instead, and add a `network_guards` gate that binds the patch hashes.

## Medium

- **M1. Pre-existing junctions inside staging redirect writes.** `stage_role` and `stage_bootstrap` run `mkdir` (`staging.py:887-888,987-988`), and `write_steam_guard`/`write_lovely_patch` (`:781-816`) write, with no `assert_within` check. A junction at `staging/roles/ai` would send those writes into live. Fix: run `assert_no_links(staging_root)` plus `assert_within` before every write.
- **M2. The overlap check uses default roots.** `assert_no_overlap`/`live_roots` (`staging.py:105-124`) ignore the `--install` argument, the discovered Steam userdata path and custom Steam libraries.
- **M3. The Steam guard Lua module is dead code.** It is written to `steam_guard/` but no patch ever loads it, so the `guard_installed` evidence refers to nothing. Either wire it in or drop the claim. Also unverified: whether SMODS patches rewrite the Steam block before our regex runs (our priority is 2147483600). Evidence should include the Lovely dump of the patched `main.lua`.
- **M4. Duplicate sessions are possible.** Nothing refuses a launch while staged `Balatro.exe` processes are already running, so two sessions could share a save directory and port.
- **M5. Termination is unverified.** `taskkill` runs without /F and the exit is never confirmed; Handy's quit hook can block. The `create_time_unavailable` path kills by bare PID even though the `Popen` handle is available. Fix: use a Windows Job Object and verify exit.
- **M6. Process enumeration fails open.** `Where-Object { $_.Path }` silently drops processes whose path is unreadable. It should fail closed for any process named Balatro with no path.

## Low

- `find_steam_userdata_app` backs up only the first Steam profile.
- `default_live_appdata` trusts the `APPDATA` environment variable.
- Directory-name exclusions (e.g. `temp`, `logs`) apply at any depth.
- `configure_role_endpoint` creates a `Multiplayer` folder even when the mod is absent. The H4 fix covers this.

## Unpassed native tests (not code bugs)

- P0 has not been run.
- P1a, P1b, full P1 and P2–P5 have not been run.
- The suite is at 41/42 with the known stale Lua shim assertion.
- The fixture tests only check plumbing, because they hand-write the proofs.

## Genuine unknowns

1. How Lovely 0.10.0 picks its Mods folder by default (C1).
2. Whether Lovely patches apply to thread chunks. If not, the save-thread probe never appears and the run fails closed.
3. Patch ordering against SMODS, and whether a regex that doesn't match only produces a warning.
4. Whether a directly started `Balatro.exe` relaunches through Steam. If it does, the live game would start. The post-spawn check catches that, but it should be repeated after a short settle delay.
5. Whether the Steam overlay injects into child processes of the live game.

## Architecture decision: keeping normal Balatro open at its menu

**This is conditionally acceptable, but only as a separate, later mode, and not on current evidence.** It is not just a looser P0; it is a new mode with its own risks:
- **Hash-diff proof stops working:** a running live game legitimately writes its own AppData, so "zero live diff" can no longer be shown by hashing.
- **Children of the live process are exposed:** they inherit Steam environment variables and the overlay's `CreateProcess` hook.

The closed-game requirement stays mandatory for bootstrap, P1a/P1b, full P1, any copying from live, backups and installing the companion.

A `concurrent_live` mode may be enabled only with all of the following:

1. **Separate, opt-in gate set.** It needs its own proof record binding the P1 proof digest, staged and Mods manifests, patch hashes, the exe and `version.dll` hashes, the live `buildid` and the tool hashes. Any mismatch — for example a Steam update — disables the mode.
2. **Concurrent proof run.** With the user's game idle at the menu, run a trace attributed to the staged PIDs (ETW/ProcMon). It must show writes only under the staging root and TCP only to the loopback match and control ports. The staged processes' loaded modules must exclude `GameOverlayRenderer64`, `steam_api64` and `steamclient64`. The live install and Steam userdata must be unchanged.
3. **Launch from outside the live game.** The live menu sends a single-use, short-lived request to a launcher process the user started separately. That launcher builds an allowlisted environment and its own Job Object. The live game must not spawn the practice runtimes itself.
4. **Live PID untouched.** Record the live PID and create time before and after; they must match, and the live process is never in any cleanup set.
5. **Per-session attestation.** Both runtimes must return probes carrying the session nonce, their save directory, their Lovely Mods directory and `steam=nil` before any credential or match start is issued.
6. **Install backup still current.** A closed-game backup must exist, and its install manifest must still match the live install. The install can be hashed read-only while the game runs.

**Smallest safe transition until then:** the live menu item asks the user to confirm "Quit Balatro and start practice?", only at the main menu. The live game then quits through its own normal quit path. The external launcher waits for the live PID to exit naturally, with a timeout. If it doesn't exit, the launcher aborts and never kills it. Then it re-runs every closed-game gate before launching.
