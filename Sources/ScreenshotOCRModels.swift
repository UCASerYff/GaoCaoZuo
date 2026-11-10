import Foundation
import CoreGraphics
import Vision

enum ScreenshotOCRRecognitionLevel: String, Codable, CaseIterable, Sendable {
    case accurate, fast
    var visionValue: VNRequestTextRecognitionLevel { self == .accurate ? .accurate : .fast }
    var title: String { self == .accurate ? "准确" : "快速" }
}

struct ScreenshotOCROptions: Codable, Sendable {
    var languages: [String] = ["zh-Hans", "en-US"]
    var recognitionLevel: ScreenshotOCRRecognitionLevel = .accurate
    var languageCorrection = true
    var enhanceContrast = false
    var deskew = false
    var pdfDPI: Double = 144
    var maxPages = 200
    var maxPixelsPerPage = 12_000_000
    var maxFileBytes: Int64 = 512 * 1024 * 1024
    var maximumConcurrency = 1
    var memoryBudgetBytes = 256 * 1024 * 1024
}

struct ScreenshotOCRSource: Codable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var sha256: String
    var byteCount: Int64
    var pageCount: Int
    var isPDF: Bool
}

struct ScreenshotOCRLine: Codable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var originalText: String? = nil
    var userEdited = false
    /// Normalized, upright rendered page coordinates; origin at bottom left.
    var boundingBox: CGRect
    /// Original PDF page coordinates before /Rotate, or image pixel coordinates.
    var pageBoundingBox: CGRect
    /// Original-coordinate corners in lower-left, lower-right, upper-right, upper-left order.
    var pageQuadrilateral: [CGPoint]
    var confidence: Float
    var confidenceSource = "Apple Vision original recognition; not recomputed after user correction"
    /// Inferred per line by Apple NaturalLanguage, rather than claiming every requested language was detected.
    var languages: [String]
    var languageDetectionMethod = "Apple NaturalLanguage dominantLanguage (inferred)"
    var readingOrder: Int
}

enum ScreenshotOCRPageStatus: String, Codable, Sendable { case completed, failed, cancelled }

struct ScreenshotOCRPage: Codable, Identifiable, Sendable {
    var id = UUID()
    var sourceID: UUID
    var pageNumber: Int
    var originalSHA256: String
    var status: ScreenshotOCRPageStatus
    var failureReason: String?
    var lines: [ScreenshotOCRLine]
    var mediaBox: CGRect
    var cropBox: CGRect
    var rotation: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var renderScale: Double
    var elapsedSeconds: Double
    var deskewAppliedDegrees: Double = 0
    var preprocessing: [String] = []
    var coordinateSystem = "normalized-upright-bottom-left; page-original-bottom-left-before-rotation"
    var text: String { lines.sorted { $0.readingOrder < $1.readingOrder }.map(\.text).joined(separator: "\n") }
}

struct ScreenshotOCRDocument: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var createdAt = Date()
    var engine = "Apple Vision VNRecognizeTextRequest"
    var engineRevision: Int
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var options: ScreenshotOCROptions
    var sources: [ScreenshotOCRSource]
    var pages: [ScreenshotOCRPage]
    var wasCancelled = false
    var successfulPages: Int { pages.filter { $0.status == .completed }.count }
    var failedPages: [ScreenshotOCRPage] { pages.filter { $0.status == .failed } }
    var retryablePages: [ScreenshotOCRPage] { pages.filter { $0.status == .failed || $0.status == .cancelled } }
    var isPartial: Bool { successfulPages > 0 && (successfulPages != pages.count || wasCancelled) }
    var text: String { pages.filter { $0.status == .completed }.map(\.text).joined(separator: "\n\n") }
}

struct ScreenshotOCRProgress: Sendable {
    var completedPages: Int
    var totalPages: Int
    var sourceName: String
    var pageNumber: Int
    var failedPages: Int
    var fractionCompleted: Double { totalPages == 0 ? 0 : Double(completedPages) / Double(totalPages) }
}

