// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import CoreGraphics

private func captureRegressionCheck(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try condition() else { throw NSError(domain: "CaptureRegressionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}

private func captureRegressionRows(height: Int, offset: Int = 0, period: Int? = nil) throws -> CGImage {
    let width = 8
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let row = period.map { (y + offset) % $0 } ?? (y + offset)
        for x in 0..<width {
            let index = (y * width + x) * 4
            if period != nil {
                pixels[index] = UInt8(row * 13); pixels[index + 1] = pixels[index]; pixels[index + 2] = pixels[index]
            } else {
                pixels[index] = UInt8(truncatingIfNeeded: row)
                pixels[index + 1] = UInt8(truncatingIfNeeded: row >> 8)
                pixels[index + 2] = UInt8(truncatingIfNeeded: row * 31 + x)
            }
            pixels[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScreenshotCaptureFailure.emptyImage }
    return image
}

/// Only new regressions from the 2026-10-18 audit. No NSApplication, NSPanel, device, permission or capture calls.
@MainActor
func ScreenshotRunCaptureRegressionTests() throws {
    let ranks = ScreenshotCaptureWindowHitTesting.ranks(frontToBackIDs: [11, 12, 11, 13])
    try captureRegressionCheck(ranks[11] == 0 && ranks[12] == 1, "WindowServer rank should preserve the first occurrence")
    let front = ScreenshotCaptureWindow(id: 11, title: "Synthetic front", applicationName: "Fixture", processID: 1,
                              frame: CGRect(x: 0, y: 0, width: 1000, height: 800), isOnScreen: true, zOrder: ranks[11])
    let hidden = ScreenshotCaptureWindow(id: 12, title: "Synthetic hidden", applicationName: "Fixture", processID: 2,
                               frame: CGRect(x: 100, y: 100, width: 200, height: 200), isOnScreen: true, zOrder: ranks[12])
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: CGPoint(x: 150, y: 150), windows: [hidden, front])?.id == 11, "A fully covered small window must not replace the visible front window")
    let protruding = ScreenshotCaptureWindow(id: 13, title: "Synthetic partial", applicationName: "Fixture", processID: 3,
                                   frame: CGRect(x: 900, y: 100, width: 200, height: 200), isOnScreen: true, zOrder: 2)
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: CGPoint(x: 1050, y: 150), windows: [front, protruding])?.id == 13, "The visible protruding part remains selectable")
    let unknown = ScreenshotCaptureWindow(id: 14, title: "Unknown order", applicationName: "Fixture", processID: 4,
                                frame: hidden.frame, isOnScreen: true)
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: CGPoint(x: 150, y: 150), windows: [unknown]) == nil, "Unknown z-order must not be guessed from area")

    let target = CGRect(x: -200, y: 100, width: 1200, height: 800)
    let content = CGRect(x: 600, y: 200, width: 200, height: 400)
    try captureRegressionCheck(try ScreenshotScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: content) == CGPoint(x: 700, y: 400), "A right-side pane must receive the scroll instead of the window centre")
    try captureRegressionCheck(try ScreenshotScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: nil) == CGPoint(x: 400, y: 500), "An explicit whole-window target may use its centre")
    do {
        _ = try ScreenshotScrollCaptureGeometry.scrollAnchor(windowBounds: target, selectedRegion: CGRect(x: 990, y: 200, width: 50, height: 20))
        throw NSError(domain: "CaptureRegressionTests", code: 2)
    } catch ScreenshotCaptureFailure.invalidRegion {}

    let previous = try captureRegressionRows(height: 1400)
    let current = try captureRegressionRows(height: 1400, offset: 400)
    let preview = try ScreenshotScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 1000)
    try captureRegressionCheck(preview.previousRect.minY == 1080 && preview.currentRect.minY == 680 && preview.currentImage.height == 320, "Large overlaps must preview corresponding rows at the end of the overlap")
    for y in [0, 159, 319] {
        let a = try ScreenshotCaptureColorSampler.pixel(in: preview.previousImage, at: CGPoint(x: 3, y: y))
        let b = try ScreenshotCaptureColorSampler.pixel(in: preview.currentImage, at: CGPoint(x: 3, y: y))
        try captureRegressionCheck(a.hex == b.hex, "Preview strips should show identical source rows for a true 1000px overlap")
    }
    let small = try ScreenshotScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 16)
    try captureRegressionCheck(small.currentImage.height == 16 && small.currentRect.minY == 0, "Small overlaps must not include unmatched rows")
    let direct = try ScreenshotScrollSeamPreviewRenderer.make(previous: previous, current: current, overlapPixels: 0)
    try captureRegressionCheck(direct.currentRect.minY == 0 && direct.previousRect.minY == 1080, "A zero overlap previews directly adjoining edges")

    let pending = ScreenshotLongScreenshotSession()
    _ = try pending.addFrame(captureRegressionRows(height: 1400, period: 16))
    _ = try pending.addFrame(captureRegressionRows(height: 1400, offset: 6, period: 16))
    try captureRegressionCheck(pending.pendingSeam != nil, "A repeated pattern should provide a pending seam for preview adjustment")
    let proposed = try pending.pendingPreview(overlapPixels: 1000)
    let adjusted = try pending.pendingPreview(overlapPixels: 800)
    try captureRegressionCheck(proposed?.currentRect.minY == 680 && adjusted?.currentRect.minY == 480, "Changing the proposed overlap must change the preview crop used by the slider")

    let fractional = try ScreenshotCaptureGeometry.normalizedRegion(CGRect(x: 0.25, y: 2.5, width: 11.5, height: 5), displaySize: CGSize(width: 100, height: 100), scale: 2)
    try captureRegressionCheck(fractional.pixelRect == CGRect(x: 0, y: 5, width: 24, height: 10), "Fractional Retina origin and max edge both round outward")
    try captureRegressionCheck(fractional.sourceRect == CGRect(x: 0, y: 2.5, width: 12, height: 5) && fractional.sourceRect.width * 2 == fractional.pixelRect.width, "SCK source rectangle and output width must describe the same physical pixels")
    let clipped = try ScreenshotCaptureGeometry.normalizedRegion(CGRect(x: -0.25, y: 99.25, width: 4, height: 4), displaySize: CGSize(width: 100, height: 100), scale: 2)
    try captureRegressionCheck(clipped.sourceRect == CGRect(x: 0, y: 99, width: 4, height: 1) && clipped.pixelRect.height == 2, "Outward snapping must remain inside the display at both outer edges")
    let regular = try ScreenshotCaptureGeometry.normalizedRegion(CGRect(x: 1.2, y: 2.3, width: 2.4, height: 3.4), displaySize: CGSize(width: 100, height: 100), scale: 1)
    try captureRegressionCheck(regular.sourceRect == CGRect(x: 1, y: 2, width: 3, height: 4), "Fractional 1x source edges should round outward")
    do {
        _ = try ScreenshotCaptureGeometry.normalizedRegion(CGRect(x: 120, y: 120, width: 10, height: 10), displaySize: CGSize(width: 100, height: 100), scale: 2)
        throw NSError(domain: "CaptureRegressionTests", code: 3)
    } catch ScreenshotCaptureFailure.invalidRegion {}

    try captureRegressionCheck(ScreenshotPinnedImageGeometry.actualPixelScale(backingScale: 1) == 1, "A 1x screen uses one point per image pixel")
    try captureRegressionCheck(ScreenshotPinnedImageGeometry.actualPixelScale(backingScale: 2) == 0.5, "A 2x screen uses half a point per image pixel")
    try captureRegressionCheck(400 * ScreenshotPinnedImageGeometry.actualPixelScale(backingScale: 2) * 2 == 400, "1:1 on Retina must keep physical pixel count unchanged")
    print("PASS Capture regressions: front-to-back hit, selected scroll anchor, corresponding seam previews and adjustment, fractional 1x/2x region snapping, current-screen pin scale (no GUI/capture).")
    try ScreenshotRunCaptureWindowEventRegressionTests()
    try ScreenshotRunCaptureSelectionLabelRegressionTests()
}

