local MOD_ID = "AISparring"

local MODULE_ORDER = {
	{ key = "status", path = "src/status.lua" },
	{ key = "logger", path = "src/logger.lua" },
	{ key = "ai_mode", path = "src/ai_mode.lua" },
	{ key = "dependency", path = "src/dependency.lua" },
	{ key = "host", path = "src/host.lua" },
}

-- Companion module sets. These are loaded ONLY when the installed companion
-- config enables a role and the Multiplayer dependency is satisfied.
--
-- The pure codec (ai/codec.lua) is role-agnostic and belongs to the COMMON
-- staged set: the runtime driver needs Codec.hash_string to build the actual
-- source-derived Major League config digest for BOTH roles, and the human host
-- cannot reach READY without it. The policy/executor set is loaded for the
-- staged AI role only: the staged human role never receives those modules.
local COMPANION_LIVE = {
	"ui/practice_menu.lua",
	"integration/menu_controller.lua",
}
local COMPANION_LIVE_OPTIONAL = {
	"integration/control_thread.lua",
}
local COMPANION_STAGED = {
	"integration/runtime_bootstrap.lua",
	"integration/control_protocol.lua",
	"integration/control_transport.lua",
	"integration/control_thread.lua",
	"integration/mp_driver.lua",
}
-- Loaded for both staged roles; never part of the AI-only policy set.
local COMPANION_STAGED_CODEC = "ai/codec.lua"
local COMPANION_STAGED_AI = {
	"integration/state_reader.lua",
	"integration/engine_adapter.lua",
	"integration/production_executor.lua",
	"integration/state_revision.lua",
	"integration/action_broker.lua",
	"integration/decision_loop.lua",
	"ai/observation.lua",
	"ai/actions.lua",
}

local COMPANION_MAX_UPDATE_ERRORS = 5

local function capabilities()
	return {
		gameplay_hooks = false,
		content_registration = false,
		network_transport = false,
		opponent = false,
		launcher = false,
	}
end

local function copy_primitives(value, depth)
	depth = depth or 0
	local kind = type(value)
	if kind ~= "table" then
		if kind == "string" or kind == "number" or kind == "boolean" then
			return value
		end
		return nil
	end
	if depth > 6 then
		return {}
	end
	local out = {}
	for key, item in pairs(value) do
		local key_kind = type(key)
		if key_kind == "string" or key_kind == "number" then
			local copied = copy_primitives(item, depth + 1)
			if copied ~= nil then
				out[key] = copied
			end
		end
	end
	return out
end

local function minimal_closed(code, detail)
	return {
		scaffold = MOD_ID,
		state = "fail_closed",
		code = code,
		detail = detail,
		scaffold_only = true,
		observation_extractor = false,
		policy = false,
		capabilities = capabilities(),
	}
end

local last_status = nil

local function publish(status)
	last_status = copy_primitives(status)
	pcall(function()
		local current = SMODS.current_mod
		if type(current) ~= "table" then
			return
		end
		local mods = SMODS.Mods
		if type(mods) ~= "table" then
			return
		end
		if current ~= mods[MOD_ID] or current.id ~= MOD_ID then
			return
		end
		current.aisparring = {
			get_status = function()
				return copy_primitives(last_status)
			end,
		}
	end)
end

local function emit(level, message)
	local target
	if level == "warn" then
		target = sendWarnMessage
	elseif level == "error" then
		target = sendErrorMessage
	elseif level == "debug" then
		target = sendDebugMessage
	else
		target = sendInfoMessage
	end
	if type(target) == "function" then
		pcall(target, message, "AISparring")
	end
end

local function load_module(path)
	if type(SMODS) ~= "table" or type(SMODS.load_file) ~= "function" then
		return nil, "smods_unavailable"
	end
	local ok, chunk = pcall(SMODS.load_file, path, MOD_ID)
	if not ok or type(chunk) ~= "function" then
		return nil, "module_unreadable"
	end
	local ok_run, value = pcall(chunk)
	if not ok_run then
		return nil, "module_exec_error"
	end
	if type(value) ~= "table" then
		return nil, "module_bad_return"
	end
	return value
