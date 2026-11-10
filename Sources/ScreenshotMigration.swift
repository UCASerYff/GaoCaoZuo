import Foundation
import CryptoKit
import Darwin

/// Shared by the application and the thin CLI. Merely constructing a configuration performs no IO.
struct ScreenshotMigrationConfiguration: Codable, Equatable, Sendable {
    struct Auxiliary: Codable, Equatable, Sendable {
        var id: String
        var url: URL
        var required: Bool = false
    }
    var sourceRoot: URL
    var targetRoot: URL
    var archiveRoot: URL
    var auxiliaries: [Auxiliary]
    // Absent options retain the schema-1 canonical encoding used by earlier saved plans.
    var historicalManifestBindings: [ScreenshotHistoricalManifestBinding]? = nil
    var legacyHistoryPolicySHA256: String? = nil

    static func standard(targetRoot: URL, backupRoot: URL) -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/GaoSeries")
        return Self(sourceRoot: support.appendingPathComponent("GaoJieTu"), targetRoot: targetRoot,
                    archiveRoot: backupRoot.appendingPathComponent("MigrationArchive.noindex"), auxiliaries: [
                        .init(id: "Backups", url: support.appendingPathComponent("GaoJieTu-Backups")),
                        .init(id: "Initialization", url: support.appendingPathComponent("GaoJieTu-Initialization.json")),
                        .init(id: "Preferences", url: home.appendingPathComponent("Library/Preferences/com.gaoseries.GaoJieTu.plist"))
                    ])
    }
}

struct ScreenshotMigrationEntry: Codable, Equatable, Sendable {
    var kind: String
    var bytes: Int64
    var sha256: String
    var linkTarget: String? = nil
}

struct ScreenshotMigrationSnapshot: Codable, Equatable, Sendable {
    var id: String
    var originalPath: String
    var existed: Bool
    var isDirectory: Bool
    var inventory: [String: ScreenshotMigrationEntry]
}

struct ScreenshotMigrationPlan: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var sourceBundleID = "com.gaoseries.GaoJieTu"
    var targetBundleID = "com.gaoseries.GaoCaoZuo"
    var sourceID: String
    var sourceSHA256: String
    var migrationID: String
    var configuration: ScreenshotMigrationConfiguration
    var snapshots: [ScreenshotMigrationSnapshot]
    var targetBefore: ScreenshotMigrationSnapshot
    var fileCount: Int
    var totalBytes: Int64
    var conflicts: [String]
    var retainedOnly: [String]
    var approvalDigest: String
}

struct ScreenshotMigrationResult: Codable, Sendable {
    var schemaVersion = 1
    var migrationID: String
    var archivePath: String
    var alreadyApplied: Bool
    var retainedOnly: [String]
    var keychain = "untouched"
    var oldExchange = "read-only ImportedActivity; never activated, resealed or replayed"
}

struct ScreenshotModuleInitialization: Codable, Sendable {
    var schemaVersion = 1
    var module = "com.gaoseries.GaoCaoZuo.Screenshot"
    var mode: String
    var migrationID: String?
    var sourceID: String?
    var sourceSHA256: String?
    var createdAt: String
    var archivePath: String?
}

/// Facts only. No source payload, old program or original settings are embedded in a retirement receipt.
struct ScreenshotRetirementDeletion: Codable, Equatable, Sendable {
    var path: String
    var category: String
    var inventorySHA256: String
}

struct ScreenshotSourceRetirementPlan: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var configuration: ScreenshotMigrationConfiguration
    var migrationID: String
    var sourceID: String
    var sourceSHA256: String
    var markerSHA256: String
    var targetBefore: ScreenshotMigrationSnapshot
    var activityIndexSHA256: String
    var activityInventorySHA256: String
    var archiveInventorySHA256: String
    var deletionAllowlist: [ScreenshotRetirementDeletion]
    var coordinatorReviewOnly: [String]
    var createdAt: String
    var approvalDigest: String
}

/// A coordinator attestation, not a compiler/test result. It is explicitly bound to the reviewed retirement plan.
struct ScreenshotSourceRetirementVerification: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var scope = "real-user-acceptance"
    var retirementPlanDigest: String
    var migrationID: String
    var sourceID: String
    var sourceSHA256: String
    var targetBundleID = "com.gaoseries.GaoCaoZuo"
    var targetVersion = "1.15"
    var targetBuild = "16"
    var verifiedAt: String
    var dataVerified: Bool
    var businessVerified: Bool
    var componentsVerified: Bool
    var installationVerified: Bool
    var releaseVerified: Bool
    var callersVerified: Bool
    var uniqueInstallationVerified: Bool
}

struct ScreenshotSourceRetirementReceipt: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var phase = "finalized"
    var module = "com.gaoseries.GaoCaoZuo.Screenshot"
    var sourceBundleID = "com.gaoseries.GaoJieTu"
    var targetBundleID = "com.gaoseries.GaoCaoZuo"
    var targetVersion = "1.15"
    var targetBuild = "16"
    var migrationID: String
    var sourceID: String
    var sourceSHA256: String
    var markerSHA256: String
    var originalTargetRoot: String
    var originalArchivePath: String
    var retirementPlanDigest: String
    var targetInventorySHA256: String
    var activityIndexSHA256: String
    var activityInventorySHA256: String
    var archiveInventorySHA256: String
    var verificationScope = "real-user-acceptance"
    var verificationEvidenceSHA256: String
    var verifiedAt: String
    var finalizedAt: String
    var deletionAllowlist: [ScreenshotRetirementDeletion]
    var receiptSHA256: String
}

enum ScreenshotMigrationFaultPoint: Equatable {
    case afterPreparedJournal, afterArchiveVerified, afterStagingVerified, afterTargetCommit, beforeCommittedJournal
    case afterStageIntent, afterStageDirectoryCreatedBeforeBinding, afterStageDirectoryCreated
    case beforeRetirementReceipt, afterRetirementReceipt
}

enum ScreenshotMigrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

private struct ScreenshotMigrationRetainedStage: Codable, Equatable {
    var relativePath: String
    var snapshot: ScreenshotMigrationSnapshot
    var markerSHA256: String?
    var ownership: String
}

private struct ScreenshotMigrationStageAttempt: Codable, Equatable {
    var relativePath: String
    var planApprovalDigest: String
    var predecessorJournalSHA256: String
    var createdAt: String
    var retainedStages: [ScreenshotMigrationRetainedStage]
    var createdRoot: ScreenshotMigrationStageDirectoryIdentity? = nil
}

private struct ScreenshotMigrationStageDirectoryIdentity: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
    var uid: UInt32
    var mode: UInt16
    var birthSeconds: Int64
    var birthNanoseconds: Int64
}

private struct ScreenshotMigrationJournal: Codable, Equatable {
    var schemaVersion = 1
    var phase: String
    var plan: ScreenshotMigrationPlan
    var expectedTarget: ScreenshotMigrationSnapshot?
    var createdAt: String
    var stageAttempt: ScreenshotMigrationStageAttempt? = nil
}

/// A module-level transaction: it never replaces the host's database or restores an old whole-store snapshot.
/// Sources remain read-only. Archive and prepared journal survive every failure. Commit is one exclusive rename.
final class ScreenshotMigration {
    static let initializationName = "ModuleInitialization.json"
    static let retirementReceiptName = "SourceRetirementReceipt.json"
    let configuration: ScreenshotMigrationConfiguration
    private let fault: ((ScreenshotMigrationFaultPoint) throws -> Void)?
    init(configuration: ScreenshotMigrationConfiguration, fault: ((ScreenshotMigrationFaultPoint) throws -> Void)? = nil) {
        self.configuration = configuration; self.fault = fault
    }

