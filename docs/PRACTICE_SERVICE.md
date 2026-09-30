# Practice control/policy service (`tools/practice_service.py`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded implementation of the launcher-owned loopback control/policy
service described in `docs/PLAYABLE_RUNTIME_CONTRACT.md`. Ships with
`tests/test_practice_service.py`. No game, Mods directory, live path, save,
launch, termination or external network is used by the service or its tests.

## 1. Purpose and trust model

The service is the small trusted component the outer launcher starts next to the
two staged Balatro runtimes. It does exactly two things over one
newline-delimited JSON channel bound to `127.0.0.1`:

1. **Match coordination relay** — narrow, fixed-enum messages that carry the
   session handshake, the human lobby code to the AI, ready confirmations and
   the one-time start authorization. It never issues Multiplayer transport
   commands, never connects to a game match server and never adjudicates a
   match.
2. **Bounded AI decisions** — one outstanding decision per AI session. The AI
   role submits a canonical exported observation; the service selects the
   repository-owned baseline policy source for the trusted difficulty, runs the
   existing `tools/policy_worker.py` in a separate bounded process and returns
   the worker-validated action.

Trust anchors (set at construction, never accepted from or mutable by a
network client):

- `session_id` — exact-match session identity.
- two random per-role credentials — `human` and `ai`, distinct, generated with
  `secrets.token_hex(32)` unless the launcher injects them.
- `difficulty` — `rookie` | `competitive` | `major_league` | `expert`.
- `pacing` — `instant` | `normal` (the runtime owns the dispatch schedule; the
  service never touches a game clock).
- `mode` — `normal` | `gauntlet`, plus the `gauntlet` label when in gauntlet
  mode.
- `match_port` — the launcher-owned Multiplayer port (recorded only; the service
  never opens it).
- `log_root` — local diagnostics root.
- `content_hash` — the verified content digest the runtimes must present in
  `hello`.
- `expected_config_digest` — **required**, the trusted host-derived Major League
  configuration digest (FNV1a32, eight lowercase hex). It is not the game
  content hash and there is no content-hash fallback.
- `ruleset_id`, `gamemode`, `forced_options` — the trusted host-derived Major
  League registry identity and forced configuration used only to expose the
  forced **keyset** in `setup` (never the values).

**Attestation gate (M8).** Every session starts *unattested*. Until the trusted
Python host calls `mark_attested(expected_config_digest)`, the service refuses
`hello`, `lobby_code`, `join_code`, `ready`, `start`, `setup` and all decision
ops with `practice_not_attested`. `status`, `heartbeat`, `end` and `error` stay
available so a launcher can still observe, abort and report. `mark_attested` is a
trusted in-process port, **never a wire op**: no network client can attest
itself, and the supplied digest must equal the constructed
`expected_config_digest`. The host calls it after both staged role probes and the
open-record check have passed and *before* the atomic attestation writer
publishes the file the companions poll, so the file only exists once the gate is
open.

The service holds no game authority. The worker remains the capability
boundary: it re-sanitizes the observation, regenerates legal actions and
re-validates the selection. A client can never supply policy source, config,
seed, raw engine state or credentials to the worker. A role claim also can never
select trusted configuration: difficulty/source, pacing, mode, the gauntlet seed,
the match port and the expected config digest come only from construction, and
the outer bootstrap binds the verified manifest plus the private role credential.

## 1.1 Major League configuration digest (M10)

Root's frozen contract is `docs/MAJOR_LEAGUE_DIGEST.md`. The host derives the
expected digest from the pinned staged `rulesets/majorleague.lua`
(`force_lobby_options`): `ruleset_id | gamemode | key=primitive | ...` with keys
in bytewise ascending order, hashed with the existing `Codec.hash_string`
(FNV1a32, eight lowercase hex). The service mirrors the algorithm exactly in
`fnv1a32_hex` and `major_league_digest(ruleset_id, gamemode, forced_options)`;
`tests/test_practice_service.py` asserts parity against the real Lua `codec.lua`.
This is trusted configuration **equality**, not authentication.

