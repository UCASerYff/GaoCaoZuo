import Foundation
import Darwin

private final class ArchiveFIFOProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    func record(_ value: Bool) { lock.lock(); rejected = value; lock.unlock() }
    func value() -> Bool { lock.lock(); defer { lock.unlock() }; return rejected }
}

private func runArchiveSnapshotFIFOTests(in root: URL) async throws {
    for suffix in ["zip", "7z"] {
        let source = root.appendingPathComponent("not-a-regular-file." + suffix)
        guard mkfifo(source.path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let timelyRejection: Bool = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            let finished = DispatchSemaphore(value: 0), result = ArchiveFIFOProbeResult()
            DispatchQueue.global(qos: .utility).async {
                defer { finished.signal() }
                do {
                    _ = try ArchiveBatchSnapshot.capture(source, in: root.appendingPathComponent("fifo-copy-" + suffix), maximumBytes: 1_024,
                                                        cancellation: .init(deadline: Date().addingTimeInterval(30)))
                } catch ArchiveError.invalid { result.record(true) }
                catch { }
            }
            if finished.wait(timeout: .now() + 1) == .success { continuation.resume(returning: result.value()); return }
            // A regression must fail promptly instead of leaving the test
            // worker stuck in FIFO open. Only this fresh synthetic FIFO gets a
            // temporary nonblocking writer; all waits stay off MainActor.
            let rescue = open(source.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if rescue >= 0 { defer { close(rescue) }; _ = finished.wait(timeout: .now() + 2) }
            continuation.resume(returning: false)
          }
        }
        guard timelyRejection, !FileManager.default.fileExists(atPath: root.appendingPathComponent("fifo-copy-" + suffix).path) else {
            throw NSError(domain: "ArchiveFIFOTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "FIFO archive source was not rejected within the bounded worker deadline"])
        }
    }
    print("Archive snapshot FIFO rejection passed (zip/7z, bounded worker, no MainActor blocking)")
}

func runArchiveStageCleanupTests() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("GaoArchiveCleanup-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    try await runArchiveSnapshotFIFOTests(in: root)
    let outside = root.appendingPathComponent("outside"), stage = root.appendingPathComponent(".gaocaozuo-stage-" + UUID().uuidString)
    let first = stage.appendingPathComponent("readonly"), nested = first.appendingPathComponent("no-access")
    try fm.createDirectory(at: outside, withIntermediateDirectories: false)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let sentinel = Data("preserved outside content".utf8), original = outside.appendingPathComponent("original")
    try sentinel.write(to: original); try sentinel.write(to: nested.appendingPathComponent("copy"))
    try fm.createSymbolicLink(at: stage.appendingPathComponent("symbolic"), withDestinationURL: outside)
    guard link(original.path, stage.appendingPathComponent("hard").path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: first.path)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stage.path)
    let warning = await ArchiveFileIO.removeStage(stage)
    guard warning == nil, !fm.fileExists(atPath: stage.path), try Data(contentsOf: original) == sentinel else {
        // Only exact generated directories are repaired after a failed test.
        for directory in [stage, first, nested] { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        throw NSError(domain: "ArchiveCleanupTests", code: 1, userInfo: [NSLocalizedDescriptionKey: warning ?? "owned readonly cleanup failed"])
    }
    let wrongScope = await ArchiveFileIO.removeStage(outside)
    guard wrongScope != nil, try Data(contentsOf: original) == sentinel else { throw NSError(domain: "ArchiveCleanupTests", code: 2) }
    let alias = root.appendingPathComponent(".gaocaozuo-stage-" + UUID().uuidString)
    try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
    let aliased = await ArchiveFileIO.removeStage(alias)
    guard aliased != nil, try Data(contentsOf: original) == sentinel else { throw NSError(domain: "ArchiveCleanupTests", code: 3) }
    print("Archive private staging cleanup passed (readonly/no-access/link/scope checks)")
}

/// Targeted production-engine integration. Only generated temporary documents;
/// no App activation, event tap, browser, or window is created.
@MainActor func runArchiveBatchIntegrationTests(engine: URL) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoArchiveBatchIntegration-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
        // Only generated test copies are made removable. The source and all
        // outputs live beneath this fresh UUID directory.
        if let children = try? ArchiveMacMetadata.allURLs(in: root) {
            for path in children where (try? fm.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeDirectory {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
        }
        try? fm.removeItem(at: root)
    }
    var checks = 0
    func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: "ArchiveBatchIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks += 1
    }
    func rejected(_ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { checks += 1; return }
        throw NSError(domain: "ArchiveBatchIntegration", code: 2, userInfo: [NSLocalizedDescriptionKey: label])
    }
    func attribute(_ url: URL, _ name: String) throws -> Data {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count >= 0, count < 65_536 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var bytes = [UInt8](repeating: 0, count: count)
        guard getxattr(url.path, name, &bytes, count, 0, XATTR_NOFOLLOW) == count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Data(bytes)
    }
    let input = root.appendingPathComponent("input"), nested = input.appendingPathComponent("目录 ' 空格")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    var originals: [String: Data] = [:]
    for index in 0..<32 {
        let name = "目录 ' 空格/\(index).txt", bytes = Data(("original generated row \(index)\n" + String(repeating: "content\n", count: 128)).utf8)
        originals[name] = bytes; try bytes.write(to: input.appendingPathComponent(name))
    }
    originals["empty"] = Data(); try Data().write(to: input.appendingPathComponent("empty"))
    let executable = input.appendingPathComponent("run.sh"), executableBytes = Data("#!/bin/sh\nexit 0\n".utf8)
    originals["run.sh"] = executableBytes; try executableBytes.write(to: executable)
    let metadata = Data("original custom attribute".utf8), fork = Data("original synthetic resource fork".utf8)
    for (name, value) in [("com.gaoseries.archive-fixture", metadata), ("com.apple.ResourceFork", fork)] {
        let code = value.withUnsafeBytes { setxattr(executable.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    try fm.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: 1_760_000_000)], ofItemAtPath: executable.path)
    let originalDigest = try FileTools.archiveFingerprint(input)
    let service = ArchiveService(engineURL: engine)
    for (format, solid, secret) in [(ArchiveFormat.zip, false, nil as String?), (.zip, false, "原创fixture-中文"), (.sevenZip, false, nil), (.sevenZip, true, nil), (.sevenZip, true, "原创fixture-中文")] {
        let label = UUID().uuidString
        let archive = root.appendingPathComponent(label + "." + format.rawValue)
        _ = try await service.create(items: [input], destination: archive, format: format, password: secret, splitMB: nil, solid: solid)
        let archiveDigest = try FileTools.sha256(archive), output = root.appendingPathComponent(label + "-out")
        _ = try await service.extract(archive: archive, to: output, password: secret, selected: nil)
        let tree = output.appendingPathComponent("input")
        for (name, bytes) in originals { try expect(try Data(contentsOf: tree.appendingPathComponent(name)) == bytes, "full extraction byte exact: " + name) }
        let restored = tree.appendingPathComponent("run.sh")
        try expect(try attribute(restored, "com.gaoseries.archive-fixture") == metadata, "custom xattr round trip")
        try expect(try attribute(restored, "com.apple.ResourceFork") == fork, "resource fork round trip")
        try expect((try fm.attributesOfItem(atPath: restored.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755, "executable mode round trip")
        try expect(abs((try fm.attributesOfItem(atPath: restored.path)[.modificationDate] as! Date).timeIntervalSince1970 - 1_760_000_000) <= 2, "modification time round trip")
        try expect(try service.lastResultReceipts.count == 1 && service.lastResultReceipts[0].fingerprint == FileTools.archiveFingerprint(output), "recovery receipt matches published content")
        let selected = root.appendingPathComponent(label + "-selected")
        _ = try await service.extract(archive: archive, to: selected, password: secret, selected: ["input/目录 ' 空格/31.txt"])
        try expect(try Data(contentsOf: selected.appendingPathComponent("input/目录 ' 空格/31.txt")) == originals["目录 ' 空格/31.txt"], "selected member exact")
        try expect(!fm.fileExists(atPath: selected.appendingPathComponent("input/run.sh").path), "selection does not extract unrelated members")
        let directory = root.appendingPathComponent(label + "-directory"); try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let targets = try await service.extractIntoDirectory(archive: archive, to: directory, password: secret)
        try expect(targets.map(\.path) == [directory.appendingPathComponent("input").path], "direct extraction returns actual published top-level result")
        try expect(try service.lastResultReceipts.count == 1 && service.lastResultReceipts[0].fingerprint == FileTools.archiveFingerprint(targets[0]), "top-level receipt computed for actual final object")
        try expect(!service.isRunning, "transaction releases busy state after publication/cleanup")
        try await rejected("existing top-level conflict must refuse") { _ = try await service.extractIntoDirectory(archive: archive, to: directory, password: secret) }
        try expect(try Data(contentsOf: directory.appendingPathComponent("input/run.sh")) == executableBytes, "conflict keeps existing output bytes")
        if secret != nil {
            let denied = root.appendingPathComponent(label + "-wrong")
            try await rejected("wrong password must refuse") { _ = try await service.extract(archive: archive, to: denied, password: "wrong-fixture", selected: nil) }
            try expect(!fm.fileExists(atPath: denied.path) && service.lastResultReceipts.isEmpty, "wrong password publishes neither output nor receipt")
        }
        try expect(try FileTools.sha256(archive) == archiveDigest, "original archive unchanged")
    }
    let cancellable = root.appendingPathComponent("cancel.zip")
    _ = try await service.create(items: [input], destination: cancellable, format: .zip, password: nil, splitMB: nil, solid: false)
    let cancelledOutput = root.appendingPathComponent("cancelled-output"), beforeCancel = try FileTools.sha256(cancellable)
    let job = Task { try await service.extract(archive: cancellable, to: cancelledOutput, password: nil, selected: nil) }
    try await Task.sleep(nanoseconds: 10_000_000); service.cancel()
    do { _ = try await job.value; throw NSError(domain: "ArchiveBatchIntegration", code: 3) } catch ArchiveError.cancelled { checks += 1 }
    try expect(!fm.fileExists(atPath: cancelledOutput.path) && service.lastResultReceipts.isEmpty && !service.isRunning, "cancelled transaction is drained before releasing state")
    try expect(try FileTools.sha256(cancellable) == beforeCancel && FileTools.archiveFingerprint(input) == originalDigest, "cancellation preserves all generated originals")
    try expect(try !fm.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".gaocaozuo-stage-") || $0.hasPrefix(".gaocaozuo-expand-") }), "success/error/cancel leave no staging trees")
    print("Archive batch production integration passed (\(checks) checks)")
}
