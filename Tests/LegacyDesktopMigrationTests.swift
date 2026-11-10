import Foundation
import Darwin

private enum LegacyDesktopFixtureFailure: Error { case injected }

private struct LegacyDesktopMigrationFixture {
    struct Hotkey: Codable { var keyCode: UInt32 = 49; var modifiers: UInt32 = 0x1800 }
    struct Workspace: Codable {
        var id = UUID(); var displayName = "合成工作区"; var fileURL: URL
        var createdAt = Date(timeIntervalSince1970: 1_000)
    }
    struct Probe: Codable {
        var id = UUID(); var observedAt = Date(timeIntervalSince1970: 1_000)
        var capability = "SYNTHETIC"; var outcome = "NOT_RUN"; var evidenceCode = "FIXTURE_ONLY"
    }
    struct Preferences: Codable {
        var appearance = "dark"
        var thumbnailsEnabled = true
        var excludedThumbnailBundleIDs = ["com.example.private"]
        var hotkeyEnabled = true
        var hotkey = Hotkey()
        var groupByApplication = false
        var compactChooser = true
        var notchEnabled = true
        var workspaceReferences: [Workspace] = []
        var capabilityProbeResults: [Probe] = []
    }
    struct Payload: Codable {
        var schemaVersion = 1
        var storeID = UUID()
        var generation: UInt64 = 7
        var migrationHistory = ["initial-schema-1"]
        var preferences = Preferences()
    }
    struct Envelope: Codable { var payload: Payload; var sha256: String }
    struct Marker: Codable { var schemaVersion = 1; var storeID: UUID; var createdAt = Date(timeIntervalSince1970: 1_000) }

    var directory: URL
    var source: LegacyDesktopMigrationSource
    var payload: Payload

