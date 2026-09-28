-- AI Sparring control channel worker thread.
--
-- The staged runtime talks to the launcher-owned practice service over a
-- dedicated loopback control channel. Like Multiplayer's own networking, the
-- blocking socket work runs on a separate LÖVE thread so the game main thread
-- never blocks. Unlike Multiplayer, it does NOT use the `uiToNetwork` /
-- `networkToUi` channels: those belong to the official match transport and must
-- never carry private coordination (docs/PLAYABLE_RUNTIME_CONTRACT.md,
-- docs/INTEGRATION_PLAN.md).
--
-- This module is data only. Loading it creates no thread, opens no socket and
-- touches no global: it returns the worker source string plus the channel-name
-- helpers. The trusted bootstrap (runtime_bootstrap.lua) is the only caller and
-- supplies the LÖVE thread API as an injected port.
--
-- Thread contract (all frames are one JSON object per line):
--
--   main -> worker : the caller pushes either
--                      * a raw encoded request envelope string (pushed through
--                        as-is plus "\n"), or
--                      * the control frame {"t":"stop"}.
--   worker -> main : each line the worker reads is pushed as a raw JSON string,
--                    plus worker events {"t":"ready"|"error"|"closed"|"stopped"}.
--
-- Bounds: 2 MiB outbound per request, 64 KiB inbound per line. The worker only
-- ever connects to 127.0.0.1. Credentials are opaque here: the worker never
-- parses, logs or rewrites them.

local ControlThread = {}

ControlThread.VERSION = "aisp-control-thread/1"

ControlThread.CODE = {
	OK = "control_thread_ok",
	BAD_PORTS = "control_thread_bad_ports",
	BAD_CHANNEL = "control_thread_bad_channel",
	BAD_SOURCE = "control_thread_bad_source",
	START_FAILED = "control_thread_start_failed",
}

ControlThread.EVENTS = {
	READY = "ready",
	ERROR = "error",
	CLOSED = "closed",
	STOPPED = "stopped",
	STOP = "stop",
}

ControlThread.LIMITS = {
	max_nonce = 32,
	max_send = 2097152,
	max_receive = 65536,
	connect_timeout = 5,
	send_timeout = 2,
	read_timeout = 0.1,
	poll_sleep = 0.005,
	drain_per_cycle = 64,
	read_chunk = 4096,
	response_budget = 32,
	channel_prefix = "aisp_ctrl_",
}

local TOKEN_PATTERN = "^[0-9A-Za-z_]+$"

