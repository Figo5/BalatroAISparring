#!/usr/bin/env python3
"""Practice host tests: daemon auth, lifecycle, certificate, gates, supervision.

Everything runs against synthetic temp trees and injected fakes: no live install,
live %AppData%, Steam tree, game, server, external network or OS process is
touched. The only real socket is a loopback ``127.0.0.1`` daemon round trip and a
real loopback ``PracticeService`` start.

The fixtures assert authorization and lifetime semantics, not success-only
mocks: a wrong secret is rejected, a duplicate live daemon is refused, a live
process is never terminated, the immutable certificate is reused (never rebased),
Steam quiescence and a fresh verified backup are required, both roles must attest
with the session nonce, a new live game voids the session and locks out, owned
handles are terminated and unowned ones are not, a prior open/unmeasured record
blocks a new ticket and acknowledgement, a retained human window is never killed,
and no credential enters the report.
"""
from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
import types
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import isolation_certificate  # noqa: E402
import launch_practice  # noqa: E402
import practice_host  # noqa: E402
import practice_service  # noqa: E402
import ruleset_contract  # noqa: E402
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


class FakeLiveHandle:
    """Query-only stand-in. ``terminate`` must never be called by the host."""

    def __init__(self, create_time, image_path, exited=False):
        self._create_time = create_time
        self._image_path = image_path
        self._exited = exited
        self.closed = 0
        self.terminate_calls = 0

    def create_time(self):
        return self._create_time

    def image_path(self):
        return self._image_path

    def has_exited(self):
        return self._exited

    def close(self):
        self.closed += 1

    def terminate(self, timeout=10.0):
        self.terminate_calls += 1
        return True


class SequenceOpener:
    def __init__(self, handles):
        self.handles = list(handles)
        self.calls = 0

    def __call__(self, pid):
        self.calls += 1
        if self.handles:
            return self.handles.pop(0)
        return None


class FakeEnumerator(launch_practice.ProcessEnumerator):
    def __init__(self, processes=None, error=None):
        self._processes = list(processes or [])
        self._error = error

    def list(self):
        if self._error is not None:
            raise self._error
        return list(self._processes)


class SwitchEnumerator(launch_practice.ProcessEnumerator):
    """Closed for the first ``closed_calls`` listings, then reports ``then``."""

    def __init__(self, closed_calls, then):
        self.closed_calls = int(closed_calls)
        self.then = list(then)
        self.calls = 0

    def list(self):
        self.calls += 1
        return [] if self.calls <= self.closed_calls else list(self.then)


class FakeClock:
    def __init__(self, step=0.5):
        self.t = 0.0
        self.step = step

    def __call__(self):
        self.t += self.step
        return self.t


class FakeListenerProbe:
    def __init__(self, ports):
        self.ports = {int(port): value for port, value in ports.items()}

    def probe(self, port):
        return dict(self.ports.get(int(port), {"listening": False, "addresses": [], "pids": [], "source": "fake"}))


class FakeRole:
    def __init__(self, role, pid=1):
        self.role = role
        self.pid = pid
        self.running = True
        self.terminated = 0

    def is_running(self):
        return self.running

    def terminate(self, timeout=10.0):
        self.terminated += 1
        self.running = False
        return {"role": self.role, "pid": self.pid, "terminated": True}


class FakeSession:
    def __init__(self, roles=("human", "ai"), ok=True, code="launched", spawn_time=1000.0):
        self.ok = ok
        self.code = code
        self.spawn_time = spawn_time
        self.owned = [FakeRole(role, pid=100 + index) for index, role in enumerate(roles)]
        self.records = [
            types.SimpleNamespace(role=role, pid=100 + index, create_time=1000.0, image_path=f"staged/{role}")
            for index, role in enumerate(roles)
        ]
        self.closed = 0

    def is_running(self):
        return [{"role": item.role, "pid": item.pid, "running": item.running} for item in self.owned]

    def close(self):
        self.closed += 1


class FakeServer:
    def __init__(self, running=True, pid=4242):
        self.running = running
        self.pid = pid
        self.terminated = 0

    def is_running(self):
        return self.running

    def terminate(self, timeout=10.0):
        self.terminated += 1
        self.running = False
        return {"role": "server", "terminated": True}


class FakeService:
    def __init__(self, config, *, ended=False, aborted=False, port=51234, terminal_phase="none", events=None):
        self.config = config
        self.expected_config_digest = getattr(config, "expected_config_digest", None)
        self.human_credential = "h1" * 32
        self.ai_credential = "a2" * 32
        self.port = port
        self.started = False
        self.ended = ended
        self.aborted = aborted
        self.closed = 0
        self.abort_calls = 0
        self.terminal_phase = terminal_phase
        # Mirror the real PracticeService lifecycle surface (H-C): the terminal
        # reason is only ``human_end`` for a normal completion.
        self.terminal_reason = "human_end" if ended else None
        self.ai_receipt_grace = 0.0
        self.attested = False
        self.attest_calls = []
        self.attest_digest = None
        self.prestart_calls = 0
        self._events = events

    def _record(self, name):
        if self._events is not None:
            self._events.append(name)

    def start(self):
        self.started = True
        return self.port

    def mark_attested(self, expected_config_digest):
        self._record("mark_attested")
        self.attest_calls.append(expected_config_digest)
        self.attest_digest = expected_config_digest
        self.attested = True
        return True

    def start_prestart_window(self):
        self._record("start_prestart_window")
        self.prestart_calls += 1
        return True

    def abort(self, code="practice_aborted"):
        self.abort_calls += 1
        self.aborted = True
        self.terminal_reason = code

    def close(self):
        self.closed += 1


class FakeSupervisor:
    def __init__(self, *, block=None, result=None, human_retained=False, session=None, session_id="sess-1"):
        self.phase = "accepted"
        self.error = None
        self.cleaned = 0
        self.session_id = session_id
        self.human_retained = human_retained
        self.session = session
        self._block = block
        self._result = result or {"ok": True, "code": practice_host.CODE_OK}

    def run(self):
        if self._block is not None:
            self._block.wait(5)
        self.phase = "completed"
        return dict(self._result)

    def human_active(self):
        if not self.human_retained or self.session is None:
            return False
        return any(item.get("role") == "human" and item.get("running") for item in self.session.is_running())

    def cleanup(self):
        self.cleaned += 1


class FakeCertificateApi:
    """In-memory stand-in for the measurement-interface certificate API."""

    def __init__(
        self,
        *,
        check=None,
        lock=None,
        prepare=None,
        verdict=None,
        open_records=None,
        content_hash=None,
        bind=None,
        write=None,
        failure=None,
        events=None,
    ):
        self._check = check if check is not None else {"ok": True, "code": "ok", "certificate_id": "cert1"}
        self._lock = lock if lock is not None else {"locked": False}
        self._prepare = prepare
        self._verdict = verdict if verdict is not None else {"ok": True, "code": "session_passed"}
        self._open = list(open_records or [])
        self._content_hash = content_hash
        self._bind = bind
        self._write = write
        self._failure = failure
        self._events = events
        self.check_calls = 0
        self.prepare_calls = 0
        self.verdict_calls = 0
        self.failure_calls = []
        self.no_spawn_calls = []
        self.bind_calls = []
        self.ack_calls = 0

    def _record(self, name):
        if self._events is not None:
            self._events.append(name)

    def check_certificate(self, staging_root, live=None, port=None):
        self.check_calls += 1
        return dict(self._check)

    def lockout(self, staging_root):
        return dict(self._lock)

    def acknowledge_lockout(self, staging_root, *, operator, reason):
        self.ack_calls += 1
        return {"ok": True, "code": "lockout_acknowledged"}

    def list_open_records(self, staging_root):
        return list(self._open)

    def collect_layer_m(self, staging_root, live=None, server_bind=None):
        digest = self._content_hash or "c" * 64
        return {"roles": {role: {"role_parity_digest": digest} for role in ("human", "ai")}}

    def prepare_session(self, staging_root, *, live, session_id, port=None, nonce=None, closed_check=None, phase="P1A", backup_id=None, backup_verify=None, **extra):
        self.prepare_calls += 1
        self._record("prepare_session")
        closed = bool(closed_check()) if callable(closed_check) else None
        if self._prepare is not None:
            return dict(self._prepare)
        session_nonce = nonce or "n" * 32
        return {
            "ok": True,
            "code": "session_prepared",
            "session_id": session_id,
            "nonce": session_nonce,
            "port": port,
            "certificate_id": "cert1",
            "backup_id": backup_id,
            "open_record": f"/stage/open/{session_id}.json",
            "record": {
                "schema": "aisparring.open_session.v1",
                "session_id": session_id,
                "phase": phase,
                "nonce": session_nonce,
                "port": port,
                "status": "open",
            },
            "closed_check": closed,
        }

    def bind_open_session(self, staging_root, session_id, *, pids, spawn_time=None):
        self._record("bind_open_session")
        self.bind_calls.append({"session_id": session_id, "pids": dict(pids or {}), "spawn_time": spawn_time})
        if self._bind is not None:
            return dict(self._bind)
        return {"ok": True, "code": "open_session_bound", "pids": dict(pids or {})}

    def record_session_verdict(self, staging_root, *, session_id, live, session=None, live_closed=None, backup_id=None, certificate_id=None):
        self.verdict_calls += 1
        self._record("record_session_verdict")
        # Mirror the real certificate: a closure can never be certified without the
        # retained session and a real live-closed check.
        assert session is not None, "retained_session_required"
        assert callable(live_closed), "live_closed_check_unavailable"
        self.live_closed_seen = bool(live_closed())
        self.session_seen = session
        if self._failure is not None:
            return dict(self._failure)
        return dict(self._verdict)

    def record_session_failure(self, staging_root, *, session_id, reason):
        self.failure_calls.append({"session_id": session_id, "reason": reason})
        return {"ok": True, "code": "session_failed_recorded", "session_id": session_id}

    def record_session_no_spawn(self, staging_root, *, session_id, live, backup_id=None):
        self.no_spawn_calls.append({"session_id": session_id, "live": live, "backup_id": backup_id})
        self._record("record_session_no_spawn")
        return {"ok": True, "code": "session_no_spawn_closed", "session_id": session_id}

    def write_launcher_attestation(self, staging_root, *, session_id, nonce, control_port, port, spawn_time=None, live=None):
        self._record("write_launcher_attestation")
        return {"ok": True, "code": "attestation_written", "attestations": {"human": "x", "ai": "y"}}


def make_config(root, **overrides):
    repo = Path(root) / "repo"
    server_root = repo / "work" / "local-server"
    values = dict(
        work_dir=repo / "work" / "aisparring-host",
        session_root=repo / "work" / "aisparring-host" / "sessions",
        staging_root=repo / "staging",
        backup_root=repo / "backups",
        live_install_root=Path(root) / "live" / "Balatro",
        live_appdata_root=Path(root) / "appdata" / "Balatro",
        steam_root=Path(root) / "Steam",
        server_root=server_root,
        server_manifest=server_root / "AISparring-adaptation.json",
        match_port=8788,
    )
    values.update(overrides)
    return practice_host.default_config(repo_root=repo, **values)


def make_request(**overrides):
    values = dict(
        session_id="correlation-1",
        difficulty="competitive",
        pacing="instant",
        mode="normal",
        gauntlet=None,
        live_pid=4321,
        live_create_time=1000.0,
    )
    values.update(overrides)
    return values


def _live_image(config):
    return str(Path(config.live_install_root) / "Balatro.exe")


def _live_opener(config, create_time=1000.0):
    return lambda pid: FakeLiveHandle(create_time, _live_image(config))


def envelope(daemon, op, request=None, auth=None, schema=practice_host.REQUEST_SCHEMA, **extra):
    payload = {
        "schema": schema,
        "op": op,
        "auth": daemon._secret if auth is None else auth,
        "request": {} if request is None else request,
    }
    payload.update(extra)
    return payload


def _write_server_fixture(config, pin=None, which=None):
    which = which or (lambda name: sys.executable)
    server = Path(config.server_root)
    (server / "src").mkdir(parents=True, exist_ok=True)
    (server / "dist").mkdir(parents=True, exist_ok=True)
    main = server / "src" / "main.ts"
    main.write_text(
        "const server = createServer()\n"
        + practice_host.SERVER_BIND_OK
        + "\n"
        + practice_host.SERVER_ADMIN_OK
        + "\n",
        encoding="utf-8",
    )
    entry = server / "dist" / "main.js"
    entry.write_text(
        "const server = createServer()\n"
        + practice_host.SERVER_BIND_OK
        + "\n// admin listener disabled in the built bundle\n",
        encoding="utf-8",
    )
    lock = server / "package-lock.json"
    lock.write_text('{"lockfileVersion":3}\n', encoding="utf-8")
    for name in config.server_runtime_deps:
        dep = server / "node_modules" / name
        dep.mkdir(parents=True, exist_ok=True)
        (dep / "package.json").write_text(
            json.dumps({"name": name, "version": "1.0.0"}) + "\n", encoding="utf-8"
        )
        (dep / "binding.node").write_bytes(b"native-binary-" + name.encode("utf-8"))
    node_path = Path(which(config.node_executable))
    runtime_files = {
        path.relative_to(server).as_posix(): staging.sha256_file(path)
        for path in sorted((server / "node_modules").rglob("*"))
        if path.is_file()
    }
    dependency_hashes = {
        name: staging._digest_of(staging.hash_tree(server / "node_modules" / name))
        for name in config.server_runtime_deps
    }
    native_files = sorted(
        path.relative_to(server).as_posix()
        for path in (server / "node_modules").rglob("*.node")
        if path.is_file()
    )
    manifest = {
        "schema": "aisparring.local_server.v1",
        "upstream_commit": pin or config.server_pin,
        "changes": list(practice_host.SERVER_CHANGES),
        "node_executable": str(node_path),
        "node_sha256": staging.sha256_file(node_path),
        "source_files": {"src/main.ts": staging.sha256_file(main)},
        "built_files": {"dist/main.js": staging.sha256_file(entry)},
        "runtime_files": runtime_files,
        "dependency_hashes": dependency_hashes,
        "native_files": native_files,
        "package_lock_sha256": staging.sha256_file(lock),
    }
    (server / "AISparring-adaptation.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
    )
    return server, main, entry, lock, manifest


def _refresh_manifest(server, manifest):
    for key, rel in (("source_files", "src/main.ts"), ("built_files", "dist/main.js")):
        manifest[key][rel] = staging.sha256_file(Path(server) / rel)
    (Path(server) / "AISparring-adaptation.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
    )


def _which_python(name):
    return sys.executable


def _ok_runtime_checker(config):
    return {"ok": True, "code": practice_host.CODE_OK, "problems": [], "runtimes": ["luajit21"]}


# ---------------------------------------------------------------------------
# Daemon: auth, shape, enums, identity, tickets, discovery, lockout
# ---------------------------------------------------------------------------

def test_daemon_rejects_bad_auth_shape_and_op():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        daemon = practice_host.HostDaemon(config, opener=_live_opener(config), enumerator=FakeEnumerator([]))
        daemon.start()
        try:
            assert daemon.handle_request(envelope(daemon, "available", auth="0" * 64))["code"] == practice_host.CODE_BAD_AUTH
            assert daemon.handle_request(envelope(daemon, "available", schema="wrong"))["code"] == practice_host.CODE_BAD_REQUEST
            assert daemon.handle_request(envelope(daemon, "nope"))["code"] == practice_host.CODE_BAD_OP
            assert daemon.handle_request({"schema": practice_host.REQUEST_SCHEMA})["code"] == practice_host.CODE_BAD_REQUEST
        finally:
            daemon.stop()


def test_daemon_available_returns_enums_without_secret():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        daemon = practice_host.HostDaemon(config, opener=_live_opener(config), enumerator=FakeEnumerator([]))
        daemon.start()
        try:
            response = daemon.handle_request(envelope(daemon, "available"))
            assert response["ok"] is True
            assert response["enums"]["difficulty"] == list(practice_service.DIFFICULTIES)
            assert response["enums"]["gauntlet"] == sorted(practice_service.GAUNTLET_SEEDS)
            assert response["lockout"]["locked"] is False
            assert response["human_active"] is False
            assert response["open_records"] == []
            assert daemon._secret not in json.dumps(response)
        finally:
            daemon.stop()


def test_daemon_start_validates_enums_and_live_pid():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        created = []

        def factory(cfg, request):
            created.append(request)
            return FakeSupervisor(block=threading.Event())

        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            supervisor_factory=factory,
        )
        daemon.start()
        try:
            for override in (
                {"difficulty": "impossible"},
                {"pacing": "fast"},
                {"mode": "ranked"},
                {"mode": "gauntlet", "gauntlet": None},
                {"mode": "gauntlet", "gauntlet": "Test9"},
                {"mode": "normal", "gauntlet": "Test1"},
                {"live_pid": True},
                {"live_create_time": 0},
                {"live_create_time": "now"},
            ):
                response = daemon.handle_request(envelope(daemon, "start", make_request(**override)))
                assert not response["ok"], (override, response)
            assert created == []
            bad = make_request()
            bad["extra"] = 1
            assert daemon.handle_request(envelope(daemon, "start", bad))["code"] == practice_host.CODE_BAD_REQUEST
        finally:
            daemon.stop()


