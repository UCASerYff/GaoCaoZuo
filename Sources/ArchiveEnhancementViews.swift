import AppKit
import Quartz
import SwiftUI

struct ArchiveBrowserView: View {
    @ObservedObject var store: OperationStore
    @ObservedObject var controller: ArchiveEnhancementController
    @ObservedObject private var service: ArchiveService
    let archiveURL: URL
    @State private var entries: [ArchiveEntry] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var additions: [URL] = []
    @State private var result: URL?
    @State private var backup: URL?
    init(store: OperationStore, controller: ArchiveEnhancementController, archiveURL: URL) {
        self.store = store; self.controller = controller; self.service = store.archive; self.archiveURL = archiveURL
    }
    private var tree: [ArchiveTreeNode] { ArchiveTreeNode.build(entries.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }) }
    private var canEdit: Bool { ["zip", "7z"].contains(archiveURL.pathExtension.lowercased()) }
    private var selectedFile: String? { selected.count == 1 ? entries.first(where: { $0.path == selected.first! && !$0.isDirectory && $0.symbolicLink == nil && $0.hardLink == nil })?.path : nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(archiveURL.lastPathComponent, systemImage: "archivebox").font(.headline)
                Spacer()
                Text("\(entries.count) 项").foregroundStyle(.secondary)
                Button("刷新", action: load).disabled(working || store.busy)
                Button("显示压缩包") { NSWorkspace.shared.activateFileViewerSelecting([archiveURL]) }
            }.padding()
            HStack {
                TextField("搜索包内路径", text: $search).textFieldStyle(.roundedBorder)
                SecureField("密码（需要时填写）", text: $password).textFieldStyle(.roundedBorder).frame(width: 220)
            }.padding(.horizontal).padding(.bottom, 10)
            HSplitView {
                VStack(spacing: 0) {
                    List {
                        OutlineGroup(tree, children: \.children) { node in
                            HStack {
                                Toggle(isOn: Binding(get: { selected.contains(node.path) }, set: { value in if value { selected.insert(node.path) } else { selected.remove(node.path) } })) {
                                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc")
                                }.toggleStyle(.checkbox)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: node.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }.help(node.path).onTapGesture(count: 2) { if !node.isDirectory { selected = [node.path]; preview() } }
                        }
                    }.listStyle(.inset).frame(minWidth: 360)
                    HStack {
                        Button("全选") { selected = Set(entries.map(\.path)) }
                        Button("清空") { selected = [] }
                        Spacer()
                        Text("勾选 \(selected.count) 项").font(.caption)
                    }.padding(10)
                }
                VStack {
                    if let url = controller.previewURL { ArchiveContentPreview(url: url).frame(minWidth: 300, minHeight: 260) }
                    else { ContentUnavailableView("包内内容预览", systemImage: "doc.text.magnifyingglass", description: Text("勾选一个文件，再点“预览内容”或双击文件。")) }
                }.frame(minWidth: 280)
            }
            Divider()
            HStack {
                Button("预览内容", action: preview).disabled(selectedFile == nil || working || store.busy)
                Button("全部解压") { extract(selection: nil) }.disabled(entries.isEmpty || working || store.busy)
                Button("提取勾选") { extract(selection: Array(selected)) }.disabled(selected.isEmpty || working || store.busy)
                Spacer()
                Button("添加文件…", action: addFiles).disabled(!canEdit || working || store.busy)
                Button("删除勾选并保存") { edit(removing: Array(selected), cleanHidden: false) }.disabled(!canEdit || selected.isEmpty || working || store.busy)
                Button("清理隐藏文件") { edit(removing: [], cleanHidden: true) }.disabled(!canEdit || working || store.busy)
            }.padding(12)
            if !additions.isEmpty {
                HStack {
                    Text("待添加：" + additions.map(\.lastPathComponent).joined(separator: "、")).lineLimit(2)
                    Spacer()
                    Button("添加并保存") { edit(removing: [], cleanHidden: false) }.disabled(working || store.busy)
                    Button("取消添加") { additions = [] }.disabled(working)
                }.padding(.horizontal).padding(.bottom, 10)
            }
            if working || service.isRunning {
                HStack { if let progress = service.progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }; Button("取消", action: service.cancel) }.padding(.horizontal).padding(.bottom, 8)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8) }
            if let result { HStack { Label("已保存：" + result.lastPathComponent, systemImage: "checkmark.circle"); Spacer(); Button("显示结果") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }.padding(.horizontal).padding(.bottom, 8) }
            if let backup { HStack { Text("编辑前原包已核验备份").font(.caption).foregroundStyle(.secondary); Button("显示原包备份") { NSWorkspace.shared.activateFileViewerSelecting([backup]) } }.padding(.bottom, 8) }
        }.onAppear { load() }.onDisappear { controller.clearPreviews() }
    }
    private func load() {
        run {
            entries = try await controller.withPassword(archive: archiveURL, store: store, preferredPassword: password) { pw in
                let list = try await service.list(archive: archiveURL, password: pw, options: controller.preferences.extraction)
                // A list with visible encrypted names can succeed without a password. Keep it unset
                // until an actual extract/preview validates the password.
                if let pw { password = pw }
                return list
            }
            selected = selected.intersection(Set(entries.map(\.path)))
        }
    }
    private func preview() {
        guard let path = selectedFile else { return }
        run {
            try await controller.withPassword(archive: archiveURL, store: store, preferredPassword: password) { pw in
                try await controller.preview(archive: archiveURL, path: path, password: pw, service: service)
                if let pw { password = pw }
            }
        }
    }
    private func extract(selection: [String]?) {
        let panel = NSOpenPanel(); panel.title = "选择解压目标目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        run {
            let outputs = try await controller.withPassword(archive: archiveURL, store: store, preferredPassword: password) { pw in
                let urls = try await service.extractIntoDirectory(archive: archiveURL, to: directory, password: pw, selected: selection, options: controller.preferences.extraction)
                if let pw { password = pw }
                return urls
            }
            try store.record(service.lastResultReceipts); result = outputs.first
            if controller.preferences.extraction.revealResults { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
    }
    private func addFiles() {
        let panel = NSOpenPanel(); panel.title = "选择添加到压缩包的文件"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { additions = panel.urls }
    }
    private func edit(removing: [String], cleanHidden: Bool) {
        let alert = NSAlert(); alert.messageText = "保存压缩包修改？"
        alert.informativeText = "将添加 \(additions.count) 项、删除 \(removing.count) 项" + (cleanHidden ? "，并清理包内隐藏文件" : "") + "。完整性验证通过后保存，编辑前原包会保留在搞操作资料备份中。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run {
            let changed = try await controller.withPassword(archive: archiveURL, store: store, preferredPassword: password) { pw in
                let value = try await service.edit(archive: archiveURL, password: pw, adding: additions, removing: removing, removeHidden: cleanHidden,
                    saveTo: archiveURL, backupDirectory: controller.directory.appendingPathComponent("ArchiveEdits", isDirectory: true),
                    options: controller.preferences.creation, extraction: controller.preferences.extraction)
                if let pw { password = pw }; return value
            }
            result = changed.result; backup = changed.backup; additions = []; selected = []
            entries = try await service.list(archive: archiveURL, password: password.isEmpty ? nil : password, options: controller.preferences.extraction)
        }
    }
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !working, !store.busy, !service.isRunning else { return }
        working = true; store.busy = true; error = nil
        Task { defer { working = false; store.busy = false; store.drainQuickJobs() }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}

