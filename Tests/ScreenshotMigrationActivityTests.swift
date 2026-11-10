#if SCREENSHOT_MIGRATION_TESTS
import Foundation

/// Isolated Foundation fixtures only. The serial build owner calls this from ScreenshotMigrationMain.
func runScreenshotMigrationActivityTests() throws {
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw Failure(message: "Activity: " + message) } }
    func rejected(_ label: String, _ operation: () throws -> Void) throws { var failed = false; do { try operation() } catch { failed = true }; try expect(failed, label) }
    func put(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func json(_ value: [String: Any], _ url: URL) throws { try put(ScreenshotMigrationIO.json(value), url) }
    let timestamp = "2026-11-02T00:00:00Z"
    let payload = Data("Synthetic OCR source; no screen or microphone used".utf8)
    let hash = ScreenshotMigrationIO.sha(payload)
    let client = "com.academic-achievement.manager"
    let oldProvider = "com.gaoseries.GaoJieTu"
    func manifest(id: String, kind: String = "request", status: String? = nil, reply: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["schemaVersion": 1, "kind": kind, "requestID": id, "sourceBundleID": kind == "request" ? client : oldProvider,
            "targetBundleID": kind == "request" ? oldProvider : client, "action": "ocr.files", "createdAt": timestamp, "expiresAt": "2026-11-02T00:02:00Z",
            "nonce": Data(repeating: 7, count: 32).base64EncodedString(), "items": [["id": "input", "relativePath": "payload/input.txt", "uti": "public.utf8-plain-text", "byteCount": payload.count, "sha256": hash]],
            "references": [[String: Any]](), "parameters": ["outputs": ["text"]]]
        if kind == "result" { value["status"] = status!; value["inReplyTo"] = reply!; value["provenance"] = ["networkUsed": false] }
        return value
    }
    struct Fixture { var base: URL; var source: URL; var target: URL; var archive: URL; var plan: ScreenshotMigrationPlan; var requestID: String; var stagedPath: String }
    func fixture(phase: String = "completed", withOCR: Bool = false, passiveResult: Bool = false, pending: Bool = false, recording: Bool = false, recordingState: String = "failed") throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotActivity-" + UUID().uuidString + ".noindex")
        let source = base.appendingPathComponent("Legacy"), target = base.appendingPathComponent("Host/Screenshot"), archive = base.appendingPathComponent("Archive.noindex")
        try json(["schemaVersion": 1, "historyEnabled": false, "historyDays": 30, "historyCapacityMB": 512, "captureStrategy": "标注", "languages": ["zh-Hans"], "silentOCRCopies": false, "pins": [String]()], source.appendingPathComponent("Settings.json"))
        let requestID = UUID().uuidString, stageID = UUID().uuidString
        let stagedPath = "Exchange/Staging/" + stageID + "/manifest.json"
        let request = manifest(id: requestID, kind: passiveResult ? "result" : "request", status: passiveResult ? "completed" : nil, reply: passiveResult ? UUID().uuidString : nil)
        // A passive result came from another provider and targets the old screenshot receiver.
        var input = request
        if passiveResult { input["sourceBundleID"] = "com.gaoseries.GaoWenJian"; input["targetBundleID"] = oldProvider }
        let bytes = try ScreenshotMigrationIO.json(input)
        try put(bytes, source.appendingPathComponent(stagedPath))
        try put(payload, source.appendingPathComponent("Exchange/Staging/" + stageID + "/0-input.txt"))
        var record: [String: Any] = ["requestID": requestID, "manifestSHA256": ScreenshotMigrationIO.sha(bytes), "action": "ocr.files", "sourceBundleID": passiveResult ? "com.gaoseries.GaoWenJian" : client,
            "kind": passiveResult ? "result" : "request", "receivedAt": timestamp, "updatedAt": timestamp, "phase": passiveResult ? "received" : phase]
        if !passiveResult, ["completed", "partial", "cancelled", "failed", "unsupported"].contains(phase) {
            let name = UUID().uuidString + ".gaoaction"
            try json(manifest(id: UUID().uuidString, kind: "result", status: phase, reply: requestID), source.appendingPathComponent("Exchange/Outgoing/" + name + "/manifest.json"))
            try put(payload, source.appendingPathComponent("Exchange/Outgoing/" + name + "/payload/input.txt"))
            record["resultPackageName"] = name
        }
        if pending {
            let name = UUID().uuidString + ".gaoaction"
            try json(manifest(id: UUID().uuidString, kind: "result", status: "pending", reply: requestID), source.appendingPathComponent("Exchange/Outgoing/" + name + "/manifest.json"))
            try put(payload, source.appendingPathComponent("Exchange/Outgoing/" + name + "/payload/input.txt"))
        }
        try json(["schemaVersion": 1, "records": [record]], source.appendingPathComponent("Exchange/ProcessedRequests.json"))
        if withOCR {
            let sourceID = UUID().uuidString
            let page: [String: Any] = ["id": UUID().uuidString, "sourceID": sourceID, "pageNumber": 1, "originalSHA256": hash, "status": "completed", "lines": [[String: Any]](),
                "mediaBox": [[0, 0], [2, 2]], "cropBox": [[0, 0], [2, 2]], "rotation": 0, "pixelWidth": 2, "pixelHeight": 2, "renderScale": 1, "elapsedSeconds": 0.02,
                "deskewAppliedDegrees": 0, "preprocessing": [String](), "coordinateSystem": "fixture"]
            let document: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "createdAt": timestamp, "engine": "Apple Vision VNRecognizeTextRequest", "engineRevision": 3, "operatingSystem": "fixture",
                "options": ["languages": ["zh-Hans"], "recognitionLevel": "accurate", "languageCorrection": true, "enhanceContrast": false, "deskew": false, "pdfDPI": 144,
                    "maxPages": 200, "maxPixelsPerPage": 12_000_000, "maxFileBytes": 536_870_912, "maximumConcurrency": 1, "memoryBudgetBytes": 268_435_456],
                "sources": [["id": sourceID, "displayName": "input.txt", "sha256": hash, "byteCount": payload.count, "pageCount": 1, "isPDF": false]], "pages": [page], "wasCancelled": false]
            try json(["schemaVersion": 1, "requestID": requestID, "createdAt": timestamp, "document": document, "sources": [["sourceID": sourceID, "sourceItemID": "input", "sourceSHA256": hash]]], source.appendingPathComponent("Exchange/Derived/" + requestID + "/OCR-recovery.json"))
            try put(Data("recognized fixture text".utf8), source.appendingPathComponent("Exchange/Derived/" + requestID + "/OCR-1.txt"))
        }
        if recording {
            let id = UUID().uuidString
            let partial = ".gao-recording-" + id + ".partial.mov"
            try json(["schemaVersion": 1, "sessionID": id, "createdAt": timestamp, "updatedAt": timestamp, "state": recordingState, "mode": "video", "sourceDescription": "synthetic fixture",
                "partialFileName": partial, "requestedFileName": "requested.mov", "systemAudio": false, "microphone": false,
                "metrics": ["videoFrames": 1, "systemAudioBuffers": 0, "microphoneBuffers": 0, "droppedVideoFrames": 0, "droppedAudioBuffers": 0, "durationSeconds": 0.1, "processCPUSeconds": 0.02],
                "failure": "synthetic", "recoveryNote": "Unverified synthetic media; never played"], source.appendingPathComponent("RecordingRecovery/.gao-recording-" + id + ".recovery.json"))
            try put(Data("Unplayable fixture bytes; preserved without a playability claim".utf8), source.appendingPathComponent("RecordingRecovery/" + partial))
        }
        let config = ScreenshotMigrationConfiguration(sourceRoot: source, targetRoot: target, archiveRoot: base.appendingPathComponent("Archives.noindex"), auxiliaries: [])
        let plan = try ScreenshotMigration(configuration: config).preview()
        try ScreenshotMigrationIO.copy(plan.snapshots.first { $0.id == "Source" }!, to: archive.appendingPathComponent("Source"))
        return .init(base: base, source: source, target: target, archive: archive, plan: plan, requestID: requestID, stagedPath: stagedPath)
    }
    do {
        let f = try fixture(withOCR: true, pending: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let original = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true)
        try put(Data("host data written after committed migration".utf8), f.target.appendingPathComponent("HostNewData.txt"))
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        try expect(try ScreenshotMigrationActivity.validate(root: f.target, plan: f.plan, archive: f.archive) == index, "pre-retirement validation independently binds the exact selected closure to the approved plan")
        try expect(index.blockers.isEmpty, "completed ledger plus terminal result resolves the historical pending package")
        try expect(index.entries.contains { $0.kind == "ocr-recovery" && $0.attachmentPaths.count == 1 }, "OCR keeps the verified original input for recovery")
        try expect(index.entries.contains { $0.kind == "derived-attachment" }, "unreturned generated outputs remain accessible")
        try expect(index.entries.allSatisfy { $0.readOnly && !$0.allowsExecution }, "no imported activity becomes an executable request")
        try expect(index.files.keys.allSatisfy { !$0.contains("Settings.json") && !$0.contains("Backups") }, "projection has no settings or raw backup")
        try expect(try ScreenshotMigrationIO.read(f.target.appendingPathComponent("HostNewData.txt")) == Data("host data written after committed migration".utf8), "incremental import preserves new host data")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true) == original, "source is byte preserving and read only")
        try expect(try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) == index, "same-source explicit import is idempotent")
        let result = index.entries.first { $0.kind == "exchange-result" && $0.status == "completed" }!
        let manifestBytes = try ScreenshotMigrationActivity.readRecord(root: f.target, entryID: result.id)
        let saved = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
        try expect(saved["sourceBundleID"] as? String == oldProvider && saved["nonce"] as? String == Data(repeating: 7, count: 32).base64EncodedString(), "old provider and nonce stay unchanged")
        try expect(try manifestBytes == ScreenshotMigrationIO.read(f.archive.appendingPathComponent("Source/" + result.provenance.originalRelativePath)), "original manifest bytes are preserved")
        let output = f.base.appendingPathComponent("Export/input.txt")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ScreenshotMigrationActivity.exportAttachment(root: f.target, entryID: result.id, relativePath: result.attachmentPaths[0], to: output)
        try expect(try ScreenshotMigrationIO.read(output) == payload, "single-file export remains available without source or archive")
        try rejected("export never overwrites") { try ScreenshotMigrationActivity.exportAttachment(root: f.target, entryID: result.id, relativePath: result.attachmentPaths[0], to: output) }
        let exportedRecord = f.base.appendingPathComponent("Export/original-record.json")
        try ScreenshotMigrationActivity.exportRecord(root: f.target, entryID: result.id, to: exportedRecord)
        try expect(try ScreenshotMigrationIO.read(exportedRecord) == manifestBytes, "record export preserves original provider/nonce/manifest bytes")
        try rejected("record export never overwrites") { try ScreenshotMigrationActivity.exportRecord(root: f.target, entryID: result.id, to: exportedRecord) }
        try rejected("record cannot be exported as executable package") { try ScreenshotMigrationActivity.exportRecord(root: f.target, entryID: result.id, to: f.base.appendingPathComponent("old.gaoaction")) }
        try FileManager.default.removeItem(at: f.archive)
        try FileManager.default.removeItem(at: f.source)
        try expect(try ScreenshotMigrationActivity.validate(root: f.target) == index, "active projection is independently readable after old roots are removed")
    }
    do {
        let f = try fixture(phase: "executing", pending: true, recording: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        try expect(index.blockers.count == 2, "executing request and unresolved pending block retirement; a complete failed recovery pair is current manageable data")
        try expect(index.entries.contains { $0.kind == "recording-recovery" && $0.attachmentPaths.count == 1 && $0.status == "failed" }, "failed recording keeps its journal and media without claiming playability")
        let indexURL = f.target.appendingPathComponent("ImportedActivity/Index.json")
        var changed = try ScreenshotMigrationValidation.object(indexURL)
        changed["blockers"] = [String]()
        try json(changed, indexURL)
        try rejected("editing blockers cannot erase pending work") { _ = try ScreenshotMigrationActivity.blockers(root: f.target) }
    }
    do {
        let f = try fixture(passiveResult: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        try expect(index.blockers.isEmpty, "passive terminal result with old ledger phase received is not a runnable pending request")
        try expect(index.entries.contains { $0.kind == "exchange-state" && $0.status == "received" }, "the original passive ledger phase is not rewritten")
    }
    do {
        let f = try fixture(pending: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let ledger = f.source.appendingPathComponent("Exchange/ProcessedRequests.json")
        var value = try ScreenshotMigrationValidation.object(ledger)
        var rows = value["records"] as! [[String: Any]]
        rows[0].removeValue(forKey: "resultPackageName"); value["records"] = rows
        try json(value, ledger)
        let plan = try ScreenshotMigration(configuration: f.plan.configuration).preview()
        try FileManager.default.removeItem(at: f.archive)
        try ScreenshotMigrationIO.copy(plan.snapshots.first { $0.id == "Source" }!, to: f.archive.appendingPathComponent("Source"))
        let index = try ScreenshotMigrationActivity.prepare(plan: plan, archive: f.archive, target: f.target)
        try expect(index.blockers.count == 1 && index.blockers[0].contains("pending"), "a terminal ledger without its exact result pointer cannot let an arbitrary matching terminal package clear pending work")
    }
    do {
        let f = try fixture(recording: true, recordingState: "recording"); defer { try? FileManager.default.removeItem(at: f.base) }
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        try expect(index.blockers.count == 1 && index.blockers[0].contains("活跃状态"), "a still-active producer blocks retirement even though current journal/media bytes are copied")
    }
    do {
        let f = try fixture(recording: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let recordingRoot = f.source.appendingPathComponent("RecordingRecovery")
        let external = f.base.appendingPathComponent("SelectedExternalOutput")
        try FileManager.default.moveItem(at: recordingRoot, to: external)
        let journal = try FileManager.default.contentsOfDirectory(at: external, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix(".recovery.json") }!
        var config = f.plan.configuration
        config.auxiliaries = [.init(id: "SelectedRecordingJournal", url: journal, required: true)]
        let plan = try ScreenshotMigration(configuration: config).preview()
        try FileManager.default.removeItem(at: f.archive)
        for snapshot in plan.snapshots where snapshot.existed { try ScreenshotMigrationIO.copy(snapshot, to: f.archive.appendingPathComponent(snapshot.id)) }
        let index = try ScreenshotMigrationActivity.prepare(plan: plan, archive: f.archive, target: f.target)
        let entry = index.entries.first { $0.kind == "recording-recovery" }!
        let localJournal = try ScreenshotMigrationActivity.recordingJournalURL(root: f.target, entryID: entry.id)
        let content = try ScreenshotMigrationActivity.readActivity(root: f.target, entryID: entry.id)
        let saved = try JSONSerialization.jsonObject(with: content.recordData) as! [String: Any]
        let localMedia = localJournal.deletingLastPathComponent().appendingPathComponent(saved["partialFileName"] as! String)
        try expect(content.attachments.values.contains(localMedia), "standalone journal and separately archived media are projected into the same recovery directory")
        try expect(index.blockers.isEmpty, "complete failed external recording is safely managed as current recovery data")
        try FileManager.default.removeItem(at: external)
        try FileManager.default.removeItem(at: f.archive)
        try expect(try ScreenshotMigrationIO.read(localJournal) == content.recordData && ScreenshotMigrationIO.exists(localMedia), "recovery pair remains readable without external originals or archive")
    }
    for corruption in ["changedAttachment", "missingInput", "futureIndex", "futureRecovery", "changedManifest", "extraFile"] {
        let f = try fixture(withOCR: true); defer { try? FileManager.default.removeItem(at: f.base) }
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        let activity = f.target.appendingPathComponent("ImportedActivity")
        switch corruption {
        case "changedAttachment": try put(Data("tampered".utf8), activity.appendingPathComponent(index.entries.first { !$0.attachmentPaths.isEmpty }!.attachmentPaths[0]))
        case "missingInput": try FileManager.default.removeItem(at: activity.appendingPathComponent("Records/Source/" + (f.stagedPath as NSString).deletingLastPathComponent + "/0-input.txt"))
        case "futureIndex": var value = try ScreenshotMigrationValidation.object(activity.appendingPathComponent("Index.json")); value["schemaVersion"] = 2; try json(value, activity.appendingPathComponent("Index.json"))
        case "futureRecovery":
            let path = index.entries.first { $0.kind == "ocr-recovery" }!.relativeRecordPath
            var value = try ScreenshotMigrationValidation.object(activity.appendingPathComponent(path)); value["schemaVersion"] = 2; try json(value, activity.appendingPathComponent(path))
        case "changedManifest":
            let path = "Records/Source/" + f.stagedPath
            var value = try ScreenshotMigrationValidation.object(activity.appendingPathComponent(path)); value["targetBundleID"] = "com.gaoseries.GaoCaoZuo"; try json(value, activity.appendingPathComponent(path))
        default: try put(Data("unindexed".utf8), activity.appendingPathComponent("Records/extra.txt"))
        }
        try rejected(corruption + " fails independent validation") { _ = try ScreenshotMigrationActivity.validate(root: f.target) }
    }
    do {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var value = try ScreenshotMigrationValidation.object(f.archive.appendingPathComponent("Source/" + f.stagedPath))
        var items = value["items"] as! [[String: Any]]; items[0]["relativePath"] = "../escape.txt"; value["items"] = items
        try json(value, f.archive.appendingPathComponent("Source/" + f.stagedPath))
        try rejected("archive path traversal or digest change fails before publishing") { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) }
        try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("ImportedActivity")), "rejected input does not publish a partial index")
    }
    do {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        // Rewriting a self-contained catalog cannot erase the original approved activity closure at retirement.
        try FileManager.default.removeItem(at: f.target.appendingPathComponent("ImportedActivity/Records"))
        index.entries = []; index.files = [:]; index.blockers = []
        try put(ScreenshotMigrationIO.encoder.encode(index), f.target.appendingPathComponent("ImportedActivity/Index.json"))
        try rejected("retirement completeness check detects coordinated removal of files and index rows") { _ = try ScreenshotMigrationActivity.validate(root: f.target, plan: f.plan, archive: f.archive) }
    }
}
#endif
