import Foundation
import AppKit

@MainActor func runLocalizationTests() throws {
    func check(_ value:Bool,_ message:String) throws { if !value { throw DataFailure.message("Localization: " + message) } }
    defer { GaoLocale.shared.setLanguage(.system); L10n.setLanguage("system") }
    for code in ["en","ja","de","fr","es","ko","pt"] {
        guard let language=GaoLanguage(rawValue:code) else {throw DataFailure.message("Missing language")}
        GaoLocale.shared.setLanguage(language)
        for action in WindowAction.allCases {
            try check(!action.title.contains(where: { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }) || code == "ja", "untranslated window action " + action.rawValue + " in " + code)
        }
        try check(GaoLocale.shared.effectiveLanguage == language,"runtime language change")
    }
    GaoLocale.shared.setLanguage(.en)
    try check(WindowAction.leftHalf.title == "Left Half","production WindowAction title did not use resource")
    try check(OperationAction.all.first(where:{$0.id == "new.text"})?.title == "New Text File","production action catalog")
    try check(SystemControlError.message("当前只有一个显示器。").localizedDescription == "Only one display is connected.","error rendering")
    try check(EnhancedInputTrigger.keyDown.title == "Key Down","input trigger rendering")
    try check(InputBinding.keyLabel(49) == "Space","input key label rendering")
    var snapshot=FinderMenuSnapshot();snapshot.language="en"
    let target=NSObject(),selector=Selector(("localizationTest:"))
    let menu=FinderMenuBuilder.menu(snapshot:snapshot,urls:[URL(fileURLWithPath:"/private/tmp")],hasSelection:true,target:target,selector:selector)
    let content=menu.items.first?.submenu
    try check(content?.items.contains(where:{$0.title == "Compress to ZIP"}) == true,"Finder resource not connected")
    snapshot.preferences.items[0].title="My ZIP 名称"
    let custom=FinderMenuBuilder.menu(snapshot:snapshot,urls:[URL(fileURLWithPath:"/private/tmp")],hasSelection:true,target:target,selector:selector)
    try check(custom.items.first?.submenu?.items.contains(where:{$0.title == "My ZIP 名称"}) == true,"custom user menu name was translated")
    snapshot.language="ja"
    let japanese=FinderMenuBuilder.menu(snapshot:snapshot,urls:[URL(fileURLWithPath:"/private/tmp")],hasSelection:true,target:target,selector:selector)
    try check(japanese.items.first?.submenu?.items.contains(where:{$0.title == "7Zに圧縮"}) == true,"Finder refresh language")
    try check(L10n.text("未知用户名称",language:"en") == "未知用户名称","unknown text must be preserved")
    try check(L10n.text("左半屏",language:"zh-Hans") == "左半屏","Chinese fallback")
    let migrationRoot=FileManager.default.temporaryDirectory.appendingPathComponent("gao-finder-title-"+UUID().uuidString,isDirectory:true)
    defer{try? FileManager.default.removeItem(at:migrationRoot)}
    let data=LocalData(directory:migrationRoot)
    var legacy=FinderMenuPreferences()
    for index in legacy.items.indices {
        switch legacy.items[index].id {
        case "file.ishot":legacy.items[index].title="打开 iShot"
        case "file.ishot.markup":legacy.items[index].title="我的标注工具"
        case "file.diskmap":legacy.items[index].title="DiskMap 分析"
        default:break
        }
    }
    try data.save(legacy,name:"finder-menu.json")
    let migrated=FinderPreferenceController(directory:migrationRoot).preferences
    try check(migrated.items.first(where:{$0.id == "file.ishot"})?.title == "用搞截图截取区域","old default capture title")
    try check(migrated.items.first(where:{$0.id == "file.diskmap"})?.title == "用搞机灵分析所选目录","old default storage title")
    try check(migrated.items.first(where:{$0.id == "file.ishot.markup"})?.title == "我的标注工具","migration changed user title")
    print("Localization resources: runtime language, all window titles, errors, actions, Finder refresh and custom names passed")
}
