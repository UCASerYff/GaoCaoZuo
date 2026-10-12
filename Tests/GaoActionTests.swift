import Foundation
import CryptoKit

@MainActor
func runGaoActionTests() async throws {
    let fm = FileManager.default
    let tempRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("GaoAction-Tests-\(UUID().uuidString)")
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: tempRoot) }

    let testClock = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    let createdAt = "2026-10-12T12:00:00Z"
    let expiresAt = "2026-10-12T12:02:00Z"
    let testNonce = Data(repeating: 0, count: 32).base64EncodedString()
    var knownIDs: Set<String> = []

    // 1. Fixture: v1-documents-newText
    let fix1Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000001.gaoaction")
    try fm.createDirectory(at: fix1Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let payload1 = fix1Dir.appendingPathComponent("payload", isDirectory: true)
    try fm.createDirectory(at: payload1, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file1 = payload1.appendingPathComponent("input.txt")
    let file1Content = Data("hello\n".utf8)
    try file1Content.write(to: file1)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file1.path)
    let hash1 = SHA256.hash(data: file1Content).map { String(format: "%02x", $0) }.joined()
    guard hash1 == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" else {
        throw DataFailure.message("Fixture 1 sha256 计算错误: \(hash1)")
    }
    let manifest1 = GaoActionManifest(
        schemaVersion: 1,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000001",
        sourceBundleID: "com.gaoseries.GaoWenJian",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "documents.newText",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [
            GaoActionItem(id: "item-1", relativePath: "input.txt", uti: "public.plain-text", byteCount: 6, sha256: hash1)
        ],
        references: [],
        parameters: ["suggestedTitle": GaoActionAnyCodable("交接测试")]
    )
    let manifest1Data = try JSONEncoder().encode(manifest1)
    try manifest1Data.write(to: fix1Dir.appendingPathComponent("manifest.json"))
    let loaded1 = try GaoActionV1.validatePackageDirectory(at: fix1Dir, now: testClock, knownIDs: &knownIDs)
    guard loaded1.requestID == "11111111-1111-4111-8111-000000000001", loaded1.action == "documents.newText" else {
        throw DataFailure.message("Fixture 1 校验失败")
    }

    // 2. Fixture: v1-storage-directory
    let fix2Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000002.gaoaction")
    try fm.createDirectory(at: fix2Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let testRefDir = tempRoot.appendingPathComponent("ScanDir", isDirectory: true)
    try fm.createDirectory(at: testRefDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var refStat = stat()
    guard stat(testRefDir.path, &refStat) == 0 else { throw DataFailure.message("获取测试目录 stat 失败") }
    let manifest2 = GaoActionManifest(
        schemaVersion: 1,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000002",
        sourceBundleID: "com.gaoseries.GaoCaoZuo",
        targetBundleID: "com.gaoseries.GaoJiLing",
        action: "storage.inspect",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [],
        references: [
            GaoActionReference(
                id: "ref-1",
                kind: .directory,
                fileURL: testRefDir.absoluteString,
                displayName: "ScanDir",
                declaredIdentity: GaoActionIdentity(
                    device: refStat.st_dev,
                    inode: UInt64(refStat.st_ino),
                    byteCount: 0,
                    modifiedAt: createdAt
                )
            )
        ],
        parameters: ["mode": GaoActionAnyCodable("metadata")]
    )
    let manifest2Data = try JSONEncoder().encode(manifest2)
    try manifest2Data.write(to: fix2Dir.appendingPathComponent("manifest.json"))
    let loaded2 = try GaoActionV1.validatePackageDirectory(at: fix2Dir, now: testClock, knownIDs: &knownIDs)
    guard loaded2.action == "storage.inspect", loaded2.references.first?.declaredIdentity?.inode == UInt64(refStat.st_ino) else {
        throw DataFailure.message("Fixture 2 校验失败")
    }

    // 3. Fixture: v1-ocr-partial
    let fix3Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000003.gaoaction")
    try fm.createDirectory(at: fix3Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let manifest3 = GaoActionManifest(
        schemaVersion: 1,
        kind: .result,
        requestID: "11111111-1111-4111-8111-000000000003",
        sourceBundleID: "com.gaoseries.GaoJieTu",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "ocr.files",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [],
        references: [],
        parameters: [:],
        inReplyTo: "11111111-1111-4111-8111-000000000003",
        status: .partial,
        errorCode: nil,
        provenance: [
            "pagesProcessed": GaoActionAnyCodable(2),
            "pagesSucceeded": GaoActionAnyCodable(1),
            "workflowState": GaoActionAnyCodable("partialResult")
        ]
    )
    let manifest3Data = try JSONEncoder().encode(manifest3)
    try manifest3Data.write(to: fix3Dir.appendingPathComponent("manifest.json"))
    let loaded3 = try GaoActionV1.validatePackageDirectory(at: fix3Dir, now: testClock, knownIDs: &knownIDs)
    guard loaded3.status == .partial, loaded3.inReplyTo == "11111111-1111-4111-8111-000000000003" else {
        throw DataFailure.message("Fixture 3 partial result 校验失败")
    }

    // 4. Fixture: v1-duplicate-request
    var duplicateCaught = false
    do {
        _ = try GaoActionV1.validatePackageDirectory(at: fix1Dir, now: testClock, knownIDs: &knownIDs)
    } catch GaoActionError.duplicateRequest(let id) {
        if id == "11111111-1111-4111-8111-000000000001" {
            duplicateCaught = true
        }
    }
    guard duplicateCaught else {
        throw DataFailure.message("Fixture 4 重复请求未被拦截")
    }

    // 5. Fixture: v1-expired
    let fix5Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000005.gaoaction")
    try fm.createDirectory(at: fix5Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let manifest5 = GaoActionManifest(
        schemaVersion: 1,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000005",
        sourceBundleID: "com.gaoseries.GaoWenJian",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "documents.newText",
        createdAt: "2026-10-12T11:50:00Z",
        expiresAt: "2026-10-12T11:52:00Z", // Expired relative to 12:00:00Z
        nonce: testNonce,
        items: [],
        references: [],
        parameters: [:]
    )
    let manifest5Data = try JSONEncoder().encode(manifest5)
    try manifest5Data.write(to: fix5Dir.appendingPathComponent("manifest.json"))
    var expiredCaught = false
    do {
        _ = try GaoActionV1.validatePackageDirectory(at: fix5Dir, now: testClock, knownIDs: &knownIDs)
    } catch GaoActionError.expired(let id) {
        if id == "11111111-1111-4111-8111-000000000005" {
            expiredCaught = true
        }
    }
    guard expiredCaught else {
        throw DataFailure.message("Fixture 5 过期请求未被拦截")
    }

    // 6. Fixture: v1-path-traversal
    let fix6Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000006.gaoaction")
    try fm.createDirectory(at: fix6Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let manifest6 = GaoActionManifest(
        schemaVersion: 1,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000006",
        sourceBundleID: "com.gaoseries.GaoWenJian",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "documents.newText",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [
            GaoActionItem(id: "item-bad", relativePath: "../outside.txt", uti: "public.plain-text", byteCount: 10, sha256: "0000")
        ],
        references: [],
        parameters: [:]
    )
    let manifest6Data = try JSONEncoder().encode(manifest6)
    try manifest6Data.write(to: fix6Dir.appendingPathComponent("manifest.json"))
    var traversalCaught = false
    do {
        _ = try GaoActionV1.validatePackageDirectory(at: fix6Dir, now: testClock, knownIDs: &knownIDs)
    } catch GaoActionError.pathTraversal {
        traversalCaught = true
    }
    guard traversalCaught else {
        throw DataFailure.message("Fixture 6 路径穿越未被拦截")
    }

    // 7. Fixture: v1-unknown-action
    let fix7Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000007.gaoaction")
    try fm.createDirectory(at: fix7Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let manifest7 = GaoActionManifest(
        schemaVersion: 1,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000007",
        sourceBundleID: "com.gaoseries.GaoWenJian",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "arbitrary.unauthorized.command",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [],
        references: [],
        parameters: [:]
    )
    let manifest7Data = try JSONEncoder().encode(manifest7)
    try manifest7Data.write(to: fix7Dir.appendingPathComponent("manifest.json"))
    var unknownCaught = false
    do {
        _ = try GaoActionV1.validatePackageDirectory(at: fix7Dir, now: testClock, knownIDs: &knownIDs)
    } catch GaoActionError.unknownAction {
        unknownCaught = true
    }
    guard unknownCaught else {
        throw DataFailure.message("Fixture 7 未知动作未被拦截")
    }

    // 8. Fixture: v2-unsupported
    let fix8Dir = tempRoot.appendingPathComponent("11111111-1111-4111-8111-000000000008.gaoaction")
    try fm.createDirectory(at: fix8Dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let manifest8 = GaoActionManifest(
        schemaVersion: 2,
        kind: .request,
        requestID: "11111111-1111-4111-8111-000000000008",
        sourceBundleID: "com.gaoseries.GaoWenJian",
        targetBundleID: "com.gaoseries.GaoCaoZuo",
        action: "documents.newText",
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: testNonce,
        items: [],
        references: [],
        parameters: [:]
    )
    let manifest8Data = try JSONEncoder().encode(manifest8)
    try manifest8Data.write(to: fix8Dir.appendingPathComponent("manifest.json"))
    var schemaCaught = false
    do {
        _ = try GaoActionV1.validatePackageDirectory(at: fix8Dir, now: testClock, knownIDs: &knownIDs)
    } catch GaoActionError.schemaUnsupported(let v) {
        if v == 2 { schemaCaught = true }
    }
    guard schemaCaught else {
        throw DataFailure.message("Fixture 8 不支持的 schemaVersion 2 未被拦截")
    }

    // Test GaoActionClient packaging and unavailable provider graceful handling
    let client = GaoActionClient(dataDirectory: tempRoot)
    var clientErrorCaught = false
    do {
        _ = try await client.sendRequest(action: "capture.region", targetBundleID: "com.gaoseries.GaoJieTuNonExistent")
    } catch GaoActionError.providerNotReady {
        clientErrorCaught = true
    }
    guard clientErrorCaught else {
        throw DataFailure.message("GaoActionClient 未检测到目标提供方缺失")
    }

    print("PASS: GaoAction V1 8项固化Fixture全量通过（newText、storage、ocrPartial、重复拦截、过期拦截、路径穿越拦截、未知动作拦截、v2版本拦截）")
}
