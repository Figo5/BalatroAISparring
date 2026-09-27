# M2 execution boundary — trusted action broker and policy capability proof

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: bounded M2 implementation, revised after Astra code review. No live files, no
game, no AI strategy, no evaluator. Real action execution is disabled for all of M2.

This guide covers:

- `AISparring/integration/action_broker.lua` — the trusted submission broker.
- `tools/policy_worker.py` + `tools/lua/policy_env.lua` — a standalone development
  worker that proves the separate-interpreter capability direction.
- `tests/run_boundary.py` + `tests/boundary/*` — the independent boundary harness.

It does not modify `AISparring/ai/*` (owned by another worker) and does not implement
the policy strategy. It never loads game state, engine modules or live files.

## 1. Trusted action broker

### 1.1 Factory and injected interfaces

```lua
local broker = ActionBroker.factory(observation, actions, ports)
```

`observation` exposes `export(handle)`, `canonical(handle)`, `is_handle(handle)`.

`actions` exposes `generate(handle) -> list, code` and
`validate(handle, action) -> normalized_action_or_nil, code`. Action identity is the
full canonical action content, never a hash or a caller id.

`ports` is part of the trusted computing base:

- `capture() -> handle, epoch` — captured **atomically**. The broker validates the
  handle with `observation.is_handle` and validates the epoch itself, so a separate
  numeric/function `ports.epoch` cannot desynchronize from the captured handle.
- `validate(normalized_action, handle) -> true` — trusted engine/UI legality check;
  only the exact value `true` is accepted.
- `dispatch(normalized_action)` — reached **only** when
  `ports.fixture == "M2_FIXTURE_ONLY"` (the distinctive sentinel required by review
  L7). Any other value, including the boolean `true`, leaves the broker in production
  mode and `dispatch` is never called.
- `fixture` — explicit sentinel. When it is not the sentinel string, `dispatch` is never
  called.

Missing or malformed interfaces fail closed at `factory`. A sentinel fixture-mode
factory without a `dispatch` function is rejected.

### 1.2 Single pending decision and in-flight guard

The broker holds exactly **one** pending decision token.

- `issue()` replaces (invalidates) any previous token.
- While `issue`/`submit` is executing its trusted phase, `in_flight` is set. A nested
  `issue()`/`submit()` from a callback returns `broker_busy` and marks reentry; the
  outer call then fails `broker_reentrant` before any dispatch. This removes the
  multi-token nested-recursion surface.
- The token is a fresh opaque table (protected metatable) and the module-private
  registry is the authority, not any property of the token table.

### 1.3 `issue()`

`local token, request = broker.issue()` on success, or `nil, code`.

- Captures a fresh `handle, epoch` atomically and reads the canonical bytes.
- Requires a non-negative integer epoch and rejects any regression against the last
  epoch observed by this broker.
- Copies the exported observation and generated action list into fresh, bounded, plain
  primitive tables (`request.observation`, `request.actions`) with no functions,
  userdata, metatables or live references.
- Returns a separate opaque fresh token bound to the captured epoch and canonical
  bytes.

### 1.4 `submit(token, action)`

Returns `true, "broker_ok"` only in fixture mode; otherwise `nil, code`.

1. Token must be a broker token and match the pending token by `rawequal` identity.
2. The token is consumed **immediately** after that identity check, before any
   structural, capture or callback check (review M3). Every attempt is therefore
   single-use: a malformed action, a stale capture, a failed validator or an escaping
   fault all leave the token gone, and a replay returns `broker_token_unknown`.
3. The action must be a bounded plain table.
4. A fresh atomic `handle, epoch` capture is compared with the pending record:
   changed epoch fails `broker_stale_epoch`, changed canonical bytes fail
   `broker_observation_changed`, a regressed epoch fails `broker_epoch_regression`.
5. `actions.validate(handle, action)` must return a normalized action (exact candidate
   membership).
