# Baseline sparring policy — bounded, observable-only

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.

Status: chunk 1 of `docs/PLAYABLE_PLAN.md` ("Observation-only bounded baseline
policy, three honest difficulties, stable development gauntlet seeds, policy
tests across Lua 5.1/LuaJIT"). This document covers only the baseline policy
module and its tests. Integration, the trusted view/certificate producer,
orchestration, launcher and UI remain other workers' scope and are not
implemented here. The trusted production executor in
`AISparring/integration/production_executor.lua` now exists and is enabled behind
its own trusted gates, but the policy described here is still inert and
restricted: it has no engine access and no authority (see section 7).

Read with `AGENTS.md`, `docs/AI_OBSERVATION.md`, `docs/LEGAL_ACTIONS.md`,
`docs/M2_EXECUTION_BOUNDARY.md` and `docs/FAIRNESS.md`.

## 1. What this is

`AISparring/ai/baseline_policy.lua` is a pure factory that produces a **text-only
Lua source string** for each of three difficulties. The source string is the
policy chunk the existing restricted worker expects: when loaded it evaluates to
`function(observation, actions)`.

The module itself is not a policy runtime. It contains no `loadstring`, no
`dofile`, no `require`, no engine access, no RNG and no IO; it only renders a
self-contained chunk from a fixed template plus a difficulty configuration. All
decision logic lives inside the generated chunk and uses only the restricted
environment's whitelist (`type`, `math.floor`/`min`/`max`, `string.byte`/`sub`,
`#`, arithmetic).

The generated chunk is an actual modest strategy, not an action-type weight
table: it reads only the sanitized visible observation, recognizes made poker
hands, decides whether a discard is better than a weak play, and treats shop
money as a budget with a reserve and interest opportunity cost.

## 2. Module API

```lua
local BaselinePolicy = dofile("AISparring/ai/baseline_policy.lua")

BaselinePolicy.difficulties()        -- { "rookie", "competitive", "major_league", "expert" }
BaselinePolicy.describe()            -- fresh deep copy of the three configurations
BaselinePolicy.source(difficulty)    -- source string, or nil + bounded code
```

- `source` returns a non-empty string within the 64 KiB worker source cap, or
  `nil, "baseline_unknown_difficulty"` for a non-string/unknown difficulty.
- `BaselinePolicy.CODE` exposes the bounded codes (`baseline_ok`,
  `baseline_unknown_difficulty`, `baseline_bad_config`, `baseline_bad_source`,
  `baseline_source_too_large`). The 64 KiB guard is enforced in the generator as
  well as the worker.
- `describe` and `difficulties` return copies; mutating them cannot change the
  module's private configurations.
- The module is deterministic: the same difficulty renders byte-identical source
  on both Lua 5.1 and LuaJIT 2.1 (pinned by cross-runtime source hash vectors).

The configuration is baked into the generated chunk at render time; no
configuration table is passed to the restricted environment, so a loaded policy
cannot be reconfigured from inside the sandbox.

## 3. Chunk contract

The generated chunk returns:

```lua
function(observation, actions)
  -- observation: the sanitized AIObservation export (visible fields only)
  -- actions:     the legal action candidates regenerated from that observation
  -- returns:     one element of `actions` (or nil when there is none)
end
```

Guarantees:

1. **Only provided legal candidates.** The function iterates the supplied
   `actions` array and returns one of its elements; it never synthesizes,
   constructs or mutates an action. The worker re-validates the selection against
   the canonical handle, so an out-of-set or mutated result is rejected upstream.
2. **Deterministic canonical ties.** Each candidate is scored with integer
   arithmetic; equal scores are broken by an explicit byte-wise comparison of the
   candidate `id` (the canonical encoding), the same ordering used by
   `actions.generate`. The result does not depend on input iteration order.
3. **Bounded evaluations.** The loop evaluates at most `max_actions` (256)
   candidates independent of the supplied array length, and each evaluation does
   bounded work over a bounded selection plus a bounded lookup into a `<= 16`
   visible shop/booster array. No recursion.
4. **No globals, seed, RNG or IO.** The chunk writes only locals. It uses no
   `math.random`, no `io`/`os`/`debug`, no clock, no seed and no network.
5. **Visible fields only.** Scoring reads only schema fields already part of the
   sanitized export: card `rank`/`suit`/`center`/`edition`/`seal`/`debuff`,
   visible joker `center`/`edition`/`seal`/`debuff`, `self.money`/`credit_limit`/
   `hands`/`discards`, `match` slots (`joker_slots`), shop
   `kind`/`center`/`edition`/`cost`/`sell_cost`/`reroll_cost`, booster card kind,
   and the consumable target `min_targets`/`max_targets` bounds
   (`consumable_target`, falling back to `context`). Unknown keys, poisoned
   fields, hidden order, sale proceeds and seed-derived state are never present in
   the export and are never read.

Malformed input returns nil (`observation`/`actions` not tables, an action
without a string `type`), which the worker reports as `policy_no_action`.

## 4. Scoring

Cards are identified by their observation-local `zone:ordinal` refs and looked up
in `self.hand`. Ranks are parsed from the real game spellings
(`"Ace"`, `"King"`, `"Queen"`, `"Jack"`, `"10"`, `"2".."9"`), with the short
aliases `A/K/Q/J/T` accepted for robustness; suits are recognized from
`Hearts`/`Diamonds`/`Clubs`/`Spades`. Unknown/redacted cards make a play
conservatively low rather than guessed.

A play selection is classified by its visible ranks/suits:

