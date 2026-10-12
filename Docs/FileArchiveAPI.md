# 文件工具、压缩与 Finder 集成

## FileTools

`FileTools` 是静态方法集合。创建、复制、移动、改名、图片转换均拒绝覆盖现有项目，包括悬空符号链接。读取失败和特殊文件不会视为空文件。目录操作拒绝链接及设备等特殊文件，并限制为 10 万个目录项。

- `createFile(in:name:content:)`：在现有目录创建 UTF-8 文件，返回 URL。
- `copy(items:to:move:)`：复制先整批写入私有暂存并核验，核验全部通过才提交到公开目标目录；移动后再次核验内容指纹。返回 `[FileOperationReceipt]`。
- `renamePreview(items:pattern:start:)`：生成 `[RenamePlan]`，不改动文件。模板支持 `{name}`、`{ext}`、`{n}`、`{n:03}`；扩展名不含点。例：`{name}_{n:03}.{ext}`。重名、大小写冲突和跨目录改名拒绝执行。
- `applyRenames(_:)`：应用经过再次检查的计划，返回恢复记录。
- `undo(_:trashCreated:)`：`trashCreated` 默认为 `true`。移动、改名恢复到原位置；创建、复制、转换的结果移入废纸篓。所有目标须与记录的内容指纹一致，且原路径不得被其他项目占用。已恢复且指纹一致的移动/改名，以及已经移走的创建/复制结果，可识别为已完成，继续重试剩余批次。内部失败回滚和隔离测试才使用 `trashCreated: false`，并且仍执行指纹核验。
- `convertImages(items:to:format:maxDimension:)`：支持 PNG、JPEG、HEIC、TIFF 单图转换及最长边缩放。最多 1 亿像素、最长边 32768 像素。去除源定位等元数据。整批先编码到私有暂存目录，全部成功才提交；不在用户目录留下正常失败的半批转换结果。
- `sha256(_:)`：流式计算普通文件 SHA-256。
- `qrCode(text:)`：生成带四模块留白的 PNG，内容上限 2000 UTF-8 字节。
- `fingerprint(_:)`：供创建/转换动作写恢复记录时使用，包含内容、相对路径及 POSIX 权限。

恢复记录为 Codable 的 `FileOperationReceipt`：`id`、`date`、`kind`（create/copy/move/rename/convert）、`source: URL?`、`destination`、`fingerprint`。`RenamePlan` 含 `id`、`source`、`destination`。指纹校验用于防止撤销时删除后来被修改的文件；它不替代应用资料备份。

批量文件操作和跨文件系统移动不承诺整体原子性。操作失败会逐项检查和回滚，目标被其他程序改动或文件系统拒绝回滚时保留资料，抛出 `FileToolsPartialFailure`；调用方须将其 `receipts` 保留到恢复历史并展示错误。该错误另含 `underlyingMessage`。撤销批次中途失败会报告已核验完成数；调用方只能在整批成功后清除原恢复记录。跨设备恢复后再次核验内容和权限；若目标文件系统改变权限或 I/O 中途失败，停止并保留恢复记录及现有资料，不作“恢复成功”的判断。

## QuickFileActions

快捷入口复用下述文件安全和压缩预检，不绕过覆盖保护。

