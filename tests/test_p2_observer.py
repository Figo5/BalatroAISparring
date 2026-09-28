#!/usr/bin/env python3
"""P2 network-thread source-observer tests (synthetic; no game, no network).

The real generated ``staging.mp_p2_observer_patches`` are applied to the pinned
Multiplayer ``networking/socket.lua`` source; the returned network-thread long
string is extracted and executed under lupa's Lua 5.1 and LuaJIT 2.1 runtimes with
bounded fake LÖVE filesystem/thread and LuaSocket dependencies. This proves:

* the observer artifact is written only *after* a real connect attempt returns;
* the emitted schema carries the actual return/error, endpoint and an observed
  wall-clock timestamp (``socket.gettime``; not a monotonic guarantee);
* with the env gate off the patched thread is inert: its whole
  connect/timeout/sleep/send/channel-event trace equals the unpatched source;
* a dead-port initial failure never claims reconnect/keepalive coverage;
* the real ``tryReconnect`` bounded cycle (2/4/8-second delays) is observed;
* the real keepalive-expiry branch is observed by driving the original timer loop
  with bounded fake time, recording ``keepalive_failures`` only when it executes.

No Balatro process, live file, Mods tree or socket is touched.
"""
from __future__ import annotations

import importlib
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
for path in (str(TOOLS), str(REPO)):
    if path not in sys.path:
        sys.path.insert(0, path)

import isolation_certificate as ic  # noqa: E402
import staging  # noqa: E402

RUNTIMES = (("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21"))
PORT = 39123

# The observed launch thread must reach the keepalive-expiry branch, which the
# pinned source only hits after the 20 s initial timer plus five 5 s retry timers
# (the dead-port path never gets there). Fake time advances only through the
# original ``socket.sleep`` calls, so that window costs thousands of bounded
# iterations; the bound is therefore case-specific.
KEEPALIVE_SLEEP_LIMIT = 2000
SHORT_SLEEP_LIMIT = 64
TRACE_SLEEP_LIMIT = 30

