-- Declarative AI Sparring menu widgets.
--
-- This module builds Balatro UI node trees only. It performs no gameplay work,
-- reads no game globals, runs no process and consumes no randomness. The host
-- bootstrap injects the UI primitives (the UIT/C constant tables plus the
-- original UIBox_button/create_UIBox_generic_options builders) so the same
-- builders can be exercised against a fake UI tree in tests.
--
-- Returned definitions reference global callback names owned by
-- integration/menu_controller.lua. This module never registers handlers, never
-- touches Multiplayer transport and never maps a gauntlet index to a seed.

local PracticeMenu = {}

local CODE = {
	OK = "menu_ok",
	BAD_UI = "menu_bad_ui",
	BAD_STATE = "menu_bad_state",
}

local function is_plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

PracticeMenu.CODE = CODE

function PracticeMenu.factory(ui)
	if not is_plain_table(ui) then
		return nil, CODE.BAD_UI
	end
	local constants = rawget(ui, "G")
	-- The live `G` is `Game = Object:extend()` and therefore carries a metatable
	-- (engine/object.lua); the factory must accept any table. The plain-table
	-- checks are kept for the nested constant tables, which really are plain
	-- fields on the instance.
	if type(constants) ~= "table" then
		return nil, CODE.BAD_UI
	end
	local UIT = rawget(constants, "UIT")
	local C = rawget(constants, "C")
	if not is_plain_table(UIT) or not is_plain_table(C) then
		return nil, CODE.BAD_UI
	end
	local button_builder = rawget(ui, "UIBox_button")
	local options_builder = rawget(ui, "create_UIBox_generic_options")
	if type(button_builder) ~= "function" or type(options_builder) ~= "function" then
		return nil, CODE.BAD_UI
	end

	local instance = {}

	local function text(value, scale, colour)
		return {
			n = UIT.T,
			config = {
				text = value,
				scale = scale or 0.4,
				colour = colour or C.UI.TEXT_LIGHT,
				shadow = true,
			},
		}
	end

	local function row(nodes, padding)
		return { n = UIT.R, config = { align = "cm", padding = padding or 0.1 }, nodes = nodes or {} }
	end

	local function find_label(list, key, value)
		if type(list) ~= "table" then
			return tostring(value)
		end
		for i = 1, #list do
			local item = list[i]
			if is_plain_table(item) and item[key] == value then
				return item.label or tostring(value)
			end
		end
		return tostring(value)
	end

	local function choice_buttons(namespace, list, current)
		local nodes = {}
		if type(list) ~= "table" then
			return nodes
		end
		for i = 1, #list do
			local item = list[i]
			if is_plain_table(item) and type(item.id) == "string" then
				local chosen = item.id == current
				nodes[#nodes + 1] = button_builder({
					id = "aisp:" .. namespace .. ":" .. item.id,
					label = { item.label or item.id },
					colour = chosen and C.GREEN or C.BLUE,
					minw = 3.5,
					minh = 0.5,
					scale = 0.35,
					button = "aisp_select",
				})
			end
		end
		return nodes
	end

	local function gauntlet_buttons(list, current)
		local nodes = {}
		if type(list) ~= "table" then
			return nodes
		end
		for i = 1, #list do
			local item = list[i]
			if is_plain_table(item) and type(item.index) == "number" then
				local chosen = item.index == current
				nodes[#nodes + 1] = button_builder({
					id = "aisp:gauntlet:" .. tostring(item.index),
					label = { item.label or tostring(item.index) },
					colour = chosen and C.GREEN or C.BLUE,
					minw = 2.2,
					minh = 0.5,
					scale = 0.35,
					button = "aisp_select",
				})
			end
		end
		return nodes
	end

	local function summary_line(options, selection)
		options = is_plain_table(options) and options or {}
		selection = is_plain_table(selection) and selection or {}
		local mode_label = find_label(options.modes, "id", selection.mode)
		if selection.mode == "gauntlet" and type(selection.gauntlet_index) == "number" then
			mode_label = mode_label .. " " .. find_label(options.gauntlet, "index", selection.gauntlet_index)
		end
		local difficulty_label = find_label(options.difficulties, "id", selection.difficulty)
		local pacing_label = find_label(options.pacings, "id", selection.pacing)
		return mode_label .. " | " .. difficulty_label .. " | " .. pacing_label
	end

	function instance.settings_definition(view)
		if not is_plain_table(view) then
			return nil, CODE.BAD_STATE
		end
		local options = rawget(view, "options")
		local selection = rawget(view, "selection")
		if not is_plain_table(options) or not is_plain_table(selection) then
			return nil, CODE.BAD_STATE
		end
		local ruleset = rawget(view, "ruleset")
		local ruleset_label = "Major League"
		if is_plain_table(ruleset) and type(ruleset.label) == "string" then
			ruleset_label = ruleset.label
		end
		local rows = {
			row({ text("AI Sparring", 0.6) }, 0.15),
			row({ text("0.1.0-dev", 0.3) }, 0.02),
			row({ text("Ruleset: " .. ruleset_label, 0.35) }, 0.08),
			row({ text("Mode", 0.4) }, 0.08),
			row(choice_buttons("mode", options.modes, selection.mode), 0.04),
		}
		if selection.mode == "gauntlet" then
			rows[#rows + 1] = row({ text("Gauntlet", 0.4) }, 0.08)
			rows[#rows + 1] = row(gauntlet_buttons(options.gauntlet, selection.gauntlet_index), 0.04)
		end
		rows[#rows + 1] = row({ text("Difficulty", 0.4) }, 0.08)
		rows[#rows + 1] = row(choice_buttons("difficulty", options.difficulties, selection.difficulty), 0.04)
		rows[#rows + 1] = row({ text("Pacing", 0.4) }, 0.08)
		rows[#rows + 1] = row(choice_buttons("pacing", options.pacings, selection.pacing), 0.04)
		rows[#rows + 1] = row({
			button_builder({
				id = "aisp:start",
				label = { "Start" },
				colour = C.GREEN,
				minw = 6,
				minh = 0.7,
				scale = 0.45,
				button = "aisp_confirm_prompt",
			}),
		}, 0.15)
		return options_builder({
			back_func = "aisp_close_overlay",
			contents = rows,
		})
	end

	function instance.confirm_definition(view)
		if not is_plain_table(view) then
			return nil, CODE.BAD_STATE
		end
		local options = rawget(view, "options")
		local selection = rawget(view, "selection")
		if not is_plain_table(options) or not is_plain_table(selection) then
			return nil, CODE.BAD_STATE
		end
		local rows = {
			row({ text("Quit Balatro and start isolated AI practice?", 0.42) }, 0.06),
			row({ text("The current game closes normally.", 0.32) }, 0.02),
			row({ text("Practice uses separate saves.", 0.32) }, 0.02),
			row({ text(summary_line(options, selection), 0.3) }, 0.1),
			row({
				button_builder({
					id = "aisp:confirm:start",
					label = { "Start" },
					colour = C.RED,
					minw = 3,
					minh = 0.6,
					scale = 0.4,
					button = "aisp_confirm_start",
				}),
				button_builder({
					id = "aisp:confirm:cancel",
					label = { "Cancel" },
					colour = C.BLUE,
					minw = 3,
					minh = 0.6,
					scale = 0.4,
					button = "aisp_confirm_cancel",
				}),
			}, 0.15),
		}
		return options_builder({ no_back = true, no_esc = true, contents = rows })
	end

	function instance.waiting_definition(view)
		view = is_plain_table(view) and view or {}
		local rows = {
			row({ text("Starting AI practice", 0.5) }, 0.1),
			row({ text("The launcher is checking its safety gates (up to two minutes).", 0.32) }, 0.04),
			row({ text("Balatro will close by itself when practice is ready.", 0.32) }, 0.04),
			row({ text(summary_line(view.options, view.selection), 0.3) }, 0.1),
		}
		return options_builder({ no_back = true, contents = rows })
	end

	function instance.diagnostic_definition(message, path)
		local rows = {
			row({ text("AI Sparring setup", 0.5) }, 0.1),
			row({ text(tostring(message), 0.35) }, 0.05),
		}
		if type(path) == "string" and #path > 0 then
			rows[#rows + 1] = row({ text("Diagnostics: " .. path, 0.28) }, 0.03)
		end
		rows[#rows + 1] = row({
			button_builder({
				id = "aisp:diagnostic:back",
				label = { "Back" },
				colour = C.BLUE,
				minw = 3,
				minh = 0.6,
				scale = 0.4,
				button = "aisp_close_overlay",
			}),
		}, 0.15)
		return options_builder({ no_back = true, no_esc = true, contents = rows })
	end

	function instance.error_definition(message, path)
		local rows = {
			row({ text("AI Sparring", 0.5) }, 0.1),
			row({ text(tostring(message), 0.35) }, 0.05),
		}
		if type(path) == "string" and #path > 0 then
			rows[#rows + 1] = row({ text("Diagnostics: " .. path, 0.28) }, 0.03)
		end
		rows[#rows + 1] = row({
			button_builder({
				id = "aisp:error:back",
				label = { "Close" },
				colour = C.BLUE,
				minw = 3,
				minh = 0.6,
				scale = 0.4,
				button = "aisp_close_overlay",
			}),
		}, 0.15)
		return options_builder({ no_back = true, no_esc = true, contents = rows })
	end

	function instance.session_definition(view)
		view = is_plain_table(view) and view or {}
		local rows = {
			row({ text("AI Sparring practice", 0.5) }, 0.1),
			row({ text(summary_line(view.options, view.selection), 0.3) }, 0.05),
			row({
				button_builder({
					id = "aisp:session:end",
					label = { "End Practice" },
					colour = C.RED,
					minw = 4,
					minh = 0.6,
					scale = 0.4,
					button = "aisp_end_practice",
				}),
				button_builder({
					id = "aisp:session:return",
					label = { "Return" },
					colour = C.BLUE,
					minw = 4,
					minh = 0.6,
					scale = 0.4,
					button = "aisp_close_overlay",
				}),
			}, 0.15),
		}
		return options_builder({ no_back = true, no_esc = true, contents = rows })
	end

	instance.CODE = CODE
	return instance
end

return PracticeMenu
