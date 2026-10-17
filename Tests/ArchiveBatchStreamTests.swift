import Foundation
import Darwin

/// Pure framing/FD and job-local source tests. No App, event tap, or GUI launch.
func runArchiveBatchStreamTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoArchiveBatch-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "ArchiveBatchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; checks += 1
    }
    func frame(_ index: UInt32, _ size: UInt64, _ bytes: Data = Data()) -> Data {
        var i = index.bigEndian, n = size.bigEndian
        return withUnsafeBytes(of: &i) { Data($0) } + withUnsafeBytes(of: &n) { Data($0) } + bytes
    }
    let done = frame(UInt32.max, 0)
    for method in ["Copy", "LZMA2:24", "LZMA2:24m", "LZMA2:256m", "LZMA2:32768k"] {
        try expect(ArchiveService.nativeBatchMethodSupported(method), "known bounded native method: " + method)
    }
    for method in ["", "LZMA2:", "LZMA2:29", "LZMA2:257m", "LZMA2:999999999999999999999m", "LZMA2:24m BCJ", "Deflate", "LZMA2:-1m"] {
        try expect(!ArchiveService.nativeBatchMethodSupported(method), "unverified native method stays on existing backend: " + method)
    }
    do {
        let base = "2026-10-15 12:34:56", raw = base + ".123456789"
        let listing = (0..<1000).map { "Path = date-\($0)\nSize = 0\nModified = \(raw)\n\n" }.joined()
        let entries = try ArchiveService.parseListing(listing)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.isLenient = false
        let expected = formatter.date(from: base)!.addingTimeInterval(0.123456789)
        try expect(entries.count == 1000 && entries.allSatisfy { $0.modifiedAt == expected }, "per-job date parser preserves repeated fractional timestamps")
        let invalid = try ArchiveService.parseListing("Path = bad-date\nSize = 0\nModified = 2026-02-30 12:34:56\n\n")
        try expect(invalid[0].modifiedAt == nil, "invalid timestamp is not invented by date cache")
        let missing = try ArchiveService.parseListing("Path = missing-date\nSize = 0\n\n")
        try expect(missing[0].modifiedAt == nil, "missing timestamp remains unknown")
    }
    func directory() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    let entry = ArchiveEntry(path: "子目录/a 'x'.txt", size: 3, isDirectory: false)
    do {
        let output = try directory(), writer = try ArchiveBatchStream(root: output, entries: [entry, .init(path: "empty", size: 0, isDirectory: false)])
        let stream = frame(1, 0) + frame(0, 3, Data("abc".utf8)) + done
        for byte in stream { writer.append(Data([byte])) }
        try writer.finish()
        try expect(try Data(contentsOf: output.appendingPathComponent(entry.path)) == Data("abc".utf8), "fragmented frames preserve exact bytes")
        try expect(try Data(contentsOf: output.appendingPathComponent("empty")).isEmpty, "empty file is represented")
        try expect(writer.completedCount == 2, "actual completed count")
    }
    let attacks: [(String, Data)] = [
        ("bad index", frame(1, 3, Data("abc".utf8)) + done),
        ("wrong size", frame(0, 4, Data("abcd".utf8)) + done),
        ("duplicate", frame(0, 3, Data("abc".utf8)) + frame(0, 3, Data("abc".utf8)) + done),
        ("truncated body", frame(0, 3, Data("ab".utf8))),
        ("truncated header", Data([0, 0, 0])),
        ("missing terminator", frame(0, 3, Data("abc".utf8))),
        ("early terminator", done),
        ("invalid terminator", frame(0, 3, Data("abc".utf8)) + frame(UInt32.max, 1)),
        ("trailing byte", frame(0, 3, Data("abc".utf8)) + done + Data([1])),
        ("overlong body", frame(0, 3, Data("abcd".utf8)) + done)
    ]
    for (name, data) in attacks {
        let output = try directory(), writer = try ArchiveBatchStream(root: output, entries: [entry])
        writer.append(data)
        do { try writer.finish(); throw NSError(domain: "ArchiveBatchTests", code: 2, userInfo: [NSLocalizedDescriptionKey: name + " was accepted"]) }
        catch ArchiveError.invalid { checks += 1 }
    }
    for path in ["../escape", "/absolute", "a/../../escape", "a\\b", "a//b", "a/./b"] {
        do { _ = try ArchiveBatchStream(root: try directory(), entries: [.init(path: path, size: 0, isDirectory: false)]); throw NSError(domain: "ArchiveBatchTests", code: 3) }
        catch ArchiveError.invalid { checks += 1 }
    }
    do {
        let outside = try directory(), output = try directory()
        try fm.createSymbolicLink(at: output.appendingPathComponent("子目录"), withDestinationURL: outside)
        let writer = try ArchiveBatchStream(root: output, entries: [entry]); writer.append(frame(0, 3, Data("abc".utf8)) + done)
        do { try writer.finish(); throw NSError(domain: "ArchiveBatchTests", code: 4) } catch ArchiveError.invalid { checks += 1 }
        try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "symlink ancestor never receives output")
    }
    do {
        let output = try directory(), sentinel = Data("keep".utf8)
        try fm.createDirectory(at: output.appendingPathComponent("子目录"), withIntermediateDirectories: false)
        try sentinel.write(to: output.appendingPathComponent(entry.path))
        let writer = try ArchiveBatchStream(root: output, entries: [entry]); writer.append(frame(0, 3, Data("abc".utf8)) + done)
        do { try writer.finish(); throw NSError(domain: "ArchiveBatchTests", code: 5) } catch ArchiveError.invalid { checks += 1 }
        try expect(try Data(contentsOf: output.appendingPathComponent(entry.path)) == sentinel, "existing file is never overwritten")
    }
    do {
        let output = try directory(), outside = try directory(), moved = root.appendingPathComponent("moved")
        let writer = try ArchiveBatchStream(root: output, entries: [entry])
        try fm.moveItem(at: output, to: moved); try fm.createSymbolicLink(at: output, withDestinationURL: outside)
        writer.append(frame(0, 3, Data("abc".utf8)) + done)
        do { try writer.finish(); throw NSError(domain: "ArchiveBatchTests", code: 6) } catch ArchiveError.invalid { checks += 1 }
        try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "renamed staging root stays FD-bound")
    }
    for mutation in ["content", "replacement", "symlink"] {
        let source = root.appendingPathComponent(UUID().uuidString + ".zip"), original = Data("original source bytes".utf8)
        try original.write(to: source)
        let cancellation = ArchiveCreationIO.Cancellation(deadline: Date().addingTimeInterval(30))
        let parent = try directory()
        let snapshot = try ArchiveBatchSnapshot.capture(source, in: parent.appendingPathComponent("copy"), maximumBytes: 1_024, cancellation: cancellation)
        try expect(try Data(contentsOf: snapshot.url) == original, "job snapshot is byte-exact")
        switch mutation {
        case "content": try Data("changed source bytes!".utf8).write(to: source)
        case "replacement": try fm.removeItem(at: source); try original.write(to: source)
        default: try fm.removeItem(at: source); try fm.createSymbolicLink(at: source, withDestinationURL: snapshot.url)
        }
        do { try snapshot.verify(); throw NSError(domain: "ArchiveBatchTests", code: 7) } catch FileToolsError.changed { checks += 1 }
        try expect(try Data(contentsOf: snapshot.url) == original, "source mutation cannot change isolated decoder input")
    }
    do {
        let source = root.appendingPathComponent("budget.zip"); try Data(repeating: 1, count: 5).write(to: source)
        let cancellation = ArchiveCreationIO.Cancellation(deadline: Date().addingTimeInterval(30))
        do { _ = try ArchiveBatchSnapshot.capture(source, in: root.appendingPathComponent("over-budget"), maximumBytes: 4, cancellation: cancellation); throw NSError(domain: "ArchiveBatchTests", code: 8) }
        catch ArchiveError.invalid { checks += 1 }
        cancellation.cancel()
        do { _ = try ArchiveBatchSnapshot.capture(source, in: root.appendingPathComponent("cancelled"), maximumBytes: 5, cancellation: cancellation); throw NSError(domain: "ArchiveBatchTests", code: 9) }
        catch ArchiveError.cancelled { checks += 1 }
    }
    do {
        let parent = try directory(), first = parent.appendingPathComponent("原创.zip.001"), second = parent.appendingPathComponent("原创.zip.002")
        let original = Data("first volume".utf8), tail = Data("second volume".utf8)
        try original.write(to: first); try tail.write(to: second)
        try Data("unrelated prefix".utf8).write(to: parent.appendingPathComponent("原创-other.zip.003"))
        try expect(try ArchiveReadSnapshot.numericMembers(first) == [first, second], "numeric stream membership is exact, ordered, and excludes nearby prefixes")
        let snapshot = try ArchiveReadSnapshot.capture(first, in: parent.appendingPathComponent("snapshot"), maximumBytes: 1_024, cancellation: .init(deadline: .distantFuture))
        try expect(try Data(contentsOf: snapshot.url) == original && Data(contentsOf: snapshot.url.deletingLastPathComponent().appendingPathComponent(second.lastPathComponent)) == tail, "every numeric volume is copied into one decoder-only directory")
        try snapshot.verify()
        try Data("changed bytes".utf8).write(to: second)
        do { try snapshot.verify(); throw NSError(domain: "ArchiveBatchTests", code: 10) } catch FileToolsError.changed { checks += 1 }
        try expect(try Data(contentsOf: snapshot.url.deletingLastPathComponent().appendingPathComponent(second.lastPathComponent)) == tail, "later-volume mutation never changes decoder bytes")
        try tail.write(to: second)
        let third = parent.appendingPathComponent("原创.zip.003")
        try tail.write(to: third); try fm.removeItem(at: second)
        do { _ = try ArchiveReadSnapshot.numericMembers(first); throw NSError(domain: "ArchiveBatchTests", code: 11) } catch ArchiveError.invalid { checks += 1 }
        try tail.write(to: second)
        do { _ = try ArchiveReadSnapshot.capture(first, in: parent.appendingPathComponent("too-small"), maximumBytes: UInt64(original.count), cancellation: .init(deadline: .distantFuture)); throw NSError(domain: "ArchiveBatchTests", code: 12) } catch ArchiveError.invalid { checks += 1 }
        do { _ = try ArchiveReadSnapshot.numericMembers(second); throw NSError(domain: "ArchiveBatchTests", code: 13) } catch ArchiveError.invalid { checks += 1 }
        let held = parent.appendingPathComponent("held-second"); try fm.moveItem(at: second, to: held)
        try fm.createSymbolicLink(at: second, withDestinationURL: held)
        do { _ = try ArchiveReadSnapshot.capture(first, in: parent.appendingPathComponent("linked-volume"), maximumBytes: 1_024, cancellation: .init(deadline: .distantFuture)); throw NSError(domain: "ArchiveBatchTests", code: 14) } catch let failure as NSError where failure.domain == NSPOSIXErrorDomain { checks += 1 }
    }
    print("Archive batch framing / FD / snapshot tests passed (\(checks) checks)")
}
