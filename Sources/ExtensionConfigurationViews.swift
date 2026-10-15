import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings edit persisted configuration supplied by the owning OperationStore.
// Constructing these views does not enable listeners, select an input source, or run a test.

public struct AutoInputSettingsView: View {
    @Binding private var configuration: AutoInputConfiguration
    @ObservedObject private var coordinator = InputSourceCoordinator.shared
    @State private var sources: [InputSourceDescriptor] = []
    @State private var editingRule: InputSourceRule?
    @State private var importedConfiguration: AutoInputConfiguration?
    @State private var importChoices = false
    @State private var status: String?
    public init(configuration: Binding<AutoInputConfiguration>) { _configuration = configuration }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("自动输入法与手动切换")).font(.headline)
            Toggle(L10n.text("启用按应用与输入区域自动切换"), isOn: value(\.enabled))
            Text(L10n.text("仅使用你明确选择且系统已启用的输入源。缺失输入源与冲突规则会保留并暂停执行；共享输入排除列表同样适用。"))
                .font(.caption).foregroundStyle(.secondary)
            currentSourceSection
            Divider()
            manualSourceSection
            Divider()
            rulesSection
            if let status { Text(L10n.text(status)).font(.caption).textSelection(.enabled) }
        }
        .padding()
        .onAppear(perform: refresh)
        .sheet(item: $editingRule) { rule in
            AutoInputRuleEditor(rule: rule, sources: sources) { saved in
                var next = configuration
                if let index = next.rules.firstIndex(where: { $0.id == saved.id }) { next.rules[index] = saved }
                else { next.rules.append(saved) }
                if apply(next) { editingRule = nil }
            }
        }
        .sheet(isPresented: Binding(get: { importedConfiguration != nil }, set: { if !$0 { importedConfiguration = nil } })) {
            autoImportSheet
        }
    }
    private var currentSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("当前系统输入源"))
                Text(coordinator.currentSource.map { $0.name + " · " + $0.shortLabel } ?? L10n.text("未知"))
                    .fontWeight(.medium)
                Spacer()
                Button(L10n.text("刷新"), action: refresh)
            }
            if let message = coordinator.lastSwitchStatus { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(L10n.text("手动切换后暂缓自动规则"))
                Stepper(value: value(\.manualOverrideSeconds), in: 0...3600, step: 1) {
                    Text(L10n.format("%ld 秒", Int(configuration.manualOverrideSeconds)))
                }.frame(maxWidth: 210)
            }
            Text(L10n.text("暂缓期后仅在下一次应用或输入区域切换时评估，不自动恢复过时输入源。组合输入未提交、近期键入或安全输入时跳过；目标未公开组合状态时保守保留当前输入源。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var manualSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("手动切换动作的两个输入源")).font(.subheadline).fontWeight(.medium)
            sourcePicker(L10n.text("第一输入源"), selected: configuration.manualPrimarySourceID, key: \.manualPrimarySourceID)
            sourcePicker(L10n.text("第二输入源"), selected: configuration.manualSecondarySourceID, key: \.manualSecondarySourceID)
            if configuration.manualPrimarySourceID == nil || configuration.manualSecondarySourceID == nil {
                Text(L10n.text("请选择两个不同输入源；配齐前不会猜测要切换的语言。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("这两项仅配置手动动作；不会立即切换，也不会自动开启按应用切换。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sourcePicker(_ title: String, selected: String?, key: WritableKeyPath<AutoInputConfiguration, String?>) -> some View {
        Picker(title, selection: Binding(get: { selected ?? "" }, set: { id in
            var next = configuration; next[keyPath: key] = id.isEmpty ? nil : id; _ = apply(next)
        })) {
            Text(L10n.text("请选择输入源")).tag("")
            ForEach(sources) { Text($0.name + " · " + $0.id).tag($0.id) }
            if let selected, !sources.contains(where: { $0.id == selected }) {
                Text(L10n.text("已配置但不可用") + " · " + selected).tag(selected)
            }
        }
    }
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("应用与区域规则")).font(.subheadline).fontWeight(.medium)
                Spacer()
                Button(L10n.text("添加规则…")) {
                    editingRule = InputSourceRule(appBundleID: "", targetSourceID: "", enabled: true)
                }
            }
            Text(L10n.text("优先顺序：应用＋区域、应用、全局＋区域、全局；同一层级再按优先级从高到低。同级且目标不同的规则暂停执行。"))
                .font(.caption).foregroundStyle(.secondary)
            if configuration.rules.isEmpty {
                Text(L10n.text("暂无规则。添加规则时需明确选择应用与输入源。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(configuration.rules) { rule in
                        HStack(alignment: .top) {
                            Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                                var next = configuration
                                if let i = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[i].enabled = enabled; _ = apply(next) }
                            })).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.appName).fontWeight(.medium)
                                Text((rule.isGlobalDefault ? L10n.text("全局") : rule.appBundleID) + " → " + rule.targetSourceName)
                                    .font(.caption)
                                Text((rule.focusedRole ?? L10n.text("整个应用")) + " · " + L10n.format("优先级 %ld", rule.priority))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if !sources.contains(where: { $0.id == rule.targetSourceID }) {
                                    Text(L10n.text("目标输入源不可用，规则保留")).font(.caption).foregroundStyle(.orange)
                                }
                                if conflictIDs.contains(rule.id) { Text(L10n.text("与同级规则冲突，暂停执行")).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Button(L10n.text("编辑")) { editingRule = rule }
                            Button(L10n.text("删除")) { var next = configuration; next.rules.removeAll { $0.id == rule.id }; _ = apply(next) }
                        }.padding(.vertical, 3)
                    }
                }.frame(minHeight: 150, maxHeight: 280)
            }
            HStack {
                Button(L10n.text("导出配置…"), action: exportConfiguration)
                Button(L10n.text("导入配置并预览…"), action: importConfiguration)
            }
            Text(L10n.text("可选择 iCloud Drive 保存配置备份；这里只做显式导出与导入，不自动同步。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var conflictIDs: Set<UUID> {
        var ids = Set<UUID>()
        let rules = configuration.rules.filter(\.enabled)
        for rule in rules {
            let peers = rules.filter { ($0.isGlobalDefault ? "*" : $0.appBundleID) == (rule.isGlobalDefault ? "*" : rule.appBundleID)
                && $0.focusedRole == rule.focusedRole && $0.priority == rule.priority }
            if Set(peers.map(\.targetSourceID)).count > 1 { ids.formUnion(peers.map(\.id)) }
        }
        return ids
    }
    private func value<T>(_ key: WritableKeyPath<AutoInputConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] }, set: { new in var next = configuration; next[keyPath: key] = new; _ = apply(next) })
    }
    @discardableResult private func apply(_ next: AutoInputConfiguration) -> Bool {
        do { try next.validate(); configuration = next; status = nil; return true }
        catch { status = error.localizedDescription; return false }
    }
    private func refresh() { sources = InputSourceCatalog.shared.availableKeyboardInputSources(); coordinator.refreshCurrentSource() }
    private func exportConfiguration() {
        do {
            try configuration.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(configuration)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "搞操作-输入源配置.json"; panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url { try bytes.write(to: url, options: .atomic); status = "已导出输入源配置。" }
        } catch { status = error.localizedDescription }
    }
    private func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try SnippetLibraryStore.readSelectedFile(url, maximum: 1_048_576)
            struct Legacy: Decodable { var format: Int; var rules: [InputSourceRule] }
            let incoming: AutoInputConfiguration
            if let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["schemaVersion"] != nil {
                incoming = try JSONDecoder().decode(AutoInputConfiguration.self, from: bytes)
            } else {
                let legacy = try JSONDecoder().decode(Legacy.self, from: bytes)
                guard legacy.format == 1 else { throw InputAutomationError.invalid("不支持的输入法规则版本；原配置未覆盖。") }
                var value = AutoInputConfiguration(); value.rules = legacy.rules; try value.validate(); incoming = value
            }
            importedConfiguration = incoming; importChoices = false
        } catch { status = error.localizedDescription }
    }
    private var autoImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("预览输入源配置导入")).font(.headline)
            Text(L10n.format("导入文件包含 %ld 条规则。", importedConfiguration?.rules.count ?? 0))
            Text(L10n.text("相同 UUID 且内容不同会拒绝整个导入；不同规则全部保留，冲突按规则页显示。本机自动切换开关保持原选择。"))
                .font(.caption)
            Toggle(L10n.text("同时导入两个手动输入源及暂缓时间"), isOn: $importChoices)
            if let incoming = importedConfiguration {
                Text((incoming.manualPrimarySourceID ?? L10n.text("未配置")) + " ↔ " + (incoming.manualSecondarySourceID ?? L10n.text("未配置")))
                    .font(.caption).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("取消")) { importedConfiguration = nil }
                Spacer()
                Button(L10n.text("确认合并")) {
                    guard let incoming = importedConfiguration else { return }
                    do {
                        var next = configuration
                        for rule in incoming.rules {
                            if let existing = next.rules.first(where: { $0.id == rule.id }) {
                                guard existing == rule else { throw InputAutomationError.invalid("输入法规则 ID 冲突；未写入任何规则。") }
                            } else { next.rules.append(rule) }
                        }
                        if importChoices {
                            next.manualPrimarySourceID = incoming.manualPrimarySourceID
                            next.manualSecondarySourceID = incoming.manualSecondarySourceID
                            next.manualOverrideSeconds = incoming.manualOverrideSeconds
                        }
                        if apply(next) { importedConfiguration = nil; refresh(); status = "已合并配置；自动切换开关保持原选择。" }
                    } catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange) }
        }.padding(20).frame(width: 570)
    }
}

