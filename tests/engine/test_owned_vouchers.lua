-- Owned vouchers (docs/OWNED_VOUCHERS_DESIGN.md): the adapter exports the AI's
-- own redeemed voucher keys as plain data, the reader copies them fail-closed
-- into self.vouchers, and the policy models the Seed Money / Money Tree
-- interest cap (tests/policy/test_interest_cap.lua).
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	-- Shop engine with the given used_vouchers table; every listed key is a real
	-- Voucher center unless `centers` overrides it.
	local function engine(used, centers, opts)
		opts = opts or {}
		local e = support.engine({
			state = STATES.SHOP,
			dollars = opts.dollars or 10,
			shop_jokers = opts.shop_jokers,
		})
		e.G.GAME.used_vouchers = used
		local p = centers or {}
		if centers == nil then
			for key in next, used do
				p[key] = { key = key, set = "Voucher" }
			end
		end
		e.G.P_CENTERS = p
		return e
	end

	local function step(e)
		local result, code = support.pipeline(bundle, e, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		return result
	end

	local function capture(result)
		return bundle.reader.capture(result.runtime, result.ui_view)
	end

	local function export(e)
		local handle, code = capture(step(e))
		is_true(handle ~= nil, "capture: " .. tostring(code))
		return bundle.obs.export(handle)
	end

	local function keys(n)
		local used = {}
		for i = 1, n do
			used[string.format("v_test_%02d", i)] = true
		end
		return used
	end

	test("adapter_exports_sorted_real_vouchers_only", function()
		local used = { v_seed_money = true, v_grabber = true, v_blank = false, ["v_Bad"] = true, v_not_a_voucher = true }
		local centers = {
			v_seed_money = { set = "Voucher" }, v_grabber = { set = "Voucher" }, v_blank = { set = "Voucher" },
			v_Bad = { set = "Voucher" }, v_not_a_voucher = { set = "Joker" },
		}
		local result = step(engine(used, centers))
		local list = result.ui_view.self.owned_vouchers
		is_true(type(list) == "table", "list")
		eq(#list, 2)
		eq(list[1], "v_grabber")
		eq(list[2], "v_seed_money")
		local ex = export(engine(used, centers))
		eq(#ex.self.vouchers, 2)
		eq(ex.self.vouchers[1].center, "v_grabber")
		eq(ex.self.vouchers[1].id, "voucher:1")
		eq(ex.self.vouchers[2].center, "v_seed_money")
	end)

	test("no_used_vouchers_means_no_field", function()
		local result = step(engine({}))
		eq(result.ui_view.self.owned_vouchers, nil)
		eq(export(engine({})).self.vouchers, nil)
	end)

	test("adapter_caps_the_list_at_32", function()
		local result = step(engine(keys(40)))
		eq(#result.ui_view.self.owned_vouchers, 32)
		eq(result.ui_view.self.owned_vouchers[32], "v_test_32")
	end)

	test("observation_accepts_17_to_32_owned_vouchers", function()
		-- Owned vouchers have their own bound (32); the shop's stays 16.
		for _, n in ipairs({ 17, 32 }) do
			local ex = export(engine(keys(n)))
			eq(#ex.self.vouchers, n, "owned " .. n)
		end
	end)

	test("reader_rejects_malformed_owned_vouchers", function()
		local cases = {
			{ "not a table", "v_x" },
			{ "non-string", { 7 } },
			{ "bad pattern", { "V_seed" } },
			{ "unsorted", { "v_seed_money", "v_grabber" } },
			{ "duplicate", { "v_grabber", "v_grabber" } },
			{ "too long", { "v_" .. string.rep("a", 31) } },
			{ "hash part", { v_grabber = true } },
		}
		local over = {}
		for i = 1, 33 do
			over[i] = string.format("v_test_%02d", i)
		end
		cases[#cases + 1] = { "over 32", over }
		for _, case in ipairs(cases) do
			local result = step(engine({ v_grabber = true }))
			result.ui_view.self.owned_vouchers = case[2]
			local handle, code = capture(result)
			eq(handle, nil, case[1])
			eq(code, "reader_bad_view", case[1])
		end
	end)

	test("reader_ignores_a_vouchers_field_in_the_view", function()
		local result = step(engine({}))
		result.ui_view.self.vouchers = { { face_down = false, center = "v_money_tree" } }
		local handle = capture(result)
		is_true(handle ~= nil, "capture")
		eq(bundle.obs.export(handle).self.vouchers, nil)
	end)

	test("owned_voucher_refs_cannot_be_bought", function()
		local ex = export(engine({ v_grabber = true }))
		eq(ex.self.vouchers[1].id, "voucher:1")
		local frame = {}
		for k, v in pairs(ex) do
			frame[k] = v
		end
		frame.certificates = { version = 1, items = { { type = "BUY_VOUCHER", certified = true, voucher_ref = "voucher:1" } } }
		local handle, code = bundle.obs.observe(frame)
		eq(handle, nil, "observe")
		eq(code, "observation_invalid_target_ref")
	end)

end
