import AppKit
import Foundation

/// Current-owner contracts and retained-request replay protection. All data is generated here.
enum ScreenshotGaoActionOwnershipTests {
    static func run(in root: URL) throws {
        let clock = ScreenshotGaoActionContract.date("2026-11-02T00:00:00Z")!
        var assertions = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try value() else { throw ScreenshotGaoActionContract.reject("testFailure", message) }
        }
        func rejects(_ code: String? = nil, _ body: () throws -> Void) throws {
            assertions += 1
            do { try body() }
            catch let error as ScreenshotGaoActionIssue {
                if let code, code != error.code { throw ScreenshotGaoActionContract.reject("testFailure", "Expected \(code), got \(error.code)") }
                return
            }
            throw ScreenshotGaoActionContract.reject("testFailure", "Unsafe owner was accepted")
        }
        func capture() -> ScreenshotGaoActionManifest {
            .init(kind: "request", requestID: UUID().uuidString, sourceBundleID: "com.gaoseries.FixtureSender",
                  targetBundleID: ScreenshotGaoActionContract.bundleID, action: "capture.region",
                  createdAt: ScreenshotGaoActionContract.timestamp(clock), expiresAt: ScreenshotGaoActionContract.timestamp(clock.addingTimeInterval(120)),
                  nonce: Data(repeating: 7, count: 32).base64EncodedString(), items: [], references: [], parameters: [:])
        }
        let request = capture()
        try check(ScreenshotGaoActionContract.bundleID == "com.gaoseries.GaoCaoZuo", "Capture provider must be the host")
        try check(ScreenshotGaoActionContract.owners["research.importDocuments"] == "com.academic-achievement.manager", "Research owner must match the installed receiver identity")
        for action in ScreenshotGaoActionContract.supportedActions + ["windows.overview", "desktop.openSettings"] {
            try check(ScreenshotGaoActionContract.owners[action] == ScreenshotGaoActionContract.bundleID, "Host action owner: " + action)
        }
        for (action, owner) in ScreenshotGaoActionContract.owners {
            try check(owner != ScreenshotGaoActionContract.retiredBundleID, "No action may resolve to the retired capture app")
            if action.hasPrefix("portal.") || action == "downloads.prepare" { try check(owner == "cn.mendao.launcher", "Portal owner") }
            if action.hasPrefix("files.") || action.hasPrefix("documents.") || action == "associations.manage" { try check(owner == "com.gaoseries.GaoWenJian", "File owner") }
        }
        try ScreenshotGaoActionContract.validate(request, expectedTargetBundleID: ScreenshotGaoActionContract.bundleID, now: clock)
        var retired = request; retired.targetBundleID = ScreenshotGaoActionContract.retiredBundleID
        try rejects("wrongTarget") { try ScreenshotGaoActionContract.validate(retired, expectedTargetBundleID: ScreenshotGaoActionContract.bundleID, now: clock) }
        try rejects("wrongOwner") { try ScreenshotGaoActionContract.validate(retired, expectedTargetBundleID: ScreenshotGaoActionContract.retiredBundleID, now: clock) }
        let exchange = root.appendingPathComponent("Exchange", isDirectory: true)
        let requestURL = try ScreenshotGaoActionWriter.writeRequest(action: request.action, sourceBundleID: request.sourceBundleID,
            targetBundleID: request.targetBundleID, exchangeRoot: exchange, now: clock)
        let retained = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange, now: clock)
        let ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
        _ = try ledger.receive(retained, now: clock)
        _ = try ledger.transition(requestID: retained.manifest.requestID, to: .approved, now: clock)
        _ = try ledger.transition(requestID: retained.manifest.requestID, to: .executing, now: clock)
        let resultURL = try ScreenshotGaoActionWriter.writeResult(inReplyTo: retained.manifest, status: "cancelled", provenance: [:], exchangeRoot: exchange, now: clock)
        _ = try ledger.transition(requestID: retained.manifest.requestID, to: .cancelled, resultPackageName: resultURL.lastPathComponent, now: clock)
        let result = try ScreenshotGaoActionTransport.receive(packageURL: resultURL, exchangeRoot: exchange, expectedTargetBundleID: request.sourceBundleID, now: clock)
        try check(result.manifest.sourceBundleID == ScreenshotGaoActionContract.bundleID && result.manifest.inReplyTo == retained.manifest.requestID, "Result identity and correlation")
        var oldResult = result.manifest; oldResult.sourceBundleID = ScreenshotGaoActionContract.retiredBundleID
        try rejects("wrongOwner") { try ScreenshotGaoActionContract.validate(oldResult, expectedTargetBundleID: request.sourceBundleID, now: clock) }
        let reopened = try ScreenshotGaoProcessedRequestStore(root: exchange)
        if case .duplicate(let old) = try reopened.receive(retained, now: clock) { try check(old.phase == .cancelled, "Restart must retain terminal cancellation") }
        else { throw ScreenshotGaoActionContract.reject("testFailure", "Retained request became new") }
        try rejects("alreadyProcessed") { _ = try reopened.transition(requestID: retained.manifest.requestID, to: .executing, now: clock) }
        let researchText = root.appendingPathComponent("research-import.txt")
        let researchBytes = Data("generated research import fixture\n".utf8)
        try researchBytes.write(to: researchText)
        let researchURL = try ScreenshotGaoActionWriter.writeRequest(action: "research.importDocuments", items: [.init(url: researchText, uti: "public.utf8-plain-text")],
            targetBundleID: "com.academic-achievement.manager", exchangeRoot: exchange, now: clock)
        let research = try ScreenshotGaoActionTransport.receive(packageURL: researchURL, exchangeRoot: exchange, expectedTargetBundleID: "com.academic-achievement.manager", now: clock)
        try check(research.manifest.targetBundleID == "com.academic-achievement.manager" && research.manifest.items[0].relativePath.hasPrefix("payload/"), "Research receiver identity and package-relative payload compatibility")
        try check(try Data(contentsOf: research.stagedItems[0].url) == researchBytes, "Research import fixture bytes preserved")
        try capabilityTests(in: root, check: check, rejects: rejects)
        print("Screenshot owner/transport/ledger/capability PASS: \(assertions) checks; no execution or GUI")
    }

    private static func capabilityTests(in root: URL, check: (@autoclosure () throws -> Bool, String) throws -> Void,
                                        rejects: (String?, () throws -> Void) throws -> Void) throws {
        // The caller's entire root is .noindex before this bundle-shaped fixture is created.
        let app = root.appendingPathComponent("FixtureProvider.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["CFBundleIdentifier": ScreenshotGaoActionContract.bundleID, "CFBundleShortVersionString": "1.15", "CFBundlePackageType": "APPL", "CFBundleName": "FixtureProvider"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let actions: [[String: Any]] = (ScreenshotGaoActionContract.supportedActions + ["windows.overview", "desktop.openSettings"]).map {
            ["action": $0, "parametersSchema": ["type": "object", "properties": [:], "additionalProperties": false], "requiresUserConfirmation": true]
        }
        var caps: [String: Any] = ["schemaVersion": 1, "bundleID": ScreenshotGaoActionContract.bundleID, "appVersion": "1.15", "actions": actions]
        let file = resources.appendingPathComponent("GaoCapabilities.json")
        try JSONSerialization.data(withJSONObject: caps).write(to: file)
        try check(try ScreenshotGaoCapabilityDiscovery.provider(applicationURL: app, bundleID: ScreenshotGaoActionContract.bundleID, action: "capture.region") != nil, "Merged host nine-action capability table")
        try check(try ScreenshotGaoCapabilityDiscovery.provider(applicationURL: app, bundleID: ScreenshotGaoActionContract.retiredBundleID, action: "capture.region") == nil, "No retired-bundle fallback")
        caps["actions"] = actions + [["action": "portal.focusSearch", "parametersSchema": ["type": "object", "properties": [:], "additionalProperties": false]]]
        try JSONSerialization.data(withJSONObject: caps).write(to: file)
        try rejects("invalidCapabilities") { _ = try ScreenshotGaoCapabilityDiscovery.provider(applicationURL: app, bundleID: ScreenshotGaoActionContract.bundleID, action: "capture.region") }
    }
}