| Category | value |
|---|---|
| high card | 1 |
| pair | 2 |
| two pair | 3 |
| three of a kind | 4 |
| straight (incl. Ace-low `A-2-3-4-5` and Broadway `10-J-Q-K-A`) | 5 |
| flush | 6 |
| full house | 7 |
| four of a kind | 8 |
| straight flush | 9 |

`score = category*100000 + primary_rank*1000 + rank_sum*2 - extra_cards*junk`,
plus a small enhanced/edition bonus and a heavy per-debuffed-card penalty. The
category weight is dominant, so any made hand beats any high-card play, and
within a category a compact play beats a junk-padded one of the same category.

### 4.1 Estimated chips × mult (cloud improvement)

When `estimate_plays` is on (every difficulty), all certified `PLAY_CARDS`
candidates are first analysed once per decision (`analyse_plays`):

- **Scoring cards** follow Balatro rules. The pair cards of a Pair, the top card
  of a High Card, the four of Four of a Kind, all five cards of a Straight,
  Flush or Full House, and Stone cards always.
- **Base** is the hand's displayed chips/mult from `self.hand_levels` (planet
  levels) when `use_levels` is on, otherwise its level-1 values. The chips of
  the scoring cards are added (2–10 face value, J/Q/K 10, A 11).
- **Card effects,** in Balatro's order per scoring card: rank chips, then the
  enhancement (Bonus +30 chips, Mult +4, Stone +50 chips, Lucky +4 expected mult
  from 1 in 5 for +20, Glass ×2), then the card's edition (Foil +50 chips, Holo
  +10 mult, Polychrome ×1.5), then per-card Joker triggers. A red seal
  retriggers all of it, including Photograph's ×2 on the first scoring face
  card.
- **Held cards:** Steel ×1.5 while held.
- **Jokers**, when `est_jokers` is on: a fixed table of simple, public effects
  keyed by the visible Joker `center` (`JOKER_EFFECTS`: flat and ×mult, suit,
  face, even/odd, Fibonacci, Scholar and Walkie Talkie per-card effects, the
  "contains a hand" +mult/+chips/×mult family, Half, Abstract, Baron, Shoot the
  Moon and Photograph). Joker editions apply in Joker order, so ×mult after
  +mult is modelled.

Unknowns count as neutral: boss-blind effects (for example The Flint halving
base chips and mult), scaling Jokers' current values, boss
effects, probabilities beyond Lucky's expectation and any Joker not in the table.
Abstract Joker counts every Joker, debuffed included. When a Joker that changes
what a hand is (Four Fingers, Shortcut, Smeared, Splash, Pareidolia) is present,
the estimate is not used at all and the category ranking decides. Estimates are
clamped at 1e15, and NaN is clamped too. The estimate is for comparing plays,
not an exact score.

A play then scores `400000 + 300000·est/(est+scale)`, where `scale` is this
decision's best estimate (at least 1000), so late-game values keep resolution, so every play outranks any
non-discard alternative and a higher estimate always wins. When `use_requirement`
is on and the displayed `blind_requirement` is readable (non-PvP only), a play
whose estimate reaches the remaining requirement gets +250000, so it is always
preferred.

**Draw-aware discards (`discard_ev`, Competitive and Major League).** Each
certified discard is valued by the expected best follow-up play:

- the best estimated play among the kept cards, improved by the most valuable
  reachable target, weighted by its hypergeometric chance with the same number
  of draws;
- targets are completing a flush, one more card of a kept rank, and a straight
  missing exactly one rank;
- unseen cards follow a standard 52-card prior minus the visible hand, capped by
  the displayed deck total. Only general knowledge and the visible hand are
  used: no deck order and no hidden deck contents.

The adapter also offers discard-specific candidates. Each keeps a flush draw, all
made rank groups, or a four-rank straight draw, or drops only the lowest junk;
valuable (enhanced, sealed or editioned) cards are never discarded. Discards are
ranked by that expected value, and the old per-card heuristic only breaks ties.
Rookie keeps the per-card heuristic.

On the **last hand** with a known requirement, discards are ranked by the chance
that the follow-up play reaches what is still needed, and expected value only
breaks ties: only a clear matters then. The draw-aware evaluation is bounded
by the budget rules in §4.5.
Imagined drawn cards (rank groups, full house, straight fillers) take a suit
no owned suit Joker rewards where possible. This is conservative: a real draw
could land on a bonus suit. Target plays are priced with the kept cards whose effect applies while held
(Steel; Kings with Baron; Queens with Shoot the Moon), the same way the current
best play is priced. Other held cards add nothing and are left out for the
budget. Drawn cards are priced so they cannot overstate the target: flush fillers use
ranks nobody kept, and a straight's missing card takes a suit none of the kept
cards share.

**Known limitation.** The draw prior is a standard 52-card deck minus the visible
hand. The adapter never reads `G.deck` (a documented boundary), so deck
depletion within a round and cards added or destroyed are not modelled.
Exporting the displayed deck count would fix that, but it needs an
architecture review of that boundary first.

**Discard mode.** This applies when no play clears, discards and hands remain,
and one of the following holds:

- the best play is only a High Card;
- it is the last hand and a requirement is known;
- (with `use_requirement`) `best_est × hands_left < discard_need_pct% × remaining`;
- (with `discard_ev`) the best discard's expected value exceeds
  `discard_gain_pct%` (150) of the best play now. Every discard candidate
then gets +1000000, and the existing discard scoring picks which cards go. With
enough hands left to clear the blind, the policy plays instead of wasting
discards.

### 4.2 Shop Jokers and Joker order (Competitive, Major League)

