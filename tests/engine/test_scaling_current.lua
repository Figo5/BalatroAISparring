-- Owned scaling Jokers (docs/SCALING_VALUES_DESIGN.md): the adapter exports
-- the shown current value (xmult in hundredths) and the per-hand step; the
-- reader recomputes both from the engine card and rejects any mismatch; the
-- observation types the nested record strictly.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)

	local function joker(center, ability)
		local card = support.card({ center = center, set = "Joker", center_set = "Joker" })
		for k, v in pairs(ability or {}) do
			card.ability[k] = v
		end
		return card
	end

	local function step(jokers)
		local e = support.engine({
			hand = { support.card({ rank = "King", suit = "Hearts" }), support.card({ rank = "King", suit = "Spades" }) },
			jokers = jokers,
		})
		local result, code = support.pipeline(bundle, e, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		return result
	end

	local function view_jokers(result)
		local list = result.ui_view.self.cards.joker
		is_true(type(list) == "table", "joker zone")
		return list
	end

	local function export(result)
		local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
		is_true(handle ~= nil, "capture: " .. tostring(code))
		return bundle.obs.export(handle)
	end

	local function rejected(result, label)
		local handle, code = bundle.reader.capture(result.runtime, result.ui_view)
		eq(handle, nil, label)
		eq(code, "reader_bad_view", label .. " code")
	end

	local function standard()
		return {
			joker("j_green_joker", { mult = 12, extra = { hand_add = 1, discard_sub = 1 } }),
			joker("j_runner", { extra = { chips = 45, chip_mod = 15 } }),
			joker("j_hologram", { x_mult = 1.25 }),
			joker("j_constellation", { x_mult = 1.7000000000000004 }),
			joker("j_ride_the_bus", { mult = 3, extra = 1 }),
		}
	end

	test("adapter_exports_current_values_through_the_pipeline", function()
		local obs = export(step(standard()))
		local j = obs.self.jokers
		eq(j[1].current.kind, "mult", "green kind")
		eq(j[1].current.value, 12, "green value")
		eq(j[1].current.step, 1, "green step")
		eq(j[2].current.kind, "chips", "runner kind")
		eq(j[2].current.value, 45, "runner value")
		eq(j[2].current.step, 15, "runner step")
		eq(j[3].current.value, 125, "hologram hundredths")
		eq(j[3].current.step, nil, "hologram has no step")
		eq(j[4].current.value, 170, "drifted constellation rounds")
		eq(j[5].current.value, 3, "ride the bus value")
		eq(j[5].current.step, 1, "ride the bus numeric extra")
	end)

	test("adapter_omits_bad_or_unlisted_values", function()
		local list = view_jokers(step({
			joker("j_green_joker", { mult = 0 / 0, extra = { hand_add = 1 } }),
			joker("j_green_joker", { mult = 2.5, extra = { hand_add = 1 } }),
			joker("j_hologram", { x_mult = 1e9 }),
			joker("j_joker", { mult = 4 }),
			joker("j_runner", { extra = { chips = 30 } }),
		}))
		for i = 1, 5 do
			eq(list[i].current, nil, "omitted " .. i)
		end
		local hidden = joker("j_hologram", { x_mult = 2 })
		hidden.facing, hidden.sprite_facing = "back", "back"
		eq(view_jokers(step({ hidden }))[1].current, nil, "face-down")
	end)

	test("reader_rejects_mismatches_and_unlisted_centers", function()
		local r1 = step(standard())
		view_jokers(r1)[1].current.value = 30
		rejected(r1, "value spoof")
		local r2 = step(standard())
		view_jokers(r2)[1].current.kind = "xmult"
		rejected(r2, "kind spoof")
		local r3 = step(standard())
		view_jokers(r3)[2].current.step = 99
		rejected(r3, "step spoof")
		local r4 = step(standard())
		view_jokers(r4)[3].current.step = 1
		rejected(r4, "extra step")
		local r5 = step(standard())
		view_jokers(r5)[1].current.extra = 1
		rejected(r5, "extra key")
		local r6 = step({ joker("j_joker", { mult = 4 }) })
		view_jokers(r6)[1].current = { kind = "mult", value = 4 }
		view_jokers(r6)[1].shown.current = true
		rejected(r6, "unlisted center")
		local r7 = step(standard())
		view_jokers(r7)[1].current = "12"
		rejected(r7, "not a table")
	end)

	test("reader_needs_the_shown_attestation", function()
		local r = step(standard())
		view_jokers(r)[1].shown.current = nil
		eq(export(r).self.jokers[1].current, nil, "not attested")
	end)

	test("observation_rejects_bad_current_records", function()
		is_true(bundle.obs.observe(export(step(standard()))) ~= nil, "valid frame observes")
		local cases = {
			{ kind = "xmult", value = 99 },
			{ kind = "mult", value = -1 },
			{ kind = "mult", value = 1.5 },
			{ kind = "bogus", value = 1 },
			{ kind = "mult", value = 1, step = 100001 },
			{ kind = "mult", value = 1, other = true },
		}
		for i, bad in ipairs(cases) do
			local base = export(step(standard()))
			base.self.jokers[1].current = bad
			local handle, code = bundle.obs.observe(base)
			eq(handle, nil, "case " .. i)
			eq(code, "observation_invalid_entity", "case " .. i .. " code")
		end
	end)
end
