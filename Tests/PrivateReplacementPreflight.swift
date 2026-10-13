import Foundation

/// Explicit optional diagnostic: only a verified backup is copied to disposable
/// storage. No input listeners, script execution, keychain reads or live writes.
@MainActor func runPrivateReplacementPreflight(snapshot:URL,payload:URL) throws {
    let fm=FileManager.default
    let root=fm.temporaryDirectory.appendingPathComponent("gaocaozuo-private-migration-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    let isolated=root.appendingPathComponent("Data",isDirectory:true)
    try fm.copyItem(at:snapshot,to:isolated)
    let store=OperationStore(directory:isolated)
    guard store.dataHealthy,!store.settings.clipboardEnabled else {throw DataFailure.message("私有隔离核验前态不可读或采集开关不符，停止。")}
    let beforeRules=store.settings.inputEnhancements.rules.count
    let beforeIDs=Set(store.settings.inputEnhancements.rules.map(\.id))
    let beforeWindow=store.settings.windowEnhancements
    let beforeSnap=store.settings.windowSnapEnabled
    try store.importReplacementSettings(payload)
    let retentionChecks:[String:Bool]=[
        "healthy":store.dataHealthy,"clipboardOff":!store.settings.clipboardEnabled,
        "snap":store.settings.windowSnapEnabled == beforeSnap,
        "restore":store.settings.windowEnhancements.restoreWhenUnsnapped == beforeWindow.restoreWhenUnsnapped,
        "oldRuleIDs":beforeIDs.isSubset(of:Set(store.settings.inputEnhancements.rules.map(\.id))),
        "rulesPaused":store.settings.inputEnhancements.rules.allSatisfy({!$0.enabled}),
        "advancedOff":!store.settings.inputEnhancements.enabled]
    print("Private preflight retention checks: \(retentionChecks)")
    guard store.dataHealthy,!store.settings.clipboardEnabled,
          store.settings.windowSnapEnabled == beforeSnap,
          store.settings.windowEnhancements.restoreWhenUnsnapped == beforeWindow.restoreWhenUnsnapped,
          beforeIDs.isSubset(of:Set(store.settings.inputEnhancements.rules.map(\.id))),
          store.settings.inputEnhancements.rules.allSatisfy({!$0.enabled}),
          !store.settings.inputEnhancements.enabled else {throw DataFailure.message("私有迁移改变了用户采集/窗口/暂停选择或旧规则身份。")}
    let sources=store.settings.inputEnhancements.migrationSources
    let payloadBytes=try ReplacementMigrationSupport.checkedBytes(payload,maximum:32_000_000)
    let parsed=try PropertyListSerialization.propertyList(from:payloadBytes,format:nil) as! [String:Any]
    let input=parsed["input"] as! [String:Any],right=parsed["right"] as! [String:Any]
    let expectedRows=BABRuleImporter.modules.reduce(0) {total,key in total + (input[key] as? [[String:Any]] ?? []).reduce(0) {$0 + ($1["All Rules"] as? [[String:Any]] ?? []).count}}
    let expectedTemplates=(right["newFileList"] as? [[String:Any]] ?? []).count
    guard sources.count == 1,sources[0].rows.count == expectedRows,
          store.fileEnhancements.settings.templates.count == expectedTemplates else {throw DataFailure.message("私有来源规则或模板条目审计数量不符。")}
    let original=try Data(contentsOf:isolated.appendingPathComponent("settings.json"))
    try store.importReplacementSettings(payload)
    guard try Data(contentsOf:isolated.appendingPathComponent("settings.json")) == original else {throw DataFailure.message("私有迁移重复导入改变了设置。")}
    let reloaded=OperationStore(directory:isolated)
    guard reloaded.dataHealthy,reloaded.settings.inputEnhancements.migrationSources[0].rows.count == expectedRows,
          reloaded.fileEnhancements.settings.templates.count == expectedTemplates else {throw DataFailure.message("私有隔离迁移重启不可读。")}
    let states=Dictionary(grouping:sources[0].rows,by:{$0.disposition.rawValue}).mapValues(\.count)
    print("PASS: private verified-snapshot preflight; prior rules \(beforeRules), resulting rules \(store.settings.inputEnhancements.rules.count); source audit \(states); template configurations \(expectedTemplates); user settings retained; repeat/reload passed; disposable copy removed")
}
