# 搞操作 Windows 版

营销版本与当前 Mac 版相同，为 **1.16**。Windows 构建号从 **1** 起算，程序显示 `1.16+1`。没有改 Mac 版的 Swift 源码、Bundle ID、BUILD 或签名。

界面是只监听 `127.0.0.1` 的本地网页，业务用 **Python 3.12 标准库** 实现，再用 **PyInstaller** 打成单个 exe。个人资料留在本机，页面不绑定其他网卡。

## 运行

开发时在 `windows` 目录安装依赖后启动。控制台会打印只监听本机的地址；加上 `--no-browser` 时不打开系统浏览器。

```powershell
cd windows
python -m pip install -r requirements-dev.txt
$env:PYTHONPATH = "src"
python launch.py --data-dir $env:TEMP\GaoCaoZuo-dev --no-browser --port 8765
```

双击 `GaoCaoZuo.exe` 等同于启动本地页面并打开浏览器。指定隔离资料目录：

```powershell
.\dist\GaoCaoZuo.exe --data-dir D:\GaoCaoZuoData
```

默认资料目录：

- Windows：`%APPDATA%\GaoSeries\GaoCaoZuo`
- 其他系统上的开发运行：`$XDG_DATA_HOME/GaoSeries/GaoCaoZuo`，否则是 `~/.local/share/GaoSeries/GaoCaoZuo`

这与 Mac 版 `~/Library/Application Support/GaoSeries/GaoCaoZuo` 对应，但不会自动去读 Mac 路径。可以把一份资料目录复制过来再打开。`settings.json` 的未知字段会保留；schema 不是 1、文件损坏，或目录里已有别的文件却没有 `settings.json` 时，程序停止写入，不用空白设置覆盖。

## 测试

```powershell
cd windows
python -m pytest -q
```

打包（仅 Windows）：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

产物是 `dist\GaoCaoZuo.exe` 和带控制台的 `dist\GaoCaoZuo-cli.exe`。GitHub Actions 在 `windows-latest` 上跑单元测试、打包，并启动 exe：页面返回 HTTP 200，写入 `settings.json` 和一个文本文件，进程保持数秒后经 `/api/shutdown` 退出。中途退出或不能退出都算失败。

## 资料

| 文件 | 作用 |
| --- | --- |
| `settings.json` | schema 1。收藏、模板、组合操作、剪贴板开关、闲置策略。未知字段保留 |
| `receipts.json` | 文件操作恢复记录。指纹不符就停止恢复 |
| `Clipboard/history.json` | 只有明确启用历史后才读取 |
| `Snippets/library.json` | 短语、分组、标签、快捷码。不生成 `.gaosnippets` 备份 |
| `Input/rules.json` | 快捷键规则。冲突不能保存 |
| `ScreenshotPins/` | 只有主动保存的贴图 |

密码放在内存保管库里；Windows 运行时不会把密码写进 JSON 或日志。本说明不把票据、文件载荷或密码写入日志。

保存使用临时文件替换，不留备份副本。

## 已对齐

- 工作台分组：日常工具、桌面与窗口、自动化、活动。收藏和搜索走同一动作目录。
- 直接新建文本、Markdown、文件夹，重名自动编号。自定义名称和模板仍保留。
- 原创空白 DOCX、XLSX、PPTX，作者为空，不含宏或外部链接。
- 复制路径、文件名、SHA-256。复制和移动只选一次目标；同名冲突停止并给出路径。
- 批量重命名先预览。`{name}`、`{ext}`、`{n}`、`{n:03}` 与 Mac 版一致。恢复时指纹不符就停止。
- ZIP 创建、传统加密（ZipCrypto，含中文密码）、列表、隔离解压后再提交。拒绝路径越界、符号链接和超出预算的内容。已完成的包不会因为下一次密码重试而重新解压。
- 分卷在没有 7-Zip 时写成 `文件.zip.001` 这种字节分卷，并在界面标明，不是 7-Zip 分卷。
- PNG 与 BMP 互转和按最长边缩放。二维码为字节模式、纠错级别 M、版本 1–10，最多 213 字节。
- 剪贴板历史默认关闭。纯文本进入待核对事务：不定时恢复、不重叠替换、不自动回车。确认后才提交文字、图片、文件和文件夹堆栈。
- 短语变量 `{date}`、`{time}`、`{datetime}`、`{year}`、`{month}`、`{day}`、`{uuid}`、`{clipboard}`。安全输入时不用剪贴板替换。CSV 为 UTF-8 BOM、CRLF；XLSX 只保留文本列。
- 窗口几何：半屏、四角、三分、四分、六分、居中、铺满、跨显示器和恢复。恢复必须与记录一致，否则回滚。边缘吸附默认关闭。没有真实窗口后端时只返回矩形，不报告已经移动。
- 组合操作按顺序执行，失败即停，已完成的步骤保留。
- 锁屏、睡眠、屏保只报告请求已提交。屏保不等于锁屏。闲置策略默认关闭，同一闲置周期不重复请求，不保存密码，不自动解锁。
- 截图必须本次明确确认。历史默认关闭。可以标注矩形、纵向拼接已有图片、主动保存贴图。
- 交接票据一次性、短时有效。带路径的外部 URL 先进入复核，不直接改文件。
- 输入规则可导出不可变修订。新规则、重新启用或执行语义变化必须本机复核后才启用。删除墓碑不会把规则复活。

