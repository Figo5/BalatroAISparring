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
  drift and any staged-copy divergence.

Building a package needs no certificate, no closed game and no live access.

## Install (`install_companion`)

The gates, in order, all fail closed. Nothing live is touched before the last
gate, and the closed-game check is repeated immediately before the commit:

1. **Package** verifies against its manifest.
2. **Reviewed acceptance record** — an explicit
   `aisparring.install_acceptance.v1` JSON file with `accepted=true`, a
   non-empty `reviewer`, a `reviewed_unix`, `package_version=0.1.0-dev` and a
   `package_sha256` equal to the verified package digest. A caller-supplied
   boolean is never sufficient: the production default reads and validates this
   file, binding the review to the exact package bytes.
3. **Isolation certificate** — the default calls the real reusable checker
   (`staging.check_isolation_proof` → `isolation_certificate.check_certificate`).
   No certificate, a partial/revoked/locked-out certificate, a changed native
   or Mods layer, changed bound tools or a live-root mismatch all refuse.
4. **Target** — exactly `<resolved live Mods>/AISparring`, with no symlink,
   junction or reparse point on any path component. A different target, an
   escaping parent or an existing target is refused (replace/upgrade is out of
   scope).
5. **Mods backup** — a verified, current backup under `repo/backups` whose
   recorded copy hashes (`staging.hash_tree` source/copy, checked through
   `launch_practice.verify_backup_entry`) still match the live `Mods` tree.
   A changed live tree fails closed.
6. **Closed game** — `launch_practice.check_live_balatro_closed`; unreadable
   process enumeration fails closed rather than skipping.
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
8. **Commit** — immediately before the rename the process check, the owned
   parent containment/reparse check and the full source-integrity re-hash are all
   repeated; an existing target (for example one created by another process
   during preparation) is refused. Only then is the fully prepared directory
   atomically renamed onto `Mods/AISparring`. A success receipt is written to a
   pending path *before* the rename and only committed after it succeeds, so a
   failed rename never leaves a successful-looking receipt. On any failure only
   the created staging temp (and any pending receipt) under the known staging
   parent is removed. The installer never closes, kills or launches Balatro.

Nothing is ever written inside live Mods until the final rename, so a game
launched during preparation can never observe a partly formed mod.

On success a receipt is written under `repo/work` (never live, never in Mods):
`aisparring.install_receipt.v1` with the target, package manifest and digest,
the backup manifest/label/entry reference, the acceptance reference and
timestamp. It contains no credential or secret.

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

## Running the fixture tests

No live install, save, Steam tree, network or game process is touched. Backups
are produced by the real `launch_practice.create_live_backup` helper over temp
trees; certificate success is injected only for the fixture path.

```
$env:PYTHONPATH="../../work/test-deps"
python tests/test_install_companion.py
```

The suite covers package contents/config escaping/version, wrong target,
linked Mods root, existing-target refusal, running-game refusal with no
mutation, unreadable process enumeration, backup-verify failure, missing/bad/
mis-bound acceptance, certificate refusal (injected and real default),
dry-run non-mutation, and a successful temp-fixture install that changes only
the new `AISparring` directory and writes a receipt outside the live tree.

The atomic-staging tests cover: a partial copy that fails outside Mods and is
cleaned with no Mods mutation; a corrupted non-config staged file
(`staged_verify_failed`); a target created during preparation
(`target_exists`, existing bytes preserved); a linked staging parent
(`link_or_junction_refused`); a cross-volume staging parent
(`cross_volume_refused`); the game becoming active during preparation
(`live_balatro_running`, staging cleaned); a receipt-write failure that
leaves no receipt and no target; and a rename failure that leaves no
successful-looking receipt, no target and no user-file change. Every one
asserts no staging temp is ever left inside live Mods.

## Actual fixture results (atomic-preparation repair)

Recorded from `py -3 tests/test_install_companion.py` on the isolated fixture
trees only: **27/27 cases passed**, including the original 19 tests and the
8 new atomic-staging cases above. No live install, Mods, save, Steam tree,
process, network or game launch was touched; no Git or packaging operation was
run against live paths.

Remaining real gates before any actual installation (not performed here):

- build the real package and obtain the reviewed `aisparring.install_acceptance.v1`
  record binding its digest;
- measure the P1 isolation certificate on the real staging root so
  `check_certificate` returns complete (the default gate is a refusal without it);
- produce a verified live Mods backup under `repo/backups`;
- confirm the closed game and that the production staging parent
  (`<repo>/work/aisparring-install-stage`) is on the same volume as the real Mods;
- the reviewed, root-run `--execute` step, followed by independent Astra and
  Claude review before any milestone acceptance.
