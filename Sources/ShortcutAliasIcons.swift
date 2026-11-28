import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum ShortcutMascot: String, CaseIterable, Identifiable {
    case chatgpt, claude, gemini, grok, deepseek, kimi, glm, qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .glm: return "GLM"
        case .qwen: return "Qwen"
        }
    }

    var imageURL: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: "ShortcutMascots")
    }

    static func suggestion(for name: String) -> Self? {
        let normalized = name.lowercased()
        let matches: [(Self, [String])] = [
            (.chatgpt, ["chatgpt", "chat gpt", "codex"]), (.claude, ["claude"]),
            (.gemini, ["gemini", "antigravity"]), (.grok, ["grok"]),
            (.deepseek, ["deepseek", "deep seek"]), (.kimi, ["kimi"]),
            (.glm, ["glm", "智谱", "zhipu", "zcode"]), (.qwen, ["qwen", "千问", "通义"])
        ]
        return matches.first(where: { entry in entry.1.contains(where: normalized.contains) })?.0
    }
}

struct ShortcutAliasStamp: Codable, Equatable {
    var device: Int32
    var inode: UInt64
    var bookmark: String
    var icon: String?

    func isSameAlias(as other: Self) -> Bool {
        device == other.device && inode == other.inode && bookmark == other.bookmark
    }
}

struct ShortcutAliasPreview: Identifiable {
    enum State: Equatable { case available, managed, custom, changed, interrupted }

    var url: URL
    var currentImage: NSImage
    var stamp: ShortcutAliasStamp
    var state: State
    var appliedName: String?
    var id: String { url.path }
}

struct ShortcutAliasBatch {
    var completed: Int
    var failures: [String]
}

/// Manages icons only on ordinary Finder alias files belonging to the current user.
/// The durable state contains fingerprints, never an alias or icon backup.
@MainActor final class ShortcutAliasIcons {
    private struct Receipt: Codable {
        var applied: ShortcutAliasStamp
        var name: String
    }

    private struct Journal: Codable {
        var schema = 1
        var receipts: [String: Receipt] = [:]
        var pending: [String: ShortcutAliasStamp] = [:]
        var restoring: Set<String>?

        mutating func clearPending(for key: String) {
            pending.removeValue(forKey: key)
            restoring?.remove(key)
        }
    }

    private struct CurrentAlias {
        var stamp: ShortcutAliasStamp
        var customIcon: NSImage?
    }

    private let data: LocalData
    private let manager = FileManager.default
    private static let recordFile = "shortcut-alias-icons.json"
    private static let maximumAliasBytes = 4 * 1_048_576
    private static let maximumImageBytes = 8 * 1_048_576

    init(data: LocalData) { self.data = data }

    var healthy: Bool { data.failure == nil }
    var desktop: URL? { manager.urls(for: .desktopDirectory, in: .userDomainMask).first }