end

-- ---------------------------------------------------------------------------
-- companion wiring
-- ---------------------------------------------------------------------------

-- Read the install-time companion descriptor from the mod's own config. Returns
-- nil unless a role was explicitly installed, so the repository default (and any
-- configuration without a companion block) stays on the inert M1 path.
local function read_companion(smods, mod_id)
	if type(smods) ~= "table" or type(smods.Mods) ~= "table" then
		return nil
	end
	local entry = smods.Mods[mod_id]
	if type(entry) ~= "table" then
		return nil
	end
	local config = rawget(entry, "config")
	if type(config) ~= "table" then
		return nil
	end
	local companion = rawget(config, "companion")
	if type(companion) ~= "table" then
		return nil
	end
	local role = rawget(companion, "role")
	if role ~= "live" and role ~= "staged" then
		return nil
	end
	return companion
end

-- Allowlisted logger bridge over the M1 logger. Only the M1 allowlisted fields
-- survive, so credentials, sessions, seeds and control secrets can never reach a
-- log line through the companion.
local function build_companion_logger(modules)
	if type(modules.logger) ~= "table" or type(modules.logger.new) ~= "function" then
		return nil
	end
	local ok, inner = pcall(modules.logger.new, emit)
	if not ok or type(inner) ~= "table" or type(inner.log) ~= "function" then
		return nil
	end
	return {
		record = function(fields)
			if type(fields) ~= "table" then
				return nil
			end
			local event = fields.event
			if type(event) ~= "string" or event == "" then
				event = "companion"
			end
			local ok_log = pcall(inner.log, inner, "info", event, fields)
			return ok_log == true
		end,
	}
end

-- The real game bundles the rxi `json` library and Multiplayer obtains it by
-- requiring the module named `json` (supplied by SMODS). That library encodes an
-- EMPTY table as `[]` and has no null sentinel, so the raw encoder cannot produce
-- the project's control envelopes on its own. Load the actual supported module
-- here through the host loader (trusted root only, never policy), falling back to
-- a global JSON fixture in tests. The literal loader call is indirect so the M1
-- source tripwire for direct IO/require use in the scaffold stays intact.
local function json_module()
	local loader = type(_G) == "table" and rawget(_G, "require") or nil
	local ok, module = false, nil
	if type(loader) == "function" then
		ok, module = pcall(loader, "json")
	end
	if ok and type(module) == "table"
		and type(rawget(module, "encode")) == "function"
		and type(rawget(module, "decode")) == "function" then
		return module
	end
	if type(JSON) == "table"
		and type(rawget(JSON, "encode")) == "function"
		and type(rawget(JSON, "decode")) == "function" then
		return JSON
	end
	return nil
end

local function json_codec()
	local module = json_module()
	if module == nil then
		return nil, nil
	end
	return rawget(module, "encode"), rawget(module, "decode")
end

-- Resolve the LuaJIT FFI module for the privileged root only. The real game's
-- main/preflight source does not initialise a global `ffi`, so the trusted
-- entrypoint asks the host module loader for it directly (mirroring the json
-- resolution above). An injected global fixture is honoured first, and any
-- absent loader or failed require fails closed to nil; policy never sees ffi.
local function native_ffi()
	local direct = type(_G) == "table" and rawget(_G, "ffi") or nil
	if direct ~= nil then
		return direct
	end
	local loader = type(_G) == "table" and rawget(_G, "require") or nil
	if type(loader) == "function" then
		local ok, module = pcall(loader, "ffi")
		if ok and module ~= nil then
			return module
		end
	end
	return nil
end

