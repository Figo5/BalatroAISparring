# Runtime isolation research and staging gate

Status: **staging code with measured, nonce-bound evidence gates and a two-layer
reusable isolation certificate. No native isolation is proven yet and nothing was
launched.** The certificate stays **partial** and the launch gate stays closed
until every required phase (P1a, P1b, full P1, crash/cleanup fixture, P2 dead-port)
has real measured evidence. No staged process was started and no live file, save
or Steam state was touched or copied.

Owners: `tools/staging.py`, `tools/isolation_certificate.py`,
`tests/test_staging.py`, `tests/test_isolation_certificate.py`, this document
(staging); `tools/launch_practice.py`, `tests/test_launcher_safety.py`,
`docs/RUNTIME_LAUNCHER.md` (launcher); `tools/practice_host.py`,
`docs/PRACTICE_HOST.md` (host). Architecture authority remains
`docs/INTEGRATION_PLAN.md` and `docs/PROTOTYPE_GATES.md`; source evidence is
`docs/PLAYABLE_SOURCE_NOTES.md`; the approved certificate split is
`docs/CLAUDE_PROOF_ARCHITECTURE.md`.

## 1. What changed in this repair pass

- **Lovely is pinned, not inherited.** `role_environment` builds the child
  environment from an allowlist (`ALLOWED_ENV_KEYS`) and sets `LOVELY_MOD_DIR`,
  `APPDATA`, `LOCALAPPDATA`, `USERPROFILE`, `TEMP`/`TMP` inside the role root. No
  inherited `Steam*`, `SDL*`, `LOVELY_*` (other than our pin) or `Python*`
  variable, and no inherited `AISP_PROBE_NONCE`, reaches the child. The launcher
  sets a fresh nonce immediately before spawn.
- **Proofs are measured, not self-attested.** `measure_isolation_state` /
  `record_isolation_proof` are the only code path that writes
  `isolation_proof.json`, and caller `extra` is isolated under a `metadata` key so
  it can never overwrite a measured gate field. A hand-written
  `isolation_proof.v1` boolean file is rejected by schema and digest checks.
- **The reusable certificate is two-layer and immutable.** `tools/isolation_certificate.py`
  binds the native layer N (staged exe/Lovely install, guard patches, absent native
  Steam DLLs, environment/`AISP_*` names, staging/role/live roots) and the Mods
  layer M (per-role Mods tree, MP guard, network-suppression hashes, loopback
  endpoint, pinned server-bind artefact, and a role-parity digest that masks the
  role-specific guard-patch paths so both staged roles must match each other). It
  also binds every isolation-critical
  tool (`staging`, `launch_practice`, `prepare_server`, `practice_service`,
  `practice_host`, the certificate checker). P1a must bind the bootstrap install
  digest equal to **both** role digests. Probe files and raw before/after live
  manifests are copied content-addressed under `staging/evidence/certificate/<id>/`
  and are never overwritten or rebased; a change to M needs a new P1b/full P1, a
  change to N needs a new P1a too. Live *contents* are not compared at check time;
  `check_isolation_proof` only checks the current staged immutable code, tools,
  endpoint and live-root paths.
- **Per-session live diff is separate and revokes.** `snapshot_live` computes a
  full byte manifest of the live install, AppData and every Steam `2379780`
  profile app dir. `record_session_verdict` appends an immutable receipt; any live
  byte difference writes a persistent lockout, revokes the certificate generation
  and stores the before/after manifests. It never auto-restores live from backup.
  `prepare_session` refuses unless the game is verified closed, the certificate is
  valid and not locked out, then rotates stale nonce probes inside staging only,
  declares no mutable paths (`config.lua` stays canonical and fully hashed) and
  mints a fresh nonce.
- **Pre-run and post-run gates are separate.** `check_bootstrap_preflight` is the
  PRE-run gate (manifest, patch binding, absent stale probes, no native Steam
  DLLs, correct paths/Mods). `check_bootstrap_evidence(staging_root,
  expected_nonce, spawn_time)` is the POST-run gate: it parses each probe's
  `key=value` fields exactly and requires the per-run nonce, the patch id, a
  probe mtime after the spawn and an exact save directory. Substring checks are
  gone.
