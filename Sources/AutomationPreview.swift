import Foundation

enum AutomationPreview {
    enum State: Equatable {
        case matched, mismatch, planned, unknown, blocked, skipped

        var title: String {
            switch self {
            case .matched: return L10n.text("命中")
            case .mismatch: return L10n.text("未命中")
            case .planned: return L10n.text("预计")
            case .unknown: return L10n.text("不确定")
            case .blocked: return L10n.text("已阻断")
            case .skipped: return L10n.text("已跳过")
            }
        }
    }

    struct Line: Equatable {
        let state: State
        let title: String
        let detail: String
        var paths: [String] = []
    }

    struct Report: Equatable {
        var checks: [Line]
        var steps: [Line]

        var canPlanSteps: Bool { !checks.contains { $0.state == .blocked || $0.state == .mismatch } }
    }

    struct BasicInput: Equatable {
        var trigger: InputTrigger
        var keyCode: UInt16
        var modifiers: UInt64
        var mouseButton: Int
        var direction: String
        var dragDistance = 100

        init(_ rule: InputBinding) {
            trigger = rule.trigger
            keyCode = rule.keyCode
            modifiers = rule.modifiers
            mouseButton = rule.mouseButton
            direction = ["left", "right", "up", "down"].contains(rule.direction) ? rule.direction : "right"
        }

        var recognizedDirection: String? {
            let vectors = ["left": CGPoint(x: -1, y: 0), "right": CGPoint(x: 1, y: 0),
                           "up": CGPoint(x: 0, y: -1), "down": CGPoint(x: 0, y: 1)]
            guard let vector = vectors[direction], dragDistance >= 0 else { return nil }
            let distance = CGFloat(dragDistance)
            return InputRules.direction(from: .zero, to: CGPoint(x: vector.x * distance, y: vector.y * distance))
        }
    }

    /// A description of a simulated event. The planner receives text values,
    /// never the active application, a selection object or an executing service.
    struct Sample: Equatable {
        var application: String
        var configuredTrigger = true
        var fileLines = ""
        var directory = ""
        var basicInput: BasicInput?

        var files: [String] {
            fileLines.components(separatedBy: .newlines).map(AutomationPreview.trim).filter { !$0.isEmpty }
        }
    }

    struct Catalog {
        let actions: [OperationAction]
        var archive = ArchiveEnhancementPreferences()
        var templates: [String: String] = [:]
    }

    static func basic(_ rule: InputBinding, bindings: [InputBinding], excludedApps: [String],
                      paused: Bool, healthy: Bool, sample: Sample, catalog: Catalog) -> Report {
        let input = sample.basicInput ?? BasicInput(rule)
        var matchingTrigger = input.trigger == rule.trigger && (input.modifiers & InputRules.modifierMask) == (rule.modifiers & InputRules.modifierMask)
        switch input.trigger {
        case .hotkey: matchingTrigger = matchingTrigger && input.keyCode == rule.keyCode
        case .mouseButton: matchingTrigger = matchingTrigger && input.mouseButton == rule.mouseButton
        case .gesture: matchingTrigger = matchingTrigger && input.recognizedDirection == rule.direction
        }
        var report = ruleChecks(enabled: rule.enabled, scope: rule.appBundleID, excludedApps: excludedApps,
                                paused: paused, healthy: healthy, sample: sample, triggerMatches: matchingTrigger && sample.configuredTrigger)
        if let problem = InputRules.validationError(rule) {
            report.checks.append(.init(state: .blocked, title: L10n.text("规则配置"), detail: problem))
        }
        // The event listener filters invalid bindings before matching.
        let effective = (bindings.filter { $0.id != rule.id } + [rule]).filter { InputRules.validationError($0) == nil }
        let eligible = InputRules.effectiveBindings(in: effective, appBundleID: trim(sample.application))
        if InputRules.conflictingIDs(in: eligible).contains(rule.id) {
            report.checks.append(line(.blocked, "触发优先级", "同一应用中的相同触发存在冲突。"))
        } else if report.canPlanSteps {
            let matched = InputRules.match(in: effective, trigger: input.trigger, modifiers: input.modifiers,
                                           keyCode: input.keyCode, mouseButton: input.mouseButton,
                                           direction: input.recognizedDirection ?? "", appBundleID: trim(sample.application))
            report.checks.append(matched?.id == rule.id
                ? line(.matched, "触发优先级", "在该模拟应用中选择了这条规则。")
                : line(.mismatch, "触发优先级", "应用专用规则优先于同触发的全局规则。"))
        }
        let title = catalog.actions.first { $0.id == rule.actionID }?.title ?? rule.actionID
        report.steps = [report.canPlanSteps ? action(rule.actionID, sample: sample, catalog: catalog) : skipped(title)]
        return report
    }

