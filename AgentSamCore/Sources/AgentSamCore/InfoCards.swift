import Foundation

/// A small card Ada shows in her reply: a few numbers, a comparison, a chart, steps, dates.
///
/// Cards are data only. Ada picks a template and fills its fields; the app draws it. No HTML, links,
/// styles or scripts come from the model, so a card cannot inject anything into the page. Every
/// string is plain text, trimmed and clipped, and every list is capped here before it is saved.
public struct InfoCard: Codable, Hashable, Sendable, Identifiable {
    public struct Item: Codable, Hashable, Sendable {
        public var label: String
        /// Text shown as the item's value ("$4,210", "Yes", "3 days").
        public var value: String?
        /// A number for bars and charts.
        public var number: Double?
        /// A second, smaller line: a change ("+12% vs May"), a note, a reason.
        public var detail: String?
        /// `good`, `bad` or `neutral`, for stat changes.
        public var tone: String?
        /// For steps: `done`, `current`, `todo` or `failed`.
        public var state: String?
        /// For timelines: when it happened or will ("Mon 3 Dec", "Q1", "09:30").
        public var when: String?

        public init(label: String, value: String? = nil, number: Double? = nil, detail: String? = nil, tone: String? = nil, state: String? = nil, when: String? = nil) {
            self.label = label
            self.value = value
            self.number = number
            self.detail = detail
            self.tone = tone
            self.state = state
            self.when = when
        }
    }

    public struct Row: Codable, Hashable, Sendable {
        public var label: String
        public var values: [String]

        public init(label: String, values: [String]) {
            self.label = label
            self.values = values
        }
    }

    public var id: UUID
    /// One of `InfoCardTools.templates`. Kept as text so an older app or a newer card never breaks decoding.
    public var template: String
    public var title: String?
    /// A short source or footnote under the card.
    public var note: String?
    public var items: [Item]
    /// Comparison: the options compared, one column each.
    public var columns: [String]
    /// Comparison: one row per aspect, a value per column.
    public var rows: [Row]
    /// Comparison: the column to mark as recommended.
    public var highlight: Int?
    /// Chart: `bar` or `line`.
    public var chart: String?
    /// Chart and ranking: the unit numbers are in ("$", "%", "visits").
    public var unit: String?
    /// Callout: `info`, `success`, `warning` or `danger`.
    public var tone: String?
    /// Callout: the message.
    public var text: String?

    public init(id: UUID = UUID(), template: String, title: String? = nil, note: String? = nil, items: [Item] = [], columns: [String] = [], rows: [Row] = [], highlight: Int? = nil, chart: String? = nil, unit: String? = nil, tone: String? = nil, text: String? = nil) {
        self.id = id
        self.template = template
        self.title = title
        self.note = note
        self.items = items
        self.columns = columns
        self.rows = rows
        self.highlight = highlight
        self.chart = chart
        self.unit = unit
        self.tone = tone
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id, template, title, note, items, columns, rows, highlight, chart, unit, tone, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        template = try c.decode(String.self, forKey: .template)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
        highlight = try c.decodeIfPresent(Int.self, forKey: .highlight)
        chart = try c.decodeIfPresent(String.self, forKey: .chart)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        tone = try c.decodeIfPresent(String.self, forKey: .tone)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }

    /// One line for Ada's tool log, so later turns know which card she showed without its data.
    public var logLine: String {
        let count = template == "comparison" ? rows.count : items.count
        var line = "show_card \(template)"
        if let title { line += " “\(title)”" }
        if template != "callout" { line += " (\(count) \(template == "comparison" ? "row" : "item")\(count == 1 ? "" : "s"))" }
        return line
    }
}

/// `show_card`: Ada's one tool for putting a card in her reply.
public enum InfoCardTools {
    public static let toolName = "show_card"
    public static let names: Set<String> = [toolName]
    public static let templates = ["stats", "comparison", "ranking", "chart", "steps", "timeline", "summary", "callout"]
    /// Cards in one reply. More than a couple turns an answer into a dashboard.
    public static let maxPerReply = 3

    static let statTones: Set<String> = ["good", "bad", "neutral"]
    static let stepStates: Set<String> = ["done", "current", "todo", "failed"]
    static let calloutTones: Set<String> = ["info", "success", "warning", "danger"]

