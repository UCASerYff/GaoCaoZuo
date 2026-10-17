import Foundation
import CoreGraphics

/// Includes order: the first screen defines the AppKit-to-AX coordinate origin.
/// Geometry equality alone must not bind a removed display to a replacement.
struct WindowDisplaySnapshot: Equatable {
    let id: UInt32
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat

    static func isValid(_ displays: [Self]) -> Bool {
        !displays.isEmpty && Set(displays.map(\.id)).count == displays.count
            && displays.allSatisfy {
                $0.id != 0 && WindowLayoutTransaction.isValid($0.frame)
                    && WindowLayoutTransaction.isValid($0.visibleFrame)
                    && $0.scale.isFinite && $0.scale > 0
            }
    }
    static func permitsWrite(captured: [Self], current: [Self]) -> Bool {
        isValid(captured) && isValid(current) && captured == current
    }
}