private struct AutoInputRuleEditor: View {
    @State private var rule: InputSourceRule
    @State private var global: Bool
    @State private var focusedRole: String
    @State private var status: String?
    let sources: [InputSourceDescriptor]
    let onSave: (InputSourceRule) -> Void
    @Environment(\.dismiss) private var dismiss
    init(rule: InputSourceRule, sources: [InputSourceDescriptor], onSave: @escaping (InputSourceRule) -> Void) {
        _rule = State(initialValue: rule); _global = State(initialValue: rule.appBundleID == "*")
        _focusedRole = State(initialValue: rule.focusedRole ?? ""); self.sources = sources; self.onSave = onSave
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("指定应用、区域与输入源")).font(.headline)
            Toggle(L10n.text("设为全局默认规则"), isOn: $global)
            if !global {
                HStack {
                    TextField(L10n.text("应用 Bundle ID"), text: $rule.appBundleID)
                    Button(L10n.text("选择应用…"), action: chooseApplication)
                }
                TextField(L10n.text("显示名称"), text: $rule.appName)
            }
            Picker(L10n.text("输入区域"), selection: $focusedRole) {
                Text(L10n.text("整个应用")).tag("")
                ForEach(AutoInputConfiguration.allowedFocusedRoles, id: \.self) { Text($0).tag($0) }
            }
            Picker(L10n.text("指定输入源"), selection: $rule.targetSourceID) {
                Text(L10n.text("请选择输入源")).tag("")
                ForEach(sources) { Text($0.name + " · " + $0.id).tag($0.id) }
                if !rule.targetSourceID.isEmpty, !sources.contains(where: { $0.id == rule.targetSourceID }) {
                    Text(L10n.text("已配置但不可用") + " · " + rule.targetSourceID).tag(rule.targetSourceID)
                }
            }
            Stepper(L10n.format("同层级优先级：%ld", rule.priority), value: $rule.priority, in: -1000...1000)
            Toggle(L10n.text("启用此规则"), isOn: $rule.enabled)
            Text(L10n.text("保存不会立即切换输入源。总开关开启后，在下次匹配的应用或区域切换时评估。"))
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("取消")) { dismiss() }
                Spacer()
                Button(L10n.text("保存规则"), action: save).buttonStyle(.borderedProminent)
                    .disabled(rule.targetSourceID.isEmpty || (!global && rule.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(20).frame(width: 600)
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            status = "所选应用未提供有效 Bundle ID，未猜测应用身份。"; return
        }
        rule.appBundleID = identifier
        rule.appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
    }
    private func save() {
        var next = rule
        next.appBundleID = global ? "*" : rule.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        next.appName = global ? L10n.text("全局默认") : (rule.appName.isEmpty ? next.appBundleID : rule.appName)
        next.focusedRole = focusedRole.isEmpty ? nil : focusedRole
        next.targetSourceName = sources.first(where: { $0.id == rule.targetSourceID })?.name ?? rule.targetSourceName
        var probe = AutoInputConfiguration(); probe.rules = [next]
        do { try probe.validate(); onSave(next) } catch { status = error.localizedDescription }
    }
}

