return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local is_false = function(value, label)
		if value ~= false then
			error((label or "is_false") .. ": expected false, got " .. tostring(value), 2)
		end
	end
	local support = ctx.support
	local repo = ctx.repo_root

	local bundle = support.load(repo)

	local function make_reader()
		local spy = support.spy(bundle.obs)
		local reader, code = bundle.StateReader.factory(spy)
		is_true(reader ~= nil, "reader factory: " .. tostring(code))
		return reader, spy
	end

	local function capture_hand(engine_card_opts, record_opts)
		local reader, spy = make_reader()
		local engine = support.build({
			phase = "PLAY_HAND",
			hand = { support.engine_card(engine_card_opts or {}) },
			hand_visible = true,
			hand_records = { support.card_record(record_opts or {}) },
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		return handle, code, spy.frames[1]
	end

	test("explicit_face_down_false_projects_identity", function()
		local _, code, frame = capture_hand({}, {})
		eq(code, nil)
		eq(frame.self.hand[1].face_down, false)
		eq(frame.self.hand[1].rank, "K")
		eq(frame.self.hand[1].suit, "Hearts")
		eq(frame.self.hand[1].center, "c_king")
	end)

	test("missing_face_down_redacts", function()
		local _, code, frame = capture_hand({}, { omit_face_down = true })
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
		eq(frame.self.hand[1].rank, nil)
	end)

	test("non_boolean_face_down_redacts", function()
		local _, code, frame = capture_hand({}, { face_down = "yes" })
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
	end)

	test("face_down_true_redacts", function()
		local _, code, frame = capture_hand({}, { face_down = true })
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
	end)

	test("facing_back_redacts_even_with_view_claim", function()
		local _, code, frame = capture_hand({ facing = "back" }, {})
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
		eq(frame.self.hand[1].rank, nil)
	end)

	test("sprite_facing_back_redacts", function()
		local _, code, frame = capture_hand({ sprite_facing = "back" }, {})
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
	end)

	test("missing_facing_redacts", function()
		local _, code, frame = capture_hand({ omit_facing = true }, {})
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
	end)

	test("missing_sprite_facing_redacts", function()
		local _, code, frame = capture_hand({ omit_sprite_facing = true }, {})
		eq(code, nil)
		eq(frame.self.hand[1].face_down, true)
	end)

	test("stone_card_masks_rank_and_suit", function()
		local _, code, frame = capture_hand({ effect = "Stone Card" }, { rank = "A", suit = "Spades" })
		eq(code, nil)
		eq(frame.self.hand[1].face_down, false)
		eq(frame.self.hand[1].rank, nil)
		eq(frame.self.hand[1].suit, nil)
		eq(frame.self.hand[1].center, "c_king")
	end)

	test("no_rank_masks_rank_only", function()
		local _, code, frame = capture_hand({ no_rank = true }, {})
		eq(code, nil)
		eq(frame.self.hand[1].rank, nil)
		eq(frame.self.hand[1].suit, "Hearts")
	end)

	test("no_suit_masks_suit_only", function()
		local _, code, frame = capture_hand({ no_suit = true }, {})
		eq(code, nil)
		eq(frame.self.hand[1].suit, nil)
		eq(frame.self.hand[1].rank, "K")
	end)

	test("replace_base_card_masks_both", function()
		local _, code, frame = capture_hand({ replace_base_card = true }, {})
		eq(code, nil)
		eq(frame.self.hand[1].rank, nil)
		eq(frame.self.hand[1].suit, nil)
	end)

	test("absent_shown_denies_all_identity", function()
		local _, code, frame = capture_hand({}, { omit_shown = true })
		eq(code, nil)
		eq(frame.self.hand[1].face_down, false)
		eq(frame.self.hand[1].rank, nil)
		eq(frame.self.hand[1].suit, nil)
		eq(frame.self.hand[1].center, nil)
	end)

	test("shown_flag_false_denies_field", function()
		local _, code, frame = capture_hand({}, { shown = { center = true } })
		eq(code, nil)
		eq(frame.self.hand[1].center, "c_king")
		eq(frame.self.hand[1].rank, nil)
		eq(frame.self.hand[1].suit, nil)
	end)

	local function capture_opponent(opts)
		local reader, spy = make_reader()
		local engine = support.build({
			phase = opts.phase or "PLAY_HAND",
			opponent = support.opponent(opts.opponent or {}),
			info_received = opts.info_received,
			score_text = opts.score_text,
			hands_text = opts.hands_text,
			last_timer = opts.last_timer,
			real_score = opts.real_score,
			highest_score = opts.highest_score,
			hide_score = opts.hide_score,
			location_disabled = opts.location_disabled,
			config_timer = opts.config_timer,
			config_hud_disabled = opts.config_hud_disabled,
			lobby_code = opts.lobby_code,
			recognition = opts.recognition,
			hands_played = opts.hands_played,
			blind = opts.blind,
			blind_key = opts.blind_key,
			blind_pvp = opts.blind_pvp,
		})
		local handle, code = reader.capture(engine.runtime, engine.ui_view)
		return handle, code, spy.frames[1]
	end

	test("opponent_score_requires_info_and_certificate", function()
		local _, code, frame = capture_opponent({
			info_received = true, score_text = "1,234",
			hide_score = false,
			opponent = { score_visible = true },
		})
		eq(code, nil)
		eq(frame.opponent.displayed_score, "1,234")

		local _, _, frame2 = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = false,
			opponent = { score_visible = false },
		})
		eq(frame2.opponent, nil)
	end)

	test("opponent_omitted_without_info_received", function()
		local _, code, frame = capture_opponent({
			info_received = false, score_text = "1,234", hands_text = "4",
			hide_score = false,
			opponent = { score_visible = true, hands_visible = true },
		})
		eq(code, nil)
		eq(frame.opponent, nil)
	end)

	test("opponent_score_masking_engine_derived_pvp", function()
		-- Engine blind unknown + view says non-PvP => fail closed (mask).
		local _, _, unknown = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(unknown.opponent, nil)

		-- Engine-proven non-PvP blind + view false => unmask.
		local _, _, nonpvp = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			blind_key = "bl_small", recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(nonpvp.opponent.displayed_score, "1,234")

		-- Actual nemesis boss + view false => still mask.
		local _, _, boss = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			blind_key = "bl_mp_nemesis", recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(boss.opponent, nil)

		-- blind.pvp flag => mask despite a false view flag.
		local _, _, pvpflag = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			blind_pvp = true, recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(pvpflag.opponent, nil)

		-- MULTIPLAYER_PVP phase masks unconditionally, regardless of a false view flag.
		local _, _, pvpphase = capture_opponent({
			phase = "MULTIPLAYER_PVP",
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			blind_key = "bl_small", recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(pvpphase.opponent, nil)

		-- After a hand is played the mask is lifted.
		local _, _, after_play = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 2,
			opponent = { score_visible = true },
		})
		eq(after_play.opponent.displayed_score, "1,234")

		-- Unknown hide config => mask.
		local _, _, unknown_cfg = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = nil, hands_played = 0,
			opponent = { score_visible = true },
		})
		eq(unknown_cfg.opponent, nil)

		-- Masked display string is never projected.
		local _, _, poisoned = capture_opponent({
			info_received = true, score_text = "???" , hide_score = false,
			opponent = { score_visible = true },
		})
		eq(poisoned.opponent, nil)
	end)

	test("opponent_score_masking_lua_truthiness_fail_closed", function()
		local key_small = { config = { blind = { key = "bl_small" } } }

		-- pvp = 0 is truthy in Lua (MP `... or blind.pvp`): must mask.
		local _, _, zero = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = key_small.config, pvp = 0 },
			opponent = { score_visible = true },
		})
		eq(zero.opponent, nil)

		-- pvp = "" is truthy: must mask.
		local _, _, empty = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = key_small.config, pvp = "" },
			opponent = { score_visible = true },
		})
		eq(empty.opponent, nil)

		-- pvp = table is truthy and must not be traversed: must mask.
		local _, _, tbl = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = key_small.config, pvp = {} },
			opponent = { score_visible = true },
		})
		eq(tbl.opponent, nil)

		-- pvp = function is truthy and must not be invoked: must mask.
		local invoked = 0
		local _, _, fn = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = key_small.config, pvp = function() invoked = invoked + 1 end },
			opponent = { score_visible = true },
		})
		eq(fn.opponent, nil)
		eq(invoked, 0)

		-- pvp = false + nonempty key + view says non-PvP => engine-proven non-PvP: unmask.
		local _, _, nonpvp = capture_opponent({
			info_received = true, score_text = "1,234", hide_score = true, hands_played = 0,
			blind = { config = key_small.config, pvp = false },
			recognition = { pvp_context = false },
			opponent = { score_visible = true },
		})
		eq(nonpvp.opponent.displayed_score, "1,234")

		-- pvp = false + empty key => unknown: mask.
		local _, _, emptyk = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = { blind = { key = "" } }, pvp = false },
			opponent = { score_visible = true },
		})
		eq(emptyk.opponent, nil)

		-- pvp = false + non-string key => unknown: mask.
		local _, _, badkey = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = { blind = { key = 123 } }, pvp = false },
			opponent = { score_visible = true },
		})
		eq(badkey.opponent, nil)

		-- pvp = false + missing key => unknown: mask.
		local _, _, nokey = capture_opponent({
			info_received = true, score_text = "SECRET", hide_score = true, hands_played = 0,
			blind = { config = { blind = {} }, pvp = false },
			opponent = { score_visible = true },
		})
		eq(nokey.opponent, nil)
	end)

	test("opponent_hands_from_certified_display_or_text", function()
		local _, _, from_view = capture_opponent({
			info_received = true, hide_score = false,
			opponent = { hands_visible = true, hands = 3 },
		})
		eq(from_view.opponent.hands, 3)

		local _, _, from_text = capture_opponent({
			info_received = true, hands_text = "4", hide_score = false,
			opponent = { hands_visible = true },
		})
		eq(from_text.opponent.hands, 4)

		local _, _, bad_text = capture_opponent({
			info_received = true, hands_text = "abc", hide_score = false,
			opponent = { hands_visible = true },
		})
		eq(bad_text.opponent, nil)
	end)

	test("opponent_location_gating", function()
		local _, _, shown = capture_opponent({
			info_received = true, hide_score = false, location_disabled = false,
			opponent = { location_visible = true, location = "Round 2" },
		})
		eq(shown.opponent.location, "Round 2")

		local _, _, disabled = capture_opponent({
			info_received = true, hide_score = false, location_disabled = true,
			opponent = { location_visible = true, location = "Round 2" },
		})
		eq(disabled.opponent, nil)
	end)

	test("opponent_timer_requires_rendered_string_and_config", function()
		local _, _, shown = capture_opponent({
			info_received = true, hide_score = false,
			config_timer = true, config_hud_disabled = false, lobby_code = "ABCD",
			opponent = { timer_visible = true, timer = "12" },
		})
		eq(shown.opponent.timer, "12")

		local _, _, no_config = capture_opponent({
			info_received = true, hide_score = false,
			config_timer = nil, lobby_code = "ABCD",
			opponent = { timer_visible = true, timer = "12" },
		})
		eq(no_config.opponent, nil)

		local _, _, hud_off = capture_opponent({
			info_received = true, hide_score = false,
			config_timer = true, config_hud_disabled = true, lobby_code = "ABCD",
			opponent = { timer_visible = true, timer = "12" },
		})
		eq(hud_off.opponent, nil)

		local _, _, raw_only = capture_opponent({
			info_received = true, hide_score = false, last_timer = 9.5,
			config_timer = true, lobby_code = "ABCD",
			opponent = { timer_visible = true },
		})
		eq(raw_only.opponent, nil)
	end)

	test("opponent_raw_timer_and_score_poison_never_exported", function()
		local _, _, frame = capture_opponent({
			info_received = true, hide_score = false, score_text = "10",
			last_timer = 999, real_score = 777, highest_score = 555,
			config_timer = true, lobby_code = "ABCD",
			opponent = { score_visible = true, timer_visible = true, timer = "5" },
		})
		eq(frame.opponent.displayed_score, "10")
		eq(frame.opponent.timer, "5")
		eq(frame.opponent.real_score, nil)
		eq(frame.opponent.last_timer, nil)
		eq(frame.opponent.highest_score, nil)
	end)

	test("match_timer_gated_by_certificate_and_config", function()
		local function capture_match(opts)
			local reader, spy = make_reader()
			local engine = support.build({
				phase = "BLIND_SELECTION",
				match_timer = opts.match_timer,
				match_timer_visible = opts.match_timer_visible,
				config_timer = opts.config_timer,
				config_hud_disabled = opts.config_hud_disabled,
				lobby_code = opts.lobby_code,
			})
			local handle, code = reader.capture(engine.runtime, engine.ui_view)
			return handle, code, spy.frames[1]
		end

		local _, code, frame = capture_match({
			match_timer = "30", match_timer_visible = true,
			config_timer = true, lobby_code = "ABCD",
		})
		eq(code, nil)
		eq(frame.match.timer, "30")

		local _, _, uncertified = capture_match({
			match_timer = "30", match_timer_visible = false,
			config_timer = true, lobby_code = "ABCD",
		})
		eq(uncertified.match.timer, nil)

		local _, _, disabled = capture_match({
			match_timer = "30", match_timer_visible = true,
			config_timer = true, config_hud_disabled = true, lobby_code = "ABCD",
		})
		eq(disabled.match.timer, nil)

		local _, _, no_config = capture_match({
			match_timer = "30", match_timer_visible = true, lobby_code = "ABCD",
		})
		eq(no_config.match.timer, nil)
	end)
end
