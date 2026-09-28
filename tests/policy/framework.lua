local Framework = {}

Framework.cases = {}
Framework.vectors = {}

function Framework.test(name, fn)
	if type(name) ~= "string" or name == "" then
		error("test name must be a non-empty string", 2)
	end
	if type(fn) ~= "function" then
		error("test body must be a function", 2)
	end
	Framework.cases[#Framework.cases + 1] = { name = name, fn = fn }
end

function Framework.eq(actual, expected, label)
	if actual ~= expected then
		error((label or "eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

function Framework.neq(actual, expected, label)
	if actual == expected then
		error((label or "neq") .. ": both " .. tostring(actual), 2)
	end
end

function Framework.is_true(value, label)
	if value ~= true then
		error((label or "is_true") .. ": expected true, got " .. tostring(value), 2)
	end
end

function Framework.truthy(value, label)
	if not value then
		error((label or "truthy") .. ": got " .. tostring(value), 2)
	end
end

function Framework.vector(key, value)
	if type(key) ~= "string" or key == "" then
		error("vector key must be a non-empty string", 2)
	end
	Framework.vectors[key] = tostring(value)
end

function Framework.run()
	local results = {}
	for i = 1, #Framework.cases do
		local item = Framework.cases[i]
		local ok, err = pcall(item.fn)
		results[#results + 1] = { name = item.name, ok = ok, err = ok and "" or tostring(err) }
	end
	return results
end

return Framework
