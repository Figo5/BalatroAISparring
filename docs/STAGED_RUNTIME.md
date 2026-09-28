# Staged runtime integration (`AISparring/integration/runtime_bootstrap.lua`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded implementation of the staged human-host + AI-guest runtime wiring
(`docs/PLAYABLE_RUNTIME_CONTRACT.md`, `docs/INTEGRATION_PLAN.md`). Fixture/static
verified only. No game launch, no Mods write, no live install, no network, no
policy subprocess, no Git operation. **This is not a playability claim.**

Owned by this chunk:

- `AISparring/integration/runtime_bootstrap.lua` — trusted outer port adapter.
- `AISparring/integration/mp_driver.lua` — real Multiplayer lobby/start driver.
- `AISparring/integration/control_transport.lua` — main-thread nonblocking channel.
- `AISparring/integration/control_thread.lua` — LÖVE control worker source.
- `tests/run_runtime.py` + `tests/runtime/*` — static + Lua 5.1 / LuaJIT fixtures.
- this document.

It does **not** modify `AISparring/core.lua`, the broker, the decision loop, the
engine adapter/executor, the reader, the M2 modules, the practice service or the
launcher. Loading every module here has no side effect; the root wires them.

## 1. Topology recap

The launcher owns the session: two role credentials, a nonce, the content hash,
the loopback control port, the match port and the trusted match seed. Each staged
Balatro runtime runs the real game + real Multiplayer 0.5.5 with an identical
pinned mod/content/unlock set. The human hosts a real local lobby with the actual
Major League ruleset; the AI joins it as the fixed public name `BALATRO AI`. The
two runtimes coordinate only over the dedicated loopback control channel through
the launcher-owned practice service. The official Multiplayer match transport is
never redirected, and no private state travels over it.

```
launcher ──spawn──► staged human runtime ─┐
        └─spawn──► staged AI runtime ────┤  dedicated loopback control channel
                                          │  (nonce/role-named LÖVE channels)
                                practice service (worker-owned)
```

## 2. Trusted boot sequence (`runtime_bootstrap.factory`)

Nothing is authorized by a role string or a `production = true` flag. The
bootstrap refuses to install unless **all** of these hold:

1. `role` is exactly `human` or `ai`.
2. `expected.save_dir`, `expected.mods_root` and `expected.mod_root` (populated by
   the launcher) equal the runtime's own reported paths after normalization
   (case-insensitive, `/`-normalized). `mod_root` must sit under `mods_root` and
   end in `AISparring`.
3. `launcher.verify()` (the independently verified Python launcher) returns a
   fresh verdict agreeing on `nonce`, `session`, `role`, `content_hash` and
   `control_port`.
4. The authenticated `hello` (carrying `content_digest = content_hash`) has been
   answered with success by the service.

Only after (4) does `activate()` run, and only for `role == "ai"`. The human role
never constructs the adapter, executor, broker capability or decision loop, and
never automates a hand.

```
validate()                    -- (1)(2)(3); returns nil + boot_* code on failure
install()                     -- channels + worker + transport + hello
update(dt)                    -- bounded polling; arms on the hello ack
  hello is retried while the attestation gate returns practice_not_attested
  advance_coordinator()       -- typed SETUP -> connect -> lobby -> ready -> start
  activate()  (ai only)       -- adapter -> reader -> executor -> capability -> broker -> loop
  decision loop runs only once the real MP match-start is observed
shutdown(reason) / teardown   -- revoke, cancel, leave local session, restore hooks
```

### 2.1 Bounded start coordinator

Every coordination response is correlated to the exact op that produced it (the
service returns no request id on coordination responses, so the bootstrap keeps a
FIFO of its own sends — including heartbeat/end — in the single ordered control
connection). The coordinator then runs a bounded, exactly-once state machine:

1. `setup`: send once after the hello ack; parse the typed SETUP payload and
   verify `role`, `difficulty`, `mode`, `pacing` against the trusted launcher
   ports. The trusted gauntlet seed is read from `gauntlet_seed` and is
   **human-only**; the guest never receives, stores or reports a seed.
2. `connect`: no create/join until `MP.LOBBY.connected` is true (the server starts
   only after the launcher probes/attestation). A missing connection is a
   bounded wait, never a frame error.
