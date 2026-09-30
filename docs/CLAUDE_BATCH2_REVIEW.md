# Claude Batch 2 review (`0981f53..97358b8`)

- **Reviewer:** Claude Code (claude-opus-5-5), independent local reviewer on the user's Windows machine
- **Scope:** the eight Batch 2 commits on `feature/ai-sparring-v1`, `0981f53` through `97358b8`, read as code, not from the progress report:
  `0981f53` estimate plays and draw-aware discards, `51fe020` hand levels / shop Joker values / Joker ordering,
  `352587e` Expert difficulty, `f046412` benchmark stage families, `d00201f` match history tool,
  `5007bf2` consumable safety floor, `d6c8cfa` consumable floor for real pack cards, `97358b8` voucher values and pack choices.
- **Comparison baseline:** `ca6ee9a` (pre-Batch-2).
- **Safety:** the review ran in a separate, since-removed checkout. The live Balatro install, Mods folder, saves and certified build were not touched. Nothing was reinstalled or re-certified.

## Verdict

The fairness boundary holds, and every test that can run on this machine passes. But H1 can end the AI's match, so Batch 2 is **not safe to build further on until H1 is fixed**.

| ID | Severity | Summary |
|---|---|---|
| H1 | High | Discard evaluation on 9–12 card hands exceeds the 2M-instruction budget; repeated failure ends the AI's match |
| M1 | Medium | "Joker before pack/voucher" guarantee is false; regression from `97358b8` |
| M2 | Medium | Rendered policy source is 98% of the 65,536-byte cap |
| M3 | Medium | Benchmark 100% figures show model agreement, not play quality |

## High

### H1 – On larger hands the AI runs out of instruction budget and ends its own match

**Trigger.** `AISparring/ai/baseline_policy.lua` (at `97358b8`, around line 1425) runs the draw-aware discard evaluation when
`CONF.discard_ev and can_discard and not info.clears and #s.hand <= 12`, for up to `DISCARD_EV_LIMIT = 40` discard candidates.
So it runs only when the AI still has discards and either the round is PvP (no `blind_requirement`, so nothing "clears") or no current play clears the blind. With more than 8 cards in hand, the cost of evaluating 40 candidates exceeds the sandbox's 2,000,000-instruction budget (`tools/lua/policy_env.lua`).

**Consequence.** The policy fails with a budget error. The same state fails the same way every time (the policy is deterministic). The decision loop's `register_error` (`AISparring/integration/decision_loop.lua`, around line 593) counts consecutive errors and calls `finish("error", code)` once `max_errors` (3) is reached, so the AI abandons the match.

**Measurement method.** A stress harness loaded the real `policy_env.lua` with the budget raised to 2e9 so the true instruction cost could be read, built frames through the engine test fixtures and the real `engine_adapter.lua` (so candidates and certificates have real adapter shapes, 93–100 certificates per frame), and dealt 30 random hands per configuration in a non-clearing state with discards remaining. "Over" means the decision would have exceeded the real 2M budget.

Major League uses the same discard-evaluation path as Competitive (`discard_ev = true`, no `deep_draws`; it only changes thresholds), so the Competitive column covers Major League. Expert adds `deep_draws`.

**Raw results, Lua 5.1 (`lupa.lua51`):**

| Hand | Jokers | Certs | Competitive peak | Competitive over 2M | Expert peak | Expert over 2M |
|---|---|---|---|---|---|---|
| 8 | 5 | 93 | 1,123k | 0/30 | 1,523k | 0/30 |
| 9 | 5 | 94 | 1,356k | 0/30 | 1,749k | 0/30 |
| 10 | 5 | 95 | 1,768k | 0/30 | 2,362k | 9/30 |
| 10 | 8 | 98 | 2,147k | 3/30 | 2,580k | 25/30 |
| 11 | 5 | 96 | 2,060k | 1/30 | 2,657k | 26/30 |
| 12 | 5 | 97 | 2,283k | 13/30 | 3,177k | 29/30 |
| 12 | 8 | 100 | 2,725k | 29/30 | 3,627k | 30/30 |

