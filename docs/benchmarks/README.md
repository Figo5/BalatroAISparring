# Policy benchmarks

> **What these numbers are not.** The reference scorer is written separately
> from the policy, but it encodes the *same* scoring model: the same hand
> bases and levels, card effects and Joker table. A high "agreement" figure
> means the two implementations match on states that model covers. It is not
> evidence that the AI plays optimally, plays well, or wins. Both share the
> same blind spots: scaling Jokers, rule-changing Jokers, boss blinds, shops,
> long-term economy and opponents. Real strength still needs live Gauntlet
> runs (LOCAL VALIDATION REQUIRED).

`tests/benchmark_policy.py` builds seeded, rules-shaped play-phase states and
runs each one through the real trusted pipeline: engine fixture → EngineAdapter
→ StateReader → AIObservation export → sandboxed policy. A reference scorer
that shares the policy's scoring model then grades each decision. It uses no
game files or network and runs in the cloud.

```
python tests/benchmark_policy.py --scenarios 300                      # report
python tests/benchmark_policy.py --scenarios 300 --check docs/benchmarks/policy_baseline.json
python tests/benchmark_policy.py --seed 5 --seed 99 --scenarios 600  # other seed families
python tests/benchmark_policy.py --scenarios 150 --discard-samples 6  # + discard quality (slower)
python tests/benchmark_policy.py --runtime lupa.lua51                 # strict instruction-budget runtime
python tests/benchmark_policy.py --families --scenarios 300           # per-stage report (early/mid/late)
python tests/benchmark_policy.py --hard --scenarios 200               # stress families outside the shared model
```

By default scenarios come from one `mixed` distribution, the one the stored
baselines were generated with, so `--check` stays comparable. `--families`
cycles three stage shapes instead, and the report's `families` section splits
results by stage, with PvP scenarios as `<stage>/pvp`:

- `early`: small requirement, 0–2 Jokers, few low levels, sparse enhancements;
- `mid`: 1–4 Jokers, levels 2–4;
- `late`: requirement 11k–50k, 3–5 Jokers, levels 4–8, denser enhancements.

`clear_taken` is always null for PvP families, because a PvP blind has no
visible requirement. A family's `decisions` counts only valid (ok, legal)
choices, so it can be lower than the difficulty totals. Do not compare a
`--families` report against the mixed baselines.

| File | What it is |
|---|---|
| `policy_before_estimator.json` | before the chips × mult estimator (category ranking only) |
| `policy_baseline.json` | current accepted baseline, used by `--check` |
| `policy_discard_baseline.json` | same, with `--scenarios 150 --discard-samples 6`: also gates discard quality |
| `policy_hard_report.json` | `--hard --scenarios 200` (LuaJIT): informational, not a `--check` baseline |

Summary (300 scenarios, seeds 11/23/37, LuaJIT). The first three rows measure
**agreement with the shared scoring model**, not play quality. "100%" there
only means the policy's estimator and the reference agree on the best offered
play for states both of them model.

| Metric | before | competitive / major_league / expert now | rookie now |
|---|---|---|---|
| agrees with the shared model's best offered play | 75.2% | 100% | 78.1% |
| mean gap to the shared model's best offered play | 12.2% | 0% | 8.9% |
| clearing hand taken when the shared model sees one | 84% | 100% | 81% |
| adapter candidate coverage | 96.9% | 97.8% | 97.8% |
| discard quality (`--discard-samples 6`, 150 scenarios): chosen / best offered discard expected follow-up, over the decisions where the policy chose to discard | ~68% | ~79–84% | ~51–68% |
| forced-discard quality: the same observation with only its discard certificates, so every difficulty ranks discards on identical states | n/a | ~84.5% | ~70% |
| failures / illegal | 0 / 0 | 0 / 0 | 0 / 0 |
| mean decision latency (LuaJIT; Lua 5.1 ≈ 2×) | ~10 ms | ~15–17 ms | ~12 ms |

The plain discard-quality metric depends on *when* a policy chooses to
discard, so it is not comparable across policies that discard in different
situations (for example after hand levels were added). Compare forced-discard
quality instead.