public struct FlyKeySettingsView: View {
    @Binding private var configuration: FlyKeyConfiguration
    @ObservedObject private var controller = FlyKeyController.shared
    private let onChange: ((FlyKeyConfiguration) -> Void)?
    @State private var status: String?
    public init(configuration: Binding<FlyKeyConfiguration>, onChange: ((FlyKeyConfiguration) -> Void)? = nil) {
        _configuration = configuration; self.onChange = onChange
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("FlyKey 快捷键速查")).font(.headline)
            Toggle(L10n.text("启用独立修饰键双击触发"), isOn: value(\.enabled))
            Picker(L10n.text("双击修饰键"), selection: value(\.triggerModifier)) {
                ForEach(FlyKeyTriggerModifier.allCases) { Text($0.symbol).tag($0) }
            }
            Stepper(value: value(\.doubleTapInterval), in: 0.15...0.8, step: 0.05) {
                Text(L10n.format("双击间隔：%ld 毫秒", Int(configuration.doubleTapInterval * 1000)))
            }
            Text(L10n.text("仅识别同一侧修饰键的两次短按与释放。其他按键、鼠标、混合修饰键、长按或切换应用会取消探测；原应用的按键照常接收。安全输入期间不展示或执行。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("浮窗显示当前应用实际公开的菜单快捷键，以及你已启用的搞操作绑定。禁用菜单不可执行，菜单点按前会重新核对目标与路径。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("显示当前应用快捷键")) { controller.showHUD() }
            if let message = controller.lastStatus { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange) }
        }.padding()
    }
    private func value<T>(_ key: WritableKeyPath<FlyKeyConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] }, set: { new in
            var next = configuration; next[keyPath: key] = new
            do { try next.validate(); configuration = next; onChange?(next); status = nil }
            catch { status = error.localizedDescription }
        })
    }
}

