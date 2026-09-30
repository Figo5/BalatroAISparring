# Native staged test progress — September 28

The user closed Balatro before this test pass. Fresh process checks and hash-verified backups preceded actual staging and launches. The live installation, Mods and saves were not modified. Native artifacts and proprietary dumps remain in ignored local staging/work directories, outside Git.

| Phase | Actual result |
|---|---|
| P1A bootstrap | Passed; process exited; zero changed live roots. Receipt `7b66edf1800f5cfc932c7466ba82e33ae27cf0f3c9a4df1e7ff86587be9ed271`. |
| P1B Multiplayer load | Passed for both staged roles; owned processes ended; zero changed live roots. Receipt `0393150ffd20b8799d9db916e9e91487931338e883cc9ab457e48ec8b29d59d4`. |
| FULL_P1 | Refused before process creation: staged role manifest mismatch. |
| CRASH and P2 phases | Not started. |
| Match/gameplay/install | Not started. |

The expected patched socket dump was observed in both real staged roles at `Mods/lovely/dump/SMODS/Multiplayer/networking/socket.lua`.

## Concrete failure and repair

After the first real Multiplayer load, Lovely regenerated its separate **unpatched** `Mods/lovely/game-dump` cache. The immutable role manifest treated that cache as source. Both roles gained generated Multiplayer `core.lua` and `networking/socket.lua` entries and lost a generated Handy updater entry. No ordinary source-file changes were reported. The next launch correctly failed closed.

The failed session has no open ownership records and no remaining Balatro processes. A fresh backup comparison after the refusal passed with no live changes. The lockout remains recorded for explicit acknowledgement after the correction has passed review.

DeepSeek is correcting only the exact generated cache classification. Live snapshots/backups must remain complete, ordinary mod sources must remain immutable, and the separate fresh **patched** dump evidence remains mandatory. Native tests pause for independent checks and Claude review of this fix.

Astra independently verified the fix with 52/52 staging cases, 52/52 certificate cases, 48/48 installer cases and three backup/session contracts. An additional independent boundary check reproduced the failure before the patch, then passed across Mods, staged-role and bootstrap policies: generated-cache rewrites are ignored only in the exact output location, three source-change cases remain detectable, and complete backups still contain cache files. Tested source and suite hashes remained unchanged through these runs. Claude review remains pending.

## Build coverage correction

The first staging pass copied the existing installed mods but omitted the new companion package. Astra caught this before any match or installation. The verified `0.1.0-dev` package is now prepared in ignored `work/aisparring-package`; it has not been installed or copied into the staged roles yet. The final staged role trees will include its exact packaged bytes before repeating the phase measurements. Earlier receipts will remain diagnostic history, not proof for changed tools or mod contents.

## Fresh companion build pass

Cache correction `cebd74e` passed Claude review (`CLAUDE_NATIVE_GAME_DUMP_REVIEW.md`) and Astra acceptance. The earlier lockout was explicitly acknowledged with its cause, and the full old staging tree and receipts were preserved in ignored `work/native-baseline-staging-20260928`. A fresh backup and new trees at the same staging root were then prepared. Both staged companion copies match package digest `988f3ef7932254e3376938ddd0e3213bd81a3092cb1bbcdb498803e5ece5f67c`.

| Fresh phase | Receipt / status |
|---|---|
| P1A | Passed: `f6360118659b1fbed402ac2037334b1773f6f09bcf0c605b776c176412b7798e` |
| P1B | Passed: `f24f04b1ca6bac81367525ab44935cdd6c096d77ed9688affb6789089a5b355c` |
| FULL_P1 | Passed: `822088ab217ef799bae44676434da4ad51bb3f877f308d16659ea9ec46027155` |
| CRASH | Passed: `ccdc71e443b0c5ac4bf3228e17c12c4a58e7bbb7b4c998cd26b79380a14641aa` |
| P2_INITIAL | Tool returned success, but Astra rejected phase compliance: both roles launched instead of AI-only. Receipt `a124ad57d85d6639d00b3c7a28ba5e6949c2625ea6e920c1f4e72f0eafb2d5a7` must not be used for acceptance. |
| P2_CLOSE / P2_SILENT | Not started; paused for exact phase-role repair. |

All completed runs reported zero changed live roots and all owned processes exited. After P1B both immutable role manifests passed with no additions, changes or missing files, proving the cache correction against real Lovely output. The companion loaded and detected Multiplayer 0.5.5; its match functionality stayed inactive in the absence of match descriptors during measurement, as intended.

