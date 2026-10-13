import Foundation

/// Shared guard for callbacks that can outlive Finder's selected preview.
/// A token invalidates queued requests; the document stamp also prevents a
/// modal callback from applying to a newly inspected revision of the same URL.
struct NativeArchiveRequestContext {
    let token: UUID
    private let url: URL?
    private let identity: NativeArchive.Identity?
    private let digest: String?
    init(token: UUID, document: NativeArchive.Document?) {
        self.token = token; url = document?.url; identity = document?.identity; digest = document?.digest
    }
    func matches(token: UUID, document: NativeArchive.Document?) -> Bool {
        self.token == token && url == document?.url && identity == document?.identity && digest == document?.digest
    }
    static func isLatest(_ request: UUID, token: UUID) -> Bool { request == token }
}

/// Host completion is independent of whether a request is still allowed to
/// update the UI. Queued, cancelled and superseded requests all finish once.
final class NativeArchivePreviewRequest {
    let token: UUID
    private var completion: ((Error?) -> Void)?
    init(token: UUID, completion: @escaping (Error?) -> Void) { self.token = token; self.completion = completion }
    func proceed(ifLatest current: UUID) -> Bool {
        guard NativeArchiveRequestContext.isLatest(token, token: current) else { finish(); return false }
        return true
    }
    func finish(_ error: Error? = nil) {
        guard let callback = completion else { return }
        completion = nil; callback(error)
    }
}
