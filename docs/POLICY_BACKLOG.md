# Policy development backlog

## Priority order

1. Economy and long-term scaling.
2. Harder benchmarks (`docs/benchmarks/README.md`, "Not yet covered").
3. Gauntlet / full-run metrics.
4. Consumable reasoning.
5. Boss awareness.
6. Stronger Major League / Expert AI.
7. Match review.
8. Reliability and performance.

Constraints on all of it:

- keep the rendered policy under `SOURCE_GUARD` (§4.5 of
  `docs/BASELINE_POLICY.md`);
- meter any new search with `WORK`;
- add budget cases to `tests/policy/test_budget.lua`.

## Economy and long-term scaling (in progress)

- **Done:** offered scaling Jokers use mid-life proxies (`SCALING`, §4.2).
- **Done:** proxies depend on the ante (×1.25 early, ×0.75 from ante 5).
- **Fixed:** the Spare Trousers proxy used the wrong key (`j_spare_trousers`;
  vanilla's is `j_trousers`), so it never applied.
- **Fixed:** the slot-pressure sale could sell a grown scaling Joker (for
  example a ×2.5 Hologram) to buy a fresh editioned copy, resetting it.
  `GROWS` Jokers are never sold that way.
- **Done:** owned scaling Jokers use their shown current value, with vanilla's
  before-scoring growth (docs/SCALING_VALUES_DESIGN.md, architecture-reviewed).
  `GROWS` sales are allowed again when the shown value is still the base.
  Re-certification is required.

## Harder benchmarks and Gauntlet metrics (in progress)

- **Done:** blind simulator (`tests/benchmark_blinds.py`) with debuff, Needle
  and Water bosses. Strong tiers clear about 81% of antes 1–4 blinds, Rookie
  58%. Major League ≈ Competitive on blinds.
- **Done:** run simulator (`tests/benchmark_runs.py`) chains blinds with hand
  levels, money, interest, Joker/planet purchases, rerolls and reorders. Its
  shared scoring model and limited shops remain regression evidence, not an
  actual win rate. Do not redo the already implemented simple-shop simulator.
- **Next:**
  - extend independent reference coverage for rule-changing Jokers and more
    boss effects; add close-EV/acceptable-action diagnostics;
  - represent scaling, vouchers, packs and survival/economy conflicts beyond
    the existing simple-shop model;
  - Expert discard thresholds are **not** the lever. On 720 paired blinds
    (seed 7, `benchmark_blinds.py --policy ... --paired ...`):
    - `discard_need_pct` 100 or 125: +0.1% (t 0.6) and −1.0% (t −2.3);
    - `discard_gain_pct` 115 or 150: −0.7% (t −1.9) and +0.4% (t 1.3);
    - at most 9 of 720 blinds changed, so all four were left unchanged;
  - Structural play changes tested and **rejected** (720 paired blinds, seed 7,
    Competitive / Expert):
    - keep the last discard while 3+ hands remain: +0.7% (t 0.9) / −0.1%;
    - with no discards and the blind out of reach, dig by playing more cards:
      +0.6% (t 1.1) / +0.1%.

    Diagnosis: all 70 of Expert's failed blinds ended with no discards left;
    most had spent them first. Neither change moved the clear rate, so the
    remaining losses look like draw luck within this model. Play-side
    headroom in the blind simulator appears small.
  - Expert's `joker_gain_value` 500 vs 400: −0.01 blinds per run (t −1.0,
    150 paired runs on held-out seed 37). Not a lever.
  - **Plateau:** play thresholds, structural play changes and Joker weight
    all move the simulators by less than noise, so the strong tiers look near
    the ceiling of these models. Real separation evidence should now come from
    local Gauntlet runs (LV-7/LV-8), not more simulator tuning.
  - give Major League and Expert a real edge: after the economy retune
    (held-out ≈ +0.33 / +0.51 blinds per run) they match Competitive in run metrics, so
    their play-side difference is still unproven.

## Boss awareness (in progress)

- **Done:**
  - The Psychic: a play of fewer than five cards is estimated at 0 (paired
    A/B +0.7% overall);
  - The Eye and The Mouth (paired A/B +0.7% / +0.4% overall).
- **Current local source size:** maximum rendered 56,681 UTF-8 bytes, 663 below
  the unchanged `SOURCE_GUARD` (57,344) and 8,855 below the hard cap (65,536).
  The earlier 54,740 / 51.4 KB figures predate the Negative-slot and shop fixes.
  See `LOCAL_H1_VERIFICATION.md` and `LOCAL_REGRESSION_VERIFICATION.md`.
- **Batch 3 M1:** Psychic minimum applies before every fallback, including all
  five rule-changing Jokers, face-down/Stone/unknown padding and no-five-candidate
  cases. Both runtimes pass; repository acceptance passed under prior Claude. The
  current installed build is `d1a9a80` (`BalatroAISparring-phase-h`); the
  authoritative-installed-config candidate is uninstalled and awaits a fresh
  package and consolidated certification. Accepted policy is unchanged and the
  live Tarot checks remain pending. Native/live gates remain.
