import AppKit

@MainActor
func runSystemTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SystemControlError.message("系统模块测试失败：\(message)") }
    }
    let primary = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let left = CGRect(x: -1920, y: -175, width: 1920, height: 1055)
    let window = CGRect(x: 200, y: 100, width: 800, height: 500)
    let leftHalf = try WindowGeometry.targetFrame(action: .leftHalf, current: window, visibleFrames: [primary, left])
    try check(leftHalf == CGRect(x: 0, y: 25, width: 720, height: 850), "半屏应避开菜单栏/Dock")
    let leftTop = try WindowGeometry.targetFrame(action: .topLeft, current: CGRect(x: -1500, y: 0, width: 600, height: 400), visibleFrames: [primary, left])
    try check(leftTop == CGRect(x: -1920, y: -175, width: 960, height: 527.5), "负坐标显示器上的四分屏")
    let above = WindowGeometry.accessibilityRect(fromAppKit: CGRect(x: 100, y: 900, width: 800, height: 600), primaryTop: 900)
    try check(above == CGRect(x: 100, y: -600, width: 800, height: 600), "主屏上方显示器坐标转换")
    let moved = try WindowGeometry.targetFrame(action: .nextDisplay, current: window, visibleFrames: [primary, left])
    try check(left.contains(moved), "跨屏后窗口必须位于目标显示器内")
    let previous = try WindowGeometry.targetFrame(action: .previousDisplay, current: moved, visibleFrames: [primary, left])
    try check(abs(previous.minX - window.minX) < 0.01 && abs(previous.minY - window.minY) < 0.01, "跨屏保留相对位置")
    do {
        _ = try WindowGeometry.targetFrame(action: .nextDisplay, current: window, visibleFrames: [primary])
        throw SystemControlError.message("系统模块测试失败：单屏跨屏必须报错")
    } catch SystemControlError.message(let message) where message == "当前只有一个显示器。" {}

    let defaults = InputBinding.defaults
    let decoded = try JSONDecoder().decode([InputBinding].self, from: JSONEncoder().encode(defaults))
    try check(decoded == defaults, "输入规则编解码保留所有字段")
    try check(defaults.filter { $0.trigger == .gesture }.allSatisfy { !$0.enabled }, "绘图手势默认关闭")
    var duplicate = defaults[0]; duplicate.id = UUID()
    try check(InputRules.conflictingIDs(in: [defaults[0], duplicate]).count == 2, "同范围快捷键冲突必须识别")
    var local = defaults[0]; local.id = UUID(); local.appBundleID = "test.editor"; local.actionID = "window.center"
    try check(InputRules.conflictingIDs(in: [defaults[0], local]).isEmpty, "按应用规则可覆盖全局规则")
    let picked = InputRules.match(in: [defaults[0], local], trigger: .hotkey, modifiers: defaults[0].modifiers,
                                  keyCode: 31, appBundleID: "test.editor")
    try check(picked?.id == local.id, "按应用规则优先")
    let global = InputRules.match(in: [defaults[0], local], trigger: .hotkey, modifiers: defaults[0].modifiers,
                                  keyCode: 31, appBundleID: "test.other")
    try check(global?.id == defaults[0].id, "其他应用使用全局规则")
    try check(InputRules.direction(from: .zero, to: CGPoint(x: 20, y: 0)) == nil, "短距离右键拖动不触发手势")
    try check(InputRules.direction(from: .zero, to: CGPoint(x: 90, y: 10)) == "right", "识别超过阈值的明确方向")
    try check(InputRules.direction(from: .zero, to: CGPoint(x: 90, y: 90)) == nil, "模糊对角线手势不误触发")
    let unsafe = InputBinding(trigger: .hotkey, keyCode: 0, modifiers: 0)
    try check(InputRules.validationError(unsafe) != nil, "普通打字键不能单独注册为动作")
    let unsafeGesture = InputBinding(trigger: .gesture, modifiers: 0)
    try check(InputRules.validationError(unsafeGesture) != nil, "绘图手势必须包含 Option")
    print("PASS: 窗口多屏几何、输入规则、冲突和手势阈值")
}
