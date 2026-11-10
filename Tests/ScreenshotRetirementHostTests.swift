import Foundation
import CoreGraphics
import ImageIO

/// Generated pixels and saved OCR work only. Never starts recognition, capture,
/// translation, an Exchange request, a device, or a window.
@MainActor
func runScreenshotImportedOCRRestoreTests() async throws {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { "Imported OCR restore: " + message }
    }
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
        checks += 1
    }
    func rejected(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { checks += 1; return }
        throw Failure(message: "accepted invalid recovery: " + message)
    }
    func encodedDocument(_ value: ScreenshotOCRDocument?) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("GaoCaoZuo-ImportedOCRRestore-" + UUID().uuidString + ".noindex", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let requestID = UUID().uuidString, sourceID = UUID()
    let imported = root.appendingPathComponent("ImportedActivity/Records/Source/Exchange", isDirectory: true)
    let staged = imported.appendingPathComponent("Staging/" + UUID().uuidString, isDirectory: true)
    let derived = imported.appendingPathComponent("Derived/" + requestID, isDirectory: true)
    try fm.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.createDirectory(at: derived, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let input = staged.appendingPathComponent("0-input.png")
    guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure(message: "cannot allocate generated pixels")
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil) else {
        throw Failure(message: "cannot create generated PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(message: "cannot finish generated PNG") }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
    let inputBytes = try Data(contentsOf: input)
    let inputSHA = try ScreenshotOCRService.sha256(url: input)
    let source = ScreenshotOCRSource(id: sourceID, displayName: "input.png", sha256: inputSHA,
                                     byteCount: Int64(inputBytes.count), pageCount: 1, isPDF: false)
    let line = ScreenshotOCRLine(text: "旧稿已校正", originalText: "旧稿原识别", userEdited: true,
        boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.3),
        pageBoundingBox: CGRect(x: 0.8, y: 1.6, width: 4.8, height: 2.4),
        pageQuadrilateral: [CGPoint(x: 0.8, y: 1.6), CGPoint(x: 5.6, y: 1.6), CGPoint(x: 5.6, y: 4), CGPoint(x: 0.8, y: 4)],
        confidence: 0.82, languages: ["zh-Hans"], readingOrder: 0)
    let page = ScreenshotOCRPage(sourceID: sourceID, pageNumber: 1, originalSHA256: inputSHA,
        status: .completed, failureReason: nil, lines: [line], mediaBox: CGRect(x: 0, y: 0, width: 8, height: 8),
        cropBox: CGRect(x: 0, y: 0, width: 8, height: 8), rotation: 0, pixelWidth: 8, pixelHeight: 8,
        renderScale: 1, elapsedSeconds: 0.02)
    var options = ScreenshotOCROptions(); options.maxFileBytes = 1_048_576
    var document = ScreenshotOCRDocument(engineRevision: 3, options: options, sources: [source], pages: [page])
    document.createdAt = Date(timeIntervalSince1970: 1_762_041_600)
    let mappings = [ScreenshotOCRRecoverySource(sourceID: sourceID, sourceItemID: "input", sourceSHA256: inputSHA)]
    let recoveryURL = derived.appendingPathComponent("OCR-recovery.json")
    _ = try ScreenshotOCRRecoveryStore.save(document: document, requestID: requestID, sources: mappings, to: recoveryURL)
    let recoveryBytes = try Data(contentsOf: recoveryURL)
    let decoded = try ScreenshotOCRRecoveryStore.decode(recoveryBytes)

    // Keep the old request as inert bytes beside its input. Restoring work must
    // not rewrite its provider, nonce, TTL, payload declaration or request ID.
    let manifest = ScreenshotGaoActionManifest(kind: "request", requestID: requestID,
        sourceBundleID: "com.academic-achievement.manager", targetBundleID: "com.gaoseries.GaoJieTu", action: "ocr.files",
        createdAt: "2026-11-02T00:00:00Z", expiresAt: "2026-11-02T00:02:00Z",
        nonce: Data(repeating: 7, count: 32).base64EncodedString(),
        items: [.init(id: "input", relativePath: "input.png", uti: "public.png", byteCount: Int64(inputBytes.count), sha256: inputSHA)],
        references: [], parameters: ["outputs": .array([.string("text")])])
    let manifestEncoder = JSONEncoder(); manifestEncoder.outputFormatting = [.sortedKeys]
    let manifestBytes = try manifestEncoder.encode(manifest)
    let manifestURL = staged.appendingPathComponent("manifest.json")
    try manifestBytes.write(to: manifestURL, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    let originalImportedFiles = Set(try fm.subpathsOfDirectory(atPath: imported.path))
    func originalsUnchanged() throws {
        try check(try Data(contentsOf: recoveryURL) == recoveryBytes, "original recovery JSON changed")
        try check(try Data(contentsOf: input) == inputBytes, "original input changed")
        try check(try Data(contentsOf: manifestURL) == manifestBytes, "old request manifest changed")
        try check(try Set(fm.subpathsOfDirectory(atPath: imported.path)) == originalImportedFiles,
                  "restore created or removed a historical Exchange artifact")
    }

    let controller = ScreenshotOCRController()
    try await controller.restore(decoded, sourceURLs: [sourceID: input])
    try check(try encodedDocument(controller.document) == encodedDocument(decoded.document), "saved document not restored verbatim")
    try check(controller.sourceURL(for: sourceID) == input, "source mapping lost")
    try check(!controller.isRunning && controller.progress == nil && controller.errorMessage == nil,
              "restore started work instead of loading the saved draft")
    try check(controller.document?.pages[0].lines[0].userEdited == true &&
              controller.document?.pages[0].lines[0].originalText == "旧稿原识别", "existing correction metadata lost")
    try originalsUnchanged()

    try controller.correctLine(id: line.id, text: "宿主继续校正")
    guard let corrected = controller.document else { throw Failure(message: "corrected document disappeared") }
    let correctedLine = corrected.pages[0].lines[0]
    try check(correctedLine.text == "宿主继续校正" && correctedLine.originalText == line.originalText && correctedLine.userEdited,
              "host correction did not retain the original recognized text")
    try check(correctedLine.confidence == line.confidence && correctedLine.pageQuadrilateral == line.pageQuadrilateral &&
              correctedLine.boundingBox == line.boundingBox && corrected.sources[0].sha256 == inputSHA,
              "correction changed original evidence or geometry")
    let currentBytes = try encodedDocument(controller.document)
    func currentUnchanged() throws {
        try check(try encodedDocument(controller.document) == currentBytes, "rejected restore replaced the current corrected document")
        try check(controller.sourceURL(for: sourceID) == input && !controller.isRunning && controller.progress == nil,
                  "rejected restore replaced source mapping or started recognition")
        try originalsUnchanged()
    }

    let savedURL = root.appendingPathComponent("CurrentOCRDraft.json")
    _ = try ScreenshotOCRRecoveryStore.save(document: corrected, requestID: decoded.requestID, sources: decoded.sources, to: savedURL)
    let saved = try ScreenshotOCRRecoveryStore.decode(Data(contentsOf: savedURL))
    try check(try encodedDocument(saved.document) == encodedDocument(corrected), "explicitly saved corrected draft cannot be read back")
    try check(saved.requestID == decoded.requestID && saved.sources[0].sourceSHA256 == inputSHA,
              "saving the current draft changed its original source association")
    try currentUnchanged()

    try await rejected("missing source mapping") { try await controller.restore(decoded, sourceURLs: [:]) }
    try currentUnchanged()
    let missing = root.appendingPathComponent("missing-input.png")
    try await rejected("missing source file") { try await controller.restore(decoded, sourceURLs: [sourceID: missing]) }
    try currentUnchanged()
    try check(!fm.fileExists(atPath: missing.path), "missing input was recreated")

    let tampered = root.appendingPathComponent("tampered-input.png")
    var tamperedBytes = inputBytes; tamperedBytes[tamperedBytes.startIndex] ^= 1
    try tamperedBytes.write(to: tampered, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tampered.path)
    try await rejected("input SHA mismatch") { try await controller.restore(decoded, sourceURLs: [sourceID: tampered]) }
    try currentUnchanged()
    try check(try Data(contentsOf: tampered) == tamperedBytes, "rejected altered input was overwritten or repaired")

    let recoveryEncoder = JSONEncoder(); recoveryEncoder.dateEncodingStrategy = .iso8601; recoveryEncoder.outputFormatting = [.sortedKeys]
    for futureDocument in [false, true] {
        var futureDraft = decoded.document
        if futureDocument { futureDraft.schemaVersion = 2 }
        var future = ScreenshotOCRRecoverySnapshot(requestID: decoded.requestID, createdAt: decoded.createdAt,
                                                    document: futureDraft, sources: decoded.sources)
        if !futureDocument { future.schemaVersion = 2 }
        let bytes = try recoveryEncoder.encode(future)
        let futureURL = root.appendingPathComponent(futureDocument ? "future-document.json" : "future-snapshot.json")
        try bytes.write(to: futureURL, options: .withoutOverwriting)
        try await rejected("future recovery schema") {
            let value = try ScreenshotOCRRecoveryStore.decode(Data(contentsOf: futureURL))
            try await controller.restore(value, sourceURLs: [sourceID: input])
        }
        try currentUnchanged()
        try check(try Data(contentsOf: futureURL) == bytes, "future recovery JSON changed after rejection")
    }

    // Exercise the actual migration -> read-only activity -> host loader path,
    // independently of the controller-only recovery fixtures above.
    func migratedRecovery(emptyOriginalDescriptor: Bool) async throws {
        let fixture = root.appendingPathComponent(emptyOriginalDescriptor ? "FailedSourceDescriptor.noindex" : "CompletedSource.noindex", isDirectory: true)
        let sourceRoot = fixture.appendingPathComponent("SourceRoot", isDirectory: true)
        let targetRoot = fixture.appendingPathComponent("Host/Screenshot", isDirectory: true)
        let archiveRoot = fixture.appendingPathComponent("Archives.noindex", isDirectory: true)
        func put(_ data: Data, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(ScreenshotAppSettings()), sourceRoot.appendingPathComponent("Settings.json"))
        let id = UUID().uuidString, stageID = UUID().uuidString
        let relativeStage = "Exchange/Staging/" + stageID + "/"
        let originalInput = sourceRoot.appendingPathComponent(relativeStage + "0-input.png")
        try put(inputBytes, originalInput)
        let originalManifest = ScreenshotGaoActionManifest(kind: "request", requestID: id,
            sourceBundleID: "com.academic-achievement.manager", targetBundleID: "com.gaoseries.GaoJieTu", action: "ocr.files",
            createdAt: manifest.createdAt, expiresAt: manifest.expiresAt, nonce: manifest.nonce,
            items: manifest.items, references: [], parameters: manifest.parameters)
        let originalManifestBytes = try encoder.encode(originalManifest)
        let originalManifestURL = sourceRoot.appendingPathComponent(relativeStage + "manifest.json")
        try put(originalManifestBytes, originalManifestURL)

        var originalDraft = document
        if emptyOriginalDescriptor {
            originalDraft.sources[0].sha256 = ""
            originalDraft.sources[0].byteCount = 0
            originalDraft.sources[0].pageCount = 0
            originalDraft.pages[0].originalSHA256 = ""
            originalDraft.pages[0].status = .failed
            originalDraft.pages[0].failureReason = "旧输入检查失败，保留原始恢复稿"
            originalDraft.pages[0].lines = []
        }
        let relativeRecovery = "Exchange/Derived/" + id + "/OCR-recovery.json"
        let originalRecoveryURL = sourceRoot.appendingPathComponent(relativeRecovery)
        try fm.createDirectory(at: originalRecoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try ScreenshotOCRRecoveryStore.save(document: originalDraft, requestID: id, sources: mappings, to: originalRecoveryURL)
        let originalRecoveryBytes = try Data(contentsOf: originalRecoveryURL)

        let phase: ScreenshotGaoRequestPhase = emptyOriginalDescriptor ? .failed : .completed
        let resultName = UUID().uuidString + ".gaoaction"
        let textBytes = Data("旧稿已校正".utf8)
        let resultItems: [ScreenshotGaoActionItem] = emptyOriginalDescriptor ? [] : [
            .init(id: "ocr-text", relativePath: "ocr.txt", uti: "public.utf8-plain-text",
                  byteCount: Int64(textBytes.count), sha256: ScreenshotMigrationIO.sha(textBytes))
        ]
        let result = ScreenshotGaoActionManifest(kind: "result", requestID: UUID().uuidString,
            sourceBundleID: "com.gaoseries.GaoJieTu", targetBundleID: originalManifest.sourceBundleID, action: "ocr.files",
            createdAt: manifest.createdAt, expiresAt: manifest.expiresAt, nonce: manifest.nonce,
            items: resultItems, references: [], parameters: [:], inReplyTo: id, status: phase.rawValue,
            provenance: ["networkUsed": .bool(false)])
        let relativeResult = "Exchange/Outgoing/" + resultName + "/"
        try put(encoder.encode(result), sourceRoot.appendingPathComponent(relativeResult + "manifest.json"))
        if !emptyOriginalDescriptor { try put(textBytes, sourceRoot.appendingPathComponent(relativeResult + "payload/ocr.txt")) }
        let record = ScreenshotGaoProcessedRequest(requestID: id, manifestSHA256: ScreenshotMigrationIO.sha(originalManifestBytes),
            action: "ocr.files", sourceBundleID: originalManifest.sourceBundleID, kind: "request",
            receivedAt: manifest.createdAt, updatedAt: manifest.createdAt, phase: phase, resultPackageName: resultName)
        struct Ledger: Encodable { var schemaVersion = 1; var records: [ScreenshotGaoProcessedRequest] }
        try put(encoder.encode(Ledger(records: [record])), sourceRoot.appendingPathComponent("Exchange/ProcessedRequests.json"))
        let originalSource = try ScreenshotMigrationIO.snapshot(id: "Source", url: sourceRoot, required: true)
        let migration = ScreenshotMigration(configuration: .init(sourceRoot: sourceRoot, targetRoot: targetRoot, archiveRoot: archiveRoot, auxiliaries: []))
        let plan = try migration.preview()
        try check(plan.conflicts.isEmpty, "isolated OCR migration unexpectedly conflicts")
        let migrationResult = try migration.apply(plan, approvedDigest: plan.approvalDigest)
        let index = try ScreenshotMigrationActivity.validate(root: targetRoot)
        try check(index.blockers.isEmpty, "complete historical OCR closure was classified as unresolved")
        guard let entry = index.entries.first(where: { $0.kind == "ocr-recovery" }) else { throw Failure(message: "migration did not publish an OCR recovery entry") }
        let beforeLoad = try ScreenshotMigrationIO.snapshot(id: "Target", url: targetRoot, required: true)
        let work = try IntegratedScreenshotRecovery.readOCR(root: targetRoot, entryID: entry.id)
        guard let currentInput = work.sourceURLs[sourceID] else { throw Failure(message: "host loader did not reconnect the migrated original") }
        try check(currentInput.path.hasPrefix(targetRoot.appendingPathComponent("ImportedActivity").path + "/") && currentInput != originalInput,
                  "host loader retained an old source URL instead of the current migrated input")
        try check(try Data(contentsOf: currentInput) == inputBytes, "host loader selected different source bytes")
        var expectedDraft = originalDraft
        if emptyOriginalDescriptor {
            expectedDraft.sources[0].sha256 = inputSHA
            expectedDraft.sources[0].byteCount = Int64(inputBytes.count)
            try check(work.snapshot.document.sources[0].sha256 == inputSHA &&
                      work.snapshot.document.sources[0].byteCount == Int64(inputBytes.count),
                      "failed legacy descriptor was not completed from the verified manifest/input mapping")
            let unchanged = try ScreenshotOCRRecoveryStore.decode(originalRecoveryBytes)
            try check(unchanged.document.sources[0].sha256.isEmpty && unchanged.document.sources[0].byteCount == 0,
                      "fixture no longer exercises a legacy empty source descriptor")
        }
        try check(try encodedDocument(work.snapshot.document) == encodedDocument(expectedDraft),
                  "host loader changed draft content beyond completing the empty working descriptor")
        let restored = ScreenshotOCRController()
        try await restored.restore(work.snapshot, sourceURLs: work.sourceURLs)
        try check(restored.sourceURL(for: sourceID) == currentInput && !restored.isRunning && restored.progress == nil,
                  "migrated recovery did not bind current input or started recognition")
        try check(try encodedDocument(restored.document) == encodedDocument(expectedDraft), "migrated draft did not reach the OCR controller intact")
        if emptyOriginalDescriptor {
            try check(restored.document?.pages[0].status == .failed && restored.document?.pages[0].lines.isEmpty == true,
                      "loading a failed draft fabricated recognized text")
        } else {
            try check(restored.document?.pages[0].lines[0].text == "旧稿已校正" &&
                      restored.document?.pages[0].lines[0].originalText == "旧稿原识别" &&
                      restored.document?.pages[0].lines[0].userEdited == true, "migrated corrected text was lost")
        }
        try check(try ScreenshotMigrationIO.snapshot(id: "Target", url: targetRoot, required: true) == beforeLoad,
                  "read/restore mutated imported records or created active work")
        try check(!fm.fileExists(atPath: targetRoot.appendingPathComponent("Exchange").path), "migration/restore activated the old Exchange")
        try check(try ScreenshotMigrationIO.snapshot(id: "Source", url: sourceRoot, required: true) == originalSource,
                  "migration/restore changed the original source tree")
        try check(try Data(contentsOf: originalManifestURL) == originalManifestBytes &&
                  Data(contentsOf: originalRecoveryURL) == originalRecoveryBytes, "original request or recovery bytes were rewritten")
        try check(try ScreenshotMigrationActivity.readRecord(root: targetRoot, entryID: entry.id) == originalRecoveryBytes,
                  "migrated recovery JSON was replaced by the completed working descriptor")
        let archivedRecovery = URL(fileURLWithPath: migrationResult.archivePath).appendingPathComponent("Source/" + relativeRecovery)
        try check(try Data(contentsOf: archivedRecovery) == originalRecoveryBytes, "archived original recovery was modified")
    }
    try await migratedRecovery(emptyOriginalDescriptor: false)
    try await migratedRecovery(emptyOriginalDescriptor: true)
    print("Imported OCR restore PASS: \(checks) checks; direct and real migration/activity/loader recovery retain current input and corrected drafts, empty failed descriptors completed only in new work, explicit draft save, invalid inputs preserve current work and original bytes. No recognition, replay, media devices or GUI.")
}
