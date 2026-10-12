import Foundation

/// Do not relax a payload assertion to merely filter an arbitrary __MACOSX tree.
/// Only exact AppleDouble companions of the expected payload names are allowed.
func validatedArchivePayloadPaths(_ entries: [ArchiveEntry], expected: Set<String>) throws -> Set<String> {
    var metadataDirectories: Set<String> = ["__MACOSX"]
    var metadataFiles: Set<String> = []
    for path in expected {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { throw NSError(domain: "ArchiveTestSupport", code: 1) }
        var parent = "__MACOSX"
        for directory in components.dropLast() { parent += "/" + directory; metadataDirectories.insert(parent) }
        metadataFiles.insert(parent + "/._" + name)
    }
    var payload: Set<String> = []
    for entry in entries {
        if expected.contains(entry.path) { payload.insert(entry.path); continue }
        guard entry.symbolicLink == nil, entry.hardLink == nil else { throw NSError(domain: "ArchiveTestSupport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metadata must not be a link"]) }
        if metadataDirectories.contains(entry.path), entry.isDirectory, entry.size == 0 { continue }
        if metadataFiles.contains(entry.path), !entry.isDirectory, (4...UInt64(64 * 1_024 * 1_024)).contains(entry.size) { continue }
        throw NSError(domain: "ArchiveTestSupport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected archive entry: " + entry.path])
    }
    guard payload == expected else { throw NSError(domain: "ArchiveTestSupport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Archive payload paths differ from the exact expected set"]) }
    return payload
}
