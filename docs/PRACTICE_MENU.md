# AI Sparring practice menu

Status: implementation contract for the functional entry/settings UI and the trusted launcher transition. Repository-only; no live install, no process launch and no playability claim. This slice is **not playable** and contains **no dummy opponent**. The runtime host wiring, staged runtimes and policy worker remain other workers' files.

## Ownership and boundaries

| File | Owns | Must never do |
|---|---|---|
| `AISparring/ui/practice_menu.lua` | Declarative widget builders for the settings, confirmation, diagnostic, error and session screens | Read engine globals, mutate game state, run process IO, consume randomness, map a gauntlet index to a seed |
| `AISparring/integration/menu_controller.lua` | Play-menu entry wrap, selection state, confirmation flow, bounded ack handling, injected quit | Touch Multiplayer transport, gameplay hooks, the live save, `os`/`io`/`love` directly, or a seed |

Both modules take every side effect as an injected port. The UI layer only builds widgets and calls back into the controller; the controller only validates a selection and calls injected host functions. No gameplay decision is made here.
## Enable conditions

The AI Sparring button is appended to the existing Play menu when:

- the trusted status probe reports `main_menu == true` (menu is main-menu only);
- the probe reports `mp_compatible == true` (compatible Multiplayer install);
- and the trusted host reports the external launcher is available **or** the only
  blocker is `menu_launcher_unavailable`.

In the second case the button opens the bounded local diagnostic screen
(`diagnostic_definition`, the same screen `open_settings` refuses with) instead of
the settings flow, so a missing external host is explained rather than silently
hidden. It never opens settings, sends a start request, performs hand-off or
quits. Every other refusal — an unreadable status probe (`menu_bad_status`), a
non-main-menu stage (`menu_not_main_menu`), an incompatible Multiplayer install
(`menu_incompatible_mp`) — still returns the original menu untouched, so normal
single-player, human Multiplayer and other mods are unaffected. Install registers
only `aisp_*` callbacks and restores any previous callback value on uninstall.
The unavailable-host condition is still enforced again at `confirm_start`
(`start_preconditions` plus the launcher check), so nothing can start without a
live host even if the entry is visible.
## Selection contract

Fixed for this build:

- Ruleset: **Major League** (resolved from actual Multiplayer configuration by the trusted host; never selectable in UI).
- Modes: `normal` (Normal Match), `gauntlet` (Gauntlet).
- Difficulties: `rookie`, `competitive`, `major_league`, `expert`.
- Pacing: `instant`, `normal`.
- Gauntlet labels: `Test1`..`Test5`; stable seeds `AISP0001`..`AISP0005` are **host-owned**.

The index-to-seed mapping is intentionally absent from these files: the trusted host maps `gauntlet_index = 1..5` to the stable seeds `AISP0001`..`AISP0005` (Normal mode uses original random seed behavior). Tests assert no `AISP0` literal appears in the UI layer.

The controller sends only a validated payload to `host.request_start`:

```
{ mode = <enum>, difficulty = <enum>, pacing = <enum> [, gauntlet_index = 1..5] }
```

No other key is accepted, no seed crosses the UI boundary, and the payload is a fresh snapshot the caller cannot mutate back into controller state. The trusted host maps `gauntlet_index` to the stable seed; the UI and policy never see it.

## Trusted launcher transition

Accepted transition (no `concurrent_live` support): the external launcher already runs independently.

1. **Start** opens an explicit confirmation: *"Quit Balatro and start isolated AI practice?"* stating that the current game closes normally and practice saves are separate.
2. **Cancel** does nothing.
3. **Confirm** verifies main menu, no active run and the current ordinary Multiplayer lobby disconnected. It never leaves a lobby or stops a run automatically.
4. It sends the authenticated start request to the external launcher and waits a bounded, nonblocking ack (default 10s).
5. Only on a confirmed success does it invoke the injected normal quit adapter **once**. Missing launcher, rejection, timeout or any error keeps the game usable and never quits. The controller itself never calls `os.execute`, spawns, kills or copies; the outer launcher waits for the exact live PID to exit naturally and re-runs the closed-game gates.

