import Foundation

@MainActor
func ScreenshotRunRecordingHostGateTests(in root: URL) async throws {
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ScreenshotAppIssue.message("Recording host gate: " + message) }
    }
    let controller = ScreenshotRecordingController()
    var checks = 0
    var willStartCalls = 0
    controller.onWillStart = { willStartCalls += 1 }
    controller.startBlockingReason = { checks += 1; return "宿主有未完成的粘贴事务" }
    let output = root.appendingPathComponent("must-not-create.mov")
    let invalid = ScreenshotRecordingConfiguration(outputURL: output)
    await controller.start(configuration: invalid)
    try check(checks == 1 && willStartCalls == 0 && !controller.isActive && controller.lastError == "宿主有未完成的粘贴事务", "block before will-start callback, invalid configuration, permissions or resources")
    try check(controller.statusMessage == controller.lastError && controller.recoveryURL == nil && !FileManager.default.fileExists(atPath: output.path), "blocked start has an honest reason and no output/journal")
    #if RECORDING_SESSION_TESTS
    _ = try controller.beginIsolatedSessionForTesting()
    let before = controller.statusMessage
    await controller.start(configuration: invalid)
    try check(checks == 1 && willStartCalls == 0 && controller.state == .recording && controller.statusMessage == before, "second blocked start must not inspect the gate, notify will-start or interrupt an active session")
    await controller.stop()
    #endif
    controller.startBlockingReason = { checks += 1; return nil }
    // Missing capture source fails pure configuration validation, before any
    // screen/microphone preflight, device construction or journal creation.
    await controller.start(configuration: invalid)
    try check(checks == 2 && willStartCalls == 1 && controller.state == .failed && controller.lastError != nil, "allowed start notifies synchronously before pure configuration rejection")
    try check(controller.recoveryURL == nil && !FileManager.default.fileExists(atPath: output.path), "configuration rejection does not create output or recovery data")
    print("Screenshot recording host gate PASS; no capture, sound device or permission API")
}
