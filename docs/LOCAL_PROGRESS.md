# Local progress — October 1, 2026

## Current status (live-menu investigation, phase-h checkout)

The installed `da66f0c` generation (`exact27` files, after the real
`install_companion` caller fix) is genuinely reviewed, certified through all
seven native phases on its exact package
`96ebad3787381324d9685a55b262268d019e8a68ec7c44c6f40d2038537b0614` (certificate
`694392aa14891518293635185478ff1dcbe8dd280d7f32c546023c93b9a15c98`), package-bound
reviewed by Claude Opus 5.5 High and accepted, and the `full62` supported
entrypoints plus the immutable 3,600-decision H1 sweep accepted on identical
runtime inputs. Its companion does boot (`companion_ready`/`bootstrap_ready`, no
`update_error`). **The actual UI smoke is only partial and has NOT passed: normal
startup, profile `gio`, single-player setup and the mod set (MP 0.5.5, Handy
2.0.6, JokerDisplay 2.0.4, AISparring 0.1.0-dev) all loaded, but the real
Multiplayer Play menu showed no AI Sparring entry on three checks with a matching
practice host running, so no live menu, match, policy or playability is
claimed.** The frozen root is the sibling `BalatroAISparring-runtime-v1`; the
source branch now lives in this checkout. Sanitized observation:
`work/local-ownership/live-smoke-observations-da66.json`. The exact live cause of
the missing entry remains **unconfirmed**.

Development batch (filesystem resilience + bounded availability reason +
reachable host diagnostics; the exact live root cause stays **unconfirmed**). A
follow-up closed Claude Opus 5.5's diagnostic-batch review findings M1/M2 and
L1/L2/L3 (`work/local-ownership/claude-diagnostic-batch-review.md`); the final
fix report is `work/local-ownership/deepseek-menu-review-fixes-report.md`.

- **Resilience, not a proven cause.** `host.available()` is the availability gate
  and its production discovery read (`CompanionHost.nfs_reader`) was never
  exercised by tests (they inject `read_discovery`). The installed nativefs uses
  a direct C open for `read` but a PHYSFS temporary mount for `getInfo`; the old
  adapter required both, so a `getInfo` miss could hide a readable marker. The
  fix makes `read` authoritative (`getInfo` can only refuse a definite
  non-file); every marker/identity/secret/auth check is unchanged. **Astra's
  independent native isolated probe of the exact pre-fix installed build with a
  fresh matching marker showed `getinfo_ok`, `read_ok`,
  `production_reader_decoded`, `production_host_available` and
  `ai_button_present` all true** (`work/local-ownership/live-menu-native-short/
  pre-fix-native-result.json`); that isolated copy does **not** prove the live
  cause is excluded, it only shows the read path works there.
- **Bounded availability reason (M1 corrected).** `host.available_detail()`
  returns an allowlisted boot-time host readiness code (`companion_ok` /
  `companion_marker_absent` / `companion_identity_*`), surfaced in the live
  status and sampled once on the `companion_boot` line. Because an unavailable
  host still shows the diagnostic entry, this code **cannot explain a missing
  entry, whatever it says**; it only says whether the entry would open settings or
  the diagnostic.
- **Reachable host diagnostics (UX).** `decorate_play_menu` also appends the AI
  Sparring entry when the only blocker is `menu_launcher_unavailable`; the entry
  opens the bounded `diagnostic_definition` (not settings, no start, request,
  hand-off or quit). Unreadable probe, non-main-menu, incompatible MP and
  connected-lobby conditions still hide/refuse, and
  `confirm_start`/`start_preconditions` re-check everything.
- **Bounded Play-menu outcome diagnostics (M2).** The controller takes an
  optional injected logger port and records at most one bounded
  `event="menu_entry"` line per outcome code (`menu_ok`,
  `menu_launcher_unavailable`, `menu_bad_status`/`menu_not_main_menu`/
  `menu_incompatible_mp`, `menu_definition_missing`, `menu_button_failed`,
  `menu_wrapper_replaced`). Wrapper replacement is detected from the existing
  per-frame `update` by comparing our own builder pointer (never rewrapped, never
  overwritten). Only allowlisted primitive fields are sent; a throwing/malformed
  logger is ignored and cannot change menu or gameplay. This is diagnostic only.

