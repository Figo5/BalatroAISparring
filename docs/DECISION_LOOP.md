# Production broker authority and injected-port decision loop

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded production-enablement chunk, fixture-verified only. No live game,
no Mods write, no network, no external AI call, no policy in the game VM.

Owned by this chunk:

- `AISparring/integration/action_broker.lua` — production capability registrar and
  cancel/revoke (the legacy M2 factory path is preserved).
- `AISparring/integration/decision_loop.lua` — nonblocking, injected-port loop.
- `tests/run_decision.py` + `tests/decision/*` — static + Lua 5.1 / LuaJIT fixtures.
- this document.

It does **not** modify `AISparring/ai/*`, `state_reader.lua`, `engine_adapter.lua`
or `production_executor.lua` (owned by other workers) and it does not run the game.

## 1. Production capability registrar

The legacy constructor is unchanged in meaning:

```lua
local broker, code = ActionBroker.factory(observation, actions, ports)
```

`factory` is production-disabled. Real dispatch runs only when
`ports.fixture == "M2_FIXTURE_ONLY"`; any other value — including a boolean
`true`, `mode = "M3_PRODUCTION"` or `production = true` — leaves the broker
disabled and `submit` returns `broker_executor_disabled` without calling
`ports.dispatch`. The engine-suite `test_broker_gap.lua` regression still holds.

Production enablement is a **separate** path:

```lua
local authority, code = ActionBroker.production_factory(verifier)
local capability       = authority.mint()
local broker, code     = authority.authorize(observation, actions, ports, capability)
```

- `production_factory(verifier)` requires a **function** `verifier(ports, capability)`
  and returns a private broker authority. A non-function is refused
  `broker_bad_verifier`; an authority built this way is only reachable by code
  that already runs inside the staged runtime.
- `authority.mint()` returns a fresh capability: an opaque table whose protected
  metatable is the module-private `AISparring.ActionBroker.capability` tag. It is
  an **identity object**, not a string, boolean or JSON value. It is not
  serializable (the codec refuses metatables) and it is never passed to policy or
  transport.
- `authority.authorize(observation, actions, ports, capability)` accepts only a
  capability minted by **this** authority, rejects a revoked one, validates the
  observation/actions/ports interfaces, refuses a ports table that still carries a
  fixture sentinel, requires `ports.dispatch`, and then calls the trusted
  `verifier`. Only `verifier(...) == true` (pcall-clean) authorizes; a false,
  missing or throwing verifier is refused `broker_verifier_rejected`.
- `authority.revoke(capability)` marks the capability revoked and clears the
  pending token on every broker created from it. `authority.revoke_all()` revokes
  every capability. `authority.describe()` reports only counts and bounded codes.

### 1.1 Who may mint a capability

Only the trusted staged bootstrap may construct the authority and mint the
capability — the same in-process code that owns the real engine adapter, the
ports triple and the verifier closure. A capability is **not** derived from a
role string, a JSON boolean, a session credential received over transport or any
policy input. Policy, the policy worker and the transport never see it.

This is **not a sandbox**. Any code that can already call
`ActionBroker.production_factory` could mint its own capability and verifier; the
capability is provenance that keeps production dispatch from being switched on by
a misrouted role string or wire boolean. There is no security claim against
arbitrary trusted local game code, and no claim of process/memory isolation.

### 1.2 Production dispatch semantics

The submit trust phase is unchanged (token identity, immediate single-use
consumption, fresh atomic capture, epoch/canonical equality, `actions.validate`
membership, `ports.validate == true`, post-validation recapture and reentrancy
checks). On top of that:

- Production dispatch requires the callback to return **explicitly `true`**. A
  `false`, `nil` or throwing `ports.dispatch` is `broker_dispatch_failed`, never a
  silent success. (Fixture mode keeps its legacy pcall-only behavior.)
- Revocation is re-checked immediately before dispatch; a revoked broker returns
  `broker_revoked` and never dispatches.
- `broker.cancel()` invalidates the pending token (`broker_canceled`, or
  `broker_no_pending`); a later submit of that token is `broker_token_unknown`.
