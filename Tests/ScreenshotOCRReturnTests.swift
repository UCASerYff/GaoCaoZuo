import Foundation

enum ScreenshotOCRReturnTests {
    static func run(in root: URL) throws {
        let now = ScreenshotGaoActionContract.date("2026-11-27T02:00:00.250Z")!
        let files = try Fixture(root, source: "com.gaoseries.GaoWenJian", now: now, uppercase: true)
        let research = try Fixture(root, source: "com.academic-achievement.manager", now: now.addingTimeInterval(0.0008), uppercase: false)
        try checkWriterMilliseconds(research)
        for fixture in [files, research] {
            try check(!fixture.ready(), "Absent ticket must never permit automatic publication")
            try check(fixture.publish() == .unavailable && !exists(fixture.destination), "No result before a bound ticket")
            try fixture.writeTicket()
            try check(fixture.ready(), "Sender ticket matches the original raw manifest")
            var unapproved = fixture.ledger.lookup(fixture.binding.requestID)!
            unapproved.phase = .received
            try check(ScreenshotOCRReturn.publish(unapproved, resultURL: fixture.result, root: fixture.root, clock: { now }) == .unavailable && !exists(fixture.destination), "Before approval, a valid ticket must not publish")
            try check(fixture.publish() == .published, "The approved result must publish")
            let first = try Data(contentsOf: fixture.destination.appendingPathComponent("manifest.json"))
            try check(fixture.publish() == .published, "A matching existing result must be idempotent")
            try check(try Data(contentsOf: fixture.destination.appendingPathComponent("manifest.json")) == first, "Retry changed result bytes")
            let received = try ScreenshotGaoActionTransport.receive(packageURL: fixture.destination, exchangeRoot: fixture.exchange, expectedTargetBundleID: fixture.binding.sourceBundleID, now: fixture.clock)
            try check(received.manifest.inReplyTo == fixture.binding.requestID, "The original UUID spelling must be preserved")
            let sentAt = ScreenshotGaoActionContract.date(received.manifest.createdAt)!
            let requestedAt = ScreenshotGaoActionContract.date(fixture.binding.createdAt)!
            try check(sentAt >= requestedAt, "An OCR result cannot predate a fractional request sent the same second")
            try check(received.manifest.parameters.isEmpty, "Results carry no new action parameters")
            try check(received.manifest.provenance?["requestManifestSHA256"]?.stringValue == fixture.binding.requestManifestSHA256, "Raw request digest missing")
            try check(received.manifest.targetBundleID == fixture.binding.sourceBundleID && received.manifest.sourceBundleID == ScreenshotGaoActionContract.bundleID, "The result reverses the two bundle IDs")
            try check(try Data(contentsOf: received.stagedItems[0].url) == fixture.resultBytes, "Result payload did not survive transfer")
            if fixture.binding.sourceBundleID == "com.academic-achievement.manager" {
                try check(received.manifest.items[0].relativePath.hasPrefix("payload/"), "Research package-relative path was lost")
            }
            try check(try FileManager.default.contentsOfDirectory(atPath: fixture.slot.path).sorted() == ["request.json", "result.gaoaction"], "Publication left a temporary directory")
            try fixture.ledger.recordAutomaticOCRReturn(requestID: fixture.binding.requestID, packageName: fixture.result.lastPathComponent, digest: fixture.resultDigest, status: .published)
            try fixture.ledger.recordAutomaticOCRReturn(requestID: fixture.binding.requestID, packageName: fixture.result.lastPathComponent, digest: fixture.resultDigest, status: .unavailable)
            let reopened = try ScreenshotGaoProcessedRequestStore(root: fixture.exchange)
            try check(reopened.lookup(fixture.binding.requestID)?.automaticReturn == .published, "Published delivery state must survive restart")
            try check(reopened.lookup(fixture.binding.requestID)?.ocrReturnBinding == fixture.binding, "The exact original request binding must survive restart")
        }
        let invalid = try Fixture(root, source: "com.gaoseries.GaoWenJian", now: now, uppercase: true)
        for (key, value) in ["requestID":invalid.binding.requestID.lowercased(), "action":"images.pin", "sourceBundleID":"com.academic-achievement.manager", "targetBundleID":"com.gaoseries.Else", "requestManifestSHA256":String(repeating: "a", count: 64), "expiresAt":"2026-11-27T02:02:00Z", "path":"/tmp/unrelated"] {
            var impostor = invalid.ticket
            impostor[key] = value
            try invalid.writeTicket(impostor)
            try check(!invalid.ready() && invalid.publish() == .unavailable && !exists(invalid.destination), "An invalid ticket value was accepted: \(key)")
        }
        let correct = try JSONSerialization.data(withJSONObject: invalid.ticket, options: [.sortedKeys])
        let correctText = String(decoding: correct, as: UTF8.self)
        for spelling in ["true", "1.0", "1e0", "2"] {
            let bad = correctText.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":\(spelling)")
            try invalid.writeRawTicket(Data(bad.utf8))
            try check(invalid.publish() == .unavailable, "Invalid schema literal was accepted: \(spelling)")
        }
        let duplicate = "{\"schemaVersion\":1," + String(correctText.dropFirst())
        try invalid.writeRawTicket(Data(duplicate.utf8))
        try check(invalid.publish() == .unavailable, "Duplicate ticket field was accepted")
        try invalid.writeRawTicket(Data([0xEF, 0xBB, 0xBF]) + correct)
        try check(invalid.publish() == .unavailable, "UTF-8 BOM was accepted")
        try invalid.writeTicket()
        var checks = 0
        try check(invalid.publish(clock: { checks += 1; return checks < 4 ? now : now.addingTimeInterval(120) }) == .expired, "Publication did not recheck expiry before commit")
        try check(try FileManager.default.contentsOfDirectory(atPath: invalid.slot.path) == ["request.json"], "Expired publication left content in the slot")
        try check(exists(invalid.result), "Manual result was lost when the ticket expired")
        let manualFolder = invalid.root.deletingLastPathComponent().appendingPathComponent("ManualExport", isDirectory: true)
        try FileManager.default.createDirectory(at: manualFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manual = try ScreenshotGaoSavedPackage(invalid.result)
        try manual.publish(to: ScreenshotGaoPrivateIO.directory(manualFolder), name: "Verified.gaoaction")
        try check(exists(manualFolder.appendingPathComponent("Verified.gaoaction/manifest.json")), "A failed automatic return must still be manually exportable")
        try check(invalid.publish(digest: String(repeating: "f", count: 64)) == .unavailable, "The result digest binding was ignored")
        try FileManager.default.createDirectory(at: invalid.destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unrelated = invalid.destination.appendingPathComponent("unrelated.txt")
        let marker = Data("unrelated result".utf8)
        try marker.write(to: unrelated)
        try check(invalid.publish() == .unavailable, "Occupied result path was treated as a valid receipt")
        try check(try Data(contentsOf: unrelated) == marker, "An unrelated result was overwritten")

        let links = try Fixture(root, source: "com.gaoseries.GaoWenJian", now: now, uppercase: true)
        try links.writeTicket()
        let safe = links.slot.appendingPathComponent("private-ticket")
        try FileManager.default.moveItem(at: links.ticketURL, to: safe)
        try FileManager.default.createSymbolicLink(at: links.ticketURL, withDestinationURL: safe)
        try check(links.publish() == .unavailable && !exists(links.destination), "Linked ticket was followed")
        try FileManager.default.removeItem(at: links.ticketURL)
        try FileManager.default.moveItem(at: safe, to: links.ticketURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: links.ticketURL.path)
        try check(links.publish() == .unavailable, "Ticket with public permissions was accepted")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: links.ticketURL.path)
        let displacedSlot = links.root.appendingPathComponent("renamed-slot")
        try FileManager.default.moveItem(at: links.slot, to: displacedSlot)
        try FileManager.default.createSymbolicLink(at: links.slot, withDestinationURL: displacedSlot)
        try check(links.publish() == .unavailable && !exists(displacedSlot.appendingPathComponent("result.gaoaction")), "Linked request directory was followed")
        try FileManager.default.removeItem(at: links.slot)
        try FileManager.default.moveItem(at: displacedSlot, to: links.root.appendingPathComponent(links.binding.requestID))
        try check(links.publish() == .unavailable, "Noncanonical directory spelling was accepted")

        let original = try Data(contentsOf: files.request.stagedItems[0].url)
        try ScreenshotGaoActionTransport.verifyStagedOCR(files.request)
        try Data(repeating: 17, count: original.count).write(to: files.request.stagedItems[0].url)
        do {
            try ScreenshotGaoActionTransport.verifyStagedOCR(files.request)
            throw testFailure("Changed staged OCR attachment was accepted")
        } catch let error as ScreenshotGaoActionIssue where error.code == "digestMismatch" {}
        print("Screenshot OCR automatic return PASS: both senders, original digest, expiry, conflicts, symlinks and retained result")
    }

