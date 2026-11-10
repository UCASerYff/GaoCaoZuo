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
