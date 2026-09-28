# Developer guide

Historical Milestone 1 companion-scaffold guide. The scope and absence claims below describe that accepted checkpoint, not the current playable-build implementation. For current behavior and installation gates, use `README.md`, `docs/PLAYABLE_ACCEPTANCE.md`, `docs/COMPANION_BOOTSTRAP.md` and `docs/INSTALL_COMPANION.md`. Architecture remains governed by `docs/INTEGRATION_PLAN.md` and `docs/PROTOTYPE_GATES.md`.

## Scope and status

The scaffold is **built to load** as a Steamodded mod; loading in a real game is unproven. It inspects the installed Multiplayer dependency read-only, resolves the inert AI flag and publishes a status snapshot on its own mod entry. It is inert by construction:

- No gameplay hooks, no card/Joker/content registration, no patches.
- No launcher, second runtime, transport, opponent, observation extractor, action executor or policy.
- No network, no file writes, no calls into Multiplayer methods.
- Never loaded in a real game yet. In-game load and isolation are **not proven** by the fixture harness.

## Layout

```
AISparring/
  AISparring.json     Steamodded JSON manifest (id, prefix, main_file, priority, dependency pin)
  config.lua          returns { ai_enabled = false }
  core.lua            entrypoint: module loading, fail-closed bootstrap, status publication
  src/status.lua      pure status builders (fresh tables; no shared mutable state)
  src/logger.lua      structured, allowlisted, length-bounded, escaping logger
  src/dependency.lua  pure dependency verdict + safe version tokens
  src/host.lua        read-only host adapter (SMODS.Mods / MP snapshots)
  src/ai_mode.lua     AI flag semantics (default off; requested stays blocked)
tests/
  run.py              Python harness (static checks + Lua runtimes)
  requirements.txt    pinned lupa
  lua/framework.lua   tiny test framework
  lua/fixture.lua     synthetic SMODS/MP/G host with guard recorders
  lua/runner.lua      per-file isolated runner
  lua/test_*.lua      regression specs
```

## Alignment with the authoritative plan

`docs/INTEGRATION_PLAN.md` selects two staged Balatro runtimes (human practice and AI practice) plus a pinned local match server, with an information boundary around the policy. This scaffold implements **none** of that beyond the mod shell. It exists so later milestones attach to a reviewed, inert base instead of a monolith.

The following remain unimplemented and are called out so they are not mistaken for done work:

- **Trusted observation extractor:** a future narrow component that reads only allowlisted engine fields.
- **AIObservation:** a future immutable, human-visible projection. No schema, allowlist or sandbox exists in this milestone; nothing is passed to any policy.
- **Restricted policy:** a future separately confined decision component. There is no sandbox and no policy runtime here.
- **Legal action executor:** future revalidation against the real runtime. Not present.
- **Launcher, local transport, second runtime, opponent:** not present.

## Install target (staging only)

The companion is **only ever installed into staged practice runtimes, never the user's normal Balatro installation.** The user's normal install must never contain `AISparring`.

Multiplayer hashes its reported mod list, and there is no exemption for passive mods: `get_mod_data` in the upstream matchmaking code adds every enabled `SMODS.Mods` entry, so enabling `AISparring-0.1.0` anywhere changes the mod string and the resulting hash sent by that install. It must not be hidden, and Multiplayer's mod-list or hash checks must not be patched. Inside a staged pair, the P5 identity-parity gate requires both clients to carry the same companion version.

The accepted integration plan allows a possible future installed AI Sparring menu. That is **not part of this approved implementation** and is not silently erased from the plan: if it is ever proposed it becomes a live entrypoint into the normal install and must get its own compatibility and UX review, with the mod-list and hash effect disclosed rather than hidden. Nothing in this milestone implements or authorizes it.

No raw Multiplayer state, Balatro `G`, RNG, seed, ordered deck, logs, filesystem or network access is ever handed to a policy, because no policy exists. When one is added it must consume only a versioned AIObservation; this milestone does not pretend to provide that boundary.

## Manifest, dependency pin and load order

`AISparring.json` declares:

- `main_file`: `core.lua`
- `priority`: `10000001`, i.e. after Multiplayer's `10000000`
- `dependencies`: `["Multiplayer (==0.5.5)"]`

The pin and priority follow the structures used by the installed sources inspected under `work/reference/` (Steamodded loader manifest semantics and `Multiplayer.json`). This is a **structural** compatibility claim only; it is not server or rules parity. Multiplayer rules, adjudication and server behaviour are explicitly out of scope here.

