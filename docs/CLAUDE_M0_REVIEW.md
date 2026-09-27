# Milestone 0 adversarial review: isolated runtime plus local legacy server

**Verdict:** I accept the direction for research only: a separate AI runtime, a local legacy TCP server that is version-pinned and otherwise unmodified, and no scoring rewrite. That's the right family of solution. I do not accept the design as written in `docs/DEEPSEEK_M0_RESEARCH.md` §D/§F/§H. The one Critical and five High findings below must be fixed in the docs before implementation starts. I did not run or edit anything.

Path prefixes: **MP** = `work/upstream-multiplayer-v0.5.5`, **SRV** = `work/upstream-api-server/src`, **DS** = `docs/DEEPSEEK_M0_RESEARCH.md`.

---

## Critical

**C1. A static `.env` can't redirect the human's live install without breaking normal Multiplayer (DS §D.1 L125, §D.6 L130, §F L149, §G L163).**
- **What the code does:**
  - The `.env` file is `MP.path .. "/.env"`, inside the live `Mods\Multiplayer` folder, and it is read once at load (MP `core.lua:72-97`).
  - The server address is passed to the network thread when it starts (MP `core.lua:343-350`; `socket.lua:6,55`). Reconnects reuse the same address (`socket.lua:83,104`).
  - Nothing can switch servers at runtime.
- **Consequences:**
  - A static `.env` in the live install sends *every* human Multiplayer session to loopback.
  - Adding and removing it per session means writing to live Mods (AGENTS.md:9). If the launcher crashes midway, the redirect is left behind silently.
  - A companion mod can't pre-seed `MP.ENV`, because `core.lua:72` resets it.
  - Changing `SMODS.Mods["Multiplayer"].config.server_url` in memory is worse. That config is persisted (`Multiplayer.jkr`, per `.env.example:5`), and Multiplayer rewrites that config itself (`matchmaking.lua:30`). The loopback address could leak into the live profile.
- **Fix:** stage **both** practice clients: a human sparring runtime and an AI runtime.
  - Each is a hash-verified copy of the installed stack, with its own Mods folder and a `.env` pointing at 127.0.0.1.
  - The live install, live Mods and live profile are never touched, so ordinary Multiplayer is unchanged by construction. Starting the launcher is the explicit AI activation.
  - "Real installed Major League rules" is proved by staged-vs-installed hash equality, the same method as MILESTONE_0:10.
  - The launcher must fail closed: check the `.env` before launch, and check the `Connecting to %s:%s` log line (`core.lua:345-348`) after launch.
  - Remove the live-`.env` and config-mutation options from the docs.

## High

**H1. Save and profile isolation is assumed, and a design decision depends on it (DS §D.2 L126, §E5 L140, §F L155).**
- DS says the AI-mode stats and save hook is "not strictly necessary" because pollution lands in the AI runtime's own config. Nothing shows a copied exe gets a separate save folder, Lovely mod folder or `Multiplayer.jkr`. Without that, `match_history`, `joker_stats` and `ghost_replays` (MP `config.lua:14-16`) are written into the user's `%AppData%\Balatro`.
- **Fix:** no runtime with Multiplayer loaded may launch until P1 passes. P1 must:
  - run only with Balatro closed and after a fresh backup;
  - hash all of `%AppData%\Balatro` (Mods, config, profiles, Lovely logs) before and after, with zero bytes changed;
  - cover Steam side effects (achievements, stats, cloud saves).
- Mark the §F "prefer isolation over hooks" conclusion as depending on P1.

**H2. The observation spec treats what's sent over the network as what a human can see, and misreads Major League (DS §8 L50-53, §H L173).**
- **Score hiding:** Major League has no `layers` (MP `rulesets/majorleague.lua:1-31`). So `hide_score_until_played` is false (`play_button_callbacks.lua:115`), and `force_lobby_options` doesn't set it (`majorleague.lua:22-30`). In Major League, scores are revealed after every hand (SRV `actionHandlers.ts:259-267`). The noScore analysis doesn't apply.
- **Remove `pvpTimerOrder`:** the client uses it only when the `pvp_timer` layer is active (MP `action_handlers.lua:445`). A Major League human never sees or uses it.
- **Location:** it is stored even when disabled (`action_handlers.lua:689-717`). The only human-visible trace is whether the timer button is enabled (`timer.lua:8`, `loc_ready`). Expose it only as that legal-action bit.
- **Exclude fields sent but never displayed:** `spent_in_shop`, `sells`/`sells_per_ante`, `last_timer` and `real_score` (`action_handlers.lua:732-756, 852-856`). Displayed fields are `lives`, `skips` and `highest_score` (`lobby_info.lua:155-164`).
- **Scores sent unmasked:** `Client.loseLife` (SRV `Client.ts:124-133`) and `skipAction` (`actionHandlers.ts:535-541`) send the real score with no noScore flag. DS's "server withholds score until both committed" is too broad even for standard rulesets.
- **Exclude lobby metadata:** `lobbyInfo` carries the opponent's modHash, including `serversideConnectionID` (SRV `Lobby.ts:288-300`; MP `matchmaking.lua:28`).
- **Fix:** define AIObservation as what the human UI shows under the *effective* ruleset and layer snapshot. Deny wire fields by default, and add one test per field.

