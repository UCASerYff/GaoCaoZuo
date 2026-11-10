import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum ScreenshotCaptureFailure: LocalizedError {
    case permissionRequired, sourceMissing, invalidRegion, budgetExceeded, emptyImage, cancelled
    case unsupported(String), exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "尚未获得屏幕录制权限，请在系统设置中为搞操作授权后重试。"
        case .sourceMissing: return "所选屏幕或窗口已关闭，请重新选择。"
        case .invalidRegion: return "截图范围无效或不在显示器内。"
        case .budgetExceeded: return "图像超过像素或内存预算，请缩小范围或分段处理。"
        case .emptyImage: return "未取得可用图像。受保护画面可能返回空白，搞操作不会绕过系统保护。"
        case .cancelled: return "已取消。"
        case .unsupported(let reason), .exportFailed(let reason): return reason
        }
    }
}

struct ScreenshotCaptureDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    /// Core Graphics desktop coordinate system: main display top-left is (0, 0).
    let frame: CGRect
    let scale: CGFloat
    let rotation: Int
}

struct ScreenshotCaptureWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let processID: pid_t
    let frame: CGRect
    let isOnScreen: Bool
    /// WindowServer front-to-back rank. Unknown order is not safe for hover hit-testing.
    var zOrder: Int? = nil
    var windowLayer: Int = 0
    var alpha: Double = 1
    var bundleID: String? = nil
}

struct ScreenshotCaptureCatalog {
    let displays: [ScreenshotCaptureDisplay]
    let windows: [ScreenshotCaptureWindow]
}

enum ScreenshotCaptureSource {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Rectangle local to the selected display, in logical points, top-left origin.
    case region(displayID: CGDirectDisplayID, rectInDisplayPoints: CGRect)
}

struct ScreenshotCaptureOptions {
    var delaySeconds: Double = 0
    var showsCursor = false
    var includesShadow = false
    var includesChildWindows = true
    var maximumPixels = 100_000_000
    var maximumMemoryBytes = 512 * 1_024 * 1_024
}

struct ScreenshotCapturedFrame {
    let image: CGImage
    let capturedAt: Date
    let scale: CGFloat
    let sourceDescription: String
    let colorSpaceName: String
    let elapsedMilliseconds: Double
    let logicalBounds: CGRect
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

struct ScreenshotCaptureRegionPlan {
    let sourceRect: CGRect
    let pixelRect: CGRect
}

enum ScreenshotCaptureWindowEligibility {
    private static let desktopOwners: Set<String> = [
        "com.apple.dock", "com.apple.windowserver", "com.apple.loginwindow", "com.apple.windowmanager",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.wallpaper.agent"
    ]
    private static let desktopOwnerNames: Set<String> = [
        "dock", "程序坞", "windowserver", "window server", "loginwindow", "windowmanager", "systemuiserver", "control center", "notificationcenter"
    ]

    static func allows(layer: Int?, alpha: Double?, processID: pid_t?, bundleID: String?, ownerName: String) -> Bool {
        guard layer == 0, let alpha, alpha.isFinite, alpha > 0, alpha <= 1, let processID, processID > 0 else { return false }
        if let bundleID, !bundleID.isEmpty {
            return !desktopOwners.contains(bundleID.lowercased())
        }
        return !desktopOwnerNames.contains(ownerName.lowercased())
    }

    static func validFrame(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.width > 1 && frame.height > 1
    }

    /// The picker and the long-capture guard must reject the same empty/transparent/system entries.
    static func allows(layer: Int?, alpha: Double?, processID: pid_t?, bundleID: String?, ownerName: String, frame: CGRect?) -> Bool {
        validFrame(frame) && allows(layer: layer, alpha: alpha, processID: processID, bundleID: bundleID, ownerName: ownerName)
    }
}

enum ScreenshotCaptureWindowHitTesting {
    static func ranks(frontToBackIDs: [CGWindowID]) -> [CGWindowID: Int] {
        var result: [CGWindowID: Int] = [:]
        for (rank, id) in frontToBackIDs.enumerated() where result[id] == nil { result[id] = rank }
        return result
    }

