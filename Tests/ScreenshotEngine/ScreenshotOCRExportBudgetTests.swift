// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import CoreGraphics
import ImageIO
import PDFKit

private enum OCRExportBudgetFailure: Error { case assertion(String) }
private func exportBudgetRequire(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw OCRExportBudgetFailure.assertion(message) }
}

/// Synthetic CLI-only regression: no application/window, capture, clipboard or translation session.
func ScreenshotRunOCRExportBudgetTests(in directory: URL) async throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let imageURL = directory.appendingPathComponent("pixel-limit.png")
    try budgetPNG(width: 800, height: 600, to: imageURL)
    var options = ScreenshotOCROptions(); options.languages = ["en-US"]; options.maxPixelsPerPage = 10_000
    let failed = try await ScreenshotOCRService().recognize(urls: [imageURL], options: options)
    try exportBudgetRequire(failed.failedPages.count == 1 && failed.successfulPages == 0 && failed.pages[0].failureReason?.contains("超过像素限制") == true && failed.sources[0].sha256 == (try ScreenshotOCRService.sha256(url: imageURL)), "recognition really rejected pixels and retained source identity")
    let failedSource = failed.sources[0]
    let failedOutput = directory.appendingPathComponent("must-not-bypass.pdf")
    try expectBudgetRejection(document: failed, sourceURL: imageURL, destination: failedOutput)
    let failureJSON = directory.appendingPathComponent("failed-page.json")
    try ScreenshotOCRExporter.export(document: failed, format: .json, to: failureJSON)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let retained = try decoder.decode(ScreenshotOCRDocument.self, from: Data(contentsOf: failureJSON))
    try exportBudgetRequire(retained.failedPages.count == 1 && retained.pages[0].lines.isEmpty && retained.pages[0].failureReason == failed.pages[0].failureReason, "rejected export preserves failed-page JSON semantics")
    try exportBudgetRequire(try ScreenshotOCRService.sha256(url: imageURL) == failedSource.sha256, "rejected export never changes input")

    // This skinny image is cheap to create but exercises the independent 12,000-pixel edge cap.
    let wideURL = directory.appendingPathComponent("edge-limit.png")
    try budgetPNG(width: 12_001, height: 1, to: wideURL)
    var edgeOptions = options; edgeOptions.maxPixelsPerPage = 100_000
    let wide = try await ScreenshotOCRService().recognize(urls: [wideURL], options: edgeOptions)
    try exportBudgetRequire(wide.failedPages.count == 1 && wide.pages[0].failureReason?.contains("超过像素限制") == true && !wide.sources[0].sha256.isEmpty, "recognition really rejected image edge length")
    try expectBudgetRejection(document: wide, sourceURL: wideURL, destination: directory.appendingPathComponent("edge-rejected.pdf"))

    let smallURL = directory.appendingPathComponent("within-budget.png")
    try budgetPNG(width: 64, height: 32, to: smallURL)
    let safe = try budgetDocument(url: smallURL, isPDF: false, options: options, media: CGRect(x: 0, y: 0, width: 64, height: 32))
    let safeOutput = directory.appendingPathComponent("within-budget.pdf")
    let safeValidation = try ScreenshotOCRExporter.exportSearchablePDF(document: safe, sourceID: safe.sources[0].id, sourceURL: smallURL, to: safeOutput)
    try exportBudgetRequire(safeValidation.pageCount == 1 && safeValidation.preservedPageGeometry && PDFDocument(url: safeOutput)?.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 64, height: 32), "normal image export retains original pixel geometry")

    var lowMemory = safe; lowMemory.options.memoryBudgetBytes = 32 * 1024 * 1024; lowMemory.options.maxPixelsPerPage = 3_000_000
    try expectBudgetRejection(document: lowMemory, sourceURL: smallURL, destination: directory.appendingPathComponent("memory-rejected.pdf"))
    var excessivePixels = safe; excessivePixels.options.maxPixelsPerPage = Int.max
    try expectBudgetRejection(document: excessivePixels, sourceURL: smallURL, destination: directory.appendingPathComponent("overflow-rejected.pdf"))
    var excessiveBytes = safe; excessiveBytes.sources[0].byteCount = Int64.max
    try expectBudgetRejection(document: excessiveBytes, sourceURL: smallURL, destination: directory.appendingPathComponent("bytes-rejected.pdf"))
    var invalidPages = safe; invalidPages.options.maxPages = 0
    try expectBudgetRejection(document: invalidPages, sourceURL: smallURL, destination: directory.appendingPathComponent("range-rejected.pdf"))

    // PDF point dimensions are not image pixels: keep the vector/failed-page path and its boxes.
    let pdfURL = directory.appendingPathComponent("large-point-box.pdf")
    let media = CGRect(x: 20, y: 30, width: 13_000, height: 1_000)
    let crop = CGRect(x: 30, y: 50, width: 600, height: 800)
    try budgetPDF(to: pdfURL, media: media, crop: crop)
    let pdfSource = try budgetDocument(url: pdfURL, isPDF: true, options: options, media: media, crop: crop, rotation: 90, status: .failed)
    let pdfOutput = directory.appendingPathComponent("preserved-failed-pdf.pdf")
    let pdfValidation = try ScreenshotOCRExporter.exportSearchablePDF(document: pdfSource, sourceID: pdfSource.sources[0].id, sourceURL: pdfURL, to: pdfOutput)
    guard let page = PDFDocument(url: pdfOutput)?.page(at: 0) else { throw OCRExportBudgetFailure.assertion("PDF output missing") }
    try exportBudgetRequire(pdfValidation.pageCount == 1 && pdfValidation.verifiedTextLines == 0 && page.bounds(for: .mediaBox) == media && page.bounds(for: .cropBox) == crop && page.rotation == 90, "PDF source keeps point boxes/rotation without image edge rejection or fake OCR text")
    try exportBudgetRequire(pdfSource.failedPages.count == 1 && pdfSource.successfulPages == 0 && (try ScreenshotOCRService.sha256(url: pdfURL)) == pdfSource.sources[0].sha256, "PDF failed status and original source remain unchanged")
    try exportBudgetRequire(!(try files.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".gaocaozuo-screenshot-ocr-") }, "rejections leave no export intermediates")
    print("OCR export budget PASS: real pixel/edge rejection cannot bypass image decode limits; memory/invalid/overflow budgets reject safely; failed-page JSON/source retained; safe image and PDF point-box/rotation paths preserved. No GUI, capture or downloads.")
}

