# Claude Batch 3 review (`b42d775..0f48623`, including the targeted-Tarots WIP)

- **Reviewer:** Claude Code (claude-opus-5-5), independent local reviewer on the user's Windows machine.
- **Reviews:** all cloud work after the last reviewed range (`a33ce99..b42d775`, `docs/CLAUDE_BATCH2_REREVIEW.md`), and the independent review of the targeted-Tarots WIP commit `0f48623`.
- **Safety:** the live Balatro install, Mods folder, saves, certified build and the user's local `main` were not touched. Nothing was re-certified or reinstalled. All work ran in separate detached checkouts.

## Exact range reviewed

- **Snapshot:** `origin/feature/ai-sparring-v1` at **`0f48623`**. The remote was re-fetched before this document was committed and had not moved.
- **Range:** `b42d775..0f48623`, 57 cloud commits:
  - 56 commits up to `c748be1`;
  - the WIP `0f48623`.
  - `9156685` is the previous review document and is not cloud work.
- **Carried over:** `02063b2`, `4ed101e` and `fc699f8` landed during the previous review. They were out of its range and are reviewed here.
- **Test snapshots:** the full suite ran twice:
  - at `c748be1`, the tip when this review started;
  - at `0f48623`, pushed during the review.

### Did the targeted-Tarots work land?

- **At `c748be1`:** only the design proposal was present (`97f27b4`, `docs/HAND_TARGETS_DESIGN.md`, status "proposed").
- **`0f48623`:** adds the implementation as an explicitly marked WIP (`docs/CLOUD_PROGRESS.md`).
- **No later commit exists.** This review is that WIP's first independent review. The cloud progress file lists it as gate 2.

`docs/CLOUD_PROGRESS.md` first appears in `0f48623`. The other docs read for this review:

- `docs/LOCAL_VALIDATION_QUEUE.md`;
- `docs/POLICY_BACKLOG.md`;
- the new design docs: `BLIND_DISABLED`, `HAND_HISTORY`, `OWNED_VOUCHERS`, `SCALING_VALUES`, `HAND_TARGETS`.

## Verdict

- **No Critical or High findings.**
- **Two Medium findings:**
  - M1, from the boss-awareness work before the WIP;
  - M2, in the WIP's consumable economy.
- **Fairness:** the new observation fields and the targeted-Tarot action stay inside the fairness boundary.
- **Targeted-Tarot mechanics are correct:** the adapter, executor, broker and rollback all behave correctly, and a forged or stale action is refused before any engine call.
- **Budget:** the H1 large-hand budget is intact with Tarots held.

| ID | Severity | Where | Status |
|---|---|---|---|
| M1 | Medium | `baseline_policy.lua` `analyse_plays` (`041dec6`) | open |
| M2 | Medium | `baseline_policy.lua` `sell_consumable_score` (`0f48623`) | open |
| L1 | Low (test defect) | `tests/test_practice_service.py` (broken by `1dcc2fb`) | open, pre-existing |
| L2 | Low | adapter certificate cap vs reorders (`0f48623`) | open |
| L3 | Low | executor defence in depth (`0f48623`) | open |
| L4 | Low | `practice_service.py` `_action_summary` (`0f48623`) | open |
| L5 | Low (docs) | `HAND_TARGETS_DESIGN.md` vs implementation | open, WIP gate 4 |
| N2, N3, N4 (Batch 2) | Low | `98c8d62` | **resolved** (N4: 6/6 isolated passes) |

## Medium findings

### M1: The Psychic's five-card rule is skipped when the AI owns a rule-changing Joker

`analyse_plays` returns early when the AI owns Four Fingers, Shortcut, Smeared, Splash or Pareidolia (`RULE_JOKERS`). It does so **before** it sets `MIN_CARDS = 5` for The Psychic.

- **Consequence:** play ranking then falls back to the category score in `play_score`.
- **That fallback:**
  - blocks The Eye / The Mouth types (`blocked_hand`);
  - never applies the five-card rule;
  - penalises the padding cards as junk (`play_junk`).

