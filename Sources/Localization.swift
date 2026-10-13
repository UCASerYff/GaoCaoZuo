import Foundation
import SwiftUI
import Combine

public enum GaoLanguage: String, CaseIterable, Identifiable, Codable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en, ja, de, fr, es, it, ko, pt
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "跟随系统 (System Default)"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        case .ko: return "한국어"
        case .pt: return "Português"
        }
    }
}

@MainActor public final class GaoLocale: ObservableObject {
    public static let shared = GaoLocale()
    @Published public private(set) var currentLanguage: GaoLanguage = .system
    public init() {}
    public func setLanguage(_ language: GaoLanguage) {
        guard language != currentLanguage else { return }
        L10n.setLanguage(language.rawValue)
        currentLanguage = language
    }
    public var effectiveLanguage: GaoLanguage { GaoLanguage(rawValue: L10n.effectiveLanguage(currentLanguage.rawValue)) ?? .en }
    public static func tr(_ key: String) -> String { L10n.text(key) }
    public func translate(_ key: String) -> String { L10n.text(key, language: currentLanguage.rawValue) }
}

/// Refreshes native SwiftUI LocalizedStringKey lookups without resetting form state.
struct GaoLocalizedContent<Content: View>: View {
    @ObservedObject private var language = GaoLocale.shared
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View { content().environment(\.locale, Locale(identifier: language.effectiveLanguage.rawValue)) }
}
