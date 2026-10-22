import Foundation
import Combine
import Darwin

enum ArchiveFormat: String, CaseIterable, Identifiable, Codable {
    case zip
    case sevenZip = "7z"
    var id: String { rawValue }
    var title: String { self == .zip ? "ZIP" : "7Z" }
}

struct ArchiveEntry: Identifiable, Hashable {
    let path: String
    let size: UInt64
    let isDirectory: Bool
    let isEncrypted: Bool
    let permissions: UInt16?
    let modifiedAt: Date?
    let symbolicLink: String?
    let hardLink: String?
    var id: String { path }
    init(path: String, size: UInt64, isDirectory: Bool, permissions: UInt16? = nil, modifiedAt: Date? = nil, isEncrypted: Bool = false, symbolicLink:String? = nil, hardLink:String? = nil) {
        self.path = path; self.size = size; self.isDirectory = isDirectory
        self.permissions = permissions; self.modifiedAt = modifiedAt
        self.isEncrypted = isEncrypted; self.symbolicLink=symbolicLink;self.hardLink=hardLink
    }
}

enum ArchiveError: LocalizedError {
    case invalid(String)
    case failed(Int32, String)
    case passwordRequired(incorrect: Bool)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return L10n.text(message)
        case .failed(let code, let detail): return L10n.format("压缩引擎退出码 %d：%@",code,detail)
        case .passwordRequired(let incorrect): return L10n.text(incorrect ? "密码不正确，请重新输入。" : "此压缩包需要密码。")
        case .cancelled: return L10n.text("已取消，原始文件未改变。")
        }
    }
}

