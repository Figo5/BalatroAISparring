return function(ctx)
	local test, eq, repo = ctx.test, ctx.eq, ctx.repo_root

	local Logger = dofile(repo .. "/AISparring/src/logger.lua")

	test("emits quoted allowlisted fields", function()
		local captured = {}
		local logger = Logger.new(function(level, message)
			captured[#captured + 1] = message
		end)
		local record = logger:log("info", "dependency_check", {
			version = "0.5.5",
			code = "ok",
			secret = "should-not-appear",
			detail = {},
		})
		eq(record.ok, true, "ok")
		eq(record.emitted, true, "emitted")
		eq(record.dropped, 2, "dropped count")
		local message = captured[1]
		eq(message:find('version="0.5.5"', 1, true) ~= nil, true, "quoted version")
		eq(message:find("secret", 1, true), nil, "no secret")
		eq(message:find('event="dependency_check"', 1, true) ~= nil, true, "quoted event")
	end)

	test("escapes newlines and control characters", function()
		local captured = {}
		local logger = Logger.new(function(_, message)
			captured[#captured + 1] = message
		end)
		logger:log("error", "bad\nlevel=error fake", {
			version = "0.5.4\r\nlevel=error",
			detail = "quote\" here",
		})
		local message = captured[1]
		eq(message:find("\n", 1, true), nil, "no real newline")
		eq(message:find("\r", 1, true), nil, "no carriage return")
		eq(message:find('\\n', 1, true) ~= nil, true, "escaped newline present")
		eq(message:find('\\"', 1, true) ~= nil, true, "escaped quote present")
		local lines = 0
		for _ in tostring(message):gmatch("\n") do
			lines = lines + 1
		end
		eq(lines, 0, "single line")
	end)

	test("truncates long values", function()
		local captured = {}
		local logger = Logger.new(function(_, message)
			captured[#captured + 1] = message
		end)
		local long = string.rep("A", 400)
		logger:log("info", "x", { version = long })
		eq(captured[1]:find(long, 1, true), nil, "long value truncated")
	end)

	test("contains sink errors", function()
		local logger = Logger.new(function()
			error("sink boom")
		end)
		local record = logger:log("info", "x", {})
		eq(record.ok, false, "not ok")
		eq(record.emitted, false, "not emitted")
		eq(record.error, "sink_error", "sink error code")
	end)

	test("missing sink is safe", function()
		local logger = Logger.new(nil)
		local record = logger:log("info", "x", {})
		eq(record.ok, false, "not ok")
		eq(record.error, "no_sink", "no sink code")
		eq(logger:describe().has_sink, false, "describe")
	end)

	test("invalid event is rejected", function()
		local logger = Logger.new(function() end)
		eq(logger:log("info", "", {}).ok, false, "empty event")
		eq(logger:log("info", nil, {}).ok, false, "nil event")
	end)
end
