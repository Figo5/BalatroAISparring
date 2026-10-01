# Independent local regression verification

Fresh Astra verification after the findings from Claude's `7f2aced` review. Tested code checkpoint: `eb39c6262a2a8dbbee9a2982c68cf9e23aa5e8d2`.

**All 62 locally supported entrypoints passed on Windows.** The 312 tracked source/doc/test files were hash-recorded before execution and unchanged through the full run. Lua 5.1 and LuaJIT both ran through lupa 2.8 / Python 3.12. The original main staged diff and old installed build remain separate protected state.

## Supported coverage

| Entry point | Result |
|---|---|
| `run.py` | PASS — runtime luajit21: 51/51 passed; unique cases: 66; total executions: 117; RESULT: PASS |
| `run_boundary.py` | PASS — worker subprocess cases: 78/78 passed; unique cases: 123; total executions: 219; RESULT: PASS |
| `run_companion.py` | PASS — runtime luajit21: 86/86 passed; unique cases: 116; total executions: 202; RESULT: PASS |
| `run_decision.py` | PASS — runtime luajit21: 84/84 passed; unique cases: 108; total executions: 192; RESULT: PASS |
| `run_engine.py` | PASS — runtime luajit21: 176/176 passed; unique cases: 192; total executions: 368; RESULT: PASS |
| `run_m2.py` | PASS — total case executions: 190; property iterations: 1040; runtimes available: 2; RESULT: PASS |
| `run_menu.py` | PASS — unique cases: 50; total case executions: 86; runtimes available: 2; RESULT: PASS |
| `run_policy.py` | PASS — unique cases: 199; total executions: 389; runtimes available: 2; RESULT: PASS |
| `run_reader.py` | PASS — runtime luajit21: 62/62 passed; unique cases: 62; total executions: 124; RESULT: PASS |
| `run_runtime.py` | PASS — runtime luajit21: 123/123 passed; unique cases: 157; total executions: 280; RESULT: PASS |
| `test_install_companion.py` | PASS — ok   test_verify_package_refuses_live_staged_body_divergence; ok   test_verify_package_refuses_malformed_manifest; 48/48 cases passed |
| `test_isolation_certificate.py` | PASS — ok   test_verdict_requires_backup_and_refuses_reuse; ok   test_verdict_requires_retained_session_and_closed_live_game; 65/65 cases passed |
| `test_launcher_safety.py` | PASS — ok   test_verify_backup_entry_rejects_arbitrary_paths_and_inside_manifests; ok   test_write_session_refuses_overwrite; 64/64 cases passed |
| `test_match_history.py` | PASS — ok   test_review_counts_phases_actions_latency_and_rejections; ok   test_review_reports_ui_facts_for_lv7; 7/7 cases passed |
| `test_measurement_lifecycle.py` | PASS — ok   test_r3_supervisor_interrupt_records_failure_and_lockout; ok   test_record_receipt_refuses_running_owned_processes; 11/11 cases passed |
| `test_native_certification_runner.py` | PASS — ok   test_upgrade_requires_a_matching_native_report; ok   test_wrong_head_is_refused; 15/15 cases passed |
| `test_p2_observer.py` | PASS — ok   lua51 reconnect branch is observed from the real branch; ok   luajit21 reconnect branch is observed from the real branch; 6/6 cases passed |
| `test_policy_estimator_parity.py` | PASS — ok   test_reference_pins; ok   test_policy_matches_reference_on_edge_hands; 2/2 cases passed |
| `test_practice_host.py` | PASS — ok   test_wait_for_live_exit_timeout_never_terminates; ok   test_windows_tcp_table_probe_reports_per_family_inventory_status; 126/126 cases passed |
| `test_practice_service.py` | PASS — ok   test_worker_failure_propagates_to_both_roles; ok   test_worker_timeout_real_runner_terminates_child; 63/63 cases passed |
| `test_prepare_server.py` | PASS — ok   test_prepare_refuses_untracked_upstream_source; ok   test_prepare_refuses_wrong_pin; 8/8 cases passed |
| `test_ruleset_contract.py` | PASS — ok   test_unresolved_multiplayer_mod_is_refused; ok   test_unsupported_statement_is_refused; 8/8 cases passed |
| `test_runtime_cross_service.py` | PASS — PASS luajit21::wire_transport_drives_practice_service; PASS luajit21::two_bootstrap_coordinators_reach_start; PASS luajit21::empty_object_encoding_root; RESULT: PASS |
| `test_staging.py` | PASS — ok   test_verify_staged_role_roundtrip_and_tamper; ok   test_write_helpers_use_safe_writes; 52/52 cases passed |
| `test_upgrade_reviewed_companion.py` | PASS — {"ok": true, "execute": true, "source_commit": "fixture-tip", "target": "C:\\Users\\ginom\\AppData\\Local\\Temp\\aisparring-upgrade-portable-8j744pkq\\fake-live\\appdata\\Mods\\AISparring", "package_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "certificate_id": "cert", "old_files": 1}; ok   scenario:closed-before-snapshot; ok   old-package-pin-proof; 19/19 cases passed |

All remaining adversarial/source/native-contract fixture entrypoints, `benchmark_m2.py`, and the original upstream Node server contracts also pass. These tests use owned harmless helpers and loopback sockets; this suite launches no Balatro game and certifies no actual session.

## Findings and independent controls

- Psychic: authoritative five-card/discard behavior across rule-changing Jokers and unusual cards; narrow certified zero-score escape for the exhausted 1–4-card terminal only. Incomplete catalogues at five or more cards still fail closed.
- Shop: useful Tarot retention, equal-score higher-worth purchases, LEAVE_SHOP-first permutations, no sale/rebuy/sale cycle, price/interest breakpoints, Negative purchases, reserve and safety floor. Sale proceeds are absent from the sanitized held-card observation, so uncertain post-sale price competition conservatively retains a useful Tarot.
- Tarot: own visible targets, counts/allowlist, broker and executor stale/forged/forced-card checks, dispatch-time production logger and a queued-cleanup fixture. `exec_ok` plus `highlight=kept` is not a settled-cleanup claim.
- Host: active/assigned worker stop deferral, locked stop intent refusing new tickets, retained closure/human ownership, polling/acknowledgement and restart.
- Release tools: tracked and import-inert; exact clean reviewed HEAD, canonical source blobs versus physical Windows package bytes, root-config-only exclusion, binary/nested controls, preserved failed attempts, final original-package pin and native report binding.
- Upgrade: permanent fake-root rollback/interruption/pinned-old-package tests preserve unrelated Mods/saves, original exceptions and partial targets. None establishes a real upgrade pass.

Separate Astra controls preserve the pre-fix Psychic and shop traces; current 60 residual cases/runtime pass, plus 360 nearby-price/cash shop cases/runtime. The fresh-checkout control copies only tracked/intended files and runs both release-tool suites without ignored implementation dependencies. Raw evidence is under `work/local-ownership/`; see `portable-release-test-proof.json`, `astra-price-grid-final-fixed.json` and the current residual/source-binding reports.

Baseline and hard benchmarks each use 300 scenarios/runtime; blind simulations use 120 blinds/runtime and run simulations use 30 runs/runtime. Every gate passes and non-timing/non-instruction metrics agree between runtimes. They use a shared reference scorer and establish regression behavior, not native win rate or independent optimality.

The separate immutable H1 sweep covers 3,600 decisions, with no budget failures or nondeterministic repeats. Peak 1,263,000 instructions under the unchanged 2M budget; largest rendered policy 56,392 bytes. See `LOCAL_H1_VERIFICATION.md`.

## Evidence and next gates

`work/local-ownership/final-reregression/summary.json` records every exit status; `source-before.json` and `source-binding.json` bind the run to unchanged code. Any later documentation-only recording is distinguished from the tested executable files. Older 60-entrypoint evidence remains preserved in `full-suite/` and Git history.

Final Claude source re-review, fresh seven-phase native certification, package-bound pre-install review, verified backups, scoped upgrade and actual live smoke are still required. Installed `9f7a8e1` and its old certificates are not evidence for these newer bytes.