    init(directory: URL, withReferences: Bool = false) throws {
        self.directory = directory
        source = .init(applicationURL: directory.appendingPathComponent("SourceApplicationEvidence", isDirectory: true),
                       dataDirectory: directory.appendingPathComponent("SourceData", isDirectory: true),
                       initializationURL: directory.appendingPathComponent("SourceInitialization.json"))
        payload = Payload()
        if withReferences {
            payload.preferences.workspaceReferences = [.init(fileURL: directory.appendingPathComponent("NeverOpenedSyntheticWorkspace"))]
            payload.preferences.capabilityProbeResults = [.init()]
        }
        try FileManager.default.createDirectory(at: source.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: source.applicationURL.appendingPathComponent("Contents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeSource()
        let info: [String: String] = ["CFBundleIdentifier": "com.gaoseries.GaoZhuoMian", "CFBundleExecutable": "GaoZhuoMian", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.00", "CFBundleVersion": "1"]
        try privateWrite(PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                         to: source.applicationURL.appendingPathComponent("Contents/Info.plist"))
    }

    func writeSource() throws {
        let encoder = LegacyDesktopMigrationCoding.encoder
        let envelope = Envelope(payload: payload, sha256: LegacyDesktopMigrationCoding.digest(try encoder.encode(payload)))
        try privateWrite(encoder.encode(envelope), to: source.dataDirectory.appendingPathComponent("preferences.json"))
        try privateWrite(encoder.encode(Marker(storeID: payload.storeID)), to: source.initializationURL)
    }

    func privateWrite(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor func runLegacyDesktopMigrationTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyDesktopMigration-\(UUID().uuidString).noindex", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw LegacyDesktopMigrationError.invalid("桌面迁移定向检查：" + message) }
    }
    func fails(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw LegacyDesktopMigrationError.invalid("桌面迁移应拒绝：" + message)
    }
    func target(_ name: String, settings: OperationSettings) throws -> LocalData {
        let data = LocalData(directory: root.appendingPathComponent(name, isDirectory: true))
        _ = try data.load("settings.json", as: OperationSettings.self)
        try data.save(settings, name: "settings.json")
        return data
    }
    func canonical(_ settings: OperationSettings) throws -> Data { try LegacyDesktopMigrationCoding.encoder.encode(settings) }
    func sourceBytes(_ fixture: LegacyDesktopMigrationFixture) throws -> [Data] {
        try [Data(contentsOf: fixture.source.dataDirectory.appendingPathComponent("preferences.json")),
             Data(contentsOf: fixture.source.initializationURL),
             Data(contentsOf: fixture.source.applicationURL.appendingPathComponent("Contents/Info.plist"))]
    }

    let fixture = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("Normal"), withReferences: true)
    var original = OperationSettings()
    original.appearance = "light"
    original.clipboardEnabled = false
    original.inputExcludedApps = ["com.example.preserve-input"]
    original.bindings.append(InputBinding(actionID: "panel.show", keyCode: 49,
                                        modifiers: LegacyDesktopMigrationImporter.targetModifierFlags(0x1800)))
    let bytesBefore = try sourceBytes(fixture)
    let data = try target("Target", settings: original)
    let importer = LegacyDesktopMigrationImporter(targetData: data)
    let preview = try importer.preview(source: fixture.source, currentSettings: original)
    try check(preview.proposedOverview.groupByApplication == original.desktopOverview.groupByApplication,
              "默认预览保留目标总览设置，采用来源需要明确选择")
    try check(preview.proposedOverview.excludedThumbnailBundleIDs == ["com.example.private"], "来源隐私排除只增加")
    try check(preview.hotkeyOffer.conflictingBindingIDs == [original.bindings.last!.id], "Carbon热键正确转换并标记已用组合")
    try check(preview.conflicts.contains(where: { $0.field == "workspaceReferences" }), "旧引用须重新授权")
    try check(preview.conflicts.contains(where: { $0.field == "capabilityProbeResults" }), "旧探针不算目标验收")
    try check(!FileManager.default.fileExists(atPath: data.directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename).path), "预览不建立迁移日志或提交设置")
    let plan = try importer.preview(source: fixture.source, currentSettings: original, adoptSourceOverview: true)
    try fails("缺少匹配明确确认") { _ = try importer.applyConfirmed(plan: plan, currentSettings: original, approvedPlanDigest: "wrong") }
    try check(try canonical(data.load("settings.json", as: OperationSettings.self)!) == canonical(original), "拒绝确认时设置原样保留")
    let result = try importer.applyConfirmed(plan: plan, currentSettings: original, approvedPlanDigest: plan.approvalDigest)
    try check(!result.alreadyApplied && result.settings.desktopMigrationIDs == [plan.migrationID], "原子设置包含唯一迁移标识")
    try check(!result.settings.desktopOverview.groupByApplication && result.settings.desktopOverview.compactChooser, "明确接纳源总览偏好")
    try check(result.settings.desktopOverview.thumbnailsEnabled, "保留源缩略图偏好本身")
    try check(result.settings.desktopOverview.statusStripEnabled, "明确采用时保留来源公开自有状态条偏好")
    try check(result.settings.appearance == "light" && result.settings.bindings == original.bindings,
              "目标外观和全部热键保持")
    var expected = original
    expected.desktopOverview = plan.proposedOverview
    expected.desktopMigrationIDs = [plan.migrationID]
    try check(try canonical(result.settings) == canonical(expected), "除总览和receipt之外的目标业务、锁策略及设置完整保留")
    let records = try importer.records(currentSettings: result.settings)
    try check(records.count == 1 && records[0].phase == .committed, "日志已完成")
    try check(records[0].sourceEvidence?.preferences == bytesBefore[0] && records[0].sourceEvidence?.initialization == bytesBefore[1], "真实导入证据存目标私有日志")
    try check(try sourceBytes(fixture) == bytesBefore, "只读来源没有变化")
    try FileManager.default.removeItem(at: fixture.directory)
    let again = try importer.applyConfirmed(plan: plan, currentSettings: result.settings, approvedPlanDigest: plan.approvalDigest)
    try check(again.alreadyApplied && again.settings.desktopMigrationIDs.count == 1, "来源退休后重复确认幂等且不读旧目录")
    try check(try importer.recoverCommittedJournals(currentSettings: again.settings) == 0, "已完成日志恢复不重放")

    // Existing nondefault overview values always survive an import; source
    // exclusions only add restrictions and never remove target exclusions.
    let conflictFixture = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("Conflicts"))
    var configured = OperationSettings()
    configured.desktopOverview.excludedApplicationBundleIDs = ["com.example.hidden"]
    configured.desktopOverview.excludedThumbnailBundleIDs = ["com.example.target-private"]
    let configuredData = try target("ConfiguredTarget", settings: configured)
    let conflictImporter = LegacyDesktopMigrationImporter(targetData: configuredData)
    let conflictPlan = try conflictImporter.preview(source: conflictFixture.source, currentSettings: configured, adoptSourceOverview: true)
    try check(conflictPlan.proposedOverview.groupByApplication && !conflictPlan.proposedOverview.compactChooser, "明确采用也不静默覆盖已配置目标")
    try check(Set(conflictPlan.proposedOverview.excludedThumbnailBundleIDs) == ["com.example.private", "com.example.target-private"], "目标和来源排除项均保留")
    try check(conflictPlan.proposedOverview.excludedApplicationBundleIDs == ["com.example.hidden"], "目标应用排除保持")
    try check(!conflictPlan.proposedOverview.statusStripEnabled, "目标已配置时不覆盖状态条偏好")
    try check(conflictPlan.conflicts.contains(where: { $0.field == "desktopOverview" }), "偏好冲突持久待解决")
    let preserved = try conflictImporter.applyConfirmed(plan: conflictPlan, currentSettings: configured,
                                                       approvedPlanDigest: conflictPlan.approvalDigest)
    var expectedConfigured = configured
    expectedConfigured.desktopOverview.excludedThumbnailBundleIDs = conflictPlan.proposedOverview.excludedThumbnailBundleIDs
    expectedConfigured.desktopMigrationIDs = [conflictPlan.migrationID]
    try check(try canonical(preserved.settings) == canonical(expectedConfigured), "冲突导入只补充隐私排除和receipt，不覆盖目标其他偏好")
    try check(try conflictImporter.records(currentSettings: preserved.settings).first?.conflicts.contains(where: { $0.field == "desktopOverview" }) == true,
              "目标冲突持久保留在journal供后续复核")

