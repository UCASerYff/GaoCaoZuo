import Foundation

/// Synthetic policies only: no process enumeration, AX, TCC, window activation, capture or real user data.
func runDesktopOverviewTests() throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard value() else { throw DesktopOverviewError.message("窗口总览测试失败：" + message) }
    }
    func rejects(_ value: DesktopOverviewPreferences) throws {
        do { _ = try value.validated() }
        catch { checks += 1; return }
        throw DesktopOverviewError.message("窗口总览测试失败：无效偏好未被拒绝。")
    }

    let defaults = DesktopOverviewPreferences()
    try check(!defaults.thumbnailsEnabled, "首次使用不启用预览")
    try check(defaults.excludedApplicationBundleIDs.isEmpty && defaults.excludedThumbnailBundleIDs.isEmpty, "默认排除为空")
    var imported = defaults
    imported.groupByApplication = false
    imported.compactChooser = true
    imported.thumbnailsEnabled = true
    imported.statusStripEnabled = true
    imported.excludedThumbnailBundleIDs = ["org.example.Secret"]
    imported.excludedApplicationBundleIDs = ["org.example.Hidden"]
    let roundTrip = try JSONDecoder().decode(DesktopOverviewPreferences.self, from: JSONEncoder().encode(imported))
    try check(roundTrip == imported,
              "迁移的分组、紧凑、预览与排除设置可完整往返")
    _ = try imported.validated()
    for ids in [[""], ["org.example.A", "org.example.A"], ["org.example. A"], ["org.example.\nA"], ["org.example.\u{0}A"], [String(repeating: "a", count: 256)]] {
        var bad = defaults
        bad.excludedThumbnailBundleIDs = ids
        try rejects(bad)
        bad = defaults
        bad.excludedApplicationBundleIDs = ids
        try rejects(bad)
    }
    var tooMany = defaults
    tooMany.excludedApplicationBundleIDs = (0..<257).map { "org.example.App\($0)" }
    try rejects(tooMany)

    try check(DesktopOverviewPolicy.containsQuery(appName: "测试应用", title: "Synthetic Report", bundleID: "org.example.Editor", query: "report 测试"), "多个搜索词均须命中，可跨应用与标题")
    try check(DesktopOverviewPolicy.containsQuery(appName: "测试应用", title: "", bundleID: "org.example.Editor", query: "ORG.example"), "应用入口可按Bundle ID搜索")
    try check(DesktopOverviewPolicy.containsQuery(appName: "A", title: "B", bundleID: "C", query: " \n "), "空白查询显示全部")
    try check(!DesktopOverviewPolicy.containsQuery(appName: "A", title: "B", bundleID: "C", query: "A missing"), "不采用任一词命中放大结果")

    try check(DesktopOverviewPolicy.isFresh(createdAt: 100, now: 100), "新目录可用")
    try check(DesktopOverviewPolicy.isFresh(createdAt: 100, now: 160), "寿命边界可用")
    try check(!DesktopOverviewPolicy.isFresh(createdAt: 100, now: 160.01), "旧目录不能动作或截图")
    try check(!DesktopOverviewPolicy.isFresh(createdAt: 100, now: 99), "时钟倒退拒绝")
    try check(!DesktopOverviewPolicy.isFresh(createdAt: .nan, now: 100), "无效创建时刻拒绝")
    try check(!DesktopOverviewPolicy.isFresh(createdAt: 100, now: .infinity), "无效当前时刻拒绝")

    let rect = CGRect(x: 40, y: 80, width: 800, height: 600)
    let source = DesktopOverviewEvidence(title: "Synthetic", frame: rect)
    let changed = DesktopOverviewEvidence(title: "Other", frame: rect)
    let untitled = DesktopOverviewEvidence(title: "", frame: rect)
    try check(DesktopOverviewPolicy.uniquePreviewMatch(source: source, axPeers: [source, changed], capturePeers: [source]), "唯一PID内标题和几何证据可用于预览")
    try check(!DesktopOverviewPolicy.uniquePreviewMatch(source: source, axPeers: [source, source], capturePeers: [source]), "AX重复证据拒绝预览")
    try check(!DesktopOverviewPolicy.uniquePreviewMatch(source: source, axPeers: [source], capturePeers: [source, source]), "SC重复证据拒绝预览")
    try check(!DesktopOverviewPolicy.uniquePreviewMatch(source: source, axPeers: [changed], capturePeers: [source]), "窗口标题变化不能替代")
    try check(!DesktopOverviewPolicy.uniquePreviewMatch(source: untitled, axPeers: [untitled], capturePeers: [untitled]), "无标题不能映射像素")
    try check(DesktopOverviewPolicy.sameGeometry(rect, rect.offsetBy(dx: 3, dy: -3)), "公开接口的有限几何舍入")
    try check(!DesktopOverviewPolicy.sameGeometry(rect, rect.offsetBy(dx: 4, dy: 0)), "超出容差拒绝")
    try check(!DesktopOverviewPolicy.sameGeometry(.zero, .zero), "零面积不构成预览证据")
    try check(!DesktopOverviewPolicy.sameGeometry(rect, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)), "非有限几何拒绝")

    var allowedStates = 0
    for mask in 0..<128 {
        let active = mask & 1 != 0, explicit = mask & 2 != 0, enabled = mask & 4 != 0
        let screen = mask & 8 != 0, ax = mask & 16 != 0, secure = mask & 32 != 0, excluded = mask & 64 != 0
        let allowed = DesktopOverviewPolicy.previewAllowed(sessionActive: active, explicitlyRequested: explicit, enabled: enabled,
            screenAuthorized: screen, accessibilityAuthorized: ax, secureInput: secure, excluded: excluded)
        try check(allowed == (active && explicit && enabled && screen && ax && !secure && !excluded), "会话、显式点击、设置、两种权限、安全输入与排除共同控制像素读取")
        if allowed { allowedStates += 1 }
    }
    try check(allowedStates == 1, "授权或迁移旧true均不能代替当前会话显式点击")
    try check(DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: 1, layer: 0, frame: rect), "仅在屏幕内的正常不透明窗口可预览")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: false, alpha: 1, layer: 0, frame: rect), "离屏拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: 0.99, layer: 0, frame: rect), "透明拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: nil, layer: 0, frame: rect), "不明透明度拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: .nan, layer: 0, frame: rect), "无效透明度拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: 2, layer: 0, frame: rect), "超出规范的透明度拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: 1, layer: 1, frame: rect), "系统浮层拒绝")
    try check(!DesktopOverviewPolicy.eligibleScreenWindow(onScreen: true, alpha: 1, layer: nil, frame: rect), "未知层拒绝")

    var countBudget = DesktopOverviewPreviewBudget()
    for _ in 0..<12 { try check(countBudget.reserve(pixels: 640*400), "12张内可预留") }
    try check(!countBudget.reserve(pixels: 1) && countBudget.count == 12, "数量预算不会因额外请求增加")
    var pixelsBudget = DesktopOverviewPreviewBudget()
    try check(pixelsBudget.reserve(pixels: 6_000_000), "像素预算边界")
    try check(!pixelsBudget.reserve(pixels: 1) && pixelsBudget.pixels == 6_000_000, "像素预算不越界")
    var invalidBudget = DesktopOverviewPreviewBudget()
    try check(!invalidBudget.reserve(pixels: Int.max) && !invalidBudget.reserve(pixels: 0) && !invalidBudget.reserve(pixels: -1), "无效或溢出像素请求不能修改预算")
    try check(invalidBudget.count == 0 && invalidBudget.pixels == 0, "拒绝时保留预算")

    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let strip = DesktopOverviewStatusStripGeometry(frame: screen, visibleFrame: visible, topInset: 38, menuBarHeight: 24)
    let stripFrame = strip.panelFrame()
    try check(stripFrame != nil && stripFrame!.maxY <= screen.maxY-38-8, "自有状态条位于菜单与顶部安全区域下方")
    try check(stripFrame.map { visible.contains($0) } == true, "状态条保留在当前可见区域内")
    try check(strip.panelFrame(size: CGSize(width: 2000, height: 30)) == nil, "区域不足隐藏状态条")
    try check(strip.panelFrame(margin: -1) == nil, "非法边距拒绝")
    try check(DesktopOverviewStatusStripGeometry(frame: .zero, visibleFrame: .zero, topInset: 0, menuBarHeight: 24).panelFrame() == nil, "没有屏幕区域不生成窗口")
    try check(DesktopOverviewStatusStripGeometry(frame: screen, visibleFrame: visible, topInset: .nan, menuBarHeight: 24).panelFrame() == nil, "无效安全区域拒绝")
    print("DesktopOverviewTests: \(checks) synthetic policy checks passed; no AX/TCC/capture/GUI calls")
}
