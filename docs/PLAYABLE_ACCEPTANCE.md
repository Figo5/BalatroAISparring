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
| Claude safety/playability verdict | Prior Critical/High findings repaired in code; required actual-diff re-reviews pending usage reset |
| Installed build ready for user | Pending review, backups, actual isolation gates and controlled live smoke |

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
| Engine adapter/executor | 102 / 189 |
| Menu/controller | 49 / 84 |
| Runtime coordinator | 95 / 162 |
| Companion root | 101 / 172 after window-identification checks |
| Real runtime bootstrap to practice service | 3 contracts on each runtime / 6 |

The original integrated batch totaled **1,563 executions**, plus 1,040 property iterations. The subsequent companion window checks add nine executions, bringing these suite results to **1,572 executions**. Additional independent attacks: M2 18/36, mutation 3/6, production adapter 11/22. All passed. Counts describe captured runs, not real-engine acceptance.

Other independently rerun suites: launcher 46/46, measured lifecycle 8/8, practice service 48/48, staging 45/45, reusable certificate 28/28, installer 27/27, independent certificate attacks 2/2. Final host 54/54, server packaging 8/8 and ruleset parser 8/8 checks also pass. Runtime dependency preflight passes in a fresh local-venv process.

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

The last attempted Claude re-review returned a session-limit response with reset at **10:30 p.m. America/New_York, September 27, 2026**. That response is not a review verdict. No acceptance or installation is inferred.

Raw logs, sources, dependencies, proprietary runtime files and staging remain ignored. No live Balatro files have been modified.
