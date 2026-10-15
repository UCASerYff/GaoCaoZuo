import Foundation

@MainActor func runExtensionLifecycleTests() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-extension-lifecycle-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=OperationStore(directory:root)
    func check(_ value:Bool,_ name:String) throws {if !value {throw DataFailure.message("扩展生命周期检查失败："+name)}}
    try check(store.dataHealthy && !store.clipboard.enabled,"独立资料正常且采集关闭")
    store.update {$0.autoInput.enabled=true;$0.flyKey.enabled=true}
    let settings=root.appendingPathComponent("settings.json")
    var external=try Data(contentsOf:settings);external.append(Data("\n".utf8));try external.write(to:settings)
    var callbacks=0
    var observedDisabled=false
    store.onSettingsChanged={callbacks += 1;observedDisabled = !store.settings.autoInput.enabled && !store.settings.flyKey.enabled && !store.dataHealthy}
    store.update {$0.autoInput.enabled=false;$0.flyKey.enabled=false}
    try check(callbacks == 1 && observedDisabled,"保存冲突仍通知运行时关闭")
    try check(!store.clipboard.enabled && store.error != nil,"故障停止采集并报告")
    try check(try Data(contentsOf:settings) == external,"外部设置内容未被覆盖")
    let first=store.beginCrossApplicationOperation(),second=store.beginCrossApplicationOperation()
    try check(store.crossApplicationBusy,"交接活动状态归属Store")
    store.endCrossApplicationOperation(first)
    try check(store.crossApplicationBusy,"一个任务结束不能清除另一任务")
    store.endCrossApplicationOperation(first)
    try check(store.crossApplicationBusy,"重复释放不能误清活动任务")
    store.endCrossApplicationOperation(second)
    try check(!store.crossApplicationBusy,"全部交接结束才可关闭和退出")
    let activity=GaoActionActivity()
    let outer=activity.begin(),inner=activity.begin()
    activity.end(inner);activity.end(inner)
    try check(activity.isBusy,"嵌套client操作或重复清理不能释放外层任务")
    activity.end(outer)
    try check(!activity.isBusy,"client外层操作完成释放活动状态")
    let cleaner=CleanerController()
    cleaner.canBegin={"等待当前粘贴"}
    cleaner.beginRescueVerification()
    try check(cleaner.state == .idle && cleaner.errorMessage == "等待当前粘贴","粘贴阻止退出键验证且不安装通道")
    cleaner.startCleaning(durationSeconds:30)
    try check(cleaner.state == .idle && !cleaner.needsInputEvents,"粘贴阻止清洁且不创建遮罩")
    print("扩展生命周期定向检查通过：保存失败关闭回调、交接活动令牌、清洁与粘贴互斥；未启动全局监听或GUI。")
}
