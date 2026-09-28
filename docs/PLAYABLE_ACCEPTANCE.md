# Playable build acceptance evidence

Status: **in development, not installed, not yet playable**. Fixture and local-server evidence do not satisfy the user's actual Balatro acceptance criteria.

| Requirement | Evidence and remaining gate |
|---|---|
| Actual mod load; normal Balatro, single-player, Multiplayer, Handy and JokerDisplay | Live copies untouched; actual-engine checks pending |
| Menu, Major League, three difficulties, five Gauntlets, pacing and match start | UI/controller, runtime/service fixtures pass; actual menu/start pending |
| Human control and independent AI run | Reviewed two-runtime architecture retained; native Balatro isolation proof pending |
| Blinds, hands, discards, shops, purchases, rerolls, round progression | Baseline and production adapter implemented; fixtures pass; actual action traces pending |
| Observation, legal validation, stale state, hidden information | M1/M2 and production regression checks pass; repaired Claude findings require re-review |
| Public opponent HUD | Original Multiplayer presentation/privacy retained; rendering pending |
| Lives, PvP/Nemesis, both result orientations, completion | Original server handlers and real local TCP lifecycle pass; complete engine lifecycle pending |
| Failure recovery, local decisions and match summaries | Service/runtime fixtures pass; controlled engine failure check pending |
| Claude safety/playability verdict | Significant repairs are implemented; isolation evidence follow-up and actual-diff re-reviews remain pending |
| Installed build ready for user | Pending review, backups, actual isolation gates and controlled live smoke |

## September 28 review update — repairs awaiting re-review

Claude reviewed commit `bbf61bf` with Opus 5.5 High. Policy/broker/loop was approved for controlled staged testing. Engine, runtime/UI, isolation and installer reviews found concrete blockers; DeepSeek implemented repairs; final source-observer verification and Claude re-review remain required. See `CLAUDE_POLICY_FINAL_REVIEW.md`, `CLAUDE_ENGINE_FINAL_REVIEW.md`, `CLAUDE_RUNTIME_FINAL_REVIEW.md`, `CLAUDE_ISOLATION_FINAL_REVIEW.md` and `CLAUDE_INSTALLER_FINAL_REVIEW.md`.

New independent checks reproduce incorrect SMODS empty-pack skipping, full-slot pack Ankh selection, successful reporting of a reverted reorder, rejection of a real Object-shaped G, failure to recognize the real RUN stage, failure to invoke metatable-proxied ruleset methods, and backup/session evidence binding failures. The reproduced defects are repaired and the independent regression checks below pass. Those results do not replace required Claude re-review or native game evidence.

The host/service review stopped at API 429 without a verdict. The client reports a **5:00 a.m. Eastern, September 28** reset. That review and targeted re-reviews of significant fixes remain required. No actual-game measurements, live staging, backups or installation have occurred.

Repair verification after commits `03a4442`, `7bd38eb` and `83bb4fd`: engine 207 executions, installer 40 cases, runtime 190 executions, menu 86, companion 178, cross-service 6, independent runtime contracts 22, production adapter attacks 28. All pass. The preserved M1 (117), M2 (188 plus 1,040 properties), reader (122), boundary (219), policy (149) and decision-loop (164) suites also pass on the repaired tree. Python host repair checks pass 60/60; launcher 50/50, staging 46/46 and measurement lifecycle 11/11 pass. Certificate validation passes 42/42 and installer checks pass 40/40 on the observer repair tree. These are repository/synthetic tests, not native Balatro measurements.

Independent backup/session checks pass 3/3 and actual Python attestation writer to both Lua readers passes 8/8 with synthetic files. A separate negative check found that a P2 startup marker/attempt counter incorrectly counted as an observed Multiplayer initial connection failure. The classifier repair passes that check by requiring an explicit observed failure, and the env-gated source observer is now implemented: it is injected into the real staged network thread (`networking/socket.lua`, after the exact `connect` call) and emits one exact schema; the classifier reads only those fields and refuses start markers, refused probes and hypothetical flags. The observer, patch application to the pinned source and the covered/pending mapping are verified synthetically under both lupa runtimes (`tests/test_p2_observer.py`), including env-gate-off trace equivalence. Astra independently ran the corrected five source-observer cases on both Lua runtimes (10 executions), all passing: unchanged producer output classification, post-connect emission, gate-off trace comparison, original reconnect loop and original keepalive-expiry branch. The three independent negative coverage checks also pass. Native reconnect/keepalive coverage remains pending: a dead port cannot reach those branches, and the required controlled local stimulus (a listener that accepts then closes; a connected listener that stops answering keepalive) has not been run. That pending coverage prevents certificate acceptance. The native P2 proposal also records an unresolved classifier distinction between exhausted retries and recovery after a failed attempt; Claude must resolve that evidence definition before acceptance. Measurement exception coverage subsequently reached 11/11 passing cases. Do not treat the green fixture suites below as native evidence.

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

Other independently rerun suites: launcher 50/50, measured lifecycle 11/11, host 60/60, staging 46/46, reusable certificate 42/42, installer 40/40, independent certificate attacks 2/2, backup binding 3/3 and Python-to-Lua attestation contracts 8/8. Three independent P2 negative checks reject startup markers, a successful initial connection followed by failed retries, and incomplete reconnect cycles as evidence for paths they did not execute. Server packaging 8/8 and ruleset parser 8/8 checks remain passing captured results. Runtime dependency preflight passes in a fresh local-venv process.

Cross-module adapter-to-real-policy-worker checks passed for all three difficulties on both runtimes (six checks, 88 legal hand candidates). Choices passed executor validation; observed process-inclusive latency was 0.17–0.22 seconds. These are engine-shaped fixtures, not actual Balatro play.

## Native and actual-source checks

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
2. Claude re-review of repaired production executor, policy/broker, runtime/companion, host/service, isolation/launcher and installer. No unresolved safety/playability Critical or High finding may remain.
3. Once reviews pass, check whether the user's Balatro is closed. If open, request closure only then; never terminate it.
4. Fresh verified backups, staged-only P1A/P1B/FULL_P1/CRASH/P2 measurements and zero live/save/Steam changes. No actual runtime staging, backups or launches have been performed yet.
5. Controlled actual-engine actions, timer continuity, minimized AI progress, public HUD, results/failure recovery, followed by safe companion installation and normal-mod compatibility checks. Do not play an entire human run.
6. Record exact installed path, commit, launcher and log directory and leave the user able to start playtesting. Only then declare playable and stop development.

The latest attempted host/service review returned a session-limit response with reset at **5:00 a.m. America/New_York, September 28, 2026**. That response is not a review verdict. No acceptance or installation is inferred.

Raw logs, sources, dependencies, proprietary runtime files and staging remain ignored. No live Balatro files have been modified.
