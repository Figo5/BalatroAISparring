-- Live discovery-read resilience regressions (the production path the menu
-- availability gate actually uses, and which most companion tests bypass with an
-- injected `read_discovery`).
--
-- The real installed Steamodded `nativefs.getInfo` mounts the containing
-- directory into LÖVE's virtual filesystem with a PHYSFS temporary mount
-- (`withTempMount`), while `nativefs.read` opens the file directly through the C
-- runtime (`_wfopen`). They are independent failure domains, so `read` is made
-- the source of truth and `getInfo` is only a presence hint that may refuse a
-- definite non-file. This is resilience hardening, NOT a proven live cause: an
-- isolated native probe of the exact installed build with a fresh matching
-- marker showed getInfo and read both succeeding and the AI button present
-- (work/local-ownership/live-menu-native-short/pre-fix-native-result.json). The
-- marker is still validated in full afterwards by `inspect_marker`.
return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support
	local host_module = support.host(ctx.repo_root)
	local CODE = host_module.CODE

	local DISCOVERY = "C:/repo/work/aisparring-host/practice_host.json"
	local MARKER_TEXT = '{"schema":"aisparring.practice_host.discovery.v1"}'

	local function build_host(nfs, overrides)
		overrides = overrides or {}
		local ports = {
			companion = { role = "live", discovery_path = overrides.discovery_path or DISCOVERY },
			NFS = nfs,
			decode = overrides.decode or function()
				return support.marker()
			end,
			identity = overrides.identity or support.identity(),
			transport = support.transport(),
			encode = support.encoder({}),
			json_null = support.NULL,
			JSON = {},
			quit = function()
				return true
			end,
		}
		local host, code = host_module.live_host(ports)
		is_true(host ~= nil, "host built: " .. tostring(code))
		return host
	end

	-- The real nativefs read is authoritative. A directory temp-mount failure
	-- (getInfo nil) must not hide a readable, fully valid marker.
	test("readable marker is available even when getInfo temp-mount fails", function()
		local host = build_host({
			getInfo = function()
				return nil
			end,
			read = function()
				return MARKER_TEXT
			end,
		})
		eq(host.available(), true, "direct read is authoritative")
		local ok, code = host.available_detail()
		eq(ok, true, "detail true")
		eq(code, CODE.OK, "ok code")
	end)

	test("getInfo that is absent, false, non-table or throwing cannot hide a readable marker", function()
		local variants = {
			{ name = "nil", fn = function() return nil end },
			{ name = "false", fn = function() return false end },
			{ name = "true", fn = function() return true end },
			{ name = "number", fn = function() return 7 end },
			{ name = "string", fn = function() return "file" end },
			{ name = "throwing", fn = function() error("getInfo exploded") end },
		}
		for i = 1, #variants do
			local host = build_host({
				getInfo = variants[i].fn,
				read = function()
					return MARKER_TEXT
				end,
			})
			eq(host.available(), true, "readable marker with getInfo=" .. variants[i].name)
		end
	end)

	test("nfs_reader itself never raises over malformed getInfo/read/decode", function()
		local cases = {
			function() return { getInfo = function() return nil end, read = function() return nil end } end,
			function() return { getInfo = function() return false end, read = function() return "" end } end,
			function() return { getInfo = function() error("x") end, read = function() error("y") end } end,
		}
		for i = 1, #cases do
			local nfs = cases[i]()
			local reader = host_module.nfs_reader(nfs, function()
				return nil
			end)
			local ok, value = pcall(reader, DISCOVERY)
			eq(ok, true, "reader did not raise on case " .. tostring(i))
			eq(value, nil, "reader returned nil on case " .. tostring(i))
		end
		-- A non-function decode still fails closed by refusing to build.
		eq(host_module.nfs_reader({ read = function() return MARKER_TEXT end }, "nope"), nil, "non-function decode")
	end)

	test("available still works when getInfo and read both succeed", function()
		local host = build_host({
			getInfo = function()
				return { type = "file" }
			end,
			read = function()
				return MARKER_TEXT
			end,
		})
		eq(host.available(), true, "normal path")
	end)

	test("an unreadable or empty marker fails closed", function()
		eq(build_host({ getInfo = function() return { type = "file" } end, read = function() return nil end }).available(), false, "nil read")
		eq(build_host({ getInfo = function() return nil end, read = function() return "" end }).available(), false, "empty read")
		eq(build_host({ getInfo = function() return nil end, read = function() error("boom") end }).available(), false, "throwing read")
	end)

	test("a decode failure fails closed and reports the bounded reason", function()
		local host = build_host({
			getInfo = function() return nil end,
			read = function() return MARKER_TEXT end,
		}, {
			decode = function()
				error("bad json")
			end,
		})
		eq(host.available(), false, "decode failure")
		local ok, code = host.available_detail()
		eq(ok, false, "detail false")
		eq(code, CODE.MARKER_ABSENT, "absent reason")
	end)

	test("the read-first path still validates the marker schema", function()
		local host = build_host({
			getInfo = function() return nil end,
			read = function() return MARKER_TEXT end,
		}, {
			decode = function()
				return support.marker({ schema = "wrong" })
			end,
		})
		eq(host.available(), false, "bad schema rejected")
		local ok, code = host.available_detail()
		eq(ok, false, "detail false")
		eq(code, CODE.MARKER_SCHEMA, "schema reason")
	end)

	test("a stale identity still reports the identity reason", function()
		local host = build_host({
			getInfo = function() return nil end,
			read = function() return MARKER_TEXT end,
		}, {
			identity = support.identity({ create_time = 999999.0 }),
		})
		local ok, code = host.available_detail()
		eq(ok, false, "stale identity unavailable")
		eq(code, CODE.IDENTITY_STALE, "stale reason")
	end)

	test("a getInfo that reports a directory still refuses", function()
		local host = build_host({
			getInfo = function()
				return { type = "directory" }
			end,
			read = function()
				return MARKER_TEXT
			end,
		})
		eq(host.available(), false, "directory is not a marker")
		local ok, code = host.available_detail()
		eq(ok, false, "detail false")
		eq(code, CODE.MARKER_ABSENT, "absent reason")
	end)

	test("nfs_reader decodes the readable file and nothing else", function()
		local reader = host_module.nfs_reader(
			{ getInfo = function() return nil end, read = function() return MARKER_TEXT end },
			function(text)
				eq(text, MARKER_TEXT, "raw text")
				return support.marker()
			end
		)
		is_true(type(reader) == "function", "reader built")
		is_true(reader(DISCOVERY) ~= nil, "decoded")

		eq(host_module.nfs_reader(nil, function() return nil end), nil, "no nfs")
		eq(host_module.nfs_reader({}, function() return nil end), nil, "no read")
		eq(host_module.nfs_reader({ read = function() end }, nil), nil, "no decode")
	end)
end
