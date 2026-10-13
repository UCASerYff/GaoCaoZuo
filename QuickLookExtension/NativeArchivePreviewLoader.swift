import Foundation

/// Preserve the existing bounded directory preview when the interactive reader
/// cannot safely represent a format. Read-only fallback never enables writes.
enum NativeArchivePreviewContent {
    case interactive(NativeArchive.Document)
    case readOnly(String)
    static func load(_ url:URL,cancellation:NativeArchive.Cancellation) throws -> Self {
        do { return .interactive(try NativeArchive.inspect(url,cancellation:cancellation)) }
        catch {
            try cancellation.check()
            let listing=try ArchiveQuickLookNative.list(url:url)
            try cancellation.check()
            return .readOnly(error.localizedDescription + "\n\n" + ArchiveQuickLookDocument.render(filename: url.lastPathComponent, technicalListing: listing))
        }
    }
}
