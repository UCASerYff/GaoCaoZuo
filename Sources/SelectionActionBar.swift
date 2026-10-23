import AppKit
import ApplicationServices
import SwiftUI
import Carbon

// MARK: - SelectionActionBar

@MainActor
public final class SelectionActionBar: NSObject {
    public static let shared = SelectionActionBar()

    private var panel: NSPanel?
    private var currentSnapshot: SelectionSnapshot?
    private var speechSynthesizer = NSSpeechSynthesizer()
    private var resultMessage: String?
    private var session = UUID()
    private var generation: UInt64 = 0
    private var writebackTask: Task<Void, Never>?
    private var dismissMonitors: [Any] = []
    private var resultWindow: NSWindow?
    public var onTranslate: ((SelectionSnapshot) -> Void)?
    public var onSendToFiles: ((SelectionSnapshot) -> Void)?
    public var onSaveSnippet: ((SelectionSnapshot) -> Void)?
    public var onSaveClipboard: ((SelectionSnapshot) -> Void)?
    public var onStatus: ((String, Bool) -> Void)?

    public override init() {
        super.init()
    }

    public func showBar(snapshot: SelectionSnapshot, at screenPoint: NSPoint? = nil) {
        dismiss()
        generation &+= 1
        currentSnapshot = snapshot.withGeneration(generation)
        let token = session

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.hasShadow = true

        let rootView = SelectionBarContentView(
            snapshot: snapshot,
            onAction: { [weak self] action in
                guard let self, self.session == token else { return }
                self.perform(action)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        p.contentView = NSHostingView(rootView: rootView)

        let targetPoint: NSPoint
        if let pt = screenPoint {
            targetPoint = NSPoint(x: pt.x - 220, y: pt.y - 180)
        } else {
            let mouse = NSEvent.mouseLocation
            targetPoint = NSPoint(x: mouse.x - 220, y: mouse.y + 20)
        }

        p.setFrameOrigin(targetPoint)
        if let frame = NSScreen.screens.first(where: { $0.frame.contains(targetPoint) })?.visibleFrame ?? NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: min(max(p.frame.minX, frame.minX), max(frame.minX, frame.maxX - p.frame.width)),
                                    y: min(max(p.frame.minY, frame.minY), max(frame.minY, frame.maxY - p.frame.height))))
        }
        p.orderFront(nil)
        self.panel = p
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }) { dismissMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }; return event
        }) { dismissMonitors.append(monitor) }
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        currentSnapshot = nil
        writebackTask?.cancel(); writebackTask = nil
        session = UUID()
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }

    /// Supplying a snapshot supports the same registered action from a hotkey.
    /// It never captures another application's selection after the action began.
    public func perform(_ action: SelectionBarAction, snapshot supplied: SelectionSnapshot? = nil) {
        if let supplied { dismiss(); generation &+= 1; currentSnapshot = supplied.withGeneration(generation) }
        guard let snapshot = currentSnapshot else { return }
        guard !IsSecureEventInputEnabled(), Date().timeIntervalSince(snapshot.timestamp) <= 60 else {
            onStatus?("安全输入或选区已过期，请重新选择文字。", true); dismiss(); return
        }
        let text = snapshot.selectedText

        switch action {
        case .search:
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = components?.url {
                NSWorkspace.shared.open(url)
            }
            dismiss()

        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            dismiss()

        case .uppercase:
            applyTransformation(SelectionTransformations.uppercase(text))

        case .lowercase:
            applyTransformation(SelectionTransformations.lowercase(text))

        case .titleCase:
            applyTransformation(SelectionTransformations.titleCase(text))

        case .toHalfWidth:
            applyTransformation(SelectionTransformations.toHalfWidth(text))

        case .toFullWidth:
            applyTransformation(SelectionTransformations.toFullWidth(text))

        case .cleanupWhitespace:
            applyTransformation(SelectionTransformations.cleanupWhitespace(text))

        case .base64Encode:
            applyTransformation(SelectionTransformations.base64Encode(text))

        case .base64Decode:
            if let decoded = SelectionTransformations.base64Decode(text) {
                applyTransformation(decoded)
            } else { onStatus?("选中文字不是有效的 UTF-8 Base64 内容。", true) }

        case .urlEncode:
            applyTransformation(SelectionTransformations.urlEncode(text))

        case .urlDecode:
            applyTransformation(SelectionTransformations.urlDecode(text))

        case .speak:
            if speechSynthesizer.isSpeaking {
                speechSynthesizer.stopSpeaking()
                onStatus?("已请求停止朗读。", false)
            } else if speechSynthesizer.startSpeaking(text) {
                onStatus?("系统已接受朗读请求。", false)
            } else {
                onStatus?("系统未接受朗读请求，无法启动朗读。", true)
            }

        case .qrcode:
            showQRCodeWindow(text: text)

        case .saveSnippet:
            if let onSaveSnippet { onSaveSnippet(snapshot) } else { onStatus?("短语库尚未连接，未保存。", true) }
            dismiss()

        case .translate:
            if let onTranslate { onTranslate(snapshot) } else { onStatus?("翻译提供方不可用。", true) }
            dismiss()

        case .sendToFiles:
            if let onSendToFiles { onSendToFiles(snapshot) } else { onStatus?("搞文件交接入口不可用。", true) }
            dismiss()

        case .saveClipboard:
            if let onSaveClipboard { onSaveClipboard(snapshot) } else { onStatus?("剪贴板历史保存入口不可用。", true) }
            dismiss()

        case .dismiss:
            dismiss()
        }
    }

    private func applyTransformation(_ newText: String) {
        guard let snapshot = currentSnapshot else { return }
        let token = session, expectedGeneration = generation
        writebackTask?.cancel()
        writebackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Only our own action panel may hand focus back to the original
            // audit-token-bound process. A different frontmost user app wins.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               !snapshot.isFromClipboardFallback, let identity = snapshot.launchIdentity,
               WindowProcessIdentity.auditTokenString(for: snapshot.pid) == identity,
               let target = NSRunningApplication(processIdentifier: snapshot.pid), !target.isTerminated {
                _ = target.activate(options: [])
                for _ in 0..<10 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid { break }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard !Task.isCancelled, self.session == token, self.generation == expectedGeneration else { return }
                }
            }
            guard !Task.isCancelled, self.session == token, self.generation == expectedGeneration else { return }
            self.finishTransformation(newText, snapshot: snapshot, generation: expectedGeneration)
        }
    }

    private func finishTransformation(_ newText: String, snapshot: SelectionSnapshot, generation expectedGeneration: UInt64) {
        let evidence = SelectionTargetValidator.evidence(for: snapshot)
        if let reason = SelectionTargetValidator.refusal(snapshot: snapshot, evidence: evidence, generation: expectedGeneration) {
            showCopyableResult(newText, reason: reason); dismiss(); return
        }
        guard let element = snapshot.element else { return }
        // Recheck immediately before the AX mutation. There is no key/paste fallback.
        let latest = SelectionTargetValidator.evidence(for: snapshot)
        if let reason = SelectionTargetValidator.refusal(snapshot: snapshot, evidence: latest, generation: expectedGeneration) {
            showCopyableResult(newText, reason: reason); dismiss(); return
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
        if status == .success { onStatus?("已替换原选区文字。", false) }
        else { showCopyableResult(newText, reason: "系统未允许写回原选区。可自行复制处理结果。") }
        dismiss()
    }

    private func showCopyableResult(_ text: String, reason: String) {
        resultWindow?.close()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("选区处理结果")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(reason)).font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Button(L10n.text("复制结果")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }.padding())
        window.center(); window.orderFront(nil); resultWindow = window
        onStatus?(reason, true)
    }

    private func showQRCodeWindow(text: String) {
        guard let image = SelectionTransformations.generateQRCode(text, size: 240) else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.text("文本二维码")
        win.center()
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        win.contentView = imageView
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SelectionBarAction

public enum SelectionBarAction {
    case search
    case translate
    case sendToFiles
    case saveClipboard
    case copy
    case uppercase
    case lowercase
    case titleCase
    case toHalfWidth
    case toFullWidth
    case cleanupWhitespace
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case speak
    case qrcode
    case saveSnippet
    case dismiss
}

// MARK: - SwiftUI View for SelectionBar

private struct SelectionBarContentView: View {
    let snapshot: SelectionSnapshot
    let onAction: (SelectionBarAction) -> Void
    let onDismiss: () -> Void

    @State private var showingStats = false
    @State private var showingFormats = false

    var body: some View {
        VStack(spacing: 8) {
            // Header: Preview and Character count
            HStack {
                Text(snapshot.selectedText.prefix(40) + (snapshot.selectedText.count > 40 ? "…" : ""))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Text(L10n.format("%@ 字", String(describing: (snapshot.selectedText.count))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()

            // Primary Quick Actions
            HStack(spacing: 12) {
                Button(action: { onAction(.search) }) {
                    Label(L10n.text("搜索"), systemImage: "magnifyingglass")
                }
                Button(action: { onAction(.copy) }) {
                    Label(L10n.text("复制"), systemImage: "doc.on.doc")
                }
                Button(action: { onAction(.translate) }) {
                    Label(L10n.text("翻译"), systemImage: "character.bubble")
                }
                Button(action: { onAction(.speak) }) {
                    Label(L10n.text("朗读"), systemImage: "speaker.wave.2")
                }
                Button(action: { onAction(.qrcode) }) {
                    Label(L10n.text("二维码"), systemImage: "qrcode")
                }
                Button(action: { onAction(.saveSnippet) }) {
                    Label(L10n.text("存为短语"), systemImage: "bookmark")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)

            // Secondary Transformations
            HStack(spacing: 8) {
                Menu(L10n.text("格式转换 ▾")) {
                    Button(L10n.text("转为大写 (UPPERCASE)")) { onAction(.uppercase) }
                    Button(L10n.text("转为小写 (lowercase)")) { onAction(.lowercase) }
                    Button(L10n.text("首字母大写 (Title Case)")) { onAction(.titleCase) }
                    Button(L10n.text("转为半角字符")) { onAction(.toHalfWidth) }
                    Button(L10n.text("转为全角字符")) { onAction(.toFullWidth) }
                    Button(L10n.text("清理多余空白与换行")) { onAction(.cleanupWhitespace) }
                }
                Menu(L10n.text("编解码 ▾")) {
                    Button("Base64 编码") { onAction(.base64Encode) }
                    Button("Base64 解码") { onAction(.base64Decode) }
                    Button("URL 编码") { onAction(.urlEncode) }
                    Button("URL 解码") { onAction(.urlDecode) }
                }
                Menu(L10n.text("发送到…")) {
                    Button(L10n.text("保存到剪贴板历史")) { onAction(.saveClipboard) }
                    Button(L10n.text("交给搞文件")) { onAction(.sendToFiles) }
                }
                Button(action: { showingStats.toggle() }) {
                    Text(L10n.text("文本统计"))
                }
            }
            .font(.caption)
            .padding(.bottom, 8)

            if showingStats {
                let stats = SelectionTransformations.statistics(snapshot.selectedText)
                HStack(spacing: 12) {
                    Text(L10n.format("字符: %@", String(describing: (stats.characterCount))))
                    Text(L10n.format("词数: %@", String(describing: (stats.wordCount))))
                    Text(L10n.format("中文: %@", String(describing: (stats.cjkCharacterCount))))
                    Text(L10n.format("行数: %@", String(describing: (stats.lineCount))))
                    Text(L10n.format("字节: %@", String(describing: (stats.byteCount))))
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
