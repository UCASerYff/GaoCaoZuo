import Foundation

/// Only a caller-created system-temporary copy is accepted. No application is
/// launched and the test does not configure the global input controllers.
@MainActor func runUpgradeCopyCheck(directory:URL) throws {
    func localPath(_ url:URL)->String {
        let value=url.standardizedFileURL.path
        return value.hasPrefix("/tmp/") ? "/private"+value : value
    }
    let path=localPath(directory)
    guard path.hasPrefix("/private/tmp/GaoCaoZuo-upgrade-"),localPath(directory.resolvingSymlinksInPath()) == path else {throw DataFailure.message("升级资料核验只接受系统临时目录中的独立副本")}
    let settingsURL=directory.appendingPathComponent("settings.json")
    let receiptsURL=directory.appendingPathComponent("receipts.json")
    let beforeSettings=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
    let beforeReceipts=try JSONSerialization.jsonObject(with:Data(contentsOf:receiptsURL))
    guard beforeSettings["clipboardEnabled"] as? Bool == false else {throw DataFailure.message("此离线核验不启动剪贴板采集，不能用开启状态的副本运行")}
    let baseline=try LocalData(directory:directory,createIfMissing:false).load("settings.json",as:OperationSettings.self)!
    let store=OperationStore(directory:directory)
    guard store.dataHealthy,store.clipboard.enabled == false,!store.settings.autoInput.enabled,!store.settings.flyKey.enabled else {throw DataFailure.message("升级副本资料保护或默认采集状态不符")}
    let afterSettings=try JSONSerialization.jsonObject(with:Data(contentsOf:settingsURL)) as! [String:Any]
    func canonical(_ value:Any) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys])}
    for (key,value) in beforeSettings {
        guard let actual=afterSettings[key],try canonical(value) == canonical(actual) else {throw DataFailure.message("升级改变了已有设置字段："+key)}
    }
    let afterReceipts=try JSONSerialization.jsonObject(with:Data(contentsOf:receiptsURL))
    guard try canonical(beforeReceipts) == canonical(afterReceipts),store.settings.bindings == baseline.bindings,
          store.settings.inputEnhancements == baseline.inputEnhancements,
          store.settings.snippets == baseline.snippets,
          Set(store.snippetLibrary.snippets.map(\.id)) == Set(baseline.snippets.map(\.id)) else {throw DataFailure.message("升级副本记录或旧短语UUID未保留")}
    print("真实资料独立副本升级核验通过：旧设置全部字段、输入绑定、暂停状态、旧短语UUID和\(store.receipts.count)条恢复记录保留；未启动App、采集或全局输入监听。")
}
