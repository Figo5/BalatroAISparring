I accept the Milestone 1 repository scaffold. No critical, high or medium findings remain. The real-game load and isolation smoke test is still pending, as are all prototype gates.

This is a read-only review. I did not run commands, tests or the game. I checked the fix diff line by line against the working files. I also checked `core.lua:287-306` and `:36-37` in `work/reference/multiplayer-core.lua`, and `:500-506` in `work/reference/smods-loader.lua`. `work/` is gitignored, so those reference copies are not committed. The test transcript adds up: 15 static checks plus 51 Lua cases gives 66 unique cases, and 15 + 2×51 gives 117 runs. The 51 Lua cases are the original 45 plus 6 new ones, and both runtimes ran.

## Remaining findings

**Low**
- **`docs/ASTRA_M1_VERIFICATION.md:3`:** it says final acceptance is recorded in `MILESTONE_1.md`, but that file doesn't exist yet. Create it in the acceptance commit, or reword the line until then.
- **`src/status.lua:54` (trivial):** `id = "Multiplayer"` in the dependency record isn't drift-checked by itself. The pin string it sits beside is checked, so this is cosmetic.

## How the fixes were handled

| Finding | Result |
|---|---|
| **M1** publication wording | **Fixed.** `DEVELOPER.md` now says that when identity can't be verified or attaching fails, no API is attached and the return value is unchanged. It also says Steamodded discards that return value. This matches `core.lua:61-81`. |
| **M2** staging-only rule and mod hash | **Fixed.** `DEVELOPER.md` has a new "Install target (staging only)" section. README uses the same staging-only wording, and item 3 of `MILESTONE_1_PLAN.md` has the qualifier. The docs say the hash effect must be disclosed, never hidden or patched. The future installed menu is flagged as needing its own review and is not authorised. `INTEGRATION_PLAN.md` itself is unchanged, which is correct. |
| **M3** stale wording | **Fixed.** Config loading is now described as checked against the source, with the real-engine test pending. The docs say copying stops at depth 6. "Non-negated host" is gone. "Built to load; loading in a real game is unproven" is used in both places. None of the old phrases remain. |
| **L1** facts hard-coded in several places | **Fixed.** The unused `priority_after` is removed. Four new static checks compare the manifest with `Dependency.SPEC` and with the `status.lua` pin, version and priority. |
| **L2** returned result shares a table with the stored status | **Fixed.** `core.lua:62` now stores `copy_primitives(status)`, a deep copy. The copy runs outside the `pcall` but can't throw: the status is always an internal table, Lua 5.1 `pairs` ignores metamethods, and depth is capped. `test_entrypoint.lua:170` changes nested fields on the returned result and confirms `get_status()` is unaffected. |
| **L3** registry writes not guarded | **Fixed, with shallow checks.** There is now a sentinel third mod (`fixture.lua:126-127`). The test at `test_entrypoint.lua:219` runs with the AI flag both off and on. It checks that the key sets of `SMODS`, `SMODS.Mods` and the third mod are unchanged. It checks that the Multiplayer and third-mod tables are still the same objects, and that the mod's own entry gains exactly `aisparring`. |
| **L4** forbidden-API scan | **Extended.** It now also catches `io[`, `NFS.`, `require(`, `dofile`, `loadstring`, `debug.`, `setfenv(` and `rawset(`. It is still a substring heuristic, and the docs say so. |
| **L5** log field check | **Fixed.** Every `key=` in every log line on the ready path is now checked against an allowed list (`test_entrypoint.lua:59`). |
| **L6** skipped runtime still passes | **Fixed.** `--require-all` makes a missing runtime a failure. The docs describe it, and Astra's final run used it. |
| **L7** partly loaded Multiplayer | **Fixed correctly** (`host.lua:73-79`). The companion now requires `entry.lovely == true`. The loader sets that marker (`smods-loader.lua:504`), and Multiplayer's own early return checks the same field (`core.lua:287`). It also requires `ACTIONS.connect` to be a function. `ACTIONS` is created before the early return (`core.lua:36`), but `connect` is only defined after it, when `action_handlers.lua` loads at `:317`. So each check alone catches the early-return path. Both are type checks only: `connect` is never called. The fixture's `connect` raises an error and records the call if invoked, and the ready-path test asserts no forbidden calls were recorded. Both conditions are tested at the host level and end to end (`test_host`, `test_dependency`). No transport readiness is claimed. |

## Architecture, fairness and compatibility

- **Architecture unchanged.** The module boundaries are the same, and `host.lua` is still the only code that reads Steamodded or Multiplayer. There are still no hooks, content registration, method calls, network access or global writes. The only write is `aisparring` on the mod's own verified entry.
- **Fairness and observation boundary:** not weakened. The two new checks read types only, never values or game state. The status still holds only constants and safe tokens.
- **Compatibility:**
  - A correctly installed Multiplayer is loaded through Lovely, so it has `lovely = true` and a defined `connect`. The new checks therefore don't reject any valid setup.
  - If a future Steamodded version drops the marker, the companion fails closed, which is acceptable under the exact version pin.
  - The staging-only rule avoids the mod-hash effect in the user's normal install. Staged pairs still depend on the P5 identity-parity gate.

## Test limits (optional, not blockers)

- The registry checks compare key sets only. They wouldn't catch a changed value on an existing key, such as `own.config`. They also run only on the ready path, not on fail-closed paths.
- The log allowlist covers only the ready path.
- The source scan is still a heuristic. It misses things like `load(`, `getfenv`, `_G[` and names built from strings.
- The host is synthetic. Real loader resolution, `NFS`, LuaJIT inside Love2D, config persistence, the real mod-hash effect and staged isolation are all unproven until the real-game smoke test.

I found nothing that asks for Milestone 2 behaviour from the inert scaffold, and I'm not requesting any.
