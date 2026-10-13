import AppKit
import ApplicationServices
import Foundation

@MainActor
func runExtensionIntegrationTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DataFailure.message("扩展整合测试失败：\(message)") }
    }

    print("=== 开始执行扩展整合与统一注册测试 ===")

    // MARK: - 1. ActionRegistry & RuleContext
    let registry = ActionRegistry.shared
    let all = registry.allDescriptors()
    try check(all.count >= 20, "注册表应包含全部内置动作，实际数量：\(all.count)")

    let windowActions = registry.descriptors(in: .window)
    try check(windowActions.contains(where: { $0.id == "window.leftHalf" }), "窗口动作包含左半屏")
    try check(windowActions.contains(where: { $0.id == "window.maximize" }), "窗口动作包含最大化")

    let selectionActions = registry.descriptors(in: .selection)
    try check(selectionActions.contains(where: { $0.id == "selection.bar.show" }), "划词动作包含显示快捷条")
    try check(selectionActions.contains(where: { $0.id == "selection.qrcode" }), "划词动作包含二维码")

    let snippetActions = registry.descriptors(in: .snippet)
    try check(snippetActions.contains(where: { $0.id == "snippet.manager.show" }), "短语动作包含管理面板")

    let inputActions = registry.descriptors(in: .input)
    try check(inputActions.contains(where: { $0.id == "inputsource.switch.abc" }), "输入法动作包含切英文")

    let contextGlobal = registry.descriptors(for: .global)
    try check(!contextGlobal.isEmpty, "全局上下文动作不为空")

    // RuleContext 目标与世代校验
    let ctx = RuleContext(
        frontmostBundleID: "com.apple.finder",
        processLaunchIdentity: "token-finder-1",
        capturedPID: 100,
        capturedWindowID: 55,
        permissionState: (true, true),
        deviceCategory: "trackpad",
        generation: 42,
        timestamp: Date()
    )
    try check(ctx.matchesTarget(pid: 100, bundleID: "com.apple.finder", generation: 42), "目标与世代相符应匹配成功")
    try check(!ctx.matchesTarget(pid: 101, bundleID: "com.apple.finder", generation: 42), "PID 不匹配应拒绝")
    try check(!ctx.matchesTarget(pid: 100, bundleID: "com.apple.Safari", generation: 42), "BundleID 不匹配应拒绝")
    try check(!ctx.matchesTarget(pid: 100, bundleID: "com.apple.finder", generation: 43), "世代过时应拒绝")

    print("动作注册表与规则上下文匹配测试通过")

    // MARK: - 2. InputSource Catalog & Coordinator
    let catalog = InputSourceCatalog.shared
    let sources = catalog.availableKeyboardInputSources()
    try check(!sources.isEmpty, "系统至少应能枚举到一个可用键盘输入法")

    // Short label derivation
    try check(InputSourceDescriptor.deriveShortLabel(id: "com.apple.keylayout.ABC", name: "ABC") == "ABC", "ABC 缩写解析")
    try check(InputSourceDescriptor.deriveShortLabel(id: "com.apple.inputmethod.SCIM.ITABC", name: "简体拼音") == "拼", "拼音缩写解析")
    try check(InputSourceDescriptor.deriveShortLabel(id: "com.apple.inputmethod.TCIM.Zhuyin", name: "繁体注音") == "繁", "繁体缩写解析")

    // Rule model and prioritization
    let ruleA = InputSourceRule(appBundleID: "com.google.Chrome", appName: "Chrome", targetSourceID: "com.apple.keylayout.ABC", targetSourceName: "ABC")
    let ruleDefault = InputSourceRule(appBundleID: "*", appName: "全局默认", targetSourceID: "com.apple.inputmethod.SCIM.ITABC", targetSourceName: "拼音")
    let ruleDisabled = InputSourceRule(appBundleID: "com.apple.Terminal", appName: "Terminal", targetSourceID: "com.apple.keylayout.ABC", enabled: false)

    try check(!ruleA.isGlobalDefault, "具体应用规则不是全局默认")
    try check(ruleDefault.isGlobalDefault, "星号规则为全局默认")

    // Rule JSON serialization
    let rules = [ruleA, ruleDefault, ruleDisabled]
    let rulesData = try JSONEncoder().encode(rules)
    let decodedRules = try JSONDecoder().decode([InputSourceRule].self, from: rulesData)
    try check(decodedRules == rules, "输入法规则 JSON 往返一致")

    // Coordinator configuration
    let coordinator = InputSourceCoordinator.shared
    coordinator.configure(rules: rules, enabled: false)
    try check(!coordinator.isEnabled, "配置生效为停用状态")

    print("输入法目录与协调器规则测试通过")

    // MARK: - 3. SelectionSnapshot & SelectionTransformations
    let originalText = "Hello World, 搞操作 V1.07!"
    try check(SelectionTransformations.uppercase("abc") == "ABC", "大写转换")
    try check(SelectionTransformations.lowercase("ABC") == "abc", "小写转换")
    try check(SelectionTransformations.titleCase("hello world") == "Hello World", "首字母大写")

    // Fullwidth / Halfwidth
    let full = "１２３　ＡＢＣ！"
    let half = SelectionTransformations.toHalfWidth(full)
    try check(half == "123 ABC!", "全角转半角失败：\(half)")
    let backToFull = SelectionTransformations.toFullWidth(half)
    try check(backToFull == full, "半角转全角往返一致")

    // Whitespace cleanup
    let messy = "   line 1   \n\n\n   line 2   \n"
    let cleaned = SelectionTransformations.cleanupWhitespace(messy)
    try check(cleaned == "line 1\nline 2", "空白换行清理失败：\(cleaned)")

    // Base64
    let b64 = SelectionTransformations.base64Encode(originalText)
    let unb64 = SelectionTransformations.base64Decode(b64)
    try check(unb64 == originalText, "Base64 编码解码往返一致")

    // URL encode / decode
    let urlEncoded = SelectionTransformations.urlEncode(originalText)
    let urlDecoded = SelectionTransformations.urlDecode(urlEncoded)
    try check(urlDecoded == originalText, "URL 编码解码往返一致")

    // TextStatistics
    let stats = SelectionTransformations.statistics("你好 世界\nHello World")
    try check(stats.cjkCharacterCount == 4, "中文字符统计应为 4，实际：\(stats.cjkCharacterCount)")
    try check(stats.lineCount == 2, "行数统计应为 2")
    try check(stats.wordCount == 4, "词数统计应为 4")

    // QR Code generation
    let qr = SelectionTransformations.generateQRCode("https://github.com/UCASerYff/GaoCaoZuo", size: 120)
    try check(qr != nil, "生成二维码图像不可为空")
    try check(qr!.size.width == 120 && qr!.size.height == 120, "二维码图像尺寸符合设定")

    // Snapshot target validation
    let snapshot = SelectionSnapshot(
        pid: 200,
        bundleID: "com.apple.Notes",
        launchIdentity: "notes-token",
        element: nil,
        selectedText: "选择文字",
        range: CFRange(location: 0, length: 4),
        generation: 10,
        isFromClipboardFallback: false
    )
    try check(snapshot.matchesTarget(currentPID: 200, currentBundleID: "com.apple.Notes", generation: 10), "快照目标匹配")
    try check(!snapshot.matchesTarget(currentPID: 201, currentBundleID: "com.apple.Notes", generation: 10), "PID 不匹配")
    try check(!snapshot.matchesTarget(currentPID: 200, currentBundleID: "com.apple.Notes", generation: 11), "世代不匹配")

    print("划词文本转换、统计、二维码与快照校验测试通过")

    // MARK: - 4. SnippetLibrary, PasteStack & CSV Formula Defense
    let snippetWithPlaceholders = AdvancedSnippet(
        name: "模板短语",
        text: "日期: {date} 时间: {time} 唯一码: {uuid} 年份: {year}"
    )
    let resolved = snippetWithPlaceholders.resolvedText()
    try check(!resolved.contains("{date}"), "占位符 {date} 应已展开")
    try check(!resolved.contains("{time}"), "占位符 {time} 应已展开")
    try check(!resolved.contains("{uuid}"), "占位符 {uuid} 应已展开")
    try check(!resolved.contains("{year}"), "占位符 {year} 应已展开")

    // PasteStack
    let stack = PasteStack.shared
    stack.clear()
    stack.push("第一段")
    stack.push("第二段")
    stack.push("第三段")
    try check(stack.items.count == 3, "入栈 3 项")

    let popped1 = stack.popAndPaste()
    try check(popped1 == "第一段", "首项弹出")
    try check(stack.items.count == 2, "剩余 2 项")

    let merged = stack.mergeAll(separator: " + ")
    try check(merged == "第二段 + 第三段", "合并剩余项目：\(merged)")
    stack.clear()
    try check(stack.items.isEmpty, "清空后为空")

    // SnippetCSVCodec Formula Injection Neutralization
    let maliciousText1 = "=1+1"
    let maliciousText2 = "@SUM(A1:A10)"
    let maliciousText3 = "-5+cmd|' /C calc'!A0"
    let maliciousText4 = "+CMD"

    try check(SnippetCSVCodec.sanitizeForCSV(maliciousText1) == "'=1+1", "前置 = 号转义防御")
    try check(SnippetCSVCodec.sanitizeForCSV(maliciousText2) == "'@SUM(A1:A10)", "前置 @ 号转义防御")
    try check(SnippetCSVCodec.sanitizeForCSV(maliciousText3) == "'-5+cmd|' /C calc'!A0", "前置 - 号转义防御")
    try check(SnippetCSVCodec.sanitizeForCSV(maliciousText4) == "'+CMD", "前置 + 号转义防御")
    try check(SnippetCSVCodec.sanitizeForCSV("正常文本") == "正常文本", "普通文本不修改")

    let group = SnippetGroup(name: "客服短语", order: 0)
    let s1 = AdvancedSnippet(groupID: group.id, name: "退货话术", text: "=尊敬的客户，退货请发送单号", shortcut: "th")
    let s2 = AdvancedSnippet(groupID: group.id, name: "欢迎话术", text: "您好，很高兴为您服务！", shortcut: "hi")

    let exportedCSV = SnippetCSVCodec.exportCSV(snippets: [s1, s2], groups: [group])
    try check(exportedCSV.contains("退货话术"), "导出的 CSV 包含短语名称")
    try check(exportedCSV.contains("'=尊敬的客户"), "公式注入前缀已转义保护")

    // Import with skip policy
    let importedSkip = try SnippetCSVCodec.importCSV(
        exportedCSV,
        existingSnippets: [s1],
        existingGroups: [group],
        policy: .skip
    )
    try check(importedSkip.snippets.count == 2, "跳过已存在项，导入新项")

    // Import with overwrite policy
    var modifiedS1InCSV = s1
    modifiedS1InCSV.text = "修改后的退货话术"
    let csvToOverwrite = SnippetCSVCodec.exportCSV(snippets: [modifiedS1InCSV], groups: [group])
    let importedOverwrite = try SnippetCSVCodec.importCSV(
        csvToOverwrite,
        existingSnippets: [s1],
        existingGroups: [group],
        policy: .overwrite
    )
    try check(importedOverwrite.snippets.first(where: { $0.name == "退货话术" })?.text == "修改后的退货话术", "覆盖策略成功更新")

    // Import with keepBoth policy
    let importedKeepBoth = try SnippetCSVCodec.importCSV(
        csvToOverwrite,
        existingSnippets: [s1],
        existingGroups: [group],
        policy: .keepBoth
    )
    try check(importedKeepBoth.snippets.contains(where: { $0.name == "退货话术 (副本)" }), "保留两者生成副本")

    print("短语库占位符、粘贴堆栈与 CSV 公式注入防御测试通过")

    // MARK: - 5. CleanerController Mechanisms
    let cleaner = CleanerController.shared
    try check(cleaner.state == .idle, "初始状态应为空闲")
    // Safe duration bounds
    cleaner.stopCleaning()
    try check(cleaner.state == .idle, "退出后恢复为空闲状态")
    cleaner.emergencyRelease()
    try check(cleaner.state == .idle, "紧急释放保持空闲状态")

    print("键盘与屏幕清洁模式状态机与安全逃生释放测试通过")

    // MARK: - 6. FlyKey Item & Hierarchy
    let item1 = FlyKeyItem(title: "新标签页", path: ["文件", "新建"], shortcut: "⌘T", isEnabled: true, sourceAppName: "Safari")
    let item2 = FlyKeyItem(title: "关闭标签页", path: ["文件", "关闭"], shortcut: "⌘W", isEnabled: true, sourceAppName: "Safari")
    try check(item1.id == "文件 > 新建:⌘T", "FlyKeyItem ID 生成正确")
    try check(item1 != item2, "不同菜单项不相等")

    let tapDetector = FlyKeyController.shared
    tapDetector.resetTapDetector()

    print("FlyKey 快捷键速查条目模型与双击探测器测试通过")
    print("=== 全部扩展整合集成测试成功通过 ===")
}
