#!/usr/bin/env python3
"""Seeded mini-run simulator for the baseline policy (cloud-safe, no game).

A first run-level (Gauntlet-style) metric. A run is a sequence of antes, each
with a small, big and boss blind, and ends at the first failed blind or after
MAX_ANTE antes. The policy makes every decision through the real trusted
pipeline (engine fixture -> EngineAdapter -> StateReader -> AIObservation ->
sandboxed policy):

- **Blinds:** as in tests/benchmark_blinds.py (shuffled deck, real draws, boss
  debuff / Needle / Water effects), with the run's Jokers and hand levels.
- **Money:** $4 to start, then the blind reward ($3 / $4 / $5), $1 per unused
  hand and interest ($1 per $5, at most $5).
- **Shop:** after every cleared blind, two items (a Joker at $4-8 or a planet at
  $3), rerolls at $5 rising by $1, five Joker slots. Offers are seeded by run
  seed, ante, blind and reroll count, so every difficulty sees the same offers
  at the same shop position. A bought planet levels its hand at once (a
  simplification of using it). Selling returns half the price. Joker reorders
  are applied. Money cannot go below $0 (no Credit Card).
- **Validation:** an unaffordable buy or reroll, a full-slot Joker buy, a bad
  reorder, a policy no-action or an unexpected action type in a blind counts as
  a failure.

Every difficulty sees the same deck orders for the same run seed. Plays are scored with the reference scorer shared with the policy's
model, Lucky cards score their average and Glass never breaks, and there are
no packs, vouchers, tags, scaling Jokers or opponents. So this measures how
play, economy and Joker buying combine within that model. It is not a Balatro
win rate.

Usage: python tests/benchmark_runs.py [--runs N] [--seed S] [--runtime R] [--json PATH]
"""
from __future__ import annotations

import argparse
import importlib
import json
import random
import statistics
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import benchmark_blinds as bb  # noqa: E402
import benchmark_policy as bp  # noqa: E402

DIFFICULTIES = bp.DIFFICULTIES
MAX_ANTE = 6
ANTE_BASE = {1: 300, 2: 800, 3: 2000, 4: 5000, 5: 11000, 6: 20000}
REWARD = {"small": 3, "big": 4, "boss": 5}
JOKER_SLOTS = 5
SHOP_STEPS = 10
# Planets by the hand they level (reference names; engine names from LEVEL_UP).
PLANETS = {
    "c_pluto": "high_card", "c_mercury": "pair", "c_uranus": "two_pair", "c_venus": "three",
    "c_saturn": "straight", "c_jupiter": "flush", "c_earth": "full_house", "c_mars": "four",
}

