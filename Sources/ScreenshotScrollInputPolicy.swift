import Foundation
import CoreGraphics

/// Pure input selection and attempt accounting. No AX, event creation, permission request or input occurs here.
struct ScreenshotScrollInputPolicy {
    enum Capability: Equatable { case advertised, absent, unknown }
    enum Strategy: Int { case native = 1, windowServer = 3 }
    enum Failure: Error, Equatable { case noCandidate, unknownCapability, invalidPixelBudget, capabilityChanged, inputAlreadyAttempted, postingUnavailable }
    struct Candidate {
        let plan: ScreenshotScrollVisibilityPlan
        let capability: Capability
    }
    struct Decision: Equatable {
        let index: Int
        let strategy: Strategy
        let pixels: Int32
    }

    /// One input attempt. A native action and a WindowServer wheel can never share a transaction.
    struct Attempt {
        enum State: Int {
            case unused = 0, nativeAttempted = 1, wheelAttempted = 3, refused = 4
        }
        private(set) var state = State.unused

        init() {}

        /// Advance immediately before the sole native action or WindowServer wheel is posted.
        mutating func begin(decision: Decision, freshCapability: Capability, postingAvailable: Bool) throws {
            do {
                guard state == .unused else { throw Failure.inputAlreadyAttempted }
                try ScreenshotScrollInputPolicy.requireReady(decision, freshCapability: freshCapability,
                    inputAlreadyAttempted: state != .unused, postingAvailable: postingAvailable)
                state = decision.strategy == .native ? .nativeAttempted : .wheelAttempted
            } catch {
                refuse()
                throw error
            }
        }

        /// A failed guard, cancellation or expired deadline permanently consumes this transaction.
        mutating func refuse() { state = .refused }
    }

    /// Pure arithmetic only. The caller creates one deadline, then only checks that fixed value.
    enum PointerWaitDeadline {
        enum Failure: Error, Equatable { case invalidClock, expired }

        static func fixedDeadline(now: TimeInterval, phaseDeadline: TimeInterval,
                                  transactionDeadline: TimeInterval) throws -> TimeInterval {
            guard now.isFinite, now >= 0, phaseDeadline.isFinite, transactionDeadline.isFinite else {
                throw Failure.invalidClock
            }
            let deadline = min(now + 2, phaseDeadline, transactionDeadline)
            try requireActive(now: now, deadline: deadline)
            return deadline
        }

        static func requireActive(now: TimeInterval, deadline: TimeInterval) throws {
            guard now.isFinite, now >= 0, deadline.isFinite else { throw Failure.invalidClock }
            guard now < deadline else { throw Failure.expired }
        }
    }

    enum PointerGeometryFailure: Error, Equatable { case invalidPrimaryDisplay, invalidPoint }

    /// Quartz uses the primary display's top-left; AppKit uses its bottom-left in global points.
    /// Points outside the primary display are valid and retain their global horizontal coordinate.
    static func cocoaPoint(fromQuartz point: CGPoint, primaryDisplayBounds bounds: CGRect) throws -> CGPoint {
        guard bounds.origin == .zero, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { throw PointerGeometryFailure.invalidPrimaryDisplay }
        guard point.x.isFinite, point.y.isFinite else { throw PointerGeometryFailure.invalidPoint }
        let result = CGPoint(x: point.x, y: bounds.height - point.y)
        guard result.y.isFinite else { throw PointerGeometryFailure.invalidPoint }
        return result
    }

    static func select(_ candidates: [Candidate], requestedPoints: CGFloat) throws -> Decision {
        guard !candidates.isEmpty else { throw Failure.noCandidate }
        // A verified native candidate wins; unrelated unknown capabilities cannot authorize CG.
        if let index = candidates.indices.filter({ candidates[$0].capability == .advertised })
            .min(by: { candidates[$0].plan.expectedMinimumScroll < candidates[$1].plan.expectedMinimumScroll }) {
            return Decision(index: index, strategy: .native, pixels: 0)
        }
        // With no verified native choice, unknown evidence is never proof of absence.
        guard !candidates.contains(where: { $0.capability == .unknown }) else { throw Failure.unknownCapability }
        guard let index = candidates.indices.min(by: { candidates[$0].plan.expectedMinimumScroll < candidates[$1].plan.expectedMinimumScroll }) else {
            throw Failure.noCandidate
        }
        let plan = candidates[index].plan
        let amount = floor(min(240, requestedPoints, plan.roi.height * 0.5))
        guard requestedPoints.isFinite, requestedPoints > 0, requestedPoints <= 2_000,
              amount.isFinite, amount >= 1, amount <= plan.stepBudget, amount >= plan.expectedMinimumScroll else { throw Failure.invalidPixelBudget }
        return Decision(index: index, strategy: .windowServer, pixels: Int32(amount))
    }

    static func requireReady(_ decision: Decision, freshCapability: Capability,
                             inputAlreadyAttempted: Bool, postingAvailable: Bool) throws {
        guard !inputAlreadyAttempted else { throw Failure.inputAlreadyAttempted }
        let expected: Capability = decision.strategy == .native ? .advertised : .absent
        guard freshCapability == expected else { throw Failure.capabilityChanged }
        if decision.strategy == .windowServer {
            guard decision.pixels >= 1, postingAvailable else { throw Failure.postingUnavailable }
        }
    }
}
