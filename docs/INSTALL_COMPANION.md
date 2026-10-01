# AI Sparring companion packaging and first install

Status: **implementation draft, no live operation performed or claimed.** The
installer below is a reviewed, root-run step for later, not a playability or
installation claim. It builds on the frozen wiring interface in
`PLAYABLE_WIRING_CONTRACT.md` and reuses the existing staging, launcher,
backup and isolation-certificate helpers rather than inventing new proof.

## Scope

Owned by this document and `tools/install_companion.py`:

- an isolated package tree under `repo/work`;
- a gated first install of exactly one new `<live Mods>/AISparring` directory.

Out of scope (never implemented here): replace/upgrade of an existing mod,
any write to a save, another mod, a symlink/junction/reparse point or an
arbitrary target; launching, closing or killing Balatro; any network or runtime
AI call. The installer never writes a secret and never deletes a user
directory — on failure it removes only the staging sibling it created.

## Package (`build_package`)

`tools/install_companion.py` copies `AISparring/` into an isolated
`repo/work/aisparring-package` tree and rewrites the **copied** `config.lua`
only. The repository source stays inert (`ai_enabled = false`).

Layout and configs:

| Copy | Config emitted |
|------|----------------|
| `live/AISparring` | `{ ai_enabled=true, companion={ role='live', discovery_path=<abs repo/work/aisparring-host/practice_host.json> } }` |
| `staged/human/AISparring` | `{ ai_enabled=true, companion={ role='staged' } }` |
| `staged/ai/AISparring` | bit-identical to the other staged copy |

- The generated `config.lua` is the **authoritative** descriptor at runtime:
  `AISparring/core.lua` loads it directly through the trusted
  `SMODS.load_file("config.lua", "AISparring")` loader and ignores the
  user-persisted saved config Steamodded merges on top. A stale saved
  live/staged descriptor or `ai_enabled` therefore cannot override or disarm the
  installed role, and a missing/malformed installed config fails closed to the
  inert scaffold (`docs/COMPANION_BOOTSTRAP.md` §2.1,
  `docs/LOCAL_VALIDATION_QUEUE.md` LV-15).
- Junk is excluded (`.git`, `__pycache__`, `node_modules`, IDE/cache dirs,
  `save`/`saves`/`Mods`/`steamapps`, `.env`, `*.log`, `*.jkr`, `*.sqlite*`,
  `*.pyc`, native Steam DLL names).
- The source `AISparring.json` version must equal `0.1.0-dev` or packaging
  fails closed.
- `discovery_path` must be absolute. It is rendered with a Lua-safe
  double-quoted literal (backslash, quote and control-byte escapes), so a
  Windows path cannot corrupt the config.
- `manifest.json` records an immutable SHA256 (plus size) for every package
  file and the digest of `{version, discovery_path, files}`. `verify_package`
  re-hashes the tree and rejects any missing, added or changed file, any config
  drift, any divergence between the two staged copies, and any divergence
  between the `live` and `staged` role bodies (everything except the generated
  `config.lua`). A malformed or non-object manifest is a bounded refusal
  (`package_manifest_invalid`), never an uncaught error.

Building a package needs no certificate, no closed game and no live access.

## Install (`install_companion`)

The gates, in order, all fail closed. Nothing live is touched before the last
gate, and the closed-game check is repeated immediately before the commit:

1. **Package** verifies against its manifest.
2. **Reviewed acceptance record** — an explicit
   `aisparring.install_acceptance.v1` JSON file with `accepted=true`, a
   non-empty `reviewer`, a `reviewed_unix`, `package_version=0.1.0-dev`, a
   `package_sha256` equal to the verified package digest and a non-empty
   `certificate_id`. A caller-supplied boolean is never sufficient: the
   production default reads and validates this file, binding the review to the
   exact package bytes **and** to the isolation certificate id.
3. **Isolation certificate (bound to the package)** — the default calls the real
   reusable checker (`staging.check_isolation_proof` →
   `isolation_certificate.check_certificate`). No certificate, a
   partial/revoked/locked-out certificate, a changed native or Mods layer,
   changed bound tools or a live-root mismatch all refuse. In addition, before
   any plan is returned the installer requires:
   - `check_certificate`'s `certificate_id` to equal the acceptance record's
     `certificate_id` (`certificate_mismatch` otherwise), so a certificate
     measured for older modules can never authorize a newer package;
   - the staged `AISparring` in `staging/roles/<role>/.../Mods` (the tree the
     certificate measures as layer M) to have the same module digest as the
     digest-checked manifest's `staged/<role>/AISparring` subtree for **both**
     roles (`staged_package_mismatch` otherwise). The expected bytes come from
     the immutable verified manifest, never from a fresh re-hash of the mutable
     `package_root/staged/<role>` directories, and this binding is checked both
     immediately before and immediately after `check_certificate`, so a package
     and staging area rewritten together after verification, or a staging area
     switched during the certificate check, cannot pass.
   `verify_package` separately requires the package's `live` and both `staged`
   role bodies (everything except the generated top-level `config.lua`) to be
   identical (`live_staged_body_mismatch` otherwise). Files are excluded by exact
   relative path at the package root only, and each `AISparring` folder is hashed
   with an empty policy, so a nested `manifest.json` or `config.lua` is still
   hashed, verified and compared rather than silently skipped.