/// Extracted bytes stream through the parent into verified paths; the decoder has no filesystem write access.
@MainActor
final class ArchiveService: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double?
    @Published var output = ""
    @Published var lastResultURL: URL?
    private(set) var lastResultReceipts: [FileOperationReceipt] = []
    var volumeEvidence:ArchiveVolumeEvidenceStore?
    private(set) var lastEditBackup:URL?
    var executionScope:ArchiveExecutionScope?
    private var workingTemporaryDirectory:URL {executionScope?.workspaceURL ?? fm.temporaryDirectory}
    private var process: Process?
    private var cancellationRequested = false
    private var jobDeadline = Date.distantFuture
    private var extractionOptions = ArchiveExtractionOptions()
    private var nativeBatchEligible = false
    private let engineOverride: URL?
    private let creationIOObserver: (@Sendable (ArchiveCreationIO.Phase) -> Void)?
    private var creationCancellation: ArchiveCreationIO.Cancellation?
    private let fm = FileManager.default
    nonisolated static let maximumExpandedBytes: UInt64 = 20 * 1024 * 1024 * 1024
    nonisolated static let maximumEntries = 100_000

    init(engineURL: URL? = nil, creationIOObserver: (@Sendable (ArchiveCreationIO.Phase) -> Void)? = nil) {
        self.engineOverride = engineURL; self.creationIOObserver = creationIOObserver
    }

    func cancel() {
        cancellationRequested = true
        creationCancellation?.cancel()
        guard let process, process.isRunning else { return }
        process.interrupt()
        Task { @MainActor [weak process] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Serialized queue-side file planning/disposal shares the same cancellation
    /// signal as compression. No later job can run while its worker is pending.
    func performFileIO<T>(_ body: @escaping @Sendable (ArchiveCreationIO.Cancellation) throws -> T) async throws -> T {
        guard !isRunning else { throw ArchiveError.invalid("已有压缩任务正在运行，请等待或取消。") }
        let cancellation = ArchiveCreationIO.Cancellation(deadline: Date().addingTimeInterval(Double(ArchiveExtractionOptions().maximumMinutes * 60)))
        creationCancellation = cancellation; cancellationRequested = false; isRunning = true
        defer { creationCancellation = nil; isRunning = false }
        return try await ArchiveFileIO.perform { try cancellation.check(); return try body(cancellation) }
    }

    /// destination is the exact output filename. Split archives return the first (.001) volume.
    func create(items: [URL], destination: URL, format: ArchiveFormat, password: String?, splitMB: Int?, solid: Bool, options: ArchiveCreationOptions = .init()) async throws -> URL {
        try begin()
        defer { finish() }
        guard !items.isEmpty else { throw ArchiveError.invalid("请先选择需要压缩的文件。") }
        try validatePassword(password)
        try options.validate()
        if let splitMB, !(1...1_048_576).contains(splitMB) { throw ArchiveError.invalid("分卷大小须为 1–1048576 MB。") }
        guard format == .sevenZip || !solid else { throw ArchiveError.invalid("固实压缩仅适用于 7Z。") }
        var sourceNames: Set<String> = []
        for source in items {
            let key = source.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            guard sourceNames.insert(key).inserted else { throw FileToolsError.conflict(source) }
        }
        let cancellation = ArchiveCreationIO.Cancellation(deadline: jobDeadline)
        creationCancellation = cancellation
        defer { creationCancellation = nil }
        let observer = creationIOObserver
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-stage-" + UUID().uuidString, isDirectory: true)
        let input = stage.appendingPathComponent("input", isDirectory: true)
        let packed = stage.appendingPathComponent("packed", isDirectory: true)
        output = L10n.text("正在核验并准备文件…")+"\n"
        do {
            let hasMacMetadata = try await ArchiveFileIO.perform {
                observer?(.preparing)
                try cancellation.check()
                return try ArchiveCreationIO.prepare(items: items, destination: destination, stage: stage, options: options, cancellation: cancellation)
            }
            try checkCancellation()
            let packedURL = packed.appendingPathComponent(destination.lastPathComponent)
            var args = ["a", "-t\(format.rawValue)", "-mx=\(options.level.rawValue)", options.threads == 0 ? "-mmt=on" : "-mmt=\(options.threads)", "-y", "-spd", "-snl"]
            args += options.ignoredPatterns.map { "-xr!" + $0 }
            if format == .sevenZip { args.append(solid ? "-ms=on" : "-ms=off") }
            if let password, !password.isEmpty {
                args.append("-p")
                args.append(format == .sevenZip ? (options.encryptFileNames ? "-mhe=on" : "-mhe=off") : "-mem=AES256")
            }
            if let splitMB { args.append("-v\(splitMB)m") }
            args += ["--", packedURL.path] + items.map(\.lastPathComponent) + (hasMacMetadata ? ["__MACOSX"] : [])
            _ = try await run(args, currentDirectory: input, password: password, writeRoot: packed)
            let first = splitMB == nil ? packedURL : packedURL.appendingPathExtension("001")
            let volumes = try await ArchiveFileIO.perform {
                try cancellation.check()
                let values = try FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !values.isEmpty else { throw ArchiveError.invalid("压缩引擎没有生成结果。") }
                var info = stat()
                guard lstat(first.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                guard info.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.invalid("缺少压缩结果或首个分卷。") }
                return values
            }
            try checkCancellation()
            output += "\n"+L10n.text("正在验证压缩包完整性…")+"\n"
            _ = try await run(["t", "-y"] + passwordArguments(password) + ["--", first.path], password: password, writeRoot: stage)
            try checkCancellation()
            let targets = volumes.map { destination.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }
            // Fingerprint isolated results before publishing any path the user can start editing.
            let receipts = try await ArchiveFileIO.perform {
                try zip(volumes, targets).map { source, target in
                    try cancellation.check()
                    try ArchiveFileIO.requireAbsent(target)
                    return FileOperationReceipt(kind: .create, destination: target, fingerprint: try FileTools.fingerprint(source))
                }
            }
            try checkCancellation()
            try await ArchiveFileIO.perform {
                observer?(.publishing)
                try cancellation.check()
                try ArchiveCreationIO.publish(volumes: volumes, targets: targets, receipts: receipts, cancellation: cancellation)
            }
            // A fully committed result keeps its receipt even if cancellation arrives
            // after the final move; never claim it disappeared or dispose its originals.
            let result = destination.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent)
            lastResultReceipts = receipts
            lastResultURL = result; progress = 1; output += "\n"+L10n.text("压缩完成，完整性验证通过。")
            if splitMB != nil,let volumeEvidence {
                do {try await ArchiveFileIO.perform {try volumeEvidence.recordCreated(first:result,format:format.rawValue,receipts:receipts)}}
                catch {output += "\n"+L10n.text("分卷创建证据未保存；结果保留，自动处理原卷不可用。")}
            }
            if let warning = await ArchiveFileIO.removeStage(stage) { output += "\n"+L10n.format("暂存目录未能完全清理，已保留以便复核：%@\n%@",stage.path,warning) }
            return result
        } catch {
            // Await cleanup before releasing isRunning or letting the queue start
            // another job. Cancellation cannot abandon a still-running I/O worker.
            if let warning = await ArchiveFileIO.removeStage(stage) { output += "\n"+L10n.format("暂存目录未能完全清理，已保留以便复核：%@\n%@",stage.path,warning) }
            throw error
        }
    }

    func list(archive: URL, password: String?, options: ArchiveExtractionOptions = .init()) async throws -> [ArchiveEntry] {
        try begin(options:options); defer { finish() }
        try validatePassword(password)
        let opened = try await openedContainer(archive:archive,password:password)
        defer { opened.temporaryRoots.forEach { try? fm.removeItem(at:$0) } }
        let entries = try await checkedEntries(archive: opened.url, password: password)
        output = L10n.format("已读取 %ld 个项目，路径与容量预检通过。",entries.count)
        progress = 1
        return entries
    }

    /// Publish each top-level item into an existing directory only after the whole archive is verified.
    /// Existing names (including dangling links) are never merged or overwritten.
    func extractIntoDirectory(archive: URL, to directory: URL, password: String?, selected: [String]? = nil,
                              options: ArchiveExtractionOptions = .init()) async throws -> [URL] {
        try requireDirectory(directory)
        let temporary = directory.appendingPathComponent(".gaocaozuo-expand-" + UUID().uuidString, isDirectory: true)
        return try await extractTransaction(archive: archive, to: temporary, password: password, selected: selected,
                                            options: options, publishingChildrenInto: directory).outputs
    }

    /// Editing is rebuilt and verified in isolation. Saving over the original always creates a verified backup.
    func edit(archive: URL, password: String?, adding: [URL], removing: [String], removeHidden: Bool,
              saveTo destination: URL, backupDirectory: URL, options: ArchiveCreationOptions = .init(),
              extraction: ArchiveExtractionOptions = .init(),originalValidation:(()throws->Void)? = nil,preserveEncryption:Bool=false) async throws -> (result: URL, backup: URL?) {
        lastEditBackup=nil
        try originalValidation?()
        guard ["zip", "7z"].contains(archive.pathExtension.lowercased()) else {
            throw ArchiveError.invalid("仅 ZIP 与 7Z 支持重新保存；其他格式可提取后新建 ZIP/7Z。")
        }
        let before = try await performFileIO { cancellation in try cancellation.check(); return try FileTools.fingerprint(archive) }
        let root = try makeStage(in: workingTemporaryDirectory)
        defer { try? fm.removeItem(at: root) }
        let tree = root.appendingPathComponent("contents", isDirectory: true)
        _ = try await extract(archive: archive, to: tree, password: password, selected: nil, options: extraction)
        let listed = try ArchiveMacMetadata.allURLs(in: tree).map { String($0.path.dropFirst(tree.path.count + 1)) }
        for path in removing { try Self.validateArchivePath(path); guard listed.contains(path) else { throw ArchiveError.invalid("待删除项目已不在压缩包中。") } }
        var deletions = Set(removing)
        if removeHidden { deletions.formUnion(listed.filter { $0.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) }) }
        for path in deletions.sorted(by: { $0.count < $1.count }) {
            let url = tree.appendingPathComponent(path)
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        }
        for source in adding {
            let target = tree.appendingPathComponent(source.lastPathComponent)
            try requireAbsent(target)
            let hash = try FileTools.archiveFingerprint(source)
            try fm.copyItem(at: source, to: target)
            guard try FileTools.archiveFingerprint(target) == hash, try FileTools.archiveFingerprint(source) == hash else { throw ArchiveError.invalid("新增文件在复制期间发生变化。") }
        }
        let children = try ArchiveMacMetadata.allURLs(in: tree).filter { $0.deletingLastPathComponent().standardizedFileURL == tree.standardizedFileURL }
        guard !children.isEmpty else { throw ArchiveError.invalid("编辑会产生空压缩包，请保留至少一个项目。") }
        let format: ArchiveFormat = archive.pathExtension.lowercased() == "7z" ? .sevenZip : .zip
        let rebuilt = root.appendingPathComponent("edited." + format.rawValue)
        _ = try await create(items: children, destination: rebuilt, format: format, password: password, splitMB: nil, solid: false, options: options)
        if preserveEncryption {
            let candidateEntries=try await list(archive:rebuilt,password:password,options:extraction)
            guard !candidateEntries.isEmpty,candidateEntries.filter({!$0.isDirectory}).allSatisfy(\.isEncrypted) else {throw ArchiveError.invalid("编辑结果未保留加密；原压缩包未修改。")}
        }
        // Internal rebuilt files disappear with this edit workspace. They must
        // never escape as recovery receipts if final destination publication fails.
        lastResultReceipts = []; lastResultURL = nil
        if destination.standardizedFileURL == archive.standardizedFileURL,
           let mode = try fm.attributesOfItem(atPath: archive.path)[.posixPermissions] {
            // Editing must not turn a private 0600 archive into a world-readable default file.
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: rebuilt.path)
        }
        let hash = try FileTools.fingerprint(rebuilt)
        guard try FileTools.fingerprint(archive) == before else { throw FileToolsError.changed(archive) }
        var backup: URL?
        if destination.standardizedFileURL == archive.standardizedFileURL {
            try originalValidation?()
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let saved = backupDirectory.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
            try fm.copyItem(at: archive, to: saved)
            guard try FileTools.fingerprint(saved) == before, try FileTools.fingerprint(archive) == before else { throw FileToolsError.changed(archive) }
            backup = saved
            lastEditBackup=saved
            // Rebuild is on a potentially different volume; copy beside original before atomic replacement.
            let candidate = archive.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-edit-" + UUID().uuidString)
            defer { try? fm.removeItem(at: candidate) }
            try fm.copyItem(at: rebuilt, to: candidate)
            guard try FileTools.fingerprint(candidate) == hash, try FileTools.fingerprint(archive) == before else { throw FileToolsError.changed(archive) }
            try checkCancellation();try originalValidation?()
            _ = try fm.replaceItemAt(archive, withItemAt: candidate, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            // Build beside the final destination, then publish one verified file
            // with the same exclusive atomic rename used by extraction. A copy
            // directly to destination exposes partial bytes and leaves a partial
            // result on ENOSPC or cancellation.
            let cancellation = ArchiveCreationIO.Cancellation(deadline: jobDeadline)
            creationCancellation = cancellation; isRunning = true
            defer { creationCancellation = nil; isRunning = false }
            let finalStage = try await ArchiveFileIO.perform {
                try cancellation.check()
                try ArchiveFileIO.requireDirectory(destination.deletingLastPathComponent())
                try ArchiveFileIO.requireAbsent(destination)
                let value = destination.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-stage-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return value
            }
            do {
                let observer = creationIOObserver
                try await ArchiveFileIO.perform {
                    let candidate = finalStage.appendingPathComponent("edited." + format.rawValue)
                    try cancellation.check()
                    try FileManager.default.copyItem(at: rebuilt, to: candidate)
                    guard try FileTools.fingerprint(candidate) == hash, try FileTools.fingerprint(archive) == before else { throw FileToolsError.changed(archive) }
                    observer?(.publishing)
                    try ArchiveCreationIO.publish(volumes: [candidate], targets: [destination], receipts: [.init(kind: .create, destination: destination, fingerprint: hash)], cancellation: cancellation)
                }
                if let warning = await ArchiveFileIO.removeStage(finalStage) { output += "\n" + warning }
            } catch {
                if let warning = await ArchiveFileIO.removeStage(finalStage) { output += "\n" + warning }
                throw error
            }
        }
        guard try FileTools.fingerprint(destination) == hash else { throw ArchiveError.invalid("保存结果核验失败；原包安全备份已保留。") }
        lastResultURL = destination
        lastResultReceipts = backup == nil ? [.init(kind: .create, destination: destination, fingerprint: hash)] : []
        return (destination, backup)
    }

    /// to is a NEW directory. Existing directories are refused, including an empty one.
    func extract(archive originalArchive: URL, to destination: URL, password: String?, selected: [String]?, options: ArchiveExtractionOptions = .init()) async throws -> URL {
        try await extractTransaction(archive: originalArchive, to: destination, password: password, selected: selected,
                                     options: options, publishingChildrenInto: nil).root
    }

    private func extractTransaction(archive originalArchive: URL, to destination: URL, password: String?, selected: [String]?,
                                    options: ArchiveExtractionOptions, publishingChildrenInto directory: URL?) async throws -> (root: URL, outputs: [URL]) {
        try begin(options:options); defer { finish() }
        try validatePassword(password)
        try requireDirectory(destination.deletingLastPathComponent())
        try requireAbsent(destination)
        let opened = try await openedContainer(archive:originalArchive,password:password)
        defer { opened.temporaryRoots.forEach { try? fm.removeItem(at:$0) } }
        let cancellation = ArchiveCreationIO.Cancellation(deadline: jobDeadline)
        creationCancellation = cancellation
        defer { creationCancellation = nil }
        let stage = try await ArchiveFileIO.perform { try self.makeExtractionStage(in: destination.deletingLastPathComponent()) }
        do {
        // A batch decoder opens only a verified job-local snapshot. Split volumes
        // and other formats retain the existing per-member backend path.
        let extensionName = opened.url.pathExtension.lowercased()
        let snapshot: ArchiveReadSnapshot?
        if ["zip", "7z"].contains(extensionName) || ArchiveReadSnapshot.isNumericSplit(opened.url) {
            snapshot = try await ArchiveFileIO.perform {
                try ArchiveReadSnapshot.capture(opened.url, in: stage.appendingPathComponent("container"), maximumBytes: options.maximumBytes, cancellation: cancellation)
            }
        } else { snapshot = nil }
        let archive = snapshot?.url ?? opened.url
        let entries = try await checkedEntries(archive: archive, password: password)
        let selected = try validateSelection(selected, entries: entries)
        let expected = entries.filter { entry in selected == nil || selected!.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) }
        if password?.isEmpty != false, expected.contains(where: { $0.isEncrypted }) {
            throw ArchiveError.passwordRequired(incorrect: false)
        }
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        output = L10n.text("路径与容量预检通过，正在隔离解压…")+"\n"
        try Self.validateLinks(expected)
        let files = expected.filter { !$0.isDirectory && $0.symbolicLink == nil && $0.hardLink == nil }
        try await ArchiveFileIO.perform {
            try cancellation.check()
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for entry in expected where entry.isDirectory {
                try cancellation.check()
                try FileManager.default.createDirectory(at: payload.appendingPathComponent(entry.path, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        let batchData: Data? = try await ArchiveFileIO.perform {
            try cancellation.check()
            guard !files.isEmpty, files.count <= 100_000 else { return nil }
            var pathBytes = 0
            for entry in files {
                pathBytes += entry.path.utf8.count + 64
                guard pathBytes <= 8 * 1_024 * 1_024 else { return nil }
            }
            let data = try JSONSerialization.data(withJSONObject: files.map { ["path": $0.path, "size": $0.size] as [String: Any] })
            return data.count <= 16 * 1_024 * 1_024 ? data : nil
        }
        let batchAllowed = snapshot != nil && batchData != nil &&
            (extensionName == "zip" || (extensionName == "7z" && nativeBatchEligible && password?.isEmpty != false))
        if batchAllowed {
            let writer = try ArchiveBatchStream(root: payload, entries: files)
            _ = try await run(["b", "--", archive.path], password: password, batchWriter: writer, batchRequest: batchData)
            try writer.finish()
        } else { for (index, entry) in files.enumerated() {
            try checkCancellation()
            let result = payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            output += "\n"+L10n.format("正在提取 %ld/%ld：%@",index+1,files.count,entry.path)+"\n"
            _ = try await run(["x", "-so", "-y", "-spd"] + passwordArguments(password) + ["--", archive.path, entry.path], password: password, streamTo: result, expectedBytes: entry.size)
            progress = Double(index + 1) / Double(max(1, files.count))
        } }
        try checkCancellation()
        try await ArchiveFileIO.perform {
        let fm = FileManager.default
        try cancellation.check()
        for entry in expected where entry.hardLink != nil {
            let target=try Self.resolvedLink(entry.hardLink!,from:entry.path,hard:true)
            let result=payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at:result.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // Both paths were validated inside our private staging tree. Links are
            // created before symbolic links, so no archive-controlled ancestor can redirect them.
            let rootFD = open(payload.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(rootFD) }
            var identity = stat()
            guard fstatat(rootFD, target, &identity, AT_SYMLINK_NOFOLLOW) == 0,
                  identity.st_mode & S_IFMT == S_IFREG,
                  linkat(rootFD, target, rootFD, entry.path, 0) == 0 else {
                throw ArchiveError.invalid("无法在安全输出目录内保留硬链接；未提交结果。")
            }
        }
        for entry in expected where entry.symbolicLink != nil {
            let result=payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at:result.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try fm.createSymbolicLink(atPath:result.path,withDestinationPath:entry.symbolicLink!)
        }
        try Self.verifyExtractedTree(payload, expected: expected)
        try ArchiveMacMetadata.restore(in: payload)
        }
        let publication = try await ArchiveFileIO.perform { () -> (sources: [URL], targets: [URL], receipts: [FileOperationReceipt]) in
            try cancellation.check()
            // Top-level publication computes each recovery fingerprint once. It
            // does not first hash the whole tree and then hash every child again.
            let sources = try directory == nil ? [payload] : FileTools.directoryChildren(payload).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let targets = directory.map { parent in sources.map { parent.appendingPathComponent($0.lastPathComponent) } } ?? [destination]
            let receipts = try zip(sources, targets).map { source, target in
                try cancellation.check()
                try ArchiveFileIO.requireAbsent(target)
                return FileOperationReceipt(kind: .create, destination: target, fingerprint: try FileTools.archiveFingerprint(source))
            }
            // Do the final original-source check after output hashing, directly
            // before publication planning leaves the protected worker.
            try snapshot?.verify()
            return (sources, targets, receipts)
        }
        try checkCancellation()
        try await ArchiveFileIO.perform {
            try ArchiveCreationIO.publish(volumes: publication.sources, targets: publication.targets, receipts: publication.receipts, cancellation: cancellation)
        }
        lastResultReceipts = publication.receipts
        lastResultURL = directory == nil ? destination : publication.targets.first
        progress = 1; output += "\n"+L10n.text("解压完成，结果已核验并保存到新目录。")
        if let warning = await ArchiveFileIO.removeStage(stage) { output += "\n"+L10n.format("暂存目录未能完全清理，已保留以便复核：%@\n%@",stage.path,warning) }
        return (destination, publication.targets)
        } catch {
            if let warning = await ArchiveFileIO.removeStage(stage) { output += "\n"+L10n.format("暂存目录未能完全清理，已保留以便复核：%@\n%@",stage.path,warning) }
            throw error
        }
    }

    private nonisolated func makeExtractionStage(in parent: URL) throws -> URL {
        let stage = parent.appendingPathComponent(".gaocaozuo-stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }

    private func begin(options:ArchiveExtractionOptions = .init()) throws {
        try options.validate()
        guard !isRunning else { throw ArchiveError.invalid("已有压缩任务正在运行，请等待或取消。") }
        extractionOptions=options; nativeBatchEligible = false
        cancellationRequested = false; isRunning = true; progress = nil; output = ""; lastResultURL = nil; lastResultReceipts = []
        jobDeadline = Date().addingTimeInterval(Double(options.maximumMinutes * 60))
    }
    private func finish() { process = nil; isRunning = false }
    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw ArchiveError.cancelled }
        if Date() > jobDeadline { throw ArchiveError.invalid("任务超过当前设定的安全时间预算。") }
    }
    private func validatePassword(_ password: String?) throws {
        if let password, password.contains("\0") || password.contains("\n") || password.contains("\r") || password.utf8.count > 1024 { throw ArchiveError.invalid("密码过长或含有换行/空字符。") }
    }
    private func passwordArguments(_ password: String?) -> [String] {
        // Passwords enter through a private stdin pipe, never process arguments or the shell.
        []
    }
    private func requireDirectory(_ url: URL) throws {
        guard (try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { throw ArchiveError.invalid(L10n.format("父目录不可用：%@",url.path)) }
    }
    private func requireAbsent(_ url: URL) throws {
        if (try? fm.attributesOfItem(atPath: url.path)) != nil { throw ArchiveError.invalid(L10n.format("目标已存在，未覆盖：%@",url.path)) }
    }
    private func makeStage(in parent: URL) throws -> URL {
        let stage = parent.appendingPathComponent(".gaocaozuo-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
    private func engine() throws -> URL {
        let candidates = [engineOverride, Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz")].compactMap { $0 }
        guard let url = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw ArchiveError.invalid("未找到随应用发布的 7-Zip 引擎，请重新安装完整发行包。")
        }
        return url
    }

    private func checkedEntries(archive: URL, password: String?) async throws -> [ArchiveEntry] {
        guard (try fm.attributesOfItem(atPath: archive.path)[.type] as? FileAttributeType) == .typeRegular else { throw ArchiveError.invalid("请选择普通压缩文件；不接受链接或特殊文件。") }
        let encoding = extractionOptions.filenameEncoding
        let codepages = ["UTF-8":"65001", "GB18030":"54936", "CP932":"932", "CP437":"437", "CP850":"850", "CP1252":"1252"]
        let encodingArgs = codepages[encoding].map { ["-mcp=" + $0] } ?? []
        let listing = try await run(["l", "-slt", "-ba", "-sccUTF-8"] + encodingArgs + passwordArguments(password) + ["--", archive.path], password: password, captureLimit: 64 * 1024 * 1024)
        let analysis = try await ArchiveFileIO.perform { () -> (blocks: [String], links: [(index: Int, path: String, size: UInt64, encrypted: Bool)], native: Bool) in
            let blocks = listing.components(separatedBy: "\n\n")
            var links: [(index: Int, path: String, size: UInt64, encrypted: Bool)] = []
            var native = archive.pathExtension.lowercased() == "7z"
            for (index, block) in blocks.enumerated() {
                var fields: [String: String] = [:]
                for line in block.components(separatedBy: .newlines) {
                    guard let separator = line.range(of: " = ") else { continue }
                    let key = String(line[..<separator.lowerBound])
                    guard fields[key] == nil else { throw ArchiveError.invalid("压缩包目录信息重复。") }
                    fields[key] = String(line[separator.upperBound...])
                }
                let attributes = (fields["Attributes"] ?? "") + " " + (fields["Mode"] ?? "")
                let directory = fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.split(separator: " ").contains { $0.first == "d" }
                if fields["Path"] != nil, !directory {
                    let method = fields["Method"] ?? ""
                    native = native && fields["Encrypted"] != "+" &&
                        (Self.nativeBatchMethodSupported(method) || (fields["Size"] == "0" && method.isEmpty))
                }
                // 7Z stores a symbolic target as bounded member data and omits
                // it from -slt. Capture only the requests here; I/O stays async.
                let mode = (fields["Attributes"] ?? "") + " " + (fields["Mode"] ?? "")
                guard mode.split(separator: " ").contains(where: { $0.first == "l" }), fields["Symbolic Link"]?.isEmpty != false else { continue }
                guard let path = fields["Path"], let size = UInt64(fields["Size"] ?? ""), (1...4_096).contains(size) else { throw ArchiveError.invalid("压缩包链接类型或长度无效。") }
                try Self.validateArchivePath(path)
                links.append((index, path, size, fields["Encrypted"] == "+"))
            }
            return (blocks, links, native)
        }
        nativeBatchEligible = analysis.native
        var blocks = analysis.blocks
        for link in analysis.links {
            guard extractionOptions.allowSafeLinks else { throw ArchiveError.invalid("压缩包链接类型或长度无效。") }
            if link.encrypted, password?.isEmpty != false { throw ArchiveError.passwordRequired(incorrect: false) }
            let stage = try makeStage(in: workingTemporaryDirectory)
            defer { try? fm.removeItem(at: stage) }
            let targetURL = stage.appendingPathComponent("target")
            _ = try await run(["x", "-so", "-y", "-spd"] + passwordArguments(password) + ["--", archive.path, link.path], password: password, streamTo: targetURL, expectedBytes: link.size)
            let data = try Data(contentsOf: targetURL)
            guard UInt64(data.count) == link.size, let target = String(data: data, encoding: .utf8), !target.isEmpty, !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ArchiveError.invalid("压缩包链接目标不是有效路径。") }
            blocks[link.index] += "\nSymbolic Link = " + target
        }
        let options = extractionOptions, parsedBlocks = blocks
        return try await ArchiveFileIO.perform { try Self.parseListing(parsedBlocks.joined(separator: "\n\n"), options: options) }
    }

    /// 7zz prints dictionary sizes using either an exponent or a byte unit.
    /// Reject unknown filter chains and bound the native decoder's dictionary.
    nonisolated static func nativeBatchMethodSupported(_ method: String) -> Bool {
        if method == "Copy" { return true }
        guard method.hasPrefix("LZMA2:") else { return false }
        let token = String(method.dropFirst(6))
        guard !token.isEmpty else { return false }
        let suffix = token.last!
        let value: UInt64
        if ["b", "k", "m"].contains(suffix) {
            guard let number = UInt64(token.dropLast()), number > 0 else { return false }
            let factor: UInt64 = suffix == "m" ? 1_048_576 : suffix == "k" ? 1_024 : 1
            guard number <= 256 * 1_024 * 1_024 / factor else { return false }
            value = number * factor
        } else {
            guard let exponent = UInt64(token), exponent <= 28 else { return false }
            value = UInt64(1) << exponent
        }
        return value <= 256 * 1_024 * 1_024
    }

    private func openedContainer(archive:URL,password:String?) async throws -> (url:URL,temporaryRoots:[URL]) {
        guard extractionOptions.recursiveContainers else{return(archive,[])}
        var current=archive, roots:[URL]=[]
        do {
            for _ in 0..<8 {
                guard ["gz","gzip","tgz","bz2","bzip2","tbz","tbz2","xz","txz","lz","lzip","zst","tzst"].contains(current.pathExtension.lowercased()) else {break}
                let entries=try await checkedEntries(archive:current,password:password)
                guard entries.count == 1,let entry=entries.first,!entry.isDirectory,entry.path.lowercased().hasSuffix(".tar") else {break}
                let root=try makeStage(in:workingTemporaryDirectory);roots.append(root)
                let child=root.appendingPathComponent("contents.tar")
                _=try await run(["x","-so","-y","-spd","--",current.path,entry.path],password:password,streamTo:child,expectedBytes:entry.size)
                current=child
            }
            return(current,roots)
        } catch {roots.forEach{try? fm.removeItem(at:$0)};throw error}
    }

    /// Public to module tests: malformed, ambiguous and link-bearing metadata is rejected.
    nonisolated static func parseListing(_ text: String, options:ArchiveExtractionOptions = .strict) throws -> [ArchiveEntry] {
        try options.validate()
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        var paths = Set<String>()
        var expanded: UInt64 = 0
        // A formatter belongs to this one index parse, never a global/shared
        // cache. Reconstructing its locale/calendar for each small member was
        // a measured CPU bottleneck on large directories.
        let modifiedDateFormatter = DateFormatter()
        modifiedDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        modifiedDateFormatter.calendar = Calendar(identifier: .gregorian)
        modifiedDateFormatter.timeZone = .current
        modifiedDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        modifiedDateFormatter.isLenient = false
        var modifiedDateCache: [String: Date] = [:]
        func flush() throws {
            guard !fields.isEmpty else { return }
            defer { fields.removeAll() }
            // Some 7-Zip versions emit an archive header even with -ba.
            if fields["Type"] != nil, fields["Size"] == nil { return }
            guard let path = fields["Path"], let rawSize = fields["Size"], let size = UInt64(rawSize) else {
                throw ArchiveError.invalid("压缩包目录信息不完整，无法安全解压。")
            }
            try validateArchivePath(path)
            let attributes = (fields["Attributes"] ?? "") + " " + (fields["Mode"] ?? "")
            let nonemptyKeys = fields.filter { !$0.value.isEmpty }.keys.map { $0.lowercased() }
            let symbolic = fields["Symbolic Link"].flatMap { $0.isEmpty ? nil : $0 }
            let hard = fields["Hard Link"].flatMap { $0.isEmpty ? nil : $0 }
            let unknownLink = nonemptyKeys.contains { ($0.contains("link") && $0 != "symbolic link" && $0 != "hard link" && $0 != "links") }
            // 7zz's CPIO "Links" field is a numeric link count, not a target.
            // It never authorizes a filesystem link; only explicit validated Hard Link does.
            if let count = fields["Links"], !count.isEmpty {
                guard let value = UInt64(count), value > 0, value <= UInt64(options.maximumEntries) else { throw ArchiveError.invalid("压缩包链接计数无效。") }
            }
            let special = attributes.split(separator:" ").contains { ["b","c","p","s"].contains($0.first.map(String.init) ?? "") }
            let modeLink = attributes.split(separator:" ").contains { $0.first == "l" }
            guard !special, !unknownLink, !(symbolic != nil && hard != nil), !modeLink || symbolic != nil else {throw ArchiveError.invalid("压缩包含有不支持的特殊文件或链接元数据。")}
            if !options.allowSafeLinks && (symbolic != nil || hard != nil) {throw ArchiveError.invalid("压缩包含有链接；当前解压设置不允许链接。")}
            let directory = fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.split(separator: " ").contains(where: { $0.first == "d" }) || path.hasSuffix("/")
            let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
            let comparison = clean.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(comparison).inserted else { throw ArchiveError.invalid(L10n.format("压缩包含有重名或大小写冲突项目：%@",clean)) }
            guard size <= options.maximumBytes, expanded <= options.maximumBytes - size else { throw ArchiveError.invalid(L10n.format("压缩包展开内容超过当前 %ld GiB 安全预算。",options.maximumExpandedGiB)) }
            expanded += size
            let modified: Date?
            if let raw = fields["Modified"], let cached = modifiedDateCache[raw] { modified = cached }
            else {
                modified = parseModifiedDate(fields["Modified"], formatter: modifiedDateFormatter)
                if let raw = fields["Modified"], let modified, modifiedDateCache.count < 4_096 { modifiedDateCache[raw] = modified }
            }
            entries.append(.init(path: clean, size: size, isDirectory: directory,
                                 permissions: parsePermissions(attributes), modifiedAt: modified,
                                 isEncrypted: fields["Encrypted"] == "+",symbolicLink:symbolic,hardLink:hard))
            guard entries.count <= options.maximumEntries else { throw ArchiveError.invalid(L10n.format("压缩包超过当前 %ld 个项目的安全预算。",options.maximumEntries)) }
        }
        for line in text.components(separatedBy: .newlines) {
            if line == "Enter password:" { continue }
            if line.isEmpty { try flush(); continue }
            if line.allSatisfy({ $0 == "-" }) { try flush(); continue }
            guard let separator = line.range(of: " = ") else {
                // In -ba technical output each nonempty line must be a key/value pair.
                throw ArchiveError.invalid("压缩包包含无法安全识别的文件名或目录元数据。")
            }
            let key = String(line[..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            guard fields[key] == nil else { throw ArchiveError.invalid("压缩包目录信息重复，无法安全解压。") }
            fields[key] = value
        }
        try flush()
        // No regular file may also be the parent directory of another item.
        let files = Set(entries.filter { !$0.isDirectory }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
        for entry in entries {
            var components = entry.path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard !files.contains(components.joined(separator: "/")) else { throw ArchiveError.invalid("压缩包内文件和目录路径发生冲突。") }
            }
        }
        try validateLinks(entries)
        // Conservatively budget logical bytes for each hard-link directory entry.
        let lookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var actualExpanded: UInt64 = 0
        for entry in entries where !entry.isDirectory {
            let amount: UInt64
            if let target = entry.hardLink { amount = lookup[try resolvedLink(target, from: entry.path, hard: true)]?.size ?? entry.size }
            else { amount = entry.size }
            guard amount <= options.maximumBytes, actualExpanded <= options.maximumBytes - amount else { throw ArchiveError.invalid("解压内容（含硬链接逻辑大小）超过当前容量预算。") }
            actualExpanded += amount
        }
        return entries
    }

    nonisolated static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveError.invalid(L10n.format("压缩包含有危险路径：%@",String(path.prefix(120))))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("."), !parts.dropLast().contains(""), parts.allSatisfy({ $0.utf8.count <= 255 }) else { throw ArchiveError.invalid("压缩包含有越界或异常路径。") }
    }

    nonisolated static func resolvedLink(_ target:String, from path:String, hard:Bool) throws -> String {
        guard !target.isEmpty,!target.hasPrefix("/"),!target.contains("\\"),!target.contains(":"),!target.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw ArchiveError.invalid("压缩包含有绝对或非法链接。")}
        var parts = hard ? [] : path.split(separator:"/").dropLast().map(String.init)
        for part in target.split(separator:"/") {
            if part == "." {continue}
            if part == ".." {guard !parts.isEmpty else {throw ArchiveError.invalid("压缩包链接指向解压目录之外。")};parts.removeLast()}
            else {parts.append(String(part))}
        }
        return parts.joined(separator:"/")
    }
    nonisolated static func validateLinks(_ entries:[ArchiveEntry]) throws {
        let lookup=Dictionary(uniqueKeysWithValues:entries.map{($0.path,$0)})
        var directories=Set([""])
        for e in entries {var c=e.path.split(separator:"/").map(String.init);if e.isDirectory{directories.insert(e.path)};while c.count>1{c.removeLast();directories.insert(c.joined(separator:"/"))}}
        for entry in entries where entry.symbolicLink != nil || entry.hardLink != nil {
            var seen=Set([entry.path]), current=entry
            for _ in 0...entries.count {
                guard let target=current.symbolicLink ?? current.hardLink else {break}
                let resolved=try resolvedLink(target,from:current.path,hard:current.hardLink != nil)
                guard seen.insert(resolved).inserted else {throw ArchiveError.invalid("压缩包包含循环链接。")}
                if let next=lookup[resolved] {
                    if entry.hardLink != nil && (next.isDirectory || next.symbolicLink != nil || next.hardLink != nil) {throw ArchiveError.invalid("硬链接目标必须是包内普通文件。")}
                    current=next
                } else if directories.contains(resolved), entry.hardLink == nil {break}
                else {throw ArchiveError.invalid("链接目标不存在或未包含在所选内容中。")}
            }
        }
    }

    /// Only rwx bits are retained. Lowercase s/t includes an executable bit but never its special-ID bit.
    nonisolated static func parsePermissions(_ attributes: String) -> UInt16? {
        guard let token = attributes.split(separator: " ").first(where: {
            $0.count == 10 && ($0.first == "-" || $0.first == "d")
        }) else { return nil }
        let characters = Array(token.dropFirst())
        var mode: UInt16 = 0
        for index in 0..<9 {
            let character = characters[index]
            switch index % 3 {
            case 0:
                guard character == "r" || character == "-" else { return nil }
                if character == "r" { mode |= UInt16(1 << (8 - index)) }
            case 1:
                guard character == "w" || character == "-" else { return nil }
                if character == "w" { mode |= UInt16(1 << (8 - index)) }
            default:
                guard ["x", "-", "s", "S", "t", "T"].contains(character) else { return nil }
                if ["x", "s", "t"].contains(character) { mode |= UInt16(1 << (8 - index)) }
            }
        }
        return mode & 0o777
    }

    private nonisolated static func parseModifiedDate(_ raw: String?, formatter: DateFormatter) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard let date = formatter.date(from: parts[0]) else { return nil }
        if parts.count == 2, parts[1].allSatisfy(\.isNumber), let fraction = Double("0." + parts[1]) { return date.addingTimeInterval(fraction) }
        return date
    }

    private func validateSelection(_ selection: [String]?, entries: [ArchiveEntry]) throws -> [String]? {
        guard let selection else { return nil }
        guard !selection.isEmpty else { throw ArchiveError.invalid("请选择至少一个压缩包内的项目。") }
        let available = Set(entries.map(\.path))
        for path in selection {
            try Self.validateArchivePath(path)
            guard available.contains(path) || entries.contains(where: { $0.path.hasPrefix(path + "/") }) else { throw ArchiveError.invalid(L10n.format("选中项目不在已核验目录中：%@",path)) }
        }
        return Array(Set(selection)).sorted()
    }

    nonisolated static func verifyExtractedTree(_ root: URL, expected: [ArchiveEntry]) throws {
        let fm = FileManager.default
        let root = try FileTools.canonicalURL(root)
        var allowed: [String: ArchiveEntry] = Dictionary(uniqueKeysWithValues: expected.map { ($0.path, $0) })
        for entry in expected {
            var components = entry.path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast(); let path = components.joined(separator: "/")
                if allowed[path] == nil { allowed[path] = .init(path: path, size: 0, isDirectory: true) }
            }
        }
        // Exact inode groups must match declared links, with no additional names
        // outside this isolated root. Equal bytes alone do not prove a hard link.
        var hardLinkGroups: [String: Set<String>] = [:]
        for entry in expected where entry.hardLink != nil {
            let target = try resolvedLink(entry.hardLink!, from: entry.path, hard: true)
            hardLinkGroups[target, default: [target]].insert(entry.path)
        }
        var groupForPath: [String: Set<String>] = [:]
        for (target, members) in hardLinkGroups {
            var targetInfo = stat()
            guard lstat(root.appendingPathComponent(target).path, &targetInfo) == 0,
                  targetInfo.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.invalid("硬链接目标不再是普通文件。") }
            for path in members {
                var info = stat()
                guard lstat(root.appendingPathComponent(path).path, &info) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      info.st_dev == targetInfo.st_dev, info.st_ino == targetInfo.st_ino,
                      info.st_nlink == members.count else { throw ArchiveError.invalid("硬链接身份或输出根内引用数量不符。") }
                groupForPath[path] = members
            }
        }
        var seen = Set<String>()
        for url in try ArchiveMacMetadata.allURLs(in: root) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard let entry = allowed[relative] else { throw ArchiveError.invalid(L10n.format("解压结果含有目录清单之外的项目：%@",relative)) }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if let target=entry.symbolicLink {
                guard type == .typeSymbolicLink,try fm.destinationOfSymbolicLink(atPath:url.path) == target else {throw ArchiveError.invalid("解压链接核验失败。")}
                seen.insert(relative);continue
            }
            guard (entry.isDirectory && type == .typeDirectory) || (!entry.isDirectory && type == .typeRegular) else { throw ArchiveError.invalid("解压结果包含链接、特殊文件或类型不一致项目。") }
            if !entry.isDirectory {
                let expectedSize:UInt64
                if let link=entry.hardLink,let target=allowed[try resolvedLink(link,from:entry.path,hard:true)] {expectedSize=target.size} else {expectedSize=entry.size}
                guard (attributes[.size] as? NSNumber)?.uint64Value == expectedSize,
                      (attributes[.referenceCount] as? NSNumber)?.intValue == (groupForPath[relative]?.count ?? 1) else { throw ArchiveError.invalid("解压结果大小或硬链接数量不符。") }
            }
            seen.insert(relative)
        }
        guard expected.allSatisfy({ seen.contains($0.path) }) else { throw ArchiveError.invalid(L10n.format("解压结果不完整，未保存到目标目录：%@",expected.filter { !seen.contains($0.path) }.prefix(5).map(\.path).joined(separator: "、"))) }
        // Apply metadata only after all bytes/types/paths verify. Descendants first preserves directory mtimes.
        for entry in allowed.values.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
            if entry.symbolicLink != nil || entry.hardLink != nil {continue}
            let url = root.appendingPathComponent(entry.path)
            // Keep the owner able to verify/read results without making read-only archives writable.
            // Never restore setuid/setgid/sticky bits or another user's ownership.
            let ownerAccess: UInt16 = entry.isDirectory ? 0o500 : 0o400
            let safeMode = ((entry.permissions ?? ownerAccess) & 0o777) | ownerAccess
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(safeMode)]
            if let modifiedAt = entry.modifiedAt { attributes[.modificationDate] = modifiedAt }
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    private func run(_ arguments: [String], currentDirectory: URL? = nil, password: String?, writeRoot: URL? = nil,
                     expansionMonitor: URL? = nil, captureLimit: Int = 2 * 1024 * 1024,
                     streamTo: URL? = nil, expectedBytes: UInt64? = nil,
                     batchWriter: ArchiveBatchStream? = nil, batchRequest: Data? = nil) async throws -> String {
        try checkCancellation()
        let engineURL = try engine()
        let marker = arguments.firstIndex(of:"--")
        let archivePath = marker.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
        let lowerPath = archivePath.lowercased()
        let unicodeZIP = password?.unicodeScalars.contains(where: { $0.value >= 128 }) == true && (lowerPath.hasSuffix(".zip") || lowerPath.hasSuffix(".zip.001"))
        let zipRead = arguments.first != "a" && (lowerPath.hasSuffix(".zip") || lowerPath.hasSuffix(".zip.001"))
        let useBridge = arguments.first == "b" || unicodeZIP || zipRead || [".ace", ".lz", ".lzip", ".lzop", ".gz", ".gzip", ".tgz", ".bz2", ".bzip2", ".tbz", ".tbz2", ".xz", ".txz", ".zst", ".tzst"].contains(where:lowerPath.hasSuffix)
        var executable = engineURL
        var prefix: [String] = []
        if useBridge {
            let tools = engineURL.deletingLastPathComponent()
            executable = tools.appendingPathComponent("ArchivePython/python/bin/python3")
            let bridge = tools.appendingPathComponent("ArchiveBridge/archive_bridge.py")
            guard fm.isExecutableFile(atPath:executable.path), fm.fileExists(atPath:bridge.path) else {throw ArchiveError.invalid("扩展压缩引擎不完整，请重新安装完整发行包。")}
            prefix = ["-I", "-B", bridge.path]
        }
        let task = Process()
        var allArguments = arguments
        // User-selected paths may themselves contain wildcard characters. The
        // decoder must open the exact staged archive, never enumerate its
        // ancestors to expand a pattern.
        if !useBridge && !allArguments.contains("-spd") { allArguments.insert("-spd",at:min(1,allArguments.count)) }
        if useBridge { allArguments.insert(contentsOf:["--gao-encoding="+extractionOptions.filenameEncoding,"--gao-limit=\(extractionOptions.maximumBytes)"],at:1) }
        else if arguments.first == "x", extractionOptions.filenameEncoding != "auto" {
            let pages=["UTF-8":"65001","GB18030":"54936","CP932":"932","CP437":"437","CP850":"850","CP1252":"1252"]
            if let page=pages[extractionOptions.filenameEncoding] {allArguments.insert("-mcp="+page,at:1)}
        }
        allArguments.insert(contentsOf: streamTo == nil ? ["-bso1", "-bse1", arguments.first == "l" ? "-bsp0" : "-bsp1"] : ["-bso0", "-bse2", "-bsp2"], at: 1)
        if let scope=executionScope {
            guard fm.isExecutableFile(atPath:"/usr/bin/sandbox-exec") else {throw ArchiveError.invalid("当前系统缺少隔离提取能力；为保护文件，未启动解压。")}
            if arguments.first=="a",let writeRoot {allArguments.insert("-w\(writeRoot.path)",at:1)}
            task.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
            task.arguments=["-p",try scope.profile(writing:arguments.first=="a"),executable.path]+prefix+allArguments
        } else if arguments.first == "a" {
            // Creation only sees previously copied, fingerprint-verified ordinary input files.
            task.executableURL = executable
            if let writeRoot { allArguments.insert("-w\(writeRoot.path)", at: 1) }
            task.arguments = prefix + allArguments
        } else {
            guard fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
                throw ArchiveError.invalid("当前系统缺少隔离提取能力；为保护文件，未启动解压。")
            }
            let profile = "(version 1)(allow default)(deny network*)(deny file-write*)"
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", profile, executable.path] + prefix + allArguments
        }
        task.currentDirectoryURL = currentDirectory
        var environment = executionScope?.environment ?? ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"; environment["LANG"] = "en_US.UTF-8"
        task.environment = environment
        let passwordPipe: Pipe?
        if password?.isEmpty == false || batchRequest != nil {
            let input = Pipe()
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            task.standardInput = input; passwordPipe = input
        } else { task.standardInput = FileHandle.nullDevice; passwordPipe = nil }
        let pipe = Pipe(); task.standardError = pipe
        let streamPipe: Pipe?
        let streamWriter: ArchiveStreamWriter?
        if batchWriter != nil {
            let bytes = Pipe(); task.standardOutput = bytes; streamPipe = bytes; streamWriter = nil
        } else if let streamTo, let expectedBytes {
            let writer = try ArchiveStreamWriter(url: streamTo, limit: expectedBytes)
            let bytes = Pipe(); task.standardOutput = bytes; streamPipe = bytes; streamWriter = writer
        } else { task.standardOutput = pipe; streamPipe = nil; streamWriter = nil }
        let collector = ArchiveOutputCollector(limit: captureLimit)
        process = task
        do { try task.run() } catch {
            streamWriter?.close()
            throw error
        }
        // One serial reader per pipe preserves byte order, including the final chunk after process exit.
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drain.leave() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty { collector.append(chunk) }
            } catch { collector.stopReason = "无法读取压缩引擎输出。"; if task.isRunning { task.interrupt() } }
        }
        if let streamPipe, let streamWriter {
            drain.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drain.leave() }
                do {
                    while let chunk = try streamPipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                        streamWriter.append(chunk)
                        if streamWriter.failure != nil, task.isRunning { task.interrupt() }
                    }
                } catch { collector.stopReason = "无法读取解压数据流。"; if task.isRunning { task.interrupt() } }
            }
        }
        if let streamPipe, let batchWriter {
            drain.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drain.leave() }
                do {
                    while let chunk = try streamPipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                        batchWriter.append(chunk)
                        if batchWriter.failure != nil, task.isRunning { task.interrupt() }
                    }
                } catch { collector.stopReason = "无法读取批量解压数据流。"; if task.isRunning { task.interrupt() } }
            }
        }
        // A finite wall-time budget and periodic disk budget stop malformed/decompression-bomb inputs.
        let baseOutput = output
        let monitor = Task { @MainActor [weak task] in
            let deadline = jobDeadline
            while let task, task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                let snapshot = collector.text
                let safeSnapshot = password?.isEmpty == false ? snapshot.replacingOccurrences(of: password!, with: "••••••") : snapshot
                output = String((baseOutput + safeSnapshot).suffix(24_000))
                if let batchWriter {
                    progress = min(1, max(0, batchWriter.progressValue))
                    output += "\n"+L10n.format("正在提取 %ld/%ld 个文件…",batchWriter.completedCount,batchWriter.entryCount)
                }
                if arguments.first != "l", let regex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#),
                   let match = regex.matches(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)).last,
                   let range = Range(match.range(at: 1), in: snapshot), let value = Double(snapshot[range]) {
                    progress = min(1, max(0, value / 100))
                }
                let budgetExceeded: Bool
                if let root = expansionMonitor { budgetExceeded = await Task.detached(priority: .utility) { Self.exceedsDiskBudget(root) }.value }
                else { budgetExceeded = false }
                if collector.exceeded || Date() > deadline || budgetExceeded || streamWriter?.failure != nil || batchWriter?.failure != nil {
                    collector.stopReason = "任务超过输出、时间或展开容量安全预算。"
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                    return
                }
            }
        }
        if let passwordPipe {
            do {
                try await ArchiveFileIO.perform {
                    defer { try? passwordPipe.fileHandleForWriting.close() }
                    try passwordPipe.fileHandleForWriting.write(contentsOf: Data(((password ?? "") + "\n").utf8))
                    if let batchRequest { try passwordPipe.fileHandleForWriting.write(contentsOf: batchRequest) }
                }
            } catch { collector.stopReason = "无法向压缩引擎提交私有输入。"; if task.isRunning { task.interrupt() } }
        }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    task.waitUntilExit(); drain.wait(); continuation.resume()
                }
            }
        }, onCancel: { if task.isRunning { task.interrupt() } })
        monitor.cancel()
        streamWriter?.close()
        let text = collector.text
        let redacted = (password?.isEmpty == false) ? text.replacingOccurrences(of: password!, with: "••••••") : text
        output = String((baseOutput + redacted).suffix(24_000))
        process = nil
        try checkCancellation()
        if let failure = streamWriter?.failure ?? batchWriter?.failure { throw ArchiveError.invalid(failure) }
        if let reason = collector.stopReason { throw ArchiveError.invalid(reason) }
        guard !collector.exceeded else { throw ArchiveError.invalid("压缩引擎输出超过安全预算。") }
        // Preserve cancellation/budget errors; only explicit engine diagnostics request a password.
        if task.terminationStatus != 0,
           Self.isPasswordDiagnostic(text, exitCode: task.terminationStatus, passwordProvided: password?.isEmpty == false) {
            throw ArchiveError.passwordRequired(incorrect: password?.isEmpty == false)
        }
        guard task.terminationStatus == 0 else { throw ArchiveError.failed(task.terminationStatus, String(redacted.suffix(2000))) }
        return text
    }

    nonisolated static func isPasswordDiagnostic(_ text: String, exitCode: Int32, passwordProvided: Bool) -> Bool {
        // Progress output uses backspaces and can put ERROR immediately after a progress update.
        let lines = text.replacingOccurrences(of: "\u{8}", with: "\n").lowercased()
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let wrongPassword = lines.contains { line in
            line.hasPrefix("error:") && (line.contains("wrong password") || line.contains("password is incorrect")) ||
            line.hasPrefix("errors:") && line.contains("wrong password") ||
            line == "cannot open encrypted archive. wrong password?" ||
            line == "can not open encrypted archive. wrong password?"
        }
        // Header-encrypted archives abort at EOF when no stdin password is available. A prompt
        // alone is insufficient: e.g. unsupported password encoding can produce E_INVALIDARG.
        let missingPassword = !passwordProvided && exitCode == 255 && lines.contains("enter password:") && lines.contains("break signaled")
        return wrongPassword || missingPassword
    }

    private nonisolated static func exceedsDiskBudget(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return true }
        var bytes: UInt64 = 0; var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { return true }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { return true }
            if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                if size > maximumExpandedBytes || bytes > maximumExpandedBytes - size { return true }
                bytes += size
            }
        }
        return false
    }
}