A shop Joker adds `joker_gain_value` (400) × its **marginal gain**, capped at
+300%. The gain is how much it raises the estimate of a fixed, deterministic
panel of representative hands, given the Jokers already owned and the displayed
hand levels. The panel weights: pair ×4, two pair ×2, and three of a kind,
flush, straight and high card ×1 each. For example, with nothing owned a +4-mult
Joker beats The Duo on this pair-heavy panel. With Gros Michel (+15 mult) owned,
The Duo's ×2 wins. Unknown Jokers keep the flat kind value, and
rule-changing Jokers switch this off. Scaling Jokers grow over a run, and their
current value is not in the observation, so an **offered** one (shop or pack)
is priced as a conservative mid-life proxy of its public card text (`SCALING`).
Only Jokers that grow from what this policy actually does (plays, discards,
rerolls, planets) are listed. Examples: Green Joker +3 mult, Ride the Bus +5
mult, Constellation ×1.3, Hologram ×1.15, Runner +30 chips. Ride the Bus gets
no proxy when an owned Joker scores face cards, which reset it. Some Jokers
grow only from actions the policy never takes (skipping blinds or packs,
selling, avoiding its most-played hand, Lucky cards): Throwback, Red Card,
Campfire, Obelisk and Lucky Cat. They get no proxy. Neither do Vampire, which
strips enhancements the estimate values, and Madness and Ceremonial Dagger,
which destroy Jokers. The proxies never enter play estimates, and owned
scaling Jokers still count as no effect there. An owned scaling Joker has no
known effect, so it also turns off estimate-based Joker reordering for that
row. Proxies depend on the public ante, because a Joker bought early has more
rounds to grow: the growth is ×1.25 at antes 1–2, ×1 at 3–4 and ×0.75 from
ante 5 (for ×mult proxies only the part above ×1 is scaled). Flash is +2
(it grows only in rich runs that reroll). An additive Joker (+mult, +chips, hand bonuses, Half,
Abstract) is priced before the **trailing run** of owned ×mult or Polychrome
Jokers. The adapter's reorder offers only a reversal and adjacent swaps, each
taken only above a 0.5% panel gain. Passing a ×mult Joker is such a gain,
while a neutral Joker in between (per-card, held or another additive Joker)
would stop the move. So this pricing applies only when the post-purchase row
qualifies for the estimate-based reorder: every Joker known, none pinned,
debuffed or redacted, and at most 8. Otherwise the new Joker is priced at the
end of the row. Residual risk: the adapter sends no reorder when an
engine-pinned card is present or its certificate cap is reached, and then the
move never happens.

A `REORDER_JOKERS` candidate is judged by the same panel when every owned Joker
has a known effect and none is pinned. It is taken only if it improves the panel
by more than 0.5%. Its score grows strictly with the improvement but stays below
`reorder + reorder_bonus`, so reordering never starves plays or purchases, and
for fixed hand levels it cannot oscillate. It applies only to rows of at most 8
Jokers and scores at most 20 reorder candidates per decision, which keeps the
instruction budget. Otherwise the tier rule below applies. A shop Joker's gain
is halved when buying it would drop money below the reserve.

### 4.3 Consumable safety floor (all difficulties)

A consumable use is refused when its visible downside would wreck the run:

- Wraith (sets money to $0) while money is $10 or more;
- Ankh or Hex (destroy other Jokers) with two or more Jokers owned;
- Ectoplasm or Ouija (permanent -1 hand size), always.

The same rule applies wherever the card could hurt or waste a slot:

- a refused card is never **bought** from the shop;
- it is never **picked from a pack**, because Arcana and Spectral picks are used
  at once. If every card in the pack is refused, the pack is skipped. The
  adapter builds every pack card as a playing-card record (`kind = "card"`), so
  the policy classifies it by its public center: `j_*` is a Joker, and any other
  `c_*` except `c_base` is a consumable (`pack_card_kind`);
- a refused card already **held** is sold in the shop
  (`leave_shop + sell_harmful`, 30), which frees the slot for planets and
  tarots. Cards that pass the rule are kept.

**Consumables that need hand targets** get the same treatment, because
they can never be used live. Examples: Strength, Death, the suit and
enhancement Tarots, Aura, Cryptid (`TARGETED`). The live runtime wires no
target-selection port, so `CONSUMABLE_SELECTION` never occurs there. Such a
card is therefore never bought, and a held one is sold to free its slot. Pack
picks are already gated by the engine's own `can_use` predicate. If the port
is ever wired, `TARGETED` must be revisited: `test_source.lua` fails when
`companion_host.lua` mentions `target_selection`. Arcana and Spectral packs
are discounted (−10) for the same reason.

Planet cards (and Black Hole) get +1000 over other uses, so levels are banked
first. At Competitive and above, **The Hermit** (double money, at most
+$20) is held until money reaches $20. The exception is when consumable slots
are full: then it is used at once to free a slot. Every other consumable keeps the flat `use_consumable` score.

### 4.4 Vouchers and packs (Competitive and above)

**Vouchers.** With `voucher_values`, a voucher scores `voucher + VOUCHER_VALUE`
+ economy. The ranking is:

- +1 Joker slot, hands or hand size first (Antimatter 260; Grabber, Nacho Tong
  200; Paint Brush, Palette 160);
- then discards and shop slots (130/120);
- then shop economy and planet vouchers (80 down to 20).

Hieroglyph and Petroglyph (-1 ante, but a hand or discard lost every round)
get -300, so leaving the shop beats them. Omen Globe, Magic Trick, Illusion,
Director's Cut and Retcon are deliberately +0, as are unknown vouchers.
Multiplayer gamemodes that ban vouchers (for example Attrition) already remove
them from the legal actions. Rookie keeps the flat score. A minor voucher
(value ≤ `MINOR_VOUCHER`, 10: Blank, the neutral ones and unknown ones) is
never bought if it would leave money below the reserve. Before this, a $10
Blank could take the last $10.

