import Foundation
import CryptoKit
import Darwin

/// Descriptor based, no-follow snapshot/copy primitives. A missing optional root is distinct from an unreadable one.
enum ScreenshotMigrationIO {
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]; return e }
    static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) }
    static func path(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        if p == "/tmp" || p.hasPrefix("/tmp/") || p == "/var" || p.hasPrefix("/var/") { p = "/private" + p }
        return p
    }
    static func contains(_ parent: URL, _ child: URL) -> Bool { let a = path(parent), b = path(child); return a == b || b.hasPrefix(a + "/") }
    static func fail(_ message: String) -> ScreenshotMigrationError { .invalid(message) }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(path(url), &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw fail("资料路径状态无法读取：" + path(url))
    }
    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard url.isFileURL else { throw fail("只支持明确本地资料路径。") }
        let p = path(url)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail("无法打开资料路径根目录。") }
        do {
            for component in p.split(separator: "/").map(String.init) {
                guard component != ".", component != "..", !component.contains("\0") else { throw fail("资料目录路径越界。") }
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw fail("资料目录无法创建。") }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw fail("资料目录缺失、不可读或包含符号链接：" + p) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func createDirectory(_ url: URL) throws { let fd = try directory(url, create: true); defer { close(fd) }; var s = stat(); guard fstat(fd, &s) == 0, s.st_uid == geteuid() else { throw fail("资料写入目录不属于当前用户。") } }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func regular(_ s: stat) throws { guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1, s.st_uid == geteuid() else { throw fail("资料含链接、特殊文件或其他用户文件，已停止，不能忽略或按空白覆盖。") } }
    static func read(_ url: URL, maximum: Int64 = 268_435_456) throws -> Data {
        let parent = try directory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw fail("主记录缺失或不可读取：" + url.lastPathComponent) }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw fail("主记录状态读取失败。") }; try regular(before)
        guard before.st_size <= maximum else { throw fail("主记录超过安全读取预算，已停止。") }
        var result = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(fd, &chunk, chunk.count); if count == 0 { break }; guard count > 0, Int64(result.count + count) <= maximum else { throw fail("主记录读取失败或读取时增大。") }; result.append(contentsOf: chunk.prefix(count)) }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0, same(before, after), same(before, named) else { throw fail("主记录在读取时改变，已停止。") }
        return result
    }
    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: read(url)) }
        catch { throw fail("资料或迁移日志缺失、损坏或版本不支持：" + url.lastPathComponent + "；" + error.localizedDescription) }
    }
    static func snapshot(id: String, url: URL, required: Bool, allowBundleLinks: Bool = false) throws -> ScreenshotMigrationSnapshot {
        guard try exists(url) else {
            guard !required else { throw fail("必须保留的来源资料缺失：" + path(url)) }
            return .init(id: id, originalPath: path(url), existed: false, isDirectory: false, inventory: [:])
        }
        let parent = try directory(url.deletingLastPathComponent()); defer { close(parent) }
        var rootInfo = stat(); guard fstatat(parent, url.lastPathComponent, &rootInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail("来源目录状态读取失败。") }
        var entries: [String: ScreenshotMigrationEntry] = [:]
        if rootInfo.st_mode & S_IFMT == S_IFDIR {
            let root = try directory(url); defer { close(root) }
            try visit(fd: root, url: url, relative: "", entries: &entries, allowBundleLinks: allowBundleLinks)
            var after = stat(); guard fstatat(parent, url.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0, same(rootInfo, after) else { throw fail("来源目录在盘点期间改变。") }
            return .init(id: id, originalPath: path(url), existed: true, isDirectory: true, inventory: entries)
        }
        try regular(rootInfo)
        entries["@file"] = try fileEntry(parent: parent, name: url.lastPathComponent, expected: rootInfo)
        return .init(id: id, originalPath: path(url), existed: true, isDirectory: false, inventory: entries)
    }
    private static func visit(fd: Int32, url: URL, relative: String, entries: inout [String: ScreenshotMigrationEntry], allowBundleLinks: Bool) throws {
        var before = stat(); guard fstat(fd, &before) == 0, before.st_uid == geteuid() else { throw fail("资料目录身份无法核验。") }
        // Foundation lists names only; each object is independently opened against the pinned parent descriptor below.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        for name in names {
            guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw fail("资料文件名损坏。") }
            let rel = relative.isEmpty ? name : relative + "/" + name
            var s = stat(); guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail("资料项无法读取：" + rel) }
            if s.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard child >= 0 else { throw fail("资料目录无法安全读取。") }; defer { close(child) }
                var checked = stat(); guard fstat(child, &checked) == 0, same(s, checked) else { throw fail("资料目录身份在读取时变化。") }
                entries[rel] = .init(kind: "directory", bytes: 0, sha256: "")
                try visit(fd: child, url: url.appendingPathComponent(name), relative: rel, entries: &entries, allowBundleLinks: allowBundleLinks)
            } else if s.st_mode & S_IFMT == S_IFLNK {
                guard allowBundleLinks, let bundleEnd = rel.range(of: ".app/"), s.st_uid == geteuid() else { throw fail("资料含符号链接，不能跳过引用实物：" + rel) }
                var buffer = [UInt8](repeating: 0, count: 16384)
                let size = readlinkat(fd, name, &buffer, buffer.count)
                guard size > 0, size < buffer.count, let target = String(bytes: buffer.prefix(size), encoding: .utf8), !target.hasPrefix("/") else { throw fail("备份程序符号链接损坏或越界。") }
                let bundle = String(rel[..<bundleEnd.upperBound]).dropLast()
                let resolved = URL(fileURLWithPath: "/" + rel).deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                guard resolved == "/" + bundle || resolved.hasPrefix("/" + bundle + "/") else { throw fail("备份程序符号链接指向包外，未忽略其目标。") }
                entries[rel] = .init(kind: "symlink", bytes: Int64(size), sha256: sha(Data(target.utf8)), linkTarget: target)
            } else { entries[rel] = try fileEntry(parent: fd, name: name, expected: s) }
        }
        var after = stat(); guard fstat(fd, &after) == 0, same(before, after) else { throw fail("资料目录在盘点时发生变化。") }
    }
    private static func fileEntry(parent: Int32, name: String, expected: stat) throws -> ScreenshotMigrationEntry {
        try regular(expected)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw fail("附件缺失或不可读取：" + name) }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, same(before, expected) else { throw fail("附件身份发生变化。") }
        var digest = SHA256(); var chunk = [UInt8](repeating: 0, count: 1_048_576); var count: Int64 = 0
        while true { let n = Darwin.read(fd, &chunk, chunk.count); if n == 0 { break }; guard n > 0 else { throw fail("附件读取失败。") }; digest.update(data: Data(chunk.prefix(n))); count += Int64(n) }
        var after = stat(), named = stat(); guard fstat(fd, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(before, after), same(before, named), count == before.st_size else { throw fail("附件在盘点期间改变。") }
        return .init(kind: "file", bytes: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func requireSnapshot(_ expected: ScreenshotMigrationSnapshot, at url: URL) throws {
        let actual = try snapshot(id: expected.id, url: url, required: true, allowBundleLinks: expected.id != "Source" && expected.id != "Target")
        guard actual.existed == expected.existed, actual.isDirectory == expected.isDirectory, actual.inventory == expected.inventory else { throw fail("归档、暂存或恢复演练的附件/目录摘要不符，已停止。") }
    }
    static func copy(_ snapshot: ScreenshotMigrationSnapshot, to destination: URL) throws {
        guard snapshot.existed else { throw fail("不能为空缺来源构造备份。") }
        let source = URL(fileURLWithPath: snapshot.originalPath)
        if !snapshot.isDirectory { try copyFile(from: source, to: destination, expected: snapshot.inventory["@file"]!); return }
        try createDirectory(destination)
        for (rel, entry) in snapshot.inventory.sorted(by: { $0.key < $1.key }) {
            let target = destination.appendingPathComponent(rel)
            switch entry.kind {
            case "directory": try createDirectory(target)
            case "file": try copyFile(from: source.appendingPathComponent(rel), to: target, expected: entry)
            case "symlink":
                try createDirectory(target.deletingLastPathComponent())
                if try !exists(target) {
                    let parent = try directory(target.deletingLastPathComponent()); defer { close(parent) }
                    guard symlinkat(entry.linkTarget!, parent, target.lastPathComponent) == 0 else { throw fail("备份程序链接无法完整保留。") }
                }
            default: throw fail("库存包含未知文件类型。")
            }
        }
        try requireSnapshot(snapshot, at: destination)
    }
    /// Streaming copies are published only after their digest matches. Partial data stays in TempWrites.noindex for recovery/audit.
    static func copyFile(from source: URL, to target: URL, expected: ScreenshotMigrationEntry) throws {
        if try exists(target) {
            let actual = try snapshot(id: "File", url: target, required: true)
            guard actual.inventory["@file"] == expected else { throw fail("目标或部分归档文件已存在且摘要冲突；保留双方，未覆盖。") }; return
        }
        try createDirectory(target.deletingLastPathComponent())
        let sourceParent = try directory(source.deletingLastPathComponent()); defer { close(sourceParent) }
        let sourceFD = openat(sourceParent, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard sourceFD >= 0 else { throw fail("待复制附件缺失或不可读取。") }; defer { close(sourceFD) }
        var before = stat(); guard fstat(sourceFD, &before) == 0 else { throw fail("待复制附件状态不可读取。") }; try regular(before)
        let work = try tempWork(near: target)
        let workFD = try directory(work); defer { close(workFD) }
        let temporaryName = UUID().uuidString + ".partial"
        let output = openat(workFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard output >= 0 else { throw fail("归档暂存无法创建。") }; defer { close(output) }
        var digest = SHA256(); var chunk = [UInt8](repeating: 0, count: 1_048_576); var count: Int64 = 0
        while true {
            let n = Darwin.read(sourceFD, &chunk, chunk.count); if n == 0 { break }; guard n > 0 else { throw fail("附件复制读取失败。") }
            let data = Data(chunk.prefix(n)); digest.update(data: data); count += Int64(n)
            try data.withUnsafeBytes { raw in var offset = 0; while offset < n { let wrote = Darwin.write(output, raw.baseAddress!.advanced(by: offset), n - offset); guard wrote > 0 else { throw fail("附件复制写入失败；部分副本已保留。") }; offset += wrote } }
        }
        var after = stat(), named = stat(); let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(sourceFD, &after) == 0, fstatat(sourceParent, source.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(before, named), count == expected.bytes, hash == expected.sha256, fsync(output) == 0 else { throw fail("复制时资料变化或摘要不符，完整来源与部分副本已保留。") }
        let parent = try directory(target.deletingLastPathComponent()); defer { close(parent) }
        guard renameatx_np(workFD, temporaryName, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0, fsync(parent) == 0 else { throw fail("附件提交失败或目标冲突，未覆盖目标。") }
    }
    static func writeNew(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        let parent = try directory(url.deletingLastPathComponent()); defer { close(parent) }
        let work = try tempWork(near: url), workFD = try directory(work); defer { close(workFD) }
        let name = UUID().uuidString + ".partial"
        let fd = openat(workFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard fd >= 0 else { throw fail("迁移记录暂存无法创建。") }; defer { close(fd) }
        try data.withUnsafeBytes { raw in var offset = 0; while offset < data.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset); guard n > 0 else { throw fail("迁移记录写入中断；未发布部分记录。") }; offset += n } }
        guard fsync(fd) == 0, renameatx_np(workFD, name, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0, fsync(parent) == 0 else { throw fail("迁移记录提交失败或已存在。") }
    }
    static func writeOrVerify(_ data: Data, to url: URL) throws {
        if try exists(url) { guard try read(url) == data else { throw fail("迁移暂存已有不同记录，未覆盖。") } }
        else { try writeNew(data, to: url) }
    }
    /// Publish a new live-module fact from private same-filesystem staging, without requiring a noindex live root.
    static func publishNew(_ data: Data, to url: URL, stagingRoot: URL) throws {
        guard stagingRoot.pathComponents.contains(where: { $0.hasSuffix(".noindex") }), try !exists(url) else { throw fail("新收据目标已存在或暂存缺少.noindex保护，未覆盖。") }
        try createDirectory(stagingRoot)
        let staged = stagingRoot.appendingPathComponent(UUID().uuidString + ".json")
        try writeNew(data, to: staged)
        let source = try directory(stagingRoot), target = try directory(url.deletingLastPathComponent())
        defer { close(source); close(target) }
        guard renameatx_np(source, staged.lastPathComponent, target, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
              fsync(target) == 0 else { throw fail("收据发布失败或目标冲突；来源和暂存均保留，未覆盖。") }
    }
    static func replace(_ data: Data, at url: URL, expectedRaw: Data? = nil) throws {
        let before = try read(url)
        if let expectedRaw { guard before == expectedRaw else { throw fail("迁移日志已偏离已读取的事务，未覆盖。") } }
        let work = try tempWork(near: url).appendingPathComponent(UUID().uuidString + ".json")
        try writeNew(data, to: work)
        guard try read(url) == before else { throw fail("迁移日志并发改变，未覆盖。") }
        let source = try directory(work.deletingLastPathComponent()), target = try directory(url.deletingLastPathComponent()); defer { close(source); close(target) }
        guard renameat(source, work.lastPathComponent, target, url.lastPathComponent) == 0, fsync(target) == 0 else { throw fail("迁移日志原子提交失败。") }
    }
    private static func tempWork(near url: URL) throws -> URL {
        // Pick the nearest noindex ancestor so copies stay on the same filesystem and no App is exposed to indexing.
        var parent = url.deletingLastPathComponent(), outermost: URL?
        while parent.path != "/" { if parent.lastPathComponent.hasSuffix(".noindex") { outermost = parent }; parent.deleteLastPathComponent() }
        guard let outermost else { throw fail("迁移临时写入缺少.noindex祖先。") }
        let work = outermost.appendingPathComponent("TempWrites.noindex")
        try createDirectory(work); return work
    }
}
