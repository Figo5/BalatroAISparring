"""Dependency drift and native report refusal controls; no live operations."""
from pathlib import Path
import copy, hashlib, json, sys, tempfile
from types import SimpleNamespace
REPO=Path(__file__).resolve().parents[1];sys.path.insert(0,str(REPO/'tools'))
import ranked_deployment as rd
import staging

def main():
    p=rd.verify_sources()
    assert len(p['sources']['smods']['files'])>100
    assert p['lovely_sha256']==staging.sha256_file(rd.DLL)
    with tempfile.TemporaryDirectory(dir=REPO/'work') as temp:
        dest=Path(temp)/'minimal'
        rd.assemble(dest)
        assert set(x.name for x in dest.iterdir())=={'smods','Multiplayer'}
        assert not (dest/'Handy').exists()
        for name,spec in p['sources'].items():assert staging.hash_tree(dest/name)==spec['files']
        suppressed=staging.suppress_staged_network_paths(dest,Path(temp))
        assert suppressed['ok'] and staging.scan_network_suppressions(dest)['ok']
        source_pins=staging.read_json(REPO/'docs/RANKED_SOURCE_PINS_V1.json')['authoritative_files']
        for rel,digest in source_pins.items():assert staging.sha256_file(dest/'Multiplayer'/rel)==digest,rel
        print('1620a staged suppressions:',json.dumps([e['rel'] for e in suppressed['entries']]))
        try:rd.assemble(dest)
        except RuntimeError as e:assert str(e)=='ranked_dependency_target_exists'
        else:raise AssertionError('replacement accepted')
        staged=Path(temp)/'staging';install=staged/'roles/human/install';install.mkdir(parents=True)
        previous=install/'winmm.dll';previous.write_bytes(b'fixture old injector')
        paths=SimpleNamespace(install=install,role='human')
        try:rd._retire_previous_injector(staged,paths,'0'*64)
        except RuntimeError:pass
        else:raise AssertionError('unknown copied injector was removed')
        assert previous.exists()
        digest=hashlib.sha256(previous.read_bytes()).hexdigest()
        rd._retire_previous_injector(staged,paths,digest)
        assert not previous.exists()
        assert staging.sha256_file(staged/'evidence/injector-replacement/human/winmm.dll')==digest
    report={'schema':'aisparring.ranked_preparation.v1','role':'human','nonce':'n','mods':rd.APPROVED,
            **{key:True for key in rd.REQUIRED},'catalog':{'schema':'aisparring.ranked_catalog.v1',
            'eligible_decks':['b_red'],'decks':{'red':{'center_key':'b_red','name':'Red Deck'}},
            'stakes':{'white':{'index':1,'max_index':8}}}}
    assert rd.validate_report(report,'human','n')
    # Exact inventory observed from the genuine 1620a/0.9 native preparation.
    # Missing guard, changed version and unrelated compatibility mods refuse.
    observed={'AISparring-0.1.0':'dev','Multiplayer':'0.5.5','Steamodded-1.0.0~BETA':'1620a',
              'lovely-compat-aisparring-staging':'0.0.0','Lovely':'0.9.0'}
    changed=copy.deepcopy(report);changed['mods']=observed
    assert rd.validate_report(changed,'human','n')
    for bad in (dict(observed, **{'lovely-compat-aisparring-staging':'0.0.1'}),
                {k:v for k,v in observed.items() if k!='lovely-compat-aisparring-staging'},
                dict(observed, **{'lovely-compat-unreviewed':'0.0.0'})):
        changed=copy.deepcopy(report);changed['mods']=bad
        try:rd.validate_report(changed,'human','n')
        except RuntimeError as e:assert str(e)=='ranked_preparation_inventory'
        else:raise AssertionError('native inventory control accepted')
    for key in rd.REQUIRED:
        for value in (False,None,1,'true'):
            changed=copy.deepcopy(report);changed[key]=value
            assert not rd.validate_report(changed,'human','n'),key
    for key,value in (('nonce','stale'),('role','ai'),('schema','wrong'),('mods',{})):
        changed=copy.deepcopy(report);changed[key]=value
        try:rd.validate_report(changed,'human','n')
        except RuntimeError:pass
        else:raise AssertionError(key+' accepted')
    print('40 dependency/native-evidence controls passed; no native preparation claim')
    return 0
if __name__=='__main__':sys.exit(main())