PREAMBLE = r"""
AISP_ENV = {}
AISP_WRITES = {}
AISP_ORDER = {}
AISP_TRACE = {}
AISP_CONNECT_CALLS = 0
AISP_CLOSE_CALLS = 0
AISP_SEND_CALLS = 0
AISP_SLEEPS = 0
AISP_SLEEP_LIMIT = 24
AISP_CLOCK = 100.0
AISP_CAUSAL = false
AISP_LAST_ATTEMPTS = 0
AISP_CONNECT_RESULTS = {}
AISP_CONNECT_ERRORS = {}
AISP_RECV_RESULTS = {}
AISP_RECV_ERRORS = {}

os.getenv = function(key) return AISP_ENV[key] end

-- Observed wall-clock source for the fake environment. The real observer only
-- records a value here; it never assumes the clock is monotonic.
os.time = function(t) return math.floor(AISP_CLOCK) end

AISP_CHANNELS = {}
local function channel(name)
  if not AISP_CHANNELS[name] then AISP_CHANNELS[name] = { queue = {}, pushed = {} } end
  local c = AISP_CHANNELS[name]
  return {
    push = function(self, msg)
      table.insert(c.pushed, msg)
      AISP_TRACE[#AISP_TRACE + 1] = 'push:' .. name .. ':' .. tostring(msg)
    end,
    pop = function(self)
      local msg = table.remove(c.queue, 1)
      AISP_TRACE[#AISP_TRACE + 1] = 'pop:' .. name .. ':' .. tostring(msg)
      return msg
    end,
  }
end

json = { encode = function(t) return '{}' end }

-- Queued outcomes are stored as explicit { present, value } entries so a
-- multi-attempt scenario never depends on sparse nil arrays.
local function take(list)
  local entry = table.remove(list, 1)
  if entry == nil or entry.present ~= true then return nil end
  return entry.value
end

local function new_client()
  local   c = {}
  c.settimeout = function(self, value) AISP_TRACE[#AISP_TRACE + 1] = 'settimeout:' .. tostring(value) end
  c.setoption = function(self, key, value) AISP_TRACE[#AISP_TRACE + 1] = 'setoption:' .. tostring(key) end
  c.connect = function(self, url, port)
    AISP_CONNECT_CALLS = AISP_CONNECT_CALLS + 1
    -- With the observer active, the latest emitted artifact must already account
    -- for every *completed* connect. Other event checkpoints (a keepalive flush
    -- before a reconnect) are allowed, so this is a causal assertion, not a
    -- write-count identity. It is skipped when no artifact is emitted at all.
    if AISP_CAUSAL then
      assert(AISP_LAST_ATTEMPTS == AISP_CONNECT_CALLS - 1, 'connect_attempts lagged completed attempts')
    end
    AISP_ORDER[#AISP_ORDER + 1] = 'connect:' .. AISP_CONNECT_CALLS
    AISP_TRACE[#AISP_TRACE + 1] = 'connect:' .. AISP_CONNECT_CALLS
    local r = take(AISP_CONNECT_RESULTS)
    local e = take(AISP_CONNECT_ERRORS)
    return r, e
  end
  c.send = function(self, msg)
    AISP_SEND_CALLS = AISP_SEND_CALLS + 1
    AISP_TRACE[#AISP_TRACE + 1] = 'send:' .. tostring(msg)
  end
  c.receive = function(self)
    AISP_TRACE[#AISP_TRACE + 1] = 'recv'
    local r = take(AISP_RECV_RESULTS)
    local e = take(AISP_RECV_ERRORS)
    return r, e, nil
  end
  c.close = function(self)
    AISP_CLOSE_CALLS = AISP_CLOSE_CALLS + 1
    AISP_TRACE[#AISP_TRACE + 1] = 'close'
  end
  return c
end

local socket = {
  tcp = function() return new_client() end,
  sleep = function(seconds)
    AISP_SLEEPS = AISP_SLEEPS + 1
    AISP_TRACE[#AISP_TRACE + 1] = 'sleep:' .. tostring(seconds)
    AISP_CLOCK = AISP_CLOCK + (tonumber(seconds) or 0)
    if AISP_SLEEPS > AISP_SLEEP_LIMIT then error('AISP_BOUND', 0) end
  end,
  gettime = function() AISP_CLOCK = AISP_CLOCK + 0.001; return AISP_CLOCK end,
}

love = {
  filesystem = {
    getSaveDirectory = function() return 'C:/staged/save' end,
    getInfo = function(name) return nil end,
    write = function(name, data)
      AISP_WRITES[#AISP_WRITES + 1] = { name = name, data = data }
      AISP_ORDER[#AISP_ORDER + 1] = 'write'
      AISP_TRACE[#AISP_TRACE + 1] = 'write:' .. name
      local n = string.match(data, 'connect_attempts=(%d+)')
      if n then AISP_LAST_ATTEMPTS = tonumber(n) end
    end,
  },
  thread = { getChannel = function(name) return channel(name) end },
  event = { quit = function() end },
}

function require(name)
  if name == 'socket' then return socket end
  if name == 'json' then return json end
  return {}
end
"""


def _extract_thread(text: str) -> str:
    match = re.search(r"return \[\[(.*)\]\]\s*$", text, re.S)
    assert match is not None, "socket.lua must return the thread long string"
    return match.group(1)


def _raw_thread_text() -> str:
    if not staging.REFERENCE_MP_SOCKET.is_file():
        raise FileNotFoundError(str(staging.REFERENCE_MP_SOCKET))
    return _extract_thread(staging.REFERENCE_MP_SOCKET.read_text(encoding="utf-8"))


def _thread_text() -> str:
    if not staging.REFERENCE_MP_SOCKET.is_file():
        raise FileNotFoundError(str(staging.REFERENCE_MP_SOCKET))
    source = staging.REFERENCE_MP_SOCKET.read_text(encoding="utf-8")
    patched = source
    for patch in staging.mp_p2_observer_patches(PORT):
        assert patch["pattern"] in source, patch["pattern"]
        patched = staging.apply_source_pattern_patch(patched, patch)
    return _extract_thread(patched)


def _encoded(lua, values):
    table = lua.table()
    for index, value in enumerate(values, start=1):
        entry = lua.table()
        entry["present"] = value is not None
        if value is not None:
            entry["value"] = value
        table[index] = entry
    return table


def _lua_list(table) -> list:
    return [table[index] for index in range(1, len(table) + 1)]


