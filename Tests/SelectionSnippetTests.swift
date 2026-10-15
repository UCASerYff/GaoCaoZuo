import AppKit
import Foundation
import CryptoKit
import Darwin

/// No application launch, event monitor, synthetic key or general pasteboard
/// write occurs here. All persistence/ZIP fixtures are isolated and removed.
@MainActor func runSelectionSnippetTests() throws {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        count += 1; guard try value() else { throw DataFailure.message("Selection/snippet: " + message) }
    }
    func rejects(_ body: () throws -> Void, _ message: String) throws {
        var failed = false; do { try body() } catch { failed = true }; try check(failed, message)
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let selected = SelectionSnapshot(pid: 42, bundleID: "test.synthetic", launchIdentity: "audit-42", element: nil,
        selectedText: "ABC", range: CFRange(location: 3, length: 3), timestamp: now, generation: 7)
    var evidence = SelectionTargetEvidence(pid: 42, bundleID: "test.synthetic", launchIdentity: "audit-42", foregroundPID: 42,
        sameElement: true, sameWindow: true, selectedRange: CFRange(location: 3, length: 3), textSHA256: selected.textSHA256,
        secureInput: false, writable: true)
    func refusal(_ candidate: SelectionTargetEvidence, generation: UInt64 = 7, date: Date? = nil) -> String? {
        SelectionTargetValidator.refusal(snapshot: selected, evidence: candidate, generation: generation, now: date ?? now)
    }
    try check(refusal(evidence) == nil, "matching target evidence")
    try check(refusal(evidence, generation: 8) != nil, "stale generation")
    try check(refusal(evidence, date: now.addingTimeInterval(61)) != nil, "expired selection")
    try check(refusal(evidence, date: now.addingTimeInterval(-1)) != nil, "future timestamp")
    evidence.launchIdentity = "reused-pid"; try check(refusal(evidence) != nil, "PID reuse"); evidence.launchIdentity = "audit-42"
    evidence.foregroundPID = 43; try check(refusal(evidence) != nil, "frontmost changed"); evidence.foregroundPID = 42
    evidence.sameElement = false; try check(refusal(evidence) != nil, "focus element changed"); evidence.sameElement = true
    evidence.sameWindow = false; try check(refusal(evidence) != nil, "window changed"); evidence.sameWindow = true
    evidence.selectedRange = CFRange(location: 4, length: 3); try check(refusal(evidence) != nil, "range moved"); evidence.selectedRange = CFRange(location: 3, length: 3)
    evidence.textSHA256 = "other"; try check(refusal(evidence) != nil, "selection text changed"); evidence.textSHA256 = selected.textSHA256
    evidence.secureInput = true; try check(refusal(evidence) != nil, "secure input"); evidence.secureInput = false
    evidence.writable = false; try check(refusal(evidence) != nil, "read-only element")
    try check(!selected.matchesTarget(currentPID: nil, currentBundleID: nil, generation: 7), "unknown target fails closed")

    let originalText = "  =SUM(A1)\r\n第二行, \"双引号\"\n'原始单引号与 emoji 🧪  "
    let phrase = AdvancedSnippet(name: "'名称", text: originalText, shortcut: "test")
    let csv = SnippetCSVCodec.exportCSV(snippets: [phrase], groups: [])
    let imported = try SnippetCSVCodec.importCSV(csv, existingSnippets: [], existingGroups: [], policy: .keepBoth)
    try check(imported.snippets.first?.name == phrase.name && imported.snippets.first?.text == originalText, "CSV quoted newline/quote/whitespace round trip")
    let apostropheFormula = AdvancedSnippet(name: "原样", text: "'=原有文本")
    let apostropheRoundTrip = try SnippetCSVCodec.importCSV(SnippetCSVCodec.exportCSV(snippets: [apostropheFormula], groups: []), existingSnippets: [], existingGroups: [], policy: .keepBoth)
    try check(apostropheRoundTrip.snippets.first?.text == apostropheFormula.text, "formula-prefix apostrophe preserved")
    try rejects({ _ = try SnippetCSVCodec.importCSV("名称,快捷码,分组,执行方式,内容\n\"未闭合,x,,copyOnly,text", existingSnippets: [], existingGroups: [], policy: .keepBoth) }, "malformed CSV rejected atomically")
    let overwritten = try SnippetCSVCodec.importCSV(csv, existingSnippets: [phrase], existingGroups: [], policy: .overwrite)
    try check(overwritten.snippets.count == 1 && overwritten.snippets[0].id == phrase.id, "overwrite keeps stable UUID")
    let duplicate = try SnippetCSVCodec.importCSV(csv, existingSnippets: [phrase], existingGroups: [], policy: .keepBoth)
    try check(duplicate.snippets.count == 2 && duplicate.snippets.last?.shortcut == nil, "keep both has no ambiguous shortcut")
    let xlsx = try SnippetXLSXCodec.exportXLSX(snippets: [phrase, .init(name: "转义", text: "_x0041_\r\n=1+1")], groups: [])
    try check(xlsx.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]), "real ZIP container")
    let rows = try SnippetXLSXCodec.importXLSX(xlsx)
    try check(rows[1][4] == originalText && rows[2][4] == "_x0041_\r\n=1+1", "XLSX inline strings/formula literal/OOXML escape round trip")
    try rejects({ _ = try SnippetXLSXCodec.importXLSX(Data("not xlsx".utf8)) }, "invalid XLSX rejected")
    try rejects({ _ = try SnippetXLSXCodec.importXLSX(Data(repeating: 0, count: SnippetXLSXCodec.maximumBytes + 1)) }, "XLSX size bound")
    let sharedFixture = try selectionSnippetXLSXFixture(cell: "<c r=\"A2\" t=\"s\"><v>0</v></c><c r=\"D2\" t=\"inlineStr\"><is><t>copyOnly</t></is></c><c r=\"E2\" t=\"s\"><v>1</v></c>", shared: "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>共享名称</t></si><si><r><t>富串</t></r><r><t>正文</t></r></si></sst>")
    let sharedRows = try SnippetXLSXCodec.importXLSX(sharedFixture)
    try check(sharedRows[1][0] == "共享名称" && sharedRows[1][4] == "富串正文", "compressed XLSX shared strings and sparse cells")
    let formulaFixture = try selectionSnippetXLSXFixture(cell: "<c r=\"A2\" t=\"str\"><f>HYPERLINK(\"https://invalid\")</f><v>x</v></c>")
    try rejects({ _ = try SnippetXLSXCodec.importXLSX(formulaFixture) }, "XLSX formulas never evaluated or imported")
    let externalFixture = try selectionSnippetXLSXFixture(cell: "<c r=\"A2\" t=\"str\"><v>x</v></c>", external: true)
    try rejects({ _ = try SnippetXLSXCodec.importXLSX(externalFixture) }, "XLSX external relationships rejected")
    let entityFixture = try selectionSnippetXLSXFixture(cell: "<c r=\"A2\" t=\"str\"><v>x</v></c>", shared: "<!DOCTYPE sst [<!ENTITY secret SYSTEM \"file:///never-read\">]><sst><si><t>&secret;</t></si></sst>")
    try rejects({ _ = try SnippetXLSXCodec.importXLSX(entityFixture) }, "XLSX external entity rejected")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-selection-snippet-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = SnippetLibraryStore(dataDirectory: root)
    try check(library.healthy && library.snippets.isEmpty, "new library has no sample records")
    let old = TextSnippet(name: "旧短语", text: "不可丢失\n原文")
    try library.migrateLegacy([old]); let migratedRevision = library.revision
    try check(library.snippets.first?.id == old.id && library.snippets.first?.text == old.text, "legacy UUID and text retained")
    try library.migrateLegacy([old]); try check(library.revision == migratedRevision, "migration idempotent")
    var edited = library.snippets[0]; edited.text = "新库用户编辑"; try library.upsert(edited)
    var changedOld = old; changedOld.text = "旧入口修改"; try library.migrateLegacy([changedOld])
    try check(library.snippets[0].text == "新库用户编辑", "three-way migration keeps advanced edits")
    let reopened = SnippetLibraryStore(dataDirectory: root)
    try check(reopened.healthy && reopened.snippets == library.snippets, "restart persistence")
    let beforeImport = library.snippets
    let preview = try library.previewCSV(csv, policy: .keepBoth)
    try check(preview.added == 1 && library.snippets == beforeImport, "import preview has no write")
    try library.applyImport(preview)
    try check(library.snippets.count == 2 && library.canUndo, "import committed")
    try library.undoLastChange(); try check(library.snippets == beforeImport, "import rollback retains original")
    try rejects({ try library.applyImport(preview) }, "stale preview cannot override later revision")
    try library.importXLSX(xlsx, policy: .keepBoth)
    try check(library.snippets.contains(where: { $0.text == originalText }), "real XLSX committed")

    let blobURL = root.appendingPathComponent("sample.txt"), blob = Data("private synthetic attachment\n".utf8)
    try blob.write(to: blobURL)
    let attachment = try library.importAttachment(from: blobURL, type: "public.plain-text")
    let rich = AdvancedSnippet(name: "富附件", text: "正文", format: .richText, richTextRTF: "{\\rtf1\\ansi Body}", attachments: [attachment])
    try library.upsert(rich)
    try check(try library.verifiedAttachment(attachment) == blob, "attachment digest and size verified")
    let copied = try library.pasteboardItems(for: rich)
    try check(copied.count == 2 && copied[0].data(forType: .rtf) != nil && copied[1].string(forType: .fileURL) != nil, "rich data and file retained without general pasteboard write")
    let attachmentReopen = SnippetLibraryStore(dataDirectory: root)
    try check(attachmentReopen.healthy && attachmentReopen.snippets.contains(rich), "rich attachment restart")
    let oldPath = AdvancedSnippet(name: "旧文件", text: "", attachmentPaths: ["/never-read"])
    try rejects({ _ = try library.pasteboardItems(for: oldPath) }, "legacy paths require authorization")
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: blobURL.path)
    try rejects({ _ = try library.importAttachment(from: root.appendingPathComponent("link"), type: "public.plain-text") }, "selected symlink rejected")
    let fifo=root.appendingPathComponent("untrusted-input.fifo")
    guard mkfifo(fifo.path,0o600) == 0 else {throw DataFailure.message("无法建立隔离FIFO拒绝样例")}
    let fifoStart=ProcessInfo.processInfo.systemUptime
    try rejects({_ = try SnippetLibraryStore.readSelectedFile(fifo,maximum:1024)},"FIFO without writer rejected before blocking")
    try check(ProcessInfo.processInfo.systemUptime-fifoStart < 2,"special-file rejection is bounded")
    let oldSettingsBytes = Data("unchanged legacy settings".utf8)
    try oldSettingsBytes.write(to: root.appendingPathComponent("settings-placeholder"))
    try Data("tamper".utf8).write(to: library.directory.appendingPathComponent(attachment.filename))
    let brokenAttachment = SnippetLibraryStore(dataDirectory: root)
    try check(!brokenAttachment.healthy, "attachment damage stops opening")
    try rejects({ try brokenAttachment.upsert(.init(name: "x", text: "y")) }, "damaged library cannot overwrite")
    try check(try Data(contentsOf: root.appendingPathComponent("settings-placeholder")) == oldSettingsBytes, "unrelated legacy file untouched")

    let stackRoot = root.appendingPathComponent("stack-test"), stack = PasteStack()
    try stack.configurePersistence(dataDirectory: stackRoot)
    try stack.pushContent(text: "第一项\n原空白 ")
    try stack.pushContent(text: "RTF 预览", rtf: Data("{\\rtf1\\ansi rich}".utf8))
    let firstTicket = stack.peek()!
    _ = try stack.pasteboardItems(for: firstTicket)
    try check(stack.entries.count == 2, "preparing paste does not pop")
    try stack.pushContent(text: "第三项")
    try rejects({ try stack.commit(firstTicket) }, "stale stack ticket cannot pop")
    try check(stack.entries.count == 3, "failed commit retains stack")
    let currentTicket = stack.peek()!; try stack.commit(currentTicket)
    try check(stack.entries.count == 2 && stack.entries.first?.format == .richText, "successful two-phase commit pops one")
    let reopenedStack = PasteStack(); try reopenedStack.configurePersistence(dataDirectory: stackRoot)
    let richTicket = reopenedStack.peek()!
    let richItems = try reopenedStack.pasteboardItems(for: richTicket)
    try check(richItems[0].data(forType: .rtf) == Data("{\\rtf1\\ansi rich}".utf8), "raw RTF stack bytes survive restart")
    let countBeforeMerge = reopenedStack.entries.count
    try check(reopenedStack.mergeAll().isEmpty && reopenedStack.entries.count == countBeforeMerge, "rich merge refuses data loss without clipboard mutation")
    try reopenedStack.clearDurably()
    try reopenedStack.pushContent(text: nil, fileReferences: [blobURL.path])
    try FileManager.default.removeItem(at: blobURL)
    let missingTicket = reopenedStack.peek()!
    try rejects({ _ = try reopenedStack.pasteboardItems(for: missingTicket) }, "missing file reference blocks paste")
    try check(reopenedStack.entries.count == 1, "failed rich prepare retains queue")
    let afterFailure = PasteStack(); try afterFailure.configurePersistence(dataDirectory: stackRoot)
    try check(afterFailure.entries.count == 1 && afterFailure.entries[0].fileReferences?.count == 1, "invalid reference retained across restart")
    try afterFailure.clearDurably()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
    for y in 0..<2 { for x in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
    let png = bitmap.representation(using: .png, properties: [:])!
    try afterFailure.pushContent(text: nil, png: png)
    let imageTicket = afterFailure.peek()!, imageItems = try afterFailure.pasteboardItems(for: imageTicket)
    try check(imageTicket.snippet.format == .image && imageItems[1].data(forType: .png) == png, "image stack preserves actual PNG bytes")
    let imageReopen = PasteStack(); try imageReopen.configurePersistence(dataDirectory: stackRoot)
    try check(try imageReopen.pasteboardItems(for: imageReopen.peek()!)[1].data(forType: .png) == png, "PNG restart round trip")
    let libraryChangedTicket = imageReopen.peek()!
    let queueURL = stackRoot.appendingPathComponent("PasteStack/Snippets/library.json")
    let queueBytes = try Data(contentsOf: queueURL)
    var queueObject = try JSONSerialization.jsonObject(with: queueBytes) as! [String: Any]
    queueObject["revision"] = 999
    try JSONSerialization.data(withJSONObject: queueObject).write(to: queueURL)
    try rejects({ try imageReopen.validateTicket(libraryChangedTicket) }, "external library change cancels before dispatch")
    try check(imageReopen.entries.count == 1, "external change validation does not pop")

    let concurrentRoot = root.appendingPathComponent("concurrent")
    let writerA = SnippetLibraryStore(dataDirectory: concurrentRoot), writerB = SnippetLibraryStore(dataDirectory: concurrentRoot)
    try writerA.upsert(.init(name: "A", text: "first writer"))
    try rejects({ try writerB.upsert(.init(name: "B", text: "must not overwrite")) }, "concurrent store cannot silently overwrite")
    let concurrentReload = SnippetLibraryStore(dataDirectory: concurrentRoot)
    try check(concurrentReload.healthy && concurrentReload.snippets.map(\.name) == ["A"], "concurrent write preserves original data")

    let damagedStackRoot = root.appendingPathComponent("damaged-stack"), stackFolder = damagedStackRoot.appendingPathComponent("PasteStack/Snippets")
    try FileManager.default.createDirectory(at: stackFolder, withIntermediateDirectories: true)
    let badStackBytes = Data("{\"schema\":9}".utf8); try badStackBytes.write(to: stackFolder.appendingPathComponent("library.json"))
    let damagedStack = PasteStack()
    try rejects({ try damagedStack.configurePersistence(dataDirectory: damagedStackRoot) }, "future stack cannot configure")
    damagedStack.push("must not become empty replacement")
    try check(damagedStack.items.isEmpty && damagedStack.failure != nil, "blocked stack cannot silently fall back to unsaved memory")
    try check(try Data(contentsOf: stackFolder.appendingPathComponent("library.json")) == badStackBytes, "future stack file retained")

    for (name, content) in [("future", "{\"schema\":2,\"revision\":0}"), ("broken", "{bad")] {
        let folder = root.appendingPathComponent(name).appendingPathComponent("Snippets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.json"), bytes = Data(content.utf8); try bytes.write(to: url)
        let blocked = SnippetLibraryStore(dataDirectory: folder.deletingLastPathComponent())
        try check(!blocked.healthy, name + " library stopped")
        try rejects({ try blocked.upsert(.init(name: "new", text: "not written")) }, name + " cannot overwrite")
        try check(try Data(contentsOf: url) == bytes, name + " bytes retained")
    }
    print("Selection/snippet targeted checks passed (\(count)); no smoke test or application launch.")
}

