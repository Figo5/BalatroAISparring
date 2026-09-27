# Milestone 2 review resolution

Status: implemented by DeepSeek V4.1 Flash High, independently verified by Astra; Claude accepted the scoped M2 re-review. N1/N2 hardening below is independently verified and accepted by Claude's targeted final confirmation. Astra accepts the scoped milestone. Original review: [CLAUDE_M2_REVIEW.md](CLAUDE_M2_REVIEW.md), exact model `claude-opus-5-5`, High. No architecture switch or live integration was needed.

| Finding | Resolution and evidence |
|---|---|
| M1 — deck aggregate inference | Removed rank/suit maps from both reader and normalized schema. Only the visible total survives; hidden-card plus deck-map fixtures assert omission. Future preview support requires a defined population, unknown bucket and wheel-flipped semantics. |
| M2 — contradictory PvP visibility | Engine blind key and PvP flag now constrain masking; missing/unknown engine evidence masks. The PvP phase cannot be overridden by a false view flag. Astra additionally reproduced a Lua-truthiness mismatch (`pvp=0`); it is fixed, with number/string/table/function cases and no callback invocation. |
| M3 — stale/ABA reuse | Exact token identity is followed immediately by consumption, before structural checks or callbacks. Failed submits cannot be retried. Epoch is explicitly a trusted monotonically increasing revision on every decision-relevant change, including A→B→A; new sessions require new brokers. Tests cover observed and unseen ABA, failed retries and a deliberately dishonest constant-revision fixture. Unobserved ABA cannot be detected if the trusted revision producer lies. |
| M4 — wrong booster states | All five real `*_PACK` names plus `SMODS_BOOSTER_OPENED` are resolved by symbol. Tests reject old short aliases and use non-default enum values. Astra confirmed installed Steamodded's `lovely/booster.toml` assignment and declaration read-only; no magic state numbers are used. |
| M5 — separate shop packs | Added `shop.boosters`, backed by `G.shop_booster.cards`, with `shop_booster:N` references. OPEN_BOOSTER only addresses that zone. Packs inside ordinary shop items are rejected. Reader/observation/action fixtures cover the complete path. |
| M6 — vacuous test calls | Corrected dot-style API calls and asserted expected malformed-input codes with positive controls. The original 1,040 reported iterations included 400 ineffective iterations; all 1,040 now exercise their intended inputs. |
| M7 — inadequate property oracle | Added a separately implemented expected-candidate predicate and exact set equality, covering resources, credit/free/voucher rules, capacity, counts and source/target bounds. Astra's independent in-memory mutants remove affordability, capacity or hands-remaining checks: all three are caught on both runtimes. |
| M8 — nondiscriminating memory test | A finite 16 MiB construction must succeed and a finite 128 MiB construction must fail under the 64 MiB Lua VM cap. Both controls pass on Lua 5.1 and LuaJIT under the external 10-second deadline. The cap applies to the Lua VM, not total Python/process memory. |
| L1 | `rep` rejects excessive/nonfinite/fractional counts even for empty strings; empty results return immediately. Direct and method routes tested. |
| L2 | `tostring` accepts primitives only. `pairs`/`next` order remains explicitly unspecified; no claim of deterministic arbitrary policy code is made. Observation/action serialization remains deterministic. |
| L3 | Empty targeted use requires the active bound source and a zero minimum target count. |
| L4 | Silent action truncation replaced by an explicit overflow error; the ordinary 128-certificate invariant makes overflow unreachable. |
| L5 | Documentation accurately states unknown certificate keys are ignored without traversal. |
| L6 | Action error-code tables are copied outward from private constants. |
| L7 | Fixture execution requires `M2_FIXTURE_ONLY`, not a boolean. The helper refuses game-like globals. Astra found the initial tripwire happened after module-load JIT mutation; fixed so JIT, string metatable and debug hook remain untouched when loaded in a game-like test environment. |
| L8 | The helper independently enforces the 64 KiB source cap. |
| I1 | Python globals and `package.loaded.python` are cleared; hardening failures fail closed. |
| I2 | A real escaping fault exercises the broker's outer guard and recovery, beyond the earlier static check. |
| I3 | Reader tests instrument `rawget` on tracked engine objects; a positive control proves detection and actual capture reads no forbidden fields. Astra's original metamethod probe remains a perturbation test, not a zero-read proof. |
| I4 | Oversized/invalid observations may fail as a whole. Accepted fail-closed availability limitation; no partial unsafe fallback. |
| I5 | Multiple simultaneous invalid fields may yield different bounded error codes across runtimes. Accepted diagnostic limitation; valid canonical data/actions are deterministic. |
| I6 | UI identity/provenance and target-to-engine mapping remain trusted integration obligations. Real producer and executor are unwired; no live correctness claim. |

## Independent verification after fixes

| Suite | Unique cases | Executions |
|---|---:|---:|
| Pure modules | 96 | 188 |
| Reader | 61 | 122 |
| Broker/worker | 123 | 219 |
| Astra boundary attacks | 18 | 36 |
| Astra oracle mutation checks | 3 | 6 |
| **M2** | **301** | **571** |
| M1 regression | 66 | 117 |
| **Combined** | **367** | **688** |

All pass. The 1,040 genuine property iterations are additional loop iterations, not added to named-case totals. Worker tests include 41 logical cases / 78 subprocess executions. Reproduction commands are in README.md and the developer guide. Astra evidence logs are workspace scratch artifacts; no proprietary sources, credentials or live files are included in Git.

The remaining C-library wall-time limitation is accepted only for this inert, test-invoked M2 capability proof, with the discriminating memory controls and required external deadline. Production process watchdog/isolation remains a hard launcher gate. No real game executor or policy was enabled.

## Post-acceptance hardening

N1: formatter arguments must be strings/numbers, and conversions use a conservative Lua 5.1 allowlist. Table/function coercions and LuaJIT pointer conversions are rejected through direct and method routes. Positive primitive/escaped-percent controls and negative pointer/width/object cases pass on both runtimes. N2: Astra's tripwire probe now supplies the actual module sources instead of empty strings; the rejection is no longer vacuous. Final boundary evidence: 123 unique / 219 executions; Astra probes 18 / 36.

Final disposition: Claude's targeted confirmation returned ACCEPT and closed N1/N2. Its two non-blocking Info notes are retained: unsupported `*` formatting fails natively with a bounded error, and format output size is checked after allocation inside the capped VM. The external deadline and future production watchdog gate remain unchanged.
