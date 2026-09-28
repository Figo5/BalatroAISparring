local function stem_of(path)
	local stem = path:match("([^/\\]+)%.lua$")
	return stem or path
end

local function run_one(repo_root, test_file)
	local framework = dofile(repo_root .. "/tests/lua/framework.lua")
	local support = dofile(repo_root .. "/tests/companion/support.lua")
	local ctx = {
		repo_root = repo_root,
		test = framework.test,
		eq = framework.eq,
		is_true = framework.is_true,
		support = support,
	}
	local chunk, err = loadfile(test_file)
	if not chunk then
		return { { name = stem_of(test_file) .. "::load_failure", ok = false, err = tostring(err) } }
	end
	local ok, body_or_err = pcall(chunk)
	if not ok then
		return { { name = stem_of(test_file) .. "::exec_failure", ok = false, err = tostring(body_or_err) } }
	end
	if type(body_or_err) == "function" then
		local ok_body, body_err = pcall(body_or_err, ctx)
		if not ok_body then
			return { { name = stem_of(test_file) .. "::exec_failure", ok = false, err = tostring(body_err) } }
		end
	end
	local results = framework.run()
	local stem = stem_of(test_file)
	for i = 1, #results do
		results[i].name = stem .. "::" .. results[i].name
	end
	return results
end

function ais_run_companion_one(repo_root, test_file)
	return run_one(repo_root, test_file)
end

return true
