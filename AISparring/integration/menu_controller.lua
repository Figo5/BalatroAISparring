-- AI Sparring main-menu controller.
--
-- Owns the Play-menu entry point and the trusted launcher transition. This
-- module builds no gameplay state, reads no engine globals, performs no process
-- IO and consumes no randomness. Every side effect is an injected port:
--
--   ui      : injected UI primitives + the live callback table + overlay hooks
--   menu    : an integration/ui/practice_menu.lua instance (widget builders)
--   host    : trusted launcher host (availability, authenticated start request,
--             nonblocking ack polling, injected normal quit, diagnostics path)
--   status  : trusted menu/run/lobby probe (plain booleans only)
--   clock   : monotonic time source
--
-- The controller sends ONLY validated selection enums/index to host.request_start
-- ({ mode, difficulty, pacing [, gauntlet_index] }). It never sends a seed: the
-- trusted host maps a gauntlet index to its stable seed. No gameplay, transport
-- or process-execution logic lives here; host.quit is the injected adapter that
-- triggers the game's normal quit path exactly once after a confirmed ack.

local MenuController = {}

local CODE = {
	OK = "menu_ok",
	BAD_PORTS = "menu_bad_ports",
	BAD_UI = "menu_bad_ui",
	BAD_HOST = "menu_bad_host",
	BAD_STATUS = "menu_bad_status",
	BAD_CLOCK = "menu_bad_clock",
	BAD_SELECTION = "menu_bad_selection",
	NOT_MAIN_MENU = "menu_not_main_menu",
	RUN_ACTIVE = "menu_run_active",
	MP_CONNECTED = "menu_mp_connected",
	INCOMPATIBLE_MP = "menu_incompatible_mp",
	LAUNCHER_UNAVAILABLE = "menu_launcher_unavailable",
	ALREADY_PENDING = "menu_already_pending",
	TIMEOUT = "menu_timeout",
	REJECTED = "menu_rejected",
	HOST_ERROR = "menu_host_error",
	QUIT_FAILED = "menu_quit_failed",
	INSTALL_FAILED = "menu_install_failed",
	INTERNAL = "menu_internal_error",
}

local MESSAGES = {
	[CODE.NOT_MAIN_MENU] = "AI Sparring practice can only be started from the main menu.",
	[CODE.RUN_ACTIVE] = "Finish or return from the current run before starting practice.",
	[CODE.MP_CONNECTED] = "Leave the current Multiplayer lobby before starting practice.",
	[CODE.INCOMPATIBLE_MP] = "AI Sparring needs a compatible Multiplayer install.",
	[CODE.LAUNCHER_UNAVAILABLE] = "AI Sparring could not find the practice launcher. Start the external launcher and try again.",
	[CODE.BAD_STATUS] = "AI Sparring could not read the current menu state.",
	[CODE.BAD_SELECTION] = "AI Sparring could not validate the selected settings.",
	[CODE.BAD_CLOCK] = "AI Sparring could not read the local clock.",
	[CODE.BAD_UI] = "AI Sparring could not build the practice menu.",
	[CODE.HOST_ERROR] = "AI Sparring could not reach the practice launcher.",
	[CODE.TIMEOUT] = "AI Sparring did not receive a launcher confirmation in time.",
	[CODE.REJECTED] = "The practice launcher rejected the start request.",
}

-- Screens that must not be dismissed with Esc (the engine reads `no_esc` only
-- from the overlay config, not from create_UIBox_generic_options).
local MODAL = { no_esc = true }

local LIMITS = {
	max_selection_copy_depth = 4,
	max_path = 240,
}

local ERROR_MESSAGE = "AI Sparring encountered an error. The match has been stopped. Diagnostics were written to the log."
local BUILDER_KEY = "override_main_menu_play_button"
local BUTTON_ID = "aisparring_play_button"
-- The launcher acknowledges only after its runtime preflight and start gate,
-- which re-hash the staged runtimes (about 40 s measured on the real staging
-- root). The menu must wait strictly longer, or it would always give up while
-- the launcher later accepts and waits for a live exit that never comes.
local ACK_TIMEOUT = 120
local GAUNTLET_COUNT = 5
local DEFAULT_SELECTION = { mode = "normal", difficulty = "competitive", pacing = "normal" }

local SELECTION_KEYS = {
	mode = true,
	difficulty = true,
	pacing = true,
	gauntlet_index = true,
}

