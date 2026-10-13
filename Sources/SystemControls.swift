import AppKit
@preconcurrency import ApplicationServices
import Combine
import IOKit.pwr_mgt

enum SystemControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return L10n.text(text) }; return nil }
}

enum WindowAction: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case thirdLeft, thirdCenter, thirdRight
    case maximize, center, smaller, larger, nextDisplay, previousDisplay, restore
    case nearMaximize, centerHalf, leftTwoThirds, rightTwoThirds, maximizeHeight, maximizeWidth
    case quarterFirst, quarterSecond, quarterThird, quarterFourth, leftThreeQuarters, rightThreeQuarters
    case sixthTopLeft, sixthTopCenter, sixthTopRight, sixthBottomLeft, sixthBottomCenter, sixthBottomRight
    case moveLeft, moveRight, moveUp, moveDown
    case minimize, minimizeAll, unminimizeAll, close, toggleFullScreen, nextWindow, previousWindow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftHalf: return L10n.text("左半屏")
        case .rightHalf: return L10n.text("右半屏")
        case .topHalf: return L10n.text("上半屏")
        case .bottomHalf: return L10n.text("下半屏")
        case .topLeft: return L10n.text("左上角")
        case .topRight: return L10n.text("右上角")
        case .bottomLeft: return L10n.text("左下角")
        case .bottomRight: return L10n.text("右下角")
        case .thirdLeft: return L10n.text("左侧三分之一")
        case .thirdCenter: return L10n.text("中间三分之一")
        case .thirdRight: return L10n.text("右侧三分之一")
        case .maximize: return L10n.text("铺满工作区")
        case .center: return L10n.text("窗口居中")
        case .smaller: return L10n.text("缩小窗口")
        case .larger: return L10n.text("放大窗口")
        case .nextDisplay: return L10n.text("移到下一显示器")
        case .previousDisplay: return L10n.text("移到上一显示器")
        case .restore: return L10n.text("恢复原位置")
        case .nearMaximize: return L10n.text("接近最大化")
        case .centerHalf: return L10n.text("中间半屏")
        case .leftTwoThirds: return L10n.text("左侧三分之二")
        case .rightTwoThirds: return L10n.text("右侧三分之二")
        case .maximizeHeight: return L10n.text("高度最大化")
        case .maximizeWidth: return L10n.text("宽度最大化")
        case .quarterFirst: return L10n.text("第一列四分之一")
        case .quarterSecond: return L10n.text("第二列四分之一")
        case .quarterThird: return L10n.text("第三列四分之一")
        case .quarterFourth: return L10n.text("第四列四分之一")
        case .leftThreeQuarters: return L10n.text("左侧四分之三")
        case .rightThreeQuarters: return L10n.text("右侧四分之三")
        case .sixthTopLeft: return L10n.text("左上六分之一")
        case .sixthTopCenter: return L10n.text("中上六分之一")
        case .sixthTopRight: return L10n.text("右上六分之一")
        case .sixthBottomLeft: return L10n.text("左下六分之一")
        case .sixthBottomCenter: return L10n.text("中下六分之一")
        case .sixthBottomRight: return L10n.text("右下六分之一")
        case .moveLeft: return L10n.text("移至左边缘")
        case .moveRight: return L10n.text("移至右边缘")
        case .moveUp: return L10n.text("移至上边缘")
        case .moveDown: return L10n.text("移至下边缘")
        case .minimize: return L10n.text("最小化窗口")
        case .minimizeAll: return L10n.text("最小化此应用所有窗口")
        case .unminimizeAll: return L10n.text("还原此应用最小化窗口")
        case .close: return L10n.text("关闭窗口")
        case .toggleFullScreen: return L10n.text("切换窗口全屏")
        case .nextWindow: return L10n.text("此应用下一窗口")
        case .previousWindow: return L10n.text("此应用上一窗口")
        }
    }
    var icon: String {
        switch self {
        case .leftHalf, .thirdLeft: return "rectangle.lefthalf.filled"
        case .rightHalf, .thirdRight: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "square.grid.2x2"
        case .thirdCenter: return "rectangle.split.3x1"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .center: return "viewfinder"
        case .smaller: return "minus.magnifyingglass"
        case .larger: return "plus.magnifyingglass"
        case .nextDisplay: return "rectangle.on.rectangle"
        case .previousDisplay: return "rectangle.on.rectangle.angled"
        case .restore: return "arrow.uturn.backward"
        case .minimize, .minimizeAll: return "minus.square"
        case .close: return "xmark.square"
        case .toggleFullScreen: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        default: return "rectangle.split.3x1"
        }
    }
}

