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

/// The system principal class keeps a stable identity while its native browser
/// implements interactive work entirely inside the sandboxed preview process.
final class ArchiveQuickLook: NativeArchiveBrowserController {}

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
