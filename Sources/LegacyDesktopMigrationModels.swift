import Foundation
import CryptoKit

/// Paths are only inspected after the user opens the import preview. Constructing
/// this value performs no IO and never starts the retired application.
struct LegacyDesktopMigrationSource: Equatable {
    var applicationURL: URL
    var dataDirectory: URL
    var initializationURL: URL

    static var standard: Self {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GaoSeries", isDirectory: true)
        return Self(applicationURL: URL(fileURLWithPath: "/Applications/搞桌面.app", isDirectory: true),
                    dataDirectory: support.appendingPathComponent("GaoZhuoMian", isDirectory: true),
                    initializationURL: support.appendingPathComponent("GaoZhuoMian-Initialization.json"))
    }
}

struct LegacyDesktopMigrationConflict: Codable, Equatable, Identifiable {
    var field: String
    var reason: String
    var id: String { field }
}

struct LegacyDesktopHotkeyOffer: Codable, Equatable {
    var enabledInSource: Bool
    var keyCode: UInt16
    var carbonModifiers: UInt32
    var targetModifiers: UInt64
    var conflictingBindingIDs: [UUID]

    var displayName: String {
        InputBinding(actionID: "windows.overview", keyCode: keyCode, modifiers: targetModifiers).triggerDescription
    }
}

struct LegacyDesktopMigrationIdentity: Codable, Equatable {
    var bundleID: String
    var appVersion: String
    var appBuild: Int
    var schemaVersion: Int
    var storeID: UUID
    var generation: UInt64
    var migrationHistory: [String]
    var preferencesSHA256: String
    var initializationSHA256: String
    var applicationInfoSHA256: String
    var payloadSHA256: String
    /// Schema 2 retains only the old identity's digest, never its free-form
    /// migration history. The compacted digest binds the remaining fields.
    var retiredIdentityDigest: String? = nil
    var compactedIdentityDigest: String? = nil

    var sourceID: String { bundleID + ":" + storeID.uuidString.lowercased() }
    var digest: String {
        if let retiredIdentityDigest { return retiredIdentityDigest }
        return legacyDigest
    }
    var legacyDigest: String {
        let fields = [bundleID, appVersion, String(appBuild), String(schemaVersion), storeID.uuidString.lowercased(),
                      String(generation), preferencesSHA256, initializationSHA256, applicationInfoSHA256, payloadSHA256]
            + migrationHistory
        // Length prefixes avoid ambiguous concatenation without a fallible
        // serialization fallback that could silently hash an empty value.
        let value = fields.map { String($0.utf8.count) + ":" + $0 }.joined()
        return LegacyDesktopMigrationCoding.digest(Data(value.utf8))
    }
    var migrationID: String { "desktop-" + digest }

    var computedCompactedIdentityDigest: String {
        let fields = [bundleID, appVersion, String(appBuild), String(schemaVersion), storeID.uuidString.lowercased(),
                      String(generation), preferencesSHA256, initializationSHA256, applicationInfoSHA256,
                      payloadSHA256, retiredIdentityDigest ?? ""]
        return LegacyDesktopMigrationCoding.digest(Data(fields.map { String($0.utf8.count) + ":" + $0 }.joined().utf8))
    }
}

extension LegacyDesktopMigrationIdentity {
    private enum CodingKeys: String, CodingKey {
        case bundleID, appVersion, appBuild, schemaVersion, storeID, generation, migrationHistory
        case preferencesSHA256, initializationSHA256, applicationInfoSHA256, payloadSHA256
        case identityDigest, compactedIdentityDigest
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        appBuild = try c.decode(Int.self, forKey: .appBuild)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        storeID = try c.decode(UUID.self, forKey: .storeID)
        generation = try c.decode(UInt64.self, forKey: .generation)
        preferencesSHA256 = try c.decode(String.self, forKey: .preferencesSHA256)
        initializationSHA256 = try c.decode(String.self, forKey: .initializationSHA256)
        applicationInfoSHA256 = try c.decode(String.self, forKey: .applicationInfoSHA256)
        payloadSHA256 = try c.decode(String.self, forKey: .payloadSHA256)
        retiredIdentityDigest = try c.decodeIfPresent(String.self, forKey: .identityDigest)
        compactedIdentityDigest = try c.decodeIfPresent(String.self, forKey: .compactedIdentityDigest)
        migrationHistory = retiredIdentityDigest == nil ? try c.decode([String].self, forKey: .migrationHistory) : []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID); try c.encode(appVersion, forKey: .appVersion)
        try c.encode(appBuild, forKey: .appBuild); try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(storeID, forKey: .storeID); try c.encode(generation, forKey: .generation)
        try c.encode(preferencesSHA256, forKey: .preferencesSHA256)
        try c.encode(initializationSHA256, forKey: .initializationSHA256)
        try c.encode(applicationInfoSHA256, forKey: .applicationInfoSHA256)
        try c.encode(payloadSHA256, forKey: .payloadSHA256)
        if let retiredIdentityDigest {
            try c.encode(retiredIdentityDigest, forKey: .identityDigest)
            try c.encodeIfPresent(compactedIdentityDigest, forKey: .compactedIdentityDigest)
        } else { try c.encode(migrationHistory, forKey: .migrationHistory) }
    }
}

/// Schema 1 retains source bytes only until explicit source retirement compacts
/// the journal. Schema 2 has no evidence field or raw restore material. These
/// bytes never grant a bookmark or form a replayable GaoAction request.
struct LegacyDesktopMigrationEvidence: Codable, Equatable {
    var preferences: Data
    var initialization: Data
    var applicationInfo: Data
}

