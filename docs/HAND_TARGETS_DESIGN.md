# Design: targeted consumables in the hand phase

Status: **proposed**, awaiting architecture review.

## Why

Tarots that act on highlighted hand cards (Strength, Death, the enhancement
Tarots, the suit Tarots) are among Balatro's strongest tools. Today the AI can
never use them:

- the adapter certifies `USE_CONSUMABLE` only for consumables that need **no**
  targets (`needs_targets` in `cert_use_consumables`);
- targeted uses exist only in the `CONSUMABLE_SELECTION` phase. That phase
  depends on a `target_selection` port that production never wires, so it
  never occurs live;
- the policy therefore never buys a targeted consumable, and sells a held one
  (`TARGETED`, `docs/BASELINE_POLICY.md`).

In vanilla there is no separate targeting phase. The player highlights cards
in hand during `SELECTING_HAND` and presses Use on the consumable. The
executor already supports exactly that for `USE_CONSUMABLE` with non-empty
`target_refs`:

1. it highlights the targets through `apply_hand_selection`;
2. it re-checks the engine's own read-only `can_use_consumeable`;
3. only then does it call `use_card`.

## Fairness

- Targets are the AI's own face-up hand cards, which it already sees.
- The effects are public card text.
- The action goes through the real UI path (highlight, then Use), and the
  engine's own predicate is the authority.

Only Tarots with deterministic, card-local effects are allowlisted.
Random-outcome ones (The Wheel of Fortune, Aura) and deck-altering ones
(The Hanged Man, Cryptid) are out of scope, so nothing about the deck order or
RNG is involved.

## Change

1. **Adapter** (`engine_adapter.lua`, in `PLAY_HAND` and `MULTIPLAYER_PVP`
   with gates clear): for each held, face-up, non-debuffed consumable whose
   engine center is in the allowlist below, certify
   `USE_CONSUMABLE { source_ref = consumable:i, target_refs = { hand:j, … } }`:

   | Center | Effect (vanilla) | Targets |
   |---|---|---|
   | `c_strength` | +1 rank (King → Ace, Ace → 2) | 1..2 |
   | `c_death` | the left card becomes a copy of the right card | exactly 2 |
   | `c_magician` / `c_empress` / `c_heirophant` | Lucky / Mult / Bonus | 1..2 |
   | `c_lovers` / `c_chariot` / `c_justice` / `c_devil` / `c_tower` | Wild / Steel / Glass / Gold / Stone | 1 |
   | `c_star` / `c_moon` / `c_sun` / `c_world` | Diamonds / Clubs / Hearts / Spades | 1..3 |

   - The target counts come from the engine card's
     `ability.consumeable.max_highlighted` and `min_highlighted` (default 1),
     never from the table.
   - The table only restricts **which** centers are offered.
   - Targets are only face-up cards with a visible identity (the adapter's
     `grouping_identity`): never face-down, Stone or no-rank cards.
   - The selections are bounded and deterministic: all singletons, then
     lexicographic pairs, then triples. At most 24 per consumable and 48 in
     total, within the existing selection cap.
   - The engine predicate cannot be pre-checked without highlighting, so the
     executor's post-highlight check stays the authority.
2. **Observation / actions** (`observation.lua`, `actions.lua`):
   `USE_CONSUMABLE.target_refs` may reference the `hand` zone, but only in
   `PLAY_HAND` and `MULTIPLAYER_PVP`. In `CONSUMABLE_SELECTION` it stays the
   `target` zone. A hand ref elsewhere is `observation_invalid_target_ref`.
   The broker binds certificates exactly as today.
3. **Executor** (`production_executor.lua`):
   - `USE_CONSUMABLE` accepts `hand:` refs in the hand phase, resolving them
     to `G.hand.cards[j]` with the same distinctness checks as `target:`;
   - if the post-highlight predicate refuses, the highlight is cleared again
     (`G.hand:unhighlight_all`), so a later `PLAY_CARDS` is unaffected;
   - vanilla's `use_card` unhighlights after a use.
4. **Policy:**
   - For each certified targeted use, simulate the effect on copies of the
     targeted cards: rank, enhancement or suit (Death copies rank, suit,
     enhancement, edition and seal).
   - Compare the best play estimate over the hand after the use with the one
     before.
   - Also add a small permanent-value bonus for an enhancement on a card that
     is in the current best play. Glass, Steel and Lucky are valued through
     the estimate; Gold at its $3 held value.
   - Use when the gain clears a margin. Otherwise hold the card: it does not
     expire.
   - The work is metered with `WORK`, with at most `TARGET_LIMIT` (24)
     candidates per decision.
   - `TARGETED` stops refusing allowlisted Tarots: they are bought at a
     modest utility and are no longer sold. The unlisted ones keep today's
     rule.
   - Rookie keeps today's behaviour.

## Tests

- **Adapter:**
  - allowlisted Tarots in the hand phase get bounded hand-ref selections
    within the engine's min/max, and never face-down or Stone targets;
  - an unlisted Tarot (Hanged Man), a debuffed consumable, a shop phase or a
    PvP-blocked state get none.
- **Observation:** a hand ref outside the hand phases, and a target ref in
  the hand phase, are both rejected.
- **Executor:**
  - a fixture applies the highlight, checks the predicate and calls
    `use_card`;
  - when the predicate is refused, the highlight is cleared and the result is
    `ILLEGAL`;
  - stale refs give `UNKNOWN_REF`.
- **Policy:**
  - Strength on a pair's kicker making two pair is used;
  - Death turning a low card into a copy of an Ace pair card is used;
  - a suit Tarot completing a flush is used;
  - a Tarot with no gain is held;
  - the budget stays within limits with 24 candidates;
  - allowlisted Tarots are bought and not sold.
- **Isolation certificate / cross-service:** re-run and re-certify.

## Out of scope

- Targeted picks from Arcana packs (hand shown during booster selection).
- The Hanged Man (it destroys cards).
- Spectral cards with targets (seals, Cryptid, Aura).
- Wiring a `target_selection` port.
