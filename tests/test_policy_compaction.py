#!/usr/bin/env python3
"""Prove text compaction preserves all Lua 5.1 executable bytecode.

The parser follows Lua's published 5.1 dump format. Only source locations,
local names and upvalue debug names are excluded; instructions, constants,
calling convention, register counts and nested prototypes must match exactly.
Primary format reference: https://www.lua.org/source/5.1/ldump.c.html
"""
import argparse
import importlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class Chunk:
    def __init__(self, data):
        self.data, self.pos = data, 0
        header = self.read(12)
        assert header[:6] == b"\x1bLua\x51\x00"
        self.order = "little" if header[6] else "big"
        self.int_size, self.size_size, self.op_size, self.num_size = header[7:11]
        assert self.int_size in (4, 8) and self.size_size in (4, 8)

    def read(self, n):
        assert 0 <= n <= len(self.data) - self.pos
        result = self.data[self.pos:self.pos + n]
        self.pos += n
        return result

    def integer(self, size=None):
        return int.from_bytes(self.read(size or self.int_size), self.order)

    def string(self):
        n = self.integer(self.size_size)
        if n == 0:
            return None
        data = self.read(n)
        assert data[-1:] == b"\0"
        return data[:-1]

    def prototype(self):
        self.string()  # Source label.
        self.read(2 * self.int_size)  # First/last source line.
        parameters = self.read(4)  # Upvalues, parameters, varargs, registers.
        instructions = self.read(self.integer() * self.op_size)
        constants = []
        for _ in range(self.integer()):
            tag = self.read(1)[0]
            assert tag in (0, 1, 3, 4)
            value = None if tag == 0 else self.read(1) if tag == 1 else self.read(self.num_size) if tag == 3 else self.string()
            constants.append((tag, value))
        children = [self.prototype() for _ in range(self.integer())]
        self.read(self.integer() * self.int_size)  # Line table.
        for _ in range(self.integer()):
            self.string()
            self.read(2 * self.int_size)  # Local variable PC range.
        for _ in range(self.integer()):
            self.string()  # Upvalue debug name.
        return parameters, instructions, constants, children

    def executable(self):
        result = self.prototype()
        assert self.pos == len(self.data)
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-all", action="store_true")
    required = parser.parse_args().require_all
    try:
        module = importlib.import_module("lupa.lua51")
    except ImportError:
        assert not required, "Lua 5.1 required for bytecode proof"
        print("SKIP Lua 5.1 unavailable")
        return
    lua = module.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    policy = lua.execute((REPO / "AISparring/ai/baseline_policy.lua").read_bytes())
    dump = lua.eval(b"function(source) return string.dump(assert(loadstring(source,'=policy'))) end")
    for name in (b"rookie", b"competitive", b"major_league", b"expert"):
        compact = policy[b"source"](name)
        readable = policy[b"readable_source"](name)
        expected = Chunk(dump(readable)).executable()
        assert Chunk(dump(compact)).executable() == expected, name
        # A changed operator or literal must fail even when debug data differ.
        damaged = compact.replace(b"local WORK=0", b"local WORK=1", 1)
        assert damaged != compact and Chunk(dump(damaged)).executable() != expected
        print(f"PASS {name.decode()}: every instruction, constant and prototype preserved; {len(compact)} source bytes")


if __name__ == "__main__":
    main()
