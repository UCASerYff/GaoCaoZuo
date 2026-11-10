#if LEGACY_DESKTOP_RETIREMENT_CLI
import Foundation
import Darwin

/// A command-line adapter for the same importer/validator used by the app.
/// This entry point never constructs OperationStore or NSApplication.
@main enum LegacyDesktopMigrationRetirementCLI {
    @MainActor static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch let committed as LegacyDesktopSourceRetirementCommittedError {
            // A nonzero exit can still mean the journal was sealed. Preserve
            // that distinction for the coordinator; do not suggest rollback or
            // permission to delete the remaining transaction artifacts.
            let status: [String: Any] = [
                "journalSealed": committed.journalSealed, "cleanupComplete": committed.cleanupComplete,
                "journalCommitUncertain": committed.journalCommitUncertain,
                "actualJournalRawSHA256": committed.actualJournalRawSHA256.map { $0 as Any } ?? NSNull(),
                "actualSettingsRawSHA256": committed.actualSettingsRawSHA256.map { $0 as Any } ?? NSNull(),
                "requiresRootReview": committed.requiresRootReview,
                "currentSettingsSHA": committed.actualSettingsRawSHA256.map { $0 as Any } ?? NSNull(),
                "currentSettingsHashKind": "raw-settings-file-sha256", "needsReview": committed.requiresRootReview,
                "journalRawSHA256": committed.journalRawSHA256, "approvedPlanDigest": committed.approvedPlanDigest,
                "underlyingMessage": committed.underlyingMessage
            ]
            writeStatus(status, to: .standardError)
            exit(3)
        }
        catch {
            FileHandle.standardError.write(Data(("桌面迁移封存已停止：" + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    @MainActor private static func run(_ arguments: [String]) throws {
        var args = arguments
        guard !args.isEmpty else { throw fail(usage) }
        let action = args.removeFirst()
        var options: [String: String] = [:]
        while !args.isEmpty {
            let key = args.removeFirst()
            guard key.hasPrefix("--"), !args.isEmpty, options[key] == nil else { throw fail("参数缺值、重复或无效。" + usage) }
            options[key] = args.removeFirst()
        }
        switch action {
        case "preview":
            guard Set(options.keys) == Set(["--target-root", "--plan"]),
                  let root = options["--target-root"], let output = options["--plan"] else { throw fail(usage) }
            let target = try localURL(root)
            let outputURL = try localURL(output)
            try requirePrivatePlanContainer(outputURL.deletingLastPathComponent())
            let data = LocalData(directory: target, createIfMissing: false)
            let settings = try readSettings(data)
            let plan = try LegacyDesktopMigrationImporter(targetData: data).retirementPreview(currentSettings: settings)
            // The typed plan contains only identities and hashes. No source
            // evidence or old journal bytes are written to the review file.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let outputData = LocalData(directory: outputURL.deletingLastPathComponent(), createIfMissing: false)
            try outputData.createFile(try encoder.encode(plan), name: outputURL.lastPathComponent)
            print("plan=" + outputURL.path)
            print("retirementApprovalDigest=" + plan.approvalDigest)
            print("migrationRecords=\(plan.migrationIDs.count); preview only; journal and settings unchanged")
        case "finalize":
            guard Set(options.keys) == Set(["--plan", "--approved-digest"]),
                  let path = options["--plan"], let approved = options["--approved-digest"] else { throw fail(usage) }
            let planURL = try localURL(path)
            try requirePrivatePlanContainer(planURL.deletingLastPathComponent())
            let reader = LocalData(directory: planURL.deletingLastPathComponent(), createIfMissing: false)
            let raw = try reader.verifiedData(planURL.lastPathComponent, maximumSize: 1_048_576)
            let plan = try LegacyDesktopSourceRetirementPlan.decode(raw)
            let target = try localURL(plan.targetDirectoryPath)
            let data = LocalData(directory: target, createIfMissing: false)
            let settings = try readSettings(data)
            let result = try LegacyDesktopMigrationImporter(targetData: data).finalizeSourceRetirement(
                plan: plan, currentSettings: settings, approvedPlanDigest: approved)
            let status: [String: Any] = [
                "journalSealed": true, "cleanupComplete": true, "needsReview": false,
                "journalCommitUncertain": false, "actualJournalRawSHA256": result.journalRawSHA256,
                "actualSettingsRawSHA256": plan.settingsRawSHA256, "requiresRootReview": false,
                "currentSettingsSHA": plan.settingsRawSHA256,
                "currentSettingsHashKind": "raw-settings-file-sha256", "alreadyFinalized": result.alreadyFinalized,
                "journalRawSHA256": result.journalRawSHA256, "approvedPlanDigest": result.approvedPlanDigest
            ]
            writeStatus(status, to: .standardOutput)
        default: throw fail(usage)
        }
    }

    private static let usage = "用法：preview --target-root ABSOLUTE_PATH --plan NEW_ABSOLUTE_PATH；finalize --plan ABSOLUTE_PATH --approved-digest SHA256。计划须在现有私有 .noindex 容器中；执行前由总协调停止资料写入者。本工具不启动应用、不删除来源、不写 settings.json。"
    private static func fail(_ message: String) -> LegacyDesktopMigrationError { .invalid(message) }
    private static func writeStatus(_ object: [String: Any], to handle: FileHandle) {
        do {
            var raw = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            raw.append(10); handle.write(raw)
        } catch { handle.write(Data("{\"journalSealed\":null,\"journalCommitUncertain\":true,\"cleanupComplete\":null,\"needsReview\":true,\"requiresRootReview\":true,\"error\":\"status encoding failed\"}\n".utf8)) }
    }
    private static func localURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains("."), path != "/" else { throw fail("必须提供规范绝对本地路径。") }
        return URL(fileURLWithPath: path)
    }
    private static func readSettings(_ data: LocalData) throws -> OperationSettings {
        guard data.failure == nil, let settings = try data.load("settings.json", as: OperationSettings.self) else {
            throw fail("目标设置缺失或不可读；不会建立空资料。")
        }
        return settings
    }
    private static func requirePrivatePlanContainer(_ parent: URL) throws {
        var info = stat()
        guard parent.pathComponents.contains(where: { $0.hasSuffix(".noindex") }),
              lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw fail("计划必须使用现有、本人所有、权限为私有的 .noindex 容器及未占用的新文件名。")
        }
    }
}
#endif
