import AppKit
import ApplicationServices
import Carbon
import SwiftUI

/// Exact menu-title paths are deliberately not fuzzy-matched or translated at execution time.
/// Changing an application's language/menu structure requires selecting the item again.
enum InputMenuPathResolver {
    static func resolve<Node>(path:[String],root:Node,children:(Node)throws->[Node],
                             title:(Node)->String,enabled:(Node)->Bool,canPress:(Node)->Bool)throws->Node {
        guard (2...10).contains(path.count),path.allSatisfy({!$0.isEmpty && $0.utf8.count<=1024}) else {
            throw SystemControlError.message("请选择完整菜单路径，包含顶层菜单和最终菜单项。")
        }
        var current=root
        for component in path {
            let siblings=try children(current)
            guard siblings.count<=512 else {throw SystemControlError.message("菜单项目超过安全读取预算。")}
            let matches=siblings.filter{title($0)==component}
            guard matches.count==1 else {throw SystemControlError.message(matches.isEmpty ? "菜单已变化或尚未公开，请重新选择菜单项。":"同级菜单存在重名，已停止以免点错。")}
            current=matches[0]
            guard enabled(current) else {throw SystemControlError.message("目标菜单项当前不可用。")}
        }
        guard canPress(current) else {throw SystemControlError.message("该菜单项未提供公开的辅助功能点按动作。")}
        return current
    }
}

