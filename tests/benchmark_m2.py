#!/usr/bin/env python3
"""Fixture benchmark for AISparring/ai (Milestone 2).

Measures typical SHOP and PLAY observation builds, action enumeration, canonical
byte size and approximate held Lua allocation under both lupa runtimes. This is
a synthetic micro-benchmark of project-owned modules only: no game, Mods,
network, runtime capture, strategy, search or evaluation is involved.

Run directly or via `python tests/run_m2.py --benchmark`.
"""
from __future__ import annotations

import argparse
import importlib
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUNTIMES = [("lua51", "lupa.lua51"), ("luajit21", "lupa.luajit21")]

BATCHES = 7
ITERATIONS = 150
HELD = 200

BENCH_LUA = r'''
return function(repo, batches, iters, held)
	local Framework = assert(loadfile(repo .. "/tests/m2/framework.lua"))()
	local m = Framework.load_ai(repo)
	local obs = m.Observation.factory(m.Codec)
	local acts = m.Actions.factory(obs, m.Codec)

	local function shop_frame()
		local f = Framework.syn("SHOP")
		f.self.money = 12
		f.shop = {
			reroll_cost = 3,
			items = {
				Framework.entity({ kind = "card", center = "c_1", cost = 2 }),
				Framework.entity({ kind = "joker", center = "j_1", cost = 4 }),
			},
			vouchers = { Framework.entity({ center = "v_1", cost = 5 }) },
			boosters = { Framework.entity({ kind = "booster", center = "b_1", cost = 3 }) },
		}
		f.certificates.items = {
			Framework.cert("BUY_ITEM", { item_ref = "shop:1" }),
			Framework.cert("BUY_ITEM", { item_ref = "shop:2", capacity_ok = true }),
			Framework.cert("OPEN_BOOSTER", { item_ref = "shop_booster:1" }),
			Framework.cert("BUY_VOUCHER", { voucher_ref = "shop_voucher:1" }),
			Framework.cert("REROLL"),
			Framework.cert("LEAVE_SHOP"),
		}
		return f
	end

	local function play_frame()
		local f = Framework.syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = {
			Framework.entity({ rank = "A", suit = "Spades" }),
			Framework.entity({ rank = "K", suit = "Hearts" }),
			Framework.entity({ rank = "Q", suit = "Clubs" }),
		}
		f.certificates.items = {
			Framework.cert("PLAY_CARDS", { card_refs = { "hand:1", "hand:2", "hand:3" } }),
			Framework.cert("DISCARD_CARDS", { card_refs = { "hand:2" } }),
			Framework.cert("REORDER_HAND", { order = { "hand:3", "hand:1", "hand:2" } }),
		}
		return f
	end

	local function measure(frame_fn)
		local observe = {}
		local generate = {}
		for b = 1, batches do
			local t0 = os.clock()
			for i = 1, iters do
				obs.observe(frame_fn())
			end
			observe[b] = os.clock() - t0
			local handle = obs.observe(frame_fn())
			local t1 = os.clock()
			for i = 1, iters do
				acts.generate(handle)
			end
			generate[b] = os.clock() - t1
		end
		local handle = obs.observe(frame_fn())
		return { observe = observe, generate = generate, canonical_bytes = #obs.canonical(handle) }
	end

	local shop = measure(shop_frame)
	local play = measure(play_frame)

	collectgarbage("collect")
	local before = collectgarbage("count")
	local holds = {}
	for i = 1, held do
		holds[i] = obs.observe(shop_frame())
	end
	local after = collectgarbage("count")
	local kb_per_observation = (after - before) / held

	return {
		batches = batches,
		iters = iters,
		held = held,
		shop = shop,
		play = play,
		kb_per_observation = kb_per_observation,
	}
end
'''


def load_runtime(module_name: str):
    try:
        module = importlib.import_module(module_name)
    except Exception as exc:  # noqa: BLE001
        return None, f"unavailable: {exc}"
    factory = getattr(module, "LuaRuntime", None)
    if factory is None:
        return None, "no LuaRuntime"
    return factory, None


def to_list(array) -> list[float]:
    return [float(value) for value in array.values()]


def run_runtime(factory, display: str) -> dict | None:
    lua = factory(unpack_returned_tuples=True)
    bench = lua.execute(BENCH_LUA)
    result = bench(REPO.as_posix(), BATCHES, ITERATIONS, HELD)
    rows = {}
    for scenario in ("shop", "play"):
        block = result[scenario]
        observe = to_list(block["observe"])
        generate = to_list(block["generate"])
        rows[scenario] = {
            "observe_us": statistics.median(observe) / ITERATIONS * 1e6,
            "generate_us": statistics.median(generate) / ITERATIONS * 1e6,
            "canonical_bytes": int(block["canonical_bytes"]),
        }
    kb = float(result["kb_per_observation"])
    return {"scenarios": rows, "kb_per_observation": kb}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="AISparring Milestone 2 fixture benchmark")
    parser.add_argument("--require-all", action="store_true", help="fail when a runtime is unavailable")
    args = parser.parse_args(argv)

    print("AISparring Milestone 2 fixture benchmark")
    print(f"batches={BATCHES} iterations_per_batch={ITERATIONS} held_observations={HELD}")

    ok = True
    available = 0
    for display, module_name in RUNTIMES:
        factory, error = load_runtime(module_name)
        if factory is None:
            print(f"runtime {display}: SKIPPED ({error})")
            if args.require_all:
                ok = False
            continue
        available += 1
        try:
            rows = run_runtime(factory, display)
        except Exception as exc:  # noqa: BLE001
            print(f"runtime {display}: ERROR ({exc})")
            ok = False
            continue
        for scenario in ("shop", "play"):
            data = rows["scenarios"][scenario]
            print(
                f"runtime {display} {scenario.upper()}: "
                f"observe median {data['observe_us']:.2f} us/op, "
                f"generate median {data['generate_us']:.2f} us/op, "
                f"canonical {data['canonical_bytes']} bytes"
            )
        print(f"runtime {display} allocation: ~{rows['kb_per_observation']:.3f} KB per held SHOP observation (approx)")

    if available == 0:
        print("no lupa runtimes available", file=sys.stderr)
        return 1

    print("caveats:")
    print("- synthetic fixtures only; not game performance and not a strategy/search measurement")
    print("- os.clock CPU time inside lupa; in-process interpreter overhead differs from the game runtime")
    print("- medians of per-batch totals divided by batch iterations; batches are not independent trials")
    print("- canonical bytes are for one representative fixture per scenario")
    print("- allocation uses collectgarbage('count') before/after retaining handles; approximate and GC-dependent")
    print("- lua51 and luajit21 are not directly comparable; rerun for stable numbers")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
