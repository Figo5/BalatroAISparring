-- AI Sparring companion host.
--
-- Single trusted adapter that turns the game's real globals into either of the
-- two supported companion configurations, selected by install-time config:
--
--   * live   -- the installed menu companion. Builds `host` (available /
--               request_start / poll_start / quit / diagnostics_path) and the
--               status probe the reviewed menu controller expects, validates the
--               fixed practice-host discovery marker, binds the current process
--               identity, and talks to the already-running external host over a
--               loopback-only bounded channel. It never launches a process,
--               never runs a shell command and never mutates Multiplayer
--               transport.
--
--   * staged -- a staged role copy. Reads only the strict launcher environment
--               descriptors, cross-checks the independently written launcher
--               attestation, then invokes the trusted RuntimeBootstrap with the
--               real G/MP/SMODS/love modules. The AI role additionally supplies
--               the policy/executor module set; the human role never does.
--
-- It also owns the `Game:update` chain wrapper (original called exactly once,
-- then the bounded companion step) and the load-time-inert module boundary.
--
-- Everything is an injected port: loading this file performs no work, touches no
-- global and opens nothing. The privileged defaults (Lovely NFS read adapter,
-- Windows identity query, LÖVE thread transport) are constructed only when the
-- corresponding port is absent, and each fails closed. Credentials, sessions,
-- control secrets and seeds are never logged and never placed on a status
-- surface. See docs/COMPANION_BOOTSTRAP.md and docs/PRACTICE_SERVICE.md.

local CompanionHost = {}

CompanionHost.VERSION = "aisp-companion-host/1"

CompanionHost.DISCOVERY_SCHEMA = "aisparring.practice_host.discovery.v1"
CompanionHost.HOST_VERSION = "practice_host/1"
CompanionHost.REQUEST_SCHEMA = "aisparring.practice_host.request.v1"
CompanionHost.ATTESTATION_SCHEMA = "aisparring.launcher_attestation.v1"
CompanionHost.HOST = "127.0.0.1"
CompanionHost.START_ACCEPTED = "practice_host_start_accepted"

-- Staged-window identification. The human and AI runtimes are separate LÖVE
-- processes; the titles below make which is which obvious to the player, and
-- the AI window is minimized once so the bot's hand is not the default
-- foreground view. UI identification only: focus, timers, update loops and
-- gameplay are never touched, and the window object is never handed to policy.
CompanionHost.WINDOW = {
	human_title = "Balatro AI Sparring 0.1.0-dev - Player",
	ai_title = "Balatro AI Sparring 0.1.0-dev - AI runtime",
}

-- Canonical session-descriptor names, frozen to the typed launcher descriptor
-- and staging.role_environment (docs/PLAYABLE_WIRING_CONTRACT.md). There are no
-- speculative aliases. The role comes from BALATRO_AI_ROLE; the mod root is
-- derived from the expected role Mods root, never read from the environment.
CompanionHost.ENV = {
	ROLE = "BALATRO_AI_ROLE",
	SESSION = "AISP_SESSION_ID",
	CREDENTIAL = "AISP_ROLE_CREDENTIAL",
	NONCE = "AISP_PROBE_NONCE",
	CONTENT_HASH = "AISP_CONTENT_HASH",
	CONTROL_PORT = "AISP_CONTROL_PORT",
	SAVE_ROOT = "AISP_EXPECTED_ROLE_SAVE_ROOT",
	MODS_ROOT = "AISP_EXPECTED_ROLE_MODS_ROOT",
	MODE = "AISP_MODE",
	DIFFICULTY = "AISP_DIFFICULTY",
	PACING = "AISP_PACING",
	GAUNTLET = "AISP_GAUNTLET",
}

CompanionHost.ENUMS = {
	difficulty = { "rookie", "competitive", "major_league" },
	pacing = { "instant", "normal" },
	mode = { "normal", "gauntlet" },
	gauntlet = { "Test1", "Test2", "Test3", "Test4", "Test5" },
}

CompanionHost.CODE = {
	OK = "companion_ok",
	BAD_PORTS = "companion_bad_ports",
	INTERNAL = "companion_internal_error",
	UNSUPPORTED_ROLE = "companion_unsupported_role",
	LIVE_ENV_MISSING = "companion_live_env_missing",
	MARKER_ABSENT = "companion_marker_absent",
	MARKER_UNREADABLE = "companion_marker_unreadable",
	MARKER_SCHEMA = "companion_marker_schema_mismatch",
	MARKER_VERSION = "companion_marker_version_mismatch",
	MARKER_HOST = "companion_marker_host_invalid",
	MARKER_PORT = "companion_marker_port_invalid",
	MARKER_SECRET = "companion_marker_secret_invalid",
	MARKER_SESSION = "companion_marker_session_invalid",
	MARKER_OPS = "companion_marker_ops_missing",
	MARKER_ENUMS = "companion_marker_enums_mismatch",
	MARKER_IDENTITY = "companion_marker_identity_invalid",
	IDENTITY_UNAVAILABLE = "companion_identity_unavailable",
	IDENTITY_STALE = "companion_identity_stale",
	TRANSPORT_UNAVAILABLE = "companion_transport_unavailable",
	TRANSPORT_ERROR = "companion_transport_error",
	ENCODE_FAILED = "companion_encode_failed",
	BUSY = "companion_busy",
	NOT_AVAILABLE = "companion_host_not_available",
	BAD_SELECTION = "companion_bad_selection",
	JSON_NULL_UNSUPPORTED = "companion_json_null_unsupported",
	BAD_WIRE = "companion_bad_wire",
	BAD_UI = "companion_bad_ui",
	MENU_FAILED = "companion_menu_failed",
	NO_UPDATE_HOST = "companion_no_update_host",
	STAGED_ENV_MISSING = "companion_staged_env_missing",
	STAGED_ENV_BAD = "companion_staged_env_bad",
	STAGED_ROLE_CROSSED = "companion_staged_role_crossed",
	STAGED_ATTESTATION_MISSING = "companion_staged_attestation_missing",
	STAGED_ATTESTATION_UNVERIFIED = "companion_staged_attestation_unverified",
	STAGED_ATTESTATION_PATH = "companion_staged_attestation_path_mismatch",
	STAGED_ATTESTATION_TIMEOUT = "companion_staged_attestation_timeout",
	STAGED_AWAITING_ATTESTATION = "companion_staged_awaiting_attestation",
	STAGED_BOOTSTRAP_FAILED = "companion_staged_bootstrap_failed",
	WINDOW_UNAVAILABLE = "companion_window_unavailable",
	WINDOW_FAILED = "companion_window_failed",
}

CompanionHost.LIMITS = {
	max_token = 128,
	max_nonce = 32,
	max_hash = 128,
	max_path = 512,
	min_secret = 32,
	max_secret = 128,
	max_send = 2097152,
	max_receive = 65536,
	max_drain = 32,
	max_req_id = 32,
	max_update_errors = 5,
	identity_tolerance = 2.0,
	attestation_timeout = 30.0,
	attestation_file = "aisparring-launcher-attestation.json",
}

local CODE = CompanionHost.CODE
local LIMITS = CompanionHost.LIMITS
local ENV = CompanionHost.ENV
local ENUMS = CompanionHost.ENUMS

