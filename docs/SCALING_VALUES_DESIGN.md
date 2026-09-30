# Design: current values of owned scaling Jokers

Status: **proposed**, awaiting architecture review.

## Why

Scaling Jokers (Green Joker, Ride the Bus, Hologram, Runner, …) grow over a
run. The policy knows only their center, so an owned one counts as **no
effect** in the play estimate. A Green Joker at +20 Mult or a Hologram at
×2.5 is invisible to it. That makes it:

- underestimate every play against the blind requirement, so it discards or
  plays extra cards to "reach" a score it would already reach;
- misprice new Jokers against the owned row (`joker_gain` uses the same
  estimate), including the order-sensitive placement before an owned ×Mult;
- unable to order an owned scaling ×Mult Joker by its real value.

An offered scaling Joker keeps its conservative mid-life proxy (`SCALING`);
this change is only about **owned** ones.

## Fairness

Vanilla shows the current value on the Joker's card text whenever the player
hovers it: "(Currently +X Mult)", "(Currently +X Chips)" or
"(Currently X× Mult)". It is the AI's own Joker, and the number is what the
card itself displays. No deck order, future RNG or opponent state is
involved. Values that the card text does **not** show as a single current
number stay out.

## Change

1. **Adapter** (`engine_adapter.lua`, `build_joker`): for a face-up owned Joker
   whose center is in a fixed allowlist, export
   `current = { kind = <"mult"|"chips"|"xmult">, value = <number> }`, read
   from the one engine field the card text displays:

   | Center | Kind | Engine field |
   |---|---|---|
   | `j_green_joker`, `j_ride_the_bus`, `j_trousers`, `j_flash` | mult | `ability.mult` |
   | `j_runner`, `j_wee`, `j_castle`, `j_square` | chips | `ability.extra.chips` |
   | `j_hologram`, `j_constellation`, `j_obelisk`, `j_campfire`, `j_glass`, `j_madness`, `j_lucky_cat` | xmult | `ability.x_mult` |

   It is fail-soft: `current` is omitted when the field is missing, not a
   finite number, or out of range (mult and chips: integers 0..100000; xmult:
   1..10000). The `shown` attestation for jokers gains `current`. Shop items
   never carry it.
2. **Reader** (`state_reader.lua`): copy `current` only for an allowlisted
   center, with `kind` matching that center's row. It must also be a finite
   number in range and, like the adapter's, equal to the engine's own field
   (as `blind_disabled` does). Anything else is `reader_bad_view`.
3. **Observation** (`observation.lua`): an optional `current` table on owned
   Jokers (`kind` enum, `value` number). `schema_version` stays 1 (an
   additive optional field). Update `docs/AI_OBSERVATION.md`,
   `docs/STATE_READER.md` and `docs/ENGINE_ADAPTER.md` together.
4. **Policy:** in `estimate_score`, an owned Joker with no `JOKER_EFFECTS`
   entry uses `{ current.kind, current.value }` as its effect. Flat `mult`,
   `chips` and `xmult` are already handled. Consequences:
   - the play estimate and the blind-requirement check see the real value;
   - `joker_gain` prices new Jokers against the real row;
   - estimate-based reordering places an owned scaling ×Mult correctly;
   - `GROWS` (never sold for a fresh copy) stays as it is.

   Castle's suit and Lucky Cat's triggers are not modelled beyond the
   displayed value. The value is what the card shows, and it applies to
   every hand.

## Tests

- **Adapter fixture:** each kind is exported from its field. A missing,
  non-finite or out-of-range value, an unlisted center and a face-down Joker
  export nothing.
- **Reader:** a kind mismatch, an unlisted center, a mismatch with the engine
  field and an out-of-range value are each `reader_bad_view`.
- **Observation:** a bad `kind` or `value` is `observation_invalid_field`.
- **Policy:**
  - a Green Joker at +30 Mult makes a pair clear a requirement that it
    would miss without the Joker;
  - an owned ×3 Hologram lowers `joker_gain` for a new ×Mult Joker compared
    with a ×1 Hologram;
  - estimates are unchanged when `current` is absent.
- **Budget:** `test_budget.lua` cases with scaling Jokers stay within limits
  (there is no new search).
- **Benchmarks:** the `scaling` stress family can give owned scaling Jokers a
  `current` value in both the policy's input and the reference scorer.
- **Isolation certificate / cross-service:** re-run and re-certify.

## Out of scope

- Throwback: its value comes from the run's skip count, not a card field.
- Supernova: it depends on per-hand lifetime counts.
- Loyalty Card: a countdown, not a value.
- Ramen, Ice Cream, Popcorn: decaying values could follow later with the same
  mechanism.
- Swashbuckler, Ceremonial Dagger, Red Card: they grow from actions the
  policy does not take.