3. `lobby`: the host creates the real Major League lobby and reports the exact
   code; the guest polls the AI-only `join_code` op with a bounded backoff until
   the host has reported it (`practice_no_lobby` is a benign wait) and then joins
   the exact code.
4. `ready`: each role computes its **own** Major League digest from the live
   `MP.LOBBY.config` over the SETUP forced keyset and sends it in `ready`; the
   `config_digest` port/content-hash fallback is removed. The host additionally
   verifies its locally recorded keyset matches the service keyset exactly.
5. `start`: the host waits for the guest's real ready flag and the `ready` ack,
   sends `start`, waits for the `start` ack, and only then calls the real
   `lobby_start_game`. Each real callback commits once; a late UI element or a
   not-yet-ready flag is retried without double-toggling.

The whole pre-start window is bounded by `prestart_timeout` (120 s: the
service's own 90 s pre-start window plus margin). A service reply of
`practice_aborted`/`practice_closed`/`practice_ended`/`practice_prestart_timeout`,
or a `heartbeat` reply with `aborted = true`, is fatal and stops the coordinator
immediately; a retryable refusal (`practice_not_ready`, `practice_no_lobby`, a
refused `lobby_code`) re-arms the send under that same deadline. `hello`/`setup`
are re-sent while the service replies `practice_not_attested` (attestation is
monotonic and set only through the trusted host `mark_attested` port, never over
the wire). Once the real `start_lobby` has been invoked, a forcing failure
(`driver_force_failed`) is fatal instead of re-arming a second `createLobby`.

The broker capability is minted by `ActionBroker.production_factory(verifier)`
inside `activate()`. The verifier closure holds the exact executor ports table
and the exact minted capability and compares them by identity. The capability,
broker, engine adapter, executor and loop stay in module-private locals and are
never returned by `describe()`/`status()`.

## 3. Bootstrap ports

`RuntimeBootstrap.factory(ports) -> instance | nil, code`

| port | contract |
|---|---|
| `role` | `"human"` \| `"ai"` (staged only) |
| `session`, `credential`, `nonce`, `content_hash` | bounded non-empty tokens from the launcher; never logged |
| `control_port` | int 1..65535, loopback control service port |
| `expected` | `{ save_dir, mods_root, mod_root }` absolute launcher-staged paths |
| `env` | `{ save_dir(), mods_root(), mod_root() }` reporting the runtime's real paths |
| `launcher` | `{ verify() -> { ok, nonce, session, role, content_hash, control_port } }` |
| `control_protocol` | `AISparring/integration/control_protocol.lua` |
| `control_transport_factory` | `ControlTransport.factory` |
| `control_thread` | `AISparring/integration/control_thread.lua` |
| `channels` | optional injected `{ to_worker, from_worker }` (must expose `push`/`pop`) |
| `get_channel` | optional `love.thread.getChannel`-style lookup when `channels` is absent |
| `love_thread` | optional `love.thread` (used to spawn the worker) |
| `spawn_thread` | optional `function(port, to_worker, from_worker) -> truthy` (tests/fakes) |
| `encode`, `decode` | the game-bundled JSON encode/decode |
| `clock` | `{ now() }` monotonic seconds |
| `modules` | `{ codec, observation, actions, StateReader, EngineAdapter, ProductionExecutor, StateRevision, ActionBroker, DecisionLoop, MPDriver }` |
| `G`, `MP`, `funcs` | staged engine tables (`funcs` defaults to `G.FUNCS`) |
| `element_for` | bounded real UIElement lookup (`"cash_out"`, `"pvp_ready"`, `"skip_blind"`, `"lobby_ready"`, …) |
| `client` | optional `Client` (the AI send guard wraps `client.send`) |
| `logger` | optional trusted `{ record(fields) }` |
| `ui_notify` | optional injected host error overlay (`function(level, message)`) |
| `hook_targets` | optional `{ { table, name, reason }, … }` revision hooks |
| `terminal_probe` | optional `function() -> "win"\|"loss"\|nil` |
| `mode`, `difficulty`, `pacing` | trusted enums (`gauntlet`/`normal`, `rookie`/`competitive`/`major_league`, `instant`/`normal`) |
| `decision_base` | first decision sequence (default `1000000`) |
| `auto_coordinate` | default `true`; the root may instead drive the explicit methods |

The gauntlet seed is **not** a bootstrap port (no `AISP_SEED`, no alias): it is
read from the authenticated, human-only service `setup` payload. There is no
`config_digest` port either; the digest is source-derived locally (below). `G`
is injected so the driver can resolve the real ready element, and
`modules.codec.hash_string` supplies the FNV1a32 digest hash.

Instance API: `validate()`, `install()`, `update(dt) -> status, code`, `status()`,
`summary()`, `lobby_code()`, `state()`, `is_inert()`, `shutdown(reason)`,
`describe()`, plus `CODE`/`LIMITS`.

## 4. Control transport (`control_transport.lua`)

- Exactly one six-key request envelope per request (`control_protocol.lua`). A
  nil payload is encoded as an empty object `{}` so the `observation` key always
  survives JSON encoders that drop nil fields; the service accepts `{}` for
  these ops (`test_practice_service.py::test_lua_control_protocol_constants`).
- **One globally monotonic wire sequence.** The real practice service keeps a
  single strictly increasing per-role `last_sequence` for every non-poll
  request, so coordination ops and `decide_begin` all allocate the next wire
  sequence. The decision loop's own sequence (`decision_base`, default
  `1000000`) is private: it travels inside the payload and the transport maps
  the returned wire sequence back to it, so a decision never invalidates the
  next heartbeat/status/end/start.
