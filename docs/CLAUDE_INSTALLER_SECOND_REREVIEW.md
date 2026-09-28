# Installer re-review (N1–N5)

**Verdict for the installer:** N1–N5 are all fixed in the committed code. Nothing High, Critical or Medium remains. The two items that had to be fixed before any live `--execute` (N1 and N2) are closed at the code level. There are two new Low findings, N6 and N7; neither blocks acceptance. This covers fixture scope only. A native certificate, a real package build with an acceptance record, and a live install are still separate gates, and nothing here proves them.

I only read code. I ran no commands, edits, agents or network calls, and did nothing live. "48/48" is Astra's recorded result in `work/installer-rerepair-root.txt`; I didn't run the tests myself.

## Dispositions

| # | Status | Evidence |
|---|---|---|
| **N1** open or unmeasured session | **Fixed at both gates** | `_combined_process_gate` (`install_companion.py:812-823`) runs after the closed-game check and `check_no_staged_session`. It is called at plan time (`:1078`) and again right before the rename (`:1143`). A `StagingError` or any other exception from the listing is refused with `staged_session_open_unmeasured`. Tests cover a record present at plan time, a record created during the copy (so only the final gate can catch it), and a listing error. Each of these would have failed on the old code. The test record path (`evidence/sessions/open/<id>.json`) matches `_open_dir` (`isolation_certificate.py:2103`). One cross-API limit remains, see N7. |
| **N2** binding to the manifest, before and after the certificate | **Fixed** | Expected role bytes now come from `_live_files_from_verified_manifest(prefix="staged/<role>/AISparring/")`. That function re-checks the digest against the accepted `package_verdict["digest"]` (`:1014-1024`). The binding runs at `:1036`, before `certificate_check`, and again at `:1057`, after the certificate-id match. I checked that the two digests are computed the same way: `_tree_digest` and `_digest_of` both use `json.dumps(sort_keys, separators=(",",":"))` over the same `{sha256,size}` records (`staging.py:309-322`). Both new tests discriminate. `swap_both` would pass under the old re-hash of the package directories. The swap during the certificate check is caught only by the post-certificate binding. |
| **N3** `StagingError` cleanup | **Fixed** | The handler is now `except staging.StagingError` (`:1168`). The test makes the second `assert_no_links` call fail. I confirmed no other `assert_no_links` call runs during install (the calls at `staging.py:988/1023` are not on this path), so the failure lands at `:1134`, after the pending receipt is written at `:1122`. The test asserts no receipt and no leftover temp folder. A related gap remains, see N6. |
| **N4** final target race | **Fixed** | The test creates the target during the second `closed_check` call. The order at `:1137 → 1143 → 1147-1149` is backup, then process gate, then target check, so the target check alone catches it. The test asserts `target_exists`, `calls == 2`, and that the marker file is still there (it isn't deleted). |
| **N5** exclusions by exact relative path | **Fixed** | `PACKAGE_HASH_POLICY` now excludes only `manifest.json` at the package root (`exclude_rel`). `PACKAGE_BODY_POLICY` excludes only the top-level `config.lua`. `PACKAGE_MODULE_POLICY` is empty and is used for the staged digests, the binding and the stage re-hash (`:130-139, 407, 467, 550, 377`). `hash_tree` compares the full relative path (`staging.py:707`). This matches the certificate's rule that `config.lua` is hashed like any other file inside the M digest (`isolation_certificate.py:625-629`), and the mod never writes into its own folder. The test covers a nested `ai/config.lua` and `AISparring/manifest.json`. |

## New actionable findings

**N6. LOW: other exception types can still leave a false pending receipt** (`install_companion.py:655, 664, 687`, reached from `:1137`)
- **Problem:** `mods_backup_verdict` assumes JSON objects. If the backup manifest, its `entries`, or an entry manifest is valid JSON but not an object (for example `[]`), it raises `AttributeError`. At the final recheck (`:1137`) that escapes both handlers. The result is a traceback, a leftover staging temp folder, and a `.pending` receipt that looks exactly like `installed_receipt_uncommitted`. This is the same kind of bug as N3. The same call at plan time (`:1072`) also shows a traceback, but nothing has been written at that point.
- **Repair:**
  - Add `isinstance(..., Mapping)` checks in `mods_backup_verdict` and refuse with `mods_backup_invalid`.
  - Optionally, add a final `except Exception` to the execute block that does the same cleanup. This is safe: after the rename, only `os.replace` runs, inside its own `try`.
- **Test:** rewrite the backup manifest to `[]` inside the `_copy_stage_tree` hook. Assert a refusal with no pending receipt and no temp folder.

**N7. LOW (depends on the isolation owner's API): `list_open_records` skips unreadable records** (`isolation_certificate.py:2115-2125`)
- **Problem:** `_read_json` returns `None` on `OSError` or `ValueError` (`:193-197`), and non-dict records or statuses outside `("open","failed_pending")` are silently dropped. The same happens with an open directory that can't be read. So the installer's "fails closed on listing errors" only covers exceptions that are actually raised. A corrupt record counts as "no session". Normal writes are atomic (`_atomic_write_text`), so reaching this needs outside corruption or tampering.
- **Why it's not an installer fix:** the installer can't correct this locally. Closed records stay in the same directory, so counting files there doesn't work. The fix is a strict listing mode in the certificate API. `practice_host.py:1222` depends on it the same way.
- **Three-phase redesign:** any new blocking status it introduces must be returned by `list_open_records`. The installer picks that up automatically because it calls the API rather than copying its logic. Rerun the installer tests when that design lands. I did not treat its unfinished edits as accepted.

## Residual note

The certificate is not re-checked in the final block before the rename. A staged session that was prepared, ran and failed entirely inside the copy window would not show up there. That's implausible given how long the game takes to launch, and the open-record gate covers every longer-lived case. This is optional hardening only: re-run `certificate_check` and the id match next to the final process gate.

## Scope

- **Required for the installer:** nothing further; N1–N5 are accepted.
- **Recommended:** N6 in the next installer commit, with its test.
- **For the isolation owner, not the installer:** N7.
- **Still separate gates:** native certificate evidence, the staging owner copying the package's staged role folders into the staging area, the real package plus acceptance record, and a live install run as root with the game confirmed closed.
