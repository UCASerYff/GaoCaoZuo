import AppKit
import SwiftUI

// MARK: - ExtensionConfigurationViews

public struct AutoInputSettingsView: View {
    @ObservedObject var coordinator = InputSourceCoordinator.shared
    @State private var showingAddRule = false
    @State private var selectedAppURL: URL?
    @State private var selectedSourceID = "com.apple.keylayout.ABC"
    @State private var importErrorMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L10n.text("启用输入法自动切换 (AutoInput)"), isOn: $coordinator.isEnabled)
                .font(.headline)

            Text(L10n.text("根据当前切换到的前台应用程序，自动将系统键盘切换至设定的目标输入法。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if let current = coordinator.currentSource {
                HStack {
                    Text(L10n.text("当前系统输入法："))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(current.name) (\(current.shortLabel))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Button(L10n.text("刷新")) {
                        coordinator.refreshCurrentSource()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let status = coordinator.lastSwitchStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Divider()

            HStack {
                Text(L10n.text("应用切换规则列表"))
                    .font(.headline)
                Spacer()
                Button(L10n.text("添加规则…")) {
                    chooseAppForNewRule()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if coordinator.rules.isEmpty {
                Text(L10n.text("暂未添加任何应用切换规则。点击右上角“添加规则”为常用应用配置指定输入法。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(coordinator.rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.appName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(rule.appBundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("➔ \(rule.targetSourceName)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Button(action: {
                                coordinator.removeRule(id: rule.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 120, maxHeight: 200)
            }

            HStack(spacing: 12) {
                Button(L10n.text("导出规则配置…")) {
                    exportRules()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.text("导入规则配置…")) {
                    importRules()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    private func chooseAppForNewRule() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.message = "选择需要指定输入法的应用程序"
        if p.runModal() == .OK, let url = p.url, let bundle = Bundle(url: url) {
            let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
            let appName = bundle.infoDictionary?["CFBundleDisplayName"] as? String ??
                          bundle.infoDictionary?["CFBundleName"] as? String ??
                          url.deletingPathExtension().lastPathComponent

            let sources = InputSourceCatalog.shared.availableKeyboardInputSources()
            let target = sources.first(where: { $0.id != coordinator.currentSource?.id }) ?? sources.first
            let targetID = target?.id ?? "com.apple.keylayout.ABC"
            let targetName = target?.name ?? "ABC"

            coordinator.addRule(
                InputSourceRule(
                    appBundleID: bundleID,
                    appName: appName,
                    targetSourceID: targetID,
                    targetSourceName: targetName
                )
            )
        }
    }

    private func exportRules() {
        guard let data = try? coordinator.exportRulesData() else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "搞操作-输入法规则.json"
        if p.runModal() == .OK, let url = p.url {
            try? data.write(to: url)
        }
    }

    private func importRules() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) {
            try? coordinator.importRulesData(data)
        }
    }
}

// MARK: - SnippetsSettingsView

public struct SnippetsSettingsView: View {
    @State private var snippets: [AdvancedSnippet] = []
    @State private var groups: [SnippetGroup] = []
    @State private var newName = ""
    @State private var newText = ""
    @State private var newShortcut = ""
    @State private var selectedMode: SnippetExecutionMode = .copyOnly
    @State private var statusMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("常用短语库与客服模版"))
                    .font(.headline)
                Spacer()
                Text(L10n.format("共 %ld 条短语", snippets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.text("支持文本变量占位符：{date}、{time}、{datetime}、{clipboard}、{uuid}。支持批量 CSV/Excel 导入导出。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Quick Add Box
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(L10n.text("短语名称 (如: 售后地址)"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text("快捷触发码 (可选)"), text: $newShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Picker(L10n.text("动作:"), selection: $selectedMode) {
                        ForEach(SnippetExecutionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(width: 180)
                }

                HStack {
                    TextField(L10n.text("短语内容 (输入 {date} 自动插入日期，{clipboard} 插入剪贴板)"), text: $newText)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.text("添加短语")) {
                        addSnippet()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newText.isEmpty)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            // Snippet List
            if snippets.isEmpty {
                Text(L10n.text("短语库为空。可通过上方表单添加，或导入 CSV 文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(snippets) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(s.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    if let sc = s.shortcut, !sc.isEmpty {
                                        Text("/\(sc)")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    Text("(\(s.executionMode.title))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(s.text)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.text("复制")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.resolvedText(), forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button(action: {
                                snippets.removeAll { $0.id == s.id }
                            }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 220)
            }

            // CSV Import / Export
            HStack(spacing: 12) {
                Button(L10n.text("导出 CSV 表格…")) {
                    exportCSV()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.text("导入 CSV 表格…")) {
                    importCSV()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            loadInitialSnippets()
        }
    }

    private func loadInitialSnippets() {
        if snippets.isEmpty {
            snippets = [
                AdvancedSnippet(name: "当前日期", text: "今日日期是：{date}", format: .plain, shortcut: "rq"),
                AdvancedSnippet(name: "当前时间", text: "记录时间：{datetime}", format: .plain, shortcut: "sj"),
                AdvancedSnippet(name: "礼貌致谢", text: "感谢您的支持与厚爱，祝您生活愉快！", format: .plain, shortcut: "zx")
            ]
        }
    }

    private func addSnippet() {
        let s = AdvancedSnippet(
            name: newName.trimmingCharacters(in: .whitespaces),
            text: newText,
            format: .plain,
            shortcut: newShortcut.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newShortcut,
            executionMode: selectedMode,
            order: snippets.count
        )
        snippets.append(s)
        newName = ""
        newText = ""
        newShortcut = ""
    }

    private func exportCSV() {
        let content = SnippetCSVCodec.exportCSV(snippets: snippets, groups: groups)
        let p = NSSavePanel()
        p.nameFieldStringValue = "搞操作-短语库.csv"
        if p.runModal() == .OK, let url = p.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已成功导出 CSV"
        }
    }

    private func importCSV() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let url = p.url, let content = try? String(contentsOf: url, encoding: .utf8) {
            do {
                let result = try SnippetCSVCodec.importCSV(content, existingSnippets: snippets, existingGroups: groups, policy: .keepBoth)
                snippets = result.snippets
                groups = result.groups
                statusMessage = "已成功导入 \(result.snippets.count) 项短语"
            } catch {
                statusMessage = "导入失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - CleanerSettingsView

public struct CleanerSettingsView: View {
    @ObservedObject var controller = CleanerController.shared
    @State private var cleanDuration = 180

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("键盘与屏幕清洁模式 (Cleaner)"))
                    .font(.headline)
                Spacer()
            }

            Text(L10n.text("开启后将全屏覆盖深色遮罩，并暂时拦截普通键盘输入与鼠标点击，便于擦拭屏幕与清理键盘污渍，防止产生误触打字或误发消息。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.text("清洁时间设置："))
                    Picker("", selection: $cleanDuration) {
                        Text("1 分钟 (60 秒)").tag(60)
                        Text("2 分钟 (120 秒)").tag(120)
                        Text("3 分钟 (180 秒)").tag(180)
                        Text("5 分钟 (300 秒)").tag(300)
                    }
                    .frame(width: 160)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("救援退出保障机制："))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("• " + L10n.text("长按 ESC 键 3 秒：出现退出环并立即解除拦截恢复桌面。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• " + L10n.text("紧急组合键：随时按 ⌘ + ⌥ + Q 强制退出清洁模式。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• " + L10n.text("看门狗自动超时：倒计时归零时自动安全关闭。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• " + L10n.text("系统保护兜底：系统睡眠、切换用户或应用退出时无条件自动释放。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: {
                    controller.startCleaning(durationSeconds: cleanDuration)
                }) {
                    Label(L10n.text("立即进入清洁模式"), systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                if let err = controller.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
    }
}
