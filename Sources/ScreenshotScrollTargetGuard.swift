import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

/// Metadata only: no window title or captured content enters the target guard.
struct ScreenshotScrollWindowMetadata {
    let windowID: CGWindowID
    let processID: pid_t?
    let frame: CGRect?
    var layer: Int? = 0
    var alpha: Double? = 1
    var bundleID: String? = nil
    var ownerName = ""

    var isEligible: Bool {
        ScreenshotCaptureWindowEligibility.allows(layer: layer, alpha: alpha, processID: processID,
                                        bundleID: bundleID, ownerName: ownerName, frame: frame)
    }
}

/// CFEqual compares the remote Accessibility element's identity, rather than Swift wrapper identity.
struct ScreenshotScrollFocusIdentity: Equatable {
    private let value: CFTypeRef

    init(element: AXUIElement) { value = element }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }

    #if SCROLL_TARGET_GUARD_TESTS
    /// A CF value stands in for identity only; tests never create or query an AX element.
    init(testToken: Int) { value = NSNumber(value: testToken) }
    #endif
}

enum ScreenshotScrollFocusEvidence {
    case accessibilityUnavailable
    case accessibilityQueryFailed
    case accessibility(processID: pid_t, frame: CGRect, identity: ScreenshotScrollFocusIdentity)
}

struct ScreenshotScrollTargetSnapshot {
    let frontmostPID: pid_t?
    let windows: [ScreenshotScrollWindowMetadata]
    let focus: ScreenshotScrollFocusEvidence
    /// A probe checks the foreground again after its metadata queries.
    var foregroundStayedConsistent = true
}

enum ScreenshotScrollTargetCheckStage: String {
    case preCapture, postCapture, preScroll, postScroll
}

struct ScreenshotScrollTargetDiagnostic: Equatable, CustomStringConvertible {
    static let unknown: Int64 = -1
    let stage: ScreenshotScrollTargetCheckStage
    let expectedPID: Int64
    let actualPID: Int64
    let expectedWindowID: Int64
    let actualWindowID: Int64

    var description: String {
        "\(stage.rawValue) expectedPID=\(expectedPID) actualPID=\(actualPID) expectedWindowID=\(expectedWindowID) actualWindowID=\(actualWindowID)"
    }

    func recordFailure() {
        #if !SCROLL_TARGET_GUARD_TESTS
        // This failure-only record contains a stage and numeric identities, never titles or images.
        Logger(subsystem: "com.gaoseries.GaoCaoZuo.screenshot", category: "LongCaptureTarget").error("\(description, privacy: .public)")
        #endif
    }
}

enum ScreenshotScrollTargetFailureReason: Equatable {
    case foregroundChanged, selectedWindowUnavailable, geometryChanged, invalidRegion
    case focusUnavailable, focusQueryFailed, focusAmbiguous, focusChanged

    var message: String {
        switch self {
        case .foregroundChanged, .focusChanged:
            return "目标焦点或窗口改变，请回到原窗口后重试。"
        case .selectedWindowUnavailable:
            return "所选目标窗口已消失或不再可捕获，请重新选择。"
        case .geometryChanged:
            return "目标窗口位置或大小改变，已停止捕获，请重新选择内容范围。"
        case .invalidRegion:
            return "长截图内容范围不再完整位于所选窗口内，请重新选择。"
        case .focusUnavailable:
            return "无法继续确认原目标焦点，已暂停并保留已有帧；请检查辅助功能权限后重试。"
        case .focusQueryFailed:
            return "无法读取目标焦点，已暂停并保留已有帧，请回到原窗口后重试。"
        case .focusAmbiguous:
            return "无法唯一确认目标窗口，已暂停并保留已有帧；未授权辅助功能时，仅支持目标应用只有一个可捕获窗口的手动长截图。"
        }
    }
}

struct ScreenshotScrollTargetValidationFailure: Error {
    let reason: ScreenshotScrollTargetFailureReason
    let actualPID: pid_t?
    let actualWindowID: CGWindowID?
}

/// Stateful identity binding with pure metadata inputs. The live adapter is the only AX/CG caller.
final class ScreenshotScrollTargetGuard {
    private let target: ScreenshotScrollTargetIdentity
    private var initialFrame: CGRect?
    private var focusedIdentity: ScreenshotScrollFocusIdentity?
    var boundAccessibilityIdentity: ScreenshotScrollFocusIdentity? { focusedIdentity }

    init(target: ScreenshotScrollTargetIdentity) { self.target = target; initialFrame = target.frame }

    /// Only the AX-to-CG bridge permits subpoint rounding; frozen CG bounds remain exact.
    private func matchesAXFrame(_ ax: CGRect, _ cg: CGRect) -> Bool {
        abs(ax.minX - cg.minX) <= 0.5 && abs(ax.minY - cg.minY) <= 0.5
            && abs(ax.width - cg.width) <= 0.5 && abs(ax.height - cg.height) <= 0.5
    }

