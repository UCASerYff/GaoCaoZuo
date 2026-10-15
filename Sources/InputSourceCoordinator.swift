import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation

private final class AutoInputFocusCallbackBox {
    weak var owner: InputSourceCoordinator?
    init(_ owner: InputSourceCoordinator) { self.owner = owner }
}

/// Uses the existing input controller for typing activity; never creates an event tap.
@MainActor
public final class InputSourceCoordinator: ObservableObject {
    public static let shared = InputSourceCoordinator()
    @Published public var isEnabled = false { didSet { if !applying { editedConfiguration() } } }
    @Published public private(set) var rules: [InputSourceRule] = []
    @Published public private(set) var configuration = AutoInputConfiguration()
    @Published public private(set) var currentSource: InputSourceDescriptor?
    @Published public private(set) var lastSwitchStatus: String?
    @Published public private(set) var unavailableRules: [UUID: String] = [:]

    private let catalog = InputSourceCatalog.shared
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var focusObserver: AXObserver?
    private var focusApplication: AXUIElement?
    private var focusBox: AutoInputFocusCallbackBox?
    private var observedPID: pid_t?
    private var healthTimer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var lastTyping: TimeInterval?
    private var sourceChanges = InputSourceChangeTracker()
    private var applying = false
    private var sleeping = false
    private var onConfigurationChange: ((AutoInputConfiguration) -> Void)?
    private var retryCount = 0
    private var excludedApps: Set<String> = []

    /// Construction has no observation, permission or input-source-changing side effects.
    public init() {}