struct ArchiveContentPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = true; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

struct ArchivePreferencesView: View {
    @ObservedObject var controller: ArchiveEnhancementController
    @ObservedObject var store: OperationStore
    @State private var ignoreText = ""
    @State private var error: String?
    @State private var status = ""
    var body: some View {
        Form {
            Section("压缩") {
                Picker("压缩等级", selection: $controller.preferences.creation.level) { ForEach(ArchiveCompressionLevel.allCases) { Text($0.title).tag($0) } }
                Stepper("CPU 线程：\(controller.preferences.creation.threads == 0 ? "自动" : String(controller.preferences.creation.threads))", value: $controller.preferences.creation.threads, in: 0...256)
                Toggle("7Z 加密文件名", isOn: $controller.preferences.creation.encryptFileNames)
                Toggle("每个所选项目分别压缩", isOn: $controller.preferences.creation.separateItems)
                Toggle("压缩包名称附加日期", isOn: $controller.preferences.creation.appendDate)
                Toggle("压缩完成后显示结果目录", isOn: $controller.preferences.creation.revealResults)
                Toggle("压缩完成并核验后将原件移到废纸篓", isOn: $controller.preferences.creation.trashOriginals)
                Text("忽略文件模式（每行一条，例如 .DS_Store、*.tmp）").font(.caption)
                TextEditor(text: $ignoreText).frame(height: 70).font(.system(.body, design: .monospaced))
            }
            Section("解压") {
                Toggle("自动展开 TAR.GZ / TGZ / TAR.XZ / TAR.LZ 等外层容器", isOn: $controller.preferences.extraction.recursiveContainers)
                Toggle("允许指向包内合法目标的链接", isOn: $controller.preferences.extraction.allowSafeLinks)
                Stepper("展开容量预算：\(controller.preferences.extraction.maximumExpandedGiB) GiB", value: $controller.preferences.extraction.maximumExpandedGiB, in: 1...16_384)
                Stepper("项目数预算：\(controller.preferences.extraction.maximumEntries)", value: $controller.preferences.extraction.maximumEntries, in: 1...5_000_000, step: 10_000)
                Stepper("时间预算：\(controller.preferences.extraction.maximumMinutes) 分钟", value: $controller.preferences.extraction.maximumMinutes, in: 1...1_440, step: 10)
                Picker("旧压缩包文件名编码", selection: $controller.preferences.extraction.filenameEncoding) { ForEach(ArchiveExtractionOptions.encodings, id: \.self) { Text($0 == "auto" ? "自动" : $0).tag($0) } }
                Toggle("解压完成后显示结果目录", isOn: $controller.preferences.extraction.revealResults)
                Toggle("解压完成并核验后将原包移到废纸篓", isOn: $controller.preferences.extraction.trashOriginals)
                Text("ZIP/7Z 分卷只支持保留原件解压；自动原件后处理尚未支持。").font(.caption).foregroundStyle(.secondary)
                Text("重名项目会停止，不会覆盖原有文件。预算调整后仍会核验实际输出和链接安全。").font(.caption).foregroundStyle(.secondary)
            }
            Section("密码与打开方式") {
                Toggle("保存正确的压缩密码到密码本", isOn: $controller.preferences.saveCompressionPasswords)
                Toggle("保存正确的解压密码到密码本", isOn: $controller.preferences.saveExtractionPasswords)
                Toggle("需要密码时先尝试解压密码本", isOn: $controller.preferences.tryPasswordBook)
                Picker("双击压缩包", selection: $controller.preferences.openBehavior) { ForEach(ArchiveOpenBehavior.allCases) { Text($0.title).tag($0) } }
                Button("将 ZIP / 7Z / RAR / TAR / TGZ 设为使用搞操作打开") {
                    do { try controller.setDefaultAssociation(extensions: ["zip", "7z", "rar", "tar", "tgz", "gz", "bz2", "xz", "lz", "ace"]); status = "已设置默认打开方式" } catch { self.error = error.localizedDescription }
                }
                Button("管理密码本") { controller.handle(id: "archive.passwords", files: [], store: store) }
            }
            if let failure = controller.failure { Text(failure).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
            if !status.isEmpty { Text(status).foregroundStyle(.green) }
            Button("保存设置") { do { controller.preferences.creation.ignoredPatterns = ignoreText.components(separatedBy: .newlines).filter { !$0.isEmpty }; try controller.save(); error = nil; status = "已保存" } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent)
        }.formStyle(.grouped).onAppear { ignoreText = controller.preferences.creation.ignoredPatterns.joined(separator: "\n") }
    }
}

struct ArchivePasswordBookView: View {
    @ObservedObject var controller: ArchiveEnhancementController
    @State private var label = ""
    @State private var password = ""
    @State private var kind: ArchivePasswordRecord.Kind = .extraction
    @State private var error: String?
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("压缩密码本").font(.title2.bold())
            Text("密码只保存在本应用的系统钥匙串中；列表只显示标签。导入、导出不会读取其他软件的钥匙串密码。").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("标签", text: $label); SecureField("密码", text: $password); Picker("用途", selection: $kind) { Text("解压").tag(ArchivePasswordRecord.Kind.extraction); Text("压缩").tag(ArchivePasswordRecord.Kind.compression) }.frame(width: 150); Button("添加") { perform { try controller.addPassword(password, label: label.isEmpty ? "常用密码" : label, kind: kind); password = ""; label = "" } }.disabled(password.isEmpty) }.textFieldStyle(.roundedBorder)
            List(controller.passwords) { record in
                HStack { Label(record.label, systemImage: "key"); Spacer(); Text(record.kind == .compression ? "压缩" : "解压").foregroundStyle(.secondary); Button("删除") { perform { try controller.deletePassword(record) } } }
            }
            HStack {
                Button("导入 UTF-8 / JSON 密码本…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { perform { try controller.importPasswords(from: url); status = "导入完成" } }
                }
                Button("导出密码本…") {
                    let alert = NSAlert(); alert.messageText = "导出包含明文密码"; alert.informativeText = "导出文件可被其他应用读取。请选择安全位置，使用后妥善保存或删除。"; alert.addButton(withTitle: "选择保存位置"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "搞操作密码本.json"
                    if panel.runModal() == .OK, let url = panel.url { perform { try controller.exportPasswords(to: url); status = "密码本已导出" } }
                }.disabled(controller.passwords.isEmpty)
                Spacer(); Text("\(controller.passwords.count) 个密码").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let failure = controller.failure { Text(failure).foregroundStyle(.red) }
            if !status.isEmpty { Text(status).foregroundStyle(.green) }
        }.padding(20)
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { self.error = error.localizedDescription } }
}