`ready.config_digest` must equal the trusted expected digest, not merely the
other role's value, and `start` re-checks it. A runtime computes the actual
digest from the live `MP.LOBBY.config` values locally and must never echo the
expected digest it saw in `setup`. Drift (a role-ready digest that is not the
expected digest) and any post-start config change are rejected.

## 2. Construction

```python
from practice_service import PracticeService, ServiceConfig

config = ServiceConfig(
    session_id="20260927T120000Z",
    difficulty="competitive",
    pacing="normal",
    mode="gauntlet",
    gauntlet="Test3",
    match_port=8788,
    log_root=r"C:\stage\logs\ai",
    content_hash="<verified digest>",
    expected_config_digest="<host-derived FNV1a32 hex>",   # required
    ruleset_id="ruleset_mp_majorleague",
    gamemode="gamemode_majorleague",
    forced_options={"attrition": True, "base_time": 180},
)
service = PracticeService(config)          # credentials generated here, unattested
service.human_credential                    # launcher-only; never logged
service.ai_credential
service.gauntlet_seed                       # "AISP0003" or None

# ...both staged role probes verified, open-record checked...
service.mark_attested(config.expected_config_digest)   # trusted port, opens the gate
port = service.start()                      # binds 127.0.0.1:0 by default
...
service.close()                             # stops server and cancels child
```

`start()` binds `127.0.0.1` only (any other host is rejected) on the requested
port, or an ephemeral port when `port=0`. `close()` stops the server, cancels any
outstanding decision and terminates **only the exact worker child** the service
spawned (stored `Popen` handle), then joins the decision thread. Closing a
started, not-yet-summarized session writes exactly one terminal summary (§4.1).

`mark_attested(expected_config_digest)` returns `True`, raises
`PracticeError(practice_bad_request)` if the digest is malformed or does not equal
the constructed value, and is refused after `close()`. It is idempotent and may
be called before `start()`.

`gauntlet_seed` is exposed to the launcher/runtime config only. It is never part
of a network response. Seed wiring for normal matches is a trusted status setter
(see §6).

### 2.1 Gauntlet

| Label | Seed |
|---|---|
| Test1 | AISP0001 |
| Test2 | AISP0002 |
| Test3 | AISP0003 |
| Test4 | AISP0004 |
| Test5 | AISP0005 |

Five exact, stable, neutral seeds. The labels are test intentions, not claims
about searched favorable outcomes. There is no seed search. Normal-match seeds
are selected by the original Multiplayer server, never by this service.

## 3. Wire protocol

- Transport: TCP, `127.0.0.1` only.
- Framing: one JSON object per line, terminated by `\n`.
- Request cap: 2 MiB. Response cap: 64 KiB. Observation cap: 1 MiB and depth 16.
- JSON must not contain duplicate keys, `NaN` or `Infinity`.
- Per-connection rate limit (default 120 requests/second) and a bounded
  concurrent-connection count (default 8). Excess returns a bounded error.

### 3.1 Request envelope (strict)

Every request is exactly these six keys — no more, no fewer:

```json
{"session":"...", "credential":"...", "role":"human|ai",
 "op":"hello|...", "sequence":0, "observation": <payload-or-null>}
```

`observation` carries the exported observation for `decide_begin` and a small,
op-specific payload object for coordination ops. `sequence` is a non-negative
int32. The key must always be present: a Python caller may send `null`, and the
Lua `ControlProtocol.envelope` turns a nil payload into `{}` so the sixth key
survives JSON encoders that drop nils.

### 3.2 Authentication and sequencing

- `session` is compared to the trusted `session_id` with a constant-time
  compare (`hmac.compare_digest`).
- `role` must be `human` or `ai`; `credential` must constant-time match that
  role's credential. A valid credential for the other role fails.
- Fixed per-op role rules: `lobby_code` and `start` are human-only; `join_code`,
  `decide_begin`, `decide_poll`, `decide_cancel` and `decision_result` are
  AI-only. Wrong role → `practice_bad_role`. The role rule is checked in the same
  authenticated envelope flow as every other op: a caller must still present the
  session and the role credential, so the human credential can never issue a
  cancel.