The P2 defect is concrete: `execute_launch` reloads the prepared phase but rebuilds a two-role plan without restricting its actual spawn set. The receipt declares `roles=[ai]` yet contains both `human` and `ai` PID keys. This could let the human role take the one-connection listener in subsequent phases. DeepSeek is repairing actual spawn selection and receipt validation to enforce the existing AI-only design. No architecture substitution, listener test, match, live installation or live-file write occurred. Native measurements pause for independent checks and Claude review; changed tool bindings require fresh evidence.

## P2 role repair — accepted September 28 (evening)

Codex reached its usage limit mid-verification; Claude Code (Opus 5.5) resumed orchestration from the uncommitted DeepSeek repair. The repair derives the spawn set only from the reloaded prepared phase (`expected_roles_for_phase`, `_restrict_plan_to_roles`) and binds receipts to exactly one retained process per expected role at record time (`_session_role_bindings`) and at every revalidation (`_receipt_role_problems`).

Independent rerun on the final tree (`work/p2fix-verify-2308.txt`): launcher 64/64, certificate 57/57, measurement lifecycle 11/11, P2 observer 6/6, staging 52/52, installer 48/48, host 87/87, plus `astra_p2_role_receipt_boundary.py`, `astra_p2_retained_identity.py`, `astra_certificate_attacks.py` and `astra_measurement_claims.py` all passing. Re-validating the rejected native receipt `a124ad57…` now returns `P2_INITIAL_receipt_owned_roles_mismatch`; it is kept as diagnostic history and never passed as a receipt ID.

Claude Opus 5.5 High actual-diff review (`CLAUDE_NATIVE_P2_ROLE_REVIEW.md`): **ready for controlled native P2**, no Critical/High/Medium findings. Evidence-reuse decision: receipts do not bind tool hashes (the certificate binds them at issuance), the repair leaves P1A (bootstrap-only) and P1B/FULL_P1/CRASH (human+AI, same order) launch behaviour unchanged, adds only stricter recording/validation, and changes no staging, Lua patch or mod bytes. The fresh receipts P1A `f6360118…`, P1B `f24f04b1…`, FULL_P1 `822088ab…` and CRASH `ccdc71e4…` are therefore retained and re-validated by the current validator at prerequisite and certificate time; only P2_INITIAL, P2_CLOSE and P2_SILENT are regenerated, with no staging-tree or mod changes before those reruns. This narrows the earlier blanket "changed tool bindings require fresh evidence" note for this specific repair only.

## Native P2 reruns after f643fac

| Phase | Result |
|---|---|
| P2_INITIAL | **Passed.** Receipt `f8a21e3fd0a254ccdc402962534f472ae0848eebd46df2305e9f874858411a82`. Exactly one owned staged AI (`staging\roles\ai\install\Balatro.exe`, PID 12124); independent 500 ms sampler saw no other Balatro process. Dead port proven, first connect refused, zero live changes. |
| P2_CLOSE | **Passed.** Receipt `3e782e8792c56e1a202a0bc0f54308971b080128e3180d903efd978f9365187e`. One owned AI (PID 20840) was the accepted listener peer (`peer_is_owned_ai=true`), zero bytes sent, FIN then receive error then one exhausted bounded retry cycle; `closure_path=keepalive_fallback`. Zero live changes. |
| P2_SILENT (first) | **Refused**, `P2_coverage_incomplete:keepalive`; lockout raised. Isolation held (one owned AI PID 8616, zero live changes). Root cause: the classifier required zero receive errors for the whole run, but the pinned Multiplayer packet coroutine performs one more `receive()` on the failed replacement client a tick after the exhausted keepalive cycle (`Socket is not connected`, +52 ms). Evidence preserved in `work/native-p2-silent-refused/`. |

Correction: SILENT now refuses any receive error at/before the exhausted keepalive cycle's end and ignores only finite, strictly later errors; every other F1–F4 condition is unchanged. DeepSeek implemented; orchestrator hardened non-finite times and added tests; Claude Opus 5.5 High review `CLAUDE_NATIVE_P2_SILENT_REVIEW.md`: ready to rerun, no Critical/High/Medium. Independent live snapshots before and after all three runs: 982 live AppData files (Mods + saves) and 15 install files byte-identical.