def test_daemon_start_verifies_live_identity():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for opener, code in (
            (_live_opener(config, create_time=9999.0), practice_host.CODE_LIVE_IDENTITY_MISMATCH),
            (lambda pid: FakeLiveHandle(1000.0, str(Path(tmp) / "other" / "Balatro.exe")), practice_host.CODE_LIVE_NOT_INSTALL),
            (lambda pid: None, "practice_live_handle_unavailable"),
        ):
            daemon = practice_host.HostDaemon(
                config, opener=opener, enumerator=FakeEnumerator([]), runtime_checker=_ok_runtime_checker
            )
            daemon.start()
            try:
                response = daemon.handle_request(envelope(daemon, "start", make_request()))
                assert response["code"] == code, response
            finally:
                daemon.stop()


def test_daemon_start_acks_only_when_recorded_and_refuses_duplicate():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        gate = threading.Event()
        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            start_gate=lambda: {"ok": True, "code": practice_host.CODE_OK},
            supervisor_factory=lambda cfg, request: FakeSupervisor(block=gate),
        )
        daemon.start()
        try:
            first = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert first["ok"] is True and first["code"] == practice_host.CODE_ACCEPTED
            assert first["ticket"]
            duplicate = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert duplicate["code"] == practice_host.CODE_TICKET_ACTIVE
            unknown = daemon.handle_request(envelope(daemon, "poll", {"ticket": "nope"}))
            assert unknown["code"] == practice_host.CODE_TICKET_UNKNOWN
            polled = daemon.handle_request(envelope(daemon, "poll", {"ticket": first["ticket"]}))
            assert polled["ok"] is True and polled["phase"] in practice_host.PHASES
        finally:
            gate.set()
            daemon.stop()


def test_daemon_refuses_live_duplicate_and_replaces_stale():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        marker = {
            "schema": practice_host.DISCOVERY_SCHEMA,
            "module_sha256": practice_host.module_sha256(),
            "daemon_id": "other",
            "pid": os.getpid(),
            "create_time": 1000.0,
        }
        path = config.resolved_discovery_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(marker), encoding="utf-8")

        live = practice_host.HostDaemon(config, opener=_live_opener(config, create_time=1000.0), enumerator=FakeEnumerator([]))
        try:
            live.start()
        except practice_host.HostError as error:
            assert error.code == practice_host.CODE_ALREADY_RUNNING
        else:
            raise AssertionError("expected host_already_running")

        marker["create_time"] = 555.0
        path.write_text(json.dumps(marker), encoding="utf-8")
        stale = practice_host.HostDaemon(config, opener=_live_opener(config, create_time=1000.0), enumerator=FakeEnumerator([]))
        started = stale.start()
        try:
            assert started["stale_replaced"] is True
            assert started["code"] == practice_host.CODE_STALE_DISCOVERY
        finally:
            stale.stop()

        # A marker that is not our well-formed schema stays foreign and is never
        # replaced, even though its PID is dead.
        marker["schema"] = "someone.else.v1"
        path.write_text(json.dumps(marker), encoding="utf-8")
        foreign = practice_host.HostDaemon(config, opener=_live_opener(config), enumerator=FakeEnumerator([]))
        try:
            foreign.start()
        except practice_host.HostError as error:
            assert error.code == practice_host.CODE_FOREIGN_DISCOVERY
        else:
            raise AssertionError("expected host_foreign_discovery")
        assert json.loads(path.read_text(encoding="utf-8"))["schema"] == "someone.else.v1"


def test_discovery_state_treats_exited_but_held_daemon_as_stale():
    # Same "exited but still openable" case as the live exit: a crashed daemon
    # whose process handle is still held elsewhere must not block a restart.
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        marker = {
            "schema": practice_host.DISCOVERY_SCHEMA,
            "module_sha256": practice_host.module_sha256(),
            "daemon_id": "other",
            "pid": 4321,
            "create_time": 1000.0,
        }
        path = config.resolved_discovery_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(marker), encoding="utf-8")
        held = SequenceOpener([FakeLiveHandle(1000.0, None, exited=True)])
        state = practice_host.discovery_state(config, opener=held, enumerator=FakeEnumerator([]))
        assert state["state"] == "stale" and state["code"] == practice_host.CODE_STALE_DISCOVERY

        running = SequenceOpener([FakeLiveHandle(1000.0, None, exited=None)])
        state = practice_host.discovery_state(config, opener=running, enumerator=FakeEnumerator([]))
        assert state["state"] == "live" and state["code"] == practice_host.CODE_ALREADY_RUNNING


def _write_marker(config, **fields):
    marker = {
        "schema": practice_host.DISCOVERY_SCHEMA,
        "module_sha256": "a" * 64,
        "version": "previous",
        "daemon_id": "host-old",
        "pid": 4321,
        "create_time": 1000.0,
    }
    marker.update(fields)
    path = config.resolved_discovery_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(marker), encoding="utf-8")
    return path, marker


def test_previous_build_marker_with_exited_daemon_is_recovered():
    # NATIVE_TEST_PROGRESS "First human-played match": the old daemon's marker
    # carried the previous practice_host.py hash and was refused as foreign even
    # after that daemon exited; it had to be renamed by hand.
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        cases = (
            # Windows: the handle is still openable but reports exited.
            ("held_exited", SequenceOpener([FakeLiveHandle(1000.0, None, exited=True)]), FakeEnumerator([])),
            # The PID is gone: no handle, and absent from the listing.
            ("gone", SequenceOpener([]), FakeEnumerator([])),
            # The PID now belongs to another process (different create time).
            ("reused_handle", SequenceOpener([FakeLiveHandle(2000.0, None)]), FakeEnumerator([])),
            (
                "reused_listing",
                SequenceOpener([]),
                FakeEnumerator([launch_practice.ProcessInfo(4321, 2000.0, "C:/x/python.exe", name="python")]),
            ),
        )
        for name, opener, enumerator in cases:
            _write_marker(config)
            state = practice_host.discovery_state(config, opener=opener, enumerator=enumerator)
            assert state["state"] == "stale_previous_build", (name, state)
            assert state["code"] == practice_host.CODE_STALE_DISCOVERY, (name, state)
            # Same ok convention as the current build's stale_pid_reused.
            assert state["ok"] is (not name.startswith("reused")), (name, state)


def test_previous_build_marker_with_running_daemon_is_never_clobbered():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        cases = (
            ("handle_running", SequenceOpener([FakeLiveHandle(1000.0, None, exited=None)]), FakeEnumerator([])),
            ("handle_running_false", SequenceOpener([FakeLiveHandle(1000.0, None, exited=False)]), FakeEnumerator([])),
            # Access denied on the handle, but the listing shows the exact process.
            (
                "listing_running",
                SequenceOpener([]),
                FakeEnumerator([launch_practice.ProcessInfo(4321, 1000.0, "C:/x/python.exe", name="python")]),
            ),
        )
        for name, opener, enumerator in cases:
            path, marker = _write_marker(config)
            before = path.read_bytes()
            state = practice_host.discovery_state(config, opener=opener, enumerator=enumerator)
            assert state["state"] == "previous_build_live", (name, state)
            assert state["ok"] is False and state["code"] == practice_host.CODE_PREVIOUS_BUILD_RUNNING, (name, state)
            daemon = practice_host.HostDaemon(
                config,
                opener=SequenceOpener([FakeLiveHandle(1000.0, None, exited=None)]) if name.startswith("handle") else opener,
                enumerator=enumerator,
            )
            try:
                daemon.start()
            except practice_host.HostError as error:
                assert error.code == practice_host.CODE_PREVIOUS_BUILD_RUNNING, (name, error.code)
            else:
                daemon.stop()
                raise AssertionError(f"{name}: a running previous-build daemon was clobbered")
            assert path.read_bytes() == before, name


def test_previous_build_marker_unverifiable_liveness_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for name, enumerator in (
            ("listing_failed", FakeEnumerator(error=staging.StagingError("process_enumeration_failed"))),
            ("listing_no_create_time", FakeEnumerator([launch_practice.ProcessInfo(4321, 0.0, None, name="python")])),
        ):
            path, _ = _write_marker(config)
            before = path.read_bytes()
            state = practice_host.discovery_state(config, opener=SequenceOpener([]), enumerator=enumerator)
            assert state["state"] == "unverified" and state["ok"] is False, (name, state)
            daemon = practice_host.HostDaemon(config, opener=SequenceOpener([]), enumerator=enumerator)
            try:
                daemon.start()
            except practice_host.HostError as error:
                assert error.code == "practice_host_discovery_unverified", (name, error.code)
            else:
                daemon.stop()
                raise AssertionError(f"{name}: unverifiable owner was clobbered")
            assert path.read_bytes() == before, name


def test_malformed_own_schema_markers_are_foreign():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for name, fields in (
            ("bool_pid", {"pid": True}),
            ("zero_pid", {"pid": 0}),
            ("negative_pid", {"pid": -5}),
            ("string_pid", {"pid": "4321"}),
            ("float_pid", {"pid": 4321.0}),
            ("bool_time", {"create_time": True}),
            ("zero_time", {"create_time": 0}),
            ("missing_time", {"create_time": None}),
            ("short_hash", {"module_sha256": "abc"}),
            ("upper_hash", {"module_sha256": "A" * 64}),
            ("missing_hash", {"module_sha256": None}),
            ("infinite_time", {"create_time": float("inf")}),
            ("nan_time", {"create_time": float("nan")}),
            ("oversized_pid", {"pid": 2**40}),
        ):
            _write_marker(config, **fields)
            state = practice_host.discovery_state(
                config, opener=SequenceOpener([]), enumerator=FakeEnumerator([])
            )
            assert state["state"] == "foreign" and state["code"] == practice_host.CODE_FOREIGN_DISCOVERY, (name, state)
        path = config.resolved_discovery_path()
        path.write_text("{not json", encoding="utf-8")
        state = practice_host.discovery_state(config, opener=SequenceOpener([]), enumerator=FakeEnumerator([]))
        assert state["state"] == "foreign"
        path.write_text("[1, 2]", encoding="utf-8")
        state = practice_host.discovery_state(config, opener=SequenceOpener([]), enumerator=FakeEnumerator([]))
        assert state["state"] == "foreign"


class _RaisingOpener:
    def __call__(self, pid):
        raise PermissionError("access denied")


class _NoTimeHandle(FakeLiveHandle):
    def create_time(self):
        return None


class _BrokenEnumerator(launch_practice.ProcessEnumerator):
    def list(self):
        raise RuntimeError("powershell exploded")


def test_marker_liveness_fallbacks_are_conservative():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        running = FakeEnumerator([launch_practice.ProcessInfo(4321, 1000.0, "C:/x/python.exe", name="python")])
        cases = (
            # Handle open but no create time: the listing decides.
            ("no_time_handle_listed", SequenceOpener([_NoTimeHandle(None, None)]), running, "previous_build_live"),
            ("no_time_handle_gone", SequenceOpener([_NoTimeHandle(None, None)]), FakeEnumerator([]), "stale_previous_build"),
            # Elevated process: the handle open raises, the listing decides.
            ("opener_raises_listed", _RaisingOpener(), running, "previous_build_live"),
            ("opener_raises_gone", _RaisingOpener(), FakeEnumerator([]), "stale_previous_build"),
            # Any listing failure proves nothing.
            ("listing_raises", SequenceOpener([]), _BrokenEnumerator(), "unverified"),
        )
        for name, opener, enumerator, expected in cases:
            _write_marker(config)
            state = practice_host.discovery_state(config, opener=opener, enumerator=enumerator)
            assert state["state"] == expected, (name, state)


def test_current_build_marker_with_unverifiable_listing_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        path, _ = _write_marker(config, module_sha256=practice_host.module_sha256())
        before = path.read_bytes()
        listing = FakeEnumerator([launch_practice.ProcessInfo(4321, 0.0, None, name="python")])
        state = practice_host.discovery_state(config, opener=SequenceOpener([]), enumerator=listing)
        assert state["state"] == "unverified" and state["ok"] is False, state
        assert path.read_bytes() == before


def test_stale_ok_flags_match_between_builds():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for module in ("a" * 64, practice_host.module_sha256()):
            _write_marker(config, module_sha256=module)
            reused = practice_host.discovery_state(
                config, opener=SequenceOpener([FakeLiveHandle(2000.0, None)]), enumerator=FakeEnumerator([])
            )
            assert reused["ok"] is False and reused["process"] == "pid_reused", reused
            exited = practice_host.discovery_state(
                config,
                opener=SequenceOpener([FakeLiveHandle(1000.0, None, exited=True)]),
                enumerator=FakeEnumerator([]),
            )
            assert exited["ok"] is True and exited["process"] == "exited", exited


def test_daemon_refuses_to_serve_without_its_own_create_time_on_windows():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        with patched(launch_practice, read_process_create_time=lambda pid: None), patched(
            practice_host, _on_windows=lambda: True
        ):
            daemon = practice_host.HostDaemon(config, opener=SequenceOpener([]), enumerator=FakeEnumerator([]))
            try:
                daemon.start()
            except practice_host.HostError as error:
                assert error.code == practice_host.CODE_CREATE_TIME_UNAVAILABLE
            else:
                daemon.stop()
                raise AssertionError("served with a marker that would read as foreign")
        assert not config.resolved_discovery_path().exists()


def test_daemon_start_replaces_dead_previous_build_marker_and_reports_it():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        path, _ = _write_marker(config)
        daemon = practice_host.HostDaemon(
            config, opener=SequenceOpener([FakeLiveHandle(1000.0, None, exited=True)]), enumerator=FakeEnumerator([])
        )
        started = daemon.start()
        try:
            assert started["stale_replaced"] is True
            assert started["replaced"] == {
                "state": "stale_previous_build",
                "pid": 4321,
                "module_sha256": "a" * 64,
                "version": "previous",
            }, started
            written = json.loads(path.read_text(encoding="utf-8"))
            assert written["module_sha256"] == practice_host.module_sha256()
            assert written["pid"] == os.getpid()
        finally:
            daemon.stop()


def test_reissue_allows_dead_previous_build_marker_but_not_a_running_one():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        api = FakeReissueApi(["bound_tool_changed:practice_host"])
        _write_marker(config)
        result = practice_host.reissue_certificate_for_tools(
            config,
            api=api,
            enumerator=FakeEnumerator([]),
            opener=SequenceOpener([FakeLiveHandle(1000.0, None, exited=None)]),
        )
        assert result["code"] == "reissue_host_daemon_running" and result["state"] == "previous_build_live"
        assert not api.built
        result = practice_host.reissue_certificate_for_tools(
            config,
            api=api,
            enumerator=FakeEnumerator([]),
            opener=SequenceOpener([FakeLiveHandle(1000.0, None, exited=True)]),
        )
        assert result["ok"] is True and result["code"] == "reissue_complete", result


def test_daemon_loopback_socket_round_trip():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        daemon = practice_host.HostDaemon(config, opener=_live_opener(config), enumerator=FakeEnumerator([]))
        daemon.start()
        try:
            assert daemon.port is not None
            with socket.create_connection((practice_host.HOST, daemon.port), timeout=5) as connection:
                connection.sendall((json.dumps(envelope(daemon, "available")) + "\n").encode("utf-8"))
                raw = connection.makefile("rb").readline()
            response = json.loads(raw.decode("utf-8"))
            assert response["ok"] is True and response["version"] == practice_host.VERSION
        finally:
            daemon.stop()


def test_host_lockout_requires_explicit_acknowledgement():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        assert practice_host.read_host_lockout(config)["locked"] is False
        practice_host.set_host_lockout(config, reason="test")
        assert practice_host.read_host_lockout(config)["locked"] is True
        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            supervisor_factory=lambda cfg, request: FakeSupervisor(block=threading.Event()),
        )
        daemon.start()
        try:
            assert daemon.handle_request(envelope(daemon, "available"))["lockout"]["locked"] is True
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_ACK_REQUIRED
            bad = daemon.handle_request(envelope(daemon, "acknowledge", {"confirm": False}))
            assert bad["code"] == practice_host.CODE_BAD_REQUEST
            ack = daemon.handle_request(envelope(daemon, "acknowledge", {"confirm": True}))
            assert ack["ok"] is True and ack["cleared"] is True
            assert practice_host.read_host_lockout(config)["locked"] is False
        finally:
            daemon.stop()


def test_open_record_blocks_new_ticket_and_acknowledgement():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        api = FakeCertificateApi(open_records=[{"status": "open", "session_id": "s-open"}])
        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            certificate_api=api,
            runtime_checker=_ok_runtime_checker,
            supervisor_factory=lambda cfg, request: FakeSupervisor(block=threading.Event()),
        )
        daemon.start()
        try:
            available = daemon.handle_request(envelope(daemon, "available"))
            assert available["open_records"] and available["open_records"][0]["session_id"] == "s-open"
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_OPEN_RECORD_BLOCKED
            practice_host.set_host_lockout(config, reason="test")
            ack = daemon.handle_request(envelope(daemon, "acknowledge", {"confirm": True}))
            assert ack["code"] == practice_host.CODE_OPEN_RECORD_BLOCKED
        finally:
            daemon.stop()


def test_new_ticket_never_kills_retained_human_and_daemon_stop_defers():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        retained = FakeSupervisor(human_retained=True, session=FakeSession(roles=("human",)))
        daemon = practice_host.HostDaemon(
            config, opener=_live_opener(config), enumerator=FakeEnumerator([]), runtime_checker=_ok_runtime_checker
        )
        daemon.start()
        try:
            with daemon._lock:
                daemon._ticket = practice_host.MatchTicket(ticket="ticket-live", request=make_request())
                daemon._ticket.supervisor = retained
            assert daemon.human_active() is True
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_HUMAN_ACTIVE
            assert retained.cleaned == 0
            stop = daemon.stop()
            assert stop["stopped"] is False and stop["code"] == practice_host.CODE_HUMAN_ACTIVE
            assert daemon._server is not None
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


# ---------------------------------------------------------------------------
# Live-exit wait (never terminates)
# ---------------------------------------------------------------------------

