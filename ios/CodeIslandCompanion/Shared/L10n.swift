import Foundation

/// Minimal bilingual localization helper for the iOS/watchOS companion app (#260).
///
/// The companion targets never had any localization infrastructure — every string was
/// a hardcoded Chinese literal. Rather than introducing a full key/dictionary catalog
/// (see the Mac app's `Sources/CodeIsland/L10n.swift` for that heavier 7-language
/// pattern), this keeps translations colocated with their call site and just chooses
/// between the original Chinese and a new English string based on the system
/// language: Chinese systems keep seeing Chinese, every other language now sees
/// natural English instead of hardcoded Chinese.
enum L10n {
    /// User-overridable language preference shared with the UI:
    /// "system" (default, follow the device language), "zh", "en".
    static var preferred: String {
        get { UserDefaults.standard.string(forKey: "AppLanguage") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "AppLanguage") }
    }

    /// True when the effective language is Chinese (any script/region).
    /// Honors the in-app override first, then falls back to the system
    /// language.
    static var isChinese: Bool {
        switch preferred {
        case "zh": return true
        case "en": return false
        default:
            let sys = Locale.preferredLanguages.first ?? Locale.current.identifier
            return sys.lowercased().hasPrefix("zh")
        }
    }

    /// Returns `zh` on a Chinese system, `en` everywhere else.
    static func t(zh: String, en: String) -> String {
        isChinese ? zh : en
    }
}
