import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FileEnhancementController {
    @discardableResult func handle(id:String,files:[URL],store:OperationStore)->Bool {
        guard FileEnhancements.actions.contains(where:{$0.id==id}) || id.hasPrefix("file.open.") || id.hasPrefix("file.template.") else{return false}
        guard healthy,store.dataHealthy else{store.notify(data.failure ?? "资料读取失败，已停止操作。",failed:true);return true}
        guard !store.busy,!store.quickJobActive,!store.workflowRunning,!store.archive.isRunning else{store.notify("请等待当前任务结束。",failed:true);return true}
        let directory=store.directory(for:files)
        if ["file.permissions","file.info","file.dissolve","file.openApp","file.template.create","file.new.office","file.fixNames","file.icon.builtin"].contains(id) || (id=="file.delete" && settings.confirmPermanentDelete) {
            request=EnhancementToolRequest(action:id,files:files);store.showMain?();return true
        }
        do {
            if id.hasPrefix("file.new."),FileEnhancements.documentFormats.contains(String(id.dropFirst(9))) {
                if settings.newFileViaWindow { request=EnhancementToolRequest(action:id,files:files);store.showMain?();return true }
                let receipt=try createOffice(String(id.dropFirst(9)),in:directory);try store.record([receipt]);store.completeNewFile(receipt.destination);store.notify("已创建文档",outputs:[receipt.destination]);return true
            }
            if id=="file.template.import" {
                let p=NSOpenPanel();p.canChooseFiles=true;p.canChooseDirectories=true;p.treatsFilePackagesAsDirectories=false;p.message="选择你拥有的模板文件或文档包；按原字节保存，不复制其他软件的商业模板。"
                if p.runModal() == .OK,let source=p.url {try importTemplate(source);store.notify("模板已导入")};return true
            }
            if id.hasPrefix("file.open."),let uuid=UUID(uuidString:String(id.dropFirst(10))),let app=settings.apps.first(where:{$0.id==uuid}) {try open(files,with:app);return true}
            if id.hasPrefix("file.template."),let uuid=UUID(uuidString:String(id.dropFirst(14))) {let receipt=try createTemplate(uuid,directory:directory);try store.record([receipt]);store.completeNewFile(receipt.destination);store.notify("已创建模板文件",outputs:[receipt.destination]);return true}
            switch id {
            case "file.hide","file.unhide","file.hideAll","file.unhideAll":
                let all=id.hasSuffix("All"),hide=id=="file.hide" || id=="file.hideAll"
                let targets=all ? try EnhancedFileTools.children(directory) : files
                guard !targets.isEmpty else{throw FileToolsError.invalid("没有需要处理的项目。")}
                try changeMetadata(targets,kind:"hidden",value:hide ? 1 : 0);store.notify("已修改 \(targets.count) 项的隐藏属性")
            case "file.extension.hide","file.extension.show": try changeMetadata(files,kind:"extension",value:id.hasSuffix("hide") ? 1 : 0);store.notify("已更新扩展名显示属性")
            case "file.write": try changeMetadata(files,kind:"write",value:0);store.notify("已授予所有者写权限")
            case "file.metadata.undo": try undoMetadata();store.notify("已恢复上次文件属性")
            case "file.cut":try beginCut(files);store.notify("已剪切 \(files.count) 项，前往目标目录后选择“粘贴剪切的文件”")
            case "file.paste":let records=try pasteCut(to:directory);try store.record(records);store.notify("已移动 \(records.count) 项",outputs:records.map(\.destination))
            case "file.folderNames":store.work("按文件名建目录"){try EnhancedFileTools.foldersUsingNames(files)}
            case "file.delete":store.work("彻底删除"){try EnhancedFileTools.permanentlyDelete(files,confirmation:"彻底删除");return []}
            case "file.alias":let desktop=FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first!;store.work("创建桌面替身"){try EnhancedFileTools.aliases(files,to:desktop)}
            case "file.path.real":let sources=files.isEmpty ? [directory] : files;store.clipboard.copyText(sources.map{$0.resolvingSymlinksInPath().path}.joined(separator:"\n"));store.notify("已复制真实路径")
            case "file.path.custom":let prefix=settings.customPathPrefix,sources=files.isEmpty ? [directory] : files;store.clipboard.copyText(sources.map{prefix+$0.path}.joined(separator:"\n"));store.notify("已复制自定义前缀路径")
            case "file.icon":
                let p=NSOpenPanel();p.allowedContentTypes=[.image];p.message="选择用作图标的图片"
                if p.runModal() == .OK,let url=p.url,let image=NSImage(contentsOf:url) {for file in files {_ = try EnhancedFileTools.checked(file);guard NSWorkspace.shared.setIcon(image,forFile:file.path,options:[]) else{throw FileToolsError.invalid("无法设置图标：\(file.path)")}};store.notify("已设置图标")}
            case "file.icon.clear":for file in files {_ = try EnhancedFileTools.checked(file);guard NSWorkspace.shared.setIcon(nil,forFile:file.path,options:[]) else{throw FileToolsError.invalid("无法清除图标：\(file.path)")}};store.notify("已恢复默认图标")
            case "file.wallpaper":guard let first=files.first else{throw FileToolsError.invalid("请选择图片。")};_ = try FileEnhancementImages.source(first);guard let screen=NSScreen.main else{throw FileToolsError.invalid("屏幕不可用。")};try NSWorkspace.shared.setDesktopImageURL(first,for:screen,options:[:]);store.notify("已设置桌面墙纸")
            case "file.airdrop","file.mail":
                let name:NSSharingService.Name=id=="file.airdrop" ? .sendViaAirDrop : .composeEmail
                guard let service=NSSharingService(named:name),service.canPerform(withItems:files) else{throw FileToolsError.invalid("系统当前无法使用该分享服务。")};service.perform(withItems:files)
            case "file.terminal":try terminal(directory,newWindow:settings.terminalNewWindow)
            case "file.ishot":try launchInstalled(["cn.better365.iShotPro","cn.better365.ishot"],files:files,description:"iShot")
            case "file.ishot.markup":try launchInstalled(["cn.better365.iShotPro","cn.better365.ishot"],files:files,description:"iShot")
            case "file.diskmap":try launchInstalled(["com.Aodo365.DiskMap","com.Aodo365.DiskMapOffline"],files:files,description:"DiskMap")
            case "images.webp","images.icns","images.macicons","images.iosicons":let kind=String(id.dropFirst(7));store.work("转换图片"){try FileEnhancementImages.create(files,kind:kind)}
            case "text.baidu","text.google":guard let text=NSPasteboard.general.string(forType:.string),!text.isEmpty else{throw FileToolsError.invalid("剪贴板没有文字。")};try translate(text,provider:id)
            default:throw FileToolsError.invalid("尚未找到对应文件增强动作。")
            }
        } catch {store.notify(error.localizedDescription,failed:true)}
        return true
    }
    func translate(_ text:String,provider:String) throws {
        guard !text.isEmpty,text.utf8.count<=16000 else{throw FileToolsError.invalid("翻译文字为空或超过 16 KB。")}
        var url=URLComponents(string:provider.contains("baidu") ? "https://fanyi.baidu.com/mtpe-individual/multimodal" : "https://translate.google.com/")!
        url.queryItems=provider.contains("baidu") ? [URLQueryItem(name:"query",value:text),URLQueryItem(name:"lang",value:"auto2zh")] : [URLQueryItem(name:"sl",value:"auto"),URLQueryItem(name:"tl",value:"zh-CN"),URLQueryItem(name:"text",value:text),URLQueryItem(name:"op",value:"translate")]
        guard let target=url.url,NSWorkspace.shared.open(target) else{throw FileToolsError.invalid("无法打开翻译网页。")}
    }
    func terminal(_ directory:URL,newWindow:Bool) throws {
        _ = try EnhancedFileTools.checked(directory)
        guard let terminalApp=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Terminal") else {
            throw FileToolsError.invalid("找不到系统终端应用。")
        }
        if newWindow {
            let config=NSWorkspace.OpenConfiguration()
            config.activates=true
            NSWorkspace.shared.open([directory],withApplicationAt:terminalApp,configuration:config){_,failure in
                if let failure {Task{@MainActor in self.error=failure.localizedDescription}}
            }
            return
        }
        func literal(_ value:String)->String {"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r")+"\""}
        let command="cd -- '"+directory.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="tell application id \"com.apple.Terminal\"\nactivate\nif (count of windows) is 0 then\ndo script "+literal(command)+"\nelse\ntell application \"System Events\" to keystroke \"t\" using command down\ndo script "+literal(command)+" in selected tab of front window\nend if\nend tell"
        var error:NSDictionary?
        guard let apple=NSAppleScript(source:script) else{throw FileToolsError.invalid("终端脚本无效。")}
        apple.executeAndReturnError(&error)
        if let error {
            let config=NSWorkspace.OpenConfiguration();config.activates=true
            NSWorkspace.shared.open([directory],withApplicationAt:terminalApp,configuration:config,completionHandler:nil)
            throw FileToolsError.invalid("终端新标签页需要系统自动化权限（已在独立窗口打开）：\(error[NSAppleScript.errorMessage] ?? "")")
        }
    }
    func addApplication() throws {
        let p=NSOpenPanel();p.allowedContentTypes=[.application];p.message="选择用来打开当前文件或目录的应用"
        guard p.runModal() == .OK,let url=p.url,let bundle=Bundle(url:url),let id=bundle.bundleIdentifier else{return}
        try update{$0.apps.append(.init(name:url.deletingPathExtension().lastPathComponent,bundleID:id,path:url.path))}
    }
    func open(_ files:[URL],with app:EnhancedOpenApp) throws {
        let saved=URL(fileURLWithPath:app.path)
        let url=(Bundle(url:saved)?.bundleIdentifier==app.bundleID ? saved : nil) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier:app.bundleID)
        guard let url else{throw FileToolsError.invalid("未找到应用：\(app.name)")}
        NSWorkspace.shared.open(files,withApplicationAt:url,configuration:NSWorkspace.OpenConfiguration()){[weak self] _,failure in if let failure{Task{@MainActor in self?.error=failure.localizedDescription}}}
    }
    private func launchInstalled(_ ids:[String],files:[URL],description:String) throws {
        guard let app=ids.compactMap({NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0)}).first else{throw FileToolsError.invalid("尚未安装 \(description)；未执行外部工具操作。")}
        NSWorkspace.shared.open(files,withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()){[weak self] _,failure in if let failure{Task{@MainActor in self?.error=failure.localizedDescription}}}
    }
    func createOffice(_ ext:String,in directory:URL,resourceDirectory:URL?=nil) throws -> FileOperationReceipt {
        guard FileEnhancements.documentFormats.contains(ext) else{throw FileToolsError.invalid("该格式请导入你自己的有效模板。")}
        guard let source=resourceDirectory?.appendingPathComponent("Blank."+ext) ?? Bundle.main.url(forResource:"Blank",withExtension:ext,subdirectory:"DocumentTemplates") else{throw FileToolsError.invalid("内置文档模板资源缺失。")}
        let bytes=try Data(contentsOf:source);guard !bytes.isEmpty else{throw FileToolsError.invalid("模板内容为空。")}
        let output=try QuickFileActions.uniqueURL(in:directory,preferredName:"未命名."+ext)
        try bytes.write(to:output,options:.withoutOverwriting)
        return .init(kind:.create,destination:output,fingerprint:try FileTools.fingerprint(output))
    }
}

