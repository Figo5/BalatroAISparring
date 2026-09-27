local Observation = {}

local SCHEMA_VERSION = 1
local INT_MAX = 2147483647
local INT_SIGNED_MIN = -2147483648

local LIMIT = {
	hand = 64,
	jokers = 64,
	consumables = 64,
	vouchers = 16,
	tags = 16,
	shop = 16,
	booster = 16,
	targets = 16,
	shop_booster = 16,
	token = 64,
	display = 32,
	text = 128,
	ref = 64,
	refs = 64,
	certificates = 128,
}

local PHASES = {
	BLIND_SELECTION = true,
	PLAY_HAND = true,
	DISCARD = true,
	SHOP = true,
	BOOSTER_SELECTION = true,
	CONSUMABLE_SELECTION = true,
	MULTIPLAYER_PVP = true,
	MATCH_COMPLETE = true,
}

local CODE = {
	OK = "ok",
	BAD_CODEC = "observation_bad_codec",
	BAD_FRAME = "observation_bad_frame",
	UNKNOWN_PHASE = "observation_unknown_phase",
	BAD_VERSION = "observation_bad_version",
	MISSING_MATCH = "observation_missing_match",
	MISSING_SELF = "observation_missing_self",
	BAD_FIELD = "observation_invalid_field",
	BAD_ENTITY = "observation_invalid_entity",
	SPARSE_ARRAY = "observation_sparse_array",
	TOO_LARGE = "observation_too_large",
	DUPLICATE_REF = "observation_duplicate_ref",
	BAD_TARGET_REF = "observation_invalid_target_ref",
	BAD_CERTIFICATE = "observation_invalid_certificate",
	BAD_CONTEXT = "observation_invalid_context",
	ENCODE_FAILED = "observation_encode_failed",
	UNKNOWN_HANDLE = "observation_unknown_handle",
}

local PAT = {
	token = "^[0-9A-Za-z_%.-]+$",
	display = "^[0-9A-Za-z_%.,%%+%-/:<> ]+$",
	ref = "^[0-9A-Za-z_%-]+:[0-9]+$",
}

local PHASE_RULES = {
	BLIND_SELECTION = { self = true, opponent = true, shop = false, booster = false, consumable = false, hand = false, context = true, certificates = true },
	PLAY_HAND = { self = true, opponent = true, shop = false, booster = false, consumable = false, hand = true, context = true, certificates = true },
	DISCARD = { self = true, opponent = true, shop = false, booster = false, consumable = false, hand = true, context = true, certificates = true },
	SHOP = { self = true, opponent = true, shop = true, booster = false, consumable = false, hand = false, context = true, certificates = true },
	BOOSTER_SELECTION = { self = true, opponent = true, shop = false, booster = true, consumable = false, hand = true, context = true, certificates = true },
	CONSUMABLE_SELECTION = { self = true, opponent = true, shop = false, booster = false, consumable = true, hand = true, context = true, certificates = true },
	MULTIPLAYER_PVP = { self = true, opponent = true, shop = false, booster = false, consumable = false, hand = true, context = true, certificates = true },
	MATCH_COMPLETE = { self = false, opponent = false, shop = false, booster = false, consumable = false, hand = false, context = false, certificates = false },
}

local ENTITY_FIELDS = {
	card = { "kind", "rank", "suit", "center", "edition", "seal", "debuff" },
	joker = { "center", "edition", "seal", "debuff", "visible_text" },
	consumable = { "center", "edition", "debuff", "visible_text" },
	shop_item = { "kind", "rank", "suit", "center", "edition", "seal", "debuff", "cost", "sell_cost" },
	voucher = { "center", "cost" },
	tag = { "center" },
}

local TOKEN_LIMIT = {
	rank = 8,
	suit = 8,
	center = 64,
	edition = 32,
	seal = 32,
	kind = 32,
}

local ARRAY_REF_FIELDS = {
	card_refs = true,
	target_refs = true,
	order = true,
}

local NONEMPTY_REF_FIELDS = {
	card_refs = true,
	order = true,
}

