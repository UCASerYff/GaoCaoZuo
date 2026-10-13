import AppKit
import Carbon
import Foundation

// MARK: - InputSourceDescriptor

public struct InputSourceDescriptor: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var isSelectCapable: Bool
    public var isEnabled: Bool
    public var category: String
    public var shortLabel: String

    public init(id: String, name: String, isSelectCapable: Bool, isEnabled: Bool, category: String, shortLabel: String = "") {
        self.id = id
        self.name = name
        self.isSelectCapable = isSelectCapable
        self.isEnabled = isEnabled
        self.category = category
        self.shortLabel = shortLabel.isEmpty ? Self.deriveShortLabel(id: id, name: name) : shortLabel
    }

    public static func deriveShortLabel(id: String, name: String) -> String {
        if id.contains("SCIM") || id.contains("Pinyin") || name.contains("拼音") || name.contains("简体") { return "拼" }
        if id.contains("TCIM") || name.contains("繁体") || name.contains("注音") { return "繁" }
        if id.contains("Japanese") || name.contains("日") { return "あ" }
        if id.contains("ABC") || id.contains("US") { return "ABC" }
        return String(name.prefix(2))
    }
}

// MARK: - InputSourceRule

public struct InputSourceRule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var appBundleID: String
    public var appName: String
    public var targetSourceID: String
    public var targetSourceName: String
    public var enabled: Bool

    public init(id: UUID = UUID(), appBundleID: String, appName: String = "", targetSourceID: String, targetSourceName: String = "", enabled: Bool = true) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName.isEmpty ? appBundleID : appName
        self.targetSourceID = targetSourceID
        self.targetSourceName = targetSourceName.isEmpty ? targetSourceID : targetSourceName
        self.enabled = enabled
    }

    public var isGlobalDefault: Bool {
        appBundleID == "*" || appBundleID.isEmpty
    }
}

// MARK: - InputSourceCatalog

public final class InputSourceCatalog {
    public static let shared = InputSourceCatalog()

    public init() {}

    private func getProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? String
    }

    private func getBoolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
        return (Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
    }

    public func currentInputSource() -> InputSourceDescriptor? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let id = getProperty(current, kTISPropertyInputSourceID) ?? ""
        let name = getProperty(current, kTISPropertyLocalizedName) ?? id
        let isSelectable = getBoolProperty(current, kTISPropertyInputSourceIsSelectCapable)
        let isEnabled = getBoolProperty(current, kTISPropertyInputSourceIsEnabled)
        let category = getProperty(current, kTISPropertyInputSourceCategory) ?? ""
        return InputSourceDescriptor(id: id, name: name, isSelectCapable: isSelectable, isEnabled: isEnabled, category: category)
    }

    public func availableKeyboardInputSources() -> [InputSourceDescriptor] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        var descriptors: [InputSourceDescriptor] = []
        for source in list {
            let isSelectable = getBoolProperty(source, kTISPropertyInputSourceIsSelectCapable)
            let isEnabled = getBoolProperty(source, kTISPropertyInputSourceIsEnabled)
            let category = getProperty(source, kTISPropertyInputSourceCategory) ?? ""
            // Keyboard input sources
            if isSelectable && isEnabled {
                let id = getProperty(source, kTISPropertyInputSourceID) ?? ""
                let name = getProperty(source, kTISPropertyLocalizedName) ?? id
                guard !id.isEmpty else { continue }
                descriptors.append(InputSourceDescriptor(id: id, name: name, isSelectCapable: isSelectable, isEnabled: isEnabled, category: category))
            }
        }
        return descriptors
    }

    public func isSourceAvailable(sourceID: String) -> Bool {
        availableKeyboardInputSources().contains { $0.id == sourceID }
    }

    @discardableResult
    public func selectInputSource(sourceID: String) -> Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for source in list {
            let id = getProperty(source, kTISPropertyInputSourceID) ?? ""
            if id == sourceID {
                let status = TISSelectInputSource(source)
                return status == noErr
            }
        }
        return false
    }
}
