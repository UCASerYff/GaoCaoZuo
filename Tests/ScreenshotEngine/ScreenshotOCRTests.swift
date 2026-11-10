// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import AppKit
import PDFKit
import Translation

private enum OCRTestFailure: Error { case assertion(String) }
private func ocrRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw OCRTestFailure.assertion(message) } }

/// Entirely synthetic inputs; no clipboard, screen capture, permissions or visible windows.
func ScreenshotRunOCRTests() async throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Screenshot-OCR-Tests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: directory) }
    let imageURL = directory.appendingPathComponent("synthetic-mixed.png")
    let pdfURL = directory.appendingPathComponent("synthetic-columns-rotation.pdf")
    let badURL = directory.appendingPathComponent("invalid-image.png")
    let skewedURL = directory.appendingPathComponent("synthetic-skewed.png")
    let image = try await MainActor.run { try ocrSyntheticImage() }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw OCRTestFailure.assertion("PNG") }
    try png.write(to: imageURL)
    try Data("this is intentionally not an image".utf8).write(to: badURL)
    try ocrSyntheticPDF(image: image, destination: pdfURL)
    let skewed = try ocrSkewedImage(image)
    guard let skewPNG = NSBitmapImageRep(cgImage: skewed).representation(using: .png, properties: [:]) else { throw OCRTestFailure.assertion("skew PNG") }
    try skewPNG.write(to: skewedURL)

    let accurate = try ScreenshotOCRService.supportedLanguages()
    let fast = try ScreenshotOCRService.supportedLanguages(level: .fast)
    try ocrRequire(accurate.contains("en-US") && accurate.contains("zh-Hans"), "Vision accurate supported languages")
    var options = ScreenshotOCROptions(); options.languages = ["zh-Hans", "en-US"]
    let began = Date()
    let doc = try await ScreenshotOCRService().recognize(urls: [imageURL, pdfURL, badURL], options: options)
    try ocrRequire(doc.successfulPages == 3 && doc.failedPages.count == 1 && doc.isPartial, "partial page preservation \(doc.pages.map { ($0.status.rawValue, $0.failureReason ?? "") })")
    try ocrRequire(doc.text.contains("Hello OCR 2026"), "English recognition")
    try ocrRequire(doc.text.contains("中文测试"), "Chinese recognition")
    try ocrRequire(doc.pages.first?.originalSHA256 == (try ScreenshotOCRService.sha256(url: imageURL)), "source digest")
    for page in doc.pages where page.status == .completed {
        try ocrRequire(!page.lines.isEmpty, "each synthetic page has text")
        try ocrRequire(page.lines.allSatisfy { (0...1).contains($0.confidence) && page.mediaBox.intersects($0.pageBoundingBox) }, "line positions in original coordinates")
        let text = page.text
        if let a = text.range(of: "LEFT FIRST"), let b = text.range(of: "LEFT SECOND"), let c = text.range(of: "RIGHT FIRST") { try ocrRequire(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound, "column reading order: \(text); \(page.lines.map { ($0.text, $0.boundingBox) })") }
    }
    let pdfSource = doc.sources[1]
    let searchable = directory.appendingPathComponent("searchable.pdf")
    let validation = try ScreenshotOCRExporter.exportSearchablePDF(document: doc, sourceID: pdfSource.id, sourceURL: pdfURL, to: searchable)
    try ocrRequire(validation.pageCount == 2 && validation.verifiedTextLines > 3 && validation.preservedPageGeometry, "searchable PDF validation")
    let exportCancellation = ScreenshotOCRCancellationToken()
    let cancelledPDF = directory.appendingPathComponent("cancelled-searchable.pdf")
    do {
        _ = try ScreenshotOCRExporter.exportSearchablePDF(document: doc, sourceID: pdfSource.id, sourceURL: pdfURL, to: cancelledPDF, cancellation: exportCancellation) { progress in
            if progress.phase == .writing && progress.completedPages == 1 { exportCancellation.cancel() }
        }
        throw OCRTestFailure.assertion("PDF export cancellation ignored")
    } catch is CancellationError { }
    try ocrRequire(!fm.fileExists(atPath: cancelledPDF.path), "cancelled PDF not published")
    try ocrRequire(!(try fm.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix(".gaocaozuo-screenshot-ocr-") }, "cancelled PDF intermediate files removed")
    let imagePDF = directory.appendingPathComponent("image-searchable.pdf")
    let imageValidation = try ScreenshotOCRExporter.exportSearchablePDF(document: doc, sourceID: doc.sources[0].id, sourceURL: imageURL, to: imagePDF)
    try ocrRequire(imageValidation.verifiedTextLines > 3, "image PDF search/select")
    let croppedPDF = directory.appendingPathComponent("visible-crop-only.pdf")
    try ocrCropOnlyPDF(image: image, destination: croppedPDF)
    let croppedDocument = try await ScreenshotOCRService().recognize(urls: [croppedPDF], options: options)
    try ocrRequire(croppedDocument.successfulPages == 1 && croppedDocument.text.contains("LEFT FIRST") && !croppedDocument.text.contains("Hello"), "CropBox defines visible OCR scope: \(croppedDocument.text) / \(croppedDocument.pages.first?.failureReason ?? "") / \(croppedDocument.pages.map { ($0.mediaBox, $0.cropBox, $0.pixelHeight) })")
    _ = try ScreenshotOCRExporter.exportSearchablePDF(document: croppedDocument, sourceID: croppedDocument.sources[0].id, sourceURL: croppedPDF, to: directory.appendingPathComponent("cropped-searchable.pdf"))
    try ocrRequire(try ScreenshotOCRService.sha256(url: pdfURL) == pdfSource.sha256, "original PDF immutable")
    for format in ScreenshotOCRExportFormat.allCases {
        let output = directory.appendingPathComponent("export.\(format.rawValue)")
        try ScreenshotOCRExporter.export(document: doc, format: format, to: output)
        if format == .json {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let reread = try decoder.decode(ScreenshotOCRDocument.self, from: Data(contentsOf: output))
            try ocrRequire(reread.pages.count == doc.pages.count && reread.sources[1].sha256 == pdfSource.sha256, "JSON provenance round trip")
        }
        do { try ScreenshotOCRExporter.export(document: doc, format: format, to: output); throw OCRTestFailure.assertion("overwrites existing output") } catch ScreenshotOCRError.outputExists { }
    }
    let retry = try await ScreenshotOCRService().retryFailed(document: doc, urlsBySourceID: Dictionary(uniqueKeysWithValues: zip(doc.sources, [imageURL, pdfURL, badURL]).map { ($0.0.id, $0.1) }))
    try ocrRequire(retry.successfulPages == 3 && retry.failedPages.count == 1 && retry.pages[0].id == doc.pages[0].id, "retry preserves successful pages")
    let cancelled = ScreenshotOCRCancellationToken(); cancelled.cancel()
    let cancelDoc = try await ScreenshotOCRService().recognize(urls: [pdfURL], cancellation: cancelled)
    try ocrRequire(cancelDoc.wasCancelled && cancelDoc.successfulPages == 0 && cancelDoc.pages.count == 2, "cancelled pages retained")
    let resumed = try await ScreenshotOCRService().retryFailed(document: cancelDoc, urlsBySourceID: [cancelDoc.sources[0].id: pdfURL])
    try ocrRequire(resumed.successfulPages == 2 && !resumed.wasCancelled, "cancelled pages resume")
    var preprocessedOptions = options; preprocessedOptions.deskew = true; preprocessedOptions.enhanceContrast = true
    let preprocessed = try await ScreenshotOCRService().recognize(urls: [skewedURL], options: preprocessedOptions)
    try ocrRequire(preprocessed.successfulPages == 1 && preprocessed.text.contains("Hello OCR 2026"), "real contrast and deskew recognition: \(preprocessed.pages.first?.failureReason ?? "")")
    try ocrRequire(abs(preprocessed.pages[0].deskewAppliedDegrees) > 2 && abs(preprocessed.pages[0].deskewAppliedDegrees) < 6, "real measured deskew angle \(preprocessed.pages[0].deskewAppliedDegrees)")
    _ = try ScreenshotOCRExporter.exportSearchablePDF(document: preprocessed, sourceID: preprocessed.sources[0].id, sourceURL: skewedURL, to: directory.appendingPathComponent("deskew-searchable.pdf"))
    let nativePDF = directory.appendingPathComponent("native-text.pdf")
    try await MainActor.run { try ocrNativeTextPDF(destination: nativePDF) }
    let correctionOptions = options
    let correctionController = await MainActor.run { let value = ScreenshotOCRController(); value.start(urls: [nativePDF], options: correctionOptions); return value }
    while await correctionController.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
    guard let beforeCorrection = await correctionController.document, let originalLine = beforeCorrection.pages.first?.lines.first(where: { $0.text.contains("Hello") }) else { throw OCRTestFailure.assertion("native PDF correction input") }
    try await correctionController.correctLine(id: originalLine.id, text: "Corrected OCR 2026")
    guard let corrected = await correctionController.document, let correctedLine = corrected.pages[0].lines.first(where: { $0.id == originalLine.id }) else { throw OCRTestFailure.assertion("corrected document missing") }
    try ocrRequire(correctedLine.userEdited && correctedLine.originalText == originalLine.text && correctedLine.confidence == originalLine.confidence && correctedLine.pageQuadrilateral == originalLine.pageQuadrilateral && corrected.sources[0].sha256 == beforeCorrection.sources[0].sha256, "correction preserves original text, confidence, source and geometry")
    let correctedText = directory.appendingPathComponent("corrected.txt")
    try ScreenshotOCRExporter.export(document: corrected, format: .text, to: correctedText)
    try ocrRequire(try String(contentsOf: correctedText, encoding: .utf8).contains("Corrected OCR 2026"), "corrected text export")
    let correctedPDF = directory.appendingPathComponent("corrected-searchable.pdf")
    _ = try ScreenshotOCRExporter.exportSearchablePDF(document: corrected, sourceID: corrected.sources[0].id, sourceURL: nativePDF, to: correctedPDF)
    guard let correctedPDFDocument = PDFDocument(url: correctedPDF) else { throw OCRTestFailure.assertion("corrected PDF unreadable") }
    try ocrRequire(!correctedPDFDocument.findString("Corrected", withOptions: []).isEmpty && correctedPDFDocument.findString("Hello", withOptions: []).isEmpty, "corrected PDF uses new text without conflicting native old text")
    try ocrRequire(try ScreenshotOCRService.sha256(url: nativePDF) == beforeCorrection.sources[0].sha256, "correction leaves source PDF unchanged")
    var limited = options; limited.maxPages = 1
    let large = try await ScreenshotOCRService().recognize(urls: [pdfURL], options: limited)
    try ocrRequire(large.failedPages.count == 1 && large.sources[0].pageCount == 2, "over-page-limit explicit failed source")
    var pixelLimited = options; pixelLimited.maxPixelsPerPage = 10_000
    let tooLarge = try await ScreenshotOCRService().recognize(urls: [imageURL], options: pixelLimited)
    try ocrRequire(tooLarge.failedPages.count == 1, "oversized image rejected before decode")
    var invalidLanguages = options; invalidLanguages.languages = ["invalid-NOT-A-LANGUAGE"]
    do { _ = try await ScreenshotOCRService().recognize(urls: [imageURL], options: invalidLanguages); throw OCRTestFailure.assertion("unsupported language accepted") } catch ScreenshotOCRError.unsupportedLanguages { }
    let encoded = try JSONEncoder().encode(doc)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; object["schemaVersion"] = 2
    let future = try JSONDecoder().decode(ScreenshotOCRDocument.self, from: JSONSerialization.data(withJSONObject: object))
    do { try ScreenshotOCRExporter.export(document: future, format: .json, to: directory.appendingPathComponent("future.json")); throw OCRTestFailure.assertion("future schema accepted") } catch ScreenshotOCRError.invalidDocument { }
    var translationStatus = "macOS15以下不可用"
    if #available(macOS 15.0, *) {
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        switch status {
        case .installed: translationStatus = "en→zh-Hans语言包已安装"
        case .supported: translationStatus = "en→zh-Hans系统支持，但语言包未安装；未触发下载"
        case .unsupported: translationStatus = "en→zh-Hans系统不支持"
        @unknown default: translationStatus = "系统返回未知翻译状态"
        }
        if #available(macOS 26.0, *), status == .installed {
            let result = try await ScreenshotLocalTranslationService.translateInstalled(text: "Hello world", sourceLanguage: "en", targetLanguage: "zh-Hans")
            try ocrRequire(!result.translatedText.isEmpty && result.translatedText != result.sourceText && !result.contentSentToCloud, "installed local translation")
            translationStatus += "；已真实翻译自建 Hello world 样本"
        }
    }
    let resultLines = [
        "OCR tests PASS — synthetic mixed Chinese/English + two columns + PDF /Rotate=90 + CropBox/MediaBox",
        "Vision accurate languages: \(accurate.joined(separator: ", "))",
        "Vision fast languages: \(fast.joined(separator: ", "))",
        "Pages: \(doc.successfulPages) succeeded / \(doc.failedPages.count) intentionally failed; total \(Date().timeIntervalSince(began)) s",
        "Per-page seconds: \(doc.pages.map { String(format: "%.3f", $0.elapsedSeconds) }.joined(separator: ", "))",
        "Searchable PDF: \(validation.pageCount) pages / \(validation.verifiedTextLines) positioned selectable/searchable lines verified",
        "Image searchable PDF: \(imageValidation.verifiedTextLines) lines verified",
        "Deskew: \(preprocessed.pages[0].deskewAppliedDegrees)° measured and inverse-mapped searchable PDF validated; contrast=1.15",
        "CropBox visible scope excludes hidden/cropped text; line correction preserves original/confidence/SHA/coordinates and replaces searchable native text: PASS",
        "Translation: \(translationStatus)",
        "Retry, cancellation, bad input, page/pixel budget, unsupported language, future schema, no-overwrite: PASS"
    ]
    print(resultLines.joined(separator: "\n"))
}

