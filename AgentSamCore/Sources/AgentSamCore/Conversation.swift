import Foundation

public enum ConversationRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum ConversationMessageStatus: String, Codable, Sendable {
    case running
    case complete
    case failed
}

public struct MessageStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    /// `working`, `done`, or `failed`.
    public var state: String
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: UUID = UUID(), label: String, state: String = "working", startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct ConversationMessage: Codable, Identifiable, Hashable, Sendable {
    public static let maxQuickReplies = 4
    public static let maxQuickReplyLength = 80

    public var id: UUID
    public var role: ConversationRole
    public var text: String
    public var createdAt: Date
    public var status: ConversationMessageStatus
    public var missionIDs: [UUID]
    public var teamIDs: [UUID]
    public var proposal: TeamProposal?
    public var activity: [AgentActivity]
    /// Visible progress steps (routing, connector reads, team work), shown while Ada works and afterwards on request.
    public var steps: [MessageStep]
    /// Short replies the user can send with one click: clarifying options or suggested follow-ups.
    public var quickReplies: [String]
    /// Files Ada wrote with the chat workspace tools during this reply, listed in the message.
    public var fileIDs: [String]
    /// True when the platform sent this message from the conversation's schedule, not the user.
    public var scheduled: Bool
    /// Photos the user attached to this message. The bytes are stored beside the conversation.
    public var photos: [PhotoAttachment]
    /// True when the user spoke this message in voice mode, so the reply will be read aloud.
    public var spoken: Bool
    /// For a reply to a spoken message: the part meant to be heard. The rest of `text` is detail shown
    /// on screen only. Nil when the whole reply may be spoken.
    public var speech: String?
    public var completedAt: Date?
    /// For Ada's replies: one short line per tool call she made, so later turns know what she
    /// already looked at, changed or asked approval for. Not shown in the chat.
    public var toolLog: [String]
    /// For a run a trigger started: what happened (an email, a webhook call). Nil otherwise.
    public var trigger: TriggerEvent?

    public init(
        id: UUID = UUID(),
        role: ConversationRole,
        text: String,
        createdAt: Date = Date(),
        status: ConversationMessageStatus = .complete,
        missionIDs: [UUID] = [],
        teamIDs: [UUID] = [],
        proposal: TeamProposal? = nil,
        activity: [AgentActivity] = [],
        steps: [MessageStep] = [],
        quickReplies: [String] = [],
        fileIDs: [String] = [],
        scheduled: Bool = false,
        photos: [PhotoAttachment] = [],
        spoken: Bool = false,
        speech: String? = nil,
        completedAt: Date? = nil,
        toolLog: [String] = [],
        trigger: TriggerEvent? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.missionIDs = missionIDs
        self.teamIDs = teamIDs
        self.proposal = proposal
        self.activity = activity
        self.steps = steps
        self.quickReplies = quickReplies
        self.fileIDs = fileIDs
        self.scheduled = scheduled
        self.photos = photos
        self.spoken = spoken
        self.speech = speech
        self.completedAt = completedAt
        self.toolLog = toolLog
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, status, missionIDs, teamIDs, proposal, activity, steps, quickReplies, fileIDs, scheduled, photos, spoken, speech, completedAt, toolLog, trigger
    }

    /// Older conversations on disk predate `steps`, `quickReplies`, and `completedAt`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(ConversationRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decode(ConversationMessageStatus.self, forKey: .status)
        missionIDs = try c.decodeIfPresent([UUID].self, forKey: .missionIDs) ?? []
        teamIDs = try c.decodeIfPresent([UUID].self, forKey: .teamIDs) ?? []
        proposal = try c.decodeIfPresent(TeamProposal.self, forKey: .proposal)
        activity = try c.decodeIfPresent([AgentActivity].self, forKey: .activity) ?? []
        steps = try c.decodeIfPresent([MessageStep].self, forKey: .steps) ?? []
        quickReplies = try c.decodeIfPresent([String].self, forKey: .quickReplies) ?? []
        fileIDs = try c.decodeIfPresent([String].self, forKey: .fileIDs) ?? []
        scheduled = try c.decodeIfPresent(Bool.self, forKey: .scheduled) ?? false
        photos = try c.decodeIfPresent([PhotoAttachment].self, forKey: .photos) ?? []
        spoken = try c.decodeIfPresent(Bool.self, forKey: .spoken) ?? false
        speech = try c.decodeIfPresent(String.self, forKey: .speech)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        toolLog = try c.decodeIfPresent([String].self, forKey: .toolLog) ?? []
        trigger = try c.decodeIfPresent(TriggerEvent.self, forKey: .trigger)
    }

    /// Trims, de-duplicates, and caps quick replies so model output can't flood the UI.
    public static func cleanQuickReplies(_ replies: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in replies {
            let clean = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= maxQuickReplyLength, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
            if result.count == maxQuickReplies { break }
        }
        return result
    }
}

