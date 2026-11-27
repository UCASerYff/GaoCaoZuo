"""与 Mac 版操作库对齐的动作目录。不能在 Windows 上执行的条目带有明确原因。"""

from __future__ import annotations

SECTIONS = [
    ("home", "常用", "daily"),
    ("files", "文件", "daily"),
    ("archives", "压缩", "daily"),
    ("clipboard", "剪贴板", "daily"),
    ("tools", "小工具", "daily"),
    ("screenshots", "截图与录制", "daily"),
    ("windows", "窗口", "desktop"),
    ("input", "快捷键与手势", "automation"),
    ("workflows", "组合操作", "automation"),
    ("history", "活动", "activity"),
]

GROUPS = [
    ("daily", "日常工具"),
    ("desktop", "桌面与窗口"),
    ("automation", "自动化"),
    ("activity", "活动"),
]

WINDOW_ACTIONS = [
    ("leftHalf", "左半屏"),
    ("rightHalf", "右半屏"),
    ("topHalf", "上半屏"),
    ("bottomHalf", "下半屏"),
    ("topLeft", "左上角"),
    ("topRight", "右上角"),
    ("bottomLeft", "左下角"),
    ("bottomRight", "右下角"),
    ("thirdLeft", "左侧三分之一"),
    ("thirdCenter", "中间三分之一"),
    ("thirdRight", "右侧三分之一"),
    ("maximize", "铺满工作区"),
    ("center", "窗口居中"),
    ("smaller", "缩小窗口"),
    ("larger", "放大窗口"),
    ("nextDisplay", "移到下一显示器"),
    ("previousDisplay", "移到上一显示器"),
    ("restore", "恢复原位置"),
    ("nearMaximize", "接近最大化"),
    ("centerHalf", "中间半屏"),
    ("leftTwoThirds", "左侧三分之二"),
    ("rightTwoThirds", "右侧三分之二"),
    ("maximizeHeight", "高度最大化"),
    ("maximizeWidth", "宽度最大化"),
    ("quarterFirst", "第一列四分之一"),
    ("quarterSecond", "第二列四分之一"),
    ("quarterThird", "第三列四分之一"),
    ("quarterFourth", "第四列四分之一"),
    ("leftThreeQuarters", "左侧四分之三"),
    ("rightThreeQuarters", "右侧四分之三"),
    ("sixthTopLeft", "左上六分之一"),
    ("sixthTopCenter", "中上六分之一"),
    ("sixthTopRight", "右上六分之一"),
    ("sixthBottomLeft", "左下六分之一"),
    ("sixthBottomCenter", "中下六分之一"),
    ("sixthBottomRight", "右下六分之一"),
    ("moveLeft", "移至左边缘"),
    ("moveRight", "移至右边缘"),
    ("moveUp", "移至上边缘"),
    ("moveDown", "移至下边缘"),
    ("minimize", "最小化窗口"),
    ("minimizeAll", "最小化此应用所有窗口"),
    ("unminimizeAll", "还原此应用最小化窗口"),
    ("close", "关闭窗口"),
    ("toggleFullScreen", "切换窗口全屏"),
    ("nextWindow", "此应用下一窗口"),
    ("previousWindow", "此应用上一窗口"),
]

SYSTEM_PRESETS = [
    ("volumeUp", "音量增加"),
    ("volumeDown", "音量减小"),
    ("mute", "静音切换"),
    ("playPause", "播放/暂停"),
    ("nextTrack", "下一曲"),
    ("previousTrack", "上一曲"),
    ("brightnessUp", "显示器亮度增加"),
    ("brightnessDown", "显示器亮度减小"),
    ("keyboardBrightnessUp", "键盘背光增加"),
    ("keyboardBrightnessDown", "键盘背光减小"),
    ("missionControl", "调度中心"),
    ("applicationWindows", "应用窗口总览"),
    ("showDesktop", "显示桌面"),
    ("spaceLeft", "左侧桌面空间"),
    ("spaceRight", "右侧桌面空间"),
    ("spaceCreate", "新建虚拟桌面"),
    ("spaceClose", "关闭当前虚拟桌面"),
    ("screenSaver", "启动屏幕保护程序"),
    ("wifiOn", "开启 Wi-Fi"),
    ("wifiOff", "关闭 Wi-Fi"),
    ("wifiToggle", "切换 Wi-Fi"),
]

