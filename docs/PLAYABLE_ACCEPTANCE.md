# Playable build acceptance evidence

Status: **in development, not installed, not yet playable**. Fixture and local-server evidence do not satisfy the user's actual Balatro acceptance criteria.

| Requirement | Evidence and remaining gate |
|---|---|
| Actual mod load; normal Balatro, single-player, Multiplayer, Handy and JokerDisplay | Live copies untouched; actual-engine checks pending |
| Menu, Major League, three difficulties, five Gauntlets, pacing and match start | UI/controller, runtime/service fixtures pass; actual menu/start pending |
| Human control and independent AI run | Reviewed two-runtime architecture retained; native Balatro isolation proof pending |
| Blinds, hands, discards, shops, purchases, rerolls, round progression | Baseline and production adapter implemented; fixtures pass; actual action traces pending |
| Observation, legal validation, stale state, hidden information | M1/M2 and production regression checks pass; runtime/engine/policy repairs reviewed |
| Public opponent HUD | Original Multiplayer presentation/privacy retained; rendering pending |
| Lives, PvP/Nemesis, both result orientations, completion | Original server handlers and real local TCP lifecycle pass; complete engine lifecycle pending |
| Failure recovery, local decisions and match summaries | Service/runtime fixtures pass; controlled engine failure check pending |
| Claude safety/playability verdict | Runtime/engine, installer, host/service and isolation code scopes accepted for staged tests; gameplay verdict pending |
| Installed build ready for user | Pending review, backups, actual isolation gates and controlled live smoke |

## Current review status — September 28

Runtime/engine/policy repairs are approved for controlled staged testing (`CLAUDE_RUNTIME_ENGINE_REREVIEW.md`). Installer repairs are approved in scope (`CLAUDE_INSTALLER_SECOND_REREVIEW.md`). Neither verdict establishes native gameplay or installation readiness by itself.

Host/service repair `4516e60` is accepted by Claude (`CLAUDE_HOST_FIFTH_REREVIEW.md`) and Astra after independent 87/87 host tests plus the retained-ownership negative. Service tests (55/55), independent service contracts (5/5) and Lua-to-service checks (6/6) remain unchanged passing results. The theoretical non-blocking Low is recorded in the review and does not delay this gate.

Isolation commit `fddea7e` corrects the reviewed F1–F4 and adjacent F5–F11 findings: source-faithful expiry EOF, separate connect/sleep timing, copied listener evidence validation and post-exit dead-port proof. Astra's independent checks pass, including certificate 50/50, launcher 61/61, shared host 87/87 and installer 48/48. Real non-game Windows socket checks also pass. See `ISOLATION_SOURCE_CORRECTIONS_VERIFICATION.md`. Claude closed F1–F4 and confirmed all seven phases may proceed under the existing conditions (`CLAUDE_ISOLATION_SOURCE_REREVIEW.md`). Astra accepts this code scope for controlled staged testing. The earlier single-session P2 proposal is superseded by `P2_MEASUREMENT_PROPOSAL.md`.

The review records three non-blocking Low limitations: overlapping marker-name substring checks, possible cross-clock skew on the CLOSE ordering check, and post-exit proof freshness guaranteed by call placement rather than an explicit timestamp comparison. These remain documented without expanding the infrastructure scope. Coverage still fails closed. If a real phase exposes a limitation, preserve its evidence and make a focused repair through the established review cycle; do not bypass the gate.

No actual Balatro runtime copies, backups, launches, installation or live-file changes have occurred. Native game measurements and playability remain unproven.

A read-only process check on September 28 evening found the user's live Steam Balatro running. Staging and native game integration remain deferred while it is open; no process was interrupted.

Read-only normal-Multiplayer compatibility inspection: the pinned `networking/action_handlers.lua` lobby-info path sets readiness from guest presence/readiness; `ui/lobby/start_ready_button.lua` does not impose a blanket equality check on all mod hashes. The live companion remains visible in the ordinary mod list, with no suppression or bypass. Actual normal-human compatibility is still an in-game acceptance gate.

## Independent repository verification

Latest integrated regression batch uses repository-local Python 3.12.14 with pinned lupa 2.8, without transient PYTHONPATH. Both Lua 5.1 and LuaJIT remain covered.

| Suite | Cases / executions or result |
|---|---|
| M1 | 66 / 117 |
| M2 pure | 96 / 188, plus 1,040 property iterations |
| State reader | 61 / 122 |
| Privacy/process boundary | 123 / 219 |
| Baseline policy | 79 / 149 |
| Decision loop/broker | 94 / 164 |
| Engine adapter/executor | 111 / 207 |
| Menu/controller | 50 / 86 |
| Runtime coordinator | 112 / 190 |
| Companion root | 104 / 178 |
| Real runtime bootstrap to practice service | 3 contracts on each runtime / 6 |

The repaired integrated batch totals **1,626 executions**, plus 1,040 property iterations. Additional independent checks pass: M2 attacks 18/36, mutation 3/6, production adapter attacks 14/28 and runtime contracts 11/22. These counts describe repository tests, not real-engine acceptance.

