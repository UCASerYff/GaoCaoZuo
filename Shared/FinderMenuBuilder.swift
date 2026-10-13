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
        return urls.contains {url in preferences.excludedPaths.contains {path in url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path:path+"/")}}
    }
}
