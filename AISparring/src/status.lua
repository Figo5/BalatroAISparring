local Status = {}

Status.MOD_ID = "AISparring"
Status.STATE_READY = "scaffold_ready"
Status.STATE_FAIL_CLOSED = "fail_closed"

Status.CODE = {
	OK = "ok",
	MODULE_LOAD_FAILED = "module_load_failed",
	BOOTSTRAP_FAILED = "bootstrap_failed",
	HOST_INSPECTION_FAILED = "host_inspection_failed",
}

local function copy_list(source)
	local out = {}
	if type(source) == "table" then
		for i = 1, #source do
			out[i] = source[i]
		end
	end
	return out
end

local function base()
	return {
		scaffold = Status.MOD_ID,
		scaffold_only = true,
		observation_extractor = false,
		policy = false,
		ai = {
			requested = false,
			enabled = false,
			implemented = false,
			status = "disabled_default_off",
		},
		capabilities = {
			gameplay_hooks = false,
			content_registration = false,
			network_transport = false,
			opponent = false,
			launcher = false,
		},
		gates = { "P0", "P1", "P2", "P3", "P4", "P5" },
		manifest = {
			dependency_pin = "Multiplayer (==0.5.5)",
			priority = 10000001,
			skips_load_when_dependency_unmet = true,
		},
	}
end

local function dependency(compatible, version)
	return {
		id = "Multiplayer",
		supported_version = "0.5.5",
		inspected_version = version,
		compatible = compatible,
		identity_verified = compatible == true,
		compatibility = "structural-only",
		server_parity = "unproven",
	}
end

function Status.ready(detail)
	detail = detail or {}
	local result = base()
	result.state = Status.STATE_READY
	result.code = Status.CODE.OK
	result.dependency = dependency(true, detail.version)
	result.ai = detail.ai or base().ai
	return result
end

function Status.fail_closed(code, detail)
	detail = detail or {}
	local result = base()
	result.state = Status.STATE_FAIL_CLOSED
	result.code = code or Status.CODE.BOOTSTRAP_FAILED
	result.dependency = dependency(false, detail.version)
	if detail.module ~= nil then
		result.module = detail.module
	end
	if detail.detail ~= nil then
		result.detail = detail.detail
	end
	if type(detail.missing) == "table" then
		result.missing = copy_list(detail.missing)
	end
	return result
end

return Status
