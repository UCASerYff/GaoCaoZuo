import AppKit
import SwiftUI
import Darwin

struct ToolSheet: View {
    @ObservedObject var store: OperationStore
    @ObservedObject var archive: ArchiveService
    let request: ToolRequest
    let items: [URL]
    @State private var directory: String
    @State private var filename = "未命名.txt"
    @State private var content = ""
    @State private var templateID: UUID?
    @State private var pattern = "{name}-{n:03}.{ext}"
    @State private var start = 1
    @State private var plans: [RenamePlan] = []
    @State private var previewError: String?
    @State private var format: ArchiveFormat = .zip
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var split = false
    @State private var splitMB = 100
    @State private var solid = false
    @State private var entries: [ArchiveEntry] = []
    @State private var selectedPaths: Set<String> = []
    @State private var imageFormat = "png"
    @State private var resize = false
    @State private var maxDimension = 1920
    @State private var result = ""
    @State private var resultURL: URL?
    @State private var taskError: String?
    @State private var working = false
    init(store: OperationStore, request: ToolRequest) {
        self.store = store; self.archive = store.archive; self.request = request; self.items = store.selection
        _directory = State(initialValue:store.defaultDirectory.path)
        switch request.actionID {
        case "new.markdown": _filename = State(initialValue:"未命名.md"); _content = State(initialValue:"# 新文档\n\n")
        case "new.folder": _filename = State(initialValue:"新文件夹")
        case "archive.create": _filename = State(initialValue:(store.selection.first?.deletingPathExtension().lastPathComponent ?? "归档")+".zip")
        case "archive.extract", "archive.list": _filename = State(initialValue:(store.selection.first?.deletingPathExtension().lastPathComponent ?? "归档")+"-解压")
        default:
            if request.actionID.hasPrefix("template."), let id = UUID(uuidString:String(request.actionID.dropFirst(9))), let template = store.settings.templates.first(where:{$0.id == id}) {
                _templateID = State(initialValue:id); _filename = State(initialValue:template.filename); _content = State(initialValue:template.content)
            }
        }
    }
    var title: String { OperationAction.all.first(where:{$0.id == request.actionID})?.title ?? (request.actionID == "templates.edit" ? "管理文件模板" : "从模板新建") }
    var running: Bool { working || store.busy || archive.isRunning }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text(title).font(.title2.weight(.semibold)); Spacer(); if running { ProgressView().controlSize(.small) } }.padding(20)
            Divider()
            if request.actionID == "templates.edit" { TemplateEditorView(store:store) }
            else {
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        if !items.isEmpty { Text("当前选择："+items.prefix(4).map(\.lastPathComponent).joined(separator:"、")+(items.count > 4 ? "…" : "")).font(.callout).foregroundStyle(.secondary) }
                        contentView
                        if let error = store.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                        if let taskError { Label(taskError,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                        if let url = resultURL { HStack { Label(url.lastPathComponent,systemImage:"checkmark.circle").foregroundStyle(.green); Spacer(); Button("在 Finder 显示"){NSWorkspace.shared.activateFileViewerSelecting([url])} }; Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(20)
                }
            }
            Divider()
            HStack {
                Text(running ? "正在处理，请等待…" : "目标同名文件不会被覆盖").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if archive.isRunning { Button("取消任务",action:archive.cancel) }
                Button("完成"){store.sheet = nil}.keyboardShortcut(.cancelAction).disabled(running)
            }.padding(16)
        }.frame(width:760,height:650)
        .interactiveDismissDisabled(running)
        .onAppear {
            if ["archive.list","archive.extract"].contains(request.actionID), let path = items.first?.path { do{password = try PasswordVault.read(account:path) ?? ""}catch{taskError=error.localizedDescription} }
            if request.actionID == "files.rename" { updatePreview() }
        }
    }
    @ViewBuilder private var contentView: some View {
        if request.actionID.hasPrefix("new.") || request.actionID.hasPrefix("template.") { newFileView }
        else if request.actionID == "files.copy" || request.actionID == "files.move" { copyMoveView }
        else if request.actionID == "files.rename" { renameView }
        else if request.actionID.hasPrefix("archive.") { archiveView }
        else if request.actionID == "images.convert" { imageView }
        else if request.actionID == "hash.sha256" { hashView }
        else if request.actionID == "text.qrcode" { qrView }
    }
    private var directoryPicker: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("目标目录").font(.headline)
            HStack { TextField("目录完整路径",text:$directory).textFieldStyle(.roundedBorder); Button("选择…"){if let url=store.chooseDirectory(){directory=url.path}} }
            if !store.settings.folders.isEmpty { HStack { Text("常用：").font(.caption).foregroundStyle(.secondary); ForEach(store.settings.folders.prefix(4)) { folder in Button(folder.name){directory=folder.path}.controlSize(.small) }; Spacer() } }
        }
    }
    private var newFileView: some View {
        VStack(alignment:.leading,spacing:16) {
            directoryPicker
            if request.actionID == "new.template" {
                Picker("文件模板",selection:$templateID) { Text("请选择模板").tag(Optional<UUID>.none); ForEach(store.settings.templates){Text($0.name).tag(Optional($0.id))} }.onChange(of:templateID){_,id in if let template=store.settings.templates.first(where:{$0.id == id}){filename=template.filename;content=template.content}}
            }
            TextField("文件名称",text:$filename).textFieldStyle(.roundedBorder)
            if request.actionID != "new.folder" { Text("初始内容").font(.headline); TextEditor(text:$content).font(.system(.body,design:.monospaced)).frame(minHeight:210).border(Color.secondary.opacity(0.3)) }
            Button(request.actionID == "new.folder" ? "创建文件夹" : "创建文件") {
                let dir=URL(fileURLWithPath:directory), name=filename, text=content, folder=request.actionID == "new.folder"
                store.work("创建") {
                    let output: URL
                    if folder {
                        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else{throw DataFailure.message("请输入有效的文件夹名称。")}
                        output=dir.appendingPathComponent(name)
                        guard mkdir(output.path,0o755) == 0 else{throw DataFailure.message("无法创建文件夹：\(String(cString:strerror(errno)))")}
                    } else { output=try FileTools.createFile(in:dir,name:name,content:text) }
                    return [.init(kind:.create,destination:output,fingerprint:try FileTools.fingerprint(output))]
                }
            }.buttonStyle(.borderedProminent).disabled(running || !store.dataHealthy || filename.isEmpty)
        }
    }
    private var copyMoveView: some View {
        VStack(alignment:.leading,spacing:16) {
            directoryPicker
            Text("先检查全部文件是否重名，遇到冲突会停止。移动与复制都会保存恢复记录。").foregroundStyle(.secondary)
            ForEach(items,id:\.self) { url in HStack { Text(url.lastPathComponent); Image(systemName:"arrow.right").foregroundStyle(.secondary); Text(URL(fileURLWithPath:directory).appendingPathComponent(url.lastPathComponent).path).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
            Button(request.actionID == "files.move" ? "移动文件" : "复制文件") { let items=items,to=URL(fileURLWithPath:directory),move=request.actionID == "files.move";store.work(move ? "移动" : "复制"){try FileTools.copy(items:items,to:to,move:move)} }.buttonStyle(.borderedProminent).disabled(running || !store.dataHealthy)
        }
    }
    private var renameView: some View {
        VStack(alignment:.leading,spacing:14) {
            TextField("命名模板",text:$pattern).textFieldStyle(.roundedBorder).onChange(of:pattern){_,_ in updatePreview()}
            Stepper("起始序号：\(start)",value:$start,in:0...999999).onChange(of:start){_,_ in updatePreview()}
            Text("{name} 原名称 · {ext} 扩展名 · {n} 序号 · {n:03} 三位补零；同名冲突停止。").font(.callout).foregroundStyle(.secondary)
            if let previewError { Text(previewError).foregroundStyle(.red) }
            ForEach(plans) { plan in HStack { Text(plan.source.lastPathComponent).frame(maxWidth:.infinity,alignment:.leading); Image(systemName:"arrow.right").foregroundStyle(.secondary); Text(plan.destination.lastPathComponent).frame(maxWidth:.infinity,alignment:.leading) }.padding(.vertical,3) }
            Button("按预览重命名") { let plans=self.plans;store.work("重命名"){try FileTools.applyRenames(plans)} }.buttonStyle(.borderedProminent).disabled(running || previewError != nil || plans.isEmpty || !store.dataHealthy)
        }
    }
    private func updatePreview(){do{plans=try FileTools.renamePreview(items:items,pattern:pattern,start:start);previewError=nil}catch{plans=[];previewError=error.localizedDescription}}
    private var archiveView: some View {
        VStack(alignment:.leading,spacing:14) {
            if request.actionID == "archive.create" {
                directoryPicker
                HStack { TextField("压缩包名称",text:$filename).textFieldStyle(.roundedBorder); Picker("格式",selection:$format){ForEach(ArchiveFormat.allCases){Text($0.title).tag($0)}}.frame(width:170).onChange(of:format){_,value in filename=URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent+"."+value.rawValue;if value == .zip {solid=false}} }
                SecureField("加密密码（留空不加密）",text:$password).textFieldStyle(.roundedBorder)
                Toggle("将密码保存到系统钥匙串",isOn:$rememberPassword).disabled(password.isEmpty)
                Toggle("分卷压缩",isOn:$split)
                if split { Stepper("每卷 \(splitMB) MB",value:$splitMB,in:1...100000) }
                if format == .sevenZip { Toggle("固实压缩",isOn:$solid); Text("7Z 设置密码时自动加密文件名；ZIP 使用 AES 加密，部分系统解压器可能不支持。").font(.caption).foregroundStyle(.secondary) }
                Button("开始压缩",action:createArchive).buttonStyle(.borderedProminent).disabled(running || filename.isEmpty || !store.dataHealthy)
            } else {
                if items.count != 1 { Label("请仅选择一个压缩包或首个 .001 分卷。",systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }
                directoryPicker
                TextField("新的解压文件夹名称",text:$filename).textFieldStyle(.roundedBorder)
                SecureField("压缩包密码（需要时填写）",text:$password).textFieldStyle(.roundedBorder)
                Toggle("将密码保存到系统钥匙串",isOn:$rememberPassword).disabled(password.isEmpty)
                HStack { Button("查看包内文件",action:listArchive).disabled(running || items.count != 1); Button("全部解压"){extractArchive(selected:nil)}.buttonStyle(.borderedProminent).disabled(running || items.count != 1 || !store.dataHealthy); if !selectedPaths.isEmpty { Button("提取勾选 \(selectedPaths.count) 项"){extractArchive(selected:Array(selectedPaths))}.disabled(running || !store.dataHealthy) } }
                if !entries.isEmpty { HStack { Text("\(entries.count) 个项目").font(.caption); Spacer(); Button("全选文件"){selectedPaths=Set(entries.filter{!$0.isDirectory}.map(\.path))};Button("清除勾选"){selectedPaths=[]} }; ForEach(entries.prefix(2000)) { entry in HStack { Toggle(isOn:Binding(get:{selectedPaths.contains(entry.path)},set:{v in if v{selectedPaths.insert(entry.path)}else{selectedPaths.remove(entry.path)}})){Label(entry.path,systemImage:entry.isDirectory ? "folder" : "doc")}; Spacer(); Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:entry.size),countStyle:.file)).font(.caption).foregroundStyle(.secondary) }.disabled(entry.isDirectory) }; if entries.count > 2000 {Text("列表仅展示前 2000 项；全部解压仍处理完整内容。").font(.caption).foregroundStyle(.secondary)} }
            }
            if archive.isRunning { if let p=archive.progress{ProgressView(value:p)}else{ProgressView()} }
            if !archive.output.isEmpty {
                DisclosureGroup("查看任务日志") {
                    Text(archive.output.replacingOccurrences(of:"\u{8}",with:"")).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding().background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                }.font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func createArchive() {
        guard filename == URL(fileURLWithPath:filename).lastPathComponent, !filename.contains(".."), !filename.isEmpty else{taskError="请输入有效的压缩包名称。";return}
        let items=items,destination=URL(fileURLWithPath:directory).appendingPathComponent(filename),pw=password.isEmpty ? nil : password
        Task { do {taskError=nil;let output=try await archive.create(items:items,destination:destination,format:format,password:pw,splitMB:split ? splitMB : nil,solid:solid);resultURL=output;if rememberPassword,let pw{try PasswordVault.save(pw,account:output.path)};store.message="压缩完成"}catch{taskError=error.localizedDescription} }
    }
    private func listArchive() {
        guard let url=items.first,items.count == 1 else{return}
        Task {do{taskError=nil;entries=try await archive.list(archive:url,password:password.isEmpty ? nil : password);selectedPaths=[]}catch{taskError=error.localizedDescription}}
    }
    private func extractArchive(selected:[String]?) {
        guard let url=items.first,items.count == 1 else{return}
        guard !filename.isEmpty,filename != ".",filename != "..",!filename.contains("/"),!filename.contains("\0") else{taskError="请输入有效的新文件夹名称。";return}
        let destination=URL(fileURLWithPath:directory).appendingPathComponent(filename),pw=password.isEmpty ? nil : password
        Task {do{taskError=nil;let output=try await archive.extract(archive:url,to:destination,password:pw,selected:selected);resultURL=output;if rememberPassword,let pw{try PasswordVault.save(pw,account:url.path)};store.message="解压完成"}catch{taskError=error.localizedDescription}}
    }
    private var imageView: some View {
        VStack(alignment:.leading,spacing:16) {
            directoryPicker
            Picker("输出格式",selection:$imageFormat){Text("PNG").tag("png");Text("JPEG").tag("jpeg");Text("HEIC").tag("heic");Text("TIFF").tag("tiff")}.pickerStyle(.segmented)
            Toggle("限制最长边",isOn:$resize)
            if resize { Stepper("最长边 \(maxDimension) 像素",value:$maxDimension,in:16...16384,step:16) }
            Text("保留原图片，输出为新文件。多帧与多页图片会提示；转换会去除源图片定位等元数据。").font(.callout).foregroundStyle(.secondary)
            Button("转换图片") { let items=items,to=URL(fileURLWithPath:directory),format=imageFormat,size=resize ? maxDimension : nil;store.work("图片转换"){let outputs=try FileTools.convertImages(items:items,to:to,format:format,maxDimension:size);return try outputs.map{.init(kind:.convert,destination:$0,fingerprint:try FileTools.fingerprint($0))}} }.buttonStyle(.borderedProminent).disabled(running || !store.dataHealthy)
        }
    }
    private var hashView: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("为所选普通文件计算 SHA-256，不修改文件内容。").foregroundStyle(.secondary)
            Button("开始计算") { let items=items;working=true;Task{do{result=try await Task.detached{try items.map{try FileTools.sha256($0)+"  "+$0.lastPathComponent}.joined(separator:"\n")}.value;taskError=nil}catch{taskError=error.localizedDescription};working=false} }.disabled(running)
            if !result.isEmpty { Text(result).font(.system(.body,design:.monospaced)).textSelection(.enabled);Button("复制校验值"){store.clipboard.copyText(result)} }
        }
    }
    private var qrView: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("输入文本或完整网址").font(.headline)
            TextEditor(text:$content).frame(height:160).border(Color.secondary.opacity(0.3))
            Button("生成并保存 PNG…") {
                let panel=NSSavePanel();panel.nameFieldStringValue="二维码.png";panel.canCreateDirectories=true
                guard panel.runModal() == .OK,let url=panel.url else{return}
                let text=content;store.work("生成二维码"){let bytes=try FileTools.qrCode(text:text);try bytes.write(to:url,options:.withoutOverwriting);return [.init(kind:.create,destination:url,fingerprint:try FileTools.fingerprint(url))]}
            }.buttonStyle(.borderedProminent).disabled(content.isEmpty || running || !store.dataHealthy)
        }
    }
}