**H3. "The bot reading its own `G` is not a leak" is overclaimed (DS §F L152).**
- `G.GAME` holds the seed and RNG state. `G.deck` is ordered, and face-down cards are in there too.
- The seed is also written to the replay-log manifest (MP `action_handlers.lua:294-316`) and the trace log (`:1571-1582`).
- The server prints every action it sends, including the `startGame` seed (SRV `main.ts:122-126`).
- This contradicts DS §H and MILESTONE_0:74.
- **Fix:** read `G` only through a field-by-field extractor. The policy process gets no filesystem access to Lovely logs, replay logs, the server's stdout or the local sqlite database.

**H4. The protocol lets the AI runtime request hidden info, and `moddedAction` is not a coordinator channel (DS §F L150).**
- The adapter runs in-process, so it can call the global `Client.send` and `MP.ACTIONS.*` (MP `action_handlers.lua:27-42`).
- `getNemesisDeck` and `getEndGameJokers` are relayed at any time with no phase check (SRV `actionHandlers.ts:636-662`). The human client answers unconditionally with its full deck and full Joker saves (MP `action_handlers.lua:902-936`).
- `lobbyOptions` is accepted from either player, not just the host (SRV `actionHandlers.ts:406-411`, `Lobby.ts:337-346`).
- `moddedAction` is never sent by the server. It is relayed from one client to the other (`actionHandlers.ts:869-887`), so bot control would pass through the human's runtime.
- **Fix:**
  - Carry control traffic over separate loopback IPC owned by the launcher. No custom `moddedAction`s in V1.
  - The adapter may only use UI-level `G.FUNCS` for legal actions.
  - Add an outbound message allowlist and an audit trace, compared against a human baseline. Add a fixture proving the AI never sends deck/Joker requests before game end, or `lobbyOptions` while it is the guest.

**H5. The seed semantics are misread, and seed choice can give an RNG advantage (DS §9 L57-58).**
- **Actual rule:** `if not different_seeds and custom_seed ~= "random" then seed = custom_seed` (MP `action_handlers.lua:288-290`). That is the reverse of DS's reading.
- With `different_seeds`, the server sends no seed (SRV `actionHandlers.ts:152`), so `start_run` gets nil (MP `lobby.lua:367-372`).
- `custom_seed` is set by the host (`lobby.lua:173`). With `random_loadout`, the deck and stake come from the seed plus the username (`lobby.lua:332-358`).
- "Same seed ⇒ same offers" is too strong. When the opponent's Magnet fires, it consumes the receiver's `j_mp_magnet` RNG stream (`action_handlers.lua:772`).
- **Fix:**
  - AI mode forces `custom_seed="random"`, and the seed stays server-generated.
  - The launcher can't choose or reroll seeds.
  - The AI username is fixed and not tunable.
  - The event-schedule requirement (MILESTONE_0:78) must include RNG draws triggered by the opponent.

## Medium

- **M1. Timers are client-reported, not "server-adjudicated" (DS §5 L35; MILESTONE_0:27).**
  - The server only relays `startAnteTimer`/`pauseAnteTimer` (SRV `actionHandlers.ts:696-719`). It deducts a life only when a client reports its own `failTimer`/`failPvPTimer` (`:721-742`, `:346-391`).
  - Expiry is decided locally from wall-clock time (MP `timer.lua:395-397, 484-497`).
  - The AI must run the unmodified timer code, and policy compute must never block its Lua main thread.
  - The DS reading of the old timer is correct (`timer.lua:445-448, 491`).
