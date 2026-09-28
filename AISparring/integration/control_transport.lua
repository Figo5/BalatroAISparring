-- Nonblocking main-thread side of the launcher-owned control channel.
--
-- The blocking socket work lives in control_thread.lua; this module only builds
-- the exact six-key request envelope (via the repo control protocol), pushes it
-- to the worker channel, drains decoded responses and matches them to the one
-- outstanding decision request. Nothing here blocks, sleeps or touches an engine
-- global.
--
-- The real practice service keeps exactly ONE strictly increasing per-role
-- sequence counter for every non-poll request, so the wire sequence must be a
-- single globally monotonic space: every new coordination request AND every
-- `decide_begin` allocates the next wire sequence. The decision loop's own
-- sequence is private: it travels inside the payload and the transport maps the
-- returned wire sequence back to that local decision sequence. `decide_poll`
-- reuses the outstanding decision's wire sequence (the service exempts polls
-- from the monotonic check), and `decision_result` carries the original decision
-- wire sequence in its payload while allocating a fresh wire sequence for the
-- request itself.
--
-- A single outstanding decision slot is tracked. Coordination responses are
-- queued (bounded) for the caller to consume by op. `decide_poll` is emitted at
-- most every `poll_interval`. Credentials and session are never logged and never
-- placed in a response.
--
-- Abandoning a decision (`cancel`) sends a wire `decide_cancel` first: a fresh
-- global sequence carrying `{ decision_sequence = <the owned decide_begin wire
-- sequence> }`. Only the exact owned job is named, and the local slot is cleared
-- only after the frame is on the channel, so a later `decide_begin` (fresh wire
-- sequence, same channel order) is accepted by the service instead of being
-- refused behind a permanently occupied slot.

local ControlTransport = {}

ControlTransport.CODE = {
	OK = "transport_ok",
	BAD_PORTS = "transport_bad_ports",
	BAD_ROLE = "transport_bad_role",
	BAD_SESSION = "transport_bad_session",
	BAD_CREDENTIAL = "transport_bad_credential",
	BAD_PROTOCOL = "transport_bad_protocol",
	BAD_CHANNELS = "transport_bad_channels",
	BAD_CLOCK = "transport_bad_clock",
	BAD_ENCODE = "transport_bad_encode",
	BAD_DECODE = "transport_bad_decode",
	BAD_REQUEST = "transport_bad_request",
	BAD_OP = "transport_bad_op",
	BAD_SEQUENCE = "transport_bad_sequence",
	REPLAY = "transport_replay",
	SEQUENCE_EXHAUSTED = "transport_sequence_exhausted",
	SEND_TOO_LARGE = "transport_send_too_large",
	RECEIVE_TOO_LARGE = "transport_receive_too_large",
	ENCODE_FAILED = "transport_encode_failed",
	DECODE_FAILED = "transport_decode_failed",
	PUSH_FAILED = "transport_push_failed",
	NOT_STARTED = "transport_not_started",
	STOPPED = "transport_stopped",
	BUSY = "transport_busy",
	NO_PENDING = "transport_no_pending",
	TIMEOUT = "transport_timeout",
	OUT_OF_ORDER = "transport_out_of_order",
	QUEUE_FULL = "transport_queue_full",
	WORKER_ERROR = "transport_worker_error",
	DISCONNECTED = "transport_disconnected",
	INTERNAL = "transport_internal_error",
}

ControlTransport.EVENTS = {
	READY = "ready",
	ERROR = "error",
	CLOSED = "closed",
	STOPPED = "stopped",
}

ControlTransport.LIMITS = {
	max_token = 128,
	max_send = 2097152,
	max_receive = 65536,
	max_queue = 64,
	max_request_id = 64,
	max_error_code = 64,
	decision_base_default = 1000000,
	max_sequence = 2147483647,
	drain_budget = 32,
	poll_interval_default = 0.25,
	request_timeout_default = 10,
}

local CODE = ControlTransport.CODE

local function is_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return true
end

local function is_nat(value)
	return is_int(value) and value >= 0 and value <= ControlTransport.LIMITS.max_sequence
end

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function token_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	return value
end

