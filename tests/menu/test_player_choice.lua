return function()
	local function choice(status)
		local pool = {}
		for _, deck in ipairs({ "red", "blue" }) do
			for _, stake in ipairs({ "white", "green" }) do
				pool[#pool + 1] = { option_id = deck .. "~" .. stake, deck_key = deck,
					deck_name = deck .. " Deck", stake_key = stake, stake_index = stake == "white" and 1 or 3 }
			end
		end
		return { schema = "aisparring.ranked_draft.v1", draft_id = "draft-player-choice",
			profile_id = "aisparring.ranked_selection_profile.player_choice.v1", status = status or "active",
			revision = 0, current_actor = "human", operation = "select", required_count = 1,
			pool = pool, remaining = { "red~white", "red~green", "blue~white", "blue~green" },
			final_selection = status == "completed" and { back_name = "blue Deck", stake_key = "green" } or nil }
	end

	test("player_choice.real_start_cycles_and_commits_once_without_bans", function()
		local fx = fixture({ draft_responses = { { ok = true, draft = choice() }, { ok = true, draft = choice("completed") } } })
		fx.controller.install()
		fx.controller.open_settings()
		local start = nil
		for _, button in ipairs(fx.ustate.buttons) do if button.id == "aisp:start" then start = button end end
		eq(start.button, "aisp_selection_begin", "production start chooses directly")
		fx.ui.funcs.aisp_selection_begin()
		eq(#fx.selection_begins, 1, "direct request")
		eq(#fx.draft_begins, 0, "no ban draft")
		fx.controller.update(0)
		eq(#fx.draft_actions, 0, "default is not committed")
		fx.ui.funcs.aisp_choice_cycle({ config = { id = "aisp:choice:deck:next" } })
		fx.ui.funcs.aisp_choice_cycle({ config = { id = "aisp:choice:stake:next" } })
		eq(#fx.starts, 0, "choices do not start")
		fx.ui.funcs.aisp_draft_confirm()
		eq(#fx.draft_actions, 1, "single commit")
		eq(fx.draft_actions[1].operation, "select", "no bans")
		eq(fx.draft_actions[1].option_ids[1], "blue~green", "actual choice")
		fx.controller.update(0)
		eq(fx.controller.state(), "draft_complete", "chosen")
		eq(#fx.starts, 0, "final Start still required")
		fx.ui.funcs.aisp_confirm_start()
		eq(#fx.starts, 1, "single launch")
		eq(fx.starts[1].draft_id, "draft-player-choice", "host-owned choice only")
		eq(fx.starts[1].deck_key, nil, "no arbitrary launch deck")
	end)

	test("player_choice.wraps_controls_and_rejects_pending_or_foreign_ids", function()
		local fx = fixture({ draft_responses = { { ok = true, draft = choice() } } })
		fx.controller.begin_draft(true)
		eq(fx.controller.choice_cycle("aisp:choice:deck:next"), nil, "pending inert")
		fx.controller.update(0)
		eq(fx.controller.choice_cycle("aisp:choice:deck:forged"), nil, "bad direction")
		fx.controller.choice_cycle("aisp:choice:deck:prev")
		fx.controller.choice_cycle("aisp:choice:stake:prev")
		fx.controller.draft_confirm()
		eq(fx.draft_actions[1].option_ids[1], "blue~green", "wraps measured choices")
		eq(fx.controller.choice_cycle("aisp:choice:deck:next"), nil, "commit pending inert")
	end)
end