- `broker.revoke()` revokes that broker; `broker.is_revoked()` reports state.
- `broker.issue()` now returns a third value: a bounded
  `meta = { epoch, candidate_count }`. Existing two-value callers are unaffected.

New bounded codes: `broker_bad_verifier`, `broker_verifier_rejected`,
`broker_bad_capability`, `broker_revoked`, `broker_canceled`,
`broker_no_pending`. All M2 codes and tests are preserved.

### 1.3 Port snapshot, executor pending latch and authority close

- **Port snapshot.** At authorize time a production broker copies `capture`,
  `validate` and `dispatch` out of the ports table the verifier approved. A later
  swap of the ports table cannot redirect an already authorized broker. The legacy
  disabled/fixture factory keeps dynamic access, so the M2 boundary behaviour (a
  swapped or metatable ports table is an internal error) is unchanged.
- **Executor pending latch.** The broker passes through three explicit allowlisted
  port codes instead of collapsing them to `broker_capture_failed`:
  - `exec_pending` — the executor's committed-action latch ("a committed action's
    visible effect has not appeared yet"). The loop treats it as a bounded
    transient wait, short of a terminal fault.
  - `exec_stall_timeout` and `exec_revoked` — the executor's **terminal** faults
    (`production_executor.lua:691-701`). They are passed through so the loop can
    stop immediately and revoke; they are never counted as a transient wait.

  Every other port code still collapses to a fixed broker code
  (`exec_control_required` and adapter-unsupported states remain
  `broker_capture_failed`).
- **Committed dispatch reentry.** If `ports.dispatch` reenters the broker, a
  dispatch that already returned explicit `true` is still reported as committed
  (`true, broker_ok`); it is never downgraded to `broker_reentrant`, which would
  invite a duplicate retry. Pre-commit reentry (during capture or validate) is
  still rejected `broker_reentrant`.
- **Revocation and authority close.** `broker.revoke()` is required by the loop.
  `authority.revoke_all()` also **closes** the authority: a later `mint()` returns
  `nil, broker_revoked`. Terminal match stop revokes the broker too.

### 1.4 API delta for the runtime bootstrap worker

The runtime bootstrap is owned elsewhere and is still being finalized. When it
wires the loop it should pass:

- `get_revision = function() return revision.current() end` so the decision log
  records the real post-action revision (`result_epoch`) rather than nothing.
- `wait_state` bound to the authorized runtime's verified-wait probe (the
  authoritative MP timer/heartbeat) so a genuine opponent wait is never
  deadline-aborted by the loop.
- `timeout` **larger than the service's worker timeout** (see §2.6). The service
  times a decision out at 10s; the loop must wait longer (recommended 15s) so a
  slow decision is cancelled-and-reissued by the service's own timeout instead of
  the loop giving up first and permanently occupying the service decision slot.
- optionally `controls.refresh` if the adapter exposes an explicit refresh call
  (otherwise the loop refreshes through `broker.issue` → capture, which is
  sufficient because `controls.next` is `executor.last_control_state()`).

No bootstrap change is *required* for the control/transient defaults to be safe:
the loop already respects the control cooldown, defaults `exec_pending` to
transient and stops immediately on `exec_stall_timeout`/`exec_revoked`. The hooks
above make the wait, cancel and logging semantics explicit.

## 2. Decision loop

```lua
local loop, code = DecisionLoop.factory(options)
loop.update() -> status, loop_code
loop.stop(reason) ; loop.is_stopped() ; loop.is_terminal()
loop.pending_sequence() ; loop.stats() ; loop.describe()
```

Injected trusted ports (every side effect):

