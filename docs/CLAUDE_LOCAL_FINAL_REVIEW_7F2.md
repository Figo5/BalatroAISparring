# Final acceptance review: `feature/ai-sparring-v1` at `7f2aced`

**Reviewer:** Claude Code, `claude-opus-5-5`, High effort. I did the review myself; no other model was used.

**Tip reviewed:** `7f2aceda1604527e4bdcff75408cf55b30cfb2ec`, which I checked independently. The tracked tree was clean at the start and is still clean (`git status --porcelain` is empty). The only things that may have changed are ignored `tests/__pycache__` and `tools/__pycache__` folders, possibly from my module imports.

**Ranges reviewed:** the WIP range `c748be1..0f48623` and the follow-up range `9498cfa..7f2aced`. I read the actual code and diffs. I did not review `3745d9c`.

**What I ran (all read-only for the checkout):**
- Two reproduction fixtures on both Lua 5.1 and LuaJIT, kept in a Temp scratch folder.
- A copy of `check_upgrade_faults_hardened.py`, run with its output redirected to Temp. All 14 scenarios match their expected outcomes.
- `check_real_old_package_pin.py`. This only reads and hashes the installed companion. Result: digest `1f6e2a6b…`, and all 27 files match.

**What I did not do:**
- I did not re-run the full suite; I checked its evidence by hash instead.
- I made no edits, commits or staging changes, did not touch the main checkout, and launched nothing.
- I observed no human or native gameplay.

## Verdict

- **No Critical or High findings.**
- **Two Medium findings:**
  - **M-A:** a policy stall under The Psychic.
  - **M-B:** a source-binding gap in the native certification runner.
- **Four Low findings.**
- The core targeted-Tarot work holds up: fairness, stale-action handling, the executor checks, the logging fix and the host shutdown fix are all correct.

## Medium findings

### M-A: Under The Psychic with fewer than five cards and no discard, the AI waits forever

**Where:**
- `baseline_policy.lua:506-513`: `play_score` returns `nil` for any play shorter than five cards.
- `decision_loop.lua:729-753`: `policy_no_action` makes the loop idle and re-ask, capped at 2 seconds, with no limit on retries.
- `tests/policy/test_psychic_rule_jokers.lua:147-157` locks this behaviour in as intended.

**Trigger:** an active Psychic, a hand of 1–4 cards (deck used up), and no discards left. In vanilla, a short play is legal and scores 0 (`game.lua:280`, `h_size_ge = 5`), and the round then moves on to a loss. Here the AI's run never advances, so the match hangs.

**Reproduced:** with a 3-card hand, two short plays offered and no discard, Competitive, Major League and Expert all return `policy_no_action` on both runtimes.

**How likely:** rare, and only when the AI is already losing. It needs extra hands and discards (e.g. Grabber, Nacho Tong, Wasteful, Recyclomancy), a smaller deck such as Abandoned, or destroyed cards. Multiplayer allows The Psychic: every reference ruleset has `banned_blinds = {}`.

I'm challenging the stated requirement "never short … including no-valid-five". It should be "never short while a five-card play or a discard is certified".

**Fix:** when no certified play reaches `MIN_CARDS` cards, give short plays a floor score below every other scored action instead of `nil`. Change the test to match.

### M-B: The native runner never ties the package to a clean, reviewed commit

**Where:**
- `run_native_certification.py:28-45` packages from the working tree. `build_package` copies `REPO/AISparring` as it is on disk (`install_companion.py:435`).
- The package manifest records no commit.
- `HEAD` is read only at the end (`run_native_certification.py:77`), and cleanliness is never checked.
- The acceptance record has no commit field (`install_companion.py:582-623`).
- The upgrade helper checks the commit (`upgrade_reviewed_companion.py:56-58`) only at upgrade time. It cannot prove which source the package was built from.

**Trigger:** any tracked or untracked edit under `AISparring/` before packaging, or a commit landing during the hours-long run. The certificate would then report a reviewed `HEAD` while the package contains different bytes.

**Also:** `OUT.mkdir(exist_ok=True)` (line 11) means a rerun overwrites an earlier attempt's evidence files.

