import AppKit
import FinderSync
import Darwin

final class GaoFinderSync: FIFinderSync {
    private let actionIDs = FinderActionRequest.allowedActions.sorted()

    override init() {
        super.init()
        let homePath = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        // Monitor the user's home so ordinary project and custom folders work too.
        FIFinderSyncController.default().directoryURLs = [home]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let menu = NSMenu(title: "搞操作"); menu.autoenablesItems = false
        let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
        if menuKind == .contextualMenuForItems, !selection.isEmpty {
            let name = selection.count == 1 ? ((try? selection[0].resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? selection[0].lastPathComponent : selection[0].deletingPathExtension().lastPathComponent) : "归档"
            menu.addItem(item("压缩为“\(name).zip”", "archive.create", symbol: "archivebox"))
            let archiveTypes: Set<String> = ["zip","7z","rar","001","tar","gz","bz2","xz","tgz","tbz","txz","zst"]
            if selection.allSatisfy({archiveTypes.contains($0.pathExtension.lowercased())}) {
                menu.addItem(item("解压到当前目录", "archive.extract", symbol: "shippingbox"))
            }
        }
        let root = NSMenuItem(title: "搞操作", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "搞操作"); submenu.autoenablesItems = false
        if !selection.isEmpty {
            submenu.addItem(item("复制路径", "path.copy")); submenu.addItem(item("复制文件名", "name.copy"))
            submenu.addItem(folderMenu(move: false)); submenu.addItem(folderMenu(move: true))
            submenu.addItem(item("批量重命名…", "files.rename")); submenu.addItem(.separator())
            let archiveMenu = NSMenu(title: "压缩与解压"); archiveMenu.autoenablesItems = false
            for (title, id) in [("压缩为 ZIP", "archive.create"),("压缩为 7Z", "archive.7z"),("加密 / 分卷 / 自定义压缩…", "archive.custom"),("直接解压", "archive.extract"),("解压到其他目录…", "archive.extract.custom"),("查看包内文件…", "archive.list")] { archiveMenu.addItem(item(title, id)) }
            let archiveRoot = NSMenuItem(title: "压缩与解压", action:nil,keyEquivalent:""); archiveRoot.submenu=archiveMenu; submenu.addItem(archiveRoot)
            let imageTypes: Set<String> = ["png","jpg","jpeg","heic","heif","tif","tiff","bmp","gif","webp"]
            if selection.allSatisfy({imageTypes.contains($0.pathExtension.lowercased())}) {
                let imageMenu=NSMenu(title:"图片转换"); imageMenu.autoenablesItems=false
                for (title,id) in [("转为 PNG","images.png"),("转为 JPEG","images.jpeg"),("转为 HEIC","images.heic"),("转为 TIFF","images.tiff"),("自定义格式与尺寸…","images.convert")] { imageMenu.addItem(item(title,id)) }
                let imageRoot=NSMenuItem(title:"图片转换",action:nil,keyEquivalent:"");imageRoot.submenu=imageMenu;submenu.addItem(imageRoot)
            }
            submenu.addItem(item("复制 SHA-256", "hash.sha256")); submenu.addItem(.separator())
        }
        let newMenu=NSMenu(title:"新建");newMenu.autoenablesItems=false
        for (title,id) in [("文本文件","new.text"),("Markdown","new.markdown"),("文件夹","new.folder"),("自定义名称与内容…","new.custom")] { newMenu.addItem(item(title,id)) }
        let newRoot=NSMenuItem(title:"新建",action:nil,keyEquivalent:"");newRoot.submenu=newMenu;submenu.addItem(newRoot)
        submenu.addItem(item("在终端打开", "terminal.open"))
        root.submenu=submenu;menu.addItem(root)
        return menu
    }

    private func folderMenu(move: Bool) -> NSMenuItem {
        let verb=move ? "移动到" : "复制到", prefix=move ? "files.move" : "files.copy"
        let root=NSMenuItem(title:verb,action:nil,keyEquivalent:"")
        let menu=NSMenu(title:verb);menu.autoenablesItems=false
        for (name,key) in [("桌面","desktop"),("下载","downloads"),("文稿","documents")] { menu.addItem(item(name,prefix+"."+key)) }
        menu.addItem(.separator());menu.addItem(item("选择其他目录…",prefix));root.submenu=menu;return root
    }
    private func item(_ title: String, _ action: String, symbol: String? = nil) -> NSMenuItem {
        let value=NSMenuItem(title:title,action:#selector(openAction(_:)),keyEquivalent:"")
        value.target=self;value.tag=(actionIDs.firstIndex(of:action) ?? -1)+1
        let urls=contextURLs(for:action);value.isEnabled = !urls.isEmpty && urls.count <= 1000
        if let symbol { value.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
        return value
    }
    @MainActor @objc private func openAction(_ sender: NSMenuItem) {
        guard sender.tag > 0, sender.tag <= actionIDs.count else { return }
        let action=actionIDs[sender.tag-1], urls=contextURLs(for:action)
        guard let url=FinderActionRequest.issue(action:action,urls:urls) else { return }
        let extensionURL=Bundle.main.bundleURL
        let pluginsURL=extensionURL.deletingLastPathComponent(), contentsURL=extensionURL.deletingLastPathComponent().deletingLastPathComponent()
        let appURL=contentsURL.deletingLastPathComponent()
        guard extensionURL.pathExtension == "appex",pluginsURL.lastPathComponent == "PlugIns",contentsURL.lastPathComponent == "Contents",appURL.pathExtension == "app",Bundle(url:appURL)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else { return }
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=false;configuration.allowsRunningApplicationSubstitution=false
        configuration.arguments=["--background-action"]
        NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:configuration) { _,error in
            if let error=error as NSError? { NSLog("GaoFinderSync open failed code=%ld",error.code) }
        }
    }
    private func contextURLs(for action: String) -> [URL] {
        let controller=FIFinderSyncController.default()
        let selection=controller.selectedItemURLs() ?? [], target=controller.targetedURL()
        let urls=action.hasPrefix("new.") ? (target.map{[$0]} ?? selection) : (selection.isEmpty ? target.map{[$0]} ?? [] : selection)
        var seen=Set<String>()
        return urls.filter{$0.isFileURL && $0.path.hasPrefix("/") && seen.insert($0.path).inserted}
    }
}
