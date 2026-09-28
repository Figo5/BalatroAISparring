#!/usr/bin/env python3
"""Measurement phase lifecycle tests: receipt-gated ordering, exclusive sessions and CLI.

Synthetic temp trees only; no game, network or real process action. Uses the
fixtures in ``test_isolation_certificate`` for staged trees and probe files.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO), str(Path(__file__).resolve().parent)):
    if path not in sys.path:
        sys.path.insert(0, path)

import isolation_certificate as ic  # noqa: E402
import launch_practice  # noqa: E402
import staging  # noqa: E402
import test_isolation_certificate as fixture  # noqa: E402


class _EmptyEnumerator(launch_practice.ProcessEnumerator):
    def list(self):
        return []


def _session(session_id, staging_root, nonce, roles, running=False):
    session = fixture._FakeSession(session_id, staging_root, nonce, 1.0, roles)
    if running:
        session.is_running = lambda: [
            {"role": record.role, "pid": record.pid, "running": True} for record in session.records
        ]
    return session


def test_measurement_phase_requires_prerequisite_receipts():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            for phase in ("P1B", "FULL_P1", "CRASH", "P2_INITIAL", "P2_CLOSE", "P2_SILENT"):
                refused = ic.prepare_session(
                    staged["staging_root"],
                    live=staged["live_map"],
                    session_id=f"shortcut-{phase.lower()}",
                    port=fixture.PORT if phase != "P1A" else None,
                    closed_check=lambda: True,
                    phase=phase,
                    backup_verify=fixture._backup_verify(staged),
                )
                assert not refused["ok"], phase
                assert any(problem.startswith("phase_prerequisite_missing") for problem in refused["problems"]), phase


def test_measurement_phase_allows_p1a_first():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            prepared = ic.prepare_session(
                staged["staging_root"],
                live=staged["live_map"],
                session_id="bootstrap-first",
                closed_check=lambda: True,
                phase="P1A",
                backup_verify=fixture._backup_verify(staged),
            )
        assert prepared["ok"], prepared
        assert prepared["certificate_id"] is None


def test_measurement_phase_run_closes_then_allows_next_phase():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            receipt_ids = fixture._receipt_ids(staged)
        assert set(receipt_ids) == set(ic.REQUIRED_PHASES)
        assert ic.lockout(staged["staging_root"])["locked"] is False


def test_record_receipt_refuses_running_owned_processes():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            prepared = ic.prepare_session(
                staged["staging_root"],
                live=staged["live_map"],
                session_id="running",
                closed_check=lambda: True,
                phase="P1A",
                backup_verify=fixture._backup_verify(staged),
            )
            assert prepared["ok"]
            fixture._write_probes(staging.bootstrap_paths(staged["staging_root"]), nonce=prepared["nonce"])
            session = _session("running", staged["staging_root"], prepared["nonce"], ("bootstrap",), running=True)
            result = ic.record_phase_receipt(
                staged["staging_root"],
                phase="P1A",
                session_id="running",
                session=session,
                live=staged["live_map"],
                live_closed=lambda: True,
            )
        assert not result["ok"] and "owned_processes_running" in result["problems"]
        assert ic.load_open_record(staged["staging_root"], "running")["status"] == "failed"


def test_execute_measurement_phase_rejects_unknown_phase():
    with tempfile.TemporaryDirectory() as tmp:
        result = launch_practice.execute_measurement_phase(Path(tmp) / "staging", phase="P1X")
        assert not result["ok"] and result["code"] == "unknown_phase"


def test_execute_measurement_phase_refuses_before_launch_without_prerequisite():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            result = launch_practice.execute_measurement_phase(
                staged["staging_root"],
                phase="P1B",
                live_install_root=staged["live_map"]["install"],
                live_appdata_root=staged["live_map"]["appdata"],
                steam_root=root / "Steam",
                port=fixture.PORT,
                backup_root=root / "backups",
                enumerator=_EmptyEnumerator(),
                popen=lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not spawn")),
            )
        assert result["code"] == "measurement_refused"
        assert "phase_prerequisite_missing:p1a" in result["problems"]


def test_launch_plan_command_carries_exact_mod_dir():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        plan = launch_practice.build_launch_plan(
            staging_root=staged["staging_root"],
            live_install_root=staged["live_map"]["install"],
            live_appdata_root=staged["live_map"]["appdata"],
            steam_root=root / "Steam",
            backup_root=root / "backups",
            enumerator=launch_practice.UnavailableProcessEnumerator(),
            require_certificate=False,
        )
        for role in staging.ROLES:
            paths = staging.role_paths(staged["staging_root"], role)
            assert plan["roles"][role]["command"] == [
                str(paths.exe()),
                "--mod-dir",
                str(paths.mods),
            ]


def test_abandon_prepared_session_uses_measured_no_spawn_path():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            prepared = ic.prepare_session(
                staged["staging_root"],
                live=staged["live_map"],
                session_id="abandoned",
                closed_check=lambda: True,
                phase="P1A",
                backup_verify=fixture._backup_verify(staged),
            )
            assert prepared["ok"], prepared
            result = launch_practice.abandon_prepared_session(
                staged["staging_root"],
                session_id="abandoned",
                live_install_root=root / "live" / "Balatro",
                live_appdata_root=root / "live_appdata" / "Balatro",
                steam_root=root / "Steam",
            )
        assert result["ok"] and result["receipt"]["verdict"] == "no_spawn"


class _FakeProc:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = 0
        self.alive = True

    def poll(self):
        return None if self.alive else self.returncode

    def kill(self):
        self.alive = False


class _FakeJob:
    def assign(self, process):
        return True

    def terminate(self):
        return True

    def close(self):
        return None


def _bootstrap_phase_kwargs(root, staged):
    return dict(
        live_install_root=staged["live_map"]["install"],
        live_appdata_root=staged["live_map"]["appdata"],
        steam_root=root / "Steam",
        backup_root=staged["backup_root"],
        enumerator=_EmptyEnumerator(),
        create_time_reader=lambda process: 1000.0,
        job_factory=_FakeJob,
        resume=lambda process: True,
    )


def test_r3_supervisor_interrupt_records_failure_and_lockout():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)
        spawned = []

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            process = _FakeProc(6100 + len(spawned))
            spawned.append(process)
            return process

        def boom(session):
            raise KeyboardInterrupt

        with fixture.synthetic_tools(root):
            try:
                launch_practice.execute_measurement_phase(
                    staged["staging_root"], phase="P1A", session_id="r3-int",
                    popen=popen, supervisor=boom, **_bootstrap_phase_kwargs(root, staged),
                )
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("KeyboardInterrupt must propagate")
        assert spawned, "the phase should have spawned before the interrupt"
        assert ic.lockout(staged["staging_root"])["locked"] is True
        record = ic.load_open_record(staged["staging_root"], "r3-int")
        assert record["status"] == "failed"


def test_r3_supervisor_exception_records_failure_and_lockout():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            return _FakeProc(6300)

        def boom(session):
            raise RuntimeError("supervisor exploded")

        with fixture.synthetic_tools(root):
            try:
                launch_practice.execute_measurement_phase(
                    staged["staging_root"], phase="P1A", session_id="r3-throw",
                    popen=popen, supervisor=boom, **_bootstrap_phase_kwargs(root, staged),
                )
            except RuntimeError:
                pass
            else:
                raise AssertionError("the supervisor exception must propagate")
        assert ic.lockout(staged["staging_root"])["locked"] is True
        assert ic.load_open_record(staged["staging_root"], "r3-throw")["status"] == "failed"


def test_r3_bind_failure_aborts_and_locks_out():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staged = fixture._stage_all(root)

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            return _FakeProc(6200)

        def failing_bind(staging_root, session_id, **kwargs):
            return {"ok": False, "code": "open_session_bind_failed"}

        with fixture.synthetic_tools(root), fixture.patched(ic, bind_open_session=failing_bind):
            result = launch_practice.execute_measurement_phase(
                staged["staging_root"], phase="P1A", session_id="r3-bind",
                popen=popen, **_bootstrap_phase_kwargs(root, staged),
            )
        assert result["code"] == "measurement_launch_failed", result
        assert result["result"]["code"] == "open_session_bind_failed", result
        assert ic.lockout(staged["staging_root"])["locked"] is True


def _run_all() -> int:
    tests = sorted(
        (name, value)
        for name, value in globals().items()
        if name.startswith("test_") and callable(value)
    )
    failures = 0
    for name, function in tests:
        try:
            function()
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"FAIL {name}: {type(error).__name__}: {error}")
        else:
            print(f"ok   {name}")
    print(f"\n{len(tests) - failures}/{len(tests)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(_run_all())
