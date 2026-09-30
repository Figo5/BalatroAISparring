# Claude Batch 2 re-review (`a33ce99..b42d775`)

- **Reviewer:** Claude Code (claude-opus-5-5), independent local reviewer on the user's Windows machine. This is separate from the cloud worker's own "fresh-context re-review" recorded in `docs/CLAUDE_BATCH2_RESOLUTION.md`.
- **Reviews:** the fixes for `docs/CLAUDE_BATCH2_REVIEW.md` (H1, M1, M2, M3 and LV-7 to LV-10).
- **Safety:** the live Balatro install, Mods folder, saves, certified build and the user's local `main` were not touched. Nothing was re-certified or reinstalled. All work ran in separate checkouts.

## Exact range reviewed

| Commit | Summary | Review depth |
|---|---|---|
| `ca02b7b` | bound discard search, recover source headroom, compare packs to best Joker | full |
| `23f0439` | cache shop Joker buy scores, refresh budget/size figures | full |
| `c37537c` | keep the default benchmark random stream unchanged | full |
| `b42d775` | keep minor vouchers from spending the money reserve | full (small; landed before this review was finalized) |

**Out of range:** three commits landed while this review was being finalized. They are new backlog development, not fixes, and are not reviewed here beyond the budget spot-check in the "Spot-check of the current tip" section:

- `02063b2`: held Steel/Baron/Shoot the Moon in discard pricing;
- `4ed101e`: additive Joker valuation;
- `fc699f8`: match-history junction filtering.

## Verdict

**H1, M1, M2 and M3 are resolved. No new Critical or High issues.** The branch is safe for continued development.

One new Medium issue appeared during the batch: `ca02b7b` broke the benchmark `--check` regression gate. The cloud worker fixed it within the range (`c37537c`), so it is closed. Three Low items and some doc nits remain; one of the Lows is a pre-existing flaky test.

**Nothing here blocks the next local certification and playtest.**

| ID | Status at `b42d775` |
|---|---|
| H1 large-hand budget failure | **Resolved** |
| M1 pack/voucher crowd-out | **Resolved** (a residual tuning note, N3, is Low) |
| M2 source size headroom | **Resolved** |
| M3 benchmark claims | **Resolved** |
| N1 (new, Medium) benchmark gate broken by `ca02b7b` | **Resolved in range** by `c37537c` |
| N2 (new, Low) work meter is relative, not absolute | open |
| N3 (new, Low) single-affordable Joker vs cheaper pack | open, tuning |
| N4 (pre-existing, Low) `astra_host_server_native` flaky | open, test-only |

## H1: resolved

**Fix.** `ca02b7b` adds a deterministic per-decision work meter, a cheap heuristic ranking of discard candidates, and metered draw-aware evaluation (`AISparring/ai/baseline_policy.lua:1473`, `:1540`). The sandbox budget was **not** raised: `INSTRUCTION_BUDGET = 2000000` is unchanged in `tools/lua/policy_env.lua`. The only sandbox change is a read-only `last_instructions()` diagnostic.

**Method.** The same harness design as the Batch 2 review, extended:

- frames come from the engine fixtures and the real `engine_adapter.lua` (93–100 certificates, ≈40 plays + ≈40 discards);
- 30 seeded hands per cell;
- 8–12 cards, 5 and 8 Jokers;
- Competitive, Major League and Expert;
- **PvP** (`blind_pvp`, `bl_mp_nemesis`; the harness asserts `blind_requirement` is absent) and **non-clearing** (requirement 1e12; the harness asserts it is present), with 3 discards left.

Every decision ran in two sandboxes. One was instrumented, with the budget lifted, to read the true instruction count. The other was the **real, unmodified** `policy_env.lua`, to count actual budget failures, and it ran every decision twice to check repeat determinism.

**Results at `ca02b7b`** (identical at `23f0439`: byte-identical harness output and the same action digest):

| | Lua 5.1 | LuaJIT |
|---|---|---|
| Real-budget decisions | 3,600 | 3,600 |
| `policy_budget_exceeded` | **0** | **0** |
| Peak, Competitive (9–12 cards) | 1,234k | 1,253k |
| Peak, Major League (9–12 cards) | 1,230k | 1,249k |
| Peak, Expert (9–12 cards) | 1,301k | 1,315k |
| Peak, 12 cards / 8 Jokers, PvP vs non-clearing | 1,300k vs 1,301k | 1,314k vs 1,315k |
| Repeat determinism (same action twice) | pass | pass |

**Cross-runtime:** the action digest is identical (`bec61f14cb945b65` on both).

**Before the fix (`a33ce99`), for comparison:**