4. **Target** — exactly `<resolved live Mods>/AISparring`, where the given
   `--mods-root` must equal the validated live `appdata/Mods` root
   (`mods_root_not_live` otherwise; `live_roots_unavailable` when the live roots
   cannot be resolved — there is no unchecked fallback). The given root may not
   overlap the staging, package or backup roots in either direction. The target
   must have no symlink, junction or reparse point on any path component; a
   present target — including a **dangling** junction, which `exists()` misses —
   is refused via `lexists`, and a different target, an escaping parent or an
   existing target is refused (replace/upgrade is out of scope). No target is
   ever deleted.
5. **Mods backup** — a verified, current backup under `repo/backups` whose
   recorded copy hashes (`staging.hash_tree` source/copy, checked through
   `launch_practice.verify_backup_entry`) still match the live `Mods` tree.
   A changed live tree fails closed.
6. **Closed game** — `launch_practice.check_live_balatro_closed`; unreadable
   process enumeration fails closed rather than skipping. This is combined with
   the launcher's unowned-process gate
   (`launch_practice.check_no_staged_session`): any Balatro process that is not
   the live install — a staged session **or a foreign `Balatro.exe` from another
   Steam library or copy** — is refused regardless of its image path. An
   open/unmeasured staged session record that leaves no process behind is refused
   too (`staged_session_open_unmeasured` via
   `isolation_certificate.list_open_records`, including when the listing raises).
   The installer launches and owns no staged process, so the only accepted state is
   no Balatro process and no open staged session at all.
7. **Prepare (outside live Mods)** — the complete module is copied into a fresh
   owned `.aisparring-install-<token>` temp under the known **staging parent**
   (`<repo>/work/aisparring-install-stage` by default, or an explicit fixture
   staging root). The staging parent must not overlap live Mods and must be on
   the **same filesystem volume** as the Mods target, proved by comparing
   `os.stat().st_dev`; a cross-volume staging parent is refused
   (`cross_volume_refused`) rather than silently copied, so the final step can be
   a true atomic rename. Every staged file is re-hashed against the previously
   verified immutable package manifest's `live/AISparring` subtree
   (`staged_verify_failed` on any missing/added/changed file), and a
   link/reparse point anywhere in the staged copy is refused.
8. **Commit** — the package manifest is re-read and its digest revalidated against
   the accepted package digest immediately before staging
   (`package_changed_after_acceptance` if the manifest and files were swapped
   together after verification, so a self-consistent newer manifest cannot pass).
   Immediately before the rename the full source-integrity re-hash runs **first**,
   then the Mods backup is re-verified for freshness, then the process gate, then
   the owned-parent containment/reparse check and the present-target check; an
   existing target (for example one created by another process during preparation)
   is refused. Only then is the fully prepared directory atomically renamed onto
   `Mods/AISparring`. Nothing is written inside Mods before that rename. A
   success receipt is written to a pending path *before* the rename and only
   committed after it succeeds. On any failure before the rename only the created
   staging temp (and the pending receipt) is removed. If the final receipt commit
   itself fails *after* a successful rename, the installer keeps the pending
   receipt, leaves the installed mod in place and returns an honest
   `{"ok": false, "code": "installed_receipt_uncommitted", "installed": true,
   "pending_receipt": ...}` rather than deleting the only record or claiming
   nothing was installed. The installer never closes, kills or launches Balatro.

Nothing is ever written inside live Mods until the final rename, so a game
launched during preparation can never observe a partly formed mod.

On success a receipt is written under `repo/work` (never live, never in Mods):
`aisparring.install_receipt.v1` with the target, package manifest and digest,
the verified `certificate_id`, the backup manifest/label/entry reference, the
acceptance reference and timestamp. It contains no credential or secret.

`execute=False` (the CLI default) runs every gate and returns
`install_planned` without mutating anything. `execute=True` only controls the
staging, verification and final rename; it cannot substitute for the acceptance
record or certificate.

## Narrow, honest gap

