import AppKit
import ApplicationServices
import SwiftUI

/// Exact menu-title paths are deliberately not fuzzy-matched or translated at execution time.
/// Changing an application's language/menu structure requires selecting the item again.
enum InputMenuPathResolver {
    static func resolve<Node>(path:[String],root:Node,children:(Node)throws->[Node],
                             title:(Node)->String,enabled:(Node)->Bool,canPress:(Node)->Bool)throws->Node {
        guard (2...10).contains(path.count),path.allSatisfy({!$0.isEmpty && $0.utf8.count<=1024}) else {
            throw SystemControlError.message("请选择完整菜单路径，包含顶层菜单和最终菜单项。")
        }
        var current=root
        for component in path {
            let siblings=try children(current)
            guard siblings.count<=512 else {throw SystemControlError.message("菜单项目超过安全读取预算。")}
            let matches=siblings.filter{title($0)==component}
            guard matches.count==1 else {throw SystemControlError.message(matches.isEmpty ? "菜单已变化或尚未公开，请重新选择菜单项。":"同级菜单存在重名，已停止以免点错。")}
            current=matches[0]
            guard enabled(current) else {throw SystemControlError.message("目标菜单项当前不可用。")}
        }
        guard canPress(current) else {throw SystemControlError.message("该菜单项未提供公开的辅助功能点按动作。")}
        return current
    }
}