-- Worker source. Runs in the isolated LÖVE thread environment (as Multiplayer's
-- networking/socket.lua does) and re-requires the game-bundled json + socket
-- modules because threads do not share the main environment. It receives
-- (port, to_worker_name, from_worker_name) from Thread:start.
ControlThread.SOURCE = [==[
local port, to_worker_name, from_worker_name = ...

require("love.filesystem")

local json_ok, json = pcall(function() return require("json") end)
local socket_ok, socket = pcall(function() return require("socket") end)

local MAX_SEND = 2097152
local MAX_RECEIVE = 65536
local CONNECT_TIMEOUT = 5
local SEND_TIMEOUT = 2
local READ_TIMEOUT = 0.1
local READ_CHUNK = 4096
local DRAIN_PER_CYCLE = 64
local RESPONSE_BUDGET = 32
local POLL_SLEEP = 0.005
local MAX_BUFFER = 262144

local inbox = love.thread.getChannel(to_worker_name)
local outbox = love.thread.getChannel(from_worker_name)

local function emit(fields)
	local ok, text = pcall(json.encode, fields)
	if ok and type(text) == "string" and #text <= MAX_RECEIVE then
		outbox:push(text)
	end
end

-- A bounded, hard-coded frame that never touches `json`, so a missing/broken
-- json dependency still reports itself instead of the emit path itself failing
-- on `json.encode` (Lovely 0.10 preloads json in every state, so this is a
-- defensive fallback, not the normal path).
local function emit_fixed(text)
	if type(text) == "string" and #text > 0 and #text <= MAX_RECEIVE then
		pcall(function()
			outbox:push(text)
		end)
	end
end

if not json_ok or not socket_ok or type(json) ~= "table" or type(socket) ~= "table" then
	emit_fixed('{"t":"error","code":"control_thread_dependency"}')
	return
end

local port_number = tonumber(port)
if port_number == nil or port_number < 1 or port_number > 65535 then
	emit({ t = "error", code = "control_thread_bad_port" })
	return
end

local client = socket.tcp()
client:settimeout(CONNECT_TIMEOUT)
client:setoption("tcp-nodelay", true)
local connected = client:connect("127.0.0.1", port_number)
if connected ~= 1 then
	pcall(function()
		client:close()
	end)
	emit({ t = "error", code = "control_connect_failed" })
	return
end

emit({ t = "ready" })

local buffer = ""
local stopping = false

local function flush_lines()
	while true do
		local newline = string.find(buffer, "\n", 1, true)
		if newline == nil then
			return
		end
		local line = string.sub(buffer, 1, newline - 1)
		buffer = string.sub(buffer, newline + 1)
		if #line > MAX_RECEIVE then
			emit({ t = "error", code = "control_receive_too_large" })
		elseif #line > 0 then
			outbox:push(line)
		end
	end
end

while not stopping do
	for _ = 1, DRAIN_PER_CYCLE do
		local message = inbox:pop()
		if message == nil then
			break
		end
		if type(message) == "string" then
			local ok_decode, decoded = pcall(json.decode, message)
			local kind = nil
			if ok_decode and type(decoded) == "table" then
				kind = decoded.t
			end
			if kind == "stop" then
				stopping = true
				break
			end
			if #message > MAX_SEND then
				emit({ t = "error", code = "control_send_too_large" })
			else
				client:settimeout(SEND_TIMEOUT)
				local sent, send_err = client:send(message .. "\n")
				if not sent and send_err ~= "timeout" then
					emit({ t = "closed" })
					stopping = true
					break
				end
			end
		end
	end

	if not stopping then
		client:settimeout(READ_TIMEOUT)
		local data, read_err, partial = client:receive(READ_CHUNK)
		if type(data) == "string" and #data > 0 then
			buffer = buffer .. data
		elseif type(partial) == "string" and #partial > 0 then
			buffer = buffer .. partial
		end
		if #buffer > MAX_BUFFER then
			buffer = ""
			emit({ t = "error", code = "control_receive_too_large" })
		end
		flush_lines()
		if read_err == "closed" then
			emit({ t = "closed" })
			break
		end
		socket.sleep(POLL_SLEEP)
	end
end

pcall(function()
	client:close()
end)
emit({ t = "stopped" })
]==]

local function token_of(value, limit)
	if type(value) ~= "string" or #value == 0 or #value > limit then
		return nil
	end
	if string.match(value, TOKEN_PATTERN) == nil then
		return nil
	end
	return value
end

-- Deterministic per-session channel names. A nonce + role pair yields a
-- dedicated pair so two staged runtimes in one process never share a queue.
function ControlThread.channel_names(nonce, role)
	local token = token_of(nonce, ControlThread.LIMITS.max_nonce)
	if token == nil then
		return nil, ControlThread.CODE.BAD_CHANNEL
	end
	if role ~= "human" and role ~= "ai" then
		return nil, ControlThread.CODE.BAD_CHANNEL
	end
	local base = ControlThread.LIMITS.channel_prefix .. token .. "_" .. role
	return {
		to_worker = base .. "_tw",
		from_worker = base .. "_fw",
	}
end

-- Spawn the worker. `love_thread` is the injected love.thread module (never a
-- global lookup here). Returns the LÖVE thread handle, or nil + bounded code.
function ControlThread.start(love_thread, port, to_worker, from_worker)
	if type(love_thread) ~= "table" or type(love_thread.newThread) ~= "function" then
		return nil, ControlThread.CODE.BAD_PORTS
	end
	if token_of(to_worker, 64) == nil or token_of(from_worker, 64) == nil then
		return nil, ControlThread.CODE.BAD_CHANNEL
	end
	local port_number = tonumber(port)
	if port_number == nil or port_number < 1 or port_number > 65535 then
		return nil, ControlThread.CODE.BAD_PORTS
	end
	if type(ControlThread.SOURCE) ~= "string" or #ControlThread.SOURCE == 0 then
		return nil, ControlThread.CODE.BAD_SOURCE
	end
	local ok_thread, thread = pcall(love_thread.newThread, ControlThread.SOURCE)
	if not ok_thread or thread == nil then
		return nil, ControlThread.CODE.START_FAILED
	end
	local ok_start = pcall(function()
		thread:start(port_number, to_worker, from_worker)
	end)
	if not ok_start then
		return nil, ControlThread.CODE.START_FAILED
	end
	return thread
end

return ControlThread