    static func enhanced(_ rule: EnhancedInputRule, configuration: InputEnhancementConfiguration,
                         excludedApps: [String], paused: Bool, healthy: Bool, sample: Sample, catalog: Catalog) -> Report {
        var report = ruleChecks(enabled: rule.enabled, scope: rule.appBundleID, excludedApps: excludedApps + rule.excludedApps,
                                paused: paused, healthy: healthy, sample: sample, triggerMatches: sample.configuredTrigger)
        report.checks.append(configuration.enabled ? line(.matched, "高级输入", "高级输入已启用。")
                             : line(.blocked, "高级输入", "高级输入已关闭。"))
        if configuration.cloudPendingScriptRules.contains(rule.id) {
            report.checks.append(line(.blocked, "规则配置", "同步规则仍需在本机复核。"))
        }
        if let problem = EnhancedInputValidation.migrationBlockReason(rule) ?? EnhancedInputValidation.error(rule, inferDirectoryTypes: false) {
            report.checks.append(.init(state: .blocked, title: L10n.text("规则配置"), detail: problem))
        }
        if rule.trigger == .touch && !configuration.experimentalRawTouch {
            report.checks.append(line(.blocked, "规则配置", "实验原始多点触控已关闭。"))
        }
        let rules = configuration.rules.contains { $0.id == rule.id }
            ? configuration.rules.map { $0.id == rule.id ? rule : $0 }
            : configuration.rules + [rule]
        let conflicts = EnhancedInputValidation.conflictingIDs(rules)
        if conflicts.contains(rule.id) {
            report.checks.append(line(.blocked, "触发优先级", "同一应用中的相同触发存在冲突。"))
        } else if report.canPlanSteps {
            let app = trim(sample.application)
            let candidates = rules.filter {
                $0.enabled && !conflicts.contains($0.id) && !configuration.cloudPendingScriptRules.contains($0.id)
                && ($0.appBundleID.isEmpty || $0.appBundleID == app) && !$0.excludedApps.contains(app)
                && $0.modifiers & EnhancedInputValidation.modifiers == rule.modifiers & EnhancedInputValidation.modifiers
            }
            let sameTrigger = candidates.filter { $0.trigger == rule.trigger }
                .sorted { !$0.appBundleID.isEmpty && $1.appBundleID.isEmpty }
            switch rule.trigger {
            case .keyDown, .keyUp, .keyHold, .keyReplacement:
                if rule.keyCode == 63 {
                    report.checks.append(line(.unknown, "系统条件", "Fn 依赖系统修饰键事件，实际触发需在运行时核验。"))
                } else {
                    let replacementHasPriority = [.keyDown, .keyHold].contains(rule.trigger) && candidates.contains {
                        $0.trigger == .keyReplacement && $0.keyCode == rule.keyCode
                    }
                    let winner = sameTrigger.first { $0.keyCode == rule.keyCode }
                    addPriority(to: &report, wins: !replacementHasPriority && winner?.id == rule.id)
                }
            case .buttonDown, .buttonUp, .buttonHold:
                let held = Set(rule.heldButtons + [rule.button])
                addPriority(to: &report, wins: sameTrigger.first { $0.button == rule.button && Set($0.heldButtons).isSubset(of: held) }?.id == rule.id)
            case .scroll:
                let held = Set(rule.heldButtons)
                addPriority(to: &report, wins: sameTrigger.first { $0.direction == rule.direction && Set($0.heldButtons).isSubset(of: held) }?.id == rule.id)
                report.checks.append(line(.unknown, "系统条件", "边缘滚动优先级和节流依赖实际事件。"))
            case .drawing, .hotCorner, .screenEdge, .touch, .pressure:
                report.checks.append(line(.unknown, "系统条件", "手势轨迹、屏幕位置、压力或设备能力需在运行时核验。"))
            }
            if rule.minimumIntervalSeconds > 0 {
                report.checks.append(line(.unknown, "系统条件", "距上次触发的时间未核验，实际运行可能因节流跳过。"))
            }
        }
        let effect = rule.effect
        let preview = rule.trigger == .touch && rule.touchGesture == "middleDrag"
            ? line(.unknown, rule.trigger.title, "预计向目标发送中键按下、拖动和松开，系统授权需在运行时核验。")
            : enhancedEffect(effect, sample: sample, catalog: catalog)
        report.steps = [report.canPlanSteps ? preview : skipped(preview.title)]
        return report
    }

