#!/usr/bin/env python3
"""Host-owned Ranked deck/stake draft: profile, state machine, commitment.

Everything runs in-memory against the real ``tools/ranked_draft.py`` authority
and the real ``tools/practice_host.py`` daemon with synthetic temp trees and
injected fakes: no live install, %AppData%, game, server, process or network.
The only real socket is the loopback daemon the host tests already use. The Lua
runtime parity checks load the real ``ranked_config.lua`` under Lua 5.1 and
LuaJIT; no game is touched.
"""
from __future__ import annotations

import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import practice_host  # noqa: E402
import ranked_draft  # noqa: E402
import ranked_effective_config  # noqa: E402
import ruleset_contract  # noqa: E402

RANKED_LUA = REPO / "AISparring" / "integration" / "ranked_config.lua"
RUNTIMES = (("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21"))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

class FakeClock:
    def __init__(self, start=1000.0):
        self.t = float(start)

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


class FakeLiveHandle:
    def __init__(self, create_time, image_path, exited=False):
        self._create_time = create_time
        self._image_path = image_path
        self._exited = exited

    def create_time(self):
        return self._create_time

    def image_path(self):
        return self._image_path

    def has_exited(self):
        return self._exited

    def close(self):
        pass

    def terminate(self, timeout=10.0):
        return True


class FakeEnumerator:
    def list(self):
        return []


class FakeSupervisor:
    def __init__(self):
        self.phase = "completed"
        self.error = None
        self.cleaned = 0
        self.session_id = "sess-1"

    def run(self):
        return {"ok": True, "code": practice_host.CODE_OK}

    def human_active(self):
        return False

    def cleanup(self):
        self.cleaned += 1


def _ok_runtime_checker(config):
    return {"ok": True, "code": practice_host.CODE_OK, "problems": [], "runtimes": ["luajit21"]}


def _catalog():
    decks = {
        key: {"center_key": "b_" + key, "name": key.title()}
        for key in ("red", "blue", "yellow", "green", "black", "magic")
    }
    return {
        "schema": ruleset_contract.RANKED_CATALOG_SCHEMA,
        "eligible_decks": ["b_" + key for key in decks],
        "decks": decks,
        "stakes": {
            "white": {"index": 1, "max_index": 8},
            "green": {"index": 2, "max_index": 8},
            "black": {"index": 3, "max_index": 8},
        },
    }


def _make_config(root, **overrides):
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


def _live_opener(config):
    return lambda pid: FakeLiveHandle(1000.0, str(Path(config.live_install_root) / "Balatro.exe"))


def _envelope(daemon, op, request=None):
    return {"schema": practice_host.REQUEST_SCHEMA, "op": op, "auth": daemon._secret, "request": request or {}}


def _start_request(draft_id=None, **overrides):
    values = dict(
        session_id="correlation-1",
        difficulty="competitive",
        pacing="normal",
        mode="normal",
        gauntlet=None,
        live_pid=4321,
        live_create_time=1000.0,
    )
    values.update(overrides)
    if draft_id is not None:
        values["draft_id"] = draft_id
    return values


def _draft(catalog=None, first_actor="human", clock=None, settings=None):
    built = {"decks": (catalog or _catalog())["decks"], "stakes": (catalog or _catalog())["stakes"]}
    return ranked_draft.RankedDraft(
        built,
        settings or {"mode": "normal", "difficulty": "competitive", "pacing": "normal", "gauntlet": None},
        "gen-1",
        first_actor=first_actor,
        clock=clock or FakeClock(),
    )


def _human_act(draft, request_id, options=None):
    stage = draft.current_actor()
    assert stage == "human", stage
    chosen = options if options is not None else draft.remaining[: draft.required_count()]
    return draft.apply("human", request_id, draft.revision, draft.current_operation(), chosen)


def _drive_to_completion(draft, prefix="h"):
    draft.auto_ai()
    guard = 0
    while draft.status == "active":
        guard += 1
        assert guard < 10, "draft did not terminate"
        verdict = _human_act(draft, "%s-%d" % (prefix, guard))
        assert verdict["ok"], verdict
        draft.auto_ai()
    assert draft.status == "completed"
    return draft


# ---------------------------------------------------------------------------
# Profile / pool
# ---------------------------------------------------------------------------