    static func frontmost(at point: CGPoint, windows: [ScreenshotCaptureWindow]) -> ScreenshotCaptureWindow? {
        windows.enumerated().filter {
            let window = $0.element
            return window.isOnScreen && window.zOrder != nil && window.frame.contains(point)
                && ScreenshotCaptureWindowEligibility.allows(layer: window.windowLayer, alpha: window.alpha, processID: window.processID, bundleID: window.bundleID, ownerName: window.applicationName, frame: window.frame)
        }
            .min { left, right in
                let leftRank = left.element.zOrder!, rightRank = right.element.zOrder!
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }?.element
    }
}

enum ScreenshotCaptureGeometry {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func appKitToDesktop(_ rect: CGRect, mainDisplayTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func desktopToAppKit(_ rect: CGRect, mainDisplayTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Outward rounding preserves edge pixels. SCK accepts logical coordinates and returns oriented pixels.
    static func pixelRect(_ rect: CGRect, scale: CGFloat) throws -> CGRect {
        guard scale.isFinite, scale > 0, rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            throw ScreenshotCaptureFailure.invalidRegion
        }
        let x = floor(rect.minX * scale), y = floor(rect.minY * scale)
        let width = ceil(rect.maxX * scale) - x, height = ceil(rect.maxY * scale) - y
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, width < CGFloat(Int.max), height < CGFloat(Int.max) else { throw ScreenshotCaptureFailure.budgetExceeded }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Snap both edges outward on the display's physical pixel grid, then clamp to its extent.
    /// The returned source rectangle and output dimensions describe exactly the same pixels.
    static func normalizedRegion(_ region: CGRect, displaySize: CGSize, scale: CGFloat) throws -> ScreenshotCaptureRegionPlan {
        guard region.minX.isFinite, region.minY.isFinite, region.maxX.isFinite, region.maxY.isFinite,
              displaySize.width.isFinite, displaySize.height.isFinite, displaySize.width > 0, displaySize.height > 0,
              scale.isFinite, scale > 0 else { throw ScreenshotCaptureFailure.invalidRegion }
        let clipped = region.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw ScreenshotCaptureFailure.invalidRegion }
        let snapped = try pixelRect(clipped, scale: scale)
        let rightLimit = floor(displaySize.width * scale), bottomLimit = floor(displaySize.height * scale)
        guard rightLimit.isFinite, bottomLimit.isFinite else { throw ScreenshotCaptureFailure.budgetExceeded }
        let pixels = snapped.intersection(CGRect(x: 0, y: 0, width: rightLimit, height: bottomLimit))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { throw ScreenshotCaptureFailure.invalidRegion }
        return ScreenshotCaptureRegionPlan(sourceRect: CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale), pixelRect: pixels)
    }

    /// Used for raw bitmap sources; display capture itself is already rotated by ScreenCaptureKit.
    static func rotatePixelPoint(_ point: CGPoint, unrotatedSize: CGSize, degrees: Int) -> CGPoint {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return CGPoint(x: unrotatedSize.height - point.y, y: point.x)
        case 180: return CGPoint(x: unrotatedSize.width - point.x, y: unrotatedSize.height - point.y)
        case 270: return CGPoint(x: point.y, y: unrotatedSize.width - point.x)
        default: return point
        }
    }

    static func validateBudget(width: Int, height: Int, maximumPixels: Int, maximumBytes: Int) throws {
        guard width > 0, height > 0, maximumPixels > 0, maximumBytes > 0,
              width <= maximumPixels / height,
              width <= maximumBytes / 4 / height else { throw ScreenshotCaptureFailure.budgetExceeded }
    }
}