**Raw results, LuaJIT 2.1 (`lupa.luajit21`):**

| Hand | Jokers | Certs | Competitive peak | Competitive over 2M | Expert peak | Expert over 2M |
|---|---|---|---|---|---|---|
| 8 | 5 | 93 | 1,146k | 0/30 | 1,555k | 0/30 |
| 9 | 5 | 94 | 1,378k | 0/30 | 1,783k | 0/30 |
| 10 | 5 | 95 | 1,796k | 0/30 | 2,407k | 11/30 |
| 10 | 8 | 98 | 2,179k | 3/30 | 2,627k | 26/30 |
| 11 | 5 | 96 | 2,093k | 3/30 | 2,701k | 28/30 |
| 12 | 5 | 97 | 2,321k | 16/30 | 3,226k | 30/30 |
| 12 | 8 | 100 | 2,764k | 29/30 | 3,674k | 30/30 |

Summary: 8-card hands peak at about 1.15M (Competitive/Major League) and 1.56M (Expert) with no failures. At 10 cards Expert fails 30–37%; at 11 cards Competitive fails 3–10% and Expert 87–93%; at 12 cards Competitive fails 43–53% and Expert ~100%; with 8 Jokers the failure rates are far higher. Both runtimes agree.

**Why the tests missed it.** The heavy policy test uses 8 cards; the "large hand" test uses 20 cards, which skips this path entirely (`#s.hand <= 12`); the benchmark only ever deals 8 cards. Sizes 9–12 were never covered.

**Why it matters more now.** `97358b8` values Paint Brush and Palette (+1 hand size each) highly, so the AI now steers itself into larger hands.

**Fix direction.** Scale the discard-evaluation candidate limit (currently 40) by hand size and Joker count, or lower the 12-card cutoff, so the worst case stays well under 2M on Lua 5.1. Add strict Lua 5.1 tests for 9–12 card hands under Competitive, Major League and Expert, in PvP and non-clearing states, with 5 and 8 Jokers, asserting no budget error.

## Medium

### M1 – The "Joker before pack/voucher" guarantee is false (regression from `97358b8`)

`97358b8` caps pack and voucher scores 20 points below a Joker buy. But below the money reserve every dollar spent costs 10 points, so a cheaper pack easily outscores a more expensive Joker even under the cap.

**Reproduction** (policy test support frames, real `shop_booster:` / `shop_voucher:` refs, Lua 5.1; LuaJIT identical):

| Case | Rookie | Competitive | Major League | Expert |
|---|---|---|---|---|
| $12: `j_ride_the_bus` $6 vs `p_celestial` $4 | BUY_ITEM (Joker) | **OPEN_BOOSTER** | **OPEN_BOOSTER** | **OPEN_BOOSTER** |
| $12: `j_ride_the_bus` $7 vs `p_buffoon` $4 | BUY_ITEM (Joker) | **OPEN_BOOSTER** | **OPEN_BOOSTER** | **OPEN_BOOSTER** |
| $20: `j_blueprint` $10 vs `v_grabber` $10 | BUY_ITEM | BUY_ITEM | BUY_ITEM | BUY_ITEM |

Before `97358b8` all tiers bought the Joker in the first two cases. With equal prices (third case) the guarantee happens to hold, which is why the existing test passes. `docs/LOCAL_VALIDATION_QUEUE.md` LV-10 tells the playtester to expect the opposite of the actual behaviour.

**Fix direction.** Cap pack/voucher scores against the actual best affordable Joker score (after the money penalty), or correct the LV-10 text if the behaviour is intended. Add a test with a cheaper pack next to a pricier Joker.

### M2 – The rendered policy source is at 98% of its size limit