def _run(runtime, body, *, env, connects, errors, recvs=None, recv_errors=None,
         sleep_limit=SHORT_SLEEP_LIMIT):
    lua = importlib.import_module(runtime).LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PREAMBLE)
    lua.globals().AISP_SLEEP_LIMIT = sleep_limit
    for key, value in (env or {}).items():
        lua.globals().AISP_ENV[key] = value
    lua.globals().AISP_CAUSAL = (env or {}).get("AISP_MEASURE_P2") == "1"
    lua.globals().AISP_CONNECT_RESULTS = _encoded(lua, connects or [])
    lua.globals().AISP_CONNECT_ERRORS = _encoded(lua, errors or [])
    lua.globals().AISP_RECV_RESULTS = _encoded(lua, recvs if recvs is not None else [None])
    lua.globals().AISP_RECV_ERRORS = _encoded(lua, recv_errors if recv_errors is not None else [None])
    lua.execute(
        'AISP_CHANNELS["uiToNetwork"] = '
        '{ queue = { [[{"action":"connect"}]] }, pushed = {} }'
    )
    thread = lua.execute("return function(...)\n" + body + "\nend")
    bound = False
    try:
        thread("127.0.0.1", PORT)
    except Exception as exc:  # noqa: BLE001
        if "AISP_BOUND" in str(exc):
            bound = True
        else:
            raise
    assert bound, "the bounded fake socket.sleep must stop the thread loop"
    writes = []
    table = lua.globals().AISP_WRITES
    for index in range(1, len(table) + 1):
        row = table[index]
        writes.append({"name": str(row["name"]), "data": str(row["data"])})
    order_table = lua.globals().AISP_ORDER
    trace_table = lua.globals().AISP_TRACE
    trace = [str(value) for value in _lua_list(trace_table)]
    sleeps = [float(entry.split(":", 1)[1]) for entry in trace if entry.startswith("sleep:")]
    return {
        "writes": writes,
        "connect_calls": int(lua.globals().AISP_CONNECT_CALLS),
        "close_calls": int(lua.globals().AISP_CLOSE_CALLS),
        "send_calls": int(lua.globals().AISP_SEND_CALLS),
        "sleeps": sleeps,
        "order": [str(order_table[index]) for index in range(1, len(order_table) + 1)],
        "trace": trace,
        "keepalive_pushes": sum(
            1 for entry in trace if entry.startswith("push:uiToNetwork:") and "keepAlive" in entry
        ),
    }


def _fields(data: str) -> dict:
    return staging.parse_probe(data)


def _assert_common(fields):
    assert fields["probe"] == "p2"
    assert fields["schema"] == staging.P2_OBSERVER_SCHEMA
    assert fields["patch"] == staging.PATCH_ID
    assert fields["url"] == "127.0.0.1"
    assert fields["port"] == str(PORT)


def test_observer_artifact_only_after_real_connect_result():
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_observer_artifact_only_after_real_connect_result: pinned Multiplayer source unavailable')
        return
    body = _thread_text()
    for display, runtime in RUNTIMES:
        result = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": "p2-observer-nonce"},
            connects=[None], errors=["connection refused"],
        )
        assert result["connect_calls"] == 1, (display, result["connect_calls"])
        assert len(result["writes"]) == 1, (display, result["writes"])
        assert result["writes"][0]["name"] == staging.PROBE_P2
        fields = _fields(result["writes"][0]["data"])
        _assert_common(fields)
        assert fields["nonce"] == "p2-observer-nonce"
        assert fields["connect_attempts"] == "1"
        assert fields["connect_failures"] == "1"
        assert fields["first_result"] == "none"
        assert fields["first_error"] == "connection refused"
        # An observed wall-clock timestamp; no monotonic guarantee is claimed.
        assert float(fields["first_time"]) > 0
        assert fields["reconnects"] == "0"
        assert fields["reconnect_failures"] == "0"
        assert fields["keepalive_failures"] == "0"
        # Every artifact write follows the connect return that produced it.
        assert result["order"] == ["connect:1", "write"], (display, result["order"])
        print(f"ok   {display} observer writes only after the real connect result")