So under The Psychic the AI prefers the bare pair to the padded five-card play the adapter offers. A hand of fewer than five cards scores nothing under The Psychic.

**Reproduced (Lua 5.1 and LuaJIT, identical):**

- **Setup:** `Support.pair_frame()` with `match.blind = "bl_psychic"`, offering a 2-card and a padded 5-card play.
- **Without a rule Joker:** Competitive, Major League and Expert all play 5 cards.
- **With any one of the five rule Jokers:** all three play **2** cards.

**Why it matters:** these Jokers are common, and The Psychic is a normal boss. Each occurrence wastes a hand at a boss. This is a play-strength defect, not a safety or fairness one.

**Fix direction:**

1. Resolve `psychic` / `MIN_CARDS` at the top of the decision (next to `EYE_PLAYED` / `MOUTH_ONLY`), not after the early returns.
2. In the category fallback, treat `#cards < MIN_CARDS` like `blocked_hand` (return `CONF.unknown + 1`).
3. Add a test: a Psychic frame with each `RULE_JOKERS` center.
4. **Same pattern elsewhere:** the `PLAY_WORK` early return also runs before the Psychic check. It only triggers at absurd hand × Joker sizes, but the same fix covers it.

### M2: Usable targeted Tarots are sold whenever the consumable slots are full, which makes a sell/buy churn

`sell_consumable_score` (WIP) sells an allowlisted Tarot whenever `#consumables >= consumable_slots`. It does this whether or not anything in the shop needs the slot. `buy_score` still buys allowlisted Tarots while a slot is free.

**Reproduced at Competitive, Major League and Expert (both runtimes):**

- **Two slots, holding Death and The Sun, shop empty:** `SELL_CONSUMABLE consumable:1`. It sells a usable Tarot for about $1 with nothing to buy.
- **Two slots, holding The Sun, Strength for sale at $3:** `BUY_ITEM`.
- **The loop:**
  1. After the purchase the slots are full again, so the next decision sells one.
  2. A free slot then buys the next Tarot on offer.

  Each cycle costs about $2 and discards a Tarot the policy values. The AI can never keep two Tarots in two slots.

**Fix direction:**

- Sell a usable Tarot for a full slot only when a certified, affordable purchase actually needs that slot (a Planet or a better consumable), and pick the lowest-value held one.
- Otherwise never sell it.
- Add a multi-decision test that plays sell → buy → sell and asserts no churn.

## Lower-priority findings

- **L1 (pre-existing test defect; confirmed not caused by the WIP).** `test_baseline_source_provider_renders_all_difficulties` checks for the literal `"function(observation, actions)"`. Since the source squeeze (`1dcc2fb`) the rendered text is `function(observation,actions)`.
  - **Bisected:** it passes at `1dcc2fb~1` and fails at `1dcc2fb`, and it fails identically at `c748be1` and `0f48623`.
  - **Scope:** the product is unaffected; the policy loads and runs.
  - **Fix:** match with a whitespace-tolerant pattern, e.g. `re.search(r"function\s*\(observation\s*,\s*actions\)", source)`.
  - **Before certification:** fix it first, so the service suite reads 61/61 and a real regression cannot hide behind a "known" failure.
- **L2 (reorders dropped at the certificate cap).**
  - **With Tarots:** a 12-card hand holding Death, Strength and The Sun reaches the 120-certificate cap (100 without Tarots, 120 with; 24 of them are Tarot certificates).
  - **Effect:** reorders are the lowest priority, so the Joker/hand reorder certificates are silently dropped in those states.
  - **Options:** lower `HAND_TAROT_TOTAL` for large hands, or reserve a few slots for Joker reorders.
