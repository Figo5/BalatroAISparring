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
				config = { custom_seed = "random", ruleset = "ruleset_mp_majorleague" },
			},
			Rulesets = { ruleset_mp_majorleague = ruleset },
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
		ctx.eq(MP.LOBBY.config.ruleset, "ruleset_mp_majorleague")
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

	test("send_guard_is_default_deny", function()
		local MP, funcs = fake_engine()
		local driver = MPDriver.factory({ role = "ai", mp = MP, funcs = funcs })
		ctx.is_true(driver.guard_allows("joinLobby"))
		ctx.is_true(driver.guard_allows("readyBlind"))
		ctx.eq(driver.guard_allows("get_end_game_jokers"), false)
		ctx.eq(driver.guard_allows("getEndGameJokers"), false)
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
end