- `uniqueURL(in:preferredName:isDirectory:)` 选择未占用名字；例如 `foo.zip`、`foo 2.zip`。悬空符号链接也算占用，读取错误不能视为空目录。此函数不预占路径，实际提交仍拒绝并发出现的重名。
- `create(in:kind:)`（`.text` / `.markdown` / `.folder`）创建唯一名的“未命名.txt”“未命名.md”“新建文件夹”，返回恢复记录。
- `createTemplate(in:filename:content:)` 按模板创建唯一名文件，返回恢复记录。
- `copy(items:to:move:)` 用于收藏目录，保留原文件名并复用 `FileTools.copy`；已有同名目标时报错，不覆盖。
- `createArchive(items:format:service:)` 为 `@MainActor async throws`，支持默认无密码 ZIP/7Z；单选按原项目名，多选按“归档”，保存到第一项的父目录并自动避重名。返回 URL。`createZIP(items:service:)` 为 ZIP 便捷入口。
- `makeExtractionBatch(archives:)` 预检并去重，返回 `QuickExtractionBatch`。调用 `@MainActor continueExtraction(_:service:password:stopAfterFirstSuccess:) async` 返回更新后的批次，遇首个需要密码、错误或取消即暂停。每项有 `archive`、`output`、`receipt` 和 `status`（pending / needsPassword(incorrect:) / completed / failed(message) / cancelled）。批次提供 `outputs`、`currentItem`、`isComplete`。`stopAfterFirstSuccess` 默认 false；正式调用方传 true，每完成一个压缩包就保存该项已有的 receipt，然后继续 pending 项。指纹在结果对用户可见前生成，不应事后对可编辑输出重新计算。调用方必须保存返回的批次并用于继续；已完成条目不再提交给引擎，密码只用于当前条目且不存入批次。每个包解压到同目录独立、唯一命名的新文件夹。
- `convertImages(items:format:maxDimension:)` 同步返回 `[FileOperationReceipt]`，应在非主线程执行。结果放在各自原目录，自动避让原件、现有结果及批次内重名。整批先在各自父目录私有暂存完成，再提交；正常失败清除暂存并核验回滚，无法安全回滚时返回 `FileToolsPartialFailure.receipts`，调用方必须保留到恢复记录。

## ArchiveService（V1.03）

`@MainActor ObservableObject` 发布任务状态、真实进度或不确定进度、输出与结果。`cancel()` 终止当前任务并保留输入。`lastResultReceipts` 在结果公开前生成，调用方先持久化记录，再执行可选的原件移到废纸篓步骤。

- `create(items:destination:format:password:splitMB:solid:options:)`：创建 ZIP/7Z；参数包含等级、线程、文件名加密、忽略规则、日期及分别打包设置。分卷返回 `.001`，全部分卷分别登记恢复记录。忽略规则和删除原件不能同时开启。
- `list(archive:password:options:)`：返回已通过路径、容量、重名与链接预检的条目，包含尺寸、权限、修改时间和可选链接目标。
- `extract(archive:to:password:selected:options:)`：输出必须是不存在的新目录。可选择准确条目路径；默认递归展开支持的 TAR 容器。默认预算 20 GiB、10 万项、一小时，可配置。
- `extractIntoDirectory(archive:to:password:selected:options:)`：在已存在目录展开，先完成全包隔离核验，再逐个提交顶层项目；任何重名停止，不合并或覆盖。返回所有顶层结果。
- `edit(archive:password:adding:removing:removeHidden:saveTo:backupDirectory:options:extraction:)`：仅 ZIP/7Z，解压到私有工作副本，修改后重建并测试。保存原路径前核验源指纹、创建备份，再替换；保留原包 POSIX 权限。另存不会覆盖现有目标。

随包引擎为官方 7-Zip 与独立 Python 格式桥接。中文密码 ZIP 使用 pyzipper/PyCryptodome；密码通过私有 stdin 提交，不进入命令行或日志。ACE/LZIP 等特殊格式按具体变体测试，不能据此推断所有变体支持。RAR 不创建，ACE 加密、LZ77 和多卷未完成验收。来源与许可见 `Docs/Licenses`。

提取进程通过系统隔离限制网络与文件写入，内容经管道由主程序写入已校验的暂存路径；逐项限制实际字节数，并再次检查结构、类型、尺寸。允许包内安全相对软链接；危险、绝对、越界、循环及未核验目标拒绝。受支持的硬链接作为独立文件提取。普通文件动作仍拒绝含链接目录，压缩恢复记录使用 `FileTools.archiveFingerprint`，无链接目录与旧指纹格式兼容。

完整提取验证后恢复普通 rwx 位和修改时间，剥离特殊位及其他用户所有权，额外保证所有者可读、目录可进入；0444 文件保持只读。`ArchiveMacMetadata` 通过本应用标记的 AppleDouble 记录往返 xattr、资源分叉与 ACL，普通 `._` 文件名不自动删除。元数据受目标文件系统支持范围限制，不承诺每个应用包完整可运行。

