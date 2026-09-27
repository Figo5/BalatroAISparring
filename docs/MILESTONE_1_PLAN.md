# Milestone 1: companion scaffold

Owner: Astra. Architectural authority: INTEGRATION_PLAN.md and PROTOTYPE_GATES.md. Milestone 0 is user-accepted. All development stays in this repository. No live Mods copies, game launches, server launches, or game termination are authorized by this milestone.

## Scope

Build a real Steamodded companion mod, pinned to the reviewed Multiplayer 0.5.5 integration surface. Keep the existing two-staged-runtime topology. This scaffold does not implement a launcher, second runtime, transport, opponent, observation extractor, action executor, or AI policy. The AI flag expresses intent only; practice must remain inactive until later isolation and implementation gates pass.

## Acceptance checks

1. Valid Steamodded JSON manifest and Lua entrypoint; explicit Multiplayer requirement and deterministic load order after Multiplayer. Check metadata and loader semantics against the installed Steamodded source. A real game load remains pending if safe staged bootstrap is unproven.
2. Defensive, read-only dependency inspection checks identity, enabled/loadable state, exact supported version 0.5.5 and required structural surface. Missing, disabled, mismatched, or incomplete dependency fails closed with useful status. Distinguish compatibility of inspected surfaces from proven runtime/server parity.
3. AI mode defaults off. Requesting it cannot start practice, hook gameplay, connect, send protocol actions or change a human lobby. Normal single-player and human Multiplayer remain unchanged under the staging-only topology: the companion is never placed in the user's normal installation, and any enabled mod changes Multiplayer's reported mod list and hash.
4. Engine/Steamodded/global reads stay in narrowly scoped integration/composition code. Core modules consume injected primitive snapshots/interfaces. No gameplay in UI. No card/Joker/content registration or patches.
5. Preserve the future AIObservation boundary: no raw game globals, dependency objects, seed/deck order, logs, file/network APIs or runtime snapshots passed to policy. No pretend security sandbox or placeholder opponent.
6. Structured, bounded, allowlisted diagnostics; contain logger errors and bootstrap/module failures. Avoid secret, seed, user-path or arbitrary state dumps. Status returned to callers must not expose mutable internal state.
7. Automated tests exercise actual entrypoint/module code using Lua 5.1 and LuaJIT where available: success, dependency failure matrix, flag behavior, bootstrap failures and forbidden side effects. Fixtures model installed loader/Multiplayer shapes; report fixture limitations honestly.
8. Developer documentation explains layout, interfaces, test commands, dependency pin, failure states, flag semantics, future gates and no-live-install policy.
9. Astra independently inspects all implementation files and runs tests. Claude Opus 5.5 High reviews the actual diff and evidence. DeepSeek fixes valid findings, Claude re-reviews significant fixes. No unresolved critical/high finding at repository acceptance.

## Workflow and evidence

DeepSeek V4.1 Flash High is the primary implementation worker. Astra defines scope, verifies and owns Git history. Claude is the adversarial reviewer. Record exact worker models and reasoning settings, test counts, findings/dispositions, branch and commit. Milestone 2 does not start in this task. In-game loading/isolation are explicitly not proven by a fixture harness.
