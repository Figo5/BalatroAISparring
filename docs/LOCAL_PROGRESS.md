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

Current implementation checkpoint: `93147b7` (Phase A fixes, pushed). First DeepSeek Phase A batch is implemented and passes its selected suites; independent face-down padding reproduction passes after a follow-up guard. No-five-candidate exclusion, actual adapter-generated churn tests and Tarot finalization are in progress in a second fresh OpenCode Go `opencode-go/deepseek-v4.1-flash`, High, session. Worker must not touch live files, saves, the main checkout, or Git history. Orchestrator independently verifies before Claude Code `claude-opus-5-5`, High, acceptance review.

## Remaining sequence

1. Independently verify Phase A; finish Tarot executor checks, bounded safe logging, certificate-cap handling and accurate docs.
2. Run every locally supported suite on Lua 5.1/LuaJIT; measured large-hand sweep with held Tarots, unchanged 2M limit, source headroom.
3. Fresh Claude final-diff review; fix and re-review valid findings; commit/push logical reviewed changes.
4. Consolidated seven-phase native certification with exact current package; no reuse of old certificates for mod changes.
5. Fresh verified backup, safe certified installation, live smoke test; record package/certificate/install separately.
6. Leave build ready for human playtesting, then continue isolated repository improvements.

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
