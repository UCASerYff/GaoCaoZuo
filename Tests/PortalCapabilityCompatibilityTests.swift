#if PORTAL_CAPABILITY_COMPATIBILITY_TESTS
import Foundation
import Darwin

/// Exercises the production capability loader with complete synthetic and actual public Portal tables.
/// App resources and generated/candidate host metadata are read-only; no NSWorkspace lookup or launch occurs.
private enum PortalCapabilityCompatibilityFixtureSuite {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Fixture {
        let base: URL
        var app: URL { base.appendingPathComponent("SyntheticProvider.app") }
        var info: URL { app.appendingPathComponent("Contents/Info.plist") }
        var capabilities: URL { app.appendingPathComponent("Contents/Resources/GaoCapabilities.json") }
    }
    static let portalID = "cn.mendao.launcher"
    static let portalVersion = "1.17"
    static let actionNames = ["portal.openSite", "portal.openWorkspace", "portal.focusSearch", "portal.proposeSite",
                              "portal.prepareDownload", "downloads.prepare"]
    static var assertions = 0
    static var rejectedCases = 0
    static var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else { throw Failure(message: "PortalCapabilityCompatibility: " + message) }
    }
    static func rejected(_ label: String, _ operation: () throws -> Void) throws {
        rejectedCases += 1
        var denied = false
        do { try operation() } catch { denied = true }
        try expect(denied, label)
    }
    static func put(_ bytes: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ url: URL) throws -> Data {
        let fd = try GaoActionFiles.openRegular(url, owned: false); defer { close(fd) }
        return try GaoActionFiles.read(fd: fd, maximum: GaoActionV1.maximumManifestBytes, owned: false)
    }
    static func fixture() throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PortalCapability-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return Fixture(base: base)
    }
    static func cleanup(_ f: Fixture) { try? FileManager.default.removeItem(at: f.base) }
    static func info(_ f: Fixture, bundleID: String = portalID, version: String = portalVersion) throws {
        try put(PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"], format: .xml, options: 0), f.info)
    }
    static func write(_ f: Fixture, _ value: [String: Any]) throws {
        try put(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]), f.capabilities)
    }
    static func action(_ name: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["action": name, "items": ["maxCount": 0], "references": ["maxCount": 0],
         "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }
    static func portalTable() -> [String: Any] {
        let urls: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 32,
                                   "items": ["type": "string", "format": "uri"]]
        return ["schemaVersion": 1, "bundleID": portalID, "appVersion": portalVersion, "actions": [
            action("portal.openSite", properties: ["siteID": ["type": "string"], "browserID": ["type": "string"]], required: ["siteID"]),
            action("portal.openWorkspace", properties: ["workspaceID": ["type": "string"]], required: ["workspaceID"]),
            action("portal.focusSearch", properties: ["query": ["type": "string"]], required: []),
            action("portal.proposeSite", properties: ["url": ["type": "string", "format": "uri"], "title": ["type": "string"]], required: ["url"]),
            action("portal.prepareDownload", properties: ["urls": urls], required: ["urls"]),
            action("downloads.prepare", properties: ["urls": urls, "mediaType": ["type": "string", "enum": ["file"]]], required: ["urls"])
        ]]
    }
    static func validParameters() -> [[String: Any]] {
        [["siteID": "synthetic-site", "browserID": "synthetic-browser"], ["workspaceID": "synthetic-workspace"],
         ["query": "Synthetic query"], ["url": "https://example.invalid/synthetic", "title": "Synthetic proposal"],
         ["urls": ["https://example.invalid/synthetic"]], ["urls": ["https://example.invalid/synthetic"], "mediaType": "file"]]
    }
    static func load(_ f: Fixture) throws -> GaoActionProviderCapabilities {
        try GaoActionProviderCapabilities.load(appURL: f.app, bundleID: portalID)
    }
    static func rejectedTable(_ f: Fixture, label: String, change: (inout [String: Any]) throws -> Void) throws {
        var value = portalTable(); try change(&value); try write(f, value)
        try rejected(label) { _ = try load(f) }
    }

    static func completePortalTable() throws {
        let f = try fixture(); defer { cleanup(f) }
        try info(f); try write(f, portalTable())
        let capabilities = try load(f)
        try expect(capabilities.actions.map(\.action) == actionNames, "all six Portal parameters declarations load together")
        for (offset, name) in actionNames.enumerated() {
            let parameters = validParameters()[offset]
            try capabilities.require(action: name, parameters: parameters, items: false, references: false)
            try expect(true, name + " accepts its declared synthetic parameters")
            try rejected(name + " still forbids input files") { try capabilities.require(action: name, parameters: parameters, items: true, references: false) }
            try rejected(name + " still forbids references") { try capabilities.require(action: name, parameters: parameters, items: false, references: true) }
        }
        try rejected("download normalization retains the fixed HTTP contract") {
            try capabilities.require(action: "downloads.prepare", parameters: ["urls": ["file:///synthetic/input"]], items: false, references: false)
        }
    }

    static func actualPortalTable(appURL: URL) throws {
        let source = appURL.appendingPathComponent("Contents/Resources/GaoCapabilities.json")
        let originalBytes = try read(source)
        try expect(GaoActionV1.calculateSHA256(data: originalBytes) == "bbd5fe2058f87bd44e775c94fed11ce7ed6c1a6fa6c408b907c80baf07569beb",
                   "actual formal Portal 1.17 complete public capability bytes match the coordinator's contract")
        let original = try GaoActionProviderCapabilities.load(appURL: appURL, bundleID: portalID)
        let f = try fixture(); defer { cleanup(f) }
        try put(read(appURL.appendingPathComponent("Contents/Info.plist")), f.info)
        try put(originalBytes, f.capabilities)
        let copied = try load(f)
        for capabilities in [original, copied] {
            try expect(capabilities.appVersion == portalVersion, "actual and isolated-copy Portal loaders bind version 1.17")
            try expect(capabilities.actions.map(\.action) == actionNames, "actual and isolated-copy loaders accept the entire six-action table")
            for (offset, name) in actionNames.enumerated() {
                try capabilities.require(action: name, parameters: validParameters()[offset], items: false, references: false)
                try expect(true, "actual Portal table retains the declared parameter contract for " + name)
            }
        }
        try expect(try read(source) == originalBytes, "direct read-only production loading leaves the formal Portal resource unchanged")
    }

    static func rejectionBoundaries() throws {
        let f = try fixture(); defer { cleanup(f) }; try info(f)
        for offset in actionNames.indices {
            try rejectedTable(f, label: actionNames[offset] + " cannot mix both parameter dialects") { value in
                var actions = value["actions"] as! [[String: Any]]
                actions[offset]["parametersSchema"] = actions[offset]["parameters"]
                value["actions"] = actions
            }
            for key in ["items", "references"] {
                try rejectedTable(f, label: actionNames[offset] + " cannot declare nonzero " + key) { value in
                    var actions = value["actions"] as! [[String: Any]]
                    actions[offset][key] = ["maxCount": 1]; value["actions"] = actions
                }
            }
        }
        try rejectedTable(f, label: "unknown parameters action is not added to the compatibility dialect") { value in
            var actions = value["actions"] as! [[String: Any]]; actions[0]["action"] = "portal.futureAction"; value["actions"] = actions
        }
        try rejectedTable(f, label: "non-Portal action cannot use the Portal parameters dialect") { value in
            var actions = value["actions"] as! [[String: Any]]; actions[0]["action"] = "capture.region"; value["actions"] = actions
        }
        try rejectedTable(f, label: "capability table owner must match Info.plist") { $0["bundleID"] = "com.gaoseries.GaoCaoZuo" }
        try rejectedTable(f, label: "capability table schema must remain v1") { $0["schemaVersion"] = 2 }
        try rejectedTable(f, label: "known action still belongs to its actual provider") { value in
            value["actions"] = [["action": "capture.region", "parametersSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
                                  "supportsItems": false, "supportsReferences": false]]
        }
        try rejectedTable(f, label: "unknown parameter key is rejected before use") { value in
            var actions = value["actions"] as! [[String: Any]], schema = actions[0]["parameters"] as! [String: Any]
            var properties = schema["properties"] as! [String: Any]; properties["shell"] = ["type": "string"]
            schema["properties"] = properties; actions[0]["parameters"] = schema; value["actions"] = actions
        }
        for key in ["items", "references"] {
            try rejectedTable(f, label: key + " maxCount cannot be a Boolean zero") { value in
                var actions = value["actions"] as! [[String: Any]]; actions[0][key] = ["maxCount": false]; value["actions"] = actions
            }
            try rejectedTable(f, label: key + " cannot hide a future constraint") { value in
                var actions = value["actions"] as! [[String: Any]]; actions[0][key] = ["maxCount": 0, "futureConstraint": true]; value["actions"] = actions
            }
        }
        try write(f, portalTable()); try info(f, version: "synthetic-changed-version")
        try rejected("loader reads current Info.plist version without a stale Bundle cache") { _ = try load(f) }
    }

    static func hostResultReceiverResource(hostInfoURL: URL) throws {
        let resourceURL = project.appendingPathComponent("Resources/DownloadGaoCapabilities.json")
        let bytes = try read(resourceURL)
        guard let resource = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let hostInfo = try PropertyListSerialization.propertyList(from: read(hostInfoURL), format: nil) as? [String: Any] else {
            throw Failure(message: "Result receiver resource or generated host Info.plist is not an object")
        }
        let version = String(decoding: try read(project.appendingPathComponent("VERSION")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(Set(resource.keys) == Set(["schemaVersion", "bundleID", "appVersion", "actions", "resultActions"]), "receiver resource contains only its explicit result-reception contract")
        try expect(resource["bundleID"] as? String == GaoActionV1.ownBundleID && hostInfo["CFBundleIdentifier"] as? String == GaoActionV1.ownBundleID,
                   "receiver resource and actual generated host metadata retain the host identity")
        try expect(resource["appVersion"] as? String == version && hostInfo["CFBundleShortVersionString"] as? String == version,
                   "receiver resource matches project and actual generated host versions")
        try expect((resource["actions"] as? [Any])?.isEmpty == true, "result receiver advertises no download provider actions")
        try expect(resource["resultActions"] as? [String] == ["downloads.prepare"], "receiver records only the actual accepted download result action")
        let types = hostInfo["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        try expect(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains(GaoActionV1.utType) == true },
                   "actual generated host metadata declares the action-package UTI required by Portal result reception")
        // Feed the real resource bytes to the same production provider loader too: the empty actions
        // table may be read but must never make the result receiver a downloads.prepare provider.
        let f = try fixture(); defer { cleanup(f) }
        try put(read(hostInfoURL), f.info); try put(bytes, f.capabilities)
        let loaded = try GaoActionProviderCapabilities.load(appURL: f.app, bundleID: GaoActionV1.ownBundleID)
        try expect(loaded.actions.isEmpty, "production provider decoding preserves an empty receiver action table")
        try rejected("result receipt compatibility does not authorize providing downloads.prepare") {
            try loaded.require(action: "downloads.prepare", parameters: ["urls": ["https://example.invalid/synthetic"]], items: false, references: false)
        }
        try expect(try read(resourceURL) == bytes, "resource contract checks preserve the exact source bytes")
    }

    static func run(hostInfoURL: URL, portalAppURL: URL) throws -> (Int, Int) {
        assertions = 0; rejectedCases = 0
        try completePortalTable(); try actualPortalTable(appURL: portalAppURL)
        try rejectionBoundaries(); try hostResultReceiverResource(hostInfoURL: hostInfoURL)
        return (assertions, rejectedCases)
    }
}

@main enum PortalCapabilityCompatibilityTestMain {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard [3, 5].contains(args.count), args[1] == "--host-info-plist", args[2].hasPrefix("/"),
                  args.count == 3 || (args[3] == "--portal-app" && args[4].hasPrefix("/")) else {
                throw PortalCapabilityCompatibilityFixtureSuite.Failure(message: "Usage: portal-capability-tests --host-info-plist <absolute generated/candidate host Info.plist> [--portal-app <formal Portal app>]")
            }
            let portal = URL(fileURLWithPath: args.count == 5 ? args[4] : "/Applications/搞门户.app")
            let (checks, boundaries) = try PortalCapabilityCompatibilityFixtureSuite.run(hostInfoURL: URL(fileURLWithPath: args[2]), portalAppURL: portal)
            print("PortalCapabilityCompatibility: \(checks) assertions passed; synthetic and actual full Portal 1.17 tables; \(boundaries) rejected cases; generated host identity/version/UTI and result receiver resource checked; no app launch, provider dispatch, network or real business data.")
        } catch { FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
#endif
