import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor private func chooseApplicationBundleID() -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseFiles = true; panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = "选择要限定或排除的应用"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

@MainActor struct InputRulesView: View {
    @ObservedObject var store: OperationStore
    @State private var editing: InputBinding?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("快捷键与手势").font(.title2.bold())
                    Text("把常用动作放到顺手的位置。按应用设置的规则优先于全局规则。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = InputBinding() } label: { Label("添加规则", systemImage: "plus") }
                    .disabled(!store.dataHealthy)
            }
            InputStatusView(input: store.input)
            List {
                ForEach(store.settings.bindings) { binding in
                    HStack(spacing: 14) {
                        Toggle("启用", isOn: Binding(get: { binding.enabled }, set: { enabled in
                            store.update { settings in if let i = settings.bindings.firstIndex(where: { $0.id == binding.id }) { settings.bindings[i].enabled = enabled } }
                        })).labelsHidden().toggleStyle(.switch).disabled(!store.dataHealthy)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(OperationAction.all.first(where: { $0.id == binding.actionID })?.title ?? binding.actionID).fontWeight(.medium)
                            Text(binding.triggerDescription + " · " + (binding.appBundleID.isEmpty ? "所有应用" : binding.appBundleID))
                                .font(.caption).foregroundStyle(.secondary)
                            if InputRules.conflictingIDs(in: store.settings.bindings).contains(binding.id) {
                                Text("触发方式冲突，此规则暂不执行").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("编辑") { editing = binding }
                        Button(role: .destructive) { store.update { $0.bindings.removeAll { $0.id == binding.id } } } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 5).disabled(!store.dataHealthy)
                }
            }.listStyle(.inset).overlay { if store.settings.bindings.isEmpty { ContentUnavailableView("还没有输入规则", systemImage: "keyboard", description: Text("添加一个快捷键来打开操作面板。")) } }
            Text("绘图手势使用 Option＋右键向一个方向拖动。事件只作监听，原应用可能同时显示右键菜单。当前版本不提供自由多点触控板手势。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("已排除 \(store.settings.inputExcludedApps.count) 个应用；可在设置中管理。").font(.caption).foregroundStyle(.secondary)
                Spacer();Button("打开设置") { store.showSettings?() }
            }
        }.padding(24)
        .sheet(item: $editing) { binding in InputBindingEditor(store: store, original: binding) }
    }
}