- Every non-poll request must use a `sequence` strictly greater than that
  role's last accepted value. Duplicates and out-of-order requests →
  `practice_replay` (the value is consumed on the first accepted request).
- `decide_poll` is special: its `sequence` identifies the outstanding job and
  must equal the pending `decide_begin` sequence; it is not a monotonic counter
  and polling an unknown/consumed sequence is a bounded error, never a reset.
- **Attestation gate (checked after auth, before the sequence counter is
  consumed):** while the session is unattested, gated ops return
  `practice_not_attested` and the role's sequence is *not* advanced, so a retry
  after `mark_attested` works with the same sequence.

### 3.3 Responses

`{"ok": true|false, "code": "<bounded code>", ...op fields}`. Only bounded codes
and bounded fields ever leave the service.

## 4. Coordination ops

| Op | Role | Payload | Behavior |
|---|---|---|---|
| `hello` | any | `{"version": str, "content_digest": str}` | Records the role hello; `content_digest` must equal the trusted `content_hash` or `practice_content_mismatch`. Returns `ruleset`. |
| `lobby_code` | human | `{"lobby_code": str}` | Records the human-created local lobby code (`[0-9A-Za-z_-]{1,32}`). |
| `join_code` | ai | `{}` / null | Returns the recorded human lobby code, or `practice_no_lobby`. |
| `ready` | any | `{"config_digest": str}` | Records the role's ready confirmation. `config_digest` must be the runtime-computed actual digest and must equal the trusted `expected_config_digest` (and the other role) or `practice_config_mismatch`; a malformed digest → `practice_bad_payload`. |
| `start` | human | `{}` / null | One-time. Requires both hellos and both ready digests equal to the trusted expected digest; otherwise `practice_not_ready` / `practice_config_mismatch`. Second call → `practice_already_started`. |
| `status` | any | `{}` or `{"seed": str}` | Returns bounded session state (including `ruleset`, `pacing`, `mode`, `attested`, `aborted`, counters and the terminal receipt flags — §4.1). A `seed` is trusted human-only audit metadata: it is accepted from the **human role only** (role is validated first; an AI value → `practice_bad_role`), **exactly once** (a second, different value → `practice_config_mismatch`, an identical human repeat is an idempotent no-op), and **only** once the run is initialized in a started, non-terminal, non-aborted session (a pre-start report → `practice_not_started`; a terminal/aborted late report → `practice_ended`). In Gauntlet mode the first seed must equal the trusted catalog seed. It is handed only to the trusted logger (§6). The real human runtime reports the *resolved* run seed through `STATUS` after `start` and `host_start_game`, never a menu or prior-run value (M-6). |
| `heartbeat` | any | `{}` or `{"tick": int}` | Liveness ping; any authenticated request refreshes the role watchdog (§5.3). |
| `setup` | any | `{}` / null | Returns the frozen trusted setup: `ruleset` (`majorleague`), `ruleset_id`, `gamemode`, the forced-config **keyset** `forced_options` (key names only, never values), `expected_config_digest`, difficulty, pacing, mode, gauntlet label, `match_port`, `content_hash`, and — for the human coordinator only — the gauntlet seed. Never sent to the worker. |
| `error` | any | `{"error": "<bounded code>"}` | Records a trusted failure visible to both roles through `status`. |
| `end` | human/ai | bounded summary object | Authorizes/records match termination. **Only the human coordinator** authorizes match end, and only after `start` with a valid terminal `result`; the AI `end` is a receipt recorded beside it. See §4.1. |

After a successful `start` the configuration is frozen: `hello`, `lobby_code`,
`join_code` and `ready` return `practice_config_frozen`. `status`, `end`,
`error`, `heartbeat`, `setup` and the decision ops remain available. After the
human terminal `end`, only `status`, `end` and `decision_result` are accepted
(everything else → `practice_ended`).

### 4.1 Terminal lifecycle (H5 / M1)

`end` no longer tears the session down from either role:

