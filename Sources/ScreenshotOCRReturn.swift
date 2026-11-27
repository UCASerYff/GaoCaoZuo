import Darwin
import Foundation

enum ScreenshotOCRReturnStatus: String, Codable {
    case published, unavailable, expired
}

/// The exact original envelope binds a local return ticket to the already approved request.
struct ScreenshotOCRReturnBinding: Codable, Equatable {
    let requestID: String
    let sourceBundleID: String
    let requestManifestSHA256: String
    let createdAt: String
    let expiresAt: String

    static let action = "ocr.files"
    static func recipient(_ bundleID: String) -> String? {
        switch bundleID {
        case "com.gaoseries.GaoWenJian": return "搞文件"
        case "com.academic-achievement.manager": return "搞研究"
        default: return nil
        }
    }

    init?(_ package: ScreenshotGaoValidatedPackage) {
        let request = package.manifest
        guard request.kind == "request", request.action == Self.action,
              request.targetBundleID == ScreenshotGaoActionContract.bundleID else { return nil }
        requestID = request.requestID
        sourceBundleID = request.sourceBundleID
        requestManifestSHA256 = package.manifestSHA256
        createdAt = request.createdAt
        expiresAt = request.expiresAt
        if !isValid { return nil }
    }

    var isValid: Bool {
        guard let uuid = UUID(uuidString: requestID), uuid.uuidString.caseInsensitiveCompare(requestID) == .orderedSame,
              Self.recipient(sourceBundleID) != nil, ScreenshotGaoActionContract.validSHA(requestManifestSHA256),
              let created = ScreenshotGaoActionContract.date(createdAt), let expires = ScreenshotGaoActionContract.date(expiresAt) else { return false }
        return expires > created && expires.timeIntervalSince(created) <= ScreenshotGaoActionContract.ttl
    }

    func isCurrent(at now: Date) -> Bool {
        guard let created = ScreenshotGaoActionContract.date(createdAt), let expires = ScreenshotGaoActionContract.date(expiresAt) else { return false }
        return created <= now && now < expires
    }
}

