import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum OperationStyle {
    static let accent = Color(red: 0.12, green: 0.48, blue: 0.42)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

extension OperationSection {
    var displayTitle: String {
        switch self {
        case .home: return "工作台"
        case .overview: return "桌面总览"
        case .archives: return "压缩与解压"
        case .tools: return "实用工具"
        default: return rawValue
        }
    }
    var summary: String {
        switch self {
        case .home: return "从这里开始，轻松处理日常。"
        case .files: return "新建、整理与转换，文件处理更顺手。"
        case .archives: return "快速打包、解压与预览压缩内容。"
        case .windows: return "为眼前的工作，安排合适的位置。"
        case .overview: return "查找应用与窗口，快速回到正在做的事。"
        case .lockPolicy: return "按自己的习惯设置本机闲置与锁屏。"
        case .screenshots: return "捕捉画面、识别文字，记录重要内容。"
        case .clipboard: return "让复制过的内容，随时回到手边。"
        case .tools: return "图片转换、校验与系统小工具。"
        case .input: return "让常用动作，跟着你的操作习惯走。"
        case .workflows: return "把重复步骤串起来，一次完成。"
        case .history: return "查看文件操作，按需恢复处理结果。"
        }
    }
}

struct OperationRootView: View {
    @ObservedObject var store: OperationStore
    @ObservedObject private var fileEnhancements: FileEnhancementController
    init(store: OperationStore) { self.store = store; self.fileEnhancements = store.fileEnhancements }
    private var showsFileSelection: Bool {
        [.files, .archives, .tools].contains(store.section) || (!store.selection.isEmpty && store.section != .home)
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "command").font(.system(size: 23, weight: .medium))
                        .foregroundStyle(OperationStyle.accent).frame(width: 43, height: 43)
                        .background(OperationStyle.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("搞操作").font(.system(size: 19, weight: .semibold))
                        Text("让操作更顺手").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 22)
                List(selection: $store.section) {
                    navigationRow(.home)
                    Section("日常工具") {
                        navigationRow(.screenshots); navigationRow(.clipboard); navigationRow(.files)
                        navigationRow(.archives); navigationRow(.tools)
                    }
                    Section("桌面与窗口") {
                        navigationRow(.windows); navigationRow(.overview); navigationRow(.lockPolicy)
                    }
                    Section("自动化") { navigationRow(.input); navigationRow(.workflows) }
                    Section("活动") { navigationRow(.history) }
                }.listStyle(.sidebar)
                Divider().padding(.horizontal, 18)
                HStack {
                    Button { store.showSettings?() } label: { Label("设置", systemImage: "gearshape") }
                        .buttonStyle(.plain).help("设置 ⌘,")
                    Spacer()
                    Text("V\(store.version)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                if showsFileSelection { SelectionBar(store: store) }
                if !store.dataHealthy {
                    Label(L10n.format("资料保护模式：%@", String(describing: store.data.failure ?? "无法写入资料")), systemImage: "exclamationmark.shield")
                        .font(.callout).foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                OperationTaskStatusView(store: store)
                    .background(OperationStyle.surface.opacity(0.7))
                    .overlay(alignment: .top) { Divider().opacity(0.5) }
            }.frame(minWidth: 700, minHeight: 640).background(OperationStyle.canvas)
        }
        .tint(OperationStyle.accent)
        .sheet(item: $store.sheet) { request in ToolSheet(store: store, request: request) }
        .sheet(item: $fileEnhancements.request) { _ in FileEnhancementToolView(controller: store.fileEnhancements, store: store) }
        .alert("操作提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(L10n.text(store.error ?? "")) }
        .onChange(of: store.section) { _, _ in store.query = "" }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in acceptDrop(providers, store: store) }
    }
    private func navigationRow(_ section: OperationSection) -> some View {
        Label {
            Text(L10n.text(section.displayTitle))
        } icon: {
            Image(systemName: section == .home ? "square.grid.2x2" : section.icon)
                .foregroundStyle(store.section == section ? OperationStyle.accent : .secondary)
        }.padding(.vertical, 5).tag(section)
    }
    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(store.section.displayTitle)).font(.system(size: 23, weight: .semibold))
                Text(L10n.text(store.section.summary)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button { store.windows.captureTarget(); store.showPanel?() } label: {
                Label("搜索操作", systemImage: "magnifyingglass").padding(.horizontal, 6).padding(.vertical, 3)
            }.buttonStyle(.bordered).controlSize(.large).help("打开操作面板，搜索全部动作")
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }
    @ViewBuilder private var sectionContent: some View {
        switch store.section {
        case .home: OperationDashboardView(store: store)
        case .overview: DesktopOverviewView(controller: store.desktopOverview)
        case .lockPolicy: IntegratedLockSettingsView(store: store)
        case .screenshots: store.screenshots.workspaceView
        case .clipboard: ClipboardWorkspace(store: store, clipboard: store.clipboard)
        case .input: InputRulesView(store: store)
        case .workflows: WorkflowListView(store: store)
        case .history: RecoveryView(store: store)
        default: ActionWorkspace(store: store)
        }
    }
}

