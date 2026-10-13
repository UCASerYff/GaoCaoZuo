import AppKit
import SwiftUI
import Combine

enum OperationSection: String, CaseIterable, Identifiable {
    case home = "常用", files = "文件", windows = "窗口", archives = "压缩", clipboard = "剪贴板", tools = "小工具", input = "快捷键与手势", workflows = "组合操作", history = "恢复记录"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: return "star"; case .files: return "folder"; case .windows: return "rectangle.split.2x1"; case .archives: return "archivebox"; case .clipboard: return "doc.on.clipboard"; case .tools: return "wand.and.stars"; case .input: return "keyboard"; case .workflows: return "square.stack.3d.up"; case .history: return "clock.arrow.circlepath" }
    }
}
struct OperationAction: Identifiable {
    let id: String
    private let sourceTitle: String
    private let sourceDetail: String
    private let localizeTitle: Bool
    var title: String { localizeTitle ? L10n.text(sourceTitle) : sourceTitle }
    var detail: String { L10n.text(sourceDetail) }
    let icon: String
    let section: OperationSection
    var keywords: String = ""
    var files = false
    init(id:String,title:String,detail:String,icon:String,section:OperationSection,keywords:String="",files:Bool=false,localizeTitle:Bool=true) {
        self.id=id;self.sourceTitle=title;self.sourceDetail=detail;self.icon=icon;self.section=section;self.keywords=keywords;self.files=files;self.localizeTitle=localizeTitle
    }
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        let text = title + " " + detail + " " + sourceTitle + " " + sourceDetail + " " + keywords + " " + id
        let pinyin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripCombiningMarks, reverse: false)?.replacingOccurrences(of: " ", with: "") ?? ""
        return text.lowercased().contains(q) || pinyin.lowercased().contains(q)
    }
    static var all: [OperationAction] {
        var actions: [OperationAction] = [
            .init(id:"panel.show",title:"打开操作面板",detail:"搜索动作或拖入文件",icon:"command",section:.home,keywords:"面板 搜索"),
            .init(id:"new.text",title:"新建文本文件",detail:"立即在当前目录创建，重名自动编号",icon:"doc.badge.plus",section:.files),
            .init(id:"new.markdown",title:"新建 Markdown",detail:"立即新建 .md 文件，重名自动编号",icon:"text.badge.plus",section:.files),
            .init(id:"new.custom",title:"自定义新建…",detail:"指定名称与初始内容",icon:"square.and.pencil",section:.files),
            .init(id:"new.template",title:"从模板新建",detail:"自定义内容与扩展名",icon:"doc.on.doc",section:.files),
            .init(id:"new.folder",title:"新建文件夹",detail:"立即创建，不再询问名称",icon:"folder.badge.plus",section:.files),
            .init(id:"path.copy",title:"复制文件路径",detail:"多个路径按行排列",icon:"link",section:.files,files:true),
            .init(id:"name.copy",title:"复制文件名称",detail:"包含文件扩展名",icon:"textformat",section:.files,files:true),
            .init(id:"files.copy",title:"复制到目录",detail:"预检重名，保留原文件",icon:"doc.on.doc",section:.files,files:true),
            .init(id:"files.move",title:"移动到目录",detail:"保留可核验的恢复记录",icon:"folder.badge.arrow.right",section:.files,files:true),
            .init(id:"files.rename",title:"批量重命名",detail:"名称与序号模板，执行前预览",icon:"pencil.line",section:.files,files:true),
            .init(id:"terminal.open",title:"在终端打开",detail:"进入所选目录",icon:"terminal",section:.files,files:true),
            .init(id:"finder.reveal",title:"在 Finder 显示",detail:"定位当前选中的文件",icon:"folder",section:.files,files:true),
            .init(id:"archive.create",title:"压缩为 ZIP",detail:"原位置直接生成，自动避开同名文件",icon:"archivebox",section:.archives,files:true),
            .init(id:"archive.7z",title:"压缩为 7Z",detail:"原位置直接生成，无需设置",icon:"archivebox.fill",section:.archives,files:true),
            .init(id:"archive.custom",title:"自定义压缩…",detail:"加密、分卷与固实压缩",icon:"slider.horizontal.3",section:.archives,files:true),
            .init(id:"archive.extract",title:"直接解压",detail:"自动解到同目录，支持多选压缩包",icon:"shippingbox",section:.archives,files:true),
            .init(id:"archive.extract.custom",title:"解压到其他目录…",detail:"选择位置或提取部分文件",icon:"folder.badge.gearshape",section:.archives,files:true),
            .init(id:"archive.list",title:"预览压缩包",detail:"查看列表并选择提取",icon:"list.bullet.rectangle",section:.archives,files:true),
            .init(id:"images.png",title:"转为 PNG",detail:"原位置生成新图，保留原文件",icon:"photo",section:.tools,files:true),
            .init(id:"images.jpeg",title:"转为 JPEG",detail:"原位置生成新图，保留原文件",icon:"photo",section:.tools,files:true),
            .init(id:"images.heic",title:"转为 HEIC",detail:"原位置生成新图，保留原文件",icon:"photo",section:.tools,files:true),
            .init(id:"images.tiff",title:"转为 TIFF",detail:"原位置生成新图，保留原文件",icon:"photo",section:.tools,files:true),
            .init(id:"images.convert",title:"自定义图片转换…",detail:"PNG / JPEG / HEIC / TIFF",icon:"photo",section:.tools,files:true),
            .init(id:"hash.sha256",title:"复制 SHA-256",detail:"立即计算并复制文件校验值",icon:"number",section:.tools,files:true),
            .init(id:"text.qrcode.clipboard",title:"剪贴板转二维码",detail:"生成PNG并复制图片，保存到当前目录",icon:"qrcode",section:.tools),
            .init(id:"text.qrcode",title:"自定义二维码…",detail:"将文本或网址保存为 PNG",icon:"qrcode",section:.tools),
            .init(id:"clipboard.show",title:"查看剪贴板",detail:"搜索历史与固定内容",icon:"doc.on.clipboard",section:.clipboard),
            .init(id:"clipboard.pasteplain",title:"粘贴为纯文本",detail:"去除格式后直接粘贴到目标应用",icon:"text.alignleft",section:.clipboard),
            .init(id:"clipboard.copyplain",title:"复制为纯文本",detail:"只移除剪贴板格式，不发送粘贴",icon:"doc.plaintext",section:.clipboard),
            .init(id:"system.preventSleep.toggle",title:"切换保持唤醒",detail:"阻止自动系统睡眠",icon:"sun.max",section:.tools),
            .init(id:"system.lock",title:"锁定屏幕",detail:"发送系统锁屏请求",icon:"lock",section:.tools),
            .init(id:"system.sleep",title:"电脑睡眠",detail:"发送系统睡眠请求",icon:"moon",section:.tools),
            .init(id:"workflow.show",title:"查看组合操作",detail:"编辑并运行多个动作",icon:"square.stack.3d.up",section:.workflows)
        ]
        actions += EnhancedSystemPreset.allCases.map{OperationAction(id:"system."+$0.rawValue,title:$0.title,detail:"系统控制",icon:"keyboard",section:.tools)}
        actions += ArchiveEnhancementController.actions
        actions += FileEnhancements.actions
        actions += [OperationAction(id:"finder.popup",title:"弹出访达操作菜单",detail:"在当前访达目录选择动作",icon:"cursorarrow.click",section:.files),OperationAction(id:"folder.favorite.add",title:"添加到常用目录",detail:"收藏当前目录",icon:"heart",section:.files)]
        actions += WindowAction.allCases.map { .init(id:"window."+$0.rawValue,title:$0.title,detail:$0 == .restore ? "恢复本次运行保存的位置" : "调整前台目标窗口",icon:$0.icon,section:.windows,keywords:"分屏 布局 窗口") }
        return actions
    }
}
struct ToolRequest: Identifiable { var id = UUID(); var actionID: String; var title: String?; var files: [URL]? }