@MainActor
final class ScreenshotCaptureService {
    private var content: SCShareableContent?
    var screenPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Permission is requested only by the caller's explicit permission workflow, never during enumeration.
    func refreshCatalog() async throws -> ScreenshotCaptureCatalog {
        guard screenPermissionGranted else { throw ScreenshotCaptureFailure.permissionRequired }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = fresh
        let orderedWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ranks = ScreenshotCaptureWindowHitTesting.ranks(frontToBackIDs: orderedWindows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let properties = orderedWindows.reduce(into: [CGWindowID: [String: Any]]()) { result, window in
            if let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value, result[id] == nil { result[id] = window }
        }
        let displays = fresh.displays.map { display -> ScreenshotCaptureDisplay in
            let screen = NSScreen.screens.first { ScreenshotCaptureGeometry.displayID($0) == display.displayID }
            let scale = screen?.backingScaleFactor ?? CGFloat(display.width) / max(1, display.frame.width)
            return ScreenshotCaptureDisplay(id: display.displayID, name: screen?.localizedName ?? "显示器 \(display.displayID)",
                                  frame: display.frame, scale: scale, rotation: Int(CGDisplayRotation(display.displayID)))
        }
        let windows = fresh.windows.compactMap { window -> ScreenshotCaptureWindow? in
            guard let application = window.owningApplication, application.processID != ProcessInfo.processInfo.processIdentifier,
                  window.isOnScreen, window.windowLayer == 0, window.frame.width > 1, window.frame.height > 1,
                  let metadata = properties[window.windowID],
                  let layer = (metadata[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let alpha = (metadata[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let ownerPID = (metadata[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let rawBounds = metadata[kCGWindowBounds as String] as? [String: Any],
                  let metadataFrame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  ownerPID == application.processID,
                  ScreenshotCaptureWindowEligibility.validFrame(metadataFrame),
                  ScreenshotCaptureWindowEligibility.allows(layer: layer, alpha: alpha, processID: ownerPID, bundleID: application.bundleIdentifier, ownerName: application.applicationName, frame: window.frame) else { return nil }
            return ScreenshotCaptureWindow(id: window.windowID, title: window.title ?? "无标题窗口", applicationName: application.applicationName,
                                 processID: application.processID, frame: window.frame, isOnScreen: true, zOrder: ranks[window.windowID],
                                 windowLayer: layer, alpha: alpha, bundleID: application.bundleIdentifier)
        }
        return ScreenshotCaptureCatalog(displays: displays, windows: windows)
    }

    func capture(_ source: ScreenshotCaptureSource, options: ScreenshotCaptureOptions = .init()) async throws -> ScreenshotCapturedFrame {
        guard options.delaySeconds.isFinite, (0...60).contains(options.delaySeconds) else { throw ScreenshotCaptureFailure.invalidRegion }
        if options.delaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(options.delaySeconds * 1_000_000_000)) }
        try Task.checkCancellation()
        let catalog = try await refreshCatalog()
        guard let content else { throw ScreenshotCaptureFailure.sourceMissing }
        let start = Date()
        let filter: SCContentFilter
        let bounds: CGRect
        let scale: CGFloat
        let description: String
        var plannedPixelSize: CGSize?
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = options.showsCursor
        configuration.ignoreShadowsSingleWindow = !options.includesShadow
        configuration.ignoreShadowsDisplay = !options.includesShadow
        configuration.preservesAspectRatio = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.2, *) { configuration.includeChildWindows = options.includesChildWindows }
        switch source {
        case .display(let id), .region(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  let info = catalog.displays.first(where: { $0.id == id }) else { throw ScreenshotCaptureFailure.sourceMissing }
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            scale = info.scale
            let local: CGRect
            if case .region(_, let region) = source {
                let plan = try ScreenshotCaptureGeometry.normalizedRegion(region, displaySize: display.frame.size, scale: scale)
                local = plan.sourceRect
                plannedPixelSize = plan.pixelRect.size
                configuration.sourceRect = local
                description = "区域 · \(info.name)"
            } else {
                local = CGRect(origin: .zero, size: display.frame.size)
                description = "显示器 · \(info.name)"
            }
            bounds = local.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        case .window(let id):
            guard let allowed = catalog.windows.first(where: { $0.id == id }),
                  let window = content.windows.first(where: { $0.windowID == id }),
                  window.owningApplication?.processID == allowed.processID,
                  window.frame.width > 0, window.frame.height > 0 else { throw ScreenshotCaptureFailure.sourceMissing }
            filter = SCContentFilter(desktopIndependentWindow: window)
            scale = CGFloat(filter.pointPixelScale)
            bounds = window.frame
            description = "窗口 · \(window.owningApplication?.applicationName ?? "") · \(window.title ?? "无标题")"
        }
        let output: CGRect
        if let plannedPixelSize { output = CGRect(origin: .zero, size: plannedPixelSize) }
        else { output = try ScreenshotCaptureGeometry.pixelRect(CGRect(origin: .zero, size: bounds.size), scale: scale) }
        configuration.width = Int(output.width)
        configuration.height = Int(output.height)
        try ScreenshotCaptureGeometry.validateBudget(width: configuration.width, height: configuration.height, maximumPixels: options.maximumPixels, maximumBytes: options.maximumMemoryBytes)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else { throw ScreenshotCaptureFailure.emptyImage }
        return ScreenshotCapturedFrame(image: image, capturedAt: Date(), scale: scale, sourceDescription: description,
                             colorSpaceName: image.colorSpace?.name as String? ?? "未声明", elapsedMilliseconds: Date().timeIntervalSince(start) * 1000, logicalBounds: bounds)
    }

    /// The system compositor preserves real overlap, ordering and alpha of the chosen windows.
    /// Windows spanning displays are captured display by display, then joined at the highest selected scale.
    func captureWindows(_ ids: [CGWindowID], options: ScreenshotCaptureOptions = .init()) async throws -> ScreenshotCapturedFrame {
        guard !ids.isEmpty, ids.count <= 64, Set(ids).count == ids.count else { throw ScreenshotCaptureFailure.invalidRegion }
        guard options.delaySeconds.isFinite, (0...60).contains(options.delaySeconds) else { throw ScreenshotCaptureFailure.invalidRegion }
        if options.delaySeconds > 0 {
            guard options.delaySeconds.isFinite, options.delaySeconds <= 60 else { throw ScreenshotCaptureFailure.invalidRegion }
            try await Task.sleep(nanoseconds: UInt64(options.delaySeconds * 1_000_000_000))
        }
        let catalog = try await refreshCatalog()
        guard let content else { throw ScreenshotCaptureFailure.sourceMissing }
        let allowedIDs = Set(catalog.windows.map(\.id))
        let selected = content.windows.filter { ids.contains($0.windowID) && allowedIDs.contains($0.windowID) }
        guard selected.count == ids.count else { throw ScreenshotCaptureFailure.sourceMissing }
        let union = selected.reduce(CGRect.null) { $0.union($1.frame) }
        let start = Date()
        var tiles: [(CGImage, CGRect, CGFloat)] = []
        for display in content.displays {
            let region = union.intersection(display.frame)
            guard !region.isNull, region.width > 0, region.height > 0 else { continue }
            try Task.checkCancellation()
            let scale = catalog.displays.first(where: { $0.id == display.displayID })?.scale ?? 1
            let plan = try ScreenshotCaptureGeometry.normalizedRegion(region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY), displaySize: display.frame.size, scale: scale)
            let config = SCStreamConfiguration()
            config.sourceRect = plan.sourceRect
            config.width = Int(plan.pixelRect.width); config.height = Int(plan.pixelRect.height)
            config.showsCursor = options.showsCursor
            config.ignoreShadowsDisplay = !options.includesShadow
            // SCStreamConfiguration's default background is transparent. Its CGColor property is
            // assign/unowned, so do not store a short-lived temporary color in it.
            try ScreenshotCaptureGeometry.validateBudget(width: config.width, height: config.height, maximumPixels: options.maximumPixels, maximumBytes: options.maximumMemoryBytes)
            let filter = SCContentFilter(display: display, including: selected)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            tiles.append((image, plan.sourceRect.offsetBy(dx: display.frame.minX, dy: display.frame.minY), scale))
        }
        let scale = tiles.map(\.2).max() ?? 1
        let visibleBounds = tiles.reduce(CGRect.null) { $0.union($1.1) }
        let image = try Self.compose(tiles: tiles, bounds: visibleBounds, scale: scale, options: options)
        return ScreenshotCapturedFrame(image: image, capturedAt: Date(), scale: scale, sourceDescription: "多窗口 · \(ids.count) 个（系统合成）", colorSpaceName: "sRGB", elapsedMilliseconds: Date().timeIntervalSince(start) * 1000, logicalBounds: visibleBounds)
    }

    /// Capture a desktop rectangle split across displays. Gaps stay transparent; scales are never treated as points.
    func captureDesktopRegion(_ rect: CGRect, options: ScreenshotCaptureOptions = .init()) async throws -> ScreenshotCapturedFrame {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              options.delaySeconds.isFinite, (0...60).contains(options.delaySeconds) else { throw ScreenshotCaptureFailure.invalidRegion }
        let catalog = try await refreshCatalog()
        let start = Date()
        var tiles: [(CGImage, CGRect, CGFloat)] = []
        var immediate = options
        if options.delaySeconds > 0 {
            guard options.delaySeconds.isFinite, options.delaySeconds <= 60 else { throw ScreenshotCaptureFailure.invalidRegion }
            try await Task.sleep(nanoseconds: UInt64(options.delaySeconds * 1_000_000_000))
        }
        immediate.delaySeconds = 0
        for display in catalog.displays {
            let region = rect.standardized.intersection(display.frame)
            guard !region.isNull, region.width > 0, region.height > 0 else { continue }
            let frame = try await capture(.region(displayID: display.id, rectInDisplayPoints: region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)), options: immediate)
            tiles.append((frame.image, frame.logicalBounds, frame.scale))
        }
        guard !tiles.isEmpty else { throw ScreenshotCaptureFailure.invalidRegion }
        let scale = tiles.map(\.2).max() ?? 1
        let visibleBounds = tiles.reduce(CGRect.null) { $0.union($1.1) }
        let image = try Self.compose(tiles: tiles, bounds: visibleBounds, scale: scale, options: options)
        return ScreenshotCapturedFrame(image: image, capturedAt: Date(), scale: scale, sourceDescription: "桌面区域 · \(tiles.count) 块显示器", colorSpaceName: "sRGB", elapsedMilliseconds: Date().timeIntervalSince(start) * 1000, logicalBounds: visibleBounds)
    }

    private static func compose(tiles: [(CGImage, CGRect, CGFloat)], bounds: CGRect, scale: CGFloat, options: ScreenshotCaptureOptions) throws -> CGImage {
        let dimensions = try ScreenshotCaptureGeometry.pixelRect(CGRect(origin: .zero, size: bounds.size), scale: scale)
        let width = Int(dimensions.width), height = Int(dimensions.height)
        try ScreenshotCaptureGeometry.validateBudget(width: width, height: height, maximumPixels: options.maximumPixels, maximumBytes: options.maximumMemoryBytes)
        let retainedTileBytes = tiles.reduce(0) { partial, tile in
            let bytes = tile.0.bytesPerRow.multipliedReportingOverflow(by: tile.0.height)
            if bytes.overflow { return Int.max }
            let total = partial.addingReportingOverflow(bytes.partialValue)
            return total.overflow ? Int.max : total.partialValue
        }
        let outputBytes = width * height * 4
        guard retainedTileBytes <= options.maximumMemoryBytes - outputBytes else { throw ScreenshotCaptureFailure.budgetExceeded }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotCaptureFailure.budgetExceeded }
        context.interpolationQuality = .high
        for (image, rect, _) in tiles {
            context.draw(image, in: CGRect(x: (rect.minX - bounds.minX) * scale, y: (bounds.maxY - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        guard let image = context.makeImage() else { throw ScreenshotCaptureFailure.emptyImage }
        return image
    }
}

enum ScreenshotCaptureImageExport {
    enum Format: String, CaseIterable { case png, jpeg, tiff, heic
        var utType: UTType { switch self { case .png: return .png; case .jpeg: return .jpeg; case .tiff: return .tiff; case .heic: return .heic } }
        var supportsAlpha: Bool { self == .png || self == .tiff }
    }

    /// Writes to a new file only. Export is decoded again before the atomic destination move.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, format: Format = .png, quality: Double = 0.9, maximumDimension: Int? = nil) throws -> CGImage {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path), quality.isFinite, (0...1).contains(quality) else { throw ScreenshotCaptureFailure.exportFailed("输出路径已存在，或导出参数无效。请选择新文件名。") }
        let exportImage: CGImage
        if let dimension = maximumDimension, dimension > 0, max(image.width, image.height) > dimension {
            let ratio = Double(dimension) / Double(max(image.width, image.height))
            let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotCaptureFailure.budgetExceeded }
            context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resized = context.makeImage() else { throw ScreenshotCaptureFailure.emptyImage }; exportImage = resized
        } else { exportImage = image }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-screenshot-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, format.utType.identifier as CFString, 1, nil) else { throw ScreenshotCaptureFailure.exportFailed("本系统不支持所选图像编码格式。") }
        CGImageDestinationAddImage(destination, exportImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithURL(staging as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width == exportImage.width, decoded.height == exportImage.height else { throw ScreenshotCaptureFailure.exportFailed("导出后重新解码校验失败，原图已保留。") }
        if format.supportsAlpha && exportImage.alphaInfo != .none && exportImage.alphaInfo != .noneSkipFirst && exportImage.alphaInfo != .noneSkipLast {
            guard decoded.alphaInfo != .none, decoded.alphaInfo != .noneSkipFirst, decoded.alphaInfo != .noneSkipLast else { throw ScreenshotCaptureFailure.exportFailed("导出文件未保留透明通道。") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: url)
        return decoded
    }

    /// Original artwork built from primitives, with optional user-selected wallpaper. No device/competitor asset.
    static func framed(_ image: CGImage, wallpaper: CGImage? = nil, padding: Int = 72, cornerRadius: CGFloat = 20, shadow: Bool = true, shell: Bool = true) throws -> CGImage {
        guard (0...2048).contains(padding), cornerRadius >= 0, cornerRadius.isFinite else { throw ScreenshotCaptureFailure.invalidRegion }
        let bar = shell ? 48 : 0, width = image.width + padding * 2, height = image.height + padding * 2 + bar
        try ScreenshotCaptureGeometry.validateBudget(width: width, height: height, maximumPixels: 100_000_000, maximumBytes: 512 * 1024 * 1024)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotCaptureFailure.budgetExceeded }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        if let wallpaper { context.draw(wallpaper, in: canvas) }
        let body = CGRect(x: padding, y: padding, width: image.width, height: image.height + bar)
        context.saveGState()
        if shadow { context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.32)) }
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.addPath(CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)); context.fillPath()
        context.restoreGState(); context.saveGState()
        context.addPath(CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)); context.clip()
        context.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
        if shell {
            context.setFillColor(CGColor(gray: 0.91, alpha: 1)); context.fill(CGRect(x: padding, y: padding + image.height, width: image.width, height: bar))
            for (index, gray) in [CGFloat(0.40), 0.54, 0.68].enumerated() {
                context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fillEllipse(in: CGRect(x: padding + 18 + index * 22, y: padding + image.height + 18, width: 12, height: 12))
            }
        }
        context.restoreGState()
        guard let output = context.makeImage() else { throw ScreenshotCaptureFailure.emptyImage }; return output
    }
}

struct ScreenshotCapturedPixelColor {
    let red: Int, green: Int, blue: Int, alpha: Int
    let colorSpace: String
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

enum ScreenshotCaptureColorSampler {
    @MainActor static func sampleSystemColor() async -> NSColor? {
        await withCheckedContinuation { continuation in NSColorSampler().show { continuation.resume(returning: $0) } }
    }

