import Foundation
import CoreFoundation

/// Raw files use Foundation's original numeric Date representation. ISO 8601
/// remains confined to the existing logical journal/settings digest codec.
enum LegacyDesktopMigrationRawCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
}

struct LegacyDesktopSourceRetirementFacts: Codable, Equatable {
    var preferencesSHA256: String
    var initializationSHA256: String
    var applicationInfoSHA256: String
    var beforeJournalRawSHA256: String
    var settingsRawSHA256: String
    /// Distinct from record.approvalDigest, which belongs to the original import.
    var retirementApprovalDigest: String
    var finalizedAt: Date
}

struct LegacyDesktopSourceRetirementPlan: Codable, Equatable {
    var schema = 1
    var targetDirectoryPath: String
    var targetDirectoryIdentity: LocalDataDirectoryIdentity
    var journalFilename: String
    var beforeJournalIdentity: LocalDataRetirementFileIdentity
    var beforeJournalRawSHA256: String
    var settingsRawSHA256: String
    var currentSettingsSHA256: String
    var migrationIDs: [String]
    var afterContentSHA256: String
    var afterExpectedRawSHA256: String
    var finalizedAt: Date
    var approvalDigest: String

    /// The output hash is derived after inserting this digest into each fact.
    /// Clearing those two derived fields avoids a self-referential hash; every
    /// finalize independently reconstructs and verifies the output bytes.
    func computedApprovalDigest() throws -> String {
        var normalized = self; normalized.approvalDigest = ""; normalized.afterExpectedRawSHA256 = ""
        return LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationRawCoding.encode(normalized))
    }

    func validated() throws -> Self {
        func failure(_ reason: String) -> LegacyDesktopMigrationError {
            .invalid("桌面来源封存方案无效（" + reason + "）；未写入任何资料。")
        }
        guard schema == 1, journalFilename == LegacyDesktopMigrationImporter.journalFilename else { throw failure("schema-or-filename") }
        guard targetDirectoryPath.hasPrefix("/"), targetDirectoryPath != "/", !targetDirectoryPath.contains("\0") else {
            throw failure("root-path")
        }
        // Match LocalData's fixed Apple-root alias normalization exactly. On
        // macOS standardizedFileURL may return /tmp or /var for /private paths;
        // LocalData deliberately stores those roots with the /private prefix.
        var normalizedPath = URL(fileURLWithPath: targetDirectoryPath).standardizedFileURL.path
        if normalizedPath == "/tmp" || normalizedPath.hasPrefix("/tmp/") { normalizedPath = "/private" + normalizedPath }
        if normalizedPath == "/var" || normalizedPath.hasPrefix("/var/") { normalizedPath = "/private" + normalizedPath }
        guard normalizedPath == targetDirectoryPath else { throw failure("canonical-root-path") }
        guard beforeJournalIdentity.size > 0, beforeJournalIdentity.sha256 == beforeJournalRawSHA256 else {
            throw failure("original-file-identity")
        }
        guard migrationIDs.count > 0, migrationIDs.count <= 128,
              Set(migrationIDs).count == migrationIDs.count,
              migrationIDs.allSatisfy(LegacyDesktopMigrationJournalValidator.isMigrationID) else { throw failure("migration-ids") }
        guard [beforeJournalRawSHA256, settingsRawSHA256, currentSettingsSHA256, afterContentSHA256, afterExpectedRawSHA256, approvalDigest]
            .allSatisfy(LegacyDesktopMigrationJournalValidator.isSHA256) else { throw failure("sha256-format") }
        guard finalizedAt.timeIntervalSinceReferenceDate.isFinite else { throw failure("finalization-time") }
        guard approvalDigest == (try computedApprovalDigest()) else { throw failure("approval-digest") }
        return self
    }

    static func decode(_ raw: Data) throws -> Self {
        try LegacyDesktopStrictJSON.validate(raw)
        let object = try LegacyDesktopMigrationJournalValidator.object(JSONSerialization.jsonObject(with: raw), keys: [
            "schema", "targetDirectoryPath", "targetDirectoryIdentity", "journalFilename", "beforeJournalIdentity",
            "beforeJournalRawSHA256", "settingsRawSHA256", "currentSettingsSHA256", "migrationIDs",
            "afterContentSHA256", "afterExpectedRawSHA256", "finalizedAt", "approvalDigest"
        ])
        _ = try LegacyDesktopMigrationJournalValidator.object(object["targetDirectoryIdentity"], keys: ["device", "inode"])
        _ = try LegacyDesktopMigrationJournalValidator.object(object["beforeJournalIdentity"], keys: ["device", "inode", "size", "sha256"])
        return try JSONDecoder().decode(Self.self, from: raw).validated()
    }
}

