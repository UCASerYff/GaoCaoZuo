import Foundation
import CoreFoundation

/// Foundation-only historical readers. In particular this never calls live transport/ledger/result writers.
enum ScreenshotMigrationActivityReader {
    private struct Package {
        var path: String
        var manifest: [String: Any]
        var attachments: [String]
        var staged: Bool
        var requestID: String { manifest["requestID"] as! String }
        var kind: String { manifest["kind"] as! String }
        var reply: String? { manifest["inReplyTo"] as? String }
        var status: String { manifest["status"] as? String ?? "request" }
    }
    private static let terminal = Set(["completed", "partial", "cancelled", "failed", "unsupported"])
    private static let phases = terminal.union(["received", "approved", "executing"])
    private static let actions = Set("capture.region capture.window capture.display ocr.files images.annotate images.pin text.translate storage.inspect cleanup.review apps.uninstall.review files.search files.choose files.reveal associations.manage documents.open documents.newText research.importDocuments portal.openSite portal.openWorkspace portal.focusSearch portal.proposeSite portal.prepareDownload windows.overview desktop.openSettings downloads.prepare".split(separator: " ").map(String.init))
    private static let fail = ScreenshotMigrationActivity.fail
    private static let safeName = ScreenshotMigrationActivity.safeName
    private static let validSHA = ScreenshotMigrationActivity.validSHA

    // Only these two observed Source files are Finder metadata, never package contents or business records.
    static func isFinderMetadataPath(_ path: String) -> Bool {
        path == "Exchange/.DS_Store" || path == "Exchange/Outgoing/.DS_Store"
    }

    static func finderMetadataProjection(_ path: String) -> String { "Records/Metadata/Source/" + path }

    static func validateFinderMetadata(at url: URL, relativePath: String, entry: ScreenshotMigrationEntry) throws {
        guard isFinderMetadataPath(relativePath), entry.kind == "file", entry.linkTarget == nil,
              entry.bytes >= 8, entry.bytes <= 16_777_216 else { throw fail("Finder元数据路径、普通文件类型或读取预算不符：" + relativePath) }
        // read() rejects links and file identity changes. Preserve the complete original bytes, not a parsed replacement.
        let bytes = try ScreenshotMigrationIO.read(url, maximum: 16_777_216)
        guard Int64(bytes.count) == entry.bytes, ScreenshotMigrationIO.sha(bytes) == entry.sha256,
              bytes.starts(with: [0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31]) else { throw fail("Finder元数据摘要、大小或原始格式头不符，不能按非业务资料处理：" + relativePath) }
    }

