#!/usr/bin/env python3
"""Seeded blind simulator for the baseline policy (cloud-safe, no game).

A step towards full-run (Gauntlet) metrics. Each simulated blind deals from a
shuffled standard 52-card deck and lets the policy act repeatedly (play or
discard, then draw back to the hand size) until the displayed requirement is
reached or no hands remain. Boss blinds apply the effects the fixture can
represent (suit / face debuffs, The Needle, The Water, The Psychic). Every decision goes
through the real trusted
pipeline: engine fixture -> EngineAdapter -> StateReader -> AIObservation ->
sandboxed policy (tools/lua/policy_env.lua).

Every difficulty sees the same deck order for the same blind (common random
numbers), so differences come from decisions, not luck.

Plays are scored with the reference scorer in tests/benchmark_policy.py, which
shares the policy's scoring model. So the metric measures how well discards and
plays are *sequenced* under real random draws within that model. It is not a
win rate against Balatro, and it does not model other boss effects, scaling
Jokers, shops or opponents. Lucky cards score their average (+20 mult at 1 in
5) and Glass cards never break.

Usage: python tests/benchmark_blinds.py [--blinds N] [--seed S] [--runtime R] [--json PATH]
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
import benchmark_policy as bp  # noqa: E402

DIFFICULTIES = bp.DIFFICULTIES
HAND_SIZE = 8
HANDS = 4
DISCARDS = 3
MAX_STEPS = 16

# Base chips per ante for small / big / boss blinds (vanilla 300-scaling table).
ANTE_BASE = {1: 300, 2: 800, 3: 2000, 4: 5000}
BLIND_MULT = {"small": 1.0, "big": 1.5, "boss": 2.0}
# Boss effects the engine fixture can represent faithfully: suit bosses and The
# Plant debuff their cards (vanilla: debuffed cards score nothing); The Needle
# gives one hand; The Water gives no discards; The Psychic scores only 5-card
# hands. Other bosses are not modelled.
# `req` is the requirement multiplier (vanilla: The Needle x1, others x2) and
# `min_ante` the first ante the boss can appear at.
BOSSES = {
    "bl_club": {"debuff": "Clubs", "min_ante": 1}, "bl_goad": {"debuff": "Spades", "min_ante": 1},
    "bl_window": {"debuff": "Diamonds", "min_ante": 1}, "bl_head": {"debuff": "Hearts", "min_ante": 1},
    "bl_plant": {"debuff": "face", "min_ante": 4}, "bl_needle": {"hands": 1, "req": 1.0, "min_ante": 2},
    "bl_water": {"discards": 0, "min_ante": 2},
    "bl_psychic": {"min_cards": 5, "min_ante": 1},
}
BOSS_KEYS = sorted(BOSSES)

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
		local hand = {}
		for i = 1, #state.hand do
			local c = state.hand[i]
			hand[i] = support.card({
				rank = c.rank, suit = c.suit, center = c.center or "c_base",
				center_set = c.center and "Enhanced" or "Default", edition = c.edition, seal = c.seal,
				debuff = c.debuff,
			})
		end
		local jokers = {}
		for i = 1, #state.jokers do
			jokers[i] = support.card({ center = state.jokers[i], center_set = "Joker", set = "Joker" })
		end
		local engine = support.engine({
			state = support.STATES.SELECTING_HAND, hand = hand, jokers = jokers,
			hands_left = state.hands_left, discards_left = state.discards_left, chips = state.chips,
			blind_key = state.boss or "bl_small",
		})
		engine.G.GAME.blind.chips = state.requirement
		local step, code = support.pipeline(bundle, engine, {}).adapter.step()
		if step == nil then
			return { ok = false, code = tostring(code) }
		end
		local handle = bundle.reader.capture(step.runtime, step.ui_view)
		local export = bundle.obs.export(handle)
		local started = os.clock()
		local result = policy_env.run(sources[difficulty], export)
		local out = { ok = result.ok == true, code = result.code, seconds = os.clock() - started,
			instructions = policy_env.last_instructions() }
		if result.ok == true then
			out.type = result.action.type
			out.refs = result.action.card_refs
		end
		return out
	end
end
'''


def make_blind(rng, index):
    ante = 1 + (index // 3) % 4
    kind = ("small", "big", "boss")[index % 3]
    deck = [{"rank": r, "suit": s} for r in bp.RANKS for s in bp.SUITS]
    for card in deck:
        if rng.random() < 0.08:
            card["center"] = rng.choice(["m_bonus", "m_mult", "m_glass", "m_steel", "m_lucky"])
    rng.shuffle(deck)
    joker_count = min(5, ante + rng.choice([-1, 0, 0, 1]))
    jokers = rng.sample(bp.JOKER_KEYS, max(0, joker_count))
    boss = rng.choice([k for k in BOSS_KEYS if BOSSES[k]["min_ante"] <= ante]) if kind == "boss" else None
    mult = BOSSES[boss].get("req", BLIND_MULT["boss"]) if boss else BLIND_MULT[kind]
    return {
        "ante": ante,
        "kind": kind,
        "boss": boss,
        "requirement": int(ANTE_BASE[ante] * mult),
        "deck": deck,
        "jokers": jokers,
    }


def simulate(decide, blind, difficulty):
    effect = BOSSES.get(blind.get("boss"), {})
    target = effect.get("debuff")
    deck = []
    for card in blind["deck"]:
        card = dict(card)
        if target is not None and (card["suit"] == target or (target == "face" and card["rank"] in ("Jack", "Queen", "King"))):
            card["debuff"] = True
        deck.append(card)
    hand = [deck.pop(0) for _ in range(HAND_SIZE)]
    chips, hands_left, discards_left = 0, effect.get("hands", HANDS), effect.get("discards", DISCARDS)
    stats = {"decisions": 0, "failures": 0, "discards": 0, "latency": [], "instructions": 0, "step_cap": 0}
    for step in range(MAX_STEPS + 1):
        if chips >= blind["requirement"] or hands_left == 0:
            break
        if step == MAX_STEPS:
            stats["step_cap"] = 1
            break
        state = {
            "hand": hand, "jokers": blind["jokers"], "hands_left": hands_left,
            "discards_left": discards_left, "chips": chips, "requirement": blind["requirement"],
            "boss": blind.get("boss"),
        }
        result = bp.from_lua(decide(bp.to_lua(LUA, state), difficulty))
        stats["decisions"] += 1
        stats["latency"].append(result.get("seconds") or 0.0)
        stats["instructions"] = max(stats["instructions"], result.get("instructions") or 0)
        if not result.get("ok") or result.get("type") not in ("PLAY_CARDS", "DISCARD_CARDS"):
            stats["failures"] += 1
            break
        idx = sorted(set(bp.refs_to_indices(result["refs"])))
        chosen = [hand[i] for i in idx]
        rest = [hand[i] for i in range(len(hand)) if i not in idx]
        if result["type"] == "PLAY_CARDS":
            if len(chosen) >= effect.get("min_cards", 0):
                chips += int(bp.reference_score(chosen, rest, blind["jokers"]))
            hands_left -= 1
        else:
            discards_left -= 1
            stats["discards"] += 1
        hand = rest
        while len(hand) < HAND_SIZE and deck:
            hand.append(deck.pop(0))
    stats["cleared"] = chips >= blind["requirement"]
    stats["ratio"] = min(chips / blind["requirement"], 3.0)
    stats["hands_used"] = effect.get("hands", HANDS) - hands_left
    return stats


LUA = None


def main(argv=None):
    global LUA
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--blinds", type=int, default=120)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--runtime", default="lupa.luajit21")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--difficulty", action="append", choices=DIFFICULTIES, help="limit to these difficulties (repeatable)")
    parser.add_argument("--policy", type=Path, help="policy file to evaluate instead of the repository one")
    parser.add_argument("--paired", type=Path, metavar="BASE_POLICY",
                        help="compare a baseline_policy.lua file against the current one on the same blinds")
    args = parser.parse_args(argv)
    LUA = importlib.import_module(args.runtime).LuaRuntime(unpack_returned_tuples=True)
    decide = LUA.execute(DECIDE)(str(REPO), str(args.policy.resolve()) if args.policy else None)
    rng = random.Random(args.seed)
    blinds = [make_blind(rng, i) for i in range(args.blinds)]
    if args.paired:
        base = LUA.execute(DECIDE)(str(REPO), str(args.paired.resolve()))
        out = {"blinds": len(blinds), "seed": args.seed, "base": str(args.paired), "difficulties": {}}
        for difficulty in args.difficulty or DIFFICULTIES:
            a = [simulate(base, b, difficulty) for b in blinds]
            c = [simulate(decide, b, difficulty) for b in blinds]
            diff = [int(y["cleared"]) - int(x["cleared"]) for x, y in zip(a, c)]
            mean = statistics.mean(diff)
            se = statistics.stdev(diff) / (len(diff) ** 0.5) if len(diff) > 1 else 0.0
            out["difficulties"][difficulty] = {
                "base_clear": round(statistics.mean(int(x["cleared"]) for x in a), 4),
                "new_clear": round(statistics.mean(int(y["cleared"]) for y in c), 4),
                "diff": round(mean, 4), "se": round(se, 4), "t": round(mean / se, 2) if se else None,
                "changed_blinds": sum(1 for d in diff if d),
            }
        print(json.dumps(out, indent=2, sort_keys=True))
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    started = time.perf_counter()
    report = {"blinds": len(blinds), "seed": args.seed, "runtime": args.runtime, "difficulties": {}}
    for difficulty in args.difficulty or DIFFICULTIES:
        runs = [simulate(decide, blind, difficulty) for blind in blinds]
        by_ante = {}
        by_kind = {}
        for blind, run in zip(blinds, runs):
            by_ante.setdefault(blind["ante"], []).append(run["cleared"])
            by_kind.setdefault(blind.get("boss") or blind["kind"], []).append(run["cleared"])
        latency = sorted(x for run in runs for x in run["latency"]) or [0.0]
        report["difficulties"][difficulty] = {
            "clear_rate": round(sum(r["cleared"] for r in runs) / len(runs), 4),
            "clear_rate_by_ante": {str(a): round(sum(v) / len(v), 4) for a, v in sorted(by_ante.items())},
            "clear_rate_by_blind": {k: round(sum(v) / len(v), 4) for k, v in sorted(by_kind.items())},
            "mean_score_ratio": round(statistics.mean(r["ratio"] for r in runs), 4),
            "mean_hands_used": round(statistics.mean(r["hands_used"] for r in runs), 3),
            "mean_discards": round(statistics.mean(r["discards"] for r in runs), 3),
            "decisions": sum(r["decisions"] for r in runs),
            "failures": sum(r["failures"] for r in runs),
            "step_cap_stops": sum(r["step_cap"] for r in runs),
            "max_instructions": max(r["instructions"] for r in runs),
            "latency_ms_p95": round(1000 * latency[int(0.95 * (len(latency) - 1))], 3),
        }
    report["wall_seconds"] = round(time.perf_counter() - started, 2)
    report["interpretation"] = (
        "blind clears under real random draws, scored with the shared reference model; "
        "not a Balatro win rate (only debuff/hand/discard/Psychic boss effects; no scaling Jokers, shops or opponents)"
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    failures = sum(d["failures"] + d["step_cap_stops"] for d in report["difficulties"].values())
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
