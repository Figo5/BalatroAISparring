return function(ctx)
	local test = ctx.test
	local Support = ctx.support
	local env = Support.env(ctx.repo_root)

	local function load_policy(difficulty, sandbox)
		local source = Support.source(env, difficulty)
		local chunk = assert(loadstring(source))
		if sandbox ~= nil then
			setfenv(chunk, sandbox)
		end
		local fn = chunk()
		ctx.is_true(type(fn) == "function", difficulty .. "_function")
		return fn
	end

	test("policy_is_deterministic_on_repeat", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local frames = { Support.pair_frame(), Support.shop_frame(), Support.consumable_frame() }
			for i = 1, #frames do
				local first = Support.choose_id(env, difficulty, frames[i])
				for _ = 1, 5 do
					ctx.eq(Support.choose_id(env, difficulty, frames[i]), first, difficulty .. "_repeat" .. i)
				end
				ctx.vector("determinism_" .. difficulty .. "_" .. i, first)
			end
		end
	end)

	test("policy_breaks_ties_canonically", function()
		local frame = Support.tie_frame()
		local list = Support.generate(env, frame)
		local smallest = list[1].id
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local action = Support.run(env, difficulty, frame)
			ctx.is_true(action.ok == true, difficulty .. "_ok")
			ctx.eq(action.action.id, smallest, difficulty .. "_canonical_tie")
		end
		ctx.vector("tie_canonical_id", smallest)
	end)

	test("policy_is_deterministic_under_permuted_input", function()
		local frame = Support.tie_frame()
		local list = Support.generate(env, frame)
		local reversed = {}
		for i = #list, 1, -1 do
			reversed[#reversed + 1] = list[i]
		end
		local fn = load_policy("competitive")
		local export = Support.export(env, frame)
		local forward = fn(export, list)
		local backward = fn(export, reversed)
		ctx.eq(forward.id, backward.id, "permutation_stable")
		ctx.eq(forward.id, list[1].id, "canonical_min")
	end)

	test("policy_caps_evaluations", function()
		local fn = load_policy("competitive")
		local actions = {}
		for i = 1, 5000 do
			local id = "a"
			if i <= 256 then
				id = string.format("z%03d", i)
			end
			actions[i] = { type = "LEAVE_SHOP", id = id }
		end
		local chosen = fn({ phase = "PLAY_HAND", self = {} }, actions)
		ctx.truthy(chosen ~= nil, "chosen")
		ctx.eq(chosen.id, "z001", "within_cap")
		ctx.vector("cap_chosen_id", chosen.id)
	end)

	test("policy_writes_no_globals", function()
		local sandbox = { string = string, type = type }
		local fn = load_policy("competitive", sandbox)
		local before = {}
		for key in pairs(sandbox) do
			before[key] = true
		end
		local actions = { { type = "LEAVE_SHOP", id = "x" } }
		fn({ phase = "PLAY_HAND", self = {} }, actions)
		for key in pairs(sandbox) do
			ctx.truthy(before[key] == true, "global_leak:" .. tostring(key))
		end
		local count = 0
		for key in pairs(sandbox) do
			count = count + 1
		end
		ctx.eq(count, 2, "sandbox_stable")
	end)

	test("policy_handles_malformed_input", function()
		local fn = load_policy("major_league")
		ctx.eq(fn(nil, {}), nil, "nil_observation")
		ctx.eq(fn({}, nil), nil, "nil_actions")
		ctx.eq(fn({}, {}), nil, "empty_actions")
		ctx.eq(fn({}, { { id = "no_type" } }), nil, "missing_type")
		ctx.eq(fn({}, { { type = 7, id = "bad_type" } }), nil, "non_string_type")
		ctx.eq(fn("not a table", { { type = "REROLL", id = "r" } }), nil, "string_observation")
	end)

	test("policy_accepts_unknown_type_last", function()
		local fn = load_policy("competitive")
		local unknown = { type = "MYSTERY", id = "m" }
		local known = { type = "LEAVE_SHOP", id = "k" }
		ctx.eq(fn({}, { unknown }).id, "m", "unknown_alone")
		ctx.eq(fn({}, { unknown, known }).id, "k", "known_preferred")
	end)

	test("policy_does_not_mutate_actions", function()
		local fn = load_policy("competitive")
		local actions = {
			{ type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "p" },
			{ type = "REROLL", id = "r" },
		}
		local before_len = #actions
		local before_first = #actions[1].card_refs
		fn({ phase = "PLAY_HAND", self = { hand = {} } }, actions)
		ctx.eq(#actions, before_len, "length")
		ctx.eq(#actions[1].card_refs, before_first, "nested")
		ctx.eq(actions[1].id, "p", "id")
		ctx.eq(actions[2].id, "r", "second_id")
	end)

	test("policy_reads_only_visible_fields", function()
		local fn = load_policy("competitive")
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "b" }
		local observation = {
			shop = {
				items = {
					{ id = "shop:1", kind = "joker", cost = 5, edition = "negative" },
				},
			},
			self = { money = 10, credit_limit = 0, hand = { { id = "hand:1", rank = "Ace", suit = "Spades" } } },
		}
		local chosen = fn(observation, { action })
		ctx.eq(chosen.id, "b", "chosen")
	end)

	test("policy_ignores_unobservable_state", function()
		local plain = Support.pair_frame()
		local poisoned = Support.poisoned_pair_frame()
		local exported = Support.export(env, poisoned)
		ctx.eq(exported.rng_state, nil, "rng_ignored")
		ctx.eq(exported.future_shop, nil, "future_ignored")
		ctx.eq(exported.deck_preview, nil, "preview_ignored")
		ctx.eq(exported.deck, nil, "root_deck_ignored")
		ctx.eq(exported.self.deck.seed, nil, "seed_ignored")
		ctx.eq(exported.self.secret_hand, nil, "secret_hand_ignored")
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local a = Support.choose_id(env, difficulty, plain)
			local b = Support.choose_id(env, difficulty, poisoned)
			ctx.eq(a, b, difficulty .. "_poison_stable")
		end
	end)

	test("policy_restricted_worker_roundtrip", function()
		for _, difficulty in ipairs(Support.DIFFICULTIES) do
			local result = Support.run(env, difficulty, Support.play_frame())
			ctx.is_true(result.ok == true, difficulty .. "_ok")
			ctx.eq(result.action.type, "PLAY_CARDS", difficulty .. "_type")
			ctx.eq(result.code, "policy_ok", difficulty .. "_code")
		end
	end)
end