def test_wait_for_live_exit_timeout_never_terminates():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        handle = FakeLiveHandle(1000.0, _live_image(config))
        opener = SequenceOpener([handle, handle, handle, handle, handle, handle])
        verdict = practice_host.wait_for_live_exit(
            config,
            4321,
            1000.0,
            timeout=1.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator([]),
            opener=opener,
            clock=FakeClock(step=1.0),
            sleeper=lambda _seconds: None,
        )
        assert verdict["code"] == practice_host.CODE_LIVE_TIMEOUT
        assert verdict["terminated"] is False
        assert handle.terminate_calls == 0


def test_wait_for_live_exit_observes_absence_and_pid_reuse():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        exited = practice_host.wait_for_live_exit(
            config,
            4321,
            1000.0,
            timeout=5.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator([]),
            opener=SequenceOpener([]),
            clock=FakeClock(step=0.1),
            sleeper=lambda _seconds: None,
        )
        assert exited["ok"] is True and exited["pid_reused"] is False

        reused = practice_host.wait_for_live_exit(
            config,
            4321,
            1000.0,
            timeout=5.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator(
                [launch_practice.ProcessInfo(4321, 2000.0, _live_image(config), name="Balatro")]
            ),
            opener=SequenceOpener([]),
            clock=FakeClock(step=0.1),
            sleeper=lambda _seconds: None,
        )
        assert reused["ok"] is True and reused["pid_reused"] is True

        unverified = practice_host.wait_for_live_exit(
            config,
            4321,
            1000.0,
            timeout=5.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator(error=staging.StagingError("process_enumeration_unavailable")),
            opener=SequenceOpener([]),
            clock=FakeClock(step=0.1),
            sleeper=lambda _seconds: None,
        )
        assert unverified["code"] == practice_host.CODE_LIVE_UNVERIFIED


def test_wait_for_live_exit_accepts_exited_process_still_held_open():
    # Live failure (September 29): after Balatro quit, another process (Steam)
    # still held a handle, so OpenProcess succeeded with the matching create
    # time but QueryFullProcessImageNameW returned nothing. The exact same
    # process having exited must count as the live exit.
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        running = FakeLiveHandle(1000.0, _live_image(config))
        exited = FakeLiveHandle(1000.0, None, exited=True)
        verdict = practice_host.wait_for_live_exit(
            config,
            1632,
            1000.0,
            timeout=5.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator(error=staging.StagingError("process_enumeration_unavailable")),
            opener=SequenceOpener([running, exited]),
            clock=FakeClock(step=0.1),
            sleeper=lambda _seconds: None,
        )
        assert verdict["ok"] is True and verdict["code"] == practice_host.CODE_LIVE_EXITED
        assert verdict["pid_reused"] is False
        assert running.terminate_calls == 0 and exited.terminate_calls == 0


def test_wait_for_live_exit_running_without_image_stays_unverified():
    # A process that has not exited (or whose exit state is unknown) still
    # needs the strict install-path check.
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for exit_state in (False, None):
            handle = FakeLiveHandle(1000.0, None, exited=exit_state)
            verdict = practice_host.wait_for_live_exit(
                config,
                1632,
                1000.0,
                timeout=5.0,
                poll_interval=0.0,
                enumerator=FakeEnumerator([]),
                opener=SequenceOpener([handle]),
                clock=FakeClock(step=0.1),
                sleeper=lambda _seconds: None,
            )
            assert verdict["code"] == practice_host.CODE_LIVE_UNVERIFIED, exit_state


def test_wait_for_live_exit_exited_handle_with_other_create_time_is_reuse():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        handle = FakeLiveHandle(2000.0, None, exited=True)
        verdict = practice_host.wait_for_live_exit(
            config,
            1632,
            1000.0,
            timeout=5.0,
            poll_interval=0.0,
            enumerator=FakeEnumerator([]),
            opener=SequenceOpener([handle]),
            clock=FakeClock(step=0.1),
            sleeper=lambda _seconds: None,
        )
        assert verdict["ok"] is True and verdict["pid_reused"] is True


def test_verify_live_target_rejects_exited_process():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        handle = FakeLiveHandle(1000.0, _live_image(config), exited=True)
        verdict = practice_host.verify_live_target(config, 1632, 1000.0, opener=SequenceOpener([handle]))
        assert verdict["ok"] is False
        assert verdict["code"] == practice_host.CODE_LIVE_ALREADY_EXITED


def test_native_query_handle_reports_exit_while_held_open():
    # Real reproduction on Windows: keep a handle to a finished child open (as
    # Steam does) and read it through the host's own query-only opener.
    if os.name != "nt":
        return
    import subprocess

    child = subprocess.Popen([sys.executable, "-c", "pass"])
    try:
        # read_owned_create_time expects the launcher's owned wrapper
        # (``.handle`` is the Popen), so read from the Popen handle directly.
        create_time = launch_practice._create_time_from_handle(launch_practice._process_handle_value(child))
        assert create_time is not None, "create time unreadable from the child's own handle"
        child.wait(timeout=30)
        with tempfile.TemporaryDirectory() as tmp:
            config = make_config(tmp)
            identity = practice_host.read_live_identity(child.pid)
            assert identity is not None, "exited-but-held process could not be opened"
            assert identity["exited"] is True, identity
            assert abs(float(identity["create_time"]) - create_time) <= launch_practice.START_TIME_TOLERANCE, identity
            verdict = practice_host.wait_for_live_exit(
                config,
                child.pid,
                create_time,
                timeout=5.0,
                poll_interval=0.0,
                enumerator=FakeEnumerator([]),
                clock=FakeClock(step=0.1),
                sleeper=lambda _seconds: None,
            )
            assert verdict["ok"] is True and verdict["code"] == practice_host.CODE_LIVE_EXITED, verdict
    finally:
        # Popen keeps its own process handle open until the object is dropped,
        # which is exactly the "exited but still openable" state under test.
        del child


class FakeReissueApi:
    """Certificate API stand-in for the tool-only reissue command."""

    def __init__(self, problems, receipts=None):
        self.problems = list(problems)
        self.receipts = {"P1A": "a" * 64} if receipts is None else receipts
        self.built = []

    def check_certificate(self, staging_root, live=None, port=None, server_bind=None):
        if self.built:
            return {"ok": True, "problems": [], "certificate_id": "new"}
        return {"ok": not self.problems, "problems": list(self.problems), "certificate_id": "old"}

    def _load_current(self, staging_root):
        return Path(staging_root) / "cert.json", {"receipts": self.receipts}

    def build_certificate(self, staging_root, **kwargs):
        self.built.append(kwargs)
        return {"ok": True, "certificate_id": "new", "problems": []}


def test_reissue_certificate_reuses_receipts_for_launcher_and_host_changes():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        api = FakeReissueApi(["bound_tool_changed:launcher", "bound_tool_changed:practice_host"])
        result = practice_host.reissue_certificate_for_tools(
            config, api=api, enumerator=FakeEnumerator([]), opener=SequenceOpener([]), reason="exit fix"
        )
        assert result["ok"] is True and result["code"] == "reissue_complete", result
        assert result["previous_certificate_id"] == "old" and result["certificate_id"] == "new"
        (kwargs,) = api.built
        assert kwargs["receipt_ids"] == api.receipts
        assert kwargs["port"] == config.match_port
        assert kwargs["extra"]["reissued_from"] == "old"


def test_reissue_certificate_refuses_anything_beyond_allowed_tools():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        for problems in (
            ["bound_tool_changed:launcher", "mods_layer_changed"],
            ["bound_tool_changed:staging"],
            ["certificate_locked_out"],
            ["phase_p2_silent_receipt_unreadable", "bound_tool_changed:practice_host"],
        ):
            api = FakeReissueApi(problems)
            result = practice_host.reissue_certificate_for_tools(
                config, api=api, enumerator=FakeEnumerator([]), opener=SequenceOpener([])
            )
            assert result["ok"] is False and result["code"] == "reissue_requires_full_recertification", problems
            assert not api.built


def test_reissue_certificate_requires_closed_game_and_stopped_host():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        api = FakeReissueApi(["bound_tool_changed:launcher"])
        running = FakeEnumerator(
            [launch_practice.ProcessInfo(1632, 1000.0, _live_image(config), name="Balatro")]
        )
        result = practice_host.reissue_certificate_for_tools(
            config, api=api, enumerator=running, opener=SequenceOpener([])
        )
        assert result["code"] == "reissue_live_balatro_running" and not api.built

        marker = {
            "schema": practice_host.DISCOVERY_SCHEMA,
            "module_sha256": practice_host.module_sha256(),
            "daemon_id": "other",
            "pid": 4321,
            "create_time": 1000.0,
        }
        path = config.resolved_discovery_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(marker), encoding="utf-8")
        result = practice_host.reissue_certificate_for_tools(
            config, api=api, enumerator=FakeEnumerator([]), opener=_live_opener(config)
        )
        assert result["code"] == "reissue_host_daemon_running" and not api.built


def test_reissue_certificate_not_needed_when_current():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        api = FakeReissueApi([])
        result = practice_host.reissue_certificate_for_tools(
            config, api=api, enumerator=FakeEnumerator([]), opener=SequenceOpener([])
        )
        assert result["ok"] is True and result["code"] == "reissue_not_needed" and not api.built


# ---------------------------------------------------------------------------
# Certificate / quiescence / backup / attestation
# ---------------------------------------------------------------------------

def test_certificate_gate_reuses_immutable_certificate():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = {"install": str(config.live_install_root)}
        api = FakeCertificateApi(check={"ok": True, "code": "ok", "certificate_id": "c1"}, lock={"locked": False})
        verdict = practice_host.certificate_gate(config, live_map=live, port=8788, api=api)
        assert verdict["ok"] is True and api.check_calls == 1

        locked = FakeCertificateApi(lock={"locked": True, "reason": "live_byte_diff"})
        assert practice_host.certificate_gate(config, live_map=live, port=8788, api=locked)["code"] == practice_host.CODE_CERTIFICATE_LOCKED

        stale = FakeCertificateApi(check={"ok": False, "code": "certificate_invalid", "problems": ["mods_layer_changed"]})
        verdict = practice_host.certificate_gate(config, live_map=live, port=8788, api=stale)
        assert verdict["code"] == practice_host.CODE_CERTIFICATE_REQUIRED

        assert practice_host.certificate_gate(config, live_map=live, port=8788, api=None)["code"] == practice_host.CODE_CERTIFICATE_API_MISSING


def test_host_has_no_unchecked_attestation_writer_and_delegates():
    source = Path(practice_host.__file__).read_text(encoding="utf-8")
    assert "rebase_isolation_proof" not in source
    assert "record_isolation_proof" not in source
    assert not hasattr(practice_host, "isolation_proof_gate")
    # H1: the host's unchecked duplicate writer is deleted.
    assert not hasattr(practice_host, "write_role_attestation")
    assert hasattr(practice_host, "write_role_attestations")

    captured = {}

    def fake_write(staging_root, **kwargs):
        captured.update(kwargs)
        return {"ok": True, "code": "attestation_written"}

    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        with patched(isolation_certificate, write_launcher_attestation=fake_write):
            verdict = practice_host.write_role_attestations(
                config, session_id="s-1", nonce="n" * 32, control_port=51234, port=8788
            )
    assert verdict["ok"] is True
    assert captured["control_port"] == 51234 and captured["port"] == 8788
    assert captured["session_id"] == "s-1"

    with patched(practice_host, isolation_certificate=None):
        assert practice_host.write_role_attestations(
            config, session_id="s-1", nonce="n" * 32, control_port=1, port=1
        )["code"] == practice_host.CODE_MEASUREMENT_API_MISSING


def test_measurement_api_problems_fail_closed():
    assert practice_host.measurement_api_problems(None) == ["certificate_api_missing"]
    assert practice_host.measurement_api_problems(object())
    assert practice_host.measurement_api_problems(isolation_certificate) == []


def test_quiescence_requires_two_equal_hashes():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = {"steam_userdata/390025789": str(Path(tmp) / "Steam" / "userdata" / "390025789" / "2379780")}
        stable = FakeCertificateApi()
        stable.snapshot_live = lambda live_roots, label=None: {"digest": "a" * 64}
        assert practice_host.check_quiescence(config, live, api=stable, sleeper=lambda _s: None)["ok"] is True

        class Unstable:
            def snapshot_live(self, live_roots, label=None):
                self.n = getattr(self, "n", 0) + 1
                return {"digest": "a" * 64 if self.n == 1 else "b" * 64}

        verdict = practice_host.check_quiescence(config, live, api=Unstable(), sleeper=lambda _s: None)
        assert verdict["code"] == practice_host.CODE_QUIESCENCE

        assert practice_host.check_quiescence(config, {"install": "x"}, api=stable, sleeper=lambda _s: None)["ok"] is True


def test_prepare_live_baseline_requires_a_real_backup_id():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = {"install": str(config.live_install_root)}
        api = FakeCertificateApi()

        refused = practice_host.prepare_live_baseline(
            config, live, api=api, backup_runner=lambda c, l, label: {"ok": False, "code": "live_process_running"}, sleeper=lambda _s: None
        )
        assert refused["code"] == practice_host.CODE_FRESH_BACKUP_REQUIRED

        with patched(practice_host, _verify_fresh_backup=lambda c, l: {"ok": True}):
            no_id = practice_host.prepare_live_baseline(
                config, live, api=api, backup_runner=lambda c, l, label: {"ok": True}, sleeper=lambda _s: None
            )
        assert no_id["code"] == practice_host.CODE_FRESH_BACKUP_REQUIRED
        assert "backup_id_missing" in no_id["problems"]

        # The verifier content identity is the id; a runner label is display metadata
        # only and can never stand in for it (R1).
        content_id = "a" * 64
        verify = {
            "ok": True,
            "backup_id": content_id,
            "backup_label": "bk1",
            "manifest_sha256": "b" * 64,
            "roots": {"install": {"files_digest": "c" * 64}},
        }
        with patched(practice_host, _verify_fresh_backup=lambda c, l: dict(verify)):
            prepared = practice_host.prepare_live_baseline(
                config, live, api=api, backup_runner=lambda c, l, label: {"ok": True, "label": "bk1"}, sleeper=lambda _s: None
            )
        assert prepared["ok"] is True, prepared
        assert prepared["backup_id"] == content_id and prepared["backup_id"] != "bk1"
        assert prepared["backup_label"] == "bk1"
        assert prepared["roots"] == verify["roots"]
        assert prepared["manifest_sha256"] == "b" * 64


def _synthetic_live(config, *, profile="390025789"):
    """Synthetic install/AppData/Steam profile: no real game or live path."""
    install = Path(config.live_install_root)
    appdata = Path(config.live_appdata_root)
    app_dir = Path(config.steam_root) / "userdata" / profile / "2379780"
    (install / "AISparring").mkdir(parents=True, exist_ok=True)
    (install / "AISparring" / "mod.json").write_text('{"m":1}\n', encoding="utf-8")
    appdata.mkdir(parents=True, exist_ok=True)
    (appdata / "profile.json").write_text('{"p":1}\n', encoding="utf-8")
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "save.jkr").write_text("save-1\n", encoding="utf-8")
    return launch_practice.live_source_map(install, appdata, config.steam_root)


def _real_backup_runner(config, live_map, label):
    """The real backup path, on synthetic trees, with the fixed display label echoed."""
    ensured = label if isinstance(label, str) and label else "synthetic-backup"
    result = launch_practice.create_live_backup(
        install_root=config.live_install_root,
        appdata_root=config.live_appdata_root,
        steam_root=config.steam_root,
        backup_root=config.backup_root,
        enumerator=FakeEnumerator([]),
        live_install_root=config.live_install_root,
        label=ensured,
        execute=True,
    )
    if isinstance(result, dict) and result.get("ok"):
        result["label"] = result.get("label") or ensured
    return result


def test_prepare_live_baseline_binds_verifier_content_identity():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_live(config)
        prepared = practice_host.prepare_live_baseline(
            config, live, backup_runner=_real_backup_runner, sleeper=lambda _s: None, label="display-label-1"
        )
        assert prepared["ok"] is True, prepared
        evidence = launch_practice.check_backup_evidence(config.backup_root, live)
        assert evidence["ok"] is True, evidence
        assert prepared["backup_id"] == evidence["backup_id"]
        assert prepared["backup_id"] != "display-label-1"
        assert practice_host._is_content_id(prepared["backup_id"])
        assert prepared["backup_label"] == "display-label-1"
        assert prepared["manifest_sha256"] == evidence["manifest_sha256"]
        assert set(prepared["roots"]) == set(evidence["roots"])
        assert set(prepared["roots"]) == {"install", "appdata", "steam_userdata/390025789"}
        for key, entry in prepared["roots"].items():
            assert entry["files_digest"] == evidence["roots"][key]["files_digest"]


def test_prepare_live_baseline_refuses_drift_before_spawn():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_live(config)
        first = practice_host.prepare_live_baseline(
            config, live, backup_runner=_real_backup_runner, sleeper=lambda _s: None, label="drift-base"
        )
        assert first["ok"] is True, first
        # A live byte change after the backup invalidates freshness: the real
        # checker refuses, so nothing is prepared and nothing can spawn.
        (Path(config.live_install_root) / "AISparring" / "mod.json").write_text('{"m":2}\n', encoding="utf-8")
        drifted = practice_host.prepare_live_baseline(
            config, live, backup_runner=lambda c, l, label: {"ok": True, "label": "unused"},
            sleeper=lambda _s: None, label="drift-second",
        )
        assert drifted["ok"] is False
        assert drifted["code"] == practice_host.CODE_FRESH_BACKUP_REQUIRED
        assert any("live_changed_since_backup" in item for item in drifted["verify"]["problems"]), drifted