- **Steam absence is no longer vacuous (NH1).** The old guard probe ran *before*
  `G:start_up()`, so `G.STEAM` was always nil there. The Steam-disable regex
  payload now writes a nonce-bound `steam_patch_applied` marker
  (`aisparring_probe_steam_marker.txt`) at the patched block, and a second probe
  placed after the Steam block and before `love.mouse.setVisible(false)`
  (`aisparring_probe_steam_post.txt`) records the real `G.STEAM` and
  `package.loaded.luasteam`. `collect_role_probes` requires both to be `nil`
  *and* the patch marker. The phase owner collects the actual Lovely `main.lua`
  dump and log from the exact staged `Mods/lovely/{log,dump}` as certificate
  evidence; `check_lovely_evidence` binds those exact paths and their freshness.
- **`check_steam_guard` is static-only (NM5).** It binds the staged patch hash,
  the marker/probe presence and absent native DLLs, and never reads the mutable
  `isolation_proof.json`. `check_steam_probes` is the fresh real-probe checker for
  the appropriate caller; the immutable certificate remains the launch gate.
- **Network guards key on manifest id and content, not folder names (NM4).**
  `scan_network_suppressions` refuses any staged `.lua` that still contains an
  un-suppressed `https_updater_thread:start()`,
  `tcp:connect("localhost", 53153)`, `M.request`/`M.asyncRequest` or the SMODS
  HTTPS fallback loaders, and requires known network manifest ids (`Handy`,
  `Steamodded`/`SMODS`) to carry their suppression markers. No mod is blocked
  merely by its name.
- **Exact staged paths.** The guard probe's `lovely_mod_dir`/`mods` and the MP
  probe's `mods` must equal the exact staged `Mods` path, not merely sit under the
  role root. The compressed saved `config/Multiplayer.jkr` is reported as
  `opaque` rather than being read as plaintext proof; the pre-thread MP guard on
  the staged `core.lua` source is the real control.
- **`hash_tree` fails closed.** A link/junction anywhere in the walk and any
  unreadable `stat` now raise (`hash_reparse_refused` / `hash_stat_failed`)
  instead of being silently skipped. `write_json`, `disable_mod_by_lovelyignore`
  and the staged/backup writers take a specific root and go through
  `assert_safe_write`.
- **The role tree is fully manifested.** `STAGING_POLICY` now hashes `install`,
  the whole `Mods` tree and the guard metadata, excluding only the mutable runtime
  output `Mods/lovely/log` and `Mods/lovely/dump` (and the manifest itself). The
  old `appdata` exclusion that hid the entire Mods tree is removed.
- **Multiplayer is found by manifest id and guarded before it starts.** The
  staged `.env` is written into the unique mod whose JSON declares
  `"id": "Multiplayer"` (never a guessed folder), the staged `config.lua`
  fallback is rewritten to loopback, the staged saved `config/Multiplayer.jkr` is
  checked, and an early Lovely patch on `=[SMODS Multiplayer "core.lua"]` errors
  before `MP.NETWORKING_THREAD:start` unless `MP.ENV` holds `127.0.0.1` and the
  expected port.
- **Network-capable staged mods are suppressed deterministically.** Handy's
  updater thread start is replaced with inert stubs (Handy's core UI and
  collection are preserved), SMODS `M.request`/`M.asyncRequest` fail closed and
  the SMODS debug-socket connect is disabled in the staged copies only. A
  `network_guards` check re-detects the markers and binds their hashes.
- **Path controls.** Every staged write goes through `assert_within` plus
  `assert_no_links(staging_root)`, so a pre-existing junction inside `staging/`
  cannot redirect a write into the live tree.
- **Overlap uses explicit roots.** `live_roots` accepts the real install, the
  known-folder AppData (independent of a redirected child `APPDATA`), every Steam
  userdata profile and custom Steam libraries from `libraryfolders.vdf`.
