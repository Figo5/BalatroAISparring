# AI decision review following the Expert playtest

The user completed a Plasma Deck / White Stake match on `2761c5a`, with a
working post-match deck viewer. The opponent lost twice to the timer and once
to a blind. This candidate addresses demonstrated scoring and timing defects;
synthetic agreement and certification are not evidence of expert strength.
Private playtest logs, native game sources and profile data stay outside Git.

## Findings and resulting decisions

| Finding | Resulting behavior |
|---|---|
| Ordinary chips × mult valuation on Plasma | Apply native final balancing to plays, discard targets, shop gains and Joker ordering. |
| Smeared disabled numerical reasoning for the entire run | Model red/black suit equivalence and retain requirement, draw and shop evaluation. |
| Other hand-changing Jokers also disabled estimates | Model Four Fingers, Shortcut, Splash and Pareidolia, including scoring subsets and debuffed Wild cards. |
| AI was at 1× while Player was at 4× | Set only the authenticated staged AI to legal 4× after activation, preserving animations and human preferences. |
| Fixed pauses consumed active countdowns | At most one added second while the AI's own visible timer runs; no added pause in the final 30 seconds. |
| Optional shopping continued under time pressure | In the final 60 seconds skip packs, vouchers, rerolls, non-Joker purchases and reordering; retain immediate scoring Joker buys and legal round progression. |
| Swashbuckler's shown bonus was ignored | Verify and use its actual displayed current mult. |
| Permanent card chip upgrades were ignored | Verify own face-up bonus plus permanent chips against the engine; redact hidden cards and reject tampered projections. |
| The Flint was ignored | Halve and round only base hand chips/mult before card and Joker effects, respecting disabled bosses. |

The decision order remains: obtain a fresh allowlisted own observation, generate
exact legal certificates, estimate the offered plays, compare clearing hands
and bounded draw opportunities, then choose an existing certified action.
Displayed levels, scoring card order, held Steel/King/Queen effects, Red seals,
editions, known scoring Jokers and shown scaling values affect the estimate.
Shop valuation compares bounded representative hands with and without a
purchase, subject to slots, affordability, interest and safety constraints.
The policy does not execute engine calculations or inspect global game state.

## Coverage and limits

| Area | Current treatment and limit |
|---|---|
| Decks and stakes | Actual own hand size, hands/discards, money, displayed levels and legal offers are projected from the selected game. Plasma's distinct scoring is explicit. Initial-deck draw priors and shop panels distinguish standard, Checkered and Abandoned. Erratic avoids assuming a distribution. Depletion and cards added/removed still make these priors approximate. |
| Hand rules | All twelve native categories and the five hand-changing Jokers are modelled. Adapter candidates remain bounded; a best offered play is not necessarily the best possible subset or order. Straight draw targets still favour ordinary consecutive-rank patterns, so Shortcut draws can be undervalued. |
| Jokers | Static scoring effects, allowlisted shown scaling values, both Hanging Chads, Sock and Buskin, Hack and Mime are supported. Blueprint/Brainstorm copy compatible known effects. Other effects retain coarse estimates. Conditional retriggers such as Dusk/Seltzer, Joker retriggers such as the rare reworked Mime, and many conditional effects remain gaps. |
| Bosses | Psychic, Eye, Mouth, Flint and Arm have explicit policy handling; visible card/Joker debuffs and forced selections are respected. Arm's one-level loss is forecast only for visible native linear hand progressions. Unknown growth and other predictive boss effects remain gaps. Engine legality does not by itself establish a good strategic choice. |
| Random effects | Lucky and Misprint use expectations, without sampling future RNG. Nonlinear Plasma scoring makes an expected-component estimate approximate. |
| Economy/build planning | Bounded gains, reserves, interest, voucher/pack values and harmful-consumable refusals. No full-run search, exact future shop prediction, or complete build synergy model. |
| Fairness | Only the AI's own visible active countdown and public own deck rules are added. No enemy cards/hidden score, hidden draw order, future RNG, timer increase, removed animations or runtime external AI calls. |

## Verification

`tests/test_expert_performance.py` runs deterministic synthetic hands through
the real adapter, reader, observation, legal certificates and restricted worker
on Lua 5.1 and LuaJIT. Offered hand categories and scoring subsets are compared
with actual installed Multiplayer/Steamodded hand evaluators loaded from
private local fixtures. Native Plasma flooring, Flint enabled/disabled,
permanent chip addition and every Smeared suit combination are pinned as well.
An independent Python scorer grades best offered choices across 130 deck,
Joker, level, enhancement and boss combinations. Budget and runtime parity
remain mandatory. These checks describe rule/model agreement, not win rates.

Separate tests enforce countdown pacing, own timer visibility, inactive and
disabled HUD handling, PvP timer ownership, legal epoch stability, activation
scope, hidden-card redaction and projection tamper rejection. Release requires
the full regression/fairness/budget suite, sole-actor source review, fresh seven
native certification phases and exact backed-up installed-byte verification.
The next human playtest must assess scoring decisions and completed rounds
under a live timer. Remaining unsupported interactions need dedicated native
fixtures before claiming broader strength.

