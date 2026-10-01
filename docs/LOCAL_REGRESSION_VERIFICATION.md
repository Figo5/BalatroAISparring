# Independent local regression verification

Astra verification of the integrated September 30 feature batch. Source/code
checkpoints: `93147b7` (Psychic/churn/test), `7341727` (targeted Tarot
finalization) and `e0d5a70` (active-supervisor shutdown safeguard).

**All 60 locally supported entrypoints passed on Windows.** The tested 306
tracked or intended source/doc/test files were hash-recorded before the full
run and byte-compared afterwards: no change occurred during verification.
Lua 5.1 and LuaJIT are both available in lupa 2.8 on Python 3.12. Repository
test tools use real ignored local reference/server copies where required.

## Coverage

| Entry point | Result |
|---|---|
| `run.py` | PASS — runtime luajit21: 51/51 passed; unique cases: 66; total executions: 117; RESULT: PASS |
| `run_boundary.py` | PASS — worker subprocess cases: 78/78 passed; unique cases: 123; total executions: 219; RESULT: PASS |
| `run_companion.py` | PASS — runtime luajit21: 86/86 passed; unique cases: 116; total executions: 202; RESULT: PASS |
| `run_decision.py` | PASS — runtime luajit21: 84/84 passed; unique cases: 108; total executions: 192; RESULT: PASS |
| `run_engine.py` | PASS — runtime luajit21: 175/175 passed; unique cases: 191; total executions: 366; RESULT: PASS |
| `run_m2.py` | PASS — total case executions: 190; property iterations: 1040; runtimes available: 2; RESULT: PASS |
| `run_menu.py` | PASS — unique cases: 50; total case executions: 86; runtimes available: 2; RESULT: PASS |
| `run_policy.py` | PASS — unique cases: 187; total executions: 365; runtimes available: 2; RESULT: PASS |
| `run_reader.py` | PASS — runtime luajit21: 62/62 passed; unique cases: 62; total executions: 124; RESULT: PASS |
| `run_runtime.py` | PASS — runtime luajit21: 123/123 passed; unique cases: 157; total executions: 280; RESULT: PASS |
| `test_policy_estimator_parity.py` | PASS — ok   test_reference_pins; ok   test_policy_matches_reference_on_edge_hands; 2/2 cases passed |
| `test_practice_service.py` | PASS — ok   test_worker_failure_propagates_to_both_roles; ok   test_worker_timeout_real_runner_terminates_child; 63/63 cases passed |
| `test_practice_host.py` | PASS — ok   test_wait_for_live_exit_timeout_never_terminates; ok   test_windows_tcp_table_probe_reports_per_family_inventory_status; 123/123 cases passed |
| `test_install_companion.py` | PASS — ok   test_verify_package_refuses_live_staged_body_divergence; ok   test_verify_package_refuses_malformed_manifest; 48/48 cases passed |
| `test_isolation_certificate.py` | PASS — ok   test_verdict_requires_backup_and_refuses_reuse; ok   test_verdict_requires_retained_session_and_closed_live_game; 65/65 cases passed |
| `test_launcher_safety.py` | PASS — ok   test_verify_backup_entry_rejects_arbitrary_paths_and_inside_manifests; ok   test_write_session_refuses_overwrite; 64/64 cases passed |
| `test_match_history.py` | PASS — ok   test_review_counts_phases_actions_latency_and_rejections; ok   test_review_reports_ui_facts_for_lv7; 7/7 cases passed |
| `test_measurement_lifecycle.py` | PASS — ok   test_r3_supervisor_interrupt_records_failure_and_lockout; ok   test_record_receipt_refuses_running_owned_processes; 11/11 cases passed |
| `test_p2_observer.py` | PASS — ok   lua51 reconnect branch is observed from the real branch; ok   luajit21 reconnect branch is observed from the real branch; 6/6 cases passed |
| `test_prepare_server.py` | PASS — ok   test_prepare_refuses_untracked_upstream_source; ok   test_prepare_refuses_wrong_pin; 8/8 cases passed |
| `test_ruleset_contract.py` | PASS — ok   test_unresolved_multiplayer_mod_is_refused; ok   test_unsupported_statement_is_refused; 8/8 cases passed |
| `test_runtime_cross_service.py` | PASS — PASS luajit21::wire_transport_drives_practice_service; PASS luajit21::two_bootstrap_coordinators_reach_start; PASS luajit21::empty_object_encoding_root; RESULT: PASS |
| `test_staging.py` | PASS — ok   test_verify_staged_role_roundtrip_and_tamper; ok   test_write_helpers_use_safe_writes; 52/52 cases passed |

