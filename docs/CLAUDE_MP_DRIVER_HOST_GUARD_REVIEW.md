# Claude review — companion send guard: trusted-role createLobby fix

Reviewer: Claude Code 2.1.283, `claude-opus-5-5`, effort high, read-only. Brief: `work/claude-mp-driver-review.txt`. Date: 2026-09-29.

# Review: mp_driver trusted-role send guard (host createLobby fix)

## Verdict: **READY FOR RE-CERTIFICATION AND STAGED MATCH**

I found no Critical, High or Medium issues. I traced the whole real path, from createLobby to the seed report, against the pinned Multiplayer 0.5.5 source and the local server. I found no other real-source mismatch that would stall the staged match. The Low items below are test-fidelity and hardening notes. None of them justifies its own re-certification cycle; batch them with the next change that needs one anyway.

This was a read-only review, so I did not run any tests. Test results are as reported in the note.

Path prefix: `MP/` = `staging/roles/human/appdata/Roaming/Balatro/Mods/Multiplayer/`, `SRV/` = `work/local-server/src/`.

## Answers to review items

**1. Is the root cause correct? Yes.**
- `MP/core.lua:31` initializes `is_host = false`.
- The only writer is `action_lobbyInfo` (`MP/networking/action_handlers.lua:184-186`). `action_joinedLobby` (`:83-94`) sets `code` but never `is_host`.
- The old `is_host_role()` (diff lines 67-76) returned false on an explicit `false`. HOST_ONLY `createLobby` was therefore refused at `start_lobby` → `MP.ACTIONS.create_lobby` (`MP/ui/main_menu/play_button/play_button_callbacks.lua:137`, `action_handlers.lua:1097-1101`).
- `host_start` still returned `driver_ok` because `force_lobby_options` ran before the send. That matches the Lovely log and the endless `practice_no_lobby` in `service_trace.jsonl:7+`.
- Side effect of the old rule: `syncClient`, sent right after joinedLobby (`action_handlers.lua:91`), was also blocked for both roles.

**2. Authority: nothing widens it.**
- The role check runs first and ignores MP state (`mp_driver.lua:782-785`), so the AI can never send `createLobby` or `lobbyOptions`.
- This check is load-bearing. The server's `lobbyOptionsAction` has **no host check** (`SRV/actionHandlers.ts:406-411`), and the server promotes the guest to host when the host leaves (`SRV/Lobby.ts:114-133`). The AI would then receive `isHost=true` and the pinned handler would call `lobby_options()` (`action_handlers.lua:224`). The trusted-role gate refuses that.
- The human can never send `joinLobby` (`mp_driver.lua:794-795`).
- MP fields can only narrow permissions. A forged `code` only blocks `createLobby`. A forged `is_host=true` only blocks the AI's `joinLobby`. `host_confirmed()` is only an additional requirement for the human's `lobbyOptions`, and the server ignores options from a client that has no lobby (`actionHandlers.ts:410`, `client.lobby?.`).

**3. rejoinLobby and syncClient: both safe.**
- **rejoinLobby payload:** only `lastLobbyCode` and `reconnectToken`, both module-local (`action_handlers.lua:61-62, 74-79`).
  - They are written only from server joinedLobby/rejoinedLobby (`:89-90, 101-102`).
  - They are cleared on leave, disconnect and timeout (`:124-125, 250-251, 1131-1132`).
- **Server binding:** the server requires that exact lobby's `disconnectedSlot.reconnectToken` (`SRV/Lobby.ts:203`) and restores only that slot's own role and state (`:207-233`). A client cannot join a different lobby or switch roles. A pre-start drop does a normal leave with no slot (`:151-153`), so a rejoin then fails safely with an error.
- **syncClient:** carries only `isCached` (`action_handlers.lua:1399-1404`). The server stores that flag (`actionHandlers.ts:744-749`) and exposes it only as `hostCached`/`guestCached` (`Lobby.ts:293, 299`), which drives a UI warning (`MP/ui/lobby/start_ready_button.lua:9`).

**4. Logger `action` field: no leak.**
- The only producer is `mp_driver.lua:816`. The value goes through `TOKEN_PATTERN` (letters, digits, `_`, `-`), at most 64 characters, then `MAX_STRING` 96. Only the action name is logged, never the payload.
- Decision logs use `selected`, not `action` (`decision_loop.lua:586-603`), so AI choices are not newly written out.
- Other records' `role`/`op` fields are still dropped by the allowlist (`logger.lua:89-94`).

## Findings

| ID | Severity | File:line | Concrete scenario | Required fix |
|---|---|---|---|---|
| L1 | Low | `tests/runtime/test_mp_driver.lua:18-25` | `fake_engine` still leaves `is_host` nil, while the real value is `false` (`MP/core.lua:31`). This is the same fixture/real gap that hid the defect. It is harmless today only because `host_confirmed()` tests `== true`. | Default `is_host = false` in `fake_engine`. |
| L2 | Low | `tests/runtime/test_mp_driver.lua:44-51, 362-381` | The fake `start_lobby` sends nothing and sets `code` synchronously. The new end-to-end test calls `client.send` directly, so it never exercises `host_start` → `start_lobby` → `create_lobby` → guarded send, which is the path that failed natively. In the real source, `code` arrives asynchronously after the send (`SRV/Lobby.ts:94-99`). | Make the fake `start_lobby` send `{action="createLobby"}` through the injected client **before** setting `code`, and assert it was forwarded. |
| L3 | Low (comment only) | `mp_driver.lua:129-131, 328-330, 336-338` | The comments say `is_host` is set by "joinedLobby/lobbyInfo". It is set only by lobbyInfo (`action_handlers.lua:186`); `code` is set by joinedLobby/rejoinedLobby (`:85, 98`). | Fix the wording at the next re-certification. It does not justify one on its own. |

