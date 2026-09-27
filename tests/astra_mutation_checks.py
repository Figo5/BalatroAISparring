"""Prove the property oracle catches broken legality checks; mutate memory only."""
import importlib
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MUTATIONS = {
    'ignore_affordability': ('if not affordable(obs, item.cost, false) then', 'if false then'),
    'ignore_joker_capacity': ('if not capacity_ok(item, cert, obs, "jokers", "joker_slots") then', 'if false then'),
    'ignore_hands_remaining': ('if type(self.hands) ~= "number" or self.hands <= 0 then', 'if false then'),
}

def main():
    harness = runpy.run_path(str(ROOT / 'tests' / 'run_m2.py'))
    source = (ROOT / 'AISparring/ai/actions.lua').read_text(encoding='utf-8')
    runner = (ROOT / 'tests/m2/runner.lua').read_text(encoding='utf-8')
    failures = 0
    for runtime in ('lua51', 'luajit21'):
        factory = importlib.import_module('lupa.' + runtime).LuaRuntime
        for name, (old, replacement) in MUTATIONS.items():
            if old not in source:
                raise AssertionError('mutation anchor missing: ' + name)
            mutant = source.replace(old, replacement, 1)
            def mutated_factory(**kwargs):
                lua = factory(**kwargs)
                lua.globals().astra_mutant = mutant
                lua.execute('''
                    local original = loadfile
                    function loadfile(path)
                        if string.sub(path, -25) == 'AISparring/ai/actions.lua' then
                            return loadstring(astra_mutant, '=astra-mutant')
                        end
                        return original(path)
                    end
                ''')
                return lua
            result = harness['run_file'](mutated_factory, runner, ROOT / 'tests/m2/test_property.lua')
            caught = result['error'] is None and any(not row['ok'] for row in result['cases'])
            print('PASS' if caught else 'FAIL', runtime, name, 'oracle rejected mutant' if caught else 'mutant survived')
            failures += not caught
    print(f'Unique mutation checks: {len(MUTATIONS)}; executions: {len(MUTATIONS)*2}; failures: {failures}')
    return bool(failures)

if __name__ == '__main__':
    raise SystemExit(main())
