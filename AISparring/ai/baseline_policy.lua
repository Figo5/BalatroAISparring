local BaselinePolicy = {}

BaselinePolicy.CODE = {
	OK = "baseline_ok",
	UNKNOWN_DIFFICULTY = "baseline_unknown_difficulty",
	BAD_CONFIG = "baseline_bad_config",
	BAD_SOURCE = "baseline_bad_source",
	TOO_LARGE = "baseline_source_too_large",
}

local CODE = BaselinePolicy.CODE

local MAX_SOURCE = 65536

local function byte_less(a, b)
	local na = #a
	local nb = #b
	local n = na
	if nb < n then
		n = nb
	end
	for i = 1, n do
		local ba = string.byte(a, i)
		local bb = string.byte(b, i)
		if ba ~= bb then
			return ba < bb
		end
	end
	return na < nb
end

local BASE = {
	max_actions = 256,
	reserve = 10,
	interest_cap = 5,
	interest_value = 6,
	debuff_penalty = 5000,
	enhance_value = 50,
	play_junk = 400,
	discard_base = 150000,
	discard_junk = 6000,
	discard_pair_pen = 20000,
	discard_flush_pen = 15000,
	discard_straight_pen = 8000,
	discard_seal_pen = 10000,
	discard_debuff_bonus = 4000,
	discard_cap_bonus = 30000,
	use_consumable = 50000,
	select_targets = 200,
	reorder = 105,
	reorder_bonus = 10,
	blind_select = 200,
	blind_skip = 40,
	-- Press the real Multiplayer timer on a slow opponent while readied at the
	-- PvP blind (0 = never). Rookie leaves it alone, like a casual player.
	start_timer = 1000,
	-- Play-phase evaluation sophistication (difficulty knobs, all legitimate):
	-- estimate_plays scores plays by an estimated chips x mult; est_jokers adds
	-- visible Joker effects to that estimate; use_requirement reads the displayed
	-- blind requirement to prefer clearing plays and to decide when to discard.
	estimate_plays = true,
	est_jokers = true,
	use_requirement = true,
	-- Discard (when not clearing) if best_play * hands_left < pct% of what is
	-- still needed.
	discard_need_pct = 90,
	-- Draw-aware discards: rank discards by expected best follow-up play and
	-- also discard when that beats the best play now by discard_gain_pct%.
	discard_ev = true,
	discard_gain_pct = 150,
	-- Extra draw targets: full house from two pair, straights missing two ranks.
	deep_draws = false,
	-- Use the displayed poker-hand levels (planets) instead of level-1 bases.
	use_levels = true,
	-- Shop Jokers: points per +100% estimated panel score (0 = flat value).
	joker_gain_value = 400,
	item_joker = 300,
	item_consumable = 200,
	item_card = 120,
	item_booster = 250,
	voucher = 260,
	negative = 150,
	buy_edition = 40,
	slot_sell = 220,
	-- Selling a held consumable the safety floor refuses: points over leave_shop.
	sell_harmful = 30,
	-- Per-voucher values (VOUCHER_VALUE) instead of one flat voucher score.
	voucher_values = true,
	-- Pack kind preference (PACK_VALUE) and value-aware picks inside a pack.
	smart_packs = true,
	-- Hold The Hermit until money reaches $20 (its payout cap).
	hold_hermit = true,
	-- Use allowlisted targeted Tarots on hand cards (docs/HAND_TARGETS_DESIGN.md).
	hand_tarots = true,
	-- React to visible boss blind effects (The Psychic).
	boss_aware = true,
	-- Pack pick: points per displayed level of the hand a planet upgrades.
	planet_level_pick = 6,
	reroll_base = 55,
	reroll_surplus_cap = 120,
	leave_shop = 90,
	booster_good = 130,
	booster_skip = 60,
	booster_kind_joker = 60,
	booster_kind_consumable = 50,
	booster_kind_card = 30,
	unknown = 0,
}

local function make_config(name, overrides)
	local config = {}
	for key, value in next, BASE do
		config[key] = value
	end
	config.name = name
	for key, value in next, overrides do
		config[key] = value
	end
	return config
end

local CONFIGS = {
	rookie = make_config("rookie", {
		start_timer = 0,
		voucher_values = false,
		smart_packs = false,
		est_jokers = false,
		use_requirement = false,
		discard_ev = false,
		hold_hermit = false,
		hand_tarots = false,
		boss_aware = false,
		use_levels = false,
		reserve = 6,
		play_junk = 250,
		discard_junk = 5000,
		discard_pair_pen = 16000,
		discard_flush_pen = 12000,
		discard_seal_pen = 8000,
		negative = 120,
		reroll_base = 70,
		reroll_surplus_cap = 160,
		leave_shop = 80,
	}),
	competitive = make_config("competitive", {}),
	major_league = make_config("major_league", {
		discard_need_pct = 100,
		reserve = 12,
		play_junk = 550,
		discard_junk = 7000,
		discard_pair_pen = 24000,
		discard_flush_pen = 18000,
		discard_seal_pen = 14000,
		negative = 180,
		reroll_base = 55,
		reroll_surplus_cap = 120,
		leave_shop = 90,
		blind_skip = 30,
		booster_good = 150,
	}),
	expert = make_config("expert", {
		discard_need_pct = 110,
		-- Expert: the same information with a deeper, more willing draw search.
		deep_draws = true,
		discard_gain_pct = 130,
		joker_gain_value = 500,
		reserve = 12,
		play_junk = 550,
		discard_junk = 7000,
		discard_pair_pen = 24000,
		discard_flush_pen = 18000,
		discard_seal_pen = 14000,
		negative = 180,
		reroll_base = 55,
		reroll_surplus_cap = 120,
		leave_shop = 90,
		blind_skip = 30,
		booster_good = 150,
	}),
}

local ORDER = { "rookie", "competitive", "major_league", "expert" }

