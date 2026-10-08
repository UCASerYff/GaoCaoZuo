import Foundation
import CryptoKit
import Security
import Darwin

struct FavoriteFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
}
struct TextTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var filename: String
    var content: String
}
struct TextSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}
struct WorkflowStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var actionID: String
    var argument: String = ""
}
struct OperationWorkflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep]
}
struct OperationSettings: Codable {
    var schema = 1
    var appearance = "system"
    var favorites = ["new.text", "path.copy", "archive.create", "window.leftHalf", "window.rightHalf", "clipboard.show"]
    var folders: [FavoriteFolder] = []
    var templates: [TextTemplate] = [
        TextTemplate(name: "Markdown", filename: "未命名.md", content: "# 新文档\n\n"),
        TextTemplate(name: "CSV 表格", filename: "未命名.csv", content: "名称,数值,备注\n"),
        TextTemplate(name: "JSON", filename: "未命名.json", content: "{\n}\n")
    ]
    var snippets: [TextSnippet] = []
    var bindings = InputBinding.defaults
    var inputExcludedApps: [String] = []
    var windowDragEnabled = false
    var windowSnapEnabled = false
    var workflows = [OperationWorkflow(name: "左右阅读", steps: [WorkflowStep(actionID: "window.leftHalf")])]
    var clipboardEnabled = false
    var clipboardDays = 7
    var clipboardLimit = 200
    var clipboardExcludedApps = ["com.apple.keychainaccess", "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop"]
    var loginAtStartup = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case schema, appearance, favorites, folders, templates, snippets, bindings, inputExcludedApps, workflows
        case clipboardEnabled, clipboardDays, clipboardLimit, clipboardExcludedApps, loginAtStartup
        case windowDragEnabled, windowSnapEnabled
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        appearance = try container.decode(String.self, forKey: .appearance)
        favorites = try container.decode([String].self, forKey: .favorites)
        folders = try container.decode([FavoriteFolder].self, forKey: .folders)
        templates = try container.decode([TextTemplate].self, forKey: .templates)
        snippets = try container.decode([TextSnippet].self, forKey: .snippets)
        bindings = try container.decode([InputBinding].self, forKey: .bindings)
        // Added before V1 delivery; older valid settings gain an empty exclusion list only.
        inputExcludedApps = container.contains(.inputExcludedApps) ? try container.decode([String].self, forKey: .inputExcludedApps) : []
        windowDragEnabled = container.contains(.windowDragEnabled) ? try container.decode(Bool.self, forKey: .windowDragEnabled) : false
        windowSnapEnabled = container.contains(.windowSnapEnabled) ? try container.decode(Bool.self, forKey: .windowSnapEnabled) : false
        workflows = try container.decode([OperationWorkflow].self, forKey: .workflows)
        clipboardEnabled = try container.decode(Bool.self, forKey: .clipboardEnabled)
        clipboardDays = try container.decode(Int.self, forKey: .clipboardDays)
        clipboardLimit = try container.decode(Int.self, forKey: .clipboardLimit)
        clipboardExcludedApps = try container.decode([String].self, forKey: .clipboardExcludedApps)
        loginAtStartup = try container.decode(Bool.self, forKey: .loginAtStartup)
    }
}
struct ReceiptDocument: Codable { var schema = 1; var records: [FileOperationReceipt] = [] }

