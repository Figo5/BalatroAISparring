"""Independent adapter -> canonical export -> OS worker -> executor checks.

Uses source-shaped engine fixtures, not a real Balatro run. Includes subprocess
startup in timings. No game process, live files or sockets are used.
"""
import importlib
import json
import sys
import time
from pathlib import Path

from run_policy import run_worker

ROOT = Path(__file__).resolve().parent.parent
SETUP = """
local support = dofile(ROOT .. '/tests/engine/support.lua')
local bundle = support.bundle(ROOT)
local json = dofile(ROOT .. '/work/reference/offline/smods-json.lua')
local hand = {
 support.card({rank='Ace',suit='Spades'}),
 support.card({rank='King',suit='Spades'}),
 support.card({rank='Queen',suit='Spades'}),
 support.card({rank='Jack',suit='Spades'}),
 support.card({rank='10',suit='Spades'}),
 support.card({rank='Ace',suit='Hearts'}),
 support.card({rank='Ace',suit='Diamonds'}),
 support.card({rank='5',suit='Clubs',facing='back',sprite_facing='back'}),
}
local engine = support.engine({hand=hand})
local pipe = support.pipeline(bundle,engine)
local handle = assert(pipe.executor.capture())
local actions = bundle.actions.generate(handle)
local policy = dofile(ROOT .. '/AISparring/ai/baseline_policy.lua')
local function validate(encoded)
 local action=json.decode(encoded)
 assert(bundle.actions.validate(handle,action), 'worker action is not legal')
 assert(pipe.executor.validate(action), 'actual executor rejects policy choice')
 return true
end
return json.encode(bundle.obs.export(handle)), #actions, policy.source, validate
"""


def main():
    vectors = {}
    failures = 0
    for runtime in ("lua51", "luajit21"):
        lua = importlib.import_module("lupa." + runtime).LuaRuntime(unpack_returned_tuples=True)
        lua.globals().ROOT = ROOT.as_posix()
        exported, count, source_for, validate = lua.execute(SETUP)
        observation = json.loads(exported)
        assert count >= 20, "fixture did not exercise a broad candidate catalogue"
        for difficulty in ("rookie", "competitive", "major_league", "expert"):
            source = source_for(difficulty)
            if isinstance(source, tuple):
                source = source[0]
            started = time.perf_counter()
            response, error = run_worker(runtime, source, observation)
            elapsed = time.perf_counter() - started
            try:
                assert response and response.get("ok") is True, (error, response)
                action = response["action"]
                assert validate(json.dumps(action))
                canonical = json.dumps(action, sort_keys=True)
                if difficulty in vectors:
                    assert vectors[difficulty] == canonical, "cross-runtime policy differs"
                vectors[difficulty] = canonical
            except Exception as exc:
                failures += 1
                print(f"FAIL {runtime}/{difficulty}: {exc}")
            else:
                print(f"PASS {runtime}/{difficulty}: {count} candidates, {elapsed:.3f}s including process startup, {action['type']}")
    print(f"6 cross-module worker checks; {failures} failures")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
