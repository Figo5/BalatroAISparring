return function()
	local Codec = new_ai().Codec
	local CODE = Codec.CODE

	test("codec.enc.scalars", function()
		eq(Codec.encode(true), "b1", "true")
		eq(Codec.encode(false), "b0", "false")
		eq(Codec.encode(5), "i5;", "int")
		eq(Codec.encode(-3), "i-3;", "negative")
		eq(Codec.encode(0), "i0;", "zero")
		eq(Codec.encode("a"), "s1:a;", "string")
		eq(Codec.encode(""), "s0:;", "empty string")
	end)

	test("codec.enc.arrays", function()
		eq(Codec.encode({}), "a0:", "empty")
		eq(Codec.encode({ 1, 2, 3 }), "a3:i1;i2;i3;", "ints")
		eq(Codec.encode({ "x", "y" }), "a2:s1:x;s1:y;", "strings")
	end)

	test("codec.enc.map_sorted_by_encoded_key", function()
		eq(Codec.encode({ b = 1, a = "x" }), "o2:s1:a;s1:x;s1:b;i1;", "map")
		eq(Codec.encode({}), "a0:", "empty table is array")
	end)

	test("codec.enc.insertion_order_invariant", function()
		eq(Codec.encode({ a = 1, b = 2, c = 3 }), Codec.encode({ c = 3, a = 1, b = 2 }), "order")
	end)

	test("codec.enc.nested", function()
		eq(Codec.encode({ list = { 1, 2 }, flag = true }), "o2:s4:flag;b1s4:list;a2:i1;i2;", "nested")
	end)

	test("codec.enc.int_bounds", function()
		eq(Codec.encode(2147483647), "i2147483647;", "max")
		eq(Codec.encode(-2147483648), "i-2147483648;", "min")
		eq(Codec.encode(2147483648), nil, "over max")
		eq(Codec.encode(-2147483649), nil, "under min")
		eq(select(2, Codec.encode(2147483648)), CODE.BAD_NUMBER, "over code")
	end)

	test("codec.enc.rejects_nonfinite_and_fractional", function()
		local nan = 0 / 0
		eq(Codec.encode(nan), nil, "nan")
		eq(Codec.encode(math.huge), nil, "inf")
		eq(Codec.encode(-math.huge), nil, "neg inf")
		eq(Codec.encode(1.5), nil, "fraction")
		eq(select(2, Codec.encode(1.5)), CODE.BAD_NUMBER, "fraction code")
	end)

	test("codec.enc.rejects_functions_metatables_cycles", function()
		eq(select(2, Codec.encode(function() end)), CODE.BAD_TYPE, "function")
		eq(select(2, Codec.encode(setmetatable({}, {}))), CODE.BAD_TYPE, "metatable")
		local cyclic = {}
		cyclic.self = cyclic
		eq(select(2, Codec.encode(cyclic)), CODE.CYCLE, "cycle")
	end)

	test("codec.enc.rejects_nonprimitive_keys", function()
		local t = {}
		t[{}] = 1
		eq(select(2, Codec.encode(t)), CODE.BAD_KEY, "table key")
	end)

	test("codec.enc.string_framing_unambiguous", function()
		eq(Codec.encode("a;b"), "s3:a;b;", "semicolon")
		eq(Codec.encode("a:b"), "s3:a:b;", "colon")
		eq(Codec.encode("a\0b"), "s3:a\0b;", "nul")
		local uni = "\195\169"
		eq(Codec.encode(uni), "s2:" .. uni .. ";", "utf8 bytes")
	end)

	test("codec.enc.oversize_bounded", function()
		local big_array = {}
		for i = 1, 300 do
			big_array[i] = i
		end
		eq(select(2, Codec.encode(big_array)), CODE.TOO_LARGE, "big array")
		local big_map = {}
		for i = 1, 300 do
			big_map["k" .. i] = i
		end
		eq(select(2, Codec.encode(big_map)), CODE.TOO_LARGE, "big map")
	end)

	test("codec.hash.known_vector_and_stability", function()
		eq(Codec.hash_string(""), "811c9dc5", "empty fnv")
		eq(Codec.hash_string("abc"), Codec.hash_string("abc"), "stable")
		eq(Codec.hash_string(123), nil, "nonstring")
	end)

	test("codec.hash.equal_matches_canonical", function()
		truthy(Codec.equal({ a = 1, b = 2 }, { b = 2, a = 1 }), "equal maps")
		falsy(Codec.equal({ a = 1 }, { a = 2 }), "different")
		falsy(Codec.equal(function() end, function() end), "unencodable")
	end)
end