    func desktopAliases() throws -> [URL] {
        guard let desktop else { throw FileToolsError.invalid("找不到当前用户的桌面。") }
        return try manager.contentsOfDirectory(at: desktop, includingPropertiesForKeys: [.isAliasFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isAliasFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func previews(for urls: [URL]) throws -> [ShortcutAliasPreview] {
        var saved = try journal()
        var recovered = false
        let previews = try urls.map { supplied -> ShortcutAliasPreview in
            let url = URL(fileURLWithPath: supplied.standardizedFileURL.path)
            let current = try inspect(url)
            let key = url.path
            if let pending = saved.pending[key], pending.icon != nil, current.stamp.icon == nil,
               saved.restoring?.contains(key) == true, saved.receipts[key]?.applied == pending,
               pending.isSameAlias(as: current.stamp) {
                // Finder already restored this exact alias. Commit the bookkeeping only.
                saved.clearPending(for: key)
                saved.receipts.removeValue(forKey: key)
                recovered = true
            }
            let receipt = saved.receipts[key]
            let state: ShortcutAliasPreview.State
            if let pending = saved.pending[key], pending != current.stamp { state = .interrupted }
            else if let receipt { state = receipt.applied == current.stamp ? .managed : .changed }
            else { state = current.customIcon == nil ? .available : .custom }
            return ShortcutAliasPreview(url: url, currentImage: current.customIcon ?? NSWorkspace.shared.icon(forFile: url.path),
                stamp: current.stamp, state: state, appliedName: state == .managed ? receipt?.name : nil)
        }
        if recovered { try data.save(saved, name: Self.recordFile) }
        return previews
    }

    func createAlias(for application: URL) throws -> URL {
        guard let desktop else { throw FileToolsError.invalid("找不到当前用户的桌面。") }
        return try createAlias(for: application, in: desktop)
    }

    func createAlias(for application: URL, in directory: URL) throws -> URL {
        guard application.pathExtension.lowercased() == "app",
              try EnhancedFileTools.checked(application).st_mode & S_IFMT == S_IFDIR,
              try EnhancedFileTools.checked(directory).st_mode & S_IFMT == S_IFDIR else {
            throw FileToolsError.invalid("请选择本机应用程序及可写的桌面目录。")
        }
        let target = directory.appendingPathComponent(application.deletingPathExtension().lastPathComponent + " 替身")
        let stage = directory.appendingPathComponent(".gao-alias-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let candidate = stage.appendingPathComponent("alias")
        defer { _ = unlink(candidate.path); _ = rmdir(stage.path) }
        let bookmark = try application.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: candidate)
        _ = try inspect(candidate)
        guard try URL(resolvingAliasFileAt: candidate, options: [.withoutUI, .withoutMounting]).standardizedFileURL == application.standardizedFileURL else {
            throw FileToolsError.invalid("无法核对新建替身的目标。")
        }
        guard renamex_np(candidate.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw FileToolsError.conflict(target) }
            throw FileToolsError.invalid("系统无法保存桌面替身。")
        }
        return target
    }

    static func loadLocalImage(_ url: URL) throws -> NSImage {
        let before = try EnhancedFileTools.checked(url)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= maximumImageBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              ["public.png", "com.microsoft.ico", "com.apple.icns"].contains(type as String),
              (1...32).contains(CGImageSourceGetCount(source)) else {
            throw FileToolsError.invalid("请选择 8 MB 以内的有效 ICO、ICNS 或 PNG 图标。")
        }
        let frames = (0..<CGImageSourceGetCount(source)).compactMap { index -> (index: Int, pixels: Int)? in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...4_096).contains(width), (1...4_096).contains(height) else { return nil }
            return (index, width * height)
        }
        guard let frame = frames.max(by: { $0.pixels < $1.pixels }),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, frame.index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ] as CFDictionary) else { throw FileToolsError.invalid("系统无法解码这个图标。") }
        let after = try EnhancedFileTools.checked(url)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileToolsError.changed(url)
        }
        return NSImage(cgImage: bitmap, size: NSSize(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
    }

    func change(_ rows: [ShortcutAliasPreview], to image: NSImage?, name: String = "") throws -> ShortcutAliasBatch {
        guard !rows.isEmpty, rows.count <= 80, Set(rows.map(\.id)).count == rows.count else {
            throw FileToolsError.invalid("每批请选择 1 到 80 个不同的替身。")
        }
        if image != nil && name.isEmpty { throw FileToolsError.invalid("请先选择图标。") }
        var journal = try journal()
        var completed = 0
        var failures: [String] = []
        for row in rows {
            do {
                try mutate(row, to: image, name: name, journal: &journal)
                completed += 1
            } catch {
                failures.append("\(row.url.lastPathComponent)：\(error.localizedDescription)")
                if data.failure != nil { break }
            }
        }
        return .init(completed: completed, failures: failures)
    }

    private func journal() throws -> Journal {
        let value = try data.load(Self.recordFile, as: Journal.self) ?? Journal()
        guard value.schema == 1 else { throw FileToolsError.invalid("此版本无法读取图标恢复记录。") }
        return value
    }

    private func mutate(_ row: ShortcutAliasPreview, to image: NSImage?, name: String, journal: inout Journal) throws {
        let url = row.url
        let key = url.path
        let before = try inspect(url)
        guard before.stamp == row.stamp else { throw FileToolsError.changed(url) }
        if let interrupted = journal.pending[key], interrupted != before.stamp {
            throw FileToolsError.invalid("上次处理未确认，请在 Finder 核对当前图标。")
        }
        let prior = journal.receipts[key]
        if let prior {
            guard before.stamp == prior.applied, before.customIcon != nil else { throw FileToolsError.changed(url) }
        } else {
            guard image != nil else { throw FileToolsError.invalid("此替身没有可恢复的换装记录。") }
            guard before.customIcon == nil else { throw FileToolsError.invalid("该替身已有自定义图标。") }
        }

        journal.pending[key] = before.stamp
        if image == nil { journal.restoring = (journal.restoring ?? []).union([key]) }
        else { journal.restoring?.remove(key) }
        try data.save(journal, name: Self.recordFile)
        guard try inspect(url).stamp == before.stamp else { throw FileToolsError.changed(url) }
        let didSet = NSWorkspace.shared.setIcon(image, forFile: key, options: [])
        let after = try inspect(url)
        guard before.stamp.isSameAlias(as: after.stamp) else { throw FileToolsError.changed(url) }
        guard didSet, (after.customIcon != nil) == (image != nil) else {
            if before.stamp == after.stamp {
                journal.clearPending(for: key)
                try data.save(journal, name: Self.recordFile)
            }
            throw FileToolsError.invalid("系统未能核对替身的图标修改。")
        }
        var completed = journal
        completed.clearPending(for: key)
        completed.receipts[key] = image == nil ? nil : Receipt(applied: after.stamp, name: name)
        do {
            try data.save(completed, name: Self.recordFile)
            journal = completed
        } catch {
            // Revert this write only while its exact post-state is still ours.
            if (try? inspect(url).stamp) == after.stamp {
                _ = NSWorkspace.shared.setIcon(before.customIcon, forFile: key, options: [])
            }
            throw FileToolsError.invalid("图标记录未能保存，请在 Finder 核对该替身。")
        }
    }

    private func inspect(_ supplied: URL) throws -> CurrentAlias {
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "plugin", "framework", "bundle"]
        let insideBundle = supplied.standardizedFileURL.pathComponents.contains { component in
            bundleExtensions.contains((component as NSString).pathExtension.lowercased())
        }
        guard supplied.isFileURL, !insideBundle else {
            throw FileToolsError.invalid("请选择 Finder 替身文件。")
        }
        let url = URL(fileURLWithPath: supplied.standardizedFileURL.path)
        let before = try EnhancedFileTools.checked(url)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size <= Self.maximumAliasBytes else { throw FileToolsError.invalid("请选择当前用户拥有的普通 Finder 替身。") }
        let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey, .customIconKey])
        guard values.isAliasFile == true, values.isSymbolicLink != true else { throw FileToolsError.invalid("该文件不是 Finder 替身。") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileToolsError.changed(url) }
        defer { close(fd) }
        let bookmark = try URL.bookmarkData(withContentsOf: url)
        guard !bookmark.isEmpty, bookmark.count <= Self.maximumAliasBytes else { throw FileToolsError.invalid("替身书签不可用。") }
        let finderInfo = try extendedAttribute("com.apple.FinderInfo", at: fd, limit: 32, url: url)
        let hasFinderIcon = finderInfo.count >= 10 && finderInfo[8] & 0x04 != 0
        let icon: String?
        if values.customIcon != nil || hasFinderIcon {
            let resource = try extendedAttribute("com.apple.ResourceFork", at: fd, limit: Self.maximumImageBytes, url: url)
            guard values.customIcon != nil, !resource.isEmpty else { throw FileToolsError.invalid("无法核对已有自定义图标。") }
            icon = Self.digest(resource)
        } else { icon = nil }
        var opened = stat()
        let after = try EnhancedFileTools.checked(url)
        guard fstat(fd, &opened) == 0, before.st_dev == opened.st_dev, before.st_ino == opened.st_ino,
              after.st_dev == opened.st_dev, after.st_ino == opened.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileToolsError.changed(url)
        }
        return .init(stamp: .init(device: before.st_dev, inode: before.st_ino, bookmark: Self.digest(bookmark), icon: icon), customIcon: values.customIcon)
    }

    private func extendedAttribute(_ name: String, at fd: Int32, limit: Int, url: URL) throws -> Data {
        let length = fgetxattr(fd, name, nil, 0, 0, 0)
        if length < 0, errno == ENOATTR { return Data() }
        guard length >= 0, length <= limit else { throw FileToolsError.changed(url) }
        var value = Data(count: length)
        let count = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
        guard count == length else { throw FileToolsError.changed(url) }
        return value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
