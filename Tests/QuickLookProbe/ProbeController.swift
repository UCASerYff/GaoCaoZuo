import AppKit
import QuickLookUI
import Darwin

/// Private, uniquely identified extension host used only to prove the real
/// Quick Look sandbox boundary before enabling the production editor UI.
@objc(GaoQuickLookHelperProbeController)
final class GaoQuickLookHelperProbeController:NSViewController,QLPreviewingController {
    private let message=NSTextField(wrappingLabelWithString:"选择公开合成 ZIP/7Z，再选择新增合成文件；仅供本次定向验收。")
    private let password=NSSecureTextField(string:"")
    private var archive:URL?,addition:URL?,scopes:[URL]=[],busy=false
    private var stop:NativeArchive.Cancellation?
    private var probeConnection:NSXPCConnection?
    override func loadView() {
        let file=NSButton(title:"选择测试压缩包",target:self,action:#selector(chooseArchive))
        let add=NSButton(title:"选择新增测试文件",target:self,action:#selector(chooseAddition))
        let inspect=NSButton(title:"验证辅助进程读取",target:self,action:#selector(inspectArchive))
        let save=NSButton(title:"授权原目录并验证原包保存",target:self,action:#selector(saveOriginal))
        let cancel=NSButton(title:"停止验证",target:self,action:#selector(cancel))
        let xpc=NSButton(title:"验证 XPC 沙盒读取与子进程",target:self,action:#selector(inspectXPC))
        let broker=NSButton(title:"验证受控归档处理与隔离",target:self,action:#selector(inspectBroker))
        password.placeholderString="公开合成压缩包密码"
        let stack=NSStackView(views:[message,file,add,password,inspect,save,xpc,broker,cancel])
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12
        stack.edgeInsets=NSEdgeInsets(top:20,left:20,bottom:20,right:20)
        password.widthAnchor.constraint(equalToConstant:280).isActive=true
        message.widthAnchor.constraint(equalToConstant:600).isActive=true
        view=stack;preferredContentSize=NSSize(width:660,height:360)
    }
    func preparePreviewOfFile(at url:URL,completionHandler handler:@escaping(Error?)->Void) { _ = view;handler(nil) }
    private func select(directory:Bool,completion:@escaping(URL)->Void) {
        guard !busy,let window=view.window else {return}
        let panel=NSOpenPanel();panel.canChooseDirectories=directory;panel.canChooseFiles = !directory
        panel.beginSheetModal(for:window){[weak self] result in
            guard let self,result == .OK,let url=panel.url else {return}
            if url.startAccessingSecurityScopedResource() {self.scopes.append(url)}
            completion(url)
        }
    }
    @objc private func chooseArchive() {select(directory:false){[weak self] in self?.archive=$0;self?.message.stringValue=$0.path}}
    @objc private func chooseAddition() {select(directory:false){[weak self] in self?.addition=$0;self?.message.stringValue=$0.path}}
    @objc private func inspectArchive() {run(.inspect)}
    @objc private func saveOriginal() {
        guard let archive,addition != nil else {return}
        select(directory:true){[weak self] url in
            guard url.standardizedFileURL==archive.deletingLastPathComponent().standardizedFileURL else {self?.message.stringValue="选择的目录与原包目录不同，未保存。";return}
            self?.run(.saveOriginal)
        }
    }
    @objc private func cancel() {stop?.cancel();if let connection=probeConnection {probeConnection=nil;connection.invalidate();busy=false;message.stringValue="已停止等待本次公开夹具验证。"}}
    @objc private func inspectXPC() {probeXPC(serviceName:GaoQuickLookProbeIdentity.serviceName,component:"SandboxProbe.xpc")}
    @objc private func inspectBroker() {probeXPC(serviceName:"com.gaoseries.GaoCaoZuo.QuickLookHelperProbe.BrokerProbe",component:"BrokerProbe.xpc")}
    private func probeXPC(serviceName:String,component:String) {
        guard !busy,let archive else {return}
        do {
            let service=Bundle(for:type(of:self)).bundleURL.appendingPathComponent("Contents/XPCServices/"+component)
            let bookmark=try archive.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            let clientBundle=try Bundle(for:type(of:self)).bundleURL.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            let connection=NSXPCConnection(serviceName:serviceName)
            connection.setCodeSigningRequirement(try GaoQuickLookProbeIdentity.requirement(for:service))
            connection.remoteObjectInterface=NSXPCInterface(with:GaoQuickLookSandboxProbeProtocol.self)
            probeConnection=connection;busy=true;message.stringValue="正在验证独立 XPC 沙盒…"
            connection.resume()
            let remote=connection.remoteObjectProxyWithErrorHandler{[weak self] error in
                DispatchQueue.main.async {guard let self,self.probeConnection===connection else{return};self.busy=false;self.message.stringValue=String(describing:error);self.probeConnection=nil;connection.invalidate()}
            } as? GaoQuickLookSandboxProbeProtocol
            remote?.inspect(bookmark,clientBundle:clientBundle){[weak self] bytes in
                DispatchQueue.main.async {
                    guard let self,self.probeConnection===connection else {return}
                    self.busy=false
                    self.message.stringValue=(String(data:bytes,encoding:.utf8) ?? "Invalid response")+"\nConnectionPID=\(connection.processIdentifier),expectedCaller=\(getpid())"
                    self.probeConnection?.invalidate();self.probeConnection=nil
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+40){[weak self,weak connection] in
                guard let self,let connection,self.probeConnection===connection else {return}
                self.probeConnection=nil;connection.invalidate();self.busy=false;self.message.stringValue="公开夹具验证连接超时，已停止等待。"
            }
        }catch {message.stringValue=String(describing:error as NSError)}
    }
    private func run(_ kind:QuickLookArchiveEditRequest.Kind) {
        guard !busy,let archive else {return}
        busy=true;let token=NativeArchive.Cancellation(seconds:60,originalMayChange:kind == .saveOriginal);stop=token
        let password=password.stringValue,adding=addition.map{[$0]} ?? []
        message.stringValue="正在真实 Quick Look 宿主内验证…"
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            let result:Result<QuickLookArchiveEditResponse,Error>=Result{
                let request=try QuickLookEditEngine.request(kind:kind,url:archive,password:password.isEmpty ? nil:password,adding:kind == .saveOriginal ? adding:[],cancellation:token)
                return try QuickLookEditEngine.run(request,cancellation:token)
            }
            DispatchQueue.main.async {
                guard let self else {return};self.busy=false;self.stop=nil
                switch result {
                case .success(let value):self.message.stringValue="真实辅助进程完成 · PID \(value.helperPID ?? 0) · 父进程 \(value.helperParentPID ?? 0) · \(value.members.count) 项\n"+(value.resultSHA256 ?? "")+"\n"+(value.backup?.path ?? "")
                case .failure(let error):
                    self.message.stringValue=error.localizedDescription+"\n"+Self.pathDiagnostics()+"\nError="+String(describing:error as NSError)
                    if let failure=error as? QuickLookEditEngine.HelperFailure {self.message.stringValue += "\nVerified helper PID=\(failure.response.helperPID ?? 0),parent=\(failure.response.helperParentPID ?? 0),exit=\(failure.exitStatus)"}
                }
            }
        }
    }
    private static func pathDiagnostics()->String {
        let bundle=Bundle(for:NativeArchiveBrowserController.self)
        var lines=["ID="+(bundle.bundleIdentifier ?? "nil"),"Bundle="+bundle.bundleURL.path,"Resource="+(bundle.resourceURL?.path ?? "nil")]
        let candidates=[bundle.resourceURL?.appendingPathComponent("Tools/QuickLookArchiveEdit"),bundle.bundleURL.appendingPathComponent("Contents/MacOS/QuickLookArchiveEdit")].compactMap{$0}
        lines.append("Auxiliary="+(QuickLookEditEngine.helperURL()?.path ?? "nil"))
        for helper in candidates {
            var s=stat();errno=0
            let exists=lstat(helper.path,&s),statError=errno
            errno=0;let executable=Darwin.access(helper.path,X_OK),accessError=errno
            lines += ["Helper="+helper.path,"lstat=\(exists),errno=\(statError),mode=\(String(s.st_mode,radix:8))","X_OK=\(executable),errno=\(accessError)"]
        }
        return lines.joined(separator:"\n")
    }
    deinit {probeConnection?.invalidate();for url in scopes {url.stopAccessingSecurityScopedResource()}}
}