| Phase | Result |
|---|---|
| P2_SILENT (rerun after `1a13b97`) | **Passed.** Receipt `6cbec6bc1a0613dcb2438091273d9bd7637229f634fe2dfb3844bf3e89a915ac`. Lockout `7faa8a7f…` acknowledged first with cause and evidence (`work/native-p2-silent-lockout-ack.json`); the refused session was not promoted. One owned staged AI (PID 23432) was the accepted listener peer; zero bytes sent, no tool close/FIN, five keepalive pushes, one exhausted keepalive cycle, `covered=["keepalive"]`. This run recorded no post-cycle receive error, consistent with the review's note that it is expected but not guaranteed. |

Sampler note: the independent sampler for this rerun recorded no rows because the previous run's `.stop` file had not been removed (operator error). Substitute independent evidence: the human staged role's newest Lovely log is 19:28 local (the rejected pre-fix P2_INITIAL); since the fix only AI-role logs were created, one per P2 run (23:18, 23:20, 23:23, 23:51 local). Samplers for P2_INITIAL and P2_CLOSE each saw exactly one staged AI `Balatro.exe`.

**All seven required phases now hold valid receipts** under the current validator: P1A `f6360118…`, P1B `f24f04b1…`, FULL_P1 `822088ab…`, CRASH `ccdc71e4…`, P2_INITIAL `f8a21e3f…`, P2_CLOSE `3e782e87…`, P2_SILENT `6cbec6bc…`. No lockout, no open session. Independent snapshots before the P2 reruns and after the final SILENT run: live AppData (982 files incl. Mods and saves) and install (15 files) byte-identical.

## First real staged matches and re-certification (September 29)

Certificate `fcee4a95…` was issued from the seven receipts above. Three real staged MATCH runs then went through the production practice host (`work/dev_match.py`; the only substitution is the live-exit trigger, which uses a PID confirmed absent because the companion is not yet installed live). Each run passed every gate, took a fresh backup, opened the certificate record, started the pinned local server, launched and attested both staged roles, then aborted safely with `practice_prestart_timeout`. Both clients left through ordinary `leaveLobby`, and each session record closed with a measured `passed` verdict (zero changed live roots).

Root cause (service op trace + human Lovely log): the companion send guard treated Multiplayer's initial `MP.LOBBY.is_host = false` as "not host" and blocked the human's own first `createLobby`, so no lobby ever existed. Fixed in `e1e8a16` (Claude review `CLAUDE_MP_DRIVER_HOST_GUARD_REVIEW.md`). Because this changes staged companion bytes, the old staging tree and package were archived (`work/archive-staging-e1e8a16`, `work/archive-package-e1e8a16`), and the full build was repeated fresh: backup, bootstrap, role staging, package, placement, all seven phases with a fresh backup before each.

| Phase (build `e1e8a16`) | Receipt | Processes |
|---|---|---|
| P1A | `9de06ff15fde0897dcdb45f2c30f9fe2dc8dbd4a77b6ef13ec2e4debdf0b2650` | bootstrap only |
| P1B | `bc3d4ad10f58a7f831576ca8a227ba8669326c524bc021427b9d70eacd3ae909` | human + ai |
| FULL_P1 | `0c4edc94f85e5e50c8f4e4be05166546fb3b82f1e8735b07cfe62d6b455db5d9` | human 21372 + ai 20412 |
| CRASH | `037063dbb312566f02c213e75a1753e1f86a871a0bf41278448712362d135a95` | human 18724 + ai 2468 |
| P2_INITIAL | `06a2df042d428179e4827f104515db6807128bd2b6c7e8cd064d3a3f6482dae1` | ai 16320 only |
| P2_CLOSE | `666640f309fef41cba485767ed13d48cdff0ac8119d4240269445bbdceec0382` | ai 13468 only |
| P2_SILENT | `d470d2a88921ca90ec47c31e66ea08cbba2345b92b8a918b8f0cb1e42cd070ed` | ai 10584 only |

All receipts recorded with zero changed live roots. The run was interrupted once after P1B when the previous orchestrator session ended; no open record or lockout remained, P1A/P1B revalidated, and it resumed from FULL_P1. The independent sampler (`work/procs-recert-resume.csv`) saw only staged `Balatro.exe` images, one AI process per P2 phase. **Certificate `ab7e1fcc1db3ef41cfa47cd1d43b0728da4db096072605a6c9923f0783c2190d`: complete; check passes.**