Rendered source bytes at `97358b8`: rookie 64,303; competitive 64,307; major_league 64,310; expert 64,303. The cap is `MAX_SOURCE_BYTES = 65536` in both the policy module and the sandbox (`tools/lua/policy_env.lua`), leaving about 1.2 KB.

Nothing is broken today and exceeding the cap fails safe (the AI refuses to start, and the tests catch it), but the H1 fix or the next feature is likely to push it over. Stripping comments from the template at render time would recover substantial room.

### M3 – The 100% benchmark figures show the two models agree, not that the AI plays well

- The Python reference scorer uses the same Joker table as the policy, and scenarios only draw Jokers the policy already models.
- Scenarios never include rule-changing or scaling Jokers, boss blinds, or hand sizes other than 8.
- `docs/benchmarks/README.md` states these limits honestly, but the commit messages ("best play 75%→100%") read stronger than that.
- This blind spot is exactly why H1 slipped through.

**Fix direction.** Reword benchmark claims as "agreement with the reference scorer on modelled scenarios". Extend the benchmark with unmodelled and rule-changing Jokers, boss blinds and 9–12 card hands.

## Lower-priority observations

- **Blank voucher:** all tiers, including Competitive and above, spend their last $10 on `v_blank` (score 110 against a 100 leave-shop threshold). Hieroglyph at $10 is correctly left by Competitive and above.
- **Rookie:** still buys Hieroglyph/Petroglyph and opens a Buffoon pack with full Joker slots (Competitive and above leave the shop). This is intentional flat Rookie scoring, but LV-10's wording should say "Competitive and above".
- **Discard evaluation skips held-card effects:** drawn-card outcomes ignore Steel, Baron and Shoot the Moon, while the current best play includes them, so the AI is biased against discarding while holding those. Documented.
- **Suit Jokers slightly over-counted:** imagined drawn cards use fixed suits, which inflates Wrathful/Gluttonous-style bonuses a little.
- **Joker valuation:** a candidate Joker is priced at the end of the row, which undervalues +Mult Jokers when ×Mult Jokers are already owned.
- **Interest cap:** fixed at 5, so Seed Money and Money Tree are ignored.
- **`tools/match_history.py`:** skips symlinked sessions but lists Windows junctions. `review` correctly rejects them, and the tool is read-only anyway.

## Checked and correct

- **Fairness boundary:**
  - `hand_levels` includes only hands Run Info shows.
  - `blind_requirement` is only sent for non-PvP blinds.
  - The reader copies both fields through a strict allowlist; the policy never sees the deck, hidden card order or the seed.
  - Face-down cards are never offered as discard candidates.
  - Expert receives exactly the same observation as the other tiers, and a test fails on any undeclared global access.
- **Score estimation:** base chips/mult per hand, scoring-card selection, enhancement/edition/red-seal order, Joker edition order and every modelled Joker effect match public Balatro rules.
- **Expert search:** the two-missing-rank straight probability is correct, and the search size is bounded (though see H1 for the combined cost).
- **Joker ordering:** a reorder is taken only if it strictly improves the estimate, and the adapter offers at most 16 swaps (under the 20-evaluation allowance), so it cannot cycle.
- **Real pack cards:** classifying them by center key is correct. Buffoon packs are not opened with full slots by Competitive and above, and the adapter's own slot check backs this up.
- **Determinism and portability:** Lua 5.1 and LuaJIT choose identically; no Lua 5.2+ syntax (`goto`, labels, `//`, bit operators, `utf8`, `table.unpack/pack/move`, `math.type/tointeger`) in the Batch 2 Lua.
- **Match history:** read-only, bounded (`MAX_FILE_BYTES` = 64 MiB, symlinked files skipped), and `review` only accepts a direct child of the sessions folder.

## Tests run (Windows, `work/runtime-venv` Python 3.12, lupa 2.8)

**Batch 2 tip `97358b8`: all 52 test scripts pass.** This includes:

