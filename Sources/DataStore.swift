import Foundation
import CryptoKit
import Security
import Darwin

struct FavoriteFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var sourceRoles: [String]? = nil
    var isCommon: Bool { sourceRoles?.contains("common") ?? true }
    var isSend: Bool { sourceRoles?.contains("send") ?? true }
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
    var language = "system"
    var showMenuBarIcon = true
    var playNewFileSound = false
    var statusBarLeftClick = "panel"
    var favorites = ["new.text", "path.copy", "archive.create", "window.leftHalf", "window.rightHalf", "clipboard.show"]
    var folders: [FavoriteFolder] = []
    var templates: [TextTemplate] = [
        TextTemplate(name: "Markdown", filename: "未命名.md", content: "# 新文档\n\n"),
        TextTemplate(name: "CSV 表格", filename: "未命名.csv", content: "名称,数值,备注\n"),
        TextTemplate(name: "JSON", filename: "未命名.json", content: "{\n}\n")
    ]
    var snippets: [TextSnippet] = []
    var lastSnippetID: UUID?
    var bindings = InputBinding.defaults
    var inputExcludedApps: [String] = []
    var windowDragEnabled = false
    var windowSnapEnabled = false
    var windowEnhancements = WindowEnhancementConfiguration()
    var inputEnhancements = InputEnhancementConfiguration()
    var desktopOverview = DesktopOverviewPreferences()
    var localLock = LocalLockConfiguration()
    var desktopMigrationIDs: [String] = []
    var autoInput = AutoInputConfiguration()
    var flyKey = FlyKeyConfiguration()
    var cleanerDurationSeconds = 180
    var workflows = [OperationWorkflow(name: "左右阅读", steps: [WorkflowStep(actionID: "window.leftHalf")])]
    var clipboardEnabled = false
    var clipboardDays = 7
    var clipboardLimit = 200
    var clipboardExcludedApps = ["com.apple.keychainaccess", "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop"]
    var loginAtStartup = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case schema, appearance, language, favorites, folders, templates, snippets, lastSnippetID, bindings, inputExcludedApps, workflows
        case clipboardEnabled, clipboardDays, clipboardLimit, clipboardExcludedApps, loginAtStartup
        case windowDragEnabled, windowSnapEnabled
        case windowEnhancements, inputEnhancements, autoInput, flyKey, cleanerDurationSeconds
        case desktopOverview, localLock, desktopMigrationIDs
        case showMenuBarIcon,playNewFileSound,statusBarLeftClick
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        appearance = try container.decode(String.self, forKey: .appearance)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "system"
        showMenuBarIcon = try container.decodeIfPresent(Bool.self,forKey:.showMenuBarIcon) ?? true
        playNewFileSound = try container.decodeIfPresent(Bool.self,forKey:.playNewFileSound) ?? false
        statusBarLeftClick = try container.decodeIfPresent(String.self,forKey:.statusBarLeftClick) ?? "panel"
        favorites = try container.decode([String].self, forKey: .favorites)
        folders = try container.decode([FavoriteFolder].self, forKey: .folders)
        templates = try container.decode([TextTemplate].self, forKey: .templates)
        snippets = try container.decode([TextSnippet].self, forKey: .snippets)
        lastSnippetID = try container.decodeIfPresent(UUID.self, forKey: .lastSnippetID)
        bindings = try container.decode([InputBinding].self, forKey: .bindings)
        // Added before V1 delivery; older valid settings gain an empty exclusion list only.
        inputExcludedApps = container.contains(.inputExcludedApps) ? try container.decode([String].self, forKey: .inputExcludedApps) : []
        windowDragEnabled = container.contains(.windowDragEnabled) ? try container.decode(Bool.self, forKey: .windowDragEnabled) : false
        windowSnapEnabled = container.contains(.windowSnapEnabled) ? try container.decode(Bool.self, forKey: .windowSnapEnabled) : false
        windowEnhancements = try container.decodeIfPresent(WindowEnhancementConfiguration.self, forKey: .windowEnhancements) ?? .init()
        inputEnhancements = try container.decodeIfPresent(InputEnhancementConfiguration.self, forKey: .inputEnhancements) ?? .init()
        desktopOverview = try container.decodeIfPresent(DesktopOverviewPreferences.self, forKey: .desktopOverview) ?? .init()
        localLock = try container.decodeIfPresent(LocalLockConfiguration.self, forKey: .localLock) ?? .init()
        _ = try desktopOverview.validated()
        desktopMigrationIDs = try container.decodeIfPresent([String].self, forKey: .desktopMigrationIDs) ?? []
        guard desktopMigrationIDs.count <= 128, Set(desktopMigrationIDs).count == desktopMigrationIDs.count else { throw DataFailure.message("桌面迁移依据无效，已停止写入。") }
        autoInput = try container.decodeIfPresent(AutoInputConfiguration.self, forKey: .autoInput) ?? .init()
        flyKey = try container.decodeIfPresent(FlyKeyConfiguration.self, forKey: .flyKey) ?? .init()
        cleanerDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .cleanerDurationSeconds) ?? 180
        guard (30...180).contains(cleanerDurationSeconds) else { throw DataFailure.message("清洁模式时限无效，已保留资料并停止写入。") }
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
    var errorDescription: String? { if case .message(let text) = self { return L10n.text(text) }; return nil }
}