public struct CleanerSettingsView: View {
    @ObservedObject private var controller = CleanerController.shared
    @Binding private var durationSeconds: Int
    public init(durationSeconds: Binding<Int>) { _durationSeconds = durationSeconds }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("键盘与屏幕清洁模式")).font(.headline)
            Text(L10n.text("由你显式开始，先验证救援按键，再遮暗屏幕并拦截可拦截的普通键鼠。清洁模式不是系统锁屏，系统保留快捷键保持可用。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("最长清洁时间"), selection: $durationSeconds) {
                Text(L10n.text("30 秒")).tag(30)
                Text(L10n.text("1 分钟")).tag(60)
                Text(L10n.text("2 分钟")).tag(120)
                Text(L10n.text("3 分钟")).tag(180)
            }.disabled(controller.state != .idle)
            Divider()
            Text(L10n.text("先点击验证，再用实体键盘按 ⌘⌥Q。验证期间不遮屏，也不拦截普通输入；验证只在短时间内有效。"))
                .font(.callout)
            HStack {
                Button(L10n.text("验证退出按键")) { controller.beginRescueVerification() }
                    .disabled(controller.state != .idle)
                Button(L10n.text("开始清洁")) { controller.startCleaning(durationSeconds: min(180, max(30, durationSeconds))) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.state != .verifyingRescue || !controller.rescueVerified)
                Button(L10n.text("取消验证／立即退出")) { controller.emergencyRelease() }
                    .disabled(controller.state == .idle)
            }
            if controller.state == .verifyingRescue {
                Label(L10n.text(controller.rescueVerified ? "退出按键已验证，可开始清洁" : "等待实体 ⌘⌥Q；请保持本页可见"),
                      systemImage: controller.rescueVerified ? "checkmark.shield" : "keyboard")
            }
            if controller.state == .active { Text(L10n.format("剩余时间：%ld 秒", controller.remainingSeconds)).font(.headline) }
            if let error = controller.errorMessage { Text(L10n.text(error)).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text("退出方式：⌘⌥Q、长按 Esc 3 秒、遮罩上的退出按钮、倒计时。通道失效、权限失效、睡眠、切换用户或退出应用会释放普通输入拦截。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onDisappear { if controller.state != .idle { controller.emergencyRelease() } }
    }
}

public struct SnippetsSettingsView: View {
    @ObservedObject private var library: SnippetLibraryStore
    @State private var query = ""
    @State private var groupFilter = "*"
    @State private var editingSnippet: AdvancedSnippet?
    @State private var editingGroup: SnippetGroup?
    @State private var deletingSnippet: AdvancedSnippet?
    @State private var status: String?
    @State private var importData: Data?
    @State private var importIsXLSX = false
    @State private var importPolicy = 0
    @State private var importPreview: SnippetImportPreview?
    @State private var showingImport = false
    @State private var backupBusy = false
    @State private var showingNativeRestore = false
    @State private var nativeSource: URL?
    @State private var nativePolicy = 0
    @State private var nativePreview: SnippetNativeBackupPreview?
    @State private var nativeGeneration: UInt64 = 0
    public init(library: SnippetLibraryStore) { self.library = library }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("持久短语库")).font(.headline)
                Spacer()
                Text(L10n.format("共 %ld 条短语", library.snippets.count)).font(.caption)
            }
            Text(L10n.text("短语、分组、标签与附件保存在本机资料中。快捷码通过明确的“按快捷码复制”动作使用，不监听普通键入，也不自动发送回车。"))
                .font(.caption).foregroundStyle(.secondary)
            if !library.healthy {
                Text(L10n.text(library.failure ?? "短语库处于保护模式，原资料未覆盖。"))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            searchAndGroups
            snippetList
            HStack {
                Button(L10n.text("新建短语…")) {
                    editingSnippet = AdvancedSnippet(name: "", text: "", order: library.snippets.count)
                }
                Button(L10n.text("导入 CSV／XLSX 并预览…"), action: chooseImport)
                Menu(L10n.text("导出文本表格")) {
                    Button(L10n.text("CSV…")) { export(xlsx: false) }
                    Button(L10n.text("Excel XLSX…")) { export(xlsx: true) }
                }
                Spacer()
                Button(L10n.text("撤销上次修改")) {
                    do { try library.undoLastChange(); status = "已恢复上一个短语库版本；当前版本仍保留供恢复。" }
                    catch { status = error.localizedDescription }
                }.disabled(!library.canUndo)
            }.disabled(!library.healthy)
            HStack {
                Button(L10n.text("保存原生备份…"), action: exportNativeBackup)
                Button(L10n.text("从原生备份恢复并预览…"), action: chooseNativeBackup)
                Button(L10n.text("在 Finder 显示附件导出副本")) {
                    let directory = library.namedAttachmentExportsDirectory
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        status = "尚无附件导出副本；复制含文件附件的短语后会按需生成。"; return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                if backupBusy { ProgressView().controlSize(.small) }
            }.disabled(!library.healthy || backupBusy)
            Text(L10n.text("附件导出副本最多 64 份／128 MiB，可能仍被剪贴板引用。应用不会自动删除；达到预算后由你明确清理。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("原生 .gaosnippets 备份未加密，包含分组、标签、富文本、附件、历史恢复版本及路径引用。文件引用不含原文件内容。可手动存到 iCloud Drive；不会自动同步或后台合并。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("CSV／XLSX 仅传输五列文本：名称、快捷码、分组、执行方式、内容。富文本、标签和附件保留在本地短语库及恢复版本；表格不是完整附件备份。导入拒绝宏、公式与外链。"))
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(L10n.text(status)).font(.caption).textSelection(.enabled) }
        }.padding()
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(library: library, snippet: snippet) { editingSnippet = nil; status = "已保存短语。" }
        }
        .sheet(item: $editingGroup) { group in
            SnippetGroupEditor(library: library, group: group) { editingGroup = nil; status = "已保存分组。" }
        }
        .sheet(isPresented: $showingImport, onDismiss: { importData = nil; importPreview = nil }) { importSheet }
        .sheet(isPresented: $showingNativeRestore, onDismiss: {
            nativeSource = nil; nativePreview = nil; nativeGeneration &+= 1; backupBusy = false
        }) { nativeRestoreSheet }
        .alert(L10n.text("删除这条短语？"), isPresented: Binding(get: { deletingSnippet != nil }, set: { if !$0 { deletingSnippet = nil } })) {
            Button(L10n.text("取消"), role: .cancel) { deletingSnippet = nil }
            Button(L10n.text("删除"), role: .destructive) {
                guard let item = deletingSnippet else { return }
                do { try library.remove(id: item.id); status = "已删除短语，可撤销上次修改。" }
                catch { status = error.localizedDescription }
                deletingSnippet = nil
            }
        } message: { Text(L10n.text("附件与恢复版本暂时保留，不会连带删除其他短语内容。")) }
    }
    private var searchAndGroups: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(L10n.text("搜索名称、正文、标签或快捷码"), text: $query).textFieldStyle(.roundedBorder)
                Picker(L10n.text("分组"), selection: $groupFilter) {
                    Text(L10n.text("全部分组")).tag("*")
                    Text(L10n.text("未分组")).tag("")
                    ForEach(library.groups) { Text($0.name).tag($0.id.uuidString) }
                }.frame(maxWidth: 240)
            }
            HStack {
                Button(L10n.text("新建分组…")) { editingGroup = SnippetGroup(name: "", order: library.groups.count) }
                if let group = library.groups.first(where: { $0.id.uuidString == groupFilter }) {
                    Button(L10n.text("编辑当前分组…")) { editingGroup = group }
                }
            }.disabled(!library.healthy)
        }
    }
    private var filteredSnippets: [AdvancedSnippet] {
        library.snippets.filter { snippet in
            let groupMatches = groupFilter == "*" || (snippet.groupID?.uuidString ?? "") == groupFilter
            let combined = ([snippet.name, snippet.text, snippet.shortcut ?? ""] + snippet.tags).joined(separator: "\n")
            return groupMatches && (query.isEmpty || combined.localizedCaseInsensitiveContains(query))
        }
    }
    private var snippetList: some View {
        Group {
            if filteredSnippets.isEmpty {
                Text(L10n.text("没有匹配的短语；不会自动添加样例。"))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            } else {
                List {
                    ForEach(filteredSnippets) { snippet in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(snippet.name).fontWeight(.medium)
                                    if let shortcut = snippet.shortcut, !shortcut.isEmpty {
                                        Text("/" + shortcut).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(snippet.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                Text(([snippet.format.title] + snippet.tags + (snippet.attachments ?? []).map(\.originalName)).joined(separator: " · "))
                                    .font(.caption2).lineLimit(2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.text("复制")) {
                                do { try library.copyToPasteboard(snippet); status = "已复制；未粘贴或发送回车。" }
                                catch { status = error.localizedDescription }
                            }
                            Button(L10n.text("编辑")) { editingSnippet = snippet }
                            Button(L10n.text("删除")) { deletingSnippet = snippet }
                        }.padding(.vertical, 3).disabled(!library.healthy)
                    }
                }.frame(minHeight: 180, maxHeight: 320)
            }
        }
    }
    private var selectedPolicy: SnippetConflictPolicy {
        switch importPolicy { case 1: return .skip; case 2: return .overwrite; default: return .keepBoth }
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importData = try SnippetLibraryStore.readSelectedFile(url, maximum: SnippetCSVCodec.maxFileBytes)
            importIsXLSX = url.pathExtension.lowercased() == "xlsx"; importPolicy = 0
            try rebuildPreview(); showingImport = true
        } catch { importData = nil; importPreview = nil; status = error.localizedDescription }
    }
    private func rebuildPreview() throws {
        guard let importData else { return }
        if importIsXLSX { importPreview = try library.previewXLSX(importData, policy: selectedPolicy) }
        else {
            guard let content = String(data: importData, encoding: .utf8) else {
                throw InputAutomationError.invalid("CSV 不是 UTF-8 文本，请以 UTF-8 编码另存后导入。")
            }
            importPreview = try library.previewCSV(content, policy: selectedPolicy)
        }
    }
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("导入预览与冲突处理")).font(.headline)
            Picker(L10n.text("与已有短语同名时"), selection: $importPolicy) {
                Text(L10n.text("保留两份并改名")).tag(0)
                Text(L10n.text("跳过导入项")).tag(1)
                Text(L10n.text("用导入文本覆盖（可撤销）")).tag(2)
            }.onChange(of: importPolicy) { _, _ in
                do { try rebuildPreview(); status = nil } catch { importPreview = nil; status = error.localizedDescription }
            }
            if let preview = importPreview {
                Text(L10n.format("新增 %ld，修改 %ld，本次跳过 %ld。", preview.added, preview.updated, preview.skipped))
                ForEach(preview.warnings, id: \.self) { Text(L10n.text($0)).font(.caption).foregroundStyle(.secondary) }
                List(Array(preview.snippets.prefix(100))) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.text).font(.caption).lineLimit(2)
                    }
                }.frame(height: 240)
                if preview.snippets.count > 100 { Text(L10n.text("仅展示前 100 条；全部记录均经过格式和预算校验。")).font(.caption) }
            }
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("取消")) { showingImport = false }
                Button(L10n.text("按当前库重新预览")) {
                    do { try rebuildPreview(); status = nil } catch { importPreview = nil; status = error.localizedDescription }
                }
                Spacer()
                Button(L10n.text("确认导入")) {
                    guard let preview = importPreview else { return }
                    do { try library.applyImport(preview); showingImport = false; status = "已事务化导入短语；可撤销上次修改。" }
                    catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(importPreview == nil || !library.healthy)
            }
        }.padding(20).frame(width: 650)
    }
    private func export(xlsx: Bool) {
        do {
            let bytes = xlsx ? try library.exportXLSX() : Data(library.exportCSV().utf8)
            let panel = NSSavePanel(); panel.nameFieldStringValue = xlsx ? "搞操作-短语文本表.xlsx" : "搞操作-短语文本表.csv"
            panel.allowedContentTypes = [xlsx ? (UTType(filenameExtension: "xlsx") ?? .data) : .commaSeparatedText]
            if panel.runModal() == .OK, let url = panel.url {
                try bytes.write(to: url, options: .atomic); status = "已导出文本表格；附件和富文本原文仍保留在本机短语库。"
            }
        } catch { status = error.localizedDescription }
    }
    private func exportNativeBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "搞操作-短语备份.gaosnippets"
        panel.message = L10n.text("选择新的 .gaosnippets 备份名称；不会覆盖已有备份。可自行选择 iCloud Drive。")
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupBusy = true; status = nil
        Task { @MainActor in
            defer { backupBusy = false }
            do { try await library.exportNativeBackup(to: url); status = "已保存原生短语备份；本机资料未替换，也未开启自动同步。" }
            catch { status = error.localizedDescription }
        }
    }
    private func chooseNativeBackup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L10n.text("选择 .gaosnippets 原生短语备份目录包；先核验并预览，不立即恢复。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        nativeSource = url; nativePolicy = 0; nativePreview = nil; status = nil; showingNativeRestore = true
        loadNativePreview()
    }
    private var nativeSelectedPolicy: SnippetConflictPolicy {
        switch nativePolicy { case 1: return .skip; case 2: return .overwrite; default: return .keepBoth }
    }
    private func loadNativePreview() {
        guard let source = nativeSource else { return }
        nativeGeneration &+= 1; let generation = nativeGeneration, policy = nativeSelectedPolicy
        nativePreview = nil; backupBusy = true
        Task { @MainActor in
            do {
                let preview = try await library.previewNativeBackup(at: source, policy: policy)
                guard generation == nativeGeneration, showingNativeRestore else { return }
                nativePreview = preview; status = nil
            } catch { if generation == nativeGeneration, showingNativeRestore { status = error.localizedDescription } }
            if generation == nativeGeneration { backupBusy = false }
        }
    }
    private var nativeRestoreSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("原生短语备份恢复预览")).font(.headline)
            Text(L10n.text("恢复前核验全部清单、正文、附件与恢复版本。默认保留两份；覆盖前保留当前库恢复版本。不会自动恢复缺失外部文件或启用输入监听。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("同名或相同 UUID 时"), selection: $nativePolicy) {
                Text(L10n.text("保留两份并改名")).tag(0)
                Text(L10n.text("跳过导入项")).tag(1)
                Text(L10n.text("覆盖并保留当前恢复版本")).tag(2)
            }.disabled(backupBusy).onChange(of: nativePolicy) { _, _ in loadNativePreview() }
            if backupBusy { ProgressView(L10n.text("正在核验原生备份…")) }
            if let preview = nativePreview {
                Text(L10n.format("新增 %ld，修改 %ld，跳过 %ld。", preview.added, preview.updated, preview.skipped))
                ForEach(preview.warnings, id: \.self) { Text(L10n.text($0)).font(.caption).foregroundStyle(.secondary) }
            }
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.text("取消")) { showingNativeRestore = false }
                Button(L10n.text("按当前库重新预览"), action: loadNativePreview).disabled(backupBusy)
                Spacer()
                Button(L10n.text("确认恢复原生备份")) {
                    guard let preview = nativePreview else { return }
                    do { try library.restoreNativeBackup(preview); showingNativeRestore = false; status = "已恢复原生备份；可撤销上次修改。" }
                    catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(backupBusy || nativePreview == nil || !library.healthy)
            }
        }.padding(20).frame(width: 640)
    }
}

