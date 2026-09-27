# M2 adversarial self-review (DeepSeek, pre-Claude)

## Astra disposition after the self-review fixes

The findings below are the historical self-review. Before Claude review, DeepSeek fixed F1 (both direct and string-metatable routes use the whitelist), F3 (empty action arrays emit JSON `[]`) and F4 (broker guard resets after exceptions). Astra independently reran the resulting boundary suite: 94 unique cases / 168 executions, all passing. F2 remains an explicitly limited development capability proof: bounded string wrappers reduce cost, the separate worker enforces a 64 MiB Lua VM cap, and the test caller enforces a 10-second process deadline. C calls are not instruction-hook bounded; production process watchdog/isolation is still a prerequisite, and the private helper must never run inside Balatro. This is accepted for inert M2 infrastructure, not permission to launch a production policy. F5 and F10 are documented intentional lifecycle contracts; F6–F9/F11 are trusted-producer and future integration obligations, with real execution disabled. No known policy-accessible game-information leak remains from this self-review.

Author: DeepSeek V4.1 Flash (High) for Codex / Astra. Date: 2026-09-27.
Status: adversarial self-review only. **No implementation, test, reader, broker, policy or
doc file other than this one was changed in this pass.** No game/engine/Mods/network
execution; all Lua ran in synthetic lupa fixtures.

Read with `AGENTS.md`, `docs/FAIRNESS.md`, `docs/MILESTONE_2_PLAN.md`,
`docs/AI_OBSERVATION.md`, `docs/LEGAL_ACTIONS.md`, `docs/STATE_READER.md`,
`docs/M2_EXECUTION_BOUNDARY.md`.

Artifacts inspected: `AISparring/ai/{codec,observation,actions}.lua`;
`AISparring/integration/{state_reader,action_broker}.lua`; `tools/policy_worker.py`;
`tools/lua/policy_env.lua`; `tests/{run_m2,run_boundary,astra_attacks}.py`;
`tests/m2/*`; `tests/boundary/*`; `docs/*`; `AISparring/core.lua`/`src/*` (M1, unchanged).

## 0. Method and what was actually executed

| Activity | Status |
|---|---|
| `python tests/run_m2.py --require-all` | **Executed.** 4/4 static; 89/89 lua51; 89/89 luajit21; 93 unique cases; 182 executions; 1040 property iterations; PASS |
| `python tests/astra_attacks.py` | **Executed.** 12 unique attacks x 2 runtimes = 24; 0 failures |
| `python tests/run_boundary.py --require-all` | **Not executed** (session permission policy allows only `run_m2.py`/`astra_attacks.py`). Broker/policy reviewed by **source inspection only**; `docs/M2_EXECUTION_BOUNDARY.md` records a prior passing run, not independently reproduced here |
| `tests/reader/*` + `tests/run_reader.py` | **Absent at review time** (reader worker in progress); not executed |
| Game / live / Mods / network | Never executed |

Evidence labels used below:
- **[executed]** — run by this review's two allowed commands (`tests/run_m2.py`,
  `tests/astra_attacks.py`).
- **[prior-worker]** — recorded by another worker's harness (e.g. `tests/run_boundary.py`
  or `docs/M2_EXECUTION_BOUNDARY.md`) and **not** independently run here.
- **[inspection]** — source reading only.

Where I could not run a disproof I say so and do not claim the hole is closed. In
particular, no worker/policy/bytecode/budget/production-dispatch case was independently
executed by this review.

## 1. Trust boundary (TCB) as implemented

TCB: `state_reader.lua`, `observation.lua`, `codec.lua`, `actions.lua`,
`action_broker.lua`, `tools/lua/policy_env.lua`, `tools/policy_worker.py`, and the
launcher-owned role/epoch provenance. Non-TCB: the future policy/search source.

Policy-visible surface is exactly: a re-sanitized plain observation export, a
regenerated plain action list, and a whitelist stdlib. No handle, no `G`/`MP`, no
certificate authority object, no callback, no engine reference, no RNG.

`core.lua` still loads only M1 modules; nothing in `integration/`, `tools/` or `ai/`
is wired into startup. `action_broker` dispatches only when `ports.fixture == true`
and otherwise returns `broker_executor_disabled` **[inspection:** `action_broker.lua:330-332`;
**not executed by this review** — the executed astra broker probes use `fixture = true`]**.

