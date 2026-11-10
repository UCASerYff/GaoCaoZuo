import AppKit
import ImageIO

enum ScreenshotPinnedImageGeometry {
    static func actualPixelScale(backingScale: CGFloat) -> CGFloat {
        backingScale.isFinite && backingScale > 0 ? 1 / backingScale : 1
    }

    /// The interactive canvas may be larger than a tiny image; the image itself is never stretched.
    static func windowSize(pixelSize: CGSize, scale: CGFloat, minimumSide: CGFloat = 24) -> CGSize {
        CGSize(width: max(minimumSide, pixelSize.width * scale), height: max(minimumSide, pixelSize.height * scale))
    }

    static func imageRect(pixelSize: CGSize, scale: CGFloat, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A missing/off-screen saved position must still receive a canvas sized for the restored scale.
    static func restoredFrame(pixelSize: CGSize, scale: CGFloat, savedFrame: CGRect, fallbackFrame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        func usable(_ rect: CGRect) -> Bool {
            rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
        }
        let required = windowSize(pixelSize: pixelSize, scale: scale)
        let screens = visibleFrames.filter(usable)
        if usable(savedFrame), let screen = screens.first(where: { $0.intersects(savedFrame) }) {
            let size = CGSize(width: max(savedFrame.width, required.width), height: max(savedFrame.height, required.height))
            if size == savedFrame.size { return savedFrame }
            return positioned(size: size, near: savedFrame.origin, in: screen)
        }
        let fallback = usable(fallbackFrame) ? fallbackFrame : CGRect(origin: .zero, size: required)
        guard let screen = screens.first(where: { $0.intersects(fallback) }) ?? screens.first else {
            return CGRect(origin: fallback.origin, size: required)
        }
        return positioned(size: required, near: fallback.origin, in: screen)
    }

    private static func positioned(size: CGSize, near origin: CGPoint, in screen: CGRect) -> CGRect {
        let x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width))
        let y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

enum ScreenshotPinnedImageRestorePlan {
    /// Only persistent identities participate. Ordinary user-created copies remain independent.
    static func missing(records: [ScreenshotPinnedImageRecord], activePersistentPaths: [String]) -> [ScreenshotPinnedImageRecord] {
        func identity(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        var seen = Set(activePersistentPaths.map(identity))
        return records.filter { seen.insert(identity($0.imagePath)).inserted }
    }
}

@MainActor
final class ScreenshotPinnedImageController: NSObject {
    private var pins: [UUID: ScreenshotPinnedImageWindow] = [:]
    var count: Int { pins.count }
    var onNotice: ((String) -> Void)?
    /// Configure to this app's validated private data root. No persistence occurs until the user asks.
    var persistenceDirectory: URL?

    @discardableResult
    func show(image: CGImage, onEdit: ((CGImage) -> Void)? = nil, imageURL: URL? = nil) -> UUID {
        let id = UUID()
        let pin = ScreenshotPinnedImageWindow(id: id, image: image, sourceURL: imageURL)
        pin.onEdit = onEdit
        pin.onClose = { [weak self] id in self?.pins.removeValue(forKey: id) }
        pin.onRemember = { [weak self] record in try self?.remember(record) }
        pin.onForget = { [weak self] url in self?.forget(url) }
        pin.onPersist = { [weak self] image in
            guard let self else { throw ScreenshotCaptureFailure.cancelled }
            return try self.savePrivateImage(image)
        }
        pin.onNotice = { [weak self] message in self?.onNotice?(message) }
        pins[id] = pin; pin.showWindow(nil)
        return id
    }

    /// Called only by an explicit user "persistent pin" action. The image and its position are included in app backups.
    @discardableResult
    func persist(image: CGImage, onEdit: ((CGImage) -> Void)? = nil) throws -> UUID {
        let url = try savePrivateImage(image)
        let id = show(image: image, onEdit: onEdit, imageURL: url)
        try pins[id]?.markRemembered(url: url)
        return id
    }

    func closeAll() { Array(pins.values).forEach { $0.close() } }
    /// Required escape route for a pass-through pin: exposed in the app menu/toolbar.
    func makeAllInteractive() { pins.values.forEach { $0.window?.ignoresMouseEvents = false } }
    func close(_ id: UUID) { pins[id]?.close() }