- **Human coordinator END.** Requires `started` and a valid terminal `result`
  (`human_win`, `ai_win`, `draw`, `aborted`, `unknown`); an `end` before start →
  `practice_not_started`, and a human `end` without a result → `practice_bad_payload`.
  On acceptance it sets the terminal state and cancels any outstanding decision.
  It is idempotent: a duplicate human `end` returns a
  stable `practice_ok` with `"duplicate": true` and writes no second summary.
- **AI END receipt.** Recorded as `ai_end` and **never authorizes teardown on its
  own**. It may arrive before or after the human END. Response:
  `{"ok":true,"code":"practice_ok","role":"ai","recorded":bool,"terminal":bool,
  "ended":bool,"terminal_phase":"none|awaiting_ai|closed"}`.
- **Bounded AI receipt grace.** After a human END with no AI receipt yet, the
  terminal phase is `awaiting_ai` with a bounded `ai_receipt_grace` (default 30 s);
  when it elapses (or the AI receipt arrives) the phase closes. The host keeps the
  loopback server and service until the human exits — this grace only bounds the
  receipt wait, and the human's results state is retained, not required to stay
  pending forever.
- **Exactly one terminal summary, written at closure (M-7).** The single summary is
  written only once the terminal phase reaches `closed` — the AI receipt, the grace
  expiry, an abort, or `close()`. It records the service's own counters, seed,
  difficulty, known lives, duration, result and reason, **plus the AI END's own
  reported result/lives/counters** (`ai_result`, `ai_human_lives`, `ai_ai_lives`,
  `ai_ante`, `ai_round`, `ai_duration_seconds`, `ai_decisions`, `ai_rejected`,
  `ai_errors`) and flags a human/AI winner disagreement as `result_conflict`. Error,
  `error` op, role-lost watchdog, pre-start timeout, explicit `abort()` and
  `close()` all funnel through the same idempotent writer, so a session produces at
  most one terminal summary — never full state. If the human coordinator already
  reported an authoritative END (and the terminal phase is `awaiting_ai`), a later
  abort/close preserves that human `result`/`reason` and records the abort code only
  as `last_error`; the abort never overwrites the human's result.
- **Post-end decision receipts.** `decision_result` is still accepted after the
  human END for sequences this service issued (bounded by the recent-commit ring),
  so the AI's final receipt is recorded rather than lost.

Host-facing APIs: `service.attested`, `service.aborted`, `service.terminal_phase`,
`service.terminal_reason` (only `"human_end"` is a normal completion; every other
value is an abnormal end the host must report as a failure — H-C),
`service.terminal_summary()` (a read-only snapshot of the terminal flags and the
written summary) and the terminal fields in `status` (§3.3). These preserve the
human's retained results state; the host does not need to consume it for the AI
receipt.

### 4.2 Pre-start deadline (M9)

Because the multi-hour match timeout only makes sense after `start`, an attested
but never-started session is bounded by `prestart_timeout` (default 90 s,
disabled when `<= 0`), measured from the trusted host-only
`start_prestart_window()` call that the supervisor makes once the attestation
files are published (falling back to `mark_attested` if it is never called, so
the deadline is never bypassed). Expiry aborts with
`practice_prestart_timeout` and writes the terminal summary. The deadline is
loopback-only and independent of the match timeout.

These are additive APIs; the original coordination ops keep their behavior.

Runtime sequencing is owned by the launcher/runtime driver, not this service: the
original human host `start_lobby` resets lobby config, so for a gauntlet the
custom seed from `setup` must be applied after that reset and before the original
`MP.ACTIONS.lobby_options`. Terminal conditions (`MP.GAME.won`,
`G.STATE == GAME_OVER`) are reported by the trusted engine roles through
`status`/`end`; this module never infers them.

## 5. Decision ops

### 5.0 Canonical observation boundary

A raw client frame never reaches the worker. Before a decision job exists, the
service rebuilds a canonical sanitized export through the **real** observation
factory in a dedicated restricted interpreter that loads only
`AISparring/ai/codec.lua` and `AISparring/ai/observation.lua` (host globals
`io`/`os`/`debug`/`package`/`require`/`dofile`/`load*`/`collectgarbage` removed):

