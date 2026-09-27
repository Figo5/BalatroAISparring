**Verdict: REQUEST_CHANGES.** The review is below as standalone text for Astra to save and route to DeepSeek.

---

# Claude review: Balatro AI Sparring Milestone 2 (adversarial source-level security and fairness)

**Reviewer:** Claude Code, `claude-opus-5-5`. Read-only; no delegation.
**Baseline:** M1 `8bcccabbce0693cf5a0e168babacfa511c2443e0`. Staged diff `work/toolchain/m2-review.diff`. The working tree has no unstaged changes, so the files read on disk match the diff.

**What I read in full:**
- Source: `AISparring/ai/{codec,observation,actions}.lua`, `AISparring/integration/{state_reader,action_broker}.lua`, `tools/policy_worker.py`, `tools/lua/policy_env.lua`.
- Test runners: `tests/run_boundary.py`, `tests/run_m2.py`.
- Tests: `tests/boundary/{support,test_policy_env}.lua`, the relevant parts of `test_broker.lua`, `tests/m2/{test_property,framework}.lua`, and targeted parts of `test_validation.lua`, `test_actions.lua`, `tests/reader/{support,test_visibility,test_positive}.lua`, and `tests/astra_attacks.py`.
- Docs: AGENTS, MILESTONE_2_PLAN, FAIRNESS, ASTRA_M2_VERIFICATION, DEEPSEEK_M2_ADVERSARIAL, M2_EXECUTION_BOUNDARY, STATE_READER, AI_OBSERVATION, LEGAL_ACTIONS, M2_SOURCE_MAP, and the relevant parts of INTEGRATION_PLAN.
- Evidence: all `astra-m2-*.txt` files.
- Multiplayer 0.5.5 source (read-only, workspace copy under `work/upstream-multiplayer-v0.5.5`) to check two claims.

**Not independently run.** This tool allowlist can't execute anything. Every "passes" statement below comes from Astra's evidence files, not from my own runs. Every defect below comes from reading the source, and each has a concrete reproduction for DeepSeek or Astra to run.

## 1. Verdict

**REQUEST_CHANGES for M2.** I found no Critical or High issue and no direct way for policy code to reach game globals, engine references, RNG, hidden identities or execution authority. The capability design holds:
- The policy only ever gets copies.
- Action identity is the full canonical encoding.
- Candidates are regenerated from the observation.
- The broker compares full canonical strings.
- The real executor is disabled.

However, three fairness-relevant Medium findings (M1–M3) leave defects in the boundary contract that the plan requires to be closed. Five further Medium findings (M4–M8) either make the acceptance evidence overstate what was tested, or leave real-game paths wrong while the tests mirror the bug. All fixes are small and none requires redesigning the architecture.

## 2. Confirmed good (checked against source)

- **Observation (`observation.lua`)**
  - It reads only allowlisted keys, using `rawget` and `next` on plain tables.
  - Tables with metatables are rejected via `getmetatable`. A `__metatable` field can't make one look metatable-free: `false` is not `nil`.
  - Visibility fails closed: an entity is redacted unless `face_down == false`.
  - Sections are dropped when the phase doesn't allow them, and MATCH_COMPLETE keeps only `schema_version`, `phase` and `match`.
  - Handles live in a weak-keyed private registry; `export` returns a deep copy.
- **Codec (`codec.lua`)**
  - The encoding is type-tagged and length-prefixed, so it is prefix-free and injective for typed schemas.
  - Map sorting uses a byte-wise comparator, and numbers are int32 only.
  - The FNV hash uses only exactly-representable arithmetic, so it agrees across runtimes, and it is used for diagnostics only.
- **Actions (`actions.lua`)**
  - An action's ID is `codec.encode(content)` (lines 645 and 780–786), not a hash.
  - `validate` enforces the exact key set, rejects metatables, checks the ID, then requires membership in freshly regenerated candidates.
- **Broker (`action_broker.lua`)**
  - Capture is atomic (handle and epoch together), and canonical strings are compared, never hashes (lines 284 and 327).
  - The validator gets its own copy, and the dispatch copy is preserved.
  - It recaptures after the validator runs and guards against re-entry.
  - The production path returns `broker_executor_disabled` (line 334).
- **Policy environment (`policy_env.lua`)**
  - Only a whitelist is exposed: no `pcall`, `error`, `setmetatable`, `getmetatable`, `load`, `debug`, `coroutine` or `collectgarbage`. The policy therefore cannot catch the budget error or defer execution through metamethods or `__gc`.
  - Bytecode is rejected in both the worker and the helper.
  - The selected action is re-validated against a re-observed handle.
  - The string metatable swap (F1) closes the `("x").dump` route.