## 2. Q1 — How could a future policy obtain information not present in AIObservation?

### 2.1 Executed checks that failed to leak
- **Restricted synthetic environment:** `tests/m2/test_isolation.lua` loads all three
  `ai/*.lua` with `G`/`MP`/`SMODS`/`Client`/`love`/`require`/`io`/`os`/`debug`/
  `load`/`loadstring`/`dofile`/`setfenv`/`getfenv` canaries and performs
  observe/generate/validate; zero canary fires **[executed, run_m2]**.
- **Hidden-field perturbation:** poison `seed`/`rng`/future shop/deck-order/private
  opponent callbacks/metatables/cycles produce identical canonical bytes, hash and
  actions **[executed, astra `raw_hidden_perturbation`, `unknown_callback_and_cycle`]**.
- **Masked opponent:** poisoned `displayed_score` cannot revive a masked score
  **[executed, astra `masked_score_poison`]**.
- **Worker re-sanitization:** extra secret fields in a supplied export never reach the
  policy; actions are regenerated from the trusted generator, not from caller input
  **[inspection of `policy_env.run`/`run_boundary.py` cases; not executed here]**.

### 2.2 Source-level avenues considered (and residuals)
1. **Direct globals / imports / RNG** — not in the policy env; the worker uses a fresh
   interpreter with `register_builtins=False`, `python`/`python_builtins` cleared, and only
   the three trusted modules loaded. Blocked.
2. **String metatable escape (real residual).** `build_env` copies a *whitelist* `string`
   table, but the shared string metatable's `__index` still points at the real standard
   string library, so `("x").dump` (and any other stdlib string function) is reachable even
   though `env.string.dump == nil`. See **F1**. No `load`/`loadstring` is exposed, so the
   returned bytecode cannot be executed inside the policy env; no game data becomes
   reachable. `docs/M2_EXECUTION_BOUNDARY.md` §2.4 is technically consistent ("only base
   standard library string methods are reachable through the shared string metatable") but
   the escape test does not assert the metatable path.
3. **Nested aliasing / shared references** — observation rebuilds canonical content from
   primitives (never stores caller tables); `export` deep-copies; broker `copy_plain`
   copies again; policy gets copies. Mutation of source, export, candidate or handle does
   not change canonical/committed data **[executed, astra `handle_and_export_mutation`,
   `tests/m2/test_observation.lua` isolated-copy, `test_validation` copy isolation]**.
4. **Python bridge** — policy env has no Python objects; worker clears `python`/
   `python_builtins`. No `python.*` access path in the setfenv'd env. `_from_lua` only
   converts data back. No leak found.
5. **Bytecode** — leading `0x1b` rejected by both worker (`policy_worker.py:206`) and helper
   (`policy_env.lua:148`) **[inspection; worker case present in `run_boundary.py`]**.
6. **Certificate/observation provenance** — policy cannot choose its observation in
   production: the broker captures and passes its own export. Residual dev-tool trust is
   noted in **F6/F7** (not policy-reachable).
7. **Reader hidden reads** — reader is `rawget`-only over a fixed allowlist; `G.deck`,
   RNG, `real_score`, `last_timer`, location structs, future shops/packs are never read
   (`state_reader.lua` §5 table). **[inspection + astra executed probes]**

**Q1 answer.** Within the stated in-process capability boundary, I found no executed or
source-level path for a policy to obtain game information outside `AIObservation`. The one
genuine reachability subtlety (F1) yields only standard string bytecode, cannot be loaded,
and exposes no engine/observation data. The remaining reachability concerns are
availability (F2) or trusted-producer/dev-tool provenance (F6/F7/F8), not policy-side
hidden-information leaks.

## 3. Q2 — How could a future AI action cause an illegal game-state mutation?

### 3.1 Checks and their evidence (mixed executed / inspected / prior-worker)
- Production submit never dispatches; returns `broker_executor_disabled`
  **[inspection of source `action_broker.lua:330-332` and the boundary production cases in
  `tests/boundary/test_broker.lua`, plus the prior-worker record in
  `docs/M2_EXECUTION_BOUNDARY.md`; NOT executed by this review.** The executed astra probe
  `replay_and_cross_broker` uses `fixture = true`, so it exercises fixture dispatch and
  replay/re-entry rejection, not production no-dispatch].
- Forged/mutated action, forged/plain/tagged/foreign/replayed token, stale epoch, changed
  observation, validator throw/false/state-change/epoch-advance, reentry, dispatch throw
  are all rejected with bounded codes **[inspection of `test_broker.lua`, boundary evidence
  not rerun here; the executed astra broker probes `action_id_is_not_authority`,
  `validator_changed_fresh_state`, `replay_and_cross_broker` run with `fixture = true` and
  therefore exercise the guard/replay/stale-state rejection logic, not production
  dispatch denial]**.
- Validator gets an independent copy; dispatch receives the preserved validated copy, so
  validator mutation cannot alter what would be dispatched **[inspection
  `test_broker.broker_validator_mutation_does_not_alter_dispatch`]**.
- `actions.validate` re-derives candidates from the current observable state and requires
  exact canonical-id membership; `id` alone grants nothing **[executed, run_m2
  test_validation + astra]**.

### 3.2 Residual avenues / requirements
1. **Trusted validator and executor are the real authority.** The broker cannot prevent a
   *trusted* `ports.validate`/`ports.dispatch` from mutating engine state during its
   callback; it can only detect the change afterwards (epoch + canonical recapture). This
   is inherent to the TCB and is why real dispatch is disabled for M2. A future real
   validator must re-derive engine truth from the engine (not from the observation) and
   apply elementary moves; see **F9** (target-ref → engine-ordinal mapping is not carried
   in the observation) and **F8** (phase is producer-declared inside `SELECTING_HAND`).
2. **Composite reorders / engine cardinality.** `REORDER_*` is validated as an exact
   permutation of the *visible* zone. Engine-side cardinality/vanilla-vs-modded legality is
   the future executor's revalidation job; the observation is a projection, not a snapshot
   **[inspection]**.
3. **Certificate trust.** `observation` trusts `certified = true` from the frame; the reader
   passes `ui_view.certificates` through. A lying trusted producer could certify an illegal
   action; the broker's trusted validator is the intended backstop (**F-provenance**, see
   §4).
