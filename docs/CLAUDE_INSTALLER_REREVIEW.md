# Installer re-review: HEAD `4ebb775`, installer changes from `7bd38eb`

**Verdict: no High or Critical findings remain, but fix N1 and N2 before any live `--execute`.** All eight prior findings are fixed as far as reading the code shows.

I reviewed without running anything: no shell, no edits, no agents, no network, no live game. I did not run the tests, so "40/40 passed" is the project's claim, not something I checked. The installer code matches the `7bd38eb` diff. Nothing was installed.

## Prior findings

| # | Sev | Status | Where |
|---|---|---|---|
| 1 | High | **Fixed** in normal operation. `package_staging_binding` checks that each staged role's `AISparring` digest matches the package's `staged/<role>` copy. `verify_package` checks the live and staged copies are identical apart from `config.lua`. The acceptance record must carry `certificate_id`, it must match the certificate checker's id, and the id goes into the receipt. Remaining gap: a timing race, see N2. | `install_companion.py:330-363, 526-535, 582-584, 971-983, 862` |
| 2 | Med | **Fixed.** If committing the receipt fails after the rename, the pending receipt is kept and the result is `installed_receipt_uncommitted` with `installed: True`. One edge case is in N3. | `:1077-1091`, test `:206` |
| 3 | Med | **Fixed.** If the live roots are missing or have no `appdata`, the installer refuses. The Mods root must equal `appdata/Mods`, and it may not overlap the staging, package or backup roots. | `:942-948, 700-714` |
| 4 | Med | **Fixed.** At execute time the manifest is re-read and its digest must equal the accepted digest (`package_changed_after_acceptance`). | `:294-327, 1035-1039` |
| 5 | Low | **Fixed.** Final order is re-hash, backup, process check, target check, then rename. | `:1052-1075` |
| 6 | Low | **Fixed.** The backup is checked again just before the rename. | `:1060-1065` |
| 7 | Low | **Fixed.** `check_no_staged_session` now refuses a staged or foreign Balatro process wherever its image lives, both at plan time and in the final check. | `:757-774, 1002, 1067` |
| 8 | Info | **Fixed.** Dangling junctions are caught with `lexists` plus the reparse probe. A malformed manifest is refused properly. | `:727-740, 482-491` |

The certificate APIs the installer calls are still compatible with the changed code: `check_certificate` returns `certificate_id` and re-measures layer M against the current staging area. So no cross-API break forces an evidence rerun yet; the N1 fix will add one.

## New findings

**N1. MEDIUM: an unfinished staged session doesn't block the install** (`install_companion.py:757-774`)
- **Problem:** since the API change, `isolation_certificate.list_open_records` treats a session still marked `open` as blocking. `prepare_session` refuses one (`isolation_certificate.py:2237`) and so does the host (`practice_host.py:1214`). `check_certificate` does not check for one. A failed session sets a lockout, so that case is caught, but a plain `open` session is not. If a staged runtime crashed or was killed before its live-diff result was recorded, there's no process left to find, so both process gates pass. The installer then installs against a certificate that session might be about to revoke.
- **Minimal repair:** at the end of `_combined_process_gate`:
  - call `isolation_certificate.list_open_records(staging_root)`;
  - refuse with `staged_session_open_unmeasured` if the list isn't empty, and also if the call raises.
  - Because this function runs at plan time and again before the rename, both checks get it.
- **Tests:** an open record in place at plan time, and one created during the copy.

**N2. MEDIUM (timing race, same kind as prior #4): the certificate binding reads live directories instead of the verified manifest, and runs after the certificate check** (`:330-363`, called at `:978` after `:963`)
- **Problem:** the binding re-hashes `package_root/staged/<role>` rather than the digest-checked manifest.
- **Concrete failure:** between `verify_package` and the binding check, something rewrites the package's staged folders to match an older staging area measured S. Or the staging area is switched between the certificate check and the binding check. In either case a certificate for S passes while the installed live copy is P.
- **Minimal repair:**
  - take the expected files from the manifest's `staged/<role>/AISparring/` section, re-checked against `package_verdict["digest"]` (make `_live_files_from_verified_manifest` accept a prefix);
  - run the binding check both immediately before and immediately after `certificate_check`.
- **Test:** use the same `acceptance_check` hook that `:178` uses to change the package's staged folder and the staging area together.

**N3. LOW: a `StagingError` can escape the execute block and leave a false pending receipt** (`:1033, 1057`; `:1042/1058` through `_verify_stage_tree` → `staging.assert_no_links` at `:377`; handler at `:1092`)
- **Problem:** `StagingError` is the parent class of `InstallError` (`staging.py:268`), so `except InstallError` doesn't catch it. Nothing reaches Mods, because the rename never happens. But the staging temp folder is left behind, the CLI shows a traceback, and after `:1044` a `.pending` receipt remains. That file looks exactly like the genuine `installed_receipt_uncommitted` record, which now means "the mod may be installed".
- **Minimal repair:** change `:1092` to `except staging.StagingError as error:`.
- **Test:** make `assert_no_links` raise on its second call, then check there is no pending receipt and no leftover staging folder.

**N4. LOW (test gap):** the test at `test_install_companion.py:558` was loosened to accept `mods_backup_unverified`. That's because the new backup recheck now catches the target before the target check does. As a result, the target check after the process gate (`:1071-1073`) has no test. **Repair:** create the target during the second call to `closed_check` and assert `target_exists`.

**N5. INFO:** the package hash policies exclude files by name at any depth (`staging.py:684`).
- A nested `manifest.json` under `live/AISparring` would never be hashed or re-verified, but would still be installed.
- A nested `config.lua` would slip past the live/staged comparison.
- Neither file exists today; only the top-level `AISparring/config.lua` does.
- **Repair:** exclude by relative path (`exclude_rel`) at the package root, and hash the individual `AISparring` folders with an empty `HashPolicy()`. Don't use `exclude_rel=("manifest.json",)` on those folders: that would hide a top-level `AISparring/manifest.json` from the staged-copy check even though the package manifest lists it, and the check would fail.

## Scope
- Fix N1 and N2 before any live `--execute`. N3 is a one-line fix and worth doing in the same commit. N4 and N5 are optional.
- Rerun the root installer tests after N1, since it adds a new dependency on the certificate API.
- In production the binding will refuse until the staging owner copies the package's `staged/<role>/AISparring` folders into the staging area. No tool does that yet. The code says so in its docstring, and it fails safe.
- The native certificate, engine and install gate are still separate and not proven by fixtures.
- On a machine where symlinks can't be created, the dangling-junction test silently passes without checking anything.
- I did not assess AI strength or unrelated polish, as you asked.

Separately: the claude.ai Gmail, Google Calendar and Google Drive connectors need authorizing in your claude.ai connector settings before they can be used. They weren't needed for this review.
