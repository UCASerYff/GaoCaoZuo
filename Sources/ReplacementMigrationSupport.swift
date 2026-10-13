import AppKit
import CryptoKit
import Foundation
import Darwin

struct ReplacementMigrationReceipt: Codable {
    var schema = 1
    var generation = 2
    var sourceSHA256: String
    var state: String
    var date = Date()
    var sourceApps = 4
    var templateCount = 0
    var iconCount = 0
    var appCount = 0
    var rulesAdded = 0
    var rulesUpgraded = 0
    var rulesPreserved = 0
    var rulesBlocked = 0
    var verifiedEmptyPasswordBooks = false
    var retainedUserChanges: [String] = []
    var notes: [String] = []
    var readyToUninstall = false
}

/// A completed settings transaction is distinct from real-device acceptance.
/// These receipts never authorize deletion of an original application.
struct ReplacementMigrationTransaction: Codable {
    var schema = 1
    var generation = 2
    var sourceSHA256: String
    var state = "prepared"
    var beforeSettings: OperationSettings
    var beforeArchive: ArchiveEnhancementPreferences
    var beforeFiles: FileEnhancementSettings
    var beforeFinder: FinderMenuPreferences
}

enum ReplacementMigrationSupport {
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined() }
    static func identical<T: Encodable>(_ a: T, _ b: T) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(a) == encoder.encode(b)
    }
    static func merged<T: Equatable>(_ candidate: T?, current: T, previousSource: T?, key: String, retained: inout [String]) -> T {
        guard let candidate else { return current }
        if let previousSource, current != previousSource {
            retained.append(key); return current
        }
        return candidate
    }
    static func preserve(_ bytes: Data, name: String, in data: LocalData) throws {
        let url = data.directory.appendingPathComponent(name)
        do {
            _ = try FileManager.default.attributesOfItem(atPath:url.path)
            guard try data.verifiedData(name) == bytes else { throw DataFailure.message("迁移原文件已变化，停止覆盖。") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            try data.createFile(bytes,name:name)
            guard try data.verifiedData(name) == bytes else { throw DataFailure.message("迁移原文件保存核验失败。") }
        }
    }
    static func folder(_ entry:[String:Any]) throws -> FavoriteFolder {
        guard let raw=entry["path"] as? String,!raw.contains("\0"),
              let name=entry["name"] as? String,raw.hasPrefix("/") || raw.hasPrefix("~/") else {throw DataFailure.message("原目录条目无法解释，已保留来源，停止迁移。")}
        let components=raw.split(separator:"/",omittingEmptySubsequences:false)
        guard !components.contains(".."),!components.contains(".") else {throw DataFailure.message("原目录条目包含未确认的路径跳转。")}
        let url=raw.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(raw.dropFirst(2)),isDirectory:true) : URL(fileURLWithPath:raw,isDirectory:true)
        let path=url.standardizedFileURL.path
        let title=name.isEmpty ? FileManager.default.displayName(atPath:path) : name
        guard !title.isEmpty else{throw DataFailure.message("原目录缺少可显示的名称。")}
        return FavoriteFolder(name:title,path:path)
    }
    static func checkedBytes(_ url: URL, maximum: Int) throws -> Data {
        let initial = try EnhancedFileTools.checked(url)
        guard initial.st_mode & S_IFMT == S_IFREG, initial.st_size >= 0, initial.st_size <= maximum else {
            throw DataFailure.message("迁移来源不是普通文件或超过读取预算。")
        }
        let descriptor = open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw DataFailure.message("迁移来源无法读取。") }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        var before = stat()
        guard fstat(descriptor,&before) == 0, before.st_dev == initial.st_dev, before.st_ino == initial.st_ino else {
            throw DataFailure.message("迁移来源在读取前被替换。")
        }
        var bytes = Data()
        while let part = try handle.read(upToCount:min(1_048_576,maximum-bytes.count+1)), !part.isEmpty {
            bytes.append(part)
            guard bytes.count <= maximum else { throw DataFailure.message("迁移来源超过读取预算。") }
        }
        var after = stat()
        guard fstat(descriptor,&after) == 0, before.st_size == after.st_size, bytes.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DataFailure.message("迁移来源在读取期间变化。")
        }
        return bytes
    }
}