private struct OperationTaskStatusView: View {
    @ObservedObject var store: OperationStore
    @ObservedObject private var archive: ArchiveService
    init(store: OperationStore) { self.store = store; self.archive = store.archive }
    var body: some View {
        HStack(spacing: 12) {
            if store.busy || store.workflowRunning || archive.isRunning {
                ProgressView().controlSize(.small)
            }
            Text(store.awaitingArchivePassword ? L10n.text("等待解压密码") : store.message)
                .lineLimit(2).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if store.queuedCount > 0 {
                Menu {
                    Button("清除等待任务") { store.cancelWaitingJobs() }
                } label: { Label(L10n.format("等待 %@ 项", String(describing: (store.queuedCount))), systemImage: "list.bullet") }
                .controlSize(.small).fixedSize()
            }
            if archive.isRunning || store.awaitingArchivePassword {
                Button("取消任务") { store.cancelQuickArchive() }
                    .controlSize(.small).help("停止压缩或解压，同时取消等待任务")
            }
            if !store.lastOutputs.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(store.lastOutputs) } label: {
                    Label("上次结果", systemImage: "folder")
                }.controlSize(.small).help("在 Finder 中显示最近生成或处理的文件")
            }
            if store.awake { Image(systemName: "sun.max").foregroundStyle(.orange).help("保持唤醒已开启") }
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }
}

struct SelectionBar: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.selection.isEmpty ? "tray.and.arrow.down" : "doc.on.doc")
                .foregroundStyle(OperationStyle.accent).font(.system(size: 19))
                .frame(width: 38, height: 38).background(OperationStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.selection.isEmpty ? "拖入文件，开始处理" : L10n.format("已选择 %@ 项", String(store.selection.count)))
                    .font(.callout.weight(.medium))
                Text(store.selection.isEmpty ? "支持多选文件与文件夹" : store.selection.prefix(3).map(\.lastPathComponent).joined(separator: "、") + (store.selection.count > 3 ? "…" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(store.selection.map(\.path).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            Button("选择文件…", action: store.chooseFiles)
            if !store.selection.isEmpty {
                Button { store.selection = [] } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("清除选择").accessibilityLabel("清除选择")
            }
        }.padding(14).background(OperationStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.05)))
            .padding(.horizontal, 28).padding(.bottom, 18)
    }
}