    // Every durable fault point is exercised with synthetic source/settings.
    for point in [LegacyDesktopMigrationFaultPoint.afterPreparedJournal, .afterSettingsCommit, .beforeCommittedJournal] {
        let name = String(describing: point)
        let faultFixture = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("FaultSource-" + name))
        let baseline = OperationSettings()
        let faultData = try target("FaultTarget-" + name, settings: baseline)
        let broken = LegacyDesktopMigrationImporter(targetData: faultData, fault: { if $0 == point { throw LegacyDesktopFixtureFailure.injected } })
        let faultPlan = try broken.preview(source: faultFixture.source, currentSettings: baseline, adoptSourceOverview: true)
        var committedError: LegacyDesktopCommittedImportError?
        try fails("注入中断 " + name) {
            do { _ = try broken.applyConfirmed(plan: faultPlan, currentSettings: baseline, approvedPlanDigest: faultPlan.approvalDigest) }
            catch let error as LegacyDesktopCommittedImportError { committedError = error; throw error }
        }
        let reopened = LocalData(directory: faultData.directory, createIfMissing: false)
        let disk = try reopened.load("settings.json", as: OperationSettings.self)!
        let recovered = LegacyDesktopMigrationImporter(targetData: reopened)
        if point == .afterPreparedJournal {
            try check(committedError == nil, "提交前故障不声称设置已提交")
            try check(try canonical(disk) == canonical(baseline), "提交前中断目标设置完整保留")
            try check(try recovered.recoverCommittedJournals(currentSettings: disk) == 0, "prepared不自动提交")
            let retry = try recovered.preview(source: faultFixture.source, currentSettings: disk, adoptSourceOverview: true)
            let retried = try recovered.applyConfirmed(plan: retry, currentSettings: disk, approvedPlanDigest: retry.approvalDigest)
            try check(retried.settings.desktopMigrationIDs.count == 1 && !retried.alreadyApplied, "中断后用户明确重试只提交一次")
        } else {
            try check(committedError?.committedSettings.desktopMigrationIDs == [faultPlan.migrationID], "提交后错误携带已精确回读设置，防止旧界面内存回写")
            try check(disk.desktopMigrationIDs == [faultPlan.migrationID], "提交后故障receipt仍在")
            var changed = disk
            changed.appearance = "dark"
            try reopened.save(changed, name: "settings.json")
            try FileManager.default.removeItem(at: faultFixture.directory)
            try check(try recovered.recoverCommittedJournals(currentSettings: changed) == 1, "源退休后根据已提交receipt恢复日志")
            let reread = try reopened.load("settings.json", as: OperationSettings.self)!
            try check(try canonical(reread) == canonical(changed), "恢复不会整库回滚或丢弃提交后的新修改")
            let duplicate = try recovered.applyConfirmed(plan: faultPlan, currentSettings: changed, approvedPlanDigest: faultPlan.approvalDigest)
            try check(duplicate.alreadyApplied && duplicate.settings.appearance == "dark", "故障重试不重放也不覆盖新偏好")
        }
    }

    // A new target edit after preparing an import is never overwritten by the
    // pre-import snapshot, even when the same source is still available.
    let changedFixture = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("ChangedSource"))
    let changedBaseline = OperationSettings()
    let changedData = try target("ChangedTarget", settings: changedBaseline)
    let interrupted = LegacyDesktopMigrationImporter(targetData: changedData, fault: { if $0 == .afterPreparedJournal { throw LegacyDesktopFixtureFailure.injected } })
    let changedPlan = try interrupted.preview(source: changedFixture.source, currentSettings: changedBaseline)
    try fails("中断准备") { _ = try interrupted.applyConfirmed(plan: changedPlan, currentSettings: changedBaseline, approvedPlanDigest: changedPlan.approvalDigest) }
    var newer = changedBaseline; newer.appearance = "dark"
    try changedData.save(newer, name: "settings.json")
    let changedRecovery = LegacyDesktopMigrationImporter(targetData: changedData)
    try fails("prepared后目标另变") { _ = try changedRecovery.recoverCommittedJournals(currentSettings: newer) }
    try fails("旧预览不得覆盖目标新设置") { _ = try changedRecovery.applyConfirmed(plan: changedPlan, currentSettings: newer, approvedPlanDigest: changedPlan.approvalDigest) }
    try check(try canonical(changedData.load("settings.json", as: OperationSettings.self)!) == canonical(newer), "目标另变拒写保持现物")

    // Invalid and unsupported source artifacts reject before any target journal
    // or settings write. These mutations never touch a real source directory.
    for mutation in ["missingPreferences", "missingMarker", "wrongStore", "hash", "futureSchema", "futureApp", "wrongBundle", "duplicateKeys", "missingField", "unknownField", "linkedFile", "writableFile"] {
        var invalid = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("Invalid-" + mutation))
        let prefURL = invalid.source.dataDirectory.appendingPathComponent("preferences.json")
        let infoURL = invalid.source.applicationURL.appendingPathComponent("Contents/Info.plist")
        switch mutation {
        case "missingPreferences": try FileManager.default.removeItem(at: prefURL)
        case "missingMarker": try FileManager.default.removeItem(at: invalid.source.initializationURL)
        case "wrongStore":
            let marker = LegacyDesktopMigrationFixture.Marker(storeID: UUID())
            try invalid.privateWrite(LegacyDesktopMigrationCoding.encoder.encode(marker), to: invalid.source.initializationURL)
        case "hash":
            let envelope = LegacyDesktopMigrationFixture.Envelope(payload: invalid.payload, sha256: String(repeating: "0", count: 64))
            try invalid.privateWrite(LegacyDesktopMigrationCoding.encoder.encode(envelope), to: prefURL)
        case "futureSchema": invalid.payload.schemaVersion = 2; try invalid.writeSource()
        case "futureApp", "wrongBundle":
            let info = ["CFBundleIdentifier": mutation == "wrongBundle" ? "com.example.wrong" : "com.gaoseries.GaoZhuoMian", "CFBundleExecutable": "GaoZhuoMian", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": mutation == "futureApp" ? "1.01" : "1.00", "CFBundleVersion": "1"]
            try invalid.privateWrite(PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0), to: infoURL)
        case "duplicateKeys":
            let bytes = try Data(contentsOf: prefURL)
            var string = String(decoding: bytes, as: UTF8.self)
            string = string.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
            try invalid.privateWrite(Data(string.utf8), to: prefURL)
        case "missingField", "unknownField":
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: prefURL)) as! [String: Any]
            var payload = object["payload"] as! [String: Any]
            var preferences = payload["preferences"] as! [String: Any]
            if mutation == "missingField" { preferences.removeValue(forKey: "hotkeyEnabled") }
            else { preferences["futurePolicy"] = true }
            payload["preferences"] = preferences; object["payload"] = payload
            try invalid.privateWrite(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: prefURL)
        case "linkedFile":
            let held = invalid.directory.appendingPathComponent("HeldPreferences.json")
            try FileManager.default.moveItem(at: prefURL, to: held)
            try FileManager.default.createSymbolicLink(at: prefURL, withDestinationURL: held)
        case "writableFile": try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: prefURL.path)
        default: break
        }
        let clean = OperationSettings()
        let invalidTarget = try target("InvalidTarget-" + mutation, settings: clean)
        let originalTargetBytes = try Data(contentsOf: invalidTarget.directory.appendingPathComponent("settings.json"))
        let invalidImporter = LegacyDesktopMigrationImporter(targetData: invalidTarget)
        try fails(mutation) { _ = try invalidImporter.preview(source: invalid.source, currentSettings: clean, adoptSourceOverview: true) }
        try check(try Data(contentsOf: invalidTarget.directory.appendingPathComponent("settings.json")) == originalTargetBytes, "无效源保留目标 " + mutation)
        try check(!FileManager.default.fileExists(atPath: invalidTarget.directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename).path), "无效源不建空日志 " + mutation)
    }

    let staleFixture = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("StaleSource"))
    let staleSettings = OperationSettings()
    let staleData = try target("StaleTarget", settings: staleSettings)
    let staleImporter = LegacyDesktopMigrationImporter(targetData: staleData)
    let stalePlan = try staleImporter.preview(source: staleFixture.source, currentSettings: staleSettings)
    var revised = staleFixture; revised.payload.generation += 1; try revised.writeSource()
    try fails("预览后源代数变化") { _ = try staleImporter.applyConfirmed(plan: stalePlan, currentSettings: staleSettings, approvedPlanDigest: stalePlan.approvalDigest) }
    try check(!FileManager.default.fileExists(atPath: staleData.directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename).path), "过时预览不写准备日志")

    let orphanData = LocalData(directory: root.appendingPathComponent("OrphanTarget"))
    try fails("目标没有原设置不能空白创建") { _ = try LegacyDesktopMigrationImporter(targetData: orphanData).preview(source: staleFixture.source, currentSettings: OperationSettings()) }
    try check(!FileManager.default.fileExists(atPath: orphanData.directory.appendingPathComponent("settings.json").path), "目标设置缺失不创建默认值")

    // Journal loss, corruption and unsupported schema are independently fatal.
    for mutation in ["missing", "corrupt", "future"] {
        let source = try LegacyDesktopMigrationFixture(directory: root.appendingPathComponent("JournalSource-" + mutation))
        let baseline = OperationSettings()
        let local = try target("JournalTarget-" + mutation, settings: baseline)
        let engine = LegacyDesktopMigrationImporter(targetData: local)
        let plan = try engine.preview(source: source.source, currentSettings: baseline)
        let saved = try engine.applyConfirmed(plan: plan, currentSettings: baseline, approvedPlanDigest: plan.approvalDigest).settings
        let journalURL = local.directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename)
        if mutation == "missing" { try FileManager.default.removeItem(at: journalURL) }
        else if mutation == "corrupt" { try Data("broken".utf8).write(to: journalURL) }
        else {
            var journal = try JSONDecoder().decode(LegacyDesktopMigrationJournal.self, from: Data(contentsOf: journalURL))
            journal.schema = 2
            try JSONEncoder().encode(journal).write(to: journalURL)
        }
        let reopened = LocalData(directory: local.directory, createIfMissing: false)
        let loaded = try reopened.load("settings.json", as: OperationSettings.self)!
        let before = try Data(contentsOf: local.directory.appendingPathComponent("settings.json"))
        try fails("日志" + mutation) { _ = try LegacyDesktopMigrationImporter(targetData: reopened).recoverCommittedJournals(currentSettings: loaded) }
        try check(saved.desktopMigrationIDs == loaded.desktopMigrationIDs, "日志故障receipt保留")
        try check(try Data(contentsOf: local.directory.appendingPathComponent("settings.json")) == before, "日志故障不回滚设置")
    }
    print("PASS: LegacyDesktopMigration \(checks) synthetic integrity, conflict, idempotence and crash-recovery checks")
}