MenuController.CODE = CODE
MenuController.LIMITS = LIMITS
MenuController.ERROR_MESSAGE = ERROR_MESSAGE
MenuController.BUILDER_KEY = BUILDER_KEY
MenuController.BUTTON_ID = BUTTON_ID
MenuController.BUTTON_TITLE = "AI Sparring"
MenuController.VERSION = "0.1.0-dev"
MenuController.BUTTON_LABEL = "AI Sparring 0.1.0-dev"
MenuController.ACK_TIMEOUT = ACK_TIMEOUT
MenuController.GAUNTLET_COUNT = GAUNTLET_COUNT
MenuController.MODES = { "normal", "gauntlet" }
MenuController.DIFFICULTIES = { "rookie", "competitive", "major_league" }
MenuController.PACINGS = { "instant", "normal" }
MenuController.RULESET = { id = "major_league", label = "Major League" }
MenuController.DEFAULT_SELECTION = { mode = "normal", difficulty = "competitive", pacing = "normal" }
MenuController.OPTIONS = {
	modes = {
		{ id = "normal", label = "Normal Match" },
		{ id = "gauntlet", label = "Gauntlet" },
	},
	difficulties = {
		{ id = "rookie", label = "Rookie" },
		{ id = "competitive", label = "Competitive" },
		{ id = "major_league", label = "Major League" },
	},
	pacings = {
		{ id = "instant", label = "Instant" },
		{ id = "normal", label = "Normal" },
	},
	gauntlet = {
		{ index = 1, label = "Test1" },
		{ index = 2, label = "Test2" },
		{ index = 3, label = "Test3" },
		{ index = 4, label = "Test4" },
		{ index = 5, label = "Test5" },
	},
}

local function is_plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_port_table(value)
	return type(value) == "table"
end

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

local function copy_plain(source, depth)
	depth = depth or 0
	local kind = type(source)
	if kind ~= "table" then
		if kind == "string" or kind == "number" or kind == "boolean" then
			return source
		end
		return nil
	end
	if depth > LIMITS.max_selection_copy_depth then
		return nil
	end
	local out = {}
	for key, value in next, source do
		local key_kind = type(key)
		if key_kind ~= "string" and key_kind ~= "number" then
			return nil
		end
		local copied = copy_plain(value, depth + 1)
		if copied ~= nil then
			out[key] = copied
		elseif type(value) ~= "table" then
			return nil
		end
	end
	return out
end

local function contains(list, value)
	for i = 1, #list do
		if list[i] == value then
			return true
		end
	end
	return false
end

