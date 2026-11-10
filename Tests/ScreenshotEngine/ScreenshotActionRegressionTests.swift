// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import AppKit
import PDFKit

private enum ActionRegressionFailure: Error { case assertion(String), lateProviderError }
private func actionRegressionRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ActionRegressionFailure.assertion(message) }
}

/// Targeted regressions only: no App/NSWindow/NSWorkspace launch, capture, audio, permissions or language download.
@MainActor
func ScreenshotRunActionRegressionTests(in directory: URL) async throws {
    _ = try ScreenshotGaoPrivateIO.directory(directory, create: true, requirePrivate: true)

    let requestA = UUID().uuidString, requestB = UUID().uuidString
    let operationA = UUID(), operationB = UUID()
    let old = ScreenshotTranslationOperationIdentity(operationID: operationA, requestID: requestA)
    let snapshot = ScreenshotTranslationAttempt(identity: old, text: "same input", sourceLanguage: "en", targetLanguage: "zh-Hans", packageDownloadRequested: false)
    try actionRegressionRequire(snapshot.identity.matches(operationID: operationA, requestID: requestA), "active translation identity")
    try actionRegressionRequire(!snapshot.identity.matches(operationID: operationB, requestID: requestB), "old completion/cancel cannot bind a new request with identical input")
    try actionRegressionRequire(!snapshot.identity.matches(operationID: operationA, requestID: requestB), "request ID must match independently of operation ID")
    let local = ScreenshotTranslationOperationIdentity(operationID: operationA, requestID: nil)
    try actionRegressionRequire(!local.matches(operationID: operationA, requestID: requestB), "local callback cannot complete an external request")

    var lateValue: CheckedContinuation<Int, Never>?
    let valueOperation = ScreenshotActionTaskHandle<Int>(requestID: requestA) {
        await withCheckedContinuation { lateValue = $0 }
    }
    while lateValue == nil { await Task.yield() }
    valueOperation.cancel(); lateValue?.resume(returning: 7)
    do { _ = try await valueOperation.value(); throw ActionRegressionFailure.assertion("cancelled provider published a late value") }
    catch is CancellationError { }
    var lateError: CheckedContinuation<Int, Error>?
    let errorOperation = ScreenshotActionTaskHandle<Int>(requestID: requestB) {
        try await withCheckedThrowingContinuation { lateError = $0 }
    }
    while lateError == nil { await Task.yield() }
    errorOperation.cancel(); lateError?.resume(throwing: ActionRegressionFailure.lateProviderError)
    do { _ = try await errorOperation.value(); throw ActionRegressionFailure.assertion("late provider error overwrote cancellation") }
    catch is CancellationError { }

    let input = directory.appendingPathComponent("hybrid-native-header-scanned-body.pdf")
    try makeHybridActionPDF(at: input)
    let beforeSHA = try ScreenshotOCRService.sha256(url: input)
    guard let original = PDFDocument(url: input), let firstOriginal = original.page(at: 0) else { throw ActionRegressionFailure.assertion("hybrid input unreadable") }
    try actionRegressionRequire(firstOriginal.string?.contains("NATIVE HEADER") == true && firstOriginal.string?.contains("SCANNED BODY") != true, "sample has a native header and genuinely image-only body")
    var options = ScreenshotOCROptions(); options.languages = ["en-US"]
    let document = try await ScreenshotOCRService().recognize(urls: [input], options: options)
    try actionRegressionRequire(document.successfulPages == 2 && document.text.contains("SCANNED BODY 2026"), "real OCR recognizes hybrid image body: " + document.pages.map { "\($0.status.rawValue): \($0.failureReason ?? $0.text)" }.joined(separator: " | "))
    let searchable = directory.appendingPathComponent("hybrid-searchable.pdf")
    let validation = try ScreenshotOCRExporter.exportSearchablePDF(document: document, sourceID: document.sources[0].id, sourceURL: input, to: searchable)
    try actionRegressionRequire(validation.pageCount == 2 && validation.rasterizedPages == [1, 2] && validation.verifiedTextLines >= 4, "hybrid pages rebuild one complete positioned text layer")
    guard let completed = PDFDocument(url: searchable) else { throw ActionRegressionFailure.assertion("hybrid output unreadable") }
    try actionRegressionRequire(completed.findString("SCANNED BODY 2026", withOptions: []).count == 2, "scanned body searchable on both pages")
    try actionRegressionRequire(!completed.findString("NATIVE HEADER", withOptions: []).isEmpty, "native header remains searchable")
    for index in 0..<2 {
        try actionRegressionRequire(completed.page(at: index)?.bounds(for: .mediaBox) == original.page(at: index)?.bounds(for: .mediaBox), "hybrid MediaBox")
        try actionRegressionRequire(completed.page(at: index)?.bounds(for: .cropBox) == original.page(at: index)?.bounds(for: .cropBox), "hybrid CropBox")
        try actionRegressionRequire(completed.page(at: index)?.rotation == original.page(at: index)?.rotation, "hybrid rotation")
    }
    try actionRegressionRequire(try ScreenshotOCRService.sha256(url: input) == beforeSHA, "hybrid source never modified")

    let token = ScreenshotOCRCancellationToken()
    let partial = try await ScreenshotOCRService().recognize(urls: [input], options: options, cancellation: token) { progress in
        if progress.completedPages == 1 { token.cancel() }
    }
    try actionRegressionRequire(partial.wasCancelled && partial.successfulPages == 1 && partial.pages.contains { $0.status == .cancelled }, "partial completed OCR retained before PDF export")
    let source = partial.sources[0]
    let recovery = directory.appendingPathComponent("OCR-recovery.json")
    let mappings = [ScreenshotOCRRecoverySource(sourceID: source.id, sourceItemID: "synthetic-input", sourceSHA256: beforeSHA)]
    _ = try ScreenshotOCRRecoveryStore.save(document: partial, requestID: requestA, sources: mappings, to: recovery)
    let cancelledOutput = directory.appendingPathComponent("cancelled-pdf-only.pdf")
    do { _ = try ScreenshotOCRExporter.exportSearchablePDF(document: partial, sourceID: source.id, sourceURL: input, to: cancelledOutput, cancellation: token); throw ActionRegressionFailure.assertion("cancelled PDF committed") }
    catch is CancellationError { }
    let restored = try ScreenshotOCRRecoveryStore.read(from: recovery)
    try actionRegressionRequire(restored.document.text == partial.text && restored.document.pages.count == partial.pages.count && restored.sources[0].sourceSHA256 == beforeSHA, "private recovery preserves text, all page states and input identity")
    try actionRegressionRequire(!FileManager.default.fileExists(atPath: cancelledOutput.path), "cancelled PDF-only request has no fake PDF output")
    let recoveryText = try String(contentsOf: recovery, encoding: .utf8)
    try actionRegressionRequire(!recoveryText.contains(directory.path) && !recoveryText.contains("file://"), "recovery has no original source URL")
    let permissions = (try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber)?.intValue
    try actionRegressionRequire(permissions == 0o600, "recovery is private")
    do { _ = try ScreenshotOCRRecoveryStore.save(document: partial, requestID: requestA, sources: mappings, to: recovery); throw ActionRegressionFailure.assertion("existing recovery overwritten") }
    catch ScreenshotOCRError.outputExists { }
    var future = try JSONSerialization.jsonObject(with: Data(contentsOf: recovery)) as! [String: Any]
    future["schemaVersion"] = 2
    let futureURL = directory.appendingPathComponent("future-recovery.json")
    try JSONSerialization.data(withJSONObject: future).write(to: futureURL)
    do { _ = try ScreenshotOCRRecoveryStore.read(from: futureURL); throw ActionRegressionFailure.assertion("future recovery silently accepted") }
    catch ScreenshotOCRError.invalidDocument { }

    let exchange = directory.appendingPathComponent("Exchange")
    let requestURL = try ScreenshotGaoActionWriter.writeRequest(action: "ocr.files", items: [.init(url: input, uti: "com.adobe.pdf", id: "synthetic-input")], parameters: ["outputs": .array([.string("searchablePDF")])], sourceBundleID: "com.gaoseries.GaoCaoZuo", targetBundleID: ScreenshotGaoActionContract.bundleID, exchangeRoot: exchange)
    let received = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange)
    let resultURL = try ScreenshotGaoActionWriter.writeResult(inReplyTo: received.manifest, status: "partial", errorCode: "userCancelled", provenance: ["localRecovery": .object(["available": .bool(true), "filename": .string("OCR-recovery.json")]), "sources": .array([.object(["sourceItemID": .string("synthetic-input"), "sourceSHA256": .string(beforeSHA)])])], exchangeRoot: exchange)
    let checked = try ScreenshotGaoActionTransport.receive(packageURL: resultURL, exchangeRoot: exchange, expectedTargetBundleID: "com.gaoseries.GaoCaoZuo")
    try actionRegressionRequire(checked.manifest.status == "partial" && checked.manifest.items.isEmpty, "unrequested recovery JSON is never an outgoing attachment")
    print("Action regressions PASS: fixed translation identities; cancellation beats late provider value/error; real hybrid-PDF OCR/search/geometry; PDF-only cancellation private recovery; no-overwrite/future schema; no GUI, capture, audio or translation downloads")
}

@MainActor
private func makeHybridActionPDF(at url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw ActionRegressionFailure.assertion("hybrid bitmap allocation") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 500).fill()
    "SCANNED BODY 2026".draw(at: CGPoint(x: 70, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    guard let image = rep.cgImage else { throw ActionRegressionFailure.assertion("hybrid bitmap render") }
    var media = CGRect(x: 10, y: 20, width: 800, height: 900)
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw ActionRegressionFailure.assertion("hybrid PDF allocation") }
    for index in 0..<2 {
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (index == 0 ? "NATIVE HEADER" : "NATIVE SECOND").draw(at: CGPoint(x: 70, y: 760), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.draw(image, in: CGRect(x: 70, y: 150, width: 660, height: 275)); context.endPDFPage()
    }
    context.closePDF()
    guard let pdf = PDFDocument(url: url) else { throw ActionRegressionFailure.assertion("hybrid source read") }
    for index in 0..<2 { pdf.page(at: index)?.setBounds(media.insetBy(dx: 10, dy: 20), for: .cropBox) }
    guard pdf.write(to: url) else { throw ActionRegressionFailure.assertion("hybrid crop preservation") }
}
