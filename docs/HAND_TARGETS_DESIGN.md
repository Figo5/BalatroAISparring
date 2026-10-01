# Design: targeted consumables in the hand phase

Status: **implemented (conservative v1, WIP)** — awaiting independent Claude
re-review and real Balatro validation. Not certified, not accepted.

This document describes what the code actually does now. The original
proposal (extend `USE_CONSUMABLE.target_refs`, 1–3 targets, a 14-center
allowlist) was reviewed in `docs/CLAUDE_BATCH3_REVIEW.md` (L5) and the
implementation is the more conservative of the two.

## Why

Tarots that act on highlighted hand cards (Strength, Death, the enhancement
Tarots, the suit Tarots) are among Balatro's strongest tools. In vanilla there
is no separate targeting phase: the player highlights cards in hand during
`SELECTING_HAND` and presses Use. The executor supports exactly that path —
highlight, re-check the engine's own read-only `can_use_consumeable`, then
`use_card`.

## Action shape

A dedicated action, **`USE_CONSUMABLE_ON_HAND`**:

```
{ type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:i",
  card_refs = { "hand:j", ... } }
```

- `source_ref` is a held consumable in `self.consumables`.
- `card_refs` are **positional** refs into the AI's own face-up hand.
- Certified only in `PLAY_HAND` and `MULTIPLAYER_PVP` (not `DISCARD`, shop,
  booster or `CONSUMABLE_SELECTION`).

This mirrors the existing `USE_CONSUMABLE`/`card_refs` broker binding. The
`CONSUMABLE_SELECTION` phase is unchanged and still uses `target:`
(`USE_CONSUMABLE.target_refs` / `SELECT_TARGETS`).

## Allowlist (ten Tarots)

| Center | Effect (vanilla) | v1 targets |
|---|---|---|
| `c_strength` | +1 rank (King → Ace, Ace → 2) | exactly 1 |
| `c_death` | the left card becomes a copy of the right card | exactly 2 |
| `c_lovers` / `c_chariot` / `c_justice` / `c_devil` | Wild / Steel / Glass / Gold | exactly 1, base card only |
| `c_star` / `c_moon` / `c_sun` / `c_world` | Diamonds / Clubs / Hearts / Spades | exactly 1, not already that suit |

Deliberately excluded (never certified): Magician, Empress, Hierophant,
Tower, Hanged Man and every random or deck-altering Tarot/Spectral. No
`packs`: Arcana-pack picks stay gated by the engine's own
`can_use_consumeable` (nothing highlighted), so a targeted Tarot is never
picked from a pack.

## Bounds

- Per source: at most **8** selections; overall at most **24**.
- The target counts come from the engine card's own
  `ability.consumeable.max_highlighted` / `min_highlighted` /
  `mod_num`, never from a hard-coded table.
- Targets are only face-up cards with a visible identity (rank and suit
  visible, never Stone, debuffed or identity-masked), the adapter's
  `grouping_identity`.
- Death offers only distinct pairs and orders the lower hand ordinal first
  (the right-hand card is the copy source; confirmed against the vanilla
  `card.lua` `T.x` rule).
- The selections are bounded and deterministic: all singletons, then
  lexicographic pairs (Death). Strength/suit/enhancement are singletons.

## Certificate cap reserve (L2)

Reorders are the lowest-priority certificates. Four slots of the 120-certificate
cap are reserved for them (`REORDER_RESERVE`), so a 12-card hand with 8 Jokers
and three held Tarots keeps a few Joker reorders while the play/discard
capacity and the 24-Tarot bound are unchanged. The 120 cap and every sandbox
limit are unchanged.

## Executor

`validate_use_on_hand` is defence in depth: it re-checks, from the engine's own
read-only state, that

- the phase is `SELECTING_HAND` and the gates are clear;
- the source is a face-up, non-debuffed consumable on the **same** ten-center
  allowlist (a forged/off-allowlist center is refused);
- the target count is within the engine card's own bounds, **and** exactly 2
  for Death / exactly 1 for every other allowlisted Tarot (v1 shape);
- an enhancement Tarot targets a base card only;
- every target is a face-up, non-debuffed, visible rank/suit card (never
  Stone or masked) — checked as a distinct set;
- no card is blind-forced (Cerulean Bell): a forced card would join every
  highlight.

