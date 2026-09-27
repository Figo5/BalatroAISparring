**Scope:** I read the four Milestone 0 (M0) docs and re-checked only the disputed source passages: `ui/game/timer.lua:3-17, 111-192, 333-350`, `networking/action_handlers.lua:852-856, 1359-1385`, `core.lua:71-97, 341-350` and `rulesets/majorleague.lua:22-30`. I ran no shell commands, made no edits and used no subagents.

## Concession on the timer

My original H2 said `last_timer` is "sent but never displayed". That was wrong. `G.FUNCS.set_timer_box` (`timer.lua:333-338`) shows `MP.UI.nemesis_timer_hud()` whenever the human hovers over the timer. That display caps `last_timer` at `timer_display_threshold`, which Major League sets to 180 (`majorleague.lua:28`). It then formats the value with `%d` above 9.95 and `%.1f` otherwise (`timer.lua:162-174`).

So the orchestrator's ruling is right: the displayed projection is allowed and the raw field stays excluded. The projection has to reuse that exact cap-and-format logic, and should be tested at the boundaries: 180, 9.95 and nil → `"0.0"`.

## Remaining actionable contradictions

**Documentation errors (fix the text):**

1. **Stale status markers.** `INTEGRATION_PLAN.md:76` still says PROTOTYPE_GATES is "pending worker correction", and `:5` says "final re-review pending". Update both after this review.
2. **The "include only" list in DS §H contradicts itself.** It says to "Include only displayed opponent fields (`lives`, `skips`, `highest_score`)", but the same section then allows projections of score/hands and the timer. Change "only" to a default-deny list of every displayed field: add PvP score/hands and the capped timer.
3. **DS §F lists `MP.register_action` (add-only) as available and never says V1 won't use it.** Any new action would fall outside the pinned server's handled set (the M3 matrix). State "not used in V1", matching how `moddedAction` is treated.
4. **Three gate numbering schemes don't line up.** DS §E uses P1–P4, the integration plan uses gates 1–5, and PROTOTYPE_GATES uses P0–P5. Several requirements in the authoritative plan are missing from the checklist; see the gaps below. Add a crosswalk and carry every plan requirement into PROTOTYPE_GATES.

**Gaps in the gate definitions (the gates themselves are not errors, but their pass criteria are incomplete):**

- **G1: the P0 fail-closed check is underspecified.**
  - `server_url` and `server_port` fall back to the persisted config one key at a time (`core.lua:343-344`).
  - The check must therefore parse the staged `.env` the way MP does: trimmed lines, `^([%w_]+)%s*=%s*(.+)$`, and a `server_url` key that is actually present.
  - The staged persisted `server_url` should also be loopback, so a parse miss can't fall through to the official server.
  - The plan's "post-launch log checking alone is not sufficient" point needs a concrete pass criterion: observed connections show only loopback to the match port.
- **G2: the Steam pass criterion is too weak.** "Achievements/cloud unchanged" after a bootstrap run that unlocked nothing proves nothing. P1 needs positive proof that Steam user stats and achievements are disabled or unreachable in staged runtimes. It also needs a defined measurement of Steam's own `userdata/<appid>` / remote-cache state, which sits outside `%AppData%\Balatro`.
- **G3: process identity and crash cleanup.**
  - Staged copies are presumably also `Balatro.exe`. The "Balatro closed" precondition and any cleanup must identify processes by full image path and by the PID the launcher spawned, never by name, so the user's game is never killed (AGENTS.md).
  - The plan's gate 3 requires "cleanup after crashes", but PROTOTYPE_GATES has no such item.
- **G4: seed-related gaps created by keeping the fixed seed.**
  - (a) P3 needs fixtures for the `custom_seed` path, the `different_seeds` → nil path, and `random_loadout` with the fixed username.
  - (b) P4 must prove the seed never appears on the launcher→policy IPC channel. The launcher holds the seed and is also the IPC endpoint. My original P4 wording was dropped.
  - (c) Policy must be unable to issue any `lobbyOptions`, even when the bot is host. Rejecting guest `lobbyOptions` alone is not enough.
  - (d) Benchmark seeds must be kept out of policy tuning.
  - (e) Reproducibility was the reason the fixed seed was kept, so define it: same seed + same action trace + same opponent event schedule (including Magnet draws) ⇒ same state hash, plus the known caveats.
