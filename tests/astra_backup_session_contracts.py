"""Independent real backup API -> session preparation checks on synthetic temp trees."""
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import isolation_certificate as certificate
import launch_practice as launcher


class EmptyEnumerator(launcher.ProcessEnumerator):
    def list(self):
        return []


def fixture(root):
    install = root / 'fake-install'
    appdata = root / 'fake-appdata'
    steam = root / 'fake-steam' / '12345' / '2379780'
    for folder in (install, appdata, steam):
        folder.mkdir(parents=True)
        (folder / 'fixture.txt').write_text('synthetic only', encoding='utf-8')
    backup = root / 'backup'
    result = launcher.create_live_backup(
        install_root=install, appdata_root=appdata, steam_userdata_roots=[steam],
        backup_root=backup, live_install_root=install, enumerator=EmptyEnumerator(),
        label='fixture', execute=True,
    )
    assert result['ok'], result
    live = {'install': install, 'appdata': appdata, 'steam_userdata/12345': steam}
    verdict = launcher.check_backup_evidence(backup, sources=live)
    assert verdict['ok'], verdict
    return live, verdict


def run_case(name):
    with tempfile.TemporaryDirectory(prefix='aisp-backup-contract-') as temp:
        root = Path(temp)
        live, verified = fixture(root)
        extra = {}
        if name == 'changed_after_verification':
            # The old API required a caller label; use that only to expose its
            # separate failure to bind snapshot bytes. The positive case above
            # still requires the real checker to provide its own identity.
            extra['backup_id'] = verified.get('backup_id') or verified.get('digest') or verified.get('id') or 'fixture-only-legacy-label'
            (live['appdata'] / 'fixture.txt').write_text('changed after check', encoding='utf-8')
        if name == 'caller_id_cannot_replace_verified_id':
            extra['backup_id'] = '0' * 64
        result = certificate.prepare_session(
            root / 'staging', live=live, session_id='backup-contract', phase='P1A',
            closed_check=lambda: True, backup_verify=lambda: verified, **extra,
        )
        if name == 'real_api_prepares_session':
            assert result.get('ok') and result.get('backup_id'), result
        else:
            assert not result.get('ok'), f'{name} accepted: {result}'


def main():
    failures = 0
    names = ('real_api_prepares_session', 'changed_after_verification', 'caller_id_cannot_replace_verified_id')
    for name in names:
        try:
            run_case(name)
            print('PASS', name)
        except Exception as error:
            failures += 1
            print('FAIL', name, str(error)[:500])
    print(f'{len(names)} independent synthetic backup/session checks; {failures} failures; no real game files touched')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
