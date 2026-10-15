import AppKit
import Foundation

@MainActor func runSnippetNativeBackupTests() async throws {
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; guard try condition() else { throw DataFailure.message("Native snippet backup: " + message) }
    }
    func fails(_ action: () async throws -> Void, _ message: String) async throws {
        var rejected = false; do { try await action() } catch { rejected = true }; try check(rejected, message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-native-snippet-backup-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("source"))
    let rtf = Data("{\\rtf1\\ansi original rich}".utf8), body = Data("owned attachment bytes\n".utf8)
    let attachment = try source.importAttachment(data: body, originalName: "原文件.txt", type: "public.plain-text")
    let richBody = try source.importAttachment(data: rtf, originalName: "正文.rtf", type: "public.rtf")
    let old = AdvancedSnippet(name: "原短语", text: "old content", format: .richText, shortcut: "old", attachments: [attachment], rtfAttachment: richBody)
    try source.upsert(old)
    var newer = old; newer.text = "new content\n{date}"; try source.upsert(newer)
    try source.upsert(.init(name: "另一项", text: "other"))
    let package = root.appendingPathComponent("manual.gaosnippets")
    try await source.exportNativeBackup(to: package)
    let loaded = try SnippetNativeBackupIO.read(at: package)
    try check(loaded.current.snippets.count == 2 && loaded.files.keys.contains(attachment.filename), "current rich data and attachment exported")
    try check(loaded.files.keys.filter { $0.hasPrefix("revision-") }.count >= 3, "all linked recovery revisions exported")
    let manifestBefore = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    try await fails({ try await source.exportNativeBackup(to: package) }, "existing output cannot be overwritten")
    try check(try Data(contentsOf: package.appendingPathComponent("manifest.json")) == manifestBefore, "existing package bytes unchanged")

    let target = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("target"))
    try target.upsert(.init(name: "原短语", text: "target user edit", shortcut: "old"))
    let before = target.snippets, preview = try await target.previewNativeBackup(at: package, policy: .keepBoth)
    try check(target.snippets == before && preview.added == 2, "read-only native restore preview")
    try target.restoreNativeBackup(preview)
    try check(target.snippets.count == 3 && target.snippets.contains(where: { $0.text == "target user edit" }), "keep both retains edited current snippet")
    let restored = target.snippets.first(where: { $0.rtfAttachment != nil })!
    try check(restored.id != old.id || restored.name != old.name, "conflict copy has separate identity or name")
    try check(restored.shortcut == nil, "import does not steal current shortcut")
    try check(try target.verifiedAttachment(restored.rtfAttachment!) == rtf && target.verifiedAttachment(restored.attachments![0]) == body, "native raw RTF and file bytes round trip")
    let restart = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("target"))
    try check(restart.healthy && restart.snippets == target.snippets, "restored native library survives restart")
    let secondPackage = root.appendingPathComponent("restored-again.gaosnippets")
    try await restart.exportNativeBackup(to: secondPackage)
    let secondRead = try SnippetNativeBackupIO.read(at: secondPackage)
    try check((secondRead.current.importedRecoveryRevisions?.count ?? 0) > 0 && secondRead.files.count >= loaded.files.count, "imported recovery history re-exports completely")
    try target.undoLastChange(); try check(target.snippets == before, "native restore can be rolled back")
    try await fails({ try target.restoreNativeBackup(preview) }, "stale native preview rejected")

    let overwriteTarget = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("overwrite"))
    let original = AdvancedSnippet(name: "原短语", text: "must remain in recovery")
    try overwriteTarget.upsert(original)
    let overwrite = try await overwriteTarget.previewNativeBackup(at: package, policy: .overwrite)
    try overwriteTarget.restoreNativeBackup(overwrite)
    try check(overwriteTarget.snippets.first(where: { $0.id == original.id })?.text == newer.text, "explicit overwrite keeps target UUID")
    try overwriteTarget.undoLastChange(); try check(overwriteTarget.snippets == [original], "overwrite old body recoverable")

    let emptyTarget = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("empty"))
    let emptyPreview = try await emptyTarget.previewNativeBackup(at: package, policy: .keepBoth)
    try emptyTarget.restoreNativeBackup(emptyPreview)
    try check(emptyTarget.healthy && emptyTarget.snippets.count == 2, "restore into pristine missing library is valid")

    func variant(_ label: String) throws -> URL {
        let url = root.appendingPathComponent(label + ".gaosnippets"); try FileManager.default.copyItem(at: package, to: url); return url
    }
    let corrupt = try variant("corrupt"), corruptFile = corrupt.appendingPathComponent(attachment.filename)
    try Data("changed bytes".utf8).write(to: corruptFile)
    let immutableTarget = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("unchanged"))
    try immutableTarget.upsert(.init(name: "safe", text: "do not modify"))
    let currentURL = immutableTarget.directory.appendingPathComponent("library.json"), currentBytes = try Data(contentsOf: currentURL)
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: corrupt, policy: .overwrite) }, "corrupt attachment rejected before restore")
    try check(try Data(contentsOf: currentURL) == currentBytes, "rejected backup leaves active library unchanged")
    let future = try variant("future")
    var futureManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: future.appendingPathComponent("manifest.json"))) as! [String: Any]
    futureManifest["schema"] = 9
    try JSONSerialization.data(withJSONObject: futureManifest).write(to: future.appendingPathComponent("manifest.json"))
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: future, policy: .keepBoth) }, "future schema rejected")
    let extra = try variant("extra"); try Data("unexpected".utf8).write(to: extra.appendingPathComponent("extra.txt"))
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: extra, policy: .keepBoth) }, "unregistered extra members rejected")
    let link = try variant("symlink"); try FileManager.default.removeItem(at: link.appendingPathComponent(attachment.filename))
    try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent(attachment.filename).path, withDestinationPath: package.appendingPathComponent(attachment.filename).path)
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: link, policy: .keepBoth) }, "symlink member rejected")
    let hard = try variant("hardlink"); try FileManager.default.removeItem(at: hard.appendingPathComponent(attachment.filename))
    try FileManager.default.linkItem(at: hard.appendingPathComponent("library.json"), to: hard.appendingPathComponent(attachment.filename))
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: hard, policy: .keepBoth) }, "hardlink member rejected")
    let missing = try variant("missing"); try FileManager.default.removeItem(at: missing.appendingPathComponent(attachment.filename))
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: missing, policy: .keepBoth) }, "missing attachment rejected")
    let alias = root.appendingPathComponent("alias.gaosnippets"); try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: package.path)
    try await fails({ _ = try await immutableTarget.previewNativeBackup(at: alias, policy: .keepBoth) }, "symlink package rejected")
    let outputAlias = root.appendingPathComponent("output-alias"); try FileManager.default.createSymbolicLink(atPath: outputAlias.path, withDestinationPath: root.path)
    try await fails({ try await source.exportNativeBackup(to: outputAlias.appendingPathComponent("unsafe.gaosnippets")) }, "symlink output parent rejected")
    try check(try Data(contentsOf: currentURL) == currentBytes, "all invalid imports retained original bytes")
    print("Native snippet backup targeted checks passed (\(checks)); no smoke test or application launch.")
}
