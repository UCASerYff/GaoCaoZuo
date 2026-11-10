// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if SCROLL_TARGET_GUARD_TESTS
import Foundation
import CoreGraphics

private struct ScrollGuardTestFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func scrollExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ScrollGuardTestFailure(message) }
}

private let scrollPID: pid_t = 42
private let scrollID: CGWindowID = 101
private let scrollBounds = CGRect(x: -180, y: 70, width: 1200, height: 800)
private let scrollROI = CGRect(x: 400, y: 200, width: 400, height: 300)
private let scrollTarget = ScreenshotScrollTargetIdentity(processID: scrollPID, windowID: scrollID, frame: scrollBounds, scrollRegion: scrollROI)

private func scrollWindow(id: CGWindowID = scrollID, pid: pid_t = scrollPID, frame: CGRect? = scrollBounds,
                          alpha: Double? = 1, layer: Int? = 0) -> ScreenshotScrollWindowMetadata {
    ScreenshotScrollWindowMetadata(windowID: id, processID: pid, frame: frame, layer: layer, alpha: alpha,
                         bundleID: "com.example.synthetic", ownerName: "Synthetic owner")
}

private func scrollAX(token: Int = 1, pid: pid_t = scrollPID, frame: CGRect = scrollBounds) -> ScreenshotScrollFocusEvidence {
    .accessibility(processID: pid, frame: frame, identity: ScreenshotScrollFocusIdentity(testToken: token))
}

private func scrollSnapshot(windows: [ScreenshotScrollWindowMetadata] = [scrollWindow()], pid: pid_t? = scrollPID,
                            focus: ScreenshotScrollFocusEvidence = .accessibilityUnavailable) -> ScreenshotScrollTargetSnapshot {
    ScreenshotScrollTargetSnapshot(frontmostPID: pid, windows: windows, focus: focus)
}

private func expectScrollRejection(_ reason: ScreenshotScrollTargetFailureReason, guard targetGuard: ScreenshotScrollTargetGuard,
                                   snapshot: ScreenshotScrollTargetSnapshot, _ message: String) throws {
    do {
        _ = try targetGuard.validate(snapshot)
        throw ScrollGuardTestFailure("Accepted unsafe snapshot: \(message)")
    } catch let failure as ScreenshotScrollTargetValidationFailure {
        try scrollExpect(failure.reason == reason, "Wrong rejection for \(message): \(failure.reason)")
    }
}

@MainActor
private final class ScriptedScrollProbe: ScreenshotScrollTargetProbing {
    private let snapshots: [ScreenshotScrollTargetSnapshot]
    private(set) var reads = 0
    init(_ snapshots: [ScreenshotScrollTargetSnapshot]) { self.snapshots = snapshots }
    func sample(target: ScreenshotScrollTargetIdentity) -> ScreenshotScrollTargetSnapshot {
        guard reads < snapshots.count else { preconditionFailure("Unexpected live-probe fallback or extra metadata query") }
        defer { reads += 1 }
        return snapshots[reads]
    }
}

/// Generates a bitmap in memory; never reads a file, screen, AX tree, window list or application state.
private func scrollTestImage(offset: Int = 0) throws -> CGImage {
    let width = 32, height = 96
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4, row = y + offset
            pixels[index] = UInt8(truncatingIfNeeded: row * 37 + x * 11)
            pixels[index + 1] = UInt8(truncatingIfNeeded: row * 13 + x * 7)
            pixels[index + 2] = UInt8(truncatingIfNeeded: row * 23 + x * 19)
            pixels[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScreenshotCaptureFailure.emptyImage }
    return image
}

private func scrollImageBytes(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard rendered else { throw ScreenshotCaptureFailure.emptyImage }
    return pixels
}

