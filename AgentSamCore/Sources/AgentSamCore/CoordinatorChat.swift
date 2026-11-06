import Foundation

// MARK: - Models

/// One line of a coordinator chat as people see it. The raw model transcript (tool calls and
/// results) is kept separately in `CoordinatorChat.transcript`.
public struct ChatLine: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Something the person said or typed.
        case user
        /// Something the coordinator said.
        case coordinator
        /// A tool the coordinator ran, shown as a short note ("Checked mission status").
        case action
        /// A problem: the model call failed, a key is missing, and so on.
        case error
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    /// Set when the line is about one mission (a launch, a status check, a report).
    public var missionID: UUID?

    public init(id: UUID = UUID(), kind: Kind, text: String, createdAt: Date = Date(), missionID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.missionID = missionID
    }
}

/// An action the coordinator wants to take that needs the person's yes first.
public struct PendingChatAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case startMission
        case stopMission
    }

    public var kind: Kind
    /// For `startMission`: the objective. For `stopMission`: the mission's objective, for display.
    public var summary: String
    public var teamID: UUID?
    public var teamName: String?
    public var missionID: UUID?
    public var createdAt: Date
    /// How many user lines the chat had when the action was proposed. The action can only be
    /// confirmed after a newer user line, so the model can't propose and approve in one turn.
    public var userLineCount: Int

    public init(kind: Kind, summary: String, teamID: UUID? = nil, teamName: String? = nil, missionID: UUID? = nil, createdAt: Date = Date(), userLineCount: Int) {
        self.kind = kind
        self.summary = summary
        self.teamID = teamID
        self.teamName = teamName
        self.missionID = missionID
        self.createdAt = createdAt
        self.userLineCount = userLineCount
    }
}

/// A conversation with a team's coordinator.
public struct CoordinatorChat: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Who the chat belongs to (a user id, or "server-token").
    public var ownerID: String
    public var teamID: UUID
    public var teamName: String
    public var title: String
    public var lines: [ChatLine]
    public var pendingAction: PendingChatAction?
    /// "en" or "es".
    public var language: String
    public var createdAt: Date
    public var updatedAt: Date
    public var totalCostUSD: Double
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    /// Full model-facing transcript, including tool calls and tool results.
    public var transcript: [APIMessage]

    public init(id: UUID = UUID(), ownerID: String, team: Team, language: String = "en", createdAt: Date = Date()) {
        self.id = id
        self.ownerID = ownerID
        self.teamID = team.id
        self.teamName = team.name
        self.title = ""
        self.lines = []
        self.pendingAction = nil
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.totalCostUSD = 0
        self.totalInputTokens = 0
        self.totalOutputTokens = 0
        self.transcript = []
    }

    public var userLineCount: Int { lines.filter { $0.kind == .user }.count }

    /// The chat without its raw transcript, for listing and for clients.
    public var publicRepresentation: CoordinatorChat {
        var copy = self
        copy.transcript = []
        return copy
    }
}

public struct ChatSettings: Codable, Hashable, Sendable {
    /// The team whose coordinator is the default contact. Nil means the first team.
    public var defaultTeamID: UUID?

    public init(defaultTeamID: UUID? = nil) {
        self.defaultTeamID = defaultTeamID
    }
}

// MARK: - Store

