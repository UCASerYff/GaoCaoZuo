import AppKit
import ApplicationServices
import Carbon
import SwiftUI

public struct FlyKeyItem: Identifiable, Equatable {
    public var id: String { bindingID.map { "binding:" + $0.uuidString } ?? path.joined(separator: " > ") + ":" + shortcut }
    public let title: String
    public let path: [String]
    public let shortcut: String
    public let isEnabled: Bool
    public let sourceAppName: String
    public let element: AXUIElement?
    public let bindingID: UUID?
    var menuEvidence: InputMenuEvidence?
    public init(title: String, path: [String], shortcut: String, isEnabled: Bool,
                sourceAppName: String, element: AXUIElement? = nil, bindingID: UUID? = nil) {
        self.title = title; self.path = path; self.shortcut = shortcut; self.isEnabled = isEnabled
        self.sourceAppName = sourceAppName; self.element = element; self.bindingID = bindingID
        self.menuEvidence = nil
    }
    public static func == (lhs: FlyKeyItem, rhs: FlyKeyItem) -> Bool {
        lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled && lhs.sourceAppName == rhs.sourceAppName
    }
}

@MainActor
public final class FlyKeyController: ObservableObject {
    public static let shared = FlyKeyController()
    @Published public private(set) var isShowing = false
    @Published public private(set) var items: [FlyKeyItem] = []
    @Published public private(set) var configuration = FlyKeyConfiguration()
    @Published public private(set) var lastStatus: String?
    @Published public var searchText = ""
    private var panel: NSPanel?
    private var detector = FlyKeyTapDetector()
    private var triggerPID: pid_t?
    private var bindings: [InputBinding] = []
    private var excludedApps: Set<String> = []
    private var executeBinding: ((InputBinding) -> Void)?
    private var generation: UInt64 = 0
    private struct HUDTarget {
        var bundleID: String
        var identity: WindowProcessIdentity.Snapshot
        var generation: UInt64
    }
    private var target: HUDTarget?
    private var healthTimer: Timer?
    private var isRunning = false
    public init() {}

    func configure(configuration: FlyKeyConfiguration, bindings: [InputBinding], excludedApps: [String] = [],
                   executeBinding: ((InputBinding) -> Void)? = nil) {
        stop()
        do { try configuration.validate() }
        catch { lastStatus = error.localizedDescription; return }
        self.configuration = configuration; self.bindings = bindings; self.excludedApps = Set(excludedApps)
        self.executeBinding = executeBinding
        isRunning = true
    }

    public func stop() {
        isRunning = false; generation &+= 1; resetTapDetector(); dismiss()
    }

