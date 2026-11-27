import Foundation

/// A small set of saved chats that is replayed against a prompt version and a model, so a prompt
/// or model change can be compared before and after instead of judged by reading the text.
///
/// Each case is one chat: an optional history, the person's next message, and what a good first
/// step looks like (which tool Ada reaches for, whether she hands the work on, how long a text
/// answer is, and what it must or must not claim). A replay sends exactly the request the server
/// would send for that message (the real system prompt, the real tool definitions, the same
/// context block) and scores Ada's first step. No tool is ever run, so a replay changes nothing.
///
/// The prompt version under test is whatever this build renders: run it on two commits, or with
/// two models, and compare the reports.
public enum PromptReplay {
    public struct Turn: Codable, Hashable, Sendable {
        public var role: String
        public var text: String
        /// Ada's reply used her browser (a page is open), as the server records it on the message.
        public var usedBrowser: Bool?

        public init(role: String, text: String, usedBrowser: Bool? = nil) {
            self.role = role
            self.text = text
            self.usedBrowser = usedBrowser
        }
    }

    /// What Ada has in this chat: which connections, machines and files exist.
    public struct Setup: Codable, Hashable, Sendable {
        /// Connected services, by connector ID (`gmail`, `googleads`, `cloudflare`, `github`, `web`).
        public var connectors: [String]
        /// Whether the connected services' write tools are switched on.
        public var connectorWrites: Bool
        /// Project files, patch, move, delete and the terminal (the server's extended access).
        public var extended: Bool
        public var workstation: Bool
        public var browser: Bool
        /// Lines of the chat's file list, as "name — bytes".
        public var files: [String]
        public var memory: String
        public var knowledge: String
        /// A recurring schedule already set on the chat, as its prompt and interval.
        public var schedulePrompt: String?
        public var scheduleMinutes: Int?

        public init(connectors: [String] = ["web"], connectorWrites: Bool = false, extended: Bool = true, workstation: Bool = false, browser: Bool = false, files: [String] = [], memory: String = "", knowledge: String = "", schedulePrompt: String? = nil, scheduleMinutes: Int? = nil) {
            self.connectors = connectors
            self.connectorWrites = connectorWrites
            self.extended = extended
            self.workstation = workstation
            self.browser = browser
            self.files = files
            self.memory = memory
            self.knowledge = knowledge
            self.schedulePrompt = schedulePrompt
            self.scheduleMinutes = scheduleMinutes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connectors = try container.decodeIfPresent([String].self, forKey: .connectors) ?? ["web"]
            connectorWrites = try container.decodeIfPresent(Bool.self, forKey: .connectorWrites) ?? false
            extended = try container.decodeIfPresent(Bool.self, forKey: .extended) ?? true
            workstation = try container.decodeIfPresent(Bool.self, forKey: .workstation) ?? false
            browser = try container.decodeIfPresent(Bool.self, forKey: .browser) ?? false
            files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
            memory = try container.decodeIfPresent(String.self, forKey: .memory) ?? ""
            knowledge = try container.decodeIfPresent(String.self, forKey: .knowledge) ?? ""
            schedulePrompt = try container.decodeIfPresent(String.self, forKey: .schedulePrompt)
            scheduleMinutes = try container.decodeIfPresent(Int.self, forKey: .scheduleMinutes)
        }
    }

    /// What a good first step looks like. Every field is optional; only the ones set are scored.
    public struct Expect: Codable, Hashable, Sendable {
        /// Ada's first step calls at least one of these tools.
        public var callsAny: [String]?
        /// Ada's first step calls none of these tools.
        public var callsNone: [String]?
        /// Ada answers in text, without calling any tool.
        public var noTools: Bool?
        /// A text answer has at most this many words.
        public var maxWords: Int?
        /// A text answer contains at least one of these (case-insensitive).
        public var mentionsAny: [String]?
        /// A text answer contains none of these (case-insensitive): claims Ada must not make.
        public var mentionsNone: [String]?
        /// A text answer is in this language (`en` or `es`).
        public var language: String?
        /// A text answer asks the person a question.
        public var asksQuestion: Bool?

