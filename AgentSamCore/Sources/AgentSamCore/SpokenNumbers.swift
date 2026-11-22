import Foundation

/// Gets amounts, percentages and other numbers ready for the voice, in the language being spoken.
///
/// Spanish (and most of Europe) writes `$10,00` for ten dollars and `1.234,56` for one thousand two hundred
/// thirty-four and a bit, while English writes `$10.00` and `1,234.56`. Speech engines guess from the digits
/// alone and often guess English: Kokoro drops a comma between digits, so `$10,00` came out as "1000 dollars".
///
/// - Spanish text: amounts, percentages and plain numbers are written out in Spanish words
///   ("$1.234,56" → "mil doscientos treinta y cuatro dólares con cincuenta y seis centavos"), so no engine
///   has to guess.
/// - English text: only numbers that are clearly in the comma-decimal style are rewritten to English style
///   ("$10,00" → "$10.00", "1.234,56" → "1,234.56"). Everything else is left to the voice.
///
/// Reading a number: when a number has both a period and a comma, the last one is the decimal mark. A
/// separator followed by one, two, or four or more digits is a decimal mark. Only one separator followed by
/// exactly three digits is ambiguous ("1.000"): in Spanish it groups thousands whichever mark is used (Spain
/// writes 1.000, Mexico 1,000), and in English a comma groups and a period is a decimal mark. Amounts of money
/// never have three decimal places, so there it always groups. A number starting with "0" never groups.
public enum SpokenNumbers {
    /// The language to read numbers in for `text`: what the words look like, falling back to `language`
    /// (the app's language, "en" or "es") when the text alone doesn't say.
    public static func language(of text: String, fallback language: String?) -> String {
        let fallback = (language ?? "").lowercased().hasPrefix("es") ? "es" : "en"
        let lower = text.lowercased()
        var spanish = lower.unicodeScalars.filter { "áéíóúñ¿¡".unicodeScalars.contains($0) }.count * 2
        var english = 0
        for word in lower.split(whereSeparator: { !$0.isLetter }) {
            if spanishMarkers.contains(String(word)) { spanish += 1 }
            if englishMarkers.contains(String(word)) { english += 1 }
        }
        if spanish > english { return "es" }
        if english > spanish { return "en" }
        return fallback
    }

    /// `text` with its numbers ready to speak in `language` ("es" or "en"; anything else is read as English).
    public static func normalize(_ text: String, language: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        return language.lowercased().hasPrefix("es") ? spanish(text) : english(text)
    }

    // MARK: Reading the digits

    /// A number as written: its whole part (digits only) and its decimal part (digits only, maybe empty).
    struct Parsed: Equatable {
        var whole: String
        var fraction: String
    }

    /// Splits a written number such as "1.234,56" into its whole and decimal digits, or nil when the
    /// separators don't make a number (such as "1.23.4").
    static func parse(_ written: String, spanish: Bool, money: Bool) -> Parsed? {
        let characters = Array(written)
        let marks = characters.indices.filter { characters[$0] == "." || characters[$0] == "," }
        guard let lastMark = marks.last else { return Parsed(whole: written, fraction: "") }
        let kinds = Set(marks.map { characters[$0] })
        func groups(_ text: Substring, by mark: Character) -> String? {
            let parts = text.split(separator: mark, omittingEmptySubsequences: false)
            guard let first = parts.first, (1...3).contains(first.count), first.first != "0" || parts.count == 1,
                  parts.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            return parts.joined()
        }
        let text = Substring(written)
        if kinds.count == 2 {
            let decimal = characters[lastMark]
            let grouping: Character = decimal == "." ? "," : "."
            guard characters.filter({ $0 == decimal }).count == 1 else { return nil }
            let head = text[..<text.index(text.startIndex, offsetBy: lastMark)]
            guard let whole = groups(head, by: grouping) else { return nil }
            return Parsed(whole: whole, fraction: String(characters[(lastMark + 1)...]))
        }
        let mark = characters[lastMark]
        if marks.count > 1 {
            return groups(text, by: mark).map { Parsed(whole: $0, fraction: "") }
        }
        let head = String(characters[..<lastMark])
        let tail = String(characters[(lastMark + 1)...])
        let couldGroup = tail.count == 3 && head.count <= 3 && head.first != "0"
        let groupsHere = couldGroup && (money || spanish || mark == ",")
        return groupsHere ? Parsed(whole: head + tail, fraction: "") : Parsed(whole: head, fraction: tail)
    }