### Steamodded skip vs runtime defensive checks

These are separate mechanisms and must not be conflated:

1. **Loader level (manifest).** Steamodded evaluates the JSON `dependencies` list before load. If Multiplayer is absent, disabled, not loadable or fails the exact `==0.5.5` comparison, Steamodded marks this mod `can_load = false` and **does not execute `core.lua` at all**. In that scenario the runtime checks below are unreachable by design.
2. **Runtime level (`core.lua` + `src/host.lua`).** If the loader still runs the entrypoint (for example an incomplete structural surface, or a loader that does not enforce the manifest), the mod inspects the dependency read-only and fails closed with a named code and useful status. The structural surface includes Multiplayer's `lovely = true` install marker and a defined `ACTIONS.connect` function, so a partially loaded Multiplayer (which returns early in `multiplayer-core.lua` when `SMODS.current_mod.lovely` is false, before `action_handlers.lua` defines `ACTIONS.connect`) is not reported ready. These are read-only type checks; the function is never called and no connection, thread or protocol state is proven.

The status snapshot reports both facts explicitly (`manifest.skips_load_when_dependency_unmet` and the runtime dependency record), so a reader can tell which layer produced the result.

## AI flag

`config.lua` returns `{ ai_enabled = false }`. Steamodded loads that into the mod entry's `config` table. `src/host.lua` reads `config.ai_enabled` and accepts it only when it is strictly boolean `true`; strings, numbers and missing values are treated as `false`.

The flag expresses intent only. `src/ai_mode.lua` always returns `enabled = false`:

- absent/false -> status `disabled_default_off`
- `true` -> status `requested_blocked_gates_not_implemented`, with the blocking prototype gate ids (`P0`-`P5`)

Setting the flag cannot start practice, hook gameplay, connect, send protocol actions or change a human lobby. Enabling AI practice requires the unpassed prototype gates and later milestones.

## Bootstrap status API

`core.lua` attaches a mod-local API to its **own** mod entry after verifying identity (`SMODS.current_mod == SMODS.Mods["AISparring"]` and `id == "AISparring"`). It publishes nothing globally and never mutates another mod.

```lua
local status = SMODS.Mods["AISparring"].aisparring.get_status()
```

Important properties:

- **Snapshot at load, not a monitor.** The value is captured once when the mod loads. It is not re-evaluated, does not track lobby or match state, and makes no ongoing runtime claims. Ask again only after a reload.
- **Fresh copies.** `get_status()` returns a deep copy of primitives only. Copying stops at depth 6; functions, userdata, dependency objects and anything deeper are not reproduced. Mutating the returned table never affects the scaffold.
- **Contained, and publication-safe.** All entrypoint work is wrapped in `pcall`, so a broken module, method or logger sink cannot escape. Status publication is also wrapped: if identity cannot be verified or attaching fails, no API is attached and nothing escapes. The entrypoint's return value is unchanged in that case and is only visible to test harnesses, since Steamodded discards it.

Representative ready snapshot:

```
state = "scaffold_ready"
code = "ok"
dependency = { id = "Multiplayer", supported_version = "0.5.5", inspected_version = "0.5.5",
               compatible = true, identity_verified = true,
               compatibility = "structural-only", server_parity = "unproven" }
ai = { requested = false, enabled = false, implemented = false, status = "disabled_default_off" }
observation_extractor = false
policy = false
capabilities = { gameplay_hooks = false, content_registration = false,
                 network_transport = false, opponent = false, launcher = false }
gates = { "P0", "P1", "P2", "P3", "P4", "P5" }
manifest = { dependency_pin = "Multiplayer (==0.5.5)", priority = 10000001,
             skips_load_when_dependency_unmet = true }
```

Closed snapshots use `state = "fail_closed"` with a `code` such as `dependency_missing`, `dependency_disabled`, `dependency_not_loadable`, `dependency_state_unknown`, `dependency_identity_mismatch`, `dependency_version_mismatch`, `dependency_structure_incomplete`, `host_inspection_failed`, `module_load_failed` or `bootstrap_failed`. `identity_verified` is `true` only on success.

If the mod entry is unavailable, already owned by another table, or refuses the write, no API is attached and the entrypoint's return value is unchanged (usually `scaffold_ready`). In the real game that return value is discarded, so a failed publication is simply invisible rather than an error; only test harnesses observe it.