**Read these honestly.** The policy's estimator and the reference scorer share
the same scoring model. Agreement is therefore a consistency check. It is how
the benchmark caught a real scoping bug where the estimate never ran. It is not
a strength measure or a win rate. Discard quality is a Monte Carlo estimate over
the unseen standard deck, which the policy also uses as its prior, so it shares
that assumption too. Use these figures to catch regressions and compare
difficulties, not to claim that the AI plays well.

## Harder coverage (`--hard`)

`--hard` cycles four stress families. It also records per-decision sandbox
instructions (`max_instructions`), failures and latency, and runs on either
runtime:

| Family | What it adds | What is trustworthy |
|---|---|---|
| `large_hand` | 9–12 card hands (Juggler, Paint Brush, Turtle Bean), 2–5 Jokers | reliability and budget; agreement stays within the shared model |
| `scaling` | one scaling Joker (Ride the Bus, Green Joker, Obelisk, Hologram, …) | reliability only: both sides treat it as no effect |
| `rule` | one rule-changing Joker (Four Fingers, Shortcut, Smeared, Splash, Pareidolia) | reliability only: the policy falls back to category ranking and the reference ignores the rule |
| `boss` | a boss blind key; suit bosses and The Plant debuff their cards | reliability only: rule-changing boss effects are not modelled |

200 scenarios (seeds 11/23/37), from `policy_hard_report.json`:

| | Rookie | Competitive | Major League | Expert |
|---|---|---|---|---|
| failures / illegal | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| max sandbox instructions (budget 2,000,000) | 185k | 854k | 852k | 1,036k |
| mean / p95 latency, LuaJIT | 12 / 19 ms | 14 / 24 ms | 13 / 21 ms | 14 / 26 ms |

The `boss` and `scaling` families still show about 100% agreement. That is
exactly the shared blind spot: neither side models those effects, so this
agreement means nothing about play quality there.

## Blind simulator (`tests/benchmark_blinds.py`)

A first step towards full-run (Gauntlet) metrics:

- **Deal and act:** each blind deals from a shuffled 52-card deck, and the
  policy plays and discards repeatedly through the real adapter → reader →
  sandbox pipeline, drawing back to 8, until the requirement is met or no
  hands remain.
- **Same luck for everyone:** every difficulty sees the same deck order.
- **Blinds:** antes 1–4 (base 300 / 800 / 2,000 / 5,000); small ×1, big ×1.5,
  bosses ×2 except The Needle ×1.
- **Boss effects** (only those the fixture can represent faithfully), each from
  its vanilla minimum ante:
  - The Club, Goad, Window and Head debuff their suit (ante 1+);
  - The Plant debuffs face cards (ante 4+);
  - The Psychic scores only 5-card hands (ante 1+);
  - The Needle allows one hand, and The Water allows no discards (ante 2+).

Plays are scored with the shared reference model. So this measures how well
play and discard decisions are sequenced under real random draws within that
model. It is **not** a Balatro win rate. Lucky cards score their average and
Glass cards never break.

```
python tests/benchmark_blinds.py --blinds 360 --json docs/benchmarks/blinds_report.json
python tests/benchmark_blinds.py --blinds 720 --policy candidate.lua --paired base.lua --difficulty expert   # A/B
```

360 blinds (seed 7, LuaJIT), from `blinds_report.json`. Blind counts are in
brackets:

| | Rookie | Competitive | Major League | Expert |
|---|---|---|---|---|
| blinds cleared | 58.6% | 81.7% | 81.4% | 80.8% |
| cleared, ante 1 / 2 / 3 / 4 | 81 / 64 / 53 / 36% | 97 / 84 / 82 / 63% | 94 / 86 / 81 / 64% | 91 / 86 / 81 / 66% |
| small (120) / big (120) | 78 / 61% | 96 / 85% | 96 / 85% | 95 / 84% |
| Club (14) / Goad (19) / Window (23) / Head (19) | 36 / 47 / 57 / 37% | 71 / 74 / 57 / 79% | 71 / 74 / 57 / 68% | 64 / 74 / 65 / 68% |
| The Psychic (19) | 37% | 79% | 84% | 74% |
| The Needle (13) / The Water (11) | 8 / 0% | 62 / 0% | 62 / 0% | 69 / 0% |
| The Plant (2, ante 4 only) | 100% | 100% | 100% | 100% |
| failures / step-cap stops | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| max sandbox instructions | 157k | 868k | 865k | 974k |