    private static func checkWriterMilliseconds(_ fixture: Fixture) throws {
        let contract = ScreenshotGaoActionContract.self
        let manifest = try ScreenshotGaoActionTransport.decodeManifest(Data(contentsOf: fixture.result.appendingPathComponent("manifest.json")))
        try check(manifest.createdAt == "2026-11-27T02:00:00.250Z" &&
                  manifest.expiresAt == "2026-11-27T02:02:00.250Z", "A .2508-second result must floor creation and retain its 120-second TTL")

        let edges = [("2026-11-27T02:00:00.125Z", "2026-11-27T02:02:00.125Z", 0.0),
                     ("2026-11-27T02:00:00.999Z", "2026-11-27T02:02:00.999Z", 0.0008)]
        for (createdAt, expiresAt, offset) in edges {
            let time = contract.date(createdAt)!.addingTimeInterval(offset)
            let url = try ScreenshotGaoActionWriter.writeResult(inReplyTo: fixture.request.manifest, status: "cancelled", exchangeRoot: fixture.exchange, now: time)
            let payload = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
            let result = try ScreenshotGaoActionTransport.decodeManifest(payload)
            try check(result.createdAt == createdAt && result.expiresAt == expiresAt, "Writer lost an exact or last millisecond of a second")
        }

        let requestTime = contract.date(fixture.binding.createdAt)!
        do {
            _ = try ScreenshotGaoActionWriter.writeResult(inReplyTo: fixture.request.manifest, status: "cancelled", exchangeRoot: fixture.exchange, now: requestTime.addingTimeInterval(-0.0002))
            throw testFailure("Writer accepted an OCR result before its request")
        } catch let error as ScreenshotGaoActionIssue where error.code == "expired" {}

        let creation = contract.date(manifest.createdAt)!, expiry = contract.date(manifest.expiresAt)!
        for outside in [creation.addingTimeInterval(-0.0001), expiry] {
            do {
                try contract.validate(manifest, expectedTargetBundleID: fixture.binding.sourceBundleID, now: outside)
                throw testFailure("Validator accepted a future or expired OCR result")
            } catch let error as ScreenshotGaoActionIssue where error.code == "expired" {}
        }
    }

