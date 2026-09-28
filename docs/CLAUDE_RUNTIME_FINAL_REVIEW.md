Review captured 2026-09-28. Invocation: `claude-opus-5-5 --effort high`; read-only. Reviewed HEAD `bbf61bf43f1a8be93ac71cc9ca7c0b96a670be8f`.

## Verdict: **Blocked** for controlled staged testing

I reviewed the diff at HEAD `bbf61bf`. Two code defects mean a staged match can't start, and even after they're fixed the AI would never make a move. Both repairs are small. Everything else below can be fixed alongside them, or is honestly waiting on real-game checks. Everything was read-only: no edits, commands, subagents or network.

### Critical: must fix before staged testing

**C1. The AI decision loop never runs in the real game.**
- **Where:** `AISparring/integration/mp_driver.lua:288-308`, gated at `runtime_bootstrap.lua:1445-1452`.
- **Problem:** `match_started()` looks for a match-started signal in three places. The AI can only rely on `MP.is_started` or `MP.LOBBY.started`, and neither exists anywhere in the pinned Multiplayer source. The only thing that sets `started = true` is `host_start_game`, which is human-only. So on the AI side `match_running` is always false.
- **Why tests pass:** the fixtures invent the flag (`tests/runtime/support.lua:133,160`; `tests/test_runtime_cross_service.py:398,454-458`).
- **Minimal repair:** treat the match as started, and keep it started, once `MP.LOBBY.code ~= nil` and `G.STAGE == G.STAGES.RUN`. In a staged lobby, the only way to reach the RUN stage is the ordinary Multiplayer start (`action_start_game` → `lobby_start_run`). Change the fixtures to drive `G.STAGE` and delete `LOBBY.started`.

**C2. Major League options are never forced, the human never sends READY, and `createLobby` repeats.**
- **Where:** `mp_driver.lua:523`.
- **Problem:** the wrapper reads `rget(resolved, "force_lobby_options")`, which is a `rawget`. The real `MP.current_ruleset()` returns an empty proxy table that answers every field through its metatable (`work/reference/mp/rulesets/_rulesets.lua:151-161`), so the raw read is always nil. The consequences in the real game:
  - The wrapper returns `false`, so the lobby is created with un-forced default options.
  - `forced_keys` stays nil, so `host_start` returns `BAD_STATE`.
  - `runtime_bootstrap.lua:1113-1115` then re-arms, so `start_lobby`, and with it a new `createLobby`, fires again every 0.5 s until a lobby code arrives.
  - `compute_digest` returns nil for the human, so READY is never sent and coordination stalls.
- **Why tests pass:** the fixture hands back a plain ruleset table (`tests/runtime/support.lua:78-80`).
- **Minimal repair:**
  1. Read the field with protected normal indexing: `pcall(function() return resolved.force_lobby_options end)`.
  2. Once the real `start_lobby` has actually been called, treat any failure as `coord_failure` instead of re-arming. Pre-call refusals (such as `NO_RULESET`) can stay retryable.
  3. Make the fixture's `current_ruleset` return a metatable proxy like the real one.

### High

**H1. The live menu never installs.**
- **Where:** `AISparring/ui/practice_menu.lua:31-34`.
- **Problem:** the factory requires `G` to be a plain table with no metatable. The real `G` is created by `G = Game()` (`globals.lua:522`) through `Object:__call`, which gives it a metatable (`engine/object.lua:34`). So the factory returns `BAD_UI` and the live menu fails closed. The normal game is unaffected, but there is no menu entry. The fake `G` in `tests/menu/fakeui.lua:31` is a plain table, which hides this.
- **Repair:** accept any table for `G`. Keep the plain-table checks for `G.UIT` and `G.C`, which really are plain fields on the instance.
- **Impact:** needed before a live install, not for staged testing.

**H2. The AI can't see why a decision request failed.**
- **Where:** `control_transport.lua:387-409`.
- **Problem:** the transport only matches a reply to the pending decision by its `sequence`. The service omits `sequence` on every `decide_begin` rejection (`practice_service.py:1331,1337,1739-1764`: not attested, replay, bad observation, decision outstanding, ended, aborted). As a result:
  - Each rejection lands in the coordination queue.
  - The decision sits until the 15.25 s loop timeout.
  - A persistent rejection keeps repeating until the loop's error budget shuts the AI down.
- **Related problem:** `decision_result` replies echo the *decision's* sequence (`practice_service.py:1832`), but the runtime never registers them in its `outstanding` list (`runtime_bootstrap.lua:1463,1473`). They therefore shift the reply order, and the AI's END acknowledgement can be credited to a heartbeat reply.
- **Minimal repair:** the service answers strictly in order on the single connection (`practice_service.py:2000-2017`). The transport should keep an ordered list of every frame it pushes (coordination, begin, poll, cancel, result) and match each non-event reply to the head of that list. Route coordination replies back to the runtime tagged with their op.

### Medium