1. The raw client frame is rebuilt as a genuine Lua table with the worker's own
   bounded converter (`policy_worker._to_lua` plus a Lua-owned `newtable`
   factory); a wrapped Python mapping is userdata inside Lua and is never passed
   into the restricted runtime.
2. `Observation.observe(frame)` re-validates and canonicalizes the frame; unknown
   and extra fields are dropped by the schema.
3. `Observation.export(handle)` yields the plain sanitized export.
4. The export is re-observed with the worker's public `opponent.certified`
   reconstruction and its canonical string must equal the first canonical
   string. An unequal roundtrip, an unobservable frame or a failed conversion is
   rejected with `practice_bad_observation` before any subprocess is launched.

Only the resulting sanitized export is placed in the worker request, so a
poisoned raw frame (seed, future shop, hidden order, session secret) cannot
cross the process boundary. This does not define a second observation schema; it
is the existing factory applied one step earlier.

### 5.1 Begin / poll

`decide_begin` (AI only) with `observation` = the canonical exported
observation:

- The observation must be a dict, ≤ 1 MiB serialized, depth ≤ 16.
- The session must be started; otherwise `practice_not_started`.
- If any decision is already pending (including an unpolled completed result)
  the request returns `practice_decision_outstanding`. The slot is single-use
  and is cleared only by `decide_poll`, by a matching wire `decide_cancel`, or by
  `cancel_decision()`/`close()`. `decide_begin` never silently replaces a pending
  job.
- On success the service starts the worker asynchronously and returns
  `{"ok":true,"code":"practice_decision_pending","sequence":N}` immediately, so
  the game main thread is never blocked.

`decide_poll` (AI only) with the same `sequence` and `observation` null/`{}`:

- `practice_decision_pending` — still running.
- `practice_decision_ready` — `action` is the worker-validated action; the slot
  is consumed.
- the bounded failure code (for example `practice_decision_timeout`,
  `policy_bad_source`) — the slot is consumed.
- `practice_decision_unknown` — no job matches that sequence; no state change.

### 5.1.1 Wire cancel (`decide_cancel`)

`decide_cancel` (AI only) is the loop-visible cancel the runtime needs when a
decision is abandoned and reissued. It is a distinct request, not a poll:

- **Envelope:** the request takes a fresh monotonic wire `sequence`, exactly like
  every non-poll op. It is a replay-protected counter, not the cancelled job's
  sequence.
- **Payload:** exactly `{"decision_sequence": <int>}` — the original wire
  `decide_begin` sequence the caller owns. Any other key, a missing key, or a
  non-int value returns `practice_bad_payload`.
- **Matching:** the service compares `decision_sequence` against the **currently
  pending** job. Only an exact match cancels. A request that names a different,
  stale, already-consumed or never-issued sequence returns
  `practice_decision_unknown` and leaves the outstanding job untouched
  (`decision_sequence` is echoed back). One job can never cancel another.
- **Effect on a match:** the owned flag is set and the slot is cleared under the
  service lock (so a worker that races completion cannot finish the job after the
  cancel is accepted), then **only that job's exact child process** is terminated
  — the stored `Popen` handle, never another process. The response is
  `{"ok":true,"code":"practice_decision_cancelled","sequence":N}`.
- **Duplicate/unknown are bounded and non-fatal:** a second cancel for the same
  sequence, or a cancel when nothing is pending, returns
  `practice_decision_unknown` and does not abort the session. The runtime must
  treat `practice_decision_unknown` (and a duplicate cancel) as a benign no-op,
  not as a match-ending error; only a malformed protocol (`practice_bad_role`,
  `practice_bad_shape`, wrong credential/session) is fatal.
- **After cancel:** a poll for the cancelled sequence returns
  `practice_decision_unknown` (the slot is gone), and a fresh `decide_begin` is
  immediately accepted and can reach `practice_decision_ready`.

### 5.1.2 Cancel-timeout contract for the runtime worker

