# Design: tell the policy when the boss blind is disabled

Status: **implemented.** The architecture review approved it with changes,
all applied:

- **High:**
  - the reader copies the flag only as a strict boolean, only alongside
    `match.blind`, and only when it equals the engine's own
    `G.GAME.blind.disabled`; anything else is `reader_bad_view`;
  - the adapter writes it only when `match.blind` was written and the engine
    value is a boolean.
- **Medium:**
  - `blind_disabled` is in the adapter's decision signature;
  - docs are updated;
  - the policy's Psychic check requires `blind_disabled ~= true`.
- **Low:** tests in `tests/engine/test_blind_disabled.lua` and
  `test_estimator.lua`.

Re-certification is required: the observation schema, adapter, reader and
policy all changed. `schema_version` stays 1, because the field is optional
and additive, like `hand_levels`.

## Why

Chicot and Luchador disable the current boss blind. The engine keeps the
boss's key (`G.GAME.blind.config.blind.key`) and sets `G.GAME.blind.disabled
= true`. The adapter already checks `disabled` before offering The Psychic's
padded five-card plays. The policy only sees `match.blind`, though, so it
still treats a disabled Psychic as active. It then scores plays of fewer than
five cards at 0 and trims its discard search.

## Fairness

The game shows a disabled boss on screen: the blind's effect text is replaced
and the boss is marked as disabled. It is the AI's own current blind, so no
hidden or opponent information is involved.

## Change

1. **Adapter** (`engine_adapter.lua`, where `match.blind` is written):
   `put_bool(match, "blind_disabled", G.GAME.blind.disabled == true)`, only
   when a blind is present. Fail-soft: omitted when unreadable.
2. **Reader** (`state_reader.lua`): copy `match.blind_disabled` as a strict
   boolean. A non-boolean value is `reader_bad_view`.
3. **Observation** (`observation.lua`): add `blind_disabled` as a `bool` field
   of `match`, default absent. This is a schema addition, so the docs
   (`docs/AI_OBSERVATION.md`, `docs/STATE_READER.md`,
   `docs/ENGINE_ADAPTER.md`) change together.
4. **Policy:** `boss_aware` rules apply only when `match.blind_disabled ~=
   true`.

## Tests

- **Adapter fixture:** a disabled Psychic exports `blind_disabled = true`, and
  an active one exports `false`.
- **Reader:** a non-boolean value is rejected.
- **Policy:** under a disabled Psychic, a pair beats a five-card High Card
  again.
- **Isolation certificate / cross-service:** re-run and re-certify.

## Out of scope

Other boss state (The Eye / The Mouth hand history, The Arm, The Ox) is out of
scope.