- **L3 (executor defence in depth).** `validate_use_on_hand` checks four things:
  - the state;
  - that the gates are clear;
  - the target count against the engine card's own bounds;
  - that no card is forced.

  It does **not** check that the source center is on the allowlist, or that the targets are face-up and not debuffed. It relies on certificate binding for these.
  - **Verified:** a forged `USE_CONSUMABLE_ON_HAND` on a face-down card is refused by the broker before any engine call (end-to-end check below), so this is not exploitable today.
  - **Suggestion:** mirror the allowlist and the target visibility check in the executor, as `validate_use_consumable` mirrors `check_use`.
- **L4 (live evidence gap).**
  - **Current log:** `_action_summary` records only `type` and the card count.
  - **Gap:** `decisions.jsonl` therefore cannot show which Tarot was used on which cards.
  - **Suggestion:** add the bounded `source_ref` (and the refs) so the LV entry can compare a use with the screen.
- **L5 (design and implementation drift, already WIP gate 4).** `HAND_TARGETS_DESIGN.md` is still "proposed" and describes a different shape from the implementation:

  | | Design | Implementation |
  |---|---|---|
  | Action | extends `USE_CONSUMABLE.target_refs` | a new action type, `USE_CONSUMABLE_ON_HAND` |
  | Targets per use | 1–3 | at most 2 (singletons for Strength and the suit Tarots) |
  | Allowlist | includes Magician, Empress, Hierophant and Tower | those four are left out |

  The implementation is the more conservative of the two. Update the design, `LEGAL_ACTIONS.md`, `ENGINE_ADAPTER.md` and `BASELINE_POLICY.md` when the WIP is converted.

## Targeted-Tarots verdict (`0f48623`)

**Mechanics correct, fair and bounded. Not yet ready to accept as-is: fix M2 (and L1) first.**

| Check | Result |
|---|---|
| Only legal visible targets | The adapter builds targets from `grouping_identity` (face-up, rank and suit visible, not Stone) and requires `debuff == false`. Face-down, Stone and debuffed cards are never offered (engine test `adapter_offers_allowlisted_tarots_on_visible_targets`). `actions.lua` re-checks that each ref is a non-redacted `self.hand` card. |
| No hidden information | Targets are the AI's own face-up hand. Effects are public card text and are simulated on copies inside the policy. No deck, RNG or future-card data is involved. Random or deck-altering Tarots (Wheel, Hanged Man, Aura, Cryptid) are out of scope. |
| Forced-selection bosses (Cerulean Bell) | Vanilla applies a Tarot to **every** highlighted card, and `CardArea` never unhighlights a forced card. So a forced card would silently join the targets. The adapter certifies nothing while any card is forced, and the executor refuses in the same case (tests cover both). |
| No stale highlight or selection | The executor clears the existing highlight, then highlights with `require_exact = true` (an exact set match). On an engine refusal or a no-op use it calls `unhighlight_all`. Vanilla's own use unhighlights on success. An end-to-end stale response (the hand changed after certification) is refused with `loop_stale`, with no engine call. |
| Target counts | Bounds come from the engine card (`mod_num` / `max_highlighted` / `min_highlighted`), and v1 offers only 1 or 2 targets (Death exactly 2). The executor re-validates the bounds, and the real `can_use_consumeable` is re-checked after highlighting. |
| Strength / Death / Lovers / Chariot / Justice / Devil / suit Tarots | Checked against the vanilla source dump (`card.lua` `use_consumeable`). Strength is +1 rank with Ace → 2; the policy models this, so it never "upgrades" an Ace. Death copies the rightmost highlighted card by `T.x` onto the others: see "Death target order" below. Enhancement Tarots apply `mod_conv`, offered only on base cards. Suit Tarots apply `suit_conv`, not on a card already of that suit. Wild is modelled in flush detection, Glass and Steel in the estimate, and Gold as $3 held. |
| Use only after the targets are selected | Highlighting, the predicate and `use_card` run in one synchronous executor dispatch. There is no separate "select" action the policy could skip. |
| Stale actions | Epoch and revision binding is unchanged. End to end, a stale response is refused and a forged uncertified target is refused (`loop_dispatch_failed`, 0 engine calls, broker not revoked). |
| Human state | The executor touches only the AI runtime's own `G.hand` and `G.consumeables`. There is no cross-runtime path. |
| Service and protocol | `USE_CONSUMABLE_ON_HAND` appears in every allowlist: `actions.lua` phases, keys and required fields; `observation.lua` `CERT_TYPES`; executor latch and leave tables; `practice_service.DEFAULT_ACTION_TYPES`. The Python worker's array fields already include `card_refs`. |
| Pack and hand context | Certified only in `PLAY_HAND` and `MULTIPLAYER_PVP` (not `DISCARD`, shop, booster or consumable selection). The executor also requires `SELECTING_HAND`. Arcana-pack picks are still gated by the engine's own `can_use_consumeable` (nothing highlighted), so a targeted Tarot is never picked from a pack. |
| Consumable lifecycle after use | `USE_CONSUMABLE_ON_HAND` shares the `card_leave` latch on `consumeables`. Vanilla sets `PLAY_TAROT`, locks use and `STOP_USE` until its events finish, so the next decision waits for the effect. A no-op use (source still held) is a clean `CALLBACK_FAILED` that also clears the highlight. |
| Rookie | `hand_tarots = false`. Rookie never uses these Tarots, never buys them and sells a held one, which is the previous behaviour. |

