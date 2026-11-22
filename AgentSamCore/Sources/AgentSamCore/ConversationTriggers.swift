import Foundation

/// A time of day, on chosen days, in the person's time zone: "weekdays at 08:00". A schedule
/// with one of these fires at that local time instead of every N minutes.
public struct ScheduleTime: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int
    /// ISO weekdays, 1 = Monday … 7 = Sunday, sorted. Empty means every day.
    public var weekdays: [Int]

    public init?(hour: Int, minute: Int, weekdays: [Int] = []) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let days = Array(Set(weekdays)).sorted()
        guard days.allSatisfy({ (1...7).contains($0) }) else { return nil }
        self.hour = hour
        self.minute = minute
        self.weekdays = days.count == 7 ? [] : days
    }

    /// Reads "8:00", "08:30" or "17:45" (24-hour) and a day list such as "weekdays", "weekends",
    /// "every day", or "mon,wed,fri". Returns nil when either part can't be read.
    public static func parse(time: String, days: String?) -> ScheduleTime? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), parts[1].count == 2 else { return nil }
        guard let weekdays = parseDays(days ?? "") else { return nil }
        return ScheduleTime(hour: hour, minute: minute, weekdays: weekdays)
    }

    static let dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    static func parseDays(_ raw: String) -> [Int]? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch text {
        case "", "daily", "every day", "everyday", "all": return []
        case "weekdays", "workdays": return [1, 2, 3, 4, 5]
        case "weekends", "weekend": return [6, 7]
        default: break
        }
        var days: [Int] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == " " }) where !token.isEmpty {
            guard let index = dayNames.firstIndex(where: { token.hasPrefix($0) }) else { return nil }
            days.append(index + 1)
        }
        return days.isEmpty ? nil : days
    }

    /// The first matching local time strictly after `date`.
    public func next(after date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            // Calendar weekdays run 1 = Sunday … 7 = Saturday.
            let iso = (calendar.component(.weekday, from: candidate) + 5) % 7 + 1
            if candidate > date && (weekdays.isEmpty || weekdays.contains(iso)) { return candidate }
        }
        return date.addingTimeInterval(86_400)
    }

    public var clock: String { String(format: "%02d:%02d", hour, minute) }

    /// "every day at 08:00", "weekdays at 08:00", "Mon, Wed at 18:30".
    public var label: String {
        let days: String
        switch weekdays {
        case []: days = "every day"
        case [1, 2, 3, 4, 5]: days = "weekdays"
        case [6, 7]: days = "weekends"
        default: days = weekdays.map { Self.dayNames[$0 - 1].capitalized }.joined(separator: ", ")
        }
        return "\(days) at \(clock)"
    }
}

