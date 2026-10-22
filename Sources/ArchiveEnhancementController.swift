import AppKit
import Combine
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct ArchivePasswordRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case compression, extraction }
    var id = UUID()
    var label: String
    var kind: Kind
    var account: String { "password-book:" + id.uuidString }
}
private struct ArchivePasswordDocument: Codable { var schema = 1; var records: [ArchivePasswordRecord] = [] }
private struct ArchivePasswordExport: Codable {
    struct Item: Codable { var label: String; var kind: ArchivePasswordRecord.Kind; var password: String }
    var schema = 1
    var passwords: [Item]
}

@MainActor final class ArchiveEnhancementController: ObservableObject {
    @Published var preferences = ArchiveEnhancementPreferences()
    @Published private(set) var passwords: [ArchivePasswordRecord] = []
    @Published private(set) var failure: String?
    @Published var previewURL: URL?
    @Published var previewFiles: [URL] = []
    private let data: LocalData
    let directory: URL
    private var windows: [NSWindowController] = []
    private var previewRoots: [URL] = []

    init(directory: URL) {
        self.directory = directory; self.data = LocalData(directory: directory)
        do {
            if let saved = try data.load("archive-preferences.json", as: ArchiveEnhancementPreferences.self) {
                guard saved.schema == 1 else { throw DataFailure.message("压缩设置版本过新，已保留原资料。") }
                try saved.creation.validate(); try saved.extraction.validate(); preferences = saved
            }
            if let saved = try data.load("archive-password-book.json", as: ArchivePasswordDocument.self) {
                guard saved.schema == 1, saved.records.count <= 10_000, Set(saved.records.map(\.id)).count == saved.records.count else { throw DataFailure.message("密码本索引无效，已停止写入。") }
                passwords = saved.records
            }
        } catch { failure = error.localizedDescription }
    }

    nonisolated static var actions: [OperationAction] { [
        .init(id: "archive.quick.zip", title: "秒速打包 ZIP", detail: "不压缩，直接保存文件", icon: "bolt", section: .archives, files: true),
        .init(id: "archive.quick.7z", title: "秒速打包 7Z", detail: "不压缩，直接保存文件", icon: "bolt", section: .archives, files: true),
        .init(id: "archive.separate.zip", title: "分别压缩为 ZIP", detail: "每个所选项目生成独立压缩包", icon: "square.stack.3d.up", section: .archives, files: true),
        .init(id: "archive.separate.7z", title: "分别压缩为 7Z", detail: "每个所选项目生成独立压缩包", icon: "square.stack.3d.up", section: .archives, files: true),
        .init(id: "archive.extract.here", title: "展开到当前目录", detail: "直接展开内容，重名停止", icon: "shippingbox", section: .archives, files: true),
        .init(id: "archive.create.trash", title: "压缩后移到废纸篓", detail: "验证完成并记录后才处理原件", icon: "archivebox", section: .archives, files: true),
        .init(id: "archive.extract.trash", title: "解压后移到废纸篓", detail: "验证并记录完成后才处理原包", icon: "shippingbox", section: .archives, files: true),
        .init(id: "archive.passwords", title: "管理压缩密码本", detail: "密码保存在系统钥匙串，可导入导出", icon: "key", section: .archives),
        .init(id: "archive.preferences", title: "压缩与解压设置", detail: "参数、预算、编码与双击行为", icon: "slider.horizontal.3", section: .archives)
    ] }