- `decide_poll` reuses the outstanding decision's wire sequence (the service
  exempts polls from the monotonic check) and `decision_result` carries the
  original decision wire sequence in its payload while allocating a fresh wire
  sequence for the request itself.
- `decide_cancel` closes the loop-visible "cancel and reissue" recovery.
  `transport.cancel(request_id)` sends a **wire** `decide_cancel` for exactly the
  owned outstanding decision — a fresh global sequence carrying
  `{ decision_sequence = <the owned decide_begin wire sequence> }` — *before* it
  clears the local slot, so the service can never still own the job after this
  side forgets it. An unknown/stale request id sends nothing. The local→wire
  mapping survives the cancel so a receipt can still name the cancelled
  decision, and the cancel ack (which echoes the decision sequence) is consumed
  rather than delivered or counted as out-of-order. When the cancel frame cannot
  be pushed the local slot is **kept** (both `cancel()` and the transport
  timeout path), so an owned cancel is never lost before it is pushed/acked or
  the connection closes.
- The loop timeout is `decision_timeout + one poll interval` (`15.25 s`); the
  service worker timeout stays 10 s, so the service reports a slow worker first
  and the loop's own timeout triggers the `decide_cancel` + reissue. The
  transport request timeout is a strictly higher backstop (`+15 s`) and also
  cancels its own owned decision on the wire before clearing.
- `poll_decision()` is nonblocking: it never sleeps, emits at most one
  `decide_poll` per `poll_interval`, and returns a terminal response (`ready`, or
  a bounded failure) only. A service `practice_decision_pending` keeps the slot
  outstanding.
- **Ordered outstanding-frame matching.** The service answers strictly in order
  on the single connection, one reply per request, so the transport keeps a
  bounded ordered list of **every** frame it pushes (coordination, `decide_begin`,
  `decide_poll`, `decide_cancel`, `decision_result`) and matches each non-event
  reply to the head of that list. A `decide_begin` rejection that omits
  `sequence` (not attested/replay/bad observation/outstanding/ended/aborted)
  still reaches the decision that caused it; a `decision_result`/cancel/
  heartbeat reply can never shift a later coordination reply (or a false END
  ack), and every coordination reply is tagged with the op that produced it so
  the runtime routes it without a second, drift-prone correlation list.
- Bounds: 2 MiB outbound, 64 KiB inbound; per-request timeout; bounded
  coordination queue and bounded inflight list. Credentials/session never appear in `describe()`.
