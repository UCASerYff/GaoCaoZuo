import AppKit
import ApplicationServices
import SwiftUI

// MARK: - SelectionActionBar

@MainActor
public final class SelectionActionBar: NSObject {
    public static let shared = SelectionActionBar()

    private var panel: NSPanel?
    private var currentSnapshot: SelectionSnapshot?
    private var speechSynthesizer = NSSpeechSynthesizer()
    private var resultMessage: String?

    public override init() {
        super.init()
    }

    public func showBar(snapshot: SelectionSnapshot, at screenPoint: NSPoint? = nil) {
        currentSnapshot = snapshot
        dismiss()

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
                self?.handleAction(action)
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
        p.orderFront(nil)
        self.panel = p
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        currentSnapshot = nil
    }

    private func handleAction(_ action: SelectionBarAction) {
        guard let snapshot = currentSnapshot else { return }
        let text = snapshot.selectedText

        switch action {
        case .search:
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
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
            }

        case .urlEncode:
            applyTransformation(SelectionTransformations.urlEncode(text))

        case .urlDecode:
            applyTransformation(SelectionTransformations.urlDecode(text))

        case .speak:
            if speechSynthesizer.isSpeaking {
                speechSynthesizer.stopSpeaking()
            } else {
                speechSynthesizer.startSpeaking(text)
            }

        case .qrcode:
            showQRCodeWindow(text: text)

        case .saveSnippet:
            NotificationCenter.default.post(name: NSNotification.Name("GaoCaoZuoSaveSnippet"), object: text)
            dismiss()

        case .dismiss:
            dismiss()
        }
    }

    private func applyTransformation(_ newText: String) {
        guard let snapshot = currentSnapshot else { return }

        // Verify if target AX element is still valid and writable
        if let element = snapshot.element,
           AXIsProcessTrusted() {
            var settable: DarwinBoolean = false
            let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            if status == .success && settable.boolValue {
                let writeStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
                if writeStatus == .success {
                    dismiss()
                    return
                }
            }
        }

        // Safe fallback: target cannot be written in place without guessing or blind keystrokes
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(newText, forType: .string)
        dismiss()
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
                Text("\(snapshot.selectedText.count) 字")
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
                Button(action: { showingStats.toggle() }) {
                    Text(L10n.text("文本统计"))
                }
            }
            .font(.caption)
            .padding(.bottom, 8)

            if showingStats {
                let stats = SelectionTransformations.statistics(snapshot.selectedText)
                HStack(spacing: 12) {
                    Text("字符: \(stats.characterCount)")
                    Text("词数: \(stats.wordCount)")
                    Text("中文: \(stats.cjkCharacterCount)")
                    Text("行数: \(stats.lineCount)")
                    Text("字节: \(stats.byteCount)")
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
