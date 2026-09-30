#!/usr/bin/env python3
"""Practice control/policy service tests.

Runs the real ``tools/practice_service.py`` against synthetic, in-process
harnesses and, for the legal-decision proof, the real repository baseline source
provider plus the real ``tools/policy_worker.py`` subprocess under lupa's
LuaJIT 2.1 runtime. A single loopback socket test proves framing/rate limits on
``127.0.0.1``. No game, Mods directory, live path, save or external network is
touched and no Balatro process is started.
"""
from __future__ import annotations

import argparse
import importlib
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import practice_service  # noqa: E402

ps = practice_service

CONTENT = "digest-abc"
HUMAN_CRED = "h" * 64
AI_CRED = "a" * 64
# Trusted host-derived expected Major League configuration digest (FNV1a32 hex).
CONFIG_DIGEST = "0a1b2c3d"
OTHER_DIGEST = "ffeeddcc"


class FakeSourceProvider:
    def __init__(self, source="return function(observation, actions) return actions[1] end"):
        self.source_text = source
        self.calls = []

    def source(self, difficulty):
        self.calls.append(difficulty)
        return self.source_text


class FakeProcess:
    def __init__(self):
        self.killed = False

    def kill(self):
        self.killed = True

    def communicate(self, *args, **kwargs):
        return (b"", b"")


class FakeRunner:
    def __init__(self, response=None, delay=0.0):
        self.response = response if response is not None else {
            "ok": True,
            "code": "policy_ok",
            "action": {"type": "PLAY_CARDS", "card_refs": ["hand:1"]},
        }
        self.delay = delay
        self.requests = []

    def __call__(self, request, timeout, register):
        self.requests.append(request)
        if self.delay:
            time.sleep(self.delay)
        return dict(self.response)


class BlockingRunner:
    def __init__(self, response, register_process=False):
        self.response = response
        self.register_process = register_process
        self.started = threading.Event()
        self.release = threading.Event()
        self.proc = None

    def __call__(self, request, timeout, register):
        if self.register_process:
            self.proc = FakeProcess()
            register(self.proc)
        self.started.set()
        self.release.wait(5)
        return dict(self.response)


class FakeClock:
    """Injectable monotonic clock for the bounded pre-start window tests."""

    def __init__(self, start=0.0):
        self.t = float(start)

    def __call__(self):
        return self.t

    def set(self, value):
        self.t = float(value)
        return self.t


def make_config(tmp, **overrides):
    values = dict(
        session_id="sess-1",
        difficulty="competitive",
        pacing="instant",
        mode="normal",
        match_port=8788,
        log_root=Path(tmp) / "logs",
        content_hash=CONTENT,
        expected_config_digest=CONFIG_DIGEST,
        gauntlet=None,
    )
    values.update(overrides)
    return ps.ServiceConfig(**values)


def make_service(tmp, **overrides):
    config_overrides = overrides.pop("config_overrides", {})
    kwargs = dict(
        human_credential=HUMAN_CRED,
        ai_credential=AI_CRED,
        source_provider=FakeSourceProvider(),
        worker_runner=FakeRunner(),
    )
    kwargs.update(overrides)
    return ps.PracticeService(make_config(tmp, **config_overrides), **kwargs)


def make_service_with_config(config, **overrides):
    kwargs = dict(
        human_credential=HUMAN_CRED,
        ai_credential=AI_CRED,
        source_provider=FakeSourceProvider(),
        worker_runner=FakeRunner(),
    )
    kwargs.update(overrides)
    return ps.PracticeService(config, **kwargs)


def credentials(service):
    return {"human": service.human_credential, "ai": service.ai_credential}


def envelope(service, role, op, sequence, observation, credential=None, session=None):
    creds = credentials(service)
    return {
        "session": service.session_id if session is None else session,
        "credential": creds[role] if credential is None else credential,
        "role": role,
        "op": op,
        "sequence": sequence,
        "observation": observation,
    }


class Session:
    """Per-role sequence bookkeeping for a coordinated session."""

    def __init__(self, service):
        self.service = service
        self.sequence = {"human": -1, "ai": -1}

    def next(self, role):
        self.sequence[role] += 1
        return self.sequence[role]

    def send(self, role, op, observation=None, sequence=None):
        seq = self.next(role) if sequence is None else sequence
        return self.service.handle_request(envelope(self.service, role, op, seq, observation))

    def hello(self, role, content=CONTENT, version="1"):
        return self.send(role, "hello", {"version": version, "content_digest": content})

    def ready(self, role, digest=CONFIG_DIGEST):
        return self.send(role, "ready", {"config_digest": digest})

    def start(self, role="human"):
        return self.send(role, "start", {})

    def handshake(self, config_digest=CONFIG_DIGEST, seed=None):
        # The trusted host attests the session through the Python port before the
        # runtime handshake; the fixture marks the actual certificate verified,
        # not a real probe proof.
        assert self.service.mark_attested(config_digest) is True
        assert self.hello("human")["ok"], self.hello("human")
        assert self.hello("ai")["ok"]
        assert self.ready("human", config_digest)["ok"]
        assert self.ready("ai", config_digest)["ok"]
        assert self.start("human")["ok"]
        # The real human runtime reports the *resolved* run seed only after
        # ``start`` (once the run is initialized), so the fixture follows the real
        # producer order rather than fabricating pre-start seed knowledge (M-6).
        if seed is not None:
            assert self.send("human", "status", {"seed": seed})["ok"]


def _valid_export():
    return {
        "schema_version": 1,
        "phase": "PLAY_HAND",
        "match": {
            "ruleset": "majorleague",
            "blind": "Small Blind",
            "timer": "120",
            "ante": 1,
            "round": 1,
            "lives": 4,
            "hands_per_round": 4,
            "discards_per_round": 3,
            "hand_size": 8,
            "joker_slots": 5,
            "consumable_slots": 2,
        },
        "self": {
            "money": 10,
            "credit_limit": 0,
            "hands": 4,
            "discards": 3,
            "current_score": "0",
            "blind_requirement": "300",
            "hand_visible": True,
            "hand": [
                {"id": "hand:1", "face_down": False, "kind": "card", "rank": "Ace", "suit": "Spades", "center": "c_ace"},
                {"id": "hand:2", "face_down": False, "kind": "card", "rank": "King", "suit": "Hearts", "center": "c_king"},
            ],
            "jokers": [],
            "consumables": [],
            "vouchers": [],
            "tags": [],
            "deck": {"total": 52},
        },
        "context": {
            "blocked": False,
            "timer_expired": False,
            "target_selection": False,
            "max_play": 5,
            "max_discard": 5,
        },
        "certificates": {
            "version": 1,
            "items": [
                {"type": "PLAY_CARDS", "certified": True, "card_refs": ["hand:1"]},
                {"type": "PLAY_CARDS", "certified": True, "card_refs": ["hand:1", "hand:2"]},
            ],
        },
    }


def wait_for_decision(session, sequence, timeout=20.0):
    deadline = time.time() + timeout
    response = None
    while time.time() < deadline:
        response = session.send("ai", "decide_poll", {}, sequence=sequence)
        if response.get("code") != ps.CODE_DECISION_PENDING:
            return response
        time.sleep(0.02)
    return response