enum ScreenshotOCRReturn {
    static var userRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoAction/OcrReturns-v1", isDirectory: true)
    }

    private struct Ticket: Codable, Equatable {
        let schemaVersion: Int
        let requestID: String
        let action: String
        let sourceBundleID: String
        let targetBundleID: String
        let requestManifestSHA256: String
        let expiresAt: String

        init(_ binding: ScreenshotOCRReturnBinding) {
            schemaVersion = 1
            requestID = binding.requestID
            action = ScreenshotOCRReturnBinding.action
            sourceBundleID = binding.sourceBundleID
            targetBundleID = ScreenshotGaoActionContract.bundleID
            requestManifestSHA256 = binding.requestManifestSHA256
            expiresAt = binding.expiresAt
        }

        static func decode(_ bytes: Data) throws -> Ticket {
            guard !bytes.starts(with: [0xEF, 0xBB, 0xBF]), String(data: bytes, encoding: .utf8) != nil else { throw ScreenshotOCRReturn.unavailable() }
            try ScreenshotGaoJSONGuard.validate(bytes, integerOneKey: "schemaVersion")
            let keys: Set<String> = ["schemaVersion", "requestID", "action", "sourceBundleID", "targetBundleID", "requestManifestSHA256", "expiresAt"]
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == keys else { throw ScreenshotOCRReturn.unavailable() }
            return try JSONDecoder().decode(Ticket.self, from: bytes)
        }
    }

    static func isReady(_ binding: ScreenshotOCRReturnBinding, root: URL, now: Date = Date()) -> Bool {
        (try? withTicket(binding, root: root, clock: { now }) { _, _ in true }) ?? false
    }

    /// Retry reads the same private result bytes, fencing both the original request and the result saved in the ledger.
    static func publish(_ record: ScreenshotGaoProcessedRequest, resultURL: URL, root: URL,
                        clock: @escaping () -> Date = Date.init) -> ScreenshotOCRReturnStatus {
        guard record.kind == "request", record.action == ScreenshotOCRReturnBinding.action,
              record.phase == .completed, record.resultPackageName == resultURL.lastPathComponent,
              let binding = record.ocrReturnBinding, let resultDigest = record.resultManifestSHA256,
              binding.requestID == record.requestID, binding.sourceBundleID == record.sourceBundleID,
              binding.requestManifestSHA256 == record.manifestSHA256 else { return .unavailable }
        do {
            try withTicket(binding, root: root, clock: clock) { slot, recheck in
                let result = try ScreenshotGaoSavedPackage(resultURL)
                let manifest = result.manifest
                guard manifest.kind == "result", manifest.action == ScreenshotOCRReturnBinding.action, manifest.status == "completed",
                      manifest.sourceBundleID == ScreenshotGaoActionContract.bundleID, manifest.targetBundleID == binding.sourceBundleID,
                      manifest.inReplyTo == binding.requestID, UUID(uuidString: manifest.requestID) != UUID(uuidString: binding.requestID),
                      manifest.errorCode == nil, manifest.parameters.isEmpty, manifest.references.isEmpty, !manifest.items.isEmpty,
                      let started = ScreenshotGaoActionContract.date(binding.createdAt), let produced = ScreenshotGaoActionContract.date(manifest.createdAt), produced >= started,
                      manifest.provenance?["requestManifestSHA256"]?.stringValue == binding.requestManifestSHA256,
                      ScreenshotFileSafety.digest(result.bytes) == resultDigest else { throw unavailable() }
                try ScreenshotGaoActionContract.validate(manifest, expectedTargetBundleID: binding.sourceBundleID, now: clock())
                try result.publish(to: slot, name: "result.gaoaction", allowIdentical: true, beforeCommit: recheck)
            }
            return .published
        } catch let error as ScreenshotGaoActionIssue where error.code == "expired" { return .expired }
        catch { return .unavailable }
    }

    private static func withTicket<T>(_ binding: ScreenshotOCRReturnBinding, root: URL, clock: @escaping () -> Date,
                                      _ work: (ScreenshotGaoFixedFD, () throws -> Void) throws -> T) throws -> T {
        guard binding.isValid else { throw unavailable() }
        let name = binding.requestID.lowercased()
        func checkTime() throws {
            guard binding.isCurrent(at: clock()) else { throw ScreenshotGaoActionContract.reject("expired", "OCR 回传期限已过。") }
        }
        try checkTime()
        let parent = try mailboxDirectory(root)
        let slot = try ScreenshotGaoPrivateIO.childDirectory(parent, name, requirePrivate: true)
        let ticketName = "request.json"
        let ticket = try ScreenshotGaoPrivateIO.regular(slot, components: [ticketName])
        let ticketStat = try ticket.statValue()
        guard ticketStat.st_mode & 0o077 == 0, hasExactName(ticket, name: ticketName),
              try Ticket.decode(ScreenshotGaoPrivateIO.read(ticket, maximum: 4096)) == Ticket(binding) else { throw unavailable() }
        func recheck() throws {
            let currentParent = try mailboxDirectory(root)
            let currentSlot = try ScreenshotGaoPrivateIO.childDirectory(currentParent, name, requirePrivate: true)
            let currentTicket = try ScreenshotGaoPrivateIO.regular(currentSlot, components: [ticketName])
            guard try ScreenshotGaoSavedPackage.sameObject(parent, currentParent),
                  try ScreenshotGaoSavedPackage.sameObject(slot, currentSlot),
                  hasExactName(currentSlot, name: name), hasExactName(currentTicket, name: ticketName),
                  try ScreenshotGaoPrivateIO.unchanged(ticketStat, ticket.statValue()),
                  try ScreenshotGaoPrivateIO.unchanged(ticketStat, currentTicket.statValue()) else { throw unavailable() }
            try checkTime()
        }
        try recheck()
        return try work(slot, recheck)
    }

    private static func mailboxDirectory(_ root: URL) throws -> ScreenshotGaoFixedFD {
        let action = root.deletingLastPathComponent(), series = action.deletingLastPathComponent()
        if action.lastPathComponent == "GaoAction", series.lastPathComponent == "GaoSeries" {
            let seriesDir = try ScreenshotGaoPrivateIO.directory(series)
            let actionDir = try ScreenshotGaoPrivateIO.childDirectory(seriesDir, "GaoAction")
            guard try seriesDir.statValue().st_mode & 0o022 == 0, try actionDir.statValue().st_mode & 0o022 == 0,
                  hasExactName(seriesDir, name: "GaoSeries"), hasExactName(actionDir, name: "GaoAction") else { throw unavailable() }
            let mailbox = try ScreenshotGaoPrivateIO.childDirectory(actionDir, "OcrReturns-v1", requirePrivate: true)
            guard hasExactName(mailbox, name: "OcrReturns-v1") else { throw unavailable() }
            return mailbox
        }
        // Isolated fixtures inject their own mailbox. No caller can supply a path from a GaoAction request.
        return try ScreenshotGaoPrivateIO.directory(root, requirePrivate: true)
    }

    fileprivate static func hasExactName(_ directory: ScreenshotGaoFixedFD, name: String) -> Bool {
        // Case-insensitive APFS opens aliases; F_GETPATH returns the actual spelling of this slot.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let obtained = path.withUnsafeMutableBufferPointer { fcntl(directory.value, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }
        guard obtained == 0, let actual = String(validatingUTF8: path) else { return false }
        return URL(fileURLWithPath: actual).lastPathComponent == name
    }

    fileprivate static func unavailable() -> ScreenshotGaoActionIssue {
        ScreenshotGaoActionContract.reject("returnUnavailable", "OCR 自动回传不可用；已保存结果可手工导出。")
    }
}