    static func pixel(in image: CGImage, at point: CGPoint) throws -> ScreenshotCapturedPixelColor {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { throw ScreenshotCaptureFailure.invalidRegion }
        var bytes = [UInt8](repeating: 0, count: 4)
        let result: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard result else { throw ScreenshotCaptureFailure.emptyImage }
        let alpha = Int(bytes[3])
        func unpremultiply(_ value: UInt8) -> Int { alpha == 0 ? 0 : min(255, Int(value) * 255 / alpha) }
        return ScreenshotCapturedPixelColor(red: unpremultiply(bytes[0]), green: unpremultiply(bytes[1]), blue: unpremultiply(bytes[2]), alpha: alpha, colorSpace: "sRGB（从原图 \(image.colorSpace?.name as String? ?? "未声明") 转换）")
    }

    static func magnifier(in image: CGImage, at point: CGPoint, radius: Int = 8, scale: Int = 12) throws -> CGImage {
        guard (1...64).contains(radius), (1...32).contains(scale) else { throw ScreenshotCaptureFailure.invalidRegion }
        let rect = CGRect(x: Int(point.x) - radius, y: Int(point.y) - radius, width: radius * 2 + 1, height: radius * 2 + 1).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: rect), let context = CGContext(data: nil, width: cropped.width * scale, height: cropped.height * scale, bitsPerComponent: 8, bytesPerRow: cropped.width * scale * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotCaptureFailure.invalidRegion }
        context.interpolationQuality = .none; context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width * scale, height: cropped.height * scale))
        guard let output = context.makeImage() else { throw ScreenshotCaptureFailure.emptyImage }; return output
    }
}