def read_jsonl(path, predicate=None, timeout=5.0):
    deadline = time.time() + timeout
    rows = []
    while True:
        try:
            lines = Path(path).read_text(encoding="utf-8").splitlines()
        except Exception:  # noqa: BLE001
            lines = []
        rows = [json.loads(line) for line in lines if line]
        if predicate is None or any(predicate(row) for row in rows) or time.time() >= deadline:
            return rows
        time.sleep(0.02)


# -- configuration and construction -----------------------------------------


def test_config_validation_and_gauntlet_seeds():
    with tempfile.TemporaryDirectory() as tmp:
        gauntlet = make_config(tmp, mode="gauntlet", gauntlet="Test3")
        assert gauntlet.gauntlet_seed == "AISP0003"
        service = make_service_with_config(gauntlet)
        assert service.gauntlet_seed == "AISP0003"
    for bad in (dict(mode="gauntlet"), dict(mode="normal", gauntlet="Test1"), dict(difficulty="easy")):
        try:
            with tempfile.TemporaryDirectory() as tmp:
                make_config(tmp, **bad)
        except ps.PracticeError as error:
            assert error.code == ps.CODE_BAD_REQUEST
        else:
            raise AssertionError(f"expected bad config for {bad}")
    assert ps.GAUNTLET_SEEDS == {
        "Test1": "AISP0001",
        "Test2": "AISP0002",
        "Test3": "AISP0003",
        "Test4": "AISP0004",
        "Test5": "AISP0005",
    }


def test_expected_config_digest_is_required():
    with tempfile.TemporaryDirectory() as tmp:
        values = dict(
            session_id="sess-1",
            difficulty="competitive",
            pacing="instant",
            mode="normal",
            match_port=8788,
            log_root=Path(tmp) / "logs",
            content_hash=CONTENT,
        )
        try:
            ps.ServiceConfig(**values)
        except TypeError:
            pass
        else:
            raise AssertionError("expected_config_digest must be a required constructor argument")
        for bad in ("", "bad digest space", "x" * 100):
            try:
                ps.ServiceConfig(expected_config_digest=bad, **values)
            except ps.PracticeError as error:
                assert error.code == ps.CODE_BAD_REQUEST
            else:
                raise AssertionError(f"expected bad expected_config_digest for {bad!r}")


def test_credentials_random_and_distinct():
    with tempfile.TemporaryDirectory() as tmp:
        first = ps.PracticeService(make_config(tmp), source_provider=FakeSourceProvider(), worker_runner=FakeRunner())
        second = ps.PracticeService(make_config(tmp), source_provider=FakeSourceProvider(), worker_runner=FakeRunner())
        assert first.human_credential != first.ai_credential
        assert first.human_credential != second.human_credential
        assert first.ai_credential != second.ai_credential
        try:
            make_service(tmp, human_credential="same", ai_credential="same")
        except ps.PracticeError as error:
            assert error.code == ps.CODE_BAD_REQUEST
        else:
            raise AssertionError("equal credentials must be rejected")


def test_non_loopback_host_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            make_service(tmp, host="0.0.0.0")
        except ps.PracticeError as error:
            assert error.code == ps.CODE_BAD_REQUEST
        else:
            raise AssertionError("non-loopback bind must be rejected")


# -- envelope and authentication --------------------------------------------


def test_envelope_shape_strict():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        base = envelope(service, "human", "status", 0, {})
        assert service.handle_request(base)["ok"]
        for mutate, code in (
            (lambda m: m.pop("observation"), ps.CODE_BAD_SHAPE),
            (lambda m: m.update({"extra": 1}), ps.CODE_BAD_SHAPE),
        ):
            message = envelope(service, "human", "status", 1, {})
            mutate(message)
            assert service.handle_request(message)["code"] == code
        assert service.handle_request("not-a-dict")["code"] == ps.CODE_BAD_REQUEST
        message = envelope(service, "human", "status", 2, {})
        message["sequence"] = True
        assert service.handle_request(message)["code"] == ps.CODE_BAD_SEQUENCE
        message = envelope(service, "human", "status", 3, {})
        message["sequence"] = -1
        assert service.handle_request(message)["code"] == ps.CODE_BAD_SEQUENCE


def test_auth_session_credential_role():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        assert service.handle_request(envelope(service, "human", "status", 0, {}, session="other"))["code"] == ps.CODE_BAD_SESSION
        assert service.handle_request(envelope(service, "human", "status", 0, {}, credential="wrong"))["code"] == ps.CODE_BAD_CREDENTIAL
        message = envelope(service, "human", "status", 0, {})
        message["role"] = "spectator"
        assert service.handle_request(message)["code"] == ps.CODE_BAD_ROLE
        message = envelope(service, "human", "status", 0, {})
        message["op"] = "bogus"
        assert service.handle_request(message)["code"] == ps.CODE_BAD_OP
        # A human credential presented as the ai role must fail.
        assert service.handle_request(envelope(service, "ai", "status", 0, {}, credential=HUMAN_CRED))["code"] == ps.CODE_BAD_CREDENTIAL


def test_role_restrictions_for_ops_and_decisions():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        # human cannot issue decisions
        assert session.send("human", "decide_begin", _valid_export())["code"] == ps.CODE_BAD_ROLE
        # ai cannot set the human lobby code; human cannot read the join code
        assert session.send("ai", "lobby_code", {"lobby_code": "ABC"})["code"] == ps.CODE_BAD_ROLE
        assert session.send("human", "join_code", {})["code"] == ps.CODE_BAD_ROLE


def test_sequence_replay_and_order():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        assert session.send("human", "status", {}, sequence=0)["ok"]
        assert session.send("human", "status", {}, sequence=0)["code"] == ps.CODE_REPLAY
        assert session.send("human", "status", {}, sequence=-1)["code"] == ps.CODE_BAD_SEQUENCE
        assert session.send("human", "status", {}, sequence=5)["ok"]
        assert session.send("human", "status", {}, sequence=4)["code"] == ps.CODE_REPLAY
        # The ai counter is independent.
        assert session.send("ai", "status", {}, sequence=0)["ok"]


# -- limits -----------------------------------------------------------------


def test_rate_limiter_and_connection_slots():
    limiter = ps.RateLimiter(2, 10.0)
    assert limiter.allow(now=0.0)
    assert limiter.allow(now=0.1)
    assert not limiter.allow(now=0.2)
    assert limiter.allow(now=11.0)
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, max_connections=2)
        assert service.acquire_connection()
        assert service.acquire_connection()
        assert not service.acquire_connection()
        service.release_connection()
        assert service.acquire_connection()
        service.release_connection()
        service.release_connection()


def test_request_and_observation_size_bounds():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        oversized = b"{" + b"x" * (ps.MAX_REQUEST_BYTES + 10)
        assert service.handle_line(oversized)["code"] == ps.CODE_INPUT_TOO_LARGE
        assert service.handle_line(b"not json\n")["code"] == ps.CODE_BAD_LINE
        # Non-dict observation payload.
        assert session.send("ai", "decide_begin", [1, 2, 3])["code"] == ps.CODE_BAD_OBSERVATION
        # Too deep.
        deep = current = {}
        for _ in range(ps.MAX_OBSERVATION_DEPTH + 2):
            current["n"] = {}
            current = current["n"]
        assert session.send("ai", "decide_begin", deep)["code"] == ps.CODE_BAD_OBSERVATION
        # Too many bytes.
        big = {"phase": "PLAY_HAND", "blob": "y" * (ps.MAX_OBSERVATION_BYTES + 10)}
        assert session.send("ai", "decide_begin", big)["code"] == ps.CODE_BAD_OBSERVATION


