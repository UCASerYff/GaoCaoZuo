import Foundation
import CoreGraphics

/// Geometry only. The live adapter must bind and recheck the identities of both AX elements.
struct ScreenshotScrollVisibilityPlan: Equatable {
    enum Failure: Int, Error, Equatable {
        // Stable numeric failure codes for metadata-only diagnostics; zero means not reached.
        case invalidGeometry = 1, invalidBudget, regionOutsideViewport
        case markerOutsideRegion, targetOutsideColumn, targetTooTall
        case targetAlreadyVisible, minimumScrollExceedsBudget
        case viewportChanged, regionChanged, elementGeometryChanged
        case noForwardMovement, inconsistentMovement, excessiveMovement, targetNotVisible
    }

    static let frameTolerance: CGFloat = 0.5

    let viewport: CGRect
    let roi: CGRect
    let marker: CGRect
    let target: CGRect
    /// This bounds the predicted minimum scroll, not a provider's alignment policy.
    let stepBudget: CGFloat
    /// A completed action must preserve at least 20 percent of the selected region's overlap.
    let maxActualDelta: CGFloat
    let expectedMinimumScroll: CGFloat

    private init(viewport: CGRect, roi: CGRect, marker: CGRect, target: CGRect,
                 stepBudget: CGFloat, maxActualDelta: CGFloat, expectedMinimumScroll: CGFloat) {
        self.viewport = viewport
        self.roi = roi
        self.marker = marker
        self.target = target
        self.stepBudget = stepBudget
        self.maxActualDelta = maxActualDelta
        self.expectedMinimumScroll = expectedMinimumScroll
    }

    static func makePlan(viewport: CGRect, roi: CGRect, marker: CGRect, target: CGRect,
                         requestedPoints: CGFloat) throws -> Self {
        guard [viewport, roi, marker, target].allSatisfy(validFrame) else {
            throw Failure.invalidGeometry
        }
        guard requestedPoints.isFinite, requestedPoints > 0, requestedPoints <= 2_000 else {
            throw Failure.invalidBudget
        }
        guard viewport.contains(roi) else { throw Failure.regionOutsideViewport }
        let column = roi.midX
        guard containsColumn(marker, column), marker.maxY > roi.minY, marker.minY < roi.maxY else {
            throw Failure.markerOutsideRegion
        }
        // A row may be wider than the user's ROI. It must not require horizontal scrolling,
        // and it must lie in the anchor's column rather than a neighboring column.
        guard containsColumn(target, column),
              target.minX >= viewport.minX - frameTolerance,
              target.maxX <= viewport.maxX + frameTolerance else { throw Failure.targetOutsideColumn }
        guard target.height <= viewport.height else { throw Failure.targetTooTall }
        let minimum = target.maxY - viewport.maxY
        guard minimum > 0 else { throw Failure.targetAlreadyVisible }
        let budget = min(requestedPoints, roi.height * 0.5)
        guard minimum <= budget else { throw Failure.minimumScrollExceedsBudget }
        return Self(viewport: viewport, roi: roi, marker: marker, target: target,
                    stepBudget: budget, maxActualDelta: roi.height * 0.8,
                    expectedMinimumScroll: minimum)
    }

    /// Verify fresh frames of the same bound elements before any image is captured.
    /// Successful AX delivery alone supplies none of this evidence.
    @discardableResult
    func verify(viewportAfter: CGRect, roiAfter: CGRect? = nil,
                markerAfter: CGRect, targetAfter: CGRect) throws -> CGFloat {
        guard [viewportAfter, markerAfter, targetAfter].allSatisfy(Self.validFrame),
              roiAfter.map(Self.validFrame) ?? true else { throw Failure.invalidGeometry }
        guard viewportAfter == viewport else { throw Failure.viewportChanged }
        if let roiAfter, roiAfter != roi { throw Failure.regionChanged }
        guard Self.sameShapeAndX(marker, markerAfter), Self.sameShapeAndX(target, targetAfter) else {
            throw Failure.elementGeometryChanged
        }
        let markerDelta = marker.minY - markerAfter.minY
        let targetDelta = target.minY - targetAfter.minY
        guard markerDelta > 0, targetDelta > 0 else { throw Failure.noForwardMovement }
        guard abs(markerDelta - targetDelta) <= Self.frameTolerance else {
            throw Failure.inconsistentMovement
        }
        let actualDelta = max(markerDelta, targetDelta)
        guard actualDelta <= maxActualDelta else { throw Failure.excessiveMovement }
        guard actualDelta + Self.frameTolerance >= expectedMinimumScroll,
              Self.contains(viewportAfter, targetAfter, tolerance: Self.frameTolerance) else {
            throw Failure.targetNotVisible
        }
        return actualDelta
    }

    private static func validFrame(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func containsColumn(_ rect: CGRect, _ x: CGFloat) -> Bool {
        rect.minX <= x && rect.maxX >= x
    }

    private static func sameShapeAndX(_ before: CGRect, _ after: CGRect) -> Bool {
        abs(before.minX - after.minX) <= frameTolerance
            && abs(before.width - after.width) <= frameTolerance
            && abs(before.height - after.height) <= frameTolerance
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.maxX <= outer.maxX + tolerance
            && inner.minY >= outer.minY - tolerance && inner.maxY <= outer.maxY + tolerance
    }
}