- **The dead Steam shim module is gone.** There is no standalone `steam_guard.lua`
  claiming to intercept `require("luasteam")`. Steam is disabled by the real early
  Lovely patch (`G.STEAM = nil`); `check_steam_guard` binds that patch's hash and
  marker statically, and `check_steam_probes` proves the post-block
  `G.STEAM`/`package.loaded.luasteam` absence from fresh probes.

## 2. Verified static facts (read-only citations)

- Install `C:\Program Files (x86)\Steam\steamapps\common\Balatro`, Mods
  `C:\Users\ginom\AppData\Roaming\Balatro\Mods`, versions Steamodded `26.829.0`,
  Lovely `0.10.0`, JokerDisplay `2.0.4`, Handy `2.0.6` (`docs/MILESTONE_0.md:7-12`).
- LÖVE 11.5 on Windows resolves the save directory via `_wgetenv(L"APPDATA")` in
  `Filesystem.cpp`, so the per-role `APPDATA` redirect is the intended control.
  This is **not** SDL's `SDL_GetPrefPath`; SDL behaviour must not be used to infer
  LÖVE behaviour. The source-based rationale is in
  `docs/PLAYABLE_SOURCE_NOTES.md:7`; the actual installed-binary
  `love.filesystem.getSaveDirectory()` proof is still pending.
- Lovely 0.10.0 selects Mods through `LOVELY_MOD_DIR` or `--mod-dir`, with logs
  under `lovely/log` in the selected tree. This is now confirmed against the real
  source checkout at `../../work/lovely-source` (outside the repo):
  `crates/lovely-core/src/lib.rs:110` reads the `LOVELY_MOD_DIR` env var and
  `:141` parses the `--mod-dir` argument (`docs/PLAYABLE_SOURCE_NOTES.md:6`). The
  staged probe therefore requires the exact staged `Mods` path, and the launcher
  owner additionally passes `--mod-dir <role Mods>`.
- `love.load` order: `G:start_up()` (`work/reference/game/main.lua:87`) then the
  Windows/macOS Steam block (`:88-114`) that requires native `luasteam`.
- The save thread reads `CHANNEL = love.thread.getChannel("save_request")`
  (`work/reference/game/engine/save_manager.lua:12`).
- Multiplayer reads `MP.path .. "/.env"` once (`work/reference/mp/core.lua:72-97`)
  and starts its thread at `MP.NETWORKING_THREAD:start(server_url, server_port)`
  (`core.lua:349`), falling back to the SMODS config default
  `balatro.virtualized.dev` (`config.lua:4`).
- Handy starts its updater thread unconditionally
  (`work/reference/offline/handy-updater.lua:1-8`) and waits on it at quit
  (`:363-366`). SMODS logging opens `localhost:53153`
  (`work/reference/offline/smods-logging.lua:4-15,56`); SMODS HTTPS is
  `M.request`/`M.asyncRequest` (`work/reference/offline/smods-https.lua`).
- Steamodded disables a mod when `<Mods>/<name>/.lovelyignore` exists
  (`work/reference/smods-loader.lua:337-344,412-419`).
- Lovely patch TOML format is confirmed from the shipped Multiplayer patches and
  SMODS booster patch: `[manifest]` plus `[[patches]]`
  `[patches.pattern]`/`[patches.regex]` with `target`, `pattern`, `position`,
  `payload`, optional `match_indent` and `times`; SMODS sources are targeted as
  `=[SMODS <Mod> "path"]`.

## 3. Implemented staging surface

`tools/staging.py`:

- two role trees `staging/roles/{human,ai}` and a separate `staging/bootstrap`
  tree, all with isolated `appdata/{Roaming,Local}`, `userprofile`, `temp`,
  `logs`, `ipc`;
- install copy omitting `steam_api64.dll`/`luasteam.dll`, excluding `Mods`,
  `*.jkr`, `*.log`, `.env`;
- `role_environment` / `role_environment_overrides`: allowlisted environment with
  explicit `LOVELY_MOD_DIR` and `APPDATA` inside the role root;
- `hash_tree` / `build_manifest` / `verify_manifest` with prefix-scoped policies:
  `STAGING_POLICY` (install + Mods + guard metadata, minus `lovely/log`,
  `lovely/dump`), `BOOTSTRAP_POLICY` (same plus the bootstrap expectations);