    /// Observes the shared tap, never consumes or synthesizes the original modifier event.
    public func handleInputEvent(type: CGEventType, event: CGEvent) {
        guard isRunning, configuration.enabled, !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication,
              !excludedApps.contains(front.bundleIdentifier ?? "") else {
            resetTapDetector()
            if IsSecureEventInputEnabled() { dismiss() }
            return
        }
        guard type == .flagsChanged else {
            // A mouse action or ordinary key proves this was not two standalone modifier taps.
            if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { resetTapDetector() }
            return
        }
        if let triggerPID, triggerPID != front.processIdentifier { resetTapDetector() }
        triggerPID = front.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        let key = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if detector.flagsChanged(key: key, flags: event.flags.rawValue, now: now,
                                 modifier: configuration.triggerModifier, interval: configuration.doubleTapInterval) {
            let capturedGeneration = generation, pid = front.processIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == capturedGeneration, self.configuration.enabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !IsSecureEventInputEnabled() else { return }
                self.showHUD()
            }
        }
    }
    public func handleFlagsChanged(event: CGEvent) { handleInputEvent(type: .flagsChanged, event: event) }
    public func resetTapDetector() { detector.reset(); triggerPID = nil }

    /// Explicit invocation remains available when the optional double-tap listener is off.
    public func showHUD() {
        guard !IsSecureEventInputEnabled() else { dismiss(); lastStatus = "安全输入状态下不显示或执行快捷键。"; return }
        if isShowing { dismiss(); return }
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              let bundleID = app.bundleIdentifier, !excludedApps.contains(bundleID),
              let identity = WindowProcessIdentity.capture(pid: app.processIdentifier, launchDate: app.launchDate) else {
            lastStatus = "无法确认当前应用身份。"; return
        }
        guard !hasSecureFocusedField(pid: app.processIdentifier) else { lastStatus = "密码输入区域中不读取或执行菜单快捷键。"; return }
        let appName = app.localizedName ?? bundleID
        var extracted: [FlyKeyItem] = []
        if AXIsProcessTrusted() { extracted = extractMenuShortcuts(pid: app.processIdentifier, appName: appName) }
        let actualBindings = bindings.filter { $0.enabled && ($0.appBundleID.isEmpty || $0.appBundleID == bundleID) }
        let conflicts = InputRules.conflictingIDs(in: actualBindings)
        for binding in actualBindings {
            extracted.append(FlyKeyItem(title: binding.title, path: [L10n.text("搞操作"), binding.title],
                shortcut: binding.triggerDescription,
                isEnabled: !conflicts.contains(binding.id) && InputRules.validationError(binding) == nil && executeBinding != nil,
                sourceAppName: L10n.text("搞操作"), bindingID: binding.id))
        }
        guard let current = NSWorkspace.shared.frontmostApplication,
              identity.matches(WindowProcessIdentity.capture(pid: current.processIdentifier, launchDate: current.launchDate)),
              !IsSecureEventInputEnabled() else { lastStatus = "读取期间前台应用或安全输入状态已变化。"; return }
        target = HUDTarget(bundleID: bundleID, identity: identity, generation: generation)
        items = extracted; searchText = ""; isShowing = true
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .floating; p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true; p.backgroundColor = .clear; p.hasShadow = true; p.center()
        p.contentView = NSHostingView(rootView: FlyKeyHUDView(controller: self,
            onSelect: { [weak self] in self?.triggerItem($0) }, onDismiss: { [weak self] in self?.dismiss() }))
        p.makeKeyAndOrderFront(nil); panel = p
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let target = self.target, let front = NSWorkspace.shared.frontmostApplication,
                      !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
                      !self.hasSecureFocusedField(pid: front.processIdentifier),
                      target.identity.matches(WindowProcessIdentity.capture(pid: front.processIdentifier, launchDate: front.launchDate)) else {
                    self?.dismiss(); return
                }
            }
        }
    }

    private func hasSecureFocusedField(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(application, 0.1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let field = unsafeBitCast(raw, to: AXUIElement.self); AXUIElementSetMessagingTimeout(field, 0.1)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success else { return false }
        return subrole as? String == (kAXSecureTextFieldSubrole as String)
    }

    public func dismiss() {
        healthTimer?.invalidate(); healthTimer = nil
        panel?.orderOut(nil); panel = nil; target = nil
        isShowing = false; items = []; searchText = ""
    }

    private func triggerItem(_ item: FlyKeyItem) {
        guard item.isEnabled, let target, target.generation == generation,
              !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication,
              !hasSecureFocusedField(pid: front.processIdentifier),
              front.bundleIdentifier == target.bundleID,
              target.identity.matches(WindowProcessIdentity.capture(pid: front.processIdentifier, launchDate: front.launchDate)) else {
            dismiss(); lastStatus = "目标、权限或快捷键配置已变化，未执行。"; return
        }
        let matchingBinding = item.bindingID.flatMap { id in bindings.first { $0.id == id } }
        dismiss()
        if let binding = matchingBinding {
            guard binding.enabled, (binding.appBundleID.isEmpty || binding.appBundleID == target.bundleID),
                  InputRules.validationError(binding) == nil else { return }
            executeBinding?(binding)
            lastStatus = "已交给动作执行器；请查看该动作的实际结果。"
        } else if item.bindingID == nil {
            do {
                // Resolve the exact menu path again; never press a stale AX element from the HUD snapshot.
                guard let evidence = item.menuEvidence else {
                    throw InputMenuEvidenceError.invalid("菜单快照证据缺失，请重新打开快捷键面板。")
                }
                try InputMenuAction.perform(evidence: evidence, pid: front.processIdentifier)
                lastStatus = "系统已接受菜单点按；不代表目标业务已经完成。"
            } catch { lastStatus = error.localizedDescription }
        }
    }

    private func extractMenuShortcuts(pid: pid_t, appName: String) -> [FlyKeyItem] {
        do {
            let snapshot = try InputMenuAction.capture(pid: pid)
            func flatten(_ nodes: [InputMenuAction.TreeNode]) -> [FlyKeyItem] {
                nodes.flatMap { node in
                    var own: [FlyKeyItem] = []
                    if let evidence = node.evidence, !node.shortcutLabel.isEmpty {
                        var item = FlyKeyItem(title: node.title, path: evidence.path, shortcut: node.shortcutLabel,
                                              isEnabled: node.enabled, sourceAppName: appName)
                        item.menuEvidence = evidence; own.append(item)
                    }
                    return own + flatten(node.children ?? [])
                }
            }
            return flatten(snapshot.roots)
        } catch { lastStatus = error.localizedDescription; return [] }
    }

}

// MARK: - FlyKey HUD View

private struct FlyKeyHUDView: View {
    @ObservedObject var controller: FlyKeyController
    let onSelect: (FlyKeyItem) -> Void
    let onDismiss: () -> Void

    var filteredItems: [FlyKeyItem] {
        if controller.searchText.isEmpty {
            return controller.items
        }
        let q = controller.searchText.lowercased()
        return controller.items.filter {
            $0.title.lowercased().contains(q) ||
            $0.shortcut.lowercased().contains(q) ||
            $0.path.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "command")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(L10n.text("FlyKey 快捷键速查"))
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.text("搜索菜单项或快捷键 (按 Esc 退出)..."), text: $controller.searchText)
                    .textFieldStyle(.plain)
                if !controller.searchText.isEmpty {
                    Button(action: { controller.searchText = "" }) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)

            Divider()

            // Item List
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredItems) { item in
                        Button(action: { onSelect(item) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline)
                                        .foregroundStyle(item.isEnabled ? .primary : .secondary)
                                    Text(item.path.joined(separator: " > "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.shortcut)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.isEnabled)
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Text(L10n.text("点击可用菜单项执行；Esc 退出"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.format("%ld 项快捷键", filteredItems.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onExitCommand(perform: onDismiss)
    }
}
