import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

public struct SnippetAttachment: Codable, Equatable, Identifiable {
    public var id: String { sha256 + ":" + type }
    public let filename: String
    public let originalName: String
    public let type: String
    public let sha256: String
    public let byteCount: Int
}

public struct SnippetFileReference: Codable, Equatable {
    public let path: String
    public let bookmark: Data?
    public static func capture(path: String) throws -> SnippetFileReference {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw DataFailure.message("文件引用路径无效。") }
        let url = URL(fileURLWithPath: path)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return SnippetFileReference(path: path, bookmark: bookmark)
    }
    func verifiedURL() throws -> URL {
        try verifiedURL(resolvingBookmark: { bookmark in
            var stale=false
            let url=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            return (url:url,isStale:stale)
        })
    }
    // The same production consistency and filesystem checks can be tested
    // without requesting access from ScopedBookmarksAgent in a CLI host.
    func verifiedURL(resolvingBookmark resolve:(Data) throws -> (url:URL,isStale:Bool)) throws -> URL {
        let url:URL
        if let bookmark {
            let resolved=try resolve(bookmark)
            guard !resolved.isStale else {throw DataFailure.message("文件引用授权已过期，请重新选择文件。")}
            url=resolved.url
        } else {url=URL(fileURLWithPath:path)}
        // Backups are untrusted input. A bookmark must not silently resolve to
        // a different file from the path displayed in the editor. Moved files
        // require a fresh explicit selection instead of inheriting that mismatch.
        guard let resolved=Self.normalizedLocalPath(url),
              let declared=Self.normalizedLocalPath(URL(fileURLWithPath:path)),resolved == declared else {
            throw DataFailure.message("文件引用书签与显示路径不一致，请重新选择原文件；未复制或粘贴其他目标。")
        }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT), access(url.path, R_OK) == 0 else {
            throw DataFailure.message("文件引用已失效或不可访问；引用不包含文件内容。")
        }
        return url
    }
    private static func normalizedLocalPath(_ url:URL)->String? {
        guard url.isFileURL,["","localhost"].contains(url.host?.lowercased() ?? "") else {return nil}
        var path=url.standardizedFileURL.path
        guard path.hasPrefix("/"),!path.contains("\0") else {return nil}
        // These are the system's standard aliases, also used by LocalData.
        if path == "/tmp" || path.hasPrefix("/tmp/") {path="/private"+path}
        if path == "/var" || path.hasPrefix("/var/") {path="/private"+path}
        return path
    }
}

struct LegacySnippetEvidence: Codable, Equatable {
    var name: String
    var text: String
}

struct SnippetLibraryDocument: Codable, Equatable {
    var schema = 1
    var revision: UInt64 = 0
    var groups: [SnippetGroup] = []
    var snippets: [AdvancedSnippet] = []
    var legacySources: [String: LegacySnippetEvidence] = [:]
    var previousRevision: String?
    var importedRecoveryRevisions: [String]?
}

public struct SnippetImportPreview {
    public let baseRevision: UInt64
    public let snippets: [AdvancedSnippet]
    public let groups: [SnippetGroup]
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let warnings: [String]
}