    static func workflow(_ workflow: OperationWorkflow, busy: Bool, healthy: Bool) -> Report {
        var checks = [line(.matched, "运行方式", "组合操作由用户主动运行。")]
        if busy { checks.append(line(.blocked, "系统条件", "已有任务正在运行。")) }
        if !healthy { checks.append(line(.blocked, "资料状态", "资料保护模式下不能启动。")) }
        if trim(workflow.name).isEmpty { checks.append(line(.blocked, "规则配置", "请填写组合操作名称。")) }
        let bounded = (1...50).contains(workflow.steps.count)
        if !bounded { checks.append(line(.blocked, "规则配置", "组合操作须包含 1–50 个步骤。")) }
        var stopped = checks.contains { $0.state == .blocked }
        let steps = workflow.steps.prefix(50).map { step -> Line in
            let plan = workflowStep(step)
            if stopped { return skipped(plan.title) }
            if plan.state == .blocked { stopped = true }
            return plan
        }
        return Report(checks: checks, steps: steps)
    }

    private static func ruleChecks(enabled: Bool, scope: String, excludedApps: [String], paused: Bool,
                                   healthy: Bool, sample: Sample, triggerMatches: Bool) -> Report {
        var checks = [enabled ? line(.matched, "规则状态", "规则已启用。") : line(.blocked, "规则状态", "规则已停用。")]
        if !healthy { checks.append(line(.blocked, "资料状态", "资料保护模式下不能启动。")) }
        if paused { checks.append(line(.blocked, "输入监听", "输入监听已暂停。")) }
        checks.append(triggerMatches ? line(.matched, "模拟触发", "模拟输入匹配配置的触发。")
                      : line(.mismatch, "模拟触发", "模拟输入与规则触发不同。"))
        let app = trim(sample.application)
        if app.isEmpty || !app.contains(".") || app.contains(where: \.isWhitespace) || app.utf8.count > 256 {
            checks.append(line(.blocked, "模拟应用", "请输入模拟应用的 Bundle ID。"))
        } else if excludedApps.contains(app) {
            checks.append(line(.blocked, "模拟应用", "该应用已被排除。"))
        } else {
            checks.append(scope.isEmpty || scope == app ? line(.matched, "模拟应用", "应用范围匹配。")
                          : line(.mismatch, "模拟应用", "应用不在这条规则的范围内。"))
        }
        checks.append(line(.unknown, "系统条件", "安全输入、实际目标窗口、设备和系统授权需在运行时核验。"))
        return Report(checks: checks, steps: [])
    }

    private static func addPriority(to report: inout Report, wins: Bool) {
        report.checks.append(wins ? line(.matched, "触发优先级", "在该模拟应用中选择了这条规则。")
                             : line(.mismatch, "触发优先级", "另一条规则在该模拟触发中优先。"))
    }

    private static func enhancedEffect(_ effect: InputEffect, sample: Sample, catalog: Catalog) -> Line {
        switch effect.kind {
        case .action: return action(effect.actionID, sample: sample, catalog: catalog)
        case .shortcut, .mouseClick, .scroll:
            return line(.unknown, effect.kind.title, "设备动作和系统授权需在运行时核验。")
        case .systemPreset:
            return line(.unknown, EnhancedSystemPreset(rawValue: effect.systemPreset)?.title ?? effect.kind.title,
                        "系统设置、设备能力及请求结果需在运行时核验。")
        case .appleScript:
            return line(.unknown, effect.kind.title, "脚本的权限、输出和副作用无法预先确定。")
        case .menuItem:
            guard effect.menuEvidence != nil else { return line(.blocked, effect.kind.title, "菜单动作缺少身份校验证据，请重新选择菜单。") }
            if effect.menuBundleID != trim(sample.application) {
                return line(.blocked, effect.kind.title, "菜单目标与模拟应用不一致。")
            }
            return line(.unknown, effect.kind.title, "菜单和应用身份需在运行时核验。", paths: [effect.menuPath.joined(separator: " › ")])
        case .openTargets:
            return line(.unknown, effect.kind.title, "目标是否存在、系统能否打开及后续结果需在运行时核验。", paths: effect.openTargets)
        }
    }