    @discardableResult func handle(id: String, files: [URL], store: OperationStore) -> Bool {
        if id == "archive.preferences" { showWindow(title: "压缩与解压设置", view: ArchivePreferencesView(controller: self, store: store)); return true }
        if id == "archive.passwords" { showWindow(title: "压缩密码本", view: ArchivePasswordBookView(controller: self)); return true }
        if id == "archive.list" || id == "archive.browse" {
            guard files.count == 1 else { store.notify("请选择一个压缩包进行预览", failed: true); return true }
            showWindow(title: "压缩包 — " + files[0].lastPathComponent, view: ArchiveBrowserView(store: store, controller: self, archiveURL: files[0])); return true
        }
        if id == "archive.open" {
            if preferences.openBehavior == .preview { return handle(id: "archive.list", files: files, store: store) }
            if preferences.openBehavior == .panel { store.selection = files; store.showPanel?(); return true }
            return handle(id: "archive.extract.enhanced", files: files, store: store)
        }
        let creates = ["archive.quick.zip", "archive.quick.7z", "archive.separate.zip", "archive.separate.7z", "archive.create.trash", "archive.create.enhanced", "archive.7z.enhanced"]
        let extracts = ["archive.extract.here", "archive.extract.trash", "archive.extract.enhanced"]
        guard creates.contains(id) || extracts.contains(id) else { return false }
        guard store.dataHealthy, failure == nil else { store.notify(failure ?? "资料暂时不可写入", failed: true); return true }
        guard !files.isEmpty else { store.notify("请先选择文件", failed: true); return true }
        store.enqueueQuick(creates.contains(id) ? "压缩" : "解压") { [self] in
            var outputs: [URL] = []
            do {
                if creates.contains(id) {
                    var options = preferences.creation
                    if id.contains("quick") { options.level = .store }
                    if id.contains("separate") { options.separateItems = true }
                    if id.hasSuffix("trash") { options.trashOriginals = true }
                    let format: ArchiveFormat = id.contains("7z") ? .sevenZip : .zip
                    let groups = options.separateItems ? files.map { [$0] } : [files]
                    for group in groups {
                        if store.quickCancellationRequested || Task.isCancelled { return outputs }
                        let parent = group[0].deletingLastPathComponent()
                        let stem = group.count == 1 ? group[0].deletingPathExtension().lastPathComponent : "归档"
                        let date = options.appendDate ? "-" + Self.dateSuffix() : ""
                        let preferredName = stem + date + "." + format.rawValue
                        let shouldTrash = options.trashOriginals
                        let (result, originals) = try await store.archive.performFileIO { cancellation in
                            let result = try QuickFileActions.uniqueURL(in: parent, preferredName: preferredName)
                            try cancellation.check()
                            let originals: [(URL,String)] = shouldTrash ? try group.map {
                                try cancellation.check(); return ($0, try FileTools.archiveFingerprint($0))
                            } : []
                            try cancellation.check()
                            return (result, originals)
                        }
                        if store.quickCancellationRequested || Task.isCancelled { return outputs }
                        _ = try await store.archive.create(items: group, destination: result, format: format, password: nil, splitMB: nil, solid: false, options: options)
                        try store.record(store.archive.lastResultReceipts); outputs.append(result)
                        if options.trashOriginals && !store.quickCancellationRequested && !Task.isCancelled {
                            try await store.archive.performFileIO { cancellation in try Self.trashUnchanged(originals, checkCancellation: { try cancellation.check() }) }
                        }
                    }
                    if options.revealResults { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                } else {
                    var options = preferences.extraction
                    if id.hasSuffix("trash") { options.trashOriginals = true }
                    for source in files {
                        if store.quickCancellationRequested || Task.isCancelled { return outputs }
                        // Capture refuses unproven split-stream groups before any
                        // decoder work or original-file side effect can begin.
                        let shouldTrash = options.trashOriginals
                        let evidence=store.archive.volumeEvidence
                        let group = shouldTrash ? try await store.archive.performFileIO { _ in try ArchiveVolumeGroup.capture(source,evidence:evidence) } : nil
                        let originals = group?.fingerprints ?? []
                        if store.quickCancellationRequested || Task.isCancelled { return outputs }
                        let result = try await withPassword(archive: source, store: store) { password in
                            if id == "archive.extract.here" { return try await store.archive.extractIntoDirectory(archive: source, to: source.deletingLastPathComponent(), password: password, options: options) }
                            let target = try await store.archive.performFileIO { cancellation in
                                let target = try QuickFileActions.uniqueURL(in: source.deletingLastPathComponent(), preferredName: QuickFileActions.extractionFolderName(for: source), isDirectory: true)
                                try cancellation.check(); return target
                            }
                            if store.quickCancellationRequested || Task.isCancelled { throw ArchiveError.cancelled }
                            return [try await store.archive.extract(archive: source, to: target, password: password, selected: nil, options: options)]
                        }
                        try store.record(store.archive.lastResultReceipts); outputs += result
                        if options.trashOriginals && !store.quickCancellationRequested && !Task.isCancelled {
                            try await store.archive.performFileIO { cancellation in
                                try group!.verifyUnchanged()
                                try Self.trashUnchanged(originals, checkCancellation: { try cancellation.check() },validateOriginal:{try group!.verifyUnchanged($0)})
                            }
                        }
                    }
                    if options.revealResults { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                }
                return outputs
            } catch { if !outputs.isEmpty { store.lastOutputs = outputs }; throw error }
        }
        return true
    }

    func save() throws {
        if let failure { throw DataFailure.message(failure) }
        try preferences.creation.validate(); try preferences.extraction.validate()
        do { try data.save(preferences, name: "archive-preferences.json") }
        catch { failure = error.localizedDescription; throw error }
    }

    func addPassword(_ password: String, label: String, kind: ArchivePasswordRecord.Kind) throws {
        guard failure == nil, !password.isEmpty, password.utf8.count <= 1024, !password.contains("\n"), !password.contains("\r"), !password.contains("\0"), passwords.count < 10_000 else { throw DataFailure.message(failure ?? "密码无效或密码本已满。") }
        // Deduplicate by reading only this app's explicitly saved entries, never other apps' credentials.
        for record in passwords where record.kind == kind {
            if try PasswordVault.read(account: record.account) == password { return }
        }
        let record = ArchivePasswordRecord(label: String(label.prefix(200)), kind: kind)
        try PasswordVault.save(password, account: record.account)
        var records = passwords; records.append(record)
        try data.save(ArchivePasswordDocument(records: records), name: "archive-password-book.json")
        passwords = records
    }

    func deletePassword(_ record: ArchivePasswordRecord) throws {
        guard failure == nil else { throw DataFailure.message(failure!) }
        let records = passwords.filter { $0.id != record.id }
        try data.save(ArchivePasswordDocument(records: records), name: "archive-password-book.json")
        passwords = records
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.gaoseries.GaoCaoZuo.archives", kSecAttrAccount as String: record.account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DataFailure.message(L10n.format("密码索引已删除，钥匙串删除失败（%@）。", String(describing: (status)))) }
    }

    func importPasswords(from url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 5_000_000 else { throw DataFailure.message("请选择小于 5 MB 的普通密码本文件。") }
        let bytes = try Data(contentsOf: url)
        if let document = try? JSONDecoder().decode(ArchivePasswordExport.self, from: bytes) {
            guard document.schema == 1, document.passwords.count <= 10_000 else { throw DataFailure.message("密码本格式无效。") }
            for item in document.passwords { try addPassword(item.password, label: item.label, kind: item.kind) }
        } else {
            guard let text = String(data: bytes, encoding: .utf8) else { throw DataFailure.message("密码本应为 UTF-8 文本或搞操作 JSON 格式。") }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard lines.count <= 10_000, lines.allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }) else { throw DataFailure.message("密码本数量或长度无效。") }
            for (index, line) in lines.enumerated() { try addPassword(line, label: L10n.format("导入密码 %@", String(describing: (index + 1))), kind: .extraction) }
        }
    }

