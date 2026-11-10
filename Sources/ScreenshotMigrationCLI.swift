#if SCREENSHOT_MIGRATION_CLI
import Foundation
import Darwin

/// Thin adapter only: all preview/apply/recover/fresh logic lives in ScreenshotMigration, used by the app as well.
@main enum ScreenshotMigrationCLI {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data(("截图迁移已停止；来源、目标和归档均保留：" + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    private static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
            guard !args.isEmpty else { throw ScreenshotMigrationIO.fail("用法：preview --target-root PATH --archive-root PATH --plan PATH [--source-root PATH --backups-root PATH --preferences PATH --aux ID=PATH --historical-manifest-bindings JSON_PATH --legacy-history-policy PATH --legacy-history-policy-sha256 SHA]；apply --plan PATH --approved-digest SHA；recover/import-activity --plan PATH；retirement-preview --plan PATH --retirement-plan NEW_PATH；finalize-source-retirement --retirement-plan PATH --approved-digest SHA --verification-evidence PATH；fresh --target-root PATH --archive-root PATH。") }
        let action = args.removeFirst(); var options: [String: String] = [:]; var auxiliary: [ScreenshotMigrationConfiguration.Auxiliary] = []
        while !args.isEmpty {
            let name = args.removeFirst(); guard name.hasPrefix("--"), !args.isEmpty else { throw ScreenshotMigrationIO.fail("参数缺少值。") }; let value = args.removeFirst()
            if name == "--aux" {
                guard let split = value.firstIndex(of: "="), value[..<split] != "LegacyHistoryPolicy" else { throw ScreenshotMigrationIO.fail("--aux需要ID=绝对路径；LegacyHistoryPolicy须由专用策略参数显式选择。") }
                auxiliary.append(.init(id: String(value[..<split]), url: try url(String(value[value.index(after: split)...])), required: true))
            }
            else { guard options[name] == nil else { throw ScreenshotMigrationIO.fail("参数重复：" + name) }; options[name] = value }
        }
        let historyOptions = Set(["--historical-manifest-bindings", "--legacy-history-policy", "--legacy-history-policy-sha256"])
        let allowed = Set(["--target-root", "--archive-root", "--plan", "--source-root", "--backups-root", "--preferences", "--approved-digest", "--retirement-plan", "--verification-evidence"]).union(historyOptions)
        guard Set(options.keys).isSubset(of: allowed) else { throw ScreenshotMigrationIO.fail("存在未知参数。") }
        guard action == "preview" || Set(options.keys).isDisjoint(with: historyOptions) else { throw ScreenshotMigrationIO.fail("历史清单与人工策略只能在preview时选择，后续步骤必须使用已确认的原plan。") }
        if action == "finalize-source-retirement" {
            guard auxiliary.isEmpty, Set(options.keys) == Set(["--retirement-plan", "--approved-digest", "--verification-evidence"]),
                  let path = options["--retirement-plan"], let digest = options["--approved-digest"], let evidence = options["--verification-evidence"] else {
                throw ScreenshotMigrationIO.fail("finalize-source-retirement需要保存的retirement-plan、确认摘要及真实验收凭据；不会删除任何文件。")
            }
            let plan = try ScreenshotMigrationIO.decode(ScreenshotSourceRetirementPlan.self, from: url(path))
            let receipt = try ScreenshotMigration(configuration: plan.configuration).finalizeSourceRetirement(plan, approvedDigest: digest, verificationEvidence: url(evidence))
            FileHandle.standardOutput.write(try ScreenshotMigrationIO.encoder.encode(receipt)); print(); return
        }
        if action == "import-activity" || action == "retirement-preview" {
            let keys: Set<String> = action == "import-activity" ? ["--plan"] : ["--plan", "--retirement-plan"]
            guard auxiliary.isEmpty, Set(options.keys) == keys, let path = options["--plan"] else { throw ScreenshotMigrationIO.fail("活动补迁/退役预览需要原迁移plan及指定的新retirement-plan路径。") }
            let plan = try ScreenshotMigrationIO.decode(ScreenshotMigrationPlan.self, from: url(path))
            let migration = ScreenshotMigration(configuration: plan.configuration)
            if action == "import-activity" {
                let index = try migration.importActivity(plan)
                print("migrationID=" + index.migrationID)
                print("importedActivityEntries=\(index.entries.count) retirementBlockers=\(try ScreenshotMigrationActivity.blockers(root: plan.configuration.targetRoot).count)")
            } else {
                let retirement = try migration.retirementPreview(plan)
                let output = try url(options["--retirement-plan"]!)
                guard output.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else { throw ScreenshotMigrationIO.fail("retirement-plan必须位于私有.noindex容器且使用新路径。") }
                try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(retirement), to: output)
                print("retirementPlan=" + output.path)
                print("migrationID=" + retirement.migrationID)
                print("approvalDigest=" + retirement.approvalDigest)
                print("deletionAllowlist=\(retirement.deletionAllowlist.count) coordinatorReviewOnly=\(retirement.coordinatorReviewOnly.count); no files deleted")
            }
            return
        }
        if action == "apply" || action == "recover" {
            guard let path = options["--plan"], auxiliary.isEmpty, options.keys.allSatisfy({ ["--plan", "--approved-digest"].contains($0) }) else { throw ScreenshotMigrationIO.fail("apply/recover仅接受保存的plan及确认摘要。") }
            let plan = try ScreenshotMigrationIO.decode(ScreenshotMigrationPlan.self, from: url(path))
            let migration = ScreenshotMigration(configuration: plan.configuration)
            let result: ScreenshotMigrationResult
            if action == "apply" { guard let approved = options["--approved-digest"] else { throw ScreenshotMigrationIO.fail("apply需要预览时显示的--approved-digest。") }; result = try migration.apply(plan, approvedDigest: approved) }
            else { result = try migration.recover(migrationID: plan.migrationID) }
            FileHandle.standardOutput.write(try ScreenshotMigrationIO.encoder.encode(result)); print(); return
        }
        guard action == "preview" || action == "fresh", let target = options["--target-root"], let archive = options["--archive-root"] else { throw ScreenshotMigrationIO.fail("preview/fresh需要明确target-root和archive-root。") }
        var config = ScreenshotMigrationConfiguration.standard(targetRoot: try url(target), backupRoot: try url(archive).deletingLastPathComponent())
        config.archiveRoot = try url(archive)
        if let source = options["--source-root"] { config.sourceRoot = try url(source) }
        if let backups = options["--backups-root"] { config.auxiliaries.removeAll { $0.id == "Backups" }; config.auxiliaries.append(.init(id: "Backups", url: try url(backups))) }
        if let preferences = options["--preferences"] { config.auxiliaries.removeAll { $0.id == "Preferences" }; config.auxiliaries.append(.init(id: "Preferences", url: try url(preferences))) }
        // Explicit source-root is an isolation boundary. Do not read the current user's real prefs/init/backups in fixture mode.
        if options["--source-root"] != nil {
            let parent = config.sourceRoot.deletingLastPathComponent()
            if options["--backups-root"] == nil { config.auxiliaries.removeAll { $0.id == "Backups" }; config.auxiliaries.append(.init(id: "Backups", url: parent.appendingPathComponent("GaoJieTu-Backups"))) }
            config.auxiliaries.removeAll { $0.id == "Initialization" || $0.id == "Preferences" && options["--preferences"] == nil }
            config.auxiliaries.append(.init(id: "Initialization", url: parent.appendingPathComponent("GaoJieTu-Initialization.json")))
        }
        config.auxiliaries += auxiliary
        if let bindingsPath = options["--historical-manifest-bindings"] {
            let bytes = try ScreenshotMigrationIO.read(url(bindingsPath), maximum: 1_048_576)
            config.historicalManifestBindings = try JSONDecoder().decode([ScreenshotHistoricalManifestBinding].self, from: bytes)
        }
        let policyPath = options["--legacy-history-policy"], policySHA = options["--legacy-history-policy-sha256"]
        guard (policyPath == nil) == (policySHA == nil) else { throw ScreenshotMigrationIO.fail("--legacy-history-policy与--legacy-history-policy-sha256必须成对提供，不能推断人工批准的摘要。") }
        if let policyPath, let policySHA {
            config.legacyHistoryPolicySHA256 = policySHA
            config.auxiliaries.append(.init(id: "LegacyHistoryPolicy", url: try url(policyPath), required: true))
        }
        let migration = ScreenshotMigration(configuration: config)
        if action == "fresh" { try migration.initializeFresh(); print("截图模块已显式初始化；未迁移来源、转授授权或改动钥匙串。"); return }
        guard let output = options["--plan"] else { throw ScreenshotMigrationIO.fail("preview需要新--plan文件路径。") }
        let plan = try migration.preview()
        // Plan files contain local paths. Write privately without overwriting an earlier review.
        let planURL = try url(output)
        guard planURL.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else { throw ScreenshotMigrationIO.fail("plan必须保存在.noindex容器。") }
        try ScreenshotMigrationIO.writeNew(try ScreenshotMigrationIO.encoder.encode(plan), to: planURL)
        print("plan=" + planURL.path)
        print("migrationID=" + plan.migrationID)
        print("approvalDigest=" + plan.approvalDigest)
        print("files=\(plan.fileCount) bytes=\(plan.totalBytes) conflicts=\(plan.conflicts.count)")
    }
    private static func url(_ path: String) throws -> URL { guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw ScreenshotMigrationIO.fail("需要规范绝对路径。") }; return URL(fileURLWithPath: path) }
}
#endif
