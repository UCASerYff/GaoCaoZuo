// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if LONG_CAPTURE_WINDOW_CROP_TESTS
import Foundation
import CoreGraphics
import Darwin

// Pure geometry, arithmetic and synthetic in-memory bitmaps. ScreenshotCaptureService is never instantiated.
// No screen/window enumeration, permission check, event, application, file image or audio is used.
private struct WindowCropFixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func cropExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw WindowCropFixtureFailure(description: message) }
}

private enum ExpectedCropFailure { case invalidRegion, budgetExceeded }

private func cropReject(_ expected: ExpectedCropFailure, _ body: () throws -> Void) throws {
    do {
        try body()
        throw WindowCropFixtureFailure(description: "Expected \(expected), but operation succeeded")
    } catch let failure as ScreenshotCaptureFailure {
        switch (expected, failure) {
        case (.invalidRegion, .invalidRegion), (.budgetExceeded, .budgetExceeded): return
        default: throw WindowCropFixtureFailure(description: "Wrong rejection: \(failure)")
        }
    }
}

private final class ParentReleaseProbe {
    var releases = 0
}

private let releasePatternData: CGDataProviderReleaseDataCallback = { info, data, _ in
    if let info {
        let probe = Unmanaged<ParentReleaseProbe>.fromOpaque(info).takeRetainedValue()
        probe.releases += 1
    }
    UnsafeMutableRawPointer(mutating: data).deallocate()
}

/// The first stored row is y=0. Padding is deliberate: full parent cost is 40*6=240, not 8*6*4.
private func patternParent(_ probe: ParentReleaseProbe) throws -> CGImage {
    let width = 8, height = 6, stride = 40, count = stride * height
    let allocation = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    let bytes = allocation.assumingMemoryBound(to: UInt8.self)
    bytes.initialize(repeating: 0xEE, count: count)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            bytes[offset] = UInt8(y * 30 + x * 3 + 1)
            bytes[offset + 1] = UInt8(x * 17 + 5)
            bytes[offset + 2] = UInt8(y * 11 + 7)
            bytes[offset + 3] = 255
        }
    }
    let retainedProbe = Unmanaged.passRetained(probe).toOpaque()
    guard let provider = CGDataProvider(dataInfo: retainedProbe, data: allocation,
                                        size: count, releaseData: releasePatternData) else {
        Unmanaged<ParentReleaseProbe>.fromOpaque(retainedProbe).release()
        allocation.deallocate()
        throw WindowCropFixtureFailure(description: "Synthetic data provider creation failed")
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: stride, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                .union(.byteOrder32Big),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw WindowCropFixtureFailure(description: "Synthetic RGBA image creation failed")
    }
    return image
}

/// Read the returned provider directly, rather than rendering through a second potentially flipping context.
private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    try cropExpect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32
                   && image.alphaInfo == .premultipliedLast, "Unexpected output RGBA format")
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
        throw WindowCropFixtureFailure(description: "Output data provider is unavailable")
    }
    defer { withExtendedLifetime(data) {} }
    try cropExpect(CFDataGetLength(data) >= image.bytesPerRow * image.height, "Truncated output provider")
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    try cropExpect(order == .byteOrderDefault || order == .byteOrder32Big || order == .byteOrder32Little,
                   "Unsupported output component byte order")
    var result: [UInt8] = []
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * 4
            if order == .byteOrder32Little {
                result.append(contentsOf: [bytes[offset + 3], bytes[offset + 2], bytes[offset + 1], bytes[offset]])
            } else {
                result.append(contentsOf: [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]])
            }
        }
    }
    return result
}

