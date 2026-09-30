#!/usr/bin/env python3
"""Seeded play-phase benchmark for the baseline policy (cloud-safe, no game).

Each scenario is a synthetic, rules-shaped PLAY_HAND (or PvP) state: a random
eight-card hand (with some enhancements, editions and red seals), 0-5 Jokers
from a known set, hands/discards left, the displayed score and blind
requirement. It runs through the *real* trusted pipeline: engine fixture ->
EngineAdapter certificates -> StateReader -> AIObservation export -> sandboxed
policy (tools/lua/policy_env.lua), exactly like a live decision.

An independent Python reference scorer (public Balatro rules: base hand
chips/mult at level 1, card chips, enhancements, editions, red seal and a set of
simple Jokers) then grades the choice. It is an evaluation aid, not the game:
scaling Jokers, hand levels, boss effects and probabilistic effects beyond their
expectation are not modelled, so the numbers measure *relative* policy quality
and catch regressions. They are not win rates.

Metrics per difficulty:
  play_optimal    share of PLAY choices whose reference score is the best offered play
  regret          mean 1 - chosen/best over PLAY choices
  clear_taken     when an offered play clears the remaining requirement, share of
                  decisions that played a clearing hand
  coverage        mean best-offered / best-possible (any <= 5 cards): adapter
                  candidate quality, identical across difficulties
  discard_rate / play_rate / no_action / failures / illegal / latency
  discard_quality (with --discard-samples N): for DISCARD choices, expected best
                  follow-up play after drawing replacements (Monte Carlo over the
                  unseen deck, common random numbers across candidates) of the
                  chosen discard / of the best offered discard

Usage: python tests/benchmark_policy.py [--scenarios N] [--seed S] [--json PATH]
       [--check docs/benchmarks/policy_baseline.json]
"""
from __future__ import annotations

import argparse
import importlib
import itertools
import json
import random
import statistics
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIFFICULTIES = ("rookie", "competitive", "major_league", "expert")

RANKS = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace"]
SUITS = ["Hearts", "Diamonds", "Clubs", "Spades"]
RANK_VALUE = {r: i + 2 for i, r in enumerate(RANKS)}
ENHANCEMENTS = ["m_bonus", "m_mult", "m_glass", "m_steel", "m_lucky", "m_wild", "m_stone"]
EDITIONS = ["foil", "holo", "polychrome"]

# Level-1 base (chips, mult) per hand, public Balatro values.
HAND_BASE = {
    "high_card": (5, 1),
    "pair": (10, 2),
    "two_pair": (20, 2),
    "three": (30, 3),
    "straight": (30, 4),
    "flush": (35, 4),
    "full_house": (40, 4),
    "four": (60, 7),
    "straight_flush": (100, 8),
    "five": (120, 12),
    "flush_house": (140, 14),
    "flush_five": (160, 16),
}
# Per-level (chips, mult) increments, public Balatro values; engine names.
LEVEL_UP = {
    "high_card": (10, 1, "High Card"),
    "pair": (15, 1, "Pair"),
    "two_pair": (20, 1, "Two Pair"),
    "three": (20, 2, "Three of a Kind"),
    "straight": (30, 3, "Straight"),
    "flush": (15, 2, "Flush"),
    "full_house": (25, 2, "Full House"),
    "four": (30, 3, "Four of a Kind"),
    "straight_flush": (40, 4, "Straight Flush"),
}
CONTAINS = {
    "pair": {"pair", "two_pair", "three", "full_house", "four", "five", "flush_house", "flush_five"},
    "two_pair": {"two_pair", "full_house", "flush_house"},
    "three": {"three", "full_house", "four", "five", "flush_house", "flush_five"},
    "four": {"four", "five", "flush_five"},
    "straight": {"straight", "straight_flush"},
    "flush": {"flush", "straight_flush", "flush_house", "flush_five"},
}