struct LegacyDesktopImportPlan {
    let source: LegacyDesktopMigrationSource
    let identity: LegacyDesktopMigrationIdentity
    let sourceEvidence: LegacyDesktopMigrationEvidence
    let proposedOverview: DesktopOverviewPreferences
    let conflicts: [LegacyDesktopMigrationConflict]
    let hotkeyOffer: LegacyDesktopHotkeyOffer
    let targetSettingsSHA256: String
    let adoptSourceOverview: Bool
    let approvalDigest: String
    var migrationID: String { identity.migrationID }
}

struct LegacyDesktopImportResult {
    var settings: OperationSettings
    var alreadyApplied: Bool
    var conflicts: [LegacyDesktopMigrationConflict]
    var hotkeyOffer: LegacyDesktopHotkeyOffer
}

/// The atomic settings commit was already read back before the journal failed.
/// Callers must adopt this exact committed value in memory and retain the storage
/// failure; writing the old in-memory settings back would erase the receipt.
struct LegacyDesktopCommittedImportError: LocalizedError {
    var committedSettings: OperationSettings
    var underlyingMessage: String
    var errorDescription: String? {
        "窗口设置已提交，迁移日志尚需恢复。已保留来源和提交标识，请停止写入并复核：" + underlyingMessage
    }
}

enum LegacyDesktopMigrationFaultPoint: Equatable {
    case afterPreparedJournal, afterSettingsCommit, beforeCommittedJournal
    case beforeRetirementIntent, afterRetirementIntent, afterRetirementSwap
    case afterRetirementDisplacedRemoval, afterRetirementJournalWrite, afterRetirementReadback
}

enum LegacyDesktopMigrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let value) = self { return value }
        return nil
    }
}

enum LegacyDesktopMigrationCoding {
    static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        value.dateEncodingStrategy = .iso8601
        return value
    }
    static var decoder: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value
    }
    static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    static func settingsDigest(_ value: OperationSettings) throws -> String {
        digest(try encoder.encode(value))
    }
}

struct LegacyDesktopMigrationJournal: Codable {
    var schema = 1
    var records: [LegacyDesktopMigrationRecord] = []
    var sourceMappings: [String: [String]] = [:]
    var sha256 = ""
}

struct LegacyDesktopMigrationRecord: Codable, Identifiable {
    enum Phase: String, Codable { case prepared, committed }
    var id: String
    var phase: Phase
    var source: LegacyDesktopMigrationIdentity
    var sourceEvidence: LegacyDesktopMigrationEvidence?
    var sourceRetirement: LegacyDesktopSourceRetirementFacts? = nil
    var preparedAt: Date
    var committedAt: Date?
    var beforeSettingsSHA256: String
    var expectedAfterSettingsSHA256: String
    var approvalDigest: String
    var proposedOverview: DesktopOverviewPreferences
    var adoptSourceOverview: Bool
    var conflicts: [LegacyDesktopMigrationConflict]
    var hotkeyOffer: LegacyDesktopHotkeyOffer
}

extension LegacyDesktopMigrationRecord {
    private enum CodingKeys: String, CodingKey {
        case id, phase, source, sourceEvidence, sourceRetirement, preparedAt, committedAt
        case beforeSettingsSHA256, expectedAfterSettingsSHA256, approvalDigest
        case proposedOverview, adoptSourceOverview, conflicts, hotkeyOffer
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); phase = try c.decode(Phase.self, forKey: .phase)
        source = try c.decode(LegacyDesktopMigrationIdentity.self, forKey: .source)
        sourceEvidence = try c.decodeIfPresent(LegacyDesktopMigrationEvidence.self, forKey: .sourceEvidence)
        sourceRetirement = try c.decodeIfPresent(LegacyDesktopSourceRetirementFacts.self, forKey: .sourceRetirement)
        preparedAt = try c.decode(Date.self, forKey: .preparedAt)
        committedAt = try c.decodeIfPresent(Date.self, forKey: .committedAt)
        beforeSettingsSHA256 = try c.decode(String.self, forKey: .beforeSettingsSHA256)
        expectedAfterSettingsSHA256 = try c.decode(String.self, forKey: .expectedAfterSettingsSHA256)
        approvalDigest = try c.decode(String.self, forKey: .approvalDigest)
        proposedOverview = sourceRetirement == nil ? try c.decode(DesktopOverviewPreferences.self, forKey: .proposedOverview) : .init()
        adoptSourceOverview = try c.decode(Bool.self, forKey: .adoptSourceOverview)
        conflicts = try c.decode([LegacyDesktopMigrationConflict].self, forKey: .conflicts)
        hotkeyOffer = try c.decode(LegacyDesktopHotkeyOffer.self, forKey: .hotkeyOffer)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(phase, forKey: .phase); try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceEvidence, forKey: .sourceEvidence)
        try c.encodeIfPresent(sourceRetirement, forKey: .sourceRetirement)
        try c.encode(preparedAt, forKey: .preparedAt); try c.encodeIfPresent(committedAt, forKey: .committedAt)
        try c.encode(beforeSettingsSHA256, forKey: .beforeSettingsSHA256)
        try c.encode(expectedAfterSettingsSHA256, forKey: .expectedAfterSettingsSHA256)
        try c.encode(approvalDigest, forKey: .approvalDigest)
        if sourceRetirement == nil { try c.encode(proposedOverview, forKey: .proposedOverview) }
        try c.encode(adoptSourceOverview, forKey: .adoptSourceOverview)
        try c.encode(conflicts, forKey: .conflicts); try c.encode(hotkeyOffer, forKey: .hotkeyOffer)
    }
}
