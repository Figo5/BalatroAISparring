local F = {}

F.cases = {}
F.iterations = 0
F.vectors = {}

local function load_chunk(path, env)
	local chunk, err = loadfile(path)
	if chunk == nil then
		error("cannot load " .. path .. ": " .. tostring(err), 2)
	end
	if env ~= nil then
		setfenv(chunk, env)
	end
	return chunk()
end

function F.load_ai(repo_root, env)
	return {
		Codec = load_chunk(repo_root .. "/AISparring/ai/codec.lua", env),
		Observation = load_chunk(repo_root .. "/AISparring/ai/observation.lua", env),
		Actions = load_chunk(repo_root .. "/AISparring/ai/actions.lua", env),
	}
end

function F.safe_env()
	local env = {}
	env.math = math
	env.string = string
	env.table = table
	env.type = type
	env.next = next
	env.rawget = rawget
	env.rawset = rawset
	env.getmetatable = getmetatable
	env.setmetatable = setmetatable
	env.pcall = pcall
	env.error = error
	env.assert = assert
	env.select = select
	env.tostring = tostring
	env.tonumber = tonumber
	env.ipairs = ipairs
	env.pairs = pairs
	env.unpack = unpack

	local fired = { count = 0 }
	local function forbid(name)
		return function()
			fired.count = fired.count + 1
			error("forbidden global access: " .. name, 2)
		end
	end
	local function canary(name)
		return setmetatable({}, { __index = forbid(name), __newindex = forbid(name) })
	end

	env.G = canary("G")
	env.MP = canary("MP")
	env.SMODS = canary("SMODS")
	env.Client = canary("Client")
	env.love = canary("love")
	env.io = canary("io")
	env.os = canary("os")
	env.debug = canary("debug")
	env.require = forbid("require")
	env.load = forbid("load")
	env.loadstring = forbid("loadstring")
	env.dofile = forbid("dofile")
	env.setfenv = forbid("setfenv")
	env.getfenv = forbid("getfenv")
	env.collectgarbage = forbid("collectgarbage")
	env._G = env
	return env, fired
end

function F.syn(phase)
	return {
		schema_version = 1,
		phase = phase,
		match = {
			ruleset = "mp",
			ante = 1,
			round = 1,
			lives = 4,
			hands_per_round = 4,
			discards_per_round = 3,
			hand_size = 8,
			joker_slots = 5,
			consumable_slots = 2,
			blind = "Small Blind",
			timer = "1:00",
		},
		self = {
			money = 20,
			credit_limit = 0,
			hands = 4,
			discards = 3,
			current_score = "0",
			blind_requirement = "300",
		},
		context = {
			blocked = false,
			timer_expired = false,
			target_selection = false,
			max_play = 5,
			max_discard = 5,
		},
		certificates = { version = 1, items = {} },
	}
end

function F.cert(kind, fields)
	local out = { type = kind, certified = true }
	if type(fields) == "table" then
		for key, value in pairs(fields) do
			out[key] = value
		end
	end
	return out
end

function F.entity(fields)
	local out = { face_down = false }
	if type(fields) == "table" then
		for key, value in pairs(fields) do
			out[key] = value
		end
	end
	return out
end

local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = clone(item)
	end
	return out
end

function F.install(g, repo_root)
	g.repo_root = repo_root
	g.new_ai = function(env)
		return F.load_ai(repo_root, env)
	end
	g.test = function(name, fn)
		if type(name) ~= "string" or name == "" then
			error("test name must be a non-empty string", 2)
		end
		if type(fn) ~= "function" then
			error("test body must be a function", 2)
		end
		F.cases[#F.cases + 1] = { name = name, fn = fn }
	end
	g.eq = function(actual, expected, label)
		if actual ~= expected then
			error((label or "eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
		end
	end
	g.neq = function(actual, expected, label)
		if actual == expected then
			error((label or "neq") .. ": both " .. tostring(actual), 2)
		end
	end
	g.truthy = function(value, label)
		if not value then
			error((label or "truthy") .. ": got " .. tostring(value), 2)
		end
	end
	g.falsy = function(value, label)
		if value then
			error((label or "falsy") .. ": got " .. tostring(value), 2)
		end
	end
	g.count = function(n)
		F.iterations = F.iterations + (n or 1)
	end
	g.vec = function(name, value)
		F.vectors[name] = tostring(value)
	end
	g.clone = clone
	g.syn = F.syn
	g.cert = F.cert
	g.entity = F.entity
	g.safe_env = F.safe_env
	g.make_ai = function(env)
		local m = F.load_ai(repo_root, env)
		local obs = m.Observation.factory(m.Codec)
		local acts = m.Actions.factory(obs, m.Codec)
		return m, obs, acts
	end
	g.ois = function(obs, frame)
		local handle, code = obs.observe(frame)
		if handle == nil then
			error("observe unexpected failure: " .. tostring(code), 2)
		end
		return handle
	end
	g.obs_code = function(obs, frame)
		local handle, code = obs.observe(frame)
		if handle ~= nil then
			error("observe unexpectedly succeeded", 2)
		end
		return code
	end
	g.action_ids = function(list)
		local out = {}
		for i = 1, #list do
			out[i] = list[i].id
		end
		table.sort(out)
		return table.concat(out, ",")
	end
	g.actions_of = function(acts, handle)
		local list, code = acts.generate(handle)
		if list == nil then
			error("generate unexpected failure: " .. tostring(code), 2)
		end
		return list
	end
	g.export_ids = function(plain)
		local set = {}
		local function add(list)
			if type(list) ~= "table" then
				return
			end
			for i = 1, #list do
				if type(list[i]) == "table" and type(list[i].id) == "string" then
					set[list[i].id] = true
				end
			end
		end
		local self = plain.self
		if type(self) == "table" then
			add(self.hand)
			add(self.jokers)
			add(self.consumables)
			add(self.vouchers)
			add(self.tags)
		end
		local shop = plain.shop
		if type(shop) == "table" then
			add(shop.items)
			add(shop.vouchers)
			add(shop.boosters)
		end
		local booster = plain.booster
		if type(booster) == "table" then
			add(booster.cards)
		end
		local target = plain.consumable_target
		if type(target) == "table" then
			add(target.targets)
		end
		return set
	end
end

function F.finish()
	local results = {}
	for i = 1, #F.cases do
		local item = F.cases[i]
		local ok, err = pcall(item.fn)
		results[i] = { name = item.name, ok = ok, err = ok and "" or tostring(err) }
	end
	return { cases = results, iterations = F.iterations, vectors = F.vectors }
end

return F
