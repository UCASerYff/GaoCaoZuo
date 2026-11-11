#if SCREENSHOT_MIGRATION_TESTS
import Foundation
import Darwin

@main enum ScreenshotMigrationTestMain {
    private struct TestFailure: LocalizedError { var message: String; var errorDescription: String? { message } }
    private struct Fixture {
        var base: URL
        var configuration: ScreenshotMigrationConfiguration
        var source: URL { configuration.sourceRoot }
        var target: URL { configuration.targetRoot }
        var archive: URL { configuration.archiveRoot }
    }
    private static var assertions = 0
    static func main() {
        do { try run(); print("ScreenshotMigration: \(assertions) assertions passed; isolated fixtures only; no GUI, capture, recording or permission requests.") }
        catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { assertions += 1; guard try condition() else { throw TestFailure(message: message) } }
    private static func rejected(_ message: String, _ work: () throws -> Void) throws { var failed = false; do { try work() } catch { failed = true }; try expect(failed, message) }
    private static func put(_ bytes: Data, _ path: URL) throws { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try bytes.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    private static func object(_ value: [String: Any], _ path: URL) throws { try put(ScreenshotMigrationIO.json(value), path) }
    private static func fixture() throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotMigration-Fixture-" + UUID().uuidString + ".noindex")
        let source = base.appendingPathComponent("Source")
        let backup = base.appendingPathComponent("GaoJieTu-Backups")
        let prefs = base.appendingPathComponent("SourcePreferences.plist")
        let initialization = base.appendingPathComponent("SourceInitialization.json")
        let external = base.appendingPathComponent("ExternalBackup.noindex")
        try object(["schemaVersion": 1, "historyEnabled": true, "historyDays": 30, "historyCapacityMB": 512,
            "captureStrategy": "保存", "saveDirectory": base.appendingPathComponent("UserChosenSaveDirectory").path,
            "editorPath": "/Applications/OriginalEditor.app", "languages": ["zh-Hans", "en-US"], "silentOCRCopies": false, "pins": [String]()], source.appendingPathComponent("Settings.json"))
        let image = Data("synthetic image bytes, never a real screenshot".utf8)
        try put(image, source.appendingPathComponent("History/asset.png"))
        try object(["schemaVersion": 1, "assets": [["id": UUID().uuidString, "createdAt": 1000.0, "source": "fixture", "pixelWidth": 2, "pixelHeight": 2,
            "colorSpace": "fixture", "scale": 1.0, "outputPath": "History/asset.png", "sha256": ScreenshotMigrationIO.sha(image), "editVersion": 0]]], source.appendingPathComponent("History.json"))
        try put(image, source.appendingPathComponent("Pins/pin.png"))
        try object(["schemaVersion": 1, "records": [["imagePath": source.appendingPathComponent("Pins/pin.png").path, "windowFrame": "{{1, 2}, {3, 4}}", "imageScale": 0.5, "opacity": 0.8]]], source.appendingPathComponent("PinnedImages.json"))
        let requestID = UUID().uuidString
        let stageID = UUID().uuidString
        let package = "Exchange/Outgoing/" + UUID().uuidString + ".gaoaction"
        let now = "2026-11-02T00:00:00Z"
        let payload = Data("unexecuted old request payload".utf8)
        let client = "com.academic-achievement.manager"
        let item: [String: Any] = ["id": "fixture-input", "relativePath": "payload/input.txt", "uti": "public.utf8-plain-text", "sha256": ScreenshotMigrationIO.sha(payload), "byteCount": payload.count]
        let request: [String: Any] = ["schemaVersion": 1, "kind": "request", "requestID": requestID, "sourceBundleID": client,
            "targetBundleID": "com.gaoseries.GaoJieTu", "action": "ocr.files", "createdAt": now, "expiresAt": "2026-11-02T00:02:00Z",
            "nonce": Data(repeating: 7, count: 32).base64EncodedString(), "items": [item], "references": [[String: Any]](), "parameters": ["outputs": ["text"]]]
        let requestBytes = try ScreenshotMigrationIO.json(request)
        try put(requestBytes, source.appendingPathComponent("Exchange/Staging/" + stageID + "/manifest.json"))
        try put(payload, source.appendingPathComponent("Exchange/Staging/" + stageID + "/0-input.txt"))
        try put(payload, source.appendingPathComponent(package + "/payload/input.txt"))
        try object(["schemaVersion": 1, "kind": "result", "requestID": UUID().uuidString, "inReplyTo": requestID,
            "sourceBundleID": "com.gaoseries.GaoJieTu", "targetBundleID": client, "action": "ocr.files", "status": "partial", "createdAt": now, "expiresAt": "2026-11-02T00:02:00Z",
            "nonce": Data(repeating: 9, count: 32).base64EncodedString(), "items": [item], "references": [[String: Any]](), "parameters": [:],
            "provenance": ["networkUsed": false]], source.appendingPathComponent(package + "/manifest.json"))
        try object(["schemaVersion": 1, "records": [["requestID": requestID, "manifestSHA256": ScreenshotMigrationIO.sha(requestBytes), "action": "ocr.files", "sourceBundleID": client,
            "kind": "request", "receivedAt": now, "updatedAt": now, "phase": "executing"]]], source.appendingPathComponent("Exchange/ProcessedRequests.json"))
        let ocrID = UUID().uuidString
        let options: [String: Any] = ["languages": ["zh-Hans", "en-US"], "recognitionLevel": "accurate", "languageCorrection": true, "enhanceContrast": false, "deskew": false,
            "pdfDPI": 144, "maxPages": 200, "maxPixelsPerPage": 12_000_000, "maxFileBytes": 536_870_912, "maximumConcurrency": 1, "memoryBudgetBytes": 268_435_456]
        let page: [String: Any] = ["id": UUID().uuidString, "sourceID": ocrID, "pageNumber": 1, "originalSHA256": ScreenshotMigrationIO.sha(payload), "status": "completed", "lines": [[String: Any]](),
            "mediaBox": [[0, 0], [2, 2]], "cropBox": [[0, 0], [2, 2]], "rotation": 0, "pixelWidth": 2, "pixelHeight": 2, "renderScale": 1,
            "elapsedSeconds": 0.02, "deskewAppliedDegrees": 0, "preprocessing": [String](), "coordinateSystem": "fixture"]
        try object(["schemaVersion": 1, "requestID": requestID, "createdAt": now,
            "sources": [["sourceID": ocrID, "sourceItemID": "fixture-input", "sourceSHA256": ScreenshotMigrationIO.sha(payload)]],
            "document": ["schemaVersion": 1, "id": UUID().uuidString, "createdAt": now, "engine": "Apple Vision VNRecognizeTextRequest", "engineRevision": 3, "operatingSystem": "fixture", "options": options,
                "sources": [["id": ocrID, "displayName": "input.txt", "sha256": ScreenshotMigrationIO.sha(payload), "byteCount": payload.count, "pageCount": 1, "isPDF": false]], "pages": [page], "wasCancelled": false]], source.appendingPathComponent("Exchange/Derived/OCRRecovery.json"))
        let recordingID = UUID().uuidString, partial = ".gao-recording-" + recordingID + ".partial.mov"
        try put(Data("not playable; retained unfinished recording fixture".utf8), source.appendingPathComponent("RecordingRecovery/" + partial))
        try object(["schemaVersion": 1, "sessionID": recordingID, "createdAt": now, "updatedAt": now, "partialFileName": partial, "requestedFileName": "record.mov",
            "state": "recording", "mode": "video", "sourceDescription": "synthetic fixture", "recoveryNote": "Unverified fixture; never played",
            "systemAudio": false, "microphone": false, "metrics": ["videoFrames": 1, "systemAudioBuffers": 0, "microphoneBuffers": 0, "droppedVideoFrames": 0, "droppedAudioBuffers": 0, "durationSeconds": 0.1, "processCPUSeconds": 0.02]], source.appendingPathComponent("RecordingRecovery/.gao-recording-" + recordingID + ".recovery.json"))
        try put(Data("retained deleted history fixture".utf8), source.appendingPathComponent("DeletedHistory/deleted.png"))
        try object(["schemaVersion": 1, "initialized": true], source.appendingPathComponent("Initialization.json"))
        try object(["schemaVersion": 1, "initialized": true], initialization)
        try put(try PropertyListSerialization.data(fromPropertyList: ["testPreference": "retained", "bookmark": Data([1, 2, 3])], format: .binary, options: 0), prefs)
        try put(Data("whole retained old backup".utf8), backup.appendingPathComponent("OldBackup.noindex/other.dat"))
        try put(Data("retained external backup".utf8), external.appendingPathComponent("outside.dat"))
        try put(Data((external.path + "\n").utf8), backup.appendingPathComponent("LatestInstallationBackup.txt"))
        let config = ScreenshotMigrationConfiguration(sourceRoot: source, targetRoot: base.appendingPathComponent("HostData/Screenshot"),
            archiveRoot: base.appendingPathComponent("Archives.noindex"), auxiliaries: [.init(id: "Backups", url: backup), .init(id: "Preferences", url: prefs), .init(id: "Initialization", url: initialization)])
        return Fixture(base: base, configuration: config)
    }
    private static func clean(_ f: Fixture) { try? FileManager.default.removeItem(at: f.base) }
    private static func retirementFixture() throws -> Fixture {
        let f = try fixture()
        // A separate settled-source fixture; the original fixture intentionally retains active producers.
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("Exchange"))
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("RecordingRecovery"))
        return f
    }
    private static func acceptance(_ plan: ScreenshotSourceRetirementPlan, in f: Fixture, businessVerified: Bool = true) throws -> URL {
        let value = ScreenshotSourceRetirementVerification(retirementPlanDigest: plan.approvalDigest, migrationID: plan.migrationID,
            sourceID: plan.sourceID, sourceSHA256: plan.sourceSHA256, verifiedAt: ISO8601DateFormatter().string(from: Date()),
            dataVerified: true, businessVerified: businessVerified, componentsVerified: true, installationVerified: true,
            releaseVerified: true, callersVerified: true, uniqueInstallationVerified: true)
        let path = f.base.appendingPathComponent("FixtureAcceptance-" + UUID().uuidString + ".json")
        try put(try ScreenshotMigrationIO.encoder.encode(value), path)
        return path
    }
    private static func runRetirementTests() throws {
        do {
            let f = try retirementFixture(); defer { clean(f) }
            let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            let marker = try ScreenshotMigrationIO.read(f.target.appendingPathComponent(ScreenshotMigration.initializationName))
            // Emulate an old committed candidate before ImportedActivity existed, with new user data already present.
            try FileManager.default.removeItem(at: f.target.appendingPathComponent("ImportedActivity"))
            try put(Data("new current user attachment".utf8), f.target.appendingPathComponent("CurrentNew.bin"))
            _ = try m.importActivity(plan)
            _ = try m.importActivity(plan)
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("CurrentNew.bin")) == Data("new current user attachment".utf8), "explicit committed activity supplement preserves later user files")
            let retirement = try m.retirementPreview(plan), evidence = try acceptance(retirement, in: f)
            try expect(retirement.deletionAllowlist.allSatisfy { $0.category == "migration-archive" }, "custom fixture source/backups/prefs are review-only, never default-source deletion authority")
            try expect(retirement.coordinatorReviewOnly.contains(f.source.path), "explicit arbitrary source path remains for coordinator ownership review")
            let receipt = try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence)
            try expect(receipt.phase == "finalized" && receipt.retirementPlanDigest == retirement.approvalDigest, "finalization binds the exact reviewed plan")
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent(ScreenshotMigration.initializationName)) == marker, "finalization never rewrites the original module marker")
            try expect(try ScreenshotMigrationIO.exists(f.source) && ScreenshotMigrationIO.exists(f.archive), "finalizer itself never deletes old source or archive")
            let receiptBytes = try ScreenshotMigrationIO.read(f.target.appendingPathComponent(ScreenshotMigration.retirementReceiptName))
            let text = String(data: receiptBytes, encoding: .utf8)!
            try expect(!text.contains("History/asset.png") && !text.contains("whole retained old backup") && !text.contains("synthetic image bytes"), "minimal receipt stores identities and digests without raw source recovery bytes")
            // Private fixture deletion simulates Root's later authorized cleanup, never a production deletion path.
            for snapshot in plan.snapshots where snapshot.existed {
                let url = URL(fileURLWithPath: snapshot.originalPath)
                if try ScreenshotMigrationIO.exists(url) { try FileManager.default.removeItem(at: url) }
            }
            try FileManager.default.removeItem(at: f.archive)
            try expect(try m.initialization()?.migrationID == plan.migrationID, "finalized module starts after all old source roots and archive are gone")
            try expect(try m.recover(migrationID: plan.migrationID).alreadyApplied, "finalized recovery is self-contained")
            try expect(try m.apply(plan, approvedDigest: plan.approvalDigest).alreadyApplied, "finalized old-plan reentry does not require or recreate source roots")
            try put(Data("later user write".utf8), f.target.appendingPathComponent("Later.bin"))
            var settings = try ScreenshotMigrationValidation.object(f.target.appendingPathComponent("Settings.json")); settings["historyDays"] = 91
            try object(settings, f.target.appendingPathComponent("Settings.json"))
            try expect(try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence) == receipt, "same retirement confirmation is idempotent after later live writes")
            try expect(try m.initialization()?.mode == "migrated", "receipt does not freeze mutable Settings or later attachments")
            try expect(try !ScreenshotMigrationIO.exists(f.archive), "self-contained calls never recreate a deleted archive root")
            let destination = f.base.appendingPathComponent("CurrentBackup.noindex")
            try rejected("removed backup never creates an output") { _ = try ScreenshotDataBackup.create(root: f.target, destination: destination) }
            try expect(try !ScreenshotMigrationIO.exists(destination), "disabled backup leaves no output")
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent(ScreenshotMigration.retirementReceiptName)) == receiptBytes, "disabled backup leaves live retirement receipt unchanged")
        }
        do {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try FileManager.default.removeItem(at: f.archive)
            try rejected("without finalized receipt a missing archive still blocks startup") { _ = try m.initialization() }
            try rejected("without finalized receipt a missing archive still blocks complete backup") { _ = try ScreenshotDataBackup.create(root: f.target, destination: f.base.appendingPathComponent("UnverifiedBackup.noindex")) }
        }
        do {
            let f = try fixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try rejected("an executing producer cannot be retired merely because its bytes were imported") { _ = try m.retirementPreview(plan) }
        }
        do {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            let retirement = try m.retirementPreview(plan)
            let falseEvidence = try acceptance(retirement, in: f, businessVerified: false)
            try rejected("static or incomplete business evidence cannot finalize source retirement") { _ = try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: falseEvidence) }
            let evidence = try acceptance(retirement, in: f)
            try put(Data("CAS concurrent user write".utf8), f.target.appendingPathComponent("AppearedAfterPreview.bin"))
            try rejected("a target changed after retirement preview requires a new plan") { _ = try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence) }
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent(ScreenshotMigration.retirementReceiptName)), "failed CAS publishes no finalized receipt")
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("AppearedAfterPreview.bin")) == Data("CAS concurrent user write".utf8), "failed CAS never rolls back newer user data")
        }
        for point in [ScreenshotMigrationFaultPoint.beforeRetirementReceipt, .afterRetirementReceipt] {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            let retirement = try m.retirementPreview(plan), evidence = try acceptance(retirement, in: f)
            let interrupted = ScreenshotMigration(configuration: f.configuration) { if $0 == point { throw TestFailure(message: "retirement interruption") } }
            try rejected("retirement fault is injected at \(point)") { _ = try interrupted.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence) }
            try expect(try ScreenshotMigrationIO.exists(f.source), "retirement partial failure leaves old source untouched")
            let receipt = try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence)
            try expect(receipt.phase == "finalized", "retirement retry resumes a missing receipt or returns the same already-published receipt")
        }
        do {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            let retirement = try m.retirementPreview(plan), evidence = try acceptance(retirement, in: f)
            let concurrent = ScreenshotMigration(configuration: f.configuration) { point in
                if point == .beforeRetirementReceipt { try put(Data("write immediately before publish".utf8), f.target.appendingPathComponent("Race.bin")) }
            }
            try rejected("last CAS detects a write immediately before receipt publication") { _ = try concurrent.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence) }
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent(ScreenshotMigration.retirementReceiptName)), "last CAS leaves the original migration authority in place")
        }
        for corruption in ["missing", "truncated", "source", "future", "unfinalized", "marker", "activity"] {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            let retirement = try m.retirementPreview(plan), evidence = try acceptance(retirement, in: f)
            var receipt = try m.finalizeSourceRetirement(retirement, approvedDigest: retirement.approvalDigest, verificationEvidence: evidence)
            let file = f.target.appendingPathComponent(ScreenshotMigration.retirementReceiptName)
            switch corruption {
            case "missing": try FileManager.default.removeItem(at: file)
            case "truncated": try put(Data("{bad".utf8), file)
            case "marker":
                var marker = try ScreenshotMigrationValidation.object(f.target.appendingPathComponent(ScreenshotMigration.initializationName)); marker["createdAt"] = "2020-01-01T00:00:00Z"
                try object(marker, f.target.appendingPathComponent(ScreenshotMigration.initializationName))
            case "activity": try put(Data("{bad".utf8), f.target.appendingPathComponent("ImportedActivity/Index.json"))
            default:
                if corruption == "source" { receipt.sourceID = "com.gaoseries.GaoJieTu:" + String(repeating: "b", count: 64) }
                if corruption == "future" { receipt.schemaVersion = 2 }
                if corruption == "unfinalized" { receipt.phase = "prepared" }
                receipt.receiptSHA256 = ""; receipt.receiptSHA256 = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(receipt))
                try put(try ScreenshotMigrationIO.encoder.encode(receipt), file)
            }
            try FileManager.default.removeItem(at: f.archive)
            try rejected("\(corruption) receipt cannot bypass missing old authority") { _ = try m.initialization() }
            try rejected("\(corruption) receipt cannot authorize a new backup") { _ = try ScreenshotDataBackup.create(root: f.target, destination: f.base.appendingPathComponent("BadBackup.noindex")) }
            try expect(try ScreenshotMigrationIO.exists(f.target.appendingPathComponent("History/asset.png")), "bad receipt preserves all current attachments")
        }
        do {
            let f = try retirementFixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try FileManager.default.removeItem(at: f.target.appendingPathComponent("ImportedActivity"))
            try put(Data("unrelated existing activity".utf8), f.target.appendingPathComponent("ImportedActivity/Keep.bin"))
            try rejected("supplement never overwrites an existing conflicting activity directory") { _ = try m.importActivity(plan) }
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("ImportedActivity/Keep.bin")) == Data("unrelated existing activity".utf8), "conflicting supplement leaves existing bytes unchanged")
        }
    }
    private static func run() throws {
        // Normal commit + no legacy execution + preserved source + durable inventory and source mapping.
        do {
            let f = try fixture(); defer { clean(f) }
            let m = ScreenshotMigration(configuration: f.configuration)
            let plan = try m.preview(); let original = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true)
            try expect(plan.snapshots.contains { $0.id.hasPrefix("External-") }, "pointer's external backup physical root is included")
            try expect(!FileManager.default.fileExists(atPath: f.target.path), "preview creates neither target nor defaults")
            let result = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try expect(!result.alreadyApplied && result.keychain == "untouched", "first commit reports correct authority and unchanged keychain")
            try expect(try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true) == original, "source bytes and topology are unchanged")
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("Exchange")), "old Exchange and executing ledger are never active")
            for name in ["DeletedHistory", "RecordingRecovery", "Initialization.json"] { try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent(name)), "recovery and original markers are audit-only") }
            let activity = try ScreenshotMigrationActivity.validate(root: f.target)
            try expect(activity.entries.allSatisfy { $0.readOnly && !$0.allowsExecution }, "retained activity is available without granting execution")
            try expect(try !ScreenshotMigrationActivity.blockers(root: f.target).isEmpty, "executing source activity prevents premature source retirement")
            let settings = try ScreenshotMigrationValidation.object(f.target.appendingPathComponent("Settings.json"))
            try expect(settings["saveDirectory"] == nil && settings["editorPath"] == nil && settings["captureStrategy"] as? String == "标注", "external path grants are not transferred")
            try expect(settings["historyEnabled"] as? Bool == true && settings["silentOCRCopies"] as? Bool == false, "other user settings are retained")
            let pins = try ScreenshotMigrationValidation.object(f.target.appendingPathComponent("PinnedImages.json"))["records"] as! [[String: Any]]
            try expect(pins[0]["imagePath"] as? String == f.target.appendingPathComponent("Pins/pin.png").path, "private pin path is mapped to the new module")
            try expect(try m.initialization()?.migrationID == plan.migrationID, "marker identifies the exact durable migration journal")
            try expect(try ScreenshotMigrationIO.exists(URL(fileURLWithPath: result.archivePath).appendingPathComponent("RestoreRehearsal.noindex/Source/Exchange/ProcessedRequests.json")), "full recovery rehearsal preserves old ledger")
            try put(Data("new user data".utf8), f.target.appendingPathComponent("NewData.bin"))
            var changed = settings; changed["historyDays"] = 90; try object(changed, f.target.appendingPathComponent("Settings.json"))
            let replay = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try expect(replay.alreadyApplied, "same plan is idempotent")
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("NewData.bin")) == Data("new user data".utf8), "idempotence preserves newer attachments")
            try expect(try ScreenshotMigrationValidation.object(f.target.appendingPathComponent("Settings.json"))["historyDays"] as? Int == 90, "idempotence never whole-store rolls back new settings")
            try FileManager.default.removeItem(at: f.source)
            try expect(try m.recover(migrationID: plan.migrationID).alreadyApplied, "committed recovery does not depend on retired source")
        }
        // Interruption points run through the same production implementation, not a fixture-only migration algorithm.
        let points: [ScreenshotMigrationFaultPoint] = [.afterPreparedJournal, .afterArchiveVerified, .afterStagingVerified, .afterTargetCommit, .beforeCommittedJournal]
        for point in points {
            let f = try fixture(); defer { clean(f) }
            let plan = try ScreenshotMigration(configuration: f.configuration).preview()
            let interrupted = ScreenshotMigration(configuration: f.configuration) { if $0 == point { throw TestFailure(message: "injected interruption") } }
            try rejected("fault must interrupt at \(point)") { _ = try interrupted.apply(plan, approvedDigest: plan.approvalDigest) }
            let m = ScreenshotMigration(configuration: f.configuration)
            if point == .afterTargetCommit || point == .beforeCommittedJournal { try rejected("uncommitted journal blocks production startup") { _ = try m.initialization() } }
            _ = try m.recover(migrationID: plan.migrationID)
            try expect(try m.initialization()?.migrationID == plan.migrationID, "recovery commits exact prepared transaction at \(point)")
            try expect(try m.apply(plan, approvedDigest: plan.approvalDigest).alreadyApplied, "recovered transaction remains idempotent at \(point)")
        }
        do {
            let f = try fixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration); let plan = try m.preview()
            try put(Data("source changed".utf8), f.source.appendingPathComponent("Later.bin"))
            try rejected("stale preview must not mutate target") { _ = try m.apply(plan, approvedDigest: plan.approvalDigest) }
            try expect(try !ScreenshotMigrationIO.exists(f.target), "stale preview leaves target absent")
        }
        do {
            let f = try fixture(); defer { clean(f) }; try put(Data("existing target".utf8), f.target.appendingPathComponent("Settings.json"))
            let m = ScreenshotMigration(configuration: f.configuration), plan = try m.preview()
            try expect(!plan.conflicts.isEmpty, "target conflicts appear explicitly in preview")
            try rejected("target conflicts stop import") { _ = try m.apply(plan, approvedDigest: plan.approvalDigest) }
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("Settings.json")) == Data("existing target".utf8), "target conflicts preserve existing bytes")
        }
        do {
            let f = try fixture(); defer { clean(f) }; let normal = ScreenshotMigration(configuration: f.configuration); let plan = try normal.preview()
            let interrupted = ScreenshotMigration(configuration: f.configuration) { if $0 == .afterStagingVerified { throw TestFailure(message: "fault") } }
            try rejected("staged interruption is injected") { _ = try interrupted.apply(plan, approvedDigest: plan.approvalDigest) }
            try put(Data("new target business".utf8), f.target.appendingPathComponent("NewBusiness.bin"))
            try rejected("recovery refuses concurrent target changes") { _ = try normal.recover(migrationID: plan.migrationID) }
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("NewBusiness.bin")) == Data("new target business".utf8), "recovery preserves target new data")
        }
        do {
            let f = try fixture(); defer { clean(f) }; let normal = ScreenshotMigration(configuration: f.configuration); let plan = try normal.preview()
            let interrupted = ScreenshotMigration(configuration: f.configuration) { if $0 == .afterTargetCommit { throw TestFailure(message: "fault after rename") } }
            try rejected("rename interruption is injected") { _ = try interrupted.apply(plan, approvedDigest: plan.approvalDigest) }
            let changed = Data("changed after rename, before journal commit".utf8)
            try put(changed, f.target.appendingPathComponent("History/asset.png"))
            try put(Data("new protected data".utf8), f.target.appendingPathComponent("NewProtected.bin"))
            try rejected("staged journal cannot falsely commit a changed target") { _ = try normal.recover(migrationID: plan.migrationID) }
            try rejected("changed staged target stays blocked") { _ = try normal.initialization() }
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("History/asset.png")) == changed, "failed staged recovery preserves changed attachment")
            try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("NewProtected.bin")) == Data("new protected data".utf8), "failed staged recovery preserves newly appearing target files")
        }
        for failure in ["missing", "corrupt", "future", "duplicate", "symlink", "pointer", "backup"] {
            let f = try fixture(); defer { clean(f) }
            switch failure {
            case "missing": try FileManager.default.removeItem(at: f.source.appendingPathComponent("History/asset.png"))
            case "corrupt": try put(Data("{bad".utf8), f.source.appendingPathComponent("Settings.json"))
            case "future": var settings = try ScreenshotMigrationValidation.object(f.source.appendingPathComponent("Settings.json")); settings["schemaVersion"] = 2; try object(settings, f.source.appendingPathComponent("Settings.json"))
            case "duplicate": try put(Data("{\"schemaVersion\":2,\"schemaVersion\":1}".utf8), f.source.appendingPathComponent("Settings.json"))
            case "symlink": try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("unsafe-link").path, withDestinationPath: "/private/tmp")
            case "pointer": try FileManager.default.removeItem(at: f.base.appendingPathComponent("ExternalBackup.noindex"))
            case "backup":
                let old = f.base.appendingPathComponent("GaoJieTu-Backups/Broken.noindex")
                try object(["schemaVersion": 1, "verified": true, "restoreRehearsal": true, "inventory": ["missing.dat": ["bytes": 1, "sha256": String(repeating: "a", count: 64)]]], old.appendingPathComponent("Verification.json"))
            default: break
            }
            try rejected("\(failure) stops before any default target write") { _ = try ScreenshotMigration(configuration: f.configuration).preview() }
            try expect(try !ScreenshotMigrationIO.exists(f.target), "\(failure) does not create blank target")
        }
        do {
            let f = try fixture(); defer { clean(f) }; let m = ScreenshotMigration(configuration: f.configuration)
            try rejected("fresh initialization cannot bypass real legacy evidence") { try m.initializeFresh() }
            try FileManager.default.removeItem(at: f.source)
            try rejected("missing source is never constructed as empty") { _ = try m.preview() }
            try rejected("remaining backups/preference/initialization still block fresh") { try m.initializeFresh() }
        }
        do {
            let f = try fixture(); defer { clean(f) }; var config = f.configuration
            let outside = f.base.appendingPathComponent("ChosenRecordingFolder")
            let sessionID = UUID().uuidString
            let partial = ".gao-recording-" + sessionID + ".partial.mov"
            let journal = outside.appendingPathComponent(".gao-recording-" + sessionID + ".recovery.json")
            let media = outside.appendingPathComponent(partial)
            try put(Data("external incomplete media fixture".utf8), media)
            try object(["schemaVersion": 1, "sessionID": sessionID, "createdAt": "2026-11-02T00:00:00Z", "updatedAt": "2026-11-02T00:00:00Z",
                "partialFileName": partial, "requestedFileName": "saved.mov", "state": "failed", "mode": "video", "sourceDescription": "external synthetic fixture", "recoveryNote": "Never decoded or played",
                "systemAudio": false, "microphone": false, "metrics": ["videoFrames": 1, "systemAudioBuffers": 0, "microphoneBuffers": 0, "droppedVideoFrames": 0, "droppedAudioBuffers": 0, "durationSeconds": 0.1, "processCPUSeconds": 0.02]], journal)
            let pointer = f.base.appendingPathComponent("ProjectPrivate/LatestInstallationBackup.txt")
            try put(Data((f.base.appendingPathComponent("ExternalBackup.noindex").path + "\n").utf8), pointer)
            config.auxiliaries.append(.init(id: "SelectedRecordingJournal", url: journal, required: true))
            config.auxiliaries.append(.init(id: "SelectedProjectBackupPointer", url: pointer, required: true))
            let m = ScreenshotMigration(configuration: config), plan = try m.preview()
            try expect(plan.snapshots.contains { $0.originalPath == media.path }, "a selected external recovery journal brings its exact partial media into the full snapshot")
            try expect(plan.snapshots.contains { $0.originalPath == f.base.appendingPathComponent("ExternalBackup.noindex").path }, "a selected standalone project pointer includes the exact backup root")
            _ = try m.apply(plan, approvedDigest: plan.approvalDigest)
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("unfinished.mov")), "external partial recording remains audit-only")
        }
        do {
            let f = try fixture(); defer { clean(f) }
            let config = ScreenshotMigrationConfiguration(sourceRoot: f.base.appendingPathComponent("NoSource"), targetRoot: f.target, archiveRoot: f.archive, auxiliaries: [])
            let m = ScreenshotMigration(configuration: config)
            try m.initializeFresh()
            try expect(try m.initialization()?.mode == "fresh", "source-free fresh initialization is explicit and marked")
            try expect(try ScreenshotMigrationValidation.object(f.target.appendingPathComponent("Settings.json"))["historyEnabled"] as? Bool == false, "fresh history remains disabled")
            try m.initializeFresh()
            try expect(try m.initialization()?.mode == "fresh", "fresh initialization is idempotent")
        }
        // Full backup creation is retired. Existing migration compatibility tests above
        // continue to validate their own transactions without new backup exports.
        do {
            let f = try fixture(); defer { clean(f) }
            let destination = f.base.appendingPathComponent("RemovedBackup.noindex")
            try rejected("backup creation is unavailable") { _ = try ScreenshotDataBackup.create(root: f.target, destination: destination) }
            try expect(try !ScreenshotMigrationIO.exists(destination), "disabled backup cannot create a rehearsal or data copy")
        }
        try runRetirementTests()
        try runScreenshotMigrationActivityTests()
    }
}
#endif
