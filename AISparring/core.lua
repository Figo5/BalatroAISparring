local MOD_ID = "AISparring"

local MODULE_ORDER = {
	{ key = "status", path = "src/status.lua" },
	{ key = "logger", path = "src/logger.lua" },
	{ key = "ai_mode", path = "src/ai_mode.lua" },
	{ key = "dependency", path = "src/dependency.lua" },
	{ key = "host", path = "src/host.lua" },
}

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
