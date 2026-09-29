"""Independent phase PID cardinality checks; synthetic, no game/files/processes."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import isolation_certificate as ic


if __name__ == '__main__':
    for phase in ic.P2_PHASES:
        valid = {'roles': ['ai'], 'pids': {'ai': [100]}}
        assert not ic._receipt_role_problems(phase, valid), phase
        for name, pids in (
            ('extra_human', {'ai': [100], 'human': [101]}),
            ('two_distinct_ai_processes', {'ai': [100, 101]}),
            ('duplicate_pid', {'ai': [100, 100]}),
            ('missing_ai', {}),
        ):
            result = ic._receipt_role_problems(phase, {'roles': ['ai'], 'pids': pids})
            assert result, (phase, name, 'invalid role process set accepted')
        print('PASS', phase, 'one AI accepted; extra/multiple/duplicate/missing processes refused')
