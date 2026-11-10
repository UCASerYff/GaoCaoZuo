#if SCREENSHOT_MIGRATION_FINDER_METADATA_TESTS
import Foundation
import Darwin

/// Physical, disposable fixtures only. Uses production plans, inventory/copy, Activity.prepare (and its
/// private selector), and independent Activity.validate; no real source, app, capture or migration apply.
private enum ScreenshotFinderMetadataFixtureSuite {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        let archive: URL
        let plan: ScreenshotMigrationPlan
    }
    static let metadataPaths = ["Exchange/.DS_Store", "Exchange/Outgoing/.DS_Store"]
    static var assertions = 0
    static var negativeCases = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw Failure(message: "FinderMetadata: " + message) }
    }
    static func rejected(_ message: String, containing reason: String, _ operation: () throws -> Void) throws {
        var failure: Error?
        do { try operation() } catch { failure = error }
        try expect(failure != nil, message + " must fail")
        if let failure { try expect(failure.localizedDescription.contains(reason), message + " must fail at the intended boundary: " + failure.localizedDescription) }
        negativeCases += 1
    }
    static func put(_ bytes: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func json(_ value: [String: Any], _ url: URL) throws { try put(ScreenshotMigrationIO.json(value), url) }
    static func metadata(_ marker: UInt8) -> Data {
        // Synthetic bytes with the observed Finder v1/Bud1 signature; never copied from a user's .DS_Store.
        var bytes = Data([0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31])
        bytes.append(contentsOf: (0..<248).map { UInt8(($0 + Int(marker)) % 256) })
        return bytes
    }
    static func fixture(change: (URL) throws -> Void = { _ in }) throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ScreenshotFinderMetadata-" + UUID().uuidString + ".noindex")
        let source = base.appendingPathComponent("SyntheticLegacy"), target = base.appendingPathComponent("Host/Screenshot")
        let archive = base.appendingPathComponent("SyntheticArchive.noindex")
        do {
            try json(["schemaVersion": 1, "historyEnabled": false, "silentOCRCopies": false,
                      "historyDays": 30, "historyCapacityMB": 512, "captureStrategy": "标注",
                      "languages": ["zh-Hans"], "pins": [String]()], source.appendingPathComponent("Settings.json"))
            try json(["schemaVersion": 1, "records": [[String: Any]]()], source.appendingPathComponent("Exchange/ProcessedRequests.json"))
            for (offset, path) in metadataPaths.enumerated() { try put(metadata(UInt8(offset + 1)), source.appendingPathComponent(path)) }
            try change(source)
            // A physical inventory-backed approved plan lets malformed path/type fixtures reach the production
            // Activity selector. No model or IO is stubbed, and no migration apply/retirement is invoked.
            let configuration = ScreenshotMigrationConfiguration(sourceRoot: source, targetRoot: target,
                archiveRoot: base.appendingPathComponent("SyntheticArchives.noindex"), auxiliaries: [])
            let snapshot = try ScreenshotMigrationIO.snapshot(id: "Source", url: source, required: true)
            let snapshots = [snapshot], sourceSHA = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode([snapshot]))
            let physicalFiles = snapshot.inventory.values.filter { $0.kind == "file" }
            var plan = ScreenshotMigrationPlan(sourceID: "com.gaoseries.GaoJieTu:" + ScreenshotMigrationIO.sha(Data(ScreenshotMigrationIO.path(source).utf8)),
                sourceSHA256: sourceSHA, migrationID: "screenshot-" + sourceSHA, configuration: configuration, snapshots: snapshots,
                targetBefore: try ScreenshotMigrationIO.snapshot(id: "Target", url: target, required: false),
                fileCount: physicalFiles.count, totalBytes: physicalFiles.reduce(0) { $0 + $1.bytes },
                conflicts: [], retainedOnly: [], approvalDigest: "")
            plan.approvalDigest = ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(plan))
            try ScreenshotMigrationIO.copy(snapshot, to: archive.appendingPathComponent("Source"))
            return .init(base: base, source: source, target: target, archive: archive, plan: plan)
        } catch { try? FileManager.default.removeItem(at: base); throw error }
    }
    static func cleanup(_ f: Fixture) { try? FileManager.default.removeItem(at: f.base) }
    static func projected(_ path: String) -> String { "Records/Metadata/Source/" + path }

    static func projectionRetainsCompleteBytes() throws {
        let f = try fixture(); defer { cleanup(f) }
        let sourceBefore = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true)
        let archiveBefore = try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true)
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target)
        try expect(try ScreenshotMigrationActivity.validate(root: f.target, plan: f.plan, archive: f.archive) == index,
                   "independent validation binds the complete selected inventory to the approved physical plan")
        try expect(index.entries.isEmpty && index.blockers.isEmpty, "Finder metadata and an empty ledger create no business entry, attachment or blocker")
        try expect(Set(index.files.keys) == Set(metadataPaths.map(projected) + ["Records/Source/Exchange/ProcessedRequests.json"]),
                   "only the two exact metadata paths use the dedicated metadata projection")
        for path in metadataPaths {
            let recordPath = projected(path)
            guard let file = index.files[recordPath], let original = sourceBefore.inventory[path] else { throw Failure(message: "missing metadata provenance: " + path) }
            let originalBytes = try ScreenshotMigrationIO.read(f.archive.appendingPathComponent("Source/" + path))
            let projectedBytes = try ScreenshotMigrationIO.read(f.target.appendingPathComponent("ImportedActivity/" + recordPath))
            try expect(projectedBytes == originalBytes, path + " preserves all bytes, including uninterpreted content after the signature")
            try expect(file.snapshotID == "Source" && file.originalRelativePath == path && file.originalPath == ScreenshotMigrationIO.path(f.source.appendingPathComponent(path)),
                       path + " preserves the original source identity and path")
            try expect(file.bytes == original.bytes && file.sha256 == original.sha256 && ScreenshotMigrationIO.sha(projectedBytes) == original.sha256,
                       path + " preserves byte count and complete-file SHA256")
            try expect(!index.entries.contains { $0.relativeRecordPath == recordPath || $0.attachmentPaths.contains(recordPath) }, path + " is never a business record or attachment")
        }
        try expect(try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) == index, "same metadata import is idempotent")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Source", url: f.source, required: true) == sourceBefore, "prepare and validation leave the fixture source unchanged")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true) == archiveBefore, "prepare and validation leave the complete fixture archive unchanged")
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: f.archive)
        try expect(try ScreenshotMigrationActivity.validate(root: f.target) == index, "metadata remains self-contained after the disposable original and archive are removed")
    }

    static func unsupportedFilesAndContentFail() throws {
        for path in ["Exchange/unknown.bin", "Exchange/Staging/.DS_Store", "Exchange/Outgoing/unknown.bin"] {
            let f = try fixture { try put(metadata(7), $0.appendingPathComponent(path)) }; defer { cleanup(f) }
            let archiveBefore = try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true)
            let reason = path == "Exchange/unknown.bin" ? "不支持的当前资料" : "无法关联的资料"
            try rejected("unknown file " + path, containing: reason) { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) }
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("ImportedActivity")), "unknown input cannot publish an index")
            try expect(try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true) == archiveBefore, "unknown input does not alter the fixture archive")
        }
        for path in metadataPaths {
            let f = try fixture { try put(Data("Synthetic business bytes are not Finder metadata".utf8), $0.appendingPathComponent(path)) }; defer { cleanup(f) }
            try rejected("non-Bud1 bytes at " + path, containing: "原始格式头不符") { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) }
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("ImportedActivity")), "non-Finder content cannot publish an index")
        }
    }

    static func sameNamedDirectoriesAndLinksFail() throws {
        for path in metadataPaths {
            let f = try fixture { source in
                let directory = source.appendingPathComponent(path)
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }; defer { cleanup(f) }
            try rejected("same-named directory " + path, containing: "普通文件类型") { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) }
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("ImportedActivity")), "a metadata-named directory cannot publish an index")
        }
        for path in metadataPaths {
            let f = try fixture(); defer { cleanup(f) }
            let sentinel = f.base.appendingPathComponent("SyntheticLinkDestination.txt"), sentinelBytes = Data("Synthetic link target must remain untouched".utf8)
            try put(sentinelBytes, sentinel)
            let link = f.archive.appendingPathComponent("Source/" + path)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: sentinel.path)
            try rejected("same-named symlink " + path, containing: "符号链接") { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: f.target) }
            try expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == sentinel.path, "a rejected symlink remains in place")
            try expect(try ScreenshotMigrationIO.read(sentinel) == sentinelBytes, "a rejected symlink never changes its synthetic destination")
            try expect(try !ScreenshotMigrationIO.exists(f.target.appendingPathComponent("ImportedActivity")), "a metadata-named symlink cannot publish an index")
        }
    }

    static func ownedStageIdentityBoundaries() throws {
        let f = try fixture(); defer { cleanup(f) }
        let validName = "PreparedTarget-" + UUID().uuidString + ".noindex"
        let validStage = f.archive.appendingPathComponent(validName)
        let missingSuffixStage = f.archive.appendingPathComponent("PreparedTarget-" + UUID().uuidString)
        let cases: [(String, URL, URL)] = [
            ("target differs from explicit stage", f.target, validStage),
            ("stage is outside archive", f.base.appendingPathComponent(validName), f.base.appendingPathComponent(validName)),
            ("stage is not a direct archive child", f.archive.appendingPathComponent("Nested/" + validName), f.archive.appendingPathComponent("Nested/" + validName)),
            ("stage UUID is invalid", f.archive.appendingPathComponent("PreparedTarget-not-a-uuid.noindex"), f.archive.appendingPathComponent("PreparedTarget-not-a-uuid.noindex")),
            ("stage is missing noindex suffix", missingSuffixStage, missingSuffixStage),
            ("legacy stage is not an explicit owned attempt", f.archive.appendingPathComponent("PreparedTarget"), f.archive.appendingPathComponent("PreparedTarget"))
        ]
        for (label, target, stage) in cases {
            let before = try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true)
            try rejected(label, containing: "显式持有阶段路径或身份不符") { _ = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: target, ownedStage: stage) }
            try expect(try !ScreenshotMigrationIO.exists(target), label + " fails before creating its target")
            try expect(try ScreenshotMigrationIO.snapshot(id: "Archive", url: f.archive, required: true) == before, label + " leaves the fixture archive unchanged")
        }
        let sourceBefore = try ScreenshotMigrationIO.snapshot(id: "Source", url: f.archive.appendingPathComponent("Source"), required: true)
        let index = try ScreenshotMigrationActivity.prepare(plan: f.plan, archive: f.archive, target: validStage, ownedStage: validStage)
        try expect(try ScreenshotMigrationActivity.validate(root: validStage, plan: f.plan, archive: f.archive) == index, "a matching explicit direct-child UUID stage prepares and independently validates")
        try expect(index.entries.isEmpty && metadataPaths.allSatisfy { index.files[projected($0)] != nil }, "a valid owned stage preserves metadata without creating executable or business entries")
        try expect(try ScreenshotMigrationIO.snapshot(id: "Source", url: f.archive.appendingPathComponent("Source"), required: true) == sourceBefore, "owned-stage publication never alters the archived source subtree")
    }

    static func run() throws -> (Int, Int) {
        assertions = 0; negativeCases = 0
        try projectionRetainsCompleteBytes()
        try unsupportedFilesAndContentFail()
        try sameNamedDirectoriesAndLinksFail()
        try ownedStageIdentityBoundaries()
        return (assertions, negativeCases)
    }
}

@main enum ScreenshotMigrationFinderMetadataTestMain {
    static func main() {
        do {
            let (assertions, boundaries) = try ScreenshotFinderMetadataFixtureSuite.run()
            print("ScreenshotMigrationFinderMetadata: \(assertions) assertions passed; \(boundaries) rejected boundaries; synthetic fixtures only; no GUI, capture, real data or migration apply.")
        } catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
#endif
