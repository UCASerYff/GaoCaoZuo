import Foundation
import CoreFoundation

/// A deliberate selection of an original manifest in the already inventoried backup snapshot.
/// The actual backup identity/path is retained; it never masquerades as a current Source file.
struct ScreenshotHistoricalManifestBinding: Codable, Equatable, Sendable {
    var requestID: String
    var manifestSHA256: String
    var snapshotID: String
    var manifestRelativePath: String
}

struct ScreenshotLegacyHistoryDisposition: Codable, Equatable, Sendable {
    var requestID: String
    var ledgerRowSHA256: String
    var originalPhase: String
    var disposition: String
}

/// Target-side evidence, rebuilt from the preserved policy and original ledger on every access.
struct ScreenshotLegacyHistoryPolicyBinding: Codable, Equatable, Sendable {
    var sourceID: String
    var sourceSHA256: String
    var policySHA256: String
    var ledgerSHA256: String
    var dispositions: [ScreenshotLegacyHistoryDisposition]
}

enum ScreenshotMigrationHistoryPolicy {
    static let snapshotID = "LegacyHistoryPolicy"
    static let projectedPath = "Records/LegacyHistoryPolicy.json"
    static let incomplete = "approved-incomplete-history"
    static let noContinuation = "approved-no-continuation"
    private static let fail = ScreenshotMigrationActivity.fail
    private static let validSHA = ScreenshotMigrationActivity.validSHA
    private static let terminal = Set(["completed", "partial", "cancelled", "failed", "unsupported"])

    struct ApprovedRecord {
        var requestID: String
        var manifestSHA256: String
        var phase: String
        var action: String
        var sourceBundleID: String
        var originalManifestPath: String?
        func matches(_ row: [String: Any]) -> Bool {
            UUID(uuidString: row["requestID"] as? String ?? "")?.uuidString == requestID &&
            row["manifestSHA256"] as? String == manifestSHA256 && row["phase"] as? String == phase &&
            row["action"] as? String == action && row["sourceBundleID"] as? String == sourceBundleID &&
            row["kind"] as? String == "request" && row["resultPackageName"] == nil
        }
    }
    struct Receipt {
        var missing: [String: ApprovedRecord]
        var received: ApprovedRecord
    }

    static func validateRawPolicy(at url: URL, expectedSHA256: String) throws {
        _ = try read(at: url, expectedSHA256: expectedSHA256)
    }

    static func validateHistoricalManifestBindings(_ bindings: [ScreenshotHistoricalManifestBinding], snapshots: [ScreenshotMigrationSnapshot]) throws {
        guard bindings.count == 7, Set(bindings.map { UUID(uuidString: $0.requestID)?.uuidString ?? "" }).count == 7,
              let backups = snapshots.first(where: { $0.id == "Backups" }), backups.existed, backups.isDirectory else {
            throw fail("历史原manifest必须明确选择七条不同请求，且来自已盘点的Backups目录。")
        }
        var paths = Set<String>()
        for binding in bindings {
            let path = binding.manifestRelativePath, parts = path.split(separator: "/").map(String.init)
            guard UUID(uuidString: binding.requestID) != nil, validSHA(binding.manifestSHA256), binding.snapshotID == "Backups",
                  ScreenshotMigrationValidation.safeRelative(path), parts.count >= 5,
                  Array(parts.suffix(5).prefix(3)) == ["Data", "Exchange", "Staging"],
                  UUID(uuidString: parts[parts.count - 2]) != nil, parts.last == "manifest.json",
                  paths.insert(path).inserted,
                  let file = backups.inventory[path], file.kind == "file", file.linkTarget == nil, file.sha256 == binding.manifestSHA256 else {
                throw fail("历史原manifest选择的请求、备份路径、现物或摘要不一致。")
            }
        }
    }

    static func load(root: URL, files: [String: ScreenshotMigratedActivityFile], expectedSHA256: String?) throws -> Receipt? {
        let selected = files.filter { $0.value.snapshotID == snapshotID }
        guard let expectedSHA256 else {
            guard selected.isEmpty else { throw fail("历史处置凭据未获得明确的原字节摘要授权。") }
            return nil
        }
        guard selected.count == 1, let file = files[projectedPath], file.snapshotID == snapshotID,
              file.originalRelativePath == "@file", file.sha256 == expectedSHA256 else {
            throw fail("历史处置凭据的只读投影、原件或摘要绑定不符。")
        }
        return try read(at: root.appendingPathComponent(projectedPath), expectedSHA256: expectedSHA256)
    }

