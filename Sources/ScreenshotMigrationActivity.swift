import Foundation
import Darwin

/// These records are a read-only projection, never input to the live Exchange provider.
struct ScreenshotMigratedActivityFile: Codable, Equatable, Sendable {
    var snapshotID: String
    var originalRelativePath: String
    var originalPath: String
    var bytes: Int64
    var sha256: String
}

struct ScreenshotMigratedActivityIdentity: Codable, Equatable, Sendable {
    var requestID: String?
    var sourceBundleID: String?
    var targetBundleID: String?
    var action: String?
    var sessionID: String?
}

struct ScreenshotMigratedActivityEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var label: String
    var status: String
    var relativeRecordPath: String
    var attachmentPaths: [String]
    var originalIdentity: ScreenshotMigratedActivityIdentity
    var provenance: ScreenshotMigratedActivityFile
    var readOnly = true
    var allowsExecution = false
    var handlingPath: String
    var historyDisposition: String? = nil
}

struct ScreenshotMigratedActivityIndex: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var sourceID: String
    var sourceSHA256: String
    var migrationID: String
    var entries: [ScreenshotMigratedActivityEntry]
    var blockers: [String]
    var files: [String: ScreenshotMigratedActivityFile]
    var accessPolicy = "read-only-history; no execution, replay, callback, provider rewrite or result send"
    var historicalManifestBindings: [ScreenshotHistoricalManifestBinding]? = nil
    var legacyHistoryPolicySHA256: String? = nil
    var legacyHistoryPolicyBinding: ScreenshotLegacyHistoryPolicyBinding? = nil
    var integrityWarnings: [String]? = nil
}

struct ScreenshotMigratedActivityContent: Sendable {
    var entry: ScreenshotMigratedActivityEntry
    var recordData: Data
    var attachments: [String: URL]
}

enum ScreenshotMigrationActivity {
    static let directoryName = "ImportedActivity"
    static let indexName = "Index.json"

