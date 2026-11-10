import Foundation
import CoreFoundation

/// Validates persisted v1 business metadata against a complete physical inventory, without constructing a writable store.
enum ScreenshotMigrationValidation {
    enum AuxiliaryRole {
        case generic
        case legacyBackupContainer
        case legacyBackupRoot
    }

    static func object(_ url: URL, maximum: Int64 = 67_108_864) throws -> [String: Any] {
        let result = try rawJSONObject(url, maximum: maximum)
        try requireDefaultSchema(result, url: url)
        return result
    }
    private static func rawJSONObject(_ url: URL, maximum: Int64 = 67_108_864) throws -> [String: Any] {
        let bytes = try ScreenshotMigrationIO.read(url, maximum: maximum)
        try ScreenshotMigrationJSONKeys.validate(bytes)
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw fail("JSON主记录不是对象：" + url.lastPathComponent) }
        return result
    }
    private static func requireDefaultSchema(_ result: [String: Any], url: URL) throws {
        if let schema = result["schemaVersion"] { guard integer(schema, 1, 1) else { throw fail("资料版本过新或损坏：" + url.lastPathComponent) } }
    }
    static func validate(root: URL, snapshot: ScreenshotMigrationSnapshot, logicalRoot: URL) throws {
        guard snapshot.isDirectory, snapshot.inventory["Settings.json"] != nil else { throw fail("真实来源Settings.json缺失；不会将已有资料或空目录当新用户覆盖。") }
        let files = snapshot.inventory
        let settings = try schemaObject(root.appendingPathComponent("Settings.json"), maximum: 1_048_576)
        guard boolean(settings["historyEnabled"]), boolean(settings["silentOCRCopies"]), integer(settings["historyDays"], 1, 3650),
              integer(settings["historyCapacityMB"], 16, 16384), ["标注", "复制", "保存"].contains(settings["captureStrategy"] as? String ?? ""),
              let languages = settings["languages"] as? [String], (1...32).contains(languages.count), languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              let pins = settings["pins"] as? [String], pins.isEmpty else { throw fail("设置参数损坏或存在待核验的旧式贴图引用，已停止迁移，未忽略附件。") }
        for key in ["saveDirectory", "editorPath"] { guard settings[key] == nil || settings[key] is NSNull || settings[key] is String else { throw fail("保存或编辑器路径字段损坏。") } }
        guard files["History.json"] == nil || files["History/History.json"] == nil else { throw fail("检测到两份History主记录，目标冲突需显式核对。") }
        let historyName = files["History.json"] != nil ? "History.json" : "History/History.json"
        if files[historyName] != nil {
            let history = try schemaObject(root.appendingPathComponent(historyName))
            guard let assets = history["assets"] as? [[String: Any]], assets.count <= 100_000 else { throw fail("历史主记录缺少assets或超限。") }
            var ids = Set<String>(), paths = Set<String>()
            for asset in assets {
                guard let id = asset["id"] as? String, validUUID(id), ids.insert(id.lowercased()).inserted,
                      let path = asset["outputPath"] as? String, safeRelative(path), path.hasPrefix("History/"), paths.insert(path).inserted,
                      integer(asset["pixelWidth"], 1, 30000), integer(asset["pixelHeight"], 1, 30000),
                      (asset["pixelWidth"] as! NSNumber).int64Value * (asset["pixelHeight"] as! NSNumber).int64Value <= 100_000_000,
                      number(asset["scale"], 0.001, 8), integer(asset["editVersion"], 0, 2_147_483_647),
                      asset["source"] is String, asset["colorSpace"] is String, number(asset["createdAt"], -1e12, 1e12) else { throw fail("历史身份、路径或图像元数据损坏/重复。") }
                try attachment(files, path: path, sha: asset["sha256"])
            }
        } else if files["History"] != nil { throw fail("History附件目录存在但主记录缺失，已保护原件。") }
        if files["PinnedImages.json"] != nil {
            let pins = try schemaObject(root.appendingPathComponent("PinnedImages.json"), maximum: 1_048_576)
            guard let records = pins["records"] as? [[String: Any]], records.count <= 50 else { throw fail("贴图主记录损坏或超限。") }
            var paths = Set<String>()
            for record in records {
                guard let path = record["imagePath"] as? String, path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      ScreenshotMigrationIO.path(URL(fileURLWithPath: path).deletingLastPathComponent()) == ScreenshotMigrationIO.path(logicalRoot.appendingPathComponent("Pins")),
                      paths.insert(path).inserted, record["windowFrame"] is String,
                      number(record["imageScale"], 0.001, 8), number(record["opacity"], 0.15, 1) else { throw fail("贴图路径、窗口参数或身份损坏。") }
                try attachment(files, path: "Pins/" + URL(fileURLWithPath: path).lastPathComponent, sha: record["sha256"], requireHash: false)
            }
        } else if files["Pins"] != nil { throw fail("Pins附件目录存在但贴图主记录缺失。") }
        let ledgerPath = "Exchange/ProcessedRequests.json"
        if files[ledgerPath] != nil {
            let ledger = try schemaObject(root.appendingPathComponent(ledgerPath))
            guard let records = ledger["records"] as? [[String: Any]], records.count <= 100_000 else { throw fail("旧交接ledger缺少记录或超限。") }
            var ids = Set<String>()
            for record in records {
                guard let id = record["requestID"] as? String, validUUID(id), ids.insert(id.lowercased()).inserted,
                      validSHA(record["manifestSHA256"]), knownActions.contains(record["action"] as? String ?? ""),
                      ["request", "result"].contains(record["kind"] as? String ?? ""), phases.contains(record["phase"] as? String ?? ""),
                      validDate(record["receivedAt"]), validDate(record["updatedAt"]), validBundleID(record["sourceBundleID"]) else { throw fail("旧交接ledger身份、状态或摘要损坏。") }
                if let name = record["resultPackageName"] {
                    guard let name = name as? String, safeName(name), name.hasSuffix(".gaoaction"), files["Exchange/Outgoing/" + name + "/manifest.json"] != nil else { throw fail("旧交接结果包缺失或路径损坏。") }
                }
            }
        } else if files.keys.contains(where: { $0.hasPrefix("Exchange/Staging/") || $0.hasPrefix("Exchange/Derived/") }) { throw fail("交接恢复现物存在但ProcessedRequests缺失，不能按空白迁移。") }
        for (name, entry) in files where entry.kind == "directory" {
            let parts = name.split(separator: "/")
            if parts.count == 3, parts[0] == "Exchange", parts[1] == "Outgoing" {
                guard parts[2].hasSuffix(".gaoaction") else { throw fail("交接输出包未完成或目录名无效。") }
                try package(root: root, base: name, files: files, staged: false)
            } else if parts.count == 3, parts[0] == "Exchange", parts[1] == "Staging" {
                guard validUUID(String(parts[2])) else { throw fail("旧交接暂存目录身份损坏。") }
                try package(root: root, base: name, files: files, staged: true)
            }
        }
        for (name, entry) in files where entry.kind == "file" && name.lowercased().hasSuffix(".json") {
            let value = try object(root.appendingPathComponent(name))
            if name.contains("OCRRecovery") || name.contains("OCR-Recovery") || value["document"] != nil && value["sources"] != nil && value["requestID"] != nil {
                try ocrRecovery(value)
            }
            if name.hasSuffix(".recovery.json") { try recordingRecovery(value, file: name, files: files) }
        }
    }
    static func validateAuxiliary(root: URL, snapshot: ScreenshotMigrationSnapshot, logicalRoot: URL, role: AuxiliaryRole = .generic) throws {
        guard snapshot.existed else { return }
        if !snapshot.isDirectory {
            if root.pathExtension.lowercased() == "json" { _ = try object(root) }
            if root.lastPathComponent.hasSuffix(".recovery.json") { _ = try recordingMediaReferencedByJournal(root) }
            if root.pathExtension.lowercased() == "plist" { _ = try PropertyListSerialization.propertyList(from: ScreenshotMigrationIO.read(root), options: [], format: nil) }
            return
        }
        for (name, entry) in snapshot.inventory where entry.kind == "file" && name.lowercased().hasSuffix(".json") {
            let file = root.appendingPathComponent(name)
            let object: [String: Any]
            if maintenanceLocation(name, role: role, files: snapshot.inventory) {
                let raw = try rawJSONObject(file)
                if maintenanceInteger(raw["schemaVersion"], equals: 2) {
                    guard maintenanceCleanupPlan(raw) else { throw fail("旧备份维护清单格式损坏或未知；未执行或改写维护内容：" + name) }
                } else {
                    // Schema 1 retains its original interpretation, including optional schema fields.
                    try requireDefaultSchema(raw, url: file)
                }
                object = raw
            } else {
                object = try self.object(file)
            }
            if name.hasSuffix(".recovery.json") { try recordingRecovery(object, file: name, files: snapshot.inventory) }
            if name == "Verification.json" || name.hasSuffix("/Verification.json") {
                guard object["verified"] as? Bool == true || object["restoreRehearsal"] as? Bool == true,
                      object["restoreRehearsal"] as? Bool == true,
                      let expected = object["inventory"] as? [String: [String: Any]] else { throw fail("旧备份核验记录损坏或没有恢复演练证据。") }
                let prefix = String(name.dropLast("Verification.json".count)) + "Data/"
                let actual = snapshot.inventory.filter { $0.key.hasPrefix(prefix) && $0.value.kind == "file" }
                guard actual.count == expected.count else { throw fail("旧备份现物与核验清单数量不符。") }
                for (relative, value) in expected {
                    guard safeRelative(relative), let actual = actual[prefix + relative], actual.sha256 == value["sha256"] as? String,
                          actual.bytes == (value["bytes"] as? NSNumber)?.int64Value else { throw fail("旧备份附件缺失或摘要冲突；历史verified不能替代现物核验。") }
                }
                if let directories = object["directories"] as? [String] {
                    let actualDirectories = Set(snapshot.inventory.filter { $0.key.hasPrefix(prefix) && $0.value.kind == "directory" }.map { String($0.key.dropFirst(prefix.count)) })
                    guard directories.allSatisfy(safeRelative), Set(directories) == actualDirectories else { throw fail("旧备份空目录或附件目录拓扑与核验清单不符。") }
                }
            }
            if name == "Installation.json" || name.hasSuffix("/Installation.json") {
                guard object["bundleID"] as? String == "com.gaoseries.GaoJieTu", boolean(object["hadPreviousApp"]) else { throw fail("旧安装收据身份或旧程序状态无效。") }
                if object["hadPreviousApp"] as? Bool == true {
                    let prefix = String(name.dropLast("Installation.json".count))
                    var found = false
                    for app in ["Previous.app", "PreviousInstalled.app"] where snapshot.inventory[prefix + app] != nil {
                        guard snapshot.inventory[prefix + app + "/Contents/Info.plist"]?.kind == "file",
                              snapshot.inventory[prefix + app + "/Contents/MacOS/GaoJieTu"]?.kind == "file" else { throw fail("旧程序备份本体缺失；不能据收据声称恢复可用。") }
                        let infoBytes = try ScreenshotMigrationIO.read(root.appendingPathComponent(prefix + app + "/Contents/Info.plist"), maximum: 1_048_576)
                        guard let info = try PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as? [String: Any],
                              info["CFBundleIdentifier"] as? String == "com.gaoseries.GaoJieTu",
                              info["CFBundleShortVersionString"] as? String == object["previousVersion"] as? String,
                              info["CFBundleVersion"] as? String == object["previousBuild"] as? String else { throw fail("旧程序备份版本/构建与收据不符。") }
                        found = true
                    }
                    guard found else { throw fail("安装收据声明有旧程序，但可恢复程序备份缺失；已停止迁移。") }
                }
            }
        }
        // Validate every archived Data root using the original logical root for absolute pin references.
        let settings = snapshot.inventory.keys.filter { $0 == "Data/Settings.json" || $0.hasSuffix("/Data/Settings.json") }
        for name in settings {
            let prefix = String(name.dropLast("Settings.json".count))
            var nested: [String: ScreenshotMigrationEntry] = [:]
            for (path, entry) in snapshot.inventory where path.hasPrefix(prefix) { nested[String(path.dropFirst(prefix.count))] = entry }
            let data = root.appendingPathComponent(String(prefix.dropLast()))
            try validate(root: data, snapshot: .init(id: "Source", originalPath: data.path, existed: true, isDirectory: true, inventory: nested), logicalRoot: logicalRoot)
        }
    }
    /// Recognizes maintenance metadata only at an explicitly selected legacy backup root.
    /// The inventory supplies physical envelope markers; the normal verification and Data checks still run.
    private static func maintenanceLocation(_ name: String, role: AuxiliaryRole, files: [String: ScreenshotMigrationEntry]) -> Bool {
        guard safeRelative(name) else { return false }
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0.lowercased() == "data" }),
              let filename = parts.last,
              ["CleanupPlan.json", "CleanupPlan-20261026.json", "CleanupPlan-20261026-ReviewedDriver.json"].contains(filename) else { return false }
        let prefix: String
        switch role {
        case .generic: return false
        case .legacyBackupContainer:
            guard parts.count == 2, parts[0].hasSuffix(".noindex") else { return false }
            prefix = parts[0] + "/"
        case .legacyBackupRoot:
            guard parts.count == 1 else { return false }
            prefix = ""
        }
        return files[prefix + "Verification.json"]?.kind == "file" && files[prefix + "Data/Settings.json"]?.kind == "file"
    }
    /// Classifies archived bytes, without resolving plan paths, loading tools, or interpreting old authorization.
    private static func maintenanceCleanupPlan(_ value: [String: Any]) -> Bool {
        guard maintenanceDate(value["preparedAtUTC"]), maintenanceInventory(value["beforeInventory"]),
              maintenanceDirectories(value["beforeDirectories"]), maintenanceLedger(value["beforeLedger"]),
              value["beforeIntegrity"] is [String: Any], let backup = value["fullCleanupBackup"] as? String, backup.hasPrefix("/"),
              maintenanceBoolean(value["backupVerified"], equals: true), maintenanceBoolean(value["restoreRehearsal"], equals: true),
              let targets = value["targets"] as? [[String: Any]], targets.allSatisfy(maintenanceTarget),
              value["summary"] is [String: Any] else { return false }
        if let requests = value["requests"] as? [Any], value["providerLedgerSHA256"] != nil {
            return validSHA(value["providerLedgerSHA256"])
                && ["status", "authorization", "baselineInstallationBackup", "retainedBoundary", "GUI"].allSatisfy { value[$0] is String }
                && ["baselineFileCount", "baselineLedgerRecordCount"].allSatisfy { maintenanceInteger(value[$0]) }
                && value["callerEvidenceReadOnly"] is [Any]
                && requests.allSatisfy { raw in
                    guard let request = raw as? [String: Any] else { return false }
                    return maintenanceUUID(request["requestID"]) && request["action"] is String && request["providerRecord"] is [String: Any]
                }
                && targets.allSatisfy { target in
                    guard let identity = target["identity"] as? [Any], identity.count == 3 else { return false }
                    return identity.allSatisfy { maintenanceInteger($0) }
                }
        }
        return value["mode"] is String && maintenanceUUID(value["requestID"])
            && maintenanceBoolean(value["executionAuthorizedByThisPreparation"], equals: false)
            && ["beforeLedgerSHA256", "plannedAfterLedgerSHA256", "backupVerificationSHA256"].allSatisfy { validSHA(value[$0]) }
            && maintenanceLedger(value["plannedAfterLedger"]) && maintenanceInventory(value["expectedAfterInventory"])
            && maintenanceDirectories(value["expectedAfterDirectories"]) && maintenanceTool(value["tool"])
            && value["transactionStrategy"] is [String] && value["recoveryStrategy"] is [String: Any]
            && targets.allSatisfy { target in
                guard let identity = target["identity"] as? [String: Any], Set(identity.keys) == Set(["device", "inode", "uid", "mode"]) else { return false }
                return identity.values.allSatisfy { maintenanceInteger($0) }
            }
    }
    private static func maintenanceInventory(_ value: Any?) -> Bool {
        guard let inventory = value as? [String: Any] else { return false }
        return inventory.allSatisfy { path, raw in
            guard safeRelative(path), let entry = raw as? [String: Any] else { return false }
            return maintenanceInteger(entry["bytes"]) && validSHA(entry["sha256"])
        }
    }
    private static func maintenanceDirectories(_ value: Any?) -> Bool {
        guard let directories = value as? [String] else { return false }
        return directories.allSatisfy(safeRelative)
    }
    private static func maintenanceLedger(_ value: Any?) -> Bool {
        guard let ledger = value as? [String: Any] else { return false }
        return maintenanceInteger(ledger["schemaVersion"], equals: 1) && ledger["records"] is [Any]
    }
    private static func maintenanceTarget(_ value: [String: Any]) -> Bool {
        guard value["path"] is String, let relative = value["relativePath"] as? String, safeRelative(relative), relative.hasPrefix("Exchange/"),
              ["Outgoing", "Staging", "Derived"].contains(value["area"] as? String ?? "") else { return false }
        return maintenanceInventory(value["files"]) && maintenanceDirectories(value["directories"])
    }
    private static func maintenanceTool(_ value: Any?) -> Bool {
        guard let tool = value as? [String: Any] else { return false }
        return tool["path"] is String && validSHA(tool["sha256"])
    }
    private static func maintenanceInteger(_ value: Any?, equals expected: Int? = nil) -> Bool {
        guard let number = value as? NSNumber, !boolean(number),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
              !number.stringValue.isEmpty, number.stringValue.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return expected == nil || number.stringValue == String(expected!)
    }
    private static func maintenanceBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        boolean(value) && value as? Bool == expected
    }
    private static func maintenanceUUID(_ value: Any?) -> Bool {
        guard let text = value as? String, let id = UUID(uuidString: text) else { return false }
        return id.uuidString.caseInsensitiveCompare(text) == .orderedSame
    }
    private static func maintenanceDate(_ value: Any?) -> Bool {
        if validDate(value) { return true }
        guard let text = value as? String else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) != nil
    }
    /// A deliberately selected external recording journal includes its referenced media, without scanning unrelated user files.
    static func recordingMediaReferencedByJournal(_ journal: URL) throws -> URL {
        let value = try object(journal, maximum: 1_048_576)
        guard let name = value["partialFileName"] as? String, safeName(name) else { throw fail("外部录制恢复日志含越界路径。") }
        let media = journal.deletingLastPathComponent().appendingPathComponent(name)
        let physical = try ScreenshotMigrationIO.snapshot(id: "RecordingMedia", url: media, required: true)
        guard !physical.isDirectory, let entry = physical.inventory["@file"] else { throw fail("外部录制恢复媒体缺失或不是普通文件。") }
        try recordingRecovery(value, file: journal.lastPathComponent, files: [name: entry])
        return media
    }
    private static func package(root: URL, base: String, files: [String: ScreenshotMigrationEntry], staged: Bool) throws {
        let manifest = try schemaObject(root.appendingPathComponent(base + "/manifest.json"), maximum: 1_048_576)
        guard ["request", "result"].contains(manifest["kind"] as? String ?? ""), validUUID(manifest["requestID"] as? String ?? ""),
              knownActions.contains(manifest["action"] as? String ?? ""), validBundleID(manifest["sourceBundleID"]), validBundleID(manifest["targetBundleID"]),
              let items = manifest["items"] as? [[String: Any]], items.count <= 256 else { throw fail("旧交接包身份、版本或附件清单损坏。") }
        var paths = Set<String>(), physical = Set<String>(); var total: Int64 = 0
        for (index, item) in items.enumerated() {
            guard let relative = item["relativePath"] as? String, safeRelative(relative), paths.insert(relative).inserted,
                  integer(item["byteCount"], 0, 2_147_483_648) else { throw fail("旧交接附件路径或大小无效。") }
            var target = staged ? base + "/" + String(index) + "-" + safeFilename(URL(fileURLWithPath: relative).lastPathComponent) : base + "/payload/" + relative
            if !staged, relative.hasPrefix("payload/") {
                let legacy = base + "/" + relative
                let candidates = [target, legacy].filter { files[$0] != nil }
                guard candidates.count <= 1 else { throw fail("旧交接附件路径解释有歧义。") }
                if let actual = candidates.first { target = actual }
            }
            guard physical.insert(target).inserted else { throw fail("多条交接附件指向同一实物。") }
            try attachment(files, path: target, sha: item["sha256"])
            guard files[target]?.bytes == (item["byteCount"] as! NSNumber).int64Value else { throw fail("旧交接附件大小与主记录不符。") }
            total += files[target]!.bytes
        }
        guard total <= 2_147_483_648 else { throw fail("旧交接附件总量超过协议预算。") }
        if manifest["kind"] as? String == "result" { guard validUUID(manifest["inReplyTo"] as? String ?? ""), ["pending", "completed", "partial", "cancelled", "failed", "unsupported"].contains(manifest["status"] as? String ?? "") else { throw fail("交接结果关联或状态损坏。") } }
    }
    private static func ocrRecovery(_ value: [String: Any]) throws {
        guard integer(value["schemaVersion"], 1, 1), validUUID(value["requestID"] as? String ?? ""), validDate(value["createdAt"]),
              let document = value["document"] as? [String: Any], integer(document["schemaVersion"], 1, 1),
              validUUID(document["id"] as? String ?? ""), let sources = value["sources"] as? [[String: Any]],
              let originals = document["sources"] as? [[String: Any]], sources.count == originals.count,
              let pages = document["pages"] as? [[String: Any]], pages.count <= 100_000 else { throw fail("OCR恢复记录或文档损坏/版本过新。") }
        var ids = Set<String>(), items = Set<String>()
        for source in sources {
            guard let id = source["sourceID"] as? String, validUUID(id), ids.insert(id).inserted,
                  let item = source["sourceItemID"] as? String, !item.isEmpty, items.insert(item).inserted, validSHA(source["sourceSHA256"]),
                  let original = originals.first(where: { $0["id"] as? String == id }),
                  original["sha256"] as? String == "" || original["sha256"] as? String == source["sourceSHA256"] as? String else { throw fail("OCR恢复原件关联、摘要或身份损坏。") }
        }
        for page in pages { guard ids.contains(page["sourceID"] as? String ?? ""), ["completed", "failed", "cancelled"].contains(page["status"] as? String ?? ""), page["lines"] is [[String: Any]] else { throw fail("OCR恢复页面关联损坏。") } }
    }
    private static func recordingRecovery(_ value: [String: Any], file: String, files: [String: ScreenshotMigrationEntry]) throws {
        guard integer(value["schemaVersion"], 1, 1), let name = value["partialFileName"] as? String, safeName(name),
              let requested = value["requestedFileName"] as? String, safeName(requested),
              validUUID(value["sessionID"] as? String ?? ""), validDate(value["createdAt"]), validDate(value["updatedAt"]),
              value["metrics"] is [String: Any], boolean(value["systemAudio"]), boolean(value["microphone"]) else { throw fail("录制恢复日志版本、身份或文件名损坏。") }
        let prefix = (file as NSString).deletingLastPathComponent
        let path = prefix.isEmpty ? name : prefix + "/" + name
        try attachment(files, path: path, sha: nil, requireHash: false)
    }
    private static func schemaObject(_ url: URL, maximum: Int64 = 67_108_864) throws -> [String: Any] { let o = try object(url, maximum: maximum); guard integer(o["schemaVersion"], 1, 1) else { throw fail("主记录缺少受支持schemaVersion：" + url.lastPathComponent) }; return o }
    private static func attachment(_ files: [String: ScreenshotMigrationEntry], path: String, sha: Any?, requireHash: Bool = true) throws {
        guard safeRelative(path), let file = files[path], file.kind == "file" else { throw fail("主记录引用的附件缺失、不可读或不是普通文件：" + path) }
        if let sha { guard validSHA(sha), file.sha256 == sha as? String else { throw fail("附件摘要与主记录不符：" + path) } }
        else if requireHash { throw fail("主记录缺少附件摘要。") }
    }
    static func safeRelative(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } }
    private static func safeName(_ path: String) -> Bool { safeRelative(path) && !path.contains("/") && path.utf8.count <= 255 }
    private static func safeFilename(_ value: String) -> String { var text = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }.map(String.init).joined(); while text.utf8.count > 220 { text.removeLast() }; return ["", ".", ".."].contains(text) ? "交接文档" : text }
    private static func boolean(_ value: Any?) -> Bool { guard let n = value as? NSNumber else { return false }; return CFGetTypeID(n) == CFBooleanGetTypeID() }
    private static func number(_ value: Any?, _ min: Double, _ max: Double) -> Bool { guard let n = value as? NSNumber, !boolean(value) else { return false }; return n.doubleValue.isFinite && (min...max).contains(n.doubleValue) }
    private static func integer(_ value: Any?, _ min: Int64, _ max: Int64) -> Bool { guard number(value, Double(min), Double(max)), let n = value as? NSNumber else { return false }; return n.doubleValue.rounded(.towardZero) == n.doubleValue }
    private static func validUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    private static func validSHA(_ value: Any?) -> Bool { guard let s = value as? String else { return false }; return s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validDate(_ value: Any?) -> Bool { guard let s = value as? String else { return false }; return ISO8601DateFormatter().date(from: s) != nil }
    private static func validBundleID(_ value: Any?) -> Bool { guard let s = value as? String, s.contains("."), s.utf8.count <= 255 else { return false }; return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }
    private static func fail(_ message: String) -> ScreenshotMigrationError { .invalid(message) }
    private static let phases = Set(["received", "approved", "executing", "completed", "partial", "cancelled", "failed", "unsupported"])
    private static let knownActions = Set("capture.region capture.window capture.display ocr.files images.annotate images.pin text.translate storage.inspect cleanup.review apps.uninstall.review files.search files.choose files.reveal associations.manage documents.open documents.newText research.importDocuments portal.openSite portal.openWorkspace portal.focusSearch portal.proposeSite portal.prepareDownload windows.overview desktop.openSettings downloads.prepare".split(separator: " ").map(String.init))
}