struct LegacyDesktopSourceRetirementResult: Codable, Equatable {
    var alreadyFinalized: Bool
    var journalRawSHA256: String
    var approvedPlanDigest: String
}

struct LegacyDesktopSourceRetirementCommittedError: LocalizedError, Codable {
    var journalSealed: Bool
    var journalCommitUncertain: Bool
    var actualJournalRawSHA256: String?
    var cleanupComplete: Bool
    var actualSettingsRawSHA256: String?
    var requiresRootReview = true
    var journalRawSHA256: String
    var approvedPlanDigest: String
    var underlyingMessage: String
    var errorDescription: String? {
        (journalSealed ? "桌面迁移日志已封存" : "桌面迁移日志已经交换或状态无法确定")
            + "，需要Root复核，不能视为退役完成：" + underlyingMessage
    }
}

/// One typed, strict validator is shared by LocalData, the production importer
/// and the maintenance CLI. It never reads a retired source location.
enum LegacyDesktopMigrationJournalValidator {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isMigrationID(_ value: String) -> Bool {
        value.hasPrefix("desktop-") && isSHA256(String(value.dropFirst(8)))
    }
    static func object(_ value: Any?, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any], keys.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: keys.union(optional)) else {
            throw LegacyDesktopMigrationError.invalid("桌面迁移字段缺失、含未知字段或混合格式；已停止写入。")
        }
        return object
    }
    static func journalDigest(_ original: LegacyDesktopMigrationJournal) throws -> String {
        var journal = original; journal.sha256 = ""
        return LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationCoding.encoder.encode(journal))
    }
    static func decode(_ raw: Data, settings: OperationSettings? = nil) throws -> LegacyDesktopMigrationJournal {
        try LegacyDesktopStrictJSON.validate(raw)
        try validateShape(raw)
        // Deliberately not LegacyDesktopMigrationCoding.decoder: persisted
        // journals have always used numeric Foundation reference-date values.
        let journal = try JSONDecoder().decode(LegacyDesktopMigrationJournal.self, from: raw)
        try validate(journal, settings: settings)
        return journal
    }
    static func validate(_ journal: LegacyDesktopMigrationJournal, settings: OperationSettings? = nil) throws {
        let ids = journal.records.map(\.id)
        guard [1, 2].contains(journal.schema), journal.records.count <= 128,
              journal.schema != 2 || !journal.records.isEmpty,
              Set(ids).count == ids.count, isSHA256(journal.sha256),
              journal.sha256 == (try journalDigest(journal)) else {
            throw LegacyDesktopMigrationError.invalid("迁移日志损坏、缺失或格式过新；已停止导入。")
        }
        if let settings {
            guard settings.desktopMigrationIDs.count <= 128,
                  Set(settings.desktopMigrationIDs).count == settings.desktopMigrationIDs.count,
                  journal.schema == 2 ? Set(ids) == Set(settings.desktopMigrationIDs)
                    : Set(settings.desktopMigrationIDs).isSubset(of: Set(ids)) else {
                throw LegacyDesktopMigrationError.invalid("桌面迁移标识与日志不一致，已停止导入。")
            }
        }
        var mapping: [String: [String]] = [:]
        var firstRetirement: LegacyDesktopSourceRetirementFacts?
        for record in journal.records {
            let source = record.source
            guard isMigrationID(record.id), record.id == source.migrationID,
                  source.schemaVersion == 1, source.bundleID == "com.gaoseries.GaoZhuoMian",
                  source.appVersion == "1.00", source.appBuild == 1, source.generation > 0,
                  [source.preferencesSHA256, source.initializationSHA256, source.applicationInfoSHA256, source.payloadSHA256,
                   record.beforeSettingsSHA256, record.expectedAfterSettingsSHA256, record.approvalDigest].allSatisfy(isSHA256),
                  record.preparedAt.timeIntervalSinceReferenceDate.isFinite,
                  record.committedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false,
                  record.phase != .committed || (record.committedAt != nil && (settings?.desktopMigrationIDs.contains(record.id) ?? true)),
                  record.conflicts.count <= 256, Set(record.conflicts.map(\.field)).count == record.conflicts.count,
                  record.conflicts.allSatisfy({ !$0.field.isEmpty && $0.field.utf8.count <= 256 && $0.reason.utf8.count <= 4096 }),
                  record.hotkeyOffer.keyCode <= 127,
                  record.hotkeyOffer.carbonModifiers & ~UInt32(0x1b00) == 0,
                  record.hotkeyOffer.targetModifiers == LegacyDesktopMigrationImporter.targetModifierFlags(record.hotkeyOffer.carbonModifiers),
                  record.hotkeyOffer.conflictingBindingIDs.count <= 1024,
                  Set(record.hotkeyOffer.conflictingBindingIDs).count == record.hotkeyOffer.conflictingBindingIDs.count else {
                throw LegacyDesktopMigrationError.invalid("迁移日志的来源身份、业务记录或提交标识不一致，已停止导入。")
            }
            if journal.schema == 1 {
                guard let evidence = record.sourceEvidence, record.sourceRetirement == nil,
                      source.retiredIdentityDigest == nil, source.compactedIdentityDigest == nil,
                      source.migrationHistory.count <= 128,
                      source.migrationHistory.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
                      evidence.preferences.count <= 1_048_576, evidence.initialization.count <= 1_048_576,
                      evidence.applicationInfo.count <= 1_048_576,
                      LegacyDesktopMigrationCoding.digest(evidence.preferences) == source.preferencesSHA256,
                      LegacyDesktopMigrationCoding.digest(evidence.initialization) == source.initializationSHA256,
                      LegacyDesktopMigrationCoding.digest(evidence.applicationInfo) == source.applicationInfoSHA256 else {
                    throw LegacyDesktopMigrationError.invalid("迁移日志的原始来源证据不一致，已停止导入。")
                }
                _ = try record.proposedOverview.validated()
            } else {
                guard record.phase == .committed, record.sourceEvidence == nil,
                      let facts = record.sourceRetirement, source.migrationHistory.isEmpty,
                      source.retiredIdentityDigest.map(isSHA256) == true,
                      source.compactedIdentityDigest == source.computedCompactedIdentityDigest,
                      facts.preferencesSHA256 == source.preferencesSHA256,
                      facts.initializationSHA256 == source.initializationSHA256,
                      facts.applicationInfoSHA256 == source.applicationInfoSHA256,
                      [facts.beforeJournalRawSHA256, facts.settingsRawSHA256, facts.retirementApprovalDigest].allSatisfy(isSHA256),
                      facts.finalizedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw LegacyDesktopMigrationError.invalid("封存日志仍含原件、半封存记录或无效事实，已停止导入。")
                }
                if let first = firstRetirement {
                    guard first.beforeJournalRawSHA256 == facts.beforeJournalRawSHA256,
                          first.settingsRawSHA256 == facts.settingsRawSHA256,
                          first.retirementApprovalDigest == facts.retirementApprovalDigest,
                          first.finalizedAt == facts.finalizedAt else {
                        throw LegacyDesktopMigrationError.invalid("封存日志混合了不同事务，已停止导入。")
                    }
                } else { firstRetirement = facts }
            }
            mapping[source.sourceID, default: []].append(record.id)
        }
        guard mapping == journal.sourceMappings else {
            throw LegacyDesktopMigrationError.invalid("迁移来源映射不一致，已停止导入。")
        }
    }

    private static func validateShape(_ raw: Data) throws {
        let root = try object(JSONSerialization.jsonObject(with: raw), keys: ["schema", "records", "sourceMappings", "sha256"])
        guard let number = root["schema"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              [1.0, 2.0].contains(number.doubleValue), let records = root["records"] as? [Any],
              root["sourceMappings"] is [String: Any] else {
            throw LegacyDesktopMigrationError.invalid("桌面迁移日志格式不受支持，已停止导入。")
        }
        let schema = number.intValue
        let base: Set<String> = ["id", "phase", "source", "preparedAt", "beforeSettingsSHA256", "expectedAfterSettingsSHA256",
                                 "approvalDigest", "adoptSourceOverview", "conflicts", "hotkeyOffer"]
        let sourceBase: Set<String> = ["bundleID", "appVersion", "appBuild", "schemaVersion", "storeID", "generation",
                                       "preferencesSHA256", "initializationSHA256", "applicationInfoSHA256", "payloadSHA256"]
        for value in records {
            let record = try object(value, keys: base.union(schema == 1 ? ["sourceEvidence", "proposedOverview"] : ["sourceRetirement", "committedAt"]),
                                    optional: schema == 1 ? ["committedAt"] : [])
            if let date = record["committedAt"] {
                guard let n = date as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                    throw LegacyDesktopMigrationError.invalid("桌面迁移提交时间无效。")
                }
            }
            _ = try object(record["source"], keys: sourceBase.union(schema == 1 ? ["migrationHistory"] : ["identityDigest", "compactedIdentityDigest"]))
            if schema == 1 {
                _ = try object(record["sourceEvidence"], keys: ["preferences", "initialization", "applicationInfo"])
                _ = try object(record["proposedOverview"], keys: ["groupByApplication", "compactChooser", "excludedThumbnailBundleIDs", "excludedApplicationBundleIDs", "thumbnailsEnabled", "statusStripEnabled"])
            } else {
                _ = try object(record["sourceRetirement"], keys: ["preferencesSHA256", "initializationSHA256", "applicationInfoSHA256", "beforeJournalRawSHA256", "settingsRawSHA256", "retirementApprovalDigest", "finalizedAt"])
            }
            _ = try object(record["hotkeyOffer"], keys: ["enabledInSource", "keyCode", "carbonModifiers", "targetModifiers", "conflictingBindingIDs"])
            guard let conflicts = record["conflicts"] as? [Any] else { throw LegacyDesktopMigrationError.invalid("迁移冲突记录无效。") }
            for conflict in conflicts { _ = try object(conflict, keys: ["field", "reason"]) }
        }
    }
}