def test_prepare_live_baseline_refuses_missing_root_map_before_spawn():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_live(config)
        first = practice_host.prepare_live_baseline(
            config, live, backup_runner=_real_backup_runner, sleeper=lambda _s: None, label="missingmap"
        )
        assert first["ok"] is True, first
        manifest_path = Path(config.backup_root) / launch_practice.BACKUP_MANIFEST_NAME
        record = json.loads(manifest_path.read_text(encoding="utf-8"))
        del record["entries"]["appdata"]
        manifest_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        refused = practice_host.prepare_live_baseline(
            config, live, backup_runner=lambda c, l, label: {"ok": True, "label": "unused"},
            sleeper=lambda _s: None, label="missingmap-second",
        )
        assert refused["ok"] is False
        assert refused["code"] == practice_host.CODE_FRESH_BACKUP_REQUIRED
        assert "appdata_missing" in refused["verify"]["problems"], refused


def test_real_prepare_session_binds_content_identity_not_label():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        Path(config.staging_root).mkdir(parents=True, exist_ok=True)
        live = _synthetic_live(config)
        prepared = practice_host.prepare_live_baseline(
            config, live, backup_runner=_real_backup_runner, sleeper=lambda _s: None, label="display-label-2"
        )
        assert prepared["ok"] is True, prepared
        satisfied = lambda staging_root, live=None, port=None: {
            "ok": True, "code": "ok", "certificate_id": "cert-fixture",
        }
        with patched(isolation_certificate, check_certificate=satisfied):
            result = practice_host._call_prepare_session(
                isolation_certificate,
                config,
                live,
                session_id="bind-identity-1",
                port=8788,
                backup_id=prepared["backup_id"],
                backup_verify=lambda: prepared["verify"],
                enumerator=FakeEnumerator([]),
            )
        assert result["ok"] is True, result
        assert result["backup_id"] == prepared["backup_id"]
        assert result["backup_label"] == "display-label-2"
        assert result["record"]["backup_id"] == prepared["backup_id"]
        assert result["record"]["backup_label"] == "display-label-2"
        # The certificate bound its own before-snapshot to the verified root digests.
        assert result["record"]["backup_roots"] == {
            key: value["files_digest"] for key, value in prepared["roots"].items()
        }


def test_wait_for_attestation_requires_both_roles():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        calls = {"n": 0}

        def collector(cfg, nonce, spawn_time, port):
            calls["n"] += 1
            return {"ok": calls["n"] >= 2, "code": practice_host.CODE_OK if calls["n"] >= 2 else "pending"}

        verdict = practice_host.wait_for_attestation(
            config, nonce="n" * 32, spawn_time=1.0, port=8788, collector=collector,
            timeout=10, poll_interval=0.0, clock=FakeClock(step=0.1), sleeper=lambda _s: None,
        )
        assert verdict["ok"] is True and calls["n"] == 2

        always_bad = lambda *args: {"ok": False, "problems": ["guard_nonce_mismatch"]}
        verdict = practice_host.wait_for_attestation(
            config, nonce="n" * 32, spawn_time=1.0, port=8788, collector=always_bad,
            timeout=1, poll_interval=0.0, clock=FakeClock(step=1.0), sleeper=lambda _s: None,
        )
        assert verdict["code"] == practice_host.CODE_ATTESTATION


# ---------------------------------------------------------------------------
# Server adaptation + listener + ports
# ---------------------------------------------------------------------------

def test_verify_server_adaptation_fixture_and_tampers():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        server, main, entry, lock, manifest = _write_server_fixture(config)
        assert practice_host.verify_server_adaptation(config, which=_which_python)["ok"] is True

        main.write_text(
            "const server = createServer()\n" + practice_host.SERVER_BIND_BAD + "\n" + practice_host.SERVER_ADMIN_OK + "\n",
            encoding="utf-8",
        )
        _refresh_manifest(server, manifest)
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "match_bind_not_loopback" in verdict["problems"], verdict

        main.write_text(
            "const server = createServer()\n" + practice_host.SERVER_BIND_OK + "\n" + practice_host.SERVER_ADMIN_BAD + "\n",
            encoding="utf-8",
        )
        _refresh_manifest(server, manifest)
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "admin_listener_not_disabled" in verdict["problems"], verdict

        entry.write_text("// tampered build\n", encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert any(problem.startswith("built_files_hash_mismatch") for problem in verdict["problems"]), verdict

        _write_server_fixture(config, pin="deadbeef")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "upstream_pin_mismatch" in verdict["problems"], verdict


def test_verify_server_adaptation_binds_node_build_and_native_binaries():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        server, _main, entry, _lock, manifest = _write_server_fixture(config)
        assert practice_host.verify_server_adaptation(config, which=_which_python)["ok"] is True

        # dist/main.js must be in the built manifest.
        manifest["built_files"] = {}
        (Path(server) / "AISparring-adaptation.json").write_text(json.dumps(manifest), encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "built_entry_not_in_manifest" in verdict["problems"]
        assert "built_files_missing" in verdict["problems"]

        # The built JS itself must carry the loopback bind.
        _write_server_fixture(config)
        entry.write_text("const server = createServer()\n// no bind here\n", encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "built_match_bind_not_loopback" in verdict["problems"]

        # The resolved Node executable hash must match the manifest pin.
        _write_server_fixture(config)
        manifest = json.loads((Path(server) / "AISparring-adaptation.json").read_text(encoding="utf-8"))
        manifest["node_sha256"] = "0" * 64
        (Path(server) / "AISparring-adaptation.json").write_text(json.dumps(manifest), encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "node_hash_mismatch" in verdict["problems"]

        # A missing native binary cannot pass as a bound runtime.
        _write_server_fixture(config)
        import shutil

        shutil.rmtree(Path(server) / "node_modules" / "better-sqlite3")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "runtime_dependency_missing:better-sqlite3" in verdict["problems"]


def test_verify_server_adaptation_binds_lock_and_runtime_dependencies():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        server, _main, _entry, lock, _manifest = _write_server_fixture(config)
        assert practice_host.verify_server_adaptation(config, which=_which_python)["ok"] is True

        lock.write_text('{"lockfileVersion":3,"tampered":true}\n', encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "package_lock_hash_mismatch" in verdict["problems"], verdict

        _write_server_fixture(config)
        import shutil

        shutil.rmtree(Path(server) / "node_modules" / "uuid")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "runtime_dependency_missing:uuid" in verdict["problems"], verdict


def test_verify_server_adaptation_binds_runtime_manifest_and_native_files():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        server, _main, _entry, _lock, manifest = _write_server_fixture(config)
        assert practice_host.verify_server_adaptation(config, which=_which_python)["ok"] is True
        assert manifest["runtime_files"] and manifest["native_files"]
        assert manifest["dependency_hashes"]

        # The full dependency manifest is required (producer/checker contract).
        manifest.pop("runtime_files")
        (Path(server) / "AISparring-adaptation.json").write_text(json.dumps(manifest), encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "runtime_files_missing" in verdict["problems"], verdict

        # A tampered dependency file is refused.
        server, _main, _entry, _lock, manifest = _write_server_fixture(config)
        target = sorted(
            rel
            for rel, _digest in manifest["runtime_files"].items()
            if rel.endswith("binding.node")
        )[0]
        (Path(server) / target).write_bytes(b"tampered-native-binary")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert any(problem.startswith("runtime_files_hash_mismatch") for problem in verdict["problems"]), verdict

        # A declared dependency hash that does not match the tree is refused.
        server, _main, _entry, _lock, manifest = _write_server_fixture(config)
        manifest["dependency_hashes"]["uuid"] = "0" * 64
        (Path(server) / "AISparring-adaptation.json").write_text(json.dumps(manifest), encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "dependency_hash_mismatch:uuid" in verdict["problems"], verdict

        # Native binaries must be declared in the manifest.
        server, _main, _entry, _lock, manifest = _write_server_fixture(config)
        manifest["native_files"] = []
        (Path(server) / "AISparring-adaptation.json").write_text(json.dumps(manifest), encoding="utf-8")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert "native_files_missing" in verdict["problems"], verdict


def test_runtime_preflight_is_bounded_and_fail_closed():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        ok = practice_host.runtime_preflight(
            config, checker=lambda cfg: {"ok": True, "code": practice_host.CODE_OK}
        )
        assert ok["ok"] is True

        refused = practice_host.runtime_preflight(
            config, checker=lambda cfg: {"ok": False, "problems": ["runtime_unavailable:luajit21"]}
        )
        assert refused["code"] == practice_host.CODE_RUNTIME_PREFLIGHT
        assert refused["problems"] == ["runtime_unavailable:luajit21"]

        def boom(cfg):
            raise RuntimeError("no lupa")

        failed = practice_host.runtime_preflight(config, checker=boom)
        assert failed["code"] == practice_host.CODE_RUNTIME_PREFLIGHT
        assert failed["problems"] == ["runtime_preflight_failed"]

        # A checker that returns a non-dict is a refusal, never an implicit pass.
        assert practice_host.runtime_preflight(config, checker=lambda cfg: None)["ok"] is False


def test_daemon_refuses_start_when_runtime_preflight_fails():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        created = []
        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=lambda cfg: {"ok": False, "problems": ["runtime_unavailable:luajit21"]},
            supervisor_factory=lambda cfg, request: created.append(request) or FakeSupervisor(block=threading.Event()),
        )
        daemon.start()
        try:
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_RUNTIME_PREFLIGHT, refused
            assert refused["problems"] == ["runtime_unavailable:luajit21"]
            assert created == []
        finally:
            daemon.stop()


def test_verify_server_adaptation_rejects_manifest_outside_root():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp, server_manifest=Path(tmp) / "elsewhere.json")
        verdict = practice_host.verify_server_adaptation(config, which=_which_python)
        assert verdict["code"] == "practice_server_manifest_path_mismatch"

        outside = make_config(tmp, server_root=Path(tmp) / "outside-server")
        verdict = practice_host.verify_server_adaptation(outside, which=_which_python)
        assert verdict["code"] == "practice_server_root_unsafe"


def test_verify_local_listener_requires_loopback_owner_and_closed_admin():
    ok = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["127.0.0.1"], "pids": [7]}}),
        expected_pid=7,
    )
    assert ok["ok"] is True and ok["owner_proven"] is True

    bound_all = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["0.0.0.0"], "pids": [7]}}),
        expected_pid=7,
    )
    assert "match_listener_not_loopback" in bound_all["problems"]

    v6_wild = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["::"], "pids": [7]}}),
        expected_pid=7,
    )
    assert "match_listener_not_loopback" in v6_wild["problems"]
    assert practice_host.is_loopback_address("::1") is True
    assert practice_host.is_loopback_address("::ffff:127.0.0.1") is True
    assert practice_host.is_loopback_address("::") is False

    wrong_owner = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["127.0.0.1"], "pids": [999]}}),
        expected_pid=7,
    )
    assert "match_listener_not_owned" in wrong_owner["problems"]

    no_owner = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["127.0.0.1"], "pids": []}}),
        expected_pid=7,
    )
    assert "match_listener_owner_unproven" in no_owner["problems"]

    admin_open = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe(
            {8788: {"listening": True, "addresses": ["127.0.0.1"], "pids": [7]}, 8789: {"listening": True, "addresses": ["127.0.0.1"]}}
        ),
        expected_pid=7,
    )
    assert "admin_listener_active" in admin_open["problems"]

    absent = practice_host.verify_local_listener(8788, 8789, probe=FakeListenerProbe({}))
    assert "match_listener_absent" in absent["problems"]
    assert "lan_bind_unproven" in absent["problems"]


def test_windows_tcp_table_probe_reports_per_family_inventory_status():
    ipv4_only = {"addresses": ["127.0.0.1"], "pids": {7}}

    def v4_only(port, family):
        return ipv4_only if int(family) == practice_host._AF_INET else None

    with patched(practice_host, os=types.SimpleNamespace(name="nt"), _probe_tcp_table=v4_only):
        measured = practice_host.WindowsTcpTableProbe().probe(8788)
    assert measured["families"] == {"ipv4": "ok", "ipv6": "unavailable"}
    assert measured["listening"] is True
    assert measured["addresses"] == ["127.0.0.1"]
    assert measured["pids"] == [7]
    assert measured["source"] == "tcp_table"

    with patched(practice_host, os=types.SimpleNamespace(name="nt"), _probe_tcp_table=lambda port, family: None):
        unavailable = practice_host.WindowsTcpTableProbe().probe(8788)
    assert unavailable["source"] == "unavailable"
    assert unavailable["listening"] is False
    assert unavailable["families"] == {"ipv4": "unavailable", "ipv6": "unavailable"}


def test_verify_local_listener_refuses_partial_family_inventory():
    complete = {"ipv4": "ok", "ipv6": "ok"}
    match_partial = {
        "listening": True,
        "addresses": ["127.0.0.1"],
        "pids": [7],
        "source": "tcp_table",
        "families": {"ipv4": "ok", "ipv6": "unavailable"},
    }
    match_unavailable = {
        "listening": False,
        "addresses": [],
        "pids": [],
        "source": "unavailable",
        "families": {"ipv4": "unavailable", "ipv6": "unavailable"},
    }
    admin_absent_partial = {
        "listening": False,
        "addresses": [],
        "pids": [],
        "source": "tcp_table",
        "families": {"ipv4": "ok", "ipv6": "unavailable"},
    }

    match_gap = practice_host.verify_local_listener(
        8788, 8789, probe=FakeListenerProbe({8788: match_partial}), expected_pid=7
    )
    assert match_gap["ok"] is False
    assert "match_listener_inventory_incomplete" in match_gap["problems"]
    assert match_gap["code"] == practice_host.CODE_LISTENER_UNPROVEN

    # A complete match family inventory cannot vouch for an admin family whose
    # native query failed: the unread family could hold an active admin listener.
    admin_gap = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe(
            {
                8788: {
                    "listening": True,
                    "addresses": ["127.0.0.1"],
                    "pids": [7],
                    "source": "tcp_table",
                    "families": dict(complete),
                },
                8789: admin_absent_partial,
            }
        ),
        expected_pid=7,
    )
    assert admin_gap["ok"] is False
    assert "admin_listener_inventory_incomplete" in admin_gap["problems"]

    both_unavailable = practice_host.verify_local_listener(
        8788, 8789, probe=FakeListenerProbe({8788: match_unavailable}), expected_pid=7
    )
    assert both_unavailable["ok"] is False
    assert "match_listener_absent" in both_unavailable["problems"]
    assert "match_listener_inventory_incomplete" in both_unavailable["problems"]

    # Non-strict callers keep the historical behaviour and only see the partial
    # inventory (no hard refusal), while strict callers refuse it.
    lenient = practice_host.verify_local_listener(
        8788, 8789, probe=FakeListenerProbe({8788: match_partial}), expected_pid=7, strict=False
    )
    assert "match_listener_inventory_incomplete" not in lenient["problems"]
    assert lenient["ok"] is True


def test_exclusive_port_probe_never_reuses_an_occupied_port():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as holder:
            holder.bind((practice_host.HOST, 0))
            holder.listen(1)
            port = holder.getsockname()[1]
            assert practice_host.port_is_free(practice_host.HOST, port) is False
        assert practice_host.choose_match_port(config, port_free=lambda host, port: True)["ok"] is True


def test_choose_match_port_prefers_fixed_and_never_silently_rechooses():
    with tempfile.TemporaryDirectory() as tmp:
        fixed = make_config(tmp)
        assert practice_host.choose_match_port(fixed, port_free=lambda host, port: True) == {
            "ok": True,
            "code": practice_host.CODE_OK,
            "port": 8788,
            "fixed": True,
        }
        busy = practice_host.choose_match_port(fixed, port_free=lambda host, port: False)
        assert busy["code"] == practice_host.CODE_MATCH_PORT

        unset = make_config(tmp, match_port=None)
        refused = practice_host.choose_match_port(unset, port_free=lambda host, port: True)
        assert refused["code"] == practice_host.CODE_MATCH_PORT_UNCONFIGURED

        flexible = make_config(tmp, match_port=None, require_fixed_match_port=False)
        chosen = practice_host.choose_match_port(flexible, port_free=lambda host, port: True)
        assert chosen["ok"] is True and chosen["fixed"] is False and 1 <= chosen["port"] <= 65535


def test_static_isolation_gates_block_on_overlap():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        overlapping = make_config(tmp, staging_root=Path(config.live_install_root) / "staging")
        with patched(
            staging,
            verify_staged_role=lambda staging_root, role: {"ok": True},
            check_steam_guard=lambda staging_root, role, live=None: {"ok": True},
        ):
            verdict = practice_host.static_isolation_gates(overlapping, enumerator=FakeEnumerator([]))
        assert verdict["ok"] is False
        assert verdict["gates"]["overlap"]["code"] == "staging_overlaps_live"


# ---------------------------------------------------------------------------
# Supervisor: descriptors, lifecycle ordering, failure, void, retention, diff
# ---------------------------------------------------------------------------

def _gate_ok(config, **extra):
    verdict = {
        "ok": True,
        "code": practice_host.CODE_OK,
        "content_hash": "c" * 64,
        "match_port": 8788,
        "nonce": "n" * 32,
        "backup_id": "bk1",
        "certificate_id": "cert1",
        "config_digest": "deadbeef",
        "ruleset": {},
        "live_map": {"install": str(config.live_install_root)},
        "open_record": None,
        "server": {"ok": True, "code": practice_host.CODE_OK, "node_executable": sys.executable},
    }
    verdict.update(extra)
    return verdict