@MainActor
private func ocrNativeTextPDF(destination: URL) throws {
    var media = CGRect(x: 0, y: 0, width: 900, height: 500)
    guard let consumer = CGDataConsumer(url: destination as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw OCRTestFailure.assertion("native text PDF context") }
    context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    "Hello OCR 2026".draw(at: CGPoint(x: 60, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
}

private func ocrCropOnlyPDF(image: CGImage, destination: URL) throws {
    var media = CGRect(x: 0, y: 0, width: 900, height: 500)
    var crop = CGRect(x: 0, y: 0, width: 900, height: 310)
    let mediaBytes = Data(bytes: &media, count: MemoryLayout<CGRect>.size), cropBytes = Data(bytes: &crop, count: MemoryLayout<CGRect>.size)
    guard let consumer = CGDataConsumer(url: destination as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw OCRTestFailure.assertion("crop PDF context") }
    context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBytes, kCGPDFContextCropBox as String: cropBytes] as CFDictionary)
    context.draw(image, in: media); context.endPDFPage(); context.closePDF()
    guard let pdf = PDFDocument(url: destination), let page = pdf.page(at: 0) else { throw OCRTestFailure.assertion("crop PDF read") }
    page.setBounds(crop, for: .cropBox)
    guard pdf.write(to: destination) else { throw OCRTestFailure.assertion("crop PDF write") }
}