    /// Inspect original or byte-preserving copied evidence. No absolute marker path is rebound or authorized.
    static func inspectCommittedArchive(at archive: URL, marker: ScreenshotModuleInitialization,
                                        originalActiveRoot: URL) throws -> ScreenshotMigrationSnapshot {
        guard marker.schemaVersion == 1, marker.module == "com.gaoseries.GaoCaoZuo.Screenshot", marker.mode == "migrated",
              let id = marker.migrationID, id.hasPrefix("screenshot-"), safeID(id),
              let originalArchive = marker.archivePath, let sourceID = marker.sourceID, let sourceHash = marker.sourceSHA256 else {
            throw ScreenshotMigrationError.invalid("截图迁移标记损坏，不能创建或核验完整备份。")
        }
        let raw = try ScreenshotMigrationIO.decode(ScreenshotMigrationJournal.self, from: archive.appendingPathComponent("Journal.json"))
        let migration = ScreenshotMigration(configuration: raw.plan.configuration)
        try migration.validateConfiguration()
        let journal = try migration.loadJournal(archive)
        guard journal.phase == "committed", journal.expectedTarget != nil,
              journal.plan.migrationID == id, journal.plan.sourceID == sourceID, journal.plan.sourceSHA256 == sourceHash,
              ScreenshotMigrationIO.path(journal.plan.configuration.targetRoot) == ScreenshotMigrationIO.path(originalActiveRoot),
              ScreenshotMigrationIO.path(migration.archiveURL(id)) == ScreenshotMigrationIO.path(URL(fileURLWithPath: originalArchive)),
              archive.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw ScreenshotMigrationError.invalid("截图资料引用的迁移归档身份、提交状态或原始路径不符。")
        }
        try migration.verifyArchive(journal.plan, archive: archive)
        try migration.verifyRetainedStages(journal, archive: archive)
        return try ScreenshotMigrationIO.snapshot(id: "MigrationEvidence", url: archive, required: true, allowBundleLinks: true)
    }

    /// Reads only the live module (or a byte-preserving backup copy). A finalized receipt never opens old roots.
    static func inspectRetirementReceipt(at root: URL, originalActiveRoot: URL) throws -> ScreenshotSourceRetirementReceipt? {
        let file = root.appendingPathComponent(retirementReceiptName)
        guard try ScreenshotMigrationIO.exists(file) else { return nil }
        _ = try ScreenshotMigrationValidation.object(file, maximum: 1_048_576)
        let receipt = try ScreenshotMigrationIO.decode(ScreenshotSourceRetirementReceipt.self, from: file)
        var unsigned = receipt; unsigned.receiptSHA256 = ""
        let markerFile = root.appendingPathComponent(initializationName)
        let markerBytes = try ScreenshotMigrationIO.read(markerFile, maximum: 1_048_576)
        let marker = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: markerFile)
        let hashes = [receipt.sourceSHA256, receipt.markerSHA256, receipt.retirementPlanDigest, receipt.targetInventorySHA256,
                      receipt.activityIndexSHA256, receipt.activityInventorySHA256, receipt.archiveInventorySHA256,
                      receipt.verificationEvidenceSHA256, receipt.receiptSHA256]
        guard receipt.schemaVersion == 1, receipt.phase == "finalized", receipt.module == "com.gaoseries.GaoCaoZuo.Screenshot",
              receipt.sourceBundleID == "com.gaoseries.GaoJieTu", receipt.targetBundleID == "com.gaoseries.GaoCaoZuo",
              receipt.targetVersion == "1.15", receipt.targetBuild == "16", receipt.verificationScope == "real-user-acceptance",
              receipt.migrationID == "screenshot-" + receipt.sourceSHA256, safeID(receipt.migrationID), hashes.allSatisfy(validSHA),
              validDate(receipt.verifiedAt), validDate(receipt.finalizedAt),
              ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(unsigned)) == receipt.receiptSHA256,
              marker.schemaVersion == 1, marker.module == receipt.module, marker.mode == "migrated",
              marker.migrationID == receipt.migrationID, marker.sourceID == receipt.sourceID,
              marker.sourceSHA256 == receipt.sourceSHA256, marker.archivePath == receipt.originalArchivePath,
              ScreenshotMigrationIO.sha(markerBytes) == receipt.markerSHA256,
              ScreenshotMigrationIO.path(URL(fileURLWithPath: receipt.originalTargetRoot)) == ScreenshotMigrationIO.path(originalActiveRoot),
              validSourceID(receipt.sourceID),
              receipt.deletionAllowlist.allSatisfy({ item in
                  item.path.hasPrefix("/") && item.path != "/" && validSHA(item.inventorySHA256) &&
                  ["source-data", "source-backups", "source-initialization", "source-preferences", "migration-archive"].contains(item.category) &&
                  !ScreenshotMigrationIO.contains(URL(fileURLWithPath: item.path), originalActiveRoot) &&
                  !ScreenshotMigrationIO.contains(originalActiveRoot, URL(fileURLWithPath: item.path))
              }) else {
            throw ScreenshotMigrationIO.fail("截图退役收据损坏、版本过新或来源/标记绑定不符，已停止写入；不能回退为空白。")
        }
        let index = try ScreenshotMigrationActivity.validate(root: root)
        guard index.sourceID == receipt.sourceID, index.sourceSHA256 == receipt.sourceSHA256, index.migrationID == receipt.migrationID,
              ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(index)) == receipt.activityIndexSHA256,
              try inventoryDigest(ScreenshotMigrationIO.snapshot(id: "Activity", url: root.appendingPathComponent("ImportedActivity"), required: true)) == receipt.activityInventorySHA256,
              try ScreenshotMigrationActivity.blockers(root: root).isEmpty else {
            throw ScreenshotMigrationIO.fail("截图退役后的现用活动资料损坏、串源或仍含未决事务，已停止写入。")
        }
        return receipt
    }

    static func inventoryDigest(_ snapshot: ScreenshotMigrationSnapshot) throws -> String {
        ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(snapshot.inventory))
    }

    func hasAnyLegacyEvidence() throws -> Bool {
        if try ScreenshotMigrationIO.exists(configuration.sourceRoot) { return true }
        for auxiliary in configuration.auxiliaries where try ScreenshotMigrationIO.exists(auxiliary.url) { return true }
        return false
    }

    func initialization() throws -> ScreenshotModuleInitialization? {
        let url = configuration.targetRoot.appendingPathComponent(Self.initializationName)
        guard try ScreenshotMigrationIO.exists(url) else { return nil }
        let value = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: url)
        guard value.schemaVersion == 1, value.module == "com.gaoseries.GaoCaoZuo.Screenshot",
              ["fresh", "migrated"].contains(value.mode) else { throw invalid("截图模块初始化标记损坏或版本过新，已停止写入。") }
        if value.mode == "fresh", try ScreenshotMigrationIO.exists(configuration.targetRoot.appendingPathComponent(Self.retirementReceiptName)) {
            throw invalid("新建截图模块出现无对应迁移的退役收据，已停止写入。")
        }
        if value.mode == "migrated" {
            guard let id = value.migrationID, let archive = value.archivePath,
                  id.hasPrefix("screenshot-"), value.sourceID != nil, value.sourceSHA256?.count == 64,
                  ScreenshotMigrationIO.path(URL(fileURLWithPath: archive)) == ScreenshotMigrationIO.path(configuration.archiveRoot.appendingPathComponent(id + ".noindex")) else {
                throw invalid("截图模块迁移标记缺少匹配归档路径，已停止写入。")
            }
            if try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot) != nil { return value }
            let journal = try loadJournal(URL(fileURLWithPath: archive))
            guard journal.phase == "committed", journal.plan.migrationID == id,
                  journal.plan.sourceID == value.sourceID, journal.plan.sourceSHA256 == value.sourceSHA256 else {
                throw invalid("截图模块迁移日志尚未提交，请显式恢复迁移后再使用。")
            }
        }
        return value
    }

    /// No automatic first-launch defaults. This explicit operation refuses to conceal any existing source evidence.
    func initializeFresh() throws {
        if try initialization() != nil { return }
        let lock = try lock(); defer { lock.close() }
        guard try initialization() == nil else { return }
        guard try !hasAnyLegacyEvidence() else { throw invalid("检测到搞截图原资料、备份或偏好，请先预览迁移；不能按新用户初始化。") }
        let before = try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: false)
        guard before.inventory.isEmpty else { throw invalid("目标截图目录已有未初始化资料，已保留，请先核对，不能覆盖为空白。") }
        let stage = configuration.archiveRoot.appendingPathComponent("Fresh-" + UUID().uuidString + ".noindex/Target")
        try ScreenshotMigrationIO.createDirectory(stage)
        try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.json(Self.defaultSettings), to: stage.appendingPathComponent("Settings.json"))
        let marker = ScreenshotModuleInitialization(mode: "fresh", migrationID: nil, sourceID: nil, sourceSHA256: nil,
                                                   createdAt: Self.now, archivePath: nil)
        try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(marker), to: stage.appendingPathComponent(Self.initializationName))
        guard try !hasAnyLegacyEvidence(), try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: false) == before else {
            throw invalid("初始化前来源或目标状态变化，已保留暂存资料，未覆盖目标。")
        }
        try commit(stage: stage, before: before)
    }

    func preview() throws -> ScreenshotMigrationPlan {
        try validateConfiguration()
        let source = try ScreenshotMigrationIO.snapshot(id: "Source", url: configuration.sourceRoot, required: true)
        guard source.isDirectory, source.existed else { throw invalid("搞截图真实资料目录缺失；不会构造空来源。") }
        try ScreenshotMigrationValidation.validate(root: configuration.sourceRoot, snapshot: source, logicalRoot: configuration.sourceRoot)
        var snapshots = [source]
        for auxiliary in configuration.auxiliaries {
            guard Self.safeID(auxiliary.id), auxiliary.id != "Source", !snapshots.contains(where: { $0.id == auxiliary.id }) else { throw invalid("辅助资料身份重复或无效。") }
            let value = try ScreenshotMigrationIO.snapshot(id: auxiliary.id, url: auxiliary.url, required: auxiliary.required, allowBundleLinks: true)
            try ScreenshotMigrationValidation.validateAuxiliary(root: auxiliary.url, snapshot: value, logicalRoot: configuration.sourceRoot,
                role: auxiliary.id == "Backups" ? .legacyBackupContainer : .generic)
            snapshots.append(value)
        }
        // Installation backup pointers can name retained backups outside the default backup root.
        // Those roots are snapshotted too, and the pointer bytes remain unchanged in the archive.
        var seenPaths = Set(snapshots.map(\.originalPath))
        var cursor = 0
        while cursor < snapshots.count {
            let snapshot = snapshots[cursor]; cursor += 1
            if snapshot.existed, !snapshot.isDirectory, URL(fileURLWithPath: snapshot.originalPath).lastPathComponent.hasSuffix(".recovery.json") {
                let media = try ScreenshotMigrationValidation.recordingMediaReferencedByJournal(URL(fileURLWithPath: snapshot.originalPath))
                if seenPaths.insert(ScreenshotMigrationIO.path(media)).inserted {
                    snapshots.append(try ScreenshotMigrationIO.snapshot(id: "External-" + String(snapshots.count), url: media, required: true))
                }
            }
            for (name, entry) in snapshot.inventory.sorted(by: { $0.key < $1.key }) where entry.kind == "file" && Self.isPointer(snapshot.isDirectory ? name : snapshot.originalPath) {
                let base = URL(fileURLWithPath: snapshot.originalPath)
                let file = snapshot.isDirectory ? base.appendingPathComponent(name) : base
                let bytes = try ScreenshotMigrationIO.read(file, maximum: 8192)
                guard let text = String(data: bytes, encoding: .utf8), text.hasSuffix("\n"), text.filter({ $0 == "\n" }).count == 1 else { throw invalid("备份路径指针损坏，已停止迁移。") }
                let path = String(text.dropLast())
                guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\r"), !path.split(separator: "/").contains("..") else { throw invalid("备份路径指针不是规范绝对路径。") }
                let url = URL(fileURLWithPath: path)
                let normalized = ScreenshotMigrationIO.path(url)
                guard normalized != "/", !ScreenshotMigrationIO.contains(configuration.targetRoot, url), !ScreenshotMigrationIO.contains(configuration.archiveRoot, url),
                      !ScreenshotMigrationIO.contains(url, configuration.targetRoot), !ScreenshotMigrationIO.contains(url, configuration.archiveRoot) else { throw invalid("备份指针指向目标、迁移归档或其祖先，已停止循环迁移。") }
                if seenPaths.insert(normalized).inserted {
                    guard snapshots.count < 128 else { throw invalid("外部备份指针超过限制，未忽略任何资料。") }
                    let external = try ScreenshotMigrationIO.snapshot(id: "External-" + String(snapshots.count), url: url, required: true, allowBundleLinks: true)
                    try ScreenshotMigrationValidation.validateAuxiliary(root: url, snapshot: external, logicalRoot: configuration.sourceRoot, role: .legacyBackupRoot)
                    snapshots.append(external)
                }
            }
        }
        try validateHistoryPolicy(snapshots: snapshots)
        let target = try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: false)
        let sourceID = "com.gaoseries.GaoJieTu:" + ScreenshotMigrationIO.sha(Data(ScreenshotMigrationIO.path(configuration.sourceRoot).utf8))
        let digest = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(snapshots))
        let migrationID = "screenshot-" + digest
        var conflicts: [String] = []
        if !target.inventory.isEmpty { conflicts.append("目标截图目录已有资料；保留全部目标与来源，本次不能覆盖或整库回滚。") }
        let entries = snapshots.flatMap { $0.inventory.values }.filter { $0.kind == "file" }
        let retained = ["原始Settings与全部路径/偏好/初始化标记、原始PinnedImages记录：退役闸门前完整保全", "仍需的旧Exchange、ProcessedRequests、输入/输出包、OCR恢复及录制恢复：独立迁入只读ImportedActivity，不重放", "DeletedHistory、全部原备份、外部备份指针及其指向实物：退役闸门前完整保全，最终仅Root按专属范围处理", "保存目录、编辑器、书签与系统权限：不自动转授；钥匙串保持原样"]
        var plan = ScreenshotMigrationPlan(sourceID: sourceID, sourceSHA256: digest, migrationID: migrationID, configuration: configuration,
            snapshots: snapshots, targetBefore: target, fileCount: entries.count, totalBytes: entries.reduce(0) { $0 + $1.bytes },
            conflicts: conflicts, retainedOnly: retained, approvalDigest: "")
        plan.approvalDigest = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(plan))
        return plan
    }

    @discardableResult
    func apply(_ plan: ScreenshotMigrationPlan, approvedDigest: String) throws -> ScreenshotMigrationResult {
        try validateConfiguration()
        if let receipt = try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot) {
            guard approvedDigest == plan.approvalDigest, plan.configuration == configuration,
                  plan.migrationID == receipt.migrationID, plan.sourceID == receipt.sourceID, plan.sourceSHA256 == receipt.sourceSHA256 else {
                throw invalid("目标已完成来源退役，本次计划不是同一来源，未覆盖现用资料。")
            }
            return .init(migrationID: receipt.migrationID, archivePath: receipt.originalArchivePath, alreadyApplied: true,
                         retainedOnly: ["现用截图资料及ImportedActivity；来源已解除依赖，删除仅由Root执行。"])
        }
        let lock = try lock(); defer { lock.close() }
        guard approvedDigest == plan.approvalDigest, plan.configuration == configuration else { throw invalid("迁移确认与预览不一致，请重新预览。") }
        let archive = archiveURL(plan.migrationID)
        if try ScreenshotMigrationIO.exists(archive.appendingPathComponent("Journal.json")) {
            let journal = try loadJournal(archive)
            guard journal.plan == plan else { throw invalid("已有日志与本次预览不同，未覆盖日志或目标。") }
            return try resume(journal, archive: archive)
        }
        let checked = try preview()
        guard checked == plan else { throw invalid("来源、附件、备份或目标在预览后变化，请重新预览；未覆盖新资料。") }
        guard plan.conflicts.isEmpty else { throw invalid(plan.conflicts.joined(separator: "\n")) }
        try ScreenshotMigrationIO.createDirectory(archive)
        let journal = ScreenshotMigrationJournal(phase: "prepared", plan: plan, expectedTarget: nil, createdAt: Self.now)
        try saveJournal(journal, archive: archive, new: true)
        try fault?(.afterPreparedJournal)
        return try resume(journal, archive: archive)
    }

    /// Explicit recovery only. It resumes the exact prepared transaction, never restores the host or overwrites a changed target.
    @discardableResult
    func recover(migrationID: String) throws -> ScreenshotMigrationResult {
        try validateConfiguration()
        if let receipt = try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot) {
            guard receipt.migrationID == migrationID else { throw invalid("退役后的目标属于其他迁移，未覆盖现用资料。") }
            return .init(migrationID: migrationID, archivePath: receipt.originalArchivePath, alreadyApplied: true,
                         retainedOnly: ["现用截图资料及ImportedActivity；旧来源删除仅由Root执行。"])
        }
        let lock = try lock(); defer { lock.close() }
        guard migrationID.hasPrefix("screenshot-"), Self.safeID(migrationID) else { throw invalid("迁移身份无效。") }
        let archive = archiveURL(migrationID)
        let journal = try loadJournal(archive)
        guard journal.plan.configuration == configuration, journal.plan.migrationID == migrationID else { throw invalid("恢复配置与原迁移事务不一致。") }
        return try resume(journal, archive: archive)
    }

    /// An explicit extension for an already committed pre-activity candidate. Only ImportedActivity may be added.
    @discardableResult
    func importActivity(_ plan: ScreenshotMigrationPlan) throws -> ScreenshotMigratedActivityIndex {
        try validateConfiguration()
        if let receipt = try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot) {
            guard receipt.migrationID == plan.migrationID, receipt.sourceID == plan.sourceID, receipt.sourceSHA256 == plan.sourceSHA256 else { throw invalid("现用活动资料与补迁来源不同。") }
            return try ScreenshotMigrationActivity.validate(root: configuration.targetRoot)
        }
        let lock = try lock(); defer { lock.close() }
        let archive = archiveURL(plan.migrationID)
        let journal = try loadJournal(archive)
        guard journal.phase == "committed", journal.plan == plan, plan.configuration == configuration,
              let marker = try initialization(), marker.migrationID == plan.migrationID else { throw invalid("活动补迁必须绑定同一已提交迁移，未覆盖目标。") }
        try verifyArchive(plan, archive: archive)
        let before = try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: true)
        let index = try ScreenshotMigrationActivity.prepare(plan: plan, archive: archive, target: configuration.targetRoot)
        let after = try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: true)
        guard before.inventory.allSatisfy({ after.inventory[$0.key] == $0.value }),
              after.inventory.keys.allSatisfy({ before.inventory[$0] != nil || $0 == "ImportedActivity" || $0.hasPrefix("ImportedActivity/") }) else {
            throw invalid("活动补迁期间目标发生变化；全部现用与补迁资料已保留，未回滚覆盖。")
        }
        return index
    }

    func retirementPreview(_ plan: ScreenshotMigrationPlan) throws -> ScreenshotSourceRetirementPlan {
        try retirementPreview(plan, createdAt: Self.now)
    }

    private func retirementPreview(_ plan: ScreenshotMigrationPlan, createdAt: String) throws -> ScreenshotSourceRetirementPlan {
        try validateConfiguration()
        guard plan.configuration == configuration,
              try !ScreenshotMigrationIO.exists(configuration.targetRoot.appendingPathComponent(Self.retirementReceiptName)),
              let marker = try initialization(), marker.mode == "migrated", marker.migrationID == plan.migrationID,
              marker.sourceID == plan.sourceID, marker.sourceSHA256 == plan.sourceSHA256 else { throw invalid("退役预览必须绑定尚未退役的同源已提交截图模块。") }
        let archive = archiveURL(plan.migrationID), journal = try loadJournal(archive)
        guard journal.phase == "committed", journal.plan == plan else { throw invalid("退役预览与已提交日志不一致。") }
        let archiveSnapshot = try Self.inspectCommittedArchive(at: archive, marker: marker, originalActiveRoot: configuration.targetRoot)
        // Retirement cannot silently discard source writes made after migration.
        for snapshot in plan.snapshots {
            guard try ScreenshotMigrationIO.snapshot(id: snapshot.id, url: URL(fileURLWithPath: snapshot.originalPath), required: snapshot.existed,
                                                     allowBundleLinks: snapshot.id != "Source") == snapshot else { throw invalid("迁移后旧来源发生变化，退役已停止；需先核对未迁入资料。") }
        }
        let index = try ScreenshotMigrationActivity.validate(root: configuration.targetRoot, plan: plan, archive: archive)
        let blockers = try ScreenshotMigrationActivity.blockers(root: configuration.targetRoot)
        guard index.sourceID == plan.sourceID, index.sourceSHA256 == plan.sourceSHA256, index.migrationID == plan.migrationID,
              blockers.isEmpty else { throw invalid("截图活动仍有未安全迁入或未决事务，不能退役：" + blockers.joined(separator: "；")) }
        let target = try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: true)
        try ScreenshotMigrationValidation.validate(root: configuration.targetRoot, snapshot: target, logicalRoot: configuration.targetRoot)
        let activity = try ScreenshotMigrationIO.snapshot(id: "Activity", url: configuration.targetRoot.appendingPathComponent("ImportedActivity"), required: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardParent = home.appendingPathComponent("Library/Application Support/GaoSeries")
        let standardSource = standardParent.appendingPathComponent("GaoJieTu")
        let standardPreferences = home.appendingPathComponent("Library/Preferences/com.gaoseries.GaoJieTu.plist")
        let defaultSource = ScreenshotMigrationIO.path(configuration.sourceRoot) == ScreenshotMigrationIO.path(standardSource)
        var allowlist: [ScreenshotRetirementDeletion] = [], reviewOnly: [String] = []
        for snapshot in plan.snapshots where snapshot.existed {
            let path = snapshot.originalPath
            let category: String?
            if defaultSource, snapshot.id == "Source", path == ScreenshotMigrationIO.path(standardSource) { category = "source-data" }
            else if defaultSource, snapshot.id == "Backups", path == ScreenshotMigrationIO.path(standardParent.appendingPathComponent("GaoJieTu-Backups")) { category = "source-backups" }
            else if defaultSource, snapshot.id == "Initialization", path == ScreenshotMigrationIO.path(standardParent.appendingPathComponent("GaoJieTu-Initialization.json")) { category = "source-initialization" }
            else if defaultSource, snapshot.id == "Preferences", path == ScreenshotMigrationIO.path(standardPreferences) { category = "source-preferences" }
            else { category = nil }
            if let category { allowlist.append(.init(path: path, category: category, inventorySHA256: try Self.inventoryDigest(snapshot))) }
            else { reviewOnly.append(path) }
        }
        allowlist.append(.init(path: ScreenshotMigrationIO.path(archive), category: "migration-archive", inventorySHA256: try Self.inventoryDigest(archiveSnapshot)))
        var result = ScreenshotSourceRetirementPlan(configuration: configuration, migrationID: plan.migrationID, sourceID: plan.sourceID,
            sourceSHA256: plan.sourceSHA256, markerSHA256: ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.read(configuration.targetRoot.appendingPathComponent(Self.initializationName))),
            targetBefore: target, activityIndexSHA256: ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(index)),
            activityInventorySHA256: try Self.inventoryDigest(activity), archiveInventorySHA256: try Self.inventoryDigest(archiveSnapshot),
            deletionAllowlist: allowlist.sorted { $0.path < $1.path }, coordinatorReviewOnly: reviewOnly.sorted(), createdAt: createdAt, approvalDigest: "")
        result.approvalDigest = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(result))
        return result
    }

    /// Finalization publishes facts only. It deliberately deletes no source, backup, archive or user file.
    @discardableResult
    func finalizeSourceRetirement(_ plan: ScreenshotSourceRetirementPlan, approvedDigest: String,
                                  verificationEvidence: URL) throws -> ScreenshotSourceRetirementReceipt {
        var unsigned = plan; unsigned.approvalDigest = ""
        guard plan.schemaVersion == 1, plan.configuration == configuration, approvedDigest == plan.approvalDigest,
              plan.migrationID == "screenshot-" + plan.sourceSHA256, Self.safeID(plan.migrationID), Self.validSourceID(plan.sourceID),
              Self.validSHA(plan.sourceSHA256), Self.validSHA(plan.markerSHA256), plan.targetBefore.existed, plan.targetBefore.isDirectory,
              Self.validSHA(approvedDigest), ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(unsigned)) == approvedDigest else {
            throw invalid("退役确认与预览摘要或配置不一致。")
        }
        _ = try ScreenshotMigrationValidation.object(verificationEvidence, maximum: 1_048_576)
        let verificationBytes = try ScreenshotMigrationIO.read(verificationEvidence, maximum: 1_048_576)
        let verification = try JSONDecoder().decode(ScreenshotSourceRetirementVerification.self, from: verificationBytes)
        guard verification.schemaVersion == 1, verification.scope == "real-user-acceptance", verification.retirementPlanDigest == approvedDigest,
              verification.migrationID == plan.migrationID, verification.sourceID == plan.sourceID, verification.sourceSHA256 == plan.sourceSHA256,
              verification.targetBundleID == "com.gaoseries.GaoCaoZuo", verification.targetVersion == "1.15", verification.targetBuild == "16",
              let verifiedAt = ISO8601DateFormatter().date(from: verification.verifiedAt), let previewedAt = ISO8601DateFormatter().date(from: plan.createdAt),
              verifiedAt >= previewedAt, verification.dataVerified, verification.businessVerified, verification.componentsVerified,
              verification.installationVerified, verification.releaseVerified, verification.callersVerified, verification.uniqueInstallationVerified else {
            throw invalid("缺少与退役预览绑定的真实资料、业务、组件、安装发布、调用者或唯一入口验收凭据。")
        }
        let evidenceSHA = ScreenshotMigrationIO.sha(verificationBytes)
        if let receipt = try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot) {
            guard receipt.retirementPlanDigest == approvedDigest, receipt.verificationEvidenceSHA256 == evidenceSHA else { throw invalid("已有退役收据与本次确认不同，未覆盖收据或现用资料。") }
            return receipt
        }
        let lock = try lock(); defer { lock.close() }
        let journal = try loadJournal(archiveURL(plan.migrationID))
        guard try retirementPreview(journal.plan, createdAt: plan.createdAt) == plan else { throw invalid("退役预览后来源、归档或目标改变，请重新预览；未删除任何资料。") }
        var receipt = ScreenshotSourceRetirementReceipt(migrationID: plan.migrationID, sourceID: plan.sourceID, sourceSHA256: plan.sourceSHA256,
            markerSHA256: plan.markerSHA256, originalTargetRoot: ScreenshotMigrationIO.path(configuration.targetRoot), originalArchivePath: archiveURL(plan.migrationID).path,
            retirementPlanDigest: approvedDigest, targetInventorySHA256: try Self.inventoryDigest(plan.targetBefore),
            activityIndexSHA256: plan.activityIndexSHA256, activityInventorySHA256: plan.activityInventorySHA256,
            archiveInventorySHA256: plan.archiveInventorySHA256, verificationEvidenceSHA256: evidenceSHA,
            verifiedAt: verification.verifiedAt, finalizedAt: Self.now, deletionAllowlist: plan.deletionAllowlist, receiptSHA256: "")
        receipt.receiptSHA256 = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(receipt))
        try fault?(.beforeRetirementReceipt)
        guard try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: true) == plan.targetBefore,
              try ScreenshotMigrationIO.read(verificationEvidence, maximum: 1_048_576) == verificationBytes else { throw invalid("退役提交前目标或验收凭据变化，未提交收据或删除来源。") }
        try ScreenshotMigrationIO.publishNew(try ScreenshotMigrationIO.encoder.encode(receipt), to: configuration.targetRoot.appendingPathComponent(Self.retirementReceiptName),
                                            stagingRoot: configuration.archiveRoot.appendingPathComponent("RetirementWrites.noindex"))
        try fault?(.afterRetirementReceipt)
        _ = try Self.inspectRetirementReceipt(at: configuration.targetRoot, originalActiveRoot: configuration.targetRoot)
        return receipt
    }

    private func resume(_ original: ScreenshotMigrationJournal, archive: URL) throws -> ScreenshotMigrationResult {
        var journal = original
        let plan = journal.plan
        try verifyRetainedStages(journal, archive: archive)
        let markerURL = configuration.targetRoot.appendingPathComponent(Self.initializationName)
        if try ScreenshotMigrationIO.exists(markerURL) {
            let marker = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: markerURL)
            guard marker.schemaVersion == 1, marker.mode == "migrated", marker.migrationID == plan.migrationID,
                  marker.sourceID == plan.sourceID, marker.sourceSHA256 == plan.sourceSHA256 else {
                throw invalid("目标已存在其他初始化或迁移记录，未覆盖目标新资料。")
            }
            // Only a committed journal permits subsequent user writes. A rename with a staged journal is still blocked,
            // so the complete expected target inventory must match before promoting that journal to committed.
            guard journal.expectedTarget != nil, ["staged", "committed"].contains(journal.phase) else { throw invalid("目标提交标记缺少准备依据，已停止恢复。") }
            try verifyArchive(plan, archive: archive)
            let already = journal.phase == "committed"
            if !already { try ScreenshotMigrationIO.requireSnapshot(journal.expectedTarget!, at: configuration.targetRoot) }
            journal.phase = "committed"; try saveJournal(journal, archive: archive)
            return result(plan, archive: archive, already: already)
        }
        guard journal.phase != "committed" else { throw invalid("已提交迁移的目标标记消失，未整库回滚；请核对目标资料。") }
        guard try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: false) == plan.targetBefore else { throw invalid("未完成迁移期间目标资料发生变化，已保留全部资料，未覆盖或回滚。") }
        if journal.phase == "prepared" {
            // Re-check every live source before resuming a partial archive. A changed source requires a new preview.
            for snapshot in plan.snapshots {
                guard try ScreenshotMigrationIO.snapshot(id: snapshot.id, url: URL(fileURLWithPath: snapshot.originalPath), required: snapshot.existed, allowBundleLinks: snapshot.id != "Source") == snapshot else {
                    throw invalid("准备迁移后来源资料发生变化，原事务与部分归档均保留，请重新预览。")
                }
                if snapshot.existed { try ScreenshotMigrationIO.copy(snapshot, to: archive.appendingPathComponent(snapshot.id)) }
            }
            try verifyArchive(plan, archive: archive)
            // Rehearsal copies all archived roots and verifies directory topology and every file/link hash.
            let rehearsal = archive.appendingPathComponent("RestoreRehearsal.noindex")
            for snapshot in plan.snapshots where snapshot.existed {
                var copy = snapshot; copy.originalPath = archive.appendingPathComponent(snapshot.id).path
                try ScreenshotMigrationIO.copy(copy, to: rehearsal.appendingPathComponent(snapshot.id))
            }
            for snapshot in plan.snapshots where snapshot.existed {
                try ScreenshotMigrationIO.requireSnapshot(snapshot, at: rehearsal.appendingPathComponent(snapshot.id))
            }
            // Rehearsal is retained as explicit rollback evidence; no original or failed artifact is removed.
            journal.phase = "archived"; try saveJournal(journal, archive: archive)
            try fault?(.afterArchiveVerified)
        }
        try verifyArchive(plan, archive: archive)
        var stage = try stageURL(journal, archive: archive)
        if journal.phase == "archived" {
            // An archived transaction has no complete expectedTarget. Preserve every recognized old stage,
            // then journal a fresh exclusive attempt before creating it; never adopt partial activity work.
            journal = try bindNewStageAttempt(journal, archive: archive)
            stage = try stageURL(journal, archive: archive)
            try fault?(.afterStageIntent)
            let intentRaw = try ScreenshotMigrationIO.read(archive.appendingPathComponent("Journal.json"))
            guard try JSONDecoder().decode(ScreenshotMigrationJournal.self, from: intentRaw) == journal else { throw invalid("暂存目录创建前意图日志改变，未写入。") }
            let identity = try createOwnedStage(stage, archive: archive)
            try fault?(.afterStageDirectoryCreatedBeforeBinding)
            journal.stageAttempt!.createdRoot = identity
            try saveJournal(journal, archive: archive, expectedRaw: intentRaw)
            try fault?(.afterStageDirectoryCreated)
            try prepareTarget(plan, archive: archive, stage: stage)
            journal.expectedTarget = try ScreenshotMigrationIO.snapshot(id: "Target", url: stage, required: true)
            journal.phase = "staged"; try saveJournal(journal, archive: archive)
            try fault?(.afterStagingVerified)
        }
        guard journal.phase == "staged", let expected = journal.expectedTarget else { throw invalid("迁移日志阶段无效，已保留现物。") }
        if let identity = journal.stageAttempt?.createdRoot {
            guard try stageDirectoryIdentity(stage) == identity else { throw invalid("已准备暂存目录的实物身份改变，未提交目标。") }
        }
        try verifyRetainedStages(journal, archive: archive)
        try ScreenshotMigrationIO.requireSnapshot(expected, at: stage)
        // Freeze the import boundary: the old owner must be stopped by the coordinator before final apply/recovery.
        for snapshot in plan.snapshots {
            guard try ScreenshotMigrationIO.snapshot(id: snapshot.id, url: URL(fileURLWithPath: snapshot.originalPath), required: snapshot.existed, allowBundleLinks: snapshot.id != "Source") == snapshot else { throw invalid("提交前来源发生变化，已停止；需关闭旧宿主后重新预览。") }
        }
        try commit(stage: stage, before: plan.targetBefore)
        try fault?(.afterTargetCommit)
        try ScreenshotMigrationIO.requireSnapshot(expected, at: configuration.targetRoot)
        journal.phase = "committed"
        try fault?(.beforeCommittedJournal)
        try saveJournal(journal, archive: archive)
        return result(plan, archive: archive, already: false)
    }

    private func prepareTarget(_ plan: ScreenshotMigrationPlan, archive: URL, stage: URL) throws {
        try ScreenshotMigrationIO.createDirectory(stage)
        let source = archive.appendingPathComponent("Source")
        let sourceSnapshot = plan.snapshots[0]
        let historyName = sourceSnapshot.inventory["History.json"] != nil ? "History.json" : "History/History.json"
        for (name, entry) in sourceSnapshot.inventory.sorted(by: { $0.key < $1.key }) {
            // Recovery/Exchange records are deliberately absent from the active module.
            guard name.hasPrefix("History/") && name != "History/History.json" || name.hasPrefix("Pins/") else { continue }
            if entry.kind == "directory" { try ScreenshotMigrationIO.createDirectory(stage.appendingPathComponent(name)) }
            else if entry.kind == "file" { try ScreenshotMigrationIO.copyFile(from: source.appendingPathComponent(name), to: stage.appendingPathComponent(name), expected: entry) }
        }
        if let entry = sourceSnapshot.inventory[historyName] { try ScreenshotMigrationIO.copyFile(from: source.appendingPathComponent(historyName), to: stage.appendingPathComponent("History.json"), expected: entry) }
        try ScreenshotMigrationIO.writeOrVerify(try preparedSettings(source: source), to: stage.appendingPathComponent("Settings.json"))
        if let pins = try preparedPins(source: source, snapshot: sourceSnapshot) {
            try ScreenshotMigrationIO.writeOrVerify(pins, to: stage.appendingPathComponent("PinnedImages.json"))
        }
        let marker = ScreenshotModuleInitialization(mode: "migrated", migrationID: plan.migrationID, sourceID: plan.sourceID,
            sourceSHA256: plan.sourceSHA256, createdAt: Self.now, archivePath: archive.path)
        let markerURL = stage.appendingPathComponent(Self.initializationName)
        if try ScreenshotMigrationIO.exists(markerURL) { try validateStageMarker(plan, archive: archive, at: markerURL) }
        else { try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(marker), to: markerURL) }
        _ = try ScreenshotMigrationActivity.prepare(plan: plan, archive: archive, target: stage, ownedStage: stage)
        let targetSnapshot = try ScreenshotMigrationIO.snapshot(id: "Target", url: stage, required: true)
        try ScreenshotMigrationValidation.validate(root: stage, snapshot: targetSnapshot, logicalRoot: configuration.targetRoot)
        guard !targetSnapshot.inventory.keys.contains(where: { $0 == "Exchange" || $0.hasPrefix("Exchange/") }) else { throw invalid("旧交接资料不能进入可执行目标。") }
    }

    private func preparedSettings(source: URL) throws -> Data {
        var settings = try ScreenshotMigrationValidation.object(source.appendingPathComponent("Settings.json"))
        settings.removeValue(forKey: "saveDirectory"); settings.removeValue(forKey: "editorPath")
        if settings["captureStrategy"] as? String == "保存" { settings["captureStrategy"] = "标注" }
        return try ScreenshotMigrationIO.json(settings)
    }
    private func preparedPins(source: URL, snapshot: ScreenshotMigrationSnapshot) throws -> Data? {
        guard snapshot.inventory["PinnedImages.json"] != nil else { return nil }
        var pins = try ScreenshotMigrationValidation.object(source.appendingPathComponent("PinnedImages.json"))
        var records = pins["records"] as! [[String: Any]]
        for i in records.indices {
            let old = records[i]["imagePath"] as! String
            records[i]["imagePath"] = configuration.targetRoot.appendingPathComponent("Pins/" + URL(fileURLWithPath: old).lastPathComponent).path
        }
        pins["records"] = records
        return try ScreenshotMigrationIO.json(pins)
    }
    private func validStageName(_ name: String) -> Bool {
        let prefix = "PreparedTarget-", suffix = ".noindex"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let value = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: value)?.uuidString == value
    }
    private func stageURL(_ journal: ScreenshotMigrationJournal, archive: URL) throws -> URL {
        guard let attempt = journal.stageAttempt else { return archive.appendingPathComponent("PreparedTarget") }
        let logicalArchive = journal.plan.configuration.archiveRoot.appendingPathComponent(journal.plan.migrationID + ".noindex")
        guard validStageName(attempt.relativePath), attempt.planApprovalDigest == journal.plan.approvalDigest,
              Self.validSHA(attempt.predecessorJournalSHA256), Self.validDate(attempt.createdAt),
              Set(attempt.retainedStages.map(\.relativePath)).count == attempt.retainedStages.count else {
            throw invalid("暂存尝试日志的路径、计划绑定或保留库存无效，已保留现物。")
        }
        if let identity = attempt.createdRoot {
            guard identity.uid == geteuid(), identity.inode > 0, identity.mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
                  (0..<1_000_000_000).contains(identity.birthNanoseconds) else { throw invalid("暂存目录创建身份日志无效。") }
        }
        for retained in attempt.retainedStages {
            guard retained.relativePath == "PreparedTarget" || validStageName(retained.relativePath),
                  retained.relativePath != attempt.relativePath,
                  ["legacy-marker", "journal-attempt"].contains(retained.ownership),
                  retained.snapshot.id == "Target", retained.snapshot.existed, retained.snapshot.isDirectory,
                  retained.snapshot.originalPath == ScreenshotMigrationIO.path(logicalArchive.appendingPathComponent(retained.relativePath)),
                  retained.ownership != "legacy-marker" || retained.markerSHA256.map(Self.validSHA) == true,
                  retained.markerSHA256 == retained.snapshot.inventory[Self.initializationName]?.sha256 else {
                throw invalid("保留的旧暂存路径、库存或标记绑定不一致，已停止恢复。")
            }
        }
        return archive.appendingPathComponent(attempt.relativePath)
    }
    private func verifyRetainedStages(_ journal: ScreenshotMigrationJournal, archive: URL) throws {
        _ = try stageURL(journal, archive: archive)
        for retained in journal.stageAttempt?.retainedStages ?? [] {
            try ScreenshotMigrationIO.requireSnapshot(retained.snapshot, at: archive.appendingPathComponent(retained.relativePath))
        }
    }
    private func validateStageMarker(_ plan: ScreenshotMigrationPlan, archive: URL, at url: URL) throws {
        _ = try ScreenshotMigrationValidation.object(url, maximum: 1_048_576)
        let marker = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: url)
        guard marker.schemaVersion == 1, marker.module == "com.gaoseries.GaoCaoZuo.Screenshot", marker.mode == "migrated",
              marker.migrationID == plan.migrationID, marker.sourceID == plan.sourceID, marker.sourceSHA256 == plan.sourceSHA256,
              marker.archivePath == archive.path, Self.validDate(marker.createdAt) else {
            throw invalid("旧暂存标记不属于同一计划与归档，未认领、覆盖或删除。")
        }
    }
    private func validateLegacyPartial(_ snapshot: ScreenshotMigrationSnapshot, plan: ScreenshotMigrationPlan, archive: URL) throws {
        let stage = URL(fileURLWithPath: snapshot.originalPath), marker = stage.appendingPathComponent(Self.initializationName)
        guard snapshot.inventory[Self.initializationName]?.kind == "file" else { throw invalid("旧暂存没有原迁移标记或已认领的日志意图，不能自动认领。") }
        try validateStageMarker(plan, archive: archive, at: marker)
        let source = archive.appendingPathComponent("Source"), original = plan.snapshots[0]
        var allowed = original.inventory.filter { name, _ in
            name == "History" || name == "Pins" || name.hasPrefix("History/") && name != "History/History.json" || name.hasPrefix("Pins/")
        }
        let history = original.inventory["History.json"] ?? original.inventory["History/History.json"]
        if let history { allowed["History.json"] = history }
        func entry(_ data: Data) -> ScreenshotMigrationEntry { .init(kind: "file", bytes: Int64(data.count), sha256: ScreenshotMigrationIO.sha(data)) }
        allowed["Settings.json"] = entry(try preparedSettings(source: source))
        if let pins = try preparedPins(source: source, snapshot: original) { allowed["PinnedImages.json"] = entry(pins) }
        allowed[Self.initializationName] = snapshot.inventory[Self.initializationName]
        if snapshot.inventory[ScreenshotMigrationActivity.directoryName] != nil {
            _ = try ScreenshotMigrationActivity.validate(root: stage, plan: plan, archive: archive)
            for (path, value) in snapshot.inventory where path == ScreenshotMigrationActivity.directoryName || path.hasPrefix(ScreenshotMigrationActivity.directoryName + "/") { allowed[path] = value }
        }
        guard snapshot.inventory.allSatisfy({ allowed[$0.key] == $0.value }) else {
            throw invalid("旧暂存含不属于已批准投影的资料，已保留全部现物，不能自动认领。")
        }
    }
    private func bindNewStageAttempt(_ original: ScreenshotMigrationJournal, archive: URL) throws -> ScreenshotMigrationJournal {
        let raw = try ScreenshotMigrationIO.read(archive.appendingPathComponent("Journal.json"))
        guard try JSONDecoder().decode(ScreenshotMigrationJournal.self, from: raw) == original,
              original.phase == "archived", original.expectedTarget == nil else { throw invalid("创建暂存尝试前日志已改变或阶段不符，未写入。") }
        var retained = original.stageAttempt?.retainedStages ?? []
        _ = try stageURL(original, archive: archive)
        for evidence in retained { try ScreenshotMigrationIO.requireSnapshot(evidence.snapshot, at: archive.appendingPathComponent(evidence.relativePath)) }
        let legacy = archive.appendingPathComponent("PreparedTarget")
        if try ScreenshotMigrationIO.exists(legacy), !retained.contains(where: { $0.relativePath == "PreparedTarget" }) {
            guard original.stageAttempt == nil else { throw invalid("日志认领之后出现了未知旧暂存目录，已保留现物。") }
            let snapshot = try ScreenshotMigrationIO.snapshot(id: "Target", url: legacy, required: true)
            try validateLegacyPartial(snapshot, plan: original.plan, archive: archive)
            retained.append(.init(relativePath: "PreparedTarget", snapshot: snapshot,
                                  markerSHA256: snapshot.inventory[Self.initializationName]?.sha256, ownership: "legacy-marker"))
        }
        if let previous = original.stageAttempt {
            let path = archive.appendingPathComponent(previous.relativePath)
            if try ScreenshotMigrationIO.exists(path) {
                if let identity = previous.createdRoot {
                    guard try stageDirectoryIdentity(path) == identity else { throw invalid("已认领暂存目录的实物身份改变，已保留现物，未自动认领。") }
                } else {
                    guard try ScreenshotMigrationIO.exists(path.appendingPathComponent(Self.initializationName)) else {
                        throw invalid("暂存只有日志意图，缺少已创建目录身份或同计划标记，已保留现物，未自动认领。")
                    }
                }
                let snapshot = try ScreenshotMigrationIO.snapshot(id: "Target", url: path, required: true)
                guard snapshot.isDirectory else { throw invalid("日志认领的暂存路径已变成非目录，已停止恢复。") }
                if snapshot.inventory[Self.initializationName] != nil { try validateStageMarker(original.plan, archive: archive, at: path.appendingPathComponent(Self.initializationName)) }
                if previous.createdRoot == nil { try validateLegacyPartial(snapshot, plan: original.plan, archive: archive) }
                retained.append(.init(relativePath: previous.relativePath, snapshot: snapshot,
                                      markerSHA256: snapshot.inventory[Self.initializationName]?.sha256, ownership: "journal-attempt"))
            } else if previous.createdRoot != nil {
                throw invalid("已持久认领的暂存目录消失，已停止恢复，不能将缺失现物当空白跳过。")
            }
        }
        let name = "PreparedTarget-" + UUID().uuidString + ".noindex"
        guard try !ScreenshotMigrationIO.exists(archive.appendingPathComponent(name)) else { throw invalid("新暂存尝试路径已存在，未认领或覆盖。") }
        var journal = original
        journal.stageAttempt = .init(relativePath: name, planApprovalDigest: original.plan.approvalDigest,
                                     predecessorJournalSHA256: ScreenshotMigrationIO.sha(raw), createdAt: Self.now, retainedStages: retained)
        _ = try stageURL(journal, archive: archive)
        try saveJournal(journal, archive: archive, expectedRaw: raw)
        return journal
    }
    private func stageDirectoryIdentity(_ stage: URL) throws -> ScreenshotMigrationStageDirectoryIdentity {
        let fd = try ScreenshotMigrationIO.directory(stage); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else { throw invalid("暂存目录实物身份不可核验。") }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), uid: info.st_uid, mode: info.st_mode,
                     birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    private func createOwnedStage(_ stage: URL, archive: URL) throws -> ScreenshotMigrationStageDirectoryIdentity {
        guard ScreenshotMigrationIO.path(stage.deletingLastPathComponent()) == ScreenshotMigrationIO.path(archive), validStageName(stage.lastPathComponent) else { throw invalid("新暂存尝试路径不安全。") }
        let parent = try ScreenshotMigrationIO.directory(archive); defer { close(parent) }
        guard mkdirat(parent, stage.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else {
            throw invalid("日志已保留新暂存意图，但目录创建失败或现物冲突；未覆盖或删除。")
        }
        return try stageDirectoryIdentity(stage)
    }

    private func verifyArchive(_ plan: ScreenshotMigrationPlan, archive: URL) throws {
        for snapshot in plan.snapshots where snapshot.existed { try ScreenshotMigrationIO.requireSnapshot(snapshot, at: archive.appendingPathComponent(snapshot.id)) }
        try validateHistoryPolicy(snapshots: plan.snapshots, archive: archive)
    }
    private func commit(stage: URL, before: ScreenshotMigrationSnapshot) throws {
        guard try ScreenshotMigrationIO.snapshot(id: "Target", url: configuration.targetRoot, required: false) == before, before.inventory.isEmpty else { throw invalid("目标提交前已变化，未覆盖新资料。") }
        let parent = configuration.targetRoot.deletingLastPathComponent()
        try ScreenshotMigrationIO.createDirectory(parent)
        let parentFD = try ScreenshotMigrationIO.directory(parent); defer { close(parentFD) }
        let sourceParent = try ScreenshotMigrationIO.directory(stage.deletingLastPathComponent()); defer { close(sourceParent) }
        // POSIX can atomically replace an empty directory. A concurrently populated directory refuses the rename.
        // For an initially absent target use RENAME_EXCL, so a newly appearing empty root is also a conflict.
        let result = before.existed
            ? renameat(sourceParent, stage.lastPathComponent, parentFD, configuration.targetRoot.lastPathComponent)
            : renameatx_np(sourceParent, stage.lastPathComponent, parentFD, configuration.targetRoot.lastPathComponent, UInt32(RENAME_EXCL))
        guard result == 0 else { throw invalid("截图资料原子提交失败；暂存与归档均保留，目标未覆盖。") }
        guard fsync(parentFD) == 0 else { throw invalid("截图资料已提交但目录同步失败，请恢复迁移日志后再使用。") }
    }
    private func validateConfiguration() throws {
        let roots = [configuration.sourceRoot, configuration.targetRoot, configuration.archiveRoot]
        guard roots.allSatisfy({ $0.isFileURL && ScreenshotMigrationIO.path($0) != "/" }),
              configuration.archiveRoot.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else { throw invalid("迁移归档必须位于.noindex容器，来源与目标必须为明确本地目录。") }
        for i in roots.indices { for j in roots.indices where i != j { guard !ScreenshotMigrationIO.contains(roots[i], roots[j]) else { throw invalid("迁移来源、目标与归档不能互相包含。") } } }
        var auxiliaryIDs = Set<String>()
        for item in configuration.auxiliaries {
            guard Self.safeID(item.id), item.id != "Source", auxiliaryIDs.insert(item.id).inserted,
                  item.url.isFileURL, ScreenshotMigrationIO.path(item.url) != "/",
                  !ScreenshotMigrationIO.contains(item.url, configuration.targetRoot), !ScreenshotMigrationIO.contains(item.url, configuration.archiveRoot),
                  !ScreenshotMigrationIO.contains(configuration.targetRoot, item.url), !ScreenshotMigrationIO.contains(configuration.archiveRoot, item.url) else { throw invalid("辅助来源与目标/归档路径重叠。") }
        }
        let policies = configuration.auxiliaries.filter { $0.id == "LegacyHistoryPolicy" }
        if let policySHA = configuration.legacyHistoryPolicySHA256 {
            guard Self.validSHA(policySHA), policies.count == 1, policies[0].required else { throw invalid("旧历史人工策略必须显式选择必需的LegacyHistoryPolicy文件并绑定有效SHA256。") }
        } else if !policies.isEmpty {
            throw invalid("LegacyHistoryPolicy为保留辅助身份，必须同时提供人工确认的策略SHA256。")
        }
    }
    private func validateHistoryPolicy(snapshots: [ScreenshotMigrationSnapshot], archive: URL? = nil) throws {
        if let bindings = configuration.historicalManifestBindings {
            try ScreenshotMigrationHistoryPolicy.validateHistoricalManifestBindings(bindings, snapshots: snapshots)
        }
        guard let expectedSHA = configuration.legacyHistoryPolicySHA256 else { return }
        guard let selected = configuration.auxiliaries.first(where: { $0.id == "LegacyHistoryPolicy" }),
              let policy = snapshots.first(where: { $0.id == "LegacyHistoryPolicy" }),
              policy.existed, !policy.isDirectory, policy.inventory.count == 1,
              policy.originalPath == ScreenshotMigrationIO.path(selected.url),
              let file = policy.inventory["@file"], file.kind == "file", file.sha256 == expectedSHA else {
            throw invalid("旧历史人工策略必须是与预览绑定的完整原始文件，摘要不符时不能迁移或恢复。")
        }
        try ScreenshotMigrationHistoryPolicy.validateRawPolicy(at: archive?.appendingPathComponent(policy.id) ?? selected.url,
                                                             expectedSHA256: expectedSHA)
    }
    private func archiveURL(_ id: String) -> URL { configuration.archiveRoot.appendingPathComponent(id + ".noindex") }
    private func loadJournal(_ archive: URL) throws -> ScreenshotMigrationJournal {
        let journal = try ScreenshotMigrationIO.decode(ScreenshotMigrationJournal.self, from: archive.appendingPathComponent("Journal.json"))
        guard journal.schemaVersion == 1, journal.plan.schemaVersion == 1, ["prepared", "archived", "staged", "committed"].contains(journal.phase) else { throw invalid("迁移日志损坏或版本过新，不能作为空白覆盖。") }
        var plan = journal.plan; let approved = plan.approvalDigest; plan.approvalDigest = ""
        guard ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(plan)) == approved else { throw invalid("迁移预览摘要与日志不符，已停止恢复。") }
        _ = try stageURL(journal, archive: archive)
        return journal
    }
    private func saveJournal(_ journal: ScreenshotMigrationJournal, archive: URL, new: Bool = false, expectedRaw: Data? = nil) throws {
        let url = archive.appendingPathComponent("Journal.json")
        let data = try ScreenshotMigrationIO.encoder.encode(journal)
        if new { try ScreenshotMigrationIO.writeNew(data, to: url) }
        else { try ScreenshotMigrationIO.replace(data, at: url, expectedRaw: expectedRaw) }
    }
    private func result(_ plan: ScreenshotMigrationPlan, archive: URL, already: Bool) -> ScreenshotMigrationResult {
        .init(migrationID: plan.migrationID, archivePath: archive.path, alreadyApplied: already, retainedOnly: plan.retainedOnly)
    }
    private func lock() throws -> ScreenshotMigrationLock {
        try validateConfiguration()
        return try ScreenshotMigrationLock(url: configuration.archiveRoot.appendingPathComponent("Migration.lock"))
    }
    private func invalid(_ message: String) -> ScreenshotMigrationError { .invalid(message) }
    private static var now: String { ISO8601DateFormatter().string(from: Date()) }
    private static func safeID(_ text: String) -> Bool { !text.isEmpty && text.utf8.count < 200 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
    private static func validSHA(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validSourceID(_ text: String) -> Bool { let prefix = "com.gaoseries.GaoJieTu:"; return text.hasPrefix(prefix) && validSHA(String(text.dropFirst(prefix.count))) }
    private static func validDate(_ text: String) -> Bool { ISO8601DateFormatter().date(from: text) != nil }
    private static func isPointer(_ path: String) -> Bool { ["LatestInstallationBackup.txt", "LatestBackup.txt", "BackupRoot.txt", "Root.txt"].contains(URL(fileURLWithPath: path).lastPathComponent) }
    private static let defaultSettings: [String: Any] = ["schemaVersion": 1, "historyEnabled": false, "historyDays": 7, "historyCapacityMB": 512, "captureStrategy": "标注", "languages": ["zh-Hans", "en-US"], "silentOCRCopies": true, "pins": [String]()]
}

private final class ScreenshotMigrationLock {
    private var fd: Int32
    init(url: URL) throws {
        try ScreenshotMigrationIO.createDirectory(url.deletingLastPathComponent())
        let parent = try ScreenshotMigrationIO.directory(url.deletingLastPathComponent()); defer { Darwin.close(parent) }
        fd = openat(parent, url.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScreenshotMigrationError.invalid("迁移锁无法安全读取。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); fd = -1; throw ScreenshotMigrationError.invalid("已有截图资料迁移正在进行，或迁移锁不是可信普通文件。") }
    }
    func close() { if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
    deinit { close() }
}