@MainActor enum InputMenuAction {
    struct Choice:Identifiable {
        var id:String {path.joined(separator:"\u{1f}")}
        let path:[String]
        let enabled:Bool
        var title:String {path.joined(separator:" → ")}
    }
    private static func value(_ element:AXUIElement,_ key:String)->CFTypeRef? {
        AXUIElementSetMessagingTimeout(element,0.15)
        var result:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,key as CFString,&result) == .success else{return nil};return result
    }
    private static func title(_ element:AXUIElement)->String {value(element,kAXTitleAttribute) as? String ?? ""}
    private static func enabled(_ element:AXUIElement)->Bool {(value(element,kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false}
    private static func canPress(_ element:AXUIElement)->Bool {
        AXUIElementSetMessagingTimeout(element,0.15)
        var actions:CFArray?;guard AXUIElementCopyActionNames(element,&actions) == .success else{return false}
        return (actions as? [String])?.contains(kAXPressAction) == true
    }
    private static func children(_ element:AXUIElement)throws->[AXUIElement] {
        let values=value(element,kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard values.count<=512 else {throw SystemControlError.message("菜单项目超过安全读取预算。")}
        var result:[AXUIElement]=[]
        for child in values {
            if value(child,kAXRoleAttribute) as? String == kAXMenuRole {
                let nested=value(child,kAXChildrenAttribute) as? [AXUIElement] ?? []
                guard nested.count<=512 else {throw SystemControlError.message("菜单项目超过安全读取预算。")}
                result.append(contentsOf:nested)
            } else {result.append(child)}
        }
        return result
    }
    private static func menuBar(pid:pid_t)throws->AXUIElement {
        guard AXIsProcessTrusted() else {throw SystemControlError.message("浏览和点按菜单需要辅助功能权限。")}
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.15)
        guard let raw=value(app,kAXMenuBarAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {
            throw SystemControlError.message("该应用没有公开可读取的菜单栏。")
        }
        let bar=unsafeBitCast(raw,to:AXUIElement.self);AXUIElementSetMessagingTimeout(bar,0.15);return bar
    }
    static func browse(pid:pid_t)throws->[Choice] {
        guard let application=NSRunningApplication(processIdentifier:pid),!application.isTerminated,
              let launch=application.launchDate else {throw SystemControlError.message("菜单来源应用已退出或身份无法确认。")}
        let root=try menuBar(pid:pid),started=ProcessInfo.processInfo.systemUptime
        var choices:[Choice]=[],visited=0
        func walk(_ node:AXUIElement,path:[String],ancestorsEnabled:Bool)throws {
            visited += 1
            guard visited<=2048,path.count<=10,ProcessInfo.processInfo.systemUptime-started<2 else {throw SystemControlError.message("菜单读取超过预算，请选择较小的菜单或重试。")}
            let list=try children(node)
            for child in list {
                guard ProcessInfo.processInfo.systemUptime-started<2 else {throw SystemControlError.message("菜单读取超过预算，请重试。") }
                let label=title(child);guard !label.isEmpty else{continue}
                let next=path+[label],active=ancestorsEnabled && enabled(child)
                if next.count>=2,canPress(child) {choices.append(.init(path:next,enabled:active))}
                if !(try children(child)).isEmpty {try walk(child,path:next,ancestorsEnabled:active)}
            }
        }
        try walk(root,path:[],ancestorsEnabled:true)
        guard NSRunningApplication(processIdentifier:pid)?.launchDate==launch,!application.isTerminated else {throw SystemControlError.message("读取期间应用已重启，请重新选择。")}
        return choices
    }
    static func perform(path:[String],bundleID:String,pid:pid_t)throws {
        guard let application=NSRunningApplication(processIdentifier:pid),!application.isTerminated,
              application.bundleIdentifier==bundleID,let launch=application.launchDate,
              NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {
            throw SystemControlError.message("菜单目标与当前应用不匹配，已停止。")
        }
        let root=try menuBar(pid:pid),started=ProcessInfo.processInfo.systemUptime
        func withinBudget()->Bool {ProcessInfo.processInfo.systemUptime-started<2}
        let item=try InputMenuPathResolver.resolve(path:path,root:root,children:{node in
            guard withinBudget() else {throw SystemControlError.message("菜单解析超过预算，未执行。")}
            return try children(node)
        },title:{withinBudget() ? title($0):""},enabled:{withinBudget() && enabled($0)},canPress:{withinBudget() && canPress($0)})
        // AX reads are IPC; recheck process identity, foreground and availability immediately before the press.
        guard let current=NSRunningApplication(processIdentifier:pid),!current.isTerminated,
              current.launchDate==launch,current.bundleIdentifier==bundleID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,enabled(item),canPress(item) else {
            throw SystemControlError.message("菜单目标、焦点或可用状态已变化，已停止。")
        }
        let error=AXUIElementPerformAction(item,kAXPressAction as CFString)
        guard error == .success else {throw SystemControlError.message("系统拒绝菜单点按（\(error.rawValue)）。")}
        // Acceptance is not evidence that the target application's business operation completed.
    }
}

@MainActor struct InputMenuSelectionView:View {
    @Binding var bundleID:String
    @Binding var path:[String]
    @State private var choices:[InputMenuAction.Choice]=[]
    @State private var message=""
    var body:some View {
        VStack(alignment:.leading) {
            TextField("菜单目标应用 Bundle ID",text:Binding(get:{bundleID},set:{bundleID=$0;path=[];choices=[]}))
            Menu("浏览运行中应用的菜单") {
                ForEach(NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.bundleIdentifier != nil}.sorted{($0.localizedName ?? "")<($1.localizedName ?? "")},id:\.processIdentifier) {app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                        bundleID=app.bundleIdentifier ?? "";path=[]
                        do {choices=try InputMenuAction.browse(pid:app.processIdentifier);message=choices.isEmpty ? "未读取到菜单项；应用可能只在展开后公开菜单。":"选择菜单项只保存规则，不会点按。"} catch {choices=[];message=error.localizedDescription}
                    }
                }
            }
            if !choices.isEmpty {
                Picker("菜单路径",selection:Binding(get:{path.joined(separator:"\u{1f}")},set:{key in if let choice=choices.first(where:{$0.id==key}) {path=choice.path}})) {
                    Text("请选择").tag("")
                    ForEach(choices) {choice in Text(choice.title+(choice.enabled ? "":L10n.text("（当前不可用）"))).tag(choice.id)}
                }
            }
            Text(path.isEmpty ? L10n.text("尚未选择菜单项"):path.joined(separator:" → ")).textSelection(.enabled)
            if !message.isEmpty {Text(L10n.text(message)).font(.caption)}
            Text("执行时仅点按匹配目标应用的确切路径；重名、失效或禁用时停止。应用语言改变后需重选；动态、未公开菜单需在目标应用内处理。系统接受点按不代表业务已完成。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
