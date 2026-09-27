**Verdict: ACCEPT** for the scoped M2 infrastructure (inert, fixture-only information and action boundary). The full re-review is below for Astra to save.

---

# Claude re-review: Balatro AI Sparring Milestone 2 fixes

**Reviewer:** Claude Code, `claude-opus-5-5`, High. Read-only, no delegation. I executed no tests; every "passes" statement below comes from Astra's evidence files.

**What I read:**
- **Previous review and fix docs:** my earlier review (`docs/CLAUDE_M2_REVIEW.md`), `docs/CLAUDE_M2_RESOLUTION.md`, the final section of `ASTRA_M2_VERIFICATION.md`, and the revised `MILESTONE_2.md`.
- **The full fix diff** `work/toolchain/m2-fixes.diff`, covering source, tests and docs.
- **Current source:**
  - `action_broker.lua` in full.
  - `policy_env.lua` in full.
  - Changed regions of `state_reader.lua` and `actions.lua`.
- **Tests:** `test_property.lua` in full, plus `astra_mutation_checks.py`, `test_load_tripwire.lua`, the new attack probes and the relevant parts of `run_boundary.py`.
- **Pinned references:**
  - `work/reference/smods-booster.toml`
  - `work/reference/game/{game,cardarea}.lua`
  - `work/reference/mp/objects/blinds/nemesis.lua`
  - `work/reference/mp/ui/game/blind_hud.lua`
- **Evidence:** the `*-revised.txt` files, `astra-m2-mutations.txt` and `astra-m2-attacks-revised.txt`.

## 1. Verdict

**ACCEPT.** All eight Medium findings (M1–M8) are closed in the actual code, and each has a test that would fail if the fix were reverted. L1, L3–L8 and I1–I3 are closed. L2 is closed except for one leftover route on LuaJIT (N1 below); it's Low and doesn't block acceptance. I4–I6 are documented as scoped limitations, as agreed. I found no new Critical, High or fairness-relevant Medium issue and no regression.

## 2. Closure of Medium findings