@MainActor private struct InputStatusView: View {
    @ObservedObject var input: InputController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(input.permissionGranted ? (input.isPaused ? "输入监听已暂停" : "输入监听权限可用") : "尚未获得输入监听权限", systemImage: input.permissionGranted ? "checkmark.shield" : "hand.raised")
                Spacer()
                if !input.permissionGranted { Button("设置权限") { input.requestPermission() } }
                Button(input.isPaused ? "继续监听" : "暂停监听") { input.pause(!input.isPaused) }
            }
            if let error = input.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor private struct InputBindingEditor: View {
    @ObservedObject var store: OperationStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: InputBinding
    @State private var wasPaused = false
    init(store: OperationStore, original: InputBinding) { self.store = store; _draft = State(initialValue: original) }
    private var validation: String? {
        if let error = InputRules.validationError(draft) { return error }
        guard OperationAction.all.contains(where: { $0.id == draft.actionID }) else { return "请选择一个有效动作。" }
        if !draft.appBundleID.isEmpty && (!draft.appBundleID.contains(".") || draft.appBundleID.contains(where: \.isWhitespace)) { return "应用标识应为有效 Bundle ID，可使用选择应用按钮。" }
        let candidate = store.settings.bindings.filter { $0.id != draft.id } + [draft]
        return InputRules.conflictingIDs(in: candidate).contains(draft.id) ? "同一应用已有相同触发方式，请更换按键或停用冲突规则。" : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑输入规则").font(.title2.bold())
            Form {
                Picker("执行动作", selection: $draft.actionID) { ForEach(OperationAction.all) { Text($0.title).tag($0.id) } }
                Picker("触发方式", selection: $draft.trigger) { ForEach(InputTrigger.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: draft.trigger) { _, type in
                        if type == .gesture { draft.modifiers = UInt64(NSEvent.ModifierFlags.option.rawValue) }
                        else if type == .hotkey && draft.modifiers == 0 { draft.modifiers = UInt64(NSEvent.ModifierFlags([.command, .option]).rawValue) }
                    }
                if draft.trigger == .hotkey {
                    LabeledContent("快捷键") {
                        ShortcutRecorder(keyCode: $draft.keyCode, modifiers: $draft.modifiers)
                            .frame(width: 250, height: 30)
                    }
                    Text("点击录制框，再按下修饰键与普通按键。Esc 取消录制。").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("修饰键")
                        Spacer()
                        modifierToggle("⌃", .control)
                        modifierToggle("⌥", .option).disabled(draft.trigger == .gesture)
                        modifierToggle("⇧", .shift)
                        modifierToggle("⌘", .command)
                    }
                    if draft.trigger == .mouseButton {
                        Picker("鼠标按钮", selection: $draft.mouseButton) {
                            Text("中键（第 3 键）").tag(2)
                            ForEach(3...31, id: \.self) { Text("第 \($0 + 1) 键").tag($0) }
                        }
                    } else {
                        Picker("拖动方向", selection: $draft.direction) {
                            Text("向左").tag("left"); Text("向右").tag("right")
                            Text("向上").tag("up"); Text("向下").tag("down")
                        }
                        Text("按住 Option 和右键拖动至少 70 点，再松开右键。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("限定应用（空白为全部）", text: $draft.appBundleID)
                    Button("选择应用…") { if let id = chooseApplicationBundleID() { draft.appBundleID = id } }
                    if !draft.appBundleID.isEmpty { Button("清除") { draft.appBundleID = "" } }
                }
                Toggle("启用此规则", isOn: $draft.enabled)
            }.formStyle(.grouped)
            if let validation { Text(validation).font(.callout).foregroundStyle(.orange) }
            Text("编辑期间已暂停输入规则，关闭后恢复之前的状态。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    draft.appBundleID = draft.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update { settings in
                        if let i = settings.bindings.firstIndex(where: { $0.id == draft.id }) { settings.bindings[i] = draft }
                        else { settings.bindings.append(draft) }
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(validation != nil || !store.dataHealthy)
            }
        }.padding(24).frame(width: 580, height: 510)
        .onAppear { wasPaused = store.input.isPaused; store.input.pause(true) }
        .onDisappear { store.input.pause(wasPaused) }
    }
    private func modifierToggle(_ label: String, _ flag: NSEvent.ModifierFlags) -> some View {
        Toggle(label, isOn: Binding(get: { draft.modifiers & UInt64(flag.rawValue) != 0 }, set: { enabled in
            if enabled { draft.modifiers |= UInt64(flag.rawValue) } else { draft.modifiers &= ~UInt64(flag.rawValue) }
        })).toggleStyle(.button)
    }
}

@MainActor private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    func makeNSView(context: Context) -> ShortcutRecordButton { ShortcutRecordButton() }
    func updateNSView(_ view: ShortcutRecordButton, context: Context) {
        view.record = { code, flags in keyCode = code; modifiers = flags }
        if !view.recording { view.title = InputBinding(keyCode: keyCode, modifiers: modifiers).triggerDescription }
    }
    static func dismantleNSView(_ nsView: ShortcutRecordButton, coordinator: ()) { nsView.endRecording() }
}

@MainActor private final class ShortcutRecordButton: NSButton {
    var record: ((UInt16, UInt64) -> Void)?
    private var monitor: Any?
    private var previousTitle = "点击录制快捷键"
    private(set) var recording = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); bezelStyle = .rounded; title = "点击录制快捷键"
        target = self; action = #selector(beginRecording); setButtonType(.momentaryPushIn)
        toolTip = "点击后按下快捷键，Esc 取消。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        previousTitle=title;endRecording(); recording = true; title = "按下快捷键…（Esc 取消）"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.keyCode == 53 { self.endRecording(); self.title = self.previousTitle; return nil }
            let flags = UInt64(event.modifierFlags.rawValue) & InputRules.modifierMask
            guard flags != 0 else { self.title = "请同时按住 ⌘ / ⌥ / ⌃ / ⇧"; return nil }
            self.endRecording(); self.record?(event.keyCode, flags)
            self.title = InputBinding(keyCode: event.keyCode, modifiers: flags).triggerDescription
            return nil
        }
    }
    func endRecording() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false }
}