    static func build(root: URL, sourceID: String, sourceSHA256: String, migrationID: String, files: [String: ScreenshotMigratedActivityFile], historicalManifestBindings: [ScreenshotHistoricalManifestBinding]? = nil, legacyHistoryPolicySHA256: String? = nil) throws -> ScreenshotMigratedActivityIndex {
        var entries: [ScreenshotMigratedActivityEntry] = [], blockers: [String] = []
        var consumed = Set<String>()
        for (path, file) in files where file.snapshotID == "Source" && isFinderMetadataPath(file.originalRelativePath) {
            guard path == finderMetadataProjection(file.originalRelativePath) else { throw fail("Finder元数据未保存在专用只读投影区。") }
            try validateFinderMetadata(at: root.appendingPathComponent(path), relativePath: file.originalRelativePath,
                                       entry: .init(kind: "file", bytes: file.bytes, sha256: file.sha256))
            consumed.insert(path)
        }
        var warnings: [String] = [], dispositions: [ScreenshotLegacyHistoryDisposition] = []
        let policy = try ScreenshotMigrationHistoryPolicy.load(root: root, files: files, expectedSHA256: legacyHistoryPolicySHA256)
        if policy != nil { consumed.insert(ScreenshotMigrationHistoryPolicy.projectedPath) }
        let historical = historicalManifestBindings ?? []
        if historicalManifestBindings != nil {
            var inventory: [String: ScreenshotMigrationEntry] = [:]
            for file in files.values where file.snapshotID == "Backups" {
                guard inventory[file.originalRelativePath] == nil else { throw fail("历史备份投影的来源路径重复。") }
                inventory[file.originalRelativePath] = .init(kind: "file", bytes: file.bytes, sha256: file.sha256)
            }
            try ScreenshotMigrationHistoryPolicy.validateHistoricalManifestBindings(historical, snapshots: [.init(id: "Backups", originalPath: "/", existed: true, isDirectory: true, inventory: inventory)])
        } else if files.values.contains(where: { $0.snapshotID == "Backups" }) { throw fail("备份活动原manifest未纳入明确批准的七条绑定。") }
        func object(_ path: String, maximum: Int64 = 67_108_864) throws -> [String: Any] {
            guard let file = files[path], file.bytes <= maximum else { throw fail("活动主记录缺失或超过读取预算：" + path) }
            return try ScreenshotMigrationValidation.object(root.appendingPathComponent(path), maximum: maximum)
        }
        func identity(_ value: [String: Any]) -> ScreenshotMigratedActivityIdentity {
            .init(requestID: value["requestID"] as? String, sourceBundleID: value["sourceBundleID"] as? String, targetBundleID: value["targetBundleID"] as? String, action: value["action"] as? String, sessionID: value["sessionID"] as? String)
        }
        func append(kind: String, label: String, status: String, path: String, attachments: [String], value: [String: Any], handling: String, discriminator: String = "", disposition: String? = nil) {
            let provenance = files[path]!
            let id = ScreenshotMigrationIO.sha(Data((migrationID + "\n" + kind + "\n" + path + "\n" + discriminator).utf8))
            entries.append(.init(id: id, kind: kind, label: label, status: status, relativeRecordPath: path, attachmentPaths: Array(Set(attachments)).sorted(), originalIdentity: identity(value), provenance: provenance, handlingPath: handling, historyDisposition: disposition))
        }
        func blocked(_ reason: String, _ path: String, _ handling: String) { blockers.append(reason + "；记录：" + path + "；安全处理：" + handling) }
        let ledgerPath = "Records/Source/Exchange/ProcessedRequests.json"
        var records: [String: [String: Any]] = [:]
        if files[ledgerPath] != nil {
            let ledger = try object(ledgerPath, maximum: 16_777_216)
            guard integer(ledger["schemaVersion"], 1, 1), let rows = ledger["records"] as? [[String: Any]], rows.count <= 100_000 else { throw fail("旧交接历史版本、记录格式或数量无效。") }
            for row in rows {
                guard let id = row["requestID"] as? String, let uuid = UUID(uuidString: id), records[uuid.uuidString] == nil,
                      validSHA(row["manifestSHA256"] as? String ?? ""), actions.contains(row["action"] as? String ?? ""),
                      bundle(row["sourceBundleID"]), ["request", "result"].contains(row["kind"] as? String ?? ""), phases.contains(row["phase"] as? String ?? ""),
                      date(row["receivedAt"]) != nil, date(row["updatedAt"]) != nil else { throw fail("旧交接历史身份、状态或摘要无效。") }
                if let name = row["resultPackageName"], !(name is NSNull) { guard let name = name as? String, safeName(name), name.hasSuffix(".gaoaction") else { throw fail("旧交接结果包路径越界。") } }
                records[uuid.uuidString] = row
            }
            consumed.insert(ledgerPath)
        }
        if let policy {
            for approved in Array(policy.missing.values) + [policy.received] {
                guard let row = records[approved.requestID], approved.matches(row) else { throw fail("历史处置凭据与本次原ledger的请求、原manifest摘要、动作、来源或状态不一致。") }
            }
        }
        var packages: [Package] = []
        for path in files.keys.sorted() {
            let logical = files[path]!.originalRelativePath
            let provenance = files[path]!
            let historicalBinding = historical.first { $0.snapshotID == provenance.snapshotID && $0.manifestRelativePath == logical }
            guard provenance.snapshotID == "Source" && logical.hasSuffix("/manifest.json") && logical.hasPrefix("Exchange/") || historicalBinding != nil else { continue }
            let parts = historicalBinding == nil ? logical.split(separator: "/").map(String.init) : Array(logical.split(separator: "/").suffix(4)).map(String.init)
            guard parts.count == 4, parts[0] == "Exchange", ["Staging", "Outgoing"].contains(parts[1]),
                  parts[1] == "Staging" ? UUID(uuidString: parts[2]) != nil : safeName(parts[2]) && parts[2].hasSuffix(".gaoaction") else { throw fail("旧交接包目录身份损坏。") }
            let value = try object(path, maximum: 1_048_576)
            try validateManifest(value)
            if let binding = historicalBinding {
                guard UUID(uuidString: value["requestID"] as? String ?? "")?.uuidString == UUID(uuidString: binding.requestID)?.uuidString,
                      provenance.sha256 == binding.manifestSHA256,
                      records[UUID(uuidString: binding.requestID)!.uuidString] != nil else { throw fail("历史备份原manifest与明确批准的原ledger请求或摘要不一致。") }
            }
            let staged = parts[1] == "Staging"
            guard (staged ? value["targetBundleID"] : value["sourceBundleID"]) as? String == "com.gaoseries.GaoJieTu" else { throw fail("历史交接包不属于原截图提供方，不能取得新宿主身份。") }
            let base = String(path.dropLast("manifest.json".count))
            var attachments: [String] = [], used = Set<String>(), total: Int64 = 0
            let items = value["items"] as! [[String: Any]]
            for (offset, item) in items.enumerated() {
                let relative = item["relativePath"] as! String
                let payloadParts = try payloadComponents(relative)
                let canonical = staged ? base + String(offset) + "-" + safeFilename(URL(fileURLWithPath: relative).lastPathComponent) : base + "payload/" + payloadParts.joined(separator: "/")
                let legacy = base + "payload/" + relative
                let candidates = Set([canonical, legacy]).filter { files[$0] != nil && (!staged || $0 == canonical) }
                guard candidates.count == 1, let attachment = candidates.first, used.insert(attachment).inserted,
                      let file = files[attachment], file.sha256 == item["sha256"] as? String, file.bytes == (item["byteCount"] as! NSNumber).int64Value else { throw fail("旧交接附件缺失、摘要不符或路径解释有歧义：" + path) }
                total += file.bytes
                guard total <= 2_147_483_648 else { throw fail("旧交接附件总大小超出协议预算。") }
                attachments.append(attachment); consumed.insert(attachment)
            }
            let package = Package(path: path, manifest: value, attachments: attachments.sorted(), staged: staged)
            packages.append(package); consumed.insert(path)
            if let sourceFile = files.values.first(where: { $0.snapshotID == "Source" && $0.originalRelativePath != "@file" && $0.originalPath.hasSuffix("/" + $0.originalRelativePath) }) {
                let oldRoot = String(sourceFile.originalPath.dropLast(sourceFile.originalRelativePath.count + 1))
                for reference in value["references"] as! [[String: Any]] {
                    let referenced = URL(string: reference["fileURL"] as! String)!
                    let original = ScreenshotMigrationIO.path(referenced)
                    if original == oldRoot || original.hasPrefix(oldRoot + "/") {
                        blocked("历史原件引用仍指向待退役来源资料", path, "在新宿主导出或重新选定需要的现用文件并核对来源引用；该fileURL仅保留历史元数据，不自动读取或修改原manifest")
                    }
                }
            }
            if staged, let record = records[UUID(uuidString: package.requestID)!.uuidString] {
                guard record["manifestSHA256"] as? String == files[path]!.sha256, record["sourceBundleID"] as? String == value["sourceBundleID"] as? String,
                      record["action"] as? String == value["action"] as? String, record["kind"] as? String == package.kind else { throw fail("旧交接历史与原manifest的摘要或身份不符。") }
            } else if staged {
                blocked("旧暂存交接缺少对应历史状态", path, "在只读历史中核对附件与来源，明确完成或取消原事务后重新预览；不得重放旧请求")
            }
            let disposition = UUID(uuidString: package.requestID)?.uuidString == policy?.received.requestID ? ScreenshotMigrationHistoryPolicy.noContinuation : nil
            append(kind: package.kind == "result" ? "exchange-result" : "exchange-request", label: "旧交接 · " + (value["action"] as! String), status: package.status, path: path, attachments: attachments, value: value, handling: "仅查看原manifest与导出单个附件；原provider、nonce与状态保持原样，不执行、不回送", disposition: disposition)
        }
        for (id, row) in records.sorted(by: { $0.key < $1.key }) {
            let originals = packages.filter { $0.staged && UUID(uuidString: $0.requestID)?.uuidString == id }
            guard originals.count <= 1 else { throw fail("同一原请求存在多个当前或备份原manifest闭包，不能任意选择。") }
            let approvedMissing = policy?.missing[id]
            var disposition: String?
            if let approvedMissing {
                guard originals.isEmpty, approvedMissing.matches(row) else { throw fail("获准保留的不完整历史范围已改变，不能复用旧处置授权。") }
                warnings.append("永久历史完整性未通过：原manifest缺失；原phase=" + approvedMissing.phase + "；请求=" + id + "；仅获准只读迁入及其余闸门完成后退役，不代表原请求完成、取消或历史补全。")
                disposition = ScreenshotMigrationHistoryPolicy.incomplete
                dispositions.append(.init(requestID: id, ledgerRowSHA256: try ScreenshotMigrationHistoryPolicy.rowSHA256(row), originalPhase: approvedMissing.phase, disposition: ScreenshotMigrationHistoryPolicy.incomplete))
            } else if originals.isEmpty { blocked("旧交接状态缺少原manifest，关联无法完整核验", ledgerPath + "#" + id, "保留来源，补齐原包后重新导入；不根据状态伪造请求") }
            var attachments = originals.flatMap(\.attachments)
            if let name = row["resultPackageName"] as? String {
                let resultPath = "Records/Source/Exchange/Outgoing/" + name + "/manifest.json"
                guard let result = packages.first(where: { $0.path == resultPath }), result.kind == "result", UUID(uuidString: result.reply ?? "")?.uuidString == id,
                      result.manifest["targetBundleID"] as? String == row["sourceBundleID"] as? String, result.manifest["action"] as? String == row["action"] as? String,
                      result.status == row["phase"] as? String else { throw fail("旧交接历史所指结果缺失或请求/provider/状态关联冲突。") }
                attachments += result.attachments
            }
            let phase = row["phase"] as! String
            if id == policy?.received.requestID, let approved = policy?.received {
                guard approved.matches(row), originals.count == 1, let original = originals.first, original.kind == "request",
                      files[original.path]?.snapshotID == "Source", files[original.path]?.sha256 == approved.manifestSHA256,
                      files[original.path]?.originalPath == approved.originalManifestPath,
                      !packages.contains(where: { !$0.staged && UUID(uuidString: $0.reply ?? "")?.uuidString == id }) else { throw fail("不再接续授权与原received请求的真实manifest、原路径或结果状态不符。") }
                disposition = ScreenshotMigrationHistoryPolicy.noContinuation
                dispositions.append(.init(requestID: id, ledgerRowSHA256: try ScreenshotMigrationHistoryPolicy.rowSHA256(row), originalPhase: phase, disposition: ScreenshotMigrationHistoryPolicy.noContinuation))
            } else if row["kind"] as? String == "request", !terminal.contains(phase) {
                blocked("旧请求仍处于 " + phase, ledgerPath + "#" + id, "在来源关闭前明确完成或取消事务并重新预览；可先导出已生成附件，绝不重放")
            }
            if row["kind"] as? String == "result" {
                guard let original = originals.first, original.kind == "result" else { throw fail("被动接收的历史结果缺少原result manifest。") }
                // Original receivers persisted phase=received for results. Do not fabricate a terminal ledger phase.
                if original.status == "pending" { blocked("原结果仍为 pending", original.path, "核对原提供方的终态结果并重新导入；不发送旧结果") }
            }
            append(kind: "exchange-state", label: "旧交接状态 · " + (row["action"] as! String), status: phase, path: ledgerPath, attachments: attachments, value: row, handling: disposition == ScreenshotMigrationHistoryPolicy.noContinuation ? "本人已明确不再接续此旧请求；保留原received状态，不记为完成或取消，不执行、重试或回送" : disposition == ScreenshotMigrationHistoryPolicy.incomplete ? "原manifest确实缺失，历史完整性永久未通过；本人仅批准只读迁入及其余闸门完成后退役，不伪造原包或原终态" : "按原状态只读展示；与原manifest/结果包联合核验，不创建活跃ledger记录", discriminator: id, disposition: disposition)
        }
        for package in packages where !package.staged && package.kind == "result" {
            let relatedID = UUID(uuidString: package.reply ?? "")?.uuidString ?? ""
            guard let row = records[relatedID], row["kind"] as? String == "request",
                  let request = packages.first(where: { $0.staged && $0.kind == "request" && UUID(uuidString: $0.requestID)?.uuidString == relatedID }),
                  request.manifest["action"] as? String == package.manifest["action"] as? String,
                  request.manifest["sourceBundleID"] as? String == package.manifest["targetBundleID"] as? String,
                  request.manifest["targetBundleID"] as? String == package.manifest["sourceBundleID"] as? String else {
                blocked("旧结果缺少可核验的原请求闭包", package.path, "补齐原ledger与manifest并核对请求/provider/动作关联后重新预览；不伪造送达或重放")
                continue
            }
            if terminal.contains(package.status), terminal.contains(row["phase"] as? String ?? ""), package.status != row["phase"] as? String {
                blocked("旧结果与原ledger终态矛盾", package.path, "保留双方并核对原事务的真实终态后重新预览；不根据任意结果推断已完成或已送达")
            }
            guard package.status == "pending" else { continue }
            // sendPending appends a package; finishing appends a separate terminal package without deleting pending.
            let superseded = packages.contains { other in
                !other.staged && other.kind == "result" && terminal.contains(other.status) && other.status == row["phase"] as? String && other.reply == package.reply && other.manifest["sourceBundleID"] as? String == package.manifest["sourceBundleID"] as? String && other.manifest["targetBundleID"] as? String == package.manifest["targetBundleID"] as? String && other.manifest["action"] as? String == package.manifest["action"] as? String && ((row["resultPackageName"] as? String).map { other.path == "Records/Source/Exchange/Outgoing/" + $0 + "/manifest.json" } ?? false)
            }
            if !superseded { blocked("旧交接保留了尚无终态结果的 pending 包", package.path, "核对原事务终态或明确取消后重新预览；保留附件，不回送旧pending") }
        }
        let sourceLogical = Set(files.values.filter { $0.snapshotID == "Source" }.map(\.originalRelativePath))
        for path in files.keys.sorted() where path.lowercased().hasSuffix(".json") && !consumed.contains(path) {
            let value = try object(path)
            if value["document"] != nil && value["sources"] != nil && value["requestID"] != nil {
                let attachments = try validateOCR(value, packages: packages, files: files)
                consumed.insert(path); attachments.forEach { consumed.insert($0) }
                let doc = value["document"] as! [String: Any]
                let pages = doc["pages"] as! [[String: Any]]
                let partial = (doc["wasCancelled"] as? Bool == true) || pages.contains { $0["status"] as? String != "completed" }
                append(kind: "ocr-recovery", label: "旧OCR恢复 · " + String(pages.count) + "页", status: partial ? "partial" : "completed", path: path, attachments: attachments, value: value, handling: "读取已完成文本、页面与原始输入附件；需要重新识别时新建本次操作，不重放旧请求")
            } else if files[path]!.originalPath.hasSuffix(".recovery.json") {
                let media = try validateRecording(value, journal: path, files: files)
                consumed.insert(path); consumed.insert(media)
                let state = value["state"] as! String
                // A complete failed/idle pair is manageable current recovery data, without a playability claim.
                // Active producer states require a new frozen preview after the old host normally ends the session.
                if ["preparing", "recording", "paused", "stopping"].contains(state) {
                    blocked("旧录制仍处于活跃状态 " + state, path, "在旧宿主正常结束或明确取消录制，停止来源写入并重新预览；不重录、不丢弃部分媒体")
                }
                append(kind: "recording-recovery", label: "旧录制恢复 · " + (value["requestedFileName"] as! String), status: state, path: path, attachments: [media], value: value, handling: "保留原journal与部分媒体；未做播放/解码检查，不保证可修复；仅单独导出供明确恢复")
            }
        }
        // Derived exports are current generated work, even if not named in a terminal result package.
        for path in files.keys.sorted() where !consumed.contains(path) {
            let file = files[path]!
            let logical = file.originalRelativePath
            guard file.snapshotID == "Source", logical.hasPrefix("Exchange/Derived/") else { throw fail("活动投影包含无法关联的资料或包内未声明附件：" + path) }
            let components = logical.split(separator: "/").map(String.init)
            guard components.count >= 4, let id = UUID(uuidString: components[2]), let row = records[id.uuidString] else { throw fail("旧派生输出缺少原请求状态，不能假定可删除来源：" + path) }
            // Unknown recovery JSON cannot masquerade as an ordinary derived export.
            guard !logical.lowercased().contains("recovery") else { throw fail("旧恢复记录结构不受支持：" + path) }
            consumed.insert(path)
            append(kind: "derived-attachment", label: "旧派生附件 · " + URL(fileURLWithPath: logical).lastPathComponent, status: row["phase"] as! String, path: ledgerPath, attachments: [path], value: row, handling: "单独读取或导出已有输出；不执行原请求", discriminator: logical)
        }
        // This map is also checked by OCR/recording readers; make accidental duplicates a hard error.
        guard sourceLogical.count == files.values.filter({ $0.snapshotID == "Source" }).count, consumed.count == files.count else { throw fail("活动来源引用重复或投影未完全解析。") }
        var policyBinding: ScreenshotLegacyHistoryPolicyBinding?
        if policy != nil {
            guard dispositions.count == 9, Set(dispositions.map(\.requestID)).count == 9,
                  let policySHA = legacyHistoryPolicySHA256, let ledger = files[ledgerPath] else { throw fail("历史处置必须恰好绑定八条原始缺失终态与一条不再接续received，不能遗漏或扩大。") }
            policyBinding = .init(sourceID: sourceID, sourceSHA256: sourceSHA256, policySHA256: policySHA, ledgerSHA256: ledger.sha256, dispositions: dispositions.sorted { $0.requestID < $1.requestID })
        }
        return .init(sourceID: sourceID, sourceSHA256: sourceSHA256, migrationID: migrationID, entries: entries.sorted { $0.id < $1.id }, blockers: Array(Set(blockers)).sorted(), files: files, historicalManifestBindings: historicalManifestBindings, legacyHistoryPolicySHA256: legacyHistoryPolicySHA256, legacyHistoryPolicyBinding: policyBinding, integrityWarnings: policy == nil ? nil : warnings.sorted())
    }

