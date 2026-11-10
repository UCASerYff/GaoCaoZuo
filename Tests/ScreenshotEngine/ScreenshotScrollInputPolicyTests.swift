// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if SCROLL_INPUT_POLICY_TESTS
import Foundation
import CoreGraphics

// Pure fixture only: no AX, event, app/window, permission, screen or audio API.
private struct FixtureFailure: Error { let message: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw FixtureFailure(message: message) }
}
private func rejectPolicy(_ expected: ScreenshotScrollInputPolicy.Failure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected policy rejection: \(expected)") }
    catch let error as ScreenshotScrollInputPolicy.Failure { try expect(error == expected, "Wrong policy rejection") }
}
private func rejectMotion(_ expected: ScreenshotScrollVisibilityPlan.Failure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected movement rejection: \(expected)") }
    catch let error as ScreenshotScrollVisibilityPlan.Failure { try expect(error == expected, "Wrong movement rejection") }
}
private func rejectWait(_ expected: ScreenshotScrollInputPolicy.PointerWaitDeadline.Failure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected pointer wait rejection: \(expected)") }
    catch let error as ScreenshotScrollInputPolicy.PointerWaitDeadline.Failure { try expect(error == expected, "Wrong pointer wait rejection") }
}
private func rejectGeometry(_ expected: ScreenshotScrollInputPolicy.PointerGeometryFailure, _ body: () throws -> Void) throws {
    do { try body(); throw FixtureFailure(message: "Expected pointer geometry rejection: \(expected)") }
    catch let error as ScreenshotScrollInputPolicy.PointerGeometryFailure { try expect(error == expected, "Wrong pointer geometry rejection") }
}
private func plan(minimum: CGFloat = 50, roiHeight: CGFloat = 960, requested: CGFloat = 240) throws -> ScreenshotScrollVisibilityPlan {
    try ScreenshotScrollVisibilityPlan.makePlan(viewport: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        roi: CGRect(x: 20, y: 20, width: 960, height: roiHeight),
        marker: CGRect(x: 0, y: 100, width: 1000, height: 90),
        target: CGRect(x: 0, y: 1000, width: 1000, height: minimum), requestedPoints: requested)
}
struct ScreenshotScrollInputPolicyTests {
    static func main() throws {
        var passed: [String] = []
        let small = try plan(minimum: 50), large = try plan(minimum: 150)
        let mixed = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .absent), .init(plan: large, capability: .advertised)], requestedPoints: 240)
        try expect(mixed.index == 1 && mixed.strategy == .native && mixed.pixels == 0, "Native must win over cheaper absent candidate")
        passed.append("nativePreferredOverCheaperWindowServer")
        let native = try ScreenshotScrollInputPolicy.select([.init(plan: large, capability: .advertised), .init(plan: small, capability: .advertised)], requestedPoints: 240)
        try expect(native.index == 1 && native.strategy == .native, "Choose smallest valid native target")
        passed.append("smallestNativeCandidate")
        let mixedUnknown = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .unknown), .init(plan: large, capability: .advertised)], requestedPoints: 240)
        try expect(mixedUnknown.index == 1 && mixedUnknown.strategy == .native && mixedUnknown.pixels == 0, "Verified native must win despite unrelated unknown")
        passed.append("verifiedNativeWinsOverUnknown")
        let reverseMixedUnknown = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .advertised), .init(plan: large, capability: .unknown)], requestedPoints: 240)
        try expect(reverseMixedUnknown.index == 0 && reverseMixedUnknown.strategy == .native, "Candidate order must not suppress verified native")
        passed.append("nativePriorityIndependentOfUnknownOrder")
        try ScreenshotScrollInputPolicy.requireReady(mixedUnknown, freshCapability: .advertised, inputAlreadyAttempted: false, postingAvailable: false)
        passed.append("verifiedNativeDoesNotNeedCGPostingGrant")
        try rejectPolicy(.capabilityChanged) { try ScreenshotScrollInputPolicy.requireReady(mixedUnknown, freshCapability: .unknown, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("selectedNativeMustRemainKnownAdvertised")
        try rejectPolicy(.unknownCapability) { _ = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .unknown)], requestedPoints: 240) }
        passed.append("unknownNeverMeansAbsent")
        try rejectPolicy(.unknownCapability) { _ = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .absent), .init(plan: large, capability: .unknown)], requestedPoints: 240) }
        passed.append("partlyUnknownCannotAuthorizeWindowServer")
        let fractional = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: 60.9)
        try expect(fractional.pixels == 60 && fractional.strategy == .windowServer, "Respect smaller request and floor")
        passed.append("smallerRequestAndFloor")
        let tiny = try plan(minimum: 0.2, requested: 0.9)
        try rejectPolicy(.invalidPixelBudget) { _ = try ScreenshotScrollInputPolicy.select([.init(plan: tiny, capability: .absent)], requestedPoints: 0.9) }
        passed.append("zeroRoundedPixelRefused")
        let clipped = try plan(minimum: 60.5, requested: 60.9)
        try rejectPolicy(.invalidPixelBudget) { _ = try ScreenshotScrollInputPolicy.select([.init(plan: clipped, capability: .absent)], requestedPoints: 60.9) }
        passed.append("roundedPixelMustCoverMinimum")
        let lowROI = try plan(minimum: 80, roiHeight: 201, requested: 240)
        let bounded = try ScreenshotScrollInputPolicy.select([.init(plan: lowROI, capability: .absent)], requestedPoints: 240)
        try expect(bounded.pixels == 100, "ROI half-height floor must apply")
        passed.append("halfROIFloor")
        let wheel = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: 500)
        try expect(wheel.pixels == 240, "The single wheel keeps the existing wheel ceiling")
        passed.append("singleWheelPixelCeiling")
        try rejectPolicy(.invalidPixelBudget) { _ = try ScreenshotScrollInputPolicy.select([.init(plan: small, capability: .absent)], requestedPoints: .nan) }
        passed.append("nonfiniteRequestRefused")
        try rejectPolicy(.capabilityChanged) { try ScreenshotScrollInputPolicy.requireReady(wheel, freshCapability: .advertised, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("newNativeCapabilityDoesNotSwitchMidFlight")
        try rejectPolicy(.capabilityChanged) { try ScreenshotScrollInputPolicy.requireReady(wheel, freshCapability: .unknown, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("selectedWindowServerMustRemainKnownAbsent")
        try rejectPolicy(.capabilityChanged) { try ScreenshotScrollInputPolicy.requireReady(native, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: true) }
        passed.append("lostNativeDoesNotFallBack")
        try rejectPolicy(.postingUnavailable) { try ScreenshotScrollInputPolicy.requireReady(wheel, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: false) }
        passed.append("missingPostingGrantRefused")
        try rejectPolicy(.inputAlreadyAttempted) { try ScreenshotScrollInputPolicy.requireReady(wheel, freshCapability: .absent, inputAlreadyAttempted: true, postingAvailable: true) }
        passed.append("priorAttemptPreventsWindowServer")
        try rejectPolicy(.inputAlreadyAttempted) { try ScreenshotScrollInputPolicy.requireReady(native, freshCapability: .advertised, inputAlreadyAttempted: true, postingAvailable: true) }
        passed.append("priorAttemptPreventsNativeRetry")
        try ScreenshotScrollInputPolicy.requireReady(wheel, freshCapability: .absent, inputAlreadyAttempted: false, postingAvailable: true)
        passed.append("freshExplicitAbsenceAllowsOneWindowServerWheel")
        let p = small
        func shifted(_ rect: CGRect, _ delta: CGFloat) -> CGRect { rect.offsetBy(dx: 0, dy: -delta) }
        try expect(try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) == 100, "Consistent verified motion")
        passed.append("actualConsistentMotionRequired")
        try rejectMotion(.noForwardMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: p.marker, targetAfter: p.target) }
        passed.append("postedButNoMotionRejected")
        try rejectMotion(.noForwardMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, -1), targetAfter: shifted(p.target, -1)) }
        passed.append("reverseMotionRejected")
        try rejectMotion(.excessiveMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 769), targetAfter: shifted(p.target, 769)) }
        passed.append("excessiveMotionRejected")
        try rejectMotion(.inconsistentMovement) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 90)) }
        passed.append("inconsistentMotionRejected")
        try rejectMotion(.targetNotVisible) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi, markerAfter: shifted(p.marker, 49), targetAfter: shifted(p.target, 49)) }
        passed.append("insufficientMotionRejected")
        try rejectMotion(.viewportChanged) { _ = try p.verify(viewportAfter: p.viewport.offsetBy(dx: 1, dy: 0), roiAfter: p.roi, markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) }
        passed.append("originalAreaGeometryRequired")
        try rejectMotion(.regionChanged) { _ = try p.verify(viewportAfter: p.viewport, roiAfter: p.roi.offsetBy(dx: 1, dy: 0), markerAfter: shifted(p.marker, 100), targetAfter: shifted(p.target, 100)) }
        passed.append("originalROIRequired")

        try expect(ScreenshotScrollInputPolicy.Strategy.windowServer.rawValue == 3
                   && ScreenshotScrollInputPolicy.Strategy(rawValue: 2) == nil, "The old PID wheel route must not remain selectable")
        passed.append("onlyNativeOrWindowServerRoutes")
        var successful = ScreenshotScrollInputPolicy.Attempt()
        var simulatedPosts = 0
        try successful.begin(decision: wheel, freshCapability: .absent, postingAvailable: true)
        simulatedPosts += 1
        try expect(successful.state == .wheelAttempted && simulatedPosts == 1, "One wheel immediately consumes the attempt")
        passed.append("singleWheelIsTerminalAttempt")
        try rejectPolicy(.inputAlreadyAttempted) {
            try successful.begin(decision: wheel, freshCapability: .absent, postingAvailable: true)
            simulatedPosts += 1
        }
        try expect(successful.state == .refused && simulatedPosts == 1, "A second wheel must not be posted")
        passed.append("secondWheelNeverPosted")

        var nativeAttempt = ScreenshotScrollInputPolicy.Attempt()
        try nativeAttempt.begin(decision: native, freshCapability: .advertised, postingAvailable: false)
        try expect(nativeAttempt.state == .nativeAttempted, "A native action consumes the attempt without a CG posting grant")
        passed.append("nativeConsumesAttemptWithoutPostingGrant")
        var fallbackPosts = 0
        try rejectPolicy(.inputAlreadyAttempted) {
            try nativeAttempt.begin(decision: wheel, freshCapability: .absent, postingAvailable: true)
            fallbackPosts += 1
        }
        try expect(nativeAttempt.state == .refused && fallbackPosts == 0, "A native attempt forbids WindowServer fallback")
        passed.append("nativeAttemptPreventsWindowServerFallback")

        for (name, capability, grant, expected) in [
            ("unknownAllowsZeroPosts", ScreenshotScrollInputPolicy.Capability.unknown, true, ScreenshotScrollInputPolicy.Failure.capabilityChanged),
            ("missingGrantAllowsZeroPosts", .absent, false, .postingUnavailable)
        ] {
            var attempt = ScreenshotScrollInputPolicy.Attempt()
            var posts = 0
            try rejectPolicy(expected) {
                try attempt.begin(decision: wheel, freshCapability: capability, postingAvailable: grant)
                posts += 1
            }
            try rejectPolicy(.inputAlreadyAttempted) {
                try attempt.begin(decision: wheel, freshCapability: .absent, postingAvailable: true)
                posts += 1
            }
            try expect(attempt.state == .refused && posts == 0, "Refusal is permanent even if conditions later change")
            passed.append(name)
        }
        var guardRefused = ScreenshotScrollInputPolicy.Attempt()
        var guardRefusedPosts = 0
        guardRefused.refuse()
        try rejectPolicy(.inputAlreadyAttempted) {
            try guardRefused.begin(decision: wheel, freshCapability: .absent, postingAvailable: true)
            guardRefusedPosts += 1
        }
        try expect(guardRefused.state == .refused && guardRefusedPosts == 0, "A failed source, cancellation or time guard permits no post")
        passed.append("guardRefusalAllowsZeroPosts")

        typealias Wait = ScreenshotScrollInputPolicy.PointerWaitDeadline
        let fixed = try Wait.fixedDeadline(now: 10, phaseDeadline: 20, transactionDeadline: 30)
        try expect(fixed == 12, "Pointer waiting allows at most two seconds")
        try expect(try Wait.fixedDeadline(now: 10, phaseDeadline: 11, transactionDeadline: 30) == 11, "The original phase deadline wins")
        try expect(try Wait.fixedDeadline(now: 10, phaseDeadline: 20, transactionDeadline: 10.5) == 10.5, "The original transaction deadline wins")
        passed.append("pointerWaitUsesEarliestOriginalDeadline")
        try Wait.requireActive(now: 11.9, deadline: fixed)
        try rejectWait(.expired) { try Wait.requireActive(now: 12, deadline: fixed) }
        try rejectWait(.expired) { try Wait.requireActive(now: 12.1, deadline: fixed) }
        try expect(fixed == 12, "Checking the wait must never renew its deadline")
        passed.append("pointerWaitDeadlineDoesNotRenew")
        try rejectWait(.expired) { _ = try Wait.fixedDeadline(now: 10, phaseDeadline: 10, transactionDeadline: 30) }
        try rejectWait(.invalidClock) { _ = try Wait.fixedDeadline(now: .nan, phaseDeadline: 20, transactionDeadline: 30) }
        try rejectWait(.invalidClock) { try Wait.requireActive(now: 10, deadline: .infinity) }
        passed.append("invalidOrExpiredPointerWaitRefused")

        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        try expect(try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: CGPoint(x: 40, y: 30), primaryDisplayBounds: primary)
                   == CGPoint(x: 40, y: 1050), "Quartz-to-Cocoa must flip Y using the primary height")
        passed.append("quartzToCocoaUsesPrimaryHeight")
        try expect(try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: CGPoint(x: -500, y: 1200), primaryDisplayBounds: primary)
                   == CGPoint(x: -500, y: -120), "Other-display global points below or left of primary remain valid")
        try expect(try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: CGPoint(x: 2500, y: -200), primaryDisplayBounds: primary)
                   == CGPoint(x: 2500, y: 1280), "Other-display global points above or right of primary remain valid")
        passed.append("otherDisplayGlobalCoordinatesAllowed")
        try rejectGeometry(.invalidPrimaryDisplay) {
            _ = try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: .zero, primaryDisplayBounds: primary.offsetBy(dx: 1, dy: 0))
        }
        try rejectGeometry(.invalidPrimaryDisplay) {
            _ = try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: .zero, primaryDisplayBounds: CGRect(x: 0, y: 0, width: 1920, height: 0))
        }
        passed.append("invalidPrimaryDisplayGeometryRefused")
        try rejectGeometry(.invalidPoint) {
            _ = try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: CGPoint(x: CGFloat.nan, y: 0), primaryDisplayBounds: primary)
        }
        try rejectGeometry(.invalidPoint) {
            _ = try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: CGPoint(x: 0, y: -CGFloat.greatestFiniteMagnitude),
                primaryDisplayBounds: CGRect(x: 0, y: 0, width: 1, height: CGFloat.greatestFiniteMagnitude))
        }
        passed.append("invalidOrOverflowingPointerPointRefused")
        let result: [String: Any] = ["result": "PURE_WINDOWSERVER_POLICY_WAIT_AND_MOVEMENT_FIXTURE_PASS", "caseCount": passed.count, "cases": passed, "realInputsOrAXOrCapture": false, "scope": "Pure route decision, one-attempt accounting, fixed pointer-wait deadline, coordinate arithmetic and unchanged movement verification; simulated post counters only, no live pointer/window/event or capture claim"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

#endif
