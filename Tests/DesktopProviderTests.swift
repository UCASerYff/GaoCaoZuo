import Foundation

@MainActor func runDesktopProviderTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaocaozuo-desktop-provider-" + UUID().uuidString + ".noindex", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func check(_ value: Bool, _ message: String) throws { guard value else { throw DataFailure.message(message) }; checks += 1 }
    func rejected(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw DataFailure.message(message)
    }
    let path = root.appendingPathComponent("data", isDirectory: true)
    let j = try DesktopProviderJournal(directory: path)
    let source = root.appendingPathComponent("source/Exchange/Outgoing", isDirectory: true)
    let package = try GaoActionV1.createRequestPackage(in: source, action: "windows.overview", targetBundleID: GaoActionV1.ownBundleID, sourceBundleID: "org.example.PublicCaller")
    let staged = try GaoActionV1.stagePackage(at: package, in: root.appendingPathComponent("incoming"))
    try j.receive(staged)
    try check(j.records.count == 1 && j.records[0].phase == .received, "接收不应执行窗口动作")
    try j.receive(staged)
    try check(j.records.count == 1, "同摘要重复接收必须幂等")
    try rejected("同ID异摘要必须拒绝") { _ = try j.existing(staged.manifest, digest: String(repeating: "a", count: 64)) }
    try j.begin(staged.manifest.requestID)
    let recovered = try DesktopProviderJournal(directory: path)
    try check(recovered.records[0].phase == .interrupted, "执行意图中断不能自动重放")
    try rejected("中断不能再次执行") { try recovered.begin(staged.manifest.requestID) }
    let settingsPackage = try GaoActionV1.createRequestPackage(in: source, action: "desktop.openSettings", targetBundleID: GaoActionV1.ownBundleID, sourceBundleID: "org.example.PublicCaller")
    let settingsStage = try GaoActionV1.stagePackage(at: settingsPackage, in: root.appendingPathComponent("incoming"))
    try recovered.receive(settingsStage); try recovered.finish(settingsStage.manifest.requestID, outcome: .cancelled)
    let result = try recovered.result(settingsStage.manifest.requestID)
    let header = try GaoActionV1.inspectManifest(at: result, expectedTarget: "org.example.PublicCaller")
    try check(header.manifest.sourceBundleID == GaoActionV1.ownBundleID && header.manifest.status == .cancelled && header.manifest.inReplyTo == settingsStage.manifest.requestID, "新owner取消结果关联")
    try rejected("取消不能重新执行") { try recovered.begin(settingsStage.manifest.requestID) }
    let successPackage = try GaoActionV1.createRequestPackage(in: source, action: "windows.overview", targetBundleID: GaoActionV1.ownBundleID, sourceBundleID: "org.example.PublicCaller")
    let successStage = try GaoActionV1.stagePackage(at: successPackage, in: root.appendingPathComponent("incoming"))
    try recovered.receive(successStage); try recovered.begin(successStage.manifest.requestID); try recovered.finish(successStage.manifest.requestID, outcome: .completed)
    let done = try GaoActionV1.inspectManifest(at: recovered.result(successStage.manifest.requestID))
    try check(done.manifest.provenance?["interfaceOpened"]?.value as? Bool == true && done.manifest.provenance?["windowsModified"]?.value as? Bool == false, "完成仅声明界面打开")
    for (action, owner) in [("windows.overview", GaoActionV1.ownBundleID), ("desktop.openSettings", GaoActionV1.ownBundleID), ("files.search", "com.gaoseries.GaoWenJian"), ("files.choose", "com.gaoseries.GaoWenJian"), ("files.reveal", "com.gaoseries.GaoWenJian"), ("associations.manage", "com.gaoseries.GaoWenJian"), ("downloads.prepare", "cn.mendao.launcher")] {
        try check(GaoActionV1.owners[action] == owner, "动作owner必须为新的唯一接收方")
    }
    var legacy = staged.manifest; legacy.targetBundleID = "com.gaoseries.GaoZhuoMian"
    try rejected("旧owner不应继续执行新请求") { try GaoActionV1.validateManifest(legacy) }
    var unexpected = staged.manifest; unexpected.parameters = ["close": .init(true)]
    try rejected("外部请求不能注入窗口控制参数") { try GaoActionV1.validateManifest(unexpected) }
    let marker = path.appendingPathComponent("desktop-provider-initialization.json")
    try FileManager.default.removeItem(at: marker)
    try rejected("初始化依据缺失不得空白重建") { _ = try DesktopProviderJournal(directory: path) }
    try check(!FileManager.default.fileExists(atPath: marker.path), "缺失依据必须保持不被覆盖")
    print("Desktop provider canonical/确认/幂等/中断/取消定向检查通过：\(checks)")
}