- Channel ports are resolved with protected normal indexing, so a real LÖVE
  `love.thread.getChannel` **userdata** (whose `push`/`pop` live on the
  metatable) is accepted exactly like the in-memory table fixture; `rawget`-only
  table assumptions previously rejected every real channel with
  `transport_bad_channels`, so a table-only lookup is never used for a native
  channel. `build_channels` applies the same rule to an injected
  `{ to_worker, from_worker }` pair and to the default `get_channel` route, and
  still rejects a value that is not a table/userdata or lacks the method (Astra
  root `control_channels_accept_userdata_methods`, plus the bootstrap
  default-`get_channel` userdata fixture).
- The worker thread (`control_thread.lua`) owns the actual `socket`, connects to
  `127.0.0.1:<port>` only, uses the game-bundled `json`+`socket`, and mirrors the
  Multiplayer thread style while using **dedicated** channels, never
  `uiToNetwork`/`networkToUi`. If either dependency is absent the worker emits a
  bounded hard-coded `{"t":"error","code":"control_thread_dependency"}` frame
  that never touches `json.encode` (the normal path is unaffected: Lovely 0.10
  preloads `json` in every state).

## 5. Multiplayer driver (`mp_driver.lua`)

- `host_start(seed)`: sets `MP.LOBBY.config.ruleset = "ruleset_mp_majorleague"`
  and the ruleset's own `forced_gamemode`, then calls the **original**
  `G.FUNCS.start_lobby`. Because `start_lobby` resets the config and then calls
  `MP.current_ruleset():force_lobby_options()`, the trusted gauntlet seed is
  installed by a scoped wrapper that runs *after* the reset and *before* the
  original `force_lobby_options`. The wrapper reads the field with protected
  normal indexing (`resolved.force_lobby_options`), because the real
  `MP.current_ruleset()` is an empty metatable proxy; a rawget would skip the
  real function. The wrapper is always restored; the original
  timer/location/option values are never re-implemented. Once the real
  `start_lobby` has been invoked, a failure to record the forced keys is fatal
  (`driver_force_failed`) and is **never** a re-armed second `createLobby`
  (pre-call refusals such as `driver_no_ruleset` stay retryable).
- `ai_join(code)`: sets `MP.LOBBY.username = "BALATRO AI"` and calls the ordinary
  `MP.ACTIONS.join_lobby(code)` with the exact service-provided code.
- `ai_ready()`: resolves the **real** element
  `G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")` (normal metatable indexing,
  never rawget, never a fabricated skeleton; an injected `element_for` override
  must return the same real shape) and calls the original
  `G.FUNCS.lobby_ready_up(e)`. Success is reported only when the observable
  `MP.LOBBY.ready_to_start` actually turned true, so a version-mismatch modal or
  a still-animating button is a bounded `driver_not_ready` retry. An
  already-ready lobby is an idempotent success that never double-toggles.
- `host_start_game()`: requires the guest-confirmed ready state and the live
  forced ruleset, then calls the original `G.FUNCS.lobby_start_game`.
- `connected()` / `ruleset_ready()` / `is_started()` / `main_menu_ready()`: real
  MP observables used by the coordinator (socket connected, registry+forced
  ruleset agree, match started, menu ready). `is_started()` is the *match* flag,
  never "we called ready": it latches once the lobby is joined and the engine has
  reached the ordinary `G.STAGES.RUN` stage (the only way a staged lobby gets
  there is the real Multiplayer start). It never consults a
  `MP.is_started`/`MP.LOBBY.started` flag, neither of which exists in the pinned
  source. `main_menu_ready()` requires the real `G.STAGE == G.STAGES.MAIN_MENU`
  **and** `G.STATE == G.STATES.MENU` **and** `G.MAIN_MENU_UI ~= nil`, so the
  splash screen (which reuses the MAIN_MENU stage with the SPLASH state) never
  creates a lobby.
- `config_digest(ruleset_id, gamemode, keys)`: source-derived Major League digest
  (`ruleset_id | gamemode | key=value…`, keys bytewise ascending) over the live
  `MP.LOBBY.config`, hashed with `Codec.hash_string` (FNV1a32, eight lowercase
  hex). The forced key set is recorded from the real registry
  `force_lobby_options` call (the driver proxies `MP.LOBBY.config` for exactly
  that call — no hardcoded key names); the guest uses the service SETUP keyset.
  The runtime computes actual values locally and never echoes the expected
  digest.
