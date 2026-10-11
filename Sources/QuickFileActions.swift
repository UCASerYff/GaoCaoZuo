import Foundation
import Darwin

enum QuickNewItemKind: String, CaseIterable {
    case text, markdown, folder
    var filename: String {
        switch self {
        case .text: return "未命名.txt"
        case .markdown: return "未命名.md"
        case .folder: return "新建文件夹"
        }
    }
}

struct QuickExtractionItem: Identifiable {
    enum Status: Equatable {
        case pending
        case needsPassword(incorrect: Bool)
        case completed
        case failed(String)
        case cancelled
    }
    let id: UUID
    let archive: URL
    fileprivate(set) var output: URL?
    fileprivate(set) var receipt: FileOperationReceipt?
    fileprivate(set) var status: Status
}

/// Keep the returned batch when asking for a password, retrying, or resuming cancellation.
/// Passwords are never retained; completed entries are never submitted to the engine again.
struct QuickExtractionBatch: Identifiable {
    let id: UUID
    fileprivate(set) var items: [QuickExtractionItem]
    var outputs: [URL] { items.compactMap(\.output) }
    var isComplete: Bool { items.allSatisfy { $0.status == .completed } }
    var currentItem: QuickExtractionItem? { items.first { $0.status != .completed } }
}

enum QuickFileActions {
    private static let fm = FileManager.default

    /// Chooses a name only, without reserving it. Every writer must still refuse overwrites.
    /// A dangling symlink is an occupied name; unreadable directories are errors, never empty.
    static func uniqueURL(in directory: URL, preferredName: String, isDirectory: Bool = false) throws -> URL {
        try validateDirectory(directory)
        try validateName(preferredName)
        let nameURL = URL(fileURLWithPath: preferredName)
        let ext = isDirectory ? "" : nameURL.pathExtension
        let stem = ext.isEmpty ? preferredName : nameURL.deletingPathExtension().lastPathComponent
        for number in 1...10_000 {
            let suffix = (number == 1 ? "" : " \(number)") + (ext.isEmpty ? "" : "." + ext)
            let name = truncated(stem, byteLimit: 255 - suffix.utf8.count) + suffix
            try validateName(name)
            let candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
            if try isAbsent(candidate) { return candidate }
        }
        throw FileToolsError.invalid("同名项目过多，请更换输出名称。")
    }

