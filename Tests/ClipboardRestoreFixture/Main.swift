import Foundation
import AppKit
import CryptoKit
import Darwin

// Standalone, deliberately opt-in CLI for this round's public clipboard fixture.
// prepare destroys the old clipboard WITHOUT reading it. verify never writes it.
// Neither phase restores unknown data, starts an app, or creates an NSApplication.
private enum Refusal: String, Error {
    case usage, root, directoryChanged, publicFile, existingManifest, io
    case manifest, writeClipboard, clipboardChanged, itemCount, types, sentinel, bytes
}

private struct TypeFingerprint: Codable, Equatable {
    let type: String
    let byteCount: Int
    let sha256: String
}
private struct ItemFingerprint: Codable, Equatable {
    let index: Int
    let types: [TypeFingerprint]
}
private struct BoardFingerprint: Codable, Equatable {
    let changeCount: Int
    let items: [ItemFingerprint]
}
private struct FixtureManifest: Codable {
    let format: String
    let receiptID: String
    let seedID: String
    let itemIDs: [String]
    let rootPath: String
    let publicFileName: String
    let publicFileByteCount: Int
    let publicFileSHA256: String
    let board: BoardFingerprint
}
private struct VerificationReceipt: Codable {
    let format: String
    let receiptID: String
    let fixtureReceiptID: String
    let seedID: String
    let matched: Bool
    let changeCountChangedSincePrepare: Bool
    let board: BoardFingerprint
}

private let manifestName = "clipboard-restore-fixture-manifest.json"
private let fixtureFormat = "gaocaozuo.public-clipboard-restore-fixture.v1"
private let publicFileName = "Public attachment [a] $ ;.txt"
private let publicFileByteCount = 47
private let publicFileSHA256 = "5edde30d71303e1cdf399d8b6a0cac748d2fbc4c123d70e612e34834f5f25815"
private let sentinelType = "com.gaoseries.gaocaozuo.clipboard-restore-fixture"

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}
private func sameIdentity(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino
}
private func sameFile(_ a: stat, _ b: stat) -> Bool {
    sameIdentity(a, b) && a.st_size == b.st_size && a.st_uid == b.st_uid
        && a.st_mode == b.st_mode && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
        && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
        && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
        && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}
private func requireDirectory(_ fd: Int32) throws -> stat {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { throw Refusal.root }
    return info
}

private final class FixtureRoot {
    let path: String
    let parentFD: Int32
    let rootFD: Int32
    let inputsFD: Int32
    let outputsFD: Int32
    private let name: String
    private let rootInfo: stat
    private let inputsInfo: stat
    private let outputsInfo: stat

    init(_ argument: String) throws {
        // Foundation may standardize the system /private/tmp alias to /tmp.
        // Validate the exact caller spelling instead; all access stays anchored
        // to the fixed no-follow /private/tmp descriptor below.
        let name = (argument as NSString).lastPathComponent
        guard getuid() != 0, geteuid() == getuid(), argument == "/private/tmp/" + name,
              name.range(of: "^gaocaozuo-acceptance-[A-Za-z0-9-]+\\.noindex$", options: .regularExpression) != nil else { throw Refusal.root }
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Refusal.root }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { close(parent); throw Refusal.root }
        var inputs: Int32 = -1, outputs: Int32 = -1
        do {
            let original = try requireDirectory(root)
            inputs = openat(root, "Inputs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            outputs = openat(root, "Outputs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard inputs >= 0, outputs >= 0 else { throw Refusal.root }
            let inputInfo = try requireDirectory(inputs), outputInfo = try requireDirectory(outputs)
            self.path = argument; self.name = name
            parentFD = parent; rootFD = root; inputsFD = inputs; outputsFD = outputs
            rootInfo = original; inputsInfo = inputInfo; outputsInfo = outputInfo
        } catch {
            if outputs >= 0 { close(outputs) }; if inputs >= 0 { close(inputs) }
            close(root); close(parent); throw error
        }
        try validate()
    }
    deinit { close(outputsFD); close(inputsFD); close(rootFD); close(parentFD) }

