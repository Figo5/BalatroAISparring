# Local validation queue

Changes made during the cloud period (no access to the live Windows Balatro
install). Each entry has passed the repository suites under Lua 5.1, LuaJIT 2.1
and Python in the cloud container. **None of them has been run in live Balatro.**
Earlier native evidence in `NATIVE_TEST_PROGRESS.md` still applies to the code it
names. It does not cover these entries.

Cloud test environment: lupa 2.8 built from source (vendored Lua 5.1 and LuaJIT
2.1 `v2.1` branch), Python 3.12.11 on Linux. Upstream references were fetched
into gitignored `work/` from the documented pins: Multiplayer `3dff16a` (v0.5.5),
Steamodded tag `26.829.0` and server `d664c29`. The proprietary Balatro sources
are not available in the cloud, so the four `astra_runtime_contracts.py` cases
that load `work/reference/game/engine/object.lua` do not run there. Two
`test_launcher_safety.py` cases exercise Windows-only Job Object branches
(`os.name == "nt"`) and fail on Linux by design. Both were the same before the
cloud changes.

## Re-certification

Any entry that changes `AISparring/` Lua changes the staged companion bytes. It
needs the full re-certification and a companion reinstall, not
`reissue-certificate`, before the live test.

---

## LV-1 End-screen Jokers after match completion

- **Commit:** see `git log --grep "reveal AI jokers"`.
- **Change:** `mp_driver.lua` send guard. `getEndGameJokers` is allowed only for
  the human role, and `receiveEndGameJokers` only for the AI role. Both are
  allowed only once the match has ended (`MP.GAME.won == true` or
  `G.STATE == G.STATES.GAME_OVER`, after a started match, in a joined lobby,
  with no active ghost replay). Completion is latched to that match's
  `MP.GAME` table, so it closes when a new match or the lobby resets it. Both stay blocked during play. The AI still
  cannot request the human's Jokers, and the deck, stats and ranked actions stay
  blocked.
- **Local test:**
  1. Re-certify, reinstall, then Play → AI Sparring.
  2. Play a full match to the end. Run it once where the human loses and, if
     practical, once where the human wins.
  3. On the end screen, check the "Enemy Jokers" area.
- **Expected:** the AI's Jokers appear on the human end screen after both a win
  and a loss. No Joker-related send appears in either runtime's log before the
  match ends.
- **Evidence to capture:** a screenshot of the end screen. From the human
  runtime log, the `mp_driver` events around the match end (there should be no
  `driver_send_blocked action=getEndGameJokers` after the end). From the AI
  runtime log, check there is no `driver_send_blocked action=receiveEndGameJokers`
  after the end. The AI log will still show a blocked `getEndGameJokers` from the
  AI's own end screen, which is expected. Keep `results.jsonl`.
- **Risk if it fails:** cosmetic only (Jokers missing, as before). A leak would
  show up as a Joker send before the end in either log. That would be a fairness
  defect: revert the entry.

## LV-2 PvP opponent wait is a non-error state

- **Commit:** see `git log --grep "PvP waiting as non-error"`.
- **Change:** `decision_loop.lua` enters `WAITING_FOR_OPPONENT` whenever the
  trusted `mp_wait_state` probe reports `mp_ready_blind`, `mp_pvp_no_hands` or
  `mp_pvp_countdown`. In that state it does not ask the policy, counts no errors
  and polls with a backoff capped at 1 s. `practice_service.py` counts
  `policy_no_action` as `no_action`, not as a failure.
- **Local test:** play a normal match. At each Nemesis (PvP) blind, take a
  deliberately long time (60 s or more) in the shop before readying. Also play a
  PvP round where the AI runs out of hands before you finish.
- **Expected:** the AI waits and then plays its PvP round normally once you
  ready. The AI log shows exactly one `wait_begin`/`wait_end` pair per wait, with
  `seconds` close to your delay (`detail` names the wait kind). `decisions.jsonl` has no
  `policy_no_action` rows during the wait, and `summary.jsonl` shows `errors` 0
  (or only genuine errors) and a `no_action` field.
- **Evidence to capture:** the AI runtime log lines with `wait_begin`/`wait_end`,
  plus `summary.jsonl` and `decisions.jsonl`.
- **Risk if it fails:** if the AI does not resume after you ready, the probe is
  stuck. Check for a `ready_blind` that stays true after the blind starts. That
  would stall the match (no leak). The earlier behaviour was noisy but correct.

## LV-3 Stale previous-build `practice_host.json` recovery

- **Commit:** see `git log --grep "stale practice host marker"`.
- **Change:** `practice_host.py discovery_state` now checks a well-formed marker
  from a previous host build for liveness instead of calling it `foreign`. When
  its exact PID and create time are proven gone (exited, exited-but-held handle,
  or PID reused), it is `stale_previous_build` and is replaced on `serve`. It is
  refused while that process runs (`practice_host_previous_build_running`) or
  cannot be verified. Unreadable or other-schema markers stay `foreign`.