6. The trusted validator receives an **independent bounded copy**, so mutations of the
   passed table cannot alter the preserved validated action.
7. After the trusted callback the broker recaptures a **new** handle and compares epoch
   and canonical bytes with the start capture, which detects state changed during
   validation (the previous design re-read the same immutable handle and could not).
8. Reentry is re-checked; the preserved validated action is what would be dispatched.
9. Sentinel fixture mode: `ports.dispatch(validated)` runs once. Production mode: no
   dispatch is performed and the result is `broker_executor_disabled`, never a silent
   success.

Rejections cover stale epoch, ABA/observation change, epoch regression, replay,
unknown/forged token, cross-broker token, malformed/illegal action, failed or throwing
validator, capture failure, reentry, and dispatch failure. Only bounded codes are
returned; callback data, error objects, traces and paths never leave the broker. The
broker never mutates the observation, the action or engine/MP globals.

**Epoch / revision definition (review M3).** `ports.capture`'s `epoch` is a trusted
revision that must strictly increase on **every** change to the captured AI state,
including a change that returns the visible content to an earlier value (A→B→A). The
broker treats a changed revision as stale and a lowered revision as
`broker_epoch_regression`. Because the broker only sees revisions that `capture`
reports, an unobserved A→B→A is detectable **only if the revision is honest**; a
producer that changes canonical bytes without advancing the revision is caught by the
canonical comparison, but a producer that reverts both bytes and revision between two
captures is a TCB limitation, not something an in-process capture can detect. This is
explicit producer/TCB trust, and real launcher-owned revision provenance remains a
production gate.

### 1.5 Bounded codes

`broker_ok`, `broker_bad_observation`, `broker_bad_actions`, `broker_bad_ports`,
`broker_capture_failed`, `broker_epoch_invalid`, `broker_epoch_regression`,
`broker_canonical_failed`, `broker_generate_failed`, `broker_busy`,
`broker_token_invalid`, `broker_token_unknown`, `broker_stale_epoch`,
`broker_observation_changed`, `broker_action_malformed`,
`broker_action_not_candidate`, `broker_validate_failed`, `broker_reentrant`,
`broker_executor_disabled`, `broker_dispatch_failed`, `broker_internal_error`.

The in-flight guard is exception-safe: the whole trusted phase runs under `pcall`, and
an escaping fault resets `in_flight` and returns the bounded `broker_internal_error`
rather than leaving the broker permanently busy (self-review F4). This is now covered by
a real escaping-fault test, not only a static check (review I2): the fixture removes
`ports.capture` and installs a `__index` that raises, so the fault escapes the inner
`pcall` and is caught by the outer guard; the broker then recovers and completes a later
decision. Capture-fault, validator-fault and reentrant-recovery tests also pass.

Token consumption is intentional and now happens **immediately** after the `rawequal`
identity check (self-review F5, widened by review M3): any attempt — malformed action,
stale capture, failed validator, reentrant callback or escaping fault — consumes the
single pending decision. Anti-replay is preserved; the consequence is a trusted-caller
DoS/UX cost requiring a new `issue()`.

A broker instance is per session (self-review F10): a session restart constructs a new
broker, because an epoch lower than the last observed epoch is rejected as
`broker_epoch_regression` and is not auto-reset.

Internal `CODE`/`LIMITS` are private locals; `ActionBroker.CODE`/`LIMITS` and
`instance.CODE`/`LIMITS` are copies, so mutating an exported table cannot change
validation. The module references no game globals (`G`, `MP`, `SMODS`, `Client`,
`love`, `NFS`) and no non-standard Lua globals.

## 2. Policy capability proof worker

### 2.1 Why a fresh interpreter

A fresh, separate Lua interpreter is used, not `setfenv` inside the engine state. The
engine shares a string metatable with installed libraries and mods, so a policy
sharing engine state could reach host extensions through shared library tables. The
worker's interpreter contains only the base standard library of a new `lupa` runtime;
no game or custom extension is loaded into it.

