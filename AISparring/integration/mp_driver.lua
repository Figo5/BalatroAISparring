-- Multiplayer match driver for the staged runtimes.
--
-- The human staged client hosts a real local Multiplayer lobby with the actual
-- Major League ruleset and its forced gamemode; the AI staged client joins that
-- exact lobby code from the trusted control service. Both sides then use the
-- ordinary Multiplayer ready/start callbacks. Nothing here opens, closes or
-- redirects the official match transport, and nothing here fabricates a fake
-- peer: the driver only calls the real callbacks the game already exposes.
--
-- Placement of the trusted gauntlet seed (docs/PLAYABLE_RUNTIME_CONTRACT.md
-- "Match orchestration"): `G.FUNCS.start_lobby` calls `MP.reset_lobby_config`,
-- so the seed cannot be set before the call. It also calls
-- `MP.current_ruleset():force_lobby_options()` right before it creates the
-- lobby, so the seed must land after the reset and before the *original*
-- force_lobby_options. The driver does exactly that with a scoped, always
-- restored wrapper around `MP.current_ruleset`; it never re-implements the
-- Major League timer/location/option values.
--
-- All engine access is through injected ports (`mp`, `funcs`, `actions`,
-- `rulesets`, `element_for`); the module references no global.

local MPDriver = {}

MPDriver.CODE = {
	OK = "driver_ok",
	BAD_PORTS = "driver_bad_ports",
	BAD_ROLE = "driver_bad_role",
	BAD_ENGINE = "driver_bad_engine",
	BAD_SEED = "driver_bad_seed",
	BAD_CODE = "driver_bad_code",
	BAD_STATE = "driver_bad_state",
	BAD_DIGEST = "driver_bad_digest",
	NO_RULESET = "driver_no_ruleset",
	NO_FORCED_MODE = "driver_no_forced_gamemode",
	MISSING_CALLBACK = "driver_missing_callback",
	MISSING_ACTION = "driver_missing_action",
	MISSING_ELEMENT = "driver_missing_element",
	START_LOBBY_FAILED = "driver_start_lobby_failed",
	ALREADY_READY = "driver_already_ready",
	NOT_READY = "driver_not_ready",
	WRONG_ROLE = "driver_wrong_role",
	SEND_BLOCKED = "driver_send_blocked",
	INTERNAL = "driver_internal_error",
}

-- Real guest ready element id (pinned Multiplayer
-- ui/lobby/start_ready_button.lua and ui/lobby/lobby.lua:520). The lookup goes
-- through the injected real `G.MAIN_MENU_UI`; a fabricated button is never
-- substituted because the real callback mutates the element's config/children
-- and UIBox.
MPDriver.READY_ELEMENT_ID = "lobby_menu_start"

MPDriver.RULESET_KEY = "ruleset_mp_majorleague"
MPDriver.RULESET_SHORT = "majorleague"
MPDriver.AI_NAME = "BALATRO AI"
MPDriver.FORCED_MODE = "gamemode_mp_attrition"

MPDriver.LIMITS = {
	max_token = 64,
	max_code = 32,
	max_name = 24,
}