# Reference Joker effects (public card text). kind: (effect, value, condition)
JOKERS = {
    "j_joker": ("mult", 4, None),
    "j_greedy_joker": ("suit_mult", 3, "Diamonds"),
    "j_lusty_joker": ("suit_mult", 3, "Hearts"),
    "j_wrathful_joker": ("suit_mult", 3, "Spades"),
    "j_gluttenous_joker": ("suit_mult", 3, "Clubs"),
    "j_jolly": ("hand_mult", 8, "pair"),
    "j_zany": ("hand_mult", 12, "three"),
    "j_mad": ("hand_mult", 10, "two_pair"),
    "j_crazy": ("hand_mult", 12, "straight"),
    "j_droll": ("hand_mult", 10, "flush"),
    "j_sly": ("hand_chips", 50, "pair"),
    "j_wily": ("hand_chips", 100, "three"),
    "j_clever": ("hand_chips", 80, "two_pair"),
    "j_devious": ("hand_chips", 100, "straight"),
    "j_crafty": ("hand_chips", 80, "flush"),
    "j_duo": ("hand_xmult", 2, "pair"),
    "j_trio": ("hand_xmult", 3, "three"),
    "j_family": ("hand_xmult", 4, "four"),
    "j_order": ("hand_xmult", 3, "straight"),
    "j_tribe": ("hand_xmult", 2, "flush"),
    "j_half": ("half", 20, None),
    "j_scary_face": ("face_chips", 30, None),
    "j_smiley": ("face_mult", 5, None),
    "j_even_steven": ("even_mult", 4, None),
    "j_odd_todd": ("odd_chips", 31, None),
    "j_scholar": ("ace", None, None),
    "j_fibonacci": ("fib_mult", 8, None),
    "j_walkie_talkie": ("walkie", None, None),
    "j_triboulet": ("kq_xmult", 2, None),
    "j_abstract": ("abstract", 3, None),
    "j_baron": ("held_king_xmult", 1.5, None),
    "j_shoot_the_moon": ("held_queen_mult", 13, None),
    "j_misprint": ("mult", 11.5, None),
    "j_gros_michel": ("mult", 15, None),
    "j_cavendish": ("xmult", 3, None),
    "j_stuntman": ("chips", 250, None),
    "j_photograph": ("photo", 2, None),
}
JOKER_KEYS = sorted(JOKERS)


def card_chips(card):
    if card.get("center") == "m_stone":
        return 0
    rank = card["rank"]
    if rank in ("Jack", "Queen", "King"):
        return 10
    if rank == "Ace":
        return 11
    return RANK_VALUE[rank]


def classify(cards):
    """(hand_name, scoring_indices) under Balatro rules (no Four Fingers/Shortcut)."""
    ranked = [i for i, c in enumerate(cards) if c.get("center") != "m_stone"]
    stones = [i for i, c in enumerate(cards) if c.get("center") == "m_stone"]
    counts = {}
    for i in ranked:
        counts.setdefault(RANK_VALUE[cards[i]["rank"]], []).append(i)
    groups = sorted(counts.values(), key=lambda g: (-len(g), -RANK_VALUE[cards[g[0]]["rank"]]))
    n = len(cards)
    flush = False
    if n == 5 and len(ranked) == 5:
        for suit in SUITS:
            if all(cards[i]["suit"] == suit or cards[i].get("center") == "m_wild" for i in ranked):
                flush = True
    straight = False
    if n == 5 and len(ranked) == 5 and len(counts) == 5:
        values = sorted(counts)
        if values[-1] - values[0] == 4 or values == [2, 3, 4, 5, 14]:
            straight = True
    sizes = [len(g) for g in groups]
    everything = list(range(n))
    if sizes and sizes[0] == 5:
        return ("flush_five" if flush else "five"), everything
    if straight and flush:
        return "straight_flush", everything
    if sizes and sizes[0] == 4:
        return "four", groups[0] + stones
    if len(sizes) >= 2 and sizes[0] == 3 and sizes[1] >= 2:
        return ("flush_house" if flush else "full_house"), everything
    if flush:
        return "flush", everything
    if straight:
        return "straight", everything
    if sizes and sizes[0] == 3:
        return "three", groups[0] + stones
    if len(sizes) >= 2 and sizes[0] == 2 and sizes[1] == 2:
        return "two_pair", groups[0] + groups[1] + stones
    if sizes and sizes[0] == 2:
        return "pair", groups[0] + stones
    if ranked:
        top = max(ranked, key=lambda i: RANK_VALUE[cards[i]["rank"]])
        return "high_card", [top] + stones
    return "high_card", stones