- `find_links`/`assert_no_links` (symlink + reparse-point refusal),
  `assert_within`/`_write_text`/`_ensure_dir` before every staged write, and
  `assert_no_overlap` over explicit `live_roots` (install, known-folder AppData,
  every Steam userdata profile, custom Steam libraries);
- `find_multiplayer_mod` (by `"id": "Multiplayer"`), `configure_role_endpoint`
  (writes `.env`, rewrites the staged `config.lua` fallback, checks the saved
  `config/Multiplayer.jkr`, adds the MP pre-start guard), `read_persisted_endpoint`,
  `verify_staged_endpoints`;
- `suppress_staged_network_paths` / `scan_network_suppressions` /
  `check_network_guards`: deterministic staged-only suppression of Handy's updater
  thread start, SMODS HTTPS and the SMODS debug socket, with re-detection and hash
  binding;
- real Lovely patch generation (`render_lovely_toml`, `staging_patches`): a Steam
  block removal regex, a crash-report disable regex, a nonce-bound startup guard
  inserted before `G:start_up()`, a save-thread probe after the `save_request`
  channel line, an optional bootstrap self-exit and the Multiplayer pre-start
  guard;
- `write_steam_guard` writes only the real patch plus honest metadata (`shim:
  false`); there is no dead Lua guard module;
- `check_steam_guard` is a **static** staged guard over the patch hash, the
  `steam_patch_applied` marker and both Steam probes, with absent native DLLs; it
  never reads `isolation_proof.json`. `check_steam_probes` is the fresh real-probe
  checker (nonce-bound marker plus absent `G.STEAM`/`package.loaded.luasteam`);
- `steam_disable_payload` / `steam_post_probe_payload` generate the NH1 marker and
  post-block probes; `lovely_evidence_paths` / `check_lovely_evidence` bind the
  exact staged `Mods` path and fresh `Mods/lovely/{log,dump}` artefacts;
- `stage_bootstrap`, `check_bootstrap_preflight`, `check_bootstrap_evidence`,
  `collect_role_probes`, `_read_probe_entry`, `parse_probe`;
- `measure_isolation_state` / `record_isolation_proof` / `check_isolation_proof`:
  the measured before/after collector, the per-session proof writer, and the
  host-facing wrapper that delegates to the reusable certificate check;
- `stage_role` / `finalize_role` / `verify_staged_role`: per-role manifest gate
  over the immutable install, the complete Mods tree and the guard metadata, with
  no native Steam DLLs and no links;
- `disable_mod_by_lovelyignore`, `find_steam_userdata_apps`,
  `discover_steam_libraries`, `known_folder_roaming_appdata`, `steamapps_parent`
  (only infers `install_steamapps` for a real `steamapps/common/<game>` layout),
  `SESSION_DESCRIPTOR_VARS` (canonical, mirrors `launch_practice.SESSION_ENV_KEYS`),
  `launcher_attestation_path` and the `write_launcher_attestation` wholesale wrapper;
- `assert_no_reparse_between` / `assert_safe_write`: lexical containment plus a
  link/reparse-point check on the **unresolved** path components, run before every
  staged write/copy so junction evidence is not lost to `.resolve()`.

`tools/isolation_certificate.py` (Section 10): `collect_layer_n` /
`collect_layer_m`, `build_certificate` / `check_certificate` (immutable two-layer
generation plus bound tools/evidence), `snapshot_live`,
`prepare_session` / `record_session_verdict`, `lockout` / `read_revocations`.

`tools/launch_practice.py` (Worker B): role/bootstrap plans with fail-closed
gates, Job-Object/Popen-handle ownership, exact create-time identity, staged-exe
binding, containment-checked cleanup, copy-vs-source verified backups over all
Steam profiles, and a fresh-nonce spawn. See `docs/RUNTIME_LAUNCHER.md`.

## 4. Bootstrap contract (the next real step)

`stage_bootstrap` builds a minimal Steam-disabled tree: vanilla + Lovely injector
only, one generated Lovely patch, and no Multiplayer/SMODS/Handy. The run is:

