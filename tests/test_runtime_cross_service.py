#!/usr/bin/env python3
"""Cross-service runtime contract.

Feeds the *actual* JSON envelopes emitted by the real Lua control transport
(``AISparring/integration/control_transport.lua`` over
``control_protocol.lua``) into the *actual* ``tools/practice_service.py``
``handle_request`` wire entrypoint, with a real canonical exported observation.
Two AI decisions are interleaved with heartbeats, status, decision results and
the terminal end so the single per-role wire sequence, the private
local-decision mapping and the additive ``decision_result`` op are exercised end
to end.

No game, Mods directory, socket, live path, save, launcher or policy subprocess
is touched; the service runs in-process with its worker replaced by a
deterministic in-memory runner.
"""
from __future__ import annotations

import argparse
import importlib
import json
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import practice_service as ps  # noqa: E402

CONTENT = "digest-abc"
SESSION = "sess-1"
HUMAN_CRED = "h" * 64
AI_CRED = "a" * 64

# Source-derived Major League configuration (docs/MAJOR_LEAGUE_DIGEST.md): the
# exact forced options of the pinned rulesets/majorleague.lua, and the digest the
# trusted host derives from them. The runtime must recompute the same digest from
# the live MP.LOBBY.config, never echo this value.
RULESET_ID = "ruleset_mp_majorleague"
GAMEMODE = "gamemode_mp_attrition"
FORCED_OPTIONS = {
    "the_order": False,
    "timer_forgiveness": 0,
    "preview_disabled": True,
    "enemy_location_disabled": True,
    "timer_base_seconds": 180,
    "timer_display_threshold": 180,
}
CONFIG_DIGEST = ps.major_league_digest(RULESET_ID, GAMEMODE, FORCED_OPTIONS)
WIRE_JSON = REPO / "AISparring" / "integration" / "wire_json.lua"
SMODS_JSON = REPO / "work" / "reference" / "offline" / "smods-json.lua"