def test_pool_is_unique_white_capped_and_fails_closed():
    built = ranked_draft.build_draft_pool({"decks": _catalog()["decks"], "stakes": _catalog()["stakes"]})
    assert built["ok"], built
    pool = built["pool"]
    assert len(pool) == 9 and len(set(pool)) == 9
    assert any(option.split("~")[1] == "white" for option in pool), "white stake guaranteed"
    deck_counts = {}
    stake_counts = {}
    for option in pool:
        deck, stake = option.split("~")
        deck_counts[deck] = deck_counts.get(deck, 0) + 1
        stake_counts[stake] = stake_counts.get(stake, 0) + 1
    assert max(deck_counts.values()) <= ranked_draft.MAX_DECK_REPEAT
    assert max(stake_counts.values()) <= ranked_draft.MAX_STAKE_REPEAT
    # A catalog that cannot supply the profile fails closed rather than guessing.
    small = {
        "decks": {k: _catalog()["decks"][k] for k in ("red", "blue")},
        "stakes": {"white": {"index": 1}, "green": {"index": 2}},
    }
    insufficient = ranked_draft.build_draft_pool(small)
    assert insufficient["ok"] is False and "ranked_pool_insufficient" in insufficient["problems"]
    # A missing named White stake is refused.
    no_white = ranked_draft.build_draft_pool(
        {"decks": _catalog()["decks"], "stakes": {"green": {"index": 2}, "black": {"index": 3}, "blue": {"index": 4}}}
    )
    assert no_white["ok"] is False and "ranked_white_stake_missing" in no_white["problems"]


def test_transcript_validation_both_actor_orders_and_tamper():
    built = ranked_draft.build_draft_pool({"decks": _catalog()["decks"], "stakes": _catalog()["stakes"]})
    pool = built["pool"]
    for first in ("human", "ai"):
        draft = _draft(first_actor=first)
        _drive_to_completion(draft)
        public = draft.public_commitment()
        verdict = ranked_draft.commitment_from_public(public)
        assert verdict["ok"] and verdict["digest"] == public["digest"]
        plan = ranked_draft.stage_plan(first)
        ops = [step["operation"] for step in public["transcript"]]
        assert ops == ["ban", "ban", "ban", "select"]
        counts = [len(step["option_ids"]) for step in public["transcript"]]
        assert counts == [1, 2, 2, 1]
        actors = [step["actor"] for step in public["transcript"]]
        assert actors == [plan[0]["actor"], plan[1]["actor"], plan[2]["actor"], plan[3]["actor"]]
    # Tampering any step, the pool or the final fails closed.
    draft = _drive_to_completion(_draft())
    public = draft.public_commitment()
    tampered = dict(public)
    tampered["final"] = public["pool"][0]
    assert ranked_draft.commitment_from_public(tampered)["ok"] is False
    tampered = dict(public)
    tampered["transcript"] = [dict(step) for step in public["transcript"]]
    tampered["transcript"][0] = {"actor": "ai", "operation": "ban", "option_ids": [public["pool"][0]]}
    assert ranked_draft.commitment_from_public(tampered)["ok"] is False
    tampered = dict(public)
    tampered["pool"] = public["pool"][:-1]
    assert ranked_draft.commitment_from_public(tampered)["ok"] is False


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

def test_state_machine_rejections_and_ttl():
    clock = FakeClock()
    draft = _draft(clock=clock)
    # Wrong actor is refused by the host-derived turn check.
    assert draft.apply("ai", "x1", draft.revision, "ban", [draft.remaining[0]])["code"] == "ranked_draft_out_of_turn"
    # A malformed option id is refused.
    assert draft.apply("human", "x2", draft.revision, "ban", ["not-an-option"])["code"] == "ranked_draft_options_invalid"
    # Removed/unknown option is refused.
    assert draft.apply("human", "x3", draft.revision, "ban", ["red~missing"])["code"] == "ranked_draft_option_unavailable"
    # Excessive count is refused.
    assert draft.apply("human", "x4", draft.revision, "ban", draft.remaining[:2])["code"] == "ranked_draft_count_invalid"
    # Wrong operation is refused.
    assert draft.apply("human", "x6", draft.revision, "select", [draft.remaining[0]])["code"] == "ranked_draft_operation_invalid"
    # A stale revision is refused.
    assert draft.apply("human", "x7", 99, "ban", [draft.remaining[0]])["code"] == "ranked_draft_stale"
    # Duplicate ids are refused at the two-ban stage.
    _human_act(draft, "pre-dup")
    draft.auto_ai()
    assert draft.required_count() == 2
    duplicate = [draft.remaining[0], draft.remaining[0]]
    assert draft.apply(
        "human", "x5", draft.revision, "ban", duplicate
    )["code"] == "ranked_draft_duplicate_option"
    # A successful action, then an exact replay of the same request id returns the
    # stored outcome without another transition; conflicting reuse is refused.
    revision_before = draft.revision
    original_options = draft.remaining[: draft.required_count()]
    first = draft.apply("human", "ok-1", revision_before, "ban", original_options)
    assert first["ok"]
    revision_after = draft.revision
    draft.auto_ai()
    replay = draft.apply("human", "ok-1", revision_before, "ban", original_options)
    assert replay["code"] == "ranked_draft_replay", replay
    conflict = draft.apply("human", "ok-1", revision_before, "ban", draft.remaining[:1])
    assert conflict["code"] == "ranked_draft_request_conflict"
    assert draft.revision > revision_after
    # TTL is monotonic, never extended by a request, and voids the draft.
    ttl_clock = FakeClock()
    expiring = _draft(clock=ttl_clock)
    ttl_clock.advance(ranked_draft.TTL_SECONDS - 1)
    assert expiring.apply("human", "near", expiring.revision, "ban", expiring.remaining[:1])["ok"], "within TTL"
    ttl_clock.advance(3)
    expired = expiring.apply("human", "late", expiring.revision, "ban", expiring.remaining[:1])
    assert expired["code"] == "ranked_draft_expired", expired