**Death target order (live item).**

- **Vanilla rule:** the rightmost highlighted card by `T.x` is the copy source.
- **Adapter and policy rule:** they treat the higher hand ordinal as the right card.
- **Why they agree:** `CardArea:align_cards` derives `T.x` from the card order, and the executor acts only in a settled `SELECTING_HAND`.
- **Remaining check:** confirm it once live.

**End-to-end check (independent; not in the repository).**

- **Pipeline:** real adapter, reader and `actions.generate`, then the real restricted `policy_env` running the rendered baseline policy, then the real production broker and decision loop, then the real executor. Only the transport is faked, and `use_card` is a recorder that removes the used card.
- **Hand:** 9♠ 9♥ 8♣ 4♦ 2♠, holding Strength.
- **Competitive, Major League and Expert (identical on both runtimes):**
  1. They choose `USE_CONSUMABLE_ON_HAND consumable:1 hand:3`.
  2. The broker accepts it.
  3. `use_card` runs with exactly one card highlighted, the 8.
- **Rookie:** plays the pair.
- **Refusals:** the forged and stale cases above were refused.

## Other checks (range `b42d775..c748be1`)

### Adapter, reader and observation schema

- **Owned scaling-Joker `current`.**
  - The adapter and the reader keep identical 16-entry tables.
  - The reader recomputes the value and step from the engine card and rejects any view that disagrees.
  - The value is shown only when the Joker is not debuffed, matching the card text.
  - The observation accepts exactly `{kind, value, step}` within bounded ranges.
- **Owned vouchers.**
  - Only keys of `G.GAME.used_vouchers` that are true, are Voucher centers and match `^v_[a-z0-9_]+$`.
  - Sorted bytewise and bounded (32 kept, 256 scanned), with Seed Money / Money Tree kept on truncation.
  - The reader enforces strict byte order.
  - They sit in zone `voucher`, separate from the shop's `shop_voucher`, and no action targets them.
- **`blind_disabled`.**
  - Sent only alongside a blind.
  - The reader requires it to equal the engine's own `G.GAME.blind.disabled`.
  - It is part of the decision signature, so a Chicot or Luchador change mid-decision is a new epoch.
- **`played_this_round`.** Only in round phases, and it is the AI's own hand history.

### Legal actions

- **The Psychic:** padded five-card plays are added only for a non-disabled `bl_psychic` (public key).
  - The padding uses visible-rank kickers first, then other cards by position.
  - Hidden identities cannot change the order.
- **Duplicates:** plays are now deduplicated order-insensitively.
- **Unchanged:** the broker, the executor action set before the WIP, and the forced-card handling.

### Economy

