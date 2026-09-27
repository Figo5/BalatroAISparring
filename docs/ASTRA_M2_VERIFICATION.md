# Astra independent verification — Milestone 2

Date: 2026-09-27. Baseline: accepted M1 commit `8bcccabbce0693cf5a0e168babacfa511c2443e0`. This document records independent inspection, execution and the final acceptance disposition below.

## Architecture and source inspection

I checked the implementation against INTEGRATION_PLAN.md and MILESTONE_2_PLAN.md. The two staged runtimes / local legacy server / separate policy worker direction is unchanged. None of the new modules is wired into M1 startup. The real executor returns an explicit disabled result. No strategy, evaluator, search, gameplay opponent, network transport or game launch was added.

I inspected pinned Multiplayer UI and game callback source (kept outside tracked files). This exposed an incorrect early assumption about own face-down cards. Own possession does not make a face-down identity visible. I required explicit field visibility, front-facing backing cards, and Stone/no-rank/no-suit/replacement masks. Timers use only certified rendered strings, never reconstructed raw `last_timer`; hidden score/location gates remain in the reader.

The UI-view/certificate producer is trusted and unwired. Role and epoch fields are trusted claims, not authenticated process identity. A schema cannot prove the truth of an allowed value supplied by a malicious trusted producer. The future producer, launcher authentication, positional target mapping and authoritative executor require their own review and staged runtime evidence. No prototype gate is claimed passed.

## Findings independently routed to DeepSeek

- A wildcard legality flag could authorize unvalidated targets/items. Required bounded exact per-action certificates, plus independent phase/resource/reference checks.
- Public mutable schema constants could affect internals. Required private constants and exported copies where relevant.
- Negative-edition purchases bypassed capacity certification; omitted owned lists were treated as empty. Required positive capacity evidence and deny-on-unknown normal capacity.
- Targeted consumable actions lacked a reliable source binding. Required an owned `consumable:N` source reference and exact match to the active target context; reader rejects duplicate target ordinals.
- Reader accepted missing face-down visibility flags and negative epochs; it omitted the explicit vanilla Stone mask. Required fail-closed fixes and regressions.
- Broker rechecked its old immutable handle rather than fresh state after validator callbacks. Required atomic handle/epoch captures, recapture after validation, reentrancy protection, independent validator copies and single-use tokens.
- Worker accepted arbitrary JSON as policy input. Required re-sanitization, action regeneration and final selection validation inside a fresh interpreter, with no caller-supplied action authority.
- Optional memory-limit feature detection could silently leave execution unbounded. Required explicit VM memory limits and fail-closed unsupported-runtime behavior.
- `--input` read a whole file before enforcing the byte cap. Required a bounded read before parsing.
- Boundary test totals counted each runtime as a distinct worker case. Required unique logical-case counts separate from execution counts.

## Executed independent attacks

`tests/astra_attacks.py` is Astra-authored, independent of DeepSeek's test fixtures. Twelve probes run under both Lua 5.1 and LuaJIT:

1. Negative purchase with denied capacity evidence.
2. Purchase with missing owned-capacity data.
3. Poisoned Stone-card rank/suit visibility.
4. Missing explicit face visibility.
5. Masked opponent score resurrection.
6. Hidden deck/RNG/raw opponent-score perturbation.
7. Negative runtime/view epochs.
8. Source, nested export and raw handle mutation.
9. Unknown callback and cyclic hidden fields.
10. Forged action content with a retained valid ID.
11. State changed during authoritative validation.
12. Replay and cross-broker token reuse.

The initial run reproduced the missing-visibility and negative-epoch defects on both runtimes while fixes were underway. The subsequent independent run passed all 24 executions. The script is retained as regression evidence.

## Historical pre-Claude suite and performance runs

The pure suite passed 93 unique cases / 182 executions, including 89 Lua cases per runtime and 4 static checks. It reported 1,040 property iterations, but Claude subsequently identified 400 ineffective iterations caused by incorrect API arguments. That defect is fixed and the revised evidence below supersedes the original coverage claim. Canonical/hash/action vectors matched across runtimes; Python independently checks FNV and selected canonical vectors. The state-reader suite passed 53 unique cases / 106 executions. The unchanged M1 regression suite passed 66 unique cases / 117 executions.

