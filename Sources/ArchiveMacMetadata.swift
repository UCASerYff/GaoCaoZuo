import Foundation
import Darwin

/// AppleDouble sidecars keep Finder tags, resource forks and ACLs portable across ZIP/7Z.
/// They are decoded only onto already verified, non-link targets inside the isolated output tree.
enum ArchiveMacMetadata {
    private static let fm = FileManager.default
    /// Foundation intentionally hides some AppleDouble files. Security verification must see
    /// every directory entry, including ._ sidecars, and never descend through a symbolic link.
    static func allURLs(in root: URL) throws -> [URL] {
        var result: [URL] = []
        func walk(_ parent: URL) throws {
            guard let directory = opendir(parent.path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else { if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let url = parent.appendingPathComponent(name); var info = stat()
                guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                result.append(url)
                if info.st_mode & S_IFMT == S_IFDIR { try walk(url) }
            }
        }
        try walk(root); return result
    }
    static func prepare(in input: URL, roots: [String], options: ArchiveCreationOptions) throws -> Bool {
        var pending: [(URL, String)] = []
        for name in roots {
            let root = input.appendingPathComponent(name)
            var paths = [root]
            if (try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory {
                paths.append(contentsOf: try allURLs(in: root))
            }
            for path in paths {
                let relative = String(path.path.dropFirst(input.path.count + 1))
                if options.excludes(relative) { continue }
                let attributes = try fm.attributesOfItem(atPath: path.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                let count = listxattr(path.path, nil, 0, XATTR_NOFOLLOW)
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var hasACL = false
                if let acl = acl_get_file(path.path, ACL_TYPE_EXTENDED) {
                    var entry: acl_entry_t?; hasACL = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
                    acl_free(UnsafeMutableRawPointer(acl))
                }
                if count > 0 || hasACL { pending.append((path, relative)) }
            }
        }
        guard !pending.isEmpty else { return false }
        let metadata = input.appendingPathComponent("__MACOSX", isDirectory: true)
        guard (try? fm.attributesOfItem(atPath: metadata.path)) == nil else { throw ArchiveError.invalid("源文件名 __MACOSX 与系统元数据目录冲突，请调整名称后重试。") }
        for (source, relative) in pending {
            let components = relative.split(separator: "/").map(String.init)
            let actual = components.dropLast().reduce(metadata) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent("._" + components.last!)
            try fm.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard copyfile(source.path, actual.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_XATTR | COPYFILE_ACL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        return true
    }

    static func restore(in root: URL) throws {
        let metadata = root.appendingPathComponent("__MACOSX", isDirectory: true)
        guard (try? fm.attributesOfItem(atPath: metadata.path)[.type] as? FileAttributeType) == .typeDirectory else { return }
        var restored: [URL] = [], directories: [URL] = []
        // Keep the original no-follow walk for both restoration and cleanup.
        // A second Foundation recursive enumeration used to rescan the entire
        // metadata tree and could hide AppleDouble names from cleanup planning.
        for url in try allURLs(in: metadata) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { directories.append(url); continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular, url.lastPathComponent.hasPrefix("._") else { continue }
            let relative = String(url.path.dropFirst(metadata.path.count + 1))
            var components = relative.split(separator: "/").map(String.init)
            components[components.count - 1] = String(components.last!.dropFirst(2))
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ArchiveError.invalid("macOS 元数据目标无效。") }
            let target = components.reduce(root) { $0.appendingPathComponent($1) }
            guard let targetAttributes = try? fm.attributesOfItem(atPath: target.path),
                  [.typeRegular, .typeDirectory].contains(targetAttributes[.type] as? FileAttributeType ?? .typeUnknown) else { continue }
            // Reject any ancestor that is a link, including a package-internal link.
            var parent = target.deletingLastPathComponent()
            while parent.path != root.path {
                guard parent.path.hasPrefix(root.path + "/"), (try fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType) == .typeDirectory else { throw ArchiveError.invalid("macOS 元数据路径包含链接。") }
                parent.deleteLastPathComponent()
            }
            guard (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max <= 64 * 1_024 * 1_024 else { throw ArchiveError.invalid("单个 macOS 元数据记录超过 64 MiB。") }
            let handle = try FileHandle(forReadingFrom: url); let header = try handle.read(upToCount: 4); try handle.close()
            guard header == Data([0, 5, 22, 7]) else { continue }
            guard copyfile(url.path, target.path, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR | COPYFILE_ACL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            restored.append(url)
        }
        for url in restored { try fm.removeItem(at: url) }
        // Preserve unrelated user files in a __MACOSX directory; only remove empty sidecar directories.
        for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory, try fm.contentsOfDirectory(atPath: url.path).isEmpty { try fm.removeItem(at: url) }
        }
        if try fm.contentsOfDirectory(atPath: metadata.path).isEmpty { try fm.removeItem(at: metadata) }
    }
}