@MainActor final class OperationStore: ObservableObject {
    @Published var settings = OperationSettings() { didSet { if ready { saveSettings() } } }
    @Published var section: OperationSection = .home
    @Published var selection: [URL] = []
    @Published var query = ""
    @Published var sheet: ToolRequest?
    @Published var message = "选择一个动作开始"
    @Published var error: String?
    @Published var busy = false
    @Published var workflowRunning = false
    @Published var receipts: [FileOperationReceipt] = []
    @Published var awake = false
    @Published var queuedCount = 0
    @Published var feedback = OperationFeedback()
    @Published var lastOutputs: [URL] = []
    @Published var awaitingArchivePassword = false
    var finderPopupContainer:URL?
    var finderPopupSelection:[URL]=[]
    var quickCancellationRequested = false
    var cancelPasswordRequest: (() -> Void)?
    var quickJobs: [QueuedQuickOperation] = []
    var quickJobActive = false
    private var archiveObserver: AnyCancellable?
    let data: LocalData
    let clipboard: ClipboardService
    let windows = WindowManager()
    let input = InputController()
    let archive = ArchiveService()
    let archiveEnhancements: ArchiveEnhancementController
    let fileEnhancements: FileEnhancementController
    let finderPreferences: FinderPreferenceController
    var showPanel: (() -> Void)?
    var showMain: (() -> Void)?
    var showSettings: (() -> Void)?
    var showPermissions: (() -> Void)?
    var showClipboard: (() -> Void)?
    var activateForDialog: (() -> Void)?
    var showFeedback: (() -> Void)?
    var requestArchivePassword: ((URL, Bool) async -> String?)?
    var onSettingsChanged: (() -> Void)?
    private var ready = false
    private var workflowTask: Task<Void,Never>?
    private var workflowProcess: Process?
    var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.00" }
    var dataHealthy: Bool { data.failure == nil && archiveEnhancements.failure == nil && fileEnhancements.healthy && finderPreferences.data.failure == nil }
    init(directory: URL) {
        data = LocalData(directory: directory)
        archiveEnhancements = ArchiveEnhancementController(directory:directory.appendingPathComponent("ArchiveEnhancements",isDirectory:true))
        fileEnhancements = FileEnhancementController(directory:directory)
        finderPreferences = FinderPreferenceController(directory:directory)
        clipboard = ClipboardService(directory: directory)
        do {
            if let saved = try data.load("settings.json", as: OperationSettings.self) {
                guard saved.schema == 1 else { throw DataFailure.message("设置来自更新版本，已保留原资料并停止写入。") }
                settings = saved
            }
            if let saved = try data.load("receipts.json", as: ReceiptDocument.self) {
                guard saved.schema == 1 else { throw DataFailure.message("恢复记录来自更新版本，已停止写入。") }
                receipts = saved.records
            }
            ready = true
            try data.save(settings, name:"settings.json")
            try data.save(ReceiptDocument(records:receipts), name:"receipts.json")
        } catch { data.block(error.localizedDescription); self.error = error.localizedDescription; ready = true }
        do{try recoverInterruptedMigration()}catch{data.block(error.localizedDescription);self.error=error.localizedDescription}
        clipboard.configure(settings)
        archiveObserver = archive.$isRunning.dropFirst().sink { [weak self] running in
            if !running { Task { @MainActor in self?.drainQuickJobs() } }
        }
    }
    private func saveSettings() {
        do { try data.save(settings, name:"settings.json"); clipboard.configure(settings); onSettingsChanged?() }
        catch { self.error = error.localizedDescription }
    }
    func update(_ body: (inout OperationSettings) -> Void) { var value = settings; body(&value); settings = value }
    func toggleFavorite(_ id: String) { update { if $0.favorites.contains(id) { $0.favorites.removeAll {$0 == id} } else { $0.favorites.append(id) } } }
    var actionChoices:[OperationAction] {
        var result=OperationAction.all
        result += settings.windowEnhancements.customLayouts.map{OperationAction(id:"window.custom."+$0.id.uuidString,title:$0.name,detail:"自定义窗口布局",icon:"rectangle.split.2x2",section:.windows,localizeTitle:false)}
        result += fileEnhancements.settings.apps.filter(\.isEnabled).map{OperationAction(id:"file.open."+$0.id.uuidString,title:$0.name,detail:"打开所选文件或目录",icon:"app",section:.files,files:true,localizeTitle:false)}
        result += fileEnhancements.settings.templates.filter(\.isEnabled).map{OperationAction(id:"binaryTemplate."+$0.id.uuidString,title:$0.name,detail:"文件模板",icon:"doc",section:.files,localizeTitle:false)}
        return result
    }
    var visibleActions: [OperationAction] {
        let all = actionChoices.filter {$0.matches(query)}
        if !query.isEmpty { return all }
        if section == .home { return all.filter {settings.favorites.contains($0.id)} }
        return all.filter {$0.section == section}
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择要操作的文件或文件夹"
        if panel.runModal() == .OK { selection = panel.urls }
    }
    func chooseDirectory(prompt: String = "选择目录") -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
    var defaultDirectory: URL {
        guard let first = selection.first else { return FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser }
        return (try? first.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? first : first.deletingLastPathComponent()
    }
    func addFolder() { if let url = chooseDirectory(prompt:"收藏一个常用目录") { update {$0.folders.append(.init(name:url.lastPathComponent,path:url.path))} } }
    func openFolder(_ folder: FavoriteFolder) { if !NSWorkspace.shared.open(URL(fileURLWithPath:folder.path)) { error = "无法打开目录：\(folder.path)" } }
    func prepare(_ id: String) { prepare(id, files: selection) }
    func prepare(_ id: String, files: [URL]) {
        if id == "finder.popup" { showFinderPopup(); return }
        if id == "panel.show" { showPanel?(); return }
        if id == "clipboard.show" { showClipboard?(); return }
        if id == "workflow.show" { section = .workflows; showMain?(); return }
        if id.hasPrefix("workflow.run."), let uuid=UUID(uuidString:String(id.dropFirst(13))),let workflow=settings.workflows.first(where:{$0.id == uuid}) { runWorkflow(workflow); return }
        if id.hasPrefix("window."), let action = WindowAction(rawValue:String(id.dropFirst(7))) {
            Task {
                do { let outcome = try await windows.perform(action); notify(outcome.message) }
                catch { notify(error.localizedDescription, failed:true) }
            }
            return
        }
        if id.hasPrefix("system.") {
            do { try SystemActions.perform(id:id); awake = SystemActions.isPreventingSleep; notify(id == "system.preventSleep.toggle" ? (awake ? "保持唤醒已开启" : "保持唤醒已关闭") : "已发送系统请求") } catch { notify(error.localizedDescription,failed:true) }; return
        }
        if id == "cleaner.start" { CleanerController.shared.startCleaning(); return }
        if id == "flykey.show" { FlyKeyController.shared.showHUD(); return }
        if id == "selection.bar.show" {
            if let snapshot = SelectionSnapshot.capture() {
                SelectionActionBar.shared.showBar(snapshot: snapshot)
            } else if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                let fallback = SelectionSnapshot(pid: 0, bundleID: nil, launchIdentity: nil, element: nil, selectedText: clip, range: nil, isFromClipboardFallback: true)
                SelectionActionBar.shared.showBar(snapshot: fallback)
            } else {
                notify("未检测到活动选中文本，请选中文字后重试，或先复制文本", failed: true)
            }
            return
        }
        if id.hasPrefix("inputsource.") {
            handleInputSourceAction(id)
            return
        }
        if id == "clipboard.stack.paste" {
            do { try clipboard.pasteFromStack(); notify("已粘贴堆栈顶部文本") } catch { notify(error.localizedDescription, failed: true) }
            return
        }
        if id == "clipboard.stack.clear" {
            PasteStack.shared.clear()
            notify("已清空粘贴堆栈")
            return
        }
        if id == "clipboard.pasteplain" {
            do { try clipboard.pastePlainText(); notify("已发送纯文本粘贴") } catch { notify(error.localizedDescription,failed:true) };return
        }
        if id == "clipboard.copyplain" {
            guard let text=NSPasteboard.general.string(forType:.string) else {notify("剪贴板没有文字",failed:true);return}
            clipboard.copyText(text);notify("已复制为纯文本");return
        }
        if (id.hasPrefix("window.layout.") || id.hasPrefix("window.custom.")),let uuid=UUID(uuidString:String(id.dropFirst(14))) {
            Task {
                do { let outcome = try await windows.performCustomLayout(uuid); notify(outcome.message) }
                catch { notify(error.localizedDescription,failed:true) }
            }
            return
        }
        var selected=files
        let fileAction=actionChoices.first(where:{$0.id == id})?.files == true || id.hasPrefix("files.copy.") || id.hasPrefix("files.move.") || id.hasPrefix("folder.copy.") || id.hasPrefix("folder.move.")
        if fileAction && selected.isEmpty { activateForDialog?();chooseFiles();selected=selection;if selected.isEmpty{return} }
        if id == "folder.favorite.add" {
            let target=directory(for:selected)
            guard dataHealthy else {notify("资料保护模式，无法收藏目录",failed:true);return}
            if !settings.folders.contains(where:{$0.path == target.path}) {update{$0.folders.append(.init(name:target.lastPathComponent,path:target.path))}}
            notify("已添加到常用目录");return
        }
        for (prefix,move) in [("folder.copy.",false),("folder.move.",true)] where id.hasPrefix(prefix) {
            guard let uuid=UUID(uuidString:String(id.dropFirst(prefix.count))),let folder=settings.folders.first(where:{$0.id==uuid && $0.isSend}) else {notify("常用目录已失效",failed:true);return}
            let destination=URL(fileURLWithPath:folder.path,isDirectory:true)
            work(move ? "移动到常用目录" : "复制到常用目录"){try FileTools.copy(items:selected,to:destination,move:move)};return
        }
        if id.hasPrefix("folder.open."),let uuid=UUID(uuidString:String(id.dropFirst(12))),let folder=settings.folders.first(where:{$0.id==uuid && $0.isCommon}) {openFolder(folder);return}
        if id.hasPrefix("binaryTemplate."),let uuid=UUID(uuidString:String(id.dropFirst(15))) {
            do{let receipt=try fileEnhancements.createTemplate(uuid,directory:directory(for:selected));try record([receipt]);notify("已创建模板文件",outputs:[receipt.destination])}catch{notify(error.localizedDescription,failed:true)};return
        }
        let archiveID=["archive.create":"archive.create.enhanced","archive.7z":"archive.7z.enhanced","archive.extract":"archive.extract.enhanced"][id] ?? id
        if archiveEnhancements.handle(id:archiveID,files:selected,store:self) {return}
        if fileEnhancements.handle(id:id,files:selected,store:self) {return}
        if id == "path.copy" || id == "name.copy" {
            clipboard.copyText(selected.map{id == "path.copy" ? $0.path : $0.lastPathComponent}.joined(separator:"\n"));notify("已复制 \(selected.count) 项");return
        }
        if id == "finder.reveal" { NSWorkspace.shared.activateFileViewerSelecting(selected);return }
        if id == "terminal.open" {openTerminal(directory(for:selected));return}
        if runQuickAction(id,files:selected) {return}
        let mapped: String
        switch id {case "archive.custom":mapped="archive.create";case "archive.extract.custom":mapped="archive.extract";case "new.custom":mapped="new.text";default:mapped=id}
        guard OperationAction.all.contains(where:{$0.id == id}) || id.hasPrefix("template.") else {notify("未找到动作：\(id)",failed:true);return}
        guard sheet == nil else {notify("请先完成当前自定义操作",failed:true);showMain?();return}
        selection=selected
        sheet=ToolRequest(actionID:mapped,title:OperationAction.all.first(where:{$0.id == id})?.title,files:selected)
        showMain?()
    }
    func directory(for files:[URL]) -> URL {
        guard let first=files.first else{return FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser}
        return (try? first.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? first : first.deletingLastPathComponent()
    }
    func openTerminal(_ directory: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Terminal") else { error = "找不到系统终端。"; return }
        NSWorkspace.shared.open([directory], withApplicationAt:app, configuration:NSWorkspace.OpenConfiguration()) { _, failure in
            if let failure { Task { @MainActor in self.error = failure.localizedDescription } }
        }
    }
    func record(_ records: [FileOperationReceipt]) throws {
        guard !records.isEmpty else { return }
        let next = records + receipts
        do { try data.save(ReceiptDocument(records:next), name:"receipts.json"); receipts = next }
        catch {
            let saveFailure=error.localizedDescription
            do { try FileTools.undo(records) }
            catch {throw DataFailure.message("恢复记录无法保存：\(saveFailure)\n自动恢复也未完成：\(error.localizedDescription)\n请核验：\(records.map{ $0.destination.path }.joined(separator:"、"))")}
            throw DataFailure.message("恢复记录无法保存，刚完成的文件操作已恢复：\(saveFailure)")
        }
    }
    func work(_ label: String, task: @escaping () throws -> [FileOperationReceipt]) {
        guard dataHealthy, !busy else { error = data.failure ?? "任务正在进行"; return }
        busy = true; message = label; error = nil
        Task {
            do {
                let records = try await Task.detached(priority:.userInitiated) { try task() }.value
                try record(records); sheet = nil; notify("\(label)完成，共 \(records.count) 项",outputs:records.map(\.destination))
            } catch {
                if let partial=error as? FileToolsPartialFailure,!partial.receipts.isEmpty {
                    do {let next=partial.receipts+receipts;try data.save(ReceiptDocument(records:next),name:"receipts.json");receipts=next}
                    catch {self.error="文件任务未完整回滚，恢复记录也未能保存：\(error.localizedDescription)\n请核验：\(partial.receipts.map{$0.destination.path}.joined(separator:"、"))"}
                }
                if self.error == nil {self.error=error.localizedDescription}
            }
            busy = false; drainQuickJobs()
        }
    }
    func undo(_ receipt: FileOperationReceipt) {
        guard dataHealthy, !busy else { error = data.failure ?? "任务正在进行"; return }
        busy = true
        Task {
            do {
                try await Task.detached { try FileTools.undo([receipt]) }.value
                let next = receipts.filter {$0.id != receipt.id}; try data.save(ReceiptDocument(records:next),name:"receipts.json"); receipts = next
                message = "已恢复操作"
            } catch { self.error = error.localizedDescription }
            busy = false; drainQuickJobs()
        }
    }
    func saveWorkflow(_ workflow: OperationWorkflow) { update { if let i = $0.workflows.firstIndex(where:{$0.id == workflow.id}) { $0.workflows[i] = workflow } else { $0.workflows.append(workflow) } } }
    func cancelWorkflow() { workflowTask?.cancel();if let process=workflowProcess,process.isRunning{process.terminate()}; message = "已请求停止组合操作；已完成的步骤保留" }
    func runWorkflow(_ workflow: OperationWorkflow) {
        guard !workflowRunning, !busy, !archive.isRunning else { notify("已有任务正在运行",failed:true); return }
        workflowRunning = true
        feedback=OperationFeedback(kind:.running,title:"正在运行："+workflow.name);showFeedback?()
        workflowTask = Task {
            defer { workflowRunning = false; drainQuickJobs() }
            do {
                for (i, step) in workflow.steps.enumerated() {
                    try Task.checkCancellation(); message = "\(workflow.name)：第 \(i+1)/\(workflow.steps.count) 步"
                    try await executeWorkflowStep(step)
                }
                notify("组合操作完成：\(workflow.name)")
            } catch { notify("组合操作已停止；已完成的步骤保留："+error.localizedDescription,failed:true) }
        }
    }
    func executeWorkflowStep(_ step: WorkflowStep) async throws {
        switch step.actionID {
        case "open.path":
            guard step.argument.hasPrefix("/"), FileManager.default.fileExists(atPath:step.argument), NSWorkspace.shared.open(URL(fileURLWithPath:step.argument)) else { throw DataFailure.message("文件或应用无法打开，请检查路径。") }
            try await Task.sleep(nanoseconds:800_000_000); windows.captureTarget()
        case "open.url":
            guard let url = URL(string:step.argument), ["https","http"].contains(url.scheme?.lowercased() ?? ""), NSWorkspace.shared.open(url) else { throw DataFailure.message("请输入完整的 http/https 网址。") }
            try await Task.sleep(nanoseconds:700_000_000); windows.captureTarget()
        case "shortcut.run":
            guard !step.argument.isEmpty else { throw DataFailure.message("请填写系统快捷指令名称。") }
            try await runShortcut(step.argument)
        case "text.copy": clipboard.copyText(step.argument)
        case "delay":
            guard let seconds = Double(step.argument), seconds >= 0, seconds <= 30 else { throw DataFailure.message("等待时间应为 0–30 秒。") }
            try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000))
        default:
            if step.actionID.hasPrefix("window."), let action = WindowAction(rawValue:String(step.actionID.dropFirst(7))) {
                let outcome = try await windows.perform(action)
                guard outcome.isExact else { throw DataFailure.message(outcome.message) }
            }
            else if step.actionID == "system.preventSleep.toggle" { try SystemActions.perform(id:step.actionID); awake = SystemActions.isPreventingSleep }
            else { throw DataFailure.message("组合操作包含不支持的步骤，请重新选择动作。") }
        }
    }
    private func runShortcut(_ name:String) async throws {
        try Task.checkCancellation()
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/shortcuts");process.arguments=["run",name];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        workflowProcess=process
        let timeout=Task{@MainActor in try? await Task.sleep(nanoseconds:120_000_000_000);if !Task.isCancelled,process.isRunning{process.terminate()}}
        defer{timeout.cancel();workflowProcess=nil}
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            process.terminationHandler={p in if p.terminationStatus == 0{continuation.resume()}else{continuation.resume(throwing:DataFailure.message("系统快捷指令失败、已取消或超过两分钟，请在快捷指令应用中检查。"))}}
            do{try process.run()}catch{process.terminationHandler=nil;continuation.resume(throwing:error)}
        }
        try Task.checkCancellation()
    }
    private func handleInputSourceAction(_ id: String) {
        if id == "inputsource.switch.abc" {
            let success = InputSourceCatalog.shared.selectInputSource(sourceID: "com.apple.keylayout.ABC")
            notify(success ? "已切换至英文键盘 (ABC)" : "英文输入法不可用", failed: !success)
        } else if id == "inputsource.switch.pinyin" {
            let pinyin = InputSourceCatalog.shared.availableKeyboardInputSources().first { $0.id.contains("SCIM") || $0.name.contains("拼音") }
            if let pinyin {
                let success = InputSourceCatalog.shared.selectInputSource(sourceID: pinyin.id)
                notify(success ? "已切换至 \(pinyin.name)" : "切换拼音输入法失败", failed: !success)
            } else {
                notify("未找到拼音输入法", failed: true)
            }
        } else if id == "inputsource.toggle" {
            let sources = InputSourceCatalog.shared.availableKeyboardInputSources()
            guard sources.count >= 2, let current = InputSourceCatalog.shared.currentInputSource() else {
                notify("当前只有一个可用输入法", failed: true)
                return
            }
            let next = sources.first { $0.id != current.id } ?? sources[0]
            let success = InputSourceCatalog.shared.selectInputSource(sourceID: next.id)
            notify(success ? "已切换至 \(next.name)" : "切换输入法失败", failed: !success)
        }
    }
}
