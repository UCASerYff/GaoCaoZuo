#!/usr/bin/env python3
"""Prepare a private, non-executable payload from a fully verified backup.

The backup remains authoritative for credentials, licensing and unknown private
vendor stores. This file carries operational settings only; never keychain data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
sys.dont_write_bytecode = True
from install_safety import inventory

BAB_OPERATIONAL_KEYS = '''ruleOfKeyboard ruleOfNormalMouse ruleOfTrackPad ruleOfMagicMouse ruleOfHotCorners ruleOfAppleScript
blacklistOfMiddleMouse blacklistOfRightMouse enableAdjustMouseSpeed mouseAcceleration offMouseAcceleration
enableSmoothScroll trackingSpeedOfSmoothScroll reverseMouseScrollX reverseMouseScrollY disableSmoothScrollOfHoldingModifierkey bottomOutOfScrollWheel SmoothScrollIndividualSetting
oneFingerDrawingOfTrackTouch oneFingerDrawingOfOutsideTrackTouch drawingOfMultiTouch enableRightMouseDrawingOfTrackpad enableMiddleMouseDrawingOfMagicMouse enableRightMouseDrawingOfMagicMouse simulateMiddleMouseFromMagicMouse widthOfSimulateMiddleMouseFromMagicMouse heightOfSimulateMiddleMouseFromMagicMouse
disableClickMoreThenOneFinger disableScrollWheelMoreThenTwoFingers disableInvalidKeyDrawingFunction distanceOfStartDragged distanceToTrackPadSides specialKeysOfNormalMouse namesForKeys MouseKeyInfo HaveFittedMouse
displayTrackOfDrawing lineWidthOfDrawing colorOfDrawingLine displayActionOfTrackPad displayActionOfMagicMouse showActionOrNote ActionOrNote actionOrNoteRetetionTime'''.split()
PANE_OPERATIONAL_KEYS = ['isUnsnapRestore','isDragSnapWindow','isHapticFeedbackOnSnap','isHiddenScreenEdgeText','isHiddenStatusBar','isLaunchAtLoginEnabled','footprintAnimationDurationMultiplier','subsequentExecutionMode']
ARCHIVE_OPTION_KEYS = ['enablePasswordWhenArchiving','enableSolidArchive','enableSplitToVolumes','enableEncryptedFileName']
BUNDLES = ['cn.better365.iRightMousePro','cn.better365.FastZip','cn.better365.Pane','cn.better365.BetterAndBetter']


def prepare(root, output):
    root = root.resolve(strict=True)
    manifest = json.loads((root/'manifest.json').read_bytes())
    protected = json.loads((root/'protected-inventory.json').read_bytes())
    if manifest.get('state') != 'verified' or inventory(root/'Files',permit_symlinks=True) != protected:
        raise RuntimeError('第三方安全备份未通过完整性核验，禁止迁移。')
    source_evidence = []
    def prefs(bundle, container):
        relative = ('Containers/'+bundle+'/Data/Library/Preferences/'+bundle+'.plist' if container else 'Preferences/'+bundle+'.plist')
        path = root/'Files'/relative
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('原配置缺失或不是普通文件，禁止按空配置迁移。')
        raw = path.read_bytes()
        result = plistlib.loads(raw)
        if not isinstance(result,dict): raise RuntimeError('原配置结构无效。')
        source_evidence.append({'bundleID':bundle,'preferenceSHA256':hashlib.sha256(raw).hexdigest()})
        return result
    right = prefs(BUNDLES[0],True)
    archive = prefs(BUNDLES[1],True)
    pane = prefs(BUNDLES[2],True)
    bab = prefs(BUNDLES[3],False)
    if not isinstance(right.get('config'),dict) or not isinstance(archive.get('config'),dict):
        raise RuntimeError('原软件操作配置缺失，禁止继续迁移。')
    zip_config = archive['config']
    counts = {}
    for key in ['compressPasswordBook','decompressPasswordBook']:
        if key not in zip_config or not isinstance(zip_config[key],list):
            raise RuntimeError('旧密码本结构未知，不能声称密码已迁移。')
        counts[key] = len(zip_config[key])
        if counts[key]:
            raise RuntimeError('旧密码本非空；需采用经过核验的本地密码本迁移流程，禁止导出到普通迁移文件。')
    # Keep empty-book evidence, not secrets. Complete originals stay in the backup.
    safe_archive = {k:v for k,v in zip_config.items() if 'passwordbook' not in k.lower()}
    resources = root/'Files/Applications/iRightMouse Pro.app/Contents/Resources'
    info = plistlib.loads((resources.parent/'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLES[0] or resources.is_symlink() or not resources.is_dir():
        raise RuntimeError('原模板资源身份不符。')
    resource_inventory = inventory(resources,permit_symlinks=False)
    hashes = {k:v['sha256'] for k,v in resource_inventory['entries'].items() if v['type']=='file'}
    right_config = dict(right['config'])
    icon_references = []
    if not isinstance(right_config.get('fileIconList'),list):
        raise RuntimeError('旧图标配置结构未知，禁止以空配置覆盖。')
    for entry in right_config['fileIconList']:
        if not isinstance(entry,dict) or not isinstance(entry.get('icon'),bytes):
            raise RuntimeError('旧图标来源无法核验。')
        reference = {k:v for k,v in entry.items() if k != 'icon'}
        reference.update(iconSHA256=hashlib.sha256(entry['icon']).hexdigest(),iconByteCount=len(entry['icon']),assetRetainedInBackup=True)
        icon_references.append(reference)
    right_config['fileIconList'] = icon_references
    payload = {'schema':2,'right':right_config,'archive':safe_archive,
               'pane':{k:pane[k] for k in PANE_OPERATIONAL_KEYS if k in pane},
               'input':{k:bab[k] for k in BAB_OPERATIONAL_KEYS if k in bab},
               'archiveOptions':{k:archive[k] for k in ARCHIVE_OPTION_KEYS if k in archive},
               'passwordBookCounts':counts,'sourceEvidence':source_evidence,
               'rightResourceSHA256':hashes,
               'rightSourceVersion':str(info.get('CFBundleShortVersionString','unknown'))}
    data = plistlib.dumps(payload,fmt=plistlib.FMT_BINARY,sort_keys=True)
    if len(data)>32_000_000: raise RuntimeError('迁移载荷超出预算。')
    output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd = os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as stream:
        stream.write(data);stream.flush();os.fsync(stream.fileno())
    if output.read_bytes()!=data: raise RuntimeError('迁移载荷写入核验失败。')
    return {'prepared':True,'schema':2,'bytes':len(data),'sourceApps':len(source_evidence),
            'passwordBooks':'verified empty; keychain unchanged','inputRules':'preserve exact mappings and unresolved rows'}


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--backup',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    print(json.dumps(prepare(args.backup,args.output),ensure_ascii=False))