- Expert failed 30–37% at 10 cards, 87–93% at 11 cards and ~100% at 12 cards.
- Competitive and Major League failed 43–53% at 12 cards with 5 Jokers.
- The same harness at `a33ce99` confirmed PvP fails exactly like non-clearing states.

**Boundedness.** The fix bounds work by design; it does not simply raise a limit:

- **12 cards with up to 32 Jokers:** peak 1.72M, 0 failures, both runtimes.
- **Hands over 12 cards:** skip discard search entirely.
- **Crowded shops:** see N2 for the remaining gap at extreme Joker counts.

**Tests.** `tests/policy/test_budget.lua` runs real-adapter frames for:

- 9–12 cards, 5 and 8 Jokers, PvP and no-clear, all four difficulties;
- plain, enhanced and paired hands;
- repeat determinism;
- absurd sizes;
- crowded shops (`23f0439`).

It uses the real budget, a 1.6M guard and cross-runtime action vectors. It passes on both runtimes.

## M1: resolved

**Fix.** `versus_joker` (`baseline_policy.lua:1910`) compares packs and vouchers with the best certified Joker purchase's full buy score (edition, estimated gain, economy after its own price):

- their intrinsic value is capped at that Joker's intrinsic value − 20;
- economy after each item's own price is added;
- when both fit the money, the score is clamped below the Joker's, so the Joker goes first.

`23f0439` caches the Joker buy scores per decision (keyed by action id, reset each decision), which restores the pre-Batch-2 shop cost.

**The review's exact reproductions** (Lua 5.1 and LuaJIT identical):

| Case | `a33ce99` Comp / ML / Expert | `b42d775` Comp / ML / Expert |
|---|---|---|
| $12: `j_ride_the_bus` $6 vs `p_celestial` $4 | OPEN_BOOSTER ×3 | **BUY_ITEM ×3** |
| $12: `j_ride_the_bus` $7 vs `p_buffoon` $4 | OPEN_BOOSTER ×3 | **BUY_ITEM ×3** |
| $20: `j_blueprint` $10 vs `v_grabber` $10 | BUY_ITEM ×3 | BUY_ITEM ×3 |

Rookie buys the Joker in all three cases, before and after.

**Additional price cases** (all tiers buy the Joker):

- $12 `j_joker` $6 vs Celestial $4;
- $30 Ride the Bus $6 vs Celestial $4 (above the reserve);
- $14 Ride the Bus $8 vs Paint Brush $10;
- $16 Blueprint $10 vs Grabber $10;
- $12 Ride the Bus $8 vs Grabber $10;
- $12 Ride the Bus $6 vs Arcana $4 vs Blank $10;
- $11 `j_joker` $5 vs Buffoon $4.

Full-slot Buffoon, Hieroglyph and the other original cases are unchanged. The only behaviour change inside the range is intended: at `b42d775` a $10 Blank voucher with $10 is now **left** by Competitive and above (it was bought before), which resolves a Batch 2 lower-priority observation.

`tests/policy/test_shop_joker_first.lua` covers the reproduction, price mismatches, interest breakpoints, draining Jokers, and full, free and Negative-Joker slots.

## M2: resolved

The rendered source is stripped of comments, indentation and blank lines at render time. Long brackets are refused, so a future template fails closed rather than being half-stripped. Measured with both runtimes, byte- and hash-identical:

| Commit | Rookie | Competitive | Major League | Expert | Headroom below 65,536 |
|---|---|---|---|---|---|
| `a33ce99` (before) | 64,303 | 64,307 | 64,310 | 64,303 | 1,226–1,233 (1.9%) |
| `ca02b7b` | 51,327 | 51,331 | 51,334 | 51,327 | 14,202–14,209 (21.7%) |
| `23f0439` | 51,544 | 51,548 | 51,551 | 51,544 | 13,985–13,992 (21.3%) |
| **`b42d775`** | **51,665** | **51,669** | **51,672** | **51,665** | **13,864–13,871 (21.2%)** |

- **Guard:** `SOURCE_GUARD` = 57,344 bytes, 5,672–5,679 bytes above the `b42d775` sizes, and `test_source.lua` fails if the guard is raised.
- **Equivalence:** a test checks that the stripped and readable sources choose the same actions.
- **Line endings:** a CRLF checkout renders identical bytes to an LF copy.
- **Unstripped template:** 66,839–66,846 bytes, over the cap. It is used only by tests and is never sent to the worker.

## M3: resolved