/// All geometry below uses Accessibility coordinates: origin at the top-left of the main display.
enum WindowGeometry {
    static func accessibilityRect(fromAppKit rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screenIndex(for window: CGRect, in screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { screen -> CGFloat in
            let intersection = screen.intersection(window)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        if let largest = areas.max(), largest > 0 { return areas.firstIndex(of: largest) }
        return screens.indices.min {
            pow(screens[$0].midX - window.midX, 2) + pow(screens[$0].midY - window.midY, 2)
            < pow(screens[$1].midX - window.midX, 2) + pow(screens[$1].midY - window.midY, 2)
        }
    }

    static func targetFrame(action: WindowAction, current: CGRect, visibleFrames: [CGRect]) throws -> CGRect {
        guard let index = screenIndex(for: current, in: visibleFrames) else {
            throw SystemControlError.message("没有可用的显示器。")
        }
        let screen = visibleFrames[index]
        func fraction(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: screen.minX + screen.width * x, y: screen.minY + screen.height * y,
                   width: screen.width * w, height: screen.height * h)
        }
        func centered(_ size: CGSize, on destination: CGRect) -> CGRect {
            let width = min(size.width, destination.width)
            let height = min(size.height, destination.height)
            return CGRect(x: destination.midX - width / 2, y: destination.midY - height / 2, width: width, height: height)
        }
        switch action {
        case .leftHalf: return fraction(0, 0, 0.5, 1)
        case .rightHalf: return fraction(0.5, 0, 0.5, 1)
        case .topHalf: return fraction(0, 0, 1, 0.5)
        case .bottomHalf: return fraction(0, 0.5, 1, 0.5)
        case .topLeft: return fraction(0, 0, 0.5, 0.5)
        case .topRight: return fraction(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return fraction(0, 0.5, 0.5, 0.5)
        case .bottomRight: return fraction(0.5, 0.5, 0.5, 0.5)
        case .thirdLeft: return fraction(0, 0, 1 / 3, 1)
        case .thirdCenter: return fraction(1 / 3, 0, 1 / 3, 1)
        case .thirdRight: return fraction(2 / 3, 0, 1 / 3, 1)
        case .maximize: return screen
        case .center: return centered(current.size, on: screen)
        case .smaller, .larger:
            let scale: CGFloat = action == .smaller ? 0.9 : 1.1
            let width = min(screen.width, max(160, current.width * scale))
            let height = min(screen.height, max(100, current.height * scale))
            return CGRect(x: min(max(current.midX - width / 2, screen.minX), screen.maxX - width),
                          y: min(max(current.midY - height / 2, screen.minY), screen.maxY - height), width: width, height: height)
        case .nextDisplay, .previousDisplay:
            guard visibleFrames.count > 1 else { throw SystemControlError.message("当前只有一个显示器。") }
            let step = action == .nextDisplay ? 1 : visibleFrames.count - 1
            let destination = visibleFrames[(index + step) % visibleFrames.count]
            let width = min(current.width, destination.width)
            let height = min(current.height, destination.height)
            let relativeX = (current.minX - screen.minX) / max(1, screen.width - current.width)
            let relativeY = (current.minY - screen.minY) / max(1, screen.height - current.height)
            return CGRect(x: destination.minX + max(0, min(1, relativeX)) * (destination.width - width),
                          y: destination.minY + max(0, min(1, relativeY)) * (destination.height - height),
                          width: width, height: height)
        case .nearMaximize: return screen.insetBy(dx:min(40,screen.width/10),dy:min(40,screen.height/10))
        case .centerHalf: return fraction(0.25,0,0.5,1)
        case .leftTwoThirds: return fraction(0,0,2/3,1)
        case .rightTwoThirds: return fraction(1/3,0,2/3,1)
        case .maximizeHeight: return CGRect(x:current.minX,y:screen.minY,width:current.width,height:screen.height)
        case .maximizeWidth: return CGRect(x:screen.minX,y:current.minY,width:screen.width,height:current.height)
        case .quarterFirst: return fraction(0,0,0.25,1)
        case .quarterSecond: return fraction(0.25,0,0.25,1)
        case .quarterThird: return fraction(0.5,0,0.25,1)
        case .quarterFourth: return fraction(0.75,0,0.25,1)
        case .leftThreeQuarters: return fraction(0,0,0.75,1)
        case .rightThreeQuarters: return fraction(0.25,0,0.75,1)
        case .sixthTopLeft: return fraction(0,0,1/3,0.5)
        case .sixthTopCenter: return fraction(1/3,0,1/3,0.5)
        case .sixthTopRight: return fraction(2/3,0,1/3,0.5)
        case .sixthBottomLeft: return fraction(0,0.5,1/3,0.5)
        case .sixthBottomCenter: return fraction(1/3,0.5,1/3,0.5)
        case .sixthBottomRight: return fraction(2/3,0.5,1/3,0.5)
        case .moveLeft: return CGRect(x:screen.minX,y:current.minY,width:current.width,height:current.height)
        case .moveRight: return CGRect(x:screen.maxX-current.width,y:current.minY,width:current.width,height:current.height)
        case .moveUp: return CGRect(x:current.minX,y:screen.minY,width:current.width,height:current.height)
        case .moveDown: return CGRect(x:current.minX,y:screen.maxY-current.height,width:current.width,height:current.height)
        default: throw SystemControlError.message("此动作需要窗口状态操作，不能仅计算尺寸。")
        }
    }
}

struct WindowSnapTarget: Equatable {
    let action: WindowAction
    let visibleFrame: CGRect
}

enum WindowDragGeometry {
    static func translatedFrame(initialFrame: CGRect, initialPointer: CGPoint, pointer: CGPoint) -> CGRect {
        initialFrame.offsetBy(dx: pointer.x - initialPointer.x, dy: pointer.y - initialPointer.y)
    }

    static func keepingTitleBarAccessible(_ proposed: CGRect, in visibleFrame: CGRect) -> CGRect {
        // macOS clamps title bars at screen boundaries. Keep a reachable handle while retaining total-delta motion.
        let horizontalHandle = min(64, proposed.width)
        let verticalHandle = min(32, proposed.height)
        return CGRect(x: min(max(proposed.minX, visibleFrame.minX - proposed.width + horizontalHandle), visibleFrame.maxX - horizontalHandle),
                      y: min(max(proposed.minY, visibleFrame.minY), visibleFrame.maxY - verticalHandle),
                      width: proposed.width, height: proposed.height)
    }

    static func isWindowDrag(initialFrame: CGRect, currentFrame: CGRect, initialPointer: CGPoint, pointer: CGPoint) -> Bool {
        // A selection changes the pointer, not the window. A resize can change the origin too, so exclude it.
        abs(initialFrame.width - currentFrame.width) <= 4 && abs(initialFrame.height - currentFrame.height) <= 4
            && hypot(currentFrame.minX - initialFrame.minX, currentFrame.minY - initialFrame.minY) >= 6
            && hypot(pointer.x - initialPointer.x, pointer.y - initialPointer.y) >= 8
    }

    static func snapTarget(pointer: CGPoint, visibleFrames: [CGRect], screenFrames: [CGRect]? = nil, threshold: CGFloat = 24) -> WindowSnapTarget? {
        let physical = screenFrames?.count == visibleFrames.count ? screenFrames! : visibleFrames
        guard let index = physical.firstIndex(where: { $0.contains(pointer) }) else { return nil }
        let frame = visibleFrames[index]
        let left = pointer.x <= frame.minX + threshold
        let right = pointer.x >= frame.maxX - threshold
        let top = pointer.y <= frame.minY + threshold
        let bottom = pointer.y >= frame.maxY - threshold
        let action: WindowAction?
        if left && top { action = .topLeft }
        else if right && top { action = .topRight }
        else if left && bottom { action = .bottomLeft }
        else if right && bottom { action = .bottomRight }
        else if left { action = .leftHalf }
        else if right { action = .rightHalf }
        else if top { action = .maximize }
        else { action = nil }
        return action.map { WindowSnapTarget(action: $0, visibleFrame: frame) }
    }
}

/// Keep focus restoration bound to the captured window, even if the user switches apps meanwhile.
/// Callbacks let the state transitions be tested without moving the user's real windows.
@MainActor
enum WindowFocusRestoration {
    static func perform(targetPID: pid_t, ownPID: pid_t,
                        frontmostPID: () -> pid_t?, validateTarget: () throws -> Void,
                        raiseTarget: () throws -> Void, activateTarget: () -> Bool) throws {
        func validate() throws {
            guard targetPID != ownPID else {
                throw SystemControlError.message("不能将搞操作自己的窗口作为本次操作目标。")
            }
            try validateTarget()
            guard let foreground = frontmostPID(), foreground == targetPID || foreground == ownPID else {
                throw SystemControlError.message("前台应用已变化，已停止切换窗口；请重新选择需要操作的窗口。")
            }
        }
        try validate()
        // Raise the specific window before activating the app, so another window is not chosen.
        try raiseTarget()
        try validate()
        guard activateTarget() else {
            throw SystemControlError.message("窗口布局已调整，但系统拒绝激活目标应用。请手动切回该窗口查看。")
        }
        // Activation can reorder an application's windows; raise the same captured element again.
        try validate()
        try raiseTarget()
    }
}

@MainActor
final class WindowManager: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var lastError: String?
    private var target: AXUIElement?
    private var targetPID: pid_t?
    // Retain the original application object: a recycled PID must never select a new process.
    private var targetApplication: NSRunningApplication?
    private var targetLaunchDate: Date?
    private struct OriginalFrame { let element: AXUIElement; let pid: pid_t; let launchDate:Date; let frame: CGRect }
    private var originalFrames: [OriginalFrame] = []
    private struct DragSession {
        let window: AXUIElement
        let pid: pid_t
        let application:NSRunningApplication
        let launchDate:Date
        var initialFrame: CGRect
        var initialPointer: CGPoint
        let moveWithPointer: Bool
        var snapEnabled = true
    }
    private var dragSession: DragSession?
    private var dragGeneration: UInt64 = 0
    private let layoutTransaction = WindowLayoutTransaction()
    private var windowOperationBusy = false
    private var configuration = WindowEnhancementConfiguration()
    private let snapPreview = WindowSnapPreview()
    private var snappedFrames: [OriginalFrame] = []
    private var lastLayout: (window: AXUIElement, action: WindowAction, time: TimeInterval, count: Int)?
    private var capturedForegroundPID: pid_t?
    @Published private(set) var conflictWarning: String?

    func configure(enhancements: WindowEnhancementConfiguration) {
        configuration = enhancements
        let known = ["cn.better365.Pane", "cn.better365.BetterAndBetter", "com.hegenberg.BetterTouchTool", "com.knollsoft.Rectangle", "com.crowdcafe.windowmagnet"]
        let names = NSWorkspace.shared.runningApplications.filter { known.contains($0.bundleIdentifier ?? "") }.compactMap(\.localizedName)
        conflictWarning = enhancements.warnConflictingApps && !names.isEmpty ? "同时运行：" + names.joined(separator: "、") + "；相同手势或分屏规则可能相互影响。" : nil
    }

    /// Call before bringing any GaoCaoZuo window or panel to the foreground.
    func captureTarget(at pointer: CGPoint? = nil) {
        isTrusted = AXIsProcessTrusted()
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = nil
        targetPID = nil
        targetApplication = nil
        targetLaunchDate = nil
        capturedForegroundPID = application.processIdentifier
        guard isTrusted else { return }
        if configuration.targetUnderPointer || pointer != nil {
            let point = pointer ?? CGEvent(source:nil)?.location ?? .zero
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&element) == .success, let element {
                var owner: pid_t = 0; AXUIElementGetPid(element,&owner)
                if owner != ProcessInfo.processInfo.processIdentifier, let ownerApp = NSRunningApplication(processIdentifier:owner) {
                    var windowValue: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(element,kAXWindowAttribute as CFString,&windowValue)
                    if let windowValue,CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                        target = (windowValue as! AXUIElement); targetPID = owner; targetApplication = ownerApp; targetLaunchDate = ownerApp.launchDate; return
                    }
                }
            }
            // Explicit pointer targeting must never silently fall back to another window.
            return
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focused)
        if result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            target = (focused as! AXUIElement)
            targetPID = application.processIdentifier
            targetApplication = application
            targetLaunchDate = application.launchDate
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        lastError = isTrusted ? nil : "请在系统设置的“隐私与安全性 → 辅助功能”中允许搞操作。"
    }

    func perform(_ action: WindowAction) async throws -> WindowOperationOutcome {
        guard !windowOperationBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
        windowOperationBusy = true
        defer { windowOperationBusy = false }
        do {
            try Task.checkCancellation()
            guard !layoutTransaction.isBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
            cancelWindowDrag()
            isTrusted = AXIsProcessTrusted()
            guard isTrusted else { throw SystemControlError.message("窗口操作需要辅助功能权限，请先在设置中授权。") }
            // Direct shortcuts act on the current foreground app; the panel keeps its captured target.
            captureTarget()
            guard let window = target, let pid = targetPID, let application = targetApplication else {
                throw SystemControlError.message("没有可操作的目标窗口。请先切换到需要调整的窗口，再打开操作面板。")
            }
            AXUIElementSetMessagingTimeout(window,0.15)
            let launchDate = targetLaunchDate
            try validateTarget(window, pid: pid, application: application, launchDate: launchDate)
            if try performStateAction(action,window:window,pid:pid,application:application) { lastError = nil; return WindowOperationOutcome(message: "已发送窗口请求：" + action.title, isExact: true) }
            let requestedAction = action
            var action = action
            if configuration.cycleRepeatedLayouts {
                let now = ProcessInfo.processInfo.systemUptime
                let count = lastLayout.map { CFEqual($0.window,window) && $0.action == requestedAction && now-$0.time < 2 ? $0.count+1 : 0 } ?? 0
                action = WindowEnhancementGeometry.cycle(requestedAction,count:count)
                lastLayout = (window,requestedAction,now,count)
            }
            var fullScreen: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
               (fullScreen as? Bool) == true {
                throw SystemControlError.message("请先退出目标窗口的全屏模式，再调整布局。")
            }
            let current = try readFrame(window)
            let originalIndex = originalFrames.firstIndex { $0.pid == pid && $0.launchDate == launchDate && CFEqual($0.element, window) }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let screens = NSScreen.screens.map { WindowEnhancementGeometry.workArea(WindowGeometry.accessibilityRect(fromAppKit:$0.visibleFrame,primaryTop:primaryTop),configuration:configuration) }
            let desired: CGRect
            if action == .restore {
                guard let originalIndex else { throw SystemControlError.message("这个窗口还没有可恢复的位置记录。") }
                desired = originalFrames[originalIndex].frame
            } else {
                var frame = try WindowGeometry.targetFrame(action: action, current: current, visibleFrames: screens)
                if action == .nearMaximize, let index = WindowGeometry.screenIndex(for:current,in:screens) {
                    let inset = min(max(0,configuration.nearMaximizeInset),min(screens[index].width,screens[index].height)/4)
                    frame = screens[index].insetBy(dx:inset,dy:inset)
                }
                let preserveSize: [WindowAction] = [.center,.moveLeft,.moveRight,.moveUp,.moveDown,.nextDisplay,.previousDisplay,.smaller,.larger]
                desired = preserveSize.contains(action) ? frame : WindowEnhancementGeometry.inset(frame,gap:configuration.windowGap)
            }
            try checkSettable(window, attribute: kAXPositionAttribute)
            if action == .restore || abs(desired.width - current.width) > 1 || abs(desired.height - current.height) > 1 {
                try checkSettable(window, attribute: kAXSizeAttribute)
            }
            // Capture foreground identity too: workspace notifications may capture a new target while awaiting AX.
            let capturedPID = capturedForegroundPID
            try await restoreFocus(window, pid: pid, application: application, launchDate: launchDate, capturedPID: capturedPID)
            let outcome = try await applyLayout(desired, original: current, window: window, pid: pid,
                application: application, launchDate: launchDate, capturedPID: capturedPID,
                workArea: WindowGeometry.screenIndex(for: desired, in: screens).map { screens[$0] },
                restoring: action == .restore)
            if configuration.movePointerWithWindow && [.nextDisplay,.previousDisplay].contains(action) {
                CGWarpMouseCursorPosition(CGPoint(x:outcome.actual.midX,y:outcome.actual.midY))
            }
            lastError = outcome.isExact ? nil : outcomeMessage(outcome, title: action.title, application: application)
            return WindowOperationOutcome(message: outcomeMessage(outcome, title: action.title, application: application), isExact: outcome.isExact)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Returns false for an ordinary click outside the focused window or on our own application.
    @discardableResult
    func beginWindowDrag(at pointer: CGPoint, moveWithPointer: Bool, snapEnabled: Bool = true) throws -> Bool {
        guard !windowOperationBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
        dragGeneration &+= 1
        dragSession = nil
        do {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            isTrusted = AXIsProcessTrusted()
            guard isTrusted else { throw SystemControlError.message("拖动窗口与边缘吸附需要辅助功能权限。") }
            captureTarget(at: configuration.targetUnderPointer ? pointer : nil)
            guard let window = target, let pid = targetPID, pid == front.processIdentifier,
                  let application=targetApplication,let launchDate=targetLaunchDate else {
                throw SystemControlError.message("这个应用没有可读取的标准前台窗口，无法开始拖动或吸附。")
            }
            AXUIElementSetMessagingTimeout(window, 0.15)
            try validateTarget(window,pid:pid,application:application,launchDate:launchDate)
            let frame = try readFrame(window)
            guard frame.contains(pointer) else { return false }
            try ensureNotFullScreen(window)
            try checkSettable(window, attribute: kAXPositionAttribute)
            dragSession = DragSession(window: window, pid: pid, application:application,launchDate:launchDate,initialFrame: frame,
                                      initialPointer: pointer, moveWithPointer: moveWithPointer, snapEnabled: snapEnabled)
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; throw error }
    }

    func updateWindowDrag(to pointer: CGPoint) throws {
        guard !windowOperationBusy else { return }
        guard let drag = dragSession else { return }
        do {try checkDragApplication(drag)} catch {
            dragSession=nil;snapPreview.hide();lastError=error.localizedDescription;throw error
        }
        let distance = hypot(pointer.x-drag.initialPointer.x,pointer.y-drag.initialPointer.y)
        if configuration.restoreWhenUnsnapped, distance >= 8,
           try drag.moveWithPointer || WindowDragGeometry.isWindowDrag(initialFrame:drag.initialFrame,currentFrame:readFrame(drag.window),initialPointer:drag.initialPointer,pointer:pointer),
           let snapped = snappedFrames.first(where: { $0.pid == drag.pid && $0.launchDate == drag.launchDate && CFEqual($0.element,drag.window) }),
           let original = originalFrames.first(where: { $0.pid == drag.pid && $0.launchDate == drag.launchDate && CFEqual($0.element,drag.window) }) {
            try checkDragApplication(drag)
            let restored = WindowEnhancementGeometry.restoredDragFrame(original:original.frame,snapped:snapped.frame,pointer:pointer)
            try checkSettable(drag.window,attribute:kAXSizeAttribute)
            // Restoring size is an asynchronous AX transaction too. Do not resume dragging or
            // discard the snapped state until position and size have actually settled.
            beginUnsnapping(drag,requested:restored,pointer:pointer)
            return
        }
        if !drag.moveWithPointer { try updateSnapPreview(pointer:pointer,drag:drag); return }
        do {
            try checkDragApplication(drag)
            guard hypot(pointer.x - drag.initialPointer.x, pointer.y - drag.initialPointer.y) >= 3 else { return }
            var desired = WindowDragGeometry.translatedFrame(initialFrame: drag.initialFrame,
                                                            initialPointer: drag.initialPointer, pointer: pointer)
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            if let screen = NSScreen.screens.first(where: {
                WindowGeometry.accessibilityRect(fromAppKit: $0.frame, primaryTop: primaryTop).contains(pointer)
            }) {
                desired = WindowDragGeometry.keepingTitleBarAccessible(desired, in: WindowGeometry.accessibilityRect(fromAppKit: screen.visibleFrame, primaryTop: primaryTop))
            }
            try apply(desired, to: drag.window, resize: false)
            let actual = try readFrame(drag.window)
            guard abs(actual.minX - desired.minX) <= 6, abs(actual.minY - desired.minY) <= 6 else {
                throw SystemControlError.message("目标应用限制了窗口移动范围，已停止拖动；可用“恢复原位置”返回。")
            }
            rememberOriginal(drag)
            try updateSnapPreview(pointer:pointer,drag:drag)
            lastError = nil
        } catch {
            // A successful partial movement must still have a restore record.
            rememberOriginal(drag)
            dragSession = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    private func beginUnsnapping(_ captured:DragSession,requested:CGRect,pointer:CGPoint) {
        let generation=dragGeneration
        windowOperationBusy=true;dragSession=nil;snapPreview.hide()
        Task { @MainActor [weak self] in
            guard let self else{return}
            defer {self.windowOperationBusy=false}
            do {
                try self.checkDragApplication(captured)
                let current=try self.readFrame(captured.window)
                let outcome=try await self.applyLayout(requested,original:current,window:captured.window,pid:captured.pid,
                    application:captured.application,launchDate:captured.launchDate,capturedPID:captured.pid,
                    workArea:nil,restoring:false,saveFrame:captured.initialFrame,additionalValidation:{
                        guard self.dragGeneration==generation else {throw CancellationError()}
                    })
                guard outcome.isExact else {throw SystemControlError.message("应用限制了拖离恢复尺寸，已停止拖动；原位置记录保留。")}
                self.snappedFrames.removeAll {$0.pid==captured.pid && $0.launchDate==captured.launchDate && CFEqual($0.element,captured.window)}
                var resumed=captured;resumed.initialFrame=outcome.actual;resumed.initialPointer=pointer
                if self.dragGeneration==generation,NSEvent.pressedMouseButtons & 1 != 0,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier==captured.pid {self.dragSession=resumed}
                self.lastError=nil
            } catch {self.lastError=error.localizedDescription}
        }
    }

    func endWindowDrag(at pointer: CGPoint, snap: Bool) async throws {
        guard let drag = dragSession else { return }
        let generation = dragGeneration
        defer { if generation == dragGeneration { dragSession = nil }; snapPreview.hide() }
        do {
            try Task.checkCancellation()
            guard !windowOperationBusy, !layoutTransaction.isBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
            try checkDragApplication(drag)
            if drag.moveWithPointer { try updateWindowDrag(to: pointer) }
            guard snap else { return }
            let current = try readFrame(drag.window)
            guard WindowDragGeometry.isWindowDrag(initialFrame: drag.initialFrame, currentFrame: current,
                                                  initialPointer: drag.initialPointer, pointer: pointer) else { return }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let visible = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit: $0.visibleFrame, primaryTop: primaryTop) }
            let physical = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit: $0.frame, primaryTop: primaryTop) }
            guard let snapTarget = WindowDragGeometry.snapTarget(pointer: pointer, visibleFrames: visible, screenFrames: physical, threshold: CGFloat(max(8,min(80,configuration.snapThreshold)))) else { return }
            try ensureNotFullScreen(drag.window)
            try checkSettable(drag.window, attribute: kAXPositionAttribute)
            try checkSettable(drag.window, attribute: kAXSizeAttribute)
            let application=drag.application
            let workArea = WindowEnhancementGeometry.workArea(snapTarget.visibleFrame, configuration: configuration)
            let desired = WindowEnhancementGeometry.inset(try WindowGeometry.targetFrame(action:snapTarget.action,current:current,visibleFrames:[workArea]),gap:configuration.windowGap)
            windowOperationBusy = true
            defer { windowOperationBusy = false }
            dragSession = nil // Pending pointer events must not modify a window during final verification.
            snapPreview.hide()
            let outcome = try await applyLayout(desired, original: current, window: drag.window, pid: drag.pid,
                application: application, launchDate: drag.launchDate, capturedPID: drag.pid,
                workArea: workArea, restoring: false, saveFrame: drag.initialFrame,
                additionalValidation: {
                    guard self.dragGeneration == generation else { throw CancellationError() }
                })
            snappedFrames.removeAll { $0.pid == drag.pid && $0.launchDate == drag.launchDate && CFEqual($0.element,drag.window) }
            snappedFrames.append(OriginalFrame(element:drag.window,pid:drag.pid,launchDate:drag.launchDate,frame:outcome.actual))
            self.target = drag.window; targetPID = drag.pid
            targetApplication = application; targetLaunchDate = drag.launchDate
            lastError = outcome.isExact ? nil : outcomeMessage(outcome,title:snapTarget.action.title,application:application)
        } catch { lastError = error.localizedDescription; throw error }
    }

    func cancelWindowDrag() { dragGeneration &+= 1; dragSession = nil; snapPreview.hide() }

    private func updateSnapPreview(pointer: CGPoint, drag: DragSession) throws {
        guard configuration.showSnapPreview,drag.snapEnabled else { return }
        let current = try readFrame(drag.window)
        guard WindowDragGeometry.isWindowDrag(initialFrame:drag.initialFrame,currentFrame:current,initialPointer:drag.initialPointer,pointer:pointer) else { snapPreview.hide(); return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let visible = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit:$0.visibleFrame,primaryTop:top) }
        let physical = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit:$0.frame,primaryTop:top) }
        guard let snap = WindowDragGeometry.snapTarget(pointer:pointer,visibleFrames:visible,screenFrames:physical,threshold:CGFloat(max(8,min(80,configuration.snapThreshold)))) else { snapPreview.hide(); return }
        let frame = WindowEnhancementGeometry.inset(try WindowGeometry.targetFrame(action:snap.action,current:current,visibleFrames:[WindowEnhancementGeometry.workArea(snap.visibleFrame,configuration:configuration)]),gap:configuration.windowGap)
        snapPreview.show(frame:frame,title:snap.action.title,animated:configuration.animatePreview,haptic:configuration.hapticFeedback)
    }

    func performCustomLayout(_ id: UUID) async throws -> WindowOperationOutcome {
        guard !windowOperationBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
        windowOperationBusy = true
        defer { windowOperationBusy = false }
        do {
            try Task.checkCancellation()
            guard !layoutTransaction.isBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
            cancelWindowDrag()
            guard let layout = configuration.customLayouts.first(where: { $0.id == id }) else { throw SystemControlError.message("自定义窗口布局不存在。") }
            guard AXIsProcessTrusted() else { throw SystemControlError.message("自定义布局需要辅助功能权限。") }
            captureTarget()
            guard let window = target,let pid = targetPID,let app = targetApplication else { throw SystemControlError.message("没有可操作的目标窗口。") }
            AXUIElementSetMessagingTimeout(window,0.15)
            let launchDate = targetLaunchDate, capturedPID = capturedForegroundPID
            try validateTarget(window,pid:pid,application:app,launchDate:launchDate)
            try ensureNotFullScreen(window)
            let original = try readFrame(window)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frames = NSScreen.screens.map { WindowEnhancementGeometry.workArea(WindowGeometry.accessibilityRect(fromAppKit:$0.visibleFrame,primaryTop:top),configuration:configuration) }
            guard let index = WindowGeometry.screenIndex(for:original,in:frames) else { throw SystemControlError.message("没有可用显示器。") }
            let desired = WindowEnhancementGeometry.inset(try layout.frame(in:frames[index]),gap:configuration.windowGap)
            try checkSettable(window,attribute:kAXPositionAttribute); try checkSettable(window,attribute:kAXSizeAttribute)
            try await restoreFocus(window,pid:pid,application:app,launchDate:launchDate,capturedPID:capturedPID)
            let outcome = try await applyLayout(desired,original:original,window:window,pid:pid,
                application:app,launchDate:launchDate,capturedPID:capturedPID,workArea:frames[index],restoring:false)
            let message = outcomeMessage(outcome,title:layout.name,application:app)
            lastError = outcome.isExact ? nil : message
            return WindowOperationOutcome(message:message,isExact:outcome.isExact)
        } catch { lastError = error.localizedDescription; throw error }
    }

    private func outcomeMessage(_ outcome: WindowLayoutOutcome, title: String, application: NSRunningApplication) -> String {
        if outcome.isExact { return "已完成：" + title }
        let name = application.localizedName ?? "目标应用"
        let width = Int(outcome.actual.width.rounded()), height = Int(outcome.actual.height.rounded())
        let requestedWidth = Int(outcome.requested.width.rounded()), requestedHeight = Int(outcome.requested.height.rounded())
        let heightMessage = abs(outcome.actual.height - outcome.requested.height) <= 4 ? "，已铺满目标高度" : "，高度也受应用限制"
        return "已按\(name)允许的尺寸调整：\(title)，实际 \(width)×\(height) pt（目标 \(requestedWidth)×\(requestedHeight) pt）\(heightMessage)；未达到精确布局，可用“恢复原位置”返回。"
    }

    private func restoreFocus(_ window: AXUIElement, pid: pid_t, application: NSRunningApplication,
                              launchDate: Date?, capturedPID: pid_t?) async throws {
        let underPointer = configuration.targetUnderPointer
        try await WindowFocusTransaction.perform(targetPID:pid,ownPID:ProcessInfo.processInfo.processIdentifier,
            allowedInitialPID:underPointer ? capturedPID : nil,
            frontmostPID:{NSWorkspace.shared.frontmostApplication?.processIdentifier},
            validateTarget: {
                guard AXIsProcessTrusted() else { throw SystemControlError.message("辅助功能权限已失效，已停止窗口操作。") }
                try self.validateTarget(window,pid:pid,application:application,launchDate:launchDate)
            },
            isTargetFocused: {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element,0.15)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
                return CFEqual(focused,window)
            },
            raiseTarget: {
                guard AXUIElementPerformAction(window,kAXRaiseAction as CFString) == .success else {
                    throw SystemControlError.message("目标应用不支持将这个窗口带到前台。请手动切回后重试。")
                }
            },
            activateTarget: {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
                NSApp.yieldActivation(to:application)
                return application.activate(from:.current,options:[])
            })
    }

    private func applyLayout(_ desired: CGRect, original: CGRect, window: AXUIElement, pid: pid_t,
                             application: NSRunningApplication, launchDate: Date?, capturedPID: pid_t?,
                             workArea: CGRect?, restoring: Bool, saveFrame: CGRect? = nil,
                             additionalValidation: () throws -> Void = {}) async throws -> WindowLayoutOutcome {
        guard let launchDate else {throw SystemControlError.message("无法确认目标应用启动身份，请重新选择窗口。")}
        func validateIdentity() throws {
            guard AXIsProcessTrusted() else { throw SystemControlError.message("辅助功能权限已失效，已停止窗口操作。") }
            try validateTarget(window,pid:pid,application:application,launchDate:launchDate)
        }
        return try await layoutTransaction.execute(requested:desired,original:original,workArea:workArea,
            resize:restoring || desired.size != original.size,allowConstrained:!restoring,
            validate: {
                try validateIdentity(); try additionalValidation()
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard front == pid else {
                    throw SystemControlError.message("前台应用已变化，已停止这次窗口布局。")
                }
            }, validateRollback:validateIdentity, read:{try self.readFrame(window)},
            setSize:{try self.setSize($0,to:window)},setPosition:{try self.setPosition($0,to:window)},
            saveOriginal: {
                if !restoring { self.rememberOriginal(DragSession(window:window,pid:pid,application:application,launchDate:launchDate,initialFrame:saveFrame ?? original,initialPointer:.zero,moveWithPointer:false)) }
            }, didRestore: {
                self.originalFrames.removeAll { $0.pid == pid && $0.launchDate == launchDate && CFEqual($0.element,window) }
                self.snappedFrames.removeAll { $0.pid == pid && $0.launchDate == launchDate && CFEqual($0.element,window) }
            })
    }

    private func raise(_ window: AXUIElement, application: NSRunningApplication) throws {
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foreground == capturedForegroundPID || foreground == ProcessInfo.processInfo.processIdentifier || foreground == application.processIdentifier else { throw SystemControlError.message("前台应用已变化，已停止切换窗口。") }
        guard AXUIElementPerformAction(window,kAXRaiseAction as CFString) == .success else { throw SystemControlError.message("目标应用拒绝将窗口带到前台。") }
        if foreground != application.processIdentifier {
            NSApp.yieldActivation(to:application)
            guard application.activate(from:.current,options:[]) else { throw SystemControlError.message("系统拒绝激活目标应用。") }
        }
    }
    private func performStateAction(_ action: WindowAction, window: AXUIElement, pid: pid_t, application: NSRunningApplication) throws -> Bool {
        func set(_ element: AXUIElement,_ attribute: String,_ value: Bool) throws {
            try checkSettable(element,attribute:attribute)
            guard AXUIElementSetAttributeValue(element,attribute as CFString,value ? kCFBooleanTrue : kCFBooleanFalse) == .success else { throw SystemControlError.message("目标应用拒绝窗口状态操作：" + action.title) }
        }
        switch action {
        case .minimize: try set(window,kAXMinimizedAttribute,true)
        case .close:
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window,kAXCloseButtonAttribute as CFString,&button) == .success,let button,CFGetTypeID(button) == AXUIElementGetTypeID(),AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString) == .success else { throw SystemControlError.message("目标窗口不支持标准关闭按钮。") }
        case .toggleFullScreen:
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window,"AXFullScreen" as CFString,&value) == .success,let full = value as? Bool else { throw SystemControlError.message("目标窗口不提供全屏状态。") }
            try set(window,"AXFullScreen",!full); try raise(window,application:application)
        case .minimizeAll,.unminimizeAll,.nextWindow,.previousWindow:
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),kAXWindowsAttribute as CFString,&value) == .success,let windows = value as? [AXUIElement], !windows.isEmpty else { throw SystemControlError.message("无法读取目标应用窗口列表。") }
            if action == .minimizeAll || action == .unminimizeAll {
                var failures = 0
                for element in windows { do { try set(element,kAXMinimizedAttribute,action == .minimizeAll) } catch { failures += 1 } }
                if failures > 0 { throw SystemControlError.message("有 \(failures) 个窗口拒绝最小化状态更改，其他窗口已处理。") }
                if action == .unminimizeAll { try raise(window,application:application) }
            } else {
                guard windows.count > 1 else { throw SystemControlError.message("目标应用只有一个窗口。") }
                let index = windows.firstIndex(where:{ CFEqual($0,window) }) ?? 0
                let next = windows[(index + (action == .nextWindow ? 1 : windows.count-1)) % windows.count]
                var minimized: CFTypeRef?; _ = AXUIElementCopyAttributeValue(next,kAXMinimizedAttribute as CFString,&minimized)
                if minimized as? Bool == true { try set(next,kAXMinimizedAttribute,false) }
                try raise(next,application:application); target = next
            }
        default: return false
        }
        return true
    }

    private func validateTarget(_ window: AXUIElement, pid: pid_t, application: NSRunningApplication, launchDate: Date?) throws {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              application.processIdentifier == pid, !application.isTerminated,
              let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
              application.launchDate == launchDate,
              WindowProcessIdentity.matches(capturedPID:pid,capturedLaunchDate:launchDate,currentPID:current.processIdentifier,currentLaunchDate:current.launchDate) else {
            throw SystemControlError.message("原目标应用已经退出或失效，请重新选择窗口。")
        }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(window, &actualPID) == .success, actualPID == pid else {
            throw SystemControlError.message("原目标窗口已经失效，请重新选择窗口。")
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
              let elements = windows as? [AXUIElement], elements.contains(where: { CFEqual($0, window) }) else {
            throw SystemControlError.message("原目标窗口已关闭，或应用不提供标准窗口列表；请重新选择可操作的窗口。")
        }
    }

    private func checkDragApplication(_ drag: DragSession) throws {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else { throw SystemControlError.message("辅助功能权限已失效，已停止窗口拖动。") }
        guard drag.pid != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == drag.pid,
              !drag.application.isTerminated,
              let current=NSRunningApplication(processIdentifier:drag.pid),!current.isTerminated,
              WindowProcessIdentity.matches(capturedPID:drag.pid,capturedLaunchDate:drag.launchDate,currentPID:current.processIdentifier,currentLaunchDate:current.launchDate) else {
            throw SystemControlError.message("前台应用或启动身份已变化，已取消这次窗口拖动。")
        }
        try validateTarget(drag.window,pid:drag.pid,application:drag.application,launchDate:drag.launchDate)
    }
    private func rememberOriginal(_ drag: DragSession) {
        guard !originalFrames.contains(where: { $0.pid == drag.pid && $0.launchDate == drag.launchDate && CFEqual($0.element, drag.window) }) else { return }
        originalFrames.removeAll {record in
            guard let current=NSRunningApplication(processIdentifier:record.pid),!current.isTerminated else{return true}
            return !WindowProcessIdentity.matches(capturedPID:record.pid,capturedLaunchDate:record.launchDate,currentPID:current.processIdentifier,currentLaunchDate:current.launchDate)
        }
        originalFrames.append(OriginalFrame(element: drag.window, pid: drag.pid, launchDate:drag.launchDate,frame: drag.initialFrame))
    }
    private func ensureNotFullScreen(_ window: AXUIElement) throws {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success, value as? Bool == true {
            throw SystemControlError.message("请先退出目标窗口的全屏模式，再使用拖动或吸附。")
        }
    }

    private func readFrame(_ window: AXUIElement) throws -> CGRect {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            throw SystemControlError.message("无法读取目标窗口的位置；这个应用可能不支持标准辅助功能窗口操作。")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              [position.x,position.y,size.width,size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0 else {
            throw SystemControlError.message("目标窗口的位置数据无效。")
        }
        return CGRect(origin: position, size: size)
    }

    private func checkSettable(_ window: AXUIElement, attribute: String) throws {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success, settable.boolValue else {
            throw SystemControlError.message("目标窗口不允许更改属性：" + attribute)
        }
    }

    private func setSize(_ size: CGSize, to window: AXUIElement) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize,&size),
              AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,value) == .success else {
            throw SystemControlError.message("目标应用拒绝调整窗口尺寸。")
        }
    }
    private func setPosition(_ position: CGPoint, to window: AXUIElement) throws {
        var position = position
        guard let value = AXValueCreate(.cgPoint,&position),
              AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,value) == .success else {
            throw SystemControlError.message("目标应用拒绝移动窗口。")
        }
    }
    private func apply(_ frame: CGRect, to window: AXUIElement, resize: Bool) throws {
        if resize { try setSize(frame.size,to:window) }
        try setPosition(frame.origin,to:window)
        if resize { try setSize(frame.size,to:window) }
    }

}

