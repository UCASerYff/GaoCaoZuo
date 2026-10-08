import AppKit
@preconcurrency import ApplicationServices
import Combine
import IOKit.pwr_mgt

enum SystemControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum WindowAction: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case thirdLeft, thirdCenter, thirdRight
    case maximize, center, smaller, larger, nextDisplay, previousDisplay, restore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        case .topHalf: return "上半屏"
        case .bottomHalf: return "下半屏"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        case .thirdLeft: return "左侧三分之一"
        case .thirdCenter: return "中间三分之一"
        case .thirdRight: return "右侧三分之一"
        case .maximize: return "铺满工作区"
        case .center: return "窗口居中"
        case .smaller: return "缩小窗口"
        case .larger: return "放大窗口"
        case .nextDisplay: return "移到下一显示器"
        case .previousDisplay: return "移到上一显示器"
        case .restore: return "恢复原位置"
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
        case .restore: throw SystemControlError.message("需要已保存的窗口位置才能恢复。")
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

@MainActor
final class WindowManager: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var lastError: String?
    private var target: AXUIElement?
    private var targetPID: pid_t?
    private struct OriginalFrame { let element: AXUIElement; let pid: pid_t; let frame: CGRect }
    private var originalFrames: [OriginalFrame] = []
    private struct DragSession {
        let window: AXUIElement
        let pid: pid_t
        let initialFrame: CGRect
        let initialPointer: CGPoint
        let moveWithPointer: Bool
    }
    private var dragSession: DragSession?

    /// Call before bringing any GaoCaoZuo window or panel to the foreground.
    func captureTarget() {
        isTrusted = AXIsProcessTrusted()
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = nil
        targetPID = nil
        guard isTrusted else { return }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focused)
        if result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            target = (focused as! AXUIElement)
            targetPID = application.processIdentifier
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        lastError = isTrusted ? nil : "请在系统设置的“隐私与安全性 → 辅助功能”中允许搞操作。"
    }

    func perform(_ action: WindowAction) throws {
        do {
            isTrusted = AXIsProcessTrusted()
            guard isTrusted else { throw SystemControlError.message("窗口操作需要辅助功能权限，请先在设置中授权。") }
            // Direct shortcuts act on the current foreground app; the panel keeps its captured target.
            captureTarget()
            guard let window = target, let pid = targetPID,
                  let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
                throw SystemControlError.message("没有可操作的目标窗口。请先切换到需要调整的窗口，再打开操作面板。")
            }
            var fullScreen: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
               (fullScreen as? Bool) == true {
                throw SystemControlError.message("请先退出目标窗口的全屏模式，再调整布局。")
            }
            let current = try readFrame(window)
            let originalIndex = originalFrames.firstIndex { $0.pid == pid && CFEqual($0.element, window) }
            let desired: CGRect
            if action == .restore {
                guard let originalIndex else { throw SystemControlError.message("这个窗口还没有可恢复的位置记录。") }
                desired = originalFrames[originalIndex].frame
            } else {
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let screens = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit: $0.visibleFrame, primaryTop: primaryTop) }
                desired = try WindowGeometry.targetFrame(action: action, current: current, visibleFrames: screens)
            }
            try checkSettable(window, attribute: kAXPositionAttribute)
            if abs(desired.width - current.width) > 1 || abs(desired.height - current.height) > 1 {
                try checkSettable(window, attribute: kAXSizeAttribute)
            }
            do {
                try apply(desired, to: window, resize: desired.size != current.size)
                let actual = try readFrame(window)
                guard abs(actual.minX - desired.minX) <= 4, abs(actual.minY - desired.minY) <= 4,
                      abs(actual.width - desired.width) <= 4, abs(actual.height - desired.height) <= 4 else {
                    throw SystemControlError.message("目标应用限制了窗口尺寸或位置，无法完成此布局；已尝试恢复操作前的位置。")
                }
            } catch {
                try? apply(current, to: window, resize: desired.size != current.size)
                throw error
            }
            if action == .restore, let originalIndex { originalFrames.remove(at: originalIndex) }
            else if originalIndex == nil {
                originalFrames.removeAll { NSRunningApplication(processIdentifier: $0.pid)?.isTerminated != false }
                originalFrames.append(OriginalFrame(element: window, pid: pid, frame: current))
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Returns false for an ordinary click outside the focused window or on our own application.
    @discardableResult
    func beginWindowDrag(at pointer: CGPoint, moveWithPointer: Bool) throws -> Bool {
        dragSession = nil
        do {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            isTrusted = AXIsProcessTrusted()
            guard isTrusted else { throw SystemControlError.message("拖动窗口与边缘吸附需要辅助功能权限。") }
            captureTarget()
            guard let window = target, let pid = targetPID, pid == front.processIdentifier else {
                throw SystemControlError.message("这个应用没有可读取的标准前台窗口，无法开始拖动或吸附。")
            }
            AXUIElementSetMessagingTimeout(window, 0.15)
            let frame = try readFrame(window)
            guard frame.contains(pointer) else { return false }
            try ensureNotFullScreen(window)
            try checkSettable(window, attribute: kAXPositionAttribute)
            dragSession = DragSession(window: window, pid: pid, initialFrame: frame,
                                      initialPointer: pointer, moveWithPointer: moveWithPointer)
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; throw error }
    }

    func updateWindowDrag(to pointer: CGPoint) throws {
        guard let drag = dragSession, drag.moveWithPointer else { return }
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
            lastError = nil
        } catch {
            // A successful partial movement must still have a restore record.
            rememberOriginal(drag)
            dragSession = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    func endWindowDrag(at pointer: CGPoint, snap: Bool) throws {
        guard let drag = dragSession else { return }
        defer { dragSession = nil }
        do {
            try checkDragApplication(drag)
            if drag.moveWithPointer { try updateWindowDrag(to: pointer) }
            guard snap else { return }
            let current = try readFrame(drag.window)
            guard WindowDragGeometry.isWindowDrag(initialFrame: drag.initialFrame, currentFrame: current,
                                                  initialPointer: drag.initialPointer, pointer: pointer) else { return }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let visible = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit: $0.visibleFrame, primaryTop: primaryTop) }
            let physical = NSScreen.screens.map { WindowGeometry.accessibilityRect(fromAppKit: $0.frame, primaryTop: primaryTop) }
            guard let target = WindowDragGeometry.snapTarget(pointer: pointer, visibleFrames: visible, screenFrames: physical) else { return }
            try ensureNotFullScreen(drag.window)
            try checkSettable(drag.window, attribute: kAXPositionAttribute)
            try checkSettable(drag.window, attribute: kAXSizeAttribute)
            let desired = try WindowGeometry.targetFrame(action: target.action, current: current, visibleFrames: [target.visibleFrame])
            do {
                try apply(desired, to: drag.window, resize: true)
                let actual = try readFrame(drag.window)
                guard abs(actual.minX - desired.minX) <= 4, abs(actual.minY - desired.minY) <= 4,
                      abs(actual.width - desired.width) <= 4, abs(actual.height - desired.height) <= 4 else {
                    throw SystemControlError.message("目标应用限制了窗口尺寸或位置，无法完成边缘吸附。")
                }
            } catch {
                try? apply(current, to: drag.window, resize: true)
                throw error
            }
            rememberOriginal(drag)
            self.target = drag.window; targetPID = drag.pid
            lastError = nil
        } catch { lastError = error.localizedDescription; throw error }
    }

    func cancelWindowDrag() { dragSession = nil }

    private func checkDragApplication(_ drag: DragSession) throws {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else { throw SystemControlError.message("辅助功能权限已失效，已停止窗口拖动。") }
        guard drag.pid != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == drag.pid,
              NSRunningApplication(processIdentifier: drag.pid)?.isTerminated == false else {
            throw SystemControlError.message("前台应用已变化，已取消这次窗口拖动。")
        }
    }
    private func rememberOriginal(_ drag: DragSession) {
        guard !originalFrames.contains(where: { $0.pid == drag.pid && CFEqual($0.element, drag.window) }) else { return }
        originalFrames.removeAll { NSRunningApplication(processIdentifier: $0.pid)?.isTerminated != false }
        originalFrames.append(OriginalFrame(element: drag.window, pid: drag.pid, frame: drag.initialFrame))
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
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else {
            throw SystemControlError.message("目标窗口的位置数据无效。")
        }
        return CGRect(origin: position, size: size)
    }

    private func checkSettable(_ window: AXUIElement, attribute: String) throws {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success, settable.boolValue else {
            throw SystemControlError.message(attribute == kAXSizeAttribute ? "目标窗口不允许调整尺寸。" : "目标窗口不允许移动位置。")
        }
    }

    private func apply(_ frame: CGRect, to window: AXUIElement, resize: Bool) throws {
        var size = frame.size
        var position = frame.origin
        if resize {
            guard let value = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else {
                throw SystemControlError.message("目标应用拒绝调整窗口尺寸。")
            }
        }
        guard let value = AXValueCreate(.cgPoint, &position),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success else {
            throw SystemControlError.message("目标应用拒绝移动窗口。")
        }
        // A move to another screen can alter the size because the screens have different scale factors.
        if resize, let sizeValue = AXValueCreate(.cgSize, &size) {
            guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
                throw SystemControlError.message("目标应用拒绝调整跨屏后的窗口尺寸。")
            }
        }
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
