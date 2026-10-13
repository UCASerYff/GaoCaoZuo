import AppKit
import ApplicationServices
import Carbon
import SwiftUI

// MARK: - FlyKeyItem

public struct FlyKeyItem: Identifiable, Equatable {
    public var id: String { path.joined(separator: " > ") + ":" + shortcut }
    public let title: String
    public let path: [String]
    public let shortcut: String
    public let isEnabled: Bool
    public let sourceAppName: String
    public let element: AXUIElement?

    public init(title: String, path: [String], shortcut: String, isEnabled: Bool, sourceAppName: String, element: AXUIElement? = nil) {
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.sourceAppName = sourceAppName
        self.element = element
    }

    public static func == (lhs: FlyKeyItem, rhs: FlyKeyItem) -> Bool {
        lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled && lhs.sourceAppName == rhs.sourceAppName
    }
}

// MARK: - FlyKeyController

@MainActor
public final class FlyKeyController: ObservableObject {
    public static let shared = FlyKeyController()

    @Published public private(set) var isShowing = false
    @Published public private(set) var items: [FlyKeyItem] = []
    @Published public var searchText = ""

    private var panel: NSPanel?
    private var lastModifierReleaseTime: Date = Date.distantPast
    private var modifierPressCount = 0
    private var lastModifierKeyCode: UInt16 = 0
    private let doubleTapWindow: TimeInterval = 0.35

    public init() {}

    /// Called by the event tap callback on flagsChanged events
    public func handleFlagsChanged(event: CGEvent) {
        guard !IsSecureEventInputEnabled() else {
            resetTapDetector()
            return
        }

        let flags = event.flags
        let isCommandPressed = flags.contains(.maskCommand)

        if isCommandPressed {
            // Key pressed down
            let now = Date()
            if now.timeIntervalSince(lastModifierReleaseTime) <= doubleTapWindow {
                modifierPressCount += 1
            } else {
                modifierPressCount = 1
            }
        } else {
            // Key released
            if modifierPressCount >= 2 {
                // Double tap recognized!
                modifierPressCount = 0
                lastModifierReleaseTime = Date.distantPast
                showHUD()
            } else {
                lastModifierReleaseTime = Date()
            }
        }
    }

    public func resetTapDetector() {
        modifierPressCount = 0
        lastModifierReleaseTime = Date.distantPast
    }

    public func showHUD() {
        guard !isShowing else {
            dismiss()
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "系统"
        let pid = frontApp?.processIdentifier ?? 0

        var extracted: [FlyKeyItem] = []
        if pid > 0 && AXIsProcessTrusted() {
            extracted = extractMenuShortcuts(pid: pid, appName: appName)
        }

        // Add GaoCaoZuo's own registered bindings
        for binding in InputBinding.defaults where binding.enabled {
            extracted.append(
                FlyKeyItem(
                    title: binding.title,
                    path: [L10n.text("搞操作"), binding.title],
                    shortcut: binding.triggerDescription,
                    isEnabled: true,
                    sourceAppName: "搞操作"
                )
            )
        }

        self.items = extracted
        self.searchText = ""
        self.isShowing = true

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.backgroundColor = .clear
        p.hasShadow = true
        p.center()

        let rootView = FlyKeyHUDView(
            controller: self,
            onSelect: { [weak self] item in
                self?.triggerItem(item)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        p.contentView = NSHostingView(rootView: rootView)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
        items = []
        searchText = ""
    }

    private func triggerItem(_ item: FlyKeyItem) {
        dismiss()
        if let element = item.element {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    private func extractMenuShortcuts(pid: pid_t, appName: String) -> [FlyKeyItem] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue as! AXUIElement? else {
            return []
        }
        AXUIElementSetMessagingTimeout(menuBar, 0.2)

        var menuBarChildrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &menuBarChildrenValue) == .success,
              let topMenus = menuBarChildrenValue as? [AXUIElement] else {
            return []
        }

        var results: [FlyKeyItem] = []

        for topItem in topMenus {
            var titleVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(topItem, kAXTitleAttribute as CFString, &titleVal)
            let topTitle = (titleVal as? String) ?? ""

            var subMenuVal: AnyObject?
            if AXUIElementCopyAttributeValue(topItem, kAXChildrenAttribute as CFString, &subMenuVal) == .success,
               let subMenus = subMenuVal as? [AXUIElement] {
                for subMenu in subMenus {
                    traverseMenu(subMenu, path: [topTitle], appName: appName, results: &results)
                }
            }
        }

        return results
    }

    private func traverseMenu(_ menu: AXUIElement, path: [String], appName: String, results: inout [FlyKeyItem]) {
        guard results.count < 300 else { return } // Safe upper limit

        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let items = childrenVal as? [AXUIElement] else {
            return
        }

        for item in items {
            var titleVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleVal)
            let title = (titleVal as? String) ?? ""

            // Check if item has submenu
            var subMenuVal: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subMenuVal) == .success,
               let subChildren = subMenuVal as? [AXUIElement], !subChildren.isEmpty {
                for sub in subChildren {
                    traverseMenu(sub, path: path + [title], appName: appName, results: &results)
                }
                continue
            }

            // Read shortcut
            var charVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charVal)
            var modVal: AnyObject?
            _ = AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modVal)

            let cmdChar = charVal as? String
            let cmdMod = (modVal as? NSNumber)?.intValue ?? 0

            if let c = cmdChar, !c.isEmpty {
                var prefix = ""
                if (cmdMod & 8) != 0 { prefix += "⌃" }
                if (cmdMod & 4) != 0 { prefix += "⌥" }
                if (cmdMod & 2) != 0 { prefix += "⇧" }
                if (cmdMod & 1) == 0 { prefix += "⌘" } // Default on Mac includes command unless inverted
                let shortcut = prefix + c.uppercased()

                var enabledVal: AnyObject?
                _ = AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledVal)
                let isEnabled = (enabledVal as? NSNumber)?.boolValue ?? true

                results.append(
                    FlyKeyItem(
                        title: title,
                        path: path + [title],
                        shortcut: shortcut,
                        isEnabled: isEnabled,
                        sourceAppName: appName,
                        element: item
                    )
                )
            }
        }
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
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Text(L10n.text("双击 ⌘ 随时唤出 FlyKey；点击菜单项可直接执行"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredItems.count) 项快捷键")
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
    }
}
