import Foundation

/// Exercises the production final-capture policy with separate foreground and
/// pointer targets. No AX objects, windows, permission queries or events are used.
func runWindowTargetModeTests() throws {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw SystemControlError.message("窗口目标模式回归失败：" + message) }
    }

    let cases: [(InputWindowTargetMode, Bool, String)] = [
        (.inheritSettings, false, "foreground"),
        (.inheritSettings, true, "pointer"),
        (.frontmost, false, "foreground"),
        (.frontmost, true, "foreground"),
        (.underPointer, false, "pointer"),
        (.underPointer, true, "pointer")
    ]
    for (mode, global, expected) in cases {
        var captures = 0
        let result = WindowExecutionTargetPolicy.capture(mode: mode, configuredUnderPointer: global) { pointer in
            captures += 1
            return pointer ? "pointer" : "foreground"
        }
        try check(result == expected, "显式选择必须优先于相反的全局设置")
        try check(captures == 1, "每次执行必须真正捕获一次，不能使用旧选择或二次回落")
    }

    var foreground = "first foreground"
    let first = WindowExecutionTargetPolicy.capture(configuredUnderPointer: false) { pointer in
        pointer ? "pointer" : foreground
    }
    foreground = "new foreground"
    let second = WindowExecutionTargetPolicy.capture(configuredUnderPointer: false) { pointer in
        pointer ? "pointer" : foreground
    }
    try check(first != second && second == foreground, "普通快捷键默认仍在每次执行重新获取当前目标")

    let changedDefault = WindowExecutionTargetPolicy.capture(configuredUnderPointer: true) { pointer in
        pointer ? "new pointer" : foreground
    }
    try check(changedDefault == "new pointer", "继承模式使用本次全局设置，不固定首次设置")

    var attempted: [Bool] = []
    let missing: String? = WindowExecutionTargetPolicy.capture(mode: .underPointer, configuredUnderPointer: false) { pointer in
        attempted.append(pointer)
        return pointer ? nil : foreground
    }
    try check(missing == nil && attempted == [true], "明确鼠标目标缺失时不能偷偷回退到前台窗口")

    attempted = []
    let unavailable: String? = WindowExecutionTargetPolicy.capture(mode: .frontmost, configuredUnderPointer: true) { pointer in
        attempted.append(pointer)
        return pointer ? "pointer" : nil
    }
    try check(unavailable == nil && attempted == [false], "明确前台目标缺失时不能偷偷改用鼠标窗口")
    print("窗口目标模式定向检查通过（\(assertions)项）；未创建窗口、读取AX或发送事件。")
}