def reference_score(played, held, jokers, levels=None):
    """Expected score of playing ``played`` with ``held`` left in hand."""
    hand, scoring = classify(played)
    chips, mult = HAND_BASE[hand]
    if levels and hand in levels:
        chips, mult = levels[hand]["chips"], levels[hand]["mult"]
    chips, mult = float(chips), float(mult)
    photo_index = None
    for index in sorted(scoring):
        card = played[index]
        if (
            not card.get("debuff")
            and card.get("center") != "m_stone"
            and card["rank"] in ("Jack", "Queen", "King")
        ):
            photo_index = index
            break
    for index in sorted(scoring):
        card = played[index]
        if card.get("debuff"):
            continue
        repeats = 2 if card.get("seal") == "Red" else 1
        for _ in range(repeats):
            chips += card_chips(card)
            center = card.get("center")
            # Enhancement (Lucky: 1 in 5 for +20 mult), then Glass, then edition.
            if center == "m_bonus":
                chips += 30
            elif center == "m_mult":
                mult += 4
            elif center == "m_stone":
                chips += 50
            elif center == "m_lucky":
                mult += 20 * 0.2
            elif center == "m_glass":
                mult *= 2
            edition = card.get("edition")
            if edition == "foil":
                chips += 50
            elif edition == "holo":
                mult += 10
            elif edition == "polychrome":
                mult *= 1.5
            rank = card.get("rank") if center != "m_stone" else None
            is_face = rank in ("Jack", "Queen", "King")
            for key in jokers:
                effect, value, condition = JOKERS[key]
                if effect == "suit_mult" and rank is not None and (card["suit"] == condition or center == "m_wild"):
                    mult += value
                elif effect == "face_chips" and is_face:
                    chips += value
                elif effect == "face_mult" and is_face:
                    mult += value
                elif effect == "even_mult" and rank in ("2", "4", "6", "8", "10"):
                    mult += value
                elif effect == "odd_chips" and rank in ("Ace", "3", "5", "7", "9"):
                    chips += value
                elif effect == "ace" and rank == "Ace":
                    chips += 20
                    mult += 4
                elif effect == "fib_mult" and rank in ("Ace", "2", "3", "5", "8"):
                    mult += value
                elif effect == "walkie" and rank in ("10", "4"):
                    chips += 10
                    mult += 4
                elif effect == "kq_xmult" and rank in ("King", "Queen"):
                    mult *= value
                elif effect == "photo" and index == photo_index:
                    mult *= value
    for card in held:
        if card.get("debuff"):
            continue
        repeats = 2 if card.get("seal") == "Red" else 1
        for _ in range(repeats):
            if card.get("center") == "m_steel":
                mult *= 1.5
            if card.get("center") != "m_stone":
                if card["rank"] == "King" and "j_baron" in jokers:
                    mult *= 1.5
                if card["rank"] == "Queen" and "j_shoot_the_moon" in jokers:
                    mult += 13
    for key in jokers:
        effect, value, condition = JOKERS[key]
        if effect == "mult":
            mult += value
        elif effect == "chips":
            chips += value
        elif effect == "xmult":
            mult *= value
        elif effect == "hand_mult" and hand in CONTAINS[condition]:
            mult += value
        elif effect == "hand_chips" and hand in CONTAINS[condition]:
            chips += value
        elif effect == "hand_xmult" and hand in CONTAINS[condition]:
            mult *= value
        elif effect == "half" and len(played) <= 3:
            mult += value
        elif effect == "abstract":
            mult += value * len(jokers)
    return chips * mult


