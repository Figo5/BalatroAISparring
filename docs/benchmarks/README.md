# Policy benchmarks

`tests/benchmark_policy.py` builds seeded, rules-shaped play-phase states and
runs each one through the real trusted pipeline: engine fixture → EngineAdapter
→ StateReader → AIObservation export → sandboxed policy. An independent Python
reference scorer then grades each decision against public Balatro scoring rules.
It uses no game files or network and runs in the cloud.

```
python tests/benchmark_policy.py --scenarios 300                      # report
python tests/benchmark_policy.py --scenarios 300 --check docs/benchmarks/policy_baseline.json
python tests/benchmark_policy.py --seed 5 --seed 99 --scenarios 600  # other seed families
python tests/benchmark_policy.py --scenarios 150 --discard-samples 6  # + discard quality (slower)
python tests/benchmark_policy.py --runtime lupa.lua51                 # strict instruction-budget runtime
```

| File | What it is |
|---|---|
| `policy_before_estimator.json` | before the chips × mult estimator (category ranking only) |
| `policy_baseline.json` | current accepted baseline, used by `--check` |
| `policy_discard_baseline.json` | same, with `--scenarios 150 --discard-samples 6`: also gates discard quality |

Summary (300 scenarios, seeds 11/23/37, LuaJIT):

| Metric | before | competitive / major_league now | rookie now |
|---|---|---|---|
| best offered play chosen | 75.2% | 100% | 86.2% |
| mean regret vs best offered | 12.2% | 0% | 6.7% |
| clearing hand taken when one existed | 84% | 100% | 87% |
| adapter candidate coverage | 96.9% | 97.2% | 97.2% |
| discard quality (`--discard-samples 6`, 150 scenarios): chosen / best offered discard expected follow-up, over the decisions where the policy chose to discard | ~68% | ~79–84% | ~51–68% |
| forced-discard quality: the same observation with only its discard certificates, so every difficulty ranks discards on identical states | n/a | ~84.5% | ~70% |
| failures / illegal | 0 / 0 | 0 / 0 | 0 / 0 |
| mean decision latency (LuaJIT; Lua 5.1 ≈ 2×) | ~10 ms | ~15 ms | ~11 ms |

The plain discard-quality metric depends on *when* a policy chooses to
discard, so it is not comparable across policies that discard in different
situations (for example after hand levels were added). Compare forced-discard
quality instead.

**Read these honestly.** The policy estimator and the reference scorer encode
the same public rules. So 100% means the two independent implementations agree,
which is how the benchmark caught a real scoping bug where the estimate never
ran. It is not a win rate. Scenarios include random hand levels (public per-level
increments). The benchmark does not model scaling
Jokers, boss blinds, shops or opponents. Discard quality is a Monte Carlo
estimate over the unseen standard deck, which the policy also uses as its prior. Use it to catch
regressions and compare difficulties, not to claim real strength. Real strength
still needs live Gauntlet runs (LOCAL VALIDATION REQUIRED).