def _supervisor(config, request, **overrides):
    defaults = dict(
        service_factory=lambda cfg: FakeService(cfg),
        launch_runner=lambda plan, **kwargs: FakeSession(),
        server_runner=lambda command, cwd, env, log_dir: FakeServer(),
        listener_probe=FakeListenerProbe({8788: {"listening": True, "addresses": ["127.0.0.1"], "pids": [4242]}}),
        enumerator=FakeEnumerator([]),
        opener=SequenceOpener([]),
        gate_evaluator=lambda: _gate_ok(config),
        certificate_api=FakeCertificateApi(),
        attestation_collector=lambda cfg, nonce, spawn_time, port: {"ok": True, "code": practice_host.CODE_OK},
        attestation_writer=lambda cfg, **kwargs: {"ok": True, "code": practice_host.CODE_OK},
        verdict_recorder=lambda cfg, session_id, before, after, backup_id, certificate_id: {"ok": True, "code": "session_passed"},
        human_exit_waiter=lambda session, grace: True,
        port_free=lambda host, port: True,
        runtime_checker=_ok_runtime_checker,
        which=_which_python,
        clock=FakeClock(step=0.1),
        sleeper=lambda _seconds: None,
    )
    defaults.update(overrides)
    return practice_host.MatchSupervisor(config, request, **defaults)


class _StepCounter:
    def __init__(self, step=1.0):
        self.t = 0.0
        self.step = step

    def __call__(self):
        value = self.t
        self.t += self.step
        return value


def test_stage_timer_records_stages_marks_and_failures():
    with tempfile.TemporaryDirectory() as tmp:
        sink = Path(tmp) / "handoff.jsonl"
        timer = practice_host.StageTimer(sink=sink, counter=_StepCounter(1.0))
        with timer.stage("a") as result:
            result["ok"] = True
            result["code"] = "fine"
        with timer.stage("b") as result:
            practice_host._timed_ok(result, {"ok": False, "code": "nope"})
        try:
            with timer.stage("c"):
                raise RuntimeError("boom")
        except RuntimeError:
            pass
        timer.mark("milestone", pid_reused=False, ignored={"x": 1})
        stages = timer.stages
        assert [entry["stage"] for entry in stages] == ["a", "b", "c", "milestone"]
        assert stages[0] == {"stage": "a", "start": 1.0, "seconds": 1.0, "ok": True, "code": "fine"}
        assert stages[1]["ok"] is False and stages[1]["code"] == "nope"
        assert stages[2]["ok"] is False, "an exception is a failed stage"
        assert stages[3]["milestone"] is True and stages[3]["pid_reused"] is False
        assert "ignored" not in stages[3]
        lines = [json.loads(line) for line in sink.read_text(encoding="utf-8").splitlines()]
        assert lines == stages
        summary = timer.summary()
        assert set(summary["totals"]) == {"a", "b", "c"}
        assert summary["slowest"][0]["seconds"] == 1.0


def test_stage_timer_is_bounded_and_never_raises_on_sink_failure():
    timer = practice_host.StageTimer(sink=Path("/nonexistent-dir/for/sure/handoff.jsonl"))
    for index in range(practice_host.StageTimer.MAX_STAGES + 10):
        with timer.stage(f"s{index}"):
            pass
    assert len(timer.stages) == practice_host.StageTimer.MAX_STAGES


def test_supervisor_report_carries_the_handoff_timeline():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        service = FakeService(None, ended=True, terminal_phase="closed")
        service.milestones = lambda: {"hello_human": 1.5, "match_started": 9.0, "bogus": "x"}
        supervisor = _supervisor(config, make_request(), service_factory=lambda cfg: service)
        result = supervisor.run()
        assert result["ok"] is True, result
        timings = result["report"]["timings"]
        names = [entry["stage"] for entry in timings["stages"]]
        for expected in (
            "wait_live_exit",
            "live_exited",
            "gates_total",
            "service_start",
            "attestation_rotate",
            "server_start",
            "roles_launch",
            "roles_launched",
            "certificate_bind_open_record",
        ):
            assert expected in names, (expected, names)
        assert names.index("wait_live_exit") < names.index("gates_total") < names.index("roles_launch")
        assert timings["service_milestones"] == {"hello_human": 1.5, "match_started": 9.0}
        written = json.loads(supervisor.workspace.report_path.read_text(encoding="utf-8"))
        assert written["timings"]["stages"] == timings["stages"]
        handoff = supervisor.workspace.log_dir / "handoff.jsonl"
        assert handoff.is_file()
        enumerations = timings["counters"].get("process_enumeration")
        assert enumerations and enumerations["calls"] >= 1, timings["counters"]
        assert "handoff.jsonl" in result["report"]["log_index"]["files"]


def test_handoff_waits_use_the_handoff_poll_interval():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        assert config.handoff_poll_interval == practice_host.DEFAULT_HANDOFF_POLL_INTERVAL == 0.25
        assert config.poll_interval == practice_host.DEFAULT_POLL_INTERVAL
        sleeps = []
        opener = SequenceOpener(
            [FakeLiveHandle(1000.0, _live_image(config)), FakeLiveHandle(1000.0, _live_image(config))]
        )
        supervisor = _supervisor(config, make_request(), opener=opener, sleeper=sleeps.append)
        verdict = supervisor._wait_live()
        assert verdict["ok"] is True, verdict
        assert sleeps and set(sleeps) == {0.25}, sleeps
        for bad in (0, -1, True, "1"):
            try:
                practice_host.validate_config(make_config(tmp, handoff_poll_interval=bad))
            except practice_host.HostError:
                pass
            else:
                raise AssertionError(f"accepted handoff_poll_interval={bad!r}")


def test_attestation_wait_uses_the_handoff_poll_interval():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        captured = {}

        def fake_wait(cfg, **kwargs):
            captured.update(kwargs)
            return {"ok": True, "code": practice_host.CODE_OK}

        supervisor = _supervisor(config, make_request(), attestation_collector=None)
        supervisor.match_port = 8788
        with patched(practice_host, wait_for_attestation=fake_wait):
            supervisor._wait_attestation("n" * 32)
        assert captured["poll_interval"] == 0.25, captured


def test_live_exit_fallback_listing_is_throttled_to_the_poll_interval():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = launch_practice.ProcessInfo(1632, 1000.0, _live_image(config), name="Balatro")
        enumerator = SwitchEnumerator(0, [live])
        calls = {"n": 0}

        class Flip(launch_practice.ProcessEnumerator):
            def list(self):
                calls["n"] += 1
                return [live] if calls["n"] <= 2 else []

        sleeps = []
        verdict = practice_host.wait_for_live_exit(
            config,
            1632,
            1000.0,
            poll_interval=0.25,
            enumerator=Flip(),
            opener=SequenceOpener([]),
            clock=FakeClock(step=0.01),
            sleeper=sleeps.append,
        )
        assert verdict["ok"] is True, verdict
        assert sleeps == [1.0, 1.0], sleeps
        del enumerator


def test_timed_enumerator_propagates_listing_errors_and_still_counts():
    timer = practice_host.StageTimer()
    timed = practice_host._TimedEnumerator(
        FakeEnumerator(error=staging.StagingError("process_enumeration_failed")), timer
    )
    try:
        timed.list()
    except staging.StagingError:
        pass
    else:
        raise AssertionError("listing failure swallowed")
    assert timer.counters["process_enumeration"]["calls"] == 1


def test_gate_lockout_refusal_still_wins_over_open_records():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        practice_host.set_host_lockout(config, reason="session_unmeasured", session_id="s-old")
        api = FakeCertificateApi(open_records=[{"session_id": "s-old"}])
        supervisor = _supervisor(config, make_request(), certificate_api=api)
        verdict = supervisor._evaluate_gates()
        assert verdict["ok"] is False and verdict["code"] == practice_host.CODE_ACK_REQUIRED, verdict


def test_real_gate_evaluator_times_each_gate():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp, require_certificate=False)
        supervisor = _supervisor(config, make_request(), gate_evaluator=None)
        supervisor._gate_evaluator = supervisor._evaluate_gates
        supervisor._evaluate_gates()
        names = [entry["stage"] for entry in supervisor.timer.stages]
        assert names[:3] == ["gate_lockouts", "gate_runtime_preflight", "gate_static_isolation"], names


def test_service_milestones_are_first_occurrence_only():
    with tempfile.TemporaryDirectory() as tmp:
        service = practice_service.PracticeService(
            practice_service.ServiceConfig(
                session_id="sess-1",
                difficulty="competitive",
                pacing="instant",
                mode="normal",
                match_port=8788,
                log_root=Path(tmp) / "logs",
                content_hash="c" * 64,
                expected_config_digest="d" * 8,
                gauntlet=None,
            )
        )
        service._milestone("lobby_code")
        first = service.milestones()["lobby_code"]
        service._milestone("lobby_code")
        assert service.milestones()["lobby_code"] == first
        copy = service.milestones()
        copy["lobby_code"] = -1
        assert service.milestones()["lobby_code"] == first


def test_supervisor_builds_typed_descriptors_and_service_config():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        captured = {}

        def factory(cfg):
            captured["config"] = cfg
            return FakeService(cfg, port=51234, ended=True, terminal_phase="closed")

        ruleset = {
            "ruleset_id": "ruleset_mp_majorleague",
            "gamemode": "gamemode_mp_attrition",
            "forced_options": {"timer_base_seconds": 180, "timer_forgiveness": 0},
        }
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=factory,
            gate_evaluator=lambda: _gate_ok(config, config_digest="cafebabe", ruleset=ruleset),
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        service_config = captured["config"]
        assert service_config.session_id == supervisor.session_id
        assert service_config.expected_config_digest == "cafebabe"
        assert service_config.ruleset_id == "ruleset_mp_majorleague"
        assert service_config.gamemode == "gamemode_mp_attrition"
        assert dict(service_config.forced_options) == {"timer_base_seconds": 180, "timer_forgiveness": 0}
        # The host mints the session id; the menu value is correlation only (M6).
        assert supervisor.session_id != "correlation-1"
        assert practice_host.SESSION_ID_RE.match(supervisor.session_id)

        supervisor.service = FakeService(None, port=51234)
        descriptors = supervisor._build_descriptors("n" * 32, "c" * 64)
        assert set(descriptors) == {"human", "ai"}
        for role, descriptor in descriptors.items():
            assert isinstance(descriptor, launch_practice.SessionDescriptor)
            env = launch_practice.session_env_overrides(descriptor)
            assert set(env) == set(launch_practice.SESSION_ENV_KEYS.values())
            assert env["AISP_CONTROL_PORT"] == "51234"
            assert env["AISP_PROBE_NONCE"] == "n" * 32
            paths = staging.role_paths(config.staging_root, role)
            assert env["AISP_EXPECTED_ROLE_MODS_ROOT"] == str(paths.mods)
            assert launch_practice.session_descriptor_problems(descriptor, paths, "n" * 32) == []


def test_supervisor_starts_verified_server_before_roles():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        events = []

        def server_runner(command, cwd, env, log_dir):
            events.append("server")
            return FakeServer(pid=4242)

        def launch_runner(plan, **kwargs):
            events.append("roles")
            return FakeSession()

        supervisor = _supervisor(
            config,
            make_request(),
            server_runner=server_runner,
            launch_runner=launch_runner,
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="closed"),
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert events == ["server", "roles"]


def test_supervisor_mark_attested_after_probes_before_writing_files():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        events = []
        service = FakeService(None, events=events, ended=True, terminal_phase="closed")
        writer = lambda cfg, **kwargs: events.append("attestation_write") or {"ok": True, "code": practice_host.CODE_OK}
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            attestation_writer=writer,
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert service.attest_digest == "deadbeef"
        assert events.index("mark_attested") < events.index("attestation_write")


def test_supervisor_writes_attestation_with_control_and_match_ports_separately():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        captured = {}
        service = FakeService(None, port=51234, ended=True, terminal_phase="closed")

        def writer(cfg, **kwargs):
            captured.update(kwargs)
            return {"ok": True, "code": practice_host.CODE_OK}

        supervisor = _supervisor(config, make_request(), service_factory=lambda cfg: service, attestation_writer=writer)
        result = supervisor.run()
        assert result["ok"] is True, result
        assert captured["control_port"] == 51234
        assert captured["port"] == 8788


def test_supervisor_starts_prestart_window_after_publishing_attestations():
    """The pre-start clock starts only once the attestation files are published."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        events = []
        service = FakeService(None, events=events, ended=True, terminal_phase="closed")
        writer = lambda cfg, **kwargs: events.append("attestation_write") or {"ok": True, "code": practice_host.CODE_OK}
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            attestation_writer=writer,
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        # M8 order is unchanged (service attested first, then the files); the
        # pre-start window opens immediately after a successful publication.
        assert events.index("mark_attested") < events.index("attestation_write")
        assert events.index("attestation_write") < events.index("start_prestart_window")
        assert service.prestart_calls == 1


def test_supervisor_does_not_start_prestart_window_when_writes_fail():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        events = []
        service = FakeService(None, events=events)
        writer = lambda cfg, **kwargs: {"ok": False, "code": practice_host.CODE_ATTESTATION}
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            attestation_writer=writer,
        )
        result = supervisor.run()
        assert result["ok"] is False, result
        assert service.prestart_calls == 0
        assert "start_prestart_window" not in events


def test_supervisor_success_retains_human_and_keeps_server_until_exit():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        server = FakeServer()
        service = FakeService(None, ended=True, terminal_phase="closed")
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: session,
            server_runner=lambda command, cwd, env, log_dir: server,
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert supervisor.phase == "completed"
        # Server/service stay up until the human window exits, then are retired.
        assert service.closed == 1 and server.terminated == 1
        by_role = {item.role: item for item in session.owned}
        assert by_role["ai"].terminated == 1
        assert by_role["human"].terminated == 0
        assert supervisor.certificate_id == "cert1" and supervisor.backup_id == "bk1"
        assert supervisor.live_verdict["ok"] is True

        report = json.loads(supervisor.workspace.report_path.read_text(encoding="utf-8"))
        text = json.dumps(report)
        assert service.human_credential not in text and service.ai_credential not in text
        assert report["session_id"] == supervisor.session_id
        assert report["config_digest"] == "deadbeef"
        assert report["role_records"]
        assert report["descriptor_env_unbound"] == []

        supervisor.cleanup()
        assert by_role["human"].terminated == 1
        assert session.closed == 1


def test_supervisor_refuses_descriptor_env_gap():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        service = FakeService(None)
        launched = []
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: launched.append(plan) or FakeSession(),
        )
        with patched(practice_host, _descriptor_env_gap=lambda: ["AISP_NEW_NAME"]):
            result = supervisor.run()
        assert result["code"] == practice_host.CODE_DESCRIPTOR_ENV_GAP
        assert launched == []
        assert service.closed == 1


def test_supervisor_fails_closed_before_any_launch_on_bad_gates():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        launched = []
        supervisor = _supervisor(
            config,
            make_request(),
            gate_evaluator=lambda: {"ok": False, "code": practice_host.CODE_CERTIFICATE_REQUIRED},
            launch_runner=lambda plan, **kwargs: launched.append(plan) or FakeSession(),
        )
        result = supervisor.run()
        assert result["ok"] is False and result["code"] == practice_host.CODE_CERTIFICATE_REQUIRED
        assert launched == []
        assert supervisor.phase == "failed"


def test_supervisor_terminates_owned_handles_when_listener_unproven():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp, server_start_timeout=1.0)
        session = FakeSession()
        server = FakeServer()
        service = FakeService(None)
        launched = []
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: launched.append(plan) or session,
            server_runner=lambda command, cwd, env, log_dir: server,
            listener_probe=FakeListenerProbe({}),
        )
        result = supervisor.run()
        assert result["ok"] is False
        assert result["code"] == practice_host.CODE_SERVER_FAILED
        assert server.terminated == 1 and service.closed == 1
        # H3: the roles are never spawned when the server listener is unproven.
        assert launched == []


def test_supervisor_attestation_failure_terminates_owned_roles():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        supervisor = _supervisor(
            config,
            make_request(),
            launch_runner=lambda plan, **kwargs: session,
            attestation_collector=lambda cfg, nonce, spawn_time, port: {"ok": False, "code": practice_host.CODE_ATTESTATION, "problems": ["ai:guard_nonce_mismatch"]},
        )
        result = supervisor.run()
        assert result["code"] == practice_host.CODE_ATTESTATION
        assert all(item.terminated == 1 for item in session.owned)
        assert supervisor.attestation["code"] == practice_host.CODE_ATTESTATION


def test_supervisor_voids_and_locks_out_when_live_game_appears():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        service = FakeService(None)
        live_info = launch_practice.ProcessInfo(99, 1.0, _live_image(config), name="Balatro")
        # The live-exit wait enumerates twice, then live is closed for gates; the
        # supervise loop then sees the appeared live game.
        enumerator = SwitchEnumerator(closed_calls=3, then=[live_info])
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: session,
            enumerator=enumerator,
        )
        result = supervisor.run()
        assert result["code"] == practice_host.CODE_LIVE_APPEARED
        assert supervisor.phase == "void"
        assert supervisor.voided is True
        assert practice_host.read_host_lockout(config)["locked"] is True
        assert service.abort_calls == 1
        assert all(item.terminated == 1 for item in session.owned)
        assert session.closed == 1


def test_supervisor_never_claims_zero_diff_while_human_window_open():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="closed"),
            launch_runner=lambda plan, **kwargs: session,
            human_exit_waiter=lambda live_session, grace: False,
        )
        result = supervisor.run()
        assert result["code"] == practice_host.CODE_HUMAN_EXIT_UNVERIFIED
        assert supervisor.session is not None
        assert supervisor.live_verdict is None
        by_role = {item.role: item for item in session.owned}
        assert by_role["human"].terminated == 0
        report = json.loads(supervisor.workspace.report_path.read_text(encoding="utf-8"))
        assert report["human_retained"] is True
        assert report["live_verdict"] is None
        supervisor.cleanup()
        assert by_role["human"].terminated == 1


def test_supervisor_fails_on_unexpected_human_exit():
    """N-1: a human window that closes mid-match is a failure, not a completion."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession(roles=("human", "ai"))
        session.owned[0].running = False
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: FakeService(cfg),
            launch_runner=lambda plan, **kwargs: session,
        )
        result = supervisor.run()
        assert result["ok"] is False, result
        assert result["code"] == practice_host.CODE_HUMAN_EXIT_BEFORE_END, result


