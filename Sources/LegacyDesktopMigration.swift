import Foundation

/// Explicit, main-actor-only import. It uses the already-open target LocalData,
/// so the settings write participates in the target's normal change detection.
/// The settings receipt and new preferences are one atomic settings.json write.
/// A prepared journal is never used to restore an old whole-settings snapshot.
@MainActor
final class LegacyDesktopMigrationImporter {
    nonisolated static let journalFilename = "legacy-desktop-migration.json"
    let targetData: LocalData
    let fault: ((LegacyDesktopMigrationFaultPoint) throws -> Void)?

    init(targetData: LocalData, fault: ((LegacyDesktopMigrationFaultPoint) throws -> Void)? = nil) {
        self.targetData = targetData
        self.fault = fault
    }

    func preview(source: LegacyDesktopMigrationSource, currentSettings: OperationSettings,
                 adoptSourceOverview: Bool = false) throws -> LegacyDesktopImportPlan {
        try requireCurrentTarget(currentSettings)
        let journal = try loadJournal(settings: currentSettings)
        guard journal.schema == 1 else {
            throw LegacyDesktopMigrationError.invalid("搞桌面来源已封存，不能再读取或导入旧来源；已迁入功能继续使用。")
        }
        let validated = try LegacyDesktopValidatedSource.read(source)
        var overview = currentSettings.desktopOverview
        var conflicts: [LegacyDesktopMigrationConflict] = []
        let defaults = DesktopOverviewPreferences()
        if adoptSourceOverview, overview == defaults {
            overview = validated.overview
        } else if overview != validated.overview {
            conflicts.append(.init(field: "desktopOverview", reason: adoptSourceOverview
                ? "目标已有窗口总览设置，已保留；来源差异待手动处理。"
                : "已保留目标窗口总览设置；如需采用来源默认区域，请明确选择后重新预览。"))
        }
        // Additional exclusions can only restrict access. Never remove a target
        // exclusion and never carry an old authorization over to the target.
        overview.excludedThumbnailBundleIDs = Array(Set(overview.excludedThumbnailBundleIDs)
            .union(validated.overview.excludedThumbnailBundleIDs)).sorted()
        overview = try overview.validated()
        guard overview.excludedThumbnailBundleIDs.count <= 256 else {
            throw LegacyDesktopMigrationError.invalid("合并后的缩略图排除项超过限制，未写入设置。")
        }
        let modifier = Self.targetModifierFlags(validated.hotkeyCarbonModifiers)
        let conflicting = currentSettings.bindings.filter {
            $0.enabled && $0.trigger == .hotkey && $0.keyCode == validated.hotkeyCode
                && $0.modifiers & InputRules.modifierMask == modifier
        }.map(\.id)
        let hotkey = LegacyDesktopHotkeyOffer(enabledInSource: validated.hotkeyEnabled, keyCode: validated.hotkeyCode,
                                             carbonModifiers: validated.hotkeyCarbonModifiers,
                                             targetModifiers: modifier, conflictingBindingIDs: conflicting)
        conflicts.append(.init(field: "hotkey", reason: conflicting.isEmpty
            ? "来源快捷键仅供复核，尚未启用；需要在快捷键设置中明确添加。"
            : "来源快捷键与目标已启用规则重叠，已保留原规则，等待解决。"))
        conflicts.append(.init(field: "appearance", reason: "目标外观设置保持不变，来源外观仅归档。"))
        if validated.retainedWorkspaceCount > 0 {
            conflicts.append(.init(field: "workspaceReferences", reason: "工作区引用仅归档；文件访问须在目标应用重新正常授权。"))
        }
        if validated.retainedProbeCount > 0 {
            conflicts.append(.init(field: "capabilityProbeResults", reason: "旧能力探针仅作历史记录，不代表目标应用通过验证。"))
        }
        if journal.records.contains(where: { $0.source.sourceID == validated.identity.sourceID && $0.source.digest != validated.identity.digest }) {
            conflicts.append(.init(field: "sourceRevision", reason: "该来源已有其他代数的迁移记录；本次保留目标已修改的偏好与旧记录。"))
        }
        let targetHash = try LegacyDesktopMigrationCoding.settingsDigest(currentSettings)
        let approval = try approvalDigest(identity: validated.identity, overview: overview, conflicts: conflicts,
                                          hotkey: hotkey, targetHash: targetHash, adopt: adoptSourceOverview)
        return LegacyDesktopImportPlan(source: source, identity: validated.identity, sourceEvidence: validated.evidence,
                                       proposedOverview: overview, conflicts: conflicts, hotkeyOffer: hotkey,
                                       targetSettingsSHA256: targetHash, adoptSourceOverview: adoptSourceOverview,
                                       approvalDigest: approval)
    }

