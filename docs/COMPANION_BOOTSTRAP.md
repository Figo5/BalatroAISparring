# Root companion wiring (`AISparring/core.lua` + `AISparring/integration/companion_host.lua`)

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: implementation of the root companion gate and host adapter for the
playable slice (`docs/PLAYABLE_RUNTIME_CONTRACT.md`, `docs/PRACTICE_MENU.md`,
`docs/STAGED_RUNTIME.md`, `docs/PRACTICE_SERVICE.md`). Fixture/static verified
only. No game launch, no Mods write, no live install, no network, no process
launch, no Git operation. **This is not a playability claim and not evidence that
the companion is armed in a real game.**

## 1. What this chunk owns

- `AISparring/core.lua` — the entrypoint gate: keeps the Milestone 1 dependency
  / state inspection and feature flag, then optionally boots the companion.
- `AISparring/config.lua` — the install-time descriptor (repository default is
  inert).
- `AISparring/AISparring.json` — developer build metadata (`0.1.0-dev`).
- `AISparring/integration/companion_host.lua` — the live menu host adapter, the
  staged descriptor reader and the `Game:update` chain wrapper.
- `tests/run_companion.py` + `tests/companion/*` — the fixture/static suite.
- this document.

It does **not** modify the menu UI, the runtime bootstrap/driver/transport, the
broker/decision loop/engine modules, the Python host/service/staging or the
launcher. Those are other workers' files and are only consumed.

## 2. Load-time behaviour (repository default)

`config.lua` returns `{ ai_enabled = false, companion = { role = nil, ... } }`.
With the default install:

1. `core.lua` loads only the five M1 modules (`src/status.lua`,
   `src/logger.lua`, `src/ai_mode.lua`, `src/dependency.lua`, `src/host.lua`).
2. It inspects Multiplayer read-only and publishes the M1 scaffold status on its
   own mod entry (`SMODS.Mods["AISparring"].aisparring.get_status()`).
3. No UI module, no transport, no thread, no process and no gameplay hook is
   touched. `Game.update` is left exactly as it was.

Setting `ai_enabled = true` without an installed `companion` descriptor still
loads only the five M1 modules and reports
`ai.status = requested_no_companion_config`. The companion is only
attempted when **all** of the following hold:

- the Multiplayer dependency is present, enabled, loadable, structurally
  complete and exactly `0.5.5` (the M1 dependency verdict is `satisfied`);
- `SMODS.Mods["AISparring"].config` has a strictly boolean `ai_enabled = true`;
- `config.companion.role` is exactly `"live"` or `"staged"`.

If the companion cannot arm, the entrypoint reports
`state = "companion_unavailable"` with a bounded code and the normal game keeps
working; capability flags are never raised and no partial authority is left
behind. A throwing boot is contained by `pcall`.

## 3. Install-time configuration (`config.lua`)

The final installer rewrites the installed copy of `config.lua`. The repository
default may stay disabled.

```lua
return {
  ai_enabled = false,          -- must be boolean true to arm the companion
  companion = {
    role = nil,                -- "live" | "staged"
    discovery_path = nil,      -- live: absolute path under repo work/
  },
}
```

- `discovery_path` is the fixed practice-host discovery marker
  (`work/aisparring-host/practice_host.json`). The live host reads it through a
  trusted read adapter, never from policy and never from the network.
- There is **no** `attestation_path` override in the repository configuration.
  The staged attestation file path is derived from the launcher's expected role
  save root: `<AISP_EXPECTED_ROLE_SAVE_ROOT>/aisparring-launcher-attestation.json`.
- No credential, session, control secret, port or seed is ever placed in this
  file.

## 4. Live path

`CompanionHost.factory({ role = "live", ... })` builds the reviewed menu
controller (`ui/practice_menu.lua` + `integration/menu_controller.lua`) and the
`host` adapter, then installs the wrap on
`G.UIDEF.override_main_menu_play_button`. The button only appears when the
status probe reports the actual main menu, a compatible Multiplayer install and
a valid launcher host; the wrapper returns every original node untouched
otherwise.

### 4.1 Discovery marker validation

The marker read from `discovery_path` is validated against the actual schema
before it is trusted:

