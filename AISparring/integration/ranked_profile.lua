-- Read-only, privileged preparation/readiness producers. No policy capability,
-- profile mutation, unlock callback invocation, RNG, or personal history access.
local Profile = {}
local VERSIONS = {
	Steamodded = "1.0.0~BETA-1620a", Lovely = "0.9.0",
	Multiplayer = "0.5.5", AISparring = "0.1.0-dev",
	["lovely-compat-aisparring-staging"] = "0.0.0",
}
local function get(t, k)
	if type(t) == "table" then return rawget(t, k) end
	return nil
end
-- Steamodded GameObject instances inherit set/name/mod defaults. Read these
-- engine-owned fields with the same semantics as Multiplayer, while containing
-- a faulty metamethod and keeping the resulting primitive checks fail-closed.
local function object_field(t, k)
	if type(t) ~= "table" then return nil, false end
	local ok, value = pcall(function() return t[k] end)
	return value, ok
end

function Profile.approved_mods()
	-- Actual Multiplayer parse_modlist splits on the LAST dash.
	return { ["Steamodded-1.0.0~BETA"] = "1620a", Lovely = "0.9.0",
		Multiplayer = "0.5.5", ["AISparring-0.1.0"] = "dev",
		["lovely-compat-aisparring-staging"] = "0.0.0" }
end

function Profile.inventory_ok(smods, mp)
	local mods = get(smods, "Mods")
	if type(mods) ~= "table" or get(smods, "booted") ~= true then return nil end
	for id, version in pairs(VERSIONS) do
		local mod = rawget(mods, id)
		if type(mod) ~= "table" or rawget(mod, "version") ~= version
			or rawget(mod, "disabled") == true or rawget(mod, "can_load") ~= true then return false end
	end
	-- Steamodded advertises our certificate-bound, patch-only isolation guard
	-- as a lovely compatibility mod. Require its real loader metadata too.
	local guard = rawget(mods, "lovely-compat-aisparring-staging")
	if rawget(guard, "lovely") ~= true or rawget(guard, "lovely_only") ~= true
		or rawget(guard, "meta_mod") ~= true then return false end
	for id, mod in pairs(mods) do
		if id ~= "Balatro" and VERSIONS[id] == nil then return false end
	end
	local integrations = get(mp, "INTEGRATIONS")
	if type(integrations) ~= "table" then return nil end
	for id, enabled in pairs(integrations) do
		-- The minimal generation disables all optional integrations, including
		-- Preview. A changed config must be reprovisioned, not silently trusted.
		if type(enabled) ~= "boolean" or enabled ~= false then return false end
	end
	return true
end

function Profile.content_unlocked(G)
	local settings, profiles = get(G, "SETTINGS"), get(G, "PROFILES")
	local profile = get(profiles, get(settings, "profile"))
	if type(profile) ~= "table" or rawget(profile, "all_unlocked") ~= true then return false end
	for _, pool in ipairs({ "P_CENTERS", "P_BLINDS", "P_TAGS" }) do
		local objects = get(G, pool)
		if type(objects) ~= "table" or next(objects) == nil then return nil end
		for _, object in pairs(objects) do
			if type(object) ~= "table" then return nil end
			if not rawget(object, "demo") and not rawget(object, "wip")
				and rawget(object, "unlocked") ~= true then return false end
		end
	end
	return true
end

function Profile.facts(G, smods, mp, release)
	local inventory = Profile.inventory_ok(smods, mp)
	local debug = get(G, "DEBUG")
	local debug_disabled = "unknown"
	if type(debug) == "boolean" then debug_disabled = debug == false end
	return {
		debug_disabled = debug_disabled,
		animations_normal = inventory == nil and "unknown" or inventory,
		handy_disabled = inventory == nil and "unknown" or inventory,
		content_unlocked = Profile.content_unlocked(G),
		tutorial_ready = get(get(G, "SETTINGS"), "tutorial_complete") == true
			and get(get(G, "SETTINGS"), "tutorial_progress") == nil,
	}
