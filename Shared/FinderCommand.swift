import AppKit
import Foundation
import Security

/// A short-lived, single-use capability on a named native pasteboard. The general
/// clipboard is untouched. A URL alone is never sufficient to authorize a file action.
struct FinderActionRequest: Codable {
    let nonce: String
    let action: String
    let paths: [String]
    let issuedAt: Date

    static let pasteboardPrefix = "com.gaoseries.GaoCaoZuo.finder."
    static let dataType = NSPasteboard.PasteboardType("com.gaoseries.GaoCaoZuo.finder-command")
    static let maximumBytes = 512_000
    static let allowedActions: Set<String> = Set([
        "new.text", "new.markdown", "new.folder", "new.custom", "path.copy", "name.copy",
        "files.copy", "files.move", "files.rename", "terminal.open", "finder.reveal",
        "archive.create", "archive.7z", "archive.custom", "archive.extract", "archive.extract.custom", "archive.list",
        "images.png", "images.jpeg", "images.heic", "images.tiff", "images.convert", "hash.sha256",
        "files.copy.desktop", "files.copy.downloads", "files.copy.documents",
        "files.move.desktop", "files.move.downloads", "files.move.documents"
    ]).union([
        "folder.favorite.add", "finder.popup", "file.hide", "file.unhide", "file.hideAll", "file.unhideAll",
        "file.extension.hide", "file.extension.show", "file.write", "file.permissions", "file.info",
        "file.alias", "file.cut", "file.paste", "file.folderNames", "file.dissolve", "file.delete",
        "file.icon", "file.icon.clear", "file.airdrop", "file.mail", "file.wallpaper", "file.openApp",
        "file.terminal", "file.path.real", "file.path.custom", "file.template.import", "file.template.create",
        "file.new.office", "file.metadata.undo", "file.ishot", "file.ishot.markup", "file.diskmap",
        "images.webp", "images.icns", "images.macicons", "images.iosicons", "file.fixNames", "file.icon.builtin",
        "file.new.docx", "file.new.xlsx", "file.new.pptx", "file.new.rtf", "file.new.xml", "file.new.psd", "file.new.ai", "file.new.pages", "file.new.numbers", "file.new.key",
        "archive.quick.zip", "archive.quick.7z", "archive.separate.zip", "archive.separate.7z", "archive.extract.here", "archive.create.trash", "archive.extract.trash", "archive.preferences", "archive.passwords"
    ])

    static func isAllowed(_ action:String)->Bool {
        if allowedActions.contains(action) {return true}
        for prefix in ["folder.open.","folder.copy.","folder.move.","template.","binaryTemplate.","file.open."] where action.hasPrefix(prefix) {
            return UUID(uuidString:String(action.dropFirst(prefix.count))) != nil
        }
        return false
    }

    static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func decode(_ bytes: Data, nonce: String, now: Date = Date()) -> FinderActionRequest? {
        guard validNonce(nonce), bytes.count <= maximumBytes,
              let request = try? JSONDecoder().decode(Self.self, from: bytes), request.nonce == nonce,
              isAllowed(request.action), !request.paths.isEmpty, request.paths.count <= 1000,
              request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 16_384 }),
              now.timeIntervalSince(request.issuedAt) >= 0, now.timeIntervalSince(request.issuedAt) <= 60 else { return nil }
        return request
    }

    /// Parse only. A syntactically valid ticket URL is not an authorized request until consume reads its native ticket.
    static func ticketNonce(from url: URL) -> String? {
        guard url.absoluteString.utf8.count <= 256,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "gaocaozuo", components.host == "finder", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              components.queryItems?.count == 1, components.queryItems?.first?.name == "ticket",
              let nonce = components.queryItems?.first?.value, validNonce(nonce) else { return nil }
        return nonce
    }

    @MainActor static func issue(action: String, urls: [URL]) -> URL? {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { return nil }
        let nonce = random.map { String(format: "%02x", $0) }.joined()
        let request = Self(nonce: nonce, action: action, paths: urls.map(\.path), issuedAt: Date())
        guard let bytes = try? JSONEncoder().encode(request), decode(bytes, nonce: nonce) != nil else { return nil }
        let board = NSPasteboard(name: .init(pasteboardPrefix + nonce))
        board.clearContents()
        guard board.setData(bytes, forType: dataType) else { board.releaseGlobally(); return nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) { board.clearContents(); board.releaseGlobally() }
        return URL(string: "gaocaozuo://finder?ticket=" + nonce)
    }

    @MainActor static func consume(_ url: URL) -> FinderActionRequest? {
        guard let nonce = ticketNonce(from: url) else { return nil }
        let board = NSPasteboard(name: .init(pasteboardPrefix + nonce))
        let bytes = board.data(forType: dataType)
        // Consume even malformed/expired requests before any file or clipboard action.
        board.clearContents(); board.releaseGlobally()
        guard let bytes else { return nil }
        return decode(bytes, nonce: nonce)
    }
}