/// File work can wait on folder consent or remote storage. Await the actual
/// worker, including cancellation/cleanup; a timeout is not permission to abandon it.
enum ArchiveFileIO {
    static func perform<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) { try body() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func requireDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw FileToolsError.invalid("目标不是可用文件夹。") }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw FileToolsError.invalid("目标不是可用文件夹。") }
    }
    static func requireAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw FileToolsError.conflict(url) }
        let code = errno
        guard code == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }
    static func moveExclusively(_ source: URL, to target: URL) throws {
        // Private stage and final output share a parent volume. RENAME_EXCL is
        // the final no-overwrite decision; preflight alone cannot close a race.
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw FileToolsError.conflict(target) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
    @discardableResult static func removeStage(_ stage: URL) async -> String? {
        // Cleanup must complete even when the awaiting task has been cancelled.
        await Task.detached(priority: .utility) {
            do { try removePrivateStage(stage); return nil as String? }
            catch { return error.localizedDescription }
        }.value
    }
    private static func removePrivateStage(_ stage: URL) throws {
        guard stage.isFileURL, stage.lastPathComponent.hasPrefix(".gaocaozuo-stage-") else { throw ArchiveError.invalid("暂存清理范围无效。") }
        let parent = open(stage.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(parent) }
        func info(_ fd: Int32, _ name: String) throws -> stat? {
            var value = stat()
            if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == b.st_mode & S_IFMT }
        func removeDirectory(_ fd: Int32, _ name: String, _ expected: stat) throws {
            guard expected.st_uid == geteuid(), expected.st_mode & S_IFMT == S_IFDIR else { throw ArchiveError.invalid("暂存文件夹身份或所有者已改变。") }
            // Only an owned, no-follow directory entry gets temporary owner
            // write access. Read-only archive metadata must not prevent cleanup.
            guard fchmodat(fd, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(child) }
            var bound = stat()
            guard fstat(child, &bound) == 0, same(expected, bound), let path = try info(fd, name), same(bound, path) else { throw ArchiveError.invalid("暂存文件夹在清理前已被替换。") }
            let duplicate = dup(child)
            guard duplicate >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    break
                }
                guard let component = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }) else { throw ArchiveError.invalid("暂存目录含无法无损识别的文件名。") }
                if component == "." || component == ".." { continue }
                guard let value = try info(child, component) else { continue }
                if value.st_mode & S_IFMT == S_IFDIR { try removeDirectory(child, component, value) }
                else {
                    // Symlinks are unlinked themselves; no target is followed.
                    guard unlinkat(child, component, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                }
            }
            guard let current = try info(fd, name), same(bound, current), unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ArchiveError.invalid("暂存根在清理期间已改变，剩余文件已保留。") }
        }
        if let value = try info(parent, stage.lastPathComponent) { try removeDirectory(parent, stage.lastPathComponent, value) }
    }
}

