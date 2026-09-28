-- Trusted, monotonic decision-state revision.
--
-- The reader only *validates* that a runtime epoch is a non-negative int32 and
-- that the view epoch equals the runtime epoch. The broker only *observes*
-- revisions reported by `ports.capture`. This module is the trusted producer
-- side of that contract: it owns a single monotonically increasing epoch for one
-- staged session and advances it whenever decision-relevant state changes.
--
-- Honest scope (docs/STATE_READER.md 3.1, docs/M2_EXECUTION_BOUNDARY.md 1.4):
--
--   * `sync(fingerprint)` advances only when the fingerprint changes. It detects
--     an *observed* A -> B -> A change (the two captures differ) but cannot detect
--     a change and change-back that happened entirely between two captures.
--   * `bump(reason)` is the forced, strictly-increasing path for trusted engine
--     change hooks. A caller that owns such a hook must call it on *every*
--     decision-relevant change, including a revert.
--
-- No unobserved-ABA magic is claimed. A monotonic frame/snapshot counter would
-- be wrong and is deliberately not provided.
--
-- This module is globals-free: it references no game globals, no require/dofile,
-- no io/os/debug and no RNG.

local StateRevision = {}

StateRevision.CODE = {
	OK = "revision_ok",
	BAD_OPTIONS = "revision_bad_options",
	BAD_FINGERPRINT = "revision_bad_fingerprint",
	BAD_REASON = "revision_bad_reason",
	OVERFLOW = "revision_overflow",
	INTERNAL = "revision_internal_error",
}

local CODE = StateRevision.CODE

local INT_MAX = 2147483647
local MAX_FINGERPRINT = 262144
local MAX_REASON = 64
local TOKEN_PATTERN = "^[0-9A-Za-z_%.-]+$"

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
	return value >= 0 and value <= INT_MAX
end

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function token_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, TOKEN_PATTERN) == nil then
		return nil
	end
	return value
end

local function copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

StateRevision.CODE = copy(CODE)

function StateRevision.factory(options)
	local limit = INT_MAX
	local start = 0
	if options ~= nil then
		if not is_plain(options) then
			return nil, CODE.BAD_OPTIONS
		end
		local option_limit = rawget(options, "limit")
		if option_limit ~= nil then
			if not is_int(option_limit) or option_limit < 1 then
				return nil, CODE.BAD_OPTIONS
			end
			limit = option_limit
		end
		local option_start = rawget(options, "start")
		if option_start ~= nil then
			if not is_int(option_start) or option_start > limit then
				return nil, CODE.BAD_OPTIONS
			end
			start = option_start
		end
	end

	local instance = {}
	local epoch = start
	local fingerprint = nil

	-- Over-advancing is safe (it only makes a decision look staler); the
	-- fingerprint is deliberately left untouched so a subsequent `sync` of
	-- unchanged content does not double-count.
	local function advance()
		if epoch >= limit then
			return nil, CODE.OVERFLOW
		end
		epoch = epoch + 1
		return epoch
	end

	function instance.bump(reason)
		local ok, result, code = pcall(function()
			local token = token_of(reason, MAX_REASON)
			if token == nil then
				return nil, CODE.BAD_REASON
			end
			return advance()
		end)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	function instance.sync(value)
		local ok, result, code = pcall(function()
			if type(value) ~= "string" or #value == 0 or #value > MAX_FINGERPRINT then
				return nil, CODE.BAD_FINGERPRINT
			end
			if fingerprint ~= nil and fingerprint == value then
				return epoch
			end
			fingerprint = value
			return advance()
		end)
		if not ok then
			return nil, CODE.INTERNAL
		end
		return result, code
	end

	function instance.current()
		return epoch
	end

	function instance.describe()
		return {
			epoch = epoch,
			limit = limit,
			has_fingerprint = fingerprint ~= nil,
			codes = copy(CODE),
		}
	end

	return instance
end

return StateRevision
