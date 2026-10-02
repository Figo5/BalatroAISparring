-- Typed canonical binding for the Ranked effective-configuration contract.
--
-- Pure, side-effect-free mirror of the Python authority in
-- `tools/ranked_effective_config.py` (domain `aisparring.ranked_effective_config
-- .v1`). Both languages must produce byte-identical canonical strings and FNV1a-32
-- equality checksums for the same typed field table; the shared fixture suite
-- proves parity under Lua 5.1 and LuaJIT. This module reads no engine state and
-- references no global; the caller supplies the already-read actual field table.
--
-- The checksum is an equality primitive only. It is not authentication; the
-- authenticated control channel and the immutable SHA-256 source/native
-- certificate remain the authority.

local RankedConfig = {}

RankedConfig.DOMAIN = "aisparring.ranked_effective_config.v1"
RankedConfig.SCHEMA = RankedConfig.DOMAIN

RankedConfig.MAX_STRING = 64
RankedConfig.MAX_CANONICAL = 262144
RankedConfig.INT_MIN = -2147483648
RankedConfig.INT_MAX = 2147483647

-- Fixed enumerated field order; identical to the Python `_LOBBY_ORDER`.
RankedConfig.LOBBY_ORDER = {
	"gold_on_life_loss",
	"no_gold_on_round_loss",
	"death_on_round_loss",
	"different_seeds",
	"the_order",
	"starting_lives",
	"pvp_start_round",
	"timer_base_seconds",
	"timer_increment_seconds",
	"pvp_countdown_seconds",
	"showdown_starting_antes",
	"weekly",
	"custom_seed",
	"different_decks",
	"random_loadout",
	"back",
	"sleeve",
	"stake",
	"challenge",
	"cocktail",
	"multiplayer_jokers",
	"timer",
	"timer_forgiveness",
	"forced_config",
	"preview_disabled",
	"legacy_smallworld",
	"hide_score_until_played",
	"enemy_location_disabled",
	"timer_display_threshold",
	"modifier_layers",
	"disable_live_and_timer_hud",
	"pvp_timer_base_seconds",
	"pvp_timer_hand_played_increment_seconds",
	"normal_bosses",
	"timer_hand_played_increment_seconds",
	"timer_base_multiplier",
	"preview_calculate_delay",
	"preview_calculate_cost",
}

-- Fixed enumerated resolved-field order; identical to `_RESOLVED_ORDER`.
RankedConfig.RESOLVED_ORDER = {
	"ruleset_key",
	"ruleset_id",
	"forced_gamemode",
	"declared_layers",
	"active_layer_chain",
	"standard",
	"multiplayer_content",
	"modifier_list",
	"pvp_timer_base_seconds_resolved",
	"pvp_timer_hand_played_increment_seconds_resolved",
	"effective_timer_base_seconds",
	"timer_base_multiplier_resolved",
	"is_disabled",
}

RankedConfig.LIST_KEYS = {
	declared_layers = true,
	active_layer_chain = true,
	modifier_list = true,
}

-- The host-owned completed-draft selection contract (exact keys/types). The
-- expected back/stake come only from this validated binding.
RankedConfig.SELECTION_SCHEMA = "aisparring.ranked_selection.v1"
RankedConfig.SELECTION_KEYS = {
	schema = true,
	deck_key = true,
	back_key = true,
	back_name = true,
	stake_key = true,
	stake_index = true,
}
RankedConfig.MAX_STAKE_INDEX = 8

