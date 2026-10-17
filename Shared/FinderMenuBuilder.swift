import AppKit

@MainActor enum FinderMenuBuilder {
    static func menu(snapshot:FinderMenuSnapshot,urls:[URL],hasSelection:Bool,target:AnyObject,selector:Selector,appBundleID:String?=nil) -> NSMenu {
        let prefs=snapshot.preferences
        L10n.setLanguage(snapshot.language ?? "system")
        let defaults=Dictionary(uniqueKeysWithValues:FinderMenuPreferences.defaults.map{($0.id,$0.title)})
        func defaultTitle(_ title:String,_ action:String)->String { defaults[action] == title ? L10n.text(title) : title }
        let menu=NSMenu(title:"搞操作");menu.autoenablesItems=false
        guard !FinderMenuContext.isExcluded(urls,appBundleID:appBundleID,preferences:prefs) else {return menu}
        let content=NSMenu(title:"搞操作");content.autoenablesItems=false
        func item(_ title:String,_ action:String,_ icon:String="",needsSelection:Bool=true)->NSMenuItem {
            let value=NSMenuItem(title:defaultTitle(title,action),action:selector,keyEquivalent:"");value.target=target;value.representedObject=action
            value.isEnabled = !urls.isEmpty && urls.count<=1000 && (!needsSelection || hasSelection)
            if prefs.showIcons,!icon.isEmpty {value.image=NSImage(systemSymbolName:icon,accessibilityDescription:nil)}
            return value
        }
        let noSelection:Set<String>=["new.text","new.markdown","new.folder","new.custom","file.new.office","file.template.create","file.paste","file.hideAll","file.unhideAll","file.terminal","folder.favorite.add","path.copy","name.copy","file.path.real","file.path.custom","file.openApp","file.ishot","file.diskmap","file.capture.window","file.capture.display","file.cleanup.review"]
        var previousGroup=""
        for definition in prefs.items where definition.enabled && !definition.title.isEmpty && (FinderActionRequest.isAllowed(definition.id) || ["folder.open","folder.copy","folder.move"].contains(definition.id)) {
            if previousGroup != definition.group,!content.items.isEmpty {content.addItem(.separator())}
            previousGroup=definition.group
            if ["folder.open","folder.copy","folder.move"].contains(definition.id) {
                let root=NSMenuItem(title:defaultTitle(definition.title,definition.id),action:nil,keyEquivalent:"")
                let sub=NSMenu(title:defaultTitle(definition.title,definition.id));sub.autoenablesItems=false
                for folder in snapshot.folders where definition.id == "folder.open" ? folder.isCommon : folder.isSend {sub.addItem(item(folder.name,definition.id+"."+folder.id,"folder",needsSelection:definition.id != "folder.open"))}
                if definition.id != "folder.open" {
                    if !sub.items.isEmpty{sub.addItem(.separator())}
                    sub.addItem(item(L10n.text("选择其他目录…"),definition.id == "folder.copy" ? "files.copy" : "files.move","folder"))
                }
                if !sub.items.isEmpty {root.submenu=sub;content.addItem(root)}
            } else if definition.id == "file.openApp",!snapshot.applications.isEmpty {
                let root=NSMenuItem(title:defaultTitle(definition.title,definition.id),action:nil,keyEquivalent:"");let sub=NSMenu(title:defaultTitle(definition.title,definition.id));sub.autoenablesItems=false
                for app in snapshot.applications {sub.addItem(item(app.name,"file.open."+app.id,"app",needsSelection:false))}
                sub.addItem(item(L10n.text("添加或选择其他应用…"),"file.openApp","plus",needsSelection:false));root.submenu=sub;content.addItem(root)
            } else if definition.id == "file.template.create" {
                let root=NSMenuItem(title:defaultTitle(definition.title,definition.id),action:nil,keyEquivalent:"");let sub=NSMenu(title:defaultTitle(definition.title,definition.id));sub.autoenablesItems=false
                for template in snapshot.templates {sub.addItem(item(template.name,(template.binary ? "binaryTemplate." : "template.")+template.id,"doc",needsSelection:false))}
                sub.addItem(item(L10n.text("管理与导入模板…"),"file.template.import","plus",needsSelection:false));root.submenu=sub;content.addItem(root)
            } else {
                content.addItem(item(definition.title,definition.id,definition.icon,needsSelection:!noSelection.contains(definition.id) && !definition.id.hasPrefix("file.new.") && !definition.id.hasPrefix("binaryTemplate.") && !definition.id.hasPrefix("file.open.")))
            }
        }
        if prefs.mergeInSubmenu {let root=NSMenuItem(title:"搞操作",action:nil,keyEquivalent:"");root.submenu=content;menu.addItem(root)}
        else {for value in content.items {content.removeItem(value);menu.addItem(value)}}
        return menu
    }
}