extension LegacyDesktopMigrationImporter {
    func retirementPreview(currentSettings: OperationSettings, finalizedAt: Date = Date()) throws -> LegacyDesktopSourceRetirementPlan {
        try requireCurrentTarget(currentSettings)
        let settingsRaw = try targetData.verifiedData("settings.json")
        let snapshot = try targetData.retirementFileSnapshot(Self.journalFilename)
        let journal = try LegacyDesktopMigrationJournalValidator.decode(snapshot.data, settings: currentSettings)
        guard journal.schema == 1, !journal.records.isEmpty,
              journal.records.allSatisfy({ $0.phase == .committed }),
              Set(journal.records.map(\.id)) == Set(currentSettings.desktopMigrationIDs) else {
            throw LegacyDesktopMigrationError.invalid("只可封存全部已提交且标识完整的旧桌面日志；未写入任何资料。")
        }
        var plan = LegacyDesktopSourceRetirementPlan(targetDirectoryPath: targetData.directory.path,
            targetDirectoryIdentity: try targetData.verifiedDirectoryIdentity(), journalFilename: Self.journalFilename,
            beforeJournalIdentity: snapshot.identity, beforeJournalRawSHA256: snapshot.identity.sha256,
            settingsRawSHA256: LegacyDesktopMigrationCoding.digest(settingsRaw),
            currentSettingsSHA256: try LegacyDesktopMigrationCoding.settingsDigest(currentSettings),
            migrationIDs: journal.records.map(\.id), afterContentSHA256: "", afterExpectedRawSHA256: "",
            finalizedAt: finalizedAt, approvalDigest: String(repeating: "0", count: 64))
        plan.afterContentSHA256 = try retirementContentDigest(compactedJournal(journal, plan: plan))
        plan.approvalDigest = try plan.computedApprovalDigest()
        let after = try compactedJournal(journal, plan: plan)
        plan.afterExpectedRawSHA256 = LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationRawCoding.encode(after))
        _ = try plan.validated()
        guard try targetData.retirementFileSnapshot(Self.journalFilename).identity == snapshot.identity,
              LegacyDesktopMigrationCoding.digest(try targetData.verifiedData("settings.json")) == plan.settingsRawSHA256 else {
            throw LegacyDesktopMigrationError.invalid("预览期间桌面日志或设置已变化；请重新预览。")
        }
        return plan
    }

    func finalizeSourceRetirement(plan originalPlan: LegacyDesktopSourceRetirementPlan, currentSettings: OperationSettings,
                                  approvedPlanDigest: String) throws -> LegacyDesktopSourceRetirementResult {
        let plan = try originalPlan.validated()
        guard approvedPlanDigest == plan.approvalDigest,
              targetData.directory.path == plan.targetDirectoryPath,
              try targetData.verifiedDirectoryIdentity() == plan.targetDirectoryIdentity else {
            throw LegacyDesktopMigrationError.invalid("封存确认或目标根身份与预览不同；未写入资料。")
        }
        let snapshot = try targetData.retirementFileSnapshot(Self.journalFilename)
        let journal = try LegacyDesktopMigrationJournalValidator.decode(snapshot.data)
        let alreadyFinalized = journal.schema == 2
        let after: LegacyDesktopMigrationJournal
        if alreadyFinalized {
            guard snapshot.identity.sha256 == plan.afterExpectedRawSHA256 else {
                throw LegacyDesktopMigrationError.invalid("已封存日志不属于这份方案，拒绝继续。")
            }
            try requireMatchingRetirement(journal, plan: plan)
            after = journal
        } else {
            guard snapshot.identity == plan.beforeJournalIdentity,
                  snapshot.identity.sha256 == plan.beforeJournalRawSHA256 else {
                throw LegacyDesktopMigrationError.invalid("桌面日志在预览后已变化；未封存。")
            }
            try requireRetirementSettings(currentSettings, plan: plan)
            try LegacyDesktopMigrationJournalValidator.validate(journal, settings: currentSettings)
            after = try compactedJournal(journal, plan: plan)
        }
        let bytes = try LegacyDesktopMigrationRawCoding.encode(after)
        guard try retirementContentDigest(after) == plan.afterContentSHA256,
              LegacyDesktopMigrationCoding.digest(bytes) == plan.afterExpectedRawSHA256 else {
            throw LegacyDesktopMigrationError.invalid("封存后的预期字节摘要不一致；未写入资料。")
        }
        do {
            try targetData.retireLegacyDesktopJournal(bytes, plan: plan, beforeCommit: {
                try self.requireRetirementSettings(currentSettings, plan: plan)
            }, fault: fault)
        } catch let error as LocalDataRetirementWriteError {
            if error.journalCommitted { throw committedRetirementError(plan, error, cleanupComplete: error.cleanupComplete) }
            throw error
        }
        do {
            try fault?(.afterRetirementJournalWrite)
            let persisted = try targetData.verifiedData(Self.journalFilename)
            guard LegacyDesktopMigrationCoding.digest(persisted) == plan.afterExpectedRawSHA256 else {
                throw LegacyDesktopMigrationError.invalid("封存日志回读摘要不一致。")
            }
            let checked = try LegacyDesktopMigrationJournalValidator.decode(persisted, settings: currentSettings)
            try requireMatchingRetirement(checked, plan: plan)
            try fault?(.afterRetirementReadback)
            // Historical CAS only: normal schema-2 readers never pin settings
            // to this hash, and may accept later ordinary preference changes.
            try requireRetirementSettings(currentSettings, plan: plan)
        } catch { throw committedRetirementError(plan, error, cleanupComplete: true) }
        return .init(alreadyFinalized: alreadyFinalized, journalRawSHA256: plan.afterExpectedRawSHA256,
                     approvedPlanDigest: plan.approvalDigest)
    }

    private func requireRetirementSettings(_ settings: OperationSettings, plan: LegacyDesktopSourceRetirementPlan) throws {
        try requireCurrentTarget(settings)
        guard try LegacyDesktopMigrationCoding.settingsDigest(settings) == plan.currentSettingsSHA256,
              LegacyDesktopMigrationCoding.digest(try targetData.verifiedData("settings.json")) == plan.settingsRawSHA256,
              Set(settings.desktopMigrationIDs) == Set(plan.migrationIDs) else {
            throw LegacyDesktopMigrationError.invalid("目标设置已变化；封存事务需要复核，未回写旧设置。")
        }
    }
    private func compactedJournal(_ original: LegacyDesktopMigrationJournal, plan: LegacyDesktopSourceRetirementPlan) throws -> LegacyDesktopMigrationJournal {
        guard original.schema == 1, !original.records.isEmpty, original.records.map(\.id) == plan.migrationIDs,
              original.records.allSatisfy({ $0.phase == .committed && $0.committedAt != nil && $0.sourceEvidence != nil }) else {
            throw LegacyDesktopMigrationError.invalid("旧日志存在未提交或缺失原件的记录，拒绝封存。")
        }
        var result = original; result.schema = 2
        for index in result.records.indices {
            let digest = result.records[index].source.digest
            result.records[index].source.retiredIdentityDigest = digest
            result.records[index].source.migrationHistory = []
            result.records[index].source.compactedIdentityDigest = result.records[index].source.computedCompactedIdentityDigest
            result.records[index].sourceEvidence = nil
            result.records[index].proposedOverview = .init()
            let source = result.records[index].source
            result.records[index].sourceRetirement = .init(preferencesSHA256: source.preferencesSHA256,
                initializationSHA256: source.initializationSHA256, applicationInfoSHA256: source.applicationInfoSHA256,
                beforeJournalRawSHA256: plan.beforeJournalRawSHA256, settingsRawSHA256: plan.settingsRawSHA256,
                retirementApprovalDigest: plan.approvalDigest, finalizedAt: plan.finalizedAt)
        }
        result.sha256 = try LegacyDesktopMigrationJournalValidator.journalDigest(result)
        try LegacyDesktopMigrationJournalValidator.validate(result)
        return result
    }
    private func requireMatchingRetirement(_ journal: LegacyDesktopMigrationJournal, plan: LegacyDesktopSourceRetirementPlan) throws {
        guard journal.schema == 2, journal.records.map(\.id) == plan.migrationIDs,
              try retirementContentDigest(journal) == plan.afterContentSHA256,
              journal.records.allSatisfy({ record in
                  guard let fact = record.sourceRetirement else { return false }
                  return fact.beforeJournalRawSHA256 == plan.beforeJournalRawSHA256
                      && fact.settingsRawSHA256 == plan.settingsRawSHA256
                      && fact.retirementApprovalDigest == plan.approvalDigest && fact.finalizedAt == plan.finalizedAt
              }) else { throw LegacyDesktopMigrationError.invalid("封存日志的事实与确认方案不同。") }
    }
    private func retirementContentDigest(_ journal: LegacyDesktopMigrationJournal) throws -> String {
        var normalized = journal; normalized.sha256 = ""
        for index in normalized.records.indices { normalized.records[index].sourceRetirement?.retirementApprovalDigest = "" }
        return LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationRawCoding.encode(normalized))
    }
    private func committedRetirementError(_ plan: LegacyDesktopSourceRetirementPlan, _ error: Error,
                                          cleanupComplete: Bool) -> LegacyDesktopSourceRetirementCommittedError {
        let actualSettingsSHA = observedRetirementSHA("settings.json", plan: plan)
        let actualJournalSHA = observedRetirementSHA(Self.journalFilename, plan: plan)
        return .init(journalSealed: actualJournalSHA == plan.afterExpectedRawSHA256,
              journalCommitUncertain: actualJournalSHA == nil, actualJournalRawSHA256: actualJournalSHA,
              cleanupComplete: cleanupComplete, actualSettingsRawSHA256: actualSettingsSHA,
              journalRawSHA256: plan.afterExpectedRawSHA256, approvedPlanDigest: plan.approvalDigest,
              underlyingMessage: error.localizedDescription)
    }
    private func observedRetirementSHA(_ name: String, plan: LegacyDesktopSourceRetirementPlan) -> String? {
        let reopened = LocalData(directory: targetData.directory, createIfMissing: false)
        guard (try? reopened.verifiedDirectoryIdentity()) == plan.targetDirectoryIdentity else { return nil }
        return (try? reopened.verifiedData(name)).map(LegacyDesktopMigrationCoding.digest)
    }
}