    private static func workflowStep(_ step: WorkflowStep) -> Line {
        switch step.actionID {
        case "open.path":
            let title = "打开文件、文件夹或应用"
            guard isAbsolutePath(step.argument) else { return line(.blocked, title, "需要有效的绝对路径。") }
            return line(.unknown, title, "目标是否存在、系统能否打开及后续结果需在运行时核验。", paths: [step.argument])
        case "open.url":
            let title = "打开网址"
            guard let url = URL(string: step.argument), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { return line(.blocked, title, "需要完整的 HTTP 或 HTTPS 网址。") }
            return line(.unknown, title, "目标是否存在、系统能否打开及后续结果需在运行时核验。", paths: [step.argument])
        case "shortcut.run":
            let title = "运行系统快捷指令"
            guard !trim(step.argument).isEmpty else { return line(.blocked, title, "请填写系统快捷指令名称。") }
            return line(.unknown, title, "快捷指令是否存在、授权、输出及副作用需在运行时核验。", paths: [step.argument])
        case "text.copy": return line(.planned, "复制文字", "预计写入剪贴板。")
        case "delay":
            guard let seconds = Double(step.argument), seconds.isFinite, (0...30).contains(seconds) else {
                return line(.blocked, "等待", "等待时间应为 0–30 秒。")
            }
            return .init(state: .planned, title: L10n.text("等待"), detail: L10n.format("预计等待 %@ 秒。", step.argument))
        case "system.preventSleep.toggle": return line(.unknown, "切换保持唤醒", "预计切换保持唤醒；当前状态未检查。")
        default:
            if step.actionID.hasPrefix("window."), let window = WindowAction(rawValue: String(step.actionID.dropFirst(7))) {
                return windowStep(window.title, closes: window == .close)
            }
            return line(.blocked, step.actionID, "组合操作包含不支持的步骤，请重新选择动作。")
        }
    }

    private static func action(_ id: String, sample: Sample, catalog: Catalog) -> Line {
        guard let descriptor = catalog.actions.first(where: { $0.id == id }) else {
            return line(.blocked, id, "请选择一个有效动作。")
        }
        let title = descriptor.title
        guard sample.fileLines.utf8.count <= 64 * 1024 else { return line(.blocked, title, "模拟文件列表超过大小限制。") }
        let files = sample.files, directory = trim(sample.directory)
        guard files.count <= 1000, files.allSatisfy(isAbsolutePath), directory.isEmpty || isAbsolutePath(directory) else {
            return line(.blocked, title, "请输入有效的模拟绝对路径，每行一个，最多 1000 项。")
        }
        if descriptor.files && files.isEmpty { return line(.blocked, title, "此动作需要模拟文件。正式执行仍须选择实际项目。") }
        if id.hasPrefix("window.") { return windowStep(title, closes: id == "window.close") }
        if id.hasPrefix("archive."), let plan = archiveAction(id, title: title, files: files, preferences: catalog.archive) { return plan }
        if let kind = QuickNewItemKind(rawValue: String(id.dropFirst(4))), id.hasPrefix("new.") {
            return createdFile(title: title, name: kind.filename, directory: directory)
        }
        if let filename = catalog.templates[id] { return createdFile(title: title, name: filename, directory: directory) }
        if ["images.png", "images.jpeg", "images.heic", "images.tiff"].contains(id) {
            let suffix = "." + String(id.dropFirst(7))
            let outputs = files.map { joined(parent($0), stem($0) + suffix) }
            return line(.unknown, title, "预计生成转换后的图片。文件类型、重名和权限需在运行时核验。", paths: outputs)
        }
        if ["files.copy", "files.move"].contains(id) {
            guard !directory.isEmpty else { return line(.blocked, title, "请填写模拟目标目录。正式执行仍须选择目录。") }
            let outputs = files.map { joined(directory, ($0 as NSString).lastPathComponent) }
            if zip(files, outputs).contains(where: { $0.0 == $0.1 }) {
                return line(.blocked, title, "模拟源与目标相同。", paths: outputs)
            }
            return line(.unknown, title, "预计写入这些目标路径。文件类型、重名和权限需在运行时核验。", paths: outputs)
        }
        if ["file.delete", "file.dissolve", "files.rename", "file.permissions", "archive.custom", "archive.extract.custom"].contains(id) {
            return line(.unknown, title, "需要在正式操作窗口选择参数或明确确认。", paths: files)
        }
        return line(.unknown, title, "预计动作已列出；可用性、权限和实际结果需在运行时核验。", paths: descriptor.files ? files : [])
    }

