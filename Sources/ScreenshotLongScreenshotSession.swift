import AppKit
import CoreGraphics

struct ScreenshotScrollTargetIdentity: Equatable {
    let processID: pid_t
    let windowID: CGWindowID
    var frame: CGRect? = nil
    /// User-selected scroll content in the top-left desktop point coordinate system.
    var scrollRegion: CGRect? = nil
}

enum ScreenshotScrollCaptureGeometry {
    static func scrollAnchor(windowBounds: CGRect, selectedRegion: CGRect?) throws -> CGPoint {
        func valid(_ rect: CGRect) -> Bool { rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0 }
        guard valid(windowBounds) else { throw ScreenshotCaptureFailure.invalidRegion }
        let region = selectedRegion ?? windowBounds
        guard valid(region), windowBounds.contains(region) else { throw ScreenshotCaptureFailure.invalidRegion }
        return CGPoint(x: region.midX, y: region.midY)
    }
}

enum ScreenshotScrollCaptureState: Equatable {
    case idle, capturing, awaitingSeam, paused(String), cancelled, completed, failed(String)
}

struct ScreenshotScrollCaptureBudget {
    var maximumPixels = 60_000_000
    var maximumHeight = 40_000
    /// Input images, working pixels and output are all charged conservatively to this budget.
    var maximumMemoryBytes = 512 * 1024 * 1024
    var maximumFrames = 80
    var fixedTopPixels = 0
    var fixedBottomPixels = 0
}

struct ScreenshotScrollSeamEstimate {
    let overlapPixels: Int
    let confidence: Double
    let meanAbsoluteError: Double
    let duplicate: Bool
    let warnings: [String]
    let previousPreview: CGImage
    let currentPreview: CGImage
}

struct ScreenshotScrollSeamPreview {
    let previousImage: CGImage
    let currentImage: CGImage
    let previousRect: CGRect
    let currentRect: CGRect
}

enum ScreenshotScrollSeamPreviewRenderer {
    /// Both strips show the same end of the proposed overlap, including when overlap exceeds the preview limit.
    /// For a zero overlap there are no common rows: show the two adjoining edges instead.
    static func make(previous: CGImage, current: CGImage, overlapPixels: Int, maximumHeight: Int = 320) throws -> ScreenshotScrollSeamPreview {
        guard previous.width == current.width, overlapPixels >= 0, overlapPixels <= min(previous.height, current.height), maximumHeight > 0 else { throw ScreenshotCaptureFailure.invalidRegion }
        let height = min(maximumHeight, overlapPixels > 0 ? overlapPixels : min(previous.height, current.height))
        guard height > 0 else { throw ScreenshotCaptureFailure.invalidRegion }
        let previousRect = CGRect(x: 0, y: previous.height - height, width: previous.width, height: height)
        let currentRect = CGRect(x: 0, y: overlapPixels > 0 ? overlapPixels - height : 0, width: current.width, height: height)
        guard let previousImage = previous.cropping(to: previousRect), let currentImage = current.cropping(to: currentRect) else { throw ScreenshotCaptureFailure.emptyImage }
        return ScreenshotScrollSeamPreview(previousImage: previousImage, currentImage: currentImage, previousRect: previousRect, currentRect: currentRect)
    }
}

private struct ScreenshotScrollFrameSegment {
    let image: CGImage
    let overlap: Int
    let backingBytes: Int
}

/// In-memory bounded scroll stitching. Exceeding the budget stops before allocation; this implementation
/// does not claim unbounded/disk-tiled output. Every low-confidence seam requires explicit acceptance.
@MainActor
final class ScreenshotLongScreenshotSession {
    let target: ScreenshotScrollTargetIdentity?
    let budget: ScreenshotScrollCaptureBudget
    private(set) var state: ScreenshotScrollCaptureState = .idle
    private(set) var seams: [ScreenshotScrollSeamEstimate] = []
    private(set) var pendingSeam: ScreenshotScrollSeamEstimate?
    private(set) var capturedFrameCount = 0
    private(set) var outputHeight = 0
    private(set) var estimatedPeakMemoryBytes = 0
    private var segments: [ScreenshotScrollFrameSegment] = []
    private var pendingImage: CGImage?
    private var pendingBackingBytes = 0
    private var targetProbe: ScreenshotScrollTargetProbing?
    private let targetGuard: ScreenshotScrollTargetGuard?
    private let accessibilityScrollCursor = ScreenshotScrollAccessibilityAction.Cursor()
    private(set) var lastTargetDiagnostic: ScreenshotScrollTargetDiagnostic?
    var pendingFrameHeight: Int? { pendingImage?.height }