def make_scenario(rng):
    deck = [(r, s) for r in RANKS for s in SUITS]
    rng.shuffle(deck)
    hand = []
    for rank, suit in deck[:8]:
        card = {"rank": rank, "suit": suit}
        roll = rng.random()
        if roll < 0.12:
            card["center"] = rng.choice(ENHANCEMENTS)
        if rng.random() < 0.05:
            card["edition"] = rng.choice(EDITIONS)
        if rng.random() < 0.05:
            card["seal"] = "Red"
        hand.append(card)
    jokers = rng.sample(JOKER_KEYS, rng.choice([0, 1, 2, 2, 3, 3, 4, 5]))
    levels = {}
    for name in rng.sample(sorted(LEVEL_UP), rng.choice([0, 0, 1, 2, 3])):
        level = rng.choice([2, 3, 4, 6])
        add_chips, add_mult, _ = LEVEL_UP[name]
        base_chips, base_mult = HAND_BASE[name]
        levels[name] = {
            "level": level,
            "chips": base_chips + add_chips * (level - 1),
            "mult": base_mult + add_mult * (level - 1),
        }
    pvp = rng.random() < 0.2
    requirement = rng.choice([300, 450, 600, 800, 1200, 2000, 3000, 5000, 11000])
    scored = int(requirement * rng.choice([0, 0, 0.2, 0.5, 0.8]))
    return {
        "hand": hand,
        "jokers": jokers,
        "hands_left": rng.choice([1, 2, 3, 4]),
        "discards_left": rng.choice([0, 1, 2, 3]),
        "chips": scored,
        "requirement": requirement,
        "pvp": pvp,
        "levels": levels,
    }


HARNESS = r'''
return function(repo, scenarios, difficulties)
	package.path = repo .. "/tests/engine/?.lua;" .. package.path
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
	local baseline = dofile(repo .. "/AISparring/ai/baseline_policy.lua")
	local sources = {}
	for d = 1, #difficulties do
		sources[difficulties[d]] = assert(baseline.source(difficulties[d]))
	end
	local clock = os.clock
	local out = {}
	for s = 1, #scenarios do
		local sc = scenarios[s]
		local hand = {}
		for i = 1, #sc.hand do
			local c = sc.hand[i]
			local center = c.center or "c_base"
			hand[i] = support.card({
				rank = c.rank, suit = c.suit, center = center,
				center_set = c.center and "Enhanced" or "Default",
				edition = c.edition, seal = c.seal,
			})
		end
		local jokers = {}
		for i = 1, #sc.jokers do
			jokers[i] = support.card({ center = sc.jokers[i], center_set = "Joker", set = "Joker" })
		end
		local engine = support.engine({
			state = support.STATES.SELECTING_HAND,
			hand = hand,
			jokers = jokers,
			hands_left = sc.hands_left,
			discards_left = sc.discards_left,
			chips = sc.chips,
			blind_key = sc.pvp and "bl_mp_nemesis" or "bl_small",
			blind_pvp = sc.pvp or nil,
		})
		engine.G.GAME.blind.chips = sc.requirement
		if sc.levels ~= nil then
			local hands = {}
			for name, entry in pairs(sc.levels) do
				hands[entry.engine] = { level = entry.level, chips = entry.chips, mult = entry.mult, visible = true }
			end
			engine.G.GAME.hands = hands
		end
		local pipeline = support.pipeline(bundle, engine, {})
		local step, code = pipeline.adapter.step()
		local row = { scenario = s, candidates = {}, choices = {} }
		if step == nil then
			row.error = tostring(code)
		else
			local handle = bundle.reader.capture(step.runtime, step.ui_view)
			local list = bundle.actions.generate(handle)
			for i = 1, #list do
				local a = list[i]
				row.candidates[#row.candidates + 1] = { id = a.id, type = a.type, refs = a.card_refs }
			end
			local export = bundle.obs.export(handle)
			-- Forced-discard variant: the same observation with only its discard
			-- certificates, so discard ranking is compared on identical states.
			local forced = nil
			if export.certificates ~= nil then
				local items = {}
				for i = 1, #export.certificates.items do
					local item = export.certificates.items[i]
					if item.type == "DISCARD_CARDS" then
						items[#items + 1] = item
					end
				end
				if #items > 0 then
					forced = {}
					for k, v in pairs(export) do
						forced[k] = v
					end
					forced.certificates = { version = export.certificates.version, items = items }
				end
			end
			row.forced = {}
			for d = 1, #difficulties do
				local name = difficulties[d]
				local started = clock()
				local result = policy_env.run(sources[name], export)
				local elapsed = clock() - started
				local choice = { difficulty = name, seconds = elapsed, ok = result.ok == true, code = result.code }
				if result.ok == true and type(result.action) == "table" then
					choice.id = result.action.id
					choice.type = result.action.type
				end
				row.choices[#row.choices + 1] = choice
				if forced ~= nil then
					local forced_result = policy_env.run(sources[name], forced)
					local forced_choice = { difficulty = name, ok = forced_result.ok == true }
					if forced_result.ok == true and type(forced_result.action) == "table" then
						forced_choice.refs = forced_result.action.card_refs
					end
					row.forced[#row.forced + 1] = forced_choice
				end
			end
		end
		out[#out + 1] = row
	end
	return out
end
'''