## Structured logging

`src/logger.lua` emits bounded records through injected Steamodded/Lovely logging functions (`sendInfoMessage`, `sendWarnMessage`, `sendErrorMessage`, `sendDebugMessage`). Rules:

- Only allowlisted field names are emitted; unknown and non-primitive fields are dropped and counted.
- Values are length-bounded and quoted with escaping for `\`, `"`, newline, carriage return, tab and remaining control characters, so a value cannot forge a second log line or a fake field.
- Dependency versions are never echoed raw: the log and status use safe tokens only (`0.5.5`, `unsupported`, `missing`, `malformed`).
- A throwing or missing sink is contained; logging never raises into bootstrap.

## Tests

Requirements are pinned in `tests/requirements.txt` (`lupa==2.8.0`). Install and run:

```powershell
python -m pip install -r tests/requirements.txt
python tests/run.py
```

For strict acceptance, require every runtime rather than skipping an unavailable one:

```powershell
python tests/run.py --require-all
```

The harness:

- validates the manifest in Python (required metadata, exact `Multiplayer (==0.5.5)` pin, priority greater than `10000000`, main file present, no stray JSON, config flag false, no forbidden IO APIs in sources);
- drift-checks the manifest pin, version and priority against `Dependency.SPEC` and `src/status.lua` constants;
- executes the **real** `core.lua` and `src/*.lua` inside synthetic hosts under both `lupa.lua51` and `lupa.luajit21`;
- prints every named case and per-runtime totals, reports unique cases versus total executions, fails on any failure, and fails if an available runtime discovers and executes zero tests;
- by default prints a descriptive skip when a runtime is unavailable; with `--require-all` a missing requested runtime is a failure;
- exits non-zero on failure.

The synthetic fixture provides `SMODS.Mods`, `SMODS.load_file`, `SMODS.current_mod`, and an `MP` that is the same table as `SMODS.Mods["Multiplayer"]` (matching the installed loader relationship). `G`, content registration APIs, `Client` and `love.thread`/`love.network` are guard objects that record and raise if called, so side effects are detected rather than assumed absent.

### Fixture limitations (honest)

- Fixtures are synthetic. They model the installed loader and Multiplayer shapes inspected under `work/reference/`; they are not the real Steamodded loader or engine.
- `config.lua` loading into `entry.config` via Steamodded's config machinery was checked against the installed `ui.lua` source; a real-engine test of that path is still pending.
- The source scan in `run.py` is a plain substring heuristic over known forbidden tokens. It is a drift alarm, not a sandbox, and does not prove the absence of side effects.
- No real game load, rendering, save, Mods scan, Steam or Love/Lovely interaction is exercised. Passing tests do not establish in-game load success, isolation, or rules/server parity.
- Lua correctness is checked on `lupa.lua51` and `lupa.luajit21`; the shipped game runtime is not otherwise asserted.

## Milestone 2 development boundaries

The M1 entrypoint and status above are intentionally unchanged: none of the new observation/action modules are loaded into the game. `AISparring/ai/` contains the pure codec, observation registry and legal-action generator. `AISparring/integration/` contains the trusted state reader and submission broker. `tools/policy_worker.py` and `tools/lua/policy_env.lua` demonstrate a fresh, restricted interpreter receiving only normalized data. No future policy may import the integration modules or run inside the game interpreter.

Read `FAIRNESS.md`, `AI_OBSERVATION.md`, `LEGAL_ACTIONS.md`, `STATE_READER.md` and `M2_EXECUTION_BOUNDARY.md` before extending these boundaries. The view/certificate producer, authenticated runtime role and revision assignment, legitimate game callback executor, and production process watchdog are still unimplemented gates. The supported action catalogue is a bounded certified subset, not an exhaustive search generator.

Run `python tests/run_m2.py --require-all`, `python tests/run_reader.py --require-all`, `python tests/run_boundary.py --require-all` and `python tests/astra_attacks.py` in addition to M1's strict suite. Run `python tests/benchmark_m2.py --require-all` separately for fixture timings. These tests require only the pinned lupa dependency and never launch or alter Balatro.

## No live install policy (all milestones)

The companion is staging-only: it is never copied into the user's normal Balatro installation, and no game or server is launched from this milestone. Even staged live integration requires the closed-game checks, verified backups, staged copies and prototype gates in `docs/PROTOTYPE_GATES.md`. Never write to live Mods while Balatro is running and never terminate the user's game.