The strong tiers are close to each other here. Major League's differences are
mostly in shop and reserve settings, which this simulator does not exercise.
Per-boss rows rest on 2–23 blinds and are noisy. Adding The Psychic reshuffled
which boss each seed draws, so these rows are not comparable with earlier
reports. For example, The Water is 0 of 11 here but was 25% of 12 before.

**Boss awareness under The Psychic** (`boss_aware`) is judged by paired A/B
(720 blinds, seed 7): +0.7% overall for Competitive and Expert, from 7 changed
blinds netting +5. The Psychic is about 4% of blinds, so its own clear rate
rises by roughly 17 points. The adapter also offers rank groups and two pair
padded to five cards under The Psychic. That raised Psychic clears on these
19 blinds from 68% to 79% / 84% / 74% (Competitive / Major League / Expert).

## Run simulator (`tests/benchmark_runs.py`)

A first run-level metric:

- **Runs:** antes 1–6, each with small, big and boss blinds. A run ends at the
  first failed blind.
- **Money:** a $4 start, blind rewards ($3 / $4 / $5), $1 per unused hand, and
  interest ($1 per $5, at most $5). Money never goes below $0.
- **Shop** after each cleared blind:
  - two offers, each a Joker ($4–8) or a planet ($3);
  - rerolls from $5, rising by $1;
  - five Joker slots;
  - selling returns half the price;
  - a bought planet levels its hand at once.
- **Pipeline:** every decision goes through the real adapter → reader →
  sandbox pipeline.
- **Same seeds:** decks and shop offers depend only on the run seed and the
  position, so every difficulty sees the same ones.
- **Validation:** an illegal buy, reroll or reorder, or a no-action, counts as
  a failure.

Scored with the shared reference model. There are no packs, vouchers, tags,
scaling Jokers or opponents, so this is **not** a Balatro win rate.

```
python tests/benchmark_runs.py --runs 60 --json docs/benchmarks/runs_report.json
git show 5b0cd64:AISparring/ai/baseline_policy.lua > /tmp/old.lua     # pre-retune policy
python tests/benchmark_runs.py --paired /tmp/old.lua --seed 37 --runs 150   # A/B on the same seeds
```

60 runs (seed 11, LuaJIT), from `runs_report.json`, with The Psychic
included and the current policy:

| | Rookie | Competitive | Major League | Expert |
|---|---|---|---|---|
| mean blinds cleared (of 18) | 5.0 | 11.8 | 11.8 | 11.5 |
| mean ante reached | 2.3 | 4.6 | 4.5 | 4.5 |
| reached ante 4 / 6 | 20 / 7% | 78 / 32% | 77 / 32% | 78 / 30% |
| planets / rerolls per run | 3.0 / 1.0 | 8.4 / 3.9 | 8.1 / 3.8 | 7.8 / 3.9 |
| money at the end | $7 | $31 | $34 | $35 |
| failures | 0 | 0 | 0 | 0 |
| max sandbox instructions | 154k | 868k | 868k | 1,004k |

This simulator exposed Major League and Expert hoarding money above the
interest cap. Their economy was retuned and judged on held-out seeds
(`docs/BASELINE_POLICY.md` §5): pooled over 300 paired runs, Major League
gained about +0.33 blinds per run and Expert about +0.51. With 60 runs the
standard error of a mean is about 0.6 blinds, so the strong tiers are
statistically tied here. Only paired comparisons resolve smaller differences.

### Not yet covered (prepared, continuing)

These need a model that differs from the policy's, or multi-decision
simulation, before any metric is meaningful:

- **Scaling-Joker value:** grading plays and purchases by future scaling
  (Ride the Bus streaks, Green Joker discards, Obelisk).
- **Rule-changing Jokers:** a reference `classify` that implements Four Fingers,
  Shortcut, Smeared and Splash, so agreement can be measured there.
- **Boss blinds:** The Psychic (must play 5), The Eye/Mouth (hand repetition),
  The Flint (halved base), The Needle (one hand).
- **Close-EV decisions:** a subset metric for states where the top two offered
  plays or discards are within 5%, so ties decided by noise are visible.
- **Survival vs economy:** shop sequences where interest, reserve and
  buying power trade off against clearing the next blind. This needs a
  multi-round simulation, not a single-decision grade.

Full-run strength still needs Gauntlet metrics: shops, bosses and money
across a whole run (planned; the blind simulator is the first piece).
