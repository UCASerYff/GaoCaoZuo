import Foundation

/// These fixtures demonstrate why decoder success is insufficient permission to
/// dispose of same-stem neighbors. No operation here uses the real Trash.
@MainActor func runArchiveDisposalSafetyTests(service: ArchiveService, root: URL, payload: Data) async throws {
    let fm = FileManager.default
    let source = root.appendingPathComponent("disposal-source.txt")
    try payload.write(to: source, options: .withoutOverwriting)
    var options = ArchiveCreationOptions(); options.level = .store
    let standalone = root.appendingPathComponent("disposal-standalone.zip")
    _ = try await service.create(items: [source], destination: standalone, format: .zip, password: nil, splitMB: nil, solid: false, options: options)
    let first = root.appendingPathComponent("unproven.zip.001")
    let unrelated = root.appendingPathComponent("unproven.zip.002")
    try fm.copyItem(at: standalone, to: first)
    let unrelatedBytes = Data("This file was not selected and is not part of the ZIP. Keep it intact.".utf8)
    try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)
    let original = try Data(contentsOf: first)
    let output = root.appendingPathComponent("unproven-extracted")
    _ = try await service.extract(archive: first, to: output, password: nil, selected: nil)
    try ArchiveEnhancementTests.expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == payload,
                                      "decoder accepts a complete ZIP plus an unused same-stem .002 tail")
    try await ArchiveEnhancementTests.rejects("decoder success must not authorize disposing unused neighbor") {
        _ = try ArchiveVolumeGroup.capture(first)
    }
    try ArchiveEnhancementTests.expect(try Data(contentsOf: first) == original && Data(contentsOf: unrelated) == unrelatedBytes,
                                      "rejected automatic ZIP disposal preserves selected archive and unselected .002 bytes")
    print("PASS evidence: ZIP extraction accepted unused .002; automatic disposal refused; both originals preserved")

    let single = try ArchiveVolumeGroup.capture(standalone)
    try ArchiveEnhancementTests.expect(single.members == [standalone] && single.fingerprints.count == 1,
                                      "ordinary single archive retains automatic disposal eligibility")
    try single.verifyUnchanged()
    let replacement = standalone.appendingPathExtension("replacement")
    try fm.copyItem(at: standalone, to: replacement)
    try fm.removeItem(at: standalone); try fm.moveItem(at: replacement, to: standalone)
    try await ArchiveEnhancementTests.rejects("identical bytes at a new inode cannot reuse captured disposal identity") { try single.verifyUnchanged() }

    let seven = root.appendingPathComponent("disposal-standalone.7z")
    _ = try await service.create(items: [source], destination: seven, format: .sevenZip, password: nil, splitMB: nil, solid: false, options: options)
    let sevenFirst = root.appendingPathComponent("unproven.7z.001"), sevenNeighbor = root.appendingPathComponent("unproven.7z.002")
    try fm.copyItem(at: seven, to: sevenFirst)
    try unrelatedBytes.write(to: sevenNeighbor, options: .withoutOverwriting)
    let sevenOriginal = try Data(contentsOf: sevenFirst)
    try await ArchiveEnhancementTests.rejects("unknown 7Z split provenance cannot authorize automatic neighbor disposal") {
        _ = try ArchiveVolumeGroup.capture(sevenFirst)
    }
    try ArchiveEnhancementTests.expect(try Data(contentsOf: sevenFirst) == sevenOriginal && Data(contentsOf: sevenNeighbor) == unrelatedBytes,
                                      "rejected automatic 7Z disposal preserves every original")
    print("PASS evidence: unproven 7Z split disposal refused; both originals preserved")
}
