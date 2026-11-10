#if SCREENSHOT_MIGRATION_MAINTENANCE_TESTS
import Foundation
import Darwin

/// Synthetic maintenance documents only. Calls the shared production validator and archive IO;
/// never opens the real legacy business or backup roots, starts an app, or executes a plan.
private enum ScreenshotMaintenanceMetadataFixtureSuite {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    enum Profile: Equatable { case task1, ocr }
    struct Fixture {
        let base: URL
        let planName: String
        let plan: [String: Any]
        var container: URL { base.appendingPathComponent("SyntheticBackups.noindex") }
        var backup: URL { container.appendingPathComponent("SyntheticMaintenance.noindex") }
        var data: URL { backup.appendingPathComponent("Data") }
        var planURL: URL { backup.appendingPathComponent(planName) }
        var logicalRoot: URL { base.appendingPathComponent("SyntheticLegacyBusinessNeverOpened") }
        var archive: URL { base.appendingPathComponent("Archive.noindex") }
        var sentinel: URL { base.appendingPathComponent("SyntheticTargetMustRemain.txt") }
    }
    typealias Role = ScreenshotMigrationValidation.AuxiliaryRole
    static let requestID = "1A14B602-64C2-4428-9C63-88A754C97F10"
    static let payload = Data("Synthetic retained bytes; no personal document, screenshot or recording.\n".utf8)
    static var assertions = 0
    static var negativeCases = 0

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw Failure(message: "MaintenanceMetadata: " + message) }
    }
    static func rejected(_ message: String, _ operation: () throws -> Void) throws {
        var denied = false
        do { try operation() } catch { denied = true }
        try expect(denied, message)
    }
    static func put(_ bytes: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func json(_ value: [String: Any], _ url: URL) throws { try put(ScreenshotMigrationIO.json(value), url) }
    static func planBytes(_ value: [String: Any]) throws -> Data {
        // Extra whitespace makes preservation observable independently of a canonical re-encoding.
        var bytes = Data("\n  ".utf8)
        bytes.append(try ScreenshotMigrationIO.json(value)); bytes.append(Data("\n\t".utf8))
        return bytes
    }
    static func replacePlan(_ f: Fixture, _ value: [String: Any]) throws { try put(planBytes(value), f.planURL) }
    static func cleanup(_ f: Fixture) { try? FileManager.default.removeItem(at: f.base) }
    static func settings() -> [String: Any] {
        ["schemaVersion": 1, "historyEnabled": false, "silentOCRCopies": false,
         "historyDays": 30, "historyCapacityMB": 512, "captureStrategy": "标注",
         "languages": ["zh-Hans"], "pins": [String]()]
    }
    static func refreshVerification(_ f: Fixture) throws {
        let data = try ScreenshotMigrationIO.snapshot(id: "SyntheticData", url: f.data, required: true)
        var inventory: [String: [String: Any]] = [:]
        for (name, entry) in data.inventory where entry.kind == "file" {
            inventory[name] = ["bytes": entry.bytes, "sha256": entry.sha256]
        }
        let directories = data.inventory.filter { $0.value.kind == "directory" }.map(\.key).sorted()
        try json(["schemaVersion": 1, "verified": true, "restoreRehearsal": true,
                  "inventory": inventory, "directories": directories], f.backup.appendingPathComponent("Verification.json"))
    }
    static func fixture(_ profile: Profile = .task1, name: String = "CleanupPlan.json") throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotMaintenance-" + UUID().uuidString + ".noindex")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let targetPath = base.appendingPathComponent("SyntheticTargetMustRemain.txt").path
            let inventory: [String: Any] = ["synthetic.txt": ["bytes": payload.count, "sha256": ScreenshotMigrationIO.sha(payload)]]
            var target: [String: Any] = ["path": targetPath, "relativePath": "Exchange/Derived/" + requestID,
                                         "area": "Derived", "files": inventory, "directories": [String]()]
            var plan: [String: Any] = ["schemaVersion": 2, "preparedAtUTC": "2026-11-04T00:00:00.125Z",
                "beforeInventory": inventory, "beforeDirectories": ["Exchange", "Exchange/Derived"],
                "beforeLedger": ["schemaVersion": 1, "records": [[String: Any]]()],
                "beforeIntegrity": ["synthetic": true],
                "fullCleanupBackup": base.appendingPathComponent("NeverFollowThisPlanPath.noindex").path,
                "backupVerified": true, "restoreRehearsal": true, "summary": ["synthetic": true]]
            switch profile {
            case .task1:
                target["identity"] = [7, 23, 501]
                plan["requests"] = [["requestID": requestID, "action": "images.annotate", "providerRecord": ["phase": "completed"]]]
                plan["providerLedgerSHA256"] = ScreenshotMigrationIO.sha(Data("Synthetic Task1 ledger".utf8))
                plan["status"] = "Synthetic historical maintenance metadata"
                plan["authorization"] = "Synthetic archived text grants no current execution permission"
                plan["baselineInstallationBackup"] = base.appendingPathComponent("NeverFollowInstallationPointer.noindex").path
                plan["retainedBoundary"] = "Synthetic boundary"
                plan["GUI"] = "No GUI performed by this fixture"
                plan["baselineFileCount"] = 1; plan["baselineLedgerRecordCount"] = 0
                plan["callerEvidenceReadOnly"] = [String]()
            case .ocr:
                target["identity"] = ["device": 7, "inode": 23, "uid": 501, "mode": 33152]
                plan["mode"] = "Synthetic read-only maintenance preparation"
                plan["requestID"] = requestID; plan["executionAuthorizedByThisPreparation"] = false
                for key in ["beforeLedgerSHA256", "plannedAfterLedgerSHA256", "backupVerificationSHA256"] {
                    plan[key] = ScreenshotMigrationIO.sha(Data(("Synthetic " + key).utf8))
                }
                plan["plannedAfterLedger"] = ["schemaVersion": 1, "records": [[String: Any]]()]
                plan["expectedAfterInventory"] = inventory; plan["expectedAfterDirectories"] = [String]()
                plan["tool"] = ["path": base.appendingPathComponent("NeverExecuteMissingTool.py").path,
                                "sha256": ScreenshotMigrationIO.sha(Data("Synthetic nonexistent tool identity".utf8))]
                plan["transactionStrategy"] = ["Synthetic archived description only"]
                plan["recoveryStrategy"] = ["synthetic": true]
            }
            plan["targets"] = [target]
            let f = Fixture(base: base, planName: name, plan: plan)
            try put(payload, f.sentinel)
            try json(settings(), f.data.appendingPathComponent("Settings.json"))
            try put(payload, f.data.appendingPathComponent("Attachments/synthetic.txt"))
            try json(["schemaVersion": 1, "bundleID": "com.gaoseries.GaoJieTu", "hadPreviousApp": false],
                     f.backup.appendingPathComponent("Installation.json"))
            try refreshVerification(f)
            try replacePlan(f, plan)
            return f
        } catch { try? FileManager.default.removeItem(at: base); throw error }
    }
    static func validate(_ f: Fixture, role: Role, root: URL? = nil) throws {
        let selected: URL
        if let root { selected = root }
        else {
            switch role { case .legacyBackupRoot: selected = f.backup; default: selected = f.container }
        }
        let snapshot = try ScreenshotMigrationIO.snapshot(id: "SyntheticAuxiliary", url: selected, required: true)
        try ScreenshotMigrationValidation.validateAuxiliary(root: selected, snapshot: snapshot, logicalRoot: f.logicalRoot, role: role)
    }
    static func denied(_ label: String, profile: Profile = .task1, name: String = "CleanupPlan.json",
                       change: (Fixture) throws -> Void = { _ in }) throws {
        let f = try fixture(profile, name: name); defer { cleanup(f) }
        try change(f)
        negativeCases += 1
        try rejected(label + " is rejected in a backup container") { try validate(f, role: .legacyBackupContainer) }
        try rejected(label + " is rejected at an explicit backup root") { try validate(f, role: .legacyBackupRoot) }
        try expect(try ScreenshotMigrationIO.read(f.sentinel) == payload, label + " never executes a target")
    }

    static func knownProfilesRetainRawArchiveBytes() throws {
        let profiles: [(Profile, String)] = [(.task1, "CleanupPlan.json"), (.ocr, "CleanupPlan-20261026.json"),
                                            (.ocr, "CleanupPlan-20261026-ReviewedDriver.json")]
        for (profile, name) in profiles {
            let f = try fixture(profile, name: name); defer { cleanup(f) }
            let before = try ScreenshotMigrationIO.snapshot(id: "SyntheticAuxiliary", url: f.container, required: true)
            let bytes = try ScreenshotMigrationIO.read(f.planURL), digest = ScreenshotMigrationIO.sha(bytes)
            try validate(f, role: .legacyBackupContainer)
            try validate(f, role: .legacyBackupRoot)
            try expect(true, name + " is accepted under both explicit backup roles")
            try rejected("object() retains its schema-1 default for " + name) { _ = try ScreenshotMigrationValidation.object(f.planURL) }
            try ScreenshotMigrationIO.copy(before, to: f.archive)
            try ScreenshotMigrationIO.requireSnapshot(before, at: f.archive)
            let archiveRoot = f.archive.appendingPathComponent("SyntheticMaintenance.noindex")
            try validate(f, role: .legacyBackupContainer, root: f.archive)
            try validate(f, role: .legacyBackupRoot, root: archiveRoot)
            let archived = try ScreenshotMigrationIO.read(archiveRoot.appendingPathComponent(name))
            try expect(archived == bytes, name + " archive preserves exact original whitespace and bytes")
            try expect(ScreenshotMigrationIO.sha(archived) == digest, name + " archive preserves original SHA256")
            try expect(before.inventory["SyntheticMaintenance.noindex/" + name]?.sha256 == digest, name + " raw SHA is bound by the production snapshot")
            try expect(try ScreenshotMigrationIO.snapshot(id: before.id, url: f.container, required: true) == before,
                       name + " validation and archival leave the original complete inventory unchanged")
            try expect(try ScreenshotMigrationIO.read(f.sentinel) == payload, name + " internal target path is never executed")
        }
    }

    static func schemaAndLocationBoundaries() throws {
        let unsupported: [(String, Any)] = [("schema-0", 0), ("schema-3", 3), ("schema-string", "2"),
                                           ("schema-bool", true), ("schema-fraction", 2.5)]
        for (label, schema) in unsupported {
            try denied(label) { f in var value = f.plan; value["schemaVersion"] = schema; try replacePlan(f, value) }
        }
        // Preserve number spelling: JSONSerialization may canonicalize 2.0 when writing a dictionary.
        for token in ["2.0", "2e0"] {
            try denied("schema-noninteger-token-" + token) { f in
                var rest = f.plan; rest.removeValue(forKey: "schemaVersion")
                let tail = String(String(decoding: try ScreenshotMigrationIO.json(rest), as: UTF8.self).dropFirst())
                try put(Data(("{\"schemaVersion\":" + token + "," + tail).utf8), f.planURL)
            }
        }
        for name in ["Settings.json", "Verification.json", "Installation.json", "manifest.json",
                     "recording.recovery.json", "UnknownPlan.json"] {
            try denied("reserved-or-unknown-" + name, name: name)
        }
        try denied("Data-location") { f in
            try FileManager.default.moveItem(at: f.planURL, to: f.data.appendingPathComponent("CleanupPlan.json"))
            try refreshVerification(f)
        }
        let f = try fixture(); defer { cleanup(f) }
        negativeCases += 1
        try rejected("generic auxiliary never selects the maintenance exception") { try validate(f, role: .generic) }
        let snapshot = try ScreenshotMigrationIO.snapshot(id: "Backups", url: f.container, required: true)
        try rejected("an auxiliary ID cannot override the default generic role") {
            try ScreenshotMigrationValidation.validateAuxiliary(root: f.container, snapshot: snapshot, logicalRoot: f.logicalRoot)
        }
        try rejected("container role cannot classify a direct backup root") { try validate(f, role: .legacyBackupContainer, root: f.backup) }
        try rejected("root role cannot classify a backup container") { try validate(f, role: .legacyBackupRoot, root: f.container) }
        try denied("no-backup-envelope") { f in try FileManager.default.removeItem(at: f.backup.appendingPathComponent("Verification.json")) }
        try denied("future-embedded-ledger") { f in
            var value = f.plan; value["beforeLedger"] = ["schemaVersion": 2, "records": [[String: Any]]()]; try replacePlan(f, value)
        }
        try denied("wrong-maintenance-shape") { f in var value = f.plan; value["beforeInventory"] = [Any](); try replacePlan(f, value) }
        try denied("ocr-executable-claim", profile: .ocr, name: "CleanupPlan-20261026.json") { f in
            var value = f.plan; value["executionAuthorizedByThisPreparation"] = true; try replacePlan(f, value)
        }
        try denied("duplicate-JSON-keys") { f in
            var rest = f.plan; rest.removeValue(forKey: "schemaVersion")
            let tail = String(String(decoding: try ScreenshotMigrationIO.json(rest), as: UTF8.self).dropFirst())
            try put(Data(("{\"schemaVersion\":2,\"schemaVersion\":1," + tail).utf8), f.planURL)
        }
    }

    static func profileAndPhysicalEnvelopeBoundaries() throws {
        for profile in [Profile.task1, .ocr] {
            try denied("wrong-profile-target-identity-" + (profile == .task1 ? "Task1" : "OCR"), profile: profile) { f in
                var value = f.plan, targets = value["targets"] as! [[String: Any]]
                if profile == .task1 { targets[0]["identity"] = ["device": 7, "inode": 23, "uid": 501, "mode": 33152] }
                else { targets[0]["identity"] = [7, 23, 501] }
                value["targets"] = targets; try replacePlan(f, value)
            }
        }
        try denied("future-planned-after-ledger", profile: .ocr) { f in
            var value = f.plan; value["plannedAfterLedger"] = ["schemaVersion": 2, "records": [[String: Any]]()]; try replacePlan(f, value)
        }
        try denied("Verification-must-still-match-physical-data") { f in
            try json(["schemaVersion": 1, "verified": true, "restoreRehearsal": true, "inventory": [String: Any]()],
                     f.backup.appendingPathComponent("Verification.json"))
        }
        try denied("Installation-must-still-have-declared-previous-app") { f in
            try json(["schemaVersion": 1, "bundleID": "com.gaoseries.GaoJieTu", "hadPreviousApp": true,
                      "previousVersion": "1.00", "previousBuild": "1"], f.backup.appendingPathComponent("Installation.json"))
        }
        try denied("Data-business-settings-remain-schema-1") { f in
            var value = settings(); value["schemaVersion"] = 2
            try json(value, f.data.appendingPathComponent("Settings.json")); try refreshVerification(f)
        }
        try denied("business-manifest-remains-schema-1") { f in
            try json(["schemaVersion": 2, "kind": "request", "requestID": requestID],
                     f.data.appendingPathComponent("Exchange/Staging/" + requestID + "/manifest.json"))
            try refreshVerification(f)
        }
        try denied("OCR-recovery-remains-schema-1") { f in
            try json(["schemaVersion": 2, "requestID": requestID, "document": [String: Any](), "sources": [Any]()],
                     f.data.appendingPathComponent("OCRRecovery.json"))
            try refreshVerification(f)
        }
    }

    static func schemaOneAndUnversionedDefaultsRemain() throws {
        let f = try fixture(); defer { cleanup(f) }
        // A v1 maintenance file never needed a typed cleanup profile; preserve that original contract.
        try replacePlan(f, ["schemaVersion": 1, "syntheticLegacyText": "Uninterpreted v1 auxiliary metadata"])
        try validate(f, role: .generic)
        try validate(f, role: .legacyBackupContainer)
        try validate(f, role: .legacyBackupRoot)
        let value = try ScreenshotMigrationValidation.object(f.planURL)
        try expect((value["schemaVersion"] as? NSNumber)?.intValue == 1, "schema-1 object defaults remain available")
        let data = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.data, required: true)
        try ScreenshotMigrationValidation.validate(root: f.data, snapshot: data, logicalRoot: f.logicalRoot)
        try expect(true, "valid schema-1 business settings and attachments still validate")
        try replacePlan(f, ["syntheticUnversionedText": "Existing object() semantics permit absent schemaVersion"])
        try validate(f, role: .generic)
        try expect(try ScreenshotMigrationValidation.object(f.planURL)["schemaVersion"] == nil, "unversioned generic metadata keeps its original object contract")
        try expect(try ScreenshotMigrationIO.read(f.sentinel) == payload, "schema-1 compatibility never executes archived text")
    }

    static func run() throws -> (Int, Int) {
        assertions = 0; negativeCases = 0
        try knownProfilesRetainRawArchiveBytes()
        try schemaAndLocationBoundaries()
        try profileAndPhysicalEnvelopeBoundaries()
        try schemaOneAndUnversionedDefaultsRemain()
        return (assertions, negativeCases)
    }
}

@main enum ScreenshotMigrationMaintenanceMetadataTestMain {
    static func main() {
        do {
            let (assertions, boundaries) = try ScreenshotMaintenanceMetadataFixtureSuite.run()
            print("ScreenshotMigrationMaintenanceMetadata: \(assertions) assertions passed; 3 schema-2 maintenance samples in both backup roles; \(boundaries) negative boundaries; synthetic fixtures only; no GUI, capture or real data.")
        } catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
#endif
