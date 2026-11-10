import AppKit
import CoreGraphics
import OSLog

struct ScreenshotCaptureRegionSelection {
    /// Top-left desktop coordinate system, logical points. May intersect several displays.
    let desktopRect: CGRect
    let displayIDs: [CGDirectDisplayID]
}

enum ScreenshotCaptureSelectionGeometry {
    static func screenPoint(eventLocationInWindow: CGPoint, convertToScreen: (CGPoint) -> CGPoint) -> CGPoint {
        convertToScreen(eventLocationInWindow)
    }

    static func desktopPoint(appKitScreenPoint: CGPoint, mainDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: appKitScreenPoint.x, y: mainDisplayTop - appKitScreenPoint.y)
    }

    static func selectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Use the same display-local desktop coordinates and outward pixel snapping as actual capture.
    static func regionPlan(selectionInAppKit: CGRect, screenFrameInAppKit: CGRect, mainDisplayTop: CGFloat, scale: CGFloat) throws -> ScreenshotCaptureRegionPlan {
        let display = ScreenshotCaptureGeometry.appKitToDesktop(screenFrameInAppKit, mainDisplayTop: mainDisplayTop)
        let selection = ScreenshotCaptureGeometry.appKitToDesktop(selectionInAppKit, mainDisplayTop: mainDisplayTop)
        let local = selection.offsetBy(dx: -display.minX, dy: -display.minY)
        return try ScreenshotCaptureGeometry.normalizedRegion(local, displaySize: display.size, scale: scale)
    }
}

@MainActor
final class ScreenshotCaptureSelectionController {
    private var panels: [ScreenshotSelectionPanel] = []
    private var continuation: CheckedContinuation<ScreenshotCaptureRegionSelection?, Never>?
    private var selection: CGRect = .zero
    private var dragOrigin: CGPoint?
    private var mainTop: CGFloat = 0
    private var localMonitor: Any?
    private var highlightedWindows: [ScreenshotCaptureWindow] = []
    private var windowPicked: ((CGWindowID?) -> Void)?
    private var latestScreenPoint: CGPoint?
    private var inputNotice: String?

    var isSelecting: Bool { !panels.isEmpty || continuation != nil || windowPicked != nil }

    private enum InputEvent: Int { case presented = 1, mouseDown, controlKey, windowMiss, invalidRegion, cancelled, finished }

    /// User-visible selection only. No screenshot is taken while panels exist; completion closes every panel first.
    func selectRegion() async -> ScreenshotCaptureRegionSelection? {
        cancel()
        return await withCheckedContinuation { completion in
            continuation = completion
            present(windows: [])
        }
    }

    /// Mouse hover highlights catalog windows; Escape cancels. Catalog is supplied by ScreenshotCaptureService.
    func selectWindow(from windows: [ScreenshotCaptureWindow]) async -> CGWindowID? {
        cancel()
        guard !windows.isEmpty else { return nil }
        return await withCheckedContinuation { completion in
            windowPicked = { completion.resume(returning: $0) }
            present(windows: windows)
        }
    }

    func cancel() { finish(cancelled: true) }
    fileprivate func cancelFromButton() { finish(cancelled: true, cancelSource: 1) }
    fileprivate func cancelFromResponder() { finish(cancelled: true, cancelSource: 2) }

