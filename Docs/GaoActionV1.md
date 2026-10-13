# GaoAction V1：搞操作消费端与结果接收端

本文说明搞操作当前实现如何使用任务01规定的 GaoAction V1，不改变固定契约，不表示其他提供方已经安装、实现或通过端到端验收。

## 动作归属和能力探测

搞操作是消费者与结果接收者。`GaoCapabilities.json` 的 `actions` 为空；它不冒充搞整理的 `files.reveal` 或搞文件的文档动作，也不执行其他提供方的外来请求。

主应用文件动作按稳定ID映射：

| 本地ID | 固定动作 | 明确目标 |
|---|---|---|
| file.ishot | capture.region | com.gaoseries.GaoJieTu |
| file.capture.window | capture.window | com.gaoseries.GaoJieTu |
| file.capture.display | capture.display | com.gaoseries.GaoJieTu |
| file.ishot.markup | images.annotate | com.gaoseries.GaoJieTu |
| file.images.pin | images.pin | com.gaoseries.GaoJieTu |
| file.ocr | ocr.files | com.gaoseries.GaoJieTu |
| file.diskmap | storage.inspect（缺省metadata） | com.gaoseries.GaoJiLing |
| file.storage.duplicates | storage.inspect（mode=duplicates） | com.gaoseries.GaoJiLing |
| file.cleanup.review | cleanup.review | com.gaoseries.GaoJiLing |
| file.apps.uninstall.review | apps.uninstall.review | com.gaoseries.GaoJiLing |

旧 `ishot` / `diskmap` 字样只保留为配置动作ID，生产链路不再以打开旧工具代替完成。截图请求不携带未选择的屏幕内容；标注、贴图只接受一个图像副本；OCR仅接受选中的图像/PDF副本；扫描只引用一个明确目录；卸载只引用一个真实应用包，并要求提供方进入其原安全复核流程。

发送前定位明确 bundleID 的实际安装应用，读取其 `Contents/Resources/GaoCapabilities.json`，核对 schemaVersion=1、bundleID、与 Info.plist 一致的 appVersion、固定动作归属及参数 schema。不能只检测“应用存在”。参数 schema 应为 object，`properties` 只含该固定动作允许的键，`additionalProperties=false`。消费者验证请求值与提供方声明的类型、枚举及边界。未完成的可选参数必须删除或明确拒绝；`duplicates` 只有提供方真实声明该值才可用。

`supportsItems`、`supportsReferences` 是当前兼容的可选能力说明：缺省按固定动作输入契约处理，显式false则拒绝对应载荷。它们不取代动作 schema；`files.choose` 等可选复制模式仍需提供方另行明确支持。

能力缺失或不兼容时，不发出动作，不自动下载提供方。用户可主动导出本次私有包或在 Finder 显示；导出不意味着业务完成，过期包需重新生成。能力表只是安装应用的自述，不是密码学身份认证。

## 包和输入验证

文档扩展 `.gaoaction`，UTType `com.gaoseries.action-package`，conformsTo `com.apple.package`；只将此类型作为可选文档接收入口，不抢占所有包的默认处理程序。

包由 `manifest.json` 与 `payload/` 组成。固定字段：schemaVersion=1、kind、requestID(UUID)、sourceBundleID、targetBundleID、action、UTC createdAt/expiresAt、32字节随机数标准Base64 nonce、items、references、parameters。result另有inReplyTo、status、errorCode、provenance。请求/结果TTL均最多120秒；接收时检查过期，批准后的长任务不受原TTL中途取消。生产nonce使用系统安全随机源；固定零nonce只用于隔离fixture。

每个item包含id、payload内relativePath、uti、byteCount、sha256。最多256项、总载荷默认2GiB、manifest最多1MiB，超限明确拒绝分批，不截断。items只复制普通文件，不移动原件，不将目录或应用包伪装为附件。生成包的目录0700、文件0600；先完成副本与摘要，再写manifest，最后原子发布，不覆盖已有请求ID。

外部读取逐级使用`openat`与`O_NOFOLLOW`，固定FD、检查UID、权限、普通文件及独立链接数；拒绝符号链接、硬链接附件、路径逃逸、重复路径/ID、非法类型与尺寸。manifest在读取前检查尺寸，并在流式读取中继续设限。附件复制到接收方自己的有界staging，流式计算摘要并比较复制前后FD身份、大小与修改状态；文本动作在同一复制字节流中校验UTF-8。固定FD不能保证内容不被同UID进程并发修改，检测到变化或摘要错误即失败。