enum ArchiveCreationIO {
    enum Phase: Sendable, Equatable { case preparing, publishing }
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline: Date
        init(deadline: Date) { self.deadline = deadline }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value || Task.isCancelled { throw ArchiveError.cancelled }
            if Date() > deadline { throw ArchiveError.invalid("任务超过当前设定的安全时间预算。") }
        }
    }
    static func prepare(items: [URL], destination: URL, stage: URL, options: ArchiveCreationOptions, cancellation: Cancellation) throws -> Bool {
        let fm = FileManager.default
        try ArchiveFileIO.requireDirectory(destination.deletingLastPathComponent())
        try ArchiveFileIO.requireAbsent(destination)
        try cancellation.check()
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let input = stage.appendingPathComponent("input", isDirectory: true), packed = stage.appendingPathComponent("packed", isDirectory: true)
        try cancellation.check()
        try fm.createDirectory(at: input, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: packed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for source in items {
            try cancellation.check()
            let target = input.appendingPathComponent(source.lastPathComponent)
            try ArchiveFileIO.requireAbsent(target)
            let fingerprint = try FileTools.archiveFingerprint(source)
            try cancellation.check()
            do { try fm.copyItem(at: source, to: target) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { throw FileToolsError.conflict(target) }
            try cancellation.check()
            guard try FileTools.archiveFingerprint(target) == fingerprint, try FileTools.archiveFingerprint(source) == fingerprint else { throw ArchiveError.invalid("待压缩文件在准备期间发生变化。") }
        }
        try cancellation.check()
        let metadata = try ArchiveMacMetadata.prepare(in: input, roots: items.map(\.lastPathComponent), options: options)
        try cancellation.check()
        return metadata
    }
    static func publish(volumes: [URL], targets: [URL], receipts: [FileOperationReceipt], cancellation: Cancellation) throws {
        var committed: [(URL, FileOperationReceipt)] = []
        do {
            for (index, source) in volumes.enumerated() {
                try cancellation.check()
                try ArchiveFileIO.requireAbsent(targets[index])
                try cancellation.check()
                try ArchiveFileIO.moveExclusively(source, to: targets[index])
                committed.append((source, receipts[index]))
            }
        } catch {
            var residual: [FileOperationReceipt] = []
            for (source, receipt) in committed.reversed() {
                do {
                    guard try FileTools.fingerprint(receipt.destination) == receipt.fingerprint else { throw FileToolsError.changed(receipt.destination) }
                    try ArchiveFileIO.moveExclusively(receipt.destination, to: source)
                } catch { residual.append(receipt) }
            }
            if !residual.isEmpty { throw FileToolsPartialFailure(underlyingMessage: error.localizedDescription, receipts: residual.reversed()) }
            throw error
        }
    }
}

private final class ArchiveStreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let limit: UInt64
    private var written: UInt64 = 0
    private var message: String?
    init(url: URL, limit: UInt64) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        self.limit = limit
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard message == nil, !chunk.isEmpty else { return }
        guard UInt64(chunk.count) <= limit - written else {
            message = "实际解压数据超过目录声明大小，已中止并丢弃暂存结果。"; return
        }
        do { try handle.write(contentsOf: chunk); written += UInt64(chunk.count) }
        catch { message = "暂存文件写入失败：\(error.localizedDescription)" }
    }
    func close() { lock.lock(); defer { lock.unlock() }; try? handle.close() }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return message }
}

private final class ArchiveOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    private var reason: String?
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !chunk.isEmpty else { return }
        if data.count + chunk.count > limit { overflow = true }
        data.append(chunk.prefix(max(0, limit - data.count)))
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    var stopReason: String? {
        get { lock.lock(); defer { lock.unlock() }; return reason }
        set { lock.lock(); reason = newValue; lock.unlock() }
    }
}
