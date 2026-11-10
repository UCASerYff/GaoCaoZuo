import AppKit
import ApplicationServices
import Foundation

/// Only ordinary settings are persisted. AX handles, titles, process identities and pixels are session memory.
struct DesktopOverviewPreferences: Codable, Equatable {
    var groupByApplication = true
    var compactChooser = false
    var excludedThumbnailBundleIDs: [String] = []
    var excludedApplicationBundleIDs: [String] = []
    var thumbnailsEnabled = false
    var statusStripEnabled = false

    func validated() throws -> Self {
        for ids in [excludedThumbnailBundleIDs, excludedApplicationBundleIDs] {
            guard ids.count <= 256, Set(ids).count == ids.count,
                  ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains(where: \.isWhitespace) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw DesktopOverviewError.message("窗口总览的应用排除设置无效；原设置未被覆盖。")
            }
        }
        return self
    }
}

enum DesktopOverviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// The exact, revalidated AX target is handed to WindowManager instead of recapturing another frontmost window.
struct DesktopOverviewActionTarget {
    let element: AXUIElement
    let application: NSRunningApplication
    let identity: WindowProcessIdentity.Snapshot
    let pid: pid_t
}

struct DesktopOverviewEntry: Identifiable {
    let id: String
    let appName: String
    let title: String
    let bundleID: String
    let pid: pid_t
    let icon: NSImage
    let frame: CGRect?
    let isMinimized: Bool
    let canFocus: Bool
    let canClose: Bool
    let detail: String
    let createdAt: TimeInterval
    let generation: UUID

    var displayTitle: String { title.isEmpty ? (canFocus ? "未命名窗口" : "应用入口") : title }
}

struct DesktopOverviewEvidence: Equatable {
    let title: String
    let frame: CGRect
}

/// Pure matching policies never turn an ambiguous screen-window mapping into an AX action target.
enum DesktopOverviewPolicy {
    static let maximumWindows = 160
    static let maximumApps = 80
    static let catalogLifetime: TimeInterval = 60
    static let previewLifetime: TimeInterval = 15
    static let maximumPreviews = 12
    static let maximumPreviewPixels = 6_000_000

    static func isFresh(createdAt: TimeInterval, now: TimeInterval) -> Bool {
        createdAt.isFinite && now.isFinite && now >= createdAt && now - createdAt <= catalogLifetime
    }

    static func sameGeometry(_ a: CGRect, _ b: CGRect) -> Bool {
        guard [a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height].allSatisfy({ $0.isFinite }),
              a.width >= 40, a.height >= 30, b.width >= 40, b.height >= 30 else { return false }
        return abs(a.minX-b.minX) <= 3 && abs(a.minY-b.minY) <= 3 && abs(a.width-b.width) <= 3 && abs(a.height-b.height) <= 3
    }

    static func uniquePreviewMatch(source: DesktopOverviewEvidence, axPeers: [DesktopOverviewEvidence], capturePeers: [DesktopOverviewEvidence]) -> Bool {
        guard !source.title.isEmpty else { return false }
        let matches: (DesktopOverviewEvidence) -> Bool = { $0.title == source.title && sameGeometry($0.frame, source.frame) }
        return axPeers.filter(matches).count == 1 && capturePeers.filter(matches).count == 1
    }

    static func previewAllowed(sessionActive: Bool, explicitlyRequested: Bool, enabled: Bool,
                               screenAuthorized: Bool, accessibilityAuthorized: Bool, secureInput: Bool, excluded: Bool) -> Bool {
        sessionActive && explicitlyRequested && enabled && screenAuthorized && accessibilityAuthorized && !secureInput && !excluded
    }

    static func eligibleScreenWindow(onScreen: Bool, alpha: Double?, layer: Int?, frame: CGRect) -> Bool {
        guard onScreen, let alpha, alpha.isFinite, alpha == 1, layer == 0 else { return false }
        return sameGeometry(frame, frame)
    }

    static func containsQuery(appName: String, title: String, bundleID: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let text = appName + " " + title + " " + bundleID
        return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

struct DesktopOverviewPreviewBudget {
    private(set) var count = 0
    private(set) var pixels = 0
    mutating func reserve(pixels requested: Int) -> Bool {
        guard requested > 0, requested <= DesktopOverviewPolicy.maximumPreviewPixels,
              count < DesktopOverviewPolicy.maximumPreviews,
              pixels <= DesktopOverviewPolicy.maximumPreviewPixels - requested else { return false }
        count += 1
        pixels += requested
        return true
    }
}
