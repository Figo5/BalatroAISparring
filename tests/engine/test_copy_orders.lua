return function(ctx)
	local s, b = ctx.support, ctx.support.bundle(ctx.repo_root)
	local function orders(center, hidden, pinned)
		local jokers={}
		for i=1,5 do jokers[i]=s.card({set="Joker",center=i==5 and center or "j_joker",area_type="joker"}) end
		if hidden then jokers[5].facing="back" end
		if pinned then jokers[2].pinned=true end
		local engine=s.engine({state=s.STATES.SHOP,jokers=jokers})
		local step=assert(s.pipeline(b,engine,{}).adapter.step())
		local handle=assert(b.reader.capture(step.runtime,step.ui_view))
		local seen={}; local count=0
		for _,a in ipairs(b.actions.generate(handle)) do if a.type=="REORDER_JOKERS" then
			local key=table.concat(a.order,","); ctx.eq(seen[key],nil,"unique permutation")
			ctx.is_true(key~="joker:1,joker:2,joker:3,joker:4,joker:5","no-op omitted")
			seen[key]=true; count=count+1
		end end
		return seen,count
	end
	ctx.test("copy_targets_are_offered_as_real_legal_permutations",function()
		local seen=orders("j_blueprint")
		ctx.eq(seen["joker:5,joker:1,joker:2,joker:3,joker:4"],true,"copy first target")
		ctx.eq(seen["joker:2,joker:3,joker:4,joker:5,joker:1"],true,"copy pair at end")
		seen=orders("j_brainstorm")
		ctx.eq(seen["joker:4,joker:1,joker:2,joker:3,joker:5"],true,"copy moved first target")
	end)
	ctx.test("hidden_copy_identity_cannot_change_permutation_catalog",function()
		local a=orders("j_blueprint",true); local b=orders("j_brainstorm",true)
		local c=orders("j_joker",true)
		for key in pairs(a) do ctx.eq(b[key],true);ctx.eq(c[key],true) end
		for key in pairs(c) do ctx.eq(a[key],true);ctx.eq(b[key],true) end
	end)
	ctx.test("engine_pinned_cards_keep_copy_orders_unavailable",function()
		local _,count=orders("j_blueprint",false,true);ctx.eq(count,0)
	end)
end
