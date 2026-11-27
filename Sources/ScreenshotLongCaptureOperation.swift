import Foundation
import CoreGraphics

/// Owns the entire long-capture interaction, including the time after preparation returns.
@MainActor
final class ScreenshotLongCaptureOperation {
    private(set) var isActive = true
    private var preparationTask: Task<Void, Never>?

    func checkActive() throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
    }

    func setPreparationTask(_ task: Task<Void, Never>) {
        guard isActive else { task.cancel(); return }
        preparationTask = task
    }

    func preparationFinished() { preparationTask = nil }

    /// Invalidate first: cancellation callbacks and late producers cannot end a later operation.
    @discardableResult
    func finish(cleanup: () -> Void) -> Bool {
        guard isActive else { return false }
        isActive = false
        preparationTask?.cancel(); preparationTask = nil
        cleanup()
        return true
    }
}

/// Runs only after the dedicated control is clicked. The same batch check is
/// called by the native scroll transaction immediately before posting input.
@MainActor enum ScreenshotLongCaptureBatch {
    enum Step { case appended, duplicate, review }
    enum Stop: Equatable { case duplicate, review, limit }
    private struct DeadlineReached: Error {}

    static func run(operation: ScreenshotLongCaptureOperation,
                    uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    verifyStart: (_ check: () throws -> Void) async throws -> Void,
                    next: (_ check: () throws -> Void) async throws -> Step) async throws -> Stop {
        let deadline = uptime() + 8
        func check() throws {
            try operation.checkActive()
            guard uptime() < deadline else { throw DeadlineReached() }
        }
        do {
            try check()
            try await verifyStart(check)
            for _ in 0..<12 {
                try check()
                let step = try await next(check)
                try operation.checkActive()
                switch step {
                case .appended: continue
                case .duplicate: return .duplicate
                case .review: return .review
                }
            }
            return .limit
        } catch {
            try operation.checkActive()
            // The native scroll guard may wrap the deadline error in its own
            // safely-stopped result, so recheck the same monotonic clock here.
            if error is DeadlineReached || uptime() >= deadline { return .limit }
            throw error
        }
    }
}

struct ScreenshotLongCapturePreparedSource {
    let window: ScreenshotCaptureWindow
    let display: ScreenshotCaptureDisplay
    let region: CGRect
}

/// The production preparation pipeline. Injected effects allow cancellation checks without UI/capture.
@MainActor
enum ScreenshotLongCapturePreparation {
    static func run(operation: ScreenshotLongCaptureOperation,
                    isCurrent: () -> Bool = { true },
                    refreshCatalog: () async throws -> ScreenshotCaptureCatalog,
                    selectWindow: ([ScreenshotCaptureWindow]) async -> CGWindowID?,
                    willSelectRegion: () -> Void,
                    selectRegion: () async -> CGRect?,
                    activate: (ScreenshotCaptureWindow) throws -> Void,
                    settle: () async throws -> Void) async throws -> ScreenshotLongCapturePreparedSource {
        func checkCurrent() throws {
            try operation.checkActive()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let catalog = try await refreshCatalog()
        try checkCurrent()
        let selectedID = await selectWindow(catalog.windows)
        try checkCurrent()
        guard let id = selectedID, let window = catalog.windows.first(where: { $0.id == id }) else { throw ScreenshotCaptureFailure.cancelled }
        willSelectRegion()
        let selectedRegion = await selectRegion()
        try checkCurrent()
        guard let region = selectedRegion else { throw ScreenshotCaptureFailure.cancelled }
        guard let display = catalog.displays.first(where: { $0.frame.contains(region) }),
              window.frame.insetBy(dx: -1, dy: -1).contains(region) else {
            throw ScreenshotCaptureFailure.unsupported("长截图内容区须完整位于所选窗口与一块显示器内，请重新选择。跨屏普通截图仍可使用。")
        }
        try activate(window)
        try await settle()
        try checkCurrent()
        return ScreenshotLongCapturePreparedSource(window: window, display: display, region: region)
    }
}
