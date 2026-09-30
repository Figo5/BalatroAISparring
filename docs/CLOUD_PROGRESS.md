# Cloud progress: targeted Tarots in the hand phase (WORK IN PROGRESS)

Branch: `feature/ai-sparring-v1`
Design: `docs/HAND_TARGETS_DESIGN.md` (status there is still **proposed**; this
file does not change it)
Recorded: 2026-09-30

## Status of this commit

This is a **work-in-progress checkpoint**, committed only so the work survives
the temporary cloud container. It is:

- **NOT fresh-context reviewed yet.** No independent Claude review of this diff
  has been done.
- **NOT service-level tested yet.** Only the engine and policy harnesses below
  were run.
- **NOT certified.** No certification or re-certification covers this code.
- **NOT approved for live installation.** Do not install, stage or playtest it
  live until every gate below is closed.

The feature is **not complete**. No existing acceptance, certification or
review status in any other document is changed by this commit. Nothing here
is merged to `main`.

## What the WIP contains

- `AISparring/ai/actions.lua`: new `USE_CONSUMABLE_ON_HAND` action
  (`source_ref` + non-empty `card_refs`), legal only in `PLAY_HAND` and
  `MULTIPLAYER_PVP`.
- `AISparring/integration/engine_adapter.lua`: certifies allowlisted targeted
  Tarots against visible, non-forced, non-debuffed hand cards.
- `AISparring/integration/production_executor.lua`: highlights exactly the
  certified cards, then uses the consumable.
- `AISparring/ai/baseline_policy.lua`, `AISparring/ai/observation.lua`: policy
  use of the allowlisted Tarots (Rookie never uses them); allowlisted ones are
  kept while a slot is free, others are still not bought and are sold.
- `tools/practice_service.py`: `USE_CONSUMABLE_ON_HAND` added to
  `DEFAULT_ACTION_TYPES`.
- Tests: `tests/engine/test_hand_tarots.lua` (5 cases),
  `tests/policy/test_hand_tarots.lua` (7 cases), `tests/engine/support.lua`
  (`unhighlight_all` fixture matching real `CardArea` forced-selection
  behaviour), `tests/policy/test_estimator.lua` (targeted-consumable cases moved
  to non-allowlisted cards; allowlisted Death slot cases added).

## Tests run for this checkpoint

| Command | Result |
|---|---|
| `python3 tests/run_engine.py --require-all` | PASS, 165/165 per runtime (lua51, luajit21); includes the 5 new tarot cases (160 without them) |
| `python3 tests/run_policy.py` | PASS, includes `test_hand_tarots` 7/7 per runtime |
| `python3 tests/test_policy_estimator_parity.py` | PASS, 2/2 |
| `python3 tests/test_practice_service.py` | 60/61; the one failure, `test_baseline_source_provider_renders_all_difficulties`, **also fails on the base commit `c748be1` without this diff**, so it is pre-existing and not caused by this work. It still has to be understood before acceptance. |

## Remaining gates (in order)

1. **Service-level tests.** Run the full service-level suites (at least
   `tests/run.py`, `tests/run_runtime.py`, `tests/run_decision.py`,
   `tests/run_m2.py`, `tests/test_practice_service.py`,
   `tests/test_practice_host.py`, `tests/test_runtime_cross_service.py`, and the
   `tests/astra_*` contracts that exercise the action set / legal actions).
   Confirm `USE_CONSUMABLE_ON_HAND` is accepted end-to-end through the practice
   service and broker. Investigate the pre-existing
   `test_baseline_source_provider_renders_all_difficulties` failure and record
   its cause.
2. **Fresh-context Claude review** of the full diff against
   `docs/HAND_TARGETS_DESIGN.md`, recorded as a new `docs/CLAUDE_*REVIEW.md`.
3. **Fix all findings**, with re-review where the review asks for it.
4. **Convert the WIP into accepted reviewed work** through a follow-up commit
   (update `docs/HAND_TARGETS_DESIGN.md` status and the relevant docs such as
   `docs/BASELINE_POLICY.md`, `docs/LEGAL_ACTIONS.md`, `docs/ENGINE_ADAPTER.md`),
   and replace this WIP notice.
5. **Add it to the next local re-certification / playtest batch**
   (`docs/LOCAL_VALIDATION_QUEUE.md`). Only after that batch passes may it be
   considered for live installation.
