# Local progress — September 30, 2026

## Recovered state

- Remote and feature worktree recovered to `9498cfa` (targeted Tarot WIP `0f48623`, followed by Batch 3 review).
- Working feature checkout: existing `wt-feature` worktree listed by Git. A durable checkout path will be recorded before native certification.
- Separate local `main` remains at `5d15bb0` with four pre-existing staged files. Do not alter its index or work. Initial staged-diff SHA256: `c7e11dec4d35d26e3e09d1bbf814f0f52825348a344ae6a7e78946e56bf94875`.
- Verified installed mod: all 27 files exactly match the `9f7a8e1` package, SHA256 `1f6e2a6b6dc7b921a6b22975163129df7189187c1ec8cf6fe4f9f66c2d607c8b`.
- Install receipt: original checkout `work/install-receipts/aisparring-install-20260930T011952Z-47f5e144.json`.
- Original seven-phase certificate: `b48b5a0b6cf69be03bab5aeac223a9b1ed066c3586e81298aa7c7f5ba72f97f4`.
- Current original-checkout certificate pointer: `c19c6dfcd31c99ac144d30b0e3e08c27af4f4aa1324e665f4a30c5435b735cf4` (host/launcher-only reissue). This does not certify current feature mod bytes.
- First human-played full match was completed in session `s-f6805722616c9375446bb20a`, per native records. Latest development build has not been installed.

## Current work

OpenCode Go `opencode-go/deepseek-v4.1-flash`, High, is implementing Batch 3 M1 Psychic, M2 Tarot churn and L1 stale test. Worker must not touch live files, saves, the main checkout, or Git history. Orchestrator independently verifies before Claude Code `claude-opus-5-5`, High, acceptance review.

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
