# Playable build and V1 acceptance

## Current evidence — September 30, 2026

The project is playable. The user completed a real match in session
`s-f6805722616c9375446bb20a` and described it as "pretty good". The host recorded
`phase=completed`, `code=practice_host_ok`, `session_passed` and
`changed_roots=[]`. The reported missing enemy Jokers on the end screen has a
repository fix, but that fix is not yet live-validated.

The installed companion remains **`9f7a8e1`, version `0.1.0-dev`**, with package
digest `1f6e2a6b6dc7b921a6b22975163129df7189187c1ec8cf6fe4f9f66c2d607c8b`.
Its original seven-phase certificate is `b48b5a0b…`; the host/launcher exit fix
later reissued it as `c19c6dfc…`. Recovery in this local session independently
compared all 27 installed files with the package manifest and install receipt:
every file matched. `NATIVE_TEST_PROGRESS.md` retains the chronological receipts,
earlier failures, corrections and full-match evidence.

The newer feature branch contains additional policy, runtime and targeted Tarot
changes. **Installed evidence does not certify the newer feature branch.** Phase A
implementation checkpoint `93147b7` closes the reported Psychic, empty-shop Tarot
sale and whitespace-test cases; targeted Tarot finalization and final review are
in progress. See `LOCAL_PROGRESS.md` for the current checkpoint and test results.

## Acceptance matrix

| Requirement | Established evidence | Current-build remaining gate |
|---|---|---|
| Mod load, profile and normal single-player entry | Installed build booted; full human practice match completed | Fresh live smoke after reviewed installation; verify profile and normal entry |
| Multiplayer 0.5.5, Handy and JokerDisplay | Present in established live environment; runtime integration and pinned-source contracts exist | Current-build boot and practice compatibility; ordinary human Multiplayer remains a human acceptance check |
| AI Sparring, handoff, lobby and ready/start | User exercised live menu, live exit and both staged roles | Current-build UI smoke, all four difficulty labels, timings and clean handoff |
| Independent AI actions and public opponent HUD | Full user match and unchanged-live session verdict | Current-build narrowly scoped native smoke; later user playtest |
| Lives, PvP and match completion | Full user match completed; real local-server protocol tests cover result orientations | Current-build PvP wait/timer and end-screen enemy Jokers (LV-1, LV-2, LV-6) |
| Fair observation, legal validation and stale-action handling | Reviewed architecture; boundary, property, broker and runtime suites | Fresh final review and complete supported regression run for the actual final diff |
| Strong-tier Psychic behavior and useful Tarot retention | Independent pre-fix failures; Phase A corrected reproduction and immutable-snapshot checks on both runtimes | Expanded engine-shaped regressions, full suite and Claude acceptance |
| Targeted Tarots | WIP adapter/broker/executor pipeline and fixture coverage | Finalization, actual final-diff review, then ten-center live validation and cleanup checks |
| Determinism, bounded search and source size | Both runtimes and prior H1 evidence; original 2M limit retained | Final 8–12 card, 5/8 Joker, held-Tarot stress, source-byte measurement and benchmarks |
| Recovery, disconnects and shutdown | Reviewed host/launcher safety and native ownership contracts | Current native certification, smoke cleanup, and exact open local-queue checks |
| No save/live-install mutation during isolated practice | Prior seven phases and full-match `changed_roots=[]` verdict | Fresh seven phases for changed companion bytes; no old-certificate reuse |
| Safe install, uninstall and rollback | Existing reviewed installer and original installation receipts | Fresh verified backups, current accepted package/certificate binding, exact upgrade receipt and independent live hashes |

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
