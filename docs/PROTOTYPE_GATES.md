# Prototype gates (actionable)

No prototype is passed. Every launch precondition must hold before each step; a failed precondition aborts the step. This checklist incorporates G1-G6 from CLAUDE_M0_REREVIEW.md.

Crosswalk: integration-plan gate 1 = P1 static investigation; gate 2 = P0 + P1a; gate 3 = P1b + full P1 + P2; gate 4 = P3; gate 5 = P4. P5 adds configuration/license hygiene to all applicable gates. The research report's P1-P4 references use these same IDs.

## P0 — preconditions
- User's Balatro closed; process check immediately before every launch using full image paths. Distinguish staged processes by image path and launcher-recorded PID/start time, not name alone. Never terminate the user's game. Recheck just before starting; abort if it reopened.
- Verified, hash-manifested backups of the live install and `%AppData%\Balatro`.
- Staged copies only; no live `.env`/config mutation and no live Mods writes.
- Parse staged `.env` using Multiplayer's trimmed-line/key matching semantics and require both server_url=127.0.0.1 and a valid chosen local match port. Both keys must be present; verify effective values after duplicate-key handling. Persisted staged fallback config must also point to that local endpoint. Refuse missing/malformed values; no official fallback. All mutation is inside staging.
- Positive connection evidence must show only loopback to the chosen match port for MP. Post-launch log inspection alone is insufficient; startup configuration/guarding must prevent an earlier official connection.

## P1 — runtime / path / Steam isolation
1. Read-only: document how Balatro/Lovely resolve profile, save, config, Mods and log paths, and Steam appid/cloud behaviour. No launch.
2. P1a: bootstrap a staged copy **without Multiplayer**; prove isolated paths, Steam/cloud/achievement isolation and zero-byte live install/AppData diff. Positively establish Steam user-stats/achievement APIs are disabled or unreachable, rather than just observing that nothing unlocked. Resolve the actual Steam user-data and remote-cache locations for app 2379780 read-only and record their before/after state too. Do not change global Steam settings or proceed if any check fails.
3. P1b: only after P1a passes, load staged Multiplayer with validated dead-loopback configuration and no official endpoint fallback; confirm no live writes.
4. Full P1 pass: zero-byte diff of the live install and `%AppData%\Balatro`; Steam achievements/cloud unchanged; two isolated runtimes coexist. P1a is the prerequisite for first staged Multiplayer startup; full P1 remains a prerequisite for a real practice match.
5. Do not claim P1 passed without this evidence.
6. Crash/cleanup fixtures: abort before startup, bot crash, human staged-runtime crash, local-server crash and launcher crash. Cleanup may affect only launcher-owned PID/start-time/path matches and declared staging files. Recheck live files/Steam state, release IPC/ports, preserve diagnostics and never kill another process by executable name alone.

## P2 — dead-port behaviour
- Source correction for pinned Multiplayer 0.5.5: `networking/socket.lua` uses a 10 s connection timeout and also defines up to three reconnect attempts with 2/4/8-second delays. Initial failure, connection closure and keepalive failure follow different paths; measure each applicable path rather than assuming there is no retry code.
- Pass: process stable, retries bounded to the actual source contract, no official endpoint fallback, no writes outside approved staged runtime data/log paths, no live writes. Record the observed attempts and timing; a fixture alone does not pass P2.

## P3 — parity (coverage matrix + fixtures)
- Coverage matrix: every `Client.send` action in `networking/action_handlers.lua` ↔ `main.ts` case ↔ client `HANDLERS`; record the commit-date gap.
- Fixtures: seed generation path; both-ready → `startBlind(firstPlayer)` (`actionHandlers.ts:173-215`); first-ready `speedrun` (`:178-191`); PvP resolves only when trailing/both out of hands (`:305-311`); tie with both at 0 hands costs no life (`:318,338-342`); leader out of hands while play continues; game-over path sends no `endPvP` (`:322-333`); tie-break via `firstReady` (`:254`); `failRound` and `failTimer` cost separate lives in one round (`Client.ts:108-121`); `failPvPTimer` when life loss is blocked (`:351-390`); reconnect.
- Seed fixtures also cover same-seed custom_seed, different_seeds -> nil, random_loadout with fixed BALATRO AI identity, and no restart/retry selecting a preferred outcome. Preserve explicit trusted pre-match fixed-seed tests.
- Reproducibility contract: identical pinned content/config/unlocks, seed, action trace and opponent/timing event schedule (including opponent-triggered RNG) produce identical canonical gameplay-state hashes at defined synchronization points. Exclude irrelevant wall timestamps/animation interpolation from hashes; document all nondeterministic inputs. A seed alone is insufficient for timing-sensitive match outcomes.
- Bind decision: documented minimal loopback bind patch (`main.ts:576`) + optional admin-port disable (`main.ts:739`); adjudication unchanged; no global firewall changes.
- Rate compliance: bot stays under 30 msg/s, burst 100 (`abuse.ts:49-50`; `main.ts:231-238`); note two clients share IP and connection id (`abuse.ts:111-138,214-215`).
- Pass: all fixtures green against the pinned server.

## P4 — observation / action audit
- Extractor reads only allowlisted fields (H2/H3); no filesystem/log access; no game-RNG draws.
- Test policy restrictions independently from extractor correctness: attempted access to G/MP/RNG state, filesystem, network, saves, Lovely/replay logs, server stdout/sqlite and arbitrary IPC must fail. Trusted extractor may access its expressly allowlisted engine fields; policy may not.
- Capture launcher-to-policy IPC and assert no seed/RNG stream or sensitive initialization/config fields reach it. Policy cannot issue lobbyOptions in ANY role; only trusted pre-match setup can configure rules/seeds. Post-start configuration is immutable.
- Test every projected UI field, including hidden cards/location, score/hands masks and capped timer values at 180, 9.95 and nil -> "0.0", matching upstream display semantics exactly.
- Reject stale, wrong-phase, insufficient-money, slot-overflow and otherwise illegal actions immediately before execution. Under maximum decision latency, verify the original timer continues updating and expiring without main-thread stalls. Timeout selects only a previously validated legal fallback or terminates safely.
- Outbound allowlist + phase guards: no pre-end `getNemesisDeck`/`getEndGameJokers` (`actionHandlers.ts:636-662`); no guest `lobbyOptions` (`Lobby.ts:337-346`); preserve legitimate runtime messages.
- Bot control over launcher IPC only; policy cannot `Client.send`/`MP.ACTIONS`.
- Pass: audit matches a human baseline; fixtures prove the two rejects.

## P5 — identity/config parity + hygiene
- Matching unlock state and Handy config (`Lobby.ts:308-311`); do not copy live progression while running.
- License/notice audit; gitignore staged copies, sqlite, logs and proprietary assets.
- Separate development seeds from held-out multi-seed acceptance benchmarks. Tune generic evaluation on development fixtures, never hard-code or memorize acceptance-seed outcomes; no seed identifier reaches policy. Keep raw benchmark logs outside policy access.
- Audit Steam, Lovely, SMODS, Handy and JokerDisplay startup/background/explicit network paths in addition to Multiplayer. Record exact versions, endpoints/call sites and the staged offline configuration or guard for each. Controlled startup/failure/action traces must show no non-loopback connection for the practice stack; explain and block any path that would otherwise contact official/ranked services. No global security or firewall changes.
