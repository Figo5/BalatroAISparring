# Local progress — September 30, 2026

## Recovered state

- Remote and feature worktree recovered to `9498cfa` (targeted Tarot WIP `0f48623`, followed by Batch 3 review).
- Durable feature worktree (moved by Git, preserving changes): `C:\Users\ginom\Documents\Codex\2026-09-30\files-pasted-by-the-user-take\outputs\BalatroAISparring`. Original `main` checkout stays in its September 27 location.
- Separate local `main` remains at `5d15bb0` with four pre-existing staged files. Do not alter its index or work. Initial staged-diff SHA256: `c7e11dec4d35d26e3e09d1bbf814f0f52825348a344ae6a7e78946e56bf94875`.
- Verified installed mod: all 27 files exactly match the `9f7a8e1` package, SHA256 `1f6e2a6b6dc7b921a6b22975163129df7189187c1ec8cf6fe4f9f66c2d607c8b`.
- Install receipt: original checkout `work/install-receipts/aisparring-install-20260930T011952Z-47f5e144.json`.
- Original seven-phase certificate: `b48b5a0b6cf69be03bab5aeac223a9b1ed066c3586e81298aa7c7f5ba72f97f4`.
- Current original-checkout certificate pointer: `c19c6dfcd31c99ac144d30b0e3e08c27af4f4aa1324e665f4a30c5435b735cf4` (host/launcher-only reissue). This does not certify current feature mod bytes.
- First human-played full match was completed in session `s-f6805722616c9375446bb20a`, per native records. Latest development build has not been installed.

## Current work

Current implementation checkpoint: `e0d5a70` (pushed), following `7341727`
(targeted Tarot finalization) and `93147b7` (Phase A). All implementation uses
OpenCode Go `opencode-go/deepseek-v4.1-flash`, High; exported sessions were
independently checked. Astra's full supported suite and separate H1 sweep pass.
Fresh Claude Code `claude-opus-5-5`, High, acceptance is pending the reported
September 30, 9:40 p.m. Eastern quota reset. Do not substitute a reviewer or
interpret an API limit as a verdict. Current source is not certified/installed.

## Remaining sequence

1. Fresh Claude final-diff review, including the native/upgrade orchestration;
   fix and re-review valid findings with the required DeepSeek coder.
2. Consolidated seven-phase native certification with exact current package;
   no reuse of old certificates for mod changes.
3. Package-bound final pre-install review, fresh verified backups, scoped
   upgrade and actual UI smoke; record package/certificate/install separately.
4. Leave build ready for human playtesting, then integrate/review the separately
   prepared read-only match-history improvement without changing live bytes.

## Evidence

Ignored local evidence: `work/local-ownership/`. Initial recovery verification: `recovery-state.json`. Source/reference/server dependencies are local ignored copies; no proprietary sources or runtime logs are committed.

No new acceptance, certification, installation or live-smoke pass is claimed by this recovery checkpoint.

Independent pre-fix evidence reproduced both Medium findings on both runtimes using exact 9498cfa source. New face-down padding cases first reproduced a residual failure, then passed after the entry guard. Current rendered source is at most 54,749 bytes. Phase A worker reported policy/engine/service/host/decision/M2/estimator suites passing; consolidated independent final-source suite and review remain pending.


## Phase A independent checkpoint (93147b7)

An immutable source snapshot passed policy (176 unique cases, 343 executions), engine (165/165 on each runtime), service (61/61) and estimator parity (2/2). The initial snapshot engine invocation lacked work/reference/mp/ui/game/timer.lua; this verification-harness dependency was copied before the engine-only rerun passed. No source/test relaxation was used. All five Phase A files were byte-compared to that verified snapshot before the logical commit and push. Final Claude acceptance and native certification remain pending. Original main staged-diff checksum was rechecked unchanged after the worktree move.


Reviewer availability preflight: Claude Code returned API 429/session limit and reported a 9:40 p.m. America/New_York reset on September 30. This is no review verdict. Repository work and verification continue; native certification/install require the fresh acceptance review after reset. Evidence: work/local-ownership/claude-availability.json.


## September 30 infrastructure verification checkpoint