enum DataFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class LocalData {
    let directory: URL
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private struct Fingerprint: Equatable {
        let identity: Identity
        let hash: Data
        let size: off_t
        let modified: timespec
        let changed: timespec
        init(_ value: stat, data: Data) {
            identity = Identity(value); hash = Data(SHA256.hash(data: data)); size = value.st_size
            modified = value.st_mtimespec; changed = value.st_ctimespec
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity && lhs.hash == rhs.hash && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
        func matchesAfterRename(_ other: Self) -> Bool {
            identity == other.identity && hash == other.hash && size == other.size
                && modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
        }
    }
    private var fingerprints: [String: Fingerprint] = [:]
    private var knownMissing: Set<String> = []
    private var directoryIdentity: Identity?
    private(set) var failure: String?
    init(directory: URL, createIfMissing: Bool = true) {
        // Only normalize Apple's fixed root aliases; never resolve user-created symlinks.
        var path = directory.standardizedFileURL.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            guard directory.isFileURL, path != "/" else { throw DataFailure.message("资料目录不是有效的本地目录。") }
            let descriptor = try openDirectory(create: createIfMissing)
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixFailure("读取资料目录") }
            directoryIdentity = Identity(info)
            if createIfMissing, fchmod(descriptor, 0o700) != 0 { throw posixFailure("保护资料目录权限") }
        } catch { failure = "资料目录无法读取或创建：\(error.localizedDescription)" }
    }

    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let (data, fingerprint) = try read(name, at: descriptor, maximumSize: 32_000_000) else {
                guard fingerprints[name] == nil else { throw DataFailure.message("\(name) 在运行期间被移除。") }
                knownMissing.insert(name); return nil
            }
            try verifyKnown(name, fingerprint: fingerprint)
            try validateSchema(data, name: name)
            let decoded = try JSONDecoder().decode(type, from: data)
            fingerprints[name] = fingerprint
            knownMissing.remove(name)
            return decoded
        }
    }

    func save<T: Encodable>(_ value: T, name: String) throws {
        try guarded(name) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try validateSchema(data, name: name)
            try write(data, name: name, mustBeNew: false)
        }
    }

    /// Immutable local attachments use the same no-follow and change-detection rules as JSON documents.
    func verifiedData(_ name: String, maximumSize: Int = 32_000_000) throws -> Data {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let (data, fingerprint) = try read(name, at: descriptor, maximumSize: maximumSize) else {
                throw DataFailure.message("资料附件缺失：\(name)")
            }
            try verifyKnown(name, fingerprint: fingerprint)
            fingerprints[name] = fingerprint
            return data
        }
    }

    func createFile(_ data: Data, name: String) throws {
        try guarded(name) { try write(data, name: name, mustBeNew: true) }
    }

    func removeKnownFile(_ name: String) throws {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let expected = fingerprints[name],
                  let (_, actual) = try read(name, at: descriptor, maximumSize: 32_000_000), actual == expected else {
                throw DataFailure.message("附件已变化或缺失，未删除：\(name)")
            }
            let held = ".preserved-\(UUID().uuidString)"
            guard renameatx_np(descriptor, name, descriptor, held, UInt32(RENAME_EXCL)) == 0 else {
                throw posixFailure("暂存待删除附件")
            }
            do {
                guard let (_, displaced) = try read(held, at: descriptor, maximumSize: 32_000_000),
                      displaced.matchesAfterRename(expected) else {
                    throw DataFailure.message("附件在删除前被替换，已保留。")
                }
            } catch {
                _ = renameatx_np(descriptor, held, descriptor, name, UInt32(RENAME_EXCL))
                throw error
            }
            guard unlinkat(descriptor, held, 0) == 0 else { throw posixFailure("删除已验证附件") }
            fingerprints.removeValue(forKey: name); knownMissing.insert(name)
        }
    }

    private func write(_ data: Data, name: String, mustBeNew: Bool) throws {
        guard data.count <= 32_000_000 else { throw DataFailure.message("资料文件过大：\(name)") }
        let descriptor = try checkedDirectory(); defer { close(descriptor) }
        let existing = try read(name, at: descriptor, maximumSize: 32_000_000)
        if let (_, actual) = existing {
            guard !mustBeNew, let expected = fingerprints[name], expected == actual else {
                throw DataFailure.message("\(name) 已存在或已被其他程序修改，拒绝覆盖。")
            }
        } else if fingerprints[name] != nil { throw DataFailure.message("\(name) 在运行期间被移除，拒绝重新创建。") }
        let staged = ".writing-\(UUID().uuidString)"
        let stagedFD = openat(descriptor, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard stagedFD >= 0 else { throw posixFailure("创建资料临时文件") }
        var canRemoveStaged = true
        defer { close(stagedFD); if canRemoveStaged { _ = unlinkat(descriptor, staged, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(stagedFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw posixFailure("写入资料临时文件") }
                offset += result
            }
        }
        guard fsync(stagedFD) == 0 else { throw posixFailure("同步资料文件") }
        // Re-open the full parent chain to detect replacement before committing through the anchored fd.
        let rechecked = try checkedDirectory(); close(rechecked)
        if let (_, expected) = existing {
            guard let (_, latest) = try read(name, at: descriptor, maximumSize: 32_000_000), latest == expected else {
                throw DataFailure.message("\(name) 在保存前被修改，拒绝覆盖。")
            }
            // Swap preserves the displaced file, including a concurrent external update, until checked.
            guard renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_SWAP)) == 0 else {
                throw posixFailure("安全替换资料")
            }
            canRemoveStaged = false
            do {
                guard let (_, displaced) = try read(staged, at: descriptor, maximumSize: 32_000_000),
                      displaced.matchesAfterRename(expected) else {
                    throw DataFailure.message("\(name) 在提交期间被其他程序替换。")
                }
                canRemoveStaged = true
            } catch {
                // Never discard the displaced file. Swap back, retaining the uncommitted version as well.
                _ = renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_SWAP))
                throw DataFailure.message("\(error.localizedDescription) 原文件和临时版本均已保留，已停止写入。")
            }
        } else {
            guard renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                throw posixFailure("排他创建 \(name)；若已出现同名文件则不会覆盖")
            }
        }
        guard let (_, saved) = try read(name, at: descriptor, maximumSize: 32_000_000), saved.hash == Data(SHA256.hash(data: data)) else {
            canRemoveStaged = false
            throw DataFailure.message("\(name) 在写入后被修改，旧文件已保留，已停止写入。")
        }
        fingerprints[name] = saved; knownMissing.remove(name)
        _ = fsync(descriptor)
    }

    private func validateSchema(_ data: Data, name: String) throws {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dictionary = json as? [String: Any], let raw = dictionary["schema"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 1,
                  number.doubleValue == 1 else { throw DataFailure.message("\(name) 的资料格式版本不受支持，请保留原文件。") }
        }
    }

    private func verifyKnown(_ name: String, fingerprint: Fingerprint) throws {
        if knownMissing.contains(name) { throw DataFailure.message("\(name) 在运行期间由外部新增，拒绝覆盖或接管。") }
        if let expected = fingerprints[name], expected != fingerprint { throw DataFailure.message("\(name) 已被其他程序修改，已停止写入。") }
    }

    private func checkedDirectory() throws -> Int32 {
        let descriptor = try openDirectory(create: false)
        var info = stat()
        guard fstat(descriptor, &info) == 0, directoryIdentity == Identity(info) else {
            close(descriptor); throw DataFailure.message("资料目录已被替换，已停止写入。")
        }
        return descriptor
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure("打开本地根目录") }
        do {
            for component in directory.path.split(separator: "/").map(String.init) {
                var info = stat()
                if fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    let code = errno
                    guard code == ENOENT, create else { throw posixFailure("读取资料父目录 \(component)", code: code) }
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw posixFailure("创建资料目录 \(component)") }
                } else if info.st_mode & S_IFMT != S_IFDIR { throw DataFailure.message("资料父路径不是常规目录或包含符号链接：\(component)") }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixFailure("安全打开资料目录 \(component)") }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func read(_ name: String, at descriptor: Int32, maximumSize: Int) throws -> (Data, Fingerprint)? {
        var pathInfo = stat()
        if fstatat(descriptor, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw posixFailure("检查资料 \(name)", code: code)
        }
        guard pathInfo.st_mode & S_IFMT == S_IFREG, pathInfo.st_nlink == 1,
              pathInfo.st_size >= 0, pathInfo.st_size <= maximumSize else {
            throw DataFailure.message("资料不是常规独立文件、含符号链接或大小异常：\(name)")
        }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixFailure("读取资料 \(name)") }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, Identity(before) == Identity(pathInfo), before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size <= maximumSize else { throw DataFailure.message("资料在打开期间被替换：\(name)") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let amount = Darwin.read(file, &buffer, buffer.count)
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw posixFailure("读取资料内容 \(name)") }
            if amount == 0 { break }
            guard result.count + amount <= maximumSize else { throw DataFailure.message("资料超过读取预算：\(name)") }
            result.append(contentsOf: buffer.prefix(amount))
        }
        var after = stat(), latestPath = stat()
        guard fstat(file, &after) == 0, fstatat(descriptor, name, &latestPath, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(after) == Identity(latestPath), Fingerprint(before, data: result) == Fingerprint(after, data: result),
              result.count == after.st_size else { throw DataFailure.message("资料在读取期间发生变化：\(name)") }
        return (result, Fingerprint(after, data: result))
    }

    private func guarded<T>(_ name: String, _ action: () throws -> T) throws -> T {
        if let failure { throw DataFailure.message(failure) }
        do {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw DataFailure.message("资料文件名无效。")
            }
            return try action()
        } catch {
            failure = "无法处理 \(name)，原资料已保留，已停止写入：\(error.localizedDescription)"
            throw DataFailure.message(failure!)
        }
    }
    private func posixFailure(_ operation: String, code: Int32 = errno) -> DataFailure {
        .message("\(operation)失败：\(String(cString: strerror(code)))（\(code)）")
    }
    func block(_ text: String) { failure = text }
}

enum PasswordVault {
    private static let service = "com.gaoseries.GaoCaoZuo.archives"
    static func save(_ password: String, account: String) throws {
        guard !password.isEmpty else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(password.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = base; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw DataFailure.message("钥匙串保存失败（\(result)）。") }
        } else if status != errSecSuccess { throw DataFailure.message("钥匙串更新失败（\(status)）。") }
    }
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw DataFailure.message("钥匙串读取失败（\(status)）。") }
        return text
    }
}