    static func create(in directory: URL, kind: QuickNewItemKind) throws -> FileOperationReceipt {
        if kind != .folder { return try createTemplate(in: directory, filename: kind.filename, content: "") }
        // mkdir refuses even an existing empty directory, including a name taken after preflight.
        for _ in 0..<16 {
            let result = try uniqueURL(in: directory, preferredName: kind.filename, isDirectory: true)
            if mkdir(result.path, 0o755) == 0 {
                return .init(kind: .create, destination: result, fingerprint: try FileTools.fingerprint(result))
            }
            let code = errno
            if code != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        throw FileToolsError.invalid("目标目录正在变化，请稍后重试。")
    }

    static func createTemplate(in directory: URL, filename: String, content: String) throws -> FileOperationReceipt {
        for _ in 0..<16 {
            let result = try uniqueURL(in: directory, preferredName: filename)
            do {
                let created = try FileTools.createFile(in: directory, name: result.lastPathComponent, content: content)
                return .init(kind: .create, destination: created, fingerprint: try FileTools.fingerprint(created))
            } catch let error as FileToolsError {
                if case .conflict = error { continue }
                throw error
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw FileToolsError.invalid("目标目录正在变化，请稍后重试。")
    }

    /// Favorite-directory transfers preserve filenames. Conflicts stop; no existing item is replaced.
    static func copy(items: [URL], to directory: URL, move: Bool) throws -> [FileOperationReceipt] {
        try FileTools.copy(items: items, to: directory, move: move)
    }

    @MainActor static func createArchive(items: [URL], format: ArchiveFormat, service: ArchiveService) async throws -> URL {
        guard let first = items.first else { throw FileToolsError.invalid("请先选择需要压缩的文件。") }
        let parent = first.deletingLastPathComponent()
        let stem: String
        if items.count == 1 {
            let type = try fm.attributesOfItem(atPath: first.path)[.type] as? FileAttributeType
            stem = type == .typeDirectory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else { stem = "归档" }
        let preferred = truncated(stem.isEmpty ? "归档" : stem, byteLimit: 250) + "." + format.rawValue
        let destination = try uniqueURL(in: parent, preferredName: preferred)
        return try await service.create(items: items, destination: destination, format: format, password: nil, splitMB: nil, solid: false)
    }

    @MainActor static func createZIP(items: [URL], service: ArchiveService) async throws -> URL {
        try await createArchive(items: items, format: .zip, service: service)
    }

    static func makeExtractionBatch(archives: [URL]) throws -> QuickExtractionBatch {
        guard !archives.isEmpty, archives.count <= 1000 else { throw FileToolsError.invalid("请选择 1–1000 个压缩包。") }
        var seen = Set<String>()
        let items = try archives.compactMap { archive -> QuickExtractionItem? in
            guard archive.isFileURL, archive.path.hasPrefix("/"),
                  (try fm.attributesOfItem(atPath: archive.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw FileToolsError.unsupported(archive)
            }
            let canonical = try FileTools.canonicalURL(archive)
            guard seen.insert(canonical.path).inserted else { return nil }
            return .init(id: UUID(), archive: archive, output: nil, receipt: nil, status: .pending)
        }
        return .init(id: UUID(), items: items)
    }

    /// Stops at the first password/error/cancellation. The password applies to the current item ONLY.
    /// Calling this with a completed batch is a no-op, so retries cannot duplicate completed outputs.
    /// stopAfterFirstSuccess lets callers persist each staged fingerprint before advancing the batch.
    @MainActor static func continueExtraction(_ batch: QuickExtractionBatch, service: ArchiveService,
                                              password: String? = nil, stopAfterFirstSuccess: Bool = false) async -> QuickExtractionBatch {
        var result = batch
        let firstPending = result.items.firstIndex { $0.status != .completed }
        for index in result.items.indices where result.items[index].status != .completed {
            if Task.isCancelled { result.items[index].status = .cancelled; return result }
            let archive = result.items[index].archive
            do {
                let destination = try uniqueURL(in: archive.deletingLastPathComponent(),
                                                preferredName: extractionFolderName(for: archive), isDirectory: true)
                let output = try await service.extract(archive: archive, to: destination,
                                                      password: index == firstPending ? password : nil, selected: nil)
                result.items[index].output = output
                result.items[index].receipt = service.lastResultReceipts.first
                result.items[index].status = .completed
                if stopAfterFirstSuccess { return result }
            } catch ArchiveError.passwordRequired(let incorrect) {
                result.items[index].status = .needsPassword(incorrect: incorrect)
                return result
            } catch ArchiveError.cancelled {
                result.items[index].status = .cancelled
                return result
            } catch is CancellationError {
                result.items[index].status = .cancelled
                return result
            } catch {
                result.items[index].status = .failed(error.localizedDescription)
                return result
            }
        }
        return result
    }

    /// Converts the full batch in hidden sibling directories, then commits unique output names.
    /// On a commit failure, verified created outputs are rolled back. Any unsafe-to-undo residual
    /// outputs are carried by FileToolsPartialFailure.receipts for the caller's recovery history.
    static func convertImages(items: [URL], format: String, maxDimension: Int? = nil) throws -> [FileOperationReceipt] {
        guard !items.isEmpty else { throw FileToolsError.invalid("请先选择图片。") }
        let ext: String
        switch format.lowercased() {
        case "png": ext = "png"
        case "jpg", "jpeg": ext = "jpeg"
        case "heic": ext = "heic"
        case "tif", "tiff": ext = "tiff"
        default: throw FileToolsError.invalid("支持的图片格式：PNG、JPEG、HEIC、TIFF。")
        }
        var stages: [URL] = []
        var prepared: [(URL, URL, String)] = []
        var committed: [FileOperationReceipt] = []
        var reserved = Set<String>()
        defer { for stage in stages { try? fm.removeItem(at: stage) } }
        do {
            for source in items {
                let parent = source.deletingLastPathComponent()
                try validateDirectory(parent)
                let preferred = truncated(source.deletingPathExtension().lastPathComponent, byteLimit: 249) + "." + ext
                var destination = try uniqueURL(in: parent, preferredName: preferred)
                // Planned names are not on disk yet: also reserve against other entries in this batch.
                var sequence = 2
                while !reserved.insert(destination.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                    let name = truncated(source.deletingPathExtension().lastPathComponent, byteLimit: 240) + " \(sequence)." + ext
                    destination = try uniqueURL(in: parent, preferredName: name)
                    sequence += 1
                }
                let stage = parent.appendingPathComponent(".gaocaozuo-quick-images-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                stages.append(stage)
                let converted = try FileTools.convertImages(items: [source], to: stage, format: ext, maxDimension: maxDimension)[0]
                prepared.append((converted, destination, try FileTools.fingerprint(converted)))
            }
            for (_, destination, _) in prepared {
                guard try isAbsent(destination) else { throw FileToolsError.conflict(destination) }
            }
            for (converted, destination, fingerprint) in prepared {
                try fm.moveItem(at: converted, to: destination)
                committed.append(.init(kind: .convert, destination: destination, fingerprint: fingerprint))
            }
            return committed
        } catch {
            var residual: [FileOperationReceipt] = []
            for receipt in committed.reversed() {
                do { try FileTools.undo([receipt], trashCreated: false) }
                catch { residual.append(receipt) }
            }
            if !residual.isEmpty { throw FileToolsPartialFailure(underlyingMessage: error.localizedDescription, receipts: residual.reversed()) }
            throw error
        }
    }

    static func extractionFolderName(for archive: URL) -> String {
        var name = archive.lastPathComponent
        if name.lowercased().hasSuffix(".001") { name = String(name.dropLast(4)) }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty || stem == "." || stem == ".." ? "解压文件" : stem
    }

    private static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              (try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw FileToolsError.invalid("目标不是可用文件夹。")
        }
    }
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw FileToolsError.invalid("文件名为空、过长或含有非法字符。")
        }
    }
    private static func isAbsent(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return false }
        let code = errno
        if code == ENOENT { return true }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    private static func truncated(_ value: String, byteLimit: Int) -> String {
        var result = ""
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= max(0, byteLimit) else { break }
            result.append(character)
        }
        return result
    }
}
