# Claude review — native P2 AI-only role repair

Reviewer: Claude Code 2.1.283, `claude-opus-5-5`, effort high, read-only tools (Read/Glob/Grep). Brief: `work/claude-native-p2-role-review-final.txt`. Date: 2026-09-28.

**Verdict: READY FOR CONTROLLED NATIVE P2.** This depends on two things: `test_practice_host.py` must finish green on the final tree (L1), and the evidence note must be reconciled (L2).

I found no Critical, High or Medium issues. All seven P2 phases (P1A through P2_SILENT) now spawn only the roles the saved session record allows. Each P2 phase launches exactly one AI copy. A receipt with an extra role, a missing role, several processes for one role, or saved records that disagree with the live process handles is rejected, both when it is recorded and whenever it is checked again later.

## Answers to review items 1–7

**1. Can anything widen the spawn set?** No.
- The role set comes only from the phase in the session record reloaded from disk (`tools/launch_practice.py:1858-1863`), mapped through `expected_roles_for_phase` (`:1344-1359`). The P2 phases map to `("ai",)` (`tools/isolation_certificate.py:89-91`).
- An unknown phase gets no roles and is refused (`launch_practice.py:1864-1867`).
- The caller's plan is never used. A fresh plan is rebuilt from disk (`:1868`) and cut down to the phase's roles before spawning (`:1880-1885`). `_spawn_verified` only loops over that reduced plan (`:1646`).
- A caller claiming a different phase is refused (`:1926-1928`). A record whose phase isn't allowed for the call type is refused (`:1842-1846`, `:1931`): measurement calls cannot reach MATCH, and the certificate-gated host path can only reach MATCH.
- The bootstrap path is fixed to P1A and bootstrap-only (`:1985`, `:1992-2008`).
- The practice host only calls `execute_launch` with the certificate required, which is MATCH-only (`tools/practice_host.py:2990-2996`). The bare command-line `launch` is refused (`launch_practice.py:3458-3472`).
- P1B, FULL_P1, CRASH and MATCH still launch human and AI in the same order as before: `PHASE_ROLES` matches `staging.ROLES = ("human","ai")` (`tools/staging.py:67`).

**2. Can a false process match certify a phase?** No.
- The listener only arms with the PIDs of AI records (`launch_practice.py:3182-3186`).
- The connecting process's PID must come from exactly one loopback TCP row (`:2543-2589`) and must be in that AI set (`:2778`). Any other peer closes the run as a failure (`:2785-2788`, `:3195-3196`, `:3238-3242`).
- PID reuse can't match because the launcher holds the AI process handle for the whole run.
- When the receipt is checked again later, the peer PID must be the receipt's single AI PID (`isolation_certificate.py:1647-1655` together with the new one-PID-per-role rule at `:2270`).
- A leftover human copy from an earlier phase is no longer spawned or ignored as "owned". It now trips the staged-session check before spawn (`launch_practice.py:1650-1657`) and on every supervision tick (`:3200-3202`).
- The user's live game is caught by the live-game check at plan time, before and after spawn, on every tick, and when the receipt is recorded (`:1412`, `:1647`, `:1774`, `:3197`, `isolation_certificate.py:2041-2048`).

**3. Startup/shutdown races?** Nothing new. The suspended start → Job Object → resume → create-time sequence (`launch_practice.py:1699-1762`) is unchanged; it now just runs once for P2. The after-exit dead-port proof still runs after supervision ends (`:3247-3248`). The Low limitation already on record about proof timing is unchanged.

**4. Exactly one process per role — reliable?**
- At record time, `_session_role_bindings` (`isolation_certificate.py:888-923`) builds role→PID maps separately from the saved records and from the live handles. It checks each has exactly one PID per role and that the two maps match exactly. The role set must equal `PHASE_ROLES` (`:2020-2024`). Any problem fails the receipt and raises the lockout (`:2049-2050`).
- On later re-checks, `_receipt_role_problems` (`:2244-2281`) requires exact role keys, one PID per role, a valid integer PID, and no PID shared between roles.
- The only thing a later re-check can't redo is the records-vs-handles match, because handles only exist at runtime. That's inherent, and it's safe: `_spawn_verified` adds records and handles together, and any abort in between returns a failed session.