Local evidence (both Lua runtimes): `tests/run_companion.py` 98/98 per runtime,
`tests/run_menu.py` 51/51 per runtime (`tests/menu/test_diagnostic.lua` fails the
pre-fix wrap and pins the connected-lobby+host-down diagnostic case),
`tests/run.py` 51/51, `tests/run_runtime.py` 123/123.

Latest review/full status: the diagnostic-hours candidate was accepted at
repository level by Claude Opus 5.5 High (`work/local-ownership/
claude-diagnostic-rereview.md`) **conditioned on the full62 run finishing
unchanged**. That run is now complete on this exact candidate:
`work/local-ownership/diagnostic-batch-astra-verification.json` records the
verified dirty candidate, 62/62 supported entrypoints passing, four
cross-runtime benchmark pairs identical, and the fresh H1 sweep (1,800 decisions
per runtime, action digest `6920e8b4…`, peaks 1,256,000 / 1,263,000 under the
unchanged 2M budget, zero budget failures), with H1's 10 actual loaded source
files byte-identical. The verified source tip is the honest parent
`4641c10` plus the pending diagnostics commit (not yet created); no resulting
commit is claimed. After the documentation/comment changes in this batch, the
final source is **not** blanket-claimable as the earlier 315-file byte-identical
snapshot — those changes must be bound and reviewed as their own delta.

Still required before any pass is claimed, in order: (1) Astra binds the
doc/comment delta and a short Claude final closure; (2) build the exact new
package and run the consolidated seven-phase native certification on it;
(3) package-bound pre-install review, fresh verified backups and the scoped
upgrade; (4) an actual installed-game UI smoke covering **both** branches — host
up (four difficulties, setup, hand-off, human/AI lobby, ready/start, actions,
HUD) and host down (entry → bounded diagnostic only, no settings, start, request
or quit), with the `companion_boot` and `menu_entry` lines — **not a full human
run**. An isolated counterprobe may inspect builder/overlay outcomes only and is
never an authorized live executable; identity/source/certificate checks must not
be bypassed. No live Mods/save/host/Game change and no install were made; the
installed `da66` build and the frozen sibling/original main stay untouched. The
sections below are historical and predate this investigation.

## Recovered state

- Remote and feature worktree recovered to `9498cfa` (targeted Tarot WIP `0f48623`, followed by Batch 3 review).
- Durable feature worktree (moved by Git, preserving changes): `C:\Users\ginom\Documents\Codex\2026-09-30\files-pasted-by-the-user-take\outputs\BalatroAISparring`. Original `main` checkout stays in its September 27 location.
- Current release candidate worktree: `...\outputs\BalatroAISparring-runtime-v1`, started from `193e231` with the helper-only caller fix recorded below. The sibling `BalatroAISparring` checkout is frozen at `193e231` with its prior certification and failed upgrade evidence.
- Separate local `main` remains at `5d15bb0` with four pre-existing staged files. Do not alter its index or work. Initial staged-diff SHA256: `c7e11dec4d35d26e3e09d1bbf814f0f52825348a344ae6a7e78946e56bf94875`.
- Verified installed mod: all 27 files exactly match the `9f7a8e1` package, SHA256 `1f6e2a6b6dc7b921a6b22975163129df7189187c1ec8cf6fe4f9f66c2d607c8b`.
- Install receipt: original checkout `work/install-receipts/aisparring-install-20260930T011952Z-47f5e144.json`.
- Original seven-phase certificate: `b48b5a0b6cf69be03bab5aeac223a9b1ed066c3586e81298aa7c7f5ba72f97f4`.
- Current original-checkout certificate pointer: `c19c6dfcd31c99ac144d30b0e3e08c27af4f4aa1324e665f4a30c5435b735cf4` (host/launcher-only reissue). This does not certify current feature mod bytes.
- First human-played full match was completed in session `s-f6805722616c9375446bb20a`, per native records. Latest development build has not been installed.

## Current work

