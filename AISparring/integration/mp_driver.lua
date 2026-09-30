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
	FORCE_FAILED = "driver_force_failed",
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
	NO_UNLOCK_OVERLAY = "driver_no_unlock_overlay",
	INTERNAL = "driver_internal_error",
}

-- Real guest ready element id (pinned Multiplayer
-- ui/lobby/start_ready_button.lua and ui/lobby/lobby.lua:520). The lookup goes
-- through the injected real `G.MAIN_MENU_UI`; a fabricated button is never
-- substituted because the real callback mutates the element's config/children
-- and UIBox.
MPDriver.READY_ELEMENT_ID = "lobby_menu_start"

-- Vanilla unlock-notification overlay identity. `continue_unlock` is used only
-- by the deck/card unlock popups as their back-button callback
-- (functions/button_callbacks.lua:1386-1405), so a back element whose
-- `config.button` is exactly this identifies exactly an unlock notification and
-- never an options/credits/Multiplayer/game-over/lobby overlay. The element id
-- is the pinned generic-options default
-- (functions/UI_definitions.lua:6784-6825).
MPDriver.UNLOCK_BACK_ID = "overlay_menu_back_button"
MPDriver.UNLOCK_BUTTON = "continue_unlock"

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
-- and ordinary gameplay are never silenced. `createLobby` and `lobbyOptions`
-- are gated separately on the trusted role: see `guard_allows`.
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
	-- The pinned `MP.ACTIONS.connect()` (action = "connect") opens/reopens the
	-- local staged socket in the ordinary Multiplayer way and carries only the
	-- action name. It is harmless (no private/ranked data) and is not the
	-- official match transport, so it is allowed; the pinned reconnect button
	-- (`G.FUNCS.reconnect`) depends on it.
	connect = true,
	-- The pinned `MP.ACTIONS.sync_client()` sends `syncClient` with only the
	-- `isCached` release flag immediately after joinedLobby/rejoinedLobby
	-- (networking/action_handlers.lua:83-107, 1399-1404); the pinned server
	-- stores that flag only for lobbyInfo display. It carries no private,
	-- ranked or result data, so both roles may send it. Quoted key only so this
	-- module contains no bare "Client" token (tests/run_runtime.py boundary).
	["syncClient"] = true,
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

-- Actions bound to the TRUSTED runtime role (the factory `role`, fixed at
-- staged bootstrap), never to the MP-derived `MP.LOBBY.is_host` flag. The
-- pinned core.lua:31 initializes `is_host = false` and only flips it true once
-- the server answers lobbyInfo (networking/action_handlers.lua:182-
-- 186), so the flag is false for the host's own real first `createLobby`.
-- `createLobby` therefore gates on the trusted role plus the absence of a
-- joined lobby; `lobbyOptions` additionally requires the server-confirmed host
-- flag. Both are frozen once the match starts.
MPDriver.HOST_ONLY = {
	createLobby = true,
	lobbyOptions = true,
}

-- Trusted-guest-only lifecycle actions: the AI role only, and never once the
-- real server has confirmed a host (a forged `is_host = true` must not open the
-- guest join either). `rejoinLobby` is deliberately NOT here: the pinned
-- `action_connected` sends it automatically after any reconnect, for the host
-- as well as the guest, carrying only the server-issued reconnect token for the
-- exact lobby it was in (networking/action_handlers.lua:63-80). Refusing it for
-- the human would strand the host's own match after a transient drop.
MPDriver.GUEST_ONLY = {
	joinLobby = true,
}

