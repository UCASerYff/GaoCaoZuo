#!/usr/bin/env python3
"""Prepare private, non-executable migration payload from an already verified backup."""
import argparse
import json
from pathlib import Path
import plistlib
import sys
sys.dont_write_bytecode = True
from install_safety import inventory

parser=argparse.ArgumentParser()
parser.add_argument('--backup',required=True,type=Path)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
root=args.backup.resolve()
manifest=json.loads((root/'manifest.json').read_bytes())
if manifest.get('state')!='verified' or inventory(root/'Files',permit_symlinks=True)!=json.loads((root/'protected-inventory.json').read_bytes()):
    raise RuntimeError('第三方安全备份未通过完整性核验，禁止迁移。')
def prefs(bundle,container):
    path=root/'Files'/('Containers/'+bundle+'/Data/Library/Preferences/'+bundle+'.plist' if container else 'Preferences/'+bundle+'.plist')
    # Unknown or unreadable preferences are never treated as empty.
    with path.open('rb') as stream:
        result=plistlib.load(stream)
    if not isinstance(result,dict):raise RuntimeError('原配置结构无效。')
    return result
right=prefs('cn.better365.iRightMousePro',True)
zip_prefs=prefs('cn.better365.FastZip',True)
pane=prefs('cn.better365.Pane',True)
bab=prefs('cn.better365.BetterAndBetter',False)
# Carry only rule and script fields. License blobs, credentials and analytics stay in the private backup.
bab={key:bab[key] for key in ['ruleOfKeyboard','ruleOfAppleScript','ruleOfMagicMouse','ruleOfTrackPad','ruleOfNormalMouse','ruleOfHotCorners'] if key in bab}
right=right['config'];zip_config=zip_prefs['config']
zip_config={k:v for k,v in zip_config.items() if 'password' not in k.lower()}
payload={'schema':1,'right':right,'archive':zip_config,'pane':{k:pane[k] for k in ['isUnsnapRestore','isDragSnapWindow','isHapticFeedbackOnSnap','isHiddenScreenEdgeText'] if k in pane},'input':bab}
data=plistlib.dumps(payload,fmt=plistlib.FMT_BINARY,sort_keys=True)
args.output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
with args.output.open('xb') as stream:stream.write(data)
args.output.chmod(0o600)
print(json.dumps({'prepared':True,'bytes':len(data),'passwords':'not exported','inputRules':'stored paused'},ensure_ascii=False))