    deinit {
        healthTimer?.invalidate(); pendingWork?.cancel()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        if let focusObserver {
            if let focusApplication { _ = AXObserverRemoveNotification(focusObserver, focusApplication, kAXFocusedUIElementChangedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
    }

    public func configure(configuration value: AutoInputConfiguration,
                          onConfigurationChange: ((AutoInputConfiguration) -> Void)? = nil,
                          excludedApps: [String] = []) {
        do { try value.validate() }
        catch { stop(); lastSwitchStatus = error.localizedDescription; return }
        stopObserving()
        self.onConfigurationChange = onConfigurationChange
        self.excludedApps = Set(excludedApps)
        applying = true; configuration = value; isEnabled = value.enabled; rules = value.rules; applying = false
        refreshCurrentSource()
        sourceChanges.observedID = currentSource?.id
        if isEnabled { startObserving() }
    }

    public func configure(rules: [InputSourceRule], enabled: Bool) {
        var next = configuration; next.rules = rules; next.enabled = enabled
        configure(configuration: next, onConfigurationChange: onConfigurationChange, excludedApps: Array(excludedApps))
    }

    /// Runtime shutdown preserves the saved choice. Called on application exit, not a settings reset.
    public func stop() { stopObserving() }

    public func refreshCurrentSource() {
        currentSource = catalog.currentInputSource()
        if isEnabled, !workspaceObservers.isEmpty,
           sourceChanges.observe(currentSource?.id, now: ProcessInfo.processInfo.systemUptime) == .external {
            invalidatePending()
            lastSwitchStatus = "输入源由用户或外部应用更改；按设置暂缓自动切换。"
        }
        let available = Set(catalog.availableKeyboardInputSources().map(\.id))
        unavailableRules = Dictionary(uniqueKeysWithValues: rules.filter { !available.contains($0.targetSourceID) }
            .map { ($0.id, "目标输入源未启用或已移除；规则保留，未替换为其他语言。") })
    }

    private func editedConfiguration() {
        var next = configuration; next.enabled = isEnabled; next.rules = rules
        do { try next.validate() }
        catch { lastSwitchStatus = error.localizedDescription; return }
        configuration = next
        if isEnabled { if workspaceObservers.isEmpty { startObserving() } }
        else { stopObserving() }
        onConfigurationChange?(next)
    }

    public func updateConfiguration(_ next: AutoInputConfiguration) throws {
        try next.validate()
        configure(configuration: next, onConfigurationChange: onConfigurationChange, excludedApps: Array(excludedApps))
        onConfigurationChange?(next)
    }

    public func addRule(_ rule: InputSourceRule) {
        var next = configuration
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[index] = rule }
        else { next.rules.append(rule) }
        do { try updateConfiguration(next) } catch { lastSwitchStatus = error.localizedDescription }
    }
    public func removeRule(id: UUID) {
        var next = configuration; next.rules.removeAll { $0.id == id }
        do { try updateConfiguration(next) } catch { lastSwitchStatus = error.localizedDescription }
    }

    private func startObserving() {
        guard isEnabled, workspaceObservers.isEmpty else { return }
        sleeping = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self, let bundleID else { return }
                self.handleApplicationActivation(bundleID: bundleID)
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.sleeping = true; self?.invalidatePending(); self?.removeFocusObserver()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled else { return }
                self.sleeping = false; self.sourceChanges.cancelExpected(); self.refreshCurrentSource(); self.attachFocusObserver()
                self.lastSwitchStatus = "已从睡眠恢复；等待下一次应用或输入区域切换。"
            }
        })
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.handleManualSourceChange() }
        })
        distributedObservers.append(distributed.addObserver(forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshCurrentSource() }
        })
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, !self.sleeping else { return }
                if !AXIsProcessTrusted() {
                    self.invalidatePending(); self.removeFocusObserver(); self.lastSwitchStatus = "辅助功能权限不可用，已暂停自动切换。"
                } else if self.focusObserver == nil { self.attachFocusObserver() }
            }
        }
        attachFocusObserver()
        lastSwitchStatus = "已启用；等待应用或输入区域切换。"
    }

    private func invalidatePending() { generation &+= 1; pendingWork?.cancel(); pendingWork = nil; retryCount = 0 }
    private func stopObserving() {
        invalidatePending(); sourceChanges.cancelExpected()
        healthTimer?.invalidate(); healthTimer = nil
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        workspaceObservers = []; distributedObservers = []; removeFocusObserver()
    }
    private func removeFocusObserver() {
        if let focusObserver {
            if let focusApplication { _ = AXObserverRemoveNotification(focusObserver, focusApplication, kAXFocusedUIElementChangedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil; focusApplication = nil; focusBox = nil; observedPID = nil
    }
    private func attachFocusObserver() {
        guard isEnabled, !sleeping, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        if excludedApps.contains(app.bundleIdentifier ?? "") { removeFocusObserver(); return }
        if observedPID == app.processIdentifier, focusObserver != nil { return }
        removeFocusObserver()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let box = Unmanaged<AutoInputFocusCallbackBox>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak box] in box?.owner?.handleFocusChange() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier), box = AutoInputFocusCallbackBox(self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString,
                                        Unmanaged.passUnretained(box).toOpaque()) == .success else { return }
        focusApplication = element; focusObserver = observer; focusBox = box; observedPID = app.processIdentifier
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    public func handleManualSourceChange() {
        guard isEnabled, !workspaceObservers.isEmpty else { return }
        refreshCurrentSource()
    }

    public func handleInputActivity(type: CGEventType, event: CGEvent) {
        guard isEnabled, !sleeping, !workspaceObservers.isEmpty else { return }
        if IsSecureEventInputEnabled() { invalidatePending(); return }
        if type == .keyDown { lastTyping = ProcessInfo.processInfo.systemUptime }
    }

    public func handleApplicationActivation(bundleID: String) {
        guard isEnabled, !sleeping, !workspaceObservers.isEmpty, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        invalidatePending(); attachFocusObserver(); applyRule(bundleID: bundleID)
    }
    private func handleFocusChange() {
        guard isEnabled, !sleeping, let app = NSWorkspace.shared.frontmostApplication,
              observedPID == app.processIdentifier, let bundle = app.bundleIdentifier else { return }
        invalidatePending(); applyRule(bundleID: bundle)
    }

    private struct FocusState {
        let element: AXUIElement
        var role: String?
        var secure = false
        var editable = false
        var composition: InputSourceSwitchPolicy.Composition = .unknown
    }
    private func focusState(pid: pid_t) -> FocusState? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self); AXUIElementSetMessagingTimeout(element, 0.1)
        func value(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let role = value(kAXRoleAttribute) as? String, subrole = value(kAXSubroleAttribute) as? String
        let secure = subrole == (kAXSecureTextFieldSubrole as String) || role == (kAXSecureTextFieldSubrole as String)
        // Do not request text, values, selections or marked content from a password field.
        if secure { return FocusState(element: element, role: role, secure: true, editable: true) }
        let effectiveRole = AutoInputConfiguration.allowedFocusedRoles.contains(subrole ?? "") ? subrole : role
        var result = FocusState(element: element, role: effectiveRole, editable: AutoInputConfiguration.allowedFocusedRoles.contains(effectiveRole ?? ""))
        // Public AXWebConstants.h contract: NULL means no provisional IME text. Unsupported is unknown.
        var names: CFArray?
        let markedKey = "AXTextInputMarkedTextMarkerRange"
        if AXUIElementCopyAttributeNames(element, &names) == .success, (names as? [String])?.contains(markedKey) == true {
            var marked: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, markedKey as CFString, &marked)
            if status == .success { result.composition = marked == nil ? .clear : .active }
            else if status == .noValue { result.composition = .clear }
        }
        return result
    }

    private func retry(bundleID: String) {
        guard retryCount < 12 else { return }
        retryCount += 1
        let captured = generation
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == captured, self.isEnabled, !self.sleeping else { return }
            self.applyRule(bundleID: bundleID)
        }
        pendingWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func applyRule(bundleID: String) {
        let initialGeneration = generation
        guard isEnabled, !sleeping, !excludedApps.contains(bundleID), let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.bundleIdentifier == bundleID,
              let identity = WindowProcessIdentity.capture(pid: app.processIdentifier, launchDate: app.launchDate) else { return }
        if IsSecureEventInputEnabled() { lastSwitchStatus = "安全输入状态下不自动切换输入法。"; return }
        guard let focus = focusState(pid: app.processIdentifier) else {
            lastSwitchStatus = "无法确认输入区域安全状态；已跳过自动切换。"; return
        }
        refreshCurrentSource()
        let decision = InputSourceSwitchPolicy.decide(enabled: isEnabled, secure: focus.secure,
            now: ProcessInfo.processInfo.systemUptime, lastManual: sourceChanges.lastExternalChange,
            grace: configuration.manualOverrideSeconds, lastTyping: lastTyping,
            composition: focus.composition, sourceIsIME: currentSource?.isInputMethod == true, editable: focus.editable)
        switch decision {
        case .allow: break
        case .typing, .composition:
            lastSwitchStatus = "正在输入或组合文字，延后自动切换。"; retry(bundleID: bundleID); return
        case .unknownComposition:
            lastSwitchStatus = "当前输入法为组合输入，目标未公开组合状态；为保护未提交文字已跳过。"; return
        case .manualOverride: lastSwitchStatus = "手动切换暂缓期内，保留当前输入源。"; return
        case .secure: lastSwitchStatus = "密码输入区域中不自动切换输入法。"; return
        case .disabled: return
        }
        let resolved = InputSourceRulePolicy.resolve(rules, bundleID: bundleID, focusedRole: focus.role)
        guard case .rule(let ruleID) = resolved else {
            if case .conflict = resolved { lastSwitchStatus = "同优先级输入法规则冲突，请先修改规则。" }
            return
        }
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
        guard unavailableRules[rule.id] == nil else { lastSwitchStatus = "目标输入源不可用；保留原规则，未选择替代输入源。"; return }
        guard currentSource?.id != rule.targetSourceID else { return }
        // AX/TIS reads are separate IPC. Recheck identity, foreground and secure input immediately before selection.
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID,
              !excludedApps.contains(bundleID),
              identity.matches(WindowProcessIdentity.capture(pid: front.processIdentifier, launchDate: front.launchDate)),
              !IsSecureEventInputEnabled(), generation == initialGeneration,
              let confirmedFocus = focusState(pid: front.processIdentifier),
              CFEqual(focus.element, confirmedFocus.element), !confirmedFocus.secure,
              InputSourceSwitchPolicy.decide(enabled: isEnabled, secure: confirmedFocus.secure,
                  now: ProcessInfo.processInfo.systemUptime, lastManual: sourceChanges.lastExternalChange,
                  grace: configuration.manualOverrideSeconds, lastTyping: lastTyping,
                  composition: confirmedFocus.composition, sourceIsIME: currentSource?.isInputMethod == true,
                  editable: confirmedFocus.editable) == .allow,
              catalog.currentInputSource()?.id == currentSource?.id else { return }
        let captured = generation
        sourceChanges.expect(rule.targetSourceID, now: ProcessInfo.processInfo.systemUptime)
        let selected = catalog.selectInputSource(sourceID: rule.targetSourceID)
        refreshCurrentSource()
        guard captured == generation else { return }
        if selected && currentSource?.id == rule.targetSourceID {
            lastSwitchStatus = L10n.format("已切换到指定输入源：%@", rule.targetSourceName)
        } else { sourceChanges.cancelExpected(); lastSwitchStatus = "系统未完成输入源切换；规则及当前输入源保留。" }
    }

    public func exportRulesData() throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }
    public func importRulesData(_ data: Data) throws {
        guard data.count <= 1_048_576 else { throw InputAutomationError.invalid("输入法配置超过 1 MiB 上限。") }
        struct Legacy: Decodable { var format: Int; var rules: [InputSourceRule] }
        let incoming: AutoInputConfiguration
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any], header["schemaVersion"] != nil {
            incoming = try JSONDecoder().decode(AutoInputConfiguration.self, from: data)
        } else {
            let legacy = try JSONDecoder().decode(Legacy.self, from: data)
            guard legacy.format == 1 else { throw InputAutomationError.invalid("不支持的输入法规则版本；原配置未覆盖。") }
            var value = AutoInputConfiguration(); value.rules = legacy.rules; try value.validate(); incoming = value
        }
        var merged = configuration
        // Import never enables automation or overwrites a different rule sharing an ID.
        for rule in incoming.rules {
            if let existing = merged.rules.first(where: { $0.id == rule.id }) {
                guard existing == rule else { throw InputAutomationError.invalid("输入法规则 ID 冲突；未写入任何规则。") }
            } else { merged.rules.append(rule) }
        }
        try updateConfiguration(merged)
    }
}