- `install_send_guard()`: default-deny allowlist over `Client.send`, built from
  the **actual wire action names** in the pinned Multiplayer source. The
  required life/timer penalties (`failTimer`, `failPvPTimer`, `startAnteTimer`,
  `pauseAnteTimer`) and ordinary gameplay are preserved; the ranked/server
  (`submitLogHashes`, `streamLogLines`, `endGameStatsRequested`, `sendGameStats`)
  and end-game/private opponent paths (`getEndGameJokers`, `getNemesisDeck`,
  `nemesisEndGameStats`, `receiveEndGameJokers`, `receiveNemesisDeck`,
  `moddedAction`, …) can never be sent. Role/phase gates sit on top: the guest
  can never create a lobby or push `lobbyOptions`; only the trusted human host
  may push `lobbyOptions`, and only before start (configuration is frozen once
  the match starts). The pinned, harmless `connect` action (`MP.ACTIONS.connect`,
  the reconnect button carries no private/ranked data) is allowed; the blocked
  set still contains every ranked/server/end-game/private path. Uninstall
  restores the exact original.
- The guard is **required for both staged roles** before any create/join: it is
  installed for the human host as well as the AI guest and a boot that cannot
  install it aborts with `boot_guard_failed` before any lobby create/join. Only
  this staged bootstrap installs it — never the normal/live path. The root must
  inject the real `Client` port; a missing client is not silently tolerated.
  Ordinary MP messages (coordination, gameplay, required timer/life penalties)
  are preserved by the allowlist.
- `leave_local()` / `stop_local()`: leave/stop only through ordinary MP actions.

## 6. Update, terminal and errors

`update(dt)` performs one bounded step: drains and correlates coordination
responses (each reply carries the op the transport tagged it with), arms on the
hello ack, (AI) activates, checks terminal signals, runs the bounded start
coordinator, then runs the decision loop **only after the real MP match-start is
observed** (the lobby is joined and `G.STAGE == G.STAGES.RUN`; the guest learns it
from the ordinary server start), and throttles the additive `heartbeat` op
(`{tick = decisions}`). Gate the loop on the real start: otherwise the service
refuses every decision as not-started and burns the loop's error budget.
The loop is wired with the real revision reader (`StateRevision.current`) and a
grounded `wait_state` probe (`mp_wait_state`): only real MP waits
(`MP.GAME.ready_blind`, the **current** PvP blind with no hands left while
`end_pvp`/`round_ended` are not set, the PvP countdown) hold the transient window
open; every other condition, including an unknown engine fault, keeps the loop's
own bounded window. The PvP no-hands wait deliberately does **not** depend on
`MP.GAME.pvp_reached`, which Multiplayer resets to false when the PvP blind
starts, so the AI can wait out the human's PvP turn instead of stopping after its
120 s transient budget. After a `submitted` loop step
the bootstrap reports the outcome with the additive `decision_result` op
(`accepted=true`), and reports an actually-delivered-then-refused decision with
its stable loop code (`accepted=false`), carrying the transport-mapped decision
wire sequence; a terminal stop sends no fabricated receipt.
Terminal handling uses the **actual** Multiplayer `MP.GAME.won` win signal and
the engine `GAME_OVER` loss signal, so a win stops the policy even while the
engine stays outside `GAME_OVER`; a compact trusted summary is sent to the
service `end` op with the service's terminal-result vocabulary. The mapping is
**role-aware** because the terminal signal is local to each engine: the human's
local win is `human_win` and the human's local lives are `human_lives`, while the
AI's are the inverse — a role-blind mapping would reverse the winner and the life
totals, and the service trusts the human END as authoritative (the AI END is only
a receipt and never authorizes teardown). After the one END send the runtime
enters a drain-only terminal state: it consumes the owned END reply (bounded by
`coord_timeout`), never re-sends, never runs the loop again and emits no further
decisions or seed.

The trusted audit seed is human-only and is sent to the service `status` op once
the run is **actually initialized**: the human reads the source-backed resolved
`G.GAME.pseudorandom.seed` (pinned `reference/game/game.lua:2164`; the gauntlet
custom seed, or the engine-generated seed for a normal match), never a stale
menu/prior-run value. A gauntlet run must agree with the human-only SETUP seed
(`boot_seed_mismatch` otherwise) and a missing resolved seed is bounded
(`boot_seed_timeout`). The seed is never a policy feature and never reaches the
AI or the policy worker export.