Claude Opus 5.5 High accepted source `9c31d2f` with no Critical/High/Medium
findings. Its complete review is `CLAUDE_LOCAL_SOURCE_ACCEPTANCE_9C31.md`.
Before native certification, Astra independently found an additional held-
Negative consumable case: selling it removes its extra capacity and frees no
slot. The required DeepSeek High coder fixed the useful-slot sale guard and
lowest-worth comparison, with permanent regular/Negative, unknown-edition,
safety-floor and real-adapter settled-capacity regressions. Existing purchase
ranking, reserves, observation fields and fairness boundaries are unchanged.

The new regressions fail on the pre-fix source on both runtimes. DeepSeek's
post-fix policy suite passes 195/195 per runtime (208 unique / 407 executions);
engine remains 176/176 per runtime. Astra independently verifies all 12
Negative traces/runtime, 60 Psychic/shop cases/runtime and 360 nearby-price
cases/runtime, with identical Lua 5.1/LuaJIT results and unchanged source
hashes. The new rendered policy is at most 56,681 bytes: 663 bytes below the
unchanged repository guard, 8,855 below the hard cap. Documentation now matches
the SHOP-only sale behavior and accurately separates historical size figures.

Current implementation checkpoint: `a385826` (pushed). Fresh Astra verification
passed all **62 supported entrypoints**, with all 313 recorded files unchanged
through execution. The immutable H1 sweep passed 3,600 decisions, identical
actions and zero budget failures; peaks remain 1,256,000 on Lua 5.1 and 1,263,000
on LuaJIT. All benchmark gates pass and their non-timing/non-instruction metrics
agree across runtimes. Current evidence is in `LOCAL_REGRESSION_VERIFICATION.md`
and `LOCAL_H1_VERIFICATION.md`; earlier evidence remains preserved separately.

Current task: this checkout (`outputs/BalatroAISparring-runtime-v1`) is the
current pointer generation. Its `193e231` source was reviewed and certified
through all seven native phases, but the actual scoped upgrade then failed
*safely*: both installer calls omitted the required `install_companion`
`live_mods_root`, the real installer refused with `mods_root_required`, and the
rollback restored the exact 27 old files, so the installed old `9f7a8e1` package
is still live. The helper-only caller fix here is fixture-verified only; it
awaits a fresh final review, consolidated seven-phase native certification with
the exact new package, exact-package pre-install review, fresh verified backups,
a scoped upgrade and actual UI smoke. Documentation-only recording after the
tested code checkpoint is distinguished from the unchanged executable inputs.

No new native certification, package, installation or actual UI smoke has been
performed for this pending new generation; the preserved `193e231` seven-phase
certificate/package and its failed-safe upgrade attempt are the latest native
evidence, not a claim about the fixed helper. The live 27-file `9f7a8e1` package
and unrelated main staged diff remain unchanged. After certification/install/
smoke, preserve the installed source generation and move future development to a
separate worktree so playtest workers continue reading stable accepted source.
The separately accepted match-history candidate remains unintegrated until then.

## Remaining sequence

1. Fresh Claude final-diff review, including the native/upgrade orchestration;
   fix and re-review valid findings with the required DeepSeek coder.
2. Consolidated seven-phase native certification with exact current package;
   no reuse of old certificates for mod changes.
3. Package-bound final pre-install review, fresh verified backups, scoped
   upgrade and actual UI smoke; record package/certificate/install separately.
4. Leave build ready for human playtesting, then integrate/review the separately
   prepared read-only match-history improvement without changing live bytes.

## Evidence

Ignored local evidence: `work/local-ownership/`. Initial recovery verification: `recovery-state.json`. Source/reference/server dependencies are local ignored copies; no proprietary sources or runtime logs are committed.

No new acceptance, certification, installation or live-smoke pass is claimed by this recovery checkpoint.

Independent pre-fix evidence reproduced both Medium findings on both runtimes using exact 9498cfa source. New face-down padding cases first reproduced a residual failure, then passed after the entry guard. Current rendered source is at most 54,749 bytes. Phase A worker reported policy/engine/service/host/decision/M2/estimator suites passing; consolidated independent final-source suite and review remain pending.


## Phase A independent checkpoint (93147b7)

