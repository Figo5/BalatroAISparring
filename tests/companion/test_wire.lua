-- Exercises the pure wire encoder against the ACTUAL supported game JSON
-- library (the read-only SMODS/rxi copy), never the fixture codec that hides the
-- empty-table-as-array and missing-null behaviour.
return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local support = ctx.support

	local smods = support.load(ctx.repo_root, "work/reference/offline/smods-json.lua")
	local WireJson = support.load(ctx.repo_root, "AISparring/integration/wire_json.lua")
	local wire, code = WireJson.factory(smods)

	local function has(text, needle)
		return string.find(text, needle, 1, true) ~= nil
	end

	test("the real SMODS json library encodes an empty table as []", function()
		eq(smods.encode({}), "[]", "empty table is an array")
		eq(smods.encode("x"), '"x"', "string")
		eq(smods.decode('{"a":1}').a, 1, "decode object")
	end)

	test("the wire module builds over the real codec", function()
		is_true(wire ~= nil, "wire")
		eq(code, WireJson.CODE.OK, "code")
	end)

	test("service envelope keeps observation as {} and exactly six keys", function()
		local text = wire.encode_service({
			session = "s",
			credential = "c",
			role = "ai",
			op = "hello",
			sequence = 1,
			observation = {},
		})
		is_true(text ~= nil, "encoded")
		is_true(has(text, '"observation":{}'), "observation object")
		is_true(not has(text, '"observation":[]'), "never an array")
		local decoded = smods.decode(text)
		local obs_count = 0
		for _ in pairs(decoded.observation) do
			obs_count = obs_count + 1
		end
		eq(obs_count, 0, "roundtrip observation object")
		local count = 0
		for _ in pairs(decoded) do
			count = count + 1
		end
		eq(count, 6, "six keys")
	end)

	test("nested observation array semantics are unchanged", function()
		local text = wire.encode_service({
			session = "s",
			credential = "c",
			role = "ai",
			op = "decide_begin",
			sequence = 2,
			observation = { acts = { "A", "B" } },
		})
		is_true(has(text, '"acts":["A","B"]'), "array preserved")
	end)

	test("service envelope rejects unknown, missing and wrongly typed keys", function()
		local base = { session = "s", credential = "c", role = "ai", op = "hello", sequence = 1, observation = {} }
		local extra = { session = "s", credential = "c", role = "ai", op = "hello", sequence = 1, observation = {}, sneaky = 1 }
		eq(wire.encode_service(extra), nil, "unknown key")
		local missing = { session = "s", credential = "c", role = "ai", op = "hello", observation = {} }
		eq(wire.encode_service(missing), nil, "missing sequence")
		local bad = { session = "s", credential = "c", role = "ai", op = "hello", sequence = 1, observation = "no" }
		eq(wire.encode_service(bad), nil, "non-table observation")
		eq(wire.encode_service({}), nil, "empty")
		is_true(wire.encode_service(base) ~= nil, "valid still accepted")
	end)

	test("host request emits explicit null gauntlet and exactly seven request keys", function()
		local text = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "start",
			auth = "secret",
			request = {
				session_id = "s",
				difficulty = "rookie",
				pacing = "normal",
				mode = "normal",
				live_pid = 4242,
				live_create_time = 100000.0,
			},
		})
		is_true(text ~= nil, "encoded")
		is_true(has(text, '"gauntlet":null'), "explicit null")
		local decoded = smods.decode(text)
		eq(decoded.request.gauntlet, nil, "null decodes to nil")
		local count = 0
		for _ in pairs(decoded.request) do
			count = count + 1
		end
		eq(count, 6, "decoded keys minus null")
		local top = 0
		for _ in pairs(decoded) do
			top = top + 1
		end
		eq(top, 4, "four envelope keys")
	end)

	test("host request emits a gauntlet label and rejects unknown request keys", function()
		local text = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "start",
			auth = "secret",
			request = {
				session_id = "s",
				difficulty = "rookie",
				pacing = "normal",
				mode = "gauntlet",
				gauntlet = "Test3",
				live_pid = 1,
				live_create_time = 2.5,
			},
		})
		is_true(has(text, '"gauntlet":"Test3"'), "label")
		local bad = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "start",
			auth = "secret",
			request = {
				session_id = "s",
				difficulty = "rookie",
				pacing = "normal",
				mode = "normal",
				live_pid = 1,
				live_create_time = 2.5,
				extra = true,
			},
		})
		eq(bad, nil, "unknown request key")
	end)

	test("start request adds ONLY draft_id when present", function()
		local text = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "start",
			auth = "secret",
			request = {
				session_id = "s",
				difficulty = "competitive",
				pacing = "normal",
				mode = "normal",
				live_pid = 4242,
				live_create_time = 100000.0,
				draft_id = "draft-abc123",
			},
		})
		is_true(text ~= nil, "encoded")
		is_true(has(text, '"draft_id":"draft-abc123"'), "draft id emitted")
		is_true(has(text, '"gauntlet":null'), "gauntlet still explicit null")
		local decoded = smods.decode(text)
		local count = 0
		for _ in pairs(decoded.request) do
			count = count + 1
		end
		eq(count, 7, "seven decoded keys minus null")
	end)

	test("draft_begin emits an explicit null gauntlet", function()
		local text = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "draft_begin",
			auth = "secret",
			request = { difficulty = "competitive", pacing = "normal", mode = "normal" },
		})
		is_true(text ~= nil, "encoded")
		is_true(has(text, '"op":"draft_begin"'), "op")
		is_true(has(text, '"gauntlet":null'), "null gauntlet")
		local decoded = smods.decode(text)
		eq(decoded.request.difficulty, "competitive", "difficulty")
	end)

	test("draft_action emits the exact action keys and option array", function()
		local text = wire.encode_host({
			schema = "aisparring.practice_host.request.v1",
			op = "draft_action",
			auth = "secret",
			request = {
				draft_id = "draft-abc123",
				expected_revision = 2,
				request_id = "menu-2-2",
				operation = "ban",
				option_ids = { "blue~white", "black~white" },
			},
		})
		is_true(text ~= nil, "encoded")
		is_true(has(text, '"expected_revision":2'), "revision")
		is_true(has(text, '"option_ids":["blue~white","black~white"]'), "array")
		local decoded = smods.decode(text)
		eq(decoded.request.operation, "ban", "operation")
		eq(decoded.request.option_ids[2], "black~white", "second option")
	end)

	test("draft_cancel and draft_status carry exactly draft_id", function()
		for _, op in ipairs({ "draft_cancel", "draft_status" }) do
			local text = wire.encode_host({
				schema = "aisparring.practice_host.request.v1",
				op = op,
				auth = "secret",
				request = { draft_id = "draft-abc123" },
			})
			is_true(text ~= nil, op .. " encoded")
			local decoded = smods.decode(text)
			eq(decoded.request.draft_id, "draft-abc123", op .. " draft id")
			local count = 0
			for _ in pairs(decoded.request) do
				count = count + 1
			end
			eq(count, 1, op .. " one request key")
		end
	end)

	test("unknown host op and malformed draft request are refused", function()
		eq(wire.encode_host({
			schema = "s", op = "nope", auth = "a", request = {},
		}), nil, "unknown op")
		eq(wire.encode_host({
			schema = "s", op = "draft_status", auth = "a", request = { draft_id = "x", extra = 1 },
		}), nil, "unknown key")
		eq(wire.encode_host({
			schema = "s", op = "draft_action", auth = "a",
			request = { draft_id = "x", expected_revision = 1, request_id = "r", operation = "ban", option_ids = {} },
		}), nil, "empty option array refused")
	end)

	test("decode is the real codec and factory needs encode+decode", function()
		eq(wire.decode('{"a":1}').a, 1, "decode passthrough")
		local missing = WireJson.factory({ encode = smods.encode })
		eq(missing, nil, "no decode")
	end)
end
