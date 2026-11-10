import Foundation
import AppKit
import Vision
import PDFKit
import CryptoKit
import ImageIO
import CoreImage
import NaturalLanguage

final class ScreenshotOCRService: @unchecked Sendable {
    private struct Work: Sendable {
        var source: ScreenshotOCRSource
        var url: URL
        var page: Int
        var preflightError: String?
    }
    private struct Rendered {
        var image: CGImage
        var media: CGRect
        var crop: CGRect
        var rotation: Int
        var scale: Double
        var pixelsToPage: CGAffineTransform
    }

    static func supportedLanguages(level: ScreenshotOCRRecognitionLevel = .accurate) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level.visionValue
        return try request.supportedRecognitionLanguages()
    }

    func recognize(urls: [URL], options: ScreenshotOCROptions = ScreenshotOCROptions(), cancellation: ScreenshotOCRCancellationToken = ScreenshotOCRCancellationToken(), progress: @escaping @Sendable (ScreenshotOCRProgress) -> Void = { _ in }) async throws -> ScreenshotOCRDocument {
        try await withTaskCancellationHandler(operation: { try await run(urls: urls, options: options, cancellation: cancellation, selectedPages: nil, progress: progress) }, onCancel: { cancellation.cancel() })
    }

    /// Only failed pages run again. Successful page payloads remain byte-for-byte in the model.
    func retryFailed(document: ScreenshotOCRDocument, urlsBySourceID: [UUID: URL], cancellation: ScreenshotOCRCancellationToken = ScreenshotOCRCancellationToken(), progress: @escaping @Sendable (ScreenshotOCRProgress) -> Void = { _ in }) async throws -> ScreenshotOCRDocument {
        guard document.schemaVersion == 1 else { throw ScreenshotOCRError.invalidDocument }
        let selected = Dictionary(grouping: document.retryablePages, by: \.sourceID).mapValues { Set($0.map(\.pageNumber)) }
        let sourceOrder = document.sources.filter { selected[$0.id] != nil }
        let urls = try sourceOrder.map { source -> URL in
            guard let url = urlsBySourceID[source.id] else { throw ScreenshotOCRError.invalidInput("重试所需原件未提供：\(source.displayName)") }
            if !source.sha256.isEmpty, try Self.sha256(url: url, limit: document.options.maxFileBytes) != source.sha256 { throw ScreenshotOCRError.validation("原件内容已变化，不能把新结果混入旧 OCR；请新建批次。") }
            return url
        }
        let selectedByIndex = Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.offset, selected[$0.element.id]!) })
        let retried = try await run(urls: urls, options: document.options, cancellation: cancellation, selectedPages: selectedByIndex, progress: progress)
        var result = document
        for (index, oldSource) in sourceOrder.enumerated() {
            guard retried.sources.indices.contains(index) else { continue }
            let newID = retried.sources[index].id
            for var page in retried.pages where page.sourceID == newID {
                page.sourceID = oldSource.id
                if let existing = result.pages.firstIndex(where: { $0.sourceID == oldSource.id && $0.pageNumber == page.pageNumber }) { result.pages[existing] = page }
            }
        }
        result.wasCancelled = retried.wasCancelled
        return result
    }

    private func run(urls: [URL], options: ScreenshotOCROptions, cancellation: ScreenshotOCRCancellationToken, selectedPages: [Int: Set<Int>]?, progress: @escaping @Sendable (ScreenshotOCRProgress) -> Void) async throws -> ScreenshotOCRDocument {
        guard !urls.isEmpty, urls.count <= 256 else { throw ScreenshotOCRError.resourceLimit("每批需 1–256 个文件。") }
        guard (1...1_000).contains(options.maxPages), (1_000...48_000_000).contains(options.maxPixelsPerPage), (72...300).contains(options.pdfDPI), options.maxFileBytes > 0, options.memoryBudgetBytes >= 32 * 1024 * 1024 else { throw ScreenshotOCRError.resourceLimit("页数、分辨率或内存预算无效。") }
        let supported = try Self.supportedLanguages(level: options.recognitionLevel)
        let unsupported = options.languages.filter { !supported.contains($0) }
        guard unsupported.isEmpty else { throw ScreenshotOCRError.unsupportedLanguages(unsupported) }
        var sources: [ScreenshotOCRSource] = []
        var works: [Work] = []
        var totalInputPages = 0
        for (index, url) in urls.enumerated() {
            var source = ScreenshotOCRSource(id: UUID(), displayName: url.lastPathComponent, sha256: "", byteCount: 0, pageCount: 1, isPDF: false)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ScreenshotOCRError.invalidInput("输入不是普通文件。") }
                source.byteCount = Int64(values.fileSize ?? 0)
                guard source.byteCount > 0, source.byteCount <= options.maxFileBytes, source.byteCount < Int64(options.memoryBudgetBytes / 2) else { throw ScreenshotOCRError.resourceLimit("文件大小超过当前预算。") }
                guard source.byteCount + Int64(options.maxPixelsPerPage) * 12 <= Int64(options.memoryBudgetBytes) else { throw ScreenshotOCRError.resourceLimit("原件与页面渲染缓冲超过内存预算，请减小每页像素上限或分批。") }
                source.sha256 = try Self.sha256(url: url, limit: options.maxFileBytes)
                let fileData = try Self.readVerifiedData(url, source: source)
                if fileData.starts(with: Array("%PDF-".utf8)) {
                    source.isPDF = true
                    guard let provider = CGDataProvider(data: fileData as CFData), let pdf = CGPDFDocument(provider), !pdf.isEncrypted || pdf.isUnlocked else { throw ScreenshotOCRError.invalidInput("PDF 已加密、损坏或不可读取。") }
                    source.pageCount = pdf.numberOfPages
                    guard source.pageCount > 0 else { throw ScreenshotOCRError.invalidInput("PDF 没有页面。") }
                } else {
                    guard CGImageSourceCreateWithData(fileData as CFData, nil) != nil else { throw ScreenshotOCRError.invalidInput("不支持或损坏的图像。") }
                }
                totalInputPages += source.pageCount
                guard totalInputPages <= options.maxPages else { throw ScreenshotOCRError.resourceLimit("批次共有至少 \(totalInputPages) 页，限制为 \(options.maxPages) 页。此文件未处理，请分批。") }
                let pageNumbers = selectedPages?[index]?.sorted() ?? Array(1...source.pageCount)
                for page in pageNumbers {
                    guard (1...source.pageCount).contains(page) else { throw ScreenshotOCRError.invalidDocument }
                    works.append(Work(source: source, url: url, page: page))
                }
            } catch {
                works.append(Work(source: source, url: url, page: selectedPages?[index]?.sorted().first ?? 1, preflightError: error.localizedDescription))
            }
            sources.append(source)
        }
        var document = ScreenshotOCRDocument(engineRevision: VNRecognizeTextRequest().revision, options: options, sources: sources, pages: [])
        // A worker holds compressed input + RGBA + filtering/Vision buffers. Limit live workers.
        let worstInput = Int(sources.map(\.byteCount).max() ?? 0)
        let perWorker = max(16 * 1024 * 1024, worstInput + options.maxPixelsPerPage * 12)
        let workers = max(1, min(2, options.maximumConcurrency, options.memoryBudgetBytes / perWorker))
        await withTaskGroup(of: ScreenshotOCRPage.self) { group in
            var next = 0
            var done = 0
            func enqueue() {
                guard next < works.count, !cancellation.isCancelled else { return }
                let work = works[next]; next += 1
                group.addTask(priority: .userInitiated) {
                    autoreleasepool { Self.process(work, options: options, cancellation: cancellation) }
                }
            }
            for _ in 0..<workers { enqueue() }
            while let page = await group.next() {
                document.pages.append(page); done += 1
                let name = sources.first { $0.id == page.sourceID }?.displayName ?? ""
                progress(ScreenshotOCRProgress(completedPages: done, totalPages: works.count, sourceName: name, pageNumber: page.pageNumber, failedPages: document.failedPages.count))
                enqueue()
            }
            if cancellation.isCancelled {
                document.wasCancelled = true
                for work in works.dropFirst(next) { document.pages.append(Self.failedPage(work, status: .cancelled, reason: "用户已取消，页面未处理。")) }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        document.pages.sort { order[$0.sourceID, default: 0] == order[$1.sourceID, default: 0] ? $0.pageNumber < $1.pageNumber : order[$0.sourceID, default: 0] < order[$1.sourceID, default: 0] }
        return document
    }

    private static func process(_ work: Work, options: ScreenshotOCROptions, cancellation: ScreenshotOCRCancellationToken) -> ScreenshotOCRPage {
        let began = Date()
        do {
            if let reason = work.preflightError { throw ScreenshotOCRError.invalidInput(reason) }
            guard !cancellation.isCancelled else { throw CancellationError() }
            let data = try readVerifiedData(work.url, source: work.source)
            var rendered = try render(data: data, isPDF: work.source.isPDF, pageNumber: work.page, options: options)
            var deskewDegrees = 0.0
            if options.deskew {
                let result = try deskew(rendered, cancellation: cancellation)
                rendered = result.0; deskewDegrees = result.1
            }
            guard !cancellation.isCancelled else { throw CancellationError() }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = options.recognitionLevel.visionValue
            request.recognitionLanguages = options.languages
            request.automaticallyDetectsLanguage = options.languages.isEmpty
            request.usesLanguageCorrection = options.languageCorrection
            let activeID = cancellation.register(request)
            defer { cancellation.remove(activeID) }
            try VNImageRequestHandler(cgImage: rendered.image, orientation: .up, options: [:]).perform([request])
            guard !cancellation.isCancelled else { throw CancellationError() }
            let lines: [ScreenshotOCRLine] = (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let b = observation.boundingBox
                let pixelRect = CGRect(x: b.minX * CGFloat(rendered.image.width), y: b.minY * CGFloat(rendered.image.height), width: b.width * CGFloat(rendered.image.width), height: b.height * CGFloat(rendered.image.height))
                let rectangle = try? candidate.boundingBox(for: candidate.string.startIndex..<candidate.string.endIndex)
                let corners: [CGPoint]
                if let rectangle {
                    corners = [rectangle.bottomLeft, rectangle.bottomRight, rectangle.topRight, rectangle.topLeft].map { CGPoint(x: $0.x * CGFloat(rendered.image.width), y: $0.y * CGFloat(rendered.image.height)).applying(rendered.pixelsToPage) }
                } else {
                    corners = [CGPoint(x: pixelRect.minX, y: pixelRect.minY), CGPoint(x: pixelRect.maxX, y: pixelRect.minY), CGPoint(x: pixelRect.maxX, y: pixelRect.maxY), CGPoint(x: pixelRect.minX, y: pixelRect.maxY)].map { $0.applying(rendered.pixelsToPage) }
                }
                let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!, minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
                let languageRecognizer = NLLanguageRecognizer(); languageRecognizer.processString(candidate.string)
                let inferredLanguages = languageRecognizer.dominantLanguage.map { [$0.rawValue] } ?? []
                return ScreenshotOCRLine(text: candidate.string, boundingBox: b, pageBoundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), pageQuadrilateral: corners, confidence: candidate.confidence, languages: inferredLanguages, readingOrder: 0)
            }
            var page = ScreenshotOCRPage(sourceID: work.source.id, pageNumber: work.page, originalSHA256: work.source.sha256, status: .completed, lines: ScreenshotOCRReadingOrder.sorted(lines), mediaBox: rendered.media, cropBox: rendered.crop, rotation: rendered.rotation, pixelWidth: rendered.image.width, pixelHeight: rendered.image.height, renderScale: rendered.scale, elapsedSeconds: Date().timeIntervalSince(began))
            page.deskewAppliedDegrees = deskewDegrees
            if options.enhanceContrast { page.preprocessing.append("contrast=1.15; original preserved") }
            if options.deskew { page.preprocessing.append("Vision text baseline median; deskew limited to ±12°; original preserved") }
            return page
        } catch {
            var page = failedPage(work, status: cancellation.isCancelled ? .cancelled : .failed, reason: error.localizedDescription)
            page.elapsedSeconds = Date().timeIntervalSince(began)
            return page
        }
    }

    private static func failedPage(_ work: Work, status: ScreenshotOCRPageStatus, reason: String) -> ScreenshotOCRPage {
        ScreenshotOCRPage(sourceID: work.source.id, pageNumber: work.page, originalSHA256: work.source.sha256, status: status, failureReason: reason, lines: [], mediaBox: .zero, cropBox: .zero, rotation: 0, pixelWidth: 0, pixelHeight: 0, renderScale: 0, elapsedSeconds: 0)
    }

    private static func render(data: Data, isPDF: Bool, pageNumber: Int, options: ScreenshotOCROptions) throws -> Rendered {
        var rendered: Rendered
        if isPDF {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: pageNumber) else { throw ScreenshotOCRError.invalidInput("PDF 第 \(pageNumber) 页无法读取。") }
            let media = page.getBoxRect(.mediaBox), crop = page.getBoxRect(.cropBox)
            guard media.width.isFinite, media.height.isFinite, media.width > 0, media.height > 0, media.width < 1_000_000, media.height < 1_000_000 else { throw ScreenshotOCRError.resourceLimit("PDF 页面尺寸异常。") }
            let visible = crop.intersection(media)
            guard !visible.isNull, visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0 else { throw ScreenshotOCRError.invalidInput("PDF 裁切页面框无有效可见区域。") }
            let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
            let rotated = rotation == 90 || rotation == 270
            let uprightSize = CGSize(width: rotated ? visible.height : visible.width, height: rotated ? visible.width : visible.height)
            let requestedScale = options.pdfDPI / 72
            let scale = min(requestedScale, sqrt(Double(options.maxPixelsPerPage) / (uprightSize.width * uprightSize.height)), 12_000 / max(uprightSize.width, uprightSize.height))
            let width = max(1, Int(floor(uprightSize.width * scale))), height = max(1, Int(floor(uprightSize.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotOCRError.resourceLimit("无法分配 PDF 页面像素。") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let uprightMedia = CGRect(x: 0, y: 0, width: rotated ? media.height : media.width, height: rotated ? media.width : media.height)
            let mediaTransform = page.getDrawingTransform(.mediaBox, rect: uprightMedia, rotate: 0, preserveAspectRatio: false)
            let uprightVisible = visible.applying(mediaTransform)
            let sx = CGFloat(width) / uprightVisible.width, sy = CGFloat(height) / uprightVisible.height
            let viewport = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: -uprightVisible.minX * sx, ty: -uprightVisible.minY * sy)
            let transform = mediaTransform.concatenating(viewport)
            context.concatenate(transform); context.clip(to: visible); context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw ScreenshotOCRError.invalidInput("PDF 页面渲染失败。") }
            rendered = Rendered(image: image, media: media, crop: crop, rotation: rotation, scale: scale, pixelsToPage: transform.inverted())
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw ScreenshotOCRError.invalidInput("图像缺少有效尺寸。") }
            guard width <= 12_000, height <= 12_000, Int64(width) * Int64(height) <= options.maxPixelsPerPage else { throw ScreenshotOCRError.resourceLimit("原图 \(width)×\(height) 超过像素限制，请先明确缩小图像。") }
            guard let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ScreenshotOCRError.invalidInput("图像解码失败。") }
            let orientation = (props[kCGImagePropertyOrientation] as? Int32) ?? 1
            let oriented = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
            guard let image = orientation == 1 ? raw : CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]).createCGImage(oriented, from: oriented.extent) else { throw ScreenshotOCRError.invalidInput("图像方向转换失败。") }
            let box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            rendered = Rendered(image: image, media: box, crop: box, rotation: 0, scale: 1, pixelsToPage: .identity)
        }
        if options.enhanceContrast {
            let input = CIImage(cgImage: rendered.image)
            let output = input.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15])
            guard let image = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]).createCGImage(output, from: input.extent) else { throw ScreenshotOCRError.invalidInput("对比度预处理失败；原图未修改。") }
            rendered.image = image
        }
        return rendered
    }

    static func readVerifiedData(_ url: URL, source: ScreenshotOCRSource) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard Int64(data.count) + Int64(chunk.count) <= source.byteCount else { throw ScreenshotOCRError.validation("原件大小在处理期间变化；已停止此页。") }
            data.append(chunk)
        }
        guard Int64(data.count) == source.byteCount, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == source.sha256 else { throw ScreenshotOCRError.validation("原件在处理期间变化；已停止此页。") }
        return data
    }

    /// Conservative optional deskew: median detected baseline, bounded angle, same-size white canvas.
    /// Text geometry maps back through the exact inverse transform; the input file is untouched.
    private static func deskew(_ rendered: Rendered, cancellation: ScreenshotOCRCancellationToken) throws -> (Rendered, Double) {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let detect = VNDetectTextRectanglesRequest(); detect.reportCharacterBoxes = false
        let activeID = cancellation.register(detect); defer { cancellation.remove(activeID) }
        try VNImageRequestHandler(cgImage: rendered.image, orientation: .up, options: [:]).perform([detect])
        let width = CGFloat(rendered.image.width), height = CGFloat(rendered.image.height)
        let angles = (detect.results ?? []).compactMap { observation -> Double? in
            let dx = (observation.bottomRight.x - observation.bottomLeft.x) * width
            let dy = (observation.bottomRight.y - observation.bottomLeft.y) * height
            guard dx > width * 0.04 else { return nil }
            let angle = atan2(dy, dx)
            return abs(angle) <= 12 * .pi / 180 ? angle : nil
        }.sorted()
        guard angles.count >= 2 else { return (rendered, 0) }
        let median = angles[angles.count / 2]
        guard abs(median) > 0.15 * .pi / 180 else { return (rendered, 0) }
        let spread = angles.filter { abs($0 - median) <= 2 * .pi / 180 }.count
        guard spread * 2 >= angles.count else { return (rendered, 0) }
        let angle = -median
        guard let context = CGContext(data: nil, width: rendered.image.width, height: rendered.image.height, bitsPerComponent: 8, bytesPerRow: rendered.image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotOCRError.resourceLimit("去倾斜缓冲无法分配。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rotatedWidth = abs(width * cos(angle)) + abs(height * sin(angle))
        let rotatedHeight = abs(width * sin(angle)) + abs(height * cos(angle))
        let fit = min(width / rotatedWidth, height / rotatedHeight)
        let transform = CGAffineTransform(translationX: width / 2, y: height / 2).rotated(by: angle).scaledBy(x: fit, y: fit).translatedBy(x: -width / 2, y: -height / 2)
        context.concatenate(transform); context.draw(rendered.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ScreenshotOCRError.invalidInput("去倾斜输出失败。") }
        var corrected = rendered; corrected.image = image
        corrected.pixelsToPage = transform.inverted().concatenating(rendered.pixelsToPage)
        return (corrected, angle * 180 / .pi)
    }

    static func sha256(url: URL, limit: Int64 = 512 * 1024 * 1024) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256(), count: Int64 = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += Int64(chunk.count); guard count <= limit else { throw ScreenshotOCRError.resourceLimit("输入文件超出大小限制。") }; digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