        public init(callsAny: [String]? = nil, callsNone: [String]? = nil, noTools: Bool? = nil, maxWords: Int? = nil, mentionsAny: [String]? = nil, mentionsNone: [String]? = nil, language: String? = nil, asksQuestion: Bool? = nil) {
            self.callsAny = callsAny
            self.callsNone = callsNone
            self.noTools = noTools
            self.maxWords = maxWords
            self.mentionsAny = mentionsAny
            self.mentionsNone = mentionsNone
            self.language = language
            self.asksQuestion = asksQuestion
        }

        /// Every tool name this expectation refers to.
        public var toolNames: [String] { (callsAny ?? []) + (callsNone ?? []) }
    }

    public struct Case: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        /// One line on what the case checks.
        public var about: String
        /// The app language the person uses (`en` or `es`).
        public var language: String
        /// The person is talking in voice mode.
        public var spoken: Bool
        public var setup: Setup
        /// Earlier turns, oldest first, ending on Ada's turn.
        public var history: [Turn]
        public var message: String
        public var expect: Expect

        public init(id: String, about: String, language: String = "en", spoken: Bool = false, setup: Setup = Setup(), history: [Turn] = [], message: String, expect: Expect) {
            self.id = id
            self.about = about
            self.language = language
            self.spoken = spoken
            self.setup = setup
            self.history = history
            self.message = message
            self.expect = expect
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            about = try container.decode(String.self, forKey: .about)
            language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
            spoken = try container.decodeIfPresent(Bool.self, forKey: .spoken) ?? false
            setup = try container.decodeIfPresent(Setup.self, forKey: .setup) ?? Setup()
            history = try container.decodeIfPresent([Turn].self, forKey: .history) ?? []
            message = try container.decode(String.self, forKey: .message)
            expect = try container.decode(Expect.self, forKey: .expect)
        }
    }

    // MARK: - The set

    /// The cases that ship with this build (`Resources/replay-cases.json`).
    public static func builtInCases() throws -> [Case] {
        guard let url = Bundle.module.url(forResource: "replay-cases", withExtension: "json") else {
            throw LLMError(message: "replay-cases.json is missing from the build.")
        }
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    // MARK: - Building the request

    /// Exactly what the server would send for the case's message.
    public struct Request: Sendable {
        public var system: String
        public var tools: [APIToolDef]
        public var messages: [APIMessage]

        /// Rough sizes in characters, for the report: tool definitions, system prompt, earlier
        /// turns, and the newest user message with its context.
        public var sizes: (tools: Int, system: Int, history: Int, turn: Int) {
            let toolText = (try? JSONEncoder().encode(tools)).map(\.count) ?? 0
            let history = messages.dropLast().reduce(0) { $0 + ($1.content?.count ?? 0) }
            return (toolText, system.count, history, messages.last?.content?.count ?? 0)
        }
    }

    /// The moment every replay pretends it is, so two runs send the same bytes.
    public static let fixedNow = Date(timeIntervalSince1970: 1_795_800_000)
    static let timeZoneID = "America/Los_Angeles"

    /// The tools Ada is offered in a chat with this setup: the same lists the server builds.
    public static func offeredTools(for setup: Setup, history: [ConversationMessage] = []) -> (offered: OfferedTools, connectorTools: [APIToolDef]) {
        var connectorTools: [APIToolDef] = []
        let permissions: ConnectorPermissions = setup.connectorWrites ? .all : ConnectorPermissions()
        for provider in ConnectorHub.providers where setup.connectors.contains(provider.id.rawValue) {
            connectorTools += provider.toolDefs(permissions: permissions)
        }
        let skills = Skill.builtIns
        let taskTools = TaskTools.definitions(catalog: SkillTeams.catalog(skills))
        let delegateTools = HelperTools.definitions(hasWorkstation: setup.workstation, hasMCP: false, hasBrowser: setup.browser, saved: [], canSave: setup.extended, skills: skills.map(\.id))
        let offered = OfferedTools.direct(connectorTools: connectorTools, hasLinkedMissions: false, hasExtendedAccess: setup.extended, hasWorkstation: setup.workstation, hasBrowser: setup.browser, browserOpen: ConversationEngine.browserInUse(history: history), mcpTools: [], taskTools: taskTools, delegateTools: delegateTools)
        return (offered, connectorTools)
    }

    public static func request(for replay: Case, store: PromptStore = PromptStore(builtins: PromptStore.builtins), now: Date = fixedNow) -> Request {
        let setup = replay.setup
        let history = replay.history.map { turn -> ConversationMessage in
            var message = ConversationMessage(role: turn.role == "user" ? .user : .assistant, text: turn.text)
            message.usedBrowser = turn.usedBrowser ?? false
            return message
        }
        let tools = offeredTools(for: setup, history: history)
        var coordinator = AgentProfile.rosterTemplates[0]
        coordinator.systemPrompt = store.render("ada_base")
        let zone = TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "UTC")!
        let schedule = setup.schedulePrompt.map {
            ConversationSchedule(prompt: $0, intervalMinutes: setup.scheduleMinutes ?? 1_440, language: replay.language, createdAt: now.addingTimeInterval(-86_400), nextRunAt: now.addingTimeInterval(3_600), timeZone: zone)
        }
        let context = ConversationPromptContext(
            projectName: "Personal",
            history: history,
            memory: setup.memory,
            workspaceManifest: setup.files.joined(separator: "\n"),
            missionReferences: "",
            missionIDs: [],
            schedule: schedule,
            scheduled: false,
            knowledge: setup.knowledge,
            spoken: replay.spoken,
            now: now,
            timeZoneID: timeZoneID,
            personName: "Sam"
        )
        let system = ConversationPrompts.directResponseSystem(coordinator: coordinator, context: context, connectorTools: tools.connectorTools, hasLinkedMissions: false, hasExtendedTools: setup.extended, store: store, language: replay.language)
        var messages = ConversationEngine.chatTurns(from: history)
        messages.append(.user(context.userTurn(replay.message)))
        return Request(system: system, tools: tools.offered.definitions, messages: messages)
    }

    // MARK: - Scoring

    /// What a check is about. The report adds the checks up by dimension.
    public enum Dimension: String, Codable, CaseIterable, Sendable {
        /// Reaching for the right tool, or for none.
        case tools
        /// Handing work to a specialist or a job only when it is worth it.
        case delegation
        /// Keeping a text answer as short as the request allows.
        case length
        /// Not claiming what did not happen, and saying what must be said.
        case truth
        /// Answering in the person's language.
        case language
        /// Asking when a needed detail is missing.
        case clarify
    }

    public struct Check: Codable, Hashable, Sendable {
        public var dimension: Dimension
        public var passed: Bool
        public var detail: String
    }

    static let delegationTools: Set<String> = ["delegate", TaskTools.startToolName]

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The reply's visible text, without the follow-up suggestions block the app shows as buttons.
    static func visibleText(_ message: APIMessage) -> String {
        ConversationPrompts.extractSuggestions(DSMLToolCalls.strip(message.content ?? "")).text
    }

    /// Scores Ada's first step for a case.
    public static func score(_ replay: Case, reply: APIMessage) -> [Check] {
        let expect = replay.expect
        let called = (reply.tool_calls ?? []).map(\.function.name)
        let text = visibleText(reply)
        let lowered = text.lowercased()
        let answered = called.isEmpty
        var checks: [Check] = []
        func dimension(for names: [String]) -> Dimension { names.contains(where: delegationTools.contains) ? .delegation : .tools }
        let calledText = called.isEmpty ? "no tool" : called.joined(separator: ", ")

        if let any = expect.callsAny, !any.isEmpty {
            checks.append(Check(dimension: dimension(for: any), passed: called.contains(where: any.contains), detail: "expected one of \(any.joined(separator: ", ")); called \(calledText)"))
        }
        if let none = expect.callsNone, !none.isEmpty {
            // Checks about handing work on and about other tools are scored apart.
            for (kind, names) in [(Dimension.delegation, none.filter(delegationTools.contains)), (.tools, none.filter { !delegationTools.contains($0) })] where !names.isEmpty {
                let hit = called.filter(names.contains)
                checks.append(Check(dimension: kind, passed: hit.isEmpty, detail: hit.isEmpty ? "did not call \(names.joined(separator: ", "))" : "should not have called \(hit.joined(separator: ", "))"))
            }
        }
        if expect.noTools == true {
            checks.append(Check(dimension: .tools, passed: answered, detail: answered ? "answered without tools" : "expected a text answer; called \(calledText)"))
        }
        // The rest are about a text answer. A step that calls a tool has not answered yet, so they
        // count as failed only when the case also said Ada should answer without tools.
        let scoreText = answered || expect.noTools == true
        if let limit = expect.maxWords, scoreText {
            let words = wordCount(text)
            checks.append(Check(dimension: .length, passed: answered && words <= limit, detail: "\(words) words; limit \(limit)"))
        }
        if let any = expect.mentionsAny, !any.isEmpty, scoreText {
            let found = any.first { lowered.contains($0.lowercased()) }
            checks.append(Check(dimension: .truth, passed: found != nil, detail: found.map { "mentions \"\($0)\"" } ?? "mentions none of: \(any.joined(separator: " | "))"))
        }
        if let none = expect.mentionsNone, !none.isEmpty, scoreText {
            let found = none.first { lowered.contains($0.lowercased()) }
            checks.append(Check(dimension: .truth, passed: found == nil, detail: found.map { "must not say \"\($0)\"" } ?? "makes none of the forbidden claims"))
        }
        if let language = expect.language, scoreText {
            let detected = SpokenNumbers.language(of: text, fallback: language == "es" ? "en" : "es")
            checks.append(Check(dimension: .language, passed: answered && detected == language, detail: "expected \(language); looks like \(detected)"))
        }
        if let asks = expect.asksQuestion, scoreText {
            let has = text.contains("?")
            checks.append(Check(dimension: .clarify, passed: answered && has == asks, detail: has ? "asks a question" : "asks no question"))
        }
        return checks
    }

    // MARK: - Running

    public struct Outcome: Codable, Sendable {
        public var caseID: String
        public var about: String
        public var toolCalls: [String]
        public var text: String
        public var checks: [Check]
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var outputTokens: Int
        public var seconds: Double
        /// Set when the model call failed; the case then has no checks.
        public var error: String?

        public var passed: Bool { error == nil && checks.allSatisfy(\.passed) }
    }

    /// Replays every case once against one model, one after the other so the provider's prompt
    /// cache behaves as it does in a real chat. Nothing is executed: only the first step is read.
    public static func run(cases: [Case], provider: ProviderConfig, key: String, model: String, client: LLMClient = LLMClient(), store: PromptStore = PromptStore(builtins: PromptStore.builtins), progress: (@Sendable (Outcome) -> Void)? = nil) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for replay in cases {
            let request = request(for: replay, store: store)
            let started = Date()
            var outcome = Outcome(caseID: replay.id, about: replay.about, toolCalls: [], text: "", checks: [], inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, seconds: 0, error: nil)
            do {
                let reply = try await client.complete(provider: provider, key: key, model: model, system: request.system, messages: request.messages, tools: request.tools, temperature: AgentProfile.rosterTemplates[0].temperature, maxTokens: 1_500)
                outcome.toolCalls = (reply.message.tool_calls ?? []).map(\.function.name)
                outcome.text = visibleText(reply.message)
                outcome.checks = score(replay, reply: reply.message)
                outcome.inputTokens = reply.inputTokens
                outcome.cachedInputTokens = reply.cachedInputTokens
                outcome.outputTokens = reply.outputTokens
            } catch let error as LLMError {
                outcome.error = error.message
            } catch {
                outcome.error = error.localizedDescription
            }
            outcome.seconds = Date().timeIntervalSince(started)
            progress?(outcome)
            outcomes.append(outcome)
        }
        return outcomes
    }

    // MARK: - Report

    /// A short fingerprint of the prompt text in use, so two reports can be told apart.
    public static func promptFingerprint(store: PromptStore = PromptStore(builtins: PromptStore.builtins)) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let text = store.records().map { "\($0.id)\n\($0.currentText ?? "")" }.joined(separator: "\n\n") + ConversationPrompts.approvalStyle + ConversationPrompts.voiceStyle(language: "en")
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// The report as Markdown: totals by dimension, one line per case, and the failed checks.
    public static func report(outcomes: [Outcome], model: String, label: String = "", store: PromptStore = PromptStore(builtins: PromptStore.builtins)) -> String {
        let checks = outcomes.flatMap(\.checks)
        let failedCalls = outcomes.filter { $0.error != nil }.count
        func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "n/a" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%" }
        var lines = [
            "# Ada replay report\(label.isEmpty ? "" : ": \(label)")",
            "",
            "- Model: `\(model)`",
            "- Prompt fingerprint: `\(promptFingerprint(store: store))`",
            "- Cases passed: \(outcomes.filter(\.passed).count) of \(outcomes.count)\(failedCalls == 0 ? "" : " (\(failedCalls) model call\(failedCalls == 1 ? "" : "s") failed)")",
            "- Checks passed: \(checks.filter(\.passed).count) of \(checks.count) (\(percent(checks.filter(\.passed).count, checks.count)))",
        ]
        let input = outcomes.reduce(0) { $0 + $1.inputTokens }
        let cached = outcomes.reduce(0) { $0 + $1.cachedInputTokens }
        let output = outcomes.reduce(0) { $0 + $1.outputTokens }
        lines.append("- Tokens: \(input) in (\(cached) from cache, \(percent(cached, input))), \(output) out")
        lines += ["", "| Dimension | Passed | Checks |", "| --- | --- | --- |"]
        for dimension in Dimension.allCases {
            let own = checks.filter { $0.dimension == dimension }
            guard !own.isEmpty else { continue }
            lines.append("| \(dimension.rawValue) | \(own.filter(\.passed).count) (\(percent(own.filter(\.passed).count, own.count))) | \(own.count) |")
        }
        lines += ["", "| Case | Result | First step | In | Cached | Out | Seconds |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for outcome in outcomes {
            let step = outcome.error != nil ? "call failed" : (outcome.toolCalls.isEmpty ? "text, \(wordCount(outcome.text)) words" : outcome.toolCalls.joined(separator: ", "))
            lines.append("| \(outcome.caseID) | \(outcome.passed ? "pass" : "FAIL") | \(step) | \(outcome.inputTokens) | \(outcome.cachedInputTokens) | \(outcome.outputTokens) | \(String(format: "%.1f", outcome.seconds)) |")
        }
        let failures = outcomes.filter { !$0.passed }
        if !failures.isEmpty {
            lines += ["", "## Failed cases", ""]
            for outcome in failures {
                lines.append("### \(outcome.caseID)")
                lines.append(outcome.about)
                if let error = outcome.error { lines.append("- Model call failed: \(error)") }
                for check in outcome.checks where !check.passed { lines.append("- \(check.dimension.rawValue): \(check.detail)") }
                if !outcome.text.isEmpty { lines.append("- Answer: \(String(outcome.text.replacingOccurrences(of: "\n", with: " ").prefix(400)))") }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
