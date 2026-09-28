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
	item_joker = 300,
	item_consumable = 200,
	item_card = 120,
	item_booster = 250,
	voucher = 260,
	negative = 150,
	buy_edition = 40,
	slot_sell = 220,
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
		reserve = 16,
		play_junk = 550,
		discard_junk = 7000,
		discard_pair_pen = 24000,
		discard_flush_pen = 18000,
		discard_seal_pen = 14000,
		negative = 180,
		reroll_base = 45,
		reroll_surplus_cap = 100,
		leave_shop = 100,
		blind_skip = 30,
		booster_good = 150,
	}),
}

local ORDER = { "rookie", "competitive", "major_league" }

local TEMPLATE = [==[
local CONF = %s

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

local function rank_value(rank)
	if type(rank) ~= "string" then
		return nil
	end
	local n = #rank
	if n == 1 then
		if rank == "A" or rank == "a" then
			return 14
		end
		if rank == "K" or rank == "k" then
			return 13
		end
		if rank == "Q" or rank == "q" then
			return 12
		end
		if rank == "J" or rank == "j" then
			return 11
		end
		if rank == "T" or rank == "t" then
			return 10
		end
		local b = string.byte(rank, 1)
		if b ~= nil and b >= 50 and b <= 57 then
			return b - 48
		end
		return nil
	end
	if n == 2 and string.byte(rank, 1) == 49 and string.byte(rank, 2) == 48 then
		return 10
	end
	if rank == "Ace" or rank == "ace" then
		return 14
	end
	if rank == "King" or rank == "king" then
		return 13
	end
	if rank == "Queen" or rank == "queen" then
		return 12
	end
	if rank == "Jack" or rank == "jack" then
		return 11
	end
	if rank == "Ten" or rank == "ten" then
		return 10
	end
	return nil
end

local function suit_key(suit)
	if type(suit) ~= "string" then
		return nil
	end
	local c = string.sub(suit, 1, 1)
	if c == "H" or c == "h" then
		return "H"
	end
	if c == "D" or c == "d" then
		return "D"
	end
	if c == "C" or c == "c" then
		return "C"
	end
	if c == "S" or c == "s" then
		return "S"
	end
	return nil
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

local function find_by_id(list, ref)
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

local function cards_for(observation, refs)
	if type(refs) ~= "table" then
		return nil
	end
	local s = observation.self
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
		local card = find_by_id(hand, refs[i])
		if card == nil then
			return nil
		end
		out[i] = card
	end
	return out
end

local function has_straight(counts)
	if (counts[14] or 0) > 0 and (counts[2] or 0) > 0 and (counts[3] or 0) > 0 and (counts[4] or 0) > 0 and (counts[5] or 0) > 0 then
		return 5
	end
	for start = 2, 10 do
		if (counts[start] or 0) > 0 and (counts[start + 1] or 0) > 0 and (counts[start + 2] or 0) > 0 and (counts[start + 3] or 0) > 0 and (counts[start + 4] or 0) > 0 then
			return start + 4
		end
	end
	return nil
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

local function evaluate(cards)
	local n = #cards
	if n == 0 then
		return nil
	end
	local counts = {}
	local suitc = {}
	local sum = 0
	local bonus = 0
	local debuffed = 0
	for i = 1, n do
		local c = cards[i]
		if type(c) ~= "table" or c.redacted == true then
			return nil
		end
		local rv = rank_value(c.rank)
		local sk = suit_key(c.suit)
		if rv == nil or sk == nil then
			return nil
		end
		counts[rv] = (counts[rv] or 0) + 1
		suitc[sk] = (suitc[sk] or 0) + 1
		if c.debuff == true then
			debuffed = debuffed + 1
		else
			sum = sum + rv
			bonus = bonus + center_bonus(c.center) + edition_bonus(c.edition)
		end
	end
	local pairs_n = 0
	local trips_n = 0
	local quads_n = 0
	local pair_hi = 0
	local trip_hi = 0
	local quad_hi = 0
	local max_rank = 0
	for r = 2, 14 do
		local c = counts[r] or 0
		if c > 0 and r > max_rank then
			max_rank = r
		end
		if c == 4 then
			quads_n = quads_n + 1
			if r > quad_hi then
				quad_hi = r
			end
		end
		if c == 3 then
			trips_n = trips_n + 1
			if r > trip_hi then
				trip_hi = r
			end
		end
		if c == 2 then
			pairs_n = pairs_n + 1
			if r > pair_hi then
				pair_hi = r
			end
		end
	end
	local flush = false
	if n >= 5 then
		local keys = { "H", "D", "C", "S" }
		for i = 1, 4 do
			if (suitc[keys[i]] or 0) == n then
				flush = true
			end
		end
	end
	local straight_top = nil
	if n >= 5 then
		straight_top = has_straight(counts)
	end
	local v
	local primary
	local minimal
	if n == 5 and flush and straight_top ~= nil then
		v = 9
		primary = straight_top
		minimal = 5
	elseif quads_n >= 1 then
		v = 8
		primary = quad_hi
		minimal = 4
	elseif trips_n >= 1 and (pairs_n >= 1 or trips_n >= 2) then
		v = 7
		primary = trip_hi
		minimal = 5
	elseif flush then
		v = 6
		primary = max_rank
		minimal = 5
	elseif straight_top ~= nil then
		v = 5
		primary = straight_top
		minimal = 5
	elseif trips_n >= 1 then
		v = 4
		primary = trip_hi
		minimal = 3
	elseif pairs_n >= 2 then
		v = 3
		primary = pair_hi
		minimal = 4
	elseif pairs_n == 1 then
		v = 2
		primary = pair_hi
		minimal = 2
	else
		v = 1
		primary = max_rank
		minimal = 1
	end
	return v, primary, sum, n, minimal, bonus, debuffed
end

local function play_score(observation, action)
	local cards = cards_for(observation, action.card_refs)
	if cards == nil or #cards == 0 then
		return nil
	end
	local v, primary, sum, n, minimal, bonus, debuffed = evaluate(cards)
	if v == nil then
		return CONF.unknown + 1
	end
	local score = v * 100000 + primary * 1000 + sum * 2
	score = score - (n - minimal) * CONF.play_junk
	score = score + bonus * CONF.enhance_value
	score = score - debuffed * CONF.debuff_penalty
	return score
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

local function discard_score(observation, action)
	local state = observation.self
	if type(state) == "table" and state.hands == 0 then
		return nil
	end
	local refs = action.card_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	local cards = cards_for(observation, refs)
	if cards == nil then
		return nil
	end
	local hand = nil
	local s = observation.self
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

local function spendable(observation)
	local s = observation.self
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
	if interest > CONF.interest_cap then
		interest = CONF.interest_cap
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

local function buy_score(observation, action)
	local shop = observation.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = find_by_id(shop.items, action.item_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(observation)
	if spend == nil or spend < cost then
		return nil
	end
	local score = kind_value(item.kind)
	score = score + edition_value(item.edition)
	score = score + economy_bonus(spend - cost)
	return score
end


local function voucher_score(observation, action)
	local shop = observation.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = find_by_id(shop.vouchers, action.voucher_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(observation)
	if spend == nil or spend < cost then
		return nil
	end
	return CONF.voucher + economy_bonus(spend - cost)
end

local function open_booster_score(observation, action)
	local shop = observation.shop
	if type(shop) ~= "table" then
		return nil
	end
	local item = find_by_id(shop.boosters, action.item_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	local cost = item.cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(observation)
	if spend == nil or spend < cost then
		return nil
	end
	return CONF.item_booster + economy_bonus(spend - cost)
end

local function reroll_score(observation, action)
	local shop = observation.shop
	if type(shop) ~= "table" then
		return nil
	end
	local cost = shop.reroll_cost
	if type(cost) ~= "number" then
		return nil
	end
	local spend = spendable(observation)
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

local function blind_score(observation, action)
	if action.type == "SELECT_BLIND" then
		return CONF.blind_select
	end
	return CONF.blind_skip
end

local function booster_select_score(observation, action)
	local b = observation.booster
	if type(b) ~= "table" then
		return nil
	end
	local refs = action.card_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	local card = find_by_id(b.cards, refs[1])
	if card == nil then
		return nil
	end
	local score = CONF.booster_good
	if card.redacted ~= true then
		if card.kind == "joker" then
			score = score + CONF.booster_kind_joker
		elseif card.kind == "consumable" then
			score = score + CONF.booster_kind_consumable
		elseif card.kind == "card" then
			score = score + CONF.booster_kind_card
		end
	end
	return score
end

local function target_minimum(observation)
	local target = observation.consumable_target
	if type(target) == "table" and type(target.min_targets) == "number" then
		return target.min_targets
	end
	local context = observation.context
	if type(context) == "table" and type(context.min_targets) == "number" then
		return context.min_targets
	end
	return nil
end

local function target_or_use_score(observation, action)
	if action.type == "SELECT_TARGETS" then
		return CONF.select_targets
	end
	local refs = action.target_refs
	local count = 0
	if type(refs) == "table" then
		count = #refs
	end
	if observation.phase == "CONSUMABLE_SELECTION" then
		local minimum = target_minimum(observation)
		if minimum == nil or count < minimum then
			return nil
		end
		return CONF.use_consumable
	end
	if count > 0 then
		return nil
	end
	return CONF.use_consumable
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

local PINNED = {
	j_blueprint = true,
	j_brainstorm = true,
	j_misprint = true,
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
local function reorder_score(observation, action)
	local s = observation.self
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
	local order = action.order
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
		local joker = find_by_id(jokers, ref)
		if joker == nil then
			return nil
		end
		candidate[i] = joker_tier(joker)
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

local function recognized_joker(center)
	if type(center) ~= "string" then
		return false
	end
	return ADD_MULT[center] == true or X_MULT[center] == true or PINNED[center] == true
end

-- SHOP-only capacity sale. The baseline frees a joker slot only when:
--   * the phase is SHOP and the visible joker board is full;
--   * the sold candidate is a visible, non-debuffed, *un-editioned* owned copy
--     of a recognized vanilla joker center;
--   * the same visible center is on offer as a joker with a recognized
--     non-negative edition (a strict, source-grounded upgrade of the same base);
--   * that offered copy is already affordable from current spendable cash while
--     preserving the difficulty reserve (the observation exposes no sale
--     proceeds, so a sale is never assumed to fund the purchase).
-- Every unclear case (unknown/face-down/different center, debuffed card, an
-- already-editioned owned copy, a negative or unrecognized offered edition,
-- unaffordable price, non-full board) yields no score, so a sell is never a
-- fallback and the board is never dumped. Selling one copy drops the board below
-- full, so no further sale can score in the following frame.
local function sell_score(observation, action)
	if action.type ~= "SELL_JOKER" then
		return nil
	end
	if observation.phase ~= "SHOP" then
		return nil
	end
	local s = observation.self
	local shop = observation.shop
	if type(s) ~= "table" or type(shop) ~= "table" then
		return nil
	end
	local jokers = s.jokers
	if type(jokers) ~= "table" then
		return nil
	end
	local slots = observation.match
	if type(slots) ~= "table" or type(slots.joker_slots) ~= "number" then
		return nil
	end
	if #jokers < slots.joker_slots then
		return nil
	end
	local owned = find_by_id(jokers, action.joker_ref)
	if owned == nil or owned.redacted == true or owned.debuff == true then
		return nil
	end
	if owned.edition ~= nil then
		return nil
	end
	local center = owned.center
	if not recognized_joker(center) then
		return nil
	end
	local spend = spendable(observation)
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

local function score_of(observation, action)
	if type(action) ~= "table" then
		return nil
	end
	local kind = action.type
	if type(kind) ~= "string" then
		return nil
	end
	if kind == "PLAY_CARDS" then
		return play_score(observation, action)
	end
	if kind == "DISCARD_CARDS" then
		return discard_score(observation, action)
	end
	if kind == "SELECT_BLIND" or kind == "SKIP_BLIND" then
		return blind_score(observation, action)
	end
	if kind == "BUY_ITEM" then
		return buy_score(observation, action)
	end
	if kind == "BUY_VOUCHER" then
		return voucher_score(observation, action)
	end
	if kind == "OPEN_BOOSTER" then
		return open_booster_score(observation, action)
	end
	if kind == "REROLL" then
		return reroll_score(observation, action)
	end
	if kind == "LEAVE_SHOP" then
		return CONF.leave_shop
	end
	if kind == "SELL_JOKER" or kind == "SELL_CONSUMABLE" then
		return sell_score(observation, action)
	end
	if kind == "SELECT_BOOSTER_ITEM" then
		return booster_select_score(observation, action)
	end
	if kind == "SKIP_BOOSTER" then
		return CONF.booster_skip
	end
	if kind == "SELECT_TARGETS" or kind == "USE_CONSUMABLE" then
		return target_or_use_score(observation, action)
	end
	if kind == "REORDER_JOKERS" then
		return reorder_score(observation, action)
	end
	if kind == "REORDER_HAND" then
		return nil
	end
	return CONF.unknown
end

return function(observation, actions)
	if type(observation) ~= "table" or type(actions) ~= "table" then
		return nil
	end
	local limit = CONF.max_actions
	local count = #actions
	if count > limit then
		count = limit
	end
	local best = nil
	local best_score = nil
	local best_id = nil
	for i = 1, count do
		local action = actions[i]
		local score = score_of(observation, action)
		if score ~= nil and type(score) == "number" then
			local id = action.id
			if type(id) ~= "string" then
				id = ""
			end
			if best == nil or score > best_score or (score == best_score and byte_less(id, best_id)) then
				best = action
				best_score = score
				best_id = id
			end
		end
	end
	return best
end
]==]

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
	local rendered = string.format(TEMPLATE, literal)
	if type(rendered) ~= "string" or #rendered == 0 then
		return nil, CODE.BAD_SOURCE
	end
	if #rendered > MAX_SOURCE then
		return nil, CODE.TOO_LARGE
	end
	return rendered
end

return BaselinePolicy
