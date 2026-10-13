import Foundation
import CryptoKit
import Darwin

/// In-process archive operations for the sandboxed preview. No subprocess or
/// libarchive external-program filter is registered. Edits produce a new copy;
/// the original archive is never renamed, overwritten or deleted.
enum NativeArchive {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { L10n.text(message) }
    }
    // Read/time checks are cooperative at library callbacks. Expanded bytes
    // bound manifest declarations and selected output; next_header may internally
    // decode skipped entries, so this is not a hard bound on every library output.
    struct Budget {
        var maxArchiveBytes: Int64 = 128 * 1_024 * 1_024
        var maxReadBytes: Int64 = 512 * 1_024 * 1_024
        var maxExpandedBytes: Int64 = 512 * 1_024 * 1_024
        var maxMemberBytes: Int64 = 128 * 1_024 * 1_024
        var maxEntries = 10_000
        var maxDepth = 64
        var maxPathBytes = 4 * 1_024 * 1_024
        var maxTreeNodes = 4_000
        var seconds: Double = 30
    }
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline: Double
        init(seconds: Double = 30) { deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds) }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped || Task.isCancelled { throw Failure(message: "已取消，原压缩包未改变。") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "原生压缩操作超过时间预算，原压缩包未改变。") }
        }
    }
    enum Kind: String { case file, directory, unsupported }
    struct Item: Identifiable, Equatable {
        let path: String
        let size: Int64
        let kind: Kind
        let mode: UInt16
        let modified: Int64
        let encrypted: Bool
        var id: String { path }
    }
    struct Identity: Equatable {
        let device: Int32, inode: UInt64, size: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino; size = s.st_size; modified = Int64(s.st_mtimespec.tv_sec); modifiedNS = Int64(s.st_mtimespec.tv_nsec); changed = Int64(s.st_ctimespec.tv_sec); changedNS = Int64(s.st_ctimespec.tv_nsec) }
    }
    struct Document {
        let url: URL
        let identity: Identity
        let digest: String
        let format: String
        let items: [Item]
        fileprivate let bound: BoundItem?
        var canEditCopy: Bool { ["zip", "7z"].contains(format) && !items.contains { $0.encrypted || $0.kind == .unsupported } }
    }
    struct VerifiedFile: Equatable { let size: Int64; let digest: String }
    enum Phase { case beforePayloadCreate, payloadReady, beforeCandidateCreate, candidateReady, beforePublish, afterCommit }
    typealias Observer = (Phase, URL) throws -> Void
    /// Both decoded paths and implicit UI nodes have finite aggregate budgets.
    /// Prefix accounting happens before an outline node or filesystem entry exists.
    struct PathBudget {
        private let limits: Budget
        private var paths = Set<String>(), prefixes = Set<String>()
        private var pathBytes = 0, prefixBytes = 0
        init(_ limits: Budget = Budget()) { self.limits = limits }
        mutating func accept(_ path: String) throws {
            _ = try safePath(path, directory: false, maxDepth: limits.maxDepth)
            guard paths.count < limits.maxEntries, paths.insert(collisionKey(path)).inserted,
                  path.utf8.count <= limits.maxPathBytes - pathBytes else { throw Failure(message: "压缩包包含重名、过多项目或超出展开预算。") }
            pathBytes += path.utf8.count
            var prefix = ""
            for part in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                if prefixes.contains(prefix) { continue }
                guard prefixes.count < limits.maxTreeNodes, prefix.utf8.count <= limits.maxPathBytes - prefixBytes else { throw Failure(message: "压缩包包含重名、过多项目或超出展开预算。") }
                prefixes.insert(prefix); prefixBytes += prefix.utf8.count
            }
        }
    }
    static func validateTree(_ items: [Item], budget: Budget = Budget()) throws {
        var accounting = PathBudget(budget)
        for item in items { try accounting.accept(item.path) }
    }
    /// A child is always opened relative to its bound parent, never by a stage URL.
    fileprivate final class BoundItem {
        let fd: Int32, parentFD: Int32, name: String
        private let device: dev_t, inode: ino_t, type: mode_t
        init(fd: Int32, parentFD: Int32, name: String) throws {
            var info = stat(); let parent = dup(parentFD)
            guard parent >= 0, fstat(fd, &info) == 0 else { if parent >= 0 { close(parent) }; close(fd); throw posix() }
            self.fd = fd; self.parentFD = parent; self.name = name; device = info.st_dev; inode = info.st_ino; type = info.st_mode & S_IFMT
        }
        deinit { close(fd); close(parentFD) }
        func verify() throws {
            var opened = stat(), named = stat()
            guard fstat(fd, &opened) == 0, fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_dev == device, opened.st_ino == inode, opened.st_mode & S_IFMT == type,
                  named.st_dev == device, named.st_ino == inode, named.st_mode & S_IFMT == type else { throw Failure(message: "编辑暂存内容已变化。") }
        }
        func matches(_ info: stat) -> Bool { info.st_dev == device && info.st_ino == inode && info.st_mode & S_IFMT == type }
    }
    private typealias Pointer = OpaquePointer
    private typealias Single = @convention(c) (Pointer?) -> Int32
    private typealias New = @convention(c) () -> Pointer?
    private typealias Header = @convention(c) (Pointer?, UnsafeMutablePointer<Pointer?>?) -> Int32
    private typealias EntryText = @convention(c) (Pointer?) -> UnsafePointer<CChar>?
    private typealias EntrySize = @convention(c) (Pointer?) -> Int64
    private typealias EntryMode = @convention(c) (Pointer?) -> UInt16
    private typealias Read = @convention(c) (Pointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias ReadCallback = @convention(c) (Pointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int
    private typealias SeekCallback = @convention(c) (Pointer?, UnsafeMutableRawPointer?, Int64, Int32) -> Int64
    private final class Library {
        let image: UnsafeMutableRawPointer
        init() throws {
            guard let image = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw Failure(message: "系统原生压缩组件不可用。") }
            self.image = image
        }
        deinit { dlclose(image) }
        func function<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let address = dlsym(image, name) else { throw Failure(message: "系统原生压缩组件不完整。") }
            return unsafeBitCast(address, to: type)
        }
    }
    private final class Input {
        let fd: Int32, identity: Identity, budget: Budget, cancellation: Cancellation, bound: BoundItem?
        let buffer: UnsafeMutableRawPointer
        var offset: Int64 = 0, readBytes: Int64 = 0
        init(url: URL, bound: BoundItem?, budget: Budget, cancellation: Cancellation) throws {
            try bound?.verify()
            let fd = bound.map { dup($0.fd) } ?? open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw posix() }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size >= 0, s.st_size <= budget.maxArchiveBytes else { close(fd); throw Failure(message: "原生预览只接受预算内的普通压缩文件。") }
            self.fd = fd; identity = Identity(s); self.budget = budget; self.cancellation = cancellation; self.bound = bound
            buffer = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16)
        }
        deinit { close(fd); buffer.deallocate() }
        func verify(_ url: URL, expected: Document? = nil) throws {
            try cancellation.check()
            var current = stat()
            guard fstat(fd, &current) == 0, current.st_mode & S_IFMT == S_IFREG, Identity(current) == identity,
                  expected == nil || expected!.identity == identity else { throw Failure(message: "压缩包已变化，请重新打开预览。") }
            if let bound { try bound.verify() }
            else {
                var named = stat()
                guard lstat(url.path, &named) == 0, named.st_mode & S_IFMT == S_IFREG, Identity(named) == identity else { throw Failure(message: "压缩包已变化，请重新打开预览。") }
            }
        }
    }
    private static let readCallback: ReadCallback = { _, opaque, output in
        guard let opaque, let output else { return -1 }
        let input = Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
        do { try input.cancellation.check() } catch { return -1 }
        if input.offset == input.identity.size { return 0 }
        guard input.offset >= 0, input.offset < input.identity.size, input.readBytes < input.budget.maxReadBytes else { return -1 }
        let amount = Int(min(65_536, input.identity.size - input.offset, input.budget.maxReadBytes - input.readBytes))
        var count: Int
        repeat { count = pread(input.fd, input.buffer, amount, off_t(input.offset)) } while count < 0 && errno == EINTR
        guard count > 0 else { return -1 }
        input.offset += Int64(count); input.readBytes += Int64(count); output.pointee = UnsafeRawPointer(input.buffer)
        return count
    }
    private static let seekCallback: SeekCallback = { _, opaque, offset, whence in
        guard let opaque else { return -1 }
        let input = Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
        do { try input.cancellation.check() } catch { return -1 }
        let origin: Int64
        switch whence { case SEEK_SET: origin = 0; case SEEK_CUR: origin = input.offset; case SEEK_END: origin = input.identity.size; default: return -1 }
        let (position, overflow) = origin.addingReportingOverflow(offset)
        guard !overflow, position >= 0, position <= input.identity.size else { return -1 }
        input.offset = position; return position
    }
    private final class Reader {
        let library: Library, input: Input, archive: Pointer
        let free: Single, next: Header, readData: Read
        let path: EntryText, hardlink: EntryText, symlink: EntryText, size: EntrySize, modified: EntrySize, mode: EntryMode, encrypted: Single, format: Single
        var expanded: Int64 = 0
        init(url: URL, bound: BoundItem? = nil, budget: Budget, cancellation: Cancellation, password: String? = nil) throws {
            let l = try Library(), i = try Input(url: url, bound: bound, budget: budget, cancellation: cancellation)
            let create = try l.function("archive_read_new", New.self), release = try l.function("archive_read_free", Single.self)
            guard let a = create() else { throw Failure(message: "无法创建系统原生解码器。") }
            var success = false; defer { if !success { _ = release(a) } }
            let handle = FileHandle(fileDescriptor: dup(i.fd), closeOnDealloc: true)
            defer { try? handle.close() }
            try ArchiveQuickLookPreflight.validate(handle: handle, maxEntries: budget.maxEntries, maxDataBytes: UInt64(max(0, budget.maxExpandedBytes)), timeoutSeconds: max(0.01, budget.seconds))
            let all = try l.function("archive_read_support_format_all", Single.self)
            guard all(a) == 0 else { throw Failure(message: "此格式不能由系统原生解码器处理。") }
            // Never register support_filter_all: it can include external programs.
            let filters = ["gz":"gzip", "gzip":"gzip", "tgz":"gzip", "bz2":"bzip2", "tbz":"bzip2", "tbz2":"bzip2", "xz":"xz", "txz":"xz", "lz":"lzip", "lzip":"lzip", "zst":"zstd", "tzst":"zstd"]
            let filter = try l.function("archive_read_support_filter_" + (filters[url.pathExtension.lowercased()] ?? "none"), Single.self)
            guard filter(a) == 0 else { throw Failure(message: "此格式需要系统原生库未提供的解码能力。") }
            if let password {
                guard !password.contains("\0"), password.utf8.count <= 1_024 else { throw Failure(message: "密码无效或过长。") }
                let add = try l.function("archive_read_add_passphrase", (@convention(c) (Pointer?, UnsafePointer<CChar>?) -> Int32).self)
                guard password.withCString({ add(a, $0) }) == 0 else { throw Failure(message: "系统原生库不支持此密码。") }
            }
            let setData = try l.function("archive_read_set_callback_data", (@convention(c) (Pointer?, UnsafeMutableRawPointer?) -> Int32).self)
            let setRead = try l.function("archive_read_set_read_callback", (@convention(c) (Pointer?, ReadCallback?) -> Int32).self)
            let setSeek = try l.function("archive_read_set_seek_callback", (@convention(c) (Pointer?, SeekCallback?) -> Int32).self)
            let openReader = try l.function("archive_read_open1", Single.self)
            guard setData(a, Unmanaged.passUnretained(i).toOpaque()) == 0, setRead(a, readCallback) == 0, setSeek(a, seekCallback) == 0,
                  openReader(a) == 0 else { throw Failure(message: "无法原生读取此压缩包，可能已加密、损坏或不受支持。") }
            library = l; input = i; archive = a; free = release
            next = try l.function("archive_read_next_header", Header.self); readData = try l.function("archive_read_data", Read.self)
            path = try l.function("archive_entry_pathname_utf8", EntryText.self); hardlink = try l.function("archive_entry_hardlink", EntryText.self); symlink = try l.function("archive_entry_symlink", EntryText.self)
            size = try l.function("archive_entry_size", EntrySize.self); modified = try l.function("archive_entry_mtime", EntrySize.self); mode = try l.function("archive_entry_mode", EntryMode.self)
            encrypted = try l.function("archive_entry_is_encrypted", Single.self); format = try l.function("archive_format", Single.self)
            success = true
        }
        deinit { _ = free(archive) }
        func nextItem() throws -> Item? {
            try input.cancellation.check()
            var entry: Pointer?
            let code = next(archive, &entry)
            if code == 1 { return nil }
            guard code == 0, let entry, let name = path(entry), strnlen(name, 16_385) <= 16_384,
                  let decoded = String(validatingUTF8: name) else { throw Failure(message: "压缩包目录无法安全读取，可能已加密或损坏。") }
            let rawMode = mode(entry), type = rawMode & UInt16(S_IFMT)
            let kind: Kind = hardlink(entry) != nil || symlink(entry) != nil ? .unsupported : (type == UInt16(S_IFDIR) ? .directory : (type == UInt16(S_IFREG) ? .file : .unsupported))
            let safe = try safePath(decoded, directory: kind == .directory, maxDepth: input.budget.maxDepth)
            let amount = size(entry)
            guard amount >= 0, amount <= input.budget.maxExpandedBytes else { throw Failure(message: "压缩包声明内容超过原生操作预算。") }
            return Item(path: safe, size: kind == .directory ? 0 : amount, kind: kind, mode: rawMode & 0o777, modified: modified(entry), encrypted: encrypted(entry) > 0)
        }
        func consume(_ item: Item, fd: Int32) throws -> VerifiedFile {
            guard item.kind == .file else { throw Failure(message: "原生操作不提取链接或特殊文件。") }
            var hash = SHA256(), amount: Int64 = 0
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16); defer { buffer.deallocate() }
            while true {
                try input.cancellation.check()
                let count = readData(archive, buffer, 65_536)
                guard count >= 0 else { throw Failure(message: item.encrypted ? "密码不正确，或系统原生库不支持此加密格式。" : "原生解码失败，未提交任何提取结果。") }
                if count == 0 { break }
                guard Int64(count) <= input.budget.maxMemberBytes - amount, Int64(count) <= input.budget.maxExpandedBytes - expanded else { throw Failure(message: "实际展开内容超过原生操作预算。") }
                try writeAll(fd, buffer: buffer, count: count)
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count)); amount += Int64(count); expanded += Int64(count)
            }
            guard amount == item.size else { throw Failure(message: "提取长度与目录不一致，未提交结果。") }
            guard fsync(fd) == 0 else { throw posix() }
            return VerifiedFile(size: amount, digest: hex(hash.finalize()))
        }
    }

    static func inspect(_ url: URL, budget: Budget = Budget(), cancellation: Cancellation? = nil) throws -> Document {
        return try inspect(url, bound: nil, budget: budget, cancellation: cancellation ?? Cancellation(seconds: budget.seconds))
    }
    private static func inspect(_ url: URL, bound: BoundItem?, budget: Budget, cancellation stop: Cancellation) throws -> Document {
        let reader = try Reader(url: url, bound: bound, budget: budget, cancellation: stop)
        let digest = try fileDigest(reader.input.fd, cancellation: stop)
        var items: [Item] = [], accounting = PathBudget(budget), declared: Int64 = 0
        while let item = try reader.nextItem() {
            try accounting.accept(item.path)
            guard item.size <= budget.maxExpandedBytes - declared else { throw Failure(message: "压缩包包含重名、过多项目或超出展开预算。") }
            declared += item.size; items.append(item)
        }
        let byPath = Dictionary(uniqueKeysWithValues: items.map { (collisionKey($0.path), $0.kind) })
        for item in items {
            var parts = item.path.split(separator: "/").map(String.init); if !parts.isEmpty { parts.removeLast() }
            while !parts.isEmpty {
                guard byPath[collisionKey(parts.joined(separator: "/"))] != .file, byPath[collisionKey(parts.joined(separator: "/"))] != .unsupported else { throw Failure(message: "压缩包文件与目录路径冲突。") }
                parts.removeLast()
            }
        }
        try reader.input.verify(url)
        guard try fileDigest(reader.input.fd, cancellation: stop) == digest else { throw Failure(message: "压缩包在读取期间发生变化，请重新打开。") }
        let kind: String
        switch reader.format(reader.archive) & 0xff0000 { case 0x50000: kind = "zip"; case 0xe0000: kind = "7z"; default: kind = "other" }
        return Document(url: url, identity: reader.input.identity, digest: digest, format: kind, items: items, bound: bound)
    }
    static func memberData(_ document: Document, path: String, password: String? = nil, budget: Budget = Budget(), cancellation: Cancellation? = nil) throws -> Data {
        guard let item = document.items.first(where: { $0.path == path }), item.kind == .file, item.size <= 16 * 1_024 * 1_024 else { throw Failure(message: "内嵌内容预览仅接受不超过 16 MiB 的普通文件。") }
        let stop = cancellation ?? Cancellation(seconds: budget.seconds), workspace = try Workspace(directory: FileManager.default.temporaryDirectory)
        let payload = try workspace.makeDirectory("payload")
        let verified = try decode(document, into: payload.fd, selected: [path], password: password, budget: budget, cancellation: stop)
        try payload.verify(); try workspace.verifyBindings(); try stop.check()
        let fd = try memberFD(payload.fd, path: path); defer { close(fd) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try stop.check(); let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw posix() }; if count == 0 { break }
            guard count <= 16 * 1_024 * 1_024 - bytes.count else { throw Failure(message: "内嵌内容预览仅接受不超过 16 MiB 的普通文件。") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try payload.verify(); try workspace.verifyBindings()
        guard let expected = verified[path], expected.size == bytes.count, expected.digest == hex(SHA256.hash(data: bytes)) else { throw Failure(message: "提取结果回读核验失败。") }
        return bytes
    }
    static func extract(_ document: Document, selected: Set<String>?, directory: URL, name: String, password: String? = nil, budget: Budget = Budget(), cancellation: Cancellation? = nil, observer: Observer? = nil) throws -> URL {
        let stop = cancellation ?? Cancellation(seconds: budget.seconds), workspace = try Workspace(directory: directory)
        try workspace.verifyBindings(); try observer?(.beforePayloadCreate, workspace.stage)
        let payload = try workspace.makeDirectory("payload")
        try observer?(.payloadReady, workspace.stage)
        _ = try decode(document, into: payload.fd, selected: selected, password: password, budget: budget, cancellation: stop)
        return try workspace.publish(payload, name: name, cancellation: stop, observer: observer)
    }
    private static func decode(_ document: Document, into rootFD: Int32, selected: Set<String>?, password: String?, budget: Budget, cancellation: Cancellation, expandDirectories: Bool = true) throws -> [String: VerifiedFile] {
        try validateTree(document.items, budget: budget)
        let reader = try Reader(url: document.url, bound: document.bound, budget: budget, cancellation: cancellation, password: password)
        try reader.input.verify(document.url, expected: document)
        guard try fileDigest(reader.input.fd, cancellation: cancellation) == document.digest else { throw Failure(message: "压缩包已变化，请重新打开预览。") }
        let chosen = document.items.filter { item in selected == nil || selected!.contains { item.path == $0 || (expandDirectories && item.path.hasPrefix($0 + "/")) } }
        guard !chosen.isEmpty else { throw Failure(message: "请先选择要提取的文件或目录。") }
        guard !chosen.contains(where: { $0.kind == .unsupported }) else { throw Failure(message: "原生操作不提取链接或特殊文件。") }
        let expected = Dictionary(uniqueKeysWithValues: document.items.map { ($0.path, $0) }), paths = Set(chosen.map(\.path))
        var verified: [String: VerifiedFile] = [:], seen = Set<String>()
        while let item = try reader.nextItem() {
            guard expected[item.path] == item, seen.insert(item.path).inserted else { throw Failure(message: "压缩目录已变化或包含重复项目。") }
            if !paths.contains(item.path) { continue }
            let components = item.path.split(separator: "/").map(String.init)
            if item.kind == .directory { let fd = try directoryFD(rootFD, components: components); close(fd); continue }
            let parent = try directoryFD(rootFD, components: Array(components.dropLast())); defer { close(parent) }
            let fd = openat(parent, components.last!, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posix() }; defer { close(fd) }
            let result = try reader.consume(item, fd: fd)
            guard try fileDigest(fd, cancellation: cancellation) == result.digest else { throw Failure(message: "提取结果回读核验失败。") }
            verified[item.path] = result
        }
        guard seen == Set(document.items.map(\.path)), Set(verified.keys) == Set(chosen.filter { $0.kind == .file }.map(\.path)) else { throw Failure(message: "提取结果不完整，未提交。") }
        try reader.input.verify(document.url, expected: document)
        guard try fileDigest(reader.input.fd, cancellation: cancellation) == document.digest else { throw Failure(message: "压缩包在提取期间发生变化。") }
        return verified
    }

    /// Rebuild and verify a fresh archive. Unsupported/encrypted entries are not
    /// silently decoded or rewritten with weaker protection.
    static func editedCopy(_ document: Document, deleting: Set<String>, adding: [URL], cleanHidden: Bool, directory: URL, name: String, budget: Budget = Budget(), cancellation: Cancellation? = nil, observer: Observer? = nil) throws -> URL {
        guard document.canEditCopy else { throw Failure(message: "原生编辑副本仅支持未加密且不含链接的 ZIP/7Z；原压缩包保留。") }
        let stop = cancellation ?? Cancellation(seconds: budget.seconds), workspace = try Workspace(directory: directory)
        try workspace.verifyBindings(); try observer?(.beforePayloadCreate, workspace.stage)
        let content = try workspace.makeDirectory("content")
        try observer?(.payloadReady, workspace.stage)
        let kept = document.items.filter { item in
            !deleting.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") }) && (!cleanHidden || !isHidden(item.path))
        }
        var hashes: [String: VerifiedFile] = [:]
        if !kept.isEmpty { hashes = try decode(document, into: content.fd, selected: Set(kept.map(\.path)), password: nil, budget: budget, cancellation: stop, expandDirectories: false) }
        var entries = kept
        for source in adding { try copyAddition(source, into: content.fd, entries: &entries, hashes: &hashes, budget: budget, cancellation: stop) }
        guard !entries.isEmpty else { throw Failure(message: "编辑计划没有剩余内容，请保留原压缩包。") }
        try content.verify(); try workspace.verifyBindings(); try observer?(.beforeCandidateCreate, workspace.stage)
        let candidate = try workspace.makeFile("candidate." + document.format)
        try writeArchive(candidate.fd, content: content.fd, entries: entries, format: document.format, budget: budget, cancellation: stop)
        try candidate.verify(); try content.verify(); try observer?(.candidateReady, workspace.stage)
        let verified = try inspect(workspace.stage.appendingPathComponent(candidate.name), bound: candidate, budget: budget, cancellation: stop)
        let verifyRoot = try workspace.makeDirectory("verify")
        let actual = try decode(verified, into: verifyRoot.fd, selected: nil, password: nil, budget: budget, cancellation: stop)
        try verifyRoot.verify(); try candidate.verify(); try workspace.verifyBindings()
        guard actual == hashes, Set(verified.items.map(\.path)) == Set(entries.map(\.path)), verified.format == document.format,
              !verified.items.contains(where: \.encrypted) else { throw Failure(message: "编辑副本完整性核验失败，原压缩包未改变。") }
        // Verify the original again even if the plan deleted every original entry.
        let original = try inspect(document.url, budget: budget, cancellation: stop)
        guard original.identity == document.identity, original.digest == document.digest else { throw Failure(message: "原压缩包已变化，未提交编辑副本。") }
        return try workspace.publish(candidate, name: name, cancellation: stop, observer: observer)
    }
    private static func writeArchive(_ fd: Int32, content: Int32, entries: [Item], format: String, budget: Budget, cancellation: Cancellation) throws {
        let l = try Library(), create = try l.function("archive_write_new", New.self), release = try l.function("archive_write_free", Single.self)
        guard let writer = create() else { throw Failure(message: "无法创建原生压缩写入器。") }; defer { _ = release(writer) }
        let setFormat = try l.function(format == "zip" ? "archive_write_set_format_zip" : "archive_write_set_format_7zip", Single.self)
        let option = try l.function("archive_write_set_format_option", (@convention(c) (Pointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self)
        guard setFormat(writer) == 0,
              option(writer, format == "zip" ? "zip" : "7zip", "compression", format == "zip" ? "deflate" : "lzma1") == 0 else { throw Failure(message: "系统原生库不支持所需压缩写入模式。") }
        let block = try l.function("archive_write_set_bytes_per_block", (@convention(c) (Pointer?, Int32) -> Int32).self)
        guard block(writer, 0) == 0 else { throw Failure(message: "无法配置原生压缩写入器。") }
        let openWriter = try l.function("archive_write_open_fd", (@convention(c) (Pointer?, Int32) -> Int32).self)
        guard openWriter(writer, fd) == 0 else { throw Failure(message: "无法写入原生编辑副本。") }
        let makeEntry = try l.function("archive_entry_new", New.self), freeEntry = try l.function("archive_entry_free", (@convention(c) (Pointer?) -> Void).self)
        let setPath = try l.function("archive_entry_set_pathname_utf8", (@convention(c) (Pointer?, UnsafePointer<CChar>?) -> Void).self)
        let setSize = try l.function("archive_entry_set_size", (@convention(c) (Pointer?, Int64) -> Void).self)
        let setType = try l.function("archive_entry_set_filetype", (@convention(c) (Pointer?, UInt32) -> Void).self)
        let setPerm = try l.function("archive_entry_set_perm", (@convention(c) (Pointer?, UInt16) -> Void).self)
        let setTime = try l.function("archive_entry_set_mtime", (@convention(c) (Pointer?, Int64, Int) -> Void).self)
        let header = try l.function("archive_write_header", (@convention(c) (Pointer?, Pointer?) -> Int32).self)
        let writeData = try l.function("archive_write_data", (@convention(c) (Pointer?, UnsafeRawPointer?, Int) -> Int).self)
        let closeWriter = try l.function("archive_write_close", Single.self)
        for item in entries.sorted(by: { $0.path < $1.path }) {
            try cancellation.check()
            guard let entry = makeEntry() else { throw Failure(message: "无法创建原生压缩条目。") }; defer { freeEntry(entry) }
            item.path.withCString { setPath(entry, $0) }; setSize(entry, item.size); setType(entry, item.kind == .directory ? UInt32(S_IFDIR) : UInt32(S_IFREG)); setPerm(entry, item.mode); setTime(entry, item.modified, 0)
            guard header(writer, entry) == 0 else { throw Failure(message: "原生编辑副本条目写入失败。") }
            if item.kind == .directory { continue }
            let input = try memberFD(content, path: item.path); defer { close(input) }
            var buffer = [UInt8](repeating: 0, count: 65_536), count: Int64 = 0
            while true {
                try cancellation.check()
                let amount = Darwin.read(input, &buffer, buffer.count)
                if amount < 0 && errno == EINTR { continue }
                guard amount >= 0 else { throw posix() }; if amount == 0 { break }
                guard Int64(amount) <= item.size - count else { throw Failure(message: "编辑暂存内容已变化。") }
                let written = buffer.withUnsafeBytes { writeData(writer, $0.baseAddress, amount) }
                guard written == amount else { throw Failure(message: "原生编辑副本数据写入不完整。") }; count += Int64(amount)
            }
            guard count == item.size else { throw Failure(message: "编辑暂存内容长度已变化。") }
        }
        guard closeWriter(writer) == 0, fsync(fd) == 0 else { throw Failure(message: "原生编辑副本未能完整结束。") }
    }
    private static func copyAddition(_ source: URL, into root: Int32, entries: inout [Item], hashes: inout [String: VerifiedFile], budget: Budget, cancellation: Cancellation) throws {
        let path = try safePath(source.lastPathComponent, directory: false, maxDepth: budget.maxDepth)
        var accounting = PathBudget(budget)
        for entry in entries { try accounting.accept(entry.path) }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }; defer { close(fd) }
        func walk(_ input: Int32, _ relative: String) throws {
            try cancellation.check(); try accounting.accept(relative)
            var info = stat(); guard fstat(input, &info) == 0 else { throw posix() }
            guard !entries.contains(where: { collisionKey($0.path) == collisionKey(relative) }), entries.count < budget.maxEntries else { throw Failure(message: "添加项目重名或超出数量预算。") }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                let directory = try directoryFD(root, components: relative.split(separator: "/").map(String.init)); close(directory)
                entries.append(Item(path: relative, size: 0, kind: .directory, mode: info.st_mode & 0o777, modified: Int64(info.st_mtimespec.tv_sec), encrypted: false))
                guard let stream = fdopendir(dup(input)) else { throw posix() }; defer { closedir(stream) }
                var names: [String] = []
                while true {
                    errno = 0; guard let entry = readdir(stream) else { if errno != 0 { throw posix() }; break }
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8) }
                    guard let name else { throw Failure(message: "添加目录包含无法无损表示的名称。") }
                    if name == "." || name == ".." { continue }; _ = try safePath(name, directory: false); names.append(name)
                    guard names.count <= budget.maxEntries else { throw Failure(message: "添加目录超出数量预算。") }
                }
                for name in names.sorted() {
                    let child = openat(input, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw posix() }; defer { close(child) }
                    try walk(child, relative + "/" + name)
                }
            } else if type == S_IFREG {
                let total = hashes.values.reduce(Int64(0)) { $0 + $1.size }
                guard info.st_size >= 0, info.st_size <= budget.maxMemberBytes, info.st_size <= budget.maxExpandedBytes - total else { throw Failure(message: "添加文件超过原生编辑预算。") }
                let parent = try directoryFD(root, components: Array(relative.split(separator: "/").dropLast().map(String.init))); defer { close(parent) }
                let output = openat(parent, relative.split(separator: "/").last!.description, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw posix() }; defer { close(output) }
                var buffer = [UInt8](repeating: 0, count: 65_536), hash = SHA256(), count: Int64 = 0
                while true {
                    try cancellation.check(); let amount = Darwin.read(input, &buffer, buffer.count)
                    if amount < 0 && errno == EINTR { continue }; guard amount >= 0 else { throw posix() }; if amount == 0 { break }
                    guard Int64(amount) <= info.st_size - count else { throw Failure(message: "添加文件在读取期间发生变化。") }
                    try buffer.withUnsafeBytes { try writeAll(output, buffer: $0.baseAddress!, count: amount) }; hash.update(data: Data(buffer.prefix(amount))); count += Int64(amount)
                }
                var after = stat(); guard fstat(input, &after) == 0, Identity(info) == Identity(after), count == info.st_size, fsync(output) == 0 else { throw Failure(message: "添加文件在复制期间发生变化。") }
                let digest = hex(hash.finalize()); guard try fileDigest(output, cancellation: cancellation) == digest else { throw Failure(message: "添加文件暂存核验失败。") }
                entries.append(Item(path: relative, size: count, kind: .file, mode: info.st_mode & 0o777, modified: Int64(info.st_mtimespec.tv_sec), encrypted: false)); hashes[relative] = VerifiedFile(size: count, digest: digest)
            } else { throw Failure(message: "添加项目不接受链接或特殊文件。") }
        }
        try walk(fd, path)
    }
    private final class Workspace {
        // stage is a display/diagnostic URL only. All staging I/O uses these FDs.
        let directory: URL, stage: URL, directoryFD: Int32, stageFD: Int32, stageName: String
        private let directoryIdentity: Identity, stageIdentity: Identity
        init(directory: URL) throws {
            let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw posix() }
            var parentInfo = stat(); guard fstat(parent, &parentInfo) == 0 else { close(parent); throw posix() }
            let name = ".gaocaozuo-ql-" + UUID().uuidString
            guard mkdirat(parent, name, 0o700) == 0 else { close(parent); throw posix() }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { unlinkat(parent, name, AT_REMOVEDIR); close(parent); throw posix() }
            var childInfo = stat(); guard fstat(child, &childInfo) == 0 else { close(child); unlinkat(parent, name, AT_REMOVEDIR); close(parent); throw posix() }
            self.directory = directory; stageName = name; stage = directory.appendingPathComponent(name, isDirectory: true)
            directoryFD = parent; stageFD = child; directoryIdentity = Identity(parentInfo); stageIdentity = Identity(childInfo)
        }
        deinit {
            // Do not follow a replacement stage name, even during cleanup.
            Self.cleanContents(stageFD)
            var named = stat()
            if fstatat(directoryFD, stageName, &named, AT_SYMLINK_NOFOLLOW) == 0, same(named, stageIdentity) { _ = unlinkat(directoryFD, stageName, AT_REMOVEDIR) }
            close(stageFD); close(directoryFD)
        }
        private func same(_ info: stat, _ identity: Identity) -> Bool { info.st_dev == identity.device && info.st_ino == identity.inode && info.st_mode & S_IFMT == S_IFDIR }
        func verifyBindings() throws {
            var parent = stat(), stageInfo = stat(), named = stat(), path = stat()
            guard fstat(directoryFD, &parent) == 0, same(parent, directoryIdentity),
                  fstat(stageFD, &stageInfo) == 0, same(stageInfo, stageIdentity),
                  fstatat(directoryFD, stageName, &named, AT_SYMLINK_NOFOLLOW) == 0, same(named, stageIdentity),
                  lstat(directory.path, &path) == 0, same(path, directoryIdentity) else { throw Failure(message: "目标目录已变化，未提交结果。") }
        }
        func makeDirectory(_ name: String) throws -> BoundItem {
            guard mkdirat(stageFD, name, 0o700) == 0 else { throw posix() }
            let fd = openat(stageFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posix() }; return try BoundItem(fd: fd, parentFD: stageFD, name: name)
        }
        func makeFile(_ name: String) throws -> BoundItem {
            let fd = openat(stageFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posix() }; return try BoundItem(fd: fd, parentFD: stageFD, name: name)
        }
        func publish(_ source: BoundItem, name: String, cancellation: Cancellation, observer: Observer?) throws -> URL {
            guard try safePath(name, directory: false) == name, !name.contains("/") else { throw Failure(message: "结果名称必须是单个有效名称。") }
            try observer?(.beforePublish, stage)
            try verifyBindings(); try source.verify()
            // Cancellation is checked after all potentially blocking binding checks.
            try cancellation.check()
            guard renameatx_np(source.parentFD, source.name, directoryFD, name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw Failure(message: "目标已存在，未覆盖；请更改结果名称。") }; throw posix()
            }
            do { try observer?(.afterCommit, stage) }
            catch { throw Failure(message: "结果已提交，但目标目录随后发生变化；请检查你选择的目录，原压缩包保持不变。") }
            // This is the commit point. Never remove a committed result on a late
            // cancellation. Refuse to report a stale returned URL after parent moves.
            var result = stat(), path = stat()
            guard fstatat(directoryFD, name, &result, AT_SYMLINK_NOFOLLOW) == 0, source.matches(result),
                  lstat(directory.path, &path) == 0, same(path, directoryIdentity) else { throw Failure(message: "结果已提交，但目标目录随后发生变化；请检查你选择的目录，原压缩包保持不变。") }
            return directory.appendingPathComponent(name)
        }
        private static func cleanContents(_ fd: Int32, depth: Int = 0) {
            guard depth < 128 else { return }
            guard let stream = fdopendir(dup(fd)) else { return }; defer { closedir(stream) }
            while let entry = readdir(stream) {
                guard let name = withUnsafeBytes(of: entry.pointee.d_name, { String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8) }), name != ".", name != ".." else { continue }
                var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child >= 0 { cleanContents(child, depth: depth + 1); close(child) }
                    _ = unlinkat(fd, name, AT_REMOVEDIR)
                } else { _ = unlinkat(fd, name, 0) }
            }
        }
    }
    static func isHidden(_ path: String) -> Bool { path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" } }
    static func safePath(_ path: String, directory: Bool, maxDepth: Int = 64) throws -> String {
        let value = directory ? String(path.drop(while: { $0 == "/" }).reversed().drop(while: { $0 == "/" }).reversed()) : path
        guard !path.hasPrefix("/"), !value.isEmpty, value.utf8.count <= 16_384, !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure(message: "压缩包包含不安全或无效路径。") }
        let pieces = value.split(separator: "/", maxSplits: max(0, maxDepth), omittingEmptySubsequences: false)
        guard maxDepth > 0, pieces.count <= maxDepth, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw Failure(message: "压缩包包含不安全或无效路径。") }
        return value
    }
    private static func collisionKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    private static func directoryFD(_ root: Int32, components: [String], create: Bool = true) throws -> Int32 {
        var current = dup(root); guard current >= 0 else { throw posix() }
        do {
            for component in components {
                if create { guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw posix() } }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posix() }; close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    private static func memberFD(_ root: Int32, path: String) throws -> Int32 {
        let parts = try safePath(path, directory: false).split(separator: "/").map(String.init)
        let parent = try directoryFD(root, components: Array(parts.dropLast()), create: false); defer { close(parent) }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw Failure(message: "编辑暂存内容已变化。") }
        return fd
    }
    private static func fileDigest(_ fd: Int32, cancellation: Cancellation) throws -> String {
        var hash = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try cancellation.check(); let amount = pread(fd, &buffer, buffer.count, off_t(offset))
            if amount < 0 && errno == EINTR { continue }; guard amount >= 0 else { throw posix() }; if amount == 0 { break }
            hash.update(data: Data(buffer.prefix(amount))); offset += Int64(amount)
        }
        return hex(hash.finalize())
    }
    private static func writeAll(_ fd: Int32, buffer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let amount = Darwin.write(fd, buffer.advanced(by: offset), count - offset)
            if amount < 0 && errno == EINTR { continue }; guard amount > 0 else { throw posix() }; offset += amount
        }
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