## Further real-path risks (item 5)

I walked lobbyInfo → lobby_code → join_code/ai_join → READY/digest → ai_ready → START → host_start_game → seed report. Each step matches the pinned source. Points worth knowing before the run:

1. **Screen wipe after joining (not a blocker).** When `code` becomes set, pinned `Game:update` calls `go_to_menu()` on both roles (`MP/ui/lobby/lobby.lua:559-565`). That wipes the screen, and `delete_run` sets `MAIN_MENU_UI = nil` (`lovely/dump/game.lua:1189`) until `main_menu` rebuilds it.
   - An `ai_ready` call in that window returns `MISSING_ELEMENT`, which is a bounded retry (`mp_driver.lua:689-691`, `runtime_bootstrap.lua:1197-1203`).
   - The element is re-resolved on every call, so a stale button cannot be used.
2. **Local ready flag trusted before the send (Low hardening, not observed).**
   - Pinned `lobby_ready_up` flips `ready_to_start` (`lobby.lua:418`) *before* it mutates the element (`:420-422`) and sends `readyLobby` (`:425`).
   - If `:420-422` ever threw, `readyLobby` would never go out. The next retry would then return early on the local flag (`mp_driver.lua:683-685`), the guest-ready commit would be recorded (`runtime_bootstrap.lua:1200-1201`), and the host would never see `guestReady`. Result: pre-start timeout.
   - I checked that the button shape matches: `id` and `button` sit on the same node, and `children[1].children[1]` is the text node (`lovely/dump/functions/UI_definitions.lua:6890-6911`; `start_ready_button.lua:148-157`). So this should not happen. If you want it hardened later, commit guest-ready only after a server `lobbyInfo` confirms it.
3. **Forced config reaches the AI before its READY.**
   - The host resends options on every lobbyInfo (`action_handlers.lua:224`). The server relays them (`Lobby.ts:345`) and also sends a snapshot on join (`Lobby.ts:274`).
   - The six forced keys (`MP/rulesets/majorleague.lua:23-28`) arrive as JSON ints/bools, and `action_lobby_options` converts the numeric keys (`action_handlers.lua:612-624`). The AI digest therefore matches the host's.
   - Until the options arrive, the AI's config still says `ruleset_mp_blitz`, so `config_digest` returns BAD_STATE and the digest step retries (`runtime_bootstrap.lua:1184-1189`).
4. **READY/START ordering has no deadlock.** READY acks each role independently (`tools/practice_service.py:1500-1515`), and START needs both (`:1523-1528`). The AI sends READY before `ai_ready`, so START is only attempted after both are in.
   - The server does not enforce guest readiness (`actionHandlers.ts:140-144`). The real gate is `ready_to_start`, checked in `mp_driver.lua:722` and `runtime_bootstrap.lua:1208`.
5. **Seed report works for Major League.**
   - `the_order` is forced to false (`majorleague.lua:25`), so the `"*"` prefix at `game.lua:2238` never applies. That prefix would fail `RUN_SEED_PATTERN` (`runtime_bootstrap.lua:127`) and end in SEED_TIMEOUT.
   - Server seeds are 8 characters from `A-Z1-9` (`SRV/utils.ts:1-10`).
   - Gauntlet runs use `custom_seed` (`action_handlers.lua:288-290`), which reaches the guest through lobbyOptions, so both runs start on the same seed.
   - `main_menu` never sets `pseudorandom.seed`, so no stale menu seed can be reported early.
6. **Expected blocked-send log lines (not failures).** When reading the run logs, these are normal:
   - After start, any lobbyInfo (for example after a rejoin, `Lobby.ts:250`) makes the host try `lobbyOptions`. The guard refuses it and logs `driver_send_blocked action="lobbyOptions"`.
   - `Client.send("ce_cache")` (`MP/lovely/ce.toml:17`) is a bare string, so it is blocked and logged with no `action` field.
   - End-game stats and log-hash sends are blocked by design.

## Orchestrator resolution

- L1 applied: `fake_engine` now starts with the real `is_host = false`.
- L2 applied: `host_start_sends_real_create_lobby_through_the_guard_before_code` drives host_start -> start_lobby -> guarded send before the code arrives; verified to FAIL on the pre-fix driver (`expected forwarded, got false`, both runtimes) and pass after.
- L3 applied: comments now say `is_host` comes only from lobbyInfo, the code from joinedLobby/rejoinedLobby.
- Risk 2 (commit guest-ready only after server confirmation): recorded, not changed; the pinned button shape matches.
