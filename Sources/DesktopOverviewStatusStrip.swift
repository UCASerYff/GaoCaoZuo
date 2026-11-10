import AppKit
import Combine

/// A self-owned visual aid below the visible menu area. This never changes the system notch or menu icons.
struct DesktopOverviewStatusStripGeometry {
    let frame: CGRect
    let visibleFrame: CGRect
    let topInset: CGFloat
    let menuBarHeight: CGFloat

    func panelFrame(size: CGSize = CGSize(width: 230, height: 30), margin: CGFloat = 8) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height, visibleFrame.minX, visibleFrame.minY,
               visibleFrame.width, visibleFrame.height, topInset, menuBarHeight, size.width, size.height, margin].allSatisfy({ $0.isFinite }),
              frame.width > 0, frame.height > 0, visibleFrame.width > 0, visibleFrame.height > 0,
              size.width > 0, size.height > 0, topInset >= 0, menuBarHeight >= 0, margin >= 0 else { return nil }
        let available = frame.intersection(visibleFrame)
        guard !available.isNull, available.width >= size.width + margin*2, available.height >= size.height + margin*2 else { return nil }
        let top = min(available.maxY, frame.maxY - max(topInset, menuBarHeight))
        let x = min(max(frame.midX - size.width/2, available.minX + margin), available.maxX - size.width - margin)
        let y = top - margin - size.height
        guard y >= available.minY + margin else { return nil }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
final class DesktopOverviewStatusStrip: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status = "状态条已关闭。"
    private var panel: NSPanel?
    private var sleeping = false
    private var screensSleeping = false
    private var sessionInactive = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func applyPreferences(_ preferences: DesktopOverviewPreferences) { setEnabled(preferences.statusStripEnabled) }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            installObservers()
            refresh()
        } else {
            panel?.orderOut(nil); panel?.close(); panel = nil
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll()
            sleeping = false; screensSleeping = false; sessionInactive = false
            status = "状态条已关闭。"
        }
    }

    func stop() { setEnabled(false) }

    private func refresh() {
        guard isEnabled, !sleeping, !screensSleeping, !sessionInactive else { panel?.orderOut(nil); return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            status = "没有可用屏幕，状态条已隐藏。"; panel?.orderOut(nil); return
        }
        let geometry = DesktopOverviewStatusStripGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame,
            topInset: screen.safeAreaInsets.top, menuBarHeight: max(NSStatusBar.system.thickness, NSApp.mainMenu?.menuBarHeight ?? 0))
        guard let frame = geometry.panelFrame() else { status = "可用区域不足，状态条已隐藏。"; panel?.orderOut(nil); return }
        if panel == nil {
            let view = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
            view.material = .popover; view.blendingMode = .withinWindow; view.state = .active
            view.wantsLayer = true; view.layer?.cornerRadius = 10; view.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "搞操作 · 窗口总览")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.alignment = .center; label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 10, y: 7, width: frame.width-20, height: 17)
            label.autoresizingMask = [.width, .height]
            view.addSubview(label)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.level = .normal
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.hidesOnDeactivate = false; panel.isFloatingPanel = false
            panel.ignoresMouseEvents = true; panel.acceptsMouseMovedEvents = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.animationBehavior = .none
            panel.title = "搞操作窗口总览状态条"
            panel.setAccessibilityLabel("搞操作自有状态条，不接收输入")
            panel.contentView = view
            self.panel = panel
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFront(nil)
        status = "状态条位于系统菜单下方的可用区域，不接收输入。"
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.refresh() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false; self?.refresh() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screensSleeping = true; self?.refresh() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screensSleeping = false; self?.refresh() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionInactive = true; self?.refresh() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionInactive = false; self?.refresh() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refresh() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, body: @escaping @MainActor () -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in body() } }))
    }

    deinit { for (center, token) in observers { center.removeObserver(token) } }
}