An immutable source snapshot passed policy (176 unique cases, 343 executions), engine (165/165 on each runtime), service (61/61) and estimator parity (2/2). The initial snapshot engine invocation lacked work/reference/mp/ui/game/timer.lua; this verification-harness dependency was copied before the engine-only rerun passed. No source/test relaxation was used. All five Phase A files were byte-compared to that verified snapshot before the logical commit and push. Final Claude acceptance and native certification remain pending. Original main staged-diff checksum was rechecked unchanged after the worktree move.


Reviewer availability preflight: Claude Code returned API 429/session limit and reported a 9:40 p.m. America/New_York reset on September 30. This is no review verdict. Repository work and verification continue; native certification/install require the fresh acceptance review after reset. Evidence: work/local-ownership/claude-availability.json.


## September 30 infrastructure verification checkpoint

Acceptance documentation now reflects the actual full human match and keeps the
installed `9f7a8e1` build separate from the feature branch. Documentation checkpoint:
`7d81a14` (no companion byte changes in that commit).

Independent Windows infrastructure run: all 15 entrypoints passed. Installer
48/48, certificate 65/65, launcher 64/64, staging 52/52, server preparation 8/8,
measurement lifecycle 11/11 and pinned P2 observer 6/6. Native Job identity,
IPv4/IPv6 listener ownership, LuaJIT PID/creation-time identity, FIN/SILENT/dead-port
proofs, actual host process runner and pinned Node server runner all passed.
Evidence: `work/local-ownership/infrastructure/summary.json` and per-suite logs.
No Balatro was launched or live content changed by these tests. Fresh Balatro
certification remains pending final source verification and Claude acceptance.

Prepared read-only-default, one-shot upgrade orchestration in
`work/local-ownership/upgrade_reviewed_companion.py`; not executed. It requires
an explicit reviewed source commit and acceptance record, the fresh valid
certificate, verified old installed hashes, two full fresh backups, a verified
archive, installer dry run/execute and complete unchanged-live checks outside
`Mods/AISparring`. Failed first installation restores only the unchanged archive
into an absent exact target with every game closed. It never restores saves.
Both this helper and the consolidated native runner must be included in the final
Claude integration review before execution.

A separate DeepSeek High read-only audit is preparing the next small Phase H
reliability/diagnostics batch. It is scoped to a scratch report and cannot replace
Claude review. The primary DeepSeek worker is still finalizing targeted Tarots.

## September 30 full regression checkpoint (e0d5a70)

The earlier in-progress notes above are historical. All 60 locally supported
entrypoints now pass, including policy/engine/reader/runtime/decision/boundary,
service 63/63, host 123/123, installer 48/48, certificate 65/65, launcher 64/64,
staging 52/52, actual cross-service transport, native owned-helper contracts,
the baseline/hard benchmarks and blind/run simulations on both Lua runtimes.
The 306 tested source/doc/test files remained byte-identical through the run.
See `LOCAL_REGRESSION_VERIFICATION.md` and ignored `work/local-ownership/full-suite/`.

The independent H1 snapshot passed 1,800 decisions on each runtime (all strong
tiers, 8–12 cards, 5/8 Jokers, PvP/nonclear, held Death/Strength/Sun). Zero budget
failures or nondeterministic repeats; cross-runtime action digests agree.
Maximum cost 1,262,000 instructions under the unchanged 2M limit. Maximum
rendered source 54,740 bytes: 2,604 below the 57,344 guard. Measured Lua-only
latency is not a native gameplay promise. See `LOCAL_H1_VERIFICATION.md`.

Independent production logging checks exposed discarded Tarot fields in the
real logger filter; the follow-up fix uses existing bounded primitives and now
passes the full policy -> broker -> executor -> logger checks. The host audit
exposed a nonforced stop deleting an active supervisor's ticket/Job; `e0d5a70`
defers safely under the shared lock, with pre-fix reproduction and regressions.

The installed 27-file `9f7a8e1` companion remains unchanged. No Balatro launch,
fresh certification, install or live smoke has occurred in this local session.
Original main staged diff was independently rechecked unchanged at this point.

