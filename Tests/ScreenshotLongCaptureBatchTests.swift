import CoreFoundation
import CoreGraphics
import Foundation

@MainActor func runScreenshotLongCaptureBatchTests() async throws {
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw DataFailure.message(message) }
    }

    let stops: [(ScreenshotLongCaptureBatch.Step, ScreenshotLongCaptureBatch.Stop)] = [(.duplicate, .duplicate), (.review, .review)]
    for (last, expected) in stops {
        var attempts = 0
        let stop = try await ScreenshotLongCaptureBatch.run(operation: ScreenshotLongCaptureOperation(), uptime: { 0 },
            verifyStart: { try $0() }, next: { check in
                try check()
                attempts += 1
                return attempts == 1 ? .appended : last
            })
        try expect(stop == expected && attempts == 2, "Batch must stop at the first repeated frame or uncertain seam")
    }

    var attempts = 0
    let budget = try await ScreenshotLongCaptureBatch.run(operation: ScreenshotLongCaptureOperation(), uptime: { 0 },
        verifyStart: { try $0() }, next: { check in
            try check()
            attempts += 1
            return .appended
        })
    try expect(budget == .limit && attempts == 12, "Batch must cap the number of input attempts")

    var now = 0.0, posted = false
    let deadline = try await ScreenshotLongCaptureBatch.run(operation: ScreenshotLongCaptureOperation(), uptime: { now },
        verifyStart: { try $0() }, next: { check in
            now = 8
            try check()
            posted = true
            return .appended
        })
    try expect(deadline == .limit && !posted, "No input can be sent after the fixed batch deadline")

    let cancelled = ScreenshotLongCaptureOperation()
    do {
        _ = try await ScreenshotLongCaptureBatch.run(operation: cancelled, uptime: { 0 }, verifyStart: { try $0() },
            next: { check in
                cancelled.finish {}
                try check()
                posted = true
                return .appended
            })
        throw DataFailure.message("Cancelled capture unexpectedly reported success")
    } catch is CancellationError { try expect(!posted, "Invalidated operation must not post further input") }

    do {
        _ = try await ScreenshotLongCaptureBatch.run(operation: ScreenshotLongCaptureOperation(), uptime: { 0 },
            verifyStart: { _ in throw ScreenshotCaptureFailure.sourceMissing }, next: { _ in posted = true; return .appended })
        throw DataFailure.message("Failed viewport verification unexpectedly reported success")
    } catch ScreenshotCaptureFailure.sourceMissing { try expect(!posted, "Failing the starting viewport check must not scroll") }

    let rowBytes = 24 * 4, byteCount = rowBytes * 96
    var pixels = Data(repeating: 255, count: byteCount)
    func frame(_ data: Data) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 24, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ScreenshotCaptureFailure.emptyImage
        }
        return image
    }
    let previous = try frame(pixels), same = try frame(pixels)
    pixels[53] = 254
    let changed = try frame(pixels)
    try expect(ScreenshotLongScreenshotSession.samePixels(previous, same, previousBytes: byteCount, currentBytes: byteCount),
               "Identical synthetic viewports must pass the start comparison")
    try expect(!ScreenshotLongScreenshotSession.samePixels(previous, changed, previousBytes: byteCount, currentBytes: byteCount),
               "One changed pixel must cause the start comparison to fail")
    print("PASS bounded automatic long capture with synthetic input and pixels.")
}