    func validate() throws {
        for (parent, child, fd, expected) in [(parentFD, name, rootFD, rootInfo),
                                            (rootFD, "Inputs", inputsFD, inputsInfo),
                                            (rootFD, "Outputs", outputsFD, outputsInfo)] {
            var named = stat()
            guard fstatat(parent, child, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFDIR, sameIdentity(named, expected),
                  sameIdentity(try requireDirectory(fd), expected) else { throw Refusal.directoryChanged }
        }
    }
    func readOwnedFile(parent: Int32, name: String, limit: Int, exactPrivateMode: Bool = false) throws -> Data {
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw Refusal.io }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Refusal.io }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= Int64(limit),
              !exactPrivateMode || before.st_mode & 0o7777 == 0o600 else { throw Refusal.io }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= limit - data.count else { throw Refusal.io }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, sameFile(before, after), Int64(data.count) == before.st_size,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(before, named) else { throw Refusal.io }
        return data
    }
    func requirePublicFile() throws -> URL {
        try validate()
        let data = try readOwnedFile(parent: inputsFD, name: publicFileName, limit: publicFileByteCount)
        guard data.count == publicFileByteCount, digest(data) == publicFileSHA256 else { throw Refusal.publicFile }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Inputs", isDirectory: true).appendingPathComponent(publicFileName)
    }
    func requireNoManifest() throws {
        var info = stat()
        guard fstatat(outputsFD, manifestName, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Refusal.existingManifest }
    }
    func writeNew(_ data: Data, name: String) throws {
        guard !name.contains("/"), !name.contains("\\") else { throw Refusal.io }
        try validate()
        let temporary = ".clipboard-fixture-" + UUID().uuidString + ".tmp"
        let fd = openat(outputsFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal.io }
        defer { close(fd); unlinkat(outputsFD, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw Refusal.io }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Refusal.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Refusal.io }
        try validate()
        guard renameatx_np(outputsFD, temporary, outputsFD, name, UInt32(RENAME_EXCL)) == 0,
              fsync(outputsFD) == 0 else { throw Refusal.io }
    }
}

private func knownFixture(seedID: String, receiptID: String, itemIDs: [String], fileURL: URL) throws -> [[String: Data]] {
    let identifiers = [seedID, receiptID] + itemIDs
    guard itemIDs.count == 3, Set(identifiers).count == 5,
          identifiers.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }) else { throw Refusal.manifest }
    func marker(_ index: Int) -> Data {
        Data((fixtureFormat + ";seed=" + seedID + ";receipt=" + receiptID + ";item=" + itemIDs[index]).utf8)
    }
    // Fixed bytes, not NSImage/NSAttributedString/NSURL pasteboard writers.
    guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADO0J6QAAAAC0lEQVQIHWNgQAcAABIAAYAUyswAAAAASUVORK5CYII=") else { throw Refusal.manifest }
    let text = "Public clipboard restore fixture " + seedID + " item " + itemIDs[0] + "\n"
    // AppKit exposes this standard external UTF-16 flavor for the RTF item.
    // Supply known bytes explicitly instead of ignoring an extra representation.
    var utf16 = Data([0xff, 0xfe])
    for unit in text.utf16 { utf16.append(UInt8(truncatingIfNeeded: unit)); utf16.append(UInt8(unit >> 8)) }
    let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 Public clipboard restore fixture \\b " + itemIDs[0] + "\\b0\\par seed " + seedID + "}"
    return [
        ["public.utf8-plain-text": Data(text.utf8), "public.utf16-external-plain-text": utf16, "public.rtf": Data(rtf.utf8), sentinelType: marker(0)],
        ["public.png": png, "public.utf8-plain-text": Data(("Public PNG fixture " + itemIDs[1]).utf8), sentinelType: marker(1)],
        ["public.file-url": Data(fileURL.absoluteString.utf8), "public.utf8-plain-text": Data(("Public file URL fixture " + itemIDs[2]).utf8), sentinelType: marker(2)]
    ]
}
private func fingerprint(_ expected: [[String: Data]], changeCount: Int) -> BoardFingerprint {
    BoardFingerprint(changeCount: changeCount, items: expected.enumerated().map { index, formats in
        ItemFingerprint(index: index, types: formats.keys.sorted().map {
            TypeFingerprint(type: $0, byteCount: formats[$0]!.count, sha256: digest(formats[$0]!))
        })
    })
}

