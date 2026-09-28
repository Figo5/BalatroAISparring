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
		is_true(pipeline.adapter ~= nil, "adapter factory: " .. tostring(pipeline.adapter_code))
		return engine, pipeline
	end

	local function no_ui_callbacks(engine, label)
		for i = 1, #engine.calls do
			local name = engine.calls[i].name
			if name == "can_play" or name == "can_buy" or name == "can_discard"
				or name == "can_sell_card" or name == "can_use_consumeable" or name == "can_open" then
				error((label or "ui") .. ": executor invoked UI predicate " .. name, 2)
			end
		end
	end

	local function remove_card(area, card)
		for i = #area.cards, 1, -1 do
			if area.cards[i] == card then
				table.remove(area.cards, i)
			end
		end
	end

	-- Real `G.FUNCS.use_card` removes the source from its area synchronously
	-- (`button_callbacks.lua:2209`); the fixture must model that so the
	-- executor's synchronous-removal check sees a real commit.
	local function real_use_card(engine)
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local card = e.config.ref_table
			remove_card(engine.G.pack_cards, card)
			remove_card(engine.G.consumeables, card)
			remove_card(engine.G.shop_booster, card)
			remove_card(engine.G.shop_vouchers, card)
		end
	end

	test("factory_binds_role_and_ports", function()
		local engine = support.engine()
		local adapter = bundle.EngineAdapter.factory({
			role = "ai_staged", session = "s1", codec = bundle.codec,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		local executor, code = bundle.ProductionExecutor.factory({
			role = "human_practice", session = "s1", adapter = adapter, reader = bundle.reader,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		eq(executor, nil)
		eq(code, "exec_bad_role")
		local executor2, code2 = bundle.ProductionExecutor.factory({
			role = "ai_staged", session = "s1", adapter = nil, reader = bundle.reader,
			revision = bundle.StateRevision.factory(), G = engine.G, MP = engine.MP,
		})
		eq(executor2, nil)
		eq(code2, "exec_bad_adapter")
	end)

	test("capture_returns_handle_and_epoch", function()
		local _, pipeline = setup()
		local handle, epoch = pipeline.executor.capture()
		is_true(handle ~= nil, "capture handle")
		is_true(type(epoch) == "number", "epoch")
		is_true(bundle.obs.is_handle(handle))
	end)

	test("play_validate_and_dispatch", function()
		local engine, pipeline = setup({
			hand = { support.card({}), support.card({}) },
		})
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched, dcode = pipeline.executor.dispatch(action)
		is_true(dispatched == true, "dispatch: " .. tostring(dcode))
		eq(#engine.hand.highlighted, 2)
		eq(engine.calls[#engine.calls].name, "play_cards_from_highlighted")
		no_ui_callbacks(engine, "play")
	end)

	test("illegal_play_refused_when_no_hands_left", function()
		local _, pipeline = setup({
			hand = { support.card({}) },
			hands_left = 0,
		})
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("stale_revision_refused_before_callback", function()
		local engine, pipeline = setup({ hand = { support.card({}) } })
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-3" }
		local ok = pipeline.executor.validate(action)
		is_true(ok == true)
		engine.G.STATE = STATES.SHOP
		local dispatched, dcode = pipeline.executor.dispatch(action)
		eq(dispatched, nil)
		eq(dcode, "exec_stale_revision")
		eq(#engine.calls, 0)
	end)

	test("dispatch_requires_validate", function()
		local _, pipeline = setup({ hand = { support.card({}) } })
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1" }, id = "play-4" }
		local dispatched, dcode = pipeline.executor.dispatch(action)
		eq(dispatched, nil)
		eq(dcode, "exec_illegal")
	end)

	test("buy_item_validate_and_dispatch", function()
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched = pipeline.executor.dispatch(action)
		is_true(dispatched == true)
		eq(engine.calls[#engine.calls].name, "buy_from_shop")
		eq(engine.calls[#engine.calls].e.config.ref_table, shop_card)
	end)

	test("buy_item_unaffordable_refused", function()
		local shop_card = support.card({ center = "c_ace", cost = 100, center_set = "Default" })
		local _, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("sell_joker_validate_and_dispatch", function()
		local joker = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { joker } })
		local action = { type = "SELL_JOKER", joker_ref = "joker:1", id = "sell-1" }
		local ok, code = pipeline.executor.validate(action)
		is_true(ok == true, "validate: " .. tostring(code))
		local dispatched = pipeline.executor.dispatch(action)
		is_true(dispatched == true)
		eq(engine.calls[#engine.calls].name, "sell_card")
		no_ui_callbacks(engine, "sell")
	end)

	test("reroll_and_leave_shop", function()
		local engine, pipeline = setup({ state = STATES.SHOP })
		-- The real `reroll_shop` replaces the shop contents; simulate the visible
		-- transition so the deferred-action latch releases before `LEAVE_SHOP`.
		local record_reroll = engine.G.FUNCS.reroll_shop
		engine.G.FUNCS.reroll_shop = function(e)
			record_reroll(e)
			engine.G.GAME.current_round.reroll_cost = 6
		end
		local reroll = { type = "REROLL", id = "reroll-1" }
		is_true(pipeline.executor.validate(reroll) == true)
		is_true(pipeline.executor.dispatch(reroll) == true)
		eq(engine.calls[#engine.calls].name, "reroll_shop")
		local leave = { type = "LEAVE_SHOP", id = "leave-1" }
		is_true(pipeline.executor.validate(leave) == true)
		is_true(pipeline.executor.dispatch(leave) == true)
		eq(engine.calls[#engine.calls].name, "toggle_shop")
	end)

	test("open_booster_and_voucher_use_card", function()
		local booster = support.card({ set = "Booster", center = "p_arcana_normal_1", cost = 4, center_set = "Booster" })
		local voucher = support.card({ set = "Voucher", center = "v_seed_money", cost = 10, center_set = "Voucher" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_boosters = { booster }, shop_vouchers = { voucher } })
		-- The real `use_card` consumes/redeems the shop item; simulate the target
		-- leaving its area so the action-specific latch releases.
		local record_use = engine.G.FUNCS.use_card
		local function remove(cards, card)
			for i = #cards, 1, -1 do
				if cards[i] == card then
					table.remove(cards, i)
				end
			end
		end
		engine.G.FUNCS.use_card = function(e)
			record_use(e)
			local card = e.config.ref_table
			remove(engine.G.shop_booster.cards, card)
			remove(engine.G.shop_vouchers.cards, card)
		end
		local open = { type = "OPEN_BOOSTER", item_ref = "shop_booster:1", id = "open-1" }
		is_true(pipeline.executor.validate(open) == true)
		is_true(pipeline.executor.dispatch(open) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, booster)
		local redeem = { type = "BUY_VOUCHER", voucher_ref = "shop_voucher:1", id = "voucher-1" }
		is_true(pipeline.executor.validate(redeem) == true)
		is_true(pipeline.executor.dispatch(redeem) == true)
		eq(engine.calls[#engine.calls].e.config.ref_table, voucher)
	end)

	test("select_booster_item_use_card", function()
		local pack_card = support.card({ center = "c_temperance" })
		local engine, pipeline = setup({ state = STATES.TAROT_PACK, pack_cards = { pack_card } })
		real_use_card(engine)
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, pack_card)
	end)

	test("use_consumable_empty_target", function()
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine, pipeline = setup({ consumeables = { consumable } })
		real_use_card(engine)
		local action = { type = "USE_CONSUMABLE", source_ref = "consumable:1", target_refs = {}, id = "use-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, consumable)
	end)

	test("use_consumable_targets_set_highlight", function()
		local consumable = support.card({ set = "Tarot", consumeable = true, center = "c_star", center_set = "Tarot", max_highlighted = 3 })
		local target = support.card({ center = "c_ace" })
		local engine, pipeline = setup({ consumeables = { consumable }, hand = { support.card({}), target } })
		real_use_card(engine)
		local action = { type = "USE_CONSUMABLE", source_ref = "consumable:1", target_refs = { "target:2" }, id = "use-2" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(#engine.hand.highlighted, 1)
		eq(engine.hand.highlighted[1], target)
	end)

	test("select_blind_uses_engine_blind_object", function()
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_select = {},
			blind_key = "bl_small",
			blind_on_deck = "Small",
		})
		local action = { type = "SELECT_BLIND", id = "blind-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "select_blind")
		eq(engine.calls[#engine.calls].e.config.ref_table, engine.G.P_BLINDS.bl_small)
	end)

	test("skip_blind_requires_element_port", function()
		local _, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small" })
		local action = { type = "SKIP_BLIND", id = "skip-1" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("skip_blind_with_element_port", function()
		local marker = { config = { ref_table = "tag" } }
		local engine, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small" }, {
			element_for = function(name)
				if name == "skip_blind" then
					return marker
				end
				return nil
			end,
		})
		local action = { type = "SKIP_BLIND", id = "skip-2" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_blind")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out", function()
		local marker = { config = { button = "cash_out" } }
		local element_for = function(name)
			if name == "cash_out" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {} }, { element_for = element_for })
		local ok, code = pipeline.executor.advance_ui()
		is_true(ok == true, "advance: " .. tostring(code))
		eq(engine.calls[#engine.calls].name, "cash_out")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out_source_element_fallback", function()
		-- Production wires no `element_for`; the executor resolves the real
		-- `round_eval` cash-out button from G (`common_events.lua:1071`).
		local marker = { config = { id = "cash_out_button" } }
		local engine, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {
			get_UIE_by_ID = function(_, id)
				if id == "cash_out_button" then
					return marker
				end
				return nil
			end,
		} })
		local ok, code = pipeline.executor.advance_ui()
		is_true(ok == true, "advance: " .. tostring(code))
		eq(engine.calls[#engine.calls].name, "cash_out")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("advance_ui_cash_out_waits_for_real_button", function()
		-- Cash-out must not run before the real round-tally button exists: the
		-- executor requires `G.round_eval:get_UIE_by_ID('cash_out_button')` (C2)
		-- and never fabricates a minimal element.
		local _, pipeline = setup({ state = STATES.ROUND_EVAL, round_eval = {
			get_UIE_by_ID = function() return nil end,
		} })
		local ok, code = pipeline.executor.advance_ui()
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("select_blind_pvp_routes_through_ready_button", function()
		local marker = { config = { ref_table = "blind" } }
		local element_for = function(name)
			if name == "pvp_ready" then
				return marker
			end
			return nil
		end
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		}, { element_for = element_for })
		local action = { type = "SELECT_BLIND", id = "blind-pvp" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "mp_toggle_ready")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("select_blind_pvp_without_ready_element_refused", function()
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		local action = { type = "SELECT_BLIND", id = "blind-pvp-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_element_missing")
	end)

	test("select_blind_pvp_already_ready_refused", function()
		local marker = { config = {} }
		local element_for = function()
			return marker
		end
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = true,
			blind_select = {},
		}, { element_for = element_for })
		local action = { type = "SELECT_BLIND", id = "blind-pvp-3" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("skip_booster_validate_and_dispatch", function()
		local engine, pipeline = setup({ state = STATES.STANDARD_PACK, pack_cards = { support.card({ rank = "2" }) } })
		local action = { type = "SKIP_BOOSTER", id = "skip-booster-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_booster")
	end)

	test("explicit_callback_false_is_not_success", function()
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card } })
		engine.G.FUNCS.buy_from_shop = function()
			return false
		end
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-false" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
	end)

	test("reorder_jokers_commits_permutation", function()
		local first = support.card({ set = "Joker", area_type = "joker" })
		local second = support.card({ set = "Joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { first, second } })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.G.jokers.cards[1], second)
		eq(engine.G.jokers.cards[2], first)
	end)

	test("reorder_rejects_non_permutation", function()
		local engine, pipeline = setup({ jokers = {
			support.card({ set = "Joker", area_type = "joker" }),
			support.card({ set = "Joker", area_type = "joker" }),
		} })
		local action = { type = "REORDER_JOKERS", order = { "joker:1", "joker:1" }, id = "reorder-2" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("sell_consumable_validate_and_dispatch", function()
		local consumable = support.card({
			set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot", area_type = "joker",
		})
		local engine, pipeline = setup({ consumeables = { consumable } })
		local action = { type = "SELL_CONSUMABLE", consumable_ref = "consumable:1", id = "sell-consumable-1" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "sell_card")
		eq(engine.calls[#engine.calls].e.config.ref_table, consumable)
	end)

	test("broker_ports_expose_production_mode", function()
		local _, pipeline = setup()
		local ports = pipeline.executor.broker_ports()
		eq(ports.mode, "M3_PRODUCTION")
		eq(ports.production, true)
		is_true(type(ports.capture) == "function")
		is_true(type(ports.validate) == "function")
		is_true(type(ports.dispatch) == "function")
		local handle, epoch = ports.capture()
		is_true(handle ~= nil)
		is_true(type(epoch) == "number")
		local action = { type = "LEAVE_SHOP", id = "leave-broker" }
		eq(ports.validate(action, handle), false)
	end)

	test("skip_blind_source_element_fallback", function()
		-- Production wires no `element_for`; the executor derives `e.UIBox` from
		-- `G.blind_select_opts[self.lower(blind_on_deck)]` so `skip_blind` can read
		-- `tag_container` (button_callbacks.lua:2754).
		local tag = { config = { ref_table = "tag" } }
		local box = { get_UIE_by_ID = function(_, id)
			if id == "tag_container" then
				return tag
			end
			return nil
		end }
		local engine, pipeline = setup({ state = STATES.BLIND_SELECT, blind_on_deck = "Small", blind_select = {} })
		engine.G.blind_select_opts = { small = box }
		local action = { type = "SKIP_BLIND", id = "skip-fallback" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_blind")
		eq(engine.calls[#engine.calls].e.UIBox, box)
	end)

	test("skip_blind_boss_refused", function()
		-- H4b: the boss blind has no `tag_container`, so a boss skip has no
		-- effect and must not be offered or validated.
		local _, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_on_deck = "Boss",
			blind_states = { Small = "Skipped", Big = "Skipped", Boss = "Select" },
			blind_select = {},
		})
		local action = { type = "SKIP_BLIND", id = "skip-boss" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("select_blind_pvp_source_element_fallback", function()
		local marker = { config = { ref_table = "blind" } }
		local box = { get_UIE_by_ID = function(_, id)
			if id == "select_blind_button" then
				return marker
			end
			return nil
		end }
		local engine, pipeline = setup({
			state = STATES.BLIND_SELECT,
			blind_key = "bl_mp_nemesis",
			boss_blind = "bl_mp_nemesis",
			blind_on_deck = "Boss",
			ready_blind = false,
			blind_select = {},
		})
		engine.G.blind_select_opts = { boss = box }
		local action = { type = "SELECT_BLIND", id = "blind-pvp-fallback" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "mp_toggle_ready")
		eq(engine.calls[#engine.calls].e, marker)
	end)

	test("select_booster_consumable_requires_can_use", function()
		-- C1: a pack consumable is used on selection, so the engine's
		-- `can_use_consumeable` is the gate rather than free consumable slots.
		local unusable = support.card({ set = "Spectral", center_set = "Spectral", consumeable_data = {}, center = "c_cryptid", usable = false })
		local engine, pipeline = setup({ state = STATES.TAROT_PACK, pack_cards = { unusable }, consumeables = {} })
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-unusable" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local usable = support.card({ set = "Tarot", consumeable = true, center = "c_hermit", center_set = "Tarot" })
		local engine2, pipeline2 = setup({ state = STATES.TAROT_PACK, pack_cards = { usable }, consumeables = {} })
		real_use_card(engine2)
		local action2 = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-usable" }
		is_true(pipeline2.executor.validate(action2) == true)
	end)

	test("select_booster_negative_joker_ignores_full_slots", function()
		-- L3: vanilla `can_select_card` accepts a negative joker regardless of
		-- free joker slots (button_callbacks.lua:2113).
		local negative = support.card({ set = "Joker", center = "j_joker", area_type = "joker", edition = "negative" })
		local filler = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		local engine, pipeline = setup({
			state = STATES.BUFFOON_PACK,
			pack_cards = { negative },
			jokers = { filler },
			joker_slots = 1,
		})
		real_use_card(engine)
		local action = { type = "SELECT_BOOSTER_ITEM", card_refs = { "booster:1" }, id = "pack-negative" }
		is_true(pipeline.executor.validate(action) == true)
	end)

	test("play_cards_requires_forced_selection", function()
		-- H3: a forced card cannot be un-highlighted and is cleared by a
		-- play/discard, so a selection omitting it is refused.
		local forced = support.card({ rank = "Ace" })
		forced.ability.forced_selection = true
		local engine, pipeline = setup({ hand = { forced, support.card({ rank = "2" }), support.card({ rank = "3" }) } })
		local omitted = { type = "PLAY_CARDS", card_refs = { "hand:2" }, id = "play-omitted" }
		local ok, code = pipeline.executor.validate(omitted)
		eq(ok, nil)
		eq(code, "exec_illegal")

		local included = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-included" }
		is_true(pipeline.executor.validate(included) == true)
		is_true(pipeline.executor.dispatch(included) == true)
		eq(#engine.hand.highlighted, 2)
	end)

	test("highlight_mismatch_blocks_callback", function()
		-- H3: `add_to_highlighted` silently drops an add at the highlight limit
		-- (cardarea.lua:149-150); the actual highlighted set must equal the
		-- requested set or the callback must not run.
		local engine, pipeline = setup({ hand = { support.card({ rank = "2" }), support.card({ rank = "3" }) } })
		engine.hand.add_to_highlighted = function() end
		local action = { type = "PLAY_CARDS", card_refs = { "hand:1", "hand:2" }, id = "play-mismatch" }
		is_true(pipeline.executor.validate(action) == true)
		local ok, code = pipeline.executor.dispatch(action)
		eq(ok, nil)
		eq(code, "exec_callback_failed")
		eq(#engine.calls, 0, "callback ran on a dropped highlight")
	end)

	test("gates_clear_blocks_shop_commit", function()
		-- M2: the executor holds legality on its own; a live STOP_USE blocks a
		-- purchase that the (blocked) view would not have offered.
		local shop_card = support.card({ center = "c_ace", cost = 3, center_set = "Default" })
		local engine, pipeline = setup({ state = STATES.SHOP, shop_jokers = { shop_card }, stop_use = 1 })
		local action = { type = "BUY_ITEM", item_ref = "shop:1", id = "buy-gated" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)

	test("skip_booster_smods_state_dispatch", function()
		-- H1: SMODS boosters are always skippable in `SMODS_BOOSTER_OPENED`.
		local engine, pipeline = setup({ state = STATES.SMODS_BOOSTER_OPENED, pack_cards = {} })
		local action = { type = "SKIP_BOOSTER", id = "skip-smods" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(engine.calls[#engine.calls].name, "skip_booster")
	end)

	test("reorder_uses_metatable_area_methods", function()
		-- L1: `align_cards`/`set_ranks` live on the CardArea metatable on a real
		-- area (rawget is always nil); the executor must reach them by normal
		-- indexing and run them.
		local first = support.card({ set = "Joker", area_type = "joker" })
		local second = support.card({ set = "Joker", area_type = "joker" })
		local engine, pipeline = setup({ jokers = { first, second } })
		local calls = {}
		local methods = {
			set_ranks = function() calls[#calls + 1] = "set_ranks" end,
			align_cards = function() calls[#calls + 1] = "align_cards" end,
		}
		setmetatable(engine.G.jokers, { __index = methods })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-mt" }
		is_true(pipeline.executor.validate(action) == true)
		is_true(pipeline.executor.dispatch(action) == true)
		eq(calls[1], "set_ranks")
		eq(calls[2], "align_cards")
		eq(engine.G.jokers.cards[1], second)
	end)

	test("reorder_refused_when_pinned", function()
		local first = support.card({ set = "Joker", area_type = "joker" })
		first.pinned = true
		local second = support.card({ set = "Joker", area_type = "joker" })
		local _, pipeline = setup({ jokers = { first, second } })
		local action = { type = "REORDER_JOKERS", order = { "joker:2", "joker:1" }, id = "reorder-pinned" }
		local ok, code = pipeline.executor.validate(action)
		eq(ok, nil)
		eq(code, "exec_illegal")
	end)
end
