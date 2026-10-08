import Foundation
import AppKit
import ImageIO
import CoreImage

struct FileToolsTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NSError(domain: "FileToolsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw NSError(domain: "FileToolsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: " + message])
    }
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-FileTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let file = try FileTools.createFile(in: source, name: "中文.txt", content: "abc")
        try expect(try String(contentsOf: file, encoding: .utf8) == "abc", "create bytes")
        try expect(try FileTools.sha256(file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known SHA-256")
        try rejects("overwrite create") { _ = try FileTools.createFile(in: source, name: "中文.txt", content: "bad") }
        try rejects("path escape create") { _ = try FileTools.createFile(in: source, name: "../bad.txt", content: "bad") }
        let copy = try FileTools.copy(items: [file], to: target, move: false)
        try expect(copy.count == 1 && fm.fileExists(atPath: file.path), "copy preserves source")
        try rejects("copy collision") { _ = try FileTools.copy(items: [file], to: target, move: false) }
        try Data("changed".utf8).write(to: copy[0].destination)
        try rejects("modified destination undo") { try FileTools.undo(copy, trashCreated: false) }
        try Data("abc".utf8).write(to: copy[0].destination)
        try FileTools.undo(copy, trashCreated: false)
        try expect(!fm.fileExists(atPath: copy[0].destination.path), "undo verified copy")
        let move = try FileTools.copy(items: [file], to: target, move: true)
        try expect(!fm.fileExists(atPath: file.path), "move source removed after success")
        try FileTools.undo(move, trashCreated: false)
        try expect(fm.fileExists(atPath: file.path), "move undo restores source")
        try FileTools.undo(move, trashCreated: false)
        try expect(fm.fileExists(atPath: file.path), "completed move recovery can be retried")
        let plan = try FileTools.renamePreview(items: [file], pattern: "{name}_{n:03}.{ext}", start: 7)
        try expect(plan[0].destination.lastPathComponent == "中文_007.txt", "rename numbering")
        let renames = try FileTools.applyRenames(plan)
        try expect(fm.fileExists(atPath: plan[0].destination.path), "rename apply")
        try FileTools.undo(renames, trashCreated: false)
        try expect(fm.fileExists(atPath: file.path), "rename undo")
        let other = try FileTools.createFile(in: source, name: "other.txt", content: "second")
        try rejects("duplicate rename targets") { _ = try FileTools.renamePreview(items: [file, other], pattern: "same.txt", start: 1) }
        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        try rejects("symlink copy") { _ = try FileTools.copy(items: [link], to: target, move: false) }
        try fm.removeItem(at: link)
        try rejects("folder to own descendant") { _ = try FileTools.copy(items: [source], to: source, move: false) }
        let nested = source.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try FileTools.createFile(in: nested, name: "data.txt", content: "nested bytes")
        let treeCopy = try FileTools.copy(items: [source], to: target, move: false)
        try expect(try FileTools.fingerprint(source) == FileTools.fingerprint(treeCopy[0].destination), "directory fingerprint canonical temp path")
        try FileTools.undo(treeCopy, trashCreated: false)
        try FileTools.undo(treeCopy, trashCreated: false)
        try expect(!fm.fileExists(atPath: treeCopy[0].destination.path), "completed copy recovery can be retried")
        let interruptedBatch = try FileTools.copy(items: [file, other], to: target, move: false)
        try FileTools.undo([interruptedBatch[0]], trashCreated: false)
        try FileTools.undo(interruptedBatch, trashCreated: false)
        try expect(interruptedBatch.allSatisfy { !fm.fileExists(atPath: $0.destination.path) }, "partially completed recovery resumes remaining items")

        let qr = try FileTools.qrCode(text: "搞操作 https://example.com/?x=1")
        let imageURL = source.appendingPathComponent("qr.png")
        try qr.write(to: imageURL)
        try expect(CGImageSourceCreateWithData(qr as CFData, nil) != nil, "QR PNG decodable")
        let converted = try FileTools.convertImages(items: [imageURL], to: target, format: "jpeg", maxDimension: 120)
        let imageSource = CGImageSourceCreateWithURL(converted[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
        try expect((props[kCGImagePropertyPixelWidth] as! Int) <= 120 && (props[kCGImagePropertyPixelHeight] as! Int) <= 120, "image dimension bound")
        try rejects("image collision") { _ = try FileTools.convertImages(items: [imageURL], to: target, format: "jpeg", maxDimension: nil) }
        try rejects("image batch transaction") { _ = try FileTools.convertImages(items: [imageURL, file], to: target, format: "tiff", maxDimension: nil) }
        try expect(!fm.fileExists(atPath: target.appendingPathComponent("qr.tiff").path), "failed image batch leaves no partial output")

        let valid = "Path = folder\nSize = 0\nAttributes = D drwx------\n\nPath = folder/file.txt\nSize = 3\nAttributes = A -rw-------\n\n"
        let entries = try ArchiveService.parseListing(valid)
        try expect(entries.count == 2 && entries[0].isDirectory && entries[1].size == 3, "archive list parse")
        for path in ["../escape", "/absolute", "a/../../escape", "a\\escape", "C:escape", "a//b", "a\nPath = evil"] {
            try rejects("archive path " + path) { try ArchiveService.validateArchivePath(path) }
        }
        try rejects("archive symlink") { _ = try ArchiveService.parseListing("Path = link\nSize = 3\nAttributes = A lrwxrwxrwx\n\n") }
        try rejects("archive hardlink") { _ = try ArchiveService.parseListing("Path = file\nSize = 3\nHard Link = ../escape\n\n") }
        try rejects("archive duplicate") { _ = try ArchiveService.parseListing("Path = A\nSize = 0\n\nPath = a\nSize = 0\n\n") }
        try rejects("archive size budget") { _ = try ArchiveService.parseListing("Path = huge\nSize = 999999999999\n\n") }
        try rejects("archive file is parent") { _ = try ArchiveService.parseListing("Path = a\nSize = 1\n\nPath = a/b\nSize = 1\n\n") }
        try expect(try ArchiveService.parseListing("Path = regular.txt\nSize = 3\nMode = -rw-r--r--\nSymbolic Link = \nHard Link = \n\n").count == 1, "TAR empty link fields")
        try expect(ArchiveService.parsePermissions("A -rwsr-sr-t") == 0o755, "executable bits retained while special-ID bits stripped")
        let serialized = try JSONEncoder().encode(move)
        try expect(try JSONDecoder().decode([FileOperationReceipt].self, from: serialized).first?.fingerprint == move.first?.fingerprint, "receipt roundtrip")

        let engineArgument = CommandLine.arguments.firstIndex(of: "--engine").flatMap { index in index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil }
        if let enginePath = engineArgument ?? ProcessInfo.processInfo.environment["GAO_TEST_7ZZ"] {
            let service = ArchiveService(engineURL: URL(fileURLWithPath: enginePath))
            let historicalDate = Date(timeIntervalSince1970: 1_609_459_200)
            try fm.setAttributes([.posixPermissions: 0o755, .modificationDate: historicalDate], ofItemAtPath: file.path)
            let zip = try await service.create(items: [file, other], destination: root.appendingPathComponent("test.zip"), format: .zip, password: nil, splitMB: nil, solid: false)
            let zipEntries = try await service.list(archive: zip, password: nil)
            try expect(Set(zipEntries.map(\.path)) == ["中文.txt", "other.txt"], "real ZIP listing")
            let extracted = try await service.extract(archive: zip, to: root.appendingPathComponent("expanded"), password: nil, selected: nil)
            try expect(try FileTools.sha256(extracted.appendingPathComponent("中文.txt")) == FileTools.sha256(file), "real ZIP roundtrip")
            let zipAttributes = try fm.attributesOfItem(atPath: extracted.appendingPathComponent("中文.txt").path)
            try expect((zipAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755, "ZIP execution permission restored")
            try expect(abs((zipAttributes[.modificationDate] as! Date).timeIntervalSince(historicalDate)) <= 2, "ZIP modification time restored")
            let selectedOutput = try await service.extract(archive: zip, to: root.appendingPathComponent("selected"), password: nil, selected: ["other.txt"])
            try expect(!fm.fileExists(atPath: selectedOutput.appendingPathComponent("中文.txt").path), "selected-only extraction")
            let secret = "test-only-中文-password"
            let encrypted = try await service.create(items: [file], destination: root.appendingPathComponent("secret.7z"), format: .sevenZip, password: secret, splitMB: 1, solid: true)
            try expect(encrypted.pathExtension == "001", "7Z volume result")
            let encryptedEntries = try await service.list(archive: encrypted, password: secret)
            try expect(encryptedEntries.first?.path == file.lastPathComponent, "encrypted 7Z stdin password listing")
            let decrypted = try await service.extract(archive: encrypted, to: root.appendingPathComponent("decrypted"), password: secret, selected: nil)
            try expect(try FileTools.sha256(decrypted.appendingPathComponent("中文.txt")) == FileTools.sha256(file), "encrypted 7Z roundtrip")
            let sevenZipAttributes = try fm.attributesOfItem(atPath: decrypted.appendingPathComponent("中文.txt").path)
            try expect((sevenZipAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755, "7Z execution permission restored")
            try expect(abs((sevenZipAttributes[.modificationDate] as! Date).timeIntervalSince(historicalDate)) <= 2, "7Z modification time restored")
            try expect(!service.output.contains(secret), "password excluded from output")
            do { _ = try await service.list(archive: encrypted, password: "wrong"); throw NSError(domain: "Expected wrong password rejection", code: 1) }
            catch let error as ArchiveError { try expect(error.localizedDescription.contains("退出码"), "wrong password detected") }
            try expect(!service.isRunning, "state reset after failure")
            let cancellableInput = try FileTools.createFile(in: source, name: "cancel-input.bin", content: "")
            try Data(repeating: 0x17, count: 64 * 1024 * 1024).write(to: cancellableInput)
            let cancelledDestination = root.appendingPathComponent("cancelled.7z")
            let job = Task { try await service.create(items: [cancellableInput], destination: cancelledDestination, format: .sevenZip, password: nil, splitMB: nil, solid: true) }
            try await Task.sleep(nanoseconds: 10_000_000)
            service.cancel()
            do { _ = try await job.value; throw NSError(domain: "Expected cancellation", code: 1) }
            catch ArchiveError.cancelled { checks += 1 }
            try expect(!fm.fileExists(atPath: cancelledDestination.path) && fm.fileExists(atPath: cancellableInput.path), "cancel preserves source and creates no output")
        } else { print("SKIP real archive engine tests: set GAO_TEST_7ZZ") }
        print("PASS: \(checks) file/archive checks; temporary fixtures removed")
    }
}

@MainActor func runFileToolsTests() async throws { try await FileToolsTests.run() }