    /// Restore only user-chosen files from this app's explicit list. Missing files are reported, never searched globally.
    func restorePersistentPins(onEdit: ((CGImage) -> Void)? = nil) {
        let records: [ScreenshotPinnedImageRecord]
        do { records = try self.records() } catch { onNotice?(error.localizedDescription); return }
        let missing = ScreenshotPinnedImageRestorePlan.missing(records: records, activePersistentPaths: pins.values.compactMap(\.persistentImagePath))
        for record in missing {
            let url = URL(fileURLWithPath: record.imagePath)
            guard let root = persistenceDirectory, url.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("Pins", isDirectory: true).standardizedFileURL else {
                onNotice?("持久贴图路径不在本App明确保存目录内，已停止该项恢复。"); continue
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                onNotice?("所选持久贴图文件已失效：\(url.lastPathComponent)。请重新选择文件。"); continue
            }
            let id = show(image: image, onEdit: onEdit, imageURL: url)
            pins[id]?.restore(record)
        }
    }

    private func records() throws -> [ScreenshotPinnedImageRecord] {
        guard let root = persistenceDirectory else { throw ScreenshotCaptureFailure.unsupported("尚未配置本App持久贴图资料目录。") }
        return try ScreenshotPinnedImagePersistence.read(root: root)
    }

    private func remember(_ record: ScreenshotPinnedImageRecord) throws {
        var saved = try records()
        saved.removeAll { $0.imagePath == record.imagePath }
        guard saved.count < 50 else { throw ScreenshotCaptureFailure.unsupported("持久贴图已达50张上限，原记录已保留。") }; saved.append(record)
        guard let root = persistenceDirectory else { throw ScreenshotCaptureFailure.unsupported("持久贴图目录不可用。") }
        try ScreenshotPinnedImagePersistence.write(saved, root: root)
    }

    private func forget(_ url: URL) {
        do {
            var saved = try records(); saved.removeAll { $0.imagePath == url.path }
            guard let root = persistenceDirectory else { throw ScreenshotCaptureFailure.unsupported("持久贴图目录不可用。") }
            try ScreenshotPinnedImagePersistence.write(saved, root: root)
        } catch { onNotice?(error.localizedDescription) }
    }