struct ScreenshotLongCaptureWindowCropTests {
    static func main() {
        var passed: [String] = []
        var current = "setup"
        func check(_ name: String, _ body: () throws -> Void) throws {
            current = name
            try body()
            passed.append(name)
            print("PASS \(name)")
        }
        do {
            let window = CGRect(x: 160, y: 200, width: 1000, height: 792)
            let roi = CGRect(x: 182, y: 357, width: 938, height: 613)
            let size = CGSize(width: 2000, height: 1584)
            try check("actualPublicSampleROIHasKnownPixels") {
                let pixels = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: window, capturedBounds: window,
                    desktopRegion: roi, scale: 2, imageSize: size)
                try cropExpect(pixels == CGRect(x: 44, y: 314, width: 1876, height: 1226),
                               "Known public sample ROI must be 44,314,1876,1226")
            }
            let negative = CGRect(x: -160.5, y: -200.25, width: 10.25, height: 8.75)
            try check("negativeDesktopOriginAndFractionalEdgesRoundOutward") {
                let pixels = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: negative, capturedBounds: negative,
                    desktopRegion: CGRect(x: -160.25, y: -199.5, width: 3.125, height: 2.125),
                    scale: 2, imageSize: CGSize(width: 21, height: 18))
                try cropExpect(pixels == CGRect(x: 0, y: 1, width: 7, height: 5),
                               "Fractional leading and trailing edges must retain their edge pixels")
            }
            try check("fullFractionalWindowMatchesCompleteCeiledExtent") {
                let pixels = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: negative, capturedBounds: negative,
                    desktopRegion: negative, scale: 2, imageSize: CGSize(width: 21, height: 18))
                try cropExpect(pixels == CGRect(x: 0, y: 0, width: 21, height: 18), "Full extent was clipped or rescaled")
            }
            for (name, scale) in [("zeroScale", CGFloat(0)), ("negativeScale", -2),
                                  ("nanScale", .nan), ("infiniteScale", .infinity)] {
                try check(name + "Refused") {
                    try cropReject(.invalidRegion) {
                        _ = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: window, capturedBounds: window,
                            desktopRegion: roi, scale: scale, imageSize: size)
                    }
                }
            }
            for (name, invalidROI) in [
                ("leftOutside", CGRect(x: 159.75, y: 357, width: 10, height: 10)),
                ("rightOutside", CGRect(x: 1150, y: 357, width: 10.25, height: 10)),
                ("bottomOutside", CGRect(x: 182, y: 982, width: 10, height: 10.25)),
                ("emptyROI", CGRect(x: 182, y: 357, width: 0, height: 10)),
                ("nonfiniteROI", CGRect(x: CGFloat.nan, y: 357, width: 10, height: 10))
            ] {
                try check(name + "Refused") {
                    try cropReject(.invalidRegion) {
                        _ = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: window, capturedBounds: window,
                            desktopRegion: invalidROI, scale: 2, imageSize: size)
                    }
                }
            }
            for (name, captured) in [("movedWindow", window.offsetBy(dx: 0.5, dy: 0)),
                                     ("resizedWindow", CGRect(x: 160, y: 200, width: 1001, height: 792))] {
                try check(name + "Refused") {
                    try cropReject(.invalidRegion) {
                        _ = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: window, capturedBounds: captured,
                            desktopRegion: roi, scale: 2, imageSize: size)
                    }
                }
            }
            for (name, imageSize) in [("shortImage", CGSize(width: 2000, height: 1583)),
                                      ("extraImage", CGSize(width: 2001, height: 1584))] {
                try check(name + "Refused") {
                    try cropReject(.invalidRegion) {
                        _ = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: window, capturedBounds: window,
                            desktopRegion: roi, scale: 2, imageSize: imageSize)
                    }
                }
            }
            try check("invalidWindowFrameRefused") {
                let invalid = CGRect(x: 0, y: 0, width: 1, height: 10)
                try cropReject(.invalidRegion) {
                    _ = try ScreenshotLongCaptureWindowCrop.pixelRect(windowFrame: invalid, capturedBounds: invalid,
                        desktopRegion: invalid, scale: 2, imageSize: CGSize(width: 2, height: 20))
                }
            }
            try check("actualSampleBudgetIncludesFullWindowAndTwoROICopies") {
                let bytes = try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: 12_672_000,
                    width: 1876, height: 1226, maximumPixels: 2_299_976, maximumBytes: 31_071_808)
                try cropExpect(bytes == 31_071_808, "Expected complete 12,672,000B parent plus two 9,199,904B ROI copies")
            }
            try check("paddedParentAndExactBudgetAccepted") {
                try cropExpect(try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: 240,
                    width: 3, height: 2, maximumPixels: 6, maximumBytes: 288) == 288,
                    "Exact parent+2ROI budget must be accepted")
            }
            try check("oneByteBelowWorkingBudgetRefused") {
                try cropReject(.budgetExceeded) {
                    _ = try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: 240,
                        width: 3, height: 2, maximumPixels: 6, maximumBytes: 287)
                }
            }
            try check("onePixelBelowROIBudgetRefused") {
                try cropReject(.budgetExceeded) {
                    _ = try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: 240,
                        width: 3, height: 2, maximumPixels: 5, maximumBytes: 288)
                }
            }
            for (name, parent, width, height, maximumPixels, maximumBytes) in [
                ("zeroParent", 0, 3, 2, 6, 288),
                ("negativeParent", -1, 3, 2, 6, 288),
                ("parentOverBudget", 289, 3, 2, 6, 288),
                ("pixelProductOverflow", 1, Int.max, 2, Int.max, Int.max),
                ("rgbaProductOverflow", 1, Int.max / 4 + 1, 1, Int.max, Int.max),
                ("twoCopiesOverflow", 1, Int.max / 4, 1, Int.max, Int.max),
                ("zeroDimension", 240, 0, 2, 6, 288),
                ("negativeDimension", 240, 3, -2, 6, 288)
            ] {
                try check(name + "Refused") {
                    try cropReject(.budgetExceeded) {
                        _ = try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: parent,
                            width: width, height: height, maximumPixels: maximumPixels, maximumBytes: maximumBytes)
                    }
                }
            }
            try check("largestRepresentableTotalAcceptedWithoutOverflow") {
                try cropExpect(try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: Int.max - 8,
                    width: 1, height: 1, maximumPixels: 1, maximumBytes: Int.max) == Int.max,
                    "Representable boundary must not overflow or be unnecessarily rejected")
            }
            try check("oneBytePastRepresentableTotalRefused") {
                try cropReject(.budgetExceeded) {
                    _ = try ScreenshotLongCaptureWindowCrop.copyWorkingBytes(parentBytes: Int.max - 7,
                        width: 1, height: 1, maximumPixels: 1, maximumBytes: Int.max)
                }
            }
            try check("remainingBytesPreservesOneByteOfPositiveBudget") {
                try cropExpect(try ScreenshotLongCaptureWindowCrop.remainingBytes(maximum: 100, retained: [60, 39]) == 1,
                               "Retained images must be subtracted from the same memory budget")
            }
            try check("fullyConsumedOrNegativeRetainedBudgetRefused") {
                try cropReject(.budgetExceeded) { _ = try ScreenshotLongCaptureWindowCrop.remainingBytes(maximum: 100, retained: [60, 40]) }
                try cropReject(.budgetExceeded) { _ = try ScreenshotLongCaptureWindowCrop.remainingBytes(maximum: 100, retained: [-1]) }
            }

            let controlProbe = ParentReleaseProbe()
            var retainingCrop: CGImage? = try autoreleasepool {
                let parent = try patternParent(controlProbe)
                guard let image = parent.cropping(to: CGRect(x: 2, y: 1, width: 3, height: 2)) else {
                    throw WindowCropFixtureFailure(description: "Synthetic control crop failed")
                }
                return image
            }
            try check("croppingControlRetainsParentUntilCropReleased") {
                try withExtendedLifetime(retainingCrop) {
                    try cropExpect(controlProbe.releases == 0, "The retaining-crop control failed to exercise parent ownership")
                }
                autoreleasepool { retainingCrop = nil }
                try cropExpect(controlProbe.releases == 1, "Control provider must release exactly once after its crop")
            }

            let copyProbe = ParentReleaseProbe()
            let owned = try autoreleasepool {
                let parent = try patternParent(copyProbe)
                try cropExpect(try ScreenshotLongCaptureWindowCrop.imageBytes(parent) == 240, "Parent row padding was omitted from cost")
                return try ScreenshotLongCaptureWindowCrop.copy(parent,
                    windowFrame: CGRect(x: -10, y: 4, width: 8, height: 6),
                    capturedBounds: CGRect(x: -10, y: 4, width: 8, height: 6),
                    desktopRegion: CGRect(x: -8, y: 5, width: 3, height: 2),
                    scale: 1, maximumPixels: 6, maximumBytes: 288)
            }
            try check("independentCopyReleasesParentBeforeOutputIsRead") {
                try cropExpect(copyProbe.releases == 1, "Output retained the full parent data provider")
                try cropExpect(owned.image.width == 3 && owned.image.height == 2 && owned.workingBytes == 288,
                               "Copy returned wrong extent or full working cost")
            }
            try check("RGBAValuesAndRowDirectionSurviveParentDestruction") {
                // Expected source columns 2...4, rows 1...2, written independently of crop geometry math.
                let expected: [UInt8] = [
                    37, 39, 18, 255, 40, 56, 18, 255, 43, 73, 18, 255,
                    67, 39, 29, 255, 70, 56, 29, 255, 73, 73, 29, 255
                ]
                try cropExpect(try rgbaPixels(owned.image) == expected,
                               "Synthetic crop changed pixels, horizontal order or vertical row direction")
                try cropExpect(copyProbe.releases == 1, "Reading independent pixels unexpectedly reacquired its parent")
            }
            let summary: [String: Any] = ["passed": passed.count, "cases": passed,
                "fixtures": "pure geometry/arithmetic and synthetic in-memory RGBA only",
                "screenCapturePerformed": false, "applicationCreatedOrLaunched": false, "audioPerformed": false]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let message = "FAIL \(current): \(error); passed=\(passed.count)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }
}
#endif
