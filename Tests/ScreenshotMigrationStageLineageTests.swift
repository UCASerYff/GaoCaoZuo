#if SCREENSHOT_MIGRATION_STAGE_LINEAGE_TESTS
import Foundation
import Darwin

/// Every path is generated under one private synthetic fixture. Never opens real business roots.
@main private enum ScreenshotMigrationStageLineageTests {
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }
    struct PlanOnly: Decodable { var plan: ScreenshotMigrationPlan }
    struct Fixture {
        var base: URL
        var configuration: ScreenshotMigrationConfiguration
        var plan: ScreenshotMigrationPlan
        var archive: URL { configuration.archiveRoot.appendingPathComponent(plan.migrationID + ".noindex") }
        var journal: URL { archive.appendingPathComponent("Journal.json") }
        var legacy: URL { archive.appendingPathComponent("PreparedTarget") }
    }
    static var assertions = 0
    static func main() {
        do {
            try interruptedOwnedAttemptsPreserveLegacyPartial()
            try intentWithoutDirectoryIsResumable()
            for corruption in ["noMarker", "wrongMarker", "changedSettings", "extraFile"] { try unclaimedPartialIsRejected(corruption) }
            try changedRetainedPartialIsRejected()
            try changedRetainedPartialBlocksStagedCommit()
            try intentCannotClaimPreexistingDirectory()
            try missingCreationReceiptBlocksRecovery()
            try replacedOwnedDirectoryIsRejected()
            try missingOwnedDirectoryIsRejected()
            try invalidAttemptPathIsRejected()
            try compareAndSwapBindsExpectedRaw()
            print("ScreenshotMigrationStageLineage: \(assertions) assertions passed; synthetic temporary fixtures only; no GUI or real recovery.")
        } catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw Failure(message: message) }
    }
    static func rejected(_ label: String, _ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try expect(failed, label)
    }
    static func put(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func json(_ value: [String: Any], _ url: URL) throws { try put(ScreenshotMigrationIO.json(value), url) }
    static func object(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ScreenshotMigrationIO.read(url)) as! [String: Any]
    }
    static func fixture() throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotStageLineage-" + UUID().uuidString + ".noindex")
        let source = base.appendingPathComponent("SyntheticSource"), target = base.appendingPathComponent("SyntheticReceiver/Screenshot")
        let configuration = ScreenshotMigrationConfiguration(sourceRoot: source, targetRoot: target,
            archiveRoot: base.appendingPathComponent("SyntheticArchive.noindex"), auxiliaries: [])
        try json(["schemaVersion": 1, "historyEnabled": false, "historyDays": 30, "historyCapacityMB": 512,
                  "captureStrategy": "保存", "saveDirectory": base.appendingPathComponent("NeverReadSaveDirectory").path,
                  "editorPath": "/SyntheticNeverOpened.app", "languages": ["zh-Hans"], "silentOCRCopies": false,
                  "pins": [String]()], source.appendingPathComponent("Settings.json"))
        try json(["schemaVersion": 1, "records": [[String: Any]]()], source.appendingPathComponent("PinnedImages.json"))
        let migration = ScreenshotMigration(configuration: configuration, fault: { point in
            if point == .afterArchiveVerified { throw Failure(message: "synthetic archive interruption") }
        })
        let plan = try migration.preview()
        let f = Fixture(base: base, configuration: configuration, plan: plan)
        try rejected("fixture stops after verified archive") { _ = try migration.apply(plan, approvedDigest: plan.approvalDigest) }
        try expect(try object(f.journal)["phase"] as? String == "archived", "fixture retains original archived transaction")
        return f
    }
    static func cleanup(_ f: Fixture) { try? FileManager.default.removeItem(at: f.base) }
    static func legacyPartial(_ f: Fixture) throws {
        var settings = try object(f.archive.appendingPathComponent("Source/Settings.json"))
        settings.removeValue(forKey: "saveDirectory"); settings.removeValue(forKey: "editorPath"); settings["captureStrategy"] = "标注"
        try json(settings, f.legacy.appendingPathComponent("Settings.json"))
        try put(ScreenshotMigrationIO.read(f.archive.appendingPathComponent("Source/PinnedImages.json")), f.legacy.appendingPathComponent("PinnedImages.json"))
        let marker = ScreenshotModuleInitialization(mode: "migrated", migrationID: f.plan.migrationID,
            sourceID: f.plan.sourceID, sourceSHA256: f.plan.sourceSHA256, createdAt: "2026-11-04T00:00:00Z", archivePath: f.archive.path)
        try put(ScreenshotMigrationIO.encoder.encode(marker), f.legacy.appendingPathComponent(ScreenshotMigration.initializationName))
    }
    static func attempt(_ f: Fixture) throws -> [String: Any] {
        guard let value = try object(f.journal)["stageAttempt"] as? [String: Any] else { throw Failure(message: "missing stage attempt") }
        return value
    }
    static func attemptURL(_ f: Fixture) throws -> URL {
        guard let path = try attempt(f)["relativePath"] as? String else { throw Failure(message: "missing stage path") }
        return f.archive.appendingPathComponent(path)
    }
    static func stopRecover(_ f: Fixture, at stopped: ScreenshotMigrationFaultPoint) throws {
        let migration = ScreenshotMigration(configuration: f.configuration, fault: { point in
            if point == stopped { throw Failure(message: "synthetic stage interruption") }
        })
        try rejected("synthetic recovery interruption at \(stopped)") { _ = try migration.recover(migrationID: f.plan.migrationID) }
    }
    static func interruptedOwnedAttemptsPreserveLegacyPartial() throws {
        let f = try fixture(); defer { cleanup(f) }; try legacyPartial(f)
        let legacy = try ScreenshotMigrationIO.snapshot(id: "Target", url: f.legacy, required: true)
        let source = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.configuration.sourceRoot, required: true)
        let originalJournal = try ScreenshotMigrationIO.read(f.journal)
        try stopRecover(f, at: .afterStageDirectoryCreated)
        let first = try attemptURL(f), firstAttempt = try attempt(f)
        try expect(first.lastPathComponent.hasSuffix(".noindex") && first != f.legacy, "new attempt is a separate unindexed path")
        try expect(firstAttempt["predecessorJournalSHA256"] as? String == ScreenshotMigrationIO.sha(originalJournal), "intent binds the exact predecessor journal bytes")
        try expect(firstAttempt["planApprovalDigest"] as? String == f.plan.approvalDigest, "attempt binds original approval without rewriting plan")
        try expect(try JSONDecoder().decode(PlanOnly.self, from: ScreenshotMigrationIO.read(f.journal)).plan == f.plan, "original plan remains exactly unchanged")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Target", url: first, required: true).inventory.isEmpty, "intent-owned directory may exist before a module marker")
        try ScreenshotMigrationIO.requireSnapshot(legacy, at: f.legacy)
        try expect(try !ScreenshotMigrationIO.exists(f.configuration.targetRoot), "interrupted attempt never publishes target")
        try stopRecover(f, at: .afterStagingVerified)
        let second = try attemptURL(f), secondAttempt = try attempt(f)
        try expect(second != first, "an archived retry creates another attempt")
        let retained = secondAttempt["retainedStages"] as! [[String: Any]]
        try expect(Set(retained.compactMap { $0["relativePath"] as? String }) == ["PreparedTarget", first.lastPathComponent], "legacy and journal-owned incomplete directory are both retained")
        try expect(try object(f.journal)["phase"] as? String == "staged", "complete expected target is written before commit")
        try expect(try (object(f.journal)["expectedTarget"] as? [String: Any])?["originalPath"] as? String == second.path, "expectedTarget binds the selected stage path")
        try ScreenshotMigrationIO.requireSnapshot(legacy, at: f.legacy)
        let result = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID)
        try expect(!result.alreadyApplied, "first staged recovery commits exactly once")
        try expect(try ScreenshotMigrationIO.path(attemptURL(f)) == ScreenshotMigrationIO.path(second), "staged recovery commits its existing attempt rather than making another")
        try expect(try !ScreenshotMigrationIO.exists(second) && ScreenshotMigrationIO.exists(first), "only selected complete stage is moved, prior directory remains")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Target", url: first, required: true).inventory.isEmpty, "previous marker-free owned attempt remains unchanged")
        try ScreenshotMigrationIO.requireSnapshot(legacy, at: f.legacy)
        try expect(try ScreenshotMigrationIO.snapshot(id: "Source", url: f.configuration.sourceRoot, required: true) == source, "all recovery stages leave the source unchanged")
        try expect(try object(f.journal)["phase"] as? String == "committed", "commit closes the same journal")
        let marker = try ScreenshotMigrationIO.decode(ScreenshotModuleInitialization.self, from: f.configuration.targetRoot.appendingPathComponent(ScreenshotMigration.initializationName))
        let copied = f.base.appendingPathComponent("CopiedEvidence.noindex"), journalBytes = try ScreenshotMigrationIO.read(f.journal)
        var evidence = try ScreenshotMigrationIO.snapshot(id: "MigrationEvidence", url: f.archive, required: true)
        evidence.originalPath = f.archive.path
        try ScreenshotMigrationIO.copy(evidence, to: copied)
        _ = try ScreenshotMigration.inspectCommittedArchive(at: copied, marker: marker, originalActiveRoot: f.configuration.targetRoot)
        try expect(try ScreenshotMigrationIO.read(copied.appendingPathComponent("Journal.json")) == journalBytes, "copied evidence keeps original absolute journal bytes unchanged")
        let backup = try ScreenshotDataBackup.create(root: f.configuration.targetRoot, destination: f.base.appendingPathComponent("SyntheticCompleteBackup.noindex"))
        let report = try ScreenshotDataBackup.verify(backup)
        try expect(report.restoreRehearsal && report.migrationEvidence != nil, "complete backup creation and copied archive verification retain stage-lineage evidence")
    }
    static func intentWithoutDirectoryIsResumable() throws {
        let f = try fixture(); defer { cleanup(f) }
        try stopRecover(f, at: .afterStageIntent)
        let unused = try attemptURL(f)
        try expect(try !ScreenshotMigrationIO.exists(unused), "journal intent exists before its stage directory")
        _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID)
        try expect(try (attemptURL(f)) != unused, "retry does not adopt an uncreated prior name")
        try expect(try !ScreenshotMigrationIO.exists(unused), "unused previous intent creates no artifact")
    }
    static func unclaimedPartialIsRejected(_ corruption: String) throws {
        let f = try fixture(); defer { cleanup(f) }; try legacyPartial(f)
        switch corruption {
        case "noMarker": try FileManager.default.removeItem(at: f.legacy.appendingPathComponent(ScreenshotMigration.initializationName))
        case "wrongMarker":
            let marker = f.legacy.appendingPathComponent(ScreenshotMigration.initializationName)
            var value = try object(marker); value["sourceID"] = "unrelated-synthetic-source"; try json(value, marker)
        case "changedSettings":
            let settings = f.legacy.appendingPathComponent("Settings.json")
            var value = try object(settings); value["historyDays"] = 90; try json(value, settings)
        default: try put(Data("unrecognized synthetic artifact".utf8), f.legacy.appendingPathComponent("Unexpected.txt"))
        }
        let partial = try ScreenshotMigrationIO.snapshot(id: "Target", url: f.legacy, required: true), before = try ScreenshotMigrationIO.read(f.journal)
        try rejected("\(corruption) cannot be automatically claimed") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before, "\(corruption) stops before journal intent mutation")
        try ScreenshotMigrationIO.requireSnapshot(partial, at: f.legacy)
        try expect(try !ScreenshotMigrationIO.exists(f.configuration.targetRoot), "\(corruption) leaves target absent")
    }
    static func changedRetainedPartialIsRejected() throws {
        let f = try fixture(); defer { cleanup(f) }; try legacyPartial(f)
        try stopRecover(f, at: .afterStageDirectoryCreated)
        try put(Data("synthetic later write".utf8), f.legacy.appendingPathComponent("AddedAfterBinding.txt"))
        let before = try ScreenshotMigrationIO.read(f.journal), owned = try attemptURL(f)
        try rejected("changed retained inventory stops a subsequent retry") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before && ScreenshotMigrationIO.exists(owned), "changed old stage is preserved without rebinding journal")
    }
    static func invalidAttemptPathIsRejected() throws {
        let f = try fixture(); defer { cleanup(f) }; try stopRecover(f, at: .afterStageIntent)
        var value = try object(f.journal), owned = value["stageAttempt"] as! [String: Any]
        owned["relativePath"] = "../Unowned.noindex"; value["stageAttempt"] = owned; try json(value, f.journal)
        let before = try ScreenshotMigrationIO.read(f.journal)
        try rejected("journal stage cannot escape its direct archive child") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before, "invalid stage intent remains untouched")
    }
    static func intentCannotClaimPreexistingDirectory() throws {
        let f = try fixture(); defer { cleanup(f) }; try stopRecover(f, at: .afterStageIntent)
        let unowned = try attemptURL(f)
        try put(Data("synthetic external occupant".utf8), unowned.appendingPathComponent("Unowned.txt"))
        let before = try ScreenshotMigrationIO.read(f.journal), evidence = try ScreenshotMigrationIO.snapshot(id: "Target", url: unowned, required: true)
        try rejected("intent alone cannot claim an externally occupied directory") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before, "unowned occupant blocks before rebinding journal")
        try ScreenshotMigrationIO.requireSnapshot(evidence, at: unowned)
    }
    static func missingCreationReceiptBlocksRecovery() throws {
        let f = try fixture(); defer { cleanup(f) }; try stopRecover(f, at: .afterStageDirectoryCreatedBeforeBinding)
        let unconfirmed = try attemptURL(f), before = try ScreenshotMigrationIO.read(f.journal)
        try expect(try ScreenshotMigrationIO.snapshot(id: "Target", url: unconfirmed, required: true).inventory.isEmpty, "synthetic crash exposes only an unconfirmed empty directory")
        try rejected("a crash before durable directory identity cannot auto-adopt even an empty directory") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before && ScreenshotMigrationIO.exists(unconfirmed), "unconfirmed directory is preserved and journal remains unchanged")
    }
    static func replacedOwnedDirectoryIsRejected() throws {
        let f = try fixture(); defer { cleanup(f) }; try stopRecover(f, at: .afterStageDirectoryCreated)
        let owned = try attemptURL(f), original = f.archive.appendingPathComponent("SyntheticMovedOwned.noindex")
        try FileManager.default.moveItem(at: owned, to: original)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let before = try ScreenshotMigrationIO.read(f.journal)
        try rejected("a different directory cannot inherit the owned path") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before && ScreenshotMigrationIO.exists(original), "directory identity mismatch preserves both directories")
    }
    static func missingOwnedDirectoryIsRejected() throws {
        let f = try fixture(); defer { cleanup(f) }; try stopRecover(f, at: .afterStageDirectoryCreated)
        let owned = try attemptURL(f)
        try FileManager.default.removeItem(at: owned)
        let before = try ScreenshotMigrationIO.read(f.journal)
        try rejected("missing durably owned directory is not treated as an uncreated intent") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before && !ScreenshotMigrationIO.exists(f.configuration.targetRoot), "missing owned artifact stops before journal rebinding or target publication")
    }
    static func changedRetainedPartialBlocksStagedCommit() throws {
        let f = try fixture(); defer { cleanup(f) }; try legacyPartial(f); try stopRecover(f, at: .afterStagingVerified)
        try put(Data("synthetic later retained change".utf8), f.legacy.appendingPathComponent("ChangedAfterStaging.txt"))
        let before = try ScreenshotMigrationIO.read(f.journal)
        try rejected("staged commit rechecks retained old partial inventory") { _ = try ScreenshotMigration(configuration: f.configuration).recover(migrationID: f.plan.migrationID) }
        try expect(try ScreenshotMigrationIO.read(f.journal) == before && !ScreenshotMigrationIO.exists(f.configuration.targetRoot), "retained change blocks target publication")
    }
    static func compareAndSwapBindsExpectedRaw() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotStageCAS-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("Journal.json"), original = Data("original synthetic journal".utf8), changed = Data("changed synthetic journal".utf8)
        try put(changed, file)
        try rejected("journal CAS refuses a different predecessor") { try ScreenshotMigrationIO.replace(original, at: file, expectedRaw: original) }
        try expect(try ScreenshotMigrationIO.read(file) == changed, "failed CAS does not rewrite a changed journal")
        try ScreenshotMigrationIO.replace(original, at: file, expectedRaw: changed)
        try expect(try ScreenshotMigrationIO.read(file) == original, "matching exact raw predecessor can be atomically replaced")
    }
}
#endif