struct TemplateEditorView: View {
    @ObservedObject var store: OperationStore
    @State private var selected: UUID?
    @State private var name=""
    @State private var filename="未命名.txt"
    @State private var content=""
    var body: some View {
        HStack(spacing:0) {
            VStack { List(selection:$selected){ForEach(store.settings.templates){Text($0.name).tag($0.id)}};HStack{Button("新增"){selected=nil;name="新模板";filename="未命名.txt";content=""};Button("删除"){if let selected{store.update{$0.templates.removeAll{$0.id == selected}};self.selected=nil;name=""}}.disabled(selected==nil)}.padding() }.frame(width:190)
            Divider()
            VStack(alignment:.leading,spacing:14){TextField("模板名称",text:$name);TextField("默认文件名（含扩展名）",text:$filename);TextEditor(text:$content).font(.system(.body,design:.monospaced)).border(Color.secondary.opacity(0.3));Button("保存模板"){let value=TextTemplate(id:selected ?? UUID(),name:name,filename:filename,content:content);store.update{if let i=$0.templates.firstIndex(where:{$0.id == value.id}){$0.templates[i]=value}else{$0.templates.append(value)}};selected=value.id}.buttonStyle(.borderedProminent).disabled(name.isEmpty || filename.isEmpty || !store.dataHealthy)}.padding(20)
        }.onChange(of:selected){_,id in if let t=store.settings.templates.first(where:{$0.id == id}){name=t.name;filename=t.filename;content=t.content}}
    }
}
