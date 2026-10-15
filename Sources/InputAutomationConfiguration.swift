import Foundation
import ApplicationServices

/// Stored with the application's settings; absence in an older document means disabled.
public struct AutoInputConfiguration: Codable, Equatable {
    public var schemaVersion = 1
    public var enabled = false
    public var manualOverrideSeconds: TimeInterval = 5
    public var manualPrimarySourceID: String?
    public var manualSecondarySourceID: String?
    public var rules: [InputSourceRule] = []

    public init() {}

    public func validate() throws {
        guard schemaVersion == 1 else { throw InputAutomationError.invalid("不支持的自动输入法配置版本；原配置未覆盖。") }
        guard manualOverrideSeconds.isFinite, (0...3600).contains(manualOverrideSeconds), rules.count <= 512,
              Set(rules.map(\.id)).count == rules.count else { throw InputAutomationError.invalid("自动输入法配置数量、标识或手动切换暂缓时间无效。") }
        for source in [manualPrimarySourceID, manualSecondarySourceID].compactMap({ $0 }) {
            guard !source.isEmpty, source.utf8.count <= 512, !source.contains("\0") else {
                throw InputAutomationError.invalid("请明确选择有效的手动切换输入源。")
            }
        }
        if let primary = manualPrimarySourceID, let secondary = manualSecondarySourceID, primary == secondary {
            throw InputAutomationError.invalid("手动切换的两个输入源必须不同。")
        }
        for rule in rules {
            guard !rule.targetSourceID.isEmpty, rule.targetSourceID.utf8.count <= 512,
                  rule.appBundleID.utf8.count <= 512, rule.appName.utf8.count <= 1024,
                  rule.targetSourceName.utf8.count <= 1024, (-1000...1000).contains(rule.priority),
                  rule.focusedRole.map({ Self.allowedFocusedRoles.contains($0) }) ?? true else {
                throw InputAutomationError.invalid("输入法规则缺少明确目标或包含不支持的输入区域。")
            }
        }
    }

    public static let allowedFocusedRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private enum CodingKeys: String, CodingKey { case schemaVersion, enabled, manualOverrideSeconds, manualPrimarySourceID, manualSecondarySourceID, rules }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        manualOverrideSeconds = try c.decode(TimeInterval.self, forKey: .manualOverrideSeconds)
        manualPrimarySourceID = try c.decodeIfPresent(String.self, forKey: .manualPrimarySourceID)
        manualSecondarySourceID = try c.decodeIfPresent(String.self, forKey: .manualSecondarySourceID)
        rules = try c.decode([InputSourceRule].self, forKey: .rules)
        try validate()
    }
}

public enum InputAutomationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum InputSourceRulePolicy {
    enum Resolution: Equatable { case none, rule(UUID), conflict([UUID]) }

    /// Specificity wins first (App+region, App, global+region, global), then explicit priority.
    /// Equal-rank rules selecting different sources are blocked, never silently first-wins.
    static func resolve(_ rules: [InputSourceRule], bundleID: String, focusedRole: String?) -> Resolution {
        let matches = rules.filter { $0.enabled && ($0.isGlobalDefault || $0.appBundleID == bundleID)
            && ($0.focusedRole == nil || $0.focusedRole == focusedRole) }
        func rank(_ r: InputSourceRule) -> Int { (r.isGlobalDefault ? 0 : 2) + (r.focusedRole == nil ? 0 : 1) }
        guard let bestRank = matches.map(rank).max() else { return .none }
        let specific = matches.filter { rank($0) == bestRank }
        guard let bestPriority = specific.map(\.priority).max() else { return .none }
        let finalists = specific.filter { $0.priority == bestPriority }
        guard Set(finalists.map(\.targetSourceID)).count == 1 else { return .conflict(finalists.map(\.id)) }
        return .rule(finalists[0].id)
    }
}

struct InputSourceSwitchPolicy {
    enum Composition { case clear, active, unknown }
    enum Decision: Equatable { case allow, disabled, secure, manualOverride, typing, composition, unknownComposition }
    static func decide(enabled: Bool, secure: Bool, now: TimeInterval, lastManual: TimeInterval?,
                       grace: TimeInterval, lastTyping: TimeInterval?, composition: Composition,
                       sourceIsIME: Bool, editable: Bool) -> Decision {
        guard enabled else { return .disabled }
        guard !secure else { return .secure }
        if let lastManual, now - lastManual < grace { return .manualOverride }
        if let lastTyping, now - lastTyping < 0.75 { return .typing }
        if composition == .active { return .composition }
        if composition == .unknown && sourceIsIME && editable { return .unknownComposition }
        return .allow
    }
}