All remaining `astra_*.py` adversarial/source/native contract entrypoints passed,
as did `benchmark_m2.py` and 13 original upstream Node server contracts.
The native checks use only their owned harmless helpers and loopback sockets;
this regression run does not launch Balatro or certify a real game session.

## Regression and performance evidence

- Psychic: all five rule-changing Jokers, all three strong tiers, face-down
  padding in every position, hidden-identity perturbation, Stone/unknown cards,
  disabled boss, no valid five-card candidate and determinism vectors.
- Churn: retained useful Tarots, no worthwhile offer, affordable strict
  upgrade through real adapter frames, sale/buy/retention, reserve and safety
  floor, and Negative consumables without a sale.
- Targeted Tarots: exact allowlist/shape/visibility restrictions, executor
  defense in depth, forced-card/phase/forged/stale rejection and cleanup.
- Production Tarot logging regression exercises the actual logger filter.
  The initially lost fields now survive in existing bounded primitive fields.
- Separate independent policy -> production broker -> executor -> real logger
  fixtures passed 12 cases across the strong tiers and both runtimes. A stale
  target produces `broker_stale_epoch`, no callback and no execution trace.
- Host shutdown: active and assigned-but-unstarted worker cases fail before
  the fix and now defer; finished worker, retained human, pending closure and
  explicit forced fixture behavior stay covered.

Baseline and harder distribution benchmarks each run 300 scenarios on both
runtimes. Blind simulations use 120 blinds per runtime; run simulations use
30 runs per runtime. Every benchmark passes with no reported failures.
All per-difficulty non-timing/non-instruction result metrics agree across
Lua 5.1 and LuaJIT. These simulations use a shared reference scorer; they are
regression evidence, not an actual Balatro win rate or independent proof of
optimal play. No tuning was based on these results.

The separate H1 immutable-snapshot sweep covers 3,600 decisions with held
Tarots, 8–12 cards, 5/8 Jokers, PvP/nonclear and all three strong tiers.
Zero budget failures and identical cross-runtime actions; peak 1,262,000
instructions under the unchanged 2M limit. Maximum source size 54,740 bytes.
See `LOCAL_H1_VERIFICATION.md` for method, exact byte headroom, source binding
and observed Lua latency limits.

## Evidence and remaining gates

Raw outputs and all benchmark JSON are in
`work/local-ownership/full-suite/`; `summary.json` lists all 60 exit statuses.
Source hashes and final comparison are in `final-suite-source-hashes.json`
and `final-suite-source-binding.json` under the same local-ownership directory.
A separate check proves the unrelated main staged diff remains unchanged
(`c7e11dec…`). All implementation worker exports confirm exactly
`opencode-go/deepseek-v4.1-flash` with `high`; no coder was substituted.

This closes the independent supported-suite gate for these code bytes.
**Claude Opus 5.5 High acceptance remains pending its reported 9:40 p.m.
Eastern September 30 session-limit reset.** No quota error is a review verdict.
Seven-phase native certification, package-bound pre-install review, fresh
backups, scoped installation and actual smoke remain required. Installed
companion `9f7a8e1` and its prior certificates are unchanged.