/// Regression for the actual full-screen Dock overlay mis-hit. Framework event conversion is injected;
/// this does not create a panel, synthesize/post an event, enumerate live windows or capture the screen.
@MainActor
func ScreenshotRunCaptureWindowEventRegressionTests() throws {
    let regularApplications = ["com.apple.finder", "com.apple.Safari", "com.apple.TextEdit", "com.apple.Terminal"]
    for bundleID in regularApplications {
        try captureRegressionCheck(ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 1, processID: 42, bundleID: bundleID, ownerName: "Synthetic sample"), "Ordinary sample application windows must remain selectable")
    }
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: 20, alpha: 1, processID: 42, bundleID: "com.example.sample", ownerName: "Synthetic floating layer"), "Floating layers must not participate in ordinary-window hit-testing")
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 0, processID: 42, bundleID: "com.example.sample", ownerName: "Synthetic transparent window"), "A fully transparent window must not cover a visible sample")
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: nil, alpha: 1, processID: 42, bundleID: "com.example.sample", ownerName: "Missing metadata"), "Missing layer metadata cannot be treated as an ordinary window")
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: .nan, processID: 42, bundleID: "com.example.sample", ownerName: "Invalid alpha"), "Non-finite transparency metadata must fail closed")
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 1, processID: 42, bundleID: "com.apple.dock", ownerName: "程序坞"), "Even a layer-zero full-screen Dock rectangle is a system overlay")
    try captureRegressionCheck(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 1, processID: 42, bundleID: nil, ownerName: "程序坞"), "Localized Dock owner fallback must reject a missing bundle identifier")

    let fullScreen = CGRect(x: 0, y: 0, width: 3420, height: 2224)
    let dock = ScreenshotCaptureWindow(id: 90, title: "Dock", applicationName: "程序坞", processID: 42, frame: fullScreen, isOnScreen: true,
                             zOrder: 0, windowLayer: 0, alpha: 1, bundleID: "com.apple.dock")
    let transparent = ScreenshotCaptureWindow(id: 92, title: "Transparent fixture", applicationName: "Fixture", processID: 43, frame: fullScreen, isOnScreen: true,
                                    zOrder: 1, windowLayer: 0, alpha: 0, bundleID: "com.example.fixture")
    let finder = ScreenshotCaptureWindow(id: 91, title: "Acceptance", applicationName: "Finder", processID: 44, frame: CGRect(x: 400, y: 200, width: 1800, height: 1400), isOnScreen: true,
                               zOrder: 2, windowLayer: 0, alpha: 1, bundleID: "com.apple.finder")
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: CGPoint(x: 1400, y: 800), windows: [dock, transparent, finder])?.id == finder.id, "A full-screen system Dock/transparent rectangle must not replace the known Finder sample")

    let local = CGPoint(x: 120, y: 80)
    var receivedLocal: CGPoint?
    let screen = ScreenshotCaptureSelectionGeometry.screenPoint(eventLocationInWindow: local, convertToScreen: { point in
        receivedLocal = point
        return CGPoint(x: point.x - 500, y: point.y + 300)
    })
    try captureRegressionCheck(receivedLocal == local && screen == CGPoint(x: -380, y: 380), "The event-local point must go through the actual window-to-screen conversion boundary")
    let eventDesktopPoint = ScreenshotCaptureSelectionGeometry.desktopPoint(appKitScreenPoint: screen, mainDisplayTop: 1000)
    try captureRegressionCheck(eventDesktopPoint == CGPoint(x: -380, y: 620), "Negative display origins and the AppKit/desktop vertical conversion must remain correct")
    let eventTarget = ScreenshotCaptureWindow(id: 93, title: "Directed click sample", applicationName: "Fixture", processID: 45,
                                    frame: CGRect(x: -450, y: 550, width: 300, height: 300), isOnScreen: true, zOrder: 1)
    let staleCursorTarget = ScreenshotCaptureWindow(id: 94, title: "Unrelated cursor fixture", applicationName: "Fixture", processID: 46,
                                          frame: CGRect(x: 50, y: 900, width: 300, height: 300), isOnScreen: true, zOrder: 0)
    let staleDesktopPoint = ScreenshotCaptureSelectionGeometry.desktopPoint(appKitScreenPoint: CGPoint(x: 100, y: 0), mainDisplayTop: 1000)
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: staleDesktopPoint, windows: [staleCursorTarget, eventTarget])?.id == 94, "The stale global cursor fixture must represent a different eligible window")
    try captureRegressionCheck(ScreenshotCaptureWindowHitTesting.frontmost(at: eventDesktopPoint, windows: [staleCursorTarget, eventTarget])?.id == 93, "A directed click must choose its event location rather than the unrelated global cursor location")
    let end = ScreenshotCaptureSelectionGeometry.screenPoint(eventLocationInWindow: CGPoint(x: 150, y: 110), convertToScreen: { CGPoint(x: $0.x - 500, y: $0.y + 300) })
    let selection = ScreenshotCaptureSelectionGeometry.selectionRect(from: screen, to: end)
    try captureRegressionCheck(selection == CGRect(x: -380, y: 380, width: 30, height: 30), "Dragging must use its two converted event positions")
    try captureRegressionCheck(ScreenshotCaptureGeometry.appKitToDesktop(selection, mainDisplayTop: 1000) == CGRect(x: -380, y: 590, width: 30, height: 30), "The final event-derived selection must keep its real desktop coordinates")
    print("PASS Window-event regressions: layer/alpha/system-owner filtering, full-screen Dock exclusion, event-local conversion and directed-click/drag coordinates (no GUI/capture).")
}