/// Distributed TIS notifications are asynchronous, so an on-stack Bool is insufficient.
struct InputSourceChangeTracker {
    enum Observation: Equatable { case unchanged, automated, external }
    var observedID: String?
    var lastExternalChange: TimeInterval?
    private var expected: (id: String, expires: TimeInterval)?
    init(observedID: String? = nil) { self.observedID = observedID }
    mutating func expect(_ id: String, now: TimeInterval) { expected = (id, now + 1.5) }
    mutating func cancelExpected() { expected = nil }
    mutating func observe(_ id: String?, now: TimeInterval) -> Observation {
        guard let id else { expected = nil; return .unchanged }
        let previous = observedID; observedID = id
        if let expected, now <= expected.expires, expected.id == id {
            self.expected = nil; return .automated
        }
        expected = nil
        guard let previous, previous != id else { return .unchanged }
        lastExternalChange = now; return .external
    }
}

public enum FlyKeyTriggerModifier: String, Codable, CaseIterable, Identifiable {
    case command, option, control, shift
    public var id: String { rawValue }
    public var symbol: String { switch self { case .command: return "⌘"; case .option: return "⌥"; case .control: return "⌃"; case .shift: return "⇧" } }
    var mask: UInt64 { switch self { case .command: return 1 << 20; case .option: return 1 << 19; case .control: return 1 << 18; case .shift: return 1 << 17 } }
    var keyCodes: Set<UInt16> { switch self { case .command: return [54,55]; case .option: return [58,61]; case .control: return [59,62]; case .shift: return [56,60] } }
}

public struct FlyKeyConfiguration: Codable, Equatable {
    public var schemaVersion = 1
    public var enabled = false
    public var triggerModifier: FlyKeyTriggerModifier = .command
    public var doubleTapInterval: TimeInterval = 0.35
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1, doubleTapInterval.isFinite, (0.15...0.8).contains(doubleTapInterval) else {
            throw InputAutomationError.invalid("不支持的快捷键速查配置版本或双击间隔；已停止监听。")
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, enabled, triggerModifier, doubleTapInterval }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        triggerModifier = try c.decode(FlyKeyTriggerModifier.self, forKey: .triggerModifier)
        doubleTapInterval = try c.decode(TimeInterval.self, forKey: .doubleTapInterval)
        try validate()
    }
}

/// A non-consuming detector. Other keys, mixed modifiers, long holds and changing sides cancel it.
struct FlyKeyTapDetector {
    private var pressedAt: TimeInterval?
    private var firstRelease: TimeInterval?
    private var keyCode: UInt16?
    private var completedFirstTap = false
    mutating func reset() { self = Self() }
    mutating func flagsChanged(key: UInt16, flags: UInt64, now: TimeInterval, modifier: FlyKeyTriggerModifier,
                               interval: TimeInterval, secure: Bool = false) -> Bool {
        let relevant = flags & UInt64(0x1e0000 | 0x800000) // Shift/Control/Option/Command/Fn; Caps Lock is irrelevant.
        guard !secure, modifier.keyCodes.contains(key), relevant == 0 || relevant == modifier.mask else { reset(); return false }
        if relevant == modifier.mask {
            guard pressedAt == nil else { return false }
            if keyCode != key || firstRelease.map({ now - $0 > interval || now < $0 }) ?? false { reset() }
            keyCode = key; pressedAt = now
            return false
        }
        guard let down = pressedAt, keyCode == key, now >= down, now - down <= interval else { reset(); return false }
        pressedAt = nil
        if completedFirstTap, let firstRelease, now - firstRelease <= interval, now >= firstRelease { reset(); return true }
        completedFirstTap = true; firstRelease = now
        return false
    }
}

enum FlyKeyShortcutFormatter {
    /// AXAttributeConstants.h: Shift=1, Option=2, Control=4, NoCommand=8.
    static func format(character: String, modifiers: Int) -> String {
        guard modifiers >= 0, modifiers & ~15 == 0, !character.isEmpty else { return "" }
        let flags = AXMenuItemModifiers(rawValue: UInt32(modifiers))
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (!flags.contains(.noCommand) ? "⌘" : "") + character.uppercased()
    }
}