The adapter applies the same allowlist and visibility rules, so it never offers
what the executor refuses. On any refusal or no-op the highlight is cleared
(`G.hand:unhighlight_all`); vanilla's own `use_card` unhighlights on success.
The engine's real `can_use_consumeable` is re-checked after highlighting and is
the authority.

## Policy

- For each certified use, the effect is simulated on copies of the targeted
  cards: rank +1 (Ace → 2), Death copies the right card (rank, suit,
  enhancement, edition, seal), an enhancement sets the center, a suit sets the
  suit. Enhancements are modelled on base cards only.
- The best play estimate over the hand after the use is compared with the one
  before; a use is chosen only on a clear gain (Gold: when it costs nothing,
  for its held payout). Otherwise the Tarot is held — it does not expire.
- The work is metered (`TARGET_WORK`, 6000 units), so large hands stay inside
  the 2,000,000-instruction budget.
- Allowlisted Tarots are bought at a modest utility and are not sold, unless the
  consumable slots are full and a strictly better, affordable consumable is
  visible in the shop (then only the lowest-value held Tarot is sold —
  `docs/CLAUDE_BATCH3_REVIEW.md` M2).
- Rookie keeps today's behaviour (`hand_tarots = false`).

## Logging (L4)

An optional trusted logger port (wired by `runtime_bootstrap`) records a bounded
`use_consumable_on_hand` event per dispatch. The trusted production logger
(`core.lua` -> `src/logger.lua`) accepts only its primitive field allowlist, so
the details are encoded entirely in existing allowlisted fields:

- `code` — the executor outcome (`exec_ok`, `exec_illegal`, …);
- `action` — the allowlisted, visible Tarot center (omitted when the source is
  face-down, debuffed or off-allowlist, whose center is never read);
- `count` — the number of targets;
- `detail` — `src=<consumable:n> refs=<hand:a,hand:b> highlight=<cleared|kept>`,
  with the exact ordered positional refs and the actual highlight state.

Every value is a bounded primitive; `card_refs` are normalized `hand:n`
positions (a forged table, an oversized string or a wrong-zone ref is omitted),
and `detail` stays inside the logger's 96-byte cap. Hidden card values are never
read and the logger call is `pcall`-wrapped, so a throwing or malformed logger
never affects a dispatch. No correlation id is emitted or claimed: an action id
is longer than the logger's 96-byte string cap and would be truncated, so it
cannot survive production formatting. The Python decision log also records the
allowlisted center (derived from the sanitized observation) and the positional
refs, reusing the existing decision record.

## Tests

- **Adapter:** the ten Tarots get bounded hand-ref selections within the
  engine's min/max, never face-down/Stone/debuffed; unlisted Tarots, a debuffed
  source, a shop phase and a PvP-blocked state get none; a 12-card/8-Joker/
  3-Tarot hand keeps play/discard capacity, the 24-Tarot bound and a few Joker
  reorders under the 120 cap.
- **Observation/actions:** a hand ref outside the hand phases and a target ref
  in the hand phase are both rejected.
- **Executor:** direct negatives (off-allowlist/hidden/debuffed source; hidden,
  Stone, masked or debuffed target; enhancement on a non-base card; singleton
  and Death-pair shapes), highlight cleared on refusal and no-op, forged and
  stale actions refused with no engine call, log-trace normalization of forged/
  oversized/table/foreign-zone refs, and a throwing or malformed logger that
  never affects a decision. A permanent regression runs the executor record
  through the real `src/logger.lua` filter (the production bridge) and asserts
  the formatted line still contains the identity, ordered refs, outcome and
  cleanup, on both Lua runtimes.
- **Policy:** Strength on a kicker, Death copying an Ace, a suit Tarot
  completing a flush, a no-gain Tarot held; held-Tarot budget inside the
  2,000,000-instruction cap across 8–12 cards, 5/8 Jokers, PvP/no-clear and
  Competitive/Major League/Expert; allowlisted Tarots bought and retained.
- **Isolation certificate / cross-service:** re-run and re-certify (still
  pending; no native certification is claimed).

## Out of scope

- Targeted picks from Arcana packs (hand shown during booster selection).
- The Hanged Man (destroys cards).
- Spectral cards with targets (seals, Cryptid, Aura).
- Wiring a `target_selection` port.
- Raising any cap or sandbox limit.
