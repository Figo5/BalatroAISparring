local Logger = {}

Logger.MAX_STRING = 96
Logger.ALLOWED_FIELDS = {
	"event", "code", "status", "dependency", "version", "required_version",
	"detail", "module", "mod", "count", "phase", "action", "seconds",
	-- Bounded, secret-free boot-time host readiness code (for example
	-- companion_ok / companion_marker_absent): whether the AI Sparring Play
	-- entry would open settings or the unavailable diagnostic. It does not
	-- explain a missing entry.
	"host_available_code",
}
Logger.LEVELS = { info = true, warn = true, error = true, debug = true }

local ESCAPES = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local allowed = {}
for i = 1, #Logger.ALLOWED_FIELDS do
	allowed[Logger.ALLOWED_FIELDS[i]] = true
end

local function primitive(value)
	local kind = type(value)
	return kind == "string" or kind == "number" or kind == "boolean"
end

local function encode(value)
	local text
	if type(value) == "string" then
		text = value
	else
		text = tostring(value)
	end
	if #text > Logger.MAX_STRING then
		text = text:sub(1, Logger.MAX_STRING) .. "..."
	end
	text = text:gsub("[\\\"\n\r\t]", ESCAPES)
	text = text:gsub("%c", function(char)
		return string.format("\\x%02X", string.byte(char))
	end)
	return "\"" .. text .. "\""
end

function Logger.is_allowed_field(key)
	return allowed[key] == true
end

function Logger.format(event, fields)
	local parts = { "event=" .. encode(event) }
	for i = 1, #Logger.ALLOWED_FIELDS do
		local key = Logger.ALLOWED_FIELDS[i]
		if key ~= "event" then
			local value = fields[key]
			if primitive(value) then
				parts[#parts + 1] = key .. "=" .. encode(value)
			end
		end
	end
	return "[AISparring] " .. table.concat(parts, " ")
end

function Logger.new(sink)
	local logger = { has_sink = type(sink) == "function" }

	function logger:describe()
		local fields = {}
		for i = 1, #Logger.ALLOWED_FIELDS do
			fields[i] = Logger.ALLOWED_FIELDS[i]
		end
		return {
			max_string = Logger.MAX_STRING,
			allowed_fields = fields,
			has_sink = self.has_sink,
		}
	end

	function logger:log(level, event, fields)
		local record = { ok = false, emitted = false, dropped = 0 }
		if type(event) ~= "string" or event == "" then
			record.error = "invalid_event"
			return record
		end
		if not Logger.LEVELS[level] then
			level = "info"
		end
		fields = type(fields) == "table" and fields or {}
		local clean = { event = event }
		for key, value in pairs(fields) do
			if type(key) == "string" and Logger.is_allowed_field(key) and primitive(value) then
				clean[key] = value
			else
				record.dropped = record.dropped + 1
			end
		end
		clean.event = event
		if not self.has_sink then
			record.error = "no_sink"
			return record
		end
		local ok = pcall(sink, level, Logger.format(event, clean))
		if not ok then
			record.error = "sink_error"
			return record
		end
		record.ok = true
		record.emitted = true
		return record
	end

	return logger
end

return Logger
