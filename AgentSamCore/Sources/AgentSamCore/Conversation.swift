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

public struct ConversationMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: ConversationRole
    public var text: String
    public var createdAt: Date
    public var status: ConversationMessageStatus
    public var missionIDs: [UUID]
    public var teamIDs: [UUID]
    public var proposal: TeamProposal?
    public var activity: [AgentActivity]

    public init(
        id: UUID = UUID(),
        role: ConversationRole,
        text: String,
        createdAt: Date = Date(),
        status: ConversationMessageStatus = .complete,
        missionIDs: [UUID] = [],
        teamIDs: [UUID] = [],
        proposal: TeamProposal? = nil,
        activity: [AgentActivity] = []
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

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var title: String
    public var projectName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ConversationMessage]

    public init(id: UUID = UUID(), ownerID: String, title: String = "New conversation", projectName: String = "Personal", createdAt: Date = Date(), updatedAt: Date = Date(), messages: [ConversationMessage] = []) {
        self.id = id
        self.ownerID = ownerID
        self.title = title
        self.projectName = projectName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    public var summary: ConversationSummary {
        ConversationSummary(id: id, title: title, projectName: projectName, updatedAt: updatedAt, running: messages.contains { $0.status == .running })
    }
}

public struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var projectName: String
    public var updatedAt: Date
    public var running: Bool

    public init(id: UUID, title: String, projectName: String, updatedAt: Date, running: Bool) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.updatedAt = updatedAt
        self.running = running
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

    public init(enabled: Bool = true, markdown: String = "", sources: [MemorySource] = [], updatedAt: Date? = nil, compactionCount: Int = 0, pendingEntries: Int = 0) {
        self.enabled = enabled
        self.markdown = markdown
        self.sources = sources
        self.updatedAt = updatedAt
        self.compactionCount = compactionCount
        self.pendingEntries = pendingEntries
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
    case routeTeam = "ROUTE_TEAM"
    case proposeTeam = "PROPOSE_TEAM"
    case clarify = "CLARIFY"
}

public struct TeamProposalDraft: Decodable, Sendable {
    public var baseTeamID: UUID?
    public var name: String
    public var emoji: String?
    public var goal: String
    public var agents: [AgentProfile]
    public var rationale: String?
    public var toolScope: ToolScope?

    public init(baseTeamID: UUID? = nil, name: String, emoji: String? = nil, goal: String, agents: [AgentProfile], rationale: String? = nil, toolScope: ToolScope? = nil) {
        self.baseTeamID = baseTeamID
        self.name = name
        self.emoji = emoji
        self.goal = goal
        self.agents = agents
        self.rationale = rationale
        self.toolScope = toolScope
    }
}

public struct ConversationDecision: Decodable, Sendable {
    public var action: ConversationRoute
    public var message: String?
    public var teamIDs: [UUID]?
    public var rationale: String?
    public var proposal: TeamProposalDraft?

    public init(action: ConversationRoute, message: String? = nil, teamIDs: [UUID]? = nil, rationale: String? = nil, proposal: TeamProposalDraft? = nil) {
        self.action = action
        self.message = message
        self.teamIDs = teamIDs
        self.rationale = rationale
        self.proposal = proposal
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
    case invalidProposal(String)
    case proposalHandled
    case noProvider
    case missingProviderKey(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Conversation not found."
        case .emptyMessage: "Write a message first."
        case .messageTooLong: "Messages can be at most 20,000 characters."
        case .alreadyRunning: "Ada is already responding in this conversation."
        case .invalidProposal(let reason): reason
        case .proposalHandled: "This team proposal has already been handled."
        case .noProvider: "Add a model provider before chatting with Ada."
        case .missingProviderKey(let name): "Add an API key for \(name) in Settings before chatting with Ada."
        case .persistence(let reason): reason
        }
    }
}