@MainActor enum InputMenuAction {
    struct TreeNode: Identifiable {
        let id = UUID()
        let title: String
        let role: String
        let enabled: Bool
        let ambiguous: Bool
        let shortcutLabel: String
        let evidence: InputMenuEvidence?
        var children: [TreeNode]?
    }
    struct Snapshot {
        let application: InputMenuApplicationEvidence
        let roots: [TreeNode]
    }
    struct Choice: Identifiable {
        var id: String { path.joined(separator: "\u{1f}") }
        let path: [String]
        let enabled: Bool
        var title: String { path.joined(separator: " → ") }
    }
    private struct RuntimeNode {
        let element: AXUIElement
        let title: String
        let role: String
        let enabled: Bool
        let canPress: Bool
        let shortcut: InputMenuShortcutEvidence
    }
    private final class Budget {
        let started = ProcessInfo.processInfo.systemUptime
        var visited = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        func check() throws {
            guard ProcessInfo.processInfo.systemUptime - started < 2, visited <= 2048 else {
                throw SystemControlError.message("菜单读取超过时间或节点预算；请展开较小的菜单后重试。")
            }
        }
        func visit(_ element: AXUIElement) throws {
            try check(); visited += 1
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else {
                throw SystemControlError.message("应用公开了循环或重复的菜单元素，已停止读取。")
            }
            seen[hash, default: []].append(element)
        }
    }
    private static func value(_ element: AXUIElement, _ key: String, budget: Budget) throws -> CFTypeRef? {
        try budget.check(); AXUIElementSetMessagingTimeout(element, 0.12)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
        if status == .success { return result }
        if status == .attributeUnsupported || status == .noValue { return nil }
        throw SystemControlError.message("应用未能完成菜单属性读取，未使用不完整结果。")
    }
    private static func canPress(_ element: AXUIElement, budget: Budget) throws -> Bool {
        try budget.check(); AXUIElementSetMessagingTimeout(element, 0.12)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        if status == .success { return (names as? [String])?.contains(kAXPressAction) == true }
        if status == .notImplemented || status == .actionUnsupported { return false }
        throw SystemControlError.message("应用未能公开可确认的菜单动作。")
    }
    private static func readNode(_ element: AXUIElement, budget: Budget) throws -> RuntimeNode {
        let role = try value(element, kAXRoleAttribute, budget: budget) as? String ?? ""
        let title = try value(element, kAXTitleAttribute, budget: budget) as? String ?? ""
        guard !role.isEmpty, role.utf8.count <= 128, title.utf8.count <= 1024 else {
            throw SystemControlError.message("菜单角色或标题无效，未猜测菜单身份。")
        }
        let enabled = (try value(element, kAXEnabledAttribute, budget: budget) as? NSNumber)?.boolValue
            ?? (role == kAXMenuRole || role == kAXMenuBarRole)
        let rawCharacter = try value(element, kAXMenuItemCmdCharAttribute, budget: budget) as? String
        let character = rawCharacter?.isEmpty == true ? nil : rawCharacter
        let modifiers = (try value(element, kAXMenuItemCmdModifiersAttribute, budget: budget) as? NSNumber)?.intValue
        let key = (try value(element, kAXMenuItemCmdVirtualKeyAttribute, budget: budget) as? NSNumber)?.intValue
        let shortcut = InputMenuShortcutEvidence(character: character, modifiers: modifiers,
                                                virtualKey: key == -1 ? nil : key)
        try shortcut.validate()
        return RuntimeNode(element: element, title: title, role: role, enabled: enabled,
                           canPress: try canPress(element, budget: budget), shortcut: shortcut)
    }
    private static func children(_ element: AXUIElement, budget: Budget) throws -> [RuntimeNode] {
        let values = try value(element, kAXChildrenAttribute, budget: budget) as? [AXUIElement] ?? []
        guard values.count <= 512 else { throw SystemControlError.message("单层菜单超过 512 项安全预算。") }
        var result: [RuntimeNode] = []
        for child in values {
            try budget.check()
            let role = try value(child, kAXRoleAttribute, budget: budget) as? String
            if role == kAXMenuRole {
                try budget.visit(child)
                let nested = try value(child, kAXChildrenAttribute, budget: budget) as? [AXUIElement] ?? []
                guard nested.count <= 512, nested.count <= 512 - result.count else { throw SystemControlError.message("单层菜单超过安全预算。") }
                for item in nested { result.append(try readNode(item, budget: budget)) }
            } else { result.append(try readNode(child, budget: budget)) }
            guard result.count <= 512 else { throw SystemControlError.message("单层菜单超过安全预算。") }
        }
        return result
    }
    private static func menuBar(pid: pid_t, budget: Budget) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw SystemControlError.message("读取菜单需要辅助功能权限；请由本人在系统设置中开启。") }
        let application = AXUIElementCreateApplication(pid)
        guard let raw = try value(application, kAXMenuBarAttribute, budget: budget), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw SystemControlError.message("该应用没有公开可读取的菜单栏。")
        }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    private static func applicationIdentity(_ app: NSRunningApplication) throws -> InputMenuApplicationEvidence {
        guard !app.isTerminated, let bundleID = app.bundleIdentifier, let url = app.bundleURL else {
            throw SystemControlError.message("菜单应用已退出或缺少可确认的本机身份。")
        }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let bytes = try SnippetLibraryStore.readSelectedFile(canonical.appendingPathComponent("Contents/Info.plist"), maximum: 1_048_576)
        guard let info = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw SystemControlError.message("运行应用与本机安装身份不匹配，请重新选择。")
        }
        let result = InputMenuApplicationEvidence(bundleID: bundleID, bundlePath: canonical.path,
            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        try result.validate(); return result
    }
    static func capture(pid: pid_t) throws -> Snapshot {
        guard !IsSecureEventInputEnabled(), let app = NSRunningApplication(processIdentifier: pid),
              let identity = WindowProcessIdentity.capture(pid: pid, launchDate: app.launchDate) else {
            throw SystemControlError.message("安全输入状态下或应用身份无法确认时不读取菜单。")
        }
        let application = try applicationIdentity(app), budget = Budget(), root = try menuBar(pid: pid, budget: budget)
        func walk(_ element: AXUIElement, path: [InputMenuComponentEvidence], ancestorEnabled: Bool, ambiguous: Bool) throws -> [TreeNode] {
            guard path.count <= 10 else { throw SystemControlError.message("菜单层级超过 10 层预算。") }
            let nodes = try children(element, budget: budget)
            guard path.count < 10 || nodes.isEmpty else { throw SystemControlError.message("菜单层级超过 10 层预算。") }
            let counts = Dictionary(grouping: nodes.filter { !$0.title.isEmpty }, by: \.title).mapValues(\.count)
            return try nodes.compactMap { node in
                try budget.visit(node.element)
                guard !node.title.isEmpty else { return nil }
                let next = path + [.init(title: node.title, role: node.role)]
                let active = ancestorEnabled && node.enabled
                let duplicate = ambiguous || (counts[node.title] ?? 0) > 1
                let nested = try walk(node.element, path: next, ancestorEnabled: active, ambiguous: duplicate)
                let selectable = next.count >= 2 && node.canPress && nested.isEmpty && !duplicate
                let evidence = selectable ? InputMenuEvidence(application: application, components: next, shortcut: node.shortcut) : nil
                if let evidence { try evidence.validate(path: evidence.path, bundleID: application.bundleID) }
                let label: String
                if let modifiers = node.shortcut.modifiers {
                    let key = node.shortcut.character ?? node.shortcut.virtualKey.flatMap { (0...127).contains($0) ? InputBinding.keyLabel(UInt16($0)) : nil } ?? ""
                    label = FlyKeyShortcutFormatter.format(character: key, modifiers: modifiers)
                } else { label = "" }
                return TreeNode(title: node.title, role: node.role, enabled: active, ambiguous: duplicate,
                                shortcutLabel: label, evidence: evidence, children: nested.isEmpty ? nil : nested)
            }
        }
        let nodes = try walk(root, path: [], ancestorEnabled: true, ambiguous: false)
        guard let current = NSRunningApplication(processIdentifier: pid),
              identity.matches(WindowProcessIdentity.capture(pid: pid, launchDate: current.launchDate)),
              try applicationIdentity(current) == application, !IsSecureEventInputEnabled() else {
            throw SystemControlError.message("读取期间应用身份、版本或安全输入状态改变，请重新选择。")
        }
        return Snapshot(application: application, roots: nodes)
    }
    static func browse(pid: pid_t) throws -> [Choice] {
        func flatten(_ nodes: [TreeNode]) -> [Choice] {
            nodes.flatMap { node in
                let own = node.evidence.map { [Choice(path: $0.path, enabled: node.enabled)] } ?? []
                return own + flatten(node.children ?? [])
            }
        }
        return flatten(try capture(pid: pid).roots)
    }
    static func perform(evidence: InputMenuEvidence, pid: pid_t) throws {
        try evidence.validate(path: evidence.path, bundleID: evidence.application.bundleID)
        guard !IsSecureEventInputEnabled(), let app = NSRunningApplication(processIdentifier: pid),
              let identity = WindowProcessIdentity.capture(pid: pid, launchDate: app.launchDate),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              try applicationIdentity(app) == evidence.application else {
            throw SystemControlError.message("菜单应用、安装位置或版本已变化；原规则保留，请重新选择菜单。")
        }
        let budget = Budget(), rootElement = try menuBar(pid: pid, budget: budget)
        let root = try readNode(rootElement, budget: budget)
        let item = try InputMenuEvidenceResolver.resolve(evidence: evidence, root: root,
            children: { try budget.visit($0.element); return try children($0.element, budget: budget) }, title: { $0.title }, role: { $0.role },
            enabled: { $0.enabled }, canPress: { $0.canPress }, shortcut: { $0.shortcut })
        try budget.visit(item.element)
        guard let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
              identity.matches(WindowProcessIdentity.capture(pid: pid, launchDate: current.launchDate)),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              try applicationIdentity(current) == evidence.application, !IsSecureEventInputEnabled() else {
            throw SystemControlError.message("点按前应用目标或权限状态已变化，未执行。")
        }
        let confirmed = try readNode(item.element, budget: budget)
        guard confirmed.enabled, confirmed.canPress, confirmed.role == item.role, confirmed.title == item.title,
              confirmed.shortcut == evidence.shortcut, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            throw SystemControlError.message("点按前菜单可用状态、角色或快捷键改变，未执行。")
        }
        let status = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        guard status == .success else { throw SystemControlError.message("系统拒绝菜单点按。") }
    }
    /// Compatibility for explicit transient callers only. Persistent rules must use saved evidence.
    static func perform(path: [String], bundleID: String, pid: pid_t) throws {
        func find(_ nodes: [TreeNode]) -> [InputMenuEvidence] {
            nodes.flatMap { node in (node.evidence.map { $0.path == path ? [$0] : [] } ?? []) + find(node.children ?? []) }
        }
        let snapshot = try capture(pid: pid)
        guard snapshot.application.bundleID == bundleID else { throw SystemControlError.message("菜单目标应用不匹配。") }
        let matches = find(snapshot.roots)
        guard matches.count == 1 else { throw SystemControlError.message("菜单路径失效或存在歧义，请重新选择。") }
        try perform(evidence: matches[0], pid: pid)
    }
}

