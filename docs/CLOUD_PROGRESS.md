# Cloud progress: targeted Tarots in the hand phase (WORK IN PROGRESS)

Branch: `feature/ai-sparring-v1`
Design: `docs/HAND_TARGETS_DESIGN.md` (updated to describe the conservative v1
implementation; still awaiting independent re-review and live validation)
Recorded: 2026-09-30 (Phase A/B update)

This file records the WIP history. Nothing here is certified, accepted or
approved for live installation, and nothing is merged to `main`.

## History

### WIP checkpoint `0f48623` (targeted Tarots)

The first implementation of `USE_CONSUMABLE_ON_HAND`: adapter, executor, action
schema, policy and tests. `docs/CLAUDE_BATCH3_REVIEW.md` was the first
independent review of it.

### Phase A/B (this update)

Fixes and hardening on top of `0f48623`, after the orchestrator's independent
Phase A findings and the Batch 3 review (`docs/CLAUDE_BATCH3_REVIEW.md`):

- **M1 (The Psychic).** Resolved before the estimate and enforced again at
  `play_score` entry, before the numeric estimate or the category fallback. An
  undersized play now scores **nothing** (`nil`, not a numeric score), so it is
  never chosen even when it is the only play offered, with or without
  rule-changing Jokers. Face-down padding reproduces correctly on both runtimes.
  Regressions cover no five-card candidate, a face-down card in every padding
  position, hidden-identity perturbation, all-Stone and unusual identities, the
  disabled boss and determinism.
- **M2 (consumable churn).** A full slot set alone no longer sells a usable
  Tarot; a slot is freed only for a concretely better, affordable visible
  consumable, and then only the lowest-value held Tarot. Covered by both the
  policy fixtures and real adapter → reader → policy SHOP churn tests (full
  slots with no `BUY_ITEM`, sale → newly certified buy → retain, the safety
  floor, and a Negative consumable that needs no slot).
- **L3 (executor defence in depth).** `validate_use_on_hand` now re-checks the
  ten-center allowlist, the source face-up/debuff state, each target's visible
  rank/suit/Stone/debuff state, the engine bounds, the Death pair shape and
  base-only enhancements, alongside the existing Cerulean Bell refusal and
  highlight cleanup. Direct executor negatives and forged/stale end-to-end
  cases added.
- **L4 (logging).** An optional trusted logger port (wired by
  `runtime_bootstrap`) records a `use_consumable_on_hand` event encoded in the
  production logger's existing primitive fields — `code` (outcome), `action`
  (allowlisted visible center, omitted when hidden/refused), `count` (targets)
  and `detail` (`src=… refs=hand:a,hand:b highlight=cleared|kept`). A forged/
  oversized/table ref is normalized away and `detail` stays inside the 96-byte
  cap. Never reads a hidden card value and never throws. No correlation id is
  emitted or claimed, because an action id cannot survive the 96-byte primitive
  cap. The Python decision log also records the allowlisted center (from the
  sanitized observation) and the positional refs. No protocol field was added.
  A permanent regression runs the record through the real `src/logger.lua`
  filter (both runtimes), not only a table recorder.
- **L2 (certificate cap).** Four of the 120 certificate slots are reserved for
  reorders, so a 12-card/8-Joker/three-Tarot hand keeps a few Joker reorders with
  the play/discard capacity and the 8/source, 24-total Tarot bounds unchanged.
  No cap or sandbox limit was raised.
- **L1 (service test).** `test_baseline_source_provider_renders_all_difficulties`
  now exercises every available lupa runtime instead of assuming Lua 5.1, and
  the whitespace-tolerant signature match is kept.
- **Budget (H1).** Permanent budget tests extended to 8–12 card hands, 5/8
  Jokers, Competitive/Major League/Expert, PvP and no-clear states, and the held
  three-Tarot case, with deterministic cross-runtime vectors. The 2,000,000
  instruction budget and the existing strict guards are unchanged.
- **Docs.** `HAND_TARGETS_DESIGN.md`, `LEGAL_ACTIONS.md`, `ENGINE_ADAPTER.md`,
  `BASELINE_POLICY.md`, `POLICY_BACKLOG.md`, `LOCAL_VALIDATION_QUEUE.md` (LV-11)
  and this file synced to the implementation.

## Current status

- **NOT independently re-reviewed** since the Phase A/B changes. The Batch 3
  review (`docs/CLAUDE_BATCH3_REVIEW.md`) covered `0f48623`; its findings above
  are addressed, but the fixes themselves still need a fresh review.
- **NOT native-certified.** The engine/policy harnesses and the service suite
  run under lupa (Lua 5.1 and LuaJIT 2.1) and Python only. No live Balatro run
  or certification covers this code.
- **NOT accepted.** Claude acceptance and the final orchestrator acceptance are
  still open.
- **NOT installed or playtested live.**

## What the change contains

- `AISparring/ai/actions.lua`: `USE_CONSUMABLE_ON_HAND` (`source_ref` +
  non-empty `card_refs`), legal only in `PLAY_HAND` and `MULTIPLAYER_PVP`.
- `AISparring/integration/engine_adapter.lua`: certifies the ten allowlisted
  Tarots against visible, non-forced, non-debuffed hand cards; bounded to 8 per
  source and 24 total; four certificate slots reserved for reorders.
- `AISparring/integration/production_executor.lua`: highlights exactly the
  certified cards, re-checks the engine predicate and the v1 shape, clears the
  highlight on any refusal/no-op, and logs a bounded outcome.
- `AISparring/integration/runtime_bootstrap.lua`: wires the trusted logger port.
- `AISparring/ai/baseline_policy.lua`, `AISparring/ai/observation.lua`: policy
  use of the allowlisted Tarots (Rookie never uses them); the M1 Psychic fix;
  the M2 sell rule.
- `tools/practice_service.py`: `USE_CONSUMABLE_ON_HAND` in
  `DEFAULT_ACTION_TYPES`; bounded decision logging of the Tarot center and
  positional refs.
- Tests: `tests/engine/test_hand_tarots.lua`,
  `tests/policy/test_hand_tarots.lua`, `tests/policy/test_psychic_rule_jokers.lua`,
  `tests/policy/test_consumable_slots.lua`, `tests/policy/test_shop_churn.lua`,
  `tests/policy/test_budget.lua`, `tests/policy/test_estimator.lua`,
  `tests/engine/support.lua`, `tests/engine/test_adapter.lua`,
  `tests/test_practice_service.py`.

## Remaining gates (in order)

1. **Independent re-review** of the Phase A/B diff against
   `docs/HAND_TARGETS_DESIGN.md`, recorded as a new `docs/CLAUDE_*REVIEW.md`.
2. **Resolve every finding** from that review, with re-review where asked.
3. **Final orchestrator acceptance** of V1. Only then may the branch be
   considered for merge (still no merge to `main` until full V1 approval).
4. **Local re-certification and playtest batch.** Every `AISparring/` Lua change
   changes the staged companion bytes, so it needs full re-certification and a
   companion reinstall. Add LV-11 (`docs/LOCAL_VALIDATION_QUEUE.md`) and run the
   live checks there. Only after that batch passes may it be considered for live
   installation.

## Test snapshots (this update)

All runs used the repository's `work/runtime-venv` (Windows). See
`work/local-ownership/deepseek-phase-ab-report.md` for the exact outcomes,
source size and remaining risks.
