local Actions = {}

local MAX_ACTIONS = 128
local MAX_ARRAY = 128
local REF_PAT = "^[0-9A-Za-z_%-]+:[0-9]+$"

local CODE = {
	OK = "ok",
	BAD_OBSERVATION = "actions_bad_observation",
	BAD_CODEC = "actions_bad_codec",
	UNKNOWN_HANDLE = "actions_unknown_handle",
	BAD_ACTION = "actions_bad_action",
	UNKNOWN_TYPE = "actions_unknown_type",
	BAD_ID = "actions_bad_id",
	ID_MISMATCH = "actions_id_mismatch",
	NOT_CERTIFIED = "actions_not_certified",
	TOO_MANY = "actions_too_many",
}

local function copy_codes(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

local SELF_PHASES = {
	BLIND_SELECTION = true,
	PLAY_HAND = true,
	DISCARD = true,
	SHOP = true,
	BOOSTER_SELECTION = true,
	CONSUMABLE_SELECTION = true,
	MULTIPLAYER_PVP = true,
}

local HANDS_PHASES = {
	PLAY_HAND = true,
	DISCARD = true,
	MULTIPLAYER_PVP = true,
}

local ACTIONS_PHASES = {
	SELECT_BLIND = { BLIND_SELECTION = true },
	SKIP_BLIND = { BLIND_SELECTION = true },
	-- The real Multiplayer timer button (ui/game/timer.lua `mp_timer_button`):
	-- offered only while the AI has readied the PvP blind and the button is lit.
	START_TIMER = { BLIND_SELECTION = true },
	PLAY_CARDS = HANDS_PHASES,
	DISCARD_CARDS = HANDS_PHASES,
	BUY_ITEM = { SHOP = true },
	SELL_JOKER = SELF_PHASES,
	SELL_CONSUMABLE = SELF_PHASES,
	REROLL = { SHOP = true },
	BUY_VOUCHER = { SHOP = true },
	OPEN_BOOSTER = { SHOP = true },
	LEAVE_SHOP = { SHOP = true },
	SELECT_BOOSTER_ITEM = { BOOSTER_SELECTION = true },
	SKIP_BOOSTER = { BOOSTER_SELECTION = true },
	USE_CONSUMABLE = SELF_PHASES,
	-- Targeted Tarot on hand cards: the real highlight-then-Use path, only in
	-- the hand phases where production emits it (docs/HAND_TARGETS_DESIGN.md).
	USE_CONSUMABLE_ON_HAND = { PLAY_HAND = true, MULTIPLAYER_PVP = true },
	SELECT_TARGETS = { CONSUMABLE_SELECTION = true },
	REORDER_JOKERS = SELF_PHASES,
	REORDER_HAND = {
		PLAY_HAND = true,
		DISCARD = true,
		MULTIPLAYER_PVP = true,
		CONSUMABLE_SELECTION = true,
		BOOSTER_SELECTION = true,
	},
}

local ACTION_KEYS = {
	SELECT_BLIND = { type = true },
	SKIP_BLIND = { type = true },
	START_TIMER = { type = true },
	PLAY_CARDS = { type = true, card_refs = true },
	DISCARD_CARDS = { type = true, card_refs = true },
	BUY_ITEM = { type = true, item_ref = true },
	SELL_JOKER = { type = true, joker_ref = true },
	SELL_CONSUMABLE = { type = true, consumable_ref = true },
	REROLL = { type = true },
	BUY_VOUCHER = { type = true, voucher_ref = true },
	OPEN_BOOSTER = { type = true, item_ref = true },
	LEAVE_SHOP = { type = true },
	SELECT_BOOSTER_ITEM = { type = true, card_refs = true },
	SKIP_BOOSTER = { type = true },
	USE_CONSUMABLE = { type = true, source_ref = true, target_refs = true },
	USE_CONSUMABLE_ON_HAND = { type = true, source_ref = true, card_refs = true },
	SELECT_TARGETS = { type = true, target_refs = true },
	REORDER_JOKERS = { type = true, order = true },
	REORDER_HAND = { type = true, order = true },
}

local REQUIRED_FIELDS = {
	PLAY_CARDS = { card_refs = true },
	DISCARD_CARDS = { card_refs = true },
	BUY_ITEM = { item_ref = true },
	SELL_JOKER = { joker_ref = true },
	SELL_CONSUMABLE = { consumable_ref = true },
	BUY_VOUCHER = { voucher_ref = true },
	OPEN_BOOSTER = { item_ref = true },
	SELECT_BOOSTER_ITEM = { card_refs = true },
	USE_CONSUMABLE = { source_ref = true },
	USE_CONSUMABLE_ON_HAND = { source_ref = true, card_refs = true },
	SELECT_TARGETS = { target_refs = true },
	REORDER_JOKERS = { order = true },
	REORDER_HAND = { order = true },
}

local ARRAY_FIELDS = { card_refs = true, target_refs = true, order = true }

local ARRAY_NONEMPTY = {
	PLAY_CARDS = { card_refs = true },
	DISCARD_CARDS = { card_refs = true },
	SELECT_BOOSTER_ITEM = { card_refs = true },
	USE_CONSUMABLE_ON_HAND = { card_refs = true },
	SELECT_TARGETS = { target_refs = true },
	REORDER_JOKERS = { order = true },
	REORDER_HAND = { order = true },
}

local function is_plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_ref(value)
	return type(value) == "string" and #value > 0 and #value <= 64 and string.match(value, REF_PAT) ~= nil
end

local function zone_of(ref)
	return string.match(ref, "^([0-9A-Za-z_%-]+):")
end

local function array_len(t)
	local count = 0
	local maxn = 0
	for key in next, t do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		count = count + 1
		if count > MAX_ARRAY then
			return nil
		end
		if key > maxn then
			maxn = key
		end
	end
	if count ~= maxn then
		return nil
	end
	return maxn
end

local function copy_array(list)
	local out = {}
	for i = 1, #list do
		out[i] = list[i]
	end
	return out
end

local function find_entity(list, ref)
	if type(list) ~= "table" or type(ref) ~= "string" then
		return nil
	end
	for i = 1, #list do
		local entity = list[i]
		if type(entity) == "table" and entity.id == ref then
			return entity
		end
	end
	return nil
end

local function ids_of(list)
	local set = {}
	if type(list) ~= "table" then
		return set
	end
	for i = 1, #list do
		local entity = list[i]
		if type(entity) == "table" and type(entity.id) == "string" then
			set[entity.id] = true
		end
	end
	return set
end

local function is_permutation(order, list, expected_zone)
	if type(order) ~= "table" or type(list) ~= "table" then
		return false
	end
	local n = array_len(order)
	if n == nil or n ~= #list or n == 0 then
		return false
	end
	local seen = {}
	for i = 1, n do
		local ref = order[i]
		if not is_ref(ref) or zone_of(ref) ~= expected_zone then
			return false
		end
		if seen[ref] then
			return false
		end
		seen[ref] = true
	end
	for i = 1, #list do
		local entity = list[i]
		if type(entity) ~= "table" or seen[entity.id] ~= true then
			return false
		end
	end
	return true
end

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

local function spendable(obs)
	local self = obs.self
	if type(self) ~= "table" then
		return nil
	end
	if type(self.money) ~= "number" or type(self.credit_limit) ~= "number" then
		return nil
	end
	return self.money + self.credit_limit
end

local function affordable(obs, cost, voucher)
	local available = spendable(obs)
	if available == nil then
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

local function capacity_ok(item, cert, obs, count_key, slots_key)
	if cert.capacity_ok ~= true then
		return false
	end
	if item.edition == "negative" then
		return true
	end
	local match = obs.match
	if type(match) ~= "table" or type(match[slots_key]) ~= "number" then
		return false
	end
	local self = obs.self
	if type(self) ~= "table" or type(self[count_key]) ~= "table" then
		return false
	end
	return #self[count_key] < match[slots_key]
end

local function target_bounds(obs)
	local min_value
	local max_value
	local target = obs.consumable_target
	if type(target) == "table" then
		min_value = target.min_targets
		max_value = target.max_targets
	end
	local context = obs.context
	if type(context) == "table" then
		if min_value == nil then
			min_value = context.min_targets
		end
		if max_value == nil then
			max_value = context.max_targets
		end
	end
	if type(min_value) ~= "number" or type(max_value) ~= "number" then
		return nil
	end
	if min_value > max_value then
		return nil
	end
	return min_value, max_value
end

local function build_cards(t, context, obs, cert)
	local self = obs.self
	if type(self) ~= "table" then
		return nil
	end
	local hand = self.hand
	if type(hand) ~= "table" then
		return nil
	end
	local refs = cert.card_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	if t == "PLAY_CARDS" then
		if type(self.hands) ~= "number" or self.hands <= 0 then
			return nil
		end
		if type(context.max_play) ~= "number" then
			return nil
		end
		if #refs > context.max_play then
			return nil
		end
	else
		if type(self.discards) ~= "number" or self.discards <= 0 then
			return nil
		end
		if type(context.max_discard) ~= "number" then
			return nil
		end
		if #refs > context.max_discard then
			return nil
		end
	end
	local hand_ids = ids_of(hand)
	local seen = {}
	for i = 1, #refs do
		local ref = refs[i]
		if not is_ref(ref) or zone_of(ref) ~= "hand" or hand_ids[ref] ~= true then
			return nil
		end
		if seen[ref] then
			return nil
		end
		seen[ref] = true
	end
	return { type = t, card_refs = copy_array(refs) }
end

local function build_buy_item(obs, cert)
	local shop = obs.shop
	if type(shop) ~= "table" or type(shop.items) ~= "table" then
		return nil
	end
	local item = find_entity(shop.items, cert.item_ref)
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
	if not affordable(obs, item.cost, false) then
		return nil
	end
	if kind == "joker" then
		if not capacity_ok(item, cert, obs, "jokers", "joker_slots") then
			return nil
		end
	elseif kind == "consumable" then
		if not capacity_ok(item, cert, obs, "consumables", "consumable_slots") then
			return nil
		end
	end
	return { type = "BUY_ITEM", item_ref = cert.item_ref }
end

local function build_open_booster(obs, cert)
	local shop = obs.shop
	if type(shop) ~= "table" or type(shop.boosters) ~= "table" then
		return nil
	end
	local item = find_entity(shop.boosters, cert.item_ref)
	if item == nil or item.redacted == true then
		return nil
	end
	if item.kind ~= "booster" then
		return nil
	end
	if type(item.cost) ~= "number" then
		return nil
	end
	if not affordable(obs, item.cost, false) then
		return nil
	end
	return { type = "OPEN_BOOSTER", item_ref = cert.item_ref }
end

local function build_buy_voucher(obs, cert)
	local shop = obs.shop
	if type(shop) ~= "table" or type(shop.vouchers) ~= "table" then
		return nil
	end
	local voucher = find_entity(shop.vouchers, cert.voucher_ref)
	if voucher == nil or voucher.redacted == true then
		return nil
	end
	if type(voucher.cost) ~= "number" then
		return nil
	end
	if not affordable(obs, voucher.cost, true) then
		return nil
	end
	return { type = "BUY_VOUCHER", voucher_ref = cert.voucher_ref }
end

local function build_reroll(obs)
	local shop = obs.shop
	if type(shop) ~= "table" then
		return nil
	end
	if type(shop.reroll_cost) ~= "number" then
		return nil
	end
	if not affordable(obs, shop.reroll_cost, false) then
		return nil
	end
	return { type = "REROLL" }
end

local function build_sell(t, obs, cert)
	local self = obs.self
	if type(self) ~= "table" then
		return nil
	end
	if t == "SELL_JOKER" then
		local entity = find_entity(self.jokers, cert.joker_ref)
		if entity == nil or entity.redacted == true then
			return nil
		end
		return { type = t, joker_ref = cert.joker_ref }
	end
	local entity = find_entity(self.consumables, cert.consumable_ref)
	if entity == nil or entity.redacted == true then
		return nil
	end
	return { type = t, consumable_ref = cert.consumable_ref }
end

local function build_select_booster_item(obs, cert)
	local booster = obs.booster
	if type(booster) ~= "table" then
		return nil
	end
	if type(booster.choices) ~= "number" or booster.choices <= 0 then
		return nil
	end
	if type(booster.cards) ~= "table" then
		return nil
	end
	local refs = cert.card_refs
	if type(refs) ~= "table" or #refs ~= 1 then
		return nil
	end
	local item = find_entity(booster.cards, refs[1])
	if item == nil or item.redacted == true then
		return nil
	end
	if item.kind == "joker" then
		if not capacity_ok(item, cert, obs, "jokers", "joker_slots") then
			return nil
		end
	elseif item.kind == "consumable" then
		if not capacity_ok(item, cert, obs, "consumables", "consumable_slots") then
			return nil
		end
	end
	return { type = "SELECT_BOOSTER_ITEM", card_refs = { refs[1] } }
end

local function build_use_consumable(phase, context, obs, cert)
	local self = obs.self
	if type(self) ~= "table" or type(self.consumables) ~= "table" then
		return nil
	end
	local source = find_entity(self.consumables, cert.source_ref)
	if source == nil or source.redacted == true then
		return nil
	end
	local refs = cert.target_refs
	if type(refs) ~= "table" then
		refs = {}
	end
	if #refs == 0 then
		if phase == "CONSUMABLE_SELECTION" then
			local target = obs.consumable_target
			if type(target) ~= "table" then
				return nil
			end
			if type(target.source_ref) ~= "string" or target.source_ref ~= cert.source_ref then
				return nil
			end
			local min_value = target_bounds(obs)
			if min_value == nil or min_value ~= 0 then
				return nil
			end
		end
		return { type = "USE_CONSUMABLE", source_ref = cert.source_ref, target_refs = {} }
	end
	if phase ~= "CONSUMABLE_SELECTION" or context.target_selection ~= true then
		return nil
	end
	local min_value, max_value = target_bounds(obs)
	if min_value == nil then
		return nil
	end
	if #refs < min_value or #refs > max_value then
		return nil
	end
	local target = obs.consumable_target
	if type(target) ~= "table" or type(target.targets) ~= "table" then
		return nil
	end
	if type(target.source_ref) ~= "string" or target.source_ref ~= cert.source_ref then
		return nil
	end
	local allowed = ids_of(target.targets)
	local seen = {}
	for i = 1, #refs do
		local ref = refs[i]
		if not is_ref(ref) or zone_of(ref) ~= "target" or allowed[ref] ~= true then
			return nil
		end
		if seen[ref] then
			return nil
		end
		seen[ref] = true
	end
	return { type = "USE_CONSUMABLE", source_ref = cert.source_ref, target_refs = copy_array(refs) }
end

-- At most two distinct, visible hand cards (the v1 allowlist's largest
-- selection is Death's two); the executor re-checks the engine's own
-- `can_use_consumeable` after highlighting them.
local function build_use_on_hand(obs, cert)
	local self = obs.self
	if type(self) ~= "table" or type(self.consumables) ~= "table" or type(self.hand) ~= "table" then
		return nil
	end
	local source = find_entity(self.consumables, cert.source_ref)
	if source == nil or source.redacted == true then
		return nil
	end
	local refs = cert.card_refs
	if type(refs) ~= "table" or #refs == 0 or #refs > 2 then
		return nil
	end
	local seen = {}
	for i = 1, #refs do
		local ref = refs[i]
		local card = is_ref(ref) and zone_of(ref) == "hand" and find_entity(self.hand, ref) or nil
		if card == nil or card.redacted == true or seen[ref] then
			return nil
		end
		seen[ref] = true
	end
	return { type = "USE_CONSUMABLE_ON_HAND", source_ref = cert.source_ref, card_refs = copy_array(refs) }
end

local function build_select_targets(phase, context, obs, cert)
	if phase ~= "CONSUMABLE_SELECTION" or context.target_selection ~= true then
		return nil
	end
	local refs = cert.target_refs
	if type(refs) ~= "table" or #refs == 0 then
		return nil
	end
	local min_value, max_value = target_bounds(obs)
	if min_value == nil then
		return nil
	end
	if #refs < min_value or #refs > max_value then
		return nil
	end
	local target = obs.consumable_target
	if type(target) ~= "table" or type(target.source_ref) ~= "string" then
		return nil
	end
	local allowed = ids_of(target.targets)
	local seen = {}
	for i = 1, #refs do
		local ref = refs[i]
		if not is_ref(ref) or zone_of(ref) ~= "target" or allowed[ref] ~= true then
			return nil
		end
		if seen[ref] then
			return nil
		end
		seen[ref] = true
	end
	return { type = "SELECT_TARGETS", target_refs = copy_array(refs) }
end

local function build_reorder(t, obs, cert)
	local self = obs.self
	if type(self) ~= "table" then
		return nil
	end
	if t == "REORDER_JOKERS" then
		local list = self.jokers
		if type(list) ~= "table" then
			return nil
		end
		if not is_permutation(cert.order, list, "joker") then
			return nil
		end
		return { type = t, order = copy_array(cert.order) }
	end
	local hand = self.hand
	if type(hand) ~= "table" then
		return nil
	end
	if not is_permutation(cert.order, hand, "hand") then
		return nil
	end
	return { type = t, order = copy_array(cert.order) }
end

local function build_action(phase, context, obs, cert)
	local t = cert.type
	local allowed = ACTIONS_PHASES[t]
	if allowed == nil or allowed[phase] ~= true then
		return nil
	end
	if t == "SELECT_BLIND" or t == "SKIP_BLIND" or t == "START_TIMER" then
		return { type = t }
	elseif t == "PLAY_CARDS" or t == "DISCARD_CARDS" then
		return build_cards(t, context, obs, cert)
	elseif t == "BUY_ITEM" then
		return build_buy_item(obs, cert)
	elseif t == "OPEN_BOOSTER" then
		return build_open_booster(obs, cert)
	elseif t == "BUY_VOUCHER" then
		return build_buy_voucher(obs, cert)
	elseif t == "REROLL" then
		return build_reroll(obs)
	elseif t == "LEAVE_SHOP" then
		return { type = t }
	elseif t == "SELL_JOKER" or t == "SELL_CONSUMABLE" then
		return build_sell(t, obs, cert)
	elseif t == "SELECT_BOOSTER_ITEM" then
		return build_select_booster_item(obs, cert)
	elseif t == "SKIP_BOOSTER" then
		if type(obs.booster) ~= "table" then
			return nil
		end
		return { type = t }
	elseif t == "USE_CONSUMABLE" then
		return build_use_consumable(phase, context, obs, cert)
	elseif t == "USE_CONSUMABLE_ON_HAND" then
		return build_use_on_hand(obs, cert)
	elseif t == "SELECT_TARGETS" then
		return build_select_targets(phase, context, obs, cert)
	elseif t == "REORDER_JOKERS" or t == "REORDER_HAND" then
		return build_reorder(t, obs, cert)
	end
	return nil
end

local function generate_from(plain, codec)
	local phase = plain.phase
	local context = plain.context
	if type(phase) ~= "string" or type(context) ~= "table" then
		return {}
	end
	if context.blocked ~= false or context.timer_expired ~= false then
		return {}
	end
	if phase == "MATCH_COMPLETE" then
		return {}
	end
	local certificates = plain.certificates
	if type(certificates) ~= "table" then
		return {}
	end
	local items = certificates.items
	if type(items) ~= "table" then
		return {}
	end
	local out = {}
	local seen = {}
	for i = 1, #items do
		local cert = items[i]
		if type(cert) == "table" and cert.certified == true and type(cert.type) == "string" then
			local action = build_action(phase, context, plain, cert)
			if action ~= nil then
				local id = codec.encode(action)
				if type(id) == "string" and id ~= "" and seen[id] ~= true then
					seen[id] = true
					action.id = id
					out[#out + 1] = action
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return byte_less(a.id, b.id)
	end)
	if #out > MAX_ACTIONS then
		return nil, CODE.TOO_MANY
	end
	return out
end

local function content_ok(t, content)
	local required = REQUIRED_FIELDS[t]
	if required ~= nil then
		for key in next, required do
			if content[key] == nil then
				return false
			end
		end
	end
	local nonempty = ARRAY_NONEMPTY[t]
	for key, value in next, content do
		if key == "type" then
			if type(value) ~= "string" then
				return false
			end
		elseif ARRAY_FIELDS[key] then
			if not is_plain_table(value) then
				return false
			end
			local n = array_len(value)
			if n == nil then
				return false
			end
			if n == 0 and nonempty ~= nil and nonempty[key] == true then
				return false
			end
			local seen = {}
			for i = 1, n do
				local ref = rawget(value, i)
				if not is_ref(ref) then
					return false
				end
				if seen[ref] then
					return false
				end
				seen[ref] = true
			end
		else
			if not is_ref(value) then
				return false
			end
		end
	end
	return true
end

local function deep_copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in next, value do
		out[key] = deep_copy(item)
	end
	return out
end

function Actions.factory(observation, codec)
	if type(observation) ~= "table" or type(observation.export) ~= "function" then
		return nil, CODE.BAD_OBSERVATION
	end
	if type(codec) ~= "table" or type(codec.encode) ~= "function" then
		return nil, CODE.BAD_CODEC
	end

	local instance = {}
	instance.CODE = copy_codes(CODE)

	function instance.generate(handle)
		local plain = observation.export(handle)
		if plain == nil then
			return nil, CODE.UNKNOWN_HANDLE
		end
		if not is_plain_table(plain) then
			return nil, CODE.BAD_OBSERVATION
		end
		return generate_from(plain, codec)
	end

	function instance.validate(handle, action)
		local plain = observation.export(handle)
		if plain == nil then
			return nil, CODE.UNKNOWN_HANDLE
		end
		if not is_plain_table(plain) then
			return nil, CODE.BAD_OBSERVATION
		end
		if not is_plain_table(action) then
			return nil, CODE.BAD_ACTION
		end
		local t = action.type
		if type(t) ~= "string" or ACTION_KEYS[t] == nil then
			return nil, CODE.UNKNOWN_TYPE
		end
		local allowed = ACTION_KEYS[t]
		for key in next, action do
			if key ~= "id" and allowed[key] ~= true then
				return nil, CODE.BAD_ACTION
			end
		end
		local id = action.id
		if type(id) ~= "string" or #id == 0 then
			return nil, CODE.BAD_ID
		end
		local content = { type = t }
		for key, value in next, action do
			if key ~= "id" and key ~= "type" then
				content[key] = value
			end
		end
		if not content_ok(t, content) then
			return nil, CODE.BAD_ACTION
		end
		local canonical = codec.encode(content)
		if canonical == nil then
			return nil, CODE.BAD_ACTION
		end
		if canonical ~= id then
			return nil, CODE.ID_MISMATCH
		end
		local candidates, candidates_code = generate_from(plain, codec)
		if candidates == nil then
			return nil, candidates_code
		end
		for i = 1, #candidates do
			if candidates[i].id == id then
				return deep_copy(candidates[i])
			end
		end
		return nil, CODE.NOT_CERTIFIED
	end

	return instance
end

Actions.CODE = copy_codes(CODE)

return Actions