def test_supervisor_accepts_human_exit_after_authoritative_end():
    """N-1: a human window that closes after the service recorded human_end completes."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession(roles=("human", "ai"))
        session.owned[0].running = False
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="awaiting_ai"),
            launch_runner=lambda plan, **kwargs: session,
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert result["code"] == practice_host.CODE_OK


def test_supervisor_records_revocation_lockout_on_live_diff():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="closed"),
            launch_runner=lambda plan, **kwargs: session,
            verdict_recorder=lambda cfg, session_id, before, after, backup_id, certificate_id: {
                "ok": False,
                "code": "live_byte_diff_revoked",
                "changed_roots": ["install"],
            },
        )
        result = supervisor.run()
        assert result["code"] == practice_host.CODE_LIVE_CHANGED
        assert practice_host.read_host_lockout(config)["locked"] is True
        assert supervisor.live_verdict["changed_roots"] == ["install"]


def test_supervisor_closes_unmeasured_failure_as_failed_and_never_rebaselines():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        service = FakeService(None)
        api = FakeCertificateApi(events=[])
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: session,
            certificate_api=api,
            gate_evaluator=lambda: _gate_ok(config, open_record="/stage/open/s.json"),
            attestation_collector=lambda *args: {"ok": False, "code": practice_host.CODE_ATTESTATION},
            verdict_recorder=lambda *args: {"ok": None, "code": "live_verdict_failed"},
        )
        result = supervisor.run()
        assert result["ok"] is False
        # H-A-1: the still-open record is now closed as a measured failure so it can
        # never wedge the next ticket or acknowledgement.
        assert supervisor._record_started is False
        assert api.failure_calls and api.failure_calls[-1]["reason"] == "live_verdict_failed"
        # The persistent lockout is retained: the next session can never silently
        # re-baseline (C1); only an explicit acknowledge clears it.
        assert practice_host.read_host_lockout(config)["locked"] is True
        assert supervisor.open_record == "/stage/open/s.json"
        report = json.loads(supervisor.workspace.report_path.read_text(encoding="utf-8"))
        assert report["open_record"] == "/stage/open/s.json"


def test_supervisor_clears_unmeasured_lockout_only_on_a_measured_pass():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()
        api = FakeCertificateApi(events=[])
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="closed"),
            launch_runner=lambda plan, **kwargs: session,
            certificate_api=api,
            gate_evaluator=lambda: _gate_ok(config, open_record="/stage/open/s.json"),
            verdict_recorder=None,
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert api.verdict_calls == 1
        assert practice_host.read_host_lockout(config)["locked"] is False
        assert api.bind_calls and api.bind_calls[0]["pids"]
        # The retained session and the real live-closed check reach the certificate.
        assert api.session_seen is session
        assert api.live_closed_seen is True


def test_supervisor_forwards_prepared_open_session_to_launcher():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        captured = {}

        def runner(plan, **kwargs):
            captured.update(kwargs)
            return FakeSession()

        record = {"status": "open", "session_id": "s-1", "nonce": "n" * 32, "phase": isolation_certificate.MATCH}
        supervisor = _supervisor(
            config,
            make_request(),
            launch_runner=runner,
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="closed"),
            gate_evaluator=lambda: _gate_ok(config, open_session=record),
        )
        result = supervisor.run()
        assert result["ok"] is True, result
        assert captured["open_session"] == record
        assert "nonce_factory" not in captured


def test_supervisor_prepare_session_preserves_certificate_content_identity():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        Path(config.staging_root).mkdir(parents=True, exist_ok=True)
        live = _synthetic_live(config)
        prepared = practice_host.prepare_live_baseline(
            config, live, backup_runner=_real_backup_runner, sleeper=lambda _s: None, label="display-label-3"
        )
        assert prepared["ok"] is True, prepared
        satisfied = lambda staging_root, live=None, port=None: {
            "ok": True, "code": "ok", "certificate_id": "cert-fixture",
        }
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            baseline_preparer=lambda cfg, live_map: prepared,
        )
        supervisor.match_port = 8788
        with patched(isolation_certificate, check_certificate=satisfied):
            verdict = supervisor._prepare_session(live)
        assert verdict["ok"] is True, verdict
        # The certificate's returned identity is authoritative and never rewritten
        # to the runner label.
        assert verdict["backup_id"] == prepared["backup_id"]
        assert verdict["record"]["backup_id"] == prepared["backup_id"]

        # A certificate that disagrees with the verifier identity is a refusal, not a
        # silent overwrite of the returned evidence.
        divergent = FakeCertificateApi(
            prepare={
                "ok": True,
                "code": "session_prepared",
                "nonce": "n" * 32,
                "backup_id": "f" * 64,
                "open_record": "/stage/open/x.json",
                "record": {"status": "open", "session_id": "x", "backup_id": "f" * 64},
            }
        )
        other = _supervisor(
            config,
            make_request(),
            certificate_api=divergent,
            baseline_preparer=lambda cfg, live_map: prepared,
        )
        other.match_port = 8788
        refused = other._prepare_session(live)
        assert refused["ok"] is False
        assert "prepared_backup_id_mismatch" in refused["problems"], refused


def test_supervisor_refuses_missing_config_digest_before_service_start():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        events = []
        launched = []

        def factory(cfg):
            events.append("service")
            return FakeService(cfg, ended=True, terminal_phase="closed")

        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=factory,
            launch_runner=lambda plan, **kwargs: launched.append(plan) or FakeSession(),
            # A content hash is present, but the required derived config digest is not.
            gate_evaluator=lambda: _gate_ok(config, config_digest=None, content_hash="c" * 64),
        )
        result = supervisor.run()
        assert result["ok"] is False
        assert result["code"] == practice_host.CODE_CONFIG_DIGEST
        assert events == [] and launched == []
        report = json.loads(supervisor.workspace.report_path.read_text(encoding="utf-8"))
        assert report["config_digest"] is None


def test_default_launch_runner_uses_open_session_not_nonce_factory():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        plan = {
            "schema": "aisparring.launch_plan.v1",
            "session_id": "s-1",
            "staging_root": str(config.staging_root),
            "backup_root": str(config.backup_root),
            "live_install_root": str(config.live_install_root),
            "port": 8788,
            "may_launch": True,
        }
        open_session = {
            "status": "open",
            "session_id": "s-1",
            "nonce": "n" * 32,
            "phase": isolation_certificate.MATCH,
        }
        # Real launcher API shape (M1): the launcher reloads the persisted open
        # record from disk; the caller mapping is never trusted on its own.
        staging_root = Path(config.staging_root)
        staging_root.mkdir(parents=True, exist_ok=True)
        isolation_certificate._write_open_record(
            staging_root,
            {
                "schema": isolation_certificate.OPEN_SESSION_SCHEMA,
                "session_id": "s-1",
                "phase": isolation_certificate.MATCH,
                "nonce": "n" * 32,
                "port": 8788,
                "certificate_id": "cert-fixture",
                "status": "open",
                "pids": {},
            },
        )
        # Real launcher path: the prepared record (not a nonce factory) is the
        # contract; a blocked re-derived plan must return cleanly, never TypeError.
        session = practice_host._default_launch_runner(
            plan,
            session_descriptors={"human": object(), "ai": object()},
            nonce="n" * 32,
            enumerator=FakeEnumerator([]),
            open_session=open_session,
        )
        assert isinstance(session, launch_practice.LaunchSession)
        assert session.code == "launch_blocked"

        # Without a prepared open record the launcher refuses instead of spawning.
        refused = practice_host._default_launch_runner(
            plan, session_descriptors=None, nonce="n" * 32, enumerator=FakeEnumerator([]), open_session=None
        )
        assert isinstance(refused, launch_practice.LaunchSession)
        assert refused.code == "open_session_required"


def test_record_live_verdict_uses_real_certificate_closure_api():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        staging_root = Path(config.staging_root)
        staging_root.mkdir(parents=True, exist_ok=True)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        before = isolation_certificate.snapshot_live(live)
        session_id, nonce = "s-real", "n" * 32
        backup_id = "b" * 64
        record = {
            "schema": isolation_certificate.OPEN_SESSION_SCHEMA,
            "session_id": session_id,
            "phase": isolation_certificate.MATCH,
            "nonce": nonce,
            "port": 8788,
            "certificate_id": "cert1",
            "backup_id": backup_id,
            "backup_label": "display-label",
            "live_roots": {key: str(value) for key, value in live.items()},
            "before": {"digest": before["digest"], "roots": isolation_certificate._digest_roots(before)},
            "before_files": before["roots"],
            "spawn_time": 1000.0,
            "pids": {"human": [11], "ai": [22]},
            "status": "open",
            "created_unix": int(__import__("time").time()) - 1,
        }
        isolation_certificate._write_open_record(staging_root, record)

        session = FakeSession(roles=("human", "ai"))
        session.session_id = session_id
        session.nonce = nonce
        for role in session.owned:
            role.running = False

        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            verdict_recorder=None,
            launch_runner=lambda plan, **kw: session,
        )
        supervisor.session = session
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(isolation_certificate._open_record_path(staging_root, session_id))
        supervisor.backup_id = backup_id
        supervisor.certificate_id = "cert1"

        verdict = supervisor._record_live_verdict()
        assert verdict is not None and verdict.get("ok") is True, verdict
        assert isolation_certificate.load_open_record(staging_root, session_id)["status"] == "closed"

        # A still-running owned handle must be an explicit closure refusal.
        other_id = "s-real-2"
        isolation_certificate._write_open_record(
            staging_root, {**record, "session_id": other_id, "status": "open"}
        )
        running = FakeSession(roles=("human", "ai"))
        running.session_id = other_id
        running.nonce = nonce
        supervisor.session = running
        supervisor.session_id = other_id
        supervisor.open_record = str(isolation_certificate._open_record_path(staging_root, other_id))
        refused = supervisor._record_live_verdict()
        assert refused["ok"] is False and "owned_processes_running" in refused["problems"], refused


def test_supervisor_launch_failure_never_touches_live():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        service = FakeService(None)
        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=lambda cfg: service,
            launch_runner=lambda plan, **kwargs: FakeSession(ok=False, code="launch_blocked"),
        )
        result = supervisor.run()
        assert result["ok"] is False and result["code"] == "launch_blocked"
        assert service.closed == 1
        assert supervisor.session is None


def test_create_session_workspace_refuses_existing_and_bad_ids():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        space = practice_host.create_session_workspace(config, "s-good")
        assert space.root.is_dir()
        try:
            practice_host.create_session_workspace(config, "s-good")
        except practice_host.HostError as error:
            assert error.code == practice_host.CODE_SESSION_WORKSPACE_EXISTS
        else:
            raise AssertionError("expected workspace refusal")
        for bad in ("bad:id", "..", "", "a" * 65):
            try:
                practice_host.create_session_workspace(config, bad)
            except practice_host.HostError as error:
                assert error.code in (practice_host.CODE_BAD_REQUEST, practice_host.CODE_SESSION_WORKSPACE_EXISTS)
            else:
                raise AssertionError(f"expected refusal for {bad!r}")


def test_mint_session_id_matches_shared_grammar():
    for _ in range(50):
        value = practice_host.mint_session_id()
        assert practice_host.SESSION_ID_RE.match(value)


# ---------------------------------------------------------------------------
# Real service + server environment + developer launcher
# ---------------------------------------------------------------------------

class _FakeSourceProvider:
    def source(self, difficulty):
        return "return function() return nil end"


class _FakeWorkerRunner:
    def __call__(self, request, timeout, register):
        return {"ok": False, "code": "policy_unsupported"}


def _real_service_config(tmp, session_id="sess-1"):
    return practice_service.ServiceConfig(
        session_id=session_id,
        difficulty="competitive",
        pacing="instant",
        mode="normal",
        match_port=8788,
        log_root=Path(tmp) / "logs",
        content_hash="c" * 64,
        expected_config_digest="deadbeef",
        gauntlet=None,
    )


def test_real_service_starts_on_loopback_and_authorizes():
    with tempfile.TemporaryDirectory() as tmp:
        service = practice_host.practice_service.PracticeService(
            _real_service_config(tmp), source_provider=_FakeSourceProvider(), worker_runner=_FakeWorkerRunner()
        )
        try:
            port = service.start()
            assert 1 <= port <= 65535
            assert len(service.human_credential) == 64
            assert service.human_credential != service.ai_credential
            assert service.mark_attested("deadbeef") is True
            try:
                service.mark_attested("0" * 8)
            except practice_service.PracticeError:
                pass
            else:
                raise AssertionError("expected digest mismatch refusal")
            authorized = service.handle_request(
                {
                    "session": "sess-1",
                    "credential": service.human_credential,
                    "role": "human",
                    "op": "status",
                    "sequence": 0,
                    "observation": None,
                }
            )
            assert authorized["ok"] is True
            rejected = service.handle_request(
                {
                    "session": "sess-1",
                    "credential": "0" * 64,
                    "role": "human",
                    "op": "status",
                    "sequence": 0,
                    "observation": None,
                }
            )
            assert rejected["code"] == "practice_bad_credential"
        finally:
            service.close()


def test_server_environment_is_allowlisted_and_keeps_sqlite_session_local():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        base = {
            "PATH": "C:/Windows",
            "SystemRoot": "C:/Windows",
            "APPDATA": "C:/live/appdata",
            "LOVELY_MOD_DIR": "C:/live/mods",
            "AISP_SESSION_ID": "leak",
            "STEAM_APP_ID": "1",
            "PYTHONPATH": "x",
        }
        session_dir = Path(config.session_root) / "s-session" / "server"
        env = practice_host.server_environment(config, 8788, 8789, base_env=base, session_dir=session_dir)
        assert env["PORT"] == "8788" and env["ADMIN_PORT"] == "8789"
        assert env["PATH"] == "C:/Windows"
        for forbidden in ("APPDATA", "LOVELY_MOD_DIR", "AISP_SESSION_ID", "STEAM_APP_ID", "PYTHONPATH"):
            assert forbidden not in env
        # M-5: the ban/rate database is per-session, never shared in server_root.
        assert Path(env["LOG_HASH_DB_PATH"]).is_relative_to(session_dir)
        assert not Path(env["LOG_HASH_DB_PATH"]).is_relative_to(Path(config.server_root))


def test_developer_launcher_writes_only_inside_repo():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        inside = practice_host.generate_developer_launcher(config)
        assert inside["ok"] is True
        assert all(Path(item).is_file() for item in inside["scripts"])
        assert all(staging.is_within(config.repo_root, item, allow_root=True) for item in inside["scripts"])
        # Generated scripts run under the interpreter that generated them (the
        # provisioned venv), never a transient PYTHONPATH/global python.
        for item in inside["scripts"]:
            assert sys.executable in Path(item).read_text(encoding="utf-8")

        outside = practice_host.generate_developer_launcher(config, directory=Path(tmp) / "elsewhere")
        assert outside["ok"] is False
        assert outside["code"] == "practice_host_output_outside_repo"


# ---------------------------------------------------------------------------
# Resumed-review repairs: H-A/H-B/H-C and M-1..M-7
# ---------------------------------------------------------------------------


class _FakePopen:
    def __init__(self, pid=5555):
        self.pid = pid
        self.killed = 0

    def kill(self):
        self.killed += 1

    def poll(self):
        return None


class _FakeJob:
    def __init__(self, assign_ok=True):
        self.assign_ok = assign_ok
        self.assigned = 0
        self.closed = 0
        self.terminated = 0

    def assign(self, proc):
        if not self.assign_ok:
            return False
        self.assigned += 1
        return True

    def close(self):
        self.closed += 1

    def terminate(self):
        self.terminated += 1


def test_default_server_runner_suspended_job_identity_and_queried_image():
    """M-1: the verified absolute Node path is launched with retained ownership."""
    with tempfile.TemporaryDirectory() as tmp:
        calls = {}
        proc = _FakePopen(pid=5555)
        job = _FakeJob()
        resumed = []

        def popen(command, **kwargs):
            calls["command"] = list(command)
            calls["creationflags"] = kwargs.get("creationflags")
            return proc

        node = str(Path(sys.executable))
        owned = practice_host.default_server_runner(
            [node, "dist/main.js"],
            tmp,
            {"PORT": "8788"},
            Path(tmp) / "logs",
            popen=popen,
            job_factory=lambda: job,
            resume=lambda p: resumed.append(p.pid) or True,
            create_time_reader=lambda owned_process: 1000.0,
            image_reader=lambda pid: node,
            on_windows=True,
        )
        assert calls["command"][0] == node
        assert calls["creationflags"] == launch_practice.CREATE_SUSPENDED
        assert job.assigned == 1 and resumed == [5555]
        assert owned.create_time == 1000.0 and owned.job is job
        # The recorded image is the queried handle path, never the bare command.
        assert owned.image_path == node


def test_default_server_runner_fails_closed_without_job_time_or_identity():
    """M-1: a missing job, create time or mismatched image terminates the child."""
    with tempfile.TemporaryDirectory() as tmp:
        node = str(Path(sys.executable))
        base = dict(
            command=[node, "dist/main.js"],
            cwd=tmp,
            env={"PORT": "8788"},
            log_dir=Path(tmp) / "logs",
            on_windows=True,
        )

        def expect_failure(*, spawns=True, **overrides):
            proc = _FakePopen(pid=6666)
            spawned = []
            kwargs = dict(base)
            kwargs["popen"] = lambda command, **kw: spawned.append(True) or proc
            kwargs["job_factory"] = overrides.pop("job_factory", lambda: _FakeJob())
            kwargs["resume"] = lambda p: True
            kwargs["create_time_reader"] = overrides.pop("create_time_reader", lambda owned: 1000.0)
            kwargs["image_reader"] = overrides.pop("image_reader", lambda pid: node)
            kwargs.update(overrides)
            try:
                practice_host.default_server_runner(**kwargs)
            except practice_host.HostError as error:
                assert error.code == practice_host.CODE_SERVER_FAILED
            else:
                raise AssertionError("expected a fail-closed server spawn")
            assert bool(spawned) is spawns
            if spawns:
                assert proc.killed == 1

        # A missing Job Object on Windows is mandatory-before-start: no spawn at all.
        expect_failure(spawns=False, job_factory=lambda: None)
        # A missing create time is never accepted.
        expect_failure(create_time_reader=lambda owned: None)
        # An image path that is not the launched executable is refused.
        expect_failure(image_reader=lambda pid: str(Path(tmp) / "other" / "node.exe"))


def test_verify_local_listener_requires_exact_owner_set():
    """M-2: a foreign loopback listener beside Node's fails the owner proof."""
    foreign = practice_host.verify_local_listener(
        8788,
        8789,
        probe=FakeListenerProbe(
            {8788: {"listening": True, "addresses": ["127.0.0.1", "::1"], "pids": [7, 999]}}
        ),
        expected_pid=7,
    )
    assert foreign["ok"] is False
    assert "match_listener_not_owned" in foreign["problems"]
    assert foreign["owner_proven"] is None


