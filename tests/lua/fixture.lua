local Fixture = {}

Fixture.DEFAULT_MAIN = "core.lua"

local CONTENT_API = {
	"Joker", "Consumable", "Atlas", "Back", "Blind", "Tag", "Voucher", "Booster",
	"Enhancement", "Seal", "Edition", "Stake", "Sound", "Challenge", "Deck", "Card", "PokerHand",
}

local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then
		return nil
	end
	local content = handle:read("*a")
	handle:close()
	return content
end

local function guard(record, name)
	return function()
		local calls = record.calls
		calls[#calls + 1] = name
		error("forbidden side effect: " .. name, 2)
	end
end

local function copy_table(value, depth)
	depth = depth or 0
	if type(value) ~= "table" then
		return value
	end
	if depth > 8 then
		return {}
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = copy_table(item, depth + 1)
	end
	return out
end

-- Model Steamodded's saved-over-installed recursive merge (the reason
-- `smods.Mods[mod_id].config` is untrustworthy for a role/discovery_path). It is
-- an OVER-APPROXIMATION of the real `insert_saved_config`, not a verbatim copy:
-- the saved value wins on same-shaped keys and on a type mismatch, whereas real
-- SMODS keeps the installed value on a type mismatch; the installed table is
-- cloned, not mutated. The load-bearing cases pair compatible types.
local function smods_merge(installed, saved)
	local out = copy_table(installed)
	if type(saved) ~= "table" then
		return out
	end
	for key, value in pairs(saved) do
		if type(value) == "table" and type(out[key]) == "table" then
			out[key] = smods_merge(out[key], value)
		else
			out[key] = copy_table(value)
		end
	end
	return out
end

