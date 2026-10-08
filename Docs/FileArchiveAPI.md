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

## ArchiveService

`@MainActor ObservableObject`，发布 `isRunning`、`progress: Double?`、`output`、`lastResultURL`。`progress == nil` 表示真实的不确定进度阶段。`cancel()` 取消当前任务，必要时终止子进程，保留原始输入。

- `ArchiveFormat.zip` / `.sevenZip`（rawValue 为 `zip` / `7z`）。
- `create(items:destination:format:password:splitMB:solid:)` 的 destination 是完整输出文件名。支持 ZIP/7Z、多线程、AES 加密、分卷、7Z 固实及 7Z 文件名加密。返回输出文件，分卷时返回 `.001`。完整性测试成功后才提交结果。
- `list(archive:password:)` 返回 `[ArchiveEntry]`，每项包含 `path`、`size`、`isDirectory`、`id`，以及可选 `permissions`、`modifiedAt`。
- `extract(archive:to:password:selected:)` 的 to 必须是不存在的新目录。selected 为目录列表中准确的路径，可为 nil（全部），不接受空数组。
- 默认从应用 `Resources/Tools/7zz` 加载引擎。`init(engineURL:)` 只用于明确的开发/测试注入。

引擎为官方 7-Zip 26.04 的 macOS Universal 独立可执行程序。可读取该引擎支持的普通归档格式，例如 ZIP、7Z、RAR、TAR。RAR 只解压，不创建。压缩容器分层处理：例如 `.tar.gz` 先产生 `.tar`，再解压 TAR；此版不自动递归展开多层容器。具体格式、加密算法与变体仍受引擎能力及本应用安全预检限制。

解压先拒绝路径穿越、绝对路径、危险链接、特殊文件、大小写/规范化重名和文件/目录冲突。预算为展开总量 20 GiB、目录项 10 万个、目录信息 64 MiB、每个任务最多一小时。

解码引擎通过系统隔离配置禁止网络和文件系统写入，仅将所选文件的内容输出到管道。主程序向私有暂存目录中的核验路径逐文件写入，并对每个文件的实际输出字节数实施上限；随后再次核验目录结构、类型、尺寸、链接数，成功后原子提交新目录。密码通过私有 stdin 管道提交，不写入命令行参数、日志或临时文件。日志还会执行密码脱敏。

全部内容和路径通过核验后，才恢复目录元数据中可识别的普通 UNIX rwx 权限和修改时间。执行位保留，setuid/setgid/sticky 等特殊位不恢复；为保证用户始终能访问结果，额外保证文件所有者可读写、目录所有者可读写进入。因此，原本只读或无所有者权限的项目会获得所有者访问权限。无法识别的权限回退为文件 `0600`、目录 `0700`；无法识别的修改时间保留提取时的时间。不恢复 ACL、扩展属性、资源分叉、所有者/组身份或 Finder 标记。ZIP 时间精度受格式限制。

此实现优先限制解码器写入范围。固实包逐文件提取可能反复解码同一固实块，大量文件时比单次批量解压慢。符号链接/硬链接不提取；有些应用包、开发依赖包因此会被拒绝。普通可执行脚本的执行位可保留，但不承诺含链接或依赖扩展元数据的 `.app` 完整可运行。此版不会执行解压内容，也不会覆盖目标目录。

## Finder 扩展

模块及主类均为 `GaoFinderSync`。Principal class：`GaoFinderSync.GaoFinderSync`。

仅监视真实账户的 Desktop、Downloads、Documents，不监视整块磁盘。菜单动作：`new.text`、`new.markdown`、`path.copy`、`files.copy`、`files.move`、`files.rename`、`archive.create`、`archive.extract`。

通过 `gaocaozuo://perform/<actionID>?payload=<base64>` 打开主应用。payload 为 UTF-8 JSON 绝对路径数组。扩展本身不修改文件。主应用必须再次验证动作白名单和路径，仅预置界面，不能收到链接即执行文件修改。在云盘目录或扩展不可用的上下文中，使用主应用面板/系统服务入口。

## 验证

`Tests/FileToolsTests.swift` 提供唯一可调用入口 `@MainActor func runFileToolsTests() async throws`，没有 `@main`。测试主程序通过 `--engine /absolute/path/to/7zz` 提供引擎。全部测试只使用临时创建的样本；恢复测试显式使用 `trashCreated: false`，不触碰用户废纸篓。

2026-10-08：56 项检查通过，包括真实 ZIP 往返、选择提取、7Z 加密/分卷/固实/中文密码、错误密码处理、取消保留原件、目录指纹、修改后拒绝恢复、改名恢复、图片批次回滚、二维码 PNG、安全路径/链接/容量预检和恢复记录序列化；还验证了 ZIP/7Z 执行位与历史修改时间、安全位剥离、已完成撤销重试和半批恢复继续。Finder 扩展及独立文件/压缩模块均编译通过。CoreImage 和嵌套系统隔离需在普通 macOS 进程环境测试，不能在额外限制的命令执行沙盒中代表真实应用行为。
