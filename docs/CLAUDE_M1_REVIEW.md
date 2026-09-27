I've finished reading everything and am writing up the review now. I only read files; I didn't run any commands, tests or the game.

# Milestone 1 review: AISparring companion scaffold

**Verdict: accept the repository scaffold once the required documentation fixes below are made. The in-game smoke test stays pending.** I found no critical or high findings.

I reviewed the actual staged diff (`m1-review.diff`, base d09b910) and the working-tree files, whose line numbers match it. I checked them against the reference copies of the Steamodded loader and the Multiplayer core, manifest and matchmaking files.

## Findings

### Medium (required fixes, all documentation)

**M1. The developer guide describes publication failures wrongly.**
- **Where:** `docs/DEVELOPER.md:91`, `docs/DEVELOPER.md:113`, compared with `AISparring/core.lua:61-81, 176-181`.
- **Problem:** The guide says a read-only mod entry, or an unavailable or unrelated `current_mod`, produces a closed status. In the code, `publish()` just skips attaching the status API and returns the bootstrap result unchanged, which is usually `scaffold_ready`. The tests confirm this: `test_entrypoint.lua:71` and `:152` both assert `scaffold_ready`.
- **Why it's only a docs issue:** The loader throws away the entrypoint's return value (`smods-loader.lua:783`). So when nothing is published, no caller can see any status, and the actual behaviour is safe.
- **Fix:** Rewrite both lines to say: "If identity can't be verified or attaching fails, no API is attached and nothing escapes. The entrypoint's return value is unchanged and only visible to test harnesses."

**M2. The documentation never mentions how installing the companion affects Multiplayer's mod list and hash, and it only rules out live installs "at this stage".**
- **Where:** `README.md:21`, `docs/DEVELOPER.md` (no mention at all), `docs/MILESTONE_1_PLAN.md:13`.
- **Evidence:** Multiplayer's `get_mod_data` (`multiplayer-matchmaking.lua:14-23`) adds every enabled `SMODS.Mods` entry to its mod string, so `AISparring-0.1.0` would be included. That string is then hashed at `:33-35` and followed by `set_username` at `:36-37`. There is no exemption for passive mods.
- **Problem:** "Normal single-player and human Multiplayer remain unchanged" is only true because the companion is never installed into the normal installation.
- **Fix:**
  - Add a short "Install target" section to `DEVELOPER.md`: the companion is only ever installed into staged runtimes, never the user's normal install. Enabling it anywhere changes Multiplayer's reported mod list and hash. It must not be hidden, and Multiplayer's checks must not be patched.
  - Change README's "at this stage" wording to the same staging-only rule.
  - Add a qualifier to Milestone 1 plan item 3 saying the claim holds under the staging-only topology.

**M3. Several stale or inaccurate statements in the developer guide.** Fix all of these alongside M1:
- **`docs/DEVELOPER.md:145`:** It says config loading "was not verified against an installed source copy". Astra did verify this in `ui.lua:1656`. Reword it as "checked against the source; a real-engine test is still pending".
- **`docs/DEVELOPER.md:90`:** "cyclic structures are dropped" is wrong. `copy_primitives` stops at a depth limit (`core.lua:30`); it doesn't detect cycles. Say "copying stops at depth 6".
- **`docs/DEVELOPER.md:64`:** "a non-negated host" doesn't mean anything. Remove it or rewrite it.
- **`docs/DEVELOPER.md:7` and `README.md:5`:** "loads as a Steamodded mod" / "is a real Steamodded mod that loads" states something that hasn't been shown yet. Use "is built to load as…; loading in a real game is unproven".

### Low (optional)

