import AppKit
import QuickLookUI
import Foundation
import Darwin

/// Finder invokes this provider for Space/Quick Look. It only lists metadata, never extracts files.
final class ArchiveQuickLook: NSViewController, QLPreviewingController {
    private let textView = NSTextView()
    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        textView.isEditable = false; textView.isSelectable = true; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20); textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true; scroll.documentView = textView; view = scroll; preferredContentSize = NSSize(width: 760, height: 580)
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let access = url.startAccessingSecurityScopedResource()
        let resource = Bundle(for: Self.self).resourceURL!
        // Keep one shared decoder distribution in the containing app.
        let application = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let tools = application.appendingPathComponent("Resources/Tools", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let decoder = resource.appendingPathComponent("Tools/7zz")
                let extra = ["ace", "lz", "lzip", "lzop", "gz", "gzip", "tgz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "zst", "tzst"].contains(url.pathExtension.lowercased())
                let executable = extra ? tools.appendingPathComponent("ArchivePython/python/bin/python3") : decoder
                let arguments = (extra ? ["-I", "-B", tools.appendingPathComponent("ArchiveBridge/archive_bridge.py").path] : []) + ["l", "-slt", "-ba", "-sccUTF-8", "-bsp0", "--", url.path]
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "en_US.UTF-8"; process.environment = environment
                try process.run()
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 12); timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }; timer.resume()
                defer { timer.cancel() }
                var data = Data(), exceeded = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    if data.count + chunk.count > 4 * 1_024 * 1_024 { exceeded = true; if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                    data.append(chunk.prefix(max(0, 4 * 1_024 * 1_024 - data.count)))
                }
                process.waitUntilExit()
                let raw = String(decoding: data, as: UTF8.self)
                let text: String
                if process.terminationStatus != 0 {
                    if raw.lowercased().contains("password") || raw.lowercased().contains("encrypted") {
                        text = url.lastPathComponent + "\n\n此压缩包已加密。请用搞操作打开并输入密码。"
                    } else if exceeded { text = url.lastPathComponent + "\n\n压缩包目录超出空格预览预算，请用搞操作打开。" }
                    else { throw NSError(domain: "GaoArchiveQuickLook", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "无法预览此格式或压缩包已损坏。请在搞操作中查看详情。"] ) }
                } else { text = ArchiveQuickLookDocument.render(filename: url.lastPathComponent, technicalListing: raw) }
                DispatchQueue.main.async { self.textView.string = text; handler(nil) }
            } catch { DispatchQueue.main.async { handler(error) } }
        }
    }
}

enum ArchiveQuickLookDocument {
    static func render(filename: String, technicalListing: String) -> String {
        var rows: [String] = [], fields: [String: String] = [:], total: UInt64 = 0, count = 0
        func flush() {
            guard let path = fields["Path"], let size = UInt64(fields["Size"] ?? ""), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { fields = [:]; return }
            defer { fields = [:] }
            count += 1; total = total > UInt64.max - size ? UInt64.max : total + size
            guard rows.count < 4_000 else { return }
            let folder = fields["Folder"] == "+" || (fields["Attributes"] ?? "").hasPrefix("D")
            let indent = String(repeating: "  ", count: min(40, path.split(separator: "/").count - 1))
            let name = path.split(separator: "/").last.map(String.init) ?? path
            rows.append(indent + (folder ? "▸ " : "  ") + name + (folder ? "/" : "    " + ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)))
        }
        for line in technicalListing.components(separatedBy: .newlines) {
            if line.isEmpty { flush(); continue }
            if let range = line.range(of: " = ") { fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...]) }
        }
        flush()
        return filename + "\n" + "\(count) 项 · 展开约 " + ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file) + "\n\n" + rows.joined(separator: "\n") + (count > rows.count ? "\n\n仅显示前 4000 项，完整目录请用搞操作打开。" : "")
    }
}
