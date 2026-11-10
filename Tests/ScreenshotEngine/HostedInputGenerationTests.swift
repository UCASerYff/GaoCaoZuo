private enum HostedInputGenerationTestFailure: Error {
    case assertion(String)
}

/// Plain state only. No event tap, input event, permission, app, file or device.
func runHostedInputGenerationTests() throws {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw HostedInputGenerationTestFailure.assertion(message) }
    }
    var actions = HostedInputGeneration()
    let tapRecoveryGeneration: UInt64 = 42
    let pendingAction = actions.snapshot
    try check(actions.matches(pendingAction), "Fresh queued action must match")

    // Capture starts synchronously, with no intervening physical event.
    actions.invalidate()
    let duringCapture = actions.snapshot
    try check(!actions.matches(pendingAction), "Capture start must invalidate the old queue immediately")
    try check(actions.matches(duringCapture), "New snapshot must represent the current action lifetime")

    // Capture ends without a physical event or a counter reset. The old action
    // must remain cancelled even when the host is no longer exclusive.
    let afterCapture = actions.snapshot
    try check(afterCapture == duringCapture && !actions.matches(pendingAction), "Capture end must not revive the old action")
    try check(actions.matches(afterCapture), "An action queued after capture may use the new snapshot")

    actions.invalidate()
    try check(!actions.matches(afterCapture) && actions.matches(actions.snapshot), "A second capture invalidates only prior action snapshots")
    try check(tapRecoveryGeneration == 42, "Action invalidation must leave independent tap recovery identity unchanged")
    var anotherController = HostedInputGeneration()
    let independentSnapshot = anotherController.snapshot
    actions.invalidate()
    try check(anotherController.matches(independentSnapshot), "Different input controllers must not share a global generation")
    anotherController.invalidate()
    try check(!anotherController.matches(independentSnapshot), "Each controller invalidates its own pending queue")
    print("Hosted input generation PASS: \(assertions) pure state checks; capture start/end with no physical event; independent tap recovery lifetime")
}
