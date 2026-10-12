import AppKit
import FinderSync
import Darwin

/// FinderSync can deliver synchronous Objective-C callbacks on an XPC worker.
/// Keep the reply synchronous while moving AppKit work onto its main executor.
/// Never dispatch synchronously when the callback already runs on that executor.
enum FinderCallbackMainActor {
    static func sync(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
        }
    }
}

final class GaoFinderSync: FIFinderSync {
    private var observer:NSObjectProtocol?
    override init() {
        super.init()
        FinderCallbackMainActor.sync { updateScope() }
        observer=DistributedNotificationCenter.default().addObserver(forName:FinderMenuSnapshot.changedNotification,object:nil,queue:.main) { [weak self] _ in
            FinderCallbackMainActor.sync { self?.updateScope() }
        }
    }
    deinit {if let observer {DistributedNotificationCenter.default().removeObserver(observer)}}
    @MainActor private func updateScope() {
        let path=getpwuid(getuid()).flatMap{$0.pointee.pw_dir}.map{String(cString:$0)} ?? NSHomeDirectory()
        let preferences=FinderMenuSnapshot.read()?.preferences ?? FinderMenuPreferences()
        var roots:Set<URL>=[URL(fileURLWithPath:path,isDirectory:true)]
        if preferences.includeExternalVolumes {for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[]) ?? [] {roots.insert(volume)}}
        FIFinderSyncController.default().directoryURLs=roots
    }
    override var toolbarItemName:String {"搞操作"}
    override var toolbarItemToolTip:String {"当前目录的快捷操作"}
    override var toolbarItemImage:NSImage {
        var image:NSImage!
        FinderCallbackMainActor.sync { image=NSImage(systemSymbolName:"cursorarrow.motionlines",accessibilityDescription:"搞操作") ?? NSImage() }
        return image
    }
    override func menu(for menuKind:FIMenuKind)->NSMenu? {
        var menu:NSMenu?
        FinderCallbackMainActor.sync { menu=makeMenu(for:menuKind) }
        return menu
    }
    @MainActor private func makeMenu(for menuKind:FIMenuKind)->NSMenu? {
        guard [.contextualMenuForItems,.contextualMenuForContainer,.contextualMenuForSidebar,.toolbarItemMenu].contains(menuKind) else {return nil}
        let snapshot=FinderMenuSnapshot.read() ?? FinderMenuSnapshot()
        if menuKind == .toolbarItemMenu && !snapshot.preferences.showToolbar {return nil}
        let controller=FIFinderSyncController.default(),selection=controller.selectedItemURLs() ?? []
        let urls=selection.isEmpty ? controller.targetedURL().map{[$0]} ?? [] : selection
        guard !urls.isEmpty,!FinderMenuContext.isExcluded(urls,preferences:snapshot.preferences) else{return nil}
        return FinderMenuBuilder.menu(snapshot:snapshot,urls:urls,hasSelection:menuKind == .contextualMenuForItems && !selection.isEmpty,target:self,selector:#selector(openAction(_:)))
    }
    @objc private func openAction(_ sender:NSMenuItem) {
        FinderCallbackMainActor.sync { performAction(sender) }
    }
    @MainActor private func performAction(_ sender:NSMenuItem) {
        guard let action=sender.representedObject as? String,FinderActionRequest.isAllowed(action) else{return}
        let controller=FIFinderSyncController.default(),selection=controller.selectedItemURLs() ?? []
        let containerAction=FinderMenuContext.usesContainer(action)
        let urls=containerAction ? controller.targetedURL().map{[$0]} ?? selection : selection.isEmpty ? controller.targetedURL().map{[$0]} ?? [] : selection
        guard let url=FinderActionRequest.issue(action:action,urls:urls) else{return}
        let extensionURL=Bundle.main.bundleURL,pluginsURL=extensionURL.deletingLastPathComponent(),contentsURL=extensionURL.deletingLastPathComponent().deletingLastPathComponent(),appURL=extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard extensionURL.pathExtension == "appex",pluginsURL.lastPathComponent == "PlugIns",contentsURL.lastPathComponent == "Contents",appURL.pathExtension == "app",Bundle(url:appURL)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else{return}
        let config=NSWorkspace.OpenConfiguration();config.activates=false;config.allowsRunningApplicationSubstitution=false;config.arguments=["--background-action"]
        NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:config){_,error in if let error=error as NSError?{NSLog("GaoFinderSync open failed code=%ld",error.code)}}
    }
}