## 未对齐

| 功能 | 原因 | 替代 |
| --- | --- | --- |
| 访达扩展、系统服务、右键注入 | Windows 没有 Finder Sync。本版不写注册表 | 把路径贴进操作面板，或用 `--paths` 传入 |
| Quick Look 里编辑加密包 | 没有 Finder 预览扩展 | 页面里的压缩包列表和隔离解压 |
| 辅助功能、输入监控 | Windows 权限模型不同 | 权限页说明窗口 API 和未注册的全局钩子；失败会直接报错 |
| 全局快捷键、鼠标侧键、触控板手势、原始触控 | 不安装低级键盘鼠标钩子，避免误伤系统输入 | 规则保存在本机，从操作面板执行 |
| 菜单栏、Dock、`⌘,` | 没有对应的 macOS 生命周期 | 浏览器里的设置区 |
| `gaocaozuo://` 协议注册 | 不注册 URL 协议 | 外部 URL 只进入复核队列 |
| 7Z、固实压缩、AES、7-Zip 分卷 | 标准库没有 7-Zip。本机没有 `7z.exe` 时明确失败 | 安装 7-Zip 后可以创建 7Z。ZIP 不依赖它 |
| JPEG、HEIC、TIFF、WebP、ICNS、iOS 图标集 | 不内置这些编码器，避免把失败说成成功 | PNG 与 BMP |
| 超过 213 字节的二维码 | 只实现到版本 10，避免输出不能扫描的图 | 缩短文本 |
| 系统 OCR、本机翻译、录屏录音 | 没有接入 Windows.Media.Ocr 或 Media Foundation，也不联网翻译 | 操作会返回不可用，不会给出空结果 |
| 长截图滚动注入 | 不向其他窗口注入滚轮 | 把已经得到的图片按重叠像素纵向拼接 |
| 屏幕录制授权和持续采集 | 只在按下捕获并确认后调用一次 GDI | 未确认不采集，不把画面写成历史 |
| 真正移动任意外部窗口的辅助功能事务 | CI 和无头环境不能代表桌面窗口管理器 | 几何和回滚用可替换后端测试。Windows 上若给出 hwnd，才调用 `SetWindowPos`，读回不一致就失败 |
| 逐设备鼠标速度、物理滚轮归属、Magic Mouse | 依赖 macOS IOHID，且硬件专项已取消 | 不写系统鼠标设置 |
| 调度中心、Space、显示器硬件亮度、Wi-Fi 电源 | 没有等价且安全的系统调用，不模拟快捷键 | 媒体键（音量、播放）在 Windows 上会真实提交 |
| 八语言完整界面 | Mac 文案量很大，本页正文是中文 | 设置里可以记语言字段，不宣称八语言覆盖 |
| iCloud 与正在运行的 Mac 版同时写 | 没有 CloudKit | 可选目录里的修订文件。不要两边同时写同一份 `settings.json` |
| 钥匙串 | 不把 Mac 钥匙串密码迁走 | 需要时再输入。选择保存时只留在本次进程的保管库 |
| 终端标签页、各编辑器 AppleEvent、Office GUI 验收 | 那些是 macOS 自动化 | Windows 上“在终端打开”会给出 `cmd /K`，确认后才启动 |
| 清洁模式遮罩 | 不是系统锁屏，依赖 macOS 事件通道 | 时限仍校验 30–180 秒，但不显示系统级遮罩 |
| WidgetKit、App Group | Windows 没有这些容器 | 不写小组件快照来冒充已注册 |

取消的硬件和样本专项（Magic Mouse、多屏热插拔、缺样本的 RAR/ACE 等）在 Windows 版同样不做，也不记为通过。