@MainActor struct WorkflowListView: View {
    @ObservedObject var store: OperationStore
    @State private var editing: OperationWorkflow?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("组合操作").font(.title2.bold())
                    Text("把打开应用、窗口排列与常用文字串成一步。") .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("添加模板") {
                    Button("左右阅读") { editing = .init(name: "左右阅读", steps: [.init(actionID: "open.path"), .init(actionID: "window.leftHalf"), .init(actionID: "open.path"), .init(actionID: "window.rightHalf")]) }
                    Button("写作与保持唤醒") { editing = .init(name: "写作与保持唤醒", steps: [.init(actionID: "system.preventSleep.toggle"), .init(actionID: "window.center")]) }
                }.disabled(!store.dataHealthy)
                Button { editing = .init(name: "新组合操作", steps: [.init(actionID: "text.copy", argument: "")]) } label: { Label("新建", systemImage: "plus") }.disabled(!store.dataHealthy)
            }
            if store.workflowRunning { HStack { ProgressView().controlSize(.small); Text(store.message); Spacer(); Button("停止") { store.cancelWorkflow() } } }
            List {
                ForEach(store.settings.workflows) { workflow in
                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(workflow.name).fontWeight(.medium); Text("\(workflow.steps.count) 个步骤").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("运行") { store.runWorkflow(workflow) }.disabled(store.workflowRunning || store.busy || !store.dataHealthy)
                        Button("编辑") { editing = workflow }.disabled(store.workflowRunning || !store.dataHealthy)
                        Button(role: .destructive) { store.update { $0.workflows.removeAll { $0.id == workflow.id } } } label: { Image(systemName: "trash") }.disabled(store.workflowRunning || !store.dataHealthy)
                    }.padding(.vertical, 6)
                }
            }.listStyle(.inset)
            Text("步骤按顺序执行，失败时停止。停止或失败会保留已经完成的步骤，不会整体回滚。保持唤醒步骤会切换当前状态；运行前请查看当前状态。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
        .sheet(item: $editing) { workflow in WorkflowEditor(store: store, original: workflow) }
    }
}

private struct WorkflowActionChoice: Identifiable {
    let id: String; let title: String
    static var all: [WorkflowActionChoice] {
        [.init(id: "open.path", title: "打开文件、文件夹或应用"), .init(id: "open.url", title: "打开网址"),
         .init(id: "text.copy", title: "复制文字"), .init(id: "shortcut.run", title: "运行系统快捷指令"),
         .init(id: "delay", title: "等待"), .init(id: "system.preventSleep.toggle", title: "切换保持唤醒")]
        + WindowAction.allCases.map { .init(id: "window." + $0.rawValue, title: $0.title) }
    }
}

@MainActor private struct WorkflowEditor: View {
    @ObservedObject var store: OperationStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OperationWorkflow
    init(store: OperationStore, original: OperationWorkflow) { self.store = store; _draft = State(initialValue: original) }
    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写组合操作名称。" }
        if draft.steps.isEmpty || draft.steps.count > 50 { return "组合操作须包含 1–50 个步骤。" }
        for (index,step) in draft.steps.enumerated() {
            if !WorkflowActionChoice.all.contains(where:{$0.id==step.actionID}) { return "第 \(index+1) 步动作无效。" }
            switch step.actionID {
            case "open.path": if !step.argument.hasPrefix("/") { return "请为第 \(index+1) 步选择实际文件、目录或应用。" }
            case "open.url": if let url=URL(string:step.argument), ["http","https"].contains(url.scheme ?? ""), url.host != nil {} else { return "第 \(index+1) 步需要完整 http/https 网址。" }
            case "shortcut.run": if step.argument.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return "请填写第 \(index+1) 步快捷指令名称。" }
            case "delay": if let value=Double(step.argument), value.isFinite, (0...30).contains(value) {} else { return "第 \(index+1) 步等待时间应为 0–30 秒。" }
            default: break
            }
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑组合操作").font(.title2.bold())
            TextField("名称", text: $draft.name).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($draft.steps) { $step in
                        let index = draft.steps.firstIndex(where:{$0.id==step.id}) ?? 0
                        WorkflowStepEditor(step: $step, number: index + 1,
                            canMoveUp: index > 0, canMoveDown: index + 1 < draft.steps.count,
                            moveUp: { if let i=draft.steps.firstIndex(where:{$0.id==step.id}), i>0 { draft.steps.swapAt(i,i-1) } },
                            moveDown: { if let i=draft.steps.firstIndex(where:{$0.id==step.id}), i+1<draft.steps.count { draft.steps.swapAt(i,i+1) } },
                            remove: { draft.steps.removeAll {$0.id==step.id} })
                    }
                }
            }
            HStack {
                Button { draft.steps.append(.init(actionID:"delay",argument:"1")) } label: { Label("添加步骤",systemImage:"plus") }.disabled(draft.steps.count >= 50)
                Spacer(); Text("\(draft.steps.count)/50 个步骤").foregroundStyle(.secondary)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { draft.name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines); store.saveWorkflow(draft); dismiss() }.keyboardShortcut(.defaultAction).disabled(validation != nil || !store.dataHealthy)
            }
        }.padding(24).frame(width:660,height:570)
    }
}