| # | Status | Evidence in code and tests |
|---|---|---|
| **M1** deck aggregate leak | **Closed** | The reader's `copy_deck` now reads only `total` and never touches `by_suit`/`by_rank`. The schema side removed `read_count_map` and `LIMIT.deck_counts`; `read_deck` emits only `total`. Negative tests at both layers put a face-down card alongside deck maps and assert the maps are absent (`test_positive.lua` `deck_maps_cannot_leak_face_down_identity`, `test_observation.lua` `maps_dropped_with_face_down_hand`), plus the Astra probe `deck_aggregate_inference_denied`. |
| **M2** PvP score masking | **Closed** | New `engine_pvp_boss` in `state_reader.lua:493-514` uses `rawget` only and matches Multiplayer's `is_pvp_boss` in `nemesis.lua:32-35`. Any Lua-truthy `blind.pvp` counts as PvP, and the value is never called or traversed. The phase `MULTIPLAYER_PVP` always masks (`:680-682`). Unmasking needs both the view flag `false` **and** engine proof of a non-PvP blind (`:684-691`), and an unknown blind masks. The reader is slightly stricter than Multiplayer when `config.blind` is missing, which errs on the safe side. Tests cover the unknown, non-PvP, nemesis, `pvp=true`, PvP-phase, `pvp=0`/`""`/table/function (with a never-called check), empty/number/missing key and unknown-config cases. Both Astra probes use a fixture with `hide_score=true`, `hands_played=0` and `info_received=true`, so they would fail against the old code. |
| **M3** token reuse and A→B→A | **Closed** | `action_broker.lua:260-265` checks token identity with `rawequal`, then clears the token before any structural check or port callback. The token checks themselves call no user code. The revision contract is defined in `STATE_READER.md` §3.1 and `M2_EXECUTION_BOUNDARY.md` §1.4: the epoch must strictly increase on every change, including A→B→A. The limit (a dishonest producer can't be detected) is stated as trusted-code-base (TCB) trust. Tests cover a retry after a failed submit (`broker_token_unknown`), an unseen A→B→A with an honest revision, and a constant revision with changed content. The test rig's `rebuild()` now advances the epoch. Astra's `failed_submit_consumes_token_before_aba` proves the token is consumed without relying on the epoch. |
| **M4** booster state names | **Closed** | `state_reader.lua` now lists the five `*_PACK` names plus `SMODS_BOOSTER_OPENED`, resolved by name. I confirmed these in the pinned sources: vanilla `game.lua:2581-2597`, and `smods-booster.toml:101` (declared) and `:36` (assigned to `G.STATE`). Tests cover all six real states, a non-default value (77) and refusal of the old short names. `work/` is gitignored. |
| **M5** shop booster packs | **Closed** | Packs now have their own `shop_boosters` area, bound to `G.shop_booster.cards`, which is the real separate area (`game.lua:3138-3157`, `mp/lib/card_utils.lua:69`). The rest of the path matches:<br>• The observation adds `shop.boosters` in the `shop_booster` zone and rejects `kind=="booster"` inside `shop.items`.<br>• The `OPEN_BOOSTER` certificate zone is `shop_booster`, and `build_open_booster` reads only `shop.boosters`.<br>• The `BUY_ITEM` and `OPEN_BOOSTER` zones are not interchangeable (`test_actions_shop.lua`).<br>• The reader has its own facing check per pack (`shop_boosters_distinct_zone_and_facing`). |
| **M6** tests that tested nothing | **Closed** | The functions are now called the right way, and each call checks the expected return code. The malformed-frame loop checks the exact code for each mode and includes a positive control. Count: 320 randomised frames + 200 malformed frames = 520 per runtime, 1,040 total, all doing real work. |
| **M7** independent legality check | **Closed** | `test_property.lua:126-573` is a separately written check that computes the expected action set (resources, credit, free-vs-voucher, capacity with the negative-edition rule, hands/discards, max limits, target bounds, source binding, permutations) and requires an exact match with the generated set. Coverage flags prove that both the allow and deny branches run. `astra_mutation_checks.py` swaps in broken copies of `actions.lua` in memory. The three broken checks (affordability at `:363`, joker capacity at `:367`, hands at `:312`) are the first occurrences, inside BUY_ITEM and PLAY_CARDS. The harness is safe: a mutant that failed to load, or the unchanged code passing, would both be reported as FAIL. All 3/6 caught. |
| **M8** 64 MiB memory cap | **Closed** | `run_boundary.py` has a pair of worker tests: building a 16 MiB string must succeed with a valid action, and building a 128 MiB string must fail with exactly `policy_runtime_error` (`expect_memory_failure` accepts no other code). A time-budget or size-limit failure would give a different code, and 128 MiB would succeed with no VM cap. Both pass on both runtimes (boundary-revised, lines 182-185). |

## 3. Low and Info items

**Low findings:**
- **L1 (closed):** `bounded_rep` rejects a count over 65,536 even for an empty string, returns `""` early, and requires a finite whole number. Tested through both the direct and the method route.
- **L2 (mostly closed):** `tostring` now accepts primitives only, and iteration order is documented as unspecified. One route remains (see N1).
- **L3 (closed):** empty-target use requires the bound source and a minimum of 0 targets. It is also in the independent check.
- **L4 (closed):** generation returns `actions_too_many` instead of silently truncating, and validation passes the error through. A test pins 128 at the cap.
- **L5 (closed):** doc fixed.
- **L6 (closed):** error-code tables are private, and callers get copies.
- **L7 (closed):** dispatch requires the `"M2_FIXTURE_ONLY"` string; a boolean `true` stays in production mode, and a test checks this. The game-VM tripwire runs before configure, before run, and before the module-load `jit.off`. `test_load_tripwire.lua` runs in a fresh runtime per file, so the JIT, string-metatable and hook checks would catch a change. Astra's `jit.off` spy probe would too.
- **L8 (closed):** the helper enforces the 64 KiB source cap itself.

**Info items:**
- **I1 (closed):** `_harden_runtime` clears `python`, `python_builtins` and `package.loaded.python`, and fails closed with `policy_env_hardening_failed` if that goes wrong.
- **I2 (closed):** the escaping-fault test triggers an `__index` error when `ports.capture` is read. That read happens outside the inner `pcall`, so the outer guard really is exercised, and the broker recovers.
- **I3 (closed):** the reader never caches `rawget` as a local (confirmed by grep), so the replacement global spy sees every reader read. A positive control proves the spy detects a forbidden read, and a SHOP capture with all the poison fields reads none of them.
- **I4–I6:** documented as accepted fail-closed or producer-trust limitations. No change needed.

**Astra's two extra fixes:** the `pvp=0` truthiness fix is correct, per M2 above. The module-load `jit.off` now runs only after the engine-VM check, and I confirmed that in `policy_env.lua:447`.

## 4. New findings

**N1. The address leak isn't fully closed on LuaJIT. Severity: Low. Doesn't block M2.**
- **Where:**
  - `tools/lua/policy_env.lua:176-182`: `bounded_format` passes any argument straight to `string.format`.
  - `:216`: this wrapper is exposed as `string.format`, both directly and through the string metatable.
  - `docs/M2_EXECUTION_BOUNDARY.md:202` claims that table and function addresses "are never produced".
- **Repro:** a worker on `luajit21` runs `return function(o, a) if string.format('%s', {}) ~= '' then return a[1] end end`. LuaJIT's `%s` converts any value like `tostring` does, so this returns `"table: 0x…"` and an action. `('%s'):format(function() end)` behaves the same. On Lua 5.1 it raises an error, as intended.
- **Impact:** the policy can see memory addresses, which vary between runs. That breaks reproducibility, and the doc claim is false. There is no route to game information: the tables are fresh copies inside a separate VM.
- **Required fix:** in `bounded_format`, reject any argument that isn't a string or number (check with `select('#', ...)` and `select(i, ...)`). Add a worker test: `string.format('%s', {})` must give `policy_runtime_error` on both runtimes. If the fix is deferred, narrow the doc sentence instead. Do this before any M3 policy code runs; Astra decides when.

**N2. One assertion in an Astra probe proves nothing. Severity: Info.**
- **Where:** `tests/astra_attacks.py:41`.
- **Detail:** `helper.configure('','','')==false` would be false even without the tripwire, because empty sources fail to load.
- **Why it doesn't matter:** the `mutations==0` spy in the same probe does prove the fix, and `test_load_tripwire.lua` checks the refusal with real module sources.
- **Optional fix:** pass the real sources in the probe.

## 5. Evidence reconciliation (not independently run)

| Suite | Unique cases | Executions | How the total is made up |
|---|---:|---:|---|
| Pure | 96 | 188 | 92 per runtime × 2 + 4 static |
| Reader | 61 | 122 | 61 per runtime × 2 |
| Broker/worker | 115 | 204 | 22 static + 58 Lua cases × 2 runtimes + 66 worker runs; 35 logical worker cases |
| Astra attacks | 18 | 36 | 18 per runtime × 2 |
| Mutation checks | 3 | 6 | 3 per runtime × 2 |
| **M2 total** | **293** | **556** | |
| With the unchanged M1 suite (66 / 117) | **359** | **673** | |

- There are 1,040 property iterations, all of which test something.
- None of the revised logs contains a FAIL line.
- The benchmark figures in `MILESTONE_2.md` match `astra-m2-benchmark-revised.txt`.

## 6. Scope and integration gates

- **Critical / High:** none, before or after the fixes.
- **Fairness-relevant Medium (M1, M2, M3):** all closed.
- **Evidence and correctness Medium (M4–M8):** all closed.
- **Unbounded C-call wall time (F2):** the condition matches what I accepted last time. The helper runs only in a private fresh VM, and test callers enforce an external 10-second limit. The launcher watchdog and process isolation stay a hard gate before any non-test use. There is no autonomous policy and no live code path. The M8 and L1 conditions I set are now met.

The remaining integration gates don't block accepting M2 as infrastructure, because nothing is wired in and every gate fails closed:
- real UI-view and certificate production;
- authenticated role and epoch provenance, including an honest revision source;
- mapping targets to the engine, and a real executor;
- the staged launcher, watchdog and isolation;
- a real Steamodded load and capture smoke test.

They must be closed before M2 is described as live-capable or before any policy runs outside tests.

**No code edits were made by me. No tests were run. No live Balatro, Mods or save files were touched.**

---

# Targeted final confirmation after N1/N2 hardening

# Claude Opus 5.5 High: targeted M2 confirmation for N1 and N2

**Verdict: ACCEPT.** N1 and N2 are both closed in the actual code. The earlier M2 acceptance in `docs/CLAUDE_M2_REREVIEW.md` still stands.

**Scope and limits:** I only read the code, as instructed. I read the new formatter (`tools/lua/policy_env.lua:176-234`), how it's wired in (`:264-268`, `:444-460`), `STRING_FUNCS` (`:35-38`), `PolicyEnv.configure` (`:360-386`), `tests/boundary/test_policy_env.lua:220-237`, the `worker_format*` cases and static check in `tests/run_boundary.py`, and `tests/astra_attacks.py:41`. I ran nothing and delegated nothing. The pass counts you gave (123/219, 18/36 and the unchanged earlier suites) are Astra's evidence. I didn't reproduce them. I didn't look at anything else.

## N1: the formatter could leak memory addresses on LuaJIT. Closed.

**Code checks:**
- **Format string must be a string.** `bounded_format` rejects anything else (`:218`), including numbers. That's stricter than stock Lua, which is fine.
- **Every argument must be a string or a number.** The check uses `select("#", ...)` and `select(i, ...)` (`:222-228`), so trailing nils and extra arguments are checked too. Tables, functions, userdata, booleans and nil are all rejected. That closes the `%s` → `tostring` → address route on LuaJIT.
- **Only allowed conversions get through.** `validate_format` walks each `%` spec and skips flags, width and precision before checking the conversion letter. `%%` is handled as a literal. A trailing `%` is rejected.
  - The allowed letters are `d i o u x X e E f g G c q s`. `%p` isn't among them, so `%p` and `%5p` are rejected before the native call.
  - `%a` and `%A` are also excluded. They'd be deterministic, but leaving them out errs on the safe side.
- **Direct call and method call use the same wrapper.** `strlib.format = bounded_format` (`:268`), and `string_meta.__index = strlib` for the duration of the call, restored afterwards (`:444-460`). So `string.format` and `('…'):format` both go through the guard.
  - `format` in `STRING_FUNCS` is overwritten by the wrapper.
  - `dump` isn't exposed, and the policy has no way to reach `getmetatable`.

**Tests:**
- **Lua test `policy_env_format_guard`** covers:
  - table argument, direct call
  - function argument, method call
  - `%p` direct and method
  - `%5p`
  - a positive control: `%d/%s/%.2f` gives `7/x/1.50`, `%%` gives `%`, and `('%d'):format(7)` gives `7`
- **Worker tests** mirror all six cases. None of them is `run_once`, so each runs on both lua51 and luajit21 (`run_boundary.py:607`). They expect `policy_runtime_error`, and the positive control expects `PLAY_CARDS`, which proves ordinary formatting still works.
- **Static check `helper_format_guard`** fails if the allowlist or the argument check is removed.

## N2: one Astra probe assertion proved nothing. Closed.

`astra_attacks.py:41` now reads the real `codec.lua`, `observation.lua` and `actions.lua` from disk and passes them to `helper.configure`, which must return `false`.

The fake environment sets `e._G = e` with `G={}`, so `engine_vm_present()` sees `G` and returns `false` at `:361-362`, before any source is loaded. With real sources, the only way to get `false` there is the tripwire, so the assertion now actually tests something. The `mutations==0` spy on `jit.off` is still there.

There's still no positive control inside this probe (for example, "same sources with `G=nil` → `true`"). The other suites already cover that: the worker cases configure the same real sources and return `PLAY_CARDS`, and `test_load_tripwire.lua` does too. So this doesn't block anything.

## Non-blocking observations (Info, don't affect the verdict)

1. **`*` is accepted as a flag.** `validate_format` lets `*` through as a flag or width character (`:198`). Stock `string.format` then errors natively, and the policy gets `policy_runtime_error`, so the outcome is safe. It's just slightly less strict than the "conservative allowlist" description suggests. Rejecting `*` explicitly would tidy it.
2. **The size cap is checked after formatting, not before.** The `STRING_CAP` check runs on the result (`:230`). A policy could combine a long `%s…` format with `unpack` of many copies of a string up to the cap, and allocate a large amount of memory before the check rejects it. It's confined to the separate worker VM and doesn't expose any information, and the post-check predates this fix. If you want to harden it in M3, add up the argument lengths plus a width/precision allowance before calling the native `string.format`, the same way `bounded_concat` does.

## Conclusion

N1 (Low) and N2 (Info) are closed. I found no new Critical, High or Medium issue in the changed code. The M2 **ACCEPT** in `docs/CLAUDE_M2_REREVIEW.md` stands, assuming Astra's reported results are accurate and there have been no other source changes since that acceptance.
