return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)
	local baseline = env.baseline

	local difficulties = baseline.difficulties()

	test("policy_difficulties_declared", function()
		ctx.eq(#difficulties, 3, "count")
		ctx.eq(difficulties[1], "rookie", "first")
		ctx.eq(difficulties[2], "competitive", "second")
		ctx.eq(difficulties[3], "major_league", "third")
	end)

	test("policy_source_available_and_bounded", function()
		for i = 1, #difficulties do
			local name = difficulties[i]
			local source = Support.source(env, name)
			ctx.truthy(type(source) == "string", name .. "_string")
			ctx.truthy(#source > 0, name .. "_nonempty")
			ctx.truthy(#source <= 65536, name .. "_cap")
			ctx.neq(string.byte(source, 1), 27, name .. "_not_bytecode")
			ctx.truthy(string.find(source, "return function(observation, actions)", 1, true) ~= nil, name .. "_entry")
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