    func validate(_ snapshot: ScreenshotScrollTargetSnapshot, requiresAccessibility: Bool = false) throws -> CGRect {
        let qualified = snapshot.windows.filter { $0.processID == target.processID && $0.isEligible }
        let focusedMatches: [ScreenshotScrollWindowMetadata]
        let observedPID: pid_t?
        switch snapshot.focus {
        case .accessibility(let pid, let frame, _):
            observedPID = pid
            focusedMatches = qualified.filter { $0.processID == pid && $0.frame.map { matchesAXFrame(frame, $0) } == true }
        case .accessibilityUnavailable:
            observedPID = snapshot.frontmostPID
            focusedMatches = focusedIdentity == nil && !requiresAccessibility && qualified.count == 1 ? qualified : []
        case .accessibilityQueryFailed:
            observedPID = snapshot.frontmostPID
            focusedMatches = []
        }
        let observedID = focusedMatches.count == 1 ? focusedMatches[0].windowID : nil
        func fail(_ reason: ScreenshotScrollTargetFailureReason, pid: pid_t? = nil, id: CGWindowID? = nil) throws -> Never {
            throw ScreenshotScrollTargetValidationFailure(reason: reason, actualPID: pid ?? observedPID, actualWindowID: id ?? observedID)
        }

        guard snapshot.foregroundStayedConsistent, snapshot.frontmostPID == target.processID else {
            throw ScreenshotScrollTargetValidationFailure(reason: .foregroundChanged, actualPID: snapshot.frontmostPID, actualWindowID: nil)
        }
        // Lookup the exact selected identity; list order never substitutes for window identity.
        let selected = qualified.filter { $0.windowID == target.windowID }
        guard selected.count == 1, let bounds = selected[0].frame else { try fail(.selectedWindowUnavailable) }
        if let initialFrame, bounds != initialFrame { try fail(.geometryChanged, id: target.windowID) }
        do { _ = try ScreenshotScrollCaptureGeometry.scrollAnchor(windowBounds: bounds, selectedRegion: target.scrollRegion) }
        catch { try fail(.invalidRegion, id: target.windowID) }

        switch snapshot.focus {
        case .accessibilityUnavailable:
            // Revocation after an AX binding must not silently weaken the evidence.
            guard focusedIdentity == nil, !requiresAccessibility else { try fail(.focusUnavailable) }
            guard qualified.count == 1 else { try fail(.focusAmbiguous) }
        case .accessibilityQueryFailed:
            try fail(.focusQueryFailed)
        case .accessibility(let pid, let frame, let identity):
            guard pid == target.processID, ScreenshotCaptureWindowEligibility.validFrame(frame) else { try fail(.focusChanged) }
            guard focusedMatches.count == 1 else { try fail(.focusAmbiguous) }
            guard observedID == target.windowID else { try fail(.focusChanged) }
            if let focusedIdentity, focusedIdentity != identity { try fail(.focusChanged) }
            focusedIdentity = identity
        }
        if initialFrame == nil { initialFrame = bounds }
        return bounds
    }
}

@MainActor
protocol ScreenshotScrollTargetProbing: AnyObject {
    func sample(target: ScreenshotScrollTargetIdentity) -> ScreenshotScrollTargetSnapshot
}

/// Reads only window metadata and public focused-window identity/geometry; never requests permission.
@MainActor
final class ScreenshotLiveScrollTargetProbe: ScreenshotScrollTargetProbing {
    func sample(target: ScreenshotScrollTargetIdentity) -> ScreenshotScrollTargetSnapshot {
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let properties = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let application = NSRunningApplication(processIdentifier: target.processID)
        let windows = properties.compactMap { info -> ScreenshotScrollWindowMetadata? in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid == target.processID, let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return ScreenshotScrollWindowMetadata(windowID: id, processID: pid, frame: bounds,
                                        layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                                        alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                                        bundleID: application?.bundleIdentifier,
                                        ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "")
        }
        let focus = AXIsProcessTrusted() ? focusedWindow(processID: target.processID) : .accessibilityUnavailable
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return ScreenshotScrollTargetSnapshot(frontmostPID: frontmostAfter, windows: windows, focus: focus,
                                    foregroundStayedConsistent: frontmostBefore == frontmostAfter)
    }

