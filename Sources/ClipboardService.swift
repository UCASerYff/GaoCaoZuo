import AppKit
import Combine
import CryptoKit
import ApplicationServices
import Carbon

enum ClipboardKind: String, Codable { case text, image, files }
struct ClipboardItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var kind: ClipboardKind
    var title: String
    var text: String?
    var imageFile: String?
    var richTextFile: String?
    var paths: [String]?
    var pinned = false
    var sourceApp: String
}
struct ClipboardDocument: Codable { var schema = 1; var items: [ClipboardItem] = [] }

@MainActor final class ClipboardService: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var enabled = false
    @Published private(set) var error: String?
    private let storage: LocalData
    private var timer: Timer?
    private var count = 0
    private var retention = 7
    private var limit = 200
    private var excluded: Set<String> = []
    private var writable = true
    private var previousApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var pasteTask: Task<Void, Never>?
    init(directory: URL, tracksApplications: Bool = true) {
        storage = LocalData(directory: directory.appendingPathComponent("Clipboard", isDirectory: true))
        do {
            if let saved = try storage.load("history.json", as: ClipboardDocument.self) {
                try Self.validateDocument(saved, storage: storage)
                items = saved.items
            }
        } catch { stopWriting(error) }
        if tracksApplications {
            rememberApplication(NSWorkspace.shared.frontmostApplication)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.rememberApplication(application) }
            }
        }
    }

    /// Read-only validation helper. Does not create directories or touch the system pasteboard.
    static func validateDocument(_ document: ClipboardDocument, directory: URL) throws {
        try validateDocument(document, storage: LocalData(directory: directory, createIfMissing: false))
    }
    private static func validateDocument(_ document: ClipboardDocument, storage: LocalData) throws {
        guard document.schema == 1 else { throw DataFailure.message("剪贴板资料格式不受支持，请保留原资料。") }
        if let failure = storage.failure { throw DataFailure.message(failure) }
        var seen: Set<UUID> = []
        for item in document.items {
            guard seen.insert(item.id).inserted else { throw DataFailure.message("剪贴板历史存在重复 ID，已停止写入。") }
            try validateItem(item, storage: storage)
        }
    }
    private static func attachmentNames(_ item: ClipboardItem) throws -> [String] {
        var names: [String] = []
        if let name = item.imageFile {
            guard item.kind == .image, name == item.id.uuidString + ".png" else { throw DataFailure.message("图片附件名称与记录 ID 不匹配，已停止写入。") }
            names.append(name)
        }
        if let name = item.richTextFile {
            guard item.kind == .text, name == item.id.uuidString + ".rtf" else { throw DataFailure.message("富文本附件名称与记录 ID 不匹配，已停止写入。") }
            names.append(name)
        }
        switch item.kind {
        case .image: guard item.imageFile != nil else { throw DataFailure.message("图片记录缺少附件，已停止写入。") }
        case .text: guard item.text != nil else { throw DataFailure.message("文字记录缺少内容，已停止写入。") }
        case .files: guard let paths = item.paths, !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw DataFailure.message("文件记录的路径格式无效，已停止写入。") }
        }
        return names
    }
    private static func validateItem(_ item: ClipboardItem, storage: LocalData) throws {
        for name in try attachmentNames(item) {
            _ = try storage.verifiedData(name, maximumSize: name.hasSuffix(".png") ? 20_000_000 : 4_000_000)
        }
    }
    func configure(_ settings: OperationSettings) {
        retention = max(1, min(365, settings.clipboardDays)); limit = max(20, min(1000, settings.clipboardLimit)); excluded = Set(settings.clipboardExcludedApps)
        enabled = settings.clipboardEnabled && writable
        timer?.invalidate(); timer = nil
        if enabled {
            count = NSPasteboard.general.changeCount
            expire()
            if enabled { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
        }
    }
    func poll() {
        guard enabled, writable else { return }
        let board = NSPasteboard.general
        guard board.changeCount != count else { return }
        count = board.changeCount
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !excluded.contains(bundle) else { return }
        let prohibited = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        guard !(board.types ?? []).contains(where: { type in prohibited.contains(where: { type.rawValue.hasPrefix($0) }) }) else { return }
        do {
            try Self.validateDocument(ClipboardDocument(items: items), storage: storage)
            var item: ClipboardItem?
            var attachment: (name: String, data: Data)?
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                item = ClipboardItem(kind: .files, title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件", paths: urls.map(\.path), sourceApp: bundle)
            } else if let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 2_000_000 {
                var next = ClipboardItem(kind: .text, title: String(text.replacingOccurrences(of: "\n", with: " ").prefix(100)), text: text, sourceApp: bundle)
                if let rtf = board.data(forType: .rtf), rtf.count < 4_000_000 {
                    let name = next.id.uuidString + ".rtf"; attachment = (name, rtf); next.richTextFile = name
                }
                item = next
            } else if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let image = images.first, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]), png.count <= 20_000_000 {
                var next = ClipboardItem(kind: .image, title: "图片 · \(rep.pixelsWide) × \(rep.pixelsHigh)", sourceApp: bundle)
                let name = next.id.uuidString + ".png"; attachment = (name, png); next.imageFile = name; item = next
            }
            if let item {
                if let first = items.first, first.kind == item.kind, first.text == item.text, first.paths == item.paths, item.kind != .image { return }
                if let attachment { try storage.createFile(attachment.data, name: attachment.name) }
                try persist([item] + items)
                expire()
            }
        } catch { stopWriting(error) }
    }
    private func persist(_ proposed: [ClipboardItem]) throws {
        guard writable else { throw DataFailure.message(error ?? "剪贴板资料已锁定，停止写入。") }
        // Check the complete previous document too: deleting a broken item must not bypass protection.
        try Self.validateDocument(ClipboardDocument(items: items), storage: storage)
        try Self.validateDocument(ClipboardDocument(items: proposed), storage: storage)
        try storage.save(ClipboardDocument(items: proposed), name: "history.json")
        items = proposed
    }
    private func removeAttachments(_ item: ClipboardItem) throws {
        for name in try Self.attachmentNames(item) { try storage.removeKnownFile(name) }
    }
    private func stopWriting(_ problem: Error) {
        error = problem.localizedDescription; writable = false; enabled = false
        storage.block(problem.localizedDescription)
        timer?.invalidate(); timer = nil
    }
    func expire() {
        guard writable else { return }
        let cutoff = Date().addingTimeInterval(-Double(retention) * 86400)
        var kept = 0
        let proposed = items.filter { item in
            if item.pinned { return true }
            kept += 1; return item.date >= cutoff && kept <= limit
        }
        let removed = items.filter { item in !proposed.contains { $0.id == item.id } }
        do {
            try Self.validateDocument(ClipboardDocument(items: items), storage: storage)
            if !removed.isEmpty { try persist(proposed); for item in removed { try removeAttachments(item) } }
        } catch { stopWriting(error) }
    }
    func pin(_ id: UUID) {
        guard writable, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var proposed = items; proposed[index].pinned.toggle()
        do { try persist(proposed) } catch { stopWriting(error) }
    }
    func delete(_ id: UUID) {
        guard writable, let item = items.first(where: { $0.id == id }) else { return }
        do { try persist(items.filter { $0.id != id }); try removeAttachments(item) } catch { stopWriting(error) }
    }
    func clearUnpinned() {
        guard writable else { return }
        let removed = items.filter { !$0.pinned }
        do { try persist(items.filter(\.pinned)); for item in removed { try removeAttachments(item) } } catch { stopWriting(error) }
    }
    func copy(_ item: ClipboardItem, plain: Bool = false) throws {
        do {
        guard let saved = items.first(where: { $0.id == item.id }) else { throw DataFailure.message("这条剪贴板记录已经不存在。") }
        do { try Self.validateItem(saved, storage: storage) } catch { stopWriting(error); throw error }
        let board = NSPasteboard.general
        let object = NSPasteboardItem()
        switch saved.kind {
        case .files:
            guard let paths = saved.paths else { throw DataFailure.message("文件路径已失效。") }
            board.clearContents()
            guard board.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }) else { throw DataFailure.message("无法写入系统剪贴板。") }
        case .image:
            guard let name = saved.imageFile else { throw DataFailure.message("图片附件缺失。") }
            let data = try storage.verifiedData(name, maximumSize: 20_000_000)
            guard NSImage(data: data) != nil else { throw DataFailure.message("图片附件内容无法解码。") }
            object.setData(data, forType: .png)
            board.clearContents()
            guard board.writeObjects([object]) else { throw DataFailure.message("无法写入系统剪贴板。") }
        case .text:
            guard let text = saved.text else { throw DataFailure.message("文字记录内容缺失。") }
            object.setString(text, forType: .string)
            if !plain, let name = saved.richTextFile { object.setData(try storage.verifiedData(name, maximumSize: 4_000_000), forType: .rtf) }
            board.clearContents()
            guard board.writeObjects([object]) else { throw DataFailure.message("无法写入系统剪贴板。") }
        }
        count = board.changeCount
        } catch {
            if storage.failure != nil { stopWriting(error) }
            throw error
        }
    }
    func image(_ item: ClipboardItem) -> NSImage? {
        do {
            guard let saved = items.first(where: { $0.id == item.id }), let name = saved.imageFile else { return nil }
            try Self.validateItem(saved, storage: storage)
            return NSImage(data: try storage.verifiedData(name, maximumSize: 20_000_000))
        } catch { stopWriting(error); return nil }
    }
    func copyText(_ text: String) { let board = NSPasteboard.general; board.clearContents(); board.setString(text, forType: .string); count = board.changeCount }

    private func rememberApplication(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular, !application.isTerminated else { return }
        previousApplication = application
    }
    func paste(_ item: ClipboardItem, plain: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw DataFailure.message("自动粘贴需要辅助功能权限；也可以先复制后手动按 ⌘V。") }
        guard !IsSecureEventInputEnabled() else { throw DataFailure.message("系统正处于安全输入状态，暂不发送自动粘贴。") }
        rememberApplication(NSWorkspace.shared.frontmostApplication)
        guard let target = previousApplication, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw DataFailure.message("没有可粘贴的目标应用。请先切换到目标应用，再打开剪贴板。") }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw DataFailure.message("无法创建系统粘贴事件。") }
        pasteTask?.cancel()
        try copy(item, plain: plain)
        let expectedCount = NSPasteboard.general.changeCount
        guard target.activate(options: []) else { throw DataFailure.message("目标应用无法激活；内容已复制，可手动粘贴。") }
        pasteTask = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), NSPasteboard.general.changeCount == expectedCount else {
                    self.error = "粘贴前权限、输入状态或剪贴板内容发生变化，已取消自动粘贴。"; return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    down.flags = .maskCommand; up.flags = .maskCommand
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                    return
                }
            }
            self?.error = "未能确认目标应用已位于前台，已取消自动粘贴；内容仍在剪贴板。"
        }
    }
    isolated deinit {
        timer?.invalidate(); pasteTask?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}