DECIDE = r'''
return function(repo, policy_path)
	local support = dofile(repo .. "/tests/engine/support.lua")
	local bundle = support.bundle(repo)
	local function read_file(path)
		local handle = io.open(path, "rb")
		local content = handle:read("*a")
		handle:close()
		return content
	end
	local policy_env = dofile(repo .. "/tools/lua/policy_env.lua")
	assert(policy_env.configure(
		read_file(repo .. "/AISparring/ai/codec.lua"),
		read_file(repo .. "/AISparring/ai/observation.lua"),
		read_file(repo .. "/AISparring/ai/actions.lua")) == true)
	local baseline = dofile(policy_path or (repo .. "/AISparring/ai/baseline_policy.lua"))
	local sources = {}
	return function(state, difficulty)
		sources[difficulty] = sources[difficulty] or assert(baseline.source(difficulty))
		local jokers = {}
		for i = 1, #state.jokers do
			local j = state.jokers[i]
			jokers[i] = support.card({ center = j.center, center_set = "Joker", set = "Joker", area_type = "joker", sell_cost = j.sell })
		end
		local opts = {
			jokers = jokers, joker_slots = state.joker_slots, dollars = state.dollars, bankrupt_at = 0,
			ante = state.ante, round = state.round,
		}
		if state.phase == "shop" then
			opts.state = support.STATES.SHOP
			opts.reroll_cost = state.reroll_cost
			local items = {}
			for i = 1, #state.shop do
				local it = state.shop[i]
				if it.kind == "joker" then
					items[i] = support.card({ set = "Joker", center = it.center, cost = it.cost, center_set = "Joker", sell_cost = math.max(1, math.floor(it.cost / 2)) })
				else
					items[i] = support.card({ set = "Planet", consumeable = true, center = it.center, center_set = "Planet", cost = it.cost })
				end
			end
			opts.shop_jokers = items
		else
			local hand = {}
			for i = 1, #state.hand do
				local c = state.hand[i]
				hand[i] = support.card({
					rank = c.rank, suit = c.suit, center = c.center or "c_base",
					center_set = c.center and "Enhanced" or "Default", debuff = c.debuff,
				})
			end
			opts.state = support.STATES.SELECTING_HAND
			opts.hand = hand
			opts.hands_left = state.hands_left
			opts.discards_left = state.discards_left
			opts.chips = state.chips
			opts.blind_key = state.boss or "bl_small"
		end
		local engine = support.engine(opts)
		if state.phase ~= "shop" then
			engine.G.GAME.blind.chips = state.requirement
		end
		local hands = {}
		for name, entry in pairs(state.levels) do
			hands[entry.engine] = { level = entry.level, chips = entry.chips, mult = entry.mult, visible = true }
		end
		engine.G.GAME.hands = hands
		local step, code = support.pipeline(bundle, engine, {}).adapter.step()
		if step == nil then
			return { ok = false, code = tostring(code) }
		end
		local handle = bundle.reader.capture(step.runtime, step.ui_view)
		local export = bundle.obs.export(handle)
		local result = policy_env.run(sources[difficulty], export)
		local out = { ok = result.ok == true, code = result.code, instructions = policy_env.last_instructions() }
		if result.ok == true then
			out.type = result.action.type
			out.refs = result.action.card_refs
			out.item_ref = result.action.item_ref
			out.joker_ref = result.action.joker_ref
			out.order = result.action.order
		end
		return out
	end
end
'''

LUA = None


def level_up(levels, name):
    add_chips, add_mult, engine = bp.LEVEL_UP[name]
    base_chips, base_mult = bp.HAND_BASE[name]
    level = levels.get(name, {"level": 1})["level"] + 1
    levels[name] = {
        "level": level, "engine": engine,
        "chips": base_chips + add_chips * (level - 1),
        "mult": base_mult + add_mult * (level - 1),
    }


def ref_index(ref):
    return int(ref.split(":")[1]) - 1


def decide(fn, state, difficulty, stats):
    result = bp.from_lua(fn(bp.to_lua(LUA, state), difficulty))
    stats["decisions"] += 1
    stats["instructions"] = max(stats["instructions"], result.get("instructions") or 0)
    if not result.get("ok") and result.get("code") != "policy_no_action":
        stats["failures"] += 1
    return result


def play_blind(fn, run, blind, difficulty, stats):
    effect = bb.BOSSES.get(blind.get("boss"), {})
    target = effect.get("debuff")
    deck = []
    for card in blind["deck"]:
        card = dict(card)
        if target is not None and (card["suit"] == target or (target == "face" and card["rank"] in ("Jack", "Queen", "King"))):
            card["debuff"] = True
        deck.append(card)
    hand = [deck.pop(0) for _ in range(bb.HAND_SIZE)]
    chips, hands_left, discards_left = 0, effect.get("hands", bb.HANDS), effect.get("discards", bb.DISCARDS)
    levels = {name: {"chips": e["chips"], "mult": e["mult"]} for name, e in run["levels"].items()}
    for step in range(bb.MAX_STEPS + 1):
        if chips >= blind["requirement"] or hands_left == 0:
            break
        if step == bb.MAX_STEPS:
            stats["failures"] += 1
            break
        state = {
            "phase": "blind", "hand": hand, "jokers": run["jokers"], "joker_slots": JOKER_SLOTS,
            "dollars": run["money"], "ante": blind["ante"], "round": run["round"],
            "hands_left": hands_left, "discards_left": discards_left, "chips": chips,
            "requirement": blind["requirement"], "boss": blind.get("boss"), "levels": run["levels"],
        }
        result = decide(fn, state, difficulty, stats)
        if not result.get("ok") or result.get("type") not in ("PLAY_CARDS", "DISCARD_CARDS"):
            if result.get("ok") or result.get("code") == "policy_no_action":
                stats["failures"] += 1
            break
        idx = sorted({ref_index(r) for r in result["refs"]})
        chosen = [hand[i] for i in idx]
        rest = [hand[i] for i in range(len(hand)) if i not in idx]
        if result["type"] == "PLAY_CARDS":
            chips += int(bp.reference_score(chosen, rest, [j["center"] for j in run["jokers"]], levels))
            hands_left -= 1
        else:
            discards_left -= 1
        hand = rest
        while len(hand) < bb.HAND_SIZE and deck:
            hand.append(deck.pop(0))
    return chips >= blind["requirement"], hands_left