| option | requirement |
|---|---|
| `broker` | production broker: `issue`, `submit`, `cancel`, `is_revoked` |
| `transport` | `request(payload) -> request_id`; `poll() -> response|nil`; optional `cancel(request_id)` |
| `clock` | `now() -> monotonic seconds`; optional `tick()` for logging |
| `logger` | optional `record(fields)` trusted local logger |
| `checksum` | optional `checksum(observation) -> bounded string` |
| `get_revision` | optional `get_revision() -> int` post-decision revision reader (or a broker `receipt()`); never the pre-issue epoch |
| `wait_state` | optional `wait_state() -> bounded string|nil`; a non-nil trusted token means the runtime is verified-waiting (e.g. the authoritative MP opponent timer/heartbeat) and the loop must not deadline-abort that wait |
| `controls` | optional `next() -> name|nil`, `advance(name) -> true|code`, optional `refresh()` |
| `pacing` | seconds between a valid response and `broker.submit` (dispatch schedule only); must be `< timeout` |
| `pacing_mode` | `"instant"` or `"normal"`, recorded in the log only |
| `min_interval` | minimum seconds between transport requests (rate cap) |
| `timeout` | per-request response deadline (seconds) |
| `transient_backoff` | cooldown after a transient or empty-action state (default `0.25s`) |
| `transient_codes` | extra broker codes treated as bounded transient waits (merged over the default set) |
| `fatal_codes` | extra broker codes treated as terminal faults (merged over the default `exec_stall_timeout`, `exec_revoked`) |
| `max_transient_streak` | secondary guard: consecutive transient waits before abort/revoke (default 1200) |
| `max_transient_seconds` | primary guard: wall-clock seconds of unbroken transient waits before abort/revoke (default 120) |
| `wait_max_backoff` | cap for the WAITING_FOR_OPPONENT poll backoff (default `1s`) |
| `no_action_max_backoff` | cap for the `policy_no_action` same-epoch exponential backoff (default `2s`) |
| `control_latch_seconds` | wall-clock deadline for a latched trusted control that never clears (default 30; 0 disables) |
| `max_consecutive_errors` | abort/revoke threshold for non-transient errors |
| `terminal_phase` | default `MATCH_COMPLETE` |
| `sequence_start` | first decision sequence (default 1) |
| `on_stop` | optional trusted stop hook (bounded reason/code) |

`update()` performs one bounded step and returns immediately: it never blocks,
never advances any engine timer, never runs policy in the game VM, holds no RNG
and references no engine globals. It reaches no `G`/`MP`/`SMODS`/`Client`/`io`/
`os`.

### 2.1 Request and response contract

The request payload is exactly `{ sequence = <int>, observation = <sanitized export> }`.
It contains **no** actions, candidates, seed, session, source, config or private
token; the service regenerates legal actions from the observation. The broker
token stays private inside the loop.

A response is `{ sequence, ok, action?, reason?, code? }`. The loop acts only on an
**exact sequence match** with its single outstanding request. A different sequence
is dropped (`loop_out_of_order`) and a replayed response for a consumed sequence
can never dispatch twice. `ok == false` or a malformed action is a bounded
transport-side rejection, logged as a rejection record. `ok == false` with
`code == "policy_no_action"` is different: it is the policy's legitimate "no legal
choice" result, so the loop backs off like the empty-action state
(`loop_policy_no_action`) and never counts it toward the fatal error budget
(`stats().no_action`). Because the policy is deterministic, an unchanged decision
epoch would return the same answer, so the cooldown **doubles while the epoch is
unchanged** (capped at `no_action_max_backoff`, default 2s) instead of re-asking
every 0.25s. The throttle resets on observable progress (a committed action, or a
changed epoch), so a future state change is never stalled.

### 2.2 Pacing, timeout, terminal and empty states

- Pacing defers `broker.submit` until `now + pacing`; `update()` returns
  `"scheduled"` and the caller-level loop keeps running (no blocking, no clock
  mutation). `pacing` must be strictly less than `timeout`, otherwise the factory
  refuses the configuration with `loop_bad_options`.
- Once a valid response is scheduled, the request timeout and polling are both
  suspended: the deadline is measured from `request_sent_at` and a scheduled
  submit always resolves before it, and a late duplicate response cannot overwrite
  the scheduled action or reset its submit time.
- A response that never arrives past `timeout` is cancelled (`broker.cancel`,
  transport cancel) and reissued after a cooldown; repeated timeouts/errors
  revoke authority and stop the local match through the trusted `on_stop` hook.