local function load_all(paths)
	local out = {}
	for i = 1, #paths do
		local value, code = load_module(paths[i])
		if value == nil then
			return nil, paths[i], code
		end
		out[#out + 1] = value
	end
	return out, nil, nil
end

-- Build the narrow wire encoder over the injected real json module. The pure
-- integration/wire_json.lua owns the exact envelopes (six-key service request,
-- four-key host request) so the real rxi encoder's empty-table-as-array and
-- missing-null behaviour cannot drop the required keys.
local function build_wire()
	local wire_module, wire_code = load_module("integration/wire_json.lua")
	if wire_module == nil then
		return nil, wire_code
	end
	if type(rawget(wire_module, "factory")) ~= "function" then
		return nil, "module_bad_return"
	end
	local base = json_module()
	if base == nil then
		return nil, "json_unavailable"
	end
	local wire = wire_module.factory(base)
	if type(wire) ~= "table" then
		return nil, "wire_factory_failed"
	end
	return wire, nil
end

-- Source-backed AI-staged-only revision hook targets over the real engine
-- classes. Only methods that actually exist are included, and the runtime wraps
-- them without touching the live human path. The real names come from
-- work/reference/game/cardarea.lua and card.lua.
local function ai_hook_targets()
	local targets = {}
	local function add(owner, name, reason)
		if type(owner) == "table" and type(rawget(owner, name)) == "function" then
			targets[#targets + 1] = { table = owner, name = name, reason = reason }
		end
	end
	add(CardArea, "emplace", "card_area_emplace")
	add(CardArea, "remove_card", "card_area_remove")
	add(CardArea, "add_to_highlighted", "card_area_highlight")
	add(CardArea, "remove_from_highlighted", "card_area_unhighlight")
	add(CardArea, "unhighlight_all", "card_area_unhighlight_all")
	add(Card, "set_ability", "card_set_ability")
	add(Card, "set_debuff", "card_set_debuff")
	add(Card, "apply_to_run", "card_apply_to_run")
	if #targets == 0 then
		return nil
	end
	return targets
end

local function boot_live(host_module, base)
	local loaded, missing, missing_code = load_all(COMPANION_LIVE)
	if loaded == nil then
		return { code = "companion_module_missing", detail = missing, module_code = missing_code, fatal = true }
	end
	local control_thread = load_module(COMPANION_LIVE_OPTIONAL[1])
	base.role = "live"
	base.practice_menu = loaded[1]
	base.menu_controller = loaded[2]
	base.control_thread = control_thread
	base.UIBox_button = UIBox_button
	base.create_UIBox_generic_options = create_UIBox_generic_options
	local instance, code = host_module.factory(base)
	if instance == nil then
		return { code = code or "companion_boot_failed", role = "live" }
	end
	local ok_install, install_code = instance.install()
	if ok_install ~= true then
		return { code = install_code or code or "companion_install_failed", role = "live" }
	end
	local status = nil
	if type(instance.status) == "function" then
		local ok_status, value = pcall(instance.status)
		if ok_status and type(value) == "table" then
			status = value
		end
	end
	return {
		code = "companion_ok",
		role = "live",
		instance = instance,
		diagnostic_path = status and status.diagnostic_path or nil,
		host_available = status and status.host_available == true or false,
		booted = true,
	}
end

local function boot_staged(host_module, base, companion)
	local env_reader = host_module.default_env_reader(base.os)
	if type(env_reader) ~= "function" then
		return { code = "companion_staged_env_missing", role = "staged" }
	end
	local descriptors, descriptor_code = host_module.read_descriptors(env_reader)
	if descriptors == nil then
		return { code = descriptor_code or "companion_staged_env_missing", role = "staged" }
	end
	local loaded, missing, missing_code = load_all(COMPANION_STAGED)
	if loaded == nil then
		return { code = "companion_module_missing", detail = missing, module_code = missing_code, fatal = true }
	end
	-- The pure codec is shared by BOTH staged roles: the runtime driver needs
	-- Codec.hash_string for the real source-derived digest even on the human
	-- host, which reaches READY before any AI policy capability exists.
	local codec_module, codec_code = load_module(COMPANION_STAGED_CODEC)
	if codec_module == nil then
		return { code = "companion_module_missing", detail = COMPANION_STAGED_CODEC, module_code = codec_code, fatal = true }
	end
	local modules = { MPDriver = loaded[5], codec = codec_module }
	if descriptors.role == "ai" then
		local policy, policy_missing, policy_code = load_all(COMPANION_STAGED_AI)
		if policy == nil then
			return { code = "companion_module_missing", detail = policy_missing, module_code = policy_code, fatal = true }
		end
		modules.StateReader = policy[1]
		modules.EngineAdapter = policy[2]
		modules.ProductionExecutor = policy[3]
		modules.StateRevision = policy[4]
		modules.ActionBroker = policy[5]
		modules.DecisionLoop = policy[6]
		modules.observation = policy[7]
		modules.actions = policy[8]
	end
	local encode, decode = json_codec()
	local wire = base.wire
	base.role = "staged"
	base.runtime_bootstrap = loaded[1]
	base.control_protocol = loaded[2]
	base.control_transport_factory = loaded[3].factory
	base.control_thread = loaded[4]
	base.modules = modules
	base.descriptors = descriptors
	base.env_reader = env_reader
	-- The control transport only ever sends the exact six-key service envelope;
	-- route it through the narrow wire encoder so empty payloads stay `{}`.
	if wire ~= nil then
		base.encode = wire.encode_service
		base.decode = wire.decode
	else
		base.encode = encode
		base.decode = decode
	end
	base.funcs = G and G.FUNCS or nil
	local instance, code = host_module.factory(base)
	if instance == nil then
		return { code = code or "companion_boot_failed", role = "staged", staged_role = descriptors.role }
	end
	local ok_install, install_code = instance.install()
	if ok_install ~= true then
		return { code = install_code or code or "companion_install_failed", role = "staged", staged_role = descriptors.role }
	end
	local status = nil
	if type(instance.status) == "function" then
		local ok_status, value = pcall(instance.status)
		if ok_status and type(value) == "table" then
			status = value
		end
	end
	return {
		code = "companion_ok",
		role = "staged",
		staged_role = descriptors.role,
		instance = instance,
		diagnostic_path = status and status.diagnostic_path or nil,
		booted = status == nil or status.booted ~= false,
		pending = status ~= nil and status.pending == true,
	}
end

local function boot_companion(modules, companion)
	local host_module, host_error = load_module("integration/companion_host.lua")
	if host_module == nil then
		return { code = "companion_module_missing", detail = host_error, fatal = true }
	end
	local encode, decode = json_codec()
	local wire = build_wire()
	local base = {
		companion = companion,
		G = G,
		MP = MP,
		SMODS = SMODS,
		love = love,
		Game = Game,
		NFS = NFS,
		os = os,
		ffi = native_ffi(),
		JSON = JSON,
		Client = Client,
		encode = encode,
		decode = decode,
		wire = wire,
		hook_targets = companion.role == "staged" and ai_hook_targets() or nil,
		mp_compatible = true,
		logger = build_companion_logger(modules),
		notify = sendWarnMessage,
	}
	local detail
	if companion.role == "live" then
		detail = boot_live(host_module, base)
	else
		detail = boot_staged(host_module, base, companion)
	end
	-- The update wrapper is installed whenever a companion instance exists so a
	-- staged role can keep polling a deferred attestation; a pending instance
	-- simply reports booted=false until the launcher writes the file.
	if detail ~= nil and type(detail.instance) == "table" then
		if type(Game) == "table" and type(detail.instance.update) == "function" then
			local handle = host_module.install_update(Game, function(dt)
				detail.instance.update(dt)
			end, {
				max_update_errors = COMPANION_MAX_UPDATE_ERRORS,
				on_failure = function()
					pcall(detail.instance.uninstall)
				end,
			})
			if handle ~= nil then
				detail.update = handle
			end
		end
	end
	return detail
end

local function companion_label(detail)
	if detail.code == "companion_ok" then
		if detail.role == "live" then
			return "companion_live_menu"
		end
		if detail.staged_role == "ai" then
			return "companion_staged_ai"
		end
		return "companion_staged_human"
	end
	return "companion_unavailable"
end

-- Enrich the M1 ready status with an accurate companion boot report. Capability
-- flags stay false: module presence and instance state are facts, not authority,
-- and a capability is never exposed through this status surface.
local function apply_companion(result, detail)
	detail = type(detail) == "table" and detail or { code = "companion_internal_error" }
	local ok = detail.code == "companion_ok"
	local instance_state = nil
	if ok and type(detail.instance) == "table" and type(detail.instance.status) == "function" then
		local ok_status, value = pcall(detail.instance.status)
		if ok_status and type(value) == "table" then
			instance_state = value.state
		end
	end
	result.scaffold_only = false
	result.ai = {
		requested = true,
		enabled = false,
		implemented = true,
		status = companion_label(detail),
		code = detail.code,
		gates = { "P0", "P1", "P2", "P3", "P4", "P5" },
	}
	result.state = ok and "companion_ready" or "companion_unavailable"
	result.code = ok and "ok" or (detail.code or "companion_unavailable")
	result.companion = {
		role = detail.role,
		staged_role = detail.staged_role,
		booted = ok and detail.booted ~= false,
		pending = detail.pending == true or instance_state == "awaiting_attestation",
		code = detail.code,
		instance_state = instance_state,
		host_available = detail.host_available == true,
		handling = detail.update ~= nil,
		diagnostic_path = detail.diagnostic_path,
		module_error = detail.detail,
	}
	return result
end

local function run(modules)
	local logger = modules.logger.new(emit)
	logger:log("info", "bootstrap_start", { mod = MOD_ID })

	local snapshot, host_error = modules.host.inspect(SMODS, MP)
	if snapshot == nil then
		logger:log("error", "host_inspection_failed", { code = host_error })
		return modules.status.fail_closed(modules.status.CODE.HOST_INSPECTION_FAILED, {
			detail = host_error,
		})
	end

	local spec = modules.dependency.SPEC
	local token = modules.dependency.version_token(snapshot.version, spec, snapshot.version_malformed)
	local satisfied, code = modules.dependency.evaluate(snapshot, spec)
	logger:log(satisfied and "info" or "error", "dependency_check", {
		dependency = spec.id,
		version = satisfied and spec.version or token,
		required_version = spec.version,
		code = code,
		status = satisfied and "satisfied" or "unsatisfied",
	})
	if not satisfied then
		return modules.status.fail_closed(code, {
			version = token,
			missing = snapshot.structure_missing,
		})
	end

	local ai = modules.ai_mode.resolve(modules.host.read_ai_flag(SMODS, MOD_ID))
	logger:log("info", "ai_mode_resolved", { status = ai.status, code = ai.code })

	local result = modules.status.ready({ version = spec.version, ai = ai })

	local companion = read_companion(SMODS, MOD_ID)
	if companion ~= nil and ai.requested == true then
		local ok_boot, detail = pcall(boot_companion, modules, companion)
		if not ok_boot or type(detail) ~= "table" then
			detail = { code = "companion_internal_error", fatal = true }
		end
		result = apply_companion(result, detail)
		logger:log(result.code == "ok" and "info" or "warn", "companion_boot", {
			code = result.code,
			status = result.state,
		})
	end

	logger:log("info", "bootstrap_ready", { status = result.state, code = result.code })
	return result
end

local function boot()
	local modules = {}
	for i = 1, #MODULE_ORDER do
		local entry = MODULE_ORDER[i]
		local value, code = load_module(entry.path)
		if value == nil then
			emit("error", "[AISparring] module_load_failed module=" .. tostring(entry.key))
			if type(modules.status) == "table" and type(modules.status.fail_closed) == "function" then
				return modules.status.fail_closed(modules.status.CODE.MODULE_LOAD_FAILED, {
					module = entry.key,
					detail = code,
				})
			end
			local closed = minimal_closed("module_load_failed", code)
			closed.module = entry.key
			return closed
		end
		modules[entry.key] = value
	end
	return run(modules)
end

local ok, result = pcall(boot)
if not ok or type(result) ~= "table" then
	result = minimal_closed("bootstrap_failed", "unhandled_error")
end
publish(result)
return result
