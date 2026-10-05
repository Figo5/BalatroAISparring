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
| Decks and stakes | Actual own hand size, hands/discards, money, displayed levels and legal offers are projected from the selected game. Plasma's distinct scoring is explicit. Draw probabilities still use a standard-deck prior, so Checkered, Abandoned and modified decks can be misvalued. |
| Hand rules | All twelve native categories and the five hand-changing Jokers are modelled. Adapter candidates remain bounded; a best offered play is not necessarily the best possible subset or order. |
| Jokers | Static scoring effects and allowlisted shown scaling values are supported. Other Jokers are neutral in score estimates and receive coarse shopping heuristics. Blueprint/Brainstorm copying, Joker retriggers, and many conditional effects remain gaps. |
| Bosses | Psychic, Eye, Mouth and Flint have explicit policy handling; visible card/Joker debuffs and forced selections are respected. Arm's upcoming level loss and other predictive boss effects are not all modelled. Engine legality does not by itself establish a good strategic choice. |
| Random effects | Lucky and Misprint use expectations, without sampling future RNG. Nonlinear Plasma scoring makes an expected-component estimate approximate. |
| Economy/build planning | Bounded gains, reserves, interest, voucher/pack values and harmful-consumable refusals. No full-run search, exact future shop prediction, or complete build synergy model. |
| Fairness | Only the AI's own visible active countdown and public own deck rule are added. No enemy cards/hidden score, hidden draw order, future RNG, timer increase, removed animations or runtime external AI calls. |

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
