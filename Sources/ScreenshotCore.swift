import AppKit
import CryptoKit
import Darwin
import ImageIO

enum ScreenshotFileSafety {
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func digestFile(_ url: URL) throws -> String {
        let fd = try ScreenshotGaoPrivateIO.regularURL(url)
        let before = try fd.statValue()
        var hasher = SHA256(); var buffer = [UInt8](repeating:0,count:65536)
        while true {
            let n = Darwin.read(fd.value,&buffer,buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw ScreenshotAppIssue.message("文件读取失败。") }
            hasher.update(data:Data(buffer.prefix(n)))
        }
        guard ScreenshotGaoPrivateIO.unchanged(before,try fd.statValue()) else { throw ScreenshotAppIssue.message("文件在读取时改变。") }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
enum ScreenshotAppIssue: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
struct ScreenshotCaptureAsset: Codable, Identifiable {
    var id = UUID(); var createdAt = Date(); var source: String
    var pixelWidth: Int; var pixelHeight: Int; var colorSpace: String; var scale: Double
    var outputPath: String; var sha256: String; var editVersion = 0
}
struct ScreenshotAppSettings: Codable {
    var schemaVersion = 1
    var historyEnabled = false; var historyDays = 7; var historyCapacityMB = 512
    var captureStrategy = "标注"; var saveDirectory: String?; var editorPath: String?
    var languages = ["zh-Hans","en-US"]; var silentOCRCopies = true
    var pins: [String] = []
}
struct ScreenshotHistoryEnvelope: Codable { var schemaVersion = 1; var assets: [ScreenshotCaptureAsset] = [] }

@MainActor final class ScreenshotLocalStore: ObservableObject {
    let root: URL; let backupRoot: URL
    @Published var settings = ScreenshotAppSettings()
    @Published var assets: [ScreenshotCaptureAsset] = []
    @Published var issue: String?
    @Published private(set) var initializationRequired = true
    let migrationConfiguration: ScreenshotMigrationConfiguration
    private var settingsDigest: String?; private var historyDigest: String?
    var writable = false
    var exchange: URL { root.appendingPathComponent("Exchange",isDirectory:true) }
    init(root: URL? = nil, backupRoot: URL? = nil, migrationConfiguration: ScreenshotMigrationConfiguration? = nil) {
        let target = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoCaoZuo/Screenshot")
        self.root = target
        self.backupRoot = backupRoot ?? target.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GaoCaoZuo-Backups/Screenshot")
        self.migrationConfiguration = migrationConfiguration ?? .standard(targetRoot: target, backupRoot: self.backupRoot)
        reloadAfterMigration()
    }
    func migrationPreview() throws -> ScreenshotMigrationPlan { try ScreenshotMigration(configuration: migrationConfiguration).preview() }
    @discardableResult func applyMigration(_ plan: ScreenshotMigrationPlan, approvedDigest: String) throws -> ScreenshotMigrationResult {
        let result = try ScreenshotMigration(configuration: migrationConfiguration).apply(plan, approvedDigest: approvedDigest)
        reloadAfterMigration(); return result
    }
    @discardableResult func recoverMigration(migrationID: String) throws -> ScreenshotMigrationResult {
        let result = try ScreenshotMigration(configuration: migrationConfiguration).recover(migrationID: migrationID)
        reloadAfterMigration(); return result
    }
    func initializeFresh() throws { try ScreenshotMigration(configuration: migrationConfiguration).initializeFresh(); reloadAfterMigration() }
    /// Loading never creates a root, defaults or Exchange. Initialization/migration is a separate explicit user action.
    func reloadAfterMigration() {
        writable = false; initializationRequired = true; issue = nil
        settings = ScreenshotAppSettings(); assets = []; settingsDigest = nil; historyDigest = nil
        do {
            guard migrationConfiguration.targetRoot.standardizedFileURL == root.standardizedFileURL else { throw ScreenshotAppIssue.message("截图模块迁移配置与资料路径不一致。") }
            let migrator = ScreenshotMigration(configuration: migrationConfiguration)
            guard try migrator.initialization() != nil else {
                if try migrator.hasAnyLegacyEvidence() { throw ScreenshotAppIssue.message("检测到搞截图原资料或备份。请先在截图设置中显式预览并迁移；迁移前已停止生产写入。") }
                throw ScreenshotAppIssue.message("截图模块尚未初始化。请明确创建新截图资料；首次加载不会保存默认设置。")
            }
            initializationRequired = false
            _ = try ScreenshotGaoPrivateIO.directory(self.root,requirePrivate:true)
            let settingsURL = self.root.appendingPathComponent("Settings.json")
            if FileManager.default.fileExists(atPath:settingsURL.path) {
                let data = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(settingsURL),maximum:1_048_576)
                settings = try JSONDecoder().decode(ScreenshotAppSettings.self,from:data)
                guard settings.schemaVersion == 1, (1...3650).contains(settings.historyDays), (16...16384).contains(settings.historyCapacityMB) else { throw ScreenshotAppIssue.message("设置格式过新或损坏，已保留资料并停止写入。") }
                settingsDigest = ScreenshotFileSafety.digest(data)
            } else {
                throw ScreenshotAppIssue.message("已初始化截图资料的Settings主记录缺失，已停止写入，不能当作新用户覆盖。")
            }
            let historyURL = self.root.appendingPathComponent("History.json")
            if FileManager.default.fileExists(atPath:historyURL.path) {
                let data = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(historyURL),maximum:16_777_216)
                let envelope = try JSONDecoder().decode(ScreenshotHistoryEnvelope.self,from:data)
                guard envelope.schemaVersion == 1 else { throw ScreenshotAppIssue.message("历史版本过新，已停止写入。") }
                assets = envelope.assets; historyDigest = ScreenshotFileSafety.digest(data)
                for asset in assets {
                    guard asset.outputPath.hasPrefix("History/"), !asset.outputPath.contains("..") else { throw ScreenshotAppIssue.message("历史路径损坏，已停止写入。") }
                    let url = self.root.appendingPathComponent(asset.outputPath)
                    guard try ScreenshotFileSafety.digestFile(url) == asset.sha256 else { throw ScreenshotAppIssue.message("历史附件缺失或摘要不符，原记录已保留。") }
                }
            } else if FileManager.default.fileExists(atPath:self.root.appendingPathComponent("History").path) {
                throw ScreenshotAppIssue.message("历史目录存在但主记录缺失，已保护现有附件。")
            }
            writable = true
        } catch { issue = error.localizedDescription }
    }
    func saveSettings() throws {
        guard writable else { throw ScreenshotAppIssue.message(issue ?? "资料只读。") }
        settingsDigest = try persist(settings,name:"Settings.json",previous:settingsDigest)
    }
    private func persist<T:Encodable>(_ value: T, name: String, previous: String?) throws -> String {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:url.path) {
            guard try ScreenshotFileSafety.digestFile(url) == previous else { throw ScreenshotAppIssue.message("资料已在其他地方修改，停止覆盖，请重新打开。") }
        } else if previous != nil { throw ScreenshotAppIssue.message("资料记录消失，停止覆盖。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(value)
        try ScreenshotGaoPrivateIO.atomicJSON(data,directory:ScreenshotGaoPrivateIO.directory(root),name:name)
        return ScreenshotFileSafety.digest(data)
    }
    func remember(image: CGImage, source: String, scale: Double) throws {
        guard settings.historyEnabled else { return }
        guard writable else { throw ScreenshotAppIssue.message("资料保护模式下不能保存历史。") }
        try pruneExpiredHistory()
        let bytes = try ScreenshotPngData(image)
        let used = try assets.reduce(Int64(0)) { n,a in n + Int64((try root.appendingPathComponent(a.outputPath).resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0) }
        guard used + Int64(bytes.count) <= Int64(settings.historyCapacityMB)*1_048_576 else { throw ScreenshotAppIssue.message("历史达到容量上限，请先导出或删除。") }
        let directory = root.appendingPathComponent("History"); _ = try ScreenshotGaoPrivateIO.directory(directory,create:true,requirePrivate:true)
        let name = UUID().uuidString + ".png"; let url = directory.appendingPathComponent(name)
        try bytes.write(to:url,options:.withoutOverwriting); _ = chmod(url.path,0o600)
        let asset = ScreenshotCaptureAsset(source:source,pixelWidth:image.width,pixelHeight:image.height,colorSpace:image.colorSpace?.name as String? ?? "unknown",scale:scale,outputPath:"History/"+name,sha256:ScreenshotFileSafety.digest(bytes))
        var next = assets; next.insert(asset,at:0)
        do { historyDigest = try persist(ScreenshotHistoryEnvelope(assets:next),name:"History.json",previous:historyDigest); assets = next }
        catch { try? FileManager.default.removeItem(at:url); throw error }
    }
    func deleteHistory() throws {
        guard writable else { throw ScreenshotAppIssue.message("资料保护模式下不能删除历史。") }
        let trash = root.appendingPathComponent("DeletedHistory/"+UUID().uuidString)
        _ = try ScreenshotGaoPrivateIO.directory(trash,create:true,requirePrivate:true)
        // A recovery copy is retained before changing the index. No original user file is removed.
        for asset in assets { try FileManager.default.copyItem(at:root.appendingPathComponent(asset.outputPath),to:trash.appendingPathComponent(URL(fileURLWithPath:asset.outputPath).lastPathComponent)) }
        historyDigest = try persist(ScreenshotHistoryEnvelope(),name:"History.json",previous:historyDigest)
        for asset in assets { try FileManager.default.removeItem(at:root.appendingPathComponent(asset.outputPath)) }
        assets = []
    }
    func pruneExpiredHistory() throws {
        guard writable,settings.historyEnabled else{return}
        let cutoff=Date().addingTimeInterval(-Double(settings.historyDays)*86400)
        let expired=assets.filter{$0.createdAt<cutoff}
        guard !expired.isEmpty else{return}
        let recovery=root.appendingPathComponent("DeletedHistory/Expired-"+UUID().uuidString)
        _ = try ScreenshotGaoPrivateIO.directory(recovery,create:true,requirePrivate:true)
        for asset in expired{try FileManager.default.copyItem(at:root.appendingPathComponent(asset.outputPath),to:recovery.appendingPathComponent(URL(fileURLWithPath:asset.outputPath).lastPathComponent))}
        let next=assets.filter{$0.createdAt>=cutoff}
        historyDigest=try persist(ScreenshotHistoryEnvelope(assets:next),name:"History.json",previous:historyDigest);assets=next
        for asset in expired{try FileManager.default.removeItem(at:root.appendingPathComponent(asset.outputPath))}
    }
}
func ScreenshotPngData(_ image: CGImage) throws -> Data {
    guard let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw ScreenshotAppIssue.message("PNG 编码失败。") }; return data
}
func ScreenshotReadImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL,nil), let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 30000, h <= 30000, Int64(w)*Int64(h) <= 100_000_000, let image = CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ScreenshotAppIssue.message("图像无法解码或超过 1 亿像素安全预算。") }; return image
}
