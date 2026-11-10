import Foundation
import CoreFoundation
import Darwin

private struct LegacyDesktopPreferences: Codable {
    struct Hotkey: Codable { var keyCode: UInt32; var modifiers: UInt32 }
    struct Workspace: Codable {
        var id: UUID; var displayName: String; var fileURL: URL; var createdAt: Date
    }
    struct Probe: Codable {
        var id: UUID; var observedAt: Date; var capability: String; var outcome: String; var evidenceCode: String
    }
    var appearance: String
    var thumbnailsEnabled: Bool
    var excludedThumbnailBundleIDs: [String]
    var hotkeyEnabled: Bool
    var hotkey: Hotkey
    var groupByApplication: Bool
    var compactChooser: Bool
    var notchEnabled: Bool
    var workspaceReferences: [Workspace]
    var capabilityProbeResults: [Probe]

    func validate() throws {
        guard ["system", "light", "dark"].contains(appearance), hotkey.keyCode <= 127,
              hotkey.modifiers & ~UInt32(0x1b00) == 0, hotkey.modifiers & UInt32(0x1900) != 0,
              !(hotkey.modifiers == 0x100 && [12,13,8,9,7,0,6,43,48,49].contains(hotkey.keyCode)),
              excludedThumbnailBundleIDs.count <= 256,
              Set(excludedThumbnailBundleIDs).count == excludedThumbnailBundleIDs.count,
              excludedThumbnailBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains(where: \.isWhitespace) && !$0.contains("\0") }),
              workspaceReferences.count <= 64,
              Set(workspaceReferences.map(\.id)).count == workspaceReferences.count,
              workspaceReferences.allSatisfy({ $0.fileURL.isFileURL && $0.fileURL.host.map({ $0.isEmpty || $0 == "localhost" }) != false && $0.displayName.utf8.count <= 512 }),
              capabilityProbeResults.count <= 64,
              Set(capabilityProbeResults.map(\.id)).count == capabilityProbeResults.count,
              capabilityProbeResults.allSatisfy({ $0.capability.utf8.count <= 128 && $0.outcome.utf8.count <= 128 && $0.evidenceCode.utf8.count <= 128 }) else {
            throw LegacyDesktopMigrationError.invalid("来源窗口设置内容无效；未写入目标资料。")
        }
    }
}

private struct LegacyDesktopPayload: Codable {
    var schemaVersion: Int
    var storeID: UUID
    var generation: UInt64
    var migrationHistory: [String]
    var preferences: LegacyDesktopPreferences
}
private struct LegacyDesktopEnvelope: Codable { var payload: LegacyDesktopPayload; var sha256: String }
private struct LegacyDesktopMarker: Codable { var schemaVersion: Int; var storeID: UUID; var createdAt: Date }

struct LegacyDesktopValidatedSource {
    var identity: LegacyDesktopMigrationIdentity
    var evidence: LegacyDesktopMigrationEvidence
    var overview: DesktopOverviewPreferences
    var hotkeyEnabled: Bool
    var hotkeyCode: UInt16
    var hotkeyCarbonModifiers: UInt32
    var retainedWorkspaceCount: Int
    var retainedProbeCount: Int