**M1. Pre-start coordination has no overall deadline and ignores a service abort.**
- Only HELLO has a deadline (`runtime_bootstrap.lua:1347`).
- A failed LOBBY_CODE, READY (other than config mismatch) or START leaves its `*_sent` flag stuck true (`runtime_bootstrap.lua:1048-1070`).
- Heartbeat replies, which carry `aborted`, are never read. The service aborts after its 90 s prestart timeout, but the runtimes keep waiting.
- **Repair:**
  - Add a prestart deadline of at least 90 s that triggers `shutdown`.
  - Treat `ABORTED`/`CLOSED`/`ENDED` replies, or a heartbeat with `aborted=true`, as `coord_failure`.
  - Re-arm the send on retryable failures (`NOT_READY`, `NO_LOBBY`).

**M2. The companion gives up on attestation sooner than the host waits.**
- The companion's attestation timeout is 30 s (`companion_host.lua:134`); the host waits up to 90 s for both probes before it writes the file (`practice_host.py:126,2061-2070`).
- With a slow second role, the first role fails permanently while the host carries on.
- **Repair:** make the companion timeout at least the host timeout plus a margin.

**M3. The live 10 s acknowledgement timeout never fires.**
- `companion_host.lua:1177` passes the frame time `dt` as `now`, so `now - started_at` is always negative (`menu_controller.lua:718-732`).
- **Repair:** call `controller.update()` with no argument.

**M4. One live transport error sticks forever.**
- `ensure_transport` keeps reusing a dead worker (`companion_host.lua:854-857`), and `poll_start` immediately returns the old `last_error` (`companion_host.lua:1039-1051`).
- **Repair:** rebuild the transport whenever `last_error()` is set or the worker has stopped.

**M5. The "main menu ready" check is also true during the splash screen.**
- `mp_driver.lua:382-390` only checks the stage. The splash screen uses the MAIN_MENU stage with the SPLASH state (`game.lua:1380`), so lobby creation could fire before the menu exists.
- **Repair:** also require `G.STATE == G.STATES.MENU` and `G.MAIN_MENU_UI ~= nil`.

### Low

- **L1. Send allowlist is missing two harmless actions.**
  - `syncClient` is sent on joining a lobby (`action_handlers.lua:91,107,1399-1404`) and is harmless to block, since the server defaults `isCached=true`. Blocking it only adds log noise.
  - Blocking `connect` disables Multiplayer's reconnect button (`lobby.lua:633-636`).
  - Neither carries private data, so both can be allowed.
- **L2. Timeout path can drop a cancel.** It clears the pending slot even if the cancel push failed (`control_transport.lua:644-646`).

### Checked and correct

- **Feature off:** the repository config is inert. The live role only wraps the play-button builder and `Game.update`.
- **Startup order:** Multiplayer loads first. The `Game.update` wrapper calls the original exactly once, first.
- **Isolated roles:**
  - The human role never loads the policy/executor modules.
  - Engine hooks are AI-only, and hooked methods keep their return values.
  - Role separation between human and AI is intact.
- **Attestation gate:**
  - Checks nonce, session, role, content hash, port and both root paths.
  - Retries hello on not-attested without burning a sequence number.
  - Window titles and AI minimize happen after attestation and before bootstrap. The live copy is untouched.
- **Environment:** reads exactly the frozen descriptor names, with no aliases.
- **Local only:** the socket goes to 127.0.0.1 only. LÖVE userdata channels are read through normal indexing.
- **Native identity:** the Windows lookup uses query-limited access and always closes the handle.
- **Real UI shapes:** the button `id` and the `create_UIBox_generic_options` node path match the real game source.
- **`Client.send`:** takes a table in the real source, so the send guard works.
- **Seed and results:**
  - Only the human reports the actually resolved run seed. The AI's SETUP carries no seed, and none reaches policy.
  - Result and lives orientation is correct for both roles.
  - After the match ends, the runtime only drains replies and never decides again.
- **Wire encoding:** `wire_json` produces exact envelopes. Empty tables inside observations are safe because the service rebuilds them as Lua tables.

### Pending real-game checks (not code blockers)

- **Minimized AI:** Balatro's `love.run` keeps calling update and only skips drawing (`main.lua:73-78`). Continuous updates still need a real smoke test, with no timer or focus workarounds.
- **Worker thread:** `require("json")`/`socket` inside the thread uses the same pattern as Multiplayer, so it's expected to work.
- **Staged paths:** normalized `getSaveDirectory`/SMODS paths and the real attestation files.
- **AI ready button:** the element after the lobby's menu rebuild.
- **Config digest:** equality after the lobby-options JSON round trip.
- **Full match:**
  - Send-guard coverage across a whole match.
  - Win and loss detection.
  - Recovery from a stopped game or a return to the lobby.
- **Mod compatibility:** Handy and JokerDisplay.

**Order of work:** fix C1 and C2, preferably with H2 and M1, and update the fixtures to the real Multiplayer shapes. After that, a controlled staged smoke test is reasonable. H1, M3 and M4 are needed before a live install.