Fixtures inject the certificate checker because a complete, measured P1
certificate cannot exist in a temp tree. The production default is the real
checker and therefore refuses when no complete certificate is present; there is
no bypass. Until the P1 gates are measured on the real staging root, the only
production outcome is a refusal — which is the intended fail-closed behaviour.

`package_staging_binding` verifies that the staged `AISparring` copies the
certificate measured match the package's `staged/<role>/AISparring`. Placing the
package's prepared staged copies **into** the real staging area *before* the
certificate is measured is a separate gate owned by the staging-root/isolation
owner, and is not implemented here; in production, until that placement step
exists and is measured, this binding (like the certificate itself) refuses. The
fixture tree performs that placement itself as a stand-in.

## Running the fixture tests

No live install, save, Steam tree, network or game process is touched. Backups
are produced by the real `launch_practice.create_live_backup` helper over temp
trees; certificate success is injected only for the fixture path.

```
$env:PYTHONPATH="../../work/test-deps"
python tests/test_install_companion.py
```

The suite covers package contents/config escaping/version, wrong target,
linked Mods root, existing-target refusal (including a dangling target reparse),
running-game refusal with no mutation, unreadable process enumeration, backup-verify
failure, missing/bad/mis-bound acceptance, acceptance missing or mismatched
`certificate_id`, certificate refusal (injected and real default), dry-run
non-mutation, and a successful temp-fixture install that changes only
the new `AISparring` directory and writes a receipt outside the live tree.

The atomic-staging tests cover: a partial copy that fails outside Mods and is
cleaned with no Mods mutation; a corrupted non-config staged file
(`staged_verify_failed`); a target created during preparation
(existing bytes preserved); a linked staging parent
(`link_or_junction_refused`); a cross-volume staging parent
(`cross_volume_refused`); the game becoming active during preparation
(`live_balatro_running`, staging cleaned); a receipt-write failure that
leaves no receipt and no target; and a rename failure that leaves no
successful-looking receipt, no target and no user-file change. Every one
asserts no staging temp is ever left inside live Mods.

Repair-specific tests added for this pass: staged modules that do not match the
package refuse (`staged_package_mismatch`, the "older certificate cannot
authorize a newer package" case); the package's live and staged bodies must
match apart from `config.lua` (`live_staged_body_divergence`); a `--mods-root`
that is not the validated live `appdata/Mods` (a stray directory or a staged
role's Mods) refuses (`mods_root_not_live`) with no write; unavailable live
roots refuse with no fallback (`live_roots_unavailable`); a manifest swapped
together with its files between verification and staging refuses
(`package_changed_after_acceptance`); a receipt-finalization failure after a
successful rename returns `installed_receipt_uncommitted` with the pending
receipt kept and the installed mod untouched; a foreign `Balatro.exe` from
another library refuses (`foreign_balatro_running`); and a malformed manifest
returns a bounded refusal (`package_manifest_invalid`).

## Actual fixture results (installer repair)

Recorded from
`work/runtime-venv/Scripts/python.exe tests/test_install_companion.py` on the
isolated fixture trees only: **48/48 cases passed**. No live install, Mods,
save, Steam tree, process, network or game launch was touched; no Git or
packaging operation was run against live paths. This is a fixture result, not a
review pass and not a native proof.

Re-review (N1–N5) tests added for this pass: an open staged session record in
place at plan time and one created during the copy both refuse
(`staged_session_open_unmeasured`), as does a listing error; a package staged
folder and the staging area rewritten to the same older bytes after verification
refuse (`staged_package_mismatch`) because the expected bytes are the
digest-checked manifest, not a re-hash; a staging area switched during the
certificate check is caught by the post-certificate re-bind; a `StagingError`
raised during the final staged re-hash leaves no pending receipt and no staging
temp (the handler now catches the parent `staging.StagingError`); a target created
during the second (final) closed check refuses with `target_exists`; and a nested
`AISparring/manifest.json` or nested `config.lua` is now detected as an added file
rather than silently skipped.

Remaining real gates before any actual installation (not performed here):

- build the real package and obtain the reviewed `aisparring.install_acceptance.v1`
  record binding its digest **and** the certificate id;
- have the staging-root/isolation owner place the package's prepared staged
  copies into the real staging area before measurement;
- measure the P1 isolation certificate on the real staging root so
  `check_certificate` returns complete (the default gate is a refusal without it);
- produce a verified live Mods backup under `repo/backups`;
- confirm the closed game and that the production staging parent
  (`<repo>/work/aisparring-install-stage`) is on the same volume as the real Mods;
- the reviewed, root-run `--execute` step, followed by independent Astra and
  Claude review before any milestone acceptance.