- **Reader (`state_reader.lua`)**
  - Engine access is `rawget`-only.
  - Visibility requires the engine card's `facing` and `sprite_facing` to both be `"front"`.
  - Stone, `no_rank`, `no_suit` and `replace_base_card` cards have rank and suit masked using engine data.
  - The opponent timer uses only the rendered string; `real_score` and `last_timer` are never read.
  - Location requires `enemy_location_disabled == false`.
- **M1 scope:** M1 startup is untouched (`core.lua` and `src/*` are not in the diff), and `.gitignore` only adds `__pycache__/` and `*.pyc`.

## 3. Findings

### Medium, fairness-relevant (must resolve or justify strongly)

**M1. The deck aggregate can't represent what the UI actually shows, and the reader copies it through unchecked. That leaves a direct route to face-down card identity.**
- **Where:**
  - `state_reader.lua:427-472` (`copy_deck`) and `:633-639`
  - `observation.lua:348-408` and `:479-485`
  - `docs/AI_OBSERVATION.md:197-199`
  - The test `tests/reader/test_positive.lua:164-176` locks the copy-through in place.
- **Evidence:** The project's own `M2_SOURCE_MAP.md:201-202` records that the UI counts face-down (`wheel_flipped`) hand cards as `?` in the deck preview, so the UI does not reveal them. The schema has only `total`, `by_suit` and `by_rank`. It has no unknown bucket and no defined population. The reader copies producer-supplied maps with no gate and no check against engine data.
- **Repro:**
  1. Build a reader fixture in PLAY_HAND with hand card 1 engine-facing `back`, so it is correctly redacted.
  2. Set `view.self.deck = {total=44, by_rank={...counts of G.deck.cards...}}`.
  3. The capture succeeds and the export contains `by_rank`.
  4. Take the full-deck counts from a SHOP or BLIND_SELECTION observation, subtract the remaining counts and the cards already seen. What's left is the redacted card's rank.
- **Impact:** A producer that follows the documented schema literally (counting the remaining deck) leaks hidden face-down identity. Even an honest producer can't express the UI's `?` rule. This is a schema defect, not only a matter of trusting the producer.
- **Fix:** For M2, have the reader stop projecting `by_suit` and `by_rank` (keep `total`, which is the on-screen counter). Record rank/suit aggregates as unsupported until a certified deck-preview-equivalent spec exists, including an `unknown` count and the `wheel_flipped` rule. Add a negative test: face-down hand card plus deck maps in the view ⇒ no maps in the observation. Update the docs.

**M2. Opponent score masking relies on a view flag that isn't checked against the engine, and contradictory frames are accepted.**
- **Where:** `state_reader.lua:500-510` (`pvp_context` is read only from `view.recognition`), `:665-681`, and `:683-686`, where the view's `displayed_score` takes priority over the engine value.
- **Ground truth in Multiplayer:**
  - The mask applies when `hide_score_until_played and MP.is_pvp_boss() and hands_played == 0` (`work/upstream-multiplayer-v0.5.5/ui/game/blind_hud.lua:208-216`).
  - `is_pvp_boss()` is true when `G.GAME.blind.config.blind.key == "bl_mp_nemesis" or G.GAME.blind.pvp` (`objects/blinds/nemesis.lua:32-35`).
- **Repro:** phase `MULTIPLAYER_PVP`; `hide_score_until_played=true`; `hands_played=0`; `info_received=true`; `recognition={pvp_context=false}`; `opponent={certified=true, score_visible=true, displayed_score="1,234"}`. The observation contains `"1,234"`, while the HUD shows `???`. `test_visibility.lua:190-195` codifies this override, and no test covers the contradiction.
- **Impact:** A single unchecked producer boolean overrides the source-proven mask during a PvP boss blind: exactly the "watch the enemy score before committing" leak Multiplayer is designed to prevent. The reader even accepts a phase that says PvP alongside a flag that says not PvP.
- **Fix:** Derive the engine's PvP state with `rawget` on `G.GAME.blind` → `config` → `blind` → `key`, and on `G.GAME.blind.pvp`. Unmask only when the view says `false` and the engine proves the blind is not PvP; if the blind can't be read, mask. Always mask in phase `MULTIPLAYER_PVP`. Add the new reads to the STATE_READER §5 allowlist and add contradiction tests.

