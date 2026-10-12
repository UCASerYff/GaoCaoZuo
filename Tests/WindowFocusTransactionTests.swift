import Foundation
import Darwin

@MainActor
private final class WindowFocusFixture {
    let own: pid_t = 100, target: pid_t = 200, other: pid_t = 300
    var front: pid_t? = 100
    var focused = true
    var valid = true
    var cancelled = false
    var clock: TimeInterval = 0
    var raises = 0, activations = 0, focusReads = 0, validations = 0, pauses = 0
    var waits: [TimeInterval] = []
    var onRaise: (() throws -> Void)?
    var onActivate: (() -> Bool)?
    var onFocus: (() throws -> Bool)?
    var onPause: (() throws -> Void)?
    var onValidate: (() throws -> Void)?

    func perform(allowedInitialPID: pid_t? = nil, targetPID: pid_t? = nil) async throws {
        try await WindowFocusTransaction.perform(targetPID: targetPID ?? target, ownPID: own,
            allowedInitialPID: allowedInitialPID,
            frontmostPID: { self.front },
            validateTarget: {
                self.validations += 1
                try self.onValidate?()
                guard self.valid else { throw SystemControlError.message("捕获窗口或应用身份已失效") }
            },
            isTargetFocused: {
                self.focusReads += 1
                return try self.onFocus?() ?? self.focused
            },
            raiseTarget: { self.raises += 1; try self.onRaise?() },
            activateTarget: { self.activations += 1; return self.onActivate?() ?? true },
            isCancelled: { self.cancelled }, now: { self.clock },
            pause: { interval in
                self.pauses += 1; self.waits.append(interval); self.clock += interval
                try self.onPause?()
            })
    }
}

