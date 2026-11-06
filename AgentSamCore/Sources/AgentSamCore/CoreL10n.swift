import Foundation

/// Lookup helpers for AgentSamCore's bundled localized strings.
/// Keys are English source text grouped by a dotted prefix; translations live in
/// `Resources/<lang>.lproj/Localizable.strings`.
public enum CoreL10n {
    /// Returns the catalog string for `key` in the process's preferred language.
    /// Falls back to the key itself (English source text).
    public static func t(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Returns the catalog string for `key` in an explicit language (`"en"` | `"es"`),
    /// used when text must follow a per-mission language rather than the process locale.
    public static func t(_ key: String, lang: String) -> String {
        guard let langPath = Bundle.module.path(forResource: lang, ofType: "lproj"),
              let langBundle = Bundle(path: langPath) else {
            return t(key)
        }
        return langBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Formats a localized template with `CVarArg` values.
    public static func tf(_ key: String, _ args: CVarArg..., lang: String? = nil) -> String {
        let format = lang.map { t(key, lang: $0) } ?? t(key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    /// Resolves the mission's working language tag: `"es"` for Spanish missions,
    /// `"en"` otherwise (including missions without an explicit language).
    public static func language(for mission: Mission) -> String {
        guard let lang = mission.outputLanguage?.trimmingCharacters(in: .whitespaces).lowercased(),
              !lang.isEmpty else {
            return "en"
        }
        return lang.hasPrefix("es") ? "es" : "en"
    }

    /// The user's preferred language tag for this process: `"es"` when the top
    /// preferred language is Spanish, `"en"` otherwise.
    public static func preferredLanguage() -> String {
        let first = Locale.preferredLanguages.first?.lowercased() ?? ""
        return first.hasPrefix("es") ? "es" : "en"
    }
}
