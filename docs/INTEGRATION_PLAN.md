# Milestone 0 integration decision

Orchestrator: Codex / GPT-6 Astra / Medium. Date: 2026-09-27.

Status: Milestone 0 research direction accepted by the orchestrator after DeepSeek source inspection, independent checks, Claude review, corrections and Claude re-review. No critical/high documentation finding remains open. This plan supersedes the historical MILESTONE_0 notes. It authorizes no live installation or game launch. It does not claim a working simulator, mod or V1.

## Selected research direction

Build a separate companion and local launcher, using **two staged Balatro runtimes** (human practice and AI practice) and a pinned local legacy Multiplayer TCP server. Reuse the installed Multiplayer 0.5.5 rulesets, gamemodes, action handling, UI, card implementation and actual game engine in each runtime. Do not implement alternate scoring or swap globals in the human run.

The user's normal installation remains independently updateable. Neither its Multiplayer .env nor its saved server setting may be redirected. Staging is a local development copy, never distributed with proprietary Balatro files. All experiments remain outside live Mods.

The launcher is the initial explicit practice entry point. A future installed AI Sparring menu may launch the staged human session, subject to a supported process-launch mechanism and later UX review; it must not silently switch the live client's transport or automate human gameplay. This is a deliberate maintainability compromise, not completion of the preferred in-game VS AI flow.

## Why this route

- Installed Multiplayer owns one game state and receives opponent summaries. It has no second game engine to instantiate.
- Ghost mode has recorded scores and a separate resolver; it is not a faithful live opponent authority.
- MultiplayerAPI 1.0.0 has a genuine local lobby but only self-dispatch and no bridge to legacy Multiplayer 0.5.5 or a second game engine. Do not add it to V1.
- Multiplayer's .env transport override is read before its unconditional networking startup and persists for the process. It is appropriate only inside each disposable staged practice copy.
- The pinned upstream server already handles lives, readiness, comparisons, ties and terminal events. Its version string does not establish equivalence with the deployed 0.5.5 server. Contract tests and source coverage must resolve this uncertainty before claiming rule parity.

## Boundaries and ownership

| Component | Owns | Must never receive/do |
|---|---|---|
| Launcher | Stage manifests, endpoint selection, process lifecycle, trusted match seed/config, private local control IPC | Modify live server settings, choose seeds based on results, launch before isolation gates |
| Local match server | Original upstream match adjudication and seed behavior | Bind to LAN/WAN, official/ranked submissions, policy decisions |
| Human staged runtime | Human inputs and its own real game/MP state | Bot action automation, share its private state with policy |
| AI staged runtime | Real engine/RNG/timers, trusted observation extractor, legal-action executor | Let policy access globals, arbitrary network APIs or private state |
| Policy worker | Versioned AIObservation, legal choices, bounded evaluation/search, independent decision noise | Game seed/RNG state, hidden ordered deck, logs/saves, full runtime snapshots, arbitrary filesystem/network access |

This is an information boundary for trusted purpose-built local software, not a claim to sandbox arbitrary hostile third-party Lua. Policy runtime isolation must nevertheless be tested; a data schema alone cannot prevent access to globals or files.

No custom Multiplayer moddedAction control channel: it relays through the rival client. Use separate launcher-owned local IPC with bounded messages, session IDs and phase/sequence validation. Human and bot runtimes maintain independent state, files, event queues and game RNG.

## Rules, fairness and transport

Resolve actual lobby defaults, selected ruleset, forced options, active layers, gamemode bans, deck and stake before taking a configuration snapshot. Major League uses Attrition, its Bloodstone rework, no standard layer, no hidden-until-played score setting by default, and disabled opponent location. These observations are evidence, not companion constants.

AIObservation is a projection of human-visible information under that snapshot. A wire message is not permission to reveal its fields. Project score/hands/timer using the UI's masking, readiness, animation/display precision and threshold rules. Major League's hidden opponent location may expose only the legitimate timer-action eligibility it causes. Exclude inactive pvpTimerOrder, raw real_score/last_timer, mod hashes, hardware identifiers, private spending and any hidden face-down identity. Allow legitimate displayed timer data after threshold/rounding projection; do not exclude all timer information merely because the backing field is private.

Only the trusted extractor reads permitted engine fields. Policy cannot read Lovely/replay logs, server stdout/sqlite, seeds or raw game globals. Search uses observation-consistent beliefs, not hidden-state clones. Candidate values are predictions; only real legal game actions and original scoring determine results.

