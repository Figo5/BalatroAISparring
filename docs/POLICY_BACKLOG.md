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

- **Blank voucher can consume the last $10.** `v_blank` has +10 value; at low
  money the economy term alone may not stop it. Consider refusing vouchers of
  value ≤ 10 when they would drop below the reserve.
- **Rookie keeps simpler voucher and pack behaviour.** This is intentional.
  It is documented in LV-10 and §4.4. Revisit only if Rookie should buy
  Hieroglyph less often.
- **Discard evaluator ignores held Steel / Baron / Shoot the Moon.** In
  `discard_ev` target plays are priced with `held = nil`. Keeping Steel cards
  or Kings (with Baron) and Queens (with Shoot the Moon) in hand is therefore
  undervalued.
- **Imagined draw suits inflate some suit-Joker estimates.** Synthetic draws
  take fixed suits (for example a Spades rank filler), which can add a
  Wrathful Joker bonus that a random draw would not.
- **New-Joker valuation assumes end-of-row placement.** `joker_gain` appends
  the offered Joker, so ×mult Jokers bought before +mult ones are valued as if
  already well ordered (the reorder step fixes the order later).
- **Seed Money / Money Tree interest cap is not modelled.** `interest_cap` is
  fixed at 5, so those vouchers' value to later interest is underestimated.
- **Match-history list may show Windows junctions.** `tools/match_history.py`
  review rejects junction paths, but the list view may still display them. Make
  both paths use the same filter.

## Measurement notes

- Two `tests/test_launcher_safety.py` cases are Windows-only. The seven
  failing `tests/test_prepare_server.py` cases need Python 3.12+
  (`Path.is_junction`). Both fail identically before and after Batch 2 fixes in
  the Linux cloud container (Python 3.11).
