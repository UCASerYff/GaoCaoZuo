import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OperationRootView: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        NavigationSplitView {
            List(selection: $store.section) {
                ForEach(OperationSection.allCases) { section in Label(section.rawValue,systemImage:section.icon).tag(section) }
            }.navigationSplitViewColumnWidth(min:160,ideal:180,max:230)
            .safeAreaInset(edge:.bottom) {
                Button { store.showSettings?() } label: { Label("设置…",systemImage:"gearshape").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).padding()
            }
        } detail: {
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:4) { Text("搞操作 V\(store.version)").font(.title2.weight(.semibold)); Text("让 Mac 的常用操作，少点几下。").foregroundStyle(.secondary) }
                    Spacer()
                    Button { store.windows.captureTarget(); store.showPanel?() } label: { Label("操作面板",systemImage:"command") }
                    Button { store.showSettings?() } label: { Image(systemName:"gearshape") }.help("设置 ⌘,")
                }.padding(20)
                Divider()
                SelectionBar(store:store)
                Divider()
                if !store.dataHealthy { Label("资料保护模式：\(store.data.failure ?? "无法写入资料")",systemImage:"exclamationmark.shield").font(.callout).foregroundStyle(.red).padding().frame(maxWidth:.infinity,alignment:.leading) }
                sectionContent
                Divider()
                HStack {
                    if store.busy || store.workflowRunning { ProgressView().controlSize(.small) }
                    Text(store.message).lineLimit(2).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if store.awake { Label("保持唤醒",systemImage:"sun.max").font(.callout) }
                }.padding(.horizontal,20).padding(.vertical,10)
            }.frame(minWidth:740,minHeight:640)
        }
        .sheet(item:$store.sheet) { request in ToolSheet(store:store,request:request) }
        .alert("操作提示",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error = nil}})) { Button("知道了"){store.error = nil} } message: { Text(store.error ?? "") }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in acceptDrop(providers,store:store) }
    }
    @ViewBuilder private var sectionContent: some View {
        switch store.section {
        case .clipboard: ClipboardWorkspace(store:store,clipboard:store.clipboard)
        case .input: InputRulesView(store:store)
        case .workflows: WorkflowListView(store:store)
        case .history: RecoveryView(store:store)
        default: ActionWorkspace(store:store)
        }
    }
}

struct SelectionBar: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:store.selection.isEmpty ? "tray" : "doc.on.doc").foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:3) {
                Text(store.selection.isEmpty ? "拖入文件，或点击选择文件" : "已选择 \(store.selection.count) 项").font(.callout.weight(.medium))
                if !store.selection.isEmpty { Text(store.selection.prefix(3).map(\.lastPathComponent).joined(separator:"、") + (store.selection.count > 3 ? "…" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(store.selection.map(\.path).joined(separator:"\n")) }
            }
            Spacer()
            Button("选择文件…",action:store.chooseFiles)
            if !store.selection.isEmpty { Button("清除"){store.selection = []}.buttonStyle(.borderless) }
        }.padding(.horizontal,20).padding(.vertical,12)
    }
}

