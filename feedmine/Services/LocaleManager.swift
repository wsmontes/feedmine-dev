import Foundation
import Observation

// MARK: - Language Model

struct Language: Identifiable, Equatable, Hashable {
    let code: String            // BCP-47: "en", "pt-BR", "zh-Hans"
    let displayName: String     // Native name: "English", "Português (Brasil)", "简体中文"

    var id: String { code }

    /// Match a system preference string (e.g. "pt-BR" or "pt") against this language code.
    func matches(_ systemPref: String) -> Bool {
        code == systemPref || systemPref.hasPrefix(code) || code.hasPrefix(systemPref)
    }
}

// MARK: - LocaleManager

@MainActor
@Observable
final class LocaleManager {
    static let shared = LocaleManager()

    /// All languages available in the app.
    /// Ordered alphabetically by display name within script/region groups.
    static let supportedLanguages: [Language] = [
        Language(code: "ar",         displayName: "العربية"),
        Language(code: "ca",         displayName: "Català"),
        Language(code: "zh-Hans",    displayName: "简体中文"),
        Language(code: "zh-Hant",    displayName: "繁體中文"),
        Language(code: "hr",         displayName: "Hrvatski"),
        Language(code: "cs",         displayName: "Čeština"),
        Language(code: "da",         displayName: "Dansk"),
        Language(code: "nl",         displayName: "Nederlands"),
        Language(code: "en",         displayName: "English"),
        Language(code: "en-AU",      displayName: "English (Australia)"),
        Language(code: "en-GB",      displayName: "English (UK)"),
        Language(code: "en-IN",      displayName: "English (India)"),
        Language(code: "fi",         displayName: "Suomi"),
        Language(code: "fr",         displayName: "Français"),
        Language(code: "fr-CA",      displayName: "Français (Canada)"),
        Language(code: "de",         displayName: "Deutsch"),
        Language(code: "el",         displayName: "Ελληνικά"),
        Language(code: "he",         displayName: "עברית"),
        Language(code: "hi",         displayName: "हिन्दी"),
        Language(code: "hu",         displayName: "Magyar"),
        Language(code: "id",         displayName: "Indonesia"),
        Language(code: "it",         displayName: "Italiano"),
        Language(code: "ja",         displayName: "日本語"),
        Language(code: "ko",         displayName: "한국어"),
        Language(code: "ms",         displayName: "Melayu"),
        Language(code: "nb",         displayName: "Norsk Bokmål"),
        Language(code: "pl",         displayName: "Polski"),
        Language(code: "pt-BR",      displayName: "Português (Brasil)"),
        Language(code: "pt-PT",      displayName: "Português (Portugal)"),
        Language(code: "ro",         displayName: "Română"),
        Language(code: "ru",         displayName: "Русский"),
        Language(code: "sk",         displayName: "Slovenčina"),
        Language(code: "es",         displayName: "Español"),
        Language(code: "es-419",     displayName: "Español (Latinoamérica)"),
        Language(code: "sv",         displayName: "Svenska"),
        Language(code: "th",         displayName: "ไทย"),
        Language(code: "tr",         displayName: "Türkçe"),
        Language(code: "uk",         displayName: "Українська"),
        Language(code: "vi",         displayName: "Tiếng Việt"),
    ]

    /// English fallback (always first match for unsupported system languages).
    private static let english: Language = supportedLanguages.first(where: { $0.code == "en" })!
    /// FeedMine-owned preference. We never read the system's `AppleLanguages` defaults key: the
    /// privacy manifest's CA92.1 reason covers app-owned defaults, not values written by the system.
    static let selectedLanguageKey = "feedmine.selectedLanguage"

    // MARK: - State

    /// The currently selected language.
    var selectedLanguage: Language

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.selectedLanguageKey)
        let resolved = Self.resolveLanguage(
            savedCode: saved,
            systemPreferences: Locale.preferredLanguages
        )
        selectedLanguage = resolved

        // When the user explicitly chose a language, keep the bundle override used by the existing
        // restart-based localization flow. This value is written into this app's own defaults domain;
        // the system/global AppleLanguages value is never read.
        if saved != nil {
            UserDefaults.standard.set([resolved.code], forKey: "AppleLanguages")
        }
    }

    // MARK: - Language Resolution

    /// Resolve the effective language at launch from app-owned state first, then the public locale API.
    static func resolveLanguage(
        savedCode: String?,
        systemPreferences: [String]
    ) -> Language {
        if let savedCode,
           let match = supportedLanguages.first(where: { $0.matches(savedCode) }) {
            return match
        }

        for pref in systemPreferences {
            if let match = supportedLanguages.first(where: { $0.matches(pref) }) {
                return match
            }
        }

        return english
    }

    // MARK: - Actions

    /// Persist a new language selection. The change takes effect on next app launch.
    func selectLanguage(_ language: Language) {
        selectedLanguage = language
        UserDefaults.standard.set(language.code, forKey: Self.selectedLanguageKey)
        // Bundle localization still follows the established restart-based override, but the source of
        // truth is FeedMine's own key above. We deliberately never read the system/global value.
        UserDefaults.standard.set([language.code], forKey: "AppleLanguages")
    }
}