- every `run_*` harness under both runtimes (`run.py`, `run_boundary`, `run_companion`, `run_decision`, `run_engine`, `run_m2`, `run_menu`, `run_policy`, `run_reader`, `run_runtime`: `RESULT: PASS`);
- all `astra_*` scripts, including the two that need the local game reference and are skipped in the cloud;
- host 119/119, service 60/60, installer 48/48, certificate 65/65, launcher 64/64;
- `test_match_history.py`, `test_policy_estimator_parity.py`, `test_measurement_lifecycle.py`, `test_p2_observer.py`, `test_staging.py`, `test_runtime_cross_service.py` and the rest.

**Benchmark:** `tests/benchmark_policy.py --scenarios 300 --check docs/benchmarks/policy_baseline.json` → `RESULT: PASS`. Lua 5.1 run: 0 failures, 0 illegal actions, mean latency 32.0 / 33.8 / 32.3 ms (p95 43 / 51 / 46 ms) across the non-Rookie tiers, on 8-card hands only.

**Pre-Batch-2 baseline `ca6ee9a`:** same results.

**No regressions.** Two failures occurred during the run; neither is a code problem:

- `astra_host_server_native` refused a folder junction created in the review checkout. It passes with a real copy.
- Baseline `test_practice_service` hit a Windows temp-folder cleanup error under parallel load. It passes when re-run.

**Slower suite:** `run_policy` takes 10.9 s instead of 3.7 s because of the heavier tests.

## LV-7 through LV-10 corrections

The entries are broadly accurate, but they mix work that can be tested in the cloud with work that genuinely needs the real game.

**Genuinely needs the real game:**

- hand levels matching Run Info, including secret hands and The Arm;
- `blind_requirement` matching the on-screen number for boss blinds, and Multiplayer's -1 value after a blind ends;
- the real pack and voucher key names;
- pack cards the game marks as usable;
- selling a consumable actually working;
- Joker slots when a Negative Joker is owned;
- the four-option menu layout, host/companion difficulty lists matching, and real decision speed.

**Per entry:**

- **LV-7 gap:** live logs record only a hash of the observation, so hand levels and blind requirement cannot be compared with the screen. Log those fields (they are already in the allowlisted observation) for this check.
- **LV-7 / LV-8:** after H1 is fixed, add a 10+ card hand in a PvP round and in a round the AI cannot clear, with no budget errors allowed.
- **LV-9:** add the positive cases: Wraith used when the AI has under $10, and Ankh/Hex used when it has exactly one Joker.
- **LV-10:** correct the Joker-before-pack claim (M1), add the Negative-Joker full-slot case, and say "Competitive and above". Voucher values and crowd-out ordering are pure policy logic and belong in cloud tests, not the live queue.

## Recommendation

**Cloud worker, fix before continuing:**

1. H1, plus strict Lua 5.1 tests for 9–12 card hands (Competitive, Major League, Expert; PvP and non-clearing; 5 and 8 Jokers).
2. Source-size headroom (M2).
3. M1, plus a test with different prices.
4. Benchmark wording (M3) and the LV-7 to LV-10 corrections above.

**Can wait for the next local certification and playtest:** the lower-priority items, a more realistic benchmark (unmodelled and rule-changing Jokers, bosses, 9–12 card hands), and the real-game checks listed above.

## Re-review plan for the fix commits

When the cloud worker pushes fixes, the local re-review will:

1. Pull `feature/ai-sparring-v1` and read the fix commits against H1, M1, M2 and M3.
2. Re-run the large-hand budget harness on Lua 5.1 and LuaJIT for 9–12 card hands, Competitive / Major League / Expert, PvP and non-clearing states, 5 and 8 Jokers.
3. Measure rendered policy source bytes against the 65,536-byte cap.
4. Reproduce the price-mismatch Joker-vs-pack/voucher cases above.
5. Check benchmark wording and the updated LV-7 to LV-10 queue.
6. Report any remaining Critical/High/Medium issues, flagging any new High/Critical immediately.

No re-certification, reinstall or live playtest happens until the user calls for the consolidated local pass.