- **Interest cap:** $5 by default, $10 with Seed Money, $20 with Money Tree (vanilla $50 / $100). It is read from the AI's own vouchers.
- **Retune:** the Major League / Expert money reserve and reroll changes were judged on held-out paired seeds (`docs/benchmarks/README.md`). The cloud notes are candid about statistical ties.

### Scaling Jokers and replacement

- **Offered Jokers:** priced at an ante-dependent mid-life proxy, and only for Jokers this policy can grow.
- **Owned Jokers:** use the shown value plus the per-hand growth step:
  - Green Joker grows each hand;
  - Spare Trousers on two pair;
  - Runner on straights;
  - Square on four-card hands;
  - Wee on scored 2s;
  - Ride the Bus resets on a scored face card.
- **Spare Trousers key:** corrected from `j_spare_trousers` to `j_trousers` (`f8cc6d1`).
- **Selling:** a grown scaling Joker is never sold for a fresh copy, only one at its base value.
- **Debuffed Jokers:** show no value and are never sold by this path.

### Boss awareness

- **The Eye / The Mouth:**
  - use the AI's own `played_this_round`;
  - are disabled by `blind_disabled`;
  - block the type in the estimate, the discard search and the category fallback.
- **The Psychic:** see M1.
- **Chicot / Luchador:** a disabled boss switches all boss rules off (tests cover the edges and the epoch change).

### Simulators

`benchmark_blinds.py` and `benchmark_runs.py` are test-only and never shipped.

- **Seeding:** seeded and deterministic.
- **Fidelity:** vanilla boss requirements and antes, and a paired A/B mode.
- **Result:** both passed in the suite.

### Fairness

All new inputs are:

- the AI's own vouchers, hand history and Joker values;
- the public boss key and the disabled flag;
- its own face-up hand.

`test_source.lua` passes; it scans for undeclared globals and prohibited tokens. The policy module state is reset at the start of every decision: `MIN_CARDS`, `EYE_PLAYED`, `MOUTH_ONLY`, `CURRENT_EFF`, `TAROT_*`, `INTEREST_CAP`, `WORK`, `BUY_SCORES` and `SHOP_BEST`.

**Nothing reads the opponent, globals, deck order or RNG.**

### Source squeeze (`1dcc2fb`, `963df6d`)

- **What it does:** removes spaces outside quotes next to punctuation.
- **Guards:** it never joins `--`, `..`, `[[` or `[=`, or a digit with `.`.
- **Safety net:** a test proves the squeezed and unsqueezed sources compile to byte-identical Lua 5.1 bytecode for every difficulty. This is sound.
- **Side effect:** the squeeze is what broke L1.

### Portability and determinism

- **Language:** no Lua 5.2+ syntax.
- **Iteration:** `pairs` is used only for order-independent sets and copies.
- **Cross-runtime:** Lua 5.1 and LuaJIT chose identical actions in every harness run (digests below).

## Budget and source size

### H1 large-hand spot-check

- **Harness:** real adapter frames, 10 trials per cell.
  - **Hand sizes:** 8, 10 or 12 cards, with 5 or 8 Jokers.
  - **States:** a non-clear blind and a PvP blind.
  - **Difficulties:** Competitive, Major League and Expert.
- **Budget:** the real 2,000,000-instruction budget, plus an uncapped instrumented run.

| Snapshot | Held Tarots | Peak (instructions) | Over budget | Real-budget failures | Cross-runtime |
|---|---|---|---|---|---|
| `c748be1` | none | 1,166k | 0 | 0/240 per runtime | identical (`93df9ffc53f0b0fe`) |
| `0f48623` | none | 1,166k | 0 | 0/240 | identical, **same digest as `c748be1`** (no behaviour change without Tarots) |
| `0f48623` | Death + Strength + The Sun (24 Tarot certificates) | **1,395k** (Lua 5.1 1,391k, LuaJIT 1,395k) | 0 | 0/240 | identical (`8725415575a65bda`) |