## Copying and deck refinement

`tests/test_copying_strategy.py` pins every supported Joker's copy compatibility
against installed native centers, then compares 219 bounded copy-chain cases
with actual native `Card:calculate_joker` and `SMODS.blueprint_effect` calls.
Independent shop-gain checks cover 250 copy purchases and placements.
Another 216 synthetic hands pass through the real restricted decision pipeline
on both Lua engines, with an independent scorer checking best offered plays.
Cycles, absent targets, debuffs, hidden identities and copier/target editions
have separate checks. The adapter offers real permutations for placing
Blueprint beside a target and moving Brainstorm's target to the first slot.
Unknown effects retain conservative placement handling; reserved certificate
capacity and the bounded reorder search can still limit available placements.

Copy effects and shop gains are cached only within one observation. Copy
routing consumes extra optional-search work; stress checks keep a 12-card hand
with seven copiers and a crowded copying-Joker shop within one million
instructions, below the unchanged two-million worker ceiling. Generated text
stays within the unchanged 57,344-byte guard. A Lua 5.1 bytecode-format test
compares every executable instruction, constant, register count and nested
prototype of compact versus readable policies, excluding only debug metadata.

`tests/test_deck_draw_priors.py` checks native initial-deck definitions and
independent flush probabilities. Checkered uses 26 Hearts/26 Spades, Abandoned
uses 40 cards without Jacks/Queens/Kings, and Erratic skips numerical draw
probabilities. Synthetic shop panels use the same initial constraints and
include held King/Queen examples for held-card effects. These are bounded
representative comparisons, not an exact model of the current unseen deck or
a complete build planner. Native certification checks delivery/isolation;
human testing of opponent strength remains outstanding.

## Follow-up after the October 5 playtest

The user reported that Expert was definitely stronger, but left the match
early. This confirms perceived improvement without establishing a completed
match result or win rate. The next refinement anticipates The Arm lowering the
played hand's level before scoring. It affects play and draw estimates while
the boss is active; disabled bosses and shop decisions retain displayed levels.
Level one is unchanged. Only displayed chips/mult consistent with native
initial values and per-level increments receive the forecast. Altered or
unknown growth remains a conservative displayed-value estimate. No new
observation fields or access to hidden information are added.

`tests/test_arm_forecast.py` reads private native hand definitions and executes
the actual installed Blind, hand-level and Steamodded upgrade functions.
It covers twelve categories, levels zero/one/two/four/100000, disabled bosses,
preview versus committed effects, both scoring decks, and 189 legal decision
choices on each Lua engine. Independent scores use the native post-boss levels.
A crafted hand now chooses a 292-point flush instead of a pair whose displayed
375-point estimate actually becomes 240 points under The Arm. Generated policy
text stays within the unchanged source guard and decisions retain their budget.

## Card retrigger refinement

The scoring model now adds repetitions from vanilla Hanging Chad (first scoring
card twice), Ranked's `j_mp_hanging_chad` (first two scoring cards once each),
Sock and Buskin (faces), Hack (ranked 2–5 cards) and vanilla Mime (held effects).
Red seals and copied retriggers stack additively. Each repetition runs the
card's enhancement, edition and supported individual Joker effects in order.
Mime repeats known Steel, Baron and Shoot the Moon scoring effects, including
copied effects; neutral held cards consume no extra scoring work. Debuffed
cards do not score and still occupy Chad's scoring-hand positions. Photograph
uses the first eligible face card rather than Chad's first-card rule.

The installed Ranked layer replaces vanilla Chad with a separate native
center. Tests load that actual center and execute native Joker calculations,
Steamodded repetition collection and card-scoring iteration, and the native
final scoring-hand assembly that restores played-card order. UI, enhancement
evaluation and effect application are test doubles, so this is focused rule
verification rather than a full native replay. Independent Python totals check
1,248 combinations per engine, including debuffs, Red seals, Stone cards,
Pareidolia, Glass multipliers and copy chains. Thirty independent shop-gain
checks and 360 best-offered choices per engine verify that the model reaches
the restricted policy pipeline. Glass fixtures explicitly project the actual
multiplier instead of testing the conservative unreadable-card fallback.

Resolved repetition counts are cached within one observation. Work accounting
includes repeated card evaluations; projected expensive play searches retain
the existing category fallback. Shops with more than 16 owned Jokers retain
the flat purchase heuristic, bounding extreme Negative/copy rows. Stress
checks cover 8/12-card hands, 5/8/16/64-Joker rows and crowded shops. Source
compaction also shortens private local symbols; executable bytecode equivalence
and the unchanged 57,344-byte source guard remain required. No new observation
fields, engine/global access, hidden deck information or future RNG are added.
Conditional retriggers, playing-card order search and full-run build planning
still need separate work; a best offered action is bounded by the legal catalog.
