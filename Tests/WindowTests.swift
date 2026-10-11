import AppKit

@MainActor
func runWindowFocusTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SystemControlError.message("窗口焦点测试失败：\(message)") }
    }
    let own: pid_t = 100, target: pid_t = 200, unrelated: pid_t = 300
    func expectFailure(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try check(failed, "失效目标或焦点变化应明确失败")
    }

    var foreground: pid_t? = own
    var events: [String] = []
    try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
        frontmostPID: { foreground }, validateTarget: { events.append("validate") },
        raiseTarget: { events.append("raise") },
        activateTarget: { events.append("activate"); foreground = target; return true })
    try check(events == ["validate", "raise", "validate", "activate", "validate", "raise"],
              "激活前后都重新核验并提升同一个窗口")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: own, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise") }, activateTarget: { events.append("activate"); return true })
    }
    try check(events.isEmpty, "不能操作自己的窗口")

    events = []; foreground = unrelated
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise") }, activateTarget: { events.append("activate"); return true })
    }
    try check(events == ["validate"], "用户已切到另一应用时不能抢回焦点")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground },
            validateTarget: { events.append("validate"); throw SystemControlError.message("窗口已关闭") },
            raiseTarget: { events.append("raise") }, activateTarget: { events.append("activate"); return true })
    }
    try check(events == ["validate"], "捕获后目标关闭不得激活同进程的其他窗口")

    events = []; foreground = own
    var alive = true
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground },
            validateTarget: { events.append("validate"); if !alive { throw SystemControlError.message("应用退出") } },
            raiseTarget: { events.append("raise"); alive = false },
            activateTarget: { events.append("activate"); return true })
    }
    try check(!events.contains("activate"), "目标在提升过程中退出不能继续激活")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise"); foreground = unrelated },
            activateTarget: { events.append("activate"); return true })
    }
    try check(!events.contains("activate"), "目标操作期间用户切换应用不能覆盖新选择")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise"); throw SystemControlError.message("不支持 AXRaise") },
            activateTarget: { events.append("activate"); return true })
    }
    try check(!events.contains("activate"), "不支持提升目标窗口时不能随便激活应用中的其他窗口")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise") }, activateTarget: { events.append("activate"); return false })
    }
    try check(events.filter { $0 == "raise" }.count == 1, "系统拒绝激活时明确结束")

    events = []; foreground = own
    try expectFailure {
        try WindowFocusRestoration.perform(targetPID: target, ownPID: own,
            frontmostPID: { foreground }, validateTarget: { events.append("validate") },
            raiseTarget: { events.append("raise") },
            activateTarget: { events.append("activate"); foreground = unrelated; return true })
    }
    try check(events.filter { $0 == "raise" }.count == 1, "激活请求之后用户切走也不得再次提升窗口")
    print("PASS: 窗口精确激活、过期目标、应用切换与不支持窗口的焦点保护")
}
