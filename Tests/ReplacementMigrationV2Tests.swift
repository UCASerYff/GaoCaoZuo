import Foundation

@MainActor func runReplacementMigrationV2Tests() throws {
    let fm=FileManager.default
    let root=fm.temporaryDirectory.appendingPathComponent("gaocaozuo-migration-v2-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    let resources=root.appendingPathComponent("Backup/Files/Applications/iRightMouse Pro.app/Contents/Resources",isDirectory:true)
    try fm.createDirectory(at:resources,withIntermediateDirectories:true)
    let info:[String:Any]=["CFBundleIdentifier":"cn.better365.iRightMousePro","CFBundleShortVersionString":"1.00"]
    try PropertyListSerialization.data(fromPropertyList:info,format:.binary,options:0).write(to:resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    let original=Data("original private blank template\n".utf8)
    try original.write(to:resources.appendingPathComponent("TXT.txt"))
    let input:[String:Any]=["ruleOfKeyboard":[["AppName":"All Applications","All Rules":[["Gesture":["keyCode":123,"modifierFlags":524288],"Action":["ActionType":"Preset","Action":"half_of_Left"],"Enable":1,"Note":"source rule"]]]]]
    let legacy:[String:Any]=["schema":1,"right":["shouldAutoOpenNewFile":false],"archive":[:],"pane":["isUnsnapRestore":false],"input":input]
    let first=root.appendingPathComponent("legacy.plist")
    try PropertyListSerialization.data(fromPropertyList:legacy,format:.binary,options:0).write(to:first)
    let store=OperationStore(directory:root.appendingPathComponent("Data"))
    try store.importReplacementSettings(first)
    let ruleID=store.settings.inputEnhancements.rules[0].id
    store.update{$0.windowSnapEnabled=true;$0.windowEnhancements.restoreWhenUnsnapped=true}
    try store.fileEnhancements.update{$0.autoOpenNew=true}
    let right:[String:Any]=["newFileList":[["name":"私有空白文档","suffix":"txt","enable":true,"mainMenu":true]],"toolboxList":[],"fileIconList":[],"shouldAutoOpenNewFile":false,
                          "commonDirList":[["name":"","path":"~/Music"]],"sendFileToDirList":[["name":"","path":"~/Music"],["name":"","path":"~/Pictures"]]]
    let source:[String:Any]=["schema":2,"right":right,"archive":[:],"pane":["isUnsnapRestore":false,"isDragSnapWindow":true,"isHiddenScreenEdgeText":true],"input":input,
        "passwordBookCounts":["compressPasswordBook":0,"decompressPasswordBook":0],"rightResourceDirectory":resources.path,
        "rightResourceSHA256":["TXT.txt":ReplacementMigrationSupport.digest(original)],"rightSourceVersion":"1.00"]
    let url=root.appendingPathComponent("complete.plist")
    try PropertyListSerialization.data(fromPropertyList:source,format:.binary,options:0).write(to:url)
    try store.importReplacementSettings(url)
    guard store.dataHealthy,store.settings.windowSnapEnabled,store.settings.windowEnhancements.restoreWhenUnsnapped,
          !store.settings.windowEnhancements.showSnapLabel,store.settings.windowEnhancements.showSnapPreview,
          store.settings.inputEnhancements.rules.count==1,store.settings.inputEnhancements.rules[0].id==ruleID,
          !store.settings.inputEnhancements.rules[0].enabled,store.settings.inputEnhancements.migrationSources.count==1,
          store.fileEnhancements.settings.templates.count==1,store.fileEnhancements.settings.autoOpenNew else {throw DataFailure.message("完整迁移未保留后续修改、规则身份或文字独立开关。")}
    let template=store.fileEnhancements.settings.templates[0]
    guard let music=store.settings.folders.first(where:{$0.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music").path}),
          music.isCommon,music.isSend,!music.name.isEmpty,
          let pictures=store.settings.folders.first(where:{$0.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path}),
          !pictures.isCommon,pictures.isSend else {throw DataFailure.message("原目录的主目录相对路径、空默认名称或菜单角色未保留。")}
    guard let attachment=template.entries[0].attachment,try store.fileEnhancements.data.verifiedData(attachment) != original,
          store.finderPreferences.preferences.items.contains(where:{$0.id=="binaryTemplate."+template.id.uuidString}),
          !FinderActionRequest.isAllowed("file.privateIcon."+UUID().uuidString),!FinderActionRequest.isAllowed("file.privateIcon.invalid") else {throw DataFailure.message("模板原字节或真实菜单交接未接通。")}
    let before=try fm.contentsOfDirectory(atPath:store.fileEnhancements.data.directory.path).sorted()
    try store.importReplacementSettings(url)
    guard try fm.contentsOfDirectory(atPath:store.fileEnhancements.data.directory.path).sorted()==before,
          store.settings.inputEnhancements.rules.count==1 else {throw DataFailure.message("重复完整迁移增加附件或重复规则。")}
    let receipt=try store.data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self)!
    guard receipt.state=="complete",!receipt.readyToUninstall,receipt.verifiedEmptyPasswordBooks,
          receipt.retainedUserChanges.contains("restoreWhenUnsnapped"),receipt.retainedUserChanges.contains("autoOpenNew") else {throw DataFailure.message("配置提交被误记为完整替代或丢失用户覆盖证据。")}
    store.update{$0.windowEnhancements.restoreWhenUnsnapped=false}
    let journalURL=store.data.directory.appendingPathComponent("replacement-migration-v2.json")
    var journal=try JSONSerialization.jsonObject(with:Data(contentsOf:journalURL)) as! [String:Any]
    journal["state"]="prepared"
    try JSONSerialization.data(withJSONObject:journal).write(to:journalURL,options:.atomic)
    let recovered=OperationStore(directory:store.data.directory)
    guard recovered.dataHealthy,recovered.settings.windowEnhancements.restoreWhenUnsnapped,recovered.settings.windowSnapEnabled,
          recovered.fileEnhancements.settings.templates.isEmpty,recovered.settings.inputEnhancements.rules[0].id==ruleID,
          fm.fileExists(atPath:store.fileEnhancements.data.directory.appendingPathComponent(attachment).path) else {throw DataFailure.message("完整迁移中断未恢复前态或删除了可恢复附件。")}
    try recovered.importReplacementSettings(url)
    guard recovered.fileEnhancements.settings.templates.count==1,recovered.settings.inputEnhancements.rules.count==1 else {throw DataFailure.message("完整迁移恢复后无法幂等重试。")}
    var reconciledJournal=try JSONSerialization.jsonObject(with:Data(contentsOf:journalURL)) as! [String:Any]
    reconciledJournal["state"]="restored"
    try JSONSerialization.data(withJSONObject:reconciledJournal).write(to:journalURL,options:.atomic)
    let reconciled=OperationStore(directory:recovered.data.directory)
    guard reconciled.dataHealthy,try reconciled.data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self)?.state == "restored" else {throw DataFailure.message("迁移日志与回执在崩溃边界后未对账。")}
    let badRoot=root.appendingPathComponent("Untouched")
    let fresh=OperationStore(directory:badRoot)
    let originalSettings=try Data(contentsOf:badRoot.appendingPathComponent("settings.json"))
    var invalid=source;invalid["passwordBookCounts"]=["compressPasswordBook":1,"decompressPasswordBook":0]
    let bad=root.appendingPathComponent("bad.plist")
    try PropertyListSerialization.data(fromPropertyList:invalid,format:.binary,options:0).write(to:bad)
    var rejected=false;do{try fresh.importReplacementSettings(bad)}catch{rejected=true}
    guard rejected,try Data(contentsOf:badRoot.appendingPathComponent("settings.json"))==originalSettings,
          !fm.fileExists(atPath:badRoot.appendingPathComponent("replacement-migration-v2.json").path) else {throw DataFailure.message("失效资源证明未在迁移写入前阻断。")}
    let configuration=try JSONEncoder().encode(WindowEnhancementConfiguration())
    var oldConfiguration=try JSONSerialization.jsonObject(with:configuration) as! [String:Any];oldConfiguration.removeValue(forKey:"showSnapLabel")
    guard try JSONDecoder().decode(WindowEnhancementConfiguration.self,from:JSONSerialization.data(withJSONObject:oldConfiguration)).showSnapLabel else {throw DataFailure.message("旧窗口配置未兼容。")}
    // Model the actually shipped early journal: committed schema 1, random rule
    // UUIDs, and neither source evidence nor source bytes retained in the data dir.
    func compatibilityRow(_ key:Int,_ name:String,_ action:String)->[String:Any] {
        ["Gesture":["keyCode":key,"modifierFlags":524288],"Modifier":" -","Enable":1,"Note":name,"Action":["ActionType":"Preset","Action":action]]
    }
    let compatibilityRows=[compatibilityRow(123,"原创左侧规则","half_of_Left"),compatibilityRow(124,"原创右侧规则","half_of_Right"),compatibilityRow(125,"原创下侧规则","half_of_Bottom")]
    let compatibilityInput:[String:Any]=["ruleOfKeyboard":[["AppName":"All Applications","All Rules":compatibilityRows]],"ruleOfAppleScript":[["Name":"原创未执行脚本","AppleScript":"return 7"]]]
    var openRow=compatibilityRow(126,"新增打开规则","Open...")
    openRow["Action"]=["ActionType":"Preset","Action":"Open...","OpenArr":["https://example.invalid/migration-fixture"]]
    var expandedInput=compatibilityInput
    expandedInput["ruleOfKeyboard"]=[["AppName":"All Applications","All Rules":compatibilityRows+[openRow]]]
    func earlyJournalStore(_ name:String,recordedRuleCount:Int=3)throws->(OperationStore,[UUID]) {
        let directory=root.appendingPathComponent(name,isDirectory:true)
        let seed=OperationStore(directory:directory)
        let legacyInput=try EnhancedRuleFiles.legacyImportBAB(compatibilityInput).configuration
        let ids=legacyInput.rules.map(\.id)
        let oldPayload:[String:Any]=["schema":1,"right":["shouldAutoOpenNewFile":false],"archive":[:],"pane":["isUnsnapRestore":false],"input":compatibilityInput]
        let oldURL=root.appendingPathComponent(name+"-source.plist")
        try PropertyListSerialization.data(fromPropertyList:oldPayload,format:.binary,options:0).write(to:oldURL)
        try seed.importReplacementSettings(oldURL)
        seed.update {
            $0.inputEnhancements=legacyInput
            $0.inputEnhancements.rules[1].name="用户修改后的右侧规则"
            $0.inputEnhancements.rules[1].effect.actionID="window.topHalf"
            $0.inputEnhancements.rules.removeLast()
            $0.inputEnhancements.scriptLibrary[0].source="return 99"
            $0.windowSnapEnabled=true;$0.windowEnhancements.restoreWhenUnsnapped=true
            $0.windowEnhancements.showSnapPreview=true;$0.windowEnhancements.showSnapLabel=true
            $0.windowEnhancements.hapticFeedback=true
            $0.showMenuBarIcon=true;$0.playNewFileSound=true
        }
        try seed.fileEnhancements.update{$0.autoOpenNew=true}
        seed.archiveEnhancements.preferences.creation.threads=2
        seed.archiveEnhancements.preferences.creation.appendDate=true
        seed.archiveEnhancements.preferences.creation.ignoredPatterns=["keep-user-pattern"]
        try seed.archiveEnhancements.save()
        seed.finderPreferences.update {
            $0.mergeInSubmenu=true;$0.includeExternalVolumes=true;$0.showIcons=true
            $0.items.reverse()
            if let index=$0.items.firstIndex(where:{$0.id == "path.copy"}) {$0.items[index].title="用户路径菜单名称";$0.items[index].enabled=false}
        }
        let evidenceURL=directory.appendingPathComponent("replacement-migration-evidence.json")
        let evidence=try JSONSerialization.jsonObject(with:Data(contentsOf:evidenceURL)) as! [String:Any]
        try fm.removeItem(at:directory.appendingPathComponent(evidence["originalFile"] as! String))
        try fm.removeItem(at:evidenceURL)
        let oldJournal=directory.appendingPathComponent("replacement-migration.json")
        var value=try JSONSerialization.jsonObject(with:Data(contentsOf:oldJournal)) as! [String:Any]
        value["importedRules"]=recordedRuleCount
        try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:oldJournal,options:.atomic)
        let reloaded=OperationStore(directory:directory)
        guard reloaded.dataHealthy,!fm.fileExists(atPath:evidenceURL.path),
              !(try fm.contentsOfDirectory(atPath:directory.path)).contains(where:{$0.hasPrefix("replacement-source-")}) else {throw DataFailure.message("早期迁移测试未形成缺少来源证据的真实日志前态。")}
        return (reloaded,ids)
    }
    var compatibilityPayload=source;compatibilityPayload["input"]=expandedInput
    var compatibilityRight=right
    compatibilityRight["shouldShowStatusBarIcon"]=false;compatibilityRight["shouldPlayNewFileSound"]=false
    compatibilityRight["shouldMergeFinderMenuItems"]=false;compatibilityRight["shouldShowMenuOnExternalDisk"]=false;compatibilityRight["shouldShowMenuIconOfToolbox"]=false
    compatibilityPayload["right"]=compatibilityRight
    compatibilityPayload["archive"]=["cpuUseCount":1,"shouldAppendDateAfterFileNameWhenCompress":false,"shouldExcludeIgnoreFilesWhenCompress":false]
    compatibilityPayload["pane"]=["isUnsnapRestore":false,"isDragSnapWindow":false,"isHiddenScreenEdgeText":true,"isHapticFeedbackOnSnap":false]
    let compatibilityURL=root.appendingPathComponent("early-journal-upgrade.plist")
    try PropertyListSerialization.data(fromPropertyList:compatibilityPayload,format:.binary,options:0).write(to:compatibilityURL)
    let (early,earlyIDs)=try earlyJournalStore("EarlyJournal")
    let earlyRules=early.settings.inputEnhancements.rules
    let earlyScripts=early.settings.inputEnhancements.scriptLibrary
    let earlyArchive=early.archiveEnhancements.preferences
    let earlyMenu=early.finderPreferences.preferences
    try early.importReplacementSettings(compatibilityURL)
    guard early.dataHealthy,early.settings.windowSnapEnabled,early.settings.windowEnhancements.restoreWhenUnsnapped,
          early.settings.windowEnhancements.showSnapPreview,early.settings.windowEnhancements.showSnapLabel,early.settings.windowEnhancements.hapticFeedback,
          early.settings.showMenuBarIcon,early.settings.playNewFileSound,early.fileEnhancements.settings.autoOpenNew,
          try ReplacementMigrationSupport.identical(early.archiveEnhancements.preferences,earlyArchive),
          early.settings.inputEnhancements.scriptLibrary==earlyScripts else {throw DataFailure.message("缺少旧来源证据时覆盖了用户窗口、文件、压缩或脚本设置。")}
    let upgradedRules=early.settings.inputEnhancements.rules
    guard upgradedRules.count==3,Set(upgradedRules.map(\.id)).count==3,
          upgradedRules.contains(where:{$0.id==earlyIDs[0] && $0.migrationOrigin != nil}),
          upgradedRules.first(where:{$0.id==earlyIDs[1]})==earlyRules[1],
          !upgradedRules.contains(where:{$0.id==earlyIDs[2]}),
          upgradedRules.filter({$0.effect.kind == .openTargets}).count==1,
          upgradedRules.allSatisfy({!$0.enabled}),!early.settings.inputEnhancements.enabled,
          early.settings.inputEnhancements.migrationSources[0].rows.count==4,
          early.settings.inputEnhancements.migrationSources[0].rows.filter({$0.disposition == .preservedUserChange}).count==2 else {throw DataFailure.message("早期旧日志升级重复规则、丢失UUID或重新添加已修改/删除的平行替代。")}
    let oldMenuIDs=Set(earlyMenu.items.map(\.id))
    guard early.finderPreferences.preferences.items.filter({oldMenuIDs.contains($0.id)})==earlyMenu.items,
          early.finderPreferences.preferences.mergeInSubmenu==earlyMenu.mergeInSubmenu,
          early.finderPreferences.preferences.includeExternalVolumes==earlyMenu.includeExternalVolumes,
          early.finderPreferences.preferences.showIcons==earlyMenu.showIcons else {throw DataFailure.message("缺旧来源证据时改变了已有菜单项目、顺序或开关。")}
    let earlyReceipt=try early.data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self)!
    guard earlyReceipt.state=="complete",!earlyReceipt.readyToUninstall,
          earlyReceipt.notes.contains(where:{$0.contains("缺少原来源文件")}),
          earlyReceipt.retainedUserChanges.contains("restoreWhenUnsnapped"),earlyReceipt.retainedUserChanges.contains("autoOpenNew") else {throw DataFailure.message("早期兼容迁移未明确记录证据不足或设置保留。")}
    let earlySettings=try Data(contentsOf:early.data.directory.appendingPathComponent("settings.json"))
    let earlyFiles=try fm.contentsOfDirectory(atPath:early.fileEnhancements.data.directory.path).sorted()
    try early.importReplacementSettings(compatibilityURL)
    guard try Data(contentsOf:early.data.directory.appendingPathComponent("settings.json"))==earlySettings,
          try fm.contentsOfDirectory(atPath:early.fileEnhancements.data.directory.path).sorted()==earlyFiles else {throw DataFailure.message("早期兼容迁移重放改变了设置或追加附件。")}
    let earlyReloaded=OperationStore(directory:early.data.directory)
    guard earlyReloaded.dataHealthy,earlyReloaded.settings.inputEnhancements.rules==upgradedRules,
          earlyReloaded.settings.windowEnhancements.restoreWhenUnsnapped,earlyReloaded.fileEnhancements.settings.autoOpenNew else {throw DataFailure.message("早期兼容迁移结果重启后未保留。")}
    let (mismatch,_)=try earlyJournalStore("EarlyJournalMismatch",recordedRuleCount:2)
    func fileBytes(_ directory:URL)throws->[String:Data] {
        guard let enumerator=fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey]) else {throw DataFailure.message("无法读取测试前态。")}
        var result:[String:Data]=[:]
        while let item=enumerator.nextObject() as? URL {
            if try item.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {result[String(item.path.dropFirst(directory.path.count))]=try Data(contentsOf:item)}
        }
        return result
    }
    let mismatchBefore=try fileBytes(mismatch.data.directory)
    var countRejected=false;do{try mismatch.importReplacementSettings(compatibilityURL)}catch{countRejected=true}
    guard countRejected,try fileBytes(mismatch.data.directory)==mismatchBefore,
          !fm.fileExists(atPath:mismatch.data.directory.appendingPathComponent("replacement-migration-v2.json").path) else {throw DataFailure.message("旧日志条数与兼容解析不符时未在任何资料写入前停止。")}
    print("PASS: full migration preflight, original template mapping/menu, stable rule upgrade, source audit, repeat idempotence, user override preservation, interrupted rollback/retry and nonempty-password-book refusal; no uninstall authorization")
}