## Errors and diagnostics

On a match error the UI shows exactly:

> AI Sparring encountered an error. The match has been stopped. Diagnostics were written to the log.

along with a sanitized local diagnostic path supplied by the host (no state dumps). A staged human menu may offer return/end practice through the trusted controller; human controls never become AI controls.

### Bounded Play-menu outcome diagnostics

The controller takes an optional injected `logger` port (the trusted companion
logger bridge). At each Play-menu build it records **at most one** bounded line
per outcome code, `event = "menu_entry"`, using only the allowlisted primitive
`event`/`code` fields: `menu_ok` (entry added, host ready),
`menu_launcher_unavailable` (entry added, opens the diagnostic),
`menu_bad_status` / `menu_not_main_menu` / `menu_incompatible_mp` (entry withheld
by that refusal), `menu_definition_missing`, `menu_button_failed`, and
`menu_wrapper_replaced` (another mod reassigned the shared builder after install;
detected from the per-frame `update`, never rewrapped or overwritten). A missing
or throwing logger is ignored; logging never changes menu or gameplay behaviour
and never floods. The code is sampled/maintained only from the controller's own
trusted pointer and bounded enum values, never from arbitrary engine state.

## Wiring API for the root bootstrap worker

The root bootstrap worker (not this slice) loads both modules and installs them once:

```lua
local PracticeMenu = SMODS.load_file("ui/practice_menu.lua", "AISparring")()
local MenuController = SMODS.load_file("integration/menu_controller.lua", "AISparring")()

local ui = {
  G = G,                       -- G.UIT / G.C constants and G.UIDEF
  funcs = G.FUNCS,             -- callback table the controller registers into
  UIBox_button = UIBox_button,
  create_UIBox_generic_options = create_UIBox_generic_options,
  overlay_menu = G.FUNCS.overlay_menu,
  exit_overlay_menu = G.FUNCS.exit_overlay_menu,
  notify = sendWarnMessage,    -- optional
}

local menu = PracticeMenu.factory(ui)local controller = MenuController.factory({
  ui = ui,
  menu = menu,
  host = trusted_launcher_host,  -- available/request_start/poll_start/quit/diagnostics_path
  status = trusted_status_probe, -- probe() -> { main_menu, active_run, mp_connected, mp_compatible }
  clock = { now = function() return love.timer.getTime() end },
})

controller.install()               -- wraps G.UIDEF.override_main_menu_play_button once
-- call every frame:
controller.update()                 -- bounded, nonblocking ack poll
-- on shutdown / role teardown:
controller.uninstall()              -- idempotent; abandons any pending ack without quitting
```

The host adapter owns provenance: it must be constructed only by the trusted bootstrap and must bind the session credential before exposing `request_start`/`quit`. `host.quit` is the only path to the game's normal quit, invoked exactly once after a confirmed ack.

`PracticeMenu.factory` accepts **any** table for `ui.G`, because the live `G` is `Game = Object:extend()` and carries a metatable (`work/reference/game/engine/object.lua`). The nested constant tables (`G.UIT`, `G.C`) are still validated as plain tables, so a malformed UI is rejected with `menu_bad_ui` while a real engine instance is accepted.

## Tests

`python tests/run_menu.py --require-all` runs the real modules under Lua 5.1 and LuaJIT 2.1 against the honest fake UI tree in `tests/menu/fakeui.lua`. It checks: every base Play-menu button is retained; install/in-normal-run has no effect; repeated install/uninstall is clean; only an explicit confirmed ack quits; cancel/unavailable/rejection/timeout never quit; selection bounds and payload immutability; an actual Object-shaped (metatable) `G` is accepted; that the UI layer contains no engine mutators, RNG or process IO; and (LV-14) that an unavailable host shows a reachable diagnostic entry that opens only `diagnostic_definition` with zero start/quit, while an unreadable probe, off-main-menu, incompatible Multiplayer or connected lobby still hide or refuse. The fixture is not the actual engine.