Prepared ignored scripts: `work/local-ownership/run_native_certification.py`
and `upgrade_reviewed_companion.py`. Both require Claude inspection before any
execution. The final-review prompt is `final-review-task-draft.txt` in that
directory. Keep reviewed source HEAD clean and fixed through certification and
upgrade; record review/native evidence in ignored work first, then commit
documentation after installation. Never kill the user's game.

Separate future Phase H preparation completed in detached checkout
`C:\Users\ginom\Documents\Codex\2026-09-30\files-pasted-by-the-user-take\work\match-review-prep`
at `7341727`: bounded read-only Tarot selections/receipt correlation in match
history. DeepSeek session `ses_f0b0ce930ffej09gQlTpRo675e`; three scoped files.
Astra reproduced and DeepSeek corrected malformed timestamp/ref and ambiguous
sequence defects. The final 19/19 suite passes independently; adversarial proof
and review of the actual old human match preserve all legacy fields and all
four log/host files. Preserved as detached commit `3745d9c`; a separate Claude
review is still required. Integrate only after the current installed build is
certified and smoke-tested. It does not establish engine effects or highlight
cleanup from broker acceptance, and it changes no installed bytes.

## Final review preparation and upgrade rehearsal

The scratch upgrade helper was fault-injected exclusively against fake Temp
live roots. Astra exposed archive-evidence and failure-evidence writes skipping
rollback, then a failed stderr warning skipping it. DeepSeek hardened the helper;
all 11 expected outcomes now pass with explicit assertions. Independent checks
prove restored old companion on safe failures, retained new companion after
successful installation followed by evidence failure, and refusal to restore
over an existing target, a changed archive or a running game. All other fake
Mods/saves remain unchanged. Evidence is `upgrade-fault-injection-before.json`,
`upgrade-fault-injection-after.json` and
`astra-upgrade-hardening-verification-{before,after}.json` under local-ownership.
This is fixture evidence; the real upgrade has not run and still needs review.

The final documentation alignment corrects the runtime logger comment: no
automatic sequence id/correlation is claimed. Only two comment lines changed
in `runtime_bootstrap.lua` after the full suite; executable source lines and
Lua 5.1 compiled bytecode remain identical. Both runtimes compile. LuaJIT dumps
also vary between compilations of identical source in the control experiment,
so dump equality is not claimed there. Policy/H1 inputs remain unchanged.
`bootstrap-comment-bytecode-binding.json` records this exact distinction.

Read-only native preflight: every Balatro process closed, fresh feature staging
and package paths absent, all 27 old installed files still match their receipt,
main index digest unchanged. Backup source totals ~88.3 MB; available disk space
~155 GB. These observations must be repeated at execution time. No native
action, new certificate, installation or smoke pass is claimed.

## Final-review findings fix (fixture-only, native acceptance pending)

The fresh required Claude Opus 5.5 review of `7f2aced` raised two Medium and
four Low findings. This batch fixes them without changing the live install:

- **M-A** exhausted-hand Psychic terminal in `baseline_policy.lua`; a certified
  short play is now the last resort when 1-4 cards remain and no discard is
  certified, while five-or-more-card incomplete catalogues stay fail-closed.
  Pre-fix stall reproduced and post-fix behavior recorded under
  `work/local-ownership/scratch-ma/`.
- **M-B** `run_native_certification.py` is now an importable, side-effect-free
  `main` pinned to `--reviewed-commit`; it refuses a wrong HEAD or any source
  change before/after/at the end, binds every packaged module file to the
  reviewed Git blobs (canonical blob plus path-filtered `git hash-object`), and
  refuses an existing attempt directory. `upgrade_reviewed_companion.py` now
  requires the native report's source commit/package/certificate bindings.
- **L-a** docs and a queued-callback regression: `exec_ok` with
  `highlight=kept` is the normal dispatch-time state; settled cleanup is a later
  observation, not a log claim.
- **L-b** equal-scored consumable buys prefer higher `SLOT_WORTH`.
- **L-c** closed-game checks around the before snapshot and the private Mods
  copy, plus BaseException-scoped rollback (Ctrl-C after rename still restores).
- **L-d** a requested non-forced stop refuses new match tickets while existing
  poll/closure/human ownership finishes.

