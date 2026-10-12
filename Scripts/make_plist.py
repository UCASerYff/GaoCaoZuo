#!/usr/bin/env python3
"""Generate versioned app / Finder extension metadata; no default handlers."""
import plistlib
from pathlib import Path
import sys

destination, version, build = sys.argv[1:4]
extension = '--extension' in sys.argv[4:]
quicklook = '--quicklook' in sys.argv[4:]
info = dict(CFBundleIdentifier='com.gaoseries.GaoCaoZuo', CFBundleName='搞操作',
    CFBundleDisplayName='搞操作', CFBundleExecutable='GaoCaoZuo', CFBundlePackageType='APPL',
    CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleIconFile='AppIcon',
    CFBundleDevelopmentRegion='zh_CN', CFBundleLocalizations=['zh-Hans'], LSMinimumSystemVersion='14.0',
    NSHighResolutionCapable=True, NSPrincipalClass='NSApplication', NSSupportsAutomaticTermination=False,
    NSHumanReadableCopyright='搞系列 · 搞操作', LSApplicationCategoryType='public.app-category.utilities')
archive_types=['public.zip-archive','org.7-zip.7-zip-archive','com.rarlab.rar-archive','public.tar-archive','org.gnu.gnu-zip-archive','public.bzip2-archive','org.tukaani.xz-archive','com.gaoseries.ace-archive','com.gaoseries.lzip-archive']
if quicklook:
    info.update(CFBundleIdentifier='com.gaoseries.GaoCaoZuo.QuickLook',CFBundleName='GaoArchiveQuickLook',CFBundleDisplayName='搞操作压缩包预览',CFBundleExecutable='GaoArchiveQuickLook',CFBundlePackageType='XPC!',NSExtension=dict(NSExtensionPointIdentifier='com.apple.quicklook.preview',NSExtensionPrincipalClass='GaoArchiveQuickLook.ArchiveQuickLook',NSExtensionAttributes=dict(QLSupportedContentTypes=archive_types,QLSupportsSearchableItems=False)))
    info.pop('NSPrincipalClass',None)
elif extension:
    info.update(CFBundleIdentifier='com.gaoseries.GaoCaoZuo.FinderSync',
        CFBundleName='GaoFinderSync', CFBundleDisplayName='搞操作访达扩展',
        CFBundleExecutable='GaoFinderSync', CFBundlePackageType='XPC!',
        NSExtension=dict(NSExtensionAttributes={}, NSExtensionPointIdentifier='com.apple.FinderSync',
            NSExtensionPrincipalClass='GaoFinderSync.GaoFinderSync'))
    info.pop('NSPrincipalClass', None)
else:
    info.update(NSAppleEventsUsageDescription='在您执行相关操作时，获取访达所选文件或调用指定应用。',
        NSInputMonitoringUsageDescription='您启用鼠标手势后，识别已配置的手势；不记录键盘输入。',
        NSAccessibilityUsageDescription='您启用窗口控制或手势后，调整窗口或执行您配置的操作。',
        NSDesktopFolderUsageDescription='处理您选择的桌面文件。',
        NSDocumentsFolderUsageDescription='处理您选择的文稿文件。',
        NSDownloadsFolderUsageDescription='处理您选择的下载文件。',
        NSRemovableVolumesUsageDescription='处理您选择的外接磁盘文件。',
        NSNetworkVolumesUsageDescription='处理您选择的网络磁盘文件。')
    info['CFBundleURLTypes'] = [dict(CFBundleURLName='搞操作动作入口',CFBundleTypeRole='Viewer',CFBundleURLSchemes=['gaocaozuo'])]
    info['CFBundleDocumentTypes'] = [dict(CFBundleTypeName='文件和文件夹',CFBundleTypeRole='Viewer',
        LSHandlerRank='Alternate',LSItemContentTypes=['public.item']),dict(CFBundleTypeName='压缩包',CFBundleTypeRole='Viewer',LSHandlerRank='Alternate',LSItemContentTypes=archive_types)]
    info['UTImportedTypeDeclarations']=[dict(UTTypeIdentifier=identifier,UTTypeConformsTo=['public.archive'],UTTypeDescription=label,UTTypeTagSpecification={'public.filename-extension':extensions}) for identifier,label,extensions in [('com.gaoseries.ace-archive','ACE Archive',['ace']),('com.gaoseries.lzip-archive','LZIP Archive',['lz','lzip'])]]
    info['NSServices'] = [dict(NSMenuItem={'default':'搞操作…'},NSMessage='receiveFiles',
        NSPortName='搞操作',NSSendTypes=['public.file-url','NSFilenamesPboardType'],
        NSRequiredContext={})] + [dict(NSMenuItem={'default':title},NSMessage='receiveText',NSUserData=action,NSPortName='搞操作',NSSendTypes=['public.utf8-plain-text'],NSRequiredContext={}) for title,action in [('用百度翻译','text.baidu'),('用谷歌翻译','text.google'),('文字转二维码','text.qrcode.clipboard')]]
Path(destination).parent.mkdir(parents=True, exist_ok=True)
Path(destination).write_bytes(plistlib.dumps(info, sort_keys=False))