-- Resolve a callable method from a trusted injected channel port. A real LÖVE
-- Channel from `love.thread.getChannel` is *userdata* whose `push`/`pop` live on
-- its metatable, so the lookup must go through normal (pcall-protected) indexing
-- rather than `rawget`; a plain-table channel (the in-memory fixture) still
-- works. Only tables/userdata are considered and a non-function (or throwing)
-- lookup is rejected, so an untrusted value can neither raise here nor expose an
-- arbitrary callable.
local function method_of(value, name)
	local kind = type(value)
	if kind ~= "table" and kind ~= "userdata" then
		return nil
	end
	local ok, method = pcall(function()
		return value[name]
	end)
	if not ok or type(method) ~= "function" then
		return nil
	end
	return method
end

local function has_fn(value, name)
	return method_of(value, name) ~= nil
end

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

ControlTransport.CODE = shallow_copy(CODE)

function ControlTransport.factory(ports)
	if not is_plain(ports) then
		return nil, CODE.BAD_PORTS
	end
	local protocol = rawget(ports, "protocol")
	if type(protocol) ~= "table"
		or type(rawget(protocol, "envelope")) ~= "function"
		or type(rawget(protocol, "OPS")) ~= "table" then
		return nil, CODE.BAD_PROTOCOL
	end
	local role = rawget(ports, "role")
	if role ~= "human" and role ~= "ai" then
		return nil, CODE.BAD_ROLE
	end
	local session = token_of(rawget(ports, "session"), ControlTransport.LIMITS.max_token)
	if session == nil then
		return nil, CODE.BAD_SESSION
	end
	local credential = token_of(rawget(ports, "credential"), ControlTransport.LIMITS.max_token)
	if credential == nil then
		return nil, CODE.BAD_CREDENTIAL
	end
	local channels = rawget(ports, "channels")
	if type(channels) ~= "table"
		or not has_fn(rawget(channels, "to_worker"), "push")
		or not has_fn(rawget(channels, "from_worker"), "pop") then
		return nil, CODE.BAD_CHANNELS
	end
	local clock = rawget(ports, "clock")
	if type(clock) ~= "table" or type(rawget(clock, "now")) ~= "function" then
		return nil, CODE.BAD_CLOCK
	end
	local encode = rawget(ports, "encode")
	if type(encode) ~= "function" then
		return nil, CODE.BAD_ENCODE
	end
	local decode = rawget(ports, "decode")
	if type(decode) ~= "function" then
		return nil, CODE.BAD_DECODE
	end
	local logger = rawget(ports, "logger")
	if logger ~= nil and (type(logger) ~= "table" or type(rawget(logger, "record")) ~= "function") then
		return nil, CODE.BAD_PORTS
	end

	local max_send = rawget(ports, "max_send") or ControlTransport.LIMITS.max_send
	if not is_nat(max_send) or max_send < 1 then
		return nil, CODE.BAD_PORTS
	end
	local max_receive = rawget(ports, "max_receive") or ControlTransport.LIMITS.max_receive
	if not is_nat(max_receive) or max_receive < 1 then
		return nil, CODE.BAD_PORTS
	end
	local decision_base = rawget(ports, "decision_base") or ControlTransport.LIMITS.decision_base_default
	if not is_nat(decision_base) or decision_base < 1 then
		return nil, CODE.BAD_PORTS
	end
	local poll_interval = rawget(ports, "poll_interval") or ControlTransport.LIMITS.poll_interval_default
	if type(poll_interval) ~= "number" or poll_interval ~= poll_interval or poll_interval < 0 then
		return nil, CODE.BAD_PORTS
	end
	local request_timeout = rawget(ports, "request_timeout") or ControlTransport.LIMITS.request_timeout_default
	if type(request_timeout) ~= "number" or request_timeout ~= request_timeout or request_timeout <= 0 then
		return nil, CODE.BAD_PORTS
	end

	local instance = {}

	local started = false
	local stopped = false
	local connected = false
	local worker_stopped = false
	local last_error = nil
	local wire_sequence = 0
	local last_decision_sequence = decision_base - 1
	local pending_decision = nil
	local decision_response = nil
	local last_delivered_sequence = nil
	local decision_index = {}
	local decision_index_count = 0
	local cancelled_wire = {}
	local cancelled_wire_count = 0
	local coordination = {}
	local coordination_count = 0
	local stats = {
		sent = 0,
		received = 0,
		dropped = 0,
		out_of_order = 0,
		errors = 0,
		polls = 0,
		cancels = 0,
		cancel_acks = 0,
	}

	local function record_error(code)
		stats.errors = stats.errors + 1
		local bounded = token_of(code, ControlTransport.LIMITS.max_error_code) or CODE.INTERNAL
		last_error = bounded
		if logger ~= nil then
			pcall(logger.record, { event = "control_transport", code = bounded, role = role })
		end
		return bounded
	end

	local function now()
		local ok, value = pcall(clock.now)
		if not ok or type(value) ~= "number" or value ~= value then
			return nil
		end
		return value
	end

	local function push_raw(text)
		local ok = pcall(channels.to_worker.push, channels.to_worker, text)
		if not ok then
			return record_error(CODE.PUSH_FAILED)
		end
		stats.sent = stats.sent + 1
		return nil
	end

	local function enqueue(response)
		if coordination_count >= ControlTransport.LIMITS.max_queue then
			stats.dropped = stats.dropped + 1
			record_error(CODE.QUEUE_FULL)
			return
		end
		local index = coordination_count + 1
		coordination[index] = response
		coordination_count = index
	end

	local function handle_event(decoded)
		local event = decoded.t
		if event == ControlTransport.EVENTS.READY then
			connected = true
		elseif event == ControlTransport.EVENTS.ERROR then
			connected = false
			record_error(token_of(rawget(decoded, "code"), ControlTransport.LIMITS.max_error_code) or CODE.WORKER_ERROR)
		elseif event == ControlTransport.EVENTS.CLOSED then
			connected = false
			record_error(CODE.DISCONNECTED)
		elseif event == ControlTransport.EVENTS.STOPPED then
			connected = false
			worker_stopped = true
		end
	end

	local function is_decision_code(code)
		if type(code) ~= "string" then
			return false
		end
		local codes = protocol.CODES
		return code == codes.DECISION_PENDING
			or code == codes.DECISION_READY
			or code == codes.DECISION_FAILED
			or code == codes.DECISION_TIMEOUT
			or code == codes.DECISION_UNKNOWN
			or code == codes.DECISION_OUTSTANDING
			or code == codes.DECISION_CANCELLED
	end

	-- Bounded local-decision -> wire-sequence map so a later `decision_result`
	-- can carry the service-issued decision identity without exposing the wire
	-- sequence to the decision loop.
	local function remember_decision(local_sequence, wire)
		if decision_index[local_sequence] == nil then
			decision_index_count = decision_index_count + 1
		end
		decision_index[local_sequence] = wire
		if decision_index_count > 64 then
			decision_index = { [local_sequence] = wire }
			decision_index_count = 1
		end
	end

	-- Bounded set of decision wire sequences this side asked the service to
	-- cancel. A `practice_decision_cancelled` ack (and any late ready/timeout
	-- that raced the cancel) echoes the *decision* wire sequence, so it must be
	-- consumed here rather than counted as an out-of-order decision or queued as
	-- a coordination response.
	local function remember_cancel(wire)
		if cancelled_wire[wire] == nil then
			cancelled_wire_count = cancelled_wire_count + 1
		end
		cancelled_wire[wire] = true
		if cancelled_wire_count > 64 then
			cancelled_wire = { [wire] = true }
			cancelled_wire_count = 1
		end
	end

	local function take_cancel_ack(sequence)
		if cancelled_wire[sequence] == nil then
			return false
		end
		cancelled_wire[sequence] = nil
		cancelled_wire_count = cancelled_wire_count - 1
		stats.cancel_acks = stats.cancel_acks + 1
		return true
	end

	local function map_decision_response(decoded)
		local mapped = {}
		for key, value in next, decoded do
			mapped[key] = value
		end
		mapped.sequence = pending_decision.local_sequence
		remember_decision(pending_decision.local_sequence, pending_decision.wire_sequence)
		decision_response = mapped
	end

	local function drain()
		for _ = 1, ControlTransport.LIMITS.drain_budget do
			local message = channels.from_worker:pop()
			if message == nil then
				return
			end
			if type(message) ~= "string" then
				stats.dropped = stats.dropped + 1
			elseif #message > max_receive then
				stats.dropped = stats.dropped + 1
				record_error(CODE.RECEIVE_TOO_LARGE)
			else
				local ok_decode, decoded = pcall(decode, message)
				if not ok_decode or type(decoded) ~= "table" then
					stats.dropped = stats.dropped + 1
					record_error(CODE.DECODE_FAILED)
				else
					stats.received = stats.received + 1
					if rawget(decoded, "t") ~= nil then
						handle_event(decoded)
					else
						local sequence = rawget(decoded, "sequence")
						local matches_pending = pending_decision ~= nil
							and is_nat(sequence)
							and sequence == pending_decision.wire_sequence
						if matches_pending then
							local pending_code = rawget(decoded, "code")
							if rawget(decoded, "ok") == true
								and pending_code == protocol.CODES.DECISION_PENDING then
								-- Still computing: leave the slot outstanding.
							else
								map_decision_response(decoded)
							end
						elseif is_nat(sequence) and take_cancel_ack(sequence) then
							-- A cancel ack (or a ready/timeout for the cancelled
							-- decision that raced it). Neither is dispatchable.
						elseif is_nat(sequence) and is_decision_code(rawget(decoded, "code")) then
							-- A decision response that is not the outstanding wire
							-- sequence can never dispatch: drop it (stale/replay).
							stats.out_of_order = stats.out_of_order + 1
						else
							-- Coordination responses are not sequence-matched.
							enqueue(decoded)
						end
					end
				end
			end
		end
	end

	local function build_and_push(op, sequence, observation)
		local ok_env, envelope = pcall(protocol.envelope, session, credential, role, op, sequence, observation)
		if not ok_env or type(envelope) ~= "table" then
			return record_error(CODE.ENCODE_FAILED)
		end
		local ok_encode, text = pcall(encode, envelope)
		if not ok_encode or type(text) ~= "string" or #text == 0 then
			return record_error(CODE.ENCODE_FAILED)
		end
		if #text > max_send then
			return record_error(CODE.SEND_TOO_LARGE)
		end
		return push_raw(text)
	end

	-- Send the wire cancellation for exactly one owned outstanding decision,
	-- BEFORE the caller clears the local pending slot. The cancel is a distinct
	-- request that consumes a fresh global wire sequence (never the poll-reuse
	-- path) and carries exactly `{ decision_sequence = <original wire> }`. It is
	-- pushed on the same channel ahead of any later `decide_begin`, so the
	-- service always sees cancel-then-begin in order. Only the named item's wire
	-- sequence is ever cancelled: no arbitrary older job can be targeted.
	local function send_cancel(item)
		local payload = nil
		local payload_fn = rawget(protocol, "decide_cancel_payload")
		if type(payload_fn) == "function" then
			local ok, value = pcall(payload_fn, item.wire_sequence)
			if ok and is_plain(value) then
				payload = value
			end
		end
		if payload == nil then
			payload = { decision_sequence = item.wire_sequence }
		end
		local op = rawget(protocol.OPS, "DECIDE_CANCEL") or "decide_cancel"
		local sequence = wire_sequence + 1
		if sequence > ControlTransport.LIMITS.max_sequence then
			return nil, CODE.SEQUENCE_EXHAUSTED
		end
		local code = build_and_push(op, sequence, payload)
		if code ~= nil then
			return nil, code
		end
		wire_sequence = sequence
		-- Keep the local->wire mapping so a receipt can still name the cancelled
		-- decision, and remember the wire sequence to consume its ack.
		remember_decision(item.local_sequence, item.wire_sequence)
		remember_cancel(item.wire_sequence)
		stats.cancels = stats.cancels + 1
		return "c" .. tostring(sequence), CODE.OK
	end

	function instance.start()
		if stopped then
			return nil, CODE.STOPPED
		end
		started = true
		coordination = {}
		coordination_count = 0
		return true, CODE.OK
	end

	function instance.is_started()
		return started
	end

	function instance.connected()
		return connected
	end

	function instance.is_stopped()
		return stopped
	end

	function instance.last_error()
		return last_error
	end

	-- Coordination send (allocates the next global wire sequence).
	function instance.send(op, payload)
		if not started then
			return nil, CODE.NOT_STARTED
		end
		if stopped then
			return nil, CODE.STOPPED
		end
		local known = false
		for _, value in next, protocol.OPS do
			if value == op then
				known = true
			end
		end
		if not known or op == protocol.OPS.DECIDE_BEGIN or op == protocol.OPS.DECIDE_POLL then
			return nil, CODE.BAD_OP
		end
		if payload ~= nil and not is_plain(payload) then
			return nil, CODE.BAD_REQUEST
		end
		-- Always send an object so the strict six-key envelope keeps its
		-- `observation` key even when the op has no payload (the service accepts
		-- `{}` for these ops).
		if payload == nil then
			payload = {}
		end
		local sequence = wire_sequence + 1
		if sequence > ControlTransport.LIMITS.max_sequence then
			return nil, CODE.SEQUENCE_EXHAUSTED
		end
		local code = build_and_push(op, sequence, payload)
		if code ~= nil then
			return nil, code
		end
		wire_sequence = sequence
		return "c" .. tostring(sequence), CODE.OK
	end

	-- Decision begin. `payload` is exactly { sequence = <local int>, observation = <export> }.
	-- The local decision sequence is private; the wire sequence is global.
	function instance.request(payload)
		if not started then
			return nil, CODE.NOT_STARTED
		end
		if stopped then
			return nil, CODE.STOPPED
		end
		if not is_plain(payload) then
			return nil, CODE.BAD_REQUEST
		end
		local local_sequence = rawget(payload, "sequence")
		if not is_nat(local_sequence) or local_sequence < decision_base then
			return nil, CODE.BAD_SEQUENCE
		end
		if local_sequence <= last_decision_sequence then
			return nil, CODE.REPLAY
		end
		if pending_decision ~= nil then
			return nil, CODE.BUSY
		end
		local observation = rawget(payload, "observation")
		if observation ~= nil and not is_plain(observation) then
			return nil, CODE.BAD_REQUEST
		end
		local sequence = wire_sequence + 1
		if sequence > ControlTransport.LIMITS.max_sequence then
			return nil, CODE.SEQUENCE_EXHAUSTED
		end
		local code = build_and_push(protocol.OPS.DECIDE_BEGIN, sequence, observation)
		if code ~= nil then
			return nil, code
		end
		wire_sequence = sequence
		last_decision_sequence = local_sequence
		local request_id = "d" .. tostring(local_sequence)
		pending_decision = {
			local_sequence = local_sequence,
			wire_sequence = sequence,
			request_id = request_id,
			sent_at = now(),
			last_poll = nil,
		}
		return request_id, CODE.OK
	end

	-- Send a decision outcome for a completed decision. The payload carries the
	-- original decision wire sequence; the request itself takes a fresh wire
	-- sequence. `fields` must be a plain table (accepted/code/version/tick/...).
	function instance.decision_result(local_sequence, fields)
		if not started then
			return nil, CODE.NOT_STARTED
		end
		if stopped then
			return nil, CODE.STOPPED
		end
		if not is_nat(local_sequence) then
			return nil, CODE.BAD_SEQUENCE
		end
		local wire = decision_index[local_sequence]
		if wire == nil then
			return nil, CODE.NO_PENDING
		end
		if fields ~= nil and not is_plain(fields) then
			return nil, CODE.BAD_REQUEST
		end
		local payload = {}
		if fields ~= nil then
			for key, value in next, fields do
				payload[key] = value
			end
		end
		payload.sequence = wire
		local sequence = wire_sequence + 1
		if sequence > ControlTransport.LIMITS.max_sequence then
			return nil, CODE.SEQUENCE_EXHAUSTED
		end
		local code = build_and_push(protocol.OPS.DECISION_RESULT, sequence, payload)
		if code ~= nil then
			return nil, code
		end
		wire_sequence = sequence
		return "c" .. tostring(sequence), CODE.OK
	end

	-- Nonblocking decision poll. Returns a terminal response only.
	function instance.poll_decision()
		if not started then
			return nil
		end
		drain()
		if decision_response ~= nil then
			local response = decision_response
			local delivered = response.sequence
			decision_response = nil
			pending_decision = nil
			last_delivered_sequence = delivered
			return response
		end
		if pending_decision == nil then
			return nil
		end
		local current = now()
		if current == nil then
			return nil
		end
		if pending_decision.sent_at ~= nil and current - pending_decision.sent_at > request_timeout then
			local item = pending_decision
			local sequence = item.local_sequence
			-- Never abandon the service's single decision slot silently: send the
			-- wire cancellation for exactly this owned job before clearing.
			send_cancel(item)
			pending_decision = nil
			return { sequence = sequence, ok = false, code = CODE.TIMEOUT }
		end
		if pending_decision.last_poll == nil or current - pending_decision.last_poll >= poll_interval then
			pending_decision.last_poll = current
			stats.polls = stats.polls + 1
			build_and_push(protocol.OPS.DECIDE_POLL, pending_decision.wire_sequence, {})
		end
		return nil
	end

	-- Nonblocking coordination drain. Returns the oldest queued response.
	function instance.poll_coordination()
		if not started then
			return nil
		end
		drain()
		if coordination_count == 0 then
			return nil
		end
		local response = coordination[1]
		for i = 1, coordination_count - 1 do
			coordination[i] = coordination[i + 1]
		end
		coordination[coordination_count] = nil
		coordination_count = coordination_count - 1
		return response
	end

	-- Abandon exactly the named outstanding decision. The wire cancellation is
	-- sent first; the local slot is cleared only after the cancel frame is on
	-- the channel, so the service can never still own the job after this side
	-- forgets it. If the cancel cannot be pushed, the slot is kept so the caller
	-- can retry instead of leaking the service's single decision slot.
	function instance.cancel(request_id)
		if type(request_id) ~= "string" then
			return false, CODE.BAD_REQUEST
		end
		if pending_decision == nil or pending_decision.request_id ~= request_id then
			return false, CODE.NO_PENDING
		end
		local item = pending_decision
		local _, code = send_cancel(item)
		if code ~= CODE.OK then
			return false, code
		end
		pending_decision = nil
		return true, CODE.OK
	end

	function instance.pending_sequence()
		if pending_decision == nil then
			return nil
		end
		return pending_decision.local_sequence
	end

	function instance.pending_wire_sequence()
		if pending_decision == nil then
			return nil
		end
		return pending_decision.wire_sequence
	end

	function instance.last_delivered_sequence()
		return last_delivered_sequence
	end

	function instance.wire_sequence()
		return wire_sequence
	end

	function instance.stop()
		if stopped then
			return true, CODE.OK
		end
		stopped = true
		pending_decision = nil
		decision_response = nil
		if started then
			pcall(channels.to_worker.push, channels.to_worker, '{"t":"stop"}')
		end
		return true, CODE.OK
	end

	function instance.stats()
		return shallow_copy(stats)
	end

	function instance.describe()
		return {
			started = started,
			stopped = stopped,
			connected = connected,
			worker_stopped = worker_stopped,
			has_pending = pending_decision ~= nil,
			wire_sequence = wire_sequence,
			pending_local_sequence = pending_decision ~= nil and pending_decision.local_sequence or nil,
			pending_wire_sequence = pending_decision ~= nil and pending_decision.wire_sequence or nil,
			last_decision_sequence = last_decision_sequence,
			last_delivered_sequence = last_delivered_sequence,
			decision_base = decision_base,
			role = role,
			session_configured = session ~= nil,
			credential_configured = credential ~= nil,
			queued = coordination_count,
			stats = shallow_copy(stats),
			last_error = last_error,
			codes = shallow_copy(CODE),
		}
	end

	instance.CODE = shallow_copy(CODE)
	instance.LIMITS = shallow_copy(ControlTransport.LIMITS)
	instance.role = role
	instance.decision_base = decision_base

	return instance
end

return ControlTransport
