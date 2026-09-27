return function()
	local m = new_ai()
	local Codec = m.Codec
	local obs = m.Observation.factory(Codec)
	local acts = m.Actions.factory(obs, Codec)

	local seed = 246813579
	local function rnd(n)
		seed = (seed * 1664525 + 1013904223) % 2147483648
		return seed % n
	end
	local function pick(list)
		return list[rnd(#list) + 1]
	end
	local function range(a, b)
		return a + rnd(b - a + 1)
	end

	local PHASES = {
		"BLIND_SELECTION",
		"PLAY_HAND",
		"DISCARD",
		"SHOP",
		"BOOSTER_SELECTION",
		"CONSUMABLE_SELECTION",
		"MULTIPLAYER_PVP",
	}

	local SELF_PHASES = {
		BLIND_SELECTION = true,
		PLAY_HAND = true,
		DISCARD = true,
		SHOP = true,
		BOOSTER_SELECTION = true,
		CONSUMABLE_SELECTION = true,
		MULTIPLAYER_PVP = true,
	}

	local HAND_PHASES = {
		PLAY_HAND = true,
		DISCARD = true,
		MULTIPLAYER_PVP = true,
	}

	local REORDER_HAND_PHASES = {
		PLAY_HAND = true,
		DISCARD = true,
		MULTIPLAYER_PVP = true,
		CONSUMABLE_SELECTION = true,
		BOOSTER_SELECTION = true,
	}

	local ZONE_PAT = "^([0-9A-Za-z_%-]+):"

	local function ref_set(list)
		local set = {}
		if type(list) ~= "table" then
			return set
		end
		for i = 1, #list do
			local item = list[i]
			if type(item) == "table" and type(item.id) == "string" then
				set[item.id] = true
			end
		end
		return set
	end

	local function find_id(list, id)
		if type(list) ~= "table" or type(id) ~= "string" then
			return nil
		end
		for i = 1, #list do
			local item = list[i]
			if type(item) == "table" and item.id == id then
				return item
			end
		end
		return nil
	end

	local function join_ids(set)
		local out = {}
		for id in pairs(set) do
			out[#out + 1] = id
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	local function count_ids(set)
		local total = 0
		for _ in pairs(set) do
			total = total + 1
		end
		return total
	end

	local function id_set(list)
		local set = {}
		for i = 1, #list do
			set[list[i].id] = true
		end
		return set
	end

	local function is_perm(order, list, zone)
		if type(order) ~= "table" or type(list) ~= "table" or #order ~= #list or #order == 0 then
			return false
		end
		local have = ref_set(list)
		local seen = {}
		for i = 1, #order do
			local ref = order[i]
			if type(ref) ~= "string" or have[ref] ~= true or seen[ref] then
				return false
			end
			if string.match(ref, ZONE_PAT) ~= zone then
				return false
			end
			seen[ref] = true
		end
		return true
	end

	local function spendable(plain)
		local self = plain.self
		if type(self) ~= "table" or type(self.money) ~= "number" or type(self.credit_limit) ~= "number" then
			return nil
		end
		return self.money + self.credit_limit
	end

	local function affordable(plain, cost, voucher)
		local available = spendable(plain)
		if available == nil or type(cost) ~= "number" then
			return false
		end
		if voucher then
			return available >= cost
		end
		if cost <= 0 then
			return true
		end
		return available >= cost
	end

	local function capacity(plain, item, cert, count_key, slots_key)
		if cert.capacity_ok ~= true then
			return false
		end
		if item.edition == "negative" then
			return true
		end
		local match = plain.match
		if type(match) ~= "table" or type(match[slots_key]) ~= "number" then
			return false
		end
		local self = plain.self
		if type(self) ~= "table" or type(self[count_key]) ~= "table" then
			return false
		end
		return #self[count_key] < match[slots_key]
	end

	local function bounds(plain)
		local target = plain.consumable_target
		local lo
		local hi
		if type(target) == "table" then
			lo = target.min_targets
			hi = target.max_targets
		end
		local context = plain.context
		if type(context) == "table" then
			if lo == nil then
				lo = context.min_targets
			end
			if hi == nil then
				hi = context.max_targets
			end
		end
		if type(lo) ~= "number" or type(hi) ~= "number" or lo > hi then
			return nil
		end
		return lo, hi
	end

	local function expected_content(cert, plain, cov)
		local phase = plain.phase
		local context = plain.context
		local self = plain.self
		local t = cert.type

		if t == "SELECT_BLIND" or t == "SKIP_BLIND" then
			if phase ~= "BLIND_SELECTION" then
				return nil
			end
			cov.blind = true
			return { type = t }
		end

		if t == "PLAY_CARDS" or t == "DISCARD_CARDS" then
			if not HAND_PHASES[phase] then
				return nil
			end
			if type(self) ~= "table" or type(self.hand) ~= "table" then
				return nil
			end
			local refs = cert.card_refs
			if type(refs) ~= "table" or #refs == 0 then
				return nil
			end
			if t == "PLAY_CARDS" then
				if type(self.hands) ~= "number" or self.hands <= 0 then
					cov.hands_zero = true
					return nil
				end
				if type(context.max_play) ~= "number" then
					return nil
				end
				if #refs > context.max_play then
					cov.max_limit = true
					return nil
				end
			else
				if type(self.discards) ~= "number" or self.discards <= 0 then
					cov.discards_zero = true
					return nil
				end
				if type(context.max_discard) ~= "number" then
					return nil
				end
				if #refs > context.max_discard then
					cov.max_limit = true
					return nil
				end
			end
			local hand = ref_set(self.hand)
			local seen = {}
			for i = 1, #refs do
				local ref = refs[i]
				if hand[ref] ~= true or seen[ref] then
					return nil
				end
				seen[ref] = true
			end
			cov.play = true
			return { type = t, card_refs = refs }
		end

		if t == "BUY_ITEM" then
			if phase ~= "SHOP" then
				return nil
			end
			local shop = plain.shop
			if type(shop) ~= "table" or type(shop.items) ~= "table" then
				return nil
			end
			local item = find_id(shop.items, cert.item_ref)
			if item == nil or item.redacted == true then
				return nil
			end
			local kind = item.kind
			if kind ~= "card" and kind ~= "joker" and kind ~= "consumable" then
				return nil
			end
			if type(item.cost) ~= "number" then
				return nil
			end
			if not affordable(plain, item.cost, false) then
				cov.affordable_false = true
				return nil
			end
			cov.affordable_true = true
			if kind == "joker" then
				if not capacity(plain, item, cert, "jokers", "joker_slots") then
					cov.capacity_denied = true
					return nil
				end
			elseif kind == "consumable" then
				if not capacity(plain, item, cert, "consumables", "consumable_slots") then
					cov.capacity_denied = true
					return nil
				end
			end
			if item.edition == "negative" and cert.capacity_ok == true then
				cov.negative_bypass = true
			end
			return { type = t, item_ref = cert.item_ref }
		end

		if t == "OPEN_BOOSTER" then
			if phase ~= "SHOP" then
				return nil
			end
			local shop = plain.shop
			if type(shop) ~= "table" or type(shop.boosters) ~= "table" then
				return nil
			end
			local item = find_id(shop.boosters, cert.item_ref)
			if item == nil or item.redacted == true then
				return nil
			end
			if item.kind ~= "booster" then
				return nil
			end
			if type(item.cost) ~= "number" then
				return nil
			end
			if not affordable(plain, item.cost, false) then
				cov.affordable_false = true
				return nil
			end
			cov.open_booster = true
			return { type = t, item_ref = cert.item_ref }
		end

		if t == "BUY_VOUCHER" then
			if phase ~= "SHOP" then
				return nil
			end
			local shop = plain.shop
			if type(shop) ~= "table" or type(shop.vouchers) ~= "table" then
				return nil
			end
			local voucher = find_id(shop.vouchers, cert.voucher_ref)
			if voucher == nil or voucher.redacted == true then
				return nil
			end
			if type(voucher.cost) ~= "number" then
				return nil
			end
			if not affordable(plain, voucher.cost, true) then
				cov.voucher_denied = true
				return nil
			end
			cov.voucher_accepted = true
			return { type = t, voucher_ref = cert.voucher_ref }
		end

		if t == "REROLL" then
			if phase ~= "SHOP" then
				return nil
			end
			local shop = plain.shop
			if type(shop) ~= "table" or type(shop.reroll_cost) ~= "number" then
				return nil
			end
			if not affordable(plain, shop.reroll_cost, false) then
				cov.affordable_false = true
				return nil
			end
			return { type = t }
		end

		if t == "LEAVE_SHOP" then
			if phase ~= "SHOP" then
				return nil
			end
			return { type = t }
		end

		if t == "SELL_JOKER" or t == "SELL_CONSUMABLE" then
			if not SELF_PHASES[phase] or type(self) ~= "table" then
				return nil
			end
			if t == "SELL_JOKER" then
				local item = find_id(self.jokers, cert.joker_ref)
				if item == nil or item.redacted == true then
					return nil
				end
				cov.sell = true
				return { type = t, joker_ref = cert.joker_ref }
			end
			local item = find_id(self.consumables, cert.consumable_ref)
			if item == nil or item.redacted == true then
				return nil
			end
			cov.sell = true
			return { type = t, consumable_ref = cert.consumable_ref }
		end

		if t == "SELECT_BOOSTER_ITEM" then
			if phase ~= "BOOSTER_SELECTION" then
				return nil
			end
			local booster = plain.booster
			if type(booster) ~= "table" or type(booster.choices) ~= "number" or booster.choices <= 0 then
				return nil
			end
			if type(booster.cards) ~= "table" then
				return nil
			end
			local refs = cert.card_refs
			if type(refs) ~= "table" or #refs ~= 1 then
				return nil
			end
			local item = find_id(booster.cards, refs[1])
			if item == nil or item.redacted == true then
				return nil
			end
			if item.kind == "joker" then
				if not capacity(plain, item, cert, "jokers", "joker_slots") then
					cov.capacity_denied = true
					return nil
				end
			elseif item.kind == "consumable" then
				if not capacity(plain, item, cert, "consumables", "consumable_slots") then
					cov.capacity_denied = true
					return nil
				end
			end
			cov.booster_select = true
			return { type = t, card_refs = { refs[1] } }
		end

		if t == "SKIP_BOOSTER" then
			if phase ~= "BOOSTER_SELECTION" or type(plain.booster) ~= "table" then
				return nil
			end
			cov.booster_skip = true
			return { type = t }
		end

		if t == "USE_CONSUMABLE" then
			if not SELF_PHASES[phase] or type(self) ~= "table" or type(self.consumables) ~= "table" then
				return nil
			end
			local source = find_id(self.consumables, cert.source_ref)
			if source == nil or source.redacted == true then
				return nil
			end
			local refs = cert.target_refs
			if type(refs) ~= "table" then
				refs = {}
			end
			if #refs == 0 then
				if phase == "CONSUMABLE_SELECTION" then
					local target = plain.consumable_target
					if type(target) ~= "table" then
						return nil
					end
					if type(target.source_ref) ~= "string" or target.source_ref ~= cert.source_ref then
						cov.source_mismatch = true
						return nil
					end
					local lo = bounds(plain)
					if lo == nil or lo ~= 0 then
						cov.empty_min = true
						return nil
					end
				end
				cov.use_empty = true
				return { type = t, source_ref = cert.source_ref, target_refs = {} }
			end
			if phase ~= "CONSUMABLE_SELECTION" or context.target_selection ~= true then
				return nil
			end
			local lo, hi = bounds(plain)
			if lo == nil then
				return nil
			end
			if #refs < lo or #refs > hi then
				cov.target_bounds = true
				return nil
			end
			local target = plain.consumable_target
			if type(target) ~= "table" or type(target.targets) ~= "table" then
				return nil
			end
			if type(target.source_ref) ~= "string" or target.source_ref ~= cert.source_ref then
				cov.source_mismatch = true
				return nil
			end
			local allowed = ref_set(target.targets)
			local seen = {}
			for i = 1, #refs do
				local ref = refs[i]
				if allowed[ref] ~= true or seen[ref] then
					return nil
				end
				seen[ref] = true
			end
			cov.use_targets = true
			return { type = t, source_ref = cert.source_ref, target_refs = refs }
		end

		if t == "SELECT_TARGETS" then
			if phase ~= "CONSUMABLE_SELECTION" or context.target_selection ~= true then
				return nil
			end
			local refs = cert.target_refs
			if type(refs) ~= "table" or #refs == 0 then
				return nil
			end
			local lo, hi = bounds(plain)
			if lo == nil then
				return nil
			end
			if #refs < lo or #refs > hi then
				cov.target_bounds = true
				return nil
			end
			local target = plain.consumable_target
			if type(target) ~= "table" or type(target.source_ref) ~= "string" then
				return nil
			end
			local allowed = ref_set(target.targets)
			local seen = {}
			for i = 1, #refs do
				local ref = refs[i]
				if allowed[ref] ~= true or seen[ref] then
					return nil
				end
				seen[ref] = true
			end
			cov.select_targets = true
			return { type = t, target_refs = refs }
		end

		if t == "REORDER_JOKERS" or t == "REORDER_HAND" then
			if type(self) ~= "table" then
				return nil
			end
			if t == "REORDER_JOKERS" then
				if not SELF_PHASES[phase] or not is_perm(cert.order, self.jokers, "joker") then
					return nil
				end
				cov.reorder = true
				return { type = t, order = cert.order }
			end
			if not REORDER_HAND_PHASES[phase] or not is_perm(cert.order, self.hand, "hand") then
				return nil
			end
			cov.reorder = true
			return { type = t, order = cert.order }
		end

		return nil
	end

	local function expected_ids(plain, cov)
		local set = {}
		local phase = plain.phase
		local context = plain.context
		if type(phase) ~= "string" or type(context) ~= "table" then
			return set
		end
		if context.blocked ~= false or context.timer_expired ~= false then
			return set
		end
		if phase == "MATCH_COMPLETE" then
			return set
		end
		local certificates = plain.certificates
		if type(certificates) ~= "table" or type(certificates.items) ~= "table" then
			return set
		end
		for i = 1, #certificates.items do
			local cert = certificates.items[i]
			if type(cert) == "table" and cert.certified == true and type(cert.type) == "string" then
				local content = expected_content(cert, plain, cov)
				if content ~= nil then
					local id = Codec.encode(content)
					if type(id) == "string" then
						set[id] = true
					end
				end
			end
		end
		return set
	end

	local function refs_for(zone, n)
		local refs = {}
		for i = 1, n do
			refs[i] = zone .. ":" .. i
		end
		return refs
	end

	local function build(phase)
		local f = syn(phase)
		f.self.money = range(-6, 25)
		f.self.credit_limit = range(0, 6)
		f.match.joker_slots = range(0, 4)
		f.match.consumable_slots = range(0, 3)
		local items = {}
		if phase == "BLIND_SELECTION" then
			items = { cert("SELECT_BLIND"), cert("SKIP_BLIND") }
		elseif HAND_PHASES[phase] then
			f.self.hand_visible = true
			local n = range(0, 5)
			local hand = {}
			for i = 1, n do
				hand[i] = entity({ rank = pick({ "A", "K", "Q" }), suit = pick({ "Spades", "Hearts", "Clubs", "Diamonds" }), center = "c_" .. i })
			end
			f.self.hand = hand
			f.self.hands = range(0, 3)
			f.self.discards = range(0, 3)
			f.context.max_play = range(0, 5)
			f.context.max_discard = range(0, 5)
			if n > 0 then
				local refs = refs_for("hand", n)
				items[#items + 1] = cert("PLAY_CARDS", { card_refs = refs })
				items[#items + 1] = cert("DISCARD_CARDS", { card_refs = refs })
				if rnd(2) == 1 then
					items[#items + 1] = cert("REORDER_HAND", { order = refs })
				end
			end
		elseif phase == "SHOP" then
			local jokers = {}
			for i = 1, range(0, 3) do
				jokers[i] = entity({ center = "j_" .. i })
			end
			f.self.jokers = jokers
			local cons = {}
			for i = 1, range(0, 2) do
				cons[i] = entity({ center = "c_" .. i })
			end
			f.self.consumables = cons
			local shop_items = {}
			for i = 1, range(0, 4) do
				local kind = pick({ "card", "joker", "consumable" })
				local item = entity({ kind = kind, center = "s_" .. i, cost = range(0, 8) })
				if (kind == "joker" or kind == "consumable") and rnd(4) == 1 then
					item.edition = "negative"
				end
				shop_items[i] = item
			end
			local shop_boosters = {}
			for i = 1, range(0, 2) do
				shop_boosters[i] = entity({ kind = "booster", center = "bb_" .. i, cost = range(0, 8) })
			end
			f.shop = {
				reroll_cost = range(0, 6),
				items = shop_items,
				vouchers = { entity({ center = "v_1", cost = range(0, 4) }) },
				boosters = shop_boosters,
			}
			items[#items + 1] = cert("REROLL")
			items[#items + 1] = cert("LEAVE_SHOP")
			for i = 1, #shop_items do
				items[#items + 1] = cert("BUY_ITEM", { item_ref = "shop:" .. i, capacity_ok = (rnd(2) == 1) })
			end
			for i = 1, #shop_boosters do
				items[#items + 1] = cert("OPEN_BOOSTER", { item_ref = "shop_booster:" .. i })
			end
			items[#items + 1] = cert("BUY_VOUCHER", { voucher_ref = "shop_voucher:1" })
			local jrefs = refs_for("joker", #jokers)
			for i = 1, #jrefs do
				items[#items + 1] = cert("SELL_JOKER", { joker_ref = jrefs[i] })
			end
			local crefs = refs_for("consumable", #cons)
			for i = 1, #crefs do
				items[#items + 1] = cert("SELL_CONSUMABLE", { consumable_ref = crefs[i] })
			end
		elseif phase == "BOOSTER_SELECTION" then
			local jokers = {}
			for i = 1, range(0, 2) do
				jokers[i] = entity({ center = "j_" .. i })
			end
			f.self.jokers = jokers
			f.booster = {
				kind = "Buffoon",
				choices = range(0, 2),
				cards = { entity({ kind = "joker", center = "b_1" }), entity({ kind = "card", center = "b_2", rank = "A", suit = "Spades" }) },
			}
			items[#items + 1] = cert("SKIP_BOOSTER")
			items[#items + 1] = cert("SELECT_BOOSTER_ITEM", { card_refs = { "booster:1" }, capacity_ok = true })
			items[#items + 1] = cert("SELECT_BOOSTER_ITEM", { card_refs = { "booster:2" } })
		elseif phase == "CONSUMABLE_SELECTION" then
			f.self.consumables = { entity({ center = "c_1" }) }
			f.consumable_target = {
				source = entity({ center = "c_1" }),
				source_ref = "consumable:1",
				targets = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) },
				min_targets = range(0, 1),
				max_targets = range(1, 2),
			}
			f.context.target_selection = (rnd(3) ~= 0)
			f.context.min_targets = range(0, 1)
			f.context.max_targets = range(1, 2)
			items[#items + 1] = cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = {} })
			if rnd(2) == 1 then
				items[#items + 1] = cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = { "target:1" } })
			end
			items[#items + 1] = cert("SELECT_TARGETS", { target_refs = { "target:1" } })
			if rnd(2) == 1 then
				items[#items + 1] = cert("SELECT_TARGETS", { target_refs = { "target:1", "target:2" } })
			end
		end
		f.certificates.items = items
		if rnd(3) == 0 then
			f.seed = rnd(1000)
			f.self.hidden = { rnd(5) }
			f.match.private = rnd(9)
		end
		return f
	end

	test("property.randomized_frames_match_independent_oracle", function()
		local cov = {}
		local produced = 0
		local denied_somewhere = 0
		for i = 1, 320 do
			count(1)
			local phase = pick(PHASES)
			local f = build(phase)
			local handle, code = obs.observe(f)
			truthy(handle, "observe " .. i .. " " .. phase .. " " .. tostring(code))
			local plain = obs.export(handle)
			local expected = expected_ids(plain, cov)
			local got = id_set(actions_of(acts, handle))
			eq(join_ids(expected), join_ids(got), "exact candidate set " .. phase .. " iter " .. i)
			truthy(count_ids(got) <= 128, "bounded output")
			if count_ids(expected) > 0 then
				produced = produced + 1
			end
			if count_ids(expected) < #plain.certificates.items then
				denied_somewhere = denied_somewhere + 1
			end
			local all_ids = export_ids(plain)
			local list = actions_of(acts, handle)
			for j = 1, #list do
				local a = list[j]
				local function check(ref)
					truthy(all_ids[ref], "ref exists " .. tostring(ref))
				end
				if a.card_refs then
					for k = 1, #a.card_refs do
						check(a.card_refs[k])
					end
				end
				if a.target_refs then
					for k = 1, #a.target_refs do
						check(a.target_refs[k])
					end
				end
				if a.order then
					for k = 1, #a.order do
						check(a.order[k])
					end
				end
				if a.item_ref then
					check(a.item_ref)
				end
				if a.joker_ref then
					check(a.joker_ref)
				end
				if a.consumable_ref then
					check(a.consumable_ref)
				end
				if a.voucher_ref then
					check(a.voucher_ref)
				end
				if a.source_ref then
					check(a.source_ref)
				end
				local normalized, vcode = acts.validate(handle, a)
				truthy(normalized, "validate " .. tostring(vcode))
				eq(normalized.id, a.id, "validate id")
			end
			local handle2 = ois(obs, clone(f))
			eq(obs.canonical(handle2), obs.canonical(handle), "deterministic canonical")
			eq(action_ids(actions_of(acts, handle2)), action_ids(list), "deterministic actions")
		end
		truthy(produced > 0, "generator produced actions in randomized frames")
		truthy(denied_somewhere > 0, "some certificates denied alongside accepted ones")
		truthy(cov.affordable_true == true, "coverage affordability accepted")
		truthy(cov.affordable_false == true, "coverage affordability denied")
		truthy(cov.voucher_denied == true, "coverage voucher predicate denied")
		truthy(cov.capacity_denied == true, "coverage capacity denied")
		truthy(cov.negative_bypass == true, "coverage negative edition bypass")
		truthy(cov.hands_zero == true or cov.discards_zero == true, "coverage resource zero")
		truthy(cov.max_limit == true, "coverage selection limit")
		truthy(cov.target_bounds == true, "coverage target bounds")
		truthy(cov.use_empty == true, "coverage empty-target use")
		truthy(cov.use_targets == true or cov.select_targets == true, "coverage target selection")
		truthy(cov.sell == true, "coverage sell")
		truthy(cov.reorder == true, "coverage reorder")
		truthy(cov.booster_select == true, "coverage booster select")
		truthy(cov.booster_skip == true, "coverage booster skip")
		truthy(cov.blind == true, "coverage blind")
	end)

	test("property.oracle_negative_controls", function()
		local f = syn("SHOP")
		f.self.money = -3
		f.self.credit_limit = 0
		f.shop = {
			reroll_cost = 0,
			items = { entity({ kind = "card", center = "c_1", cost = 0 }) },
			vouchers = { entity({ center = "v_1", cost = 0 }) },
			boosters = {},
		}
		f.certificates.items = {
			cert("BUY_VOUCHER", { voucher_ref = "shop_voucher:1" }),
			cert("BUY_ITEM", { item_ref = "shop:1" }),
		}
		local h = ois(obs, f)
		local expected = expected_ids(obs.export(h), {})
		eq(count_ids(expected), 1, "voucher free denied, card free accepted")
		eq(join_ids(expected), join_ids(id_set(actions_of(acts, h))), "oracle matches")

		local g = syn("SHOP")
		g.self.money = 10
		g.self.jokers = { entity({ center = "j_1" }) }
		g.shop = {
			reroll_cost = 0,
			items = { entity({ kind = "joker", center = "j_9", cost = 1, edition = "negative" }) },
			vouchers = {},
			boosters = {},
		}
		g.certificates.items = {
			cert("BUY_ITEM", { item_ref = "shop:1" }),
			cert("SELL_JOKER", { joker_ref = "joker:1" }),
		}
		local h2 = ois(obs, g)
		local expected2 = expected_ids(obs.export(h2), {})
		eq(count_ids(expected2), 1, "negative edition without capacity_ok denied; sell accepted")
		eq(join_ids(expected2), join_ids(id_set(actions_of(acts, h2))), "oracle matches negative control")
	end)

	test("property.malformed_frames_expected_codes", function()
		local cases = {
			{
				name = "version",
				apply = function(f)
					f.schema_version = 2
				end,
				code = obs.CODE.BAD_VERSION,
			},
			{
				name = "phase",
				apply = function(f)
					f.phase = "NOPE"
				end,
				code = obs.CODE.UNKNOWN_PHASE,
			},
			{
				name = "money",
				apply = function(f)
					f.self.money = 0 / 0
				end,
				code = obs.CODE.BAD_FIELD,
			},
			{
				name = "sparse_hand",
				apply = function(f)
					f.phase = "PLAY_HAND"
					f.self.hand_visible = true
					f.self.hand = { [1] = entity({}), [4] = entity({}) }
				end,
				code = obs.CODE.SPARSE_ARRAY,
			},
			{
				name = "cert_type",
				apply = function(f)
					f.certificates.items = { { type = "NOPE", certified = true } }
				end,
				code = obs.CODE.BAD_CERTIFICATE,
			},
			{
				name = "context",
				apply = function(f)
					f.context = { blocked = "yes" }
				end,
				code = obs.CODE.BAD_CONTEXT,
			},
			{
				name = "valid_control",
				apply = function() end,
				code = nil,
			},
		}
		for i = 1, 200 do
			count(1)
			local case = pick(cases)
			local f = syn(pick(PHASES))
			case.apply(f)
			local ok, handle, code = pcall(obs.observe, f)
			truthy(ok, "observe no crash " .. case.name .. " iter " .. i)
			if case.code == nil then
				truthy(handle ~= nil, "positive control iter " .. i)
			else
				eq(handle, nil, "malformed handle " .. case.name .. " iter " .. i)
				eq(code, case.code, "expected code " .. case.name .. " iter " .. i)
			end
		end
	end)
end
