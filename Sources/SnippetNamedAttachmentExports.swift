import CryptoKit
import Darwin
import Foundation

/// Explicit copy/paste preparation only. These are private delivery copies;
/// immutable library blobs remain the source of truth and belong to backups.
/// No timer removes a URL that a receiving application may still be reading.
enum SnippetNamedAttachmentExports {
    struct Limits { var maximumItems = 64; var maximumBytes = 128 * 1_024 * 1_024 }
    private struct Format: Codable { var schema = 1; var format = "GaoCaoZuo.NamedSnippetAttachmentExports" }
    private struct Identity: Equatable {
        let device: dev_t; let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != ".DS_Store"
            && name.utf8.count <= 240 && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
    }

    static func prepare(data: Data, attachment: SnippetAttachment, directory: URL, limits: Limits = Limits()) throws -> URL {
        guard safeName(attachment.originalName), attachment.byteCount == data.count,
              data.count <= SnippetLibraryStore.maximumAttachmentBytes,
              digest(data) == attachment.sha256, SnippetNativeBackupIO.digest(attachment.sha256),
              limits.maximumItems > 0, limits.maximumItems <= 1_000,
              limits.maximumBytes >= 0, limits.maximumBytes <= 128 * 1_024 * 1_024 else {
            throw DataFailure.message("附件原名包含危险字符、超过 240 字节，或内容摘要／预算无效，未生成副本。")
        }
        let local = LocalData(directory: directory)
        if let issue = local.failure { throw DataFailure.message(issue) }
        let root = try openDirectory(local.directory); defer { close(root) }
        var rootInfo = stat(); guard fstat(root, &rootInfo) == 0 else { throw failure() }
        if let marker = try local.load("format.json", as: Format.self) {
            guard marker.schema == 1, marker.format == Format().format else { throw DataFailure.message("附件导出缓存格式未知，原副本保留，未重新初始化。") }
        } else {
            guard try names(root).isEmpty else { throw DataFailure.message("附件导出目录缺少格式记录但已有内容，未将其当作空目录。") }
            try local.save(Format(), name: "format.json")
        }
        let usage = try scan(root, limits: limits)
        let key = "item-" + digest(Data((attachment.sha256 + "\0" + attachment.originalName).utf8))
        var named = stat()
        if fstatat(root, key, &named, AT_SYMLINK_NOFOLLOW) == 0 {
            guard named.st_mode & S_IFMT == S_IFDIR else { throw failure() }
            try verifyEntry(root: root, name: key, originalName: attachment.originalName, data: data)
            try verifyDirectory(local.directory, identity: Identity(rootInfo))
            return local.directory.appendingPathComponent(key, isDirectory: true).appendingPathComponent(attachment.originalName)
        }
        guard errno == ENOENT else { throw failure() }
        guard usage.items < limits.maximumItems, data.count <= limits.maximumBytes - usage.bytes else {
            throw DataFailure.message("附件导出副本已达到 64 份／128 MB 预算。原库未改变；请在设置中显示导出副本目录，明确清理不再使用的副本后重试。")
        }
        try verifyDirectory(local.directory, identity: Identity(rootInfo))
        let temporary = ".pending-" + UUID().uuidString
        guard mkdirat(root, temporary, 0o700) == 0 else { throw failure() }
        let child = openat(root, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw failure() }; defer { close(child) }
        var childInfo = stat(); guard fstat(child, &childInfo) == 0 else { throw failure() }
        let childIdentity = Identity(childInfo)
        var published = false, createdFile: Identity?
        defer {
            if !published {
                var value = stat()
                if let createdFile, fstatat(child, attachment.originalName, &value, AT_SYMLINK_NOFOLLOW) == 0, Identity(value) == createdFile {
                    _ = unlinkat(child, attachment.originalName, 0)
                }
                if fstatat(root, temporary, &value, AT_SYMLINK_NOFOLLOW) == 0, Identity(value) == childIdentity {
                    _ = unlinkat(root, temporary, AT_REMOVEDIR)
                }
            }
        }
        let output = openat(child, attachment.originalName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure() }; defer { close(output) }
        var fileInfo = stat(); guard fstat(output, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1 else { throw failure() }
        createdFile = Identity(fileInfo)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        guard fsync(output) == 0 else { throw failure() }; _ = fsync(child)
        try verifyFile(child: child, name: attachment.originalName, data: data)
        try verifyDirectory(local.directory, identity: Identity(rootInfo))
        guard fstatat(root, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(named) == childIdentity,
              renameatx_np(root, temporary, root, key, UInt32(RENAME_EXCL)) == 0 else { throw DataFailure.message("附件导出目标在提交前已变化或已存在，未覆盖。") }
        published = true; _ = fsync(root)
        try verifyEntry(root: root, name: key, originalName: attachment.originalName, data: data)
        try verifyDirectory(local.directory, identity: Identity(rootInfo))
        return local.directory.appendingPathComponent(key, isDirectory: true).appendingPathComponent(attachment.originalName)
    }

    private static func scan(_ root: Int32, limits: Limits) throws -> (items: Int, bytes: Int) {
        var count = 0, bytes = 0
        for name in try names(root) where name != "format.json" {
            var info = stat()
            guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
            if name == ".DS_Store" {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= 1_048_576 else { throw failure() }
                bytes += Int(info.st_size); continue
            }
            let expected = name.hasPrefix("item-") && SnippetNativeBackupIO.digest(String(name.dropFirst(5)))
            let pending = name.hasPrefix(".pending-") && UUID(uuidString: String(name.dropFirst(9))) != nil
            guard expected || pending, info.st_mode & S_IFMT == S_IFDIR else { throw failure() }
            count += 1
            let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw failure() }; defer { close(child) }
            let children = try names(child)
            guard children.count <= 2, children.filter({ $0 != ".DS_Store" }).count <= 1 else { throw failure() }
            for filename in children {
                var value = stat()
                guard fstatat(child, filename, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_size >= 0,
                      value.st_size <= limits.maximumBytes - bytes else { throw failure() }
                bytes += Int(value.st_size)
            }
            guard count <= limits.maximumItems, bytes <= limits.maximumBytes else { throw DataFailure.message("附件导出缓存包含遗留或超预算内容，未清理或覆盖。") }
        }
        guard bytes <= limits.maximumBytes else { throw failure() }
        return (count, bytes)
    }

    private static func verifyEntry(root: Int32, name: String, originalName: String, data: Data) throws {
        let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw failure() }; defer { close(child) }
        var opened = stat(), named = stat()
        guard fstat(child, &opened) == 0,
              Set(try names(child)).subtracting([".DS_Store"]) == [originalName] else { throw failure() }
        try verifyFile(child: child, name: originalName, data: data)
        guard fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(opened) == Identity(named), named.st_mode & S_IFMT == S_IFDIR else { throw failure() }
    }

    private static func verifyFile(child: Int32, name: String, data: Data) throws {
        let fd = openat(child, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size == data.count else { throw failure() }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024), count = 0
        while true {
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read < 0, errno == EINTR { continue }
            guard read >= 0, read <= data.count - count else { throw failure() }
            if read == 0 { break }; hasher.update(data: Data(buffer.prefix(read))); count += read
        }
        guard count == data.count, Data(hasher.finalize()) == Data(SHA256.hash(data: data)), fstat(fd, &after) == 0,
              fstatat(child, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(before) == Identity(after), Identity(after) == Identity(named), after.st_nlink == 1,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DataFailure.message("附件导出副本已改变，未覆盖或复制；原库内容仍保留。")
        }
    }

    private static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw failure() }
        guard let stream = fdopendir(copy) else { close(copy); throw failure() }; defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []; errno = 0
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw failure() }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 1_002 else { throw failure() }
            errno = 0
        }
        guard errno == 0 else { throw failure() }; return result
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        var path = directory.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        guard directory.isFileURL, !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw failure() }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard fd >= 0 else { throw failure() }
        for part in path.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(fd)
            guard next >= 0 else { throw failure() }; fd = next
        }
        return fd
    }
    private static func verifyDirectory(_ directory: URL, identity: Identity) throws {
        let checked = try openDirectory(directory); defer { close(checked) }; var info = stat()
        guard fstat(checked, &info) == 0, Identity(info) == identity else { throw failure() }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure() -> DataFailure { .message("附件导出缓存不可读取、包含链接或已变化；未覆盖任何副本。请在设置中显示目录并明确清理。") }
}
