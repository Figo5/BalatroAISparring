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
- **Imagined draw suits inflate some suit-Joker estimates.** Synthetic draws
  take fixed suits (for example a Spades rank filler), which can add a
  Wrathful Joker bonus that a random draw would not.
- **New-Joker valuation assumes end-of-row placement.** `joker_gain` appends
  the offered Joker, so ×mult Jokers bought before +mult ones are valued as if
  already well ordered (the reorder step fixes the order later).
- **Seed Money / Money Tree interest cap is not modelled.** `interest_cap` is
  fixed at 5. The policy cannot see owned vouchers yet: the adapter and reader
  never fill `self.vouchers`, although the schema allows it. Fixing this needs
  a trusted-integration change that exports `G.GAME.used_vouchers`, which Run
  Info shows publicly, through adapter → reader → observation, with a fairness
  review.
- **Match-history list may show Windows junctions.** `tools/match_history.py`
  review rejects junction paths, but the list view may still display them. Make
  both paths use the same filter.

## Measurement notes

- Two `tests/test_launcher_safety.py` cases are Windows-only. The seven
  failing `tests/test_prepare_server.py` cases need Python 3.12+
  (`Path.is_junction`). Both fail identically before and after Batch 2 fixes in
  the Linux cloud container (Python 3.11).