private func runScrollMetadataTests() throws {
    let transparent = scrollWindow(id: 90, alpha: 0)
    let empty = scrollWindow(id: 91, frame: CGRect(x: 0, y: 0, width: 0, height: 0))
    let tiny = scrollWindow(id: 92, frame: CGRect(x: 0, y: 0, width: 1, height: 300))
    let unknownLayer = scrollWindow(id: 93, layer: nil)
    let badAlpha = scrollWindow(id: 94, alpha: .nan)
    let otherPID = scrollWindow(id: 95, pid: 99)
    let polluted = [transparent, empty, tiny, unknownLayer, badAlpha, otherPID, scrollWindow()]
    try scrollExpect(try ScreenshotScrollTargetGuard(target: scrollTarget).validate(scrollSnapshot(windows: polluted)) == scrollBounds,
                     "Transparent/empty/invalid entries ahead of the selected window caused a false rejection")
    try scrollExpect(!ScreenshotCaptureWindowEligibility.validFrame(CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)), "Nonfinite bounds accepted")
    try scrollExpect(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 1, processID: scrollPID, bundleID: "com.apple.dock", ownerName: "Dock", frame: scrollBounds), "Desktop owner accepted")
    try scrollExpect(!ScreenshotCaptureWindowEligibility.allows(layer: 0, alpha: 1, processID: scrollPID, bundleID: nil, ownerName: "Synthetic", frame: nil), "Missing bounds accepted")

    let otherBounds = CGRect(x: 1100, y: 70, width: 900, height: 700)
    let another = scrollWindow(id: 202, frame: otherBounds)
    try expectScrollRejection(.focusAmbiguous, guard: ScreenshotScrollTargetGuard(target: scrollTarget),
                             snapshot: scrollSnapshot(windows: [scrollWindow(), another]), "manual same-PID second normal window")
    try expectScrollRejection(.focusChanged, guard: ScreenshotScrollTargetGuard(target: scrollTarget),
                             snapshot: scrollSnapshot(windows: [scrollWindow(), another], focus: scrollAX(token: 2, frame: otherBounds)), "AX focus belongs to another same-PID window")
    try scrollExpect(try ScreenshotScrollTargetGuard(target: scrollTarget).validate(scrollSnapshot(windows: [another, scrollWindow()], focus: scrollAX())) == scrollBounds,
                     "A uniquely mapped actual focused target was replaced by list order")

    let ambiguityGuard = ScreenshotScrollTargetGuard(target: scrollTarget)
    try expectScrollRejection(.focusAmbiguous, guard: ambiguityGuard,
                             snapshot: scrollSnapshot(windows: [scrollWindow(), scrollWindow(id: 202)], focus: scrollAX(token: 9)), "same-bounds AX mapping ambiguity")
    _ = try ambiguityGuard.validate(scrollSnapshot(focus: scrollAX(token: 10)))
    try expectScrollRejection(.focusChanged, guard: ambiguityGuard, snapshot: scrollSnapshot(focus: scrollAX(token: 11)), "same-geometry changed AX identity")
    try expectScrollRejection(.focusQueryFailed, guard: ambiguityGuard, snapshot: scrollSnapshot(focus: .accessibilityQueryFailed), "AX query failure after binding")
    try expectScrollRejection(.focusUnavailable, guard: ambiguityGuard, snapshot: scrollSnapshot(), "revoked AX permission must not silently downgrade")
    try expectScrollRejection(.focusQueryFailed, guard: ScreenshotScrollTargetGuard(target: scrollTarget),
                             snapshot: scrollSnapshot(focus: .accessibilityQueryFailed), "initial AX query failure")

    try expectScrollRejection(.geometryChanged, guard: ScreenshotScrollTargetGuard(target: scrollTarget),
                             snapshot: scrollSnapshot(windows: [scrollWindow(frame: scrollBounds.offsetBy(dx: 0.25, dy: 0))]), "subpoint movement must not pass the AX bridge tolerance")
    try expectScrollRejection(.selectedWindowUnavailable, guard: ScreenshotScrollTargetGuard(target: scrollTarget), snapshot: scrollSnapshot(windows: []), "selected window disappearance")
    try expectScrollRejection(.selectedWindowUnavailable, guard: ScreenshotScrollTargetGuard(target: scrollTarget),
                             snapshot: scrollSnapshot(windows: [scrollWindow(pid: 99)]), "same ID under a different PID")
    let outside = ScreenshotScrollTargetIdentity(processID: scrollPID, windowID: scrollID, frame: scrollBounds,
                                       scrollRegion: CGRect(x: scrollBounds.maxX - 1, y: 200, width: 10, height: 10))
    try expectScrollRejection(.invalidRegion, guard: ScreenshotScrollTargetGuard(target: outside), snapshot: scrollSnapshot(), "ROI extends outside selected bounds")
    let invalidROI = ScreenshotScrollTargetIdentity(processID: scrollPID, windowID: scrollID, frame: scrollBounds,
                                          scrollRegion: CGRect(x: 0, y: 100, width: 0, height: 10))
    try expectScrollRejection(.invalidRegion, guard: ScreenshotScrollTargetGuard(target: invalidROI), snapshot: scrollSnapshot(), "empty ROI")
    try expectScrollRejection(.foregroundChanged, guard: ScreenshotScrollTargetGuard(target: scrollTarget), snapshot: scrollSnapshot(pid: 99, focus: scrollAX()), "foreign foreground is never exempt")
    var unsettled = scrollSnapshot(focus: scrollAX()); unsettled.foregroundStayedConsistent = false
    try expectScrollRejection(.foregroundChanged, guard: ScreenshotScrollTargetGuard(target: scrollTarget), snapshot: unsettled, "foreground changed during probe")
    print("PASS metadata: shared eligibility, transparent/empty entries, exact PID/ID/bounds/ROI, strict foreground, unique AX geometry, identity binding, query/revocation failures and manual ambiguity.")
}

