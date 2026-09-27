local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then
		return nil
	end
	local content = handle:read("*a")
	handle:close()
	return content
end

local function jit_status()
	if type(jit) == "table" and type(jit.status) == "function" then
		return tostring(jit.status())
	end
	return "nojit"
end

return function(ctx)
	local test = ctx.test
	local repo = ctx.repo_root

	local codec_src = read_file(repo .. "/AISparring/ai/codec.lua")
	local observation_src = read_file(repo .. "/AISparring/ai/observation.lua")
	local actions_src = read_file(repo .. "/AISparring/ai/actions.lua")

	test("helper_load_with_engine_globals_does_not_mutate", function()
		local names = { "G", "MP", "SMODS", "love" }
		local jit_before = jit_status()
		local index_before = getmetatable("").__index
		local hook_before = debug.gethook()
		for i = 1, #names do
			local name = names[i]
			local saved = _G[name]
			_G[name] = {}
			local helper = dofile(repo .. "/tools/lua/policy_env.lua")
			local configured = helper.configure(codec_src, observation_src, actions_src)
			local result = helper.run("return function(observation, actions) return actions[1] end", {})
			_G[name] = saved
			ctx.is_true(type(helper) == "table", name .. "_loaded")
			ctx.eq(jit_status(), jit_before, name .. "_jit_unchanged")
			ctx.is_true(getmetatable("").__index == index_before, name .. "_string_meta_unchanged")
			ctx.is_true(debug.gethook() == hook_before, name .. "_hook_unchanged")
			ctx.is_true(configured == false, name .. "_configure_refused")
			ctx.is_true(result.ok == false, name .. "_run_refused")
			ctx.eq(result.code, "policy_engine_vm_refused", name .. "_run_code")
		end
	end)
end