def lua_scenarios(scenarios):
    """Scenarios with each hand level tagged by its engine hand name."""
    out = []
    for scenario in scenarios:
        copy = dict(scenario)
        copy["levels"] = {
            name: dict(entry, engine=LEVEL_UP[name][2]) for name, entry in (scenario.get("levels") or {}).items()
        }
        out.append(copy)
    return out


def to_lua(lua, value):
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = to_lua(lua, item)
        return table
    if isinstance(value, (list, tuple)):
        table = lua.table()
        for index, item in enumerate(value, 1):
            table[index] = to_lua(lua, item)
        return table
    return value


def from_lua(value):
    if hasattr(value, "items") and not isinstance(value, (str, bytes)):
        keys = list(value.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [from_lua(value[k]) for k in sorted(keys)]
        return {k: from_lua(v) for k, v in value.items()}
    return value


def refs_to_indices(refs):
    return [int(ref.split(":")[1]) - 1 for ref in refs]


def best_possible(hand, jokers, levels=None):
    best = 0.0
    indices = range(len(hand))
    for size in range(1, 6):
        for combo in itertools.combinations(indices, size):
            played = [hand[i] for i in combo]
            held = [hand[i] for i in indices if i not in combo]
            best = max(best, reference_score(played, held, jokers, levels))
    return best


def discard_ev(hand, jokers, discard_idx, draws, levels=None):
    """Mean best reference play after discarding and drawing, over ``draws``."""
    kept = [hand[i] for i in range(len(hand)) if i not in discard_idx]
    total = 0.0
    for order in draws:
        new_hand = kept + order[: len(discard_idx)]
        total += best_possible(new_hand, jokers, levels)
    return total / len(draws)


def evaluate(rows, scenarios, discard_samples=0):
    metrics = {}
    for difficulty in DIFFICULTIES:
        metrics[difficulty] = {
            "decisions": 0, "plays": 0, "discards": 0, "other": 0, "no_action": 0,
            "failures": 0, "illegal": 0, "optimal": 0, "regret_sum": 0.0,
            "clear_chances": 0, "clear_taken": 0, "latency": [],
            "discard_quality": [], "forced_quality": [],
        }
    coverage = []
    for row in rows:
        scenario = scenarios[row["scenario"] - 1]
        if row.get("error"):
            for difficulty in DIFFICULTIES:
                metrics[difficulty]["failures"] += 1
            continue
        hand, jokers = scenario["hand"], scenario["jokers"]
        levels = scenario.get("levels")
        play_scores = {}
        for candidate in row["candidates"]:
            if candidate["type"] == "PLAY_CARDS":
                idx = refs_to_indices(candidate["refs"])
                played = [hand[i] for i in idx]
                held = [hand[i] for i in range(len(hand)) if i not in idx]
                play_scores[candidate["id"]] = reference_score(played, held, jokers, levels)
        best_offered = max(play_scores.values()) if play_scores else 0.0
        possible = best_possible(hand, jokers, levels)
        if possible > 0:
            coverage.append(best_offered / possible)
        remaining = scenario["requirement"] - scenario["chips"]
        can_clear = (not scenario["pvp"]) and best_offered >= remaining
        valid_ids = {c["id"] for c in row["candidates"]}
        discard_values = None
        if discard_samples and (row.get("forced") or any(c.get("type") == "DISCARD_CARDS" for c in row["choices"])):
            seen = {(c["rank"], c["suit"]) for c in hand}
            unseen = [{"rank": r, "suit": su} for r in RANKS for su in SUITS if (r, su) not in seen]
            draw_rng = random.Random(row["scenario"])
            draws = []
            for _ in range(discard_samples):
                order = list(unseen)
                draw_rng.shuffle(order)
                draws.append(order[:5])
            discard_values = {}
            for candidate in row["candidates"]:
                if candidate["type"] == "DISCARD_CARDS":
                    discard_values[candidate["id"]] = discard_ev(
                        hand, jokers, set(refs_to_indices(candidate["refs"])), draws, levels
                    )
        if discard_values:
            best_discard = max(discard_values.values())
            by_refs = {}
            for candidate in row["candidates"]:
                if candidate["type"] == "DISCARD_CARDS":
                    by_refs[",".join(candidate["refs"])] = discard_values.get(candidate["id"], 0.0)
            for forced in row.get("forced") or []:
                if forced.get("ok") and forced.get("refs") and best_discard > 0:
                    value = by_refs.get(",".join(forced["refs"]), 0.0)
                    metrics[forced["difficulty"]]["forced_quality"].append(value / best_discard)
        for choice in row["choices"]:
            m = metrics[choice["difficulty"]]
            m["decisions"] += 1
            m["latency"].append(choice["seconds"])
            if not choice["ok"]:
                if choice.get("code") == "policy_no_action":
                    m["no_action"] += 1
                else:
                    m["failures"] += 1
                continue
            if choice["id"] not in valid_ids:
                m["illegal"] += 1
                continue
            if can_clear:
                m["clear_chances"] += 1
            if choice["type"] == "PLAY_CARDS":
                m["plays"] += 1
                score = play_scores.get(choice["id"], 0.0)
                if best_offered > 0:
                    if score >= best_offered - 1e-9:
                        m["optimal"] += 1
                    m["regret_sum"] += 1.0 - score / best_offered
                if can_clear and score >= remaining:
                    m["clear_taken"] += 1
            elif choice["type"] == "DISCARD_CARDS":
                m["discards"] += 1
                if discard_values:
                    best_discard = max(discard_values.values())
                    if best_discard > 0:
                        m["discard_quality"].append(discard_values.get(choice["id"], 0.0) / best_discard)
            else:
                m["other"] += 1
    report = {"coverage": round(statistics.mean(coverage), 4) if coverage else None, "difficulties": {}}
    for difficulty, m in metrics.items():
        latency = sorted(m.pop("latency")) or [0.0]
        quality = m.pop("discard_quality")
        forced_quality = m.pop("forced_quality")
        plays = m["plays"] or 1
        report["difficulties"][difficulty] = {
            "decisions": m["decisions"],
            "play_rate": round(m["plays"] / max(1, m["decisions"]), 4),
            "discard_rate": round(m["discards"] / max(1, m["decisions"]), 4),
            "other": m["other"],
            "no_action": m["no_action"],
            "failures": m["failures"],
            "illegal": m["illegal"],
            "play_optimal": round(m["optimal"] / plays, 4),
            "regret": round(m["regret_sum"] / plays, 4),
            "clear_taken": round(m["clear_taken"] / m["clear_chances"], 4) if m["clear_chances"] else None,
            "latency_ms_mean": round(1000 * statistics.mean(latency), 3),
            "latency_ms_p95": round(1000 * latency[int(0.95 * (len(latency) - 1))], 3),
            "discard_quality": round(statistics.mean(quality), 4) if quality else None,
            "forced_discard_quality": round(statistics.mean(forced_quality), 4) if forced_quality else None,
        }
    return report


# Regression gates for --check: the stored baseline may be improved on, never
# made worse beyond these tolerances.
CHECK_TOLERANCE = {"play_optimal": 0.02, "regret": 0.02, "clear_taken": 0.02, "coverage": 0.01, "discard_quality": 0.03}


def check(report, baseline):
    problems = []
    if baseline.get("coverage") is not None and report["coverage"] is not None:
        if report["coverage"] < baseline["coverage"] - CHECK_TOLERANCE["coverage"]:
            problems.append(f"coverage {report['coverage']} < {baseline['coverage']}")
    for difficulty, base in baseline["difficulties"].items():
        now = report["difficulties"].get(difficulty, {})
        for key in ("failures", "illegal"):
            if now.get(key, 0) > base.get(key, 0):
                problems.append(f"{difficulty} {key} {now.get(key)} > {base.get(key)}")
        if now.get("play_optimal", 0) < base["play_optimal"] - CHECK_TOLERANCE["play_optimal"]:
            problems.append(f"{difficulty} play_optimal {now.get('play_optimal')} < {base['play_optimal']}")
        if now.get("regret", 1) > base["regret"] + CHECK_TOLERANCE["regret"]:
            problems.append(f"{difficulty} regret {now.get('regret')} > {base['regret']}")
        if base.get("clear_taken") is not None and (now.get("clear_taken") or 0) < base["clear_taken"] - CHECK_TOLERANCE["clear_taken"]:
            problems.append(f"{difficulty} clear_taken {now.get('clear_taken')} < {base['clear_taken']}")
        for key in ("discard_quality", "forced_discard_quality"):
            if base.get(key) is not None and now.get(key) is not None:
                if now[key] < base[key] - CHECK_TOLERANCE["discard_quality"]:
                    problems.append(f"{difficulty} {key} {now[key]} < {base[key]}")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scenarios", type=int, default=300)
    parser.add_argument("--seed", type=int, action="append", help="scenario seed family (repeatable)")
    parser.add_argument("--runtime", default="lupa.luajit21")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--check", type=Path)
    parser.add_argument("--discard-samples", type=int, default=0, help="Monte Carlo draws per discard candidate (slow)")
    args = parser.parse_args(argv)
    seeds = args.seed or [11, 23, 37]
    scenarios = []
    for seed in seeds:
        rng = random.Random(seed)
        scenarios.extend(make_scenario(rng) for _ in range(args.scenarios // len(seeds)))
    lua = importlib.import_module(args.runtime).LuaRuntime(unpack_returned_tuples=True)
    harness = lua.execute(HARNESS)
    started = time.perf_counter()
    rows = from_lua(harness(str(REPO), to_lua(lua, lua_scenarios(scenarios)), to_lua(lua, list(DIFFICULTIES))))
    elapsed = time.perf_counter() - started
    report = evaluate(rows, scenarios, args.discard_samples)
    report["scenarios"] = len(scenarios)
    report["seeds"] = seeds
    report["runtime"] = args.runtime
    report["wall_seconds"] = round(elapsed, 2)
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.check:
        problems = check(report, json.loads(args.check.read_text(encoding="utf-8")))
        for problem in problems:
            print("REGRESSION", problem)
        print("RESULT:", "FAIL" if problems else "PASS")
        return 1 if problems else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