struct LocalDataDirectoryIdentity: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
}
struct LocalDataRetirementFileIdentity: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var sha256: String
}
struct LocalDataRetirementSnapshot {
    var data: Data
    var identity: LocalDataRetirementFileIdentity
}
struct LocalDataRetirementWriteError: LocalizedError {
    var journalCommitted: Bool
    var cleanupComplete: Bool
    var underlyingMessage: String
    var errorDescription: String? { underlyingMessage }
}

private struct LocalDataDesktopRetirementIntent: Codable, Equatable {
    var schema = 1
    var transactionID: String
    var directoryPath: String
    var directoryIdentity: LocalDataDirectoryIdentity
    var journalFilename: String
    var original: LocalDataRetirementFileIdentity
    var stage: LocalDataRetirementFileIdentity
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
        } catch { failure = L10n.format("资料目录无法读取或创建：%@", String(describing: (error.localizedDescription))) }
    }

    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let (data, fingerprint) = try read(name, at: descriptor, maximumSize: 32_000_000) else {
                guard fingerprints[name] == nil else { throw DataFailure.message(L10n.format("%@ 在运行期间被移除。", String(describing: (name)))) }
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
                throw DataFailure.message(L10n.format("资料附件缺失：%@", String(describing: (name))))
            }
            try verifyKnown(name, fingerprint: fingerprint)
            fingerprints[name] = fingerprint
            return data
        }
    }

    func verifiedDirectoryIdentity() throws -> LocalDataDirectoryIdentity {
        try guarded(LegacyDesktopMigrationImporter.journalFilename) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixFailure("核对封存根目录") }
            return LocalDataDirectoryIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
        }
    }

    func retirementFileSnapshot(_ name: String) throws -> LocalDataRetirementSnapshot {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let (data, fingerprint) = try read(name, at: descriptor, maximumSize: 32_000_000) else {
                throw DataFailure.message("桌面迁移日志缺失；不能封存空白日志。")
            }
            try verifyKnown(name, fingerprint: fingerprint)
            fingerprints[name] = fingerprint; knownMissing.remove(name)
            return .init(data: data, identity: retirementIdentity(fingerprint))
        }
    }

    /// Dedicated, recoverable compaction transaction. The ordinary JSON writer
    /// deliberately remains unchanged. A durable intent binds both file inodes
    /// before swap, so a crash never turns an unowned raw file into cleanup work.
    func retireLegacyDesktopJournal(_ data: Data, plan: LegacyDesktopSourceRetirementPlan,
                                    beforeCommit: () throws -> Void,
                                    fault: ((LegacyDesktopMigrationFaultPoint) throws -> Void)? = nil) throws {
        var committed = false
        var cleanupComplete = false
        do {
            if let failure { throw DataFailure.message(failure) }
            _ = try plan.validated()
            let compacted = try LegacyDesktopMigrationJournalValidator.decode(data)
            let name = LegacyDesktopMigrationImporter.journalFilename
            guard compacted.schema == 2, plan.journalFilename == name, plan.targetDirectoryPath == directory.path,
                  LegacyDesktopMigrationJournalValidator.isSHA256(plan.approvalDigest),
                  LegacyDesktopMigrationCoding.digest(data) == plan.afterExpectedRawSHA256,
                  data.count <= 32_000_000 else { throw DataFailure.message("桌面封存写入方案不一致。") }
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            var root = stat()
            guard fstat(descriptor, &root) == 0,
                  LocalDataDirectoryIdentity(device: UInt64(bitPattern: Int64(root.st_dev)), inode: UInt64(root.st_ino)) == plan.targetDirectoryIdentity else {
                throw DataFailure.message("封存根目录身份已变化。")
            }
            let stageName = ".retiring-desktop-" + plan.approvalDigest + ".stage"
            let intentName = ".retiring-desktop-" + plan.approvalDigest + ".intent.json"
            guard let (_, initial) = try read(name, at: descriptor, maximumSize: 32_000_000) else {
                throw DataFailure.message("封存日志在提交前缺失。")
            }
            committed = retirementIdentity(initial).sha256 == plan.afterExpectedRawSHA256
            var intentFile = try read(intentName, at: descriptor, maximumSize: 64_000)
            var stageFile = try read(stageName, at: descriptor, maximumSize: 32_000_000)
            let intent: LocalDataDesktopRetirementIntent
            if let (raw, _) = intentFile {
                try requireRetirementPrivateFile(intentName, at: descriptor)
                try LegacyDesktopStrictJSON.validate(raw)
                let fields = try LegacyDesktopMigrationJournalValidator.object(JSONSerialization.jsonObject(with: raw), keys: [
                    "schema", "transactionID", "directoryPath", "directoryIdentity", "journalFilename", "original", "stage"
                ])
                _ = try LegacyDesktopMigrationJournalValidator.object(fields["directoryIdentity"], keys: ["device", "inode"])
                for key in ["original", "stage"] {
                    _ = try LegacyDesktopMigrationJournalValidator.object(fields[key], keys: ["device", "inode", "size", "sha256"])
                }
                intent = try JSONDecoder().decode(LocalDataDesktopRetirementIntent.self, from: raw)
                guard intent.schema == 1, intent.transactionID == plan.approvalDigest,
                      intent.directoryPath == directory.path, intent.directoryIdentity == plan.targetDirectoryIdentity,
                      intent.journalFilename == name, intent.original == plan.beforeJournalIdentity,
                      intent.stage.sha256 == plan.afterExpectedRawSHA256, intent.stage.size == Int64(data.count),
                      intent.stage.device == plan.targetDirectoryIdentity.device,
                      intent.stage.inode != intent.original.inode else {
                    throw DataFailure.message("封存事务依据不属于此方案；保留未知暂存文件。")
                }
            } else {
                if committed {
                    guard stageFile == nil else { throw DataFailure.message("日志已封存但缺少暂存所有权依据；未清理未知文件。") }
                    let latest = try checkedDirectory(); close(latest)
                    guard fsync(descriptor) == 0 else { throw posixFailure("同步已完成封存状态") }
                    fingerprints[name] = initial; knownMissing.remove(name)
                    return
                }
                guard retirementIdentity(initial) == plan.beforeJournalIdentity else {
                    throw DataFailure.message("旧桌面日志身份或摘要已变化，拒绝封存。")
                }
                guard stageFile == nil else {
                    throw DataFailure.message("封存暂存名缺少持久所有权依据，须由Root核对路径：" + directory.appendingPathComponent(stageName).path + "；未接管、覆盖或删除。")
                }
                try fault?(.beforeRetirementIntent)
                try createRetirementFile(data, name: stageName, at: descriptor)
                stageFile = try read(stageName, at: descriptor, maximumSize: 32_000_000)
                guard let (stageData, stage) = stageFile, stageData == data,
                      retirementIdentity(stage).sha256 == plan.afterExpectedRawSHA256 else {
                    throw DataFailure.message("新封存暂存文件缺失或已变化。")
                }
                try requireRetirementPrivateFile(stageName, at: descriptor)
                intent = .init(transactionID: plan.approvalDigest, directoryPath: directory.path,
                    directoryIdentity: plan.targetDirectoryIdentity, journalFilename: name,
                    original: plan.beforeJournalIdentity, stage: retirementIdentity(stage))
                guard fsync(descriptor) == 0 else { throw posixFailure("同步封存暂存目录") }
                try createRetirementFile(LegacyDesktopMigrationRawCoding.encode(intent), name: intentName, at: descriptor)
                guard fsync(descriptor) == 0 else { throw posixFailure("同步封存事务依据") }
                intentFile = try read(intentName, at: descriptor, maximumSize: 64_000)
            }
            try fault?(.afterRetirementIntent)
            guard let (_, current) = try read(name, at: descriptor, maximumSize: 32_000_000) else {
                throw DataFailure.message("桌面日志在封存事务中缺失。")
            }
            let currentIdentity = retirementIdentity(current)
            stageFile = try read(stageName, at: descriptor, maximumSize: 32_000_000)
            if currentIdentity == intent.original {
                guard let (_, stage) = stageFile, retirementIdentity(stage) == intent.stage else {
                    throw DataFailure.message("封存新暂存身份已变化；未交换或删除。")
                }
                try requireRetirementPrivateFile(stageName, at: descriptor)
                try requireRetirementPrivateFile(intentName, at: descriptor)
                try beforeCommit()
                let latestDirectory = try checkedDirectory(); close(latestDirectory)
                guard let (_, latest) = try read(name, at: descriptor, maximumSize: 32_000_000),
                      retirementIdentity(latest) == intent.original,
                      let (_, latestStage) = try read(stageName, at: descriptor, maximumSize: 32_000_000),
                      retirementIdentity(latestStage) == intent.stage,
                      let (_, latestIntent) = try read(intentName, at: descriptor, maximumSize: 64_000),
                      let (_, expectedIntent) = intentFile, latestIntent == expectedIntent else {
                    throw DataFailure.message("封存事务文件在提交前已变化；未交换。")
                }
                guard renameatx_np(descriptor, stageName, descriptor, name, UInt32(RENAME_SWAP)) == 0 else {
                    throw posixFailure("交换桌面封存日志")
                }
                // The rename has happened even if the next read fails. Route
                // every subsequent error through the structured review receipt.
                committed = true
                guard let (_, exchanged) = try read(name, at: descriptor, maximumSize: 32_000_000),
                      retirementIdentity(exchanged) == intent.stage else {
                    throw DataFailure.message("交换后的正式日志不是确认暂存；保留全部现物。")
                }
                guard fsync(descriptor) == 0 else { throw posixFailure("同步已交换封存日志") }
                try fault?(.afterRetirementSwap)
            } else {
                guard currentIdentity == intent.stage else {
                    throw DataFailure.message("封存事务中的正式日志身份不匹配；保留全部现物。")
                }
                committed = true
            }
            // Confirm the anchored current inode and its content before touching
            // the displaced raw evidence. A foreign stage is never discarded.
            guard let (_, saved) = try read(name, at: descriptor, maximumSize: 32_000_000),
                  retirementIdentity(saved) == intent.stage else {
                throw DataFailure.message("封存日志交换后身份不一致；原件仍保留。")
            }
            if let (_, displaced) = try read(stageName, at: descriptor, maximumSize: 32_000_000) {
                guard retirementIdentity(displaced) == intent.original else {
                    throw DataFailure.message("旧原件暂存身份不匹配；未删除未知文件。")
                }
                guard unlinkat(descriptor, stageName, 0) == 0 else { throw posixFailure("删除已核验桌面日志原件") }
            }
            guard fsync(descriptor) == 0 else { throw posixFailure("同步桌面原件移除") }
            try fault?(.afterRetirementDisplacedRemoval)
            guard let (_, latestIntent) = try read(intentName, at: descriptor, maximumSize: 64_000),
                  let (_, expectedIntent) = intentFile, latestIntent == expectedIntent,
                  try read(stageName, at: descriptor, maximumSize: 32_000_000) == nil else {
                throw DataFailure.message("封存清理依据已变化；未宣告完成。")
            }
            guard unlinkat(descriptor, intentName, 0) == 0 else { throw posixFailure("移除已完成桌面封存依据") }
            guard fsync(descriptor) == 0 else { throw posixFailure("同步封存事务完成") }
            let rechecked = try checkedDirectory(); close(rechecked)
            guard try read(stageName, at: descriptor, maximumSize: 32_000_000) == nil,
                  try read(intentName, at: descriptor, maximumSize: 64_000) == nil,
                  let (_, final) = try read(name, at: descriptor, maximumSize: 32_000_000),
                  retirementIdentity(final) == intent.stage else { throw DataFailure.message("封存收尾未完成，需继续同一事务。") }
            fingerprints[name] = final; knownMissing.remove(name)
            cleanupComplete = true
        } catch {
            failure = "桌面日志封存事务停止：" + error.localizedDescription
            throw LocalDataRetirementWriteError(journalCommitted: committed, cleanupComplete: cleanupComplete, underlyingMessage: failure!)
        }
    }

    private func retirementIdentity(_ value: Fingerprint) -> LocalDataRetirementFileIdentity {
        .init(device: UInt64(bitPattern: Int64(value.identity.device)), inode: UInt64(value.identity.inode),
              size: Int64(value.size), sha256: value.hash.map { String(format: "%02x", $0) }.joined())
    }
    private func requireRetirementPrivateFile(_ name: String, at descriptor: Int32) throws {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw DataFailure.message("封存事务文件权限或所有者异常；未接管。")
        }
    }
    private func createRetirementFile(_ data: Data, name: String, at descriptor: Int32) throws {
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw posixFailure("排他创建封存事务文件") }
        defer { close(file) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw posixFailure("写入封存事务文件") }
                offset += amount
            }
        }
        guard fsync(file) == 0 else { throw posixFailure("同步封存事务文件") }
    }

    func createFile(_ data: Data, name: String) throws {
        try guarded(name) { try write(data, name: name, mustBeNew: true) }
    }

    func removeKnownFile(_ name: String) throws {
        try guarded(name) {
            let descriptor = try checkedDirectory(); defer { close(descriptor) }
            guard let expected = fingerprints[name],
                  let (_, actual) = try read(name, at: descriptor, maximumSize: 32_000_000), actual == expected else {
                throw DataFailure.message(L10n.format("附件已变化或缺失，未删除：%@", String(describing: (name))))
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
        guard data.count <= 32_000_000 else { throw DataFailure.message(L10n.format("资料文件过大：%@", String(describing: (name)))) }
        let descriptor = try checkedDirectory(); defer { close(descriptor) }
        let existing = try read(name, at: descriptor, maximumSize: 32_000_000)
        if let (_, actual) = existing {
            guard !mustBeNew, let expected = fingerprints[name], expected == actual else {
                throw DataFailure.message(L10n.format("%@ 已存在或已被其他程序修改，拒绝覆盖。", String(describing: (name))))
            }
        } else if fingerprints[name] != nil { throw DataFailure.message(L10n.format("%@ 在运行期间被移除，拒绝重新创建。", String(describing: (name)))) }
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
                throw DataFailure.message(L10n.format("%@ 在保存前被修改，拒绝覆盖。", String(describing: (name))))
            }
            // Swap preserves the displaced file, including a concurrent external update, until checked.
            guard renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_SWAP)) == 0 else {
                throw posixFailure("安全替换资料")
            }
            canRemoveStaged = false
            do {
                guard let (_, displaced) = try read(staged, at: descriptor, maximumSize: 32_000_000),
                      displaced.matchesAfterRename(expected) else {
                    throw DataFailure.message(L10n.format("%@ 在提交期间被其他程序替换。", String(describing: (name))))
                }
                canRemoveStaged = true
            } catch {
                // Never discard the displaced file. Swap back, retaining the uncommitted version as well.
                _ = renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_SWAP))
                throw DataFailure.message(L10n.format("%@ 原文件和临时版本均已保留，已停止写入。", String(describing: (error.localizedDescription))))
            }
        } else {
            guard renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                throw posixFailure(L10n.format("排他创建 %@；若已出现同名文件则不会覆盖", String(describing: (name))))
            }
        }
        guard let (_, saved) = try read(name, at: descriptor, maximumSize: 32_000_000), saved.hash == Data(SHA256.hash(data: data)) else {
            canRemoveStaged = false
            throw DataFailure.message(L10n.format("%@ 在写入后被修改，旧文件已保留，已停止写入。", String(describing: (name))))
        }
        fingerprints[name] = saved; knownMissing.remove(name)
        _ = fsync(descriptor)
    }

    private func validateSchema(_ data: Data, name: String) throws {
        if name == LegacyDesktopMigrationImporter.journalFilename {
            _ = try LegacyDesktopMigrationJournalValidator.decode(data)
            return
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dictionary = json as? [String: Any], let raw = dictionary["schema"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 1,
                  number.doubleValue == 1 else { throw DataFailure.message(L10n.format("%@ 的资料格式版本不受支持，请保留原文件。", String(describing: (name)))) }
        }
    }

    private func verifyKnown(_ name: String, fingerprint: Fingerprint) throws {
        if knownMissing.contains(name) { throw DataFailure.message(L10n.format("%@ 在运行期间由外部新增，拒绝覆盖或接管。", String(describing: (name)))) }
        if let expected = fingerprints[name], expected != fingerprint { throw DataFailure.message(L10n.format("%@ 已被其他程序修改，已停止写入。", String(describing: (name)))) }
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
                    guard code == ENOENT, create else { throw posixFailure(L10n.format("读取资料父目录 %@", String(describing: (component))), code: code) }
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw posixFailure(L10n.format("创建资料目录 %@", String(describing: (component)))) }
                } else if info.st_mode & S_IFMT != S_IFDIR { throw DataFailure.message(L10n.format("资料父路径不是常规目录或包含符号链接：%@", String(describing: (component)))) }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixFailure(L10n.format("安全打开资料目录 %@", String(describing: (component)))) }
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
            throw posixFailure(L10n.format("检查资料 %@", String(describing: (name))), code: code)
        }
        guard pathInfo.st_mode & S_IFMT == S_IFREG, pathInfo.st_nlink == 1,
              pathInfo.st_size >= 0, pathInfo.st_size <= maximumSize else {
            throw DataFailure.message(L10n.format("资料不是常规独立文件、含符号链接或大小异常：%@", String(describing: (name))))
        }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixFailure(L10n.format("读取资料 %@", String(describing: (name)))) }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, Identity(before) == Identity(pathInfo), before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size <= maximumSize else { throw DataFailure.message(L10n.format("资料在打开期间被替换：%@", String(describing: (name)))) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let amount = Darwin.read(file, &buffer, buffer.count)
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw posixFailure(L10n.format("读取资料内容 %@", String(describing: (name)))) }
            if amount == 0 { break }
            guard result.count + amount <= maximumSize else { throw DataFailure.message(L10n.format("资料超过读取预算：%@", String(describing: (name)))) }
            result.append(contentsOf: buffer.prefix(amount))
        }
        var after = stat(), latestPath = stat()
        guard fstat(file, &after) == 0, fstatat(descriptor, name, &latestPath, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(after) == Identity(latestPath), Fingerprint(before, data: result) == Fingerprint(after, data: result),
              result.count == after.st_size else { throw DataFailure.message(L10n.format("资料在读取期间发生变化：%@", String(describing: (name)))) }
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
            failure = L10n.format("无法处理 %@，原资料已保留，已停止写入：%@", String(describing: (name)), String(describing: (error.localizedDescription)))
            throw DataFailure.message(failure!)
        }
    }
    private func posixFailure(_ operation: String, code: Int32 = errno) -> DataFailure {
        .message(L10n.format("%@失败：%@（%@）", String(describing: (operation)), String(describing: (String(cString: strerror(code)))), String(describing: (code))))
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
            guard result == errSecSuccess else { throw DataFailure.message(L10n.format("钥匙串保存失败（%@）。", String(describing: (result)))) }
        } else if status != errSecSuccess { throw DataFailure.message(L10n.format("钥匙串更新失败（%@）。", String(describing: (status)))) }
    }
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw DataFailure.message(L10n.format("钥匙串读取失败（%@）。", String(describing: (status)))) }
        return text
    }
}
