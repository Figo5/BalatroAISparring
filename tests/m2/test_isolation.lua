return function()
	test("isolation.pure_modules_without_engine_globals", function()
		local env, fired = safe_env()
		local m, obs, acts = make_ai(env)
		local f = syn("SHOP")
		f.shop = {
			reroll_cost = 0,
			items = { entity({ kind = "card", center = "c_1", cost = 0 }) },
			vouchers = {},
		}
		f.certificates.items = { cert("BUY_ITEM", { item_ref = "shop:1" }) }
		local handle = obs.observe(f)
		truthy(handle, "observe under restricted environment")
		local list = acts.generate(handle)
		truthy(type(list) == "table", "generate under restricted environment")
		eq(#list, 1, "one action")
		local normalized = acts.validate(handle, list[1])
		truthy(normalized, "validate under restricted environment")
		eq(fired.count, 0, "no forbidden global access")
		truthy(m.Codec.hash_string("x") ~= nil, "codec usable")
	end)

	test("isolation.rejects_engine_object_inputs_via_schema", function()
		local m = new_ai()
		local obs = m.Observation.factory(m.Codec)
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { setmetatable({ rank = "A" }, { __index = function()
			error("engine object indexed")
		end }) }
		eq(obs_code(obs, f), obs.CODE.BAD_ENTITY, "engine object rejected without traversal")
	end)
end