-- Real protocol actions the staged runtimes may originate. Every name is the
-- exact wire action from the pinned Multiplayer source (networking/
-- action_handlers.lua and the MP.ACTIONS senders). The AI's send guard
-- default-denies anything outside this set, so the required life/timer
-- penalties (`failTimer`, `failPvPTimer`, `startAnteTimer`, `pauseAnteTimer`)
-- and ordinary gameplay are never silenced. `lobbyOptions` is handled
-- separately: only the trusted human host may push it, only before start.
MPDriver.SEND_ALLOWLIST = {
	-- lobby lifecycle
	createLobby = true,
	joinLobby = true,
	rejoinLobby = true,
	leaveLobby = true,
	readyLobby = true,
	unreadyLobby = true,
	startGame = true,
	stopGame = true,
	lobbyInfo = true,
	-- in-match coordination / gameplay
	readyBlind = true,
	unreadyBlind = true,
	playHand = true,
	newRound = true,
	setAnte = true,
	setLocation = true,
	skip = true,
	setFurthestBlind = true,
	failRound = true,
	dataSync = true,
	keepAliveAck = true,
	version = true,
	username = true,
	-- required life/timer penalties (never silenced)
	startAnteTimer = true,
	pauseAnteTimer = true,
	failTimer = true,
	failPvPTimer = true,
	-- ordinary gameplay actions raised by Multiplayer content
	asteroid = true,
	eatPizza = true,
	spentLastShop = true,
	soldJoker = true,
	magnet = true,
	magnetResponse = true,
	sendPhantom = true,
	removePhantom = true,
	letsGoGamblingNemesis = true,
}

-- Config-changing actions only the trusted host may send before the match
-- starts. The guest can never push lobby configuration.
MPDriver.HOST_ONLY = {
	createLobby = true,
	lobbyOptions = true,
}

-- Guest-only lifecycle actions.
MPDriver.GUEST_ONLY = {
	joinLobby = true,
	rejoinLobby = true,
}

-- Real wire actions that must never leave a staged runtime: ranked/server
-- logging, end-game result exchange and private opponent deck queries, plus
-- auth and modded actions.
MPDriver.SEND_BLOCKED = {
	submitLogHashes = true,
	streamLogLines = true,
	endGameStatsRequested = true,
	sendGameStats = true,
	getEndGameJokers = true,
	getNemesisDeck = true,
	nemesisEndGameStats = true,
	receiveEndGameJokers = true,
	receiveNemesisDeck = true,
	connect = true,
	auth = true,
	authenticate = true,
	rankedSubmit = true,
	rankedScore = true,
	submitResult = true,
	uploadResult = true,
	resultSubmit = true,
	moddedAction = true,
}

local CODE = MPDriver.CODE

local SEED_PATTERN = "^[0-9A-Za-z_%-]+$"
local CODE_PATTERN = "^[0-9A-Za-z_%-]+$"
local TOKEN_PATTERN = "^[0-9A-Za-z_%-]+$"

local FORCED_STRING_MAX = 64
local INT_MIN = -2147483648
local INT_MAX = 2147483647

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= INT_MIN and value <= INT_MAX
end

-- Canonical digest primitive per docs/MAJOR_LEAGUE_DIGEST.md: booleans lowercase,
-- ints decimal, bounded strings without pipe/equals/newline. Anything else is
-- unsupported and refuses the digest instead of stringifying a table.
local function digest_primitive(value)
	if value == true then
		return "true"
	end
	if value == false then
		return "false"
	end
	if is_int(value) then
		return string.format("%d", value)
	end
	if type(value) == "string" then
		if #value > FORCED_STRING_MAX then
			return nil
		end
		if string.find(value, "|", 1, true) ~= nil
			or string.find(value, "=", 1, true) ~= nil
			or string.find(value, "\r", 1, true) ~= nil
			or string.find(value, "\n", 1, true) ~= nil then
			return nil
		end
		return value
	end
	return nil
end

local function rget(obj, key)
	if type(obj) ~= "table" or key == nil then
		return nil
	end
	return rawget(obj, key)
end

local function rpath(obj, a, b)
	return rget(rget(obj, a), b)
end

local function token_of(value, pattern, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, pattern) == nil then
		return nil
	end
	return value
end

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

MPDriver.CODE = shallow_copy(CODE)