    /// Call only from the user's confirmation button with the digest of the
    /// displayed preview. Revalidates every source artifact immediately before
    /// preparing the durable journal; a stale preview never writes settings.
    func applyConfirmed(plan: LegacyDesktopImportPlan, currentSettings: OperationSettings,
                        approvedPlanDigest: String) throws -> LegacyDesktopImportResult {
        guard approvedPlanDigest == plan.approvalDigest else {
            throw LegacyDesktopMigrationError.invalid("导入确认与预览不一致，请重新预览后确认。")
        }
        try requireCurrentTarget(currentSettings)
        var journal = try loadJournal(settings: currentSettings)
        // A committed receipt is sufficient after the source was retired. This
        // also makes a repeated click idempotent without re-reading old paths.
        if currentSettings.desktopMigrationIDs.contains(plan.migrationID) {
            guard let index = journal.records.firstIndex(where: { $0.id == plan.migrationID }),
                  journal.records[index].source.digest == plan.identity.digest else {
                throw LegacyDesktopMigrationError.invalid("目标迁移标识缺少匹配日志，已停止导入，请恢复日志后复核。")
            }
            let record = journal.records[index]
            if record.phase == .prepared {
                journal.records[index].phase = .committed
                journal.records[index].committedAt = Date()
                try saveJournal(journal)
            }
            return .init(settings: currentSettings, alreadyApplied: true, conflicts: record.conflicts, hotkeyOffer: record.hotkeyOffer)
        }
        guard journal.schema == 1 else {
            throw LegacyDesktopMigrationError.invalid("搞桌面来源已封存，不能再导入旧来源。")
        }
        guard try LegacyDesktopMigrationCoding.settingsDigest(currentSettings) == plan.targetSettingsSHA256 else {
            throw LegacyDesktopMigrationError.invalid("目标设置在预览后发生变化，请重新预览；未覆盖新设置。")
        }
        let checked = try preview(source: plan.source, currentSettings: currentSettings,
                                  adoptSourceOverview: plan.adoptSourceOverview)
        guard checked.identity == plan.identity, checked.sourceEvidence == plan.sourceEvidence,
              checked.approvalDigest == plan.approvalDigest else {
            throw LegacyDesktopMigrationError.invalid("来源或导入方案已变化，请重新预览；未写入目标设置。")
        }
        var next = currentSettings
        next.desktopOverview = checked.proposedOverview
        guard next.desktopMigrationIDs.count < 128 else { throw LegacyDesktopMigrationError.invalid("迁移记录超过限制，请先复核资料。") }
        next.desktopMigrationIDs.append(checked.migrationID)
        let expectedAfter = try LegacyDesktopMigrationCoding.settingsDigest(next)
        let index: Int
        if let existing = journal.records.firstIndex(where: { $0.id == checked.migrationID }) {
            let record = journal.records[existing]
            guard record.phase == .prepared, record.beforeSettingsSHA256 == checked.targetSettingsSHA256,
                  record.expectedAfterSettingsSHA256 == expectedAfter,
                  record.approvalDigest == checked.approvalDigest else {
                throw LegacyDesktopMigrationError.invalid("已有未完成迁移与当前方案不同，已保留日志和新设置；请人工复核。")
            }
            index = existing
        } else {
            guard journal.records.count < 128,
                  !journal.records.contains(where: { $0.phase == .prepared }) else {
                throw LegacyDesktopMigrationError.invalid("已有尚未完成的迁移，请先复核或继续原迁移。")
            }
            let record = LegacyDesktopMigrationRecord(id: checked.migrationID, phase: .prepared, source: checked.identity,
                sourceEvidence: checked.sourceEvidence, preparedAt: Date(), committedAt: nil,
                beforeSettingsSHA256: checked.targetSettingsSHA256, expectedAfterSettingsSHA256: expectedAfter,
                approvalDigest: checked.approvalDigest, proposedOverview: checked.proposedOverview,
                adoptSourceOverview: checked.adoptSourceOverview, conflicts: checked.conflicts, hotkeyOffer: checked.hotkeyOffer)
            journal.records.append(record)
            journal.sourceMappings[record.source.sourceID, default: []].append(record.id)
            index = journal.records.count - 1
            try saveJournal(journal)
        }
        try fault?(.afterPreparedJournal)
        // No ordinary preference, binding, lock policy, credential, receipt or
        // business record is replaced by a source whole-database snapshot.
        try targetData.save(next, name: "settings.json")
        guard let persisted = try targetData.load("settings.json", as: OperationSettings.self),
              persisted.desktopMigrationIDs.contains(checked.migrationID),
              try LegacyDesktopMigrationCoding.settingsDigest(persisted) == expectedAfter else {
            throw LegacyDesktopMigrationError.invalid("迁移设置提交后回读不一致；已保留准备日志，请停止写入并复核。")
        }
        do {
            try fault?(.afterSettingsCommit)
            journal.records[index].phase = .committed
            journal.records[index].committedAt = Date()
            try fault?(.beforeCommittedJournal)
            try saveJournal(journal)
        } catch {
            throw LegacyDesktopCommittedImportError(committedSettings: persisted, underlyingMessage: error.localizedDescription)
        }
        return .init(settings: persisted, alreadyApplied: false, conflicts: checked.conflicts, hotkeyOffer: checked.hotkeyOffer)
    }