def test_cancel_and_completed_and_consumed():
    draft = _draft()
    assert draft.cancel()["ok"] is True
    assert draft.status == "cancelled"
    assert draft.apply("human", "c1", draft.revision, "ban", draft.remaining[:1])["code"] == "ranked_draft_cancelled"

    completed = _drive_to_completion(_draft())
    assert completed.selection is not None
    assert completed.mark_consumed() is True
    assert completed.mark_consumed() is False, "consume is exactly once"
    assert completed.apply(
        "human", "post", completed.revision, "select", completed.remaining[:1]
    )["code"] == "ranked_draft_completed"


def test_cancel_completed_unconsumed_and_forbid_consumed():
    # Architecture: cancellation voids a completed UNCONSUMED draft.
    draft = _drive_to_completion(_draft())
    assert draft.cancel()["ok"] is True, "an unconsumed completed draft can be cancelled"
    assert draft.cancelled and draft.status == "cancelled"
    assert draft.cancel()["ok"] is True, "cancelling again is honest idempotence"
    assert draft.mark_consumed() is False, "a cancelled draft can never be consumed"
    assert draft.apply("human", "post-cancel", draft.revision, "select", draft.remaining[:1])["code"] == (
        "ranked_draft_cancelled"
    )
    # A consumed draft is owned by a launch and can never be cancelled.
    consumed = _drive_to_completion(_draft())
    assert consumed.mark_consumed() is True
    assert consumed.cancel() == {"ok": False, "code": "ranked_draft_consumed"}


def test_mark_consumed_refuses_expired():
    clock = FakeClock()
    draft = _drive_to_completion(_draft(clock=clock))
    assert draft.status == "completed"
    clock.advance(ranked_draft.TTL_SECONDS + 1)
    assert draft.expired() is True
    assert draft.mark_consumed() is False, "an expired completed draft can never be consumed"
    assert draft.status == "expired"


def test_ai_preferences_are_seed_independent():
    # The draft API carries no gameplay/gauntlet seed at all: identical pools
    # always produce identical AI choices.
    first = _draft(first_actor="ai")
    second = _draft(first_actor="ai")
    assert first.ai_option_ids() == second.ai_option_ids()
    options_a = first.ai_option_ids()
    for option in options_a:
        assert option in first.remaining
    # The AI only ever acts on its own turn; the host never invents a human move.
    assert first.current_actor() == "ai"
    assert first.apply("ai", "ai-1", first.revision, first.current_operation(), first.ai_option_ids())["ok"]
    assert first.current_actor() == "human"


def test_settings_binding_invalidates_stale_draft():
    draft = _draft(settings={"mode": "normal", "difficulty": "competitive", "pacing": "normal", "gauntlet": None})
    assert draft.settings_match(
        {"mode": "normal", "difficulty": "competitive", "pacing": "normal", "gauntlet": None}, "gen-1"
    )
    assert not draft.settings_match(
        {"mode": "normal", "difficulty": "rookie", "pacing": "normal", "gauntlet": None}, "gen-1"
    )
    assert not draft.settings_match(
        {"mode": "normal", "difficulty": "competitive", "pacing": "normal", "gauntlet": None}, "gen-2"
    )


