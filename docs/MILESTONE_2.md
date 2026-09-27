# Milestone 2 — AI Observation + Legal Action System

Date: 2026-09-27. Branch: `feature/ai-sparring-v1`. Baseline: accepted M1 `8bcccabbce0693cf5a0e168babacfa511c2443e0`.

**Status: Milestone 2 accepted by Astra after Claude Opus 5.5 High source review, fixes, re-review and targeted final confirmation.** No Milestone 3 work has begun. The exact resulting commit and clean-tree check are recorded in the final handoff; this report is included in that commit.

## Implementation

The accepted architecture is unchanged: two separate staged game runtimes, a pinned local legacy Multiplayer server, and a separate restricted policy worker. M2 implements the information/action boundary using synthetic fixtures. M1 startup is unchanged and does not load these new modules. There is no evaluator, strategy, search, difficulty, autonomous opponent, launcher or real action executor.

| Component | Responsibility |
|---|---|
| `AISparring/integration/state_reader.lua` | Trusted AI-role, same-epoch, phase-aware extraction using injected engine references and a narrow certified UI view; returns only an observation handle. |
| `AISparring/ai/observation.lua` | Versioned allowlist, bounded normalization, private registry of immutable canonical records; each export is an isolated copy. |
| `AISparring/ai/codec.lua` | Deterministic typed/length-delimited serialization, bytewise map sorting, bounded integers/strings/arrays and diagnostic FNV-1a checksum. |
| `AISparring/ai/actions.lua` | Generates and validates structured actions from the sanitized observation and exact trusted action certificates only. |
| `AISparring/integration/action_broker.lua` | Private single-use decision token, atomic capture/epoch, fresh candidate validation, trusted validator, recapture before fixture dispatch. Production execution is explicitly disabled. |
| `tools/policy_worker.py`, `tools/lua/policy_env.lua` | Development proof of a fresh separate Lua interpreter with restricted capabilities, re-sanitized input, regenerated actions and validated output. No gameplay policy is implemented. |

Dependency direction is engine/Multiplayer → trusted reader → observation → actions → future policy. The return path is selection → broker → trusted fresh validator → future legitimate executor. Policy never receives the reader, broker, observation handles, raw engine objects or authority callbacks. Recursive source checks and restricted-environment tests guard this direction; static scans alone are not a sandbox.

### AIObservation schema

The exact field definitions and limits are in [AI_OBSERVATION.md](AI_OBSERVATION.md). The normalized record has:

- `schema_version = 1`, `phase` from the eight supported decision phases.
- `match`: ruleset token; visible ante/round/blind/lives/timer and hand/Joker/consumable limits.
- `self`: money/credit, hands/discards, displayed score/requirement, visible ordered hand/Jokers/consumables, optional schema-supported voucher/tag lists and the visible deck total only. Rank/suit maps are deliberately unsupported to prevent hidden-card inference.
- `opponent`: only certified visible displayed score, hands, lives, location and timer, with Multiplayer masking/readiness/config guards in the reader.
- Phase-specific `shop` (separate items, vouchers and boosters), `booster` or `consumable_target`. Shop packs use `shop_booster:N` references backed by `G.shop_booster`. The target context has an explicit owned `consumable:N` source binding.
- `context`: positive evidence for unblocked/unexpired interaction and bounded selection limits.
- `certificates`: versioned bounded catalogue of exact certified actions. This is data, not an authority object or callback.

All entity references are observation-local zone ordinals such as `hand:1`, `joker:2`, `shop:1`, `shop_booster:1` and `target:1`. They are not engine IDs or addresses. Target-to-engine ordinal mapping remains trusted future adapter work. Face-down or uncertified identities are redacted; Stone/no-rank/no-suit/replacement masks prevent hidden rank/suit disclosure. Missing visibility evidence denies fields. Stale hand/shop/pack/target state is dropped or rejected according to phase.