# 这些动作在目录中可见，调用时返回原因，不伪造成功。
UNAVAILABLE = {
    "screenshot.translate.clipboard": "Windows 版没有 macOS 本机翻译，也不会联网翻译。",
    "screenshot.translate.capture": "Windows 版没有 macOS 本机翻译。",
    "system.brightnessUp": "逐显示器硬件亮度不在本版范围，不写显示设置。",
    "system.brightnessDown": "逐显示器硬件亮度不在本版范围，不写显示设置。",
    "system.keyboardBrightnessUp": "Windows 版不写键盘背光。",
    "system.keyboardBrightnessDown": "Windows 版不写键盘背光。",
    "system.wifiOn": "不切换无线电源。",
    "system.wifiOff": "不切换无线电源。",
    "system.wifiToggle": "不切换无线电源。",
    "text.baidu": "不打开外部翻译网页，也不上传剪贴板。",
    "text.google": "不打开外部翻译网页，也不上传剪贴板。",
}


def _action(action_id: str, title: str, detail: str, section: str, keywords: str = "", files: bool = False) -> dict:
    return {
        "id": action_id,
        "title": title,
        "detail": UNAVAILABLE.get(action_id, detail),
        "section": section,
        "keywords": keywords,
        "files": files,
        "available": action_id not in UNAVAILABLE,
        "unavailableReason": UNAVAILABLE.get(action_id),
    }