function Fixture.new(opts)
	opts = opts or {}
	local repo = opts.repo_root
	if type(repo) ~= "string" then
		error("Fixture.new requires repo_root", 2)
	end
	local mod_path = repo .. "/AISparring/"
	local record = {
		calls = {},
		logs = {},
		loads = {},
		config_loads = {},
		mp_reads = {},
		mp_writes = {},
		g_reads = {},
		g_writes = {},
		publish_writes = 0,
	}
	local env = setmetatable({}, { __index = _G })

	local mp_storage = {
		id = "Multiplayer",
		version = opts.mp_version or "0.5.5",
		can_load = opts.mp_can_load,
		disabled = opts.mp_disabled == true,
		config = { ai_enabled = false },
		lovely = true,
		GAME = {},
		ACTIONS = {},
		MOD_ACTIONS = {},
		LOBBY = { connected = false, code = nil },
	}
	if opts.mp_can_load_nil then
		mp_storage.can_load = nil
	elseif opts.mp_can_load == nil then
		mp_storage.can_load = true
	end
	mp_storage.register_mod_action = guard(record, "MP.register_mod_action")
	mp_storage.current_ruleset = guard(record, "MP.current_ruleset")
	mp_storage.ACTIONS.connect = guard(record, "MP.ACTIONS.connect")
	if type(opts.mp_structure) == "table" then
		for key, value in pairs(opts.mp_structure) do
			mp_storage[key] = value
		end
	end
	if type(opts.mp_lobby) == "table" then
		for key, value in pairs(opts.mp_lobby) do
			mp_storage.LOBBY[key] = value
		end
	end
	local mp = setmetatable({}, {
		__index = function(_, key)
			local reads = record.mp_reads
			reads[#reads + 1] = key
			return mp_storage[key]
		end,
		__newindex = function(_, key, value)
			local writes = record.mp_writes
			writes[#writes + 1] = key
			mp_storage[key] = value
		end,
	})

	local g_storage = {}
	local g = setmetatable({}, {
		__index = function(_, key)
			local reads = record.g_reads
			reads[#reads + 1] = key
			return g_storage[key]
		end,
		__newindex = function(_, key, value)
			local writes = record.g_writes
			writes[#writes + 1] = key
			g_storage[key] = value
		end,
	})

	-- `own.config` is the AUTHORITATIVE installed config.lua body; core.lua reads
	-- it through the trusted loader. `opts.saved_config` models the user-persisted
	-- overlay so the merged table (saved over installed) can be checked to be
	-- ignored for the descriptor/enable gate.
	local installed_config = { ai_enabled = opts.ai_enabled == true }
	if type(opts.own_config) == "table" then
		installed_config = opts.own_config
	end
	local own = {
		id = "AISparring",
		version = "0.1.0",
		can_load = true,
		disabled = false,
		config = smods_merge(installed_config, opts.saved_config),
	}
	if opts.own_readonly == true then
		setmetatable(own, {
			__newindex = function()
				record.publish_writes = record.publish_writes + 1
				error("own mod entry is read only", 2)
			end,
		})
	end

	local smods = { Mods = {}, current_mod = own }
	smods.Mods["AISparring"] = own
	smods.Mods["Multiplayer"] = mp
	local third = { id = "ThirdMod", version = "1.0.0", can_load = true, disabled = false }
	smods.Mods["ThirdMod"] = third
	for i = 1, #CONTENT_API do
		smods[CONTENT_API[i]] = guard(record, "SMODS." .. CONTENT_API[i])
	end

	if opts.mp_present == false then
		smods.Mods["Multiplayer"] = nil
	end
	if opts.current_mod_present == false then
		smods.current_mod = nil
	end
	if opts.current_mod_unrelated == true then
		smods.current_mod = { id = "SomeOtherMod" }
	end

	local mirror_mp = mp
	if opts.mp_identity_mismatch == true then
		mirror_mp = setmetatable({}, {
			__index = function(_, key)
				local reads = record.mp_reads
				reads[#reads + 1] = key
				return mp_storage[key]
			end,
		})
	end

	env.MP = mirror_mp
	env.G = g
	env.Client = { send = guard(record, "Client.send"), connect = guard(record, "Client.connect") }
	env.love = {
		thread = { newThread = guard(record, "love.thread.newThread") },
		network = guard(record, "love.network"),
	}

	local function log_to(kind)
		return function(message)
			local logs = record.logs
			logs[#logs + 1] = kind .. ":" .. tostring(message)
			if opts.throw_logs == true then
				error("synthetic logging failure", 2)
			end
		end
	end
	env.sendInfoMessage = log_to("info")
	env.sendWarnMessage = log_to("warn")
	env.sendErrorMessage = log_to("error")
	env.sendDebugMessage = log_to("debug")
	env.sendTraceMessage = log_to("trace")
	env._G = env

	if opts.smods_present ~= false then
		env.SMODS = smods
	end

	smods.load_file = function(path, id)
		if type(path) ~= "string" or path == "" then
			return nil, "no_path"
		end
		if path == "config.lua" then
			-- The authoritative install-time config, read through the trusted
			-- loader (never the merged mod config). `opts.authoritative_config`
			-- injects a bounded failure mode.
			local config_loads = record.config_loads
			config_loads[#config_loads + 1] = id
			local mode = opts.authoritative_config
			if mode == "absent" then
				return nil, "synthetic_absent"
			end
			if mode == "loader_error" then
				error("synthetic config loader failure")
			end
			if mode == "not_function" then
				return "not a function"
			end
			if mode == "exec_error" then
				return function()
					error("synthetic config exec failure")
				end
			end
			if mode == "bad_return" then
				return function()
					return 42
				end
			end
			local snapshot = copy_table(installed_config)
			return function()
				return copy_table(snapshot)
			end
		end
		local loads = record.loads
		loads[#loads + 1] = path
		if opts.fail_module == path then
			return nil, "synthetic_missing"
		end
		local virtual = mod_path .. path
		local content = read_file(virtual)
		if not content then
			return nil, "read_fail"
		end
		if opts.throw_module == path then
			content = "error('synthetic module throw')"
		end
		if type(opts.override_module) == "table" and opts.override_module[path] ~= nil then
			content = opts.override_module[path]
		end
		local chunk, cerr = loadstring(content, "@" .. virtual)
		if not chunk then
			return nil, "compile_fail:" .. tostring(cerr)
		end
		setfenv(chunk, env)
		return chunk
	end

	local ctx = {
		repo_root = repo,
		mod_path = mod_path,
		env = env,
		smods = smods,
		mp = mirror_mp,
		mp_storage = mp_storage,
		own = own,
		third = third,
		record = record,
		main_file = opts.main_file or Fixture.DEFAULT_MAIN,
	}

	function ctx:run()
		local content = read_file(self.mod_path .. self.main_file)
		if not content then
			return false, "entry_unreadable"
		end
		local chunk, cerr = loadstring(content, "@" .. self.mod_path .. self.main_file)
		if not chunk then
			return false, "entry_compile_fail:" .. tostring(cerr)
		end
		setfenv(chunk, self.env)
		return pcall(chunk)
	end

	return ctx
end

return Fixture