    func pendingPreview(overlapPixels: Int) throws -> ScreenshotScrollSeamPreview? {
        guard let previous = segments.last?.image, let current = pendingImage else { return nil }
        guard overlapPixels >= 0, overlapPixels < current.height else { throw ScreenshotCaptureFailure.invalidRegion }
        return try ScreenshotScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: overlapPixels)
    }

    init(target: ScreenshotScrollTargetIdentity? = nil, budget: ScreenshotScrollCaptureBudget = .init(), targetProbe: ScreenshotScrollTargetProbing? = nil) {
        self.target = target; self.budget = budget; self.targetProbe = targetProbe
        self.targetGuard = target.map { ScreenshotScrollTargetGuard(target: $0) }
    }

    /// Manual frames from the same view are supported without Accessibility permission.
    /// The caller can generate synthetic frames for isolated tests; only captureNext performs real capture.
    @discardableResult
    func addFrame(_ frame: CGImage) throws -> ScreenshotScrollSeamEstimate? {
        guard state != .cancelled, state != .completed else { throw ScreenshotCaptureFailure.cancelled }
        guard pendingSeam == nil else { throw ScreenshotCaptureFailure.unsupported("请先预览并确认或拒绝上一条接缝。") }
        let backingBytes = try ScreenshotLongCaptureWindowCrop.imageBytes(frame)
        let image = try normalized(frame)
        guard segments.count < budget.maximumFrames else { throw ScreenshotCaptureFailure.budgetExceeded }
        if let previous = segments.last?.image {
            guard previous.width == image.width, previous.height == image.height else {
                state = .paused("窗口尺寸或截图范围改变，请重新开始长截图。")
                throw ScreenshotCaptureFailure.unsupported("前后帧尺寸不同，已暂停，未拼接错位画面。")
            }
            state = .capturing
            let estimate = try ScreenshotScrollOverlapMatcher.estimate(previous: previous, current: image)
            if estimate.duplicate { state = .paused("画面没有移动，可能已到边界；当前帧未重复追加。"); return estimate }
            try checkBudget(adding: image, overlap: estimate.overlapPixels, backingBytes: backingBytes)
            if estimate.confidence < 0.88 || !estimate.warnings.isEmpty {
                pendingImage = image; pendingBackingBytes = backingBytes; pendingSeam = estimate; state = .awaitingSeam
            } else { append(image, estimate: estimate, backingBytes: backingBytes) }
            return estimate
        }
        try checkBudget(adding: image, overlap: 0, backingBytes: backingBytes)
        segments.append(ScreenshotScrollFrameSegment(image: image, overlap: 0, backingBytes: backingBytes)); capturedFrameCount = 1
        outputHeight = image.height; state = .capturing; return nil
    }

    /// Explicit manual seam correction is bounded to the common frame height.
    func acceptPending(overlapPixels: Int? = nil) throws {
        guard let image = pendingImage, let estimate = pendingSeam else { return }
        let overlap = overlapPixels ?? estimate.overlapPixels
        guard overlap >= 0, overlap < image.height else { throw ScreenshotCaptureFailure.invalidRegion }
        let backingBytes = pendingBackingBytes
        try checkBudget(adding: image, overlap: overlap, backingBytes: backingBytes)
        let accepted = ScreenshotScrollSeamEstimate(overlapPixels: overlap, confidence: estimate.confidence, meanAbsoluteError: estimate.meanAbsoluteError, duplicate: false, warnings: estimate.warnings + ["用户已预览并确认接缝"], previousPreview: estimate.previousPreview, currentPreview: estimate.currentPreview)
        pendingImage = nil; pendingBackingBytes = 0; pendingSeam = nil; append(image, estimate: accepted, backingBytes: backingBytes)
    }

    func rejectPending() { pendingImage = nil; pendingBackingBytes = 0; pendingSeam = nil; state = .paused("已拒绝接缝，可手动调整目标滚动位置后重试。") }
    func pause(_ reason: String = "用户暂停") { if state != .cancelled && state != .completed { state = .paused(reason) } }
    func cancel() { state = .cancelled; pendingImage = nil; pendingBackingBytes = 0; pendingSeam = nil; segments.removeAll(); seams.removeAll(); outputHeight = 0; capturedFrameCount = 0 }

    /// Real capture verifies the foreground PID and selected window before and after every frame.
    @discardableResult
    func captureNext(using service: ScreenshotCaptureService, source: ScreenshotCaptureSource, options: ScreenshotCaptureOptions = .init()) async throws -> ScreenshotScrollSeamEstimate? {
        try await captureNext(capturing: { try await self.captureBoundWindowRegion(using: service, source: source, options: options) })
    }

    private func captureBoundWindowRegion(using service: ScreenshotCaptureService, source: ScreenshotCaptureSource,
                                          options: ScreenshotCaptureOptions) async throws -> CGImage {
        guard #available(macOS 14.2, *) else {
            throw ScreenshotCaptureFailure.unsupported("窗口内长截图需要 macOS 14.2 或更新版本。")
        }
        guard let target, let windowFrame = target.frame, let region = target.scrollRegion,
              case .window(let windowID) = source, windowID == target.windowID else { throw ScreenshotCaptureFailure.invalidRegion }
        guard pendingImage == nil, pendingSeam == nil else {
            throw ScreenshotCaptureFailure.unsupported("请先预览并确认或拒绝上一条接缝。")
        }
        let retained = segments.map(\.backingBytes)
        let maximumBytes = min(options.maximumMemoryBytes, budget.maximumMemoryBytes)
        let available = try ScreenshotLongCaptureWindowCrop.remainingBytes(maximum: maximumBytes, retained: retained)
        var windowOptions = options
        windowOptions.includesShadow = false
        windowOptions.includesChildWindows = false
        windowOptions.maximumMemoryBytes = available
        windowOptions.maximumPixels = min(options.maximumPixels, budget.maximumPixels)
        let frame = try await service.capture(.window(windowID), options: windowOptions)
        let crop = try ScreenshotLongCaptureWindowCrop.copy(frame.image, windowFrame: windowFrame,
            capturedBounds: frame.logicalBounds, desktopRegion: region, scale: frame.scale,
            maximumPixels: windowOptions.maximumPixels, maximumBytes: available)
        estimatedPeakMemoryBytes = max(estimatedPeakMemoryBytes, maximumBytes - available + crop.workingBytes)
        return crop.image
    }

    /// The same production transaction accepts an in-memory producer in isolated CLI tests.
    /// No frame is committed until the second target check and cancellation check both pass.
    @discardableResult
    func captureNext(capturing capture: () async throws -> CGImage) async throws -> ScreenshotScrollSeamEstimate? {
        try Task.checkCancellation()
        try validateCurrentTarget(stage: .preCapture)
        let image = try await capture()
        try Task.checkCancellation()
        try validateCurrentTarget(stage: .postCapture)
        try Task.checkCancellation()
        return try addFrame(image)
    }

    /// A single explicit scroll action, never a hidden global loop. A changed target immediately pauses.
    @discardableResult
    func scrollAndCapture(using service: ScreenshotCaptureService, source: ScreenshotCaptureSource, downwardPoints: Int32 = 240,
                          options: ScreenshotCaptureOptions = .init(), waitingForPointer: () -> Void = {}) async throws -> ScreenshotScrollSeamEstimate? {
        guard let target else { throw ScreenshotCaptureFailure.unsupported("自动滚动需要明确的目标窗口；无目标时请手动滚动。") }
        guard AXIsProcessTrusted() else { throw ScreenshotCaptureFailure.unsupported("辅助功能权限未授权，仍可使用手动滚动逐帧拼接。") }
        return try await scrollAndCapture(downwardPoints: downwardPoints, performScroll: { anchor in
            guard let windowIdentity = self.targetGuard?.boundAccessibilityIdentity else { throw ScreenshotCaptureFailure.sourceMissing }
            try await ScreenshotScrollAccessibilityAction.scrollDown(target: target, anchor: anchor, requestedPoints: CGFloat(downwardPoints), windowIdentity: windowIdentity, cursor: self.accessibilityScrollCursor, waitingForPointer: waitingForPointer) {
                _ = try self.validateCurrentTarget(stage: .preScroll)
            }
        }, capturing: { try await self.captureBoundWindowRegion(using: service, source: source, options: options) })
    }

    /// Injects only the producer and explicit one-shot action, keeping all production guard stages.
    @discardableResult
    func scrollAndCapture(downwardPoints: Int32 = 240, performScroll: (CGPoint) async throws -> Void,
                          capturing capture: () async throws -> CGImage) async throws -> ScreenshotScrollSeamEstimate? {
        guard let target else { throw ScreenshotCaptureFailure.unsupported("自动滚动需要明确的目标窗口；无目标时请手动滚动。") }
        guard downwardPoints <= 2_000, downwardPoints > 0 else { throw ScreenshotCaptureFailure.invalidRegion }
        try Task.checkCancellation()
        guard let bounds = try validateCurrentTarget(stage: .preScroll) else { throw ScreenshotCaptureFailure.sourceMissing }
        try await performScroll(ScreenshotScrollCaptureGeometry.scrollAnchor(windowBounds: bounds, selectedRegion: target.scrollRegion))
        try Task.checkCancellation()
        try validateCurrentTarget(stage: .postScroll)
        return try await captureNext(capturing: capture)
    }

    func finish() throws -> CGImage {
        guard state != .cancelled else { throw ScreenshotCaptureFailure.cancelled }
        guard pendingSeam == nil else { throw ScreenshotCaptureFailure.unsupported("尚有待确认接缝，请预览后再导出。") }
        guard let first = segments.first else { throw ScreenshotCaptureFailure.emptyImage }
        try ScreenshotCaptureGeometry.validateBudget(width: first.image.width, height: outputHeight, maximumPixels: budget.maximumPixels, maximumBytes: budget.maximumMemoryBytes)
        guard let context = CGContext(data: nil, width: first.image.width, height: outputHeight, bitsPerComponent: 8, bytesPerRow: first.image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotCaptureFailure.budgetExceeded }
        var top = 0
        for segment in segments {
            let remaining = segment.image.height - segment.overlap
            guard let crop = segment.image.cropping(to: CGRect(x: 0, y: segment.overlap, width: segment.image.width, height: remaining)) else { throw ScreenshotCaptureFailure.emptyImage }
            context.draw(crop, in: CGRect(x: 0, y: outputHeight - top - remaining, width: crop.width, height: remaining))
            top += remaining
        }
        guard let output = context.makeImage(), top == outputHeight else { throw ScreenshotCaptureFailure.emptyImage }
        state = .completed
        return output
    }

    /// Compatibility entry for existing synthetic tests; real capture always supplies a full snapshot.
    func validateTarget(frontmostPID: pid_t?, activeWindowID: CGWindowID?, activeWindowFrame: CGRect? = nil) throws {
        guard let target else { return }
        let frame = activeWindowFrame ?? (target.frame == nil ? CGRect(x: 0, y: 0, width: 2, height: 2) : nil)
        let windows = activeWindowID.map { [ScreenshotScrollWindowMetadata(windowID: $0, processID: target.processID, frame: frame)] } ?? []
        _ = try validateTarget(ScreenshotScrollTargetSnapshot(frontmostPID: frontmostPID, windows: windows, focus: .accessibilityUnavailable), stage: .preCapture)
    }

    @discardableResult
    func validateTarget(_ snapshot: ScreenshotScrollTargetSnapshot, stage: ScreenshotScrollTargetCheckStage) throws -> CGRect? {
        guard let target, let targetGuard else { return nil }
        do {
            return try targetGuard.validate(snapshot, requiresAccessibility: stage == .preScroll || stage == .postScroll)
        } catch let failure as ScreenshotScrollTargetValidationFailure {
            let diagnostic = ScreenshotScrollTargetDiagnostic(stage: stage, expectedPID: Int64(target.processID),
                actualPID: failure.actualPID.map(Int64.init) ?? ScreenshotScrollTargetDiagnostic.unknown,
                expectedWindowID: Int64(target.windowID), actualWindowID: failure.actualWindowID.map(Int64.init) ?? ScreenshotScrollTargetDiagnostic.unknown)
            lastTargetDiagnostic = diagnostic; diagnostic.recordFailure()
            state = .paused(failure.reason.message)
            throw ScreenshotCaptureFailure.unsupported(failure.reason.message)
        }
    }

    @discardableResult
    private func validateCurrentTarget(stage: ScreenshotScrollTargetCheckStage) throws -> CGRect? {
        guard let target else { return nil }
        if targetProbe == nil { targetProbe = ScreenshotLiveScrollTargetProbe() }
        guard let targetProbe else { throw ScreenshotCaptureFailure.sourceMissing }
        return try validateTarget(targetProbe.sample(target: target), stage: stage)
    }

    private func normalized(_ image: CGImage) throws -> CGImage {
        let top = budget.fixedTopPixels, bottom = budget.fixedBottomPixels
        guard top >= 0, bottom >= 0, top < image.height, bottom < image.height - top,
              image.width >= 8, image.height - top - bottom >= 32,
              let crop = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom)) else { throw ScreenshotCaptureFailure.invalidRegion }
        return crop
    }

    private func checkBudget(adding image: CGImage, overlap: Int, backingBytes: Int) throws {
        let proposedHeight = outputHeight + image.height - overlap
        guard proposedHeight <= budget.maximumHeight else { throw ScreenshotCaptureFailure.budgetExceeded }
        try ScreenshotCaptureGeometry.validateBudget(width: image.width, height: proposedHeight, maximumPixels: budget.maximumPixels, maximumBytes: budget.maximumMemoryBytes)
        // Normalizing fixed edges may retain the complete ROI parent. Charge its actual backing,
        // as well as the existing conservative working copies and full stitched output.
        let available = try ScreenshotLongCaptureWindowCrop.remainingBytes(maximum: budget.maximumMemoryBytes,
                                                                 retained: segments.map(\.backingBytes))
        let outputBytes = image.width * proposedHeight * 4
        let workingBytes = max(backingBytes, try ScreenshotLongCaptureWindowCrop.imageBytes(image))
        guard outputBytes <= available, workingBytes > 0,
              workingBytes <= (available - outputBytes) / 3 else { throw ScreenshotCaptureFailure.budgetExceeded }
        let peak = budget.maximumMemoryBytes - available + workingBytes * 3 + outputBytes
        estimatedPeakMemoryBytes = max(estimatedPeakMemoryBytes, peak)
    }

    private func append(_ image: CGImage, estimate: ScreenshotScrollSeamEstimate, backingBytes: Int) {
        segments.append(ScreenshotScrollFrameSegment(image: image, overlap: estimate.overlapPixels, backingBytes: backingBytes)); seams.append(estimate)
        capturedFrameCount += 1; outputHeight += image.height - estimate.overlapPixels; state = .capturing
    }
}