**M3. The broker's stale-state and ABA guarantee isn't implemented as documented: the token survives failed submits, and "epoch" has no defined revision meaning.**
- **Where:** `action_broker.lua:256-289`. The token is checked at 257–262, then a capture is taken (272). A stale or changed state returns at 277–286, *before* the token is consumed at 288–289. Epoch is only checked for not going backwards (192–197).
- **Doc and requirement claims:**
  - `M2_EXECUTION_BOUNDARY.md:78` says the token is "consumed single-use before any callback". False: `ports.capture` is a trusted callback and runs before consumption.
  - `M2_EXECUTION_BOUNDARY.md:91` claims ABA rejection.
  - `FAIRNESS.md:12` and the plan's item 5 require a monotonically advancing revision and ABA rejection.
- **Repro** (using `tests/boundary/support.lua` `rig({fixture=true})`):
  1. `t,p = issue()`, then `world.set_money(999)`.
  2. `submit(t, p.actions[1])` returns `broker_observation_changed`, but `has_pending()` is still true.
  3. `world.set_money(10)`, then `submit(t, p.actions[1])` returns `broker_ok` and `dispatch_calls == 1`. The epoch never changed, because the rig's `rebuild()` doesn't bump it.
- **Impact:** A state change and change-back (A→B→A) is accepted, and the token isn't strictly single-use. Without a defined revision, an intermediate state the broker never saw can't be detected.
- **Fix:**
  1. Clear the token immediately after the `rawequal` identity check, before any port call.
  2. Define `epoch` (reader, producer and `ports.capture` contract) as a trusted revision that strictly increases on every change to the captured AI state, and document it in STATE_READER and M2_EXECUTION_BOUNDARY.
  3. Add A→B→A and retry-after-failure tests.
  4. Correct the doc text.

### Medium: correctness and evidence (resolve this round; the evidence ones are required for acceptance)

**M4. The pack-state symbol names are wrong, and the tests mirror the mistake.**
- **Where:** `state_reader.lua:68-72` uses `TAROT`, `SPECTRAL`, `PLANET`, `STANDARD`, `BUFFOON`.
- **Evidence:** The project's own `M2_SOURCE_MAP.md:43` names `TAROT_PACK/PLANET_PACK/SPECTRAL_PACK/STANDARD_PACK/BUFFOON_PACK`. Multiplayer itself uses `G.STATES.TAROT_PACK` and `SPECTRAL_PACK` (`ui/main_menu/title_card.lua:8,11`). The fixtures at `tests/reader/support.lua:64-68,81` and the table at `STATE_READER.md:158` use the short names.
- **Impact:** In a real game, every BOOSTER_SELECTION capture fails with `reader_unsupported_state`. It fails closed, but the tests give false confidence.
- **Fix:** Use the `_PACK` names. Check whether the pinned Steamodded version replaces these with `SMODS_BOOSTER_OPENED`, and add it only if confirmed. Change the fixtures to the real names, and add a test that the short names are refused.

**M5. Shop booster packs aren't modelled.**
- **Where:** `state_reader.lua:89-96,102` (shop zone is bound to `G.shop_jokers` and must match its count exactly) and `:753-759`. `actions.lua:369-388` requires `kind=="booster"` inside `shop.items`.
- **Evidence:** Vanilla keeps packs in a separate area, `G.shop_booster` (verify in the pinned source).
- **Impact:** A faithful producer that lists packs in the shop view causes an `ENTITY_MISMATCH` on the whole SHOP capture. If it leaves packs out, OPEN_BOOSTER is never generated. If it mixes them in to make the count match, a pack record gets bound to a joker card by position, and the facing check runs on the wrong card.
- **Fix:** Add a `shop.boosters` zone bound to `G.shop_booster.cards`, with `shop_booster:N` refs. Point the OPEN_BOOSTER certificate zone and the generator at it. Add tests and update the docs.

**M6. Three tests pass without testing anything: dot-style functions called as methods.**
- **Where:** `tests/m2/test_property.lua:275` `pcall(obs.observe, obs, f)`, `test_validation.lua:91` `pcall(acts.validate, acts, h, probe)`, and `test_actions.lua:185,191` `pcall(acts.generate, acts, …)`. All these APIs are dot-style closures (`function instance.observe(frame)`).
- **Impact:**
  - `observe(obs)` always returns `observation_bad_version`, so all 200 malformed modes per runtime are never exercised. **400 of the 1,040 reported property iterations test nothing.**
  - The probe and foreign-handle generate cases pass whatever the implementation does.
- **Fix:** Call `obs.observe(f)`, `acts.validate(h, probe)`, `acts.generate(probe)` and `acts.generate(h)`, and assert the expected code for each mode. Correct the iteration counts in ASTRA_M2_VERIFICATION.