// Only call after the seed has been written, or after validating its manifest.
// Check our private sentinel on every item before reading ordinary formats.
// A changed board fails closed; raw clipboard data is never printed or saved.
private func readKnownBoard(_ board: NSPasteboard, expected: [[String: Data]]) throws -> BoardFingerprint {
    let before = board.changeCount
    guard let items = board.pasteboardItems, items.count == expected.count else { throw Refusal.itemCount }
    for (index, item) in items.enumerated() {
        let names = item.types.map(\.rawValue)
        guard Set(names).count == names.count, names.sorted() == expected[index].keys.sorted() else { throw Refusal.types }
        guard item.data(forType: NSPasteboard.PasteboardType(sentinelType)) == expected[index][sentinelType],
              board.changeCount == before else { throw Refusal.sentinel }
    }
    var actual: [[String: Data]] = []
    for (index, item) in items.enumerated() {
        var formats: [String: Data] = [:]
        for name in expected[index].keys.sorted() {
            guard board.changeCount == before,
                  let data = item.data(forType: NSPasteboard.PasteboardType(name)),
                  data == expected[index][name] else { throw Refusal.bytes }
            formats[name] = data
        }
        actual.append(formats)
    }
    guard board.changeCount == before else { throw Refusal.clipboardChanged }
    return fingerprint(actual, changeCount: before)
}

@MainActor private func prepare(_ root: FixtureRoot) throws {
    let fileURL = try root.requirePublicFile()
    try root.requireNoManifest()
    let receiptID = UUID().uuidString, seedID = UUID().uuidString
    let itemIDs = (0..<3).map { _ in UUID().uuidString }
    let expected = try knownFixture(seedID: seedID, receiptID: receiptID, itemIDs: itemIDs, fileURL: fileURL)
    let items = try expected.map { formats -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for name in formats.keys.sorted() {
            guard item.setData(formats[name]!, forType: NSPasteboard.PasteboardType(name)) else { throw Refusal.writeClipboard }
        }
        return item
    }
    try root.validate()
    let board = NSPasteboard.general
    // First interaction with the general board is destructive ownership change.
    // Do not inspect changeCount, types, items, strings, or old bytes beforehand.
    board.clearContents()
    guard board.writeObjects(items) else { throw Refusal.writeClipboard }
    let observed = try readKnownBoard(board, expected: expected)
    let manifest = FixtureManifest(format: fixtureFormat, receiptID: receiptID, seedID: seedID,
        itemIDs: itemIDs, rootPath: root.path, publicFileName: publicFileName,
        publicFileByteCount: publicFileByteCount, publicFileSHA256: publicFileSHA256, board: observed)
    try root.writeNew(encoded(manifest), name: manifestName)
    print("prepared: 3 public fixture items; hashes and changeCount recorded in Outputs/" + manifestName)
}

@MainActor private func verify(_ root: FixtureRoot) throws {
    let fileURL = try root.requirePublicFile()
    let raw = try root.readOwnedFile(parent: root.outputsFD, name: manifestName, limit: 64 * 1024, exactPrivateMode: true)
    let manifest = try JSONDecoder().decode(FixtureManifest.self, from: raw)
    guard manifest.format == fixtureFormat, manifest.rootPath == root.path,
          manifest.publicFileName == publicFileName, manifest.publicFileByteCount == publicFileByteCount,
          manifest.publicFileSHA256 == publicFileSHA256, manifest.board.changeCount >= 0,
          try encoded(manifest) == raw else { throw Refusal.manifest }
    let expected = try knownFixture(seedID: manifest.seedID, receiptID: manifest.receiptID,
                                    itemIDs: manifest.itemIDs, fileURL: fileURL)
    guard fingerprint(expected, changeCount: manifest.board.changeCount) == manifest.board else { throw Refusal.manifest }
    try root.validate()
    // The manifest is now proven to describe exactly our code-defined fixture.
    // No general clipboard access occurs in verify before all these guards.
    let observed = try readKnownBoard(NSPasteboard.general, expected: expected)
    let receiptID = UUID().uuidString
    let receipt = VerificationReceipt(format: fixtureFormat + ".verification", receiptID: receiptID,
        fixtureReceiptID: manifest.receiptID, seedID: manifest.seedID, matched: true,
        changeCountChangedSincePrepare: observed.changeCount != manifest.board.changeCount, board: observed)
    let name = "clipboard-restore-fixture-verification-" + receiptID + ".json"
    try root.writeNew(encoded(receipt), name: name)
    print("verified: all item order, exact type sets and bytes match; hash-only receipt in Outputs/" + name)
}

@main private enum ClipboardRestoreFixtureMain {
    @MainActor static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, ["prepare", "verify"].contains(arguments[1]) else { throw Refusal.usage }
            let root = try FixtureRoot(arguments[2])
            if arguments[1] == "prepare" { try prepare(root) } else { try verify(root) }
        } catch {
            let code = (error as? Refusal)?.rawValue ?? "invalidFixture"
            FileHandle.standardError.write(Data(("clipboard fixture refused: " + code + "; no unknown clipboard restoration attempted\n").utf8))
            exit(1)
        }
    }
}
