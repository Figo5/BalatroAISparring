# Runtime integration contract for the playable slice

Status: implementation contract; requires actual-diff Claude review and runtime evidence. This elaborates the accepted topology, not a substitute architecture.

## Process ownership

The launcher owns a session identifier, two distinct role credentials, a loopback match endpoint, a separate loopback control endpoint, and exact child PID/create-time/image records. No credential or match seed enters policy input. Both game runtimes use the real staged engine and identical pinned mod/content/unlock configuration, with independent files and Lua globals. The AI uses the fixed public name BALATRO AI.

Bootstrap, copy, installation and practice launch all retain the closed-game gate. The first build uses the simpler transition proposed in `CLAUDE_PLAYABLE_STAGING_REVIEW.md`: an independently running external launcher accepts a confirmed main-menu request; the UI explicitly asks to quit Balatro and start isolated practice, then invokes normal game quit only after a valid launcher acknowledgement. The launcher waits for the exact live process to exit naturally and repeats all closed-game checks before spawning staged roles. A timeout aborts; it never terminates the live game. There is no concurrent-live mode. The user's currently running game is not part of this automated transition and must remain untouched during development.

The launcher must retain exact process and Job Object handles and remain alive to supervise the session. Returning only a JSON process record and exiting would close kill-on-close jobs immediately. Cleanup revalidates image and creation time on the same native process handle it terminates, avoiding a PID-reuse gap.

## AI decision loop

Only the authenticated AI staged runtime loads engine adapter/executor/control modules. Human runtime gets session coordination and ordinary MP behavior, with no action automation. Live companion gets menu entry only. A role string alone is insufficient provenance: staged early bootstrap binds verified paths/configuration, session credential and launcher handshake before any production capability exists.

Capture uses the trusted adapter → reader → immutable observation, then broker.issue. Send only exported observation plus an opaque decision sequence to the launcher-owned policy service. The service selects repository-owned baseline source for the trusted difficulty and invokes the existing restricted policy worker in a separate process with hard timeout/output bounds. It must not accept arbitrary source supplied by a game client. No seed, raw state, authority token, logs or initialization configuration enters that worker. The human role cannot submit AI decisions.

The game main thread remains responsive; use bounded nonblocking control transport or a LÖVE thread. At response time, look up the private pending token by exact sequence and submit through the broker. Revalidate immutable observation, revision, candidate membership and actual callback prerequisites immediately before dispatch. Cancel outstanding work on state changes, transitions, timeout, session failure or completion. Never replay a consumed token, dispatch on timeout without validation, or pause actual MP timers while calculating or pacing.

State revision must detect relevant transitions including A→B→A through trusted hooks, not merely repeated final snapshots. Reject/cancel on any uncertain transition. Default broker remains disabled; production authorization must be an in-process trusted capability, never `fixture = M2_FIXTURE_ONLY` or a received JSON boolean. Successful pcall is insufficient: dispatch rejection must propagate explicitly. Successful deferred callbacks also require a pending-action latch: a new decision cannot buy/use/reroll the same object before its queued effect completes. Release requires an appropriate real transition, not the executor's own revision bump; stalled effects stop safely after a bounded deadline.

## Match orchestration

Human staged client hosts via original Multiplayer callbacks, selecting the actual majorleague ruleset and forced Attrition mode/options. AI staged client joins that local lobby through the private launcher control channel. Start only after both clients confirm matching configuration/content. Do not use moddedAction for private coordination. Do not direct any lobby/user/result traffic to official services. Freeze selected ruleset/config after start; policy cannot issue transport/config actions.

Normal mode uses original random seed behavior. Gauntlet chooses one fixed seed before match via original same-seed/custom_seed configuration. Five neutral seed identifiers must remain stable; category names are test intentions, not claims about searched favorable outcomes. Seed selection never depends on a previous result, and seed is never a policy feature.

Opponent HUD remains original public Multiplayer UI. Major League hides location; no extra phase/private score reveal. Use actual timer eligibility/display semantics. Trusted cashout navigation is permitted only when there is no gameplay choice and the real button is available. Blind readiness remains a validated SELECT_BLIND operation invoking the actual MP ready button.

## Errors, pacing and diagnostics

Instant/Normal pacing is a dispatch schedule independent of gameplay RNG; never modify the game clock or timer update frequency. Every decision logs local timestamp/tick, seed in trusted logger only, match/ruleset/difficulty, phase, observation checksum, candidate count, selected action, bounded reason, latency, post-action revision and rejections. No full state dump by default. Log compact end summary with result, lives, ante/round, duration and counters.

Actual pinned Multiplayer terminal signals are `MP.GAME.won` for a win and engine `GAME_OVER` for a loss. A win must stop the policy even if the engine stays outside `GAME_OVER`. Ordinary timer consumption can cost a life while play continues; do not turn a consumed regular timer into a permanent action prohibition. Preserve the original timer update and server adjudication.

On policy/adapter/transport failure, revoke authority and stop the local match through normal MP stop/leave flows, show a useful error and preserve diagnostics. Cleanup may terminate only exact launcher-owned processes. Never act on the human's run, kill by executable name, modify live transport, overwrite saves or leave an orphaned bot posting actions after session shutdown.
