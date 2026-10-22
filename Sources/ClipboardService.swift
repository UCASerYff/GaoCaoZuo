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
    var group: String?
    var tags: [String]?
    var imageSHA256: String?
    var richTextSHA256: String?
}
struct ClipboardDocument: Codable { var schema = 1; var items: [ClipboardItem] = [] }

@MainActor final class ClipboardService: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var enabled = false
    @Published private(set) var error: String?
    @Published private(set) var pendingPaste: PendingPaste?
    @Published private(set) var hasActivePasteTransaction = false
    @Published private(set) var hasCopyRecovery=false
    private var copyRecovery:ClipboardExplicitCopy.Recovery? {didSet {refreshClipboardActivity()}}
    private let secureInputForCopy:()->Bool
    private let storage: LocalData
    private var timer: Timer?
    private var count = 0
    private var retention = 7
    private var limit = 200
    private var excluded: Set<String> = []
    private var writable = true
    private var previousApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var mergeRecoveryObserver:AnyCancellable?
    private var pasteTask: Task<Void, Never>?
    private var pasteTarget: ClipboardPasteTarget?
    private var pasteTransaction: ClipboardPasteTransaction? {didSet {refreshClipboardActivity()}}
    private var transactionTarget: ClipboardPasteTarget?
    private var transactionCompletion: (() throws -> Void)?
    var onPasteResult: ((String,Bool)->Void)?
    var onPasteReviewNeeded: (() -> Void)?
    /// Read-only lifecycle gate, evaluated again immediately before event posts.
    var pasteBlockingReason: (() -> String?)?
    init(directory: URL, tracksApplications: Bool = true,secureInputForCopy:@escaping()->Bool={IsSecureEventInputEnabled()}) {
        self.secureInputForCopy=secureInputForCopy
        storage = LocalData(directory: directory.appendingPathComponent("Clipboard", isDirectory: true))
        do {
            if let saved = try storage.load("history.json", as: ClipboardDocument.self) {
                try Self.validateDocument(saved, storage: storage)
                items = try saved.items.map {try Self.addAttachmentDigests($0,storage:storage)}
            }
        } catch { stopWriting(error) }
        mergeRecoveryObserver=PasteStack.shared.$mergeCopyRecovery.sink { [weak self] recovery in
            guard let self else {return}
            self.copyRecovery=recovery
            if recovery != nil {self.onPasteReviewNeeded?()}
        }
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
        guard document.schema == 1 else { throw DataFailure.message(L10n.text("剪贴板资料格式不受支持，请保留原资料。")) }
        guard document.items.count <= 2000 else {throw DataFailure.message(L10n.text("剪贴板记录超过安全数量，已停止写入。"))}
        if let failure = storage.failure { throw DataFailure.message(failure) }
        var seen: Set<UUID> = []
        var attachmentBytes=0
        for item in document.items {
            guard seen.insert(item.id).inserted else { throw DataFailure.message(L10n.text("剪贴板历史存在重复 ID，已停止写入。")) }
            attachmentBytes += try validateItem(item, storage: storage)
            guard attachmentBytes <= 256_000_000 else {throw DataFailure.message(L10n.text("剪贴板附件超过256MB安全预算，原资料已保留，已停止新增采集。"))}
        }
    }
    private static func attachmentNames(_ item: ClipboardItem) throws -> [String] {
        var names: [String] = []
        if let name = item.imageFile {
            guard item.kind == .image, name == item.id.uuidString + ".png" else { throw DataFailure.message(L10n.text("图片附件名称与记录 ID 不匹配，已停止写入。")) }
            names.append(name)
        }
        if let name = item.richTextFile {
            guard item.kind == .text, name == item.id.uuidString + ".rtf" else { throw DataFailure.message(L10n.text("富文本附件名称与记录 ID 不匹配，已停止写入。")) }
            names.append(name)
        }
        switch item.kind {
        case .image: guard item.imageFile != nil else { throw DataFailure.message(L10n.text("图片记录缺少附件，已停止写入。")) }
        case .text: guard item.text != nil else { throw DataFailure.message(L10n.text("文字记录缺少内容，已停止写入。")) }
        case .files: guard let paths = item.paths, !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw DataFailure.message(L10n.text("文件记录的路径格式无效，已停止写入。")) }
        }
        return names
    }
    @discardableResult private static func validateItem(_ item: ClipboardItem, storage: LocalData) throws -> Int {
        guard (item.group?.utf8.count ?? 0) <= 256, (item.tags?.count ?? 0) <= 32,
              item.tags?.allSatisfy({!$0.isEmpty && $0.utf8.count <= 128}) ?? true else {
            throw DataFailure.message(L10n.text("剪贴板分组或标签无效，已保留原资料。"))
        }
        guard (item.text?.utf8.count ?? 0) <= 2_000_000,(item.paths?.count ?? 0) <= 256,
              item.paths?.allSatisfy({$0.utf8.count <= 16_384}) ?? true else {throw DataFailure.message(L10n.text("剪贴板内容超过安全预算，已停止写入。"))}
        var total=0
        for name in try attachmentNames(item) {
            let bytes = try storage.verifiedData(name, maximumSize: name.hasSuffix(".png") ? 20_000_000 : 4_000_000)
            if let digest=name.hasSuffix(".png") ? item.imageSHA256 : item.richTextSHA256,
               digest != Self.digest(bytes) {throw DataFailure.message(L10n.text("剪贴板附件摘要不符，已保留原资料并停止使用。"))}
            total += bytes.count
        }
        return total
    }
    private static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    private static func addAttachmentDigests(_ original:ClipboardItem,storage:LocalData) throws -> ClipboardItem {
        var value=original
        if value.imageSHA256 == nil,let name=value.imageFile {value.imageSHA256=digest(try storage.verifiedData(name,maximumSize:20_000_000))}
        if value.richTextSHA256 == nil,let name=value.richTextFile {value.richTextSHA256=digest(try storage.verifiedData(name,maximumSize:4_000_000))}
        return value
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
        let readCount = board.changeCount
        guard readCount != count else { return }
        let origin = collectionContext()
        guard ClipboardCollectionPolicy.begin(changeCount: readCount, previous: &count, context: origin),
              !(board.types ?? []).contains(where: { ClipboardCollectionPolicy.isProhibitedType($0.rawValue) }) else { return }
        let bundle = origin.bundleID
        do {
            try Self.validateDocument(ClipboardDocument(items: items), storage: storage)
            var item: ClipboardItem?
            var attachment: (name: String, data: Data)?
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                item = ClipboardItem(kind: .files, title: urls.count == 1 ? urls[0].lastPathComponent : L10n.format("%@ 个文件", String(describing: (urls.count))), paths: urls.map(\.path), sourceApp: bundle)
            } else if let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 2_000_000 {
                var next = ClipboardItem(kind: .text, title: String(text.replacingOccurrences(of: "\n", with: " ").prefix(100)), text: text, sourceApp: bundle)
                if let rtf = board.data(forType: .rtf), rtf.count < 4_000_000 {
                    let name = next.id.uuidString + ".rtf"; attachment = (name, rtf); next.richTextFile = name;next.richTextSHA256=Self.digest(rtf)
                }
                item = next
            } else if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let image = images.first, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]), png.count <= 20_000_000 {
                var next = ClipboardItem(kind: .image, title: L10n.format("图片 · %@ × %@", String(describing: (rep.pixelsWide)), String(describing: (rep.pixelsHigh))), sourceApp: bundle)
                let name = next.id.uuidString + ".png"; attachment = (name, png); next.imageFile = name;next.imageSHA256=Self.digest(png); item = next
            }
            if let item {
                // Pasteboard reads can involve other processes. A focus, secure
                // input, process identity or pasteboard change invalidates the
                // complete observation before creating any durable attachment.
                guard ClipboardCollectionPolicy.permitsCommit(before: origin, after: collectionContext(),
                    readCount: readCount, currentCount: board.changeCount),
                    !(board.types ?? []).contains(where: { ClipboardCollectionPolicy.isProhibitedType($0.rawValue) }) else { return }
                if let first=items.first,first.kind == item.kind,first.text == item.text,first.paths == item.paths,
                   first.imageSHA256 == item.imageSHA256,first.richTextSHA256 == item.richTextSHA256 {return}
                if let attachment { try storage.createFile(attachment.data, name: attachment.name) }
                try persist([item] + items)
                expire()
            }
        } catch { stopWriting(error) }
    }
    private func collectionContext() -> ClipboardCollectionPolicy.Context {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? ""
        let secure = IsSecureEventInputEnabled()
        var secureField = false
        if !secure, AXIsProcessTrusted(), let app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let focused = SelectionTargetValidator.elementAttribute(element, kAXFocusedUIElementAttribute) {
                AXUIElementSetMessagingTimeout(focused, 0.1)
                secureField = SelectionTargetValidator.isSecure(focused)
            }
        }
        return .init(pid: app?.processIdentifier ?? 0, bundleID: bundle,
            launchIdentity: app.map { WindowProcessIdentity.auditTokenString(for: $0.processIdentifier) } ?? nil,
            secureInput: secure || IsSecureEventInputEnabled(), secureField: secureField,
            excluded: excluded.contains(bundle) || ClipboardCollectionPolicy.sensitiveApps.contains(bundle.lowercased()))
    }
    private func persist(_ proposed: [ClipboardItem]) throws {
        guard writable else { throw DataFailure.message(error ?? L10n.text("剪贴板资料已锁定，停止写入。")) }
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
    func setMetadata(_ id:UUID,group:String,tags:[String]) throws {
        guard let index=items.firstIndex(where:{$0.id == id}) else {throw DataFailure.message(L10n.text("剪贴板记录不存在。"))}
        var proposed=items
        proposed[index].group=group.isEmpty ? nil : group
        proposed[index].tags=tags.isEmpty ? nil : Array(Set(tags)).sorted()
        try persist(proposed)
    }
    func saveSelectedText(_ text:String,sourceApp:String) throws {
        guard !IsSecureEventInputEnabled(),!text.isEmpty,text.utf8.count <= 2_000_000 else {throw DataFailure.message(L10n.text("选区不可保存。"))}
        let item=ClipboardItem(kind:.text,title:String(text.replacingOccurrences(of:"\n",with:" ").prefix(100)),text:text,sourceApp:sourceApp)
        try persist([item]+items)
    }
    func areFilesAccessible(_ item: ClipboardItem) -> Bool {
        guard let paths = item.paths else { return false }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
    func pushToStack(_ text: String) {
        PasteStack.shared.push(text)
    }
    func pasteFromStack() throws {
        try requireClipboardIdle()
        let sourceChangeCount=NSPasteboard.general.changeCount
        guard let ticket=PasteStack.shared.peek() else {
            throw DataFailure.message(L10n.text("粘贴堆栈为空。"))
        }
        let objects=try PasteStack.shared.pasteboardItems(for:ticket)
        try pastePreparedItems(objects,sourceChangeCount:sourceChangeCount,beforeSubmit:{try PasteStack.shared.validateTicket(ticket)},onSubmitted:{try PasteStack.shared.commit(ticket)})
    }
    func pushCurrentToStack() throws {
        guard !IsSecureEventInputEnabled() else {throw DataFailure.message(L10n.text("安全输入期间不读取剪贴板。"))}
        let board=NSPasteboard.general
        let before = collectionContext(), readCount = board.changeCount
        guard before.permitsCapture,
              !(board.types ?? []).contains(where:{ClipboardCollectionPolicy.isProhibitedType($0.rawValue)}) else {throw DataFailure.message(L10n.text("此剪贴板内容标记为敏感或临时，未加入堆栈。"))}
        let paths=(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL])?.map(\.path) ?? []
        let text=board.string(forType:.string),rtf=board.data(forType:.rtf),png=board.data(forType:.png)
        guard ClipboardCollectionPolicy.permitsCommit(before:before,after:collectionContext(),readCount:readCount,currentCount:board.changeCount),
              !(board.types ?? []).contains(where:{ClipboardCollectionPolicy.isProhibitedType($0.rawValue)}) else {throw DataFailure.message(L10n.text("剪贴板或来源已变化，未加入堆栈。"))}
        try PasteStack.shared.pushContent(text:text,rtf:rtf,png:png,fileReferences:paths)
    }
    func copyMergedStack() throws {
        try requireClipboardIdle()
        guard !secureInputForCopy() else {throw DataFailure.message(L10n.text("安全输入期间不读取剪贴板。"))}
        let board=NSPasteboard.general,changeCount=NSPasteboard.general.changeCount
        let prepared=try PasteStack.shared.preparedMerge()
        try requireClipboardIdle()
        guard board.changeCount==changeCount,!secureInputForCopy() else {throw DataFailure.message(L10n.text("剪贴板或来源已变化，未加入堆栈。"))}
        do {try ClipboardExplicitCopy.publish(prepared,to:board,expectedCount:changeCount,shouldProceed:{!self.secureInputForCopy()})}
        catch let failure as ClipboardExplicitCopy.Failure {
            if let recovery=failure.recovery {retainCopyRecovery(recovery)}
            throw failure
        }
    }
    func resolveFailedCopy(restore:Bool)throws {
        guard let recovery=copyRecovery,pasteTransaction==nil else {return}
        if restore {
            guard !secureInputForCopy() else {throw DataFailure.message(L10n.text("安全输入期间不读取剪贴板。"))}
            try recovery.restore()
        }
        if PasteStack.shared.mergeCopyRecovery === recovery {PasteStack.shared.mergeCopyRecovery=nil}
        copyRecovery=nil
        count=recovery.board.changeCount
    }
    private func refreshClipboardActivity() {
        hasCopyRecovery=copyRecovery != nil
        hasActivePasteTransaction=pasteTransaction != nil || copyRecovery != nil
    }
    func retainCopyRecovery(_ recovery:ClipboardExplicitCopy.Recovery) {
        PasteStack.shared.mergeCopyRecovery=recovery
    }
    func requireClipboardIdle()throws {
        if copyRecovery==nil,let recovery=PasteStack.shared.mergeCopyRecovery {retainCopyRecovery(recovery)}
        guard copyRecovery==nil else {onPasteReviewNeeded?();throw DataFailure.message(L10n.text("请先处理复制前剪贴板的恢复选择。"))}
        try ClipboardPasteTransaction.requireIdle(pasteTransaction)
    }
    func pushToStack(_ item:ClipboardItem) throws {
        guard let saved=items.first(where:{$0.id == item.id}) else {throw DataFailure.message(L10n.text("剪贴板记录不存在。"))}
        try Self.validateItem(saved,storage:storage)
        let rtf=try saved.richTextFile.map {try storage.verifiedData($0,maximumSize:4_000_000)}
        let png=try saved.imageFile.map {try storage.verifiedData($0,maximumSize:20_000_000)}
        try PasteStack.shared.pushContent(text:saved.text,rtf:rtf,png:png,fileReferences:saved.paths ?? [])
    }
    private func preparedItems(_ item:ClipboardItem,plain:Bool) throws -> [NSPasteboardItem] {
        guard let saved=items.first(where:{$0.id == item.id}) else {throw DataFailure.message(L10n.text("这条剪贴板记录已经不存在。"))}
        do {try Self.validateItem(saved,storage:storage)} catch {stopWriting(error);throw error}
        let object=NSPasteboardItem()
        switch saved.kind {
        case .files:
            guard let paths=saved.paths,!paths.isEmpty,paths.allSatisfy({FileManager.default.fileExists(atPath:$0) && FileManager.default.isReadableFile(atPath:$0)}) else {throw DataFailure.message(L10n.text("原文件引用失效或不可访问，请重新选择原文件。"))}
            return paths.map {path in let item=NSPasteboardItem();item.setString(URL(fileURLWithPath:path).absoluteString,forType:.fileURL);return item}
        case .image:
            guard let name=saved.imageFile else {throw DataFailure.message(L10n.text("图片附件缺失。"))}
            let bytes=try storage.verifiedData(name,maximumSize:20_000_000)
            guard NSImage(data:bytes) != nil else {throw DataFailure.message(L10n.text("图片附件内容无法解码。"))}
            object.setData(bytes,forType:.png)
        case .text:
            guard let text=saved.text else {throw DataFailure.message(L10n.text("文字记录内容缺失。"))}
            object.setString(text,forType:.string)
            if !plain,let name=saved.richTextFile {object.setData(try storage.verifiedData(name,maximumSize:4_000_000),forType:.rtf)}
        }
        return [object]
    }
    func copy(_ item: ClipboardItem, plain: Bool = false) throws {
        let objects=try preparedItems(item,plain:plain)
        let board=NSPasteboard.general
        board.clearContents()
        guard board.writeObjects(objects) else {throw DataFailure.message(L10n.text("无法写入系统剪贴板。"))}
        count=board.changeCount
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
        try requireClipboardIdle()
        let sourceChangeCount=NSPasteboard.general.changeCount
        let objects=try preparedItems(item,plain:plain)
        try pastePreparedItems(objects,sourceChangeCount:sourceChangeCount)
    }

    /// Paste the current system text without formatting; does not enable history.
    func pastePlainText() throws {
        try requireClipboardIdle()
        let board = NSPasteboard.general
        let sourceCount = board.changeCount
        guard let text = board.string(forType: .string), !text.isEmpty else {
            throw DataFailure.message(L10n.text("剪贴板没有可粘贴的文字。"))
        }
        let item=NSPasteboardItem();item.setString(text,forType:.string)
        try pastePreparedItems([item],sourceChangeCount:sourceCount)

    }

    func capturePasteTarget() {
        guard !hasActivePasteTransaction,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {return}
        rememberApplication(NSWorkspace.shared.frontmostApplication)
        pasteTarget=ClipboardPasteTarget.capture()
    }

    /// Installs one temporary pasteboard lease. A submitted event is not proof
    /// that another process consumed its contents; only explicit user review
    /// can commit the supplied durable completion callback.
    func pastePreparedItems(_ objects:[NSPasteboardItem],sendEnter:Bool=false,sourceChangeCount:Int?=nil,beforeSubmit:(() throws -> Void)?=nil,onSubmitted:(() throws -> Void)?=nil) throws {
        try requireClipboardIdle()
        try ClipboardPasteTransaction.requireUnblocked(pasteBlockingReason?())
        try requireClipboardIdle()
        guard !objects.isEmpty else {throw DataFailure.message(L10n.text("没有可粘贴的内容。"))}
        guard AXIsProcessTrusted() else {throw DataFailure.message(L10n.text("自动粘贴需要辅助功能权限；也可以先复制后手动按 ⌘V。"))}
        guard !IsSecureEventInputEnabled() else {throw DataFailure.message(L10n.text("系统正处于安全输入状态，暂不发送自动粘贴。"))}
        let board=NSPasteboard.general
        let expectedSourceCount=sourceChangeCount ?? board.changeCount
        // Explicit panel/action entry captures its target before taking focus.
        // A stale captured target must fail, rather than silently rebinding to
        // whichever app happens to be foreground when preparation finishes.
        if pasteTarget == nil {capturePasteTarget()}
        guard let target=pasteTarget,target.canActivate(),
              let application=NSRunningApplication(processIdentifier:target.pid),!application.isTerminated else {
            throw DataFailure.message(L10n.text("原粘贴目标、焦点或选区已失效。请重新进入目标输入框，再打开剪贴板。"))
        }
        guard permitsTargetActivation(target) else {throw DataFailure.message(L10n.text("前台目标已改变，已停止粘贴。"))}
        guard let source=CGEventSource(stateID:.combinedSessionState),
              let down=CGEvent(keyboardEventSource:source,virtualKey:9,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:9,keyDown:false) else {
            throw DataFailure.message(L10n.text("无法创建系统粘贴事件。"))
        }
        let original=try ClipboardPasteboardSnapshot.capture(board)
        guard original.changeCount == expectedSourceCount,board.changeCount == original.changeCount else {
            throw DataFailure.message(L10n.text("剪贴板已改变，未执行自动粘贴。"))
        }
        // Retain the rich snapshot while restoring the target, but leave the
        // system pasteboard untouched until the exact foreground focus matches.
        let id=UUID()
        pasteTransaction=ClipboardPasteTransaction(id:id,original:original,sendEnterRequested:sendEnter)
        transactionTarget=target
        transactionCompletion=onSubmitted
        do {
            guard target.canActivate(),permitsTargetActivation(target),
                  board.changeCount == original.changeCount else {throw DataFailure.message(L10n.text("临时替换前目标或剪贴板已变化，未发送粘贴。"))}
            // Activation is permitted only while this app or the exact
            // captured process remains foreground. No later retry steals focus.
            guard target.canActivate(),permitsTargetActivation(target) else {
                throw DataFailure.message(L10n.text("前台目标已改变，未发送粘贴。"))
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid,
               !application.activate(options:[]) {throw DataFailure.message(L10n.text("目标应用无法激活，未发送粘贴。"))}
        } catch {
            failBeforeSubmission(id:id,message:error.localizedDescription)
            throw error
        }
        pasteTask=Task { @MainActor [weak self] in
            for _ in 0..<15 {
                guard let self,self.pasteTransaction?.id == id,!Task.isCancelled else {return}
                guard self.pasteTransaction?.permitsTemporaryInstallation(changeCount:board.changeCount,targetMatches:target.canActivate()) == true else {
                    self.failBeforeSubmission(id:id,message:L10n.text("粘贴前权限、输入状态、原目标或剪贴板已改变，未发送。堆栈内容保留。"))
                    return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                    do {
                        // Inactive apps can temporarily expose no focused AX
                        // window. Validate their real focus only after normal
                        // activation, before touching any pasteboard bytes.
                        guard target.isValid(requireFrontmost:true) else {
                            throw DataFailure.message(L10n.text("原目标窗口、输入框或选区已改变，未替换剪贴板或发送粘贴。"))
                        }
                        try ClipboardPasteTransaction.requireUnblocked(self.pasteBlockingReason?())
                        guard self.pasteTransaction?.permitsTemporaryInstallation(changeCount:board.changeCount,targetMatches:target.isValid(requireFrontmost:true)) == true else {
                            throw DataFailure.message(L10n.text("原目标或剪贴板已改变，未替换剪贴板。"))
                        }
                        let cleared=board.clearContents()
                        try self.pasteTransaction?.installedTemporary(changeCount:cleared)
                        self.count=cleared
                        guard board.changeCount == cleared else {throw DataFailure.message(L10n.text("剪贴板已由其他操作改变，未写入临时内容。"))}
                        guard board.writeObjects(objects) else {throw DataFailure.message(L10n.text("无法写入系统剪贴板，未发送自动粘贴。"))}
                        let temporaryCount=board.changeCount
                        self.pasteTransaction?.replaceTemporaryOwnership(changeCount:temporaryCount)
                        self.count=temporaryCount
                        try beforeSubmit?()
                        try ClipboardPasteTransaction.requireUnblocked(self.pasteBlockingReason?())
                        // No client callback or suspension is allowed between
                        // this complete validation and event submission.
                        guard self.pasteTransaction?.id == id,
                              target.isValid(requireFrontmost:true),
                              let current=self.pasteTransaction,
                              current.permitsDispatch(changeCount:board.changeCount,targetMatches:true) else {
                            throw DataFailure.message(L10n.text("最终检查发现目标或剪贴板已改变，未发送粘贴。"))
                        }
                        try self.pasteTransaction?.submitted(changeCount:board.changeCount,targetMatches:true)
                        down.flags = .maskCommand;up.flags = .maskCommand
                        for event in [down,up] {
                            event.setIntegerValueField(.eventSourceUserData,value:EnhancedInputEngine.syntheticTag)
                            event.postToPid(target.pid)
                        }
                        self.pasteTask=nil
                        self.showPasteReview(message:L10n.text("粘贴事件已发送，但系统不能证明目标已读取或插入。请核对原窗口；确认前保留原剪贴板在内存，堆栈尚未弹出。已发送的事件无法撤回。"))
                    } catch {
                        self.failBeforeSubmission(id:id,message:L10n.text("粘贴请求已失效，未发送：")+error.localizedDescription)
                    }
                    return
                }
                guard self.permitsTargetActivation(target) else {
                    self.failBeforeSubmission(id:id,message:L10n.text("前台已切换至其他应用，未发送粘贴，堆栈内容保留。"))
                    return
                }
                do {try await Task.sleep(for:.milliseconds(100))} catch {return}
            }
            self?.failBeforeSubmission(id:id,message:L10n.text("未能确认原目标已位于前台，未发送粘贴，堆栈内容保留。"))
        }
    }

    /// The user has inspected the consumer. Keeping/restoring the clipboard is
    /// a separate explicit choice; neither choice implies OS consumption proof.
    func confirmPendingPaste(restoreOriginal:Bool,sendEnter:Bool=false) throws {
        guard var transaction=pasteTransaction else {throw DataFailure.message(L10n.text("没有待确认的粘贴。"))}
        try transaction.requiresUserReview()
        if transaction.completionWasAttempted && !transaction.completionSucceeded {
            throw DataFailure.message(L10n.text("上次确认的记录提交失败，不会重复执行。请核对堆栈后取消本次确认；原剪贴板仍在内存。"))
        }
        var enterEvents:[CGEvent]=[]
        if sendEnter {
            try ClipboardPasteTransaction.requireUnblocked(pasteBlockingReason?())
            guard transaction.sendEnterRequested,!transaction.enterWasSubmitted,
                  let target=transactionTarget,
                  target.isValid(requireFrontmost:true,checkRange:false,requireEditableText:true),
                  transaction.ownsTemporary(changeCount:NSPasteboard.general.changeCount),
                  let source=CGEventSource(stateID:.combinedSessionState),
                  let down=CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:true),
                  let up=CGEvent(keyboardEventSource:source,virtualKey:36,keyDown:false) else {
                throw DataFailure.message(L10n.text("原窗口、文档、可编辑输入框或剪贴板已改变，未发送回车。请回到原目标后核对，或选择仅确认插入。"))
            }
            enterEvents=[down,up]
        }
        if !transaction.completionWasAttempted {
            try transaction.beginCompletion()
            pasteTransaction=transaction
            do {
                try transactionCompletion?()
                guard pasteTransaction?.id == transaction.id else {throw DataFailure.message(L10n.text("粘贴确认已被其他显式操作结束，不会继续处理旧请求。"))}
                try pasteTransaction?.completed()
            } catch {
                guard pasteTransaction?.id == transaction.id else {throw error}
                showPasteReview(message:L10n.text("你已确认内容插入，但记录提交失败，不会自动重试。请核对堆栈；原剪贴板仍在内存：")+error.localizedDescription)
                reportPasteFailure(L10n.text("内容插入已由你确认，但记录提交失败：")+error.localizedDescription)
                throw error
            }
        }
        if sendEnter {
            // Completion callbacks can mutate local state. Recheck the complete
            // target after them; never activate an app from this confirmation.
            do {try ClipboardPasteTransaction.requireUnblocked(pasteBlockingReason?())}
            catch {
                showPasteReview(message:L10n.text("内容插入已由你确认并记录，但当前模式禁止发送回车：")+error.localizedDescription)
                throw error
            }
            guard let target=transactionTarget,
                  target.isValid(requireFrontmost:true,checkRange:false,requireEditableText:true),
                  pasteTransaction?.id == transaction.id,
                  pasteTransaction?.ownsTemporary(changeCount:NSPasteboard.general.changeCount) == true else {
                showPasteReview(message:L10n.text("内容插入已由你确认并记录，但最终目标检查未通过，未发送回车。可选择仅确认并处理剪贴板。"))
                throw DataFailure.message(L10n.text("最终目标检查未通过，未发送回车。内容插入确认已记录。"))
            }
            try pasteTransaction?.recordEnterSubmission()
            for event in enterEvents {
                event.setIntegerValueField(.eventSourceUserData,value:EnhancedInputEngine.syntheticTag)
                event.postToPid(target.pid)
            }
        }
        do {
            let restored=try restoreOriginal ? restoreOriginalIfOwned() : false
            let changed=restoreOriginal && !restored
            let entered=pasteTransaction?.enterWasSubmitted == true
            clearPasteTransaction()
            let message=entered
                ? (changed ? L10n.text("已按你的确认记录插入并发送回车事件；剪贴板已变化，保留新内容。") : L10n.text("已按你的确认记录插入并发送回车事件。"))
                : (restoreOriginal ? (restored ? L10n.text("已按你的确认记录插入，原剪贴板已恢复。") : L10n.text("已按你的确认记录插入；剪贴板已变化，保留新内容。")) : L10n.text("已按你的确认记录插入，并按选择保留当前剪贴板。"))
            onPasteResult?(message,false)
        } catch {
            showPasteReview(message:L10n.text("内容插入已由你确认并记录，但原剪贴板恢复失败。原内容仍在内存，可再次选择恢复或保留当前内容：")+error.localizedDescription)
            reportPasteFailure(L10n.text("插入确认已记录；原剪贴板恢复失败：")+error.localizedDescription)
            throw error
        }
    }

    /// Cancel only the local lease. Already posted events cannot be retracted;
    /// this never invokes a durable completion callback.
    func cancelPendingPaste(restoreOriginal:Bool=true) throws {
        guard let transaction=pasteTransaction else {throw DataFailure.message(L10n.text("没有待处理的粘贴。"))}
        pasteTask?.cancel();pasteTask=nil
        do {
            let restored=try restoreOriginal ? restoreOriginalIfOwned() : false
            let submitted=transaction.eventWasSubmitted
            let committed=transaction.completionSucceeded
            clearPasteTransaction()
            let message:String
            if transaction.completionWasAttempted && !committed {
                message=L10n.text("已结束确认，未重试失败的记录提交；请核对实际堆栈和原窗口。")+(restored ? L10n.text("原剪贴板已恢复。") : L10n.text("按选择或变化状态保留当前剪贴板。"))
            }
            else if committed {message=restored ? L10n.text("已结束确认并恢复原剪贴板；此前你确认的插入记录已保留。") : L10n.text("已结束确认；剪贴板已变化，保留新内容，此前确认的插入记录已保留。")}
            else if !restoreOriginal {message=submitted ? L10n.text("已按选择取消确认并保留当前剪贴板，未调用堆栈提交。已发送事件无法撤回，请核对原窗口。") : L10n.text("未发送粘贴，已按选择取消并保留当前剪贴板，堆栈内容保留。")}
            else if submitted {message=restored ? L10n.text("已取消本次确认并恢复原剪贴板，未提交堆栈。已发送的粘贴事件无法撤回，请核对原窗口。") : L10n.text("已取消本次确认，未提交堆栈；剪贴板已变化，保留新内容。已发送事件无法撤回。")}
            else {message=restored ? L10n.text("未发送粘贴，已取消并恢复原剪贴板，堆栈内容保留。") : L10n.text("未发送粘贴，已取消；剪贴板新内容和堆栈内容保留。")}
            onPasteResult?(message,false)
        } catch {
            showPasteReview(message:L10n.text("取消时原剪贴板恢复失败；原内容仍在内存，取消不会重试确认记录。请重试恢复或明确选择取消并保留当前剪贴板：")+error.localizedDescription)
            reportPasteFailure(L10n.text("取消时原剪贴板恢复失败：")+error.localizedDescription)
            throw error
        }
    }

    private func permitsTargetActivation(_ target:ClipboardPasteTarget)->Bool {
        guard let front=NSWorkspace.shared.frontmostApplication else {return false}
        return front.processIdentifier == ProcessInfo.processInfo.processIdentifier || front.processIdentifier == target.pid
    }
    private func showPasteReview(message:String) {
        guard let transaction=pasteTransaction else {return}
        pendingPaste=PendingPaste(id:transaction.id,sendEnterRequested:transaction.sendEnterRequested && !transaction.enterWasSubmitted,
                                  message:message,eventWasSubmitted:transaction.eventWasSubmitted)
        onPasteReviewNeeded?()
    }
    private func restoreOriginalIfOwned() throws -> Bool {
        guard let transaction=pasteTransaction,let expected=transaction.temporaryChangeCount else {return false}
        let board=NSPasteboard.general
        let restored=try transaction.original.restore(board,ifUnchanged:expected,onCleared:{ [weak self] cleared in
            guard self?.pasteTransaction?.id == transaction.id else {return}
            self?.pasteTransaction?.replaceTemporaryOwnership(changeCount:cleared)
            self?.count=cleared
        })
        if restored {count=board.changeCount}
        return restored
    }
    private func failBeforeSubmission(id:UUID,message:String) {
        guard pasteTransaction?.id == id,pasteTransaction?.eventWasSubmitted == false else {return}
        pasteTask?.cancel();pasteTask=nil
        pasteTransaction?.failedBeforeSubmission()
        do {
            let restored=try restoreOriginalIfOwned()
            clearPasteTransaction()
            reportPasteFailure(message+(restored ? L10n.text(" 原剪贴板已恢复。") : L10n.text(" 未覆盖剪贴板的新内容。")))
        } catch {
            showPasteReview(message:message+L10n.text(" 原剪贴板恢复失败，原内容仍在内存；请取消并重试恢复。")+error.localizedDescription)
            reportPasteFailure(message+L10n.text(" 原剪贴板恢复失败：")+error.localizedDescription)
        }
    }
    private func clearPasteTransaction() {
        pasteTask?.cancel();pasteTask=nil
        pasteTransaction=nil;transactionTarget=nil;transactionCompletion=nil
        pendingPaste=nil;refreshClipboardActivity()
    }
    private func reportPasteFailure(_ message:String) {error=message;onPasteResult?(message,true)}
    isolated deinit {
        timer?.invalidate(); pasteTask?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}