- **M2. The tie and PvP-end fixtures are incomplete.**
  - DS is right that a tie costs no life (`actionHandlers.ts:318, 338-342`).
  - Add fixtures for:
    - PvP resolving only when the trailing player (or both) is out of hands (`:305-311`);
    - a tie where both have 0 hands;
    - the leader running out of hands while play continues;
    - the game-over path, which sends no `endPvP` (`:322-333`);
    - the tie-break using `firstReady` (`:254`);
    - `failRound` and `failTimer` costing separate lives in the same round (`Client.ts:108-121`);
    - the `failPvPTimer` path when the life loss is blocked (`:351-390`).
- **M3. The server version says nothing about parity.**
  - `serverVersion` is hard-coded to `"0.3.2-MULTIPLAYER"` with a "TODO: Fix this" (`actionHandlers.ts:464-465`). The check only warns if the client is older (`:483-494`).
  - The pinned server is the repo's HEAD commit, not a release matched to 0.5.5.
  - DS's claim that everything else the client sends has a server case holds: `endGameStatsRequested`/`nemesisEndGameStats` are at `main.ts:469-477`, and `sendGameStats` is the only unhandled action.
  - **Fix:** build a coverage matrix from the source (every `Client.send` ↔ `main.ts` case ↔ the client's `HANDLERS` table), add behavioural fixtures, and record the commit-date gap.
- **M4. Loopback-only conflicts with an "unmodified server".**
  - The bind address is hard-coded to `0.0.0.0` (`main.ts:576`); only the port is configurable.
  - Both clients share IP 127.0.0.1 and the same connection ID (MP `crypto.lua:45-84`), so abuse bans hit both at once (SRV `abuse.ts:111-138, 214-215`).
  - The limit of 30 messages/sec (burst 100) drops messages (`abuse.ts:49-50`, `main.ts:231-238`). A fast bot could lose a `playHand`.
  - **Fix:** decide between a one-line documented fork and a firewall rule, and add a fixture proving the bot stays under the rate limit.
- **M5. Unlock state and encryptID must match between the runtimes.** `unlocked` and encryptID go into the modHash, and encryptID includes game speed and the day (`matchmaking.lua:28-32, 54-95`). Locked Jokers change the shop pool, so both runtimes need the same unlock state.
- **M6. The offline claims are too broad (DS §G L165).** The only network code in the Multiplayer client is the TCP socket plus user-initiated `openURL` calls (`smods_menu.lua:8,12`, `functions.lua:146,412`). Vanilla Steam integration, SMODS, Lovely, Handy and JokerDisplay were not audited. Ranked rulesets exist in the client (`rulesets/ranked.lua:3`). Reword the claim to "no ranked submission path found in the MP 0.5.5 Lua".

## Low

- The modHash carries an FNV hash of the C: volume serial, not the raw serial (`crypto.lua:70,84`).
- Handy's MP-extension flag must match in both runtimes (SRV `Lobby.ts:308-311`).
- Readying first earns `speedrun` (`actionHandlers.ts:178-191`), so bot ready-timing should be an explicit difficulty setting.
- The admin port requires a signature (`main.ts:596-622, 714-722`). It's harmless, but should be disabled.

---

## Must be fixed before implementation starts (research docs)

1. Adopt the both-staged topology in C1 with fail-closed loopback checks. Remove the static live `.env` and config-mutation routes.
2. Rewrite §H as a projection of what the human UI shows under the effective Major League snapshot (H2), and add the field and log exclusions (H3).
3. Correct the seed section and set the AI-mode seed policy (H5).
4. Correct the timer section to "client-reported" (M1).
5. Replace the `moddedAction` channel with launcher IPC, and specify the outbound allowlist and audit (H4).
6. Write the parity plan: coverage matrix, the full fixture list from M2, and the bind decision (M3, M4).
7. Specify how P1 proves isolation, including the Steam checks, and make every launch depend on it (H1). Add the unlock-parity check (M5).

## Prototype acceptance gates (not research errors)

These are evidence the prototypes must produce, not mistakes in the research:

- **P1:** zero-byte diff of the live install and profile.
- **P2:** behaviour when the server port is dead, given the single 10-second connect attempt (`socket.lua:50-63, 102-105`).
- **P3:** every fixture listed above passes against the pinned server.
- **P4:** the AI's outbound message audit matches the human baseline, the extractor reads no extra RNG, and no seed reaches any channel the policy can read.
- Rate-limit compliance, and matching Handy/unlock state between the two runtimes.
