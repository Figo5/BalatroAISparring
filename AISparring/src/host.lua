local Host = {}

Host.DEPENDENCY_ID = "Multiplayer"
Host.STRUCTURE_TABLES = { "GAME", "ACTIONS", "MOD_ACTIONS" }
Host.STRUCTURE_FUNCTIONS = { "register_mod_action", "current_ruleset" }

function Host.inspect(smods, mp)
	if type(smods) ~= "table" or type(smods.Mods) ~= "table" then
		return nil, "smods_unavailable"
	end
	local entry = smods.Mods[Host.DEPENDENCY_ID]
	if entry == nil then
		return {
			present = false,
			identity_match = false,
			id = Host.DEPENDENCY_ID,
			version = nil,
			version_malformed = false,
			can_load = nil,
			disabled = false,
			structure_missing = {},
		}
	end
	if type(entry) ~= "table" then
		return nil, "dependency_entry_invalid"
	end

	local missing = {}
	if type(mp) ~= "table" then
		missing[#missing + 1] = "MP"
	end

	local identity_match = (mp == entry)
	local id = entry.id
	if type(id) ~= "string" then
		id = nil
	end
	local version = entry.version
	local version_malformed = version ~= nil and type(version) ~= "string"
	if type(version) ~= "string" then
		version = nil
	end
	local can_load = entry.can_load
	if type(can_load) ~= "boolean" then
		can_load = nil
	end
	local disabled = entry.disabled == true

	if identity_match then
		for i = 1, #Host.STRUCTURE_TABLES do
			local key = Host.STRUCTURE_TABLES[i]
			if type(entry[key]) ~= "table" then
				missing[#missing + 1] = key
			end
		end
		for i = 1, #Host.STRUCTURE_FUNCTIONS do
			local key = Host.STRUCTURE_FUNCTIONS[i]
			if type(entry[key]) ~= "function" then
				missing[#missing + 1] = key
			end
		end
		local lobby = entry.LOBBY
		if type(lobby) ~= "table" then
			missing[#missing + 1] = "LOBBY"
		else
			if type(lobby.connected) ~= "boolean" then
				missing[#missing + 1] = "LOBBY.connected"
			end
			if lobby.code ~= nil and type(lobby.code) ~= "string" then
				missing[#missing + 1] = "LOBBY.code"
			end
		end
		if entry.lovely ~= true then
			missing[#missing + 1] = "lovely"
		end
		local actions = entry.ACTIONS
		if type(actions) ~= "table" or type(actions.connect) ~= "function" then
			missing[#missing + 1] = "ACTIONS.connect"
		end
	end

	return {
		present = true,
		identity_match = identity_match,
		id = id,
		version = version,
		version_malformed = version_malformed,
		can_load = can_load,
		disabled = disabled,
		structure_missing = missing,
	}
end

function Host.read_ai_flag(smods, mod_id)
	if type(smods) ~= "table" or type(smods.Mods) ~= "table" then
		return false
	end
	local entry = smods.Mods[mod_id]
	if type(entry) ~= "table" then
		return false
	end
	local config = entry.config
	if type(config) ~= "table" then
		return false
	end
	return config.ai_enabled == true
end

return Host
