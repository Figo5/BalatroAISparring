-- Targeted Tarots on hand cards (docs/HAND_TARGETS_DESIGN.md): the adapter
-- certifies USE_CONSUMABLE_ON_HAND for the v1 allowlist only, on visible
-- targets the effect would change, and none while a card is force-selected;
-- the executor highlights exactly the targets, lets the engine predicate
-- decide and clears the highlight on any failure.
return function(ctx)
	local test = ctx.test
	local eq = ctx.eq
	local is_true = ctx.is_true
	local support = ctx.support
	local bundle = support.bundle(ctx.repo_root)
	local STATES = support.STATES

	local function tarot(center, max_h, min_h)
		return support.card({
			set = "Tarot", consumeable = true, center = center, center_set = "Tarot",
			consumeable_data = { max_highlighted = max_h, min_highlighted = min_h },
		})
	end

	local function hand()
		local stone = support.card({ rank = "5", suit = "Clubs", center = "m_stone" })
		stone.ability.effect = "Stone Card"
		stone.config.center.replace_base_card = true
		return {
			support.card({ rank = "King", suit = "Hearts", center = "c_base" }),
			support.card({ rank = "9", suit = "Spades", center = "c_base" }),
			support.card({ rank = "4", suit = "Hearts", center = "c_base", facing = "back", sprite_facing = "back" }),
			stone,
			support.card({ rank = "2", suit = "Diamonds", center = "m_bonus" }),
		}
	end

	local function uses(consumeables, cards, opts)
		opts = opts or {}
		local engine = support.engine({ hand = cards or hand(), consumeables = consumeables, state = opts.state })
		local result, code = support.pipeline(bundle, engine, {}).adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		local handle = assert(bundle.reader.capture(result.runtime, result.ui_view))
		local out = {}
		for _, a in ipairs(bundle.actions.generate(handle)) do
			if a.type == "USE_CONSUMABLE_ON_HAND" then
				out[#out + 1] = a.source_ref .. "=" .. table.concat(a.card_refs, "+")
			end
		end
		table.sort(out)
		return table.concat(out, " ")
	end

	test("adapter_offers_allowlisted_tarots_on_visible_targets", function()
		-- Strength: every visible card (never the face-down one or the Stone).
		eq(uses({ tarot("c_strength", 2) }), "consumable:1=hand:1 consumable:1=hand:2 consumable:1=hand:5", "strength")
		-- Death: pairs of visible cards, lower position first.
		eq(uses({ tarot("c_death", 2, 2) }),
			"consumable:1=hand:1+hand:2 consumable:1=hand:1+hand:5 consumable:1=hand:2+hand:5", "death")
		-- The Sun: not on a card already of Hearts.
		eq(uses({ tarot("c_sun", 3) }), "consumable:1=hand:2 consumable:1=hand:5", "sun")
		-- Justice: not on an already-enhanced card (the Bonus 2).
		eq(uses({ tarot("c_justice", 1) }), "consumable:1=hand:1 consumable:1=hand:2", "justice")
		-- Outside the allowlist: nothing.
		eq(uses({ tarot("c_hanged_man", 2) }), "", "hanged man")
		eq(uses({ tarot("c_tower", 1) }), "", "tower")
	end)

	test("adapter_offers_none_when_forced_debuffed_or_outside_the_hand_phase", function()
		local cards = hand()
		cards[1].ability.forced_selection = true
		eq(uses({ tarot("c_strength", 2) }, cards), "", "forced card")
		local debuffed = tarot("c_strength", 2)
		debuffed.debuff = true
		eq(uses({ debuffed }), "", "debuffed tarot")
		eq(uses({ tarot("c_strength", 2) }, nil, { state = STATES.SHOP }), "", "shop")
	end)

	local function executor(consumeable, cards, logger)
		local engine = support.engine({ hand = cards, consumeables = { consumeable } })
		local pipeline = support.pipeline(bundle, engine, { logger = logger })
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local list = engine.G.consumeables.cards
			for i = #list, 1, -1 do
				if list[i] == e.config.ref_table then
					table.remove(list, i)
				end
			end
		end
		return engine, pipeline.executor
	end

	local function plain_hand()
		return {
			support.card({ rank = "King", suit = "Hearts" }),
			support.card({ rank = "9", suit = "Spades" }),
			support.card({ rank = "2", suit = "Clubs" }),
		}
	end

	test("executor_highlights_exactly_then_uses", function()
		local cards = plain_hand()
		local engine, ex = executor(tarot("c_death", 2, 2), cards)
		engine.G.hand.highlighted = { cards[3] }
		local action = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1", "hand:2" }, id = "death" }
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch")
		eq(engine.calls[#engine.calls].name, "use_card")
		eq(#engine.G.hand.highlighted, 2)
		eq(engine.G.hand.highlighted[1], cards[1])
		eq(engine.G.hand.highlighted[2], cards[2])
	end)

	test("executor_clears_the_highlight_when_the_engine_refuses", function()
		local refused = tarot("c_strength", 2)
		refused._usable = false
		local engine, ex = executor(refused, plain_hand())
		local action = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:2" }, id = "refused" }
		is_true(ex.validate(action) == true, "validate")
		local ok, code = ex.dispatch(action)
		eq(ok, nil, "refused")
		eq(code, "exec_illegal", "code")
		eq(#engine.G.hand.highlighted, 0, "highlight cleared")
		-- A no-op use (source still held) is a clean failure, highlight cleared.
		local engine2, ex2 = executor(tarot("c_strength", 2), plain_hand())
		engine2.G.FUNCS.use_card = function() end
		local noop = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "noop" }
		is_true(ex2.validate(noop) == true, "validate noop")
		eq(ex2.dispatch(noop), nil, "noop refused")
		eq(#engine2.G.hand.highlighted, 0, "noop highlight cleared")
	end)

	test("executor_refuses_forced_oversized_or_out_of_bounds_selections", function()
		local cards = plain_hand()
		cards[3].ability.forced_selection = true
		local _, ex = executor(tarot("c_strength", 2), cards)
		local forced = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "forced" }
		eq(ex.validate(forced), nil, "forced card present")
		local _, ex2 = executor(tarot("c_strength", 2), plain_hand())
		local three = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1", "hand:2", "hand:3" }, id = "three" }
		eq(ex2.validate(three), nil, "three targets")
		local _, ex3 = executor(tarot("c_death", 2, 2), plain_hand())
		local one = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "one" }
		eq(ex3.validate(one), nil, "death needs two")
		-- The v1 shape is mirrored exactly: a non-Death Tarot is a singleton.
		local _, ex4 = executor(tarot("c_strength", 2), plain_hand())
		local two = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1", "hand:2" }, id = "two" }
		eq(ex4.validate(two), nil, "strength is a singleton")
	end)

	test("executor_refuses_hidden_or_off_allowlist_sources", function()
		local single = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:2" }, id = "single" }
		-- Off the allowlist (vanilla Hanged Man): refused from the engine truth.
		local _, ex = executor(tarot("c_hanged_man", 2), plain_hand())
		eq(ex.validate(single), nil, "off-allowlist source")
		-- A face-down source.
		local hidden = tarot("c_strength", 2)
		hidden.facing, hidden.sprite_facing = "back", "back"
		local _, ex2 = executor(hidden, plain_hand())
		eq(ex2.validate(single), nil, "face-down source")
		-- A debuffed source.
		local debuffed = tarot("c_strength", 2)
		debuffed.debuff = true
		local _, ex3 = executor(debuffed, plain_hand())
		eq(ex3.validate(single), nil, "debuffed source")
	end)

	test("executor_refuses_hidden_stone_masked_or_debuffed_targets", function()
		local single = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:2" }, id = "single" }
		local first = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "first" }

		local hidden = plain_hand()
		hidden[2].facing, hidden[2].sprite_facing = "back", "back"
		local _, ex = executor(tarot("c_strength", 2), hidden)
		eq(ex.validate(single), nil, "face-down target")

		local stone = support.card({ rank = "5", suit = "Clubs", center = "m_stone" })
		stone.ability.effect = "Stone Card"
		stone.config.center.replace_base_card = true
		local _, ex2 = executor(tarot("c_strength", 2), { stone, support.card({ rank = "9", suit = "Spades" }) })
		eq(ex2.validate(first), nil, "Stone target")

		local masked = support.card({ rank = "9", suit = "Spades" })
		masked.config.center.no_rank = true
		local _, ex3 = executor(tarot("c_strength", 2), { masked })
		eq(ex3.validate(first), nil, "no-rank masked target")

		local debuffed = plain_hand()
		debuffed[1].debuff = true
		local _, ex4 = executor(tarot("c_strength", 2), debuffed)
		eq(ex4.validate(first), nil, "debuffed target")
	end)

	test("executor_restricts_enhancements_to_base_cards", function()
		local action = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:1" }, id = "enhance" }
		local enhanced = { support.card({ rank = "9", suit = "Spades", center = "m_bonus" }) }
		local _, ex = executor(tarot("c_justice", 1), enhanced)
		eq(ex.validate(action), nil, "already-enhanced non-base card")
		local base = { support.card({ rank = "9", suit = "Spades", center = "c_base" }) }
		local _, ex2 = executor(tarot("c_justice", 1), base)
		is_true(ex2.validate(action) == true, "base card accepted")
	end)

	test("end_to_end_forged_and_stale_use_on_hand_are_refused", function()
		local cards = plain_hand()
		local engine, ex = executor(tarot("c_strength", 2), cards)
		local certified = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:2" }, id = "ok" }
		is_true(ex.validate(certified) == true, "certified action validates")
		-- Forged: an out-of-range hand target the adapter never certified.
		local forged = { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = { "hand:9" }, id = "forged" }
		eq(ex.validate(forged), nil, "forged target refused")
		-- Stale: the hand changes after validation, so dispatch is refused and
		-- the engine callback never runs.
		is_true(ex.validate(certified) == true, "validate before mutation")
		engine.G.hand.cards[2] = support.card({ rank = "3", suit = "Clubs" })
		local calls_before = #engine.calls
		local ok, code = ex.dispatch(certified)
		eq(ok, nil, "stale refused")
		is_true(code == "exec_stale_revision" or code == "exec_unknown_ref", tostring(code))
		eq(#engine.calls, calls_before, "no engine call on a stale action")
	end)

	test("reorders_are_reserved_when_tarots_fill_the_certificate_cap", function()
		-- A 12-card hand, 8 Jokers and the three held Tarots that hit the cap
		-- (docs/CLAUDE_BATCH3_REVIEW.md L2): play/discard capacity and the Tarot
		-- bounds are unchanged, and a few Joker reorders survive the cap.
		local ranks = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King" }
		local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
		local cards = {}
		for i = 1, 12 do
			cards[i] = support.card({ rank = ranks[((i - 1) % 12) + 1], suit = suits[((i - 1) % 4) + 1] })
		end
		local jokers = {}
		for i = 1, 8 do
			jokers[i] = support.card({ set = "Joker", center = "j_joker", area_type = "joker" })
		end
		local engine = support.engine({
			hand = cards, hand_limit = 12, jokers = jokers, joker_slots = 8,
			consumeables = { tarot("c_death", 2, 2), tarot("c_strength", 2), tarot("c_sun", 3) },
			consumable_slots = 3,
		})
		local pipeline = support.pipeline(bundle, engine, {})
		local result, code = pipeline.adapter.step()
		is_true(result ~= nil, "adapter: " .. tostring(code))
		local counts, total = {}, 0
		for _, item in ipairs(result.ui_view.certificates.items) do
			counts[item.type] = (counts[item.type] or 0) + 1
			total = total + 1
		end
		is_true(total <= 120, "cap respected: " .. total)
		is_true((counts.PLAY_CARDS or 0) >= 36, "play capacity kept: " .. tostring(counts.PLAY_CARDS))
		is_true((counts.DISCARD_CARDS or 0) >= 36, "discard capacity kept: " .. tostring(counts.DISCARD_CARDS))
		eq(counts.USE_CONSUMABLE_ON_HAND, 24, "Tarot bounds preserved")
		is_true((counts.REORDER_JOKERS or 0) > 0, "Joker reorders reserved")
	end)

	local function recorder()
		local records = {}
		return { records = records, record = function(fields) records[#records + 1] = fields end }
	end

	-- The actual production path: `core.lua:build_companion_logger` forwards the
	-- record to `src/logger.lua`, whose primitive/field allowlist decides what
	-- reaches the line. Loading the real module here is the regression that the
	-- table recorder alone could not catch.
	local function production_logger(repo_root)
		local Logger = dofile(repo_root .. "/AISparring/src/logger.lua")
		local lines = {}
		local inner = Logger.new(function(_, line) lines[#lines + 1] = line end)
		return {
			lines = lines,
			record = function(fields)
				local event = type(fields) == "table" and fields.event or nil
				if type(event) ~= "string" or event == "" then
					event = "companion"
				end
				return inner:log("info", event, fields)
			end,
		}
	end

	local function use_action(id, refs)
		return { type = "USE_CONSUMABLE_ON_HAND", source_ref = "consumable:1", card_refs = refs, id = id }
	end

	test("executor_logs_a_bounded_record_the_production_logger_can_format", function()
		local logger = recorder()
		local engine, ex = executor(tarot("c_strength", 2), plain_hand(), logger)
		-- Vanilla's use unhighlights on success; the fixture callback stands in.
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local list = engine.G.consumeables.cards
			for i = #list, 1, -1 do
				if list[i] == e.config.ref_table then
					table.remove(list, i)
				end
			end
			engine.G.hand:unhighlight_all()
		end
		local action = use_action("log", { "hand:2" })
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch")
		eq(#logger.records, 1, "one record")
		local row = logger.records[1]
		eq(row.event, "use_consumable_on_hand")
		eq(row.code, "exec_ok", "execution outcome")
		eq(row.action, "c_strength", "allowlisted Tarot identity")
		eq(row.count, 1, "target count")
		is_true(row.detail:find("src=consumable:1", 1, true) ~= nil, "source position")
		is_true(row.detail:find("refs=hand:2", 1, true) ~= nil, "ordered target position")
		is_true(row.detail:find("highlight=cleared", 1, true) ~= nil, "actual cleanup")
		-- Only the bounded, allowlisted primitive fields; no hidden card value
		-- and no arbitrary table can reach the logger.
		eq(row.rank, nil)
		eq(row.suit, nil)
		eq(row.center, nil)
		eq(row.card_refs, nil)
		eq(row.outcome, nil)
		eq(row.id, nil)
	end)

	test("production_logger_keeps_the_tarot_record_details", function()
		local plog = production_logger(ctx.repo_root)
		local engine, ex = executor(tarot("c_death", 2, 2), plain_hand(), plog)
		local record = engine.G.FUNCS.use_card
		engine.G.FUNCS.use_card = function(e)
			record(e)
			local list = engine.G.consumeables.cards
			for i = #list, 1, -1 do
				if list[i] == e.config.ref_table then
					table.remove(list, i)
				end
			end
			engine.G.hand:unhighlight_all()
		end
		local action = use_action("log", { "hand:1", "hand:2" })
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch")
		eq(#plog.lines, 1, "one production line")
		local line = plog.lines[1]
		is_true(line:find("use_consumable_on_hand", 1, true) ~= nil, "event: " .. line)
		is_true(line:find('action="c_death"', 1, true) ~= nil, "identity: " .. line)
		is_true(line:find('code="exec_ok"', 1, true) ~= nil, "outcome: " .. line)
		is_true(line:find('count="2"', 1, true) ~= nil, "count: " .. line)
		is_true(line:find("src=consumable:1", 1, true) ~= nil, "source: " .. line)
		is_true(line:find("refs=hand:1,hand:2", 1, true) ~= nil, "ordered refs: " .. line)
		is_true(line:find("highlight=cleared", 1, true) ~= nil, "cleanup: " .. line)
	end)

	test("executor_logs_a_refused_use_and_omits_hidden_or_off_allowlist_identity", function()
		local logger = recorder()
		local refused = tarot("c_strength", 2)
		refused._usable = false
		local engine, ex = executor(refused, plain_hand(), logger)
		local action = use_action("refused", { "hand:1" })
		is_true(ex.validate(action) == true, "validate")
		eq(ex.dispatch(action), nil, "engine refuses")
		eq(logger.records[1].code, "exec_illegal")
		is_true(logger.records[1].detail:find("highlight=cleared", 1, true) ~= nil, "highlight cleared on refusal")

		-- An off-allowlist source is refused and never named.
		local off_logger = recorder()
		local _, off_ex = executor(tarot("c_hanged_man", 2), plain_hand(), off_logger)
		off_ex.dispatch(action)
		eq(off_logger.records[1].code, "exec_illegal")
		eq(off_logger.records[1].action, nil, "off-allowlist identity omitted")

		-- A face-down source is refused and its center is never read.
		local hidden = tarot("c_strength", 2)
		hidden.facing, hidden.sprite_facing = "back", "back"
		local hidden_logger = recorder()
		local _, hidden_ex = executor(hidden, plain_hand(), hidden_logger)
		hidden_ex.dispatch(action)
		eq(hidden_logger.records[1].code, "exec_illegal")
		eq(hidden_logger.records[1].action, nil, "hidden identity omitted")
	end)

	test("executor_log_trace_normalizes_forged_oversized_and_table_refs", function()
		local logger = recorder()
		local _, ex = executor(tarot("c_strength", 2), plain_hand(), logger)
		local action = {
			type = "USE_CONSUMABLE_ON_HAND",
			source_ref = { forged = true },
			card_refs = { { forged = true }, "hand:1", string.rep("x", 500), "consumable:2", "hand:2" },
			id = "forged",
		}
		ex.validate(action)
		ex.dispatch(action)
		local row = logger.records[1]
		eq(row.code, "exec_illegal", "forged action refused")
		eq(row.action, nil, "no identity for a forged source")
		eq(row.count, 2, "only the two valid hand refs counted")
		is_true(row.detail:find("src=none", 1, true) ~= nil, "table source omitted")
		is_true(row.detail:find("refs=hand:1,hand:2", 1, true) ~= nil, "valid refs normalized in order")
		is_true(row.detail:find("xxxx", 1, true) == nil, "oversized ref omitted")
		is_true(row.detail:find("consumable:2", 1, true) == nil, "wrong-zone ref omitted")
		-- The whole detail stays well inside the logger's 96-byte string cap.
		is_true(#row.detail <= 96, "detail bounded: " .. #row.detail)
	end)

	test("a_throwing_or_malformed_logger_never_affects_the_decision", function()
		local bad = { record = function() error("logger boom") end }
		local engine, ex = executor(tarot("c_strength", 2), plain_hand(), bad)
		local action = use_action("throw", { "hand:1" })
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch survives a throwing logger")
		eq(engine.calls[#engine.calls].name, "use_card")

		-- A logger that returns nonsense is equally harmless.
		local weird = { record = function() return "not-a-record" end }
		local engine2, ex2 = executor(tarot("c_strength", 2), plain_hand(), weird)
		local action2 = use_action("weird", { "hand:1" })
		is_true(ex2.validate(action2) == true, "validate weird")
		is_true(ex2.dispatch(action2) == true, "dispatch survives a malformed logger")
		eq(engine2.calls[#engine2.calls].name, "use_card")
	end)

	test("production_log_reports_the_dispatch_time_highlight_then_settles", function()
		-- L-a: vanilla's `use_card` queues its `unhighlight_all` (card.lua:1150),
		-- so on success the executor's line legitimately records the highlight
		-- still present. It must not claim settled cleanup; the later queued
		-- engine event settles it. This drives the real src/logger.lua bridge.
		local plog = production_logger(ctx.repo_root)
		local engine, ex = executor(tarot("c_strength", 2), plain_hand(), plog)
		-- The default executor fixture leaves the highlight through return,
		-- exactly like the queued vanilla callback.
		local action = use_action("queued", { "hand:2" })
		is_true(ex.validate(action) == true, "validate")
		is_true(ex.dispatch(action) == true, "dispatch")
		eq(#plog.lines, 1, "one production line")
		local line = plog.lines[1]
		is_true(line:find('code="exec_ok"', 1, true) ~= nil, "outcome: " .. line)
		is_true(line:find("highlight=kept", 1, true) ~= nil, "dispatch-time state: " .. line)
		is_true(line:find("highlight=cleared", 1, true) == nil, "no settled-cleanup claim: " .. line)
		eq(#engine.G.hand.highlighted, 1, "highlight present at log time")
		-- The later modeled engine event performs the queued cleanup.
		engine.G.hand:unhighlight_all()
		eq(#engine.G.hand.highlighted, 0, "settled cleanup")
	end)
end
