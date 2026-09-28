# AI Sparring playtest guide

Build target: **0.1.0-dev**. This is currently an implementation draft, not an
installation or playability claim. Actual engine checks and Claude acceptance
must pass before the installed build is handed over.

## Intended launch flow

Start the local AI Sparring launcher, then open normal Balatro. From **Play →
AI Sparring**, choose **Major League**, **Competitive**, and **Normal** pacing
for a first test. **Normal Match** uses Multiplayer's normal seed selection.
**Gauntlet** offers Test 1–5 with stable seeds for repeatable comparisons.

Starting practice asks whether to quit normal Balatro and open isolated
practice. Cancel leaves the game alone. Confirming exits the game normally;
the external launcher waits for that exit and checks its safety gates before
opening the two practice runtimes. Human play belongs in the human window.
The AI has a separate run and separate practice files.

Once the launcher attestation validates and before any match request is sent,
each staged runtime is identified by its window title: the human window is
titled **Balatro AI Sparring 0.1.0-dev - Player** and the AI window is titled
**Balatro AI Sparring 0.1.0-dev - AI runtime**. The AI window is minimized once
so the bot's hand is not the default foreground view; the human window is never
minimized. Only the title and this single minimize are applied — focus, timers,
update loops and gameplay are untouched.

Required live smoke gate (not provable from fixture tests): confirm that the
minimized AI runtime keeps updating and playing normally on the real engine.
The reference `work/reference/game/main.lua` runs `love.update` outside
`love.graphics.isActive()`, which suggests it does, but only an actual minimized
runtime can confirm it. This is a local UI identification change, not a full-run
or playability claim.

The five Gauntlet seeds were chosen as neutral fixed identifiers, not searched
for favorable AI results. Their labels do not imply tested economy or shop
characteristics. Match results may depend on timing as well as the seed.

## Useful feedback

When something goes wrong, record:

- What you were doing and the approximate time.
- Ante/blind, difficulty, pacing, and visible seed or Gauntlet test.
- Whether the AI froze, made a bad decision, or the UI broke.
- A screenshot when it helps explain the problem.

Keep the session's `decisions.jsonl`, `summary.jsonl`, and launcher diagnostics.
They are local files; no automatic upload is intended. The final installed-build
handoff will give the exact session-log directory and launcher path.

## Current strategy scope

The baseline uses visible hand ranks/suits, simple discard preservation,
purchase costs and cash reserves. It does not model every Joker interaction,
predict hidden draws, or search seeds. Stronger strategy follows playtesting;
legality, privacy and independent engine state are required now.

## Verification status

See `PLAYABLE_ACCEPTANCE.md` for the distinction between fixture tests, real
local-server evidence and the remaining actual Balatro gates. Do not infer
successful installation from the existence of this guide.