    func exportPasswords(to url: URL) throws {
        let items = try passwords.map { record -> ArchivePasswordExport.Item in
            guard let secret = try PasswordVault.read(account: record.account) else { throw DataFailure.message("钥匙串缺少密码，未导出不完整密码本。") }
            return .init(label: record.label, kind: record.kind, password: secret)
        }
        let bytes = try JSONEncoder().encode(ArchivePasswordExport(passwords: items))
        // Set privacy permissions at creation, before any plaintext password bytes exist.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
    }

    func withPassword<T>(archive: URL, store: OperationStore, preferredPassword: String? = nil, perform: @escaping (String?) async throws -> T) async throws -> T {
        var candidates: [String?] = []
        if let preferredPassword, !preferredPassword.isEmpty { candidates.append(preferredPassword) }
        candidates.append(nil)
        if let saved = try PasswordVault.read(account: archive.path), !saved.isEmpty { candidates.append(saved) }
        if preferences.tryPasswordBook {
            for record in passwords where record.kind == .extraction {
                if let secret = try PasswordVault.read(account: record.account), !candidates.contains(secret) { candidates.append(secret) }
            }
        }
        for password in candidates {
            if store.quickCancellationRequested || Task.isCancelled { throw ArchiveError.cancelled }
            do { return try await perform(password) }
            catch ArchiveError.passwordRequired { continue }
        }
        var incorrect = false
        while true {
            if store.quickCancellationRequested || Task.isCancelled { throw ArchiveError.cancelled }
            guard let password = await store.requestArchivePassword?(archive, incorrect) else { throw ArchiveError.cancelled }
            do {
                let value = try await perform(password)
                if preferences.saveExtractionPasswords { try addPassword(password, label: archive.lastPathComponent, kind: .extraction); try PasswordVault.save(password, account: archive.path) }
                return value
            } catch ArchiveError.passwordRequired { incorrect = true }
        }
    }

