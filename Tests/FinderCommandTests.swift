import Foundation

/// Pure request/URL tests: never issue or consume a native pasteboard ticket.
func runFinderCommandTests() throws {
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else {
            throw NSError(domain: "FinderCommandTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    let nonce = String(repeating: "0123456789abcdef", count: 4)
    let otherNonce = String(repeating: "fedcba9876543210", count: 4)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func bytes(action: String = "new.text", paths: [String] = ["/temporary/finder-test"],
               issuedAt: Date? = nil, requestNonce: String? = nil) throws -> Data {
        try JSONEncoder().encode(FinderActionRequest(nonce: requestNonce ?? nonce, action: action,
                                                    paths: paths, issuedAt: issuedAt ?? now))
    }
    func accepted(_ data: Data, matching value: String? = nil) -> Bool {
        FinderActionRequest.decode(data, nonce: value ?? nonce, now: now) != nil
    }
    func parsed(_ text: String) -> String? {
        URL(string: text).flatMap { FinderActionRequest.ticketNonce(from: $0) }
    }
    try check(FinderActionRequest.validNonce(nonce), "64 ASCII lowercase hex characters form a valid nonce")
    for invalid in ["", String(nonce.dropLast()), nonce + "0", nonce.uppercased(), String(repeating: "g", count: 64),
                    String(repeating: "０", count: 64), nonce + "\0", " " + nonce] {
        try check(!FinderActionRequest.validNonce(invalid), "wrong length, alphabet or Unicode nonce is rejected")
    }
    let valid = try bytes()
    try check(accepted(valid), "newly issued valid request is accepted")
    try check(!accepted(valid, matching: otherNonce), "URL token must match native request token")
    try check(!accepted(bytes(requestNonce: otherNonce)), "native token mismatch is rejected")
    try check(!accepted(valid, matching: "not-a-nonce"), "invalid caller nonce cannot authorize valid JSON")
    try check(accepted(bytes(issuedAt: now.addingTimeInterval(-60))), "exactly 60 seconds old is within validity")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(-60.001))), "expired ticket is rejected")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(0.001))), "even slightly future ticket is rejected")
    try check(!accepted(bytes(issuedAt: now.addingTimeInterval(3600))), "future-dated ticket cannot extend validity")

    for allowed in ["new.folder", "path.copy", "archive.extract", "files.move.documents", "images.heic"] {
        try check(accepted(bytes(action: allowed)), "known Finder action accepted: \(allowed)")
    }
    for forbidden in ["", "new.text ", "NEW.TEXT", "system.lock", "shortcut.run", "shell.run", "template.anything", "../new.text"] {
        try check(!accepted(bytes(action: forbidden)), "action outside Finder whitelist rejected: \(forbidden)")
    }
    try check(accepted(bytes(paths: ["/temporary/中文 空格/#?%&.txt"])), "absolute Unicode path is preserved as data")
    for invalidPath in ["", "relative/file.txt", "../escape", "~/Desktop/file.txt", "file:///temporary/a", "/temporary/a\0b"] {
        try check(!accepted(bytes(paths: [invalidPath])), "relative or NULL-containing path rejected")
    }
    let maxPath = "/" + String(repeating: "a", count: 16_383)
    try check(accepted(bytes(paths: [maxPath])), "path at 16384 UTF-8 bytes is permitted")
    try check(!accepted(bytes(paths: [maxPath + "a"])), "overlong path rejected")
    try check(!accepted(bytes(paths: ["/" + String(repeating: "文", count: 5462)])), "path length uses UTF-8 bytes, not characters")
    try check(!accepted(bytes(paths: [])), "empty selection rejected")
    try check(accepted(bytes(paths: Array(repeating: "/temporary/a", count: 1000))), "1000 path boundary accepted")
    try check(!accepted(bytes(paths: Array(repeating: "/temporary/a", count: 1001))), "selection above 1000 paths rejected")

    var exactSize = valid
    exactSize.append(Data(repeating: 32, count: FinderActionRequest.maximumBytes - valid.count))
    try check(accepted(exactSize), "JSON at total byte budget accepted")
    var oversized = exactSize; oversized.append(32)
    try check(!accepted(oversized), "JSON over total byte budget rejected before decoding")
    for malformed in [Data(), Data("{".utf8), Data("null".utf8), Data([0xff, 0xfe, 0xfd])] {
        try check(!accepted(malformed), "malformed JSON is rejected")
    }
    let rawPaths = try JSONEncoder().encode(["/temporary/a"])
    try check(!accepted(rawPaths), "legacy browser path payload is not a native ticket document")
    var wrongShape = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    wrongShape["paths"] = [7]
    try check(!accepted(JSONSerialization.data(withJSONObject: wrongShape)), "path entries must be strings")
    wrongShape = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    wrongShape.removeValue(forKey: "issuedAt")
    try check(!accepted(JSONSerialization.data(withJSONObject: wrongShape)), "missing timestamp is rejected")

    let validURL = "gaocaozuo://finder?ticket=" + nonce
    try check(parsed(validURL) == nonce, "ticket route extracts only nonce")
    for invalidURL in [
        "https://finder?ticket=" + nonce,
        "gaocaozuo://perform/new.text?payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + nonce + "&payload=" + rawPaths.base64EncodedString(),
        "gaocaozuo://finder?ticket=" + nonce + "&ticket=" + nonce,
        "gaocaozuo://finder?ticket=", "gaocaozuo://finder?ticket",
        "gaocaozuo://finder?Ticket=" + nonce,
        "gaocaozuo://finder/?ticket=" + nonce,
        "gaocaozuo://finder/new.text?ticket=" + nonce,
        "gaocaozuo://evil.example?ticket=" + nonce,
        "gaocaozuo://user@finder?ticket=" + nonce,
        "gaocaozuo://user:password@finder?ticket=" + nonce,
        "gaocaozuo://finder:9999?ticket=" + nonce,
        validURL + "#", validURL + "#new.text",
        "gaocaozuo://finder?ticket=" + String(repeating: "a", count: 300)
    ] {
        try check(parsed(invalidURL) == nil, "non-ticket, ambiguous or decorated URL rejected")
    }
    // A parsed nonce still needs matching native bytes; URL syntax alone carries no paths or authority.
    try check(!accepted(rawPaths, matching: parsed(validURL)), "browser payload cannot become a request through valid ticket syntax")
    print("PASS: \(checks) Finder ticket checks; pure data only, no pasteboard or file access")
}
