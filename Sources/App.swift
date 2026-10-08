import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main enum GaoOperationMain {
    @MainActor static func main() {
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
    private var statusItem: NSStatusItem!
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var earlyURLs: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args=CommandLine.arguments
        let directory: URL
        if let i=args.firstIndex(of:"--data-dir"),args.count>i+1,args[i+1].hasPrefix("/") {directory=URL(fileURLWithPath:args[i+1],isDirectory:true)}
        else {directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoCaoZuo",isDirectory:true)}
        store=OperationStore(directory:directory)
        store.showMain={ [weak self] in self?.showMain() }
        store.showPanel={ [weak self] in self?.showPanel() }
        store.showSettings={ [weak self] in self?.showSettings() }
        store.onSettingsChanged={ [weak self] in self?.configureInput();self?.applyAppearance() }
        NSApp.servicesProvider=self
        NSUpdateDynamicServices()
        mainWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        mainWindow.title="搞操作 V\(store.version)";mainWindow.minSize=NSSize(width:960,height:680);mainWindow.isReleasedWhenClosed=false;mainWindow.delegate=self
        mainWindow.contentView=NSHostingView(rootView:OperationRootView(store:store));mainWindow.center();mainWindow.setFrameAutosaveName("GaoCaoZuo.main")
        installMenu();configureStatus();configureInput();applyAppearance()
        activationObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self]note in
            guard let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else{return}
            Task{@MainActor in self?.store.windows.captureTarget();self?.panel?.orderOut(nil)}
        }
        showMain()
        if let i=args.firstIndex(of:"--open"),args.count>i+1 {store.selection=[URL(fileURLWithPath:args[i+1])]}
        if !earlyURLs.isEmpty {let urls=earlyURLs;earlyURLs=[];application(NSApp,open:urls)}
    }
    private func configureInput(){store.input.configure(bindings:store.settings.bindings,excludedApps:store.settings.inputExcludedApps,windows:store.windows,windowDragEnabled:store.settings.windowDragEnabled,windowSnapEnabled:store.settings.windowSnapEnabled){[weak self]id in guard let self else{return};self.store.windows.captureTarget();self.store.prepare(id)}}
    private func applyAppearance(){NSApp.appearance=store.settings.appearance == "system" ? nil : NSAppearance(named:store.settings.appearance == "dark" ? .darkAqua : .aqua)}
    func showMain(){store.windows.captureTarget();mainWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func showPanel(){
        store.windows.captureTarget()
        if panel?.isVisible == true {panel?.orderOut(nil);return}
        let panel=self.panel ?? OperationPanel(contentRect:NSRect(x:0,y:0,width:600,height:480),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.standardWindowButton(.closeButton)?.isHidden=true;panel.standardWindowButton(.miniaturizeButton)?.isHidden=true;panel.standardWindowButton(.zoomButton)?.isHidden=true
        panel.level = .floating;panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=true;panel.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:OperationPanelView(store:store,close:{[weak panel] in panel?.orderOut(nil)}))
        let point=NSEvent.mouseLocation
        let screen=NSScreen.screens.first(where:{$0.frame.contains(point)}) ?? NSScreen.main
        if let frame=screen?.visibleFrame {panel.setFrameOrigin(NSPoint(x:frame.midX-300,y:frame.midY-240))}else{panel.center()}
        self.panel=panel;panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func showSettings(){
        store.windows.captureTarget()
        if settingsWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="搞操作设置";window.isReleasedWhenClosed=false;window.contentView=NSHostingView(rootView:OperationSettingsView(store:store));window.center();settingsWindow=window
        }
        settingsWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    private func installMenu(){
        let menu=NSMenu()
        let appMenu=NSMenu();appMenu.addItem(item("关于搞操作",#selector(about)));appMenu.addItem(.separator());appMenu.addItem(item("设置…",#selector(settingsAction),key:","));appMenu.addItem(.separator());appMenu.addItem(item("退出搞操作",#selector(quit),key:"q"))
        menu.addItem(withTitle:"搞操作",action:nil,keyEquivalent:"").submenu=appMenu
        let file=NSMenu();file.addItem(item("选择文件…",#selector(selectFiles),key:"o"));file.addItem(item("显示主窗口",#selector(mainAction),key:"0"));file.addItem(item("打开操作面板",#selector(panelAction)));file.addItem(.separator());file.addItem(item("关闭窗口",#selector(closeWindow),key:"w"))
        menu.addItem(withTitle:"文件",action:nil,keyEquivalent:"").submenu=file
        let edit=NSMenu()
        for (title,selector,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key))}
        menu.addItem(withTitle:"编辑",action:nil,keyEquivalent:"").submenu=edit
        let window=NSMenu();window.addItem(NSMenuItem(title:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"));menu.addItem(withTitle:"窗口",action:nil,keyEquivalent:"").submenu=window;NSApp.windowsMenu=window
        let help=NSMenu();help.addItem(item("使用说明",#selector(helpAction)));menu.addItem(withTitle:"帮助",action:nil,keyEquivalent:"").submenu=help
        NSApp.mainMenu=menu
    }
    private func item(_ title:String,_ selector:Selector,key:String="")->NSMenuItem{let value=NSMenuItem(title:title,action:selector,keyEquivalent:key);value.target=self;return value}
    private func configureStatus(){statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);statusItem.button?.image=NSImage(systemSymbolName:"cursorarrow.motionlines",accessibilityDescription:"搞操作");statusItem.button?.toolTip="搞操作";statusItem.button?.target=self;statusItem.button?.action=#selector(statusClicked);statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])}
    @objc private func statusClicked(){
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu();menu.addItem(item("打开操作面板",#selector(panelAction)));menu.addItem(item("显示主窗口",#selector(mainAction)));menu.addItem(.separator());menu.addItem(item(store.input.isPaused ? "恢复快捷键与手势" : "暂停快捷键与手势",#selector(pauseInput)));menu.addItem(item("设置…",#selector(settingsAction)));menu.addItem(.separator());menu.addItem(item("退出搞操作",#selector(quit)))
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil
        }else{showPanel()}
    }
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
    func application(_ application:NSApplication,open urls:[URL]){
        guard store != nil else{earlyURLs += urls;return}
        guard !store.busy,!store.archive.isRunning,store.sheet == nil else{store.error="当前操作尚未完成，请关闭工具窗口后再打开新文件。";return}
        let fileURLs=urls.filter(\.isFileURL)
        if !fileURLs.isEmpty {store.selection=fileURLs}
        for url in urls {
            if url.scheme == "gaocaozuo", url.host == "perform", let components=URLComponents(url:url,resolvingAgainstBaseURL:false),let value=components.queryItems?.first(where:{$0.name == "payload"})?.value,value.utf8.count <= 512_000, let bytes=Data(base64Encoded:value),let paths=try? JSONDecoder().decode([String].self,from:bytes),paths.count <= 10_000,paths.allSatisfy({$0.hasPrefix("/") && !$0.contains("\0")}) {
                let action=url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"));let allowed=["new.text","new.markdown","path.copy","files.copy","files.move","files.rename","archive.create","archive.extract"]
                guard allowed.contains(action) else{continue}
                store.selection=paths.map{URL(fileURLWithPath:$0)};showMain()
                // External links prepare actions for review; even copying a path remains an explicit user action.
                if action == "path.copy" {store.section = .files;store.message="已接收文件，点击“复制文件路径”执行"}else{store.sheet=ToolRequest(actionID:action)}
            }
        }
        if urls.contains(where:{$0.isFileURL}){showMain()}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showMain();return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        if store.busy || store.archive.isRunning || store.workflowRunning {
            let alert=NSAlert();alert.messageText="任务仍在运行";alert.informativeText="请等待文件任务完成，或在任务界面取消压缩/组合操作后退出。";alert.addButton(withTitle:"返回任务");alert.runModal();showMain();return .terminateCancel
        }
        store.input.stop();SystemActions.releasePreventSleep();return .terminateNow
    }
}