@MainActor private struct WorkflowStepEditor: View {
    @Binding var step: WorkflowStep
    let number: Int
    let canMoveUp: Bool; let canMoveDown: Bool
    let moveUp: () -> Void; let moveDown: () -> Void; let remove: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("\(number)").font(.headline).foregroundStyle(.secondary).frame(width:24)
                Picker("动作",selection:$step.actionID) { ForEach(WorkflowActionChoice.all) { Text($0.title).tag($0.id) } }.labelsHidden()
                Button(action:moveUp) { Image(systemName:"arrow.up") }.disabled(!canMoveUp).help("上移")
                Button(action:moveDown) { Image(systemName:"arrow.down") }.disabled(!canMoveDown).help("下移")
                Button(role:.destructive,action:remove) { Image(systemName:"trash") }
            }
            if step.actionID == "open.path" {
                HStack { TextField("文件、目录或应用的绝对路径",text:$step.argument).textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
                        if panel.runModal() == .OK, let url=panel.url { step.argument=url.path }
                    }
                }
            } else if step.actionID == "text.copy" {
                TextEditor(text:$step.argument).font(.body).frame(height:65).border(.quaternary)
            } else if step.actionID == "open.url" {
                TextField("https://example.com",text:$step.argument).textFieldStyle(.roundedBorder)
            } else if step.actionID == "shortcut.run" {
                TextField("已存在的系统快捷指令名称",text:$step.argument).textFieldStyle(.roundedBorder)
                Text("执行的是您在“快捷指令”应用中创建的指令。").font(.caption).foregroundStyle(.secondary)
            } else if step.actionID == "delay" {
                HStack { TextField("0–30",text:$step.argument).textFieldStyle(.roundedBorder).frame(width:90);Text("秒").foregroundStyle(.secondary) }
            }
        }.padding(12).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
    }
}