On any failure `shutdown(reason)` revokes the capability and broker, cancels the
control/policy work, restores hooks and the send guard, leaves only the local
session through ordinary MP actions and stops the transport. It never kills a
process, never mutates a save and never touches the human's run.

## 7. Revision hooks

`RuntimeBootstrap.install_hooks(hook_targets, revision)` wraps the named real
engine methods. The wrapper calls the original first and preserves its return
values (and lets exceptions propagate); it bumps the trusted revision only on a
successful call, so a failed callback never advances state. It is not a
per-frame bump. `shutdown` restores every wrapper.

## 8. Test harness

`python tests/run_runtime.py --require-all` runs static source checks plus
`tests/runtime/test_*.lua` under `lupa.lua51` and `lupa.luajit21`. The real
protocol/transport/thread/driver/bootstrap and the real M2/engine modules are
loaded; only the game environment (in-memory channels, fake clock, synthetic
G/MP) is fake. Coverage: envelope shape/gauntlet stability; transport role/bound
validation, sequence separation, single decision slot, pending/ready/failure
responses, replay, timeout, size bounds and secret-free `describe`; thread source
bounds/loopback/dedicated channels, the json-independent dependency error and
spawn validation; driver seed placement,
role refusal, fixed AI name, real-element readiness, start gating and the send
guard; and bootstrap inertness for non-staged/mismatched/unverified boots, human
non-activation, AI activation after the hello ack, decision issuance, terminal
stop, private-object hygiene and hook return/exception preservation. The
lifecycle additions are covered too: wire-cancel ordering/unknown-cancel/timeout
cancel, hello retry under the attestation gate, the loop timeout cancel+reissue,
role-aware terminal mapping for both roles, the drained bounded terminal END, the
deferred asynchronous lobby code without a duplicate create, the grounded
`mp_wait_state` probe (including the post-start PvP no-hands wait holding the loop
past its 120 s transient budget), the default-`get_channel` **userdata** channel
path, ordered outstanding-frame matching (a `decide_begin` rejection without a
`sequence`, repeated polls, and a `decision_result`/heartbeat reply not shifting a
later END ack), the fatal post-create forcing failure (`driver_force_failed`,
one create only), the service-abort/heartbeat-abort and prestart-deadline stops,
and the real RUN-stage/SPLASH-state shape checks.

Run the pinned interpreter `work/runtime-venv/Scripts/python.exe` (lupa 2.8,
no `PYTHONPATH` needed).

`python tests/test_runtime_cross_service.py --require-all` has three contracts:

- the *actual* JSON envelopes emitted by the real Lua transport are fed into the
  *actual* `tools/practice_service.py` `handle_request` wire entrypoint with a
  real canonical observation, exercising two decisions interleaved with
  heartbeats/status/results and the terminal `end`, and asserting the single
  per-role wire sequence never triggers `practice_replay`;
- **two real bootstrap coordinators** (human + guest, in two Lua runtimes) are
  driven against one attested real service with source-shaped MP stubs and
  late connect/UI, asserting they both reach the real start gates, the host
  reports the trusted seed exactly once, the guest joins the host's exact code,
  and each role sends exactly one `hello` (no invented op or code);
