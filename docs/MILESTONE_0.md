# Initial architecture investigation — not yet accepted

Date: 2026-09-27. Research performed by the orchestrator while locating the required implementation worker. DeepSeek inspection and Claude adversarial review remain outstanding. No feature code has been written.

## Verified environment

- Game: `C:\Program Files (x86)\Steam\steamapps\common\Balatro`.
- Mods: `C:\Users\ginom\AppData\Roaming\Balatro\Mods`.
- Balatro was running (PID 7676) during research. No live files were changed and no game interaction was performed.
- Installed Multiplayer manifest: 0.5.5. Its 449 upstream-tracked files match tag v0.5.5 after CRLF normalization. Binary/content byte identity is a separate verification; initial raw hashes differed because Git checked out Windows line endings.
- Exact upstream tag commit: `3dff16a99edde91894e0ccf94cc9a9171443070b`.
- Steamodded version.lua: 26.829.0. Lovely startup log: 0.10.0. JokerDisplay manifest: 2.0.4. Handy folder exists; 2.0.6 reported by user, pending manifest confirmation.
- Research clones are under the workspace's `work/`, outside this repository and outside live Mods. No live backup is needed for read-only inspection; a fresh verified backup is mandatory before any future live change, after checking the game is closed.

## Actual architecture map

The v0.5.5 client initializes `MP.LOBBY`, `MP.GAME`, `MP.ACTIONS`, `MP.MOD_ACTIONS` in core.lua. It loads libraries, overrides, compatibility, networking, gamemodes, layers, rulesets, UI and objects. Each game client owns one global Balatro `G` and one independent run. Opponent state is a summary, not a second engine.

| Concern | Inspected source surface |
|---|---|
| Rules and layers | rulesets/_rulesets.lua, rulesets/majorleague.lua, layers/_layers.lua, lib/ruleset_utils.lua; canonical runtime reader MP.current_ruleset() |
| Lobby defaults | core.lua MP.reset_lobby_config; ui/main_menu/play_button/play_button_callbacks.lua G.FUNCS.start_lobby |
| Local/enemy state | core.lua MP.reset_game_states; MP.GAME.enemy holds score, hands, skips, lives, location, spending |
| Start/seed | networking/action_handlers.lua action_start_game; seeds arrive in startGame, custom same-seed selection follows lobby config |
| Blind progression | gamemodes/attrition.lua get_blinds_by_ante; objects/blinds/nemesis.lua; ui/game/game_state.lua |
| Lives and match end | inbound playerInfo, enemyInfo, endPvP, winGame, loseGame; server resolves match state |
| Timer | ui/game/timer.lua, lib/ruleset_utils.lua; startAnteTimer/pauseAnteTimer/failTimer actions |
| Scores/hands visibility | action_enemy_info accepts noScore; ui/game/blind_hud.lua masks scores before first hand when configured |
| Location/spending | MP.ACTIONS.set_location, spent_last_shop; enemyLocation/spentLastShop handlers |
| Action transport | Client.send serializes into uiToNetwork; socket thread TCP; networkToUi consumed by Game:update |
| Extension APIs | MP.register_mod_action and MP.ACTIONS.modded for relayed custom actions; MP.register_action only adds new handlers, refusing replacement |
| Practice | lib/practice_mode.lua; changes MP.SP and routes through single-player setup |
| Ghost/replay | lib/ghost_replay.lua and lib/replay_log.lua; recorded score playback and separate ghost life resolution |

The inbound built-in HANDLERS table is local. The client auto-starts a network thread and connects at core.lua startup. A wrapper added only after initialization does not prove offline isolation.

The repository's agents.md is orientation, not authoritative behavior: its timer summary is inconsistent with the actual code. In the Major League path without timer modifier layers, the old timer ticks outside PvP when a timer has been started; it explicitly returns inside a PvP boss. Do not implement a generic "PvP-only countdown" from the prose description.

## Major League observations

The installed `ruleset_mp_majorleague` forces Attrition, sets base time 180, forgiveness 0, The Order false, preview disabled, enemy location disabled and timer display threshold 180. These are observed values, not new constants to copy into the companion.

Normal lobby construction resets defaults, derives multiplayer content and score hiding from the selected ruleset, then applies force_lobby_options(). Major League has multiplayer_content=false, bans vanilla Bloodstone and uses Multiplayer's existing Bloodstone rework. Reusing this ruleset means retaining its supplied balance; the companion must introduce no additional changes.

Defaults inherited from Multiplayer include starting lives, PvP starting ante, timer increment, same-seed option and comeback settings. Attrition adds bans independently. The adapter must call actual rules/layer/gamemode setup and snapshot its effective result, not read only majorleague.lua.

## MultiplayerAPI investigation

Pinned current checkout: `44512733f0ab97393dc911d229d6de85b0ca335e`; manifest 1.0.0. It is not a dependency used by installed Multiplayer 0.5.5.