| Field | Requirement |
|---|---|
| `schema` | exactly `aisparring.practice_host.discovery.v1` |
| `version` | exactly `practice_host/1` |
| `host` | exactly `127.0.0.1` |
| `port` | integer `1..65535` |
| `secret` | 32–128 hex characters (control auth; never logged) |
| `session` | token `[0-9A-Za-z][0-9A-Za-z_.:-]{0,127}` |
| `pid` / `create_time` | positive integer / finite number, matching the live process identity |
| `ops` | includes `start` and `poll` |
| `enums` | difficulty/pacing/mode/gauntlet exactly the fixed sets |

Fresh identity is enforced with a query-only Windows query
(`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `GetProcessTimes` +
`CloseHandle`) through the real LuaJIT `ffi` module. A loaded FFI C library is a
userdata whose symbols are callable cdata, so the adapter resolves each symbol
through a protected lookup rather than a table/`rawget` shape test; the
`DWORD`/`HANDLE` results are converted with `tonumber` and a null handle is
recognised as `nil`. The trusted entrypoint obtains `ffi` itself (global first,
then a protected `require("ffi")`), because the game's main/preflight source does
not initialise a global `ffi`; policy never sees it. A missing module/symbol, a
failed load, an invalid pid, a failed or throwing query and a null handle all
fail closed. The handle is released on every path, including a failed query, and
only `PROCESS_QUERY_LIMITED_INFORMATION` is ever requested: no kill/spawn API is
used and nothing is terminated. A stale or misidentified `pid` fails closed; no
marker value is ever trusted on its own.

### 4.2 Request flow

`host.available()` is a local check (marker + identity + a constructable
transport); it performs no blocking network call on the main thread.

`host.request_start(selection)` re-validates the selection enums/index, binds the
**current process** `pid`/`create_time` from the same trusted query, maps a
gauntlet index to the host-owned label `Test<N>` (the seed is never seen here)
and sends exactly `{schema, op, auth, request}` over the bounded nonblocking
LÖVE worker (`integration/control_thread.lua`, newline JSON, `127.0.0.1` only,
2 MiB out / 64 KiB in). `host.poll_start(id)` drains one response nonblockingly.
Only a confirmed accepted ack lets the reviewed controller invoke the injected
normal quit (`love.event.quit`) exactly once; cancel, rejection, timeout and
error never quit. The controller reads its own trusted clock — the live companion
update calls `controller.update()` with no argument — so the bounded 10 s
acknowledgement timeout actually fires (passing the frame delta as "now" made
`now - started_at` negative and the timeout dead).

### 4.3 Transport

The default transport is the reviewed `control_thread.lua` relay worker wrapped
over its two channels; tests inject a transport. The worker never carries
credentials in either direction beyond the authenticated request envelope, and
the secret is never logged or placed on a status surface.

A transport whose worker has errored (`last_error()`) or stopped
(`worker_stopped()`) can never answer a new request, so `ensure_transport`
rebuilds it on the next attempt instead of reusing the dead one. One transient
worker failure therefore does not stick forever; no start request is replayed
automatically and the companion still never quits before an accepted ack.

## 5. Staged path

`CompanionHost.factory({ role = "staged", ... })` reads only the strict launcher
environment descriptors, validates types/bounds/enums, derives the module root,
then waits (bounded, nonblocking) for the independently written launcher
attestation to appear at the derived save-root path. Only then does it invoke the
real `RuntimeBootstrap.factory`/`install()` with the actual `G`, `MP`, `SMODS`,
`love`, `Client` and path functions. The pure codec (`ai/codec.lua`) is part of
the **common** staged set for BOTH roles: the runtime driver builds the actual
source-derived Major League config digest with `Codec.hash_string`, and the human
host must reach READY too. The AI role additionally receives the policy/executor
module set (`StateReader`, `EngineAdapter`, `ProductionExecutor`,
`StateRevision`, `ActionBroker`, `DecisionLoop`, `observation`, `actions`); the
human role never does. The engine's source-backed
`element_for` default is left to the executor (the companion passes nil rather
than a fabricated lookup), and the AI-staged role receives source-backed
`CardArea`/`Card` revision `hook_targets` built from the real engine classes.

### 5.1 Strict launcher environment descriptors (canonical)

Only these exact canonical variables are read; everything else in the
environment is ignored. All are typed and bounded. These are the frozen typed
launcher descriptor names (`tools/launch_practice.py::SESSION_ENV_KEYS`,
`tools/staging.py::SESSION_DESCRIPTOR_VARS`); there are no speculative aliases.

| Variable | Type / bound |
|---|---|
| `BALATRO_AI_ROLE` | `human` \| `ai` (from `staging.role_environment`) |
| `AISP_SESSION_ID` | token, 1–128 |
| `AISP_ROLE_CREDENTIAL` | token, 1–128 |
| `AISP_PROBE_NONCE` | `[0-9A-Za-z_]+`, 1–32 |
| `AISP_CONTENT_HASH` | token, 1–128 |
| `AISP_CONTROL_PORT` | integer `1..65535` |
| `AISP_EXPECTED_ROLE_SAVE_ROOT` | path, 1–512 |
| `AISP_EXPECTED_ROLE_MODS_ROOT` | path, 1–512 |
| `AISP_MODE` | `normal` \| `gauntlet` |
| `AISP_DIFFICULTY` | `rookie` \| `competitive` \| `major_league` |
| `AISP_PACING` | `instant` \| `normal` |
| `AISP_GAUNTLET` | `""` for normal, else `Test1`…`Test5` |

The companion module root is **derived** as
`<AISP_EXPECTED_ROLE_MODS_ROOT>/AISparring`; it is never read from the
environment. There is no seed/decision-base/auto-coordinate/log-root descriptor:
the run seed is obtained by the human coordinator from the authenticated service
`SETUP` and reaches the AI through ordinary MP `startGame`; the seed is never a
policy input.

The real `env` port reports `love.filesystem.getSaveDirectory()`,
`SMODS.MODS_DIR` and `SMODS.Mods["AISparring"].path`; `RuntimeBootstrap.validate`
compares all three against the expected descriptors (save root, Mods root and the
derived mod root) before any capability exists.

### 5.2 Fixed launcher attestation

The staged path never trusts the descriptors it is asked to confirm. While the
launcher's frozen attestation file is absent, the companion stays in a bounded,
nonblocking **pending** state (`state = "awaiting_attestation"`) and retries each
`Game:update`; it does not fail permanently at first module load. Only once the
file appears and validates does the companion construct the real
`RuntimeBootstrap`, call `install()` (which sends the authenticated `hello`) and
then await the ack. A deadline (`attestation_timeout`, 120 s = the host's 90 s
probe wait plus margin) is a graceful local failure; no policy capability is ever
minted before the hello ack. The bound is deliberately **larger** than the host's
`practice_host.DEFAULT_ATTESTATION_TIMEOUT` (90 s) so a slow second role cannot
make the first role fail permanently while the host is still waiting.

The file is read from
`<AISP_EXPECTED_ROLE_SAVE_ROOT>/aisparring-launcher-attestation.json` through the
trusted native read adapter and must match the schema written by
`tools/isolation_certificate.py::write_launcher_attestation`:

| Field | Requirement |
|---|---|
| `schema` | `aisparring.launcher_attestation.v1` |
| `ok` | `true` |
| `session`, `nonce`, `content_hash` | exactly the descriptors' values |
| `role` | exactly the descriptors' role |
| `control_port` | exactly the descriptors' control port |
| `expected_role_save_root` | path-equal to `AISP_EXPECTED_ROLE_SAVE_ROOT` |
| `expected_role_mods_root` | path-equal to `AISP_EXPECTED_ROLE_MODS_ROOT` |

Wrong nonce/role/hash/port or a wrong expected path, and a present-but-invalid
file, are definitive rejections (they never become pending). An injected
`launcher_attestation` verdict port is still honoured for fixtures, and the real
bootstrap performs the final field-level agreement check.

### 5.3 Staged-window identification

Once the launcher attestation is validated and **before** the runtime bootstrap
sends any startup/match request, the staged companion performs a one-time UI
identification through the injected `love.window` API:

- **human role:** `love.window.setTitle("Balatro AI Sparring 0.1.0-dev - Player")`;
- **AI role:** `love.window.setTitle("Balatro AI Sparring 0.1.0-dev - AI runtime")`
  and then `love.window.minimize()` exactly once, so the bot's hand is not the
  default foreground view.

The window object is read from the trusted `love` global (or an injected test
port); it is never stored on a status surface and never reaches policy. Only
`setTitle` (both roles) and, for the AI role, `minimize` are used. Focus, timers,
update loops and gameplay are never changed, and the live companion never stages
a window. Both required methods must be present and callable: a missing or
throwing method is a bounded failure
(`companion_window_unavailable` / `companion_window_failed`) that prevents staged
startup, so no authenticated hello is sent. The identification runs at most once
per staged instance and is never retried per `Game:update` tick.

LÖVE 11.5's `wrap_Window.cpp` supports `setTitle` and `minimize`, so the two
titles above are the user-facing identification. This section is a fixture/static
contract only: the real reference `work/reference/game/main.lua` calls
`love.update` **outside** `love.graphics.isActive()`, so whether a minimized
runtime keeps updating is **not** provable from fixtures and remains a required
live smoke gate (see docs/PLAYTEST.md). No engine proof and no full-run claim are
made here.

## 6. Update chain

`CompanionHost.install_update(Game, step)` wraps the current `Game.update`
(which is already the Multiplayer wrapper, since AISparring has higher
priority):

```lua
function Game:update(dt)
  local r1, r2 = original(self, dt)   -- exactly once, first
  if active then pcall(step, dt) end  -- bounded companion step
  return r1, r2
end
```

A throwing step is counted; after `max_update_errors` (5) the local feature is
closed through `on_failure` (`instance.uninstall`) and the wrapper goes inert.
The original game update and its return values are never disturbed. Uninstall is
idempotent and restores the exact original. No `Card`/`CardArea`/action hooks and
no Multiplayer transport mutation happen on the live path.

## 7. Status surface

The published status adds a primitive-only `companion` block:

```
state = "companion_ready" | "companion_unavailable" | "fail_closed"
ai    = { requested = true, enabled = false, implemented = true, status = ... }
companion = { role, staged_role, booted, pending, code, instance_state,
              host_available, handling, diagnostic_path, module_error }
```

`companion_ready` means the companion is armed; for the staged path it also
covers the bounded-pending state, where `pending = true`, `booted = false` and
`instance_state = "awaiting_attestation"` while the launcher writes the fixed
attestation file. The companion update step is still installed so it can resolve
and boot later. `diagnostic_path` is a sanitized local path (no credentials).
Capability flags stay `false` deliberately: instance state and module presence
are facts, not authority, and the broker capability is never exposed here. A
mutating caller cannot change the stored snapshot (`get_status()` returns fresh
copies).

## 8. Wire encoding (`integration/wire_json.lua`)

The real game bundles the rxi `json` library and Multiplayer reaches it through
the host loader (`require` of the module named `json`, supplied by SMODS). That
library encodes an empty table as `[]` and has no null sentinel: a missing table
key is omitted. The raw codec therefore cannot produce the two envelopes the
project owns, so `core.lua` builds a narrow, footprinted-only wire encoder over
the real module:

- the control-service request is always exactly
  `{session, credential, role, op, sequence, observation}` and a nil/empty
  `observation` payload is emitted as `{}` (never `[]`); nested observation
  arrays keep the base encoder's semantics;
- the practice-host request is always exactly
  `{schema, op, auth, request}` and the `request` object is exactly
  `{session_id, difficulty, pacing, mode, gauntlet, live_pid, live_create_time}`,
  with an explicit `gauntlet: null` for normal mode (a label string otherwise);
- unknown, missing or wrongly typed keys are rejected with a bounded code;
  a malformed request is never silently turned into a valid one.

When no wire encoder is injected (fixtures), `companion_host.lua` falls back to
the legacy `encode` + `JSON.null` sentinel ports. Normal mode therefore works in
production without any null sentinel.

## 9. Test harness

`python tests/run_companion.py --require-all` runs static checks, Python wire
cases and `tests/companion/test_*.lua` under `lupa.lua51` and `lupa.luajit21`.
The real `companion_host.lua`, the real `integration/wire_json.lua`, the
reviewed menu modules and (for staged cases) the real runtime modules are loaded;
only globals, the marker, identity, transport and channels are fake. The Python
wire cases load the actual read-only SMODS/rxi `work/reference/offline/smods-json.lua`,
encode through the real wire module and parse the bytes with `json.loads` and the
real `tools/practice_host.py` `parse_json_line`/`START_REQUEST_KEYS`. Coverage:
flag-off/scaffold regressions and exact M1 load set; missing Multiplayer /
version mismatch; missing host and game globals; marker
schema/version/host/port/secret/enum/identity rejection; request validation,
identity binding and gauntlet index mapping; explicit `gauntlet: null`; ack/
reject/timeout behaviour through the reviewed controller; `Game:update` ordering,
idempotence and fault containment; staged role crossing, no-attestation-source,
wrong nonce/role/hash/path, deferred attestation (pending then boot), the
host-plus-margin attestation bound (still pending at the host's 90 s, then a
bounded timeout), the acknowledgement timeout through the real companion update,
the dead-worker transport rebuild, strict env descriptor reading, human
non-activation and AI activation only after
the hello ack, secret-free status, and the staged-window identification (no
window operation before attestation, the exact human/AI titles, exactly one AI
minimize, the human never minimized, the live companion untouched, and a
missing or throwing window method failing closed before any startup request). It
also drives the real production
`core.lua` through a human staged boot (`test_digest.lua`): the common staged set
loads the pure codec for the human role, the policy/executor set is absent, and
the `hash_string` the runtime driver receives agrees with the shipped
`ai/codec.lua` (`test_digest.lua`). The identity adapter is driven through a
controllable table-shaped ffi port (`test_identity.lua`): missing modules/symbols,
failed loads, failed and throwing queries, null handles and invalid pids all fail
closed, the query-only handle is released on every path, and invalid pids never
open a handle. The real LuaJIT FFI library/callables are accepted by
`tests/astra_native_identity.py`, run read-only by the root against this test
process's own pid and creation time only. It is not the actual engine.

## 10. Remaining integration mismatches (honest)

1. **Gauntlet seed.** No seed descriptor is read any more (the launcher supplies
   none). `RuntimeBootstrap` is invoked with `seed = nil`, so normal mode uses the
   original random seed behaviour. The gauntlet seed must be delivered by the
   launcher's authenticated service `SETUP` and injected into the runtime's MP
   `startGame`; that injection point is not wired here and is a real no-op gap for
   gauntlet mode.
2. **Launcher attestation writer.** The companion now derives and validates the
   exact `aisparring.launcher_attestation.v1` file the certificate tool writes, but
   the launcher must actually write it (after both roles' fresh probes) before the
   staged roles boot. Until it is written, staged boot stays bounded-pending and
   then fails gracefully with `companion_staged_attestation_timeout`.
3. **UI elements.** The companion passes no `element_for`; the engine worker's
   source-backed default inside the executor resolves cash-out, PvP ready, skip
   blind and booster skip. Lobby-ready still relies on the injected `G.FUNCS`
   path. Any missing element fails closed in the executor, never fabricated here.
4. **Revision hooks are partial.** The AI staged role gets source-backed
   `CardArea:emplace/remove_card/add_to_highlighted/remove_from_highlighted/
   unhighlight_all` and `Card:set_ability/set_debuff/apply_to_run` hooks. Other
   observation-relevant transitions not in this set are still covered only by the
   reader's observed-change sync (no unobserved-ABA magic).
5. **Live identity needs the real Windows query.** `core.lua` resolves LuaJIT
   `ffi` itself (global first, else a protected `require("ffi")`) and the adapter
   now accepts an actual FFI library/callables, so the live path is not blocked
   by the library shape. The check still fails closed when the module/symbol or
   query is unavailable (for example a non-`ffi` or non-Windows runtime); that is
   the intended behaviour, not a fallback.
6. **Not a sandbox.** This is in-process provenance, not isolation, and not a
   defence against arbitrary trusted local code.
7. **No live evidence.** Nothing here launches the game, writes a Mod or file,
   opens a real socket, starts a real thread or runs the policy subprocess; all
   evidence is fixture and static only. Real-engine smoke testing is the root's
   later step.
8. **HUMAN END summary is the runtime worker's file.** The role-aware
   `report_summary` output used when a HUMAN match terminates belongs to
   `integration/runtime_bootstrap.lua` (another owner) and is not touched here.
   This chunk only guarantees the human staged wiring supplies what that path
   needs: the real `Codec.hash_string` via the common staged codec module, plus
   the send guard and the real `G`/`MP`, with no AI policy/executor modules
   loaded.
9. **Minimized-runtime updating is a live gate.** The staged-window
   identification is proven only by fixtures here. Whether the real game keeps
   driving `love.update` while its window is minimized is engine behaviour and
   must be confirmed by the live smoke gate in docs/PLAYTEST.md; this document
   does not claim it.
