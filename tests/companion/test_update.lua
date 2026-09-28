return function(ctx)
	local test, eq, is_true = ctx.test, ctx.eq, ctx.is_true
	local host_module = ctx.support.host(ctx.repo_root)

	test("original update is called exactly once before the companion step", function()
		local order = {}
		local game = { update = function(self, dt)
			order[#order + 1] = "original:" .. tostring(dt)
			return "orig-result"
		end }
		local handle = host_module.install_update(game, function(dt)
			order[#order + 1] = "companion:" .. tostring(dt)
		end)
		is_true(handle ~= nil, "handle")
		local result = game.update(game, 0.5)
		eq(result, "orig-result", "return forwarded")
		eq(#order, 2, "two calls")
		eq(order[1], "original:0.5", "original first")
		eq(order[2], "companion:0.5", "companion second")
	end)

	test("uninstall restores the original and stops the companion step", function()
		local count = 0
		local game = { update = function()
			return true
		end }
		local original = game.update
		local handle = host_module.install_update(game, function()
			count = count + 1
		end)
		game.update(game)
		eq(count, 1, "companion ran")
		eq(handle.uninstall(), true, "uninstall")
		eq(game.update, original, "original restored")
		game.update(game)
		eq(count, 1, "companion stopped")
		eq(handle.uninstall(), true, "idempotent uninstall")
	end)

	test("missing update host fails closed", function()
		local handle, code = host_module.install_update(nil, function() end)
		eq(handle, nil, "no host")
		eq(code, host_module.CODE.NO_UPDATE_HOST, "code")
		local handle2, code2 = host_module.install_update({}, function() end)
		eq(handle2, nil, "no method")
		eq(code2, host_module.CODE.NO_UPDATE_HOST, "code2")
	end)

	test("a throwing companion step closes only the local feature", function()
		local failures = 0
		local companion_calls = 0
		local original_calls = 0
		local game = { update = function()
			original_calls = original_calls + 1
			return true
		end }
		local handle = host_module.install_update(game, function()
			companion_calls = companion_calls + 1
			error("synthetic companion failure", 2)
		end, {
			max_update_errors = 3,
			on_failure = function()
				failures = failures + 1
			end,
		})
		for _ = 1, 5 do
			game.update(game)
		end
		eq(original_calls, 5, "normal game keeps updating")
		eq(companion_calls, 3, "companion stopped after the bound")
		eq(failures, 1, "local feature closed once")
		eq(handle.active(), false, "inactive")
		eq(handle.errors(), 3, "errors counted")
	end)
end