**No crowding out Jokers (`versus_joker`).** The reference is the best
*certified* Joker purchase in this shop decision, by its full buy score:
`item_joker` + edition + estimated gain + economy after its own price. Only a
Joker scoring above `leave_shop` counts. The adapter certifies a Joker buy only
when it fits, so full slots mean no reference, except a Negative Joker, which
needs no slot. Against that Joker, a voucher or pack is scored like this:

- its intrinsic value (`voucher + VOUCHER_VALUE`, or `item_booster +` pack
  bonus) is capped at that Joker's intrinsic value − `JOKER_MARGIN` (50), so table values cannot
  crowd out a Joker the estimate values flatly;
- then each item's economy after its **own** price is added, so the comparison
  is utility after costs;
- if the Joker and the voucher/pack both fit the money, the Joker is bought
  first: the voucher/pack is kept below the Joker's full score. The other item
  stays affordable afterwards, so this only orders the purchases.

A voucher or pack can still win when only one fits and the Joker would drain
the money. For example, at $10 an unmodelled $9 Joker loses to a $4 Celestial
pack. This is not an absolute Joker-first rule. It replaces the earlier flat
`item_joker - 20` cap, which compared a pack's capped value plus the economy
after its lower price against a pricier Joker. At $12, a $4 pack could then
beat a $6–7 Joker purely through the reserve penalty (review M1).
`tests/policy/test_shop_joker_first.lua` pins these cases:

- Joker, pack and voucher prices;
- interest breakpoints;
- a strong Joker against a weak pack;
- a draining Joker against a strong pack or voucher;
- full slots, a free slot and a Negative Joker with full slots;
- Rookie.

**Opening packs.** With `smart_packs`, an `OPEN_BOOSTER` action gets a bonus by
center prefix:

| Pack | Bonus |
|---|---|
| Buffoon, with a free Joker slot | +60 |
| Buffoon, all Joker slots full | never opened (only a Negative Joker could be taken) |
| Buffoon, slot count unknown | 0 |
| Celestial | +30 |
| Arcana | −10 (most cards need hand targets) |
| Spectral | −10 (same) |
| Standard (`p_standard*`, Multiplayer `p_mp_standard*`) | -20 |

**Picking inside a pack.**

- A Joker adds its panel-estimate gain, as a shop Joker does (§4.2), plus its
  edition value.
- A planet adds `planet_level_pick` (6) × the displayed level of the hand it
  upgrades, capped at level 20, so an already-levelled hand keeps compounding.
  Black Hole adds 40.
- A playing card adds half its edition value, 15 for a seal and 10 for an
  enhancement other than Stone (Stone loses rank and suit).

The safety floor (§4.3) applies first.

Purchases are scored by item kind plus a small edition weight: a recognized
non-negative edition (`foil`/`holo`/`polychrome`) adds a fixed bonus over an
un-editioned copy and the `negative` edition keeps its bounded slot-saving bonus.
This is what lets the buying policy prefer a visible upgrade over an otherwise
equivalent inferior copy of the same kind, without a joker tier list.

Discards are scored near a fixed base with per-card adjustments: discarding a
card that is part of a pair, a flush-draw suit, a straight run, a sealed or
enhanced card is penalized; discarding an unmatched junk card (or a debuffed
card) is rewarded. A discard therefore beats a weak high-card play but loses to a
made pair, and it prefers to keep made components. The discard score is capped so
it always stays below a made-pair play. A discard scores `nil` when the visible
`self.hands` count is `0`, because no hand can be played afterwards (for example
while waiting on a PvP opponent); the AI then waits instead of discarding.

### 4.5 Instruction budget and source size

The sandbox gives every decision 2,000,000 VM instructions
(`PolicyEnv.INSTRUCTION_BUDGET`). A decision that exceeds it is refused, and
three refusals in a row end the AI's match. The play phase is the expensive
part, so it is bounded deterministically:

- **Work meter.** Every score estimate charges (cards read) × (Jokers applied
  \+ 2) to `WORK`, which is reset per decision. Each draw-aware discard evaluation
  also charges its structural cost, `kept × (110 + 20 × discarded)`. Measured on
  Lua 5.1, one unit costs about 50 VM instructions. The charge counts each
  played card once, so Red-seal retriggers cost more than they are charged. The
  limits were calibrated on Red-seal-heavy hands; re-measure before raising
  either one.
- **Cheap first pass.** Discard candidates are ranked by the per-card heuristic
  (`discard_score`), with the id breaking ties. The best ones get the draw-aware
  evaluation until 40 candidates or `DISCARD_WORK` (24000) units are used.
  Unevaluated candidates keep their heuristic score, which is below any
  evaluated one.
- **Hard stops.** Hands over 12 cards skip the draw-aware search. If the
  projected play-estimate cost (plays × hand size × (Jokers + 2)) exceeds
  `PLAY_WORK` (24000), which only happens at absurd sizes (for example
  12 cards / 64 Jokers or 32 / 40), plays keep the category ranking.
- **Absolute cap.** The discard allowance is `WORK + DISCARD_WORK`, but never
  more than `TOTAL_WORK` (30000) for the whole decision. Before this cap, a play
  estimate close to `PLAY_WORK` plus the full discard share could reach the
  budget with 12 cards and 48+ Jokers (re-review N2). The test's absurd shapes
  now measure at most 1.11M and are held to a 1.25M guard. Heavy per-card
  Joker rows (12 cards / 20–64 Jokers) reach about 1.28M, still well under the
  budget.

