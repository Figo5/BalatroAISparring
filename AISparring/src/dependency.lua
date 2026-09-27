local Dependency = {}

Dependency.SPEC = {
	id = "Multiplayer",
	version = "0.5.5",
}

function Dependency.version_token(value, spec, malformed)
	spec = spec or Dependency.SPEC
	if malformed == true then
		return "malformed"
	end
	if value == nil then
		return "missing"
	end
	if type(value) ~= "string" then
		return "malformed"
	end
	if value == spec.version then
		return spec.version
	end
	return "unsupported"
end

function Dependency.evaluate(snapshot, spec)
	spec = spec or Dependency.SPEC
	if type(snapshot) ~= "table" then
		return false, "host_inspection_failed"
	end
	if snapshot.present ~= true then
		return false, "dependency_missing"
	end
	if snapshot.identity_match ~= true or snapshot.id ~= spec.id then
		return false, "dependency_identity_mismatch"
	end
	if snapshot.disabled == true then
		return false, "dependency_disabled"
	end
	if snapshot.can_load == false then
		return false, "dependency_not_loadable"
	end
	if snapshot.can_load == nil then
		return false, "dependency_state_unknown"
	end
	if type(snapshot.version) ~= "string" or snapshot.version ~= spec.version then
		return false, "dependency_version_mismatch"
	end
	if type(snapshot.structure_missing) == "table" and #snapshot.structure_missing > 0 then
		return false, "dependency_structure_incomplete"
	end
	return true, "ok"
end

return Dependency