    /// A written number: digits with optional thousands groups and a decimal part. Not part of a word, a time
    /// ("10:30"), a date ("22/11"), a range or code ("555-1234"), a version ("1.2.3.4") or an ordinal ("1º").
    static let numberPattern = "(?<![\\w.,:/]|\\d-)(\\d+(?:[.,]\\d+)*)(?![\\w:/ºª°]|[.,]\\d|-\\d)"

    // MARK: English

    private static func english(_ text: String) -> String {
        var text = replaceMatches(text, "(US\\$|MX\\$|C\\$|A\\$|\\$|€|£)\\s?" + numberPattern) { groups in
            guard let parsed = parse(groups[2], spanish: false, money: true) else { return nil }
            return groups[1] + englishDigits(parsed)
        }
        // Outside amounts, rewrite only numbers that can't be English: both marks, or grouped with periods.
        text = replaceMatches(text, numberPattern) { groups in
            let written = groups[1]
            let commaDecimal = (written.contains(",") && written.contains(".") && written.lastIndex(of: ",")! > written.lastIndex(of: ".")!)
                || written.filter({ $0 == "." }).count > 1
            guard commaDecimal, let parsed = parse(written, spanish: true, money: false) else { return nil }
            return englishDigits(parsed)
        }
        return text
    }