def test_default_start_gate_refuses_before_acknowledgement():
    """M-3: the non-game gates run before the quit acknowledgement."""
    with tempfile.TemporaryDirectory() as tmp:
        unconfigured = make_config(tmp, match_port=None)
        verdict = practice_host.default_start_gate(
            unconfigured, certificate_api=FakeCertificateApi(), which=_which_python
        )
        assert verdict["code"] == practice_host.CODE_MATCH_PORT_UNCONFIGURED

        configured = make_config(tmp)
        missing_server = practice_host.default_start_gate(
            configured, certificate_api=FakeCertificateApi(), which=_which_python
        )
        assert missing_server["code"] == practice_host.CODE_SERVER_ADAPTATION

        bad_cert = FakeCertificateApi(check={"ok": False, "code": "certificate_invalid", "problems": ["mods_layer_changed"]})
        refused = practice_host.default_start_gate(configured, certificate_api=bad_cert, which=_which_python)
        assert refused["code"] == practice_host.CODE_CERTIFICATE_REQUIRED


def test_daemon_refuses_acknowledgement_when_start_gate_fails():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp, match_port=None)
        created = []
        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            supervisor_factory=lambda cfg, request: created.append(request) or FakeSupervisor(block=threading.Event()),
        )
        daemon.start()
        try:
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_MATCH_PORT_UNCONFIGURED, refused
            assert created == []
            # The reservation is released, so the daemon is not stuck busy.
            assert daemon._ticket is None
        finally:
            daemon.stop()


def test_daemon_start_reserves_ticket_atomically_before_preflight():
    """M-4: two concurrent starts cannot both be admitted."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        entered = threading.Event()
        release = threading.Event()
        created = []

        def gate():
            entered.set()
            release.wait(5)
            return {"ok": True, "code": practice_host.CODE_OK}

        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            start_gate=gate,
            supervisor_factory=lambda cfg, request: created.append(request) or FakeSupervisor(block=threading.Event()),
        )
        daemon.start()
        try:
            first = {}

            def run_first():
                first["response"] = daemon.handle_request(envelope(daemon, "start", make_request()))

            thread = threading.Thread(target=run_first)
            thread.start()
            assert entered.wait(5)
            second = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert second["code"] == practice_host.CODE_TICKET_ACTIVE, second
            release.set()
            thread.join(5)
            assert first["response"]["ok"] is True, first
            assert len(created) == 1
        finally:
            release.set()
            daemon.stop()


def test_daemon_releases_reserved_ticket_when_factory_raises():
    """Low: a supervisor-factory/workspace failure must not leak the ticket slot."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)

        def factory(cfg, request):
            raise RuntimeError("supervisor workspace init failed")

        daemon = practice_host.HostDaemon(
            config,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
            runtime_checker=_ok_runtime_checker,
            start_gate=lambda: {"ok": True, "code": practice_host.CODE_OK},
            supervisor_factory=factory,
        )
        daemon.start()
        try:
            refused = daemon.handle_request(envelope(daemon, "start", make_request()))
            assert refused["code"] == practice_host.CODE_INTERNAL, refused
            # The reservation is released, so a later start is not stuck ``ticket_active``.
            assert daemon._ticket is None
        finally:
            daemon.stop()


def _real_open_record(config, session_id, live, *, pids=None, backup_id="b" * 64):
    staging_root = Path(config.staging_root)
    staging_root.mkdir(parents=True, exist_ok=True)
    before = isolation_certificate.snapshot_live(live)
    record = {
        "schema": isolation_certificate.OPEN_SESSION_SCHEMA,
        "session_id": session_id,
        "phase": isolation_certificate.MATCH,
        "nonce": "n" * 32,
        "port": 8788,
        "certificate_id": "cert1",
        "backup_id": backup_id,
        "backup_label": "display-label",
        "live_roots": {key: str(value) for key, value in live.items()},
        "before": {"digest": before["digest"], "roots": isolation_certificate._digest_roots(before)},
        "before_files": before["roots"],
        "spawn_time": 1000.0,
        "pids": dict(pids or {}),
        "status": "open",
        "created_unix": int(time.time()) - 1,
    }
    isolation_certificate._write_open_record(staging_root, record)
    return record


def _receipts(config):
    staging_root = Path(config.staging_root)
    return isolation_certificate._read_jsonl(
        staging_root / isolation_certificate.EVIDENCE_DIR / isolation_certificate.RECEIPTS_REL
    )


def test_supervisor_no_spawn_failure_closes_record_and_clears_unmeasured_lockout():
    """H-A: a pre-spawn failure closes the never-spawned record, not wedges it."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-nospawn"
        _real_open_record(config, session_id, live)
        supervisor = _supervisor(
            config, make_request(), certificate_api=isolation_certificate, verdict_recorder=None
        )
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(
            isolation_certificate._open_record_path(Path(config.staging_root), session_id)
        )
        supervisor._record_started = True
        supervisor._unmeasured_lockout = True
        practice_host.set_host_lockout(config, reason="session_unmeasured", session_id=session_id)

        result = supervisor._fail(practice_host.CODE_SERVER_FAILED)
        assert result["ok"] is False and result["code"] == practice_host.CODE_SERVER_FAILED
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "closed" and closed["close_problems"] == []
        receipts = [row for row in _receipts(config) if row.get("session_id") == session_id]
        assert receipts and receipts[-1]["verdict"] == "no_spawn"
        assert practice_host.read_host_lockout(config)["locked"] is False


def test_supervisor_void_closes_record_as_failed_and_allows_acknowledge():
    """H-B: void -> failure receipt -> the existing acknowledge op completes."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-void"
        _real_open_record(config, session_id, live, pids={"human": [11], "ai": [22]})
        session = FakeSession(roles=("human", "ai"))
        session.session_id = session_id
        session.nonce = "n" * 32
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            verdict_recorder=None,
            launch_runner=lambda plan, **kwargs: session,
        )
        supervisor.session = session
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(
            isolation_certificate._open_record_path(Path(config.staging_root), session_id)
        )
        supervisor._record_started = True

        result = supervisor._void(practice_host.CODE_LIVE_APPEARED)
        assert result["code"] == practice_host.CODE_LIVE_APPEARED
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "failed"
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is True

        # The existing daemon acknowledge op clears both the host and certificate lockouts.
        daemon = practice_host.HostDaemon(
            config, certificate_api=isolation_certificate, opener=_live_opener(config), enumerator=FakeEnumerator([])
        )
        ack = daemon._op_acknowledge({"confirm": True})
        assert ack["ok"] is True and ack["cleared"] is True, ack
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False


class _StubbornHumanSession:
    """A retained-session stand-in whose owned handles still read as running.

    Mirrors the real ``LaunchSession`` surface the certificate's closure check uses
    (``session_id``/``nonce``/``is_running``) without owning a real process, so the
    real ``record_session_verdict`` returns ``session_closure_unproven``.
    """

    def __init__(self, session_id, nonce):
        self.session_id = session_id
        self.nonce = nonce
        self.spawn_time = 1000.0
        self.owned = []
        self.closed = 0

    def is_running(self):
        return [{"role": "human", "pid": 7, "running": True}]

    def close(self):
        self.closed += 1


def test_supervisor_prelaunch_live_reappearance_closes_record_and_recovers():
    """H-A-1: a live game reappearing before the spawn still closes the record."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-prelaunch-live"
        _real_open_record(config, session_id, live)
        live_info = launch_practice.ProcessInfo(99, 1.0, _live_image(config), name="Balatro")
        # Closed for the live-exit wait, then live reappears at the pre-launch check.
        enumerator = SwitchEnumerator(closed_calls=1, then=[live_info])
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            enumerator=enumerator,
            gate_evaluator=lambda: _gate_ok(
                config,
                open_record=str(
                    isolation_certificate._open_record_path(Path(config.staging_root), session_id)
                ),
                live_map=live,
            ),
        )
        supervisor.session_id = session_id

        result = supervisor.run()
        assert result["code"] == practice_host.CODE_LIVE_APPEARED, result
        assert supervisor.voided is True
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "failed"
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is True

        daemon = practice_host.HostDaemon(
            config, certificate_api=isolation_certificate, opener=_live_opener(config), enumerator=FakeEnumerator([])
        )
        ack = daemon._op_acknowledge({"confirm": True})
        assert ack["ok"] is True and ack["cleared"] is True, ack
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False


def test_supervisor_refused_closure_closes_record_and_recovers():
    """H-A-1: a real ``session_closure_unproven`` refusal closes the record as failed."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-unproven"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _StubbornHumanSession(session_id, "n" * 32)
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            verdict_recorder=None,
            launch_runner=lambda plan, **kwargs: session,
        )
        supervisor.session = session
        supervisor.service = FakeService(None, ended=True, terminal_phase="awaiting_ai")
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(
            isolation_certificate._open_record_path(Path(config.staging_root), session_id)
        )
        supervisor._record_started = True
        supervisor._unmeasured_lockout = True
        practice_host.set_host_lockout(config, reason="session_unmeasured", session_id=session_id)

        result = supervisor._finalize_after_run()
        assert result["ok"] is False, result
        assert result["code"] == "session_closure_unproven", result
        assert supervisor.human_retained is False
        assert session.closed == 1
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "failed"
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is True

        daemon = practice_host.HostDaemon(
            config, certificate_api=isolation_certificate, opener=_live_opener(config), enumerator=FakeEnumerator([])
        )
        ack = daemon._op_acknowledge({"confirm": True})
        assert ack["ok"] is True and ack["cleared"] is True, ack
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False


class _StuckOwnedRole:
    """Owned handle whose terminate cannot stop it (mirrors a stuck Job Object)."""

    def __init__(self, role, pid):
        self.role = role
        self.pid = pid
        self.running = True
        self.terminated = 0

    def is_running(self):
        return self.running

    def terminate(self, timeout=10.0):
        self.terminated += 1
        return {"role": self.role, "pid": self.pid, "terminated": False}


class _FailedCloseSession:
    """Session whose close raises while its owned human still runs (root repro)."""

    def __init__(self, session_id, nonce):
        self.session_id = session_id
        self.nonce = nonce
        self.spawn_time = 1000.0
        self.owned = [_StuckOwnedRole("human", 7)]
        self.closed = 0

    def is_running(self):
        return [
            {"role": item.role, "pid": item.pid, "running": item.is_running()}
            for item in self.owned
        ]

    def close(self):
        self.closed += 1
        raise OSError("synthetic failed Job close")


class _LingeringOwnedRole:
    """Owned handle that only reports exit a few queries after ``terminate``."""

    def __init__(self, role, pid, steps=3):
        self.role = role
        self.pid = pid
        self.running = True
        self.terminated = 0
        self._steps = int(steps)
        self._countdown = None

    def is_running(self):
        if self._countdown is None:
            return self.running
        if self._countdown > 0:
            self._countdown -= 1
            return True
        return False

    def terminate(self, timeout=10.0):
        self.terminated += 1
        self._countdown = self._steps
        return {"role": self.role, "pid": self.pid, "terminated": True}


class _LingeringSession:
    """Session whose owned handle exits only after a bounded delay."""

    def __init__(self, session_id, nonce, steps=3):
        self.session_id = session_id
        self.nonce = nonce
        self.spawn_time = 1000.0
        self.owned = [_LingeringOwnedRole("human", 7, steps)]
        self.closed = 0

    def is_running(self):
        return [
            {"role": item.role, "pid": item.pid, "running": item.is_running()}
            for item in self.owned
        ]

    def close(self):
        self.closed += 1


def _refused_closure_supervisor(config, session_id, session, live):
    supervisor = _supervisor(
        config,
        make_request(),
        certificate_api=isolation_certificate,
        verdict_recorder=None,
        launch_runner=lambda plan, **kwargs: session,
    )
    supervisor.session = session
    supervisor.service = None
    supervisor.session_id = session_id
    supervisor._gates = {"live_map": live}
    supervisor.open_record = str(
        isolation_certificate._open_record_path(Path(config.staging_root), session_id)
    )
    supervisor._record_started = True
    supervisor._unmeasured_lockout = True
    practice_host.set_host_lockout(config, reason="session_unmeasured", session_id=session_id)
    return supervisor


def test_supervisor_failed_close_retains_owned_process_and_open_record():
    """Root repro: a failed Job close while the owned human still runs must
    neither drop the handle nor record a failure closure."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-failed-close"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _FailedCloseSession(session_id, "n" * 32)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)

        result = supervisor._finalize_refused_closure("session_closure_unproven")
        assert result["ok"] is False, result
        # Ownership retained: the handle is never dropped on a swallowed failure.
        assert supervisor.session is session
        assert supervisor.human_retained is True
        # The open record stands and no failure closure/receipt was written.
        assert supervisor._record_started is True
        assert isolation_certificate.list_open_records(Path(config.staging_root))
        still_open = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert still_open["status"] == "open"
        assert not [row for row in _receipts(config) if row.get("session_id") == session_id]
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False
        assert practice_host.read_host_lockout(config)["locked"] is True


def test_supervisor_eventual_exit_closes_record_and_recovers():
    """A delayed (but proven) owned exit still closes the record; ack then clears."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        install = Path(tmp) / "live" / "install"
        appdata = Path(tmp) / "live" / "appdata"
        install.mkdir(parents=True, exist_ok=True)
        appdata.mkdir(parents=True, exist_ok=True)
        live = {"install": str(install), "appdata": str(appdata)}
        session_id = "s-eventual-exit"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _LingeringSession(session_id, "n" * 32, steps=3)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)

        result = supervisor._finalize_refused_closure("session_closure_unproven")
        assert result["ok"] is False, result
        assert result["code"] == "session_closure_unproven", result
        assert supervisor.human_retained is False
        assert supervisor.session is None
        assert session.closed == 1
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "failed"
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is True

        daemon = practice_host.HostDaemon(
            config,
            certificate_api=isolation_certificate,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
        )
        ack = daemon._op_acknowledge({"confirm": True})
        assert ack["ok"] is True and ack["cleared"] is True, ack
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False


def test_record_failure_closure_keeps_record_open_on_persist_failure():
    """Persistence-exception: a raised/refused closure must not clear the flag."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        supervisor = _supervisor(config, make_request())
        supervisor.session_id = "s-persist"
        supervisor._record_started = True

        class _RaisingApi:
            def record_session_failure(self, *args, **kwargs):
                raise RuntimeError("certificate write failed")

        supervisor._certificate_api = _RaisingApi()
        assert supervisor._record_failure_closure("session_closure_unproven") is False
        assert supervisor._record_started is True

        class _RefusingApi:
            def record_session_failure(self, *args, **kwargs):
                return {"ok": False, "code": "open_session_missing"}

        supervisor._certificate_api = _RefusingApi()
        assert supervisor._record_failure_closure("session_closure_unproven") is False
        assert supervisor._record_started is True

        class _OkApi:
            def record_session_failure(self, *args, **kwargs):
                return {"ok": True, "code": "session_failed_recorded"}

        supervisor._certificate_api = _OkApi()
        assert supervisor._record_failure_closure("session_closure_unproven") is True
        assert supervisor._record_started is False


def test_supervisor_fails_on_real_service_prestart_timeout():
    """H-C: the real service's pre-start timeout is a failure, never a completion."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        session = FakeSession()

        def factory(service_config):
            return practice_service.PracticeService(
                service_config,
                source_provider=_FakeSourceProvider(),
                worker_runner=_FakeWorkerRunner(),
                prestart_timeout=0.2,
                role_timeout=0.0,
                watchdog_interval=0.02,
            )

        supervisor = _supervisor(
            config,
            make_request(),
            service_factory=factory,
            launch_runner=lambda plan, **kwargs: session,
            clock=time.monotonic,
            sleeper=lambda seconds: time.sleep(min(float(seconds), 0.01)),
        )
        result = supervisor.run()
        assert result["ok"] is False, result
        assert result["code"] == "practice_service_aborted", result
        report = result["report"]
        assert report["supervision"]["reason"] == practice_service.CODE_PRESTART_TIMEOUT, report["supervision"]