@MainActor struct InputMenuSelectionView: View {
    @Binding var bundleID: String
    @Binding var path: [String]
    @Binding var evidence: InputMenuEvidence?
    @State private var selectedPID: pid_t = 0
    @State private var selectedAppName = ""
    @State private var roots: [InputMenuAction.TreeNode] = []
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu(L10n.text("选择正在运行的目标应用")) {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            selectedPID = app.processIdentifier; selectedAppName = app.localizedName ?? app.bundleIdentifier ?? ""
                            roots = []; message = "已选择目标，点击读取菜单后再选择具体项目。"
                        }
                    }
                }
                Button(L10n.text("读取所选应用菜单"), action: readMenu).disabled(selectedPID <= 0)
            }
            if !selectedAppName.isEmpty { Text(selectedAppName).font(.caption).fontWeight(.medium) }
            if !roots.isEmpty {
                List {
                    OutlineGroup(roots, children: \.children) { node in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).foregroundStyle(node.enabled ? Color.primary : .secondary)
                                Text(node.role + (node.shortcutLabel.isEmpty ? "" : " · " + node.shortcutLabel))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if node.ambiguous { Text(L10n.text("同级重名，不能选择")).font(.caption).foregroundStyle(.orange) }
                            else if !node.enabled { Text(L10n.text("当前不可用")).font(.caption).foregroundStyle(.secondary) }
                            if let captured = node.evidence {
                                Button(L10n.text("选择")) {
                                    evidence = captured; path = captured.path; bundleID = captured.application.bundleID
                                    message = "已保存应用身份、逐级角色、标题和快捷键线索；没有点按菜单。"
                                }.disabled(!node.enabled)
                            }
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 320)
            }
            Text(path.isEmpty ? L10n.text("尚未选择菜单项") : path.joined(separator: " → ")).textSelection(.enabled)
            if !path.isEmpty, evidence == nil {
                Text(L10n.text("旧规则只保存标题路径，执行已停止；请从实际菜单树重新选择。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let evidence {
                Text(evidence.application.bundleID + " · " + (evidence.application.version ?? "") + " / " + (evidence.application.build ?? ""))
                    .font(.caption).textSelection(.enabled)
            }
            if let message { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text("仅在你点击读取后访问 AX 菜单树，不启动或激活目标应用。禁用、重名、未公开菜单不可选；目标升级、角色或快捷键变化后需重新选择。系统接受点按不等于业务完成。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func readMenu() {
        do {
            let snapshot = try InputMenuAction.capture(pid: selectedPID)
            roots = snapshot.roots
            message = roots.isEmpty ? "未读取到菜单；应用可能只在菜单展开后公开项目。" : "展开层级后选择可用项目；读取和选择不会执行菜单。"
        } catch { roots = []; message = error.localizedDescription }
    }
}