Latest independently rerun infrastructure suites: launcher 59/59, measured lifecycle 11/11, staging 48/48, reusable certificate 46/46, installer 48/48, backup binding 3/3 and Python-to-Lua attestation 8/8. Ten independent measurement negatives reject missing ownership, failed FIN, missing/early connection hold, reversed peer endpoint, unreadable process handles and unsupported coverage claims. Source-observer tests pass on both Lua runtimes (six reported cases). Host 87/87 now passes for the accepted `4516e60` repair. Isolation counts above describe `9c698ae`; verification of the subsequent F1–F4 correction is still pending. Server packaging 8/8 and ruleset parser 8/8 remain unchanged passing captured results.

Cross-module adapter-to-real-policy-worker checks passed for all three difficulties on both runtimes (six checks, 88 legal hand candidates). Choices passed executor validation; observed process-inclusive latency was 0.17–0.22 seconds. These are engine-shaped fixtures, not actual Balatro play.

## Native and actual-source checks

- The actual measurement listener passed a Windows test with a separate owned hidden Python peer: both-family inventory, exact client-side peer PID, graceful FIN, zero sent bytes and cleanup. This is OS plumbing evidence only.

- Actual Windows PID/creation-time query via LuaJIT FFI agrees with native Python verification for the test's own process. Invalid PID refused.
- One harmless owned Python helper was created suspended, assigned to a Windows Job, resumed and cleaned up through its retained identity. No Balatro process was involved.
- Actual pinned engine Object/UIBox source lookup, Channel userdata contract, callback return preservation, wire sequence, original timer protocol and guest option guards passed six independent contracts on both runtimes (12 executions).
- Native IPv4/IPv6 listener inventory exposed a Windows scalar conversion defect. DeepSeek repaired it; both native loopback checks now pass with exact owning PID and wrong-owner refusal. Partial-family inventory is rejected by strict host checks. The native PowerShell enumerator also resolves the checking process to its actual base interpreter, distinguishing the venv redirector.
- Actual locally held Major League Lua source was evaluated in restricted fixtures on both runtimes. Forced options agree with the strict Python parser and Lua/Python digest `72d9e157`.

## Real local-server evidence

Pinned upstream: `d664c29523b827d53dfa1a181e5b2baf1aefac4f`. The prepared server changes only the match listener bind to 127.0.0.1 and disables the unused admin listener. Original GPL license and patched source stay with the ignored build. The corrected preparation tool successfully compiled 11 build files, bound 816 runtime files and one native binary; the host's adaptation verifier accepted this manifest.

`tests/astra_server_contracts.mjs` imports the original compiled Client, Lobby and action handlers: 13 contracts pass, including seed paths, host-only start, ready order, life/result orientations, ties and score suppression. `tests/astra_server_tcp.py` starts that server and two synthetic TCP peers and passes create/join/start/shared-seed/ready/PvP/AI-win/human-loss through actual wire messages. OS inventory confirms only the selected loopback listener and no admin listener. The owned Node process exits during cleanup.

The TCP test intentionally uses a shortened one-life lifecycle. It does not prove Major League engine parity, rendering, AI autonomy in Balatro, or a full match played by a user.

## Remaining acceptance gates

1. Repository host/native-listener verification and window-identification fixtures are complete. Eight additional checks prove the actual Python attestation writer and Lua companion reader agree for both roles on both runtimes and reject changed nonces; all certificate files in this check are synthetic.
2. Finish and verify isolation F1–F4 corrections, then pass Claude re-review. Runtime/engine/policy, host/service and installer scope reviews are complete. No unresolved safety/playability Critical or High finding may remain.
3. Once reviews pass, check whether the user's Balatro is closed. If open, request closure only then; never terminate it.
4. Fresh verified backups, staged-only P1A/P1B/FULL_P1/CRASH/P2_INITIAL/P2_CLOSE/P2_SILENT measurements and zero live/save/Steam changes. No actual runtime staging, backups or launches have been performed yet.
5. Controlled actual-engine actions, timer continuity, minimized AI progress, public HUD, results/failure recovery, followed by safe companion installation and normal-mod compatibility checks. Do not play an entire human run.
6. Record exact installed path, commit, launcher and log directory and leave the user able to start playtesting. Only then declare playable and stop development.

The earlier session-limit response was superseded by the completed after-reset reviews above. No acceptance or installation is inferred from quota availability.

Raw logs, sources, dependencies, proprietary runtime files and staging remain ignored. No live Balatro files have been modified.

Review availability at 9:02 a.m. Eastern: Claude returned a session-limit response during the final isolation re-review, with a reported noon Eastern reset on September 28. That run supplies no verdict. The final isolation and host repair reviews remain required; implementation and independent verification can finish without native Balatro actions.

September 28 evening: host/service repair `4516e60` is accepted by Claude (`CLAUDE_HOST_FIFTH_REREVIEW.md`) and Astra after independent 87/87 host tests plus the failed-close negative. The one theoretical non-blocking Low is recorded, not expanded into more scope. Runtime/engine/policy, installer and host/service code-review gates have passed. Isolation F1–F4 source-measurement corrections remain in implementation and require verification/re-review before P2. No actual Balatro operation has occurred.