Acceptance documentation now reflects the actual full human match and keeps the
installed `9f7a8e1` build separate from the feature branch. Documentation checkpoint:
`7d81a14` (no companion byte changes in that commit).

Independent Windows infrastructure run: all 15 entrypoints passed. Installer
48/48, certificate 65/65, launcher 64/64, staging 52/52, server preparation 8/8,
measurement lifecycle 11/11 and pinned P2 observer 6/6. Native Job identity,
IPv4/IPv6 listener ownership, LuaJIT PID/creation-time identity, FIN/SILENT/dead-port
proofs, actual host process runner and pinned Node server runner all passed.
Evidence: `work/local-ownership/infrastructure/summary.json` and per-suite logs.
No Balatro was launched or live content changed by these tests. Fresh Balatro
certification remains pending final source verification and Claude acceptance.

Prepared read-only-default, one-shot upgrade orchestration in
`work/local-ownership/upgrade_reviewed_companion.py`; not executed. It requires
an explicit reviewed source commit and acceptance record, the fresh valid
certificate, verified old installed hashes, two full fresh backups, a verified
archive, installer dry run/execute and complete unchanged-live checks outside
`Mods/AISparring`. Failed first installation restores only the unchanged archive
into an absent exact target with every game closed. It never restores saves.
Both this helper and the consolidated native runner must be included in the final
Claude integration review before execution.

A separate DeepSeek High read-only audit is preparing the next small Phase H
reliability/diagnostics batch. It is scoped to a scratch report and cannot replace
Claude review. The primary DeepSeek worker is still finalizing targeted Tarots.

## September 30 full regression checkpoint (e0d5a70)

The earlier in-progress notes above are historical. All 60 locally supported
entrypoints now pass, including policy/engine/reader/runtime/decision/boundary,
service 63/63, host 123/123, installer 48/48, certificate 65/65, launcher 64/64,
staging 52/52, actual cross-service transport, native owned-helper contracts,
the baseline/hard benchmarks and blind/run simulations on both Lua runtimes.
The 306 tested source/doc/test files remained byte-identical through the run.
See `LOCAL_REGRESSION_VERIFICATION.md` and ignored `work/local-ownership/full-suite/`.

The independent H1 snapshot passed 1,800 decisions on each runtime (all strong
tiers, 8–12 cards, 5/8 Jokers, PvP/nonclear, held Death/Strength/Sun). Zero budget
failures or nondeterministic repeats; cross-runtime action digests agree.
Maximum cost 1,262,000 instructions under the unchanged 2M limit. Maximum
rendered source 54,740 bytes: 2,604 below the 57,344 guard. Measured Lua-only
latency is not a native gameplay promise. See `LOCAL_H1_VERIFICATION.md`.

Independent production logging checks exposed discarded Tarot fields in the
real logger filter; the follow-up fix uses existing bounded primitives and now
passes the full policy -> broker -> executor -> logger checks. The host audit
exposed a nonforced stop deleting an active supervisor's ticket/Job; `e0d5a70`
defers safely under the shared lock, with pre-fix reproduction and regressions.

The installed 27-file `9f7a8e1` companion remains unchanged. No Balatro launch,
fresh certification, install or live smoke has occurred in this local session.
Original main staged diff was independently rechecked unchanged at this point.

Prepared ignored scripts: `work/local-ownership/run_native_certification.py`
and `upgrade_reviewed_companion.py`. Both require Claude inspection before any
execution. The final-review prompt is `final-review-task-draft.txt` in that
directory. Keep reviewed source HEAD clean and fixed through certification and
upgrade; record review/native evidence in ignored work first, then commit
documentation after installation. Never kill the user's game.

Separate future Phase H preparation completed in detached checkout
`C:\Users\ginom\Documents\Codex\2026-09-30\files-pasted-by-the-user-take\work\match-review-prep`
at `7341727`: bounded read-only Tarot selections/receipt correlation in match
history. DeepSeek session `ses_f0b0ce930ffej09gQlTpRo675e`; three scoped files.
Its reported 14/14 tests need independent verification and a separate Claude
review. Preserve as a normal detached commit after verification, then integrate
only after the current installed build is certified and smoke-tested. It does
not establish engine effects or highlight cleanup from broker acceptance.
