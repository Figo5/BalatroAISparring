# Batch 2 review: resolution

How the cloud worker resolved the findings in `docs/CLAUDE_BATCH2_REVIEW.md`
(local Claude Opus 5.5 High review of `0981f53..97358b8`). The review file is
kept verbatim; this file records the fixes and measurements.

## H1: discard search exceeds the policy budget (High, match-ending)

**Finding.** Larger hands exceed the 2,000,000-instruction sandbox budget when
the AI still has discards and either the round is PvP or no current play clears.
Measured with real adapter-shaped candidates:

| Hand / Jokers | Result |
|---|---|
| 8 cards / 5 Jokers | safe |
| 10 cards | Expert starts failing |
| 11 cards | Major League and Competitive start failing; Expert fails most cases |
| 12 cards | Major League and Competitive fail often; Expert almost always |

More Jokers make it worse. Three repeated failures make the decision loop
abandon the AI's match. Paint Brush and Palette, which the new policy values,
create these states.

**Resolution.** A deterministic work meter, a cheap heuristic first pass, and
metered draw-aware evaluation (`docs/BASELINE_POLICY.md` §4.5). The global
limit was not raised. Worst measured cases are now 1.33M instructions (66%) for
12 cards and 16 Jokers with enhanced, sealed cards on both runtimes, and
0 failures. Absurd sizes up to 48 cards / 64 Jokers stay under 0.25M through
the category fallback.

`tests/policy/test_budget.lua` covers:

- hand sizes 9–12 and 5 or 8 Jokers;
- PvP, and non-PvP where no play clears;
- all four difficulties, on Lua 5.1 and LuaJIT, through the real adapter;
- a 1.6M-instruction guard per decision;
- cross-runtime identical choices and repeat determinism.

With the meter disabled, 18 of its cases fail.

## M2: policy source near the hard size limit (Medium)

**Finding.** The rendered policy was about 64.3 KB against the sandbox's hard
65,536-byte cap.

**Resolution.** Comments, indentation and blank lines are stripped at render
time. The repository template stays readable. The rendered source went from
64,303–64,310 bytes to 50,859–50,866 bytes, including this batch's new code:
14.7 KB (22%) of headroom. A 56 KiB practical guard (`SOURCE_GUARD`) is
enforced by `tests/policy/test_source.lua`, together with stripped-vs-readable
decision equivalence. Rendering is deterministic, and behaviour is the same on
Lua 5.1 and LuaJIT.

## M1: Joker-before-pack/voucher not guaranteed (Medium)

**Finding.** `97358b8` capped pack and voucher scores at the flat Joker value
(`item_joker - 20`). The economy penalty, though, was applied after each item's
own price, so a cheaper pack could still win. Reproduction: $12, an unmodelled
$6–7 Joker and a $4 Celestial or Buffoon pack. Competitive, Major League and
Expert chose the pack; before `97358b8` they chose the Joker. LV-10 expects the
Joker.

**Resolution.** Vouchers and packs are compared against the **best certified
Joker purchase's full utility** (edition, estimated gain, economy after its own
price) (`docs/BASELINE_POLICY.md` §4.4, `versus_joker`):

- their intrinsic value is capped at that Joker's intrinsic value − 20;
- economy after each item's own price is then compared honestly;
- when both fit the money, the Joker is bought first.

A Joker that would drain the money can still lose, so this is not an absolute
rule. `tests/policy/test_shop_joker_first.lua` covers:

- the reproduction;
- different Joker, pack and voucher prices;
- interest breakpoints;
- a strong Joker against a weak pack, and a weak draining Joker against a
  strong pack or voucher;
- full slots, available slots, and a Negative Joker with full slots.

The reproduction and two other cases fail on the pre-fix policy.

## M3: benchmark interpretation and coverage (Medium)

**Finding.** The benchmark's reference scorer shares most of the policy's
model, so its 100% figures must not be read as optimal play.

**Resolution.** `docs/benchmarks/README.md` and the harness docstring now
describe the scorer as sharing the policy's model. The headline rows are
relabelled as agreement with that model, and the report carries an
`interpretation` field. `--hard` adds stress families with per-decision
instruction counts:

- 9–12 card hands;
- scaling Jokers;
- rule-changing Jokers;
- boss blinds.

Close-EV and survival-vs-economy scenarios are listed there as prepared work.

## Local validation queue

LV-7 through LV-10 were corrected:

- **LV-7:** `decisions.jsonl` now logs a `ui` field with `hand_size`,
  `blind_requirement`, `current_score` and `hand_levels` for comparison with
  the Balatro UI. The item also requires 10+ card PvP and no-clear states with
  zero budget errors.
- **LV-8:** keeps the four-option menu layout, companion/host difficulty
  matching and live decision speed.
- **LV-9:** adds positive consumable cases (Wraith below $10, Ankh or Hex with
  exactly one Joker). Negative cases are kept.
- **LV-10:** scoped to Competitive and above. Adds Negative Joker and full-slot
  validation. Moves valuation and crowd-out checks to repository tests.

## Lower-priority observations

These are recorded in `docs/POLICY_BACKLOG.md` for continuous development and
were not addressed here.
