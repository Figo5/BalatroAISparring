local StateReader = {}

StateReader.SCHEMA_VERSION = 1

StateReader.CODE = {
	OK = "ok",
	BAD_OBSERVATION = "reader_bad_observation",
	BAD_RUNTIME = "reader_bad_runtime",
	BAD_ROLE = "reader_bad_role",
	BAD_EPOCH = "reader_bad_epoch",
	EPOCH_MISMATCH = "reader_epoch_mismatch",
	BAD_VIEW = "reader_bad_view",
	UNSUPPORTED_STATE = "reader_unsupported_state",
	PHASE_MISMATCH = "reader_phase_mismatch",
	ENTITY_MISMATCH = "reader_entity_mismatch",
	OBSERVE_FAILED = "reader_observe_failed",
}

local CODE = StateReader.CODE

local SCHEMA_VERSION = StateReader.SCHEMA_VERSION
local INT_MIN = -2147483648
local INT_MAX = 2147483647

local LIMITS = {
	hand = 64,
	jokers = 64,
	consumables = 64,
	shop = 16,
	shop_booster = 16,
	vouchers = 16,
	owned_vouchers = 32,
	booster = 16,
	targets = 16,
	token = 64,
	display = 64,
	text = 128,
	ref = 64,
}

StateReader.LIMITS = LIMITS

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

local PHASE_ALLOWS_HAND = {
	BLIND_SELECTION = false,
	PLAY_HAND = true,
	DISCARD = true,
	SHOP = false,
	BOOSTER_SELECTION = true,
	CONSUMABLE_SELECTION = true,
	MULTIPLAYER_PVP = true,
	MATCH_COMPLETE = false,
}

local ENGINE_SYMBOLS = {
	{ symbol = "BLIND_SELECT", phase = "BLIND_SELECTION" },
	{ symbol = "SELECTING_HAND", phase = "HAND_SELECT" },
	{ symbol = "SHOP", phase = "SHOP" },
	{ symbol = "TAROT_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "SPECTRAL_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "PLANET_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "STANDARD_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "BUFFOON_PACK", phase = "BOOSTER_SELECTION" },
	{ symbol = "SMODS_BOOSTER_OPENED", phase = "BOOSTER_SELECTION" },
	{ symbol = "GAME_OVER", phase = "MATCH_COMPLETE" },
}

local COMPATIBLE = {
	BLIND_SELECTION = { BLIND_SELECTION = true },
	HAND_SELECT = {
		PLAY_HAND = true,
		DISCARD = true,
		CONSUMABLE_SELECTION = true,
		MULTIPLAYER_PVP = true,
	},
	SHOP = { SHOP = true },
	BOOSTER_SELECTION = { BOOSTER_SELECTION = true },
	MATCH_COMPLETE = { MATCH_COMPLETE = true },
}

local AREAS = {
	hand = { "hand", "cards" },
	jokers = { "jokers", "cards" },
	consumeables = { "consumeables", "cards" },
	pack = { "pack_cards", "cards" },
	shop = { "shop_jokers", "cards" },
	shop_boosters = { "shop_booster", "cards" },
	shop_vouchers = { "shop_vouchers", "cards" },
}

local ZONES = {
	hand = { kind = "card", area = "hand", whole = true, area_limit = LIMITS.hand, array_limit = LIMITS.hand },
	joker = { kind = "joker", area = "jokers", whole = true, area_limit = LIMITS.jokers, array_limit = LIMITS.jokers },
	consumable = { kind = "consumable", area = "consumeables", whole = true, area_limit = LIMITS.consumables, array_limit = LIMITS.consumables },
	shop = { kind = "shop_item", area = "shop", whole = true, area_limit = LIMITS.shop, array_limit = LIMITS.shop },
	shop_booster = { kind = "shop_item", area = "shop_boosters", whole = true, area_limit = LIMITS.shop_booster, array_limit = LIMITS.shop_booster },
	shop_voucher = { kind = "voucher", area = "shop_vouchers", whole = true, area_limit = LIMITS.vouchers, array_limit = LIMITS.vouchers },
	booster = { kind = "card", area = "pack", whole = true, area_limit = LIMITS.booster, array_limit = LIMITS.booster },
	target = { kind = "card", area = "hand", whole = false, area_limit = LIMITS.hand, array_limit = LIMITS.targets },
	source = { kind = "consumable", area = "consumeables", whole = false, area_limit = LIMITS.consumables, array_limit = 1 },
}

local ENTITY_FIELDS = {
	card = { "kind", "rank", "suit", "center", "edition", "seal", "debuff" },
	joker = { "center", "edition", "seal", "debuff", "visible_text" },
	consumable = { "center", "edition", "debuff", "visible_text" },
	shop_item = { "kind", "rank", "suit", "center", "edition", "seal", "debuff", "cost", "sell_cost" },
	voucher = { "center", "cost" },
}

local FIELD_SPEC = {
	kind = { kind = "token", limit = 32 },
	rank = { kind = "token", limit = 8 },
	suit = { kind = "token", limit = 8 },
	center = { kind = "token", limit = LIMITS.token },
	edition = { kind = "token", limit = 32 },
	seal = { kind = "token", limit = 32 },
	debuff = { kind = "bool" },
	cost = { kind = "int" },
	sell_cost = { kind = "int" },
	visible_text = { kind = "text", limit = LIMITS.text },
}

