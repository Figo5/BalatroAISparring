-- Trusted staged-runtime bootstrap.
--
-- This is the single outer adapter that turns injected globals (G/MP/G.FUNCS,
-- the game's json module, love.thread) into the private modules the staged AI
-- runtime needs. It is the ONLY place permitted to mint a production broker
-- capability, and it does so only after:
--
--   1. the role is exactly `human` or `ai` (a role string alone is NOT
--      authority);
--   2. the reported save directory, Lovely Mods root and current AISparring mod
--      path exactly match the launcher-staged expectations;
--   3. an independently verified launcher handshake agrees on nonce, session,
--      role, content hash and control port;
--   4. the control service answered the authenticated `hello` with success.
--
-- The capability, the broker, the engine adapter/executor and the decision loop
-- stay in module-private locals: they are never exposed through `describe()` or
-- any status/telemetry surface. The human role never constructs the executor,
-- the policy channel or any action automation.
--
-- Loading this file has no side effect. The default/live path (any non-staged
-- role, mismatched paths or unverified launcher) returns inert and never touches
-- official Multiplayer routing.

local RuntimeBootstrap = {}

RuntimeBootstrap.CODE = {
	OK = "boot_ok",
	BAD_PORTS = "boot_bad_ports",
	NOT_STAGED = "boot_not_staged",
	BAD_TOKEN = "boot_bad_token",
	BAD_PORT = "boot_bad_port",
	ENV_MISMATCH = "boot_env_mismatch",
	ENV_UNAVAILABLE = "boot_env_unavailable",
	LAUNCHER_UNVERIFIED = "boot_launcher_unverified",
	BAD_CHANNELS = "boot_bad_channels",
	BAD_CODEC_PORTS = "boot_bad_codec_ports",
	BAD_MODULES = "boot_bad_modules",
	BAD_TRANSPORT = "boot_bad_transport",
	NO_THREAD = "boot_no_thread",
	ALREADY_INSTALLED = "boot_already_installed",
	NOT_INSTALLED = "boot_not_installed",
	HELLO_FAILED = "boot_hello_failed",
	HELLO_REJECTED = "boot_hello_rejected",
	SETUP_FAILED = "boot_setup_failed",
	CONFIG_MISMATCH = "boot_config_mismatch",
	COORD_TIMEOUT = "boot_coord_timeout",
	SEED_MISMATCH = "boot_seed_mismatch",
	SEED_TIMEOUT = "boot_seed_timeout",
	SELECTION_MISMATCH = "boot_selection_mismatch",
	TERMINAL_TIMEOUT = "boot_terminal_timeout",
	NOT_ARMED = "boot_not_armed",
	ACTIVATE_FAILED = "boot_activate_failed",
	GUARD_FAILED = "boot_guard_failed",
	WRONG_ROLE = "boot_wrong_role",
	UPDATE_FAILED = "boot_update_failed",
	TERMINAL = "boot_terminal",
	STOPPED = "boot_stopped",
	INTERNAL = "boot_internal_error",
	UNLOCK_STUCK = "unlock_overlay_stuck",
}

RuntimeBootstrap.ROLE_AI = "ai_staged"
RuntimeBootstrap.ROLE_HUMAN = "human_staged"
-- Explicit versioned Ranked contract carried through Setup/Ready.
RuntimeBootstrap.RANKED_CONFIG_SCHEMA = "aisparring.ranked_effective_config.v1"
-- The production Standard Ranked registry key. A driver configured with this
-- key must require the Ranked schema; only an explicit legacy driver fixture may
-- use the schema-less Major League digest path.
RuntimeBootstrap.RANKED_RULESET_ID = "ruleset_mp_standard_ranked"

RuntimeBootstrap.LIMITS = {
	max_token = 128,
	max_path = 512,
	max_hash = 128,
	max_update_errors = 5,
	max_coordination_per_update = 8,
	max_status_per_second = 30,
	heartbeat_interval = 0.5,
	hello_timeout = 10,
	max_reason = 64,
	-- The service owns the policy child and reports a slow worker after its
	-- bounded 10 s decision timeout. The decision loop must budget longer than
	-- the service (plus a poll margin) so the service's own timeout is observed
	-- first; on a loop timeout the loop issues a wire `decide_cancel` for the
	-- owned sequence and reissues a fresh `decide_begin`. The transport's own
	-- request timeout is a strictly higher backstop so the loop, not the dumb
	-- channel, is the one that cancels.
	decision_timeout = 15,
	decision_poll_interval = 0.25,
	decision_transport_margin = 15,
	-- Bounded pre-start coordination retry: a late UI element, a not-yet-ready
	-- registry, an unattested service or a slow opponent is a wait, never a
	-- frame error. Coordination aborts only after `coord_timeout` seconds.
	coord_retry_interval = 0.5,
	coord_timeout = 60,
	-- Vanilla unlock-notification dismissal: at most one attempt per interval, a
	-- fixed per-instance success cap and an overall attempt cap. A continuously
	-- blocking overlay that never clears is bounded by `unlock_block_timeout`
	-- (a clean stop, never a frame error). Diagnostic-only otherwise: it never
	-- counts toward update_errors.
	unlock_dismiss_interval = 0.5,
	max_unlock_dismissals = 32,
	max_unlock_attempts = 64,
	-- A continuously-present unlock overlay that never clears (a callback that
	-- never really dismisses, a refusal loop or a chained popup that never ends)
	-- is a clean stop, exactly like the pre-start/hello timeouts. The clock runs
	-- on every allowed, non-graced tick with an unlock overlay up (including
	-- capped or rate-limited ticks) and is cleared while the human grace below
	-- runs, so a grace never counts toward it.
	unlock_block_timeout = 20,
	-- The human's own pre-start unlock notification is shown for this grace
	-- window before it is dismissed, so an attended human can read it. The AI
	-- is always immediate and never graced.
	human_unlock_grace = 8,
	-- Overall pre-start coordination deadline. The service aborts its own
	-- pre-start window after 90 s, so the runtime's deadline must be strictly
	-- larger (service timeout + margin) or the runtime would keep attempting
	-- coordination the service has already refused.
	prestart_timeout = 120,
	-- Terminal drain diagnostics: how many decoded late replies may be logged as
	-- dropped after terminal. The counter keeps counting but the logging stops so
	-- a hostile peer cannot flood the log; every dropped reply is still consumed.
	max_terminal_drops = 16,
	-- Cadence of the bracketed inbound-observer snapshot while terminal is
	-- retained: one bounded snapshot group every this many seconds, never per
	-- frame.
	retained_snapshot_interval = 30,
	-- Wire-bound integer ceiling for the summary counters (the service caps every
	-- bounded int at this value). New frame/loop metrics saturate here rather than
	-- being refused by the service.
	max_sequence = 2147483647,
}

-- Staging observer bridge: the exact namespaced global the source-pinned
-- Multiplayer dispatch observer reads before its own handler lookup. The staged
-- human runtime installs the tap; the AI runtime leaves it nil. The tap receives
-- only the parsed action name (never a payload) and returns nothing.
RuntimeBootstrap.INBOUND_TAP_NAME = "AISP_INBOUND_TAP"
RuntimeBootstrap.INBOUND_EVENT_NAMES = { "enemyDisconnected", "reconnecting", "stopGame" }

local CODE = RuntimeBootstrap.CODE

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

local function is_plain(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function rget(obj, key)
	if type(obj) ~= "table" or key == nil then
		return nil
	end
	return rawget(obj, key)
end

local function rpath(obj, a, b)
	return rget(rget(obj, a), b)
end

-- The service's bounded seed vocabulary (`practice_service.SEED_PATTERN`).
-- Multiplayer's The Order prefixes the actual engine seed with one '*'. Keep
-- that identity as human-only audit metadata; never pass it to AIObservation.
local RUN_SEED_PATTERN = "^%*?[0-9A-Za-z_%-]+$"

-- The actual, already-resolved run seed of a real initialized run: `Game:start_run`
-- assigns `G.GAME.pseudorandom.seed` from the trusted `args.seed` (the gauntlet
-- custom seed) or `generate_starting_seed()` for a normal match (pinned
-- reference/game/game.lua:2164). Reading the resolved field avoids any stale
-- menu/prior-run seed and is never derived from policy.
local function resolved_run_seed(G)
	local seed = rget(rget(rget(G, "GAME"), "pseudorandom"), "seed")
	if type(seed) ~= "string" or #seed == 0 or #seed > 32 then
		return nil
	end
	if string.match(seed, RUN_SEED_PATTERN) == nil then
		return nil
	end
	return seed
end

local function token_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	return value
end

local function shallow_copy(source)
	local out = {}
	for key, value in next, source do
		out[key] = value
	end
	return out
end

local function normalize_path(value)
	local bounded = token_of(value, RuntimeBootstrap.LIMITS.max_path)
	if bounded == nil then
		return nil
	end
	local normalized = string.lower(bounded)
	normalized = string.gsub(normalized, "\\", "/")
	normalized = string.gsub(normalized, "/+", "/")
	if #normalized > 1 then
		normalized = string.gsub(normalized, "/$", "")
	end
	if #normalized == 0 then
		return nil
	end
	return normalized
end

local function basename(path)
	return string.match(path, "([^/]+)$")
end

local function under(root, child)
	local prefix = root .. "/"
	return string.sub(child, 1, #prefix) == prefix
end

local unpack_values = table.unpack or unpack

-- Capture every return value including nil holes, so a wrapped engine callback
-- keeps its exact return arity.
local function pack_values(...)
	local count = select("#", ...)
	local packed = { n = count }
	for index = 1, count do
		packed[index] = select(index, ...)
	end
	return packed
end

RuntimeBootstrap.CODE = shallow_copy(CODE)

-- Install revision hooks over injected engine targets. Each target is
-- { table = t, name = "method", reason = "token" }. The wrapper preserves the
-- original return values and lets exceptions propagate; it bumps the trusted
-- revision only AFTER a successful call, so a failed callback never advances
-- state. It is not a per-frame bump: only the named relevant methods fire.
local function install_hooks(hook_targets, revision)
	if type(hook_targets) ~= "table" or type(revision) ~= "table" then
		return nil
	end
	local installed = {}
	for i = 1, #hook_targets do
		local target = hook_targets[i]
		if type(target) == "table" then
			local owner = rawget(target, "table")
			local name = rawget(target, "name")
			local reason = rawget(target, "reason")
			if type(owner) == "table"
				and type(name) == "string"
				and type(reason) == "string"
				and #reason > 0
				and #reason <= RuntimeBootstrap.LIMITS.max_reason
				and type(rawget(owner, name)) == "function" then
				local original = owner[name]
				local wrapper = function(...)
					local results = pack_values(original(...))
					revision.bump(reason)
					return unpack_values(results, 1, results.n)
				end
				owner[name] = wrapper
				installed[#installed + 1] = { owner = owner, name = name, original = original, wrapper = wrapper }
			end
		end
	end
	local function restore()
		for i = #installed, 1, -1 do
			local record = installed[i]
			if record.owner[record.name] == record.wrapper then
				record.owner[record.name] = record.original
			end
		end
	end
	return restore
end

RuntimeBootstrap.install_hooks = install_hooks

-- Grounded Multiplayer wait states the *runtime* legitimately owns while the AI
-- is not on a decision. These are the real, parser-visible MP fields
-- (`MP.GAME.ready_blind`, a PvP blind with no hands left, the PvP countdown) from
-- the pinned source — never a blanket `true`. Any other condition, including an
-- unrecognised engine state or a genuine capture fault, returns nil so the
-- decision loop keeps its own bounded transient window and can still abort.
RuntimeBootstrap.WAIT_STATES = {
	READY_BLIND = "mp_ready_blind",
	PVP_NO_HANDS = "mp_pvp_no_hands",
	PVP_COUNTDOWN = "mp_pvp_countdown",
}

-- H2 default thinking dwell per decision class (seconds). Production Normal
-- passes this table through `ports.dwell`; it is tuning data informed by sparse
-- match observations, not measured population statistics, and it never touches
-- the engine's own timers or animations.
RuntimeBootstrap.DEFAULT_DWELL = {
	blind = 2,
	card = 4,
	pvp = 4,
	shop = 6,
	shop_first = 8,
	booster = 4,
	control = 0,
}

-- The real current blind is the PvP blind: `G.GAME.blind.pvp` (any non-nil,
-- non-false value, matching MP's `... or blind.pvp` truthiness) or the pinned
-- nemesis blind key. Never inferred from `pvp_reached`, which Multiplayer resets
-- to false when the PvP blind starts.
local function current_blind_is_pvp(G)
	local blind = rget(rget(G, "GAME"), "blind")
	if type(blind) ~= "table" then
		return false
	end
	local pvp = rget(blind, "pvp")
	if pvp ~= nil and pvp ~= false then
		return true
	end
	local config = rget(blind, "config")
	local key = rget(rget(config, "blind"), "key")
	return key == "bl_mp_nemesis"
end

-- The engine states of the PvP hand loop (select, played, redraw). Resolved by
-- name from the real `G.STATES`; an unknown state is never a wait.
local PVP_HAND_LOOP_STATES = { "SELECTING_HAND", "HAND_PLAYED", "DRAW_TO_HAND" }

local function in_pvp_hand_loop(G)
	local states = rget(G, "STATES")
	local state_value = rget(G, "STATE")
	if not is_int(state_value) then
		return false
	end
	for _, name in ipairs(PVP_HAND_LOOP_STATES) do
		local value = rget(states, name)
		if is_int(value) and value == state_value then
			return true
		end
	end
	return false
end

function RuntimeBootstrap.mp_wait_state(mp, G)
	local game = rget(mp, "GAME")
	if type(game) ~= "table" then
		return nil
	end
	if rget(game, "ready_blind") == true then
		return RuntimeBootstrap.WAIT_STATES.READY_BLIND
	end
	-- A round that already ended (or is past PvP) is normally consumed by the
	-- next decision, not stalled; only a still-open PvP blind is a trusted wait.
	if rget(game, "round_ended") == true or rget(game, "end_pvp") == true then
		return nil
	end
	-- PvP no-hands wait: the current blind really is the PvP blind and the AI has
	-- no hands left, but the server has not yet signalled `end_pvp`. This is the
	-- ordinary wait for the human's PvP turn and must not depend on
	-- `pvp_reached` (false during the PvP round).
	-- Only while the engine is still inside the PvP hand loop: Multiplayer keeps
	-- the blind PvP through round evaluation and clears `end_pvp` once the round
	-- moves on, so without the state check the wait could outlive the PvP round
	-- (cash-out, shop) and silence every later decision.
	if current_blind_is_pvp(G) and in_pvp_hand_loop(G) then
		local hands_left = rget(rget(rget(G, "GAME"), "current_round"), "hands_left")
		if is_int(hands_left) and hands_left <= 0 then
			return RuntimeBootstrap.WAIT_STATES.PVP_NO_HANDS
		end
	end
	local countdown = rget(game, "pvp_countdown")
	if is_int(countdown) and countdown > 0 then
		return RuntimeBootstrap.WAIT_STATES.PVP_COUNTDOWN
	end
	return nil
end

-- SAMPLED STATE-EDGE HEURISTIC (diagnostic only; never inbound event evidence).
-- It only READS the public state the real Multiplayer handlers already write
-- (`MP.enemy_disconnect_countdown`, `MP.self_reconnect_countdown`/
-- `MP.LOBBY.connected`, and a running joined match leaving RUN). Because it
-- samples once per update it cannot prove how many actual inbound messages
-- arrived: two same-kind messages collapse to one edge, a `stopGame` that changes
-- no tracked state is missed, and a voluntary menu transition without a message
-- can look like one. It is retained only as a state diagnostic; the certification
-- signal is the staging dispatch observer's `inbound_events`. It never calls,
-- wraps, replaces or suppresses a handler. `previous`/`started` carry the
-- caller's prior observation and the trusted driver's latched start; the returned
-- table is the next sample plus a 0/1 rising-edge marker per signal.
function RuntimeBootstrap.observe_state_edges(previous, mp, g, started)
	local prev = is_plain(previous) and previous or {}
	local state = {
		enemy = prev.enemy == true,
		reconnect = prev.reconnect == true,
		match = prev.match == true,
		enemy_edge = 0,
		reconnect_edge = 0,
		stop_edge = 0,
	}
	if not is_plain(mp) then
		return state
	end
	local enemy = rget(mp, "enemy_disconnect_countdown") ~= nil
	if enemy and not state.enemy then
		state.enemy_edge = 1
	end
	state.enemy = enemy

	local lobby_connected = rpath(mp, "LOBBY", "connected")
	local reconnect = rget(mp, "self_reconnect_countdown") ~= nil or lobby_connected == false
	if reconnect and not state.reconnect then
		state.reconnect_edge = 1
	end
	state.reconnect = reconnect

	local stages = rget(g, "STAGES")
	local stage_value = rget(g, "STAGE")
	local run_stage = rget(stages, "RUN")
	local in_run = is_int(stage_value) and is_int(run_stage) and stage_value == run_stage
	local lobby_code = rpath(mp, "LOBBY", "code")
	local match = started == true and in_run and type(lobby_code) == "string" and #lobby_code > 0
	if state.match and not match and not state.enemy and not state.reconnect then
		state.stop_edge = 1
	end
	state.match = match
	return state
end

function RuntimeBootstrap.factory(ports)
	if not is_plain(ports) then
		return nil, CODE.BAD_PORTS
	end

	local role = rawget(ports, "role")
	local expected = rawget(ports, "expected")
	local env = rawget(ports, "env")
	local launcher = rawget(ports, "launcher")
	local protocol = rawget(ports, "control_protocol")
	local transport_factory = rawget(ports, "control_transport_factory")
	local control_thread = rawget(ports, "control_thread")
	local love_thread = rawget(ports, "love_thread")
	local get_channel = rawget(ports, "get_channel")
	local channels_port = rawget(ports, "channels")
	local clock = rawget(ports, "clock")
	local logger = rawget(ports, "logger")
	local modules = rawget(ports, "modules")
	local G = rawget(ports, "G")
	local MP = rawget(ports, "MP")
	local funcs = rawget(ports, "funcs") or rget(G, "FUNCS")
	local element_for = rawget(ports, "element_for")
	local encode = rawget(ports, "encode")
	local decode = rawget(ports, "decode")
	local ui_notify = rawget(ports, "ui_notify")
	local spawn_thread = rawget(ports, "spawn_thread")
	local terminal_probe = rawget(ports, "terminal_probe")

	local session = token_of(rawget(ports, "session"), RuntimeBootstrap.LIMITS.max_token)
	local credential = token_of(rawget(ports, "credential"), RuntimeBootstrap.LIMITS.max_token)
	local nonce = token_of(rawget(ports, "nonce"), RuntimeBootstrap.LIMITS.max_token)
	local content_hash = token_of(rawget(ports, "content_hash"), RuntimeBootstrap.LIMITS.max_hash)
	local control_port = rawget(ports, "control_port")
	local mode = rawget(ports, "mode") or "normal"
	local difficulty = rawget(ports, "difficulty") or "competitive"
	local pacing = rawget(ports, "pacing") or "normal"
	-- Optional trusted thinking-dwell table (H2). Production (Normal) passes
	-- `RuntimeBootstrap.DEFAULT_DWELL`; a caller that omits it keeps the legacy
	-- immediate path. It is validated again by the decision loop factory.
	local dwell_port = rawget(ports, "dwell")
	if dwell_port ~= nil and not is_plain(dwell_port) then
		return nil, CODE.BAD_PORTS
	end
	local decision_base = rawget(ports, "decision_base") or 1000000
	local auto_coordinate = rawget(ports, "auto_coordinate")
	if auto_coordinate == nil then
		auto_coordinate = true
	end
	local stall_timeout = rawget(ports, "stall_timeout")
	local poll_interval = RuntimeBootstrap.LIMITS.decision_poll_interval
	-- Loop timeout = service timeout + one poll interval (documented recovery
	-- budget); the transport's request timeout is a strictly higher backstop.
	local loop_timeout = RuntimeBootstrap.LIMITS.decision_timeout + poll_interval
	local transport_request_timeout = loop_timeout + RuntimeBootstrap.LIMITS.decision_transport_margin
	local coord_retry_interval = RuntimeBootstrap.LIMITS.coord_retry_interval

	if type(control_thread) ~= "table"
		or type(rawget(control_thread, "channel_names")) ~= "function"
		or type(rawget(control_thread, "start")) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	if type(protocol) ~= "table" or type(rawget(protocol, "envelope")) ~= "function" then
		return nil, CODE.BAD_PORTS
	end
	if type(transport_factory) ~= "function" then
		return nil, CODE.BAD_TRANSPORT
	end
	if type(clock) ~= "table" or type(rawget(clock, "now")) ~= "function" then
		return nil, CODE.BAD_PORTS
	end

	local instance = {}

	local installed = false
	local state = "inert"
	local handshake = "none"
	local activated = false
	local hello_request = nil
	local hello_acked = false
	local transport = nil
	local thread = nil
	local channels = nil
	local decision_transport = nil
	local revision = nil
	local adapter = nil
	local reader = nil
	local executor = nil
	local authority = nil
	local capability = nil
	local broker = nil
	local loop = nil
	local mp_driver = nil
	local remove_hooks = nil
	local uninstall_guard = nil
	local last_error = nil
	local last_heartbeat = nil
	local installed_at = nil
	local update_errors = 0
	-- The control transport owns the ordered outstanding-frame list and tags
	-- every coordination reply with the op that produced it. Earlier closures
	-- (heartbeat/report_summary) queue their coordination sends through `co_send`.
	local co_send = nil
	local setup_sent = false
	local setup_acked = false
	local setup_info = nil
	local post_start_checked = false
	local post_start_check_at = nil
	local lobby_code_sent = false
	local lobby_code_acked = false
	local join_code = nil
	local join_sent = false
	local ready_sent = false
	local ready_acked = false
	local ready_digest = nil
	local ready_readiness = nil
	local start_sent = false
	local start_acked = false
	local guest_ready_committed = false
	local start_committed = false
	local start_committed_at = nil
	local lobby_enter_sent = false
	local seed_reported = false
	local human_seed = nil
	local last_coord_at = nil
	local handshake_retry_at = nil
	local coord_failure = nil
	local terminal_reported = false
	local terminal_acked = false
	local terminal_sent_at = nil
	local terminal_timeout_recorded = false
	local terminal_drops = 0
	local pending_stop = nil
	local last_summary = nil
	local receipt_rejections = {}
	local last_receipt_sequence = nil
	local counters = { decisions = 0, rejected = 0, errors = 0, terminal = 0 }
	-- Sampled state-edge diagnostic (never inbound evidence). Read-only.
	local state_edges = { enemy_disconnected = 0, reconnecting = 0, stop_game = 0 }
	local state_edge_sample = nil
	-- Actual inbound event counts, fed only by the source-pinned staging dispatch
	-- observer through the bounded `AISP_INBOUND_TAP` bridge. The staged human
	-- runtime installs the tap; the AI runtime leaves it nil. One count per really
	-- parsed inbound action the observer passes (never a payload).
	local inbound_events = { enemyDisconnected = 0, reconnecting = 0, stopGame = 0 }
	-- Bounded total of every parsed action string the tap observed (including
	-- innocuous ones such as keepAlive), so native evidence can show the observer
	-- was alive and progressing even when the disruptive counts stay zero. No
	-- action name other than the three counters is ever stored or exported.
	local inbound_seen_total = 0
	local inbound_tap = nil
	local last_retained_snapshot_at = nil
	local inbound = {}
	local inbound_count = 0
	-- Bounded vanilla unlock-notification dismissal bookkeeping. `unlock_blocking`
	-- continuity is tracked separately so an overlay that never clears is a clean
	-- stop; the clock is cleared on human-grace ticks. Diagnostic-only
	-- otherwise: never counts toward update_errors.
	local unlock_dismissals = 0
	local unlock_attempts = 0
	local last_unlock_attempt_at = nil
	local unlock_cap_logged = false
	local unlock_attempt_cap_logged = false
	local unlock_refusal_logged = {}
	local unlock_block_since = nil
	local human_unlock_overlay = nil
	local human_unlock_since = nil
	-- Set when a human grace first runs out unattended; later popups (the rest
	-- of an unattended chain) are then dismissed promptly, so N popups never
	-- cost N graces. Popups the human closes themselves each keep their grace.
	local human_grace_done = false

	local function record_error(code)
		counters.errors = counters.errors + 1
		last_error = token_of(code, 64) or CODE.INTERNAL
		if logger ~= nil then
			pcall(logger.record, { event = "runtime_bootstrap", code = last_error, role = role })
		end
		return last_error
	end

	-- Saturating bound shared by every diagnostic counter (wire integer ceiling).
	local function saturate(value)
		local limit = RuntimeBootstrap.LIMITS.max_sequence
		if value > limit then
			return limit
		end
		return value
	end

	-- True only for a real finite number (rejects NaN and +/-infinity), so a
	-- nonfinite clock can never be serialized as a timestamp or poison the
	-- retained-snapshot cadence.
	local function finite_number(value)
		return type(value) == "number" and value == value and value > -math.huge and value < math.huge
	end

	-- Sampled state-edge diagnostic. Honest name: it counts observed *state*
	-- transitions, never actual inbound messages. Never used as acceptance
	-- evidence (the staging dispatch observer's `inbound_events` is).
	local function note_state_edge(key)
		local value = saturate(state_edges[key] + 1)
		state_edges[key] = value
		if logger ~= nil then
			pcall(logger.record, { event = "mp_state_edge", code = key, count = value })
		end
	end

	-- Actual inbound event counting, fed ONLY by the source-pinned staging
	-- dispatch observer. The observer reads the fixed global
	-- `RuntimeBootstrap.INBOUND_TAP_NAME` (`AISP_INBOUND_TAP`) before its own
	-- handler lookup and calls it with the single parsed action name (never a
	-- payload). The tap counts the bounded *total* of every parsed action string
	-- (so keepAlive and other ordinary traffic prove the observer is alive) and
	-- the three exact disruptive actions, each with a saturating bound. It stores
	-- no name other than the three counters and returns nothing, so the original
	-- decode/dispatch/handler/returns are untouched. Installed for the staged
	-- human runtime only; the AI runtime leaves the global nil.
	local function note_inbound_event(action)
		local value = saturate(inbound_events[action] + 1)
		inbound_events[action] = value
		if logger ~= nil then
			pcall(logger.record, { event = "mp_inbound_event", code = action, count = value })
		end
	end

	-- Bracketed snapshot through the trusted logger bridge. Each counter is its
	-- own bounded record using only existing allowlisted logger fields
	-- (`action`/`count`/`phase`/`seconds`/`status`), so the production logger
	-- (and the real core-shaped bridge) never drops a value. The observer record
	-- carries its alive fact and the bounded total observed count.
	local function log_inbound_snapshot(reason, at)
		if logger == nil then
			return
		end
		local phase = token_of(reason, 32) or "snapshot"
		local seconds = nil
		if finite_number(at) then
			seconds = at
		end
		-- Owned identity is the actual callback equality, never merely a saved
		-- nonnil slot: a displaced global must not read as alive.
		local owned = inbound_tap ~= nil and AISP_INBOUND_TAP == inbound_tap
		local status
		if owned then
			status = inbound_seen_total > 0 and "alive" or "installed"
		elseif inbound_tap ~= nil then
			status = "displaced"
		else
			status = "absent"
		end
		pcall(logger.record, {
			event = "mp_inbound_snapshot",
			phase = phase,
			action = "observer",
			status = status,
			count = inbound_seen_total,
			seconds = seconds,
		})
		for i = 1, #RuntimeBootstrap.INBOUND_EVENT_NAMES do
			local name = RuntimeBootstrap.INBOUND_EVENT_NAMES[i]
			pcall(logger.record, {
				event = "mp_inbound_snapshot",
				phase = phase,
				action = name,
				count = inbound_events[name],
				seconds = seconds,
			})
		end
	end

	local function install_inbound_tap()
		if role ~= "human" then
			return
		end
		local function tap(action)
			if type(action) ~= "string" or action == "" then
				return
			end
			inbound_seen_total = saturate(inbound_seen_total + 1)
			if inbound_events[action] ~= nil then
				note_inbound_event(action)
			end
		end
		AISP_INBOUND_TAP = tap
		inbound_tap = tap
	end

	local function clear_inbound_tap()
		if inbound_tap ~= nil and AISP_INBOUND_TAP == inbound_tap then
			AISP_INBOUND_TAP = nil
		end
		inbound_tap = nil
	end

	-- Diagnostic only (no control effect): why the bounded pre-start coordinator
	-- is currently waiting, logged once per change so a stalled start is
	-- explainable from the role's own log. Reasons are fixed tokens; the detail
	-- is a short bounded string of engine enums, never a card/seed/credential.
	local last_wait = nil
	local last_wait_at = nil
	local function wait_clock()
		local ok, value = pcall(clock.now)
		if ok and type(value) == "number" and value == value then
			return value
		end
		return nil
	end
	-- Logged when the reason changes, or at most every 10 s while the same
	-- reason persists (the detail carries advancing engine clocks, so a plain
	-- detail-change dedupe would log every frame).
	local function note_wait(reason, detail)
		if type(detail) ~= "string" then
			detail = nil
		end
		local at = wait_clock()
		if reason == last_wait and (at == nil or last_wait_at == nil or at - last_wait_at < 10) then
			return
		end
		last_wait = reason
		last_wait_at = at
		if logger ~= nil then
			pcall(function()
				logger.record({
					event = "coordinator_wait",
					code = token_of(reason, 64),
					detail = detail ~= nil and string.sub(detail, 1, 96) or nil,
				})
			end)
		end
	end

	-- Compact engine snapshot for menu waits: stage/state, menu UI, pause,
	-- overlay, game-time (TOTAL) and real-time (REAL) clocks and the base event
	-- queue length. Engine enums/numbers only.
	local function menu_detail()
		local ok, value = pcall(function()
			local timers = rget(G, "TIMERS")
			local function num(v)
				if type(v) == "number" then
					return string.format("%.1f", v)
				end
				return "nil"
			end
			local queue = rget(rget(rget(G, "E_MANAGER"), "queues"), "base")
			local qn = type(queue) == "table" and #queue or -1
			return "st=" .. tostring(rget(G, "STAGE")) .. "/" .. tostring(rget(G, "STATE"))
				.. " ui=" .. (rget(G, "MAIN_MENU_UI") ~= nil and 1 or 0)
				.. " p=" .. (rget(rget(G, "SETTINGS"), "paused") == true and 1 or 0)
				.. " ov=" .. (rget(G, "OVERLAY_MENU") ~= nil and 1 or 0)
				.. " T=" .. num(rget(timers, "TOTAL")) .. " R=" .. num(rget(timers, "REAL"))
				.. " q=" .. tostring(qn)
		end)
		return ok and value or nil
	end

	local function now()
		local ok, value = pcall(clock.now)
		if not ok or type(value) ~= "number" or value ~= value then
			return nil
		end
		return value
	end


	-- 1 + 2 + 3: provenance.
	function instance.validate()
		if role ~= "human" and role ~= "ai" then
			return nil, CODE.NOT_STAGED
		end
		if session == nil or credential == nil or nonce == nil or content_hash == nil then
			return nil, CODE.BAD_TOKEN
		end
		if type(control_port) ~= "number" or not is_int(control_port) or control_port < 1 or control_port > 65535 then
			return nil, CODE.BAD_PORT
		end
		if not is_plain(expected)
			or not is_plain(env)
			or type(rawget(env, "save_dir")) ~= "function"
			or type(rawget(env, "mods_root")) ~= "function"
			or type(rawget(env, "mod_root")) ~= "function" then
			return nil, CODE.ENV_UNAVAILABLE
		end
		local expected_save = normalize_path(rawget(expected, "save_dir"))
		local expected_mods = normalize_path(rawget(expected, "mods_root"))
		local expected_mod = normalize_path(rawget(expected, "mod_root"))
		if expected_save == nil or expected_mods == nil or expected_mod == nil then
			return nil, CODE.ENV_UNAVAILABLE
		end
		local ok_save, actual_save = pcall(env.save_dir)
		local ok_mods, actual_mods = pcall(env.mods_root)
		local ok_mod, actual_mod = pcall(env.mod_root)
		if not ok_save or not ok_mods or not ok_mod then
			return nil, CODE.ENV_UNAVAILABLE
		end
		local norm_save = normalize_path(actual_save)
		local norm_mods = normalize_path(actual_mods)
		local norm_mod = normalize_path(actual_mod)
		if norm_save == nil or norm_mods == nil or norm_mod == nil then
			return nil, CODE.ENV_MISMATCH
		end
		if norm_save ~= expected_save or norm_mods ~= expected_mods or norm_mod ~= expected_mod then
			return nil, CODE.ENV_MISMATCH
		end
		if not under(norm_mods, norm_mod) then
			return nil, CODE.ENV_MISMATCH
		end
		if basename(norm_mod) ~= "aisparring" then
			return nil, CODE.ENV_MISMATCH
		end
		if not is_plain(launcher) or type(rawget(launcher, "verify")) ~= "function" then
			return nil, CODE.LAUNCHER_UNVERIFIED
		end
		local ok_verify, verdict = pcall(launcher.verify)
		if not ok_verify or type(verdict) ~= "table" or rawget(verdict, "ok") ~= true then
			return nil, CODE.LAUNCHER_UNVERIFIED
		end
		if rawget(verdict, "nonce") ~= nonce
			or rawget(verdict, "session") ~= session
			or rawget(verdict, "role") ~= role
			or rawget(verdict, "content_hash") ~= content_hash
			or rawget(verdict, "control_port") ~= control_port then
			return nil, CODE.LAUNCHER_UNVERIFIED
		end
		return true, CODE.OK
	end

	-- Resolve a channel method from a trusted injected port. A real LÖVE Channel
	-- from `love.thread.getChannel` is userdata whose `push`/`pop` live on the
	-- metatable, so the check must use protected normal indexing rather than
	-- `rawget`; a plain-table channel (fixtures) still works. A non-function or
	-- throwing lookup is rejected, so this never exposes an arbitrary callable.
	local function channel_has(value, name)
		local kind = type(value)
		if kind ~= "table" and kind ~= "userdata" then
			return false
		end
		local ok, method = pcall(function()
			return value[name]
		end)
		return ok and type(method) == "function"
	end

	local function build_channels()
		if is_plain(channels_port)
			and channel_has(rawget(channels_port, "to_worker"), "push")
			and channel_has(rawget(channels_port, "from_worker"), "pop") then
			return channels_port
		end
		local names, name_code = control_thread.channel_names(nonce, role)
		if names == nil then
			return nil, name_code or CODE.BAD_CHANNELS
		end
		if type(get_channel) ~= "function" then
			return nil, CODE.BAD_CHANNELS
		end
		local ok_a, to_worker = pcall(get_channel, names.to_worker)
		local ok_b, from_worker = pcall(get_channel, names.from_worker)
		if not ok_a or not ok_b or to_worker == nil or from_worker == nil
			or not channel_has(to_worker, "push") or not channel_has(from_worker, "pop") then
			return nil, CODE.BAD_CHANNELS
		end
		return { to_worker = to_worker, from_worker = from_worker }
	end

	local function spawn()
		if type(spawn_thread) == "function" then
			local ok, spawned = pcall(spawn_thread, control_port, channels.to_worker, channels.from_worker)
			if not ok or spawned == nil or spawned == false then
				return nil, CODE.NO_THREAD
			end
			return spawned, CODE.OK
		end
		if type(love_thread) ~= "table" then
			return nil, CODE.NO_THREAD
		end
		local names = control_thread.channel_names(nonce, role)
		if names == nil then
			return nil, CODE.BAD_CHANNELS
		end
		local thread_handle, thread_code = control_thread.start(love_thread, control_port, names.to_worker, names.from_worker)
		if thread_handle == nil then
			return nil, thread_code or CODE.NO_THREAD
		end
		return thread_handle, CODE.OK
	end

	local function notify(level, message)
		if type(ui_notify) == "function" then
			pcall(ui_notify, level, message)
		end
	end

	-- Only the service's terminal-result vocabulary may leave the runtime. The
	-- terminal signal is LOCAL to this runtime's engine, so the mapping must be
	-- role-aware: the human's local win is the human's win and the human's local
	-- lives are `human_lives`; the AI's are the inverse. The service trusts the
	-- human END, so a role-blind mapping would reverse the winner and the life
	-- totals.
	local RESULT_WIRE = {
		human = {
			win = "human_win",
			loss = "ai_win",
			draw = "draw",
			aborted = "aborted",
			unknown = "unknown",
		},
		ai = {
			win = "ai_win",
			loss = "human_win",
			draw = "draw",
			aborted = "aborted",
			unknown = "unknown",
		},
	}

	local function report_summary(result)
		if transport == nil then
			return
		end
		local bounded = token_of(result, 32) or "unknown"
		local wire = RESULT_WIRE[role] or RESULT_WIRE.ai
		-- Versioned receipt-counter semantics (H3): `rejected` counts a refused
		-- decision once per delivered sequence (the existing receipt allowlist),
		-- never idle update frames. The wait/backoff classes are reported
		-- separately so they can never be mis-read as refused choices. Historical
		-- `ai_rejected` totals counted idle ticks and are not comparable; a
		-- consumer that wants the old magnitude must look at the loop_* fields.
		local loop_stats = nil
		if loop ~= nil then
			local ok_stats, value = pcall(loop.stats)
			if ok_stats and type(value) == "table" then
				loop_stats = value
			end
		end
		-- Every summary counter is saturated at the wire ceiling so a very large
		-- metric can never cause the service to refuse the whole END frame. The
		-- incoming bounds are unchanged.
		local function clamp_metric(value)
			if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < 0 then
				return 0
			end
			if value > RuntimeBootstrap.LIMITS.max_sequence then
				return RuntimeBootstrap.LIMITS.max_sequence
			end
			return value
		end
		local function loop_metric(key)
			if loop_stats == nil then
				return 0
			end
			return clamp_metric(rget(loop_stats, key))
		end
		local summary = {
			result = wire[bounded] or "unknown",
			human_lives = nil,
			ai_lives = nil,
			ante = nil,
			round = nil,
			decisions = clamp_metric(counters.decisions),
			rejected = clamp_metric(counters.rejected),
			errors = clamp_metric(counters.errors),
			counter_version = 2,
			loop_idle = loop_metric("idle"),
			loop_transient = loop_metric("transient"),
			loop_empty = loop_metric("empty"),
			loop_no_action = loop_metric("no_action"),
			loop_waits = loop_metric("waits"),
		}
		if type(MP) == "table" then
			local local_lives = rget(rget(MP, "GAME"), "lives")
			local enemy_lives = rget(rget(rget(MP, "GAME"), "enemy"), "lives")
			if role == "human" then
				summary.human_lives = local_lives
				summary.ai_lives = enemy_lives
			else
				summary.ai_lives = local_lives
				summary.human_lives = enemy_lives
			end
		end
		if type(G) == "table" then
			summary.round = rget(rget(G, "GAME"), "round")
			summary.ante = rget(rget(rget(G, "GAME"), "round_resets"), "ante")
		end
		last_summary = summary
		co_send(protocol.OPS.END, summary)
	end

	-- Private log bridge: forwards bounded decision records to the trusted
	-- logger and reports committed results to the service status op, throttled.
	local function decision_logger()
		if type(logger) ~= "table" then
			return nil
		end
		return {
			record = function(fields)
				pcall(logger.record, fields)
			end,
		}
	end

	local function push_inbound(response)
		if inbound_count >= 16 then
			return
		end
		inbound_count = inbound_count + 1
		inbound[inbound_count] = response
	end

	local function take_inbound()
		if inbound_count == 0 then
			return nil
		end
		local response = inbound[1]
		for i = 1, inbound_count - 1 do
			inbound[i] = inbound[i + 1]
		end
		inbound[inbound_count] = nil
		inbound_count = inbound_count - 1
		return response
	end

	local function ensure_driver(driver_role)
		if mp_driver ~= nil then
			return mp_driver
		end
		if type(modules) ~= "table" then
			return nil, CODE.BAD_MODULES
		end
		local MPDriver = rawget(modules, "MPDriver")
		if type(MPDriver) ~= "table" or type(rawget(MPDriver, "factory")) ~= "function" then
			return nil, CODE.BAD_MODULES
		end
		-- Source-derived allowlist/digest need the real Codec.hash_string; the
		-- ready element lookup needs the real G (never a fabricated button).
		local codec = type(modules) == "table" and rawget(modules, "codec") or nil
		local hash_string = nil
		if type(codec) == "table" and type(rawget(codec, "hash_string")) == "function" then
			hash_string = function(text)
				return codec.hash_string(text)
			end
		end
		local driver = MPDriver.factory({
			role = driver_role,
			mp = MP,
			funcs = funcs,
			G = G,
			element_for = element_for,
			clock = clock,
			logger = logger,
			client = rawget(ports, "client"),
			hash_string = hash_string,
			-- The typed canonical parity module for the Ranked contract; absent
			-- on the legacy Major League path.
			ranked_config = type(modules) == "table" and rawget(modules, "ranked_config") or nil,
			-- Registry selection: production uses the driver default (Standard
			-- Ranked); a legacy fixture may name the Major League registry.
			ruleset_key = rawget(ports, "ruleset_key"),
			ruleset_short = rawget(ports, "ruleset_short"),
			-- Real readiness producers supplied by the entrypoint (release mode)
			-- and the deployment slice (approved inventory); an explicit fixture
			-- override is available to tests only.
			release_mode = rawget(ports, "release_mode"),
			approved_mods = rawget(ports, "approved_mods"),
			ranked_profile_facts = rawget(ports, "ranked_profile_facts"),
			readiness_override = rawget(ports, "readiness_override"),
		})
		if driver == nil then
			return nil, CODE.BAD_MODULES
		end
		-- Both staged roles get the real Client.send allowlist before any lobby
		-- create/join: the human host must also never emit ranked/server or
		-- end-game/private sends in a local practice match. The allowlist keeps
		-- ordinary MP coordination and the required timer/life penalties, and
		-- only this staged path installs it (the normal/live lazy path never
		-- reaches this bootstrap). A stage that cannot install it aborts before
		-- create/join.
		local uninstaller = driver.install_send_guard()
		if type(uninstaller) ~= "function" then
			return nil, CODE.GUARD_FAILED
		end
		uninstall_guard = uninstaller
		mp_driver = driver
		return driver
	end

	local function activate()
		if role ~= "ai" then
			return nil, CODE.WRONG_ROLE
		end
		if handshake ~= "acked" then
			return nil, CODE.NOT_ARMED
		end
		if activated then
			return true, CODE.OK
		end
		if type(modules) ~= "table" then
			return nil, CODE.BAD_MODULES
		end
		local codec = rawget(modules, "codec")
		local observation = rawget(modules, "observation")
		local actions = rawget(modules, "actions")
		local StateReader = rawget(modules, "StateReader")
		local EngineAdapter = rawget(modules, "EngineAdapter")
		local ProductionExecutor = rawget(modules, "ProductionExecutor")
		local StateRevision = rawget(modules, "StateRevision")
		local ActionBroker = rawget(modules, "ActionBroker")
		local DecisionLoop = rawget(modules, "DecisionLoop")
		local MPDriver = rawget(modules, "MPDriver")
		if type(codec) ~= "table"
			or type(observation) ~= "table"
			or type(actions) ~= "table"
			or type(StateReader) ~= "table"
			or type(EngineAdapter) ~= "table"
			or type(ProductionExecutor) ~= "table"
			or type(StateRevision) ~= "table"
			or type(ActionBroker) ~= "table"
			or type(DecisionLoop) ~= "table"
			or type(MPDriver) ~= "table" then
			return nil, CODE.BAD_MODULES
		end
		if type(G) ~= "table" or type(MP) ~= "table" then
			return nil, CODE.BAD_MODULES
		end

		local obs = observation.factory(codec)
		local actions_handle = actions.factory(obs, codec)
		if rawget(actions_handle, "generate") == nil or rawget(actions_handle, "validate") == nil then
			return nil, CODE.BAD_MODULES
		end
		revision = StateRevision.factory()
		if revision == nil then
			return nil, CODE.ACTIVATE_FAILED
		end
		local target_selection = nil
		if type(rawget(ports, "target_selection")) == "function" then
			target_selection = rawget(ports, "target_selection")
		end
		adapter = EngineAdapter.factory({
			role = RuntimeBootstrap.ROLE_AI,
			session = session,
			codec = codec,
			revision = revision,
			G = G,
			MP = MP,
			target_selection = target_selection,
		})
		if adapter == nil then
			return nil, CODE.ACTIVATE_FAILED
		end
		reader = StateReader.factory(obs)
		if reader == nil then
			return nil, CODE.ACTIVATE_FAILED
		end
		executor = ProductionExecutor.factory({
			role = RuntimeBootstrap.ROLE_AI,
			session = session,
			adapter = adapter,
			reader = reader,
			revision = revision,
			G = G,
			MP = MP,
			element_for = element_for,
			clock = clock,
			stall_timeout = stall_timeout,
			-- L4: the same trusted logger the decision loop records to, so a
			-- targeted Tarot use logs bounded, safe outcome/highlight diagnostics
			-- alongside the Python decision records; no sequence id is emitted.
			logger = decision_logger(),
		})
		if executor == nil then
			return nil, CODE.ACTIVATE_FAILED
		end

		-- The capability is minted here, AFTER validation + hello ack, and the
		-- verifier binds the exact executor ports table plus the exact minted
		-- capability. It is never serialized and never leaves this closure.
		local bound_ports = executor.broker_ports()
		if type(bound_ports) ~= "table" then
			return nil, CODE.ACTIVATE_FAILED
		end
		authority = ActionBroker.production_factory(function(candidate_ports, candidate_capability)
			if not rawequal(candidate_ports, bound_ports) then
				return false
			end
			if not rawequal(candidate_capability, capability) then
				return false
			end
			if rawget(candidate_ports, "fixture") ~= nil then
				return false
			end
			return true
		end)
		if authority == nil then
			return nil, CODE.ACTIVATE_FAILED
		end
		capability = authority.mint()
		broker = authority.authorize(obs, actions_handle, bound_ports, capability)
		if broker == nil then
			return nil, CODE.ACTIVATE_FAILED
		end

		decision_transport = {
			request = function(payload)
				return transport.request(payload)
			end,
			poll = function()
				return transport.poll_decision()
			end,
			cancel = function(request_id)
				return transport.cancel(request_id)
			end,
		}
		local controls = {
			next = function()
				return executor.last_control_state()
			end,
			advance = function()
				local ok, code = executor.advance_ui()
				if ok == true then
					return true
				end
				return nil, code
			end,
		}
		-- H2: Normal installs a trusted pre-capture readiness/phase probe and the
		-- per-phase thinking dwell, but only when the trusted caller supplies the
		-- dwell table (`ports.dwell`, production companion host). A caller that
		-- does not (legacy fixtures) keeps the byte-for-byte immediate path.
		-- Instant supplies no dwell either. Post-response pacing is 0 in every
		-- case. The probe reads only the adapter's pure engine-symbol/own-timer
		-- view: no handle, no canonical content, no opponent data, and it is
		-- never policy input.
		local readiness_probe = nil
		local dwell_config = nil
		if pacing == "normal" and is_plain(dwell_port) then
			dwell_config = dwell_port
			readiness_probe = function()
				if adapter == nil or type(adapter.probe) ~= "function" then
					return nil
				end
				local ok, value = pcall(adapter.probe)
				if not ok then
					return nil
				end
				return value
			end
		end
		loop = DecisionLoop.factory({
			broker = broker,
			transport = decision_transport,
			clock = clock,
			logger = decision_logger(),
			controls = controls,
			-- Production post-response pacing is always 0: the thinking time is
			-- the pre-capture dwell below, never a delayed submit of a held token.
			pacing = 0,
			pacing_mode = pacing,
			readiness = readiness_probe,
			dwell = dwell_config,
			min_interval = 0,
			timeout = loop_timeout,
			terminal_phase = "MATCH_COMPLETE",
			sequence_start = decision_base,
			-- N5/L5: the loop's post-decision revision and its trusted wait probe
			-- are the runtime's real public state, never inferred from a global.
			get_revision = function()
				return revision.current()
			end,
			wait_state = function()
				return RuntimeBootstrap.mp_wait_state(MP, G)
			end,
			on_stop = function(reason)
				pending_stop = token_of(reason, RuntimeBootstrap.LIMITS.max_reason) or "stopped"
			end,
		})
		if loop == nil then
			return nil, CODE.ACTIVATE_FAILED
		end
		-- Receipt logging is limited to the loop's own stable rejection codes,
		-- and only when a real decision was delivered for that sequence.
		receipt_rejections = {}
		for _, key in ipairs({ "STALE", "DISPATCH_FAILED", "RESPONSE_REJECTED" }) do
			local value = rawget(rawget(loop, "CODE"), key)
			if type(value) == "string" then
				receipt_rejections[value] = true
			end
		end
		remove_hooks = install_hooks(rawget(ports, "hook_targets"), revision)
		local driver, driver_code = ensure_driver("ai")
		if driver == nil then
			return nil, driver_code or CODE.ACTIVATE_FAILED
		end

		activated = true
		state = "active"
		return true, CODE.OK
	end

	local function handle_terminal()
		if type(terminal_probe) == "function" then
			local ok, value = pcall(terminal_probe)
			if ok and value ~= nil then
				return token_of(value, 32)
			end
		end
		if type(MP) == "table" and rget(rget(MP, "GAME"), "won") == true then
			return "win"
		end
		if type(G) == "table" then
			local states = rget(G, "STATES")
			local state_value = rget(G, "STATE")
			local game_over = rget(states, "GAME_OVER")
			if is_int(state_value) and is_int(game_over) and state_value == game_over then
				return "loss"
			end
		end
		return nil
	end

	local function heartbeat(current)
		if transport == nil then
			return
		end
		if last_heartbeat ~= nil and current - last_heartbeat < RuntimeBootstrap.LIMITS.heartbeat_interval then
			return
		end
		last_heartbeat = current
		-- The service `heartbeat` op accepts only an optional bounded `tick`.
		co_send(protocol.OPS.HEARTBEAT, { tick = counters.decisions })
	end

	-- Coordination send: the transport records the pushed frame in its ordered
	-- outstanding list and tags the matching reply with this op.
	co_send = function(op, payload)
		if transport == nil then
			return nil, CODE.BAD_TRANSPORT
		end
		local id, code = transport.send(op, payload)
		if id == nil then
			return nil, code
		end
		return id, code
	end

	local function coord_ready(current)
		if last_coord_at ~= nil and current - last_coord_at < coord_retry_interval then
			return false
		end
		last_coord_at = current
		return true
	end

	-- A bounded digest over the live forced ruleset config, using the trusted
	-- SETUP ruleset id/gamemode and, for the guest, the service keyset; the host
	-- additionally verifies its locally recorded keyset matches it exactly.
	local function compute_digest()
		if mp_driver == nil or setup_info == nil then
			return nil
		end
		-- The versioned Ranked contract reads the actual live configuration,
		-- layers and timers itself; it never echoes a service-provided expected
		-- digest. An unknown schema fails closed.
		if setup_info.config_schema ~= nil then
			if setup_info.config_schema ~= RuntimeBootstrap.RANKED_CONFIG_SCHEMA then
				return nil
			end
			local value = mp_driver.ranked_config_digest()
			return value
		end
		local keys = setup_info.forced_options
		if role == "human" then
			local recorded = mp_driver.forced_keys()
			if recorded == nil or keys == nil or #recorded ~= #keys then
				return nil
			end
			local seen = {}
			for i = 1, #recorded do
				seen[recorded[i]] = true
			end
			for i = 1, #keys do
				if seen[keys[i]] ~= true then
					return nil
				end
			end
		end
		local value = mp_driver.config_digest(setup_info.ruleset_id, setup_info.gamemode, keys)
		return value
	end

	-- B4: the READY digest is retained and re-checked before any readiness or
	-- start commit. The runtime always recomputes from the actual config; a
	-- missing or changed value is a config mismatch, never an echoed expected
	-- checksum.
	local function recheck_digest()
		if ready_digest == nil then
			return false
		end
		local current = compute_digest()
		return current ~= nil and current == ready_digest
	end

	-- The dedicated draft commitment digest is re-derived from the bounded public
	-- transcript before READY, before the ready/start actuators and before the
	-- host start commit. It is never echoed from the service.
	local function recheck_draft()
		if setup_info == nil or setup_info.draft_digest == nil then
			return true
		end
		local parity = type(modules) == "table" and rawget(modules, "ranked_config") or nil
		if type(parity) ~= "table" or type(rawget(parity, "validate_draft")) ~= "function" then
			return false
		end
		local derived = parity.validate_draft(setup_info.draft)
		return derived ~= nil and derived == setup_info.draft_digest
	end

	-- The real readiness record (primitives only). Absent producer or malformed
	-- record fails the Ranked readiness gate.
	local function compute_readiness()
		if mp_driver == nil or type(mp_driver.readiness_facts) ~= "function" then
			return nil
		end
		local facts = mp_driver.readiness_facts()
		if type(facts) ~= "table" then
			return nil
		end
		-- Withhold READY unless every reviewed fact is exactly true.
		if type(mp_driver.readiness_ok) ~= "function" or mp_driver.readiness_ok() ~= true then
			return nil
		end
		return facts
	end

	-- Route one coordination response to the op that produced it. Only
	-- `coord_failure` (a fatal protocol/config mismatch) stops the boot.
	local function handle_coordination(op, response)
		local code = rawget(response, "code")
		-- A service abort/close/end (or the explicit pre-start timeout) is fatal
		-- for the whole pre-start coordinator: it can never complete, so stop now
		-- instead of waiting for the overall deadline.
		if code == protocol.CODES.ABORTED or code == protocol.CODES.CLOSED
			or code == protocol.CODES.ENDED or code == protocol.CODES.PRESTART_TIMEOUT then
			coord_failure = token_of(code, RuntimeBootstrap.LIMITS.max_reason) or CODE.COORD_TIMEOUT
			return
		end
		-- Heartbeats carry the service's own `aborted` flag. A service that has
		-- aborted its pre-start window will never complete, so stop.
		if op == protocol.OPS.HEARTBEAT then
			if rawget(response, "aborted") == true then
				coord_failure = protocol.CODES.ABORTED
			end
			return
		end
		if op == protocol.OPS.HELLO then
			if response.ok == true then
				hello_acked = true
				handshake = "acked"
				-- Defense in depth: a terminal runtime is never re-armed by any
				-- coordinator reply (terminal drain never routes here anyway).
				if state ~= "terminal" then
					state = "armed"
				end
			elseif code == protocol.CODES.NOT_ATTESTED then
				-- The launcher host attests after both probes; re-send hello on
				-- the next bounded retry. The sequence is not consumed on a
				-- not-attested rejection, so a fresh one is safe.
				handshake = "sent"
				handshake_retry_at = nil
			elseif response.ok == false then
				coord_failure = CODE.HELLO_REJECTED
			end
			return
		end
		if op == protocol.OPS.SETUP then
			if response.ok ~= true then
				if code == protocol.CODES.NOT_ATTESTED then
					setup_sent = false
				else
					coord_failure = token_of(code, RuntimeBootstrap.LIMITS.max_reason) or CODE.SETUP_FAILED
				end
				return
			end
			local ruleset_id = rawget(response, "ruleset_id")
			local gamemode = rawget(response, "gamemode")
			local forced = rawget(response, "forced_options")
			local config_schema = rawget(response, "config_schema")
			-- A driver configured for Standard Ranked must never accept a
			-- schema-less SETUP and fall back to the legacy Major League digest
			-- path. Only an explicit legacy registry driver may do that.
			local driver_ranked = mp_driver ~= nil
				and type(mp_driver.ruleset_key_value) == "function"
				and mp_driver.ruleset_key_value() == RuntimeBootstrap.RANKED_RULESET_ID
			if driver_ranked and config_schema ~= RuntimeBootstrap.RANKED_CONFIG_SCHEMA then
				coord_failure = CODE.CONFIG_MISMATCH
				return
			end
			if config_schema ~= nil then
				if type(config_schema) ~= "string" then
					coord_failure = CODE.SETUP_FAILED
					return
				end
				-- Only the reviewed versioned schema is accepted; an unknown
				-- version fails closed rather than being treated as legacy.
				if config_schema ~= RuntimeBootstrap.RANKED_CONFIG_SCHEMA then
					coord_failure = CODE.CONFIG_MISMATCH
					return
				end
				-- The Ranked contract needs the shared typed parity module. A
				-- missing driver/module is an immediate module fault, never a
				-- bounded readiness wait that only times out.
				if mp_driver == nil
					or type(mp_driver.has_ranked_config) ~= "function"
					or mp_driver.has_ranked_config() ~= true then
					coord_failure = CODE.BAD_MODULES
					return
				end
			end
			if type(ruleset_id) ~= "string" or type(gamemode) ~= "string"
				or type(forced) ~= "table" then
				coord_failure = CODE.SETUP_FAILED
				return
			end
			-- Under the Ranked schema the SETUP ruleset id must match the driver's
			-- configured registry key; a legacy id cannot be relabelled as Ranked.
			if config_schema ~= nil then
				if type(mp_driver.ruleset_key_value) ~= "function"
					or ruleset_id ~= mp_driver.ruleset_key_value() then
					coord_failure = CODE.CONFIG_MISMATCH
					return
				end
			end
			-- The legacy Major League path carries a non-empty forced-keyset; the
			-- Ranked path carries no keyset and reads the actual layered config.
			if #forced == 0 and config_schema == nil then
				coord_failure = CODE.SETUP_FAILED
				return
			end
			if rawget(response, "role") ~= role
				or rawget(response, "difficulty") ~= difficulty
				or rawget(response, "mode") ~= mode
				or rawget(response, "pacing") ~= pacing then
				coord_failure = CODE.CONFIG_MISMATCH
				return
			end
			local keys = {}
			for i = 1, #forced do
				if type(forced[i]) ~= "string" then
					coord_failure = CODE.SETUP_FAILED
					return
				end
				keys[i] = forced[i]
			end
			local selection = rawget(response, "selection")
			if selection ~= nil and type(selection) ~= "table" then
				coord_failure = CODE.SETUP_FAILED
				return
			end
			local draft = rawget(response, "draft")
			local draft_digest = nil
			-- Under the Ranked schema a validated selection is mandatory with
			-- exact keys/types; the expected deck/stake come only from it.
			if config_schema ~= nil then
				local parity = type(modules) == "table" and rawget(modules, "ranked_config") or nil
				if type(parity) ~= "table" or type(rawget(parity, "selection_valid")) ~= "function" then
					coord_failure = CODE.BAD_MODULES
					return
				end
				local valid, valid_code = parity.selection_valid(selection)
				if valid ~= true then
					coord_failure = CODE.SETUP_FAILED
					return
				end
				-- A completed host-owned draft commitment is MANDATORY under the
				-- Ranked schema. There is no selection-only launch and no caller
				-- flag that can downgrade the requirement; the transcript is
				-- independently validated here and its digest derived (a supplied
				-- digest is never accepted as a substitute).
				if type(draft) ~= "table" or type(rawget(parity, "validate_draft")) ~= "function" then
					coord_failure = CODE.SETUP_FAILED
					return
				end
				local derived, draft_code, final = parity.validate_draft(draft)
				if derived == nil then
					coord_failure = CODE.SETUP_FAILED
					return
				end
				-- The committed final option must bind to the mandatory selection's
				-- deck/stake keys, so a transcript that disagrees can never launch.
				local final_deck, final_stake = string.match(final, "^([%w_]+)~([%w_]+)$")
				if final_deck == nil or final_deck ~= selection.deck_key
					or final_stake ~= selection.stake_key then
					coord_failure = CODE.CONFIG_MISMATCH
					return
				end
				draft_digest = derived
			elseif draft ~= nil then
				coord_failure = CODE.SETUP_FAILED
				return
			end
			setup_info = {
				ruleset_id = ruleset_id,
				gamemode = gamemode,
				forced_options = keys,
				config_schema = config_schema,
				selection = selection,
				draft = draft,
				draft_digest = draft_digest,
			}
			if role == "human" then
				local trusted = rawget(response, "gauntlet_seed")
				if trusted ~= nil then
					human_seed = token_of(trusted, RuntimeBootstrap.LIMITS.max_token)
					if human_seed == nil then
						coord_failure = CODE.SETUP_FAILED
						return
					end
				end
			end
			setup_acked = true
			return
		end
		if op == protocol.OPS.LOBBY_CODE then
			lobby_code_acked = response.ok == true
			if not lobby_code_acked then
				-- A refused lobby_code report is a bounded retry, not a stop.
				lobby_code_sent = false
			end
			return
		end
		if op == protocol.OPS.JOIN_CODE then
			if response.ok == true and type(rawget(response, "lobby_code")) == "string" then
				join_code = rawget(response, "lobby_code")
			end
			-- NO_LOBBY / not-ready are bounded waits: re-poll on the retry tick.
			return
		end
		if op == protocol.OPS.READY then
			if response.ok == true then
				ready_acked = true
			elseif code == protocol.CODES.CONFIG_MISMATCH and ready_sent then
				coord_failure = CODE.CONFIG_MISMATCH
			else
				-- NOT_READY (the other role has not reported yet) and other
				-- retryable refusals re-arm the send under the overall deadline.
				ready_sent = false
			end
			return
		end
		if op == protocol.OPS.START then
			if response.ok == true or code == protocol.CODES.ALREADY_STARTED then
				start_acked = true
			else
				start_sent = false
			end
			return
		end
	end

	-- Bounded, exactly-once start coordinator. Each service op commits once its
	-- own ack arrives; each real MP callback commits once and is only retried
	-- when it did not take effect (late UI / not-yet-ready).
	local function advance_coordinator(current)
		if mp_driver == nil then
			note_wait("driver_missing")
			return
		end
		if not setup_acked then
			note_wait(setup_sent and "setup_awaiting_ack" or "setup_unsent")
			if not setup_sent and coord_ready(current) then
				if co_send(protocol.OPS.SETUP, {}) ~= nil then
					setup_sent = true
				end
			end
			return
		end
		-- Once the lobby is joined, coordination no longer depends on the main
		-- menu: reporting the code, readying, starting and the audit seed all
		-- happen with the match stage changing underneath.
		if not mp_driver.connected() then
			note_wait("mp_not_connected")
			return
		end
		if role == "ai" and join_code ~= nil and not join_sent then
			-- `join_lobby` is a main-menu callback; wait for the real menu.
			if not mp_driver.main_menu_ready() then
				note_wait("join_menu_not_ready", menu_detail())
			elseif coord_ready(current) then
				local ok, join_code_result = mp_driver.ai_join(join_code)
				if ok == true then
					join_sent = true
					note_wait("join_sent")
				else
					note_wait("ai_join_refused", join_code_result)
				end
			end
			return
		end
		if instance.lobby_code() == nil then
			if not mp_driver.main_menu_ready() then
				note_wait("menu_not_ready", menu_detail())
				return
			end
			if coord_ready(current) then
				if role == "human" then
					-- `start_lobby` queues the server create asynchronously; send
					-- it exactly once and wait for the real code. Only an explicit
					-- callback failure re-arms the send.
					if not lobby_enter_sent then
						local entry, ruleset_code = mp_driver.ruleset()
						if entry == nil then
							note_wait("ruleset_unavailable", ruleset_code)
						else
							lobby_enter_sent = true
							note_wait("host_start_calling")
							-- The completed-draft selection is applied by the
							-- driver after the real reset and before the first
							-- lobby-options send; the legacy Major League path
							-- supplies no selection.
							local ok, host_code = mp_driver.host_start(
								human_seed, setup_info ~= nil and setup_info.selection or nil
							)
							if ok ~= true then
								-- Once the real create callback has been invoked, a
								-- failure must never re-arm: a second createLobby
								-- would orphan the first lobby and repeat the
								-- un-forced-config defect. Pre-call refusals
								-- (NO_RULESET / NO_FORCED_MODE) stay retryable.
								if host_code == mp_driver.CODE.START_LOBBY_FAILED
									or host_code == mp_driver.CODE.FORCE_FAILED then
									coord_failure = host_code
								else
									lobby_enter_sent = false
									note_wait("host_start_refused", host_code)
								end
							else
								note_wait("lobby_code_awaiting_server")
							end
						end
					end
				else
					note_wait("join_code_polling")
					co_send(protocol.OPS.JOIN_CODE, {})
				end
			end
			return
		end
		if role == "human" and not lobby_code_acked then
			note_wait("lobby_code_report_pending")
			if not lobby_code_sent and coord_ready(current) then
				if co_send(protocol.OPS.LOBBY_CODE, { lobby_code = instance.lobby_code() }) ~= nil then
					lobby_code_sent = true
				end
			end
			return
		end
		if not ready_sent then
			if coord_ready(current) then
				local digest_value = compute_digest()
				if digest_value == nil then
					note_wait("ready_digest_unavailable")
				else
					local ready_payload = { config_digest = digest_value }
					if setup_info.config_schema ~= nil then
						ready_payload.config_schema = setup_info.config_schema
						-- The independently derived draft commitment digest is
						-- bound alongside the lobby-config digest when a draft is
						-- carried.
						if setup_info.draft_digest ~= nil then
							ready_payload.draft_digest = setup_info.draft_digest
						end
						-- The Ranked contract withholds READY unless every real
						-- readiness fact is true; the record is carried as
						-- primitives only and is never part of AIObservation.
						local facts = compute_readiness()
						if facts == nil then
							note_wait("ready_readiness_unavailable")
							return
						end
						ready_payload.readiness = facts
						ready_readiness = facts
					end
					if co_send(protocol.OPS.READY, ready_payload) ~= nil then
						ready_digest = digest_value
						ready_sent = true
					end
				end
			end
			return
		end
		if not ready_acked then
			note_wait("ready_awaiting_ack")
			return
		end
		if role == "ai" then
			if not guest_ready_committed then
				if coord_ready(current) then
					-- B4: recompute the actual digest before committing ready;
					-- the draft commitment digest is re-derived too.
					if not recheck_digest() or not recheck_draft() then
						coord_failure = CODE.CONFIG_MISMATCH
						return
					end
					local ok, ready_code = mp_driver.ai_ready()
					if ok == true then
						guest_ready_committed = true
						note_wait("guest_ready_committed")
					else
						note_wait("ai_ready_refused", ready_code)
					end
				end
			end
			return
		end
		if not start_sent then
			if rpath(MP, "LOBBY", "ready_to_start") ~= true then
				note_wait("start_awaiting_guest_ready")
			end
			if rpath(MP, "LOBBY", "ready_to_start") == true and coord_ready(current) then
				-- B4: recompute the actual digest before sending START; the
				-- draft commitment digest is re-derived too.
				if not recheck_digest() or not recheck_draft() then
					coord_failure = CODE.CONFIG_MISMATCH
					return
				end
				if co_send(protocol.OPS.START, {}) ~= nil then
					start_sent = true
				end
			end
			return
		end
		if not start_acked then
			note_wait("start_awaiting_ack")
			return
		end
		if not start_committed then
			if coord_ready(current) then
				-- B4: recompute the actual digest before committing the start;
				-- the draft commitment digest is re-derived too.
				if not recheck_digest() or not recheck_draft() then
					coord_failure = CODE.CONFIG_MISMATCH
					return
				end
				local ok, start_code = mp_driver.host_start_game()
				if ok == true then
					start_committed = true
					start_committed_at = current
					note_wait("start_committed")
				else
					note_wait("start_commit_refused", start_code)
				end
			end
			return
		end
		-- Trusted audit seed: the human reports the *actual resolved* run seed
		-- once the run is initialized (`G.GAME.pseudorandom.seed`), never a menu
		-- or prior-run value. A gauntlet run must agree with the SETUP seed. The
		-- guest never reports a seed and no seed is ever exported to policy.
		if not seed_reported then
			local seed_value = mp_driver.is_started() and resolved_run_seed(G) or nil
			if seed_value ~= nil then
				if human_seed ~= nil and seed_value ~= human_seed then
					coord_failure = CODE.SEED_MISMATCH
					return
				end
				seed_reported = true
				co_send(protocol.OPS.STATUS, { seed = seed_value })
			elseif start_committed_at ~= nil
				and current - start_committed_at > RuntimeBootstrap.LIMITS.coord_timeout then
				coord_failure = CODE.SEED_TIMEOUT
			end
		end
	end

	local function coordination_done()
		return (start_committed and seed_reported) or guest_ready_committed
	end

	-- Terminal is a drain-only state: consume the owned END ack (never leave it
	-- unread in the channel), never run the loop again, and never let a missing
	-- ack hang the runtime. ONLY an END reply is acted on. Every other decoded
	-- reply -- successful HELLO/SETUP/READY/START/JOIN_CODE as well as CLOSED/
	-- ENDED/ABORTED/aborted-heartbeat -- is consumed and dropped with a bounded
	-- diagnostic: it can never re-arm, modify setup/readiness/start/seed, restart
	-- the policy, duplicate the END, or remove the MP send guard. The AI END is a
	-- receipt and never authorizes teardown on this side.
	local function drain_terminal(current)
		if transport == nil then
			return
		end
		for _ = 1, RuntimeBootstrap.LIMITS.max_coordination_per_update do
			local response = transport.poll_coordination()
			if response == nil then
				break
			end
			if rawget(response, "op") == protocol.OPS.END then
				terminal_acked = response.ok == true
			else
				terminal_drops = saturate(terminal_drops + 1)
				if terminal_drops <= RuntimeBootstrap.LIMITS.max_terminal_drops and logger ~= nil then
					pcall(logger.record, {
						event = "terminal_drop",
						count = terminal_drops,
						-- `action` is allowlisted (a bounded op token); `op` was not.
						action = token_of(rawget(response, "op"), 32),
					})
				end
			end
		end
		if not terminal_acked and terminal_sent_at ~= nil
			and current - terminal_sent_at > RuntimeBootstrap.LIMITS.coord_timeout then
			if not terminal_timeout_recorded then
				terminal_timeout_recorded = true
				record_error(CODE.TERMINAL_TIMEOUT)
			end
		end
	end

	-- Dismiss a vanilla unlock-notification overlay that is blocking a staged
	-- role, bounded and diagnostic-only. The human's popups are dismissed only
	-- BEFORE the match (once the human's match has started they belong to the
	-- human), the first one only after a grace window; the AI's are always dismissed
	-- immediately because an unattended AI can never click Continue. Returns
	-- `blocking, stopped`: `blocking` is true when an unlock overlay is still
	-- present after this tick's step, so an in-match AI never consumes a decision
	-- against a frozen or flapping overlay, and `stopped` is true when a
	-- continuously-blocking overlay passed `unlock_block_timeout` and the runtime
	-- was cleanly stopped. Bounds: one attempt per `unlock_dismiss_interval`,
	-- `max_unlock_dismissals` successes, `max_unlock_attempts` attempts and
	-- `unlock_block_timeout` of continuous blocking. Never touches update_errors.
	local function handle_unlock_overlay(current)
		if mp_driver == nil or type(mp_driver.unlock_overlay) ~= "function" then
			return false
		end
		local allowed = role == "ai"
		if not allowed and role == "human" then
			local started = false
			if type(mp_driver.is_started) == "function" then
				local ok_started, value = pcall(mp_driver.is_started)
				started = ok_started and value == true
			end
			allowed = not start_committed and not started
		end
		if not allowed then
			unlock_block_since = nil
			return false
		end
		local overlay = mp_driver.unlock_overlay()
		if overlay == nil then
			unlock_block_since = nil
			return false
		end
		-- L2: an attended human sees each pre-start unlock for the grace window
		-- (the same overlay object must stay up; a replacement restarts it) until
		-- one grace runs out unattended; from then on the rest of the chain is
		-- dismissed like the AI's. A grace never counts toward the stuck bound
		-- below: the clock is cleared while graced. The AI is never graced.
		if role == "human" and not human_grace_done then
			if not rawequal(overlay, human_unlock_overlay) then
				human_unlock_overlay = overlay
				human_unlock_since = current
			end
			if human_unlock_since == nil
				or current - human_unlock_since < RuntimeBootstrap.LIMITS.human_unlock_grace then
				unlock_block_since = nil
				return true
			end
			human_grace_done = true
		end
		-- M1: every permitted, non-graced tick with an unlock overlay up counts
		-- toward the continuous-block bound, including ticks where a cap or the
		-- rate limit prevents an attempt, so no path can gate the AI loop
		-- forever. It is a clean stop, exactly like the pre-start/hello timeouts.
		if unlock_block_since == nil then
			unlock_block_since = current
		end
		if current - unlock_block_since > RuntimeBootstrap.LIMITS.unlock_block_timeout then
			record_error(CODE.UNLOCK_STUCK)
			instance.shutdown(CODE.UNLOCK_STUCK)
			return true, true
		end
		if unlock_attempts >= RuntimeBootstrap.LIMITS.max_unlock_attempts then
			if not unlock_attempt_cap_logged then
				unlock_attempt_cap_logged = true
				if logger ~= nil then
					pcall(logger.record, { event = "unlock_attempt_cap", count = unlock_attempts })
				end
			end
			return true
		end
		if unlock_dismissals >= RuntimeBootstrap.LIMITS.max_unlock_dismissals then
			if not unlock_cap_logged then
				unlock_cap_logged = true
				if logger ~= nil then
					pcall(logger.record, { event = "unlock_dismiss_cap", count = unlock_dismissals })
				end
			end
			return true
		end
		if last_unlock_attempt_at ~= nil
			and current - last_unlock_attempt_at < RuntimeBootstrap.LIMITS.unlock_dismiss_interval then
			return true
		end
		last_unlock_attempt_at = current
		unlock_attempts = unlock_attempts + 1
		local ok, code = mp_driver.dismiss_unlock_overlay()
		if ok == true then
			unlock_dismissals = unlock_dismissals + 1
			if logger ~= nil then
				pcall(logger.record, { event = "unlock_overlay_dismissed", count = unlock_dismissals })
			end
		elseif (code == mp_driver.CODE.MISSING_CALLBACK
			or code == mp_driver.CODE.INTERNAL
			or code == mp_driver.CODE.BAD_STATE)
			and unlock_refusal_logged[code] ~= true then
			unlock_refusal_logged[code] = true
			if logger ~= nil then
				pcall(logger.record, { event = "unlock_overlay_refused", code = code, count = unlock_dismissals })
			end
		end
		-- A chained *new* popup still leaves an unlock overlay up.
		local still_blocking = mp_driver.unlock_overlay() ~= nil
		if not still_blocking then
			unlock_block_since = nil
		end
		return still_blocking
	end

	function instance.is_inert()
		return state == "inert"
	end

	function instance.state()
		return state
	end

	function instance.install()
		if installed then
			return nil, CODE.ALREADY_INSTALLED
		end
		state = "inert"
		local allowed, code = instance.validate()
		if allowed ~= true then
			record_error(code)
			return nil, code
		end
		if now() == nil then
			record_error(CODE.BAD_PORTS)
			return nil, CODE.BAD_PORTS
		end
		channels, code = build_channels()
		if channels == nil then
			record_error(code)
			return nil, code
		end
		if type(encode) ~= "function" or type(decode) ~= "function" then
			record_error(CODE.BAD_CODEC_PORTS)
			return nil, CODE.BAD_CODEC_PORTS
		end
		local built, build_code = transport_factory({
			role = role,
			session = session,
			credential = credential,
			protocol = protocol,
			channels = channels,
			clock = clock,
			encode = encode,
			decode = decode,
			logger = logger,
			decision_base = decision_base,
			poll_interval = poll_interval,
			request_timeout = transport_request_timeout,
		})
		if built == nil then
			record_error(build_code or CODE.BAD_TRANSPORT)
			return nil, build_code or CODE.BAD_TRANSPORT
		end
		transport = built
		thread, code = spawn()
		if thread == nil then
			record_error(code)
			transport = nil
			return nil, code
		end
		transport.start()
		hello_request = transport.send(protocol.OPS.HELLO, {
			version = rawget(protocol, "VERSION"),
			content_digest = content_hash,
		})
		if hello_request == nil then
			record_error(CODE.HELLO_FAILED)
			return nil, CODE.HELLO_FAILED
		end
		handshake = "sent"
		handshake_retry_at = now()
		state = "installed"
		installed = true
		installed_at = now()
		-- Install the real inbound-event tap for the staged human runtime only.
		-- The source-pinned Multiplayer dispatch observer calls it; the AI runtime
		-- leaves it nil so nothing changes for the unattended role. The installed
		-- snapshot brackets the pre-terminal window from the first moment.
		install_inbound_tap()
		log_inbound_snapshot("installed", installed_at)
		return true, CODE.OK
	end

	function instance.lobby_code()
		if mp_driver ~= nil then
			return mp_driver.lobby_code()
		end
		local code_value = rget(rget(MP, "LOBBY"), "code")
		if type(code_value) == "string" and #code_value > 0 and #code_value <= 32 then
			return code_value
		end
		return nil
	end

	-- One read-only sampled state-edge observation per update. Diagnostic only:
	-- it is not an inbound event count and is never acceptance evidence.
	local function observe_state_edges()
		if type(MP) ~= "table" then
			return
		end
		local started = false
		if mp_driver ~= nil and type(mp_driver.is_started) == "function" then
			local ok, value = pcall(mp_driver.is_started)
			started = ok and value == true
		end
		local next_sample = RuntimeBootstrap.observe_state_edges(state_edge_sample, MP, G, started)
		state_edge_sample = next_sample
		if next_sample.enemy_edge == 1 then
			note_state_edge("enemy_disconnected")
		end
		if next_sample.reconnect_edge == 1 then
			note_state_edge("reconnecting")
		end
		if next_sample.stop_edge == 1 then
			note_state_edge("stop_game")
		end
	end

	function instance.update(dt)
		if not installed then
			return "inert", CODE.OK
		end
		if state == "stopped" then
			return "stopped", CODE.STOPPED
		end
		-- Terminal is sticky: once reported, no later path may leave it.
		if terminal_reported and state ~= "terminal" then
			state = "terminal"
		end
		-- Sampled state-edge diagnostic runs on every update, including the
		-- terminal/retention drain. It is diagnostic only, never event evidence.
		observe_state_edges()
		local current = now()
		if current == nil then
			if state == "terminal" then
				return "terminal", CODE.TERMINAL
			end
			update_errors = update_errors + 1
			if update_errors >= RuntimeBootstrap.LIMITS.max_update_errors then
				instance.shutdown("clock")
				return "stopped", update_errors
			end
			return "installed", CODE.BAD_PORTS
		end
		if state == "terminal" then
			drain_terminal(current)
			-- Bounded periodic snapshot across the retained window, so a native
			-- proof can bracket the observer's live zero/again counts (never a
			-- per-frame flood).
			if
				finite_number(current)
				and (
					last_retained_snapshot_at == nil
					or current - last_retained_snapshot_at >= RuntimeBootstrap.LIMITS.retained_snapshot_interval
				)
			then
				last_retained_snapshot_at = current
				log_inbound_snapshot("retained", current)
			end
			return "terminal", CODE.TERMINAL
		end

		-- The pre-start hello/attestation wait is a bounded coordinator state,
		-- not a frame error: the launcher attests after both probes. Only the
		-- whole coordinator window is bounded.
		if handshake == "sent" and installed_at ~= nil
			and current - installed_at > RuntimeBootstrap.LIMITS.coord_timeout then
			record_error(CODE.HELLO_FAILED)
			instance.shutdown("hello_timeout")
			return "stopped", CODE.HELLO_FAILED
		end

		for _ = 1, RuntimeBootstrap.LIMITS.max_coordination_per_update do
			local response = transport.poll_coordination()
			if response == nil then
				break
			end
			local op = rawget(response, "op")
			if op == nil then
				push_inbound(response)
			else
				handle_coordination(op, response)
			end
		end
		if coord_failure ~= nil then
			local code = coord_failure
			record_error(code)
			instance.shutdown(code)
			return "stopped", code
		end

		if handshake == "acked" and role == "ai" and not activated then
			local ok_activate, activate_code = activate()
			if ok_activate ~= true then
				-- A missing send guard is a hard fault: it must never be retried
				-- into a lobby, so abort the staged boot immediately.
				if activate_code == CODE.GUARD_FAILED then
					record_error(activate_code)
					instance.shutdown(activate_code)
					return "stopped", activate_code
				end
				update_errors = update_errors + 1
				if update_errors >= RuntimeBootstrap.LIMITS.max_update_errors then
					instance.shutdown(activate_code)
					return "stopped", activate_code
				end
				return "armed", activate_code
			end
		end

		if handshake == "acked" and role == "human" and mp_driver == nil then
			local driver, driver_code = ensure_driver("human")
			if driver == nil then
				-- The send guard is required for both roles before create/join.
				local code = driver_code or CODE.GUARD_FAILED
				record_error(code)
				instance.shutdown(code)
				return "stopped", code
			end
		end

		local terminal = handle_terminal()
		if terminal ~= nil then
			counters.terminal = counters.terminal + 1
			if loop ~= nil and not loop.is_stopped() then
				loop.stop(terminal)
			end
			if not terminal_reported then
				terminal_reported = true
				terminal_sent_at = current
				-- Only a finite open time may anchor the cadence; a nonfinite clock
				-- never poisons it, so finite snapshots resume once the clock is sane.
				if finite_number(current) then
					last_retained_snapshot_at = current
				end
				log_inbound_snapshot("open", current)
				report_summary(terminal)
			end
			state = "terminal"
			-- Drain the owned END reply on later updates; never run the loop or
			-- emit further decisions/seed from here.
			drain_terminal(current)
			return "terminal", CODE.TERMINAL
		end

		-- A vanilla unlock popup (deck/card unlock) freezes an unattended role:
		-- nobody clicks Continue, so the deferred main-menu event never fires and
		-- the run can stall. Dismiss it within the staged bounds above (allowed
		-- roles only, one attempt per interval, fixed success/attempt caps, the
		-- human grace and a continuous-block timeout that is a clean stop). An
		-- in-match AI then never consumes a decision against a still-present popup.
		local unlock_blocking, unlock_stopped = false, false
		if handshake == "acked" and mp_driver ~= nil then
			unlock_blocking, unlock_stopped = handle_unlock_overlay(current)
		end
		if unlock_stopped then
			return "stopped", CODE.UNLOCK_STUCK
		end

		if handshake == "acked" then
			-- L1: never advance the coordinator under a popup. The pre-start
			-- deadline below stays OUTSIDE this gate so a stuck pre-start popup
			-- still ends in the existing clean coord timeout.
			if auto_coordinate and not unlock_blocking then
				advance_coordinator(current)
			end
			-- Overall pre-start deadline: the whole bounded coordination window
			-- (SETUP through start/seed) may not exceed the service's own
			-- pre-start window plus margin. A stall here is a clean stop, never
			-- an unbounded wait.
			if not coordination_done() and installed_at ~= nil
				and current - installed_at > RuntimeBootstrap.LIMITS.prestart_timeout then
				record_error(CODE.COORD_TIMEOUT)
				instance.shutdown("coord_timeout")
				return "stopped", CODE.COORD_TIMEOUT
			end
		elseif handshake == "sent" then
			-- Retry the hello until the attestation gate lets it through; the
			-- not-attested rejection does not consume the wire sequence.
			if handshake_retry_at == nil or current - handshake_retry_at >= coord_retry_interval then
				handshake_retry_at = current
				transport.send(protocol.OPS.HELLO, {
					version = rawget(protocol, "VERSION"),
					content_digest = content_hash,
				})
			end
		end

		-- The policy loop only runs once the real match has started (the guest
		-- from the initialized RUN stage for both roles); before that
		-- the service would refuse every decision as not-started and burn the
		-- loop's error budget.
		local match_running = false
		if mp_driver ~= nil and type(mp_driver.is_started) == "function" then
			local ok_started, value = pcall(mp_driver.is_started)
			match_running = ok_started and value == true
		elseif loop ~= nil then
			match_running = true
		end
		-- Post-start selection binding: both roles verify the actual initialized
		-- `selected_back.effect.center.key` and `G.GAME.stake` against the
		-- completed host-owned draft before any AI policy action. A loading frame
		-- is a bounded retry; a real mismatch aborts. With no selection present
		-- (legacy path / next draft slice) the check is skipped.
		local selection_ready = setup_info == nil or setup_info.selection == nil or post_start_checked
		if match_running and not selection_ready and mp_driver ~= nil then
			if post_start_check_at == nil or current - post_start_check_at >= coord_retry_interval then
				post_start_check_at = current
				local ok_check, check_code, retry = mp_driver.check_post_start_selection(setup_info.selection)
				if ok_check == true then
					post_start_checked = true
				elseif retry ~= true then
					-- Record the boot-level mismatch code (the driver's specific
					-- code is diagnostic only) so the abort reason is stable.
					record_error(CODE.SELECTION_MISMATCH)
					instance.shutdown(CODE.SELECTION_MISMATCH)
					return "stopped", CODE.SELECTION_MISMATCH
				end
			end
		end
		if loop ~= nil and not loop.is_stopped() and match_running and selection_ready and not unlock_blocking then
			local status, loop_code = loop.update()
			if status == "submitted" then
				counters.decisions = counters.decisions + 1
				-- Report the committed outcome to the service with the original
				-- (wire) decision identity the transport mapped from the private
				-- local sequence. The loop only reports `submitted` after an
				-- explicit successful broker dispatch.
				local local_sequence = transport.last_delivered_sequence()
				if local_sequence ~= nil and local_sequence ~= last_receipt_sequence then
					last_receipt_sequence = local_sequence
					transport.decision_result(local_sequence, { accepted = true, code = "broker_ok" })
				end
			elseif (status == "idle" or status == "stopped") and loop_code ~= nil then
				-- H3: count a refused decision exactly once per delivered
				-- sequence and only for the receipt allowlist (stale / dispatch
				-- failed / response rejected). Plain cooldown, dwell, transient,
				-- empty, no-action and wait returns are NOT refusals and are
				-- reported separately through `loop.stats()` in the end summary;
				-- they no longer inflate `rejected`. A delivered stale sequence
				-- therefore counts exactly once no matter how many idle frames
				-- follow it, because `last_receipt_sequence` latches it.
				-- L3: the final refusal that reaches `max_errors` stops the loop,
				-- so `status` is "stopped"; if it was a genuinely delivered
				-- refusal it is still counted and receipted here (before the
				-- shutdown below) exactly once. Non-receipt stop codes (revoked,
				-- timeout, transport error, terminal) are ignored by the allowlist.
				local local_sequence = transport.last_delivered_sequence()
				if local_sequence ~= nil and local_sequence ~= last_receipt_sequence
					and receipt_rejections[loop_code] == true then
					last_receipt_sequence = local_sequence
					counters.rejected = counters.rejected + 1
					transport.decision_result(local_sequence, { accepted = false, code = loop_code })
				end
			end
		end

		if pending_stop ~= nil and loop ~= nil and loop.is_stopped() then
			local reason = pending_stop
			pending_stop = nil
			if reason ~= "terminal" then
				instance.shutdown(reason)
				return "stopped", reason
			end
		end

		heartbeat(current)
		return state, CODE.OK
	end

	function instance.summary()
		return shallow_copy(last_summary or {})
	end

	function instance.status()
		return {
			state = state,
			role = role,
			handshake = handshake,
			activated = activated,
			decisions = counters.decisions,
			-- `rejected` is the version-2 receipt-based count (one per delivered
			-- refused decision). `counter_version` lets a consumer tell it apart
			-- from the historical idle-inflated number without guessing.
			rejected = counters.rejected,
			errors = counters.errors,
			counter_version = 2,
			has_pending = loop ~= nil and loop.pending_sequence() ~= nil,
			connected = transport ~= nil and transport.connected(),
			-- `inbound_events` are actual parsed-action counts from the staging
			-- dispatch observer; `inbound_seen` is its bounded total observed
			-- count (liveness); `state_edges` are the sampled diagnostic only.
			inbound_events = shallow_copy(inbound_events),
			inbound_seen = inbound_seen_total,
			-- Actual owned identity: our saved callback is still the live global.
			inbound_tap = inbound_tap ~= nil and AISP_INBOUND_TAP == inbound_tap,
			state_edges = shallow_copy(state_edges),
			last_error = last_error,
		}
	end

	function instance.shutdown(reason)
		if state == "stopped" then
			return true, CODE.STOPPED
		end
		local bounded = token_of(reason, RuntimeBootstrap.LIMITS.max_reason) or "shutdown"
		-- Final bracketed snapshot before the tap is cleared, so the retained
		-- window closes with its real counts and observer alive fact.
		log_inbound_snapshot("final", now())
		if loop ~= nil then
			pcall(loop.stop, bounded)
		end
		if broker ~= nil then
			pcall(broker.cancel)
		end
		if authority ~= nil and capability ~= nil then
			pcall(authority.revoke, capability)
		end
		if executor ~= nil then
			pcall(executor.revoke)
		end
		if type(remove_hooks) == "function" then
			pcall(remove_hooks)
			remove_hooks = nil
		end
		if type(uninstall_guard) == "function" then
			pcall(uninstall_guard)
			uninstall_guard = nil
		end
		if mp_driver ~= nil then
			pcall(mp_driver.uninstall)
			pcall(mp_driver.leave_local)
		end
		if transport ~= nil then
			pcall(transport.stop)
		end
		-- Drop the inbound tap only while it is still ours, so a foreign global of
		-- the same name is never clobbered by our shutdown. The closed snapshot
		-- then records the absent identity honestly (counters are preserved).
		clear_inbound_tap()
		log_inbound_snapshot("closed", now())
		activated = false
		installed = false
		installed_at = nil
		inbound = {}
		inbound_count = 0
		state = "stopped"
		loop = nil
		broker = nil
		executor = nil
		adapter = nil
		reader = nil
		revision = nil
		capability = nil
		authority = nil
		decision_transport = nil
		mp_driver = nil
		return true, CODE.OK
	end

	function instance.describe()
		local loop_state = nil
		if loop ~= nil then
			loop_state = loop.describe()
		end
		return {
			version = "aisp-runtime-bootstrap/1",
			state = state,
			role = role,
			handshake = handshake,
			activated = activated,
			mode = mode,
			pacing = pacing,
			difficulty = difficulty,
			gauntlet = human_seed ~= nil,
			setup_acked = setup_acked,
			lobby_ready = guest_ready_committed or start_committed,
			coordinated = coordination_done(),
			-- The decision loop's real public state (N5): the wired timeout, the
			-- trusted wait probe and the post-decision revision reader.
			loop_timeout = loop_state ~= nil and loop_state.timeout or nil,
			loop_has_wait_state = loop_state ~= nil and loop_state.has_wait_state == true,
			loop_has_revision = loop_state ~= nil and loop_state.has_revision == true,
			loop_has_readiness = loop_state ~= nil and loop_state.has_readiness == true,
			loop_stats = loop_state ~= nil and loop_state.stats or nil,
			role_ai = RuntimeBootstrap.ROLE_AI,
			role_human = RuntimeBootstrap.ROLE_HUMAN,
			counters = shallow_copy(counters),
			inbound_events = shallow_copy(inbound_events),
			inbound_seen = inbound_seen_total,
			-- Actual owned identity: our saved callback is still the live global.
			inbound_tap = inbound_tap ~= nil and AISP_INBOUND_TAP == inbound_tap,
			state_edges = shallow_copy(state_edges),
			last_error = last_error,
			codes = shallow_copy(CODE),
		}
	end

	instance.CODE = shallow_copy(CODE)
	instance.LIMITS = shallow_copy(RuntimeBootstrap.LIMITS)
	instance.role = role
	return instance
end

return RuntimeBootstrap
