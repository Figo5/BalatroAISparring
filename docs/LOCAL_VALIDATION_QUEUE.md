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