The trusted executor revalidates phase, resources, card IDs, slots and action legality immediately before normal game callbacks. Policy has no Client.send or MP.ACTIONS capability. Audit and gate runtime protocol traffic by phase and role, including pre-end full-deck/Joker requests and guest lobbyOptions. Preserve legitimate messages required by the original flow. End-game private payloads still do not enter policy observations for future decisions.

Normal random matches retain server-generated seed semantics. Fixed-seed user/harness runs select one seed before the match via original same-seed custom_seed behavior. No policy-selected seeds, outcome-dependent rerolls or rewinds. Seed is trusted initialization data only; difficulty never changes gameplay RNG. BALATRO AI identity is fixed. Both staged clients require matching content hashes, unlock state and relevant Handy/MP settings. Same seed is not a promise of identical offers after divergent choices or opponent-triggered RNG.

Preserve actual timer implementation: countdown/expiry are client-local, failure reports cause server life deduction. Major League's legacy timer is not a generic PvP countdown. Run policy computation off the game main thread or in strictly bounded yielded work, without stopping timer updates. Pacing does not draw gameplay RNG; reproducible timing-sensitive results also require a fixed/replayed event schedule. Ready timing and protocol rate limits belong in pacing, not hidden RNG or score advantages.

## Minimal server adaptation

Keep upstream adjudication unchanged. A documented small staging patch may change the hard-coded 0.0.0.0 listener to 127.0.0.1 and disable the unused admin listener. Do not describe this as an entirely unmodified server. No machine-wide firewall mutation is planned. Pin and attribute the GPLv3 source and record exact changes before distributing any adaptation.

The launcher must validate both local endpoint configurations before loading Multiplayer, refuse missing/mismatched configurations, and verify actual connection logs/traffic. Post-launch log checking alone is not sufficient protection against an earlier connection. Add a startup guard if configuration validation cannot prove fail-closed behavior. Audit Steam, Lovely, SMODS and compatibility mods separately; inspecting Multiplayer's socket does not prove the entire stack is offline.

## Required prototype gates

1. **Static isolation investigation:** identify native game/Lovely save, profile, Mods, logging and Steam/cloud behavior without executing the game. A copied executable is not evidence of isolation.
2. **Controlled bootstrap proof:** only after Balatro is closed and fresh verified backups exist, test harmless startup/path redirection before loading Multiplayer. Record before/after hashes of live install and all live Balatro AppData; require zero changes. Establish Steam achievements/stats/cloud isolation. If a safe bootstrap cannot be established, do not launch staged Multiplayer.
3. **Local startup:** only after bootstrap isolation passes, load staged clients. Prove loopback-only endpoints, dead-port failure behavior, separate data directories, no live writes, and cleanup after crashes. Do not kill or restart the user's game.
4. **Server parity:** build a complete send/handler coverage matrix, pin commit dates and differences, test seed paths, readiness, leader/trailer exhaustion, ties, terminal events, round/timer blockers, and rate limits including two clients on one IP. Deployment parity is unproven until evidence establishes it.
5. **Observation/action proof:** field-by-field visible/hidden fixtures, no RNG consumption in extraction, restricted policy environment, stale/illegal action rejection, protocol allowlist and complete bot action trace. Preserve human action ownership.

Only research and non-game contract work may proceed while Balatro is running. The remaining build milestones follow these gates and the requested DeepSeek -> Astra verification -> Claude review -> DeepSeek fixes -> Claude re-review cycle. A successful research review does not waive runtime proof or the 30 V1 acceptance criteria.

## Review disposition

- C1: adopt both-staged topology; prohibit live .env/config redirection.
- H1: make isolation evidence a prerequisite for staged Multiplayer; distinguish initial safe bootstrap experiment from proven isolation.
- H2/H3: human-visible projection and restricted policy boundary, not raw wire/global access.
- H4: separate control IPC, trusted executor and role/phase protocol audit.
- H5: correct custom-seed condition; retain required fixed-seed reproducibility through trusted pre-match configuration rather than forcing every match random.
- M1-M6: client-local timers, expanded parity fixtures, version uncertainty, documented bind patch/rate tests, unlock parity, scoped offline claims.

Supporting source analysis: DEEPSEEK_M0_RESEARCH.md. Original reviewer findings: CLAUDE_M0_REVIEW.md. Re-review and scoped acceptance: CLAUDE_M0_REREVIEW.md. Detailed prototype evidence checklist: PROTOTYPE_GATES.md, including the re-review amendments. Every prototype remains unrun.
