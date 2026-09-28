local function stem_of(path)
	local stem = path:match("([^/\\]+)%.lua$")
	return stem or path
end

local function run_one(repo_root, test_file)
	local framework = dofile(repo_root .. "/tests/policy/framework.lua")
	local support = dofile(repo_root .. "/tests/policy/support.lua")
	local ctx = {
		repo_root = repo_root,
		test = framework.test,
		eq = framework.eq,
		neq = framework.neq,
		is_true = framework.is_true,
		truthy = framework.truthy,
		vector = framework.vector,
		support = support,
	}
	local chunk, err = loadfile(test_file)
	if not chunk then
		return { cases = { { name = stem_of(test_file) .. "::load_failure", ok = false, err = tostring(err) } }, vectors = {} }
	end
	local ok, body_or_err = pcall(chunk)
	if not ok then
		return { cases = { { name = stem_of(test_file) .. "::exec_failure", ok = false, err = tostring(body_or_err) } }, vectors = {} }
	end
	if type(body_or_err) == "function" then
		local ok_body, body_err = pcall(body_or_err, ctx)
		if not ok_body then
			return { cases = { { name = stem_of(test_file) .. "::exec_failure", ok = false, err = tostring(body_err) } }, vectors = {} }
		end
	end
	local results = framework.run()
	local stem = stem_of(test_file)
	for i = 1, #results do
		results[i].name = stem .. "::" .. results[i].name
	end
	return { cases = results, vectors = framework.vectors }
end

function ais_run_policy_one(repo_root, test_file)
	return run_one(repo_root, test_file)
end

return true
