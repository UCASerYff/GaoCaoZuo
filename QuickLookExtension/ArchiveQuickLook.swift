import AppKit
import QuickLookUI
import Foundation
import Darwin
import OSLog

enum ArchiveQuickLookDiagnostics {
    static let logger=Logger(subsystem:"com.gaoseries.GaoCaoZuo.QuickLook",category:"preview")
    static func isExtension(_ bundle:Bundle)->Bool {bundle.bundleIdentifier == "com.gaoseries.GaoCaoZuo.QuickLook" && bundle.bundleURL.pathExtension == "appex"}
}

/// A preview can outlive its listing task. Keep the original scoped URL alive for
/// the visible preview and for any asynchronous LaunchServices handoff. Each
/// successful acquisition is balanced exactly once when the last owner finishes.
final class ArchiveQuickLookResourceAccess {
    let url: URL
    let isSecurityScoped: Bool
    private let stop: (URL) -> Void
    init(url: URL, start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url; self.stop = stop; isSecurityScoped = start(url)
    }
    deinit { if isSecurityScoped { stop(url) } }
}

enum ArchiveQuickLookHandoff {
    /// Reuse the main app's review-only selection entry point. This URL is not an
    /// authorization token and never requests an archive write or execution.
    static func selectionRequest(for archive: URL) -> URL? {
        guard archive.isFileURL, archive.path.hasPrefix("/"),
              !archive.path.contains("\0"), archive.path.utf8.count <= 16_384,
              let fileComponents = URLComponents(url: archive, resolvingAgainstBaseURL: false),
              fileComponents.query == nil, fileComponents.fragment == nil,
              [nil, "", "localhost"].contains(fileComponents.host?.lowercased()),
              !fileComponents.percentEncodedPath.lowercased().contains("%00"),
              let data = try? JSONEncoder().encode([archive.path]) else { return nil }
        var components = URLComponents()
        components.scheme = "gaocaozuo"; components.host = "perform"
        components.queryItems = [URLQueryItem(name: "payload", value: data.base64EncodedString())]
        return components.url
    }
}

/// Finder invokes this provider for Space/Quick Look. It only lists metadata, never extracts files.
final class ArchiveQuickLook: NSViewController, QLPreviewingController {
    private let textView = NSTextView()
    private var archiveURL: URL?
    private var previewAccess: ArchiveQuickLookResourceAccess?
    private var previewID = UUID()
    private let openButton = NSButton(title: L10n.text("用搞操作打开"), target: nil, action: nil)
    override func loadView() {
        ArchiveQuickLookDiagnostics.logger.notice("phase=load-view")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        textView.isEditable = false; textView.isSelectable = true; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20); textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true; scroll.documentView = textView
        openButton.target = self; openButton.action = #selector(openInMainApp); openButton.bezelStyle = .rounded; openButton.isEnabled = false
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("此处只读目录。按钮仅在搞操作面板中选择此压缩包，请再选择要执行的动作；内容预览、提取和增删由主应用完成。"))
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [explanation, openButton]); footer.orientation = .horizontal; footer.spacing = 12
        let stack = NSStackView(views: [scroll, footer]); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false; footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24), footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)])
        view = stack; preferredContentSize = NSSize(width: 760, height: 580)
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        if previewAccess == nil, let archiveURL { previewAccess = ArchiveQuickLookResourceAccess(url: archiveURL) }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Listing and open completions retain their own reference until finished.
        previewAccess = nil
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        archiveURL = url; openButton.isEnabled = false
        let access = ArchiveQuickLookResourceAccess(url: url)
        previewAccess = access
        let requestID = UUID(); previewID = requestID
        let classBundle=Bundle(for: Self.self)
        let mainIsExtension=ArchiveQuickLookDiagnostics.isExtension(Bundle.main),classIsExtension=ArchiveQuickLookDiagnostics.isExtension(classBundle)
        ArchiveQuickLookDiagnostics.logger.notice("phase=native-prepare main-extension=\(mainIsExtension,privacy:.public) class-extension=\(classIsExtension,privacy:.public) scoped=\(access.isSecurityScoped,privacy:.public)")
        DispatchQueue.global(qos:.userInitiated).async { [access] in
            do {
                let listing=try ArchiveQuickLookNative.list(url:access.url)
                let text=ArchiveQuickLookDocument.render(filename:url.lastPathComponent,technicalListing:listing)
                let bytes=listing.utf8.count
                ArchiveQuickLookDiagnostics.logger.notice("phase=native-result listing-bytes=\(bytes,privacy:.public)")
                DispatchQueue.main.async {if self.previewID == requestID {self.textView.string=text;self.openButton.isEnabled=true};handler(nil)}
            } catch {
                ArchiveQuickLookDiagnostics.logger.error("phase=native-failure")
                let explanation=url.lastPathComponent+"\n\n"+error.localizedDescription
                DispatchQueue.main.async {if self.previewID == requestID {self.textView.string=explanation;self.openButton.isEnabled=true};handler(nil)}
            }
        }
    }
    @objc private func openInMainApp() {
        guard let archiveURL else { return }
        let access = previewAccess ?? ArchiveQuickLookResourceAccess(url: archiveURL)
        let requestID = previewID
        let bundle = Bundle(for: Self.self).bundleURL
        let appURL = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "appex", appURL.pathExtension == "app",
              Bundle(url: appURL)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else {
            textView.string += "\n\n"+L10n.text("主应用位置无法验证，请在 Finder 中选择搞操作打开。"); return
        }
        guard let request = ArchiveQuickLookHandoff.selectionRequest(for: access.url),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: request),
              handler.standardizedFileURL.resolvingSymlinksInPath() == appURL.standardizedFileURL.resolvingSymlinksInPath(),
              Bundle(url: handler)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else {
            ArchiveQuickLookDiagnostics.logger.error("phase=host-open-handler-verified accepted=false")
            textView.string += "\n\n"+L10n.text("主应用位置无法验证，请在 Finder 中选择搞操作打开。"); return
        }
        guard let context = extensionContext else {
            ArchiveQuickLookDiagnostics.logger.error("phase=host-open-context-available accepted=false")
            textView.string += "\n\n"+L10n.text("无法打开主应用；目录预览仍可使用。")+"\n"+L10n.text("请关闭预览，在 Finder 中选择“打开方式”→“搞操作”。"); return
        }
        openButton.isEnabled = false
        // A Quick Look extension can run in a system persona/session that cannot
        // launch an app directly. Ask the host through the public extension API.
        // Each extension point decides whether this request is supported.
        context.open(request) { [weak self, access] accepted in
            withExtendedLifetime(access) {
                ArchiveQuickLookDiagnostics.logger.notice("phase=host-open-result accepted=\(accepted,privacy:.public)")
                DispatchQueue.main.async {
                    guard let self, self.previewID == requestID else { return }
                    self.openButton.isEnabled = true
                    if !accepted {self.textView.string += "\n\n"+L10n.text("无法打开主应用；目录预览仍可使用。")+"\n"+L10n.text("请关闭预览，在 Finder 中选择“打开方式”→“搞操作”。")}
                }
            }
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