-- Per-field type schema. Identical to the Python ``FIELD_TYPES`` and enforced
-- before any tag is written: the type is declared by the field, never inferred
-- from the runtime value. ``nil`` means the field must be exactly the typed-nil
-- sentinel; ``str_list`` is a dense ordered list of non-empty bounded strings.
RankedConfig.FIELD_TYPES = {
	lobby = {
		gold_on_life_loss = "bool",
		no_gold_on_round_loss = "bool",
		death_on_round_loss = "bool",
		different_seeds = "bool",
		the_order = "bool",
		starting_lives = "int",
		pvp_start_round = "int",
		timer_base_seconds = "int",
		timer_increment_seconds = "int",
		pvp_countdown_seconds = "int",
		showdown_starting_antes = "int",
		weekly = "nil",
		custom_seed = "str",
		different_decks = "bool",
		random_loadout = "bool",
		back = "str",
		sleeve = "str",
		stake = "int",
		challenge = "str",
		cocktail = "str",
		multiplayer_jokers = "bool",
		timer = "bool",
		timer_forgiveness = "int",
		forced_config = "bool",
		preview_disabled = "bool",
		legacy_smallworld = "bool",
		hide_score_until_played = "bool",
		enemy_location_disabled = "bool",
		timer_display_threshold = "int",
		modifier_layers = "str",
		disable_live_and_timer_hud = "bool",
		pvp_timer_base_seconds = "nil",
		pvp_timer_hand_played_increment_seconds = "nil",
		normal_bosses = "nil",
		timer_hand_played_increment_seconds = "nil",
		timer_base_multiplier = "nil",
		preview_calculate_delay = "nil",
		preview_calculate_cost = "nil",
	},
	resolved = {
		ruleset_key = "str",
		ruleset_id = "str",
		forced_gamemode = "str",
		declared_layers = "str_list",
		active_layer_chain = "str_list",
		standard = "bool",
		multiplayer_content = "bool",
		modifier_list = "str_list",
		pvp_timer_base_seconds_resolved = "int",
		pvp_timer_hand_played_increment_seconds_resolved = "int",
		effective_timer_base_seconds = "int",
		timer_base_multiplier_resolved = "int",
		is_disabled = "bool",
	},
}

local HEX = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" }

-- Explicit typed-nil marker. A Lua table cannot hold a nil value, so the actual
-- view builder must set a nil field to this unique sentinel; the key is then
-- present (never silently missing) and tags as `n`. This preserves the required
-- distinction between a missing required key (an error) and an explicitly nil
-- field.
RankedConfig.NIL = setmetatable({}, { __tostring = function() return "ranked_config_nil" end })

local function is_int(n)
	if type(n) ~= "number" then
		return false
	end
	if n ~= n or n == math.huge or n == -math.huge then
		return false
	end
	if n % 1 ~= 0 then
		return false
	end
	return n >= RankedConfig.INT_MIN and n <= RankedConfig.INT_MAX
end

local function xor8(a, b)
	local result = 0
	local bit = 1
	for _ = 1, 8 do
		local abit = a % 2
		local bbit = b % 2
		if abit ~= bbit then
			result = result + bit
		end
		a = (a - abit) / 2
		b = (b - bbit) / 2
		bit = bit * 2
	end
	return result
end

local function mulmod32(a, b)
	local high = math.floor(a / 65536)
	local low = a - high * 65536
	local lo = (low * b) % 4294967296
	local hi = ((high * b) % 65536) * 65536
	return (lo + hi) % 4294967296
end