The service worker timeout stays at its existing bounded value (default 10 s,
`decision_timeout`), and the service is the only owner of that child. The
runtime decision loop must budget **longer** than the service so a slow worker is
reported by the service before the loop gives up: use a loop timeout of at least
**15 s plus the poll margin** (for example 15 s + one `poll_interval`), and on a
loop timeout issue a wire `decide_cancel` for the owned decision sequence, then
reissue `decide_begin` with a new sequence. This is the loop's documented
"cancel and reissue" recovery; without it one slow decision ends the match.

### 5.2 Execution result receipt

`decision_result` (AI only) is a separate, narrow reporting channel for the
**actual broker/engine outcome**, distinct from the policy choice and from the
canonical observation input. The payload is strictly bounded:
`{"sequence": int, "accepted": bool, "code": "<bounded code>", "version": int?,
"tick": int?, "reason": str?}`. `sequence` must match a decision this service
issued (bounded by the recent-commit ring), otherwise `practice_decision_unknown`.
A matching receipt is written once to `results.jsonl` (§6). A policy-selected
action is never logged as executed; only a receipt from the runtime is.

Exactly-once per sequence:

- The first receipt for a sequence is logged; the response carries
  `"duplicate": false`.
- An identical repeat returns `practice_ok` with `"duplicate": true` and writes
  nothing more.
- A **conflicting** repeat (`accepted`/`code`/`version`/`tick`/`reason` differ)
  returns `practice_result_conflict` and neither logs nor overwrites the first.
- A rejected first receipt (`accepted: false`) increments the service `rejected`
  counter, which is merged into the terminal summary.
- Receipts remain accepted after the human terminal END for recently issued
  sequences.

### 5.3 Role watchdog

Because staged clients use short per-request connections, a normal disconnect is
not an abort. Instead, every authenticated request refreshes that role's
`last_seen`. Once a session is started, a bounded watchdog aborts the session
(`practice_role_lost`) if a role has been silent longer than `role_timeout`
(default 60 s; disabled when `<= 0`). Abort cancels any pending decision, marks
the session aborted, writes the single terminal summary (§4.1) and returns
`practice_aborted` for every op except `status`/`end`, so both roles see the
failure. `close()` and the explicit `abort()` accessor also clear any pending
decision, so the AI is never left pending after a launcher/session close.

### 5.4 Worker request contract

The service rebuilds the worker request from scratch:

```json
{"runtime":"luajit21", "source":"<repository baseline source>", "observation": <sanitized export>}
```

- `observation` is the canonical sanitized export from §5.0, never the raw
  client frame.
- `source` is rendered once per difficulty from `AISparring/ai/baseline_policy.lua`
  in a restricted `lupa` `LuaRuntime` (`register_eval=False`,
  `register_builtins=False`, host globals removed) that loads nothing else. No
  client-supplied source is ever used, and the renderer is trusted code (it is
  not an OS sandbox).
- `runtime` is always `luajit21`; the worker applies the 64 MiB Lua VM cap.
- The request contains no session id, credential, seed, private token, config,
  log path or raw engine state.
- The worker runs in a separate process with a hard timeout (default 10 s). On
  timeout the exact child is killed and the decision fails
  `practice_decision_timeout`. Output is read bounded and must parse as the
  worker's bounded JSON response.

## 6. Logging

`LocalLogger` writes bounded JSONL under `log_root`:

- `decisions.jsonl` — `timestamp, tick, session, ruleset, difficulty, phase,
  hash, legalcount, action, reason, latency, version, errors, seed`. `action` is
  a bounded summary (type and ref counts only); the observation and credentials
  are never logged. `hash` is the canonical observation hash from §5.0.
  `legalcount` is `null` here because candidate counting is owned by the runtime
  decision loop, which has its own trusted logger. `seed` is the **trusted**
  seed only, never a seed taken from a request or observation.
- `summary.jsonl` — exactly one terminal row per session, written by the
  idempotent terminal writer once the terminal phase closes (human `end` + AI
  receipt/grace, `error`/abort, role-lost, pre-start timeout or `close()`). Fields:
  `result, reason, human_lives, ai_lives, ante, round, duration_seconds, decisions,
  rejected, errors, terminal, terminal_phase, human_end_received, ai_end_received,
  ai_result, ai_human_lives, ai_ai_lives, ai_ante, ai_round, ai_duration_seconds,
  ai_decisions, ai_rejected, ai_errors, result_conflict, seed`. The
  `decisions`/`rejected`/`errors` values **merge** the service's own counters with
  the bounded client counts using `max(...)` — a client can never overwrite the
  service counters downward — and only known lives/duration/result/reason are
  included, never full engine state. The `ai_*` fields record the AI END's own
  report and `result_conflict` is true when the human and AI winners disagree (M-7).