Measured worst cases use the real adapter catalogue (≈40 plays + ≈40 discards),
3 discards and 3 hands left, and cards with enhancements, Red seals and
editions. Instructions are counted by the sandbox hook (`PolicyEnv.last_instructions`):

| Hand / Jokers | Before (Expert) | After: Competitive / ML | After: Expert | Rookie |
|---|---|---|---|---|
| 8 / 5–16 | 1.15–1.58M | ≤ 0.99M | ≤ 1.07M | ≤ 0.18M |
| 9 / 5–16 | 1.44–1.89M | ≤ 1.05M | ≤ 1.14M | ≤ 0.19M |
| 10 / 5–16 | 1.75M – **fail** | ≤ 1.13M | ≤ 1.21M | ≤ 0.20M |
| 11 / 5–16 | **fails most cases** | ≤ 1.16M | ≤ 1.26M | ≤ 0.22M |
| 12 / 5–16 | **fails almost always** (Comp/ML also fail) | ≤ 1.28M | ≤ 1.36M | ≤ 0.23M |
| 16 / 16, 24 / 24 (no discard search) | 0.41M, 0.71M | same | same | — |
| 32 / 40, 48 / 64 (category fallback) | 1.19M, **fail** | ≤ 0.23M | ≤ 0.23M | — |

The "before" column used plain cards with 5 or 8 Jokers (8 seeded deals per
cell); "after" used 10 enhanced deals per cell with 5, 8 and 16 Jokers.
These ranges hold for PvP and for non-PvP states where no play clears, on
Lua 5.1 and on LuaJIT (the sandbox turns the JIT off, so both count
interpreted instructions). An independent re-review reran the original
review's grid: 30 seeded hands per cell, 9–12 cards, 5 and 8 Jokers, PvP and
no-clear, 1 or 3 hands left, plain and enhanced cards, 5,760 decisions per
runtime. It found 0 failures, with peaks of 1.337M on Lua 5.1 and 1.356M on
LuaJIT. A wider sweep with 20 Jokers peaked at 1.43M. Shapes below
`PLAY_WORK` run the full play estimate. Before `TOTAL_WORK`, 12-card shapes
with 48–64 Jokers could still exceed the budget (re-review N2); with it, they
measure at most 1.11M. Shapes past `PLAY_WORK` fall back. After held-card pricing (Steel, Baron,
Shoot the Moon) was added, a stress run found a peak of 1.295M over 2,304
decisions per runtime. It used 9–12 card hands of Steel cards, Kings and
Queens, with Red seals and Polychrome, 2–16 Jokers including Baron and Shoot
the Moon, and PvP and no-clear blinds.
Decision latency in these cases is 35–100 ms
on Lua 5.1 in the cloud container. Failures after the change: 0.
`tests/policy/test_budget.lua` runs all of these through the real adapter and
fails any decision above 1.6M instructions. It records the chosen action ids as
cross-runtime vectors, so Lua 5.1 and LuaJIT must pick identical actions. With
the meter disabled, 18 of its cases fail.

The ranking changes how many 8-card discard candidates are evaluated only in
the costliest states. The discard-quality benchmark is unchanged: forced
discard quality stays 0.85–0.86 for Competitive and above.

**Source size.** The sandbox rejects sources over 65,536 bytes. The repository
template keeps its comments and indentation. `BaselinePolicy.source` renders a
stripped copy, which:

- removes line comments outside strings;
- removes indentation, trailing whitespace and blank lines;
- keeps line breaks, so tokens never merge;
- refuses long brackets, so a future template cannot be half-stripped.

`BaselinePolicy.readable_source` renders the unstripped copy for tests only.

| | Rendered size |
|---|---|
| Before (`97358b8`, comments included) | 64,303–64,310 bytes (≈1,230 bytes of headroom) |
| This change, if unstripped | 66,538–66,545 bytes (over the cap) |
| This change, stripped | **51,544–51,551 bytes** (≈14.0 KB, 21%, under the cap) |
| After the follow-up backlog commits | 53,110–53,117 bytes (≈12.4 KB under the cap, 4.2 KB under the guard) |

`BaselinePolicy.SOURCE_GUARD` is 57,344 bytes (56 KiB).
`tests/policy/test_source.lua` fails when a rendered source exceeds it or when
the guard is raised, so growth has to recover space before it can creep back to
the hard cap. The same file checks that the stripped and readable sources choose
the same actions on a spread of play, shop, pack and consumable frames.

## 5. Difficulties

All three difficulties share the same safety guarantees and the same observable
information; they differ only in heuristic aggressiveness/quality constants (no
information or authority differences).

| Constant | rookie | competitive | major_league |
|---|---|---|---|
| `reserve` (money kept) | 6 | 10 | 12 |
| play junk penalty / extra card | 250 | 400 | 550 |
| discard junk value / card | 5000 | 6000 | 7000 |
| discard pair-preservation penalty | 16000 | 20000 | 24000 |
| `reroll_base` / surplus cap | 70 / 160 | 55 / 120 | 55 / 120 |
| `leave_shop` | 80 | 90 | 90 |
| `reorder` / max improvement bonus | 105 / 10 | 105 / 10 | 105 / 10 |
| negative-edition bonus | 120 | 150 | 180 |
| recognized-edition buy bonus / `slot_sell` | 40 / 220 | 40 / 220 | 40 / 220 |
| `estimate_plays` (chips × mult play scoring) | on | on | on |
| `est_jokers` (visible Joker effects in the estimate) | off | on | on |
| `use_requirement` (clear-first, requirement-driven discards) | off | on | on |
| `discard_need_pct` | n/a | 90 | 100 |
| `discard_ev` (draw-aware discard ranking) | off | on | on |
| `use_levels` (displayed poker-hand levels in the estimate) | off | on | on |
| `joker_gain_value` (panel-based shop Joker value; order by panel) | used only with `est_jokers` (off) | 400 | 400 |
| `voucher_values` (per-voucher values, §4.4) | off | on | on |
| `smart_packs` (pack kind preference and value-aware picks, §4.4) | off | on | on |