def all_actions() -> list[dict]:
    rows = [
        _action("panel.show", "打开操作面板", "搜索动作或填写路径", "home", "面板 搜索"),
        _action("new.text", "新建文本文件", "立即在当前目录创建，重名自动编号", "files", "txt"),
        _action("new.markdown", "新建 Markdown", "立即新建 .md 文件，重名自动编号", "files", "md"),
        _action("new.custom", "自定义新建…", "指定名称与初始内容", "files"),
        _action("new.template", "从模板新建", "使用设置中的文本模板", "files"),
        _action("new.folder", "新建文件夹", "立即创建，重名自动编号", "files"),
        _action("file.new.docx", "新建 Word", "原创空白 DOCX，作者为空", "files", "word"),
        _action("file.new.xlsx", "新建 Excel", "原创空白 XLSX，作者为空", "files", "excel"),
        _action("file.new.pptx", "新建 PowerPoint", "原创空白 PPTX，作者为空", "files", "powerpoint"),
        _action("path.copy", "复制文件路径", "多个路径按行排列", "files", "path", True),
        _action("name.copy", "复制文件名称", "包含文件扩展名", "files", "name", True),
        _action("files.copy", "复制到目录", "预检重名，保留原文件", "files", "copy", True),
        _action("files.move", "移动到目录", "保留可核验的恢复记录", "files", "move", True),
        _action("files.rename", "批量重命名", "名称与序号模板，执行前预览", "files", "rename", True),
        _action("terminal.open", "在终端打开", "进入所选目录", "files", "cmd terminal", True),
        _action("finder.reveal", "在资源管理器显示", "定位所选文件", "files", "explorer", True),
        _action("archive.create", "压缩为 ZIP", "原位置直接生成，自动避开同名文件", "archives", "zip", True),
        _action("archive.7z", "压缩为 7Z", "保留原文件", "archives", "7z", True),
        _action("archive.custom", "自定义压缩…", "加密、分卷与固实压缩", "archives", "password split", True),
        _action("archive.extract", "直接解压", "每个包解到同目录的新文件夹", "archives", "unzip", True),
        _action("archive.extract.custom", "解压到其他目录…", "选择位置或提取部分文件", "archives", "", True),
        _action("archive.list", "预览压缩包", "查看列表并选择提取", "archives", "quicklook", True),
        _action("images.png", "转为 PNG", "原位置生成新图，保留原文件", "tools", "png", True),
        _action("images.jpeg", "转为 JPEG", "原位置生成新图，保留原文件", "tools", "jpg", True),
        _action("images.heic", "转为 HEIC", "原位置生成新图，保留原文件", "tools", "heic", True),
        _action("images.tiff", "转为 TIFF", "原位置生成新图，保留原文件", "tools", "tiff", True),
        _action("images.convert", "自定义图片转换…", "选择格式并指定尺寸", "tools", "png jpeg heic tiff webp bmp icns", True),
        _action("images.bmp", "转为 BMP", "原位置生成新图，保留原文件", "tools", "bmp", True),
        _action("images.webp", "转为 WebP", "原位置生成新图，保留原文件", "tools", "webp", True),
        _action("images.icns", "生成 ICNS", "生成可在 macOS 使用的图标文件", "tools", "icon", True),
        _action("hash.sha256", "复制 SHA-256", "计算文件校验值并显示", "tools", "sha256 hash", True),
        _action("text.qrcode.clipboard", "剪贴板转二维码", "把文本生成为 PNG", "tools", "qr"),
        _action("text.qrcode", "自定义二维码…", "将文本保存为 PNG", "tools", "qr"),
        _action("clipboard.show", "查看剪贴板", "搜索历史与固定内容", "clipboard"),
        _action("clipboard.pasteplain", "粘贴为纯文本", "去除格式后进入待核对粘贴", "clipboard"),
        _action("clipboard.copyplain", "复制为纯文本", "只保留文本，不发送粘贴", "clipboard"),
        _action("system.preventSleep.toggle", "切换保持唤醒", "阻止自动系统睡眠", "tools", "awake"),
        _action("system.lock", "锁定屏幕", "提交系统锁屏请求，不确认是否已锁定", "tools", "lock"),
        _action("system.sleep", "电脑睡眠", "提交系统睡眠请求", "tools", "sleep"),
        _action("windows.overview", "窗口总览", "列出窗口标题、进程和位置，不保存画面", "windows"),
        _action("desktop.openSettings", "桌面与窗口设置", "吸附、拖动和权限说明", "windows"),
        _action("lock.settings", "锁屏策略", "默认关闭的本机闲置策略", "tools", "idle"),
        _action("screenshot.workspace", "截图与录制工作台", "只在明确操作后捕获", "screenshots"),
        _action("screenshot.capture", "捕获画面", "本次明确确认后才采集", "screenshots"),
        _action("screenshot.long", "长截图", "滚动目标后连续捕获并拼接", "screenshots"),
        _action("screenshot.annotate", "标注", "添加形状、画线及文字", "screenshots"),
        _action("screenshot.recording", "录屏与录音", "选择来源后明确开始", "screenshots"),
        _action("screenshot.pins.restore", "恢复持久贴图", "只打开已经主动保存的贴图", "screenshots"),
        _action("screenshot.ocr.capture", "静默截图 OCR", "选择区域并识别", "screenshots"),
        _action("screenshot.ocr.clipboard", "识别剪贴板图片", "只在本次明确动作中读取图片", "screenshots"),
        _action("ocr.files", "识别图像与 PDF", "调用 Windows 本机 OCR，可导出识别文字", "screenshots", "pdf ocr", True),
        _action("screenshot.translate.clipboard", "本机翻译剪贴板文字", "只读取本次内容", "screenshots"),
        _action("screenshot.translate.capture", "截图后本机翻译", "选择区域并识别", "screenshots"),
        _action("workflow.show", "查看组合操作", "按顺序运行，失败即停止", "workflows"),
        _action("finder.popup", "资源管理器操作面板", "在工作台运行所选文件的操作", "files"),
        _action("folder.favorite.add", "添加到常用目录", "收藏当前目录", "files"),
        _action("text.baidu", "百度翻译所选文字", "使用剪贴板文字打开翻译网页", "tools"),
        _action("text.google", "谷歌翻译所选文字", "使用剪贴板文字打开翻译网页", "tools"),
    ]
    for key, title in WINDOW_ACTIONS:
        detail = "恢复本次运行保存的位置" if key == "restore" else "调整所选窗口"
        rows.append(_action(f"window.{key}", title, detail, "windows", "分屏 布局 窗口"))
    for key, title in SYSTEM_PRESETS:
        rows.append(_action(f"system.{key}", title, "系统控制", "tools"))
    return rows


def find_action(action_id: str) -> dict | None:
    for row in all_actions():
        if row["id"] == action_id:
            return row
    return None


def search_actions(query: str, extra: list[dict] | None = None) -> list[dict]:
    q = query.strip().lower()
    rows = all_actions() + list(extra or [])
    if not q:
        return rows
    result = []
    for row in rows:
        text = " ".join(
            [
                row.get("title", ""),
                row.get("detail", ""),
                row.get("keywords", ""),
                row.get("id", ""),
            ]
        ).lower()
        if q in text:
            result.append(row)
    return result