1. **Preflight** (`check_bootstrap_preflight`): bootstrap manifest and patch hash
   verified, no stale probe files present, no native Steam DLLs, correct
   save/Mods paths.
2. **Run** with a fresh `AISP_PROBE_NONCE` in the allowlisted child environment.
   The guard verifies `love.filesystem.getSaveDirectory()` and `LOVELY_MOD_DIR`
   before `G:start_up()`, writes `aisparring_probe_main.txt` and
   `aisparring_probe_guard.txt` from the main thread and
   `aisparring_probe_save_thread.txt` from the save thread. The Steam-disable
   payload then writes the nonce-bound `aisparring_probe_steam_marker.txt`, the
   post-block probe writes `aisparring_probe_steam_post.txt` with the real
   `G.STEAM` and `package.loaded.luasteam`, and the run exits on its own.
3. **Evidence** (`check_bootstrap_evidence` with the nonce and spawn time): all
   five probes parse exactly, carry the nonce and patch id, were written after the
   spawn, name the exact staged save directory, the marker reports
   `steam_patch_applied=true`, and the post-block probe reports both `steam=nil`
   and `luasteam=nil`. `check_lovely_evidence` additionally requires a fresh log
   and `main.lua` dump under the exact staged `Mods/lovely/{log,dump}`.

`measure_isolation_state` before/after plus `record_isolation_proof` writes the
measured per-session `isolation_proof.json`, which requires zero live diff and
unchanged staged immutables. The reusable certificate (Section 10) is built
separately from explicit P1a/P1b/full-P1/crash/P2 evidence and stays partial until
all of it is present.

## 5. Gate status

| Gate | Requirement | Status |
|---|---|---|
| P0 | game closed, hash backups incl. all Steam userdata, staged-only, loopback `.env`, MP guard | code complete; **not run** |
| P1.1 static | document save/profile/Mods/log/Steam resolution | **done** (Section 2) |
| P1a bootstrap | staged no-MP run, nonce-bound probes, zero live diff, positive Steam isolation | **code complete, evidence absent → blocked** |
| Certificate | two-layer N/M certificate over staged code, tools, evidence copies; partial without crash/P2 | **code complete, no real evidence → partial** |
| P1b/P2–P5 | staged MP, dead-port, parity, observation/action, hygiene | untouched |

## 6. Unresolved questions (remaining)

1. **Actual bootstrap proof.** Whether the child `APPDATA` redirect yields the
   expected `getSaveDirectory()` for a fused `Balatro.exe`, and whether Lovely
   reads the same tree for `LOVELY_MOD_DIR` and `lovely/log`.
2. **Lovely patch application timing.** Whether a `[[patches]]` entry targeting
   `main.lua` (or `=[SMODS Multiplayer "core.lua"]`) applies before the target
   executes, and whether a non-matching pattern only warns. The runtime guard
   fails closed, but runtime application is unproven.
3. **Lovely Mods selection is source-verified; runtime application is not.**
   `../../work/lovely-source/crates/lovely-core/src/lib.rs:110` reads
   `LOVELY_MOD_DIR` and `:141` parses `--mod-dir`, so the staged redirect and the
   launcher's `--mod-dir` argument are grounded in the real source. What remains
   unproven is the *installed-binary* behaviour: that the fused `Balatro.exe`
   actually honours both and writes a fresh log/dump under the exact staged
   `Mods/lovely` tree (collected as P1a evidence by the phase owner).
4. **Steam userdata location and safety.** The app directory is machine-specific;
   the launcher discovers all numeric profiles containing app `2379780`. Whether
   Steam re-injects/writes for a second staged instance is unproven.
5. **Suppression fidelity.** The Handy updater stub and the SMODS HTTPS/debug
   suppressions are validated offline against the reference snapshots; whether
   the installed mod versions match those snapshots still needs a real staged run
   (the `network_guards` gate binds the staged hashes).
6. **Save-thread probe semantics.** Whether the save thread's `love.filesystem`
   exposes the same save directory and can write the probe before the bootstrap
   exits.