**Shop economy (run-level evidence).** `tests/benchmark_runs.py` showed Major
League and Expert hoarding money above the $25 interest cap, where it earns
nothing, and clearing fewer blinds than Competitive. Their shop settings now
use Competitive's reroll and leave values with a reserve of 12, still graded
above Competitive's 10. The retune was chosen on seed 11. It was then judged
on held-out seeds 37 and 41 (150 paired runs each, no credit,
against the pre-retune policy from `5b0cd64`:
`git show 5b0cd64:AISparring/ai/baseline_policy.lua > /tmp/old.lua`, then
`python tests/benchmark_runs.py --paired /tmp/old.lua --seed 37 --runs 150`):

| Held-out seed | Major League | Expert |
|---|---|---|
| 37 | +0.25 blinds per run (t = 1.7) | +0.35 (t = 1.8) |
| 41 | +0.41 (t = 1.9) | +0.67 (t = 2.8) |
| Pooled, 300 runs | ≈ +0.33 (t ≈ 2.5) | ≈ +0.51 (t ≈ 3.3) |

The first in-sample figures (+0.69 and +0.24) were measured with a simulator
that allowed $5 of credit, and are superseded. The simulator has no packs or
vouchers, so LV-10 should watch whether these tiers now save too little for a
$10 voucher.

**Expert** (`expert`, fourth tier) is Major League with a deeper draw search and a more
willing discard and shop profile. It adds two draw targets: full house from two
pair, and straights missing two ranks. Its settings are `deep_draws = true`,
`discard_gain_pct = 130` (not 150), `discard_need_pct = 110` and
`joker_gain_value = 500`. It uses exactly the same observation as every other
tier. On the cloud benchmark it is currently only marginally different from
Major League (forced-discard quality 0.846 vs 0.845). Real separation is
unproven until live Gauntlet runs.
| `start_timer` (press the MP timer on a slow opponent) | 0 (never) | 1000 | 1000 |

Observable consequences (pinned by tests):

- **rookie** is more willing to spend, reroll and churn; it still preserves made
  hands and respects a small reserve.
- **competitive** is the balanced default.
- **major_league** keeps the largest reserve, is the most conservative about
  junk-padded plays and damaging discards, and rerolls only with a large surplus.

These are honest baseline differences in a generic scorer, not a strength claim
and not an evaluator: the real Major League engine adjudicates every effect, cost
and outcome.

## 6. Action coverage (conservative)

Every action type the legal-action generator can emit is handled, so the policy
can return a candidate whenever one is offered, with deliberate exceptions. A
candidate whose score is `nil` (unaffordable item, unparsable visible cards, a
consumable use below its visible minimum target count, an unjustified or
out-of-shop sell, a hand reorder, or a non-improving joker reorder) is skipped; if
everything is skipped the policy returns no action.

| Action | Treatment |
|---|---|
| `SELECT_BLIND` | Preferred; skipping is disfavoured. Selection never depends on any exported `hands` count. |
| `SKIP_BLIND` | Low. |
| `START_TIMER` | While readied at the PvP blind: `start_timer` (1000) for Competitive and Major League, so it is pressed as soon as it is offered. Rookie has `start_timer = 0`, so the score is `nil`: it leaves the timer alone, like a casual player. |
| `PLAY_CARDS` | Scored by the made-hand classification; made hands dominate weak longer plays. |
| `DISCARD_CARDS` | Can beat a weak play; preserves made components, sealed/enhanced cards. |
| `BUY_ITEM` | Budget-aware: kind utility plus a recognized-edition bonus plus interest/reserve adjustment; a cheaper equivalent is preferred, an edition upgrade is preferred over an un-editioned copy. |
| `BUY_VOUCHER` | Highest-valued purchase (permanent), still reserve-aware. |
| `OPEN_BOOSTER` | Preferred purchase of a visible pack, reserve-aware. |
| `REROLL` | Selective: only meaningful above a surplus threshold; otherwise leave. |
| `LEAVE_SHOP` | The usual resolution when nothing is worth buying or money is tight. |
| `SELL_JOKER` | Scored only in `SHOP` under visible slot pressure (full joker board plus a specific, already-affordable, strictly-better same-center copy on offer); no score in every other phase. |
| `SELL_CONSUMABLE` | **Never selected** (no score); consumable slot pressure is not implemented. |
| `SELECT_BOOSTER_ITEM` | Preferred pack pick; known kind weighted. |
| `SKIP_BOOSTER` | Positive but well below picking; also the only option when nothing is usable. |
| `SELECT_TARGETS` | Highlight step in `CONSUMABLE_SELECTION`, chosen only when no committing `USE_CONSUMABLE` is legal. |
| `USE_CONSUMABLE` | Positive in self-bearing phases; in `CONSUMABLE_SELECTION` a committing candidate (visible target count at or above the visible `min_targets`) outranks `SELECT_TARGETS`. |
| `REORDER_JOKERS` | Selected only for a strict, monotonic improvement against a visible-identity target order (see below); otherwise no score. |
| `REORDER_HAND` | **Never selected** (no score). |
| unknown type | Scored `0`, chosen only when nothing known is offered. |