- **Local test (Windows):**
  1. With the old daemon running, run `python tools/practice_host.py status`.
     Expect `previous_build_live` (once `practice_host.py` differs from the
     running daemon's build). `serve` must refuse, and the marker must be
     unchanged.
  2. Stop the old daemon normally, then run `status`. Expect
     `stale_previous_build`. Then run `serve` and check the start result shows
     `stale_replaced: true` and `replaced.pid` equal to the old PID.
  3. Run `reissue-certificate` in both situations: refused while the old daemon
     runs, allowed after it has exited.
- **Expected:** no manual marker rename is needed after a host update.
- **Evidence to capture:** the `status` and `serve` JSON output, plus the marker
  file before and after.
- **Risk if it fails:** the worst plausible failure is a refusal. That is the
  same as the old behaviour and is fixed by the manual rename. Replacing a
  marker whose daemon is still running would be a defect: the running daemon
  keeps its port, but the menu would find the new one.

## LV-4 Startup log wording and Handy suppression logging

- **Commit:** see `git log --grep "startup log"`.
- **Change:** the boot line is now `ai_mode_resolved
  status=requested_companion_configured code=ai_companion_configured` when a
  companion is installed. With no companion descriptor it is
  `requested_no_companion_config`. The old `ai_gates_not_implemented` is gone. The
  send guard logs known harmless refusals (Handy `handyMPExtension*`,
  Multiplayer `streamLogLines`/`submitLogHashes`) once per action as
  `driver_send_suppressed`. Nothing new is allowed. See
  `docs/HANDY_COMPATIBILITY.md`.
- **Local test:** start live Balatro and one practice match with Handy 2.0.6
  enabled.
- **Expected:** no `not_implemented` text anywhere in the Lovely log. Each staged
  runtime log has at most one `driver_send_suppressed` line per action, and
  Handy produces no `driver_send_blocked` lines. The match runs at 1x with normal
  animations, which is Handy's own MP-lobby behaviour.
- **Evidence to capture:** the Lovely logs for live, human and AI.
- **Risk if it fails:** logging only. The guard decision is unchanged and
  test-enforced.


## LV-5 Hand-off stage timings

- **Commit:** see `git log --grep "instrument practice handoff"`.
- **Change:** `practice_host.py` records every hand-off stage (`StageTimer`),
  every process listing (`counters.process_enumeration`) and the control
  service milestones. They go into `<session>/host.json` `timings` and
  `<session>/logs/handoff.jsonl`. The live-exit and attestation waits now poll
  every 0.25 s instead of every 1 s. Nothing was removed from verification. See
  `docs/HANDOFF_TIMING.md`.
- **Local test:** full re-certification (host and launcher sources changed),
  then one normal Play → AI Sparring, then play or quit.
- **Expected:** the hand-off works exactly as before. `handoff.jsonl` exists from
  the first stage on. `host.json` has `timings.slowest` and
  `counters.process_enumeration.calls`.
- **Evidence to capture:** both files, plus the wall-clock time from clicking Play
  to the staged human window appearing.
- **Risk if it fails:** instrumentation is exception-safe and uses its own clock,
  so a failure should only lose timing data. A hand-off failure with a new code
  would be a defect.

## LV-6 AI uses the Major League timer on a slow opponent

- **Commit:** see `git log --grep "Major League PvP timer"`.
- **Change:** new legal action `START_TIMER`, which presses the real
  `G.FUNCS.mp_timer_button`. It is certified only while the AI has readied the
  PvP blind and the real `MP.UI.can_timer_opponent()` lights the button, and
  never after the AI's own timer has started. Competitive and Major League press
  it at once; Rookie never does. Timer ticking, expiry and the life penalty are
  Multiplayer's own code in both clients (Major League: `timer_base_seconds=180`,
  `timer_forgiveness=0`, `timer_display_threshold=180`, no timer layers).
- **Local test (difficulty Competitive or Major League):**
  1. Reach an Ante 2 PvP blind. Let the AI ready first while you stay in the
     shop.
  2. Watch your HUD timer: it should start counting down within about 1 s of the
     AI readying.
  3. Let it run out once. You should lose a life (forgiveness 0).
  4. Next PvP, ready promptly. The AI should not start a timer once you are
     ready (the button is unlit).
  5. Repeat with Rookie: the AI should never start your timer.
  6. Have the human timer the AI. The AI should keep playing normally; its own
     timer expiring costs it a life.
- **Expected:** exactly one `startAnteTimer` from the AI per PvP wait. Nothing is
  suppressed or refused (`failTimer` and the timer actions are on the allowlist).