**Fix (helper only, no companion bytes change):**
- Require `--reviewed-commit`.
- Check `HEAD` and a clean `git status --porcelain` (including untracked files) at the start, after packaging and at the end.
- Compare `live/AISparring` and the staged files, excluding the config file, against the blobs from `git show <commit>:AISparring/…`.
- Refuse if `OUT` already exists.
- Have the upgrade helper require `certificate.json` `source_commit` to equal `--reviewed-commit`.

## Low findings

- **L-a: success logs will normally say `highlight=kept` in the real game.**
  - Vanilla clears the highlight in a queued event (`card.lua:1150`), after the executor has already written its log line.
  - The tests clear it immediately in the fixture `use_card` (`test_hand_tarots.lua:288-298`, `325-334`), so they assert `highlight=cleared` on success.
  - The design doc also says "actual highlight state".
  - Only refusals and no-ops get `cleared` at log time. During live checks, read `exec_ok` + `kept` as expected, and confirm cleanup from the next observation.
- **L-b: after a justified sale, the AI can buy the wrong consumable.**
  - **Setup:** holding Death, shop offering Star ($3) at `shop:1` and Saturn ($3) at `shop:2`.
  - **Result:** all strong tiers buy Star, because consumables score the same and the tie goes to the lower id. Reproduced on both runtimes.
  - **Effect:** the next decision sells Star and buys Saturn, wasting about $2–3. It is bounded by shop stock, not an infinite loop.
  - **Fix:** use the `SLOT_WORTH` value as a tie-breaker in `buy_score`.
- **L-c: three small upgrade/runner safety gaps.**
  - `upgrade_reviewed_companion.py:98-99` takes the `before` snapshot before calling `no_game()`.
  - The rollback path catches only `Exception`. A Ctrl-C after the rename leaves the target absent and the archive intact, so recovery is the documented manual restore.
  - The runner's `copytree` of live Mods has no `no_game()` immediately before it. It is read-only and the hash comparison catches drift, so this is minor.
- **L-d: a deferred host stop still accepts new matches.** If starts keep arriving, the stop can be postponed indefinitely. This is operational only.

## Batch 3 dispositions

| ID | Disposition |
|---|---|
| **M1** | **Resolved.** `MIN_CARDS` is now set at the top of the decision (`baseline_policy.lua:2807`), before the rule-Joker and work-cap early returns. `play_score` drops short plays on every path. Tests cover all five rule Jokers, Stone and unusual centers, face-down cards in every position, unchanged choices when hidden ranks change, the work cap, determinism and a disabled Psychic. The new residual issue is M-A. |
| **M2** | **Resolved.** A held Tarot is sold only for a visible, affordable consumable that is strictly better (by `SLOT_WORTH`) and keeps the money reserve, and only the lowest-worth held Tarot goes. Real adapter frames show no extra purchase is certified at full slots, then sell → buy → retain. Each cycle strictly raises the held worth, so it cannot loop. The safety-floor sales and Negative purchases are unchanged. The residual issue is L-b. |
| **L1** | **Resolved, and the test is meaningful.** It matches the function signature with a regex and actually executes each rendered difficulty on every available runtime. Compaction stays on. |
| **L2** | **Resolved.** The 120 cap is unchanged. Ordinary certificates stop at 116; only reorders use the last 4, and they are added last (`engine_adapter.lua:1614-1642`, `2257-2261`). Trade-off beyond the spec: states with more than 116 ordinary certificates (e.g. 12 cards, 8 Jokers and 5 or more held consumables) lose their last Tarot certificates instead. Play and discard choices are unaffected. |
| **L3** | **Resolved.** The executor now enforces the allowlist, a face-up non-debuffed source, visible targets (face-up, not debuffed, not Stone, not masked, real rank and suit), base-card-only enhancements, an exact pair for Death and singletons otherwise, and no forced cards (`production_executor.lua:1511-1566`). It doesn't repeat the adapter's usefulness filters (a suit Tarot on a card already that suit, or Death on two identical cards). Those uses are legal in the engine and harmless. |
| **L4** | **Resolved, with the L-a caveat.** The service records the Tarot center from the cleaned observation, plus the exact positions. The executor writes allowlisted primitive fields (`code`, `action`, `count`, `detail`) through the real `src/logger.lua` filter. The detail string stays under 96 bytes. Forged, oversized, table and wrong-zone references are dropped. Logger failures are caught (`pcall`). |
| **L5** | **Resolved.** `HAND_TARGETS_DESIGN.md`, `LEGAL_ACTIONS.md`, `ENGINE_ADAPTER.md` and `BASELINE_POLICY.md` now match the code: the separate action type, ten centers, the stated counts and bounds, and the reorder reserve. Only the doc's "actual highlight state" logging wording is off (L-a). |

