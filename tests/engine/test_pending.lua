return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function setup(engine_opts, pipeline_opts)
		local engine = support.engine(engine_opts or {})
		local pipeline = support.pipeline(bundle, engine, pipeline_opts or {})
		is_true(pipeline.executor ~= nil, "executor factory: " .. tostring(pipeline.executor_code))
		return engine, pipeline
	end

	local function find_action(list, action_type)
		for i = 1, #list do
			if list[i].type == action_type then
				return list[i]
			end
		end
		return nil
	end

	local function first_candidate(pipeline, action_type)
		local handle, code = pipeline.executor.capture()
		is_true(handle ~= nil, "candidate capture: " .. tostring(code))
		local action = find_action(bundle.actions.generate(handle), action_type)
		is_true(action ~= nil, "missing " .. action_type .. " candidate")
		return action
	end

	local function buy_card()
		return support.card({ set = "Joker", center_set = "Joker", center = "j_joker", cost = 3 })
	end

	local function remove_card(area, card)
		local cards = area.cards
		for i = #cards, 1, -1 do
			if cards[i] == card then
				table.remove(cards, i)
			end
		end
	end

	test("duplicate_queued_buy_is_blocked_until_target_transition", function()
		local card = buy_card()
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		local calls = 0
		engine.G.FUNCS.buy_from_shop = function()
			calls = calls + 1
		end
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(calls, 1)
		eq(pipeline.executor.pending_status(), "exec_pending")

		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_pending")
		eq(calls, 1)

		-- Only the anchored target leaving its area proves completion.
		remove_card(engine.G.shop_jokers, card)
		local handle, capture_code = pipeline.executor.capture()
		is_true(handle ~= nil, "target transition capture: " .. tostring(capture_code))
		eq(pipeline.executor.pending_status(), nil)
	end)

	test("unrelated_opponent_update_does_not_release", function()
		local card = buy_card()
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		local calls = 0
		engine.G.FUNCS.buy_from_shop = function()
			calls = calls + 1
		end
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)

		-- Opponent lives/score change the trusted fingerprint but are not this
		-- purchase's completion.
		engine.MP.GAME.enemy.lives = 2
		engine.MP.GAME.enemy.info_received = true
		engine.MP.GAME.enemy.score_text = "1234"
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_pending")
		eq(calls, 1)
	end)

	test("own_irrelevant_and_revision_bump_do_not_release", function()
		local card = buy_card()
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		local calls = 0
		engine.G.FUNCS.buy_from_shop = function()
			calls = calls + 1
		end
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)

		engine.G.GAME.dollars = engine.G.GAME.dollars + 50
		pipeline.revision.bump("unrelated_hook")
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_pending")
		eq(calls, 1)
	end)

	test("synchronous_target_removal_completes", function()
		local card = buy_card()
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		engine.G.FUNCS.buy_from_shop = function()
			remove_card(engine.G.shop_jokers, card)
		end
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		local handle, code = pipeline.executor.capture()
		is_true(handle ~= nil, "synchronous target removal should complete: " .. tostring(code))
		eq(pipeline.executor.pending_status(), nil)
	end)

	test("synchronous_reroll_cost_change_completes", function()
		local engine, pipeline = setup({ state = STATES.SHOP })
		engine.G.FUNCS.reroll_shop = function()
			engine.G.GAME.current_round.reroll_cost = 6
		end
		local reroll = first_candidate(pipeline, "REROLL")
		is_true(pipeline.executor.validate(reroll) == true)
		is_true(pipeline.executor.dispatch(reroll) == true)
		local handle, code = pipeline.executor.capture()
		is_true(handle ~= nil, "synchronous reroll should complete: " .. tostring(code))
		eq(pipeline.executor.pending_status(), nil)
	end)

	test("synchronous_phase_change_completes", function()
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		engine.G.blind_select_opts = { small = { get_UIE_by_ID = function(_, id)
			if id == "select_blind_button" then
				return { config = { button = "select_blind", ref_table = engine.G.P_BLINDS.bl_small }, UIBox = {} }
			end
			return nil
		end } }
		engine.G.FUNCS.select_blind = function()
			engine.G.STATE = STATES.SELECTING_HAND
		end
		local action = { type = "SELECT_BLIND", id = "blind-sync" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		local handle, code = pipeline.executor.capture()
		is_true(handle ~= nil, "synchronous phase change should complete: " .. tostring(code))
		eq(pipeline.executor.pending_status(), nil)
	end)

	test("duplicate_use_and_reroll_are_blocked", function()
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine, pipeline = setup({ consumeables = { consumable } })
		-- Real `use_card` removes the source synchronously (button_callbacks.lua
		-- :2209), so the fixture models that (the executor asserts it).
		local record_use = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record_use(e)
			remove_card(engine.G.consumeables, e.config.ref_table)
		end
		local use = first_candidate(pipeline, "USE_CONSUMABLE")
		is_true(pipeline.executor.validate(use) == true)
		is_true(pipeline.executor.dispatch(use) == true)
		eq(pipeline.executor.pending_status(), "exec_pending")
		-- The source left its area synchronously, so the latch completes on the
		-- next gate and the duplicate no longer resolves: it can never commit
		-- twice.
		local ok, code = pipeline.executor.validate(use)
		eq(ok, nil)
		eq(code, "exec_unknown_ref")

		local _, pipeline2 = setup({ state = STATES.SHOP })
		local reroll = first_candidate(pipeline2, "REROLL")
		is_true(pipeline2.executor.validate(reroll) == true)
		is_true(pipeline2.executor.dispatch(reroll) == true)
		local blocked, reroll_code = pipeline2.executor.capture()
		eq(blocked, nil)
		eq(reroll_code, "exec_pending")
	end)

	test("use_card_noop_early_return_fails_clean_without_latch", function()
		-- Ankh passes `can_use_consumeable` with full joker slots
		-- (card.lua:1536) but `use_card` early-returns on `check_use` (2163-2169)
		-- without removing the card. The executor must reject the no-op and hold
		-- no latch (H5), never latch into a terminal stall.
		local ankh = support.card({ set = "Tarot", consumeable = true, center = "c_ankh", center_set = "Tarot" })
		ankh.ability.name = "Ankh"
		local engine, pipeline = setup({ consumeables = { ankh }, jokers = {}, joker_slots = 1 })
		local use = first_candidate(pipeline, "USE_CONSUMABLE")
		is_true(use ~= nil)
		-- Fill the single joker slot: `Card:check_use` now makes use_card a no-op.
		engine.G.jokers.cards[1] = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local vok, vcode = pipeline.executor.validate(use)
		eq(vok, nil)
		eq(vcode, "exec_illegal")
		eq(pipeline.executor.pending_status(), nil)
		eq(#engine.calls, 0, "no-op use must not invoke a callback")
	end)

	test("failed_callback_leaves_latch_free", function()
		local card = buy_card()
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		engine.G.FUNCS.buy_from_shop = function()
			return false
		end
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
		eq(pipeline.executor.pending_status(), nil, "rejected callback must not latch")

		local leave = { type = "LEAVE_SHOP", id = "leave-after-failed" }
		is_true(pipeline.executor.validate(leave) == true)
	end)

	test("stall_timeout_is_terminal_until_session_cancel", function()
		local card = buy_card()
		local clock = support.clock(0)
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } }, {
			clock = clock,
			stall_timeout = 1,
		})
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(pipeline.executor.pending_status(), "exec_pending")

		clock.advance(1)
		local handle, code = pipeline.executor.capture()
		eq(handle, nil)
		eq(code, "exec_stall_timeout")
		eq(pipeline.executor.pending_status(), "exec_stall_timeout", "timeout must fault, not release")

		-- The fault is terminal: a fresh valid action cannot be validated and the
		-- old queued action cannot be retried.
		local calls_before = #engine.calls
		local leave = { type = "LEAVE_SHOP", id = "leave-after-stall" }
		local vok, vcode = pipeline.executor.validate(leave)
		eq(vok, nil)
		eq(vcode, "exec_stall_timeout")
		eq(#engine.calls, calls_before)

		local canceled, cancel_code = pipeline.executor.cancel()
		is_true(canceled == true)
		eq(cancel_code, "exec_canceled")
		eq(pipeline.executor.pending_status(), nil)
		is_true(pipeline.executor.validate(leave) == true)
	end)

	test("cashout_latch_blocks_duplicate_until_state_moves", function()
		local marker = { config = { button = "cash_out" } }
		local element_for = function(name)
			if name == "cash_out" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {} }, { element_for = element_for })
		is_true(pipeline.executor.advance_ui() == true)
		eq(engine.calls[#engine.calls].name, "cash_out")
		eq(pipeline.executor.pending_status(), "exec_pending")

		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_pending")
		eq(#engine.calls, 1, "duplicate cash_out committed")

		engine.G.STATE = STATES.SHOP
		local handle = pipeline.executor.capture()
		is_true(handle ~= nil)
		eq(pipeline.executor.pending_status(), nil)
	end)

	test("revoke_and_cancel_clear_the_latch", function()
		local card = buy_card()
		local _, pipeline = setup({ state = STATES.SHOP, shop_jokers = { card } })
		local action = first_candidate(pipeline, "BUY_ITEM")
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(pipeline.executor.pending_status(), "exec_pending")

		local revoked, revoke_code = pipeline.executor.revoke()
		is_true(revoked == true)
		eq(revoke_code, "exec_revoked")
		eq(pipeline.executor.pending_status(), "exec_revoked")
		local handle, code = pipeline.executor.capture()
		eq(handle, nil)
		eq(code, "exec_revoked")

		local card2 = buy_card()
		local _, pipeline2 = setup({ state = STATES.SHOP, shop_jokers = { card2 } })
		local action2 = first_candidate(pipeline2, "BUY_ITEM")
		is_true(pipeline2.executor.validate(action2) == true)
		is_true(pipeline2.executor.dispatch(action2) == true)
		local canceled, cancel_code = pipeline2.executor.cancel()
		is_true(canceled == true)
		eq(cancel_code, "exec_canceled")
		eq(pipeline2.executor.pending_status(), nil)
		local handle2 = pipeline2.executor.capture()
		is_true(handle2 ~= nil, "session cancel must not revoke the executor")
	end)

	test("same_state_reorder_is_not_latched", function()
		local first = support.card({ set = "Joker", area_type = "joker" })
		local second = support.card({ set = "Joker", area_type = "joker" })
		local _, pipeline = setup({ jokers = { first, second } })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-pending" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(pipeline.executor.pending_status(), nil, "pure reorder must not latch")
		local handle = pipeline.executor.capture()
		is_true(handle ~= nil, "capture after reorder")
	end)

	test("use_card_non_removal_fails_without_latch", function()
		-- H5: a `use_card` that returns without removing its source is a no-op,
		-- not a committed effect; it must fail cleanly with no latch so the
		-- bounded stall timer can never fire on it.
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine, pipeline = setup({ consumeables = { consumable } })
		engine.G.FUNCS.use_card = function() end
		local use = first_candidate(pipeline, "USE_CONSUMABLE")
		is_true(pipeline.executor.validate(use) == true)
		local ok, code = pipeline.executor.dispatch(use)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
		eq(pipeline.executor.pending_status(), nil, "no-op use latched a pending action")
		local handle = pipeline.executor.capture()
		is_true(handle ~= nil, "executor must stay free after a no-op use")
	end)
end