- A **transient** capture failure at `issue` or `submit` (engine animation, a
  queued executor callback, the executor's `exec_pending` latch) is a bounded
  wait, not an abort: the loop backs off and retries without counting toward the
  fatal error budget, returning `loop_transient`. An unbroken transient streak
  becomes fatal only after `max_transient_seconds` of wall-clock time (the
  secondary `max_transient_streak` guard may fire first; the default backoff of
  `0.25s` makes the wall-clock window the practical bound).
- A **terminal executor fault** (`exec_stall_timeout`, `exec_revoked` — the codes
  the executor's `gate()` latches permanently) is *not* a transient. The loop
  stops at once (`stats().faults`), cancels the pending broker token and revokes
  the authority. `exec_pending` stays a bounded wait: it is the valid
  "committed action's effect not visible yet" latch, bounded by the executor's own
  stall window (10s default), so a legitimate animation is never mistaken for the
  fault that follows it.
- A failed trusted control advance (`controls.advance` returning a non-`true`
  code, e.g. `exec_element_missing` while the button is still animating in) is
  the same bounded transient wait, not a `loop_control_failed` that aborts the
  match after three frames. The retry respects `cooldown_until`, so the bound is
  wall-clock (or `max_transient_seconds`) rather than a frame-rate streak guard.
- Stale submissions (`broker_stale_epoch`, `broker_observation_changed`,
  `broker_epoch_regression`) are normal: the loop counts them, does not abort and
  reissues with a fresh sequence, so an A→B→A revision bump is handled safely.
- A terminal observation (`phase == terminal_phase`) ends the loop with
  `"terminal"`, revokes the broker authority and performs no request; the driver
  performs normal MP stop/leave.
- An empty candidate list is a transient state: the loop backs off (and doubles
  the cooldown if the same epoch repeats), never spins and never aborts.
- At most one request is outstanding, and `min_interval` caps the request rate.

### 2.3 Trusted control navigation

`controls.next()` is the trusted adapter's control state. In production it is
bound to `executor.last_control_state()`, which is **only refreshed by
`executor.capture()`** — so the loop must run the capture path, never sit on its
own latch. Only an explicitly allowed control name (`cash_out`) is acted on, via
`controls.advance(name)`, which the bootstrap binds to the executor's
`advance_ui`. Before engaging the transition the loop cancels the outstanding
decision (`abandon_pending`: transport cancel plus `broker.cancel`), so a queued
callback can never commit a stale token across the transition. The transition is
also gated on `cooldown_until`: if a recent capture/advance failed, the loop waits
out the backoff and falls through to the normal path instead of re-driving
`advance_ui` every frame. That keeps a stubborn cash-out (or any other control)
bounded by wall-clock time rather than the frame rate, and lets the trusted
capture refresh the control state on the next eligible step.

After a successful advance the loop latches the control name. While latched:

- it never arms a second deferred transition;
- it calls the optional `controls.refresh()` if supplied, then falls through to
  the normal decision path so `broker.issue` runs the trusted capture and updates
  `controls.next` (a still-required control re-surfaces as a transient capture
  failure, so there is no deadlock);
- once the capture reports the control is gone the latch releases; if the latch
  has been held longer than `control_latch_seconds` (and no verified `wait_state`
  is active) the loop stops with `loop_control_timeout` instead of hanging.

No arbitrary error is treated as a control, and readiness is not special-cased: a
PvP ready decision flows through the normal `SELECT_BLIND` action/broker path
(`mp_toggle_ready`), never a loop bypass.

### 2.4 Transient port contract

The trusted capture is allowed to be busy without failing the match. A capture or
submit that cannot proceed because the engine is mid-animation or because the
runtime executor has a queued/pending callback returns a bounded broker code.
Any code present in `transient_codes` is a **bounded transient wait**: the loop
cancels nothing irreversible (no dispatch happened), backs off by
`transient_backoff`, returns `( "idle", "loop_transient" )`, and does not
increment the fatal error budget. A non-transient result resets the streak; an
unbroken streak beyond `max_transient_streak` or `max_transient_seconds` aborts
and revokes.

Default transient codes: `broker_capture_failed`, `broker_generate_failed` and
`exec_pending` (the production executor's committed-action latch, passed through
by the broker — see §1.3). The trusted bootstrap may merge additional codes
through `transient_codes`; the loop assumes nothing about their names.

Distinct from those, a code present in `fatal_codes` (default
`exec_stall_timeout`, `exec_revoked`) stops the match immediately: the fault is
returned verbatim, the pending broker token is cancelled and the authority
revoked (`stats().faults`). The two executor codes are the difference between a
**valid pending wait** — a committed action whose effect is still animating, held
by `exec_pending` for at most the executor's stall window (10s default) — and the
**terminal fault** that the executor latches if that effect never arrives.
`exec_pending` therefore stays transient; only the fault ends the match.

A trusted `wait_state` probe that returns a bounded token marks a **verified
wait**. The bootstrap's probe (`RuntimeBootstrap.mp_wait_state`) reports
`mp_ready_blind` (the AI readied the PvP blind), `mp_pvp_no_hands` (the PvP blind
is open, the engine is still in the hand loop `SELECTING_HAND`/`HAND_PLAYED`/
`DRAW_TO_HAND`, and the AI has no hands left) or `mp_pvp_countdown`. The
hand-loop restriction matters: Multiplayer keeps the blind PvP through round
evaluation and clears `end_pvp` once the round moves on, so without it the wait
could hold through cash-out and the shop. It reads only the
AI runtime's own MP state, never the policy.

While the probe is non-nil the loop is in the explicit **WAITING_FOR_OPPONENT**
state (`loop_waiting_for_opponent`, status `waiting`):

- It never asks the policy. After a successful capture it cancels the token
  instead of sending a request. The terminal `MATCH_COMPLETE` check still runs
  first on every poll.
- It is not an error, a transient or a `policy_no_action`. It never adds to the
  error budget (nor resets the consecutive-error streak, because a wait is not
  progress), and the transient deadline never aborts it. A capture that fails
  during the wait (for example `HAND_PLAYED` after the last PvP hand) joins the
  same wait (`stats().transient_waiting` counts those).
- It polls with a doubling backoff that starts at `transient_backoff` and is
  capped at `wait_max_backoff` (default 1 s), so the opponent's arrival is seen
  within about a second.
- It logs one `wait_begin` record on entry and one `wait_end` record (with
  `waited_seconds`) on exit or stop. Nothing is logged per poll. `stats()` adds
  `waits`, `waiting_polls` and `waiting_seconds`, and `describe()` shows the
  current `waiting` token and `wait_backoff`.

Unknown stalls are still aborted within the bound when no trusted wait is
reported.

This is a deliberate behaviour change. While readied or waiting, the AI no longer
considers optional actions (selling, using consumables, reordering Jokers).
Before, the policy was asked and answered `policy_no_action` in every observed
case (native match 10). Multiplayer itself disables opening packs while readied.
A Multiplayer timer action for the waiting player does not exist yet (see the
PvP timer work).

The practice service also counts a `policy_no_action` answer separately
(`no_action` in the terminal summary) and no longer counts it as a failure or
`errors` (native match 10 reported 33 such "errors" at the PvP blind). The
policy environment also answers `policy_no_action` when a policy returns nothing
even though candidates existed (`tools/lua/policy_env.lua`). Such a policy defect
now appears under `no_action`, not `errors`.

### 2.6 Transport cancel semantics

The loop calls `transport.cancel(request_id)` when it abandons an outstanding
request (`abandon_pending`, a trusted control transition, a timeout, or a stop).
That call is **best-effort and asynchronous**: the loop does not block on it and
makes no assumption that the service has released its decision slot by the time
the call returns. The wire-level cancel (a `decide_cancel` keyed by sequence, or
letting a newer `decide_begin` replace a stale job) is owned by the practice
service and the runtime bootstrap; the transport contract here only requires that
`cancel` be safe to call and that a later `request` be independent.

The loop's local guarantee is that it **never retries the old token**: it drops the
local pending sequence, calls `broker.cancel` (which invalidates the opaque token),
and reissues with a **fresh** sequence. A late or replayed response for the old
sequence is dropped as out-of-order, and a submit of the cancelled token is
`broker_token_unknown`. Because the service's worker timeout (10s) and the loop's
`timeout` are independent, the bootstrap must set the loop `timeout` **above** the
service timeout (recommended 15s) so the service's own cancel/replace runs first
and a single slow decision cannot permanently occupy the decision slot.

### 2.7 Logging

The loop passes a bounded record to the trusted logger: `tick`, `phase`,
`checksum`, `candidate_count`, `selected` (`type`, `id`), `latency`, `reason`,
`issue_epoch` (the pre-issue broker epoch), `result_epoch` (the post-decision
revision from `get_revision`, or `nil` when no reader is injected — the pre-issue
epoch is never relabelled as the post-action version), `result_code` and
`pacing_mode`. Response rejections, stale submissions, timeouts and dispatch
failures are logged as rejection records (`selected == nil`). Seed and session
are supplied outside the loop logger; the loop never receives them.

## 3. Tests

`python tests/run_decision.py --require-all` runs static checks and every
`tests/decision/test_*.lua` under both `lupa.lua51` and `lupa.luajit21`. The real
M2 codec/observation/actions, the real broker and the real loop are loaded; only
the async transport and clock are fake. `tests/decision/test_pipeline.lua` goes
further: it builds the real StateReader / EngineAdapter / ProductionExecutor over
the synthetic engine fixture and drives the real broker and loop end to end.
Coverage:

- default factory still production-disabled with production-style ports, while the
  fixture sentinel still dispatches;
- production authorize/dispatch, explicit-`true` requirement, token single-use,
  stale epoch, validator rejection, port snapshot at authorize time, `exec_pending`
  pass-through, `exec_stall_timeout`/`exec_revoked` fatal pass-through, an
  unlisted port code still collapsing, committed-dispatch reentry reports success,
  pre-commit reentry still rejected;
- forged capability, cross-instance capability, verifier rejection/throw,
  non-function verifier, non-serializable capability, fixture-sentinel ports,
  missing dispatch port;
- authority revoke before submit, broker cancel, `revoke_all` and authority close
  against a new `mint`;
- request payload shape (only `sequence` + `observation`, no hidden fields, no
  functions), pacing without blocking, `pacing >= timeout` rejected, scheduled
  submits skip timeout and polling (duplicate responses cannot overwrite them),
  out-of-order and replayed responses, timeout/error abort with revocation,
  error-then-success recovery, `policy_no_action` same-epoch exponential backoff
  to the cap, reset on epoch change and on commit, stale A→B→A reissue, terminal
  stop revokes, empty-state backoff without spin, request rate cap;
- control navigation via injected advance only, unknown control ignored, latch
  refresh through capture (no deadlock) with a self-sticky controls fake, latch
  release after refresh, bounded failed-advance waits, a 15s/144 FPS failed-advance
  run bounded by wall clock rather than the frame-rate streak guard, wall-clock
  transient bound, verified `wait_state` holding the window open;
- response-rejection and dispatch-failure logging, post-decision revision logging
  from an injected reader, bounded transient capture waits, transport
  request/poll faults, no engine globals;
- a full real-pipeline cash-out (stale latch → refresh → progress), a real
  `PLAY_CARDS` dispatch through the broker, the executor stall fault stopping and
  revoking the match, and an 8s/144 FPS valid pending-commit wait that does not
  trip the fault or the transient guard.

Fixtures are not real-engine evidence; the live adapter/executor wiring remains a
launcher prerequisite.

## 4. Honest non-claims

- The loop is not wired to the mod startup, the adapter or the launcher here.
- The capability is in-process provenance, not isolation, and not a defence
  against arbitrary trusted local code.
- No live game, staged runtime, Mods write, IPC, process control or policy
  subprocess is exercised by this chunk.