def test_observer_env_gate_off_is_inert_and_networking_unaffected():
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_observer_env_gate_off_is_inert_and_networking_unaffected: pinned Multiplayer source unavailable')
        return
    patched = _thread_text()
    raw = _raw_thread_text()
    # N5: gate-off equivalence is checked for all three real scenarios (close-error
    # reconnect, dead-port initial failure, keepalive expiry), not just one.
    scenarios = {
        "close_error": dict(
            connects=[1, None, None, None],
            errors=[None, "connection refused", "connection refused", "connection refused"],
            recvs=[None], recv_errors=["close"], sleep_limit=TRACE_SLEEP_LIMIT,
        ),
        "dead_port": dict(
            connects=[None], errors=["connection refused"],
            recvs=[None], recv_errors=[None], sleep_limit=TRACE_SLEEP_LIMIT,
        ),
        "keepalive": dict(
            connects=[1, None, None, None],
            errors=[None, "connection refused", "connection refused", "connection refused"],
            recvs=[None], recv_errors=[None], sleep_limit=KEEPALIVE_SLEEP_LIMIT,
        ),
    }
    for display, runtime in RUNTIMES:
        for label, scenario in scenarios.items():
            off = _run(runtime, patched, env={"AISP_PROBE_NONCE": "off-nonce"}, **scenario)
            plain = _run(runtime, raw, env={"AISP_PROBE_NONCE": "off-nonce"}, **scenario)
            assert off["writes"] == [], (display, label, off["writes"])
            # The patched thread with the gate off must be indistinguishable from the
            # unpatched source across connects, receives, sleeps, sends and channel events.
            assert off["trace"] == plain["trace"], (display, label)
            assert off["sleeps"] == plain["sleeps"], (display, label)
            assert off["close_calls"] == plain["close_calls"], (display, label)
            assert off["connect_calls"] == plain["connect_calls"], (display, label)
    print("ok   both runtimes: gate off is inert across close/dead-port/keepalive traces")


def test_observer_closed_error_never_uses_the_close_branch_and_falls_back_to_keepalive():
    """N5: branch-reachability check. LuaSocket's peer-close result is ``closed``,
    not ``close``, so the pinned ``error == "close"`` branch does not run; the
    keepalive path takes over and the classifier labels it ``keepalive_fallback``."""
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_observer_closed_error_never_uses_the_close_branch_and_falls_back_to_keepalive: pinned Multiplayer source unavailable')
        return
    body = _thread_text()
    for display, runtime in RUNTIMES:
        result = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": "closed-nonce"},
            connects=[1, None, None, None],
            errors=[None, "connection refused", "connection refused", "connection refused"],
            recvs=[None], recv_errors=["closed"],
            sleep_limit=KEEPALIVE_SLEEP_LIMIT,
        )
        fields = _fields(result["writes"][-1]["data"])
        # The literal close branch never fires for a "closed" receive error.
        assert fields["closes"] == "0", (display, fields)
        assert fields["keepalive_failures"] == "1", (display, fields)
        assert fields["cycle1_cause"] == "keepalive", (display, fields)
        assert fields["cycle1_outcome"] == "exhausted", (display, fields)
        # The classifier must label this a keepalive fallback, never close_branch.
        derived = ic._p2_derive(fields, PORT)
        listener = ic._listener_view({
            "accepted": "1", "peer_is_owned_ai": "true", "sent_bytes": "0",
            "closed": "true", "fin": "true", "close_time": "100.0",
        })
        coverage = ic._p2_phase_coverage("P2_CLOSE", derived, listener)
        assert "closure" in coverage["covered"], (display, coverage)
        assert coverage["closure_path"] == "keepalive_fallback", (display, coverage)
    print("ok   both runtimes: closed receive error uses the keepalive fallback path")


def test_observer_observes_real_reconnect_branch():
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_observer_observes_real_reconnect_branch: pinned Multiplayer source unavailable')
        return
    body = _thread_text()
    for display, runtime in RUNTIMES:
        result = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": "reconnect-nonce"},
            connects=[1, None, None, None],
            errors=[None, "connection refused", "connection refused", "connection refused"],
            recvs=[None], recv_errors=["close"],
        )
        assert result["connect_calls"] == 4, (display, result["connect_calls"])
        assert result["writes"], display
        fields = _fields(result["writes"][-1]["data"])
        _assert_common(fields)
        assert fields["connect_attempts"] == "4"
        assert fields["connect_failures"] == "3"
        assert fields["first_result"] == "1"
        assert fields["closes"] == "1"
        assert fields["reconnect_attempts"] == "3"
        assert fields["reconnect_failures"] == "3"
        assert fields["reconnects"] == "1"
        assert fields["keepalive_failures"] == "0"
        # The original exponential backoff came from the pinned source itself.
        assert [value for value in result["sleeps"] if value in (2.0, 4.0, 8.0)] == [2.0, 4.0, 8.0], display
        assert any(
            entry.startswith("push:networkToUi:") and "reconnecting" in entry
            for entry in result["trace"]
        ), display
        print(f"ok   {display} reconnect branch is observed from the real branch")


