import Foundation
import Darwin

enum ArchiveEnhancementTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try value() else { throw NSError(domain: "ArchiveEnhancementTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func rejects(_ message: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { checks += 1; return }
        throw NSError(domain: "ArchiveEnhancementTests", code: 999, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: " + message])
    }
    @MainActor static func run() async throws {
        let fm = FileManager.default
        guard let index = CommandLine.arguments.firstIndex(of: "--engine"), index + 1 < CommandLine.arguments.count else { throw ArchiveError.invalid("Tests require --engine") }
        let engine = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try await runArchiveFileIOTests(engine: engine)
        let project = engine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = fm.temporaryDirectory.appendingPathComponent("GaoArchiveEnhancements-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixtures", isDirectory: true)
        let generator = Process(); generator.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); generator.arguments = ["-B", project.appendingPathComponent("Tests/ArchiveFixtures.py").path, fixture.path]
        try generator.run(); generator.waitUntilExit(); try expect(generator.terminationStatus == 0, "original fixture generation")
        let payload = try Data(contentsOf: fixture.appendingPathComponent("payload.txt"))
        let service = ArchiveService(engineURL: engine)
        let source = root.appendingPathComponent("中文资料", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let sourceFile = source.appendingPathComponent("文件.txt"); try payload.write(to: sourceFile)
        let hidden = source.appendingPathComponent(".DS_Store"); try Data("hidden".utf8).write(to: hidden)
        var create = ArchiveCreationOptions(); create.level = .store; create.threads = 2; create.ignoredPatterns = [".DS_Store"]; create.encryptFileNames = false
        try expect(create.excludes("dir/.DS_Store"), "ignore basename wildcard")
        for format in ArchiveFormat.allCases {
            print("Archive test: stored \(format.rawValue)"); fflush(stdout)
            let packed = root.appendingPathComponent("stored." + format.rawValue)
            _ = try await service.create(items: [source], destination: packed, format: format, password: nil, splitMB: nil, solid: false, options: create)
            let listing = try await service.list(archive: packed, password: nil)
            try expect(listing.contains { $0.path == "中文资料/文件.txt" }, "store mode creates \(format)")
            try expect(!listing.contains { $0.path.contains(".DS_Store") }, "ignored hidden file absent \(format)")
        }
        let encrypted = root.appendingPathComponent("unicode.zip")
        print("Archive test: Unicode AES ZIP"); fflush(stdout)
        let secret = "中文🔐Pässwörd"
        _ = try await service.create(items: [sourceFile], destination: encrypted, format: .zip, password: secret, splitMB: nil, solid: false, options: create)
        try expect(!service.output.contains(secret), "password redacted")
        let unicodeOut = root.appendingPathComponent("unicode-out")
        _ = try await service.extract(archive: encrypted, to: unicodeOut, password: secret, selected: nil)
        try expect(try Data(contentsOf: unicodeOut.appendingPathComponent("文件.txt")) == payload, "Unicode ZIP password roundtrip")
        try await rejects("incorrect Unicode ZIP password") { _ = try await service.extract(archive: encrypted, to: root.appendingPathComponent("wrong-password"), password: "错误", selected: nil) }
        let encrypted7z = root.appendingPathComponent("visible-names.7z")
        _ = try await service.create(items: [sourceFile], destination: encrypted7z, format: .sevenZip, password: "test", splitMB: nil, solid: false, options: create)
        let visibleNames = try await service.list(archive: encrypted7z, password: nil)
        try expect(visibleNames.contains { $0.path == "文件.txt" }, "7Z filename encryption off")
        print("Archive test: split ZIP and link-bearing ZIP/7Z"); fflush(stdout)
        let large = root.appendingPathComponent("volume.bin")
        try Data((0..<(2_300_000)).map { UInt8(truncatingIfNeeded: $0) }).write(to: large)
        for pw: String? in [nil, "中文分卷"] {
            let name = pw == nil ? "split.zip" : "unicode-split.zip"
            let first = try await service.create(items: [large], destination: root.appendingPathComponent(name), format: .zip, password: pw, splitMB: 1, solid: false, options: create)
            try expect(first.lastPathComponent.hasSuffix(".001"), "ZIP first split volume")
            let output = root.appendingPathComponent(name + "-expanded")
            _ = try await service.extract(archive: first, to: output, password: pw, selected: nil)
            try expect(try Data(contentsOf: output.appendingPathComponent("volume.bin")) == Data(contentsOf: large), "split ZIP bytes roundtrip")
            try await rejects("numeric ZIP group has no provenance authorizing automatic disposal") { _ = try ArchiveVolumeGroup.capture(first) }
            let middle = first.deletingPathExtension().appendingPathExtension("002")
            let last = first.deletingPathExtension().appendingPathExtension("003"), held = last.appendingPathExtension("held")
            try await rejects("cannot dispose non-first volume") { _ = try ArchiveVolumeGroup.capture(middle) }
            try fm.moveItem(at: last, to: held)
            try await rejects("missing volume never forms disposal group") { _ = try await service.extract(archive: first, to: root.appendingPathComponent(UUID().uuidString), password: pw, selected: nil) }
            try fm.moveItem(at: held, to: last)
            let middleHeld = middle.appendingPathExtension("held")
            try fm.moveItem(at: middle, to: middleHeld)
            try await rejects("non-contiguous disposal group rejected") { _ = try ArchiveVolumeGroup.capture(first) }
            try fm.moveItem(at: middleHeld, to: middle)
        }
        try await runArchiveDisposalSafetyTests(service: service, root: root, payload: payload)
        let linked = root.appendingPathComponent("Links.app", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: false)
        try payload.write(to: linked.appendingPathComponent("run.sh"))
        try fm.createSymbolicLink(atPath: linked.appendingPathComponent("shortcut").path, withDestinationPath: "run.sh")
        for format in ArchiveFormat.allCases {
            let archive = root.appendingPathComponent("linked." + format.rawValue)
            _ = try await service.create(items: [linked], destination: archive, format: format, password: nil, splitMB: nil, solid: false)
            let output = root.appendingPathComponent("linked-out-" + format.rawValue)
            _ = try await service.extract(archive: archive, to: output, password: nil, selected: nil)
            try expect(try fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("Links.app/shortcut").path) == "run.sh", "ZIP/7Z symbolic link roundtrip")
        }

        for name in ["links.tar", "container.tar.gz", "container.tgz", "container.tar.xz", "container.txz", "container.tar.bz2", "container.tbz2", "container.tar.lz"] {
            print("Archive test: \(name)"); fflush(stdout)
            let archive = fixture.appendingPathComponent(name)
            let listing = try await service.list(archive: archive, password: nil)
            try expect(listing.contains { $0.path == "dir/run.sh" }, "recursive container listing \(name)")
            let target = root.appendingPathComponent("out-" + name)
            _ = try await service.extract(archive: archive, to: target, password: nil, selected: nil)
            try expect(try Data(contentsOf: target.appendingPathComponent("dir/run.sh")) == payload, "recursive container extraction \(name)")
            try expect(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dir/shortcut").path) == "run.sh", "safe symlink \(name)")
            try expect(try Data(contentsOf: target.appendingPathComponent("dir/hard")) == payload, "safe hard-link contents \(name)")
            var originalInfo = stat(), hardInfo = stat()
            try expect(lstat(target.appendingPathComponent("dir/run.sh").path, &originalInfo) == 0 && lstat(target.appendingPathComponent("dir/hard").path, &hardInfo) == 0 && originalInfo.st_dev == hardInfo.st_dev && originalInfo.st_ino == hardInfo.st_ino && originalInfo.st_nlink == 2, "safe hard-link actual shared inode \(name)")
            try expect((try fm.attributesOfItem(atPath: target.appendingPathComponent("dir/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755, "executable mode \(name)")
            try expect(abs(((try fm.attributesOfItem(atPath: target.appendingPathComponent("dir/run.sh").path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) - 1_760_000_000) < 1, "file mtime \(name)")
            let receipt = service.lastResultReceipts
            try FileTools.undo(receipt, trashCreated: false)
            try expect(!fm.fileExists(atPath: target.path), "undo safe-link archive \(name)")
        }
        try await rejects("outside link") { _ = try await service.extract(archive: fixture.appendingPathComponent("escape-link.tar"), to: root.appendingPathComponent("unsafe-link"), password: nil, selected: nil) }
        var noLinks = ArchiveExtractionOptions(); noLinks.allowSafeLinks = false
        try await rejects("link policy") { _ = try await service.list(archive: fixture.appendingPathComponent("links.tar"), password: nil, options: noLinks) }
        var one = ArchiveExtractionOptions(); one.maximumEntries = 1
        try await rejects("adjustable entries budget") { _ = try await service.list(archive: fixture.appendingPathComponent("links.tar"), password: nil, options: one) }
        var outer = ArchiveExtractionOptions(); outer.recursiveContainers = false
        let outerEntries = try await service.list(archive: fixture.appendingPathComponent("container.txz"), password: nil, options: outer)
        try expect(outerEntries.count == 1 && outerEntries.first?.path == "container.tar", "disable recursive expansion")

        let ace = fixture.appendingPathComponent("original.ace"), aceOut = root.appendingPathComponent("ace-out")
        print("Archive test: ACE / legacy encodings / LZIP"); fflush(stdout)
        _ = try await service.extract(archive: ace, to: aceOut, password: nil, selected: nil)
        try expect(try Data(contentsOf: aceOut.appendingPathComponent("hello.txt")) == payload, "original stored ACE actual extraction")
        try await rejects("ACE original traversal metadata") { _ = try await service.extract(archive: fixture.appendingPathComponent("unsafe.ace"), to: root.appendingPathComponent("ace-unsafe"), password: nil, selected: nil) }
        var legacy = ArchiveExtractionOptions(); legacy.filenameEncoding = "CP437"
        let names = try await service.list(archive: fixture.appendingPathComponent("cp437.ace"), password: nil, options: legacy)
        try expect(names.first?.path == "café.txt", "ACE CP437 exact decoded name")
        let legacyOutput = root.appendingPathComponent("cp437-out")
        _ = try await service.extract(archive: fixture.appendingPathComponent("cp437.ace"), to: legacyOutput, password: nil, selected: ["café.txt"], options: legacy)
        try expect(try Data(contentsOf: legacyOutput.appendingPathComponent("café.txt")) == payload, "ACE CP437 selected bytes roundtrip across Foundation argv normalization")
        legacy.filenameEncoding = "CP932"
        let japan = try await service.list(archive: fixture.appendingPathComponent("cp932.zip"), password: nil, options: legacy)
        try expect(japan.first?.path == "テスト.txt", "ZIP CP932 exact decoded name")
        let japanOut = root.appendingPathComponent("cp932-out")
        _ = try await service.extract(archive: fixture.appendingPathComponent("cp932.zip"), to: japanOut, password: nil, selected: nil, options: legacy)
        try expect(try Data(contentsOf: japanOut.appendingPathComponent("テスト.txt")) == payload, "ZIP CP932 bytes roundtrip")
        let lzOut = root.appendingPathComponent("lzip-out")
        _ = try await service.extract(archive: fixture.appendingPathComponent("hello.lz"), to: lzOut, password: nil, selected: nil)
        try expect(try Data(contentsOf: lzOut.appendingPathComponent("hello")) == payload, "LZIP standalone actual extraction")

        print("Archive test: independently generated AR / CPIO / CAB / ISO"); fflush(stdout)
        for (name, path) in [("original.ar", "payload.txt"), ("original.cpio", "payload.txt"), ("original.cab", "hello.txt"), ("original.iso", "hello.txt")] {
            let archive = fixture.appendingPathComponent(name)
            print("Archive sample \(name) SHA256=\(try FileTools.sha256(archive)) backend=7zz-26.04")
            let entries = try await service.list(archive: archive, password: nil)
            try expect(entries.contains { $0.path == path }, "independent sample listing \(name)")
            let target = root.appendingPathComponent("all-" + name)
            _ = try await service.extract(archive: archive, to: target, password: nil, selected: nil)
            try expect(try Data(contentsOf: target.appendingPathComponent(path)) == payload, "independent sample full extraction \(name)")
            let selectedTarget = root.appendingPathComponent("selected-" + name)
            _ = try await service.extract(archive: archive, to: selectedTarget, password: nil, selected: [path])
            try expect(try Data(contentsOf: selectedTarget.appendingPathComponent(path)) == payload, "independent sample selected extraction \(name)")
        }
        try expect(ArchiveCapabilities.matrix.first { $0.format.hasPrefix("TAR") }?.canCreate == false, "TAR creation is not advertised")
        let rollbackSourceA = root.appendingPathComponent("rollback-a.zip"), rollbackSourceB = root.appendingPathComponent("rollback-b.zip")
        try payload.write(to: rollbackSourceA);try payload.write(to: rollbackSourceB)
        let fakeTrash = root.appendingPathComponent("isolated-trash");try fm.createDirectory(at:fakeTrash,withIntermediateDirectories:false)
        let originalPairs = try [rollbackSourceA, rollbackSourceB].map { ($0, try FileTools.fingerprint($0)) }
        try await rejects("partial volume disposal rolls back earlier moves") {
            try ArchiveEnhancementController.trashUnchanged(originalPairs) { file in
                if file == rollbackSourceB { throw ArchiveError.invalid("injected second-volume failure") }
                let target = fakeTrash.appendingPathComponent(file.lastPathComponent);try fm.moveItem(at:file,to:target);return target
            }
        }
        try expect(try Data(contentsOf:rollbackSourceA) == payload && Data(contentsOf:rollbackSourceB) == payload && fm.contentsOfDirectory(atPath:fakeTrash.path).isEmpty,"disposal rollback restores all original temporary samples")
        let badHardRoot=root.appendingPathComponent("bad-hard-root");try fm.createDirectory(at:badHardRoot,withIntermediateDirectories:false)
        try payload.write(to:badHardRoot.appendingPathComponent("original"));try payload.write(to:badHardRoot.appendingPathComponent("pretend-link"))
        let hardExpected:[ArchiveEntry]=[.init(path:"original",size:UInt64(payload.count),isDirectory:false),.init(path:"pretend-link",size:0,isDirectory:false,hardLink:"original")]
        try await rejects("equal byte copies are not accepted as hard links") {try ArchiveService.verifyExtractedTree(badHardRoot,expected:hardExpected)}
        try fm.removeItem(at:badHardRoot.appendingPathComponent("pretend-link"));try fm.linkItem(at:badHardRoot.appendingPathComponent("original"),to:badHardRoot.appendingPathComponent("pretend-link"))
        let outside=root.appendingPathComponent("outside-inode-link");try fm.linkItem(at:badHardRoot.appendingPathComponent("original"),to:outside)
        try await rejects("hard link with an extra outside-root name rejected") {try ArchiveService.verifyExtractedTree(badHardRoot,expected:hardExpected)}
        let here = root.appendingPathComponent("here"); try fm.createDirectory(at: here, withIntermediateDirectories: false)
        print("Archive test: direct expansion and editing"); fflush(stdout)
        let targets = try await service.extractIntoDirectory(archive: root.appendingPathComponent("stored.zip"), to: here, password: nil)
        try expect(targets.count == 1 && targets[0].lastPathComponent == source.lastPathComponent, "existing-directory direct expansion")
        try await rejects("existing-directory collision") { _ = try await service.extractIntoDirectory(archive: root.appendingPathComponent("stored.zip"), to: here, password: nil) }
        try expect(try Data(contentsOf: here.appendingPathComponent("中文资料/文件.txt")) == payload, "collision preserves existing bytes")
        let added = root.appendingPathComponent("new.txt"); try Data("added".utf8).write(to: added)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("stored.zip").path)
        let originalHash = try FileTools.fingerprint(root.appendingPathComponent("stored.zip"))
        let edit = try await service.edit(archive: root.appendingPathComponent("stored.zip"), password: nil, adding: [added], removing: ["中文资料/文件.txt"], removeHidden: false,
                                          saveTo: root.appendingPathComponent("stored.zip"), backupDirectory: root.appendingPathComponent("backups"))
        try expect(edit.backup != nil && (try FileTools.fingerprint(edit.backup!)) == originalHash, "archive edit verified original backup")
        try expect((try fm.attributesOfItem(atPath: edit.result.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "editing preserves private archive mode")
        let edited = try await service.list(archive: edit.result, password: nil)
        try expect(edited.contains { $0.path == "new.txt" } && !edited.contains { $0.path == "中文资料/文件.txt" }, "archive edit add/delete saved")
        try expect(ArchiveTreeNode.build([.init(path: "a/b/c.txt", size: 9, isDirectory: false)]).first?.children?.first?.children?.first?.name == "c.txt", "implicit directory tree")

        let metadataFile = root.appendingPathComponent("metadata.txt"); try payload.write(to: metadataFile)
        print("Archive test: macOS metadata"); fflush(stdout)
        let attribute = Data("metadata-roundtrip".utf8)
        let status = attribute.withUnsafeBytes { setxattr(metadataFile.path, "com.gaoseries.archive-test", $0.baseAddress, $0.count, 0, 0) }
        try expect(status == 0, "test xattr set")
        let fork = Data("original-resource-fork".utf8)
        let forkStatus = fork.withUnsafeBytes { setxattr(metadataFile.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        try expect(forkStatus == 0, "test resource fork set")
        let aclCommand = Process(); aclCommand.executableURL = URL(fileURLWithPath: "/bin/chmod"); aclCommand.arguments = ["+a", NSUserName() + " allow read", metadataFile.path]
        try aclCommand.run(); aclCommand.waitUntilExit()
        try expect(aclCommand.terminationStatus == 0, "test ACL set")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: metadataFile.path)
        let metadataArchive = root.appendingPathComponent("metadata.zip")
        _ = try await service.create(items: [metadataFile], destination: metadataArchive, format: .zip, password: nil, splitMB: nil, solid: false)
        let metadataOut = root.appendingPathComponent("metadata-out")
        _ = try await service.extract(archive: metadataArchive, to: metadataOut, password: nil, selected: nil)
        var bytes = Data(count: 128)
        let amount = bytes.withUnsafeMutableBytes { getxattr(metadataOut.appendingPathComponent("metadata.txt").path, "com.gaoseries.archive-test", $0.baseAddress, $0.count, 0, 0) }
        try expect(amount == attribute.count && bytes.prefix(amount) == attribute, "AppleDouble xattr restored")
        let forkAmount = bytes.withUnsafeMutableBytes { getxattr(metadataOut.appendingPathComponent("metadata.txt").path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        try expect(forkAmount == fork.count && bytes.prefix(forkAmount) == fork, "AppleDouble resource fork restored")
        var aclPresent = false
        if let acl = acl_get_file(metadataOut.appendingPathComponent("metadata.txt").path, ACL_TYPE_EXTENDED) {
            var entry: acl_entry_t?; aclPresent = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0; acl_free(UnsafeMutableRawPointer(acl))
        }
        try expect(aclPresent, "AppleDouble ACL restored")
        try expect((try fm.attributesOfItem(atPath: metadataOut.appendingPathComponent("metadata.txt").path)[.posixPermissions] as? NSNumber)?.intValue == 0o444, "read-only mode preserved")
        try expect(!fm.fileExists(atPath: metadataOut.appendingPathComponent("__MACOSX").path), "consumed AppleDouble removed")

        let ordinarySidecar = root.appendingPathComponent("._ordinary.txt"); try payload.write(to: ordinarySidecar)
        let ordinaryZIP = root.appendingPathComponent("ordinary-sidecar.zip")
        _ = try await service.create(items: [ordinarySidecar], destination: ordinaryZIP, format: .zip, password: nil, splitMB: nil, solid: false)
        let ordinaryOut = root.appendingPathComponent("ordinary-output"); try fm.createDirectory(at: ordinaryOut, withIntermediateDirectories: false)
        let ordinaryResults = try await service.extractIntoDirectory(archive: ordinaryZIP, to: ordinaryOut, password: nil)
        try expect(ordinaryResults.count == 1 && (try Data(contentsOf: ordinaryOut.appendingPathComponent("._ordinary.txt"))) == payload, "ordinary AppleDouble-like filename survives publication")

        let previewController=ArchiveEnhancementController(directory:root.appendingPathComponent("preview-settings"))
        try await previewController.preview(archive:edit.result,path:"new.txt",password:nil,service:service)
        try expect(try Data(contentsOf:previewController.previewURL!) == Data("added".utf8),"browser preview materializes actual selected bytes")
        let previewURL=previewController.previewURL!;previewController.clearPreviews()
        try expect(!fm.fileExists(atPath:previewURL.path),"preview cleanup removes only its own temporary copy")
        let settings = root.appendingPathComponent("settings")
        let controller = ArchiveEnhancementController(directory: settings); controller.preferences.creation.level = .maximum; controller.preferences.extraction.maximumExpandedGiB = 80
        try controller.save()
        let reopened = ArchiveEnhancementController(directory: settings)
        try expect(reopened.failure == nil && reopened.preferences.creation.level == .maximum && reopened.preferences.extraction.maximumExpandedGiB == 80, "archive settings restart preservation")
        let emptyExport = root.appendingPathComponent("empty-password-book.json")
        try reopened.exportPasswords(to: emptyExport)
        try expect((try fm.attributesOfItem(atPath: emptyExport.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "password export private from creation")
        try await rejects("password export never overwrites") { try reopened.exportPasswords(to: emptyExport) }
        print("Archive enhancements: \(checks) checks passed")
    }
}
@MainActor func runArchiveEnhancementTests() async throws { try await ArchiveEnhancementTests.run() }
