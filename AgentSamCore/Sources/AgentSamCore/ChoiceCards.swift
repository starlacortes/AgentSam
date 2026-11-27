import Foundation

/// A card of tappable choices Ada puts in her reply when the person must pick before she goes on:
/// one question or a few in a row, each with a short list of options, one or several picks, and
/// optionally a box for their own answer. A later question may depend on an earlier answer.
///
/// Like `InfoCard`, it is data only: plain-text questions and options the app draws itself. The
/// person's picks come back as their next message, both as readable text (what Ada and every app
/// see) and as `ChoiceAnswer` (what the web app draws as a compact answered card).
public struct ChoiceCard: Codable, Hashable, Sendable, Identifiable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        /// One short line under the label: what picking it means.
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// A question shows only when an earlier one was answered with one of `anyOf`.
    public struct Condition: Codable, Hashable, Sendable {
        /// The earlier question's `id`.
        public var question: String
        /// Option labels of that question, any of which shows this one.
        public var anyOf: [String]

        public init(question: String, anyOf: [String]) {
            self.question = question
            self.anyOf = anyOf
        }
    }

    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var question: String
        public var options: [Option]
        /// Several options may be picked.
        public var multiple: Bool
        /// The person may type their own answer.
        public var other: Bool
        public var showIf: Condition?

        public init(id: String, question: String, options: [Option], multiple: Bool = false, other: Bool = false, showIf: Condition? = nil) {
            self.id = id
            self.question = question
            self.options = options
            self.multiple = multiple
            self.other = other
            self.showIf = showIf
        }

        private enum CodingKeys: String, CodingKey { case id, question, options, multiple, other, showIf }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            question = try c.decode(String.self, forKey: .question)
            options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
            multiple = try c.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
            other = try c.decodeIfPresent(Bool.self, forKey: .other) ?? false
            showIf = try c.decodeIfPresent(Condition.self, forKey: .showIf)
        }
    }

    public enum State: String, Codable, Sendable {
        /// Waiting for the person.
        case pending
        /// The person answered, on the card or in words that matched its options.
        case answered
        /// The person wrote something else instead; the card no longer takes answers.
        case closed
    }

    public var id: UUID
    public var title: String?
    public var questions: [Question]
    public var state: State
    public var answer: ChoiceAnswer?

    public init(id: UUID = UUID(), title: String? = nil, questions: [Question], state: State = .pending, answer: ChoiceAnswer? = nil) {
        self.id = id
        self.title = title
        self.questions = questions
        self.state = state
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey { case id, title, questions, state, answer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        // A state a later build adds reads as closed, which never takes answers.
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .closed
        answer = try c.decodeIfPresent(ChoiceAnswer.self, forKey: .answer)
    }

    /// The questions that show, in order, given the options picked so far (by question id).
    public func visibleQuestions(picked: [String: [String]]) -> [Question] {
        var shown: [Question] = []
        for question in questions {
            if let condition = question.showIf {
                guard shown.contains(where: { $0.id == condition.question }) else { continue }
                let chosen = Set((picked[condition.question] ?? []).map(ChoiceCardTools.folded))
                guard condition.anyOf.contains(where: { chosen.contains(ChoiceCardTools.folded($0)) }) else { continue }
            }
            shown.append(question)
        }
        return shown
    }

    /// One line for Ada's tool log, so later turns know what she asked without the whole card.
    public var logLine: String {
        var line = "ask_choice"
        if let title { line += " “\(title)”" }
        let parts = questions.enumerated().map { index, question in
            let kind = question.multiple ? "pick any" : "pick one"
            return "Q\(index + 1) \(question.question) [\(question.options.map(\.label).joined(separator: " | "))\(question.other ? " | own answer" : "")] (\(kind)\(question.showIf == nil ? "" : ", only for some answers"))"
        }
        line += " " + parts.joined(separator: "; ")
        return line.count > 600 ? String(line.prefix(599)) + "…" : line
    }
}