It supplies lobby, action, ruleset, replay, UI and networking infrastructure. The current implementation DOES contain `MPAPI.create_local_lobby` in api/lobby/public.lua, even though the README emphasizes network lobbies. It creates one local player without allocating a server lobby. api/action/dispatch.lua dispatch_local_action delivers only to self/broadcast and drops other targets. This is not an implemented second local participant or game simulator. A simulated rival would require additional work, and would still not connect legacy Multiplayer rules automatically.

## Additional server source

The repository named BalatroMultiplayerAPI-Server currently checks out a legacy TCP Multiplayer server, matching the installed client's message vocabulary. Commit: `d664c29523b827d53dfa1a181e5b2baf1aefac4f`. src/actionHandlers.ts includes playHand, endPvP, failRound and timer adjudication. Its exact deployment/version correspondence with client v0.5.5 is not established. Inspect and pin this relationship before claiming exact rule parity. Do not infer current server architecture from the repository name or cached web descriptions.

## Initial integration direction and unresolved gates

Prefer a separate companion with an isolated second Balatro runtime and a strictly local match coordinator using the existing Multiplayer protocol/rules. This combines an AI participant with a local adapter; it avoids rewriting the scoring engine and unsafe swapping of G. A child process is the leading isolation candidate, not yet a proven launcher. It must get its own profile, save/config paths, event manager, RNG and mod directory before it is ever launched.

The coordinator should reuse a version-matched upstream server implementation locally if its isolation, licensing and parity are confirmed. A newly written approximate PvP/lives arbiter is not acceptable. The current server's timer/tie/round semantics still need full inspection and contract fixtures. A protocol adapter needs an explicit ownership state machine, no official socket traffic in AI mode, no ranked/stat/checksum uploads, and complete cleanup on exit/failure.

Potential routes:

1. **A/B: isolated runtime plus local protocol participant/adapter** — strongest initial candidate for exact game execution and minimal scoring changes. Must prove local transport replacement before auto-connect, safe process/profile isolation and upstream server parity.
2. **C: MultiplayerAPI local lobby** — real solo local-lobby API exists, but no second participant, no legacy Multiplayer bridge and no simulation engine. Do not add as V1 dependency merely for lobby naming.
3. **Ghost mode** — useful UI/replay references but not a live adversary. Its score progression follows human comparisons and its life handling is separate; unsuitable as the match authority.
4. **Fresh Lua simulator or global swapping** — reject as V1 direction: incomplete vanilla/SMODS fidelity or unsafe shared state.

A small supported upstream transport/offline-context hook may be necessary because built-in inbound handlers are private and transport starts during core initialization. No patch has been chosen or applied. First investigate whether existing startup configuration and a local-only session boundary can satisfy the requirements cleanly. Document any required hook precisely before implementation; do not make a giant fork.

## Fairness and determinism plan

AIObservation will be a versioned immutable plain-data allowlist: phase, own currently visible hand/shop/pack choices, known deck composition as an unordered aggregate, owned visible Jokers/consumables and public counters, money/capacity, public rules, legal action descriptors, and only the opponent information Multiplayer would disclose at that point. Face-down identity, ordered deck, RNG state/seed streams, unopened packs, future offers, raw globals and undisclosed opponent fields stay out. The match seed belongs to trusted runtime initialization; policy decision noise uses a separate stream which cannot predict gameplay RNG.

Legal actions must be validated by the bot's own actual runtime immediately before execution, including stale-action rejection. Search may use belief samples consistent with observation, never clone hidden live state to evaluate actions. Independent policy sandbox and serialized boundary are required; banning field names alone is insufficient.

Difficulty changes computation and optional decision noise only. Pacing changes when legal actions execute; it must not advance RNG. Tournament outcomes can depend on timing, so reproducibility claims need a recorded/fixed event schedule as well as seed.

## Compatibility, licensing and acceptance gates

- Live game/mod/save paths stay untouched while playing. Check processes immediately before integration; do not terminate Balatro. Back up affected targets with hashes only once closed. A later backup of an actively changing save is not a consistent snapshot.
- Ordinary single-player and human multiplayer must take original code paths with AI disabled; preserve Handy/JokerDisplay hooks.
- Existing Multiplayer terminal handlers record normal match history and emit log checksums. AI mode must isolate persistence and prevent network/stat submissions before reusing these handlers.
- Both inspected Multiplayer and MultiplayerAPI repositories contain GPL v3 license text. The server license must also be reviewed before reuse. Preserve licenses and notices for any adaptation. No implementation source has been copied into this project; do not distribute proprietary Balatro sources/assets.
- Required before implementation acceptance: DeepSeek's real code inspection, complete server parity assessment, child-runtime isolation proof, transport/offline strategy, and Claude's adversarial review with high/critical findings resolved.

## Sources

- https://github.com/Balatro-Multiplayer/BalatroMultiplayer/tree/3dff16a99edde91894e0ccf94cc9a9171443070b
- https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI/tree/44512733f0ab97393dc911d229d6de85b0ca335e
- https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI-Server/tree/d664c29523b827d53dfa1a181e5b2baf1aefac4f

Status: preliminary plan written; no feature implementation, runtime test, benchmark, reviewer approval, or V1 completion claimed.
