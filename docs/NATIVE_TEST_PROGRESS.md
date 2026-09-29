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