private func ocrSkewedImage(_ image: CGImage) throws -> CGImage {
    let width = image.width, height = image.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OCRTestFailure.assertion("skew context") }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2); context.rotate(by: 4 * .pi / 180); context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw OCRTestFailure.assertion("skew render") }; return result
}

@MainActor
private func ocrSyntheticImage() throws -> CGImage {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw OCRTestFailure.assertion("bitmap context") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1800, height: 1000).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black]
    let content: [(String, CGPoint)] = [("Hello OCR 2026", CGPoint(x: 100, y: 860)), ("中文测试 你好世界", CGPoint(x: 100, y: 740)), ("LEFT FIRST", CGPoint(x: 100, y: 560)), ("LEFT SECOND", CGPoint(x: 100, y: 450)), ("RIGHT FIRST", CGPoint(x: 1000, y: 560)), ("RIGHT SECOND", CGPoint(x: 1000, y: 450))]
    for (text, point) in content { text.draw(at: point, withAttributes: attrs) }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = rep.cgImage else { throw OCRTestFailure.assertion("bitmap image") }; return image
}

private func ocrSyntheticPDF(image: CGImage, destination: URL) throws {
    var media = CGRect(x: 10, y: 20, width: 900, height: 500)
    guard let consumer = CGDataConsumer(url: destination as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw OCRTestFailure.assertion("PDF context") }
    func rectData(_ rect: CGRect) -> Data { var rect = rect; return Data(bytes: &rect, count: MemoryLayout<CGRect>.size) }
    context.beginPDFPage([kCGPDFContextMediaBox as String: rectData(media), kCGPDFContextCropBox as String: rectData(media.insetBy(dx: 5, dy: 5))] as CFDictionary)
    context.draw(image, in: media); context.endPDFPage()
    let portrait = CGRect(x: 10, y: 20, width: 500, height: 900)
    context.beginPDFPage([kCGPDFContextMediaBox as String: rectData(portrait), kCGPDFContextCropBox as String: rectData(portrait.insetBy(dx: 5, dy: 5))] as CFDictionary)
    context.saveGState(); context.translateBy(x: portrait.maxX, y: portrait.minY); context.rotate(by: .pi / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: 900, height: 500)); context.restoreGState(); context.endPDFPage(); context.closePDF()
    guard let pdf = PDFDocument(url: destination), let page = pdf.page(at: 1) else { throw OCRTestFailure.assertion("PDF rotation") }; page.rotation = 90
    pdf.page(at: 0)?.setBounds(media.insetBy(dx: 5, dy: 5), for: .cropBox)
    page.setBounds(portrait.insetBy(dx: 5, dy: 5), for: .cropBox)
    guard pdf.write(to: destination) else { throw OCRTestFailure.assertion("write PDF rotation") }
}