- the empty-object JSON mismatch root is asserted directly: the pinned
  rxi/SMODS json (the game's `require("json")`) encodes `{}` as `[]`, while the
  companion `integration/wire_json.lua` composes the six-key envelope with
  `"observation":{}`. When `wire_json.lua` is present the cross-service critical
  frames are encoded through the real SMODS json + wire wrapper, never the test
  json. If the wrapper is absent the report case fails loudly rather than
  hiding the mismatch.

`python tests/astra_runtime_contracts.py` (6 cases / 12 executions, lua51 +
luajit21) independently checks the real **userdata** control channel methods
(`control_channels_accept_userdata_methods`), hook return arity, the single wire
sequence across a decision, the timer penalty allowlist, the guest lobby-option
block, and the real inherited-UIBox ready lookup (executed against the pinned
engine Object/UIBox definitions, not a conjectured metatable fixture).

No test starts Balatro, opens a socket, reads a Mods directory or contacts an
external network.

## 9. Unresolved integrations and honest non-claims

- **Root wiring not done.** `AISparring/core.lua` (root-owned) must inject the
  ports, install `update`, and provide `G`, `env`, `launcher`, the game
  `encode`/`decode` (through the companion `wire_json` wrapper), `love_thread`/
  `get_channel` **and the real `Client` handle for BOTH roles** (the send guard
  is required for host and guest and a stage aborts `boot_guard_failed` without
  it). `get_channel` is `love.thread.getChannel`; the returned Channel
  **userdata** is now accepted directly (protected method lookup), as is an
  injected `{ to_worker, from_worker }` pair. It must also supply `modules.codec`
  for the human role: `ensure_driver` needs `Codec.hash_string` on both roles for
  the source-derived digest, and the digest is never weakened with a
  content-hash fallback. That human-codec supply is assigned to the **companion
  owner** (finding 9); this chunk does not edit `core.lua` or
  `companion_host.lua`, and `companion_host.lua` must still forward the `Client`
  port.
- **Practice service coupling.** The exact `hello`/`setup`/`status`/`end`
  response shapes are owned by the service worker; this chunk reads only the
  documented op-specific fields (`role`, `ruleset_id`, `gamemode`,
  `forced_options`, `difficulty`, `mode`, `pacing`, `gauntlet_seed`) and bounded
  `ok`/`code`. A response that is missing a required field or disagrees with the
  trusted ports fails the boot (`boot_setup_failed`/`boot_config_mismatch`)
  rather than being worked around. The service attests the session only through
  its trusted Python `mark_attested` port; the runtime treats
  `practice_not_attested` as a bounded retry.
- **Empty-object / null wire shapes.** The game's `require("json")` (rxi)
  encodes an empty table as `[]` and has no null sentinel. The companion
  `integration/wire_json.lua` (owner: root/companion) is the wire composer that
  forces `{}` for the six-key envelope's `observation`; it now exists and the
  cross-service critical frames are encoded through the real pinned SMODS json +
  this wrapper, with the mismatch root asserted directly. Core must still pass
  `wire.encode_service` as the runtime `encode` port in the live path. This chunk
  does not edit the companion module.
- **Major League digest.** The host-side expected digest is derived by the
  launcher/service owner from the pinned `rulesets/majorleague.lua`; this runtime
  computes the actual digest locally from the live `MP.LOBBY.config` over the
  service-provided keyset and never echoes the expected value. Equal digests plus
  `practice_config_mismatch` on drift are the check; the digest is trusted
  configuration equality, not authentication.
- **Real start observation.** The guest's match-start relay is the ordinary
  server start; fixtures relay it explicitly (the two runtimes do not share
  engine memory). A live run must observe the real lobby join plus the ordinary
  `G.STAGES.RUN` transition (there is no `MP.is_started`/`LOBBY.started` in the
  pinned source).
- **Pending-action latch.** The executor's pending/cancel/timeout API
  (`pending_status`, `cancel`, `revoke`) is consumed through the broker ports; a
  worker-owned latch change is integrated via those ports, not by editing worker
  files.
- **Real UI elements.** The lobby-ready lookup resolves the real inherited
  `G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")` (verified against the pinned
  engine Object/UIBox definitions). The remaining cash-out/PvP/skip elements are
  the engine worker's; fixtures only prove the driver refuses a missing element
  and never fabricates a button.
- **Executor terminal faults.** The broker now passes `exec_stall_timeout`/
  `exec_revoked` through; the decision loop must stop immediately on them
  (loop-worker scope).
- **Terminal ownership.** The service trusts the human END; the AI END is a
  receipt. The runtime keeps the service open (the launcher closes it) and never
  generates decisions after the terminal state.
- **Timer projection and observation coverage** remain as documented in
  `ENGINE_ADAPTER.md` §9 and `DECISION_LOOP.md` §4.
- **Not a sandbox.** The capability is in-process provenance, not isolation, and
  not a defence against arbitrary trusted local code.
- **No live evidence.** Nothing here launches the game, writes a Mod or file,
  sends network traffic or runs the policy subprocess; all evidence is fixture
  and static only. Real-engine smoke testing is the root's later step.