/// The person's answers to a choice card, saved on their message and on the card.
public struct ChoiceAnswer: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var questionID: String
        public var question: String
        public var picked: [String]
        /// Their own words, when the question took them.
        public var other: String?

        public init(questionID: String, question: String, picked: [String], other: String? = nil) {
            self.questionID = questionID
            self.question = question
            self.picked = picked
            self.other = other
        }

        /// "Lisbon", "Friday, Saturday", "Friday, my own: Monday morning".
        public func value(language: String) -> String {
            var parts = picked
            if let other { parts.append(other) }
            return parts.joined(separator: ", ")
        }
    }

    public var cardID: UUID
    public var items: [Item]
    /// The person answered by writing or saying it, not on the card.
    public var inWords: Bool

    public init(cardID: UUID, items: [Item], inWords: Bool = false) {
        self.cardID = cardID
        self.items = items
        self.inWords = inWords
    }

    private enum CodingKeys: String, CodingKey { case cardID, items, inWords }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cardID = try c.decode(UUID.self, forKey: .cardID)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        inWords = try c.decodeIfPresent(Bool.self, forKey: .inWords) ?? false
    }

    /// The message text Ada (and any app that does not draw the card) reads.
    public func text(title: String?, language: String) -> String {
        let es = language == "es"
        var lines = [es ? "Mis respuestas\(title.map { " a «\($0)»" } ?? ""):" : "My answers\(title.map { " to “\($0)”" } ?? ""):"]
        for item in items {
            lines.append("- \(item.question) → \(item.value(language: language))")
        }
        return lines.joined(separator: "\n")
    }
}

/// What the app sends when the person answers on the card: option numbers, from 0, per question.
public struct ChoiceReply: Codable, Hashable, Sendable {
    public struct Pick: Codable, Hashable, Sendable {
        public var question: String
        public var picked: [Int]
        public var other: String?

        public init(question: String, picked: [Int], other: String? = nil) {
            self.question = question
            self.picked = picked
            self.other = other
        }
    }

    public var cardID: UUID
    public var answers: [Pick]

    public init(cardID: UUID, answers: [Pick]) {
        self.cardID = cardID
        self.answers = answers
    }
}

/// `ask_choice`: Ada's tool for a card of choices.
public enum ChoiceCardTools {
    public static let toolName = "ask_choice"
    public static let names: Set<String> = [toolName]
    public static let maxQuestions = 5
    public static let minOptions = 2
    public static let maxOptions = 6
    public static let maxOtherLength = 300

