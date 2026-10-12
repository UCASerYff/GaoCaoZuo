import Foundation
import Darwin

/// Restores one captured window's focus. An accepted activation request is not a completed activation.
/// The backend and clock are injectable so tests never activate or move the user's real windows.
@MainActor
enum WindowFocusTransaction {
    static func perform(targetPID: pid_t, ownPID: pid_t, allowedInitialPID: pid_t? = nil,
                        frontmostPID: () -> pid_t?, validateTarget: () throws -> Void,
                        isTargetFocused: () throws -> Bool, raiseTarget: () throws -> Void,
                        activateTarget: () -> Bool, isCancelled: () -> Bool = { false },
                        timeout: TimeInterval = 0.8, pollInterval: TimeInterval = 0.04,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: (TimeInterval) async throws -> Void = { interval in
                            try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded(.up)))
                        }) async throws {
        guard targetPID > 0, ownPID > 0, targetPID != ownPID else {
            throw SystemControlError.message("不能将搞操作自己的窗口或失效进程作为本次操作目标。")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 5,
              pollInterval.isFinite, pollInterval >= 0.001, pollInterval <= timeout else {
            throw SystemControlError.message("窗口焦点等待参数无效。")
        }
        let started = now()
        guard started.isFinite else { throw SystemControlError.message("无法读取窗口焦点等待时钟。") }
        let deadline = started + timeout
        let maximumWaits = Int(ceil(timeout / pollInterval)) + 1
        var activationRequested = false
        var observedTargetActive = false
        var raisedAfterActivation = false

        func timedOut() -> SystemControlError {
            .message("未能确认原目标窗口获得焦点，已停止窗口布局。请先切回目标窗口再重试。")
        }
        func checkCancellation() throws {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
        }
        func timeRemaining() throws -> TimeInterval {
            let time = now()
            guard time.isFinite, time >= started else {
                throw SystemControlError.message("窗口焦点等待时钟无效。")
            }
            let remaining = deadline - time
            guard remaining > 0 else { throw timedOut() }
            return remaining
        }
        @discardableResult
        func validate() throws -> pid_t {
            try checkCancellation()
            _ = try timeRemaining()
            try validateTarget() // The caller checks the captured AX element and original app identity.
            try checkCancellation()
            _ = try timeRemaining()
            guard let front = frontmostPID(), front > 0 else {
                throw SystemControlError.message("无法确认前台应用，已停止恢复窗口焦点。")
            }
            if activationRequested, front == targetPID { observedTargetActive = true }
            // Before activation completes, the original foreground app may still be active.
            // Once the target becomes active, leaving it is a new user choice and must not be overridden.
            let allowed = observedTargetActive ? front == targetPID
                : front == targetPID || front == ownPID || front == allowedInitialPID
            guard allowed else {
                throw SystemControlError.message("前台应用已变化，已停止切换窗口；请重新选择需要操作的窗口。")
            }
            try checkCancellation()
            _ = try timeRemaining()
            return front
        }

        try validate()
        try raiseTarget()
        try validate()
        let accepted = activateTarget()
        try checkCancellation()
        guard accepted else {
            throw SystemControlError.message("系统拒绝激活目标应用，已停止窗口布局。请先切回目标窗口再重试。")
        }
        activationRequested = true

        for attempt in 0...maximumWaits {
            let front = try validate()
            if front == targetPID {
                // Activation can select another window. Raise this captured window exactly once more.
                if !raisedAfterActivation {
                    try raiseTarget()
                    raisedAfterActivation = true
                    try validate()
                }
                let focused = try isTargetFocused()
                // Reading focus can itself involve IPC; recheck cancellation, identity and foreground afterward.
                let finalFront = try validate()
                if focused, finalFront == targetPID { return }
            }
            guard attempt < maximumWaits else { throw timedOut() }
            let remaining = try timeRemaining()
            try checkCancellation()
            try await pause(min(pollInterval, remaining))
            // The next iteration validates before doing any more AX work.
        }
        throw timedOut()
    }
}