public struct AgentActivity: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var agentName: String
    public var summary: String
    public var state: String
    public var updatedAt: Date
    public var teamID: UUID?
    public var teamName: String?

    public init(id: UUID = UUID(), agentID: UUID, agentName: String, summary: String, state: String, updatedAt: Date = Date(), teamID: UUID? = nil, teamName: String? = nil) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.summary = summary
        self.state = state
        self.updatedAt = updatedAt
        self.teamID = teamID
        self.teamName = teamName
    }
}

public struct ToolScope: Codable, Hashable, Sendable {
    public var connectorIDs: [ConnectorID]
    public var permissions: ConnectorPermissions

    public init(connectorIDs: [ConnectorID] = ConnectorID.allCases, permissions: ConnectorPermissions = ConnectorPermissions()) {
        self.connectorIDs = connectorIDs
        self.permissions = permissions
    }

    public static let readOnly = ToolScope()
}

public struct TeamProposal: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case applied
        case dismissed
    }

    public var id: UUID
    public var baseTeamID: UUID?
    public var team: Team
    public var rationale: String
    public var toolScope: ToolScope
    public var status: Status
    public var createdAt: Date

    public init(id: UUID = UUID(), baseTeamID: UUID? = nil, team: Team, rationale: String, toolScope: ToolScope = .readOnly, status: Status = .pending, createdAt: Date = Date()) {
        self.id = id
        self.baseTeamID = baseTeamID
        self.team = team
        self.rationale = rationale
        self.toolScope = toolScope
        self.status = status
        self.createdAt = createdAt
    }
}

/// A recurring prompt the platform sends for the user: when set, the server fires `prompt`
/// into the conversation every `intervalMinutes` and Ada runs it with her normal tools. This is
/// how "update this every hour without me asking" works — Ada cannot wake herself, but the
/// scheduler can wake her.
public struct ConversationSchedule: Codable, Hashable, Sendable {
    public static let allowedIntervals: [Int] = [15, 30, 60, 360, 720, 1440]

    public var prompt: String
    public var intervalMinutes: Int
    /// The language Ada answers in when the schedule fires (`en` or `es`).
    public var language: String
    public var createdAt: Date
    public var lastRunAt: Date?
    public var nextRunAt: Date
    /// When set, the schedule fires at this local time on these days, and `intervalMinutes` is unused.
    public var at: ScheduleTime?
    /// Failed runs in a row. After `pauseAfterFailures` the schedule pauses itself.
    public var failures: Int?
    public var pausedAt: Date?
    public var pauseReason: String?

    public static let pauseAfterFailures = 3

    public init(prompt: String, intervalMinutes: Int, language: String = "en", createdAt: Date = Date(), lastRunAt: Date? = nil, nextRunAt: Date? = nil, at: ScheduleTime? = nil, timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        self.prompt = prompt
        self.intervalMinutes = at == nil ? intervalMinutes : 1440
        self.language = language.lowercased().hasPrefix("es") ? "es" : "en"
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.at = at
        if let nextRunAt {
            self.nextRunAt = nextRunAt
        } else if let at {
            self.nextRunAt = at.next(after: createdAt, in: timeZone)
        } else {
            self.nextRunAt = createdAt.addingTimeInterval(TimeInterval(intervalMinutes) * 60)
        }
    }

