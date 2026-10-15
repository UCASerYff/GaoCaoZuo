import AppKit
import CryptoKit
import Foundation

@MainActor func runSnippetNamedAttachmentExportTests() throws {
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; guard try condition() else { throw DataFailure.message("Named snippet export: " + message) }
    }
    func rejects(_ body: () throws -> Void, _ message: String) throws {
        var failed = false; do { try body() } catch { failed = true }; try check(failed, message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-named-snippet-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = SnippetLibraryStore(dataDirectory: root.appendingPathComponent("library"))
    let bytes = Data("synthetic ordinary attachment\n".utf8)
    let first = try library.importAttachment(data: bytes, originalName: "合同 \"示例\"🧪.txt", type: "public.plain-text")
    let second = try library.importAttachment(data: Data("different content".utf8), originalName: first.originalName, type: "public.plain-text")
    let snippet = AdvancedSnippet(name: "ordinary file", text: "", format: .fileReference, attachments: [first])
    try library.upsert(snippet)
    let originalBlob = library.directory.appendingPathComponent(first.filename), originalBytes = try Data(contentsOf: originalBlob)
    let prepared = try library.pasteboardItems(for: snippet)
    let delivered = URL(string: prepared[1].string(forType: .fileURL)!)!
    try check(delivered.lastPathComponent == first.originalName && delivered.pathExtension == "txt", "original Unicode name and real extension preserved")
    try check(try Data(contentsOf: delivered) == bytes && originalBytes == bytes, "delivery and immutable source bytes match")
    try check(delivered.path != originalBlob.path && delivered.path.hasPrefix(library.namedAttachmentExportsDirectory.path + "/"), "delivery copy is inside own private cache")
    let reused = try library.pasteboardItems(for: snippet)
    try check(reused[1].string(forType: .fileURL) == prepared[1].string(forType: .fileURL), "same digest/name reuses verified copy")
    let otherSnippet = AdvancedSnippet(name: "same name other bytes", text: "", format: .fileReference, attachments: [second])
    let otherURL = URL(string: try library.pasteboardItems(for: otherSnippet)[1].string(forType: .fileURL)!)!
    try check(otherURL.lastPathComponent == delivered.lastPathComponent && otherURL.deletingLastPathComponent() != delivered.deletingLastPathComponent(), "same filename with different content isolated")
    try check(try Data(contentsOf: delivered) == bytes, "same-name delivery never overwrites previous copy")
    let alternateName = try library.importAttachment(data: bytes, originalName: "不同名字.pdf", type: "com.adobe.pdf")
    let alternate = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: alternateName, directory: library.namedAttachmentExportsDirectory)
    try check(alternate.lastPathComponent == "不同名字.pdf" && alternate.deletingLastPathComponent() != delivered.deletingLastPathComponent(), "same bytes with different filename isolated")
    let metadataPath = delivered.deletingLastPathComponent().appendingPathComponent(".DS_Store")
    try Data([0, 1, 2]).write(to: metadataPath)
    _ = try library.pasteboardItems(for: snippet)
    try check(try Data(contentsOf: delivered) == bytes, "Finder metadata does not replace delivery content")
    try Data("user changed delivery copy".utf8).write(to: delivered)
    try rejects({ _ = try library.pasteboardItems(for: snippet) }, "modified delivery cache is rejected without overwrite")
    try check(try Data(contentsOf: originalBlob) == originalBytes && library.healthy, "cache corruption does not corrupt or disable original library")

    for name in ["../escape.txt", "bad/name.pdf", "bad\\name.txt", "bad:name.txt", ".", "..", "bad\nname.txt", "bad\0name", "bad\u{202e}fdp.exe", String(repeating: "字", count: 81) + ".txt"] {
        let bad = SnippetAttachment(filename: first.filename, originalName: name, type: first.type, sha256: first.sha256, byteCount: first.byteCount)
        try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: bad, directory: root.appendingPathComponent("bad-names")) }, "dangerous/overlong name rejected")
    }
    let budget = root.appendingPathComponent("budget"), limits = SnippetNamedAttachmentExports.Limits(maximumItems: 1, maximumBytes: bytes.count)
    let one = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: budget, limits: limits)
    try check(try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: budget, limits: limits) == one, "full cache can reuse existing verified item")
    try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: alternateName, directory: budget, limits: limits) }, "item/disk budget prevents new copy")
    try check(try Data(contentsOf: one) == bytes, "budget failure never auto-deletes existing copy")

    for (name, marker) in [("future", "{\"schema\":9,\"format\":\"GaoCaoZuo.NamedSnippetAttachmentExports\"}"), ("broken", "{bad")] {
        let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("format.json"), data = Data(marker.utf8); try data.write(to: file)
        try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: folder) }, name + " marker refuses reset")
        try check(try Data(contentsOf: file) == data, name + " marker preserved")
    }
    let linkRoot = root.appendingPathComponent("link-cache"), exported = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: linkRoot)
    try FileManager.default.removeItem(at: exported)
    try FileManager.default.createSymbolicLink(atPath: exported.path, withDestinationPath: originalBlob.path)
    try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: linkRoot) }, "symlink replacement rejected")
    try check(try Data(contentsOf: originalBlob) == bytes, "symlink target original unchanged")
    let hardRoot = root.appendingPathComponent("hard-cache"), hard = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: hardRoot)
    let outside = root.appendingPathComponent("owned-hardlink-target"); try bytes.write(to: outside)
    try FileManager.default.removeItem(at: hard); try FileManager.default.linkItem(at: outside, to: hard)
    try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: hardRoot) }, "hardlink replacement rejected")
    let directoryLink = root.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: budget.path)
    try rejects({ _ = try SnippetNamedAttachmentExports.prepare(data: bytes, attachment: first, directory: directoryLink) }, "cache directory link rejected")
    print("Named snippet attachment export targeted checks passed (\(checks)); no general pasteboard write or application launch.")
}
