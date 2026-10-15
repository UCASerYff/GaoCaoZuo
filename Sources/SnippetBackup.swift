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
        try checkBudget(files)
        for (name, bytes) in files {
            if revisionName(name), name != "revision-\(sha(bytes)).json" { throw DataFailure.message("恢复版本内容与标识不符，未导出。") }
            if attachmentName(name), name != "attachment-\(sha(bytes)).blob" { throw DataFailure.message("附件内容与标识不符，未导出。") }
            if name == "library.json" || revisionName(name) {
                try validateDocumentShape(JSONDecoder().decode(SnippetLibraryDocument.self, from: bytes), supplementalFiles: files, existing: nil)
            }
        }
        guard destination.isFileURL, destination.pathExtension.lowercased() == "gaosnippets" else { throw DataFailure.message("原生备份须保存为新的 .gaosnippets 目录包。") }
        let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let parent = destination.deletingLastPathComponent(), finalName = destination.lastPathComponent
        guard !finalName.isEmpty, !finalName.contains("/"), !finalName.contains("\0") else { throw DataFailure.message("备份名称无效。") }
        let parentFD = try directoryFD(parent); defer { close(parentFD) }
        var parentIdentity = stat(); guard fstat(parentFD, &parentIdentity) == 0 else { throw DataFailure.message("无法核验备份目标目录。") }
        var current = stat()
        guard fstatat(parentFD, finalName, &current, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw DataFailure.message("目标已经存在，原生备份不会覆盖。") }
        let stageName = ".snippet-backup-" + UUID().uuidString, stage = parent.appendingPathComponent(stageName, isDirectory: true)
        guard mkdirat(parentFD, stageName, 0o700) == 0 else { throw DataFailure.message("无法建立备份暂存目录。") }
        let stageFD = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw DataFailure.message("无法绑定备份暂存目录。") }; defer { close(stageFD) }
        var originalStage = stat(); guard fstat(stageFD, &originalStage) == 0 else { throw DataFailure.message("无法核验备份暂存目录。") }
        var created: [(String, dev_t, ino_t)] = [], published = false
        func write(_ data: Data, name: String) throws {
            let fd = openat(stageFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DataFailure.message("无法排他创建备份成员。") }; defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw DataFailure.message("备份成员不是独立普通文件。") }
            created.append((name, info.st_dev, info.st_ino))
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw DataFailure.message("备份写入失败，未提交。") }; offset += count
                }
            }
            guard fsync(fd) == 0 else { throw DataFailure.message("备份同步失败，未提交。") }
        }
        func verify(_ data: Data, name: String) throws {
            let fd = openat(stageFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw DataFailure.message("无法核验备份成员。") }; defer { close(fd) }
            var info = stat(), named = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == data.count,
                  let expected = created.first(where: { $0.0 == name }), info.st_dev == expected.1, info.st_ino == expected.2 else { throw DataFailure.message("备份成员在写入后已变化。") }
            var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024), count = 0
            while true {
                let amount = Darwin.read(fd, &buffer, buffer.count)
                if amount < 0, errno == EINTR { continue }
                guard amount >= 0, amount <= data.count - count else { throw DataFailure.message("备份成员读取超过预算。") }
                if amount == 0 { break }; digest.update(data: Data(buffer.prefix(amount))); count += amount
            }
            guard count == data.count, Data(digest.finalize()) == Data(SHA256.hash(data: data)),
                  fstatat(stageFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0, named.st_dev == info.st_dev, named.st_ino == info.st_ino,
                  named.st_nlink == 1 else { throw DataFailure.message("备份成员摘要或路径核验失败。") }
        }
        defer {
            if !published {
                for (name, device, inode) in created {
                    var info = stat()
                    if fstatat(stageFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device, info.st_ino == inode { _ = unlinkat(stageFD, name, 0) }
                }
                var info = stat()
                if fstatat(parentFD, stageName, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == originalStage.st_dev, info.st_ino == originalStage.st_ino { _ = unlinkat(parentFD, stageName, AT_REMOVEDIR) }
            }
        }
        for (name, data) in files.sorted(by: { $0.key < $1.key }) { try write(data, name: name) }
        let manifest = Manifest(files: files.sorted(by: { $0.key < $1.key }).map { FileRecord(name: $0.key, byteCount: $0.value.count, sha256: sha($0.value)) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= 1_048_576 else { throw DataFailure.message("备份清单超过预算。") }
        try write(manifestData, name: "manifest.json")
        for (name, data) in files { try verify(data, name: name) }; try verify(manifestData, name: "manifest.json"); _ = fsync(stageFD)
        let rechecked = try directoryFD(parent); defer { close(rechecked) }
        var identity = stat(), stageIdentity = stat(), finalIdentity = stat()
        guard fstat(rechecked, &identity) == 0, identity.st_dev == parentIdentity.st_dev, identity.st_ino == parentIdentity.st_ino,
              fstatat(parentFD, stageName, &stageIdentity, AT_SYMLINK_NOFOLLOW) == 0, stageIdentity.st_mode & S_IFMT == S_IFDIR else { throw DataFailure.message("备份目标在提交前已变化，未提交。") }
        guard stageIdentity.st_dev == originalStage.st_dev, stageIdentity.st_ino == originalStage.st_ino,
              Set(try FileManager.default.contentsOfDirectory(atPath: stage.path)) == Set(created.map { $0.0 }) else { throw DataFailure.message("备份暂存目录在提交前已变化，未提交。") }
        guard renameatx_np(parentFD, stageName, parentFD, finalName, UInt32(RENAME_EXCL)) == 0 else { throw DataFailure.message("备份目标已存在或无法原子提交，未覆盖。") }
        published = true; _ = fsync(parentFD)
        guard fstatat(parentFD, finalName, &finalIdentity, AT_SYMLINK_NOFOLLOW) == 0,
              finalIdentity.st_dev == stageIdentity.st_dev, finalIdentity.st_ino == stageIdentity.st_ino else { throw DataFailure.message("备份已提交，但目标随后发生变化；请核对所选目录。") }
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
