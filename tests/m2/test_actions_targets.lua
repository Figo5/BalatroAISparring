return function()
	local m = new_ai()
	local obs = m.Observation.factory(m.Codec)
	local acts = m.Actions.factory(obs, m.Codec)

	local function target_frame()
		local f = syn("CONSUMABLE_SELECTION")
		f.self.consumables = { entity({ center = "c_tarot" }) }
		f.consumable_target = {
			source = entity({ center = "c_tarot" }),
			source_ref = "consumable:1",
			targets = { entity({ rank = "A", suit = "Spades" }), entity({ rank = "K", suit = "Hearts" }) },
			min_targets = 1,
			max_targets = 2,
		}
		f.context.target_selection = true
		return f
	end

	test("actions.consumable.empty_targets_allowed_in_hand_phase", function()
		local f = syn("PLAY_HAND")
		f.self.consumables = { entity({ center = "c_tarot" }) }
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = {} }) }
		local list = actions_of(acts, ois(obs, f))
		eq(#list, 1, "empty-target consumable")
		eq(list[1].source_ref, "consumable:1", "source")
		eq(#list[1].target_refs, 0, "empty targets")
	end)

	test("actions.consumable.targets_require_selection_context", function()
		local f = target_frame()
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = { "target:1" } }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "selected target")
		f.context.target_selection = false
		eq(#actions_of(acts, ois(obs, f)), 0, "no target_selection")
	end)

	test("actions.consumable.target_count_bounds", function()
		local f = target_frame()
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = { "target:1" } }) }
		f.consumable_target.min_targets = 2
		f.consumable_target.max_targets = 2
		eq(#actions_of(acts, ois(obs, f)), 0, "too few targets")
		f.consumable_target.min_targets = 1
		f.consumable_target.max_targets = 1
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = { "target:1", "target:2" } }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "too many targets")
		f.consumable_target.max_targets = 2
		eq(#actions_of(acts, ois(obs, f)), 1, "in range")
	end)

	test("actions.select_targets.context_checks", function()
		local f = target_frame()
		f.certificates.items = { cert("SELECT_TARGETS", { target_refs = { "target:1", "target:2" } }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "select targets")
		f.context.target_selection = false
		eq(#actions_of(acts, ois(obs, f)), 0, "requires target selection")
		f.context.target_selection = true
		f.consumable_target.source_ref = nil
		eq(#actions_of(acts, ois(obs, f)), 0, "requires bound source context")
		f.consumable_target.source_ref = "consumable:1"
		eq(#actions_of(acts, ois(obs, f)), 1, "bound source restores")
	end)

	test("actions.consumable.source_ref_must_match_context", function()
		local f = target_frame()
		f.self.consumables = { entity({ center = "c_a" }), entity({ center = "c_b" }) }
		f.consumable_target.source_ref = "consumable:2"
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:1", target_refs = { "target:1" } }) }
		eq(#actions_of(acts, ois(obs, f)), 0, "mismatched source denied")
		f.certificates.items = { cert("USE_CONSUMABLE", { source_ref = "consumable:2", target_refs = { "target:1" } }) }
		eq(#actions_of(acts, ois(obs, f)), 1, "matched source allows")
	end)

	test("actions.targets.refs_must_exist", function()
		local f = target_frame()
		f.certificates.items = { cert("SELECT_TARGETS", { target_refs = { "target:9" } }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "missing target ref")
		f.certificates.items = { cert("SELECT_TARGETS", { target_refs = { "hand:1" } }) }
		eq(obs_code(obs, f), obs.CODE.BAD_TARGET_REF, "foreign zone")
	end)
end
