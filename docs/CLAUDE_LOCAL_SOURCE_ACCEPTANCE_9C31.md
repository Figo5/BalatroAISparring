# Acceptance re-review: `feature/ai-sparring-v1` at `9c31d2f`

**Reviewer:** Claude Code, `claude-opus-5-5`, High. I did the review myself; no other model was used, and nothing was blocked by quota or auth errors.

**Tip checked:** `9c31d2fe59c03ca37c88ef8fea3ac8046efd2d03`. `git status --porcelain` was empty before and after my checks.

**What I reviewed:**
- The actual diff `7f2aced..9c31d2f`.
- The two new tracked release tools and their tests.
- `eb39c62..9c31d2f` contains only the five declared docs (README, `LOCAL_H1_VERIFICATION`, `LOCAL_PROGRESS`, `LOCAL_REGRESSION_VERIFICATION`, `PLAYABLE_ACCEPTANCE`).
- I did not review `3745d9c`.

**What I did not do:** no edits, no Git changes, no staging, package or certificate creation, no native launch, and no reads or writes of live content. The original main checkout was not touched.

## Verdict

**I accept the repository source at `9c31d2f` for the fresh native certification.**

- No Critical, High or Medium findings.
- All of my earlier findings are resolved: M-A, M-B and L-a through L-d, plus the interest-breakpoint churn.
- What remains is two Low documentation items and some non-blocking limitations.

**What this acceptance covers:** repository and integration source only. These are still separate required gates:
- seven-phase native certification of the exact package;
- the final review of that exact package before install;
- fresh backups and the scoped upgrade;
- a real UI smoke test.

I observed no native or human gameplay.

## Checks I ran

**Repository suites (both Lua runtimes; all wrote only to Temp):**

| Check | Result |
|---|---|
| `tests/test_native_certification_runner.py` | 15/15 |
| `tests/test_upgrade_reviewed_companion.py` | 19/19 (fake roots: fixture evidence only, not proof of a real install) |
| `tests/run_policy.py` | 186/186 per runtime, including 16 Psychic and 12 churn cases each |
| `tests/run_engine.py` | 176/176 per runtime |
| `tests/test_practice_host.py` | 126/126 |

**My own fixtures (scratch copies in Temp):**

1. **M-A before/after through the real adapter and sandbox.** Same frames, the `7f2aced` policy against the current one:

   | Case | `7f2aced` policy | Current policy |
   |---|---|---|
   | Psychic, 1–4 cards, no discards | waits forever (`policy_no_action`) | plays a certified short play |
   | 3 cards, discards left | discards | discards |
   | 5–6 cards | plays five cards | plays five cards |
   | disabled Psychic | plays the pair | plays the pair |

   Results are identical on both runtimes.

2. **Multi-step shop simulation through the real adapter, reader and sandbox.**
   - Covers the strong tiers, 4 held sets, 6 shop sets including both orders, $8–36 and prices $2–6 for each item.
   - Result: 52,200 cases per runtime, 41,895 sales. Every sale was followed by a strictly higher-worth purchase, with no repeated sale and no sale left without a purchase.
   - A separate focused interest-breakpoint grid (3,672 cases per runtime) also found nothing.
   - Identical on Lua 5.1 and LuaJIT.

3. **Cross-kind tie probe.**
   - I tried every certificate permutation, including `LEAVE_SHOP` first.
   - The result never changed: the action catalogue reaches the policy in canonical id order.
   - An exact three-way tie (Major League or Expert at $4 with $3 consumables, where a buy scores exactly the same as `LEAVE_SHOP`) resolves deterministically to leaving the shop.

**Evidence I checked against current files by hash:**
- **Final suite:** 62 entries, all exit 0. Of the 312 recorded files, exactly the five docs differ now. No tracked file is missing from the record.
- **H1 inputs:** all 30 relevant files match.
- **H1 results:**
  - Lua 5.1 peak is 1,256,000 instructions and LuaJIT is 1,263,000, against the real 2M budget.
  - 0 failures, and both runtimes share the identical digest `6920e8b4…`.
  - Maximum candidates 120, Tarot candidates 24.
- **Rendered source size** (I measured it myself): 56,385–56,392 bytes on both runtimes, which is 952 bytes under the 57,344 guard and 9,144 under the 65,536 cap.
- **Tool and test hashes** match `final-rereview-input-binding.json`.
- **Worker exports:** both show only `opencode-go/deepseek-v4.1-flash`, `high`.
- **Historical evidence is preserved.** `upgrade-fault-injection-pinned-after.json` was regenerated at 23:09 on September 30, before this re-review. The copy I verified previously is byte-identical (`64113300…`) under `prior-claude-7f2-review-evidence/`.

## Dispositions