function MPDriver.factory(ports)
	if not is_plain(ports) then
		return nil, CODE.BAD_PORTS
	end
	local role = rawget(ports, "role")
	if role ~= "human" and role ~= "ai" then
		return nil, CODE.BAD_ROLE
	end
	local mp = rawget(ports, "mp")
	local funcs = rawget(ports, "funcs")
	if type(mp) ~= "table" or type(funcs) ~= "table" then
		return nil, CODE.BAD_ENGINE
	end
	if type(rget(mp, "LOBBY")) ~= "table" then
		return nil, CODE.BAD_ENGINE
	end
	local element_for = rawget(ports, "element_for")
	if element_for ~= nil and type(element_for) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local logger = rawget(ports, "logger")
	if logger ~= nil and (type(logger) ~= "table" or type(rget(logger, "record")) ~= "function") then
		return nil, CODE.BAD_PORTS
	end

	local rulesets = rawget(ports, "rulesets") or rget(mp, "Rulesets")
	local actions = rawget(ports, "actions") or rget(mp, "ACTIONS")
	local client = rawget(ports, "client")
	local G = rawget(ports, "G")
	local hash_string = rawget(ports, "hash_string")
	if hash_string ~= nil and type(hash_string) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local is_started_port = rawget(ports, "is_started")
	if is_started_port ~= nil and type(is_started_port) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	if is_started_port == nil and rget(mp, "is_started") ~= nil and type(rget(mp, "is_started")) ~= "function" then
		return nil, CODE.BAD_ENGINE
	end
	local is_connected_port = rawget(ports, "is_connected")
	if is_connected_port ~= nil and type(is_connected_port) ~= "function" then
		return nil, CODE.BAD_PORTS
	end

	local started = false
	-- Forced Major League config keys recorded from the real registry
	-- `force_lobby_options` call (never hardcoded), plus the values snapshot they
	-- produced. Used for the source-derived expected/actual digest.
	local forced_keys = nil
	local forced_gamemode = nil

	local function match_started()
		if started then
			return true
		end
		if is_started_port ~= nil then
			local ok, value = pcall(is_started_port)
			if ok and value == true then
				return true
			end
		end
		if type(rget(mp, "is_started")) == "function" then
			local ok, value = pcall(mp.is_started)
			if ok and value == true then
				return true
			end
		end
		if rpath(mp, "LOBBY", "started") == true then
			return true
		end
		return false
	end

	local function is_host_role()
		local flag = rpath(mp, "LOBBY", "is_host")
		if flag == true then
			return true
		end
		if flag == false then
			return false
		end
		return role == "human"
	end

	local originals = {
		start_lobby = rawget(funcs, "start_lobby"),
		lobby_ready_up = rawget(funcs, "lobby_ready_up"),
		lobby_start_game = rawget(funcs, "lobby_start_game"),
	}
	local installed_guard = nil
	local instance = {}

	local function emit(fields)
		if logger == nil then
			return
		end
		pcall(logger.record, fields)
	end

	-- Registry inspection: the live MP registry is keyed by the full
	-- "ruleset_mp_<short>" string; tolerate the bare short key as a fallback.
	local function lookup_ruleset()
		if type(rulesets) ~= "table" then
			return nil
		end
		local entry = rulesets[MPDriver.RULESET_KEY]
		if entry == nil then
			entry = rulesets[MPDriver.RULESET_SHORT]
		end
		if type(entry) ~= "table" then
			return nil
		end
		return entry
	end

	function instance.ruleset()
		local entry = lookup_ruleset()
		if entry == nil then
			return nil, CODE.NO_RULESET
		end
		local gamemode = rget(entry, "forced_gamemode")
		if type(gamemode) ~= "string" or #gamemode == 0 then
			return nil, CODE.NO_FORCED_MODE
		end
		return { key = MPDriver.RULESET_KEY, gamemode = gamemode, forced_lobby_options = rget(entry, "forced_lobby_options") }
	end

	function instance.lobby_code()
		return token_of(rpath(mp, "LOBBY", "code"), CODE_PATTERN, MPDriver.LIMITS.max_code)
	end

	-- The real Multiplayer socket state. Staged create/join must wait for it.
	function instance.connected()
		if is_connected_port ~= nil then
			local ok, value = pcall(is_connected_port)
			if ok and type(value) == "boolean" then
				return value
			end
		end
		return rpath(mp, "LOBBY", "connected") == true
	end

	-- The real initialized main menu: `start_lobby`/`join_lobby` are main-menu
	-- callbacks and must not fire before the menu exists. Prefer the resolved
	-- engine stage enum; fall back to the real menu UI handle (fixtures/tests).
	function instance.main_menu_ready()
		local stages = rget(G, "STAGES")
		local stage_value = rget(G, "STAGE")
		local main_menu = rget(stages, "MAIN_MENU")
		if is_int(stage_value) and is_int(main_menu) then
			return stage_value == main_menu
		end
		return rget(G, "MAIN_MENU_UI") ~= nil
	end

	-- The registry entry and the live forced ruleset must agree before any
	-- create/join. A registry that has not finished initialization (or the wrong
	-- ruleset) is never treated as ready.
	function instance.ruleset_ready()
		local entry = lookup_ruleset()
		if entry == nil then
			return false, CODE.NO_RULESET
		end
		local gamemode = rget(entry, "forced_gamemode")
		if type(gamemode) ~= "string" or #gamemode == 0 then
			return false, CODE.NO_FORCED_MODE
		end
		local config = rpath(mp, "LOBBY", "config")
		if type(config) ~= "table" or rawget(config, "ruleset") ~= MPDriver.RULESET_KEY then
			return false, CODE.BAD_STATE
		end
		return true, CODE.OK
	end

	-- Forced config keys recorded from the real registry `force_lobby_options`.
	function instance.forced_keys()
		if forced_keys == nil then
			return nil
		end
		local out = {}
		for key in next, forced_keys do
			out[#out + 1] = key
		end
		table.sort(out)
		return out
	end

	-- Source-derived Major League digest: ruleset_id | gamemode then each forced
	-- key (bytewise ascending) as |key=value, read from the *actual* live
	-- MP.LOBBY.config and hashed with the injected Codec.hash_string (FNV1a32,
	-- eight lowercase hex). Never echoes a service-provided expected digest.
	-- `keys` (optional) is the trusted SETUP forced-options keyset. When absent
	-- the keys recorded from the local registry call are used (host path).
	function instance.config_digest(ruleset_id, gamemode, keys)
		if type(hash_string) ~= "function" then
			return nil, CODE.BAD_DIGEST
		end
		if type(ruleset_id) ~= "string" or #ruleset_id == 0 or #ruleset_id > MPDriver.LIMITS.max_token then
			return nil, CODE.BAD_DIGEST
		end
		if type(gamemode) ~= "string" or #gamemode == 0 or #gamemode > MPDriver.LIMITS.max_token then
			return nil, CODE.BAD_DIGEST
		end
		if keys == nil then
			keys = instance.forced_keys()
		end
		if type(keys) ~= "table" or #keys == 0 then
			return nil, CODE.BAD_DIGEST
		end
		local config = rpath(mp, "LOBBY", "config")
		if type(config) ~= "table" then
			return nil, CODE.BAD_DIGEST
		end
		if rawget(config, "ruleset") ~= MPDriver.RULESET_KEY then
			return nil, CODE.BAD_STATE
		end
		-- Bytewise ascending key order; copy first so the caller's array is
		-- never mutated.
		local sorted = {}
		for i = 1, #keys do
			local key = keys[i]
			if type(key) ~= "string" or #key == 0 or #key > MPDriver.LIMITS.max_token then
				return nil, CODE.BAD_DIGEST
			end
			sorted[i] = key
		end
		table.sort(sorted)
		local parts = { ruleset_id, gamemode }
		for i = 1, #sorted do
			local key = sorted[i]
			local primitive = digest_primitive(rawget(config, key))
			if primitive == nil then
				return nil, CODE.BAD_DIGEST
			end
			parts[#parts + 1] = key .. "=" .. primitive
		end
		local ok, value = pcall(hash_string, table.concat(parts, "|"))
		if not ok or type(value) ~= "string" or #value == 0 then
			return nil, CODE.BAD_DIGEST
		end
		return value, CODE.OK
	end

	-- Human host. `seed` is trusted setup data (gauntlet, human-only) and may be
	-- nil for a normal random match; it is never derived from policy.
	function instance.host_start(seed)
		if role ~= "human" then
			return nil, CODE.WRONG_ROLE
		end
		local ruleset = lookup_ruleset()
		if ruleset == nil then
			return nil, CODE.NO_RULESET
		end
		local gamemode = rget(ruleset, "forced_gamemode")
		if type(gamemode) ~= "string" or #gamemode == 0 then
			return nil, CODE.NO_FORCED_MODE
		end
		if type(originals.start_lobby) ~= "function" then
			return nil, CODE.MISSING_CALLBACK
		end
		local current_ruleset = rawget(mp, "current_ruleset")
		if type(current_ruleset) ~= "function" then
			return nil, CODE.NO_RULESET
		end
		local bounded_seed = nil
		if seed ~= nil then
			bounded_seed = token_of(seed, SEED_PATTERN, MPDriver.LIMITS.max_token)
			if bounded_seed == nil then
				return nil, CODE.BAD_SEED
			end
		end

		mp.LOBBY.config.ruleset = MPDriver.RULESET_KEY
		mp.LOBBY.config.gamemode = gamemode

		local previous = current_ruleset
		mp.current_ruleset = function()
			local resolved = previous()
			return setmetatable({}, {
				__index = function(_, key)
					if key == "force_lobby_options" then
						return function()
							-- After the reset, before the original options call.
							if bounded_seed ~= nil then
								mp.LOBBY.config.custom_seed = bounded_seed
							end
							local original = rget(resolved, "force_lobby_options")
							if type(original) ~= "function" then
								return false
							end
							-- Record exactly which config keys the real
							-- ruleset function assigns, without hardcoding them.
							local backing = mp.LOBBY.config
							local recorded = {}
							local proxy = setmetatable({}, {
								__index = function(_, inner_key)
									return backing[inner_key]
								end,
								__newindex = function(_, inner_key, value)
									recorded[inner_key] = true
									backing[inner_key] = value
								end,
							})
							mp.LOBBY.config = proxy
							local ok_force, result = pcall(original, resolved)
							mp.LOBBY.config = backing
							if ok_force then
								forced_keys = recorded
								forced_gamemode = gamemode
							end
							return result
						end
					end
					return resolved[key]
				end,
			})
		end

		local ok, err = pcall(originals.start_lobby, nil)
		mp.current_ruleset = previous
		if not ok then
			emit({ event = "mp_driver", code = CODE.START_LOBBY_FAILED, detail = tostring(err) })
			return nil, CODE.START_LOBBY_FAILED
		end
		if forced_keys == nil then
			-- The real registry never forced options: not source-ready.
			return nil, CODE.BAD_STATE
		end
		emit({ event = "mp_driver", code = CODE.OK, op = "host_start", gauntlet = bounded_seed ~= nil })
		return true, CODE.OK
	end

	-- AI guest. `code` is the exact lobby code the trusted service handed over.
	function instance.ai_join(code)
		if role ~= "ai" then
			return nil, CODE.WRONG_ROLE
		end
		local bounded = token_of(code, CODE_PATTERN, MPDriver.LIMITS.max_code)
		if bounded == nil then
			return nil, CODE.BAD_CODE
		end
		if type(actions) ~= "table" or type(rget(actions, "join_lobby")) ~= "function" then
			return nil, CODE.MISSING_ACTION
		end
		mp.LOBBY.username = MPDriver.AI_NAME
		if type(rget(actions, "set_username")) == "function" then
			pcall(actions.set_username, MPDriver.AI_NAME)
		end
		local ok = pcall(actions.join_lobby, bounded)
		if not ok then
			return nil, CODE.MISSING_ACTION
		end
		emit({ event = "mp_driver", code = CODE.OK, op = "ai_join", named = true })
		return true, CODE.OK
	end

	-- Real guest ready element: the pinned UI creates
	-- `G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")` for the ready button. A
	-- fabricated skeleton is never substituted (the real callback mutates the
	-- element's config/children and UIBox). An injected `element_for` port may
	-- override the lookup for fixtures, but must return the same real shape.
	local function resolve_ready_element()
		if element_for ~= nil then
			local ok, element = pcall(element_for, "lobby_ready")
			if ok and type(element) == "table" then
				return element
			end
		end
		local ui = rget(G, "MAIN_MENU_UI")
		local get_by_id = nil
		if type(ui) == "table" then
			-- Normal indexing: real UIBox objects inherit get_UIE_by_ID through a
			-- metatable, so a rawget would never resolve the real button.
			local ok_get, value = pcall(function()
				return ui.get_UIE_by_ID
			end)
			if ok_get then
				get_by_id = value
			end
		end
		if type(get_by_id) == "function" then
			local ok, element = pcall(get_by_id, ui, MPDriver.READY_ELEMENT_ID)
			if ok and type(element) == "table" then
				return element
			end
		end
		return nil
	end

	-- AI readiness through the real lobby ready callback. The callback toggles
	-- `MP.LOBBY.ready_to_start` and can bail on a version-mismatch modal, so
	-- success is only reported when the observable ready flag actually turned
	-- true. Late UI (element not mounted yet) is a bounded retry, and an
	-- already-ready lobby is an idempotent success that never double-toggles.
	function instance.ai_ready()
		if role ~= "ai" then
			return nil, CODE.WRONG_ROLE
		end
		if instance.lobby_code() == nil then
			return nil, CODE.BAD_STATE
		end
		if rpath(mp, "LOBBY", "ready_to_start") == true then
			return true, CODE.OK
		end
		if type(originals.lobby_ready_up) ~= "function" then
			return nil, CODE.MISSING_CALLBACK
		end
		local element = resolve_ready_element()
		if element == nil then
			return nil, CODE.MISSING_ELEMENT
		end
		local ok = pcall(originals.lobby_ready_up, element)
		if not ok then
			return nil, CODE.MISSING_CALLBACK
		end
		-- Version mismatch (or any early bail) leaves the flag false: report a
		-- bounded not-ready so the coordinator retries instead of pretending.
		if rpath(mp, "LOBBY", "ready_to_start") ~= true then
			return nil, CODE.NOT_READY
		end
		return true, CODE.OK
	end

	-- The real match-started observable (never "we called ready"). The guest
	-- learns it from the ordinary server start, the host from its own start
	-- callback; the decision loop is gated on this so it never polls the service
	-- before the match starts.
	function instance.is_started()
		return match_started()
	end

	-- Human start through the real lobby start callback, only once the guest is
	-- confirmed ready and the ruleset options are frozen.
	function instance.host_start_game()
		if role ~= "human" then
			return nil, CODE.WRONG_ROLE
		end
		if instance.lobby_code() == nil then
			return nil, CODE.BAD_STATE
		end
		if rpath(mp, "LOBBY", "ready_to_start") ~= true then
			return nil, CODE.NOT_READY
		end
		if rpath(mp, "LOBBY", "config") == nil then
			return nil, CODE.BAD_STATE
		end
		if instance.ruleset_ready() ~= true then
			return nil, CODE.BAD_STATE
		end
		if type(originals.lobby_start_game) ~= "function" then
			return nil, CODE.MISSING_CALLBACK
		end
		local ok = pcall(originals.lobby_start_game, nil)
		if not ok then
			return nil, CODE.MISSING_CALLBACK
		end
		started = true
		return true, CODE.OK
	end

	-- Leave/stop only the local staged session, through ordinary MP actions.
	function instance.leave_local()
		if type(actions) ~= "table" then
			return nil, CODE.MISSING_ACTION
		end
		if type(rget(actions, "leave_lobby")) == "function" then
			pcall(actions.leave_lobby)
		end
		return true, CODE.OK
	end

	function instance.stop_game()
		if type(actions) ~= "table" then
			return nil, CODE.MISSING_ACTION
		end
		if type(rget(actions, "stop_game")) == "function" then
			pcall(actions.stop_game)
		end
		return true, CODE.OK
	end

	-- Real protocol send allowlist. Default-deny: only the allowlisted
	-- coordination/gameplay actions pass, and the blocked/end-game/private set
	-- can never pass. Role/phase gates are enforced on top: the guest can never
	-- create a lobby or push lobby options, only the trusted human host may push
	-- options, and configuration is frozen once the match starts. Returns true
	-- when the action may be sent.
	function instance.guard_allows(action)
		if type(action) ~= "string" or #action == 0 then
			return false
		end
		if MPDriver.SEND_BLOCKED[action] == true then
			return false
		end
		if MPDriver.HOST_ONLY[action] == true or action == "lobbyOptions" then
			if not is_host_role() then
				return false
			end
			if action == "lobbyOptions" and match_started() then
				return false
			end
		end
		if MPDriver.GUEST_ONLY[action] == true and is_host_role() then
			return false
		end
		return MPDriver.SEND_ALLOWLIST[action] == true or action == "lobbyOptions"
	end

	-- Wrap Client.send with the allowlist. Returns an uninstall function that
	-- restores the exact original when still installed, or nil + code.
	function instance.install_send_guard()
		if installed_guard ~= nil then
			return nil, CODE.BAD_STATE
		end
		if type(client) ~= "table" or type(rget(client, "send")) ~= "function" then
			return nil, CODE.BAD_ENGINE
		end
		local original = client.send
		local function guarded(message)
			local action = nil
			if type(message) == "table" then
				action = rawget(message, "action")
			end
			if not instance.guard_allows(action) then
				emit({ event = "mp_driver", code = CODE.SEND_BLOCKED, action = token_of(action, TOKEN_PATTERN, MPDriver.LIMITS.max_token) })
				return false, CODE.SEND_BLOCKED
			end
			return original(message)
		end
		client.send = guarded
		installed_guard = { client = client, original = original, wrapped = guarded }
		return function()
			if installed_guard ~= nil and installed_guard.client.send == installed_guard.wrapped then
				installed_guard.client.send = installed_guard.original
				installed_guard = nil
				return true
			end
			return false
		end
	end

	function instance.uninstall()
		if installed_guard ~= nil then
			if installed_guard.client.send == installed_guard.wrapped then
				installed_guard.client.send = installed_guard.original
			end
			installed_guard = nil
		end
		return true, CODE.OK
	end

	function instance.describe()
		local ruleset = lookup_ruleset()
		return {
			role = role,
			ruleset_key = MPDriver.RULESET_KEY,
			ruleset_present = ruleset ~= nil,
			ruleset_ready = instance.ruleset_ready() == true,
			connected = instance.connected(),
			main_menu_ready = instance.main_menu_ready(),
			has_forced_keys = forced_keys ~= nil,
			has_hash = type(hash_string) == "function",
			ready_element_id = MPDriver.READY_ELEMENT_ID,
			ai_name = MPDriver.AI_NAME,
			has_lobby = instance.lobby_code() ~= nil,
			guard_installed = installed_guard ~= nil,
			codes = shallow_copy(CODE),
		}
	end

	instance.CODE = shallow_copy(CODE)
	instance.role = role
	return instance
end

return MPDriver