**M7. The property test has no independent model of legality.**
- **Where:** `test_property.lua:184-254`. Its `TYPE_PHASE` table (38–62) copies the implementation.
- **Impact:** The test randomises money, credit, slots, `capacity_ok`, hands and discards left, `max_play` and the target bounds, but only checks well-formedness, phase membership and that `validate` round-trips. A generator that ignored affordability, capacity or limits would still pass. The plan says property tests check legality.
- **Fix:** Write a reference predicate, written independently, that computes the expected candidate set for each certificate:
  - spendable ≥ cost, with cost ≤ 0 free except for vouchers;
  - capacity or a certified negative edition;
  - hands or discards left > 0, and the selection within `max_play`/`max_discard`;
  - target bounds and source binding.

  Assert the generated set equals the expected set.

**M8. The memory-limit test doesn't prove the 64 MiB cap.**
- **Where:** `run_boundary.py:381-383` doubles `s = s .. s` until failure and expects `policy_runtime_error`.
- **Impact:** Without any VM cap the test still passes, once the host allocator fails or Lua reports "string length overflow". So "the worker enforces 64 MiB" is unproven on either runtime; I couldn't confirm whether lupa honours `max_memory` under LuaJIT. My acceptance of F2 (section 4) depends on this.
- **Fix:** Use a discriminating pair:
  - Must fail: `local s=('x'):rep(65536); for i=1,11 do s=s..s end; return actions[1]` (about 128 MiB).
  - Must succeed: the same with 8 doublings (about 16 MiB).

  Run both on both runtimes.

### Low

- **L1. The `string.rep` wrapper can be bypassed on Lua 5.1** (`policy_env.lua:125-133`). The cap only applies when `#value > 0`. Lua 5.1's `str_rep` loops *n* times even for an empty string, so `for i=1,1000 do (''):rep(2147483647) end` burns unbounded C-level CPU time the instruction hook never sees. LuaJIT is likely unaffected. **Fix:** reject `count > STRING_CAP` regardless of length, and return `""` for an empty string. This contradicts the doc's claim that rep is bounded before it runs (M2_EXECUTION_BOUNDARY §2.5).
- **L2. The policy environment has sources of nondeterminism.** `tostring` (line 182) exposes table addresses, which vary with ASLR, and `pairs`/`next` order can vary. This contradicts the "no memory addresses" and "no RNG" intent and hurts reproducibility, though it doesn't leak game information. **Fix:** drop `tostring` or restrict it to primitives, and document that iteration order is unspecified.
- **L3. The empty-target USE_CONSUMABLE path skips the target context checks** (`actions.lua:481-487`). In CONSUMABLE_SELECTION, an empty-target use is emitted without checking `min_targets` or the `consumable_target.source_ref` binding. The plan requires limits to agree independently of certificates. **Fix:** in that phase, require `min == 0` and a matching source, or deny.
- **L4. Truncation to 128 actions is silent** (`actions.lua:657-663`), while the plan says overflow is reported explicitly. It can't happen today, because the certificate limit and `MAX_ACTIONS` are both 128. **Fix:** return an overflow flag, or assert the invariant and document it.
- **L5. A doc claim doesn't match the code.** `AI_OBSERVATION.md:294` says unknown certificate fields are *rejected*; `observation.lua:710-767` ignores them. **Fix:** change the doc (ignoring is the safer choice).
- **L6. Action error codes are a shared mutable table** (`actions.lua:7-17,733`). This is inconsistent with the private-constants policy followed in observation, the reader and the broker. It has no effect on authorization. **Fix:** copy them outward.
- **L7. A future path could accidentally enable real dispatch.** `ports.fixture == true` is the only thing enabling dispatch. **Fix:** require a distinctive sentinel (for example `"M2_FIXTURE_ONLY"`), and have `policy_env.lua` refuse to run if `love`, `G` or `SMODS` exist in its globals, as a tripwire for "never in the game VM".
- **L8. The in-process `PolicyEnv.run` doesn't limit source size.** Only the worker enforces its 64 KiB limit. **Fix:** add the limit to the helper too.

### Info

