// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if SCROLL_PIXEL_EVENT_BUNDLE_TESTS
import Foundation
import CoreGraphics
import Darwin

// Event construction and field readback only. Never post, warp, read the pointer, or query an app/window.
private struct FixtureFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FixtureFailure(message: message) }
}

struct ScreenshotScrollPixelEventBundleTests {
    static func main() {
        do { try run() }
        catch {
            let result: [String: Any] = ["result": "IN_MEMORY_EVENT_CONSTRUCTION_FAILED",
                "error": String(describing: error), "eventsPosted": 0,
                "globalPointerReadsOrWarps": 0, "appOrWindowQueries": 0]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(1)
        }
    }

    private static func run() throws {
        var passed: [String] = []
        let anchor = CGPoint(x: 651, y: 663.5)
        // Earlier prime/PID fixtures remain archived unchanged. This fixture constructs a single wheel;
        // it never posts to WindowServer and cannot validate source/pointer guards or delivery.
        guard let bundle = ScreenshotScrollPixelEventBundle(anchor: anchor, pixels: 1) else {
            throw FixtureFailure(message: "Expected single bounded wheel construction")
        }
        try expect(bundle.wheel.type == .scrollWheel && bundle.wheel.location == anchor && bundle.wheel.flags.isEmpty,
                   "Wheel type, original anchor or empty flags changed")
        try expect(bundle.wheel.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -1 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0 &&
                   bundle.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0,
                   "Wheel must retain one negative vertical pixel with no other axes")
        passed.append("singleBoundedWheelConstructed")
        for pixels in [Int32(0), -1, 241, .max, .min] {
            try expect(ScreenshotScrollPixelEventBundle(anchor: anchor, pixels: pixels) == nil,
                       "Out-of-budget pixel amount accepted: \(pixels)")
            passed.append("invalidPixels_\(pixels)")
        }
        let invalid: [(String, CGPoint)] = [
            ("nanX", CGPoint(x: CGFloat.nan, y: 1)),
            ("nanY", CGPoint(x: 1, y: CGFloat.nan)),
            ("infiniteX", CGPoint(x: CGFloat.infinity, y: 1)),
            ("infiniteY", CGPoint(x: 1, y: CGFloat.infinity)),
            ("negativeInfiniteX", CGPoint(x: -CGFloat.infinity, y: 1)),
            ("negativeInfiniteY", CGPoint(x: 1, y: -CGFloat.infinity))
        ]
        for (name, point) in invalid {
            try expect(ScreenshotScrollPixelEventBundle(anchor: point, pixels: 100) == nil,
                       "Nonfinite anchor accepted: \(name)")
            passed.append(name)
        }
        let result: [String: Any] = [
            "result": "MEMORY_SINGLE_PIXEL_WHEEL_CONSTRUCTION_ONLY",
            "constructionChecks": "PASS", "deliveryProven": false, "wheelCarriesWindowIDClaim": false,
            "caseCount": passed.count, "cases": passed,
            "eventsPosted": 0, "globalPointerReadsOrWarps": 0, "appOrWindowQueries": 0,
            "earlierRawFailure": "Acceptance-2026-10-28/WindowPrimeConstructionBlocker.noindex/first-failed-raw-output.json",
            "scope": "Single wheel memory construction and parameter rejection only. No window metadata, prime, post, pointer read, WindowServer delivery or live scrolling claim. Caller must retain source/pointer guards"
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
#endif