# ---------------------------------------------------------------------------
# Lua parity
# ---------------------------------------------------------------------------

def _load_lua(module_name):
    import importlib

    lua = importlib.import_module(module_name).LuaRuntime(unpack_returned_tuples=True)
    config = lua.execute(RANKED_LUA.read_text(encoding="utf-8"))
    return lua, config


def _to_lua(lua, value):
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = _to_lua(lua, item)
        return table
    if isinstance(value, (list, tuple)):
        return lua.table_from([_to_lua(lua, item) for item in value])
    return value


def test_lua_runtime_parity_for_the_draft_commitment():
    draft = _drive_to_completion(_draft())
    public = draft.public_commitment()
    for display, module_name in RUNTIMES:
        lua, config = _load_lua(module_name)
        lua_public = _to_lua(lua, public)
        derived, code, final = config.validate_draft(lua_public)
        assert code == "ok", (display, code)
        assert derived == public["digest"], (display, derived, public["digest"])
        assert final == public["final"], display
        # Tampering the transcript is refused independently in Lua.
        bad = dict(public)
        bad["transcript"] = [dict(step) for step in public["transcript"]]
        bad["transcript"][1] = {"actor": "human", "operation": "ban", "option_ids": [public["pool"][1]]}
        derived_bad, code_bad = config.validate_draft(_to_lua(lua, bad))
        assert derived_bad is None and code_bad is not None, display


# ---------------------------------------------------------------------------
# Host daemon: draft ops, gate-preserve, atomic consume
# ---------------------------------------------------------------------------

def _daemon(root, gate, factory):
    config = _make_config(root, ranked_catalog=_catalog(), ranked_guest_catalog=_catalog())
    daemon = practice_host.HostDaemon(
        config,
        opener=_live_opener(config),
        enumerator=FakeEnumerator(),
        runtime_checker=_ok_runtime_checker,
        start_gate=gate,
        supervisor_factory=factory,
    )
    daemon.start()
    return daemon


def _drive_daemon_draft(daemon):
    begin = daemon.handle_request(
        _envelope(
            daemon,
            "draft_begin",
            {"difficulty": "competitive", "pacing": "normal", "mode": "normal", "gauntlet": None},
        )
    )
    assert begin["ok"], begin
    state = begin["draft"]
    draft_id = state["draft_id"]
    guard = 0
    while state["status"] == "active":
        guard += 1
        assert guard < 10
        assert state["current_actor"] == "human"
        action = {
            "draft_id": draft_id,
            "expected_revision": state["revision"],
            "request_id": "host-%d" % guard,
            "operation": state["operation"],
            "option_ids": state["remaining"][: state["required_count"]],
        }
        response = daemon.handle_request(_envelope(daemon, "draft_action", action))
        assert response["ok"], response
        state = response["draft"]
    assert state["status"] == "completed"
    return draft_id


def test_daemon_draft_flow_gate_preserves_and_atomic_consume():
    with tempfile.TemporaryDirectory() as tmp:
        created = []

        def factory(config, request):
            supervisor = FakeSupervisor()
            created.append(supervisor)
            return supervisor

        gate_state = {"ok": True}
        daemon = _daemon(tmp, lambda: {"ok": gate_state["ok"], "code": practice_host.CODE_OK}, factory)
        try:
            draft_id = _drive_daemon_draft(daemon)
            # A gate refusal preserves the draft.
            gate_state["ok"] = False
            refused = daemon._op_start(_start_request(draft_id))
            assert refused["ok"] is False, refused
            assert daemon._completed_draft_snapshot(draft_id) is not None, "gate refusal preserves the draft"
            # Editing the launch settings invalidates the stale draft.
            stale = daemon._op_start(_start_request(draft_id, difficulty="rookie"))
            assert stale["code"] == practice_host.CODE_RANKED_DRAFT_STALE, stale
            assert daemon._completed_draft_snapshot(draft_id) is None, "settings edit voids the draft"
            # A fresh draft can be launched; the gate passes and it is consumed.
            gate_state["ok"] = True
            draft_id = _drive_daemon_draft(daemon)
            accepted = daemon._op_start(_start_request(draft_id))
            assert accepted["ok"] is True and accepted["code"] == practice_host.CODE_ACCEPTED, accepted
            assert daemon._completed_draft_snapshot(draft_id) is None, "accepted launch consumes the draft"
            # A duplicate relaunch is refused; the draft cannot be reused.
            again = daemon._op_start(_start_request(draft_id))
            assert again["ok"] is False and again["code"] == practice_host.CODE_RANKED_DRAFT
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