## 7. APIs / evidence still needed

- LÖVE: runtime `love.filesystem.getSaveDirectory()` from main and thread.
- Lovely: patch application ordering and `LOVELY_MOD_DIR` logging behaviour;
  source checkout (missing here).
- Steam: `userdata/<id>/2379780/remote` cache state, `loginusers.vdf`,
  `appmanifest_2379780.acf`; whether native Steam must be running.
- SMODS/Handy: confirmation that the installed versions match the suppression
  targets.

## 8. Running the tools

```
python tools/staging.py stage --install "<install>" --staging-root staging --mods-source "<Mods>" --port 8788
python tools/staging.py verify --staging-root staging
python tools/staging.py bootstrap --install "<install>" --staging-root staging
python tools/staging.py bootstrap-preflight --staging-root staging
python tools/staging.py bootstrap-verify --staging-root staging --nonce "<nonce>" --spawn-time <epoch>
python tools/launch_practice.py plan --staging-root staging --backup-root backups
python tests/test_staging.py
python tests/test_isolation_certificate.py
```

`stage`/`bootstrap` write only inside the gitignored `staging/` tree.
`plan`/`bootstrap` without `--execute` are read-only and report the blocked
gates. `backup --execute` requires the game closed and writes a hash-manifested
copy under the gitignored `backups/` tree. `launch`/`bootstrap --execute` refuse
until the P1 evidence and backups exist.

## 9. Architecture decision: no concurrent-live mode in this slice

Keeping normal Balatro open at its menu stays a separate, later mode. The
closed-game requirement remains mandatory for bootstrap, P1a/P1b, full P1, any
copying from live, backups and installing the companion. The smallest safe
transition is the reviewer-proposed one: the live menu asks the user to confirm
"Quit Balatro and start practice?", the live game quits through its own normal
quit path, and a separately started external launcher waits for that exact live
PID to exit naturally (timeout aborts, never kills it) before re-running every
closed-game gate.

## 10. Certificate and per-session API (host integration)

All entry points below are also re-exported as thin wrappers on `staging`
(they lazy-import `isolation_certificate`, so `import staging` stays cycle-free).

| API | Purpose |
|---|---|
| `isolation_certificate.bound_tool_specs()` | the bound tool set: `staging`, `launcher`, `prepare_server`, `practice_service`, `practice_host`, `certificate_checker` |
| `isolation_certificate.collect_layer_n(staging_root, live=None)` | measured native layer N |
| `isolation_certificate.collect_layer_m(staging_root, live=None, server_bind=None)` | measured Mods layer M |
| `isolation_certificate.build_certificate(staging_root, *, phases, live=None, port=None, server_bind=None, tools=None, extra=None)` | validate explicit measured phase evidence and publish an immutable generation; returns `status: "partial"` (unpublished) when anything is missing, including crash/P2 |
| `isolation_certificate.check_certificate(staging_root, live=None, port=None)` | recompute N/M/tools/evidence/endpoint/live-roots; never compares live contents |
| `staging.check_isolation_proof(staging_root, live=None, roles=...)` | host-facing wrapper the launcher/host already call |
| `staging.check_steam_guard(staging_root, role, live=None, proof=None)` | static staged Steam guard (patch hash + marker/probes + absent natives); ignores `live`/`proof`, never reads the mutable proof |
| `staging.check_steam_probes(staging_root, role, expected_nonce, spawn_time)` | fresh real-probe checker: nonce-bound marker + absent `G.STEAM`/`package.loaded.luasteam` |
| `staging.check_lovely_evidence(staging_root, role, spawn_time, expected_mods=None, require_dump=True)` | exact staged `Mods` binding plus fresh `Mods/lovely/{log,dump}` artefacts |
| `isolation_certificate.snapshot_live(live, *, label=None)` | full byte manifest of live install + AppData + every Steam `2379780` profile app dir (never the whole Steam install) |
| `isolation_certificate.prepare_session(staging_root, *, live, session_id, port=None, nonce=None, closed_check=None)` | closed-game prep: certificate + not-locked-out + rotate stale probes **and any previous attestation** (safe staging writes) + fresh nonce; requires a real `closed_check` callable |
| `isolation_certificate.record_session_verdict(staging_root, *, session_id, before, after, backup_id=None, certificate_id=None)` | append-only receipt; live byte diff -> persistent lockout + revocation + stored before/after manifests |
| `isolation_certificate.write_launcher_attestation(staging_root, *, session_id, nonce, content_hash, control_port, spawn_time, port=None)` | re-verify **both** roles' probes, then write the fixed session-bound attestation to `<role save root>/aisparring-launcher-attestation.json` (outside Mods) via staging safe writes |
| `isolation_certificate.launcher_session_env_names()` | the exact session-descriptor env names derived from the real `launch_practice.SESSION_ENV_KEYS` (no speculative aliases) |
| `isolation_certificate.rotate_attestation_files(staging_root)` | remove any previous session's attestation inside staging only |
| `isolation_certificate.lockout(staging_root)` / `certificate_status(staging_root)` | persistent lockout and generation/revocation status |
| `isolation_certificate.read_revocations(staging_root)` | append-only revocation log |

