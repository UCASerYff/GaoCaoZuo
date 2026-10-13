import Foundation
import Darwin

private final class ArchiveIOTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var mainThread = false
    private var timedOut = false
    func block() {
        lock.lock(); mainThread = Thread.isMainThread; lock.unlock()
        entered.signal()
        // A test failure must not deadlock the test runner's main thread forever.
        let timeout = release.wait(timeout: .now() + 5) != .success
        lock.lock(); timedOut = timeout; lock.unlock()
    }
    func waitUntilEntered() async -> Bool {
        await Task.detached { self.waitForEntry() }.value
    }
    private func waitForEntry() -> Bool { entered.wait(timeout: .now() + 6) == .success }
    func open() { release.signal() }
    var safelyBlockedOffMain: Bool {
        lock.lock(); defer { lock.unlock() }; return !mainThread && !timedOut
    }
}

/// Only isolated temporary files and the actual bundled archive engine are used.
/// Blocking hooks model consent/storage waits without touching TCC or the real Trash.
@MainActor func runArchiveFileIOTests(engine: URL) async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/GaoArchiveIO-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"), bytes = Data("isolated archive I/O fixture\n".utf8)
    try bytes.write(to: source, options: .withoutOverwriting)
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw DataFailure.message("Archive I/O regression: " + label) }; checks += 1
    }
    func expectCancelled<T>(_ task: Task<T, Error>) async throws {
        do { _ = try await task.value } catch ArchiveError.cancelled { checks += 1; return }
        throw DataFailure.message("Archive I/O regression: pending work must report cancellation")
    }
    func noStageRemains() throws -> Bool {
        try !fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".gaocaozuo-stage-") }
    }

    // The controller's planning/aftercare primitive keeps its execution slot
    // occupied until the blocked worker acknowledges cancellation.
    do {
        let gate = ArchiveIOTestGate(), service = ArchiveService(engineURL: engine)
        let marker = root.appendingPathComponent("must-not-write")
        let job = Task { try await service.performFileIO { cancellation in
            gate.block(); try cancellation.check(); try bytes.write(to: marker, options: .withoutOverwriting)
        } }
        let entered = await gate.waitUntilEntered()
        try expect(entered, "planning worker entered")
        try expect(gate.safelyBlockedOffMain && service.isRunning, "main actor is responsive while planning is blocked")
        service.cancel()
        try expect(service.isRunning, "cancelling cannot release a still-blocked worker")
        do {
            _ = try await service.create(items: [source], destination: root.appendingPathComponent("queued.zip"), format: .zip, password: nil, splitMB: nil, solid: false)
            throw DataFailure.message("second writer started while old worker was blocked")
        } catch ArchiveError.invalid { checks += 1 }
        gate.open(); try await expectCancelled(job)
        try expect(!service.isRunning && !fm.fileExists(atPath: marker.path), "cancelled plan writes nothing and then releases execution slot")
    }
    for phase in [ArchiveCreationIO.Phase.preparing, .publishing] {
        let gate = ArchiveIOTestGate()
        let service = ArchiveService(engineURL: engine, creationIOObserver: { if $0 == phase { gate.block() } })
        let destination = root.appendingPathComponent(phase == .preparing ? "cancel-before-copy.zip" : "cancel-before-publish.zip")
        let job = Task { try await service.create(items: [source], destination: destination, format: .zip, password: nil, splitMB: nil, solid: false) }
        let entered = await gate.waitUntilEntered()
        try expect(entered, "creation worker reached blocked phase")
        try expect(gate.safelyBlockedOffMain && service.isRunning, "main actor can cancel a blocked preparation/publication phase")
        service.cancel(); try expect(service.isRunning, "busy state remains until creation worker finishes")
        gate.open(); try await expectCancelled(job)
        try expect(!fm.fileExists(atPath: destination.path) && service.lastResultReceipts.isEmpty,
                   "cancelled phase never publishes an output or false receipt")
        try expect(try Data(contentsOf: source) == bytes && noStageRemains(), "cancelled creation preserves source and removes only its private stage")
    }

    let service = ArchiveService(engineURL: engine)
    for format in ArchiveFormat.allCases {
        let destination = root.appendingPathComponent("success." + format.rawValue)
        let result = try await service.create(items: [source], destination: destination, format: format, password: nil, splitMB: nil, solid: false)
        try expect(result == destination && service.lastResultReceipts.count == 1, "real engine publishes a receipt for " + format.rawValue)
        try expect(try FileTools.fingerprint(result) == service.lastResultReceipts[0].fingerprint, "published result matches precomputed receipt")
        let listing = try await service.list(archive: result, password: nil)
        try expect(listing.contains { $0.path == source.lastPathComponent && $0.size == UInt64(bytes.count) }, "real engine result contains source bytes")
    }
    // A denied path is an error, never an absent output. The test runner must be
    // an ordinary user for a chmod-based filesystem denial to be meaningful.
    if getuid() != 0 {
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try fm.createDirectory(at: denied, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        do {
            _ = try await service.create(items: [source], destination: denied.appendingPathComponent("out.zip"), format: .zip, password: nil, splitMB: nil, solid: false)
            throw DataFailure.message("denied output was treated as absent")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code)) { checks += 1 }
        try expect(service.lastResultReceipts.isEmpty, "denied path produces no receipt")
    }
    let collision = root.appendingPathComponent("collision.zip"), sentinel = Data("existing original".utf8)
    try sentinel.write(to: collision, options: .withoutOverwriting)
    do {
        _ = try await service.create(items: [source], destination: collision, format: .zip, password: nil, splitMB: nil, solid: false)
        throw DataFailure.message("existing output was overwritten")
    } catch FileToolsError.conflict { checks += 1 }
    try expect(try Data(contentsOf: collision) == sentinel && noStageRemains(), "collision preserves existing bytes and leaves no stage")

    // A name appearing between preflight and publication restores earlier moves.
    let stage = root.appendingPathComponent("rollback-stage"), output = root.appendingPathComponent("rollback-output")
    try fm.createDirectory(at: stage, withIntermediateDirectories: false); try fm.createDirectory(at: output, withIntermediateDirectories: false)
    let volumes = [stage.appendingPathComponent("a"), stage.appendingPathComponent("b")]
    for volume in volumes { try bytes.write(to: volume) }
    let targets = volumes.map { output.appendingPathComponent($0.lastPathComponent) }
    let receipts = try zip(volumes, targets).map { FileOperationReceipt(kind: .create, destination: $1, fingerprint: try FileTools.fingerprint($0)) }
    try sentinel.write(to: targets[1])
    do {
        try await ArchiveFileIO.perform { try ArchiveFileIO.moveExclusively(volumes[1], to: targets[1]) }
        throw DataFailure.message("exclusive rename replaced an existing target")
    } catch FileToolsError.conflict { checks += 1 }
    try expect(try Data(contentsOf: targets[1]) == sentinel && Data(contentsOf: volumes[1]) == bytes, "atomic exclusive rename preserves both raced names")
    do {
        try await ArchiveFileIO.perform { try ArchiveCreationIO.publish(volumes: volumes, targets: targets, receipts: receipts, cancellation: .init(deadline: .distantFuture)) }
        throw DataFailure.message("late collision was overwritten")
    } catch FileToolsError.conflict { checks += 1 }
    try expect(try Data(contentsOf: targets[1]) == sentinel && !fm.fileExists(atPath: targets[0].path), "publication rollback does not overwrite a raced destination")
    try expect(try volumes.allSatisfy { try Data(contentsOf: $0) == bytes }, "publication rollback returns every moved private volume")

    // Cancel after the first simulated disposal: restore it before returning.
    let originals = [root.appendingPathComponent("original-a"), root.appendingPathComponent("original-b")]
    for original in originals { try bytes.write(to: original) }
    let pairs = try originals.map { ($0, try FileTools.fingerprint($0)) }
    let cancellation = ArchiveCreationIO.Cancellation(deadline: .distantFuture)
    do {
        try await ArchiveFileIO.perform {
            try ArchiveEnhancementController.trashUnchanged(pairs, checkCancellation: { try cancellation.check() }) { original in
                let held = stage.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.moveItem(at: original, to: held); cancellation.cancel(); return held
            }
        }
        throw DataFailure.message("disposal ignored cancellation")
    } catch ArchiveError.invalid { checks += 1 }
    try expect(try originals.allSatisfy { try Data(contentsOf: $0) == bytes }, "cancelled disposal restores all isolated originals")
    // No following iteration exists for the final item: cancellation must still
    // trigger restoration, and a replacement at the original path must survive.
    for pathOccupied in [false, true] {
        let original = root.appendingPathComponent(pathOccupied ? "last-occupied" : "last-cancelled")
        try bytes.write(to: original)
        let pair = [(original, try FileTools.fingerprint(original))]
        let cancellation = ArchiveCreationIO.Cancellation(deadline: .distantFuture)
        let held = stage.appendingPathComponent(original.lastPathComponent)
        do {
            try await ArchiveFileIO.perform {
                try ArchiveEnhancementController.trashUnchanged(pair, checkCancellation: { try cancellation.check() }) { original in
                    try FileManager.default.moveItem(at: original, to: held)
                    if pathOccupied { try sentinel.write(to: original, options: .withoutOverwriting) }
                    cancellation.cancel(); return held
                }
            }
            throw DataFailure.message("last-item disposal ignored cancellation")
        } catch ArchiveError.invalid { checks += 1 }
        if pathOccupied {
            try expect(try Data(contentsOf: original) == sentinel && Data(contentsOf: held) == bytes,
                       "restore never overwrites a newly occupied original path; held original stays recoverable")
        } else {
            try expect(try Data(contentsOf: original) == bytes && !fm.fileExists(atPath: held.path),
                       "single/final-item cancellation restores the original before completion")
        }
    }
    print("PASS: \(checks) archive background I/O/cancellation checks; no TCC, real Trash or GUI touched")
}