@MainActor
private func runScrollTransactionTests() async throws {
    let first = try scrollTestImage(), next = try scrollTestImage(offset: 48)
    let control = ScreenshotLongScreenshotSession(); _ = try control.addFrame(first)
    let retainedBytes = try scrollImageBytes(control.finish())
    let valid = scrollSnapshot(focus: scrollAX())
    let changed = scrollSnapshot(windows: [scrollWindow(), scrollWindow(id: 202, frame: CGRect(x: 1100, y: 70, width: 900, height: 700))],
                                 focus: scrollAX(token: 2, frame: CGRect(x: 1100, y: 70, width: 900, height: 700)))
    var inconsistent = valid; inconsistent.foregroundStayedConsistent = false
    let failures: [(String, ScreenshotScrollTargetSnapshot)] = [
        ("same-PID normal-window switch", changed),
        ("AX identity changed at same geometry", scrollSnapshot(focus: scrollAX(token: 2))),
        ("AX query failed", scrollSnapshot(focus: .accessibilityQueryFailed)),
        ("AX permission revoked", scrollSnapshot()),
        ("selected window moved", scrollSnapshot(windows: [scrollWindow(frame: scrollBounds.offsetBy(dx: 1, dy: 0))], focus: scrollAX())),
        ("selected window disappeared", scrollSnapshot(windows: [], focus: .accessibilityQueryFailed)),
        ("foreground changed", scrollSnapshot(pid: 99, focus: scrollAX())),
        ("foreground changed during probe", inconsistent)
    ]
    for (name, post) in failures {
        let probe = ScriptedScrollProbe([valid, post])
        let session = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: probe)
        _ = try session.addFrame(first)
        var produced = 0
        do {
            _ = try await session.captureNext(capturing: { produced += 1; return next })
            throw ScrollGuardTestFailure("Committed postCapture failure: \(name)")
        } catch ScreenshotCaptureFailure.unsupported {}
        try scrollExpect(produced == 1 && probe.reads == 2, "Production pre/post transaction was bypassed: \(name)")
        try scrollExpect(session.capturedFrameCount == 1 && session.outputHeight == first.height && session.pendingSeam == nil && session.seams.isEmpty,
                         "A rejected postCapture frame changed retained frame metadata: \(name)")
        try scrollExpect(session.lastTargetDiagnostic?.stage == .postCapture, "Missing postCapture diagnostic: \(name)")
        if name == "AX query failed" || name == "AX permission revoked" || name == "foreground changed during probe" {
            try scrollExpect(session.lastTargetDiagnostic?.actualWindowID == ScreenshotScrollTargetDiagnostic.unknown,
                             "AX query failure invented a known actual focused window ID")
        }
        if name == "foreground changed" {
            try scrollExpect(session.lastTargetDiagnostic?.actualPID == 99 && session.lastTargetDiagnostic?.actualWindowID == ScreenshotScrollTargetDiagnostic.unknown,
                             "A foreign foreground PID was paired with the target application's window ID")
        }
        try scrollExpect(try scrollImageBytes(session.finish()) == retainedBytes, "A rejected postCapture frame changed the old image: \(name)")
    }

    let preProbe = ScriptedScrollProbe([changed])
    let pre = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: preProbe)
    var preProduced = 0
    do { _ = try await pre.captureNext(capturing: { preProduced += 1; return next }); throw ScrollGuardTestFailure("preCapture allowed changed focus") }
    catch ScreenshotCaptureFailure.unsupported {}
    try scrollExpect(preProduced == 0 && pre.capturedFrameCount == 0 && pre.lastTargetDiagnostic?.stage == .preCapture,
                     "preCapture failure reached the producer or lacked its stage")
    try scrollExpect(pre.lastTargetDiagnostic?.actualWindowID == 202 && pre.lastTargetDiagnostic?.actualPID == 42,
                     "Same-PID switch diagnostics do not report the actual mapped numeric window ID")

    let unknown = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: ScriptedScrollProbe([scrollSnapshot(windows: [], pid: nil)]))
    do { _ = try await unknown.captureNext(capturing: { next }); throw ScrollGuardTestFailure("Unknown foreground accepted") }
    catch ScreenshotCaptureFailure.unsupported {}
    try scrollExpect(unknown.lastTargetDiagnostic?.description == "preCapture expectedPID=42 actualPID=-1 expectedWindowID=101 actualWindowID=-1",
                     "Unknown diagnostic values must share the numeric -1 sentinel")

    let manual = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: ScriptedScrollProbe([scrollSnapshot(), scrollSnapshot()]))
    _ = try await manual.captureNext(capturing: { first })
    try scrollExpect(manual.capturedFrameCount == 1, "Untrusted manual capture lost its single-window path")

    let cancellation = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: ScriptedScrollProbe([valid]))
    _ = try cancellation.addFrame(first)
    let cancelledTask = Task { @MainActor in
        try await cancellation.captureNext(capturing: {
            withUnsafeCurrentTask { $0?.cancel() }
            return next
        })
    }
    do { _ = try await cancelledTask.value; throw ScrollGuardTestFailure("Cancelled producer appended a frame") }
    catch is CancellationError {}
    try scrollExpect(cancellation.capturedFrameCount == 1 && cancellation.outputHeight == first.height && cancellation.pendingSeam == nil,
                     "Ignored producer cancellation corrupted retained frames")
    print("PASS capture transaction: real preCapture/postCapture path, rejected frame never appended, retained image byte equality, numeric diagnostics, single-window manual capture and ignored-producer cancellation.")

    let preScroll = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: ScriptedScrollProbe([scrollSnapshot()]))
    var scrollActions = 0, captures = 0
    do {
        _ = try await preScroll.scrollAndCapture(performScroll: { _ in scrollActions += 1 }, capturing: { captures += 1; return next })
        throw ScrollGuardTestFailure("preScroll permitted unavailable AX")
    } catch ScreenshotCaptureFailure.unsupported {}
    try scrollExpect(scrollActions == 0 && captures == 0 && preScroll.lastTargetDiagnostic?.stage == .preScroll,
                     "preScroll did not refuse unavailable AX before the action")

    let postScroll = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: ScriptedScrollProbe([valid, changed]))
    _ = try postScroll.addFrame(first)
    var anchor: CGPoint?
    do {
        _ = try await postScroll.scrollAndCapture(performScroll: { anchor = $0; scrollActions += 1 }, capturing: { captures += 1; return next })
        throw ScrollGuardTestFailure("postScroll permitted a changed focused window")
    } catch ScreenshotCaptureFailure.unsupported {}
    try scrollExpect(anchor == CGPoint(x: 600, y: 350) && scrollActions == 1 && captures == 0,
                     "Selected top-left ROI anchor was flipped or postScroll reached capture")
    try scrollExpect(postScroll.lastTargetDiagnostic?.stage == .postScroll && postScroll.capturedFrameCount == 1,
                     "postScroll failure lacked its stage or changed retained frames")
    try scrollExpect(try scrollImageBytes(postScroll.finish()) == retainedBytes, "postScroll failure changed the retained image")

    let allProbe = ScriptedScrollProbe([valid, valid, valid, valid])
    let allStages = ScreenshotLongScreenshotSession(target: scrollTarget, targetProbe: allProbe)
    var successActions = 0, successCaptures = 0
    _ = try await allStages.scrollAndCapture(performScroll: { _ in successActions += 1 }, capturing: { successCaptures += 1; return first })
    try scrollExpect(allProbe.reads == 4 && successActions == 1 && successCaptures == 1 && allStages.capturedFrameCount == 1,
                     "Successful explicit scroll did not traverse all four production guard stages")
    print("PASS scroll transaction: preScroll/postScroll rejection, one explicit injected action, unchanged retained image, exact ROI anchor and all four guard stages.")
}

struct ScreenshotScrollTargetGuardTestsMain {
    @MainActor static func main() async {
        do {
            try runScrollMetadataTests()
            try await runScrollTransactionTests()
            print("PASS Scroll target guard targeted CLI. No NSApplication, AX calls, live window enumeration, event posting, UI, capture, file images or user data.")
        } catch {
            fputs("Scroll target guard targeted CLI FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