local function is_gauntlet_index(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value % 1 ~= 0 then
		return false
	end
	return value >= 1 and value <= GAUNTLET_COUNT
end

local function sanitize_text(value, limit)
	if type(value) ~= "string" or #value == 0 then
		return nil
	end
	local out = {}
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte >= 32 and byte <= 126 then
			out[#out + 1] = string.char(byte)
		end
		if #out >= limit then
			break
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out)
end

local function copy_options()
	return copy_plain(MenuController.OPTIONS, 0) or {}
end

local function validate_selection(source)
	if not is_plain_table(source) then
		return nil, CODE.BAD_SELECTION
	end
	for key in next, source do
		if SELECTION_KEYS[key] ~= true then
			return nil, CODE.BAD_SELECTION
		end
	end
	local mode = source.mode
	if type(mode) ~= "string" or not contains(MenuController.MODES, mode) then
		return nil, CODE.BAD_SELECTION
	end
	local difficulty = source.difficulty
	if type(difficulty) ~= "string" or not contains(MenuController.DIFFICULTIES, difficulty) then
		return nil, CODE.BAD_SELECTION
	end
	local pacing = source.pacing
	if type(pacing) ~= "string" or not contains(MenuController.PACINGS, pacing) then
		return nil, CODE.BAD_SELECTION
	end
	local index = nil
	if mode == "gauntlet" then
		index = source.gauntlet_index
		if not is_gauntlet_index(index) then
			return nil, CODE.BAD_SELECTION
		end
	elseif source.gauntlet_index ~= nil then
		return nil, CODE.BAD_SELECTION
	end
	local payload = {
		mode = mode,
		difficulty = difficulty,
		pacing = pacing,
	}
	if index ~= nil then
		payload.gauntlet_index = index
	end
	return payload
end

function MenuController.factory(ports)
	if not is_port_table(ports) then
		return nil, CODE.BAD_PORTS
	end
	local ui = rawget(ports, "ui")
	if not is_port_table(ui)
		or not is_port_table(rawget(ui, "G"))
		or not is_port_table(rawget(ui, "funcs"))
		or type(rawget(ui, "UIBox_button")) ~= "function"
		or type(rawget(ui, "create_UIBox_generic_options")) ~= "function"
		or type(rawget(ui, "overlay_menu")) ~= "function"
		or type(rawget(ui, "exit_overlay_menu")) ~= "function" then
		return nil, CODE.BAD_UI
	end
	local menu = rawget(ports, "menu")
	if not is_port_table(menu)
		or type(rawget(menu, "settings_definition")) ~= "function"
		or type(rawget(menu, "confirm_definition")) ~= "function"
		or type(rawget(menu, "diagnostic_definition")) ~= "function"
		or type(rawget(menu, "error_definition")) ~= "function"
		or type(rawget(menu, "session_definition")) ~= "function" then
		return nil, CODE.BAD_UI
	end
	local host = rawget(ports, "host")
	if not is_port_table(host)
		or type(rawget(host, "available")) ~= "function"
		or type(rawget(host, "request_start")) ~= "function"
		or type(rawget(host, "poll_start")) ~= "function"
		or type(rawget(host, "quit")) ~= "function"
		or type(rawget(host, "diagnostics_path")) ~= "function" then
		return nil, CODE.BAD_HOST
	end
	local status = rawget(ports, "status")
	if not is_port_table(status) or type(rawget(status, "probe")) ~= "function" then
		return nil, CODE.BAD_STATUS
	end
	local clock = rawget(ports, "clock")
	if not is_port_table(clock) or type(rawget(clock, "now")) ~= "function" then
		return nil, CODE.BAD_CLOCK
	end

	local funcs = ui.funcs
	local instance = {}

	local installed = false
	local original_builder = nil
	local wrapped_builder = nil
	local registered = {}
	local selection = copy_plain(DEFAULT_SELECTION, 0) or {}
	local state = "idle"
	local failure_code = nil
	local pending_request = nil
	local pending_selection = nil
	local started_at = nil
	local quit_invoked = false
	local last_payload = nil

	local function read_probe()
		local ok, result = pcall(status.probe)
		if not ok or not is_plain_table(result) then
			return nil, CODE.BAD_STATUS
		end
		return result, CODE.OK
	end

	local function launcher_available()
		local ok, value = pcall(host.available)
		return ok == true and value == true
	end

	local function read_now()
		local ok, value = pcall(clock.now)
		if not ok or type(value) ~= "number" or value ~= value then
			return nil
		end
		return value
	end

	local function notify(level, message)
		if type(ui.notify) == "function" then
			pcall(ui.notify, level, message)
		end
	end

	-- The overlay object this controller opened last (engine UIBox, when the
	-- port exposes it), so uninstall can close only its own screen.
	local own_overlay = nil

	local function show(definition, config)
		if type(definition) ~= "table" then
			return false
		end
		local ok = pcall(ui.overlay_menu, definition, config)
		if ok ~= true then
			-- A failed build leaves no screen: never leave the game paused
			-- behind nothing, and tell the player.
			local settings = rawget(ui.G, "SETTINGS")
			if type(settings) == "table" then
				settings.paused = false
			end
			notify("error", MESSAGES[CODE.BAD_UI])
			return false
		end
		own_overlay = rawget(ui.G, "OVERLAY_MENU")
		return true
	end

	local function diagnostics_path()
		local ok, value = pcall(host.diagnostics_path)
		if not ok then
			return nil
		end
		return sanitize_text(value, LIMITS.max_path)
	end

	local function view_state()
		return {
			options = copy_options(),
			selection = copy_plain(selection, 0) or {},
			ruleset = shallow_copy(MenuController.RULESET),
		}
	end

	local function refuse(code)
		local message = MESSAGES[code] or "AI Sparring cannot start practice right now."
		local definition = menu.diagnostic_definition(message, diagnostics_path())
		show(definition, MODAL)
		notify("warn", message)
		return nil, code
	end

	local function fail(code)
		state = "failed"
		failure_code = code
		-- Release the host side too (L4): otherwise every later Start in this
		-- game session is refused as busy by a request nobody will poll again.
		if pending_request ~= nil and type(rawget(host, "abandon")) == "function" then
			pcall(host.abandon, pending_request)
		end
		pending_request = nil
		pending_selection = nil
		local definition = menu.error_definition(ERROR_MESSAGE, diagnostics_path())
		show(definition, MODAL)
		notify("error", ERROR_MESSAGE)
		return nil, code
	end

	local function contents_of(candidate)
		if type(candidate) ~= "table" then
			return nil
		end
		local root_nodes = candidate.nodes
		if type(root_nodes) ~= "table" then
			return nil
		end
		local outer = root_nodes[1]
		if type(outer) ~= "table" or type(outer.nodes) ~= "table" then
			return nil
		end
		local column = outer.nodes[1]
		if type(column) ~= "table" or type(column.nodes) ~= "table" then
			return nil
		end
		local contents_row = column.nodes[1]
		if type(contents_row) ~= "table" or type(contents_row.nodes) ~= "table" then
			return nil
		end
		return contents_row.nodes
	end

	local function append_node(contents, node)
		local max_index = 0
		for key in pairs(contents) do
			if type(key) == "number" and key > max_index then
				max_index = key
			end
		end
		contents[max_index + 1] = node
	end

	function instance.play_button_node()
		local palette = ui.G.C
		local colour = nil
		if is_port_table(palette) then
			colour = rawget(palette, "GOLD") or rawget(palette, "PURPLE") or rawget(palette, "BLUE")
		end
		local ok, node = pcall(ui.UIBox_button, {
			id = BUTTON_ID,
			label = { MenuController.BUTTON_TITLE, MenuController.VERSION },
			colour = colour,
			minw = 5,
			button = "aisp_open_menu",
		})
		if not ok or type(node) ~= "table" then
			return nil
		end
		return node
	end

	function instance.can_open()
		local probe, code = read_probe()
		if probe == nil then
			return nil, code
		end
		if probe.main_menu ~= true then
			return nil, CODE.NOT_MAIN_MENU
		end
		if probe.mp_compatible ~= true then
			return nil, CODE.INCOMPATIBLE_MP
		end
		if not launcher_available() then
			return nil, CODE.LAUNCHER_UNAVAILABLE
		end
		return true, CODE.OK
	end

	function instance.start_preconditions()
		local probe, code = read_probe()
		if probe == nil then
			return nil, code
		end
		if probe.main_menu ~= true then
			return nil, CODE.NOT_MAIN_MENU
		end
		if probe.active_run == true then
			return nil, CODE.RUN_ACTIVE
		end
		if probe.mp_connected == true then
			return nil, CODE.MP_CONNECTED
		end
		if probe.mp_compatible ~= true then
			return nil, CODE.INCOMPATIBLE_MP
		end
		return true, CODE.OK
	end

	function instance.decorate_play_menu(menu_definition)
		if type(menu_definition) ~= "table" then
			return menu_definition
		end
		local allowed = instance.can_open()
		if allowed ~= true then
			return menu_definition
		end
		local contents = contents_of(menu_definition)
		if contents == nil then
			return menu_definition
		end
		local node = instance.play_button_node()
		if node == nil then
			return menu_definition
		end
		append_node(contents, node)
		return menu_definition
	end

	local function register_callbacks()
		local defs = {
			aisp_open_menu = function()
				instance.open_settings()
			end,
			aisp_select = function(event)
				local id = nil
				if type(event) == "table" and type(event.config) == "table" then
					id = event.config.id
				end
				instance.handle_select(id)
			end,
			aisp_confirm_prompt = function()
				instance.open_confirm()
			end,
			aisp_confirm_cancel = function()
				instance.cancel_confirm()
			end,
			aisp_confirm_start = function()
				instance.confirm_start()
			end,
			aisp_close_overlay = function()
				pcall(ui.exit_overlay_menu)
			end,
			aisp_end_practice = function()
				instance.end_practice()
			end,
		}
		for name, handler in pairs(defs) do
			if registered[name] == nil then
				registered[name] = { had = funcs[name] ~= nil, previous = funcs[name] }
				funcs[name] = handler
			end
		end
	end

	local function unregister_callbacks()
		for name, record in pairs(registered) do
			if record.had then
				funcs[name] = record.previous
			else
				funcs[name] = nil
			end
		end
		registered = {}
	end

	function instance.install()
		if installed then
			return true, CODE.OK
		end
		local uidf = ui.G.UIDEF
		if not is_port_table(uidf) then
			return nil, CODE.INSTALL_FAILED
		end
		local existing = rawget(uidf, BUILDER_KEY)
		if type(existing) ~= "function" then
			return nil, CODE.INSTALL_FAILED
		end
		original_builder = existing
		local function wrapped()
			local result = original_builder()
			if not installed then
				return result
			end
			return instance.decorate_play_menu(result)
		end
		wrapped_builder = wrapped
		uidf[BUILDER_KEY] = wrapped
		installed = true
		register_callbacks()
		return true, CODE.OK
	end

	function instance.uninstall()
		-- Close our own screen first: its buttons name callbacks that are about
		-- to be unregistered, and the engine calls G.FUNCS[button] unchecked.
		if own_overlay ~= nil and rawequal(rawget(ui.G, "OVERLAY_MENU"), own_overlay) then
			pcall(ui.exit_overlay_menu)
		end
		own_overlay = nil
		if wrapped_builder ~= nil and ui.G.UIDEF[BUILDER_KEY] == wrapped_builder then
			ui.G.UIDEF[BUILDER_KEY] = original_builder
		end
		unregister_callbacks()
		installed = false
		original_builder = nil
		wrapped_builder = nil
		instance.reset()
		return true, CODE.OK
	end

	function instance.reset()
		state = "idle"
		failure_code = nil
		pending_request = nil
		pending_selection = nil
		started_at = nil
		quit_invoked = false
		last_payload = nil
		return true, CODE.OK
	end

	function instance.refresh_overlay()
		local definition = menu.settings_definition(view_state())
		if definition == nil then
			return refuse(CODE.BAD_UI)
		end
		show(definition)
		return true, CODE.OK
	end

	function instance.open_settings()
		local allowed, code = instance.can_open()
		if allowed ~= true then
			if code == CODE.LAUNCHER_UNAVAILABLE then
				local definition = menu.diagnostic_definition(MESSAGES[code], diagnostics_path())
				show(definition, MODAL)
				notify("warn", MESSAGES[code])
				return nil, code
			end
			return refuse(code)
		end
		return instance.refresh_overlay()
	end

	function instance.handle_select(id)
		if type(id) ~= "string" then
			return nil, CODE.BAD_SELECTION
		end
		local namespace, value = string.match(id, "^aisp:([a-z_]+):(.+)$")
		if namespace == nil then
			return nil, CODE.BAD_SELECTION
		end
		if namespace == "mode" then
			if not contains(MenuController.MODES, value) then
				return nil, CODE.BAD_SELECTION
			end
			selection.mode = value
			if value == "gauntlet" then
				if not is_gauntlet_index(selection.gauntlet_index) then
					selection.gauntlet_index = 1
				end
			else
				selection.gauntlet_index = nil
			end
		elseif namespace == "difficulty" then
			if not contains(MenuController.DIFFICULTIES, value) then
				return nil, CODE.BAD_SELECTION
			end
			selection.difficulty = value
		elseif namespace == "pacing" then
			if not contains(MenuController.PACINGS, value) then
				return nil, CODE.BAD_SELECTION
			end
			selection.pacing = value
		elseif namespace == "gauntlet" then
			if selection.mode ~= "gauntlet" then
				return nil, CODE.BAD_SELECTION
			end
			local index = tonumber(value)
			if not is_gauntlet_index(index) then
				return nil, CODE.BAD_SELECTION
			end
			selection.gauntlet_index = index
		else
			return nil, CODE.BAD_SELECTION
		end
		instance.refresh_overlay()
		return true, CODE.OK
	end

	function instance.open_confirm()
		local payload, code = validate_selection(selection)
		if payload == nil then
			return refuse(CODE.BAD_SELECTION)
		end
		pending_selection = payload
		local definition = menu.confirm_definition(view_state())
		if definition == nil then
			return refuse(CODE.BAD_UI)
		end
		show(definition, MODAL)
		return true, CODE.OK
	end

	function instance.cancel_confirm()
		pending_selection = nil
		pcall(ui.exit_overlay_menu)
		return true, CODE.OK
	end

	function instance.confirm_start()
		if state == "awaiting_ack" then
			return nil, CODE.ALREADY_PENDING
		end
		local payload, code = validate_selection(selection)
		if payload == nil then
			return refuse(CODE.BAD_SELECTION)
		end
		local allowed, reason = instance.start_preconditions()
		if allowed ~= true then
			return refuse(reason)
		end
		if not launcher_available() then
			local definition = menu.diagnostic_definition(MESSAGES[CODE.LAUNCHER_UNAVAILABLE], diagnostics_path())
			show(definition, MODAL)
			notify("warn", MESSAGES[CODE.LAUNCHER_UNAVAILABLE])
			return nil, CODE.LAUNCHER_UNAVAILABLE
		end
		local now = read_now()
		if now == nil then
			return fail(CODE.BAD_CLOCK)
		end
		local ok_call, request_id = pcall(host.request_start, payload)
		if not ok_call or type(request_id) ~= "string" or #request_id == 0 then
			return fail(CODE.HOST_ERROR)
		end
		last_payload = copy_plain(payload, 0) or payload
		pending_selection = nil
		pending_request = request_id
		started_at = now
		state = "awaiting_ack"
		-- Keep a modal "starting" screen up while the launcher runs its gates, so
		-- no run can be started underneath. It is never closed before the quit,
		-- so no settings save is queued that the quit could race.
		local waiting = type(rawget(menu, "waiting_definition")) == "function"
			and menu.waiting_definition(view_state()) or nil
		if waiting == nil or not show(waiting, MODAL) then
			pcall(ui.exit_overlay_menu)
		end
		return true, CODE.OK
	end

	function instance.quit_once()
		if quit_invoked then
			return true
		end
		quit_invoked = true
		-- The host adapter reports `false` when the real quit did not run; the
		-- modal waiting screen must then be replaced by a closable error screen.
		local ok, done = pcall(host.quit)
		if not ok or done ~= true then
			state = "failed"
			failure_code = CODE.QUIT_FAILED
			local definition = menu.error_definition(ERROR_MESSAGE, diagnostics_path())
			show(definition, MODAL)
			notify("error", ERROR_MESSAGE)
			return false
		end
		return true
	end

	function instance.update(now)
		if state ~= "awaiting_ack" then
			return state, CODE.OK
		end
		if type(now) ~= "number" then
			now = read_now()
		end
		if now == nil then
			fail(CODE.BAD_CLOCK)
			return "failed", CODE.BAD_CLOCK
		end
		if now - started_at > ACK_TIMEOUT then
			fail(CODE.TIMEOUT)
			return "failed", CODE.TIMEOUT
		end
		local ok_poll, response = pcall(host.poll_start, pending_request)
		if not ok_poll then
			fail(CODE.HOST_ERROR)
			return "failed", CODE.HOST_ERROR
		end
		if response == nil then
			return "awaiting_ack", CODE.OK
		end
		if not is_plain_table(response) then
			fail(CODE.HOST_ERROR)
			return "failed", CODE.HOST_ERROR
		end
		local outcome = response.status
		if outcome == "pending" then
			return "awaiting_ack", CODE.OK
		end
		if outcome == "ok" then
			pending_request = nil
			-- The launcher accepted after its gates; the game must still be on the
			-- main menu with no run, or quitting would lose the player's progress.
			local still_ok, reason = instance.start_preconditions()
			if still_ok ~= true then
				state = "failed"
				failure_code = reason
				refuse(reason)
				return "failed", reason
			end
			state = "quitting"
			if not instance.quit_once() then
				return "failed", CODE.QUIT_FAILED
			end
			return "quitting", CODE.OK
		end
		if outcome == "rejected" then
			fail(CODE.REJECTED)
			return "failed", CODE.REJECTED
		end
		fail(CODE.HOST_ERROR)
		return "failed", CODE.HOST_ERROR
	end

	function instance.end_practice()
		if type(rawget(host, "request_end")) == "function" then
			local ok, accepted = pcall(host.request_end, "user_return")
			if not ok or accepted ~= true then
				return fail(CODE.HOST_ERROR)
			end
		end
		pcall(ui.exit_overlay_menu)
		return true, CODE.OK
	end

	function instance.selection()
		return copy_plain(selection, 0) or {}
	end

	function instance.last_request()
		if last_payload == nil then
			return nil
		end
		return copy_plain(last_payload, 0)
	end

	function instance.state()
		return state
	end

	function instance.describe()
		return {
			installed = installed,
			state = state,
			failure_code = failure_code,
			has_pending = pending_request ~= nil,
			quit_invoked = quit_invoked,
			selection = copy_plain(selection, 0) or {},
			codes = shallow_copy(CODE),
		}
	end

	instance.CODE = CODE
	instance.LIMITS = LIMITS
	instance.ERROR_MESSAGE = ERROR_MESSAGE
	return instance
end

return MenuController
