I accept this final source candidate for commit and fresh full native certification, with no unresolved Critical/High/Medium findings.

**What the verdict is bound to:**
- **Source map:** the 317-file `source_files` map in `astra-resumed-config-verification.json` (file sha `9fda3605…`). My re-hash of the current tree matches it exactly, with no mismatches, additions or removals.
- **Key hashes:** `core.lua 46a2318a…`, `src/host.lua 3a85196f…`, `test_config.lua 803c7e44…`, `support.lua 9619fcd1…`, `fixture.lua 5ad00ef8…`; `config.lua e8871a2f…` is unchanged.

**What it does not cover:**
- No clean commit exists yet; HEAD is still `d1a9a80` with a dirty tree. The commit must be byte-identical to that map.
- The final package still needs its own review, and a new full seven-phase certification is required. The d1 and da66 certificates can't be reused or reissued for this behaviour change.
- The actual host-up match is still pending: settings, hand-off, lobby, start, actions and HUD have not passed. Only the d1 host-down entry and diagnostic have been seen.

**Checks behind the verdict:**
- **Regression provenance:** both runs and Astra's pre-doc snapshot started from the same 317 file hashes, which are exactly the snapshot I accepted earlier.
  - The combined summary is the first 58 entrypoints plus the resumed 4, with no overlap and all 62 exiting 0.
  - The resumed four line up with where the interrupted run stopped.
  - It is correctly labelled as resumed, not one uninterrupted run.
  - All four benchmark pairs give identical results on Lua 5.1 and LuaJIT once timing fields are removed.
- **Comment-only delta:** in all five changed Lua files, the non-comment lines are identical to the pinned snapshot.
  - Stripped LuaJIT bytecode is also identical for four of them.
  - `support.lua` is the exception, but its bytecode differs even when the same file is dumped twice in fresh runtimes. Its diff is a single comment block.
- **Tests on the final bytes (both runtimes):**
  - `run.py` 51/51, `run_companion.py` 108/108 (static 23/23, wire 8/8), `run_menu.py` 51/51.
  - My probe using Steamodded's real merge and loader code: 14/14 on the final source, 2/14 on the pre-fix source. The new case confirms the closure's claim that a live role with a missing path ends as `companion_unavailable` and never uses the saved path.
- **Unchanged areas:** the ten H1 inputs, the 2M instruction limit, the 57344 source guard, and `ai/`, `integration/`, `ui/` and `config.lua` are all unchanged.

**Findings:**
- **M1 is closed.** LV-15 now separates the sandbox counterprobe already run from the actual installed-game test.
  - It uses the correct path, `<role save directory>/config/AISparring.jkr`.
  - It forbids copying or editing the live saved config and requires its hash before and after the run to match.
  - It checks the newly installed `config.lua` discovery path instead of a hard-coded phase-h path, and keeps the real-executable hand-off pending.
- **L1, L2, L4 and L7 are closed accurately:**
  - L1: the docs now describe Steamodded's real type-mismatch merge behaviour correctly.
  - L2: they distinguish the one logged warning for an unreadable config from an unrecognized role, which goes inert silently.
  - L4: `Host.read_ai_flag` is marked untrusted and not used in production.
  - L7: the stale saved file is documented as expected and never cleaned up automatically.
- **L3, L5 and L6 deferral is reasonable; L8 is informational.**
- **LV-3** now collects only selected secret-free metadata and forbids raw marker or status output.
- **Checkout identities and live/certification status** are stated honestly in the progress docs.

Two cosmetic notes, not blocking. `LOCAL_PROGRESS.md` says "four docs" where five are now modified. Its testing section says the full regression "completed" without mentioning it was resumed (58 + 4), although Astra's binding records that correctly. Fixing either changes the bound hashes, so it would need a docs-only re-bind.

Report: `work/local-ownership/claude-config-closure-review.md`