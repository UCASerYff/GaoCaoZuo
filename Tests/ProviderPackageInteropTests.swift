import Foundation
import Darwin

private struct ProviderInteropPair: Decodable {
    var name: String
    var request: String
    var result: String
    var expectedStatus: GaoActionStatus
}

/// Opt-in disk-package compatibility check, never a business execution path.
/// Each immutable package's createdAt supplies its isolated fixture clock. This
/// mode does not demonstrate current production TTL, permissions, GUI or E2E.
@MainActor func runProviderPackageInteropTests(directory: URL) throws {
    let fm = FileManager.default
    let input = GaoActionFiles.normalized(directory)
    let inputFD = try GaoActionFiles.openPath(input, directory: true, owned: true)
    defer { close(inputFD) }
    let pairsFD = openat(inputFD, "pairs.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard pairsFD >= 0 else { throw DataFailure.message("Provider interop: pairs.json is unavailable.") }
    let pairsBytes: Data
    do { pairsBytes = try GaoActionFiles.read(fd: pairsFD, maximum: GaoActionV1.maximumManifestBytes, owned: true) }
    catch { close(pairsFD); throw DataFailure.message("Provider interop: pairs.json failed its bounded read.") }
    close(pairsFD)
    let pairs: [ProviderInteropPair]
    do {
        guard let rawPairs = try JSONSerialization.jsonObject(with: pairsBytes) as? [[String: Any]],
              (1...64).contains(rawPairs.count),
              rawPairs.allSatisfy({ Set($0.keys) == Set(["name", "request", "result", "expectedStatus"]) }) else {
            throw DataFailure.message("Invalid pair descriptions.")
        }
        pairs = try JSONDecoder().decode([ProviderInteropPair].self, from: pairsBytes)
    } catch { throw DataFailure.message("Provider interop: expected 1–64 complete pair descriptions with valid statuses.") }
    guard Set(pairs.map(\.name)).count == pairs.count else { throw DataFailure.message("Provider interop: pair names must be unique.") }
    for pair in pairs {
        guard !pair.name.isEmpty, pair.name.utf8.count <= 128,
              pair.name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else {
            throw DataFailure.message("Provider interop: pair names must be short labels without paths or control characters.")
        }
        for path in [pair.request, pair.result] {
            try GaoActionV1.safeRelativePath(path)
            guard URL(fileURLWithPath: path).pathExtension.lowercased() == GaoActionV1.packageExtension else {
                throw DataFailure.message("Provider interop: pair members must be relative .gaoaction packages.")
            }
        }
    }
    let scratch = fm.temporaryDirectory.appendingPathComponent("GaoCaoZuo-provider-interop-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: scratch) }
    var passed = 0
    for (index, pair) in pairs.enumerated() {
        var phase = "package headers"
        do {
            let requestURL = input.appendingPathComponent(pair.request, isDirectory: true)
            let resultURL = input.appendingPathComponent(pair.result, isDirectory: true)
            let requestHeader = try providerInteropHeader(requestURL, expectedKind: .request)
            guard requestHeader.manifest.sourceBundleID == GaoActionV1.ownBundleID else {
                throw DataFailure.message("The request does not belong to this consumer.")
            }
            let resultHeader = try providerInteropHeader(resultURL, expectedKind: .result, expectedTarget: GaoActionV1.ownBundleID)
            guard resultHeader.manifest.status == pair.expectedStatus else { throw DataFailure.message("The expected result status differs.") }
            let pairScratch = scratch.appendingPathComponent("pair-" + String(index), isDirectory: true)
            try fm.createDirectory(at: pairScratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            phase = "request disk validation and staging"
            let stagedRequest = try GaoActionV1.stagePackage(at: requestURL,
                in: pairScratch.appendingPathComponent("Request/Exchange/Incoming", isDirectory: true),
                now: requestHeader.clock, expectedTarget: requestHeader.manifest.targetBundleID)
            guard stagedRequest.manifestSHA256 == requestHeader.digest, stagedRequest.manifest == requestHeader.manifest else {
                throw DataFailure.message("The request changed between header inspection and staging.")
            }
            phase = "request journal"
            let journal = try GaoActionJournal(directory: pairScratch.appendingPathComponent("Journal", isDirectory: true))
            try journal.prepare(manifest: stagedRequest.manifest, package: stagedRequest.directory,
                                digest: stagedRequest.manifestSHA256, now: requestHeader.clock)
            try journal.transition(stagedRequest.manifest.requestID, direction: "out", to: .dispatched, now: requestHeader.clock)
            phase = "result disk validation and staging"
            let stagedResult = try GaoActionV1.stagePackage(at: resultURL,
                in: pairScratch.appendingPathComponent("Result/Exchange/Incoming", isDirectory: true),
                now: resultHeader.clock, expectedTarget: GaoActionV1.ownBundleID)
            guard stagedResult.manifestSHA256 == resultHeader.digest, stagedResult.manifest == resultHeader.manifest else {
                throw DataFailure.message("The result changed between header inspection and staging.")
            }
            phase = "result correspondence and provenance"
            guard case .new = try journal.receive(stagedResult, now: resultHeader.clock) else {
                throw DataFailure.message("The first result was treated as a duplicate.")
            }
            phase = "result acceptance and status preservation"
            try GaoActionV1.verifyRetainedPackage(stagedResult)
            try journal.acceptResult(stagedResult.manifest.requestID, now: resultHeader.clock)
            let expectedState: GaoActionJournalState = pair.expectedStatus == .pending ? .received : .completed
            guard let outgoing = try journal.record(stagedRequest.manifest.requestID, direction: "out"),
                  let incoming = try journal.record(stagedResult.manifest.requestID, direction: "in"),
                  outgoing.businessStatus == pair.expectedStatus, outgoing.state == expectedState,
                  outgoing.resultIDs == [stagedResult.manifest.requestID],
                  incoming.businessStatus == pair.expectedStatus, incoming.state == .completed,
                  incoming.manifest == stagedResult.manifest else { throw DataFailure.message("The journal did not preserve the provider status.") }
            phase = "duplicate preflight"
            guard case .duplicate(let duplicate) = try journal.preflight(stagedResult.manifest, digest: stagedResult.manifestSHA256),
                  duplicate.state == .completed, duplicate.businessStatus == pair.expectedStatus,
                  try journal.history().count == 2,
                  try journal.record(stagedRequest.manifest.requestID, direction: "out")?.resultIDs == outgoing.resultIDs else {
                throw DataFailure.message("Duplicate preflight changed or lost the accepted result.")
            }
            print("PASS: \(pair.name) \(stagedRequest.manifest.action) \(pair.expectedStatus.rawValue)")
            passed += 1
        } catch {
            // Production diagnostics may contain names or paths. Only the caller's
            // validated label and fixed phase are emitted by this private harness.
            throw DataFailure.message("Provider interop failed: \(pair.name) [\(phase)].")
        }
    }
    print("PASS: provider package pairs \(passed); isolated fixture clocks, no production TTL or GUI/E2E proof")
}

private func providerInteropHeader(_ url: URL, expectedKind: GaoActionKind, expectedTarget: String? = nil) throws -> (manifest: GaoActionManifest, digest: String, clock: Date) {
    let root = try GaoActionFiles.openPath(url, directory: true, owned: true)
    defer { close(root) }
    let fd = openat(root, "manifest.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw DataFailure.message("The package manifest is unavailable.") }
    defer { close(fd) }
    let bytes = try GaoActionFiles.read(fd: fd, maximum: GaoActionV1.maximumManifestBytes, owned: true)
    let initial = try GaoActionV1.decodeManifest(bytes)
    guard initial.kind == expectedKind, let clock = GaoActionV1.parseDate(initial.createdAt) else {
        throw DataFailure.message("The package kind or fixture clock is invalid.")
    }
    let checked = try GaoActionV1.inspectManifest(at: url, now: clock, expectedTarget: expectedTarget)
    guard checked.digest == GaoActionV1.calculateSHA256(data: bytes), checked.manifest == initial else {
        throw DataFailure.message("The package manifest changed during inspection.")
    }
    return (checked.manifest, checked.digest, clock)
}
