import Foundation
import AppKit

/// Pure request/URL tests: never issue or consume a native pasteboard ticket.
@MainActor func runFinderCommandTests(renderMenus:Bool = true) throws {
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else {
            throw NSError(domain: "FinderCommandTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    let nonce = String(repeating: "0123456789abcdef", count: 4)
    let otherNonce = String(repeating: "fedcba9876543210", count: 4)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func bytes(action: String = "new.text", paths: [String] = ["/temporary/finder-test"],
               issuedAt: Date? = nil, requestNonce: String? = nil) throws -> Data {
        try JSONEncoder().encode(FinderActionRequest(nonce: requestNonce ?? nonce, action: action,
                                                    paths: paths, issuedAt: issuedAt ?? now))
    }
    func accepted(_ data: Data, matching value: String? = nil) -> Bool {
        FinderActionRequest.decode(data, nonce: value ?? nonce, now: now) != nil
    }
    func parsed(_ text: String) -> String? {
        URL(string: text).flatMap { FinderActionRequest.ticketNonce(from: $0) }
    }
    try check(FinderActionRequest.validNonce(nonce), "64 ASCII lowercase hex characters form a valid nonce")
    for invalid in ["", String(nonce.dropLast()), nonce + "0", nonce.uppercased(), String(repeating: "g", count: 64),
                    String(repeating: "０", count: 64), nonce + "\0", " " + nonce] {
        try check(!FinderActionRequest.validNonce(invalid), "wrong length, alphabet or Unicode nonce is rejected")
    }
    let valid = try bytes()
    try check(accepted(valid), "newly issued valid request is accepted")
    try check(!accepted(valid, matching: otherNonce), "URL token must match native request token")
    try check(!accepted(bytes(requestNonce: otherNonce)), "native token mismatch is rejected")
    try check(!accepted(valid, matching: "not-a-nonce"), "invalid caller nonce cannot authorize valid JSON")
    try check(accepted(bytes(issuedAt: now.addingTimeInterval(-60))), "exactly 60 seconds old is within validity")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(-60.001))), "expired ticket is rejected")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(0.001))), "even slightly future ticket is rejected")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(3600))), "future-dated ticket cannot extend validity")

    for allowed in ["new.folder", "path.copy", "archive.extract", "files.move.documents", "images.heic"] {
        try check(accepted(bytes(action: allowed)), "known Finder action accepted: \(allowed)")
    }
    for forbidden in ["", "new.text ", "NEW.TEXT", "system.lock", "shortcut.run", "shell.run", "template.anything", "../new.text"] {
        try check(!accepted(bytes(action: forbidden)), "action outside Finder whitelist rejected: \(forbidden)")
    }
    try check(accepted(bytes(paths: ["/temporary/中文 空格/#?%&.txt"])), "absolute Unicode path is preserved as data")
    for invalidPath in ["", "relative/file.txt", "../escape", "~/Desktop/file.txt", "file:///temporary/a", "/temporary/a\0b"] {
        try check(!accepted(bytes(paths: [invalidPath])), "relative or NULL-containing path rejected")
    }
    let maxPath = "/" + String(repeating: "a", count: 16_383)
    try check(accepted(bytes(paths: [maxPath])), "path at 16384 UTF-8 bytes is permitted")
    try check(!accepted(bytes(paths: [maxPath + "a"])), "overlong path rejected")
    try check(!accepted(bytes(paths: ["/" + String(repeating: "文", count: 5462)])), "path length uses UTF-8 bytes, not characters")
    try check(!accepted(bytes(paths: [])), "empty selection rejected")
    try check(accepted(bytes(paths: Array(repeating: "/temporary/a", count: 1000))), "1000 path boundary accepted")
    try check(!accepted(bytes(paths: Array(repeating: "/temporary/a", count: 1001))), "selection above 1000 paths rejected")

    var exactSize = valid
    exactSize.append(Data(repeating: 32, count: FinderActionRequest.maximumBytes - valid.count))
    try check(accepted(exactSize), "JSON at total byte budget accepted")
    var oversized = exactSize; oversized.append(32)
    try check(!accepted(oversized), "JSON over total byte budget rejected before decoding")
    for malformed in [Data(), Data("{".utf8), Data("null".utf8), Data([0xff, 0xfe, 0xfd])] {
        try check(!accepted(malformed), "malformed JSON is rejected")
    }
    let rawPaths = try JSONEncoder().encode(["/temporary/a"])
    try check(!accepted(rawPaths), "legacy browser path payload is not a native ticket document")
    var wrongShape = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    wrongShape["paths"] = [7]
    try check(!accepted(JSONSerialization.data(withJSONObject: wrongShape)), "path entries must be strings")
    wrongShape = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    wrongShape.removeValue(forKey: "issuedAt")
    try check(!accepted(JSONSerialization.data(withJSONObject: wrongShape)), "missing timestamp is rejected")

    let validURL = "gaocaozuo://finder?ticket=" + nonce
    try check(parsed(validURL) == nonce, "ticket route extracts only nonce")
    for invalidURL in [
        "https://finder?ticket=" + nonce,
        "gaocaozuo://perform/new.text?payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + nonce + "&payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + nonce + "&ticket=" + nonce,
        "gaocaozuo://finder?ticket=", "gaocaozuo://finder?ticket",
        "gaocaozuo://finder?Ticket=" + nonce,
        "gaocaozuo://finder/?ticket=" + nonce,
        "gaocaozuo://finder/new.text?ticket=" + nonce,
        "gaocaozuo://evil.example?ticket=" + nonce,
        "gaocaozuo://user@finder?ticket=" + nonce,
        "gaocaozuo://user:password@finder?ticket=" + nonce,
        "gaocaozuo://finder:9999?ticket=" + nonce,
        validURL + "#", validURL + "#new.text",
        "gaocaozuo://finder?ticket=" + String(repeating: "a", count: 300)
    ] {
        try check(parsed(invalidURL) == nil, "non-ticket, ambiguous or decorated URL rejected")
    }
    // A parsed nonce still needs matching native bytes; URL syntax alone carries no paths or authority.
    try check(!accepted(rawPaths, matching: parsed(validURL)), "browser payload cannot become a request through valid ticket syntax")
    var prefs = FinderMenuPreferences()
    // This CLI regression exercises menu selection/visibility, not system symbol
    // rendering. Loading SF Symbols registers a GUI process with WindowServer.
    prefs.showIcons=false
    prefs.excludedApps = ["com.apple.finder", "com.example.Excluded"]
    prefs.excludedPaths = ["/temporary/excluded"]
    try check(FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/normal")],appBundleID:"com.apple.finder",preferences:prefs), "Finder application exclusion is independent of input exclusions")
    try check(!FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/normal")],appBundleID:"com.example.Allowed",preferences:prefs), "unlisted app remains allowed")
    try check(FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/excluded/child")],preferences:prefs), "excluded directory descendants are blocked")
    try check(!FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/excluded-sibling")],preferences:prefs), "directory exclusion does not match path prefix siblings")
    prefs.excludedPaths=["/temporary/first/../excluded/"]
    try check(FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/excluded/child")],preferences:prefs), "lexically equivalent exclusions match without reading file data")
    try check(FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/other/../excluded/child")],preferences:prefs), "Finder URL dot components cannot bypass an exclusion")
    prefs.excludedPaths=["relative/ignored"]
    try check(!FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/normal")],preferences:prefs), "malformed relative persisted exclusions do not become relative to a process directory")
    prefs.excludedPaths=["/"]
    try check(FinderMenuContext.isExcluded([URL(fileURLWithPath:"/temporary/normal")],preferences:prefs), "root exclusion covers all descendants")
    prefs.excludedPaths=[]
    prefs.items = [FinderMenuItemDefinition(id:"new.text",title:"新建文本",icon:"doc",group:"新建"), FinderMenuItemDefinition(id:"file.openApp",title:"应用",icon:"app",group:"应用"), FinderMenuItemDefinition(id:"unknown.future.action",title:"未来功能",icon:"app",group:"未知")]
    let customID=UUID().uuidString
    let snapshot=FinderMenuSnapshot(preferences:prefs,applications:[FinderMenuApplication(id:customID,name:"自定义应用")])
    let target=NSObject(), selector=NSSelectorFromString("perform:")
    let urls=[URL(fileURLWithPath:"/temporary/normal")]
    if renderMenus {
        try check(FinderMenuBuilder.menu(snapshot:snapshot,urls:urls,hasSelection:true,target:target,selector:selector,appBundleID:"com.example.Excluded").items.isEmpty, "builder itself blocks default and custom menu actions for excluded app")
        let allowed=FinderMenuBuilder.menu(snapshot:snapshot,urls:urls,hasSelection:true,target:target,selector:selector,appBundleID:"com.example.Allowed")
        let content=allowed.items.first?.submenu
        try check(content?.items.contains(where:{$0.representedObject as? String == "new.text"}) == true, "allowed default action appears")
        try check(content?.items.flatMap({$0.submenu?.items ?? []}).contains(where:{$0.representedObject as? String == "file.open."+customID}) == true, "allowed custom action appears")
        try check(content?.items.contains(where:{$0.title == "未来功能"}) == false, "preserved unknown action cannot execute")
    }
    var encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(prefs)) as! [String:Any]
    encoded["futureTop"]=["nested":["retain",NSNull(),true],"integer":Int64.max]
    var items=encoded["items"] as! [[String:Any]];items[0]["futureItem"]=["privateRule":"keep"];encoded["items"]=items
    var reread=try JSONDecoder().decode(FinderMenuPreferences.self,from:JSONSerialization.data(withJSONObject:encoded))
    reread.showIcons=false;reread.items[0].title="自定义名称"
    let roundtrip=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reread)) as! [String:Any]
    try check((roundtrip["futureTop"] as? NSDictionary) == (encoded["futureTop"] as? NSDictionary), "unknown nested menu fields and 64-bit integers survive editing")
    try check(((roundtrip["items"] as! [[String:Any]])[0]["futureItem"] as? NSDictionary) == (items[0]["futureItem"] as? NSDictionary), "unknown per-item fields survive editing")
    var rolePreferences=FinderMenuPreferences()
    rolePreferences.showIcons=false
    rolePreferences.items=[.init(id:"folder.open",title:"Open",icon:"folder",group:"Folders"),.init(id:"folder.copy",title:"Copy",icon:"folder",group:"Folders")]
    let commonID=UUID().uuidString,sendID=UUID().uuidString,bothID=UUID().uuidString
    let roleSnapshot=FinderMenuSnapshot(preferences:rolePreferences,folders:[
        .init(id:commonID,name:"Common only",path:"/temporary/common",sourceRoles:["common"]),
        .init(id:sendID,name:"Send only",path:"/temporary/send",sourceRoles:["send"]),
        .init(id:bothID,name:"Existing user folder",path:"/temporary/both")])
    if renderMenus {
        let roleMenu=FinderMenuBuilder.menu(snapshot:roleSnapshot,urls:urls,hasSelection:true,target:target,selector:selector)
        func menuActions(_ menu:NSMenu)->[String] {menu.items.flatMap {item in (item.representedObject as? String).map{[$0]} ?? item.submenu.map(menuActions) ?? []}}
        let roleActions=Set(menuActions(roleMenu))
        try check(roleActions.contains("folder.open."+commonID) && !roleActions.contains("folder.open."+sendID),"source favorites and send destinations retain distinct real menu roles")
        try check(roleActions.contains("folder.copy."+sendID) && !roleActions.contains("folder.copy."+commonID),"send-only source folder is not widened into common menus")
        try check(roleActions.contains("folder.open."+bothID) && roleActions.contains("folder.copy."+bothID),"older user folders retain both roles")
    }
    try check(FinderMenuContext.isActionEnabled("folder.open."+commonID,snapshot:roleSnapshot),"an enabled dynamic common-folder item is accepted")
    try check(!FinderMenuContext.isActionEnabled("folder.open."+sendID,snapshot:roleSnapshot),"a send-only folder cannot become an open-folder callback")
    try check(!FinderMenuContext.isActionEnabled("folder.copy."+commonID,snapshot:roleSnapshot),"a common-only folder cannot become a send-folder callback")
    var changedSnapshot=roleSnapshot
    changedSnapshot.preferences.items[0].enabled=false
    try check(!FinderMenuContext.isActionEnabled("folder.open."+commonID,snapshot:changedSnapshot),"disabling a parent invalidates an already-open dynamic menu")
    changedSnapshot=roleSnapshot;changedSnapshot.folders=[]
    try check(!FinderMenuContext.isActionEnabled("folder.open."+commonID,snapshot:changedSnapshot),"removing a dynamic destination invalidates an old callback")
    try check(FinderMenuContext.isActionEnabled("files.copy",snapshot:roleSnapshot),"choose-other-directory callback shares its parent visibility")
    let first=URL(fileURLWithPath:"/temporary/selected-a"),second=URL(fileURLWithPath:"/temporary/selected-b"),container=URL(fileURLWithPath:"/temporary")
    let selectionContext=FinderMenuInvocationContext(selection:[first,second],container:container,usesSelection:true,appBundleID:"com.apple.finder")
    try check(selectionContext.menuURLs == [first,second] && selectionContext.urls(for:"archive.create") == [first,second],"selection-menu actions keep all ordered captured objects")
    try check(selectionContext.urls(for:"new.text") == [container],"new-file actions keep the captured container")
    try check(selectionContext.matches(selection:[first,second],container:container,appBundleID:"com.apple.finder"),"unchanged Finder context remains valid")
    try check(!selectionContext.matches(selection:[second,first],container:container,appBundleID:"com.apple.finder"),"reordered selection cannot retarget an old menu")
    try check(!selectionContext.matches(selection:[second],container:container,appBundleID:"com.apple.finder"),"changed selection cannot retarget an old menu")
    try check(!selectionContext.matches(selection:[first,second],container:first,appBundleID:"com.apple.finder"),"changed container cannot retarget an old menu")
    try check(!selectionContext.matches(selection:[first,second],container:container,appBundleID:"com.example.Other"),"changed host cannot retarget an old menu")
    let blankContext=FinderMenuInvocationContext(selection:[first],container:container,usesSelection:false,appBundleID:"com.apple.finder")
    try check(blankContext.menuURLs == [container] && blankContext.urls(for:"path.copy") == [container],"blank-space and toolbar menus operate on their container rather than stale selection")
    try check(blankContext.matches(selection:[second],container:container,appBundleID:"com.apple.finder"),"unrelated selection changes do not alter a container-menu target")
    let missingContainer=FinderMenuInvocationContext(selection:[first],container:nil,usesSelection:false,appBundleID:"com.apple.finder")
    try check(missingContainer.menuURLs.isEmpty && missingContainer.urls(for:"new.text").isEmpty,"absent container does not silently fall back to selected objects")
    let defaultItem=FinderMenuPreferences.defaults.first{$0.id == "new.text"}!
    L10n.setLanguage("en")
    try check(FinderMenuPreferences.displayTitle(defaultItem) == L10n.text(defaultItem.title),"settings display the translated default menu title")
    try check(FinderMenuPreferences.storedTitle(L10n.text(defaultItem.title),for:defaultItem.id) == defaultItem.title,"editing the displayed default keeps its canonical language-independent storage key")
    var customItem=defaultItem;customItem.title="我的自定义名称"
    try check(FinderMenuPreferences.displayTitle(customItem) == customItem.title && FinderMenuPreferences.storedTitle(customItem.title,for:customItem.id) == customItem.title,"custom user labels are never translated or rewritten")
    L10n.setLanguage("zh-Hans")
    print("PASS: \(checks) Finder ticket, exclusion, captured-target, visibility and unknown-field checks; menu rendering \(renderMenus ? "included" : "not executed (WindowServer unavailable)"); no ticket pasteboard or user files")
}