    private static func archiveAction(_ id: String, title: String, files: [String], preferences: ArchiveEnhancementPreferences) -> Line? {
        guard !files.isEmpty else { return nil }
        let creates = ["archive.create", "archive.7z", "archive.quick.zip", "archive.quick.7z", "archive.separate.zip", "archive.separate.7z", "archive.create.trash"]
        if creates.contains(id) {
            let groupIndividually = preferences.creation.separateItems || id.hasPrefix("archive.separate.")
            let groups = groupIndividually ? files.map { [$0] } : [files]
            let appendDate = preferences.creation.appendDate
            let format = id.contains("7z") ? "7z" : "zip"
            let outputs = groups.compactMap { group -> String? in
                guard let first = group.first else { return nil }
                let name = group.count == 1 ? stem(first) : "归档"
                return appendDate ? parent(first) : joined(parent(first), (name.isEmpty ? "归档" : name) + "." + format)
            }
            let trash = preferences.creation.trashOriginals || id == "archive.create.trash"
            if trash && !preferences.creation.ignoredPatterns.isEmpty {
                return line(.blocked, title, "压缩有忽略规则时不能移除原件。", paths: files)
            }
            let detail = appendDate ? "计划在所列目录生成带运行时间的压缩包；文件名需在运行时核验。"
                : "预计生成压缩包。文件类型、重名和权限需在运行时核验。"
            return archiveLine(title: title, detail: detail, destinations: outputs, trash: trash, originals: files)
        }
        if ["archive.extract", "archive.extract.here", "archive.extract.trash"].contains(id) {
            let outputs = files.map { path in
                let name = QuickFileActions.extractionFolderName(for: URL(fileURLWithPath: path, isDirectory: false))
                return id == "archive.extract.here" ? parent(path) : joined(parent(path), name)
            }
            let detail = "预计解压到所列目录。归档内容、密码、分卷、重名和权限需在运行时核验。"
            return archiveLine(title: title, detail: detail, destinations: outputs, trash: preferences.extraction.trashOriginals || id == "archive.extract.trash", originals: files)
        }
        return nil
    }

    private static func archiveLine(title: String, detail: String, destinations: [String], trash: Bool, originals: [String]) -> Line {
        let explanation = L10n.text(detail) + (trash ? " " + L10n.text("成功并校验后会请求将所列原件移到废纸篓。") : "")
        return .init(state: .unknown, title: title, detail: explanation, paths: destinations + (trash ? originals : []))
    }

    private static func createdFile(title: String, name: String, directory: String) -> Line {
        if directory.isEmpty { return line(.unknown, title, "预计创建项目；未指定模拟目标目录，实际位置需在运行时核验。", paths: [name]) }
        return line(.unknown, title, "预计创建项目。文件类型、重名和权限需在运行时核验。", paths: [joined(directory, name)])
    }

    private static func windowStep(_ title: String, closes: Bool) -> Line {
        line(.unknown, title, closes ? "预计请求关闭目标窗口，目标和可能的保存提示需在运行时核验。"
             : "预计调整目标窗口；实际窗口、显示器与辅助功能授权需在运行时核验。")
    }

    private static func skipped(_ title: String) -> Line {
        line(.skipped, title, "前置条件未命中或先前步骤已阻断。")
    }

    private static func line(_ state: State, _ title: String, _ detail: String, paths: [String] = []) -> Line {
        .init(state: state, title: L10n.text(title), detail: L10n.text(detail), paths: paths)
    }

    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 8192 && !value.contains("\0") && !value.contains(where: \.isNewline)
    }
    private static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    private static func stem(_ path: String) -> String {
        (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
    }
    private static func joined(_ directory: String, _ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }
}