    private func savePrivateImage(_ image: CGImage) throws -> URL {
        // Read first: corrupt/future metadata blocks any new write rather than being treated as empty.
        _ = try records()
        guard let root = persistenceDirectory else { throw ScreenshotCaptureFailure.unsupported("持久贴图目录不可用。") }
        let directory = root.appendingPathComponent("Pins", isDirectory: true)
        try ScreenshotPinnedImagePersistence.ensurePrivateDirectory(directory)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        _ = try ScreenshotCaptureImageExport.write(image, to: url)
        return url
    }
}

struct ScreenshotPinnedImageRecord: Codable {
    let imagePath: String
    let windowFrame: String
    let imageScale: Double
    let opacity: Double
}

enum ScreenshotPinnedImagePersistence {
    private struct Envelope: Codable { let schemaVersion: Int; let records: [ScreenshotPinnedImageRecord] }
    static func read(root: URL) throws -> [ScreenshotPinnedImageRecord] {
        let url = root.appendingPathComponent("PinnedImages.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ScreenshotCaptureFailure.unsupported("持久贴图记录不是普通文件，已停止读写。") }
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        guard data.count <= 1024 * 1024, let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.schemaVersion == 1, envelope.records.count <= 50 else {
            throw ScreenshotCaptureFailure.unsupported("持久贴图记录损坏或版本过新，已停止读写并保留原件。")
        }
        let attachmentRoot = root.appendingPathComponent("Pins", isDirectory: true).standardizedFileURL
        for record in envelope.records {
            let file = URL(fileURLWithPath: record.imagePath).standardizedFileURL
            guard (record.imagePath as NSString).isAbsolutePath,
                  file.deletingLastPathComponent() == attachmentRoot,
                  record.imageScale.isFinite, (0.001...8).contains(record.imageScale),
                  record.opacity.isFinite, (0.15...1).contains(record.opacity) else {
                throw ScreenshotCaptureFailure.unsupported("持久贴图记录含无效参数或越界路径，原记录已保留。")
            }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch { throw ScreenshotCaptureFailure.unsupported("持久贴图附件缺失或无法读取：\(file.lastPathComponent)。原记录已保留，未按空白覆盖。") }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                  FileManager.default.isReadableFile(atPath: file.path) else { throw ScreenshotCaptureFailure.unsupported("持久贴图附件不是可读取的独立普通文件，已停止恢复和写入。") }
        }
        return envelope.records
    }
    static func write(_ records: [ScreenshotPinnedImageRecord], root: URL) throws {
        _ = try read(root: root)
        guard records.count <= 50 else { throw ScreenshotCaptureFailure.budgetExceeded }
        try ensurePrivateDirectory(root)
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, records: records))
        let url = root.appendingPathComponent("PinnedImages.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func ensurePrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw ScreenshotCaptureFailure.unsupported("贴图资料路径不是普通目录，已停止保存。") }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
}

@MainActor
private final class ScreenshotPinnedImageWindow: NSWindowController, NSWindowDelegate {
    let pinID: UUID
    let image: CGImage
    var sourceURL: URL?
    var onEdit: ((CGImage) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRemember: ((ScreenshotPinnedImageRecord) throws -> Void)?
    var onForget: ((URL) -> Void)?
    var onPersist: ((CGImage) throws -> URL)?
    var onNotice: ((String) -> Void)?
    private var imageScale: CGFloat = 1
    private var explicitlyRemembered = false
    fileprivate var persistentImagePath: String? { explicitlyRemembered ? sourceURL?.path : nil }

    fileprivate func imageRect(in bounds: CGRect) -> CGRect {
        ScreenshotPinnedImageGeometry.imageRect(pixelSize: CGSize(width: image.width, height: image.height), scale: imageScale, in: bounds)
    }

    init(id: UUID, image: CGImage, sourceURL: URL?) {
        self.pinID = id; self.image = image; self.sourceURL = sourceURL
        let screenScale = NSScreen.main?.backingScaleFactor ?? 1
        let scale = min(1 / screenScale, 600 / CGFloat(max(image.width, image.height)))
        imageScale = max(0.001, scale)
        let rect = CGRect(origin: CGPoint(x: 80, y: 100), size: ScreenshotPinnedImageGeometry.windowSize(pixelSize: CGSize(width: image.width, height: image.height), scale: imageScale))
        let panel = ScreenshotPinPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "搞操作 · 贴图"; panel.minSize = NSSize(width: 24, height: 24)
        super.init(window: panel)
        panel.delegate = self
        let view = ScreenshotPinImageView(frame: CGRect(origin: .zero, size: rect.size))
        view.pin = self; view.image = image; view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    required init?(coder: NSCoder) { nil }

    func restore(_ record: ScreenshotPinnedImageRecord) {
        guard record.imageScale.isFinite, (0.001...8).contains(record.imageScale), record.opacity.isFinite, (0.15...1).contains(record.opacity) else { return }
        imageScale = record.imageScale; explicitlyRemembered = false
        let frame = ScreenshotPinnedImageGeometry.restoredFrame(pixelSize: CGSize(width: image.width, height: image.height), scale: imageScale,
                                                     savedFrame: NSRectFromString(record.windowFrame), fallbackFrame: window?.frame ?? .zero,
                                                     visibleFrames: NSScreen.screens.map(\.visibleFrame))
        window?.setFrame(frame, display: true)
        window?.alphaValue = record.opacity
        // Pass-through and topmost safety state are not persisted; restored pins always remain operable.
        window?.ignoresMouseEvents = false
        explicitlyRemembered = true
    }

    func markRemembered(url: URL) throws {
        sourceURL = url
        guard let window else { throw ScreenshotCaptureFailure.cancelled }
        try onRemember?(ScreenshotPinnedImageRecord(imagePath: url.path, windowFrame: NSStringFromRect(window.frame), imageScale: imageScale, opacity: window.alphaValue))
        explicitlyRemembered = true
    }

    func windowWillClose(_ notification: Notification) { onClose?(pinID) }
    func windowDidMove(_ notification: Notification) { savePositionIfRemembered() }
    func windowDidResize(_ notification: Notification) { savePositionIfRemembered() }

    func zoom(by factor: CGFloat) {
        guard let window, factor.isFinite, factor > 0 else { return }
        imageScale = min(8, max(0.001, imageScale * factor))
        let size = ScreenshotPinnedImageGeometry.windowSize(pixelSize: CGSize(width: image.width, height: image.height), scale: imageScale)
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        window.setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
        savePositionIfRemembered()
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, tag: Int = 0, state: NSControl.StateValue = .off) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; entry.tag = tag; entry.state = state; menu.addItem(entry)
        }
        item("复制图片", #selector(copyImage)); item("另存图片…", #selector(saveImage)); item("回到标注", #selector(editImage))
        menu.addItem(.separator())
        item("放大", #selector(zoomIn)); item("缩小", #selector(zoomOut)); item("实际像素大小", #selector(actualPixels))
        for percent in [100, 80, 60, 40] { item("透明度 \(percent)%", #selector(changeOpacity(_:)), tag: percent, state: abs((window?.alphaValue ?? 1) - Double(percent) / 100) < 0.01 ? .on : .off) }
        item("窗口置顶", #selector(toggleTopmost), state: window?.level == .floating ? .on : .off)
        item("鼠标穿透（从主界面“贴图恢复交互”退出）", #selector(enablePassThrough))
        menu.addItem(.separator())
        item("持久保存此贴图", #selector(rememberImage))
        if explicitlyRemembered { item("不再恢复此贴图（保留图片文件）", #selector(forgetImage)) }
        item("关闭贴图", #selector(closePin))
        return menu
    }

    @objc func copyImage() {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
    }
    @objc private func saveImage() { save(remember: false) }
    @objc private func rememberImage() { save(remember: true) }
    private func save(remember: Bool) {
        if remember {
            do {
                if explicitlyRemembered { savePositionIfRemembered(); return }
                guard let url = try onPersist?(image) else { throw ScreenshotCaptureFailure.unsupported("持久贴图目录尚未配置。") }
                try markRemembered(url: url); onNotice?("图像与位置已保存在本App私有资料目录，可随完整备份恢复。")
            } catch { onNotice?(error.localizedDescription) }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "贴图-\(pinID.uuidString.prefix(8)).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ScreenshotCaptureImageExport.write(image, to: url)
        } catch { onNotice?(error.localizedDescription) }
    }
    @objc private func forgetImage() { if let sourceURL { onForget?(sourceURL) }; explicitlyRemembered = false }
    @objc private func editImage() { onEdit?(image) }
    @objc private func closePin() { close() }
    @objc private func zoomIn() { zoom(by: 1.2) }
    @objc private func zoomOut() { zoom(by: 1 / 1.2) }
    @objc private func actualPixels() { zoom(by: ScreenshotPinnedImageGeometry.actualPixelScale(backingScale: window?.backingScaleFactor ?? 1) / imageScale) }
    @objc private func toggleTopmost() { window?.level = window?.level == .floating ? .normal : .floating }
    @objc private func enablePassThrough() { window?.ignoresMouseEvents = true; onNotice?("此贴图已开启鼠标穿透；可在主界面选择“贴图恢复交互”。") }
    @objc private func changeOpacity(_ sender: NSMenuItem) { window?.alphaValue = CGFloat(sender.tag) / 100; savePositionIfRemembered() }
    private func savePositionIfRemembered() {
        guard explicitlyRemembered, let sourceURL, let window else { return }
        do { try onRemember?(ScreenshotPinnedImageRecord(imagePath: sourceURL.path, windowFrame: NSStringFromRect(window.frame), imageScale: imageScale, opacity: window.alphaValue)) }
        catch { onNotice?(error.localizedDescription) }
    }
}

private final class ScreenshotPinPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor
private final class ScreenshotPinImageView: NSView {
    weak var pin: ScreenshotPinnedImageWindow?
    var image: CGImage?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.cgContext.clear(bounds)
        NSGraphicsContext.current?.cgContext.draw(image, in: pin?.imageRect(in: bounds) ?? bounds)
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { if let menu = pin?.menu() { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
    override func scrollWheel(with event: NSEvent) { pin?.zoom(by: event.scrollingDeltaY >= 0 ? 1.05 : 1 / 1.05) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pin?.close(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { pin?.copyImage(); return }
        if event.characters == "+" || event.characters == "=" { pin?.zoom(by: 1.2); return }
        if event.characters == "-" { pin?.zoom(by: 1 / 1.2); return }
        super.keyDown(with: event)
    }
}
