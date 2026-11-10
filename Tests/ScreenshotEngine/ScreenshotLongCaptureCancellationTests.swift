// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if LONG_CAPTURE_CANCELLATION_TESTS
import Foundation
import CoreGraphics

private struct LongCancelTestFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func longCancelExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw LongCancelTestFailure(message) }
}

/// A deliberately non-cooperative producer: cancellation does not resume it or discard its result.
@MainActor
private final class LongCancelGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
    func awaitSuspension() async throws {
        for _ in 0..<10_000 {
            if isWaiting { return }
            await Task.yield()
        }
        throw LongCancelTestFailure("Producer did not reach the expected suspension")
    }
}

private let longCancelBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
private let longCancelRegion = CGRect(x: 100, y: 100, width: 300, height: 200)
private let longCancelWindow = ScreenshotCaptureWindow(id: 101, title: "Synthetic", applicationName: "Synthetic", processID: 42,
                                            frame: longCancelBounds, isOnScreen: true)
private let longCancelCatalog = ScreenshotCaptureCatalog(displays: [ScreenshotCaptureDisplay(id: 1, name: "Synthetic", frame: longCancelBounds, scale: 1, rotation: 0)],
                                               windows: [longCancelWindow])

@MainActor
private func testPreparationCancellation(at blockedStage: String, invalidateOwner: Bool) async throws {
    let operation = ScreenshotLongCaptureOperation(), gate = LongCancelGate()
    var current = true, calls: [String] = [], cleanupCount = 0, readyCount = 0, rejected = false
    let task = Task { @MainActor in
        defer { operation.preparationFinished() }
        do {
            _ = try await ScreenshotLongCapturePreparation.run(operation: operation, isCurrent: { current },
                refreshCatalog: {
                    calls.append("catalog"); if blockedStage == "catalog" { await gate.wait() }
                    return longCancelCatalog
                },
                selectWindow: { _ in
                    calls.append("window"); if blockedStage == "window" { await gate.wait() }
                    return longCancelWindow.id
                },
                willSelectRegion: { calls.append("region-status") },
                selectRegion: {
                    calls.append("region"); if blockedStage == "region" { await gate.wait() }
                    return longCancelRegion
                },
                activate: { _ in calls.append("activate") },
                settle: {
                    calls.append("settle"); if blockedStage == "settle" { await gate.wait() }
                })
            readyCount += 1
        } catch is CancellationError { rejected = true }
        catch {}
    }
    operation.setPreparationTask(task)
    try await gate.awaitSuspension()
    let callsBeforeCancellation = calls
    if invalidateOwner {
        try longCancelExpect(operation.finish { cleanupCount += 1 }, "First cancellation was ignored")
    } else {
        // A replaced controller generation must reject a producer even without Task cancellation.
        current = false
    }
    let nextOperation = ScreenshotLongCaptureOperation()
    gate.release()
    await task.value
    try longCancelExpect(rejected && readyCount == 0, "Late \(blockedStage) result reached ready")
    try longCancelExpect(calls == callsBeforeCancellation, "Late \(blockedStage) result opened a later selector or activated a target")
    try longCancelExpect(nextOperation.isActive, "Old operation ended its successor")
    if invalidateOwner {
        var successorBusy = true
        try longCancelExpect(!operation.finish { successorBusy = false; cleanupCount += 1 }, "Late callback was accepted")
        try longCancelExpect(successorBusy && cleanupCount == 1, "Late cleanup changed a newer operation")
    }
    print("PASS preparation \(blockedStage): late producer rejected (\(invalidateOwner ? "cancelled owner" : "replaced controller generation")); no later selector/status/activation/ready.")
}

@MainActor
private func testSessionLifetimeAndCancellation() async throws {
    let operation = ScreenshotLongCaptureOperation()
    let task = Task { @MainActor in
        defer { operation.preparationFinished() }
        _ = try? await ScreenshotLongCapturePreparation.run(operation: operation,
            refreshCatalog: { longCancelCatalog }, selectWindow: { _ in longCancelWindow.id },
            willSelectRegion: {}, selectRegion: { longCancelRegion }, activate: { _ in }, settle: {})
    }
    operation.setPreparationTask(task)
    await task.value
    try longCancelExpect(operation.isActive, "Preparation return removed the live-session cancellation owner")

    let session = ScreenshotLongScreenshotSession(), gate = LongCancelGate()
    let width = 16, height = 64
    let pixels = Data(repeating: 255, count: width * height * 4)
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScreenshotCaptureFailure.emptyImage }
    let frameTask = Task { @MainActor () -> Bool in
        do {
            _ = try await session.captureNext(capturing: { await gate.wait(); return image })
            return false
        } catch is CancellationError { return true }
        catch ScreenshotCaptureFailure.cancelled { return true }
        catch { return false }
    }
    try await gate.awaitSuspension()
    var selectorCancelled = 0, panelCancelled = 0
    try longCancelExpect(operation.finish {
        selectorCancelled += 1; panelCancelled += 1; frameTask.cancel(); session.cancel()
    }, "Live-session cancellation was ignored")
    gate.release()
    let frameRejected = await frameTask.value
    try longCancelExpect(!operation.isActive && selectorCancelled == 1 && panelCancelled == 1,
                         "Live-session cleanup was not dispatched once")
    try longCancelExpect(frameRejected && session.state == .cancelled && session.capturedFrameCount == 0 && session.pendingSeam == nil,
                         "Cancelled in-memory frame producer committed a result")
    try longCancelExpect(!operation.finish { panelCancelled += 1 }, "Repeated session callback was accepted")
    print("PASS live session: preparation completion keeps cancellation active; cancellation dispatches cleanup once; late frame cannot commit.")
}

@MainActor
private func testPreparationTaskIsCancelled() async throws {
    let operation = ScreenshotLongCaptureOperation(), gate = LongCancelGate()
    var sawCancellation = false
    let task = Task { @MainActor in
        await gate.wait()
        sawCancellation = Task.isCancelled
    }
    operation.setPreparationTask(task)
    try await gate.awaitSuspension()
    operation.finish {}
    gate.release(); await task.value
    try longCancelExpect(sawCancellation, "Owner failed to cancel its stored preparation task")
    print("PASS owner-held preparation task receives cancellation.")
}

struct ScreenshotLongCaptureCancellationTestMain {
    @MainActor static func main() async {
        do {
            for stage in ["catalog", "window", "region", "settle"] {
                try await testPreparationCancellation(at: stage, invalidateOwner: true)
                try await testPreparationCancellation(at: stage, invalidateOwner: false)
            }
            try await testSessionLifetimeAndCancellation()
            try await testPreparationTaskIsCancelled()
            print("PASS all focused long-capture cancellation checks; no UI, live AX, screen capture or user data access.")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
#endif
