"""A SILENT receipt must prove the peer stayed open through retry exhaustion."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import isolation_certificate as ic

def main():
    cycle = {'cause': 'keepalive', 'start_time': 145.0, 'outcome': 'exhausted',
             'end_time': 159.0, 'attempts': [
                 {'start': 147.0, 'time': 147.0, 'result': 'none'},
                 {'start': 151.0, 'time': 151.0, 'result': 'none'},
                 {'start': 159.0, 'time': 159.0, 'result': 'none'}]}
    observed = {'schema_ok': True, 'first_result': '1', 'first_success_time': 100.0,
                'cycles': [cycle], 'receive_errors': [],
                'keepalive_push_times': [120.0,125.0,130.0,135.0,140.0]}
    failures = 0
    valid = {'accepted': 1, 'peer_is_owned_ai': True, 'sent_bytes': 0,
             'closed': False, 'fin': False, 'peer_reset': False,
             'peer_eof': True, 'eof_time': 145.0, 'open_until': 160.0}
    baseline = ic._p2_phase_coverage('P2_SILENT', observed, valid)
    assert 'keepalive' in baseline['covered'], ('invalid positive control', baseline)
    for name, end in [('missing_hold_evidence', None), ('released_before_exhaustion', 101.0)]:
        listener = dict(valid, open_until=end)
        result = ic._p2_phase_coverage('P2_SILENT', observed, listener)
        if 'keepalive' in result['covered']:
            failures += 1
            print('FAIL', name, result)
        else:
            print('PASS', name)
    return bool(failures)

if __name__ == '__main__':
    sys.exit(main())