/// Something outside the chat that wakes it: a new email matching a search, or a call to the
/// chat's private webhook address. Each fire sends `prompt` for the person, like a schedule,
/// with what happened attached as untrusted event data.
public struct ConversationTrigger: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case webhook
        case gmail
    }

    public static let maxPerConversation = 5
    /// At most this many runs in any hour, so a noisy inbox or a looping caller can't run up costs.
    public static let maxFiresPerHour = 6
    /// Failed runs in a row before the trigger pauses itself.
    public static let pauseAfterFailures = 3
    /// How often a Gmail trigger looks for new mail.
    public static let gmailPollSeconds: TimeInterval = 300
    static let maxSeenIDs = 200

    public var id: UUID
    public var kind: Kind
    public var prompt: String
    public var language: String
    /// Gmail search, for example `from:billing@example.com is:unread`.
    public var query: String?
    /// The secret part of the webhook address. Anyone who has it can wake the chat.
    public var token: String?
    public var createdAt: Date
    public var lastFiredAt: Date?
    public var recentFires: [Date]?
    public var failures: Int?
    public var pausedAt: Date?
    public var pauseReason: String?
    public var lastCheckedAt: Date?
    /// Gmail message IDs already seen. Nil until the first check, which only records what is there.
    public var seenIDs: [String]?

    public init(id: UUID = UUID(), kind: Kind, prompt: String, language: String = "en", query: String? = nil, token: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.language = language.lowercased().hasPrefix("es") ? "es" : "en"
        self.query = query
        self.token = token
        self.createdAt = createdAt
    }

    /// Checks model or client input. A webhook trigger gets a fresh secret token.
    public static func validate(kind: Kind, prompt: String, query: String?, language: String = "en") -> Result<ConversationTrigger, TriggerError> {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4_000 else { return .failure(.invalid("The prompt must be non-empty and under 4,000 characters.")) }
        switch kind {
        case .gmail:
            let search = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !search.isEmpty, search.count <= 500 else { return .failure(.invalid("A Gmail trigger needs a Gmail search (under 500 characters), for example from:billing@example.com.")) }
            return .success(ConversationTrigger(kind: .gmail, prompt: clean, language: language, query: search))
        case .webhook:
            return .success(ConversationTrigger(kind: .webhook, prompt: clean, language: language, token: newToken()))
        }
    }

    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    public var webhookPath: String? { token.map { "/api/hooks/\($0)" } }

    public var isPaused: Bool { pausedAt != nil }

    /// "when a new email matches \"from:boss\"" / "when its webhook is called".
    public var label: String {
        switch kind {
        case .gmail: "when a new email matches \"\(query ?? "")\""
        case .webhook: "when its webhook is called"
        }
    }

    /// Fires in the hour before `now`.
    public func firesInLastHour(now: Date) -> Int {
        (recentFires ?? []).filter { now.timeIntervalSince($0) < 3_600 }.count
    }

    public func canFire(now: Date) -> Bool {
        !isPaused && firesInLastHour(now: now) < Self.maxFiresPerHour
    }

    mutating func recordFire(now: Date) {
        lastFiredAt = now
        recentFires = ((recentFires ?? []).filter { now.timeIntervalSince($0) < 3_600 }) + [now]
    }

    mutating func recordOutcome(succeeded: Bool, now: Date) {
        if succeeded {
            failures = nil
            return
        }
        let count = (failures ?? 0) + 1
        failures = count
        if count >= Self.pauseAfterFailures {
            pausedAt = now
            pauseReason = "Paused after \(count) failed runs in a row."
        }
    }

    mutating func resume() {
        pausedAt = nil
        pauseReason = nil
        failures = nil
    }

    /// One line for Ada's workspace data.
    public var contextLine: String {
        var line = "\(id.uuidString.prefix(8)) — \(kind.rawValue), runs \(label); prompt: \(prompt)"
        if let pausedAt, let pauseReason { line += " [PAUSED \(ISO8601DateFormatter().string(from: pausedAt)): \(pauseReason)]" }
        return line
    }
}

public enum TriggerError: Error, Equatable, Sendable {
    case invalid(String)
    case tooMany
    case notFound

    public var message: String {
        switch self {
        case .invalid(let reason): reason
        case .tooMany: "This chat already has \(ConversationTrigger.maxPerConversation) triggers. Remove one first."
        case .notFound: "No trigger with that ID in this chat."
        }
    }
}

/// What woke the chat, attached to the run's user message. `data` is from outside (an email's
/// sender and subject, a webhook body), so Ada sees it as untrusted data, never as instructions.
public struct TriggerEvent: Codable, Hashable, Sendable {
    public var triggerID: UUID
    public var kind: ConversationTrigger.Kind
    public var data: String

    public static let maxDataCharacters = 8_000

    public init(triggerID: UUID, kind: ConversationTrigger.Kind, data: String) {
        self.triggerID = triggerID
        self.kind = kind
        self.data = String(data.prefix(Self.maxDataCharacters))
    }
}

/// One new email a Gmail trigger found.
public struct TriggerEmail: Sendable, Hashable {
    public var id: String
    public var from: String
    public var subject: String
    public var snippet: String

    public init(id: String, from: String, subject: String, snippet: String) {
        self.id = id
        self.from = from
        self.subject = subject
        self.snippet = snippet
    }
}