@MainActor struct OperationSettingsView: View {
    @ObservedObject var store: OperationStore
    @State private var selectedTab = 0
    @State private var loginBusy = false
    @State private var loginMessage: String?
    @State private var backupMessage: String?
    var body: some View {
        TabView(selection:$selectedTab) {
            general.tabItem { Label("外观与剪贴板",systemImage:"slider.horizontal.3") }.tag(0)
            SettingsWindowBehaviorView(store:store).tabItem { Label("窗口",systemImage:"rectangle.3.group") }.tag(4)
            SettingsPermissionsView(input:store.input,windows:store.windows).tabItem { Label("权限",systemImage:"hand.raised") }.tag(1)
            data.tabItem { Label("数据",systemImage:"externaldrive") }.tag(2)
            about.tabItem { Label("关于",systemImage:"info.circle") }.tag(3)
        }.padding(16).frame(width:660,height:580)
    }
    private func setting<T>(_ keyPath: WritableKeyPath<OperationSettings,T>) -> Binding<T> {
        Binding(get:{store.settings[keyPath:keyPath]},set:{ value in store.update {$0[keyPath:keyPath]=value} })
    }
    private var general: some View {
        Form {
            Section("外观") {
                Picker("界面模式",selection:setting(\.appearance)) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }
                    .onChange(of:store.settings.appearance) { _, value in NSApp.appearance = value == "light" ? NSAppearance(named:.aqua) : value == "dark" ? NSAppearance(named:.darkAqua) : nil }
                Toggle("登录时启动",isOn:Binding(get:{store.settings.loginAtStartup},set:{ setLogin($0) })).disabled(loginBusy)
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.orange) }
            }
            Section("剪贴板历史") {
                Toggle("记录剪贴板历史",isOn:setting(\.clipboardEnabled))
                Text("关闭后停止采集，已有历史继续保留。启用后只在本机保存，系统标记为敏感或临时的内容会跳过。").font(.caption).foregroundStyle(.secondary)
                Stepper("保留 \(store.settings.clipboardDays) 天",value:setting(\.clipboardDays),in:1...365)
                Stepper("最多 \(store.settings.clipboardLimit) 条普通记录",value:setting(\.clipboardLimit),in:20...1000,step:20)
                Text("固定记录不参与到期清理。以下应用在前台时不记录剪贴板。").font(.caption).foregroundStyle(.secondary)
                ForEach(store.settings.clipboardExcludedApps,id:\.self) { id in
                    HStack { Text(id).font(.caption).textSelection(.enabled);Spacer();Button(role:.destructive) { store.update {$0.clipboardExcludedApps.removeAll {$0==id}} } label:{Image(systemName:"minus.circle")} }
                }
                Button("添加排除应用…") { if let id=chooseApplicationBundleID(), !store.settings.clipboardExcludedApps.contains(id) { store.update {$0.clipboardExcludedApps.append(id)} } }
            }
            Section("输入规则排除") {
                Text("以下应用在前台时，暂停所有快捷键、鼠标按钮和绘图手势规则。可用于游戏、设计软件或已有专属手势的应用。").font(.caption).foregroundStyle(.secondary)
                ForEach(store.settings.inputExcludedApps,id:\.self) { id in
                    HStack { Text(id).font(.caption).textSelection(.enabled);Spacer();Button(role:.destructive) { store.update {$0.inputExcludedApps.removeAll {$0==id}} } label:{Image(systemName:"minus.circle")} }
                }
                Button("添加输入排除应用…") { if let id=chooseApplicationBundleID(), !store.settings.inputExcludedApps.contains(id) { store.update {$0.inputExcludedApps.append(id)} } }
            }
        }.formStyle(.grouped).disabled(!store.dataHealthy)
    }
    private func setLogin(_ enabled: Bool) {
        guard !loginBusy else { return }
        let previous=store.settings.loginAtStartup
        let previousStatus=SMAppService.mainApp.status
        loginBusy=true;loginMessage=nil
        Task { @MainActor in
            defer {loginBusy=false}
            var changedService=false
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                changedService=true
                var next=store.settings;next.loginAtStartup=enabled
                try store.data.save(next,name:"settings.json")
                store.settings=next
                if enabled && SMAppService.mainApp.status == .requiresApproval { loginMessage="请在系统设置的登录项中允许搞操作启动。" }
            } catch {
                let originalError=error.localizedDescription
                if changedService {
                    do {
                        if previousStatus == .enabled || previousStatus == .requiresApproval { try SMAppService.mainApp.register() }
                        else { try await SMAppService.mainApp.unregister() }
                    } catch { loginMessage="设置未保存，登录项状态也未能恢复，请在系统设置中核验：\(error.localizedDescription)" }
                }
                if store.settings.loginAtStartup != previous { store.update {$0.loginAtStartup=previous} }
                if loginMessage == nil { loginMessage="登录启动设置未改变：\(originalError)" }
            }
        }
    }
    private var data: some View {
        Form {
            Section("本机资料") {
                LabeledContent("资料位置") { Text(store.data.directory.path).font(.caption).textSelection(.enabled).lineLimit(3) }
                Button("在 Finder 中打开资料目录") { NSWorkspace.shared.open(store.data.directory) }
                Text("settings.json 保存模板、输入规则和组合操作；receipts.json 保存恢复记录；Clipboard 文件夹保存历史及 PNG/RTF 附件。密码保存在 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary)
            }
            Section("安全备份") {
                Text("正式更新安装前，安全安装器会完整备份资料、全部附件及偏好设置，并逐文件校验。备份保存在资料同级的 GaoCaoZuo-Backups 目录。")
                    .font(.callout)
                Button("查看已有备份") {
                    let url=store.data.directory.deletingLastPathComponent().appendingPathComponent("GaoCaoZuo-Backups")
                    if FileManager.default.fileExists(atPath:url.path) { NSWorkspace.shared.open(url) }
                    else { backupMessage="尚未生成安装备份。首次安全安装会记录资料状态。" }
                }
                if let backupMessage { Text(backupMessage).font(.caption).foregroundStyle(.secondary) }
                Text("本版不提供覆盖式导入或一键重置。保留资料与安全备份后，再处理读取错误。").font(.caption).foregroundStyle(.secondary)
            }
            if let failure=store.data.failure { Section("资料需要检查") { Text(failure).foregroundStyle(.orange).textSelection(.enabled) } }
        }.formStyle(.grouped)
    }
    private var about: some View {
        VStack(spacing:14) {
            if let image=NSImage(named:NSImage.Name("AppIcon")) { Image(nsImage:image).resizable().interpolation(.high).frame(width:100,height:100) }
            Text("搞操作 V\(store.version)").font(.title.bold())
            Text("构建 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "1") · 原生 macOS 工具").foregroundStyle(.secondary)
            Text("让 Mac 上的操作更简单").font(.headline)
            Text("文件、窗口、压缩、剪贴板与常用动作，集中到一个入口。").foregroundStyle(.secondary)
            Divider().padding(.horizontal,60)
            Text("Apple Silicon · macOS 14 或更高版本\n本地签名 · 未公证\n本机保存资料，不提供云同步或桌面小组件").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let url=Bundle.main.url(forResource:"使用说明",withExtension:"txt") { Button("打开使用说明") { NSWorkspace.shared.open(url) } }
            Spacer()
        }.padding(28)
    }
}

