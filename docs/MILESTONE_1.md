# Milestone 1 completion and acceptance

Date: 2026-09-27. Branch: `feature/ai-sparring-v1`. Base: `d09b910`.

**Astra accepts the repository scaffold after Claude's re-review.** Real Steamodded discovery/load and staged-isolation smoke testing remain pending. This acceptance does not claim a working AI opponent, passed prototype gates or in-game compatibility. Milestone 2 has not started.

## Implemented architecture

`AISparring/` is the standalone companion package, designed for Steamodded. Its composition entrypoint loads five focused modules: read-only host inspection, pure dependency validation, inert AI flag resolution, safe status construction and structured logging. Engine-facing inputs enter through composition/host code; other modules receive injected data. A status getter is attached only to the companion's verified own mod entry and returns primitive copies.

No UI, gameplay hooks, content/Jokers/cards, patches, transport, launcher, fake opponent, observation extractor, legal-action executor or policy were added. The reviewed two-staged-runtime/local-server topology remains authoritative and unimplemented. Future policy will consume only a reviewed human-visible AIObservation through restricted interfaces; no schema or sandbox is claimed here.

## Dependency and flag behaviour

- Manifest requires `Multiplayer (==0.5.5)` and uses priority `10000001`, after Multiplayer's `10000000`.
- Steamodded normally skips the companion entirely if this dependency is missing, disabled, unloadable or incompatible. No companion API exists when its entrypoint is skipped.
- Runtime checks defensively verify dependency identity, loadable/enabled state, exact version, required table/function shapes, lobby field types, Lovely install marker and post-bootstrap ACTIONS.connect function. Missing, mismatched, malformed or known partial-load states return fail-closed status. No Multiplayer method is invoked.
- `config.ai_enabled` defaults false and accepts only boolean true as intent. Even true leaves AI disabled with a gates-not-implemented reason.
- Compatibility means a structural snapshot taken at load, not ongoing connection health or rules/server parity.
- Diagnostics use bounded, escaped, allowlisted fields and safe version tokens. Logger failures are contained. No gameplay/seed/deck/log payload is passed to any policy.

## Test results and independent verification

Strict command: `python tests/run.py --require-all`, using Python 3.12.14 and lupa 2.8.

| Suite | Passed |
|---|---:|
| Static manifest/source/drift checks | 15/15 |
| Lua 5.1 behavioural cases | 51/51 |
| LuaJIT 2.1 behavioural cases | 51/51 |
| Unique cases | 66 |
| Total executions | 117 |

DeepSeek and Astra each ran the final strict suite successfully. Astra inspected the runtime source, fixtures, fix diff and actual installed Steamodded loader/config source. Seven additional independent source-contract/harness checks passed, separately from the counts above. Git whitespace checks passed. Evidence details are in ASTRA_M1_VERIFICATION.md.

Tests cover dependency failures, known partial startup, strict flag semantics, human-lobby inertness, bootstrap failures, throwing sinks, safe diagnostics, status-copy isolation, repeated loads and registry preservation. Fixtures are not an actual game or a complete sandbox. Registry regression checks are shallow, log-field coverage focuses on the ready path, and static source scanning is heuristic.

## Agent workflow and review disposition

- **Astra / Medium:** defined M1 scope and acceptance tests, inspected implementation, found and delegated initial correctness fixes, independently verified final code/tests and owns this acceptance/Git history.
- **OpenCode Go / DeepSeek V4.1 Flash / High:** implemented all scaffold modules, harness, tests and developer documentation, then corrected Astra and Claude findings. Verified provider/model ID: `opencode-go/deepseek-v4.1-flash`, variant `high`. The initial broad task exhausted its reasoning budget; smaller implementation tasks completed successfully without a model substitution.
- **Claude Code / Opus 5.5 / High:** reviewed the actual diff, architecture, safety, fairness, compatibility and test evidence. Original review found no critical/high issues and three required medium documentation corrections. DeepSeek fixed publication semantics, staging/hash implications and inaccurate load/config/copy claims.
- DeepSeek also addressed low findings with metadata drift checks, stored-status isolation, registry regression checks, broader static heuristics, log allowlist assertions, `--require-all`, and partial-Multiplayer detection.
- Claude re-reviewed the significant fixes and **accepted M1 with no critical/high/medium findings remaining**. See CLAUDE_M1_REVIEW.md and CLAUDE_M1_REREVIEW.md. Its missing-acceptance-document note is resolved by this file. One cosmetic low observation remains: the dependency-status `id` constant is not independently drift-checked, although the neighbouring manifest pin/version are checked. It is correct today and not a runtime defect or acceptance blocker.

## Files created

Runtime package (8):

- `AISparring/AISparring.json`
- `AISparring/config.lua`
- `AISparring/core.lua`
- `AISparring/src/ai_mode.lua`
- `AISparring/src/dependency.lua`
- `AISparring/src/host.lua`
- `AISparring/src/logger.lua`
- `AISparring/src/status.lua`

Automated tests (10):

- `tests/run.py`
- `tests/requirements.txt`
- `tests/lua/fixture.lua`
- `tests/lua/framework.lua`
- `tests/lua/runner.lua`
- `tests/lua/test_dependency.lua`
- `tests/lua/test_entrypoint.lua`
- `tests/lua/test_flag.lua`
- `tests/lua/test_host.lua`
- `tests/lua/test_logger.lua`

Documentation/evidence (6):

- `docs/MILESTONE_1_PLAN.md`
- `docs/DEVELOPER.md`
- `docs/ASTRA_M1_VERIFICATION.md`
- `docs/CLAUDE_M1_REVIEW.md`
- `docs/CLAUDE_M1_REREVIEW.md`
- `docs/MILESTONE_1.md`

Updated: `README.md`. Total: 24 created files and 1 updated file. Original integration/prototype plans and AGENTS.md remain unchanged. Reference sources, CLI transcripts and test dependencies stay in ignored/local work directories and are not distributed with the mod.

## Unresolved runtime evidence and live-game status

No blocking repository issue remains. Real Steamodded load, actual configuration persistence, the real mod-metadata effect, save/Mods/Steam isolation and complete in-game compatibility remain unverified. All prototype gates remain pending.

The companion is staging-only under this implementation. Multiplayer includes all enabled mods in its reported mod list/hash; installing the companion into a normal client would visibly change that metadata. No exemption is fabricated and no upstream checks are patched. A possible future installed menu requires separate compatibility/UX review under the accepted plan.

Balatro was running throughout the relevant checks. This task performed no live install/Mods writes, game or server launches, process termination, or game interaction. Handy, JokerDisplay and Multiplayer were preserved. A future smoke test must first meet the reviewed closed-game, backup and staged-bootstrap isolation gates; simply finding the live game closed would not by itself authorize a launch.
