-- Identity adapter fixtures for `CompanionHost.default_identity`.
--
-- The real acceptance of a genuine LuaJIT FFI library (userdata/cdata symbols)
-- against the live kernel32 query lives in tests/astra_native_identity.py, which
-- the root runs read-only against this process only. These fixtures drive the
-- same adapter over a controllable ffi port to prove the fail-closed behaviour
-- around missing modules/symbols, failed loads and failed queries, and that the
-- query-only handle is always released. No OS call, process, game, socket or
-- thread is involved.
return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local host_module = support.host(ctx.repo_root)

	local EPOCH_DELTA = 11644473600
	local QUERY_LIMITED = 0x1000

	local function expected_seconds(ticks)
		return (ticks / 10000000) - EPOCH_DELTA
	end

	test("a missing or partial ffi port fails closed", function()
		eq(host_module.default_identity({}), nil, "no port")
		eq(host_module.default_identity({ ffi = "nope" }), nil, "non-table ffi")
		eq(host_module.default_identity({ ffi = {} }), nil, "empty ffi")
		eq(host_module.default_identity({ ffi = { cdef = function() end, load = function() end } }), nil, "no new")
	end)

	test("a failed or wrong-typed library load fails closed", function()
		local load_error = support.fake_ffi({ load_error = true })
		eq(host_module.default_identity({ ffi = load_error }), nil, "load raises")

		local lib_nil = support.fake_ffi({ libnil = true })
		eq(host_module.default_identity({ ffi = lib_nil }), nil, "load returns nil")

		local wrong = support.fake_ffi({ library = "not_a_library" })
		eq(host_module.default_identity({ ffi = wrong }), nil, "load returns a string")
	end)

	test("any missing kernel32 symbol fails closed", function()
		for _, name in ipairs({ "OpenProcess", "GetProcessTimes", "CloseHandle", "GetCurrentProcessId" }) do
			local ffi = support.fake_ffi({ missing = name })
			eq(host_module.default_identity({ ffi = ffi }), nil, "missing " .. name)
		end
	end)

	test("a real-shaped query binds the current process and releases the handle", function()
		local ticks = 50000000
		local ffi, state = support.fake_ffi({ current_pid = 1234, ticks = ticks })
		local identity = host_module.default_identity({ ffi = ffi })
		is_true(identity ~= nil, "adapter built")
		eq(state.cdefs, 1, "cdef declared once")

		local current = identity.current()
		eq(current.pid, 1234, "current pid")
		is_true(math.abs(current.create_time - expected_seconds(ticks)) < 1e-6, "creation time")
		eq(#state.closes, 1, "handle released")

		local again = identity.process(1234)
		is_true(again ~= nil, "self query")
		eq(again.create_time, current.create_time, "stable creation time")
		eq(#state.closes, 2, "handle released again")
		eq(state.opens[1].access, QUERY_LIMITED, "query-only access, never terminate")
	end)

	test("a failed query returns nil but still releases the handle", function()
		local ffi, state = support.fake_ffi({ result = 0 })
		local identity = host_module.default_identity({ ffi = ffi })
		is_true(identity ~= nil, "adapter built")
		eq(identity.process(1234), nil, "no identity on failure")
		eq(#state.closes, 1, "handle released on failed query")
	end)

	test("a throwing query returns nil but still releases the handle", function()
		local ffi, state = support.fake_ffi({ raise_query = true })
		local identity = host_module.default_identity({ ffi = ffi })
		is_true(identity ~= nil, "adapter built")
		eq(identity.process(1234), nil, "no identity when the query throws")
		eq(#state.closes, 1, "handle released after a throwing query")
	end)

	test("a null process handle is refused without a spurious close", function()
		local ffi, state = support.fake_ffi({ handle = false })
		local identity = host_module.default_identity({ ffi = ffi })
		eq(identity.process(1234), nil, "null handle refused")
		eq(#state.closes, 0, "nothing to close")
		eq(#state.opens, 1, "open attempted once")
	end)

	test("invalid pids are refused before any handle is opened", function()
		local ffi, state = support.fake_ffi()
		local identity = host_module.default_identity({ ffi = ffi })
		for _, pid in ipairs({ -1, 0, 1.5, 4294967296 }) do
			eq(identity.process(pid), nil, "rejected pid " .. tostring(pid))
		end
		eq(identity.process("not-a-pid"), nil, "rejected non-number pid")
		eq(identity.process(nil), nil, "rejected nil pid")
		eq(#state.opens, 0, "no OpenProcess for invalid pids")
	end)

	test("an invalid current pid fails closed", function()
		local ffi = support.fake_ffi({ current_pid = 0 })
		local identity = host_module.default_identity({ ffi = ffi })
		eq(identity.current(), nil, "no current identity")
		eq(identity.process(1234) ~= nil, true, "explicit pid still works")
	end)
end
