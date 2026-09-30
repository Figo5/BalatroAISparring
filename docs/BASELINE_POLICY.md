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

BaselinePolicy.difficulties()        -- { "rookie", "competitive", "major_league" }
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
- **Base** is the level-1 chips/mult of the hand, plus the chips of the scoring
  cards (2–10 face value, J/Q/K 10, A 11).
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

Unknowns count as neutral: hand levels, scaling Jokers' current values, boss
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

## 5. Difficulties

All three difficulties share the same safety guarantees and the same observable
information; they differ only in heuristic aggressiveness/quality constants (no
information or authority differences).

| Constant | rookie | competitive | major_league |
|---|---|---|---|
| `reserve` (money kept) | 6 | 10 | 16 |
| play junk penalty / extra card | 250 | 400 | 550 |
| discard junk value / card | 5000 | 6000 | 7000 |
| discard pair-preservation penalty | 16000 | 20000 | 24000 |
| `reroll_base` / surplus cap | 70 / 160 | 55 / 120 | 45 / 100 |
| `leave_shop` | 80 | 90 | 100 |
| `reorder` / max improvement bonus | 105 / 10 | 105 / 10 | 105 / 10 |
| negative-edition bonus | 120 | 150 | 180 |
| recognized-edition buy bonus / `slot_sell` | 40 / 220 | 40 / 220 | 40 / 220 |
| `estimate_plays` (chips × mult play scoring) | on | on | on |
| `est_jokers` (visible Joker effects in the estimate) | off | on | on |
| `use_requirement` (clear-first, requirement-driven discards) | off | on | on |
| `discard_need_pct` | n/a | 90 | 100 |
| `discard_ev` (draw-aware discard ranking) | off | on | on |
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

- Source is text-only and within the 64 KiB cap; bytecode is rejected upstream.
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
- **Difficulty selection:** `rookie`, `competitive`, `major_league`; the string is
  the only difficulty knob, so the same source can be cached and reused.
- **Selection handling:** accept only the returned action and re-validate it; do
  not trust it. Treat `policy_no_action` as a legitimate "no legal choice".
- **Determinism:** identical observation + candidate list yields an identical
  action id on every run and on both Lua runtimes, which keeps gauntlet seeds
  reproducible.

Not implemented here and owned elsewhere: real-engine view/certificate producer,
executor, async orchestration, logging, launcher, staged runtime, UI.
