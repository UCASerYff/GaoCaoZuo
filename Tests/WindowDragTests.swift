import AppKit

@MainActor
func runWindowDragTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SystemControlError.message("窗口拖动测试失败：\(message)") }
    }
    let initial = CGRect(x: 200, y: 150, width: 800, height: 500)
    let start = CGPoint(x: 400, y: 250)
    let pointer = CGPoint(x: -120, y: 90)
    let translated = WindowDragGeometry.translatedFrame(initialFrame: initial, initialPointer: start, pointer: pointer)
    try check(translated == CGRect(x: -320, y: -10, width: 800, height: 500), "跨屏/负坐标使用初始 frame 加总位移")
    let returning = WindowDragGeometry.translatedFrame(initialFrame: initial, initialPointer: start, pointer: start)
    try check(returning == initial, "回到鼠标起点没有累计漂移")
    try check(!WindowDragGeometry.isWindowDrag(initialFrame: initial, currentFrame: initial, initialPointer: start, pointer: pointer), "仅选中文本或拖动文件不改变窗口，因此不触发吸附")
    try check(!WindowDragGeometry.isWindowDrag(initialFrame: initial, currentFrame: initial.offsetBy(dx: 2, dy: 2), initialPointer: start, pointer: pointer), "窗口轻微抖动不算拖动")
    let resized = CGRect(x: initial.minX - 100, y: initial.minY, width: initial.width + 100, height: initial.height)
    try check(!WindowDragGeometry.isWindowDrag(initialFrame: initial, currentFrame: resized, initialPointer: start, pointer: pointer), "拖动左边框调整尺寸不能触发吸附")
    try check(WindowDragGeometry.isWindowDrag(initialFrame: initial, currentFrame: translated, initialPointer: start, pointer: pointer), "实际窗口移动可以触发吸附")

    let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let topClamped = WindowDragGeometry.keepingTitleBarAccessible(CGRect(x: 300, y: -200, width: 800, height: 500), in: visible)
    try check(topClamped.minY == visible.minY && topClamped.width == 800, "顶部系统边界保留标题栏，不因预期边界限制中断吸附")
    let cases: [(CGPoint, WindowAction?)] = [
        (CGPoint(x: 2, y: 300), .leftHalf),
        (CGPoint(x: 1438, y: 300), .rightHalf),
        (CGPoint(x: 700, y: 2), .maximize),
        (CGPoint(x: 2, y: 2), .topLeft),
        (CGPoint(x: 1438, y: 2), .topRight),
        (CGPoint(x: 2, y: 898), .bottomLeft),
        (CGPoint(x: 1438, y: 898), .bottomRight),
        (CGPoint(x: 700, y: 898), nil),
        (CGPoint(x: 100, y: 300), nil),
        (CGPoint(x: 1500, y: 300), nil)
    ]
    for (point, action) in cases {
        let target = WindowDragGeometry.snapTarget(pointer: point, visibleFrames: [visible], screenFrames: [full])
        try check(target?.action == action, "边缘/四角目标错误：\(point)")
        if let target {
            let frame = try WindowGeometry.targetFrame(action: target.action, current: initial, visibleFrames: [target.visibleFrame])
            try check(visible.contains(frame), "最终吸附 frame 不得覆盖菜单栏和 Dock")
        }
    }
    let external = CGRect(x: -1920, y: -175, width: 1920, height: 1055)
    let externalFull = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    let onExternal = WindowDragGeometry.snapTarget(pointer: CGPoint(x: -1915, y: 100),
                                                   visibleFrames: [visible, external], screenFrames: [full, externalFull])
    try check(onExternal?.action == .leftHalf && onExternal?.visibleFrame == external, "按鼠标所在显示器吸附，不沿用原窗口所在显示器")

    var settings = OperationSettings()
    try check(!settings.windowDragEnabled && !settings.windowSnapEnabled, "新增功能默认全部关闭")
    settings.windowDragEnabled = true; settings.windowSnapEnabled = true
    let encoded = try JSONEncoder().encode(settings)
    let roundtrip = try JSONDecoder().decode(OperationSettings.self, from: encoded)
    try check(roundtrip.windowDragEnabled && roundtrip.windowSnapEnabled, "用户选择可以保存")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    legacy.removeValue(forKey: "windowDragEnabled"); legacy.removeValue(forKey: "windowSnapEnabled")
    let migrated = try JSONDecoder().decode(OperationSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(!migrated.windowDragEnabled && !migrated.windowSnapEnabled && migrated.favorites == settings.favorites,
              "旧配置新增开关关闭，其他用户配置不重置")
    print("PASS: 窗口拖动总位移、真实移动判定、边缘/四角/跨屏吸附与关闭默认值")
}
