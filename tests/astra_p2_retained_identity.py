"""Independent real-recorder checks over synthetic trees and retained handles."""
from pathlib import Path
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(repo / 'tools'), str(repo / 'tests')]
import isolation_certificate as ic
import test_isolation_certificate as fixture


def check(kind):
    class BadSession(fixture._FakeSession):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            if kind == 'pid_mismatch':
                self.owned[0].pid += 999
            else:
                self.owned.append(fixture._FakeOwned('ai', 999))

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        data = fixture._stage_all(root)
        with fixture.synthetic_tools(root):
            for phase in ('P1A', 'P1B', 'FULL_P1'):
                result = fixture._record_phase(data, phase)
                assert result['ok'], result
            with fixture.patched(fixture, _FakeSession=BadSession):
                result = fixture._record_phase(data, 'P2_INITIAL')
        assert not result.get('ok'), (kind, 'inconsistent retained identity accepted', result)
        print('PASS', kind, result.get('problems'))


if __name__ == '__main__':
    check('pid_mismatch')
    check('extra_owned_ai')
