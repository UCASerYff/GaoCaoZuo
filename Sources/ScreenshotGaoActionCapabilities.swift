import Foundation
import AppKit

struct ScreenshotGaoActionCapability {
    let action: String
    let parameterSchema: [String:ScreenshotGaoJSONValue]
    let details: [String:ScreenshotGaoJSONValue]
    func accepts(parameterKeys: Set<String>) -> Bool {
        guard let properties = parameterSchema["properties"]?.objectValue else { return parameterKeys.isEmpty }
        return parameterKeys.isSubset(of:Set(properties.keys))
    }
}

struct ScreenshotGaoInstalledProvider {
    let bundleID: String
    let applicationURL: URL
    let appVersion: String
    let capability: ScreenshotGaoActionCapability
}

enum ScreenshotGaoCapabilityDiscovery {
    @MainActor static func installedProvider(bundleID: String, action: String) throws -> ScreenshotGaoInstalledProvider? {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) else { return nil }
        return try provider(applicationURL:application,bundleID:bundleID,action:action)
    }
    static func provider(applicationURL: URL, bundleID: String, action: String) throws -> ScreenshotGaoInstalledProvider? {
        guard ScreenshotGaoActionContract.validBundleID(bundleID), ScreenshotGaoActionContract.knownActions.contains(action), let bundle = Bundle(url:applicationURL), bundle.bundleIdentifier == bundleID, let version = bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String, let resource = bundle.url(forResource:"GaoCapabilities",withExtension:"json") else { return nil }
        let bytes = try ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(resource),maximum:Int64(ScreenshotGaoActionContract.maximumManifestBytes))
        let json: [String:ScreenshotGaoJSONValue]
        do { json = try JSONDecoder().decode([String:ScreenshotGaoJSONValue].self,from:bytes) }
        catch { throw ScreenshotGaoActionContract.reject("invalidCapabilities","目标应用能力表损坏，不能发送动作。") }
        guard json["schemaVersion"]?.numberValue == 1, json["bundleID"]?.stringValue == bundleID, json["appVersion"]?.stringValue == version, let actions = json["actions"]?.arrayValue, actions.count <= ScreenshotGaoActionContract.knownActions.count else { throw ScreenshotGaoActionContract.reject("invalidCapabilities","目标应用能力表版本或身份不匹配。") }
        var found: ScreenshotGaoActionCapability?
        var seen = Set<String>()
        for entry in actions {
            guard let object = entry.objectValue else { throw ScreenshotGaoActionContract.reject("invalidCapabilities","目标应用动作声明无效。") }
            // V1 fixes semantics, but did not prescribe an action-entry key. Accept either spelling, never conflicting values.
            let actionName = object["action"]?.stringValue ?? object["name"]?.stringValue
            guard let name = actionName, ScreenshotGaoActionContract.knownActions.contains(name), ScreenshotGaoActionContract.owners[name] == bundleID, seen.insert(name).inserted, object["action"] == nil || object["name"] == nil || object["action"] == object["name"] else { throw ScreenshotGaoActionContract.reject("invalidCapabilities","目标应用动作声明重复或无效。") }
            let schema = object["parametersSchema"]?.objectValue ?? object["parameterSchema"]?.objectValue ?? object["parameters"]?.objectValue
            guard let schema, schema["type"]?.stringValue == "object", schema["additionalProperties"]?.boolValue == false, schema["properties"]?.objectValue != nil else { throw ScreenshotGaoActionContract.reject("invalidCapabilities","目标动作缺少严格参数声明。") }
            if name == action { found = ScreenshotGaoActionCapability(action:name,parameterSchema:schema,details:object) }
        }
        guard let capability = found else { return nil }
        return ScreenshotGaoInstalledProvider(bundleID:bundleID,applicationURL:applicationURL,appVersion:version,capability:capability)
    }
    @MainActor static func send(packageURL: URL, to provider: ScreenshotGaoInstalledProvider, completion: @escaping (Error?) -> Void) {
        // Recheck the exact installed bundle immediately before the explicit NSWorkspace handoff.
        do {
            guard let current = try self.provider(applicationURL:provider.applicationURL,bundleID:provider.bundleID,action:provider.capability.action), current.appVersion == provider.appVersion else { throw ScreenshotGaoActionContract.reject("providerChanged","目标应用已变化，请重新检查能力。") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.open([packageURL],withApplicationAt:provider.applicationURL,configuration:config) { _,error in completion(error) }
        } catch { completion(error) }
    }
}