    func preview(archive: URL, path: String, password: String?, service: ArchiveService) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaocaozuo-preview-" + UUID().uuidString, isDirectory: true)
        var options = preferences.extraction; options.allowSafeLinks = false
        let before = try FileTools.fingerprint(archive)
        let listing = try await service.list(archive: archive, password: password, options: options)
        guard let entry = listing.first(where: { $0.path == path }), !entry.isDirectory,
              entry.symbolicLink == nil, entry.hardLink == nil, entry.size <= 128 * 1024 * 1024 else {
            throw ArchiveError.invalid("内容预览只接受不超过 128 MiB 的普通文件；较大项目请明确提取后打开。")
        }
        do {
            _ = try await service.extract(archive: archive, to: root, password: password, selected: [path], options: options)
            let file = root.appendingPathComponent(path)
            let identity = try EnhancedFileTools.checked(file)
            guard identity.st_size <= 128 * 1024 * 1024, try FileTools.fingerprint(archive) == before else { throw ArchiveError.invalid("预览内容或原压缩包已变化，未显示不完整结果。") }
            previewRoots.append(root); previewURL = file; previewFiles = [file]
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func clearPreviews() { previewURL = nil; previewFiles = []; previewRoots.forEach { try? FileManager.default.removeItem(at: $0) }; previewRoots = [] }
    func setDefaultAssociation(extensions: [String]) throws {
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext) else { throw DataFailure.message(L10n.format("无法识别格式：%@", String(describing: (ext)))) }
            let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, "com.gaoseries.GaoCaoZuo" as CFString)
            guard status == noErr else { throw DataFailure.message(L10n.format("设置默认解压应用失败（%@）。", String(describing: (status)))) }
        }
    }
    private func showWindow<V: View>(title: String, view: V) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = NSHostingView(rootView: view); window.center(); window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window); windows.append(controller); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private static func dateSuffix() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }
    nonisolated static func trashUnchanged(_ originals: [(URL, String)], checkCancellation: () throws -> Void = {},validateOriginal:((URL)throws->Void)?=nil, moveToTrash: ((URL) throws -> URL)? = nil) throws {
        for (url, hash) in originals {
            try checkCancellation()
            let current = hash.hasPrefix("archive-tree-v1:") ? try FileTools.archiveFingerprint(url) : try FileTools.fingerprint(url)
            guard current == hash else { throw FileToolsError.changed(url) }
            try validateOriginal?(url)
        }
        var moved: [(URL,URL,String)] = []
        do {
            for (url, hash) in originals {
                try checkCancellation()
                let current = hash.hasPrefix("archive-tree-v1:") ? try FileTools.archiveFingerprint(url) : try FileTools.fingerprint(url)
                guard current == hash else { throw FileToolsError.changed(url) }
                try checkCancellation()
                try validateOriginal?(url)
                let trashURL: URL
                if let moveToTrash { trashURL = try moveToTrash(url) }
                else {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    guard let value = trashed as URL? else { throw ArchiveError.invalid("废纸篓没有返回可恢复路径；请保留当前结果并检查原件。") }
                    trashURL = value
                }
                moved.append((url, trashURL, hash))
            }
            // Include cancellation arriving during the last (or only) trash move.
            try checkCancellation()
        } catch {
            var restored = true
            for (original, trashed, hash) in moved.reversed() {
                do {
                    try ArchiveFileIO.requireAbsent(original)
                    guard try FileTools.archiveFingerprint(trashed) == hash else { restored = false; continue }
                    try ArchiveFileIO.moveExclusively(trashed, to: original)
                } catch { restored = false }
            }
            throw ArchiveError.invalid(restored ? "原件后处理失败，已恢复本批已移动原件；解压结果保留。" : "原件后处理部分失败；已尽量恢复，本批结果与剩余废纸篓原件均保留，请复核。")
        }
    }
}
