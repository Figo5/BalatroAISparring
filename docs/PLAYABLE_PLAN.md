# Playable development slice

User authorization: 2026-09-27, following accepted M2 commit a991a9325462b766c3e369b67f276c2a842ed640. The objective is a safe, legal, functional human-versus-AI Major League development build, not another infrastructure milestone. No playability claim until actual engine acceptance evidence exists.

## Architecture and work ownership

The accepted INTEGRATION_PLAN remains authoritative: two staged real game runtimes, pinned loopback legacy Multiplayer server, separate restricted policy worker. The installed companion menu is an explicit launcher entry point; it must not redirect normal Multiplayer or share the user's live run. No alternate scorer or global-state swapping. Any necessary architectural change requires evidence and Claude review before implementation.

Astra defines contracts, inspects integration, verifies independently and accepts. DeepSeek V4.1 Flash High performs primary implementation and fixes. Claude Opus 5.5 High reviews actual diffs and evidence, with re-review of significant fixes. Work continues through internal checkpoints toward the playable objective.

## Implementation chunks

1. Observation-only bounded baseline policy, three honest difficulties, stable development gauntlet seeds, policy tests across Lua 5.1/LuaJIT.
2. Trusted real-engine visible-view/certificate producer, monotonic state revision, broker-authorized production executor, asynchronous policy orchestration, local decision/match logging and safe error recovery. UI contains no gameplay decisions.
3. Staged launcher/runtime bootstrap, separate save/Mods/log paths, disabled Steam integration and external transport, authenticated bounded local IPC, subprocess watchdog, pinned local-server adaptation and protocol/parity tests.
4. Functional AI Sparring entry/settings UI, Major League resolved from actual Multiplayer configuration, normal/gauntlet and Instant/Normal pacing, staged human ownership and original opponent HUD.
5. Independent regression/progression/failure tests; Claude review/fixes/re-review; safe staged runtime proofs and live installation/smoke test when the user's game is closed.

## Acceptance

Preserve all M1/M2 boundaries and regressions. Prove policy choices legal, stale/invalid actions rejected, independent runtime state, shop/hand/blind progression, life/PvP/win/loss/completion paths, graceful failure, deterministic seed selection, normal Multiplayer/single-player isolation and local logs. Fixtures do not replace real-engine evidence.

Before any game launch or live install, satisfy PROTOTYPE_GATES isolation prerequisites, check process image paths immediately, back up live targets and saves with hashes, and never terminate the user's game. If it is running, complete all repository/test/review work before requesting closure. Do not copy progression while it runs. Never overwrite saves. Review must have no unresolved Critical/High safety/playability findings before installation.

Completion requires the user's 34 acceptance points, including actual mod load, preserved Handy/JokerDisplay/human Multiplayer, independent AI playing the real engine, full lifecycle evidence, installed development label and playtest instructions/log locations. Stop development once ready for user playtesting; no subsequent strategy/polish phase is authorized.