    private func present(windows: [ScreenshotCaptureWindow]) {
        highlightedWindows = windows
        mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        selection = .zero
        latestScreenPoint = nil; inputNotice = nil
        // This is the explicit selection UI. Never schedule activation after it closes.
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = ScreenshotSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = windows.isEmpty ? "选择截图区域" : "选择截图窗口"
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true; panel.hidesOnDeactivate = false
            let view = ScreenshotSelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.selectionOwner = self; view.screenFrame = screen.frame
            panel.contentView = view; panels.append(panel)
            panel.orderFrontRegardless(); panel.makeFirstResponder(view)
        }
        // Local event monitoring belongs only to this explicit selection session, not a global shortcut listener.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let eventWindow = event.window ?? NSApp.keyWindow,
                  self.panels.contains(where: { $0 === eventWindow }) else { return event }
            return self.handleKey(event) ? nil : event
        }
        panels.first?.makeKey()
        record(.presented)
    }

    fileprivate func down(at point: CGPoint) {
        latestScreenPoint = point; inputNotice = nil
        record(.mouseDown, selectedWindowID: windowAtPointer()?.id)
        if !highlightedWindows.isEmpty {
            if let id = windowAtPointer()?.id { finish(window: id) }
            else { inputNotice = "未选中可捕获窗口。请移动到目标窗口后重试，或点击“取消选择”。"; record(.windowMiss); redraw() }
            return
        }
        dragOrigin = point
        selection = CGRect(origin: point, size: .zero)
        redraw()
    }

    fileprivate func drag(at point: CGPoint) {
        latestScreenPoint = point
        guard let origin = dragOrigin else { return }
        inputNotice = nil
        selection = ScreenshotCaptureSelectionGeometry.selectionRect(from: origin, to: point)
        redraw()
    }

    fileprivate func up(at point: CGPoint) {
        if dragOrigin != nil { drag(at: point) } else { latestScreenPoint = point }
        dragOrigin = nil
        // Keep the selection for arrow-key adjustment. Return/double click explicitly confirms.
        redraw()
    }

    fileprivate func move(at point: CGPoint) { latestScreenPoint = point; if !highlightedWindows.isEmpty { if windowAtPointer() != nil { inputNotice = nil }; redraw() } }
    fileprivate func confirm(at point: CGPoint? = nil) {
        if let point { latestScreenPoint = point }
        if windowPicked != nil {
            if let id = windowAtPointer()?.id { finish(window: id) }
            else { inputNotice = "未选中可捕获窗口。请移动到目标窗口后重试，或点击“取消选择”。"; record(.windowMiss); redraw() }
        } else if selection.width >= 1, selection.height >= 1 { finish(cancelled: false) }
        else { inputNotice = "请先拖出截图区域，再按 Return 确认；也可点击“取消选择”。"; record(.invalidRegion); redraw() }
    }

    private func windowAtPointer() -> ScreenshotCaptureWindow? {
        guard let latestScreenPoint else { return nil }
        let desktopPoint = ScreenshotCaptureSelectionGeometry.desktopPoint(appKitScreenPoint: latestScreenPoint, mainDisplayTop: mainTop)
        return ScreenshotCaptureWindowHitTesting.frontmost(at: desktopPoint, windows: highlightedWindows)
    }

    fileprivate var appKitSelection: CGRect {
        if let window = windowAtPointer(), !highlightedWindows.isEmpty { return ScreenshotCaptureGeometry.desktopToAppKit(window.frame, mainDisplayTop: mainTop) }
        return selection
    }

    fileprivate var selectionLabel: String {
        if let inputNotice { return inputNotice }
        if let window = windowAtPointer(), !highlightedWindows.isEmpty { return "\(window.applicationName) · \(window.title)\n单击或 Return 选择 · Esc 取消" }
        if !highlightedWindows.isEmpty { return "此处没有可确认前后顺序的窗口\n移动到目标窗口 · Esc 取消" }
        let desktop = ScreenshotCaptureGeometry.appKitToDesktop(selection, mainDisplayTop: mainTop)
        let screens = NSScreen.screens.filter { $0.frame.intersects(selection) }
        let pixels = screens.map { screen -> String in
            guard let plan = try? ScreenshotCaptureSelectionGeometry.regionPlan(selectionInAppKit: selection, screenFrameInAppKit: screen.frame, mainDisplayTop: mainTop, scale: screen.backingScaleFactor) else { return "像素范围无效" }
            return "\(Int(plan.pixelRect.width)) × \(Int(plan.pixelRect.height)) px @\(Int(screen.backingScaleFactor))x"
        }.joined(separator: "；")
        if selection.width < 1 || selection.height < 1 { return "拖动选择截图区域\nReturn 确认 · Esc 取消" }
        return "\(Int(selection.width)) × \(Int(selection.height)) 点 · (\(Int(desktop.minX)), \(Int(desktop.minY)))\n\(pixels)\n方向键移动 · Option+方向键调尺寸 · Shift 10点 · Return 确认 · Esc 取消"
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        guard isSelecting else { return false }
        if [UInt16(53), 36, 76, 123, 124, 125, 126].contains(event.keyCode) { record(.controlKey, keyCode: Int(event.keyCode)) }
        if event.keyCode == 53 { finish(cancelled: true, cancelSource: 3); return true }
        if event.keyCode == 36 || event.keyCode == 76 { confirm(); return true }
        guard highlightedWindows.isEmpty, selection.width >= 1, selection.height >= 1 else { return false }
        let delta: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var x: CGFloat = 0, y: CGFloat = 0
        switch event.keyCode { case 123: x = -delta; case 124: x = delta; case 125: y = -delta; case 126: y = delta; default: return false }
        if event.modifierFlags.contains(.option) {
            selection.size.width = max(1, selection.width + x)
            selection.size.height = max(1, selection.height + y)
        } else { selection = selection.offsetBy(dx: x, dy: y) }
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        selection = selection.intersection(desktopBounds)
        redraw(); return true
    }

    private func redraw() { panels.forEach { $0.contentView?.needsDisplay = true } }

    private func record(_ event: InputEvent, keyCode: Int = -1, selectedWindowID: CGWindowID? = nil, cancelSource: Int = -1) {
        guard isSelecting else { return }
        let panel = panels.first(where: { $0.isKeyWindow }) ?? panels.first
        let phase = windowPicked != nil ? 1 : 2
        // Numeric diagnostics only: no window titles, typed text, clipboard or image content.
        let values = "event=\(event.rawValue) phase=\(phase) panel=\(panel?.windowNumber ?? -1) keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1) isKey=\(panel?.isKeyWindow == true ? 1 : 0) appActive=\(NSApp.isActive ? 1 : 0) keyCode=\(keyCode) selectedWindowID=\(selectedWindowID ?? 0) width=\(Int(selection.width.rounded())) height=\(Int(selection.height.rounded())) cancelSource=\(cancelSource)"
        Logger(subsystem: "com.gaoseries.GaoCaoZuo.screenshot", category: "CaptureSelectionInput").notice("\(values, privacy: .public)")
    }

    private func finish(cancelled: Bool = false, window: CGWindowID? = nil, cancelSource: Int = 0) {
        let selected = selection
        record(cancelled ? .cancelled : .finished, selectedWindowID: window, cancelSource: cancelled ? cancelSource : -1)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); dragOrigin = nil; highlightedWindows.removeAll(); latestScreenPoint = nil; inputNotice = nil
        let callback = windowPicked, completion = continuation
        windowPicked = nil; continuation = nil
        callback?(cancelled ? nil : window)
        if let completion {
            let ids = NSScreen.screens.filter { $0.frame.intersects(selected) }.compactMap(ScreenshotCaptureGeometry.displayID)
            completion.resume(returning: cancelled || selected.width < 1 || selected.height < 1 ? nil : ScreenshotCaptureRegionSelection(desktopRect: ScreenshotCaptureGeometry.appKitToDesktop(selected, mainDisplayTop: mainTop), displayIDs: ids))
        }
    }
}