    static func validateManifest(_ value: [String: Any]) throws {
        let required = Set(["schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action", "createdAt", "expiresAt", "nonce", "items", "references", "parameters"])
        guard required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(["inReplyTo", "status", "errorCode", "provenance"])),
              integer(value["schemaVersion"], 1, 1), ["request", "result"].contains(value["kind"] as? String ?? ""), UUID(uuidString: value["requestID"] as? String ?? "") != nil,
              bundle(value["sourceBundleID"]), bundle(value["targetBundleID"]), actions.contains(value["action"] as? String ?? ""),
              let created = date(value["createdAt"]), let expires = date(value["expiresAt"]), expires > created, expires.timeIntervalSince(created) <= 120,
              let nonce = value["nonce"] as? String, Data(base64Encoded: nonce)?.count == 32,
              let items = value["items"] as? [[String: Any]], let references = value["references"] as? [[String: Any]], items.count + references.count <= 256,
              value["parameters"] is [String: Any] else { throw fail("历史manifest字段、schema、nonce或原始有效期损坏。") }
        var ids = Set<String>(), paths = Set<String>()
        for item in items {
            guard Set(item.keys) == ["id", "relativePath", "uti", "byteCount", "sha256"], let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 256, ids.insert(id).inserted,
                  let path = item["relativePath"] as? String, let uti = item["uti"] as? String, !uti.isEmpty, uti.utf8.count <= 256, !uti.contains(where: { $0.isWhitespace || $0 == "\0" }),
                  integer(item["byteCount"], 0, 2_147_483_648), validSHA(item["sha256"] as? String ?? "") else { throw fail("历史交接附件元数据无效。") }
            guard paths.insert(try payloadComponents(path).joined(separator: "/")).inserted else { throw fail("历史交接附件路径重复。") }
        }
        for reference in references {
            let required = Set(["id", "kind", "fileURL", "displayName", "declaredIdentity"])
            guard required.isSubset(of: Set(reference.keys)), Set(reference.keys).isSubset(of: required.union(["bundleID", "sha256"])),
                  let id = reference["id"] as? String, !id.isEmpty, id.utf8.count <= 256, ids.insert(id).inserted,
                  ["file", "directory", "application"].contains(reference["kind"] as? String ?? ""), let display = reference["displayName"] as? String, !display.isEmpty, display.utf8.count <= 4096,
                  let text = reference["fileURL"] as? String, let url = URL(string: text), url.isFileURL, [nil, "", "localhost"].contains(url.host), url.query == nil, url.fragment == nil,
                  url.user == nil, url.password == nil, url.path.hasPrefix("/"), !url.path.contains("\0"), !url.path.contains("//"), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  let declared = reference["declaredIdentity"] as? [String: Any], Set(declared.keys) == ["volumeUUID", "device", "inode", "byteCount", "modifiedAt"] else { throw fail("历史原件引用字段或路径不完整；引用不会授权外部读取。") }
            for key in ["device", "inode", "byteCount"] where !(declared[key] is NSNull) { guard number(declared[key], 0, 1.8446744073709552e19), (declared[key] as! NSNumber).doubleValue.rounded(.towardZero) == (declared[key] as! NSNumber).doubleValue else { throw fail("历史原件身份数值无效。") } }
            if !(declared["volumeUUID"] is NSNull), !(declared["volumeUUID"] is String) { throw fail("历史原件卷身份无效。") }
            if !(declared["modifiedAt"] is NSNull), date(declared["modifiedAt"]) == nil { throw fail("历史原件时间无效。") }
            if reference["kind"] as? String == "application" { guard bundle(reference["bundleID"]) else { throw fail("历史应用引用缺少Bundle ID。") } }
            else if reference["bundleID"] != nil { throw fail("历史普通文件引用混入应用身份。") }
            if let hash = reference["sha256"] { guard reference["kind"] as? String == "file", validSHA(hash as? String ?? "") else { throw fail("历史原件引用摘要无效。") } }
        }
        if value["kind"] as? String == "result" {
            guard UUID(uuidString: value["inReplyTo"] as? String ?? "") != nil, terminal.union(["pending"]).contains(value["status"] as? String ?? ""), value["provenance"] is [String: Any] else { throw fail("历史结果的原请求关联、状态或provenance缺失。") }
            if let error = value["errorCode"] { guard let error = error as? String, error.utf8.count <= 256 else { throw fail("历史结果错误码无效。") } }
        } else {
            guard value["inReplyTo"] == nil, value["status"] == nil, value["errorCode"] == nil, value["provenance"] == nil else { throw fail("历史请求混入结果字段。") }
        }
    }

    private static func validateOCR(_ value: [String: Any], packages: [Package], files: [String: ScreenshotMigratedActivityFile]) throws -> [String] {
        guard integer(value["schemaVersion"], 1, 1), let request = value["requestID"] as? String, UUID(uuidString: request) != nil, date(value["createdAt"]) != nil,
              let mappings = value["sources"] as? [[String: Any]], let doc = value["document"] as? [String: Any], integer(doc["schemaVersion"], 1, 1),
              UUID(uuidString: doc["id"] as? String ?? "") != nil, date(doc["createdAt"]) != nil, doc["engine"] is String, integer(doc["engineRevision"], 0, 2_147_483_647),
              doc["operatingSystem"] is String, let options = doc["options"] as? [String: Any], boolean(doc["wasCancelled"]),
              let originals = doc["sources"] as? [[String: Any]], mappings.count == originals.count, mappings.count <= 256,
              let pages = doc["pages"] as? [[String: Any]], pages.count <= 100_000,
              let package = packages.first(where: { $0.staged && $0.kind == "request" && $0.manifest["action"] as? String == "ocr.files" && $0.requestID == request }) else { throw fail("OCR恢复schema或完整原件暂存manifest缺失，不能仅保留恢复JSON。") }
        guard let languages = options["languages"] as? [String], !languages.isEmpty, languages.count <= 32, languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              ["accurate", "fast"].contains(options["recognitionLevel"] as? String ?? ""), boolean(options["languageCorrection"]), boolean(options["enhanceContrast"]), boolean(options["deskew"]),
              number(options["pdfDPI"], 1, 2400), integer(options["maxPages"], 1, 100_000), integer(options["maxPixelsPerPage"], 1, 1_000_000_000),
              integer(options["maxFileBytes"], 1, 2_147_483_648), integer(options["maximumConcurrency"], 1, 1024), integer(options["memoryBudgetBytes"], 1, 1_099_511_627_776) else { throw fail("OCR恢复识别选项不完整或数值无效。") }
        let manifestItems = package.manifest["items"] as! [[String: Any]]
        var ids = Set<String>(), itemIDs = Set<String>(), pageIDs = Set<String>(), pageKeys = Set<String>(), attachments: [String] = []
        for source in mappings {
            guard let id = source["sourceID"] as? String, UUID(uuidString: id) != nil, ids.insert(id).inserted,
                  let itemID = source["sourceItemID"] as? String, !itemID.isEmpty, itemIDs.insert(itemID).inserted, validSHA(source["sourceSHA256"] as? String ?? ""),
                  let original = originals.first(where: { $0["id"] as? String == id }), original["sha256"] as? String == "" || original["sha256"] as? String == source["sourceSHA256"] as? String,
                  let offset = manifestItems.firstIndex(where: { $0["id"] as? String == itemID }), manifestItems[offset]["sha256"] as? String == source["sourceSHA256"] as? String,
                  original["displayName"] is String, integer(original["byteCount"], 0, 2_147_483_648), integer(original["pageCount"], 0, 100_000), boolean(original["isPDF"]) else { throw fail("OCR恢复sourceID/itemID/原件摘要或元数据关联无效。") }
            let item = manifestItems[offset]
            let path = String(package.path.dropLast("manifest.json".count)) + String(offset) + "-" + safeFilename(URL(fileURLWithPath: item["relativePath"] as! String).lastPathComponent)
            guard let physical = files[path], physical.sha256 == source["sourceSHA256"] as? String, physical.bytes == (item["byteCount"] as! NSNumber).int64Value,
                  original["sha256"] as? String == "" || physical.bytes == (original["byteCount"] as! NSNumber).int64Value else { throw fail("OCR恢复缺少经摘要核验的原始输入附件。") }
            attachments.append(path)
        }
        guard Set(originals.compactMap { $0["id"] as? String }) == ids, originals.count == ids.count else { throw fail("OCR恢复原件身份不完整或重复。") }
        for page in pages {
            guard let pageID = page["id"] as? String, UUID(uuidString: pageID) != nil, pageIDs.insert(pageID).inserted,
                  let sourceID = page["sourceID"] as? String, ids.contains(sourceID), integer(page["pageNumber"], 1, 100_000),
                  pageKeys.insert(sourceID + ":" + String((page["pageNumber"] as! NSNumber).intValue)).inserted,
                  let original = originals.first(where: { $0["id"] as? String == sourceID }),
                  ((page["pageNumber"] as! NSNumber).intValue <= (original["pageCount"] as! NSNumber).intValue || page["status"] as? String != "completed"),
                  page["originalSHA256"] as? String == original["sha256"] as? String,
                  ["completed", "failed", "cancelled"].contains(page["status"] as? String ?? ""), let lines = page["lines"] as? [[String: Any]],
                  lines.count <= 1_000_000, rect(page["mediaBox"]), rect(page["cropBox"]), integer(page["rotation"], -360, 360),
                  integer(page["pixelWidth"], 0, 100_000), integer(page["pixelHeight"], 0, 100_000), number(page["renderScale"], 0, 1000),
                  number(page["elapsedSeconds"], 0, 1e12), number(page["deskewAppliedDegrees"], -360, 360), page["preprocessing"] is [String], page["coordinateSystem"] is String else { throw fail("OCR恢复页面、几何或原件关联不完整。") }
            if original["sha256"] as? String == "", page["status"] as? String == "completed" { throw fail("OCR恢复成功页不能缺少原始识别输入摘要。") }
            if let reason = page["failureReason"], !(reason is String) { throw fail("OCR恢复页面失败说明格式无效。") }
            var lineIDs = Set<String>()
            for line in lines {
                guard let id = line["id"] as? String, UUID(uuidString: id) != nil, lineIDs.insert(id).inserted, line["text"] is String, boolean(line["userEdited"]),
                      rect(line["boundingBox"]), rect(line["pageBoundingBox"]), let corners = line["pageQuadrilateral"] as? [Any], corners.count == 4, corners.allSatisfy(point),
                      number(line["confidence"], 0, 1), line["confidenceSource"] is String, line["languages"] is [String], line["languageDetectionMethod"] is String,
                      integer(line["readingOrder"], 0, 2_147_483_647) else { throw fail("OCR恢复文本行、坐标或置信度无效。") }
                if let original = line["originalText"], !(original is String) { throw fail("OCR恢复原文字段无效。") }
            }
        }
        return attachments.sorted()
    }

    private static func validateRecording(_ value: [String: Any], journal: String, files: [String: ScreenshotMigratedActivityFile]) throws -> String {
        guard integer(value["schemaVersion"], 1, 1), let session = value["sessionID"] as? String, let uuid = UUID(uuidString: session),
              date(value["createdAt"]) != nil, date(value["updatedAt"]) != nil, ["idle", "preparing", "recording", "paused", "stopping", "failed"].contains(value["state"] as? String ?? ""),
              ["video", "audioOnly"].contains(value["mode"] as? String ?? ""), value["sourceDescription"] is String,
              let partial = value["partialFileName"] as? String, safeName(partial), partial.hasPrefix(".gao-recording-" + uuid.uuidString + ".partial."), !partial.contains(".."),
              ["mov", "m4a"].contains(URL(fileURLWithPath: partial).pathExtension.lowercased()), let requested = value["requestedFileName"] as? String, safeName(requested),
              boolean(value["systemAudio"]), boolean(value["microphone"]), let metrics = value["metrics"] as? [String: Any], value["recoveryNote"] is String else { throw fail("录制恢复schema、sessionID、状态或同目录媒体文件名无效。") }
        for key in ["videoFrames", "systemAudioBuffers", "microphoneBuffers", "droppedVideoFrames", "droppedAudioBuffers"] { guard integer(metrics[key], 0, Int64.max) else { throw fail("录制恢复计数不完整或无效。") } }
        for key in ["durationSeconds", "processCPUSeconds"] { guard number(metrics[key], 0, 1e12) else { throw fail("录制恢复时间无效。") } }
        if let latency = metrics["firstSampleLatencySeconds"] { guard number(latency, 0, 1e12) else { throw fail("录制恢复首样本时间无效。") } }
        let original = files[journal]!.originalPath
        guard URL(fileURLWithPath: original).lastPathComponent == ".gao-recording-" + uuid.uuidString + ".recovery.json" else { throw fail("录制恢复日志文件名与sessionID不匹配。") }
        let mediaPath = ScreenshotMigrationIO.path(URL(fileURLWithPath: original).deletingLastPathComponent().appendingPathComponent(partial))
        let candidates = files.filter { $0.value.originalPath == mediaPath }
        guard candidates.count == 1, let media = candidates.first else { throw fail("录制恢复的同目录部分媒体缺失或引用有歧义。") }
        return media.key
    }

    private static func payloadComponents(_ path: String) throws -> [String] {
        guard ScreenshotMigrationValidation.safeRelative(path), path.utf8.count <= 4096 else { throw fail("历史交接附件路径越界。") }
        let parts = path.split(separator: "/").map(String.init)
        return parts.count > 1 && parts.first == "payload" ? Array(parts.dropFirst()) : parts
    }
    static func safeFilename(_ value: String) -> String {
        var name = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }.map(String.init).joined()
        while name.utf8.count > 220 { name.removeLast() }
        return ["", ".", ".."].contains(name) ? "交接文档" : name
    }
    private static func boolean(_ value: Any?) -> Bool { guard let n = value as? NSNumber else { return false }; return CFGetTypeID(n) == CFBooleanGetTypeID() }
    private static func number(_ value: Any?, _ lower: Double, _ upper: Double) -> Bool { guard let n = value as? NSNumber, !boolean(value) else { return false }; return n.doubleValue.isFinite && (lower...upper).contains(n.doubleValue) }
    private static func integer(_ value: Any?, _ lower: Int64, _ upper: Int64) -> Bool { guard number(value, Double(lower), Double(upper)), let n = value as? NSNumber else { return false }; return n.doubleValue.rounded(.towardZero) == n.doubleValue }
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.date(from: text)
    }
    private static func bundle(_ value: Any?) -> Bool { guard let text = value as? String, text.contains("."), text.utf8.count <= 255 else { return false }; return text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 } }
    // Foundation Codable encodes CGRect/CGPoint as nested coordinate arrays; accepting other shapes hides malformed records.
    private static func point(_ value: Any) -> Bool { guard let a = value as? [Any], a.count == 2 else { return false }; return a.allSatisfy { number($0, -1e12, 1e12) } }
    private static func rect(_ value: Any?) -> Bool { guard let a = value as? [Any], a.count == 2 else { return false }; return a.allSatisfy(point) }
}