- **G5: P4 tests the wrong component.** It tests the trusted extractor, but the plan (`:33`) requires testing the policy worker's own restrictions: no filesystem, network or globals access. Also add these items from plan gate 5, which are missing:
  - rejection of stale and illegal actions;
  - timer continuity: no stall on the main thread under the maximum policy latency (M1).
- **G6: no audit of the rest of the stack for network use.** The plan (`:55`) requires Steam, Lovely, SMODS, Handy and JokerDisplay to be audited separately. PROTOTYPE_GATES has no such item and no pass criterion for it.

## Critical/High resolution table

| # | Original finding | Disposition | Status |
|---|---|---|---|
| C1 | Static live `.env` breaks normal Multiplayer | Both clients staged. Live `.env` and config redirection prohibited in all three docs (Integration Plan `:11`, DS §0/§D, P0). | **Resolved in docs.** The fail-closed details (G1) are a gate gap, not a contradiction. |
| H1 | Save and profile isolation assumed | P1 split into P1a (bootstrap without MP) and P1b (MP with a dead loopback port); full P1 required before any real match. The DS §F isolation claim is now conditional. | **Resolved.** The P1a/P1b split is an acceptable adjudication, since P1a proves the paths are isolated before MP loads. Steam criterion weak (G2). |
| H2 | Network traffic treated as human-visible | §H rewritten as a projection of the human UI under the effective snapshot, default-deny by field. ML has no layers, so scores are revealed. `pvpTimerOrder` excluded and location reduced to one bit. | **Resolved.** The displayed timer is allowed; my "never displayed" claim was wrong (see concession). Wording error #2 remains. |
| H3 | "Own `G` is not a leak" overclaimed | Field-by-field extractor; policy gets no logs, filesystem, seed or globals. | **Resolved.** Policy-worker test missing (G5). |
| H4 | `moddedAction` used as the control channel; hidden-info requests possible | Launcher-owned IPC, trusted executor, outbound allowlist and phase guards; policy has no `Client.send`. | **Resolved.** The `lobbyOptions` rule needs to cover the host case as well (G4c). |
| H5 | Seed semantics misread | Rule corrected. Random mode stays server-generated. A trusted fixed seed chosen before the match is kept at the user's request, with no policy selection or rerolls. | **Resolved by adjudication, and I accept it.** Its safeguards are not yet in the gates (G4a–e). |

## Medium findings

- **M1 (timers are client-reported): resolved** in DS §A.5 and plan `:49`. The pass criterion for timer continuity is missing (G5).
- **M2 (PvP/tie fixtures): resolved.** P3 now lists every fixture.
- **M3 (server version says nothing about parity): resolved.** Coverage matrix and commit-date gap are required, and parity is explicitly marked unproven.
- **M4 (loopback vs "unmodified server"): resolved.** A documented bind patch replaces the "unmodified" claim, and rate-limit testing is included.
- **M5 (unlock state and encryptID must match): resolved** in P5.
- **M6 (offline claim too broad): resolved** by the reworded claim. The audit gate for the wider stack is missing (G6).

## Verdict

**The M0 research direction is acceptable.** No Critical or High finding remains open as a documentation error. The four documentation errors above are Low and can be fixed alongside the gate amendments.

G1–G6 are unproven or underspecified prototype gates, not research errors. They must be added to PROTOTYPE_GATES before the related gate runs: G1–G3 before P1a/P1b, and G4–G6 before P3/P4. They don't block accepting the direction.

This acceptance does **not** mean:

- that a working mod exists;
- that it is safe to launch any runtime now;
- that path or Steam isolation is proven;
- server/protocol parity;
- a fair-observation guarantee;
- V1 or any of the 30 acceptance criteria are complete.
