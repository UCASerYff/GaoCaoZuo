import AppKit
import QuickLookUI
import Foundation
import Darwin

/// Finder invokes this provider for Space/Quick Look. It only lists metadata, never extracts files.
final class ArchiveQuickLook: NSViewController, QLPreviewingController {
    private let textView = NSTextView()
    override func loadView() {
        NSLog("GaoArchiveQuickLook phase=load-view")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        textView.isEditable = false; textView.isSelectable = true; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20); textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true; scroll.documentView = textView; view = scroll; preferredContentSize = NSSize(width: 760, height: 580)
    }
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let access = url.startAccessingSecurityScopedResource()
        let classBundle=Bundle(for: Self.self)
        let resources:ArchiveQuickLookResources
        do {resources=try ArchiveQuickLookResources.resolve(classBundle:classBundle,mainBundle:Bundle.main)}
        catch {if access {url.stopAccessingSecurityScopedResource()};handler(error);return}
        NSLog("GaoArchiveQuickLook phase=prepare bundle-main=%@ bundle-class=%@",Bundle.main.bundleIdentifier ?? "missing",classBundle.bundleIdentifier ?? "missing")
        let resource=resources.resource,tools=resources.tools
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let decoder = resource.appendingPathComponent("Tools/7zz")
                let extra = ["ace", "lz", "lzip", "lzop", "gz", "gzip", "tgz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "zst", "tzst"].contains(url.pathExtension.lowercased())
                let executable = extra ? tools.appendingPathComponent("ArchivePython/python/bin/python3") : decoder
                let arguments = (extra ? ["-I", "-B", tools.appendingPathComponent("ArchiveBridge/archive_bridge.py").path] : []) + ["l", "-slt", "-ba", "-sccUTF-8", "-bsp0", "--", url.path]
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                // Quick Look may reuse a service after its former working directory
                // disappears. Always launch from an existing, readable bundle path.
                process.currentDirectoryURL=resource
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "en_US.UTF-8"; process.environment = environment
                let exists=FileManager.default.fileExists(atPath:executable.path),canExecute=FileManager.default.isExecutableFile(atPath:executable.path)
                guard exists,canExecute else {
                    NSLog("GaoArchiveQuickLook phase=engine-check bridge=%d exists=%d executable=%d",extra,exists,canExecute)
                    throw NSError(domain:"GaoArchiveQuickLook",code:1,userInfo:[NSLocalizedDescriptionKey:"压缩预览引擎缺失或不可执行，请重新安装完整的搞操作。"])
                }
                do {try process.run()}
                catch {
                    let failure=error as NSError
                    NSLog("GaoArchiveQuickLook phase=engine-launch bridge=%d exists=%d executable=%d error-domain=%@ error-code=%ld",extra,exists,canExecute,failure.domain,failure.code)
                    throw NSError(domain:"GaoArchiveQuickLook",code:2,userInfo:[NSLocalizedDescriptionKey:"无法启动压缩预览引擎（\(failure.domain) \(failure.code)）。请重新安装搞操作后重试。"])
                }
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
                    else {
                        NSLog("GaoArchiveQuickLook phase=engine-result bridge=%d exit=%ld",extra,process.terminationStatus)
                        throw NSError(domain: "GaoArchiveQuickLook", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "压缩预览引擎未能读取此文件（退出码 \(process.terminationStatus)）。请在搞操作中查看详情。"] )
                    }
                } else { text = ArchiveQuickLookDocument.render(filename: url.lastPathComponent, technicalListing: raw) }
                DispatchQueue.main.async { self.textView.string = text; handler(nil) }
            } catch { DispatchQueue.main.async { handler(error) } }
        }
    }
}

struct ArchiveQuickLookResources {
    let resource:URL
    let tools:URL
    static func resolve(classBundle:Bundle,mainBundle:Bundle)throws->Self {
        guard let bundle=[classBundle,mainBundle].first(where:{$0.bundleIdentifier == "com.gaoseries.GaoCaoZuo.QuickLook" && $0.bundleURL.pathExtension == "appex"}),let resource=bundle.resourceURL else {
            NSLog("GaoArchiveQuickLook phase=bundle-check main=%@ class=%@",mainBundle.bundleIdentifier ?? "missing",classBundle.bundleIdentifier ?? "missing")
            throw NSError(domain:"GaoArchiveQuickLook",code:3,userInfo:[NSLocalizedDescriptionKey:"无法定位压缩预览扩展资源，请重新安装完整的搞操作。"])
        }
        let plugins=bundle.bundleURL.deletingLastPathComponent(),contents=plugins.deletingLastPathComponent(),application=contents.deletingLastPathComponent()
        guard plugins.lastPathComponent == "PlugIns",contents.lastPathComponent == "Contents",application.pathExtension == "app",Bundle(url:application)?.bundleIdentifier == "com.gaoseries.GaoCaoZuo" else {
            NSLog("GaoArchiveQuickLook phase=container-check")
            throw NSError(domain:"GaoArchiveQuickLook",code:3,userInfo:[NSLocalizedDescriptionKey:"压缩预览扩展安装位置不完整，请重新安装搞操作。"])
        }
        return Self(resource:resource,tools:contents.appendingPathComponent("Resources/Tools",isDirectory:true))
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
