"""Independent synthetic generated-cache boundary; never touches actual game files."""
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import staging


def put(root, rel, value):
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value, encoding='utf-8')
    return target


def check(policy, prefix):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = put(root, prefix + 'Multiplayer/networking/socket.lua', 'source')
        nested = put(root, prefix + 'OtherMod/lovely/game-dump/source.lua', 'nested-source')
        similar = put(root, prefix + 'lovely/game-dump-extra/source.lua', 'similar-source')
        baseline = staging.hash_tree(root, policy)
        old = put(root, prefix + 'lovely/game-dump/SMODS/Handy/threads/updater', 'old generated')
        assert staging.hash_tree(root, policy) == baseline, 'exact generated cache entered source digest'
        old.unlink()
        put(root, prefix + 'lovely/game-dump/SMODS/Multiplayer/networking/socket.lua', 'new generated')
        assert staging.hash_tree(root, policy) == baseline, 'generated cache rewrite changed source digest'
        for item in (source, nested, similar):
            value = item.read_text(encoding='utf-8')
            item.write_text(value + ' changed', encoding='utf-8')
            assert staging.hash_tree(root, policy) != baseline, ('source change hidden', item)
            item.write_text(value, encoding='utf-8')
        complete = staging.hash_tree(root, staging.BACKUP_POLICY)
        assert any('/game-dump/' in key for key in complete), 'complete backup omitted generated files'
        print('PASS exact cache exclusion, three source-change rejections, complete backup:', prefix or 'Mods root')


if __name__ == '__main__':
    check(staging.MODS_HASH_POLICY, '')
    check(staging.STAGING_POLICY, staging.MODS_REL_PREFIX + '/')
    check(staging.BOOTSTRAP_POLICY, staging.MODS_REL_PREFIX + '/')