Internal canonical data is private; raw writes to the exposed handle cannot replace it. Exported records may be edited by callers but cannot mutate source or stored data. The reader currently implements a conservative subset: the actual UI/certificate producer is unwired, owned voucher/tag extraction is not bound, and unknown/modded/oversized states may yield omitted fields or no actions. This is not a complete live observation integration.

### Action schema

Actions are plain records `{type, id, ...typed references...}`. The `id` is the full canonical action content, not a collision-prone checksum. Examples are `PLAY_CARDS` with `card_refs`, `BUY_ITEM` with `item_ref`, `USE_CONSUMABLE` with `source_ref`/`target_refs`, and `REORDER_JOKERS` with `order`. Empty array fields serialize as JSON `[]` in worker responses.

Seventeen action types are supported: SELECT_BLIND, SKIP_BLIND, PLAY_CARDS, DISCARD_CARDS, BUY_ITEM, SELL_JOKER, SELL_CONSUMABLE, REROLL, BUY_VOUCHER, OPEN_BOOSTER, LEAVE_SHOP, SELECT_BOOSTER_ITEM, SKIP_BOOSTER, USE_CONSUMABLE, SELECT_TARGETS, REORDER_JOKERS and REORDER_HAND. See [LEGAL_ACTIONS.md](LEGAL_ACTIONS.md).

The catalogue is a deliberately nonexhaustive certified subset, capped at 128. Unknown authoritative legality evidence yields no action. Independent generator checks cover phase, references, duplicates, cardinality, hands/discards, money/credit, free-versus-voucher semantics, explicit capacity evidence, negative-edition exceptions, target bounds/source binding and ordering permutations. Blocked, expired or completed observations yield no choices. Certificates cannot bypass these checks and must eventually be produced without hidden-state probing. No speculative UI callbacks are invoked by enumeration.

### Serialization and hash

The codec emits explicit type tags, lengths, dense-array order and bytewise-sorted typed map keys. Only bounded int32 numeric fields are admitted; displayed scores and timers are strings. Unsupported functions, userdata, metatables, cycles, sparse arrays, nonfinite/fractional numbers and excessive sizes fail. Lua 5.1/LuaJIT cross-runtime vectors agree. FNV-1a-32 is a stable diagnostic checksum, never a security token, freshness check or authorization mechanism. The broker compares full canonical strings and independent epochs.

## Fairness and trust

Allowed data is restricted to the AI player's legitimately visible current state and Multiplayer's public display projections. The following never enter policy observations: draw order, future shops/packs/cards, hidden RNG or seeds (including known benchmark seeds), private opponent hands/decks/Jokers/shops, server/matchmaking secrets, raw scores/timers, stale future/replay state, callbacks, arbitrary globals or paths back to engine objects. Unknown fields are not traversed. Deck rank/suit maps are omitted by both reader and schema; only the visible total is supported until a safe deck-preview contract exists.

The reader enforces Multiplayer score masking, readiness and location/timer visibility gates. Engine-derived PvP state, including Lua truthiness, prevents contradictory view flags from unmasking scores. Tokens are consumed before callbacks, and trusted revisions must advance on every decision-relevant state change, including A-to-B-to-A. Booster phases use the five real *_PACK symbols and SMODS_BOOSTER_OPENED. Exact rendered timers are required; no raw `last_timer` fallback exists. A trusted view producer can still lie about an allowlisted value: its correctness and provenance are part of the reviewed trusted computing base. Neither caller-supplied role strings nor schema validation authenticate a process. Future launcher authentication, epoch assignment and UI-equivalent certificate production remain mandatory gates.

The development worker has a 64 MiB Lua VM limit, bounded input/source/output, text-only source, instruction budget, restricted direct and string-metatable library routes, no Python objects/globals, and validated selection output. The test caller imposes a 10-second wall deadline. Lua hooks do not bound every native C call; the private helper has no standalone memory/OS protection and must never be loaded in Balatro. Production process watchdog/isolation remains unimplemented. See [FAIRNESS.md](FAIRNESS.md) for the 15-threat analysis.

