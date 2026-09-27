# Astra verification: Milestone 1 candidate

2026-09-27. Candidate based on d09b910, branch feature/ai-sparring-v1. Initial evidence and post-review verification are recorded below; final acceptance is recorded in MILESTONE_1.md.

## Independent verification

- Inspected every runtime source and the Python/Lua harness. Runtime consists of a Steamodded composition entrypoint, injected read-only host inspection, pure dependency/flag/status modules and structured logging. Only the own mod entry receives a status API. No content registration, gameplay hooks, Multiplayer method invocation, transport, launcher, opponent or policy implementation.
- Independently executed `tests/run.py` with Python 3.12.14 and workspace-local lupa 2.8: 11 static checks plus 45 Lua cases on each of Lua 5.1 and LuaJIT 2.1, **56 unique cases / 101 executions, all passed**. Full named output retained outside Git in workspace work/toolchain/astra-m1-tests.txt.
- Checked installed Steamodded 26.829.0 `src/preflight/loader.lua`: JSON required fields and `==` operator at lines 138-184; config_file default at 223; ascending priorities and load/config sequence at 734-783; SMODS.load_file(path,id) at 873-896. Manifest's Multiplayer exact pin and priority 10000001 agree with these semantics and Multiplayer priority 10000000.
- Read installed Steamodded `src/ui.lua:1656` independently: `SMODS.load_mod_config` executes mod-local config.lua into default_config, assigns mod.config and merges persisted config. The scaffold's config.ai_enabled access matches this source. This is source verification, not a real-game config test. No saved config was read.
- Pinned Multiplayer `core.lua` establishes `MP = SMODS.current_mod` and the inspected surface (LOBBY/GAME/ACTIONS/MOD_ACTIONS and functions). Checks do not invoke these functions or inspect private gameplay data. They establish a load-time structural snapshot only.
- Balatro was running (live executable, PID 7676). No live file writes, game/server launches, copies into Mods, process termination, or game interaction were performed. Existing Handy/JokerDisplay/Multiplayer remain untouched by this task.

## Findings corrected before Claude review

DeepSeek corrected Astra's initial findings: config flag field, actual MP identity comparison, primitive snapshot normalization, full bootstrap error containment, persistent own-mod status getter, misleading active status, invented future observation allowlist, and unescaped/raw version diagnostics. Further tests cover an existing human lobby with AI intent true, throwing sinks, repeated bootstrap, unrelated current_mod and publication failures.

## Compatibility limitation requiring explicit documentation

Pinned Multiplayer `lib/matchmaking.lua:14-34` enumerates every non-disabled SMODS.Mods entry into mod metadata and hashes; it has no cosmetic-mod exemption. Therefore installing any enabled companion can change Multiplayer's mod-list/hash diagnostics even without hooks. Do not claim identical human-Multiplayer metadata after a hypothetical live install. The accepted **staging-only** topology preserves the normal installation; do not patch or conceal upstream hashing. Future paired staged clients require matching companion versions, consistent with the accepted plan. No topology change is proposed.

## Documentation points for review

The developer guide currently says an unavailable/unrelated own mod yields closed status; code actually returns its computed bootstrap result without publishing. A caught publication error similarly does not convert the return value to closed. These descriptions need alignment. The guide's config-source limitation can now distinguish independent source verification above from still-pending actual engine tests. Copying uses a depth bound, not true cycle detection; no cyclic state is constructed by the scaffold.

## Pending evidence

Real Steamodded discovery/load, runtime side effects, staged save/Mods/Steam isolation and compatibility under a real game are untested. No prototype gate is passed by these fixtures. The scaffold cannot enable AI even if the flag is true. No Milestone 2 implementation is authorized here.

## Post-review verification

- Claude Opus 5.5 High reviewed the actual diff and returned no critical/high findings. Its three required medium documentation findings were sent to DeepSeek, along with selected low findings. See CLAUDE_M1_REVIEW.md for the original review.
- DeepSeek corrected all required documentation findings and added status-return isolation, registry regression checks, strict runtime availability mode, metadata drift checks, broader static heuristics and read-only checks for Multiplayer's Lovely marker and ACTIONS.connect function. The latter rejects the known early-return path at Multiplayer core.lua:287-306; no method is called and no transport readiness is claimed.
- Astra independently inspected the fix diff and ran `python tests/run.py --require-all`: **15 static checks + 51 Lua cases on each runtime = 66 unique cases / 117 executions, all passed**. Full output is in workspace work/toolchain/astra-m1-final-tests.txt. Both runtimes were required and available.
- Seven additional independent checks passed: the actual installed load_mod_config function, extracted into an isolated synthetic NFS environment, handled default, saved-true and malformed saved config under both runtimes; the test harness rejected zero executed cases. Only source text and in-memory synthetic config were used. No user saved config was read. Script/output remain outside Git in workspace work/astra_m1_contracts.py and work/toolchain/astra-m1-contracts.txt.
- Git whitespace checks passed. INTEGRATION_PLAN.md, PROTOTYPE_GATES.md and AGENTS.md remain unchanged. The milestone plan received only the reviewed staging-only compatibility qualifier.
- Worker session export confirms OpenCode provider opencode-go, model deepseek-v4.1-flash, variant high. Claude result metadata confirms claude-opus-5-5; invocation used --effort high. No model substitutions.
- The earlier documentation discrepancies above are resolved in the final developer guide. Remaining test limits: synthetic host, shallow registry regression assertions, heuristic source scans, no policy sandbox and no real-game load. These are not claims of complete hostile-code isolation or in-game parity.
