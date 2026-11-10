import AppKit
import Carbon
import Foundation

@MainActor func runScreenshotHostStoreTests() throws {
    var checks=0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else {throw DataFailure.message("Screenshot host/store: "+message)};checks += 1
    }
    func rejected(_ message:String,_ body:() throws->Void) throws {
        do {try body()} catch {checks += 1;return};throw DataFailure.message("Screenshot host/store failed to reject: "+message)
    }
    let fm=FileManager.default
    let root=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("GaoCaoZuo-HostStore-"+UUID().uuidString+".noindex",isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    defer{try? fm.removeItem(at:root)}
    func configuration(_ name:String)->ScreenshotMigrationConfiguration {
        .init(sourceRoot:root.appendingPathComponent(name+"-source"),targetRoot:root.appendingPathComponent(name+"-target"),archiveRoot:root.appendingPathComponent(name+"-archive.noindex"),auxiliaries:[])
    }
    let fresh=configuration("fresh")
    let first=ScreenshotLocalStore(root:fresh.targetRoot,backupRoot:root.appendingPathComponent("fresh-backups"),migrationConfiguration:fresh)
    try check(!first.writable && first.initializationRequired,"no defaults before explicit initialization")
    try check(!fm.fileExists(atPath:fresh.targetRoot.path),"opening module does not create a root or Exchange")
    try first.initializeFresh()
    try check(first.writable && !first.initializationRequired,"explicit fresh initializes the real store")
    try check(!first.settings.historyEnabled && first.assets.isEmpty,"fresh defaults keep collection disabled")
    try check(!fm.fileExists(atPath:first.exchange.path),"store initialization does not create a request ledger")
    first.settings.historyDays=30;try first.saveSettings()
    let reloaded=ScreenshotLocalStore(root:fresh.targetRoot,backupRoot:root.appendingPathComponent("fresh-backups"),migrationConfiguration:fresh)
    try check(reloaded.writable && reloaded.settings.historyDays==30,"settings persist through the production store")

    let legacy=configuration("legacy")
    try fm.createDirectory(at:legacy.sourceRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    var source=ScreenshotAppSettings();source.historyDays=45;source.saveDirectory="/ungranted/source-directory";source.editorPath="/Applications/Unselected Editor.app";source.captureStrategy="保存"
    let original=try encoder.encode(source)
    try original.write(to:legacy.sourceRoot.appendingPathComponent("Settings.json"))
    let receiving=ScreenshotLocalStore(root:legacy.targetRoot,backupRoot:root.appendingPathComponent("legacy-backups"),migrationConfiguration:legacy)
    try rejected("source cannot become fresh") {try receiving.initializeFresh()}
    try check(!fm.fileExists(atPath:legacy.targetRoot.path),"source evidence never creates blank target")
    let plan=try receiving.migrationPreview()
    _ = try receiving.applyMigration(plan,approvedDigest:plan.approvalDigest)
    try check(receiving.writable && receiving.settings.historyDays==45,"committed source settings load through actual host store")
    try check(receiving.settings.saveDirectory==nil && receiving.settings.editorPath==nil && receiving.settings.captureStrategy=="标注","old directory rights and save mode do not silently transfer")
    try check(try Data(contentsOf:legacy.sourceRoot.appendingPathComponent("Settings.json"))==original,"source bytes preserved")
    try check(!fm.fileExists(atPath:receiving.exchange.path),"migration never activates old request ledger")
    let settingsURL=legacy.targetRoot.appendingPathComponent("Settings.json")
    let damaged=Data("{broken".utf8);try damaged.write(to:settingsURL)
    receiving.reloadAfterMigration()
    try check(!receiving.writable && receiving.issue != nil,"corrupt committed settings block production writes")
    try rejected("blocked save") {try receiving.saveSettings()}
    try check(try Data(contentsOf:settingsURL)==damaged,"blocked reload/save never creates empty defaults")

    let before=OperationSettings()
    let adopted=try ScreenshotHotkeyAdoption.applying(to:before)
    try check(adopted.bindings.count==before.bindings.count+2,"source fixed shortcuts only added by explicit adoption")
    let repeated=try ScreenshotHotkeyAdoption.applying(to:adopted)
    try check(try encoder.encode(repeated)==encoder.encode(adopted),"explicit shortcut adoption is idempotent")
    var conflict=before
    let modifiers=UInt64(NSEvent.ModifierFlags([.command,.option,.control]).rawValue)
    conflict.bindings.append(InputBinding(actionID:"clipboard.show",keyCode:UInt16(kVK_ANSI_3),modifiers:modifiers))
    let conflictBytes=try encoder.encode(conflict)
    try rejected("existing shortcut wins") {_ = try ScreenshotHotkeyAdoption.applying(to:conflict)}
    try check(try encoder.encode(conflict)==conflictBytes,"second-key conflict cannot partially add first shortcut")
    var disabled=adopted;disabled.bindings[disabled.bindings.count-1].enabled=false
    try rejected("disabled existing rule preserved") {_ = try ScreenshotHotkeyAdoption.applying(to:disabled)}
    var advanced=before;var rule=EnhancedInputRule();rule.enabled=true;rule.keyCode=UInt16(kVK_ANSI_2);rule.modifiers=modifiers;advanced.inputEnhancements.rules.append(rule)
    try rejected("advanced input rule wins") {_ = try ScreenshotHotkeyAdoption.applying(to:advanced)}

    let screenshotMenuTitles:[String:(old:String,current:String)]=[
        "file.ishot":("用搞截图截取区域","截取区域"),
        "file.ishot.markup":("用搞截图标注图片","标注图片"),
        "file.capture.window":("用搞截图截取窗口","截取窗口"),
        "file.capture.display":("用搞截图截取屏幕","截取屏幕"),
        "file.images.pin":("用搞截图贴图","图片贴图"),
        "file.ocr":("用搞截图识别文字","本机OCR识别文字")
    ]
    let finderData=LocalData(directory:root.appendingPathComponent("finder-defaults"))
    var oldFinder=FinderMenuPreferences()
    for index in oldFinder.items.indices {
        if let title=screenshotMenuTitles[oldFinder.items[index].id] {oldFinder.items[index].title=title.old}
    }
    try finderData.save(oldFinder,name:"finder-menu.json")
    let oldFinderBytes=try Data(contentsOf:finderData.directory.appendingPathComponent("finder-menu.json"))
    let finder=FinderPreferenceController(directory:finderData.directory)
    try check(finder.data.failure==nil && finder.error==nil,"isolated Finder preferences load")
    for (id,title) in screenshotMenuTitles {
        try check(finder.preferences.items.first(where:{$0.id==id})?.title==title.current,"known screenshot default migrates: "+id)
    }
    try check(try Data(contentsOf:finderData.directory.appendingPathComponent("finder-menu.json"))==oldFinderBytes,"loading migrated Finder names does not rewrite the original settings")
    finder.update{_ in}
    let finderReloaded=FinderPreferenceController(directory:finderData.directory)
    try check(try encoder.encode(finderReloaded.preferences)==encoder.encode(finder.preferences),"migrated Finder names persist idempotently after normal save")

    let customFinderData=LocalData(directory:root.appendingPathComponent("finder-custom"))
    var customFinder=oldFinder
    for index in customFinder.items.indices {
        if let title=screenshotMenuTitles[customFinder.items[index].id] {customFinder.items[index].title=title.old+" · 我的名称"}
        if customFinder.items[index].id=="file.ocr" {customFinder.items[index].title="用搞截图截取窗口"}
    }
    try customFinderData.save(customFinder,name:"finder-menu.json")
    let customFinderReloaded=FinderPreferenceController(directory:customFinderData.directory)
    try check(try encoder.encode(customFinderReloaded.preferences)==encoder.encode(customFinder),"custom names and another action's old default remain unchanged")
    print("Screenshot host/store PASS: \(checks) checks; isolated data, no App, capture, clipboard, device or permission calls")
}
