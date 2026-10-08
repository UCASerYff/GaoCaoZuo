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
    let title: String
    let detail: String
    let icon: String
    let section: OperationSection
    var keywords: String = ""
    var files = false
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        let text = title + " " + detail + " " + keywords + " " + id
        let pinyin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripCombiningMarks, reverse: false)?.replacingOccurrences(of: " ", with: "") ?? ""
        return text.lowercased().contains(q) || pinyin.lowercased().contains(q)
    }
    static var all: [OperationAction] {
        var actions: [OperationAction] = [
            .init(id:"panel.show",title:"打开操作面板",detail:"搜索动作或拖入文件",icon:"command",section:.home,keywords:"面板 搜索"),
            .init(id:"new.text",title:"新建文本文件",detail:"在指定目录新建 TXT",icon:"doc.badge.plus",section:.files),
            .init(id:"new.markdown",title:"新建 Markdown",detail:"使用模板开始写作",icon:"text.badge.plus",section:.files),
            .init(id:"new.template",title:"从模板新建",detail:"自定义内容与扩展名",icon:"doc.on.doc",section:.files),
            .init(id:"new.folder",title:"新建文件夹",detail:"在指定目录创建文件夹",icon:"folder.badge.plus",section:.files),
            .init(id:"path.copy",title:"复制文件路径",detail:"多个路径按行排列",icon:"link",section:.files,files:true),
            .init(id:"name.copy",title:"复制文件名称",detail:"包含文件扩展名",icon:"textformat",section:.files,files:true),
            .init(id:"files.copy",title:"复制到目录",detail:"预检重名，保留原文件",icon:"doc.on.doc",section:.files,files:true),
            .init(id:"files.move",title:"移动到目录",detail:"保留可核验的恢复记录",icon:"folder.badge.arrow.right",section:.files,files:true),
            .init(id:"files.rename",title:"批量重命名",detail:"名称与序号模板，执行前预览",icon:"pencil.line",section:.files,files:true),
            .init(id:"terminal.open",title:"在终端打开",detail:"进入所选目录",icon:"terminal",section:.files,files:true),
            .init(id:"finder.reveal",title:"在 Finder 显示",detail:"定位当前选中的文件",icon:"folder",section:.files,files:true),
            .init(id:"archive.create",title:"创建压缩包",detail:"ZIP / 7Z，加密与分卷",icon:"archivebox",section:.archives,files:true),
            .init(id:"archive.extract",title:"解压到新目录",detail:"预检路径，安全隔离提取",icon:"shippingbox",section:.archives,files:true),
            .init(id:"archive.list",title:"预览压缩包",detail:"查看列表并选择提取",icon:"list.bullet.rectangle",section:.archives,files:true),
            .init(id:"images.convert",title:"图片格式与尺寸",detail:"PNG / JPEG / HEIC / TIFF",icon:"photo",section:.tools,files:true),
            .init(id:"hash.sha256",title:"计算 SHA-256",detail:"复制文件校验值",icon:"number",section:.tools,files:true),
            .init(id:"text.qrcode",title:"生成二维码",detail:"将文本或网址保存为 PNG",icon:"qrcode",section:.tools),
            .init(id:"clipboard.show",title:"查看剪贴板",detail:"搜索历史与固定内容",icon:"doc.on.clipboard",section:.clipboard),
            .init(id:"clipboard.pasteplain",title:"复制为纯文本",detail:"移除当前剪贴板的格式",icon:"text.alignleft",section:.clipboard),
            .init(id:"system.preventSleep.toggle",title:"切换保持唤醒",detail:"阻止自动系统睡眠",icon:"sun.max",section:.tools),
            .init(id:"system.lock",title:"锁定屏幕",detail:"发送系统锁屏请求",icon:"lock",section:.tools),
            .init(id:"system.sleep",title:"电脑睡眠",detail:"发送系统睡眠请求",icon:"moon",section:.tools),
            .init(id:"workflow.show",title:"查看组合操作",detail:"编辑并运行多个动作",icon:"square.stack.3d.up",section:.workflows)
        ]
        actions += WindowAction.allCases.map { .init(id:"window."+$0.rawValue,title:$0.title,detail:$0 == .restore ? "恢复本次运行保存的位置" : "调整前台目标窗口",icon:$0.icon,section:.windows,keywords:"分屏 布局 窗口") }
        return actions
    }
}
struct ToolRequest: Identifiable { var id = UUID(); var actionID: String }

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
    let data: LocalData
    let clipboard: ClipboardService
    let windows = WindowManager()
    let input = InputController()
    let archive = ArchiveService()
    var showPanel: (() -> Void)?
    var showMain: (() -> Void)?
    var showSettings: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    private var ready = false
    private var workflowTask: Task<Void,Never>?
    private var workflowProcess: Process?
    var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.00" }
    var dataHealthy: Bool { data.failure == nil }
    init(directory: URL) {
        data = LocalData(directory: directory)
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
        clipboard.configure(settings)
    }
    private func saveSettings() {
        do { try data.save(settings, name:"settings.json"); clipboard.configure(settings); onSettingsChanged?() }
        catch { self.error = error.localizedDescription }
    }
    func update(_ body: (inout OperationSettings) -> Void) { var value = settings; body(&value); settings = value }
    func toggleFavorite(_ id: String) { update { if $0.favorites.contains(id) { $0.favorites.removeAll {$0 == id} } else { $0.favorites.append(id) } } }
    var visibleActions: [OperationAction] {
        let all = OperationAction.all.filter {$0.matches(query)}
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
    func prepare(_ id: String) {
        guard !busy, !archive.isRunning else { error = "当前有任务正在进行，请完成或取消后再操作。"; return }
        if id == "panel.show" { showPanel?(); return }
        if id == "clipboard.show" { section = .clipboard; showMain?(); return }
        if id == "workflow.show" { section = .workflows; showMain?(); return }
        if id.hasPrefix("window."), let action = WindowAction(rawValue:String(id.dropFirst(7))) {
            do { try windows.perform(action); message = "已执行：\(action.title)" } catch { self.error = error.localizedDescription }; return
        }
        if id.hasPrefix("system.") {
            do { try SystemActions.perform(id:id); awake = SystemActions.isPreventingSleep; message = id == "system.preventSleep.toggle" ? (awake ? "保持唤醒已开启" : "保持唤醒已关闭") : "已发送系统请求" } catch { self.error = error.localizedDescription }; return
        }
        if id == "clipboard.pasteplain" {
            guard let text = NSPasteboard.general.string(forType:.string) else { error = "剪贴板没有可转换的文字。"; return }
            clipboard.copyText(text); message = "已复制为纯文本"; return
        }
        if let action = OperationAction.all.first(where:{$0.id == id}), action.files, selection.isEmpty { chooseFiles(); if selection.isEmpty { return } }
        if id == "path.copy" || id == "name.copy" {
            clipboard.copyText(selection.map { id == "path.copy" ? $0.path : $0.lastPathComponent }.joined(separator:"\n")); message = "已复制 \(selection.count) 项"; return
        }
        if id == "finder.reveal" { NSWorkspace.shared.activateFileViewerSelecting(selection); return }
        if id == "terminal.open" { openTerminal(defaultDirectory); return }
        if let action = OperationAction.all.first(where:{$0.id == id}) { section = action.section; sheet = ToolRequest(actionID:id); showMain?() }
        else { error = "未找到动作：\(id)" }
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
                try record(records); message = "\(label)完成，共 \(records.count) 项"; sheet = nil
            } catch {
                if let partial=error as? FileToolsPartialFailure,!partial.receipts.isEmpty {
                    do {let next=partial.receipts+receipts;try data.save(ReceiptDocument(records:next),name:"receipts.json");receipts=next}
                    catch {self.error="文件任务未完整回滚，恢复记录也未能保存：\(error.localizedDescription)\n请核验：\(partial.receipts.map{$0.destination.path}.joined(separator:"、"))"}
                }
                if self.error == nil {self.error=error.localizedDescription}
            }
            busy = false
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
            busy = false
        }
    }
    func saveWorkflow(_ workflow: OperationWorkflow) { update { if let i = $0.workflows.firstIndex(where:{$0.id == workflow.id}) { $0.workflows[i] = workflow } else { $0.workflows.append(workflow) } } }
    func cancelWorkflow() { workflowTask?.cancel();if let process=workflowProcess,process.isRunning{process.terminate()}; message = "已请求停止组合操作；已完成的步骤保留" }
    func runWorkflow(_ workflow: OperationWorkflow) {
        guard !workflowRunning, !busy else { error = "已有任务正在运行"; return }
        workflowRunning = true
        workflowTask = Task {
            defer { workflowRunning = false }
            do {
                for (i, step) in workflow.steps.enumerated() {
                    try Task.checkCancellation(); message = "\(workflow.name)：第 \(i+1)/\(workflow.steps.count) 步"
                    try await executeWorkflowStep(step)
                }
                message = "组合操作完成：\(workflow.name)"
            } catch { self.error = error.localizedDescription; message = "组合操作已停止；已完成的步骤保留" }
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
            if step.actionID.hasPrefix("window."), let action = WindowAction(rawValue:String(step.actionID.dropFirst(7))) { try windows.perform(action) }
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
}