- **L1. The same facts are hard-coded in several places.** `status.lua:44-48` and `:55` hard-code the dependency pin, the priority, `skips_load_when_dependency_unmet` and `"0.5.5"`. `dependency.lua:6` has a `priority_after` value that nothing uses. Either take these values from `Dependency.SPEC`, or add a static check in `run.py` that they match `AISparring.json`.
- **L2. The returned result shares a table with the stored status.** `core.lua:62` stores the same table that is later returned at `:181`, so a caller changing the returned table changes what `get_status()` reports. Only tests can see the return value, but storing a copy (`last_status = copy_primitives(status)`) would remove the issue.
- **L3. Side-effect tests don't check other mod-registry tables.** Only writes to `MP` and `G` are guarded; nothing catches writes to `SMODS`, `SMODS.Mods` or other mod entries (`fixture.lua:121`). Add a sentinel third mod, then assert that the key sets of `SMODS` and `SMODS.Mods` are unchanged and that the own entry only gains `aisparring`. By reading the code, I confirmed no such writes happen today, so this is a regression guard only.
- **L4. The forbidden-API scan is a plain substring match** (`run.py:32`). It misses things like `NFS.`, `require`, `load`/`loadstring`/`dofile`, `debug.`, `setfenv`/`rawset`, and access like `io["open"]`. Consider extending the list.
- **L5. The "logs stay within safe fields" test only looks for the word "seed"** (`test_entrypoint.lua:53`). A stronger test would check each whole log line against a pattern of allowed field names.
- **L6. The harness passes even if one Lua runtime is skipped** (`run.py:183-185`). Consider adding a `--require-all` flag, or printing a warning when a runtime is skipped.
- **L7 (information only).** Multiplayer's core returns early when it's installed incorrectly (`multiplayer-core.lua:287-306`). In that case the structural check still passes, so the scaffold reports `scaffold_ready` over a partly loaded Multiplayer. This has no effect while the scaffold is inert.

## Architecture, fairness and compatibility

- **Steamodded scaffold:** Correct.
  - The manifest fields match the loader's JSON rules (`smods-loader.lua:135-223`).
  - The `==` pin is enforced before any code runs (`:602-635`). A failed pin, a disabled dependency or an unloadable dependency sets `can_load=false`, and `core.lua` is never run (`:771`).
  - Priority 10000001 sorts after Multiplayer's 10000000 (`:735-746`).
  - `SMODS.load_file(path, id)` is called the way the loader expects (`:873-895`), and its failures are caught.
  - `MP == SMODS.Mods.Multiplayer` is the right identity check, because Multiplayer's core sets `MP = SMODS.current_mod`.
  - The checked structure (`LOBBY`, `GAME`, `ACTIONS`, `MOD_ACTIONS`, `register_mod_action`, `current_ruleset`) exists by the time this mod loads.
- **Fail-closed checks and the AI flag:** Correct and ordered sensibly. Version values are reduced to safe tokens before they reach status or logs. `ai_mode.resolve` always sets `enabled=false`, so setting the flag to `true` stays inert.
- **Interference with normal games:** None in the code. There are no hooks, content registration, Multiplayer method calls, network access, global writes, or writes to other mods. The only write is `aisparring` on the mod's own verified entry.
- **Module boundaries:** Clean.
  - `status`, `logger`, `dependency` and `ai_mode` are pure.
  - `host` is the only adapter reading Steamodded and Multiplayer.
  - `core` wires them together.
- **Future observation boundary:** Not weakened. `host` checks the types of `LOBBY.connected` and `LOBBY.code` but never copies them. The status contains only constants and tokens, with no game, lobby or RNG data. The docs don't pretend a sandbox exists.
- **Staging-only scope and the mod hash:** Yes, staging-only covers this with no architecture change.
  - The user's normal install never contains the companion, so its Multiplayer metadata doesn't change.
  - Inside the staged pair, the P5 identity-parity gate requires both clients to carry the same companion version.
  - One tension to record, not an M1 blocker: `INTEGRATION_PLAN.md:13` allows a possible future "installed AI Sparring menu". That would put the companion into the normal install and visibly change the mod list and hash sent from that install. That option should get its own review when proposed, with the effect disclosed rather than hidden. Consider adding a one-line note there now.

## Limits of the test evidence

- **What I checked:** I did not run the tests. Astra's transcript is internally consistent with how `run.py` counts:
  - Lua test names carry no runtime prefix, so there are 45 unique Lua names plus 11 static checks, giving 56 unique cases.
  - Executions are 11 + 2×45 = 101.
- **Synthetic loader:** The test fixture (the synthetic stand-in for the game) doesn't reproduce the real loader. It doesn't perform real dependency resolution, `NFS` path handling, or the real `load_file` behaviour of throwing when a mod ID is missing.
- **Standard library not guarded:** The test environment falls back to the real Lua standard library, so the "no side effects" coverage is limited to what the fixture guards.
- **Unproven by fixtures:** The Steamodded "skip on unmet dependency" behaviour is established only by reading the source. Loading in the real game, Love2D's LuaJIT build, config persistence, the mod-hash effect, and isolation are all unproven by these tests, as the docs mostly already say.

## Summary for the fix round

The required fixes are all documentation: M1, M2 and the M3 wording corrections. L1–L7 are optional. After these fixes, the milestone is acceptable as an inert repository scaffold, with the real-game smoke test and every prototype gate still pending.