/// Independently generated, deflated OOXML fixture using macOS zip. The reader
/// therefore sees a different writer, shared strings and sparse coordinates.
private func selectionSnippetXLSXFixture(cell: String, shared: String? = nil, external: Bool = false) throws -> Data {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-xlsx-fixture-" + UUID().uuidString)
    let parts = root.appendingPathComponent("parts")
    defer { try? FileManager.default.removeItem(at: root) }
    let files: [String: String] = [
        "[Content_Types].xml": "<Types/>",
        "xl/workbook.xml": "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet r:id=\"rId1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"\(external ? " TargetMode=\"External\"" : "")/></Relationships>",
        "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row r=\"1\">" + ["名称", "快捷码", "分组", "执行方式", "内容"].enumerated().map { "<c r=\"\(Character(UnicodeScalar(65 + $0.offset)!))1\" t=\"inlineStr\"><is><t>\($0.element)</t></is></c>" }.joined() + "</row><row r=\"2\">" + cell + "</row></sheetData></worksheet>"
    ]
    for (name, value) in files {
        let url = parts.appendingPathComponent(name); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(value.utf8).write(to: url)
    }
    if let shared { try Data(shared.utf8).write(to: parts.appendingPathComponent("xl/sharedStrings.xml")) }
    let archive = root.appendingPathComponent("fixture.xlsx"), process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = parts; process.arguments = ["-q", "-r", archive.path, "."]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw DataFailure.message("无法生成隔离 XLSX 样本。") }
    return try Data(contentsOf: archive)
}