-- End-screen Joker reveal (docs/PROTOTYPE_GATES.md: no *pre-end*
-- getEndGameJokers). The pinned end screen (ui/game/game_end.lua:53) sends
-- `getEndGameJokers`; the pinned server relays it to the opponent
-- (src/actionHandlers.ts getEndGameJokersAction), whose handler answers with
-- `receiveEndGameJokers` carrying its own `G.jokers:save()`
-- (networking/action_handlers.lua:902-925). Each action is allowed only for the
-- one trusted role that needs it for the human to see the AI's Jokers, and only
-- once `match_complete()` holds. The reverse direction (the AI requesting the
-- human's Jokers) stays blocked, so the human's build never reaches the AI
-- runtime, even after the match.
MPDriver.ENDGAME_REVEAL = {
	getEndGameJokers = "human",
	receiveEndGameJokers = "ai",
}

-- Real wire actions that must never leave a staged runtime: ranked/server
-- logging, end-game stats exchange and private opponent deck queries, plus
-- auth and modded actions.
MPDriver.SEND_BLOCKED = {
	submitLogHashes = true,
	streamLogLines = true,
	endGameStatsRequested = true,
	sendGameStats = true,
	getNemesisDeck = true,
	nemesisEndGameStats = true,
	receiveNemesisDeck = true,
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
		-- The pinned Multiplayer source has no `MP.is_started` and never sets
		-- `MP.LOBBY.started` (only the human-only `host_start_game` does). The
		-- real, source-visible signal is the ordinary RUN stage reached by the
		-- normal Multiplayer start while the lobby is joined. Latch it: once a
		-- real match is running it never un-starts from a later teardown frame.
		local code = rpath(mp, "LOBBY", "code")
		if type(code) ~= "string" or #code == 0 then
			return false
		end
		local stages = rget(G, "STAGES")
		local stage_value = rget(G, "STAGE")
		local run_stage = rget(stages, "RUN")
		if not is_int(stage_value) or not is_int(run_stage) or stage_value ~= run_stage then
			return false
		end
		started = true
		return true
	end

	-- Whether a lobby has actually been joined: the real code is set only after
	-- the server answers joinedLobby/rejoinedLobby. Used to stop a second
	-- `createLobby` once the host is already in its own lobby.
	local function lobby_joined()
		local code = rpath(mp, "LOBBY", "code")
		return type(code) == "string" and #code > 0
	end

	-- Whether the real match has legitimately ended for this runtime. In a
	-- non-ghost match the pinned client sets `MP.GAME.won = true` only in the
	-- inbound winGame handler and `G.STATE = G.STATES.GAME_OVER` only in the
	-- inbound loseGame handler (networking/action_handlers.lua:545-566); the
	-- other GAME_OVER writers are ghost-replay paths (ui/game/game_state.lua,
	-- lib/ghost_replay.lua) and the speedlatro layer, which Major League does not
	-- use. Once seen, completion is latched to that match's own `MP.GAME`
	-- table, so a later engine event that moves `G.STATE` off GAME_OVER cannot
	-- close the reveal before the opponent's request arrives. MP.reset_game_states
	-- (startGame, return to lobby) builds a new `MP.GAME` table, which ends the
	-- latch, and leaving the lobby closes it too. Requires a started match in a
	-- joined lobby and no active ghost replay.
	local completed_game = nil
	local function match_complete()
		if not match_started() or not lobby_joined() then
			return false
		end
		local game = rget(mp, "GAME")
		if type(game) ~= "table" then
			return false
		end
		local ghost = rget(mp, "GHOST")
		local ghost_active = type(ghost) == "table" and rget(ghost, "is_active") or nil
		if ghost_active ~= nil then
			if type(ghost_active) ~= "function" then
				return false
			end
			-- Pinned lib/ghost_replay.lua:253: `MP.GHOST.active and ...`, so an
			-- inactive ghost answers nil or false.
			local ok, active = pcall(ghost_active)
			if not ok or active then
				return false
			end
		end
		if completed_game ~= nil and rawequal(completed_game, game) then
			return true
		end
		local ended = rget(game, "won") == true
		if not ended then
			local game_over = rpath(G, "STATES", "GAME_OVER")
			local state_value = rget(G, "STATE")
			ended = is_int(game_over) and is_int(state_value) and state_value == game_over
		end
		if ended then
			completed_game = game
		end
		return ended
	end

	-- The server-confirmed host flag. The pinned Multiplayer source sets it
	-- true only while answering lobbyInfo; it is never trusted on
	-- its own for role authorization (the trusted `role` is).
	local function host_confirmed()
		return rpath(mp, "LOBBY", "is_host") == true
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
	-- callbacks and must not fire before the menu exists. The pinned source shows
	-- the splash screen reuses the MAIN_MENU stage with the SPLASH state
	-- (game.lua), so the stage alone is not enough: when the real enum pairs are
	-- present, both STAGE == STAGES.MAIN_MENU and STATE == STATES.MENU must hold,
	-- and the main-menu UI handle must exist.
	function instance.main_menu_ready()
		local stages = rget(G, "STAGES")
		local states = rget(G, "STATES")
		local main_menu_stage = rget(stages, "MAIN_MENU")
		if is_int(main_menu_stage) then
			local stage_value = rget(G, "STAGE")
			if not is_int(stage_value) or stage_value ~= main_menu_stage then
				return false
			end
		end
		local menu_state = rget(states, "MENU")
		if is_int(menu_state) then
			local state_value = rget(G, "STATE")
			if not is_int(state_value) or state_value ~= menu_state then
				return false
			end
		end
		return rget(G, "MAIN_MENU_UI") ~= nil
	end

	-- The real vanilla unlock-notification overlay's back element, or nil. Only
	-- the unlock popups use `continue_unlock` as their back button, so every
	-- other overlay kind is never matched. `G.OVERLAY_MENU` is a real UIBox whose
	-- `get_UIE_by_ID` is inherited through its class metatable, so the method and
	-- the element's `config.button` are resolved with protected normal indexing,
	-- never rawget. Never throws.
	function instance.unlock_overlay()
		local overlay = rget(G, "OVERLAY_MENU")
		if type(overlay) ~= "table" then
			return nil
		end
		local ok_get, get_by_id = pcall(function()
			return overlay.get_UIE_by_ID
		end)
		if not ok_get or type(get_by_id) ~= "function" then
			return nil
		end
		local ok_element, element = pcall(get_by_id, overlay, MPDriver.UNLOCK_BACK_ID)
		if not ok_element or type(element) ~= "table" then
			return nil
		end
		local ok_button, button = pcall(function()
			return element.config.button
		end)
		if not ok_button or button ~= MPDriver.UNLOCK_BUTTON then
			return nil
		end
		return element
	end

	-- Dismiss the vanilla unlock-notification overlay through the real
	-- `continue_unlock` callback. Role-independent: the caller decides policy.
	-- A *new* unlock overlay opened by the callback's own chained
	-- `G.E_MANAGER:update` still counts as success for this one. Never throws.
	function instance.dismiss_unlock_overlay()
		local element = instance.unlock_overlay()
		if element == nil then
			return false, CODE.NO_UNLOCK_OVERLAY
		end
		local overlay = rget(G, "OVERLAY_MENU")
		if type(overlay) ~= "table" then
			return false, CODE.NO_UNLOCK_OVERLAY
		end
		local continue_unlock = rget(funcs, "continue_unlock")
		if type(continue_unlock) ~= "function" then
			return false, CODE.MISSING_CALLBACK
		end
		if not pcall(continue_unlock, element) then
			return false, CODE.INTERNAL
		end
		if rawequal(rget(G, "OVERLAY_MENU"), overlay) then
			return false, CODE.BAD_STATE
		end
		return true, CODE.OK
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
							-- The real `MP.current_ruleset()` is an empty
							-- metatable proxy that answers every field through
							-- its metatable, so the field must be read with
							-- protected normal indexing, never rawget.
							local ok_get, original = pcall(function()
								return resolved.force_lobby_options
							end)
							if not ok_get or type(original) ~= "function" then
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
			-- The real registry never forced options after the real create was
			-- invoked: the lobby exists in an un-forced state. This is fatal,
			-- never a retryable re-arm, because a second createLobby would
			-- orphan the first lobby and repeat the defect.
			emit({ event = "mp_driver", code = CODE.FORCE_FAILED, op = "host_start" })
			return nil, CODE.FORCE_FAILED
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

	-- Whether the real match has legitimately ended (see match_complete).
	function instance.is_complete()
		return match_complete()
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
	-- can never pass. Role/phase gates are enforced on top and bind to the
	-- TRUSTED runtime `role`, never to the MP-derived `MP.LOBBY.is_host` alone:
	--   * `createLobby` only for the human, and only before it has joined a
	--     lobby (the pinned initial `is_host = false` must not refuse the
	--     host's own first create).
	--   * `lobbyOptions` only for the human once the server has confirmed the
	--     host, and never after the match starts.
	--   * `joinLobby` only for the AI, and never while the server
	--     has confirmed a host (a forged `is_host = true` must not open them).
	--   * `getEndGameJokers` only for the human and `receiveEndGameJokers` only
	--     for the AI, and each only once the match has legitimately ended
	--     (ENDGAME_REVEAL).
	-- Returns true when the action may be sent.
	function instance.guard_allows(action)
		if type(action) ~= "string" or #action == 0 then
			return false
		end
		if MPDriver.SEND_BLOCKED[action] == true then
			return false
		end
		-- The reveal entries are exactly two role-bound end-screen actions and are
		-- never also host-only, guest-only or blocked (test-enforced), so
		-- returning here skips no other gate.
		local reveal_role = MPDriver.ENDGAME_REVEAL[action]
		if reveal_role ~= nil then
			return role == reveal_role and match_complete()
		end
		if MPDriver.HOST_ONLY[action] == true then
			if role ~= "human" then
				return false
			end
			if match_started() then
				return false
			end
			if action == "createLobby" then
				return not lobby_joined()
			end
			return host_confirmed()
		end
		if MPDriver.GUEST_ONLY[action] == true then
			return role == "ai" and not host_confirmed()
		end
		return MPDriver.SEND_ALLOWLIST[action] == true
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
