import AppKit
import ApplicationServices
import CoreImage
import CryptoKit
import Foundation
import Carbon

// MARK: - SelectionSnapshot

public struct SelectionSnapshot: Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let launchIdentity: String?
    public let element: AXUIElement?
    public let window: AXUIElement?
    public let selectedText: String
    public let textSHA256: String
    public let range: CFRange?
    public let timestamp: Date
    public let generation: UInt64
    public let isFromClipboardFallback: Bool

    public init(pid: pid_t, bundleID: String?, launchIdentity: String?, element: AXUIElement?,
                selectedText: String, range: CFRange?, timestamp: Date = Date(),
                generation: UInt64 = 0, isFromClipboardFallback: Bool = false, window: AXUIElement? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.launchIdentity = launchIdentity
        self.element = element
        self.window = window
        self.selectedText = selectedText
        self.textSHA256 = SHA256.hash(data: Data(selectedText.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        self.range = range
        self.timestamp = timestamp
        self.generation = generation
        self.isFromClipboardFallback = isFromClipboardFallback
    }

    public static func capture(generation: UInt64 = 0) -> SelectionSnapshot? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)

        var focusedElementValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let value = focusedElementValue, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !SelectionTargetValidator.isSecure(element) else { return nil }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let bundleID = runningApp?.bundleIdentifier
        let launchIdentity = WindowProcessIdentity.auditTokenString(for: pid)

        // Read selected text
        var selectedTextValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
              let text = selectedTextValue as? String,
              !text.isEmpty, text.utf8.count <= 1_048_576 else {
            return nil
        }

        // Read selected range if available
        var selectedRangeValue: AnyObject?
        var range: CFRange? = nil
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
           let rangeVal = selectedRangeValue, CFGetTypeID(rangeVal) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(rangeVal as! AXValue, .cfRange, &r) {
                range = r
            }
        }

        return SelectionSnapshot(
            pid: pid,
            bundleID: bundleID,
            launchIdentity: launchIdentity,
            element: element,
            selectedText: text,
            range: range,
            timestamp: Date(),
            generation: generation,
            isFromClipboardFallback: false,
            window: SelectionTargetValidator.window(for: element, pid: pid)
        )
    }

    public func matchesTarget(currentPID: pid_t?, currentBundleID: String?, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration else { return false }
        return currentPID == pid && currentPID != nil && currentBundleID == bundleID
    }

    func withGeneration(_ value: UInt64) -> SelectionSnapshot {
        SelectionSnapshot(pid: pid, bundleID: bundleID, launchIdentity: launchIdentity, element: element,
            selectedText: selectedText, range: range, timestamp: timestamp, generation: value,
            isFromClipboardFallback: isFromClipboardFallback, window: window)
    }

    public static func == (lhs: SelectionSnapshot, rhs: SelectionSnapshot) -> Bool {
        return lhs.pid == rhs.pid &&
               lhs.bundleID == rhs.bundleID &&
               lhs.launchIdentity == rhs.launchIdentity &&
               lhs.selectedText == rhs.selectedText &&
               lhs.textSHA256 == rhs.textSHA256 &&
               lhs.range?.location == rhs.range?.location && lhs.range?.length == rhs.range?.length &&
               SelectionTargetValidator.sameElement(lhs.element, rhs.element) &&
               SelectionTargetValidator.sameElement(lhs.window, rhs.window) &&
               lhs.generation == rhs.generation &&
               lhs.isFromClipboardFallback == rhs.isFromClipboardFallback
    }
}

/// Evidence is separate from AX access so expiry, identity, generation and range
/// failures can be exercised without opening an application or sending input.
public struct SelectionTargetEvidence {
    public var pid: pid_t
    public var bundleID: String?
    public var launchIdentity: String?
    public var foregroundPID: pid_t?
    public var sameElement: Bool
    public var sameWindow: Bool
    public var selectedRange: CFRange?
    public var textSHA256: String
    public var secureInput: Bool
    public var writable: Bool
}

