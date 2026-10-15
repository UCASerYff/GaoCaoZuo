import AppKit

struct CrossApplicationAction: Identifiable {
    var id:String {"service."+action}
    let action:String
    let title:String
    let provider:String
    var bundleID:String {provider == "portal" ? "cn.mendao.launcher" : "com.gaoseries."+provider}
    var needsItems:Bool {["ocr.files","images.annotate","images.pin","text.translate","documents.open","documents.newText"].contains(action)}
    var referenceKind:String? {
        switch action {case "storage.inspect":return "directory";case "apps.uninstall.review":return "application";case "files.reveal":return "any";case "files.search","files.choose":return "optionalDirectory";default:return nil}
    }
}

enum CrossApplicationActions {
    static let entries:[CrossApplicationAction] = [
        .init(action:"capture.region",title:"搞截图：截取区域",provider:"GaoJieTu"),
        .init(action:"capture.window",title:"搞截图：截取窗口",provider:"GaoJieTu"),
        .init(action:"capture.display",title:"搞截图：截取屏幕",provider:"GaoJieTu"),
        .init(action:"ocr.files",title:"搞截图：识别文件文字",provider:"GaoJieTu"),
        .init(action:"images.annotate",title:"搞截图：标注图片",provider:"GaoJieTu"),
        .init(action:"images.pin",title:"搞截图：贴图",provider:"GaoJieTu"),
        .init(action:"text.translate",title:"搞截图：翻译文本文件",provider:"GaoJieTu"),
        .init(action:"files.search",title:"搞整理：搜索文件",provider:"GaoZhengLi"),
        .init(action:"files.choose",title:"搞整理：选择文件",provider:"GaoZhengLi"),
        .init(action:"files.reveal",title:"搞整理：定位原件",provider:"GaoZhengLi"),
        .init(action:"associations.manage",title:"搞整理：管理文件关联",provider:"GaoZhengLi"),
        .init(action:"documents.open",title:"搞文件：打开文档副本",provider:"GaoWenJian"),
        .init(action:"documents.newText",title:"搞文件：新建文字文档",provider:"GaoWenJian"),
        .init(action:"windows.overview",title:"搞桌面：窗口总览",provider:"GaoZhuoMian"),
        .init(action:"desktop.openSettings",title:"搞桌面：打开设置",provider:"GaoZhuoMian"),
        .init(action:"downloads.prepare",title:"搞下载：准备下载",provider:"GaoXiaZai"),
        .init(action:"storage.inspect",title:"搞机灵：分析目录",provider:"GaoJiLing"),
        .init(action:"cleanup.review",title:"搞机灵：清理复核",provider:"GaoJiLing"),
        .init(action:"apps.uninstall.review",title:"搞机灵：卸载复核",provider:"GaoJiLing"),
        .init(action:"portal.openSite",title:"搞门户：打开已存站点",provider:"portal"),
        .init(action:"portal.openWorkspace",title:"搞门户：打开已存工作区",provider:"portal"),
        .init(action:"portal.focusSearch",title:"搞门户：搜索",provider:"portal"),
        .init(action:"portal.proposeSite",title:"搞门户：编辑新增站点",provider:"portal"),
        .init(action:"portal.prepareDownload",title:"搞门户：转交下载复核",provider:"portal")
    ]
    static func bundleID(_ entry:CrossApplicationAction)->String {entry.provider == "portal" ? "cn.mendao.launcher" : entry.bundleID}
    static var actions:[OperationAction] {
        [.init(id:"service.compose",title:"跨应用交接与导出",detail:"按实际能力发送；缺少提供方可导出私有交接包",icon:"arrow.triangle.branch",section:.tools)]
        + entries.map {.init(id:$0.id,title:$0.title,detail:"GaoAction V1 · 在提供方复核并返回实际状态",icon:"arrow.up.forward.app",section:.tools)}
    }
    static let legacyIDs:[String:String] = ["file.ishot":"capture.region","file.capture.window":"capture.window","file.capture.display":"capture.display","file.ishot.markup":"images.annotate","file.images.pin":"images.pin","file.ocr":"ocr.files","file.diskmap":"storage.inspect","file.storage.duplicates":"storage.inspect","file.cleanup.review":"cleanup.review","file.apps.uninstall.review":"apps.uninstall.review","selection.translate":"text.translate","selection.sendToFiles":"documents.newText"]
}

@MainActor final class CrossApplicationAvailability {
    static let shared=CrossApplicationAvailability()
    private var cached:[String:Result<GaoActionProviderCapabilities,Error>]=[:]
    private var expires=Date.distantPast
    func invalidate(){expires = .distantPast}
    func unavailableReason(for id:String)->String? {
        guard let entry=CrossApplicationActions.entries.first(where:{$0.id == id || $0.action == CrossApplicationActions.legacyIDs[id]}) else {return nil}
        if Date() >= expires {cached=[:];expires=Date().addingTimeInterval(5)}
        let bundleID=CrossApplicationActions.bundleID(entry)
        let result:Result<GaoActionProviderCapabilities,Error>
        if let existing=cached[bundleID] {result=existing}
        else {
            result=Result {
                guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) else {throw GaoActionError.providerNotReady("未安装提供方；可从跨应用交接导出私有包")}
                return try GaoActionProviderCapabilities.load(appURL:url,bundleID:bundleID)
            }
            cached[bundleID]=result
        }
        do {
            let capabilities=try result.get()
            guard capabilities.actions.contains(where:{$0.action == entry.action}) else {return "提供方尚未声明此动作；可导出交接包"}
            if id == "file.storage.duplicates" {try capabilities.require(action:entry.action,parameters:["mode":"duplicates"],items:false,references:true)}
            return nil
        } catch {return error.localizedDescription}
    }
}
