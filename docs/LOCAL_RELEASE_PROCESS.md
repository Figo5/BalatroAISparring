# Local release, upgrade and rollback process

This procedure uses the existing reviewed first-install tool. It does not add an overwrite mode, relax certificate gates, or reuse an old certificate for changed mod bytes. Current build/review/certificate/install evidence is recorded separately in `LOCAL_PROGRESS.md` and `NATIVE_TEST_PROGRESS.md`.

## Review and certification

1. Finish a coherent feature-branch batch. Run the supported Lua 5.1/LuaJIT, Python, property, determinism, source-size and benchmark gates. Capture large-hand instruction/candidate/latency measurements with the real unchanged 2M budget.
2. Obtain fresh Claude Opus 5.5 High acceptance of the actual final diff. Resolve relevant findings and re-review meaningful fixes. A quota/authentication error is no verdict.
3. Check every Balatro process. Never close or terminate a user's game to make the gate pass. If a user game is running, finish independent repository work first and wait for a safe closed-game opportunity.
4. Build a fresh package from the reviewed feature source, with its discovery path in the durable feature checkout. Preserve package digest and source commit.
5. Stage from a verified private copy of live Mods which excludes exactly the already-installed `AISparring` directory. All other mods remain byte-identical to the live source copy before the staging tool applies its existing isolated network/Steam protections. This exclusion changes only the private source copy; the live installed companion stays intact.
6. Place both verified packaged staged companion copies before any measurement receipt. Check manifest/package binding for both roles. Never rebaseline already-measured content.
7. Run one consolidated P1A, P1B, FULL_P1, CRASH, P2_INITIAL, P2_CLOSE and P2_SILENT certification, with fresh verified backups, exact intended process ownership/role counts and unchanged live-root snapshots. Failures keep their evidence and require investigation. Build/check the new certificate and recheck package binding.

## Tooling

The release orchestration is tracked, importable and inert on import:

- `tools/run_native_certification.py` — the seven-phase certification runner. It
  requires `--reviewed-commit`, refuses a wrong HEAD or any tracked/untracked
  change before packaging, after packaging and at the end, binds every packaged
  module file (excluding only the generated top-level `config.lua`) to the
  reviewed Git blobs, and refuses an existing attempt directory. At the end it
  re-verifies the package against the digest captured at packaging time (through
  the established verified-manifest pin checker), re-runs the source binding and
  re-binds the staging area to the original immutable expected roles, so a
  package swapped during the long run refuses before a certificate report is
  written.
- `tools/upgrade_reviewed_companion.py` — the upgrade orchestration. It requires
  `--reviewed-commit` and a native certificate report whose source commit,
  package digest and certificate ID equal the values this session actually
  verified.

`work/local-ownership/run_native_certification.py` and
`work/local-ownership/upgrade_reviewed_companion.py` are thin compatibility
entrypoints only. Tests and the fault harnesses load the tracked `tools` modules
directly, so injected fake globals act on the real module rather than a wrapper's
namespace.

## Upgrade from an existing installed build

The first-install tool intentionally refuses an existing target. Upgrade orchestration therefore preserves the old target outside Mods first, while retaining all of its safeguards.

1. Complete final pre-install review of the certified package and its exact receipt set.
2. With every Balatro process closed, create and verify a fresh full live backup **including the old companion and saves**. Confirm all preserved Multiplayer, Handy, JokerDisplay, Lovely and Steamodded files.
3. Verify the existing target is exactly `%APPDATA%/Balatro/Mods/AISparring`, with no links/reparse points, and record its complete file hash manifest. Archive only that directory into a fresh, checked path under this feature checkout's `backups/`. Use a native directory rename; do not delete it or change another mod. Recheck the archived tree against the recorded hashes.
4. Create a second fresh verified live backup after archival, because the first-install tool correctly requires a backup matching the now-current live Mods tree. The earlier complete backup and archived companion remain the rollback source.
5. Write an honest install-acceptance record binding reviewer, package digest and the new certificate ID. Run the existing installer dry run, then execute. Its process gate, source rehash, package/staging binding, current backup, exact target and atomic rename remain authoritative.
6. Record the old archive, both backup references, source commit, package digest, certificate ID and install receipt. Independently compare the installed companion with the verified package; compare all other Mods with the pre-upgrade manifest. Do not overwrite or restore saves.
7. Start the matching feature-checkout practice host and perform the requested native smoke test. A build is ready for playtesting only after the actual smoke evidence is recorded.

If installation refuses after the old directory was archived, retain every receipt/error and restore only that verified archived companion to the exact absent target, provided all Balatro processes are closed. Refuse rollback over an existing target or a changed archive. If the game has started meanwhile, leave the archive safely intact and require a closed-game opportunity; never terminate the user's game.

## Uninstall and rollback after installation

- Close Balatro normally first. Preserve a verified fresh backup and record the currently installed hashes.
- Uninstall by moving only the exact `Mods/AISparring` directory to a fresh verified archive outside Mods. Keep the other mods and all profiles/saves intact. Stop only the project-owned idle practice host through its established control/shutdown path.
- Restore a previously reviewed/certified companion only from a verified archive, into an absent exact target with every Balatro process closed. Use its matching host/staging/package/certificate generation; an older installed mod with a newer host discovery schema is not a complete rollback.
- Recheck installed hashes and boot compatibility after rollback. Never copy an entire AppData backup over the user's current saves to roll back a mod.

## Evidence boundaries

Native certification proves isolation and the measured phase requirements. It does not establish every Tarot's live visual effect, a full current-build human match, external human Multiplayer compatibility, or AI strength. Those checks have explicit steps and pass/fail criteria in `LOCAL_VALIDATION_QUEUE.md`. Keep repository acceptance, certification, installation and live/human playtest status distinct.
