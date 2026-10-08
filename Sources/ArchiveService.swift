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
    let permissions: UInt16?
    let modifiedAt: Date?
    var id: String { path }
    init(path: String, size: UInt64, isDirectory: Bool, permissions: UInt16? = nil, modifiedAt: Date? = nil) {
        self.path = path; self.size = size; self.isDirectory = isDirectory
        self.permissions = permissions; self.modifiedAt = modifiedAt
    }
}

enum ArchiveError: LocalizedError {
    case invalid(String)
    case failed(Int32, String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .failed(let code, let detail): return "压缩引擎退出码 \(code)：\(detail)"
        case .cancelled: return "已取消，原始文件未改变。"
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
    private var process: Process?
    private var cancellationRequested = false
    private var jobDeadline = Date.distantFuture
    private let engineOverride: URL?
    private let fm = FileManager.default
    nonisolated static let maximumExpandedBytes: UInt64 = 20 * 1024 * 1024 * 1024
    nonisolated static let maximumEntries = 100_000

    init(engineURL: URL? = nil) { self.engineOverride = engineURL }

    func cancel() {
        cancellationRequested = true
        guard let process, process.isRunning else { return }
        process.interrupt()
        Task { @MainActor [weak process] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// destination is the exact output filename. Split archives return the first (.001) volume.
    func create(items: [URL], destination: URL, format: ArchiveFormat, password: String?, splitMB: Int?, solid: Bool) async throws -> URL {
        try begin()
        defer { finish() }
        guard !items.isEmpty else { throw ArchiveError.invalid("请先选择需要压缩的文件。") }
        try validatePassword(password)
        if let splitMB, !(1...1_048_576).contains(splitMB) { throw ArchiveError.invalid("分卷大小须为 1–1048576 MB。") }
        guard format == .sevenZip || !solid else { throw ArchiveError.invalid("固实压缩仅适用于 7Z。") }
        try requireDirectory(destination.deletingLastPathComponent())
        try requireAbsent(destination)
        let stage = try makeStage(in: destination.deletingLastPathComponent())
        defer { try? fm.removeItem(at: stage) }
        let input = stage.appendingPathComponent("input", isDirectory: true)
        let packed = stage.appendingPathComponent("packed", isDirectory: true)
        try fm.createDirectory(at: input, withIntermediateDirectories: false)
        try fm.createDirectory(at: packed, withIntermediateDirectories: false)
        output = "正在核验并准备文件…\n"
        // FileTools rejects links/special files and verifies complete copies. Work runs away from the UI actor.
        _ = try await Task.detached(priority: .userInitiated) { try FileTools.copy(items: items, to: input, move: false) }.value
        try checkCancellation()
        let packedURL = packed.appendingPathComponent(destination.lastPathComponent)
        var args = ["a", "-t\(format.rawValue)", "-mx=5", "-mmt=on", "-y", "-spd"]
        if format == .sevenZip { args.append(solid ? "-ms=on" : "-ms=off") }
        if let password, !password.isEmpty {
            args.append("-p")
            args.append(format == .sevenZip ? "-mhe=on" : "-mem=AES256")
        }
        if let splitMB { args.append("-v\(splitMB)m") }
        args += ["--", packedURL.path] + items.map(\.lastPathComponent)
        _ = try await run(args, currentDirectory: input, password: password, writeRoot: packed)
        let volumes = try fm.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !volumes.isEmpty else { throw ArchiveError.invalid("压缩引擎没有生成结果。") }
        let first = splitMB == nil ? packedURL : packedURL.appendingPathExtension("001")
        guard fm.fileExists(atPath: first.path) else { throw ArchiveError.invalid("缺少压缩结果或首个分卷。") }
        output += "\n正在验证压缩包完整性…\n"
        _ = try await run(["t", "-y"] + passwordArguments(password) + ["--", first.path], password: password, writeRoot: stage)
        try checkCancellation()
        let targets = volumes.map { destination.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }
        for target in targets { try requireAbsent(target) }
        var committed: [(URL, URL)] = []
        do {
            for (source, target) in zip(volumes, targets) {
                try fm.moveItem(at: source, to: target)
                committed.append((source, target))
            }
        } catch {
            // Roll back only results this job just moved, without touching any pre-existing path.
            for (source, target) in committed.reversed() { try? fm.moveItem(at: target, to: source) }
            throw error
        }
        let result = destination.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent)
        lastResultURL = result; progress = 1; output += "\n压缩完成，完整性验证通过。"
        return result
    }

    func list(archive: URL, password: String?) async throws -> [ArchiveEntry] {
        try begin(); defer { finish() }
        try validatePassword(password)
        let entries = try await checkedEntries(archive: archive, password: password)
        output = "已读取 \(entries.count) 个项目，路径与容量预检通过。"
        progress = 1
        return entries
    }

    /// to is a NEW directory. Existing directories are refused, including an empty one.
    func extract(archive: URL, to destination: URL, password: String?, selected: [String]?) async throws -> URL {
        try begin(); defer { finish() }
        try validatePassword(password)
        try requireDirectory(destination.deletingLastPathComponent())
        try requireAbsent(destination)
        let entries = try await checkedEntries(archive: archive, password: password)
        let selected = try validateSelection(selected, entries: entries)
        let stage = try makeStage(in: destination.deletingLastPathComponent())
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        output = "路径与容量预检通过，正在隔离解压…\n"
        let expected = entries.filter { entry in selected == nil || selected!.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) }
        let files = expected.filter { !$0.isDirectory }
        for entry in expected where entry.isDirectory {
            try fm.createDirectory(at: payload.appendingPathComponent(entry.path, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for (index, entry) in files.enumerated() {
            try checkCancellation()
            let result = payload.appendingPathComponent(entry.path)
            try fm.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            output += "\n正在提取 \(index + 1)/\(files.count)：\(entry.path)\n"
            _ = try await run(["x", "-so", "-y", "-spd"] + passwordArguments(password) + ["--", archive.path, entry.path], password: password, streamTo: result, expectedBytes: entry.size)
            progress = Double(index + 1) / Double(max(1, files.count))
        }
        try checkCancellation()
        try Self.verifyExtractedTree(payload, expected: expected)
        try requireAbsent(destination)
        try fm.moveItem(at: payload, to: destination)
        lastResultURL = destination; progress = 1; output += "\n解压完成，结果已核验并保存到新目录。"
        return destination
    }

    private func begin() throws {
        guard !isRunning else { throw ArchiveError.invalid("已有压缩任务正在运行，请等待或取消。") }
        cancellationRequested = false; isRunning = true; progress = nil; output = ""; lastResultURL = nil
        jobDeadline = Date().addingTimeInterval(60 * 60)
    }
    private func finish() { process = nil; isRunning = false }
    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw ArchiveError.cancelled }
        if Date() > jobDeadline { throw ArchiveError.invalid("任务超过一小时的安全时间预算。") }
    }
    private func validatePassword(_ password: String?) throws {
        if let password, password.contains("\0") || password.contains("\n") || password.contains("\r") || password.utf8.count > 1024 { throw ArchiveError.invalid("密码过长或含有换行/空字符。") }
    }
    private func passwordArguments(_ password: String?) -> [String] {
        // Passwords enter through a private stdin pipe, never process arguments or the shell.
        []
    }
    private func requireDirectory(_ url: URL) throws {
        guard (try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { throw ArchiveError.invalid("父目录不可用：\(url.path)") }
    }
    private func requireAbsent(_ url: URL) throws {
        if (try? fm.attributesOfItem(atPath: url.path)) != nil { throw ArchiveError.invalid("目标已存在，未覆盖：\(url.path)") }
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
        let listing = try await run(["l", "-slt", "-ba", "-sccUTF-8"] + passwordArguments(password) + ["--", archive.path], password: password, captureLimit: 64 * 1024 * 1024)
        return try Self.parseListing(listing)
    }

    /// Public to module tests: malformed, ambiguous and link-bearing metadata is rejected.
    nonisolated static func parseListing(_ text: String) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        var paths = Set<String>()
        var expanded: UInt64 = 0
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
            if nonemptyKeys.contains(where: { $0.contains("symbolic link") || $0.contains("hard link") || $0 == "link" }) ||
                attributes.split(separator: " ").contains(where: { $0.first == "l" || $0.first == "b" || $0.first == "c" || $0.first == "p" || $0.first == "s" }) ||
                (fields["Characteristics"] ?? "").lowercased().contains("link") {
                throw ArchiveError.invalid("压缩包含有链接或特殊文件，为避免越界写入已拒绝。")
            }
            let directory = fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.split(separator: " ").contains(where: { $0.first == "d" }) || path.hasSuffix("/")
            let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
            let comparison = clean.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(comparison).inserted else { throw ArchiveError.invalid("压缩包含有重名或大小写冲突项目：\(clean)") }
            guard size <= maximumExpandedBytes, expanded <= maximumExpandedBytes - size else { throw ArchiveError.invalid("压缩包展开内容超过 20 GiB 安全预算。") }
            expanded += size
            entries.append(.init(path: clean, size: size, isDirectory: directory,
                                 permissions: parsePermissions(attributes), modifiedAt: parseModifiedDate(fields["Modified"])))
            guard entries.count <= maximumEntries else { throw ArchiveError.invalid("压缩包超过 10 万个项目的安全预算。") }
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
        return entries
    }

    nonisolated static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveError.invalid("压缩包含有危险路径：\(String(path.prefix(120)))")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("."), !parts.dropLast().contains(""), parts.allSatisfy({ $0.utf8.count <= 255 }) else { throw ArchiveError.invalid("压缩包含有越界或异常路径。") }
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

    private nonisolated static func parseModifiedDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
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
            guard available.contains(path) else { throw ArchiveError.invalid("选中项目不在已核验目录中：\(path)") }
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
        var seen = Set<String>()
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else { throw ArchiveError.invalid("无法核验解压结果。") }
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard let entry = allowed[relative] else { throw ArchiveError.invalid("解压结果含有目录清单之外的项目：\(relative)") }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard (entry.isDirectory && type == .typeDirectory) || (!entry.isDirectory && type == .typeRegular) else { throw ArchiveError.invalid("解压结果包含链接、特殊文件或类型不一致项目。") }
            if !entry.isDirectory {
                guard (attributes[.size] as? NSNumber)?.uint64Value == entry.size,
                      (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw ArchiveError.invalid("解压结果大小不符或包含硬链接。") }
            }
            seen.insert(relative)
        }
        if let failure { throw failure }
        guard expected.allSatisfy({ seen.contains($0.path) }) else { throw ArchiveError.invalid("解压结果不完整，未保存到目标目录。") }
        // Apply metadata only after all bytes/types/paths verify. Descendants first preserves directory mtimes.
        for entry in allowed.values.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
            let url = root.appendingPathComponent(entry.path)
            let ownerAccess: UInt16 = entry.isDirectory ? 0o700 : 0o600
            let safeMode = ((entry.permissions ?? ownerAccess) & 0o777) | ownerAccess
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(safeMode)]
            if let modifiedAt = entry.modifiedAt { attributes[.modificationDate] = modifiedAt }
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }

    private func run(_ arguments: [String], currentDirectory: URL? = nil, password: String?, writeRoot: URL? = nil,
                     expansionMonitor: URL? = nil, captureLimit: Int = 2 * 1024 * 1024,
                     streamTo: URL? = nil, expectedBytes: UInt64? = nil) async throws -> String {
        try checkCancellation()
        let engineURL = try engine()
        let task = Process()
        var allArguments = arguments
        allArguments.insert(contentsOf: streamTo == nil ? ["-bso1", "-bse1", arguments.first == "l" ? "-bsp0" : "-bsp1"] : ["-bso0", "-bse2", "-bsp2"], at: 1)
        if arguments.first == "a" {
            // Creation only sees previously copied, fingerprint-verified ordinary input files.
            task.executableURL = engineURL
            if let writeRoot { allArguments.insert("-w\(writeRoot.path)", at: 1) }
            task.arguments = allArguments
        } else {
            guard fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
                throw ArchiveError.invalid("当前系统缺少隔离提取能力；为保护文件，未启动解压。")
            }
            let profile = "(version 1)(allow default)(deny network*)(deny file-write*)"
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", profile, engineURL.path] + allArguments
        }
        task.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"; environment["LANG"] = "en_US.UTF-8"
        task.environment = environment
        let passwordPipe: Pipe?
        if let password, !password.isEmpty {
            let input = Pipe(); task.standardInput = input; passwordPipe = input
        } else { task.standardInput = FileHandle.nullDevice; passwordPipe = nil }
        let pipe = Pipe(); task.standardError = pipe
        let streamPipe: Pipe?
        let streamWriter: ArchiveStreamWriter?
        if let streamTo, let expectedBytes {
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
        if let passwordPipe, let password {
            do { try passwordPipe.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
            catch { collector.stopReason = "无法向压缩引擎提交密码。"; if task.isRunning { task.interrupt() } }
            try? passwordPipe.fileHandleForWriting.close()
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
                if arguments.first != "l", let regex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#),
                   let match = regex.matches(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)).last,
                   let range = Range(match.range(at: 1), in: snapshot), let value = Double(snapshot[range]) {
                    progress = min(1, max(0, value / 100))
                }
                let budgetExceeded: Bool
                if let root = expansionMonitor { budgetExceeded = await Task.detached(priority: .utility) { Self.exceedsDiskBudget(root) }.value }
                else { budgetExceeded = false }
                if collector.exceeded || Date() > deadline || budgetExceeded || streamWriter?.failure != nil {
                    collector.stopReason = "任务超过输出、时间或展开容量安全预算。"
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                    return
                }
            }
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
        if let failure = streamWriter?.failure { throw ArchiveError.invalid(failure) }
        if let reason = collector.stopReason { throw ArchiveError.invalid(reason) }
        guard !collector.exceeded else { throw ArchiveError.invalid("压缩引擎输出超过安全预算。") }
        guard task.terminationStatus == 0 else { throw ArchiveError.failed(task.terminationStatus, String(redacted.suffix(2000))) }
        return text
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
