# Claude native cache correction review

Commit: cebd74e398945ecb1e5b24d5c86c323c043a1363
Reviewer: Claude Opus 5.5 High, read-only.

**Verdict: I found no blockers. The fix is ready as code. Controlled fresh staging and a full re-run of every native phase can resume under the conditions listed at the end.**

This was a read-only review. I read the scoped diff, the changed `tools/staging.py` code, `hash_tree`, `verify_manifest` and `verify_staged_role`, everything else that uses the Mods hash policy, and the pinned Lovely reference. I did not run anything, so the test counts below are the ones reported to me.

## What I checked

1. **The root cause is real.** The Lovely reference deletes both `Mods/lovely/dump` and `Mods/lovely/game-dump` at startup (`lovely-core-lib.rs:210-221`). The folder name is a lowercase literal. It then writes the unpatched copy of each loaded file to `game-dump` (`:321`) and the patched copy to `dump` (`:330`). So `game-dump` is a cache Lovely rebuilds on every run, just like `dump`. The failed receipt listed only `game-dump` paths as changed and no source files.

2. **The exclusion is exact, not a broad pattern.** Excluded paths go through `_under_any` (`staging.py:706-707`), which only matches the exact prefix or the prefix followed by `/`. So `lovely/game-dump-extra/...` and `SomeMod/game-dump/...` are still hashed. There is no match on folder names or extensions anywhere, and `exclude_dirnames` is not used.

3. **The copy step skips only one folder.** `_mods_ignore` (`staging.py:1058-1088`) skips `game-dump` only when the parent path, relative to the resolved Mods source, is exactly `lovely`. It also keeps all the existing install-copy exclusions and records the skip in the `omitted` list. The only call site changed is `stage_mods`, and `stage_install` is untouched.

4. **Nothing in the policy wiring was missed.**
   - `STAGING_POLICY`, `BOOTSTRAP_POLICY` and `MODS_HASH_POLICY` all build their exclusions from the same three names.
   - The certificate (`isolation_certificate.py:441,463`) and the host's role-parity check (`practice_host.py:1085`) pick the change up through `MODS_HASH_POLICY`.
   - No hard-coded `lovely/log` or `lovely/dump` lists remain.
   - Live snapshots, backups and live-state hashing still use the default policy (`staging.py:2903-2904`, `isolation_certificate.py:601`), so they still capture the generated folders in full.

5. **Old results do not get quietly accepted.** `verify_manifest` (`staging.py:828-831`) checks each manifest against the policy stored inside it. Manifests written before the fix will therefore still fail. Old certificates' Mods digests were also computed with the old policy, so they won't match either. You are forced to restage, which is what we want.

6. **The patched-dump evidence check is unchanged.** It still reads only from `lovely/dump` (`staging.py:2629`), and `game-dump` is never accepted as evidence.

7. **Excluding the folder is safe.** Lovely wipes `game-dump` before any Lua runs, and it only ever holds copies of the staged sources, so nothing left in it can affect a run. `lovely/dump` has been excluded on the same basis all along.

## Do the tests exercise the real failure?

Yes.
- **The real failure is reproduced.** The staged-role test starts with a stale `Handy/threads/updater` cache in the source, confirms it is left out of both the copy and the manifest, then writes the two regenerated Multiplayer files and expects verification to pass with nothing added or missing.
- **Real source changes are still caught.** `Multiplayer/core.lua` exists in `_make_mods`, so changing it is a genuine edit to an existing file, and the test expects it to fail. Adding `SomeMod/game-dump/` or `lovely/game-dump-extra/` also fails.
- **Deleting a cached file is covered.** Astra's boundary script adds a cache file and then deletes it under all three policies, and modifies three existing source files, expecting each change to be caught.
- **Certificate and snapshot are covered.** The certificate test shows the Mods layer is unchanged by the cache but does change when a similarly named sibling folder is added. The snapshot test shows live snapshots still contain log, dump and `game-dump` files.

## Not blocking

`tests/astra_generated_dump_boundary.py` has no `test_` functions, so pytest won't collect it. It only runs when called directly. That's fine as independent evidence, but it isn't a regression guard.

## Conditions for resuming (process, not code)

- **Keep the old staging, but not in place.** `stage_mods` refuses to copy into a folder that already exists (`staging_target_exists`). Move the old role folders somewhere outside the new target paths instead of deleting them. Then stage fresh into the same root from the closed live installation, with a process check and a verified backup immediately beforehand.
- **Add the companion first.** Put the exact packaged `0.1.0-dev` bytes from `work/aisparring-package` into both roles before the manifest and certificate are written, and confirm the two roles still match each other.
- **Regenerate the certificate.** Build the certificate and manifests from scratch. Don't reuse any old manifest, certificate or receipt, including the P1A and P1B receipts.
- **Clear the lockout on the record.** Acknowledge the recorded lockout with its cause (Lovely's `game-dump` cache was wrongly treated as source) before running again.
- **Re-run every phase in order.** That means P1A, P1B, FULL_P1, CRASH and all P2 phases. After P1B, check that both roles now pass verification even though Lovely has rewritten `game-dump`, and that fresh patched `lovely/dump/SMODS/Multiplayer/networking/socket.lua` evidence is still there.

This confirms the code is ready for those tests. It is not acceptance of gameplay.