The broker/worker suite was independently rerun after the self-review fixes: 94 unique cases / 168 executions passed (17 static, 48 Lua cases per runtime, 29 logical subprocess cases / 55 subprocess executions). The complete M2 pre-Claude total is 252 unique named cases / 480 executions, excluding property iterations from case totals. Including M1 regressions gives 318 unique cases / 597 executions. Final review disposition is recorded in MILESTONE_2.md after review. Subprocess attacks have a 10-second external deadline. Lua instruction hooks do not bound every C-library call, and the private helper alone is not an OS sandbox. Production watchdog and process isolation remain a launcher gate. The helper must never be loaded into the game interpreter.

Independent benchmark: seven batches of 150 operations, two synthetic fixtures, retained allocation estimated with 200 handles. Lua 5.1 SHOP/PLAY observation medians: 1.827/1.527 ms; enumeration: 0.107/0.093 ms. LuaJIT: 0.313/0.240 ms and 0.033/0.033 ms. Canonical sizes: 1,253/1,001 bytes. Approximate retained SHOP allocation: 10.02 KiB / 7.47 KiB per observation. These are machine-specific, GC-sensitive fixture measurements, not live performance or search throughput.

## Independent post-review verification

All eight Medium findings were implemented and independently checked; see CLAUDE_M2_RESOLUTION.md for the complete matrix, including Low/Info dispositions. Additional Astra probes cover hidden-card deck-map inference, contradictory PvP flags, failed-submit ABA, unseen ABA revisions, module-load VM mutation and Lua-truthy PvP flags. The expanded attack script passes 18 probes / 36 executions. The last two exposed real follow-up defects, both fixed by DeepSeek.

`tests/astra_mutation_checks.py` modifies generator source in memory only, deliberately bypassing affordability, Joker capacity and hands-remaining checks. The independent property oracle rejects all three mutants on both runtimes (3 unique checks / 6 executions). No production source file is altered by this harness.

Revised suites pass: pure 96/188 unique/executions, reader 61/122, broker/worker 123/219, Astra attacks 18/36, mutation checks 3/6. M2 totals are 301 unique cases / 571 executions. Including unchanged M1 regressions: 367 unique / 688 executions. All 1,040 property iterations now exercise their intended frames. The worker's finite 16 MiB positive and 128 MiB negative controls substantiate the Lua VM memory cap on both runtimes.

Revised benchmark: SHOP/PLAY canonical sizes 1,286/1,001 bytes; Lua 5.1 observe 1.907/1.620 ms, enumerate 0.107/0.120 ms; LuaJIT observe 0.273/0.213 ms, enumerate 0.033/0.033 ms. Approximate retained SHOP allocation: 7.51/5.21 KiB. These supersede earlier fixture timings; the same measurement caveats apply.

## Live safety (all runs)

All implementation and testing occurred in this isolated repository or workspace scratch directories. The only game-source access was read-only inspection. No live Mods/game/save files were written, no game/server was launched, and Balatro was not stopped. Real-game load, capture, UI certification, action execution, server parity and staged isolation remain pending.

Formatter follow-up: DeepSeek closed the Low LuaJIT format coercion/pointer route; Astra independently reran the boundary suite (123/219) and strengthened tripwire probes (18/36), all passing. A focused Claude confirmation follows the accepted full re-review.

## Astra acceptance

Accepted for Milestone 2 infrastructure after Claude's full re-review and targeted formatter confirmation both returned ACCEPT. All Medium findings and the remaining Low/Info follow-ups were resolved or explicitly scoped; no Critical/High/fairness-Medium issue remains. Final verified totals: 301 M2 unique cases / 571 executions, 1,040 genuine property iterations; including M1, 367 / 688. No source changes followed the final confirmation. The reviewed state is committed and the final handoff records the commit and clean-tree verification. No Milestone 3 or live integration is authorized by this acceptance.