## Tests and performance

Independently reproduced results after review fixes:

| Suite | Unique named cases | Executions | Result |
|---|---:|---:|---|
| Pure observation/codec/actions | 96 | 188 | 92 Lua cases each runtime + 4 static; pass |
| State reader | 61 | 122 | 61 each runtime; pass |
| Broker/worker | 123 | 219 | 59 Lua cases each runtime + 23 static + 78 subprocess executions; pass |
| Astra independent attacks | 18 | 36 | 18 each runtime; pass |
| Astra oracle mutation checks | 3 | 6 | 3 each runtime; pass |
| **M2 total** | **301** | **571** | **Pass** |
| Existing M1 regression | 66 | 117 | 51 each runtime + 15 static; pass |
| **Combined** | **367** | **688** | **Pass** |

The worker has 41 logical subprocess cases, 37 executed once per runtime and four runtime-independent cases. The initial suite had 400 ineffective property iterations caused by incorrect call arguments; these are corrected. The final oracle checks exact candidate-set equality using separate legality predicates. Astra proved it detects in-memory mutants bypassing affordability, capacity and hands-remaining checks. Property loops add 520 deterministic seeded synthetic frames per runtime (1,040 total); iterations are not inflated into named-case counts. Checks include legal resources/references/phase, bounds, no duplicates, deterministic actions, hidden-field invariance and mutation isolation. Python independently verifies selected codec/FNV vectors. Fixtures exercise actual repository modules, not copied implementations. Claude inspects source and evidence; it does not independently execute tests through its read-only tool allowance.

| Fixture benchmark | Lua 5.1 | LuaJIT |
|---|---:|---:|
| SHOP observation build | 1.907 ms | 0.273 ms |
| PLAY observation build | 1.620 ms | 0.213 ms |
| SHOP action enumeration | 0.107 ms | 0.033 ms |
| PLAY action enumeration | 0.120 ms | 0.033 ms |
| Retained SHOP allocation, approximate | 7.51 KiB | 5.21 KiB |

Canonical fixture sizes are 1,286 bytes SHOP and 1,001 bytes PLAY. These are medians over seven batches of 150 operations and approximate GC-based allocations over 200 held handles. Synthetic, machine-specific figures include normalization/serialization/hash work; they are not live capture, IPC, full-game or policy-search measurements. Rerun `tests/benchmark_m2.py --require-all` rather than treating these figures as a performance guarantee.

## Adversarial workflow

DeepSeek V4.1 Flash High implemented the modules, documentation and main tests. Astra defined interfaces/threats, inspected source, ran independent suites, authored 18 boundary attack probes and 3 oracle mutation checks and routed defects back. [ASTRA_M2_VERIFICATION.md](ASTRA_M2_VERIFICATION.md) records the full evidence.

DeepSeek's required [self-review](DEEPSEEK_M2_ADVERSARIAL.md) answers both hidden-information and illegal-mutation questions. It identified the indirect string-library route, empty JSON array ambiguity and exception-unsafe broker guard; all were fixed and regression-tested before Claude. C-call availability, trusted producer/validator correctness, fresh-broker-per-session semantics and future target mapping are explicitly scoped residual obligations.

Astra's fixes included exact rather than wildcard certificates, explicit capacity checks, consumable source binding, face visibility/Stone masks, nonnegative epochs, fresh post-validator capture, replay/reentrancy protections, worker input re-sanitization, mandatory VM memory caps and bounded file reads. Initial missing-visibility/negative-epoch attack failures now pass. DeepSeek also caught and fixed a Lua boolean-default bug that denied every action and a worker table-constructor bug that prevented all worker requests.

