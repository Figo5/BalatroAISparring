# Design: hand types played this round (The Eye, The Mouth)

Status: **proposed, awaiting architecture review.** No code yet.

## Why

Two boss blinds depend on which hand types were played this round:

- **The Eye:** no repeat hand types this round. A repeated type is debuffed
  and scores 0.
- **The Mouth:** only one hand type per round. After the first hand, any other
  type is debuffed and scores 0.

The policy cannot tell which types were played, so under these bosses it can
throw away a hand. The Psychic is already handled from the public blind key
(`match.blind`), with `match.blind_disabled` (docs/BLIND_DISABLED_DESIGN.md).

## Fairness

This is the AI's own history within the current round: the hands it played
itself a moment ago. A human player remembers them. The engine keeps them as
`G.GAME.hands[name].played_this_round`, next to the `level` / `chips` / `mult`
already exported from Run Info. Nothing about the opponent, the deck or the
future is involved. Only hands Run Info lists (`visible == true`) are exported,
and every hand that has been played is visible.

## Change

Follow the `hand_levels` path exactly:

1. **Adapter** (`engine_adapter.lua`, hand-levels loop): for each exported
   hand, add `played_this_round = int_field(entry.played_this_round)` when it
   is an integer between 0 and 1000. Fail-soft: omitted otherwise.
2. **Reader** (`state_reader.lua`, `copy_hand_levels`): copy the optional
   `played_this_round` as a non-negative integer of at most 1000. A non-integer
   is `reader_bad_view`. Hand names stay allowlisted.
3. **Observation** (`observation.lua`, `read_hand_levels`): an optional
   `played_this_round` field (int, 0..1000) in each entry. Update
   `docs/AI_OBSERVATION.md` and `docs/STATE_READER.md` together.
4. **Policy** (`boss_aware`; the boss must not be disabled): the play estimate
   is 0 for:
   - under `bl_eye`, a play whose hand type has `played_this_round >= 1`;
   - under `bl_mouth`, once any hand has `played_this_round >= 1`, a play of
     any other type.

   The discard search applies the same filter. Hand types come from the
   policy's own classifier, which already falls back to category ranking under
   rule-changing Jokers.

## Tests

- **Adapter fixture:** `played_this_round` is exported with hand levels, and
  a non-integer or out-of-range value is dropped.
- **Reader:** a non-integer is `reader_bad_view`; an absent value stays
  absent.
- **Observation:** an out-of-range value is `observation_invalid_field`.
- **Policy:** under The Eye, a played Pair loses to an unplayed Two Pair. Under
  The Mouth after a Pair, only Pairs score. A disabled boss changes nothing.
- **Simulators:** `benchmark_blinds.py` models The Eye and The Mouth, for a
  paired A/B.
- **Isolation certificate / cross-service:** re-run and re-certify.
