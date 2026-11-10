// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
#if RECORDING_SESSION_TESTS
import Foundation

private struct RecordingSessionTestFailure: LocalizedError {
    let errorDescription: String?
}

private func sessionExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RecordingSessionTestFailure(errorDescription: message) }
}

@MainActor
private final class DeferredRecordingCheck {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var entered = false
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release(error: Error? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

/// Calls the controller's real producer callback, monitor and stop implementations.
/// Only the initial active state is injected: no device, recorder, stream, writer or UI is created.
@MainActor
func ScreenshotRunRecordingSessionIsolationTests() async throws {
    let controller = ScreenshotRecordingController()
    let oldID = try controller.beginIsolatedSessionForTesting()
    let oldWriterFailure = controller.failureHandlerForTesting(sessionID: oldID)
    let oldRecorderFailure = controller.failureHandlerForTesting(sessionID: oldID)
    let delayedFailure = DeferredRecordingCheck()
    let oldMonitor = Task { @MainActor in
        await controller.monitorOnceForTesting(sessionID: oldID, check: { try await delayedFailure.wait() })
    }
    while !delayedFailure.entered { await Task.yield() }
    await controller.stop()
    try sessionExpect(controller.state == .failed, "隔离会话无媒体时仍被错误完成")
    let newID = try controller.beginIsolatedSessionForTesting()
    let before = controller.statusMessage
    await oldWriterFailure(ScreenshotRecordingError.writing("旧 writer 迟到错误")).value
    await oldRecorderFailure(ScreenshotRecordingError.writing("旧 recorder 迟到错误")).value
    try sessionExpect(controller.state == .recording && controller.statusMessage == before,
        "旧 writer/recorder 的生产错误回调终止或修改了新会话")
    delayedFailure.release(error: ScreenshotRecordingError.sourceUnavailable("旧源查询迟到失败"))
    let oldFailureResult = await oldMonitor.value
    try sessionExpect(!oldFailureResult && controller.state == .recording && controller.statusMessage == before,
        "旧 monitor await 后的失败终止或修改了新会话")

    // A callback for the current session must still take the actual stop/failure path.
    await controller.failureHandlerForTesting(sessionID: newID)(ScreenshotRecordingError.writing("当前会话错误")).value
    try sessionExpect(controller.state == .failed && controller.statusMessage.contains("当前会话错误"),
        "会话隔离把当前会话错误也静默丢弃了")

    let successID = try controller.beginIsolatedSessionForTesting()
    let delayedSuccess = DeferredRecordingCheck()
    let successMonitor = Task { @MainActor in
        await controller.monitorOnceForTesting(sessionID: successID, check: { try await delayedSuccess.wait() })
    }
    while !delayedSuccess.entered { await Task.yield() }
    await controller.stop()
    let currentID = try controller.beginIsolatedSessionForTesting()
    let currentMessage = controller.statusMessage
    delayedSuccess.release()
    let oldSuccessResult = await successMonitor.value
    try sessionExpect(!oldSuccessResult && controller.state == .recording && controller.statusMessage == currentMessage,
        "旧 monitor 成功返回后仍向新会话继续写状态或 journal")

    // Cancellation may occur while a source query ignores cancellation and later throws.
    let cancelledCheck = DeferredRecordingCheck()
    let cancelledMonitor = Task { @MainActor in
        await controller.monitorOnceForTesting(sessionID: currentID, check: { try await cancelledCheck.wait() })
    }
    while !cancelledCheck.entered { await Task.yield() }
    cancelledMonitor.cancel()
    cancelledCheck.release(error: ScreenshotRecordingError.sourceUnavailable("已取消查询的迟到错误"))
    let cancelledResult = await cancelledMonitor.value
    try sessionExpect(!cancelledResult && controller.state == .recording,
        "已取消 monitor 的迟到错误仍停止当前会话")
    let currentMonitorResult = await controller.monitorOnceForTesting(sessionID: currentID) {
        throw ScreenshotRecordingError.sourceUnavailable("当前源已丢失")
    }
    try sessionExpect(!currentMonitorResult && controller.state == .failed && controller.statusMessage.contains("当前源已丢失"),
        "当前 monitor 的真实失败未执行停止并保留错误")
    print("RecordingSessionIsolationTests PASS: late writer/recorder errors, old monitor failure/success and cancelled query ignored; current callbacks and source failures stop; no devices/media/UI")
}
#endif
