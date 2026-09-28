"""Independent negative claim checks; temporary synthetic evidence only."""
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import isolation_certificate as certificate
import staging


def main():
    with tempfile.TemporaryDirectory(prefix='aisp-evidence-claim-') as folder:
        # A tool's refused TCP probe and the intent to start the MP thread do
        # not prove the game's connect() has run, much less returned failure.
        record = {'nonce': 'synthetic-nonce', 'measurement_setup': {
            'kind': 'dead_port', 'dead_port': 39123, 'refused': True,
            'listener_absent': {'ipv4': True, 'ipv6': True},
            'attempts': 1, 'timings': [0.001],
        }}
        paths = staging.role_paths(Path(folder), 'ai')
        artifact = paths.data / 'Balatro' / staging.PROBE_P2
        artifact.parent.mkdir(parents=True)
        artifact.write_text(
            f'probe=p2\npatch={staging.PATCH_ID}\nnonce=synthetic-nonce\n'
            f'url=127.0.0.1\nport=39123\nsave={artifact.parent}\nmods={paths.mods}\n'
            'attempts=1\nstarted=1\n', encoding='utf-8',
        )
        result = certificate._measure_p2(Path(folder), record, SimpleNamespace(owned=[]), 39123)
        assert 'initial_failure' not in result.get('covered_subgates', []), result
        assert 'initial_failure' in result.get('pending_subgates', []), result
        print('PASS: startup intent and launcher connect refusal cannot prove MP failure')

        # A successful initial connection followed by failed reconnects exercises
        # different source branches from a failed initial connection.
        artifact.write_text(
            f'probe=p2\nschema={staging.P2_OBSERVER_SCHEMA}\npatch={staging.PATCH_ID}\n'
            f'nonce=synthetic-nonce\nurl=127.0.0.1\nport=39123\n'
            f'save={artifact.parent}\nmods={paths.mods}\n'
            'connect_attempts=4\nconnect_failures=3\nfirst_result=1\nfirst_error=nil\n'
            'first_time=100\nlast_result=none\nlast_error=connection refused\nlast_time=159\n'
            'reconnect_attempts=3\nreconnect_failures=3\nreconnects=1\n'
            'keepalive_failures=1\ncloses=0\n', encoding='utf-8',
        )
        result = certificate._measure_p2(Path(folder), record, SimpleNamespace(owned=[]), 39123)
        assert 'initial_failure' not in result.get('covered_subgates', []), result
        assert 'initial_failure' in result.get('pending_subgates', []), result
        print('PASS: reconnect failure cannot substitute for initial connection failure')

        # Initial failure, then manual connection, then only the first failed
        # retry. The original bounded reconnect cycle has not finished yet.
        text = artifact.read_text(encoding='utf-8')
        for before, after in (
            ('connect_attempts=4\n', 'connect_attempts=3\n'),
            ('connect_failures=3\n', 'connect_failures=2\n'),
            ('first_result=1\n', 'first_result=none\n'),
            ('first_error=nil\n', 'first_error=connection refused\n'),
            ('reconnect_attempts=3\n', 'reconnect_attempts=1\n'),
            ('reconnect_failures=3\n', 'reconnect_failures=1\n'),
            ('reconnects=1\n', 'reconnects=0\n'),
        ):
            text = text.replace('\n' + before, '\n' + after)
        artifact.write_text(text, encoding='utf-8')
        result = certificate._measure_p2(Path(folder), record, SimpleNamespace(owned=[]), 39123)
        assert 'reconnect' not in result.get('covered_subgates', []), result
        assert 'reconnect' in result.get('pending_subgates', []), result
        print('PASS: unfinished reconnect cycle cannot satisfy bounded retry coverage')


if __name__ == '__main__':
    main()
