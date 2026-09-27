local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then
		return nil
	end
	local content = handle:read("*a")
	handle:close()
	return content
end

return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local repo = ctx.repo_root

	local helper = dofile(repo .. "/tools/lua/policy_env.lua")
	local codec_src = read_file(repo .. "/AISparring/ai/codec.lua")
	local observation_src = read_file(repo .. "/AISparring/ai/observation.lua")
	local actions_src = read_file(repo .. "/AISparring/ai/actions.lua")
	ctx.is_true(helper.configure(codec_src, observation_src, actions_src) == true, "configure")

	local env = Support.load(repo)
	local obs = env.observation.factory(env.codec)
	local handle = assert(obs.observe(Support.play_frame()))
	local export = assert(obs.export(handle))

	local function run(source, observation)
		return helper.run(source, observation or export)
	end

	test("policy_env_selects_valid_action", function()
		local result = run("return function(observation, actions) return actions[1] end")
		ctx.is_true(result.ok == true, "ok")
		ctx.eq(result.action.type, "PLAY_CARDS", "type")
	end)

	test("policy_env_accepts_index_selection", function()
		local result = run("return function(observation, actions) return 1 end")
		ctx.is_true(result.ok == true, "ok")
		ctx.eq(result.action.type, "PLAY_CARDS", "type")
	end)

	test("policy_env_sanitizes_hidden_fields", function()
		local poisoned = Support.deep_copy(export)
		poisoned.secret_token = "leak"
		poisoned.pvp_timer_order = { 1, 2 }
		poisoned.self.secret = "leak"
		poisoned.self.deck_order = { "hand:1" }
		local source = "return function(observation, actions) "
			.. "if observation.secret_token ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "if observation.pvp_timer_order ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "if observation.self.secret ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "if observation.self.deck_order ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end"
		local result = run(source, poisoned)
		ctx.is_true(result.ok == true, "sanitized")
		ctx.eq(result.action.type, "PLAY_CARDS", "type")
	end)

	test("policy_env_forged_action_rejected", function()
		local result = run("return function(observation, actions) return { type = 'LEAVE_SHOP' } end")
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_bad_action", "code")
	end)

	test("policy_env_candidate_mutation_rejected", function()
		local source = "return function(observation, actions) "
			.. "actions[1].card_refs[1] = 'hand:999' "
			.. "return actions[1] end"
		local result = run(source)
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_bad_action", "code")
	end)

	test("policy_env_escape_blocked", function()
		local source = "return function(observation, actions) "
			.. "local bad = (_G ~= nil) or (type(getfenv) ~= 'nil') or (type(setfenv) ~= 'nil') "
			.. "or (type(require) ~= 'nil') or (type(package) ~= 'nil') or (type(io) ~= 'nil') "
			.. "or (type(os) ~= 'nil') or (type(debug) ~= 'nil') or (type(G) ~= 'nil') "
			.. "or (type(MP) ~= 'nil') or (type(SMODS) ~= 'nil') or (type(Client) ~= 'nil') "
			.. "or (type(python) ~= 'nil') or (type(loadstring) ~= 'nil') or (type(load) ~= 'nil') "
			.. "or (type(dofile) ~= 'nil') or (type(pcall) ~= 'nil') "
			.. "or (string.dump ~= nil) or (math.random ~= nil) "
			.. "if bad then return { type = 'LEAVE_SHOP' } end "
			.. "if ('ab'):rep(2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
			.. "if ('x').aisparring ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end"
		local result = run(source)
		ctx.is_true(result.ok == true, "ok")
		ctx.eq(result.code, "policy_ok", "code")
	end)

	test("policy_env_budget_exceeded", function()
		local result = run("return function() while true do end end")
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_budget_exceeded", "code")
	end)

	test("policy_env_bytecode_rejected", function()
		local result = run(string.char(27) .. "LuaQpolicybytes")
		ctx.eq(result.code, "policy_bytecode_rejected", "code")
	end)

	test("policy_env_compile_failure", function()
		local result = run("this is not valid lua !!!")
		ctx.eq(result.code, "policy_compile_failed", "code")
	end)

	test("policy_env_load_failure", function()
		local result = run("return 5")
		ctx.eq(result.code, "policy_load_failed", "code")
	end)

	test("policy_env_no_action", function()
		local result = run("return function() return nil end")
		ctx.eq(result.code, "policy_no_action", "code")
	end)

	test("policy_env_index_out_of_range", function()
		local result = run("return function(observation, actions) return 99 end")
		ctx.eq(result.code, "policy_bad_index", "code")
	end)

	test("policy_env_function_result_rejected", function()
		local result = run("return function() return { f = function() end } end")
		ctx.eq(result.code, "policy_bad_action", "code")
	end)

	test("policy_env_cycle_result_rejected", function()
		local result = run("return function() local t = {}; t.self = t; return t end")
		ctx.eq(result.code, "policy_bad_action", "code")
	end)

	test("policy_env_runtime_error_is_bounded", function()
		local result = run("return function() local t = nil; return t.y end")
		ctx.is_true(result.ok == false, "not_ok")
		ctx.eq(result.code, "policy_runtime_error", "code")
		ctx.is_true(result.action == nil, "no_action")
	end)

	test("policy_env_string_routes_share_whitelist", function()
		local source = "return function(observation, actions) "
			.. "if string.dump ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "if ('x').dump ~= nil then return { type = 'LEAVE_SHOP' } end "
			.. "if ('ab'):rep(2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
			.. "if string.rep('ab', 2) ~= 'abab' then return { type = 'LEAVE_SHOP' } end "
			.. "if ('AB'):lower() ~= 'ab' then return { type = 'LEAVE_SHOP' } end "
			.. "if string.format('%d', 7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end"
		local result = run(source)
		ctx.is_true(result.ok == true, "ok")
		ctx.eq(result.action.type, "PLAY_CARDS", "type")
	end)

	test("policy_env_string_rep_bounded", function()
		local direct = run("return function() local s = string.rep('x', 100000000); return nil end")
		ctx.eq(direct.code, "policy_runtime_error", "direct")
		local indirect = run("return function() local s = ('x'):rep(100000000); return nil end")
		ctx.eq(indirect.code, "policy_runtime_error", "indirect")
	end)

	test("policy_env_empty_target_wire_roundtrip", function()
		local handle = assert(obs.observe(Support.consumable_frame()))
		local export = assert(obs.export(handle))
		local result = run("return function(observation, actions) return actions[1] end", export)
		ctx.is_true(result.ok == true, "ok")
		ctx.eq(result.action.type, "USE_CONSUMABLE", "type")
		ctx.eq(result.action.source_ref, "consumable:1", "source_ref")
		ctx.eq(#result.action.target_refs, 0, "empty_targets")
	end)

	test("policy_env_string_rep_guards", function()
		local empty_count = run("return function() local s = string.rep('', 100000000); return nil end")
		ctx.eq(empty_count.code, "policy_runtime_error", "empty_count")
		local empty_method = run("return function() local s = (''):rep(100000000); return nil end")
		ctx.eq(empty_method.code, "policy_runtime_error", "empty_method")
		local fractional = run("return function() local s = string.rep('x', 1.5); return nil end")
		ctx.eq(fractional.code, "policy_runtime_error", "fractional")
		local edge = run("return function(observation, actions) "
			.. "if string.rep('', 65536) ~= '' then return { type = 'LEAVE_SHOP' } end "
			.. "if ('x'):rep(0) ~= '' then return { type = 'LEAVE_SHOP' } end "
			.. "if string.rep('ab', 3) ~= 'ababab' then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end")
		ctx.is_true(edge.ok == true, "edge_ok")
	end)

	test("policy_env_tostring_primitives_only", function()
		local source = "return function(observation, actions) "
			.. "if tostring(7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
			.. "if tostring('x') ~= 'x' then return { type = 'LEAVE_SHOP' } end "
			.. "if tostring(true) ~= 'true' then return { type = 'LEAVE_SHOP' } end "
			.. "if tostring(nil) ~= 'nil' then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end"
		local primitives = run(source)
		ctx.is_true(primitives.ok == true, "primitives")
		local table_result = run("return function() return tostring({}) end")
		ctx.eq(table_result.code, "policy_runtime_error", "table_rejected")
		local function_result = run("return function() return tostring(function() end) end")
		ctx.eq(function_result.code, "policy_runtime_error", "function_rejected")
	end)

	test("policy_env_refuses_engine_vm", function()
		local names = { "G", "MP", "SMODS", "love" }
		for i = 1, #names do
			local name = names[i]
			local saved = _G[name]
			_G[name] = {}
			local result = run("return function(observation, actions) return actions[1] end")
			_G[name] = saved
			ctx.is_true(result.ok == false, name .. "_not_ok")
			ctx.eq(result.code, "policy_engine_vm_refused", name .. "_code")
		end
	end)

	test("policy_env_source_cap", function()
		local result = run(string.rep("x", 70000))
		ctx.eq(result.code, "policy_bad_source", "code")
	end)

	test("policy_env_format_guard", function()
		local table_direct = run("return function() return string.format('%s', {}) end")
		ctx.eq(table_direct.code, "policy_runtime_error", "table_direct")
		local function_method = run("return function() return ('%s'):format(function() end) end")
		ctx.eq(function_method.code, "policy_runtime_error", "function_method")
		local pointer_direct = run("return function() return string.format('%p', 'x') end")
		ctx.eq(pointer_direct.code, "policy_runtime_error", "pointer_direct")
		local pointer_method = run("return function() return ('%p'):format('x') end")
		ctx.eq(pointer_method.code, "policy_runtime_error", "pointer_method")
		local pointer_width = run("return function() return string.format('%5p', 1) end")
		ctx.eq(pointer_width.code, "policy_runtime_error", "pointer_width")
		local primitives = run("return function(observation, actions) "
			.. "if string.format('%d/%s/%.2f', 7, 'x', 1.5) ~= '7/x/1.50' then return { type = 'LEAVE_SHOP' } end "
			.. "if string.format('%%') ~= '%' then return { type = 'LEAVE_SHOP' } end "
			.. "if ('%d'):format(7) ~= '7' then return { type = 'LEAVE_SHOP' } end "
			.. "return actions[1] end")
		ctx.is_true(primitives.ok == true, "primitives_ok")
	end)
end