end

function Profile.catalog(G, smods, mp)
	if Profile.inventory_ok(smods, mp) ~= true then return nil end
	local eligible_fn = get(mp, "get_cocktail_decks")
	local stake_fn = get(smods, "stake_from_index")
	if type(eligible_fn) ~= "function" or type(stake_fn) ~= "function" then return nil end
	local ok, eligible = pcall(eligible_fn, false)
	if not ok or type(eligible) ~= "table" or #eligible == 0 then return nil end
	local centers, seen, decks = get(G, "P_CENTERS"), {}, {}
	for _, key in ipairs(eligible) do
		if type(key) ~= "string" or seen[key] or key == "b_mp_cocktail" then return nil end
		seen[key] = true
		local center = get(centers, key)
		local set, set_ok = object_field(center, "set")
		local name, name_ok = object_field(center, "name")
		local mod, mod_ok = object_field(center, "mod")
		if not set_ok or not name_ok or not mod_ok or set ~= "Back" or type(name) ~= "string" then return nil end
		-- Only base-game Back centers enter this first practice draft.
		if mod == nil and key:match("^b_[%w_]+$") then
			decks[key:sub(3)] = { center_key = key, name = name }
		end
	end
	local cap = get(get(mp, "DECK"), "MAX_STAKE")
	if type(cap) ~= "number" or cap ~= math.floor(cap) or cap < 0 then return nil end
	if cap == 0 then cap = 8 end
	cap = math.min(cap, 8)
	local allowed = { white = true, green = true, black = true, purple = true, gold = true }
	local stakes = {}
	for i = 1, cap do
		local ok_stake, key = pcall(stake_fn, i)
		if not ok_stake or type(key) ~= "string" then return nil end
		local short = key:match("^stake_([%w_]+)$")
		if short and allowed[short] then stakes[short] = { index = i, max_index = cap } end
	end
	if next(decks) == nil or stakes.white == nil then return nil end
	return { schema = "aisparring.ranked_catalog.v1", eligible_decks = eligible, decks = decks, stakes = stakes }
end

function Profile.preparation(G, smods, mp, love, encode, env, release)
	local elapsed = 0
	local instance = {}
	function instance.update(dt)
		elapsed = elapsed + (type(dt) == "number" and dt or 0)
		if elapsed < 1 or get(smods, "booted") ~= true then return end
		elapsed = 0
		local utils = get(mp, "UTILS")
		local cached = get(mp, "MOD_STRING")
		if type(cached) ~= "string" or #cached == 0 then return end
		local ok, parsed = pcall(get(utils, "parse_Hash"), cached)
		local ok_unlock, unlocked = pcall(get(utils, "unlock_check"))
		local facts = Profile.facts(G, smods, mp, release)
		local speed = get(get(G, "SETTINGS"), "GAMESPEED")
		local report = {
			schema = "aisparring.ranked_preparation.v1", nonce = env("AISP_PROBE_NONCE"),
			role = env("BALATRO_AI_ROLE"), release_mode = release == true,
			debug_disabled = facts.debug_disabled, animations_normal = facts.animations_normal,
			handy_disabled = facts.handy_disabled, content_unlocked = facts.content_unlocked == true,
			tutorial_ready = facts.tutorial_ready,
			unlock_check = ok_unlock and unlocked == true,
			advertised_unlocked = ok and get(parsed, "unlocked") == true,
			mods = ok and get(parsed, "Mods") or {},
			game_speed_ok = type(speed) == "number" and speed == speed and speed > 0 and speed <= 4,
			catalog = Profile.catalog(G, smods, mp),
		}
		if type(encode) == "function" and type(get(love, "filesystem")) == "table" then
			local encoded_ok, bytes = pcall(encode, report)
			if encoded_ok then love.filesystem.write("aisparring-ranked-preparation.json", bytes) end
		end
	end
	function instance.status() return { booted = true, state = "profile_preparation" } end
	function instance.uninstall() return true end
	return instance
end

return Profile