private struct SnippetEditorView: View {
    @ObservedObject var library: SnippetLibraryStore
    @State private var draft: AdvancedSnippet
    @State private var tags: String
    @State private var status: String?
    private let baseRevision: UInt64
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    init(library: SnippetLibraryStore, snippet: AdvancedSnippet, onSave: @escaping () -> Void) {
        self.library = library; _draft = State(initialValue: snippet)
        _tags = State(initialValue: snippet.tags.joined(separator: ", ")); baseRevision = library.revision; self.onSave = onSave
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("编辑短语")).font(.headline)
            HStack {
                TextField(L10n.text("短语名称"), text: $draft.name)
                TextField(L10n.text("快捷码（可选，不含空白）"), text: Binding(get: { draft.shortcut ?? "" }, set: { draft.shortcut = $0.isEmpty ? nil : $0 }))
            }.textFieldStyle(.roundedBorder)
            HStack {
                Picker(L10n.text("分组"), selection: Binding(get: { draft.groupID?.uuidString ?? "" }, set: { draft.groupID = UUID(uuidString: $0) })) {
                    Text(L10n.text("未分组")).tag("")
                    ForEach(library.groups) { Text($0.name).tag($0.id.uuidString) }
                }
                Picker(L10n.text("正文格式"), selection: $draft.format) {
                    ForEach(SnippetFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            TextField(L10n.text("标签，用逗号分隔"), text: $tags).textFieldStyle(.roundedBorder)
            Text(L10n.text("正文／纯文本备用内容")).font(.caption)
            TextEditor(text: $draft.text).font(.body).frame(height: 135).border(Color.secondary.opacity(0.25))
            Text(L10n.text("可用变量：{date}、{time}、{datetime}、{year}、{month}、{day}、{uuid}、{clipboard}。剪贴板变量仅在你明确执行该短语时读取；安全输入时不读取。"))
                .font(.caption).foregroundStyle(.secondary)
            if draft.format == .richText {
                HStack {
                    Button(L10n.text("从 RTF 文件导入富文本正文…"), action: importRTF)
                    Text(L10n.text(draft.richTextRTF == nil && draft.rtfAttachment == nil ? "尚未导入 RTF 正文" : "已保存 RTF 正文；上方编辑仅影响纯文本备用内容"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            attachmentSection
            HStack {
                Picker(L10n.text("动作偏好"), selection: $draft.executionMode) {
                    ForEach(SnippetExecutionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper(L10n.format("排序：%ld", draft.order), value: $draft.order, in: 0...100_000)
            }
            Text(L10n.text("本页保存与“复制”不会粘贴或发送回车。需要粘贴或回车时，使用独立动作并重新确认捕获目标。"))
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.text("取消")) { dismiss() }
                Spacer()
                Button(L10n.text("保存短语"), action: save).buttonStyle(.borderedProminent)
                    .disabled(!library.healthy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
        }.frame(width: 760, height: min(700, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 160)))
    }
    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("图片与文件附件")).font(.subheadline)
                Spacer()
                Button(L10n.text("选择附件…"), action: importAttachments)
                Button(L10n.text("选择文件引用…"), action: importFileReferences)
            }
            ForEach(draft.attachments ?? []) { attachment in
                HStack {
                    Text(attachment.originalName).lineLimit(1)
                    Text(L10n.format("%ld 字节", attachment.byteCount)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("移除此关联")) { draft.attachments?.removeAll { $0.id == attachment.id } }
                }
            }
            ForEach(Array((draft.fileReferences ?? []).enumerated()), id: \.offset) { _, reference in
                HStack {
                    Text(URL(fileURLWithPath: reference.path).lastPathComponent).lineLimit(1)
                    Text(L10n.text("文件引用；未复制文件内容")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("移除此关联")) { draft.fileReferences?.removeAll { $0 == reference } }
                }
            }
            if draft.attachmentPaths?.isEmpty == false {
                Text(L10n.text("旧附件路径仍保留，尚未重新授权；请重新选择原附件。确认新附件可用后，可移除旧引用。"))
                    .font(.caption).foregroundStyle(.orange)
                Button(L10n.text("移除旧附件路径关联")) { draft.attachmentPaths = nil }
            }
            Text(L10n.text("单附件最多 16 MB，库内引用附件总计最多 64 MB。选择后保存短语才建立关联；移除关联不会立即删除恢复版本所需的内容。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func importAttachments() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var attachments = draft.attachments ?? []
            for url in panel.urls {
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier
                    ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
                let attachment = try library.importAttachment(from: url, type: type)
                if !attachments.contains(where: { $0.id == attachment.id }) { attachments.append(attachment) }
            }
            draft.attachments = attachments; status = "附件已添加到编辑内容，保存短语后生效。"
        } catch { status = error.localizedDescription }
    }
    private func importRTF() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.rtf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try SnippetLibraryStore.readSelectedFile(url, maximum: SnippetLibraryStore.maximumAttachmentBytes)
            let attributed = try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let normalized = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            guard let rtf = String(data: normalized, encoding: .utf8), rtf.hasPrefix("{\\rtf"),
                  normalized.count <= SnippetLibraryStore.maximumAttachmentBytes, attributed.string.utf8.count <= 1_048_576 else {
                throw InputAutomationError.invalid("RTF 正文无效或超过预算，原编辑内容保留。")
            }
            draft.rtfAttachment = try library.importAttachment(data: normalized, originalName: url.lastPathComponent, type: UTType.rtf.identifier)
            draft.richTextRTF = nil; draft.text = attributed.string; status = "已导入富文本及纯文本备用内容。"
        } catch { status = error.localizedDescription }
    }
    private func importFileReferences() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var references = draft.fileReferences ?? []
            for url in panel.urls {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let reference = try SnippetFileReference.capture(path: url.path)
                if !references.contains(where: { $0.path == reference.path }) { references.append(reference) }
            }
            draft.fileReferences = references
            status = "已添加文件引用；原文件没有复制到短语库，使用时会核验存在性与授权。"
        } catch { status = error.localizedDescription }
    }
    private func save() {
        guard library.revision == baseRevision else { status = "短语库在编辑期间已更改，请关闭后重新编辑；未覆盖新内容。"; return }
        do {
            var next = draft; next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            next.tags = tags.replacingOccurrences(of: "，", with: ",").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var seen = Set<String>(); next.tags = next.tags.filter { seen.insert($0).inserted }
            if next.format == .richText, next.richTextRTF == nil && next.rtfAttachment == nil { throw InputAutomationError.invalid("请先导入有效 RTF 正文，或明确改为纯文本。") }
            if next.format == .image, !(next.attachments ?? []).contains(where: { UTType($0.type)?.conforms(to: .image) == true }) {
                throw InputAutomationError.invalid("图片短语需要至少一个已授权图片附件。")
            }
            if next.format == .fileReference, next.attachments?.isEmpty != false && next.fileReferences?.isEmpty != false && next.attachmentPaths?.isEmpty != false {
                throw InputAutomationError.invalid("文件短语需要至少一个已授权文件附件。")
            }
            try library.upsert(next); onSave()
        } catch { status = error.localizedDescription }
    }
}

private struct SnippetGroupEditor: View {
    @ObservedObject var library: SnippetLibraryStore
    @State private var group: SnippetGroup
    @State private var status: String?
    private let baseRevision: UInt64
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    init(library: SnippetLibraryStore, group: SnippetGroup, onSave: @escaping () -> Void) {
        self.library = library; _group = State(initialValue: group); baseRevision = library.revision; self.onSave = onSave
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("编辑短语分组")).font(.headline)
            TextField(L10n.text("分组名称"), text: $group.name)
            Stepper(L10n.format("排序：%ld", group.order), value: $group.order, in: 0...100_000)
            if let status { Text(L10n.text(status)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("取消")) { dismiss() }
                Spacer()
                Button(L10n.text("保存分组")) {
                    guard library.revision == baseRevision else { status = "短语库在编辑期间已更改，请重新打开分组编辑。"; return }
                    var next = group; next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !library.groups.contains(where: { $0.id != next.id && $0.name.caseInsensitiveCompare(next.name) == .orderedSame }) else {
                        status = "已有同名分组，请使用不同名称以免表格导入时混淆。"; return
                    }
                    do { try library.upsertGroup(next); onSave() } catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.healthy)
            }
        }.padding(20).frame(width: 430)
    }
}