## Unlock-popup fix, re-certification and match 10 (September 29 evening)

**Cause of the remaining pre-start stalls (match 9, build 57fb6f4 + diagnostics).** The human role's own log showed Balatro's Blue Deck unlock popup (`create_unlock_overlay`, "Discover at least 20 items") opening on the main menu, then `menu_not_ready detail="st=1/11 ui=0 p=1 ov=1 T=13.9"` until the 90 s abort. The popup pauses the game, so the deferred main-menu UI event never fires on an unattended role, and the lobby is never created. `Game:start_run` queues the same popups, so the AI could also freeze mid-match.

**Fix `c33bab6`.** `mp_driver` identifies only the vanilla unlock popup: the back element is `overlay_menu_back_button` with `button == 'continue_unlock'`. It dismisses the popup through the real `G.FUNCS.continue_unlock`. The runtime policy is:
- The AI dismisses always.
- The human dismisses only before its match starts, after an 8 s grace so an attended user can read it.
- At most one attempt per 0.5 s, 32 successes and 64 attempts.
- 20 s of continuous blocking ends in a clean `unlock_overlay_stuck` stop.
- No coordinator step and no AI decision happen while a popup is up.

The commit includes the reviewed coordinator diagnostics. The Claude Opus 5.5 High review cycle was READY, then BLOCKED on R1/N1 (a post-cap gate without a bound, and chained human graces), then READY for re-certification (`CLAUDE_UNLOCK_OVERLAY_REVIEW*.md`). Independent reruns: run_runtime 108/108 on lua51 and luajit21, and all 12 suites green. `test_practice_service` has an intermittent Windows temp-dir teardown race (WinError 145) that is unrelated to this change.

**Re-certification (build `c33bab6`).** The full fresh build (`work/recert-c33bab6`) produced receipts P1B `1465adac…`, FULL_P1 `816c1013…`, CRASH `506c4c88…`, P2_INITIAL `66ea87b6…`, P2_CLOSE `4089f8a7…` and P2_SILENT `6ae88c71…`, plus P1A. **Certificate `e9bc994a51a409a56c6e3f033f685c9ca1aaf25607c4ad75fe45b42f3d7d9a0d`: complete; check passes.**

**Match 10** (session `s-7003a17e…`, rookie, normal pacing, Major League attrition):
- The human popup was dismissed after its grace (`unlock_overlay_dismissed count=1`, then `p=0 ov=0`). The host created the lobby, the AI joined and readied, and the host started the match.
- The AI played Ante 1 small/big/boss and Ante 2 small/big: blind selection, hands, a discard, shop purchases, three boosters with picks, two consumables and leaving the shop. That was **37 accepted decisions, 0 rejected**.
- It then selected the Nemesis (PvP) blind and sent `readyBlind`. The human role's public opponent feed received the AI's location and lives (`loc_ready-bl_mp_nemesis`, lives 4).
- From there the AI correctly waited for its opponent with `policy_no_action` (a backoff wait, not a loop error), because the unattended human never plays. The orchestrator ended the run by sending WM_CLOSE to the staged human window. The host reported `practice_human_exited_before_end`, the AI companion closed (`practice_closed`), and no process, open record or lockout remained.
- Session receipt: `verdict=passed`, `changed_roots=[]`. The independent live snapshot before and after was identical (AppData 983 files, install 15 files).

**Observations for follow-up (not blockers):**
- The service summary counts `policy_no_action` waits in `errors` (33). The adapter could expose the PvP wait as a waiting state instead of polling the policy every ~2.5 s.
- The send guard blocks Handy's `handyMPExtensionDisable` and Multiplayer's `streamLogLines`, which is intended for private practice. Handy/MP compatibility remains an in-game acceptance item.
- The AI does not use the Multiplayer PvP timer against a slow opponent.
- PvP resolution, lives, match end and results cannot be exercised without a human actually playing to the PvP blind. Per AGENTS.md, a full human run is not played by the orchestrator, so this remains for the controlled live smoke with the user.

## Live installation and live smoke (September 29, ~20:15–20:22 ET)

User-approved in chat. Balatro was confirmed closed immediately before each live step.

