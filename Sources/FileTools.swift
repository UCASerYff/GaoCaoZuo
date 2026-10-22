import Foundation
import AppKit
import CryptoKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Darwin

enum FileToolsError: LocalizedError {
    case invalid(String)
    case conflict(URL)
    case changed(URL)
    case unsupported(URL)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return L10n.text(message)
        case .conflict(let url): return L10n.format("已存在同名项目，未覆盖：%@",url.path)
        case .changed(let url): return L10n.format("文件已发生变化，为保护资料无法恢复：%@",url.path)
        case .unsupported(let url): return L10n.format("暂不处理符号链接、特殊文件或无法读取的项目：%@",url.path)
        }
    }
}

struct FileOperationReceipt: Codable, Identifiable {
    enum Kind: String, Codable { case create, copy, move, rename, convert }
    var id: UUID
    var date: Date
    var kind: Kind
    var source: URL?
    var destination: URL
    var fingerprint: String

    init(kind: Kind, source: URL? = nil, destination: URL, fingerprint: String) {
        self.id = UUID(); self.date = Date(); self.kind = kind
        self.source = source; self.destination = destination; self.fingerprint = fingerprint
    }
}

/// A failed operation may leave verified originals/results intact when automatic rollback is unsafe.
/// The caller can retain these receipts in recovery history; it must not report complete success.
struct FileToolsPartialFailure: LocalizedError {
    let underlyingMessage: String
    let receipts: [FileOperationReceipt]
    var errorDescription: String? {
        L10n.format("操作未完成，部分项目无法安全自动恢复，资料已保留。%@\n", String(describing: (underlyingMessage))) +
        receipts.map { $0.destination.path }.joined(separator: "\n")
    }
}

struct RenamePlan: Codable, Identifiable {
    var id: UUID
    var source: URL
    var destination: URL
    init(source: URL, destination: URL) {
        self.id = UUID(); self.source = source; self.destination = destination
    }
}

/// Files are never overwritten. Receipts are content fingerprints, not promises that a file still exists.
enum FileTools {
    private static let fm = FileManager.default

    static func createFile(in directory: URL, name: String, content: String) throws -> URL {
        try validateDirectory(directory)
        try validateName(name)
        let result = directory.appendingPathComponent(name)
        try absent(result)
        // .withoutOverwriting also protects against a file appearing after our preflight.
        try Data(content.utf8).write(to: result, options: .withoutOverwriting)
        return result
    }