# -- decisions ---------------------------------------------------------------


def test_decide_begin_poll_ready_and_single_slot():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = BlockingRunner({"ok": True, "code": "policy_ok", "action": {"type": "PLAY_CARDS", "card_refs": ["hand:1"]}})
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        begin = session.send("ai", "decide_begin", _valid_export())
        assert begin["code"] == ps.CODE_DECISION_PENDING, begin
        sequence = begin["sequence"]
        assert runner.started.wait(5)
        outstanding = session.send("ai", "decide_begin", _valid_export())
        assert outstanding["code"] == ps.CODE_DECISION_OUTSTANDING
        assert session.send("ai", "decide_poll", {}, sequence=sequence)["code"] == ps.CODE_DECISION_PENDING
        runner.release.set()
        response = wait_for_decision(session, sequence)
        assert response["code"] == ps.CODE_DECISION_READY, response
        assert response["action"]["type"] == "PLAY_CARDS"
        # The slot is consumed; another begin is allowed.
        runner.release.set()
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_DECISION_PENDING


def test_poll_of_unknown_sequence_is_not_a_reset():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        response = session.send("ai", "decide_poll", {}, sequence=99)
        assert response["code"] == ps.CODE_DECISION_UNKNOWN
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_DECISION_PENDING


def test_decide_requires_start():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        session.hello("human")
        session.hello("ai")
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_NOT_STARTED


def test_hidden_request_capture():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner()
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake(seed="AISP0003")
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        response = wait_for_decision(session, sequence)
        assert response["code"] == ps.CODE_DECISION_READY
        assert len(runner.requests) == 1
        request = runner.requests[0]
        assert set(request.keys()) == {"runtime", "source", "observation"}
        assert request["runtime"] == "luajit21"
        blob = json.dumps(request)
        for forbidden in (HUMAN_CRED, AI_CRED, service.session_id, "AISP0003", "config_digest", "credential"):
            assert forbidden not in blob
        assert "seed" not in request["observation"]


def test_worker_timeout_real_runner_terminates_child():
    class TimeoutPopen:
        def __init__(self):
            self.killed = False

        def communicate(self, *args, **kwargs):
            if not self.killed:
                raise subprocess.TimeoutExpired(cmd="worker", timeout=kwargs.get("timeout", 1))
            return (b"", b"")

        def kill(self):
            self.killed = True

    proc = TimeoutPopen()
    registered = []
    response = ps.run_policy_worker(
        {"runtime": "luajit21", "source": "return function() end", "observation": {}},
        0.1,
        registered.append,
        popen=lambda *a, **k: proc,
    )
    assert response == {"ok": False, "code": ps.CODE_DECISION_TIMEOUT}
    assert proc.killed is True
    assert registered == [proc]


def test_worker_failure_propagates_to_both_roles():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner({"ok": False, "code": "policy_bad_source"})
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        response = wait_for_decision(session, sequence)
        assert response["code"] == "policy_bad_source"
        status = session.send("human", "status", {})
        assert status["error"] == "policy_bad_source"
        assert status["failures"] >= 1


def test_policy_no_action_is_counted_apart_from_failures():
    # NATIVE_TEST_PROGRESS match 10: 33 PvP-wait `policy_no_action` answers were
    # summarized as errors. They are a legitimate policy outcome.
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner({"ok": False, "code": "policy_no_action"})
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake(seed="AISP0001")
        for _ in range(3):
            sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
            response = wait_for_decision(session, sequence)
            assert response["code"] == "policy_no_action"
        status = session.send("human", "status", {})
        assert status["failures"] == 0, status
        assert status["error"] is None, status
        described = service.terminal_summary()
        assert described["errors"] == 0 and described["no_action"] == 3, described
        decisions_path = Path(tmp) / "logs" / "decisions.jsonl"
        rows = read_jsonl(decisions_path, lambda row: row.get("reason") == "policy_no_action")
        assert len(rows) == 3 and all(row["errors"] is None for row in rows), rows
        end = session.send("human", "end", {"result": "human_win", "errors": 0})
        assert end["ok"], end
        session.send("ai", "end", {"result": "human_win"})
        summary_path = Path(tmp) / "logs" / "summary.jsonl"
        summaries = read_jsonl(summary_path, lambda row: row.get("result") == "human_win")
        assert summaries[-1]["errors"] == 0 and summaries[-1]["no_action"] == 3, summaries[-1]


def test_real_policy_failures_still_count_with_no_action():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner({"ok": False, "code": "policy_no_action"})
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        wait_for_decision(session, sequence)
        runner.response = {"ok": False, "code": "policy_bad_source"}
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        wait_for_decision(session, sequence)
        status = session.send("human", "status", {})
        assert status["failures"] == 1 and status["error"] == "policy_bad_source", status


def test_cancel_decision_terminates_exact_child():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = BlockingRunner(
            {"ok": True, "code": "policy_ok", "action": {"type": "PLAY_CARDS"}},
            register_process=True,
        )
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        begin = session.send("ai", "decide_begin", _valid_export())
        sequence = begin["sequence"]
        assert runner.started.wait(5)
        assert runner.proc is not None
        assert service.cancel_decision() is True
        assert runner.proc.killed is True
        runner.release.set()
        assert session.send("ai", "decide_poll", {}, sequence=sequence)["code"] == ps.CODE_DECISION_UNKNOWN
        runner.release.set()
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_DECISION_PENDING


def test_wire_decide_cancel_owned_job_then_new_decision_ready():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = BlockingRunner(
            {"ok": True, "code": "policy_ok", "action": {"type": "PLAY_CARDS"}},
            register_process=True,
        )
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        begin = session.send("ai", "decide_begin", _valid_export())
        sequence = begin["sequence"]
        assert runner.started.wait(5)
        assert runner.proc is not None
        cancel = session.send("ai", "decide_cancel", {"decision_sequence": sequence})
        assert cancel["ok"] is True and cancel["code"] == ps.CODE_DECISION_CANCELLED, cancel
        assert runner.proc.killed is True
        # The slot is cleared: the cancelled sequence is unknown and a duplicate
        # cancel is a bounded, non-fatal code.
        assert session.send("ai", "decide_poll", {}, sequence=sequence)["code"] == ps.CODE_DECISION_UNKNOWN
        duplicate = session.send("ai", "decide_cancel", {"decision_sequence": sequence})
        assert duplicate["ok"] is False and duplicate["code"] == ps.CODE_DECISION_UNKNOWN, duplicate
        # A fresh decision is accepted and reaches a worker-validated action.
        runner.release.set()
        second = session.send("ai", "decide_begin", _valid_export())
        assert second["code"] == ps.CODE_DECISION_PENDING, second
        response = wait_for_decision(session, second["sequence"])
        assert response["code"] == ps.CODE_DECISION_READY, response
        assert response["action"]["type"] == "PLAY_CARDS"