- **Evidence to capture:** the AI and human runtime logs, a screenshot of the
  counting timer, `decisions.jsonl` (look for `START_TIMER`) and `summary.jsonl`.
- **Risk if it fails:** if the button does not start, the AI simply does not use
  the timer (as before). If the AI paused an already-started timer, that would be
  a defect (it is prevented by `timer_started` in both the adapter and the
  executor).

## LV-7 Stronger play, discard, shop and Joker-order decisions

- **Commits:** see `git log --grep "estimate plays"` and `git log --grep "hand levels"`.
- **Change:** the policy estimates chips × mult (visible Jokers, enhancements,
  editions, hand levels), prefers plays that clear the displayed requirement,
  ranks discards by an expected follow-up play, values shop Jokers by their
  marginal effect on a panel of hands, and orders Jokers (+mult before ×mult).
  The adapter now also sends `blind_requirement` (non-PvP, hand phases),
  `hand_levels` (hands listed in Run Info) and discard-specific candidates.
  None of this is live-proven. The benchmark only compares against its own rules
  model.
- **Local test:** play three matches at Major League difficulty with the
  Gauntlet seeds and three at Rookie. Where you can, compare against the
  pre-change build on the same seeds.
- **Expected:** no rejected or illegal decisions, policy latency comparable to
  before (a few tens of ms), the AI clears small and big blinds more reliably and
  reaches a later ante, and there are no pointless repeated Joker reorders.
- **Evidence to capture:** `results.jsonl` and `decisions.jsonl` for each match
  (ante reached, lives, decisions, rejected, errors, latency), plus a note of any
  obviously bad play.
- **Risk if it fails:** the AI gets weaker. The first things to check are
  over-discarding (unmodelled scaling Jokers and boss effects) and Joker
  purchases. Rolling back `baseline_policy.lua` is self-contained.

## LV-8 Expert difficulty in the menu and match

- **Commit:** see `git log --grep "Expert difficulty"`.
- **Change:** a fourth difficulty, `expert`. It is added to the menu options,
  the companion marker enums, the control protocol, launcher descriptors, the
  practice service and the policy. The host marker publishes the service's list,
  and the companion requires an exact set match, so host and companion must come
  from the same build (full re-certification and reinstall).
- **Local test:** open Play → AI Sparring and check the menu shows four difficulty
  choices that fit on screen. Select Expert and start a match, then play one PvP
  round.
- **Expected:** the menu layout is not clipped. The host accepts `expert`, and
  `results.jsonl` / `summary.jsonl` record `difficulty=expert`. The AI plays
  normally with no budget errors (`policy_budget_exceeded` must not appear).
- **Evidence to capture:** a screenshot of the menu, the log lines with the
  start request, and `summary.jsonl`.
- **Risk if it fails:** `companion_marker_enums_mismatch` means host and
  companion builds differ, so reinstall both. If the menu layout clips, shorten
  the labels. Failure is fail-closed: the menu reports it cannot start.

## LV-9 Consumable safety floor (use, buy, pack pick, sell)

- **Commit:** see `git log --grep "consumable safety floor"`.
- **Change:** at every difficulty the policy refuses to use, buy or pick from a
  pack these cards:
  - Wraith with $10 or more;
  - Ankh or Hex with two or more Jokers;
  - Ectoplasm or Ouija, always.

  It sells such a card when one is already held. Planets are used before other
  consumables. The change is policy-only (`baseline_policy.lua`, certified), so
  it needs re-certification and a reinstall.
- **Local test:** play practice matches until the AI opens a Spectral pack or
  holds a Spectral card. A debug seed with an early Spectral pack helps. Also
  confirm that an Arcana or Celestial pick, and planet use, still happen.
- **Expected:** a Spectral pack offering only refused cards is skipped
  (`SKIP_BOOSTER`), and a harmless card in the same pack is picked. A held
  Ectoplasm or Ouija is sold on the next shop visit. Planets are used promptly.
  There are no rejected decisions.
- **Evidence to capture:** the `decisions.jsonl` rows around the pack or shop
  (action type and refs), and `results.jsonl` accepted flags.
- **Risk if it fails:**
  - The AI might skip packs it should take. That is a mild weakness, not a
    stall, because `SKIP_BOOSTER` and `LEAVE_SHOP` are always legal.
  - If the game rejects `SELL_CONSUMABLE`, the result shows as a rejected
    decision and the loop continues.
  - Pack cards reach the policy as playing-card records, and the policy
    classifies them by center key (`j_*` / `c_*`).
    `tests/engine/test_policy_packs.lua` pins this against the adapter
    fixture. If a live pack card's center key differs (a modded pack, for
    example), the floor does not apply to it: check the `SELECT_BOOSTER_ITEM`
    refs against the pack shown on screen.

