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
    for filename in ['LocalizationCommon.tsv', 'LocalizationWindow.tsv', 'LocalizationArchiveNative.tsv', 'LocalizationExtensions.tsv', 'LocalizationFinder.tsv', 'LocalizationSafety.tsv', 'LocalizationInputSafety.tsv', 'LocalizationCompletion.tsv', 'LocalizationDynamic.tsv', 'LocalizationFinalCloud.tsv', 'LocalizationClipboardFinal.tsv', 'LocalizationArchiveFinal.tsv']:
        if not (ROOT/'Resources'/filename).exists(): continue
        for line in (ROOT/'Resources'/filename).read_text().splitlines():
            if not line or line.startswith('#'):continue
            values=line.split('|')
            if len(values)!=8:raise ValueError((filename,line))
            if filename in ('LocalizationDynamic.tsv','LocalizationArchiveFinal.tsv'):
                values=[value.replace('\\n','\n') for value in values]
            key=values[0]
            for lang,value in zip(['zh-Hans','en','ja','de','fr','es','ko','pt'],values):result[lang][key]=value
    for path in sorted((ROOT/'Resources/LocalizationOverrides').glob('*.json')):
        if path.stem not in LANGUAGES:raise ValueError('Unknown localization: '+path.name)
        values=json.loads(path.read_text())
        if not isinstance(values,dict) or any(not isinstance(k,str) or not isinstance(v,str) for k,v in values.items()):raise ValueError('Invalid localization: '+path.name)
        result[path.stem].update(values)
    # Explicit semantic aliases share translations, never English fallbacks.
    # Selection actions use a translated context plus an already translated
    # action label; user names and paths are not inputs to this catalog step.
    aliases={
        '居中窗口':'窗口居中','恢复窗口位置':'恢复原位置',
        '查看剪贴板历史':'查看剪贴板','粘贴上一条短语':'粘贴最近使用的短语',
        '存为常用短语':'存为短语','转为大写':'转为大写 (UPPERCASE)',
        '转为小写':'转为小写 (lowercase)','朗读选中文本':'朗读选中文字',
        '窗口管理':'窗口','文件工具':'文件','快捷短语':'常用短语',
        '粘贴堆栈：依次弹出并粘贴':'粘贴堆栈顶部内容',
        '生成选中文本二维码':'选中文字转二维码',
        '选中文本统计 (字数/行数)':'选中文字统计',
        '访达扩展菜单':'弹出访达操作菜单','键盘与屏幕清洁设置':'键盘与屏幕清洁模式',
    }
    selected={
        '搜索选中文字':'搜索','复制选中文字':'复制',
        '选中文字转二维码':'生成二维码','选中文字统计':'文本统计',
        '选中文字转大写':'转为大写 (UPPERCASE)','选中文字转小写':'转为小写 (lowercase)',
        '选中文字词首大写':'首字母大写 (Title Case)',
        '选中文字转半角':'转为半角字符','选中文字转全角':'转为全角字符',
        '清理选中文字空白':'清理多余空白与换行',
        '选中文字 Base64 编码':'Base64 编码','选中文字 Base64 解码':'Base64 解码',
        '选中文字 URL 编码':'URL 编码','选中文字 URL 解码':'URL 解码',
        '朗读选中文字':'朗读','将选中文字存为短语':'存为短语',
        '将选中文字存入剪贴板历史':'保存到剪贴板历史',
    }
    prefixes={'zh-Hans':'选中文字：','en':'Selected text: ','ja':'選択テキスト：','de':'Textauswahl: ','fr':'Texte sélectionné : ','es':'Texto seleccionado: ','ko':'선택한 텍스트: ','pt':'Texto selecionado: '}
    for key,base in selected.items():
        for lang,prefix in prefixes.items():
            if base not in result[lang]:raise ValueError(f'Missing explicit selection action {lang}: {base}')
            result[lang][key]=key if lang=='zh-Hans' else prefix+result[lang][base]
    for key,base in aliases.items():
        for lang in prefixes:
            if base not in result[lang]:raise ValueError(f'Missing explicit alias {lang}: {base}')
            result[lang][key]=key if lang=='zh-Hans' else result[lang][base]
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
        purposes={
            'NSAppleEventsUsageDescription':'仅在你请求操作时读取访达选择或控制指定应用。',
            'NSInputMonitoringUsageDescription':'识别你配置的输入手势，不记录键入的文字。',
            'NSAccessibilityUsageDescription':'排列窗口并执行你配置的操作。',
            'NSDesktopFolderUsageDescription':'处理你选择的桌面文件。',
            'NSDocumentsFolderUsageDescription':'处理你选择的文稿。',
            'NSDownloadsFolderUsageDescription':'处理你选择的下载文件。',
            'NSRemovableVolumesUsageDescription':'处理你选择的移动磁盘文件。',
            'NSNetworkVolumesUsageDescription':'处理你选择的网络磁盘文件。',
        }
        info={key:values.get(message,data['en'].get(message,message)) for key,message in purposes.items()}
        info['CFBundleDisplayName']=display_zh if lang.startswith('zh') else display_en
        (directory/'InfoPlist.strings').write_text(strings(info))
    return data

if __name__=='__main__':
    for path in sys.argv[1:]:build(path)