- **I1. Worker environment hardening.** The worker swallows failures when clearing the `python` global (`policy_worker.py:99-104`). lupa may also leave `package.loaded.python` in place. The policy can't reach either, but clear both and fail closed.
- **I2. F4 is only checked statically.** It's checked by a text match (`run_boundary.py:67`). The "recovers after a fault" tests only exercise faults already caught inside the broker, not the outer guard. The doc (§1.5) overstates this.
- **I3. The Astra G.deck probe is weak.** `raw_hidden_perturbation` installs an `__index` canary on `G.deck`, but `rawget` never triggers `__index`, so the probe can't detect a read. For zero-read proof, instrument `rawget` in the reader's test environment.
- **I4. Size limits can fail a whole observation.** The certificate limits (128 × 64 refs) can exceed the codec's 8,192-node limit, and one bad certificate fails the entire observation. Both fail closed, so this is only an availability issue.
- **I5. Error codes can differ between runtimes.** `for field, zone in next, spec` (`observation.lua:730`) can pick a different code for multi-field bad certificates on each runtime; output vectors are unaffected.
- **I6. Identity binding is producer-trusted.** Entity identity comes only from the view record, bound to the engine card by position, and target refs don't carry the engine ordinal (F9). This is producer trust as documented in STATE_READER §6, and must be revisited when the real mapper is built.

## 4. Decision: C-library calls not bounded by the Lua hook (F2)

**Acceptable for M2. It does not block acceptance of the fairness boundary,** on these grounds and conditions:

1. **Why it's acceptable:**
   - It only affects availability (CPU time and memory): no route to hidden information or illegal mutation depends on it.
   - Nothing in the repo runs the worker or helper except the test runners, which enforce a 10-second limit.
   - The helper isn't wired into mod startup.
   - The worker creates a fresh interpreter for each request.
2. **Conditions:**
   - Fix M8, so the 64 MiB claim is actually evidenced.
   - Fix L1 (a wrapper bypass).
   - Keep the launcher watchdog and process/memory isolation recorded as a hard gate before any non-test invocation.
3. **Recommended, not required:** a self-deadline inside the worker, for example a daemon `threading.Timer` that calls `os._exit` (verify that lupa releases the GIL while Lua is running). The known unbounded C paths are pattern-match backtracking (`find`/`match`/`gmatch`/`gsub`), `gsub` expansion and L1.

## 5. DeepSeek self-review findings: historical vs current

| # | At self-review | Now |
|---|---|---|
| F1 | Open: the string metatable exposed `string.dump` | **Fixed.** `policy_env.lua:333-350` swaps the metatable's lookup table to the whitelist and restores it. Covered by `test_policy_env.lua:141-153` and the worker's `('x').dump` escape check (`run_boundary.py:199,205-214`), which pass on both runtimes per the evidence. Remaining caveat: the metatable is global to the VM, so the helper must stay in its own VM (see L7). |
| F2 | Open | **Accepted as a scoped limitation** under the conditions in section 4. |
| F3 | Open: empty arrays came out as `{}` | **Fixed.** `policy_worker.py:184-189,252` normalises the three array fields, and `run_boundary.py:288-301` asserts `[]`. Other empty tables would still come out as `{}`, but none are emitted today. |
| F4 | Open: guard not exception-safe | **Fixed.** `action_broker.lua:209-222`. Only checked statically (I2). |
| F5 | Intended behaviour | The token is consumed only after the checks that can fail on stale state, so M3 requires consuming it earlier, which widens F5 slightly (still acceptable). |
| F6, F7, F8, F9, F11 | Producer trust or future work | Unchanged. M1 and M2 are the concrete cases where producer trust wasn't enough. |
| F10 | Documented | Unchanged. It becomes part of the epoch definition in M3. |
| F12 | Checked | Unchanged. |

## 6. Evidence reconciliation (not independently run)

| Suite | Unique cases | Executions |
|---|---|---|
| Pure (observation, codec, actions) | 93 | 182 |
| Reader | 53 | 106 |
| Boundary (final) | 94 | 168 |
| Astra attacks | 12 | 24 |
| **M2 total** | **252** | **480** |
| M1 regression | 66 | 117 |

- The M2 totals match the claimed 252 unique cases and 480 executions.
- The runners' counting logic (`run_boundary.py` and `run_m2.py` both use unique-name sets) matches the reported numbers.
- 1,040 property iterations is arithmetically correct, but **only 640 test anything** (M6).
- The earlier `astra-m2-boundary.txt` (96 unique / 138 executions) is superseded by the final run.
- `astra-m2-attacks-initial.txt` correctly shows the historical missing-visibility and negative-epoch failures that were later fixed.

## 7. Required for re-review

1. Fix M1–M3 and M6–M8, with regression tests.
2. Fix M4 and M5, or remove the supported-behaviour claims and record them as tracked gates.
3. Low findings at Astra's discretion; L1 is required by section 4.
4. Rerun and supply the updated evidence files, then a Claude re-review of the changed source.

No real-game integration is needed or requested.