- `results.jsonl` — the broker/engine receipt rows from §5.2: `timestamp,
  session, ruleset, difficulty, sequence, accepted, code, version_id, tick,
  reason, seed, version`. One row per sequence.

The seed is set **only** through the trusted `status` setter (validated
`[0-9A-Za-z_-]{1,32}`), **only** by the human role (validated before any
existing-seed/idempotence handling, so a same-value human repeat can never bypass
it), **only once** (a different second value is refused; an identical human repeat
is an idempotent no-op), **only** in a started, non-terminal, non-aborted session
(pre-start → `practice_not_started`, terminal/aborted late → `practice_ended`), and
in Gauntlet mode **only** when it equals the trusted catalog seed (M-6). It is
never taken through a policy request and is never forwarded to the worker. The
service does not read environment variables; credential/env wiring is reserved for
the launcher.

## 7. Bounded codes

`practice_ok`, `practice_bad_line`, `practice_input_too_large`,
`practice_output_too_large`, `practice_bad_request`, `practice_bad_shape`,
`practice_bad_session`, `practice_bad_credential`, `practice_bad_role`,
`practice_bad_op`, `practice_bad_sequence`, `practice_replay`,
`practice_rate_limited`, `practice_busy`, `practice_not_ready`,
`practice_config_mismatch`, `practice_content_mismatch`, `practice_no_lobby`,
`practice_already_started`, `practice_config_frozen`, `practice_not_started`,
`practice_not_attested`, `practice_prestart_timeout`, `practice_result_conflict`,
`practice_ended`, `practice_closed`, `practice_bad_payload`,
`practice_bad_observation`, `practice_decision_outstanding`,
`practice_decision_unknown`, `practice_decision_pending`,
`practice_decision_ready`, `practice_decision_timeout`,
`practice_decision_cancelled`,
`practice_source_unavailable`, `practice_canonical_unavailable`,
`practice_worker_failed`, `practice_aborted`, `practice_role_lost`,
`practice_internal_error`, plus worker codes such as `policy_bad_source`.

Failures are bounded; no callback, exception object, trace, path or secret is
returned.

## 8. Lua integration

`AISparring/integration/control_protocol.lua` mirrors the constants and builds
the exact six-key envelope. JSON encode/decode stays with the runtime
transport; the module only builds the message table and inspects a decoded
response table:

```lua
local ControlProtocol = dofile("AISparring/integration/control_protocol.lua")
local message = ControlProtocol.envelope(session, credential, "ai", "hello", sequence, payload)
-- transport: write json_encode(message) .. "\n"; read one line; json_decode
local response = ...
if ControlProtocol.is_ready(response) then ... end
```

The module is pure: no globals, no `require`, no `io`/`os`/`love`/`NFS`. It
contains no seed selection logic and no transport commands.

## 9. Tests

`python tests/test_practice_service.py [--require-all]` exercises the real
module:

- config/gauntlet validation, random distinct credentials, loopback-only bind;
- strict envelope shape, session/credential/role auth, per-op role rules,
  replay and ordering, per-role independence;
- rate-limit and connection-slot bounds, request/observation size and depth;
- begin/poll lifecycle, single outstanding slot, unknown-poll safety,
  start requirement;
- wire `decide_cancel`: a real owned job is cancelled and only its exact child
  dies, the slot frees and a new decision reaches `practice_decision_ready`; a
  wrong `decision_sequence` returns `practice_decision_unknown` and leaves the
  owned job running to completion; human role rejection, exact-payload
  validation, envelope replay and duplicate/unknown bounded non-fatal codes;