/// Copy a validated, app-owned result to a new name using one directory-relative, exclusive commit.
struct ScreenshotGaoSavedPackage {
    let manifest: ScreenshotGaoActionManifest
    let bytes: Data
    private let payload: ScreenshotGaoFixedFD
    private let names: [String]

    init(_ url: URL) throws {
        let root = try ScreenshotGaoPrivateIO.directory(url, requirePrivate: true)
        bytes = try Self.readManifest(root)
        manifest = try ScreenshotGaoActionTransport.decodeManifest(bytes)
        payload = try ScreenshotGaoPrivateIO.childDirectory(root, "payload", requirePrivate: true)
        names = try manifest.items.map { item in
            let components = try ScreenshotGaoActionContract.payloadComponents(item.relativePath)
            guard components.count == 1 else { throw ScreenshotOCRReturn.unavailable() }
            return components[0]
        }
        guard Set(names).count == names.count else { throw ScreenshotOCRReturn.unavailable() }
    }

    func publish(to destination: ScreenshotGaoFixedFD, name: String, allowIdentical: Bool = false,
                 beforeCommit: () throws -> Void = {}) throws {
        var existing = stat()
        if fstatat(destination.value, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard allowIdentical else { throw ScreenshotOCRReturn.unavailable() }
            try verifyExisting(in: destination, name: name)
            try beforeCommit()
            return
        }
        guard errno == ENOENT else { throw ScreenshotOCRReturn.unavailable() }
        let temporaryName = ".gaoaction-" + UUID().uuidString.lowercased()
        let temporary = try ScreenshotGaoPrivateIO.childDirectory(destination, temporaryName, create: true, requirePrivate: true)
        var committed = false
        defer {
            if !committed, Self.stillNamed(temporary, in: destination, name: temporaryName) {
                _ = unlinkat(temporary.value, "manifest.json", 0)
                _ = unlinkat(temporary.value, "payload", AT_REMOVEDIR)
                _ = unlinkat(destination.value, temporaryName, AT_REMOVEDIR)
            }
        }
        let copy = try ScreenshotGaoPrivateIO.childDirectory(temporary, "payload", create: true, requirePrivate: true)
        defer {
            if !committed { for member in names { _ = unlinkat(copy.value, member, 0) } }
        }
        for (item, member) in zip(manifest.items, names) {
            let source = try ScreenshotGaoPrivateIO.regular(payload, components: [member])
            try ScreenshotGaoPrivateIO.copy(source, to: copy, name: member, maximum: item.byteCount, expectedSize: item.byteCount, expectedSHA256: item.sha256)
        }
        try ScreenshotGaoPrivateIO.atomicJSON(bytes, directory: temporary, name: "manifest.json")
        guard fsync(copy.value) == 0, fsync(temporary.value) == 0,
              Self.stillNamed(copy, in: temporary, name: "payload"), Self.stillNamed(temporary, in: destination, name: temporaryName) else {
            throw ScreenshotOCRReturn.unavailable()
        }
        try beforeCommit()
        if renameatx_np(destination.value, temporaryName, destination.value, name, UInt32(RENAME_EXCL)) != 0 {
            guard allowIdentical, errno == EEXIST else { throw ScreenshotOCRReturn.unavailable() }
            try verifyExisting(in: destination, name: name)
            try beforeCommit()
            return
        }
        committed = true
        guard fsync(destination.value) == 0 else { throw ScreenshotOCRReturn.unavailable() }
    }