    private func focusedWindow(processID: pid_t) -> ScreenshotScrollFocusEvidence {
        let application = AXUIElementCreateApplication(processID)
        guard AXUIElementSetMessagingTimeout(application, 0.2) == .success else { return .accessibilityQueryFailed }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return .accessibilityQueryFailed }
        let focused = focusedValue as! AXUIElement
        guard AXUIElementSetMessagingTimeout(focused, 0.2) == .success else { return .accessibilityQueryFailed }
        var pid: pid_t = 0
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementGetPid(focused, &pid) == .success,
              AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return .accessibilityQueryFailed }
        let position = positionValue as! AXValue, size = sizeValue as! AXValue
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return .accessibilityQueryFailed }
        var focusAfterGeometry: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusAfterGeometry) == .success,
              let focusAfterGeometry, CFGetTypeID(focusAfterGeometry) == AXUIElementGetTypeID(),
              CFEqual(focused, focusAfterGeometry) else { return .accessibilityQueryFailed }
        // AXPosition and AXSize use global desktop points with a top-left origin, just like CG bounds.
        return .accessibility(processID: pid, frame: CGRect(origin: point, size: dimensions), identity: ScreenshotScrollFocusIdentity(element: focused))
    }
}

@MainActor
enum ScreenshotScrollAccessibilityAction {
    /// Failure-only metadata; the last AX return is evidence, not an inferred cause.
    private struct FailureDiagnostic {
        enum Stage: Int {
            case region = 1, originalArea, areaBinding, descendants, marker, choices
            case beforeInput, performAction, settling, afterInput
            case pointerWait, beforeWheel
        }
        enum Operation: Int {
            case none = 0, deadline, messagingTimeout, processID, attributeValue
            case attributeCount, attributeSlice, actionNames, hitTest, performAction
        }
        enum Substep: Int {
            case none = 0, resolveArea, areaIdentity, areaGeometry, markerParent, targetParent
            case markerFrame, targetFrame, capability, postingPreflight, sourceGuard, deadlineAndFocus
            case pointerWait, pointerHit, wheelPost, motionVerify, completion
            case pointerPosition, mouseButtons
        }
        var stage = Stage.region
        var operation = Operation.none
        var substep = Substep.none
        var attribute = 0
        var lastAXResult: Int32 = AXError.success.rawValue
        var visited = 0, skipped = 0, content = 0, choices = 0
        var actionAttempted = false, actionSucceeded = false
        var geometryChoices = 0, actionArraysParsed = 0, inputStrategy = 0
        var wheelPosted = false, logicalInputState = 0
        var pointerInsideROI = -1, pointerWindowMatches = -1, pointerAreaMatches = -1
        var pointerStayed = -1, pointerButtonsReleased = -1, pointerWaitMilliseconds = -1
        var areaIdentityMatches = -1, areaFrameMatches = -1
        var markerFrameParsed = -1, targetFrameParsed = -1
        var motionValuesAvailable = false, verifyAttempted = false, verifyPassed = false
        var markerDelta = 0.0, targetDelta = 0.0, verifyFailure = 0

        mutating func beginGeometryCheck() {
            areaIdentityMatches = -1; areaFrameMatches = -1
            markerFrameParsed = -1; targetFrameParsed = -1
            motionValuesAvailable = false; markerDelta = 0; targetDelta = 0
            verifyAttempted = false; verifyPassed = false; verifyFailure = 0
        }

        mutating func observed(_ result: AXError, _ operation: Operation, _ name: CFString? = nil) -> AXError {
            self.operation = operation
            // Codes are fixed metadata names; never log an AX value, title, or description.
            let attributes = [kAXRoleAttribute, kAXWindowAttribute, kAXTopLevelUIElementAttribute,
                              kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute,
                              kAXIndexAttribute, kAXChildrenAttribute, kAXVisibleChildrenAttribute]
            attribute = name.flatMap { attributes.firstIndex(of: $0 as String) }.map { $0 + 1 } ?? 0
            lastAXResult = result.rawValue
            return result
        }

        func recordFailure() {
            #if !SCROLL_TARGET_GUARD_TESTS
            Logger(subsystem: "com.gaoseries.GaoCaoZuo.screenshot", category: "LongCaptureScroll").error("stage=\(stage.rawValue, privacy: .public) operation=\(operation.rawValue, privacy: .public) attribute=\(attribute, privacy: .public) lastAXResult=\(lastAXResult, privacy: .public) visited=\(visited, privacy: .public) skipped=\(skipped, privacy: .public) content=\(content, privacy: .public) choices=\(choices, privacy: .public) actionAttempted=\(actionAttempted, privacy: .public) actionSucceeded=\(actionSucceeded, privacy: .public) geometryChoices=\(geometryChoices, privacy: .public) actionArraysParsed=\(actionArraysParsed, privacy: .public) inputStrategy=\(inputStrategy, privacy: .public) pixelPosted=\(wheelPosted, privacy: .public) wheelPosted=\(wheelPosted, privacy: .public) postedEventCount=\(wheelPosted ? 1 : 0, privacy: .public) logicalInputState=\(logicalInputState, privacy: .public) substep=\(substep.rawValue, privacy: .public) areaIdentityMatches=\(areaIdentityMatches, privacy: .public) areaFrameMatches=\(areaFrameMatches, privacy: .public) markerFrameParsed=\(markerFrameParsed, privacy: .public) targetFrameParsed=\(targetFrameParsed, privacy: .public) motionValuesAvailable=\(motionValuesAvailable, privacy: .public) markerDelta=\(markerDelta, privacy: .public) targetDelta=\(targetDelta, privacy: .public) verifyAttempted=\(verifyAttempted, privacy: .public) verifyPassed=\(verifyPassed, privacy: .public) verifyFailure=\(verifyFailure, privacy: .public) pointerInsideROI=\(pointerInsideROI, privacy: .public) pointerWindowMatches=\(pointerWindowMatches, privacy: .public) pointerAreaMatches=\(pointerAreaMatches, privacy: .public) pointerStayed=\(pointerStayed, privacy: .public) pointerButtonsReleased=\(pointerButtonsReleased, privacy: .public) pointerWaitMilliseconds=\(pointerWaitMilliseconds, privacy: .public)")
            #endif
        }
    }