- **Headroom:** about 30% at the worst Tarot-heavy 12-card state.
- **Benchmarks:** `benchmark_policy` shows 0 failures and 0 illegal actions.

### Rendered source size

The cap is 65,536 bytes; the test guard is 57,344.

| Snapshot | Largest difficulty (Major League) |
|---|---|
| `b42d775` | 51,672 bytes |
| `388a781` (before the squeeze) | 55,333 |
| `c748be1` | 51,382 |
| `0f48623` | **53,665**: 11,871 bytes (18%) under the cap, 3,679 under the guard |

The WIP adds about 2.3 KB. The guard, not the cap, is now the nearer limit.

## Tests run (Windows, `work/runtime-venv` Python 3.12, lupa 2.8)

| Snapshot | Scripts | Notes |
|---|---|---|
| `c748be1` | 53/54 pass | only `test_practice_service` 60/61 (L1) |
| `0f48623` | 53/54 pass | only `test_practice_service` 60/61 (L1, same case) |

Details at `0f48623`:

- **Engine and policy harnesses (both runtimes):**
  - `run_engine`: 165/165 per runtime;
  - `run_policy`: 181 unique cases, including `test_hand_tarots` 7/7.
- **Service-level suites:** host 119/119, service 60/61, installer 48/48, isolation certificate 65/65, launcher 64/64, match history 7/7.
- **Harnesses:** `run_decision`, `run_m2`, `run_runtime`, `run_boundary`, `run_companion` and `test_runtime_cross_service` all PASS, as do estimator parity 2/2 and every `astra_*` script. The `astra_*` scripts ran on real copies of `work/reference` and `work/local-server`.
- **Benchmarks:** `benchmark_policy`, `benchmark_blinds`, `benchmark_runs` and `benchmark_m2` all pass.
- **`astra_host_server_native` (N4):** 6/6 isolated passes after `98c8d62`, so the flake is fixed.

**Reviewer-only harnesses** are kept in the local scratchpad, not in Git:

- the H1 harness;
- the Psychic × rule-Joker reproduction;
- the churn reproduction;
- the end-to-end Tarot check.

## Needs real Balatro validation

Add these to `docs/LOCAL_VALIDATION_QUEUE.md` when the WIP is converted.

### Targeted Tarots

- A use on each allowlisted Tarot, with the on-screen card matching the policy's expectation. Death's source must be the right-hand card.
- The PvP-blind use.
- No leftover highlight after a use, or after a refused one.
- The Cerulean Bell: no use while a card is forced.
- `STOP_USE` timing: no decision until the effect settles.

### Other items from this range

- **Owned scaling-Joker `current` values:** each must match the card text.
- **Debuffed Jokers:** show no value.
- **`blind_disabled`:** flips when Chicot or Luchador disables a boss.
- **The Eye and The Mouth:** blocking follows the round's played hands.
- **The Psychic:** plays five cards, including the M1 case once fixed.
- **The interest cap:** changes after Seed Money and after Money Tree.
- **Owned vouchers:** listed as in Run Info.

### Unchanged items

- LV-7 budget: 10+ card PvP and no-clear states with zero `policy_budget_exceeded`.
- LV-1 to LV-10: still open.

## Ready for consolidated re-certification and playtest?

**Not yet. Fix M1, M2 and L1 first (all small), then run one consolidated local re-certification and playtest.**

- **Blocking reasons:** none of the findings is a safety or fairness blocker. But M2 bleeds money every shop visit once the AI holds two Tarots, and M1 wastes hands at a common boss. Both would confound the LV-7/LV-10 play-strength observations the playtest is meant to collect. L1 would leave the service suite red during certification.
- **Is `0f48623` safe to include in that batch?** Yes, after M2 and the WIP conversion (CLOUD_PROGRESS gates 3–4) are done. With both it and M1 fixed, a short re-review of the fixes is enough; no full re-review is needed.
- **Excluding the Tarots instead:** the pre-WIP tip `c748be1` is certifiable once M1 and L1 are fixed.