def test_wire_decide_cancel_wrong_sequence_leaves_other_job():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = BlockingRunner(
            {"ok": True, "code": "policy_ok", "action": {"type": "PLAY_CARDS"}},
            register_process=True,
        )
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        begin = session.send("ai", "decide_begin", _valid_export())
        sequence = begin["sequence"]
        assert runner.started.wait(5)
        wrong = session.send("ai", "decide_cancel", {"decision_sequence": sequence + 7})
        assert wrong["ok"] is False and wrong["code"] == ps.CODE_DECISION_UNKNOWN, wrong
        # The owned job is untouched, still pending and completes normally.
        assert session.send("ai", "decide_poll", {}, sequence=sequence)["code"] == ps.CODE_DECISION_PENDING
        assert runner.proc is None or runner.proc.killed is False
        runner.release.set()
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY


def test_wire_decide_cancel_role_payload_and_replay():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        # AI-only, like the other decision ops: the human role is rejected.
        assert session.send("human", "decide_cancel", {"decision_sequence": 0})["code"] == ps.CODE_BAD_ROLE
        # Exact payload only.
        assert session.send("ai", "decide_cancel", {})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("ai", "decide_cancel", [1])["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("ai", "decide_cancel", {"decision_sequence": "0"})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("ai", "decide_cancel", {"decision_sequence": True})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("ai", "decide_cancel", {"decision_sequence": 0, "extra": 1})["code"] == ps.CODE_BAD_PAYLOAD
        # No job matches: bounded and non-fatal.
        unknown = session.send("ai", "decide_cancel", {"decision_sequence": 0})
        assert unknown["code"] == ps.CODE_DECISION_UNKNOWN, unknown
        # The cancel op consumes a fresh monotonic envelope sequence, so a
        # replayed envelope sequence is rejected before any cancellation.
        assert session.send("ai", "decide_cancel", {"decision_sequence": 0}, sequence=50)["code"] == ps.CODE_DECISION_UNKNOWN
        assert session.send("ai", "decide_cancel", {"decision_sequence": 0}, sequence=50)["code"] == ps.CODE_REPLAY


def test_close_cancels_pending_and_fails_closed():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = BlockingRunner(
            {"ok": True, "code": "policy_ok", "action": {"type": "PLAY_CARDS"}},
            register_process=True,
        )
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        session.send("ai", "decide_begin", _valid_export())
        assert runner.started.wait(5)
        runner.release.set()
        service.close()
        assert runner.proc.killed is True
        assert service.handle_request(envelope(service, "human", "status", 10, {}))["code"] == ps.CODE_SERVICE_CLOSED


# -- coordination ------------------------------------------------------------


def test_coordination_lobby_join_ready_start_and_freeze():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        assert session.hello("human")["ok"]
        assert session.hello("ai")["ok"]
        assert session.send("human", "lobby_code", {"lobby_code": "PRAC-1"})["ok"]
        join = session.send("ai", "join_code", {})
        assert join["ok"] and join["lobby_code"] == "PRAC-1"
        assert session.send("human", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        # A digest that is not the trusted host-derived expectation is rejected
        # at once, not only when the two roles happen to disagree.
        assert session.send("ai", "ready", {"config_digest": OTHER_DIGEST})["code"] == ps.CODE_CONFIG_MISMATCH
        assert session.start("human")["code"] == ps.CODE_NOT_READY
        assert session.send("ai", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        assert session.start("human")["ok"]
        # frozen after start
        assert session.hello("human")["code"] == ps.CODE_FROZEN
        assert session.send("human", "lobby_code", {"lobby_code": "OTHER"})["code"] == ps.CODE_FROZEN
        assert session.send("ai", "join_code", {})["code"] == ps.CODE_FROZEN
        assert session.send("ai", "ready", {"config_digest": CONFIG_DIGEST})["code"] == ps.CODE_FROZEN
        # start is one-time
        assert session.start("human")["code"] == ps.CODE_ALREADY_STARTED
        # status still allowed
        assert session.send("human", "status", {})["ok"]


def test_coordination_requires_content_and_lobby():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        assert session.hello("human", content="wrong-digest")["code"] == ps.CODE_CONTENT_MISMATCH
        assert session.hello("ai")["ok"]
        assert session.send("human", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        assert session.send("ai", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        assert session.start("human")["code"] == ps.CODE_NOT_READY
        assert session.send("ai", "join_code", {})["code"] == ps.CODE_NO_LOBBY


def test_start_requires_both_hellos_before_start():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        session.hello("human")
        session.hello("ai")
        session.ready("human")
        session.ready("ai")
        assert session.start("human")["ok"]
        assert session.start("human")["code"] == ps.CODE_ALREADY_STARTED


# -- attestation and terminal lifecycle -------------------------------------


def test_attestation_gate_blocks_until_trusted_mark():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        # Unattested: every configuration/decision op is refused, but the host
        # can still observe and report.
        assert session.send("human", "hello", {"version": "1", "content_digest": CONTENT})["code"] == ps.CODE_NOT_ATTESTED
        assert session.send("human", "setup", {})["code"] == ps.CODE_NOT_ATTESTED
        assert session.send("human", "ready", {"config_digest": CONFIG_DIGEST})["code"] == ps.CODE_NOT_ATTESTED
        assert session.send("human", "start", {})["code"] == ps.CODE_NOT_ATTESTED
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_NOT_ATTESTED
        assert session.send("human", "error", {"error": "ai_runtime_failed"})["ok"]
        status = session.send("human", "status", {})
        assert status["ok"] and status["attested"] is False
        # A mismatched attestation digest is refused; only the trusted port can
        # attest, and mark_attested is never a wire op.
        try:
            service.mark_attested(OTHER_DIGEST)
        except ps.PracticeError as error:
            assert error.code == ps.CODE_BAD_REQUEST
        else:
            raise AssertionError("mismatched attestation digest must be rejected")
        assert service.mark_attested(CONFIG_DIGEST) is True
        assert service.attested is True
        assert session.hello("human")["ok"]
        assert "mark_attested" not in ps.OPS
        assert {"hello", "setup", "ready", "start", "decide_begin"}.issubset(ps.ATTESTED_OPS)
        assert {"status", "end", "error", "heartbeat"}.isdisjoint(ps.ATTESTED_OPS)


def test_ready_pinned_to_host_expected_digest():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        assert session.hello("human")["ok"]
        assert session.hello("ai")["ok"]
        assert session.send("human", "ready", {"config_digest": OTHER_DIGEST})["code"] == ps.CODE_CONFIG_MISMATCH
        assert session.send("human", "ready", {"config_digest": "not a digest!"})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("human", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        assert session.send("ai", "ready", {"config_digest": CONFIG_DIGEST})["ok"]
        assert session.start("human")["ok"]


def test_prestart_deadline_after_attestation():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, prestart_timeout=0.2, role_timeout=0.0, watchdog_interval=0.02)
        service.mark_attested(CONFIG_DIGEST)
        service.start()
        try:
            session = Session(service)
            status = None
            deadline = time.time() + 3.0
            while time.time() < deadline:
                time.sleep(0.05)
                status = session.send("human", "status", {})
                if status.get("aborted"):
                    break
            assert status is not None and status.get("aborted") is True, status
            assert status.get("error") == ps.CODE_PRESTART_TIMEOUT
            # H-C: the real service exposes the abnormal end to the host under its lock.
            assert service.aborted is True
            assert service.terminal_reason == ps.CODE_PRESTART_TIMEOUT
            assert service.terminal_phase == ps.TERMINAL_CLOSED
        finally:
            service.stop()


def test_prestart_window_measured_from_publication():
    """The pre-start budget starts when the attestation files are published.

    Both roles' probes can finish well before the (slow) attestation writer
    publishes the files the companions poll, so measuring from ``mark_attested``
    would spend the budget before either role can act.
    """
    with tempfile.TemporaryDirectory() as tmp:
        clock = FakeClock(1000.0)
        service = make_service(tmp, prestart_timeout=90.0, role_timeout=0.0, watchdog_interval=0.02, clock=clock)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)  # attested at t0
        service.start()
        try:
            clock.set(1055.0)  # published 55 s later
            assert service.start_prestart_window() is True
            # t0 + 100 is past attested_at + 90, but only publication + 45.
            clock.set(1100.0)
            time.sleep(0.1)
            status = session.send("human", "status", {})
            assert status.get("aborted") is not True, status
            # Still inside the window one second before publication + 90.
            clock.set(1144.0)
            time.sleep(0.1)
            assert session.send("human", "status", {}).get("aborted") is not True
            # Expires only after publication + 90.
            clock.set(1146.0)
            deadline = time.time() + 3.0
            status = None
            while time.time() < deadline:
                time.sleep(0.05)
                status = session.send("human", "status", {})
                if status.get("aborted"):
                    break
            assert status is not None and status.get("aborted") is True, status
            assert status.get("error") == ps.CODE_PRESTART_TIMEOUT
        finally:
            service.stop()


def test_prestart_window_is_noop_before_attestation_and_after_start_or_abort():
    with tempfile.TemporaryDirectory() as tmp:
        clock = FakeClock(500.0)
        service = make_service(tmp, prestart_timeout=90.0, role_timeout=0.0, watchdog_interval=0.02, clock=clock)
        session = Session(service)
        # Before the trusted attestation the window cannot be started; a failed
        # call leaves the earlier (attested_at) clock as the only bound.
        assert service.start_prestart_window() is False
        assert service.start_prestart_window() is False
        service.mark_attested(CONFIG_DIGEST)
        assert service.start_prestart_window() is True
        session.handshake()
        assert service.started is True
        assert service.start_prestart_window() is False

        aborted = make_service(
            tmp, prestart_timeout=90.0, role_timeout=0.0, watchdog_interval=0.02, clock=FakeClock(500.0)
        )
        aborted.mark_attested(CONFIG_DIGEST)
        aborted.abort(ps.CODE_ABORTED)
        assert aborted.start_prestart_window() is False


def test_ai_end_receipt_alone_does_not_terminate():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        receipt = session.send("ai", "end", {"result": "ai_win"})
        assert receipt["ok"] and receipt["recorded"] is True
        assert receipt["terminal"] is False and receipt["ended"] is False
        assert receipt["terminal_phase"] == ps.TERMINAL_NONE
        status = session.send("human", "status", {})
        assert status["terminal"] is False and status["ai_end_received"] is True
        assert status["human_end_received"] is False


def test_human_end_authorizes_terminal_and_is_idempotent():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        session.send("ai", "end", {"result": "ai_win"})
        human = session.send(
            "human",
            "end",
            {"result": "human_win", "human_lives": 3, "ai_lives": 0, "ante": 4, "round": 2, "duration_seconds": 12.5},
        )
        assert human["ok"] and human["terminal"] is True
        # The AI receipt was already present, so the phase closes immediately.
        assert human["terminal_phase"] == ps.TERMINAL_CLOSED
        status = session.send("human", "status", {})
        assert status["terminal"] is True and status["human_end_received"] is True
        assert status["terminal_result"] == "human_win" and status["terminal_reason"] == "human_end"
        # Duplicate human END is a stable, idempotent OK with no second summary.
        duplicate = session.send("human", "end", {"result": "human_win"})
        assert duplicate["ok"] is True and duplicate.get("duplicate") is True
        assert duplicate["terminal_phase"] == ps.TERMINAL_CLOSED
        summaries = read_jsonl(Path(tmp) / "logs" / "summary.jsonl")
        terminal_rows = [row for row in summaries if row.get("terminal")]
        assert len(terminal_rows) == 1, terminal_rows
        assert terminal_rows[0]["result"] == "human_win"
        assert terminal_rows[0]["human_lives"] == 3 and terminal_rows[0]["duration_seconds"] == 12.5
        assert terminal_rows[0]["ai_end_received"] is True


def test_human_end_requires_start_and_terminal_result():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        session.hello("human")
        assert session.send("human", "end", {"result": "human_win"})["code"] == ps.CODE_NOT_STARTED
        session.hello("ai")
        session.ready("human")
        session.ready("ai")
        session.start("human")
        # A human END without a valid terminal result never authorizes match end.
        assert session.send("human", "end", {})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("human", "end", {"result": "not_a_result"})["code"] == ps.CODE_BAD_PAYLOAD
        assert session.send("human", "status", {})["terminal"] is False


def test_ai_receipt_after_human_advances_phase_to_closed():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        human = session.send("human", "end", {"result": "draw"})
        assert human["terminal_phase"] == ps.TERMINAL_AWAITING_AI
        assert session.send("human", "status", {})["terminal_phase"] == ps.TERMINAL_AWAITING_AI
        receipt = session.send("ai", "end", {"result": "draw"})
        assert receipt["ok"] and receipt["terminal_phase"] == ps.TERMINAL_CLOSED
        # The AI receipt never re-authors the human's terminal result.
        status = session.send("human", "status", {})
        assert status["terminal_result"] == "draw" and status["ai_end_received"] is True


def test_abort_and_close_write_exactly_one_terminal_summary():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        service.abort(ps.CODE_ABORTED)
        assert session.send("human", "status", {})["aborted"] is True
        service.close()
        summaries = read_jsonl(Path(tmp) / "logs" / "summary.jsonl")
        terminal_rows = [row for row in summaries if row.get("terminal")]
        assert len(terminal_rows) == 1, terminal_rows
        assert terminal_rows[0]["reason"] == ps.CODE_ABORTED
        assert terminal_rows[0]["result"] == "aborted"


def test_aborted_and_terminal_reason_are_real_service_state():
    """H-C: the host reads real, locked lifecycle state, not a caller-invented attr."""
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        assert service.aborted is False and service.terminal_reason is None
        session = Session(service)
        session.handshake()
        service.abort(ps.CODE_ABORTED)
        assert service.aborted is True
        assert service.terminal_reason == ps.CODE_ABORTED
        assert service.terminal_phase == ps.TERMINAL_CLOSED


def test_abort_during_ai_receipt_wait_preserves_human_result():
    """Low: an abort during the AI-receipt wait keeps the human's authoritative result.

    The abort code is recorded only as the last error; the single terminal summary
    still carries the human END's result and reason.
    """
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        human = session.send("human", "end", {"result": "human_win", "human_lives": 3, "ai_lives": 0})
        assert human["ok"] and human["terminal_phase"] == ps.TERMINAL_AWAITING_AI
        service.abort("ai_receipt_failed")
        assert service.aborted is True
        assert service.terminal_reason == "human_end"
        assert service.terminal_summary()["terminal_result"] == "human_win"
        assert service.terminal_phase == ps.TERMINAL_CLOSED
        service.close()
        terminal = [row for row in read_jsonl(Path(tmp) / "logs" / "summary.jsonl") if row.get("terminal")]
        assert len(terminal) == 1, terminal
        assert terminal[0]["result"] == "human_win"
        assert terminal[0]["reason"] == "human_end"
        assert terminal[0]["human_lives"] == 3
        assert terminal[0]["ai_end_received"] is False


def test_status_seed_is_human_only_and_accepted_once():
    """M-6: only the human role, exactly once, only in an initialized run.

    The real human runtime reports the *resolved* run seed once the run is
    initialized (after ``start``), so acceptance is gated to a started active
    session and never restricted to a fabricated pre-start window; the AI role
    still can never set or rewrite it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        # A pre-start report is not from an initialized run and is refused.
        assert service.mark_attested(CONFIG_DIGEST) is True
        session.hello("human")
        session.hello("ai")
        session.ready("human")
        session.ready("ai")
        prestart = session.send("human", "status", {"seed": "PRESTART1"})
        assert prestart["code"] == ps.CODE_NOT_STARTED
        assert service._logger.seed is None
        assert session.start("human")["ok"]
        # The AI role can never set the seed, even post-start.
        assert session.send("ai", "status", {"seed": "AISP0001"})["code"] == ps.CODE_BAD_ROLE
        assert service._logger.seed is None
        # The human reports the resolved seed exactly once (post-start).
        assert session.send("human", "status", {"seed": "NORMALRUN7"})["ok"]
        assert service._logger.seed == "NORMALRUN7"
        # The AI cannot author a seed report even by guessing the same value.
        assert session.send("ai", "status", {"seed": "NORMALRUN7"})["code"] == ps.CODE_BAD_ROLE
        # A different second value is refused; the first value stands.
        assert session.send("human", "status", {"seed": "REWRITE9"})["code"] == ps.CODE_CONFIG_MISMATCH
        assert service._logger.seed == "NORMALRUN7"
        # A repeated identical value is a stable no-op.
        assert session.send("human", "status", {"seed": "NORMALRUN7"})["ok"]
        # A malformed seed is still a bounded bad payload.
        assert session.send("human", "status", {"seed": "bad seed!"})["code"] == ps.CODE_BAD_PAYLOAD


def test_terminal_session_rejects_a_late_first_seed():
    """M-6: a closed session never accepts its first seed after the summary."""
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        assert session.send("human", "end", {"result": "draw"})["ok"]
        assert session.send("ai", "end", {"result": "draw"})["ok"]
        late = session.send("human", "status", {"seed": "LATESEED"})
        assert late["ok"] is False and late["code"] == ps.CODE_ENDED
        assert service._logger.seed is None


def test_gauntlet_seed_must_match_catalog_seed():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, config_overrides={"mode": "gauntlet", "gauntlet": "Test1"})
        session = Session(service)
        session.handshake()
        assert session.send("human", "status", {"seed": "WRONGSEED"})["code"] == ps.CODE_CONFIG_MISMATCH
        assert service._logger.seed is None
        assert session.send("human", "status", {"seed": "AISP0001"})["ok"]
        assert service._logger.seed == "AISP0001"


def test_terminal_summary_written_at_close_with_orientation_conflict():
    """M-7: one summary after the AI receipt, recording AI fields and a conflict."""
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        human = session.send(
            "human", "end", {"result": "human_win", "human_lives": 3, "ai_lives": 0}
        )
        assert human["terminal_phase"] == ps.TERMINAL_AWAITING_AI
        # No terminal summary is written before the receipt or the grace expiry.
        early = read_jsonl(Path(tmp) / "logs" / "summary.jsonl")
        assert [row for row in early if row.get("terminal")] == []
        receipt = session.send(
            "ai", "end", {"result": "ai_win", "human_lives": 0, "ai_lives": 3, "decisions": 4}
        )
        assert receipt["terminal_phase"] == ps.TERMINAL_CLOSED
        rows = read_jsonl(Path(tmp) / "logs" / "summary.jsonl", lambda row: row.get("terminal"))
        terminal_rows = [row for row in rows if row.get("terminal")]
        assert len(terminal_rows) == 1, terminal_rows
        row = terminal_rows[0]
        assert row["reason"] == "human_end"
        assert row["ai_end_received"] is True
        assert row["ai_result"] == "ai_win"
        assert row["ai_decisions"] == 4
        assert row["result_conflict"] is True


def test_terminal_summary_written_on_ai_receipt_grace_expiry():
    """M-7: the grace expiry still writes the single summary, flagging no conflict."""
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, ai_receipt_grace=0.15, watchdog_interval=0.02)
        service.start()
        try:
            session = Session(service)
            session.handshake()
            assert session.send("human", "end", {"result": "draw"})["terminal_phase"] == ps.TERMINAL_AWAITING_AI
            rows = read_jsonl(Path(tmp) / "logs" / "summary.jsonl", lambda row: row.get("terminal"))
            terminal_rows = [row for row in rows if row.get("terminal")]
            assert terminal_rows and terminal_rows[-1]["reason"] == "human_end"
            assert terminal_rows[-1]["ai_end_received"] is False
            assert terminal_rows[-1]["result_conflict"] is False
            assert service.terminal_phase == ps.TERMINAL_CLOSED
        finally:
            service.stop()


# -- logging -----------------------------------------------------------------


def test_end_logging_summary_and_decision_rows():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake(seed="AISP0001")
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY
        end = session.send(
            "human",
            "end",
            {
                "result": "human_win",
                "human_lives": 3,
                "ai_lives": 0,
                "ante": 4,
                "round": 2,
                "duration_seconds": 123.5,
                "decisions": 11,
                "rejected": 1,
                "errors": 0,
            },
        )
        assert end["ok"] and end["ended"] is True
        # The single terminal summary is written only after the AI receipt (or the
        # bounded grace); the AI's own result agrees here, so no conflict.
        receipt = session.send("ai", "end", {"result": "human_win", "decisions": 11})
        assert receipt["ok"] and receipt["terminal_phase"] == ps.TERMINAL_CLOSED
        decisions_path = Path(tmp) / "logs" / "decisions.jsonl"
        summary_path = Path(tmp) / "logs" / "summary.jsonl"
        assert decisions_path.is_file() and summary_path.is_file()
        decision_rows = read_jsonl(decisions_path, lambda row: row.get("reason") == "practice_ok")
        assert any(row["reason"] == "practice_ok" and row["action"]["type"] == "PLAY_CARDS" for row in decision_rows)
        assert all("credential" not in row and "observation" not in row for row in decision_rows)
        assert decision_rows[-1]["seed"] == "AISP0001"
        summaries = read_jsonl(summary_path, lambda row: row.get("result") == "human_win")
        assert summaries and summaries[-1]["result"] == "human_win"
        assert summaries[-1]["seed"] == "AISP0001"
        assert summaries[-1]["human_lives"] == 3
        assert summaries[-1]["ai_lives"] == 0
        # ended session rejects further ordinary ops
        assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_ENDED


def test_canonicalization_blocks_poisoned_observation():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner()
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake(seed="AISP0003")
        poisoned = _valid_export()
        poisoned["seed"] = "AISP0005"
        poisoned["session_secret"] = HUMAN_CRED
        poisoned["future_shop"] = {"items": [{"cost": 99}]}
        poisoned["hidden_deck_order"] = ["hand:2", "hand:1"]
        poisoned["self"]["hidden_order"] = ["hand:2"]
        sequence = session.send("ai", "decide_begin", poisoned)["sequence"]
        response = wait_for_decision(session, sequence)
        assert response["code"] == ps.CODE_DECISION_READY, response
        assert len(runner.requests) == 1
        request = runner.requests[0]
        blob = json.dumps(request)
        for forbidden in ("AISP0005", "AISP0003", "session_secret", "future_shop", "hidden_deck_order", "hidden_order"):
            assert forbidden not in blob, forbidden
        assert "seed" not in request["observation"]
        assert "seed" not in request["observation"].get("self", {})
        rows = read_jsonl(Path(tmp) / "logs" / "decisions.jsonl", lambda row: row.get("reason") == "practice_ok")
        assert rows and rows[-1]["seed"] == "AISP0003"


def test_canonicalization_rejects_malformed_observation():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        runner = FakeRunner()
        service = make_service(tmp, worker_runner=runner)
        session = Session(service)
        session.handshake()
        # The real (unmocked) canonicalizer rejects the frame before any worker
        # subprocess is launched; the negative probe never reaches the worker.
        assert session.send("ai", "decide_begin", {"schema_version": 1, "phase": "PLAY_HAND"})["code"] == ps.CODE_BAD_OBSERVATION
        assert runner.requests == []
        begin = session.send("ai", "decide_begin", _valid_export())
        assert begin["code"] == ps.CODE_DECISION_PENDING
        assert wait_for_decision(session, begin["sequence"])["code"] == ps.CODE_DECISION_READY
        assert len(runner.requests) == 1


def test_heartbeat_watchdog_aborts_and_blocks_decisions():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, role_timeout=0.2, watchdog_interval=0.02)
        service.start()
        try:
            session = Session(service)
            session.handshake()
            status = None
            deadline = time.time() + 3.0
            while time.time() < deadline:
                time.sleep(0.05)
                status = session.send("ai", "status", {})
                if status.get("aborted"):
                    break
            assert status is not None and status.get("aborted") is True, status
            assert status.get("error") == ps.CODE_ROLE_LOST
            assert session.send("ai", "decide_begin", _valid_export())["code"] == ps.CODE_ABORTED
        finally:
            service.stop()


def test_setup_returns_trusted_config():
    with tempfile.TemporaryDirectory() as tmp:
        config = make_config(
            tmp,
            mode="gauntlet",
            gauntlet="Test2",
            pacing="normal",
            gamemode="gamemode_majorleague",
            forced_options={"attrition": True, "base_time": 180, "forgiveness": 0, "threshold": 180},
        )
        service = make_service_with_config(config)
        session = Session(service)
        service.mark_attested(CONFIG_DIGEST)
        human = session.send("human", "setup", {})
        assert human["ok"] and human["ruleset"] == "majorleague"
        assert human["ruleset_id"] == "ruleset_mp_majorleague"
        assert human["gamemode"] == "gamemode_majorleague"
        # SETUP exposes only the forced option key names (keyset metadata): the
        # runtime reads the actual values locally and never echoes the digest.
        assert human["forced_options"] == ["attrition", "base_time", "forgiveness", "threshold"]
        assert human["expected_config_digest"] == CONFIG_DIGEST
        assert human["gauntlet_seed"] == "AISP0002"
        assert human["pacing"] == "normal" and human["mode"] == "gauntlet"
        assert human["difficulty"] == "competitive"
        ai = session.send("ai", "setup", {})
        assert ai["ok"] and ai["gauntlet_seed"] is None
        assert ai["forced_options"] == human["forced_options"]


def test_major_league_digest_matches_lua_codec():
    forced = {"threshold": 180, "attrition": True, "forgiveness": 0, "order": False}
    keys = sorted(forced, key=lambda k: k.encode("utf-8"))
    canonical_parts = ["ruleset_mp_majorleague", "gamemode_majorleague"]
    for key in keys:
        value = forced[key]
        rendered = "true" if value is True else "false" if value is False else str(value)
        canonical_parts.append(key + "=" + rendered)
    canonical = "|".join(canonical_parts)
    digest = ps.major_league_digest("ruleset_mp_majorleague", "gamemode_majorleague", forced)
    assert ps.fnv1a32_hex("") == "811c9dc5"
    assert len(digest) == 8 and digest == ps.fnv1a32_hex(canonical)
    if not _lupa_available():
        return
    try:
        module = importlib.import_module("lupa.lua51")
    except Exception:  # noqa: BLE001
        return
    lua = module.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
    codec = lua.execute((REPO / "AISparring" / "ai" / "codec.lua").read_text(encoding="utf-8"))
    assert codec["hash_string"](canonical) == digest


def test_decision_result_logging_and_matching():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY
        unknown = session.send("ai", "decision_result", {"sequence": 9999, "accepted": True, "code": "broker_ok"})
        assert unknown["code"] == ps.CODE_DECISION_UNKNOWN
        ok = session.send(
            "ai",
            "decision_result",
            {"sequence": sequence, "accepted": True, "code": "broker_ok", "version": 7, "tick": 42, "reason": "engine_applied"},
        )
        assert ok["ok"] is True and ok["sequence"] == sequence
        rows = read_jsonl(Path(tmp) / "logs" / "results.jsonl", lambda row: row.get("sequence") == sequence)
        assert rows and rows[-1]["accepted"] is True and rows[-1]["code"] == "broker_ok"
        assert rows[-1]["version_id"] == 7


def test_error_op_propagates_via_status():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        assert session.send("ai", "error", {"error": "ai_runtime_failed"})["ok"]
        status = session.send("human", "status", {})
        assert status["error"] == "ai_runtime_failed"


def test_decision_result_exactly_once_dedupe_and_conflict():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY
        first = session.send("ai", "decision_result", {"sequence": sequence, "accepted": True, "code": "broker_ok"})
        assert first["ok"] is True and first["duplicate"] is False
        duplicate = session.send("ai", "decision_result", {"sequence": sequence, "accepted": True, "code": "broker_ok"})
        assert duplicate["ok"] is True and duplicate["duplicate"] is True
        # A conflicting second receipt for the same sequence is rejected and
        # neither logged nor allowed to overwrite the first.
        conflict = session.send(
            "ai", "decision_result", {"sequence": sequence, "accepted": False, "code": "broker_rejected"}
        )
        assert conflict["ok"] is False and conflict["code"] == ps.CODE_RESULT_CONFLICT
        rows = read_jsonl(
            Path(tmp) / "logs" / "results.jsonl", lambda row: row.get("sequence") == sequence
        )
        matching = [row for row in rows if row.get("sequence") == sequence]
        assert len(matching) == 1 and matching[0]["accepted"] is True


def test_post_end_decision_receipt_accepted_within_bounds():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY
        assert session.send("human", "end", {"result": "human_win"})["ok"]
        # The receipt may arrive after the human END; it is recorded, not dropped.
        receipt = session.send("ai", "decision_result", {"sequence": sequence, "accepted": True, "code": "broker_ok"})
        assert receipt["ok"] is True and receipt["duplicate"] is False
        # An unknown sequence is still bounded even post-end.
        unknown = session.send("ai", "decision_result", {"sequence": sequence + 5000, "accepted": True, "code": "broker_ok"})
        assert unknown["code"] == ps.CODE_DECISION_UNKNOWN


def test_summary_merges_service_counters_without_client_overwrite():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp)
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        assert wait_for_decision(session, sequence)["code"] == ps.CODE_DECISION_READY
        # The client under-reports its counters; the service's own counters win.
        assert session.send(
            "human", "end", {"result": "human_win", "decisions": 0, "rejected": 0, "errors": 0}
        )["ok"]
        assert session.send("ai", "end", {"result": "human_win"})["terminal_phase"] == ps.TERMINAL_CLOSED
        rows = read_jsonl(Path(tmp) / "logs" / "summary.jsonl", lambda row: row.get("terminal"))
        terminal_rows = [row for row in rows if row.get("terminal")]
        assert terminal_rows and terminal_rows[-1]["decisions"] >= 1


# -- worker legal integration ------------------------------------------------


def _lupa_available():
    for name in ("lupa.lua51", "lupa.luajit21"):
        try:
            importlib.import_module(name)
        except Exception:  # noqa: BLE001
            return False
    return True


def test_baseline_source_provider_renders_all_difficulties():
    if not _lupa_available():
        return
    provider = ps.BaselineSourceProvider()
    for difficulty in ps.DIFFICULTIES:
        source = provider.source(difficulty)
        assert isinstance(source, str) and source
        assert "function(observation, actions)" in source
    assert provider.source("rookie") == provider.source("rookie")


def test_real_worker_legal_decision_integration():
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(
            tmp,
            source_provider=ps.BaselineSourceProvider(),
            worker_runner=ps.run_policy_worker,
            decision_timeout=30.0,
        )
        session = Session(service)
        session.handshake()
        sequence = session.send("ai", "decide_begin", _valid_export())["sequence"]
        response = wait_for_decision(session, sequence, timeout=40.0)
        assert response["code"] == ps.CODE_DECISION_READY, response
        assert response["action"]["type"] in ps.DEFAULT_ACTION_TYPES


def test_forwarded_observation_is_worker_legal_true():
    """A forged/poisoned observation is re-sanitized by the real worker."""
    if not _lupa_available():
        return
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(
            tmp,
            source_provider=ps.BaselineSourceProvider(),
            worker_runner=ps.run_policy_worker,
            decision_timeout=30.0,
        )
        session = Session(service)
        session.handshake()
        poisoned = _valid_export()
        poisoned["session_secret"] = HUMAN_CRED
        poisoned["seed"] = "AISP0005"
        sequence = session.send("ai", "decide_begin", poisoned)["sequence"]
        response = wait_for_decision(session, sequence, timeout=40.0)
        assert response["code"] == ps.CODE_DECISION_READY, response
        assert response["action"]["type"] in ps.DEFAULT_ACTION_TYPES


# -- Lua protocol mirror -----------------------------------------------------


def test_lua_control_protocol_constants():
    if not _lupa_available():
        return
    try:
        module = importlib.import_module("lupa.lua51")
    except Exception:  # noqa: BLE001
        return
    lua = module.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
    source = (REPO / "AISparring" / "integration" / "control_protocol.lua").read_text(encoding="utf-8")
    protocol = lua.execute(source)
    assert protocol["VERSION"] == "practice_service/1"
    assert protocol["GAUNTLET"]["Test1"] == "AISP0001"
    assert protocol["GAUNTLET"]["Test5"] == "AISP0005"
    message = protocol["envelope"]("sess", "cred", "ai", "hello", 3, None)
    keys = sorted(message.keys())
    assert keys == ["credential", "observation", "op", "role", "sequence", "session"]
    # A nil payload must still serialise as an empty observation table so the
    # sixth key survives JSON encoders that drop nils.
    assert list(message["observation"].keys()) == []
    # The staged transport decodes JSON responses back into Lua tables, so the
    # protocol helpers are exercised with real Lua tables, not Python mappings.
    pending = lua.table(ok=True, code="practice_decision_pending")
    ready = lua.table(ok=True, code="practice_decision_ready", action=lua.table())
    assert protocol["is_pending"](pending) is True
    assert protocol["is_ready"](ready) is True
    # The wire cancel op and its exact payload helper mirror the service.
    assert protocol["OPS"]["DECIDE_CANCEL"] == "decide_cancel"
    assert protocol["CODES"]["DECISION_CANCELLED"] == "practice_decision_cancelled"
    assert protocol["CODES"]["NOT_ATTESTED"] == "practice_not_attested"
    assert protocol["CODES"]["PRESTART_TIMEOUT"] == "practice_prestart_timeout"
    assert protocol["CODES"]["RESULT_CONFLICT"] == "practice_result_conflict"
    assert protocol["CODES"]["CLOSED"] == "practice_closed"
    assert protocol["TERMINAL_PHASES"]["AWAITING_AI"] == "awaiting_ai"
    assert "mark_attested" not in protocol["OPS"]
    cancel_payload = protocol["decide_cancel_payload"](41)
    assert sorted(cancel_payload.keys()) == ["decision_sequence"]
    assert cancel_payload["decision_sequence"] == 41
    described = protocol["describe"]()
    assert described["gauntlet"]["Test3"] == "AISP0003"
    assert described["ops"]["DECIDE_CANCEL"] == "decide_cancel"


# -- loopback socket ---------------------------------------------------------


def test_loopback_socket_roundtrip_and_rate_limit():
    with tempfile.TemporaryDirectory() as tmp:
        service = make_service(tmp, requests_per_window=2, rate_window=60.0)
        service.mark_attested(CONFIG_DIGEST)
        port = service.start()
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
                stream = conn.makefile("rwb")
                for sequence in range(3):
                    message = envelope(service, "human", "hello", sequence, {"version": "1", "content_digest": CONTENT})
                    stream.write((json.dumps(message) + "\n").encode("utf-8"))
                    stream.flush()
                    line = stream.readline()
                    response = json.loads(line.decode("utf-8")) if line else {}
                    if sequence < 2:
                        assert response.get("ok") is True, response
                    else:
                        assert response.get("code") == ps.CODE_RATE_LIMITED, response
        finally:
            service.stop()


def _run_all(require_all: bool) -> int:
    tests = sorted(
        (name, value)
        for name, value in globals().items()
        if name.startswith("test_") and callable(value)
    )
    if require_all and not _lupa_available():
        print("FAIL lupa runtime required but unavailable", file=sys.stderr)
        return 1
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


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Practice service tests")
    parser.add_argument("--require-all", action="store_true", help="fail when lupa is unavailable")
    args = parser.parse_args(argv)
    print("AISparring practice service tests")
    print(f"repository: {REPO}")
    return _run_all(args.require_all)


if __name__ == "__main__":
    sys.exit(main())
