import Foundation

struct ScreenshotImportedOCRWork: Sendable {
    var snapshot: ScreenshotOCRRecoverySnapshot
    var sourceURLs: [UUID: URL]
}

enum IntegratedScreenshotRecovery {
    /// Loads current receiver-owned data only; does not execute the historical request.
    static func readOCR(root: URL, entryID: String) throws -> ScreenshotImportedOCRWork {
        let content = try ScreenshotMigrationActivity.readActivity(root: root, entryID: entryID)
        guard content.entry.kind == "ocr-recovery" else { throw ScreenshotOCRError.invalidDocument }
        let original = try ScreenshotOCRRecoveryStore.decode(content.recordData)
        var verified: [String: URL] = [:]
        for (_, url) in content.attachments.sorted(by: { $0.key < $1.key }) {
            let digest = try ScreenshotOCRService.sha256(url: url, limit: original.document.options.maxFileBytes)
            if verified[digest] == nil { verified[digest] = url }
        }
        var document = original.document
        var sources: [UUID: URL] = [:]
        for offset in document.sources.indices {
            let source = document.sources[offset]
            guard let mapping = original.sources.first(where: { $0.sourceID == source.id }),
                  let url = verified[mapping.sourceSHA256], source.sha256.isEmpty || source.sha256 == mapping.sourceSHA256 else {
                throw ScreenshotOCRError.validation("迁入恢复稿缺少经过核验的原件；未替换当前文稿。")
            }
            // A failed original decode can leave its document descriptor empty.
            // Only fill this new working copy from the retained, validated input;
            // the original recovery JSON and manifest remain unchanged.
            if source.sha256.isEmpty {
                document.sources[offset].sha256 = mapping.sourceSHA256
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let bytes = attributes[.size] as? NSNumber else { throw ScreenshotOCRError.invalidDocument }
                document.sources[offset].byteCount = bytes.int64Value
            }
            sources[source.id] = url
        }
        let snapshot = ScreenshotOCRRecoverySnapshot(schemaVersion: original.schemaVersion, requestID: original.requestID,
            createdAt: original.createdAt, document: document, sources: original.sources)
        return .init(snapshot: snapshot, sourceURLs: sources)
    }
}
