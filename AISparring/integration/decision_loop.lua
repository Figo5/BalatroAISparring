-- Injected-port, nonblocking AI decision loop.
--
-- Trusted bootstrap supplies every side effect as a port:
--
--   broker    : the production action broker (issue/submit/cancel/is_revoked/revoke)
--   transport : async, nonblocking policy request/response channel
--   clock     : monotonic time source (now, optionally tick)
--   controls  : trusted UI navigation state (next/advance, optional refresh)
--   logger    : trusted local decision logger (record)
--   checksum  : optional observation checksum function
--   get_revision : optional post-decision state revision reader (see 2.5)
--   wait_state   : optional trusted "the runtime is legitimately waiting" probe
--
-- Opponent wait contract. When the trusted `wait_state` probe reports a wait
-- (the AI readied the PvP blind, has no PvP hands left, or the PvP countdown is
-- running), the loop is in the explicit WAITING_FOR_OPPONENT state: it never
-- asks the policy, never counts an error or a transient, and polls the trusted
-- capture with a bounded doubling backoff (so a terminal match end or the
-- opponent's arrival is still seen promptly). Entering and leaving the state is
-- logged once each, never per poll.
--
-- The loop owns no engine reference, no timer, no randomness and no policy
-- interpreter. It only transports the sanitized observation export plus an
-- opaque decision sequence; the private broker token never leaves the loop and
-- never reaches the transport. A response is matched by exact sequence before
-- submit, so out-of-order and replayed responses are dropped.
--
-- Transient contract. A trusted capture/adapter may be mid-animation, waiting on
-- a queued executor callback or bound by a verified server/opponent wait. Those
-- conditions surface as bounded broker codes (by default `broker_capture_failed`,
-- `broker_generate_failed` and the production executor's `exec_pending`), and the
-- loop treats any code in `transient_codes` as a bounded wait: it backs off and
-- retries without counting toward the fatal error budget, aborting only after the
-- wall-clock `max_transient_seconds` window (or, as a secondary guard,
-- `max_transient_streak`) of unbroken transients. A trusted `wait_state` probe
-- that reports a verified wait holds the window open instead of aborting.
--
-- Trusted control navigation cancels the pending broker token and transport
-- request before transitioning, and latches the control name. While the latch is
-- set the loop never arms a second deferred transition; it refreshes the trusted
-- control state through the normal capture path (the runtime's `controls.next` is
-- only updated by capture) until the control clears or the wall-clock latch
-- deadline passes.
--
-- update() performs one bounded, nonblocking step and returns immediately.

local DecisionLoop = {}

local CODE = {
	OK = "loop_ok",
	BAD_OPTIONS = "loop_bad_options",
	BAD_BROKER = "loop_bad_broker",
	BAD_TRANSPORT = "loop_bad_transport",
	BAD_CLOCK = "loop_bad_clock",
	BAD_LOGGER = "loop_bad_logger",
	BAD_CONTROLS = "loop_bad_controls",
	REVOKED = "loop_revoked",
	TERMINAL = "loop_terminal",
	EMPTY_ACTIONS = "loop_empty_actions",
	TRANSIENT = "loop_transient",
	TRANSPORT_ERROR = "loop_transport_error",
	TIMEOUT = "loop_timeout",
	OUT_OF_ORDER = "loop_out_of_order",
	RESPONSE_REJECTED = "loop_response_rejected",
	NO_ACTION = "loop_policy_no_action",
	WAITING = "loop_waiting_for_opponent",
	STALE = "loop_stale",
	DISPATCH_FAILED = "loop_dispatch_failed",
	MAX_ERRORS = "loop_max_errors",
	CONTROL_FAILED = "loop_control_failed",
	CONTROL_TIMEOUT = "loop_control_timeout",
	STOPPED = "loop_stopped",
	INTERNAL = "loop_internal_error",
}

local LIMITS = {
	max_reason = 64,
	max_token = 64,
	max_id = 256,
	max_terminal_phase = 32,
	min_transient_backoff = 0.05,
}

local TERMINAL_PHASE = "MATCH_COMPLETE"
local CONTROL_ALLOWLIST = { ["cash_out"] = true }

-- Bounded broker codes that mean "the trusted capture is transiently busy"
-- (engine animation, queued executor callback, a committed action whose effect
-- has not appeared) rather than a fatal failure. `exec_pending` is the explicit
-- production-executor pending latch passed through by the broker; the bootstrap
-- may merge additional runtime codes on top.
local DEFAULT_TRANSIENT_CODES = {
	broker_capture_failed = true,
	broker_generate_failed = true,
	exec_pending = true,
}
-- Terminal executor faults passed through the broker (see the broker's
-- PORT_FATAL_CODES). These are not waits: the match stops immediately and the
-- broker authority is revoked. `exec_pending` is deliberately absent — it is the
-- valid, bounded "a committed action's visible effect has not appeared yet"
-- latch and stays a transient wait (bounded by the executor's own stall window).
local DEFAULT_FATAL_CODES = {
	exec_stall_timeout = true,
	exec_revoked = true,
}
-- Secondary streak guard. Raised so the wall-clock window is the primary bound
-- (with the default backoff this is far beyond `max_transient_seconds`).
local DEFAULT_MAX_TRANSIENT_STREAK = 1200
-- Primary bound: an unbroken transient streak longer than this many seconds is a
-- fatal stall. Generous enough for real scoring animations.
local DEFAULT_MAX_TRANSIENT_SECONDS = 120
-- Larger than a per-frame backoff so a transient wait never busy-spins.
local DEFAULT_TRANSIENT_BACKOFF = 0.25
-- N6: an unchanged-epoch `policy_no_action` is deterministic, so re-asking is
-- wasted work (the service spawns a worker per request). The cooldown doubles
-- while the epoch is unchanged, capped here, and resets on observable progress.
local DEFAULT_NO_ACTION_MAX_BACKOFF = 2.0
-- WAITING_FOR_OPPONENT poll cadence: starts at the transient backoff, doubles
-- while the wait persists and is capped here, so the opponent's arrival is
-- noticed within about a second.
local DEFAULT_WAIT_MAX_BACKOFF = 1.0
-- Wall-clock deadline for a latched trusted control that never clears.
local DEFAULT_CONTROL_LATCH_SECONDS = 30

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

local function is_plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function is_number(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value then
		return false
	end
	if value == math.huge or value == -math.huge then
		return false
	end
	return true
end

local function is_nat_int(value)
	if type(value) ~= "number" then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= 0 and value <= 2147483647
end

local function safe_token(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	return value
end

local function printable(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	for i = 1, #value do
		local byte = string.byte(value, i)
		if byte < 32 or byte > 126 then
			return nil
		end
	end
	return value
end

DecisionLoop.CODE = shallow_copy(CODE)
DecisionLoop.LIMITS = shallow_copy(LIMITS)
DecisionLoop.TERMINAL_PHASE = TERMINAL_PHASE

function DecisionLoop.factory(options)
	if not is_plain_table(options) then
		return nil, CODE.BAD_OPTIONS
	end

	local broker = rawget(options, "broker")
	if type(broker) ~= "table"
		or type(broker.issue) ~= "function"
		or type(broker.submit) ~= "function"
		or type(broker.cancel) ~= "function"
		or type(broker.is_revoked) ~= "function"
		or type(broker.revoke) ~= "function" then
		return nil, CODE.BAD_BROKER
	end

	local transport = rawget(options, "transport")
	if type(transport) ~= "table"
		or type(transport.request) ~= "function"
		or type(transport.poll) ~= "function" then
		return nil, CODE.BAD_TRANSPORT
	end

	local clock = rawget(options, "clock")
	if type(clock) ~= "table" or type(clock.now) ~= "function" then
		return nil, CODE.BAD_CLOCK
	end

	local logger = rawget(options, "logger")
	if logger ~= nil and (type(logger) ~= "table" or type(logger.record) ~= "function") then
		return nil, CODE.BAD_LOGGER
	end

	local controls = rawget(options, "controls")
	if controls ~= nil then
		if type(controls) ~= "table"
			or type(controls.next) ~= "function"
			or type(controls.advance) ~= "function" then
			return nil, CODE.BAD_CONTROLS
		end
		if rawget(controls, "refresh") ~= nil and type(rawget(controls, "refresh")) ~= "function" then
			return nil, CODE.BAD_CONTROLS
		end
	end

	local checksum = rawget(options, "checksum")
	if checksum ~= nil and type(checksum) ~= "function" then
		return nil, CODE.BAD_OPTIONS
	end

	local revision_source = rawget(options, "get_revision")
	if revision_source ~= nil and type(revision_source) ~= "function" then
		return nil, CODE.BAD_OPTIONS
	end
	if revision_source == nil and type(rawget(broker, "receipt")) == "function" then
		revision_source = rawget(broker, "receipt")
	end

	local wait_state = rawget(options, "wait_state")
	if wait_state ~= nil and type(wait_state) ~= "function" then
		return nil, CODE.BAD_OPTIONS
	end

	local pacing = rawget(options, "pacing")
	if pacing == nil then
		pacing = 0
	end
	if not is_number(pacing) or pacing < 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local min_interval = rawget(options, "min_interval")
	if min_interval == nil then
		min_interval = 0
	end
	if not is_number(min_interval) or min_interval < 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local timeout = rawget(options, "timeout")
	if timeout == nil then
		timeout = 5
	end
	if not is_number(timeout) or timeout <= 0 then
		return nil, CODE.BAD_OPTIONS
	end
	-- M3: a dispatch schedule at or beyond the response deadline would abandon
	-- valid decisions. Reject the impossible configuration up front.
	if pacing > 0 and pacing >= timeout then
		return nil, CODE.BAD_OPTIONS
	end

	local transient_backoff = rawget(options, "transient_backoff")
	if transient_backoff == nil then
		if min_interval > 0 then
			transient_backoff = min_interval
		else
			transient_backoff = DEFAULT_TRANSIENT_BACKOFF
		end
	end
	if not is_number(transient_backoff) or transient_backoff < 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local max_errors = rawget(options, "max_consecutive_errors")
	if max_errors == nil then
		max_errors = 3
	end
	if not is_nat_int(max_errors) or max_errors < 1 then
		return nil, CODE.BAD_OPTIONS
	end

	local terminal_phase = rawget(options, "terminal_phase")
	if terminal_phase == nil then
		terminal_phase = TERMINAL_PHASE
	end
	if safe_token(terminal_phase, LIMITS.max_terminal_phase) == nil then
		return nil, CODE.BAD_OPTIONS
	end

	local pacing_mode = rawget(options, "pacing_mode")
	if pacing_mode == nil then
		pacing_mode = "instant"
	end
	if pacing_mode ~= "instant" and pacing_mode ~= "normal" then
		return nil, CODE.BAD_OPTIONS
	end

	local sequence_start = rawget(options, "sequence_start")
	if sequence_start == nil then
		sequence_start = 1
	end
	if not is_nat_int(sequence_start) then
		return nil, CODE.BAD_OPTIONS
	end

	local on_stop = rawget(options, "on_stop")
	if on_stop ~= nil and type(on_stop) ~= "function" then
		return nil, CODE.BAD_OPTIONS
	end

	local transient_codes = {}
	for key, value in next, DEFAULT_TRANSIENT_CODES do
		transient_codes[key] = value
	end
	local transient_override = rawget(options, "transient_codes")
	if transient_override ~= nil then
		if not is_plain_table(transient_override) then
			return nil, CODE.BAD_OPTIONS
		end
		for key, value in next, transient_override do
			if type(key) ~= "string" or type(value) ~= "boolean" then
				return nil, CODE.BAD_OPTIONS
			end
			transient_codes[key] = value
		end
	end

	local fatal_codes = {}
	for key, value in next, DEFAULT_FATAL_CODES do
		fatal_codes[key] = value
	end
	local fatal_override = rawget(options, "fatal_codes")
	if fatal_override ~= nil then
		if not is_plain_table(fatal_override) then
			return nil, CODE.BAD_OPTIONS
		end
		for key, value in next, fatal_override do
			if type(key) ~= "string" or type(value) ~= "boolean" then
				return nil, CODE.BAD_OPTIONS
			end
			fatal_codes[key] = value
		end
	end

	local max_transient_streak = rawget(options, "max_transient_streak")
	if max_transient_streak == nil then
		max_transient_streak = DEFAULT_MAX_TRANSIENT_STREAK
	end
	if not is_nat_int(max_transient_streak) then
		return nil, CODE.BAD_OPTIONS
	end

	local max_transient_seconds = rawget(options, "max_transient_seconds")
	if max_transient_seconds == nil then
		max_transient_seconds = DEFAULT_MAX_TRANSIENT_SECONDS
	end
	if not is_number(max_transient_seconds) or max_transient_seconds <= 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local no_action_max_backoff = rawget(options, "no_action_max_backoff")
	if no_action_max_backoff == nil then
		no_action_max_backoff = DEFAULT_NO_ACTION_MAX_BACKOFF
	end
	if not is_number(no_action_max_backoff) or no_action_max_backoff <= 0 then
		return nil, CODE.BAD_OPTIONS
	end
	local wait_max_backoff = rawget(options, "wait_max_backoff")
	if wait_max_backoff == nil then
		wait_max_backoff = DEFAULT_WAIT_MAX_BACKOFF
	end
	if not is_number(wait_max_backoff) or wait_max_backoff <= 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local control_latch_seconds = rawget(options, "control_latch_seconds")
	if control_latch_seconds == nil then
		control_latch_seconds = DEFAULT_CONTROL_LATCH_SECONDS
	end
	if not is_number(control_latch_seconds) or control_latch_seconds < 0 then
		return nil, CODE.BAD_OPTIONS
	end

	local function is_transient(code)
		return type(code) == "string" and transient_codes[code] == true
	end

	-- N4: a terminal executor fault stops the local match at once. It is never
	-- counted toward the transient budget or the consecutive-error budget.
	local function is_fatal(code)
		return type(code) == "string" and fatal_codes[code] == true
	end

	-- A trusted signal that the runtime is legitimately waiting (for example the
	-- authoritative MP opponent timer/heartbeat). Any bounded string keeps the
	-- loop from aborting its own transient wait, without busy-spinning.
	local function external_wait()
		if wait_state == nil then
			return nil
		end
		local ok, value = pcall(wait_state)
		if not ok then
			return nil
		end
		return safe_token(value, LIMITS.max_token)
	end

	local stopped = false
	local terminal = false
	local stop_reason = nil
	local pending = nil
	local last_request_at = nil
	local cooldown_until = nil
	local consecutive_errors = 0
	local transient_streak = 0
	local transient_started_at = nil
	local control_latch = nil
	local control_latch_at = nil
	local next_sequence = sequence_start
	local last_empty_epoch = nil
	local last_no_action_epoch = nil
	local no_action_backoff = nil
	-- WAITING_FOR_OPPONENT state: the trusted wait token, when it began and the
	-- current poll backoff. nil while not waiting.
	local waiting = nil
	-- Epoch for which the policy was already asked about a wait-compatible
	-- action (e.g. START_TIMER) during a wait; asked at most once per epoch.
	local wait_asked_epoch = nil
	local waiting_since = nil
	local last_now = nil
	local wait_backoff = nil
	local stats = {
		issued = 0,
		requests = 0,
		submitted = 0,
		rejected = 0,
		stale = 0,
		errors = 0,
		timeouts = 0,
		out_of_order = 0,
		empty = 0,
		no_action = 0,
		transient = 0,
		transient_waiting = 0,
		waits = 0,
		waiting_polls = 0,
		wait_decisions = 0,
		waiting_seconds = 0,
		faults = 0,
		controls = 0,
		terminal = false,
	}

	local loop = {}

	local function set_cooldown(now, delay)
		if type(delay) == "number" and delay > 0 then
			cooldown_until = now + delay
		else
			cooldown_until = nil
		end
	end

	local function reset_transient()
		transient_streak = 0
		transient_started_at = nil
	end

	-- N6: observable progress clears the no-action throttle so a future state
	-- change is asked about promptly instead of inheriting the old backoff.
	local function note_progress()
		last_no_action_epoch = nil
		no_action_backoff = nil
	end

	local function abandon_pending()
		local item = pending
		pending = nil
		if item ~= nil and item.request_id ~= nil and type(transport.cancel) == "function" then
			pcall(transport.cancel, item.request_id)
		end
		pcall(broker.cancel)
	end

	-- Field names are the companion logger's allowlisted ones (src/logger.lua),
	-- so the wait kind and duration survive into the real Lovely log line.
	local function log_wait(now, event, state, seconds)
		if logger == nil then
			return
		end
		pcall(logger.record, {
			event = event,
			code = CODE.WAITING,
			detail = state,
			seconds = seconds,
		})
	end

	-- Leave WAITING_FOR_OPPONENT (the wait cleared, or the match ended/stopped):
	-- account the waited time and log the exit once.
	local function end_wait(now)
		if waiting == nil then
			return
		end
		local seconds = 0
		if waiting_since ~= nil and is_number(now) and now >= waiting_since then
			seconds = now - waiting_since
		end
		stats.waiting_seconds = stats.waiting_seconds + seconds
		log_wait(now, "wait_end", waiting, seconds)
		waiting = nil
		waiting_since = nil
		wait_backoff = nil
	end

	-- Enter or continue WAITING_FOR_OPPONENT. Never an error or a transient;
	-- the capture is re-polled with a capped doubling backoff.
	local function hold_wait(now, state)
		if waiting ~= state then
			end_wait(now)
			waiting = state
			waiting_since = now
			stats.waits = stats.waits + 1
			log_wait(now, "wait_begin", state, nil)
			wait_backoff = transient_backoff
		else
			wait_backoff = (wait_backoff or transient_backoff) * 2
		end
		if wait_backoff > wait_max_backoff then
			wait_backoff = wait_max_backoff
		end
		if wait_backoff < LIMITS.min_transient_backoff then
			wait_backoff = LIMITS.min_transient_backoff
		end
		stats.waiting_polls = stats.waiting_polls + 1
		-- A wait is not progress: the consecutive-error streak is left alone.
		reset_transient()
		set_cooldown(now, wait_backoff)
		return "waiting", CODE.WAITING
	end

	local function finish(reason, code)
		if stopped then
			return "stopped", stop_reason
		end
		stopped = true
		stop_reason = reason
		end_wait(last_now)
		abandon_pending()
		pcall(broker.cancel)
		pcall(function()
			broker.revoke()
		end)
		if on_stop ~= nil then
			pcall(on_stop, reason, code)
		end
		return "stopped", code
	end

	local function finish_terminal()
		if stopped then
			return "stopped", stop_reason
		end
		stopped = true
		terminal = true
		stop_reason = "terminal"
		end_wait(last_now)
		stats.terminal = true
		abandon_pending()
		pcall(broker.cancel)
		pcall(function()
			broker.revoke()
		end)
		return "terminal", CODE.TERMINAL
	end

	local function register_error(now, code)
		reset_transient()
		consecutive_errors = consecutive_errors + 1
		stats.errors = stats.errors + 1
		set_cooldown(now, min_interval)
		if consecutive_errors >= max_errors then
			return finish("error", code)
		end
		return nil, nil
	end

	-- A trusted capture that is mid-animation, waiting on a queued executor
	-- callback or bound by a verified server wait is a bounded wait, not a match
	-- abort: back off and retry, and treat only an unbroken wall-clock window as
	-- fatal. The raw streak guard remains as a secondary bound.
	local function register_transient(now, code)
		local wait = external_wait()
		if wait ~= nil then
			-- The runtime owns this wait (e.g. the PvP opponent): it is the
			-- explicit WAITING_FOR_OPPONENT state, not a transient, so the loop's
			-- own transient bound never aborts it and it is never counted as one.
			stats.transient_waiting = stats.transient_waiting + 1
			return hold_wait(now, wait)
		end
		stats.transient = stats.transient + 1
		set_cooldown(now, transient_backoff)
		transient_streak = transient_streak + 1
		if transient_started_at == nil then
			transient_started_at = now
		end
		if transient_streak > max_transient_streak then
			return finish("error", code)
		end
		if now - transient_started_at > max_transient_seconds then
			return finish("error", code)
		end
		return nil, nil
	end

	local function checksum_of(observation)
		if checksum == nil then
			return nil
		end
		local ok, value = pcall(checksum, observation)
		if not ok then
			return nil
		end
		return safe_token(value, LIMITS.max_token)
	end

	-- L5: the post-decision revision comes from the injected reader (or a broker
	-- receipt), never from the pre-issue epoch, which is not a post-action version.
	local function current_revision()
		if revision_source == nil then
			return nil
		end
		local ok, value = pcall(revision_source)
		if not ok then
			return nil
		end
		if is_nat_int(value) then
			return value
		end
		if type(value) == "table" and getmetatable(value) == nil then
			local epoch = rawget(value, "epoch")
			if is_nat_int(epoch) then
				return epoch
			end
		end
		return nil
	end

	local function log_decision(now, item, action, latency, reason, code, result_epoch)
		if logger == nil or item == nil then
			return
		end
		local tick = now
		if type(clock.tick) == "function" then
			local ok, value = pcall(clock.tick)
			if ok and is_number(value) then
				tick = value
			end
		end
		local selected
		if type(action) == "table" then
			selected = {
				type = safe_token(rawget(action, "type"), 32),
				id = safe_token(rawget(action, "id"), LIMITS.max_id),
			}
		end
		local record = {
			tick = tick,
			phase = item.phase,
			checksum = item.checksum,
			candidate_count = item.candidate_count,
			selected = selected,
			latency = latency,
			reason = reason,
			issue_epoch = item.epoch,
			result_epoch = result_epoch,
			result_code = code,
			pacing_mode = pacing_mode,
		}
		pcall(logger.record, record)
	end

	local function log_rejection(now, item, code, reason)
		if item == nil then
			return
		end
		log_decision(now, item, nil, now - item.request_sent_at, reason, code, current_revision())
	end

	local function handle_response(now, response)
		if type(response) ~= "table" or getmetatable(response) ~= nil then
			stats.rejected = stats.rejected + 1
			log_rejection(now, pending, CODE.RESPONSE_REJECTED, nil)
			local status, code = register_error(now, CODE.RESPONSE_REJECTED)
			if status ~= nil then
				return status, code
			end
			return "idle", CODE.RESPONSE_REJECTED
		end
		local sequence = rawget(response, "sequence")
		if not is_nat_int(sequence) or pending == nil or sequence ~= pending.sequence then
			stats.out_of_order = stats.out_of_order + 1
			stats.rejected = stats.rejected + 1
			return "waiting", CODE.OUT_OF_ORDER
		end
		if rawget(response, "ok") ~= true then
			local response_code = printable(rawget(response, "code"), LIMITS.max_reason)
			local reason = printable(rawget(response, "reason"), LIMITS.max_reason)
			local item = pending
			abandon_pending()
			stats.rejected = stats.rejected + 1
			log_rejection(now, item, response_code or CODE.RESPONSE_REJECTED, reason)
			if response_code == "policy_no_action" then
				-- M2: a legitimate "no legal choice" is not a match error. Back
				-- off like the empty-action state and do not count it toward the
				-- fatal error budget.
				reset_transient()
				stats.no_action = stats.no_action + 1
				-- N6: the policy is deterministic, so an unchanged epoch would
				-- return the same answer. Double the cooldown while the epoch is
				-- unchanged (capped), and reset it as soon as the epoch moves.
				local epoch = item ~= nil and item.epoch or nil
				local repeat_epoch = epoch ~= nil and epoch == last_no_action_epoch
				local delay = transient_backoff
				if repeat_epoch then
					delay = (no_action_backoff or transient_backoff) * 2
				end
				if delay > no_action_max_backoff then
					delay = no_action_max_backoff
				end
				if delay < LIMITS.min_transient_backoff then
					delay = LIMITS.min_transient_backoff
				end
				no_action_backoff = delay
				last_no_action_epoch = epoch
				set_cooldown(now, delay)
				return "idle", CODE.NO_ACTION
			end
			local status, code = register_error(now, CODE.RESPONSE_REJECTED)
			if status ~= nil then
				return status, code
			end
			return "idle", CODE.RESPONSE_REJECTED
		end
		local action = rawget(response, "action")
		if type(action) ~= "table" or getmetatable(action) ~= nil then
			local item = pending
			abandon_pending()
			stats.rejected = stats.rejected + 1
			log_rejection(now, item, CODE.RESPONSE_REJECTED, printable(rawget(response, "reason"), LIMITS.max_reason))
			local status, code = register_error(now, CODE.RESPONSE_REJECTED)
			if status ~= nil then
				return status, code
			end
			return "idle", CODE.RESPONSE_REJECTED
		end
		pending.action = action
		pending.response_at = now
		pending.latency = now - pending.request_sent_at
		pending.reason = printable(rawget(response, "reason"), LIMITS.max_reason)
		pending.submit_at = now + pacing
		if now >= pending.submit_at then
			return loop._submit(now)
		end
		return "scheduled", CODE.OK
	end

	local function do_poll(now)
		local ok_poll, response = pcall(transport.poll)
		if not ok_poll then
			abandon_pending()
			local status, code = register_error(now, CODE.TRANSPORT_ERROR)
			if status ~= nil then
				return status, code
			end
			return "idle", CODE.TRANSPORT_ERROR
		end
		if response == nil then
			return "waiting", CODE.OK
		end
		return handle_response(now, response)
	end

	local function do_issue(now)
		local token, request, meta = broker.issue()
		if token == nil then
			local code = request or CODE.TRANSPORT_ERROR
			if code == "broker_revoked" then
				return finish("revoked", CODE.REVOKED)
			end
			if is_fatal(code) then
				-- N4: a terminal executor fault (stall timeout/revoked executor)
				-- stops the match immediately instead of waiting out the
				-- transient window; `finish` cancels the pending broker token and
				-- revokes the authority.
				stats.faults = stats.faults + 1
				return finish("fault", code)
			end
			if is_transient(code) then
				local status, transient_code = register_transient(now, code)
				if status ~= nil then
					return status, transient_code
				end
				return "idle", CODE.TRANSIENT
			end
			local status, error_code = register_error(now, code)
			if status ~= nil then
				return status, error_code
			end
			return "idle", code
		end

		reset_transient()
		local observation = request.observation
		local phase = nil
		if type(observation) == "table" then
			phase = safe_token(rawget(observation, "phase"), LIMITS.max_terminal_phase)
		end
		local candidate_count = 0
		local epoch = nil
		if type(meta) == "table" then
			local count = rawget(meta, "candidate_count")
			if is_nat_int(count) then
				candidate_count = count
			end
			local meta_epoch = rawget(meta, "epoch")
			if is_nat_int(meta_epoch) then
				epoch = meta_epoch
			end
		end

		if phase == terminal_phase then
			pcall(broker.cancel)
			return finish_terminal()
		end

		-- WAITING_FOR_OPPONENT: a trusted runtime wait (never a policy or
		-- observation claim) means there is nothing to decide until the opponent
		-- arrives. Do not ask the policy; poll the capture again after a bounded
		-- backoff. The terminal check above still runs on every poll.
		local wait = external_wait()
		if wait ~= nil then
			-- A wait-compatible choice (the Multiplayer timer button) is asked
			-- about once per epoch; any answer, including no-action, then leaves
			-- the loop waiting until the epoch changes.
			local wait_actions = 0
			if type(meta) == "table" and is_nat_int(rawget(meta, "wait_action_count")) then
				wait_actions = rawget(meta, "wait_action_count")
			end
			if wait_actions == 0 or epoch == nil or epoch == wait_asked_epoch then
				pcall(broker.cancel)
				return hold_wait(now, wait)
			end
			wait_asked_epoch = epoch
			stats.wait_decisions = stats.wait_decisions + 1
		else
			end_wait(now)
		end

		if candidate_count == 0 then
			pcall(broker.cancel)
			reset_transient()
			stats.empty = stats.empty + 1
			local repeat_empty = epoch ~= nil and epoch == last_empty_epoch
			if epoch ~= nil then
				last_empty_epoch = epoch
			end
			local delay = transient_backoff
			if repeat_empty then
				delay = delay * 2
			end
			if delay < LIMITS.min_transient_backoff then
				delay = LIMITS.min_transient_backoff
			end
			set_cooldown(now, delay)
			return "idle", CODE.EMPTY_ACTIONS
		end
		last_empty_epoch = nil

		local sequence = next_sequence
		next_sequence = next_sequence + 1
		local payload = { sequence = sequence, observation = observation }
		local ok_send, request_id, send_code = pcall(transport.request, payload)
		if not ok_send or request_id == nil then
			pcall(broker.cancel)
			local status, code = register_error(now, send_code or CODE.TRANSPORT_ERROR)
			if status ~= nil then
				return status, code
			end
			return "idle", CODE.TRANSPORT_ERROR
		end

		pending = {
			sequence = sequence,
			request_id = request_id,
			token = token,
			request_sent_at = now,
			phase = phase,
			candidate_count = candidate_count,
			checksum = checksum_of(observation),
			epoch = epoch,
			submit_at = nil,
		}
		last_request_at = now
		stats.issued = stats.issued + 1
		stats.requests = stats.requests + 1
		return "issued", CODE.OK
	end

	function loop._submit(now)
		local item = pending
		pending = nil
		if item == nil then
			return "idle", CODE.OK
		end
		local ok, code = broker.submit(item.token, item.action)
		if ok == true then
			consecutive_errors = 0
			reset_transient()
			note_progress()
			stats.submitted = stats.submitted + 1
			local latency = item.latency
			if latency == nil then
				latency = now - item.request_sent_at
			end
			log_decision(now, item, item.action, latency, item.reason, code, current_revision())
			return "submitted", CODE.OK
		end
		if code == "broker_revoked" then
			return finish("revoked", CODE.REVOKED)
		end
		if is_fatal(code) then
			-- N4: the executor reported a terminal fault while submitting (the
			-- broker re-captures before dispatch). Stop and revoke now.
			stats.faults = stats.faults + 1
			return finish("fault", code)
		end
		if code == "broker_stale_epoch" or code == "broker_observation_changed" or code == "broker_epoch_regression" then
			stats.stale = stats.stale + 1
			stats.rejected = stats.rejected + 1
			consecutive_errors = 0
			reset_transient()
			set_cooldown(now, min_interval)
			log_rejection(now, item, CODE.STALE, item.reason)
			return "idle", CODE.STALE
		end
		if is_transient(code) then
			stats.rejected = stats.rejected + 1
			local status, transient_code = register_transient(now, code)
			if status ~= nil then
				return status, transient_code
			end
			return "idle", CODE.TRANSIENT
		end
		stats.rejected = stats.rejected + 1
		log_rejection(now, item, CODE.DISPATCH_FAILED, item.reason)
		local status, failure = register_error(now, CODE.DISPATCH_FAILED)
		if status ~= nil then
			return status, failure
		end
		return "idle", CODE.DISPATCH_FAILED
	end

	local function control_latch_expired(now)
		if control_latch_at == nil or control_latch_seconds <= 0 then
			return false
		end
		if now - control_latch_at <= control_latch_seconds then
			return false
		end
		if external_wait() ~= nil then
			control_latch_at = now
			return false
		end
		return true
	end

	function loop.update()
		if stopped then
			return "stopped", stop_reason
		end
		local ok_revoked, revoked = pcall(broker.is_revoked)
		if ok_revoked and revoked == true then
			return finish("revoked", CODE.REVOKED)
		end
		local ok_now, current = pcall(clock.now)
		if not ok_now or not is_number(current) then
			return finish("error", CODE.BAD_CLOCK)
		end
		local now = current
		last_now = now

		if controls ~= nil then
			local ok_next, name = pcall(controls.next)
			if ok_next and type(name) == "string" and CONTROL_ALLOWLIST[name] == true then
				if control_latch ~= name then
					-- N3: respect the cooldown before re-attempting the deferred
					-- transition. This branch used to run every frame, so a
					-- failing advance was bounded by the frame-rate streak guard
					-- (about 20s at 60 FPS, about 8s at 144 FPS) rather than wall
					-- clock. While cooling down, fall through to the normal path so
					-- trusted capture (`controls.next` is only refreshed by
					-- capture) runs on the next eligible step and a stale cash-out
					-- latch cannot persist.
					if cooldown_until == nil or now >= cooldown_until then
						-- Drop any outstanding decision before the trusted
						-- transition so a queued callback cannot commit a stale
						-- token afterwards.
						abandon_pending()
						local ok_adv, advanced = pcall(controls.advance, name)
						if not ok_adv or advanced ~= true then
							-- H2: the control button may still be animating in,
							-- or the previous commit may still be latched. That is
							-- a bounded wait, not a match abort, and is not
							-- counted as an error.
							local status, transient_code = register_transient(now, CODE.CONTROL_FAILED)
							if status ~= nil then
								return status, transient_code
							end
							return "idle", CODE.TRANSIENT
						end
						control_latch = name
						control_latch_at = now
						stats.controls = stats.controls + 1
						return "control", CODE.OK
					end
				else
					-- H1: the runtime's `controls.next` is only refreshed by the
					-- trusted capture (`broker.issue`). Do not deadlock on the
					-- stale latch: fall through to the normal decision path so
					-- capture runs and the control state is refreshed (a
					-- still-required control re-surfaces as a transient capture
					-- failure).
					if type(controls.refresh) == "function" then
						pcall(controls.refresh)
					end
					if control_latch_expired(now) then
						return finish("error", CODE.CONTROL_TIMEOUT)
					end
				end
			else
				control_latch = nil
				control_latch_at = nil
			end
		end

		if pending ~= nil and pending.submit_at ~= nil then
			if now >= pending.submit_at then
				return loop._submit(now)
			end
			-- M3: once a valid response is scheduled, stop the request timeout
			-- and stop polling, so a duplicate response cannot overwrite the
			-- scheduled action or reset its submit time.
			return "scheduled", CODE.OK
		end

		if pending ~= nil then
			if now - pending.request_sent_at > timeout then
				stats.timeouts = stats.timeouts + 1
				log_rejection(now, pending, CODE.TIMEOUT, nil)
				abandon_pending()
				local status, code = register_error(now, CODE.TIMEOUT)
				if status ~= nil then
					return status, code
				end
				return "idle", CODE.TIMEOUT
			end
			return do_poll(now)
		end

		if cooldown_until ~= nil and now < cooldown_until then
			return "idle", CODE.OK
		end
		if last_request_at ~= nil and now - last_request_at < min_interval then
			return "idle", CODE.OK
		end

		return do_issue(now)
	end

	function loop.stop(reason)
		if type(reason) ~= "string" or #reason == 0 or #reason > LIMITS.max_reason then
			reason = "stopped"
		end
		return finish(reason, CODE.STOPPED)
	end

	function loop.is_stopped()
		return stopped
	end

	function loop.is_terminal()
		return terminal
	end

	function loop.pending_sequence()
		if pending == nil then
			return nil
		end
		return pending.sequence
	end

	function loop.stats()
		return shallow_copy(stats)
	end

	function loop.describe()
		return {
			stopped = stopped,
			terminal = terminal,
			stop_reason = stop_reason,
			has_pending = pending ~= nil,
			pacing = pacing,
			pacing_mode = pacing_mode,
			min_interval = min_interval,
			timeout = timeout,
			max_consecutive_errors = max_errors,
			max_transient_streak = max_transient_streak,
			max_transient_seconds = max_transient_seconds,
			transient_streak = transient_streak,
			no_action_backoff = no_action_backoff,
			waiting = waiting,
			waiting_since = waiting_since,
			wait_backoff = wait_backoff,
			wait_max_backoff = wait_max_backoff,
			no_action_max_backoff = no_action_max_backoff,
			control_latch = control_latch,
			control_latch_seconds = control_latch_seconds,
			has_revision = revision_source ~= nil,
			has_wait_state = wait_state ~= nil,
			terminal_phase = terminal_phase,
			codes = shallow_copy(CODE),
		}
	end

	loop.CODE = shallow_copy(CODE)
	loop.LIMITS = shallow_copy(LIMITS)

	return loop
end

return DecisionLoop