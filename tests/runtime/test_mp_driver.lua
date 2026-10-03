return function(ctx)
	local support = ctx.support
	local MPDriver = support.mod(ctx.repo_root, "AISparring/integration/mp_driver.lua")
	local test = ctx.test

	local function fake_engine(opts)
		opts = opts or {}
		local calls = {}
		local MP
		local ruleset = {
			forced_gamemode = "gamemode_mp_attrition",
			standard = true,
			multiplayer_content = true,
			pvp_timer_base_seconds = 60,
			pvp_timer_hand_played_increment_seconds = 10,
			_layer_order = { "standard", "ranked", "pvp_timer" },
			is_disabled = function()
				if opts.disabled == true then
					return true
				end
				return false
			end,
			force_lobby_options = function()
				calls[#calls + 1] = { name = "force_lobby_options", custom_seed = MP.LOBBY.config.custom_seed }
				MP.LOBBY.config.timer_base_seconds = 180
				return true
			end,
		}
		MP = {
			LOBBY = {
				code = opts.code,
				-- Real pinned initial state: core.lua:31 `is_host = false`; only the
				-- server's lobbyInfo ever sets it (action_handlers.lua:186).
				is_host = opts.is_host == true,
				ready_to_start = opts.ready_to_start or false,
				connected = true,
				username = "Guest",
				-- The reviewed `reset_lobby_config` defaults; the actual-config
				-- Ranked digest requires every field to carry its real type.
				config = {
					ruleset = "ruleset_mp_standard_ranked",
					gamemode = "gamemode_mp_attrition",
					gold_on_life_loss = true,
					no_gold_on_round_loss = false,
					death_on_round_loss = true,
					different_seeds = false,
					the_order = true,
					starting_lives = 4,
					pvp_start_round = 2,
					timer_base_seconds = 150,
					timer_increment_seconds = 60,
					pvp_countdown_seconds = 3,
					showdown_starting_antes = 3,
					custom_seed = "random",
					different_decks = false,
					random_loadout = false,
					back = "Red Deck",
					sleeve = "sleeve_casl_none",
					stake = 1,
					challenge = "",
					cocktail = "1H",
					multiplayer_jokers = true,
					timer = true,
					timer_forgiveness = 0,
					forced_config = true,
					preview_disabled = false,
					legacy_smallworld = false,
					hide_score_until_played = true,
					enemy_location_disabled = false,
					timer_display_threshold = 0,
					modifier_layers = "",
					disable_live_and_timer_hud = false,
				},
			},
			Rulesets = { ruleset_mp_standard_ranked = ruleset },
			ACTIONS = {
				join_lobby = function(code)
					calls[#calls + 1] = { name = "join_lobby", code = code }
				end,
				set_username = function(name)
					calls[#calls + 1] = { name = "set_username", username = name }
				end,
				leave_lobby = function()
					calls[#calls + 1] = { name = "leave_lobby" }
				end,
			},
		}
		local original_current_ruleset = function()
			return ruleset
		end
		MP.current_ruleset = original_current_ruleset
		local funcs = {}
		funcs.start_lobby = function()
			calls[#calls + 1] = { name = "start_lobby" }
			-- reset_lobby_config(true) preserves the ruleset/gamemode and resets
			-- the seed, exactly like the real G.FUNCS.start_lobby.
			MP.LOBBY.config.custom_seed = "random"
			MP.current_ruleset():force_lobby_options()
			MP.LOBBY.code = "ABC12"
		end
		funcs.lobby_ready_up = function(e)
			calls[#calls + 1] = { name = "lobby_ready_up", e = e }
			-- Source-shaped toggle: the real callback flips ready_to_start and
			-- mutates e.config/e.children/e.UIBox.
			MP.LOBBY.ready_to_start = not MP.LOBBY.ready_to_start
			if type(e) == "table" then
				e.config.colour = MP.LOBBY.ready_to_start and "green" or "red"
				e.children[1].children[1].config.text = MP.LOBBY.ready_to_start and "unready" or "ready"
				e.UIBox:recalculate()
			end
		end
		funcs.lobby_start_game = function(e)
			calls[#calls + 1] = { name = "lobby_start_game", e = e }
		end
		return MP, funcs, calls, original_current_ruleset
	end

	test("host_start_injects_seed_after_reset_before_original_options", function()
		local MP, funcs, calls, original = fake_engine()
		local driver, code = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.eq(code, nil)
		local ok = driver.host_start("AISP0003")
		ctx.is_true(ok)
		ctx.eq(MP.LOBBY.config.ruleset, "ruleset_mp_standard_ranked")
		ctx.eq(MP.LOBBY.config.gamemode, "gamemode_mp_attrition")
		ctx.eq(MP.LOBBY.config.custom_seed, "AISP0003")
		local saw_seed = false
		for _, call in ipairs(calls) do
			if call.name == "force_lobby_options" and call.custom_seed == "AISP0003" then
				saw_seed = true
			end
		end
		ctx.is_true(saw_seed, "original force_lobby_options saw the trusted seed")
		ctx.is_true(rawequal(MP.current_ruleset, original), "current_ruleset restored")
	end)

	test("host_start_without_seed_keeps_normal_random_semantics", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ok = driver.host_start(nil)
		ctx.is_true(ok)
		ctx.eq(MP.LOBBY.config.custom_seed, "random")
	end)

	test("host_start_refuses_bad_seed_and_wrong_role", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local bad, bad_code = driver.host_start("bad seed!")
		ctx.eq(bad, nil)
		ctx.eq(bad_code, "driver_bad_seed")
		local ai_driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		local refused, refused_code = ai_driver.host_start("AISP0001")
		ctx.eq(refused, nil)
		ctx.eq(refused_code, "driver_wrong_role")
	end)

	test("ai_join_sets_fixed_name_and_exact_code", function()
		local MP, funcs, calls = fake_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		local ok = driver.ai_join("abc12")
		ctx.is_true(ok)
		ctx.eq(MP.LOBBY.username, "BALATRO AI")
		local joined = nil
		local named = false
		for _, call in ipairs(calls) do
			if call.name == "join_lobby" then
				joined = call.code
			end
			if call.name == "set_username" then
				named = true
			end
		end
		ctx.eq(joined, "abc12")
		ctx.is_true(named)
		local bad, bad_code = driver.ai_join("bad code!")
		ctx.eq(bad, nil)
		ctx.eq(bad_code, "driver_bad_code")
	end)

	local function source_element()
		return {
			config = {},
			children = { { children = { { config = {} } } } },
			UIBox = { recalculate = function() end },
		}
	end

	test("ai_ready_uses_real_element_and_is_idempotent_once_ready", function()
		local MP, funcs, calls = fake_engine({ code = "ABC12" })
		local element = source_element()
		local driver = MPDriver.factory({
			role = "ai",
			mp = MP,
			funcs = funcs,
			element_for = function(name)
				if name == "lobby_ready" then
					return element
				end
				return nil
			end,
		})
		local ok = driver.ai_ready()
		ctx.is_true(ok)
		local ready_call = nil
		for _, call in ipairs(calls) do
			if call.name == "lobby_ready_up" then
				ready_call = call
			end
		end
		ctx.is_true(ready_call ~= nil)
		ctx.is_true(rawequal(ready_call.e, element))
		ctx.is_true(MP.LOBBY.ready_to_start)
		-- Already ready: an idempotent success that never toggles again.
		local again, again_code = driver.ai_ready()
		ctx.is_true(again)
		ctx.eq(again_code, "driver_ok")
		local toggles = 0
		for _, call in ipairs(calls) do
			if call.name == "lobby_ready_up" then
				toggles = toggles + 1
			end
		end
		ctx.eq(toggles, 1)
	end)

	test("ai_ready_resolves_the_real_g_main_menu_element", function()
		local MP, funcs, calls = fake_engine({ code = "ABC12" })
		local element = source_element()
		local G = {
			MAIN_MENU_UI = {
				get_UIE_by_ID = function(_, id)
					if id == "lobby_menu_start" then
						return element
					end
					return nil
				end,
			},
		}
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = G })
		local ok = driver.ai_ready()
		ctx.is_true(ok)
		local ready_call = nil
		for _, call in ipairs(calls) do
			if call.name == "lobby_ready_up" then
				ready_call = call
			end
		end
		ctx.is_true(ready_call ~= nil and rawequal(ready_call.e, element))
	end)

	test("ai_ready_requires_a_real_element", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, element_for = function() return nil end })
		local ok, code = driver.ai_ready()
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_missing_element")
	end)

	test("ai_ready_does_not_pretend_when_the_toggle_bailed", function()
		-- Version-mismatch modal shape: the callback returns without changing
		-- the observable ready flag.
		local MP, funcs = fake_engine({ code = "ABC12" })
		funcs.lobby_ready_up = function() end
		local element = source_element()
		local driver = MPDriver.factory({
			role = "ai",
			mp = MP,
			funcs = funcs,
			element_for = function() return element end,
		})
		local ok, code = driver.ai_ready()
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_not_ready")
		ctx.eq(MP.LOBBY.ready_to_start, false)
	end)

	test("ruleset_ready_requires_the_real_forced_ruleset", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.is_true((driver.ruleset_ready()))
		MP.LOBBY.config.ruleset = "ruleset_mp_blitz"
		local ok, code = driver.ruleset_ready()
		ctx.eq(ok, false)
		ctx.eq(code, "driver_bad_state")
	end)

	test("host_start_game_requires_guest_ready", function()
		local MP, funcs, calls = fake_engine({ code = "ABC12", ready_to_start = false })
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ok, code = driver.host_start_game()
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_not_ready")
		MP.LOBBY.ready_to_start = true
		local started = driver.host_start_game()
		ctx.is_true(started)
		local saw_start = false
		for _, call in ipairs(calls) do
			if call.name == "lobby_start_game" then
				saw_start = true
			end
		end
		ctx.is_true(saw_start)
	end)

	test("host_start_request_waits_for_real_run_and_freezes_options_immediately", function()
		local MP, funcs = fake_engine({ code = "ABC12", ready_to_start = true, is_host = true })
		local G = { STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 1 }
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G })
		ctx.is_true(driver.host_start_game())
		ctx.eq(driver.is_started(), false, "queued start is still a menu frame")
		ctx.eq(driver.guard_allows("lobbyOptions"), false, "options freeze before the reply")
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started(), "the actual initialized run opens the gate")
	end)

	test("send_guard_is_default_deny", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		ctx.is_true(driver.guard_allows("joinLobby"))
		ctx.is_true(driver.guard_allows("readyBlind"))
		ctx.eq(driver.guard_allows("get_end_game_jokers"), false)
		ctx.eq(driver.guard_allows("getEndGameJokers"), false)
		ctx.eq(driver.guard_allows("receiveEndGameJokers"), false)
		ctx.eq(driver.guard_allows("getNemesisDeck"), false)
		ctx.eq(driver.guard_allows("nemesisEndGameStats"), false)
		ctx.eq(driver.guard_allows("moddedAction"), false)
		ctx.eq(driver.guard_allows("mysteryAction"), false)
		ctx.eq(driver.guard_allows(nil), false)
	end)

	test("send_guard_preserves_required_life_and_timer_penalties", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		for _, action in ipairs({ "failTimer", "failPvPTimer", "startAnteTimer", "pauseAnteTimer" }) do
			ctx.is_true(driver.guard_allows(action), "penalty suppressed: " .. action)
		end
	end)

	test("send_guard_blocks_guest_lobby_options_and_create", function()
		local MP, funcs = fake_engine()
		MP.LOBBY.is_host = false
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		ctx.eq(driver.guard_allows("lobbyOptions"), false)
		ctx.eq(driver.guard_allows("createLobby"), false)
		ctx.is_true(driver.guard_allows("joinLobby"))
	end)

	test("send_guard_allows_host_options_only_before_start", function()
		local MP, funcs = fake_engine({ code = "ABC12", ready_to_start = true })
		MP.LOBBY.is_host = true
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.is_true(driver.guard_allows("lobbyOptions"))
		ctx.eq(driver.guard_allows("createLobby"), false, "already in a server-confirmed lobby")
		ctx.is_true(driver.host_start_game())
		ctx.eq(driver.guard_allows("lobbyOptions"), false, "configuration frozen after start")
	end)

	-- Real pinned Multiplayer initial state (core.lua:31 `MP.LOBBY.is_host =
	-- false`, no code) must not refuse the human host's own first createLobby.
	test("send_guard_human_initial_state_allows_create_only", function()
		local MP, funcs = fake_engine()
		MP.LOBBY.is_host = false
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.is_true(driver.guard_allows("createLobby"), "the host's real first createLobby must pass")
		ctx.eq(driver.guard_allows("lobbyOptions"), false, "options before the server confirms the host")
		ctx.eq(driver.guard_allows("joinLobby"), false, "a human never joins as guest")
		ctx.is_true(driver.guard_allows("rejoinLobby"), "the host's own automatic reconnect rejoin must pass")
	end)

	test("send_guard_human_after_server_confirmation_freezes_at_start", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		MP.LOBBY.is_host = true
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.is_true(driver.guard_allows("lobbyOptions"), "confirmed host may push options")
		ctx.eq(driver.guard_allows("createLobby"), false, "already joined: no second create")
		MP.LOBBY.ready_to_start = true
		ctx.is_true(driver.host_start_game())
		ctx.eq(driver.guard_allows("lobbyOptions"), false, "frozen after start")
		ctx.eq(driver.guard_allows("createLobby"), false, "frozen after start")
	end)

	test("send_guard_rejects_forged_ai_host_flag", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		MP.LOBBY.is_host = true
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		ctx.eq(driver.guard_allows("createLobby"), false, "the AI never creates a lobby")
		ctx.eq(driver.guard_allows("lobbyOptions"), false, "the AI never pushes lobby options")
		ctx.eq(driver.guard_allows("joinLobby"), false, "a forged host flag refuses the guest join")
		ctx.is_true(driver.guard_allows("rejoinLobby"), "token-bound reconnect rejoin is role-neutral")
	end)

	test("send_guard_allows_sync_client_and_blocks_the_private_set", function()
		local MP, funcs = fake_engine()
		local human = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ai = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		ctx.is_true(human.guard_allows("syncClient"))
		ctx.is_true(ai.guard_allows("syncClient"))
		for action in next, MPDriver.SEND_BLOCKED do
			ctx.eq(human.guard_allows(action), false, "human allowed " .. action)
			ctx.eq(ai.guard_allows(action), false, "ai allowed " .. action)
		end
	end)

	test("send_guard_wraps_and_restores_client_send", function()
		local MP, funcs = fake_engine()
		local sent = {}
		local client = {
			send = function(message)
				sent[#sent + 1] = message.action
				return "forwarded"
			end,
		}
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, client = client })
		local original = client.send
		local uninstall = driver.install_send_guard()
		ctx.is_true(type(uninstall) == "function")
		ctx.eq(client.send({ action = "joinLobby" }), "forwarded")
		local blocked, blocked_code = client.send({ action = "get_end_game_jokers" })
		ctx.eq(blocked, false)
		ctx.eq(blocked_code, "driver_send_blocked")
		ctx.eq(#sent, 1)
		uninstall()
		ctx.is_true(rawequal(client.send, original))
	end)

	test("install_send_guard_forwards_the_real_host_create_lobby", function()
		local MP, funcs = fake_engine()
		MP.LOBBY.is_host = false
		local sent = {}
		local client = {
			send = function(message)
				sent[#sent + 1] = message.action
				return "forwarded"
			end,
		}
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, client = client })
		local uninstall = driver.install_send_guard()
		ctx.is_true(type(uninstall) == "function")
		ctx.eq(client.send({ action = "createLobby" }), "forwarded")
		ctx.eq(#sent, 1)
		ctx.eq(sent[1], "createLobby")
	end)

	test("host_start_sends_real_create_lobby_through_the_guard_before_code", function()
		-- End-to-end over the path that failed natively: host_start -> original
		-- start_lobby -> create_lobby -> guarded Client.send, with the pinned
		-- initial is_host=false and the lobby code arriving only after the send.
		local MP, funcs = fake_engine()
		local sent = {}
		local client = {
			send = function(message)
				sent[#sent + 1] = message.action
				return "forwarded"
			end,
		}
		local original_start = funcs.start_lobby
		local send_result = nil
		funcs.start_lobby = function(e)
			local code_before = MP.LOBBY.code
			send_result = client.send({ action = "createLobby", gameMode = "attrition" })
			ctx.eq(code_before, nil, "no lobby code before the server answers")
			original_start(e)
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, client = client })
		ctx.is_true(type(driver.install_send_guard()) == "function")
		ctx.eq(MP.LOBBY.is_host, false)
		ctx.is_true(driver.host_start())
		ctx.eq(send_result, "forwarded", "the host's real createLobby must reach the server")
		ctx.eq(sent[1], "createLobby")
	end)

	test("is_started_tracks_the_real_run_stage_and_latches", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		local G = { STAGES = { MAIN_MENU = 1, RUN = 2 }, STAGE = 1 }
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = G })
		ctx.eq(driver.is_started(), false, "main menu is not a running match")
		ctx.eq(rawget(MP, "is_started"), nil, "no invented MP.is_started flag")
		ctx.eq(MP.LOBBY.started, nil, "no invented MP.LOBBY.started flag")
		G.STAGE = G.STAGES.RUN
		ctx.eq(driver.is_started(), true)
		G.STAGE = G.STAGES.MAIN_MENU
		ctx.eq(driver.is_started(), true, "the running match is latched")
	end)

	test("main_menu_ready_rejects_the_splash_screen", function()
		local MP, funcs = fake_engine()
		local G = {
			STAGES = { MAIN_MENU = 1, RUN = 2 },
			STATES = { MENU = 11, SPLASH = 12 },
			STAGE = 1,
			STATE = 12,
			MAIN_MENU_UI = {},
		}
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G })
		ctx.eq(driver.main_menu_ready(), false, "the splash state is not the menu")
		G.STATE = G.STATES.MENU
		ctx.eq(driver.main_menu_ready(), true)
		G.MAIN_MENU_UI = nil
		ctx.eq(driver.main_menu_ready(), false, "the menu UI handle is required")
	end)

	local function unlock_element(button)
		return { config = { id = "overlay_menu_back_button", button = button or "continue_unlock" } }
	end

	-- A real UIBox-shaped overlay: get_UIE_by_ID exists ONLY through the class
	-- metatable (never a raw field), exactly like the pinned UIBox class. A
	-- rawget-only implementation cannot resolve the back element.
	local function metatable_overlay(element)
		return setmetatable({}, {
			__index = {
				get_UIE_by_ID = function(_, id)
					if id == "overlay_menu_back_button" then
						return element
					end
					return nil
				end,
			},
		})
	end

	test("unlock_overlay_resolves_the_metatable_back_element_and_dismisses_it", function()
		local MP, funcs = fake_engine()
		local element = unlock_element()
		local overlay = metatable_overlay(element)
		local G = { OVERLAY_MENU = overlay }
		local dismissed, seen = 0, nil
		funcs.continue_unlock = function(e)
			dismissed = dismissed + 1
			seen = e
			G.OVERLAY_MENU = nil
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G })
		ctx.eq(rawget(overlay, "get_UIE_by_ID"), nil, "the method lives only on the metatable")
		ctx.is_true(rawequal(driver.unlock_overlay(), element))
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.is_true(ok)
		ctx.eq(code, "driver_ok")
		ctx.eq(dismissed, 1)
		ctx.is_true(rawequal(seen, element), "the real element is passed to continue_unlock")
		ctx.eq(G.OVERLAY_MENU, nil)
	end)

	test("unlock_overlay_ignores_foreign_overlays", function()
		local MP, funcs = fake_engine()
		local called = 0
		funcs.continue_unlock = function() called = called + 1 end
		-- Real generic-options back button: never the unlock callback.
		local options = metatable_overlay(unlock_element("exit_overlay_menu"))
		local G = { OVERLAY_MENU = options }
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = G })
		ctx.eq(driver.unlock_overlay(), nil)
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.eq(ok, false)
		ctx.eq(code, "driver_no_unlock_overlay")
		ctx.eq(called, 0)
		ctx.is_true(rawequal(G.OVERLAY_MENU, options))
		-- A Multiplayer-style overlay: unrelated back button, never matched.
		G.OVERLAY_MENU = metatable_overlay(unlock_element("mp_overlay_back"))
		ctx.eq(driver.unlock_overlay(), nil)
		driver.dismiss_unlock_overlay()
		ctx.eq(called, 0)
		-- A Multiplayer error overlay box with no matching back element.
		G.OVERLAY_MENU = setmetatable({}, { __index = { get_UIE_by_ID = function() return nil end } })
		ctx.eq(driver.unlock_overlay(), nil)
		local refused, refused_code = driver.dismiss_unlock_overlay()
		ctx.eq(refused, false)
		ctx.eq(refused_code, "driver_no_unlock_overlay")
	end)

	test("dismiss_unlock_overlay_refuses_cleanly_without_an_overlay", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = {} })
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.eq(ok, false)
		ctx.eq(code, "driver_no_unlock_overlay")
	end)

	test("dismiss_unlock_overlay_reports_a_missing_and_a_throwing_callback", function()
		local MP, funcs = fake_engine()
		local G = { OVERLAY_MENU = metatable_overlay(unlock_element()) }
		funcs.continue_unlock = nil
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = G })
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.eq(ok, false)
		ctx.eq(code, "driver_missing_callback")
		ctx.is_true(G.OVERLAY_MENU ~= nil)
		funcs.continue_unlock = function() error("boom") end
		local raised_ok, raised_code = driver.dismiss_unlock_overlay()
		ctx.eq(raised_ok, false)
		ctx.eq(raised_code, "driver_internal_error")
		ctx.is_true(G.OVERLAY_MENU ~= nil)
	end)

	test("dismiss_unlock_overlay_reports_bad_state_when_the_overlay_stays", function()
		local MP, funcs = fake_engine()
		local overlay = metatable_overlay(unlock_element())
		local G = { OVERLAY_MENU = overlay }
		funcs.continue_unlock = function() end
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, G = G })
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.eq(ok, false)
		ctx.eq(code, "driver_bad_state")
		ctx.is_true(rawequal(G.OVERLAY_MENU, overlay))
	end)

	test("dismiss_unlock_overlay_accepts_a_chained_next_overlay", function()
		local MP, funcs = fake_engine()
		local first = metatable_overlay(unlock_element())
		local second = metatable_overlay(unlock_element())
		local G = { OVERLAY_MENU = first }
		funcs.continue_unlock = function() G.OVERLAY_MENU = second end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G })
		local ok, code = driver.dismiss_unlock_overlay()
		ctx.is_true(ok)
		ctx.eq(code, "driver_ok")
		ctx.is_true(rawequal(G.OVERLAY_MENU, second))
	end)

	test("host_start_failure_after_create_is_fatal_not_rearmed", function()
		local MP, funcs, calls = fake_engine()
		-- The lobby is created but the real options are never forced.
		funcs.start_lobby = function()
			calls[#calls + 1] = { name = "start_lobby" }
			MP.LOBBY.code = "ABC12"
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ok, code = driver.host_start(nil)
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_force_failed")
	end)

	-- End-screen Joker reveal (NATIVE_TEST_PROGRESS "First human-played match"):
	-- blocked during play, allowed only once the match has legitimately ended,
	-- and only in the direction that shows the AI's Jokers to the human.
	local function reveal_engine(role)
		local MP, funcs = fake_engine({ code = "ABC12" })
		MP.GAME = { won = false }
		MP.GHOST = { active = nil, replay = nil }
		MP.GHOST.is_active = function()
			return MP.GHOST.active and MP.GHOST.replay ~= nil
		end
		local G = {
			STAGES = { MAIN_MENU = 1, RUN = 2 },
			STATES = { SELECTING_HAND = 1, GAME_OVER = 4, NEW_ROUND = 5 },
			STAGE = 1,
			STATE = 1,
		}
		local driver = MPDriver.factory({ role = role, mp = MP, funcs = funcs, G = G })
		return driver, MP, G
	end

	test("end_game_jokers_blocked_before_and_during_the_match", function()
		for _, role in ipairs({ "human", "ai" }) do
			local driver, MP, G = reveal_engine(role)
			ctx.eq(driver.is_complete(), false)
			ctx.eq(driver.guard_allows("getEndGameJokers"), false, role .. " lobby")
			ctx.eq(driver.guard_allows("receiveEndGameJokers"), false, role .. " lobby")
			G.STAGE = G.STAGES.RUN
			ctx.is_true(driver.is_started())
			for _, state in ipairs({ 1, 5 }) do
				G.STATE = state
				ctx.eq(driver.guard_allows("getEndGameJokers"), false, role .. " in play")
				ctx.eq(driver.guard_allows("receiveEndGameJokers"), false, role .. " in play")
			end
		end
	end)

	test("end_game_jokers_terminal_signal_before_start_is_refused", function()
		-- A stray won/GAME_OVER before the real match started (e.g. a menu frame)
		-- is not a legitimate match end.
		local driver, MP, G = reveal_engine("human")
		MP.GAME.won = true
		G.STATE = G.STATES.GAME_OVER
		ctx.eq(driver.is_complete(), false)
		ctx.eq(driver.guard_allows("getEndGameJokers"), false)
	end)

	test("end_game_jokers_allowed_after_win_or_loss_in_reveal_direction_only", function()
		for _, outcome in ipairs({ "win", "loss" }) do
			for _, role in ipairs({ "human", "ai" }) do
				local driver, MP, G = reveal_engine(role)
				G.STAGE = G.STAGES.RUN
				ctx.is_true(driver.is_started())
				if outcome == "win" then
					MP.GAME.won = true
				else
					G.STATE = G.STATES.GAME_OVER
				end
				ctx.is_true(driver.is_complete(), outcome)
				ctx.eq(driver.guard_allows("getEndGameJokers"), role == "human", role .. " " .. outcome .. " get")
				ctx.eq(driver.guard_allows("receiveEndGameJokers"), role == "ai", role .. " " .. outcome .. " receive")
				-- Deck/stats/ranked stay blocked after the match as well.
				ctx.eq(driver.guard_allows("getNemesisDeck"), false)
				ctx.eq(driver.guard_allows("receiveNemesisDeck"), false)
				ctx.eq(driver.guard_allows("nemesisEndGameStats"), false)
				ctx.eq(driver.guard_allows("submitResult"), false)
			end
		end
	end)

	test("end_game_jokers_reveal_closes_when_the_lobby_resets", function()
		local driver, MP, G = reveal_engine("ai")
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		MP.GAME.won = true
		ctx.is_true(driver.guard_allows("receiveEndGameJokers"))
		-- MP.reset_game_states on return to lobby clears the terminal signal.
		MP.GAME = { won = false }
		G.STAGE = G.STAGES.MAIN_MENU
		G.STATE = 1
		ctx.eq(driver.guard_allows("receiveEndGameJokers"), false)
		-- Leaving the lobby also closes it even if a stale won flag lingered.
		MP.GAME.won = true
		MP.LOBBY.code = nil
		ctx.eq(driver.guard_allows("receiveEndGameJokers"), false)
	end)

	test("end_game_jokers_refused_while_a_ghost_replay_is_active", function()
		local driver, MP, G = reveal_engine("human")
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		MP.GHOST.active = true
		MP.GHOST.replay = {}
		G.STATE = G.STATES.GAME_OVER
		ctx.eq(driver.guard_allows("getEndGameJokers"), false)
		MP.GHOST.is_active = function()
			error("boom")
		end
		ctx.eq(driver.guard_allows("getEndGameJokers"), false, "a failing ghost probe fails closed")
		MP.GHOST.is_active = function()
			return false
		end
		ctx.is_true(driver.guard_allows("getEndGameJokers"))
	end)

	test("end_game_jokers_send_guard_passes_real_payload_after_end", function()
		local driver, MP, G = reveal_engine("ai")
		local sent = {}
		local client = { send = function(message) sent[#sent + 1] = message.action return true end }
		driver = MPDriver.factory({ role = "ai", mp = MP, funcs = {}, G = G, client = client })
		ctx.is_true(driver.install_send_guard() ~= nil)
		ctx.eq(client.send({ action = "receiveEndGameJokers", keys = "x" }), false)
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		G.STATE = G.STATES.GAME_OVER
		ctx.is_true(client.send({ action = "receiveEndGameJokers", keys = "x" }))
		ctx.eq(client.send({ action = "getEndGameJokers" }), false)
		ctx.eq(#sent, 1)
		ctx.eq(sent[1], "receiveEndGameJokers")
	end)

	test("end_game_reveal_table_is_exactly_two_role_bound_entries", function()
		local count = 0
		for action, role in pairs(MPDriver.ENDGAME_REVEAL) do
			count = count + 1
			ctx.is_true(role == "human" or role == "ai", action)
			ctx.eq(MPDriver.SEND_BLOCKED[action], nil, action .. " also blocked")
			ctx.eq(MPDriver.HOST_ONLY[action], nil, action .. " also host-only")
			ctx.eq(MPDriver.GUEST_ONLY[action], nil, action .. " also guest-only")
			ctx.eq(MPDriver.SEND_ALLOWLIST[action], nil, action .. " also always-allowed")
		end
		ctx.eq(count, 2)
		ctx.eq(MPDriver.ENDGAME_REVEAL.getEndGameJokers, "human")
		ctx.eq(MPDriver.ENDGAME_REVEAL.receiveEndGameJokers, "ai")
	end)

	test("end_game_reveal_requires_a_boolean_true_won_flag", function()
		for _, value in ipairs({ 1, "true", {} }) do
			local driver, MP, G = reveal_engine("human")
			G.STAGE = G.STAGES.RUN
			ctx.is_true(driver.is_started())
			MP.GAME.won = value
			ctx.eq(driver.guard_allows("getEndGameJokers"), false, tostring(value))
		end
		-- The real reset leaves `won` unset rather than false.
		local driver, MP, G = reveal_engine("human")
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		MP.GAME = {}
		ctx.eq(driver.guard_allows("getEndGameJokers"), false)
	end)

	test("end_game_reveal_stays_open_for_the_same_match_after_state_moves", function()
		local driver, MP, G = reveal_engine("ai")
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		G.STATE = G.STATES.GAME_OVER
		ctx.is_true(driver.guard_allows("receiveEndGameJokers"))
		-- A queued engine event moves the state off GAME_OVER on the same match.
		G.STATE = G.STATES.NEW_ROUND
		ctx.is_true(driver.guard_allows("receiveEndGameJokers"), "latched for this match")
		-- A new match (reset_game_states builds a new MP.GAME) ends the latch.
		MP.GAME = { won = false }
		ctx.eq(driver.guard_allows("receiveEndGameJokers"), false, "new match closes it")
	end)

	test("end_game_reveal_through_the_human_send_wrapper", function()
		local _, MP, G = reveal_engine("human")
		local sent = {}
		local client = { send = function(message) sent[#sent + 1] = message.action return true end }
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = {}, G = G, client = client })
		ctx.is_true(driver.install_send_guard() ~= nil)
		G.STAGE = G.STAGES.RUN
		ctx.is_true(driver.is_started())
		ctx.eq(client.send({ action = "getEndGameJokers" }), false, "blocked during play")
		MP.GAME.won = true
		ctx.is_true(client.send({ action = "getEndGameJokers" }))
		ctx.eq(client.send({ action = "receiveEndGameJokers", keys = "x" }), false, "human build never sent")
		ctx.eq(#sent, 1)
		ctx.eq(sent[1], "getEndGameJokers")
	end)

	test("known_mod_sends_are_suppressed_once_and_still_refused", function()
		for _, role in ipairs({ "human", "ai" }) do
			local MP, funcs = fake_engine({ code = "ABC12" })
			local records = {}
			local sent = {}
			local client = { send = function(message) sent[#sent + 1] = message.action return true end }
			local logger = { record = function(fields) records[#records + 1] = fields end }
			local driver = MPDriver.factory({ role = role, mp = MP, funcs = funcs, client = client, logger = logger })
			ctx.is_true(driver.install_send_guard() ~= nil)
			for _ = 1, 3 do
				ctx.eq(client.send({ action = "handyMPExtensionDisable" }), false)
				ctx.eq(client.send({ action = "handyMPExtensionEnable" }), false)
				ctx.eq(client.send({ action = "streamLogLines", gameId = "g", lines = "x" }), false)
				ctx.eq(client.send({ action = "mysteryAction" }), false)
			end
			ctx.eq(#sent, 0, "nothing reaches the transport")
			local suppressed, blocked = {}, 0
			for _, record in ipairs(records) do
				if record.code == "driver_send_suppressed" then
					suppressed[record.action] = (suppressed[record.action] or 0) + 1
				elseif record.code == "driver_send_blocked" then
					blocked = blocked + 1
					ctx.eq(record.action, "mysteryAction")
				end
			end
			ctx.eq(suppressed.handyMPExtensionDisable, 1, role)
			ctx.eq(suppressed.handyMPExtensionEnable, 1, role)
			ctx.eq(suppressed.streamLogLines, 1, role)
			ctx.eq(blocked, 3, "unknown blocked sends are logged every time")
		end
	end)

	test("suppressed_reasons_never_allow_anything", function()
		local MP, funcs = fake_engine()
		for action in pairs(MPDriver.SEND_SUPPRESSED_REASONS) do
			ctx.eq(MPDriver.SEND_ALLOWLIST[action], nil, action)
			ctx.eq(MPDriver.ENDGAME_REVEAL[action], nil, action)
			for _, role in ipairs({ "human", "ai" }) do
				local driver = MPDriver.factory({ role = role, mp = MP, funcs = funcs })
				ctx.eq(driver.guard_allows(action), false, role .. " " .. action)
			end
		end
	end)

	test("suppressed_log_line_carries_reason_through_the_real_logger", function()
		local Logger = support.mod(ctx.repo_root, "AISparring/src/logger.lua")
		local lines = {}
		local inner = Logger.new(function(level, line)
			lines[#lines + 1] = line
		end)
		local logger = {
			record = function(fields)
				return inner:log("info", fields.event or "companion", fields)
			end,
		}
		local MP, funcs = fake_engine({ code = "ABC12" })
		local client = { send = function() return true end }
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, client = client, logger = logger })
		ctx.is_true(driver.install_send_guard() ~= nil)
		client.send({ action = "submitLogHashes" })
		client.send({ action = "submitLogHashes" })
		ctx.eq(#lines, 1)
		ctx.is_true(string.find(lines[1], 'code="driver_send_suppressed"', 1, true) ~= nil, lines[1])
		ctx.is_true(string.find(lines[1], 'action="submitLogHashes"', 1, true) ~= nil, lines[1])
		ctx.is_true(string.find(lines[1], 'detail="mp_replay_log_off"', 1, true) ~= nil, lines[1])
	end)

	test("suppression_snapshot_ignores_later_table_edits_and_resets_per_install", function()
		local MP, funcs = fake_engine({ code = "ABC12" })
		local records = {}
		local client = { send = function() return true end }
		local logger = { record = function(fields) records[#records + 1] = fields end }
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, client = client, logger = logger })
		MPDriver.SEND_SUPPRESSED_REASONS.mysteryAction = "sneaky"
		local uninstall = driver.install_send_guard()
		client.send({ action = "mysteryAction" })
		client.send({ action = "mysteryAction" })
		MPDriver.SEND_SUPPRESSED_REASONS.mysteryAction = nil
		local blocked = 0
		for _, record in ipairs(records) do
			if record.code == "driver_send_blocked" then
				blocked = blocked + 1
			end
		end
		ctx.eq(blocked, 2, "an added entry cannot silence other refusals")
		ctx.is_true(uninstall())
		records = {}
		logger.record = function(fields) records[#records + 1] = fields end
		driver.install_send_guard()
		client.send({ action = "handyMPExtensionDisable" })
		ctx.eq(#records, 1, "a fresh install logs the first suppression again")
	end)

	-- Ranked contract: the real registry `is_disabled()` gate and the typed
	-- canonical digest read from the actual live configuration.

	local function ranked_engine(opts)
		opts = opts or {}
		local MP, funcs = fake_engine(opts)
		MP.MODIFIERS = {}
		if opts.no_is_disabled then
			MP.Rulesets.ruleset_mp_standard_ranked.is_disabled = nil
		end
		return MP, funcs
	end

	test("ruleset_disabled_calls_the_real_registry_function", function()
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local disabled, code = driver.ruleset_disabled()
		ctx.eq(disabled, false)
		ctx.eq(code, "driver_ok")
		local disabled_engine, disabled_funcs = ranked_engine({ disabled = true })
		local disabled_driver = MPDriver.factory({ role = "ai", mp = disabled_engine, funcs = disabled_funcs })
		ctx.eq(disabled_driver.ruleset_disabled(), true)
	end)

	test("both_roles_refuse_create_and_join_when_the_ruleset_is_disabled", function()
		local MP, funcs = ranked_engine({ disabled = true })
		local human = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ok, code = human.host_start(nil)
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_ruleset_disabled")
		local ai = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		local joined, join_code = ai.ai_join("abc12")
		ctx.eq(joined, nil)
		ctx.eq(join_code, "driver_ruleset_disabled")
	end)

	test("missing_is_disabled_fails_closed_before_create_join", function()
		local MP, funcs = ranked_engine({ no_is_disabled = true })
		local human = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local ok, code = human.host_start(nil)
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_no_is_disabled")
		local ai = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		local joined, join_code = ai.ai_join("abc12")
		ctx.eq(joined, nil)
		ctx.eq(join_code, "driver_no_is_disabled")
	end)

	test("ranked_config_digest_reads_actual_config_and_is_sensitive", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config,
		})
		MP.LOBBY.config.timer_base_seconds = 150
		local digest, code = driver.ranked_config_digest()
		ctx.eq(code, "driver_ok")
		ctx.is_true(type(digest) == "string" and #digest == 8, tostring(digest))
		-- The digest is exactly the typed canonical binding over the actual
		-- config; a real config change moves it.
		MP.LOBBY.config.timer_base_seconds = 151
		local moved = driver.ranked_config_digest()
		ctx.is_true(moved ~= digest, "a changed actual config value moves the digest")
		-- The override fields are nil-only: any injected real value is refused
		-- outright (no digest), not merely a different binding.
		MP.LOBBY.config.normal_bosses = "bl_mp_nemesis"
		local refused = driver.ranked_config_digest()
		ctx.eq(refused, nil, "an injected override is refused")
		MP.LOBBY.config.normal_bosses = false
		ctx.eq(driver.ranked_config_digest(), nil, "a boolean override is refused")
		MP.LOBBY.config.normal_bosses = nil
		ctx.is_true(driver.ranked_config_digest() ~= nil, "clearing the override restores the digest")
	end)

	test("ranked_digest_accepts_only_the_pinned_lobby_options_envelope", function()
		local parity = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs, ranked_config = parity })
		local baseline = driver.ranked_config_digest()
		ctx.is_true(type(baseline) == "string")
		MP.LOBBY.config.action = "lobbyOptions"
		ctx.eq(driver.ranked_config_digest(), baseline, "transport envelope preserves the rules digest")
		MP.LOBBY.config.action = "startGame"
		ctx.eq(driver.ranked_config_digest(), nil, "an unrelated action is refused")
		MP.LOBBY.config.action = true
		ctx.eq(driver.ranked_config_digest(), nil, "an invalid action type is refused")
		MP.LOBBY.config.action = "lobbyOptions"
		MP.LOBBY.config.injected_rule = true
		ctx.eq(driver.ranked_config_digest(), nil, "unknown options remain refused")
	end)

	test("post_start_selection_state_reads_the_actual_initialized_run", function()
		local MP, funcs = ranked_engine()
		local G = { GAME = {} }
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G })
		local key, stake = driver.post_start_selection_state()
		ctx.eq(key, nil)
		ctx.eq(stake, nil)
		G.GAME.selected_back = { effect = { center = { key = "b_red" } } }
		G.GAME.stake = 1
		key, stake = driver.post_start_selection_state()
		ctx.eq(key, "b_red")
		ctx.eq(stake, 1)
	end)

	test("host_start_applies_selected_back_and_stake_before_force", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config })
		local selection = {
			schema = "aisparring.ranked_selection.v1",
			deck_key = "blue", back_key = "b_blue", back_name = "Blue Deck",
			stake_key = "green", stake_index = 2,
		}
		ctx.is_true(driver.host_start(nil, selection))
		ctx.eq(MP.LOBBY.config.back, "Blue Deck", "selected Back NAME applied")
		ctx.eq(MP.LOBBY.config.stake, 2, "selected stake INDEX applied")
		ctx.eq(MP.LOBBY.config.different_decks, false)
		ctx.eq(MP.LOBBY.config.random_loadout, false)
	end)

	test("host_start_refuses_a_malformed_selection", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config })
		local ok, code = driver.host_start(nil, { deck_key = "blue" })
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_bad_selection")
	end)

	test("host_start_restores_ruleset_and_config_proxy_on_create_fault", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = fake_engine()
		local original_ruleset = MP.current_ruleset
		funcs.start_lobby = function()
			error("synthetic create fault")
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config })
		local selection = {
			schema = "aisparring.ranked_selection.v1",
			deck_key = "blue", back_key = "b_blue", back_name = "Blue Deck",
			stake_key = "green", stake_index = 2,
		}
		local ok, code = driver.host_start(nil, selection)
		ctx.eq(ok, nil)
		ctx.eq(code, "driver_start_lobby_failed")
		ctx.eq(MP.current_ruleset, original_ruleset, "the ruleset proxy is restored")
		ctx.is_true(getmetatable(MP.LOBBY.config) == nil, "the temporary config proxy is restored")
	end)

	-- B3: the actual lobby gamemode is bound and unknown raw keys are refused.

	test("ranked_digest_refuses_unknown_raw_config_keys", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config,
		})
		ctx.is_true(driver.ranked_config_digest() ~= nil, "baseline digest")
		MP.LOBBY.config.injected_extra = 1
		ctx.eq(driver.ranked_config_digest(), nil, "an unknown raw key is refused, not dropped")
		MP.LOBBY.config.injected_extra = nil
		ctx.is_true(driver.ranked_config_digest() ~= nil, "removing it restores the digest")
	end)

	test("ranked_digest_binds_the_actual_lobby_gamemode", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config,
		})
		ctx.is_true(driver.ranked_config_digest() ~= nil, "attrition gamemode binds")
		MP.LOBBY.config.gamemode = "gamemode_mp_showdown"
		ctx.eq(driver.ranked_config_digest(), nil, "a mismatched live gamemode is refused")
	end)

	test("ranked_digest_uses_the_real_engine_chain_and_timers", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config,
		})
		local baseline = driver.ranked_config_digest()
		ctx.is_true(baseline ~= nil)
		-- The real engine producer is preferred when present.
		MP.active_layer_chain = function()
			return { "standard", "ranked", "pvp_timer", "standard_ranked" }
		end
		MP.UTILS = {
			timer_base = function() return 150 end,
			pvp_timer_base = function() return 60 end,
		}
		ctx.eq(driver.ranked_config_digest(), baseline, "the real engine chain/timers agree")
		-- A real chain that differs from the registry is bound, not faked.
		MP.active_layer_chain = function()
			return { "standard", "ranked", "pvp_timer", "standard_ranked", "pressure_timer" }
		end
		ctx.is_true(driver.ranked_config_digest() ~= baseline, "a changed real chain changes the digest")
	end)

	test("ruleset_disabled_reports_a_localized_reason_as_disabled", function()
		local MP, funcs = ranked_engine()
		MP.Rulesets.ruleset_mp_standard_ranked.is_disabled = function()
			return "k_ruleset_disabled_smods_version"
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		local disabled, code = driver.ruleset_disabled()
		ctx.eq(disabled, true)
		ctx.eq(code, "driver_ok")
		local ok, host_code = driver.host_start(nil)
		ctx.eq(ok, nil)
		ctx.eq(host_code, "driver_ruleset_disabled")
	end)

	-- B6: the real readiness producers and the fixture override.

	test("readiness_facts_read_real_producers", function()
		local MP, funcs = ranked_engine()
		MP.UTILS = {
			unlock_check = function() return true end,
			parse_Hash = function(text)
				return { unlocked = text:find("unlocked=true", 1, true) ~= nil, Mods = { Multiplayer = "0.5.5" } }
			end,
			get_banned_mods = function() return {} end,
		}
		MP.MOD_STRING = "preview=true;unlocked=true;Multiplayer-0.5.5"
		-- The live fact is the actual MP.INTEGRATIONS table, not the mod config.
		MP.INTEGRATIONS = { Preview = true }
		MP.config = { integrations = { Preview = true } }
		MP.LOBBY.is_host = true
		-- A real lobbyInfo carries both entries; check both explicitly.
		MP.LOBBY.host = { cached = true, config = { unlocked = true, Mods = { Multiplayer = "0.5.5" } } }
		MP.LOBBY.guest = { cached = true, config = { unlocked = true, Mods = { Multiplayer = "0.5.5" } } }
		local G = {
			SETTINGS = { profile = 1, GAMESPEED = 1 },
			PROFILES = { { all_unlocked = true } },
		}
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, G = G,
			release_mode = true,
			approved_mods = { Multiplayer = "0.5.5" },
		})
		local facts = driver.readiness_facts()
		ctx.eq(facts.unlock_check, true)
		ctx.eq(facts.all_unlocked, true)
		ctx.eq(facts.advertised_unlocked, true)
		ctx.eq(facts.advertised_preview, true)
		ctx.eq(facts.advertised_preview_valid, true)
		ctx.eq(facts.live_preview, true)
		ctx.eq(facts.preview_consistent, true)
		ctx.eq(facts.peer_unlocked, true)
		ctx.eq(facts.peer_cached, true)
		ctx.eq(facts.banned_mods_empty, true)
		ctx.eq(facts.mods_approved, true)
		ctx.eq(facts.release_mode, true)
		ctx.eq(facts.game_speed_ok, true)
		-- No reviewed producer yet: honest unknown.
		ctx.eq(facts.debug_disabled, "unknown")
		ctx.eq(facts.animations_normal, "unknown")
		ctx.eq(facts.handy_ranked_safe, "unknown")
		-- Unknown facts refuse readiness; no caller flag can make it pass.
		ctx.eq(driver.readiness_ok(), false)
		-- A too-fast game speed is refused.
		G.SETTINGS.GAMESPEED = 5
		ctx.eq(driver.readiness_facts().game_speed_ok, false)
	end)

	test("advertised_preview_reads_the_cached_once_boot_token", function()
		local function facts_for(mod_string, live)
			local MP, funcs = ranked_engine()
			MP.UTILS = {
				unlock_check = function() return true end,
				parse_Hash = function() return { unlocked = true, Mods = { Multiplayer = "0.5.5" } } end,
				get_banned_mods = function() return {} end,
			}
			MP.MOD_STRING = mod_string
			-- Only the actual MP.INTEGRATIONS.Preview is live evidence.
			MP.INTEGRATIONS = { Preview = live }
			MP.config = { integrations = { Preview = not live } }
			MP.LOBBY.is_host = true
			MP.LOBBY.guest = { cached = true, config = { unlocked = true, Mods = { Multiplayer = "0.5.5" } } }
			local driver = MPDriver.factory({
				role = "human", mp = MP, funcs = funcs,
				G = { SETTINGS = { profile = 1, GAMESPEED = 1 }, PROFILES = { { all_unlocked = true } } },
				release_mode = true, approved_mods = { Multiplayer = "0.5.5" },
			})
			return driver.readiness_facts()
		end
		-- Cached false beats the live true setting.
		local cached_false = facts_for("preview=false;unlocked=true;Multiplayer-0.5.5", true)
		ctx.eq(cached_false.advertised_preview, false)
		ctx.eq(cached_false.advertised_preview_valid, true)
		ctx.eq(cached_false.live_preview, true)
		ctx.eq(cached_false.preview_consistent, false)
		-- Cached true beats the live false setting.
		local cached_true = facts_for("preview=true;unlocked=true;Multiplayer-0.5.5", false)
		ctx.eq(cached_true.advertised_preview, true)
		ctx.eq(cached_true.live_preview, false)
		ctx.eq(cached_true.preview_consistent, false)
		-- Missing token is unknown, never defaulted.
		local missing = facts_for("unlocked=true;Multiplayer-0.5.5", false)
		ctx.eq(missing.advertised_preview, "unknown")
		ctx.eq(missing.advertised_preview_valid, false)
		-- Duplicate token is unknown.
		local duplicate = facts_for("preview=true;preview=false;unlocked=true", false)
		ctx.eq(duplicate.advertised_preview, "unknown")
		-- Malformed token is unknown.
		local malformed = facts_for("preview=yes;unlocked=true", false)
		ctx.eq(malformed.advertised_preview, "unknown")
	end)

	test("optional_disabled_preview_is_a_positive_control", function()
		local MP, funcs = ranked_engine()
		local ok_facts = {}
		for _, key in ipairs(MPDriver.READINESS_KEYS) do
			ok_facts[key] = true
		end
		-- Preview is optional: both raw booleans false, predicates true.
		ok_facts.advertised_preview = false
		ok_facts.live_preview = false
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, readiness_override = ok_facts,
		})
		ctx.eq(driver.readiness_ok(), true)
		-- Unknown evidence refuses even when predicates are true.
		ok_facts.advertised_preview = "unknown"
		local unknown = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, readiness_override = ok_facts,
		})
		ctx.eq(unknown.readiness_facts(), nil, "evidence keys must be booleans")
	end)

	test("readiness_override_is_a_fixture_only_port", function()
		local MP, funcs = ranked_engine()
		local ok_facts = {}
		for _, key in ipairs(MPDriver.READINESS_KEYS) do
			ok_facts[key] = true
		end
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, readiness_override = ok_facts,
		})
		ctx.eq(driver.readiness_ok(), true)
		-- A malformed override is refused.
		local bad = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, readiness_override = { unlock_check = "yes" },
		})
		ctx.eq(bad.readiness_facts(), nil)
	end)

	-- Nonblocking hardening negative controls.

	test("config_only_preview_is_not_live_evidence", function()
		local MP, funcs = ranked_engine()
		MP.UTILS = {
			unlock_check = function() return true end,
			parse_Hash = function() return { unlocked = true, Mods = { Multiplayer = "0.5.5" } } end,
			get_banned_mods = function() return {} end,
		}
		MP.MOD_STRING = "preview=true;unlocked=true;Multiplayer-0.5.5"
		MP.LOBBY.is_host = true
		MP.LOBBY.guest = { cached = true, config = { unlocked = true, Mods = { Multiplayer = "0.5.5" } } }
		local G = { SETTINGS = { profile = 1, GAMESPEED = 1 }, PROFILES = { { all_unlocked = true } } }
		-- Load-time config metadata must NOT be read as the live integration fact.
		MP.config = { integrations = { Preview = true } }
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, G = G,
			release_mode = true, approved_mods = { Multiplayer = "0.5.5" },
		})
		local facts = driver.readiness_facts()
		ctx.eq(facts.live_preview, "unknown", "config integrations is not live evidence")
		ctx.eq(facts.preview_consistent, false, "a missing live fact is never consistent")
	end)

	test("release_mode_false_stays_false", function()
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, release_mode = false })
		ctx.eq(driver.readiness_facts().release_mode, false, "false is reported as false, not unknown")
		local missing = MPDriver.factory({ role = "human", mp = MP, funcs = funcs })
		ctx.eq(missing.readiness_facts().release_mode, "unknown", "a missing producer is unknown")
	end)

	test("ranked_profile_producer_is_primitive_and_fault_closed", function()
		local MP, funcs = ranked_engine()
		local G = { SETTINGS = { profile = 1, GAMESPEED = 1 }, PROFILES = { { all_unlocked = true } } }
		for _, producer in ipairs({
			function() error("producer fault") end,
			function() return { debug_disabled = "true", animations_normal = 1, handy_ranked_safe = {} } end,
		}) do
			local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G,
				ranked_profile_facts = producer })
			local facts = driver.readiness_facts()
			ctx.eq(facts.debug_disabled, "unknown")
			ctx.eq(facts.animations_normal, "unknown")
			ctx.eq(driver.readiness_ok(), false)
		end
		local driver = MPDriver.factory({ role = "human", mp = MP, funcs = funcs, G = G,
			ranked_profile_facts = function() return { debug_disabled = false, animations_normal = true,
				handy_ranked_safe = true, content_unlocked = false } end })
		ctx.eq(driver.readiness_facts().debug_disabled, false)
		ctx.eq(driver.readiness_facts().all_unlocked, false)
		ctx.eq(driver.readiness_ok(), false)
	end)

	test("missing_peer_mods_is_unknown_not_empty_safe", function()
		local MP, funcs = ranked_engine()
		MP.UTILS = {
			unlock_check = function() return true end,
			parse_Hash = function() return { unlocked = true, Mods = { Multiplayer = "0.5.5" } } end,
			get_banned_mods = function(mods) return {} end,
		}
		MP.MOD_STRING = "unlocked=true;Multiplayer-0.5.5"
		MP.INTEGRATIONS = { Preview = true }
		MP.LOBBY.is_host = true
		-- A peer packet with no Mods table must be unknown, never "no banned mods".
		MP.LOBBY.guest = { cached = true, config = { unlocked = true } }
		local G = { SETTINGS = { profile = 1, GAMESPEED = 1 }, PROFILES = { { all_unlocked = true } } }
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, G = G,
			release_mode = true, approved_mods = { Multiplayer = "0.5.5" },
		})
		local facts = driver.readiness_facts()
		ctx.eq(facts.banned_mods_empty, "unknown", "missing Mods is unknown")
		ctx.eq(facts.mods_approved, "unknown", "missing Mods is never an approved empty inventory")
	end)

	test("faulting_timer_and_proxy_producers_refuse", function()
		local ranked_config = support.mod(ctx.repo_root, "AISparring/integration/ranked_config.lua")
		local MP, funcs = ranked_engine()
		local driver = MPDriver.factory({
			role = "human", mp = MP, funcs = funcs, ranked_config = ranked_config,
		})
		ctx.is_true(driver.ranked_config_digest() ~= nil, "baseline digest")
		-- A real producer that throws is malformed, never an absent fallback.
		MP.UTILS = { timer_base = function() error("boom") end, pvp_timer_base = function() return 60 end }
		ctx.eq(driver.ranked_config_digest(), nil, "a throwing timer_base refuses")
		MP.UTILS = nil
		ctx.is_true(driver.ranked_config_digest() ~= nil, "removing the faulty producer restores the digest")
		-- A present proxy whose field indexing errors refuses too.
		MP.current_ruleset = function()
			return setmetatable({}, {
				__index = function(_, key)
					if key == "timer_base_multiplier" then
						error("proxy fault")
					end
					return nil
				end,
			})
		end
		ctx.eq(driver.ranked_config_digest(), nil, "a faulting proxy field refuses")
	end)
end