local TOKEN_PATTERN = "^[0-9A-Za-z][0-9A-Za-z_.:-]*$"
local NONCE_PATTERN = "^[0-9A-Za-z_]+$"
local HASH_PATTERN = "^[0-9A-Za-z]+$"
local SECRET_PATTERN = "^[0-9a-fA-F]+$"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function rget(obj, key)
	if type(obj) ~= "table" or key == nil then
		return nil
	end
	return rawget(obj, key)
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
	return true
end

local function bounded_string(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	return value
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

local function secret_of(value)
	local bounded = token_of(value, SECRET_PATTERN, LIMITS.max_secret)
	if bounded == nil or #bounded < LIMITS.min_secret then
		return nil
	end
	return bounded
end

local function path_of(value)
	local bounded = bounded_string(value, LIMITS.max_path)
	if bounded == nil then
		return nil
	end
	if string.find(bounded, "%c") ~= nil then
		return nil
	end
	return bounded
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

local function contains(list, value)
	if type(list) ~= "table" then
		return false
	end
	for i = 1, #list do
		if list[i] == value then
			return true
		end
	end
	return false
end

local function same_set(list, expected)
	if type(list) ~= "table" or type(expected) ~= "table" then
		return false
	end
	local count = 0
	for key, value in next, list do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
		if not contains(expected, value) then
			return false
		end
	end
	return count == #expected
end

local function path_directory(path)
	local dir = string.match(path, "^(.*)[/\\][^/\\]*$")
	if dir == nil or #dir == 0 then
		return nil
	end
	return dir
end

local function path_join(directory, name)
	if type(directory) ~= "string" or type(name) ~= "string" then
		return nil
	end
	local trimmed = string.gsub(directory, "[/\\]+$", "")
	if #trimmed == 0 then
		return nil
	end
	return trimmed .. "/" .. name
end

-- Case-insensitive, slash-normalized comparison form for a path.
local function normalize_path(value)
	if type(value) ~= "string" or #value == 0 then
		return nil
	end
	local normalized = string.lower(value)
	normalized = string.gsub(normalized, "\\", "/")
	normalized = string.gsub(normalized, "/+", "/")
	if #normalized > 1 then
		normalized = string.gsub(normalized, "/$", "")
	end
	if #normalized == 0 then
		return nil
	end
	return normalized
end

-- ---------------------------------------------------------------------------
-- discovery marker validation (live role)
-- ---------------------------------------------------------------------------

-- Validate a decoded practice-host discovery marker against the actual schema
-- and the independently queried process identity. `identity` must expose
-- `process(pid) -> { create_time }`. Nothing here trusts a network value: the
-- marker is read from the fixed install-time path and re-checked against the
-- live process.
function CompanionHost.inspect_marker(marker, identity)
	if not is_plain(marker) then
		return nil, CODE.MARKER_ABSENT
	end
	if rawget(marker, "schema") ~= CompanionHost.DISCOVERY_SCHEMA then
		return nil, CODE.MARKER_SCHEMA
	end
	if rawget(marker, "version") ~= CompanionHost.HOST_VERSION then
		return nil, CODE.MARKER_VERSION
	end
	if rawget(marker, "host") ~= CompanionHost.HOST then
		return nil, CODE.MARKER_HOST
	end
	local port = rawget(marker, "port")
	if not is_int(port) or port < 1 or port > 65535 then
		return nil, CODE.MARKER_PORT
	end
	local secret = secret_of(rawget(marker, "secret"))
	if secret == nil then
		return nil, CODE.MARKER_SECRET
	end
	local session = token_of(rawget(marker, "session"), TOKEN_PATTERN, LIMITS.max_token)
	if session == nil then
		return nil, CODE.MARKER_SESSION
	end
	local pid = rawget(marker, "pid")
	local created = rawget(marker, "create_time")
	if not is_int(pid) or pid < 1 or type(created) ~= "number" or created ~= created then
		return nil, CODE.MARKER_IDENTITY
	end
	local ops = rawget(marker, "ops")
	if not contains(ops, "start") or not contains(ops, "poll") then
		return nil, CODE.MARKER_OPS
	end
	local enums = rawget(marker, "enums")
	if not is_plain(enums)
		or not same_set(rawget(enums, "difficulty"), ENUMS.difficulty)
		or not same_set(rawget(enums, "pacing"), ENUMS.pacing)
		or not same_set(rawget(enums, "mode"), ENUMS.mode)
		or not same_set(rawget(enums, "gauntlet"), ENUMS.gauntlet) then
		return nil, CODE.MARKER_ENUMS
	end
	if type(identity) ~= "table" or type(rawget(identity, "process")) ~= "function" then
		return nil, CODE.IDENTITY_UNAVAILABLE
	end
	local ok_live, live = pcall(identity.process, pid)
	if not ok_live or type(live) ~= "table" then
		return nil, CODE.IDENTITY_UNAVAILABLE
	end
	local live_time = rawget(live, "create_time")
	if type(live_time) ~= "number" or live_time ~= live_time then
		return nil, CODE.IDENTITY_UNAVAILABLE
	end
	if math.abs(live_time - created) > LIMITS.identity_tolerance then
		return nil, CODE.IDENTITY_STALE
	end
	return {
		port = port,
		secret = secret,
		session = session,
		pid = pid,
		create_time = created,
		gauntlet = { "Test1", "Test2", "Test3", "Test4", "Test5" },
	}, CODE.OK
end

-- ---------------------------------------------------------------------------
-- status probe (menu controller port)
-- ---------------------------------------------------------------------------

-- Source-backed menu/run/lobby probe. `mp_connected` is the active ordinary
-- Multiplayer lobby predicate: the lobby code is non-nil. The official socket is
-- connected at the normal main menu and that is expected, so the socket boolean
-- is deliberately NOT consulted.
function CompanionHost.status_probe(ports)
	local G = ports.G
	local MP = ports.MP
	local mp_compatible = ports.mp_compatible == true
	return function()
		local main_menu = false
		local active_run = false
		if type(G) == "table" then
			local stages = rget(G, "STAGES")
			local stage = rget(G, "STAGE")
			local menu_stage = rget(stages, "MAIN_MENU")
			local run_stage = rget(stages, "RUN")
			if is_int(stage) and is_int(menu_stage) then
				main_menu = stage == menu_stage
			end
			if is_int(stage) and is_int(run_stage) then
				active_run = stage == run_stage
			end
		end
		local lobby_code = nil
		if type(MP) == "table" then
			lobby_code = rget(rget(MP, "LOBBY"), "code")
		end
		local mp_connected = type(lobby_code) == "string" and #lobby_code > 0
		return {
			main_menu = main_menu,
			active_run = active_run,
			mp_connected = mp_connected,
			mp_compatible = mp_compatible,
		}
	end
end

-- ---------------------------------------------------------------------------
-- privileged defaults (only built when the injected port is absent)
-- ---------------------------------------------------------------------------

function CompanionHost.default_clock(ports)
	local love = ports.love
	local timer = rget(love, "timer")
	local get_time = rget(timer, "getTime")
	if type(get_time) ~= "function" then
		return nil
	end
	return {
		now = function()
			local ok, value = pcall(get_time)
			if ok and type(value) == "number" and value == value then
				return value
			end
			return nil
		end,
	}
end

-- Strict environment reader. Only names the caller requests are read; the
-- companion only ever asks for the exact AISP_* descriptor names.
function CompanionHost.default_env_reader(os_module)
	if type(os_module) ~= "table" or type(rawget(os_module, "getenv")) ~= "function" then
		return nil
	end
	return function(name)
		if type(name) ~= "string" or #name == 0 or #name > 64 then
			return nil
		end
		local ok, value = pcall(os_module.getenv, name)
		if ok and type(value) == "string" then
			return value
		end
		return nil
	end
end

function CompanionHost.default_quit(ports)
	local love = ports.love
	local event = rget(love, "event")
	local quit = rget(event, "quit")
	if type(quit) ~= "function" then
		return nil
	end
	return function()
		quit()
		return true
	end
end

-- Trusted read adapter over the Lovely native filesystem. Returns a decoded
-- table or nil. Never raises.
function CompanionHost.nfs_reader(nfs, decode)
	if type(nfs) ~= "table" or type(decode) ~= "function" then
		return nil
	end
	if type(rawget(nfs, "getInfo")) ~= "function" or type(rawget(nfs, "read")) ~= "function" then
		return nil
	end
	return function(path)
		local ok_info, info = pcall(nfs.getInfo, path)
		if not ok_info or info == nil then
			return nil
		end
		local ok_read, content = pcall(nfs.read, path)
		if not ok_read or type(content) ~= "string" or #content == 0 then
			return nil
		end
		local ok_decode, decoded = pcall(decode, content)
		if not ok_decode then
			return nil
		end
		return decoded
	end
end

local IDENTITY_CDEF = [[
typedef struct { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } AISP_FILETIME;
void* OpenProcess(unsigned long dwDesiredAccess, int bInheritHandle, unsigned long dwProcessId);
int GetProcessTimes(void* hProcess, AISP_FILETIME* creation, AISP_FILETIME* exit_time, AISP_FILETIME* kernel, AISP_FILETIME* user);
int CloseHandle(void* hObject);
unsigned long GetCurrentProcessId(void);
]]

-- Windows FILETIME is 100 ns ticks since 1601-01-01; Unix seconds are offset by
-- the fixed epoch delta. Values stay well inside exact double range here.
local FILE_TIME_EPOCH_DELTA = 11644473600.0
local FILE_TIME_TICKS_PER_SECOND = 10000000
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

local function filetime_seconds(ft)
	if ft == nil then
		return nil
	end
	local low = tonumber(ft.dwLowDateTime)
	local high = tonumber(ft.dwHighDateTime)
	if low == nil or high == nil then
		return nil
	end
	local ticks = high * 4294967296 + low
	return (ticks / FILE_TIME_TICKS_PER_SECOND) - FILE_TIME_EPOCH_DELTA
end

-- An FFI-exact integer: nil for anything that is not a finite whole number, so a
-- cdata DWORD (converted by tonumber) is accepted while NaN/inf/floats are not.
local function ffi_integer(value)
	local numeric = tonumber(value)
	if numeric == nil or numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
		return nil
	end
	if numeric % 1 ~= 0 then
		return nil
	end
	return numeric
end

-- Resolve one symbol from a real LuaJIT FFI C library. A loaded library is
-- userdata whose symbols are callable cdata; looking up an undeclared symbol can
-- raise, so every index is protected. Table-shaped fixtures are read raw.
local function ffi_symbol(library, name)
	if library == nil or name == nil then
		return nil
	end
	if type(library) == "table" then
		return rawget(library, name)
	end
	local ok, value = pcall(function()
		return library[name]
	end)
	if not ok then
		return nil
	end
	return value
end

local function ffi_callable(value)
	local kind = type(value)
	return kind == "function" or kind == "cdata"
end

-- Legitimate query-only Windows identity adapter (LuaJIT ffi). It never opens a
-- termination handle: only PROCESS_QUERY_LIMITED_INFORMATION is requested and the
-- returned handle is always closed, including after a failed query. Any missing
-- symbol, partial ffi module or failed load fails closed.
function CompanionHost.default_identity(ports)
	local ffi = ports.ffi
	if type(ffi) ~= "table" then
		return nil
	end
	local cdef = rawget(ffi, "cdef")
	local load = rawget(ffi, "load")
	local new = rawget(ffi, "new")
	if type(cdef) ~= "function" or type(load) ~= "function" or type(new) ~= "function" then
		return nil
	end
	-- A redefinition error is expected once this adapter has been built in the
	-- same Lua state; the earlier declaration still satisfies the lookups below.
	pcall(cdef, IDENTITY_CDEF)
	local ok_library, library = pcall(load, "kernel32")
	if not ok_library or library == nil then
		return nil
	end
	local kind = type(library)
	if kind ~= "table" and kind ~= "userdata" and kind ~= "cdata" then
		return nil
	end
	local open_process = ffi_symbol(library, "OpenProcess")
	local get_process_times = ffi_symbol(library, "GetProcessTimes")
	local close_handle = ffi_symbol(library, "CloseHandle")
	local get_current_pid = ffi_symbol(library, "GetCurrentProcessId")
	if not ffi_callable(open_process)
		or not ffi_callable(get_process_times)
		or not ffi_callable(close_handle)
		or not ffi_callable(get_current_pid) then
		return nil
	end

	local function create_time_of(pid)
		local numeric = ffi_integer(pid)
		if numeric == nil or numeric < 1 or numeric > 4294967295 then
			return nil
		end
		local ok, value = pcall(function()
			local handle = open_process(PROCESS_QUERY_LIMITED_INFORMATION, 0, numeric)
			if handle == nil then
				return nil
			end
			local ok_query, result, creation = pcall(function()
				local creation_ft = new("AISP_FILETIME[1]")
				local exit_time = new("AISP_FILETIME[1]")
				local kernel = new("AISP_FILETIME[1]")
				local user = new("AISP_FILETIME[1]")
				local times_result = get_process_times(handle, creation_ft, exit_time, kernel, user)
				return times_result, creation_ft
			end)
			-- The handle is released on every path, including a failed or throwing
			-- query; the adapter never leaks a handle and never terminates anything.
			pcall(close_handle, handle)
			if not ok_query then
				return nil
			end
			if ffi_integer(result) ~= 1 then
				return nil
			end
			return filetime_seconds(creation[0])
		end)
		if not ok or type(value) ~= "number" or value ~= value then
			return nil
		end
		return value
	end

	return {
		current = function()
			local ok, pid = pcall(get_current_pid)
			if not ok then
				return nil
			end
			local numeric = ffi_integer(pid)
			if numeric == nil or numeric < 1 then
				return nil
			end
			local created = create_time_of(numeric)
			if created == nil then
				return nil
			end
			return { pid = numeric, create_time = created }
		end,
		process = function(pid)
			local numeric = ffi_integer(pid)
			if numeric == nil or numeric < 1 then
				return nil
			end
			local created = create_time_of(numeric)
			if created == nil then
				return nil
			end
			return { pid = numeric, create_time = created }
		end,
	}
end

-- ---------------------------------------------------------------------------
-- loopback transport (live role)
-- ---------------------------------------------------------------------------

-- Build the default bounded nonblocking LÖVE-thread transport. The relay worker
-- is the reviewed control_thread.lua worker (protocol-agnostic newline frames,
-- 127.0.0.1 only, 2 MiB outbound / 64 KiB inbound); this wraps its channels.
function CompanionHost.thread_transport(ports, info)
	local love = ports.love
	local love_thread = rget(love, "thread")
	local control_thread = ports.control_thread
	local get_channel = rget(love_thread, "getChannel")
	local decode = ports.decode
	if type(control_thread) ~= "table"
		or type(rawget(control_thread, "start")) ~= "function"
		or type(get_channel) ~= "function"
		or type(decode) ~= "function" then
		return nil, CODE.TRANSPORT_UNAVAILABLE
	end
	local nonce = token_of(info.nonce or ("p" .. tostring(info.pid)), NONCE_PATTERN, LIMITS.max_nonce)
	if nonce == nil then
		nonce = "p" .. tostring(info.pid)
	end
	local to_worker_name = "aisp_host_" .. nonce .. "_tw"
	local from_worker_name = "aisp_host_" .. nonce .. "_fw"
	local ok_a, to_worker = pcall(get_channel, to_worker_name)
	local ok_b, from_worker = pcall(get_channel, from_worker_name)
	if not ok_a or not ok_b or to_worker == nil or from_worker == nil then
		return nil, CODE.TRANSPORT_UNAVAILABLE
	end
	local ok_thread, thread = pcall(control_thread.start, love_thread, info.port, to_worker_name, from_worker_name)
	if not ok_thread or thread == nil then
		return nil, CODE.TRANSPORT_UNAVAILABLE
	end

	local state = { connected = false, last_error = nil }

	local transport = {}
	function transport.send(text)
		if type(text) ~= "string" or #text == 0 or #text > LIMITS.max_send then
			return nil, CODE.TRANSPORT_ERROR
		end
		local ok = pcall(to_worker.push, to_worker, text)
		if not ok then
			state.last_error = CODE.TRANSPORT_ERROR
			return nil, CODE.TRANSPORT_ERROR
		end
		return true
	end
	function transport.poll()
		for _ = 1, LIMITS.max_drain do
			local message = from_worker:pop()
			if message == nil then
				return nil
			end
			if type(message) == "string" and #message <= LIMITS.max_receive then
				local ok_decode, decoded = pcall(decode, message)
				if ok_decode and type(decoded) == "table" then
					local event = rawget(decoded, "t")
					if event == nil then
						return decoded
					end
					if event == "ready" then
						state.connected = true
					elseif event == "error" then
						state.connected = false
						state.last_error = rawget(decoded, "code") or CODE.TRANSPORT_ERROR
					elseif event == "closed" then
						state.connected = false
						state.last_error = state.last_error or CODE.TRANSPORT_ERROR
					elseif event == "stopped" then
						state.connected = false
					end
				end
			end
		end
		return nil
	end
	function transport.connected()
		return state.connected
	end
	function transport.last_error()
		return state.last_error
	end
	function transport.close()
		pcall(to_worker.push, to_worker, '{"t":"stop"}')
		return true
	end
	return transport, CODE.OK
end

-- ---------------------------------------------------------------------------
-- live host adapter
-- ---------------------------------------------------------------------------

local function validate_payload(payload)
	if not is_plain(payload) then
		return nil
	end
	for key in next, payload do
		if key ~= "mode" and key ~= "difficulty" and key ~= "pacing" and key ~= "gauntlet_index" then
			return nil
		end
	end
	local mode = rawget(payload, "mode")
	if not contains(ENUMS.mode, mode) then
		return nil
	end
	local difficulty = rawget(payload, "difficulty")
	if not contains(ENUMS.difficulty, difficulty) then
		return nil
	end
	local pacing = rawget(payload, "pacing")
	if not contains(ENUMS.pacing, pacing) then
		return nil
	end
	local index = nil
	if mode == "gauntlet" then
		index = rawget(payload, "gauntlet_index")
		if not is_int(index) or index < 1 or index > #ENUMS.gauntlet then
			return nil
		end
	elseif rawget(payload, "gauntlet_index") ~= nil then
		return nil
	end
	local out = { mode = mode, difficulty = difficulty, pacing = pacing }
	if index ~= nil then
		out.gauntlet_index = index
	end
	return out
end

-- Build the live host adapter. All side effects are injected ports; this only
-- ever produces a table of functions.
function CompanionHost.live_host(ports)
	local companion = ports.companion
	if type(companion) ~= "table" then
		return nil, CODE.LIVE_ENV_MISSING
	end
	local discovery_path = path_of(rawget(companion, "discovery_path"))
	if discovery_path == nil then
		return nil, CODE.LIVE_ENV_MISSING
	end
	local read_discovery = ports.read_discovery
	if type(read_discovery) ~= "function" then
		read_discovery = CompanionHost.nfs_reader(ports.NFS, ports.decode)
	end
	local identity = ports.identity
	if type(identity) ~= "table" then
		identity = CompanionHost.default_identity(ports)
	end
	local quit = ports.quit
	if type(quit) ~= "function" then
		quit = CompanionHost.default_quit(ports)
	end

	local marker_info = nil
	local transport = nil
	local transport_port = nil
	local pending = nil
	local counter = 0
	local state = "idle"
	local diagnostic_path = sanitize_text(path_directory(discovery_path), LIMITS.max_path)

	local function resolve_marker()
		if type(read_discovery) ~= "function" then
			return nil, CODE.MARKER_UNREADABLE
		end
		local ok, marker = pcall(read_discovery, discovery_path)
		if not ok then
			return nil, CODE.MARKER_UNREADABLE
		end
		if marker == nil then
			return nil, CODE.MARKER_ABSENT
		end
		local info, code = CompanionHost.inspect_marker(marker, identity)
		if info == nil then
			return nil, code
		end
		return info, CODE.OK
	end

	local function build_transport(info)
		if type(ports.transport) == "table" and type(rawget(ports.transport, "send")) == "function" then
			return ports.transport, CODE.OK
		end
		if type(ports.transport_factory) == "function" then
			local ok, built, code = pcall(ports.transport_factory, { port = info.port, pid = info.pid })
			if not ok or type(built) ~= "table" then
				return nil, code or CODE.TRANSPORT_UNAVAILABLE
			end
			return built, CODE.OK
		end
		return CompanionHost.thread_transport(ports, info)
	end

	local function ensure_transport(info)
		if transport ~= nil and transport_port == info.port then
			return transport, CODE.OK
		end
		if transport ~= nil and type(rawget(transport, "close")) == "function" then
			pcall(transport.close)
		end
		local built, code = build_transport(info)
		if built == nil then
			transport = nil
			transport_port = nil
			return nil, code or CODE.TRANSPORT_UNAVAILABLE
		end
		transport = built
		transport_port = info.port
		return transport, CODE.OK
	end

	local function refresh()
		local info, code = resolve_marker()
		if info == nil then
			marker_info = nil
			return nil, code
		end
		if marker_info == nil or marker_info.pid ~= info.pid or marker_info.port ~= info.port then
			marker_info = info
			if transport ~= nil and transport_port ~= info.port then
				pcall(transport.close)
				transport = nil
				transport_port = nil
			end
		else
			marker_info = info
		end
		return info, CODE.OK
	end

	local wire = ports.wire
	if type(wire) ~= "table" or type(rawget(wire, "encode_host")) ~= "function" then
		wire = nil
	end

	local function json_null()
		local explicit = ports.json_null
		if explicit ~= nil then
			return explicit
		end
		return rget(ports.JSON, "null")
	end

	-- Encode one practice-host request. With the trusted wire encoder the exact
	-- key set and the explicit `gauntlet: null` are owned there; otherwise the
	-- legacy encode + null-sentinel ports are honoured (fixtures only).
	local function encode_request(auth, op, request, label)
		local envelope = {
			schema = CompanionHost.REQUEST_SCHEMA,
			op = op,
			auth = auth,
			request = request,
		}
		local text
		if wire ~= nil then
			local ok, value = pcall(wire.encode_host, envelope)
			if not ok or type(value) ~= "string" then
				return nil, CODE.BAD_WIRE
			end
			text = value
		else
			if request.gauntlet == nil then
				request.gauntlet = label
			end
			local encode = ports.encode
			if type(encode) ~= "function" then
				encode = rget(ports.JSON, "encode")
			end
			if type(encode) ~= "function" then
				return nil, CODE.TRANSPORT_UNAVAILABLE
			end
			local ok, value = pcall(encode, envelope)
			if not ok or type(value) ~= "string" then
				return nil, CODE.ENCODE_FAILED
			end
			text = value
		end
		if type(text) ~= "string" or #text == 0 or #text > LIMITS.max_send then
			return nil, CODE.ENCODE_FAILED
		end
		return text, CODE.OK
	end

	local host = {}

	function host.available()
		local ok, value = pcall(function()
			local info, code = refresh()
			if info == nil then
				return false, code
			end
			local built, build_code = ensure_transport(info)
			if built == nil then
				return false, build_code
			end
			return true, CODE.OK
		end)
		return ok == true and value == true
	end

	function host.request_start(payload)
		if pending ~= nil then
			return nil, CODE.BUSY
		end
		local ok, request_id, code = pcall(function()
			local selection = validate_payload(payload)
			if selection == nil then
				return nil, CODE.BAD_SELECTION
			end
			local info, info_code = refresh()
			if info == nil then
				return nil, info_code or CODE.NOT_AVAILABLE
			end
			local built, build_code = ensure_transport(info)
			if built == nil then
				return nil, build_code or CODE.TRANSPORT_UNAVAILABLE
			end
			if type(identity) ~= "table" or type(rawget(identity, "current")) ~= "function" then
				return nil, CODE.IDENTITY_UNAVAILABLE
			end
			local ok_current, current = pcall(identity.current)
			if not ok_current or type(current) ~= "table"
				or not is_int(rawget(current, "pid"))
				or type(rawget(current, "create_time")) ~= "number" then
				return nil, CODE.IDENTITY_UNAVAILABLE
			end
			local label = nil
			if selection.mode == "gauntlet" then
				label = "Test" .. tostring(selection.gauntlet_index)
				if not contains(info.gauntlet, label) then
					return nil, CODE.BAD_SELECTION
				end
			elseif wire == nil then
				-- Legacy fixture path only; the wire encoder emits explicit null.
				label = json_null()
				if label == nil then
					return nil, CODE.JSON_NULL_UNSUPPORTED
				end
			end
			local request = {
				session_id = info.session,
				difficulty = selection.difficulty,
				pacing = selection.pacing,
				mode = selection.mode,
				live_pid = rawget(current, "pid"),
				live_create_time = rawget(current, "create_time"),
			}
			if selection.mode == "gauntlet" then
				request.gauntlet = label
			end
			local text, encode_code = encode_request(info.secret, "start", request, label)
			if text == nil then
				return nil, encode_code
			end
			local sent, send_code = built.send(text)
			if sent ~= true then
				return nil, send_code or CODE.TRANSPORT_ERROR
			end
			counter = counter + 1
			local request_id = "live-" .. tostring(counter)
			pending = { id = request_id, op = "start" }
			state = "awaiting_ack"
			return request_id, CODE.OK
		end)
		if ok ~= true then
			return nil, CODE.INTERNAL
		end
		return request_id, code
	end

	function host.poll_start(request_id)
		if pending == nil or pending.id ~= request_id then
			return nil
		end
		if type(transport) ~= "table" or type(rawget(transport, "poll")) ~= "function" then
			return nil
		end
		local response = transport.poll()
		if response == nil then
			local last_error = nil
			if type(rawget(transport, "last_error")) == "function" then
				local ok_error, value = pcall(transport.last_error)
				if ok_error then
					last_error = value
				end
			end
			if last_error ~= nil then
				pending = nil
				state = "transport_error"
				return { status = "error", code = last_error }
			end
			return nil
		end
		if type(response) ~= "table" then
			pending = nil
			state = "error"
			return { status = "error", code = CODE.TRANSPORT_ERROR }
		end
		pending = nil
		if rawget(response, "ok") == true then
			state = "accepted"
			return { status = "ok", ticket = rawget(response, "ticket"), code = rawget(response, "code") }
		end
		state = "rejected"
		return { status = "rejected", code = rawget(response, "code") }
	end

	function host.quit()
		if type(quit) ~= "function" then
			return false
		end
		local ok = pcall(quit)
		return ok == true
	end

	function host.diagnostics_path()
		return diagnostic_path
	end

	function host.close()
		if transport ~= nil and type(rawget(transport, "close")) == "function" then
			pcall(transport.close)
		end
		transport = nil
		transport_port = nil
		return true
	end

	function host.describe()
		return {
			version = CompanionHost.VERSION,
			state = state,
			has_pending = pending ~= nil,
			marker_valid = marker_info ~= nil,
			transport_ready = transport ~= nil,
			diagnostic_path = diagnostic_path,
		}
	end

	return host, CODE.OK
end

-- Assemble the live menu companion: UI + reviewed menu controller + host.
function CompanionHost.build_ui(ports)
	local G = ports.G
	local funcs = rget(G, "FUNCS")
	if type(G) ~= "table" or type(funcs) ~= "table" then
		return nil
	end
	return {
		G = G,
		funcs = funcs,
		UIBox_button = ports.UIBox_button,
		create_UIBox_generic_options = ports.create_UIBox_generic_options,
		overlay_menu = rget(funcs, "overlay_menu"),
		exit_overlay_menu = rget(funcs, "exit_overlay_menu"),
		notify = ports.notify,
	}
end

function CompanionHost.live(ports)
	local PracticeMenu = ports.practice_menu
	local MenuController = ports.menu_controller
	if type(PracticeMenu) ~= "table" or type(rawget(PracticeMenu, "factory")) ~= "function" then
		return nil, CODE.BAD_UI
	end
	if type(MenuController) ~= "table" or type(rawget(MenuController, "factory")) ~= "function" then
		return nil, CODE.MENU_FAILED
	end
	local ui = CompanionHost.build_ui(ports)
	if ui == nil then
		return nil, CODE.BAD_UI
	end
	local menu, menu_code = PracticeMenu.factory(ui)
	if menu == nil then
		return nil, menu_code or CODE.BAD_UI
	end
	local host, host_code = CompanionHost.live_host(ports)
	if host == nil then
		return nil, host_code or CODE.LIVE_ENV_MISSING
	end
	local clock = ports.clock
	if type(clock) ~= "table" then
		clock = CompanionHost.default_clock(ports)
	end
	if type(clock) ~= "table" or type(rawget(clock, "now")) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local controller, controller_code = MenuController.factory({
		ui = ui,
		menu = menu,
		host = host,
		status = { probe = CompanionHost.status_probe(ports) },
		clock = clock,
	})
	if controller == nil then
		return nil, controller_code or CODE.MENU_FAILED
	end

	local installed = false
	local instance = { role = "live" }
	function instance.install()
		if installed then
			return true, CODE.OK
		end
		local ok, code = controller.install()
		if ok ~= true then
			return nil, code or CODE.MENU_FAILED
		end
		installed = true
		return true, CODE.OK
	end
	function instance.update(dt)
		if not installed then
			return "inert"
		end
		return controller.update(dt)
	end
	function instance.uninstall()
		if installed then
			pcall(controller.uninstall)
		end
		pcall(host.close)
		installed = false
		return true, CODE.OK
	end
	function instance.status()
		return {
			role = "live",
			installed = installed,
			state = controller.state(),
			host_available = host.available(),
			diagnostic_path = host.diagnostics_path(),
		}
	end
	function instance.describe()
		return instance.status()
	end
	function instance.host()
		return host
	end
	function instance.controller()
		return controller
	end
	return instance, CODE.OK
end

-- ---------------------------------------------------------------------------
-- staged role descriptors (strict, typed)
-- ---------------------------------------------------------------------------

function CompanionHost.validate_descriptors(source)
	if not is_plain(source) then
		return nil, CODE.STAGED_ENV_BAD
	end
	local role = rawget(source, "role")
	if role ~= "human" and role ~= "ai" then
		return nil, CODE.STAGED_ROLE_CROSSED
	end
	local session = token_of(rawget(source, "session"), TOKEN_PATTERN, LIMITS.max_token)
	local credential = token_of(rawget(source, "credential"), TOKEN_PATTERN, LIMITS.max_token)
	local nonce = token_of(rawget(source, "nonce"), NONCE_PATTERN, LIMITS.max_nonce)
	local content_hash = token_of(rawget(source, "content_hash"), HASH_PATTERN, LIMITS.max_hash)
	if session == nil or credential == nil or nonce == nil or content_hash == nil then
		return nil, CODE.STAGED_ENV_BAD
	end
	local control_port = rawget(source, "control_port")
	if not is_int(control_port) or control_port < 1 or control_port > 65535 then
		return nil, CODE.STAGED_ENV_BAD
	end
	local save_root = path_of(rawget(source, "save_root"))
	local mods_root = path_of(rawget(source, "mods_root"))
	if save_root == nil or mods_root == nil then
		return nil, CODE.STAGED_ENV_BAD
	end
	-- The companion module root is derived from the expected role Mods root; it
	-- is never read from the environment.
	local mod_root = path_of(path_join(mods_root, "AISparring"))
	if mod_root == nil then
		return nil, CODE.STAGED_ENV_BAD
	end
	local mode = rawget(source, "mode")
	local difficulty = rawget(source, "difficulty")
	local pacing = rawget(source, "pacing")
	if not contains(ENUMS.mode, mode)
		or not contains(ENUMS.difficulty, difficulty)
		or not contains(ENUMS.pacing, pacing) then
		return nil, CODE.STAGED_ENV_BAD
	end
	local gauntlet = rawget(source, "gauntlet")
	if gauntlet == nil then
		gauntlet = ""
	end
	if type(gauntlet) ~= "string" or #gauntlet > 16 then
		return nil, CODE.STAGED_ENV_BAD
	end
	if mode == "gauntlet" then
		if not contains(ENUMS.gauntlet, gauntlet) then
			return nil, CODE.STAGED_ENV_BAD
		end
	elseif gauntlet ~= "" then
		return nil, CODE.STAGED_ENV_BAD
	end
	return {
		role = role,
		session = session,
		credential = credential,
		nonce = nonce,
		content_hash = content_hash,
		control_port = control_port,
		save_root = save_root,
		mods_root = mods_root,
		mod_root = mod_root,
		mode = mode,
		difficulty = difficulty,
		pacing = pacing,
		gauntlet = gauntlet,
	}, CODE.OK
end

-- Read the strict launcher environment descriptors. Only the canonical names in
-- CompanionHost.ENV are consulted; anything else in the environment is ignored.
function CompanionHost.read_descriptors(env_reader)
	if type(env_reader) ~= "function" then
		return nil, CODE.STAGED_ENV_MISSING
	end
	local function get(name)
		local ok, value = pcall(env_reader, name)
		if not ok then
			return nil
		end
		return value
	end
	local source = {
		role = get(ENV.ROLE),
		session = get(ENV.SESSION),
		credential = get(ENV.CREDENTIAL),
		nonce = get(ENV.NONCE),
		content_hash = get(ENV.CONTENT_HASH),
		control_port = tonumber(get(ENV.CONTROL_PORT) or ""),
		save_root = get(ENV.SAVE_ROOT),
		mods_root = get(ENV.MODS_ROOT),
		mode = get(ENV.MODE),
		difficulty = get(ENV.DIFFICULTY),
		pacing = get(ENV.PACING),
		gauntlet = get(ENV.GAUNTLET),
	}
	if source.role == nil and source.session == nil and source.credential == nil then
		return nil, CODE.STAGED_ENV_MISSING
	end
	return CompanionHost.validate_descriptors(source)
end

function CompanionHost.default_paths(ports)
	local love = ports.love
	local get_save = rget(rget(love, "filesystem"), "getSaveDirectory")
	if type(get_save) ~= "function" then
		return nil
	end
	local SMODS = ports.SMODS
	local mods_dir = rget(SMODS, "MODS_DIR")
	local own = rget(rget(SMODS, "Mods"), "AISparring")
	local mod_path = rget(own, "path")
	if type(mods_dir) ~= "string" or type(mod_path) ~= "string" then
		return nil
	end
	return {
		save_dir = function()
			local ok, value = pcall(get_save)
			if ok then
				return value
			end
			return nil
		end,
		mods_root = function()
			return mods_dir
		end,
		mod_root = function()
			return mod_path
		end,
	}
end

-- Validate a decoded launcher attestation against the descriptors the companion
-- read from the strict environment, and against the exact schema written by
-- tools/isolation_certificate.py::write_launcher_attestation. Returns the
-- verdict table plus a bounded code; a nil table means the blob is not trusted.
function CompanionHost.check_attestation(blob, descriptors)
	if not is_plain(blob) or rawget(blob, "schema") ~= CompanionHost.ATTESTATION_SCHEMA then
		return nil, CODE.STAGED_ATTESTATION_UNVERIFIED
	end
	if rawget(blob, "ok") ~= true then
		return nil, CODE.STAGED_ATTESTATION_UNVERIFIED
	end
	if rawget(blob, "nonce") ~= descriptors.nonce
		or rawget(blob, "session") ~= descriptors.session
		or rawget(blob, "role") ~= descriptors.role
		or rawget(blob, "content_hash") ~= descriptors.content_hash
		or rawget(blob, "control_port") ~= descriptors.control_port then
		return nil, CODE.STAGED_ATTESTATION_UNVERIFIED
	end
	local save_root = normalize_path(rawget(blob, "expected_role_save_root"))
	local mods_root = normalize_path(rawget(blob, "expected_role_mods_root"))
	local expected_save = normalize_path(descriptors.save_root)
	local expected_mods = normalize_path(descriptors.mods_root)
	if save_root == nil or mods_root == nil
		or save_root ~= expected_save or mods_root ~= expected_mods then
		return nil, CODE.STAGED_ATTESTATION_PATH
	end
	return {
		ok = true,
		nonce = descriptors.nonce,
		session = descriptors.session,
		role = descriptors.role,
		content_hash = descriptors.content_hash,
		control_port = descriptors.control_port,
	}, CODE.OK
end

-- The fixed session-bound attestation path derives from the expected role save
-- root; the repository configuration never carries a path override.
function CompanionHost.attestation_path(descriptors)
	if type(descriptors) ~= "table" then
		return nil
	end
	local save_root = path_of(rawget(descriptors, "save_root"))
	if save_root == nil then
		return nil
	end
	return path_of(path_join(save_root, LIMITS.attestation_file))
end

-- Build the attestation resolver. Two trusted sources are supported, in this
-- order: an injected launcher verdict port (fixtures/in-process launcher), or
-- the fixed attestation file read through the trusted native read adapter. A
-- nil resolver means no attestation source exists at all: that is a fatal
-- configuration gap, not a deferral.
function CompanionHost.build_attestation(ports, descriptors)
	local path = ports.attestation_path or CompanionHost.attestation_path(descriptors)
	local reader = ports.attestation_reader
	if type(reader) ~= "function" then
		reader = CompanionHost.nfs_reader(ports.NFS, ports.decode)
	end
	local launcher_port = ports.launcher_attestation
	local resolver = {}
	if type(launcher_port) == "function" then
		resolver.source = "launcher"
		resolver.resolve = function()
			local ok, verdict = pcall(launcher_port, descriptors)
			if not ok or type(verdict) ~= "table" then
				return nil, CODE.STAGED_ATTESTATION_UNVERIFIED, false
			end
			return verdict, (verdict.ok == true and CODE.OK or CODE.STAGED_ATTESTATION_UNVERIFIED), false
		end
		return resolver
	end
	if type(reader) == "function" and type(path) == "string" then
		resolver.source = "file"
		resolver.path = path
		resolver.resolve = function()
			local ok, blob = pcall(reader, path)
			if not ok then
				return nil, CODE.STAGED_ATTESTATION_UNVERIFIED, true
			end
			if blob == nil then
				return nil, CODE.STAGED_ATTESTATION_MISSING, true
			end
			local verdict, code = CompanionHost.check_attestation(blob, descriptors)
			if verdict == nil then
				return nil, code, false
			end
			return verdict, CODE.OK, false
		end
		return resolver
	end
	return nil
end

-- Staged-window identification, applied exactly once. After the launcher
-- attestation is validated and before any startup/match request, set the role's
-- window title and (AI role only) minimize the window a single time. Both
-- `setTitle` and, for the AI role, `minimize` must be present and callable: a
-- missing or throwing method is a bounded failure that prevents staged startup.
-- The window object is only read here; it is never stored on a status surface
-- and never reaches policy. This never changes focus, timers, update loops or
-- gameplay, and it is never applied to the live companion.
function CompanionHost.stage_window(window_port, role)
	if role ~= "human" and role ~= "ai" then
		return nil, CODE.WINDOW_UNAVAILABLE
	end
	if type(window_port) ~= "table" then
		return nil, CODE.WINDOW_UNAVAILABLE
	end
	local set_title = rawget(window_port, "setTitle")
	if type(set_title) ~= "function" then
		return nil, CODE.WINDOW_UNAVAILABLE
	end
	local minimize = rawget(window_port, "minimize")
	if role == "ai" and type(minimize) ~= "function" then
		return nil, CODE.WINDOW_UNAVAILABLE
	end
	local title = CompanionHost.WINDOW.human_title
	if role == "ai" then
		title = CompanionHost.WINDOW.ai_title
	end
	local ok_title = pcall(set_title, title)
	if ok_title ~= true then
		return nil, CODE.WINDOW_FAILED
	end
	if role == "ai" then
		local ok_minimize = pcall(minimize)
		if ok_minimize ~= true then
			return nil, CODE.WINDOW_FAILED
		end
	end
	return true, CODE.OK
end

-- Invoke the trusted staged runtime bootstrap. The AI role additionally gets
-- the policy/executor module set; the human role never constructs it.
function CompanionHost.staged(ports)
	local RuntimeBootstrap = ports.runtime_bootstrap
	if type(RuntimeBootstrap) ~= "table" or type(rawget(RuntimeBootstrap, "factory")) ~= "function" then
		return nil, CODE.STAGED_BOOTSTRAP_FAILED
	end
	local descriptors, descriptor_code
	if is_plain(ports.descriptors) then
		descriptors, descriptor_code = CompanionHost.validate_descriptors(ports.descriptors)
	else
		descriptors, descriptor_code = CompanionHost.read_descriptors(ports.env_reader)
	end
	if descriptors == nil then
		return nil, descriptor_code or CODE.STAGED_ENV_MISSING
	end
	local declared = ports.role
	if (declared == "human" or declared == "ai") and declared ~= descriptors.role then
		return nil, CODE.STAGED_ROLE_CROSSED
	end
	local paths = ports.paths or CompanionHost.default_paths(ports)
	if type(paths) ~= "table"
		or type(rawget(paths, "save_dir")) ~= "function"
		or type(rawget(paths, "mods_root")) ~= "function"
		or type(rawget(paths, "mod_root")) ~= "function" then
		return nil, CODE.STAGED_ENV_BAD
	end
	local launcher = ports.launcher
	local resolver = nil
	if launcher == nil then
		resolver = CompanionHost.build_attestation(ports, descriptors)
		if resolver == nil then
			return nil, CODE.STAGED_ATTESTATION_MISSING
		end
	end
	-- The engine worker owns the source-backed default element lookup inside the
	-- executor, so the companion passes nil rather than fabricating a nil-returning
	-- button factory. An explicit real port is still forwarded untouched.
	local element_for = ports.element_for
	if element_for ~= nil and type(element_for) ~= "function" then
		element_for = nil
	end
	local hook_targets = nil
	if descriptors.role == "ai" then
		hook_targets = ports.hook_targets
	end
	local love = ports.love
	-- The staged-window identification uses the injected `love.window` API. It is
	-- read here but never forwarded to the runtime, the bootstrap or policy.
	local window_port = ports.window
	if window_port == nil then
		window_port = rget(love, "window")
	end
	local love_thread = ports.love_thread
	if love_thread == nil then
		love_thread = rget(love, "thread")
	end
	local get_channel = ports.get_channel
	if get_channel == nil then
		get_channel = rget(love_thread, "getChannel")
	end
	local clock = ports.clock
	if type(clock) ~= "table" then
		clock = CompanionHost.default_clock(ports)
	end
	if type(clock) ~= "table" or type(rawget(clock, "now")) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	local client = ports.client
	if client == nil then
		client = ports.Client
	end

	local diagnostic_path = sanitize_text(
		path_directory((resolver ~= nil and resolver.path) or descriptors.save_root),
		LIMITS.max_path
	)

	local bootstrap = nil
	local state = "awaiting_attestation"
	local last_code = CODE.STAGED_AWAITING_ATTESTATION
	local failed = false
	local started_at = nil
	local window_staged = false

	local function now()
		local ok, value = pcall(clock.now)
		if not ok or type(value) ~= "number" or value ~= value then
			return nil
		end
		return value
	end

	local function make_bootstrap(verdict_launcher)
		return RuntimeBootstrap.factory({
			role = descriptors.role,
			session = descriptors.session,
			credential = descriptors.credential,
			nonce = descriptors.nonce,
			content_hash = descriptors.content_hash,
			control_port = descriptors.control_port,
			expected = {
				save_dir = descriptors.save_root,
				mods_root = descriptors.mods_root,
				mod_root = descriptors.mod_root,
			},
			env = paths,
			launcher = verdict_launcher,
			control_protocol = ports.control_protocol,
			control_transport_factory = ports.control_transport_factory,
			control_thread = ports.control_thread,
			channels = ports.channels,
			get_channel = get_channel,
			love_thread = love_thread,
			spawn_thread = ports.spawn_thread,
			encode = ports.encode,
			decode = ports.decode,
			clock = clock,
			logger = ports.logger,
			modules = ports.modules or {},
			G = ports.G,
			MP = ports.MP,
			funcs = ports.funcs,
			element_for = element_for,
			client = client,
			ui_notify = ports.ui_notify,
			terminal_probe = ports.terminal_probe,
			config_digest = ports.config_digest,
			hook_targets = hook_targets,
			mode = descriptors.mode,
			difficulty = descriptors.difficulty,
			pacing = descriptors.pacing,
		})
	end

	-- Obtain the launcher verifier. A pre-built `ports.launcher` is trusted
	-- as-is; otherwise the attestation resolver is consulted. A resolved verdict
	-- is handed to the bootstrap, which performs the field-level agreement check.
	local function obtain()
		if launcher ~= nil then
			return launcher, CODE.OK, false
		end
		local verdict, code, deferred = resolver.resolve()
		if verdict == nil then
			return nil, code, deferred
		end
		if verdict.ok ~= true then
			return nil, code or CODE.STAGED_ATTESTATION_UNVERIFIED, false
		end
		return { verify = function()
			return verdict
		end }, CODE.OK, false
	end

	-- One bounded, nonblocking boot attempt. Only a validated attestation lets
	-- the real bootstrap install (which sends the authenticated hello); a missing
	-- file stays pending instead of failing at first load.
	local function attempt()
		if bootstrap ~= nil then
			return true, CODE.OK, false
		end
		if failed then
			return nil, last_code, false
		end
		local verdict_launcher, code, deferred = obtain()
		if verdict_launcher == nil then
			last_code = code or CODE.STAGED_ATTESTATION_UNVERIFIED
			return nil, last_code, deferred
		end
		-- Apply the staged-window identification exactly once, after the
		-- attestation is validated and before the bootstrap sends any
		-- startup/match request. A missing or throwing window method fails
		-- closed here, so staged startup never proceeds without it.
		if not window_staged then
			local window_ok, window_code = CompanionHost.stage_window(window_port, descriptors.role)
			if window_ok ~= true then
				failed = true
				last_code = window_code or CODE.WINDOW_UNAVAILABLE
				return nil, last_code, false
			end
			window_staged = true
		end
		local built, build_code = make_bootstrap(verdict_launcher)
		if built == nil then
			failed = true
			last_code = build_code or CODE.STAGED_BOOTSTRAP_FAILED
			return nil, last_code, false
		end
		local ok_install, install_code = built.install()
		if ok_install ~= true then
			pcall(built.shutdown, install_code or "install_failed")
			failed = true
			last_code = install_code or CODE.STAGED_BOOTSTRAP_FAILED
			return nil, last_code, false
		end
		bootstrap = built
		state = "installed"
		last_code = CODE.OK
		return true, CODE.OK, false
	end

	local ok_eager, eager_code, eager_deferred = attempt()
	if ok_eager ~= true then
		if eager_deferred then
			started_at = now()
		else
			return nil, eager_code
		end
	end

	local instance = { role = "staged", staged_role = descriptors.role }
	function instance.install()
		if bootstrap ~= nil then
			return true, CODE.OK
		end
		local ok_install, install_code, deferred = attempt()
		if ok_install == true then
			return true, CODE.OK
		end
		if deferred then
			return true, CODE.OK
		end
		return nil, install_code or CODE.STAGED_BOOTSTRAP_FAILED
	end
	function instance.update(dt)
		if bootstrap == nil then
			local ok_update, update_code, deferred = attempt()
			if ok_update ~= true then
				if deferred then
					local current = now()
					if started_at ~= nil and current ~= nil
						and current - started_at >= LIMITS.attestation_timeout then
						failed = true
						state = "failed"
						last_code = CODE.STAGED_ATTESTATION_TIMEOUT
						return "failed", last_code
					end
					return state, update_code or CODE.STAGED_AWAITING_ATTESTATION
				end
				failed = true
				state = "failed"
				last_code = update_code or CODE.STAGED_BOOTSTRAP_FAILED
				return "failed", last_code
			end
		end
		return bootstrap.update(dt)
	end
	function instance.uninstall()
		if bootstrap ~= nil then
			pcall(bootstrap.shutdown, "uninstall")
		end
		state = "stopped"
		return true, CODE.OK
	end
	function instance.status()
		if bootstrap == nil then
			return {
				role = "staged",
				staged_role = descriptors.role,
				booted = false,
				pending = not failed,
				state = state,
				handshake = "none",
				activated = false,
				decisions = 0,
				rejected = 0,
				errors = 0,
				last_error = last_code,
				diagnostic_path = diagnostic_path,
			}
		end
		local base = bootstrap.status()
		return {
			role = "staged",
			staged_role = descriptors.role,
			booted = true,
			pending = false,
			state = rget(base, "state"),
			handshake = rget(base, "handshake"),
			activated = rget(base, "activated") == true,
			decisions = rget(base, "decisions"),
			rejected = rget(base, "rejected"),
			errors = rget(base, "errors"),
			last_error = rget(base, "last_error"),
			diagnostic_path = diagnostic_path,
		}
	end
	function instance.describe()
		return instance.status()
	end
	function instance.bootstrap()
		return bootstrap
	end
	function instance.attestation_pending()
		return bootstrap == nil and not failed
	end
	instance.boot_code = CODE.OK
	return instance, CODE.OK
end

-- ---------------------------------------------------------------------------
-- Game:update chain wrapper
-- ---------------------------------------------------------------------------

-- Wrap one update host so the original method is called exactly once, before the
-- bounded companion step. A throwing companion step is counted; after the bound
-- the local feature is closed through `on_failure` and the wrapper becomes
-- inert, so the normal game is never disturbed.
function CompanionHost.install_update(game, update_fn, options)
	if type(game) ~= "table" or type(update_fn) ~= "function" then
		return nil, CODE.NO_UPDATE_HOST
	end
	local original = rawget(game, "update")
	if type(original) ~= "function" then
		return nil, CODE.NO_UPDATE_HOST
	end
	options = is_plain(options) and options or {}
	local max_errors = rawget(options, "max_update_errors") or LIMITS.max_update_errors
	if not is_int(max_errors) or max_errors < 1 then
		max_errors = LIMITS.max_update_errors
	end
	local on_failure = rawget(options, "on_failure")
	local errors = 0
	local active = true
	local wrapper
	wrapper = function(self, dt)
		local r1, r2 = original(self, dt)
		if active then
			local ok = pcall(update_fn, dt)
			if not ok then
				errors = errors + 1
				if errors >= max_errors then
					active = false
					if type(on_failure) == "function" then
						pcall(on_failure)
					end
				end
			end
		end
		return r1, r2
	end
	game.update = wrapper
	local handle = { wrapper = wrapper, original = original }
	function handle.uninstall()
		if game.update == wrapper then
			game.update = original
		end
		active = false
		return true
	end
	function handle.errors()
		return errors
	end
	function handle.active()
		return active
	end
	return handle, CODE.OK
end

-- ---------------------------------------------------------------------------
-- dispatch
-- ---------------------------------------------------------------------------

function CompanionHost.factory(ports)
	if not is_plain(ports) then
		return nil, CODE.BAD_PORTS
	end
	local role = rawget(ports, "role")
	if role == "live" then
		return CompanionHost.live(ports)
	end
	if role == "staged" or role == "human" or role == "ai" then
		return CompanionHost.staged(ports)
	end
	return nil, CODE.UNSUPPORTED_ROLE
end

return CompanionHost