- canonical observation boundary: a poisoned raw frame (seed, future shop,
  hidden order, session secret) is re-sanitized so none of those fields reaches
  the captured worker request, a malformed frame is rejected, and the decision
  row carries the trusted seed rather than the observation seed;
- hidden-request capture (no credential/session/seed/config in the worker
  request), real worker timeout with exact-child termination, failure
  propagation to both roles, cancel/close cleanup;
- coordination lobby/join/ready/start, config mismatch, freeze, one-time start,
  trusted `setup` (forced keyset + expected digest), heartbeat/watchdog abort;
- the attestation gate: gated ops refuse with `practice_not_attested` before the
  trusted `mark_attested`, `status` still works, a mismatched attestation digest
  is refused, and `mark_attested` is not a wire op;
- the digest contract: `fnv1a32_hex` and `major_league_digest` parity against the
  real Lua `codec.lua`, and `ready` pinned to the host-derived expected digest;
- the terminal lifecycle: AI-only END does not terminate, human END requires
  `start` and a terminal result, one idempotent summary, bounded `awaiting_ai`
  phase, post-end decision receipts and exactly-once `decision_result` with
  conflict rejection;
- the pre-start deadline aborting an attested-but-unstarted session;
- decision and summary logging including the trusted seed and the merged
  terminal counters, and the separate `decision_result` broker-receipt rows
  matched to issued decisions;
- real baseline source rendering and a real `tools/policy_worker.py` subprocess
  returning a legal action under LuaJIT 2.1, plus a poisoned-observation probe;
- the Lua `control_protocol.lua` mirror (including the terminal codes/phases);
- a loopback socket round trip with the per-connection rate limit.

No test starts Balatro, reads live paths or contacts an external network.

## 10. Explicitly not implemented here

- No game launch, process control, memory isolation or real-game IPC.
- No Multiplayer transport commands, lobby creation, join or result submission.
- No policy strategy; only trusted source selection and worker invocation.
- No connection to a game match server and no adjudication.
- No environment-variable wiring; the launcher owns credential delivery.
- The service never reads live saves or live game state; it receives only the
  allowlisted observation and reports bounded counters.

## 11. Host / runtime integration deltas

These are the exact contract changes the host (`tools/practice_host.py`, owned
elsewhere) and the staged runtime must make against this service. They are listed
here so the integration lands in one pass.

Host (`practice_host.py`):

1. Pass `expected_config_digest` (host-derived from the pinned
   `rulesets/majorleague.lua`) and, when available, `ruleset_id`, `gamemode` and
   `forced_options` into `ServiceConfig`. Use `major_league_digest(...)` (or the
   equivalent host helper) so the expected value matches the FNV1a32 contract.
2. After both role probes and the open-record check pass, and **before** the
   atomic attestation writer publishes the file, call
   `service.mark_attested(config.expected_config_digest)`.
3. On terminal handling, keep the loopback server and service alive until the
   human exits: read `status`'s `terminal`/`terminal_phase`/
   `human_end_received`/`ai_end_received` (or `service.terminal_summary()`) and
   only wait the bounded AI receipt grace; do not tear down on the AI receipt
   alone, and do not consume the human's results state.
4. Surface the terminal result/reason in the menu ticket (status carries them).
5. The match server may need to listen before the role spawns (H3) — that is a
   host ordering fix, orthogonal to this service.

Runtime (`AISparring/integration/*`):

1. Companion/observer must read the frozen `BALATRO_AI_ROLE` /
   `AISP_EXPECTED_ROLE_*` names (H2) — host/companion scope, unchanged here.
2. The runtime computes the **actual** Major League digest from the live
   `MP.LOBBY.config` forced values locally and sends it as `ready.config_digest`;
   it must never echo the `expected_config_digest` returned by `setup`.
3. `end` must be sent as the human coordinator only, with a terminal result,
   after start; the AI role sends its END as a receipt (before or after).
4. Treat `practice_not_attested`, `practice_config_mismatch`,
   `practice_result_conflict` and `practice_ended` as bounded, non-crashing
   codes. The cross-service fixture
   (`tests/test_runtime_cross_service.py`) must be updated to call
   `mark_attested` and to pass an `expected_config_digest`.
