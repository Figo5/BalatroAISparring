# Engineering workflow

## User override — October 2, 2026

The user explicitly instructed: "you are the sole actor on this project just finish it so i can play". Codex now implements, reviews, verifies and delivers this candidate alone. The OpenCode/DeepSeek implementation and Claude review requirements below are superseded. No delegated actors or external model review are required. All game isolation, rules, fairness, backup and source/package/certificate binding requirements remain in force.

- Orchestrator: Codex / GPT-6 Astra / Medium. Own architecture, integration, independent verification, acceptance and Git history.
- Primary implementation: OpenCode Go / opencode-go/deepseek-v4.1-flash / High if supported. Do not substitute another provider or model without user approval.
- Reviewer: Claude Code / claude-opus-5-5 / High. Inspect real code and challenge fairness, state isolation, rules fidelity and compatibility. Resolve high/critical findings and re-review before accepting milestones.
- No feature coding until Milestone 0 architecture is reviewed and the initial integration plan is written.
- Never write to the live Balatro installation or Mods while Balatro is running. Check processes immediately before every live integration operation. Never kill the user's game. Back up every live target before changing it; never overwrite saves.
- Keep proprietary game sources, credentials, personal saves, downloaded dependency sources and runtime logs out of Git. No runtime external AI calls.
- Keep human and AI game states isolated. AI policy receives only an allowlisted AIObservation, never globals, hidden card order or future RNG.
- Use actual Multiplayer rules/configuration, legal game actions and an offline-only transport. Never send AI practice data to official servers or ranked systems.
- DeepSeek implementation -> Astra independent checks -> Claude review -> DeepSeek fixes -> Claude re-review -> Astra acceptance.
- Branch: feature/ai-sparring-v1. Logical commits; no merge to main until full V1 approval.
