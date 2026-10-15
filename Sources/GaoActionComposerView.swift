import AppKit
import SwiftUI

@MainActor struct GaoActionComposerView:View {
    @ObservedObject var store:OperationStore
    @State private var selectedID:String
    @State private var files:[URL]
    @State private var value=""
    @State private var secondary=""
    @State private var targetLanguage="zh-Hans"
    @State private var sourceLanguage="auto"
    @State private var ocrOutput=""
    @State private var delay=0
    @State private var duplicates=false
    @State private var multiple=false
    @State private var status:String?
    @State private var unavailable:String?
    @State private var exported:URL?
    private var running:Bool {store.crossApplicationBusy}
    init(store:OperationStore,initialID:String,files:[URL]) {
        self.store=store
        _selectedID=State(initialValue:CrossApplicationActions.entries.contains(where:{$0.id == initialID}) ? initialID : "service.capture.region")
        _files=State(initialValue:files)
    }
    private var entry:CrossApplicationAction {CrossApplicationActions.entries.first(where:{$0.id == selectedID}) ?? CrossApplicationActions.entries[0]}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Picker("动作",selection:$selectedID) {ForEach(CrossApplicationActions.entries) {Text(L10n.text($0.title)).tag($0.id)}}
                Text("仅传递本次明确选择的副本或引用；提供方仍需复核。打开请求成功不代表截图、下载、清理或其他业务完成。").font(.callout).foregroundStyle(.secondary)
                if let unavailable {Label(L10n.text(unavailable),systemImage:"exclamationmark.triangle").foregroundStyle(.orange);Text("可导出私有交接包。有效期120秒，过期后请重新生成。").font(.caption)}
                if entry.needsItems || entry.referenceKind != nil {inputSelection}
                parameters
                if let status {Text(L10n.text(status)).textSelection(.enabled)}
                if let exported {Button("在 Finder 显示交接包") {NSWorkspace.shared.activateFileViewerSelecting([exported])}}
                HStack {
                    Button("刷新提供方状态") {refresh()}
                    Spacer()
                    Button("导出私有交接包") {submit(exportOnly:true)}
                    Button("交给提供方复核") {submit(exportOnly:false)}.disabled(unavailable != nil)
                }
                if running {ProgressView("正在建立并核验交接包…")}
            }.padding(20).disabled(running)
        }.onAppear {refresh()}.onChange(of:selectedID) {_,_ in value="";secondary="";status=nil;exported=nil;refresh()}
    }
    private var inputSelection:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Text(L10n.text(entry.needsItems ? "所选文件副本" : "原件或目录引用")).font(.headline);Spacer();Button("重新选择…") {chooseInputs()};if entry.referenceKind == "optionalDirectory" {Button("不限目录") {files=[]}}}
            ForEach(files,id:\.path) {url in Text(url.path).font(.caption).textSelection(.enabled)}
            Text(L10n.text(entry.needsItems ? "普通文件副本，最多256项、总计2GiB；图像与文本类型由契约再次校验。" : "引用不会复制原文件，也不会转移目录访问授权或删除许可。失效时由提供方重新确认。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var parameters:some View {
        let action=entry.action
        if action.hasPrefix("capture.") {Stepper("延时 \(delay) 秒",value:$delay,in:0...60)}
        if action == "text.translate" {
            TextField("目标语言（BCP47）",text:$targetLanguage);TextField("来源语言（auto 或 BCP47）",text:$sourceLanguage)
        }
        if action == "ocr.files" {
            TextField("识别语言（可选，逗号分隔）",text:$value)
            Picker("输出",selection:$ocrOutput) {Text("提供方默认").tag("");Text("纯文本").tag("text");Text("Markdown").tag("markdown");Text("JSON").tag("json");Text("可搜索PDF").tag("searchablePDF")}
        }
        if action == "storage.inspect" {Toggle("请求重复文件分析（须提供方声明支持）",isOn:$duplicates)}
        if action == "files.search" || action == "portal.focusSearch" {TextField("搜索词",text:$value)}
        if action == "files.choose" {Toggle("允许多选",isOn:$multiple);TextField("允许的UTI（可选，逗号分隔）",text:$value)}
        if action == "associations.manage" {TextField("预填UTI（可选）",text:$value)}
        if action == "documents.newText" {TextField("建议文档名称（可选）",text:$value)}
        if action == "portal.openSite" {TextField("已存站点ID",text:$value);TextField("已存浏览器ID（可选）",text:$secondary)}
        if action == "portal.openWorkspace" {TextField("已存工作区ID",text:$value)}
        if action == "portal.proposeSite" {TextField("http/https网址",text:$value);TextField("标题（可选）",text:$secondary)}
        if action == "downloads.prepare" || action == "portal.prepareDownload" {
            Text("下载网址（每行一个，最多32个）")
            TextEditor(text:$value).frame(height:90).border(.quaternary)
            Text("这里只准备并交给提供方复核，不表示下载已完成。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refresh() {CrossApplicationAvailability.shared.invalidate();unavailable=CrossApplicationAvailability.shared.unavailableReason(for:selectedID)}
    private func chooseInputs() {
        let panel=NSOpenPanel()
        panel.canChooseDirectories=entry.referenceKind != nil
        panel.canChooseFiles=entry.referenceKind != "directory" && entry.referenceKind != "optionalDirectory"
        panel.allowsMultipleSelection=entry.needsItems && !["text.translate","documents.newText","images.pin","images.annotate"].contains(entry.action)
        panel.message=L10n.text(entry.needsItems ? "选择本次明确发送的普通文件副本" : "选择本次交接引用的真实对象")
        if panel.runModal() == .OK {files=panel.urls}
    }
    private func build() throws -> (parameters:[String:Any],items:[URL],references:[GaoActionReference]) {
        let action=entry.action
        var params:[String:Any]=[:]
        switch action {
        case "capture.region","capture.window","capture.display":if delay > 0 {params["delaySeconds"]=delay}
        case "text.translate":params=["targetLanguage":targetLanguage,"sourceLanguage":sourceLanguage]
        case "ocr.files":if !value.isEmpty {params["languages"]=value.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}};if !ocrOutput.isEmpty {params["outputs"]=[ocrOutput]}
        case "storage.inspect":if duplicates {params["mode"]="duplicates"}
        case "files.search":params["query"]=value
        case "files.choose":if multiple {params["multiple"]=true};if !value.isEmpty {params["allowedUTIs"]=value.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}}
        case "associations.manage":if !value.isEmpty {params["uti"]=value}
        case "documents.newText":if !value.isEmpty {params["suggestedTitle"]=value}
        case "portal.openSite":params["siteID"]=value;if !secondary.isEmpty {params["browserID"]=secondary}
        case "portal.openWorkspace":params["workspaceID"]=value
        case "portal.focusSearch":if !value.isEmpty {params["query"]=value}
        case "portal.proposeSite":params["url"]=value;if !secondary.isEmpty {params["title"]=secondary}
        case "downloads.prepare","portal.prepareDownload":params["urls"]=value.split(whereSeparator:{$0.isNewline}).map{String($0).trimmingCharacters(in:.whitespaces)}
        default:break
        }
        let items=entry.needsItems ? files : []
        var references:[GaoActionReference]=[]
        if let kind=entry.referenceKind {
            guard kind == "optionalDirectory" && files.isEmpty || files.count == 1 else {throw DataFailure.message("请选择一个明确的原件或目录。")}
            references=try files.map {try GaoActionV1.reference(for:$0)}
            if ["directory","optionalDirectory"].contains(kind),references.contains(where:{$0.kind != .directory}) {throw DataFailure.message("此动作只接受目录引用。")}
            if kind == "application",references.first?.kind != .application {throw DataFailure.message("请选择真实应用包。")}
        }
        if entry.needsItems,items.isEmpty {throw DataFailure.message("请先选择本次发送的文件。")}
        return (params,items,references)
    }
    private func submit(exportOnly:Bool) {
        guard !running else {return}
        guard store.dataHealthy else {status="资料处于保护模式，未建立交接包。";return}
        do {
            let draft=try build();let request=entry;let client=GaoActionClient(dataDirectory:store.data.directory)
            let operation=store.beginCrossApplicationOperation();status=nil
            Task { @MainActor in
                defer {store.endCrossApplicationOperation(operation)}
                do {
                    if exportOnly {
                        exported=try await client.exportRequest(action:request.action,targetBundleID:CrossApplicationActions.bundleID(request),parameters:draft.parameters,inputFiles:draft.items,references:draft.references)
                        status="已生成私有交接包，动作尚未执行。"
                    } else {
                        _ = try await client.sendRequest(action:request.action,targetBundleID:CrossApplicationActions.bundleID(request),parameters:draft.parameters,inputFiles:draft.items,references:draft.references)
                        status="已递交，等待提供方确认；请从跨应用任务记录查看实际完成或取消状态。"
                    }
                } catch {status=error.localizedDescription}
            }
        } catch {status=error.localizedDescription}
    }
}
