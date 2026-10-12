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
    override func loadView() {
        ArchiveQuickLookDiagnostics.logger.notice("phase=load-view")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        textView.isEditable = false; textView.isSelectable = true; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20); textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true; scroll.documentView = textView; view = scroll; preferredContentSize = NSSize(width: 760, height: 580)
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
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
                DispatchQueue.main.async {self.textView.string=text;handler(nil)}
            } catch {
                ArchiveQuickLookDiagnostics.logger.error("phase=native-failure")
                let explanation=url.lastPathComponent+"\n\n"+error.localizedDescription
                DispatchQueue.main.async {self.textView.string=explanation;handler(nil)}
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
            rows.append(indent + (folder ? "▸ " : "  ") + name + lock + (folder ? "/" : "    " + (unknown ? "大小未知" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))))
        }
        for line in technicalListing.components(separatedBy: .newlines) {
            if line.hasPrefix("PreviewWarning = ") {warnings.append(String(line.dropFirst("PreviewWarning = ".count)));continue}
            if line.isEmpty { flush(); continue }
            if let range = line.range(of: " = ") { fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...]) }
        }
        flush()
        return filename + "\n" + (warnings.isEmpty ? "\(count) 项 · " : "已列出 \(count) 项 · ") + (unknownSize ? "部分大小未知" : "展开约 " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)) + "\n\n" + rows.joined(separator: "\n") + (count > rows.count ? "\n\n仅显示前 4000 项，完整目录请用搞操作打开。" : "") + (warnings.isEmpty ? "" : "\n\n"+warnings.joined(separator:"\n"))
    }
}