### 2.2 Runtime construction (fail closed)

The runtime is created with explicit `register_eval=False`,
`register_builtins=False` and `max_memory=64 MiB`. `inspect.signature` is not used
(it does not reliably report C-constructor keywords); if the installed Lupa rejects
`max_memory` the worker fails closed with `policy_memory_limit_unsupported` rather
than running unbounded. The `python`/`python_builtins` globals are cleared and the
clear is verified fail-closed (`policy_env_hardening_failed`); `package.loaded.python`
is cleared too, so no dangling Python object can be reached or exported (review I1).
Only JSON primitives are ever converted back out.

### 2.3 Trusted module loading (schema boundary)

The request is `runtime`, `source`, `observation` only — the `actions` field is gone.
The worker reads and loads **only** the trusted repository modules
`AISparring/ai/codec.lua`, `observation.lua` and `actions.lua` into the fresh
interpreter's global environment.

The supplied observation is treated as untrusted canonical-export data:

1. It is deep-copied and reconstructed as a frame; `opponent.certified = true` is
   re-added because the broker export only contains opponent fields that were already
   certified. Unknown fields stay unknown and are dropped by the schema.
2. `Observation.observe(frame)` re-validates and canonicalizes the frame.
3. `Observation.export(handle)` gives the re-sanitized plain export handed to the
   policy.
4. `Actions.generate(handle)` regenerates the legal action candidates from the trusted
   observation; the caller can never supply candidate actions.
5. The policy's selection is re-validated with `Actions.validate(handle, candidate)`
   against the canonical handle. A forged, mutated or out-of-range selection is
   rejected; policy mutation of the input candidates cannot grant authority.

Policy code receives only the re-sanitized export and the regenerated plain actions.

### 2.4 Restricted environment

The helper deep-copies the observation and actions into fresh bounded plain tables and
builds a whitelist environment containing only:

- `string` (`byte char sub len rep lower upper format find match gsub gmatch reverse`),
  `table` (`insert remove concat sort`), `math` (`floor ceil abs min max huge`);
- `type`, `tostring`, `tonumber`, `ipairs`, `pairs`, `next`, `select`, `unpack`,
  `rawget`, `rawset`, `rawequal`; `tostring` is restricted to primitives (string,
  boolean, nil, number) so table/function/userdata memory addresses are never produced
  (review L2). `pairs`/`next` iteration order is unspecified; the observation canonical
  string stays deterministic because it is produced by the trusted codec, not by policy
  iteration;
- the copied `observation` and `actions`.

Not exposed: `_G`, `require`, `package`, `debug`, `io`, `os`, `love`, `NFS`, `Client`,
`SMODS`, `getfenv`, `setfenv`, `load`, `loadstring`, `dofile`, `collectgarbage`,
`coroutine`, `setmetatable`, `getmetatable`, `pcall`/`error`/`assert`, and any RNG API.
Removing `pcall` also removes the policy's ability to swallow the budget exception.

The string-method route is closed too (self-review F1). The shared string metatable's
`__index` is repointed to the same whitelist table for the duration of the policy call
and restored afterwards, so `("x").dump` and every other non-whitelisted standard string
function are unavailable exactly as `env.string.dump` is. Direct (`string.rep`) and
indirect (`("ab"):rep(2)`) routes therefore share one whitelist, while whitelisted
methods keep working. This mutates the string metatable of the interpreter, so the
helper must only ever be loaded into a fresh, dedicated development interpreter and must
never be loaded into the game VM; the worker always constructs such an interpreter.

