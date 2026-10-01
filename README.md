# Balatro AI Sparring

Local AI practice using Balatro Multiplayer's Major League rules, with separate human and AI game runtimes and a restricted policy worker.

**The project is playable.** The user completed a real human-vs-AI match on the
installed `9f7a8e1`, `0.1.0-dev` build. Its native session recorded unchanged live
roots. The newer feature branch includes additional policy/runtime work and
finalized targeted Tarots; it is separate from that installed build. Independent
local checks passed all 62 supported entrypoints and the fresh 3,600-decision H1 sweep.
Fresh Claude acceptance, seven-phase certification, a backed-up upgrade and
actual current-build smoke are still required. Exact commit, package, review and
installed-state records are in [local progress](docs/LOCAL_PROGRESS.md) and
[acceptance evidence](docs/PLAYABLE_ACCEPTANCE.md).

The repository configuration remains inert. Do not copy it directly into Mods or
bypass the launcher/certificate gates. The installed companion supplies the
AI Sparring menu; practice runs in isolated staged copies with a local match
server. It remains visible in Multiplayer's mod list and hash. No checks are
hidden or bypassed, and no AI activity goes to official or ranked services.

## Current implementation and evidence

- [Acceptance evidence and remaining engine gates](docs/PLAYABLE_ACCEPTANCE.md)
- [Current local regression evidence](docs/LOCAL_REGRESSION_VERIFICATION.md), [H1 measurements](docs/LOCAL_H1_VERIFICATION.md), [live validation queue](docs/LOCAL_VALIDATION_QUEUE.md)
- [Playtest guide (not an installation claim)](docs/PLAYTEST.md)
- [Reviewed integration architecture](docs/INTEGRATION_PLAN.md) and [prototype gates](docs/PROTOTYPE_GATES.md)
- [Runtime wiring contract](docs/PLAYABLE_WIRING_CONTRACT.md), [companion bootstrap](docs/COMPANION_BOOTSTRAP.md), [practice host](docs/PRACTICE_HOST.md)
- [Baseline policy](docs/BASELINE_POLICY.md), [production adapter](docs/ENGINE_ADAPTER.md), [decision loop](docs/DECISION_LOOP.md)
- [Isolated launcher](docs/RUNTIME_LAUNCHER.md), [runtime isolation](docs/RUNTIME_ISOLATION.md), [installer](docs/INSTALL_COMPANION.md)
- [Local release, upgrade, uninstall and rollback](docs/LOCAL_RELEASE_PROCESS.md)
- [Fairness boundary](docs/FAIRNESS.md), [AIObservation](docs/AI_OBSERVATION.md), [legal actions](docs/LEGAL_ACTIONS.md)
- Accepted historical reports: [Milestone 1](docs/MILESTONE_1.md), [Milestone 2](docs/MILESTONE_2.md)

## Repository tests

Use Python 3.12 with the pinned dependencies in `tests/requirements.txt`.
Local verification uses both lupa Lua 5.1 and LuaJIT runtimes; native contracts
also require Windows and the documented ignored reference/server copies.

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

Development continues on `feature/ai-sparring-v1` toward the V1 standard while
the user playtests a stable certified build. DeepSeek implements, Astra verifies
and integrates, and Claude independently reviews. Later runtime improvements
are batched for certification/installation. No merge to `main` occurs before
release readiness; unrelated local main work is preserved.