struct ActionWorkspace: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack { Text(store.section.rawValue).font(.title3.weight(.semibold)); Spacer(); TextField("搜索动作、关键词或拼音",text:$store.query).textFieldStyle(.roundedBorder).frame(maxWidth:330) }
                if store.section == .windows { WindowPermissionCard(manager:store.windows) }
                if store.visibleActions.isEmpty { ContentUnavailableView("暂无匹配动作",systemImage:"magnifyingglass",description:Text("可以更换关键词，或将动作加入收藏。")) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:12)],spacing:12) {
                    ForEach(store.visibleActions) { action in ActionCard(store:store,action:action) }
                }
                if store.section == .home || store.section == .files { folders; templates }
                if store.section == .tools { Label("窗口、锁屏等功能按需使用系统授权。",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary) }
            }.padding(20)
        }
    }
    private var folders: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("常用目录").font(.headline); Spacer(); Button("添加目录…",action:store.addFolder) }
            if store.settings.folders.isEmpty { Text("收藏常用目录，快速打开或在复制、移动时选择。").foregroundStyle(.secondary) }
            ForEach(store.settings.folders) { folder in
                HStack { Button { store.openFolder(folder) } label: { Label(folder.name,systemImage:"folder") }; Text(folder.path).foregroundStyle(.secondary).font(.caption).lineLimit(1); Spacer(); Button { store.update {$0.folders.removeAll {$0.id == folder.id}} } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help("移除收藏") }
            }
        }.padding().background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:12))
    }
    private var templates: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("文件模板").font(.headline); Spacer(); Button("管理模板…"){store.sheet = ToolRequest(actionID:"templates.edit")} }
            HStack { ForEach(store.settings.templates.prefix(5)) { template in Button(template.name){store.sheet = ToolRequest(actionID:"template."+template.id.uuidString)} }; Spacer() }
        }
    }
}
struct ActionCard: View {
    @ObservedObject var store: OperationStore
    let action: OperationAction
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            Button { store.prepare(action.id) } label: {
                HStack(alignment:.top,spacing:12) {
                    Image(systemName:action.icon).font(.title2).foregroundStyle(.tint).frame(width:28)
                    VStack(alignment:.leading,spacing:6) { Text(action.title).font(.headline); Text(action.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minHeight:28) }
                    Spacer(minLength:0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.toggleFavorite(action.id) } label: { Image(systemName:store.settings.favorites.contains(action.id) ? "star.fill" : "star").foregroundStyle(store.settings.favorites.contains(action.id) ? Color.orange : Color.secondary) }.buttonStyle(.plain).help("收藏动作")
        }.padding(14).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.separator.opacity(0.5)))
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
    @FocusState private var focused: Bool
    var actions: [OperationAction] {
        let all = OperationAction.all.filter {$0.id != "panel.show" && $0.matches(query)}
        return query.isEmpty ? all.sorted { a,b in
            let af = store.settings.favorites.contains(a.id), bf = store.settings.favorites.contains(b.id)
            if af != bf { return af }
            if !store.selection.isEmpty, a.files != b.files { return a.files }
            return a.title < b.title
        } : all
    }
    var body: some View {
        VStack(spacing:0) {
            HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("搜索操作…",text:$query).textFieldStyle(.plain).font(.title3).focused($focused).onSubmit(runSelected); Text("esc").font(.caption).foregroundStyle(.secondary) }.padding(18)
            Divider()
            if !store.selection.isEmpty { HStack { Label("\(store.selection.count) 个已选项目",systemImage:"doc.on.doc"); Text(store.selection.first?.lastPathComponent ?? "").lineLimit(1); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(10) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(Array(actions.enumerated()),id:\.element.id) { index,action in
                            Button { close(); store.prepare(action.id) } label: {
                                HStack(spacing:12) { Image(systemName:action.icon).frame(width:22).foregroundStyle(.tint); VStack(alignment:.leading,spacing:3) { Text(action.title); Text(action.detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); if store.settings.favorites.contains(action.id) { Image(systemName:"star.fill").font(.caption).foregroundStyle(.orange) } }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(index == selected ? Color.accentColor.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).id(index)
                        }
                    }.padding(8)
                }.onChange(of:selected) { _,index in withAnimation(.easeOut(duration:0.1)){proxy.scrollTo(index,anchor:.center)} }
            }
            Divider()
            HStack { Text("↑↓ 选择 · 回车执行"); Spacer(); Button("选择文件…",action:store.chooseFiles).buttonStyle(.plain); Button("打开主窗口"){close();store.showMain?()}.buttonStyle(.plain) }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width:600,height:480)
        .onAppear { selected = 0; focused = true }
        .onChange(of:query) { _,_ in selected = 0 }
        .onExitCommand(perform:close)
        .onMoveCommand { direction in if direction == .down { selected = min(selected+1,max(0,actions.count-1)) }; if direction == .up { selected = max(0,selected-1) } }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { acceptDrop($0,store:store) }
    }
    private func runSelected() { if actions.indices.contains(selected) { let id = actions[selected].id; close(); store.prepare(id) } }
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
    var filtered: [ClipboardItem] { clipboard.items.filter {search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.text ?? "").localizedCaseInsensitiveContains(search)} }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("剪贴板").font(.title3.weight(.semibold)); Toggle("记录新复制的内容",isOn:Binding(get:{store.settings.clipboardEnabled},set:{v in store.update {$0.clipboardEnabled = v}})); Spacer(); TextField("搜索历史",text:$search).textFieldStyle(.roundedBorder).frame(width:220) }
            Text("历史保存在本机。来源标记为机密或临时的内容会跳过；可在设置中排除应用。").font(.callout).foregroundStyle(.secondary)
            if let error = clipboard.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red) }
            HStack { Text("\(clipboard.items.count) 条 · 保留 \(store.settings.clipboardDays) 天").font(.caption).foregroundStyle(.secondary); Spacer(); Button("清除未固定历史…"){confirmClear()} }
            List(filtered) { item in
                HStack(alignment:.top,spacing:12) {
                    if item.kind == .image, let image = clipboard.image(item) { Image(nsImage:image).resizable().scaledToFit().frame(width:66,height:48) }
                    else { Image(systemName:item.kind == .files ? "doc.on.doc" : "text.alignleft").font(.title2).frame(width:30) }
                    VStack(alignment:.leading,spacing:4) { Text(item.title).lineLimit(2); Text(item.date,style:.date).font(.caption).foregroundStyle(.secondary); if !item.sourceApp.isEmpty { Text(item.sourceApp).font(.caption2).foregroundStyle(.tertiary) } }
                    Spacer()
                    Button { clipboard.pin(item.id) } label: { Image(systemName:item.pinned ? "pin.fill" : "pin") }.buttonStyle(.borderless)
                    Button("复制"){do {try clipboard.copy(item);store.message = "已复制"} catch {store.error = error.localizedDescription}}.buttonStyle(.borderless)
                    if item.kind == .text { Button("纯文本"){do{try clipboard.copy(item,plain:true);store.message = "已复制为纯文本"}catch{store.error = error.localizedDescription}}.buttonStyle(.borderless) }
                    Button("粘贴"){do{try clipboard.paste(item)}catch{store.error = error.localizedDescription}}.buttonStyle(.borderless)
                    Button { clipboard.delete(item.id) } label: { Image(systemName:"trash") }.buttonStyle(.borderless)
                }.padding(.vertical,6)
            }.overlay { if filtered.isEmpty { ContentUnavailableView(clipboard.enabled ? "等待新的复制内容" : "历史记录尚未启用",systemImage:"doc.on.clipboard",description:Text("启用后开始记录；也可以直接使用下方常用文本。")) } }
            Divider()
            Text("常用文本").font(.headline)
            HStack { TextField("名称",text:$snippetName).frame(width:160); TextField("文本内容",text:$snippetText); Button("保存"){let name = snippetName.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty,!snippetText.isEmpty else{return};store.update {$0.snippets.append(.init(name:name,text:snippetText))};snippetName="";snippetText=""}.disabled(snippetName.isEmpty || snippetText.isEmpty) }
            ScrollView(.horizontal) { HStack { ForEach(store.settings.snippets) { snippet in HStack { Button(snippet.name){clipboard.copyText(snippet.text);store.message="已复制常用文本"}.help(snippet.text); Button{store.update {$0.snippets.removeAll {$0.id == snippet.id}}}label:{Image(systemName:"xmark.circle")}.buttonStyle(.borderless) } } } }
        }.padding(20)
    }
    private func confirmClear() { let alert=NSAlert();alert.messageText="清除未固定的剪贴板历史？";alert.informativeText="固定内容会保留；清除会同时移除本应用保存的对应图片附件。";alert.addButton(withTitle:"清除");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn {clipboard.clearUnpinned()} }
}

struct RecoveryView: View {
    @ObservedObject var store: OperationStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("恢复记录").font(.title3.weight(.semibold))
            Text("恢复前会核验目标内容；原位置冲突、文件变化或文件缺失时停止。新建、复制和转换的结果恢复时移入废纸篓。").font(.callout).foregroundStyle(.secondary)
            List(store.receipts) { receipt in HStack { VStack(alignment:.leading,spacing:4) { Text(receipt.destination.lastPathComponent).font(.headline); Text(receipt.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1); Text(receipt.date,style:.date).font(.caption) }; Spacer(); Text(receipt.kind.rawValue).font(.caption).foregroundStyle(.secondary); Button("恢复…") { let alert=NSAlert();alert.messageText="恢复这次操作？";alert.informativeText=receipt.destination.path;alert.addButton(withTitle:"恢复");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn {store.undo(receipt)} }.disabled(store.busy || !store.dataHealthy) } }.overlay { if store.receipts.isEmpty {ContentUnavailableView("暂无恢复记录",systemImage:"clock.arrow.circlepath")} }
        }.padding(20)
    }
}
