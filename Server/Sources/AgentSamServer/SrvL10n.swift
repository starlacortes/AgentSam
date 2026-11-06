import Foundation
import Vapor

/// Server-side localization helper. The server localizes every client-visible
/// message based on the requesting client's preferred language ("en" | "es").
enum SrvL10n {
    static func t(_ key: String, lang: String) -> String {
        let resolved = lang.lowercased().hasPrefix("es") ? "es" : "en"
        guard let langPath = Bundle.module.path(forResource: resolved, ofType: "lproj"),
              let langBundle = Bundle(path: langPath) else {
            return Bundle.module.localizedString(forKey: key, value: key, table: "Localizable")
        }
        return langBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func tf(_ key: String, _ args: CVarArg..., lang: String) -> String {
        let format = t(key, lang: lang)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: lang.lowercased().hasPrefix("es") ? "es" : "en"), arguments: args)
    }

    /// Resolves the request's preferred language tag: "es" when the client
    /// prefers Spanish, "en" otherwise.
    static func lang(for req: Request) -> String {
        let header = req.headers.first(name: .acceptLanguage) ?? ""
        let firstTag = header.split(separator: ",").first.map { String($0) }?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return firstTag.hasPrefix("es") ? "es" : "en"
    }
}
