-- The attended Ranked deck/stake draft in the Player AI Sparring menu.
--
-- These exercise the real menu controller/menu renderer callbacks against a
-- scripted host draft (the authoritative state machine lives host-side in
-- tools/ranked_draft.py and is covered by the Python and Lua parity suites).
-- They assert the public rendering, the required distinct count, out-of-turn
-- lockout and that launch adds ONLY the completed draft id. No game is touched.
return function()
	local function option(deck_key, stake_key, deck_name, stake_index)
		local option_id = deck_key .. "~" .. stake_key
		return {
			option_id = option_id,
			deck_key = deck_key,
			deck_name = deck_name,
			stake_key = stake_key,
			stake_index = stake_index,
		}
	end

	local POOL = {
		option("blue", "white", "Blue Deck", 1),
		option("black", "white", "Black Deck", 1),
		option("green", "white", "Green Deck", 1),
		option("blue", "green", "Blue Deck", 2),
		option("black", "green", "Black Deck", 2),
		option("red", "green", "Red Deck", 2),
		option("red", "black", "Red Deck", 3),
		option("yellow", "black", "Yellow Deck", 3),
		option("green", "black", "Green Deck", 3),
	}

	local function remaining_after(banned)
		local removed = {}
		for i = 1, #banned do
			removed[banned[i]] = true
		end
		local out = {}
		for i = 1, #POOL do
			if not removed[POOL[i].option_id] then
				out[#out + 1] = POOL[i].option_id
			end
		end
		return out
	end

	local function state(overrides)
		local base = {
			schema = "aisparring.ranked_draft.v1",
			draft_id = "draft-abc123",
			profile_id = "aisparring.ranked_draft_profile.standard_1_2_2.v1",
			status = "active",
			revision = 0,
			first_actor = "human",
			turn_order = { "human", "ai" },
			current_actor = "human",
			operation = "ban",
			required_count = 1,
			pool = POOL,
			remaining = remaining_after({}),
			banned = {},
			transcript = {},
			final = nil,
			final_selection = nil,
		}
		for key, value in pairs(overrides or {}) do
			base[key] = value
		end
		return base
	end

	local function begin(fx, responses)
		if responses ~= nil then
			fx.draft_responses = {}
			for index = 1, #responses do
				fx.draft_responses[index] = responses[index]
			end
		end
		eq(fx.controller.begin_draft(), true, "begin draft")
	end

	test("draft.begin_sends_only_validated_settings", function()
		local fx = fixture({ draft_responses = { { ok = true, draft = state() } } })
		begin(fx)
		eq(fx.controller.state(), "draft_begin_pending", "awaiting begin")
		eq(#fx.draft_begins, 1, "one begin")
		local payload = fx.draft_begins[1]
		eq(payload.mode, "normal", "mode")
		eq(payload.difficulty, "competitive", "difficulty")
		eq(payload.pacing, "normal", "pacing")
		eq(payload.draft_id, nil, "no draft id on begin")
		eq(payload.seed, nil, "no seed ever")
		local count = 0
		for _ in pairs(payload) do
			count = count + 1
		end
		eq(count, 3, "exactly three keys")
		local state_code = fx.controller.update(0)
		eq(state_code, "draft_active", "active after poll")
		eq(fx.controller.draft().draft_id, "draft-abc123", "public draft")
	end)

	test("draft.human_picks_require_exact_count_and_real_callback", function()
		-- Two-ban stage: a single pick must not be confirmable.
		local fx = fixture({ draft_responses = {
			{ ok = true, draft = state({ required_count = 2 }) },
		} })
		begin(fx)
		fx.controller.update(0)
		eq(fx.controller.state(), "draft_active", "active")
		eq(fx.controller.handle_select("aisp:draft:pick:blue~white"), true, "pick one")
		eq(fx.controller.draft_confirm(), nil, "one of two refused")
		eq(#fx.draft_actions, 0, "no action sent")
		eq(fx.controller.handle_select("aisp:draft:pick:black~white"), true, "pick two")
		eq(fx.controller.draft_confirm(), true, "two of two confirmed")
		eq(#fx.draft_actions, 1, "action sent once")
		local action = fx.draft_actions[1]
		eq(action.operation, "ban", "operation")
		eq(action.expected_revision, 0, "expected revision")
		eq(#action.option_ids, 2, "exact distinct count")
		eq(action.option_ids[1], "blue~white", "first choice")
		eq(action.option_ids[2], "black~white", "second choice")
		eq(action.draft_id, "draft-abc123", "draft id")
		truthy(type(action.request_id) == "string" and #action.request_id > 0, "request id")
	end)

	test("draft.duplicate_pick_toggles_and_out_of_turn_is_inert", function()
		local fx = fixture({ draft_responses = { { ok = true, draft = state({ required_count = 2 }) } } })
		begin(fx)
		fx.controller.update(0)
		fx.controller.handle_select("aisp:draft:pick:blue~white")
		fx.controller.handle_select("aisp:draft:pick:blue~white")
		eq(fx.controller.draft_confirm(), nil, "toggled off leaves nothing confirmable")
		-- Out-of-turn (AI) state: human pick refused and not rendered selectable.
		local ai_state = state({ current_actor = "ai", required_count = 2 })
		local fx2 = fixture({ draft_responses = { { ok = true, draft = ai_state } } })
		begin(fx2)
		fx2.controller.update(0)
		eq(fx2.controller.state(), "draft_active", "active")
		eq(fx2.controller.handle_select("aisp:draft:pick:blue~white"), nil, "out-of-turn pick refused")
		eq(#fx2.draft_actions, 0, "no action")
	end)

	test("draft.completed_renders_selection_and_launch_adds_only_draft_id", function()
		local completed = state({
			status = "completed",
			revision = 4,
			current_actor = nil,
			operation = nil,
			required_count = nil,
			banned = { "green~white", "red~green", "yellow~black", "blue~green", "green~green" },
			remaining = { "black~white", "blue~white", "black~green", "green~black" },
			final = "blue~white",
			final_selection = {
				schema = "aisparring.ranked_selection.v1",
				deck_key = "blue",
				back_key = "b_blue",
				back_name = "Blue Deck",
				stake_key = "white",
				stake_index = 1,
			},
			commitment_digest = "deadbeef",
		})
		local fx = fixture({ draft_responses = { { ok = true, draft = completed } } })
		begin(fx)
		fx.controller.update(0)
		eq(fx.controller.state(), "draft_complete", "complete")
		local ids = collect_ids(fx.ustate.overlays[#fx.ustate.overlays])
		local has_start = false
		for i = 1, #ids do
			if ids[i] == "aisp:draft:start" then
				has_start = true
			end
		end
		truthy(has_start, "start offered")
		eq(fx.controller.draft_start(), true, "open confirm")
		eq(fx.controller.confirm_start(), true, "start request")
		eq(#fx.starts, 1, "one start")
		eq(fx.starts[1].draft_id, "draft-abc123", "only the draft id is added")
		eq(fx.starts[1].mode, "normal", "settings preserved")
		local count = 0
		for _ in pairs(fx.starts[1]) do
			count = count + 1
		end
		eq(count, 4, "exactly one extra key")
	end)

	test("draft.cancel_waits_for_authenticated_success_then_clears", function()
		local fx = fixture({ draft_responses = {
			{ ok = true, draft = state() },
			{ ok = true, code = "ranked_draft_cancelled", draft = state({ status = "cancelled" }) },
		} })
		begin(fx)
		fx.controller.update(0)
		eq(fx.controller.draft_cancel(), true, "cancel submitted")
		eq(fx.controller.state(), "draft_cancel_pending", "awaiting the host reply")
		eq(#fx.draft_cancels, 1, "host told once")
		eq(fx.draft_cancels[1], "draft-abc123", "draft id")
		-- No success is claimed before the authenticated reply.
		eq(fx.controller.draft() ~= nil, true, "draft still shown while pending")
		eq(fx.controller.update(0), "idle", "idle after the host confirms")
		eq(fx.controller.draft(), nil, "draft cleared only on success")
		eq(#fx.starts, 0, "never starts")
		eq(fx.quits, 0, "never quits")
	end)

	test("draft.cancel_refusal_keeps_the_draft_and_reports", function()
		local fx = fixture({ draft_responses = {
			{ ok = true, draft = state({ status = "completed", current_actor = nil, operation = nil, required_count = nil }) },
			{ ok = false, code = "ranked_draft_consumed", draft = state({ status = "completed", current_actor = nil, operation = nil, required_count = nil }) },
		} })
		begin(fx)
		fx.controller.update(0)
		eq(fx.controller.state(), "draft_complete", "completed draft")
		eq(fx.controller.draft_cancel(), true, "cancel submitted")
		local status, code = fx.controller.update(0)
		eq(status, "draft_complete", "state restored, not dropped")
		eq(code, fx.modules.MenuController.CODE.DRAFT_REJECTED, "honest refusal")
		eq(fx.controller.draft() ~= nil, true, "draft retained on refusal")
	end)

	test("draft.unavailable_catalog_fails_honestly", function()
		local fx = fixture({ draft_begin_ok = false })
		local ok, code = fx.controller.begin_draft()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.DRAFT_UNAVAILABLE, "honest unavailable")
		eq(#fx.starts, 0, "never starts")
		eq(fx.quits, 0, "never quits")
	end)

	test("draft.rejection_refreshes_public_revision", function()
		local fx = fixture({ draft_responses = {
			{ ok = true, draft = state() },
			{ ok = false, code = "ranked_draft_stale", draft = state({ revision = 3, remaining = remaining_after({ "blue~white" }), banned = { "blue~white" } }) },
		} })
		begin(fx)
		fx.controller.update(0)
		-- A stale confirmation returns the corrected public state.
		fx.controller.handle_select("aisp:draft:pick:blue~white")
		eq(fx.controller.draft_confirm(), true, "confirm submitted")
		local st = fx.controller.update(0)
		eq(st, "draft_active", "still active for retry")
		eq(fx.controller.draft().revision, 3, "revision updated from rejection")
		eq(fx.controller.draft().remaining[1], "black~white", "remaining refreshed")
	end)

	test("draft.gauntlet_mode_never_offers_a_draft", function()
		local fx = fixture()
		fx.controller.handle_select("aisp:mode:gauntlet")
		local ok, code = fx.controller.begin_draft()
		eq(ok, nil, "refused")
		eq(code, fx.modules.MenuController.CODE.DRAFT_UNAVAILABLE, "gauntlet refused")
		eq(#fx.draft_begins, 0, "no draft request")
	end)
end
