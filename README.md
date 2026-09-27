# Balatro AI Sparring

Local, offline competitive practice against a legal AI opponent using Balatro Multiplayer rules. This repository is where the companion is built.

Status: **Milestone 1 scaffold only.** `AISparring/` is built to load as a Steamodded mod; loading in a real game is unproven. It checks its dependency read-only, resolves an inert AI flag and publishes a status snapshot. There is no opponent, launcher, transport, observation extractor, action executor or AI policy. Nothing has been loaded in a real game, and no live install has been touched.

- Integration direction and topology: [docs/INTEGRATION_PLAN.md](docs/INTEGRATION_PLAN.md)
- Required prototype gates: [docs/PROTOTYPE_GATES.md](docs/PROTOTYPE_GATES.md)
- Milestone 1 scope: [docs/MILESTONE_1_PLAN.md](docs/MILESTONE_1_PLAN.md)
- Developer guide (layout, interfaces, tests, limitations): [docs/DEVELOPER.md](docs/DEVELOPER.md)
- Milestone 1 acceptance and full file/test/review report: [docs/MILESTONE_1.md](docs/MILESTONE_1.md)

The planned solution keeps two isolated staged Balatro runtimes (human practice and AI practice) with a pinned local match server. That direction is not implemented by this scaffold.

## Quick start (development only)

```powershell
python -m pip install -r tests/requirements.txt
python tests/run.py
```

Tests run the real entrypoint and modules in synthetic Lua hosts under lupa Lua 5.1 and LuaJIT 2.1. No game, Mods directory, save or network is used. Use `python tests/run.py --require-all` for strict acceptance.

The companion is **staging-only**: it is never placed in the user's normal Balatro installation. Multiplayer hashes its reported mod list with no exemption for passive mods, so enabling `AISparring` anywhere visibly changes that install's mod list and hash; it must not be hidden and Multiplayer's checks must not be patched. A future installed AI Sparring menu is allowed by the accepted integration plan but is **not** part of this implementation and would require its own compatibility and UX review. See the developer guide for the no-live-install policy.