local TEMPLATE = [==[
local CONF = %s

-- Per-decision play analysis, computed once over the certified PLAY_CARDS
-- candidates before scoring (see the entry point). Declared first so every
-- scoring function below closes over this local, never a global.
local PLAY = nil
-- The displayed poker-hand levels (self.hand_levels) for this decision, or nil.
local LEVELS = nil
local SMEARED = false
local DRAW_PROFILE = nil
local BALANCED = false
local TIME_PRESSURE = false
local FLINT = false
local RULES = {}
-- Deterministic work meter, reset per decision: every score estimate charges
-- (cards read) x (Jokers applied + 2), which tracks its VM instruction cost.
-- Optional searches stop once their share is spent, so the sandbox budget is
-- not reached whatever the hand size or Joker count.
local WORK = 0
-- The best certified Joker purchase in this shop decision (best_joker), or false.
local SHOP_BEST = false
-- Minimum cards a play needs to score this decision (5 under The Psychic).
local MIN_CARDS = 0
-- True only for the exhausted-hand terminal under The Psychic: our own visible
-- hand holds 1-4 cards, the boss is active, and no certified discard exists.
-- A five-card play cannot exist at that size, so a certified short play is the
-- honest way to consume the last hand and let the round move on to its normal
-- loss. In every other case an undersized play still scores nothing.
local PSYCHIC_TERMINAL = false
-- Hand types that score nothing this decision (docs/HAND_HISTORY_DESIGN.md):
-- under The Eye the types already played this round; under The Mouth every
-- type but those played. nil when no such boss is active.
local EYE_PLAYED = nil
local MOUTH_ONLY = nil
-- Targeted Tarot evaluation, per decision: best play now, and work spent.
local TAROT_BEFORE = nil
local TAROT_WORK = 0
-- Effects derived from owned scaling Jokers' shown values, per decision.
local CURRENT_EFF = {}
local JOKER_CACHE = {}
local GAIN_CACHE = {}

local function blocked_hand(name)
	if EYE_PLAYED ~= nil and EYE_PLAYED[name] then
		return true
	end
	if MOUTH_ONLY ~= nil and not MOUTH_ONLY[name] then
		return true
	end
	return false
end
-- M4: the effective X-multiplier of our own Glass card, projected by the trusted
-- extractor as integer hundredths (Standard reworks Glass to 1.5 = 150; vanilla
-- and Major League keep 2 = 200). Conservative fallback 1.5 when the projection
-- is absent or malformed, so an unreadable card is never over-valued. Never reads
-- a global, a center table or any hidden value.
local GLASS_XMULT_FALLBACK = 150
local function glass_xmult(card)
	local value = card.xmult
	if type(value) == "number" and value == value and value %% 1 == 0 and value >= 100 and value <= 10000 then
		return value / 100
	end
	return GLASS_XMULT_FALLBACK / 100
end
-- BUY_ITEM Joker scores computed by best_joker, reused by score_of (per decision).
local BUY_SCORES = {}
-- Interest cap (interest dollars) for this decision: CONF.interest_cap, raised
-- to 10 by an owned Seed Money and 20 by Money Tree (vanilla $50 / $100).
local INTEREST_CAP = CONF.interest_cap

local function byte_less(a, b)
	local na = #a
	local nb = #b
	local n = na
	if nb < n then
		n = nb
	end
	for i = 1, n do
		local ba = string.byte(a, i)
		local bb = string.byte(b, i)
		if ba ~= bb then
			return ba < bb
		end
	end
	return na < nb
end

-- Accepted rank spellings: single characters (A K Q J T, either case, 2-9),
-- "10" and the full names (capitalised or lower case).
local RANK_OF = {
	A = 14, a = 14, K = 13, k = 13, Q = 12, q = 12, J = 11, j = 11, T = 10, t = 10, ["10"] = 10,
	["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
	Ace = 14, ace = 14, King = 13, king = 13, Queen = 12, queen = 12, Jack = 11, jack = 11, Ten = 10, ten = 10,
}

local function rank_value(rank)
	return type(rank) == "string" and RANK_OF[rank] or nil
end

-- Suits by their first letter, either case.
local SUIT_OF = { H = "H", h = "H", D = "D", d = "D", C = "C", c = "C", S = "S", s = "S" }

local function merge_suit(sk)
	if SMEARED then
		if sk == "D" then return "H" end
		if sk == "C" then return "S" end
	end
	return sk
end

local function suit_key(suit)
	return merge_suit(type(suit) == "string" and SUIT_OF[string.sub(suit, 1, 1)] or nil)
end

local function set_rules(jokers)
	RULES = {}
	if type(jokers) == "table" then
		for i = 1, #jokers do
			local j = jokers[i]
			if type(j) == "table" and j.debuff ~= true and j.redacted ~= true and type(j.center) == "string" then
				RULES[j.center] = true
			end
		end
	end
	SMEARED = RULES.j_smeared == true
end

local function center_bonus(center)
	if type(center) ~= "string" then
		return 0
	end
	if string.sub(center, 1, 2) ~= "m_" then
		return 0
	end
	if center == "m_steel" or center == "m_gold" then
		return 2
	end
	return 1
end

local function edition_bonus(edition)
	if edition == "foil" or edition == "holo" or edition == "polychrome" then
		return 1
	end
	if edition == "negative" then
		return 2
	end
	return 0
end

-- A recognized strictly-positive non-negative edition. Every one of these is an
-- added effect on top of the base card, so it strictly dominates an uneditioned
-- copy of the same visible center; "negative" is excluded here because it is a
-- slot-saving edition, not an upgrade that ever justifies freeing a slot.
local function is_upgrade_edition(edition)
	if edition == "foil" or edition == "holo" or edition == "polychrome" then
		return true
	end
	return false
end

-- Purchase-side edition weight. All recognized non-negative editions get the
-- same small bonus (a strict upgrade over no edition) and the negative edition
-- keeps its bounded slot-saving bonus. Absent/unknown editions add nothing.
local function edition_value(edition)
	if is_upgrade_edition(edition) then
		return CONF.buy_edition
	end
	if edition == "negative" then
		return CONF.negative
	end
	return 0
end

local function by_ref(list, ref)
	if type(list) ~= "table" or type(ref) ~= "string" then
		return nil
	end
	local n = #list
	for i = 1, n do
		local item = list[i]
		if type(item) == "table" and item.id == ref then
			return item
		end
	end
	return nil
end

local function cards_for(obs, refs)
	if type(refs) ~= "table" then
		return nil
	end
	local s = obs.self
	if type(s) ~= "table" then
		return nil
	end
	local hand = s.hand
	if type(hand) ~= "table" then
		return nil
	end
	local out = {}
	local n = #refs
	for i = 1, n do
		local card = by_ref(hand, refs[i])
		if card == nil then
			return nil
		end
		out[i] = card
	end
	return out
end


local function in_run(counts, rv)
	for start = rv - 2, rv do
		local seen = 0
		for k = 0, 2 do
			local r = start + k
			if r >= 2 and r <= 14 and (counts[r] or 0) > 0 then
				seen = seen + 1
			end
		end
		if seen == 3 then
			return true
		end
	end
	return false
end


local function is_stone(card)
	return card.center == "m_stone"
end

-- Hand name and scoring positions, including own visible hand-changing
-- Jokers. Returns nil for unreadable cards.
local function classify_scoring(cards)
	local n = #cards
	local groups = {}
	local ranked = {}
	local stones = {}
	for i = 1, n do
		local c = cards[i]
		if type(c) ~= "table" or c.redacted == true then
			return nil
		end
		if is_stone(c) then
			stones[#stones + 1] = i
		else
			local rv = rank_value(c.rank)
			if rv == nil or suit_key(c.suit) == nil then
				return nil
			end
			ranked[#ranked + 1] = i
			local g = groups[rv]
			if g == nil then
				g = {}
				groups[rv] = g
			end
			g[#g + 1] = i
		end
	end
	local list = {}
	for rv, g in pairs(groups) do
		list[#list + 1] = { rv = rv, g = g }
	end
	table.sort(list, function(a, b)
		if #a.g ~= #b.g then
			return #a.g > #b.g
		end
		return a.rv > b.rv
	end)
	local needed = RULES.j_four_fingers and 4 or 5
	local flush, straight
	local keys = { "S", "H", "C", "D" }
	for k = 1, 4 do
		local g = {}
		for i = 1, #ranked do
			local c = cards[ranked[i]]
			if suit_key(c.suit) == keys[k] or (c.center == "m_wild" and c.debuff ~= true) then g[#g + 1] = ranked[i] end
		end
		if #g >= needed then flush = g; break end
	end
	for low = 1, 14 do
		local g, ranks, gap = {}, 0, 0
		for rv = low, 14 do
			local group = groups[rv == 1 and 14 or rv]
			if group ~= nil then
				ranks, gap = ranks + 1, 0
				for i = 1, #group do g[#g + 1] = group[i] end
			else
				gap = gap + 1
				if not RULES.j_shortcut or gap > 1 then break end
			end
		end
		if ranks >= needed and (straight == nil or #g > #straight) then straight = g end
	end
	local scoring = {}
	local function mark(g)
		for i = 1, #g do
			scoring[g[i]] = true
		end
	end
	local function mark_all()
		for i = 1, n do
			scoring[i] = true
		end
	end
	mark(stones)
	local s1 = list[1] and #list[1].g or 0
	local s2 = list[2] and #list[2].g or 0
	local name
	if s1 == 5 then
		name = flush and "flush_five" or "five"
		mark_all()
	elseif straight and flush then
		name = "straight_flush"
		mark(straight)
		mark(flush)
	elseif s1 == 4 then
		name = "four"
		mark(list[1].g)
	elseif s1 == 3 and s2 >= 2 then
		name = flush and "flush_house" or "full_house"
		mark_all()
	elseif flush then
		name = "flush"
		mark(flush)
	elseif straight then
		name = "straight"
		mark(straight)
	elseif s1 == 3 then
		name = "three"
		mark(list[1].g)
	elseif s1 == 2 and s2 == 2 then
		name = "two_pair"
		mark(list[1].g)
		mark(list[2].g)
	elseif s1 == 2 then
		name = "pair"
		mark(list[1].g)
	else
		name = "high_card"
		if list[1] ~= nil then
			scoring[list[1].g[1]] = true
		end
	end
	if RULES.j_splash then mark_all() end
	return name, scoring
end

-- Hand categories for the fallback ranking (discards sit between 1 and 2).
local CATEGORY = {
	high_card = 1, pair = 2, two_pair = 3, three = 4, straight = 5, flush = 6, full_house = 7,
	four = 8, straight_flush = 9, five = 10, flush_house = 11, flush_five = 12,
}

local function play_score(obs, act)
	local cards = cards_for(obs, act.card_refs)
	if cards == nil or #cards == 0 then
		return nil
	end
	if #cards < MIN_CARDS then
		-- The Psychic's five-card minimum: a short play scores nothing in game,
		-- so it is normally removed from the ranking entirely (docs/
		-- CLAUDE_BATCH3_REVIEW.md M1). The one exception is the exhausted-hand
		-- terminal (PSYCHIC_TERMINAL): a floor below every other score lets the
		-- last undersized cards be played so the round can end (M-A). It makes
		-- no scoring claim and is never reachable while a certified discard or a
		-- five-card play exists (a five-card play needs five cards).
		if PSYCHIC_TERMINAL then
			return -1
		end
		return nil
	end
	if CONF.estimate_plays and PLAY ~= nil then
		local value = PLAY.est[act.id]
		if value ~= nil then
			-- Scaled to this decision's best estimate so late-game values keep
			-- full resolution; strictly increasing in the estimate.
			local scale = PLAY.best or 1000
			if scale < 1000 then
				scale = 1000
			end
			local score = 400000 + 300000 * value / (value + scale)
			if PLAY.remaining ~= nil and value >= PLAY.remaining then
				score = score + 250000
			end
			return score
		end
	end
	-- Category fallback (rule-changing Jokers, absurd sizes, estimate off):
	-- hand category, then the top scoring rank, then the rank sum.
	local name, scoring = classify_scoring(cards)
	if name == nil or blocked_hand(name) then
		-- Unreadable, or a type The Eye / The Mouth blocks: a discard wins.
		return CONF.unknown + 1
	end
	local primary, sum, minimal, bonus, debuffed = 0, 0, 0, 0, 0
	for i = 1, #cards do
		local c = cards[i]
		local rv = (not is_stone(c)) and rank_value(c.rank) or 0
		if c.debuff == true then
			debuffed = debuffed + 1
		else
			sum = sum + rv
			bonus = bonus + center_bonus(c.center) + edition_bonus(c.edition)
		end
		if scoring[i] then
			minimal = minimal + 1
			if rv > primary then
				primary = rv
			end
		end
	end
	local score = CATEGORY[name] * 100000 + primary * 1000 + sum * 2
	score = score - (#cards - minimal) * CONF.play_junk
	score = score + bonus * CONF.enhance_value
	score = score - debuffed * CONF.debuff_penalty
	return score
end

-- Balatro score estimate (public rules): level-1 base chips/mult per hand, the
-- chips of the cards that actually score, visible enhancements, editions and red
-- seals, cards held in hand, and a table of simple Joker effects keyed by the
-- visible Joker center. Only public, displayed facts are used. Scaling Jokers,
-- hand levels and boss effects are unknown and ignored, so this is a relative
-- estimate for choosing between plays, not an exact score.
local HAND_BASE = {
	high_card = { 5, 1 }, pair = { 10, 2 }, two_pair = { 20, 2 }, three = { 30, 3 },
	straight = { 30, 4 }, flush = { 35, 4 }, full_house = { 40, 4 }, four = { 60, 7 },
	straight_flush = { 100, 8 }, five = { 120, 12 }, flush_house = { 140, 14 }, flush_five = { 160, 16 },
}
local CONTAINS = {
	pair = { pair = true, two_pair = true, three = true, full_house = true, four = true, five = true, flush_house = true, flush_five = true },
	two_pair = { two_pair = true, full_house = true, flush_house = true },
	three = { three = true, full_house = true, four = true, five = true, flush_house = true, flush_five = true },
	four = { four = true, five = true, flush_five = true },
	straight = { straight = true, straight_flush = true },
	flush = { flush = true, straight_flush = true, flush_house = true, flush_five = true },
}
local JOKER_EFFECTS = {
	j_blueprint = { "copy", 0 }, j_brainstorm = { "copy", 0 },
	j_four_fingers = { "rule", 0 }, j_shortcut = { "rule", 0 }, j_splash = { "rule", 0 }, j_pareidolia = { "rule", 0 }, j_smeared = { "rule", 0 }, j_joker = { "mult", 4 }, j_misprint = { "mult", 11.5 }, j_gros_michel = { "mult", 15 },
	j_cavendish = { "xmult", 3 }, j_stuntman = { "chips", 250 },
	j_greedy_joker = { "suit_mult", 3, "D" }, j_lusty_joker = { "suit_mult", 3, "H" },
	j_wrathful_joker = { "suit_mult", 3, "S" }, j_gluttenous_joker = { "suit_mult", 3, "C" },
	j_jolly = { "hand_mult", 8, "pair" }, j_zany = { "hand_mult", 12, "three" },
	j_mad = { "hand_mult", 10, "two_pair" }, j_crazy = { "hand_mult", 12, "straight" },
	j_droll = { "hand_mult", 10, "flush" },
	j_sly = { "hand_chips", 50, "pair" }, j_wily = { "hand_chips", 100, "three" },
	j_clever = { "hand_chips", 80, "two_pair" }, j_devious = { "hand_chips", 100, "straight" },
	j_crafty = { "hand_chips", 80, "flush" },
	j_duo = { "hand_xmult", 2, "pair" }, j_trio = { "hand_xmult", 3, "three" },
	j_family = { "hand_xmult", 4, "four" }, j_order = { "hand_xmult", 3, "straight" },
	j_tribe = { "hand_xmult", 2, "flush" },
	j_half = { "half", 20 }, j_scary_face = { "face_chips", 30 }, j_smiley = { "face_mult", 5 },
	j_even_steven = { "even_mult", 4 }, j_odd_todd = { "odd_chips", 31 }, j_scholar = { "ace" },
	j_fibonacci = { "fib_mult", 8 }, j_walkie_talkie = { "walkie" }, j_triboulet = { "kq_xmult", 2 },
	j_abstract = { "abstract", 3 }, j_baron = { "held_king" }, j_shoot_the_moon = { "held_queen", 13 },
	j_photograph = { "photo" },
}

-- Joker-level effect kinds by order sensitivity (per-card effects apply
-- during card scoring, before any of these).
local ADDITIVE = { mult = true, chips = true, hand_mult = true, hand_chips = true, half = true, abstract = true }
local MULTIPLICATIVE = { xmult = true, hand_xmult = true }

-- Scaling Jokers grow over a run, so their current value is not visible when
-- offered. For shop and pack valuation only (never play estimates), an offered
-- one is priced as a conservative mid-life effect from its public card text.
-- Only Jokers that grow from what this policy actually does (plays, discards,
-- rerolls, planets) are listed. Throwback, Red Card, Campfire, Obelisk and
-- Lucky Cat grow from actions it never takes; Vampire strips enhancements the
-- estimate values. The built-up bonus of Spare Trousers and Runner applies to
-- every hand.
local SCALING = {
	j_green_joker = { "mult", 3 }, j_ride_the_bus = { "mult", 5 }, j_supernova = { "mult", 4 },
	j_flash = { "mult", 2 }, j_trousers = { "mult", 4 }, j_runner = { "chips", 30 },
	j_wee = { "chips", 24 }, j_castle = { "chips", 30 }, j_square = { "chips", 8 },
	j_hologram = { "xmult", 1.15 }, j_constellation = { "xmult", 1.3 },
}
-- Owned scaling Jokers use the value their card shows (`current`, from the
-- trusted pipeline; xmult in hundredths). These also grow while the hand
-- scores, before Jokers apply: Ride the Bus resets on a scoring face card.
local GROW = {
	j_ride_the_bus = "ride", j_green_joker = "each", j_trousers = "two_pair", j_runner = "straight",
	j_square = "four_cards", j_wee = "twos",
}

local function effect_of(j)
	local e = JOKER_EFFECTS[j.center] or (j.offered and j.proxy)
	if e then
		return e
	end
	local c = j.current
	if type(c) ~= "table" then
		return nil
	end
	e = CURRENT_EFF[j]
	if e == nil then
		e = { c.kind, c.kind == "xmult" and c.value / 100 or c.value, nil, GROW[j.center], c.step or 0 }
		CURRENT_EFF[j] = e
	end
	return e
end

-- Known scoring effects are native Blueprint-compatible (pinned by tests).
-- Resolve only the visible own row, with a hard bound for copy cycles. Rule
-- Jokers are incompatible, and copied editions belong to the copier itself.
local function copied_effect(jokers, index)
	for _ = 1, #jokers do
		local j = jokers[index]
		if type(j) ~= "table" or j.redacted == true or j.debuff == true then return nil end
		if j.center == "j_blueprint" then index = index + 1
		elseif j.center == "j_brainstorm" then index = 1
		else
			local e = effect_of(j)
			return e and e[1] ~= "rule" and e or nil
		end
	end
	return nil
end

-- Joker kinds that score face cards: they reset Ride the Bus.
local FACE_KINDS = { face_chips = true, face_mult = true, photo = true, kq_xmult = true }

-- Estimates are clamped here (also NaN), far above any meaningful score.
local ESTIMATE_CAP = 1e15
-- Draw-aware discard search: at most this many candidates, best cheap
-- heuristic first, while WORK stays under DISCARD_WORK (measured worst cases
-- in docs/BASELINE_POLICY.md).
local DISCARD_EV_LIMIT = 40
local DISCARD_WORK = 24000
local PLAY_WORK = 24000
-- Absolute cap on play plus discard work in one decision (review N2): the
-- discard share is also cut when the play estimate already used a lot.
local TOTAL_WORK = 30000
-- Estimate-based Joker ordering is limited to small Joker rows and a bounded
-- number of candidates per decision, so it always fits the sandbox budget.
local REORDER_EST_MAX_JOKERS = 8
local REORDER_EST_LIMIT = 20

local function card_chip_value(rv)
	if rv == 14 then
		return 11
	end
	if rv >= 11 then
		return 10
	end
	return rv
end



-- Expected score of playing `played` while `held` stays in hand. `jokers` is
-- the ordered visible Joker list, or nil to ignore Jokers.
local function estimate(played, held, jokers)
	local name, scoring = classify_scoring(played)
	if name == nil then
		return nil
	end
	local base = HAND_BASE[name]
	local chips = base[1]
	local mult = base[2]
	if LEVELS ~= nil then
		local level = LEVELS[name]
		if type(level) == "table" and type(level.chips) == "number" and type(level.mult) == "number" then
			chips = level.chips
			mult = level.mult
		end
	end
	if FLINT then
		chips = math.max(0, math.floor(chips * 0.5 + 0.5))
		mult = math.max(1, math.floor(mult * 0.5 + 0.5))
	end
	local cached = jokers ~= nil and JOKER_CACHE[jokers] or nil
	local effects, joker_count, copy_work
	if cached then
		effects, joker_count, copy_work = cached[1], cached[2], cached[3]
	else
		effects = {}
		joker_count, copy_work = 0, 0
		if jokers ~= nil then
			for i = 1, #jokers do
				local j = jokers[i]
				if type(j) == "table" then
					-- Abstract Joker counts every Joker, debuffed ones included.
					joker_count = joker_count + 1
				end
				if type(j) == "table" and j.debuff ~= true and j.redacted ~= true then
					local e = effect_of(j)
					if e and e[1] == "copy" then
						-- Reserve optional-search work for copy routing and value resolution.
						copy_work = copy_work + 12
						e = copied_effect(jokers, i)
					end
					if e ~= nil then
						effects[#effects + 1] = { e = e, edition = j.edition }
					else
						effects[#effects + 1] = { e = false, edition = j.edition }
					end
				end
			end
		end
		if jokers ~= nil then JOKER_CACHE[jokers] = { effects, joker_count, copy_work } end
	end
	local face_scored, twos = false, 0
	-- Photograph: x2 whenever the first scoring face card scores (each retrigger).
	local photo_index = nil
	for i = 1, #played do
		local c = played[i]
		local rv = (not is_stone(c)) and rank_value(c.rank) or nil
		if photo_index == nil and scoring[i] and c.debuff ~= true and (RULES.j_pareidolia or (rv ~= nil and rv >= 11 and rv <= 13)) then
			photo_index = i
		end
	end
	for i = 1, #played do
		local c = played[i]
		if scoring[i] and c.debuff ~= true then
			local reps = (c.seal == "Red" or c.seal == "red") and 2 or 1
			local rv = nil
			if not is_stone(c) then
				rv = rank_value(c.rank)
			end
			local sk = suit_key(c.suit)
			if rv == 2 then twos = twos + reps end
			if RULES.j_pareidolia or (rv ~= nil and rv >= 11 and rv <= 13) then face_scored = true end
			for _ = 1, reps do
				if rv ~= nil then
					chips = chips + card_chip_value(rv)
				end
				local center = c.center
				-- Enhancement first (Lucky: 1 in 5 for +20 mult = +4 expected),
				-- then Glass (its projected effective own-card multiplier, x1.5
				-- under Standard and x2 under vanilla/Major League), then the
				-- card's edition.
				if type(c.bonus_chips) == "number" then
					chips = chips + c.bonus_chips
				end
				if center == "m_bonus" and c.bonus_chips == nil then
					chips = chips + 30
				elseif center == "m_mult" then
					mult = mult + 4
				elseif center == "m_stone" and c.bonus_chips == nil then
					chips = chips + 50
				elseif center == "m_lucky" then
					mult = mult + 4
				elseif center == "m_glass" then
					-- M4: the effective own-card multiplier (Standard 1.5,
					-- vanilla/Major League 2), never a hardcoded constant.
					mult = mult * glass_xmult(c)
				end
				if c.edition == "foil" then
					chips = chips + 50
				elseif c.edition == "holo" then
					mult = mult + 10
				elseif c.edition == "polychrome" then
					mult = mult * 1.5
				end
				local face = (RULES.j_pareidolia or (rv ~= nil and rv >= 11 and rv <= 13))
				for k = 1, #effects do
					local e = effects[k].e
					if e then
						local kind = e[1]
						if kind == "suit_mult" and rv ~= nil and (sk == merge_suit(e[3]) or center == "m_wild") then
							mult = mult + e[2]
						elseif kind == "face_chips" and face then
							chips = chips + e[2]
						elseif kind == "face_mult" and face then
							mult = mult + e[2]
						elseif kind == "even_mult" and rv ~= nil and rv <= 10 and rv %% 2 == 0 then
							mult = mult + e[2]
						elseif kind == "odd_chips" and rv ~= nil and (rv == 14 or (rv <= 9 and rv %% 2 == 1)) then
							chips = chips + e[2]
						elseif kind == "ace" and rv == 14 then
							chips = chips + 20
							mult = mult + 4
						elseif kind == "fib_mult" and (rv == 14 or rv == 2 or rv == 3 or rv == 5 or rv == 8) then
							mult = mult + e[2]
						elseif kind == "walkie" and (rv == 10 or rv == 4) then
							chips = chips + 10
							mult = mult + 4
						elseif kind == "kq_xmult" and (rv == 13 or rv == 12) then
							mult = mult * e[2]
						elseif kind == "photo" and i == photo_index then
							mult = mult * 2
						end
					end
				end
			end
		end
	end
	if held ~= nil then
		for i = 1, #held do
			local c = held[i]
			if type(c) == "table" and c.redacted ~= true and c.debuff ~= true then
				local reps = (c.seal == "Red" or c.seal == "red") and 2 or 1
				local rv = nil
				if not is_stone(c) then
					rv = rank_value(c.rank)
				end
				for _ = 1, reps do
					if c.center == "m_steel" then
						mult = mult * 1.5
					end
					for k = 1, #effects do
						local e = effects[k].e
						if e and e[1] == "held_king" and rv == 13 then
							mult = mult * 1.5
						elseif e and e[1] == "held_queen" and rv == 12 then
							mult = mult + e[2]
						end
					end
				end
			end
		end
	end
	for k = 1, #effects do
		local e = effects[k].e
		local edition = effects[k].edition
		if edition == "foil" then
			chips = chips + 50
		elseif edition == "holo" then
			mult = mult + 10
		end
		if e then
			local kind = e[1]
			if kind == "mult" or kind == "chips" or kind == "xmult" then
				local v = e[2]
				local r = e[4]
				if r == "ride" then
					v = face_scored and 0 or v + e[5]
				elseif r == "twos" then
					v = v + e[5] * twos
				elseif r == "each" or (r == "two_pair" and CONTAINS.two_pair[name]) or (r == "straight" and CONTAINS.straight[name])
					or (r == "four_cards" and #played == 4) then
					v = v + e[5]
				end
				if kind == "mult" then
					mult = mult + v
				elseif kind == "chips" then
					chips = chips + v
				else
					mult = mult * v
				end
			elseif kind == "hand_mult" and CONTAINS[e[3]][name] then
				mult = mult + e[2]
			elseif kind == "hand_chips" and CONTAINS[e[3]][name] then
				chips = chips + e[2]
			elseif kind == "hand_xmult" and CONTAINS[e[3]][name] then
				mult = mult * e[2]
			elseif kind == "half" and #played <= 3 then
				mult = mult + e[2]
			elseif kind == "abstract" then
				mult = mult + e[2] * joker_count
			end
		end
		if edition == "polychrome" then
			mult = mult * 1.5
		end
	end
	WORK = WORK + (#played + (held ~= nil and #held or 0)) * (#effects + 2) + copy_work
	if BALANCED then
		-- Plasma balances after all scoring effects, flooring each half.
		local half = math.floor((chips + mult) / 2)
		return half * half, name
	end
	return chips * mult, name
end

-- Parse a displayed integer ("1200", "1,200", "1.2e5"); nil if unreadable.
local function display_number(text)
	if type(text) ~= "string" or #text == 0 or #text > 32 then
		return nil
	end
	local cleaned = string.gsub(text, ",", "")
	if string.find(cleaned, "^[0-9]+$") == nil and string.find(cleaned, "^[0-9]+%%.?[0-9]*e%%+?[0-9]+$") == nil then
		return nil
	end
	return tonumber(cleaned)
end


local function held_after(hand, refs)
	local used = {}
	for i = 1, #refs do
		used[refs[i]] = true
	end
	local out = {}
	for i = 1, #hand do
		local c = hand[i]
		if type(c) == "table" and not used[c.id] then
			out[#out + 1] = c
		end
	end
	return out
end

-- Draw-aware discard evaluation (analytic "outs", deterministic). Unseen cards
-- follow public initial-deck priors minus the visible hand. These are
-- approximate; no deck order or hidden deck contents are consulted.
local function choose(n, k)
	if k < 0 or k > n then
		return 0
	end
	local r = 1
	for i = 1, k do
		r = r * (n - k + i) / i
	end
	return r
end

-- P(at least `need` successes) drawing `draws` from `pool` holding `good`.
local function p_at_least(need, draws, good, pool)
	if need <= 0 then
		return 1
	end
	if pool <= 0 then
		return 0
	end
	if good > pool then
		good = pool
	end
	if draws > pool then
		draws = pool
	end
	if need > draws or good < need then
		return 0
	end
	local total = choose(pool, draws)
	if total <= 0 then
		return 0
	end
	local p = 0
	for x = need, draws do
		p = p + choose(good, x) * choose(pool - good, draws - x) / total
	end
	if p > 1 then
		p = 1
	end
	return p
end

local SUIT_NAMES = { H = "Hearts", D = "Diamonds", C = "Clubs", S = "Spades" }
local RANK_NAMES = { [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8",
	[9] = "9", [10] = "10", [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace" }

-- Best estimated play among `cards` (<= 8) from its structural candidates:
-- rank groups (with a second group for two pair / full house), the top five of
-- a suit, five-rank straights and the single high card.
local function best_play(cards, jokers)
	local best = 0
	local function try(list)
		if #list == 0 or #list > 5 or #list < MIN_CARDS then
			return
		end
		local held = {}
		local used = {}
		for i = 1, #list do
			used[list[i]] = true
		end
		for i = 1, #cards do
			if not used[cards[i]] then
				held[#held + 1] = cards[i]
			end
		end
		local value, name = estimate(list, held, jokers)
		if value ~= nil and value > best and not blocked_hand(name) then
			best = value
		end
	end
	local by_rank = {}
	local by_suit = {}
	local top = nil
	local top_rv = 0
	for i = 1, #cards do
		local c = cards[i]
		local rv = rank_value(c.rank)
		local sk = suit_key(c.suit)
		if rv ~= nil and not is_stone(c) then
			by_rank[rv] = by_rank[rv] or {}
			local g = by_rank[rv]
			g[#g + 1] = c
			if rv > top_rv then
				top_rv = rv
				top = c
			end
		end
		if sk ~= nil and not is_stone(c) then
			by_suit[sk] = by_suit[sk] or {}
			local g = by_suit[sk]
			g[#g + 1] = c
		end
	end
	if top ~= nil then
		try({ top })
	end
	local groups = {}
	for rv = 14, 2, -1 do
		local g = by_rank[rv]
		if g ~= nil and #g >= 2 then
			groups[#groups + 1] = g
		end
	end
	for a = 1, #groups do
		local ga = groups[a]
		local one = {}
		for i = 1, #ga do
			if i <= 5 then
				one[#one + 1] = ga[i]
			end
		end
		try(one)
		for b = a + 1, #groups do
			local both = {}
			for i = 1, #one do
				both[#both + 1] = one[i]
			end
			local gb = groups[b]
			for i = 1, #gb do
				if #both < 5 then
					both[#both + 1] = gb[i]
				end
			end
			try(both)
		end
	end
	for _, g in pairs(by_suit) do
		if #g >= (RULES.j_four_fingers and 4 or 5) then
			local sorted = {}
			for i = 1, #g do
				sorted[i] = g[i]
			end
			table.sort(sorted, function(x, y)
				local rx, ry = rank_value(x.rank) or 0, rank_value(y.rank) or 0
				if rx ~= ry then
					return rx > ry
				end
				return byte_less(x.id or "", y.id or "")
			end)
			local play = {}
			for i = 1, math.min(5, #sorted) do play[i] = sorted[i] end
			try(play)
		end
	end
	for low = 1, 14 do
		local run, gap = {}, 0
		for v = low, 14 do
			local g = by_rank[v == 1 and 14 or v]
			if g ~= nil then
				run[#run + 1], gap = g[1], 0
				if #run >= (RULES.j_four_fingers and 4 or 5) then try(run) end
				if #run == 5 then break end
			else
				gap = gap + 1
				if not RULES.j_shortcut or gap > 1 then break end
			end
		end
	end
	return best
end

local function synthetic(rank, suit)
	return { kind = "card", rank = RANK_NAMES[rank], suit = SUIT_NAMES[suit], center = "c_base", id = "draw" }
end

-- Public initial-deck priors only: never inspect unseen cards or draw order.
-- Deck changes, depletion and added/removed cards make these approximate.
local function rank_stock(rv)
	return DRAW_PROFILE == "abandoned" and rv >= 11 and rv <= 13 and 0 or 4
end
local function suit_stock(sk)
	if DRAW_PROFILE == "checkered" then return (sk == "H" or sk == "S") and 26 or 0 end
	return (DRAW_PROFILE == "abandoned" and 10 or 13) * (SMEARED and 2 or 1)
end

-- Expected best play after discarding `discard_refs` and drawing the same
-- number of cards: the current best of the kept cards, improved by the most
-- valuable reachable target (flush, better rank group, straight) weighted by
-- its hypergeometric chance.
local function discard_ev(obs, discard_refs, jokers, need)
	local s = obs.self
	local hand = s.hand
	local drop = {}
	for i = 1, #discard_refs do
		drop[discard_refs[i]] = true
	end
	local kept = {}
	local seen_rank = {}
	local seen_suit = {}
	for i = 1, #hand do
		local c = hand[i]
		if type(c) == "table" and c.redacted ~= true then
			local rv = rank_value(c.rank)
			local sk = suit_key(c.suit)
			if rv ~= nil then
				seen_rank[rv] = (seen_rank[rv] or 0) + 1
			end
			if sk ~= nil then
				seen_suit[sk] = (seen_suit[sk] or 0) + 1
			end
			if not drop[c.id] then
				kept[#kept + 1] = c
			end
		end
	end
	local d = #discard_refs
	-- Structural search cost that estimate does not charge.
	WORK = WORK + #kept * (110 + 20 * d)
	local pool = (DRAW_PROFILE == "abandoned" and 40 or 52) - #hand
	local deck = s.deck
	if type(deck) == "table" and type(deck.total) == "number" and deck.total > 0 and deck.total < pool then
		pool = deck.total
	end
	local base = best_play(kept, jokers)
	local ev = base
	-- Chance that the follow-up play reaches `need` (last-hand ranking).
	local p_clear = 0
	if need ~= nil and base >= need then
		p_clear = 1
	end
	-- Kept cards whose effect applies while held (Steel; Kings with Baron;
	-- Queens with Shoot the Moon), so targets are priced like the current best
	-- play. Other held cards add nothing and are left out for the budget.
	local baron, moon = false, false
	if jokers ~= nil then
		for i = 1, #jokers do
			local j = jokers[i]
			if type(j) == "table" and j.debuff ~= true then
				baron = baron or j.center == "j_baron"
				moon = moon or j.center == "j_shoot_the_moon"
			end
		end
	end
	-- Suits an owned suit Joker rewards: an imagined drawn card avoids them
	-- where it can, so a random draw is not priced as a bonus suit.
	local bonus = {}
	if jokers ~= nil then
		for i = 1, #jokers do
			local j = jokers[i]
			local je = type(j) == "table" and j.debuff ~= true and JOKER_EFFECTS[j.center] or nil
			if je ~= nil and je[1] == "suit_mult" then
				bonus[merge_suit(je[3])] = true
			end
		end
	end
	local neutral = "S"
	for _, sk in ipairs({ "S", "C", "H", "D" }) do
		if suit_stock(sk) > 0 and not bonus[sk] then
			neutral = sk
			break
		end
	end
	local held_fx = {}
	for i = 1, #kept do
		local c = kept[i]
		local rv = (not is_stone(c)) and rank_value(c.rank) or nil
		if c.center == "m_steel" or (baron and rv == 13) or (moon and rv == 12) then
			held_fx[#held_fx + 1] = c
		end
	end
	-- `play` is the exact target play (kept cards plus synthetic draws), priced
	-- with the effect-bearing kept cards it leaves in hand.
	local function consider(p, play)
		if p <= 0 or #play == 0 or #play > 5 or #play < MIN_CARDS then
			return
		end
		local held = nil
		if #held_fx > 0 then
			local in_play = {}
			for i = 1, #play do
				in_play[play[i]] = true
			end
			held = {}
			for i = 1, #held_fx do
				if not in_play[held_fx[i]] then
					held[#held + 1] = held_fx[i]
				end
			end
		end
		local value, name = estimate(play, held, jokers)
		if value == nil or blocked_hand(name) then
			return
		end
		local candidate = p * value + (1 - p) * base
		if candidate > ev then
			ev = candidate
		end
		if need ~= nil and value >= need and p > p_clear then
			p_clear = p
		end
	end
	local function kept_where(test, limit)
		local out = {}
		for i = 1, #kept do
			local c = kept[i]
			if not is_stone(c) and test(c) then
				out[#out + 1] = c
			end
		end
		table.sort(out, function(x, y)
			local rx, ry = rank_value(x.rank) or 0, rank_value(y.rank) or 0
			if rx ~= ry then
				return rx > ry
			end
			return byte_less(x.id or "", y.id or "")
		end)
		while #out > limit do
			out[#out] = nil
		end
		return out
	end
	-- Flush: complete a suit.
	local kept_suit = {}
	local kept_rank = {}
	for i = 1, #kept do
		local c = kept[i]
		local sk = suit_key(c.suit)
		local rv = rank_value(c.rank)
		if sk ~= nil and not is_stone(c) then
			kept_suit[sk] = (kept_suit[sk] or 0) + 1
		end
		if rv ~= nil and not is_stone(c) then
			kept_rank[rv] = (kept_rank[rv] or 0) + 1
		end
	end
	local suits = { "H", "D", "C", "S" }
	for k = 1, 4 do
		local sk = suits[k]
		local have = kept_suit[sk] or 0
		local target = RULES.j_four_fingers and 4 or 5
		local need = target - have
		if have >= 2 and need >= 1 and need <= d then
			local play = kept_where(function(c)
				return suit_key(c.suit) == sk
			end, 5)
			-- Fillers: ranks nobody kept, so they cannot also make a pair or
			-- better than the flush being priced.
			local filler = 3
			for _ = 1, need do
				while filler <= 14 and ((kept_rank[filler] or 0) > 0 or rank_stock(filler) == 0) do
					filler = filler + 1
				end
				play[#play + 1] = synthetic(filler <= 14 and filler or 8, sk)
				filler = filler + 2
			end
			consider(p_at_least(need, d, suit_stock(sk) - (seen_suit[sk] or 0), pool), play)
		end
	end
	-- Rank groups: one more of a kept rank (pair -> three, three -> four,
	-- a lone high card -> pair).
	for rv = 2, 14 do
		local have = kept_rank[rv] or 0
		if have >= 1 and d >= 1 then
			local outs = rank_stock(rv) - (seen_rank[rv] or 0)
			if outs > 0 and have <= 3 then
				local play = kept_where(function(c)
					return rank_value(c.rank) == rv
				end, 4)
				play[#play + 1] = synthetic(rv, neutral)
				consider(p_at_least(1, d, outs, pool), play)
			end
		end
	end
	-- Drawn straight cards take a suit none of the kept cards share, so a
	-- straight target is never priced as a straight flush.
	local fill_suit = DRAW_PROFILE == "checkered" and "H" or "D"
	local fill_rank = 0
	for _, candidate_suit in ipairs({ "D", "C", "H", "S" }) do
		-- Prefer a suit no kept card shares, then one no suit Joker rewards.
		local r = ((kept_suit[merge_suit(candidate_suit)] or 0) == 0 and 2 or 0) + (bonus[merge_suit(candidate_suit)] and 0 or 1)
		if suit_stock(candidate_suit) > 0 and r > fill_rank then
			fill_suit = candidate_suit
			fill_rank = r
		end
	end
	-- Straights missing exactly one rank (open or gutshot).
	if d >= 1 then
		for low = 1, 10 do
			local missing = nil
			local count = 0
			for v = low, low + 4 do
				local rv = v
				if v == 1 then
					rv = 14
				end
				if (kept_rank[rv] or 0) > 0 then
					count = count + 1
				else
					missing = rv
				end
			end
			if count == 4 and missing ~= nil then
				local outs = rank_stock(missing) - (seen_rank[missing] or 0)
				if outs > 0 then
					local play = {}
					for v = low, low + 4 do
						local rv = v
						if v == 1 then
							rv = 14
						end
						if rv == missing then
							play[#play + 1] = synthetic(missing, fill_suit)
						else
							local picked = kept_where(function(c)
								return rank_value(c.rank) == rv
							end, 1)
							play[#play + 1] = picked[1]
						end
					end
					consider(p_at_least(1, d, outs, pool), play)
				end
			end
		end
	end
	if CONF.deep_draws and d >= 1 then
		-- Two pair -> full house: one more of either pair rank.
		local pair_ranks = {}
		for rv = 14, 2, -1 do
			if (kept_rank[rv] or 0) == 2 then
				pair_ranks[#pair_ranks + 1] = rv
			end
		end
		if #pair_ranks >= 2 then
			local a, b = pair_ranks[1], pair_ranks[2]
			local outs = (rank_stock(a) - (seen_rank[a] or 0)) + (rank_stock(b) - (seen_rank[b] or 0))
			if outs > 0 then
				local play = kept_where(function(c)
					local rv = rank_value(c.rank)
					return rv == a or rv == b
				end, 4)
				play[#play + 1] = synthetic(a, neutral)
				consider(p_at_least(1, d, outs, pool), play)
			end
		end
		-- Straights missing two ranks: both must arrive.
		if d >= 2 then
			for low = 1, 10 do
				local missing = {}
				local count = 0
				for v = low, low + 4 do
					local rv = v
					if v == 1 then
						rv = 14
					end
					if (kept_rank[rv] or 0) > 0 then
						count = count + 1
					else
						missing[#missing + 1] = rv
					end
				end
				if count == 3 and #missing == 2 then
					local outs_a = rank_stock(missing[1]) - (seen_rank[missing[1]] or 0)
					local outs_b = rank_stock(missing[2]) - (seen_rank[missing[2]] or 0)
					if outs_a > 0 and outs_b > 0 and pool >= d then
						-- Exact: P(>=1 of each) by inclusion-exclusion.
						local total = choose(pool, d)
						local p = 0
						if total > 0 then
							p = 1 - choose(pool - outs_a, d) / total - choose(pool - outs_b, d) / total
								+ choose(pool - outs_a - outs_b, d) / total
						end
						if p < 0 then
							p = 0
						end
						local play = {}
						for v = low, low + 4 do
							local rv = v
							if v == 1 then
								rv = 14
							end
							if rv == missing[1] or rv == missing[2] then
								play[#play + 1] = synthetic(rv, fill_suit)
							else
								play[#play + 1] = kept_where(function(c)
									return rank_value(c.rank) == rv
								end, 1)[1]
							end
						end
						consider(p, play)
					end
				end
			end
		end
	end
	return ev, p_clear
end

local function hand_aggregates(hand)
	if type(hand) ~= "table" then
		return nil, nil
	end
	local counts = {}
	local suitc = {}
	local m = #hand
	for i = 1, m do
		local c = hand[i]
		if type(c) == "table" and c.redacted ~= true then
			local rv = rank_value(c.rank)
			local sk = suit_key(c.suit)
			if rv ~= nil and sk ~= nil then
				counts[rv] = (counts[rv] or 0) + 1
				suitc[sk] = (suitc[sk] or 0) + 1
			end
		end
	end
	return counts, suitc
end

local function discard_score(obs, act)
	local state = obs.self
	if type(state) == "table" and state.hands == 0 then
		return nil
	end
	local refs = act.card_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	local cards = cards_for(obs, refs)
	if cards == nil then
		return nil
	end
	local hand = nil
	local s = obs.self
	if type(s) == "table" then
		hand = s.hand
	end
	local counts, suitc = hand_aggregates(hand)
	local score = CONF.discard_base
	if counts == nil then
		return score
	end
	local m = #cards
	for i = 1, m do
		local c = cards[i]
		if type(c) == "table" and c.redacted ~= true then
			local rv = rank_value(c.rank)
			local sk = suit_key(c.suit)
			if rv ~= nil and sk ~= nil then
				if c.debuff == true then
					score = score + CONF.discard_debuff_bonus
				else
					if (counts[rv] or 0) >= 2 then
						score = score - CONF.discard_pair_pen
					end
					if (suitc[sk] or 0) >= 4 then
						score = score - CONF.discard_flush_pen
					end
					if in_run(counts, rv) then
						score = score - CONF.discard_straight_pen
					end
					if c.seal ~= nil or c.edition ~= nil then
						score = score - CONF.discard_seal_pen
					elseif type(c.center) == "string" and string.sub(c.center, 1, 2) == "m_" then
						score = score - CONF.discard_seal_pen
					else
						score = score + CONF.discard_junk
					end
				end
			end
		end
	end
	local cap = CONF.discard_base + CONF.discard_cap_bonus
	if score > cap then
		score = cap
	end
	return score
end

local function analyse_plays(obs, actions, count)
	local info = {
		est = {}, best = nil, remaining = nil, clears = false, discard_mode = false,
		-- Per-decision Joker-order budget (see reorder_score).
		reorders_left = REORDER_EST_LIMIT, panel_now = nil,
	}
	local s = obs.self
	if type(s) ~= "table" or type(s.hand) ~= "table" then
		return info
	end
	local jokers = nil
	if CONF.est_jokers then
		jokers = s.jokers
	end
	-- Projected estimate cost; past PLAY_WORK (only absurd hand and Joker
	-- counts) keep the category ranking rather than risk the budget.
	local plays = 0
	for i = 1, count do
		local a = actions[i]
		if type(a) == "table" and a.type == "PLAY_CARDS" then
			plays = plays + 1
		end
	end
	if plays * #s.hand * ((type(jokers) == "table" and #jokers or 0) + 2) > PLAY_WORK then
		return info
	end
	local best = nil
	local best_name = nil
	for i = 1, count do
		local a = actions[i]
		if type(a) == "table" and a.type == "PLAY_CARDS" then
			local cards = cards_for(obs, a.card_refs)
			if cards ~= nil and #cards > 0 then
				local value, name = estimate(cards, held_after(s.hand, a.card_refs), jokers)
				if value ~= nil and (value ~= value or value >= ESTIMATE_CAP) then
					value = ESTIMATE_CAP
				end
				if #cards < MIN_CARDS or (value ~= nil and blocked_hand(name)) then
					-- The Psychic: fewer than 5 cards; The Eye / The Mouth: a
					-- blocked hand type. Either scores nothing.
					value = 0
				end
				if value ~= nil then
					info.est[a.id] = value
					if best == nil or value > best then
						best = value
						best_name = name
					end
				end
			end
		end
	end
	info.best = best
	if CONF.use_requirement and obs.phase ~= "MULTIPLAYER_PVP" then
		local need = display_number(s.blind_requirement)
		local have = display_number(s.current_score) or 0
		if need ~= nil and need > 0 then
			info.remaining = need - have
		end
	end
	if best ~= nil and info.remaining ~= nil and best >= info.remaining then
		info.clears = true
	end
	local discards = s.discards
	local hands = s.hands
	local can_discard = type(discards) == "number" and discards > 0 and type(hands) == "number" and hands > 0
	-- Draw-aware discards stay inside the instruction budget: skipped for very
	-- large hands; otherwise candidates are ranked by the cheap per-card
	-- heuristic (id breaks ties) and the best ones are evaluated until
	-- DISCARD_EV_LIMIT candidates or the DISCARD_WORK share of WORK is used.
	if CONF.discard_ev and DRAW_PROFILE ~= "unknown" and can_discard and not info.clears and #s.hand <= 12 then
		info.discard_ev = {}
		info.last_hand = hands == 1 and info.remaining ~= nil
		local need = nil
		if info.last_hand then
			need = info.remaining
			info.discard_clear = {}
		end
		local ranked = {}
		for i = 1, count do
			local a = actions[i]
			if type(a) == "table" and a.type == "DISCARD_CARDS" and type(a.card_refs) == "table" then
				local h = discard_score(obs, a)
				if h ~= nil then
					ranked[#ranked + 1] = { a = a, h = h, id = type(a.id) == "string" and a.id or "" }
				end
			end
		end
		table.sort(ranked, function(x, y)
			if x.h ~= y.h then
				return x.h > y.h
			end
			return byte_less(x.id, y.id)
		end)
		local best_ev = nil
		local limit = WORK + DISCARD_WORK
		if limit > TOTAL_WORK then
			limit = TOTAL_WORK
		end
		for i = 1, #ranked do
			local a = ranked[i].a
			if i <= DISCARD_EV_LIMIT and WORK < limit then
				local value, p_clear = discard_ev(obs, a.card_refs, jokers, need)
				info.discard_ev[a.id] = value
				if info.discard_clear ~= nil then
					info.discard_clear[a.id] = p_clear
				end
				if best_ev == nil or value > best_ev then
					best_ev = value
				end
			end
		end
		info.best_discard_ev = best_ev
	end
	if best ~= nil and not info.clears and can_discard then
		if best == 0 then
			-- Every play scores nothing (a blocked type under The Eye / The
			-- Mouth, or The Psychic): discard even without a requirement.
			info.discard_mode = true
		elseif best_name == "high_card" then
			info.discard_mode = true
		elseif info.remaining ~= nil and hands == 1 then
			-- Last hand and nothing clears: improving is the only chance.
			info.discard_mode = true
		elseif info.remaining ~= nil and best * hands * 100 < info.remaining * CONF.discard_need_pct then
			info.discard_mode = true
		elseif info.best_discard_ev ~= nil and info.best_discard_ev * 100 > best * CONF.discard_gain_pct then
			-- Drawing is expected to beat the best play now by a clear margin.
			info.discard_mode = true
		end
	end
	return info
end

local function spendable(obs)
	local s = obs.self
	if type(s) ~= "table" then
		return nil
	end
	local money = s.money
	local credit = s.credit_limit
	if type(money) ~= "number" then
		money = 0
	end
	if type(credit) ~= "number" then
		credit = 0
	end
	return money + credit
end

local function economy_bonus(left)
	if type(left) ~= "number" then
		return 0
	end
	local interest = math.floor(left / 5)
	if interest > INTEREST_CAP then
		interest = INTEREST_CAP
	end
	if interest < 0 then
		interest = 0
	end
	local bonus = interest * CONF.interest_value
	if left < CONF.reserve then
		bonus = bonus - (CONF.reserve - left) * 10
	end
	return bonus
end

-- Marginal value of a shop Joker: how much it raises the estimated score of a
-- fixed, deterministic panel of representative hands (weighted towards pairs),
-- given the Jokers already owned and the displayed hand levels. Only visible
-- shop and owned-Joker centers are used. Returns a ratio (0.5 = +50%%).
local PANEL = nil

local function panel_hands()
	if PANEL ~= nil then
		return PANEL
	end
	local function c(rank, suit)
		return { kind = "card", rank = rank, suit = suit, center = "c_base", id = "panel" }
	end
	PANEL = {
		{ w = 4, play = { c("King", "Spades"), c("King", "Hearts") }, held = { c("7", "Clubs"), c("Queen", "Diamonds"), c("9", "Spades") } },
		{ w = 2, play = { c("Queen", "Spades"), c("Queen", "Diamonds"), c("8", "Clubs"), c("8", "Hearts") }, held = { c("3", "Spades") } },
		{ w = 1, play = { c("7", "Spades"), c("7", "Hearts"), c("7", "Clubs") }, held = { c("King", "Diamonds") } },
		{ w = 1, play = { c("2", "Hearts"), c("5", "Hearts"), c("8", "Hearts"), c("Jack", "Hearts"), c("King", "Hearts") }, held = {} },
		{ w = 1, play = { c("6", "Clubs"), c("7", "Diamonds"), c("8", "Spades"), c("9", "Hearts"), c("10", "Clubs") }, held = {} },
		{ w = 1, play = { c("Ace", "Spades") }, held = { c("4", "Hearts"), c("6", "Clubs") } },
	}
	if DRAW_PROFILE == "abandoned" or DRAW_PROFILE == "checkered" then
		for _, hand in ipairs(PANEL) do
			for _, cards in ipairs({ hand.play, hand.held }) do
				for _, card in ipairs(cards) do
					if DRAW_PROFILE == "abandoned" then
						card.rank = card.rank == "King" and "10" or (card.rank == "Queen" and "9" or (card.rank == "Jack" and "6" or card.rank))
					else
						card.suit = card.suit == "Clubs" and "Spades" or (card.suit == "Diamonds" and "Hearts" or card.suit)
					end
				end
			end
		end
		if DRAW_PROFILE == "checkered" then PANEL[1].w, PANEL[4].w = 2, 4 end
	end
	return PANEL
end

-- Weighted panel score for an ordered Joker list (nil Jokers = none).
local function panel_total(jokers)
	local previous = RULES
	set_rules(jokers)
	local total = 0
	local panel = panel_hands()
	for i = 1, #panel do
		local hand = panel[i]
		total = total + hand.w * (estimate(hand.play, hand.held, jokers) or 0)
	end
	RULES = previous
	SMEARED = RULES.j_smeared == true
	return total
end

local PINNED = {
	j_blueprint = true,
	j_brainstorm = true,
	j_misprint = true,
}

local function joker_pinned(joker)
	if type(joker) ~= "table" or joker.redacted == true or joker.debuff == true then
		return true
	end
	local center = joker.center
	if type(center) ~= "string" then
		return true
	end
	return PINNED[center] == true
end

local function joker_gain(obs, center, edition)
	if type(center) ~= "string" then
		return 0
	end
	local key = center .. ":" .. (edition or "")
	if GAIN_CACHE[key] ~= nil then return GAIN_CACHE[key] end
	local s = obs.self
	local owned = {}
	if type(s) == "table" and type(s.jokers) == "table" then
		for i = 1, #s.jokers do
			local j = s.jokers[i]
			if type(j) == "table" then
				owned[#owned + 1] = j
			end
		end
	end
	-- Place the new Joker where the reorder step would: an additive
	-- (+mult/+chips) Joker goes before the trailing x-mult / Polychrome
	-- Jokers. Only when the row after purchase qualifies for the
	-- estimate-based reorder (reorder_score): every Joker known, none pinned,
	-- at most REORDER_EST_MAX_JOKERS. Otherwise it stays at the end.
	local e = JOKER_EFFECTS[center]
	local slot = #owned + 1
	local movable = e ~= nil and #owned + 1 <= REORDER_EST_MAX_JOKERS and (not PINNED[center] or e[1] == "copy")
	for i = 1, #owned do
		local o = effect_of(owned[i])
		if o == nil or (joker_pinned(owned[i]) and o[1] ~= "copy") then
			movable = false
		end
	end
	if movable and ADDITIVE[e[1]] then
		-- Only past the trailing run of x-mult/Polychrome Jokers: the adapter
		-- offers adjacent swaps, and each of those swaps is a clear gain, while
		-- a neutral Joker in between would stop the move.
		for i = #owned, 1, -1 do
			local o = effect_of(owned[i])
			if owned[i].edition == "polychrome" or (o ~= nil and MULTIPLICATIVE[o[1]]) then
				slot = i
			else
				break
			end
		end
	end
	local with = {}
	for i = 1, #owned do
		with[i] = owned[i]
	end
	local offered = true
	if center == "j_ride_the_bus" then
		for i = 1, #owned do
			local o = JOKER_EFFECTS[owned[i].center]
			if o ~= nil and FACE_KINDS[o[1]] then
				offered = false
			end
		end
	end
	local proxy = nil
	if offered and SCALING[center] ~= nil then
		-- More rounds left to grow early: x1.25 at antes 1-2, x1 at 3-4,
		-- x0.75 from ante 5 (only the part above x1 for x-mult).
		local ante = type(obs.match) == "table" and obs.match.ante or nil
		local f = 1
		if type(ante) == "number" then
			f = ante <= 2 and 1.25 or (ante <= 4 and 1 or 0.75)
		end
		local p = SCALING[center]
		local v = p[1] == "xmult" and 1 + (p[2] - 1) * f or p[2] * f
		proxy = { p[1], v, p[3] }
	end
	local purchase = { center = center, edition = edition, offered = offered, proxy = proxy }
	table.insert(with, slot, purchase)
	local before = panel_total(owned)
	local after = panel_total(with)
	if movable and e[1] == "copy" then
		-- Same bounded placements the real adapter offers after purchase.
		for target = 1, #owned do
			local rest = {}
			for i = 1, #owned do if i ~= target then rest[#rest + 1] = owned[i] end end
			if center == "j_brainstorm" then
				table.insert(rest, 1, owned[target]); rest[#rest + 1] = purchase
				after = math.max(after, panel_total(rest))
			else
				rest[#rest + 1], rest[#rest + 2] = purchase, owned[target]
				after = math.max(after, panel_total(rest))
				-- Rows used as cache keys must remain immutable.
				local front = { purchase, owned[target] }
				for i = 1, #rest - 2 do front[#front + 1] = rest[i] end
				after = math.max(after, panel_total(front))
			end
		end
	end
	if before <= 0 or after <= before then
		GAIN_CACHE[key] = 0
		return 0
	end
	local gain = (after - before) / before
	if gain > 3 then
		gain = 3
	end
	GAIN_CACHE[key] = gain
	return gain
end

-- Consumables whose downside can wreck the run when used blindly, with the
-- condition under which they are refused (all difficulties: a safety floor).
-- The same rule refuses buying them, picking them from a pack (Arcana and
-- Spectral picks are used at once) and makes a held one worth selling.
local PLANETS = {
	c_pluto = true, c_mercury = true, c_uranus = true, c_venus = true, c_saturn = true,
	c_jupiter = true, c_earth = true, c_mars = true, c_neptune = true, c_planet_x = true,
	c_ceres = true, c_eris = true, c_black_hole = true,
}

-- Consumables that need highlighted hand targets. The live runtime wires no
-- target-selection port (companion_host.lua), so CONSUMABLE_SELECTION never
-- occurs there and these can never be used: never buy one, and sell a held one
-- to free the slot. Pack picks are already gated by the engine's own
-- can_use predicate. (Vanilla spells the Hierophant key c_heirophant.)
local TARGETED = {
	c_magician = true, c_empress = true, c_heirophant = true, c_hierophant = true, c_lovers = true,
	c_chariot = true, c_justice = true, c_strength = true, c_hanged_man = true, c_death = true,
	c_devil = true, c_tower = true, c_star = true, c_moon = true, c_sun = true, c_world = true,
	c_aura = true, c_deja_vu = true, c_trance = true, c_medium = true, c_talisman = true, c_cryptid = true,
}

-- Targeted Tarots the adapter certifies on hand cards (USE_CONSUMABLE_ON_HAND)
-- and their effect: +1 rank, Death (left becomes a copy of right), an
-- enhancement, or a suit.
local TAROT_FX = {
	c_strength = "rank", c_death = "pair",
	c_lovers = "m_wild", c_chariot = "m_steel", c_justice = "m_glass", c_devil = "m_gold",
	c_star = "Diamonds", c_moon = "Clubs", c_sun = "Hearts", c_world = "Spades",
}

-- Relative value of a consumable, used only to choose which held Tarot to sell
-- for a full slot (docs/CLAUDE_BATCH3_REVIEW.md M2). Planets permanently level a
-- hand, so they outrank a targeted Tarot; Death (a copy) and the enhancement
-- Tarots outrank the single-target rank and suit Tarots.
local SLOT_WORTH = {
	c_pluto = 9, c_mercury = 9, c_uranus = 9, c_venus = 9, c_saturn = 9, c_jupiter = 9,
	c_earth = 9, c_mars = 9, c_neptune = 9, c_planet_x = 9, c_ceres = 9, c_eris = 9, c_black_hole = 9,
	c_death = 4, c_strength = 3,
	c_lovers = 2, c_chariot = 2, c_justice = 2, c_devil = 2,
	c_star = 1, c_moon = 1, c_sun = 1, c_world = 1,
}

-- A targeted consumable this difficulty can never use: never bought, and sold.
local function unusable(center)
	return TARGETED[center] and not (CONF.hand_tarots and TAROT_FX[center])
end

local function harmful_use(obs, center)
	local s = obs.self
	local jokers = 0
	local money = 0
	if type(s) == "table" then
		if type(s.jokers) == "table" then
			jokers = #s.jokers
		end
		if type(s.money) == "number" then
			money = s.money
		end
	end
	if center == "c_wraith" then
		-- Rare Joker, but money is set to $0.
		return money >= 10
	end
	if center == "c_ankh" or center == "c_hex" then
		-- Destroy every other Joker.
		return jokers >= 2
	end
	if center == "c_ectoplasm" or center == "c_ouija" then
		-- Permanently -1 hand size.
		return true
	end
	return false
end

-- Voucher values added to the flat `voucher` score (voucher_values tiers).
-- Permanent hands, discards, hand size and slots come first, then economy and
-- shop vouchers. Ante-lowering vouchers that permanently cost a hand or a
-- discard score below leave_shop, so they are not bought. Unknown vouchers add
-- nothing.
-- Vouchers valued at or below this are minor (see voucher_score).
local MINOR_VOUCHER = 10
local VOUCHER_VALUE = {
	v_antimatter = 260, v_grabber = 200, v_nacho_tong = 200, v_paint_brush = 160, v_palette = 160,
	v_wasteful = 130, v_recyclomancy = 130, v_overstock_norm = 120, v_overstock_plus = 120,
	v_clearance_sale = 80, v_liquidation = 80, v_observatory = 80, v_telescope = 60, v_glow_up = 60,
	v_seed_money = 50, v_money_tree = 50, v_hone = 40, v_reroll_surplus = 40, v_reroll_glut = 40,
	v_crystal_ball = 40, v_planet_merchant = 30, v_planet_tycoon = 30, v_tarot_merchant = 20,
	v_tarot_tycoon = 20, v_blank = 10, v_hieroglyph = -300, v_petroglyph = -300,
	-- Deliberately neutral: situational, or banned in some Multiplayer modes.
	v_omen_globe = 0, v_magic_trick = 0, v_illusion = 0, v_directors_cut = 0, v_retcon = 0,
}

-- Pack kind by center prefix (smart_packs tiers): Jokers first while a slot is
-- free, then planets; Standard packs rarely beat keeping the money. Arcana and
-- Spectral are discounted: most of their cards need hand targets (TARGETED),
-- which cannot be used live. A Buffoon
-- pack with every Joker slot full is not opened at all (open_booster_score).
local PACK_VALUE = {
	{ "p_buffoon", 60 }, { "p_celestial", 30 }, { "p_arcana", -10 }, { "p_spectral", -10 }, { "p_standard", -20 },
	{ "p_mp_standard", -20 },
}

-- The poker hand each planet levels (obs hand_levels names).
local PLANET_HAND = {
	c_pluto = "high_card", c_mercury = "pair", c_uranus = "two_pair", c_venus = "three",
	c_saturn = "straight", c_jupiter = "flush", c_earth = "full_house", c_mars = "four",
	c_neptune = "straight_flush", c_planet_x = "five", c_ceres = "flush_house", c_eris = "flush_five",
}

-- true/false when the visible Joker count and slot limit are known (the limit
-- already includes Negative Jokers' extra slots), nil when either is unknown.
local function joker_room(obs)
	local s = obs.self
	local match = obs.match
	if type(s) ~= "table" or type(s.jokers) ~= "table" or type(match) ~= "table" then
		return nil
	end
	if type(match.joker_slots) ~= "number" then
		return nil
	end
	return #s.jokers < match.joker_slots
end

local function pack_prefix(center)
	if type(center) ~= "string" then
		return nil
	end
	for i = 1, #PACK_VALUE do
		local prefix = PACK_VALUE[i][1]
		if string.sub(center, 1, #prefix) == prefix then
			return i
		end
	end
	return nil
end

local function pack_value(obs, center)
	local i = pack_prefix(center)
	if i == nil then
		return 0
	end
	if PACK_VALUE[i][1] == "p_buffoon" and joker_room(obs) ~= true then
		-- Unknown room: no Buffoon preference either way.
		return 0
	end
	return PACK_VALUE[i][2]
end

-- Pack pick: a planet for an already-levelled hand compounds (the policy
-- keeps playing what it has levelled), so it gets points per displayed level.
local function planet_pick_value(obs, center)
	if center == "c_black_hole" then
		return 40
	end
	local hand = PLANET_HAND[center]
	if hand == nil then
		return 0
	end
	local levels = type(obs.self) == "table" and obs.self.hand_levels or nil
	local level = 1
	if type(levels) == "table" and type(levels[hand]) == "table" and type(levels[hand].level) == "number" then
		level = levels[hand].level
	end
	if level > 20 then
		level = 20
	end
	return level * CONF.planet_level_pick
end

-- The adapter builds every pack card as a playing-card record (kind "card"),
-- so a pack card's real kind comes from its public center key: "j_*" is a
-- Joker, any other "c_*" but the plain "c_base" is a Tarot/Planet/Spectral.
local function pack_card_kind(card)
	if card.redacted == true then
		return nil
	end
	local center = card.center
	if type(center) ~= "string" then
		return card.kind
	end
	local prefix = string.sub(center, 1, 2)
	if prefix == "j_" then
		return "joker"
	end
	if prefix == "c_" and center ~= "c_base" then
		return "consumable"
	end
	return "card"
end

local function kind_value(kind)
	if kind == "joker" then
		return CONF.item_joker
	end
	if kind == "consumable" then
		return CONF.item_consumable
	end
	if kind == "card" then
		return CONF.item_card
	end
	if kind == "booster" then
		return CONF.item_booster
	end
	return 0
end

local function buy_score(obs, act)
	local shop = obs.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = by_ref(shop.items, act.item_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(obs)
	if spend == nil or spend < cost then
		return nil
	end
	if item.kind == "consumable" and (harmful_use(obs, item.center) or unusable(item.center)) then
		return nil
	end
	local score = kind_value(item.kind)
	score = score + edition_value(item.edition)
	score = score + economy_bonus(spend - cost)
	if item.kind == "joker" and CONF.est_jokers and CONF.joker_gain_value > 0 then
		-- Up to +3x the panel estimate; unknown Jokers keep the flat value and
		-- scaling ones use their SCALING proxy.
		local gain = joker_gain(obs, item.center, item.edition) * CONF.joker_gain_value
		if spend - cost < CONF.reserve then
			-- Dipping under the reserve (or into Credit Card debt) needs a
			-- clearly better Joker: halve the gain there.
			gain = gain / 2
		end
		score = score + math.floor(gain)
	end
	return score
end

-- Equal-scored tie-break for BUY_ITEM actions: a consumable purchase with the
-- higher SLOT_WORTH wins, so a shop offering Star before Saturn does not cause a
-- wrongly-bought weaker Tarot (final review L-b). It is only
-- consulted when two actions already score exactly the same AND both expose a
-- worth, so no comparison between different kinds or price/economy/reserve/
-- edition outcomes can change; anything else keeps the established id order.
local function buy_tiebreak(obs, act)
	local shop = obs.shop
	if type(act) ~= "table" or act.type ~= "BUY_ITEM" or type(shop) ~= "table" then
		return nil
	end
	local item = by_ref(shop.items, act.item_ref)
	if item == nil or item.kind ~= "consumable" then
		return nil
	end
	return SLOT_WORTH[item.center] or 0
end

-- The best certified Joker purchase this shop decision, by its full buy score
-- (edition, estimated gain and economy after its own price), or false. Only
-- Jokers worth buying over leaving count. Computed once per decision.
local function best_joker(obs, actions, count)
	local best = false
	local spend = spendable(obs)
	for i = 1, count do
		local a = actions[i]
		if type(a) == "table" and a.type == "BUY_ITEM" then
			local item = by_ref(obs.shop.items, a.item_ref)
			local score = item ~= nil and item.kind == "joker" and buy_score(obs, a) or nil
			if score ~= nil and type(a.id) == "string" then
				BUY_SCORES[a.id] = score
			end
			if score ~= nil and score > CONF.leave_shop and (not best or score > best.score) then
				best = { score = score, cost = item.cost, intrinsic = score - economy_bonus(spend - item.cost) }
			end
		end
	end
	return best
end

-- Final score of a voucher or pack with intrinsic value `base` and price
-- `cost`, measured against the best Joker purchase (M1 of
-- docs/CLAUDE_BATCH2_REVIEW.md). Its intrinsic value never exceeds that
-- Joker's, so table values cannot crowd it out; economy after each price is
-- then compared honestly, so a Joker that would drain the money can lose. When
-- both fit the money the Joker is bought first (the other stays affordable).
-- Intrinsic margin a Joker keeps over a voucher/pack when only one fits: 50
-- points is $5 below the reserve, so a slightly cheaper pack no longer wins on
-- the reserve penalty alone (review N3), but a Joker that drains the money
-- still loses.
local JOKER_MARGIN = 50

local function versus_joker(obs, spend, base, cost)
	local best = SHOP_BEST
	if best then
		if base > best.intrinsic - JOKER_MARGIN then
			base = best.intrinsic - JOKER_MARGIN
		end
	end
	local score = base + economy_bonus(spend - cost)
	if best and best.cost + cost <= spend and score > best.score - 20 then
		score = best.score - 20
	end
	return score
end

local function voucher_score(obs, act)
	local shop = obs.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = by_ref(shop.vouchers, act.voucher_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(obs)
	if spend == nil or spend < cost then
		return nil
	end
	if CONF.voucher_values and type(item.center) == "string" then
		local value = VOUCHER_VALUE[item.center] or 0
		-- A minor voucher (Blank, neutral or unknown) is not worth dipping
		-- below the money reserve for.
		if value <= MINOR_VOUCHER and spend - cost < CONF.reserve then
			return nil
		end
		return versus_joker(obs, spend, CONF.voucher + value, cost)
	end
	return CONF.voucher + economy_bonus(spend - cost)
end

local function open_booster_score(obs, act)
	local shop = obs.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = by_ref(shop.boosters, act.item_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(obs)
	if spend == nil or spend < cost then
		return nil
	end
	local base = CONF.item_booster
	if CONF.smart_packs then
		local i = pack_prefix(item.center)
		if i ~= nil and PACK_VALUE[i][1] == "p_buffoon" and joker_room(obs) == false then
			-- Every Joker slot is full: only a Negative Joker could be taken.
			return nil
		end
		return versus_joker(obs, spend, base + pack_value(obs, item.center), cost)
	end
	return base + economy_bonus(spend - cost)
end

local function reroll_score(obs, act)
	local shop = obs.shop
	if type(shop) ~= "table" then
		return nil
	end
	local cost = shop.reroll_cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(obs)
	if spend == nil or spend < cost then
		return nil
	end
	local left = spend - cost
	local score = CONF.reroll_base
	local surplus = left - CONF.reserve * 2
	if surplus > 0 then
		local extra = surplus * 2
		if extra > CONF.reroll_surplus_cap then
			extra = CONF.reroll_surplus_cap
		end
		score = score + extra
	end
	if left < CONF.reserve then
		score = score - (CONF.reserve - left) * 8
	end
	return score
end

local function blind_score(obs, act)
	if act.type == "SELECT_BLIND" then
		return CONF.blind_select
	end
	return CONF.blind_skip
end

local function booster_select_score(obs, act)
	local b = obs.booster
	if type(b) ~= "table" then
		return nil
	end
	local refs = act.card_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	local card = by_ref(b.cards, refs[1])
	if card == nil then
		return nil
	end
	local kind = pack_card_kind(card)
	if kind == "consumable" and harmful_use(obs, card.center) then
		return nil
	end
	local score = CONF.booster_good
	if card.redacted ~= true then
		if kind == "joker" then
			score = score + CONF.booster_kind_joker
		elseif kind == "consumable" then
			score = score + CONF.booster_kind_consumable
		elseif kind == "card" then
			score = score + CONF.booster_kind_card
		end
		if CONF.smart_packs then
			if kind == "joker" then
				score = score + edition_value(card.edition)
				if CONF.est_jokers and CONF.joker_gain_value > 0 then
					score = score + math.floor(joker_gain(obs, card.center, card.edition) * CONF.joker_gain_value)
				end
			elseif kind == "consumable" then
				score = score + planet_pick_value(obs, card.center)
			elseif kind == "card" then
				-- Standard pack: an edition, seal or enhancement beats a plain card.
				score = score + math.floor(edition_value(card.edition) / 2)
				if card.seal ~= nil then
					score = score + 15
				end
				-- Stone loses rank and suit, so it is not an upgrade here.
				if type(card.center) == "string" and card.center ~= "c_base" and card.center ~= "m_stone" then
					score = score + 10
				end
			end
		end
	end
	return score
end

local function target_minimum(obs)
	local target = obs.consumable_target
	if type(target) == "table" and type(target.min_targets) == "number" then
		return target.min_targets
	end
	local context = obs.context
	if type(context) == "table" and type(context.min_targets) == "number" then
		return context.min_targets
	end
	return nil
end

local function target_or_use_score(obs, act)
	if act.type == "SELECT_TARGETS" then
		return CONF.select_targets
	end
	local source = nil
	if type(obs.self) == "table" and type(act.source_ref) == "string" then
		source = by_ref(obs.self.consumables, act.source_ref)
	end
	if source == nil and type(obs.consumable_target) == "table" then
		source = obs.consumable_target.source
	end
	local center = type(source) == "table" and source.center or nil
	if type(center) == "string" and harmful_use(obs, center) then
		return nil
	end
	if center == "c_hermit" and CONF.hold_hermit then
		-- The Hermit doubles money up to +$20: hold it until money reaches
		-- $20, unless the shop's consumable slots are full of cards worth
		-- keeping (a harmful or targeted card is sold instead).
		local s = obs.self
		local money = type(s) == "table" and type(s.money) == "number" and s.money or 0
		local slots = type(obs.match) == "table" and obs.match.consumable_slots or nil
		local held = 0
		if type(s) == "table" and type(s.consumables) == "table" then
			for i = 1, #s.consumables do
				local c = s.consumables[i]
				local cc = type(c) == "table" and c.center or nil
				if not (type(cc) == "string" and (unusable(cc) or harmful_use(obs, cc))) then
					held = held + 1
				end
			end
		end
		local full = obs.phase == "SHOP" and type(slots) == "number" and held >= slots
		if money < 20 and not full then
			return nil
		end
	end
	local planet_bonus = 0
	if PLANETS[center] then
		planet_bonus = 1000
	end
	local refs = act.target_refs
	local count = 0
	if type(refs) == "table" then
		count = #refs
	end
	if obs.phase == "CONSUMABLE_SELECTION" then
		local minimum = target_minimum(obs)
		if minimum == nil or count < minimum then
			return nil
		end
		return CONF.use_consumable + planet_bonus
	end
	if count > 0 then
		return nil
	end
	return CONF.use_consumable + planet_bonus
end

local ADD_MULT = {
	j_joker = true,
	j_greedy_joker = true,
	j_lusty_joker = true,
	j_wrathful_joker = true,
	j_gluttenous_joker = true,
	j_abstract = true,
	j_even_steven = true,
	j_odd_todd = true,
	j_scholar = true,
	j_walkie_talkie = true,
	j_smiley = true,
	j_half = true,
	j_mystic_summit = true,
	j_shoot_the_moon = true,
	j_trousers = true,
	j_supernova = true,
	j_ride_the_bus = true,
	j_green_joker = true,
	j_fibonacci = true,
}

local X_MULT = {
	j_baron = true,
	j_cavendish = true,
	j_duo = true,
	j_trio = true,
	j_family = true,
	j_order = true,
	j_tribe = true,
	j_ramen = true,
	j_blackboard = true,
	j_hologram = true,
	j_constellation = true,
	j_loyalty_card = true,
	j_obelisk = true,
	j_throwback = true,
	j_yorick = true,
	j_campfire = true,
	j_steel_joker = true,
	j_glass = true,
	j_bloodstone = true,
	j_madness = true,
	j_baseball = true,
	j_photograph = true,
}


local function joker_tier(joker)
	if type(joker) ~= "table" or joker.redacted == true or joker.debuff == true then
		return nil
	end
	local center = joker.center
	if type(center) ~= "string" then
		return nil
	end
	if ADD_MULT[center] == true then
		return 0
	end
	if X_MULT[center] == true then
		return 1
	end
	return nil
end


local function inversions(tiers, n)
	local count = 0
	for i = 1, n do
		local left = tiers[i]
		if left ~= nil then
			for j = i + 1, n do
				local right = tiers[j]
				if right ~= nil and left > right then
					count = count + 1
				end
			end
		end
	end
	return count
end

-- Monotonic joker ordering. Only recognized vanilla +Mult and xMult jokers are
-- ranked, and +Mult must come before xMult. Every other joker (unrecognized
-- center, redacted or debuffed card) is a fixed anchor and never moves, so the
-- relative order of unknown jokers is stable; a recognized position-sensitive
-- joker (Blueprint/Brainstorm/Misprint) additionally keeps its immediate
-- neighbours. A candidate is scored only when it strictly reduces the number of
-- ranked inversions against that target, so the inversion count is a potential
-- that always decreases: no reverse/adjacent cycle is possible, and a target
-- that is already ordered never reverses.
local function reorder_score(obs, act)
	local s = obs.self
	if type(s) ~= "table" then
		return nil
	end
	local jokers = s.jokers
	if type(jokers) ~= "table" then
		return nil
	end
	local n = #jokers
	if n < 2 then
		return nil
	end
	local order = act.order
	if type(order) ~= "table" or #order ~= n then
		return nil
	end
	local current = {}
	local anchor = {}
	local pinned = {}
	for i = 1, n do
		local joker = jokers[i]
		if type(joker) ~= "table" or type(joker.id) ~= "string" then
			return nil
		end
		current[i] = joker_tier(joker)
		anchor[i] = (current[i] == nil)
		pinned[i] = joker_pinned(joker)
	end
	local candidate = {}
	local seen = {}
	for i = 1, n do
		local ref = order[i]
		if type(ref) ~= "string" or seen[ref] == true then
			return nil
		end
		seen[ref] = true
		local joker = by_ref(jokers, ref)
		if joker == nil then
			return nil
		end
		candidate[i] = joker_tier(joker)
	end
	-- Estimate-based ordering (+mult before xmult etc.) when every Joker's
	-- effect is known to the estimator; otherwise the tier rule below applies.
	if CONF.est_jokers and CONF.estimate_plays and n <= REORDER_EST_MAX_JOKERS and PLAY ~= nil
		and PLAY.reorders_left > 0 then
		local known = true
		local reordered = {}
		for i = 1, n do
			local joker = jokers[i]
			local e = effect_of(joker)
			if e == nil or (pinned[i] and e[1] ~= "copy") then
				known = false
			end
			reordered[i] = by_ref(jokers, order[i])
		end
		if known then
			PLAY.reorders_left = PLAY.reorders_left - 1
			if PLAY.panel_now == nil then
				PLAY.panel_now = panel_total(jokers)
			end
			local now = PLAY.panel_now
			local next_total = panel_total(reordered)
			if now > 0 and next_total > now * 1.005 then
				-- Strictly increasing in the improvement, below the cap.
				local r = next_total / now - 1
				return CONF.reorder + CONF.reorder_bonus * r / (1 + r)
			end
			return nil
		end
	end
	for i = 1, n do
		if anchor[i] and order[i] ~= jokers[i].id then
			return nil
		end
	end
	for i = 1, n do
		if pinned[i] then
			if i > 1 and order[i - 1] ~= jokers[i - 1].id then
				return nil
			end
			if i < n and order[i + 1] ~= jokers[i + 1].id then
				return nil
			end
		end
	end
	local before = inversions(current, n)
	local after = inversions(candidate, n)
	if after >= before then
		return nil
	end
	local gain = before - after
	if gain > CONF.reorder_bonus then
		gain = CONF.reorder_bonus
	end
	return CONF.reorder + gain
end

-- Jokers whose built-up value a sale resets: never sold for a fresh copy
-- unless their shown value is still the base.
local GROWS = {
	j_ride_the_bus = true, j_green_joker = true, j_trousers = true, j_hologram = true, j_constellation = true,
	j_obelisk = true, j_yorick = true, j_campfire = true, j_glass = true, j_madness = true, j_loyalty_card = true,
}

local function recognized_joker(center)
	if type(center) ~= "string" then
		return false
	end
	return ADD_MULT[center] == true or X_MULT[center] == true or PINNED[center] == true
end

-- A held consumable only frees a slot when it does not carry capacity itself.
-- The `negative` edition supplies `ability.card_limit = 1` to the owned row
-- (current Steamodded `handle_card_limit`, src/utils.lua:3919), so removing it
-- lowers the area limit by the same slot it occupied: it frees nothing. An
-- edition the obs cannot classify is treated the same way -- the slot
-- effect cannot be inferred, so the card is never sold as a slot release rather
-- than assuming its removal helps.
local function slot_releasing(edition)
	if edition == nil then
		return true
	end
	return edition == "foil" or edition == "holo" or edition == "polychrome"
end

local function sell_consumable_score(obs, act)
	-- Only a held card the safety floor would never use is worth its slot back.
	if obs.phase ~= "SHOP" or type(obs.self) ~= "table" then
		return nil
	end
	local held = by_ref(obs.self.consumables, act.consumable_ref)
	if held == nil or held.redacted == true or type(held.center) ~= "string" then
		return nil
	end
	if not harmful_use(obs, held.center) and not unusable(held.center) then
		if not slot_releasing(held.edition) then
			return nil
		end
		-- A usable targeted Tarot waits for a useful hand, so a full set of
		-- consumable slots is not by itself a reason to sell it. It is freed
		-- only when the visible shop offers a concretely better, affordable
		-- consumable that needs the slot, and then only the lowest-value held
		-- Tarot is sacrificed (docs/CLAUDE_BATCH3_REVIEW.md M2). Only a card
		-- that actually releases a slot is compared: a lower-worth Negative (or
		-- any slot-providing/unknown edition) never blocks the regular card.
		local slots = type(obs.match) == "table" and obs.match.consumable_slots or nil
		local list = obs.self.consumables
		local worth = SLOT_WORTH[held.center]
		if not (TAROT_FX[held.center] and type(slots) == "number" and type(list) == "table" and #list >= slots and worth ~= nil) then
			return nil
		end
		for i = 1, #list do
			local other = list[i]
			local center = type(other) == "table" and other.center or nil
			local w = type(center) == "string" and SLOT_WORTH[center] or nil
			local edition = type(other) == "table" and other.edition or nil
			if w ~= nil and w < worth and slot_releasing(edition) then
				return nil
			end
		end
		local spend = spendable(obs)
		local shop = obs.shop
		if spend == nil or type(shop) ~= "table" or type(shop.items) ~= "table" then
			return nil
		end
		-- The sale must be for the purchase the same buy ranking (buy_score plus
		-- the SLOT_WORTH/id tie-break) actually picks among the visible offers,
		-- and that purchase must strictly improve the held worth. A cheaper
		-- same-or-worse-worth offer can overtake it once the invisible sale
		-- proceeds raise the interest bonus, so refuse that churn (final review
		-- interest churn; docs/BASELINE_POLICY.md).
		local predicted = nil
		local predicted_score = nil
		local predicted_tie = nil
		local predicted_id = nil
		local min_nonupgrade_cost = nil
		for i = 1, #shop.items do
			local item = shop.items[i]
			if type(item) == "table" and item.redacted ~= true and item.kind == "consumable"
				and type(item.id) == "string" and type(item.cost) == "number" and spend - item.cost >= CONF.reserve then
				local score = buy_score(obs, { type = "BUY_ITEM", item_ref = item.id })
				if score ~= nil then
					local w = SLOT_WORTH[item.center] or 0
					if predicted == nil or score > predicted_score
						or (score == predicted_score and (w > predicted_tie or (w == predicted_tie and byte_less(item.id, predicted_id)))) then
						predicted = item
						predicted_score = score
						predicted_tie = w
						predicted_id = item.id
					end
					if w <= worth and (min_nonupgrade_cost == nil or item.cost < min_nonupgrade_cost) then
						min_nonupgrade_cost = item.cost
					end
				end
			end
		end
		if predicted == nil or (SLOT_WORTH[predicted.center] or 0) <= worth then
			return nil
		end
		if min_nonupgrade_cost ~= nil and min_nonupgrade_cost < predicted.cost then
			return nil
		end
		return CONF.leave_shop + CONF.sell_harmful
	end
	return CONF.leave_shop + CONF.sell_harmful
end

-- SHOP-only capacity sale. The baseline frees a joker slot only when:
--   * the phase is SHOP and the visible joker board is full;
--   * the sold candidate is a visible, non-debuffed, *un-editioned* owned copy
--     of a recognized vanilla joker center;
--   * the same visible center is on offer as a joker with a recognized
--     non-negative edition (a strict, source-grounded upgrade of the same base);
--   * that offered copy is already affordable from current spendable cash while
--     preserving the difficulty reserve (the obs exposes no sale
--     proceeds, so a sale is never assumed to fund the purchase).
-- Every unclear case (unknown/face-down/different center, debuffed card, an
-- already-editioned owned copy, a negative or unrecognized offered edition,
-- unaffordable price, non-full board) yields no score, so a sell is never a
-- fallback and the board is never dumped. Selling one copy drops the board below
-- full, so no further sale can score in the following frame.
local function sell_score(obs, act)
	if act.type == "SELL_CONSUMABLE" then
		return sell_consumable_score(obs, act)
	end
	if act.type ~= "SELL_JOKER" then
		return nil
	end
	if obs.phase ~= "SHOP" then
		return nil
	end
	local s = obs.self
	local shop = obs.shop
	if type(s) ~= "table" or type(shop) ~= "table" then
		return nil
	end
	local jokers = s.jokers
	if type(jokers) ~= "table" then
		return nil
	end
	local slots = obs.match
	if type(slots) ~= "table" or type(slots.joker_slots) ~= "number" then
		return nil
	end
	if #jokers < slots.joker_slots then
		return nil
	end
	local owned = by_ref(jokers, act.joker_ref)
	if owned == nil or owned.redacted == true or owned.debuff == true then
		return nil
	end
	if owned.edition ~= nil then
		return nil
	end
	local center = owned.center
	local c = owned.current
	-- A grown one (or one whose value is not shown) keeps its value.
	if not recognized_joker(center) or (GROWS[center] and not (type(c) == "table" and c.value <= (c.kind == "xmult" and 100 or 0))) then
		return nil
	end
	local spend = spendable(obs)
	if spend == nil then
		return nil
	end
	local items = shop.items
	if type(items) ~= "table" then
		return nil
	end
	for i = 1, #items do
		local item = items[i]
		if type(item) == "table" and item.redacted ~= true and item.debuff ~= true
			and item.kind == "joker" and item.center == center and is_upgrade_edition(item.edition) then
			local cost = item.cost
			if type(cost) == "number" and spend - cost >= CONF.reserve then
				return CONF.slot_sell
			end
		end
	end
	return nil
end

-- A targeted Tarot on hand cards: the best estimated play over the hand with
-- the effect applied, against the best play now. Used on a clear gain (Gold:
-- when it costs nothing, for its held payout); otherwise held. Metered with
-- its own share of work.
local TARGET_WORK = 6000

local function hand_tarot_score(obs, act)
	local s = obs.self
	if not CONF.hand_tarots or not CONF.estimate_plays or type(s) ~= "table" or type(s.hand) ~= "table"
		or TAROT_WORK >= TARGET_WORK then
		return nil
	end
	local source = by_ref(s.consumables, act.source_ref)
	local fx = type(source) == "table" and TAROT_FX[source.center] or nil
	local refs = act.card_refs
	if fx == nil or type(refs) ~= "table" then
		return nil
	end
	local w0 = WORK
	local hand = {}
	local at = {}
	for i = 1, #s.hand do
		local c = s.hand[i]
		if type(c) ~= "table" or c.redacted == true then
			return nil
		end
		hand[i] = c
		at[c.id] = i
	end
	if TAROT_BEFORE == nil then
		TAROT_BEFORE = best_play(hand, s.jokers)
	end
	local idx = {}
	for i = 1, #refs do
		idx[i] = at[refs[i]]
		if idx[i] == nil then
			return nil
		end
	end
	local function copy(c)
		local out = {}
		for k, v in pairs(c) do
			out[k] = v
		end
		return out
	end
	if fx == "pair" then
		if #idx ~= 2 then
			return nil
		end
		-- The left card (lower position) becomes a copy of the right one.
		local left, right = math.min(idx[1], idx[2]), math.max(idx[1], idx[2])
		local c = copy(hand[right])
		c.id = hand[left].id
		hand[left] = c
	else
		local c = copy(hand[idx[1]])
		if fx == "rank" then
			local rv = rank_value(c.rank)
			if rv == nil then
				return nil
			end
			c.rank = RANK_NAMES[rv == 14 and 2 or rv + 1]
		elseif string.sub(fx, 1, 2) == "m_" then
			c.center = fx
		else
			c.suit = fx
		end
		hand[idx[1]] = c
	end
	local after = best_play(hand, s.jokers)
	TAROT_WORK = TAROT_WORK + WORK - w0
	local before = TAROT_BEFORE
	if before > 0 and after > before * 1.02 then
		local gain = (after - before) / before
		return 1500000 + 400000 * (gain > 1 and 1 or gain)
	end
	if fx == "m_gold" and before > 0 and after >= before then
		return 1400000
	end
	return nil
end

local function score_of(obs, act)
	if type(act) ~= "table" then
		return nil
	end
	local kind = act.type
	if type(kind) ~= "string" then
		return nil
	end
	-- Preserve time for the remaining blinds. Immediate Joker purchases and
	-- consumable uses remain available; optional shopping stops under pressure.
	if TIME_PRESSURE and obs.phase == "SHOP" then
		if kind == "OPEN_BOOSTER" or kind == "BUY_VOUCHER" or kind == "REROLL" or kind == "REORDER_JOKERS" then
			return nil
		end
		if kind == "BUY_ITEM" then
			local item = by_ref(type(obs.shop) == "table" and obs.shop.items or nil, act.item_ref)
			if type(item) ~= "table" or item.kind ~= "joker" then
				return nil
			end
		end
	end
	if kind == "PLAY_CARDS" then
		return play_score(obs, act)
	end
	if kind == "USE_CONSUMABLE_ON_HAND" then
		return hand_tarot_score(obs, act)
	end
	if kind == "DISCARD_CARDS" then
		local score = discard_score(obs, act)
		if score ~= nil and PLAY ~= nil and PLAY.discard_ev ~= nil then
			local value = PLAY.discard_ev[act.id]
			if value ~= nil then
				-- Rank discards by expected follow-up play; the old per-card
				-- heuristic only breaks ties.
				local scale = PLAY.best or 1000
				if scale < 1000 then
					scale = 1000
				end
				if value ~= value or value > ESTIMATE_CAP then
					value = ESTIMATE_CAP
				end
				if PLAY.discard_clear ~= nil and PLAY.discard_clear[act.id] ~= nil then
					-- Last hand: the chance to clear decides, EV breaks ties.
					score = 200000 + 250000 * PLAY.discard_clear[act.id]
						+ 50000 * value / (value + scale) + score / 1000
				else
					score = 200000 + 300000 * value / (value + scale) + score / 1000
				end
			end
		end
		if score ~= nil and CONF.estimate_plays and PLAY ~= nil and PLAY.discard_mode then
			score = score + 1000000
		end
		return score
	end
	if kind == "SELECT_BLIND" or kind == "SKIP_BLIND" then
		return blind_score(obs, act)
	end
	if kind == "START_TIMER" then
		if CONF.start_timer > 0 then
			return CONF.start_timer
		end
		return nil
	end
	if kind == "BUY_ITEM" then
		if type(act.id) == "string" and BUY_SCORES[act.id] ~= nil then
			return BUY_SCORES[act.id]
		end
		return buy_score(obs, act)
	end
	if kind == "BUY_VOUCHER" then
		return voucher_score(obs, act)
	end
	if kind == "OPEN_BOOSTER" then
		return open_booster_score(obs, act)
	end
	if kind == "REROLL" then
		return reroll_score(obs, act)
	end
	if kind == "LEAVE_SHOP" then
		return CONF.leave_shop
	end
	if kind == "SELL_JOKER" or kind == "SELL_CONSUMABLE" then
		return sell_score(obs, act)
	end
	if kind == "SELECT_BOOSTER_ITEM" then
		return booster_select_score(obs, act)
	end
	if kind == "SKIP_BOOSTER" then
		return CONF.booster_skip
	end
	if kind == "SELECT_TARGETS" or kind == "USE_CONSUMABLE" then
		return target_or_use_score(obs, act)
	end
	if kind == "REORDER_JOKERS" then
		return reorder_score(obs, act)
	end
	if kind == "REORDER_HAND" then
		return nil
	end
	return CONF.unknown
end

return function(obs, actions)
	if type(obs) ~= "table" or type(actions) ~= "table" then
		return nil
	end
	local limit = CONF.max_actions
	local count = #actions
	if count > limit then
		count = limit
	end
	PLAY = nil
	LEVELS = nil
	WORK = 0
	SHOP_BEST = false
	MIN_CARDS = 0
	PSYCHIC_TERMINAL = false
	EYE_PLAYED = nil
	MOUTH_ONLY = nil
	CURRENT_EFF = {}
	JOKER_CACHE = {}
	GAIN_CACHE = {}
	TAROT_BEFORE = nil
	TAROT_WORK = 0
	local match = obs.match
	set_rules(type(obs.self) == "table" and obs.self.jokers or nil)
	DRAW_PROFILE = type(match) == "table" and match.draw_profile or nil
	PANEL = nil
	BALANCED = type(match) == "table" and match.score_balanced == true
	TIME_PRESSURE = type(match) == "table" and type(match.timer_remaining) == "number" and match.timer_remaining <= 60
	FLINT = CONF.boss_aware and type(match) == "table" and match.blind_disabled ~= true and match.blind == "bl_flint"
		and (obs.phase == "PLAY_HAND" or obs.phase == "MULTIPLAYER_PVP" or obs.phase == "CONSUMABLE_SELECTION")
	-- The Psychic must play five cards (public blind key). Resolved here, before
	-- the estimate, so the rule holds on every path that ranks by category
	-- instead: the rule-Joker and play-work-cap early returns, and the fallback
	-- (docs/CLAUDE_BATCH3_REVIEW.md M1).
	if CONF.boss_aware and type(match) == "table" and match.blind_disabled ~= true and match.blind == "bl_psychic" then
		MIN_CARDS = 5
	end
	if MIN_CARDS > 0 then
		-- The exhausted-hand terminal (M-A): only when our own visible hand is
		-- 1-4 cards (so no five-card play can exist) and the certified catalogue
		-- offers no scoreable discard. A missing five-card candidate at five or
		-- more cards is a malformed catalogue and stays fail-closed.
		local hand = type(obs.self) == "table" and obs.self.hand or nil
		local size = type(hand) == "table" and #hand or nil
		if size ~= nil and size >= 1 and size <= 4 then
			local discardable = false
			for i = 1, count do
				local a = actions[i]
				if type(a) == "table" and a.type == "DISCARD_CARDS" and discard_score(obs, a) ~= nil then
					discardable = true
					break
				end
			end
			PSYCHIC_TERMINAL = not discardable
		end
	end
	local levels = type(obs.self) == "table" and obs.self.hand_levels or nil
	if CONF.boss_aware and type(match) == "table" and match.blind_disabled ~= true and type(levels) == "table"
		and (match.blind == "bl_eye" or match.blind == "bl_mouth") then
		local played = nil
		for name, entry in pairs(levels) do
			if type(entry) == "table" and type(entry.played_this_round) == "number" and entry.played_this_round >= 1 then
				played = played or {}
				played[name] = true
			end
		end
		if played ~= nil then
			-- The Mouth: if several types show as played (a debuffed off-type
			-- hand still counts), the first cannot be told apart, so all of
			-- them stay allowed.
			if match.blind == "bl_eye" then
				EYE_PLAYED = played
			else
				MOUTH_ONLY = played
			end
		end
	end
	BUY_SCORES = {}
	INTEREST_CAP = CONF.interest_cap
	local owned_vouchers = type(obs.self) == "table" and obs.self.vouchers or nil
	if type(owned_vouchers) == "table" then
		for i = 1, #owned_vouchers do
			local v = owned_vouchers[i]
			local center = type(v) == "table" and v.center or nil
			if center == "v_money_tree" and INTEREST_CAP < 20 then
				INTEREST_CAP = 20
			elseif center == "v_seed_money" and INTEREST_CAP < 10 then
				INTEREST_CAP = 10
			end
		end
	end
	if CONF.use_levels and type(obs.self) == "table" and type(obs.self.hand_levels) == "table" then
		LEVELS = obs.self.hand_levels
	end
	if CONF.estimate_plays then
		PLAY = analyse_plays(obs, actions, count)
	end
	if (CONF.smart_packs or CONF.voucher_values) and type(obs.shop) == "table" then
		SHOP_BEST = best_joker(obs, actions, count)
	end
	local best = nil
	local best_score = nil
	local best_id = nil
	local best_tie = nil
	for i = 1, count do
		local act = actions[i]
		local score = score_of(obs, act)
		if score ~= nil and type(score) == "number" then
			local id = act.id
			if type(id) ~= "string" then
				id = ""
			end
			local tie = buy_tiebreak(obs, act)
			local take = best == nil or score > best_score
			if not take and score == best_score then
				if tie ~= nil and best_tie ~= nil then
					take = tie > best_tie or (tie == best_tie and byte_less(id, best_id))
				else
					take = byte_less(id, best_id)
				end
			end
			if take then
				best = act
				best_score = score
				best_id = id
				best_tie = tie
			end
		end
	end
	return best
end
]==]

-- The template keeps its comments and indentation for readers; the rendered
-- sandbox source drops them (line breaks stay, so tokens never merge). A line
-- comment starts at the first "--" outside a quoted string. Long brackets are
-- refused rather than half-handled, so a future template cannot be mangled.
local function strip_line(line)
	if string.find(line, "[[", 1, true) or string.find(line, "--[", 1, true) then
		return nil
	end
	local cut = string.find(line, "--", 1, true)
	if cut ~= nil and string.find(line, "[\"']") ~= nil then
		cut = nil
		local quote = nil
		local i = 1
		local n = #line
		while i <= n do
			local c = string.sub(line, i, i)
			if quote ~= nil then
				if c == "\\" then
					i = i + 1
				elseif c == quote then
					quote = nil
				end
			elseif c == "\"" or c == "'" then
				quote = c
			elseif c == "-" and string.sub(line, i + 1, i + 1) == "-" then
				cut = i
				break
			end
			i = i + 1
		end
	end
	if cut ~= nil then
		line = string.sub(line, 1, cut - 1)
	end
	return (string.gsub(string.gsub(line, "^%s+", ""), "%s+$", ""))
end

-- Drop a space outside quotes when a neighbour is punctuation, unless that
-- would join "--" (a comment), "." with "." or a digit (a different
-- operator or a malformed number) or open a long bracket ("[[" / "[=").
-- Both compact and loose renderings join statement lines before squeezing,
-- retaining identical token streams and line metadata for the bytecode check.
local PUNCT = {}
for c in string.gmatch("=+-*/,(){}[]<>~.#%^;:", ".") do
	PUNCT[c] = true
end

local function squeeze_line(line)
	local out = {}
	local quote = nil
	local n = #line
	local i = 1
	while i <= n do
		local c = string.sub(line, i, i)
		if quote ~= nil then
			out[#out + 1] = c
			if c == "\\" then
				i = i + 1
				out[#out + 1] = string.sub(line, i, i)
			elseif c == quote then
				quote = nil
			end
		elseif c == "\"" or c == "'" then
			quote = c
			out[#out + 1] = c
		elseif c == " " then
			local a = out[#out] or ""
			local b = string.sub(line, i + 1, i + 1)
			local drop = (PUNCT[a] or PUNCT[b]) and not (a == "-" and b == "-")
				and not (a == "[" and (b == "[" or b == "="))
				and not (string.find(a, "%d") and b == ".") and not (a == "." and (b == "." or string.find(b, "%d")))
			if not drop then
				out[#out + 1] = c
			end
		else
			out[#out + 1] = c
		end
		i = i + 1
	end
	return table.concat(out)
end

-- Shorten private function/constant symbols only in generated text. Keep the
-- maintained template readable, preserve quoted data and field names, and
-- retain the existing source cap. Tests compare every executable instruction,
-- constant and nested prototype with the readable template (debug data aside).
local function compact_symbols(text)
	if string.find(text, "_b%d") then return nil end
	local names, seen = {}, {}
	local function collect(name)
		if #name > 6 and not seen[name] and not string.find(text, "[%.:]" .. name .. "%f[%W]") then
			seen[name] = true; names[#names + 1] = name
		end
	end
	for name in string.gmatch(text, "local function ([%a_][%w_]*)") do collect(name) end
	for name in string.gmatch(text, "local ([A-Z][A-Z_0-9]*)%s*=") do collect(name) end
	table.sort(names, byte_less)
	local mapping = {}
	for i = 1, #names do mapping[names[i]] = "_b" .. i end
	local out, quote, i = {}, nil, 1
	while i <= #text do
		local c = string.sub(text, i, i)
		if quote ~= nil then
			out[#out + 1] = c
			if c == "\\" then
				i = i + 1; out[#out + 1] = string.sub(text, i, i)
			elseif c == quote then quote = nil end
		elseif c == "\"" or c == "'" then quote = c; out[#out + 1] = c
		elseif string.find(c, "[%a_]") then
			local finish = i + 1
			while finish <= #text and string.find(string.sub(text, finish, finish), "[%w_]") do finish = finish + 1 end
			local token = string.sub(text, i, finish - 1)
			out[#out + 1] = mapping[token] or token; i = finish - 1
		else out[#out + 1] = c end
		i = i + 1
	end
	return table.concat(out)
end

local function strip_template(text, squeeze)
	local out = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		local kept = strip_line(line)
		if kept == nil then
			return nil
		end
		if #kept > 0 then
			out[#out + 1] = kept
		end
	end
	local joined = compact_symbols(table.concat(out, " "))
	if joined == nil then return nil end
	return (squeeze and squeeze_line(joined) or joined) .. "\n"
end

local STRIPPED = strip_template(TEMPLATE, true)

-- Practical guard well below the sandbox's hard 65536-byte cap, so policy
-- growth has to recover space instead of creeping up to the limit.
BaselinePolicy.SOURCE_GUARD = 57344

local function render_value(value)
	if type(value) == "number" then
		return string.format("%d", value)
	end
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) == "boolean" then
		if value then
			return "true"
		end
		return "false"
	end
	return nil
end

local function render_config(config)
	local keys = {}
	for key in next, config do
		keys[#keys + 1] = key
	end
	table.sort(keys, byte_less)
	local parts = {}
	for i = 1, #keys do
		local key = keys[i]
		local rendered = render_value(config[key])
		if rendered == nil then
			return nil
		end
		parts[#parts + 1] = key .. "=" .. rendered
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function BaselinePolicy.difficulties()
	local out = {}
	for i = 1, #ORDER do
		out[i] = ORDER[i]
	end
	return out
end

function BaselinePolicy.describe()
	local out = {}
	for i = 1, #ORDER do
		local name = ORDER[i]
		local config = CONFIGS[name]
		local copy = {}
		for key, value in next, config do
			copy[key] = value
		end
		out[name] = copy
	end
	return out
end

-- Stripped but not squeezed (spaces kept), built on first use: only for the
-- bytecode-equality test, never sent to the policy worker.
local LOOSE = nil

function BaselinePolicy.loose_source(difficulty)
	local config = type(difficulty) == "string" and CONFIGS[difficulty] or nil
	local literal = config ~= nil and render_config(config) or nil
	LOOSE = LOOSE or strip_template(TEMPLATE, false)
	if literal == nil or LOOSE == nil then
		return nil, CODE.UNKNOWN_DIFFICULTY
	end
	return string.format(LOOSE, literal)
end

-- The same policy rendered from the unstripped template (comments kept). Only
-- for tests proving the stripped source is equivalent; it may exceed the
-- sandbox cap and is never sent to the policy worker.
function BaselinePolicy.readable_source(difficulty)
	local config = type(difficulty) == "string" and CONFIGS[difficulty] or nil
	local literal = config ~= nil and render_config(config) or nil
	if literal == nil then
		return nil, CODE.UNKNOWN_DIFFICULTY
	end
	return string.format(TEMPLATE, literal)
end

function BaselinePolicy.source(difficulty)
	if type(difficulty) ~= "string" then
		return nil, CODE.UNKNOWN_DIFFICULTY
	end
	local config = CONFIGS[difficulty]
	if config == nil then
		return nil, CODE.UNKNOWN_DIFFICULTY
	end
	local literal = render_config(config)
	if literal == nil then
		return nil, CODE.BAD_CONFIG
	end
	if STRIPPED == nil then
		return nil, CODE.BAD_SOURCE
	end
	local rendered = string.format(STRIPPED, literal)
	if type(rendered) ~= "string" or #rendered == 0 then
		return nil, CODE.BAD_SOURCE
	end
	if #rendered > MAX_SOURCE then
		return nil, CODE.TOO_LARGE
	end
	return rendered
end

return BaselinePolicy