    /// Normalizes model or client input into a valid schedule, or explains why it can't be.
    /// With `at`, the interval is ignored and the first run is the next matching local time.
    public static func validate(prompt: String, intervalMinutes: Int?, language: String = "en", at: ScheduleTime? = nil, timeZone: TimeZone = TimeZone(identifier: "UTC")!, now: Date = Date()) -> ConversationSchedule? {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4_000 else { return nil }
        if let at {
            return ConversationSchedule(prompt: clean, intervalMinutes: 1440, language: language, createdAt: now, at: at, timeZone: timeZone)
        }
        guard let intervalMinutes, allowedIntervals.contains(intervalMinutes) else { return nil }
        return ConversationSchedule(prompt: clean, intervalMinutes: intervalMinutes, language: language, createdAt: now)
    }

    /// The next due time after a run at `date`.
    public func next(after date: Date, in timeZone: TimeZone) -> Date {
        at?.next(after: date, in: timeZone) ?? date.addingTimeInterval(TimeInterval(intervalMinutes) * 60)
    }

    public var isPaused: Bool { pausedAt != nil }

    mutating func recordOutcome(succeeded: Bool, now: Date = Date()) {
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

    /// The human interval label shown in the chat and UI.
    public var intervalLabel: String {
        if let at { return at.label }
        return switch intervalMinutes {
        case 1440: "daily"
        case 720: "every 12 hours"
        case 360: "every 6 hours"
        case 60: "hourly"
        case 30: "every 30 minutes"
        default: "every 15 minutes"
        }
    }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var title: String
    public var projectName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ConversationMessage]
    public var schedule: ConversationSchedule?
    /// When the user archived the chat. Archived chats leave the sidebar, stop their schedule,
    /// and are deleted once they are older than the owner's archive retention.
    public var archivedAt: Date?
    /// The person's IANA time zone (for example "America/Los_Angeles"), from the last message their
    /// browser sent. Scheduled runs reuse it. Nil until a client reports one.
    public var timeZone: String?
    /// Events that wake the chat: new matching email, or a call to its webhook.
    public var triggers: [ConversationTrigger]

    public init(id: UUID = UUID(), ownerID: String, title: String = "New conversation", projectName: String = "Personal", createdAt: Date = Date(), updatedAt: Date = Date(), messages: [ConversationMessage] = [], schedule: ConversationSchedule? = nil, archivedAt: Date? = nil, timeZone: String? = nil, triggers: [ConversationTrigger] = []) {
        self.id = id
        self.ownerID = ownerID
        self.title = title
        self.projectName = projectName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.schedule = schedule
        self.archivedAt = archivedAt
        self.timeZone = timeZone
        self.triggers = triggers
    }

    /// The person's time zone for schedules, UTC until their browser reports one.
    public var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")! }

    public var summary: ConversationSummary {
        ConversationSummary(id: id, title: title, projectName: projectName, updatedAt: updatedAt, running: messages.contains { $0.status == .running }, archivedAt: archivedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerID, title, projectName, createdAt, updatedAt, messages, schedule, archivedAt, timeZone, triggers
    }

    /// Older conversations on disk predate `schedule` and `archivedAt`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ownerID = try c.decode(String.self, forKey: .ownerID)
        title = try c.decode(String.self, forKey: .title)
        projectName = try c.decode(String.self, forKey: .projectName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        schedule = try c.decodeIfPresent(ConversationSchedule.self, forKey: .schedule)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        triggers = try c.decodeIfPresent([ConversationTrigger].self, forKey: .triggers) ?? []
    }
}

public struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var projectName: String
    public var updatedAt: Date
    public var running: Bool
    public var archivedAt: Date?

    public init(id: UUID, title: String, projectName: String, updatedAt: Date, running: Bool, archivedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.running = running
        self.archivedAt = archivedAt
    }
}

/// How long one owner keeps archived chats. `retentionDays == nil` means never delete them.
/// `configured` stays false until the owner answers the first-archive question, so the web
/// app knows to ask once.
public struct ArchiveSettings: Codable, Hashable, Sendable {
    public static let allowedRetentionDays = [7, 30, 90, 365]

    public var retentionDays: Int?
    public var configured: Bool

    public init(retentionDays: Int? = nil, configured: Bool = false) {
        self.retentionDays = retentionDays
        self.configured = configured
    }

    /// The moment before which an archive is expired, or nil when archives are kept forever.
    public func cutoff(now: Date = Date()) -> Date? {
        guard let retentionDays else { return nil }
        return now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
    }
}

