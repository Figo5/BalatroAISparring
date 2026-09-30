# Fairness threat model

Initial M2 design by Astra, before implementation. Read with INTEGRATION_PLAN.md, MILESTONE_2_PLAN.md and the source-evidence map. The goal is to prevent project-owned future policy/search code from observing hidden information or bypassing legal actions. Trusted extraction, schema code, broker, runtime-role assignment and future engine-validator implementations are part of the trusted computing base and require review. A malicious game mod, compromised interpreter, or malicious trusted extractor is outside this in-process boundary's guarantee. No sandbox claim follows from a schema or a Lua metatable alone.

| Threat | Required mitigation and attack evidence |
|---|---|
| Direct global access | Restricted policy environment excludes G, MP, SMODS, Client, _G, package, require, io, os, love, NFS, debug, getfenv/setfenv, load/dofile and random APIs. Test direct and indirect access; integration modules are never policy imports. |
| Nested reference leaks | Explicit schema copies only approved primitives. Reject metatable-bearing input at accessed boundaries without invoking metamethods; no generic recursive copy of engine objects. Mutate all nested views and verify sources/stored canonical data unchanged. |
| Future RNG | Do not read/copy RNG generators, state, pseudorandom caches, future draws, shops or packs. Poison these fields and verify unchanged outputs and zero reads/calls. |
| Seed prediction | Exclude all seeds/seed identifiers from policy, even fixed user benchmarks. Trusted launcher alone owns pre-match seed setup. No engine sort_ID or hidden-state-derived identifiers. |
| Opponent private state | Only source-proven UI projections of public state. Never clone enemy/player objects, end-game deck/Joker dumps or wire payloads. After the match has ended, the send guard lets the AI's Jokers reach the human's end screen, one way only (`mp_driver.lua` `ENDGAME_REVEAL`). Nothing flows to the AI runtime, and the observation is empty at `MATCH_COMPLETE`. Masked score, hidden location and timer precision must match the UI or be omitted. |
| Stale/future caches | No cache of hidden runtime state. Each read starts fresh; phase-specific fields removed on transitions. Trusted per-session monotonically advancing revision is separate from canonical visible content; reject stale/ABA/replay submissions. |
| Debug tooling | No logs, error stack, replay files, arbitrary callbacks or diagnostic state enter observations. Errors are bounded codes, not raw exceptions. Debug-only proxies are not the security control. |
| Serialization | Canonical schema only; deterministic ordering and types; bounded strings/arrays; no tostring(table), functions, memory addresses, metamethod evaluation or locale-dependent floats. Hash never grants authority. Cross-runtime and hidden-perturbation tests. |
| Validator bypass | Strict action shape and exact current candidate membership; fresh trusted state/engine validation before any mock dispatch. Independent trusted revision token; no trusting action.id alone. Real executor disabled. |
| Omniscient search | Future search receives only observation plus legal choices and observation-consistent beliefs. No game snapshots, hidden-state clones, extractor handles, engine callbacks or RNG. No search implemented here. |
| Excessive adapter objects | Integration accepts trusted runtime and narrow UI/affordance inputs, but exports only normalized data. Broker and extraction capability objects are never passed to policy. Unsupported cases deny rather than return arbitrary tables. |
| Prohibited imports | Dependency-direction scan plus capability-restricted loading/execution. Adversarial snippets test require/debug/environment/function escapes. Static substring scans alone are insufficient and are documented as heuristics. |
| Resource exhaustion / malicious Lua | Bounded observations/actions/serialization and instruction budgets for development execution. No unsafe libraries or bytecode input. Lua in-process execution is not a hard memory/OS sandbox; production launcher must add process and memory limits before untrusted extensions or autonomous matches. |
| Legal-action information oracle | Affordances may reveal only outcomes a legitimate UI interaction exposes. Never query future outcomes, hidden card values, random samples or opponent secrets to filter actions. Engine-dependent capability certificates require trusted UI-equivalent provenance. |
| Human-state capture | Extractor requires explicit AI staged-runtime role; refuses human role. Actual role/path/IPC authentication is launcher-owned, unimplemented and a prerequisite to wiring capture/execution. Test role refusal; do not treat caller-provided labels as OS isolation. |

## Dependency direction

Engine/Multiplayer -> trusted state/UI adapter -> normalized AIObservation -> legal actions -> future restricted policy/search/evaluator. Selected action -> trusted broker -> fresh authoritative validation -> future legitimate engine callback. Policy has no reverse edge to adapter/broker capabilities. Observation checksums and public action IDs carry no execution authority.

## Completion conditions

Implementation must document its exact schema, supported/unsupported projections, action catalogue bounds, mock execution status, policy-environment limits and any threat-model changes. DeepSeek self-review, independent Astra attacks and Claude source review are required before acceptance. No real policy, live runtime capture, autonomous action, or staged-isolation success is asserted by this initial document.