**Consumable target commit priority.** In `CONSUMABLE_SELECTION` the adapter
certifies `SELECT_TARGETS {target:i}` together with committing
`USE_CONSUMABLE {target:i}` whenever `min_targets <= 1`. The committing use is
scored above the highlight, so the policy resolves the selection instead of
re-highlighting forever; `SELECT_TARGETS` is only chosen when no committing use
is offered. A `USE_CONSUMABLE` whose visible target count is below `min_targets`
(or whose bounds are not visible) scores `nil` and is never fabricated.

**Slot-pressure sale (SHOP-only).** Outside `SHOP`, `SELL_JOKER` and
`SELL_CONSUMABLE` are assigned no score in every phase, so the AI never sells
while waiting on a PvP opponent or anywhere else (it was previously scored, which
let the AI dump every joker while waiting with no hands left). Inside `SHOP`, a
`SELL_JOKER` scores only when **all** of the following hold on visible fields:

- the visible joker board is full (`#self.jokers >= match.joker_slots`);
- the sold candidate is a visible, non-debuffed, **un-editioned** owned copy of a
  recognized vanilla joker `center` (the small `+Mult`/`xMult`/position-sensitive
  set already used for reordering — not a tier list);
- the shop offers a face-up `joker` with the **same visible center** and a
  recognized non-negative edition (`foil`/`holo`/`polychrome`) — a strict,
  source-grounded upgrade of the identical base card;
- that offered copy is already affordable from current spendable cash **while
  preserving the difficulty reserve**. The observation exposes no sale proceeds,
  so a sell is never assumed to fund the purchase (a `sell_cost` is never added).

Every unclear case — unknown/face-down/different center, debuffed copy, an
already-editioned owned copy (so a strictly-better edition cannot be proven), a
`negative` offered copy (which needs no slot), an unaffordable price, or a
non-full board — scores `nil`. A sell is therefore never a fallback: the actor
leaves the shop instead. Selling a single copy drops the board below full, so no
further sale can score in the following frame: there is no dump-all or
sell/reorder loop. The sale deliberately outranks `LEAVE_SHOP`, `REROLL` and a
minor card purchase, and stays below booster/voucher/joker purchases, so it
resolves a genuine slot bottle-neck without pre-empting a real purchase.
`SELL_CONSUMABLE` is never scored: consumable slot pressure is not implemented.

**Joker reorder (monotonic).** The baseline recognizes a small, conservative set
of vanilla jokers by their visible `center` key: additive-`+Mult` jokers (should
trigger first) and multiplicative-`xMult` jokers (should trigger last). Every
other joker — an unrecognized center, a redacted/face-down card, a debuffed card,
or a known position-sensitive joker (`Blueprint`, `Brainstorm`, `Misprint`) — is a
**fixed anchor** and never moves, so the relative order of unknown jokers is
stable and no synergy is rearranged blindly. A known position-sensitive joker
additionally keeps its immediate neighbours. A `REORDER_JOKERS` candidate is
scored only when every anchor keeps its current index, every pinned neighbour is
unchanged, and the candidate strictly reduces the number of ranked inversions
against the target order (`+Mult` before `xMult`). That inversion count is a
bounded non-negative potential that strictly decreases on every committed
reorder, so termination is guaranteed: a reverse/adjacent `A → reverse(A) → A`
oscillation is impossible, an already-ordered board never reverses, and a reorder
that cannot strictly improve is never chosen. The score is a small positive value
above `LEAVE_SHOP` but below every purchase utility, so an improving reorder can
resolve a shop instead of leaving, while a real play, discard, purchase or
consumable use always outranks it. `REORDER_HAND` remains unscored and is never
selected.

### Known limitations (honest)

- **Joker reorder is intentionally narrow.** Only recognized vanilla
  `+Mult`/`xMult` centers are ranked and only when the candidate strictly reduces
  inversions; every unrecognized or position-sensitive joker is a fixed anchor
  that is never moved. This means ordering-dependent value beyond "additive mult
  before multiplicative mult" (for example chain-mult layouts or
  Blueprint/Copycat positioning) is left on the table. A richer ranking was
  deliberately not invented: the baseline does not guess a joker tier list or
  rearrange synergies it cannot see.
- **Selling is intentionally basic.** The only sale the baseline can justify is a
  SHOP slot-pressure upgrade: full joker board, same visible center, un-editioned
  owned copy, recognized non-negative edition on offer, and already affordable
  without the sale. It never sells to raise money, never sells consumables, and
  never picks a joker to give up by value — so it cannot free a slot for an
  arbitrary stronger-but-different joker (that needs a strategic replacement
  ranking the visible observation does not provide). This is a conservative
  baseline, not a strength claim.
- **Buy ranking is intentionally shallow.** Purchases differ only by item kind,
  a fixed bonus for a recognized non-negative edition (or the negative bonus) and
  the reserve/interest economy term. There is no per-joker utility model, so
  between two same-kind, same-edition purchases the economy term decides.
- **Multi-target consumables are unsupported.** The trusted adapter certifies
  only single-target `SELECT_TARGETS` steps, while the legal-action generator
  rejects a single target when the visible `min_targets >= 2`. In that state
  there is no committing candidate at all, so the policy returns no action rather
  than inventing one and never fakes a successful target callback. This is a
  producer/executor contract gap owned outside this module.
- **The highlight-only frame is synthetic.** The current adapter always emits a
  committing `USE_CONSUMABLE` together with `SELECT_TARGETS` for
  `min_targets <= 1`, so the policy normally commits in a single decision. The
  two-step progression test's first frame deliberately omits the committing
  certificate to pin the "select only when needed" branch. No test and no policy
  path fakes an executor or engine callback.
