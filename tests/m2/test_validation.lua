return function()
	local m = new_ai()
	local Codec = m.Codec
	local obs = m.Observation.factory(Codec)
	local acts = m.Actions.factory(obs, Codec)
	local CODE = acts.CODE

	local function scenario()
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }) }
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "hand:1" } }) }
		local h = ois(obs, f)
		return h, actions_of(acts, h)[1]
	end

	test("actions.validate.roundtrip_copy_isolation", function()
		local h, action = scenario()
		local copy = acts.validate(h, action)
		truthy(copy, "validate ok")
		eq(copy.id, action.id, "id")
		copy.id = "tampered"
		copy.card_refs[1] = "hand:99"
		local again = acts.validate(h, action)
		eq(again.id, action.id, "candidate unaffected by returned copy mutation")
		eq(again.card_refs[1], "hand:1", "refs intact")
	end)

	test("actions.validate.rejects_forged_id", function()
		local h, action = scenario()
		local forged = clone(action)
		forged.id = "o0:"
		eq(select(2, acts.validate(h, forged)), CODE.ID_MISMATCH, "wrong id")
	end)

	test("actions.validate.rejects_extra_keys", function()
		local h, action = scenario()
		local extra = clone(action)
		extra.extra = 1
		eq(select(2, acts.validate(h, extra)), CODE.BAD_ACTION, "extra key")
	end)

	test("actions.validate.rejects_metatable_and_function", function()
		local h, action = scenario()
		local mt = setmetatable(clone(action), {})
		eq(select(2, acts.validate(h, mt)), CODE.BAD_ACTION, "metatable action")
		local fn = clone(action)
		fn.card_refs = function() end
		eq(select(2, acts.validate(h, fn)), CODE.BAD_ACTION, "function field")
	end)

	test("actions.validate.rejects_bad_id_and_type", function()
		local h, action = scenario()
		local no_id = clone(action)
		no_id.id = 5
		eq(select(2, acts.validate(h, no_id)), CODE.BAD_ID, "nonstring id")
		eq(select(2, acts.validate(h, { type = "NOPE", id = "x" })), CODE.UNKNOWN_TYPE, "unknown type")
	end)

	test("actions.validate.foreign_ref_not_certified", function()
		local h, action = scenario()
		local forged_content = { type = action.type, card_refs = { "hand:99" } }
		local forged = { type = action.type, card_refs = { "hand:99" }, id = Codec.encode(forged_content) }
		eq(select(2, acts.validate(h, forged)), CODE.NOT_CERTIFIED, "foreign ref")
	end)

	test("actions.validate.foreign_handle", function()
		local other = m.Observation.factory(Codec)
		local h = ois(other, syn("BLIND_SELECTION"))
		local action = acts.generate(h)
		eq(action, nil, "generate foreign nil")
		eq(select(2, acts.validate(h, { type = "SELECT_BLIND", id = "x" })), CODE.UNKNOWN_HANDLE, "validate foreign")
	end)

	test("actions.validate.denied_after_context_change_is_not_certified", function()
		local h, action = scenario()
		eq(select(2, acts.validate(h, action)), nil, "valid now")
		local f = syn("PLAY_HAND")
		f.self.hand_visible = true
		f.self.hand = { entity({ rank = "A", suit = "Spades" }) }
		f.context.blocked = true
		f.certificates.items = { cert("PLAY_CARDS", { card_refs = { "hand:1" } }) }
		local h2 = ois(obs, f)
		eq(select(2, acts.validate(h2, action)), CODE.NOT_CERTIFIED, "blocked now")
	end)

	test("actions.validate.never_crashes_on_probes", function()
		local h, action = scenario()
		local probes = { nil, 0, "x", true, function() end, setmetatable({}, {}), { type = "PLAY_CARDS" } }
		for i = 1, #probes do
			local ok, result = pcall(acts.validate, h, probes[i])
			truthy(ok, "validate no crash " .. tostring(i))
			truthy(result == nil, "no candidate returned " .. tostring(i))
		end
	end)
end
