#if LEGACY_DESKTOP_RETIREMENT_TESTS
import Foundation
import Darwin

/// This suite creates every source, journal and settings file below its own
/// /private/tmp .noindex root. It never opens the user's source/target paths.
@MainActor private enum LegacyDesktopRetirementSuite {
    enum Injected: Error { case interruption }
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { "DesktopRetirement: " + message }
    }
    struct Fixture {
        let root: URL
        let target: URL
        let source: LegacyDesktopMigrationSource
        let settings: OperationSettings
        let sourceBytes: [Data]
        var journal: URL { target.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename) }
        var settingsURL: URL { target.appendingPathComponent("settings.json") }
    }
    struct Hotkey: Codable { var keyCode: UInt32 = 49; var modifiers: UInt32 = 0x1800 }
    struct Workspace: Codable {
        var id = UUID(); var displayName = "SYNTHETIC-WORKSPACE-REMOVE-WITH-EVIDENCE"; var fileURL: URL
        var createdAt = Date(timeIntervalSince1970: 1_000)
    }
    struct Probe: Codable {
        var id = UUID(); var observedAt = Date(timeIntervalSince1970: 1_000)
        var capability = "SYNTHETIC"; var outcome = "NOT_RUN"; var evidenceCode = "SYNTHETIC-PROBE-REMOVE-WITH-EVIDENCE"
    }
    struct Preferences: Codable {
        var appearance = "dark"
        var thumbnailsEnabled = true
        var excludedThumbnailBundleIDs = ["com.example.synthetic-private"]
        var hotkeyEnabled = true
        var hotkey = Hotkey()
        var groupByApplication = false
        var compactChooser = true
        var notchEnabled = true
        var workspaceReferences: [Workspace]
        var capabilityProbeResults = [Probe()]
    }
    struct Payload: Codable {
        var schemaVersion = 1
        var storeID = UUID()
        var generation: UInt64 = 1
        var migrationHistory = ["SYNTHETIC-HISTORY-REMOVE-WITH-EVIDENCE"]
        var preferences: Preferences
    }
    struct Envelope: Codable { var payload: Payload; var sha256: String }
    struct Marker: Codable { var schemaVersion = 1; var storeID: UUID; var createdAt = Date(timeIntervalSince1970: 1_000) }
    struct SchemaOnly: Codable { var schema: Int }

    static var assertions = 0
    static var negativeCases = 0
    static var phase = "initializing-synthetic-root"
    static let finalizedAt = Date(timeIntervalSince1970: 1_800_000_000.125)

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw Failure(message: message) }
    }
    static func rejected(_ message: String, _ operation: () throws -> Void) throws {
        var denied = false
        do { try operation() } catch { denied = true }
        negativeCases += 1
        try expect(denied, "must reject " + message)
    }
    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func digest(_ raw: Data) -> String { LegacyDesktopMigrationCoding.digest(raw) }
    static func rawJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    static func object(_ raw: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Failure(message: "fixture object") }
        return value
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func put(_ raw: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try raw.write(to: url, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Preserve the inode when exercising size/hash CAS separately.
    static func overwrite(_ raw: Data, _ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(message: "fixture overwrite open") }
        defer { close(fd) }
        try raw.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure(message: "fixture overwrite write") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure(message: "fixture overwrite fsync") }
    }
    static func recordMutation(_ document: [String: Any], _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var document = document
        guard var records = document["records"] as? [[String: Any]], !records.isEmpty else { throw Failure(message: "fixture records") }
        change(&records[0]); document["records"] = records
        return document
    }
    static func nestedMutation(_ document: [String: Any], key: String, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var failure = false
        let value = try recordMutation(document) { record in
            guard var nested = record[key] as? [String: Any] else { failure = true; return }
            change(&nested); record[key] = nested
        }
        guard !failure else { throw Failure(message: "fixture nested " + key) }
        return value
    }
    static func resign(_ document: [String: Any]) throws -> Data {
        // Deliberately resign known-field changes, so semantic negative tests
        // cannot pass merely because a stale outer digest was rejected.
        var journal = try JSONDecoder().decode(LegacyDesktopMigrationJournal.self, from: rawJSON(document))
        journal.sha256 = try LegacyDesktopMigrationJournalValidator.journalDigest(journal)
        return try encode(journal)
    }
    static func openFixture(_ f: Fixture, fault: ((LegacyDesktopMigrationFaultPoint) throws -> Void)? = nil) throws -> (LocalData, LegacyDesktopMigrationImporter, OperationSettings) {
        let data = LocalData(directory: f.target, createIfMissing: false)
        guard let settings = try data.load("settings.json", as: OperationSettings.self) else { throw Failure(message: "fixture settings missing") }
        return (data, LegacyDesktopMigrationImporter(targetData: data, fault: fault), settings)
    }
    static func fixture(_ parent: URL, _ name: String, preparedOnly: Bool = false) throws -> Fixture {
        let root = parent.appendingPathComponent(name, isDirectory: true)
        let target = root.appendingPathComponent("SyntheticTarget", isDirectory: true)
        let source = LegacyDesktopMigrationSource(
            applicationURL: root.appendingPathComponent("SyntheticApplicationEvidence", isDirectory: true),
            dataDirectory: root.appendingPathComponent("SyntheticSource", isDirectory: true),
            initializationURL: root.appendingPathComponent("SyntheticInitialization.json"))
        let payload = Payload(preferences: Preferences(workspaceReferences: [.init(fileURL: root.appendingPathComponent("NeverOpenedSyntheticWorkspace"))]))
        let sourceEncoder = LegacyDesktopMigrationCoding.encoder
        let preferences = try sourceEncoder.encode(Envelope(payload: payload, sha256: digest(try sourceEncoder.encode(payload))))
        let initialization = try sourceEncoder.encode(Marker(storeID: payload.storeID))
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.gaoseries.GaoZhuoMian", "CFBundleExecutable": "GaoZhuoMian",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.00", "CFBundleVersion": "1"
        ], format: .binary, options: 0)
        try put(preferences, source.dataDirectory.appendingPathComponent("preferences.json"))
        try put(initialization, source.initializationURL)
        try put(info, source.applicationURL.appendingPathComponent("Contents/Info.plist"))
        let data = LocalData(directory: target)
        var settings = OperationSettings(); settings.appearance = "light"; settings.clipboardEnabled = false
        _ = try data.load("settings.json", as: OperationSettings.self)
        try data.save(settings, name: "settings.json")
        let importer = LegacyDesktopMigrationImporter(targetData: data, fault: preparedOnly ? { point in
            if point == .afterPreparedJournal { throw Injected.interruption }
        } : nil)
        let plan = try importer.preview(source: source, currentSettings: settings, adoptSourceOverview: true)
        if preparedOnly {
            try rejected("synthetic prepare interruption") {
                _ = try importer.applyConfirmed(plan: plan, currentSettings: settings, approvedPlanDigest: plan.approvalDigest)
            }
        } else {
            settings = try importer.applyConfirmed(plan: plan, currentSettings: settings, approvedPlanDigest: plan.approvalDigest).settings
        }
        // Noncanonical whitespace ensures retirement preserves raw settings,
        // rather than silently replacing them with a canonical re-encoding.
        let settingsURL = target.appendingPathComponent("settings.json")
        try overwrite(Data("\n  ".utf8) + bytes(settingsURL) + Data("\n\t".utf8), settingsURL)
        return Fixture(root: root, target: target, source: source, settings: settings, sourceBytes: [preferences, initialization, info])
    }
    static func plan(_ f: Fixture) throws -> LegacyDesktopSourceRetirementPlan {
        let (_, importer, settings) = try openFixture(f)
        return try importer.retirementPreview(currentSettings: settings, finalizedAt: finalizedAt)
    }
    static func finalize(_ f: Fixture, _ plan: LegacyDesktopSourceRetirementPlan,
                         fault: ((LegacyDesktopMigrationFaultPoint) throws -> Void)? = nil) throws -> LegacyDesktopSourceRetirementResult {
        let (_, importer, settings) = try openFixture(f, fault: fault)
        return try importer.finalizeSourceRetirement(plan: plan, currentSettings: settings, approvedPlanDigest: plan.approvalDigest)
    }
    static func stage(_ f: Fixture, _ plan: LegacyDesktopSourceRetirementPlan) -> URL {
        f.target.appendingPathComponent(".retiring-desktop-" + plan.approvalDigest + ".stage")
    }
    static func intent(_ f: Fixture, _ plan: LegacyDesktopSourceRetirementPlan) -> URL {
        f.target.appendingPathComponent(".retiring-desktop-" + plan.approvalDigest + ".intent.json")
    }
    static func assertNoStagedEvidence(_ f: Fixture, _ plan: LegacyDesktopSourceRetirementPlan) throws {
        try expect(!FileManager.default.fileExists(atPath: stage(f, plan).path), "owned stage must be gone before success")
        try expect(!FileManager.default.fileExists(atPath: intent(f, plan).path), "completed transaction intent must be gone before success")
        let names = try FileManager.default.contentsOfDirectory(atPath: f.target.path)
        try expect(!names.contains(where: { $0.hasPrefix(".writing-") }), "retirement must not leave random writing files")
    }

    static func run(_ root: URL) throws {
        phase = "positive-fixture"
        let f = try fixture(root, "Positive")
        let journalBefore = try bytes(f.journal), settingsBefore = try bytes(f.settingsURL)
        let v1 = try LegacyDesktopMigrationJournalValidator.decode(journalBefore, settings: f.settings)
        try expect(v1.schema == 1 && v1.records.count == 1, "production importer creates a valid schema 1 fixture")
        phase = "positive-retirement-preview"
        let preview = try plan(f)
        try expect(preview.finalizedAt == finalizedAt, "fixed retirement date survives preview")
        try expect(preview.beforeJournalRawSHA256 == digest(journalBefore) && preview.settingsRawSHA256 == digest(settingsBefore), "plan binds raw journal and settings")
        try expect(try bytes(f.journal) == journalBefore && bytes(f.settingsURL) == settingsBefore, "preview performs no writes")
        try expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path).sorted() == [LegacyDesktopMigrationImporter.journalFilename, "settings.json"].sorted(), "preview creates no intent, stage or raw backup")
        let planBytes = try encode(preview)
        phase = "positive-plan-roundtrip"
        try expect(try LegacyDesktopSourceRetirementPlan.decode(planBytes) == preview, "saved plan strict decode round-trips its fixed date and identity")
        for evidence in f.sourceBytes { try expect(planBytes.range(of: Data(evidence.base64EncodedString().utf8)) == nil, "plan contains no recoverable source bytes") }
        try expect(!String(decoding: planBytes, as: UTF8.self).contains("SYNTHETIC-HISTORY"), "plan contains no source history")
        let (_, wrongImporter, wrongSettings) = try openFixture(f)
        try rejected("different retirement approval digest") {
            _ = try wrongImporter.finalizeSourceRetirement(plan: preview, currentSettings: wrongSettings, approvedPlanDigest: String(repeating: "0", count: 64))
        }
        try expect(try bytes(f.journal) == journalBefore && bytes(f.settingsURL) == settingsBefore, "wrong approval leaves both originals exact")
        phase = "positive-finalize"
        let result = try finalize(f, preview)
        let retiredRaw = try bytes(f.journal)
        let v2 = try LegacyDesktopMigrationJournalValidator.decode(retiredRaw, settings: f.settings)
        try expect(!result.alreadyFinalized && result.journalRawSHA256 == digest(retiredRaw), "first finalize returns committed journal hash")
        try expect(v2.schema == 2 && !v2.records.isEmpty && v2.records.allSatisfy({ $0.phase == .committed && $0.committedAt != nil && $0.sourceEvidence == nil }), "schema 2 has only committed evidence-free records")
        try expect(try bytes(f.settingsURL) == settingsBefore, "all current settings bytes are preserved")
        let retired = try object(retiredRaw)
        let retiredRecords = retired["records"] as! [[String: Any]]
        let first = retiredRecords[0], source = first["source"] as! [String: Any]
        try expect(first["sourceEvidence"] == nil && first["proposedOverview"] == nil && source["migrationHistory"] == nil, "serialized schema 2 omits every recoverable old snapshot key")
        try expect(first["sourceRetirement"] != nil && source["identityDigest"] as? String == v1.records[0].source.digest, "retirement facts retain original source identity digest")
        let facts = v2.records[0].sourceRetirement!
        try expect(facts.preferencesSHA256 == digest(f.sourceBytes[0]) && facts.initializationSHA256 == digest(f.sourceBytes[1])
                   && facts.applicationInfoSHA256 == digest(f.sourceBytes[2]), "facts preserve all three original artifact hashes")
        try expect(facts.beforeJournalRawSHA256 == digest(journalBefore) && facts.settingsRawSHA256 == digest(settingsBefore)
                   && facts.retirementApprovalDigest == preview.approvalDigest && facts.finalizedAt == finalizedAt,
                   "facts bind old raw hashes, separate retirement approval and fixed date")
        try expect(v2.records[0].approvalDigest == v1.records[0].approvalDigest && v2.records[0].approvalDigest != facts.retirementApprovalDigest,
                   "original import approval is preserved separately from retirement approval")
        let retiredText = String(decoding: retiredRaw, as: UTF8.self)
        for evidence in f.sourceBytes { try expect(!retiredText.contains(evidence.base64EncodedString()), "journal contains no encoded original artifact") }
        try expect(!retiredText.contains("SYNTHETIC-HISTORY") && !retiredText.contains("NeverOpenedSyntheticWorkspace"), "source history and paths are gone")
        try expect(try bytes(f.source.dataDirectory.appendingPathComponent("preferences.json")) == f.sourceBytes[0]
                   && bytes(f.source.initializationURL) == f.sourceBytes[1]
                   && bytes(f.source.applicationURL.appendingPathComponent("Contents/Info.plist")) == f.sourceBytes[2], "finalize never deletes or rewrites source artifacts")
        try assertNoStagedEvidence(f, preview)
        phase = "positive-idempotency-and-later-preferences"
        let again = try finalize(f, preview)
        try expect(again.alreadyFinalized && (try bytes(f.journal)) == retiredRaw && (try bytes(f.settingsURL)) == settingsBefore, "same-plan finalize is byte-for-byte idempotent")
        let (changedData, changedImporter, current) = try openFixture(f)
        var changed = current; changed.appearance = "dark"; changed.desktopOverview.compactChooser.toggle()
        try changedData.save(changed, name: "settings.json")
        let changedRaw = try bytes(f.settingsURL)
        try expect(try changedImporter.records(currentSettings: changed).count == 1, "later ordinary preference edits remain readable")
        try expect(try bytes(f.settingsURL) == changedRaw && bytes(f.journal) == retiredRaw, "reading schema 2 never restores old preferences")

        phase = "document-negatives"
        try documentNegatives(root, v1Raw: journalBefore, v1Settings: f.settings, v2Raw: retiredRaw)
        phase = "state-negatives"
        try stateNegatives(root)
        phase = "interruption-tests"
        try interruptionTests(root)
        phase = "foreign-stage-tests"
        try foreignStageTests(root)
    }

    static func documentNegatives(_ root: URL, v1Raw: Data, v1Settings: OperationSettings, v2Raw: Data) throws {
        let one = try object(v1Raw), two = try object(v2Raw)
        func rejectRaw(_ label: String, _ raw: Data, settings: OperationSettings? = nil) throws {
            phase = "document-negative-shared-validator: " + label
            try rejected(label + " shared validator") { _ = try LegacyDesktopMigrationJournalValidator.decode(raw, settings: settings ?? v1Settings) }
            let directory = root.appendingPathComponent("InvalidDocument-" + UUID().uuidString)
            let settingsRaw = try encode(settings ?? v1Settings)
            try put(settingsRaw, directory.appendingPathComponent("settings.json"))
            try put(raw, directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename))
            let data = LocalData(directory: directory, createIfMissing: false)
            phase = "document-negative-production-reader: " + label
            try rejected(label + " production reader") {
                let disk = try data.load("settings.json", as: OperationSettings.self)!
                _ = try LegacyDesktopMigrationImporter(targetData: data).records(currentSettings: disk)
            }
            phase = "document-negative-original-bytes: " + label
            try expect(try bytes(directory.appendingPathComponent(LegacyDesktopMigrationImporter.journalFilename)) == raw, "invalid journal remains untouched")
            try expect(try bytes(directory.appendingPathComponent("settings.json")) == settingsRaw, "negative production read leaves settings bytes untouched")
        }
        var cases: [(String, [String: Any])] = []
        for (label, document) in [("v1", one), ("v2", two)] {
            var unknown = document; unknown["unexpected"] = "synthetic"; cases.append((label + " unknown top field", unknown))
            cases.append((label + " unknown record field", try recordMutation(document) { $0["unexpected"] = true }))
            cases.append((label + " unknown source field", try nestedMutation(document, key: "source") { $0["unexpected"] = true }))
            var unsupported = document; unsupported["schema"] = 3; cases.append((label + " unsupported schema", unsupported))
            var boolean = document; boolean["schema"] = true; cases.append((label + " boolean schema", boolean))
            var missing = document; missing.removeValue(forKey: "sourceMappings"); cases.append((label + " missing mapping", missing))
            cases.append((label + " null committedAt", try recordMutation(document) { $0["committedAt"] = NSNull() }))
        }
        cases.append(("v1 missing source evidence", try recordMutation(one) { $0.removeValue(forKey: "sourceEvidence") }))
        cases.append(("v1 null source evidence", try recordMutation(one) { $0["sourceEvidence"] = NSNull() }))
        cases.append(("v1 missing Data", try nestedMutation(one, key: "sourceEvidence") { $0.removeValue(forKey: "preferences") }))
        cases.append(("v1 null Data", try nestedMutation(one, key: "sourceEvidence") { $0["preferences"] = NSNull() }))
        cases.append(("v1 unknown evidence field", try nestedMutation(one, key: "sourceEvidence") { $0["unexpected"] = "synthetic" }))
        cases.append(("v1 retirement facts not permitted", try recordMutation(one) { $0["sourceRetirement"] = [:] }))
        let forbiddenEvidence: [Any] = [NSNull(), [:] as [String: Any], (one["records"] as! [[String: Any]])[0]["sourceEvidence"]!]
        for value in forbiddenEvidence {
            cases.append(("v2 sourceEvidence key forbidden even null", try recordMutation(two) { $0["sourceEvidence"] = value }))
        }
        cases.append(("v2 old proposed overview forbidden", try recordMutation(two) { $0["proposedOverview"] = (one["records"] as! [[String: Any]])[0]["proposedOverview"] }))
        cases.append(("v2 source history forbidden", try nestedMutation(two, key: "source") { $0["migrationHistory"] = ["synthetic"] }))
        cases.append(("v2 missing retirement facts", try recordMutation(two) { $0.removeValue(forKey: "sourceRetirement") }))
        cases.append(("v2 null retirement facts", try recordMutation(two) { $0["sourceRetirement"] = NSNull() }))
        cases.append(("v2 unknown retirement fact", try nestedMutation(two, key: "sourceRetirement") { $0["unexpected"] = "synthetic" }))
        var mislabeledOne = one; mislabeledOne["schema"] = 2; cases.append(("v1 payload labeled v2", mislabeledOne))
        var mislabeledTwo = two; mislabeledTwo["schema"] = 1; cases.append(("v2 payload labeled v1", mislabeledTwo))
        for (label, document) in cases { try rejectRaw(label, rawJSON(document)) }
        for (label, raw) in [("v1", v1Raw), ("v2", v2Raw)] {
            var duplicate = Data("{\"schema\":\(label == "v1" ? 1 : 2),".utf8); duplicate.append(raw.dropFirst())
            try rejectRaw(label + " duplicate object key", duplicate)
        }
        for (label, document) in [("v1", one), ("v2", two)] {
            var mapping = document; mapping["sourceMappings"] = [String: [String]]()
            try rejectRaw(label + " wrong mapping with fresh digest", resign(mapping))
            var duplicated = document
            duplicated["records"] = (document["records"] as! [[String: Any]]) + (document["records"] as! [[String: Any]])
            try rejectRaw(label + " duplicate record IDs with fresh digest", resign(duplicated))
            let wrongID = try recordMutation(document) { $0["id"] = "desktop-" + String(repeating: "0", count: 64) }
            try rejectRaw(label + " identity ID mismatch with fresh digest", resign(wrongID))
            var extra = v1Settings; extra.desktopMigrationIDs.append("desktop-" + String(repeating: "1", count: 64))
            try rejectRaw(label + " settings extra migration ID", rawJSON(document), settings: extra)
            var fewer = v1Settings; fewer.desktopMigrationIDs = []
            try rejectRaw(label + " journal extra committed ID", rawJSON(document), settings: fewer)
            var duplicateSettings = v1Settings; duplicateSettings.desktopMigrationIDs += v1Settings.desktopMigrationIDs
            try rejectRaw(label + " duplicate settings IDs", rawJSON(document), settings: duplicateSettings)
        }
        var empty = two; empty["records"] = [[String: Any]](); empty["sourceMappings"] = [String: [String]]()
        var noIDs = v1Settings; noIDs.desktopMigrationIDs = []
        try rejectRaw("schema 2 cannot be empty", resign(empty), settings: noIDs)
        let prepared = try recordMutation(two) { $0["phase"] = "prepared"; $0.removeValue(forKey: "committedAt") }
        try rejectRaw("schema 2 cannot contain prepared record", resign(prepared))
        let other = root.appendingPathComponent("FilenameBoundary")
        try put(v2Raw, other.appendingPathComponent("other.json"))
        let otherData = LocalData(directory: other, createIfMissing: false)
        try rejected("schema 2 exception is exact journal filename only") { _ = try otherData.load("other.json", as: LegacyDesktopMigrationJournal.self) }
        let wrongSchema = root.appendingPathComponent("SchemaBoundary")
        try put(try encode(SchemaOnly(schema: 2)), wrongSchema.appendingPathComponent("settings.json"))
        let schemaData = LocalData(directory: wrongSchema, createIfMissing: false)
        try rejected("schema 2 never admitted for ordinary settings") { _ = try schemaData.load("settings.json", as: SchemaOnly.self) }
    }

    static func stateNegatives(_ root: URL) throws {
        let prepared = try fixture(root, "Prepared", preparedOnly: true)
        try rejected("retirement of a prepared import") { _ = try plan(prepared) }
        let emptyRoot = root.appendingPathComponent("EmptyTarget")
        let emptySettings = OperationSettings()
        try put(try encode(emptySettings), emptyRoot.appendingPathComponent("settings.json"))
        let emptyData = LocalData(directory: emptyRoot, createIfMissing: false)
        try rejected("retirement of empty journal") {
            _ = try LegacyDesktopMigrationImporter(targetData: emptyData).retirementPreview(currentSettings: emptySettings, finalizedAt: finalizedAt)
        }
        let planFixture = try fixture(root, "PlanBoundary"), reviewed = try plan(planFixture)
        let reviewedObject = try object(encode(reviewed))
        var unknown = reviewedObject; unknown["unexpected"] = "synthetic"
        try rejected("saved plan unknown field") { _ = try LegacyDesktopSourceRetirementPlan.decode(rawJSON(unknown)) }
        var missing = reviewedObject; missing.removeValue(forKey: "afterContentSHA256")
        try rejected("saved plan missing content digest") { _ = try LegacyDesktopSourceRetirementPlan.decode(rawJSON(missing)) }
        var null = reviewedObject; null["beforeJournalIdentity"] = NSNull()
        try rejected("saved plan null original identity") { _ = try LegacyDesktopSourceRetirementPlan.decode(rawJSON(null)) }
        var duplicatePlan = Data("{\"schema\":1,".utf8); duplicatePlan.append(try encode(reviewed).dropFirst())
        try rejected("saved plan duplicate key") { _ = try LegacyDesktopSourceRetirementPlan.decode(duplicatePlan) }
        var forgedContent = reviewedObject; forgedContent["afterContentSHA256"] = String(repeating: "0", count: 64)
        try rejected("saved plan changed content digest with old approval") { _ = try LegacyDesktopSourceRetirementPlan.decode(rawJSON(forgedContent)) }
        var forgedAfter = reviewed
        forgedAfter.afterExpectedRawSHA256 = String(repeating: "0", count: 64)
        try rejected("changed derived raw output digest") { _ = try finalize(planFixture, forgedAfter) }
        _ = try finalize(planFixture, reviewed)
        let untampered = try bytes(planFixture.journal)
        let tampered = try recordMutation(object(untampered)) { record in
            var conflicts = record["conflicts"] as! [[String: Any]]
            conflicts[0]["reason"] = "SYNTHETIC-UNREVIEWED-BUSINESS-CHANGE"
            record["conflicts"] = conflicts
        }
        let tamperedRaw = try resign(tampered)
        try overwrite(tamperedRaw, planFixture.journal)
        var forgedResume = reviewed
        forgedResume.afterExpectedRawSHA256 = digest(tamperedRaw)
        try rejected("v2 business edit plus matching forged raw hash cannot reuse approved digest") { _ = try finalize(planFixture, forgedResume) }
        try expect(try bytes(planFixture.journal) == tamperedRaw, "unreviewed v2 edit remains untouched after refusal")
        for change in ["settings-raw", "settings-value", "journal-raw", "journal-inode", "journal-size", "journal-hash"] {
            let f = try fixture(root, "Stale-" + change), preview = try plan(f)
            let journalBefore = try bytes(f.journal), settingsBefore = try bytes(f.settingsURL)
            if change == "settings-raw" { try overwrite(settingsBefore + Data(" ".utf8), f.settingsURL) }
            else if change == "settings-value" {
                var changed = f.settings; changed.appearance = "dark"
                try overwrite(encode(changed), f.settingsURL)
            }
            else if change == "journal-raw" || change == "journal-size" { try overwrite(journalBefore + Data(" ".utf8), f.journal) }
            else if change == "journal-inode" {
                try FileManager.default.moveItem(at: f.journal, to: f.root.appendingPathComponent("SyntheticOriginalJournal"))
                try put(journalBefore, f.journal)
            } else {
                var raw = journalBefore
                if let index = raw.firstIndex(of: 10) { raw[index] = 32 } else { throw Failure(message: "fixture needs whitespace") }
                try overwrite(raw, f.journal)
            }
            let journalCurrent = try bytes(f.journal), settingsCurrent = try bytes(f.settingsURL)
            try rejected("stale plan " + change) { _ = try finalize(f, preview) }
            try expect(try bytes(f.journal) == journalCurrent && bytes(f.settingsURL) == settingsCurrent, "stale plan preserves exact current files")
        }
        for collision in ["stage", "intent"] {
            let f = try fixture(root, "Collision-" + collision), preview = try plan(f)
            let journalBefore = try bytes(f.journal), settingsBefore = try bytes(f.settingsURL)
            let path = collision == "stage" ? stage(f, preview) : intent(f, preview)
            let sentinel = Data("SYNTHETIC-FOREIGN-COLLISION".utf8)
            try put(sentinel, path)
            try rejected("preexisting foreign " + collision) { _ = try finalize(f, preview) }
            try expect(try bytes(path) == sentinel && bytes(f.journal) == journalBefore && bytes(f.settingsURL) == settingsBefore, "foreign collision never overwritten or removed")
        }
        let unowned = try fixture(root, "IdenticalStageWithoutIntent"), unownedPlan = try plan(unowned)
        try rejected("prepare exact candidate without later authority") {
            _ = try finalize(unowned, unownedPlan, fault: { if $0 == .afterRetirementIntent { throw Injected.interruption } })
        }
        // Removing our synthetic fixture's receipt simulates the narrow real
        // create-to-intent crash gap. Identical bytes do not prove ownership.
        try FileManager.default.removeItem(at: intent(unowned, unownedPlan))
        let candidate = try bytes(stage(unowned, unownedPlan)), original = try bytes(unowned.journal)
        try rejected("identical candidate stage without durable owned intent") { _ = try finalize(unowned, unownedPlan) }
        try expect(try bytes(stage(unowned, unownedPlan)) == candidate && bytes(unowned.journal) == original,
                   "unowned same-content stage is neither claimed, removed nor committed")
        // Both checks surround the actual commit; canonical-equal raw changes
        // still invalidate the previously reviewed settings bytes.
        for point in [LegacyDesktopMigrationFaultPoint.afterRetirementIntent, .afterRetirementSwap] {
          for mutation in ["raw", "preference"] {
            let f = try fixture(root, "ConcurrentSettings-" + String(describing: point) + "-" + mutation), preview = try plan(f)
            var changed = f.settings; changed.appearance = "dark"
            let current: Data
            if mutation == "raw" { current = try bytes(f.settingsURL) + Data("\n ".utf8) }
            else { current = try encode(changed) }
            var committed: LegacyDesktopSourceRetirementCommittedError?
            try rejected("settings CAS at " + String(describing: point)) {
                do { _ = try finalize(f, preview, fault: { if $0 == point { try overwrite(current, f.settingsURL) } }) }
                catch let error as LegacyDesktopSourceRetirementCommittedError { committed = error; throw error }
            }
            try expect(try bytes(f.settingsURL) == current, "concurrent settings edit is never overwritten")
            if point == .afterRetirementSwap {
                try expect(committed?.journalSealed == true && committed?.cleanupComplete == true && committed?.requiresRootReview == true,
                           "post-swap settings edit reports structured committed state after owned cleanup")
                try expect(committed?.actualSettingsRawSHA256 == digest(current), "committed review status reports actual settings raw hash")
                try expect(committed?.journalCommitUncertain == false && committed?.actualJournalRawSHA256 == preview.afterExpectedRawSHA256,
                           "post-swap review status freshly verifies the sealed journal")
                try assertNoStagedEvidence(f, preview)
                let (_, reader, disk) = try openFixture(f)
                try expect(try reader.records(currentSettings: disk).count == 1, "new settings remain readable with the historical v2 journal")
            } else {
                try expect(committed == nil, "pre-swap settings edit is not reported as committed")
            }
          }
        }
    }

    static func interruptionTests(_ root: URL) throws {
        for point in [LegacyDesktopMigrationFaultPoint.beforeRetirementIntent, .afterRetirementIntent, .afterRetirementSwap,
                      .afterRetirementDisplacedRemoval, .afterRetirementJournalWrite, .afterRetirementReadback] {
            let f = try fixture(root, "Interrupted-" + String(describing: point)), preview = try plan(f)
            let settingsBefore = try bytes(f.settingsURL), journalBefore = try bytes(f.journal)
            try rejected("injected " + String(describing: point)) {
                _ = try finalize(f, preview, fault: { if $0 == point { throw Injected.interruption } })
            }
            if point == .afterRetirementSwap {
                try expect(try bytes(stage(f, preview)) == journalBefore, "after swap crash retains exactly displaced original until verified removal")
                try expect(try LegacyDesktopMigrationJournalValidator.decode(bytes(f.journal), settings: f.settings).schema == 2, "after swap journal is the planned v2")
            }
            if point == .afterRetirementDisplacedRemoval {
                try expect(!FileManager.default.fileExists(atPath: stage(f, preview).path), "after unlink crash has no recoverable old stage")
            }
            let result = try finalize(f, preview)
            try expect(result.journalRawSHA256 == preview.afterExpectedRawSHA256, "same-plan resume reaches exact planned bytes")
            try expect(try bytes(f.settingsURL) == settingsBefore, "interruption and resume leave settings exact")
            try expect(try LegacyDesktopMigrationJournalValidator.decode(bytes(f.journal), settings: f.settings).schema == 2, "resume uses normal v2 validator")
            try assertNoStagedEvidence(f, preview)
            let completed = try bytes(f.journal)
            try expect(try finalize(f, preview).alreadyFinalized && bytes(f.journal) == completed, "resume completion is idempotent")
        }
        let changed = try fixture(root, "AfterSwapResumeWithNewPreferences"), reviewed = try plan(changed)
        try rejected("prepare swapped journal before later preference change") {
            _ = try finalize(changed, reviewed, fault: { if $0 == .afterRetirementSwap { throw Injected.interruption } })
        }
        var settings = changed.settings; settings.appearance = "dark"
        let newSettings = try encode(settings)
        try overwrite(newSettings, changed.settingsURL)
        var committed: LegacyDesktopSourceRetirementCommittedError?
        try rejected("same-plan v2 cleanup with changed preferences requires root review") {
            do { _ = try finalize(changed, reviewed) }
            catch let error as LegacyDesktopSourceRetirementCommittedError { committed = error; throw error }
        }
        try expect(committed?.journalSealed == true && committed?.cleanupComplete == true && committed?.requiresRootReview == true,
                   "same-plan resume cleans owned evidence but never calls changed settings a success")
        try expect(committed?.actualSettingsRawSHA256 == digest(newSettings), "resume review reports actual changed settings raw hash")
        try expect(committed?.journalCommitUncertain == false && committed?.actualJournalRawSHA256 == reviewed.afterExpectedRawSHA256,
                   "resume review status uses the actual journal hash")
        try assertNoStagedEvidence(changed, reviewed)
        try expect(try bytes(changed.settingsURL) == newSettings, "same-plan cleanup never rewrites changed preferences")
        let (_, reader, disk) = try openFixture(changed)
        try expect(try reader.records(currentSettings: disk).count == 1, "ordinary schema 2 reads accept later preferences after review-required cleanup")
        for mutation in ["missing", "replaced"] {
            let f = try fixture(root, "AfterSwapCurrentJournal-" + mutation), reviewed = try plan(f)
            let original = try bytes(f.journal)
            let foreign = Data("SYNTHETIC-FOREIGN-CURRENT-JOURNAL".utf8)
            var status: LegacyDesktopSourceRetirementCommittedError?
            try rejected("post-swap actual journal " + mutation) {
                do {
                    _ = try finalize(f, reviewed, fault: { point in
                        if point == .afterRetirementSwap {
                            if mutation == "missing" { try FileManager.default.removeItem(at: f.journal) }
                            else { try overwrite(foreign, f.journal) }
                        }
                    })
                } catch let error as LegacyDesktopSourceRetirementCommittedError { status = error; throw error }
            }
            try expect(status?.journalSealed == false && status?.cleanupComplete == false && status?.requiresRootReview == true,
                       "failed current-journal verification never claims sealed or cleanup complete")
            if mutation == "missing" {
                try expect(status?.journalCommitUncertain == true && status?.actualJournalRawSHA256 == nil,
                           "missing current journal reports uncertainty with no invented hash")
            } else {
                try expect(status?.journalCommitUncertain == false && status?.actualJournalRawSHA256 == digest(foreign),
                           "readable foreign current journal reports its actual differing hash")
                try expect(try bytes(f.journal) == foreign, "foreign current journal is not overwritten")
            }
            try expect(try bytes(stage(f, reviewed)) == original, "uncertain or replaced current journal preserves displaced evidence")
        }
    }

    static func foreignStageTests(_ root: URL) throws {
        for point in [LegacyDesktopMigrationFaultPoint.afterRetirementIntent, .afterRetirementSwap] {
          for mutation in ["inode", "size", "hash", "intent"] {
            let f = try fixture(root, "ForeignStage-" + String(describing: point) + "-" + mutation), preview = try plan(f)
            try rejected("prepare transaction fixture") {
                _ = try finalize(f, preview, fault: { if $0 == point { throw Injected.interruption } })
            }
            let stageURL = stage(f, preview), intentURL = intent(f, preview)
            let initialStage = try bytes(stageURL), journalBefore = try bytes(f.journal), settingsBefore = try bytes(f.settingsURL)
            if mutation == "inode" {
                try FileManager.default.moveItem(at: stageURL, to: f.root.appendingPathComponent("SyntheticOwnedStage"))
                try put(initialStage, stageURL)
            } else if mutation == "size" { try overwrite(initialStage + Data(" ".utf8), stageURL) }
            else if mutation == "hash" {
                var changed = initialStage
                if let index = changed.firstIndex(of: 10) { changed[index] = 32 } else { throw Failure(message: "stage needs whitespace") }
                try overwrite(changed, stageURL)
            } else { try overwrite(Data("{\"syntheticForeignIntent\":true}".utf8), intentURL) }
            let foreignStage = try bytes(stageURL), foreignIntent = try bytes(intentURL)
            try rejected("resume refuses foreign transaction " + mutation) { _ = try finalize(f, preview) }
            try expect(try bytes(stageURL) == foreignStage && bytes(intentURL) == foreignIntent, "foreign transaction artifacts remain untouched")
            try expect(try bytes(f.journal) == journalBefore && bytes(f.settingsURL) == settingsBefore, "foreign transaction cannot replace journal or settings")
          }
        }
    }
}

@main private enum LegacyDesktopRetirementTestMain {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LegacyDesktopRetirement-" + UUID().uuidString + ".noindex", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            try LegacyDesktopRetirementSuite.run(root)
            print("{\"suite\":\"LegacyDesktopRetirement\",\"syntheticOnly\":true,\"assertions\":\(LegacyDesktopRetirementSuite.assertions),\"negativeCases\":\(LegacyDesktopRetirementSuite.negativeCases),\"passed\":true}")
        } catch {
            FileHandle.standardError.write(Data(("[phase=" + LegacyDesktopRetirementSuite.phase + "] " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
#endif
