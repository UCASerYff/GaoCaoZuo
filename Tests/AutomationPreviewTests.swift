import Foundation

func runAutomationPreviewTests() throws {
    var checks = 0
    func expect(_ test: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try test() else { throw DataFailure.message("规则试跑测试失败：" + label) }
        checks += 1
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gao-rule-preview-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("synthetic.txt", isDirectory: false)
    try Data("fixture".utf8).write(to: existing, options: .withoutOverwriting)
    let absent = root.appendingPathComponent("absent.txt", isDirectory: false)
    let catalog = AutomationPreview.Catalog(actions: OperationAction.all)

    let global = InputBinding(actionID: "archive.create")
    let scoped = InputBinding(actionID: "archive.7z", appBundleID: "com.example.synthetic")
    var sample = AutomationPreview.Sample(application: "com.example.synthetic", fileLines: absent.path)
    var result = AutomationPreview.basic(global, bindings: [global, scoped], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.checks.contains { $0.state == .mismatch } && result.steps.map(\.state) == [.skipped], "应用专用规则覆盖全局规则")
    result = AutomationPreview.basic(scoped, bindings: [global, scoped], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.canPlanSteps && result.steps.first?.paths == [root.path + "/absent.7z"], "通过真实规则匹配器并推算原目录归档名称")

    let duplicate = InputBinding(actionID: "panel.show", appBundleID: scoped.appBundleID)
    result = AutomationPreview.basic(scoped, bindings: [duplicate, scoped], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.checks.contains { $0.state == .blocked } && result.steps.map(\.state) == [.skipped], "同一作用域的重复触发阻断")
    result = AutomationPreview.basic(scoped, bindings: [scoped], excludedApps: [scoped.appBundleID], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps, "模拟应用命中排除名单")
    sample.configuredTrigger = false
    result = AutomationPreview.basic(scoped, bindings: [scoped], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.checks.contains { $0.state == .mismatch } && result.steps.first?.paths.isEmpty == true, "不同触发不生成动作")
    sample.configuredTrigger = true
    result = AutomationPreview.basic(scoped, bindings: [scoped], excludedApps: [], paused: true, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps, "暂停输入时跳过动作")

    var syntheticTrigger = AutomationPreview.BasicInput(scoped)
    syntheticTrigger.keyCode += 1
    sample.basicInput = syntheticTrigger
    result = AutomationPreview.basic(scoped, bindings: [scoped], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.checks.contains { $0.state == .mismatch }, "模拟键码由实际匹配规则判定")
    let gesture = InputBinding(actionID: "panel.show", trigger: .gesture, direction: "left")
    syntheticTrigger = .init(gesture)
    syntheticTrigger.dragDistance = 69
    sample.basicInput = syntheticTrigger
    result = AutomationPreview.basic(gesture, bindings: [gesture], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps, "短于原生阈值的模拟拖动不匹配")
    syntheticTrigger.dragDistance = 70
    sample.basicInput = syntheticTrigger
    result = AutomationPreview.basic(gesture, bindings: [gesture], excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.canPlanSteps, "达到原生阈值的模拟拖动匹配")
    sample.basicInput = nil

    let saved = InputBinding(actionID: "panel.show")
    var draft = saved
    draft.actionID = "files.move"
    let bindings = [saved]
    sample.directory = root.path
    result = AutomationPreview.basic(draft, bindings: bindings, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.steps.map(\.state) == [.blocked] && bindings[0] == saved, "无效目标阻断草稿计划且不修改保存规则")
    sample.directory = root.appendingPathComponent("synthetic-destination", isDirectory: true).path
    result = AutomationPreview.basic(draft, bindings: bindings, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.steps.first?.paths == [sample.directory + "/absent.txt"], "根据模拟目录推算移动目的地")

    var enhanced = EnhancedInputRule()
    enhanced.enabled = true
    enhanced.effect.kind = .openTargets
    enhanced.effect.openTargets = [absent.path, "https://example.invalid/preview"]
    var configuration = InputEnhancementConfiguration()
    configuration.enabled = true
    configuration.rules = [enhanced]
    result = AutomationPreview.enhanced(enhanced, configuration: configuration, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.steps.first?.state == .unknown && result.steps.first?.paths == enhanced.effect.openTargets, "高级打开目标只产生路径和未知效果")
    configuration.cloudPendingScriptRules = [enhanced.id]
    result = AutomationPreview.enhanced(enhanced, configuration: configuration, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps && result.steps.map(\.state) == [.skipped], "同步规则待复核")
    configuration.cloudPendingScriptRules = []
    var peer = enhanced
    peer.id = UUID()
    configuration.rules.append(peer)
    result = AutomationPreview.enhanced(enhanced, configuration: configuration, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps && result.steps.map(\.state) == [.skipped], "高级规则按原生冲突判据阻断")
    configuration.rules = [enhanced]
    enhanced.effect.kind = .menuItem
    enhanced.effect.menuBundleID = sample.application
    enhanced.effect.menuPath = ["Synthetic", "Example"]
    result = AutomationPreview.enhanced(enhanced, configuration: configuration, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(result.steps.map(\.state) == [.blocked], "缺少身份校验证据的菜单动作阻断")
    enhanced.trigger = .touch
    result = AutomationPreview.enhanced(enhanced, configuration: configuration, excludedApps: [], paused: false, healthy: true, sample: sample, catalog: catalog)
    try expect(!result.canPlanSteps, "实验触控关闭时阻断")

    let workflow = OperationWorkflow(name: "Synthetic", steps: [
        .init(actionID: "open.path", argument: absent.path), .init(actionID: "delay", argument: "3.0"),
        .init(actionID: "text.copy", argument: "synthetic private clipboard text"),
        .init(actionID: "open.url", argument: "file://synthetic/path"), .init(actionID: "window.leftHalf")
    ])
    result = AutomationPreview.workflow(workflow, busy: false, healthy: true)
    try expect(result.steps.map(\.state) == [.unknown, .planned, .planned, .blocked, .skipped], "组合操作顺序、阻断和后续跳过")
    try expect(result.steps[0].paths == [absent.path] && result.steps[2].paths.isEmpty && !result.steps[2].detail.contains("clipboard text"), "路径不打开，剪贴板值不回显")
    try expect(AutomationPreview.workflow(workflow, busy: true, healthy: true).steps.allSatisfy { $0.state == .skipped }, "主任务忙碌时不预测执行")
    let imported = OperationWorkflow(name: "Synthetic unsupported", steps: [.init(actionID: "archive.create"), .init(actionID: "delay", argument: "1")])
    try expect(AutomationPreview.workflow(imported, busy: false, healthy: true).steps.map(\.state) == [.blocked, .skipped], "不把普通动作库动作当作组合操作步骤")
    try expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [existing.lastPathComponent], "没有写入模拟文件、目录或输出")
    try expect(try Data(contentsOf: existing) == Data("fixture".utf8), "合成原件逐字节保留")
    print("规则与组合操作只读试跑通过：\(checks) 项。")
}