    public static var definitions: [APIToolDef] {
        let text: JSONValue = .object([("type", .string("string"))])
        let flag: JSONValue = .object([("type", .string("boolean"))])
        let option: JSONValue = .object([
            ("type", .string("object")),
            ("properties", .object([("label", text), ("detail", text)])),
            ("required", .array([.string("label")])),
        ])
        let question: JSONValue = .object([
            ("type", .string("object")),
            ("properties", .object([
                ("id", text),
                ("question", text),
                ("options", .object([("type", .string("array")), ("items", option)])),
                ("multiple", flag),
                ("other", flag),
                ("show_if", .object([
                    ("type", .string("object")),
                    ("properties", .object([("question", text), ("any_of", .object([("type", .string("array")), ("items", text)]))])),
                ])),
            ])),
            ("required", .array([.string("question"), .string("options")])),
        ])
        return [
            APIToolDef(
                name: toolName,
                description: """
                Show tappable choices when the person must pick before you can go on and the answers are a few \
                concrete options: which of the approaches you lay out, which items to include, or a short setup of \
                several questions in a row. Never for an open question (what to fix, a name, a date), a yes/no, a \
                fact, a vague request you do not yet understand, or anything you can reasonably assume: ask those in plain text. \
                Ask everything in one card. Once the person has answered a card, do the work; never follow it with \
                another card. Your reply ends with the \
                card; the answers come back as the person's next message. Text before the call is optional, one \
                short line of context; do not repeat the questions. Voice mode reads the card aloud. Plain text, no Markdown.
                - questions: 1-\(maxQuestions), shown one at a time with a review before sending. Each: question, \
                options \(minOptions)-\(maxOptions) {label (a few words), detail? (one line)}, multiple? (pick several), \
                other? (adds a box for their own answer), id? (short key).
                - show_if? {question: an earlier question's id, any_of: its option labels}: ask this one only after those answers.
                - title? A few words naming the whole card.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("title", text),
                        ("questions", .object([("type", .string("array")), ("items", question)])),
                    ])),
                    ("required", .array([.string("questions")])),
                ])
            ),
        ]
    }

    /// Lowercased, without accents or surrounding spaces, for comparing labels and words.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func flag(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?: return flag
        case .string(let text)?: return ["true", "yes", "1"].contains(text.lowercased())
        case .number(let number)?: return number != 0
        default: return false
        }
    }

    public enum CardError: Error, Equatable, Sendable {
        case invalid(String)

        public var message: String {
            switch self { case .invalid(let text): "No choice card was shown. \(text)" }
        }
    }

    /// Builds a card from an `ask_choice` call, or says what to fix. A call with one question at the
    /// top level (question, options) instead of a `questions` list is read as a one-question card.
    public static func card(from args: [String: JSONValue]) -> Result<ChoiceCard, CardError> {
        var rawQuestions = args["questions"]?.arrayValue ?? []
        if rawQuestions.isEmpty, args["question"] != nil { rawQuestions = [JSONValue.object(args)] }
        guard !rawQuestions.isEmpty else { return .failure(.invalid("Give 1 to \(maxQuestions) questions, each with a question and \(minOptions) to \(maxOptions) options.")) }
        guard rawQuestions.count <= maxQuestions else { return .failure(.invalid("A card takes at most \(maxQuestions) questions; ask only what you need before you can go on.")) }
        var questions: [ChoiceCard.Question] = []
        // How a show_if may name an earlier question: its id, or its number from 1.
        var aliases: [String: String] = [:]
        for (index, raw) in rawQuestions.enumerated() {
            guard let object = raw.objectValue, let text = InfoCardTools.clean(object["question"] ?? object["text"], limit: 160) else {
                return .failure(.invalid("Question \(index + 1) needs its question text."))
            }
            var seen = Set<String>()
            let options: [ChoiceCard.Option] = (object["options"]?.arrayValue ?? []).compactMap { raw in
                let label: String?
                var detail: String?
                if let option = raw.objectValue {
                    label = InfoCardTools.clean(option["label"] ?? option["text"], limit: 60)
                    detail = InfoCardTools.clean(option["detail"] ?? option["description"], limit: 100)
                } else {
                    label = InfoCardTools.clean(raw, limit: 60)
                }
                guard let label, seen.insert(folded(label)).inserted else { return nil }
                if detail.map(folded) == folded(label) { detail = nil }
                return ChoiceCard.Option(label: label, detail: detail)
            }
            guard options.count >= minOptions else { return .failure(.invalid("Question \(index + 1) needs at least \(minOptions) different options. For an open question, ask in plain text.")) }
            guard options.count <= maxOptions else { return .failure(.invalid("Question \(index + 1) takes at most \(maxOptions) options; keep the likeliest and set other: true.")) }
            var id = InfoCardTools.clean(object["id"], limit: 24) ?? "q\(index + 1)"
            if questions.contains(where: { $0.id == id }) { id = "q\(index + 1)" }
            var question = ChoiceCard.Question(id: id, question: text, options: options, multiple: flag(object["multiple"] ?? object["multi"] ?? object["multi_select"]), other: flag(object["other"] ?? object["allow_other"]))
            if index > 0, let condition = (object["show_if"] ?? object["showIf"])?.objectValue {
                let named = InfoCardTools.clean(condition["question"], limit: 24) ?? ""
                guard let target = aliases[named] ?? aliases[folded(named)], let earlier = questions.first(where: { $0.id == target }) else {
                    return .failure(.invalid("Question \(index + 1)'s show_if must name an earlier question by its id."))
                }
                let wanted = ((condition["any_of"] ?? condition["anyOf"] ?? condition["answers"])?.arrayValue ?? [condition["answer"]].compactMap { $0 })
                    .compactMap { InfoCardTools.clean($0, limit: 60) }
                let matched = earlier.options.map(\.label).filter { label in wanted.contains { folded($0) == folded(label) } }
                guard !matched.isEmpty else {
                    return .failure(.invalid("Question \(index + 1)'s show_if any_of must use option labels of question \(earlier.id): \(earlier.options.map(\.label).joined(separator: ", "))."))
                }
                question.showIf = ChoiceCard.Condition(question: earlier.id, anyOf: matched)
            }
            aliases[id] = id
            aliases[folded(id)] = id
            aliases["\(index + 1)"] = id
            aliases["q\(index + 1)"] = id
            questions.append(question)
        }
        return .success(ChoiceCard(title: InfoCardTools.clean(args["title"], limit: 60), questions: questions))
    }

    /// What Ada is told once the card is shown. Her reply ends there.
    public static let shownMessage = "The choice card is shown and your reply ends here. The person's answers come back as their next message."

    /// Checks answers sent from the card against it: every question that shows is answered with
    /// options it has, and answers to questions that do not show are left out.
    public static func answer(_ card: ChoiceCard, reply: ChoiceReply) -> Result<ChoiceAnswer, CardError> {
        var picked: [String: [String]] = [:]
        var others: [String: String] = [:]
        for pick in reply.answers {
            guard let question = card.questions.first(where: { $0.id == pick.question }) else { continue }
            let labels = Array(NSOrderedSet(array: pick.picked.filter { question.options.indices.contains($0) }).array.compactMap { $0 as? Int }).map { question.options[$0].label }
            picked[question.id] = labels
            if question.other, let raw = pick.other {
                let own = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if !own.isEmpty { others[question.id] = String(own.prefix(maxOtherLength)) }
            }
        }
        var items: [ChoiceAnswer.Item] = []
        for question in card.visibleQuestions(picked: picked) {
            var labels = picked[question.id] ?? []
            let own = others[question.id]
            // One pick: their own answer takes the place of an option.
            if !question.multiple {
                if own != nil { labels = [] } else { labels = Array(labels.prefix(1)) }
            }
            guard !labels.isEmpty || own != nil else { return .failure(.invalid("Answer “\(question.question)” first.")) }
            items.append(ChoiceAnswer.Item(questionID: question.id, question: question.question, picked: labels, other: own))
        }
        return .success(ChoiceAnswer(cardID: card.id, items: items))
    }

    // MARK: - Answers in words

    static let ordinals: [String: Int] = [
        "first": 0, "second": 1, "third": 2, "fourth": 3, "fifth": 4, "sixth": 5,
        "primera": 0, "primero": 0, "segunda": 1, "segundo": 1, "tercera": 2, "tercero": 2, "cuarta": 3, "cuarto": 3, "quinta": 4, "quinto": 4, "sexta": 5, "sexto": 5,
    ]
    /// Plain numbers ("option two", "la 3"), trusted only in a short answer.
    static let numbers: [String: Int] = [
        "one": 0, "two": 1, "three": 2, "four": 3, "five": 4, "six": 5,
        "uno": 0, "una": 0, "dos": 1, "tres": 2, "cuatro": 3, "cinco": 4, "seis": 5,
        "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5,
    ]

    /// When the person writes or says their answer instead of tapping, the card still shows what
    /// they picked if it is clear: a one-question card, and words that name its options (“Lisbon”,
    /// “the second one”, “la última”). Nil when it is not clear; Ada still reads their words.
    public static func match(_ text: String, card: ChoiceCard) -> ChoiceAnswer? {
        guard card.questions.count == 1, let question = card.questions.first else { return nil }
        let said = " " + folded(text).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
        guard said.count <= 200 else { return nil }
        var found: [Int] = []
        for (index, option) in question.options.enumerated() {
            let label = folded(option.label).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
            if !label.isEmpty, said.contains(" \(label) ") { found.append(index) }
        }
        if found.isEmpty {
            let words = said.split(separator: " ").map(String.init)
            // "The second one", "la última": a position in the list, in a short answer only, since
            // longer sentences use these words for other things ("two people", "first, let's...").
            if words.count <= 6 {
                if words.contains(where: { ["last", "ultima", "ultimo"].contains($0) }) { found = [question.options.count - 1] }
                for word in words { if let index = ordinals[word], question.options.indices.contains(index), !found.contains(index) { found.append(index) } }
            }
            if found.isEmpty, words.count <= 3 {
                for word in words { if let index = numbers[word], question.options.indices.contains(index), !found.contains(index) { found.append(index) } }
            }
        }
        guard !found.isEmpty, question.multiple || found.count == 1 else { return nil }
        return ChoiceAnswer(cardID: card.id, items: [ChoiceAnswer.Item(questionID: question.id, question: question.question, picked: found.sorted().map { question.options[$0].label })], inWords: true)
    }

    // MARK: - Voice

    /// The card as Ada says it in voice mode, after her text: each question that does not depend on
    /// an earlier answer, with its options.
    public static func spokenText(_ card: ChoiceCard, language: String) -> String {
        let es = language == "es"
        let shown = card.questions.filter { $0.showIf == nil }
        var lines: [String] = []
        for (index, question) in shown.enumerated() {
            let labels = question.options.map(\.label)
            let list = labels.count > 1 ? labels.dropLast().joined(separator: ", ") + (es ? " o " : ", or ") + labels[labels.count - 1] : labels.joined()
            var line = shown.count > 1 ? (index == 0 ? (es ? "Primero: " : "First: ") : (es ? "Después: " : "Then: ")) : ""
            line += question.question
            if !line.hasSuffix("?") && !line.hasSuffix(".") { line += "." }
            line += " " + (question.multiple ? (es ? "Puedes elegir varias: " : "You can pick several: ") : "") + list + "."
            if question.other { line += es ? " O dime otra cosa." : " Or tell me something else." }
            lines.append(line)
        }
        if shown.count < card.questions.count { lines.append(es ? "Según lo que elijas, te preguntaré algo más." : "Depending on your answer, I’ll ask a bit more.") }
        lines.append(es ? "Puedes decírmelo o tocar tu respuesta en pantalla." : "Just say your answer, or tap it on screen.")
        return lines.joined(separator: "\n")
    }
}