As a tripwire against accidental game-VM use, the helper refuses to run (bounded
`policy_engine_vm_refused`) when any of `G`, `MP`, `SMODS` or `love` exists in its
interpreter globals, checked before module loading and before the string-metatable
mutation (review L7). The module-load-time JIT disable is guarded by the same check
(`if (not engine_vm_present()) and jit ...`), so merely loading the helper in a
game-like environment mutates nothing: no JIT change, no string-metatable change and no
debug hook. `configure` returns false and `run` returns the bounded refusal. The worker's
fresh interpreter never has engine globals, and a dedicated module-load test
(`tests/boundary/test_load_tripwire.lua`) loads the helper with each engine global
present and asserts no mutation plus the bounded refusals.

### 2.5 Execution bounds

- Source must be text-only, non-empty and within a 64 KiB source cap enforced by both
  the worker and the helper (review L8); a leading bytecode signature (`0x1b`) is
  rejected.
- `loadstring` + `setfenv` compile into the whitelist environment; a chunk that does not
  return a function is rejected.
- The policy is called as `function(observation, actions)` and may return an action
  record or a 1-based index into `actions`.
- A `debug` count hook enforces the instruction budget. The prior hook is saved and
  restored, the budget hook clears itself before raising, and an `exhausted` flag is
  checked after unwinding, so the budget is reported even if the source catches errors
  indirectly. JIT is disabled when present.
- `string.rep`, `string.format` and `table.concat` are wrapped with a 64 KiB result cap
  (checked before `rep`/`concat` and after `format`); exceeding it raises a trusted
  error that the policy cannot catch and becomes a bounded `policy_runtime_error`. The
  `rep` wrapper rejects `count > 65536` regardless of the input length, returns `""`
  immediately for an empty string or zero count (avoiding the Lua 5.1 C-level loop over
  an empty string), and requires a finite integer count (review L1). These wrappers
  reduce, but do not remove, native-C-call cost; see §2.9.
- `string.format` is restricted to a conservative, Lua 5.1-compatible safe subset (review
  N1). The format string must itself be a string; every variadic argument must be a
  string or a number, checked with `select("#", ...)`/`select(i, ...)` **before**
  delegating. The format string is scanned and only `%%` plus the normal number/string
  conversions `d i o u x X e E f g G c q s` are allowed; flags, width, precision and `*`
  are accepted only in front of an allowed conversion. Pointer/address conversions such
  as `%p` (a LuaJIT extension, including with width/flags such as `%5p`) and any unknown
  conversion are rejected, so no memory address can be produced through either the
  direct (`string.format`) or method (`("%d"):format`) route. Primitive formatting such
  as `string.format('%d/%s/%.2f', 7, 'x', 1.5)` and escaped `%%` still work. There are no
  callbacks and no address conversions in the subset.
- The helper returns only `{ ok, code, action }`, where `action` is a fresh bounded
  plain copy. The worker emits only that selected record plus a bounded code.
- The orchestrator/broker must re-validate before any effect; the worker has no
  authority and no side effects.

### 2.9 Memory and timing limits (honest scope)

- **The in-process helper has no memory or wall protection of its own.** `PolicyEnv.run`
  is a private, fresh-interpreter-only loader; it does not enforce a memory cap or a
  wall-clock deadline. The only memory bound on this path is the Lua VM cap the
  *worker* requests from Lupa (`max_memory`, 64 MiB) when it constructs the interpreter.
  The Python-side input caps are separate again: `--input` is read with a bounded
  binary read of `MAX_INPUT_BYTES + 1` bytes and stdin is read with the same bound, so
  an oversized file is rejected by size rather than fully loaded. The Lua VM cap, the
  Python input cap, and the wall clock are three independent limits and none implies
  another.
- **A caller process deadline is mandatory.** Because the helper itself provides no
  wall protection, the caller must run it behind an OS process deadline (and, later,
  process/memory isolation). This is a required contract, not an optional extra; the
  boundary harness enforces a 10-second subprocess timeout, and production launcher
  process control remains disabled/unimplemented.
