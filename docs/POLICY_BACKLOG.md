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
- **Next:** use the
  displayed current value of owned scaling Jokers if the adapter can export
  it as UI-visible card text (needs a boundary review).

## Harder benchmarks and Gauntlet metrics (in progress)

- **Done:** blind simulator (`tests/benchmark_blinds.py`) with debuff, Needle
  and Water bosses. Strong tiers clear about 81% of antes 1–4 blinds, Rookie
  58%. Major League ≈ Competitive on blinds.
- **Next:**
  - add hand levels and more boss effects to the simulator;
  - chain blinds with a simple shop (money, interest, Joker buys) into a
    run-level metric;
  - Expert discard thresholds are **not** the lever. On 720 paired blinds
    (seed 7, `benchmark_blinds.py --policy ... --paired ...`):
    - `discard_need_pct` 100 or 125: +0.1% (t 0.6) and −1.0% (t −2.3);
    - `discard_gain_pct` 115 or 150: −0.7% (t −1.9) and +0.4% (t 1.3);
    - at most 9 of 720 blinds changed, so all four were left unchanged;
  - give Major League and Expert a real edge: after the economy retune
    (held-out ≈ +0.33 / +0.51 blinds per run) they match Competitive in run metrics, so
    their play-side difference is still unproven.

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