All changes are fixture/test-only evidence; no native certification, install,
upgrade, save or Mods mutation was performed. Full report:
`work/local-ownership/deepseek-claude-findings-fix-report.md`.

## Final-review integration corrections (fixture-only)

Astra's independent inspection of the findings batch raised two integration
corrections and one reproduced price/interest churn; all are closed without
native or live operations:

- **Portable release tooling.** The real implementations moved to tracked
  `tools/run_native_certification.py` and `tools/upgrade_reviewed_companion.py`
  (REPO resolved from `tools/`), and `tests/test_native_certification_runner.py`
  now loads those tracked modules, so a fresh checkout can run the regression.
  The fault harness and source-binding controls load the tracked modules too; the
  `work/local-ownership/` copies are thin compatibility entrypoints only, and all
  injected fakes act on the real module. Old 7f2aced review evidence stays in
  `work/local-ownership/prior-claude-7f2-review-evidence/`.
- **Buy tie-break metadata.** The selector already initialises the tie metadata
  whenever a candidate becomes best (including a strict score improvement over an
  earlier `LEAVE_SHOP`), so an equal-scored higher-worth consumable is still
  chosen; permanent `LEAVE_SHOP`-first permutation coverage was added.
- **Interest-breakpoint churn.** A full-slot sale is now justified only for the
  purchase the same `buy_score` and tie-break actually ranks best, that purchase
  must strictly raise the held `SLOT_WORTH`, and a cheaper same-or-worse-worth
  offer blocks the sale (its hidden proceeds would flip the next buy). The
  reproduced sell ? buy ? sell cycle ($22, Death+Sun, Star $3 / Saturn $4) now
  holds; useful superior purchases, Negative purchases and safety-floor sales are
  unchanged.
- **Final package pin.** `tools/run_native_certification.py` now re-verifies the
  package against the digest captured at packaging time (verified-manifest pin
  checker), re-runs source binding and re-binds staging to the original expected
  roles before writing a certificate report.

Evidence: `work/local-ownership/deepseek-interest-churn-fixed.json`,
`astra-review-residuals-final-fixes.json`, `astra-source-binding-fixtures-final-fixes.json`
and `deepseek-claude-findings-fix-report.md`. No native certification, install,
upgrade, save or Mods mutation was performed.

## Negative-consumable slot fix (fixture-only, native acceptance pending)

Astra independently reproduced one unhandled shop case after the `9c31d2f`
source acceptance and before native certification. With a full Death + Strength
+ Negative Sun row (base 2, effective 3), $36, and Star $3 and Saturn $3, the
pre-fix policy sold the Negative Sun first — a sale with no slot benefit — on
both runtimes. The fix is `AISparring/ai/baseline_policy.lua` only: a `negative`
owned consumable (or any edition the observation cannot classify) is never sold
as a slot release, and the lowest-worth scan compares only slot-releasing
candidates, so a lower-worth Negative cannot block the regular card. Negative
purchases and the harmful/unusable safety floor are unchanged, and no observation
fields, hidden information or global buy priorities changed.

Permanent regressions: `tests/policy/test_consumable_slots.lua` (15 cases) and
`tests/policy/test_shop_churn.lua` (14 cases through the real adapter → reader →
policy path, including both offer orders, LEAVE_SHOP-first, the regular/unknown
edition cases, and a settled limit recompute of 3 → 2 after the Negative is
removed). Pre-fix control: 12 failing cases (6 new tests × 2 runtimes); post-fix
both suites pass on both runtimes. `run_policy.py` is now 208 unique / 407
executions (195/195 per runtime, up from 186/186); `run_engine.py` is unchanged
at 192 unique / 368 executions (176/176 per runtime). Largest rendered policy is
56,681 bytes (663 below the unchanged 57,344 guard and well under the 65,536 hard
cap). The corrected probe
(`astra_negative_slot_probe.py --label deepseek-fixed-after`) is cross-runtime
identical and shows only SELL Strength, keep the Negative, BUY Saturn across
both orders, LEAVE_SHOP-first and all three strong tiers. Evidence:
`work/local-ownership/deepseek-negative-slot-fix-report.md`,
`astra-negative-slot-deepseek-fixed-after.json` and the pre-fix run log. No
native launch, install, certification, upgrade, save or Mods mutation was
performed; LV-12 in `LOCAL_VALIDATION_QUEUE.md` is queued for the live test.