- **No runtime claim.** The fixtures are synthetic, schema-honest frames run
  against the real generated source in the restricted worker; they are not a
  real-engine capture and establish no in-game behaviour or rules parity.

Conservative denials (do not invent authority):

- No blanket/class authorization; the policy chooses only among certificates the
  trusted producer already certified.
- Unknown action types and unknown item kinds receive no positive weight.
- Empty candidate lists (blocked interaction, expired timer, `MATCH_COMPLETE` or
  no certificates) produce no action rather than a fabricated one.

## 7. Safety and boundary summary

- Source is text-only, within the 56 KiB practical guard and the 64 KiB cap
  (§4.5); bytecode is rejected upstream.
- No global writes; the generated chunk declares only locals.
- No RNG, seed, clock, filesystem, network, process or engine access; the
  restricted environment exposes none of them.
- Only visible, already-sanitized fields are read, and only to score/compare
  candidates the trusted generator produced.
- The worker/orchestrator must still re-validate the selection; the policy has no
  authority and performs no effect. This module is and remains inert: it renders a
  text-only chunk and is not wired to any engine object.
- The trusted production executor (`AISparring/integration/production_executor.lua`)
  now exists and is enabled behind its own trusted gates: it is the only component
  that reaches the engine, re-derives legality from live state and fails closed.
  That does not change this module's contract — the policy still receives only the
  sanitized observation and the certified candidate list, and its chosen action is
  re-validated before any effect.

## 8. Tests

```
python tests/run_policy.py --require-all
```

The harness:

The worker invokes `PolicyEnv.run` in its separate restricted interpreter; this
is not an invocation inside the game VM.

- static-checks the module, documentation and absence of forbidden APIs after
  stripping comments (so a comment mentioning `require(` or a `G` identifier is
  not a false positive, while real `require`/`io.`/`os.`/`math.random`/`_G`
  usages are still flagged);
- runs `tests/policy/test_*.lua` on `lupa.lua51` and `lupa.luajit21`, loading the
  real `codec.lua`, `observation.lua`, `actions.lua`, `baseline_policy.lua` and
  `tools/lua/policy_env.lua`, instantiating `Observation.factory(codec)` and
  `Actions.factory(observation, codec)`;
- compares chosen-action and source-hash vectors exactly across both runtimes;
- drives the real `tools/policy_worker.py` subprocess for all three difficulties
  on both runtimes and checks the returned action type.

The Lua suite includes substantive competing-candidate cases: flush vs pair vs
high card, nonadjacent pairs, Ace-low and Broadway straights, discard-beats-weak
play, discard preservation of a made pair, careless-spend vs reserve, cheaper
equivalent purchases, selective reroll by budget, an adapter-shaped
`CONSUMABLE_SELECTION` frame in which a committing `USE_CONSUMABLE` competes with
`SELECT_TARGETS` and the committing use wins, a two-step highlight-then-commit
progression, a `min_targets >= 2` frame proving no candidate is fabricated, blind
selection with a leftover `hands == 0`, reverse and adjacent-swap reorder frames
yielding stable no action, determinism and canonical tie-breaking, and
independence from poisoned unobservable state (seed/future/RNG keys are
ignored).

The shop-upgrade suite (`tests/policy/test_shop_upgrade.lua`) adds an
adapter-shaped full-board frame where `SELL_JOKER`, a capacity-free `BUY_ITEM`
and `LEAVE_SHOP` compete and the slot-pressure sale wins; a second frame with one
slot freed where the editioned same-center upgrade must win over an inferior
plain copy; a three-step `SELL -> BUY -> no further sale` progression; and
negative cases (equal/worse/unknown center, debuffed owned copy, `negative`
offered copy, unaffordable-from-cash price) that must all leave the shop rather
than sell. Non-SHOP frames with a full board still yield `policy_no_action` for
every `SELL_*`. Every chosen action is asserted to be a member of the generated
candidate set and to be stable on repeat, on both runtimes.

`tests/policy/test_budget.lua` drives the real engine adapter with 9–12 card
hands (and absurd sizes) and asserts every decision stays under a 1.6M
instruction guard (§4.5). `tests/policy/test_shop_joker_first.lua` pins the
Joker/voucher/pack comparison (§4.4). `test_source.lua` enforces the source
guard and stripped-vs-readable equivalence.

Lua fixtures are schema-honest: they are built with the real observation schema
and asserted to observe/export successfully; they are synthetic frames, not
real-engine captures, and do not establish in-game behaviour or rules parity.
The Major League engine, not these tests, adjudicates real play.

## 9. Integration contract for other workers

- **Producer → observation:** build the AIObservation normally; the policy only
  needs the sanitized export plus the generator's candidate list.
- **Orchestrator:** call `BaselinePolicy.source(difficulty)` once per policy
  instance and pass that string to the restricted runner/worker; do not pass the
  module or any configuration across the boundary.
- **Difficulty selection:** `rookie`, `competitive`, `major_league`, `expert`; the string is
  the only difficulty knob, so the same source can be cached and reused.
- **Selection handling:** accept only the returned action and re-validate it; do
  not trust it. Treat `policy_no_action` as a legitimate "no legal choice".
- **Determinism:** identical observation + candidate list yields an identical
  action id on every run and on both Lua runtimes, which keeps gauntlet seeds
  reproducible.

Not implemented here and owned elsewhere: real-engine view/certificate producer,
executor, async orchestration, logging, launcher, staged runtime, UI.
