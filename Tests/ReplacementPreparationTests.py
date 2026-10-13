#!/usr/bin/env python3
"""Verify private-payload preparation, integrity gates and credential exclusion."""
from pathlib import Path
import importlib.util
import json
import plistlib
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'Scripts'))
from install_safety import inventory
spec=importlib.util.spec_from_file_location('replacement_prepare',ROOT/'Scripts/prepare_replacement_migration.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix='gaocaozuo-replacement-prepare-') as temporary:
    root=Path(temporary)/'backup';files=root/'Files';files.mkdir(parents=True)
    def write(bundle, value, container=True):
        relative=('Containers/'+bundle+'/Data/Library/Preferences/'+bundle+'.plist' if container else 'Preferences/'+bundle+'.plist')
        path=files/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(plistlib.dumps(value));return path
    write('cn.better365.iRightMousePro',{'config':{'newFileList':[],'fileIconList':[{'name':'old stock icon','enable':True,'icon':b'original-vendor-art-do-not-copy'}],'unknownNested':{'opaque':b'original-template-field'}}})
    archive=write('cn.better365.FastZip',{'config':{'compressPasswordBook':[],'decompressPasswordBook':[],'futureMenu':{'value':9223372036854775807}},'enableSolidArchive':True})
    write('cn.better365.Pane',{'isDragSnapWindow':True,'MSAppCenterInstallId':'private-analytics'})
    write('cn.better365.BetterAndBetter',{'ruleOfKeyboard':[{'All Rules':[{'future':{'opaque':b'preserved'}}]}],
         'blacklistOfRightMouse':['example.application'],'LicenseKey':'credential-must-not-export','CloudToken':'token-must-not-export'},False)
    resources=files/'Applications/iRightMouse Pro.app/Contents/Resources';resources.mkdir(parents=True)
    (resources.parent/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cn.better365.iRightMousePro','CFBundleShortVersionString':'1.00'}))
    (resources/'TXT.txt').write_bytes(b'original blank document')
    def seal():
        (root/'manifest.json').write_text(json.dumps({'state':'verified'}))
        (root/'protected-inventory.json').write_text(json.dumps(inventory(files,permit_symlinks=True)))
    seal();before=inventory(files,permit_symlinks=True)
    output=Path(temporary)/'payload.plist';result=module.prepare(root,output);payload=plistlib.loads(output.read_bytes())
    assert payload['schema']==2 and result['sourceApps']==4
    assert payload['right']['unknownNested']['opaque']==b'original-template-field'
    assert payload['input']['ruleOfKeyboard'][0]['All Rules'][0]['future']['opaque']==b'preserved'
    assert payload['input']['blacklistOfRightMouse']==['example.application']
    assert 'icon' not in payload['right']['fileIconList'][0] and payload['right']['fileIconList'][0]['assetRetainedInBackup']
    assert 'rightResourceDirectory' not in payload
    assert 'LicenseKey' not in payload['input'] and 'CloudToken' not in payload['input']
    assert 'MSAppCenterInstallId' not in payload['pane']
    assert 'compressPasswordBook' not in payload['archive'] and payload['passwordBookCounts']['compressPasswordBook']==0
    assert output.stat().st_mode&0o777==0o600 and inventory(files,permit_symlinks=True)==before
    (resources/'TXT.txt').write_bytes(b'tampered')
    try:module.prepare(root,Path(temporary)/'tampered.plist')
    except RuntimeError:pass
    else:raise AssertionError('tampered backup accepted')
    archive.write_bytes(plistlib.dumps({'config':{'compressPasswordBook':[{'password':'private-test-secret'}],'decompressPasswordBook':[]}}));seal()
    rejected=Path(temporary)/'secrets.plist'
    try:module.prepare(root,rejected)
    except RuntimeError:pass
    else:raise AssertionError('nonempty password book exported')
    assert not rejected.exists()
print('PASS: verified backup gate, unknown operational fields, private permissions, no source mutation, credential exclusion and nonempty-book refusal')
