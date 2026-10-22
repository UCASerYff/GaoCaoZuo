import Foundation

private final class GaoLocalizationBundleMarker: NSObject {}

/// Rendering-only localization. Persisted action IDs, user names and paths never change.
enum L10n {
    private static let lock = NSLock()
    private static var selected = "system"
    static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "de", "fr", "es", "it", "ko", "pt"]
    /// Resolve resources from the executable containing this code, including an
    /// extension hosted by a system process. Never search a user's document.
    static var resourceBundle: Bundle { Bundle(for: GaoLocalizationBundleMarker.self) }

    static func setLanguage(_ language: String) {
        lock.lock(); defer { lock.unlock() }
        selected = languages.contains(language) ? language : "system"
    }
    static func effectiveLanguage(_ language: String? = nil) -> String {
        lock.lock(); let chosen = language ?? selected; lock.unlock()
        if languages.contains(chosen) { return chosen }
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") { return "zh-Hant" }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        return languages.first { preferred == $0 || preferred.hasPrefix($0 + "-") } ?? "en"
    }
    static func text(_ key: String, language: String? = nil, bundle: Bundle? = nil) -> String {
        let language = effectiveLanguage(language)
        let bundle = bundle ?? resourceBundle
        func lookup(_ code: String) -> String? {
            guard let path = bundle.path(forResource: code, ofType: "lproj"), let localized = Bundle(path: path) else { return nil }
            let value = localized.localizedString(forKey: key, value: "__gao_missing__", table: "Localizable")
            return value == "__gao_missing__" ? nil : value
        }
        return lookup(language) ?? (language == "zh-Hans" ? nil : lookup("en")) ?? key
    }
    static func format(_ key: String, _ arguments: CVarArg..., language: String? = nil, bundle: Bundle? = nil) -> String {
        String(format: text(key, language: language, bundle: bundle), locale: Locale(identifier: effectiveLanguage(language)), arguments: arguments)
    }
}