def test_observer_observes_real_keepalive_expiry_branch():
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_observer_observes_real_keepalive_expiry_branch: pinned Multiplayer source unavailable')
        return
    body = _thread_text()
    for display, runtime in RUNTIMES:
        result = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": "keepalive-nonce"},
            connects=[1, None, None, None],
            errors=[None, "connection refused", "connection refused", "connection refused"],
            recvs=[None], recv_errors=[None],
            sleep_limit=KEEPALIVE_SLEEP_LIMIT,
        )
        fields = _fields(result["writes"][-1]["data"])
        _assert_common(fields)
        assert fields["first_result"] == "1"
        assert fields["connect_attempts"] == "4"
        assert fields["connect_failures"] == "3"
        # Recorded only because the real keepalive-failure branch executed; the
        # retry counts come from the pinned source's own bounded loop.
        assert fields["keepalive_failures"] == "1"
        assert fields["reconnects"] == "1"
        assert fields["reconnect_attempts"] == "3"
        assert fields["reconnect_failures"] == "3"
        assert fields["closes"] == "0"
        assert result["close_calls"] == 1, display
        # keepAliveRetryCount = 4 in the source: five keepAlive pushes then the close.
        assert result["keepalive_pushes"] == 5, (display, result["keepalive_pushes"])
        assert [value for value in result["sleeps"] if value in (2.0, 4.0, 8.0)] == [2.0, 4.0, 8.0], display
        seen = [int(_fields(write["data"])["keepalive_failures"]) for write in result["writes"]]
        first = next(index for index, value in enumerate(seen) if value >= 1)
        assert all(value == 0 for value in seen[:first]), (display, seen)
        assert seen[-1] == 1, (display, seen)
        print(f"ok   {display} keepalive expiry branch is driven through the original timer loop")


def _classify(data: str, nonce: str, port: int) -> dict:
    record = {
        "nonce": nonce,
        "measurement_setup": {
            "kind": "dead_port",
            "dead_port": port,
            "refused": True,
            "listener_absent": {"ipv4": True, "ipv6": True},
            "attempts": 1,
            "timings": [0.001],
        },
    }
    with tempfile.TemporaryDirectory() as folder:
        paths = staging.role_paths(Path(folder), "ai")
        artifact = paths.data / "Balatro" / staging.PROBE_P2
        artifact.parent.mkdir(parents=True)
        artifact.write_text(data, encoding="utf-8")
        from types import SimpleNamespace

        return ic._measure_p2(Path(folder), record, SimpleNamespace(owned=[]), port)


def test_classifier_binds_coverage_to_emitted_fields():
    if not staging.REFERENCE_MP_SOCKET.is_file():
        print('skip test_classifier_binds_coverage_to_emitted_fields: pinned Multiplayer source unavailable')
        return
    body = _thread_text()
    for display, runtime in RUNTIMES:
        nonce = "classify-nonce"
        failed = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": nonce},
            connects=[None], errors=["connection refused"],
        )
        # Classify the artifact exactly as the observer emitted it: no field may be
        # rewritten to fake an initial failure.
        initial = _fields(failed["writes"][-1]["data"])
        assert initial["first_result"] == "none", (display, initial)
        measured = _classify(failed["writes"][-1]["data"], nonce, PORT)
        assert "initial_failure" in measured["covered_subgates"], (display, measured)
        assert "reconnect" in measured["pending_subgates"], (display, measured)
        assert "keepalive" in measured["pending_subgates"], (display, measured)
        assert measured["keepalive_failures"] == 0, (display, measured)

        reconnected = _run(
            runtime, body,
            env={"AISP_MEASURE_P2": "1", "AISP_PROBE_NONCE": nonce},
            connects=[1, None, None, None],
            errors=[None, "refused", "refused", "refused"],
            recvs=[None], recv_errors=["close"],
        )
        # A first success followed by failed reconnects must leave the initial
        # failure pending while the completed reconnect cycle is covered.
        actual = _fields(reconnected["writes"][-1]["data"])
        assert actual["first_result"] == "1", (display, actual)
        assert actual["connect_attempts"] == "4", (display, actual)
        measured = _classify(reconnected["writes"][-1]["data"], nonce, PORT)
        assert "initial_failure" in measured["pending_subgates"], (display, measured)
        assert "reconnect" in measured["covered_subgates"], (display, measured)
        assert "keepalive" in measured["pending_subgates"], (display, measured)
        print(f"ok   {display} classifier maps coverage to the exact observer fields")


def main() -> int:
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
    print(f"\n{len(tests) - failures}/{len(tests)} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
