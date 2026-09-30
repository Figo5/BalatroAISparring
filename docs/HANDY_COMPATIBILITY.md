# Handy compatibility (code analysis)

Cloud analysis from source only. Behaviour in a live game with Handy enabled is
**LOCAL VALIDATION REQUIRED** (LV-4 in `LOCAL_VALIDATION_QUEUE.md`).

Sources: Handy `v2.0.6` (the installed version recorded in `MILESTONE_0.md`),
`github.com/SleepyG11/HandyBalatro`, `src/mp_extension/pre_release.lua`. Pinned
server `d664c29`, `src/actionHandlers.ts:889-907` and `src/Lobby.ts:67-311`.

## What the blocked message is

Handy's Multiplayer "lobby extension" lets a lobby agree on Handy's speed
multiplier, animation-skip level and "dangerous actions" mode. Each client says
whether it wants the extension:

- `send_action_setEnabled` (`pre_release.lua:24-35`) sends
  `{action = "handyMPExtensionEnable"}` or `{action = "handyMPExtensionDisable"}`.
  The message carries only the action name: no cards, score, seed, profile or
  other private data. It is sent from the lobby checkbox and from
  `set_local_enabled`, which uses the player's saved default.
- The server keeps a per-client flag, `handyAllowMPExtension`, which starts
  **false** when a client joins (`Lobby.ts:236,267`). Enable or Disable sets
  the flag, and the server then rebroadcasts lobby info plus
  `handyMPExtensionLobbyEnabled = every(flag)` (`Lobby.ts:308-311`).
- Handy turns its lobby-controlled options on only when every player is enabled
  (`is_extension_active`, `pre_release.lua:170-178`).

## Effect of the companion send guard

The staged send guard is default-deny (`mp_driver.lua` `SEND_ALLOWLIST`). Neither
Handy action is on the allowlist, so both are refused in both staged runtimes:

- **Disable:** refusing it changes nothing, because the server flag is already
  false.
- **Enable:** refusing it keeps the lobby extension off for the practice match.
  Handy itself then disables its speed multiplier and animation skip inside any
  Multiplayer lobby: `is_disabled_by_mp` returns true for the default mode 1
  (`src/controls/speed_multiplier/index.lua:24-29,101-110`, and the same pattern
  in `animation_skip/index.lua`). So in practice the game runs at 1x with normal
  animations, the same as an online match whose opponent has not enabled the
  extension. Handy's keybinds and other local features that are not
  MP-restricted still work.
- **Leak or isolation:** none. The message goes only to the staged local
  loopback server, never to an official server, and it carries no data.
  Blocking it cannot affect state isolation. Allowing it would not leak anything
  either, but it would let the human's saved Handy default turn on lobby-wide
  options that the AI runtime would then also run under.

## Decision

- **Keep both actions blocked.** No isolation or fairness reason requires them,
  and blocking them keeps the practice rules exactly Major League.
- **Remove the warning noise.** They are listed in
  `MPDriver.SEND_SUPPRESSED_REASONS`, together with Multiplayer's periodic
  replay-log stream (`streamLogLines`, `submitLogHashes`), which was already
  blocked. The guard now logs one `driver_send_suppressed action=<name>
  detail=<reason>` line per action. It no longer logs a `driver_send_blocked`
  line on every attempt. That table affects logging only and is test-enforced to
  allow nothing. Any other refused send is still logged on every attempt.
- **A safe allowlisted path exists if wanted later.** Allowing
  `handyMPExtensionDisable` alone is harmless, because it can only confirm the
  default. Allowing `handyMPExtensionEnable` is a product decision (should
  Handy's lobby-forced speed and animation options apply in practice?), not a
  safety one.

## Local validation (LV-4)

With Handy 2.0.6 enabled, play a practice match. Expect:

- one `driver_send_suppressed action=handyMPExtensionDisable` (or `...Enable`)
  line per runtime, not repeated lines;
- no `driver_send_blocked` lines for Handy;
- Handy's MP tab shows the extension as disabled;
- the match plays normally at 1x speed with normal animations, which is
  Handy's own behaviour in an MP lobby without the extension; Handy keybinds that
  are not MP-restricted still work.