@MainActor private struct SettingsWindowBehaviorView: View {
    @ObservedObject var store: OperationStore
    @ObservedObject private var input: InputController
    @ObservedObject private var windows: WindowManager
    init(store: OperationStore) { self.store=store;self.input=store.input;self.windows=store.windows }
    var body: some View {
        Form {
            Section("窗口拖动与吸附") {
                Toggle("Option＋左键拖动前台窗口",isOn:Binding(get:{store.settings.windowDragEnabled},set:{enabled in store.update {$0.windowDragEnabled=enabled}})).disabled(!store.dataHealthy)
                Text("按住 Option，在前台目标窗口内按住左键拖动，可移动窗口；松开左键结束。").font(.caption).foregroundStyle(.secondary)
                Toggle("拖动到屏幕边缘吸附",isOn:Binding(get:{store.settings.windowSnapEnabled},set:{enabled in store.update {$0.windowSnapEnabled=enabled}})).disabled(!store.dataHealthy)
                Text("拖动窗口接近屏幕边缘时，按支持的区域排列窗口。此功能默认关闭，可与快捷键窗口动作独立设置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("所需权限") {
                LabeledContent("辅助功能",value:windows.isTrusted ? "已授权" : "尚未授权")
                Button("设置辅助功能权限") { windows.requestPermission() }
                LabeledContent("输入监听",value:input.permissionGranted ? "权限可用" : "尚未授权")
                Button("设置输入监控权限") { input.requestPermission() }
            }
            Section("使用边界") {
                Text("拖动功能只监听输入，不会吞掉目标应用原本收到的鼠标事件；目标应用可能同时执行选择或其他操作。特殊窗口、全屏窗口与不支持辅助功能的应用可能无法移动或吸附。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("输入排除应用与暂停监听同样适用于窗口拖动和吸附。可在“外观与剪贴板”页管理排除应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

@MainActor private struct SettingsPermissionsView: View {
    @ObservedObject var input: InputController
    @ObservedObject var windows: WindowManager
    var body: some View {
        Form {
            Section("窗口控制") {
                LabeledContent("辅助功能",value:windows.isTrusted ? "已授权" : "尚未授权")
                Text("用于定位和调整您选择的目标窗口。").font(.caption).foregroundStyle(.secondary)
                Button("设置辅助功能权限") { windows.requestPermission() }
                if let error=windows.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("快捷键与鼠标") {
                LabeledContent("输入监听",value:input.permissionGranted ? "权限可用" : "尚未授权")
                Button("设置输入监控权限") { input.requestPermission() }
                Text("识别您配置的快捷键、鼠标按钮和方向手势。不会记录键盘输入内容。").font(.caption).foregroundStyle(.secondary)
            }
            Section("Finder 右键菜单") {
                Button("打开系统扩展设置") {
                    let pane: String
                    if #available(macOS 15, *) { pane="com.apple.LoginItems-Settings.extension" }
                    else { pane="com.apple.ExtensionsPreferences" }
                    if let url=URL(string:"x-apple.systempreferences:"+pane) { NSWorkspace.shared.open(url) }
                }
                Text("在系统设置中启用“搞操作访达扩展”。不同 macOS 版本可位于“通用 → 登录项与扩展 → 文件提供程序”或“隐私与安全性 → 扩展”。扩展当前覆盖桌面、下载与文稿目录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("云盘或系统管理目录可能不显示扩展菜单，仍可用系统服务、快捷面板或拖入文件。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