`ArchiveEnhancementController` 管理偏好、包内浏览和钥匙串密码本。普通压缩、解压进入统一可取消队列，已完成结果先保存，密码重试不会重做已完成包。主动导出密码本会生成明文普通文件，创建时即采用 0600，不覆盖已有文件。

## Finder 与 Quick Look

Finder 模块/主类为 `GaoFinderSync.GaoFinderSync`，监视用户主目录和可选外接卷。`FinderMenuPreferences` 保存开关、名称、顺序、图标、分组与排除目录；命名粘贴板发布只读菜单快照，主程序仍通过真实 UUID 解析目录、模板和应用。

空白目录菜单支持当前目录路径、新建、粘贴等动作，选中文件菜单区分容器动作和选择动作。扩展与备用 Finder 菜单使用相同上下文判断和排除规则。工具栏入口由 Finder 自定义工具栏管理。

扩展写入带随机 256 位 nonce 的独立本机票据，通过 `gaocaozuo://finder?ticket=<nonce>` 唤起所属主应用。主程序一次性读取并销毁，校验白名单、绝对路径、数量、大小与60秒时效。旧式 `perform?payload=` 只准备复核，不直接修改文件。票据防止网页仅构造链接执行文件操作，不提供本机恶意进程身份认证。

`GaoArchiveQuickLook` 为独立目录预览扩展，使用只读选择文件权限，通过系统 libarchive 在进程内读取目录，不启动子工具、不提取成员或写入文件。读取量、目录数量、目录文字和部分元数据受预算约束；时间限制是读取回调协作式检查，不能保证打断系统库内部所有运算。加密、超出预算或系统库不支持的变体明确提示使用主程序。ACE、LZOP、Zstandard 等预览边界以实际系统库与测试为准，主程序使用随包引擎，格式支持与预算另行规定。系统可能选择其他已注册扩展，源码编译和扩展注册不等于已完成 Finder 空格预览实机验收。

## 验证

`Tests/FileToolsTests.swift` 提供唯一可调用入口 `@MainActor func runFileToolsTests() async throws`，没有 `@main`。测试主程序通过 `--engine /absolute/path/to/7zz` 提供引擎。全部测试只使用临时创建的样本；恢复测试显式使用 `trashCreated: false`，不触碰用户废纸篓。

2026-10-08：56 项检查通过，包括真实 ZIP 往返、选择提取、7Z 加密/分卷/固实/中文密码、错误密码处理、取消保留原件、目录指纹、修改后拒绝恢复、改名恢复、图片批次回滚、二维码 PNG、安全路径/链接/容量预检和恢复记录序列化；还验证了 ZIP/7Z 执行位与历史修改时间、安全位剥离、已完成撤销重试和半批恢复继续。Finder 扩展及独立文件/压缩模块均编译通过。CoreImage 和嵌套系统隔离需在普通 macOS 进程环境测试，不能在额外限制的命令执行沙盒中代表真实应用行为。

2026-10-11：核心 58 项和 `runQuickFileActionsTests()` 快捷 43 项通过，包括创建/模板/图片唯一命名和恢复、悬空链接占位、图片半批失败清理、收藏目录复制移动、真实单选/多选 ZIP 与 7Z、ZIP/7Z 缺密码及错密码、密码只用于当前项、已完成批次不重复解压、正常损坏不误报密码、取消。还验证跨父目录选择、同名来源拒绝且不留结果、逐项记录、半批取消不误报完成、分卷记录和用户编辑后拒绝恢复。两组测试均使用项目内正式 7zz 和随机临时文件。

V1.03 新增专项：配置迁移中断恢复、动态菜单与目录上下文、真实文档模板、文件属性与剪切恢复、输入与窗口规则、中文密码 ZIP、编辑备份、分卷、安全链接、递归容器和 macOS 元数据。完整测试入口 `Scripts/test.sh`；历史测试记录不代表新版本已安装或全部硬件已验收。
