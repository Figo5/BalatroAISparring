-- match.blind_disabled (docs/BLIND_DISABLED_DESIGN.md): the adapter exports the
-- AI's own G.GAME.blind.disabled only alongside a blind; the reader accepts a
-- strict boolean that matches the engine and only with a blind; the
-- observation types it as bool.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)

	local function engine(opts)
		local e = support.engine({
			hand = { support.card({ rank = "King", suit = "Hearts" }), support.card({ rank = "King", suit = "Spades" }) },
			blind_key = opts.key or "bl_psychic",
			omit_blind = opts.omit_blind,
		})
		if not opts.omit_blind then
			e.G.GAME.blind.disabled = opts.disabled
		end
		return e
	end

	local function step(e)
		local result, code = support.pipeline(bundle, e, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		return result
	end

	local function export(e)
		local result = step(e)
		local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "capture: " .. tostring(code))
		return bundle.obs.export(handle)
	end

	test("adapter_exports_the_engine_flag_with_the_blind", function()
		eq(export(engine({ disabled = true })).match.blind_disabled, true, "disabled")
		eq(export(engine({ disabled = false })).match.blind_disabled, false, "active")
		eq(export(engine({})).match.blind_disabled, nil, "unset engine flag")
		local nemesis = export(engine({ key = "bl_mp_nemesis", disabled = false }))
		eq(nemesis.match.blind_disabled, false, "pvp blind")
	end)

	test("reader_rejects_bad_or_orphan_or_mismatched_flags", function()
		for _, bad in ipairs({ "true", 1, {} }) do
			local result = step(engine({ disabled = true }))
			result.ui_view.match.blind_disabled = bad
			local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
			eq(handle, nil, "type " .. type(bad))
			eq(code, "reader_bad_view", "type " .. type(bad))
		end
		-- The view says disabled but the engine says active: never trusted.
		local spoof = step(engine({ disabled = false }))
		spoof.ui_view.match.blind_disabled = true
		local h1, c1 = bundle.reader.capture(spoof.runtime, spoof.ui_view)
		eq(h1, nil, "mismatch")
		eq(c1, "reader_bad_view", "mismatch code")
		-- A flag without a blind.
		local orphan = step(engine({ disabled = true }))
		orphan.ui_view.match.blind = nil
		local h2, c2 = bundle.reader.capture(orphan.runtime, orphan.ui_view)
		eq(h2, nil, "orphan")
		eq(c2, "reader_bad_view", "orphan code")
	end)

	test("observation_types_the_flag_as_bool", function()
		local ex = export(engine({ disabled = true }))
		local frame = {}
		for k, v in pairs(ex) do
			frame[k] = v
		end
		frame.match = {}
		for k, v in pairs(ex.match) do
			frame.match[k] = v
		end
		frame.match.blind_disabled = "yes"
		local handle = bundle.obs.observe(frame)
		eq(handle, nil, "non-bool rejected")
	end)
end