local SELF_ENTITY_ZONES = {
	{ view = "joker", field = "jokers", zone = "joker" },
	{ view = "consumable", field = "consumables", zone = "consumable" },
}

local TOKEN_PATTERN = "^[0-9A-Za-z_%.-]+$"
local DISPLAY_PATTERN = "^[0-9A-Za-z_%.,%%+%-/:<> ]+$"
local DIGIT = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value then
		return false
	end
	if value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= INT_MIN and value <= INT_MAX
end

local function rget(obj, key)
	if type(obj) ~= "table" then
		return nil
	end
	return rawget(obj, key)
end

local function dec_string(n)
	if n <= 0 then
		return "0"
	end
	local reversed = {}
	while n > 0 do
		local q = math.floor(n / 10)
		local r = n - q * 10
		reversed[#reversed + 1] = DIGIT[r + 1]
		n = q
	end
	local out = {}
	for i = #reversed, 1, -1 do
		out[#out + 1] = reversed[i]
	end
	return table.concat(out)
end

local function copy_codes(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

local function raw_array_count(value, limit)
	if type(value) ~= "table" then
		return nil
	end
	local count = 0
	local maxn = 0
	for key in next, value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		count = count + 1
		if count > limit then
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

local function engine_cards(G, area_key, limit)
	local path = AREAS[area_key]
	local area = rget(G, path[1])
	local cards = rget(area, path[2])
	local count = raw_array_count(cards, limit)
	if count == nil then
		return nil
	end
	return cards, count
end

local function project_token(value, limit)
	if type(value) ~= "string" then
		return nil
	end
	if #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, TOKEN_PATTERN) == nil then
		return nil
	end
	return value
end

local function project_bool(value)
	if type(value) ~= "boolean" then
		return nil
	end
	return value
end

local function project_int(value)
	if not is_int(value) or value < 0 then
		return nil
	end
	return value
end

local function project_text(value, limit)
	if type(value) ~= "string" then
		return nil
	end
	if #value == 0 or #value > limit then
		return nil
	end
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte < 32 or byte > 126 then
			return nil
		end
	end
	return value
end

local function project_field(name, value)
	local spec = FIELD_SPEC[name]
	if spec == nil then
		return nil
	end
	if spec.kind == "token" then
		return project_token(value, spec.limit)
	end
	if spec.kind == "bool" then
		return project_bool(value)
	end
	if spec.kind == "int" then
		return project_int(value)
	end
	if spec.kind == "text" then
		return project_text(value, spec.limit)
	end
	return nil
end

local function as_display(value, limit)
	if type(value) ~= "string" then
		return nil
	end
	if #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, DISPLAY_PATTERN) == nil then
		return nil
	end
	return value
end

local function parse_count_text(value)
	if type(value) ~= "string" then
		return nil
	end
	if #value == 0 or #value > 3 then
		return nil
	end
	local total = 0
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte < 48 or byte > 57 then
			return nil
		end
		total = total * 10 + (byte - 48)
	end
	if total > 99 then
		return nil
	end
	return total
end

local function center_masks(card)
	local ability = rget(card, "ability")
	local effect = rget(ability, "effect")
	local stone = (effect == "Stone Card")
	local config = rget(card, "config")
	local center = rget(config, "center")
	if type(center) ~= "table" then
		return true, true
	end
	local function flag(name)
		local value = rawget(center, name)
		return value ~= nil and value ~= false
	end
	local replace = flag("replace_base_card")
	local no_rank = flag("no_rank")
	local no_suit = flag("no_suit")
	return stone or replace or no_rank, stone or replace or no_suit
end

-- Owned scaling Jokers (docs/SCALING_VALUES_DESIGN.md): identical to the
-- adapter's table. The row comes from the engine card's own center, and the
-- value and step are recomputed from its fields; the view must match exactly.
local SCALING_CURRENT = {
	j_swashbuckler = { "mult", { "mult" } },
	j_green_joker = { "mult", { "mult" }, { "extra", "hand_add" } },
	j_ride_the_bus = { "mult", { "mult" }, { "extra" } },
	j_trousers = { "mult", { "mult" }, { "extra" } },
	j_flash = { "mult", { "mult" } },
	j_red_card = { "mult", { "mult" } },
	j_ceremonial = { "mult", { "mult" } },
	j_runner = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_square = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_wee = { "chips", { "extra", "chips" }, { "extra", "chip_mod" } },
	j_castle = { "chips", { "extra", "chips" } },
	j_hologram = { "xmult", { "x_mult" } },
	j_constellation = { "xmult", { "x_mult" } },
	j_campfire = { "xmult", { "x_mult" } },
	j_glass = { "xmult", { "x_mult" } },
	j_madness = { "xmult", { "x_mult" } },
	j_lucky_cat = { "xmult", { "x_mult" } },
}

local function scaling_number(value, kind)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if kind == "xmult" then
		value = math.floor(value * 100 + 0.5)
		if value < 100 or value > 1000000 then
			return nil
		end
		return value
	end
	if value % 1 ~= 0 or value < 0 or value > 100000 then
		return nil
	end
	return value
end

local function engine_path(obj, path)
	local value = rget(obj, path[1])
	if path[2] ~= nil then
		value = rget(value, path[2])
	end
	return value
end

-- Returns the verified copy, or nil, false when the view disagrees.
local function copy_current(view, card, view_record)
	if not is_plain(view) then
		return nil, false
	end
	for key in next, view do
		if key ~= "kind" and key ~= "value" and key ~= "step" then
			return nil, false
		end
	end
	-- Only a non-debuffed card shows its value, and the view's center must be
	-- the engine card's (the policy picks the growth rule from it).
	local key = rget(rget(rget(card, "config"), "center"), "key")
	local spec = SCALING_CURRENT[key]
	if spec == nil or rget(card, "debuff") ~= false or rawget(view_record, "center") ~= key then
		return nil, false
	end
	local ability = rget(card, "ability")
	local value = scaling_number(engine_path(ability, spec[2]), spec[1])
	local step = nil
	if spec[3] ~= nil then
		step = scaling_number(engine_path(ability, spec[3]), "step")
		if step == nil then
			return nil, false
		end
	end
	if value == nil or rawget(view, "kind") ~= spec[1] or rawget(view, "value") ~= value
		or rawget(view, "step") ~= step then
		return nil, false
	end
	return { kind = spec[1], value = value, step = step }, true
end

-- M4: the engine's own-card X-multiplier (hundredths), from
-- `card.ability.x_mult` (copied from `center.config.Xmult`, pinned
-- card.lua:288), for the strict enhancement allowlist only. `ok` is false only
-- on an out-of-contract value; `value` is nil when the card carries none.
local CARD_XMULT_CENTERS = { m_glass = true }
local CARD_XMULT_MIN = 100
local CARD_XMULT_MAX = 10000

local function engine_card_xmult(card)
	local key = rget(rget(rget(card, "config"), "center"), "key")
	if type(key) ~= "string" or CARD_XMULT_CENTERS[key] ~= true then
		return nil, true
	end
	if rget(card, "debuff") == true then
		return nil, true
	end
	local value = rget(rget(card, "ability"), "x_mult")
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil, true
	end
	local scaled = math.floor(value * 100 + 0.5)
	if scaled < CARD_XMULT_MIN or scaled > CARD_XMULT_MAX then
		return nil, true
	end
	return scaled, true
end

-- Returns the verified hundredths, or nil, false when the view disagrees.
local function copy_card_xmult(view, card)
	local projected = rawget(view, "xmult")
	if not is_int(projected) or projected < CARD_XMULT_MIN or projected > CARD_XMULT_MAX then
		return nil, false
	end
	local engine_value, ok = engine_card_xmult(card)
	if ok ~= true or engine_value == nil or engine_value ~= projected then
		return nil, false
	end
	return engine_value, true
end

local function build_entity(record, card, kind)
	local face_down = rawget(record, "face_down")
	local facing = rget(card, "facing")
	local sprite_facing = rget(card, "sprite_facing")
	local front = (facing == "front" and sprite_facing == "front")
	if face_down ~= false or front ~= true then
		return { face_down = true }
	end
	local shown = rawget(record, "shown")
	if shown ~= nil and not is_plain(shown) then
		return nil
	end
	local mask_rank, mask_suit = center_masks(card)
	local out = { face_down = false }
	local fields = ENTITY_FIELDS[kind]
	for i = 1, #fields do
		local name = fields[i]
		local visible = shown ~= nil and rawget(shown, name) == true
		if visible then
			local masked = (name == "rank" and mask_rank) or (name == "suit" and mask_suit)
			if not masked then
				local projected = project_field(name, rawget(record, name))
				if projected ~= nil then
					out[name] = projected
				end
			end
		end
	end
	if kind == "joker" and shown ~= nil and rawget(shown, "current") == true then
		local view = rawget(record, "current")
		if view ~= nil then
			local current, ok = copy_current(view, card, record)
			if not ok then
				return nil
			end
			out.current = current
		end
	end
	-- M4: verify the projected own-card X-multiplier against the engine card.
	-- The view may declare it only for the strict enhancement allowlist, and the
	-- recomputed engine value must match exactly; a mismatch or out-of-range
	-- value rejects the entity (fail closed).
	if kind == "card" and rawget(record, "xmult") ~= nil then
		local xmult, ok = copy_card_xmult(record, card)
		if not ok then
			return nil
		end
		if xmult ~= nil then
			out.xmult = xmult
		end
	end
	if kind == "card" and rawget(record, "bonus_chips") ~= nil then
		local ability = rget(card, "ability")
		local bonus, permanent = rget(ability, "bonus") or 0, rget(ability, "perma_bonus") or 0
		local value = rawget(record, "bonus_chips")
		if rget(card, "debuff") == true or not is_int(bonus) or not is_int(permanent)
			or bonus < 0 or permanent < 0 or bonus + permanent > 100000
			or not is_int(value) or value ~= bonus + permanent then return nil end
		out.bonus_chips = value
	end
	return out
end

local function build_zone(G, view_zone, zone_name)
	local spec = ZONES[zone_name]
	if view_zone == nil then
		return nil
	end
	if not is_plain(view_zone) then
		return nil, CODE.BAD_VIEW
	end
	local count = raw_array_count(view_zone, spec.array_limit)
	if count == nil then
		return nil, CODE.BAD_VIEW
	end
	local cards, card_count = engine_cards(G, spec.area, spec.area_limit)
	if cards == nil then
		return nil, CODE.ENTITY_MISMATCH
	end
	if spec.whole and card_count ~= count then
		return nil, CODE.ENTITY_MISMATCH
	end
	local out = {}
	local seen_ordinals = {}
	for i = 1, count do
		local record = rawget(view_zone, i)
		if not is_plain(record) then
			return nil, CODE.BAD_VIEW
		end
		local ordinal = i
		if not spec.whole then
			ordinal = rawget(record, "ordinal")
			if not is_int(ordinal) or ordinal < 1 or ordinal > spec.area_limit then
				return nil, CODE.BAD_VIEW
			end
			if seen_ordinals[ordinal] then
				return nil, CODE.ENTITY_MISMATCH
			end
			seen_ordinals[ordinal] = true
			if ordinal > card_count then
				return nil, CODE.ENTITY_MISMATCH
			end
		end
		local card = rawget(cards, ordinal)
		if type(card) ~= "table" then
			return nil, CODE.ENTITY_MISMATCH
		end
		local entity = build_entity(record, card, spec.kind)
		if entity == nil then
			return nil, CODE.BAD_VIEW
		end
		out[i] = entity
	end
	return out
end

-- Public poker-hand levels: only allowlisted hand names, each exactly
-- { level, chips, mult } as non-negative integers. Unknown names are never read.
local HAND_LEVEL_NAMES = {
	"high_card", "pair", "two_pair", "three", "straight", "flush", "full_house",
	"four", "straight_flush", "five", "flush_house", "flush_five",
}

local function copy_hand_levels(source)
	if source == nil then
		return nil
	end
	if not is_plain(source) then
		return nil, CODE.BAD_VIEW
	end
	local out = nil
	for i = 1, #HAND_LEVEL_NAMES do
		local name = HAND_LEVEL_NAMES[i]
		local entry = rawget(source, name)
		if entry ~= nil then
			if not is_plain(entry) then
				return nil, CODE.BAD_VIEW
			end
			local level = rawget(entry, "level")
			local chips = rawget(entry, "chips")
			local mult = rawget(entry, "mult")
			if not is_int(level) or not is_int(chips) or not is_int(mult) or level < 0 or chips < 0 or mult < 0 then
				return nil, CODE.BAD_VIEW
			end
			out = out or {}
			out[name] = { level = level, chips = chips, mult = mult }
			local played = rawget(entry, "played_this_round")
			if played ~= nil then
				if not is_int(played) or played < 0 or played > 1000 then
					return nil, CODE.BAD_VIEW
				end
				out[name].played_this_round = played
			end
		end
	end
	return out
end

-- The AI's own redeemed voucher keys (adapter `owned_vouchers`): a plain
-- array of at most LIMITS.owned_vouchers strings matching `^v_[a-z0-9_]+$`
-- (<= 32 bytes), strictly increasing bytewise. Output records carry only the
-- key; they are not bound to engine objects and no action targets them.
local function bytes_before(a, b)
	local n = math.min(#a, #b)
	for i = 1, n do
		local x, y = string.byte(a, i), string.byte(b, i)
		if x ~= y then
			return x < y
		end
	end
	return #a < #b
end

local function copy_owned_vouchers(source)
	if source == nil then
		return nil
	end
	if not is_plain(source) then
		return nil, CODE.BAD_VIEW
	end
	local n = 0
	for key in next, source do
		n = n + 1
		if not is_int(key) or key < 1 or n > LIMITS.owned_vouchers then
			return nil, CODE.BAD_VIEW
		end
	end
	local out = {}
	local previous = nil
	for i = 1, n do
		local key = rawget(source, i)
		if type(key) ~= "string" or #key > 32 or string.find(key, "^v_[a-z0-9_]+$") == nil then
			return nil, CODE.BAD_VIEW
		end
		if previous ~= nil and not bytes_before(previous, key) then
			return nil, CODE.BAD_VIEW
		end
		previous = key
		out[i] = { face_down = false, center = key }
	end
	if n == 0 then
		return nil
	end
	return out
end

local function copy_deck(source)
	if source == nil then
		return nil
	end
	if not is_plain(source) then
		return nil, CODE.BAD_VIEW
	end
	-- M1: only the on-screen total is projected. Rank/suit aggregates are
	-- unsupported (no unknown bucket, wheel_flipped preview rule unmodelled), so
	-- by_suit/by_rank are neither read nor traversed here.
	local out = {}
	local total = rawget(source, "total")
	if total ~= nil then
		if not is_int(total) or total < 0 then
			return nil, CODE.BAD_VIEW
		end
		out.total = total
	end
	return out
end

local function derive_engine_phase(G)
	local states = rget(G, "STATES")
	if type(states) ~= "table" then
		return nil, CODE.UNSUPPORTED_STATE
	end
	local state = rget(G, "STATE")
	if not is_int(state) then
		return nil, CODE.UNSUPPORTED_STATE
	end
	local found = nil
	for i = 1, #ENGINE_SYMBOLS do
		local entry = ENGINE_SYMBOLS[i]
		local value = rget(states, entry.symbol)
		if is_int(value) and value == state then
			if found ~= nil and found ~= entry.phase then
				return nil, CODE.UNSUPPORTED_STATE
			end
			found = entry.phase
		end
	end
	if found == nil then
		return nil, CODE.UNSUPPORTED_STATE
	end
	return found
end

local function get_pvp_context(view)
	local recognition = rawget(view, "recognition")
	if not is_plain(recognition) then
		return nil
	end
	local value = rawget(recognition, "pvp_context")
	if type(value) ~= "boolean" then
		return nil
	end
	return value
end

-- M2: the run's PvP-boss state is derived from the engine, never trusted from a
-- caller boolean. Returns true (proven PvP), false (proven non-PvP) or nil
-- (unknown -> callers must fail closed). Evidence: MP `is_pvp_boss()` is
-- G.GAME.blind.config.blind.key == "bl_mp_nemesis" or G.GAME.blind.pvp.
local function engine_pvp_boss(G)
	local blind = rget(rget(G, "GAME"), "blind")
	if type(blind) ~= "table" then
		return nil
	end
	-- Lua truthiness, exactly as MP's `... or blind.pvp` does: any non-nil,
	-- non-false value (0, "", tables, functions, ...) means PvP. The value is
	-- compared only; it is never invoked or traversed.
	local pvp = rget(blind, "pvp")
	if pvp ~= nil and pvp ~= false then
		return true
	end
	local key = rget(rget(rget(blind, "config"), "blind"), "key")
	if key == "bl_mp_nemesis" then
		return true
	end
	-- Non-PvP is proven only by a nonempty string key plus nil/false pvp.
	if type(key) == "string" and #key > 0 then
		return false
	end
	return nil
end

local function build_match(G, MP, view)
	local out = {}
	local view_match = rawget(view, "match")
	if view_match ~= nil then
		if not is_plain(view_match) then
			return nil, CODE.BAD_VIEW
		end
		local ruleset = rawget(view_match, "ruleset")
		if ruleset ~= nil then
			local projected = project_token(ruleset, LIMITS.token)
			if projected == nil then
				return nil, CODE.BAD_VIEW
			end
			out.ruleset = projected
		end
		local blind = as_display(rawget(view_match, "blind"), 32)
		if blind ~= nil then
			out.blind = blind
		end
		-- blind_disabled: a strict boolean, only with a blind, and equal to the
		-- engine's own G.GAME.blind.disabled (never trusted from the view).
		local disabled = rawget(view_match, "blind_disabled")
		if disabled ~= nil then
			local engine_disabled = rget(rget(rget(G, "GAME"), "blind"), "disabled")
			if project_bool(disabled) == nil or out.blind == nil or disabled ~= (engine_disabled == true) then
				return nil, CODE.BAD_VIEW
			end
			out.blind_disabled = disabled
		end
		local timer = as_display(rawget(view_match, "timer"), 16)
		if timer ~= nil and rawget(view_match, "timer_visible") == true then
			local lobby = rget(MP, "LOBBY")
			local config = rget(lobby, "config")
			local lobby_code = rget(lobby, "code")
			if rget(config, "timer") == true
				and rget(config, "disable_live_and_timer_hud") ~= true
				and type(lobby_code) == "string" and #lobby_code > 0 then
				out.timer = timer
			end
		end
		local counts = { "lives", "hands_per_round", "discards_per_round", "hand_size", "joker_slots", "consumable_slots" }
		for i = 1, #counts do
			local value = rawget(view_match, counts[i])
			if value ~= nil then
				if not is_int(value) or value < 0 then
					return nil, CODE.BAD_VIEW
				end
				out[counts[i]] = value
			end
		end
	end
	local game = rget(G, "GAME")
	-- Public own deck rule, derived from the real Back object, never the view.
	-- Vanilla Back:trigger_effect balances only this name at final_scoring_step.
	local back_name = rget(rget(game, "selected_back"), "name")
	if type(back_name) == "string" then
		out.score_balanced = back_name == "Plasma Deck"
	end
	-- Read the AI's own visible active countdown. Deriving it here keeps the
	-- changing seconds out of the adapter's action epoch: elapsed time changes
	-- strategy, but not legal-action identity. Never inspect the enemy timer.
	local mp_game = rget(MP, "GAME")
	local config = rget(rget(MP, "LOBBY"), "config")
	local lobby_code = rget(rget(MP, "LOBBY"), "code")
	local active = rget(mp_game, "timer_started") == true or rget(mp_game, "nemesis_timer_started") == true
	if engine_pvp_boss(G) == true then
		local is_layer = rget(MP, "is_layer_active")
		local pvp_timer = true
		if type(is_layer) == "function" then
			local ok, value = pcall(is_layer, "pvp_timer")
			if ok and type(value) == "boolean" then
				pvp_timer = value
			end
		end
		active = pvp_timer and rget(mp_game, "nemesis_timer_started") == true
	end
	local timer = rget(mp_game, "timer")
	if active and rget(config, "timer") == true and rget(config, "disable_live_and_timer_hud") ~= true
		and type(lobby_code) == "string" and #lobby_code > 0
		and type(timer) == "number" and timer == timer and timer ~= math.huge and timer ~= -math.huge then
		out.timer_remaining = math.max(0, math.min(INT_MAX, math.floor(timer)))
	end
	local resets = rget(game, "round_resets")
	local ante = rget(resets, "ante")
	if is_int(ante) and ante >= 0 then
		out.ante = ante
	end
	local round = rget(game, "round")
	if is_int(round) and round >= 0 then
		out.round = round
	end
	return out
end

local function build_self(G, view, phase)
	local out = {}
	local allow_hand = PHASE_ALLOWS_HAND[phase] == true
	local game = rget(G, "GAME")
	local dollars = rget(game, "dollars")
	if is_int(dollars) then
		out.money = dollars
	end
	local bankrupt = rget(game, "bankrupt_at")
	if is_int(bankrupt) and bankrupt <= 0 and bankrupt > INT_MIN then
		out.credit_limit = -bankrupt
	end
	if allow_hand then
		local current_round = rget(game, "current_round")
		local hands_left = rget(current_round, "hands_left")
		if is_int(hands_left) and hands_left >= 0 then
			out.hands = hands_left
		end
		local discards_left = rget(current_round, "discards_left")
		if is_int(discards_left) and discards_left >= 0 then
			out.discards = discards_left
		end
	end

	local view_self = rawget(view, "self")
	if view_self ~= nil and not is_plain(view_self) then
		return nil, CODE.BAD_VIEW
	end
	if view_self ~= nil then
		local score = as_display(rawget(view_self, "current_score"), 32)
		if score ~= nil then
			out.current_score = score
		end
		local requirement = as_display(rawget(view_self, "blind_requirement"), 32)
		if requirement ~= nil then
			out.blind_requirement = requirement
		end
	end

	local hand_visible = view_self ~= nil and rawget(view_self, "hand_visible") == true
	local cards = rget(view_self, "cards")
	if cards ~= nil and not is_plain(cards) then
		return nil, CODE.BAD_VIEW
	end
	if view_self ~= nil then
		for i = 1, #SELF_ENTITY_ZONES do
			local entry = SELF_ENTITY_ZONES[i]
			local list, zone_code = build_zone(G, rget(cards, entry.view), entry.zone)
			if zone_code ~= nil then
				return nil, zone_code
			end
			if list ~= nil then
				out[entry.field] = list
			end
		end
	end
	if allow_hand and hand_visible then
		out.hand_visible = true
		local hand, hand_code = build_zone(G, rget(cards, "hand"), "hand")
		if hand_code ~= nil then
			return nil, hand_code
		end
		if hand ~= nil then
			out.hand = hand
		end
	end

	local deck, deck_code = copy_deck(rget(view_self, "deck"))
	if deck_code ~= nil then
		return nil, deck_code
	end
	if deck ~= nil then
		out.deck = deck
	end
	local levels, levels_code = copy_hand_levels(rget(view_self, "hand_levels"))
	if levels_code ~= nil then
		return nil, levels_code
	end
	if levels ~= nil then
		out.hand_levels = levels
	end
	local owned, owned_code = copy_owned_vouchers(rget(view_self, "owned_vouchers"))
	if owned_code ~= nil then
		return nil, owned_code
	end
	if owned ~= nil then
		out.vouchers = owned
	end
	return out
end

local function build_opponent(MP, G, view, phase)
	local view_opponent = rawget(view, "opponent")
	if view_opponent == nil then
		return nil
	end
	if not is_plain(view_opponent) then
		return nil, CODE.BAD_VIEW
	end
	if rawget(view_opponent, "certified") ~= true then
		return nil
	end

	local mp_game = rget(MP, "GAME")
	local enemy = rget(mp_game, "enemy")
	local lobby = rget(MP, "LOBBY")
	local config = rget(lobby, "config")
	local current_round = rget(rget(G, "GAME"), "current_round")

	local out = { certified = true }
	local has_field = false
	local info_received = rget(enemy, "info_received")

	if rawget(view_opponent, "score_visible") == true and info_received == true then
		local hide_score = rget(config, "hide_score_until_played")
		local masked = false
		if hide_score ~= false then
			if hide_score ~= true then
				masked = true
			else
				local hands_played = rget(current_round, "hands_played")
				if not is_int(hands_played) or hands_played < 0 then
					masked = true
				elseif hands_played == 0 then
					if phase == "MULTIPLAYER_PVP" then
						-- Unconditional in a PvP phase, regardless of a false view flag.
						masked = true
					else
						-- Unmask only if the view says non-PvP AND the engine proves non-PvP.
						local view_pvp = get_pvp_context(view)
						local engine_pvp = engine_pvp_boss(G)
						if view_pvp == false and engine_pvp == false then
							masked = false
						else
							masked = true
						end
					end
				end
			end
		end
		if not masked then
			local score = rawget(view_opponent, "displayed_score")
			if score == nil then
				score = rget(enemy, "score_text")
			end
			local projected = as_display(score, 32)
			if projected ~= nil then
				out.displayed_score = projected
				has_field = true
			end
		end
	end

	if rawget(view_opponent, "hands_visible") == true and info_received == true then
		local hands = rawget(view_opponent, "hands")
		if not is_int(hands) or hands < 0 or hands > 99 then
			hands = parse_count_text(rget(enemy, "hands_text"))
		end
		if is_int(hands) and hands >= 0 and hands <= 99 then
			out.hands = hands
			has_field = true
		end
	end

	if rawget(view_opponent, "lives_visible") == true and info_received == true then
		local lives = rawget(view_opponent, "lives")
		if is_int(lives) and lives >= 0 then
			out.lives = lives
			has_field = true
		end
	end

	if rawget(view_opponent, "location_visible") == true then
		local disabled = rget(config, "enemy_location_disabled")
		if disabled == false then
			local location = as_display(rawget(view_opponent, "location"), 32)
			if location ~= nil then
				out.location = location
				has_field = true
			end
		end
	end

	if rawget(view_opponent, "timer_visible") == true then
		local timer_enabled = rget(config, "timer")
		local hud_disabled = rget(config, "disable_live_and_timer_hud")
		local lobby_code = rget(lobby, "code")
		if timer_enabled == true and hud_disabled ~= true and type(lobby_code) == "string" and #lobby_code > 0 then
			local rendered = as_display(rawget(view_opponent, "timer"), 16)
			if rendered ~= nil then
				out.timer = rendered
				has_field = true
			end
		end
	end

	if not has_field then
		return nil
	end
	return out
end

local function build_shop(G, view_shop)
	local out = {}
	local reroll = rawget(view_shop, "reroll_cost")
	if reroll ~= nil then
		if not is_int(reroll) or reroll < 0 then
			return nil, CODE.BAD_VIEW
		end
		out.reroll_cost = reroll
	end
	local items, items_code = build_zone(G, rawget(view_shop, "items"), "shop")
	if items_code ~= nil then
		return nil, items_code
	end
	if items ~= nil then
		out.items = items
	end
	local boosters, boosters_code = build_zone(G, rawget(view_shop, "boosters"), "shop_booster")
	if boosters_code ~= nil then
		return nil, boosters_code
	end
	if boosters ~= nil then
		out.boosters = boosters
	end
	local vouchers, vouchers_code = build_zone(G, rawget(view_shop, "vouchers"), "shop_voucher")
	if vouchers_code ~= nil then
		return nil, vouchers_code
	end
	if vouchers ~= nil then
		out.vouchers = vouchers
	end
	return out
end

local function build_booster(G, view_booster)
	local out = {}
	local kind = rawget(view_booster, "kind")
	if kind ~= nil then
		local projected = project_token(kind, 32)
		if projected == nil then
			return nil, CODE.BAD_VIEW
		end
		out.kind = projected
	end
	local counts = { "choices", "skips" }
	for i = 1, #counts do
		local value = rawget(view_booster, counts[i])
		if value ~= nil then
			if not is_int(value) or value < 0 then
				return nil, CODE.BAD_VIEW
			end
			out[counts[i]] = value
		end
	end
	local cards, cards_code = build_zone(G, rawget(view_booster, "cards"), "booster")
	if cards_code ~= nil then
		return nil, cards_code
	end
	if cards ~= nil then
		out.cards = cards
	end
	return out
end

local function build_target(G, view_target)
	local source = rawget(view_target, "source")
	if not is_plain(source) then
		return nil, CODE.BAD_VIEW
	end
	local ordinal = rawget(source, "ordinal")
	if not is_int(ordinal) or ordinal < 1 or ordinal > LIMITS.consumables then
		return nil, CODE.BAD_VIEW
	end
	local cards, card_count = engine_cards(G, "consumeables", LIMITS.consumables)
	if cards == nil or ordinal > card_count then
		return nil, CODE.ENTITY_MISMATCH
	end
	local card = rawget(cards, ordinal)
	if type(card) ~= "table" then
		return nil, CODE.ENTITY_MISMATCH
	end
	local source_entity = build_entity(source, card, "consumable")
	if source_entity == nil then
		return nil, CODE.BAD_VIEW
	end
	local out = { source = source_entity, source_ref = "consumable:" .. dec_string(ordinal) }
	local counts = { "min_targets", "max_targets" }
	for i = 1, #counts do
		local value = rawget(view_target, counts[i])
		if value ~= nil then
			if not is_int(value) or value < 0 then
				return nil, CODE.BAD_VIEW
			end
			out[counts[i]] = value
		end
	end
	local targets, targets_code = build_zone(G, rawget(view_target, "targets"), "target")
	if targets_code ~= nil then
		return nil, targets_code
	end
	if targets ~= nil then
		out.targets = targets
	end
	return out
end

local function check_runtime(runtime)
	if not is_plain(runtime) then
		return nil, CODE.BAD_RUNTIME
	end
	if rawget(runtime, "role") ~= "ai_staged" then
		return nil, CODE.BAD_ROLE
	end
	local epoch = rawget(runtime, "epoch")
	if not is_int(epoch) or epoch < 0 then
		return nil, CODE.BAD_EPOCH
	end
	local G = rawget(runtime, "G")
	local MP = rawget(runtime, "MP")
	if type(G) ~= "table" or type(MP) ~= "table" then
		return nil, CODE.BAD_RUNTIME
	end
	return { G = G, MP = MP, epoch = epoch }
end

local function build_frame(checked, view)
	local G = checked.G
	local MP = checked.MP

	local phase = rawget(view, "phase")
	if type(phase) ~= "string" or PHASES[phase] ~= true then
		return nil, CODE.BAD_VIEW
	end
	local engine_phase, state_code = derive_engine_phase(G)
	if engine_phase == nil then
		return nil, state_code
	end
	local compatible = COMPATIBLE[engine_phase]
	if compatible == nil or compatible[phase] ~= true then
		return nil, CODE.PHASE_MISMATCH
	end

	local view_shop = rawget(view, "shop")
	local view_booster = rawget(view, "booster")
	local view_target = rawget(view, "consumable_target")
	if phase ~= "SHOP" and view_shop ~= nil then
		return nil, CODE.PHASE_MISMATCH
	end
	if phase ~= "BOOSTER_SELECTION" and view_booster ~= nil then
		return nil, CODE.PHASE_MISMATCH
	end
	if phase ~= "CONSUMABLE_SELECTION" and view_target ~= nil then
		return nil, CODE.PHASE_MISMATCH
	end
	if phase == "SHOP" and not is_plain(view_shop) then
		return nil, CODE.BAD_VIEW
	end
	if phase == "BOOSTER_SELECTION" and not is_plain(view_booster) then
		return nil, CODE.BAD_VIEW
	end
	if phase == "CONSUMABLE_SELECTION" and not is_plain(view_target) then
		return nil, CODE.BAD_VIEW
	end

	local frame = { schema_version = SCHEMA_VERSION, phase = phase }
	local match, match_code = build_match(G, MP, view)
	if match == nil then
		return nil, match_code
	end
	frame.match = match

	if phase ~= "MATCH_COMPLETE" then
		local self_out, self_code = build_self(G, view, phase)
		if self_out == nil then
			return nil, self_code
		end
		frame.self = self_out

		local opponent, opponent_code = build_opponent(MP, G, view, phase)
		if opponent_code ~= nil then
			return nil, opponent_code
		end
		if opponent ~= nil then
			frame.opponent = opponent
		end

		if phase == "SHOP" then
			local shop, shop_code = build_shop(G, view_shop)
			if shop == nil then
				return nil, shop_code
			end
			frame.shop = shop
		elseif phase == "BOOSTER_SELECTION" then
			local booster, booster_code = build_booster(G, view_booster)
			if booster == nil then
				return nil, booster_code
			end
			frame.booster = booster
		elseif phase == "CONSUMABLE_SELECTION" then
			local target, target_code = build_target(G, view_target)
			if target == nil then
				return nil, target_code
			end
			frame.consumable_target = target
		end

		local context = rawget(view, "context")
		if context ~= nil then
			if not is_plain(context) then
				return nil, CODE.BAD_VIEW
			end
			frame.context = context
		end
		local certificates = rawget(view, "certificates")
		if certificates ~= nil then
			if not is_plain(certificates) then
				return nil, CODE.BAD_VIEW
			end
			frame.certificates = certificates
		end
	end

	return frame
end

function StateReader.factory(observation)
	if type(observation) ~= "table" or type(observation.observe) ~= "function" then
		return nil, CODE.BAD_OBSERVATION
	end

	local instance = {}
	instance.CODE = copy_codes(CODE)
	instance.SCHEMA_VERSION = SCHEMA_VERSION
	instance.LIMITS = copy_codes(LIMITS)

	function instance.capture(runtime, ui_view)
		local checked, runtime_code = check_runtime(runtime)
		if checked == nil then
			return nil, runtime_code
		end
		if not is_plain(ui_view) then
			return nil, CODE.BAD_VIEW
		end
		local view_epoch = rawget(ui_view, "epoch")
		if not is_int(view_epoch) or view_epoch < 0 then
			return nil, CODE.BAD_VIEW
		end
		if view_epoch ~= checked.epoch then
			return nil, CODE.EPOCH_MISMATCH
		end

		local frame, frame_code = build_frame(checked, ui_view)
		if frame == nil then
			return nil, frame_code
		end

		local ok, handle, observe_code = pcall(observation.observe, frame)
		if not ok or handle == nil then
			return nil, observe_code or CODE.OBSERVE_FAILED
		end
		if type(observation.is_handle) == "function" then
			local ok_check, valid = pcall(observation.is_handle, handle)
			if not ok_check or valid ~= true then
				return nil, CODE.OBSERVE_FAILED
			end
		end
		return handle
	end

	function instance.describe()
		local zones = {}
		for key, value in next, ZONES do
			zones[key] = {
				kind = value.kind,
				whole = value.whole,
				area_limit = value.area_limit,
				array_limit = value.array_limit,
			}
		end
		local phases = {}
		for key in next, PHASES do
			phases[key] = true
		end
		local codes = copy_codes(CODE)
		local limits = copy_codes(LIMITS)
		return {
			schema_version = SCHEMA_VERSION,
			phases = phases,
			zones = zones,
			codes = codes,
			limits = limits,
		}
	end

	return instance
end

StateReader.CODE = copy_codes(CODE)
StateReader.LIMITS = copy_codes(LIMITS)

return StateReader
