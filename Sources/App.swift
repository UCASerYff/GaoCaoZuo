import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import Darwin

@main enum GaoOperationMain {
    @MainActor static func main() {
        if let index=CommandLine.arguments.firstIndex(of:"--hid-tracking-preflight"),CommandLine.arguments.count>index+1 {
            do {
                let output=URL(fileURLWithPath:CommandLine.arguments[index+1]),parent=output.deletingLastPathComponent()
                var info=stat()
                let allowedParents=[FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),URL(fileURLWithPath:"/private/tmp",isDirectory:true)]
                guard output.lastPathComponent=="hid-tracking-preflight.json",parent.lastPathComponent.hasPrefix("gaocaozuo-acceptance-"),parent.lastPathComponent.hasSuffix(".noindex"),allowedParents.contains(parent.resolvingSymlinksInPath().deletingLastPathComponent()),lstat(parent.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0 else {throw CocoaError(.fileWriteNoPermission)}
                NSApplication.shared.setActivationPolicy(.prohibited)
                let report=HIDTrackingServiceBackend.readOnlyPreflightReport()
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                try encoder.encode(report).write(to:output,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            }catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
            return
        }
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate=OperationAppDelegate()
        app.delegate=delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
final class OperationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class OperationAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: OperationStore!
    private var mainWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var panel: OperationPanel?
    private var clipboardPanel: OperationPanel?
    private var pasteReviewPanel:NSPanel?
    private var feedbackPanel: NSPanel?
    private var passwordPanel: OperationPanel?
    private var finishPassword: ((String?) -> Void)?
    private var feedbackDismiss: DispatchWorkItem?
    private var clipboardErrorObserver: AnyCancellable?
    private var statusItem: NSStatusItem!
    private var enhancementObservers:Set<AnyCancellable>=[]
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var gaoActionClient: GaoActionClient!
    private var earlyURLs: [URL] = []
    private var pendingInitialPresentation = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args=CommandLine.arguments
        let directory: URL
        if let i=args.firstIndex(of:"--data-dir"),args.count>i+1,args[i+1].hasPrefix("/") {directory=URL(fileURLWithPath:args[i+1],isDirectory:true)}
        else {directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoCaoZuo",isDirectory:true)}
        store=OperationStore(directory:directory)
        GaoLocale.shared.setLanguage(GaoLanguage(rawValue:store.settings.language) ?? .system)
        gaoActionClient=GaoActionClient(dataDirectory:directory)
        store.showMain={ [weak self] in self?.showMain() }
        store.showPanel={ [weak self] in self?.showPanel() }
        store.showSettings={ [weak self] in self?.showSettings() }
        store.showExtensionSettings={ [weak self] tab in self?.showSettings(tab:tab) }
        store.showPermissions={ [weak self] in self?.showSettings(tab:1) }
        store.showClipboard={ [weak self] in self?.showClipboard() }
        store.showPasteReview={ [weak self] in self?.showPasteReview() }
        store.showFeedback={ [weak self] in self?.showFeedback() }
        store.activateForDialog={ NSApp.activate(ignoringOtherApps:true) }
        store.requestArchivePassword={ [weak self] url,incorrect in await self?.askPassword(url,incorrect:incorrect) }
        store.cancelPasswordRequest={ [weak self] in self?.finishPassword?(nil) }
        store.clipboard.onPasteResult={ [weak self] message,failed in self?.store.notify(message,failed:failed) }
        store.clipboard.onPasteReviewNeeded={ [weak self] in self?.showPasteReview() }
        store.clipboard.pasteBlockingReason={
            CleanerController.shared.state == .idle ? nil : "请先退出清洁模式或退出键验证，再粘贴。"
        }
        CleanerController.shared.canBegin={ [weak self] in
            self?.store.clipboard.hasActivePasteTransaction == true ? "请先处理当前粘贴，再验证退出键或进入清洁模式。" : nil
        }
        SelectionActionBar.shared.onStatus={ [weak self] message,failed in self?.store.notify(message,failed:failed) }
        SelectionActionBar.shared.onSaveSnippet={ [weak self] snapshot in
            guard let self,self.store.dataHealthy else {return}
            do {
                try self.store.snippetLibrary.upsert(AdvancedSnippet(name:String(snapshot.selectedText.prefix(30)),text:snapshot.selectedText))
                self.store.notify("选中文字已保存至短语库")
            } catch {self.store.notify(error.localizedDescription,failed:true)}
        }
        SelectionActionBar.shared.onSaveClipboard={ [weak self] snapshot in
            guard let self else {return}
            do {try self.store.clipboard.saveSelectedText(snapshot.selectedText,sourceApp:snapshot.bundleID ?? "");self.store.notify("选中文字已存入历史；采集开关保持当前设置")}
            catch {self.store.notify(error.localizedDescription,failed:true)}
        }
        SelectionActionBar.shared.onTranslate={ [weak self] snapshot in self?.sendSelection(snapshot,translate:true) }
        SelectionActionBar.shared.onSendToFiles={ [weak self] snapshot in self?.sendSelection(snapshot,translate:false) }
        do {try PasteStack.shared.configurePersistence(dataDirectory:directory)} catch {store.notify(error.localizedDescription,failed:true)}
        CleanerController.shared.onInputDemandChanged={ [weak self] in
            DispatchQueue.main.async { self?.store.input.refreshExtensionDemand() }
        }
        store.input.onPauseChanged={ [weak self] _ in self?.configureInputExtensions() }
        clipboardErrorObserver=store.clipboard.$error.compactMap{$0}.removeDuplicates().sink { [weak self] message in
            self?.store.notify(message,failed:true)
        }
        store.onSettingsChanged={ [weak self] in self?.configureInput();self?.applyAppearance();self?.applyStatusVisibility();if let self{self.store.finderPreferences.publish(store:self.store)} }
        store.finderPreferences.changed={ [weak self] in if let self{self.store.finderPreferences.publish(store:self.store)} }
        store.fileEnhancements.$settings.dropFirst().sink { [weak self] _ in Task { @MainActor in if let self{self.store.finderPreferences.publish(store:self.store)} } }.store(in:&enhancementObservers)
        store.finderPreferences.publish(store:store)
        NSApp.servicesProvider=self
        NSUpdateDynamicServices()
        mainWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        mainWindow.title="搞操作 V\(store.version)";mainWindow.minSize=NSSize(width:960,height:680);mainWindow.isReleasedWhenClosed=false;mainWindow.delegate=self
        mainWindow.contentView=NSHostingView(rootView:GaoLocalizedContent { OperationRootView(store:self.store) });mainWindow.center();mainWindow.setFrameAutosaveName("GaoCaoZuo.main")
        if let i=args.firstIndex(of:"--migration"),args.count>i+1,args[i+1].hasPrefix("/") {do{try store.importReplacementSettings(URL(fileURLWithPath:args[i+1]))}catch{store.notify(error.localizedDescription,failed:true)}}
        installMenu();configureStatus();configureInput();applyAppearance();applyStatusVisibility()
        activationObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self]note in
            guard let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else{return}
            Task{@MainActor in self?.store.windows.captureTarget();self?.panel?.orderOut(nil);self?.clipboardPanel?.orderOut(nil)}
        }
        pendingInitialPresentation = !args.contains("--background-action") && earlyURLs.isEmpty
        // Finder's sandbox may discard launch arguments; inactive URL launches must stay quiet.
        if pendingInitialPresentation,NSApp.isActive {pendingInitialPresentation=false;showMain()}
        if let i=args.firstIndex(of:"--open"),args.count>i+1 {store.selection=[URL(fileURLWithPath:args[i+1])]}
        if !earlyURLs.isEmpty {let urls=earlyURLs;earlyURLs=[];application(NSApp,open:urls)}
    }
    private func configureInput(){store.windows.configure(enhancements:store.settings.windowEnhancements);store.input.configure(bindings:store.settings.bindings,excludedApps:store.settings.inputExcludedApps,windows:store.windows,windowDragEnabled:store.settings.windowDragEnabled,windowSnapEnabled:store.settings.windowSnapEnabled,enhancements:store.settings.inputEnhancements,invocationHandler:{[weak self] id,mode in
            guard let self else{return}
            self.store.windows.captureTarget(underPointer:mode == .inheritSettings ? nil : mode == .underPointer)
            self.store.prepare(id,targetMode:mode)
        }){[weak self]id in guard let self else{return};self.store.windows.captureTarget();self.store.prepare(id)}
        configureInputExtensions()
    }
    private func configureInputExtensions() {
        var auto=store.settings.autoInput;var fly=store.settings.flyKey
        if store.input.isPaused || !store.dataHealthy {auto.enabled=false;fly.enabled=false}
        InputSourceCoordinator.shared.configure(configuration:auto,onConfigurationChange:{ [weak self] value in
            guard let self,!self.store.input.isPaused,self.store.dataHealthy else {return}
            self.store.update {$0.autoInput=value}
        },excludedApps:store.settings.inputExcludedApps)
        FlyKeyController.shared.configure(configuration:fly,bindings:store.settings.bindings,excludedApps:store.settings.inputExcludedApps) { [weak self] binding in
            self?.store.prepare(binding.actionID)
        }
        store.input.configureExtensionDemand(auto.enabled || fly.enabled)
    }
    private func applyAppearance(){
        NSApp.appearance=store.settings.appearance == "system" ? nil : NSAppearance(named:store.settings.appearance == "dark" ? .darkAqua : .aqua)
        if let lang=GaoLanguage(rawValue:store.settings.language) {GaoLocale.shared.setLanguage(lang)}
        if mainWindow != nil { installMenu(); settingsWindow?.title=L10n.text("搞操作设置"); clipboardPanel?.title=L10n.text("剪贴板") }
    }
    func showMain(){store.windows.captureTarget();store.captureSelectionForActions();mainWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func showPanel(){
        pendingInitialPresentation=false
        store.windows.captureTarget()
        store.captureSelectionForActions()
        if panel?.isVisible == true {panel?.orderOut(nil);return}
        let panel=self.panel ?? OperationPanel(contentRect:NSRect(x:0,y:0,width:600,height:480),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.standardWindowButton(.closeButton)?.isHidden=true;panel.standardWindowButton(.miniaturizeButton)?.isHidden=true;panel.standardWindowButton(.zoomButton)?.isHidden=true
        panel.level = .floating;panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=true;panel.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:GaoLocalizedContent { [store=self.store!,weak panel] in OperationPanelView(store:store,close:{panel?.orderOut(nil)}) })
        let point=NSEvent.mouseLocation
        let screen=NSScreen.screens.first(where:{$0.frame.contains(point)}) ?? NSScreen.main
        if let frame=screen?.visibleFrame {panel.setFrameOrigin(NSPoint(x:frame.midX-300,y:frame.midY-240))}else{panel.center()}
        self.panel=panel
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name:OperationPanelSearchField.focusReadyNotification,object:panel)
    }
    func showSettings(tab:Int=0){
        store.windows.captureTarget()
        if settingsWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title=L10n.text("搞操作设置");window.isReleasedWhenClosed=false;window.contentView=NSHostingView(rootView:GaoLocalizedContent { OperationSettingsView(store:self.store) });window.center();settingsWindow=window
        }
        settingsWindow?.contentView=NSHostingView(rootView:GaoLocalizedContent { OperationSettingsView(store:self.store,initialTab:tab) })
        settingsWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func showClipboard(){
        store.windows.captureTarget()
        store.clipboard.capturePasteTarget()
        if clipboardPanel?.isVisible == true {clipboardPanel?.orderOut(nil);return}
        let window=clipboardPanel ?? OperationPanel(contentRect:NSRect(x:0,y:0,width:520,height:480),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title=L10n.text("剪贴板");window.titlebarAppearsTransparent=true;window.isReleasedWhenClosed=false
        window.level = .floating;window.hidesOnDeactivate=true;window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        window.contentView=NSHostingView(rootView:GaoLocalizedContent { [store=self.store!,weak window] in QuickClipboardView(store:store,close:{window?.orderOut(nil)},onError:{message in store.notify(message,failed:true)}) })
        clipboardPanel=window;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    private func showPasteReview() {
        let window=pasteReviewPanel ?? NSPanel(contentRect:NSRect(x:0,y:0,width:520,height:350),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
        window.title=L10n.text("确认粘贴结果");window.isReleasedWhenClosed=false;window.becomesKeyOnlyIfNeeded=true
        window.level = .floating;window.hidesOnDeactivate=false;window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        let content=NSHostingView(rootView:GaoLocalizedContent { [store=self.store!,weak window] in PendingPasteReviewView(clipboard:store.clipboard,close:{window?.orderOut(nil)}) })
        window.contentView=content;window.setContentSize(content.fittingSize)
        if let frame=NSScreen.main?.visibleFrame {window.setFrameOrigin(NSPoint(x:frame.maxX-window.frame.width-20,y:frame.minY+30))}
        pasteReviewPanel=window;window.orderFrontRegardless()
    }
    private func showFeedback(){
        guard store.feedback.kind != .idle else{return}
        feedbackDismiss?.cancel()
        let window=feedbackPanel ?? NSPanel(contentRect:NSRect(x:0,y:0,width:392,height:130),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=true
        window.level = .floating;window.hidesOnDeactivate=false;window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        let content=NSHostingView(rootView:GaoLocalizedContent { [store=self.store!,weak window] in QuickFeedbackView(store:store,archive:store.archive,close:{window?.orderOut(nil)}) })
        window.contentView=content;window.setContentSize(NSSize(width:392,height:170))
        let point=NSEvent.mouseLocation
        if let frame=(NSScreen.screens.first{$0.frame.contains(point)} ?? NSScreen.main)?.visibleFrame {window.setFrameOrigin(NSPoint(x:frame.maxX-window.frame.width-20,y:frame.maxY-window.frame.height-20))}
        feedbackPanel=window;window.orderFrontRegardless()
        statusItem?.button?.toolTip="搞操作 · "+store.feedback.title
        if store.feedback.kind != .running {
            let work=DispatchWorkItem{[weak window] in window?.orderOut(nil)};feedbackDismiss=work
            DispatchQueue.main.asyncAfter(deadline:.now()+(store.feedback.kind == .failure ? 12 : 5),execute:work)
        }
    }
    private func askPassword(_ archive:URL,incorrect:Bool) async -> String? {
        await withCheckedContinuation { continuation in
            let previous=NSWorkspace.shared.frontmostApplication
            let window=OperationPanel(contentRect:NSRect(x:0,y:0,width:454,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title=L10n.text("解压密码");window.isReleasedWhenClosed=false;window.delegate=self;window.level = .floating
            window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
            var finished=false
            let finish:(String?)->Void={ [weak self,weak window] value in
                guard !finished else{return};finished=true
                window?.orderOut(nil);self?.finishPassword=nil;self?.passwordPanel=nil
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,let previous,previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,!previous.isTerminated {previous.activate(options:[])}
                continuation.resume(returning:value)
            }
            finishPassword=finish;passwordPanel=window
            let content=NSHostingView(rootView:GaoLocalizedContent { ArchivePasswordPrompt(filename:archive.lastPathComponent,incorrect:incorrect,finish:finish) })
            window.contentView=content;window.setContentSize(content.fittingSize);window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        }
    }
    func windowWillClose(_ notification:Notification){if let window=notification.object as? NSWindow,window === passwordPanel {finishPassword?(nil)}}
    private func installMenu(){
        let menu=NSMenu()
        let appMenu=NSMenu();appMenu.addItem(item("关于搞操作",#selector(about)));appMenu.addItem(.separator());appMenu.addItem(item("设置…",#selector(settingsAction),key:","));appMenu.addItem(.separator());appMenu.addItem(item("退出搞操作",#selector(quit),key:"q"))
        menu.addItem(withTitle:L10n.text("搞操作"),action:nil,keyEquivalent:"").submenu=appMenu
        let file=NSMenu();file.addItem(item("选择文件…",#selector(selectFiles),key:"o"));file.addItem(item("显示主窗口",#selector(mainAction),key:"0"));file.addItem(item("打开操作面板",#selector(panelAction)));file.addItem(item("跨应用任务…",#selector(exchangeHistoryAction)));file.addItem(.separator());file.addItem(item("关闭窗口",#selector(closeWindow),key:"w"))
        menu.addItem(withTitle:L10n.text("文件"),action:nil,keyEquivalent:"").submenu=file
        let edit=NSMenu()
        for (title,selector,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(NSMenuItem(title:L10n.text(title),action:selector,keyEquivalent:key))}
        menu.addItem(withTitle:L10n.text("编辑"),action:nil,keyEquivalent:"").submenu=edit
        let window=NSMenu();window.addItem(NSMenuItem(title:L10n.text("最小化"),action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"));menu.addItem(withTitle:L10n.text("窗口"),action:nil,keyEquivalent:"").submenu=window;NSApp.windowsMenu=window
        let help=NSMenu();help.addItem(item("使用说明",#selector(helpAction)));menu.addItem(withTitle:L10n.text("帮助"),action:nil,keyEquivalent:"").submenu=help
        NSApp.mainMenu=menu
    }
    private func item(_ title:String,_ selector:Selector,key:String="")->NSMenuItem{let value=NSMenuItem(title:L10n.text(title),action:selector,keyEquivalent:key);value.target=self;return value}
    private func configureStatus(){statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);statusItem.button?.image=NSImage(systemSymbolName:"cursorarrow.motionlines",accessibilityDescription:"搞操作");statusItem.button?.toolTip="搞操作";statusItem.button?.target=self;statusItem.button?.action=#selector(statusClicked);statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])}
    private func applyStatusVisibility(){statusItem?.isVisible=store.settings.showMenuBarIcon}
    @objc private func statusClicked(){
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu();menu.addItem(item("打开操作面板",#selector(panelAction)));menu.addItem(item("显示主窗口",#selector(mainAction)));menu.addItem(item("剪贴板",#selector(clipboardAction)))
            if store.clipboard.hasActivePasteTransaction {menu.addItem(item("处理待确认粘贴",#selector(pasteReviewAction)))}
            let layouts=NSMenu()
            for action in WindowAction.allCases {let entry=item(action.title,#selector(quickMenuAction(_:)));entry.representedObject="window."+action.rawValue;layouts.addItem(entry)}
            menu.addItem(withTitle:L10n.text("排列当前窗口"),action:nil,keyEquivalent:"").submenu=layouts
            if !store.settings.workflows.isEmpty {let workflows=NSMenu();for workflow in store.settings.workflows {let entry=item(workflow.name,#selector(quickMenuAction(_:)));entry.representedObject="workflow.run."+workflow.id.uuidString;workflows.addItem(entry)};menu.addItem(withTitle:L10n.text("运行组合操作"),action:nil,keyEquivalent:"").submenu=workflows}
            menu.addItem(.separator());menu.addItem(item("检查权限…",#selector(permissionsAction)));menu.addItem(item(store.input.isPaused ? "恢复快捷键与手势" : "暂停快捷键与手势",#selector(pauseInput)));menu.addItem(item("设置…",#selector(settingsAction)));menu.addItem(.separator());menu.addItem(item("退出搞操作",#selector(quit)))
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil
        }else{switch store.settings.statusBarLeftClick {case "main":showMain();case "clipboard":showClipboard();default:showPanel()}}
    }
    @objc private func clipboardAction(){showClipboard()}
    @objc private func pasteReviewAction(){showPasteReview()}
    @objc private func permissionsAction(){showSettings(tab:1)}
    @objc private func quickMenuAction(_ sender:NSMenuItem){store.windows.captureTarget();if let id=sender.representedObject as? String{store.prepare(id)}}
    @objc private func exchangeHistoryAction(){gaoActionClient.showHistory()}
    @objc private func panelAction(){showPanel()}
    @objc private func mainAction(){showMain()}
    @objc private func settingsAction(){showSettings()}
    @objc private func selectFiles(){showMain();store.chooseFiles()}
    @objc private func pauseInput(){store.input.pause(!store.input.isPaused)}
    @objc private func closeWindow(){NSApp.keyWindow?.performClose(nil)}
    @objc private func quit(){NSApp.terminate(nil)}
    @objc private func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"搞操作",.applicationVersion:"V\(store.version)",.version:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "1",.credits:NSAttributedString(string:"搞系列 · 本地操作增强工具\nSwiftUI + AppKit · 本地签名，未公证")]);NSApp.activate(ignoringOtherApps:true)}
    @objc private func helpAction(){if let url=Bundle.main.url(forResource:"使用说明",withExtension:"txt"){NSWorkspace.shared.open(url)}}
    @objc(receiveFiles:userData:error:) func receiveFiles(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>?){
        guard store != nil else{error?.pointee="程序正在启动，请稍后重试。";return}
        guard !store.busy,!store.archive.isRunning,store.sheet == nil else{error?.pointee="当前操作尚未完成，请关闭工具窗口后重试。";return}
        let modern=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]
        let legacy=pasteboard.propertyList(forType:NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]
        let urls=modern ?? legacy?.filter{$0.hasPrefix("/") && !$0.contains("\0")}.map{URL(fileURLWithPath:$0)} ?? []
        guard !urls.isEmpty else{error?.pointee="请选择文件或文件夹。";return}
        store.windows.captureTarget();store.selection=urls;showPanel()
    }
    @objc(receiveText:userData:error:) func receiveText(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text=pasteboard.string(forType:.string),!text.isEmpty,let action=userData else {error?.pointee="没有可处理的文字";return}
        do {
            if action == "text.baidu" || action == "text.google" {try store.fileEnhancements.translate(text,provider:action)}
            else if action == "text.qrcode.clipboard" {let bytes=try FileTools.qrCode(text:text);let board=NSPasteboard.general;board.clearContents();board.setData(bytes,forType:.png);store.notify("二维码已复制")}
        }catch let failure {error?.pointee=failure.localizedDescription as NSString}
    }
    func application(_ application:NSApplication,open urls:[URL]){
        pendingInitialPresentation=false
        guard store != nil else{earlyURLs += urls;return}
        store.windows.captureTarget()
        let exchangeURLs=urls.filter{$0.isFileURL && $0.pathExtension.lowercased()==GaoActionV1.packageExtension}
        for url in exchangeURLs {
            Task { @MainActor [client=gaoActionClient!,weak self] in await client.receivePackage(url) { message,failed in self?.store.notify(message,failed:failed) } }
        }
        let fileURLs=urls.filter{$0.isFileURL && $0.pathExtension.lowercased() != GaoActionV1.packageExtension}
        if !fileURLs.isEmpty {store.selection=fileURLs;if fileURLs.allSatisfy({["zip","7z","rar","ace","lzh","lha","lz","lzip","tar","tgz","gz","bz2","xz","zst","cab","iso","xar","cpio","001"].contains($0.pathExtension.lowercased())}) {_ = store.archiveEnhancements.handle(id:"archive.open",files:fileURLs,store:store)}else{showPanel()}}
        for url in urls where url.scheme == "gaocaozuo" {
            if url.host == "finder" {
                guard let request=FinderActionRequest.consume(url) else {store.notify("右键请求已过期，请重新从 Finder 选择操作",failed:true);continue}
                store.prepare(request.action,files:request.paths.map{URL(fileURLWithPath:$0)})
            } else if url.host == "perform",let components=URLComponents(url:url,resolvingAgainstBaseURL:false),let value=components.queryItems?.first(where:{$0.name == "payload"})?.value,value.utf8.count <= 512_000,let bytes=Data(base64Encoded:value),let paths=try? JSONDecoder().decode([String].self,from:bytes),!paths.isEmpty,paths.count <= 1000,paths.allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 16_384}) {
                // Legacy/external URLs only select inputs. An explicit panel click authorizes an action.
                store.selection=paths.map{URL(fileURLWithPath:$0)};store.message=L10n.text("已接收文件，请选择要执行的操作");showPanel()
            }
        }
    }
    func applicationDidBecomeActive(_ notification:Notification){
        if pendingInitialPresentation,mainWindow != nil {pendingInitialPresentation=false;showMain()}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showMain();return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        if store.clipboard.hasActivePasteTransaction {store.notify("请先处理剪贴板的恢复或粘贴确认，再退出，以保留原内容。",failed:true);showPasteReview();return .terminateCancel}
        if store.busy || store.archive.isRunning || store.workflowRunning || store.crossApplicationBusy || GaoActionActivity.shared.isBusy {
            let alert=NSAlert();alert.messageText=L10n.text("任务仍在运行");alert.informativeText=L10n.text("请等待文件任务完成，或在任务界面取消压缩/组合操作后退出。");alert.addButton(withTitle:L10n.text("返回任务"));alert.runModal();showMain();return .terminateCancel
        }
        CleanerController.shared.emergencyRelease();InputSourceCoordinator.shared.stop();FlyKeyController.shared.stop();SelectionActionBar.shared.dismiss()
        store.input.stop();SystemActions.releasePreventSleep();return .terminateNow
    }
}

@MainActor private extension OperationAppDelegate {
    func sendSelection(_ snapshot:SelectionSnapshot,translate:Bool) {
        guard store.dataHealthy else {store.notify("资料处于保护模式，未建立交接包。",failed:true);return}
        guard Date().timeIntervalSince(snapshot.timestamp) <= 60,!snapshot.selectedText.isEmpty else {store.notify("选区已过期，请重新选择。",failed:true);return}
        let action=translate ? "text.translate" : "documents.newText"
        let target=translate ? "com.gaoseries.GaoJieTu" : "com.gaoseries.GaoWenJian"
        var parameters:[String:Any]=translate ? ["targetLanguage":"zh-Hans","sourceLanguage":"auto"] : ["suggestedTitle":"选中文字.txt"]
        if translate {
            let alert=NSAlert();alert.messageText=L10n.text("翻译选中文字");alert.informativeText=L10n.text("选择目标语言；文本将交给搞截图的翻译界面。")
            let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:260,height:28))
            let languages=[("简体中文","zh-Hans"),("English","en"),("日本語","ja"),("Deutsch","de"),("Français","fr"),("Español","es"),("한국어","ko"),("Português","pt")]
            picker.addItems(withTitles:languages.map(\.0));alert.accessoryView=picker;alert.addButton(withTitle:L10n.text("继续"));alert.addButton(withTitle:L10n.text("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else {return}
            parameters["targetLanguage"]=languages[picker.indexOfSelectedItem].1
        }
        do { _ = try gaoActionClient.providerURL(bundleID:target,action:action,parameters:parameters,items:true) }
        catch {store.notify(error.localizedDescription,failed:true);return}
        let operation=store.beginCrossApplicationOperation()
        Task { @MainActor in
            defer {self.store.endCrossApplicationOperation(operation)}
            let inputs=LocalData(directory:self.store.data.directory.appendingPathComponent("Exchange/SelectionInputs",isDirectory:true))
            let name=UUID().uuidString+".txt"
            do {
                try inputs.createFile(Data(snapshot.selectedText.utf8),name:name)
                defer {try? inputs.removeKnownFile(name)}
                _ = try await self.gaoActionClient.sendRequest(action:action,targetBundleID:target,parameters:parameters,inputFiles:[inputs.directory.appendingPathComponent(name)])
                self.store.notify("已交给提供方，完成状态可在跨应用任务中查看")
            } catch {self.store.notify(error.localizedDescription,failed:true)}
        }
    }
}