- **C-library operations are not covered by the Lua hook.** The instruction budget is
  a `debug` count hook on interpreted Lua. Native library work (for example large
  `string.rep`/`string.gsub` results, `table.concat`, or pattern matching) can consume
  real time and memory without a proportional number of counted instructions; the Lua
  VM memory cap is the guard there, and it is a guard, not a hardbound on wall time.
- **Caller wall-clock timeout is required.** Budget and memory limits are in-process
  guards only. A policy can still consume wall time, so the caller must enforce a
  process timeout (and later OS process/memory isolation) before running anything
  untrusted. The boundary harness enforces this with a 10-second subprocess timeout;
  production launcher process control and real-game IPC remain unimplemented.
- **The 64 MiB VM cap is evidenced by a discriminating pair (review M8).** On both
  runtimes a policy that builds a 16 MiB string (65536 chars doubled 8 times) must
  succeed and return a valid action, while the same with 11 doublings (~128 MiB) must
  fail with `policy_runtime_error` within the 10-second deadline. This distinguishes a
  real VM cap from a host allocator failure or a Lua string-length overflow, and
  confirms Lupa honours `max_memory` under both Lua 5.1 and LuaJIT.
- No claim is made that the Lua hook covers C-library execution, blocking calls or
  native code.

### 2.6 Worker protocol

Request (all keys required, unknown keys rejected), bounded in size:

```json
{"runtime": "lua51",
 "source": "return function(observation, actions) return actions[1] end",
 "observation": {"phase": "PLAY_HAND", "...": "canonical export"}}
```

Response `{"ok": true, "code": "policy_ok", "action": {"...": "validated action"}}`
or `{"ok": false, "code": "<bounded code>"}`. Malformed/foreign/raw JSON, unsupported
runtime, unsupported memory limit, oversized input/output, missing helper/module,
compile/load failure, runtime error, budget exceeded, no action, bad index and bad
action all fail with bounded codes. No traces, paths or error text appear in the
response; observation inputs are never logged or persisted. Importing the module does
no work; execution only happens through the explicit command (`python
tools/policy_worker.py` reading stdin, or `--input PATH`).

### 2.7 Bounded codes

`policy_ok`, `policy_bad_input`, `policy_bad_runtime`, `policy_bad_source`,
`policy_input_too_large`, `policy_output_too_large`, `policy_helper_missing`,
`policy_module_missing`, `policy_runtime_unavailable`,
`policy_memory_limit_unsupported`, `policy_env_hardening_failed`,
`policy_internal_error`, plus helper codes (`policy_bytecode_rejected`,
`policy_compile_failed`, `policy_load_failed`, `policy_runtime_error`,
`policy_budget_exceeded`, `policy_no_action`, `policy_bad_index`, `policy_bad_action`,
`policy_bad_observation`, `policy_bad_actions`, `policy_not_configured`,
`policy_engine_vm_refused`).

### 2.8 Conservative projection loss

The re-sanitization is deliberately lossy and safe:

- Opponent `certified` is reconstructed from an already-certified export; uncertified
  or extra opponent fields are schema-dropped, and an opponent with no permitted field
  disappears.
- Redacted entities carry no identity; their `id` is re-derived from the observation
  ordinal, and absent `face_down = false` keeps them redacted.
- `hand_visible` absent or false yields no hand; unopened/future shop, booster and deck
  order are not representable.
- Certificate entries with `certified = false` are withheld, so regenerated actions can
  be a strict subset of what the producer offered.
- Unknown fields at any level are ignored without traversal, so poisoned secrets in the
  supplied JSON never reach the policy.
- No checksum is trusted; only canonical-string equality and re-validation are used.
- The JSON bridge is schema-aware for action array fields: `card_refs`, `target_refs`
  and `order` are emitted as arrays, so an empty selection serializes as `[]`, not `{}`
  (self-review F3). An empty-target `USE_CONSUMABLE` therefore round-trips as
  `"target_refs":[]` and re-validates.

The dev worker trusts the supplied export's opponent/certificate provenance (self-review
F6/F7); in production the broker owns the worker input, and real producer authentication
is a launcher prerequisite.