    static func read(_ source: LegacyDesktopMigrationSource) throws -> Self {
        let preferences = try LegacyDesktopMigrationFiles.readPrivate(source.dataDirectory.appendingPathComponent("preferences.json"))
        let markerBytes = try LegacyDesktopMigrationFiles.readPrivate(source.initializationURL)
        let infoURL = source.applicationURL.appendingPathComponent("Contents/Info.plist")
        let infoBytes = try LegacyDesktopMigrationFiles.readApplication(infoURL)
        try LegacyDesktopStrictJSON.validate(preferences)
        try LegacyDesktopStrictJSON.validate(markerBytes)
        try validateShape(preferences: preferences, marker: markerBytes)
        let decoder = LegacyDesktopMigrationCoding.decoder
        let envelope = try decoder.decode(LegacyDesktopEnvelope.self, from: preferences)
        let marker = try decoder.decode(LegacyDesktopMarker.self, from: markerBytes)
        guard envelope.payload.schemaVersion == 1, marker.schemaVersion == 1 else {
            throw LegacyDesktopMigrationError.invalid("来源格式过新或不受支持；未写入目标资料。")
        }
        guard let info = try PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.gaoseries.GaoZhuoMian",
              info["CFBundleExecutable"] as? String == "GaoZhuoMian",
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleShortVersionString"] as? String == "1.00",
              info["CFBundleVersion"] as? String == "1" else {
            throw LegacyDesktopMigrationError.invalid("来源程序身份或版本不受支持；请选择搞桌面 V1.00 / build 1。")
        }
        let payload = envelope.payload
        let payloadHash = LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationCoding.encoder.encode(payload))
        guard payload.generation > 0, payload.storeID == marker.storeID,
              envelope.sha256.count == 64, envelope.sha256 == payloadHash,
              payload.migrationHistory.count <= 128,
              payload.migrationHistory.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw LegacyDesktopMigrationError.invalid("来源初始化身份、代数或摘要不一致；未写入目标资料。")
        }
        try payload.preferences.validate()
        // Detect a source update between the independent marker and settings reads.
        guard try LegacyDesktopMigrationFiles.readPrivate(source.dataDirectory.appendingPathComponent("preferences.json")) == preferences,
              try LegacyDesktopMigrationFiles.readPrivate(source.initializationURL) == markerBytes,
              try LegacyDesktopMigrationFiles.readApplication(infoURL) == infoBytes else {
            throw LegacyDesktopMigrationError.invalid("来源在预览期间发生变化；请重新预览。")
        }
        let p = payload.preferences
        var overview = DesktopOverviewPreferences()
        overview.groupByApplication = p.groupByApplication
        overview.compactChooser = p.compactChooser
        overview.excludedThumbnailBundleIDs = p.excludedThumbnailBundleIDs
        overview.thumbnailsEnabled = p.thumbnailsEnabled
        overview.statusStripEnabled = p.notchEnabled
        overview = try overview.validated()
        return Self(identity: .init(bundleID: "com.gaoseries.GaoZhuoMian", appVersion: "1.00", appBuild: 1,
                                    schemaVersion: 1, storeID: payload.storeID, generation: payload.generation,
                                    migrationHistory: payload.migrationHistory,
                                    preferencesSHA256: LegacyDesktopMigrationCoding.digest(preferences),
                                    initializationSHA256: LegacyDesktopMigrationCoding.digest(markerBytes),
                                    applicationInfoSHA256: LegacyDesktopMigrationCoding.digest(infoBytes), payloadSHA256: payloadHash),
                    evidence: .init(preferences: preferences, initialization: markerBytes, applicationInfo: infoBytes),
                    overview: overview, hotkeyEnabled: p.hotkeyEnabled, hotkeyCode: UInt16(p.hotkey.keyCode),
                    hotkeyCarbonModifiers: p.hotkey.modifiers, retainedWorkspaceCount: p.workspaceReferences.count,
                    retainedProbeCount: p.capabilityProbeResults.count)
    }

    private static func validateShape(preferences: Data, marker: Data) throws {
        func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any], Set(object.keys) == keys else {
                throw LegacyDesktopMigrationError.invalid("来源字段缺失或不属于已支持的格式；未写入目标资料。")
            }
            return object
        }
        let envelope = try object(JSONSerialization.jsonObject(with: preferences), keys: ["payload", "sha256"])
        let payload = try object(envelope["payload"], keys: ["schemaVersion", "storeID", "generation", "migrationHistory", "preferences"])
        let p = try object(payload["preferences"], keys: ["appearance", "thumbnailsEnabled", "excludedThumbnailBundleIDs", "hotkeyEnabled", "hotkey", "groupByApplication", "compactChooser", "notchEnabled", "workspaceReferences", "capabilityProbeResults"])
        _ = try object(p["hotkey"], keys: ["keyCode", "modifiers"])
        guard let workspaces = p["workspaceReferences"] as? [Any], let probes = p["capabilityProbeResults"] as? [Any] else {
            throw LegacyDesktopMigrationError.invalid("来源集合格式无效；未写入目标资料。")
        }
        for workspace in workspaces { _ = try object(workspace, keys: ["id", "displayName", "fileURL", "createdAt"]) }
        for probe in probes { _ = try object(probe, keys: ["id", "observedAt", "capability", "outcome", "evidenceCode"]) }
        _ = try object(JSONSerialization.jsonObject(with: marker), keys: ["schemaVersion", "storeID", "createdAt"])
    }
}

enum LegacyDesktopMigrationFiles {
    static func readPrivate(_ url: URL) throws -> Data { try read(url, privateFile: true) }
    static func readApplication(_ url: URL) throws -> Data { try read(url, privateFile: false) }

    private static func read(_ url: URL, privateFile: Bool) throws -> Data {
        guard url.isFileURL, url.standardizedFileURL.path != "/" else {
            throw LegacyDesktopMigrationError.invalid("来源必须是本地普通文件。")
        }
        let local = LocalData(directory: url.deletingLastPathComponent(), createIfMissing: false)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              privateFile ? info.st_uid == getuid() : (info.st_uid == getuid() || info.st_uid == 0) else {
            throw LegacyDesktopMigrationError.invalid("来源缺失、不可读、含链接或权限异常；未写入目标资料。")
        }
        return try local.verifiedData(url.lastPathComponent, maximumSize: 1_048_576)
    }
}

/// Foundation's Codable parser accepts duplicate object keys. Reject those
/// before decoding, instead of selecting an arbitrary value.
enum LegacyDesktopStrictJSON {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw failure() }
    }
    private static func failure() -> LegacyDesktopMigrationError { .invalid("来源 JSON 损坏、字段重复或超出解析预算。") }
    private struct Parser {
        var bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) throws { whitespace(); guard index < bytes.count, bytes[index] == byte else { throw failure() }; index += 1 }
        mutating func string() throws -> String {
            whitespace(); let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { guard index < bytes.count else { throw failure() }; index += 1 }
                else if byte == 34 {
                    let data = Data(bytes[start..<index])
                    guard let result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw failure() }
                    return result
                }
            }
            throw failure()
        }
        mutating func value(depth: Int) throws {
            whitespace(); nodes += 1
            guard depth <= 32, nodes <= 20_000, index < bytes.count else { throw failure() }
            switch bytes[index] {
            case 123:
                index += 1; whitespace(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw failure() }
                    try consume(58); try value(depth: depth + 1); whitespace()
                    guard index < bytes.count else { throw failure() }
                    if bytes[index] == 125 { index += 1; return }
                    try consume(44)
                }
            case 91:
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace(); guard index < bytes.count else { throw failure() }
                    if bytes[index] == 93 { index += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw failure() }
                _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
            }
        }
    }
}