| Finding | Status | What I verified |
|---|---|---|
| **M-A** Psychic stall | **Resolved** | Applies only to the strong tiers, an active Psychic, an actual own hand of 1–4 cards, and no certified discard that `discard_score` accepts (`baseline_policy.lua:2864-2882`). A short play then gets a `-1` floor (`:520-522`), and the flag is reset every decision (`:2850`). `discard_score` reads only the observation, and `score_of` returns non-nil for a discard exactly when it does, so the early check matches the real ranking. At five or more cards an incomplete catalogue still waits (`policy_no_action`), on purpose. It reads only the hand size: no deck, RNG or opponent data, and no invented actions. |
| **M-B** source binding | **Resolved** | `tools/run_native_certification.py`: <ul><li>importing it has no side effects;</li><li>the repo root resolves correctly (`parents[1]`);</li><li>it requires `--reviewed-commit` and a clean tree, including untracked files, at the start, after packaging and at the end (`:194`, `:229`, `:270`);</li><li>it refuses an existing evidence directory before creating anything (`:195`);</li><li>every module in the live and both staged subtrees is checked against the reviewed Git blobs by exact file set, size and SHA256, excluding only the generated top-level `config.lua` (`:89-128`);</li><li>the CRLF fallback compares `git hash-object --path` against the blob id. It is genuinely needed here, because this checkout has system `core.autocrlf=true` and the working tree is CRLF;</li><li>at the end it re-checks the digest captured at packaging time, the source binding and the staged binding before writing any report (`:131-159`, `:267-269`).</li></ul> The seven phases, fresh backups, Mods copy excluding only `AISparring`, and finalizing staged roles before measurement are all unchanged. The upgrade helper now requires the native report's commit, package digest and certificate id to match (`upgrade_reviewed_companion.py:17-30`, `:116`), on top of the existing acceptance, certificate and old-package checks. |
| **L-a** highlight timing | **Resolved** | New engine case `production_log_reports_the_dispatch_time_highlight_then_settles` uses the real logger. The design doc now says `exec_ok` plus `highlight=kept` is the honest state at dispatch time; settled cleanup and the `STOP_USE` wait are confirmed separately. |
| **L-b** equal-score purchase | **Resolved** | A worth tie-break applies only between equal-scored consumable buys (`:2029-2045`, `:2939-2947`). Both shop orders and `LEAVE_SHOP` first are tested. Prices, economy, reserve and editions are untouched. |
| **Interest-breakpoint churn** | **Resolved** | A sale must target the purchase the same `buy_score` and tie-break would pick, and it must strictly raise held worth. It is also refused when a same-or-worse offer is cheaper than the upgrade (`:2547-2585`). This is safe because the economy bonus never decreases as remaining money rises. Astra's case ($22, Star $3, Saturn $4) is now a hold rather than a churn. There is no memory across decisions and no engine mutation. |
| **L-c** closed-game and interrupt safety | **Resolved** | `no_game()` now runs before the snapshot (`:123`). The protected block catches `BaseException`. Rollback still restores only an unchanged, verified archive into an absent target with every game closed, never over a partial target and never touching saves, and it keeps a successfully installed companion if later diagnostics fail. The 19 fake-root scenarios cover SystemExit and interrupts. |
| **L-d** new matches during a deferred stop | **Resolved** | A stop flag is set under the lock in `stop()` (`practice_host.py:3698-3702`). `_op_start` refuses new tickets inside its reservation lock (`:3882-3886`). Poll, acknowledgement, closure and the retained human window keep working, and `start()` clears the flag. Three new tests cover this. |

Unchanged and still correct: the broker and executor own-visible-target checks, refusal of stale and forged actions, and the observation-only policy path.

## New Low findings (documentation only)

- **Stale size figure in `docs/BASELINE_POLICY.md`.** It gives 55,771–55,778 bytes (about 1.5 KB under the guard) for the final fixes. The actual size is 56,385–56,392 bytes, 952 bytes under the guard.
- **Function name that doesn't exist.** The same doc names `predicted_consumable_buy`, but that logic is written inline in `sell_consumable_score`.

## Limitations that don't block anything

- **The interest guard can skip a real upgrade.**
  - **Example:** holding Death and Sun with $30, a shop offering Star at $3 and Saturn at $4 produces no sale on any strong tier. I reproduced this.
  - **Why it's harmless:** after a sale both would sit at the interest cap and Saturn would win, so the result is a missed upgrade, not churn.
- **Source-size headroom is now 952 bytes under the guard.** The next feature growth needs compaction first.
- **The CRLF fallback depends on the local Git setup.** It trusts the clean filter Git applies, which here is only system `autocrlf`; there is no `.gitattributes` and no filter driver.
- **A tiny unprotected interrupt window remains.** Between the rename and `archived=True`, an interrupt would leave the target absent with the archive intact, which is the documented manual-restore state.
- **A label mismatch in the portability proof.** `portable-release-test-proof.json` labels its source as `7f2aced`. Its tool and test hashes equal the final tracked files, and I re-ran both suites at `9c31d2f`.
- **Earlier limitations still apply:**
  - Death candidates favour the leftmost visible card.
  - The L2 reserve trade-off holds in extreme consumable counts.
  - H1 and the benchmarks are fixture regression evidence, not native latency, win-rate or optimality.