/// Display/selection values only. No NSScreen enumeration, event posting, panels or capture.
func ScreenshotRunCaptureSelectionLabelRegressionTests() throws {
    let fixtures: [(screen: CGRect, selection: CGRect, mainTop: CGFloat, scale: CGFloat, local: CGRect, pixels: CGRect)] = [
        (CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0.25, y: 92.5, width: 11.5, height: 5), 100, 2,
         CGRect(x: 0.25, y: 2.5, width: 11.5, height: 5), CGRect(x: 0, y: 5, width: 24, height: 10)),
        (CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 1.2, y: 94.3, width: 2.4, height: 3.4), 100, 1,
         CGRect(x: 1.2, y: 2.3, width: 2.4, height: 3.4), CGRect(x: 1, y: 2, width: 3, height: 4)),
        (CGRect(x: -500, y: -200, width: 100, height: 100), CGRect(x: -499.75, y: -107.5, width: 11.5, height: 5), 1000, 2,
         CGRect(x: 0.25, y: 2.5, width: 11.5, height: 5), CGRect(x: 0, y: 5, width: 24, height: 10)),
        (CGRect(x: -500, y: -200, width: 100, height: 100), CGRect(x: -500.25, y: -106.75, width: 4, height: 7), 1000, 2,
         CGRect(x: -0.25, y: -0.25, width: 4, height: 7), CGRect(x: 0, y: 0, width: 8, height: 14)),
        (CGRect(x: -500, y: -200, width: 100, height: 100), CGRect(x: -500.25, y: -203.25, width: 4, height: 4), 1000, 2,
         CGRect(x: -0.25, y: 99.25, width: 4, height: 4), CGRect(x: 0, y: 198, width: 8, height: 2)),
        (CGRect(x: 100, y: 200, width: 80, height: 60), CGRect(x: 100.2, y: 254.75, width: 5.5, height: 4), 1000, 1,
         CGRect(x: 0.2, y: 1.25, width: 5.5, height: 4), CGRect(x: 0, y: 1, width: 6, height: 5))
    ]
    for fixture in fixtures {
        let label = try ScreenshotCaptureSelectionGeometry.regionPlan(selectionInAppKit: fixture.selection, screenFrameInAppKit: fixture.screen, mainDisplayTop: fixture.mainTop, scale: fixture.scale)
        let capture = try ScreenshotCaptureGeometry.normalizedRegion(fixture.local, displaySize: fixture.screen.size, scale: fixture.scale)
        try captureRegressionCheck(label.pixelRect == fixture.pixels, "Selection labels must use expected outward-rounded physical pixels, including clipped edges")
        try captureRegressionCheck(label.pixelRect == capture.pixelRect && label.sourceRect == capture.sourceRect, "The label and actual capture plan must describe the same display-local pixels")
    }
    let fractional = fixtures[0]
    try captureRegressionCheck(ceil(fractional.selection.width * fractional.scale) == 23 && fractional.pixels.width == 24, "The regression must distinguish the former width-only rounding from correct edge rounding")
    do {
        _ = try ScreenshotCaptureSelectionGeometry.regionPlan(selectionInAppKit: CGRect(x: -800, y: -800, width: 5, height: 5), screenFrameInAppKit: fixtures[2].screen, mainDisplayTop: 1000, scale: 2)
        throw NSError(domain: "CaptureRegressionTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Off-screen label range was accepted"])
    } catch ScreenshotCaptureFailure.invalidRegion {}
    print("PASS Selection label: fractional 1x/2x, negative/positive display origins and clipped edges agree with actual normalized capture plans; no GUI, capture, or real data access.")
}