@MainActor
enum SystemActions {
    private static var sleepAssertion: IOPMAssertionID = 0
    static var isPreventingSleep: Bool { sleepAssertion != 0 }

    static func perform(id: String) throws {
        switch id {
        case "lock", "system.lock":
            guard AXIsProcessTrusted() else { throw SystemControlError.message("锁定屏幕快捷操作需要辅助功能权限。") }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else {
                throw SystemControlError.message("无法发送系统锁屏快捷键。")
            }
            down.flags = [.maskControl, .maskCommand]
            up.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        case "sleep", "system.sleep":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw SystemControlError.message("系统未接受睡眠请求。\(message.prefix(200))")
            }
        case let value where value.hasPrefix("system.") && EnhancedSystemPreset(rawValue:String(value.dropFirst(7))) != nil:
            try EnhancedSystemControls.perform(EnhancedSystemPreset(rawValue:String(value.dropFirst(7)))!)
        case "preventSleep.toggle", "system.preventSleep.toggle":
            if sleepAssertion != 0 {
                guard IOPMAssertionRelease(sleepAssertion) == kIOReturnSuccess else {
                    throw SystemControlError.message("无法解除保持唤醒，请退出搞操作以释放请求。")
                }
                sleepAssertion = 0
            } else {
                var created: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "搞操作：保持系统唤醒（不阻止合盖和手动睡眠）" as CFString, &created)
                guard result == kIOReturnSuccess else { throw SystemControlError.message("系统拒绝了保持唤醒请求。") }
                sleepAssertion = created
            }
        default: throw SystemControlError.message("未识别的系统操作：\(id)")
        }
    }

    static func releasePreventSleep() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }
}
