import Foundation

@MainActor func runQuickFileActionsTests() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-QuickTests-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NSError(domain: "QuickFileActionsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw NSError(domain: "QuickFileActionsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let text = try QuickFileActions.create(in: root, kind: .text)
    let text2 = try QuickFileActions.create(in: root, kind: .text)
    let markdown = try QuickFileActions.create(in: root, kind: .markdown)
    let folder = try QuickFileActions.create(in: root, kind: .folder)
    let folder2 = try QuickFileActions.create(in: root, kind: .folder)
    try expect(text.destination.lastPathComponent == "未命名.txt" && text2.destination.lastPathComponent == "未命名 2.txt", "new text uses unique names")
    try expect(markdown.destination.pathExtension == "md" && folder2.destination.lastPathComponent == "新建文件夹 2", "markdown and folder defaults")
    let template = try QuickFileActions.createTemplate(in: root, filename: "未命名.txt", content: "template contents")
    try expect(template.destination.lastPathComponent == "未命名 3.txt" && (try String(contentsOf: template.destination, encoding: .utf8)) == "template contents", "template copies content under unique name")
    try FileTools.undo([text, text2, markdown, folder, folder2, template], trashCreated: false)
    try expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "all default creations have working recovery receipts")
    let dangling = root.appendingPathComponent("foo.zip")
    try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
    try expect(try QuickFileActions.uniqueURL(in: root, preferredName: "foo.zip").lastPathComponent == "foo 2.zip", "dangling link occupies a name")
    try rejects("path escape name") { _ = try QuickFileActions.uniqueURL(in: root, preferredName: "../escape") }
    try rejects("missing parent is not empty directory") { _ = try QuickFileActions.uniqueURL(in: root.appendingPathComponent("absent"), preferredName: "a.txt") }
    try fm.removeItem(at: dangling)
    try expect(QuickFileActions.extractionFolderName(for: root.appendingPathComponent("foo.7z.001")) == "foo", "first-volume folder name")
    try expect(QuickFileActions.extractionFolderName(for: root.appendingPathComponent("foo.tar.gz")) == "foo.tar", "one-layer gzip name")

    let image = root.appendingPathComponent("图.png")
    try FileTools.qrCode(text: "temporary quick operation test").write(to: image)
    let originalDigest = try FileTools.sha256(image)
    let converted = try QuickFileActions.convertImages(items: [image, image], format: "png", maxDimension: 128)
    try expect(converted.map(\.destination.lastPathComponent) == ["图 2.png", "图 3.png"], "image conversion reserves names within batch")
    try expect(try FileTools.sha256(image) == originalDigest, "same-format image conversion preserves original")
    let brokenImage = try FileTools.createFile(in: root, name: "broken.png", content: "not an image")
    let beforeFailure = Set(try fm.contentsOfDirectory(atPath: root.path))
    try rejects("image batch fails") { _ = try QuickFileActions.convertImages(items: [image, brokenImage], format: "jpeg") }
    try expect(try Set(fm.contentsOfDirectory(atPath: root.path)) == beforeFailure, "failed image batch leaves no partial outputs or staging")
    try FileTools.undo(converted, trashCreated: false)
    try expect(try FileTools.sha256(image) == originalDigest, "image undo preserves input")
    let favorites = root.appendingPathComponent("favorite")
    try fm.createDirectory(at: favorites, withIntermediateDirectories: false)
    let copied = try QuickFileActions.copy(items: [image], to: favorites, move: false)
    try rejects("favorite copy never overwrites") { _ = try QuickFileActions.copy(items: [image], to: favorites, move: false) }
    try FileTools.undo(copied, trashCreated: false)
    let moved = try QuickFileActions.copy(items: [brokenImage], to: favorites, move: true)
    try FileTools.undo(moved, trashCreated: false)
    try expect(fm.fileExists(atPath: brokenImage.path), "favorite move can be restored")

    let engineArg = CommandLine.arguments.firstIndex(of: "--engine").flatMap { index in index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil }
    guard let enginePath = engineArg ?? ProcessInfo.processInfo.environment["GAO_TEST_7ZZ"] else {
        throw NSError(domain: "QuickFileActionsTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Real engine tests require --engine path"])
    }
    let service = ArchiveService(engineURL: URL(fileURLWithPath: enginePath))
    let source = try FileTools.createFile(in: root, name: "内容.txt", content: "archive contents")
    let firstZip = try await QuickFileActions.createZIP(items: [source], service: service)
    let firstZipReceipt = service.lastResultReceipts[0]
    try expect(firstZipReceipt.destination == firstZip && (try FileTools.fingerprint(firstZip)) == firstZipReceipt.fingerprint, "created ZIP has matching prepublication receipt")
    let secondZip = try await QuickFileActions.createZIP(items: [source], service: service)
    try expect(firstZip.lastPathComponent == "内容.zip" && secondZip.lastPathComponent == "内容 2.zip", "single quick ZIP unique names")
    let multi = try await QuickFileActions.createArchive(items: [source, image], format: .sevenZip, service: service)
    try expect(multi.lastPathComponent == "归档.7z", "multi-selection quick 7Z")
    let multiZip = try await QuickFileActions.createZIP(items: [source, image], service: service)
    try expect(multiZip.lastPathComponent == "归档.zip", "multi-selection quick ZIP")
    let otherParent = root.appendingPathComponent("other-parent")
    try fm.createDirectory(at: otherParent, withIntermediateDirectories: false)
    let otherSource = try FileTools.createFile(in: otherParent, name: "other.txt", content: "second parent")
    let crossParentZip = try await QuickFileActions.createZIP(items: [source, otherSource], service: service)
    let crossEntries = try await service.list(archive: crossParentZip, password: nil)
    try expect(crossParentZip.deletingLastPathComponent().path == root.path && Set(crossEntries.map(\.path)) == ["内容.txt", "other.txt"], "cross-parent selection saves in first parent and includes both files")
    try expect(service.lastResultReceipts.isEmpty, "new non-creating job clears old result receipts")
    let sameNamedSource = try FileTools.createFile(in: otherParent, name: "内容.txt", content: "different source with same basename")
    let beforeCollision = Set(try fm.contentsOfDirectory(atPath: root.path))
    do { _ = try await QuickFileActions.createZIP(items: [source, sameNamedSource], service: service); throw NSError(domain: "ExpectedCrossParentCollision", code: 1) }
    catch is FileToolsError { checks += 1 }
    try expect(try Set(fm.contentsOfDirectory(atPath: root.path)) == beforeCollision, "cross-parent duplicate basenames fail without an output or staging")
    let secret = "only-test-password"
    let sevenZipSecret = "only-test-中文-password"
    let encryptedZip = try await service.create(items: [source], destination: root.appendingPathComponent("加密.zip"), format: .zip, password: secret, splitMB: nil, solid: false)
    let encrypted7z = try await service.create(items: [source], destination: root.appendingPathComponent("加密.7z"), format: .sevenZip, password: sevenZipSecret, splitMB: nil, solid: true)
    let batch = try QuickFileActions.makeExtractionBatch(archives: [firstZip, encryptedZip, encrypted7z, multiZip, firstZip])
    try expect(batch.items.count == 4, "duplicate archive selection deduplicated")
    let waiting = await QuickFileActions.continueExtraction(batch, service: service)
    try expect(waiting.outputs.count == 1 && waiting.currentItem?.status == .needsPassword(incorrect: false), "plain output retained before ZIP password prompt")
    let firstOutput = waiting.outputs[0]
    let firstOutputFingerprint = try FileTools.fingerprint(firstOutput)
    try expect(waiting.items[0].receipt?.fingerprint == firstOutputFingerprint, "extraction carries prepublication receipt")
    let wrong = await QuickFileActions.continueExtraction(waiting, service: service, password: "wrong")
    try expect(wrong.outputs == waiting.outputs && wrong.currentItem?.status == .needsPassword(incorrect: true), "wrong ZIP password preserves completed prefix")
    let secondWaiting = await QuickFileActions.continueExtraction(wrong, service: service, password: secret)
    try expect(secondWaiting.outputs.count == 2 && secondWaiting.currentItem?.archive == encrypted7z && secondWaiting.currentItem?.status == .needsPassword(incorrect: false), "password is not forwarded to another archive")
    let wrong7z = await QuickFileActions.continueExtraction(secondWaiting, service: service, password: "wrong")
    try expect(wrong7z.currentItem?.status == .needsPassword(incorrect: true), "header-encrypted 7Z wrong-password classification")
    let completed = await QuickFileActions.continueExtraction(wrong7z, service: service, password: sevenZipSecret)
    try expect(completed.isComplete && completed.outputs.count == 4, "batch resumes from password item through remaining archives")
    try expect(completed.outputs[2].lastPathComponent == "加密 2", "same archive stems get independent unique extraction directories")
    try expect(try FileTools.fingerprint(firstOutput) == firstOutputFingerprint, "completed output never reprocessed")
    let noOp = await QuickFileActions.continueExtraction(completed, service: service)
    try expect(noOp.outputs == completed.outputs, "completed batch retry is no-op")
    try expect(!service.output.contains(secret) && !service.output.contains(sevenZipSecret), "quick extraction does not log password")
    try expect(!ArchiveService.isPasswordDiagnostic("Enter password:\nSystem ERROR:\nE_INVALIDARG", exitCode: 2, passwordProvided: true), "unrelated failure after password prompt is not wrong-password classification")
    let bad = try QuickFileActions.makeExtractionBatch(archives: [brokenImage])
    let badResult = await QuickFileActions.continueExtraction(bad, service: service)
    if case .failed? = badResult.currentItem?.status { checks += 1 }
    else { throw NSError(domain: "QuickFileActionsTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "corrupt archive must be failure, not password prompt"] ) }
    let cancellation = Task { @MainActor in await QuickFileActions.continueExtraction(batch, service: service) }
    cancellation.cancel()
    let cancelled = await cancellation.value
    try expect(cancelled.outputs.isEmpty && cancelled.currentItem?.status == .cancelled, "cancelled batch preserves inputs without output")
    let steppedBatch = try QuickFileActions.makeExtractionBatch(archives: [firstZip, secondZip])
    let stepped = await QuickFileActions.continueExtraction(steppedBatch, service: service, stopAfterFirstSuccess: true)
    try expect(stepped.outputs.count == 1 && !stepped.isComplete && stepped.currentItem?.status == .pending, "step mode returns after one successful archive")
    let cancelledRemainder = Task { @MainActor in await QuickFileActions.continueExtraction(stepped, service: service, stopAfterFirstSuccess: true) }
    cancelledRemainder.cancel()
    let stopped = await cancelledRemainder.value
    try expect(stopped.outputs == stepped.outputs && !stopped.isComplete && stopped.currentItem?.status == .cancelled, "partial batch cancellation preserves completed prefix and never reports complete")
    let finishedSteps = await QuickFileActions.continueExtraction(stopped, service: service, stopAfterFirstSuccess: true)
    try expect(finishedSteps.isComplete && finishedSteps.outputs[0] == stepped.outputs[0], "step mode can resume cancelled remainder without reprocessing prefix")
    let protectedReceipt = finishedSteps.items[0].receipt!
    try Data("user edit after publication".utf8).write(to: protectedReceipt.destination.appendingPathComponent("内容.txt"))
    try rejects("extraction recovery rejects user changes after publication") { try FileTools.undo([protectedReceipt], trashCreated: false) }
    try Data("modified ZIP after publication".utf8).write(to: firstZip)
    try rejects("archive recovery rejects user changes after publication") { try FileTools.undo([firstZipReceipt], trashCreated: false) }
    print("PASS: \(checks) quick-file checks; temporary fixtures removed")
}