private final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ScreenshotSelectionCanvas: NSView {
    weak var selectionOwner: ScreenshotCaptureSelectionController?
    var screenFrame: CGRect = .zero
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); addCancelButton() }
    required init?(coder: NSCoder) { super.init(coder: coder); addCancelButton() }
    private func addCancelButton() {
        let button = NSButton(title: "取消选择", target: self, action: #selector(cancelSelection(_:)))
        button.bezelStyle = .rounded; button.keyEquivalent = "\u{1b}"; button.keyEquivalentModifierMask = []; button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("capture.selection.cancel")
        button.setAccessibilityHelp("取消本次截图选择，返回工作台。")
        addSubview(button)
        NSLayoutConstraint.activate([button.topAnchor.constraint(equalTo: topAnchor, constant: 20), button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)])
    }
    @objc private func cancelSelection(_ sender: Any?) { selectionOwner?.cancelFromButton() }
    override func keyDown(with event: NSEvent) { if selectionOwner?.handleKey(event) != true { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { selectionOwner?.cancelFromResponder() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseDown(with event: NSEvent) {
        guard let point = screenPoint(for: event) else { return }
        if event.clickCount == 2 { selectionOwner?.confirm(at: point) } else { selectionOwner?.down(at: point) }
    }
    override func mouseDragged(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.drag(at: point) } }
    override func mouseUp(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.up(at: point) } }
    override func mouseMoved(with event: NSEvent) { if let point = screenPoint(for: event) { selectionOwner?.move(at: point) } }
    private func screenPoint(for event: NSEvent) -> CGPoint? {
        guard let eventWindow = event.window ?? window else { return nil }
        return ScreenshotCaptureSelectionGeometry.screenPoint(eventLocationInWindow: event.locationInWindow, convertToScreen: { eventWindow.convertPoint(toScreen: $0) })
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner = selectionOwner else { return }
        NSColor.black.withAlphaComponent(0.32).setFill(); bounds.fill()
        let local = owner.appKitSelection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        if local.width > 0, local.height > 0 {
            NSGraphicsContext.current?.cgContext.clear(local.intersection(bounds))
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: local); outline.lineWidth = 1; outline.stroke()
            NSColor.systemBlue.setStroke(); let inner = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1)); inner.lineWidth = 1; inner.stroke()
        }
        let label = owner.selectionLabel
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        let box = CGRect(x: max(12, min(bounds.width - labelSize.width - 28, local.minX)), y: max(12, min(bounds.height - labelSize.height - 28, local.minY - labelSize.height - 20)), width: min(bounds.width - 24, labelSize.width + 20), height: labelSize.height + 16)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        (label as NSString).draw(in: box.insetBy(dx: 10, dy: 8), withAttributes: attributes)
    }
}