4. **Token lifecycle.** Token is consumed **after the structural checks** (token identity,
   fresh capture, epoch/canonical equality) and before candidate validation, by design, so a
   malformed/non-candidate submit drains the pending decision (**F5**). DoS/UX only, to the
   trusted caller; anti-replay is preserved. Astra disposition: intentional.

**Q2 answer.** No policy-reachable illegal-mutation path was found: action identity is
canonical content, candidates are regenerated, the broker re-captures and re-checks, and
production dispatch is disabled. The residual risk is entirely in the trusted
validator/executor and producer, which is correctly identified as TCB and gated.

## 4. Findings (severity, file:line, repro, status)

Severity: **High** = exploitable now; **Medium** = real but bounded/availability or
interop; **Low** = latent/robustness/TCB note; **Info** = documented limitation.

| # | Sev | Finding | Location | Evidence / repro | Status |
|---|---|---|---|---|---|
| F1 | Low-Med | Policy `string` whitelist is bypassable via the shared string metatable: `("x").dump` resolves to the real stdlib `string.dump` although `env.string.dump` is nil. No `load`/`loadstring` in env, so bytecode cannot be executed; no game data is reachable. | `tools/lua/policy_env.lua:114-142` (`build_env`), `:144-157` (`compile`) | Inspection; the escape test only checks `string.dump ~= nil` on the env copy (`test_policy_env.lua:83`, `run_boundary.py:190`) | Open (recommend deleting `string.dump`/`string.gsub`? no—only `dump` matters, in the fresh worker runtime; add a `('x').dump` assertion) |
| F2 | Medium | Instruction budget only ticks on VM instructions, not C calls; `('x'):rep(N)`, `string.format`, `table.concat` of huge tables run un-hooked. The **subprocess worker** has `max_memory=64 MiB` + a 10 s test timeout, but the **in-process** helper path (`PolicyEnv.run`) has no memory cap. | `tools/lua/policy_env.lua:159-185` (`with_budget`), `:114-121` (string funcs incl. `rep`,`format`) | Inspection; e.g. policy `return function() local s=('x'):rep(1e9) return actions[1] end` | Open — production launcher process/memory limit is the documented gate; recommend the helper pre-limit `rep`/`format`/`concat` |
| F3 | Low-Med | Python-bridge shape ambiguity: an empty Lua table serializes to JSON `{}` (object), not `[]`; any contiguous integer-keyed Lua table serializes to a JSON array. Actions with empty `target_refs`/`order` therefore appear as `{}`. | `tools/policy_worker.py:155-180` (`_from_lua`) | Inspection; empty-target `USE_CONSUMABLE` (actions.lua:486) -> `{}` | Open (interop hazard; document, or emit `[]` for known array fields) |
| F4 | Low | Broker in-flight guard is not exception-safe: `guarded` does not `pcall` `fn`; an un-pcalled fault inside `issue_impl`/`submit_impl` would leave `in_flight=true` permanently. All untrusted calls are currently pcall-wrapped, so latent. | `AISparring/integration/action_broker.lua:208-218` | Inspection | Open (recommend wrapping `fn` in `pcall` + reset `in_flight` in the handler) |
| F5 | Low | Pending token is cleared **before** `actions.validate`, so a malformed/non-candidate submit consumes the single decision token (must `issue()` again). Anti-replay is preserved; it is a trusted-caller DoS/UX consequence. | `action_broker.lua:284-293` | Inspection; `test_broker.broker_action_not_candidate_rejected` | Accepted behavior (document) |
| F6 | Low | `reconstruct` force-sets `frame.opponent.certified = true` for any opponent table in the supplied export, so the worker/in-process boundary trusts opponent-section presence as certification and cannot re-verify the HUD certificate. Correct for broker-sourced exports; a forged export fed to the dev worker (`--input`) can inject opponent fields. | `tools/lua/policy_env.lua:229-238` | Inspection | TCB/dev-tool (document; not policy-reachable in production) |
| F7 | Low | Worker trusts caller-supplied `observation.certificates`: re-observation regenerates candidates from whatever certified entries the export contains (refs must still exist in the same export). No independent certificate provenance. | `tools/policy_env.lua:240-322`; `tools/policy_worker.py:212-254` | Inspection | TCB (broker owns the worker input in production) |
| F8 | Low | Reader cannot distinguish `PLAY_HAND` vs `DISCARD` vs `CONSUMABLE_SELECTION` from `G.STATE`; all map from `SELECTING_HAND`. The normalized phase is producer-declared and only compatibility-checked. | `state_reader.lua:53-96`, `:861-876` | Inspection | TCB/producer; document (cross-field staleness gating still applies) |
| F9 | Low | Subset-zone refs do not carry the engine ordinal into the observation: `target:i` is the view position while the engine card is at `record.ordinal`. A future executor cannot map an action ref back to an engine target without a real mapper. | `state_reader.lua:800-840`; `docs/STATE_READER.md` §6.1 | Inspection | Documented future work; execution disabled |
| F10 | Low | Broker treats a captured epoch lower than `last_epoch` as `broker_epoch_regression` permanently; a legitimate session restart (epoch reset) would wedge the broker until reconstructed. | `action_broker.lua:191-196` | Inspection | Open (document fresh-broker-per-session requirement) |
| F11 | Info | Certificate provenance is producer trust by design: `observation` accepts `certified=true` from the frame and the reader passes `ui_view.certificates` through unverified. | `observation.lua:721-759`; `state_reader.lua:949-955` | Inspection | TCB; backstopped by the broker's trusted validator |
| F12 | Info | JSON `NaN`/`Infinity`/`-Infinity` parse in Python but are rejected because `_to_lua` refuses non-integer floats; deep-nested JSON raises `RecursionError` caught as `policy_bad_input`; input is byte-capped before parsing. | `policy_worker.py:127-152`, `:247-254` | Inspection | Good (recorded as checked) |