- **Open (review Lows):**
  - ~~the adapter offers few five-card plays under The Psychic~~: fixed with
    padded rank groups and two pair (Psychic clears 68% → 74–84% on 19
    blinds);
  - ~~discard EV still counts plays of fewer than five cards under The
    Psychic~~: fixed (`MIN_CARDS`); neutral in A/B;
  - ~~a boss disabled by Chicot or Luchador keeps its key~~: fixed with an
    engine-cross-checked `match.blind_disabled` (docs/BLIND_DISABLED_DESIGN.md,
    architecture-reviewed);
  - ~~The Eye and The Mouth need hand-type history this round~~: done
    (docs/HAND_HISTORY_DESIGN.md, architecture-reviewed). The Flint scales
    scoring uniformly and is not modelled;
  - ~~with fewer than five visible-rank cards (for example Stone cards), no
    padded candidate is offered~~: fixed, padding falls back to other cards by
    position (a test checks that a face-down card's hidden rank does not
    change the offer).

## Consumable reasoning (v1 implemented, repository acceptance passed; live checks pending)

- **Done:**
  - the ten allowlisted Tarots (Strength, Death, Lovers, Chariot, Justice,
    Devil, Star, Moon, Sun, World) are used on hand cards through
    `USE_CONSUMABLE_ON_HAND`, bought at a modest utility and held when there is
    no clear gain (docs/HAND_TARGETS_DESIGN.md);
  - a full consumable slot set no longer churns a usable Tarot: only a
    concretely better, affordable visible offer frees the weakest one
    (docs/CLAUDE_BATCH3_REVIEW.md M2);
  - the remaining targeted cards (Magician, Empress, Hierophant, Tower, Hanged
    Man, Spectral seals, Aura, Cryptid) are never bought and a held one is
    sold: no target port is wired live, and a test guards that;
  - Arcana and Spectral packs are discounted;
  - The Hermit is held until $20.
- **Next:**
  - Temperance timing needs owned Joker sell values, which are not in the
    observation yet;
  - consider raising the v1 Tarot scope (more centers, 1–2 target
    enhancements) after live validation;
  - wiring the target-selection port would additionally unlock the
    `CONSUMABLE_SELECTION` path, but it is a trusted-integration change that
    needs its own design review.

## Open observations from the Batch 2 review (lower priority)

From `docs/CLAUDE_BATCH2_REVIEW.md` (resolution notes in
`docs/CLAUDE_BATCH2_RESOLUTION.md`). None is match-ending.

- ~~**Blank voucher can consume the last $10.**~~ Fixed: minor vouchers never
  dip below the reserve (§4.4).
- **Rookie keeps simpler voucher and pack behaviour.** This is intentional.
  It is documented in LV-10 and §4.4. Revisit only if Rookie should buy
  Hieroglyph less often.
- ~~**Discard evaluator ignores held Steel / Baron / Shoot the Moon.**~~ Fixed:
  draw targets are priced with the effect-bearing kept cards they leave in hand
  (`tests/policy/test_held_effects.lua`). 20% of decisions changed on
  Steel-heavy seeded hands. Forced-discard quality moved from 0.852/0.863/0.850
  to 0.854/0.868/0.854 (shared-model check only). LV-7 should watch
  Steel/Baron runs.
- ~~**Imagined draw suits inflate some suit-Joker estimates.**~~ Changed:
  imagined rank and full-house draws take a suit no owned suit Joker rewards,
  and straight fillers prefer one too. This swaps a small upward bias for a
  small conservative one: a real draw hits a bonus suit about ¼ of the time.
  Pricing the expected suit bonus exactly is left open. Forced-discard quality
  moved within noise (0.854→0.852, 0.868→0.868, 0.854→0.852).
- ~~**New-Joker valuation assumes end-of-row placement.**~~ Fixed: an additive
  Joker-level effect is priced before the trailing run of owned x-mult or
  Polychrome Jokers, only when the post-purchase row qualifies for the
  estimate-based reorder (`tests/policy/test_joker_slot.lua`).
- ~~**Seed Money / Money Tree interest cap is not modelled.**~~ Done: owned
  vouchers are exported (docs/OWNED_VOUCHERS_DESIGN.md, architecture-reviewed)
  and the policy's interest cap follows them.
- ~~**Match-history list may show Windows junctions.**~~ Fixed: listing and
  `review` share `is_session_dir`, which requires a real directory (not a
  symlink or junction) that resolves directly under the root.

- **Joker slot pricing, residual (Low).** In 6 of 855 sampled rows (0.7%) a
  new additive Joker is still priced 0.3–13% above what the greedy reorder
  reaches. This happens when two hand-conditional x-mult Jokers never overlap
  (for example Cavendish then Trio with Mad). The fix is to simulate the
  greedy adjacent-swap reorder inside `joker_gain`.

## Measurement notes

- Two `tests/test_launcher_safety.py` cases are Windows-only. The seven
  failing `tests/test_prepare_server.py` cases need Python 3.12+
  (`Path.is_junction`). Both fail identically before and after Batch 2 fixes in
  the Linux cloud container (Python 3.11).