Claude requested changes with no Critical/High findings and eight Medium findings. DeepSeek implemented all Medium and Low fixes; Astra independently verified them and added follow-up tripwire and Lua-truthiness probes. See [CLAUDE_M2_REVIEW.md](CLAUDE_M2_REVIEW.md) and [CLAUDE_M2_RESOLUTION.md](CLAUDE_M2_RESOLUTION.md) for every finding, fix and residual Info disposition. Claude accepted the re-review with all Medium findings closed. Its remaining Low formatter-address route and optional probe assertion were hardened and independently retested. Claude's focused final confirmation closed both and reaffirmed ACCEPT; see [CLAUDE_M2_REREVIEW.md](CLAUDE_M2_REREVIEW.md). No Critical, High or fairness-relevant Medium finding remains open.

## Remaining integration work

- Real UI-view/certificate production and authenticated AI-runtime/epoch provenance.
- Real target mapping and authoritative engine action validation/execution.
- Staged launcher/process watchdog, filesystem/profile/Steam/cloud isolation and local-server parity gates.
- Real Steamodded load and game-state capture smoke tests in a safe integration window.
- No real game performance or full rules/action coverage claim.

No blocking review issue remains. Accepted limitations include whole-observation rejection for excessive/invalid data, potentially different bounded diagnostic codes for multiply-invalid input, trusted producer/target-mapping obligations, and native-library wall-time requiring the external process deadline. Formatting has a post-allocation size check inside the capped Lua VM; unsupported native format syntax fails with a bounded error. None grants policy game access or enables real dispatch.

These are explicit integration gates, not silently enabled features. No live Balatro, Mods or save file was modified; the game was neither launched nor closed. Handy, JokerDisplay and Multiplayer were preserved. Milestone 3 has not begun.

## File inventory

New implementation, test and supporting-document files in the reviewed change:

```text
AISparring/ai/actions.lua
AISparring/ai/codec.lua
AISparring/ai/observation.lua
AISparring/integration/action_broker.lua
AISparring/integration/state_reader.lua
docs/AI_OBSERVATION.md
docs/ASTRA_M2_VERIFICATION.md
docs/DEEPSEEK_M2_ADVERSARIAL.md
docs/FAIRNESS.md
docs/LEGAL_ACTIONS.md
docs/M2_EXECUTION_BOUNDARY.md
docs/M2_SOURCE_MAP.md
docs/MILESTONE_2_PLAN.md
docs/STATE_READER.md
tests/astra_attacks.py
tests/benchmark_m2.py
tests/boundary/framework.lua
tests/boundary/runner.lua
tests/boundary/support.lua
tests/boundary/test_broker.lua
tests/boundary/test_policy_env.lua
tests/m2/framework.lua
tests/m2/runner.lua
tests/m2/test_actions.lua
tests/m2/test_actions_shop.lua
tests/m2/test_actions_targets.lua
tests/m2/test_codec.lua
tests/m2/test_isolation.lua
tests/m2/test_observation.lua
tests/m2/test_property.lua
tests/m2/test_validation.lua
tests/m2/test_vectors.lua
tests/reader/runner.lua
tests/reader/support.lua
tests/reader/test_gates.lua
tests/reader/test_isolation.lua
tests/reader/test_positive.lua
tests/reader/test_visibility.lua
tests/run_boundary.py
tests/run_m2.py
tests/run_reader.py
tools/lua/policy_env.lua
tools/policy_worker.py
```

Existing files updated:

```text
.gitignore
README.md
docs/DEVELOPER.md
```

Additional files created during review and completion:

```text
docs/MILESTONE_2.md
docs/CLAUDE_M2_REVIEW.md
docs/CLAUDE_M2_RESOLUTION.md
docs/CLAUDE_M2_REREVIEW.md
tests/astra_mutation_checks.py
tests/boundary/test_load_tripwire.lua
```

The saved re-review and its targeted follow-up are in `docs/CLAUDE_M2_REREVIEW.md`.
