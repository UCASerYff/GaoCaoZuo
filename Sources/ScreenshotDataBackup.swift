import Foundation

/// Read-only validation of historical backup metadata. New backup creation is disabled.
enum ScreenshotDataBackup {
    struct Entry: Codable, Equatable, Sendable { var bytes: Int64; var sha256: String }
    struct MigrationEvidence: Codable, Equatable, Sendable {
        var originalArchivePath: String
        var migrationID: String
        var relativePath: String
        var snapshot: ScreenshotMigrationSnapshot
    }
    struct Report: Codable, Sendable {
        var schemaVersion = 3
        var createdAt = ISO8601DateFormatter().string(from: Date())
        var sourceExisted: Bool
        var inventory: [String: Entry]
        var restoreRehearsal = true
        var keychain = "untouched"
        var dataSnapshot: ScreenshotMigrationSnapshot?
        var migrationEvidence: MigrationEvidence?
        var retirementReceiptSHA256: String? = nil
        var restoreBindingNotice: String? = "Original absolute paths remain unchanged. Verification proves physical backup completeness only; restoring to another path requires a controlled rebind/migration-recovery transaction. No authorization is transferred."
    }

    static func inventory(_ root: URL) throws -> [String: Entry] {
        let snapshot = try ScreenshotMigrationIO.snapshot(id: "Source", url: root, required: false)
        guard !snapshot.existed || snapshot.isDirectory else { throw fail("截图资料根不是普通目录。") }
        return files(snapshot)
    }

    /// Retained only as a rejecting compatibility boundary for old callers.
    /// This version never creates an export, rehearsal or migration backup.
    static func create(root: URL, destination: URL) throws -> URL {
        throw fail("本版本已移除截图备份功能；现用资料与附件保留在原目录。")
    }

    /// Reads only backup-local evidence. The original source/archive may be offline or retired.
    static func verify(_ directory: URL) throws -> Report {
        let report = try ScreenshotMigrationIO.decode(Report.self, from: directory.appendingPathComponent("Verification.json"))
        guard [1, 2, 3].contains(report.schemaVersion), report.restoreRehearsal, report.keychain == "untouched" else { throw fail("截图备份版本、恢复演练或凭据保护记录不符。") }
        let data = directory.appendingPathComponent("Data")
        let actual = try ScreenshotMigrationIO.snapshot(id: "Source", url: data, required: true)
        guard actual.isDirectory, files(actual) == report.inventory else { throw fail("截图备份活动资料缺失或摘要不符。") }
        if report.schemaVersion >= 2 {
            guard report.sourceExisted, let expected = report.dataSnapshot,
                  expected.existed, expected.isDirectory, expected.inventory == actual.inventory,
                  files(expected) == report.inventory, report.restoreBindingNotice?.isEmpty == false else { throw fail("完整备份缺少活动目录拓扑或恢复路径约束记录。") }
        }
        let marker = try initialization(at: data)
        let retirement: ScreenshotSourceRetirementReceipt?
        if try ScreenshotMigrationIO.exists(data.appendingPathComponent(ScreenshotMigration.retirementReceiptName)) {
            guard report.schemaVersion == 3, let original = report.dataSnapshot, let receiptSHA = report.retirementReceiptSHA256,
                  ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.read(data.appendingPathComponent(ScreenshotMigration.retirementReceiptName))) == receiptSHA,
                  report.migrationEvidence == nil, try !ScreenshotMigrationIO.exists(directory.appendingPathComponent("MigrationEvidence.noindex")) else {
                throw fail("已退役截图备份收据缺失、摘要不符或仍夹带旧恢复归档。")
            }
            retirement = try ScreenshotMigration.inspectRetirementReceipt(at: data, originalActiveRoot: URL(fileURLWithPath: original.originalPath))
        } else {
            guard report.retirementReceiptSHA256 == nil else { throw fail("已退役截图备份缺少绑定的最小收据。") }
            retirement = nil
        }
        if let marker, marker.mode == "migrated", retirement == nil {
            guard let evidence = report.migrationEvidence, let originalData = report.dataSnapshot,
                  evidence.originalArchivePath == marker.archivePath, evidence.migrationID == marker.migrationID,
                  evidence.relativePath == "MigrationEvidence.noindex/" + evidence.migrationID + ".noindex",
                  ScreenshotMigrationValidation.safeRelative(evidence.relativePath), evidence.snapshot.existed, evidence.snapshot.isDirectory,
                  ScreenshotMigrationIO.path(URL(fileURLWithPath: evidence.originalArchivePath)) == ScreenshotMigrationIO.path(URL(fileURLWithPath: evidence.snapshot.originalPath)) else {
                throw fail("迁移活动目录缺少匹配的MigrationEvidence实物记录；不能仅凭Data称完整。")
            }
            let localArchive = directory.appendingPathComponent(evidence.relativePath)
            let container = try ScreenshotMigrationIO.snapshot(id: "EvidenceContainer", url: directory.appendingPathComponent("MigrationEvidence.noindex"), required: true, allowBundleLinks: true)
            let child = evidence.migrationID + ".noindex"
            var expectedContainer = [child: ScreenshotMigrationEntry(kind: "directory", bytes: 0, sha256: "")]
            for (path, entry) in evidence.snapshot.inventory { expectedContainer[child + "/" + path] = entry }
            guard container.isDirectory, container.inventory == expectedContainer else { throw fail("MigrationEvidence目录含缺失或未记录实物，不能忽略额外事务。") }
            try ScreenshotMigrationIO.requireSnapshot(evidence.snapshot, at: localArchive)
            let verified = try ScreenshotMigration.inspectCommittedArchive(at: localArchive, marker: marker,
                originalActiveRoot: URL(fileURLWithPath: originalData.originalPath))
            guard verified.inventory == evidence.snapshot.inventory else { throw fail("备份内迁移事务实物或摘要不符。") }
        } else {
            guard report.migrationEvidence == nil, try !ScreenshotMigrationIO.exists(directory.appendingPathComponent("MigrationEvidence.noindex")) else { throw fail("截图备份含未绑定的迁移证据目录，需显式核对，不能忽略。") }
        }
        return report
    }

    private static func initialization(at root: URL) throws -> ScreenshotModuleInitialization? {
        let file = root.appendingPathComponent(ScreenshotMigration.initializationName)
        guard try ScreenshotMigrationIO.exists(file) else { return nil }
        let marker = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: file)
        guard marker.schemaVersion == 1, marker.module == "com.gaoseries.GaoCaoZuo.Screenshot", ["fresh", "migrated"].contains(marker.mode) else { throw fail("截图模块初始化标记损坏或版本过新，备份停止。") }
        return marker
    }
    private static func protectedDestination(_ url: URL) -> URL {
        url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) ? url : url.appendingPathExtension("noindex")
    }
    private static func files(_ snapshot: ScreenshotMigrationSnapshot) -> [String: Entry] {
        snapshot.inventory.reduce(into: [:]) { result, pair in if pair.value.kind == "file" { result[pair.key] = .init(bytes: pair.value.bytes, sha256: pair.value.sha256) } }
    }
    private static func fail(_ text: String) -> ScreenshotMigrationError { .invalid(text) }
}
