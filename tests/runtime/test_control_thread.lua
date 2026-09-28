return function(ctx)
	local support = ctx.support
	local ControlThread = support.mod(ctx.repo_root, "AISparring/integration/control_thread.lua")
	local test = ctx.test

	test("source_requires_bundled_json_and_socket", function()
		ctx.is_true(string.find(ControlThread.SOURCE, 'require("json")', 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, 'require("socket")', 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, "127.0.0.1", 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, '"stop"', 1, true) ~= nil)
	end)

	test("source_bounds_send_and_receive", function()
		ctx.is_true(string.find(ControlThread.SOURCE, "MAX_SEND", 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, "MAX_RECEIVE", 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, "control_send_too_large", 1, true) ~= nil)
		ctx.is_true(string.find(ControlThread.SOURCE, "control_receive_too_large", 1, true) ~= nil)
	end)

	test("channel_names_are_nonce_and_role_scoped", function()
		local names = ControlThread.channel_names("nonce1", "ai")
		ctx.eq(names.to_worker, "aisp_ctrl_nonce1_ai_tw")
		ctx.eq(names.from_worker, "aisp_ctrl_nonce1_ai_fw")
		local human = ControlThread.channel_names("nonce1", "human")
		ctx.eq(human.to_worker, "aisp_ctrl_nonce1_human_tw")
		local bad, code = ControlThread.channel_names("bad-nonce!", "ai")
		ctx.eq(bad, nil)
		ctx.eq(code, "control_thread_bad_channel")
		local bad_role, role_code = ControlThread.channel_names("nonce1", "live")
		ctx.eq(bad_role, nil)
		ctx.eq(role_code, "control_thread_bad_channel")
	end)

	test("start_validates_ports_and_spawns_once", function()
		local starts = 0
		local fake_love_thread = {
			newThread = function(source)
				ctx.is_true(type(source) == "string")
				return {
					start = function(_, port, to_worker, from_worker)
						starts = starts + 1
						ctx.eq(port, 8788)
						ctx.eq(to_worker, "aisp_ctrl_nonce1_ai_tw")
						ctx.eq(from_worker, "aisp_ctrl_nonce1_ai_fw")
					end,
				}
			end,
		}
		local thread, code = ControlThread.start(fake_love_thread, 8788, "aisp_ctrl_nonce1_ai_tw", "aisp_ctrl_nonce1_ai_fw")
		ctx.eq(code, nil)
		ctx.is_true(thread ~= nil)
		ctx.eq(starts, 1)
		local bad, bad_code = ControlThread.start(fake_love_thread, 0, "a", "b")
		ctx.eq(bad, nil)
		ctx.eq(bad_code, "control_thread_bad_ports")
	end)
end