@MainActor struct FileEnhancementSettingsView:View {
    @ObservedObject var controller:FileEnhancementController
    @State private var message=""
    private func change(_ block:(inout FileEnhancementSettings)->Void){do{try controller.update(block)}catch{message=error.localizedDescription}}
    var body:some View {
        Form {
            Section("文件行为") {
                Toggle("通过文件模板新建后自动打开",isOn:Binding(get:{controller.settings.autoOpenNew},set:{v in change{$0.autoOpenNew=v}}))
                Toggle("新建内置文档时先显示窗口",isOn:Binding(get:{controller.settings.newFileViaWindow},set:{v in change{$0.newFileViaWindow=v}}))
                Toggle("剪切时隐藏文件（粘贴或取消后恢复）",isOn:Binding(get:{controller.settings.cutHidesFiles},set:{v in change{$0.cutHidesFiles=v}}))
                Toggle("彻底删除前再次确认",isOn:Binding(get:{controller.settings.confirmPermanentDelete},set:{v in change{$0.confirmPermanentDelete=v}}))
                Toggle("Terminal 使用新窗口（关闭则新标签页）",isOn:Binding(get:{controller.settings.terminalNewWindow},set:{v in change{$0.terminalNewWindow=v}}))
                Text("控制 Terminal 会按需请求自动化权限；新标签页还需系统事件与辅助功能权限。").font(.caption).foregroundStyle(.secondary)
                TextField("自定义复制路径前缀",text:Binding(get:{controller.settings.customPathPrefix},set:{v in change{$0.customPathPrefix=v}}))
                Button("取消当前剪切并恢复隐藏属性"){do{try controller.cancelCut();message="已取消剪切"}catch{message=error.localizedDescription}}
            }
            Section("原样文件模板") {
                Text("支持你自己的 Office、iWork、WPS、设计文档及文件包。内容逐文件核验；不会把普通文本改后缀冒充文档。单个附件最多 32 MB，模板合计最多 128 MB。").font(.caption).foregroundStyle(.secondary)
                ForEach(controller.settings.templates){template in HStack{Text(template.name);Spacer();Text(template.filename).foregroundStyle(.secondary);Button("移除"){change{$0.templates.removeAll{$0.id==template.id}}}}}
                Button("导入模板…"){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;if panel.runModal() == .OK,let url=panel.url{do{try controller.importTemplate(url)}catch{message=error.localizedDescription}}}
            }
            Section("用指定应用打开当前文件") {
                ForEach(controller.settings.apps){app in HStack{Text(app.name);Spacer();Button("移除"){change{$0.apps.removeAll{$0.id==app.id}}}}}
                Button("添加应用…"){do{try controller.addApplication()}catch{message=error.localizedDescription}}
            }
            Section("恢复") {
                Button("恢复上次文件属性修改"){do{try controller.undoMetadata();message="已恢复"}catch{message=error.localizedDescription}}
                Button("恢复上次解散文件夹"){do{try controller.undoDissolve();message="已恢复"}catch{message=error.localizedDescription}}
                Text("解散时保留隐藏的空目录外壳供恢复；不清理用户文件。永久删除不进入恢复记录。").font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty{Text(message).foregroundStyle(.orange).textSelection(.enabled)}
            if let error=controller.error{Text(error).foregroundStyle(.red)}
        }.formStyle(.grouped).disabled(!controller.healthy)
    }
}

@MainActor struct FileEnhancementToolView:View {
    @ObservedObject var controller:FileEnhancementController
    @ObservedObject var store:OperationStore
    @State private var text=""
    @State private var result=""
    @State private var format="docx"
    @State private var templateID:UUID?
    @State private var busy=false
    @State private var nameByteEncoding="Latin1"
    @State private var nameTextEncoding="UTF-8"
    @State private var renamePlans:[RenamePlan]=[]
    @State private var builtinIcon="folder"
    private var sourceEncoding:String.Encoding {nameByteEncoding=="Latin1" ? .isoLatin1 : .windowsCP1252}
    private var targetEncoding:String.Encoding {nameTextEncoding=="UTF-8" ? .utf8 : nameTextEncoding=="Shift-JIS" ? .shiftJIS : String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))}
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            if let request=controller.request {
                Text(FileEnhancements.actions.first(where:{$0.id==request.action})?.title ?? "文件增强").font(.title2.bold())
                Text("\(request.files.count) 个项目").foregroundStyle(.secondary)
                ScrollView{Text(request.files.map(\.lastPathComponent).joined(separator:"\n")).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:100)
                switch request.action {
                case "file.permissions":TextField("三位八进制权限，例如 644 或 755",text:$text);Text("仅修改选中项，不递归。属性可从文件增强设置恢复。").font(.caption)
                case "file.delete":Text("永久删除无法撤销。请核对上方项目并输入：彻底删除").foregroundStyle(.red);TextField("确认文字",text:$text)
                case "file.dissolve":Text("将文件夹内容移到上一级。重名即停止；目录外壳作为隐藏恢复记录保留。")
                case "file.new.office":Picker("文档格式",selection:$format){ForEach(FileEnhancements.documentFormats,id:\.self){Text($0.uppercased()).tag($0)}}
                case let action where action.hasPrefix("file.new."):Text("将创建有效的 \(String(action.dropFirst(9)).uppercased()) 空白文档；重名自动编号。")
                case "file.fixNames":
                    Picker("错误名称的字节编码",selection:$nameByteEncoding){Text("Latin-1").tag("Latin1");Text("Windows-1252").tag("Windows1252")}
                    Picker("原名称编码",selection:$nameTextEncoding){Text("UTF-8").tag("UTF-8");Text("GB18030 / GBK").tag("GB18030");Text("Shift-JIS（日文）").tag("Shift-JIS")}
                    Button("预览名称"){do{renamePlans=try EnhancedFileTools.repairedNames(request.files,byteEncoding:sourceEncoding,textEncoding:targetEncoding);result=renamePlans.map{$0.source.lastPathComponent+" → "+$0.destination.lastPathComponent}.joined(separator:"\n")}catch{renamePlans=[];result=error.localizedDescription}}
                case "file.icon.builtin":Picker("图标",selection:$builtinIcon){ForEach(FileEnhancementImages.builtinSymbols,id:\.self){Text($0).tag($0)}}
                case "file.template.create":Picker("文件模板",selection:$templateID){Text("请选择").tag(UUID?.none);ForEach(controller.settings.templates){Text($0.name).tag(Optional($0.id))}}
                case "file.openApp":ForEach(controller.settings.apps){app in Button(app.name){do{try controller.open(request.files,with:app);controller.request=nil}catch{result=error.localizedDescription}}};Button("添加应用…"){do{try controller.addApplication()}catch{result=error.localizedDescription}}
                default:EmptyView()
                }
                if !result.isEmpty{ScrollView{Text(result).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(minHeight:120,maxHeight:280)}
                HStack{Spacer();Button("关闭"){controller.request=nil}.keyboardShortcut(.cancelAction)
                    if request.action != "file.openApp"{Button(request.action=="file.info" ? "读取信息" : "执行"){execute(request)}.buttonStyle(.borderedProminent).disabled(busy || (request.action=="file.delete" && text != "彻底删除") || (request.action=="file.fixNames" && renamePlans.isEmpty))}
                }
            }
        }.padding(22).frame(width:580).disabled(!controller.healthy)
    }
    private func execute(_ request:EnhancementToolRequest){
        busy=true;result=""
        Task { @MainActor in
            defer{busy=false}
            do {
                let files=request.files,directory=store.directory(for:files)
                switch request.action {
                case "file.info":result=try await Task.detached{try files.map{try EnhancedFileTools.hashes($0)}.joined(separator:"\n\n")}.value;return
                case "file.permissions":guard text.count==3,let value=UInt32(text,radix:8),value<=0o777 else{throw FileToolsError.invalid("请输入三位八进制权限。")};try controller.changeMetadata(files,kind:"mode",value:value)
                case "file.delete":let confirmation=text;try await Task.detached{try EnhancedFileTools.permanentlyDelete(files,confirmation:confirmation)}.value
                case "file.dissolve":let outputs=try controller.dissolveFolders(files);store.notify("已解散文件夹",outputs:outputs)
                case "file.new.office":let receipt=try controller.createOffice(format,in:directory);try store.record([receipt]);store.completeNewFile(receipt.destination);store.notify("已创建文档",outputs:[receipt.destination])
                case let action where action.hasPrefix("file.new."):let receipt=try controller.createOffice(String(action.dropFirst(9)),in:directory);try store.record([receipt]);store.completeNewFile(receipt.destination);store.notify("已创建文档",outputs:[receipt.destination])
                case "file.fixNames":let records=try FileTools.applyRenames(renamePlans);try store.record(records);store.notify("已修复文件名称",outputs:records.map(\.destination))
                case "file.icon.builtin":let image=try FileEnhancementImages.builtinIcon(builtinIcon);for file in files{_ = try EnhancedFileTools.checked(file);guard NSWorkspace.shared.setIcon(image,forFile:file.path,options:[]) else{throw FileToolsError.invalid("未能设置图标：\(file.lastPathComponent)")}};store.notify("已设置内置图标")
                case "file.template.create":guard let template=controller.settings.templates.first(where:{$0.id==templateID}) else{throw FileToolsError.invalid("请选择模板。")};let receipt=try controller.createTemplate(template,in:directory);try store.record([receipt]);store.completeNewFile(receipt.destination);store.notify("已按模板创建",outputs:[receipt.destination])
                default:throw FileToolsError.invalid("未识别的操作。")
                }
                controller.request=nil
            }catch{result=error.localizedDescription}
        }
    }
}
