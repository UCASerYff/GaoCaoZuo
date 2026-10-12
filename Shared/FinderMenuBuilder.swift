import AppKit

@MainActor enum FinderMenuBuilder {
    static func menu(snapshot:FinderMenuSnapshot,urls:[URL],hasSelection:Bool,target:AnyObject,selector:Selector) -> NSMenu {
        let prefs=snapshot.preferences
        let menu=NSMenu(title:"搞操作");menu.autoenablesItems=false
        let content=NSMenu(title:"搞操作");content.autoenablesItems=false
        func item(_ title:String,_ action:String,_ icon:String="",needsSelection:Bool=true)->NSMenuItem {
            let value=NSMenuItem(title:title,action:selector,keyEquivalent:"");value.target=target;value.representedObject=action
            value.isEnabled = !urls.isEmpty && urls.count<=1000 && (!needsSelection || hasSelection)
            if prefs.showIcons,!icon.isEmpty {value.image=NSImage(systemSymbolName:icon,accessibilityDescription:nil)}
            return value
        }
        let noSelection:Set<String>=["new.text","new.markdown","new.folder","new.custom","file.new.office","file.template.create","file.paste","file.hideAll","file.unhideAll","file.terminal","folder.favorite.add","path.copy","name.copy","file.path.real","file.path.custom","file.openApp","file.ishot","file.diskmap"]
        var previousGroup=""
        for definition in prefs.items where definition.enabled && !definition.title.isEmpty {
            if previousGroup != definition.group,!content.items.isEmpty {content.addItem(.separator())}
            previousGroup=definition.group
            if ["folder.open","folder.copy","folder.move"].contains(definition.id) {
                let root=NSMenuItem(title:definition.title,action:nil,keyEquivalent:"")
                let sub=NSMenu(title:definition.title);sub.autoenablesItems=false
                for folder in snapshot.folders {sub.addItem(item(folder.name,definition.id+"."+folder.id,"folder",needsSelection:definition.id != "folder.open"))}
                if definition.id != "folder.open" {
                    if !sub.items.isEmpty{sub.addItem(.separator())}
                    sub.addItem(item("选择其他目录…",definition.id == "folder.copy" ? "files.copy" : "files.move","folder"))
                }
                if !sub.items.isEmpty {root.submenu=sub;content.addItem(root)}
            } else if definition.id == "file.openApp",!snapshot.applications.isEmpty {
                let root=NSMenuItem(title:definition.title,action:nil,keyEquivalent:"");let sub=NSMenu(title:definition.title);sub.autoenablesItems=false
                for app in snapshot.applications {sub.addItem(item(app.name,"file.open."+app.id,"app",needsSelection:false))}
                sub.addItem(item("添加或选择其他应用…","file.openApp","plus",needsSelection:false));root.submenu=sub;content.addItem(root)
            } else if definition.id == "file.template.create" {
                let root=NSMenuItem(title:definition.title,action:nil,keyEquivalent:"");let sub=NSMenu(title:definition.title);sub.autoenablesItems=false
                for template in snapshot.templates {sub.addItem(item(template.name,(template.binary ? "binaryTemplate." : "template.")+template.id,"doc",needsSelection:false))}
                sub.addItem(item("管理与导入模板…","file.template.import","plus",needsSelection:false));root.submenu=sub;content.addItem(root)
            } else {
                content.addItem(item(definition.title,definition.id,definition.icon,needsSelection:!noSelection.contains(definition.id) && !definition.id.hasPrefix("file.new.")))
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
    static func isExcluded(_ urls:[URL],preferences:FinderMenuPreferences)->Bool {
        urls.contains {url in preferences.excludedPaths.contains {path in url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path:path+"/")}}
    }
}