enum ScreenshotScrollOverlapMatcher {
    static func estimate(previous: CGImage, current: CGImage) throws -> ScreenshotScrollSeamEstimate {
        guard previous.width == current.width, previous.height == current.height, previous.height >= 32 else { throw ScreenshotCaptureFailure.invalidRegion }
        let sampleWidth = min(144, previous.width), height = previous.height
        let a = try grayPixels(previous, width: sampleWidth), b = try grayPixels(current, width: sampleWidth)
        func error(overlap: Int) -> Double {
            let stepY = max(1, overlap / 64), stepX = max(1, sampleWidth / 48)
            var total = 0.0, count = 0
            for y in stride(from: 0, to: overlap, by: stepY) {
                let offsetA = (height - overlap + y) * sampleWidth, offsetB = y * sampleWidth
                for x in stride(from: 2, to: sampleWidth - 2, by: stepX) { total += abs(Double(a[offsetA + x]) - Double(b[offsetB + x])); count += 1 }
            }
            return count > 0 ? total / Double(count) / 255 : 1
        }
        let identicalError = error(overlap: height)
        let minOverlap = max(16, height / 12), maxOverlap = height - max(8, height / 40)
        var ranked: [(Int, Double)] = []
        for overlap in minOverlap...maxOverlap { ranked.append((overlap, error(overlap: overlap))) }
        ranked.sort { $0.1 < $1.1 }
        guard let best = ranked.first else { throw ScreenshotCaptureFailure.invalidRegion }
        let second = ranked.first { abs($0.0 - best.0) > max(3, height / 100) }?.1 ?? 1
        var warnings: [String] = []
        let separation = max(0, second - best.1)
        var confidence = min(1, max(0, (1 - best.1 * 5) * min(1, separation / 0.035)))
        if best.1 > 0.08 { warnings.append("重叠差异较大：可能有动画、视频、滚动过快或范围变化。") }
        if separation < 0.018 { warnings.append("内容重复或纹理不足，存在多个相似接缝。") }
        let fixedHeader = sameEdgeRows(a, b, width: sampleWidth, height: height, fromTop: true)
        let fixedFooter = sameEdgeRows(a, b, width: sampleWidth, height: height, fromTop: false)
        if identicalError > 0.005 && (fixedHeader >= 16 || fixedFooter >= 16) {
            warnings.append("检测到固定页眉/页脚或静止区域；请设置排除像素并重新开始，或人工核对接缝。")
            confidence = min(confidence, 0.75)
        }
        if identicalError > 0.005 && (sameEdgeColumns(a, b, width: sampleWidth, height: height, fromLeft: true) >= max(8, sampleWidth / 8) || sameEdgeColumns(a, b, width: sampleWidth, height: height, fromLeft: false) >= max(8, sampleWidth / 8)) {
            warnings.append("检测到固定侧栏；建议重新选择纯滚动内容范围，或人工核对接缝。")
            confidence = min(confidence, 0.75)
        }
        let duplicate = identicalError < 0.003
        let preview = try ScreenshotScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: duplicate ? height : best.0)
        return ScreenshotScrollSeamEstimate(overlapPixels: duplicate ? height : best.0, confidence: duplicate ? 1 : confidence, meanAbsoluteError: best.1, duplicate: duplicate, warnings: warnings, previousPreview: preview.previousImage, currentPreview: preview.currentImage)
    }

    private static func grayPixels(_ image: CGImage, width: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * image.height)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height)); return true
        }
        guard success else { throw ScreenshotCaptureFailure.emptyImage }; return pixels
    }

    private static func sameEdgeRows(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, fromTop: Bool) -> Int {
        var matched = 0
        for edgeY in 0..<min(height / 4, 160) {
            let y = fromTop ? edgeY : height - 1 - edgeY
            var sum = 0
            for x in stride(from: 2, to: width - 2, by: max(1, width / 32)) { sum += abs(Int(a[y * width + x]) - Int(b[y * width + x])) }
            if sum > max(1, width / max(1, width / 32)) * 2 { break }
            matched += 1
        }
        return matched
    }

    private static func sameEdgeColumns(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, fromLeft: Bool) -> Int {
        var matched = 0
        for edgeX in 0..<max(1, width / 3) {
            let x = fromLeft ? edgeX : width - 1 - edgeX
            var sum = 0, samples = 0
            for y in stride(from: 4, to: height - 4, by: max(1, height / 48)) { sum += abs(Int(a[y * width + x]) - Int(b[y * width + x])); samples += 1 }
            if sum > samples * 2 { break }; matched += 1
        }
        return matched
    }
}
