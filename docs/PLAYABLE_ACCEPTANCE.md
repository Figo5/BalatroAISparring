# Playable build and V1 acceptance

## Current evidence — October 1, 2026

The installed companion is **`da66f0c`, `exact27` files**, package digest
`96ebad3787381324d9685a55b262268d019e8a68ec7c44c6f40d2038537b0614`, certificate
`694392aa14891518293635185478ff1dcbe8dd280d7f32c546023c93b9a15c98`, preserved in
the frozen root `BalatroAISparring-runtime-v1`. The reviewed/certified/backed-up
scoped upgrade succeeded. Its actual live UI smoke is **partial**: normal
startup, profile `gio`, single-player setup and the mod set (Multiplayer 0.5.5,
Handy 2.0.6, JokerDisplay 2.0.4, AISparring 0.1.0-dev) passed, but **the AI
Sparring Play entry was absent on three checks with a matching host; the cause is
unconfirmed and Phase G is not passed.**

The earlier full human match (session `s-f6805722616c9375446bb20a`,
`phase=completed`, `changed_roots=[]`) belongs **only to the earlier `9f7a8e1`
build**; it does not certify the current candidate. The current menu-diagnostic
source candidate was accepted at repository level by Claude Opus 5.5 High
(`2eda7…`) subject to the now-complete full62 run; the fresh H1 sweep's 10 actual
loaded source files are byte-identical. There is **no current-candidate native
certification, package, install, live UI pass or readiness**. Human checks still
pending: the ten Tarots on screen (effects and highlight cleanup), ordinary human
Multiplayer compatibility, end-screen enemy Jokers, and a full new match. See
`LOCAL_PROGRESS.md` and `LOCAL_VALIDATION_QUEUE.md` for exact evidence.

## Acceptance matrix

| Requirement | Established evidence | Current-build remaining gate |
|---|---|---|
| Mod load, profile and normal single-player entry | Current installed `da66f0c` booted through normal startup, profile `gio` and single-player setup | AI Play entry present; fresh live smoke after the reviewed installation |
| Multiplayer 0.5.5, Handy and JokerDisplay | Present and loaded in the current live environment; runtime integration and pinned-source contracts exist | Ordinary human Multiplayer remains a pending human acceptance check |
| AI Sparring, handoff, lobby and ready/start | Current source candidate repository-accepted; read-only isolated builder/overlay counterprobe only | Actual installed-game UI smoke: entry (host up/down), all four difficulties, timings and clean handoff |
| Independent AI actions and public opponent HUD | Earlier `9f7a8e1` full user match and unchanged-live session verdict | Current-build narrowly scoped native smoke; later user playtest |
| Lives, PvP and match completion | Real local-server protocol tests cover result orientations | Current-build PvP wait/timer and end-screen enemy Jokers (LV-1, LV-2, LV-6) |
| Fair observation, legal validation and stale-action handling | Reviewed architecture; current boundary, property, broker and runtime suites pass | Fresh final-diff review; actual smoke after installation |
| Strong-tier Psychic behavior and useful Tarot retention | Pre-fix failures and expanded engine-shaped regressions pass on both runtimes, including the real adapter sale/buy cycle | Claude acceptance and relevant live boss/Tarot checks |
| Targeted Tarots | Adapter/broker/executor and real production logger fixture path pass; repository acceptance under prior Claude | Ten-center on-screen effects and highlight-cleanup still pending |
| Determinism, bounded search and source size | Full62 now complete on this candidate, four cross-runtime benchmark pairs identical; fresh H1 1,800/1,800 per runtime, digest `6920e8b4…`, peaks 1.256M/1.263M under unchanged 2M; maximum source 56,681 bytes / guard 57,344 / hard 65,536 | Current-build native large-hand observation; no fixture claim of AI strength |
| Recovery, disconnects and shutdown | Reviewed host/launcher safety and native ownership contracts | Current native certification, smoke cleanup, and exact open local-queue checks |
| No save/live-install mutation during isolated practice | Prior seven phases and earlier full-match `changed_roots=[]` verdict | Fresh seven phases for changed companion bytes; no old-certificate reuse |
| Safe install, uninstall and rollback | Reviewed installer and current upgrade receipts | Fresh verified backups, current accepted package/certificate binding, exact upgrade receipt and independent live hashes |

## Required release sequence

1. Finish a coherent feature batch through DeepSeek implementation, Astra
   verification, Claude Opus 5.5 High review, fixes and relevant re-review.
2. Pass every locally supported suite on Windows and both Lua runtimes. Preserve
   source guard and 2M budget; record independent performance evidence.
3. With the user's game closed, run one fresh consolidated seven-phase native
   certification against the exact reviewed package. Preserve failed evidence;
   never weaken the gates or mutate already-measured staged files.
4. Perform final pre-install review, fresh verified backups and the exact scoped
   companion upgrade described in `LOCAL_RELEASE_PROCESS.md`. Other Mods and saves
   remain intact. Record and independently check installation evidence.
5. Run the actual local UI smoke, leave the certified build ready for the user,
   and maintain exact human/native checks in `LOCAL_VALIDATION_QUEUE.md`.
6. Continue independent development on the feature branch while that installed
   build remains stable. Later changes require their own meaningful review and
   certification batch before installation.

## V1 release candidate standard

V1 requires the current reviewed/certified/installed build to pass normal startup,
normal single-player, real human Multiplayer compatibility, Handy/JokerDisplay
compatibility, all four difficulties, reasonable handoff, complete matches,
correct PvP/lives/results, targeted Tarots, reliable boss behavior and recovery.
No unresolved Critical/High or relevant Medium finding may remain. Both Lua
runtimes, determinism, performance and native isolation must pass. Documentation
must describe the actual implementation and scoped uninstall/rollback.

Repository fixtures, socket tests and isolation certification each prove their
own contracts. They do not substitute for on-screen Tarot effects, ordinary human
Multiplayer compatibility or a current-build full match. Pending human checks do
not halt unrelated safe repository development. No merge to `main` occurs until
the project meets the V1 standard.
