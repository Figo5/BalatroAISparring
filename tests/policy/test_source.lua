return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local baseline = env.baseline

	local difficulties = baseline.difficulties()

	test("policy_difficulties_declared", function()
		ctx.eq(#difficulties, 4, "count")
		ctx.eq(difficulties[1], "rookie", "first")
		ctx.eq(difficulties[2], "competitive", "second")
		ctx.eq(difficulties[3], "major_league", "third")
		ctx.eq(difficulties[4], "expert", "fourth")
	end)

	test("policy_source_available_and_bounded", function()
		for i = 1, #difficulties do
			local name = difficulties[i]
			local source = Support.source(env, name)
			ctx.truthy(type(source) == "string", name .. "_string")
			ctx.truthy(#source > 0, name .. "_nonempty")
			ctx.truthy(#source <= 65536, name .. "_cap")
			ctx.neq(string.byte(source, 1), 27, name .. "_not_bytecode")
			ctx.truthy(string.find(source, "return function(obs,actions)", 1, true) ~= nil, name .. "_entry")
			ctx.vector("src_len_" .. name, #source)
			ctx.vector("src_hash_" .. name, env.codec.hash_string(source))
		end
	end)

	test("policy_source_has_no_forbidden_tokens", function()
		for i = 1, #difficulties do
			local name = difficulties[i]
			local hits = Support.scan_source(Support.source(env, name))
			ctx.eq(#hits, 0, name .. "_hits:" .. table.concat(hits, ","))
		end
	end)

	test("policy_scanner_ignores_comments_and_incidental_substrings", function()
		local decoy = "local negative = 1 -- this comment mentions require( and io.open and G\n--[[ block lead comment G io. ]]\nreturn negative"
		local hits = Support.scan_source(decoy)
		ctx.eq(#hits, 0, "decoy_hits:" .. table.concat(hits, ","))
		local real = "local x = require('m'); return x"
		ctx.truthy(#Support.scan_source(real) > 0, "real_require_detected")
		local rng = "local x = math.random(1, 6); return x"
		ctx.truthy(#Support.scan_source(rng) > 0, "real_rng_detected")
	end)

	test("policy_source_within_size_guard", function()
		-- Practical guard (M2 of docs/CLAUDE_BATCH2_REVIEW.md): growth must recover
		-- space rather than creep towards the sandbox's hard 65536-byte cap.
		ctx.truthy(baseline.SOURCE_GUARD <= 57344, "guard_not_raised")
		for i = 1, #difficulties do
			local name = difficulties[i]
			local source = Support.source(env, name)
			ctx.truthy(#source <= baseline.SOURCE_GUARD, name .. "_guard:" .. #source)
			ctx.truthy(#baseline.readable_source(name) > #source, name .. "_stripped")
		end
	end)

	test("policy_stripped_source_keeps_no_comments_or_indentation", function()
		for i = 1, #difficulties do
			local name = difficulties[i]
			local source = Support.source(env, name)
			ctx.eq(string.find(source, "--", 1, true), nil, name .. "_no_comment")
			ctx.eq(string.find(source, "\n[ \t]"), nil, name .. "_no_indent")
			ctx.eq(string.find(source, "\n\n", 1, true), nil, name .. "_no_blank")
		end
	end)

	test("policy_stripped_source_decides_like_readable_template", function()
		local frames = {
			Support.pair_frame(), Support.flush_frame(), Support.high_card_frame(), Support.discard_only_frame(),
			Support.pvp_frame(), Support.shop_frame(), Support.voucher_frame(), Support.booster_frame(),
			Support.consumable_frame(), Support.jokers_with_play_frame(), Support.reorder_frame(),
			Support.requirement_frame("5000", 1, 2, "PLAY_HAND"),
		}
		for i = 1, #difficulties do
			local name = difficulties[i]
			local stripped = assert(loadstring(Support.source(env, name)))()
			local readable = assert(loadstring(baseline.readable_source(name)))()
			for k = 1, #frames do
				local export = Support.export(env, frames[k])
				local a = stripped(export, Support.generate(env, frames[k]))
				local b = readable(export, Support.generate(env, frames[k]))
				ctx.eq(a and a.id, b and b.id, name .. "_frame" .. k)
			end
		end
	end)

	test("targeted_rule_matches_the_unwired_target_port", function()
		-- TARGETED (never buy / sell consumables needing hand targets) is only
		-- right while the live runtime wires no target_selection port. If this
		-- fails, the port was wired: revisit TARGETED in baseline_policy.lua.
		local handle = assert(io.open(ctx.repo_root .. "/AISparring/integration/companion_host.lua", "rb"))
		local host = handle:read("*a")
		handle:close()
		ctx.eq(string.find(host, "target_selection", 1, true), nil, "companion_host_wires_no_target_port")
		ctx.truthy(string.find(Support.source(env, "competitive"), "c_strength", 1, true) ~= nil, "targeted_list_present")
	end)

	test("squeezed_source_compiles_to_identical_bytecode", function()
		-- Both renderings join statement lines before the space squeeze. Lua 5.1
		-- (whose bytecode records lines but not columns) the stripped and the
		-- unsqueezed sources must compile to byte-identical functions. LuaJIT
		-- dumps are not byte-stable between loads, so only Lua 5.1 checks.
		if jit ~= nil then
			return
		end
		for i = 1, #difficulties do
			local name = difficulties[i]
			local tight = string.dump(assert(loadstring(Support.source(env, name), "=policy")))
			local loose = string.dump(assert(loadstring(baseline.loose_source(name), "=policy")))
			ctx.eq(tight, loose, name .. "_bytecode")
			ctx.truthy(#baseline.loose_source(name) > #Support.source(env, name), name .. "_squeezed")
		end
	end)

	test("policy_source_is_deterministic", function()
		for i = 1, #difficulties do
			local name = difficulties[i]
			local first = Support.source(env, name)
			local second = Support.source(env, name)
			ctx.eq(first, second, name .. "_stable")
		end
	end)

	test("policy_unknown_difficulty_rejected", function()
		local source, code = baseline.source("legendary")
		ctx.eq(source, nil, "source_nil")
		ctx.eq(code, "baseline_unknown_difficulty", "code")
	end)

	test("policy_non_string_difficulty_rejected", function()
		for _, value in ipairs({ 1, true, {}, function() end }) do
			local source, code = baseline.source(value)
			ctx.eq(source, nil, "nil")
			ctx.eq(code, "baseline_unknown_difficulty", "code")
		end
	end)

	test("policy_describe_is_isolated_copy", function()
		local first = baseline.describe()
		first.rookie.reserve = -9999
		first.rookie.extra = true
		local second = baseline.describe()
		ctx.neq(second.rookie.reserve, -9999, "mutation_blocked")
		ctx.eq(second.rookie.extra, nil, "extra_blocked")
		for i = 1, #difficulties do
			local name = difficulties[i]
			ctx.eq(second[name].max_actions, 256, name .. "_max_actions")
		end
	end)

	test("policy_difficulties_actually_differ", function()
		local described = baseline.describe()
		local rookie = described.rookie
		local competitive = described.competitive
		local major = described.major_league
		ctx.truthy(major.reserve > competitive.reserve, "reserve_graded")
		ctx.truthy(competitive.reserve > rookie.reserve, "reserve_graded_low")
		ctx.truthy(major.play_junk > competitive.play_junk, "junk_graded")
		ctx.truthy(competitive.play_junk > rookie.play_junk, "junk_graded_low")
		ctx.neq(rookie.discard_pair_pen, major.discard_pair_pen, "discard_preservation_graded")
		ctx.neq(rookie.reroll_base, major.reroll_base, "reroll_graded")
	end)
end
