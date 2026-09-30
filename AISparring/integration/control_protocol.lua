-- AISparring control protocol constants and helpers (Lua side).
--
-- Pure module: no globals, no require, no io/os/love/NFS access. It mirrors the
-- Python practice service in tools/practice_service.py and exists so the staged
-- runtime builds the exact envelope the service expects without duplicating
-- string literals. JSON encoding/decoding is owned by the runtime's transport;
-- this module only builds the message table and reads an already-decoded
-- response table.
--
-- The envelope is exactly these six keys, always:
--   { session, credential, role, op, sequence, observation }
-- Credentials and session are launcher-owned secrets: never log them, never
-- send them anywhere except this control channel, and never place them in a
-- policy worker request.
--
-- Protocol details: docs/PRACTICE_SERVICE.md.

local ControlProtocol = {}

ControlProtocol.VERSION = "practice_service/1"

ControlProtocol.ROLES = { "human", "ai" }
ControlProtocol.DIFFICULTIES = { "rookie", "competitive", "major_league", "expert" }
ControlProtocol.PACING = { "instant", "normal" }
ControlProtocol.MODES = { "normal", "gauntlet" }

-- Exact stable neutral gauntlet labels and seeds. No search, no reordering.
ControlProtocol.GAUNTLET = {
	Test1 = "AISP0001",
	Test2 = "AISP0002",
	Test3 = "AISP0003",
	Test4 = "AISP0004",
	Test5 = "AISP0005",
}

ControlProtocol.OPS = {
	HELLO = "hello",
	LOBBY_CODE = "lobby_code",
	JOIN_CODE = "join_code",
	READY = "ready",
	START = "start",
	STATUS = "status",
	END = "end",
	ERROR = "error",
	HEARTBEAT = "heartbeat",
	SETUP = "setup",
	DECIDE_BEGIN = "decide_begin",
	DECIDE_POLL = "decide_poll",
	DECIDE_CANCEL = "decide_cancel",
	DECISION_RESULT = "decision_result",
}

ControlProtocol.CODES = {
	OK = "practice_ok",
	DECISION_PENDING = "practice_decision_pending",
	DECISION_READY = "practice_decision_ready",
	DECISION_OUTSTANDING = "practice_decision_outstanding",
	DECISION_UNKNOWN = "practice_decision_unknown",
	DECISION_FAILED = "practice_decision_failed",
	DECISION_TIMEOUT = "practice_decision_timeout",
	DECISION_CANCELLED = "practice_decision_cancelled",
	BAD_PAYLOAD = "practice_bad_payload",
	BAD_ROLE = "practice_bad_role",
	BAD_CREDENTIAL = "practice_bad_credential",
	BAD_SESSION = "practice_bad_session",
	BAD_OBSERVATION = "practice_bad_observation",
	REPLAY = "practice_replay",
	NOT_STARTED = "practice_not_started",
	NOT_READY = "practice_not_ready",
	NOT_ATTESTED = "practice_not_attested",
	PRESTART_TIMEOUT = "practice_prestart_timeout",
	RESULT_CONFLICT = "practice_result_conflict",
	CONFIG_MISMATCH = "practice_config_mismatch",
	CONFIG_FROZEN = "practice_config_frozen",
	CONTENT_MISMATCH = "practice_content_mismatch",
	NO_LOBBY = "practice_no_lobby",
	ALREADY_STARTED = "practice_already_started",
	ENDED = "practice_ended",
	ABORTED = "practice_aborted",
	ROLE_LOST = "practice_role_lost",
	RATE_LIMITED = "practice_rate_limited",
	BUSY = "practice_busy",
	CLOSED = "practice_closed",
	INTERNAL = "practice_internal_error",
}

-- Terminal lifecycle vocabulary mirrored from the service. The human
-- coordinator's END is the only authorizer of match end; an AI END is a
-- receipt recorded beside it. `mark_attested` is a trusted Python host port
-- and is deliberately NOT an op here: no wire client can attest itself.
ControlProtocol.TERMINAL_RESULTS = { "human_win", "ai_win", "draw", "aborted", "unknown" }
ControlProtocol.TERMINAL_PHASES = {
	NONE = "none",
	AWAITING_AI = "awaiting_ai",
	CLOSED = "closed",
}

-- Only these six keys are legal on any request.
ControlProtocol.REQUEST_KEYS = {
	"session",
	"credential",
	"role",
	"op",
	"sequence",
	"observation",
}

local function copy_list(list)
	local out = {}
	for i = 1, #list do
		out[i] = list[i]
	end
	return out
end

-- Build the exact request envelope. `observation` is the exported observation
-- for DECIDE_BEGIN, a small op payload for coordination ops, or nil. Lua cannot
-- carry a nil table field, so a nil payload becomes an empty table: the sixth
-- key must always be present in the encoded JSON request.
function ControlProtocol.envelope(session, credential, role, op, sequence, observation)
	if observation == nil then
		observation = {}
	end
	return {
		session = session,
		credential = credential,
		role = role,
		op = op,
		sequence = sequence,
		observation = observation,
	}
end

-- Per-role strictly increasing sequence helper. `state` is a caller-owned table.
function ControlProtocol.next_sequence(state)
	local next_value = (state.sequence or 0) + 1
	state.sequence = next_value
	return next_value
end

-- Build the exact DECIDE_CANCEL payload for the decision the caller owns:
--   { decision_sequence = <original DECIDE_BEGIN wire sequence> }
-- The cancel request itself takes a fresh monotonic envelope sequence (unlike
-- DECIDE_POLL, which reuses the outstanding decision's wire sequence). The
-- service cancels only the pending job whose sequence matches; a duplicate or
-- unknown sequence returns a bounded, non-fatal code and cancels nothing.
function ControlProtocol.decide_cancel_payload(wire_sequence)
	return { decision_sequence = wire_sequence }
end

function ControlProtocol.gauntlet_seed(label)
	return ControlProtocol.GAUNTLET[label]
end

function ControlProtocol.is_success(response)
	return type(response) == "table" and response.ok == true
end

function ControlProtocol.is_pending(response)
	return type(response) == "table" and response.code == ControlProtocol.CODES.DECISION_PENDING
end

function ControlProtocol.is_ready(response)
	return type(response) == "table"
		and response.code == ControlProtocol.CODES.DECISION_READY
		and type(response.action) == "table"
end

function ControlProtocol.is_failure(response)
	return type(response) == "table" and response.ok == false
end

function ControlProtocol.describe()
	local out = {
		version = ControlProtocol.VERSION,
		roles = copy_list(ControlProtocol.ROLES),
		difficulties = copy_list(ControlProtocol.DIFFICULTIES),
		pacing = copy_list(ControlProtocol.PACING),
		modes = copy_list(ControlProtocol.MODES),
		gauntlet = {},
		ops = {},
	}
	for label, seed in next, ControlProtocol.GAUNTLET do
		out.gauntlet[label] = seed
	end
	for name, value in next, ControlProtocol.OPS do
		out.ops[name] = value
	end
	return out
end

return ControlProtocol
