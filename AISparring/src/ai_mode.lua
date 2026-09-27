local AIMode = {}

AIMode.DEFAULT_ENABLED = false
AIMode.STATUS_DISABLED = "disabled_default_off"
AIMode.STATUS_BLOCKED = "requested_blocked_gates_not_implemented"
AIMode.CODE_DISABLED = "ai_disabled"
AIMode.CODE_BLOCKED = "ai_gates_not_implemented"
AIMode.GATES = { "P0", "P1", "P2", "P3", "P4", "P5" }

local function gate_list()
	local out = {}
	for i = 1, #AIMode.GATES do
		out[i] = AIMode.GATES[i]
	end
	return out
end

function AIMode.resolve(requested)
	local wants = requested == true
	return {
		requested = wants,
		enabled = false,
		implemented = false,
		status = wants and AIMode.STATUS_BLOCKED or AIMode.STATUS_DISABLED,
		code = wants and AIMode.CODE_BLOCKED or AIMode.CODE_DISABLED,
		gates = gate_list(),
	}
end

function AIMode.can_activate()
	return false
end

return AIMode
