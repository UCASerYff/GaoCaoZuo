import AppKit
import QuickLookUI
import Foundation
import Darwin
import OSLog

enum ArchiveQuickLookDiagnostics {
    static let logger=Logger(subsystem:"com.gaoseries.GaoCaoZuo.QuickLook",category:"preview")
    static func isExtension(_ bundle:Bundle)->Bool {bundle.bundleIdentifier == "com.gaoseries.GaoCaoZuo.QuickLook" && bundle.bundleURL.pathExtension == "appex"}
}

/// Finder invokes this provider for Space/Quick Look. It only lists metadata, never extracts files.
final class ArchiveQuickLook: NSViewController, QLPreviewingController {
    private let textView = NSTextView()
    private var archiveURL: URL?
    private let openButton = NSButton(title: L10n.text("用搞操作打开"), target: nil, action: nil)
    override func loadView() {
        ArchiveQuickLookDiagnostics.logger.notice("phase=load-view")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        textView.isEditable = false; textView.isSelectable = true; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20); textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true; scroll.documentView = textView
        openButton.target = self; openButton.action = #selector(openInMainApp); openButton.bezelStyle = .rounded; openButton.isEnabled = false
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("此处只读目录。包内内容预览、选取、提取和增删在搞操作主应用完成；打开后采用你的压缩包打开设置。"))
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [explanation, openButton]); footer.orientation = .horizontal; footer.spacing = 12
        let stack = NSStackView(views: [scroll, footer]); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false; footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24), footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)])
        view = stack; preferredContentSize = NSSize(width: 760, height: 580)
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        archiveURL = url; openButton.isEnabled = false
        let access = url.startAccessingSecurityScopedResource()
        let classBundle=Bundle(for: Self.self)
        let mainIsExtension=ArchiveQuickLookDiagnostics.isExtension(Bundle.main),classIsExtension=ArchiveQuickLookDiagnostics.isExtension(classBundle)
        ArchiveQuickLookDiagnostics.logger.notice("phase=native-prepare main-extension=\(mainIsExtension,privacy:.public) class-extension=\(classIsExtension,privacy:.public) scoped=\(access,privacy:.public)")
        DispatchQueue.global(qos:.userInitiated).async {
            defer {if access {url.stopAccessingSecurityScopedResource()}}
            do {
                let listing=try ArchiveQuickLookNative.list(url:url)
                let text=ArchiveQuickLookDocument.render(filename:url.lastPathComponent,technicalListing:listing)
                let bytes=listing.utf8.count
                ArchiveQuickLookDiagnostics.logger.notice("phase=native-result listing-bytes=\(bytes,privacy:.public)")
                DispatchQueue.main.async {self.textView.string=text;self.openButton.isEnabled=true;handler(nil)}
            } catch {
                ArchiveQuickLookDiagnostics.logger.error("phase=native-failure")
                let explanation=url.lastPathComponent+"\n\n"+error.localizedDescription
                DispatchQueue.main.async {self.textView.string=explanation;self.openButton.isEnabled=true;handler(nil)}
            }
        }
    }
    @objc private func openInMainApp() {
        guard let archiveURL else { return }
        let bundle = Bundle(for: Self.self).bundleURL
        let appURL = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "appex", appURL.pathExtension == "app",
              Bundle(url: appURL)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else {
            textView.string += "\n\n"+L10n.text("主应用位置无法验证，请在 Finder 中选择搞操作打开。"); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([archiveURL], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
            if error != nil { DispatchQueue.main.async { self?.textView.string += "\n\n"+L10n.text("无法打开主应用；目录预览仍可使用。") } }
        }
    }
}

enum ArchiveQuickLookDocument {
    static func render(filename: String, technicalListing: String) -> String {
        var rows: [String] = [], fields: [String: String] = [:], total: UInt64 = 0, count = 0
        var warnings:[String]=[],unknownSize=false
        func flush() {
            guard let path = fields["Path"], let size = UInt64(fields["Size"] ?? ""), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { fields = [:]; return }
            defer { fields = [:] }
            count += 1; total = total > UInt64.max - size ? UInt64.max : total + size
            let unknown=fields["SizeUnknown"] == "+";unknownSize = unknownSize || unknown
            guard rows.count < 4_000 else { return }
            let folder = fields["Folder"] == "+" || (fields["Attributes"] ?? "").hasPrefix("D")
            let indent = String(repeating: "  ", count: max(0,min(40, path.split(separator: "/").count - 1)))
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let lock=fields["Encrypted"] == "+" ? " 🔒" : ""
            rows.append(indent + (folder ? "▸ " : "  ") + name + lock + (folder ? "/" : "    " + (unknown ? L10n.text("大小未知") : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))))
        }
        for line in technicalListing.components(separatedBy: .newlines) {
            if line.hasPrefix("PreviewWarning = ") {warnings.append(String(line.dropFirst("PreviewWarning = ".count)));continue}
            if line.isEmpty { flush(); continue }
            if let range = line.range(of: " = ") { fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...]) }
        }
        flush()
        return filename + "\n" + (warnings.isEmpty ? L10n.format("%ld 项 ·",count)+" " : L10n.format("已列出 %ld 项 ·",count)+" ") + (unknownSize ? L10n.text("部分大小未知") : L10n.format("展开约 %@",ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))) + "\n\n" + rows.joined(separator: "\n") + (count > rows.count ? "\n\n"+L10n.text("仅显示前 4000 项，完整目录请用搞操作打开。") : "") + (warnings.isEmpty ? "" : "\n\n"+warnings.joined(separator:"\n"))
    }
}