Environment names are frozen to the real launcher descriptor
(`docs/PLAYABLE_WIRING_CONTRACT.md`): layer N binds the *names* of the
`role_environment_overrides` (including `BALATRO_AI_ROLE`, `LOVELY_MOD_DIR`,
`APPDATA`) plus the exact `launch_practice.SESSION_ENV_KEYS` values
(`AISP_SESSION_ID`, `AISP_ROLE_CREDENTIAL`, `AISP_CONTROL_PORT`,
`AISP_CONTENT_HASH`, `AISP_PROBE_NONCE`, `AISP_EXPECTED_ROLE_SAVE_ROOT`,
`AISP_EXPECTED_ROLE_MODS_ROOT`, `AISP_MODE`, `AISP_DIFFICULTY`, `AISP_PACING`,
`AISP_GAUNTLET`). No conflicting aliases (`AISP_ROLE`, `AISP_EXPECTED_SAVE_DIR`,
`AISP_EXPECTED_MODS_ROOT`, `AISP_EXPECTED_MOD_ROOT`, `AISP_SEED`) may be bound; if
the launcher is unavailable the certificate is refused, not guessed. The host
writes the session-bound attestation only after both roles' probes verify;
`prepare_session` rotates any previous attestation inside staging before launch.

`phases` keys are `P1A`, `P1B`, `FULL_P1`, `CRASH`, `P2`. Each bundle carries a
session `nonce`, a `spawn_time`, a `measured` mapping of real digests/flags and an
`evidence_files` mapping of probe/manifest files to copy. `P1A.measured` must hold
equal `bootstrap_install_digest` and `role_install_digests`; `FULL_P1.measured`
requires equal `live_before_digest`/`live_after_digest`; `CRASH` requires
`crash_observed` and `cleanup_ok`; `P2` requires `dead_port` and `refused`. A bare
`{"passed": true}` bundle fails validation. There is deliberately **no rebase
API**: historical certificate evidence is immutable, and recovery requires a new
P1 run that produces a new measured generation.

## 11. Sources

- `docs/PLAYABLE_SOURCE_NOTES.md` (LÖVE `_wgetenv(APPDATA)`, Lovely
  `LOVELY_MOD_DIR`/`lovely/log`, `G:start_up` ordering, Handy/SMODS audit).
- `docs/INTEGRATION_PLAN.md`, `docs/PROTOTYPE_GATES.md`, `docs/MILESTONE_0.md`.
- `work/reference/game/{main.lua,conf.lua,engine/save_manager.lua}`.
- `work/reference/mp/{core.lua,config.lua,lovely/*.toml}`.
- `work/reference/offline/{handy-updater.lua,handy-updater-thread.lua,smods-https.lua,smods-logging.lua,luajit-curl.lua}`.
- `work/reference/smods-loader.lua`, `work/reference/smods-booster.toml`.
- `../../work/lovely-source/crates/lovely-core/src/lib.rs:110,141` (LOVELY_MOD_DIR
  and `--mod-dir`; outside the repo, read-only).