- **Backup:** fresh verified backup `backups/20260930T001526Z`: AppData 983 files including Mods and saves, install 15 files, Steam userdata 1 file. All three entries re-verified against their manifests.
- **Package:** `work/aisparring-package` `0.1.0-dev`, digest `9bf386381d507730ee89a45b8bc04b582a8d85acb0251d471681ef9dcd5408ee`. The live body is byte-identical to repo `AISparring/` at `c33bab6`, apart from the generated `config.lua` (`role="live"`, discovery path to `work/aisparring-host/practice_host.json`).
- **Install:** acceptance record `work/install-acceptance.json` binds the package digest and certificate `e9bc994a…`. The dry run returned `install_planned`, and `--execute` returned `installed` with receipt `work/install-receipts/aisparring-install-20260930T001746Z-a3877191.json`.
- **Target:** `%APPDATA%\Balatro\Mods\AISparring`. An independent diff against the backup showed the only change was that new folder, identical to the package. The install directory was unchanged.
- **Live smoke:**
  - The practice host daemon was started (`practice_host.py serve --match-port 8788`, loopback, discovery marker written). Live Balatro was launched once through Steam.
  - Lovely log `lovely-2026.09.29-20.18.32.log` showed `bootstrap_ready`, Multiplayer 0.5.5 satisfied and `companion_boot ok` (live role: practice menu and controller installed). There were no errors or tracebacks. The main menu screenshot showed Steamodded, Multiplayer 0.5.5 and "Connected to Service".
  - The `ai_mode_resolved ... ai_gates_not_implemented` line is the legacy M1 resolver logged before the companion boot. It is misleading but harmless (cleanup item).
  - The game was closed normally (WM_CLOSE on the instance launched for the smoke test).
  - Afterwards only the game's own `1/profile.jkr` and `settings.jkr`, a new Lovely log and Steam's `remotecache.vdf` differed from the backup. That is normal launch/exit behaviour; the companion contains no save-writing calls.
  - With the mod installed, the host's pre-acknowledgement start gates (`default_start_gate` with the real certificate API) return `practice_host_ok`.
- **Not verified by the orchestrator:**
  - Clicking **Play → AI Sparring** in the live UI. A synthetic click could not take foreground focus, and no further desktop input was attempted.
  - The live-to-staged hand-off, and any human-played match through PvP, lives and results.
  - These are the user's first playtest.
- **Left running for the user:** practice host daemon (session `host-ffddc17b…`). Restart scripts are `work/aisparring-host/dev/start_practice_host.cmd` and `.ps1`.

## Live menu crash, fix `9f7a8e1` and reinstall (September 29, ~20:25–21:20 ET)

**What happened.** The user clicked **Play → AI Sparring** in the installed `c33bab6` build, and the live game crashed with `game.lua:3036: attempt to index field 'OVERLAY_MENU' (a boolean value)`.
- **Cause:** the menu passed a bare UI definition to `G.FUNCS.overlay_menu`, which expects `{definition = …}`. The UIBox build threw after the engine had set `G.OVERLAY_MENU = true`, the menu's `pcall` hid the error, and the next draw crashed.
- **Why tests missed it:** the fixtures modelled the wrong signature.
- **Immediate action:** the broken build was moved out of live Mods to `backups/installed-c33bab6-AISparring`, after verified backup `20260930T003436Z`.

**Fix.** Three Claude Opus 5.5 High review rounds (`CLAUDE_LIVE_MENU_CRASH_*.md`) also caught these handoff defects:
- The launcher's start gate takes about 40 s (measured), against a 10 s menu ack timeout, so every live start would have failed.
- The launcher's 10 s idle close, combined with process-global LÖVE channel names, meant starts hit a dead connection and a rebuilt worker could replay an old start (H1).

What changed:
- The real overlay signature, with sentinel cleanup.
- A 120 s ack timeout with a modal waiting screen that is never closed before the quit.
- A main-menu re-check on ack.
- A fresh connection with unique channels for every start, released after the answer, plus abandon on failure.
- Uninstall closes our own screen, and there is no live menu without the update hook.

All tests use real engine shapes and failed first. Final verdict: READY to reinstall. Deferred items, documented:
- L2: a launcher `cancel` op.
- I1/I3/I9–I11.

**Re-certification and reinstall.**
- Certificate `b48b5a0b6cf69be03bab5aeac223a9b1ed066c3586e81298aa7c7f5ba72f97f4` (seven phases, `work/recert-9f7a8e1`).
- Package `1f6e2a6b…` = `9f7a8e1` source.
- Fresh backup, dry run `install_planned`, then `installed` with receipt `work/install-receipts/aisparring-install-20260930T011952Z-47f5e144.json`. The only live difference is the new `Mods/AISparring` folder, identical to the package.
- The practice host daemon was restarted (`host-a137bd9d…`). Start gates: `practice_host_ok` in 41.1 s.
- The user's first click-through of the new menu is the next live check.