### 4.1 Known reader items in progress (NOT reported as unfixed final facts)
The reader worker is actively fixing: explicit `face_down = false` requirement, negative
epoch rejection, Stone `no_rank`/`no_suit`/`replace_base_card` masking, duplicate target
ordinals, `consumable_target.source_ref`, and removal of raw timer fallback. The reviewed
`state_reader.lua` already shows all of these (lines 324-341, 343-350, 401-413, 821, 849-851,
180-185). Astra probes for them pass **[executed]** (`stone_rank_hidden`,
`unknown_facing_denied`, `negative_epoch_denied`). No further action claimed here.

## 5. Concrete bypass attempts tried, by result

- **Executed and blocked:** poisoned hidden fields / callbacks / cycles / nested metatables
  (astra, run_m2 observation+isolation); handle/export/source mutation (astra, run_m2);
  masked score resurrection (astra); negative capacity / missing owned list (astra); action
  id not authority (astra, run_m2 validation); validator fresh-state mutation / replay /
  cross-broker (astra).
- **Denied per prior-worker boundary evidence and source inspection — NOT independently
  executed by this review:** bytecode policy (worker/helper), budget overrun (helper +
  worker case), forged/mutated selection (helper + worker cases), extra secret fields
  sanitized (worker case), production no-dispatch. These are recorded in
  `docs/M2_EXECUTION_BOUNDARY.md` and `tests/run_boundary.py`, which this review could not
  run; they are **prior-worker** evidence, not this review's executions.