public struct MemorySource: Codable, Hashable, Sendable {
    public var conversationID: UUID
    public var userMessageID: UUID
    public var assistantMessageID: UUID
    public var timestamp: Date

    public init(conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID, timestamp: Date = Date()) {
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.timestamp = timestamp
    }
}

public struct WorkspaceMemory: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var markdown: String
    public var sources: [MemorySource]
    public var updatedAt: Date?
    public var compactionCount: Int
    public var pendingEntries: Int
    /// Facts the person, or Ada at their request, asked to keep word for word.
    public var pinned: [PinnedMemory]

    public init(enabled: Bool = true, markdown: String = "", sources: [MemorySource] = [], updatedAt: Date? = nil, compactionCount: Int = 0, pendingEntries: Int = 0, pinned: [PinnedMemory] = []) {
        self.enabled = enabled
        self.markdown = markdown
        self.sources = sources
        self.updatedAt = updatedAt
        self.compactionCount = compactionCount
        self.pendingEntries = pendingEntries
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey { case enabled, markdown, sources, updatedAt, compactionCount, pendingEntries, pinned }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        sources = try container.decodeIfPresent([MemorySource].self, forKey: .sources) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        compactionCount = try container.decodeIfPresent(Int.self, forKey: .compactionCount) ?? 0
        pendingEntries = try container.decodeIfPresent(Int.self, forKey: .pendingEntries) ?? 0
        pinned = try container.decodeIfPresent([PinnedMemory].self, forKey: .pinned) ?? []
    }

    /// What Ada reads: remembered facts first, then the compacted summary. Empty when memory is off.
    public var promptText: String {
        guard enabled else { return "" }
        guard !pinned.isEmpty else { return markdown }
        let facts = pinned.map { "- \($0.text)" }.joined(separator: "\n")
        return "## Remembered on request\n\(facts)\n\n\(markdown)"
    }

    public static let empty = WorkspaceMemory(
        markdown: "# Workspace memory\n\nNo conversations have been summarized yet.\n\n## Sources\n- No messages yet."
    )
}

public struct GuideState: Codable, Hashable, Sendable {
    public var completed: Bool
    public var resetAt: Date?

    public init(completed: Bool = false, resetAt: Date? = nil) {
        self.completed = completed
        self.resetAt = resetAt
    }
}

public enum ConversationRoute: String, Codable, Sendable {
    case direct = "DIRECT"
    case solo = "SOLO"
    /// Run one or more skills: the server assembles each skill's specialists and runs them as a mission.
    case useSkill = "USE_SKILL"
    /// Older routing prompts (kept by operators who edited theirs) still name teams; mapped to skills.
    case routeTeam = "ROUTE_TEAM"
    case proposeTeam = "PROPOSE_TEAM"
    case clarify = "CLARIFY"
}

public struct ConversationDecision: Decodable, Sendable {
    public var action: ConversationRoute
    public var message: String?
    /// For USE_SKILL: the skill IDs to run, at most three.
    public var skillIDs: [String]?
    public var teamIDs: [UUID]?
    public var rationale: String?
    /// For CLARIFY: two to four short answers the user can pick with one click.
    public var options: [String]?

    public init(action: ConversationRoute, message: String? = nil, skillIDs: [String]? = nil, teamIDs: [UUID]? = nil, rationale: String? = nil, options: [String]? = nil) {
        self.action = action
        self.message = message
        self.skillIDs = skillIDs
        self.teamIDs = teamIDs
        self.rationale = rationale
        self.options = options
    }

    public static func parse(_ text: String) -> ConversationDecision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationDecision.self, from: data)
    }
}

public enum ConversationError: Error, LocalizedError, Sendable {
    case notFound
    case emptyMessage
    case messageTooLong
    case alreadyRunning
    case noProvider
    case missingProviderKey(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Conversation not found."
        case .emptyMessage: "Write a message first."
        case .messageTooLong: "Messages can be at most 20,000 characters."
        case .alreadyRunning: "Ada is already responding in this conversation."
        case .noProvider: "Add a model provider before chatting with Ada."
        case .missingProviderKey(let name): "Add an API key for \(name) in Settings before chatting with Ada."
        case .persistence(let reason): reason
        }
    }
}