## By scope

1. **Psychic and churn:** see M1, M2 and M-A. Whenever there are five or more cards, a five-card play always exists: the padded plays come first, and five-card positional windows are always offered.
2. **Tarot fairness and execution:** sound.
   - The source and targets come only from the AI's own visible hand.
   - The engine's own `can_use_consumeable` check runs after the exact highlight is applied.
   - Refusals and no-ops clear the highlight (`production_executor.lua:1909-1933`, `2038-2046`).
   - The `STOP_USE` / `PLAY_TAROT` latch is respected.
   - Forged and stale actions are refused before any engine call.
   - Nothing reads the opponent, the deck order, the RNG or globals.
3. **Logging:** the fixed bridge from the bootstrap (`decision_logger`) to `core.lua` to `src/logger.lua` was verified. The regression test drives the real logger module, not just a recorder.
4. **Reorder reserve:** verified; see L2.
5. **H1 performance evidence:**
   - All nine hashed policy and adapter inputs match the current files.
   - 1,800 decisions per runtime, 0 failures; peak 1,262,000 instructions against the 2,000,000 budget.
   - Identical action digest on both runtimes.
   - The harness asserts its patch points and checks the real-budget runs and repeats.
   - The Park-Miller products stay below 2^53.
   - Rendered source is 54,740 bytes at most, under both the 57,344 guard and the 65,536 cap.
6. **Host shutdown:** correct.
   - The worker check and ticket removal happen in one locked step (`practice_host.py:3703-3711`).
   - `_op_start` re-checks under the same lock (`3968-3978`), so it never starts an orphaned run.
   - Unstarted workers count as unfinished.
   - A retained human window and pending closures are still honoured.
   - `force=True` still works.
   - The serve loop retries.
   - Nothing reopens processes by PID.
7. **Orchestration:**
   - The upgrade gates are well ordered: reviewed clean commit, package, acceptance, certificate, the pinned old package, a fresh backup, a hash-verified archive, a second backup, installer dry run then execute, and a check that everything outside the companion is unchanged.
   - Rollback restores only the verified archive into an absent target with no game running, and never touches saves.
   - The native runner's seven phases, fresh backups, private Mods copy (excluding only `AISparring`) and package binding before measurement are right, apart from M-B.

## Evidence check

- `summary.json` lists 60 suites, all with exit 0.
- Of the 306 hashed files, exactly seven differ from the suite run: `runtime_bootstrap.lua` (two comment lines only, confirmed by `git diff e0d5a70..HEAD`) plus six docs. One doc, `LOCAL_REGRESSION_VERIFICATION.md`, was added later.
- The Lua 5.1 bytecode-equality claim stands. LuaJIT dumps differ even between two compiles of identical source, so a difference there is not a behaviour change.
- The two helper hashes match `final-review-input-binding.json`.

## Readiness

- **Repository and integration source: accepted.** There are no Critical or High findings, and fairness, stale handling and compatibility are sound.
- **Before running native certification, M-B is required.** It changes only the helper, so a short re-review of the runner is enough.
- **I strongly recommend fixing M-A before packaging.** It is a small change, but if it's fixed later it changes companion bytes and forces another full seven-phase certification. If you defer it, record it as a known limitation and a watch item for live testing.
- **Scope of this acceptance:** it covers repository and integration source only. The seven-phase native certification, the final review of the exact certified package before install, fresh backups, the scoped upgrade and a real smoke test are all still separate required steps.

## Limitations that don't block anything

- **Death only ever rewrites the leftmost visible card.** Its pairs are listed in order and capped at 8 per Tarot, so every offered pair starts with the first visible card.
- **Single-card Tarots never target visible cards past the eighth** in 12-card hands.
- **Rookie still plays short hands under The Psychic.** That is by design.
- **H1 and the benchmarks are fixture measurements.** They don't predict in-game latency or AI strength.
