# Narrow fix: Lovely generated `game-dump` cache is not staged source

Scope: the single staging-verification failure found by real native evidence after
P1A/P1B (FULL_P1 refused before any process spawn). This note records the evidence,
the exact fix boundary and the focused test results. No other behaviour changed.

## Evidence (real native artifacts, read-only)

- `work/native-post-p1b-verify.json` — both staged roles failed only on
  `manifest_mismatch`, with the identical diff:
  - added: `appdata/Roaming/Balatro/Mods/lovely/game-dump/SMODS/Multiplayer/core.lua`
  - added: `appdata/Roaming/Balatro/Mods/lovely/game-dump/SMODS/Multiplayer/networking/socket.lua`
  - missing: `appdata/Roaming/Balatro/Mods/lovely/game-dump/SMODS/Handy/threads/updater`
  - `changed: []` — no ordinary source file changed.
- `work/native-full-p1-result.json` — `launch_blocked` / `blocked: ["staged_roles"]`,
  spawn time `0.0` (refused before spawning).
- Local Lovely reference `work/reference/offline/lovely-core-lib.rs`:
  - `:210-221` at init Lovely removes **both** `lovely/dump` and `lovely/game-dump`
    and recreates them;
  - `:321` writes the **unpatched** buffer to `lovely/game-dump/<pretty_name>`;
  - `:330` writes the **patched** buffer to `lovely/dump/<pretty_name>`.

Conclusion: `Mods/lovely/game-dump` is a Lovely-regenerated runtime cache, exactly
like `lovely/dump` (already excluded) and `lovely/log`. It is never loaded as code,
so binding it as immutable staged source was the defect.

## Fix boundary (only `tools/staging.py` production code)

1. Exact generated prefix set. `LOVELY_GAME_DUMP_DIR_NAME = "game-dump"` and the
   derived `STAGING_LOVELY_OUTPUT_PREFIXES` / `MODS_LOVELY_OUTPUT_PREFIXES`
   (staging.py:222-243) list `lovely/log`, `lovely/dump`, `lovely/game-dump`.
2. Immutable policies exclude those prefixes by exact relative path:
   `STAGING_POLICY` and `BOOTSTRAP_POLICY` (staging.py:717-726) and
   `MODS_HASH_POLICY` (staging.py:729). `MODS_HASH_POLICY` is also the policy the
   isolation certificate uses for `mods_digest` / `role_parity_digest`
   (`isolation_certificate.py:441,463`), so the certificate/layer-M handling is
   fixed through the shared policy — no separate certificate code change was needed.
3. Fresh-copy omission. `stage_mods` now copies with `_mods_ignore` (staging.py:1058,
   1137), which skips exactly `lovely/game-dump` directly under the source Mods root
   and records it in `omitted` as `kind: "lovely_generated"`. A stale live cache is
   therefore never seeded into a staged role.

## Explicit non-changes (guards preserved)

- Exclusions are exact prefixes. `SomeMod/game-dump/...`, `lovely/game-dump-extra/...`
  and any other same-named tree remain hashed and still invalidate the manifest.
- Ordinary mod sources (`Multiplayer/core.lua`, Handy/SMODS sources) remain immutable
  and still invalidate.
- Live snapshot/backup completeness is untouched: `snapshot_live` hashes every root
  with the default `HashPolicy()`, still capturing `lovely/log`, `lovely/dump` and
  `lovely/game-dump` bytes.
- The separate fresh **patched** `lovely/dump` evidence requirement
  (`check_lovely_evidence`, `_select_dump_files`) is unchanged; `game-dump` is still
  never accepted as dump evidence.

## Tests (focused, pinned interpreter)

`work/runtime-venv/Scripts/python.exe`

- `tests/test_staging.py` — 52/52:
  - `test_generated_lovely_game_dump_cache_never_invalidates_staged_role`
  - `test_mods_hash_policy_excludes_only_exact_lovely_generated_dirs`
  - `test_stage_mods_omits_only_exact_generated_lovely_game_dump`
  - `test_similar_game_dump_names_and_mod_sources_still_invalidate_role`
- `tests/test_isolation_certificate.py` — 52/52:
  - `test_generated_game_dump_cache_does_not_change_certificate_mods_layer`
  - `test_live_snapshot_still_includes_lovely_dump_and_game_dump_content`

Regression suites also green: `test_launcher_safety.py` 61/61,
`test_install_companion.py` 48/48, `test_measurement_lifecycle.py` 11/11,
`test_practice_host.py` 87/87.

## Status

Native phase measurements stay paused. All prior receipts remain diagnostic history;
per the project rule they are not proof for changed tools and must be re-run by root
after Astra verification and Claude's actual diff review, with the packaged companion
added to the staged roles first.