/// JSONSerialization accepts duplicate keys. Reject them before any field can hide a conflicting schema or attachment path.
enum ScreenshotMigrationJSONKeys {
    static func validate(_ data: Data) throws { var p = Parser(bytes: Array(data)); try p.value(depth: 0); p.whitespace(); guard p.index == p.bytes.count else { throw ScreenshotMigrationIO.fail("JSON主记录含尾随或损坏内容。") } }
    private struct Parser {
        let bytes: [UInt8]; var index = 0; var nodes = 0
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool { whitespace(); if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false }
        mutating func string() throws -> String {
            whitespace(); let start = index; guard index < bytes.count, bytes[index] == 34 else { throw ScreenshotMigrationIO.fail("JSON键或字符串损坏。") }; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { index += 1; return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard bytes[index] >= 32 else { throw ScreenshotMigrationIO.fail("JSON字符串含控制字符。") }; index += 1
            }
            throw ScreenshotMigrationIO.fail("JSON字符串未结束。")
        }
        mutating func value(depth: Int) throws {
            nodes += 1; guard depth <= 64, nodes <= 2_000_000 else { throw ScreenshotMigrationIO.fail("JSON递归或数量超过预算。") }; whitespace()
            guard index < bytes.count else { throw ScreenshotMigrationIO.fail("JSON主记录不完整。") }
            if consume(123) {
                var keys = Set<String>(); if consume(125) { return }
                repeat { let key = try string(); guard keys.insert(key).inserted, consume(58) else { throw ScreenshotMigrationIO.fail("JSON主记录含重复键或缺少分隔符。") }; try value(depth: depth + 1); if consume(125) { return } } while consume(44)
                throw ScreenshotMigrationIO.fail("JSON对象损坏。")
            }
            if consume(91) { if consume(93) { return }; repeat { try value(depth: depth + 1); if consume(93) { return } } while consume(44); throw ScreenshotMigrationIO.fail("JSON列表损坏。") }
            if bytes[index] == 34 { _ = try string(); return }
            let start = index; while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ScreenshotMigrationIO.fail("JSON标量损坏。") }
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
        }
    }
}