    public static var definitions: [APIToolDef] {
        let string: (String) -> JSONValue = { .object([("type", .string("string")), ("description", .string($0))]) }
        let item: JSONValue = .object([
            ("type", .string("object")),
            ("properties", .object([
                ("label", string("What the item is. Required.")),
                ("value", string("The value shown, as text: \"$4,210\", \"Yes\", \"3 days\".")),
                ("number", .object([("type", .string("number")), ("description", .string("A plain number, for chart points and ranking bars."))])),
                ("detail", string("A short second line: a change (\"+12% vs May\"), a reason, a note.")),
                ("tone", .object([("type", .string("string")), ("enum", .array(["good", "bad", "neutral"].map(JSONValue.string))), ("description", .string("stats: colours the detail line."))])),
                ("state", .object([("type", .string("string")), ("enum", .array(["done", "current", "todo", "failed"].map(JSONValue.string))), ("description", .string("steps: where each step stands."))])),
                ("when", string("timeline: the date or time, as people say it (\"Mon 3 Dec\", \"Q1\", \"09:30\").")),
            ])),
            ("required", .array([.string("label")])),
        ])
        return [
            APIToolDef(
                name: toolName,
                description: """
                Show a small card in your reply, below your text, when information has a shape that is easier \
                to see than to read: a few key numbers, options side by side, a ranking, a trend, progress through \
                steps, dates, a key-value summary, or a warning that must not be missed. Fill a template with data; \
                the app draws it. Plain text only, never HTML or Markdown. Templates and their fields:
                - stats: items (1-6) with label and value, optional detail (the change) and tone.
                - comparison: columns (2-4 option names), rows (1-10) each with label and values (one per column), optional highlight (the recommended column, from 0).
                - ranking: items (2-10) best first, with label and optional value, detail, number (draws bars).
                - chart: chart "bar" or "line", items (2-24) with label and number, optional unit.
                - steps: items (1-10) with label, state and optional detail.
                - timeline: items (1-10) in order, with when, label and optional detail.
                - summary: items (1-12) with label and value.
                - callout: tone (info, success, warning, danger) and text, optional title.
                Every card takes an optional title and note (a source or footnote). At most \(maxPerReply) cards per reply. \
                Your reply text still answers in a sentence or two without repeating the card, because voice mode reads only the text.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("template", .object([("type", .string("string")), ("enum", .array(templates.map(JSONValue.string))), ("description", .string("Which card to show."))])),
                        ("title", string("A short title, at most 80 characters.")),
                        ("note", string("Optional source or footnote, at most 160 characters.")),
                        ("items", .object([("type", .string("array")), ("items", item), ("description", .string("The entries, for every template except comparison and callout."))])),
                        ("columns", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("comparison: the options compared."))])),
                        ("rows", .object([
                            ("type", .string("array")),
                            ("items", .object([
                                ("type", .string("object")),
                                ("properties", .object([
                                    ("label", string("The aspect compared (\"Price\", \"Setup time\").")),
                                    ("values", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("One value per column, in column order."))])),
                                ])),
                                ("required", .array([.string("label"), .string("values")])),
                            ])),
                            ("description", .string("comparison: one row per aspect.")),
                        ])),
                        ("highlight", .object([("type", .string("integer")), ("description", .string("comparison: the recommended column, counted from 0."))])),
                        ("chart", .object([("type", .string("string")), ("enum", .array([.string("bar"), .string("line")])), ("description", .string("chart: bar for categories, line for a trend over time."))])),
                        ("unit", string("chart and ranking: the unit of the numbers (\"$\", \"%\", \"visits\").")),
                        ("tone", .object([("type", .string("string")), ("enum", .array(["info", "success", "warning", "danger"].map(JSONValue.string))), ("description", .string("callout: how it reads."))])),
                        ("text", string("callout: the message, at most 400 characters.")),
                    ])),
                    ("required", .array([.string("template")])),
                ])
            ),
        ]
    }

    /// Plain text on one line, trimmed and clipped. Nil when nothing is left.
    static func clean(_ value: JSONValue?, limit: Int) -> String? {
        let raw: String
        switch value {
        case .string(let text)?: raw = text
        case .number(let number)?: raw = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag)?: raw = flag ? "Yes" : "No"
        default: return nil
        }
        let text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number.isFinite ? number : nil
        case .string(let text)?:
            // "1,234.5", "$80", "12%": keep the digits, sign and point.
            let kept = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
            guard !kept.isEmpty, let parsed = Double(kept), parsed.isFinite else { return nil }
            return parsed
        default: return nil
        }
    }

    /// Builds a card from a `show_card` call, or says what to fix.
    public static func card(from args: [String: JSONValue]) -> Result<InfoCard, CardError> {
        guard let template = clean(args["template"], limit: 20)?.lowercased(), templates.contains(template) else {
            return .failure(.invalid("Pick a template: \(templates.joined(separator: ", "))."))
        }
        var card = InfoCard(template: template, title: clean(args["title"], limit: 80), note: clean(args["note"], limit: 160))
        let rawItems = args["items"]?.arrayValue ?? []

        func items(min: Int, max: Int, label: String = "items") -> Result<[InfoCard.Item], CardError> {
            let parsed: [InfoCard.Item] = rawItems.compactMap { raw in
                guard let object = raw.objectValue else { return nil }
                let label = clean(object["label"], limit: 60) ?? clean(object["when"], limit: 60)
                guard let label else { return nil }
                return InfoCard.Item(
                    label: label,
                    value: clean(object["value"], limit: 40),
                    number: number(object["number"]),
                    detail: clean(object["detail"], limit: 120),
                    tone: clean(object["tone"], limit: 10)?.lowercased(),
                    state: clean(object["state"], limit: 10)?.lowercased(),
                    when: clean(object["when"], limit: 40)
                )
            }
            guard parsed.count >= min else { return .failure(.invalid("A \(template) card needs at least \(min) \(label), each with a label.")) }
            guard parsed.count <= max else { return .failure(.invalid("A \(template) card takes at most \(max) \(label); show the most important ones.")) }
            return .success(parsed)
        }

        switch template {
        case "stats":
            switch items(min: 1, max: 6) {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    if list[i].value == nil, let n = list[i].number { list[i].value = clean(.number(n), limit: 40) }
                    guard list[i].value != nil else { return .failure(.invalid("Each stat needs a value.")) }
                    if let tone = list[i].tone, !statTones.contains(tone) { list[i].tone = nil }
                    list[i].state = nil; list[i].when = nil
                }
                card.items = list
            }
        case "summary":
            switch items(min: 1, max: 12) {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    if list[i].value == nil, let n = list[i].number { list[i].value = clean(.number(n), limit: 40) }
                    guard list[i].value != nil else { return .failure(.invalid("Each summary line needs a value.")) }
                    list[i].tone = nil; list[i].state = nil; list[i].when = nil; list[i].number = nil
                }
                card.items = list
            }
        case "ranking":
            switch items(min: 2, max: 10) {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    if list[i].number == nil, let value = list[i].value { list[i].number = number(.string(value)) }
                    list[i].tone = nil; list[i].state = nil; list[i].when = nil
                }
                // Bars only when every entry has a number, or they would mislead.
                if list.contains(where: { $0.number == nil }) { for i in list.indices { list[i].number = nil } }
                card.items = list
                card.unit = clean(args["unit"], limit: 12)
            }
        case "chart":
            switch items(min: 2, max: 24, label: "points") {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    if list[i].number == nil, let value = list[i].value { list[i].number = number(.string(value)) }
                    guard list[i].number != nil else { return .failure(.invalid("Every chart point needs a number.")) }
                    list[i].detail = nil; list[i].tone = nil; list[i].state = nil; list[i].when = nil
                }
                card.items = list
                let kind = clean(args["chart"], limit: 10)?.lowercased()
                card.chart = kind == "line" ? "line" : "bar"
                card.unit = clean(args["unit"], limit: 12)
            }
        case "steps":
            switch items(min: 1, max: 10, label: "steps") {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    if !(list[i].state.map(stepStates.contains) ?? false) { list[i].state = "todo" }
                    list[i].tone = nil; list[i].number = nil; list[i].when = nil
                }
                card.items = list
            }
        case "timeline":
            switch items(min: 1, max: 10, label: "events") {
            case .failure(let error): return .failure(error)
            case .success(var list):
                for i in list.indices {
                    guard list[i].when != nil else { return .failure(.invalid("Each timeline event needs a when.")) }
                    list[i].tone = nil; list[i].number = nil; list[i].state = nil; list[i].value = nil
                }
                card.items = list
            }
        case "comparison":
            let columns = (args["columns"]?.arrayValue ?? []).compactMap { clean($0, limit: 30) }
            guard (2...4).contains(columns.count) else { return .failure(.invalid("A comparison needs 2 to 4 columns, one per option.")) }
            let rows: [InfoCard.Row] = (args["rows"]?.arrayValue ?? []).compactMap { raw in
                guard let object = raw.objectValue, let label = clean(object["label"], limit: 40) else { return nil }
                let values = (object["values"]?.arrayValue ?? []).map { clean($0, limit: 60) ?? "–" }
                return InfoCard.Row(label: label, values: values)
            }
            guard !rows.isEmpty else { return .failure(.invalid("A comparison needs at least one row, each with a label and values.")) }
            guard rows.count <= 10 else { return .failure(.invalid("A comparison takes at most 10 rows; keep the ones that decide.")) }
            guard rows.allSatisfy({ $0.values.count == columns.count }) else {
                return .failure(.invalid("Each comparison row needs exactly \(columns.count) values, one per column, in column order."))
            }
            card.columns = columns
            card.rows = rows
            if let raw = args["highlight"]?.numberValue, raw.rounded() == raw, Int(raw) >= 0, Int(raw) < columns.count { card.highlight = Int(raw) }
        case "callout":
            guard let text = clean(args["text"], limit: 400) else { return .failure(.invalid("A callout needs text.")) }
            card.text = text
            let tone = clean(args["tone"], limit: 10)?.lowercased()
            card.tone = tone.flatMap { calloutTones.contains($0) ? $0 : nil } ?? "info"
        default:
            return .failure(.invalid("Unknown template."))
        }
        return .success(card)
    }

    public enum CardError: Error, Equatable, Sendable {
        case invalid(String)

        public var message: String {
            switch self { case .invalid(let text): "No card was shown. \(text)" }
        }
    }

    /// What Ada is told after a card is shown.
    public static func shownMessage(_ card: InfoCard, number: Int) -> String {
        "Card \(number) (\(card.template)) is shown below your reply text. Do not repeat its contents; answer in a sentence or two that stands on its own, since voice mode reads only your text."
    }
}
