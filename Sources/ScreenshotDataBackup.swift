import Foundation

/// Before retirement includes the one committed archive; after retirement backs up live data and its minimal receipt only.
/// Verification proves retained bytes/topology and a copy rehearsal, never automatic runtime path rebinding.
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

    /// The returned URL is authoritative: a destination outside noindex ancestry gets a .noindex suffix before any App copy.
    static func create(root: URL, destination requestedDestination: URL) throws -> URL {
        let destination = protectedDestination(requestedDestination)
        guard !ScreenshotMigrationIO.contains(root, destination), !ScreenshotMigrationIO.contains(destination, root),
              try !ScreenshotMigrationIO.exists(requestedDestination), try !ScreenshotMigrationIO.exists(destination) else {
            throw fail("完整备份目标必须是资料外的新目录；已有请求路径或.noindex目标不会覆盖。")
        }
        let before = try ScreenshotMigrationIO.snapshot(id: "Source", url: root, required: true)
        guard before.isDirectory else { throw fail("截图资料根缺失或不是目录，不能构造空白备份。") }
        try ScreenshotMigrationValidation.validate(root: root, snapshot: before, logicalRoot: root)
        let marker = try initialization(at: root)
        let retirement = try ScreenshotMigration.inspectRetirementReceipt(at: root, originalActiveRoot: root)
        let evidence: MigrationEvidence?
        if let marker, marker.mode == "migrated", retirement == nil {
            guard let archivePath = marker.archivePath, let migrationID = marker.migrationID else { throw fail("迁移标记缺少归档身份，完整备份已停止。") }
            let archive = URL(fileURLWithPath: archivePath)
            guard !ScreenshotMigrationIO.contains(archive, destination), !ScreenshotMigrationIO.contains(destination, archive) else { throw fail("备份目标与本次迁移归档重叠，已停止递归备份。") }
            let snapshot = try ScreenshotMigration.inspectCommittedArchive(at: archive, marker: marker, originalActiveRoot: root)
            evidence = .init(originalArchivePath: archivePath, migrationID: migrationID,
                             relativePath: "MigrationEvidence.noindex/" + migrationID + ".noindex", snapshot: snapshot)
        } else { evidence = nil }
        try ScreenshotMigrationIO.createDirectory(destination)
        let data = destination.appendingPathComponent("Data")
        try ScreenshotMigrationIO.copy(before, to: data)
        if let evidence { try ScreenshotMigrationIO.copy(evidence.snapshot, to: destination.appendingPathComponent(evidence.relativePath)) }
        try ScreenshotMigrationIO.requireSnapshot(before, at: data)
        guard try ScreenshotMigrationIO.snapshot(id: "Source", url: root, required: true) == before else { throw fail("截图活动资料在备份时改变；来源和未完成备份均保留。") }
        if let evidence, let marker {
            let current = try ScreenshotMigration.inspectCommittedArchive(at: URL(fileURLWithPath: evidence.originalArchivePath), marker: marker, originalActiveRoot: root)
            guard current == evidence.snapshot else { throw fail("迁移归档在备份时改变，未确认完整备份成功。") }
            try ScreenshotMigrationIO.requireSnapshot(evidence.snapshot, at: destination.appendingPathComponent(evidence.relativePath))
        }

        // Rehearse BOTH the active data and the referenced archive. No source or marker is modified or rebound.
        let rehearsal = destination.appendingPathComponent("RestoreRehearsal.noindex")
        var dataCopy = before; dataCopy.originalPath = data.path
        try ScreenshotMigrationIO.copy(dataCopy, to: rehearsal.appendingPathComponent("Data"))
        try ScreenshotMigrationIO.requireSnapshot(before, at: rehearsal.appendingPathComponent("Data"))
        try ScreenshotMigrationValidation.validate(root: rehearsal.appendingPathComponent("Data"), snapshot: before, logicalRoot: root)
        if let evidence, let marker {
            var copiedEvidence = evidence.snapshot
            copiedEvidence.originalPath = destination.appendingPathComponent(evidence.relativePath).path
            let rehearsedArchive = rehearsal.appendingPathComponent(evidence.relativePath)
            try ScreenshotMigrationIO.copy(copiedEvidence, to: rehearsedArchive)
            try ScreenshotMigrationIO.requireSnapshot(evidence.snapshot, at: rehearsedArchive)
            let rehearsed = try ScreenshotMigration.inspectCommittedArchive(at: rehearsedArchive, marker: marker, originalActiveRoot: root)
            guard rehearsed.inventory == evidence.snapshot.inventory, rehearsed.isDirectory == evidence.snapshot.isDirectory else { throw fail("迁移归档恢复演练库存不符，未确认成功。") }
        }
        if retirement != nil {
            _ = try ScreenshotMigration.inspectRetirementReceipt(at: data, originalActiveRoot: root)
            _ = try ScreenshotMigration.inspectRetirementReceipt(at: rehearsal.appendingPathComponent("Data"), originalActiveRoot: root)
        }
        try FileManager.default.removeItem(at: rehearsal) // Only this new, fully verified rehearsal is discarded.
        let retiredSHA = retirement == nil ? nil : ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.read(root.appendingPathComponent(ScreenshotMigration.retirementReceiptName)))
        let report = Report(sourceExisted: true, inventory: files(before), dataSnapshot: before, migrationEvidence: evidence, retirementReceiptSHA256: retiredSHA)
        try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(report), to: destination.appendingPathComponent("Verification.json"))
        _ = try verify(destination)
        return destination
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