## Upgrade caller-contract fix (fixture-only, native acceptance pending)

The `193e231` source generation was reviewed and genuinely certified through all
seven native phases, and its accepted package/certificate were recorded
(package
`fce9da0e7811d119902462571e1fef0f79a7cff3823d46e859bb1e9684a90b19`, certificate
`b122532d89bc12e4d6b857d59714cc74d1bcf050b7abfaa075614e3fe83a49f3`). Its actual
upgrade then failed *safely*: both `tools/upgrade_reviewed_companion.py`
installer calls omitted the required `install_companion` API `live_mods_root`, so
the real installer refused with `mods_root_required`. The archive rollback
restored exactly the 27 old files and every live map outside the companion was
unchanged (`work/local-ownership/upgrade-failure-rollback-astra-proof.json`), so
the installed old `9f7a8e1` build remains in place. The prior Claude pre-install
review and the 19 portable mocked tests missed this caller contract because the
fault fixture's installer double accepted arbitrary `**kw`.

This helper-only fix forwards the already verified resolved paths under the
installer's real keyword names — `live_mods_root=mods`, `target_dir=target` and
the obtained `live` mapping — on both the dry-run and execute calls. No installer
gate, default, rollback, game-closure, target/backup check or source/native
binding changed, and no Lua/runtime byte changed. A permanent regression in
`tests/test_upgrade_reviewed_companion.py` now constrains the fixture to the
production installer signature (missing/wrong root, target or live mapping is
rejected), mirrors the production `resolve_install_target` resolver, and proves
the pre-fix call shape fails while the fixed shape passes. It fails the pre-fix
helper (`installer missing/wrong live_mods_root`) and passes the fixed helper;
the 19 prior cases stay green (now 20/20). Evidence:
`work/local-ownership/deepseek-installer-caller-report.md`.

This was a helper-only change on identical runtime inputs, so the previously
recorded 62 supported suites and H1 results still name the same runtime bytes.
No new native certification, package, installation or UI smoke has been
performed; the new release generation still needs a fresh final review, native
certification, exact-package pre-install review, backed-up scoped upgrade and
actual UI smoke before any new pass is claimed. The prior `fce9da0e` package
and `b122532d` certificate are retained under the sibling old generation and must not
be reused for a newly generated discovery path. The current pointer generation is
this checkout. The original `main` checkout keeps its unrelated staged changes
and stash and is never modified.


## Astra integration and native counterchecks (2026-10-01)

The development branch now includes the previously independently reviewed read-only match-history work as `5f3bb5b` and its documentation correction as `4641c10`. All three integrated Git blobs equal the accepted `48cd0a4` candidate exactly, all unrelated working files were preserved, and the aggregator passes 19/19 cases. These Python/report changes do not alter the installed companion or policy. The current menu/host diagnostic batch remains uncommitted pending fresh independent verification and Claude review.

Astra ran additional bounded native diagnostics over the exact installed `da66f0c` modules in isolated human copies: a short-path copy, a copy with only the existing menu settings/profile (no saved run or deck), and a copy invoking the real Multiplayer Play callback and scanning the created overlay. All three report a valid actual marker and Windows identity, readable discovery, `host_available=true`, and an AI button in the returned definition; the last also reports the AI button in the created overlay while paused. Each owned process closed and complete live byte maps remained identical. The first overlong staging path failed in Handy before the menu check and is preserved separately; its owned process closed and live maps stayed identical. These are diagnostic counterexamples, not certification, installed UI or match acceptance.

The unchanged installed live game was checked again after a fresh idle host start and still omitted the AI entry. The exact live cause remains unconfirmed. The pending change makes the existing host-unavailable diagnostic reachable and reports a bounded boot-time availability code; it must not be represented as a proven live repair or ready-for-playtest build. Installed `da66f0c` package/certificate/upgrade evidence remains frozen in the sibling runtime checkout. Full supported verification and a fresh adversarial review precede the next meaningful native package batch.