# The real Lua transport is created with decision_base = 1000000 and this
# observation is a real canonical client export (see tests/test_practice_service).
VALID_EXPORT = {
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


class DeterministicRunner:
    """In-memory policy worker: always returns one legal certified action."""

    def __init__(self):
        self.requests = []

    def __call__(self, request, timeout, register):
        self.requests.append(request)
        return {"ok": True, "code": "policy_ok", "action": {"type": "SELECT_BLIND"}}


def _service_config(tmp: Path) -> "ps.ServiceConfig":
    return ps.ServiceConfig(
        session_id=SESSION,
        difficulty="competitive",
        pacing="normal",
        mode="normal",
        match_port=8788,
        log_root=Path(tmp) / "logs",
        content_hash=CONTENT,
        expected_config_digest=CONFIG_DIGEST,
        gauntlet=None,
        ruleset_id=RULESET_ID,
        gamemode=GAMEMODE,
        forced_options=dict(FORCED_OPTIONS),
    )


def _attested_service(tmp: Path, worker_runner) -> "ps.PracticeService":
    config = _service_config(tmp)
    service = ps.PracticeService(
        config,
        human_credential=HUMAN_CRED,
        ai_credential=AI_CRED,
        worker_runner=worker_runner,
    )
    service.mark_attested(CONFIG_DIGEST)
    return service


LUA_SOURCE = r"""
local support = dofile(ROOT .. '/tests/runtime/support.lua')
local protocol = support.protocol(ROOT)
local json = support.json(ROOT)
local ControlTransport = support.mod(ROOT, 'AISparring/integration/control_transport.lua')

local to_worker = support.channel()
local from_worker = support.channel()
local sent = {}
local responses = {}

-- Every frame the Lua transport emits is handed to the real Python
-- PracticeService.handle_request; the response is queued back on the worker
-- channel exactly as the socket worker would.
to_worker.push = function(self, text)
	local frame = json.decode(text)
	sent[#sent + 1] = frame
	local response_text = service_handle(text)
	if response_text ~= nil and #response_text > 0 then
		responses[#responses + 1] = json.decode(response_text)
		from_worker:push(response_text)
	end
	return true
end

local clock = { t = 0 }
function clock.now() return clock.t end

local transport, code = ControlTransport.factory({
	role = 'ai',
	session = SESSION,
	credential = AI_CRED,
	protocol = protocol,
	channels = { to_worker = to_worker, from_worker = from_worker },
	clock = clock,
	encode = json.encode,
	decode = json.decode,
	decision_base = 1000000,
	poll_interval = 0,
	request_timeout = 10,
})
assert(transport ~= nil, 'transport factory failed: ' .. tostring(code))
clock.t = 1
assert(transport.start())

-- The human role drives the trusted side directly through the same service.
local function human(op, payload)
	local r = human_call(op, json.encode(payload or {}))
	return json.decode(r)
end

assert(human('hello', { version = 'practice_service/1', content_digest = CONTENT }).ok)
assert(human('ready', { config_digest = CONFIG_DIGEST }).ok)

-- AI handshake through the real Lua transport frames.
assert(transport.send(protocol.OPS.HELLO, { version = 'practice_service/1', content_digest = CONTENT }))
assert(transport.send(protocol.OPS.READY, { config_digest = CONFIG_DIGEST }))
assert(human('start', {}).ok)

local function poll_until_terminal(timeout_polls)
	for _ = 1, timeout_polls do
		clock.t = clock.t + 1
		local response = transport.poll_decision()
		if response ~= nil then
			return response
		end
	end
	return nil
end

-- Decision 1.
assert(transport.request({ sequence = 1000000, observation = json.decode(OBS_JSON) }) == 'd1000000')
local first = poll_until_terminal(200)
assert(first ~= nil, 'decision 1 never completed')
assert(first.code == protocol.CODES.DECISION_READY, 'decision 1: ' .. tostring(first.code))
assert(first.sequence == 1000000, 'decision 1 local sequence not mapped: ' .. tostring(first.sequence))
assert(first.action ~= nil and first.action.type == 'SELECT_BLIND')

-- Interleave heartbeat/status/result before the second decision.
assert(transport.send(protocol.OPS.HEARTBEAT, { tick = 1 }))
assert(transport.send(protocol.OPS.STATUS, {}))
assert(transport.decision_result(1000000, { accepted = true, code = 'broker_ok' }))

-- Decision 2 must not be rejected as a replay by the single per-role counter.
assert(transport.request({ sequence = 1000001, observation = json.decode(OBS_JSON) }) == 'd1000001')
local second = poll_until_terminal(200)
assert(second ~= nil, 'decision 2 never completed')
assert(second.code == protocol.CODES.DECISION_READY, 'decision 2: ' .. tostring(second.code))
assert(second.sequence == 1000001, 'decision 2 local sequence not mapped: ' .. tostring(second.sequence))
assert(transport.decision_result(1000001, { accepted = true, code = 'broker_ok' }))

-- Terminal end through the real service vocabulary.
assert(transport.send(protocol.OPS.END, { result = 'ai_win', decisions = 2 }))
clock.t = clock.t + 1
while transport.poll_coordination() ~= nil do end

-- Contract assertions over the actual emitted wire frames.
local decide_begins = {}
local result_requests = {}
local previous = 0
local last_begin = nil
for i = 1, #sent do
	local frame = sent[i]
	if frame.op == 'decide_poll' then
		-- A poll reuses the outstanding decision's wire sequence by design.
		assert(frame.sequence == last_begin, 'decide_poll must reuse the decision wire sequence')
	else
		assert(type(frame.sequence) == 'number' and frame.sequence > previous,
			'wire sequence not strictly increasing at frame ' .. i)
		previous = frame.sequence
	end
	if frame.op == 'decide_begin' then
		last_begin = frame.sequence
		decide_begins[#decide_begins + 1] = frame
	end
	if frame.op == 'decision_result' then
		result_requests[#result_requests + 1] = frame
	end
end
assert(#decide_begins == 2, 'expected two decide_begin frames, got ' .. #decide_begins)
assert(decide_begins[1].sequence < decide_begins[2].sequence)
assert(#result_requests == 2, 'expected two decision_result frames, got ' .. #result_requests)
assert(result_requests[1].observation.sequence == decide_begins[1].sequence,
	'decision_result must carry the decision wire sequence')
assert(result_requests[2].observation.sequence == decide_begins[2].sequence)
assert(result_requests[1].sequence > decide_begins[1].sequence)

for i = 1, #responses do
	assert(responses[i].code ~= protocol.CODES.REPLAY,
		'service rejected a wire frame as a replay: ' .. json.encode(sent[i]))
end
"""


def run_runtime(display: str, module_name: str) -> None:
    module = importlib.import_module(module_name)
    with tempfile.TemporaryDirectory() as tmp:
        runner = DeterministicRunner()
        service = _attested_service(Path(tmp), runner)
        human_sequence = {"value": -1}

        def human_call(op, payload_text):
            human_sequence["value"] += 1
            message = {
                "session": SESSION,
                "credential": HUMAN_CRED,
                "role": "human",
                "op": op,
                "sequence": human_sequence["value"],
                "observation": json.loads(payload_text or "{}"),
            }
            return json.dumps(service.handle_request(message))

        def service_handle(text):
            message = json.loads(text)
            response = service.handle_request(message)
            if message.get("op") == "decide_poll" and response.get("code") == ps.CODE_DECISION_PENDING:
                deadline = time.time() + 5.0
                while time.time() < deadline and response.get("code") == ps.CODE_DECISION_PENDING:
                    time.sleep(0.005)
                    response = service.handle_request(message)
            return json.dumps(response)

        lua = module.LuaRuntime(unpack_returned_tuples=True)
        globals_ = lua.globals()
        globals_.ROOT = REPO.as_posix()
        globals_.SESSION = SESSION
        globals_.AI_CRED = AI_CRED
        globals_.CONTENT = CONTENT
        globals_.CONFIG_DIGEST = CONFIG_DIGEST
        globals_.OBS_JSON = json.dumps(VALID_EXPORT)
        globals_.human_call = human_call
        globals_.service_handle = service_handle
        lua.execute(LUA_SOURCE)
        assert len(runner.requests) == 2, f"expected two policy requests, got {len(runner.requests)}"


TWO_BOOTSTRAP_SOURCE = r"""
local support = dofile(ROOT .. '/tests/runtime/support.lua')
local json = support.json(ROOT)
local wire_json = false
local encode = json.encode
local decode = json.decode
if WIRE_JSON_PATH ~= '' and SMODS_JSON_PATH ~= '' then
	-- Use the real pinned SMODS/rxi json as the base codec and compose the exact
	-- six-key envelope through the companion wire module: empty payloads become
	-- `{}` (never `[]`) for the critical frames, and no test json is used.
	local ok_base, base = pcall(dofile, SMODS_JSON_PATH)
	local ok_wire, WireJson = pcall(dofile, WIRE_JSON_PATH)
	if ok_base and ok_wire and type(base) == 'table' and type(WireJson) == 'table' then
		local wire = WireJson.factory(base)
		if type(wire) == 'table' then
			encode = wire.encode_service
			decode = wire.decode
			wire_json = true
		end
	end
end

-- The real transport frames are handed to the real Python service entrypoint and
-- the response is queued back exactly as the socket worker would.
local from_worker = support.channel()
local sent_ops = {}
local reported_seed = nil
local to_worker = {}
function to_worker:push(text)
	local ok, frame = pcall(json.decode, text)
	if ok and type(frame) == 'table' and type(frame.op) == 'string' then
		sent_ops[frame.op] = (sent_ops[frame.op] or 0) + 1
		if frame.op == 'status' and type(frame.observation) == 'table' then
			reported_seed = frame.observation.seed
		end
	end
	local response = service_request(text)
	if type(response) == 'string' and #response > 0 then
		from_worker:push(response)
	end
	return true
end

local probe_result = nil
function boot_set_terminal(value)
	probe_result = value
end

local instance, boot_code, bctx = support.bootstrap(ROOT, {
	role = ROLE,
	session = SESSION,
	credential = CRED,
	nonce = NONCE,
	content_hash = CONTENT,
	control_port = 49321,
	mode = MODE,
	difficulty = 'competitive',
	pacing = 'normal',
	run_seed = RUN_SEED,
	lives = 4,
	enemy_lives = 2,
	terminal_probe = function() return probe_result end,
	channels = { to_worker = to_worker, from_worker = from_worker },
	encode = encode,
	decode = decode,
	logger = { record = function() end },
})
assert(instance ~= nil, 'bootstrap: ' .. tostring(boot_code))
-- The match is not running yet; the loop must stay gated until the ordinary
-- MP start is observed.
bctx.engine.MP.LOBBY.started = false

function boot_uses_wire_json()
	return wire_json
end

function boot_install()
	local ok, code = instance.install()
	return ok == true, tostring(code)
end

function boot_step(delta)
	bctx.clock.advance(delta)
	local status, code = instance.update(0.016)
	return tostring(status), tostring(code)
end

function boot_describe()
	local d = instance.describe()
	return {
		state = d.state,
		handshake = d.handshake,
		setup_acked = d.setup_acked,
		coordinated = d.coordinated,
		lobby_ready = d.lobby_ready,
		last_error = d.last_error,
	}
end

function boot_op_count(op)
	return sent_ops[op] or 0
end

function boot_reported_seed()
	return reported_seed
end

function boot_set_connected(value)
	bctx.engine.MP.LOBBY.connected = value == true
end

function boot_lobby_code()
	return instance.lobby_code()
end

function boot_ready_to_start()
	return bctx.engine.MP.LOBBY.ready_to_start == true
end

-- Simulates the ordinary server relay of the guest's ready state to the host
-- (the two runtimes do not share engine memory).
function boot_set_ready_to_start(value)
	bctx.engine.MP.LOBBY.ready_to_start = value == true
end

function boot_engine_started()
	return bctx.engine.MP.LOBBY.started == true
end

function boot_set_match_started(value)
	bctx.engine.MP.LOBBY.started = value == true
end

function boot_shutdown(reason)
	instance.shutdown(reason)
end

function encode_empty_with(path)
	local ok, mod = pcall(dofile, path)
	if not ok or type(mod) ~= 'table' or type(mod.encode) ~= 'function' then
		return 'load_failed'
	end
	local ok2, text = pcall(mod.encode, {})
	if not ok2 then
		return 'encode_failed'
	end
	return text
end
"""


def _coordinate(module, tmp: Path, mode: str, gauntlet, run_seed: str, expect_seed: str):
    """Drive two real bootstrap coordinators against one attested real service."""
    runner = DeterministicRunner()
    config = ps.ServiceConfig(
        session_id=SESSION,
        difficulty="competitive",
        pacing="normal",
        mode=mode,
        match_port=8788,
        log_root=tmp / "logs",
        content_hash=CONTENT,
        expected_config_digest=CONFIG_DIGEST,
        gauntlet=gauntlet,
        ruleset_id=RULESET_ID,
        gamemode=GAMEMODE,
        forced_options=dict(FORCED_OPTIONS),
    )
    service = ps.PracticeService(
        config,
        human_credential=HUMAN_CRED,
        ai_credential=AI_CRED,
        worker_runner=runner,
    )
    service.mark_attested(CONFIG_DIGEST)

    def service_request(text):
        message = json.loads(text)
        response = service.handle_request(message)
        return json.dumps(response)

    def make(role):
        lua = module.LuaRuntime(unpack_returned_tuples=True)
        g = lua.globals()
        g.ROOT = REPO.as_posix()
        g.ROLE = role
        g.SESSION = SESSION
        g.CRED = HUMAN_CRED if role == "human" else AI_CRED
        g.NONCE = "nonce-" + role
        g.CONTENT = CONTENT
        g.MODE = mode
        # The already-resolved run seed of the initialized run. Normal match is
        # an engine-generated seed, distinct from any gauntlet seed; gauntlet
        # must agree with the human-only SETUP seed.
        g.RUN_SEED = run_seed
        g.WIRE_JSON_PATH = WIRE_JSON.as_posix() if WIRE_JSON.is_file() else ""
        g.SMODS_JSON_PATH = SMODS_JSON.as_posix() if SMODS_JSON.is_file() else ""
        g.service_request = service_request
        lua.execute(TWO_BOOTSTRAP_SOURCE)
        return lua

    human = make("human")
    ai = make("ai")

    # Start disconnected: no lobby/decision op may leave before the real MP
    # socket is connected, and the boot is a bounded wait, not an error.
    human.globals().boot_set_connected(False)
    ai.globals().boot_set_connected(False)
    assert human.globals().boot_install()[0] is True
    assert ai.globals().boot_install()[0] is True
    for _ in range(4):
        human.globals().boot_step(1.0)
        ai.globals().boot_step(1.0)
    hd = human.globals().boot_describe()
    assert hd["state"] != "stopped", f"disconnected boot stopped: {hd}"
    assert human.globals().boot_op_count("lobby_code") == 0, "lobby reported before connect"
    assert ai.globals().boot_op_count("join_code") == 0, "join polled before connect"

    human.globals().boot_set_connected(True)
    ai.globals().boot_set_connected(True)

    for _ in range(2000):
        human.globals().boot_step(1.0)
        ai.globals().boot_step(1.0)
        # Relay the guest's ready state to the host through the normal server
        # message path (the runtimes do not share engine memory).
        if ai.globals().boot_ready_to_start():
            human.globals().boot_set_ready_to_start(True)
        # Once the host has really started the match, the ordinary server relays
        # the start to the guest; only then may its loop run.
        if human.globals().boot_engine_started():
            ai.globals().boot_set_match_started(True)
        hd = human.globals().boot_describe()
        ad = ai.globals().boot_describe()
        if hd["coordinated"] and ad["coordinated"]:
            break

    hd = human.globals().boot_describe()
    ad = ai.globals().boot_describe()
    assert hd["coordinated"] and ad["coordinated"], f"never coordinated: human={hd} ai={ad}"
    assert hd["last_error"] is None, f"human boot error: {hd}"
    assert ad["last_error"] is None, f"ai boot error: {ad}"
    assert hd["state"] != "stopped" and ad["state"] != "stopped"

    # Two authenticated HELLOs; the host reports the seed exactly once and the
    # guest never does. The real service logger records the resolved seed.
    assert human.globals().boot_op_count("hello") == 1
    assert ai.globals().boot_op_count("hello") == 1
    assert human.globals().boot_op_count("status") == 1, "seed reported exactly once"
    assert ai.globals().boot_op_count("status") == 0, "guest reported a seed"
    assert human.globals().boot_reported_seed() == expect_seed
    assert service._logger.seed == expect_seed
    # The guest joined the exact code the host's real lobby produced.
    assert ai.globals().boot_lobby_code() == "ABC12"
    # No seed ever reaches the policy worker export.
    for request in runner.requests:
        observation = request.get("observation", {})
        assert "seed" not in observation, observation
        assert "pseudorandom" not in observation, observation

    # Terminal: the human END is authoritative; the AI END is a receipt and must
    # not authorize teardown. Local win/loss and lives are role-aware.
    human.globals().boot_set_terminal("win")
    ai.globals().boot_set_terminal("loss")
    for _ in range(40):
        human.globals().boot_step(1.0)
        ai.globals().boot_step(1.0)
        terminal = service.terminal_summary()
        if terminal["human_end_received"] and terminal["ai_end_received"]:
            break
    terminal = service.terminal_summary()
    assert terminal["human_end_received"] is True, terminal
    assert terminal["ai_end_received"] is True, terminal
    summary = terminal["summary"]
    # Human local win -> human_win; human local lives -> human_lives.
    assert summary["result"] == "human_win", summary
    assert summary["human_lives"] == 4 and summary["ai_lives"] == 2, summary
    assert service.ended is True

    human.globals().boot_shutdown("test")
    ai.globals().boot_shutdown("test")


def run_two_bootstrap(display: str, module_name: str) -> None:
    """Two real bootstrap coordinators (human + AI) through the real service.

    Not hand-emitted transport frames: each Lua runtime builds the real
    multi-module bootstrap (adapter/executor/broker/loop/driver), drives its own
    typed coordination state machine over the real control transport JSON, and
    the real PracticeService answers every wire frame. The engines are
    source-shaped stubs (real ruleset registry, real ready toggle, real guest
    join config, late UI/connect) and the service gate is attested. Both a
    gauntlet (SETUP seed agreement) and a normal match (engine-resolved seed) are
    driven.
    """
    module = importlib.import_module(module_name)
    with tempfile.TemporaryDirectory() as tmp:
        _coordinate(module, Path(tmp), "gauntlet", "Test3", "AISP0003", "AISP0003")
        _coordinate(module, Path(tmp), "normal", None, "NORMALRUN7", "NORMALRUN7")


def run_wire_json_report(display: str, module_name: str) -> None:
    """Report the empty-object JSON mismatch root without changing the wire."""

    module = importlib.import_module(module_name)
    lua = module.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = REPO.as_posix()
    lua.globals().SMODS_JSON_PATH = SMODS_JSON.as_posix()
    lua.globals().WIRE_JSON_PATH = WIRE_JSON.as_posix() if WIRE_JSON.is_file() else ""
    lua.execute(TWO_BOOTSTRAP_SOURCE_FOR_PROBE)
    smods = lua.globals().probe_smods(lua.globals().SMODS_JSON_PATH)
    # The pinned rxi/SMODS json encodes an empty table as an array, which the
    # strict six-key envelope/service cannot accept for `{}` payloads: this is
    # the mismatch root the companion wire module exists to fix.
    assert smods == "[]", f"unexpected pinned smods json empty-object encoding: {smods}"
    assert lua.globals().fixture_empty() == "{}", "fixture json hides the empty-object bug"
    text = lua.globals().probe_wire(
        lua.globals().WIRE_JSON_PATH, lua.globals().SMODS_JSON_PATH
    )
    assert '"observation":{}' in text, f"wire must force empty objects: {text}"
    assert '"observation":[]' not in text


TWO_BOOTSTRAP_SOURCE_FOR_PROBE = r"""
local support = dofile(ROOT .. '/tests/runtime/support.lua')
local json = support.json(ROOT)
function probe_smods(path)
	local ok, mod = pcall(dofile, path)
	if not ok or type(mod) ~= 'table' or type(mod.encode) ~= 'function' then
		return 'load_failed'
	end
	local ok2, text = pcall(mod.encode, {})
	if not ok2 then
		return 'encode_failed'
	end
	return text
end
function probe_wire(wire_path, base_path)
	if wire_path == '' or base_path == '' then
		return 'no_wire_module'
	end
	local ok_base, base = pcall(dofile, base_path)
	local ok_wire, WireJson = pcall(dofile, wire_path)
	if not ok_base or not ok_wire or type(base) ~= 'table' or type(WireJson) ~= 'table' then
		return 'load_failed'
	end
	local wire = WireJson.factory(base)
	if type(wire) ~= 'table' then
		return 'factory_failed'
	end
	local text, code = wire.encode_service({
		session = 'sess', credential = 'cred', role = 'ai', op = 'status', sequence = 1, observation = {},
	})
	if type(text) ~= 'string' then
		return 'encode_failed:' .. tostring(code)
	end
	return text
end
function fixture_empty()
	return json.encode({})
end
"""


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Cross-service runtime contract")
    parser.add_argument("--require-all", action="store_true",
                        help="fail when any requested lupa runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring cross-service runtime contract")
    failures = 0
    available = 0
    for display, module_name in (("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")):
        try:
            importlib.import_module(module_name)
        except Exception as exc:  # noqa: BLE001
            print(f"runtime {display}: SKIPPED ({exc})")
            if args.require_all:
                failures += 1
            continue
        available += 1
        for label, runner in (
            ("wire_transport_drives_practice_service", run_runtime),
            ("two_bootstrap_coordinators_reach_start", run_two_bootstrap),
            ("empty_object_encoding_root", run_wire_json_report),
        ):
            try:
                runner(display, module_name)
            except Exception as exc:  # noqa: BLE001
                failures += 1
                print(f"FAIL {display}::{label}: {type(exc).__name__}: {exc}")
            else:
                print(f"PASS {display}::{label}")

    if available == 0:
        print("No lupa runtimes available.", file=sys.stderr)
        return 1
    if failures:
        print(f"RESULT: FAIL ({failures} failing executions)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