## 3. Tests

`python tests/run_boundary.py --require-all` runs independently of the other harness:

- static source-drift checks for the required fixes;
- `tests/boundary/test_broker.lua` on both `lupa.lua51` and `lupa.luajit21`;
- `tests/boundary/test_load_tripwire.lua` on both runtimes (loads the helper with each
  engine global present and asserts no JIT/string-metatable/hook mutation);
- `tests/boundary/test_policy_env.lua` on both runtimes;
- worker cases as real subprocesses via `sys.executable` (10-second timeout, inherited
  `PYTHONPATH`), covering malformed input, oversized `--input` files (bounded read in a
  native-Python temporary directory) and oversized source, budget exhaustion, the
  discriminating 16 MiB-succeeds / 128 MiB-fails memory pair, `rep` guards, primitive
  `tostring`, the `format` safe subset (table/function arguments and `%p` direct/method
  rejected, primitive formatting allowed), closure/cycle/function results, bytecode,
  secret field injection,
  forged/mutated selections, global/string-method escapes, and roundtrip probes for
  redacted cards, public opponent fields, consumable `source_ref`, and no
  caller-provided-action authority.

Unique-case counts are deduplicated logically: each worker case contributes one
`worker::<name>` unique name even though it executes once per runtime, while the
per-runtime execution count is retained.

Recorded result on this machine (Python 3.12, lupa 2.8): 23 static, 59 Lua 5.1, 59
LuaJIT 2.1, 78 worker subprocess executions over 41 logical worker cases, 123 unique
cases, 219 total executions, all passing.

Fixes landed for the Claude M2 review (this file's scope only):

- **M3** token is consumed immediately after the `rawequal` identity check; epoch is
  defined as a strictly increasing revision; A→B→A after a failed submit, unseen A→B→A
  with strict revision, and a constant-revision canonical-change bad fixture are tested;
  the fixture rebuild now advances the revision on every state change.
- **M8** discriminating memory pair (16 MiB must succeed, 128 MiB must fail) on both
  runtimes.
- **L1** `rep` guard (count cap independent of length, empty returns immediately, finite
  integer count) with direct and method tests.
- **L2** `tostring` restricted to primitives; iteration order documented as unspecified.
- **L7** fixture sentinel `M2_FIXTURE_ONLY` (boolean no longer enables dispatch) and the
  helper's `G`/`MP`/`SMODS`/`love` engine-VM tripwire.
- **L8** 64 KiB source cap in the helper (the worker already had one).
- **I1** runtime hardening (`python`, `python_builtins`, `package.loaded.python`) is
  fail-closed.
- **I2** a real escaping fault through the outer guard is tested (fixture `__index`
  raises on `ports.capture`), with recovery and `broker_internal_error`.
- **N1** (re-review Low) `string.format` now requires a string format and rejects any
  non-string/number variadic argument before delegating, and rejects pointer/address and
  unknown conversions (including `%p` with width/flags) via a conservative Lua
  5.1-compatible allowlist, on both the direct and method routes.

Earlier fixes remain: the worker Lua-table constructor bug, the bounded `--input` read,
the string-metatable whitelist (F1), the exception-safe guard (F4) and the empty-array
JSON shape (F3). Self-review F5/F10 remain documented intended behaviour.

## 4. Explicitly not implemented

- No legal-action strategy/evaluator; only loader/execution infrastructure.
- No production dispatch, raw engine writes or Multiplayer callbacks.
- No launcher, process control, memory isolation or real-game IPC.
- No live game capture, live file writes, game or server launch.
- The broker is intentionally not wired into `core.lua` and loads no AI modules at
  startup.

This is a capability boundary for project-owned software, not a memory-safe OS sandbox
against arbitrary hostile native exploits. Production process/memory isolation and the
real executor remain future prerequisites, and the broker's dispatch path is
fixture-only for M2.
