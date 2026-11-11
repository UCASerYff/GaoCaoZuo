import CryptoKit
import Darwin
import Foundation

public struct SnippetNativeBackupPreview {
    public let baseRevision: UInt64
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let warnings: [String]
    let candidate: SnippetLibraryDocument
    let files: [String: Data]
}

enum SnippetNativeBackupIO {
    struct FileRecord: Codable { let name: String; let byteCount: Int; let sha256: String }
    struct Manifest: Codable {
        var schema = 1
        var format = "GaoCaoZuo.SnippetBackup"
        var currentDocument = "library.json"
        let files: [FileRecord]
    }
    struct Contents { let current: SnippetLibraryDocument; let files: [String: Data] }
    static let maximumFiles = 256
    static let maximumBytes = 128 * 1_024 * 1_024
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { 48...57 ~= $0 || 97...102 ~= $0 } }
    static func revisionName(_ value: String) -> Bool { value.hasPrefix("revision-") && value.hasSuffix(".json") && digest(String(value.dropFirst(9).dropLast(5))) }
    static func attachmentName(_ value: String) -> Bool { value.hasPrefix("attachment-") && value.hasSuffix(".blob") && digest(String(value.dropFirst(11).dropLast(5))) }
    static func validName(_ value: String) -> Bool { value == "library.json" || revisionName(value) || attachmentName(value) }
    static func checkBudget(_ files: [String: Data]) throws {
        guard files.count <= maximumFiles, files.allSatisfy({ validName($0.key) && $0.value.count <= 32_000_000 }),
              files.values.reduce(0, { $0 + $1.count }) <= maximumBytes else {
            throw DataFailure.message("原生短语备份超过 256 个文件／128 MB 安全预算，原资料未修改。")
        }
    }

    static func read(at url: URL) throws -> Contents {
        guard url.isFileURL, url.pathExtension.lowercased() == "gaosnippets" else { throw DataFailure.message("请选择 .gaosnippets 原生短语备份目录包。") }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = LocalData(directory: url, createIfMissing: false)
        if let issue = local.failure { throw DataFailure.message(issue) }
        let manifestBytes = try local.verifiedData("manifest.json", maximumSize: 1_048_576)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
        guard manifest.schema == 1, manifest.format == "GaoCaoZuo.SnippetBackup", manifest.currentDocument == "library.json",
              manifest.files.count <= maximumFiles, Set(manifest.files.map(\.name)).count == manifest.files.count,
              manifest.files.contains(where: { $0.name == "library.json" }) else { throw DataFailure.message("原生短语备份版本、格式或清单无效。") }
        let expected = Set(manifest.files.map(\.name) + ["manifest.json"])
        guard Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == expected else { throw DataFailure.message("原生备份含未登记、缺失或嵌套成员，未导入。") }
        var files: [String: Data] = [:], total = 0
        for record in manifest.files {
            guard validName(record.name), record.byteCount >= 0, record.byteCount <= 32_000_000,
                  record.byteCount <= maximumBytes - total, digest(record.sha256) else { throw DataFailure.message("备份文件路径或读取预算无效。") }
            let data = try local.verifiedData(record.name, maximumSize: record.byteCount)
            guard data.count == record.byteCount, sha(data) == record.sha256 else { throw DataFailure.message("备份文件摘要不匹配，当前短语库未修改。") }
            if attachmentName(record.name) { guard record.name == "attachment-\(sha(data)).blob" else { throw DataFailure.message("备份附件标识与内容不一致。") } }
            if revisionName(record.name) { guard record.name == "revision-\(sha(data)).json" else { throw DataFailure.message("备份恢复版本标识与内容不一致。") } }
            files[record.name] = data; total += data.count
        }
        try checkBudget(files)
        for (name, data) in files where name == "library.json" || revisionName(name) {
            let document = try JSONDecoder().decode(SnippetLibraryDocument.self, from: data)
            try validateDocumentShape(document, supplementalFiles: files, existing: nil)
        }
        let current = try JSONDecoder().decode(SnippetLibraryDocument.self, from: files["library.json"]!)
        // Re-read through the original LocalData fingerprints to catch a late
        // directory, manifest or file replacement before returning the preview.
        guard try local.verifiedData("manifest.json", maximumSize: 1_048_576) == manifestBytes,
              Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == expected else { throw DataFailure.message("备份在读取期间已变化，未导入。") }
        return Contents(current: current, files: files)
    }

    static func validateDocumentShape(_ document: SnippetLibraryDocument, supplementalFiles files: [String: Data], existing: LocalData?) throws {
        guard document.schema == 1, document.snippets.count <= SnippetCSVCodec.maxImportRows, document.groups.count <= 1_000,
              document.legacySources.count <= SnippetCSVCodec.maxImportRows,
              document.legacySources.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.name.utf8.count <= 4096 && $0.value.text.utf8.count <= 1_048_576 }),
              Set(document.snippets.map(\.id)).count == document.snippets.count,
              Set(document.groups.map(\.id)).count == document.groups.count else { throw DataFailure.message("备份短语版本、数量或标识无效。") }
        func bytes(_ name: String) throws -> Data {
            if let data = files[name] { return data }
            if let existing { return try existing.verifiedData(name) }
            throw DataFailure.message("备份缺少关联的附件或恢复版本。")
        }
        for name in (document.previousRevision.map { [$0] } ?? []) + (document.importedRecoveryRevisions ?? []) {
            guard revisionName(name) else { throw DataFailure.message("备份恢复版本路径无效。") }
            _ = try bytes(name)
        }
        guard (document.importedRecoveryRevisions?.count ?? 0) <= maximumFiles else { throw DataFailure.message("备份恢复版本数量超限。") }
        let groupIDs = Set(document.groups.map(\.id)); var codes = Set<String>(), attachmentBytes = 0, counted = Set<String>()
        for group in document.groups { guard !group.name.isEmpty, group.name.utf8.count <= 4096 else { throw DataFailure.message("备份分组名称无效。") } }
        for snippet in document.snippets {
            guard !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snippet.name.utf8.count <= 4096,
                  snippet.text.utf8.count <= 1_048_576, snippet.groupID.map(groupIDs.contains) ?? true,
                  (snippet.richTextRTF?.utf8.count ?? 0) <= SnippetLibraryStore.maximumAttachmentBytes,
                  (snippet.attachments?.count ?? 0) <= 100, (snippet.fileReferences?.count ?? 0) <= 100,
                  snippet.tags.count <= 100, snippet.tags.allSatisfy({ $0.utf8.count <= 1024 }) else { throw DataFailure.message("备份短语字段或正文超过预算。") }
            if let code = snippet.shortcut, !code.isEmpty { guard code.utf8.count <= 128, !code.contains(where: { $0.isWhitespace }), codes.insert(code.lowercased()).inserted else { throw DataFailure.message("备份存在无效或重复快捷码。") } }
            for reference in snippet.fileReferences ?? [] { guard reference.path.hasPrefix("/"), !reference.path.contains("\0"), reference.path.utf8.count <= 4096, (reference.bookmark?.count ?? 0) <= 1_048_576 else { throw DataFailure.message("备份文件引用无效。") } }
            for attachment in (snippet.attachments ?? []) + (snippet.rtfAttachment.map { [$0] } ?? []) {
                guard attachmentName(attachment.filename), digest(attachment.sha256), attachment.filename == "attachment-\(attachment.sha256).blob",
                      attachment.byteCount >= 0, attachment.byteCount <= SnippetLibraryStore.maximumAttachmentBytes,
                      !attachment.type.isEmpty, attachment.type.utf8.count <= 256, attachment.originalName.utf8.count <= 4096 else { throw DataFailure.message("备份附件记录无效。") }
                let data = try bytes(attachment.filename)
                guard data.count == attachment.byteCount, sha(data) == attachment.sha256 else { throw DataFailure.message("备份附件损坏或内容不匹配。") }
                if counted.insert(attachment.filename).inserted { attachmentBytes += data.count }
                guard attachmentBytes <= SnippetLibraryStore.maximumLibraryAttachmentBytes else { throw DataFailure.message("备份单版附件超过 64 MB。") }
            }
        }
    }

    static func write(files: [String: Data], to destination: URL) throws {
        throw DataFailure.message("本版本已移除原生短语备份写入。")
    }

    private static func directoryFD(_ directory: URL) throws -> Int32 {
        var path = directory.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        guard directory.isFileURL, path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw DataFailure.message("备份目录路径无效。") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw DataFailure.message("无法打开备份目录。") }
        for part in path.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw DataFailure.message("备份目录不可访问或包含符号链接。") }; fd = next
        }
        return fd
    }
}
