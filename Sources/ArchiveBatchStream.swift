import Foundation
import Darwin
import CryptoKit

/// A bounded job-local copy prevents a path replacement between the checked
/// directory and the decoder's open. The original FD remains pinned until the
/// last verification; content hashes, not mtime/size cache keys, decide validity.
final class ArchiveBatchSnapshot: @unchecked Sendable {
    let url: URL
    private let original: URL
    private let sourceFD: Int32
    private let identity: stat
    private let digest: Data
    private let cancellation: ArchiveCreationIO.Cancellation
    private init(url: URL, original: URL, sourceFD: Int32, identity: stat, digest: Data, cancellation: ArchiveCreationIO.Cancellation) {
        self.url = url; self.original = original; self.sourceFD = sourceFD; self.identity = identity; self.digest = digest; self.cancellation = cancellation
    }
    deinit { close(sourceFD) }
    static func capture(_ source: URL, in directory: URL, maximumBytes: UInt64, cancellation: ArchiveCreationIO.Cancellation) throws -> ArchiveBatchSnapshot {
        // Reject a replaced FIFO/device before any potentially blocking read.
        // Regular files ignore O_NONBLOCK; fstat below still decides the type.
        let fd = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var keep = false; defer { if !keep { close(fd) } }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              UInt64(before.st_size) <= maximumBytes else { throw ArchiveError.invalid("压缩包不是普通文件或超过当前隔离副本容量预算。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(source.lastPathComponent)
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var outputOpen = true
        var digest = SHA256(); var bytes = [UInt8](repeating: 0, count: 1_048_576); var copied: UInt64 = 0
        do {
            while true {
                try cancellation.check()
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if count == 0 { break }
                guard UInt64(count) <= UInt64(before.st_size) - copied else { throw FileToolsError.changed(source) }
                copied += UInt64(count)
                digest.update(data: Data(bytes.prefix(count)))
                try bytes.withUnsafeBytes { pointer in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, pointer.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                        offset += written
                    }
                }
            }
            guard copied == UInt64(before.st_size) else { throw FileToolsError.changed(source) }
            // close(2) may already have consumed the descriptor on error; do not
            // close it a second time and risk closing a reused descriptor.
            outputOpen = false
            let code = close(output)
            if code != 0 { throw ArchiveError.invalid("无法完成压缩包隔离副本写入。") }
        } catch { if outputOpen { close(output) }; throw error }
        let expected = Data(digest.finalize())
        let value = ArchiveBatchSnapshot(url: url, original: source, sourceFD: fd, identity: before, digest: expected, cancellation: cancellation)
        keep = true
        try value.verify()
        guard try FileTools.sha256(url) == expected.map({ String(format: "%02x", $0) }).joined() else { throw ArchiveError.invalid("压缩包隔离副本核验失败。") }
        return value
    }
    func verify() throws {
        try cancellation.check()
        var info = stat(), path = stat()
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        guard fstat(sourceFD, &info) == 0, lstat(original.path, &path) == 0, same(identity, info), same(identity, path), lseek(sourceFD, 0, SEEK_SET) == 0 else { throw FileToolsError.changed(original) }
        var hash = SHA256(); var bytes = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try cancellation.check()
            let count = Darwin.read(sourceFD, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { break }; hash.update(data: Data(bytes.prefix(count)))
        }
        guard Data(hash.finalize()) == digest, fstat(sourceFD, &info) == 0, lstat(original.path, &path) == 0, same(identity, info), same(identity, path) else { throw FileToolsError.changed(original) }
    }
}

/// A decoder only emits framed bytes. Only this parent-side writer can create files,
/// relative to a pinned, private staging directory. Names come from the checked index,
/// never from decoder output. Frames are UInt32 index + UInt64 byte count, big endian.
final class ArchiveBatchStream: @unchecked Sendable {
    private let lock = NSLock()
    private let rootFD: Int32
    private let rootURL: URL
    private let rootIdentity: stat
    private let entries: [ArchiveEntry]
    private let expectedTotal: UInt64
    private var totalWritten: UInt64 = 0
    private var pending = Data()
    private var seen = Set<Int>()
    private var currentFD: Int32 = -1
    private var remaining: UInt64 = 0
    private var ended = false
    private var message: String?

