// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if LONG_CAPTURE_BACKING_BUDGET_TESTS
import Foundation
import CoreGraphics
import Darwin

// Four in-memory regressions only. A targetless session never queries windows, AX, permissions or devices.
private struct BackingBudgetFixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func backingExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw BackingBudgetFixtureFailure(description: message) }
}

private func rejectBackingBudget(_ body: () throws -> Void) throws {
    do {
        try body()
        throw BackingBudgetFixtureFailure(description: "Expected memory-budget rejection")
    } catch ScreenshotCaptureFailure.budgetExceeded { }
}

/// Complete parent is 8*100*4=3200B. Its 68-row top crop retains that provider, despite exposing 1024B.
private func backingFrame(offset: Int = 0, periodic: Bool = false) throws -> CGImage {
    let width = 8, height = 100
    var bytes = [UInt8](repeating: 0, count: 3200)
    for y in 0..<height {
        for x in 0..<width {
            let row = periodic ? (y + offset) % 16 : y + offset
            let index = (y * width + x) * 4
            if periodic {
                let value = UInt8(row * 13)
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
            } else {
                var value = UInt64(row + 1) &* 0x9E3779B97F4A7C15 &+ UInt64(x + 1) &* 0xBF58476D1CE4E5B9
                value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
                value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
                value ^= value >> 31
                bytes[index] = UInt8(truncatingIfNeeded: value)
                bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
            bytes[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: 32, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw BackingBudgetFixtureFailure(description: "Synthetic parent creation failed")
    }
    return image
}

private func backingBudget(_ maximumBytes: Int) -> ScreenshotScrollCaptureBudget {
    var budget = ScreenshotScrollCaptureBudget()
    budget.fixedTopPixels = 68
    budget.fixedBottomPixels = 0
    budget.maximumMemoryBytes = maximumBytes
    // Keep unrelated limits well above these four tiny frames.
    budget.maximumPixels = 100_000
    budget.maximumHeight = 400
    budget.maximumFrames = 4
    return budget
}

@MainActor
struct ScreenshotLongCaptureBackingBudgetTests {
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
            let first = try backingFrame()
            guard let normalized = first.cropping(to: CGRect(x: 0, y: 68, width: 8, height: 32)) else {
                throw BackingBudgetFixtureFailure(description: "Synthetic normalization control failed")
            }
            try backingExpect(try ScreenshotLongCaptureWindowCrop.imageBytes(first) == 3200,
                              "Fixture parent must really expose 3200 backing bytes")
            try backingExpect(try ScreenshotLongCaptureWindowCrop.imageBytes(normalized) == 1024,
                              "Fixture normalized view must expose only 1024 bytes")

            try check("fullBackingRejectsFirstFrameAt4500BeforeAppend") {
                let session = ScreenshotLongScreenshotSession(budget: backingBudget(4500))
                try rejectBackingBudget { _ = try session.addFrame(first) }
                try backingExpect(session.capturedFrameCount == 0 && session.outputHeight == 0
                                  && session.pendingSeam == nil && session.seams.isEmpty,
                                  "Rejected first frame must leave no appended or pending frame")
            }
            try check("firstFrameAcceptsExact10624FullBackingPeak") {
                let session = ScreenshotLongScreenshotSession(budget: backingBudget(10_624))
                let seam = try session.addFrame(first)
                try backingExpect(seam == nil && session.capturedFrameCount == 1 && session.outputHeight == 32,
                                  "Exact first-frame memory boundary must be accepted")
                try backingExpect(session.estimatedPeakMemoryBytes == 10_624,
                                  "Known peak is three complete 3200B working parents plus 1024B output")
            }
            try check("secondNonduplicateRefusedAt11000KeepsFirstFrame") {
                let session = ScreenshotLongScreenshotSession(budget: backingBudget(11_000))
                _ = try session.addFrame(first)
                let second = try backingFrame(offset: 10)
                try rejectBackingBudget { _ = try session.addFrame(second) }
                try backingExpect(session.capturedFrameCount == 1 && session.outputHeight == 32
                                  && session.pendingSeam == nil && session.seams.isEmpty,
                                  "Refused second frame must preserve the original first frame")
                try backingExpect(session.estimatedPeakMemoryBytes == 10_624,
                                  "A rejected addition must not replace the prior successful peak")
            }
            try check("pendingAcceptanceTransfersFullBackingAndRejectsThirdAt17500") {
                let session = ScreenshotLongScreenshotSession(budget: backingBudget(17_500))
                _ = try session.addFrame(backingFrame(periodic: true))
                let proposed = try session.addFrame(backingFrame(offset: 6, periodic: true))
                try backingExpect(proposed?.duplicate == false && session.pendingSeam != nil
                                  && session.state == .awaitingSeam && session.capturedFrameCount == 1
                                  && session.pendingFrameHeight == 32,
                                  "Periodic nonduplicate fixture must actually take the pending path")
                try session.acceptPending(overlapPixels: 0)
                try backingExpect(session.pendingSeam == nil && session.pendingFrameHeight == nil
                                  && session.capturedFrameCount == 2 && session.outputHeight == 64
                                  && session.seams.count == 1,
                                  "Accepted zero-overlap pending frame must become the second segment")
                try backingExpect(session.estimatedPeakMemoryBytes == 14_848,
                                  "Known acceptance peak is 3200 retained + 3*3200 working + 2048 output")
                // 17,500 distinguishes correct transfer from charging the second segment only 1024B:
                // correct retained 6400 + working 9600 + output >=2080 exceeds 17,500;
                // incorrect retained 4224 + working 9600 + output <=3072 stays below it (16,896).
                try rejectBackingBudget {
                    _ = try session.addFrame(backingFrame(offset: 10, periodic: true))
                }
                try backingExpect(session.capturedFrameCount == 2 && session.outputHeight == 64
                                  && session.pendingSeam == nil && session.pendingFrameHeight == nil
                                  && session.seams.count == 1 && session.estimatedPeakMemoryBytes == 14_848,
                                  "Third-frame budget refusal must retain exactly the accepted two-frame session")
            }
            let summary: [String: Any] = ["passed": passed.count, "cases": passed,
                "fixtures": "four targetless in-memory backing-budget regressions",
                "applicationCreatedOrLaunched": false, "screenCapturePerformed": false,
                "AXOrInputPerformed": false, "audioPerformed": false]
            let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("FAIL \(current): \(error); passed=\(passed.count)\n".utf8))
            Darwin.exit(1)
        }
    }
}
#endif
