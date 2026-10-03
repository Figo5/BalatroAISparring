-- Honest fake UI tree for AI Sparring menu tests.
--
-- This is a test fixture, not the real engine. It reproduces the node shape that
-- vanilla create_UIBox_generic_options returns (root -> R -> C -> contents R ->
-- contents) so the narrow Play-menu wrap and the settings widgets are exercised
-- the same way they are in the game. It records button/overlay calls for
-- assertions and exposes a plain G.FUNCS table the controller registers into.

local FakeUI = {}

function FakeUI.new()
	local state = {
		buttons = {},
		overlays = {},
		exits = 0,
		notifications = {},
		funcs = {},
	}

	local UIT = { ROOT = "ROOT", R = "R", C = "C", T = "T", B = "B", O = "O" }
	local C = {
		BLUE = { 0, 0, 1 },
		RED = { 1, 0, 0 },
		GREEN = { 0, 1, 0 },
		PURPLE = { 0.5, 0, 1 },
		GOLD = { 1, 0.8, 0 },
		BLACK = { 0, 0, 0 },
		L_BLACK = { 0.1, 0.1, 0.1 },
		UI = { TEXT_LIGHT = { 1, 1, 1 }, TEXT_DARK = { 0, 0, 0 }, RED = { 1, 0, 0 } },
	}
	local G = { UIT = UIT, C = C, UIDEF = {} }

	local function UIBox_button(args)
		args = args or {}
		state.buttons[#state.buttons + 1] = {
			id = args.id,
			button = args.button or "exit_overlay_menu",
			label = args.label,
			colour = args.colour,
		}
		return {
			n = UIT.R,
			config = { align = "cm", id = args.id, button = args.button or "exit_overlay_menu", colour = args.colour },
			nodes = {
				{ n = UIT.C, config = { align = "cm" }, nodes = {
					{ n = UIT.T, config = { text = (args.label and args.label[1]) or "", scale = args.scale or 0.4 } },
				} },
			},
		}
	end

	local function create_UIBox_generic_options(args)
		args = args or {}
		local contents = args.contents or {}
		return {
			n = UIT.ROOT,
			config = { align = "cm" },
			nodes = {
				{ n = UIT.R, config = { align = "cm" }, nodes = {
					{ n = UIT.C, config = { align = "cm" }, nodes = {
						{ n = UIT.R, config = { align = "cm" }, nodes = contents },
					} },
				} },
				{ n = UIT.R, config = { align = "cm" }, nodes = {} },
			},
		}
	end

	local ui = {
		G = G,
		funcs = state.funcs,
		UIBox_button = UIBox_button,
		create_UIBox_generic_options = create_UIBox_generic_options,
		overlay_menu = function(definition)
			state.overlays[#state.overlays + 1] = definition
			return true
		end,
		exit_overlay_menu = function()
			state.exits = state.exits + 1
			return true
		end,
		notify = function(level, message)
			state.notifications[#state.notifications + 1] = { level = level, message = message }
		end,
	}

	return ui, state
end

return FakeUI
