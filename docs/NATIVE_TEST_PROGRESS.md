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