/// The JSON document is the transaction boundary. Attachments are immutable,
/// content addressed, and verified before being referenced or copied. Old
/// revisions and unreferenced attachments are retained for explicit recovery.
@MainActor public final class SnippetLibraryStore: ObservableObject {
    @Published public private(set) var snippets: [AdvancedSnippet] = []
    @Published public private(set) var groups: [SnippetGroup] = []
    @Published public private(set) var healthy = true
    @Published public private(set) var failure: String?
    private var document = SnippetLibraryDocument()
    private let local: LocalData
    private let documentName = "library.json"
    nonisolated public static let maximumAttachmentBytes = 16 * 1_024 * 1_024
    nonisolated public static let maximumLibraryAttachmentBytes = 64 * 1_024 * 1_024
    public var revision: UInt64 { document.revision }
    public var canUndo: Bool { document.previousRevision != nil && healthy }
    public var directory: URL { local.directory }
    public var namedAttachmentExportsDirectory: URL { local.directory.appendingPathComponent("NamedAttachmentExports", isDirectory: true) }
    public var attachmentReferenceCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for snippet in snippets {
            for attachment in (snippet.attachments ?? []) + (snippet.rtfAttachment.map { [$0] } ?? []) {
                counts[attachment.filename, default: 0] += 1
            }
        }
        return counts
    }

    public init(dataDirectory: URL) {
        local = LocalData(directory: dataDirectory.appendingPathComponent("Snippets", isDirectory: true))
        do {
            if let issue = local.failure { throw DataFailure.message(issue) }
            if let loaded = try local.load(documentName, as: SnippetLibraryDocument.self) {
                try validate(loaded); document = loaded
            }
            publish()
        } catch { stop(error) }
    }

    /// Three-way import never deletes the legacy array or replaces an edited
    /// advanced record. Stable legacy UUIDs make restarts and retries idempotent.
    func migrateLegacy(_ legacy: [TextSnippet]) throws {
        try requireHealthy()
        var candidate = document
        for source in legacy {
            let key = source.id.uuidString
            let evidence = LegacySnippetEvidence(name: source.name, text: source.text)
            if let index = candidate.snippets.firstIndex(where: { $0.id == source.id }) {
                if let previous = candidate.legacySources[key],
                   candidate.snippets[index].name == previous.name, candidate.snippets[index].text == previous.text,
                   candidate.snippets[index].format == .plain,
                   candidate.snippets[index].attachments?.isEmpty != false,
                   candidate.snippets[index].richTextRTF == nil {
                    candidate.snippets[index].name = source.name; candidate.snippets[index].text = source.text
                }
            } else if candidate.legacySources[key] == nil {
                candidate.snippets.append(AdvancedSnippet(id: source.id, name: source.name, text: source.text, order: candidate.snippets.count))
            }
            candidate.legacySources[key] = evidence
        }
        if candidate != document { try commit(candidate) }
    }

    public func upsert(_ snippet: AdvancedSnippet) throws {
        try requireHealthy()
        var candidate = document
        if let index = candidate.snippets.firstIndex(where: { $0.id == snippet.id }) { candidate.snippets[index] = snippet }
        else { candidate.snippets.append(snippet) }
        try commit(candidate)
    }

    public func remove(id: UUID) throws {
        try requireHealthy()
        var candidate = document; candidate.snippets.removeAll { $0.id == id }
        try commit(candidate)
    }

    func replaceAllSnippets(_ snippets: [AdvancedSnippet]) throws {
        var candidate = document; candidate.snippets = snippets; try commit(candidate)
    }

    public func upsertGroup(_ group: SnippetGroup) throws {
        try requireHealthy()
        var candidate = document
        if let index = candidate.groups.firstIndex(where: { $0.id == group.id }) { candidate.groups[index] = group }
        else { candidate.groups.append(group) }
        try commit(candidate)
    }

    public func previewCSV(_ content: String, policy: SnippetConflictPolicy) throws -> SnippetImportPreview {
        try requireHealthy()
        let imported = try SnippetCSVCodec.importCSV(content, existingSnippets: snippets, existingGroups: groups, policy: policy)
        let incoming = try SnippetCSVCodec.parseCSV(content).dropFirst().filter { $0.contains(where: { !$0.isEmpty }) }.count
        return try preview(snippets: imported.snippets, groups: imported.groups, incoming: incoming)
    }

    public func previewXLSX(_ data: Data, policy: SnippetConflictPolicy) throws -> SnippetImportPreview {
        let rows = try SnippetXLSXCodec.importXLSX(data)
        return try previewCSV(SnippetXLSXCodec.csvTable(rows), policy: policy)
    }

    public func applyImport(_ preview: SnippetImportPreview) throws {
        try requireHealthy()
        guard preview.baseRevision == document.revision else { throw DataFailure.message("短语库在预览后已变化，请重新预览导入。") }
        var candidate = document; candidate.snippets = preview.snippets; candidate.groups = preview.groups
        try commit(candidate)
    }

    public func importCSV(_ content: String, policy: SnippetConflictPolicy) throws { try applyImport(previewCSV(content, policy: policy)) }
    public func importXLSX(_ data: Data, policy: SnippetConflictPolicy) throws { try applyImport(previewXLSX(data, policy: policy)) }
    public func exportCSV() -> String { SnippetCSVCodec.exportCSV(snippets: snippets, groups: groups) }
    public func exportXLSX() throws -> Data { try requireHealthy(); return try SnippetXLSXCodec.exportXLSX(snippets: snippets, groups: groups) }

    public func undoLastChange() throws {
        try requireHealthy()
        guard let previous = document.previousRevision,
              let recovered = try local.load(previous, as: SnippetLibraryDocument.self) else {
            throw DataFailure.message("没有可恢复的短语版本。")
        }
        try validate(recovered)
        // A recovery is a new transaction; the current version remains recoverable.
        try commit(recovered)
    }

    public func importAttachment(from url: URL, type: String) throws -> SnippetAttachment {
        try requireHealthy()
        guard url.isFileURL, !type.isEmpty, type.utf8.count <= 256,
              type.utf8.allSatisfy({ $0 >= 45 && $0 <= 57 || $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 }) else {
            throw DataFailure.message("附件类型不受支持。")
        }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Self.readSelectedFile(url, maximum: Self.maximumAttachmentBytes)
        return try importAttachment(data: data, originalName: url.lastPathComponent, type: type)
    }

    public func importAttachment(data: Data, originalName: String, type: String) throws -> SnippetAttachment {
        try requireHealthy()
        guard data.count <= Self.maximumAttachmentBytes, !originalName.contains("\0"), originalName.utf8.count <= 4096,
              !type.isEmpty, type.utf8.count <= 256,
              type.utf8.allSatisfy({ $0 >= 45 && $0 <= 57 || $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 }) else {
            throw DataFailure.message("附件类型、名称或大小不正确。")
        }
        let digest = Self.sha(data), name = "attachment-\(digest).blob"
        if let existing = try local.loadAttachmentIfPresent(name, maximumSize: Self.maximumAttachmentBytes) {
            guard Self.sha(existing) == digest else { throw DataFailure.message("同名短语附件校验失败，未覆盖。") }
        } else {
            // Include orphaned and recovery-version attachments in the disk
            // budget. They are retained rather than silently deleting data.
            var retained = 0
            for file in try FileManager.default.contentsOfDirectory(at: local.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("attachment-") {
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                      info.st_size <= Self.maximumLibraryAttachmentBytes - retained else { throw DataFailure.message("短语附件目录包含异常项目或超过预算，未继续导入。") }
                retained += Int(info.st_size)
            }
            guard data.count <= Self.maximumLibraryAttachmentBytes - retained else { throw DataFailure.message("短语附件连同恢复版本已达 64 MB 上限；未清理原附件。") }
            try local.createFile(data, name: name)
        }
        return SnippetAttachment(filename: name, originalName: originalName, type: type, sha256: digest, byteCount: data.count)
    }

    public func verifiedAttachment(_ attachment: SnippetAttachment) throws -> Data {
        guard attachment.filename == "attachment-\(attachment.sha256).blob", attachment.sha256.count == 64,
              attachment.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              attachment.byteCount >= 0, attachment.byteCount <= Self.maximumAttachmentBytes else {
            throw DataFailure.message("短语附件记录无效。")
        }
        let bytes = try local.verifiedData(attachment.filename, maximumSize: Self.maximumAttachmentBytes)
        guard bytes.count == attachment.byteCount, Self.sha(bytes) == attachment.sha256 else {
            throw DataFailure.message("短语附件内容已变化，已停止使用。")
        }
        return bytes
    }

    /// Only prepares data. All attachments must pass before a caller changes the
    /// pasteboard. External legacy paths are retained as unavailable references;
    /// importing one requires a fresh user-selected file authorization.
    public func pasteboardItems(for snippet: AdvancedSnippet) throws -> [NSPasteboardItem] {
        try requireHealthy()
        guard snippet.attachmentPaths?.isEmpty != false else { throw DataFailure.message("旧短语文件引用尚未重新授权，请选择原附件后再复制。") }
        let verified = try (snippet.attachments ?? []).map { ($0, try verifiedAttachment($0)) }
        let references = try (snippet.fileReferences ?? []).map { try $0.verifiedURL() }
        let item = NSPasteboardItem()
        item.setString(snippet.resolvedText(), forType: .string)
        if snippet.format == .richText {
            if let attachment = snippet.rtfAttachment {
                guard attachment.type == "public.rtf" else { throw DataFailure.message("富文本附件类型不正确。") }
                let bytes = try verifiedAttachment(attachment)
                guard bytes.starts(with: Data("{\\rtf".utf8)) else { throw DataFailure.message("富文本附件不是 RTF。") }
                item.setData(bytes, forType: .rtf)
            } else if let rtf = snippet.richTextRTF, rtf.hasPrefix("{\\rtf"), rtf.utf8.count <= Self.maximumAttachmentBytes {
                item.setData(Data(rtf.utf8), forType: .rtf)
            } else {
                throw DataFailure.message("富文本正文无效；原数据已保留，未静默降级。")
            }
        }
        var result = [item]
        for (attachment, data) in verified {
            let attachmentItem = NSPasteboardItem()
            if ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "public.webp"].contains(attachment.type)
                || UTType(attachment.type)?.conforms(to: .image) == true {
                attachmentItem.setData(data, forType: NSPasteboard.PasteboardType(attachment.type))
            } else {
                let named = try SnippetNamedAttachmentExports.prepare(data: data, attachment: attachment, directory: namedAttachmentExportsDirectory)
                attachmentItem.setString(named.absoluteString, forType: .fileURL)
            }
            result.append(attachmentItem)
        }
        for url in references { let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); result.append(item) }
        return result
    }

    public func copyToPasteboard(_ snippet: AdvancedSnippet) throws {
        let items = try pasteboardItems(for: snippet)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects(items) else { throw DataFailure.message("剪贴板写入失败。") }
    }

    public func snippet(shortcut: String) -> AdvancedSnippet? {
        let matches = snippets.filter { $0.shortcut?.caseInsensitiveCompare(shortcut) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// No write or attachment reread: prepared pasteboard bytes are already
    /// immutable. Detect a replaced/removed/externally edited queue document at
    /// the final pre-dispatch boundary rather than after sending old content.
    func validateCurrentRevision() throws {
        try requireHealthy()
        do {
            let current = try local.load(documentName, as: SnippetLibraryDocument.self)
            guard current == document || current == nil && document == SnippetLibraryDocument() else {
                throw DataFailure.message("短语或堆栈资料在等待期间已变化，未发送内容。")
            }
        } catch { stop(error); throw error }
    }

    public func exportNativeBackup(to destination: URL) async throws {
        let files = try nativeBackupSnapshot()
        try await Task.detached { try SnippetNativeBackupIO.write(files: files, to: destination) }.value
    }

    public func previewNativeBackup(at source: URL, policy: SnippetConflictPolicy) async throws -> SnippetNativeBackupPreview {
        let loaded = try await Task.detached { try SnippetNativeBackupIO.read(at: source) }.value
        try requireHealthy(); try validateCurrentRevision()
        var candidate = document, groupIDs: [UUID: UUID] = [:]
        for group in loaded.current.groups {
            if let existing = candidate.groups.first(where: { $0.name == group.name }) { groupIDs[group.id] = existing.id }
            else {
                var copy = group
                if candidate.groups.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
                candidate.groups.append(copy); groupIDs[group.id] = copy.id
            }
        }
        var added = 0, updated = 0, skipped = 0
        for source in loaded.current.snippets {
            var copy = source; copy.groupID = source.groupID.flatMap { groupIDs[$0] }
            if let index = candidate.snippets.firstIndex(where: { $0.id == source.id || $0.name == source.name }) {
                switch policy {
                case .skip: skipped += 1; continue
                case .overwrite:
                    copy.id = candidate.snippets[index].id
                    if let code = copy.shortcut, candidate.snippets.enumerated().contains(where: { $0.offset != index && $0.element.shortcut?.lowercased() == code.lowercased() }) { copy.shortcut = nil }
                    candidate.snippets[index] = copy; updated += 1; continue
                case .keepBoth:
                    copy.id = UUID(); var suffix = 1
                    while candidate.snippets.contains(where: { $0.name == copy.name }) {
                        copy.name = source.name + (suffix == 1 ? " (恢复副本)" : L10n.format(" (恢复副本 %@)", String(describing: (suffix)))); suffix += 1
                    }
                }
            }
            if let code = copy.shortcut, candidate.snippets.contains(where: { $0.shortcut?.lowercased() == code.lowercased() }) { copy.shortcut = nil }
            candidate.snippets.append(copy); added += 1
        }
        let incomingCurrent = loaded.files["library.json"]!
        let savedCurrentName = "revision-\(Self.sha(incomingCurrent)).json"
        var files = loaded.files; files.removeValue(forKey: "library.json"); files[savedCurrentName] = incomingCurrent
        candidate.importedRecoveryRevisions = Array(Set((candidate.importedRecoveryRevisions ?? []) + [savedCurrentName])).sorted()
        // Validate against the package's immutable bytes without first writing
        // anything into the user's current library.
        try SnippetNativeBackupIO.validateDocumentShape(candidate, supplementalFiles: files, existing: local)
        return SnippetNativeBackupPreview(baseRevision: document.revision, added: added, updated: updated, skipped: skipped,
            warnings: ["恢复内容含富文本、附件与本地恢复版本；文件引用仍只是路径和授权引用，没有复制原文件内容。", "可选择 iCloud Drive 保存备份；这不是自动同步，也没有后台上传或跨端合并。", "同名冲突按本次选择处理；覆盖前会保留当前短语库恢复版本，重复快捷码留空。"],
            candidate: candidate, files: files)
    }

    public func restoreNativeBackup(_ preview: SnippetNativeBackupPreview) throws {
        try requireHealthy(); try validateCurrentRevision()
        guard preview.baseRevision == document.revision else { throw DataFailure.message("短语库在预览后已变化，请重新预览恢复。") }
        try SnippetNativeBackupIO.validateDocumentShape(preview.candidate, supplementalFiles: preview.files, existing: local)
        // Preflight every namespace collision and total attachment budget before
        // creating even one immutable file. An interrupted commit cannot replace
        // the active library; copied recovery material remains recoverable.
        var additions: [(String, Data)] = [], totalAttachments = 0
        for file in try FileManager.default.contentsOfDirectory(at: local.directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("attachment-") {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= Self.maximumLibraryAttachmentBytes - totalAttachments else { throw DataFailure.message("原附件目录异常，未恢复覆盖。") }
            totalAttachments += Int(info.st_size)
        }
        for (name, bytes) in preview.files {
            if let current = try local.loadAttachmentIfPresent(name, maximumSize: 32_000_000) {
                guard current == bytes else { throw DataFailure.message("恢复文件与当前不可变版本冲突，未覆盖。") }
            } else {
                additions.append((name, bytes))
                if name.hasPrefix("attachment-") { totalAttachments += bytes.count }
            }
        }
        guard totalAttachments <= Self.maximumLibraryAttachmentBytes else { throw DataFailure.message("恢复后附件及历史版本超过 64 MB，未导入。") }
        for (name, bytes) in additions { try local.createFile(bytes, name: name) }
        try commit(preview.candidate)
    }

    private func nativeBackupSnapshot() throws -> [String: Data] {
        try requireHealthy(); try validateCurrentRevision()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var files: [String: Data] = [:], pending = [documentName], visited = Set<String>()
        while let name = pending.popLast() {
            guard visited.insert(name).inserted else { continue }
            let bytes: Data
            if name == documentName, document == SnippetLibraryDocument() { bytes = try encoder.encode(document) }
            else { bytes = try local.verifiedData(name) }
            let value = try JSONDecoder().decode(SnippetLibraryDocument.self, from: bytes)
            if SnippetNativeBackupIO.revisionName(name), name != "revision-\(Self.sha(bytes)).json" { throw DataFailure.message("恢复版本标识与内容摘要不符，未导出。") }
            try validate(value); files[name] = bytes
            if let previous = value.previousRevision { pending.append(previous) }
            pending += value.importedRecoveryRevisions ?? []
            for snippet in value.snippets {
                for attachment in (snippet.attachments ?? []) + (snippet.rtfAttachment.map { [$0] } ?? []) {
                    files[attachment.filename] = try verifiedAttachment(attachment)
                }
            }
            try SnippetNativeBackupIO.checkBudget(files)
        }
        return files
    }

    private func preview(snippets imported: [AdvancedSnippet], groups importedGroups: [SnippetGroup], incoming: Int) throws -> SnippetImportPreview {
        var candidate = document; candidate.snippets = imported; candidate.groups = importedGroups
        try validate(candidate)
        let existing = Dictionary(snippets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = imported.filter { existing[$0.id] == nil }.count
        let updated = imported.filter { item in existing[item.id].map { $0 != item } == true }.count
        // CSV/XLSX are text tables. The native library retains rich bodies and
        // attachments; an explicit overwrite can be undone through its revision.
        return SnippetImportPreview(baseRevision: document.revision, snippets: imported, groups: importedGroups,
            added: added, updated: updated, skipped: max(0, incoming - added - updated),
            warnings: ["CSV/XLSX 仅传输文本表格；富文本与附件保留在本地短语库和恢复版本中。", "重复快捷码将留空，导入不会触发自动粘贴或回车。"])
    }

    private func commit(_ value: SnippetLibraryDocument) throws {
        try requireHealthy(); try validate(value)
        guard value != document else { return }
        guard document.revision < UInt64.max else { throw DataFailure.message("短语库修订号已达到上限。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(document)
        let previous = "revision-\(Self.sha(encoded)).json"
        if let old = try local.load(previous, as: SnippetLibraryDocument.self) {
            guard old == document else { throw DataFailure.message("短语恢复版本校验失败，未写入。") }
        } else { try local.createFile(encoded, name: previous) }
        var candidate = value; candidate.revision = document.revision + 1; candidate.previousRevision = previous
        do { try local.save(candidate, name: documentName); document = candidate; publish() }
        catch { stop(error); throw error }
    }

    private func validate(_ value: SnippetLibraryDocument) throws {
        guard value.schema == 1, value.snippets.count <= SnippetCSVCodec.maxImportRows, value.groups.count <= 1_000, value.legacySources.count <= SnippetCSVCodec.maxImportRows,
              Set(value.snippets.map(\.id)).count == value.snippets.count,
              Set(value.groups.map(\.id)).count == value.groups.count else { throw DataFailure.message("短语库版本、数量或标识不正确，原资料未覆盖。") }
        guard value.groups.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 4096 }),
              value.legacySources.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.name.utf8.count <= 4096 && $0.value.text.utf8.count <= 1_048_576 }),
              value.previousRevision.map(SnippetNativeBackupIO.revisionName) ?? true,
              (value.importedRecoveryRevisions?.count ?? 0) <= SnippetNativeBackupIO.maximumFiles,
              (value.importedRecoveryRevisions ?? []).allSatisfy(SnippetNativeBackupIO.revisionName) else {
            throw DataFailure.message("短语分组或迁移记录不正确，原资料未覆盖。")
        }
        let groupIDs = Set(value.groups.map(\.id)); var shortcuts = Set<String>(), total = 0; var checked = Set<String>()
        for snippet in value.snippets {
            guard !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  snippet.name.utf8.count <= 4096, snippet.text.utf8.count <= 1_048_576,
                  snippet.groupID.map(groupIDs.contains) ?? true,
                  (snippet.richTextRTF?.utf8.count ?? 0) <= Self.maximumAttachmentBytes,
                  snippet.tags.count <= 100, snippet.tags.allSatisfy({ $0.utf8.count <= 1024 }),
                  (snippet.attachments?.count ?? 0) <= 100, (snippet.fileReferences?.count ?? 0) <= 100,
                  (snippet.fileReferences ?? []).allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.path.utf8.count <= 4096 && ($0.bookmark?.count ?? 0) <= 1_048_576 }) else { throw DataFailure.message("短语字段或附件数量不正确，未写入。") }
            if let code = snippet.shortcut, !code.isEmpty {
                guard code.utf8.count <= 128, !code.contains(where: { $0.isWhitespace || $0.isNewline }), shortcuts.insert(code.lowercased()).inserted else {
                    throw DataFailure.message("快捷码重复、包含空白或过长，请修正后保存。")
                }
            }
            for attachment in (snippet.attachments ?? []) + (snippet.rtfAttachment.map { [$0] } ?? []) {
                _ = try verifiedAttachment(attachment)
                if checked.insert(attachment.filename).inserted { total += attachment.byteCount }
                guard total <= Self.maximumLibraryAttachmentBytes else { throw DataFailure.message("短语附件总量超过 64 MB 上限。") }
            }
        }
    }

    private func publish() { snippets = document.snippets.sorted { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }; groups = document.groups.sorted { $0.order < $1.order } }
    private func requireHealthy() throws { guard healthy else { throw DataFailure.message(failure ?? "短语库不可写，原资料已保留。") } }
    private func stop(_ error: Error) { failure = error.localizedDescription; healthy = false }
    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func readSelectedFile(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw DataFailure.message("无法读取所选附件。") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else {
            throw DataFailure.message("附件不是普通文件或超过读取预算。")
        }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximum - bytes.count else { throw DataFailure.message("附件读取失败或超出预算。") }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino, bytes.count == after.st_size else {
            throw DataFailure.message("附件读取期间已变化，未导入。")
        }
        return bytes
    }
}

private extension LocalData {
    func loadAttachmentIfPresent(_ name: String, maximumSize: Int) throws -> Data? {
        // Registration through load is inappropriate for non-JSON data. A
        // missing file is checked without following links; all present data is
        // still read and fingerprinted by LocalData's anchored descriptor path.
        var value = stat()
        if lstat(directory.appendingPathComponent(name).path, &value) != 0 {
            if errno == ENOENT { return nil }; throw DataFailure.message("无法检查短语附件。")
        }
        return try verifiedData(name, maximumSize: maximumSize)
    }
}