@MainActor
func runWindowFocusTransactionTests() async throws {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw SystemControlError.message("窗口异步焦点测试失败：" + message) }
    }
    func failure(_ operation: () async throws -> Void) async throws -> Error {
        do { try await operation() }
        catch { return error }
        throw SystemControlError.message("窗口异步焦点测试失败：应该明确失败而没有失败")
    }

    do {
        let f = WindowFocusFixture()
        f.onPause = { if f.pauses == 3 { f.front = f.target } }
        try await f.perform()
        try check(f.pauses == 3 && f.raises == 2 && f.activations == 1,
                  "延迟激活应等待真实前台变化，且只发送一次激活、两次提升")
        try check(f.focusReads == 1 && f.waits.allSatisfy { abs($0 - 0.04) < 0.000001 },
                  "每40ms检查，只在目标真正到前台后读取其窗口焦点")
    }
    do {
        let f = WindowFocusFixture()
        let error = try await failure { try await f.perform() }
        try check(error.localizedDescription.contains("未能确认"), "激活获准但本app一直在前台必须超时失败")
        try check(f.raises == 1 && f.activations == 1 && f.focusReads == 0,
                  "未实际激活不能反复提升、不能误认目标窗口焦点")
        try check(f.clock <= 0.800001 && f.pauses <= 21, "等待有明确时间与次数预算")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target; f.focused = false
        _ = try await failure { try await f.perform() }
        try check(f.raises == 2 && f.focusReads > 1, "同一应用中的其他窗口有焦点也不能算成功或反复抢焦点")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target; f.focused = false
        f.onPause = { if f.pauses == 2 { f.focused = true } }
        try await f.perform()
        try check(f.pauses == 2 && f.raises == 2, "捕获窗口的焦点可在一次提升后延迟生效")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target
        try await f.perform()
        try check(f.pauses == 0 && f.focusReads == 1, "已在目标窗口时无须无意义等待")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.other
        _ = try await failure { try await f.perform() }
        try check(f.raises == 0 && f.activations == 0, "最初已经是第三个应用时不得执行提升或激活")
    }
    do {
        let f = WindowFocusFixture()
        f.onRaise = { f.front = f.other }
        _ = try await failure { try await f.perform() }
        try check(f.raises == 1 && f.activations == 0, "提升期间用户切应用，激活之前必须停止")
    }
    do {
        let f = WindowFocusFixture()
        f.onActivate = { f.front = f.other; return true }
        _ = try await failure { try await f.perform() }
        try check(f.raises == 1 && f.pauses == 0, "激活回调返回true但第三app在前台必须立即停止")
    }
    do {
        let f = WindowFocusFixture()
        f.onPause = { f.front = f.other }
        _ = try await failure { try await f.perform() }
        try check(f.pauses == 1 && f.raises == 1 && f.focusReads == 0,
                  "等待中切到第三app，下一次检查不能继续提升")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target
        f.onFocus = { f.front = f.other; return true }
        _ = try await failure { try await f.perform() }
        try check(f.focusReads == 1, "读取焦点期间前台变化，即使读回true也不能报成功")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.other
        f.onPause = { if f.pauses == 2 { f.front = f.target } }
        try await f.perform(allowedInitialPID: f.other)
        try check(f.pauses == 2 && f.focusReads == 1, "显式鼠标目标允许最初前台来源，但成功仍须真实目标前台")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.other
        _ = try await failure { try await f.perform(allowedInitialPID: f.other) }
        try check(f.focusReads == 0, "允许的最初来源一直留在前台不能假装激活成功")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.other; f.focused = false
        f.onPause = { f.front = f.pauses == 1 ? f.target : f.other }
        _ = try await failure { try await f.perform(allowedInitialPID: f.other) }
        try check(f.pauses == 2 && f.raises == 2,
                  "已经观察到目标前台后返回最初来源属于新选择，不得再提升")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target; f.focused = false
        f.onPause = { f.front = f.own }
        _ = try await failure { try await f.perform() }
        try check(f.pauses == 1 && f.raises == 2, "目标激活后用户返回本app也应停止恢复，不覆盖新选择")
    }
    do {
        let f = WindowFocusFixture(); f.valid = false
        _ = try await failure { try await f.perform() }
        try check(f.raises == 0 && f.activations == 0, "失效捕获窗口不能开始操作")
    }
    do {
        let f = WindowFocusFixture()
        f.onPause = { f.valid = false }
        _ = try await failure { try await f.perform() }
        try check(f.pauses == 1 && f.raises == 1 && f.focusReads == 0,
                  "等待后目标身份失效时不得继续对新进程或窗口操作")
    }
    do {
        let f = WindowFocusFixture(); f.cancelled = true
        let error = try await failure { try await f.perform() }
        try check(error is CancellationError && f.validations == 0 && f.raises == 0,
                  "事务代数取消在任何AX读取之前生效")
    }
    do {
        let f = WindowFocusFixture()
        f.onValidate = { f.cancelled = true }
        let error = try await failure { try await f.perform() }
        try check(error is CancellationError && f.raises == 0, "身份检查期间取消不能漏过到写入")
    }
    do {
        let f = WindowFocusFixture()
        f.onPause = { f.cancelled = true; f.front = f.target }
        let error = try await failure { try await f.perform() }
        try check(error is CancellationError && f.raises == 1 && f.focusReads == 0,
                  "跨await取消必须先于下一次提升和焦点确认")
    }
    do {
        let f = WindowFocusFixture()
        f.onActivate = { f.cancelled = true; return false }
        let error = try await failure { try await f.perform() }
        try check(error is CancellationError && f.raises == 1 && f.pauses == 0,
                  "激活请求期间取消，不能把取消误报成系统拒绝")
    }
    do {
        let f = WindowFocusFixture(); f.front = f.target
        f.onFocus = { f.cancelled = true; return true }
        let error = try await failure { try await f.perform() }
        try check(error is CancellationError, "最终焦点读取期间取消不能报成功")
    }
    do {
        let f = WindowFocusFixture(); f.onActivate = { false }
        _ = try await failure { try await f.perform() }
        try check(f.raises == 1 && f.pauses == 0, "系统拒绝激活立即明确失败")
    }
    do {
        let f = WindowFocusFixture(); f.front = nil
        _ = try await failure { try await f.perform() }
        try check(f.raises == 0 && f.activations == 0, "无法读取前台应用时不能执行操作")
    }
    do {
        let f = WindowFocusFixture()
        _ = try await failure { try await f.perform(targetPID: f.own) }
        try check(f.validations == 0 && f.raises == 0, "本app不能作为捕获目标")
    }
    do {
        let f = WindowFocusFixture()
        f.onPause = { f.clock = .nan }
        _ = try await failure { try await f.perform() }
        try check(f.pauses == 1 && f.raises == 1, "无效等待时钟必须失败而非无限等待")
    }
    do {
        let f = WindowFocusFixture()
        f.onPause = { f.clock = 0 }
        _ = try await failure { try await f.perform() }
        try check(f.pauses <= 21 && f.raises == 1, "注入时钟不前进时，次数预算仍能终止等待")
    }
    do {
        let f = WindowFocusFixture()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.perform()
        }
        let error = try await failure { try await task.value }
        try check(error is CancellationError && f.validations == 0 && f.raises == 0,
                  "Swift Task原生取消在事务入口得到执行")
    }
    print("PASS: 窗口异步焦点事务 \(assertions) 项断言（延迟激活、真实窗口、前台变化、失效与取消）")
}