- **Wording:** `docs/benchmarks/README.md` and the harness docstring now say the reference scorer shares the policy's scoring model. The headline rows are relabelled "agreement with the shared model", and the report carries an `interpretation` field. The "not optimal play or win rate" caveat is prominent.
- **`--hard`:** adds large-hand, scaling, rule-changing and boss families. It explicitly marks their agreement numbers as meaningless (shared blind spots) and reports only reliability (failures, instructions, latency) as trustworthy. The wording now matches what the benchmark demonstrates.

## New findings

### N1 (Medium, resolved in range by `c37537c`): `ca02b7b` broke the benchmark regression gate

`make_scenario` in `ca02b7b` called `rng.choice(shape.get("hand_sizes", [8]))` for **every** scenario. That extra draw shifted the seeded stream of the default families, so `--check` compared different scenarios from the stored baselines:

- **`--check policy_baseline.json`:** `REGRESSION coverage 0.9575 < 0.9778`, FAIL.
- **`--check policy_discard_baseline.json`:** coverage 0.9445 < 0.97, plus Rookie `play_optimal` 0.748 < 0.8049 and regret 0.121 > 0.08, FAIL.
- **Old benchmark script against the new policy:** both gates PASS. So the policy had not regressed; only the gate was broken.

`c37537c` draws a hand size only for stress families (`tests/benchmark_policy.py:340`). At `b42d775` both gates pass:

- `policy_baseline.json`: PASS.
- `policy_discard_baseline.json`: PASS. Forced-discard quality is 0.852 / 0.863 / 0.850 (Comp / ML / Expert) and 0.700 (Rookie).

### N2 (Low, open): the work meter is relative, so extreme Joker rows still exceed the budget

The discard allowance is `WORK + DISCARD_WORK` (`baseline_policy.lua:1540`), added on top of whatever the play estimate already spent. The `PLAY_WORK` gate (`:1473`) lets 12 cards × 64 Jokers through, because 40 × 12 × 66 = 31,680 is under 40,000.

Real-adapter measurements at `23f0439`, 5 hands per cell, 3 discards:

