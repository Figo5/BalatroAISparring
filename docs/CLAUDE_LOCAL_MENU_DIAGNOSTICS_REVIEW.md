# Local menu diagnostics review — October 1, 2026

## Scope and verdict

Primary implementation: OpenCode Go `opencode-go/deepseek-v4.1-flash`, High.
Independent review: Claude Code `claude-opus-5-5`, High, session
`2eda7e78-eeb3-44a1-be6f-44c8a3636250`.
Astra independently verifies and owns acceptance, native certification and install.

The reviewed candidate follows parent `4641c10`. It hardens native discovery
reads without relaxing marker or process identity checks, exposes the existing
host-unavailable diagnostic from the Play menu, and logs bounded menu outcomes
through the trusted companion logger. AI observation, policy, broker, executor,
start authentication and Multiplayer transport are unchanged.

Claude initially found misleading boot-time readiness wording (M1) and silent
remaining menu refusal paths (M2). DeepSeek corrected both; Claude re-review
closed M1/M2 and L1/L2/L3, found no new Critical/High/Medium, and stated:

> I accept this exact uncommitted source snapshot at repository level.

That verdict was conditional on the complete final supported run and its source
binding. Astra subsequently verified all 62 entrypoints pass on 315 unchanged
files, and all four benchmark pairs have identical non-latency/non-instruction
metrics across Lua 5.1 and LuaJIT. The earlier interrupted 43-entrypoint run is
preserved as partial evidence and is not a full pass.

Claude independently ran companion 98/98, menu 51/51, core 51/51 and runtime
123/123 cases on both runtimes. Its mutation checks caught removed wrapper
detection, dedupe, protected logging, bridge wiring and button-failure reporting,
plus unwanted rewrapping and extra log fields.

## Performance and evidence binding

Fresh H1: 1,800 decisions per runtime, zero strict-budget failures/overruns,
identical action SHA
`6920e8b4c8b82aa47364d3732ec347d98423edbbdd450b509cb03ed1d58136ed`.
Peak instructions: Lua 5.1 1,256,000; LuaJIT 1,263,000, below the unchanged
2,000,000 limit. Candidate maxima: 120 total, 24 targeted Tarot, 19 reorder.
Rendered policy maximum: 56,681 bytes, 663 below the 57,344 guard and 8,855
below the 65,536 hard cap. This is correctness/budget evidence, not AI strength.

The earlier H1 hash set included menu/core/logger files that the harness does
not load. Astra and Claude checked the actual complete ten-file dependency set;
those bytes remain identical after the diagnostics follow-up. No blanket claim
that the older thirty-file set is identical is made.

After the full run, DeepSeek corrected six Markdown files and standalone
comments in `tests/companion/test_gate.lua` only. Astra bound that delta: all
runtime/tool bytes remain identical to the full run, and all non-comment test
lines are identical. Companion and menu suites pass again on both runtimes.
This review record is added separately; the final clean commit requires a short
Claude closure before native certification. Original test/review snapshots are
preserved and are never relabeled as byte-identical to later documentation.

Local evidence (ignored, kept in the development checkout):
- `work/local-ownership/claude-diagnostic-batch-review.json`
- `work/local-ownership/claude-diagnostic-rereview.json`
- `work/local-ownership/diagnostic-final-reregression/`
- `work/local-ownership/diagnostic-batch-astra-verification.json`
- `work/local-ownership/diagnostic-batch-h1-verified.json`
- `work/local-ownership/diagnostic-final-doc-delta-binding.json`

## Remaining gates

The installed frozen `da66f0c` package/certificate/upgrade passed, but its actual
Play entry was absent on repeated checks. Isolated native counterprobes found
the entry in the builder and created overlay; they do not establish the live
cause or a live pass. The exact cause remains unconfirmed.

This batch still needs final clean-source closure, fresh consolidated seven
native phases, exact-package pre-install review, verified fresh backups,
scoped upgrade and actual installed-game smoke. Both host-ready setup/handoff
and host-down diagnostic-only branches are required. No package, current-batch
certification, install, UI pass or readiness is claimed by this record.

Whole-marker reads remain a documented pre-existing Low with no size bound
claimed. Human ten-Tarot effects/cleanup, ordinary Multiplayer compatibility,
end-screen enemy Jokers and a full match on the new build remain queued. Main
stays untouched and unmerged.