local function to_hex8(n)
	local out = {}
	for i = 1, 8 do
		local nib = n % 16
		out[i] = HEX[nib + 1]
		n = (n - nib) / 16
	end
	local s = {}
	for i = 8, 1, -1 do
		s[#s + 1] = out[i]
	end
	return table.concat(s)
end

-- FNV1a-32, identical to `Codec.hash_string`. Returns eight lowercase hex.
function RankedConfig.fnv1a32_hex(text)
	if type(text) ~= "string" then
		return nil, "ranked_canonical_type_invalid"
	end
	if #text > RankedConfig.MAX_CANONICAL then
		return nil, "ranked_canonical_too_large"
	end
	local hash = 2166136261
	for i = 1, #text do
		local byte = string.byte(text, i)
		local low = hash % 256
		local high = hash - low
		hash = high + xor8(low, byte)
		hash = mulmod32(hash, 16777619)
	end
	return to_hex8(hash)
end

-- Byte-bounded, no control byte (<0x20 or 0x7f) and no separator. Mirrors the
-- Python `_string_invalid`; Lua strings are byte sequences so `#value` is the
-- same UTF-8 byte length Python tags.
local function string_invalid(value)
	if #value > RankedConfig.MAX_STRING then
		return true
	end
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte < 0x20 or byte == 0x7f then
			return true
		end
	end
	return string.find(value, "|", 1, true) ~= nil or string.find(value, "=", 1, true) ~= nil
end

-- Validate a value against its declared field type. ``nil`` is the typed-nil
-- sentinel only; a real Lua nil is never a table value and so is never accepted
-- in its place.
local function field_type_ok(kind, value)
	if kind == "nil" then
		return value == RankedConfig.NIL
	end
	if kind == "bool" then
		return type(value) == "boolean"
	end
	if kind == "int" then
		return is_int(value)
	end
	if kind == "str" then
		return type(value) == "string" and not string_invalid(value)
	end
	if kind == "str_list" then
		if type(value) ~= "table" then
			return false
		end
		-- Dense array only: integer keys 1..#value, no holes and no extra keys.
		local count = 0
		for key in next, value do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then
				return false
			end
			count = count + 1
		end
		if count ~= #value then
			return false
		end
		for i = 1, #value do
			local item = value[i]
			if type(item) ~= "string" or #item == 0 or string_invalid(item) then
				return false
			end
		end
		return true
	end
	return false
end

-- Explicit type tag for one primitive. Nil is a distinct tag from empty string;
-- booleans are distinct from string spellings. A table/function/userdata value
-- is a type error, never stringified.
function RankedConfig.type_tag(value)
	if value == nil or value == RankedConfig.NIL then
		return "n"
	end
	local kind = type(value)
	if kind == "boolean" then
		return value and "b1" or "b0"
	end
	if kind == "number" then
		if not is_int(value) then
			return nil, "ranked_canonical_type_invalid"
		end
		return "i" .. string.format("%d", value)
	end
	if kind == "string" then
		if string_invalid(value) then
			return nil, "ranked_canonical_string_invalid"
		end
		return "s" .. string.format("%d", #value) .. ":" .. value
	end
	return nil, "ranked_canonical_type_invalid"
end

-- Ordered list tag: `l<count>[<tag>,<tag>,...]`; empty list is `l0[]`.
function RankedConfig.type_tag_list(values)
	if type(values) ~= "table" then
		return nil, "ranked_canonical_type_invalid"
	end
	local parts = {}
	for i = 1, #values do
		local tag, code = RankedConfig.type_tag(values[i])
		if tag == nil then
			return nil, code
		end
		parts[i] = tag
	end
	return "l" .. string.format("%d", #values) .. "[" .. table.concat(parts, ",") .. "]"
end

local function check_keys(table_value, order, required_code, unknown_code)
	if type(table_value) ~= "table" then
		return false, "ranked_canonical_type_invalid"
	end
	local present = {}
	for key in next, table_value do
		present[key] = true
	end
	local known = {}
	for i = 1, #order do
		known[order[i]] = true
		if present[order[i]] == nil then
			-- A missing required key is an error, never a typed nil.
			return false, required_code
		end
	end
	for key in next, present do
		if known[key] ~= true then
			return false, unknown_code
		end
	end
	return true
end

-- Domain-separated, fixed-order, type-tagged canonical string. Every enumerated
-- key is required; an unknown or missing key fails closed.
function RankedConfig.canonical_bytes(lobby, resolved)
	local ok, code = check_keys(
		lobby,
		RankedConfig.LOBBY_ORDER,
		"ranked_canonical_missing_lobby_key",
		"ranked_canonical_unknown_lobby_key"
	)
	if not ok then
		return nil, code
	end
	ok, code = check_keys(
		resolved,
		RankedConfig.RESOLVED_ORDER,
		"ranked_canonical_missing_resolved_key",
		"ranked_canonical_unknown_resolved_key"
	)
	if not ok then
		return nil, code
	end
	local parts = { RankedConfig.DOMAIN }
	for i = 1, #RankedConfig.LOBBY_ORDER do
		local key = RankedConfig.LOBBY_ORDER[i]
		local value = lobby[key]
		if not field_type_ok(RankedConfig.FIELD_TYPES.lobby[key], value) then
			return nil, "ranked_canonical_field_type"
		end
		local tag, tag_code = RankedConfig.type_tag(value)
		if tag == nil then
			return nil, tag_code
		end
		parts[#parts + 1] = key .. "=" .. tag
	end
	for i = 1, #RankedConfig.RESOLVED_ORDER do
		local key = RankedConfig.RESOLVED_ORDER[i]
		local value = resolved[key]
		if not field_type_ok(RankedConfig.FIELD_TYPES.resolved[key], value) then
			return nil, "ranked_canonical_field_type"
		end
		local tag, tag_code
		if RankedConfig.LIST_KEYS[key] == true then
			tag, tag_code = RankedConfig.type_tag_list(value)
		else
			tag, tag_code = RankedConfig.type_tag(value)
		end
		if tag == nil then
			return nil, tag_code
		end
		parts[#parts + 1] = key .. "=" .. tag
	end
	local canonical = table.concat(parts, "|")
	if #canonical > RankedConfig.MAX_CANONICAL then
		return nil, "ranked_canonical_too_large"
	end
	return canonical
end

-- Canonical bytes then FNV1a-32. Returns the checksum hex or nil + code.
function RankedConfig.digest(lobby, resolved)
	local canonical, code = RankedConfig.canonical_bytes(lobby, resolved)
	if canonical == nil then
		return nil, code
	end
	local checksum, hash_code = RankedConfig.fnv1a32_hex(canonical)
	if checksum == nil then
		return nil, hash_code
	end
	return checksum, canonical
end

-- Post-start selection check, mirroring `check_post_start_selection`. `actual`
-- carries the real initialized values (`back_key` from
-- `selected_back.effect.center.key`, `stake` from `G.GAME.stake`); a nil value
-- is a bounded "not initialized yet" retry, not a mismatch.
function RankedConfig.check_post_start_selection(selection, actual_back_key, actual_stake)
	if actual_back_key == nil or actual_stake == nil then
		return false, "ranked_post_start_uninitialized", true
	end
	if type(selection) ~= "table" then
		return false, "ranked_selection_schema_invalid", false
	end
	if actual_back_key ~= selection.back_key then
		return false, "ranked_post_start_back_mismatch", false
	end
	if not is_int(actual_stake) or actual_stake ~= selection.stake_index then
		return false, "ranked_post_start_stake_mismatch", false
	end
	return true, "ok", false
end

-- ---------------------------------------------------------------------------
-- Dedicated draft commitment (full ban-pick profile)
-- ---------------------------------------------------------------------------
-- The host-owned completed draft publishes an ordered public pool and legal
-- transcript; both runtime roles independently validate the same bounded public
-- commitment here and derive the identical digest. A supplied digest is never
-- trusted and never echoed.

RankedConfig.DRAFT_SCHEMA = "aisparring.ranked_draft.v1"
RankedConfig.DRAFT_COMMITMENT_DOMAIN = "aisparring.ranked_draft_commitment.v1"
RankedConfig.DRAFT_PROFILE_ID = "aisparring.ranked_draft_profile.standard_1_2_2.v1"
RankedConfig.DRAFT_POOL_SIZE = 9
RankedConfig.DRAFT_STAGE_COUNTS = { 1, 2, 2, 1 }
RankedConfig.DRAFT_STAGE_OPS = { "ban", "ban", "ban", "select" }
RankedConfig.MAX_OPTION_ID = 48
RankedConfig.MAX_DRAFT_KEY = 32

local function key_ok(value)
	if type(value) ~= "string" or #value < 1 or #value > RankedConfig.MAX_DRAFT_KEY then
		return false
	end
	return string.match(value, "^[%w_]+$") ~= nil
end

local function option_id_ok(value)
	if type(value) ~= "string" or #value < 3 or #value > RankedConfig.MAX_OPTION_ID then
		return false
	end
	local sep = string.find(value, "~", 1, true)
	if sep == nil then
		return false
	end
	if string.find(value, "~", sep + 1, true) ~= nil then
		return false
	end
	return key_ok(string.sub(value, 1, sep - 1)) and key_ok(string.sub(value, sep + 1))
end

-- Domain-separated canonical string for the completed draft. Identical format to
-- `ranked_draft.commitment_canonical` in the Python authority.
function RankedConfig.draft_commitment_canonical(profile_id, first_actor, pool, transcript, final)
	if profile_id ~= RankedConfig.DRAFT_PROFILE_ID then
		return nil, "ranked_draft_profile_invalid"
	end
	if first_actor ~= "human" and first_actor ~= "ai" then
		return nil, "ranked_draft_canonical_invalid"
	end
	if type(pool) ~= "table" then
		return nil, "ranked_draft_canonical_invalid"
	end
	local pool_tokens = {}
	for i = 1, #pool do
		if not option_id_ok(pool[i]) then
			return nil, "ranked_draft_canonical_invalid"
		end
		pool_tokens[i] = pool[i]
	end
	if type(transcript) ~= "table" then
		return nil, "ranked_draft_canonical_invalid"
	end
	local step_tokens = {}
	for i = 1, #transcript do
		local step = transcript[i]
		if type(step) ~= "table" or (step.actor ~= "human" and step.actor ~= "ai")
			or (step.operation ~= "ban" and step.operation ~= "select") then
			return nil, "ranked_draft_canonical_invalid"
		end
		local options = step.option_ids
		if type(options) ~= "table" or #options < 1 then
			return nil, "ranked_draft_canonical_invalid"
		end
		local ids = {}
		for j = 1, #options do
			if not option_id_ok(options[j]) then
				return nil, "ranked_draft_canonical_invalid"
			end
			ids[j] = options[j]
		end
		step_tokens[i] = step.actor .. ":" .. step.operation .. ":" .. table.concat(ids, "+")
	end
	if type(final) ~= "string" or not option_id_ok(final) then
		return nil, "ranked_draft_canonical_invalid"
	end
	local canonical = table.concat({
		RankedConfig.DRAFT_COMMITMENT_DOMAIN,
		"profile=" .. profile_id,
		"first=" .. first_actor,
		"pool=" .. table.concat(pool_tokens, ","),
		"transcript=" .. table.concat(step_tokens, ";"),
		"final=" .. final,
	}, "|")
	if #canonical > 8192 then
		return nil, "ranked_draft_canonical_too_large"
	end
	return canonical
end

function RankedConfig.draft_commitment_digest(profile_id, first_actor, pool, transcript, final)
	local canonical, code = RankedConfig.draft_commitment_canonical(profile_id, first_actor, pool, transcript, final)
	if canonical == nil then
		return nil, code
	end
	local checksum, hash_code = RankedConfig.fnv1a32_hex(canonical)
	if checksum == nil then
		return nil, hash_code
	end
	return checksum
end

-- Independently validate one public draft commitment and derive its digest.
-- Returns ``digest, "ok", final`` or ``nil, code``. Mirrors
-- `ranked_draft.commitment_from_public`.
function RankedConfig.validate_draft(draft)
	if type(draft) ~= "table" then
		return nil, "ranked_draft_commitment_missing"
	end
	if draft.schema ~= RankedConfig.DRAFT_SCHEMA then
		return nil, "ranked_draft_commitment_schema"
	end
	if draft.profile_id ~= RankedConfig.DRAFT_PROFILE_ID then
		return nil, "ranked_draft_profile_invalid"
	end
	local first = draft.first_actor
	if first ~= "human" and first ~= "ai" then
		return nil, "ranked_draft_first_actor_invalid"
	end
	local pool = draft.pool
	if type(pool) ~= "table" or #pool ~= RankedConfig.DRAFT_POOL_SIZE then
		return nil, "ranked_draft_pool_size"
	end
	local pool_seen = {}
	for i = 1, #pool do
		local option = pool[i]
		if not option_id_ok(option) or pool_seen[option] then
			return nil, "ranked_draft_pool_invalid"
		end
		pool_seen[option] = true
	end
	local transcript = draft.transcript
	if type(transcript) ~= "table" or #transcript ~= #RankedConfig.DRAFT_STAGE_COUNTS then
		return nil, "ranked_draft_transcript_shape"
	end
	local second = first == "human" and "ai" or "human"
	local remaining = {}
	for i = 1, #pool do
		remaining[pool[i]] = true
	end
	local remaining_count = #pool
	local final = nil
	for stage = 1, #RankedConfig.DRAFT_STAGE_COUNTS do
		local step = transcript[stage]
		if type(step) ~= "table" then
			return nil, "ranked_draft_transcript_shape"
		end
		local actor = (stage % 2 == 1) and first or second
		if step.actor ~= actor then
			return nil, "ranked_draft_turn"
		end
		if step.operation ~= RankedConfig.DRAFT_STAGE_OPS[stage] then
			return nil, "ranked_draft_operation"
		end
		local options = step.option_ids
		if type(options) ~= "table" or #options ~= RankedConfig.DRAFT_STAGE_COUNTS[stage] then
			return nil, "ranked_draft_count"
		end
		if step.operation == "select" then
			if remaining_count ~= 4 then
				return nil, "ranked_draft_remaining"
			end
		end
		local seen_step = {}
		for i = 1, #options do
			local option = options[i]
			if not option_id_ok(option) then
				return nil, "ranked_draft_option_invalid"
			end
			if seen_step[option] then
				return nil, "ranked_draft_duplicate_option"
			end
			seen_step[option] = true
			if remaining[option] ~= true then
				return nil, "ranked_draft_option_unavailable"
			end
		end
		if step.operation == "select" then
			final = options[1]
		else
			for option in next, seen_step do
				remaining[option] = nil
				remaining_count = remaining_count - 1
			end
		end
	end
	if final == nil then
		return nil, "ranked_draft_transcript_shape"
	end
	if draft.final ~= final then
		return nil, "ranked_draft_final_mismatch"
	end
	local digest, code = RankedConfig.draft_commitment_digest(
		RankedConfig.DRAFT_PROFILE_ID, first, pool, transcript, final
	)
	if digest == nil then
		return nil, code
	end
	return digest, "ok", final
end

-- Exact selection schema/type check (mirrors the Python `validate_selection`
-- shape checks): exact keys, bounded primitive strings, an int stake index in
-- range. The catalog binding itself is validated host-side.
function RankedConfig.selection_valid(selection)
	if type(selection) ~= "table" then
		return false, "ranked_selection_schema_invalid"
	end
	for key in next, selection do
		if RankedConfig.SELECTION_KEYS[key] ~= true then
			return false, "ranked_selection_schema_invalid"
		end
	end
	for key in next, RankedConfig.SELECTION_KEYS do
		if selection[key] == nil then
			return false, "ranked_selection_schema_invalid"
		end
	end
	if selection.schema ~= RankedConfig.SELECTION_SCHEMA then
		return false, "ranked_selection_schema_invalid"
	end
	for _, key in ipairs({ "deck_key", "back_key", "back_name", "stake_key" }) do
		local value = selection[key]
		if type(value) ~= "string" or #value == 0 or string_invalid(value) then
			return false, "ranked_selection_schema_invalid"
		end
	end
	if not is_int(selection.stake_index)
		or selection.stake_index < 1
		or selection.stake_index > RankedConfig.MAX_STAKE_INDEX then
		return false, "ranked_selection_stake_invalid"
	end
	return true, "ok"
end

return RankedConfig
