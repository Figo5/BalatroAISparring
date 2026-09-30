# Design: current values of owned scaling Jokers

Status: **implemented.** The architecture review approved it with changes,
all applied:

- **Critical:** the codec accepts integers only, so ×Mult values are sent in
  hundredths (`value` 100..1,000,000 for `xmult`). A fractional engine value
  is rounded the same way in the adapter and in the reader.
- **High:**
  - several values change in the hand's "before" step, before Jokers score.
    The policy models that growth, and in particular Ride the Bus resetting
    to 0 when a face card scores. The per-hand step is exported (`step`),
    because rulesets can change it. Obelisk is dropped, because its reset
    depends on lifetime hand counts;
  - one helper, `effect_of`, gives the effect of an owned or offered Joker to
    the estimate, `joker_gain` and the estimate-based reorder.
- **Medium:**
  - the reader takes the allowlist row from the engine card's own center and
    compares `kind`, `value` and `step` with the engine fields; anything else
    is `reader_bad_view`;
  - the observation reads `current` with a dedicated nested reader, and a bad
    value is `observation_invalid_entity`;
  - the `joker_gain` tests were corrected (see below).
- **Low:**
  - the decision signature needs no change: `current` is part of the view,
    so the epoch moves with it;
  - the out-of-scope reasons are corrected.

Re-certification is required: the adapter, reader, observation and policy
all changed. `schema_version` stays 1.


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
number stay out. A debuffed Joker's text reads "All abilities are disabled",
so it exports no value; the reader rejects one (code review Medium).

## Change

1. **Adapter** (`engine_adapter.lua`, `build_joker`): for a face-up owned
   Joker whose center is in a fixed allowlist, export
   `current = { kind, value, step? }`, with `shown.current = true`:

   | Center | Kind | Value field | Step field (per hand) |
   |---|---|---|---|
   | `j_green_joker` | mult | `ability.mult` | `ability.extra.hand_add` |
   | `j_ride_the_bus` | mult | `ability.mult` | `ability.extra` |
   | `j_trousers` | mult | `ability.mult` | `ability.extra` |
   | `j_flash`, `j_red_card`, `j_ceremonial` | mult | `ability.mult` | none |
   | `j_runner`, `j_square`, `j_wee` | chips | `ability.extra.chips` | `ability.extra.chip_mod` |
   | `j_castle` | chips | `ability.extra.chips` | none |
   | `j_hologram`, `j_constellation`, `j_campfire`, `j_glass`, `j_madness`, `j_lucky_cat` | xmult | `ability.x_mult` ×100, rounded | none |

   - `mult` and `chips` values are integers 0..100000.
   - `xmult` values are integers 100..1000000.
   - `step` is an integer 0..100000.
   - The adapter is fail-soft: `current` is omitted when a field is missing,
     non-finite, fractional (for `mult` and `chips`) or out of range. Shop
     items, booster cards and redacted Jokers never carry it.
2. **Reader** (`state_reader.lua`): for a joker record with
   `shown.current == true` and a `current` table, look up the row by the
   **engine card's** `config.center.key`. Recompute the expected
   `{kind, value, step}` from the engine fields, with the same rounding, and
   copy `current` only if it matches exactly. Otherwise (an unlisted center,
   a mismatch, a bad shape) the result is `reader_bad_view`.
3. **Observation** (`observation.lua`): an optional `current` on joker
   entities. `kind` is one of `mult`, `chips`, `xmult`; `value` and `step`
   are integers in the ranges above; no other keys. Anything else is
   `observation_invalid_entity`. `schema_version` stays 1 (an additive
   optional field).
4. **Policy:**
   - `effect_of(j)` returns `JOKER_EFFECTS[center]`, then the offered proxy,
     then an effect derived from `current` (×Mult divided by 100);
   - `estimate_score` applies the before-step growth:
     - **Ride the Bus:** 0 if a scoring, non-debuffed face card is played,
       otherwise value + step;
     - **Green Joker:** value + step;
     - **Spare Trousers:** + step if the hand contains Two Pair;
     - **Runner:** + step if the hand contains a Straight;
     - **Square Joker:** + step if exactly four cards are played;
     - **Wee Joker:** + step for each scoring 2, retriggers included;
   - `joker_gain` placement and `reorder_score` use `effect_of`, so an owned
     grown ×Mult Joker counts as ×Mult and a grown +Mult one as additive;
   - Lucky Cat, Flash Card, Castle and the other Jokers without a step use
     the shown value (they grow from other events).

## Tests

- **Adapter:** each kind is exported from its fields, and ×Mult is rounded
  to hundredths (1.25 → 125; 1.7000000000000004 → 170). A missing,
  non-finite or out-of-range value, an unlisted center, a face-down Joker and
  a shop item export nothing. The codec encodes the view.
- **Reader:**
  - a kind, value or step mismatch with the engine is `reader_bad_view`;
  - so is an unlisted engine center;
  - without `shown.current` the value is not copied.
- **Observation:** a bad `kind`, `value`, `step` or an extra key is
  `observation_invalid_entity`.
- **Policy:**
  - Green Joker at +30 Mult makes a pair clear a requirement it would
    otherwise miss;
  - Green Joker at +30 lowers the gain of a new +Mult Joker;
  - an owned ×3 Hologram puts a new additive Joker before it;
  - Ride the Bus scores +0 with a face card;
  - a debuffed scaling Joker contributes nothing;
  - estimates are unchanged when `current` is absent.
- **Budget:** existing budget cases pass (there is no new search).
- **Isolation certificate / cross-service:** re-run and re-certify.

## Out of scope

- Obelisk: its reset depends on lifetime hand counts, which are not
  exported.
- Throwback: its value comes from the run's skip count, not a card field.
- Supernova: it depends on per-hand lifetime counts.
- Loyalty Card: a countdown, not a value.
- Yorick, Hit the Road, Ramen, Ice Cream, Popcorn and Swashbuckler could
  follow later with the same mechanism.
- Before-step growth of offered copies is not modelled: they keep the
  `SCALING` proxy.
