# Balatro AI Sparring

Local AI practice using Balatro Multiplayer's Major League rules, with separate human and AI game runtimes and a restricted policy worker.

**0.1.0-dev is implemented in the repository but is not yet accepted, installed or playable.** Milestones 1 and 2 remain accepted. The current work adds a baseline policy, validated production executor, local server/host, staged runtime coordination and AI Sparring menus. Earlier repository and real local-server checks passed, but the September 28 Claude reviews found additional runtime, engine, isolation and installer defects. Repairs and new regression checks are in progress; targeted re-review, actual Balatro isolation gates, compatibility checks and controlled installation remain pending. Live game files and saves have not been changed.

The repository configuration remains inert. Do not copy it directly into Mods or bypass the launcher/certificate gates. The eventual installed companion supplies a menu; actual practice runs in isolated staged copies. It remains visible in Multiplayer's mod list and hash. No checks are hidden or bypassed, and no AI activity goes to official or ranked services.

## Current implementation and evidence

- [Acceptance evidence and remaining engine gates](docs/PLAYABLE_ACCEPTANCE.md)
- [Playtest guide (not an installation claim)](docs/PLAYTEST.md)
- [Reviewed integration architecture](docs/INTEGRATION_PLAN.md) and [prototype gates](docs/PROTOTYPE_GATES.md)
- [Runtime wiring contract](docs/PLAYABLE_WIRING_CONTRACT.md), [companion bootstrap](docs/COMPANION_BOOTSTRAP.md), [practice host](docs/PRACTICE_HOST.md)
- [Baseline policy](docs/BASELINE_POLICY.md), [production adapter](docs/ENGINE_ADAPTER.md), [decision loop](docs/DECISION_LOOP.md)
- [Isolated launcher](docs/RUNTIME_LAUNCHER.md), [runtime isolation](docs/RUNTIME_ISOLATION.md), [installer](docs/INSTALL_COMPANION.md)
- [Fairness boundary](docs/FAIRNESS.md), [AIObservation](docs/AI_OBSERVATION.md), [legal actions](docs/LEGAL_ACTIONS.md)
- Accepted historical reports: [Milestone 1](docs/MILESTONE_1.md), [Milestone 2](docs/MILESTONE_2.md)

## Repository tests

Use Python with the pinned dependencies in `tests/requirements.txt`. This workstation also has a repository-local interpreter at `work/runtime-venv/Scripts/python.exe`; it needs no transient PYTHONPATH.

```powershell
python -m pip install -r tests/requirements.txt
python tests/run.py --require-all
python tests/run_m2.py --require-all
python tests/run_reader.py --require-all
python tests/run_boundary.py --require-all
python tests/run_policy.py
python tests/run_decision.py
python tests/run_engine.py
python tests/run_menu.py
python tests/run_runtime.py
python tests/run_companion.py
```

These suites exercise Lua 5.1 and LuaJIT with synthetic engine fixtures. Some integration checks separately use a real restricted policy subprocess or local sockets; their scope is documented in the acceptance evidence. They do not launch Balatro or prove a playable match. Proprietary sources, dependencies, credentials, logs, backups and staged runtimes stay outside Git.

Development stops after a safe, legal, functional installed playtest build has passed the requested checks. Stronger AI and visual polish are outside the current objective.
