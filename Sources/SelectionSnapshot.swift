import AppKit
import ApplicationServices
import CoreImage
import CryptoKit
import Foundation

// MARK: - SelectionSnapshot

public struct SelectionSnapshot: Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let launchIdentity: String?
    public let element: AXUIElement?
    public let selectedText: String
    public let textSHA256: String
    public let range: CFRange?
    public let timestamp: Date
    public let generation: UInt64
    public let isFromClipboardFallback: Bool

    public init(pid: pid_t, bundleID: String?, launchIdentity: String?, element: AXUIElement?,
                selectedText: String, range: CFRange?, timestamp: Date = Date(),
                generation: UInt64 = 0, isFromClipboardFallback: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.launchIdentity = launchIdentity
        self.element = element
        self.selectedText = selectedText
        self.textSHA256 = SHA256.hash(data: Data(selectedText.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        self.range = range
        self.timestamp = timestamp
        self.generation = generation
        self.isFromClipboardFallback = isFromClipboardFallback
    }

    public static func capture(generation: UInt64 = 0) -> SelectionSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)

        var focusedElementValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let element = focusedElementValue as! AXUIElement? else {
            return nil
        }
        AXUIElementSetMessagingTimeout(element, 0.2)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let bundleID = runningApp?.bundleIdentifier
        let launchIdentity = WindowProcessIdentity.auditTokenString(for: pid)

        // Read selected text
        var selectedTextValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
              let text = selectedTextValue as? String,
              !text.isEmpty else {
            return nil
        }

        // Read selected range if available
        var selectedRangeValue: AnyObject?
        var range: CFRange? = nil
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
           let rangeVal = selectedRangeValue {
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
            isFromClipboardFallback: false
        )
    }

    public func matchesTarget(currentPID: pid_t?, currentBundleID: String?, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration else { return false }
        if let currentPID = currentPID, currentPID != pid { return false }
        if let currentBundleID = currentBundleID, let bundleID = bundleID, currentBundleID != bundleID { return false }
        return true
    }

    public static func == (lhs: SelectionSnapshot, rhs: SelectionSnapshot) -> Bool {
        return lhs.pid == rhs.pid &&
               lhs.bundleID == rhs.bundleID &&
               lhs.launchIdentity == rhs.launchIdentity &&
               lhs.selectedText == rhs.selectedText &&
               lhs.textSHA256 == rhs.textSHA256 &&
               lhs.generation == rhs.generation &&
               lhs.isFromClipboardFallback == rhs.isFromClipboardFallback
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
