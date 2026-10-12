import Foundation

@MainActor func runMigrationTests() throws {
    let fm=FileManager.default
    let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("GaoCaoZuo-Migration-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    let source=root.appendingPathComponent("migration.plist")
    let document:[String:Any]=["schema":1,"right":["commonDirList":[["name":"临时目录","path":root.path]],"shouldAutoOpenNewFile":true,"shouldMergeFinderMenuItems":false],"archive":["cpuUseCount":2,"shouldAppendDateAfterFileNameWhenCompress":true,"shouldExcludeIgnoreFilesWhenCompress":true,"ignoreFilesWhenCompress":[["name":".DS_Store","enable":true]]],"pane":["isUnsnapRestore":false],"input":["ruleOfKeyboard":[["AppName":"All Applications","All Rules":[["Gesture":["keyCode":123,"modifierFlags":524288],"Action":["ActionType":"Preset","Action":"half_of_Left"],"Enable":1,"Note":"测试"]]]]]]
    try PropertyListSerialization.data(fromPropertyList:document,format:.binary,options:0).write(to:source)
    let store=OperationStore(directory:root.appendingPathComponent("Data"))
    let originalFolders=store.settings.folders.count
    try store.importReplacementSettings(source)
    guard store.settings.folders.count==originalFolders+1,store.settings.inputEnhancements.rules.count==1,
          store.settings.inputEnhancements.rules.allSatisfy({!$0.enabled}),!store.settings.clipboardEnabled,
          store.fileEnhancements.settings.autoOpenNew,store.archiveEnhancements.preferences.creation.threads==2,
          store.archiveEnhancements.preferences.creation.ignoredPatterns==[".DS_Store"],!store.finderPreferences.preferences.mergeInSubmenu,
          !store.settings.windowEnhancements.restoreWhenUnsnapped else{throw DataFailure.message("迁移后的配置与暂停状态不符")}
    try store.importReplacementSettings(source)
    guard store.settings.folders.count==originalFolders+1,store.settings.inputEnhancements.rules.count==1 else{throw DataFailure.message("重复迁移产生重复项")}
    let reloaded=OperationStore(directory:store.data.directory)
    guard reloaded.dataHealthy,reloaded.settings.inputEnhancements.rules.count==1,reloaded.fileEnhancements.settings.autoOpenNew else{throw DataFailure.message("迁移配置重启未保留")}
    // Simulate process death after partial cross-file writes and before the commit marker.
    reloaded.update{$0.folders.removeAll();$0.appearance="dark"}
    try reloaded.fileEnhancements.update{$0.autoOpenNew=false}
    let journalURL=reloaded.data.directory.appendingPathComponent("replacement-migration.json")
    var journal=try JSONSerialization.jsonObject(with:Data(contentsOf:journalURL)) as! [String:Any]
    journal["state"]="prepared"
    try JSONSerialization.data(withJSONObject:journal).write(to:journalURL,options:.atomic)
    let recovered=OperationStore(directory:reloaded.data.directory)
    guard recovered.dataHealthy,recovered.settings.folders.isEmpty,recovered.settings.appearance=="system",!recovered.fileEnhancements.settings.autoOpenNew,recovered.archiveEnhancements.preferences.creation.threads==0,recovered.finderPreferences.preferences.mergeInSubmenu else{throw DataFailure.message("中断迁移未恢复完整迁移前配置")}
    // A later retry must not make newer user changes subject to the first attempt's rollback.
    let protectedURLs=[recovered.data.directory.appendingPathComponent("settings.json"),
                       recovered.archiveEnhancements.directory.appendingPathComponent("archive-preferences.json"),
                       recovered.fileEnhancements.data.directory.appendingPathComponent("settings.json"),
                       recovered.finderPreferences.data.directory.appendingPathComponent("finder-menu.json"),journalURL]
    func rejectChangedPrestate() throws {
        let before=try protectedURLs.map{try Data(contentsOf:$0)}
        var rejected=false
        do {try recovered.importReplacementSettings(source)}
        catch {rejected=error.localizedDescription.contains("恢复后的设置已修改")}
        guard rejected,recovered.dataHealthy,try protectedURLs.map({try Data(contentsOf:$0)})==before else {
            throw DataFailure.message("迁移重试未拒绝恢复后修改，或覆盖了当前设置/旧快照")
        }
    }
    recovered.update{$0.appearance="dark"};try rejectChangedPrestate();recovered.update{$0.appearance="system"}
    recovered.archiveEnhancements.preferences.creation.threads=1;try recovered.archiveEnhancements.save()
    try rejectChangedPrestate()
    recovered.archiveEnhancements.preferences.creation.threads=0;try recovered.archiveEnhancements.save()
    try recovered.fileEnhancements.update{$0.autoOpenNew=true};try rejectChangedPrestate()
    try recovered.fileEnhancements.update{$0.autoOpenNew=false}
    var changedMenu=recovered.finderPreferences.preferences;changedMenu.mergeInSubmenu=false
    try recovered.finderPreferences.replaceForMigration(changedMenu);try rejectChangedPrestate()
    changedMenu.mergeInSubmenu=true;try recovered.finderPreferences.replaceForMigration(changedMenu)
    try recovered.importReplacementSettings(source)
    guard recovered.settings.folders.count==1,recovered.settings.inputEnhancements.rules.count==1 else{throw DataFailure.message("中断恢复后无法安全重试迁移")}
    let invalid=root.appendingPathComponent("invalid.plist");try Data("invalid".utf8).write(to:invalid)
    let fresh=OperationStore(directory:root.appendingPathComponent("Untouched"));let before=try Data(contentsOf:fresh.data.directory.appendingPathComponent("settings.json"))
    var rejected=false;do{try fresh.importReplacementSettings(invalid)}catch{rejected=true}
    guard rejected,try Data(contentsOf:fresh.data.directory.appendingPathComponent("settings.json"))==before else{throw DataFailure.message("无效迁移文件覆盖了设置")}
    print("PASS: 配置迁移、重复导入、暂停规则、重启保留、中断恢复、四份恢复后修改拒绝及还原后重试；未执行脚本或读取钥匙串")
}