class _RecoverableOwnedRole:
    """Owned handle that cannot be stopped until ``session.recover`` is flipped."""

    def __init__(self, role, pid, session):
        self.role = role
        self.pid = pid
        self.session = session
        self.terminated = 0

    def is_running(self):
        return not self.session.recover

    def terminate(self, timeout=10.0):
        self.terminated += 1
        return {"role": self.role, "pid": self.pid, "terminated": self.session.recover}


class _RecoverableHumanSession:
    """Real-certificate owned session whose first close fails while the human runs.

    Mirrors a stuck Job Object: the first ``close`` raises while the owned human
    still reports running, then the handle finally exits and the close succeeds.
    """

    def __init__(self, session_id, nonce):
        self.session_id = session_id
        self.nonce = nonce
        self.spawn_time = 1000.0
        self.recover = False
        self.closed = 0
        self.owned = [_RecoverableOwnedRole("human", 7, self)]

    def is_running(self):
        return [
            {"role": item.role, "pid": item.pid, "running": item.is_running()}
            for item in self.owned
        ]

    def close(self):
        self.closed += 1
        if not self.recover:
            raise OSError("synthetic stuck Job close")


class _StuckAiSession(_FailedCloseSession):
    """A spawned session whose owned AI survives termination (a stuck Job)."""

    def __init__(self, session_id, nonce):
        super().__init__(session_id, nonce)
        self.owned = [_StuckOwnedRole("ai", 8)]


class _RetryRecordingSupervisor:
    """Minimal supervisor stand-in that records pending-closure retries."""

    def __init__(self, result=True):
        self.phase = "failed"
        self.error = None
        self.calls = 0
        self.result = result

    def retry_pending_closure(self):
        self.calls += 1
        return self.result


def _synthetic_livepair(config):
    install = Path(config.live_install_root)
    appdata = Path(config.live_appdata_root)
    install.mkdir(parents=True, exist_ok=True)
    appdata.mkdir(parents=True, exist_ok=True)
    return {"install": str(install), "appdata": str(appdata)}


def test_supervisor_real_certificate_human_end_after_exit_completes():
    """N-1-R: a genuine human_end with the human already exited must pass with the
    real certificate, close the record and leave no lockouts (no failure stamp)."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-human-end"
        _real_open_record(config, session_id, live, pids={"human": [7], "ai": [8]})
        session = FakeSession(roles=("human", "ai"))
        session.session_id = session_id
        session.nonce = "n" * 32
        for role in session.owned:
            role.running = False
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            verdict_recorder=None,
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="awaiting_ai"),
            launch_runner=lambda plan, **kwargs: session,
        )
        supervisor.session = session
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(
            isolation_certificate._open_record_path(Path(config.staging_root), session_id)
        )
        supervisor.backup_id = "b" * 64
        supervisor.certificate_id = "cert1"
        supervisor._record_started = True
        supervisor._unmeasured_lockout = True
        practice_host.set_host_lockout(config, reason="session_unmeasured", session_id=session_id)

        result = supervisor._finalize_after_run()
        assert result["ok"] is True, result
        assert supervisor.human_retained is False
        assert supervisor.session is None
        assert session.closed == 1
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "closed" and closed["close_problems"] == []
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False
        assert practice_host.read_host_lockout(config)["locked"] is False


def test_supervisor_real_certificate_stuck_ai_retains_open_record():
    """N-1-R: an AI that survives termination must not stamp a closure; ownership
    is retained and the record stays open."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-stuck-ai"
        _real_open_record(config, session_id, live, pids={"human": [7], "ai": [8]})
        session = _StuckAiSession(session_id, "n" * 32)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)

        result = supervisor._finalize_refused_closure("session_closure_unproven")
        assert result["ok"] is False, result
        assert supervisor.session is session
        assert supervisor.human_retained is True
        assert supervisor._pending_closure == "session_closure_unproven"
        assert supervisor._record_started is True
        assert isolation_certificate.list_open_records(Path(config.staging_root))
        still_open = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert still_open["status"] == "open"
        assert not [row for row in _receipts(config) if row.get("session_id") == session_id]
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False


def test_daemon_acknowledge_retries_pending_closure_and_recovers():
    """H-A-1-R: a finished supervisor with a stuck owned handle is retried through
    the public acknowledge op once that handle finally exits."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-pending-ack"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _RecoverableHumanSession(session_id, "n" * 32)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)

        first = supervisor._finalize_refused_closure("session_closure_unproven")
        assert first["ok"] is False
        assert supervisor.session is session
        assert supervisor._pending_closure == "session_closure_unproven"
        assert isolation_certificate.list_open_records(Path(config.staging_root))

        daemon = practice_host.HostDaemon(
            config,
            certificate_api=isolation_certificate,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
        )
        with daemon._lock:
            daemon._ticket = practice_host.MatchTicket(ticket="ticket-pending", request=make_request())
            daemon._ticket.supervisor = supervisor
        try:
            refused = daemon._op_acknowledge({"confirm": True})
            assert refused["ok"] is False, refused
            assert supervisor._pending_closure == "session_closure_unproven"
            assert isolation_certificate.list_open_records(Path(config.staging_root))

            # The stuck owned handle finally exits.
            session.recover = True

            ack = daemon._op_acknowledge({"confirm": True})
            assert ack["ok"] is True and ack["cleared"] is True, ack
            assert supervisor._pending_closure is None
            assert supervisor.session is None
            assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
            closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
            assert closed["status"] == "failed"
            assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False
            assert practice_host.read_host_lockout(config)["locked"] is False
        finally:
            with daemon._lock:
                daemon._ticket = None


def test_daemon_acknowledge_retries_closure_after_persistence_failure():
    """H-A-1-R: a closure that raised once is persisted on the next acknowledge."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-persist-retry"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = FakeSession(roles=("human",))
        session.owned[0].running = False
        session.session_id = session_id
        session.nonce = "n" * 32
        real_failure = isolation_certificate.record_session_failure
        calls = {"n": 0}

        def flaky(staging_root, *, session_id, reason):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("synthetic persistence failure")
            return real_failure(staging_root, session_id=session_id, reason=reason)

        supervisor = _refused_closure_supervisor(config, session_id, session, live)
        with patched(isolation_certificate, record_session_failure=flaky):
            first = supervisor._finalize_refused_closure("session_closure_unproven")
            assert first["ok"] is False
            assert calls["n"] == 1
            assert supervisor._pending_closure == "session_closure_unproven"
            assert supervisor.session is None
            assert supervisor._record_started is True
            assert isolation_certificate.list_open_records(Path(config.staging_root))

            daemon = practice_host.HostDaemon(
                config,
                certificate_api=isolation_certificate,
                opener=_live_opener(config),
                enumerator=FakeEnumerator([]),
            )
            with daemon._lock:
                daemon._ticket = practice_host.MatchTicket(
                    ticket="ticket-persist", request=make_request()
                )
                daemon._ticket.supervisor = supervisor
            try:
                ack = daemon._op_acknowledge({"confirm": True})
                assert ack["ok"] is True and ack["cleared"] is True, ack
                assert calls["n"] == 2
                assert supervisor._pending_closure is None
                assert supervisor._record_started is False
                assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
                closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
                assert closed["status"] == "failed"
                assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is False
            finally:
                with daemon._lock:
                    daemon._ticket = None


def test_daemon_start_retries_pending_closure_before_open_record_check():
    """H-A-1-R: a finished prior supervisor's pending closure is retried (and
    closed) before a new start's open-record check."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-start-retry"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = FakeSession(roles=("human",))
        session.owned[0].running = False
        session.session_id = session_id
        session.nonce = "n" * 32
        real_failure = isolation_certificate.record_session_failure
        calls = {"n": 0}

        def flaky(staging_root, *, session_id, reason):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("synthetic persistence failure")
            return real_failure(staging_root, session_id=session_id, reason=reason)

        supervisor = _refused_closure_supervisor(config, session_id, session, live)
        with patched(isolation_certificate, record_session_failure=flaky):
            first = supervisor._finalize_refused_closure("session_closure_unproven")
            assert first["ok"] is False
            assert calls["n"] == 1
            assert supervisor._pending_closure == "session_closure_unproven"

            daemon = practice_host.HostDaemon(
                config,
                certificate_api=isolation_certificate,
                opener=_live_opener(config),
                enumerator=FakeEnumerator([]),
                runtime_checker=_ok_runtime_checker,
                start_gate=lambda: {"ok": True, "code": practice_host.CODE_OK},
                supervisor_factory=lambda cfg, request: FakeSupervisor(block=threading.Event()),
            )
            daemon.start()
            try:
                with daemon._lock:
                    daemon._ticket = practice_host.MatchTicket(
                        ticket="ticket-pending-start", request=make_request(), phase="failed"
                    )
                    daemon._ticket.supervisor = supervisor

                # The retry completes the closure, but the persistent host lockout
                # still requires an explicit acknowledge (never silently cleared).
                refused = daemon._op_start(make_request())
                assert refused["code"] == practice_host.CODE_ACK_REQUIRED, refused
                assert calls["n"] == 2
                assert supervisor._pending_closure is None
                assert supervisor._record_started is False
                assert isolation_certificate.list_open_records(Path(config.staging_root)) == []

                ack = daemon._op_acknowledge({"confirm": True})
                assert ack["ok"] is True and ack["cleared"] is True, ack
                assert practice_host.read_host_lockout(config)["locked"] is False

                response = daemon._op_start(make_request())
                assert response["ok"] is True, response
                assert response["code"] == practice_host.CODE_ACCEPTED, response
            finally:
                daemon.stop(force=True)


def test_daemon_stop_refuses_while_closure_pending():
    """H-A-1-R: a non-forced stop must never reach cleanup while a closure is
    still pending (the retained handles are the only proof of exit)."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-stop-pending"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _RecoverableHumanSession(session_id, "n" * 32)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)
        first = supervisor._finalize_refused_closure("session_closure_unproven")
        assert first["ok"] is False
        assert supervisor.session is session

        daemon = practice_host.HostDaemon(
            config,
            certificate_api=isolation_certificate,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
        )
        with daemon._lock:
            daemon._ticket = practice_host.MatchTicket(ticket="ticket-stop", request=make_request())
            daemon._ticket.supervisor = supervisor
        try:
            stopped = daemon.stop()
            assert stopped["stopped"] is False, stopped
            assert stopped["code"] == practice_host.CODE_CLOSURE_PENDING, stopped
            assert supervisor.session is session
        finally:
            with daemon._lock:
                daemon._ticket = None


def test_daemon_retry_pending_closure_only_for_finished_threads():
    """H-A-1-R: a running supervisor thread owns its closure and is never retried."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        daemon = practice_host.HostDaemon(
            config, opener=_live_opener(config), enumerator=FakeEnumerator([])
        )
        recording = _RetryRecordingSupervisor()
        event = threading.Event()
        live_thread = threading.Thread(target=event.wait, args=(5.0,), daemon=True)
        live_thread.start()
        try:
            with daemon._lock:
                daemon._ticket = practice_host.MatchTicket(
                    ticket="ticket-thread", request=make_request(), supervisor=recording, thread=live_thread
                )
            assert daemon._retry_pending_closure() is True
            assert recording.calls == 0

            with daemon._lock:
                daemon._ticket.thread = None
            assert daemon._retry_pending_closure() is True
            assert recording.calls == 1
        finally:
            event.set()


def test_supervisor_real_certificate_live_byte_diff_closes_failed_record_and_stop():
    """H-A-1-R2: a real measured live byte diff closes the record as failed with the
    byte-diff lockout and leaves no pending closure, so the daemon can actually stop
    even though the certificate already closed the record (no second verdict)."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-real-diff"
        _real_open_record(config, session_id, live, pids={"human": [7], "ai": [8]})
        # A real byte change in the live install after the before-snapshot.
        (Path(config.live_install_root) / "revoked.bin").write_bytes(b"live byte change")
        session = FakeSession(roles=("human", "ai"))
        session.session_id = session_id
        session.nonce = "n" * 32
        for role in session.owned:
            role.running = False
        supervisor = _supervisor(
            config,
            make_request(),
            certificate_api=isolation_certificate,
            verdict_recorder=None,
            service_factory=lambda cfg: FakeService(cfg, ended=True, terminal_phase="awaiting_ai"),
            launch_runner=lambda plan, **kwargs: session,
        )
        supervisor.session = session
        supervisor.session_id = session_id
        supervisor._gates = {"live_map": live}
        supervisor.open_record = str(
            isolation_certificate._open_record_path(Path(config.staging_root), session_id)
        )
        supervisor.backup_id = "b" * 64
        supervisor.certificate_id = "cert1"
        supervisor._record_started = True
        supervisor._unmeasured_lockout = True
        practice_host.set_host_lockout(config, reason="session_unmeasured", session_id=session_id)

        result = supervisor._finalize_after_run()
        assert result["ok"] is False, result
        assert result["code"] == practice_host.CODE_LIVE_CHANGED, result
        assert supervisor.live_verdict["code"] == "live_byte_diff_revoked"
        # The certificate already persisted the failure; nothing else is pending.
        assert supervisor._pending_closure is None
        assert supervisor._record_started is False
        assert supervisor.session is None
        assert supervisor.human_retained is False
        assert isolation_certificate.list_open_records(Path(config.staging_root)) == []
        closed = isolation_certificate.load_open_record(Path(config.staging_root), session_id)
        assert closed["status"] == "failed"
        assert isolation_certificate.lockout(Path(config.staging_root))["locked"] is True
        receipts = [row for row in _receipts(config) if row.get("session_id") == session_id]
        assert receipts and receipts[-1]["verdict"] == "revoked"

        # The public stop must actually shut the daemon down (no stuck pending state).
        daemon = practice_host.HostDaemon(
            config,
            certificate_api=isolation_certificate,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
        )
        with daemon._lock:
            daemon._ticket = practice_host.MatchTicket(ticket="ticket-diff", request=make_request())
            daemon._ticket.supervisor = supervisor
        stopped = daemon.stop()
        assert stopped["stopped"] is True, stopped


def test_daemon_refuses_acknowledge_and_start_while_retry_cannot_close():
    """H-A-1-R (Low): a retry that still cannot retire/persist must refuse the public
    acknowledge and start without discarding the kept owned handles or the record."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-retry-refuse"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = _FailedCloseSession(session_id, "n" * 32)
        supervisor = _refused_closure_supervisor(config, session_id, session, live)
        first = supervisor._finalize_refused_closure("session_closure_unproven")
        assert first["ok"] is False
        assert supervisor._pending_closure == "session_closure_unproven"
        assert supervisor.session is session

        daemon = practice_host.HostDaemon(
            config,
            certificate_api=isolation_certificate,
            opener=_live_opener(config),
            enumerator=FakeEnumerator([]),
        )
        with daemon._lock:
            daemon._ticket = practice_host.MatchTicket(ticket="ticket-refuse", request=make_request())
            daemon._ticket.supervisor = supervisor
        try:
            ack = daemon._op_acknowledge({"confirm": True})
            assert ack["ok"] is False and ack["code"] == practice_host.CODE_CLOSURE_PENDING, ack
            assert supervisor.session is session
            assert supervisor._pending_closure == "session_closure_unproven"
            assert isolation_certificate.list_open_records(Path(config.staging_root))

            start = daemon._op_start(make_request())
            assert start["ok"] is False and start["code"] == practice_host.CODE_CLOSURE_PENDING, start
            assert supervisor.session is session
            assert supervisor._pending_closure == "session_closure_unproven"
            assert isolation_certificate.list_open_records(Path(config.staging_root))
        finally:
            with daemon._lock:
                daemon._ticket = None


def test_concurrent_pending_closure_retry_persists_once():
    """H-A-1-R (Low): concurrent retries are serialized, so the failure closure is
    persisted exactly once and never appends duplicate receipts."""
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(tmp)
        live = _synthetic_livepair(config)
        session_id = "s-concurrent-retry"
        _real_open_record(config, session_id, live, pids={"human": [7]})
        session = FakeSession(roles=("human",))
        session.owned[0].running = False
        session.session_id = session_id
        session.nonce = "n" * 32
        supervisor = _refused_closure_supervisor(config, session_id, session, live)
        supervisor._pending_closure = "session_closure_unproven"

        real_failure = isolation_certificate.record_session_failure
        calls = {"n": 0}

        def slow_failure(staging_root, *, session_id, reason):
            calls["n"] += 1
            time.sleep(0.05)
            return real_failure(staging_root, session_id=session_id, reason=reason)

        results = []

        def worker():
            results.append(supervisor.retry_pending_closure())

        with patched(isolation_certificate, record_session_failure=slow_failure):
            threads = [threading.Thread(target=worker) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(5.0)

        assert sorted(results) == [True, True], results
        assert calls["n"] == 1
        assert supervisor._pending_closure is None
        assert supervisor._record_started is False
        receipts = [row for row in _receipts(config) if row.get("session_id") == session_id]
        assert len(receipts) == 1 and receipts[0]["verdict"] == "failed"


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
