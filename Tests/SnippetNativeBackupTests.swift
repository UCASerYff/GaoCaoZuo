import AppKit
import Foundation

@MainActor func runSnippetNativeBackupTests() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-no-snippet-backup-" + UUID().uuidString + ".noindex")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("source"))
    let snippet = AdvancedSnippet(name: "现用短语", text: "current content")
    try source.upsert(snippet)
    let before = try Data(contentsOf: source.directory.appendingPathComponent("library.json"))
    let package = root.appendingPathComponent("removed.gaosnippets")
    var refused = false
    do { try await source.exportNativeBackup(to: package) } catch { refused = true }
    guard refused, !fm.fileExists(atPath: package.path),
          try Data(contentsOf: source.directory.appendingPathComponent("library.json")) == before,
          source.snippets == [snippet] else { throw DataFailure.message("Disabled snippet backup changed current data or created output") }
    refused = false
    do { try SnippetNativeBackupIO.write(files: [:], to: package) } catch { refused = true }
    guard refused, !fm.fileExists(atPath: package.path) else { throw DataFailure.message("Disabled native writer created a backup") }
    print("短语备份移除专项通过：旧导出调用和底层写入拒绝，未创建输出，现用短语不变。")
}

func runScreenshotBackupRemovalTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-no-screenshot-backup-" + UUID().uuidString + ".noindex")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let current = root.appendingPathComponent("Current.bin")
    let bytes = Data("current screenshot attachment".utf8)
    try bytes.write(to: current, options: .withoutOverwriting)
    let destination = root.appendingPathComponent("RemovedBackup.noindex")
    var refused = false
    do { _ = try ScreenshotDataBackup.create(root: root, destination: destination) } catch { refused = true }
    guard refused, !fm.fileExists(atPath: destination.path), try Data(contentsOf: current) == bytes,
          try fm.contentsOfDirectory(atPath: root.path) == ["Current.bin"] else {
        throw DataFailure.message("Disabled screenshot backup created output or changed current attachment")
    }
    let legacy = root.appendingPathComponent("SyntheticSource")
    try fm.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sourceSettings = legacy.appendingPathComponent("Settings.json")
    let settingsBytes = try JSONEncoder().encode(ScreenshotAppSettings())
    try settingsBytes.write(to: sourceSettings, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceSettings.path)
    let configuration = ScreenshotMigrationConfiguration(sourceRoot: legacy, targetRoot: root.appendingPathComponent("UncreatedTarget"),
        archiveRoot: root.appendingPathComponent("UncreatedMigrationArchive.noindex"), auxiliaries: [])
    let migrator = ScreenshotMigration(configuration: configuration)
    let plan = try migrator.preview()
    guard plan.conflicts.isEmpty else {throw DataFailure.message("Synthetic source preview unexpectedly conflicts")}
    refused = false
    do { _ = try migrator.apply(plan, approvedDigest: plan.approvalDigest) }
    catch { refused = error.localizedDescription.contains("新迁移备份功能已移除") }
    guard refused, !fm.fileExists(atPath: configuration.archiveRoot.path), !fm.fileExists(atPath: configuration.targetRoot.path),
          try Data(contentsOf: sourceSettings) == settingsBytes else {
        throw DataFailure.message("New migration was not refused, created an archive, or changed source data")
    }
    print("截图备份移除专项通过：导出与新迁移均拒绝，无归档/演练副本，现用附件与旧来源不变。")

}

@MainActor func runScreenshotHistoryNoBackupTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-history-no-backup-" + UUID().uuidString + ".noindex")
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("Current")
    let configuration = ScreenshotMigrationConfiguration(sourceRoot: root.appendingPathComponent("AbsentSource"), targetRoot: target,
        archiveRoot: root.appendingPathComponent("UnusedArchive.noindex"), auxiliaries: [])
    let store = ScreenshotLocalStore(root: target, backupRoot: root.appendingPathComponent("UnusedBackups.noindex"), migrationConfiguration: configuration)
    try store.initializeFresh()
    store.settings.historyEnabled = true
    try store.saveSettings()
    let history = target.appendingPathComponent("History")
    try fm.createDirectory(at: history, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let expiredBytes = Data("synthetic expired history".utf8), currentBytes = Data("synthetic current history".utf8)
    let expiredURL = history.appendingPathComponent("expired.png"), currentURL = history.appendingPathComponent("current.png")
    try expiredBytes.write(to: expiredURL, options: .withoutOverwriting)
    try currentBytes.write(to: currentURL, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expiredURL.path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL.path)
    var expired = ScreenshotCaptureAsset(source: "Synthetic", pixelWidth: 1, pixelHeight: 1, colorSpace: "Synthetic", scale: 1,
        outputPath: "History/expired.png", sha256: ScreenshotFileSafety.digest(expiredBytes))
    expired.createdAt = Date().addingTimeInterval(-30*86400)
    let current = ScreenshotCaptureAsset(source: "Synthetic", pixelWidth: 1, pixelHeight: 1, colorSpace: "Synthetic", scale: 1,
        outputPath: "History/current.png", sha256: ScreenshotFileSafety.digest(currentBytes))
    let indexURL = target.appendingPathComponent("History.json")
    try JSONEncoder().encode(ScreenshotHistoryEnvelope(assets: [expired, current])).write(to: indexURL, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    store.reloadAfterMigration()
    guard store.writable else {throw DataFailure.message("Synthetic history did not load")}
    try store.pruneExpiredHistory()
    guard !fm.fileExists(atPath: expiredURL.path), try Data(contentsOf: currentURL) == currentBytes,
          store.assets.map(\.id) == [current.id], !fm.fileExists(atPath: target.appendingPathComponent("DeletedHistory").path) else {
        throw DataFailure.message("Expiry created a backup or removed current history")
    }
    store.reloadAfterMigration()
    guard store.writable, store.assets.count == 1 else {throw DataFailure.message("Expiry did not persist the remaining history index")}
    // An externally modified index must stop deletion before any current bytes are removed.
    let validIndex = try Data(contentsOf: indexURL)
    try Data("changed external index".utf8).write(to: indexURL)
    var refused = false
    do {try store.deleteHistory()} catch {refused = true}
    guard refused, try Data(contentsOf: currentURL) == currentBytes else {throw DataFailure.message("Stale history index did not protect current attachment")}
    try validIndex.write(to: indexURL)
    store.reloadAfterMigration()
    try store.deleteHistory()
    store.reloadAfterMigration()
    guard store.writable, store.assets.isEmpty, !fm.fileExists(atPath: currentURL.path),
          !fm.fileExists(atPath: target.appendingPathComponent("DeletedHistory").path) else {
        throw DataFailure.message("Explicit deletion created a backup or left a stale index")
    }
    print("截图历史专项通过：到期只清理过期条目，当前附件保留；索引冲突拒绝删除，明确删除不生成恢复副本。")
}
