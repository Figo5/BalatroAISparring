Review captured 2026-09-28. Invocation: `claude-opus-5-5 --effort high`; read-only. Reviewed HEAD `bbf61bf43f1a8be93ac71cc9ca7c0b96a670be8f`.

# Installer review at HEAD `bbf61bf`: **BLOCKED**

This review was read-only. I made no edits, ran no commands and used no agents. I did not run the 27 tests, so "27/27 passed" is the project's claim, not something I checked. `work/review-installer-current.diff` is identical to `tools/install_companion.py`. The certificate being absent is expected at this stage and is not counted against the installer. Nothing has been installed and nothing is claimed playable.

## Findings

**1. HIGH: the certificate is not tied to the package being installed** (`tools/install_companion.py:820-827`)
- **Problem:** `check_certificate` measures whatever mod tree is in the staging area (`isolation_certificate.py:406-467`). The installer only checks `ok`. Nothing compares the staged copies with the package's `staged/<role>/AISparring`. Nothing checks that the live copy matches the staged copies apart from `config.lua`. No tool in `tools/` puts the package's staged copies into the staging area.
- **Concrete failure:** a certificate measured on older module code still passes for a newer package. The installer would then put code that no certificate or smoke test ever covered into live Mods.
- **Minimal repair:** before the plan is returned, check both roles:
  - the digest of `staging.role_paths(staging_root, role).mods / "AISparring"` must equal the digest of `package_root/staged/<role>/AISparring` (both with `PACKAGE_HASH_POLICY`);
  - the live package files, minus `config.lua`, must equal the staged package files, minus `config.lua`.
- Record `certificate_id` in the acceptance record and the receipt, and refuse if they differ. Add a fixture test where the package and the certificate disagree.

**2. MEDIUM: a receipt failure after the rename deletes the only record of a real install** (lines 902-913)
- **Problem:** if `os.replace(pending, final)` fails (file lock, antivirus, full disk), the `InstallError` handler deletes the pending receipt and returns `ok: False, receipt_write_failed`. But `Mods/AISparring` already exists.
- **Concrete failure:** the result says the install failed while the mod is live, and no receipt says so.
- **Minimal repair:** after `os.rename` succeeds, never delete the pending receipt. Return `{"ok": False, "code": "installed_receipt_uncommitted", "installed": True, "pending_receipt": ...}`. Add a test that makes `os.replace` fail.

**3. MEDIUM: `--mods-root` is not checked against the real AppData Mods folder** (lines 608-626 and 830)
- **Problem:** the target is only checked to be `<given root>/AISparring`. The given root is never compared with `live["appdata"]/Mods`, which is the location the certificate and the backup describe. If `staging.live_roots()` throws, `live` falls back to `None` (lines 802-805).
- **Concrete failure:** a mistyped or wrong `--mods-root` (for example a staged role's Mods folder or some other directory) is accepted as the target.
- **Minimal repair:**
  - require `normcase(abspath(mods_root)) == normcase(Path(live["appdata"]) / "Mods")`;
  - refuse when `live is None`;
  - refuse a Mods root that overlaps the staging, package or backup roots.

**4. MEDIUM: the package manifest is re-read at execute time without re-checking the accepted digest** (`_expected_live_files`, lines 281-300, called at line 867)
- **Concrete failure:** the manifest and live files could be rewritten together between `verify_package` and staging. The staged copy would then be checked against the new manifest and would pass, even though the reviewer approved different bytes.
- **Minimal repair:** recompute `package_digest(...)` from the re-read manifest and require it to equal `package_verdict["digest"]`, the digest the acceptance record approved. Alternatively, have `verify_package` return the verified `files` map and use that.

**5. LOW: the final checks run in the wrong order** (lines 889-902)
- **Problem:** the closed-game recheck runs before the target recheck and before the full re-hash, so the whole hashing time sits between that check and `os.rename`.
- **Minimal repair:** run the re-hash first, then the process check, then the target check, then rename straight away.

**6. LOW: backup freshness is not rechecked at commit time** (lines 836-841)
- **Problem:** another mod could change during preparation. The installer never writes to other mods, so this is not a data-loss risk, but the "current backup" guarantee only holds at gate 5.
- **Minimal repair:** run `mods_backup_verdict` again just before the rename.

**7. LOW: the closed-game check only recognises a Balatro process under the given install root** (`launch_practice.py:913-930`)
- **Problem:** if the game runs from another Steam library and `--install-root` is left at its default, a running game is not detected. The certificate's `live_roots` comparison partly covers this.
- **Minimal repair:** also refuse any `process_is_balatro` process that is not an owned staged process.

**8. INFO:**
- **Dangling junction at the target:** lines 833 and 894 use `exists()`/`is_symlink()`, which both return false for a dangling junction. `os.rename` still refuses because the name exists, so this fails safely. Using `os.path.lexists` plus `staging._is_reparse_point` would give a clearer error.
- **Malformed manifest:** in `verify_package`, a manifest that isn't a JSON object crashes with `AttributeError`. There is no mutation, but it should be a proper refusal.

## Checked and OK
- **Acceptance record:** it must be a real record with schema, `accepted=true`, a reviewer and the exact package digest. The CLI has no way to inject a checker. The default certificate check calls the real checker and refuses when no certificate exists.
- **Existing target:** it is refused before and after staging. On Windows, `os.rename` also cannot replace an existing directory.
- **Staging:** it happens outside Mods, overlap in either direction is refused, and a different disk volume is refused. Staging paths and the staged copy are checked for symlinks and junctions, and the staged copy is fully re-hashed against the manifest.
- **Cleanup:** it only removes the temp folder, and only if it has the `.aisparring-install-` prefix and sits under the staging parent. The receipt location may not overlap Mods or the target.
- **Nothing else is touched:** nothing writes to saves, Handy, JokerDisplay, Multiplayer, Steam data or other mods, and the repository's `config.lua` stays with `ai_enabled = false`. The backup gate checks the backup copy's hashes and that the live Mods folder still matches them.
- **Live config is menu only:**
  - `role = "live"` goes to `boot_live` (`AISparring/core.lua:324-359, 470`), which loads only the practice menu, the menu controller and the control thread;
  - engine hooks are only set up for staged roles (line 464);
  - the AI policy and executor modules load only for a staged AI role, which needs both `role = "staged"` in config and the launcher's environment settings.

**Test gaps:** there are no tests for findings 1-4 (failure after the rename, wrong Mods root, package/certificate mismatch, manifest swapped during staging).

## Verdict
**BLOCKED.** Fix finding 1 and findings 2-4, add their tests, then send the installer for re-review. After that, a controlled installation should still wait for:
- a real certificate that is complete and tied to the package;
- a fresh verified backup;
- the other outstanding reviews and smoke tests;
- a closed game, checked immediately before running `--execute`.