/// Ada's tools for adding and removing triggers in this chat.
public enum TriggerTools {
    public static var definitions: [APIToolDef] {
        [
            APIToolDef(
                name: "chat_trigger_add",
                description: "Make this chat run a prompt automatically when something happens, instead of on a timer: when a new email matches a Gmail search (checked every 5 minutes), or when another service calls this chat's private webhook address. Each run gets what happened as event data. Runs are limited to \(ConversationTrigger.maxFiresPerHour) an hour, and a trigger pauses itself after \(ConversationTrigger.pauseAfterFailures) failed runs in a row. Only add one when the user asks for it or accepts your offer.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("kind", .object([
                            ("type", .string("string")),
                            ("enum", .array([.string("gmail"), .string("webhook")])),
                            ("description", .string("gmail: new emails matching `query`. webhook: an HTTP POST to the chat's private address")),
                        ])),
                        ("prompt", .object([("type", .string("string")), ("description", .string("The instruction to run each time, written as the user would phrase it, e.g. \"Summarize the new invoice email and add it to invoices.csv\""))])),
                        ("query", .object([("type", .string("string")), ("description", .string("For gmail: a Gmail search, e.g. \"from:billing@example.com has:attachment\""))])),
                    ])),
                    ("required", .array([.string("kind"), .string("prompt")])),
                ])
            ),
            APIToolDef(
                name: "chat_trigger_remove",
                description: "Remove one of this chat's triggers by the ID shown in the workspace data (the first 8 characters are enough).",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("id", .object([("type", .string("string")), ("description", .string("The trigger's ID"))])),
                    ])),
                    ("required", .array([.string("id")])),
                ])
            ),
        ]
    }

    /// Changes to a chat's triggers, wired by the engine to the conversation's store.
    public struct Sink: Sendable {
        public var add: @Sendable (ConversationTrigger) async -> Result<ConversationTrigger, TriggerError>
        public var remove: @Sendable (String) async -> Result<ConversationTrigger, TriggerError>
        public var gmailConnected: Bool

        public init(add: @escaping @Sendable (ConversationTrigger) async -> Result<ConversationTrigger, TriggerError>, remove: @escaping @Sendable (String) async -> Result<ConversationTrigger, TriggerError>, gmailConnected: Bool) {
            self.add = add
            self.remove = remove
            self.gmailConnected = gmailConnected
        }
    }

    public static func run(call: APIToolCall, sink: Sink?, language: String) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        guard let sink else { return .failure("Triggers are not available in this context.") }
        switch call.function.name {
        case "chat_trigger_add":
            guard let rawKind = args["kind"]?.stringValue, let kind = ConversationTrigger.Kind(rawValue: rawKind.lowercased()) else {
                return .failure("chat_trigger_add requires kind: gmail or webhook.")
            }
            if kind == .gmail && !sink.gmailConnected {
                return .failure("Gmail is not connected, so a Gmail trigger can't check for mail. Ask the user to connect Gmail in Settings > Connections first.")
            }
            switch ConversationTrigger.validate(kind: kind, prompt: args["prompt"]?.stringValue ?? "", query: args["query"]?.stringValue, language: language) {
            case .failure(let error):
                return .failure(error.message)
            case .success(let trigger):
                switch await sink.add(trigger) {
                case .failure(let error): return .failure(error.message)
                case .success(let saved):
                    let id = saved.id.uuidString.prefix(8)
                    switch saved.kind {
                    case .gmail:
                        return ToolOutcome(resultText: "Trigger \(id) added: runs \"\(saved.prompt)\" \(saved.label). The first check only notes the emails already there; after that, each new match starts a run.")
                    case .webhook:
                        return ToolOutcome(resultText: "Trigger \(id) added: runs \"\(saved.prompt)\" \(saved.label). Its private address is this site's \(saved.webhookPath ?? "") (the full link is in this chat's Automation panel). Any POST to it starts a run, with the request body as event data. Tell the user to keep the address secret.")
                    }
                }
            }
        case "chat_trigger_remove":
            guard let id = args["id"]?.stringValue, !id.isEmpty else { return .failure("chat_trigger_remove requires id.") }
            switch await sink.remove(id) {
            case .failure(let error): return .failure(error.message)
            case .success(let removed): return ToolOutcome(resultText: "Trigger \(removed.id.uuidString.prefix(8)) removed.")
            }
        default:
            return .failure("Unknown tool: \(call.function.name).")
        }
    }
}