    private func verifyExisting(in parent: ScreenshotGaoFixedFD, name: String) throws {
        let result = try ScreenshotGaoPrivateIO.childDirectory(parent, name, requirePrivate: true)
        let items = try ScreenshotGaoPrivateIO.childDirectory(result, "payload", requirePrivate: true)
        guard ScreenshotOCRReturn.hasExactName(result, name: name), try Self.readManifest(result) == bytes,
              try Self.entries(in: result, maximum: 2) == ["manifest.json", "payload"],
              try Self.entries(in: items, maximum: names.count) == Set(names) else { throw ScreenshotOCRReturn.unavailable() }
        for (item, member) in zip(manifest.items, names) {
            try ScreenshotGaoPrivateIO.verify(ScreenshotGaoPrivateIO.regular(items, components: [member]), item: item)
        }
        guard Self.stillNamed(items, in: result, name: "payload"), Self.stillNamed(result, in: parent, name: name) else { throw ScreenshotOCRReturn.unavailable() }
    }

    private static func readManifest(_ directory: ScreenshotGaoFixedFD) throws -> Data {
        try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regular(directory, components: ["manifest.json"]), maximum: Int64(ScreenshotGaoActionContract.maximumManifestBytes))
    }

    static func sameObject(_ lhs: ScreenshotGaoFixedFD, _ rhs: ScreenshotGaoFixedFD) throws -> Bool {
        let a = try lhs.statValue(), b = try rhs.statValue()
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func stillNamed(_ directory: ScreenshotGaoFixedFD, in parent: ScreenshotGaoFixedFD, name: String) -> Bool {
        var current = stat()
        guard let opened = try? directory.statValue(), fstatat(parent.value, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return current.st_mode & S_IFMT == S_IFDIR && current.st_dev == opened.st_dev && current.st_ino == opened.st_ino
    }

    private static func entries(in directory: ScreenshotGaoFixedFD, maximum: Int) throws -> Set<String> {
        let fd = openat(directory.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotOCRReturn.unavailable() }
        guard let stream = fdopendir(fd) else { close(fd); throw ScreenshotOCRReturn.unavailable() }
        defer { closedir(stream) }
        var names = Set<String>()
        while true {
            errno = 0
            guard let member = readdir(stream) else {
                guard errno == 0 else { throw ScreenshotOCRReturn.unavailable() }
                return names
            }
            let count = Int(member.pointee.d_namlen)
            let name = withUnsafeBytes(of: &member.pointee.d_name) { String(bytes: $0.prefix(count), encoding: .utf8) }
            guard let name else { throw ScreenshotOCRReturn.unavailable() }
            guard name != ".", name != ".." else { continue }
            guard names.insert(name).inserted, names.count <= maximum else { throw ScreenshotOCRReturn.unavailable() }
        }
    }
}
