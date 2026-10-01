# Local H1 performance and determinism verification

Fresh independent Astra sweep after the Claude findings fixes. Tested code checkpoint: `eb39c6262a2a8dbbee9a2982c68cf9e23aa5e8d2`. Repository fixture evidence; no native gameplay, visual Tarot-effect or AI-strength claim.

## Method

Own hands 8/9/10/11/12; 5 and 8 Jokers; Competitive/Major League/Expert; non-clearing and PvP frames; held Death/Strength/Sun. Thirty deterministic varied trials per cell, 1,800 decisions/runtime. Real adapter/reader observations and legal catalogues. Each decision runs twice under the real unchanged 2,000,000-instruction sandbox budget and must agree with separately instrumented measurement. Only the in-memory instrumented sandbox lifts its cap; production limits remain unchanged.

Park-Miller fixture randomness keeps integer products exact in doubles. The older overflow-prone fixture distribution is not an optimization baseline. Instruction-hook stride is read from the real sandbox.

## Results

| Runtime | Decisions | Budget failures | Peak instructions | Max candidates | Max Lua latency (ms) |
|---|---:|---:|---:|---:|---:|
| lupa.lua51 | 1,800 | 0 | 1,256,000 | 120 | 83.000 |
| lupa.luajit21 | 1,800 | 0 | 1,263,000 | 120 | 38.000 |

Both runtimes select identical actions: SHA256 `6920e8b4c8b82aa47364d3732ec347d98423edbbdd450b509cb03ed1d58136ed`. No real-budget failures, over-budget measurements or nondeterministic repeats. The peak leaves 36.9% of the 2M allowance unused. Legal catalogues stay at or below 120, with targeted Tarots and meaningful reorders retained.

Lua latency includes fixture sandbox work and excludes Python launch, transport, handoff and native animation settlement. Other verification workers were active during measurement; this is observed local fixture latency, not a promised game ceiling.

## Rendered policy size

| Difficulty | UTF-8 bytes (both runtimes) |
|---|---:|
| rookie | 56,389 |
| competitive | 56,390 |
| major_league | 56,392 |
| expert | 56,385 |

Largest source leaves **952 bytes** below the unchanged 57,344 repository guard and **9,144 bytes** below the 65,536 hard cap. Compaction and permanent squeezed/unsqueezed checks remain enabled.

## Exact binding

Executed immutable snapshot: `work/local-ownership/claude-fixes-h1-snapshot`. Its `work/local-ownership/h1-summary.json` and per-runtime text retain raw counts/latencies/digests. All current companion, Lua sandbox and relevant fixture inputs were independently byte-compared with the snapshot. Exact hashes and measured sizes are in `claude-fixes-h1-verified-summary.json`; copied-source hashes are in `claude-fixes-h1-source-hashes.json`.

Any later change to those inputs requires fresh measurement. Claude source acceptance, actual native certification, installation and UI smoke remain separate gates. Prior sweep evidence is preserved in `phase-ab-h1-snapshot`.
