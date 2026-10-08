import AppKit
import FinderSync
import Darwin

/// Finder only gathers context; every action opens the main app for review before any mutation.
final class GaoFinderSync: FIFinderSync {
    private struct Action {
        let id: String
        let title: String
    }
    private let actions: [Action] = [
        .init(id: "new.text", title: "新建文本…"),
        .init(id: "new.markdown", title: "新建 Markdown…"),
        .init(id: "path.copy", title: "复制路径…"),
        .init(id: "files.copy", title: "复制到…"),
        .init(id: "files.move", title: "移动到…"),
        .init(id: "files.rename", title: "批量改名…"),
        .init(id: "archive.create", title: "压缩…"),
        .init(id: "archive.extract", title: "解压…")
    ]

    override init() {
        super.init()
        // getpwuid resolves the real account home, rather than the extension's sandbox container.
        let homePath = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let folders = ["Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0, isDirectory: true) }
        FIFinderSyncController.default().directoryURLs = Set(folders)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let menu = NSMenu(title: "搞操作")
        let root = NSMenuItem(title: "搞操作", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "搞操作")
        submenu.autoenablesItems = false
        for (index, action) in actions.enumerated() {
            let urls = contextURLs(for: action)
            let item = NSMenuItem(title: action.title, action: #selector(openAction(_:)), keyEquivalent: "")
            item.target = self
            // Finder forwards a menu action across the extension boundary. Keep only a scalar action tag.
            // Do not depend on an arbitrary representedObject dictionary surviving that boundary.
            item.tag = index + 1
            item.isEnabled = !urls.isEmpty && urls.count <= 1000
            submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
        return menu
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        guard sender.tag > 0, sender.tag <= actions.count else { return }
        let index = sender.tag - 1
        let action = actions[index]
        // Apple's FinderSync contract makes these getters valid inside the menu action itself.
        // Read before opening the containing app, while Finder's menu context is still current.
        let paths = contextURLs(for: action).map(\.path)
        guard !paths.isEmpty,
              paths.count <= 1000,
              let data = try? JSONSerialization.data(withJSONObject: paths) else { return }
        var components = URLComponents()
        components.scheme = "gaocaozuo"; components.host = "perform"; components.path = "/" + action.id
        components.queryItems = [URLQueryItem(name: "payload", value: data.base64EncodedString())]
        guard let url = components.url, url.absoluteString.utf8.count <= 120_000 else { return }
        NSWorkspace.shared.open(url)
    }

    /// Invoke only from menu(for:) or its action callback, as required by FIFinderSyncController.
    private func contextURLs(for action: Action) -> [URL] {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let target = controller.targetedURL()
        let urls: [URL]
        if action.id.hasPrefix("new.") {
            urls = target.map { [$0] } ?? selection
        } else {
            urls = selection.isEmpty ? target.map { [$0] } ?? [] : selection
        }
        var seen = Set<String>()
        return urls.filter { $0.isFileURL && $0.path.hasPrefix("/") && seen.insert($0.path).inserted }
    }
}