public enum SelectionTargetValidator {
    public static func refusal(snapshot: SelectionSnapshot, evidence: SelectionTargetEvidence,
                               generation: UInt64, now: Date = Date()) -> String? {
        guard !snapshot.isFromClipboardFallback else { return "剪贴板文本没有可验证的选区，只能复制处理结果。" }
        guard snapshot.generation == generation else { return "选区操作已过期，请重新选择文字。" }
        guard now.timeIntervalSince(snapshot.timestamp) >= 0, now.timeIntervalSince(snapshot.timestamp) <= 60 else {
            return "选区已超过一分钟，请重新选择文字。"
        }
        guard !evidence.secureInput else { return "安全输入状态下不读取或替换选区。" }
        guard snapshot.pid > 0, evidence.pid == snapshot.pid, evidence.foregroundPID == snapshot.pid,
              evidence.bundleID == snapshot.bundleID,
              let launch = snapshot.launchIdentity, !launch.isEmpty, evidence.launchIdentity == launch else {
            return "原应用已退出或前台目标已改变，未写入文字。"
        }
        guard evidence.sameElement, evidence.sameWindow else { return "原窗口或输入区域已改变，未写入文字。" }
        guard let expected = snapshot.range, expected.location >= 0, expected.length > 0,
              let actual = evidence.selectedRange, actual.location == expected.location, actual.length == expected.length,
              evidence.textSHA256 == snapshot.textSHA256 else { return "原选区或文字已改变，未写入文字。" }
        guard evidence.writable else { return "此输入区域不允许替换选中文字。" }
        return nil
    }

    static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) { case (nil, nil): return true; case let (a?, b?): return CFEqual(a, b); default: return false }
    }

    static func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
            && (value as? String) == kAXSecureTextFieldSubrole
    }

    static func window(for element: AXUIElement, pid: pid_t) -> AXUIElement? {
        elementAttribute(element, kAXWindowAttribute) ?? elementAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    @MainActor static func evidence(for snapshot: SelectionSnapshot) -> SelectionTargetEvidence {
        let secure = IsSecureEventInputEnabled() || snapshot.element.map(isSecure) == true
        var result = SelectionTargetEvidence(pid: 0, bundleID: nil, launchIdentity: nil,
            foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            sameElement: false, sameWindow: false, selectedRange: nil, textSHA256: "",
            secureInput: secure, writable: false)
        guard !secure, AXIsProcessTrusted(), let element = snapshot.element else { return result }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return result }
        result.pid = pid
        result.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        result.launchIdentity = WindowProcessIdentity.auditTokenString(for: pid)
        let system = AXUIElementCreateSystemWide()
        result.sameElement = elementAttribute(system, kAXFocusedUIElementAttribute).map { CFEqual($0, element) } ?? false
        result.sameWindow = snapshot.window != nil && sameElement(snapshot.window, window(for: element, pid: pid))
        guard result.pid == snapshot.pid, result.bundleID == snapshot.bundleID,
              result.foregroundPID == snapshot.pid, snapshot.launchIdentity != nil,
              result.launchIdentity == snapshot.launchIdentity, result.sameElement, result.sameWindow else { return result }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange(); if AXValueGetValue(value as! AXValue, .cfRange, &range) { result.selectedRange = range }
        }
        value = nil
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, text.utf8.count <= 1_048_576 {
            result.textSHA256 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var settable: DarwinBoolean = false
        result.writable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return result
    }
}

// MARK: - SelectionTransformations

public enum SelectionTransformations {
    public static func uppercase(_ text: String) -> String {
        text.uppercased()
    }

    public static func lowercase(_ text: String) -> String {
        text.lowercased()
    }

    public static func titleCase(_ text: String) -> String {
        text.capitalized
    }

    public static func toHalfWidth(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x3000 {
                result.append(" ")
            } else if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                if let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                    result.append(String(converted))
                } else {
                    result.append(String(scalar))
                }
            } else {
                result.append(String(scalar))
            }
        }
        return result
    }

    public static func toFullWidth(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x20 {
                result.append("\u{3000}")
            } else if scalar.value >= 0x21 && scalar.value <= 0x7E {
                if let converted = UnicodeScalar(scalar.value + 0xFEE0) {
                    result.append(String(converted))
                } else {
                    result.append(String(scalar))
                }
            } else {
                result.append(String(scalar))
            }
        }
        return result
    }

    public static func cleanupWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let cleanedLines = lines.map { line in
            line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return cleanedLines.joined(separator: "\n")
    }

    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    public static func base64Decode(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    public static func urlDecode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    public struct TextStatistics: Equatable {
        public let characterCount: Int
        public let nonWhitespaceCount: Int
        public let wordCount: Int
        public let cjkCharacterCount: Int
        public let lineCount: Int
        public let byteCount: Int
    }

    public static func statistics(_ text: String) -> TextStatistics {
        let charCount = text.count
        let nonWsCount = text.filter { !$0.isWhitespace }.count
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var cjkCount = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        let lines = text.components(separatedBy: .newlines).count
        let bytes = text.utf8.count
        return TextStatistics(
            characterCount: charCount,
            nonWhitespaceCount: nonWsCount,
            wordCount: words.count,
            cjkCharacterCount: cjkCount,
            lineCount: lines,
            byteCount: bytes
        )
    }

    public static func generateQRCode(_ text: String, size: CGFloat = 200) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let rep = NSCIImageRep(ciImage: transformed)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