    /// Session-local ordering hints only. Every hinted reference is checked again before use.
    final class Cursor {
        fileprivate var area: AXUIElement?
        fileprivate var areaFrame: CGRect?
        fileprivate var hints: [SiblingHint] = []
    }
    fileprivate struct SiblingHint {
        let parent: AXUIElement
        let child: AXUIElement
        let index: Int
    }
    /// One native action, or one wheel at the real pointer after exact source hits. Never retry.
    static func scrollDown(target: ScreenshotScrollTargetIdentity, anchor: CGPoint, requestedPoints: CGFloat,
                           windowIdentity: ScreenshotScrollFocusIdentity, cursor: Cursor, waitingForPointer: () -> Void = {},
                           revalidate: () throws -> Void) async throws {
        guard #available(macOS 26.0, *) else {
            throw ScreenshotCaptureFailure.unsupported("此系统版本不支持可核验的滚入视口动作，请手动滚动后捕获下一帧。")
        }
        try await scrollToVisible(target: target, anchor: anchor, requestedPoints: requestedPoints,
                                  windowIdentity: windowIdentity, cursor: cursor,
                                  waitingForPointer: waitingForPointer, revalidate: revalidate)
    }

    @available(macOS 26.0, *)
    private static func scrollToVisible(target: ScreenshotScrollTargetIdentity, anchor: CGPoint, requestedPoints: CGFloat,
                                        windowIdentity: ScreenshotScrollFocusIdentity, cursor: Cursor, waitingForPointer: () -> Void,
                                        revalidate: () throws -> Void) async throws {
        var diagnostic = FailureDiagnostic()
        var completed = false
        var attempt = ScreenshotScrollInputPolicy.Attempt()
        defer {
            if !completed {
                attempt.refuse()
                diagnostic.logicalInputState = attempt.state.rawValue
                diagnostic.recordFailure()
            }
        }
        let transactionDeadline = ProcessInfo.processInfo.systemUptime + 5
        var phaseDeadline = ProcessInfo.processInfo.systemUptime + 2
        let app = AXUIElementCreateApplication(target.processID)
        let action = NSAccessibility.Action.scrollToVisibleAction.rawValue as CFString
        let unavailable = ScreenshotCaptureFailure.unsupported("无法核验原滚动区域内的小步滚入目标，未发送动作；请手动滚动后捕获下一帧。")
        guard let roi = target.scrollRegion, roi.contains(anchor) else { throw unavailable }

        func prepare(_ element: AXUIElement) throws {
            try Task.checkCancellation()
            let remaining = min(phaseDeadline, transactionDeadline) - ProcessInfo.processInfo.systemUptime
            var pid: pid_t = 0
            guard remaining > 0 else { diagnostic.operation = .deadline; diagnostic.attribute = 0; throw unavailable }
            guard diagnostic.observed(AXUIElementSetMessagingTimeout(element, Float(min(0.2, remaining))), .messagingTimeout) == .success,
                  diagnostic.observed(AXUIElementGetPid(element, &pid), .processID) == .success,
                  pid == target.processID else { throw unavailable }
        }
        func optionalValue(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef? {
            try prepare(element)
            var raw: CFTypeRef?
            let result = diagnostic.observed(AXUIElementCopyAttributeValue(element, name, &raw), .attributeValue, name)
            try Task.checkCancellation()
            switch result {
            case .success: return raw
            case .attributeUnsupported, .noValue, .notImplemented: return nil
            default: throw unavailable
            }
        }
        func value(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef {
            guard let raw = try optionalValue(element, name) else { throw unavailable }
            return raw
        }
        func elementValue(_ element: AXUIElement, _ name: CFString) throws -> AXUIElement {
            let raw = try value(element, name)
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw unavailable }
            return raw as! AXUIElement
        }
        func sameWindow(_ element: AXUIElement) throws {
            let window = try elementValue(element, kAXWindowAttribute as CFString)
            let top = try elementValue(element, kAXTopLevelUIElementAttribute as CFString)
            try prepare(window); try prepare(top)
            guard ScreenshotScrollFocusIdentity(element: window) == windowIdentity,
                  ScreenshotScrollFocusIdentity(element: top) == windowIdentity else { throw unavailable }
        }
        func role(_ element: AXUIElement) throws -> String {
            guard let result = try value(element, kAXRoleAttribute as CFString) as? String else { throw unavailable }
            return result
        }
        func frame(_ element: AXUIElement) throws -> CGRect? {
            guard let rawPosition = try optionalValue(element, kAXPositionAttribute as CFString),
                  let rawSize = try optionalValue(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
            let position = rawPosition as! AXValue, size = rawSize as! AXValue
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
                  AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
            let result = CGRect(origin: point, size: dimensions)
            return ScreenshotCaptureWindowEligibility.validFrame(result) ? result : nil
        }
        // A remote provider may expose a large document. Read bounded reference slices only,
        // never AXContents or document text. The anchor and last verified target locate siblings.
        typealias ParentPair = (child: AXUIElement, parent: AXUIElement)
        var anchorParents: [ParentPair] = []
        var discoveredEdges: [SiblingHint] = []
        var indexReferenceBudget = 512
        func childCount(_ element: AXUIElement, _ attribute: CFString) throws -> Int {
            try prepare(element)
            var count: CFIndex = 0
            let result = diagnostic.observed(AXUIElementGetAttributeValueCount(element, attribute, &count), .attributeCount, attribute)
            if [.attributeUnsupported, .noValue, .notImplemented].contains(result) { return 0 }
            guard result == .success, count >= 0 else { throw unavailable }
            return count
        }
        func slice(_ element: AXUIElement, _ attribute: CFString, start: Int, maximum: Int) throws -> [AXUIElement] {
            let count = try childCount(element, attribute)
            guard start >= 0, start < count else { return [] }
            var raw: CFArray?
            try prepare(element)
            guard diagnostic.observed(AXUIElementCopyAttributeValues(element, attribute, start, min(maximum, count - start), &raw), .attributeSlice, attribute) == .success,
                  let items = raw as? [AXUIElement], items.count <= maximum else { throw unavailable }
            return items
        }
        func locate(_ child: AXUIElement, in parent: AXUIElement) throws -> Int? {
            // AXIndex is merely a hint: verify its reference against this exact parent's children.
            if let number = try optionalValue(child, kAXIndexAttribute as CFString) as? NSNumber {
                let index = number.intValue
                if index >= 0, number.doubleValue == Double(index),
                   let atIndex = try slice(parent, kAXChildrenAttribute as CFString, start: index, maximum: 1).first,
                   CFEqual(atIndex, child) { return index }
            }
            var offset = 0
            let count = try childCount(parent, kAXChildrenAttribute as CFString)
            while offset < count, indexReferenceBudget > 0 {
                let amount = min(32, count - offset, indexReferenceBudget)
                let items = try slice(parent, kAXChildrenAttribute as CFString, start: offset, maximum: amount)
                indexReferenceBudget -= amount
                if let index = items.firstIndex(where: { CFEqual($0, child) }) { return offset + index }
                guard !items.isEmpty else { return nil }
                offset += items.count
            }
            return nil
        }
        func limitedChildren(_ element: AXUIElement) throws -> [AXUIElement] {
            let visible = try slice(element, kAXVisibleChildrenAttribute as CFString, start: 0, maximum: 8)
            var start = 0
            // A fresh anchor wins after a legitimate manual scroll; an old valid index is
            // only an ordering hint and must not strand the search near an earlier viewport.
            if let pair = anchorParents.first(where: { CFEqual($0.parent, element) }),
               let index = try locate(pair.child, in: element) {
                start = max(0, index - 2)
            } else if let hint = cursor.hints.first(where: { CFEqual($0.parent, element) }) {
                if let atIndex = try slice(element, kAXChildrenAttribute as CFString, start: hint.index, maximum: 1).first,
                   CFEqual(atIndex, hint.child) {
                    start = max(0, hint.index - 2)
                } else if let freshIndex = try locate(hint.child, in: element) {
                    start = max(0, freshIndex - 2)
                }
            }
            let direct = try slice(element, kAXChildrenAttribute as CFString, start: start, maximum: 8)
            for (offset, child) in direct.enumerated() {
                discoveredEdges.append(SiblingHint(parent: element, child: child, index: start + offset))
            }
            var result = visible
            for item in direct where !result.contains(where: { CFEqual($0, item) }) { result.append(item) }
            return result
        }
        func actionCapability(_ element: AXUIElement) throws -> ScreenshotScrollInputPolicy.Capability {
            try prepare(element)
            var raw: CFArray?
            let result = diagnostic.observed(AXUIElementCopyActionNames(element, &raw), .actionNames)
            // Unknown action capability never authorizes CG; another verified native target may still win.
            // prepare() identity/deadline failures continue to throw before this classification.
            guard result == .success, let names = raw as? [String] else { return .unknown }
            diagnostic.actionArraysParsed += 1
            return names.contains(action as String) ? .advertised : .absent
        }
        typealias Node = (element: AXUIElement, frame: CGRect, role: String)
        func resolveArea(at point: CGPoint) throws -> (area: AXUIElement, frame: CGRect, ancestors: [Node], parents: [ParentPair]) {
            try prepare(app)
            var hit: AXUIElement?
            guard diagnostic.observed(AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit), .hitTest) == .success,
                  var current = hit else { throw unavailable }
            var ancestors: [Node] = []
            var parents: [ParentPair] = []
            for _ in 0..<24 {
                let currentRole = try role(current)
                if currentRole == kAXWindowRole as String { throw unavailable }
                try sameWindow(current)
                if currentRole == kAXScrollAreaRole as String {
                    guard let bounds = try frame(current), bounds.contains(roi) else { throw unavailable }
                    return (current, bounds, ancestors, parents)
                }
                if let bounds = try frame(current) { ancestors.append((current, bounds, currentRole)) }
                let parent = try elementValue(current, kAXParentAttribute as CFString)
                parents.append((current, parent))
                current = parent
            }
            throw unavailable
        }
        func requireOriginalArea(_ element: AXUIElement, _ area: AXUIElement) throws {
            var current = element
            for _ in 0..<24 {
                let currentRole = try role(current)
                try sameWindow(current)
                if currentRole == kAXScrollAreaRole as String {
                    guard CFEqual(current, area) else { throw unavailable }
                    return
                }
                if currentRole == kAXWindowRole as String { throw unavailable }
                current = try elementValue(current, kAXParentAttribute as CFString)
            }
            throw unavailable
        }

        diagnostic.stage = .originalArea
        let original = try resolveArea(at: anchor)
        diagnostic.stage = .areaBinding
        if let boundArea = cursor.area {
            guard CFEqual(boundArea, original.area), cursor.areaFrame == original.frame else { throw unavailable }
        } else {
            cursor.area = original.area; cursor.areaFrame = original.frame
        }
        anchorParents = original.parents
        var nodes = original.ancestors
        var seen: [AXUIElement] = []
        diagnostic.stage = .descendants
        var queue = try limitedChildren(original.area).map { (element: $0, depth: 1) }
        var visited = 0
        let descendantBudget = max(0, 48 - original.ancestors.count)
        while !queue.isEmpty, visited < descendantBudget {
            let item = queue.removeFirst()
            if seen.contains(where: { CFEqual($0, item.element) }) { continue }
            seen.append(item.element); visited += 1
            diagnostic.visited = visited
            let itemRole = try role(item.element)
            // A nested scroll area is a separate input target, even within the same window.
            if itemRole == kAXScrollAreaRole as String || itemRole == kAXWindowRole as String { continue }
            // These controls cannot be content targets; do not require their unrelated window metadata.
            if itemRole == kAXScrollBarRole as String || itemRole == kAXValueIndicatorRole as String {
                diagnostic.skipped += 1
                continue
            }
            try sameWindow(item.element)
            if !nodes.contains(where: { CFEqual($0.element, item.element) }), let bounds = try frame(item.element) {
                nodes.append((item.element, bounds, itemRole))
            }
            if item.depth < 3 {
                let descendants = try limitedChildren(item.element)
                let room = max(0, 64 - queue.count)
                queue.append(contentsOf: descendants.prefix(room).map { (element: $0, depth: item.depth + 1) })
            }
        }
        let content = nodes.filter { node in
            node.role != kAXScrollBarRole as String && node.role != kAXValueIndicatorRole as String
                && node.frame.minX <= anchor.x && node.frame.maxX >= anchor.x
        }
        diagnostic.content = content.count
        diagnostic.stage = .marker
        // Prefer a small visible content element over a stationary clipping container.
        let markers = content.filter { $0.frame.intersects(roi) && $0.frame != original.frame }
            .sorted { $0.frame.height < $1.frame.height }
        guard let marker = markers.first else { throw unavailable }
        diagnostic.stage = .choices
        var choices: [(node: Node, plan: ScreenshotScrollVisibilityPlan, capability: ScreenshotScrollInputPolicy.Capability)] = []
        for node in content where !CFEqual(node.element, marker.element) {
            guard let plan = try? ScreenshotScrollVisibilityPlan.makePlan(viewport: original.frame, roi: roi,
                                                               marker: marker.frame, target: node.frame,
                                                               requestedPoints: requestedPoints) else { continue }
            diagnostic.geometryChoices += 1
            let capability = try actionCapability(node.element)
            choices.append((node, plan, capability))
            if capability == .advertised { diagnostic.choices += 1 }
        }
        let decision: ScreenshotScrollInputPolicy.Decision
        do {
            decision = try ScreenshotScrollInputPolicy.select(choices.map { .init(plan: $0.plan, capability: $0.capability) },
                                                    requestedPoints: requestedPoints)
        } catch { throw unavailable }
        let choice = choices[decision.index]
        diagnostic.inputStrategy = decision.strategy.rawValue

        // Reuse the original references and the bounded anchor hit-test. Never rescan or reselect candidates.
        func checkedGeometry(requireUnmoved: Bool, hitPoint: CGPoint? = nil) throws -> (areaFrame: CGRect, marker: CGRect, target: CGRect) {
            diagnostic.beginGeometryCheck()
            diagnostic.substep = .resolveArea
            let latest = try resolveArea(at: hitPoint ?? anchor)
            diagnostic.substep = .areaIdentity
            diagnostic.areaIdentityMatches = CFEqual(original.area, latest.area) ? 1 : 0
            if hitPoint != nil { diagnostic.pointerAreaMatches = diagnostic.areaIdentityMatches }
            guard diagnostic.areaIdentityMatches == 1 else { throw unavailable }
            diagnostic.substep = .areaGeometry
            diagnostic.areaFrameMatches = original.frame == latest.frame ? 1 : 0
            guard diagnostic.areaFrameMatches == 1 else { throw unavailable }
            diagnostic.substep = .markerParent
            try requireOriginalArea(marker.element, original.area)
            diagnostic.substep = .targetParent
            try requireOriginalArea(choice.node.element, original.area)
            diagnostic.substep = .markerFrame
            let markerNow = try frame(marker.element)
            diagnostic.markerFrameParsed = markerNow == nil ? 0 : 1
            guard let markerNow, !requireUnmoved || markerNow == marker.frame else { throw unavailable }
            diagnostic.substep = .targetFrame
            let targetNow = try frame(choice.node.element)
            diagnostic.targetFrameParsed = targetNow == nil ? 0 : 1
            guard let targetNow, !requireUnmoved || targetNow == choice.node.frame else { throw unavailable }
            return (latest.frame, markerNow, targetNow)
        }
        func checkedInputReadiness(hitPoint: CGPoint? = nil) throws -> (capability: ScreenshotScrollInputPolicy.Capability, postingAvailable: Bool) {
            _ = try checkedGeometry(requireUnmoved: true, hitPoint: hitPoint)
            diagnostic.substep = .capability
            let capability = try actionCapability(choice.node.element)
            diagnostic.substep = .postingPreflight
            // Existing access only. No request or private acceptance/lease state enters production.
            let postingAvailable = decision.strategy == .native || CGPreflightPostEventAccess()
            return (capability, postingAvailable)
        }
        func checkDeadlineAndFocus() throws {
            diagnostic.substep = .deadlineAndFocus
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < min(phaseDeadline, transactionDeadline),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else { throw unavailable }
        }
        func finalSourceGuard() throws {
            diagnostic.substep = .sourceGuard
            try prepare(choice.node.element)
            // Rechecks the same production source, CG window, original ROI and focused-window identity.
            try revalidate()
            try checkDeadlineAndFocus()
        }
        func readPointer() throws -> CGPoint {
            diagnostic.substep = .pointerPosition
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < min(phaseDeadline, transactionDeadline),
                  let event = CGEvent(source: nil) else { throw unavailable }
            let point = event.location
            guard point.x.isFinite, point.y.isFinite else { throw unavailable }
            return point
        }
        func pointerInRegion() async throws -> CGPoint {
            diagnostic.stage = .pointerWait
            diagnostic.substep = .pointerWait
            let began = ProcessInfo.processInfo.systemUptime
            let deadline = try ScreenshotScrollInputPolicy.PointerWaitDeadline.fixedDeadline(
                now: began, phaseDeadline: phaseDeadline, transactionDeadline: transactionDeadline)
            var announced = false
            while true {
                try Task.checkCancellation()
                do { try ScreenshotScrollInputPolicy.PointerWaitDeadline.requireActive(now: ProcessInfo.processInfo.systemUptime, deadline: deadline) }
                catch { throw ScreenshotCaptureFailure.unsupported("鼠标未及时回到原选区，本次未发送滚动；请核对后手动滚动。") }
                let point = try readPointer()
                diagnostic.pointerWaitMilliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1_000)
                diagnostic.pointerInsideROI = roi.contains(point) ? 1 : 0
                if diagnostic.pointerInsideROI == 1 { return point }
                if !announced { waitingForPointer(); announced = true }
                // Only pointer/cancellation/clock polling; no AX scan, activation or input while waiting.
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        func checkPointerHit(_ expected: CGPoint) throws {
            let point = try readPointer()
            diagnostic.pointerStayed = point == expected ? 1 : 0
            diagnostic.pointerInsideROI = roi.contains(point) ? 1 : 0
            guard diagnostic.pointerStayed == 1, diagnostic.pointerInsideROI == 1 else { throw unavailable }
            diagnostic.substep = .mouseButtons
            // Includes physical devices and synthesized button state; any held button refuses the wheel.
            diagnostic.pointerButtonsReleased = NSEvent.pressedMouseButtons == 0 ? 1 : 0
            guard diagnostic.pointerButtonsReleased == 1 else { throw unavailable }
            diagnostic.substep = .pointerHit
            let cocoa = try ScreenshotScrollInputPolicy.cocoaPoint(fromQuartz: point, primaryDisplayBounds: CGDisplayBounds(CGMainDisplayID()))
            // Public WindowServer hit-test returns the actual frontmost mouse target, not a bounds guess.
            let windowNumber = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
            diagnostic.pointerWindowMatches = windowNumber > 0 && UInt64(windowNumber) == UInt64(target.windowID) ? 1 : 0
            guard diagnostic.pointerWindowMatches == 1 else { throw unavailable }
        }

        diagnostic.stage = .beforeInput
        let readiness = try checkedInputReadiness()
        do {
            try ScreenshotScrollInputPolicy.requireReady(decision, freshCapability: readiness.capability,
                                               inputAlreadyAttempted: attempt.state != .unused,
                                               postingAvailable: readiness.postingAvailable)
        } catch { throw unavailable }
        switch decision.strategy {
        case .native:
            try finalSourceGuard()
            do {
                try attempt.begin(decision: decision, freshCapability: readiness.capability,
                                  postingAvailable: readiness.postingAvailable)
            } catch { throw unavailable }
            diagnostic.stage = .performAction
            diagnostic.actionAttempted = true
            let result = diagnostic.observed(AXUIElementPerformAction(choice.node.element, action), .performAction)
            guard result == .success else {
                throw ScreenshotCaptureFailure.unsupported("滚入视口动作结果未确认（AX \(result.rawValue)），未重复发送；请检查原窗口后手动滚动。")
            }
            diagnostic.actionSucceeded = true
        case .windowServer:
            let point = try await pointerInRegion()
            try checkDeadlineAndFocus()
            diagnostic.stage = .beforeWheel
            try checkPointerHit(point)
            // The actual pointer must hit the same bound AX area, PID and window, not merely the ROI rectangle.
            let wheelReadiness = try checkedInputReadiness(hitPoint: point)
            do {
                try ScreenshotScrollInputPolicy.requireReady(decision, freshCapability: wheelReadiness.capability,
                                                   inputAlreadyAttempted: attempt.state != .unused,
                                                   postingAvailable: wheelReadiness.postingAvailable)
            } catch { throw unavailable }
            guard let event = ScreenshotScrollPixelEventBundle(anchor: point, pixels: decision.pixels) else { throw unavailable }
            try finalSourceGuard()
            try checkPointerHit(point)
            try checkDeadlineAndFocus()
            do {
                try attempt.begin(decision: decision, freshCapability: wheelReadiness.capability,
                                  postingAvailable: wheelReadiness.postingAvailable)
            } catch { throw unavailable }
            diagnostic.stage = .performAction
            diagnostic.substep = .wheelPost
            event.wheel.post(tap: .cghidEventTap)
            // One public event-stream post, no prime or cursor relocation. Return is not delivery evidence.
            diagnostic.wheelPosted = true
        }
        diagnostic.stage = .settling
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation()
        phaseDeadline = min(transactionDeadline, ProcessInfo.processInfo.systemUptime + 2)
        diagnostic.stage = .afterInput
        do {
            let after = try checkedGeometry(requireUnmoved: false)
            let markerDelta = Double(marker.frame.minY - after.marker.minY)
            let targetDelta = Double(choice.node.frame.minY - after.target.minY)
            diagnostic.motionValuesAvailable = markerDelta.isFinite && targetDelta.isFinite
            if diagnostic.motionValuesAvailable {
                diagnostic.markerDelta = markerDelta; diagnostic.targetDelta = targetDelta
            }
            diagnostic.substep = .motionVerify
            diagnostic.verifyAttempted = true
            do {
                _ = try choice.plan.verify(viewportAfter: after.areaFrame, roiAfter: target.scrollRegion,
                                           markerAfter: after.marker, targetAfter: after.target)
                diagnostic.verifyPassed = true
            } catch let failure as ScreenshotScrollVisibilityPlan.Failure {
                diagnostic.verifyFailure = failure.rawValue
                throw failure
            }
            diagnostic.substep = .completion
            try prepare(marker.element); try prepare(choice.node.element)
            guard ProcessInfo.processInfo.systemUptime < min(phaseDeadline, transactionDeadline),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else { throw unavailable }
            var hints: [SiblingHint] = []
            var current = choice.node.element
            for _ in 0..<3 {
                guard !CFEqual(current, original.area),
                      let edge = discoveredEdges.last(where: { CFEqual($0.child, current) }) else { break }
                hints.append(edge); current = edge.parent
            }
            cursor.hints = hints
            completed = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenshotCaptureFailure.unsupported("滚动后的实际位移或窗口几何未通过核验，未追加截图；请核对原窗口后手动捕获。")
        }
    }
}