    /// Recover receipts only. Never enables a feature or writes settings during
    /// startup. A prepared-but-uncommitted import needs explicit user retry.
    @discardableResult
    func recoverCommittedJournals(currentSettings: OperationSettings) throws -> Int {
        try requireCurrentTarget(currentSettings)
        var journal = try loadJournal(settings: currentSettings)
        var count = 0
        for index in journal.records.indices where journal.records[index].phase == .prepared {
            let record = journal.records[index]
            if currentSettings.desktopMigrationIDs.contains(record.id) {
                journal.records[index].phase = .committed
                journal.records[index].committedAt = Date()
                count += 1
            } else if try LegacyDesktopMigrationCoding.settingsDigest(currentSettings) != record.beforeSettingsSHA256 {
                throw LegacyDesktopMigrationError.invalid("未完成导入后目标设置已有新修改；未回滚或覆盖，请人工复核迁移日志。")
            }
        }
        if count > 0 { try saveJournal(journal) }
        return count
    }

    func records(currentSettings: OperationSettings) throws -> [LegacyDesktopMigrationRecord] {
        try requireCurrentTarget(currentSettings)
        return try loadJournal(settings: currentSettings).records
    }

    func requireCurrentTarget(_ settings: OperationSettings) throws {
        _ = try settings.desktopOverview.validated()
        guard targetData.failure == nil, settings.schema == 1,
              Set(settings.desktopMigrationIDs).count == settings.desktopMigrationIDs.count,
              settings.desktopMigrationIDs.count <= 128,
              let disk = try targetData.load("settings.json", as: OperationSettings.self),
              try LegacyDesktopMigrationCoding.settingsDigest(disk) == LegacyDesktopMigrationCoding.settingsDigest(settings) else {
            throw LegacyDesktopMigrationError.invalid("目标设置缺失、不可读或与当前界面不同；未写入迁移资料。")
        }
    }

    private func loadJournal(settings: OperationSettings) throws -> LegacyDesktopMigrationJournal {
        guard try targetData.load(Self.journalFilename, as: LegacyDesktopMigrationJournal.self) != nil else {
            guard settings.desktopMigrationIDs.isEmpty else {
                throw LegacyDesktopMigrationError.invalid("目标已有迁移标识但日志缺失，不能建立空迁移日志。")
            }
            return LegacyDesktopMigrationJournal()
        }
        return try LegacyDesktopMigrationJournalValidator.decode(targetData.verifiedData(Self.journalFilename), settings: settings)
    }

    private func saveJournal(_ original: LegacyDesktopMigrationJournal) throws {
        var journal = original
        journal.sha256 = try LegacyDesktopMigrationJournalValidator.journalDigest(journal)
        try LegacyDesktopMigrationJournalValidator.validate(journal)
        try targetData.save(journal, name: Self.journalFilename)
        guard let actual = try targetData.load(Self.journalFilename, as: LegacyDesktopMigrationJournal.self),
              actual.sha256 == journal.sha256, actual.sha256 == (try LegacyDesktopMigrationJournalValidator.journalDigest(actual)) else {
            throw LegacyDesktopMigrationError.invalid("迁移日志写入后回读摘要不一致；请保留原资料并复核。")
        }
    }

    private struct Approval: Encodable {
        var identity: LegacyDesktopMigrationIdentity
        var overview: DesktopOverviewPreferences
        var conflicts: [LegacyDesktopMigrationConflict]
        var hotkey: LegacyDesktopHotkeyOffer
        var targetHash: String
        var adopt: Bool
    }
    private func approvalDigest(identity: LegacyDesktopMigrationIdentity, overview: DesktopOverviewPreferences,
                                conflicts: [LegacyDesktopMigrationConflict], hotkey: LegacyDesktopHotkeyOffer,
                                targetHash: String, adopt: Bool) throws -> String {
        LegacyDesktopMigrationCoding.digest(try LegacyDesktopMigrationCoding.encoder.encode(
            Approval(identity: identity, overview: overview, conflicts: conflicts, hotkey: hotkey, targetHash: targetHash, adopt: adopt)))
    }

    nonisolated static func targetModifierFlags(_ carbon: UInt32) -> UInt64 {
        var result: UInt64 = 0
        if carbon & 0x100 != 0 { result |= 1 << 20 } // command
        if carbon & 0x200 != 0 { result |= 1 << 17 } // shift
        if carbon & 0x800 != 0 { result |= 1 << 19 } // option
        if carbon & 0x1000 != 0 { result |= 1 << 18 } // control
        return result
    }
}
