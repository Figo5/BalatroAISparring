#!/usr/bin/env python3
"""Launcher safety tests: containment, ownership, backups, fail-closed gates.

Synthetic temp trees only. No live install, live %AppData%, Steam tree, network,
game launch or OS process termination is performed. Process enumeration, Popen,
Job Objects and create-time reads are injected fakes. No isolation/steam proof
JSON is hand-written: tests that need a passing gate inject a synthetic callable
and exercise the production launcher logic, never a forged evidence file.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import isolation_certificate as ic  # noqa: E402
import launch_practice  # noqa: E402
import staging  # noqa: E402

_MISSING = object()


@contextmanager
def patched(module, **attrs):
    saved = {}
    for name, value in attrs.items():
        saved[name] = getattr(module, name, _MISSING)
        setattr(module, name, value)
    try:
        yield
    finally:
        for name, value in saved.items():
            if value is _MISSING:
                delattr(module, name)
            else:
                setattr(module, name, value)


class FakeEnumerator(launch_practice.ProcessEnumerator):
    def __init__(self, processes):
        self._processes = list(processes)

    def list(self):
        return list(self._processes)


class FakeProc:
    def __init__(self, pid):
        self.pid = pid
        self.alive = True
        self.killed = 0

    def poll(self):
        return None if self.alive else 0

    def wait(self, timeout=None):
        self.alive = False
        return 0

    def kill(self):
        self.killed += 1
        self.alive = False


class FakeJob:
    def __init__(self):
        self.terminated = 0
        self.closed = 0
        self.assigned = 0

    def assign(self, process):
        self.assigned += 1
        return True

    def terminate(self):
        self.terminated += 1
        return True

    def close(self):
        self.closed += 1


class FakeNativeHandle:
    """Stands in for a single reopened native process handle."""

    def __init__(self, create_time, image_path, terminate_ok=True):
        self._create_time = create_time
        self._image_path = image_path
        self.terminate_ok = terminate_ok
        self.terminated = 0
        self.closed = 0

    def create_time(self):
        return self._create_time

    def image_path(self):
        return self._image_path

    def terminate(self, timeout=10.0):
        self.terminated += 1
        return self.terminate_ok

    def close(self):
        self.closed += 1


def _pinned_env(paths):
    return {
        "APPDATA": str(paths.data),
        "LOCALAPPDATA": str(paths.local_appdata),
        "USERPROFILE": str(paths.userprofile),
        "TEMP": str(paths.temp),
        "TMP": str(paths.temp),
        "LOVELY_MOD_DIR": str(paths.mods),
        "BALATRO_AI_ROLE": paths.role,
        "BALATRO_AI_ISOLATION": "unproven",
    }


def _make_install(root):
    install = root / "BalatroInstall"
    (install / "resources").mkdir(parents=True)
    (install / "Balatro.exe").write_bytes(b"MZ fake balatro")
    (install / "resources" / "main.lua").write_text("return 1\n", encoding="utf-8")
    return install


def _fake_role_tree(staging_root, role, binding=True, steam_native=False):
    paths = staging.role_paths(staging_root, role)
    paths.install.mkdir(parents=True, exist_ok=True)
    executable = paths.install / "Balatro.exe"
    executable.write_bytes(b"MZ staged " + role.encode())
    if steam_native:
        (paths.install / "steam_api64.dll").write_bytes(b"native")
    manifest = {"schema": "aisparring.staging_manifest.v1", "root": str(paths.root), "files": {}}
    if binding:
        manifest["files"]["install/Balatro.exe"] = {
            "sha256": staging.sha256_file(executable),
            "size": executable.stat().st_size,
        }
    (paths.root / staging.MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
    return paths, executable


def _fresh_plan(staging_root, roles=("ai",), session_id="testsession"):
    specs = {}
    for role in roles:
        paths = staging.role_paths(staging_root, role)
        executable = paths.exe()
        specs[role] = {
            "exe": str(executable),
            "exe_exists": executable.is_file(),
            "cwd": str(paths.install),
            "command": [str(executable), "--mod-dir", str(paths.mods)],
            "env_overrides": {},
            "env": {},
        }
    return {"may_launch": True, "blocked": [], "session_id": session_id, "roles": specs}


def _make_live_tree(root):
    install = root / "live" / "Balatro"
    install.mkdir(parents=True)
    (install / "Balatro.exe").write_bytes(b"MZ live")
    (install / "version.dll").write_bytes(b"lovely")
    appdata = root / "live_appdata" / "Balatro"
    (appdata / "Mods").mkdir(parents=True)
    (appdata / "Mods" / "x.lua").write_text("x", encoding="utf-8")
    (appdata / "save.jkr").write_bytes(b"save")
    profiles = {}
    for profile in ("390025789", "111111111"):
        app = root / "Steam" / "userdata" / profile / "2379780"
        (app / "remote").mkdir(parents=True)
        (app / "remote" / "state.vdf").write_text("s", encoding="utf-8")
        profiles[profile] = app
    return install, appdata, profiles


def test_write_session_refuses_overwrite():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        records = [launch_practice.ProcessRecord("ai", 1, 1.0, str(staging_root / "roles" / "ai" / "install" / "Balatro.exe"), "s")]
        launch_practice.write_session(staging_root, "s", records)
        try:
            launch_practice.write_session(staging_root, "s", records)
        except staging.StagingError as error:
            assert error.code == "session_exists"
        else:
            raise AssertionError("expected session_exists")


def test_cleanup_requires_staging_root():
    result = launch_practice.cleanup_session("missing.json", FakeEnumerator([]), staging_root=None)
    assert not result["ok"] and result["code"] == "staging_root_required"


def test_cleanup_refuses_session_outside_staging():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        session = root / "elsewhere" / "s.json"
        session.parent.mkdir()
        session.write_text(json.dumps({"records": []}), encoding="utf-8")
        result = launch_practice.cleanup_session(session, FakeEnumerator([]), staging_root=root / "staging")
        assert not result["ok"] and result["code"] == "session_outside_staging"


def test_cleanup_refuses_record_outside_staging():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        session = staging_root / "sessions" / "s.json"
        session.parent.mkdir(parents=True)
        session.write_text(
            json.dumps(
                {
                    "records": [
                        {
                            "role": "ai",
                            "pid": 10,
                            "create_time": 1.0,
                            "image_path": str(root / "live" / "Balatro.exe"),
                            "session_id": "s",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        result = launch_practice.cleanup_session(session, FakeEnumerator([]), staging_root=staging_root)
        assert not result["ok"] and result["code"] == "session_record_outside_staging"


def test_cleanup_only_terminates_owned_and_skips_pid_reuse():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        owned_exe = str(staging_root / "roles" / "ai" / "install" / "Balatro.exe")
        live_exe = str(root / "live" / "Balatro.exe")
        records = [
            launch_practice.ProcessRecord("ai", 10, 500.0, owned_exe, "s"),
            launch_practice.ProcessRecord("ai", 20, 500.0, owned_exe, "s"),
        ]
        session = launch_practice.write_session(staging_root, "s", records)
        processes = [
            launch_practice.ProcessInfo(10, 500.2, owned_exe, name="Balatro"),
            launch_practice.ProcessInfo(20, 500.2, live_exe, name="Balatro"),
            launch_practice.ProcessInfo(21, 500.2, owned_exe, name="Balatro"),
        ]
        killed = []

        def fake_terminate(record):
            killed.append(record.pid)
            return {"terminated": True, "reason": "ok"}

        result = launch_practice.cleanup_session(
            session,
            FakeEnumerator(processes),
            live_install_root=root / "live",
            terminate=fake_terminate,
            staging_root=staging_root,
        )
        assert result["ok"], result
        assert killed == [10]
        skipped = next(a for a in result["actions"] if a["pid"] == 20)
        assert skipped["action"] == "skip" and skipped["reason"] == "not_owned"


def test_cleanup_refuses_when_handle_identity_mismatch():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        owned_exe = str(staging_root / "roles" / "ai" / "install" / "Balatro.exe")
        session = launch_practice.write_session(
            staging_root, "s", [launch_practice.ProcessRecord("ai", 10, 500.0, owned_exe, "s")]
        )

        def stale_terminate(record):
            return {"terminated": False, "reason": "handle_create_time_mismatch"}

        result = launch_practice.cleanup_session(
            session,
            FakeEnumerator([launch_practice.ProcessInfo(10, 500.2, owned_exe, name="Balatro")]),
            live_install_root=root / "live",
            terminate=stale_terminate,
            staging_root=staging_root,
        )
        assert result["ok"]
        assert result["actions"][0]["action"] == "refused"
        assert result["actions"][0]["reason"] == "handle_create_time_mismatch"


def test_terminate_verified_record_revalidates_on_the_same_handle():
    record = launch_practice.ProcessRecord("ai", 77, 1000.0, r"C:\stage\roles\ai\install\Balatro.exe", "s")
    good = FakeNativeHandle(1000.2, record.image_path)
    outcome = launch_practice.terminate_verified_record(record, open_handle=lambda pid: good)
    assert outcome["terminated"] is True and outcome["reason"] == "ok"
    assert good.terminated == 1 and good.closed == 1

    stale_time = FakeNativeHandle(9999.0, record.image_path)
    outcome = launch_practice.terminate_verified_record(record, open_handle=lambda pid: stale_time)
    assert not outcome["terminated"] and outcome["reason"] == "handle_create_time_mismatch"
    assert stale_time.terminated == 0 and stale_time.closed == 1

    reused_image = FakeNativeHandle(1000.2, r"C:\other\Balatro.exe")
    outcome = launch_practice.terminate_verified_record(record, open_handle=lambda pid: reused_image)
    assert not outcome["terminated"] and outcome["reason"] == "handle_image_mismatch"

    blind = FakeNativeHandle(None, record.image_path)
    outcome = launch_practice.terminate_verified_record(record, open_handle=lambda pid: blind)
    assert not outcome["terminated"] and outcome["reason"] == "handle_create_time_unavailable"

    outcome = launch_practice.terminate_verified_record(record, open_handle=lambda pid: None)
    assert not outcome["terminated"] and outcome["reason"] == "handle_open_failed"


def test_parse_process_json_fails_closed_on_balatro_without_path():
    normal = json.dumps([{"pid": 1, "name": "explorer", "path": "C:/Windows/explorer.exe", "start": None}])
    infos = launch_practice.parse_process_json(normal)
    assert infos[0].pid == 1 and infos[0].name == "explorer"
    blind = json.dumps([{"pid": 5, "name": "Balatro", "path": None, "start": None}])
    try:
        launch_practice.parse_process_json(blind)
    except staging.StagingError as error:
        assert error.code == "process_enumeration_incomplete"
    else:
        raise AssertionError("expected process_enumeration_incomplete")


def test_parse_process_json_allows_non_balatro_without_path():
    text = json.dumps([{"pid": 6, "name": "System", "path": None, "start": None}])
    infos = launch_practice.parse_process_json(text)
    assert infos[0].pid == 6 and infos[0].image_path == ""


def test_check_no_staged_session_refuses_and_ignores_owned():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        staged = str(staging_root / "roles" / "ai" / "install" / "Balatro.exe")
        enumerator = FakeEnumerator([launch_practice.ProcessInfo(9, 1.0, staged, name="Balatro")])
        verdict = launch_practice.check_no_staged_session(enumerator, staging_root, root / "live")
        assert not verdict["ok"] and verdict["code"] == "staged_session_running" and verdict["pids"] == [9]
        ignored = launch_practice.check_no_staged_session(enumerator, staging_root, root / "live", ignore_pids=[9])
        assert ignored["ok"]
        unavailable = launch_practice.check_no_staged_session(
            launch_practice.UnavailableProcessEnumerator(), staging_root, root / "live"
        )
        assert not unavailable["ok"]
        assert unavailable["code"] == "process_enumeration_unavailable"


def test_overlap_gate_uses_explicit_install_root():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install = root / "customlib" / "steamapps" / "common" / "Aquarium"
        install.mkdir(parents=True)
        appdata = root / "appdata"
        steam_root = root / "Steam"
        overlapping = launch_practice._overlap_gate(install / "staging", install, appdata, steam_root)
        assert not overlapping["ok"] and overlapping["code"] == "staging_overlaps_live"
        clear = launch_practice._overlap_gate(root / "staging", install, appdata, steam_root)
        assert clear["ok"], clear


def test_spawn_verified_uses_handles_and_pinned_nonce_env():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        spawned = []
        jobs = []

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            spawned.append({"command": command, "env": env, "cwd": cwd, "flags": creationflags})
            return FakeProc(7001)

        def job_factory():
            job = FakeJob()
            jobs.append(job)
            return job

        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1000.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="nonce123",
                job_factory=job_factory,
                resume=lambda process: True,
            )
        assert result["ok"] and result["code"] == "launched", result
        assert isinstance(result, launch_practice.LaunchSession)
        assert spawned[0]["env"][launch_practice.PROBE_NONCE_VAR] == "nonce123"
        assert spawned[0]["command"] == [
            fresh["roles"]["ai"]["exe"],
            "--mod-dir",
            str(staging.role_paths(staging_root, "ai").mods),
        ]
        assert spawned[0]["env"]["LOVELY_MOD_DIR"] == _pinned_env(staging.role_paths(staging_root, "ai"))["LOVELY_MOD_DIR"]
        assert jobs and jobs[0].assigned == 1
        if __import__("os").name == "nt":
            assert spawned[0]["flags"] == launch_practice.CREATE_SUSPENDED
        assert len(result.handles) == 1 and result.handles[0].pid == 7001
        assert result.is_running()[0]["running"] is True
        assert jobs[0].closed == 0
        session = json.loads(Path(result["session_file"]).read_text(encoding="utf-8"))
        assert session["nonce"] == "nonce123" and session["spawn_time"]
        result.close()
        assert jobs[0].closed == 1


def test_spawn_verified_requires_a_nonce():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        result = launch_practice._spawn_verified(
            fresh,
            lambda *a, **k: FakeProc(1),
            lambda process: 1.0,
            FakeEnumerator([]),
            root / "live",
            staging_root,
            nonce="",
        )
        assert result["code"] == "session_nonce_required"


def test_spawn_verified_requires_mandatory_job_and_aborts_before_resume():
    if __import__("os").name != "nt":
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        resumed = []
        spawned = []

        def popen(*args, **kwargs):
            spawned.append(args)
            raise AssertionError("must not spawn without a mandatory Job Object")

        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: None,
                resume=lambda process: resumed.append(process) or True,
            )
        assert result["code"] == "job_object_unavailable", result
        assert resumed == []
        assert spawned == []


def test_spawn_verified_does_not_spawn_when_mandatory_job_unavailable():
    if __import__("os").name != "nt":
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        calls = []

        def popen(*args, **kwargs):
            calls.append(args)
            raise AssertionError("Popen must not run without a Job Object")

        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: None,
            )
        assert result["code"] == "job_object_unavailable", result
        assert calls == []


def test_spawn_verified_typeerror_never_retries_unsuspended_and_closes_job():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        job = FakeJob()
        calls = []

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            calls.append({"command": command, "flags": creationflags})
            raise TypeError("'creationflags' is an unexpected keyword argument")

        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: job,
                resume=lambda process: True,
            )
        assert result["code"] == "spawn_flags_unsupported", result
        assert len(calls) == 1, calls
        if __import__("os").name == "nt":
            assert calls[0]["flags"] == launch_practice.CREATE_SUSPENDED
        assert job.closed == 1
        assert job.assigned == 0
        assert result.handles == () and result.records == []
        assert result["rolled_back"] is False


def test_spawn_verified_spawn_failure_closes_job_without_orphan():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        job = FakeJob()

        def popen(*args, **kwargs):
            raise OSError("cannot create process")

        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: job,
                resume=lambda process: True,
            )
        assert result["code"] == "spawn_failed", result
        assert job.closed == 1 and job.assigned == 0
        assert result.handles == () and result.records == []
        assert result["rolled_back"] is False


def test_spawn_verified_aborts_on_job_assignment_failure():
    class FailingJob(FakeJob):
        def assign(self, process):
            self.assigned += 1
            return False

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        proc = FakeProc(7003)
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: proc,
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: FailingJob(),
                resume=lambda process: True,
            )
        assert result["code"] == "job_object_assignment_failed", result
        assert proc.alive is False


def test_spawn_verified_rejects_mod_dir_command_mismatch():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        fresh["roles"]["ai"]["command"] = [fresh["roles"]["ai"]["exe"]]
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: FakeProc(1),
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: FakeJob(),
                resume=lambda process: True,
            )
        assert result["code"] == "mod_dir_command_mismatch", result


def test_spawn_verified_rolls_back_owned_handles_on_missing_create_time():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        for role in ("human", "ai"):
            _fake_role_tree(staging_root, role)
        fresh = _fresh_plan(staging_root, ("human", "ai"))
        procs = []

        def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
            process = FakeProc(8100 + len(procs))
            procs.append(process)
            return process

        terminated = []
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: None if process.pid == 8101 else 1000.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
                on_terminate=lambda process: terminated.append(process.pid),
                job_factory=lambda: FakeJob(),
                resume=lambda process: True,
            )
        assert result["code"] == "create_time_unavailable", result
        assert result["rolled_back"] is True
        assert sorted(terminated) == [8100, 8101]
        assert all(not process.alive for process in procs)


def test_spawn_verified_refuses_duplicate_staged_session():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _paths, executable = _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        spawned = []

        def popen(*args, **kwargs):
            spawned.append(args)
            return FakeProc(1)

        enumerator = FakeEnumerator(
            [launch_practice.ProcessInfo(9, 1.0, str(executable), name="Balatro")]
        )
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                popen,
                lambda process: 1.0,
                enumerator,
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: FakeJob(),
                resume=lambda process: True,
            )
        assert result["code"] == "staged_session_running", result
        assert spawned == []


def test_spawn_verified_refuses_foreign_balatro_outside_staging():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        spawned = []
        other_install = root / "other_library" / "Balatro" / "Balatro.exe"
        enumerator = FakeEnumerator(
            [launch_practice.ProcessInfo(15, 1.0, str(other_install), name="Balatro")]
        )
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: spawned.append(a) or FakeProc(1),
                lambda process: 1.0,
                enumerator,
                root / "live",
                staging_root,
                nonce="n" * 32,
                job_factory=lambda: FakeJob(),
                resume=lambda process: True,
            )
        assert result["code"] == "foreign_balatro_running", result
        assert spawned == []


def test_spawn_verified_requires_exe_binding():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai", binding=False)
        fresh = _fresh_plan(staging_root, ("ai",))
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: FakeProc(1),
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
            )
        assert result["code"] == "staged_exe_binding_missing", result


def test_spawn_verified_refuses_staged_steam_native():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai", steam_native=True)
        fresh = _fresh_plan(staging_root, ("ai",))
        with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: FakeProc(1),
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
            )
        assert result["code"] == "staged_steam_native_present", result


def test_env_gate_requires_pinned_mods_and_strips_injection():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        with patched(staging, role_environment=lambda paths: {
            "APPDATA": str(paths.data),
            "USERPROFILE": str(paths.userprofile),
            "TEMP": str(paths.temp),
        }):
            gate = launch_practice._env_gate(staging_root, "ai")
        assert not gate["ok"] and "lovely_mod_dir_missing" in gate["problems"]
        with patched(staging, role_environment=lambda paths: {
            **_pinned_env(paths),
            "LOVELY_CACHE": "x",
            "STEAM_APP_ID": "1",
            "PYTHONPATH": "y",
        }):
            gate = launch_practice._env_gate(staging_root, "ai")
        assert not gate["ok"]
        assert "inherited:LOVELY_CACHE" in gate["problems"]
        assert "inherited:STEAM_APP_ID" in gate["problems"]
        assert "inherited:PYTHONPATH" in gate["problems"]


def test_spawn_verified_rejects_unsafe_role_environment():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        _fake_role_tree(staging_root, "ai")
        fresh = _fresh_plan(staging_root, ("ai",))
        with patched(staging, role_environment=lambda paths: {"APPDATA": str(paths.data)}):
            result = launch_practice._spawn_verified(
                fresh,
                lambda *a, **k: FakeProc(1),
                lambda process: 1.0,
                FakeEnumerator([]),
                root / "live",
                staging_root,
                nonce="n" * 32,
            )
        assert result["code"] == "role_environment_unsafe", result


def _persist_open_record(staging_root, session_id, *, phase="P1B", nonce="n" * 32, pids=None):
    record = {
        "schema": ic.OPEN_SESSION_SCHEMA,
        "session_id": session_id,
        "phase": phase,
        "nonce": nonce,
        "port": 8788,
        "certificate_id": None,
        "backup_id": "a" * 64,
        "pids": pids or {},
        "status": "open",
    }
    ic._write_open_record(staging_root, record)
    return record


def test_execute_launch_ignores_forged_may_launch_and_reloads_record():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        staging_root.mkdir(parents=True)
        _persist_open_record(staging_root, "forged", phase="P1B")
        forged = {
            "may_launch": True,
            "blocked": [],
            "session_id": "forged",
            "staging_root": str(staging_root),
            "live_install_root": str(root / "live"),
            "backup_root": str(root / "backups"),
            "port": 8788,
        }
        open_session = {"status": "open", "session_id": "forged", "nonce": "n" * 32, "phase": "P1B"}
        called = []

        def popen(*args, **kwargs):
            called.append(args)
            raise AssertionError("must not spawn when fresh gates fail")

        result = launch_practice.execute_launch(
            forged,
            enumerator=FakeEnumerator([]),
            popen=popen,
            live_appdata_root=root / "appdata",
            steam_root=root / "Steam",
            open_session=open_session,
            require_certificate=False,
        )
        assert result["code"] == "launch_blocked", result
        assert called == []


def test_execute_launch_requires_an_open_session():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        result = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "x"},
            enumerator=FakeEnumerator([]),
            popen=lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not spawn")),
        )
        assert result["code"] == "open_session_required", result


def test_execute_launch_refuses_fabricated_open_session_mapping():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        staging_root.mkdir(parents=True)
        called = []

        def popen(*args, **kwargs):
            called.append(args)
            raise AssertionError("must not spawn without a persisted open record")

        result = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "ghost"},
            enumerator=FakeEnumerator([]),
            open_session={"status": "open", "session_id": "ghost", "nonce": "n" * 32, "phase": "P1B"},
            popen=popen,
            require_certificate=False,
        )
        assert result["code"] == "open_session_missing", result
        assert called == []


def test_execute_launch_descriptors_require_match_phase():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        staging_root.mkdir(parents=True)
        _persist_open_record(staging_root, "x", phase="P1A", nonce="n" * 32)
        result = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "x"},
            enumerator=FakeEnumerator([]),
            open_session={"status": "open", "session_id": "x", "nonce": "n" * 32, "phase": "P1A"},
            session_descriptors={"ai": object()},
            popen=lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not spawn")),
        )
        assert result["code"] == "session_descriptors_require_match_phase", result


def test_bootstrap_plan_gates_on_preflight_not_postproof():
    calls = {"preflight": 0, "evidence": 0}

    def fake_preflight(staging_root):
        calls["preflight"] += 1
        return {"ok": True, "code": "ok"}

    def fake_evidence(staging_root, expected_nonce=None, spawn_time=None):
        calls["evidence"] += 1
        return {"ok": True}

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        with patched(
            staging,
            check_bootstrap_preflight=fake_preflight,
            check_bootstrap_evidence=fake_evidence,
        ):
            plan = launch_practice.build_bootstrap_plan(
                staging_root=staging_root,
                live_install_root=root / "live",
                backup_root=root / "backups",
                enumerator=FakeEnumerator([]),
                live_appdata_root=root / "appdata",
                steam_root=root / "Steam",
            )
    assert "bootstrap_preflight" in plan["gates"]
    assert "bootstrap_evidence" not in plan["gates"]
    assert plan["gates"]["bootstrap_preflight"]["ok"] is True
    assert calls["preflight"] == 1 and calls["evidence"] == 0


def test_bootstrap_plan_reports_missing_preflight_api():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        saved = getattr(staging, "check_bootstrap_preflight", _MISSING)
        if saved is not _MISSING:
            delattr(staging, "check_bootstrap_preflight")
        try:
            gate = launch_practice._api_gate(staging_root, "check_bootstrap_preflight")
        finally:
            if saved is not _MISSING:
                setattr(staging, "check_bootstrap_preflight", saved)
        assert not gate["ok"] and gate["code"] == "staging_api_missing"


def test_launch_plan_verifies_all_roles_and_blocks():
    calls = []

    def fake_verify(staging_root, role):
        calls.append(role)
        return {"ok": True, "code": "ok"}

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        with patched(staging, verify_staged_role=fake_verify):
            plan = launch_practice.build_launch_plan(
                staging_root=staging_root,
                live_install_root=root / "live",
                backup_root=root / "backups",
                enumerator=FakeEnumerator([]),
                live_appdata_root=root / "appdata",
                steam_root=root / "Steam",
            )
    assert sorted(calls) == ["ai", "human"]
    assert plan["gates"]["staged_roles"]["ok"] is True
    assert "staged_roles" in plan["gates"]
    assert "backup_evidence" in plan["blocked"]


def test_backup_covers_all_steam_profiles_and_detects_stale_live():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install, appdata, profiles = _make_live_tree(root)
        backup_root = root / "backups"
        created = launch_practice.create_live_backup(
            install_root=install,
            appdata_root=appdata,
            steam_userdata_roots=list(profiles.values()),
            backup_root=backup_root,
            enumerator=FakeEnumerator([]),
            live_install_root=install,
            label="one",
            execute=True,
        )
        assert created["ok"], created
        assert set(created["entries"]) == {
            "install",
            "appdata",
            "steam_userdata/390025789",
            "steam_userdata/111111111",
        }
        sources = launch_practice.live_source_map(install, appdata, steam_root=root / "Steam")
        assert launch_practice.check_backup_evidence(backup_root, sources)["ok"]
        for entry in created["entries"].values():
            manifest_path = Path(entry["manifest"])
            assert manifest_path.is_file()
            assert not staging.is_within(entry["dir"], manifest_path, allow_root=True)
        (appdata / "save.jkr").write_bytes(b"changed")
        verdict = launch_practice.check_backup_evidence(backup_root, sources)
        assert not verdict["ok"]
        assert "appdata_live_changed_since_backup" in verdict["problems"]


def test_backup_copy_mismatch_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install, appdata, profiles = _make_live_tree(root)
        backup_root = root / "backups"

        real_copytree = __import__("shutil").copytree

        def corrupt_copytree(source, destination, *args, **kwargs):
            result = real_copytree(source, destination, *args, **kwargs)
            target = Path(destination) / "tampered.bin"
            target.write_bytes(b"tampered")
            return result

        shutil = __import__("shutil")
        saved = shutil.copytree
        shutil.copytree = corrupt_copytree
        try:
            result = launch_practice.create_live_backup(
                install_root=install,
                appdata_root=appdata,
                steam_userdata_roots=list(profiles.values()),
                backup_root=backup_root,
                enumerator=FakeEnumerator([]),
                live_install_root=install,
                label="torn",
                execute=True,
            )
        finally:
            shutil.copytree = saved
        assert not result["ok"] and result["code"] == "backup_copy_mismatch"


def test_verify_backup_entry_rejects_arbitrary_paths_and_inside_manifests():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        outside = {
            "dir": str(root / "copied"),
            "manifest": str(root / "copied" / "manifest.json"),
        }
        verdict = launch_practice.verify_backup_entry(outside, backup_root=root / "backups")
        assert not verdict["ok"] and verdict["code"] == "backup_entry_outside_root"

        backup_root = root / "backups"
        copy_dir = backup_root / "install"
        copy_dir.mkdir(parents=True)
        inside = copy_dir / "manifest.json"
        inside.write_text("{}", encoding="utf-8")
        verdict = launch_practice.verify_backup_entry(
            {"dir": str(copy_dir), "manifest": str(inside)}, backup_root=backup_root
        )
        assert not verdict["ok"] and verdict["code"] == "backup_manifest_inside_copy"


def test_backup_requires_closed_and_steam_profiles():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install, appdata, profiles = _make_live_tree(root)
        backup_root = root / "backups"
        refused = launch_practice.create_live_backup(
            install_root=install,
            appdata_root=appdata,
            steam_userdata_roots=list(profiles.values()),
            backup_root=backup_root,
            enumerator=FakeEnumerator(
                [launch_practice.ProcessInfo(1, 1.0, str(install / "Balatro.exe"), name="Balatro")]
            ),
            live_install_root=install,
            execute=True,
        )
        assert not refused["ok"] and refused["code"] == "live_process_running"
        missing = launch_practice.create_live_backup(
            install_root=install,
            appdata_root=appdata,
            steam_userdata_roots=[],
            backup_root=backup_root,
            enumerator=FakeEnumerator([]),
            live_install_root=install,
            execute=True,
        )
        assert not missing["ok"] and missing["code"] == "steam_userdata_missing"


def test_check_backup_evidence_rejects_unbound_sources():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        install, appdata, profiles = _make_live_tree(root)
        backup_root = root / "backups"
        launch_practice.create_live_backup(
            install_root=install,
            appdata_root=appdata,
            steam_userdata_roots=list(profiles.values()),
            backup_root=backup_root,
            enumerator=FakeEnumerator([]),
            live_install_root=install,
            label="two",
            execute=True,
        )
        wrong = launch_practice.live_source_map(root / "other_install", appdata, steam_root=root / "Steam")
        verdict = launch_practice.check_backup_evidence(backup_root, wrong)
        assert not verdict["ok"]
        assert "install_source_mismatch" in verdict["problems"]


def _live_session(tmp, pid=4242, alive=True):
    proc = FakeProc(pid)
    proc.alive = alive
    job = FakeJob()
    owned = [launch_practice.OwnedProcess("ai", proc, pid, 1.0, str(Path(tmp) / "Balatro.exe"), job=job)]
    session = launch_practice.LaunchSession(
        "s", Path(tmp), [], owned, "nonce", 1.0, code="launched"
    )
    return session, proc, job


def test_launch_session_retains_handles_until_close():
    with tempfile.TemporaryDirectory() as tmp:
        session, proc, job = _live_session(tmp)
        assert session.ok
        assert len(session.handles) == 1 and session.handles[0].pid == 4242
        assert session.is_running()[0]["running"] is True
        assert job.closed == 0
        payload = session.to_dict()
        assert "handles" not in payload and "owned" not in payload
        assert payload["ok"] is True and payload["session_id"] == "s"
        session.close()
        assert job.closed == 1


def test_supervise_session_waits_for_owned_exit():
    with tempfile.TemporaryDirectory() as tmp:
        session, proc, job = _live_session(tmp, alive=False)
        result = launch_practice.supervise_session(session, timeout=5, poll_interval=0.01)
        assert result["ok"] and result["code"] == "supervision_exited"
        assert job.terminated == 0


def test_supervise_session_timeout_terminates_owned_only():
    with tempfile.TemporaryDirectory() as tmp:
        session, proc, job = _live_session(tmp, alive=True)
        result = launch_practice.supervise_session(session, timeout=0.05, poll_interval=0.02)
        assert not result["ok"] and result["code"] == "supervision_timeout"
        assert proc.alive is False
        assert job.terminated >= 1
        assert launch_practice.supervise_session({"ok": True})["code"] == "not_a_live_session"


def test_cli_launch_is_host_only_and_refuses_bare_launch():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        called = []

        def fake_execute(*args, **kwargs):
            called.append(args)
            raise AssertionError("bare CLI launch must never spawn")

        with patched(launch_practice, execute_launch=fake_execute):
            code = launch_practice.main(
                [
                    "launch",
                    "--staging-root",
                    str(staging_root),
                    "--install",
                    str(Path(tmp) / "live"),
                    "--backup-root",
                    str(Path(tmp) / "backups"),
                    "--appdata",
                    str(Path(tmp) / "appdata"),
                    "--steam-root",
                    str(Path(tmp) / "Steam"),
                ]
            )
        assert code == 3
        assert called == []


def _descriptor(staging_root, role, nonce="n" * 32, credential=None, content="c" * 64, port=5555, save_root=None, mods_root=None, mode="normal", gauntlet="", difficulty="competitive", pacing="instant"):
    paths = staging.role_paths(staging_root, role)
    return launch_practice.SessionDescriptor(
        role=role,
        session_id="sess-1",
        role_credential=credential or ("h" * 64 if role == "human" else "a" * 64),
        control_port=port,
        content_hash=content,
        probe_nonce=nonce,
        expected_role_save_root=str(save_root if save_root is not None else paths.data / "Balatro"),
        expected_role_mods_root=str(mods_root if mods_root is not None else paths.mods),
        mode=mode,
        difficulty=difficulty,
        pacing=pacing,
        gauntlet=gauntlet,
    )


def _spawn_with_descriptor(staging_root, role, descriptors, nonce="n" * 32, create_time=lambda process: 1000.0):
    _fake_role_tree(staging_root, role)
    fresh = _fresh_plan(staging_root, (role,))
    spawned = []

    def popen(command, cwd=None, env=None, close_fds=None, creationflags=0):
        spawned.append({"command": command, "env": env, "cwd": cwd, "flags": creationflags})
        return FakeProc(9001)

    with patched(staging, role_environment=lambda paths: _pinned_env(paths)):
        result = launch_practice._spawn_verified(
            fresh,
            popen,
            create_time,
            FakeEnumerator([]),
            Path(staging_root).parent / "live",
            staging_root,
            nonce=nonce,
            job_factory=lambda: FakeJob(),
            resume=lambda process: True,
            session_descriptors=descriptors,
        )
    return result, spawned


def test_session_descriptor_env_is_strict_and_allowlisted():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        role = "ai"
        paths = staging.role_paths(staging_root, role)
        result, spawned = _spawn_with_descriptor(
            staging_root, role, {role: _descriptor(staging_root, role)}
        )
        assert result["ok"] and isinstance(result, launch_practice.LaunchSession), result
        assert result.handles and result.handles[0].pid == 9001
        env = spawned[0]["env"]
        assert set(launch_practice.SESSION_ENV_KEYS.values()).issubset(env)
        assert env["AISP_CONTROL_PORT"] == "5555"
        assert env["AISP_PROBE_NONCE"] == "n" * 32
        assert env["AISP_EXPECTED_ROLE_SAVE_ROOT"] == str(paths.data / "Balatro")
        assert env["AISP_EXPECTED_ROLE_MODS_ROOT"] == str(paths.mods)
        assert env["AISP_MODE"] == "normal" and env["AISP_GAUNTLET"] == ""
        assert env["AISP_DIFFICULTY"] == "competitive" and env["AISP_PACING"] == "instant"
        # The descriptor never overrides pinned paths/Lovely values.
        assert env["LOVELY_MOD_DIR"] == _pinned_env(paths)["LOVELY_MOD_DIR"]
        assert env["APPDATA"] == str(paths.data)
        assert env["BALATRO_AI_ISOLATION"] == "unproven"
        if __import__("os").name == "nt":
            assert spawned[0]["flags"] == launch_practice.CREATE_SUSPENDED


def test_spawn_verified_requires_typed_descriptor_not_plain_dict():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        result, spawned = _spawn_with_descriptor(
            staging_root, "ai", {"ai": {"AISP_SESSION_ID": "sess-1"}}
        )
        assert result["code"] == "session_descriptor_required", result
        assert spawned == []


def test_spawn_verified_rejects_descriptor_nonce_and_save_root():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        wrong_nonce = _descriptor(staging_root, "ai", nonce="x" * 32)
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": wrong_nonce})
        assert result["code"] == "session_descriptor_nonce_mismatch", result
        assert spawned == []

        wrong_root = _descriptor(staging_root, "ai", save_root=str(Path(tmp) / "elsewhere"))
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": wrong_root})
        assert result["code"] == "session_descriptor_bad_save_root", result
        assert spawned == []


def test_spawn_verified_rejects_descriptor_mods_root_and_enums():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        wrong_mods = _descriptor(staging_root, "ai", mods_root=str(Path(tmp) / "elsewhere"))
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": wrong_mods})
        assert result["code"] == "session_descriptor_bad_mods_root", result
        assert spawned == []

        bad_mode = _descriptor(staging_root, "ai", mode="ranked")
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": bad_mode})
        assert result["code"] == "session_descriptor_bad_mode", result
        assert spawned == []

        bad_gauntlet = _descriptor(staging_root, "ai", mode="gauntlet", gauntlet="Test9")
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": bad_gauntlet})
        assert result["code"] == "session_descriptor_bad_gauntlet", result
        assert spawned == []

        gauntlet_leak = _descriptor(staging_root, "ai", mode="normal", gauntlet="Test1")
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {"ai": gauntlet_leak})
        assert result["code"] == "session_descriptor_bad_gauntlet", result
        assert spawned == []


def test_spawn_verified_requires_descriptor_for_every_role():
    with tempfile.TemporaryDirectory() as tmp:
        staging_root = Path(tmp) / "staging"
        result, spawned = _spawn_with_descriptor(staging_root, "ai", {})
        assert result["code"] == "session_descriptor_missing", result
        assert spawned == []


def test_supervise_session_aborts_owned_only_on_unexpected_balatro():
    with tempfile.TemporaryDirectory() as tmp:
        session, proc, job = _live_session(tmp, alive=True)
        result = launch_practice.supervise_session(
            session,
            timeout=5,
            poll_interval=0.01,
            unexpected_check=lambda statuses: {"ok": False, "code": "foreign_balatro_running"},
        )
        assert not result["ok"] and result["code"] == "foreign_balatro_running"
        assert proc.alive is False and job.terminated >= 1


def test_execute_launch_refuses_mismatched_open_session_fields():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        staging_root = root / "staging"
        staging_root.mkdir(parents=True)
        _persist_open_record(staging_root, "m1", phase="P1B", nonce="n" * 32)

        def must_not_spawn(*args, **kwargs):
            raise AssertionError("must not spawn")

        wrong_nonce = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "m1"},
            enumerator=FakeEnumerator([]),
            open_session={"status": "open", "session_id": "m1", "nonce": "x" * 32, "phase": "P1B"},
            popen=must_not_spawn,
            require_certificate=False,
        )
        assert wrong_nonce["code"] == "open_session_nonce_mismatch", wrong_nonce

        wrong_phase = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "m1"},
            enumerator=FakeEnumerator([]),
            open_session={"status": "open", "session_id": "m1", "nonce": "n" * 32, "phase": "MATCH"},
            popen=must_not_spawn,
            require_certificate=False,
        )
        assert wrong_phase["code"] == "open_session_phase_mismatch", wrong_phase

        _persist_open_record(staging_root, "m1-bound", phase="P1B", nonce="n" * 32, pids={"ai": [7]})
        bound = launch_practice.execute_launch(
            {"staging_root": str(staging_root), "session_id": "m1-bound"},
            enumerator=FakeEnumerator([]),
            open_session={"status": "open", "session_id": "m1-bound", "nonce": "n" * 32, "phase": "P1B"},
            popen=must_not_spawn,
            require_certificate=False,
        )
        assert bound["code"] == "open_session_pids_bound", bound


def test_cli_bootstrap_timeout_is_wired_to_the_measurement_run():
    with tempfile.TemporaryDirectory() as tmp:
        captured = {}

        def fake_execute(*args, **kwargs):
            captured.update(kwargs)
            return {"receipt": {"ok": True}}

        with patched(launch_practice, execute_measurement_phase=fake_execute):
            code = launch_practice.main(
                ["bootstrap", "--execute", "--timeout", "4.25", "--staging-root", str(Path(tmp) / "staging")]
            )
        assert code == 0
        assert captured.get("timeout") == 4.25


class _FakeListenSocket:
    def __init__(self):
        self.closed = False
        self.bound = None

    def setsockopt(self, *args):
        pass

    def bind(self, endpoint):
        self.bound = endpoint

    def listen(self, *args):
        pass

    def settimeout(self, value):
        pass

    def close(self):
        self.closed = True


class _FakeSockets:
    AF_INET = 2
    SOCK_STREAM = 1
    SOL_SOCKET = 1
    SO_EXCLUSIVEADDRUSE = 4
    SHUT_WR = 1

    def __init__(self):
        self.last = None

    def socket(self, *args):
        self.last = _FakeListenSocket()
        return self.last


class _NoThreads:
    Event = threading.Event

    class Thread:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

        def join(self, *args, **kwargs):
            pass


class _FakeConn:
    def __init__(self, recvs):
        self._recvs = list(recvs)
        self.calls = 0
        self.closed = False
        self.shutdowns = 0

    def settimeout(self, *args):
        pass

    def recv(self, *args):
        self.calls += 1
        if self._recvs:
            return self._recvs.pop(0)
        raise TimeoutError("drain complete")

    def shutdown(self, *args):
        self.shutdowns += 1
        raise OSError("shutdown did not succeed")

    def close(self):
        self.closed = True


class _FakeAcceptServer:
    def __init__(self, conn, addr=("127.0.0.1", 49123)):
        self._conn = conn
        self._addr = addr
        self.closed = False

    def accept(self):
        return self._conn, self._addr

    def close(self):
        self.closed = True


PORT = 39123


def _listener(mode="P2_CLOSE", inventory=None, owner_lookup=None, sockets=None):
    return launch_practice.MeasurementListener(
        PORT,
        mode=mode,
        inventory=inventory,
        owner_lookup=owner_lookup or (lambda *args: None),
        socket_mod=sockets or _FakeSockets(),
        threading_mod=_NoThreads,
    )


def test_measurement_listener_requires_exact_owned_pid_and_complete_inventory():
    other = os.getpid() + 100000
    positive = _listener(
        inventory=lambda port: {"ok": True, "code": "ok", "rows": [{"address": "127.0.0.1", "pid": os.getpid()}]}
    )
    assert positive.start()["ok"] is True, "the exact owning PID on loopback is positive proof"

    # An empty table cannot positively prove ownership.
    listener = _listener(inventory=lambda port: {"ok": True, "code": "ok", "rows": []})
    result = listener.start()
    assert result["ok"] is False and listener._socket.last.closed

    # A failed/partial query is distinguished from an empty table and refused.
    listener = _listener(inventory=lambda port: {"ok": False, "code": "inventory_unavailable", "rows": []})
    result = listener.start()
    assert result["ok"] is False and "inventory_unavailable" in result["problems"]
    assert listener._socket.last.closed

    # A listener on ::1 is foreign even when it shares our PID.
    listener = _listener(
        inventory=lambda port: {
            "ok": True,
            "code": "ok",
            "rows": [{"address": "::1", "pid": os.getpid()}, {"address": "127.0.0.1", "pid": os.getpid()}],
        }
    )
    assert listener.start()["ok"] is False and listener._socket.last.closed

    # A second loopback owner refuses.
    listener = _listener(
        inventory=lambda port: {
            "ok": True,
            "code": "ok",
            "rows": [{"address": "127.0.0.1", "pid": os.getpid()}, {"address": "127.0.0.1", "pid": other}],
        }
    )
    assert listener.start()["ok"] is False and listener._socket.last.closed

    # A malformed row fails closed.
    listener = _listener(inventory=lambda port: {"ok": True, "code": "ok", "rows": [{"address": "127.0.0.1"}]})
    result = listener.start()
    assert result["ok"] is False and "listener_inventory_partial" in result["problems"]
    assert listener._socket.last.closed


def test_measurement_listener_silent_eof_does_not_busy_spin_or_extend_the_hold():
    listener = _listener(mode="P2_SILENT", owner_lookup=lambda *args: 12345)
    conn = _FakeConn([b""])
    listener._server = _FakeAcceptServer(conn)
    listener.arm([12345])
    listener._serve()
    state = listener._state
    assert state["peer_eof"] is True and state["peer_is_owned_ai"] is True
    assert state["open_until"] == state["eof_time"], "an honest EOF caps the hold"
    assert conn.calls == 1, "a closed SILENT peer must not busy-spin"
    assert listener._server is None


def test_measurement_listener_wrong_peer_aborts_promptly_and_nothing_is_sent():
    listener = _listener(mode="P2_SILENT", owner_lookup=lambda *args: os.getpid() + 1)
    conn = _FakeConn([b"data"])
    listener._server = _FakeAcceptServer(conn)
    listener.arm([12345])
    listener._serve()
    assert listener._state["peer_is_owned_ai"] is False
    assert conn.calls == 0 and conn.closed is True, "a wrong peer is never read or held"
    assert listener._state["open_until"] is None

    # A non-loopback observed endpoint is refused before any owner lookup.
    listener = _listener(mode="P2_SILENT", owner_lookup=lambda *args: 12345)
    conn = _FakeConn([b"data"])
    listener._server = _FakeAcceptServer(conn, addr=("192.168.1.5", 49123))
    listener.arm([12345])
    listener._serve()
    assert listener._state["peer_is_owned_ai"] is False
    assert "listener_peer_endpoint_not_loopback" in listener._state["problems"]
    assert conn.calls == 0 and conn.closed is True


def test_measurement_listener_logs_bounded_actions_and_never_sends():
    limit = int(staging.LISTENER_MAX_RECEIVED_BYTES)
    listener = _listener(mode="P2_CLOSE", owner_lookup=lambda *args: 12345)
    conn = _FakeConn([b'{"action":"keepAlive"}\n{"action":"keepAlive"}\n{"action":"join"}\n', b"z" * (limit + 32)])
    listener._server = _FakeAcceptServer(conn)
    listener.arm([12345])
    listener._serve()
    fields = listener.log_fields("nonce", "P2_CLOSE")
    assert fields["sent_bytes"] == 0
    assert fields["actions"] == "keepAlive,join"
    assert fields["action_count"] == 2
    assert fields["received_bytes"] == limit, "retention is bounded"
    assert fields["fin"] is False, "a failed shutdown is never a successful FIN"


def test_measurement_listener_silent_receive_timeout_is_not_a_peer_eof():
    listener = _listener(mode="P2_SILENT", owner_lookup=lambda *args: 12345)

    class _IdleConn:
        def __init__(self, stop):
            self._stop = stop
            self.calls = 0

        def settimeout(self, *args):
            pass

        def recv(self, *args):
            self.calls += 1
            self._stop.set()
            raise TimeoutError("idle")

        def shutdown(self, *args):
            raise OSError("no")

        def close(self):
            pass

    conn = _IdleConn(listener._stop)
    listener._server = _FakeAcceptServer(conn)
    listener.arm([12345])
    listener._serve()
    assert listener._state["peer_eof"] is False, "a recv timeout is not an EOF"
    assert listener._state["open_until"] is not None
    assert conn.calls == 1


class _Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def test_tcp_owner_queries_reverse_client_tuple_and_returns_peer_pid():
    commands: list = []

    def fake_run(args, **kwargs):
        command = args[-1]
        commands.append(command)
        client_side = "-State Established" in command and "-LocalPort 49123" in command and "-RemotePort 39123" in command
        return _Completed(stdout='{"OwningProcess": %d}' % (12345 if client_side else 54321))

    with patched(launch_practice.subprocess, run=fake_run):
        pid = launch_practice._default_tcp_owner(39123, 49123)
    assert pid == 12345, f"queried the listener PID instead of the AI peer PID: {commands}"
    assert "127.0.0.1" in commands[0] and "-State Established" in commands[0]


def test_tcp_owner_refuses_nonzero_malformed_ambiguous_and_missing_owner():
    cases = [
        _Completed(returncode=1, stdout='{"OwningProcess": 12345}'),
        _Completed(stdout="not json"),
        _Completed(stdout=""),
        _Completed(stdout='[{"OwningProcess": 12345}, {"OwningProcess": 54321}]'),
        _Completed(stdout='[{"OwningProcess": 12345}, {"OwningProcess": 12345}]'),
        _Completed(stdout='{"OwningProcess": null}'),
        _Completed(stdout='{"OwningProcess": "not-a-pid"}'),
        _Completed(stdout='{"LocalPort": 49123}'),
    ]
    for completed in cases:
        with patched(launch_practice.subprocess, run=lambda *a, _c=completed, **k: _c):
            assert launch_practice._default_tcp_owner(39123, 49123) is None, completed.stdout


def test_tcp_listeners_refuse_nonzero_exit():
    stdout = '{"ok": true, "rows": [{"address": "127.0.0.1", "pid": 1}]}'
    with patched(launch_practice.subprocess, run=lambda *a, **k: _Completed(returncode=1, stdout=stdout)):
        result = launch_practice._default_tcp_listeners(39123)
    assert result["ok"] is False and result["code"] == "inventory_unavailable", result


def test_owned_process_unreadable_handle_does_not_prove_exit():
    class Unreadable:
        def poll(self):
            raise OSError("synthetic query failure")

    owned = launch_practice.OwnedProcess("ai", Unreadable(), 12345, 1.0, "synthetic.exe")
    assert owned.is_running() is True, "an unreadable retained handle cannot prove exit"


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