- **Inspected only:** full broker submit ordering, worker JSON bridge shape, `string.dump`
  reachability, C-function DoS, epoch-regression wedging, target-ref engine mapping,
  certificate provenance. No exploit claimed; not proven safe.

## 6. Residual production gates (must remain explicit)

1. Launcher-owned role/epoch/view **provenance and authentication**; today `role`/`epoch`
   are caller claims (`state_reader.lua:842-859`) and no launcher binds them.
2. **Process and memory isolation** for the policy worker (in-process Lua is not a hard
   sandbox; F2). Real IPC and a real authoritative engine validator/executor remain
   disabled/unimplemented.
3. **Real validator/executor correctness** for engine-truth revalidation, elementary-move
   application and target-ref→engine mapping (F9, Q2.1).
4. **Fresh broker per session** or defined epoch-reset semantics (F10).
5. Reader `ui_view` production: no real mapper builds it; positional bindings and
   `record.ordinal` are producer-supplied (STATE_READER §6.1/§9).

## 7. Non-claims and verdict

- No strategy, search, evaluator, live capture, Mod/engine write, network or game launch
  exists or was executed. Main code is inert; broker dispatch is fixture-only.
- One genuine low/medium residual (F1 string metatable + F2 C-function availability) and
  several TCB/dev-tool interop notes (F3-F11) are recorded; none is a demonstrated
  policy-side hidden-information or illegal-mutation exploit.
- The two headline threats did not reproduce under the executed suites or source analysis,
  subject to the TCB and production gates in §6.

## 8. Astra dispositions (post self-report)

The §4 table is retained as the **historical finding record**; these dispositions supersede
the per-row "Status" wording. A later addendum (by whoever lands the fixes) can close
individual rows.

- **F1, F3, F4 — routed to the worker owner for fixes.** F1: remove `string.dump`
  reachability in the fresh worker runtime (and add a metatable-path assertion); F3: decide
  on empty-array JSON shape; F4: make the broker guard exception-safe.
- **F2 — resolved by deployment constraint: caller wall-timeout required.** The helper
  (`PolicyEnv.run`) is a private, fresh-interpreter-only path with **no in-game entry**; the
  deployed caller must impose a wall-timeout around any execution. No in-game use.
- **F5 — intentional.** Token is consumed after structural checks (token identity, fresh
  capture, epoch/canonical equality) and before candidate validation, by design.
- **F6/F7 — trusted-producer authentication is a future gate.** The worker (and production
  broker path) trusts broker/producer-supplied certification and opponent presence; real
  authentication is a launcher/integration prerequisite.
- **F8 — producer subphase.** `PLAY_HAND`/`DISCARD`/`CONSUMABLE_SELECTION` are producer-
  declared subphases of `SELECTING_HAND`; producer-trusted by design.
- **F9 — trusted opaque mapping is future work.** Mapping observation refs back to engine
  targets requires a real trusted mapper; execution is disabled.
- **F10 — fresh broker per session.** A new session constructs a new broker; epoch regression
  is otherwise `broker_epoch_regression`.
- **F11 — TCB as-is** (backstopped by the broker's trusted validator). **F12 — checked, no
  action.**

None of the above blocks Claude review.

## Subsequent external review

This self-review is historical. Claude found additional Medium defects, including deck aggregate inference, contradictory PvP masking and stale-token reuse, plus evidence gaps. DeepSeek fixed them and Astra verified them; the full Claude re-review accepted scoped M2. See CLAUDE_M2_RESOLUTION.md and MILESTONE_2.md for the final disposition and counts.