local CERT_TYPES = {
	SELECT_BLIND = {},
	SKIP_BLIND = {},
	PLAY_CARDS = { card_refs = "hand" },
	DISCARD_CARDS = { card_refs = "hand" },
	BUY_ITEM = { item_ref = "shop", capacity_ok = true },
	SELL_JOKER = { joker_ref = "joker" },
	SELL_CONSUMABLE = { consumable_ref = "consumable" },
	REROLL = {},
	BUY_VOUCHER = { voucher_ref = "shop_voucher" },
	OPEN_BOOSTER = { item_ref = "shop_booster", capacity_ok = true },
	LEAVE_SHOP = {},
	SELECT_BOOSTER_ITEM = { card_refs = "booster", capacity_ok = true },
	SKIP_BOOSTER = {},
	USE_CONSUMABLE = { source_ref = "consumable", target_refs = "target" },
	SELECT_TARGETS = { target_refs = "target" },
	REORDER_JOKERS = { order = "joker" },
	REORDER_HAND = { order = "hand" },
}

local DIGIT = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local function dec(n)
	if n < 10 then
		return DIGIT[n + 1]
	end
	local out = {}
	while n > 0 do
		local q = math.floor(n / 10)
		local r = n - q * 10
		out[#out + 1] = DIGIT[r + 1]
		n = q
	end
	local s = {}
	for i = #out, 1, -1 do
		s[#s + 1] = out[i]
	end
	return table.concat(s)
end

local function is_plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_int(n)
	if type(n) ~= "number" then
		return false
	end
	if n ~= n then
		return false
	end
	if n == math.huge or n == -math.huge then
		return false
	end
	if n % 1 ~= 0 then
		return false
	end
	return n >= INT_SIGNED_MIN and n <= INT_MAX
end

local function read_int(t, key, min_value, max_value)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if not is_int(value) then
		return CODE.BAD_FIELD
	end
	if value < min_value or value > max_value then
		return CODE.BAD_FIELD
	end
	return nil, value
end

local function read_bool(t, key)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if type(value) ~= "boolean" then
		return CODE.BAD_FIELD
	end
	return nil, value
end

local function read_string(t, key, max_len, pattern)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if type(value) ~= "string" then
		return CODE.BAD_FIELD
	end
	if #value == 0 or #value > max_len then
		return CODE.BAD_FIELD
	end
	if string.match(value, pattern) == nil then
		return CODE.BAD_FIELD
	end
	return nil, value
end

local function read_text(t, key, max_len)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if type(value) ~= "string" then
		return CODE.BAD_FIELD
	end
	if #value == 0 or #value > max_len then
		return CODE.BAD_FIELD
	end
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte < 32 or byte > 126 then
			return CODE.BAD_FIELD
		end
	end
	return nil, value
end

local MAX_ARRAY_SCAN = 256

local function array_count(t)
	local count = 0
	local maxn = 0
	for key in next, t do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, CODE.SPARSE_ARRAY
		end
		count = count + 1
		if count > MAX_ARRAY_SCAN then
			return nil, CODE.TOO_LARGE
		end
		if key > maxn then
			maxn = key
		end
	end
	if count ~= maxn then
		return nil, CODE.SPARSE_ARRAY
	end
	return maxn
end

local function read_array(t, key, max_items, convert)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if not is_plain_table(value) then
		return CODE.BAD_FIELD
	end
	local n, reason = array_count(value)
	if n == nil then
		return reason
	end
	if n > max_items then
		return CODE.TOO_LARGE
	end
	local out = {}
	for i = 1, n do
		local code, item = convert(rawget(value, i), i)
		if code ~= nil then
			return code
		end
		out[i] = item
	end
	return nil, out
end

local function read_fields(t, spec)
	local out = {}
	for i = 1, #spec do
		local name = spec[i][1]
		local kind = spec[i][2]
		local arg = spec[i][3]
		local code
		local value
		if kind == "int" then
			code, value = read_int(t, name, 0, INT_MAX)
		elseif kind == "sint" then
			code, value = read_int(t, name, INT_SIGNED_MIN, INT_MAX)
		elseif kind == "bool" then
			code, value = read_bool(t, name)
		elseif kind == "token" then
			code, value = read_string(t, name, arg, PAT.token)
		elseif kind == "display" then
			code, value = read_string(t, name, arg, PAT.display)
		elseif kind == "ref" then
			code, value = read_string(t, name, arg, PAT.ref)
		else
			return CODE.BAD_FIELD
		end
		if code ~= nil then
			return code
		end
		if value ~= nil then
			out[name] = value
		end
	end
	return nil, out
end

local function convert_entity(kind, zone, add_ref)
	return function(item, ordinal)
		if not is_plain_table(item) then
			return CODE.BAD_ENTITY
		end
		local code, face_down = read_bool(item, "face_down")
		if code ~= nil then
			return CODE.BAD_ENTITY
		end
		local id = zone .. ":" .. dec(ordinal)
		if add_ref(id) then
			return CODE.DUPLICATE_REF
		end
		if face_down ~= false then
			return nil, { id = id, redacted = true }
		end
		local out = { id = id, face_down = false }
		local fields = ENTITY_FIELDS[kind]
		for i = 1, #fields do
			local name = fields[i]
			local field_code
			local value
			if name == "debuff" then
				field_code, value = read_bool(item, name)
			elseif name == "cost" or name == "sell_cost" then
				field_code, value = read_int(item, name, 0, INT_MAX)
			elseif name == "visible_text" then
				field_code, value = read_text(item, name, LIMIT.text)
			else
				field_code, value = read_string(item, name, TOKEN_LIMIT[name], PAT.token)
			end
			if field_code ~= nil then
				return CODE.BAD_ENTITY
			end
			if value ~= nil then
				out[name] = value
			end
		end
		return nil, out
	end
end

local function read_deck(t)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_FIELD
	end
	local out = {}
	local code, total = read_int(t, "total", 0, INT_MAX)
	if code ~= nil then
		return CODE.BAD_FIELD
	end
	if total ~= nil then
		out.total = total
	end
	return nil, out
end

local function read_match(t)
	if t == nil then
		return CODE.MISSING_MATCH
	end
	if not is_plain_table(t) then
		return CODE.MISSING_MATCH
	end
	local spec = {
		{ "ruleset", "token", 64 },
		{ "blind", "display", 32 },
		{ "timer", "display", 16 },
		{ "ante", "int" },
		{ "round", "int" },
		{ "lives", "int" },
		{ "hands_per_round", "int" },
		{ "discards_per_round", "int" },
		{ "hand_size", "int" },
		{ "joker_slots", "int" },
		{ "consumable_slots", "int" },
	}
	local code, out = read_fields(t, spec)
	if code ~= nil then
		return code
	end
	if out.ruleset == nil then
		return CODE.BAD_FIELD
	end
	return nil, out
end

local function read_self(t, state, rules)
	if t == nil then
		return CODE.MISSING_SELF
	end
	if not is_plain_table(t) then
		return CODE.MISSING_SELF
	end
	local spec = {
		{ "money", "sint" },
		{ "credit_limit", "int" },
		{ "hands", "int" },
		{ "discards", "int" },
		{ "current_score", "display", 32 },
		{ "blind_requirement", "display", 32 },
		{ "hand_visible", "bool" },
	}
	local code, out = read_fields(t, spec)
	if code ~= nil then
		return code
	end
	local sections = {
		{ "jokers", LIMIT.jokers, "joker", "joker" },
		{ "consumables", LIMIT.consumables, "consumable", "consumable" },
		{ "vouchers", LIMIT.vouchers, "voucher", "voucher" },
		{ "tags", LIMIT.tags, "tag", "tag" },
	}
	if rules.hand and out.hand_visible == true then
		sections[#sections + 1] = { "hand", LIMIT.hand, "card", "hand" }
	end
	for i = 1, #sections do
		local entry = sections[i]
		local section_code, list = read_array(t, entry[1], entry[2], convert_entity(entry[3], entry[4], state.add_ref))
		if section_code ~= nil then
			return section_code
		end
		if list ~= nil then
			out[entry[1]] = list
		end
	end
	local deck_code, deck = read_deck(rawget(t, "deck"))
	if deck_code ~= nil then
		return deck_code
	end
	if deck ~= nil then
		out.deck = deck
	end
	return nil, out
end

local function read_opponent(t)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_FIELD
	end
	local code, certified = read_bool(t, "certified")
	if code ~= nil then
		return CODE.BAD_FIELD
	end
	if certified ~= true then
		return nil
	end
	local spec = {
		{ "displayed_score", "display", 32 },
		{ "hands", "int" },
		{ "lives", "int" },
		{ "location", "display", 32 },
		{ "timer", "display", 16 },
	}
	local field_code, out = read_fields(t, spec)
	if field_code ~= nil then
		return field_code
	end
	if next(out) == nil then
		return nil
	end
	return nil, out
end

local function read_shop(t, state)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_FIELD
	end
	local code, out = read_fields(t, { { "reroll_cost", "int" } })
	if code ~= nil then
		return code
	end
	local item_code, items = read_array(t, "items", LIMIT.shop, convert_entity("shop_item", "shop", state.add_ref))
	if item_code ~= nil then
		return item_code
	end
	if items ~= nil then
		for i = 1, #items do
			if items[i].kind == "booster" then
				return CODE.BAD_ENTITY
			end
		end
		out.items = items
	end
	local voucher_code, vouchers = read_array(t, "vouchers", LIMIT.vouchers, convert_entity("voucher", "shop_voucher", state.add_ref))
	if voucher_code ~= nil then
		return voucher_code
	end
	if vouchers ~= nil then
		out.vouchers = vouchers
	end
	local booster_code, boosters = read_array(t, "boosters", LIMIT.shop_booster, convert_entity("shop_item", "shop_booster", state.add_ref))
	if booster_code ~= nil then
		return booster_code
	end
	if boosters ~= nil then
		out.boosters = boosters
	end
	return nil, out
end

local function read_booster(t, state)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_FIELD
	end
	local code, out = read_fields(t, {
		{ "kind", "token", 32 },
		{ "choices", "int" },
		{ "skips", "int" },
	})
	if code ~= nil then
		return code
	end
	local card_code, cards = read_array(t, "cards", LIMIT.booster, convert_entity("card", "booster", state.add_ref))
	if card_code ~= nil then
		return card_code
	end
	if cards ~= nil then
		out.cards = cards
	end
	return nil, out
end

local function read_consumable_target(t, state)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_FIELD
	end
	local source = rawget(t, "source")
	if not is_plain_table(source) then
		return CODE.BAD_FIELD
	end
	local code, source_out = convert_entity("consumable", "source", state.add_ref)(source, 1)
	if code ~= nil then
		return code
	end
	local out = { source = source_out }
	local ref_code, source_ref = read_string(t, "source_ref", LIMIT.ref, PAT.ref)
	if ref_code ~= nil then
		return ref_code
	end
	if source_ref ~= nil then
		out.source_ref = source_ref
	end
	local fields_code, fields = read_fields(t, {
		{ "min_targets", "int" },
		{ "max_targets", "int" },
	})
	if fields_code ~= nil then
		return fields_code
	end
	for field_name, field_value in next, fields do
		out[field_name] = field_value
	end
	local target_code, targets = read_array(t, "targets", LIMIT.targets, convert_entity("card", "target", state.add_ref))
	if target_code ~= nil then
		return target_code
	end
	if targets ~= nil then
		out.targets = targets
	end
	if out.min_targets ~= nil and out.max_targets ~= nil and out.min_targets > out.max_targets then
		return CODE.BAD_FIELD
	end
	return nil, out
end

local function read_context(t)
	if t == nil then
		return nil, { blocked = true, timer_expired = true, target_selection = false }
	end
	if not is_plain_table(t) then
		return CODE.BAD_CONTEXT
	end
	local out = {}
	local c1, blocked = read_bool(t, "blocked")
	if c1 ~= nil then
		return CODE.BAD_CONTEXT
	end
	out.blocked = (blocked ~= false)
	local c2, timer_expired = read_bool(t, "timer_expired")
	if c2 ~= nil then
		return CODE.BAD_CONTEXT
	end
	out.timer_expired = (timer_expired ~= false)
	local c3, target_selection = read_bool(t, "target_selection")
	if c3 ~= nil then
		return CODE.BAD_CONTEXT
	end
	out.target_selection = (target_selection == true)
	local spec = {
		{ "max_play", "int" },
		{ "max_discard", "int" },
		{ "min_targets", "int" },
		{ "max_targets", "int" },
	}
	local code, fields = read_fields(t, spec)
	if code ~= nil then
		return code
	end
	for field_name, field_value in next, fields do
		out[field_name] = field_value
	end
	if out.min_targets ~= nil and out.max_targets ~= nil and out.min_targets > out.max_targets then
		return CODE.BAD_CONTEXT
	end
	return nil, out
end

local function ref_zone(ref)
	return string.match(ref, "^([0-9A-Za-z_%-]+):[0-9]+$")
end

local function check_ref(ref, expected_zone, state)
	if ref_zone(ref) ~= expected_zone then
		return CODE.BAD_TARGET_REF
	end
	if state.refs[ref] ~= true then
		return CODE.BAD_TARGET_REF
	end
	return nil
end

local function read_ref_array(t, key, expected_zone, state)
	local value = rawget(t, key)
	if value == nil then
		return nil
	end
	if not is_plain_table(value) then
		return CODE.BAD_CERTIFICATE
	end
	local n, reason = array_count(value)
	if n == nil then
		return reason
	end
	if n > LIMIT.refs then
		return CODE.TOO_LARGE
	end
	local out = {}
	local seen = {}
	for i = 1, n do
		local ref = rawget(value, i)
		if type(ref) ~= "string" or #ref == 0 or #ref > LIMIT.ref or string.match(ref, PAT.ref) == nil then
			return CODE.BAD_CERTIFICATE
		end
		if seen[ref] then
			return CODE.DUPLICATE_REF
		end
		seen[ref] = true
		local code = check_ref(ref, expected_zone, state)
		if code ~= nil then
			return code
		end
		out[i] = ref
	end
	return nil, out
end

local function read_certificate(t, state)
	if not is_plain_table(t) then
		return CODE.BAD_CERTIFICATE
	end
	local type_code, ctype = read_string(t, "type", 32, PAT.token)
	if type_code ~= nil then
		return CODE.BAD_CERTIFICATE
	end
	if ctype == nil or CERT_TYPES[ctype] == nil then
		return CODE.BAD_CERTIFICATE
	end
	local cert_code, certified = read_bool(t, "certified")
	if cert_code ~= nil then
		return CODE.BAD_CERTIFICATE
	end
	if certified ~= true then
		return nil
	end
	local spec = CERT_TYPES[ctype]
	local out = { type = ctype, certified = true }
	for field, zone in next, spec do
		if field == "capacity_ok" then
			local cap_code, capacity_ok = read_bool(t, field)
			if cap_code ~= nil then
				return CODE.BAD_CERTIFICATE
			end
			if capacity_ok ~= nil then
				out[field] = capacity_ok
			end
		elseif ARRAY_REF_FIELDS[field] then
			local ref_code, refs = read_ref_array(t, field, zone, state)
			if ref_code ~= nil then
				return ref_code
			end
			if refs == nil then
				return CODE.BAD_CERTIFICATE
			end
			if NONEMPTY_REF_FIELDS[field] and #refs == 0 then
				return CODE.BAD_CERTIFICATE
			end
			out[field] = refs
		else
			local ref_code, ref = read_string(t, field, LIMIT.ref, PAT.ref)
			if ref_code ~= nil then
				return CODE.BAD_CERTIFICATE
			end
			if ref == nil then
				return CODE.BAD_CERTIFICATE
			end
			local zone_code = check_ref(ref, zone, state)
			if zone_code ~= nil then
				return zone_code
			end
			out[field] = ref
		end
	end
	return nil, out
end

local function read_certificates(t, state)
	if t == nil then
		return nil
	end
	if not is_plain_table(t) then
		return CODE.BAD_CERTIFICATE
	end
	local version_code, version = read_int(t, "version", SCHEMA_VERSION, SCHEMA_VERSION)
	if version_code ~= nil or version == nil then
		return CODE.BAD_CERTIFICATE
	end
	local value = rawget(t, "items")
	if not is_plain_table(value) then
		return CODE.BAD_CERTIFICATE
	end
	local n, reason = array_count(value)
	if n == nil then
		return reason
	end
	if n > LIMIT.certificates then
		return CODE.TOO_LARGE
	end
	local items = {}
	for i = 1, n do
		local cert_code, cert = read_certificate(rawget(value, i), state)
		if cert_code ~= nil then
			return cert_code
		end
		if cert ~= nil then
			items[#items + 1] = cert
		end
	end
	return nil, { version = version, items = items }
end

local function make_state()
	local refs = {}
	local function add_ref(id)
		if refs[id] then
			return true
		end
		refs[id] = true
		return false
	end
	return { refs = refs, add_ref = add_ref }
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

local HANDLE_META = { __metatable = "AISparring.AIObservation.handle" }

function Observation.factory(codec)
	if type(codec) ~= "table" or type(codec.encode) ~= "function" or type(codec.hash_string) ~= "function" then
		return nil, CODE.BAD_CODEC
	end

	local registry = setmetatable({}, { __mode = "k" })
	local instance = {}

	instance.SCHEMA_VERSION = SCHEMA_VERSION
	instance.PHASES = deep_copy(PHASES)
	instance.CODE = deep_copy(CODE)

	function instance.observe(frame)
		if not is_plain_table(frame) then
			return nil, CODE.BAD_FRAME
		end
		local version_code, version = read_int(frame, "schema_version", SCHEMA_VERSION, SCHEMA_VERSION)
		if version_code ~= nil or version == nil then
			return nil, CODE.BAD_VERSION
		end
		local phase_code, phase = read_string(frame, "phase", 32, PAT.token)
		if phase_code ~= nil or phase == nil or PHASES[phase] ~= true then
			return nil, CODE.UNKNOWN_PHASE
		end
		local rules = PHASE_RULES[phase]

		local match_code, match = read_match(rawget(frame, "match"))
		if match_code ~= nil then
			return nil, match_code
		end

		local state = make_state()
		local content = { schema_version = version, phase = phase, match = match }

		if rules.self then
			local self_code, self_out = read_self(rawget(frame, "self"), state, rules)
			if self_code ~= nil then
				return nil, self_code
			end
			content.self = self_out
		end
		if rules.opponent then
			local opponent_code, opponent = read_opponent(rawget(frame, "opponent"))
			if opponent_code ~= nil then
				return nil, opponent_code
			end
			if opponent ~= nil then
				content.opponent = opponent
			end
		end
		if rules.shop then
			local shop_code, shop = read_shop(rawget(frame, "shop"), state)
			if shop_code ~= nil then
				return nil, shop_code
			end
			if shop ~= nil then
				content.shop = shop
			end
		end
		if rules.booster then
			local booster_code, booster = read_booster(rawget(frame, "booster"), state)
			if booster_code ~= nil then
				return nil, booster_code
			end
			if booster ~= nil then
				content.booster = booster
			end
		end
		if rules.consumable then
			local target_code, consumable_target = read_consumable_target(rawget(frame, "consumable_target"), state)
			if target_code ~= nil then
				return nil, target_code
			end
			if consumable_target ~= nil then
				if consumable_target.source_ref ~= nil then
					local ref_code = check_ref(consumable_target.source_ref, "consumable", state)
					if ref_code ~= nil then
						return nil, ref_code
					end
				end
				content.consumable_target = consumable_target
			end
		end
		if rules.context then
			local context_code, context = read_context(rawget(frame, "context"))
			if context_code ~= nil then
				return nil, context_code
			end
			content.context = context
		end
		if rules.certificates then
			local certificate_code, certificates = read_certificates(rawget(frame, "certificates"), state)
			if certificate_code ~= nil then
				return nil, certificate_code
			end
			if certificates ~= nil then
				content.certificates = certificates
			end
		end

		local canonical, encode_code = codec.encode(content)
		if canonical == nil then
			return nil, encode_code or CODE.ENCODE_FAILED
		end
		local hash = codec.hash_string(canonical)
		if hash == nil then
			return nil, CODE.ENCODE_FAILED
		end

		local handle = setmetatable({}, HANDLE_META)
		registry[handle] = { content = content, canonical = canonical, hash = hash }
		return handle
	end

	function instance.export(handle)
		if type(handle) ~= "table" then
			return nil, CODE.UNKNOWN_HANDLE
		end
		local entry = registry[handle]
		if entry == nil then
			return nil, CODE.UNKNOWN_HANDLE
		end
		return deep_copy(entry.content)
	end

	function instance.canonical(handle)
		if type(handle) ~= "table" then
			return nil, CODE.UNKNOWN_HANDLE
		end
		local entry = registry[handle]
		if entry == nil then
			return nil, CODE.UNKNOWN_HANDLE
		end
		return entry.canonical
	end

	function instance.hash(handle)
		if type(handle) ~= "table" then
			return nil, CODE.UNKNOWN_HANDLE
		end
		local entry = registry[handle]
		if entry == nil then
			return nil, CODE.UNKNOWN_HANDLE
		end
		return entry.hash
	end

	function instance.equal(left, right)
		local left_canonical = instance.canonical(left)
		if left_canonical == nil then
			return false
		end
		local right_canonical = instance.canonical(right)
		if right_canonical == nil then
			return false
		end
		return left_canonical == right_canonical
	end

	function instance.is_handle(value)
		if type(value) ~= "table" then
			return false
		end
		return registry[value] ~= nil
	end

	function instance.describe()
		return deep_copy({
			schema_version = SCHEMA_VERSION,
			phases = PHASES,
			phase_rules = PHASE_RULES,
			entity_fields = ENTITY_FIELDS,
			certificate_types = CERT_TYPES,
			limits = LIMIT,
			codes = CODE,
		})
	end

	return instance
end

Observation.SCHEMA_VERSION = SCHEMA_VERSION
Observation.PHASES = deep_copy(PHASES)
Observation.CODE = deep_copy(CODE)

return Observation
