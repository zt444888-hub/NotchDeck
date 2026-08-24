import Foundation

/// Minimal localization helper for the iOS/watchOS companion app (#260).
///
/// The companion targets never had any localization infrastructure — every string was
/// a hardcoded Chinese literal. Rather than introducing a full key/dictionary catalog
/// (see the Mac app's `Sources/CodeIsland/L10n.swift` for that heavier 7-language
/// pattern), this keeps translations colocated with their call site and chooses
/// between the original Chinese and an English string. **The app is English-only**
/// (overseas users), so `isChinese` is pinned to `false` and `t(zh:en:)` always
/// returns `en` — no Chinese UI is ever displayed. The `zh` literals are kept only as
/// a translation fallback and are never shown.
enum L10n {
    /// User-overridable language preference shared with the UI:
    /// "system" (default, follow the device language), "zh", "en".
    static var preferred: String {
        get { UserDefaults.standard.string(forKey: "AppLanguage") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "AppLanguage") }
    }

    /// The companion app is English-only (targeted at overseas users, #260).
    /// Pinned to `false` so every `L10n.t(zh:en:)` resolves to `en` regardless of
    /// the device or in-app language setting — no Chinese UI is ever shown.
    static var isChinese: Bool { false }

    /// Resolves to `en` (the app is English-only). Falls back to `zh` only if
    /// `en` is somehow empty, so a missing translation can never blank the UI.
    static func t(zh: String, en: String) -> String {
        en.isEmpty ? zh : en
    }
}