    static func rowSHA256(_ row: [String: Any]) throws -> String {
        ScreenshotMigrationIO.sha(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func read(at url: URL, expectedSHA256: String) throws -> Receipt {
        let bytes = try ScreenshotMigrationIO.read(url, maximum: 1_048_576)
        guard validSHA(expectedSHA256), ScreenshotMigrationIO.sha(bytes) == expectedSHA256 else { throw fail("历史处置原始凭据摘要与本次明确选择不符。") }
        try ScreenshotMigrationJSONKeys.validate(bytes)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw fail("历史处置原始凭据必须是JSON对象。") }
        let keys: Set<String> = ["schemaVersion", "atUTC", "humanDecision", "questionScope", "rootOwner", "evidence", "exactMissingTerminalRecords", "exactReceivedRecords", "noSourceStateChangeAuthorized", "notOriginalRequestCompletionOrCancellation", "notBlankSubstitution", "newLiveExecutionAuthorityGranted", "retirementOnlyAfterAllOtherGates"]
        guard Set(value.keys) == keys, let schema = value["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              value["humanDecision"] as? String == "允许按此方案迁入并继续退役",
              text(value["atUTC"]), text(value["questionScope"]), text(value["rootOwner"]),
              flag(value["noSourceStateChangeAuthorized"], true), flag(value["notOriginalRequestCompletionOrCancellation"], true),
              flag(value["notBlankSubstitution"], true), flag(value["newLiveExecutionAuthorityGranted"], false), flag(value["retirementOnlyAfterAllOtherGates"], true),
              let evidence = value["evidence"] as? [String: Any], Set(evidence.keys) == ["path", "sha256"],
              absolute(evidence["path"]), validSHA(evidence["sha256"] as? String ?? ""),
              let missing = value["exactMissingTerminalRecords"] as? [[String: Any]], missing.count == 8,
              let received = value["exactReceivedRecords"] as? [[String: Any]], received.count == 1 else {
            throw fail("历史处置凭据范围、明确授权标志或八加一条目格式无效。")
        }
        var approved: [String: ApprovedRecord] = [:]
        for row in missing {
            guard Set(row.keys) == ["action", "classification", "ledgerManifestSHA256", "phase", "requestID", "requiredUnresolved", "sourceBundleID"],
                  row["classification"] as? String == "current_terminal_record_original_manifest_not_found_in_known_backup_inventory",
                  text(row["requiredUnresolved"]), let phase = row["phase"] as? String, terminal.contains(phase) else { throw fail("历史不完整条目不是获准保留的原始终态缺失。") }
            let item = try record(row, hashKey: "ledgerManifestSHA256", originalPath: nil)
            guard approved.updateValue(item, forKey: item.requestID) == nil else { throw fail("历史处置凭据含重复请求。") }
        }
        let row = received[0]
        guard Set(row.keys) == ["action", "kind", "manifestSHA256", "originalManifests", "phase", "requestID", "sourceBundleID"],
              row["kind"] as? String == "request", row["phase"] as? String == "received", row["action"] as? String == "text.translate",
              let originals = row["originalManifests"] as? [[String: Any]], originals.count == 1,
              Set(originals[0].keys) == ["fileSHA256", "manifestSHAMatchesLedger", "path"],
              originals[0]["fileSHA256"] as? String == row["manifestSHA256"] as? String,
              flag(originals[0]["manifestSHAMatchesLedger"], true), absolute(originals[0]["path"]) else {
            throw fail("不再接续条目必须是唯一received翻译请求及其真实原manifest。")
        }
        let item = try record(row, hashKey: "manifestSHA256", originalPath: originals[0]["path"] as? String)
        guard approved[item.requestID] == nil else { throw fail("历史不完整与不再接续范围重叠。") }
        return Receipt(missing: approved, received: item)
    }

    private static func record(_ row: [String: Any], hashKey: String, originalPath: String?) throws -> ApprovedRecord {
        guard let id = UUID(uuidString: row["requestID"] as? String ?? ""), validSHA(row[hashKey] as? String ?? ""),
              let phase = row["phase"] as? String, let action = row["action"] as? String,
              ["text.translate", "images.pin", "images.annotate"].contains(action),
              let source = row["sourceBundleID"] as? String, !source.isEmpty, source.utf8.count <= 255 else { throw fail("历史处置条目的身份、动作或原摘要无效。") }
        return .init(requestID: id.uuidString, manifestSHA256: row[hashKey] as! String, phase: phase, action: action, sourceBundleID: source, originalManifestPath: originalPath)
    }
    private static func text(_ value: Any?) -> Bool { guard let value = value as? String else { return false }; return !value.isEmpty && !value.contains("\0") }
    private static func absolute(_ value: Any?) -> Bool { guard let value = value as? String else { return false }; return value.hasPrefix("/") && text(value) && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) }
    private static func flag(_ value: Any?, _ expected: Bool) -> Bool { guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }; return value.boolValue == expected }
}
