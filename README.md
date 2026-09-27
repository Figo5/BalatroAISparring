# Balatro AI Sparring

Local, offline competitive practice against a legal AI opponent using Balatro Multiplayer rules. This repository is where the companion is built.

Status: **Milestone 2 accepted: observation/action infrastructure, fixture validation only.** The Steamodded scaffold remains inert. New modules normalize observations, enumerate certified legal actions and reject invalid submissions behind a disabled real executor. A trusted state reader and separate development policy worker are exercised with synthetic fixtures; the UI-view producer and live capture are unwired. There is no opponent, launcher, transport, evaluator, search or gameplay policy. Real game loading remains unproven; no live install has been touched.

- Integration direction and topology: [docs/INTEGRATION_PLAN.md](docs/INTEGRATION_PLAN.md)
- Required prototype gates: [docs/PROTOTYPE_GATES.md](docs/PROTOTYPE_GATES.md)
- Milestone 1 scope: [docs/MILESTONE_1_PLAN.md](docs/MILESTONE_1_PLAN.md)
- Developer guide (layout, interfaces, tests, limitations): [docs/DEVELOPER.md](docs/DEVELOPER.md)
- Milestone 1 acceptance and full file/test/review report: [docs/MILESTONE_1.md](docs/MILESTONE_1.md)
- Milestone 2 interfaces and acceptance criteria: [docs/MILESTONE_2_PLAN.md](docs/MILESTONE_2_PLAN.md)
- Milestone 2 completion and review report: [docs/MILESTONE_2.md](docs/MILESTONE_2.md)
- Fairness and trust boundaries: [docs/FAIRNESS.md](docs/FAIRNESS.md)
- Schemas: [AIObservation](docs/AI_OBSERVATION.md), [legal actions](docs/LEGAL_ACTIONS.md)
- Integration contracts: [state reader](docs/STATE_READER.md), [broker and worker](docs/M2_EXECUTION_BOUNDARY.md)

The planned solution keeps two isolated staged Balatro runtimes (human practice and AI practice) with a pinned local match server. That direction is not implemented by this scaffold.

## Quick start (development only)

```powershell
python -m pip install -r tests/requirements.txt
python tests/run.py
python tests/run_m2.py --require-all
python tests/run_reader.py --require-all
python tests/run_boundary.py --require-all
python tests/astra_attacks.py
python tests/astra_mutation_checks.py
python tests/benchmark_m2.py --require-all
```

Tests run the real entrypoint and modules in synthetic Lua hosts under lupa Lua 5.1 and LuaJIT 2.1. No game, Mods directory, save or network is used. Use `python tests/run.py --require-all` for strict acceptance.

The companion is **staging-only**: it is never placed in the user's normal Balatro installation. Multiplayer hashes its reported mod list with no exemption for passive mods, so enabling `AISparring` anywhere visibly changes that install's mod list and hash; it must not be hidden and Multiplayer's checks must not be patched. A future installed AI Sparring menu is allowed by the accepted integration plan but is **not** part of this implementation and would require its own compatibility and UX review. See the developer guide for the no-live-install policy.
