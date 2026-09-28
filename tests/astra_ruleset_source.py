"""Independent parity against the pinned, locally held Major League Lua source.

No game, network, live files, or gameplay state is used. Proprietary/dependency
sources remain ignored; absence of that local reference is a failed gate.
"""
from pathlib import Path
import importlib
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ruleset_contract
import practice_service


def main():
    source = (ROOT / "work/reference/mp/rulesets/majorleague.lua").read_text(encoding="utf-8")
    parsed = ruleset_contract.parse_ruleset_source(source)
    assert parsed["ok"], parsed
    expected = practice_service.major_league_digest(
        parsed["ruleset_id"], parsed["gamemode"], parsed["forced_options"]
    )
    for name in ("lua51", "luajit21"):
        lua = importlib.import_module("lupa." + name).LuaRuntime(unpack_returned_tuples=True)
        lua.globals().ROOT = ROOT.as_posix()
        execute = lua.eval('''function(source)
          local entry
          local mp = {LOBBY={config={}}}
          mp.Ruleset=function(value)
            entry=value
            value.inject=function() end
            return value
          end
          local f=assert(loadstring(source))
          setfenv(f,{MP=mp})
          f()
          assert(entry:force_lobby_options()==true)
          return mp,entry
        end''')
        mp, entry = execute(source)
        actual = dict(mp["LOBBY"]["config"].items())
        assert actual == parsed["forced_options"], (name, actual, parsed)
        assert entry["forced_gamemode"] == parsed["gamemode"]
        codec = lua.execute("return dofile(ROOT..'/AISparring/ai/codec.lua')")
        canonical = parsed["ruleset_id"] + "|" + parsed["gamemode"]
        for key, value in sorted(actual.items()):
            text = str(value).lower() if isinstance(value, bool) else str(int(value)) if isinstance(value, (int, float)) else value
            canonical += "|" + key + "=" + text
        assert codec["hash_string"](canonical) == expected
        print(f"PASS {name}: actual Major League force_lobby_options and Python/Lua digest agree ({expected})")
    print("2 source-derived parity checks passed; no actual-engine claim")
    return 0


if __name__ == "__main__":
    sys.exit(main())