    static func copy(items: [URL], to directory: URL, move: Bool) throws -> [FileOperationReceipt] {
        try validateDirectory(directory)
        guard !items.isEmpty else { throw FileToolsError.invalid("请先选择文件。") }
        let destinations = items.map { directory.appendingPathComponent($0.lastPathComponent) }
        try validateDistinct(destinations)
        var fingerprints: [String] = []
        for (source, destination) in zip(items, destinations) {
            try absent(destination)
            let src = source.resolvingSymlinksInPath().standardizedFileURL.path
            let dst = destination.resolvingSymlinksInPath().standardizedFileURL.path
            guard src != dst, !dst.hasPrefix(src + "/") else {
                throw FileToolsError.invalid("不能把文件夹复制或移动到自身内部。")
            }
            fingerprints.append(try fingerprint(source))
        }
        var completed: [FileOperationReceipt] = []
        // Copies are not exposed in the destination until the entire batch verifies successfully.
        let stage = move ? nil : directory.appendingPathComponent(".gaocaozuo-copy-\(UUID().uuidString)")
        if let stage { try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        defer { if let stage { try? fm.removeItem(at: stage) } }
        do {
            if let stage {
                for (index, source) in items.enumerated() {
                    let staged = stage.appendingPathComponent(source.lastPathComponent)
                    try fm.copyItem(at: source, to: staged)
                    guard try fingerprint(staged) == fingerprints[index] else { throw FileToolsError.changed(source) }
                }
                for destination in destinations { try absent(destination) }
            }
            for (index, source) in items.enumerated() {
                let destination = destinations[index]
                if move { try fm.moveItem(at: source, to: destination) }
                else { try fm.moveItem(at: stage!.appendingPathComponent(source.lastPathComponent), to: destination) }
                // Record the expected state immediately: even failed post-move verification now has a recovery record.
                completed.append(.init(kind: move ? .move : .copy, source: source, destination: destination, fingerprint: fingerprints[index]))
                guard try fingerprint(destination) == fingerprints[index] else { throw FileToolsError.changed(destination) }
            }
            return completed
        } catch {
            let residual = rollbackIndividually(completed)
            if !residual.isEmpty { throw FileToolsPartialFailure(underlyingMessage: error.localizedDescription, receipts: residual) }
            throw error
        }
    }

    /// Template variables: {name}, {ext}, {n}, {n:03}. Explicit dots remain literal.
    static func renamePreview(items: [URL], pattern: String, start: Int) throws -> [RenamePlan] {
        guard !items.isEmpty else { throw FileToolsError.invalid("请先选择文件。") }
        guard start >= 0, start <= Int.max - items.count else { throw FileToolsError.invalid("起始序号无效。") }
        let numberPattern = try NSRegularExpression(pattern: #"\{n:(0?)([1-9][0-9]?)\}"#)
        var plans: [RenamePlan] = []
        for (index, source) in items.enumerated() {
            _ = try fingerprint(source)
            let n = start + index
            var name = pattern.replacingOccurrences(of: "{name}", with: source.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{ext}", with: source.pathExtension)
                .replacingOccurrences(of: "{n}", with: String(n))
            let matches = numberPattern.matches(in: name, range: NSRange(name.startIndex..., in: name))
            for match in matches.reversed() {
                guard let widthRange = Range(match.range(at: 2), in: name), let fullRange = Range(match.range, in: name), let width = Int(name[widthRange]), width <= 20 else {
                    throw FileToolsError.invalid("序号补零宽度须在 1–20 之间。")
                }
                let value = String(n)
                name.replaceSubrange(fullRange, with: String(repeating: "0", count: max(0, width - value.count)) + value)
            }
            // An extensionless source should not gain an accidental trailing dot.
            if source.pathExtension.isEmpty, pattern.hasSuffix(".{ext}"), name.hasSuffix(".") { name.removeLast() }
            try validateName(name)
            let destination = source.deletingLastPathComponent().appendingPathComponent(name)
            if destination.standardizedFileURL != source.standardizedFileURL { try absent(destination) }
            plans.append(.init(source: source, destination: destination))
        }
        try validateDistinct(plans.map(\.destination))
        return plans
    }

    static func applyRenames(_ plans: [RenamePlan]) throws -> [FileOperationReceipt] {
        try validateDistinct(plans.map(\.source))
        try validateDistinct(plans.map(\.destination))
        var fingerprints: [UUID: String] = [:]
        for plan in plans where plan.source.standardizedFileURL != plan.destination.standardizedFileURL {
            guard plan.source.deletingLastPathComponent().standardizedFileURL == plan.destination.deletingLastPathComponent().standardizedFileURL else {
                throw FileToolsError.invalid("批量改名不能更换文件所在目录。")
            }
            try validateName(plan.destination.lastPathComponent)
            try absent(plan.destination)
            fingerprints[plan.id] = try fingerprint(plan.source)
        }
        var receipts: [FileOperationReceipt] = []
        do {
            for plan in plans {
                guard let digest = fingerprints[plan.id] else { continue }
                try fm.moveItem(at: plan.source, to: plan.destination)
                receipts.append(.init(kind: .rename, source: plan.source, destination: plan.destination, fingerprint: digest))
            }
            return receipts
        } catch {
            let residual = rollbackIndividually(receipts)
            if !residual.isEmpty { throw FileToolsPartialFailure(underlyingMessage: error.localizedDescription, receipts: residual) }
            throw error
        }
    }

    /// User recovery sends created/copied outputs to Trash. Only verified internal rollback uses false.
    static func undo(_ receipts: [FileOperationReceipt], trashCreated: Bool = true) throws {
        // Preflight the entire batch before touching anything.
        try validateDistinct(receipts.map(\.destination))
        var pending: [FileOperationReceipt] = []
        for receipt in receipts {
            if try isMissing(receipt.destination) {
                if receipt.kind == .move || receipt.kind == .rename {
                    guard let source = receipt.source, try receiptFingerprint(source, expected:receipt.fingerprint) == receipt.fingerprint else { throw FileToolsError.changed(receipt.source ?? receipt.destination) }
                }
                // A previous interrupted attempt already restored/moved this item. Continue the remaining batch.
                continue
            }
            guard try receiptFingerprint(receipt.destination, expected:receipt.fingerprint) == receipt.fingerprint else { throw FileToolsError.changed(receipt.destination) }
            if receipt.kind == .move || receipt.kind == .rename {
                guard let source = receipt.source else { throw FileToolsError.invalid("恢复记录缺少原始路径。") }
                try absent(source)
            }
            pending.append(receipt)
        }
        var restored = 0
        do {
            for receipt in pending.reversed() {
                // Recheck immediately before mutation in case a different process has edited the file.
                guard try receiptFingerprint(receipt.destination, expected:receipt.fingerprint) == receipt.fingerprint else { throw FileToolsError.changed(receipt.destination) }
                if receipt.kind == .move || receipt.kind == .rename, let source = receipt.source {
                    try fm.moveItem(at: receipt.destination, to: source)
                    guard try receiptFingerprint(source, expected:receipt.fingerprint) == receipt.fingerprint else { throw FileToolsError.changed(source) }
                } else if trashCreated {
                    try fm.trashItem(at: receipt.destination, resultingItemURL: nil)
                } else { try fm.removeItem(at: receipt.destination) }
                restored += 1
            }
        } catch {
            throw FileToolsError.invalid("恢复中断：本次已完成 \(restored)/\(pending.count) 项；请保留恢复记录，可重试其余项目。\(error.localizedDescription)")
        }
    }

    static func convertImages(items: [URL], to directory: URL, format: String, maxDimension: Int?) throws -> [URL] {
        try validateDirectory(directory)
        guard !items.isEmpty else { throw FileToolsError.invalid("请先选择图片。") }
        let type: UTType
        switch format.lowercased() {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "heic": type = .heic
        case "tiff", "tif": type = .tiff
        default: throw FileToolsError.invalid("支持的图片格式：PNG、JPEG、HEIC、TIFF。")
        }
        if let dimension = maxDimension, !(1...32768).contains(dimension) { throw FileToolsError.invalid("最长边须在 1–32768 像素之间。") }
        let ext = type.preferredFilenameExtension ?? format.lowercased()
        let outputs = items.map { directory.appendingPathComponent($0.deletingPathExtension().lastPathComponent).appendingPathExtension(ext) }
        try validateDistinct(outputs)
        for url in outputs { try absent(url) }
        let stage = directory.appendingPathComponent(".gaocaozuo-images-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        var committed: [FileOperationReceipt] = []
        do {
            for (sourceURL, outputURL) in zip(items, outputs) {
                try validateRegularFile(sourceURL)
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), CGImageSourceGetCount(source) == 1 else {
                    throw FileToolsError.invalid("不支持此图片或包含多帧/多页，请先导出单张图片：\(sourceURL.lastPathComponent)")
                }
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else {
                    throw FileToolsError.invalid("图片超过 1 亿像素预算或无法读取尺寸。")
                }
                let dimension = min(maxDimension ?? max(width, height), max(width, height))
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
                    kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw FileToolsError.invalid("无法解码图片：\(sourceURL.lastPathComponent)")
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                    throw FileToolsError.invalid("当前系统无法编码 \(format)。")
                }
                // Strip GPS and other source metadata; output orientation is already applied above.
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw FileToolsError.invalid("图片编码失败。") }
                try (data as Data).write(to: stage.appendingPathComponent(outputURL.lastPathComponent), options: .withoutOverwriting)
            }
            // The complete batch is encoded before any visible output is committed.
            for outputURL in outputs { try absent(outputURL) }
            for outputURL in outputs {
                let stagedURL = stage.appendingPathComponent(outputURL.lastPathComponent)
                let digest = try fingerprint(stagedURL)
                try fm.moveItem(at: stagedURL, to: outputURL)
                committed.append(.init(kind: .convert, destination: outputURL, fingerprint: digest))
            }
            return outputs
        } catch {
            let residual = rollbackIndividually(committed)
            if !residual.isEmpty { throw FileToolsPartialFailure(underlyingMessage: error.localizedDescription, receipts: residual) }
            throw error
        }
    }

    static func sha256(_ url: URL) throws -> String {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func qrCode(text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 2000 else { throw FileToolsError.invalid("二维码内容须为 1–2000 字节。") }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw FileToolsError.invalid("二维码生成器不可用。") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = filter.outputImage else { throw FileToolsError.invalid("内容超出二维码容量。") }
        // A four-module quiet zone is required for reliable scanning.
        let rect = qr.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: rect)
        let padded = qr.composited(over: white).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(padded, from: padded.extent) else { throw FileToolsError.invalid("二维码渲染失败。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw FileToolsError.invalid("PNG 编码器不可用。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FileToolsError.invalid("PNG 编码失败。") }
        return data as Data
    }

    /// Fingerprint includes all relative paths, file contents, and POSIX modes. Links and special files are rejected.
    static func fingerprint(_ url: URL) throws -> String {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else { throw FileToolsError.unsupported(url) }
        if type == .typeRegular { return "file:\(try sha256(url)):\(attributes[.posixPermissions] ?? 0)" }
        guard type == .typeDirectory else { throw FileToolsError.unsupported(url) }
        let canonicalRoot = try canonicalURL(url)
        var entries:[URL]=[]
        func walk(_ directory:URL) throws {
            for child in try directoryChildren(directory) {
                let type=try fm.attributesOfItem(atPath:child.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else {throw FileToolsError.unsupported(child)}
                entries.append(child)
                guard entries.count<=100_000 else {throw FileToolsError.invalid("目录超过 10 万个项目的操作预算。")}
                if type == .typeDirectory {try walk(child)}
            }
        }
        try walk(canonicalRoot)
        var hash = SHA256()
        hash.update(data: Data("directory:\(attributes[.posixPermissions] ?? 0)\n".utf8))
        for child in entries.sorted(by: { $0.path < $1.path }) {
            let a = try fm.attributesOfItem(atPath: child.path)
            let relative = String(child.path.dropFirst(canonicalRoot.path.count))
            let type = a[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { throw FileToolsError.unsupported(child) }
            let content = type == .typeRegular ? try sha256(child) : "directory"
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(content):\(a[.posixPermissions] ?? 0)\n".utf8))
        }
        return "directory:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// POSIX enumeration includes AppleDouble records Foundation may hide automatically.
    static func directoryChildren(_ directory:URL) throws -> [URL] {
        guard let stream=opendir(directory.path) else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{closedir(stream)}
        var urls:[URL]=[]
        while true {
            errno=0
            guard let entry=readdir(stream) else {if errno != 0 {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))};break}
            let count=Int(entry.pointee.d_namlen)
            guard let name=withUnsafeBytes(of:entry.pointee.d_name,{String(bytes:$0.prefix(count),encoding:.utf8)}) else {throw FileToolsError.invalid("目录包含无法无损表示的文件名，已停止操作。")}
            if name == "." || name == ".." {continue}
            urls.append(directory.appendingPathComponent(name))
            guard urls.count<=100_000 else {throw FileToolsError.invalid("单个目录超过 10 万项预算。")}
        }
        return urls
    }

    /// Archive receipts may contain internal symbolic links. Ordinary file operations keep rejecting links.
    static func archiveFingerprint(_ root: URL) throws -> String {
        let a = try fm.attributesOfItem(atPath:root.path)
        if a[.type] as? FileAttributeType == .typeRegular {return try fingerprint(root)}
        guard a[.type] as? FileAttributeType == .typeDirectory else { throw FileToolsError.unsupported(root) }
        let base = try canonicalURL(root)
        var entries: [(String,URL,FileAttributeType,UInt32)] = []
        func walk(_ directory:URL) throws {
            for child in try directoryChildren(directory).sorted(by:{$0.lastPathComponent < $1.lastPathComponent}) {
                let attrs=try fm.attributesOfItem(atPath:child.path)
                guard let type=attrs[.type] as? FileAttributeType,[.typeRegular,.typeDirectory,.typeSymbolicLink].contains(type) else {throw FileToolsError.unsupported(child)}
                let relative=String(child.path.dropFirst(base.path.count+1))
                entries.append((relative,child,type,(attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0))
                guard entries.count<=100_000 else {throw FileToolsError.invalid("压缩目录超过 10 万项预算。")}
                if type == .typeDirectory {try walk(child)}
            }
        }
        try walk(base)
        if !entries.contains(where:{$0.2 == .typeSymbolicLink}) {return try fingerprint(root)}
        let kinds=Dictionary(uniqueKeysWithValues:entries.map{($0.0,$0.2)})
        func checkLink(_ relative:String) throws -> String {
            let value=try fm.destinationOfSymbolicLink(atPath:base.appendingPathComponent(relative).path)
            guard !value.isEmpty,!value.hasPrefix("/"),!value.contains("\0") else {throw FileToolsError.invalid("压缩目录包含危险链接。")}
            var parts=Array(relative.split(separator:"/").dropLast()).map(String.init)
            for piece in value.split(separator:"/",omittingEmptySubsequences:true).map(String.init) {
                if piece == "." {continue}
                if piece == ".." {guard !parts.isEmpty else {throw FileToolsError.invalid("链接越出解压目录。")};parts.removeLast()}
                else {parts.append(piece)}
            }
            guard !parts.isEmpty else {throw FileToolsError.invalid("链接指向目录根，可能产生循环。")}
            // Reject link chains and symlink ancestors. This also rejects cycles without following links.
            for n in 1...parts.count {if kinds[parts.prefix(n).joined(separator:"/")] == .typeSymbolicLink {throw FileToolsError.invalid("压缩目录不允许链接链或循环。")}}
            guard kinds[parts.joined(separator:"/")] != nil else {throw FileToolsError.invalid("压缩目录包含悬空链接。")}
            return value
        }
        var hash=SHA256()
        hash.update(data:Data("root:\(a[.posixPermissions] ?? 0)\n".utf8))
        for (relative,url,type,mode) in entries.sorted(by:{$0.0<$1.0}) {
            let content:String
            if type == .typeSymbolicLink {content="link:"+(try checkLink(relative))}
            else if type == .typeDirectory {content="directory"}
            else {
                let fd=open(url.path,O_RDONLY|O_NOFOLLOW)
                guard fd>=0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
                let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
                defer{try? handle.close()}
                var info=stat();guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG else {throw FileToolsError.unsupported(url)}
                var digest=SHA256()
                while let bytes=try handle.read(upToCount:1_048_576),!bytes.isEmpty {digest.update(data:bytes)}
                content=digest.finalize().map{String(format:"%02x",$0)}.joined()
            }
            hash.update(data:Data("\(relative.utf8.count):\(relative):\(type.rawValue):\(mode):\(content.utf8.count):\(content)\n".utf8))
        }
        return "archive-tree-v1:"+hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private static func receiptFingerprint(_ url:URL,expected:String) throws -> String {
        try expected.hasPrefix("archive-tree-v1:") ? archiveFingerprint(url) : fingerprint(url)
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw FileToolsError.invalid("文件名为空、过长或含有非法字符。") }
    }
    /// Foundation's standardizedFileURL intentionally rewrites /private/var to /var on macOS.
    /// Enumerators return physical paths, so use realpath when deriving relative filesystem paths.
    static func canonicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    private static func validateDirectory(_ url: URL) throws {
        guard (try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { throw FileToolsError.invalid("目标不是可用文件夹：\(url.path)") }
    }
    private static func validateRegularFile(_ url: URL) throws {
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw FileToolsError.unsupported(url) }
    }
    private static func absent(_ url: URL) throws {
        // attributes also detects dangling links, for which fileExists reports false.
        if (try? fm.attributesOfItem(atPath: url.path)) != nil { throw FileToolsError.conflict(url) }
    }
    private static func isMissing(_ url: URL) throws -> Bool {
        do { _ = try fm.attributesOfItem(atPath: url.path); return false }
        catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return true }
            throw error
        }
    }
    private static func rollbackIndividually(_ receipts: [FileOperationReceipt]) -> [FileOperationReceipt] {
        var residual: [FileOperationReceipt] = []
        for receipt in receipts.reversed() {
            do { try undo([receipt], trashCreated: false) }
            catch { residual.append(receipt) }
        }
        return residual.reversed()
    }
    private static func validateDistinct(_ urls: [URL]) throws {
        var paths = Set<String>()
        for url in urls {
            let key = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw FileToolsError.conflict(url) }
        }
    }
}
