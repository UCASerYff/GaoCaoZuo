import AppKit
import Combine
import CryptoKit
import Darwin

struct FileMetadataChange: Codable, Identifiable {
    var id = UUID()
    var url: URL
    var device: Int32
    var inode: UInt64
    var kind: String
    var before: UInt32
    var after: UInt32
}

/// Standalone, non-UI operations. Every destructive caller must separately obtain an explicit choice.
enum EnhancedFileTools {
    static let fm = FileManager.default
    static func checked(_ url: URL) throws -> stat {
        guard url.isFileURL, url.path != "/" else { throw FileToolsError.invalid("请选择具体文件或目录。") }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw FileToolsError.invalid("无法读取：\(url.path)") }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else { throw FileToolsError.unsupported(url) }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.resolvingSymlinksInPath().path == parent.path else { throw FileToolsError.invalid("父目录包含符号链接，请从实际目录操作。") }
        return value
    }
    static func metadataPlan(_ urls: [URL], kind: String, value: UInt32) throws -> [FileMetadataChange] {
        guard !urls.isEmpty, Set(urls).count == urls.count else { throw FileToolsError.invalid("请选择不同的文件。") }
        return try urls.map { url in
            let s = try checked(url)
            let old: UInt32
            let next: UInt32
            switch kind {
            case "hidden": old = s.st_flags; next = value == 0 ? old & ~UInt32(UF_HIDDEN) : old | UInt32(UF_HIDDEN)
            case "extension": guard value <= 1 else { throw FileToolsError.invalid("扩展名显示设置无效。") }; old = (try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension ?? false) ? 1 : 0; next = value
            case "write": old = UInt32(s.st_mode & 0o7777); next = old | UInt32(S_IWUSR)
            case "mode": guard value <= 0o777 else { throw FileToolsError.invalid("权限必须是 000–777。") }; old = UInt32(s.st_mode & 0o7777); next = value
            default: throw FileToolsError.invalid("未知属性操作。")
            }
            return .init(url: url, device: s.st_dev, inode: s.st_ino, kind: kind, before: old, after: next)
        }
    }
    static func applyMetadata(_ changes: [FileMetadataChange], undo: Bool = false) throws {
        // Verify every identity/value before changing any item. No path is silently followed.
        for change in changes { try verify(change, expected: undo ? change.after : change.before) }
        var completed: [FileMetadataChange] = []
        do {
            for change in changes {
                try set(change, expected: undo ? change.after : change.before, value: undo ? change.before : change.after)
                completed.append(change)
            }
        } catch {
            let reason = error.localizedDescription
            var failures: [String] = []
            for change in completed.reversed() {
                do { try set(change, expected: undo ? change.before : change.after, value: undo ? change.after : change.before) }
                catch { failures.append(change.url.path) }
            }
            throw FileToolsError.invalid(reason + (failures.isEmpty ? "（已恢复本批次）" : "\n部分属性未能恢复，请核验：" + failures.joined(separator: "、")))
        }
    }
    private static func verify(_ c: FileMetadataChange, expected: UInt32) throws {
        let s = try checked(c.url)
        guard s.st_dev == c.device, s.st_ino == c.inode else { throw FileToolsError.changed(c.url) }
        let value: UInt32
        if c.kind == "hidden" { value = s.st_flags }
        else if c.kind == "extension" { value = (try c.url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension ?? false) ? 1 : 0 }
        else { value = UInt32(s.st_mode & 0o7777) }
        guard value == expected else { throw FileToolsError.changed(c.url) }
    }
    private static func set(_ c: FileMetadataChange, expected: UInt32, value: UInt32) throws {
        try verify(c, expected: expected)
        if c.kind == "extension" {
            var url = c.url; var values = URLResourceValues(); values.hasHiddenExtension = value != 0
            try url.setResourceValues(values)
        } else {
            let fd = open(c.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0, errno == EACCES, c.kind != "hidden" {
                // chmod is allowed for an owned unreadable file. macOS has no O_PATH;
                // fchmodat + NOFOLLOW preserves that capability without following links.
                let parent = open(c.url.deletingLastPathComponent().path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw FileToolsError.invalid("无法访问文件所在目录。") };defer{close(parent)}
                try verify(c,expected:expected)
                guard fchmodat(parent,c.url.lastPathComponent,mode_t(value),AT_SYMLINK_NOFOLLOW) == 0 else { throw FileToolsError.invalid("系统拒绝修改权限：\(c.url.path)（\(String(cString:strerror(errno)))）") }
                try verify(c,expected:value);return
            }
            guard fd >= 0 else { throw FileToolsError.invalid("无法修改属性：\(c.url.path)（\(String(cString:strerror(errno)))）") }; defer { close(fd) }
            var s = stat(); guard fstat(fd, &s) == 0, s.st_dev == c.device, s.st_ino == c.inode else { throw FileToolsError.changed(c.url) }
            let result = c.kind == "hidden" ? fchflags(fd, value) : fchmod(fd, mode_t(value))
            guard result == 0 else { throw FileToolsError.invalid("系统拒绝修改：\(c.url.path)（\(String(cString: strerror(errno)))）") }
        }
        try verify(c, expected: value)
    }
    static func children(_ directory: URL) throws -> [URL] {
        let s = try checked(directory); guard s.st_mode & S_IFMT == S_IFDIR else { throw FileToolsError.invalid("请选择文件夹。") }
        let result = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard result.count <= 10_000 else { throw FileToolsError.invalid("一次最多处理 10000 项。") }
        return result
    }
    static func hashes(_ url: URL) throws -> String {
        let before = try checked(url); guard before.st_mode & S_IFMT == S_IFREG else { throw FileToolsError.invalid("校验值仅适用于普通文件。") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileToolsError.invalid("文件无法读取。") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var identity = stat(); guard fstat(fd, &identity) == 0, identity.st_ino == before.st_ino, identity.st_dev == before.st_dev else { throw FileToolsError.changed(url) }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        while let bytes = try h.read(upToCount: 1_048_576), !bytes.isEmpty { md5.update(data: bytes); sha1.update(data: bytes); sha256.update(data: bytes); sha512.update(data: bytes) }
        var after = stat(); guard fstat(fd, &after) == 0, after.st_size == identity.st_size, after.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec else { throw FileToolsError.changed(url) }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        return "\(url.lastPathComponent)\n大小：\(identity.st_size) 字节\n权限：\(String(identity.st_mode & 0o777, radix: 8))\nMD5: \(hex(md5.finalize()))\nSHA1: \(hex(sha1.finalize()))\nSHA256: \(hex(sha256.finalize()))\nSHA512: \(hex(sha512.finalize()))"
    }
    static func foldersUsingNames(_ urls: [URL]) throws -> [FileOperationReceipt] {
        var records: [FileOperationReceipt] = []
        do {
            for url in urls {
                _ = try checked(url)
                let name = url.deletingPathExtension().lastPathComponent
                let target = try QuickFileActions.uniqueURL(in: url.deletingLastPathComponent(), preferredName: name, isDirectory: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                records.append(.init(kind: .create, destination: target, fingerprint: try FileTools.fingerprint(target)))
            }
            return records
        } catch { try FileTools.undo(records, trashCreated: false); throw error }
    }
    static func aliases(_ urls: [URL], to directory: URL) throws -> [FileOperationReceipt] {
        guard try checked(directory).st_mode & S_IFMT == S_IFDIR else { throw FileToolsError.invalid("替身目标不是文件夹。") }
        var records: [FileOperationReceipt] = []
        do {
            for url in urls {
                _ = try checked(url)
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                let output = try QuickFileActions.uniqueURL(in: directory, preferredName: url.lastPathComponent + " 替身")
                try URL.writeBookmarkData(data, to: output)
                records.append(.init(kind: .create, destination: output, fingerprint: try FileTools.fingerprint(output)))
            }
            return records
        } catch { try FileTools.undo(records, trashCreated: false); throw error }
    }
    /// Flatten into each source's parent. Empty original folders are retained for recoverability.
    /// The controller can remove them only after verified receipts have been committed.
    static func dissolve(_ folders: [URL]) throws -> [FileOperationReceipt] {
        var all: [(URL, URL)] = []; var targets = Set<String>()
        for folder in folders {
            for item in try children(folder) {
                let target = folder.deletingLastPathComponent().appendingPathComponent(item.lastPathComponent)
                guard targets.insert(target.path).inserted else { throw FileToolsError.conflict(target) }
                if (try? fm.attributesOfItem(atPath: target.path)) != nil { throw FileToolsError.conflict(target) }
                _ = try FileTools.fingerprint(item); all.append((item, target))
            }
        }
        var records: [FileOperationReceipt] = []
        do {
            for (source, target) in all { records += try FileTools.copy(items: [source], to: target.deletingLastPathComponent(), move: true) }
            return records
        } catch { try FileTools.undo(records, trashCreated: false); throw error }
    }
    /// Destructive, explicit opt-in API. Calling UI must show all targets and require confirmation.
    static func permanentlyDelete(_ urls: [URL], confirmation: String) throws {
        guard confirmation == "彻底删除", !urls.isEmpty else { throw FileToolsError.invalid("请明确输入“彻底删除”确认。") }
        guard Set(urls.map(\.standardizedFileURL)).count == urls.count else { throw FileToolsError.invalid("待删除项目重复。") }
        for url in urls {
            _ = try checked(url)
            guard !urls.contains(where: { $0 != url && url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { throw FileToolsError.invalid("不能同时删除文件夹及其内部项目。") }
        }
        let fingerprints = try urls.map { try FileTools.fingerprint($0) }
        for (i, url) in urls.enumerated() {
            guard try FileTools.fingerprint(url) == fingerprints[i] else { throw FileToolsError.changed(url) }
            // Quarantine by exclusive rename, then re-verify before irreversible deletion.
            let held = url.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-delete-" + UUID().uuidString)
            guard renamex_np(url.path, held.path, UInt32(RENAME_EXCL)) == 0 else { throw FileToolsError.invalid("未能暂存待删除项目：\(url.path)") }
            do { guard try FileTools.fingerprint(held) == fingerprints[i] else { throw FileToolsError.changed(held) }; try fm.removeItem(at: held) }
            catch { _ = renamex_np(held.path, url.path, UInt32(RENAME_EXCL)); throw FileToolsError.invalid("删除未全部完成，已经删除的项目无法恢复。" + error.localizedDescription) }
        }
    }
    /// Decode byte-preserving mojibake only after the caller has shown a rename preview.
    static func repairedNames(_ urls: [URL], byteEncoding: String.Encoding, textEncoding: String.Encoding) throws -> [RenamePlan] {
        guard !urls.isEmpty else { throw FileToolsError.invalid("请选择需要修复名称的文件。") }
        let plans = try urls.map { url -> RenamePlan in
            _ = try checked(url)
            guard let bytes = url.lastPathComponent.data(using: byteEncoding, allowLossyConversion: false),
                  let name = String(data: bytes, encoding: textEncoding), !name.isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw FileToolsError.invalid("当前编码无法无损修复：\(url.lastPathComponent)") }
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if target != url, (try? fm.attributesOfItem(atPath: target.path)) != nil { throw FileToolsError.conflict(target) }
            return RenamePlan(source: url, destination: target)
        }
        guard Set(plans.map { $0.destination.standardizedFileURL }).count == plans.count else { throw FileToolsError.invalid("修复后名称重复。") }
        return plans
    }
}

struct BinaryTemplate: Codable, Identifiable {
    struct Entry: Codable { var relative: String; var attachment: String?; var digest: String?; var mode: UInt32 }
    var id = UUID(); var name: String; var filename: String; var directory: Bool; var entries: [Entry]
}
struct EnhancedOpenApp: Codable, Identifiable { var id = UUID(); var name: String; var bundleID: String; var path: String }
struct FileEnhancementSettings: Codable {
    var schema = 1
    var templates: [BinaryTemplate] = []
    var apps: [EnhancedOpenApp] = []
    var autoOpenNew = false
    var cutHidesFiles = false
    var terminalNewWindow = false
    var customPathPrefix = ""
    var confirmPermanentDelete = true
    var newFileViaWindow = false

    enum CodingKeys: String, CodingKey { case schema, templates, apps, autoOpenNew, cutHidesFiles, terminalNewWindow, customPathPrefix, confirmPermanentDelete, newFileViaWindow }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        templates = try c.decodeIfPresent([BinaryTemplate].self, forKey: .templates) ?? []
        apps = try c.decodeIfPresent([EnhancedOpenApp].self, forKey: .apps) ?? []
        autoOpenNew = try c.decodeIfPresent(Bool.self, forKey: .autoOpenNew) ?? false
        cutHidesFiles = try c.decodeIfPresent(Bool.self, forKey: .cutHidesFiles) ?? false
        terminalNewWindow = try c.decodeIfPresent(Bool.self, forKey: .terminalNewWindow) ?? false
        customPathPrefix = try c.decodeIfPresent(String.self, forKey: .customPathPrefix) ?? ""
        confirmPermanentDelete = try c.decodeIfPresent(Bool.self, forKey: .confirmPermanentDelete) ?? true
        newFileViaWindow = try c.decodeIfPresent(Bool.self, forKey: .newFileViaWindow) ?? false
    }
}
struct EnhancementMetadataHistory: Codable { var schema = 1; var batches: [[FileMetadataChange]] = [] }
struct EnhancementCutState:Codable {var schema=1;var files:[URL]=[];var digests:[String]=[];var metadata:[FileMetadataChange]=[]}
struct DissolvedFolderBatch: Codable {
    struct Shell: Codable { var original:URL;var held:URL;var fingerprint:String }
    var schema=1
    var shells:[Shell]
    var records:[FileOperationReceipt]
}
struct EnhancementToolRequest: Identifiable { var id = UUID(); var action: String; var files: [URL]; var result = "" }

enum FileEnhancements {
    static let documentFormats = ["docx", "xlsx", "pptx", "rtf", "xml", "psd", "pages", "numbers", "key"]
    static var actions: [OperationAction] {
        let file: [(String, String)] = [("file.hide", "隐藏所选文件"),("file.unhide", "取消隐藏所选文件"),("file.hideAll", "隐藏当前目录全部文件"),("file.unhideAll", "取消隐藏当前目录全部文件"),("file.extension.hide", "隐藏文件扩展名"),("file.extension.show", "显示文件扩展名"),("file.write", "授予所有者写权限"),("file.permissions", "设置文件权限…"),("file.info", "文件信息与全部校验值"),("file.alias", "发送替身到桌面"),("file.cut", "剪切文件"),("file.paste", "粘贴剪切的文件"),("file.folderNames", "根据文件名创建文件夹"),("file.dissolve", "解散文件夹…"),("file.delete", "彻底删除…"),("file.icon", "设置文件图标…"),("file.icon.clear", "移除自定义图标"),("file.airdrop", "隔空投送"),("file.mail", "邮件发送"),("file.wallpaper", "设为桌面墙纸"),("file.openApp", "用指定应用打开…"),("file.terminal", "在终端新窗口/标签页打开"),("file.path.real", "复制真实路径"),("file.path.custom", "复制自定义路径"),("file.template.import", "导入文件模板…"),("file.template.create", "从文件模板新建…"),("file.new.office", "新建文档…"),("file.metadata.undo", "恢复上次属性修改"),("file.ishot", "打开 iShot"),("file.ishot.markup", "用 iShot 打开图片"),("file.diskmap", "用 DiskMap 分析所选目录")]
        let noSelection:Set<String>=["file.template.import","file.template.create","file.new.office","file.metadata.undo","file.paste","file.hideAll","file.unhideAll","file.terminal"]
        var result = file.map { OperationAction(id:$0.0,title:$0.1,detail:"文件增强",icon:"folder.badge.gearshape",section:.files,files:!noSelection.contains($0.0)) }
        result += [("images.webp","转为 WebP"),("images.icns","转为 ICNS"),("images.macicons","生成 macOS 图标集"),("images.iosicons","生成 iOS 图标集")].map { OperationAction(id:$0.0,title:$0.1,detail:"图片与图标",icon:"photo",section:.tools,files:true) }
        result += [("text.baidu","百度翻译所选文字"),("text.google","谷歌翻译所选文字")].map { OperationAction(id:$0.0,title:$0.1,detail:"使用剪贴板文字打开翻译网页",icon:"character.bubble",section:.tools) }
        result += [("file.fixNames", "修复乱码文件名…"), ("file.icon.builtin", "使用内置文件图标…")].map { OperationAction(id:$0.0,title:$0.1,detail:"预览后处理所选项目",icon:"folder.badge.gearshape",section:.files,files:true) }
        result += documentFormats.map { OperationAction(id:"file.new."+$0,title:"新建 "+$0.uppercased(),detail:"直接创建有效空白文档",icon:"doc.badge.plus",section:.files) }
        return result
    }
}

@MainActor final class FileEnhancementController: ObservableObject {
    @Published private(set) var settings = FileEnhancementSettings()
    @Published var request: EnhancementToolRequest?
    @Published var error: String?
    @Published private(set) var history = EnhancementMetadataHistory()
    let data: LocalData
    private var cutFiles: [URL] = []
    private var cutDigests: [String] = []
    private var cutMetadata: [FileMetadataChange] = []
    private var cutChangeCount: Int?
    private var dissolved:DissolvedFolderBatch?
    init(directory: URL) {
        data = LocalData(directory: directory.appendingPathComponent("FileEnhancements",isDirectory:true))
        do {
            if let saved = try data.load("settings.json",as:FileEnhancementSettings.self) { guard saved.schema == 1 else { throw DataFailure.message("文件增强设置版本过新。") };settings=saved }
            if let saved = try data.load("metadata-history.json",as:EnhancementMetadataHistory.self) { guard saved.schema == 1 else { throw DataFailure.message("属性记录版本过新。") };history=saved }
            dissolved=try data.load("dissolved.json",as:DissolvedFolderBatch.self)
            if let cut=try data.load("cut-journal.json",as:EnhancementCutState.self) {guard cut.schema==1 else{throw DataFailure.message("剪切记录版本过新。")};cutFiles=cut.files;cutDigests=cut.digests;cutMetadata=cut.metadata}
            for template in settings.templates { for entry in template.entries { if let name=entry.attachment,let digest=entry.digest { let bytes=try data.verifiedData(name);guard Self.digest(bytes)==digest else {throw DataFailure.message("模板附件校验失败。")} } } }
        } catch { data.block(error.localizedDescription);self.error=error.localizedDescription }
    }
    var healthy: Bool { data.failure == nil }
    func update(_ change:(inout FileEnhancementSettings)->Void) throws { var next=settings;change(&next);try data.save(next,name:"settings.json");settings=next }
    nonisolated static func digest(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    func importTemplate(_ source: URL) throws {
        guard healthy else {throw DataFailure.message(data.failure!)}
        let s=try EnhancedFileTools.checked(source);let directory=s.st_mode & S_IFMT == S_IFDIR
        let fingerprint=try FileTools.fingerprint(source)
        let root=directory ? source : source.deletingLastPathComponent()
        var urls=[source]
        if directory {guard let e=FileManager.default.enumerator(at:source,includingPropertiesForKeys:nil) else {throw FileToolsError.invalid("无法读取模板目录。")};urls += e.compactMap{$0 as? URL}}
        guard urls.count <= 10_000 else {throw FileToolsError.invalid("模板项目过多。")}
        var template=BinaryTemplate(name:source.deletingPathExtension().lastPathComponent,filename:source.lastPathComponent,directory:directory,entries:[])
        var total=0
        var created: [String] = []
        var committed = false
        defer { if !committed { for name in created { try? data.removeKnownFile(name) } } }
        for url in urls {
            let info=try EnhancedFileTools.checked(url)
            let relative=directory ? String(url.path.dropFirst(root.path.count)).trimmingCharacters(in:CharacterSet(charactersIn:"/")) : ""
            if info.st_mode & S_IFMT == S_IFDIR {template.entries.append(.init(relative:relative,attachment:nil,digest:nil,mode:UInt32(info.st_mode & 0o777)));continue}
            guard info.st_size <= 32_000_000 else {throw FileToolsError.invalid("单个模板附件最多 32 MB。")}
            let bytes=try Data(contentsOf:url,options:.mappedIfSafe);total += bytes.count
            guard total <= 128_000_000 else {throw FileToolsError.invalid("模板合计最多 128 MB。")}
            let name=UUID().uuidString+".template"
            try data.createFile(bytes,name:name)
            created.append(name)
            template.entries.append(.init(relative:relative,attachment:name,digest:Self.digest(bytes),mode:UInt32(info.st_mode & 0o777)))
        }
        guard try FileTools.fingerprint(source)==fingerprint else {throw FileToolsError.changed(source)}
        try update{$0.templates.append(template)}
        committed = true
    }
    func createTemplate(_ template:BinaryTemplate,in directory:URL) throws -> FileOperationReceipt {
        guard healthy else {throw DataFailure.message(data.failure!)}
        var verified:[String:Data]=[:]
        guard !template.entries.isEmpty, Set(template.entries.map(\.relative)).count == template.entries.count,
              template.entries.filter({ $0.relative.isEmpty }).count == 1,
              template.directory || (template.entries.count == 1 && template.entries[0].attachment != nil) else { throw DataFailure.message("模板结构无效。") }
        for entry in template.entries {
            guard !entry.relative.hasPrefix("/"),!entry.relative.split(separator:"/",omittingEmptySubsequences:false).contains(".."),!entry.relative.contains("\0"),entry.mode <= 0o777 else {throw DataFailure.message("模板路径或权限无效。")}
            if let attachment=entry.attachment {let bytes=try data.verifiedData(attachment);guard Self.digest(bytes)==entry.digest else {throw DataFailure.message("模板内容已变化。")};verified[attachment]=bytes}
        }
        let result=try QuickFileActions.uniqueURL(in:directory,preferredName:template.filename,isDirectory:template.directory)
        let stage=directory.appendingPathComponent(".gaocaozuo-template-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:stage)}
        let payload=stage.appendingPathComponent("payload",isDirectory:template.directory)
        for entry in template.entries.sorted(by:{$0.relative.count<$1.relative.count}) {
            let target=entry.relative.isEmpty ? payload : payload.appendingPathComponent(entry.relative)
            if let name=entry.attachment,let bytes=verified[name] {try bytes.write(to:target,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:entry.mode],ofItemAtPath:target.path)}
            else {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false,attributes:[.posixPermissions:entry.mode | 0o700])}
        }
        // Keep directories writable during staging, then restore their original modes inside-out.
        for entry in template.entries.filter({ $0.attachment == nil }).sorted(by: { $0.relative.count > $1.relative.count }) {
            let target = entry.relative.isEmpty ? payload : payload.appendingPathComponent(entry.relative)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: target.path)
        }
        let fingerprint=try FileTools.fingerprint(payload)
        guard renamex_np(payload.path,result.path,UInt32(RENAME_EXCL))==0 else {throw FileToolsError.conflict(result)}
        return .init(kind:.create,destination:result,fingerprint:fingerprint)
    }
    func createTemplate(_ id:UUID,directory:URL) throws -> FileOperationReceipt {
        guard let template=settings.templates.first(where:{$0.id==id}) else{throw FileToolsError.invalid("未找到该文件模板。")}
        return try createTemplate(template,in:directory)
    }
    func changeMetadata(_ files:[URL],kind:String,value:UInt32) throws {
        let changes=try EnhancedFileTools.metadataPlan(files,kind:kind,value:value)
        var next=history;next.batches.insert(changes,at:0)
        // Durable recovery intent precedes mutation. Interrupted batches remain visible for manual inspection.
        try data.save(next,name:"metadata-history.json");history=next
        do { try EnhancedFileTools.applyMetadata(changes) }
        catch {
            // applyMetadata rolls back completed entries. Retain the durable intent if it cannot be cleared.
            var restored = history; restored.batches.removeFirst()
            let fullyRestored = (try? changes.allSatisfy { c in
                guard let state = try EnhancedFileTools.metadataPlan([c.url],kind:c.kind,value:c.after).first else { return false }
                return state.device == c.device && state.inode == c.inode && state.before == c.before
            }) ?? false
            if fullyRestored, (try? data.save(restored,name:"metadata-history.json")) != nil { history=restored }
            throw error
        }
    }
    func undoMetadata() throws {
        guard let changes=history.batches.first else {throw FileToolsError.invalid("没有属性恢复记录。")}
        var applied: [FileMetadataChange] = []
        for change in changes {
            let s = try EnhancedFileTools.checked(change.url)
            guard s.st_dev == change.device, s.st_ino == change.inode else { throw FileToolsError.changed(change.url) }
            let current: UInt32
            if change.kind == "hidden" { current=s.st_flags }
            else if change.kind == "extension" { current=(try change.url.resourceValues(forKeys:[.hasHiddenExtensionKey]).hasHiddenExtension ?? false) ? 1 : 0 }
            else { current=UInt32(s.st_mode & 0o7777) }
            if current == change.after { applied.append(change) }
            else if current != change.before { throw FileToolsError.changed(change.url) }
        }
        try EnhancedFileTools.applyMetadata(applied,undo:true)
        var next=history;next.batches.removeFirst();try data.save(next,name:"metadata-history.json");history=next
    }
    func cancelCut() throws {
        if !cutMetadata.isEmpty {try EnhancedFileTools.applyMetadata(cutMetadata,undo:true)}
        try data.save(EnhancementCutState(),name:"cut-journal.json")
        cutFiles=[];cutDigests=[];cutMetadata=[];cutChangeCount=nil
    }
    func beginCut(_ files:[URL],writePasteboard:Bool=true) throws {
        try cancelCut()
        let digests=try files.map{try FileTools.fingerprint($0)}
        let changes=settings.cutHidesFiles ? try EnhancedFileTools.metadataPlan(files,kind:"hidden",value:1) : []
        try data.save(EnhancementCutState(files:files,digests:digests,metadata:changes),name:"cut-journal.json")
        if !changes.isEmpty {try EnhancedFileTools.applyMetadata(changes)}
        cutFiles=files;cutDigests=digests;cutMetadata=changes
        if writePasteboard {let pb=NSPasteboard.general;pb.clearContents();pb.writeObjects(files as [NSURL]);cutChangeCount=pb.changeCount}
    }
    func pasteCut(to directory:URL,checkPasteboard:Bool=true) throws -> [FileOperationReceipt] {
        guard !cutFiles.isEmpty else {throw FileToolsError.invalid("请先用搞操作剪切文件。")}
        if checkPasteboard,let count=cutChangeCount,count != NSPasteboard.general.changeCount {throw FileToolsError.invalid("系统剪贴板已变化，剪切仍保留；请重新剪切或取消。")}
        for (url,digest) in zip(cutFiles,cutDigests) {guard try FileTools.fingerprint(url)==digest else {throw FileToolsError.changed(url)}}
        if !cutMetadata.isEmpty {
            let changes=cutMetadata
            try EnhancedFileTools.applyMetadata(changes,undo:true)
            do { try data.save(EnhancementCutState(files:cutFiles,digests:cutDigests,metadata:[]),name:"cut-journal.json");cutMetadata=[] }
            catch { try EnhancedFileTools.applyMetadata(changes);throw error }
        }
        let records=try FileTools.copy(items:cutFiles,to:directory,move:true)
        do {try data.save(EnhancementCutState(),name:"cut-journal.json")}
        catch {try FileTools.undo(records,trashCreated:false);throw error}
        cutFiles=[];cutDigests=[];cutChangeCount=nil
        return records
    }
    func dissolveFolders(_ folders:[URL]) throws -> [URL] {
        guard dissolved == nil || dissolved?.shells.isEmpty == true else {throw FileToolsError.invalid("请先恢复上次解散操作，避免覆盖恢复记录。")}
        for a in folders {for b in folders where a != b {guard !b.path.hasPrefix(a.path+"/") else {throw FileToolsError.invalid("不能同时解散父目录及其子目录。")}}}
        let records=try EnhancedFileTools.dissolve(folders)
        var batch=DissolvedFolderBatch(shells:[],records:records)
        do {
            for folder in folders {
                guard try EnhancedFileTools.children(folder).isEmpty else {throw FileToolsError.changed(folder)}
                let held=folder.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-folder-recovery-"+UUID().uuidString,isDirectory:true)
                let shell=DissolvedFolderBatch.Shell(original:folder,held:held,fingerprint:try FileTools.fingerprint(folder))
                batch.shells.append(shell)
                try data.save(batch,name:"dissolved.json");dissolved=batch
                guard renamex_np(folder.path,held.path,UInt32(RENAME_EXCL))==0 else {throw FileToolsError.invalid("无法保留文件夹恢复外壳。")}
            }
            return records.map(\.destination)
        } catch {
            for shell in batch.shells.reversed() {if FileManager.default.fileExists(atPath:shell.held.path) {_ = renamex_np(shell.held.path,shell.original.path,UInt32(RENAME_EXCL))}}
            try FileTools.undo(records,trashCreated:false)
            let empty=DissolvedFolderBatch(shells:[],records:[]);try data.save(empty,name:"dissolved.json");dissolved=empty
            throw error
        }
    }
    func undoDissolve() throws {
        guard let batch=dissolved,!batch.shells.isEmpty else {throw FileToolsError.invalid("没有可恢复的解散操作。")}
        for shell in batch.shells {guard try FileTools.fingerprint(shell.held)==shell.fingerprint,!FileManager.default.fileExists(atPath:shell.original.path) else {throw FileToolsError.changed(shell.original)}}
        for record in batch.records {guard try FileTools.fingerprint(record.destination)==record.fingerprint else {throw FileToolsError.changed(record.destination)}}
        for shell in batch.shells {guard renamex_np(shell.held.path,shell.original.path,UInt32(RENAME_EXCL))==0 else {throw FileToolsError.invalid("恢复目录失败：\(shell.original.path)")}}
        try FileTools.undo(batch.records,trashCreated:false)
        let empty=DissolvedFolderBatch(shells:[],records:[]);try data.save(empty,name:"dissolved.json");dissolved=empty
    }
}