def shop_offer(rng):
    if rng.random() < 0.7:
        return {"kind": "joker", "center": rng.choice(bp.JOKER_KEYS), "cost": rng.randint(4, 8)}
    return {"kind": "planet", "center": rng.choice(sorted(PLANETS)), "cost": 3}


def shop_rng(seed, ante, blind, rerolls):
    # Offers depend only on the run seed and the shop position, so every
    # difficulty sees the same offers for the same shop and reroll count.
    return random.Random(((seed * 31 + ante) * 7 + blind) * 101 + rerolls)


def visit_shop(fn, run, ante, blind, difficulty, stats, seed):
    rerolls = 0
    rng = shop_rng(seed, ante, blind, rerolls)
    shop = [shop_offer(rng), shop_offer(rng)]
    reroll_cost = 5
    for _ in range(SHOP_STEPS):
        state = {
            "phase": "shop", "shop": shop, "jokers": run["jokers"], "joker_slots": JOKER_SLOTS,
            "dollars": run["money"], "ante": ante, "round": run["round"], "reroll_cost": reroll_cost,
            "levels": run["levels"],
        }
        result = decide(fn, state, difficulty, stats)
        kind = result.get("type")
        if not result.get("ok") or kind == "LEAVE_SHOP" or kind is None:
            return
        if kind == "BUY_ITEM":
            item = shop.pop(ref_index(result["item_ref"]))
            if item["cost"] > run["money"] or (item["kind"] == "joker" and len(run["jokers"]) >= JOKER_SLOTS):
                stats["failures"] += 1
                return
            run["money"] -= item["cost"]
            if item["kind"] == "joker":
                run["jokers"].append({"center": item["center"], "sell": max(1, item["cost"] // 2)})
                stats["jokers_bought"] += 1
            else:
                level_up(run["levels"], PLANETS[item["center"]])
                stats["planets_bought"] += 1
        elif kind == "REROLL":
            if reroll_cost > run["money"]:
                stats["failures"] += 1
                return
            run["money"] -= reroll_cost
            reroll_cost += 1
            rerolls += 1
            rng = shop_rng(seed, ante, blind, rerolls)
            shop = [shop_offer(rng), shop_offer(rng)]
            stats["rerolls"] += 1
        elif kind == "SELL_JOKER":
            sold = run["jokers"].pop(ref_index(result["joker_ref"]))
            run["money"] += sold["sell"]
        elif kind == "REORDER_JOKERS":
            order = [ref_index(r) for r in result["order"]]
            if sorted(order) != list(range(len(run["jokers"]))):
                stats["failures"] += 1
                return
            run["jokers"] = [run["jokers"][i] for i in order]
        else:
            return


def simulate_run(fn, seed, difficulty):
    rng = random.Random(seed)
    run = {"money": 4, "jokers": [], "levels": {}, "round": 1}
    stats = {"decisions": 0, "failures": 0, "instructions": 0, "jokers_bought": 0,
             "planets_bought": 0, "rerolls": 0, "blinds_cleared": 0, "ante_reached": 1}
    for ante in range(1, MAX_ANTE + 1):
        stats["ante_reached"] = ante
        for blind_index, kind in enumerate(("small", "big", "boss")):
            boss = rng.choice([k for k in bb.BOSS_KEYS if bb.BOSSES[k]["min_ante"] <= ante]) if kind == "boss" else None
            mult = bb.BOSSES[boss].get("req", bb.BLIND_MULT["boss"]) if boss else bb.BLIND_MULT[kind]
            deck = [{"rank": r, "suit": s} for r in bp.RANKS for s in bp.SUITS]
            rng.shuffle(deck)
            blind = {"ante": ante, "boss": boss, "requirement": int(ANTE_BASE[ante] * mult), "deck": deck}
            cleared, hands_left = play_blind(fn, run, blind, difficulty, stats)
            if not cleared:
                stats["money_end"] = run["money"]
                return stats
            stats["blinds_cleared"] += 1
            run["round"] += 1
            run["money"] += REWARD[kind] + hands_left + min(max(run["money"], 0) // 5, 5)
            visit_shop(fn, run, ante, blind_index, difficulty, stats, seed)
    stats["ante_reached"] = MAX_ANTE + 1
    stats["money_end"] = run["money"]
    return stats


def paired(args, fn, base_fn):
    """Blinds cleared per run, current minus base, on identical seeds."""
    report = {"runs": args.runs, "seed": args.seed, "base": str(args.paired), "difficulties": {}}
    failures = 0
    for difficulty in args.difficulty or DIFFICULTIES:
        base = [simulate_run(base_fn, args.seed * 1000 + i, difficulty) for i in range(args.runs)]
        new = [simulate_run(fn, args.seed * 1000 + i, difficulty) for i in range(args.runs)]
        failures += sum(r["failures"] for r in base + new)
        diff = [n["blinds_cleared"] - b["blinds_cleared"] for b, n in zip(base, new)]
        mean = statistics.mean(diff)
        se = statistics.stdev(diff) / (len(diff) ** 0.5) if len(diff) > 1 else 0.0
        report["difficulties"][difficulty] = {
            "base_mean": round(statistics.mean(b["blinds_cleared"] for b in base), 3),
            "new_mean": round(statistics.mean(n["blinds_cleared"] for n in new), 3),
            "diff": round(mean, 3), "se": round(se, 3), "t": round(mean / se, 2) if se else None,
        }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if failures else 0


def main(argv=None):
    global LUA
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--runtime", default="lupa.luajit21")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--difficulty", action="append", choices=DIFFICULTIES, help="limit to these difficulties (repeatable)")
    parser.add_argument("--paired", type=Path, metavar="BASE_POLICY",
                        help="compare a baseline_policy.lua file (e.g. from git show) against the current one on the same seeds")
    args = parser.parse_args(argv)
    LUA = importlib.import_module(args.runtime).LuaRuntime(unpack_returned_tuples=True)
    fn = LUA.execute(DECIDE)(str(REPO))
    if args.paired:
        return paired(args, fn, LUA.execute(DECIDE)(str(REPO), str(args.paired.resolve())))
    started = time.perf_counter()
    report = {"runs": args.runs, "seed": args.seed, "runtime": args.runtime, "max_ante": MAX_ANTE, "difficulties": {}}
    for difficulty in args.difficulty or DIFFICULTIES:
        runs = [simulate_run(fn, args.seed * 1000 + i, difficulty) for i in range(args.runs)]
        report["difficulties"][difficulty] = {
            "mean_blinds_cleared": round(statistics.mean(r["blinds_cleared"] for r in runs), 3),
            "mean_ante_reached": round(statistics.mean(r["ante_reached"] for r in runs), 3),
            "reached_ante": {str(a): round(sum(r["ante_reached"] >= a for r in runs) / len(runs), 3) for a in range(2, MAX_ANTE + 2)},
            "mean_jokers_bought": round(statistics.mean(r["jokers_bought"] for r in runs), 3),
            "mean_planets_bought": round(statistics.mean(r["planets_bought"] for r in runs), 3),
            "mean_rerolls": round(statistics.mean(r["rerolls"] for r in runs), 3),
            "mean_money_end": round(statistics.mean(r["money_end"] for r in runs), 2),
            "decisions": sum(r["decisions"] for r in runs),
            "failures": sum(r["failures"] for r in runs),
            "max_instructions": max(r["instructions"] for r in runs),
        }
    report["wall_seconds"] = round(time.perf_counter() - started, 2)
    report["interpretation"] = (
        "mini-runs within the shared reference model (Jokers, planets, rerolls, interest, "
        "debuff/Needle/Water bosses); not a Balatro win rate"
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 1 if any(d["failures"] for d in report["difficulties"].values()) else 0


if __name__ == "__main__":
    sys.exit(main())