    /// Only the selected activity closure is copied. Settings, old backups and a raw Source tree are excluded.
    /// Publication is one exclusive rename; no existing host file is replaced, including on explicit incremental import.
    static func prepare(plan: ScreenshotMigrationPlan, archive: URL, target: URL, ownedStage: URL? = nil) throws -> ScreenshotMigratedActivityIndex {
        try validatePlan(plan)
        let isOwnedStage: Bool
        if let ownedStage {
            let name = ownedStage.lastPathComponent, prefix = "PreparedTarget-", suffix = ".noindex"
            guard ScreenshotMigrationIO.path(target) == ScreenshotMigrationIO.path(ownedStage),
                  ScreenshotMigrationIO.path(ownedStage.deletingLastPathComponent()) == ScreenshotMigrationIO.path(archive),
                  name.hasPrefix(prefix), name.hasSuffix(suffix),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else {
                throw fail("活动导入的显式持有阶段路径或身份不符。")
            }
            isOwnedStage = true
        } else { isOwnedStage = false }
        guard !ScreenshotMigrationIO.contains(target, archive), !ScreenshotMigrationIO.contains(archive, target) || ScreenshotMigrationIO.contains(archive.appendingPathComponent("PreparedTarget"), target) || isOwnedStage else {
            throw fail("活动导入的归档与目标路径关系不安全。")
        }
        let destination = target.appendingPathComponent(directoryName)
        let selection = try select(plan: plan, archive: archive)
        // The temporary container is unindexed before any activity is written and is on the target filesystem.
        let work = target.appendingPathComponent("ActivityImport-" + UUID().uuidString + ".noindex")
        let staged = work.appendingPathComponent(directoryName)
        try ScreenshotMigrationIO.createDirectory(staged)
        for (path, selected) in selection.sorted(by: { $0.key < $1.key }) {
            try ScreenshotMigrationIO.copyFile(from: selected.url, to: staged.appendingPathComponent(path), expected: selected.entry)
        }
        let files = selection.mapValues(\.provenance)
        let expected = try ScreenshotMigrationActivityReader.build(root: staged, sourceID: plan.sourceID, sourceSHA256: plan.sourceSHA256, migrationID: plan.migrationID, files: files, historicalManifestBindings: plan.configuration.historicalManifestBindings, legacyHistoryPolicySHA256: plan.configuration.legacyHistoryPolicySHA256)
        try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(expected), to: staged.appendingPathComponent(indexName))
        guard try validateDirectory(staged) == expected else { throw fail("活动暂存重新读取不一致；保留暂存，未提交。") }
        if try ScreenshotMigrationIO.exists(destination) {
            let current = try validateDirectory(destination)
            guard current == expected else { throw fail("目标活动索引已有不同来源或内容；保留宿主新资料，未覆盖。") }
            try FileManager.default.removeItem(at: work)
            return current
        }
        let parent = try ScreenshotMigrationIO.directory(target), stageParent = try ScreenshotMigrationIO.directory(work)
        defer { close(parent); close(stageParent) }
        guard renameatx_np(stageParent, directoryName, parent, directoryName, UInt32(RENAME_EXCL)) == 0, fsync(parent) == 0 else {
            throw fail("活动目录提交冲突或失败；目标与阶段目录均未覆盖。")
        }
        let result = try validate(root: target)
        try FileManager.default.removeItem(at: work)
        return result
    }

    /// root is the screenshot module root, not a migration archive. No original source or archive is needed.
    static func validate(root: URL) throws -> ScreenshotMigratedActivityIndex {
        try validateDirectory(root.appendingPathComponent(directoryName))
    }

    /// Before retirement, bind completeness to the approved inventory as well as to the self-contained index.
    /// Afterwards a retirement receipt binds this verified index/inventory, without retaining old raw data.
    static func validate(root: URL, plan: ScreenshotMigrationPlan, archive: URL) throws -> ScreenshotMigratedActivityIndex {
        try validatePlan(plan)
        let index = try validate(root: root)
        let selected = try select(plan: plan, archive: archive).mapValues(\.provenance)
        guard index.sourceID == plan.sourceID, index.sourceSHA256 == plan.sourceSHA256, index.migrationID == plan.migrationID, index.files == selected,
              index.historicalManifestBindings == plan.configuration.historicalManifestBindings, index.legacyHistoryPolicySHA256 == plan.configuration.legacyHistoryPolicySHA256 else {
            throw fail("活动索引与已批准原迁移库存筛选出的完整活动闭包不符。")
        }
        return index
    }

    static func blockers(root: URL) throws -> [String] { try validate(root: root).blockers }

    /// Reading never reconstitutes a live .gaoaction package or authorizes an external fileURL reference.
    static func readRecord(root: URL, entryID: String) throws -> Data {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }), let file = index.files[entry.relativeRecordPath] else { throw fail("所选只读活动记录不存在。") }
        let data = try ScreenshotMigrationIO.read(root.appendingPathComponent(directoryName + "/" + entry.relativeRecordPath), maximum: max(file.bytes, 1))
        guard data.count == file.bytes, ScreenshotMigrationIO.sha(data) == file.sha256 else { throw fail("所选活动记录在读取前发生变化。") }
        return data
    }

    /// A verified local journal and its same-directory media can be passed to the explicit recovery inspector.
    /// Returning the URL grants no assurance that the media decodes, and never starts a recording.
    static func recordingJournalURL(root: URL, entryID: String) throws -> URL {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID && $0.kind == "recording-recovery" }) else { throw fail("所选记录不是已核验库存的录制恢复日志。") }
        return root.appendingPathComponent(directoryName + "/" + entry.relativeRecordPath)
    }

    /// Only declared attachments are exposed. Manifests/packages remain data-only through readRecord.
    static func attachmentURL(root: URL, entryID: String, relativePath: String) throws -> URL {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }), entry.attachmentPaths.contains(relativePath), index.files[relativePath] != nil else { throw fail("所选文件不属于本活动的已核验附件。") }
        return root.appendingPathComponent(directoryName + "/" + relativePath)
    }

    static func attachmentURLs(root: URL, entryID: String) throws -> [String: URL] {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }) else { throw fail("所选只读活动记录不存在。") }
        return Dictionary(uniqueKeysWithValues: entry.attachmentPaths.map { ($0, root.appendingPathComponent(directoryName + "/" + $0)) })
    }

    /// One full inventory check supplies the immutable record plus all verified attachment URLs to background UI work.
    static func readActivity(root: URL, entryID: String) throws -> ScreenshotMigratedActivityContent {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }), let file = index.files[entry.relativeRecordPath] else { throw fail("所选只读活动记录不存在。") }
        let data = try ScreenshotMigrationIO.read(root.appendingPathComponent(directoryName + "/" + entry.relativeRecordPath), maximum: max(file.bytes, 1))
        guard data.count == file.bytes, ScreenshotMigrationIO.sha(data) == file.sha256 else { throw fail("所选活动记录在读取前发生变化。") }
        return .init(entry: entry, recordData: data, attachments: Dictionary(uniqueKeysWithValues: entry.attachmentPaths.map { ($0, root.appendingPathComponent(directoryName + "/" + $0)) }))
    }

    /// Export an individual attachment as bytes only. A destination conflict is an error, never an overwrite.
    /// The caller supplies the user-selected output location; this does not send a historical result.
    static func exportRecord(root: URL, entryID: String, to output: URL) throws {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }), let file = index.files[entry.relativeRecordPath] else {
            throw fail("所选只读记录不存在。")
        }
        try exportFile(root: root, relativePath: entry.relativeRecordPath, file: file, to: output)
    }

    static func exportAttachment(root: URL, entryID: String, relativePath: String, to output: URL) throws {
        let index = try validate(root: root)
        guard let entry = index.entries.first(where: { $0.id == entryID }), entry.attachmentPaths.contains(relativePath),
              let file = index.files[relativePath] else { throw fail("所选附件不存在。") }
        try exportFile(root: root, relativePath: relativePath, file: file, to: output)
    }

    private static func exportFile(root: URL, relativePath: String, file: ScreenshotMigratedActivityFile, to output: URL) throws {
        guard output.isFileURL, !ScreenshotMigrationIO.contains(root, output),
              output.pathExtension.lowercased() != "gaoaction", try !ScreenshotMigrationIO.exists(output) else {
            throw fail("只能将所选附件导出到模块外的新文件；不覆盖或导出为可执行交接包。")
        }
        // copyFile uses a .noindex ancestor for durable temporary writes. The staging container sits beside output.
        let work = output.deletingLastPathComponent().appendingPathComponent("ActivityExport-" + UUID().uuidString + ".noindex")
        let temporary = work.appendingPathComponent("attachment")
        let expected = ScreenshotMigrationEntry(kind: "file", bytes: file.bytes, sha256: file.sha256)
        try ScreenshotMigrationIO.copyFile(from: root.appendingPathComponent(directoryName + "/" + relativePath), to: temporary, expected: expected)
        let source = try ScreenshotMigrationIO.directory(work), target = try ScreenshotMigrationIO.directory(output.deletingLastPathComponent())
        defer { close(source); close(target) }
        guard renameatx_np(source, "attachment", target, output.lastPathComponent, UInt32(RENAME_EXCL)) == 0, fsync(target) == 0 else { throw fail("附件导出冲突或失败；原活动与暂存文件均保留。") }
        try ScreenshotMigrationIO.requireSnapshot(.init(id: "Export", originalPath: output.path, existed: true, isDirectory: false, inventory: ["@file": expected]), at: output)
        try FileManager.default.removeItem(at: work)
    }

    private struct Selected {
        var url: URL
        var entry: ScreenshotMigrationEntry
        var provenance: ScreenshotMigratedActivityFile
    }

    private static func select(plan: ScreenshotMigrationPlan, archive: URL) throws -> [String: Selected] {
        guard let source = plan.snapshots.first(where: { $0.id == "Source" }), source.existed, source.isDirectory else { throw fail("活动导入缺少真实来源库存。") }
        let sourceRoot = archive.appendingPathComponent("Source")
        try ScreenshotMigrationIO.requireSnapshot(source, at: sourceRoot)
        // Keep the observed Finder metadata in a data-only projection, with its original archive inventory binding.
        // Check before filtering files so a same-named directory or link cannot become an ignored metadata item.
        for (path, entry) in source.inventory where ScreenshotMigrationActivityReader.isFinderMetadataPath(path) {
            try ScreenshotMigrationActivityReader.validateFinderMetadata(at: sourceRoot.appendingPathComponent(path), relativePath: path, entry: entry)
        }
        var result: [String: Selected] = [:]
        var recordingJournals: [(ScreenshotMigrationSnapshot, String, URL)] = []
        func add(_ snapshot: ScreenshotMigrationSnapshot, _ relative: String) throws {
            let sourcePath = snapshot.isDirectory ? relative : "@file"
            guard let entry = snapshot.inventory[sourcePath], entry.kind == "file", entry.linkTarget == nil else { throw fail("当前活动引用的附件缺失或类型不安全：" + relative) }
            let original = snapshot.isDirectory ? URL(fileURLWithPath: snapshot.originalPath).appendingPathComponent(relative) : URL(fileURLWithPath: snapshot.originalPath)
            let provenance = ScreenshotMigratedActivityFile(snapshotID: snapshot.id, originalRelativePath: sourcePath, originalPath: ScreenshotMigrationIO.path(original), bytes: entry.bytes, sha256: entry.sha256)
            let recordPath = projectedPath(provenance)
            guard ScreenshotMigrationValidation.safeRelative(recordPath) else { throw fail("活动投影路径越界。") }
            let archived = archive.appendingPathComponent(snapshot.id)
            let url = snapshot.isDirectory ? archived.appendingPathComponent(relative) : archived
            let value = Selected(url: url, entry: entry, provenance: provenance)
            if let old = result[recordPath], old.provenance != value.provenance { throw fail("活动投影发生路径冲突。") }
            result[recordPath] = value
        }
        for (path, entry) in source.inventory.sorted(by: { $0.key < $1.key }) where entry.kind == "file" {
            if path.hasPrefix("Exchange/") {
                guard ScreenshotMigrationActivityReader.isFinderMetadataPath(path) || path == "Exchange/ProcessedRequests.json" || path.hasPrefix("Exchange/Outgoing/") || path.hasPrefix("Exchange/Staging/") || path.hasPrefix("Exchange/Derived/") else { throw fail("旧Exchange存在不支持的当前资料，不能忽略：" + path) }
                try add(source, path)
            }
            guard !path.hasPrefix("DeletedHistory/"), !path.hasPrefix("Backups/"), !path.hasPrefix("Source/") else { continue }
            if path.hasSuffix(".recovery.json") { recordingJournals.append((source, path, sourceRoot.appendingPathComponent(path))) }
            else if path.lowercased().hasSuffix(".json"), !path.hasPrefix("Exchange/") {
                let object = try ScreenshotMigrationValidation.object(sourceRoot.appendingPathComponent(path))
                if object["document"] != nil && object["sources"] != nil && object["requestID"] != nil { try add(source, path) }
            }
        }
        if let bindings = plan.configuration.historicalManifestBindings {
            try ScreenshotMigrationHistoryPolicy.validateHistoricalManifestBindings(bindings, snapshots: plan.snapshots)
            let backups = plan.snapshots.first { $0.id == "Backups" }!
            try ScreenshotMigrationIO.requireSnapshot(backups, at: archive.appendingPathComponent(backups.id))
            for binding in bindings {
                let manifestPath = binding.manifestRelativePath
                let manifest = try ScreenshotMigrationValidation.object(archive.appendingPathComponent(backups.id + "/" + manifestPath), maximum: 1_048_576)
                try ScreenshotMigrationActivityReader.validateManifest(manifest)
                guard UUID(uuidString: manifest["requestID"] as? String ?? "")?.uuidString == UUID(uuidString: binding.requestID)?.uuidString,
                      manifest["targetBundleID"] as? String == "com.gaoseries.GaoJieTu" else { throw fail("选定备份manifest不是本次请求的原接收包。") }
                try add(backups, manifestPath)
                let base = String(manifestPath.dropLast("manifest.json".count))
                var declared = Set([manifestPath])
                for (offset, item) in (manifest["items"] as! [[String: Any]]).enumerated() {
                    let relative = item["relativePath"] as! String
                    let path = base + String(offset) + "-" + ScreenshotMigrationActivityReader.safeFilename(URL(fileURLWithPath: relative).lastPathComponent)
                    guard declared.insert(path).inserted, let entry = backups.inventory[path], entry.sha256 == item["sha256"] as? String,
                          entry.bytes == (item["byteCount"] as! NSNumber).int64Value else { throw fail("选定历史原manifest声明的输入附件缺失或摘要不符。") }
                    try add(backups, path)
                }
                // Unknown package files are not silently omitted from the selected original closure.
                let physical = Set(backups.inventory.filter { $0.key.hasPrefix(base) && $0.value.kind != "directory" }.map(\.key))
                guard physical == declared else { throw fail("选定历史包存在未声明资料或危险链接，不能截断原始闭包。") }
            }
        }
        if let expected = plan.configuration.legacyHistoryPolicySHA256 {
            guard let policy = plan.snapshots.first(where: { $0.id == ScreenshotMigrationHistoryPolicy.snapshotID }),
                  policy.existed, !policy.isDirectory, policy.inventory["@file"]?.sha256 == expected else { throw fail("历史处置原始凭据未纳入明确批准的真实文件库存。") }
            try ScreenshotMigrationIO.requireSnapshot(policy, at: archive.appendingPathComponent(policy.id))
            try ScreenshotMigrationHistoryPolicy.validateRawPolicy(at: archive.appendingPathComponent(policy.id), expectedSHA256: expected)
            try add(policy, "@file")
        } else if plan.snapshots.contains(where: { $0.id == ScreenshotMigrationHistoryPolicy.snapshotID }) {
            throw fail("历史处置凭据没有明确选择的原字节摘要，不能据此解除退役阻挡。")
        }
        // Only explicitly selected standalone external journals are current records. Backup trees stay excluded.
        for snapshot in plan.snapshots where snapshot.existed && !snapshot.isDirectory && snapshot.id != "Source" && snapshot.originalPath.hasSuffix(".recovery.json") {
            try ScreenshotMigrationIO.requireSnapshot(snapshot, at: archive.appendingPathComponent(snapshot.id))
            recordingJournals.append((snapshot, "@file", archive.appendingPathComponent(snapshot.id)))
        }
        for (snapshot, relative, journalURL) in recordingJournals {
            try add(snapshot, relative)
            let object = try ScreenshotMigrationValidation.object(journalURL, maximum: 1_048_576)
            guard let name = object["partialFileName"] as? String, safeName(name) else { throw fail("录制恢复媒体路径越界。") }
            let originalJournal = snapshot.isDirectory ? URL(fileURLWithPath: snapshot.originalPath).appendingPathComponent(relative) : URL(fileURLWithPath: snapshot.originalPath)
            let originalMedia = originalJournal.deletingLastPathComponent().appendingPathComponent(name)
            if snapshot.isDirectory {
                let prefix = (relative as NSString).deletingLastPathComponent
                try add(snapshot, prefix.isEmpty ? name : prefix + "/" + name)
            } else {
                guard let media = plan.snapshots.first(where: { !$0.isDirectory && $0.existed && ScreenshotMigrationIO.path(URL(fileURLWithPath: $0.originalPath)) == ScreenshotMigrationIO.path(originalMedia) }) else { throw fail("外部录制恢复媒体未纳入原迁移库存；不能删除来源。") }
                try add(media, "@file")
            }
        }
        // A package directory without its manifest is not an empty result. Do not silently drop it.
        for (path, entry) in source.inventory where entry.kind == "directory" {
            let parts = path.split(separator: "/")
            if parts.count == 3, parts[0] == "Exchange", ["Staging", "Outgoing"].contains(String(parts[1])), source.inventory[path + "/manifest.json"]?.kind != "file" {
                throw fail("旧交接包缺少manifest，保留来源并先核对：" + path)
            }
        }
        return result
    }

    private static func validatePlan(_ plan: ScreenshotMigrationPlan) throws {
        guard plan.schemaVersion == 1, plan.sourceBundleID == "com.gaoseries.GaoJieTu", plan.targetBundleID == "com.gaoseries.GaoCaoZuo",
              plan.migrationID == "screenshot-" + plan.sourceSHA256, validSHA(plan.sourceSHA256),
              plan.sourceSHA256 == ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(plan.snapshots)),
              plan.sourceID == "com.gaoseries.GaoJieTu:" + ScreenshotMigrationIO.sha(Data(ScreenshotMigrationIO.path(plan.configuration.sourceRoot).utf8)) else { throw fail("活动迁移计划身份、版本或库存摘要不一致。") }
        var unsigned = plan; unsigned.approvalDigest = ""
        guard validSHA(plan.approvalDigest), ScreenshotMigrationIO.sha(try ScreenshotMigrationIO.encoder.encode(unsigned)) == plan.approvalDigest,
              Set(plan.snapshots.map(\.id)).count == plan.snapshots.count else { throw fail("活动迁移确认摘要或来源身份重复。") }
        if let bindings = plan.configuration.historicalManifestBindings {
            try ScreenshotMigrationHistoryPolicy.validateHistoricalManifestBindings(bindings, snapshots: plan.snapshots)
        }
        if let hash = plan.configuration.legacyHistoryPolicySHA256 {
            guard validSHA(hash), let auxiliary = plan.configuration.auxiliaries.first(where: { $0.id == ScreenshotMigrationHistoryPolicy.snapshotID }),
                  auxiliary.required, let snapshot = plan.snapshots.first(where: { $0.id == auxiliary.id }), snapshot.existed, !snapshot.isDirectory,
                  snapshot.originalPath == ScreenshotMigrationIO.path(auxiliary.url), snapshot.inventory["@file"]?.sha256 == hash else { throw fail("历史处置凭据未绑定本次批准计划及原文件摘要。") }
        } else if plan.configuration.auxiliaries.contains(where: { $0.id == ScreenshotMigrationHistoryPolicy.snapshotID }) {
            throw fail("历史处置凭据缺少明确选择的原文件摘要。")
        }
        for snapshot in plan.snapshots {
            guard safeName(snapshot.id), snapshot.originalPath.hasPrefix("/") else { throw fail("活动来源路径或身份无效。") }
            for (path, value) in snapshot.inventory {
                guard (path == "@file" && !snapshot.isDirectory || ScreenshotMigrationValidation.safeRelative(path)), ["directory", "file", "symlink"].contains(value.kind) else { throw fail("活动来源库存路径或类型损坏。") }
            }
        }
    }

    private static func validateDirectory(_ directory: URL) throws -> ScreenshotMigratedActivityIndex {
        let object = try ScreenshotMigrationValidation.object(directory.appendingPathComponent(indexName))
        guard object["schemaVersion"] as? Int == 1 else { throw fail("活动索引版本不受支持。") }
        let indexBytes = try ScreenshotMigrationIO.read(directory.appendingPathComponent(indexName), maximum: 67_108_864)
        let index = try JSONDecoder().decode(ScreenshotMigratedActivityIndex.self, from: indexBytes)
        guard try ScreenshotMigrationIO.encoder.encode(index) == indexBytes else { throw fail("活动索引不是受支持的原子生成格式或含未支持字段。") }
        guard index.schemaVersion == 1, validSHA(index.sourceSHA256), index.migrationID == "screenshot-" + index.sourceSHA256,
              index.sourceID.hasPrefix("com.gaoseries.GaoJieTu:"), validSHA(String(index.sourceID.dropFirst("com.gaoseries.GaoJieTu:".count))) else { throw fail("活动索引来源身份或版本无效。") }
        let physical = try ScreenshotMigrationIO.snapshot(id: "Activity", url: directory, required: true)
        guard physical.inventory[indexName] == ScreenshotMigrationEntry(kind: "file", bytes: Int64(indexBytes.count), sha256: ScreenshotMigrationIO.sha(indexBytes)) else { throw fail("活动索引在读取/盘点期间改变。") }
        let actualFiles = physical.inventory.filter { $0.value.kind == "file" && $0.key != indexName }
        guard actualFiles.count == index.files.count, physical.inventory.values.allSatisfy({ ["file", "directory"].contains($0.kind) }) else { throw fail("活动附件缺失、存在未索引文件或危险链接。") }
        var originals = Set<String>()
        var directoryOrigins: [String: String] = [:]
        for (path, file) in index.files {
            guard ScreenshotMigrationValidation.safeRelative(path), path.hasPrefix("Records/"), safeName(file.snapshotID),
                  file.originalPath.hasPrefix("/"), !file.originalPath.contains("\0"), !file.originalPath.contains("//"), !file.originalPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), originals.insert(file.originalPath).inserted,
                  file.originalRelativePath == "@file" || ScreenshotMigrationValidation.safeRelative(file.originalRelativePath),
                  file.bytes >= 0, validSHA(file.sha256), actualFiles[path] == ScreenshotMigrationEntry(kind: "file", bytes: file.bytes, sha256: file.sha256) else { throw fail("活动附件摘要、来源或引用不完整：" + path) }
            guard path == projectedPath(file) else { throw fail("活动附件来源映射被改写。") }
            if file.snapshotID == "Backups" {
                guard file.originalRelativePath != "@file", file.originalPath.hasSuffix("/" + file.originalRelativePath) else { throw fail("活动备份原路径与相对引用不符。") }
                let originalRoot = String(file.originalPath.dropLast(file.originalRelativePath.count + 1))
                guard directoryOrigins[file.snapshotID] == nil || directoryOrigins[file.snapshotID] == originalRoot else { throw fail("同一活动备份库存被混接到不同原始目录。") }
                directoryOrigins[file.snapshotID] = originalRoot
            }
            if file.snapshotID == "Source" {
                guard file.originalRelativePath != "@file", file.originalPath.hasSuffix("/" + file.originalRelativePath) else { throw fail("活动来源路径与相对引用不符。") }
                let originalRoot = String(file.originalPath.dropLast(file.originalRelativePath.count + 1))
                guard index.sourceID == "com.gaoseries.GaoJieTu:" + ScreenshotMigrationIO.sha(Data(originalRoot.utf8)) else { throw fail("活动原件路径与来源身份不一致。") }
            }
        }
        let rebuilt = try ScreenshotMigrationActivityReader.build(root: directory, sourceID: index.sourceID, sourceSHA256: index.sourceSHA256, migrationID: index.migrationID, files: index.files, historicalManifestBindings: index.historicalManifestBindings, legacyHistoryPolicySHA256: index.legacyHistoryPolicySHA256)
        guard rebuilt == index else { throw fail("活动索引与原记录重新推导不符；不能隐藏未完成事务或改写状态。") }
        return rebuilt
    }

    static func safeName(_ value: String) -> Bool { ScreenshotMigrationValidation.safeRelative(value) && !value.contains("/") && value.utf8.count <= 255 }
    private static func projectedPath(_ file: ScreenshotMigratedActivityFile) -> String {
        if file.snapshotID == ScreenshotMigrationHistoryPolicy.snapshotID { return ScreenshotMigrationHistoryPolicy.projectedPath }
        if file.snapshotID == "Source", ScreenshotMigrationActivityReader.isFinderMetadataPath(file.originalRelativePath) { return ScreenshotMigrationActivityReader.finderMetadataProjection(file.originalRelativePath) }
        if file.originalRelativePath != "@file" { return "Records/" + file.snapshotID + "/" + file.originalRelativePath }
        let original = URL(fileURLWithPath: file.originalPath)
        // Standalone journals/media were separate archive snapshots; retain their same-directory relationship.
        let parent = ScreenshotMigrationIO.sha(Data(ScreenshotMigrationIO.path(original.deletingLastPathComponent()).utf8))
        return "Records/ExternalRecordings/" + parent + "/" + original.lastPathComponent
    }
    static func validSHA(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func fail(_ message: String) -> ScreenshotMigrationError { .invalid(message) }
}