enum FinderMenuContext {
    static func usesContainer(_ action:String)->Bool {
        action.hasPrefix("new.") || action.hasPrefix("template.") || action.hasPrefix("binaryTemplate.") || action.hasPrefix("file.new.") || ["file.paste","file.hideAll","file.unhideAll","file.template.create"].contains(action)
    }
    static func isExcluded(_ urls:[URL],appBundleID:String?=nil,preferences:FinderMenuPreferences)->Bool {
        if let appBundleID,!appBundleID.isEmpty,preferences.excludedApps.contains(appBundleID) {return true}
        // Compare path components after lexical normalization. This neither reads
        // nor materializes cloud files, and /excluded must not match /excluded-2.
        return urls.contains {url in preferences.excludedPaths.contains {path in
            guard path.hasPrefix("/"),!path.contains("\0") else {return false}
            let excluded=URL(fileURLWithPath:path).standardizedFileURL.path
            let candidate=url.standardizedFileURL.path
            return candidate == excluded || candidate.hasPrefix(excluded == "/" ? "/" : excluded+"/")
        }}
    }
    /// Recheck visibility against the newest configuration when an old Finder
    /// menu is clicked. A changed or disabled dynamic child cannot survive just
    /// because its numeric menu tag was issued earlier.
    static func isActionEnabled(_ action:String,snapshot:FinderMenuSnapshot)->Bool {
        func enabled(_ id:String)->Bool {snapshot.preferences.items.contains{$0.id == id && $0.enabled && !$0.title.isEmpty}}
        if action == "files.copy" {return enabled("folder.copy")}
        if action == "files.move" {return enabled("folder.move")}
        if action == "file.template.import" {return enabled("file.template.create")}
        for prefix in ["folder.open.","folder.copy.","folder.move."] where action.hasPrefix(prefix) {
            let id=String(action.dropFirst(prefix.count)),parent=String(prefix.dropLast())
            return enabled(parent) && snapshot.folders.contains{$0.id == id && (parent == "folder.open" ? $0.isCommon : $0.isSend)}
        }
        for (prefix,binary) in [("template.",false),("binaryTemplate.",true)] where action.hasPrefix(prefix) {
            let id=String(action.dropFirst(prefix.count))
            return enabled("file.template.create") && snapshot.templates.contains{$0.id == id && $0.binary == binary}
        }
        if action.hasPrefix("file.open.") {
            let id=String(action.dropFirst("file.open.".count))
            return enabled("file.openApp") && snapshot.applications.contains{$0.id == id}
        }
        return FinderActionRequest.isAllowed(action) && enabled(action)
    }
}

/// A menu is a choice about the objects that were visible when it opened.
/// Finder may change selection or targetedURL before invoking the callback;
/// never silently reinterpret that old choice as a request for other objects.
struct FinderMenuInvocationContext {
    let selection:[URL]
    let container:URL?
    let usesSelection:Bool
    let appBundleID:String?
    init(selection:[URL],container:URL?,usesSelection:Bool,appBundleID:String?) {
        self.selection=selection.map(\.standardizedFileURL)
        self.container=container?.standardizedFileURL
        self.usesSelection=usesSelection
        self.appBundleID=appBundleID
    }
    var menuURLs:[URL] {usesSelection ? selection : container.map{[$0]} ?? []}
    func urls(for action:String)->[URL] {
        FinderMenuContext.usesContainer(action) ? container.map{[$0]} ?? [] : menuURLs
    }
    func matches(selection:[URL],container:URL?,appBundleID:String?)->Bool {
        guard self.appBundleID == appBundleID,self.container == container?.standardizedFileURL else {return false}
        // Container, sidebar and toolbar actions ignore an unrelated stale Finder
        // selection. Selection menus must preserve the exact ordered selection.
        return !usesSelection || self.selection == selection.map(\.standardizedFileURL)
    }
}