    init(root: URL, entries: [ArchiveEntry]) throws {
        rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var identity = stat()
        guard fstat(rootFD, &identity) == 0 else { close(rootFD); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        rootURL = root; rootIdentity = identity
        self.entries = entries
        expectedTotal = entries.reduce(UInt64(0)) { value, entry in value.addingReportingOverflow(entry.size).overflow ? UInt64.max : value + entry.size }
        do {
            var total: UInt64 = 0
            for entry in entries {
                try ArchiveService.validateArchivePath(entry.path)
                guard !entry.isDirectory, entry.symbolicLink == nil, entry.hardLink == nil,
                      entry.size <= UInt64.max - total else { throw ArchiveError.invalid("批量提取目录无效。") }
                total += entry.size
            }
        } catch { close(rootFD); throw error }
    }
    deinit { if currentFD >= 0 { close(currentFD) }; close(rootFD) }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return message }
    var completedCount: Int { lock.lock(); defer { lock.unlock() }; return seen.count - (currentFD >= 0 ? 1 : 0) }
    var entryCount: Int { entries.count }
    var progressValue: Double {
        lock.lock(); defer { lock.unlock() }
        return expectedTotal > 0 ? Double(totalWritten) / Double(expectedTotal) : Double(seen.count) / Double(max(1, entries.count))
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard message == nil, !chunk.isEmpty else { return }
        do {
            guard !ended else { throw ArchiveError.invalid("批量解压结束标记之后仍有数据。") }
            pending.append(chunk)
            while !pending.isEmpty {
                if currentFD >= 0 {
                    let count = Int(min(remaining, UInt64(pending.count)))
                    if count > 0 {
                        try pending.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < count {
                                let written = Darwin.write(currentFD, bytes.baseAddress!.advanced(by: offset), count - offset)
                                if written < 0, errno == EINTR { continue }
                                guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                                offset += written
                            }
                        }
                        pending.removeFirst(count); remaining -= UInt64(count); totalWritten += UInt64(count)
                    }
                    if remaining == 0 { try closeCurrentFile() }
                    continue
                }
                guard pending.count >= 12 else { break }
                let header = Array(pending.prefix(12)); pending.removeFirst(12)
                let index = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let length = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if index == UInt32.max {
                    guard length == 0, seen.count == entries.count, pending.isEmpty else { throw ArchiveError.invalid("批量解压结束标记或项目数不符。") }
                    ended = true; break
                }
                guard Int(index) < entries.count, seen.insert(Int(index)).inserted,
                      length == entries[Int(index)].size else { throw ArchiveError.invalid("批量解压项目重复、大小或身份不符。") }
                currentFD = try makeFile(entries[Int(index)].path); remaining = length
                if length == 0 { try closeCurrentFile() }
            }
        } catch { message = "批量解压流未通过核验：" + error.localizedDescription; if currentFD >= 0 { close(currentFD); currentFD = -1 } }
    }

    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        if currentFD >= 0 { close(currentFD); currentFD = -1 }
        if let message { throw ArchiveError.invalid(message) }
        guard ended, pending.isEmpty, remaining == 0, seen.count == entries.count else {
            throw ArchiveError.invalid("批量解压流不完整，未提交结果。")
        }
        var bound = stat(), path = stat()
        guard fstat(rootFD, &bound) == 0, lstat(rootURL.path, &path) == 0,
              bound.st_dev == rootIdentity.st_dev, bound.st_ino == rootIdentity.st_ino,
              path.st_dev == rootIdentity.st_dev, path.st_ino == rootIdentity.st_ino,
              path.st_mode & S_IFMT == S_IFDIR else { throw ArchiveError.invalid("批量解压暂存根已改变，未提交结果。") }
    }
    private func closeCurrentFile() throws {
        let fd = currentFD; currentFD = -1
        guard close(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func makeFile(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(rootFD)
        guard parent >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(parent) }
        for part in parts.dropLast() {
            if mkdirat(parent, part, 0o700) != 0, errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ArchiveError.invalid("批量解压路径祖先不再是安全文件夹。") }
            close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }
}
