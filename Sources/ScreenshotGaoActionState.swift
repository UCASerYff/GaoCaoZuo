import Foundation
import Darwin

enum ScreenshotGaoRequestPhase: String, Codable {
    case received, approved, executing, completed, partial, cancelled, failed, unsupported
    var isTerminal: Bool { [.completed,.partial,.cancelled,.failed,.unsupported].contains(self) }
}

struct ScreenshotGaoProcessedRequest: Codable, Equatable, Identifiable {
    var requestID: String
    var manifestSHA256: String
    var action: String
    var sourceBundleID: String
    var kind: String
    var receivedAt: String
    var updatedAt: String
    var phase: ScreenshotGaoRequestPhase
    var resultPackageName: String?
    var errorCode: String?
    var id: String { requestID }
}

enum ScreenshotGaoRequestReceipt {
    case new(ScreenshotGaoProcessedRequest)
    case duplicate(ScreenshotGaoProcessedRequest)
    var record: ScreenshotGaoProcessedRequest { switch self { case .new(let r), .duplicate(let r): return r } }
}

/// Records are append/update metadata only. Invalid or newer files disable processing instead of erasing history.
final class ScreenshotGaoProcessedRequestStore {
    private struct Envelope: Codable { var schemaVersion: Int; var records: [ScreenshotGaoProcessedRequest] }
    private let directory: ScreenshotGaoFixedFD
    private let lock = NSLock()
    private var records: [String:ScreenshotGaoProcessedRequest]
    private var persistedDigest: String?
    init(root: URL) throws {
        directory = try ScreenshotGaoPrivateIO.directory(root,create:true,requirePrivate:true)
        let fd = openat(directory.value,"ProcessedRequests.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw ScreenshotGaoActionContract.reject("recordUnreadable","交接历史无法读取，已停止接收，未覆盖旧记录。") }
            records = [:]; persistedDigest = nil; return
        }
        do {
            let bytes = try ScreenshotGaoPrivateIO.read(ScreenshotGaoFixedFD(fd),maximum:16_777_216)
            let envelope = try JSONDecoder().decode(Envelope.self,from:bytes)
            guard envelope.schemaVersion == 1, envelope.records.count <= 100_000 else { throw ScreenshotGaoActionContract.reject("recordUnsupported","交接历史版本或记录数量暂不支持，未覆盖旧记录。") }
            var indexed: [String:ScreenshotGaoProcessedRequest] = [:]
            for record in envelope.records {
                guard UUID(uuidString:record.requestID) != nil, ScreenshotGaoActionContract.validSHA(record.manifestSHA256), ScreenshotGaoActionContract.knownActions.contains(record.action), ScreenshotGaoActionContract.validBundleID(record.sourceBundleID), ["request","result"].contains(record.kind), ScreenshotGaoActionContract.date(record.receivedAt) != nil, ScreenshotGaoActionContract.date(record.updatedAt) != nil, indexed[UUID(uuidString:record.requestID)!.uuidString] == nil else { throw ScreenshotGaoActionContract.reject("recordCorrupt","交接历史损坏，已停止接收，未覆盖旧记录。") }
                if let package = record.resultPackageName { guard Self.safeResultName(package) else { throw ScreenshotGaoActionContract.reject("recordCorrupt","交接结果记录损坏，未覆盖旧记录。") } }
                indexed[UUID(uuidString:record.requestID)!.uuidString] = record
            }
            records = indexed; persistedDigest = ScreenshotFileSafety.digest(bytes)
        } catch let error as ScreenshotGaoActionIssue { throw error }
        catch { throw ScreenshotGaoActionContract.reject("recordCorrupt","交接历史损坏，已停止接收，未覆盖旧记录。") }
    }
    func lookup(_ requestID: String) -> ScreenshotGaoProcessedRequest? {
        lock.lock(); defer { lock.unlock() }; return records[UUID(uuidString:requestID)?.uuidString ?? requestID]
    }
    func allRecords() -> [ScreenshotGaoProcessedRequest] {
        lock.lock(); defer { lock.unlock() }; return records.values.sorted { $0.receivedAt > $1.receivedAt }
    }
    @discardableResult func receive(_ package: ScreenshotGaoValidatedPackage, now: Date = Date()) throws -> ScreenshotGaoRequestReceipt {
        lock.lock(); defer { lock.unlock() }
        let m = package.manifest
        let canonicalID = UUID(uuidString:m.requestID)!.uuidString
        if let existing = records[canonicalID] {
            guard existing.manifestSHA256 == package.manifestSHA256 else { throw ScreenshotGaoActionContract.reject("requestCollision","同一请求编号的内容已改变，已拒绝重复执行。") }
            return .duplicate(existing)
        }
        guard records.count < 100_000 else { throw ScreenshotGaoActionContract.reject("recordLimit","交接历史已达上限，请保留记录后处理。") }
        let record = ScreenshotGaoProcessedRequest(requestID:canonicalID,manifestSHA256:package.manifestSHA256,action:m.action,sourceBundleID:m.sourceBundleID,kind:m.kind,receivedAt:ScreenshotGaoActionContract.timestamp(now),updatedAt:ScreenshotGaoActionContract.timestamp(now),phase:.received)
        var next = records; next[canonicalID] = record
        try persist(next); records = next
        return .new(record)
    }
    @discardableResult func transition(requestID: String, to phase: ScreenshotGaoRequestPhase, resultPackageName: String? = nil, errorCode: String? = nil, now: Date = Date()) throws -> ScreenshotGaoProcessedRequest {
        lock.lock(); defer { lock.unlock() }
        let canonicalID = UUID(uuidString:requestID)?.uuidString ?? requestID
        guard var record = records[canonicalID] else { throw ScreenshotGaoActionContract.reject("unknownRequest","交接请求不存在，未执行动作。") }
        if record.phase == phase { return record }
        guard !record.phase.isTerminal else { throw ScreenshotGaoActionContract.reject("alreadyProcessed","该请求已处理，不能重复执行。") }
        let allowed: Bool
        switch record.phase {
        case .received: allowed = [.approved,.cancelled,.failed,.unsupported].contains(phase)
        case .approved: allowed = [.executing,.cancelled,.failed,.unsupported].contains(phase)
        case .executing: allowed = [.completed,.partial,.cancelled,.failed,.unsupported].contains(phase)
        default: allowed = false
        }
        guard allowed, resultPackageName == nil || Self.safeResultName(resultPackageName!), errorCode == nil || errorCode!.utf8.count <= 256 else { throw ScreenshotGaoActionContract.reject("invalidTransition","交接状态转换无效，未重复执行。") }
        record.phase = phase; record.updatedAt = ScreenshotGaoActionContract.timestamp(now)
        record.resultPackageName = resultPackageName ?? record.resultPackageName; record.errorCode = errorCode
        var next = records; next[canonicalID] = record
        try persist(next); records = next
        return record
    }
    private func persist(_ indexed: [String:ScreenshotGaoProcessedRequest]) throws {
        let currentFD = openat(directory.value,"ProcessedRequests.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if currentFD >= 0 {
            let current = try ScreenshotGaoPrivateIO.read(ScreenshotGaoFixedFD(currentFD),maximum:16_777_216)
            guard persistedDigest == ScreenshotFileSafety.digest(current) else { throw ScreenshotGaoActionContract.reject("recordConflict","交接历史已被其他窗口或程序修改，请重新打开后处理。") }
        } else {
            guard errno == ENOENT, persistedDigest == nil else { throw ScreenshotGaoActionContract.reject("recordConflict","交接历史已变化或无法读取，未覆盖旧记录。") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(schemaVersion:1,records:indexed.values.sorted {$0.requestID < $1.requestID}))
        guard data.count <= 16_777_216 else { throw ScreenshotGaoActionContract.reject("recordLimit","交接历史超过安全大小，已停止修改。") }
        try ScreenshotGaoPrivateIO.atomicJSON(data,directory:directory,name:"ProcessedRequests.json")
        persistedDigest = ScreenshotFileSafety.digest(data)
    }
    private static func safeResultName(_ value: String) -> Bool { value.hasSuffix(".gaoaction") && !value.contains("/") && !value.contains("\\") && !value.contains("\0") && value.utf8.count <= 128 }
}
