# Local H1 performance and determinism verification

Independent Astra measurement, September 30, 2026. Repository fixture evidence;
this does not establish native gameplay, Tarot visual effects or AI strength.

## Coverage and method

- Own-hand sizes 8, 9, 10, 11 and 12; 5 and 8 Jokers; all three strong tiers.
- Non-clearing blinds and PvP frames; held Death, Strength and The Sun.
- Thirty deterministic varied trials per cell, 1,800 decisions per runtime.
- Real adapter/reader observations and generated legal-action catalogues.
- Each decision runs under the unchanged real 2,000,000-instruction budget
  twice. Both repeats must match the separately instrumented decision.
- An immutable source snapshot is used. Only the instrumented in-memory
  sandbox lifts its limit to measure cost; production source remains unchanged.
- Hook stride is read from the real sandbox; peak counts below are not rounded
  to thousands beyond the hook resolution.
- Park-Miller fixture randomness keeps products within exact-double integer
  range. The prior harness multiplier lost low bits above 2^53; its older
  instruction peak is not a directly comparable optimization baseline.

## Results

| Runtime | Decisions | Budget failures | Peak instructions | Max candidates | Max Lua latency (ms) |
|---|---:|---:|---:|---:|---:|
| lupa.lua51 | 1,800 | 0 | 1,254,000 | 120 | 124.000 |
| lupa.luajit21 | 1,800 | 0 | 1,262,000 | 120 | 43.000 |

**Both runtimes select identical actions** (SHA256
`6920e8b4c8b82aa47364d3732ec347d98423edbbdd450b509cb03ed1d58136ed`). No over-budget instruction counts,
real-budget failures or nondeterministic repeats occurred. The measured worst
case leaves approximately 37% of the 2M instruction allowance unused.
The catalogue stays at or below 120; up to 24 targeted-Tarot certificates and
meaningful reorders remain available.

Latency is the Lua fixture run measured by `os.clock`, including sandbox work.
It excludes Python worker launch, service transport, handoff and native
animation/effect settlement. Other repository workers/tests were active during
the sweep; this is a local measured ceiling, not a promised in-game latency.

## Rendered policy size

| Difficulty | UTF-8 bytes (both runtimes) |
|---|---:|
| rookie | 54,737 |
| competitive | 54,738 |
| major_league | 54,740 |
| expert | 54,733 |

The largest source leaves **2,604 bytes** below the unchanged
57,344 repository guard and **10,796 bytes** below the 65,536 hard cap.
Compaction remains enabled; permanent squeezed/unsqueezed bytecode checks remain
part of the policy suite.

## Source and evidence binding

The executed snapshot is `work/local-ownership/phase-ab-h1-snapshot`.
Raw cell counts/latencies and result digests are in its
`work/local-ownership/h1-lupa.lua51.txt`, `h1-lupa.luajit21.txt` and
`h1-summary.json`. The current relevant policy, observation, adapter, reader,
revision, sandbox and engine-fixture files were independently byte-compared
with that snapshot after the run. Exact hashes and current rendered sizes are
recorded in `work/local-ownership/h1-verified-summary.json`.

Subsequent logger formatting changes do not alter these measured policy inputs
or sandbox code. Any later change to those inputs requires fresh measurements.
Claude acceptance, seven-phase native certification and live smoke remain
separate gates.
