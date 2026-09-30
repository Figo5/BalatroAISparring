-- Every rendered policy source runs with a strict environment: reading or
-- writing any name that is not an allowed sandbox global fails loudly. This
-- catches a local declared after its first use (which Lua silently treats as a
-- nil global) before it can disable a whole evaluator.
return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local ALLOWED = {
		string = true, table = true, math = true, type = true, tostring = true, tonumber = true,
		ipairs = true, pairs = true, next = true, select = true, unpack = true,
		rawget = true, rawset = true, rawequal = true,
	}

	local function strict_env()
		local base = {}
		for name in pairs(ALLOWED) do
			base[name] = _G[name]
		end
		return setmetatable(base, {
			__index = function(_, key)
				error("undeclared global read: " .. tostring(key), 2)
			end,
			__newindex = function(_, key)
				error("global write: " .. tostring(key), 2)
			end,
		})
	end

	local frames = {
		Support.play_frame(), Support.pair_frame(), Support.flush_frame(), Support.shop_frame(),
		Support.blind_frame(), Support.timer_frame(), Support.booster_frame(), Support.consumable_frame(),
		Support.sell_frame(), Support.requirement_frame("1000", 2, 3), Support.requirement_frame("60", 1, 2),
		Support.requirement_frame("100000", 2, 3, "MULTIPLAYER_PVP"),
	}
	local shop = Support.shop_frame()
	shop.self.jokers = { Support.joker("j_gros_michel"), Support.joker("j_cavendish") }
	shop.certificates.items[#shop.certificates.items + 1] = { type = "REORDER_JOKERS", certified = true, order = { "joker:2", "joker:1" } }
	frames[#frames + 1] = shop
	local leveled = Support.requirement_frame("150", 1, 3)
	leveled.self.hand_levels = { pair = { level = 3, chips = 35, mult = 4 } }
	frames[#frames + 1] = leveled

	test("policy_sources_use_no_undeclared_globals", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local source = Support.source(env, difficulty)
			local chunk = assert((loadstring or load)(source, "=policy_" .. difficulty))
			local sandbox = strict_env()
			if setfenv then
				setfenv(chunk, sandbox)
			else
				chunk = assert(load(source, "=policy_" .. difficulty, "t", sandbox))
			end
			local decide = chunk()
			for i = 1, #frames do
				local frame = frames[i]
				local export = Support.export(env, frame)
				local list = Support.generate(env, frame)
				local ok, err = pcall(decide, export, list)
				ctx.is_true(ok, difficulty .. " frame " .. i .. ": " .. tostring(err))
			end
		end
	end)
end
