local function load_framework(repo_root)
	local chunk, err = loadfile(repo_root .. "/tests/menu/framework.lua")
	if chunk == nil then
		error("framework load failed: " .. tostring(err), 2)
	end
	return chunk()
end

local function run(repo_root, test_file)
	local framework = load_framework(repo_root)
	framework.install(_G, repo_root)
	local chunk, err = loadfile(test_file)
	if chunk == nil then
		return { cases = {}, vectors = {}, error = "load_failure: " .. tostring(err) }
	end
	local ok, result = pcall(chunk)
	if not ok then
		return { cases = {}, vectors = {}, error = "exec_failure: " .. tostring(result) }
	end
	if type(result) == "function" then
		local ok_body, body_err = pcall(result, { repo_root = repo_root })
		if not ok_body then
			return { cases = {}, vectors = {}, error = "body_failure: " .. tostring(body_err) }
		end
	end
	return framework.finish()
end

ais_menu_run = run
return run
