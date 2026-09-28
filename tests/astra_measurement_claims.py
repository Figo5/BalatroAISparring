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


if __name__ == '__main__':
    main()