| Hand / Jokers | Peak (Comp / Expert) | Real failures |
|---|---|---|
| 12 / 24 | 1.43M / 1.45M | 0 |
| 12 / 32 | 1.64M / 1.72M | 0 (above the tests' 1.6M guard) |
| 12 / 48 | 2.02M / 2.06M | 1–2 of 5 |
| 12 / 64 | 2.43M / 2.58M | 3–5 of 5 |
| 9 / 64 | 2.15M / 2.23M | 1–5 of 5 |

With discards at 0, the play estimate alone peaks at 1.45M (12 / 64). So the overrun is play plus the relative discard allowance.

- **Reachability:** 40+ Jokers is not reachable in a real Multiplayer match, which is why this is Low. But `docs/CLAUDE_BATCH2_RESOLUTION.md` says oversized shapes below `PLAY_WORK` peak at 1.22M. That is only true for hands over 12 cards, which skip discard search; the ≤12-card, 48+ Joker shapes fail.
- **Fix direction:** cap total work absolutely (discard limit = min(`WORK + DISCARD_WORK`, a fixed total such as ≈36,000 units)) and add 12-card × 48/64-Joker cases to `test_budget.lua`.

### N3 (Low, open, tuning): a cheaper pack still beats a Joker when only one is affordable

When the money covers the Joker **or** the pack but not both, the 20-point intrinsic margin equals exactly $2 below the money reserve (10 points per dollar). So a pack $2 or more cheaper wins on economy:

- **$9:** Ride the Bus $6 vs Celestial $4 → Competitive, Major League and Expert open the pack.
- **$10:** Ride the Bus $7 vs Buffoon $4 → the same.
- **Before Batch 2 (`d6c8cfa`):** both cases bought the Joker.

This matches the documented rule ("a Joker that would drain the money can still lose"), and LV-10 no longer promises Joker-first, so it is not a failed fix. It is a play-strength tuning choice: consider a larger margin, or scaling it with the Joker's estimated gain. Worth watching in the LV-10 playtest.

### N4 (Low, pre-existing, test-only): `tests/astra_host_server_native.py` is flaky

The test checks for `session/data/log_hashes.db` straight after the server's listener passes verification (lines 38–46). The server can open its port before it writes the database, so the check races it.

- **Measured in isolation:** 3 of 6 runs fail at `a33ce99` and 3 of 6 at `b42d775`. The host and server code did not change in the range.
- **Leftovers:** a failed run leaves its temp folder behind (a Windows file lock on `server.err.log`), but no Node process.
- **Earlier runs:** it passed in the Batch 2 run and at `ca02b7b` / `23f0439` by chance.
- **Fix direction:** wait for the database file inside the deadline loop, not only for the listener.
- **Why it matters:** fix it before the consolidated local certification if that runs this script, so a flake is not mistaken for a real failure.

### Doc nits

- **Pre-fix headroom:** `docs/BASELINE_POLICY.md` §4.5 gives it as "≈230 bytes"; it was ≈1,230 bytes.
- **Stale size figures:** the size figures in the §4.5 table and the resolution doc were refreshed in `23f0439`, but `b42d775` grew the source by another ~120 bytes (51,665–51,672 now).
- **Fresh-context re-review:** the section in the resolution doc is the cloud worker's own review, which found no Medium issues. It missed N1, which was later fixed in `c37537c`.

## Other checks

- **Fairness boundary:** the new policy code reads only `observation.self` (hand, hands), `observation.shop.items` and certificate fields. There are no new globals, and `test_source.lua`'s undeclared-global scan passes. Module state (`WORK`, `SHOP_BEST`, `BUY_SCORES`, `PLAY`, `LEVELS`) is reset at the start of every decision.
- **LV-7 `ui` logging:** `tools/practice_service.py:_ui_facts` copies only the AI's own sanitized, allowlisted observation fields (`hand_size`, `blind_requirement`, `current_score`, `hand_levels`), bounded in length and count, into local `decisions.jsonl`. Nothing leaves the machine.
- **Lua 5.1 / LuaJIT portability:** no Lua 5.2+ syntax in the changed Lua. H1 and M1 decisions are identical across runtimes.
- **Performance:**
  - Lua 5.1 mixed benchmark at `b42d775`: 0 failures, 0 illegal, max 905k instructions, mean latency 27–32 ms, p95 ≤ 47 ms.
  - Lua 5.1 `--hard`: 0 failures, max 1.016M instructions, p95 ≤ 47 ms.
  - Shop cost at realistic sizes (≤4 shop Jokers, up to 30 owned) is back to pre-Batch-2 levels after `23f0439`: 532k worst case, against 531k before. `ca02b7b` alone had raised it 40–60%.
  - `run_policy` takes 26 s instead of 11 s because of the new budget tests.
- **LV-7 to LV-10:** all the Batch 2 corrections are in:
  - `ui` field logging with on-screen comparison steps;
  - 10+ card PvP and no-clear states with zero budget errors;
  - the positive Wraith/Ankh/Hex cases;
  - Competitive-and-above scoping;
  - the Negative-Joker full-slot case;
  - valuation and crowd-out checks moved to repository tests.

## Tests run (Windows, `work/runtime-venv` Python 3.12, lupa 2.8)

| Commit | Suite | Notes |
|---|---|---|
| `ca02b7b` | 52/52 scripts pass | |
| `23f0439` | 52/52 scripts pass | |
| `b42d775` | 51/52 pass; `astra_host_server_native` flaky (N4) | 130 unique `run_policy` cases |

The suite results include:

- host 119/119, service 61/61, installer 48/48, certificate 65/65, launcher 64/64, match history 5/5;
- `run_policy` (129 unique cases) and every `run_*` harness under both runtimes;
- all `astra_*` scripts, including the local-game-reference ones. They ran on real copies of `work/reference` and `work/local-server`, not junctions, so the Batch 2 environment failure did not recur.

**Benchmark gates:** FAIL at `ca02b7b` / `23f0439` (N1), PASS at `b42d775`.

**Measurement scripts** used for H1, M1, M2 and shop cost live in the reviewer's local scratchpad, not in Git.

## Spot-check of the current tip (outside the range)

Because `02063b2` changes discard pricing (the H1 code path), the full H1 harness was also run at the remote tip at the time, **`4ed101e`**:

- **Budget failures:** 0 across all 3,600 real-budget decisions per runtime (120 of 120 cells at 0/30).
- **Peaks:** 1,307k (Lua 5.1) and 1,326k (LuaJIT).
- **Cross-runtime:** identical actions (digest `e425a26e065320c2`; it changed from the range's digest as expected, because discard pricing changed).

The new backlog commits have not reintroduced H1. They still need their own review in the next pass.

## Recommendation

- **Safe for continued development:** yes.
- **Blocks the next local certification or playtest:** nothing.
- **For the cloud worker, non-blocking:** N2 (absolute work cap plus 12-card × 48/64-Joker tests), a decision on N3's margin, N4 (make the database check wait), and the doc nits.
- **For the consolidated local pass:**
  - keep LV-7's 10+ card PvP/no-clear budget check and LV-10's crowd-out observation (N3) on the list;
  - review `02063b2`, `4ed101e`, `fc699f8` and anything after them;
  - expect `astra_host_server_native` to flake until N4 is fixed.