/// Stores coordinator chats as `chats/<uuid>.json` and chat settings as `chat-settings.json`.
public actor ChatStore {
    public nonisolated let root: URL

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
    }

    public nonisolated var chatsDirectory: URL { root.appendingPathComponent("chats", isDirectory: true) }

    private nonisolated func chatURL(_ id: UUID) -> URL {
        chatsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ chat: CoordinatorChat) {
        if let data = try? Self.encoder.encode(chat) {
            try? data.write(to: chatURL(chat.id), options: .atomic)
        }
    }

    public func chat(id: UUID) -> CoordinatorChat? {
        guard let data = try? Data(contentsOf: chatURL(id)) else { return nil }
        return try? Self.decoder.decode(CoordinatorChat.self, from: data)
    }

    public func list(ownerID: String, limit: Int = 100) -> [CoordinatorChat] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CoordinatorChat? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(CoordinatorChat.self, from: data)
            }
            .filter { $0.ownerID == ownerID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.publicRepresentation)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: chatURL(id))
    }

    public func loadSettings() -> ChatSettings {
        let url = root.appendingPathComponent("chat-settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? Self.decoder.decode(ChatSettings.self, from: data) else { return ChatSettings() }
        return settings
    }

    public func saveSettings(_ settings: ChatSettings) {
        let url = root.appendingPathComponent("chat-settings.json")
        if let data = try? Self.encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Mission control

/// What the coordinator chat needs from the host app to act on missions. The server implements it
/// with `ServerContext`; tests implement it with a fake.
public protocol ChatMissionControl: Sendable {
    func teams() async -> [Team]
    func missions(limit: Int) async -> [Mission]
    func mission(id: UUID) async -> Mission?
    func isRunning(missionID: UUID) async -> Bool
    func recentEvents(missionID: UUID, limit: Int) async -> [RunEvent]
    func deliverable(missionID: UUID, name: String) async -> String?
    func startMission(team: Team, objective: String, language: String) async throws -> Mission
    func stopMission(id: UUID) async
}

// MARK: - Engine

public enum CoordinatorChatError: Error, LocalizedError, Sendable {
    case noCoordinator
    case unknownProvider(String)
    case missingKey(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case .noCoordinator: "This team has no agents to talk to."
        case .unknownProvider(let id): "The coordinator uses provider \"\(id)\", which isn't configured."
        case .missingKey(let name): "No API key is set for \(name)."
        case .busy: "The coordinator is still answering the last message."
        }
    }
}

/// Signature of one model call, so tests can replace the network.
public typealias ChatCompletion = @Sendable (_ provider: ProviderConfig, _ key: String, _ model: String, _ system: String, _ messages: [APIMessage], _ tools: [APIToolDef]?, _ temperature: Double?) async throws -> LLMReply

/// Runs one person's turn in a coordinator chat: a short tool-use loop with the team's
/// coordinator profile, its provider, and its key.
public actor CoordinatorChatEngine {
    public static let maxSteps = 6
    public static let maxTranscriptMessages = 60

    private let store: ChatStore
    private let missions: ChatMissionControl
    private let keyRing: KeyRing
    private let providers: @Sendable () async -> [ProviderConfig]
    private let complete: ChatCompletion
    private var busy: Set<UUID> = []

    public init(
        store: ChatStore,
        missions: ChatMissionControl,
        keyRing: KeyRing,
        providers: @escaping @Sendable () async -> [ProviderConfig],
        complete: ChatCompletion? = nil
    ) {
        self.store = store
        self.missions = missions
        self.keyRing = keyRing
        self.providers = providers
        if let complete {
            self.complete = complete
        } else {
            let client = LLMClient()
            self.complete = { provider, key, model, system, messages, tools, temperature in
                try await client.complete(provider: provider, key: key, model: model, system: system, messages: messages, tools: tools, temperature: temperature)
            }
        }
    }

    /// Adds the person's message, runs the coordinator, saves, and returns the updated chat.
    public func send(chatID: UUID, text: String) async throws -> CoordinatorChat? {
        guard var chat = await store.chat(id: chatID) else { return nil }
        guard !busy.contains(chatID) else { throw CoordinatorChatError.busy }
        busy.insert(chatID)
        defer { busy.remove(chatID) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.lines.append(ChatLine(kind: .user, text: trimmed))
        chat.transcript.append(.user(trimmed))
        if chat.title.isEmpty { chat.title = String(trimmed.prefix(60)) }
        chat.updatedAt = Date()
        await store.save(chat)

        do {
            try await runCoordinator(&chat)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? (error as? LLMError)?.message ?? error.localizedDescription
            chat.lines.append(ChatLine(kind: .error, text: message))
        }
        chat.updatedAt = Date()
        await store.save(chat)
        return chat
    }

    /// Approves or declines the pending action directly (the Confirm / Cancel buttons).
    public func resolvePending(chatID: UUID, approve: Bool) async throws -> CoordinatorChat? {
        guard var chat = await store.chat(id: chatID) else { return nil }
        guard !busy.contains(chatID) else { throw CoordinatorChatError.busy }
        busy.insert(chatID)
        defer { busy.remove(chatID) }
        guard let pending = chat.pendingAction else { return chat }

        chat.pendingAction = nil
        if approve {
            let result = await perform(pending, chat: &chat)
            // Tell the model what happened so the conversation stays coherent.
            chat.transcript.append(.user("[The person pressed Confirm.] \(result)"))
        } else {
            chat.lines.append(ChatLine(kind: .action, text: "Cancelled: \(pending.summary)", missionID: pending.missionID))
            chat.transcript.append(.user("[The person pressed Cancel. Do not take that action.]"))
        }
        chat.updatedAt = Date()
        await store.save(chat)
        return chat
    }

    // MARK: Loop

    private func runCoordinator(_ chat: inout CoordinatorChat) async throws {
        let teams = await missions.teams()
        guard let team = teams.first(where: { $0.id == chat.teamID }) else {
            throw CoordinatorChatError.noCoordinator
        }
        guard let coordinator = team.coordinator ?? team.agents.first else {
            throw CoordinatorChatError.noCoordinator
        }
        let registry = ProviderRegistry(providers: await providers())
        guard let provider = registry.provider(id: coordinator.providerID) else {
            throw CoordinatorChatError.unknownProvider(coordinator.providerID)
        }
        guard let key = keyRing.get(provider.keyAccount), !key.isEmpty else {
            throw CoordinatorChatError.missingKey(provider.name)
        }

        let system = Self.systemPrompt(team: team, coordinator: coordinator, allTeams: teams, chat: chat)
        for _ in 0..<Self.maxSteps {
            let reply = try await complete(provider, key, coordinator.model, system, Self.trimmed(chat.transcript), ChatTools.definitions, coordinator.temperature)
            chat.totalInputTokens += reply.inputTokens
            chat.totalOutputTokens += reply.outputTokens
            chat.totalCostUSD += Pricing.estimate(model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)
            chat.transcript.append(reply.message)

            if let text = reply.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                chat.lines.append(ChatLine(kind: .coordinator, text: text))
            }
            guard let calls = reply.message.tool_calls, !calls.isEmpty else { return }
            for call in calls {
                let result = await runTool(call, chat: &chat, team: team, teams: teams)
                chat.transcript.append(.tool(id: call.id, content: result))
            }
        }
    }

    /// Keeps the transcript within bounds without splitting a tool call from its results.
    static func trimmed(_ transcript: [APIMessage]) -> [APIMessage] {
        guard transcript.count > maxTranscriptMessages else { return transcript }
        var slice = Array(transcript.suffix(maxTranscriptMessages))
        while let first = slice.first, first.role != "user" {
            slice.removeFirst()
        }
        return slice
    }

    static func systemPrompt(team: Team, coordinator: AgentProfile, allTeams: [Team], chat: CoordinatorChat) -> String {
        let roster = team.agents
            .map { "- \($0.name) (\($0.title), \($0.role.rawValue))" }
            .joined(separator: "\n")
        let otherTeams = allTeams
            .filter { $0.id != team.id }
            .map { "- \($0.name)" }
            .joined(separator: "\n")
        var prompt = """
        You are \(coordinator.name), the coordinator of the AgentSam team "\(team.name)". \
        You are the person's main contact: they talk to you to get work done by your team.
        \(coordinator.systemPrompt)

        Your team:
        \(roster)
        """
        if !otherTeams.isEmpty {
            prompt += "\n\nOther teams you can launch missions on:\n\(otherTeams)"
        }
        prompt += """


        How you work in this chat:
        - Answer in two or three short, plain sentences, as if speaking. No markdown headings, tables, or file paths.
        - Use your tools to check missions and reports instead of guessing. Refer to missions by their objective, not their id.
        - To start or stop a mission, call start_mission or stop_mission. That only proposes it; then ask the person to confirm.
        - Call confirm_pending_action only after the person clearly says yes in a new message. If they say no or change their mind, call cancel_pending_action.
        - A mission costs money and takes minutes. Make the objective specific and self-contained before proposing it.
        """
        if let pending = chat.pendingAction {
            prompt += "\n\nWaiting for the person to confirm: \(Self.describe(pending))."
        }
        if chat.language == "es" {
            prompt += "\n\nReply in Spanish."
        }
        return prompt
    }

    static func describe(_ action: PendingChatAction) -> String {
        switch action.kind {
        case .startMission: "start a mission for \(action.teamName ?? "the team"): \(action.summary)"
        case .stopMission: "stop the mission \"\(action.summary)\""
        }
    }

    // MARK: Tools

    private func runTool(_ call: APIToolCall, chat: inout CoordinatorChat, team: Team, teams: [Team]) async -> String {
        let args = ChatTools.arguments(call.function.arguments)
        switch call.function.name {
        case "list_teams":
            chat.lines.append(ChatLine(kind: .action, text: "Looked at teams"))
            return teams.map { candidate in
                let members = candidate.agents.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
                return "\(candidate.name): \(members)"
            }.joined(separator: "\n")

        case "list_missions":
            let limit = min(20, max(1, args["limit"]?.numberValue.map(Int.init) ?? 8))
            chat.lines.append(ChatLine(kind: .action, text: "Checked recent missions"))
            let list = await missions.missions(limit: limit)
            guard !list.isEmpty else { return "No missions yet." }
            var rows: [String] = []
            for mission in list {
                rows.append(await Self.missionLine(mission, running: missions.isRunning(missionID: mission.id)))
            }
            return rows.joined(separator: "\n")

        case "mission_status":
            guard let mission = await findMission(args["mission_id"]?.stringValue) else {
                return "No mission with that id. Call list_missions to see ids."
            }
            chat.lines.append(ChatLine(kind: .action, text: "Checked \"\(Self.short(mission.objective))\"", missionID: mission.id))
            let running = await missions.isRunning(missionID: mission.id)
            let events = await missions.recentEvents(missionID: mission.id, limit: 8)
            let recent = events
                .compactMap { event -> String? in
                    guard let text = event.text, !text.isEmpty else { return nil }
                    return "- \(event.kind.rawValue)\(event.agentName.map { " (\($0))" } ?? ""): \(String(text.prefix(240)))"
                }
                .joined(separator: "\n")
            return Self.missionLine(mission, running: running) + (recent.isEmpty ? "" : "\nRecent activity:\n\(recent)")

        case "read_report":
            guard let mission = await findMission(args["mission_id"]?.stringValue) else {
                return "No mission with that id. Call list_missions to see ids."
            }
            chat.lines.append(ChatLine(kind: .action, text: "Read the report for \"\(Self.short(mission.objective))\"", missionID: mission.id))
            var report = mission.finalReport
            if report?.isEmpty ?? true {
                report = await missions.deliverable(missionID: mission.id, name: "final-report.md")
            }
            guard let report, !report.isEmpty else {
                return "There is no final report yet. Status: \(mission.status.rawValue), phase: \(mission.phase.rawValue)."
            }
            return String(report.prefix(12_000))

        case "start_mission":
            let objective = (args["objective"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else { return "An objective is required." }
            guard objective.count <= 20_000 else { return "That objective is too long." }
            var target = team
            if let name = args["team"]?.stringValue, !name.isEmpty {
                guard let match = Self.team(named: name, in: teams) else {
                    return "No team named \(name). Teams: \(teams.map(\.name).joined(separator: ", "))."
                }
                target = match
            }
            chat.pendingAction = PendingChatAction(kind: .startMission, summary: objective, teamID: target.id, teamName: target.name, userLineCount: chat.userLineCount)
            return "Proposed. Nothing has started. Ask the person to confirm launching this mission on \(target.name)."

        case "stop_mission":
            guard let mission = await findMission(args["mission_id"]?.stringValue) else {
                return "No mission with that id. Call list_missions to see ids."
            }
            guard await missions.isRunning(missionID: mission.id) else { return "That mission is not running." }
            chat.pendingAction = PendingChatAction(kind: .stopMission, summary: mission.objective, missionID: mission.id, userLineCount: chat.userLineCount)
            return "Proposed. Nothing has stopped. Ask the person to confirm stopping it."

        case "confirm_pending_action":
            guard let pending = chat.pendingAction else { return "There is nothing waiting for confirmation." }
            guard chat.userLineCount > pending.userLineCount else {
                return "Not confirmed: the person hasn't answered yet. Ask them and wait for their reply."
            }
            chat.pendingAction = nil
            return await perform(pending, chat: &chat)

        case "cancel_pending_action":
            guard let pending = chat.pendingAction else { return "There is nothing waiting for confirmation." }
            chat.pendingAction = nil
            chat.lines.append(ChatLine(kind: .action, text: "Cancelled: \(Self.short(pending.summary))", missionID: pending.missionID))
            return "Cancelled."

        default:
            return "Unknown tool \(call.function.name)."
        }
    }

    private func perform(_ pending: PendingChatAction, chat: inout CoordinatorChat) async -> String {
        switch pending.kind {
        case .startMission:
            let teams = await missions.teams()
            guard let teamID = pending.teamID, let team = teams.first(where: { $0.id == teamID }) else {
                return "That team no longer exists, so nothing started."
            }
            do {
                let mission = try await missions.startMission(team: team, objective: pending.summary, language: chat.language)
                chat.lines.append(ChatLine(kind: .action, text: "Launched \"\(Self.short(pending.summary))\" on \(team.name)", missionID: mission.id))
                return "Mission started on \(team.name). Id: \(Self.shortID(mission.id))."
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                chat.lines.append(ChatLine(kind: .error, text: "Couldn't launch the mission: \(reason)"))
                return "The launch failed: \(reason)"
            }
        case .stopMission:
            guard let id = pending.missionID else { return "No mission to stop." }
            await missions.stopMission(id: id)
            chat.lines.append(ChatLine(kind: .action, text: "Stopped \"\(Self.short(pending.summary))\"", missionID: id))
            return "Stop requested."
        }
    }

    private func findMission(_ raw: String?) async -> Mission? {
        let needle = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 4 else { return nil }
        if let id = UUID(uuidString: needle), let mission = await missions.mission(id: id) { return mission }
        let matches = await missions.missions(limit: 500).filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func team(named name: String, in teams: [Team]) -> Team? {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return teams.first(where: { $0.name.lowercased() == lower })
            ?? teams.first(where: { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) })
    }

    static func missionLine(_ mission: Mission, running: Bool) -> String {
        let state = running ? "running (\(mission.phase.rawValue))" : mission.status.rawValue
        return "[\(shortID(mission.id))] \(short(mission.objective, 140)) — team \(mission.teamName), \(state), cost $\(String(format: "%.3f", mission.totalCostUSD))"
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func short(_ text: String, _ limit: Int = 80) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }
}

// MARK: - Tool definitions

public enum ChatTools {
    private static func schema(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(required.map(JSONValue.string))),
        ])
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object([("type", .string(type)), ("description", .string(description))])
    }

    public static var definitions: [APIToolDef] {
        [
            APIToolDef(name: "list_teams", description: "List the teams and their members.", parameters: schema([])),
            APIToolDef(
                name: "list_missions",
                description: "List recent missions, newest first, with short ids, status, and cost.",
                parameters: schema([("limit", prop("integer", "How many to list, 1 to 20. Default 8."))])
            ),
            APIToolDef(
                name: "mission_status",
                description: "Status and recent activity of one mission.",
                parameters: schema([("mission_id", prop("string", "The mission's short id from list_missions, or its full id."))], required: ["mission_id"])
            ),
            APIToolDef(
                name: "read_report",
                description: "Read a finished mission's final report.",
                parameters: schema([("mission_id", prop("string", "The mission's short id or full id."))], required: ["mission_id"])
            ),
            APIToolDef(
                name: "start_mission",
                description: "Propose launching a mission. Nothing starts until the person confirms.",
                parameters: schema([
                    ("objective", prop("string", "A specific, self-contained objective for the team.")),
                    ("team", prop("string", "Team name. Omit to use your own team.")),
                ], required: ["objective"])
            ),
            APIToolDef(
                name: "stop_mission",
                description: "Propose stopping a running mission. Nothing stops until the person confirms.",
                parameters: schema([("mission_id", prop("string", "The mission's short id or full id."))], required: ["mission_id"])
            ),
            APIToolDef(
                name: "confirm_pending_action",
                description: "Carry out the proposed action. Only after the person said yes in a new message.",
                parameters: schema([])
            ),
            APIToolDef(
                name: "cancel_pending_action",
                description: "Drop the proposed action because the person declined or changed their mind.",
                parameters: schema([])
            ),
        ]
    }

    static func arguments(_ raw: String) -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else { return [:] }
        return object
    }
}