## Live start stopped at `practice_live_exit_unverified` (September 29–30)

**What happened.** On the user's first start in the `9f7a8e1` build, the menu, start gates, acknowledgement and auto-quit all worked. The host then stopped safely with `practice_live_exit_unverified` and launched nothing.
- **Cause:** after Balatro quit, another process (Steam) still held a handle to it. `OpenProcess` on the live PID (1632) therefore still succeeded with the matching create time, but `QueryFullProcessImageNameW` returned nothing. `wait_for_live_exit` read the empty image path as "cannot verify" and never recognised a normal quit.
- **Why tests missed it:** the dev harness used a placeholder PID that was already fully gone.

**Fix.**
- `NativeProcessHandle.has_exited()` performs a non-terminating exit check on the same handle: `WaitForSingleObject(h, 0)`, falling back to `GetExitCodeProcess`. A `STILL_ACTIVE` result only ever means "unknown".
- The host's query handle adds `SYNCHRONIZE`, which grants no termination right, and falls back to query-only if that is refused.
- `wait_for_live_exit` accepts an exit only for the exact same process (matching create time). A running or unknown-state process still requires the strict install-path check.
- The same case is fixed in `discovery_state` (a crashed daemon whose handle is still held is now stale, not `already_running`).
- `verify_live_target` refuses an already-exited target with `practice_host_live_already_exited`.

**Tests.** Five fake-handle tests and one real Windows reproduction (a finished child whose `Popen` handle is still held) failed first. On Linux: host 95/95, and every other runnable suite is unchanged. The Windows-only suites, the native reproduction and the Lua suites still need a run on the user's machine.

**Still to do:**
- Claude review of the diff.
- Re-certification: the certificate binds the host and launcher sources, and the discovery marker binds the module hash. This change touches no staging, Lua patch or mod bytes and no measured launch behaviour, which is the same basis as the P2 role repair. So `practice_host.py reissue-certificate` re-issues the current certificate from its own seven receipts. It refuses unless live Balatro is closed, no host daemon is running, and the only certificate problems are `bound_tool_changed:launcher` or `bound_tool_changed:practice_host`. Anything else requires a full re-certification.
- Restart the practice host daemon, then have the user retry Play → AI Sparring.

## First human-played match (September 29, ~22:20–23:00 ET)

The exit fix was applied on the user's machine. The host suite passed 99/99 there after the native-test correction `c398271`, including the real Windows exited-but-held reproduction, and the launcher suite passed 64/64. `reissue-certificate` refused once with `reissue_host_daemon_running state=foreign`, because the old daemon's discovery marker carried the previous `practice_host.py` hash. The old daemon was stopped and the marker renamed to `practice_host.old-before-exitfix.json`; the reissue then produced certificate `c19c6dfc…` from the `b48b5a0b…` receipts.

Session `s-f6805722616c9375446bb20a`: the user clicked Play → AI Sparring in live Balatro.
- **Hand-off (22:22–22:25):** the live exit was observed (PID 12720, `pid_reused=false`). This is the step that previously failed. The fresh backup, gates, match server and both staged roles followed. The live-exit to role-launch interval was about 3.5 min, much longer than the 40–60 s the user was told.
- **Match:** the user played a full match against the AI and reported it as "pretty good".
- **Report:** `phase=completed`, `code=practice_host_ok`, live verdict `session_passed`, `changed_roots=[]` and receipt verdict `passed`. The host lockout was cleared. The logs are `decisions.jsonl` (68 KB) and `results.jsonl` (28 KB).

**The user's one finding:** the AI's jokers were not visible on the end screen. This comes from the companion send guard, which blocks `getEndGameJokers`/`receiveEndGameJokers` unconditionally (`mp_driver.lua` `SEND_BLOCKED`). The original requirement was only "no **pre-end** `getEndGameJokers`" (`PROTOTYPE_GATES.md`). A post-match-end allowance would restore the original presentation, but it changes companion Lua bytes, so it needs review, full re-certification and a reinstall.

**Other follow-ups:**
- Tell users to expect a hand-off of about 3–4 min, or shorten it.
- A new host version should treat an old-hash discovery marker whose PID has exited as stale rather than foreign.