struct ActionWorkspace: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索动作、关键词或拼音", text: $store.query).textFieldStyle(.plain)
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清除搜索")
                    }
                    Spacer(minLength: 0)
                    Text(L10n.format("%@ 个动作", String(store.visibleActions.count))).font(.caption).foregroundStyle(.secondary).fixedSize()
                }.padding(12).background(OperationStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                if store.section == .windows { WindowPermissionCard(manager:store.windows) }
                if store.visibleActions.isEmpty { ContentUnavailableView("暂无匹配动作",systemImage:"magnifyingglass",description:Text("可以更换关键词，或将动作加入收藏。")) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:12)],spacing:12) {
                    ForEach(store.visibleActions) { action in ActionCard(store:store,action:action) }
                }
                if store.section == .home || store.section == .files { folders; templates }
                if store.section == .tools { Label("窗口、锁屏等功能按需使用系统授权。",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary) }
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
    private var folders: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("常用目录").font(.headline); Spacer(); Button("添加目录…",action:store.addFolder) }
            if store.settings.folders.isEmpty { Text("收藏常用目录，快速打开或在复制、移动时选择。").foregroundStyle(.secondary) }
            ForEach(store.settings.folders) { folder in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button { store.openFolder(folder) } label: { Label(folder.name, systemImage: "folder") }
                            .disabled(!folder.isCommon)
                        Text(folder.path).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.middle).help(folder.path)
                        Spacer(minLength: 8)
                        Button { store.update { $0.folders.removeAll { $0.id == folder.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("移除收藏")
                    }
                    HStack(spacing: 14) {
                        Toggle("常用菜单", isOn: folderRole(folder, "common")).toggleStyle(.checkbox).controlSize(.small).disabled(!store.dataHealthy)
                        Toggle("发送菜单", isOn: folderRole(folder, "send")).toggleStyle(.checkbox).controlSize(.small).disabled(!store.dataHealthy)
                        Spacer(minLength: 8)
                        if !store.selection.isEmpty {
                            Button("复制到这里") { store.transfer(store.selection, to: URL(fileURLWithPath: folder.path, isDirectory: true), move: false) }
                                .controlSize(.small).disabled(!store.dataHealthy || !folder.isSend)
                            Button("移动到这里") { store.transfer(store.selection, to: URL(fileURLWithPath: folder.path, isDirectory: true), move: true) }
                                .controlSize(.small).disabled(!store.dataHealthy || !folder.isSend)
                        }
                    }
                }.padding(.vertical, 5)
            }
        }.padding().background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
    }
    @MainActor private func folderRole(_ folder:FavoriteFolder,_ role:String)->Binding<Bool> {
        Binding(get:{role == "common" ? folder.isCommon : folder.isSend},set:{enabled in
            store.update {value in
                guard let index=value.folders.firstIndex(where:{$0.id == folder.id}) else{return}
                var roles=value.folders[index].sourceRoles ?? ["common","send"]
                if enabled,!roles.contains(role) {roles.append(role)}
                if !enabled {roles.removeAll{$0 == role}}
                value.folders[index].sourceRoles=roles
            }
        })
    }
    private var templates: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("文件模板").font(.headline); Spacer(); Button("管理模板…"){store.sheet = ToolRequest(actionID:"templates.edit")} }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(store.settings.templates) { template in
                        Button(template.name) { store.prepare("template." + template.id.uuidString) }
                            .disabled(!store.dataHealthy).help("在当前目录直接新建，自动避开同名文件")
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
}
struct ActionCard: View {
    @ObservedObject var store: OperationStore
    let action: OperationAction
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.prepare(action.id) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: action.icon).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(OperationStyle.accent).frame(width: 42, height: 40)
                        .background(OperationStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(action.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        Text(action.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            .frame(minHeight: 34, alignment: .top)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(action.unavailableReason != nil).help(action.unavailableReason ?? action.detail)
            Button { store.toggleFavorite(action.id) } label: {
                Image(systemName: store.settings.favorites.contains(action.id) ? "star.fill" : "star")
                    .foregroundStyle(store.settings.favorites.contains(action.id) ? Color.orange : Color.secondary.opacity(0.65))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help(store.settings.favorites.contains(action.id) ? "取消收藏" : "收藏到工作台")
                .accessibilityLabel(store.settings.favorites.contains(action.id) ? "取消收藏" : "收藏到工作台")
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(OperationStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hovering ? OperationStyle.accent.opacity(0.45) : Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(hovering ? 0.05 : 0.02), radius: hovering ? 9 : 3, y: 2)
            .onHover { hovering = $0 }
    }
}

struct WindowPermissionCard: View {
    @ObservedObject var manager: WindowManager
    var body: some View {
        HStack { Image(systemName:manager.isTrusted ? "checkmark.shield" : "hand.raised"); VStack(alignment:.leading,spacing:4) { Text(manager.isTrusted ? "窗口控制已授权" : "窗口控制需要辅助功能授权").font(.headline); Text("操作前台目标窗口；先切到目标应用，再使用快捷键或操作面板。特殊窗口可能无法调整。").font(.callout).foregroundStyle(.secondary) }; Spacer(); Button("检查与授权",action:manager.requestPermission) }.padding().background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
    }
}

struct OperationPanelView: View {
    @ObservedObject var store: OperationStore
    var close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    var actions: [OperationAction] {
        if query.hasPrefix(":") {
            let code=String(query.dropFirst())
            guard let snippet=store.snippetLibrary.snippet(shortcut:code) else {return []}
            return store.actionChoices.filter {$0.id == "snippet.run."+snippet.id.uuidString}
        }
        let workflows = store.settings.workflows.map { workflow in
            OperationAction(id: "workflow.run." + workflow.id.uuidString, title: workflow.name,
                            detail: L10n.format("运行组合操作 · %@ 个步骤", String(describing: (workflow.steps.count))), icon: "square.stack.3d.up",
                            section: .workflows, keywords: "组合 工作流 workflow")
        }
        let all = (store.actionChoices + workflows).filter { $0.id != "panel.show" && $0.matches(query) }
        return query.isEmpty ? all.sorted { a,b in
            let af = store.settings.favorites.contains(a.id), bf = store.settings.favorites.contains(b.id)
            if af != bf { return af }
            if !store.selection.isEmpty, a.files != b.files { return a.files }
            return a.title < b.title
        } : all
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                OperationPanelSearchField(text:$query,onSubmit:runSelected,onCancel:close,onMoveSelection:moveSelection)
                    .frame(maxWidth:.infinity)
                Text("esc").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
            Divider()
            if !store.selection.isEmpty { HStack { Label(L10n.format("%@ 个已选项目", String(describing: (store.selection.count))),systemImage:"doc.on.doc"); Text(store.selection.first?.lastPathComponent ?? "").lineLimit(1); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(10) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(Array(actions.enumerated()),id:\.element.id) { index,action in
                            Button { run(action.id) } label: {
                                HStack(spacing:12) { Image(systemName:action.icon).frame(width:22).foregroundStyle(.tint); VStack(alignment:.leading,spacing:3) { Text(action.title); Text(action.detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); if store.settings.favorites.contains(action.id) { Image(systemName:"star.fill").font(.caption).foregroundStyle(.orange) } }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(index == selected ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(action.unavailableReason != nil).help(action.unavailableReason ?? action.detail).id(action.id)
                        }
                    }.padding(8)
                }.onChange(of:selected) { _,index in
                    guard actions.indices.contains(index) else {return}
                    withAnimation(.easeOut(duration:0.1)){proxy.scrollTo(actions[index].id,anchor:.center)}
                }
            }
            Divider()
            HStack { Text("↑↓ 选择 · 回车执行"); Spacer(); Button("选择文件…",action:store.chooseFiles).buttonStyle(.plain); Button("打开主窗口"){close();store.showMain?()}.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width:600,height:480)
        .onAppear { selected = 0 }
        .onChange(of:query) { _,_ in selected = 0 }
        .onChange(of: actions.map(\.id)) { _, _ in selected = min(selected, max(0, actions.count - 1)) }
        .onExitCommand(perform:close)
        .onMoveCommand { direction in if direction == .down {moveSelection(1)}; if direction == .up {moveSelection(-1)} }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { acceptDrop($0,store:store) }
    }
    private func run(_ id:String) {
        // A visible row can outlive a search update in a lazy stack. Recheck
        // its stable identity against the current query before any side effect.
        guard actions.contains(where:{$0.id == id && $0.unavailableReason == nil}) else {return}
        close();store.prepare(id)
    }
    private func runSelected() {if actions.indices.contains(selected) {run(actions[selected].id)}}
    private func moveSelection(_ offset:Int) {selected=min(max(0,selected+offset),max(0,actions.count-1))}
}

@MainActor func acceptDrop(_ providers: [NSItemProvider], store: OperationStore) -> Bool {
    guard !providers.isEmpty else { return false }
    let group = DispatchGroup(); let lock = NSLock(); var urls: [URL] = []
    for provider in providers {
        group.enter(); provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation:data,relativeTo:nil) }
            else if let value = item as? URL { url = value }
            if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue:.main) { store.selection = Array(Set(urls)).sorted {$0.path < $1.path} }
    return true
}

struct ClipboardWorkspace: View {
    @ObservedObject var store: OperationStore
    @ObservedObject var clipboard: ClipboardService
    @State private var search = ""
    @State private var snippetName = ""
    @State private var snippetText = ""
    @State private var groupFilter = ""
    @State private var metadataItem: ClipboardItem?
    var filtered: [ClipboardItem] { clipboard.items.filter {(groupFilter.isEmpty || $0.group == groupFilter) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.text ?? "").localizedCaseInsensitiveContains(search) || ($0.tags ?? []).contains(where:{$0.localizedCaseInsensitiveContains(search)}) || ($0.group ?? "").localizedCaseInsensitiveContains(search))} }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("剪贴板").font(.title3.weight(.semibold)); Toggle("记录新复制的内容",isOn:Binding(get:{store.settings.clipboardEnabled},set:{v in store.update {$0.clipboardEnabled = v}})); Spacer(); TextField("搜索历史",text:$search).textFieldStyle(.roundedBorder).frame(width:220) }
            Text("历史保存在本机。来源标记为机密或临时的内容会跳过；可在设置中排除应用。").font(.callout).foregroundStyle(.secondary)
            if let error = clipboard.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red) }
            HStack { Text(L10n.format("%@ 条 · 保留 %@ 天", String(describing: (clipboard.items.count)), String(describing: (store.settings.clipboardDays)))).font(.caption).foregroundStyle(.secondary); Spacer(); Button("清除未固定历史…"){confirmClear()} }
            HStack {
                Picker("分组",selection:$groupFilter) {Text("全部").tag("");ForEach(Array(Set(clipboard.items.compactMap(\.group))).sorted(),id:\.self) {Text($0).tag($0)}}.frame(width:240)
                if clipboard.hasActivePasteTransaction {Button("处理待确认粘贴") {store.showPasteReview?()}}
                Button("加入当前剪贴板到堆栈") {do {try clipboard.pushCurrentToStack()} catch {store.error=error.localizedDescription}}
                Button("粘贴堆栈顶部") {do {try clipboard.pasteFromStack()} catch {store.error=error.localizedDescription}}
            }
            List(filtered) { item in
                HStack(alignment:.top,spacing:12) {
                    if item.kind == .image, let image = clipboard.image(item) { Image(nsImage:image).resizable().scaledToFit().frame(width:66,height:48) }
                    else { Image(systemName:item.kind == .files ? "doc.on.doc" : "text.alignleft").font(.title2).frame(width:30) }
                    VStack(alignment:.leading,spacing:4) { Text(item.title).lineLimit(2); Text(item.date,style:.date).font(.caption).foregroundStyle(.secondary); if !item.sourceApp.isEmpty { Text(item.sourceApp).font(.caption2).foregroundStyle(.tertiary) } }
                    Spacer()
                    Button { clipboard.pin(item.id) } label: { Image(systemName:item.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
                    Button("复制"){do {try clipboard.copy(item);store.message = L10n.text("已复制")} catch {store.error = error.localizedDescription}}.buttonStyle(.borderless)
                    if item.kind == .text { Button("纯文本"){do{try clipboard.copy(item,plain:true);store.message = L10n.text("已复制为纯文本")}catch{store.error = error.localizedDescription}}.buttonStyle(.borderless) }
                    Button("粘贴"){do{try clipboard.paste(item)}catch{store.error = error.localizedDescription}}.buttonStyle(.borderless)
                    Menu { Button("分组与标签…") {metadataItem=item};Button("加入粘贴堆栈") {do {try clipboard.pushToStack(item)} catch {store.error=error.localizedDescription}} } label: {Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).frame(width:24)
                    Button { clipboard.delete(item.id) } label: { Image(systemName:"trash") }.buttonStyle(.borderless)
                }.padding(.vertical,6)
            }.overlay { if filtered.isEmpty { ContentUnavailableView(clipboard.enabled ? "等待新的复制内容" : "历史记录尚未启用",systemImage:"doc.on.clipboard",description:Text("启用后开始记录；也可以直接使用下方常用文本。")) } }
            Divider()
            HStack {Text("常用短语").font(.headline);Spacer();Button("分组、富内容与导入导出…") {store.showExtensionSettings?(11)}}
            HStack { TextField("名称",text:$snippetName).frame(width:160); TextField("文本内容",text:$snippetText); Button("保存"){let name=snippetName.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty,!snippetText.isEmpty else{return};do {try store.snippetLibrary.upsert(AdvancedSnippet(name:name,text:snippetText));snippetName="";snippetText=""} catch {store.error=error.localizedDescription}}.disabled(snippetName.isEmpty || snippetText.isEmpty || !store.dataHealthy) }
            ScrollView(.horizontal) { HStack { ForEach(store.snippetLibrary.snippets) { snippet in
                Button(snippet.name){store.executeSnippet(snippet)}.help(snippet.executionMode.title)
                    .contextMenu {Button("仅复制") {store.executeSnippet(snippet,mode:.copyOnly)};Button("仅粘贴") {store.executeSnippet(snippet,mode:.pasteOnly)};Button("粘贴并回车") {store.executeSnippet(snippet,mode:.pasteAndEnter)}}
            } } }.disabled(!store.snippetLibrary.healthy)
        }.padding(20)
        .sheet(item:$metadataItem) {item in ClipboardMetadataEditor(item:item,save:{group,tags in try clipboard.setMetadata(item.id,group:group,tags:tags)})}
    }
    private func confirmClear() {if store.confirmClipboardClear(stack:false) {clipboard.clearUnpinned()}}
}

struct RecoveryView: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("恢复记录").font(.title3.weight(.semibold))
            Text("恢复前会核验目标内容；原位置冲突、文件变化或文件缺失时停止。新建、复制和转换的结果恢复时移入废纸篓。").font(.callout).foregroundStyle(.secondary)
            List(store.receipts) { receipt in HStack { VStack(alignment:.leading,spacing:4) { Text(receipt.destination.lastPathComponent).font(.headline); Text(receipt.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1); Text(receipt.date,style:.date).font(.caption) }; Spacer(); Text(receipt.kind.rawValue).font(.caption).foregroundStyle(.secondary); Button("恢复…") { let alert=NSAlert();alert.messageText=L10n.text("恢复这次操作？");alert.informativeText=receipt.destination.path;alert.addButton(withTitle:L10n.text("恢复"));alert.addButton(withTitle:L10n.text("取消"));if alert.runModal() == .alertFirstButtonReturn {store.undo(receipt)} }.disabled(store.busy || !store.dataHealthy) } }.overlay { if store.receipts.isEmpty {ContentUnavailableView("暂无恢复记录",systemImage:"clock.arrow.circlepath")} }
        }.padding(20)
    }
}
