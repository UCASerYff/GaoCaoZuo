#!/usr/bin/env python3
"""Build independent native localization resources for app and both extensions.
Catalog entries are explicit translations; absent translations use visible fallback.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'de', 'fr', 'es', 'it', 'ko', 'pt']

def catalog():
    result = json.loads((ROOT/'Resources/LocalizationCatalog.json').read_text())
    for lang in LANGUAGES: result.setdefault(lang, {})
    for filename in ['LocalizationEnglish.tsv','LocalizationExchange.tsv','LocalizationInput.tsv']:
        path=ROOT/'Resources'/filename
        if not path.exists():continue
        for line in path.read_text().splitlines():
            if not line or line.startswith('#'): continue
            key,value=line.split('\t',1)
            result['zh-Hans'][key]=key;result['en'][key]=value
    for filename in ['LocalizationCommon.tsv', 'LocalizationWindow.tsv', 'LocalizationArchiveNative.tsv']:
        for line in (ROOT/'Resources'/filename).read_text().splitlines():
            if not line or line.startswith('#'):continue
            values=line.split('|')
            if len(values)!=8:raise ValueError((filename,line))
            key=values[0]
            for lang,value in zip(['zh-Hans','en','ja','de','fr','es','ko','pt'],values):result[lang][key]=value
    for path in sorted((ROOT/'Resources/LocalizationOverrides').glob('*.json')):
        if path.stem not in LANGUAGES:raise ValueError('Unknown localization: '+path.name)
        values=json.loads(path.read_text())
        if not isinstance(values,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in values.items()):raise ValueError('Invalid localization: '+path.name)
        result[path.stem].update(values)
    return result

def strings(data):
    return ''.join(json.dumps(k,ensure_ascii=False)+' = '+json.dumps(v,ensure_ascii=False)+';\n' for k,v in sorted(data.items()))

def build(destination):
    data=catalog();destination=Path(destination)
    bundle_name=destination.parent.parent.name
    finder=bundle_name=='GaoFinderSync.appex';quicklook=bundle_name=='GaoArchiveQuickLook.appex'
    display_en='GaoCaoZuo Finder Extension' if finder else ('GaoCaoZuo Archive Preview' if quicklook else 'GaoCaoZuo')
    display_zh='搞操作访达扩展' if finder else ('搞操作压缩预览' if quicklook else '搞操作')
    for lang,values in data.items():
        directory=destination/(lang+'.lproj');directory.mkdir(parents=True,exist_ok=True)
        # Include English fallback for SwiftUI lookups; retain the explicit catalog
        # separately so audit never mistakes fallback for a completed translation.
        combined={**data['en'],**values} if lang!='zh-Hans' else values
        (directory/'Localizable.strings').write_text(strings(combined))
        english={'CFBundleDisplayName':'GaoCaoZuo','NSAppleEventsUsageDescription':'Access Finder selection or control the selected app only when you request an action.','NSInputMonitoringUsageDescription':'Recognize configured gestures; typed content is not recorded.','NSAccessibilityUsageDescription':'Arrange windows and run the actions you configured.','NSDesktopFolderUsageDescription':'Process desktop files you select.','NSDocumentsFolderUsageDescription':'Process documents you select.','NSDownloadsFolderUsageDescription':'Process downloads you select.','NSRemovableVolumesUsageDescription':'Process selected files on removable drives.','NSNetworkVolumesUsageDescription':'Process selected files on network drives.'}
        english['CFBundleDisplayName']=display_en
        if lang=='zh-Hans':english={'CFBundleDisplayName':display_zh}
        (directory/'InfoPlist.strings').write_text(strings(english))
    return data

if __name__=='__main__':
    for path in sys.argv[1:]:build(path)