    private static func englishDigits(_ parsed: Parsed) -> String {
        var groups: [String] = []
        var digits = Substring(parsed.whole)
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits = digits.dropLast(3)
        }
        groups.insert(String(digits), at: 0)
        let whole = groups.joined(separator: ",")
        return parsed.fraction.isEmpty ? whole : whole + "." + parsed.fraction
    }

    // MARK: Spanish

    struct Currency {
        var one: String
        var many: String
        var centOne: String
        var centMany: String
        var feminine = false
    }

    static let dollar = Currency(one: "dólar", many: "dólares", centOne: "centavo", centMany: "centavos")
    static let euro = Currency(one: "euro", many: "euros", centOne: "céntimo", centMany: "céntimos")
    static let peso = Currency(one: "peso", many: "pesos", centOne: "centavo", centMany: "centavos")
    static let pound = Currency(one: "libra", many: "libras", centOne: "penique", centMany: "peniques", feminine: true)

    static func currency(_ mark: String) -> Currency? {
        switch mark.lowercased() {
        case "$", "us$", "usd", "c$", "a$", "dólar", "dólares", "dolar", "dolares": return dollar
        case "€", "eur", "euro", "euros": return euro
        case "mx$", "mxn", "peso", "pesos": return peso
        case "£", "gbp", "libra", "libras": return pound
        default: return nil
        }
    }

    private static let scalePattern = "(?:\\s(mil millones|mil|millón|millones|billón|billones)(?!\\w))?"
    /// A currency word written after an amount that already has a symbol: "$10 dólares", "$1,5 millones de dólares".
    private static let currencyWordAfter = "(?:\\s(?:de\\s)?(dólares|dólar|dolares|dolar|pesos|peso|euros|euro|libras|libra|USD|EUR|MXN|GBP)(?!\\w))?"
    private static let currencyAfter = "(€|\\$|USD|EUR|MXN|GBP|dólares|dólar|dolares|dolar|euros|euro|pesos|peso|libras|libra)(?![\\w])"

    private static func spanish(_ text: String) -> String {
        // "$1.234,56", "US$ 5", "$1,5 millones", "MXN 200".
        // A word after the symbol wins: "$200 pesos" is pesos.
        var text = replaceMatches(text, "(US\\$|MX\\$|C\\$|A\\$|\\$|€|£|USD|EUR|MXN|GBP)\\s?" + numberPattern + scalePattern + currencyWordAfter) { groups in
            guard let currency = currency(groups[4]) ?? currency(groups[1]) else { return nil }
            return spanishAmount(groups[2], scale: groups[3], currency: currency)
        }
        // "10,00 €", "25 dólares", "3 mil pesos".
        text = replaceMatches(text, numberPattern + scalePattern + "\\s?" + currencyAfter) { groups in
            guard let currency = currency(groups[3]) else { return nil }
            return spanishAmount(groups[1], scale: groups[2], currency: currency)
        }
        // "12,5 %", "50%".
        text = replaceMatches(text, numberPattern + "\\s?%") { groups in
            parse(groups[1], spanish: true, money: false).map { spanishNumber($0) + " por ciento" }
        }
        // "1 millón" → "un millón", "21 mil" → "veintiún mil", "1,5 millones" → "uno coma cinco millones".
        text = replaceMatches(text, numberPattern + scalePattern) { groups in
            guard let parsed = parse(groups[1], spanish: true, money: false) else { return nil }
            return groups[2].isEmpty ? spanishNumber(parsed) : spanishNumber(parsed, apocope: true) + " " + groups[2]
        }
        return text
    }

    /// "1.234,56" dollars → "mil doscientos treinta y cuatro dólares con cincuenta y seis centavos".
    static func spanishAmount(_ written: String, scale: String, currency: Currency) -> String? {
        guard let parsed = parse(written, spanish: true, money: true) else { return nil }
        if !scale.isEmpty {
            // "$1,5 millones" → "uno coma cinco millones de dólares"; "$3 mil" → "tres mil dólares".
            let millions = scale != "mil"
            let number = millions ? spanishNumber(parsed, apocope: true) : spanishNumber(parsed, apocope: true, feminine: currency.feminine)
            return number + " " + scale + (millions ? " de " : " ") + currency.many
        }
        guard parsed.fraction.count <= 2 else {
            return spanishNumber(parsed) + " " + currency.many
        }
        let whole = UInt64(parsed.whole) ?? 0
        let cents = parsed.fraction.isEmpty ? 0 : UInt64(parsed.fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        var words: [String] = []
        if whole > 0 || cents == 0 {
            let name = whole == 1 ? currency.one : currency.many
            // "un millón de dólares", but "un millón doscientos mil dólares".
            let of = whole >= 1_000_000 && whole % 1_000_000 == 0 ? "de " : ""
            words.append(spanishWords(whole, apocope: true, feminine: currency.feminine) + " " + of + name)
        }
        if cents > 0 {
            words.append(spanishWords(cents, apocope: true) + " " + (cents == 1 ? currency.centOne : currency.centMany))
        }
        return words.joined(separator: " con ")
    }

    /// A number in Spanish words, with "coma" before its decimals: "1,5" → "uno coma cinco",
    /// "0,05" → "cero coma cero cinco".
    static func spanishNumber(_ parsed: Parsed, apocope: Bool = false, feminine: Bool = false) -> String {
        guard let whole = UInt64(parsed.whole), parsed.whole.count <= 15 else {
            return parsed.whole.map { spanishWords(UInt64(String($0)) ?? 0) }.joined(separator: " ")
        }
        guard !parsed.fraction.isEmpty else { return spanishWords(whole, apocope: apocope, feminine: feminine) }
        var decimals = Substring(parsed.fraction)
        var spoken: [String] = []
        while decimals.count > 1, decimals.first == "0" {
            spoken.append("cero")
            decimals = decimals.dropFirst()
        }
        if decimals.count <= 3, let value = UInt64(decimals) {
            spoken.append(spanishWords(value))
        } else {
            spoken += decimals.map { spanishWords(UInt64(String($0)) ?? 0) }
        }
        return spanishWords(whole) + " coma " + spoken.joined(separator: " ")
    }

    private static let units = ["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
                                "diez", "once", "doce", "trece", "catorce", "quince", "dieciséis", "diecisiete", "dieciocho", "diecinueve",
                                "veinte", "veintiuno", "veintidós", "veintitrés", "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve"]
    private static let tens = ["", "", "", "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"]
    private static let hundreds = ["", "ciento", "doscientos", "trescientos", "cuatrocientos", "quinientos", "seiscientos", "setecientos", "ochocientos", "novecientos"]

    /// A whole number in Spanish words. `apocope` shortens a final "uno" before a noun ("un dólar",
    /// "veintiún dólares"); `feminine` agrees with a feminine noun ("una libra", "doscientas libras").
    public static func spanishWords(_ number: UInt64, apocope: Bool = false, feminine: Bool = false) -> String {
        if number == 0 { return "cero" }
        var parts: [String] = []
        var rest = number
        let scales: [(UInt64, String, String)] = [(1_000_000_000_000, "billón", "billones"), (1_000_000, "millón", "millones")]
        for (size, one, many) in scales where rest >= size {
            let count = rest / size
            rest %= size
            parts.append(count == 1 ? "un " + one : belowMillion(count, apocope: true, feminine: false) + " " + many)
        }
        if rest > 0 { parts.append(belowMillion(rest, apocope: apocope, feminine: feminine)) }
        return parts.joined(separator: " ")
    }

    private static func belowMillion(_ number: UInt64, apocope: Bool, feminine: Bool) -> String {
        let thousands = number / 1000
        let rest = number % 1000
        var parts: [String] = []
        if thousands == 1 {
            parts.append("mil")
        } else if thousands > 1 {
            parts.append(belowThousand(thousands, apocope: true, feminine: feminine) + " mil")
        }
        if rest > 0 { parts.append(belowThousand(rest, apocope: apocope, feminine: feminine)) }
        return parts.joined(separator: " ")
    }

    private static func belowThousand(_ number: UInt64, apocope: Bool, feminine: Bool) -> String {
        let hundred = Int(number / 100)
        let rest = Int(number % 100)
        var parts: [String] = []
        if hundred > 0 {
            var word = number == 100 ? "cien" : hundreds[hundred]
            if feminine, hundred > 1 { word = String(word.dropLast(2)) + "as" }
            parts.append(word)
        }
        if rest > 0 {
            var word = rest < 30 ? units[rest] : tens[rest / 10] + (rest % 10 == 0 ? "" : " y " + units[rest % 10])
            if rest % 10 == 1, rest != 11 {
                if feminine {
                    word = String(word.dropLast()) + "a"
                } else if apocope {
                    word = rest == 21 ? "veintiún" : String(word.dropLast())
                }
            }
            parts.append(word)
        }
        return parts.joined(separator: " ")
    }

    // MARK: Helpers

    private static let spanishMarkers: Set<String> = [
        "el", "la", "los", "las", "de", "del", "que", "y", "en", "un", "una", "por", "con", "para", "es", "son",
        "está", "esta", "este", "pero", "como", "más", "tu", "su", "lo", "le", "se", "al", "hay", "cuesta",
        "dólares", "pesos", "euros", "mil", "millones", "sí", "muy", "también", "precio",
    ]
    private static let englishMarkers: Set<String> = [
        "the", "and", "is", "are", "of", "to", "you", "for", "with", "that", "this", "it", "on", "your", "be",
        "was", "have", "has", "will", "can", "costs", "dollars", "price", "thousand", "million", "at",
    ]

    /// Replaces each match of `pattern`, last first. `transform` gets the whole match and its groups
    /// (missing groups are empty) and returns nil to leave a match as it is.
    private static func replaceMatches(_ text: String, _ pattern: String, _ transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            if let replacement = transform(groups) {
                result.replaceSubrange(whole, with: replacement)
            }
        }
        return result
    }
}