def test_daemon_draft_requires_a_bound_draft_and_rejects_bad_actions():
    with tempfile.TemporaryDirectory() as tmp:
        created = []
        daemon = _daemon(
            tmp,
            lambda: {"ok": True, "code": practice_host.CODE_OK},
            lambda config, request: created.append(FakeSupervisor()) or created[-1],
        )
        try:
            # A launch with no completed draft is refused before the supervisor.
            missing = daemon._op_start(_start_request("draft-missing"))
            assert missing["ok"] is False and missing["code"] == practice_host.CODE_RANKED_DRAFT
            assert created == []
            # Unknown draft ids are refused; no state transition.
            assert daemon.handle_request(
                _envelope(daemon, "draft_status", {"draft_id": "draft-nope"})
            )["code"] == practice_host.CODE_RANKED_DRAFT_UNKNOWN
            dash = daemon.handle_request(
                _envelope(
                    daemon,
                    "draft_action",
                    {
                        "draft_id": "draft-nope",
                        "expected_revision": 0,
                        "request_id": "r1",
                        "operation": "ban",
                        "option_ids": ["x~white"],
                    },
                )
            )
            assert dash["code"] == practice_host.CODE_RANKED_DRAFT_UNKNOWN
            # Ranked gauntlet is refused before a draft exists.
            gauntlet = daemon.handle_request(
                _envelope(
                    daemon,
                    "draft_begin",
                    {"difficulty": "competitive", "pacing": "normal", "mode": "gauntlet", "gauntlet": "Test1"},
                )
            )
            assert gauntlet["code"] == practice_host.CODE_RANKED_GAUNTLET
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


def test_daemon_late_launch_failure_still_consumes():
    with tempfile.TemporaryDirectory() as tmp:
        def raising_factory(config, request):
            raise RuntimeError("boom")

        daemon = _daemon(tmp, lambda: {"ok": True, "code": practice_host.CODE_OK}, raising_factory)
        try:
            draft_id = _drive_daemon_draft(daemon)
            try:
                daemon._op_start(_start_request(draft_id))
            except RuntimeError:
                pass
            else:
                raise AssertionError("factory failure did not propagate")
            # Consumed after a successful gate even though launch then failed.
            assert daemon._completed_draft_snapshot(draft_id) is None
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


def test_daemon_cancel_completed_via_host_then_launch_refused():
    with tempfile.TemporaryDirectory() as tmp:
        created = []
        daemon = _daemon(
            tmp,
            lambda: {"ok": True, "code": practice_host.CODE_OK},
            lambda config, request: created.append(FakeSupervisor()) or created[-1],
        )
        try:
            draft_id = _drive_daemon_draft(daemon)
            reply = daemon.handle_request(_envelope(daemon, "draft_cancel", {"draft_id": draft_id}))
            assert reply["ok"] is True, reply
            assert daemon._completed_draft_snapshot(draft_id) is None, "cancelled draft still bound"
            refused = daemon._op_start(_start_request(draft_id))
            assert refused["ok"] is False and refused["code"] == practice_host.CODE_RANKED_DRAFT, refused
            assert created == [], "no supervisor for a cancelled draft"
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


def test_daemon_gate_crossing_expiry_refuses_and_creates_nothing():
    with tempfile.TemporaryDirectory() as tmp:
        holder = {}
        created = []

        def gate():
            # The pre-acknowledgement gate is slow enough that the monotonic TTL
            # elapses after the snapshot but before the atomic consume.
            draft = holder["daemon"]._draft
            draft._clock = lambda: draft.created_at + ranked_draft.TTL_SECONDS + 1
            return {"ok": True, "code": practice_host.CODE_OK}

        def factory(config, request):
            created.append(FakeSupervisor())
            return created[-1]

        daemon = _daemon(tmp, gate, factory)
        holder["daemon"] = daemon
        try:
            draft_id = _drive_daemon_draft(daemon)
            refused = daemon._op_start(_start_request(draft_id))
            assert refused["ok"] is False, refused
            assert refused["code"] == practice_host.CODE_RANKED_DRAFT, refused
            assert created == [], "no supervisor for a draft that expired during the gate"
        finally:
            with daemon._lock:
                daemon._ticket = None
            daemon.stop(force=True)


def _run_all() -> int:
    tests = sorted(
        (name, value) for name, value in globals().items() if name.startswith("test_") and callable(value)
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