**5. Can results still be falsely certified?** I found no path.
- A receipt's ID is its own content hash, and its phase must match the slot it's used for (`:2415-2422`).
- Nonces must be different across phases (`:2589-2590`).
- The old receipt `a124ad57…` now fails with `receipt_owned_roles_mismatch`. It cannot count as a prerequisite, because P2 phases only require FULL_P1 (`:119-121`, `:2427-2440`).

**6. Is cleanup guaranteed on the new refusal paths?** Yes.
- Both new refusals (`prepared_phase_roles_unknown` and `expected_role_missing:*`) return before any job is created or process started.
- `execute_measurement_phase` then marks the open session failed and raises the lockout (`launch_practice.py:3175-3180`). The listener is closed in `finally` (`:3271-3275`).

**7. Could these phases touch the live install, Mods or saves?** No. The diff only filters roles in memory and adds validation; it adds no file or process operations. The existing guards still apply: executables must be inside staging and not in the live install (`:1662`), and file writes are confined to staging (`isolation_certificate.py:659`, `:682`).

## Findings

| ID | Severity | file:line | Concrete failure scenario | Required fix |
|---|---|---|---|---|
| L1 | Low (evidence integrity) | `work/p2fix-verify-2308.txt:37` | The rerun log stops at `===== tests/test_practice_host.py` with no result, and neither `tests/astra_p2_*.py` script appears in it. The practice host (`practice_host.py:2990`) is the only MATCH caller of the changed `execute_launch`, so a regression there would currently go unseen. The only 87/87 figure is the implementer's own claim. | Record `test_practice_host.py` at 87/87 plus both astra scripts passing, on the exact final tree, before the first native P2 run. |
| L2 | Low (evidence record) | `docs/NATIVE_TEST_PROGRESS.md` (diff line 25: "changed tool bindings require fresh evidence") | If the four receipts are kept (item 8), the committed progress note says the opposite of what was done, so the audit trail can't be trusted. | If item 8 is adopted, reword this line to state the limited basis for reuse and name the four receipt IDs. |

## Item 8 verdict on reusing evidence

**Keeping the four receipts (P1A, P1B, FULL_P1, CRASH) and rerunning only P2_INITIAL, P2_CLOSE and P2_SILENT is sound. Regenerating all seven isn't required.**

Why:
- **Launch behaviour for those four phases is unchanged.** P1A's plan was already bootstrap-only (`launch_practice.py:1513-1522`). For P1B, FULL_P1 and CRASH, the filter keeps exactly `("human","ai")`, in the same order as before (`isolation_certificate.py:86-88` vs `staging.py:67`).
- **Recording only got stricter.** The diff adds refusals but doesn't change the receipt format (`isolation_certificate.py:2187-2210`).
- **Nothing else in their inputs changed.** `staging.py`, the Lua patches and the mod bytes aren't in the diff.
- **The new validator re-checks them automatically, and any failure blocks.** FULL_P1 is re-checked every time a P2 phase is prepared (`:3037` → `:2439`). All seven are re-checked, along with freshness against the current staged trees, when the certificate is built (`:2578-2594`, `:1895-1920`). The certificate then binds the fixed tool hashes at that point.
- **The rejected P2_INITIAL run doesn't taint them.** It also launched the human copy after CRASH, but any drift that matters in the human staged tree would make P1A/P1B/FULL_P1 fail as stale and block the certificate.

Conditions:
- Make no staging-tree or mod changes before the three P2 reruns.
- Never pass `a124ad57…` as a receipt ID.
- Apply L2.

## Orchestrator resolution

- L1: resolved — the full rerun finished after the review began: `test_practice_host.py` 87/87 and both `astra_p2_*` scripts pass on the exact reviewed tree (`work/p2fix-verify-2308.txt`).
- L2: resolved — `NATIVE_TEST_PROGRESS.md` now states the narrowed reuse basis and names the four retained receipt IDs.
