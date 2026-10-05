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
	DWELL = "loop_dwelling",
	NOT_READY = "loop_not_ready",
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
-- H2 thinking dwell. Normal play waits this long BEFORE the broker issues a
-- token (so the policy request and the exact canonical broker check both happen
-- after the wait, never on a held, staling token). Instant supplies no dwell.
-- The trusted pre-capture phase probe maps an engine decision phase to a dwell
-- class; an unknown phase has no class and gets no delay.
local DWELL_CLASS = {
	BLIND_SELECTION = "blind",
	PLAY_HAND = "card",
	DISCARD = "card",
	MULTIPLAYER_PVP = "pvp",
	CONSUMABLE_SELECTION = "card",
	SHOP = "shop",
	BOOSTER_SELECTION = "booster",
	ROUND_EVAL_CONTROL = "control",
	MATCH_COMPLETE = "terminal",
}
-- Cap the dwell by the AI's own visible active timer when the probe reports it:
-- target = min(base, max(0, R - reserve), fraction * R). Never reads opponent
-- or hidden timers; it is the AI's own public HUD countdown only.
local DEFAULT_DWELL_TIMER_RESERVE = 2
local DEFAULT_DWELL_TIMER_FRACTION = 0.2
-- Hard ceiling on the total carried dwell for one logical decision.
local DEFAULT_DWELL_MAX = 8

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

	-- H2: optional trusted pre-capture readiness/phase probe. When absent the
	-- loop is byte-for-byte the legacy immediate path (fixtures and old callers
	-- keep working). When present, the loop dwells before it captures.
	local readiness = rawget(options, "readiness")
	if readiness ~= nil and type(readiness) ~= "function" then
		return nil, CODE.BAD_OPTIONS
	end
	local dwell = rawget(options, "dwell")
	if dwell ~= nil then
		if not is_plain_table(dwell) then
			return nil, CODE.BAD_OPTIONS
		end
		for key, value in next, dwell do
			if type(key) ~= "string" or #key == 0 or #key > LIMITS.max_terminal_phase then
				return nil, CODE.BAD_OPTIONS
			end
			if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
				return nil, CODE.BAD_OPTIONS
			end
		end
		-- L2: keep a private copy so a caller mutating its table (production
		-- passes the shared RuntimeBootstrap.DEFAULT_DWELL) cannot change an
		-- already-constructed loop.
		local dwell_copy = {}
		for key, value in next, dwell do
			dwell_copy[key] = value
		end
		dwell = dwell_copy
	end
	local dwell_max = rawget(options, "dwell_max")
	if dwell_max == nil then
		dwell_max = DEFAULT_DWELL_MAX
	end
	if not is_number(dwell_max) or dwell_max < 0 then
		return nil, CODE.BAD_OPTIONS
	end
	-- A1: how long a soft overlay/pause may hold the thinking clock before the
	-- loop falls through to the legitimate do_issue path and acts under the
	-- overlay. Bounded by `dwell_max` (0 => act immediately).
	local overlay_grace = rawget(options, "overlay_grace")
	if overlay_grace == nil then
		overlay_grace = dwell_max
	end
	if not is_number(overlay_grace) or overlay_grace < 0 then
		return nil, CODE.BAD_OPTIONS
	end
	if overlay_grace > dwell_max then
		overlay_grace = dwell_max
	end
	local dwell_timer_reserve = rawget(options, "dwell_timer_reserve")
	if dwell_timer_reserve == nil then
		dwell_timer_reserve = DEFAULT_DWELL_TIMER_RESERVE
	end
	if not is_number(dwell_timer_reserve) or dwell_timer_reserve < 0 then
		return nil, CODE.BAD_OPTIONS
	end
	local dwell_timer_fraction = rawget(options, "dwell_timer_fraction")
	if dwell_timer_fraction == nil then
		dwell_timer_fraction = DEFAULT_DWELL_TIMER_FRACTION
	end
	if not is_number(dwell_timer_fraction) or dwell_timer_fraction < 0 or dwell_timer_fraction > 1 then
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
	-- Broker CAPTURE/control transient window (register_transient): bounded by
	-- max_transient_seconds/streak and cleared only by a real broker progress
	-- (issue/submit success). It is NEVER cleared by a readiness probe.
	local transient_streak = 0
	local transient_started_at = nil
	-- Readiness hard-hold window (hold_not_ready): a SEPARATE bound for a
	-- non-actionable engine (lock / STOP_USE / play animation / unknown). A
	-- genuine soft or ready phase is progress and resets this window, but it must
	-- never reset the capture window above (a soft overlay does not prove the
	-- broker can capture a valid canonical state).
	local readiness_streak = 0
	local readiness_started_at = nil
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
	-- H2 dwell state. A logical decision's thinking time starts when a
	-- decision-ready state first appears and is carried across state changes,
	-- stale/no-action/empty/transient retries and opponent-location changes until
	-- the decision commits or the match resets. `dwell_elapsed` is the accumulated
	-- ACTIVE time and `dwell_active_since` is nil while frozen (a soft
	-- overlay/pause), so overlay/pause time is excluded. `dwell_first_shop` marks
	-- the first inspection of a shop visit; `shop_visit_open` is true while the
	-- logical context is inside a shop visit (the shop itself or a booster opened
	-- from it).
	--
	-- L5: a verified opponent wait does NOT reset the elapsed time: while a wait
	-- holds, the clock keeps running against the cap, so an AI that was already
	-- thinking may act immediately when the wait clears (accepted). An in-flight
	-- decision is never cancelled by the wait check; its validity is
	-- re-established by the broker's exact epoch/canonical recheck, so a still-valid
	-- legacy decision completes (see
	-- `a_decision_in_flight_when_the_wait_begins_still_completes`).
	-- `dwell_elapsed` counts only ACTIVE thinking time; `dwell_active_since` is
	-- nil while the clock is frozen (a soft overlay/pause), so overlay/pause time
	-- never advances the dwell and never leaks into the next decision.
	local dwell_active = false
	local dwell_elapsed = 0
	local dwell_active_since = nil
	local dwell_class = nil
	local dwell_first_shop = false
	local shop_visit_open = false
	-- When the current soft overlay/pause episode began (nil when not soft). The
	-- loop falls through to do_issue after `overlay_grace`.
	local soft_since = nil
	local stats = {
		issued = 0,
		requests = 0,
		submitted = 0,
		rejected = 0,
		stale = 0,
		errors = 0,
		timeouts = 0,
		out_of_order = 0,
		idle = 0,
		dwelling = 0,
		not_ready = 0,
		overlay_idle = 0,
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

	-- A genuine readiness progress (a valid soft or ready phase) clears only the
	-- readiness hard-hold window; it never clears the broker capture window.
	local function reset_readiness()
		readiness_streak = 0
		readiness_started_at = nil
	end

	-- N6: observable progress clears the no-action throttle so a future state
	-- change is asked about promptly instead of inheriting the old backoff.
	local function note_progress()
		last_no_action_epoch = nil
		no_action_backoff = nil
	end

	-- H2: a committed action (or a match reset/stop) ends the logical decision,
	-- so the next decision starts a fresh dwell. Stale/no-action/empty/transient
	-- retries deliberately do NOT reset it, so a retry never re-adds a full dwell.
	local function reset_dwell()
		dwell_active = false
		dwell_elapsed = 0
		dwell_active_since = nil
		dwell_class = nil
		dwell_first_shop = false
	end

	-- Freeze the dwell clock (a soft overlay/pause): bank the active portion and
	-- stop counting, so overlay/pause time never advances the dwell.
	local function freeze_dwell(now)
		if dwell_active_since ~= nil and now > dwell_active_since then
			dwell_elapsed = dwell_elapsed + (now - dwell_active_since)
		end
		dwell_active_since = nil
	end

	local function dwell_elapsed_now(now)
		local elapsed = dwell_elapsed
		if dwell_active_since ~= nil and now > dwell_active_since then
			elapsed = elapsed + (now - dwell_active_since)
		end
		return elapsed
	end

	-- A committed logical transition ends the current shop visit as well (a
	-- cash-out control happens outside a shop; a match reset clears everything).
	local function reset_shop_visit()
		shop_visit_open = false
		dwell_first_shop = false
	end

	-- Maintain the shop-visit flag from the current decision class and report
	-- whether THIS evaluation is the first to enter the shop of the visit.
	-- `shop` and `booster` are both part of a visit; any other class leaves it.
	local function note_class(class)
		local entering_shop = (class == "shop" and not shop_visit_open)
		if class == "shop" or class == "booster" then
			shop_visit_open = true
		else
			shop_visit_open = false
		end
		return entering_shop
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
		reset_dwell()
		reset_shop_visit()
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
		reset_dwell()
		reset_shop_visit()
		end_wait(last_now)
		stats.terminal = true
		abandon_pending()
		pcall(broker.cancel)
		pcall(function()
			broker.revoke()
		end)
		return "terminal", CODE.TERMINAL
	end

	-- H2: trusted pre-capture readiness/phase probe. It returns only bounded
	-- primitives (a ready flag, an optional decision phase token, the AI's own
	-- visible timer and a soft/hard block kind), never engine handles, opponent
	-- data or canonical content, and it is never policy input. An absent or
	-- malformed probe is treated conservatively as a hard block.
	local function read_probe()
		if readiness == nil then
			return nil
		end
		local ok, value = pcall(readiness)
		if not ok or type(value) ~= "table" or getmetatable(value) ~= nil then
			return nil
		end
		local ready = rawget(value, "ready") == true
		local phase = printable(rawget(value, "phase"), LIMITS.max_terminal_phase)
		local timer = rawget(value, "timer_remaining")
		if timer ~= nil and not is_nat_int(timer) then
			timer = nil
		end
		if ready then
			if phase == nil then
				return nil
			end
			return { ready = true, phase = phase, timer_remaining = timer }
		end
		local block = rawget(value, "block")
		if block ~= "soft" and block ~= "hard" then
			block = "hard"
		end
		return { ready = false, phase = phase, block = block }
	end

	-- Per-phase dwell seconds, capped by the AI's own visible active timer and
	-- the hard ceiling. 0 means issue immediately (controls and unknown phases).
	local function dwell_target(class, timer)
		if class == nil or dwell == nil then
			return 0
		end
		local base = rawget(dwell, class)
		if type(base) ~= "number" then
			return 0
		end
		if class == "shop" and dwell_first_shop == true then
			local first = rawget(dwell, "shop_first")
			if type(first) == "number" then
				base = first
			end
		end
		local target = base
		if is_nat_int(timer) then
			-- A Ranked ante deadline covers several blinds and shops, not just
			-- the next action. Stop adding long pauses as soon as it is active.
			if target > 1 then
				target = 1
			end
			if timer <= 30 then
				target = 0
			end
			local reserve_cap = timer - dwell_timer_reserve
			if reserve_cap < 0 then
				reserve_cap = 0
			end
			local fraction_cap = math.floor(timer * dwell_timer_fraction)
			if reserve_cap < target then
				target = reserve_cap
			end
			if fraction_cap < target then
				target = fraction_cap
			end
		end
		if target > dwell_max then
			target = dwell_max
		end
		return target
	end

	-- H2: pre-capture terminal check. With the readiness probe wired (Normal) a
	-- terminal phase is seen on EVERY update, including the dwell and the legacy
	-- scheduled paths, without capturing or holding a token. Without the probe
	-- (legacy/fixtures) terminal detection stays exactly where it was (inside
	-- do_issue, from the captured phase). On a terminal it drops any outstanding
	-- decision (`abandon_pending`) because the match is over and no queued token
	-- may still commit; a non-terminal probe returns nil and never touches a
	-- pending decision.
	local function terminal_probe()
		if readiness == nil then
			return nil
		end
		local probe = read_probe()
		if probe ~= nil and probe.phase == terminal_phase then
			abandon_pending()
			return finish_terminal()
		end
		return nil
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

	-- H2 readiness: while the trusted probe reports the engine is not yet
	-- actionable (a HARD lock/STOP_USE/play animation or an unknown state) the
	-- loop does NOT capture and does NOT start the thinking clock. It uses its OWN
	-- bounded wall-clock window (separate from the broker capture window, which a
	-- readiness probe must never clear), so a genuinely stuck non-actionable state
	-- still ends the match cleanly. A soft overlay/pause is NOT routed here.
	local function hold_not_ready(now)
		stats.idle = stats.idle + 1
		stats.not_ready = stats.not_ready + 1
		set_cooldown(now, transient_backoff)
		readiness_streak = readiness_streak + 1
		if readiness_started_at == nil then
			readiness_started_at = now
		end
		if readiness_streak > max_transient_streak then
			return finish("error", CODE.NOT_READY)
		end
		if now - readiness_started_at > max_transient_seconds then
			return finish("error", CODE.NOT_READY)
		end
		return "idle", CODE.NOT_READY
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
			-- H2: a commit ends the logical decision (the shop visit stays open so
			-- the next shop decision in this visit uses the ordinary dwell).
			reset_dwell()
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

		-- H2: terminal wins on every update when the readiness probe can see it,
		-- including while dwelling or on the legacy scheduled path.
		local term_status, term_code = terminal_probe()
		if term_status ~= nil then
			return term_status, term_code
		end

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
						-- M1: a successful control advance IS a committed logical
						-- transition. End the current decision's dwell (the
						-- cash-out animation time must not be charged to the next
						-- shop's first inspection) and leave any open shop visit.
						reset_dwell()
						reset_shop_visit()
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

		-- H2 readiness. The THINKING-clock freeze/resume runs before the
		-- issue-cadence gates so a soft overlay/pause always excludes its time,
		-- but the actual issue/wait handling below still respects the existing
		-- cooldown/min_interval backoff. Instant (no readiness probe) skips this
		-- entirely and is the legacy immediate path.
		local probe = nil
		local soft = false
		if readiness ~= nil then
			probe = read_probe()
			if probe ~= nil and probe.ready == false and probe.block == "soft" then
				soft = true
				-- A1: an overlay/pause gates the THINKING CLOCK only. Freeze it
				-- (overlay time is never counted and never leaks into the next
				-- decision). A verified soft phase proves the hard gates
				-- (lock/STOP_USE/play animation) are clear, so it is genuine
				-- progress: reset the hard transient window so overlay time never
				-- accumulates toward the fatal deadline. A combined lock+overlay
				-- probe is hard (not soft), so it is never reset here.
				if dwell_active_since ~= nil then
					freeze_dwell(now)
				end
				-- Genuine readiness progress: clear only the readiness hard-hold
				-- window. The broker capture window is deliberately untouched, so
				-- a persistent capture failure behind a popup still hits its
				-- existing bound.
				reset_readiness()
				if soft_since == nil then
					soft_since = now
				end
			else
				soft_since = nil
				if probe ~= nil and probe.ready then
					-- A valid ready phase is genuine readiness progress too.
					reset_readiness()
				end
			end
		end

		if cooldown_until ~= nil and now < cooldown_until then
			stats.idle = stats.idle + 1
			return "idle", CODE.OK
		end
		if last_request_at ~= nil and now - last_request_at < min_interval then
			stats.idle = stats.idle + 1
			return "idle", CODE.OK
		end

		-- Soft overlay/pause: after a bounded grace (or a verified wait) fall
		-- through to the legitimate do_issue path and act under the overlay. The
		-- backoff gates above are respected, so a persistent popup cannot cause a
		-- capture/request every frame.
		if soft then
			stats.overlay_idle = stats.overlay_idle + 1
			if external_wait() ~= nil or now - soft_since >= overlay_grace then
				return do_issue(now)
			end
			stats.idle = stats.idle + 1
			return "idle", CODE.OK
		end

		-- Hard not-ready (lock / STOP_USE / play animation / unknown) and a
		-- malformed probe: a bounded, non-capturing fatal hold. A verified wait
		-- keeps its own do_issue handling.
		if readiness ~= nil and (probe == nil or (probe.ready == false and probe.block ~= "soft")) then
			if external_wait() ~= nil then
				return do_issue(now)
			end
			local hold_status, hold_code = hold_not_ready(now)
			if hold_status ~= nil then
				return hold_status, hold_code
			end
			return "idle", CODE.NOT_READY
		end

		-- Actionable now. A verified wait still holds via do_issue.
		if readiness ~= nil and probe ~= nil and probe.ready and external_wait() == nil then
			local class = rawget(DWELL_CLASS, probe.phase)
			local entering_shop = false
			if class ~= nil then
				entering_shop = note_class(class)
			end
			local base = nil
			if class ~= nil and dwell ~= nil then
				base = rawget(dwell, class)
			end
			if class ~= nil and type(base) == "number" and base > 0 then
				if not dwell_active then
					-- A new logical decision starts a fresh dwell.
					dwell_active = true
					dwell_elapsed = 0
					dwell_active_since = now
					dwell_class = class
					dwell_first_shop = (class == "shop" and entering_shop)
				else
					dwell_class = class
					if dwell_active_since == nil then
						dwell_active_since = now -- resume after a soft freeze
					end
				end
				local target = dwell_target(class, probe.timer_remaining)
				if target > 0 and dwell_elapsed_now(now) < target then
					stats.dwelling = stats.dwelling + 1
					return "dwelling", CODE.DWELL
				end
			elseif class ~= nil then
				-- Zero-dwell class (control): a separate committed transition;
				-- never start or carry the clock into the next real decision.
				reset_dwell()
			end
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
			has_readiness = readiness ~= nil,
			dwell = dwell ~= nil,
			dwell_max = dwell_max,
			overlay_grace = overlay_grace,
			dwell_active = dwell_active,
			dwell_elapsed = dwell_elapsed_now(last_now or 0),
			dwell_active_since = dwell_active_since,
			dwell_class = dwell_class,
			dwell_first_shop = dwell_first_shop,
			soft_since = soft_since,
			shop_visit_open = shop_visit_open,
			stats = shallow_copy(stats),
			terminal_phase = terminal_phase,
			codes = shallow_copy(CODE),
		}
	end

	loop.CODE = shallow_copy(CODE)
	loop.LIMITS = shallow_copy(LIMITS)

	return loop
end

return DecisionLoop
