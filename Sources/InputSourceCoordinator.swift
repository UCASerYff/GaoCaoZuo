import AppKit
import Carbon
import Combine
import Foundation

// MARK: - InputSourceCoordinator

@MainActor
public final class InputSourceCoordinator: ObservableObject {
    public static let shared = InputSourceCoordinator()

    @Published public var isEnabled: Bool = false
    @Published public var rules: [InputSourceRule] = []
    @Published public private(set) var currentSource: InputSourceDescriptor?
    @Published public private(set) var lastSwitchStatus: String?

    private var appActivationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var lastManualSwitchTime: Date = Date.distantPast
    private let manualGracePeriod: TimeInterval = 2.0
    private var isPerformingAutomatedSwitch: Bool = false
    private let catalog = InputSourceCatalog.shared

    public init() {
        refreshCurrentSource()
        setupObservers()
    }

    deinit {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    public func configure(rules: [InputSourceRule], enabled: Bool) {
        self.rules = rules
        self.isEnabled = enabled
        refreshCurrentSource()
    }

    public func refreshCurrentSource() {
        self.currentSource = catalog.currentInputSource()
    }

    private func setupObservers() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            DispatchQueue.main.async {
                guard let self = self, self.isEnabled else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                self.handleApplicationActivation(bundleID: bundleID)
            }
        }
    }

    public func handleManualSourceChange() {
        if isPerformingAutomatedSwitch { return }
        lastManualSwitchTime = Date()
        refreshCurrentSource()
    }

    public func handleApplicationActivation(bundleID: String) {
        guard isEnabled else { return }

        // 1. Check for manual switch grace period to prevent feedback loops
        let elapsed = Date().timeIntervalSince(lastManualSwitchTime)
        if elapsed < manualGracePeriod {
            lastSwitchStatus = "用户手动切换后暂缓自动切换"
            return
        }

        // 2. Check for secure event input (passwords, PINs)
        if IsSecureEventInputEnabled() {
            lastSwitchStatus = "检测到安全输入状态，跳过自动切换"
            return
        }

        // 3. Find matching rule in order of priority:
        // Priority 1: Exact App Bundle ID match
        // Priority 2: Global Default rule ("*")
        var matchedRule: InputSourceRule? = nil
        for rule in rules where rule.enabled {
            if rule.appBundleID == bundleID {
                matchedRule = rule
                break
            }
        }
        if matchedRule == nil {
            matchedRule = rules.first(where: { $0.enabled && $0.isGlobalDefault })
        }

        guard let rule = matchedRule else { return }

        // 4. Verify target input source availability on current machine
        guard catalog.isSourceAvailable(sourceID: rule.targetSourceID) else {
            lastSwitchStatus = "目标输入法不可用：\(rule.targetSourceName) (\(rule.targetSourceID))"
            return
        }

        // 5. If already current source, no-op
        if let current = currentSource, current.id == rule.targetSourceID {
            return
        }

        // 6. Perform automated switch safely
        isPerformingAutomatedSwitch = true
        let success = catalog.selectInputSource(sourceID: rule.targetSourceID)
        isPerformingAutomatedSwitch = false

        if success {
            refreshCurrentSource()
            lastSwitchStatus = "已为 \(rule.appName) 自动切换至 \(rule.targetSourceName)"
        } else {
            lastSwitchStatus = "切换输入法失败：\(rule.targetSourceName)"
        }
    }

    // MARK: - Rule Management & Safe Serialization

    public func addRule(_ rule: InputSourceRule) {
        rules.removeAll { $0.appBundleID == rule.appBundleID }
        rules.append(rule)
    }

    public func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    public func exportRulesData() throws -> Data {
        struct ExportDocument: Codable {
            var format: Int = 1
            var rules: [InputSourceRule]
        }
        let doc = ExportDocument(format: 1, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    public func importRulesData(_ data: Data) throws {
        struct ExportDocument: Codable {
            var format: Int
            var rules: [InputSourceRule]
        }
        let doc = try JSONDecoder().decode(ExportDocument.self, from: data)
        guard doc.format == 1 else {
            throw DataFailure.message("不受支持的输入法规则版本：\(doc.format)")
        }
        // Merge rules without dropping existing ones
        for incoming in doc.rules {
            if let index = rules.firstIndex(where: { $0.appBundleID == incoming.appBundleID }) {
                rules[index] = incoming
            } else {
                rules.append(incoming)
            }
        }
    }
}