private func expectBudgetRejection(document: ScreenshotOCRDocument, sourceURL: URL, destination: URL) throws {
    do {
        _ = try ScreenshotOCRExporter.exportSearchablePDF(document: document, sourceID: document.sources[0].id, sourceURL: sourceURL, to: destination)
        throw OCRExportBudgetFailure.assertion("unsafe export accepted: " + destination.lastPathComponent)
    } catch ScreenshotOCRError.resourceLimit { }
    try exportBudgetRequire(!FileManager.default.fileExists(atPath: destination.path), "rejected export was published")
}

private func budgetDocument(url: URL, isPDF: Bool, options: ScreenshotOCROptions, media: CGRect, crop: CGRect? = nil, rotation: Int = 0, status: ScreenshotOCRPageStatus = .completed) throws -> ScreenshotOCRDocument {
    let source = ScreenshotOCRSource(id: UUID(), displayName: url.lastPathComponent, sha256: try ScreenshotOCRService.sha256(url: url), byteCount: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), pageCount: 1, isPDF: isPDF)
    let page = ScreenshotOCRPage(sourceID: source.id, pageNumber: 1, originalSHA256: source.sha256, status: status, failureReason: status == .failed ? "synthetic failed page" : nil, lines: [], mediaBox: media, cropBox: crop ?? media, rotation: rotation, pixelWidth: 64, pixelHeight: 32, renderScale: 1, elapsedSeconds: 0)
    return ScreenshotOCRDocument(engineRevision: 3, options: options, sources: [source], pages: [page])
}

private func budgetPNG(width: Int, height: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OCRExportBudgetFailure.assertion("synthetic PNG buffer") }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw OCRExportBudgetFailure.assertion("synthetic PNG writer") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw OCRExportBudgetFailure.assertion("synthetic PNG finalization") }
}

private func budgetPDF(to url: URL, media: CGRect, crop: CGRect) throws {
    var box = media; var cropBox = crop
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw OCRExportBudgetFailure.assertion("synthetic PDF writer") }
    let cropBytes = Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size)
    context.beginPDFPage([kCGPDFContextCropBox as String: cropBytes] as CFDictionary)
    context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(crop)
    context.endPDFPage(); context.closePDF()
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { throw OCRExportBudgetFailure.assertion("synthetic PDF reader") }
    page.rotation = 90
    guard document.write(to: url) else { throw OCRExportBudgetFailure.assertion("synthetic PDF rotation") }
}