    private struct Fixture {
        let root: URL
        let exchange: URL
        let clock: Date
        let request: ScreenshotGaoValidatedPackage
        let ledger: ScreenshotGaoProcessedRequestStore
        let binding: ScreenshotOCRReturnBinding
        let slot: URL
        let result: URL
        let resultDigest: String
        let resultBytes = Data("synthetic OCR text\n".utf8)

        var ticketURL: URL { slot.appendingPathComponent("request.json") }
        var destination: URL { slot.appendingPathComponent("result.gaoaction", isDirectory: true) }
        var ticket: [String: Any] {
            ["schemaVersion":1, "requestID":binding.requestID, "action":"ocr.files", "sourceBundleID":binding.sourceBundleID,
             "targetBundleID":ScreenshotGaoActionContract.bundleID, "requestManifestSHA256":binding.requestManifestSHA256, "expiresAt":binding.expiresAt]
        }

        init(_ parent: URL, source: String, now: Date, uppercase: Bool) throws {
            let directory = parent.appendingPathComponent("OCRReturn-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            clock = now
            root = directory.appendingPathComponent("OcrReturns-v1", isDirectory: true)
            exchange = directory.appendingPathComponent("Exchange", isDirectory: true)
            let input = directory.appendingPathComponent("fixture.png")
            try Data("generated transport-only fixture".utf8).write(to: input)
            let out = try ScreenshotGaoActionWriter.writeRequest(action: "ocr.files", items: [.init(url: input, uti: "public.png", id: "original")],
                 sourceBundleID: source, targetBundleID: ScreenshotGaoActionContract.bundleID, exchangeRoot: exchange, now: now,
                 requestID: UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")!)
            let manifestURL = out.appendingPathComponent("manifest.json")
            // The fixture's exact raw bytes (including whitespace and optional fractional seconds) are the contract.
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            if !uppercase { object["requestID"] = (object["requestID"] as! String).lowercased() }
            object["createdAt"] = "2026-11-27T02:00:00.125Z"
            object["expiresAt"] = "2026-11-27T02:02:00.125Z"
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
            try bytes.write(to: manifestURL)
            request = try ScreenshotGaoActionTransport.receive(packageURL: out, exchangeRoot: exchange, now: now)
            let expectedDigest = ScreenshotFileSafety.digest(bytes)
            guard let binding = ScreenshotOCRReturnBinding(request), binding.requestManifestSHA256 == expectedDigest else { throw testFailure("Missing exact manifest binding") }
            self.binding = binding
            slot = root.appendingPathComponent(binding.requestID.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let output = directory.appendingPathComponent("recognized.txt")
            try resultBytes.write(to: output)
            let item = request.manifest.items[0]
            let sourceMap: [String: ScreenshotGaoJSONValue] = ["sourceID": .string("page-source"), "sourceItemID": .string(item.id), "sourceSHA256": .string(item.sha256)]
            var sourceWithPages = sourceMap
            sourceWithPages["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("completed")])])
            sourceWithPages["outputItemIDs"] = .array([.string("recognized")])
            var outputWithFormat = sourceMap
            outputWithFormat["resultItemID"] = .string("recognized")
            outputWithFormat["format"] = .string("text")
            result = try ScreenshotGaoActionWriter.writeResult(inReplyTo: request.manifest, status: "completed", items: [.init(url: output, uti: "public.utf8-plain-text", id: "recognized")],
                provenance: ["requestManifestSHA256": .string(expectedDigest), "sources": .array([.object(sourceWithPages)]), "outputs": .array([.object(outputWithFormat)])], exchangeRoot: exchange, now: now)
            resultDigest = try ScreenshotFileSafety.digest(Data(contentsOf: result.appendingPathComponent("manifest.json")))
            ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
            _ = try ledger.receive(request, now: now)
            _ = try ledger.transition(requestID: binding.requestID, to: .approved, now: now)
            _ = try ledger.transition(requestID: binding.requestID, to: .executing, now: now)
            _ = try ledger.transition(requestID: binding.requestID, to: .completed, resultPackageName: result.lastPathComponent, now: now, resultManifestSHA256: resultDigest)
        }

        func ready() -> Bool { ScreenshotOCRReturn.isReady(binding, root: root, now: clock) }
        func publish(digest: String? = nil, clock: (() -> Date)? = nil) -> ScreenshotOCRReturnStatus {
            guard var record = ledger.lookup(binding.requestID) else { return .unavailable }
            if let digest { record.resultManifestSHA256 = digest }
            return ScreenshotOCRReturn.publish(record, resultURL: result, root: root, clock: clock ?? { self.clock })
        }
        func writeTicket(_ fields: [String: Any]? = nil) throws {
            try writeRawTicket(JSONSerialization.data(withJSONObject: fields ?? ticket, options: [.sortedKeys]))
        }
        func writeRawTicket(_ bytes: Data) throws {
            try bytes.write(to: ticketURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ticketURL.path)
        }
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw testFailure(message) }
    }

    private static func testFailure(_ message: String) -> ScreenshotGaoActionIssue {
        ScreenshotGaoActionContract.reject("testFailure", message)
    }
}