struct ScreenshotOCRPDFExportProgress: Sendable {
    enum Phase: String, Sendable { case writing, validating, finished }
    var phase: Phase
    var completedPages: Int
    var totalPages: Int
    var fractionCompleted: Double {
        guard totalPages > 0 else { return 0 }
        switch phase {
        case .writing: return 0.5 * Double(completedPages) / Double(totalPages)
        case .validating: return 0.5 + 0.5 * Double(completedPages) / Double(totalPages)
        case .finished: return 1
        }
    }
    var description: String {
        switch phase {
        case .writing: return "写入原页与文本层：\(completedPages)/\(totalPages) 页"
        case .validating: return "校验文本选取、检索与页面位置：\(completedPages)/\(totalPages) 页"
        case .finished: return "PDF 已完成写入与校验"
        }
    }
}

enum ScreenshotOCRError: LocalizedError {
    case unsupportedLanguages([String]), invalidInput(String), resourceLimit(String), noText, invalidDocument, outputExists, validation(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguages(let codes): return "当前识别模式不支持语种：\(codes.joined(separator: "、"))。请按实际语言列表选择。"
        case .invalidInput(let reason): return "无法读取输入：\(reason)"
        case .resourceLimit(let reason): return "超出安全处理限制：\(reason)"
        case .noText: return "未识别到文字；页面保留为成功的空白结果，请检查原图清晰度。"
        case .invalidDocument: return "OCR 数据版本不支持或页码无效。"
        case .outputExists: return "输出文件已存在，请选择新文件名。"
        case .validation(let reason): return "导出校验未通过：\(reason)"
        }
    }
}

/// Explicitly cancelled Vision requests and unscheduled pages share one token.
final class ScreenshotOCRCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var active: [UUID: VNRequest] = [:]
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); cancelled = true; let requests = Array(active.values); lock.unlock()
        requests.forEach { $0.cancel() }
    }
    func register(_ request: VNRequest) -> UUID {
        let id = UUID(); lock.lock(); active[id] = request; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { request.cancel() }; return id
    }
    func remove(_ id: UUID) { lock.lock(); active[id] = nil; lock.unlock() }
}

/// Recursive XY-cut splits genuine whitespace gutters before ordering rows.
/// Dense tables, mixed scripts and mathematics may still require user correction.
enum ScreenshotOCRReadingOrder {
    static func sorted(_ lines: [ScreenshotOCRLine]) -> [ScreenshotOCRLine] {
        func order(_ values: [ScreenshotOCRLine], depth: Int) -> [ScreenshotOCRLine] {
            guard values.count > 2, depth < 8 else { return rows(values) }
            let rects = values.map(\.boundingBox)
            let intervals = rects.map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
            var right = intervals[0].1
            var gaps: [(Double, Double)] = []
            for interval in intervals.dropFirst() {
                if interval.0 - right > 0.035 { gaps.append((right, interval.0)) }
                right = max(right, interval.1)
            }
            if let gap = gaps.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) {
                let left = values.filter { $0.boundingBox.maxX <= gap.0 + 0.001 }
                let right = values.filter { $0.boundingBox.minX >= gap.1 - 0.001 }
                if left.count >= 2, right.count >= 2, left.count + right.count == values.count {
                    return order(left, depth: depth + 1) + order(right, depth: depth + 1)
                }
            }
            // A full-width heading spans gutters; split at horizontal whitespace first.
            let ys = rects.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var top = ys[0].1
            var best: (Double, Double)?
            for interval in ys.dropFirst() {
                if interval.0 - top > 0.025, best == nil || interval.0 - top > best!.1 - best!.0 { best = (top, interval.0) }
                top = max(top, interval.1)
            }
            if let gap = best {
                let above = values.filter { $0.boundingBox.minY >= gap.1 - 0.001 }
                let below = values.filter { $0.boundingBox.maxY <= gap.0 + 0.001 }
                if !above.isEmpty, !below.isEmpty, above.count + below.count == values.count {
                    return order(above, depth: depth + 1) + order(below, depth: depth + 1)
                }
            }
            return rows(values)
        }
        func rows(_ values: [ScreenshotOCRLine]) -> [ScreenshotOCRLine] {
            values.sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) < min($0.boundingBox.height, $1.boundingBox.height) * 0.45 { return $0.boundingBox.minX < $1.boundingBox.minX }
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
        }
        return order(lines, depth: 0).enumerated().map { index, line in var copy = line; copy.readingOrder = index; return copy }
    }
}