references是待核实原件描述，不是访问授权、可信身份或删除许可。字段包括id、kind、规范本机fileURL、displayName、declaredIdentity（volumeUUID/device/inode/byteCount/modifiedAt；未知值为null），应用另带bundleID，普通文件可附sha256。当前实现兼容早期嵌套application.bundleID和顶层bundleID；两者同时出现须一致。实际对象、非null身份字段、应用ID与可选摘要重新核对；身份不明确或权限不足即停止，提示接收方独立选择并确认原件。这里不传递跨签名bookmark权限，也不把payload副本当成待扫描目录或待卸载应用。

## 递交、关联、确认和恢复

使用 `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)` 显式指定安装目标，`allowsRunningApplicationSubstitution=false`。LaunchServices接收打开请求，只能表示递交；不能当作截图、清理、卸载、下载或其他业务完成。

私有资料下保存 `Exchange/Outgoing`、`Incoming`、`Journal`。journal按UUID持久记录prepared、dispatched、received、approved、executing、completed、interrupted；业务status独立保存pending/completed/partial/cancelled/failed/unsupported。接受pending结果仍保留pending，partial不提升为completed。结果必须匹配本App原请求的inReplyTo、动作、源/目标双方；没有匹配请求或同ID不同内容的结果拒绝接收。已知重复请求只展示旧状态，不复制新载荷、不重复副作用。

用户在“文件→跨应用任务…”可查看重启后任务、在Finder显示自己的包、继续核对已接收结果。接受前展示动作、来源声明、报告状态、附件名称和字节数，并说明来源与nonce不证明身份。用户点击接受后再次在后台用固定FD核验保留manifest与所有附件，再改变journal状态并显示副本；不自动执行附件，不覆盖已编辑原件。approved/executing中断后转interrupted，不能自动重放。显式重递交会提示旧任务可能仍在提供方执行，重新核验旧manifest/附件/原件引用，以新UUID和新TTL建立请求。

提供方返回结果必须在自己的Exchange生成新result包，再由用户“发送结果”显式交给原App；不得把私密正文、原路径、密码或Cookie写进URL、公共剪贴板、argv或日志。本App不提供本地HTTP控制服务。

## 结果语义与兼容核对

固定契约的结果语义继续适用：

- capture完成应返回真实图像，provenance含像素尺寸、scale、色彩空间；annotate返回新图像；pin只反映实际opened/closed，不虚构落盘产物。
- OCR逐输入/输出关联sourceItemID和sourceSHA256，保留逐页失败和partial。消费者递归检查来源关系，不强制提供方使用私有`sources`容器名。
- translate返回译文并说明provider及是否联网。
- cleanup/uninstall仅打开复核时为pending/awaitingUser；completed须有真实执行workflowState和receiptID。
- downloads accepted只能pending，并带真实taskIDs；完成须另发关联结果及实际输出/摘要。
- 文档打开/新建、定位等动作不凭空返回附件；未完成可选语义不得忽略后报成功。

当前消费端支持的常见元数据键写法：截图width/height或pixelWidth/pixelHeight或pixelSize对象，以及scale/colorSpace；多项可置outputs。翻译联网bool兼容networkUsed/isNetwork/networked。OCR输出来源可用itemID或resultItemID关联。固定契约未把所有provenance键名完全形式化，这些是当前解码适配说明，不是新增V1动作或改变语义。接入其他提供方时必须核对其实际产出，若采用其他等价字段需明确兼容适配并加入双方真实fixture；不能仅凭单方模拟认定互通通过。

## 留存预算与测试边界

除单包预算外，当前接收/发件共用8GiB、128包、65536项的留存上限，使用私有文件锁约束并发复制。达到上限停止接收/创建并提示人工核对，不按年龄删除未完成任务。失败校验的新接收副本可精确清理；不删除发送方包、原文档、失败恢复记录或用户备份。已保存journal仍用于幂等核验。

`Tests/GaoActionTests.swift`包含同名V1固定fixture和安全/状态回归：newText、实际目录identity、ocrPartial、duplicate、expired、pathTraversal、unknownAction、v2Unsupported，以及参数/目标/TTL/nonce、父级链接/硬链接、限额、复制中变更、确认期间变更、持久重放、pending后续结果、崩溃恢复和能力表缺失/不兼容。测试使用隔离临时资料；模拟应用不启动、不开权限、不处理真实用户文件。

这些测试只证明本项目消费端的对应行为。必须使用实际安装双方、实际用户确认与真实产物完成至少一份双方生成包的互换，才能证明端到端接入。缺提供方、能力表、设备或授权时应继续标未验收/阻塞，并保留原替代软件。
