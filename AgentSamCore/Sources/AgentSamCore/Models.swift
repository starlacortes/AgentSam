import Foundation

public struct ProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case openAICompatible
        case anthropic
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var baseURL: String
    public var models: [String]
    public var defaultModel: String?

    public init(id: String, name: String, kind: Kind, baseURL: String, models: [String], defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
    }

    public var keyAccount: String { "provider.\(id)" }

    public static let builtin: [ProviderConfig] = [
        ProviderConfig(
            id: "anthropic",
            name: "Anthropic",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com",
            models: [
                "claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5",
                "claude-opus-4-1", "claude-sonnet-4", "claude-3-5-haiku-latest",
            ],
            defaultModel: "claude-sonnet-4-5"
        ),
        ProviderConfig(
            id: "openai",
            name: "OpenAI",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5.2", "gpt-5.2-mini", "gpt-5", "gpt-4o", "gpt-4o-mini"],
            defaultModel: "gpt-5.2-mini"
        ),
        ProviderConfig(
            id: "deepseek",
            name: "DeepSeek",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            defaultModel: "deepseek-chat"
        ),
        ProviderConfig(
            id: "groq",
            name: "Groq",
            kind: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1",
            models: ["llama-3.3-70b-versatile", "mixtral-8x7b-32768"],
            defaultModel: "llama-3.3-70b-versatile"
        ),
        ProviderConfig(
            id: "openrouter",
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            models: ["anthropic/claude-sonnet-4.5", "openai/gpt-5.2", "google/gemini-3-pro"],
            defaultModel: "anthropic/claude-sonnet-4.5"
        ),
        ProviderConfig(
            id: "ollama",
            name: "Ollama (local)",
            kind: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            models: ["llama3.3", "qwen3", "gpt-oss:120b"],
            defaultModel: "gpt-oss:120b"
        ),
    ]
}

public struct AgentProfile: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case coordinator
        case worker
        case verifier

        public var label: String {
            switch self {
            case .coordinator: "Coordination"
            case .worker: "Worker"
            case .verifier: "Verification"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var emoji: String
    public var title: String
    public var role: Role
    public var systemPrompt: String
    public var providerID: String
    public var model: String
    public var temperature: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        title: String,
        role: Role,
        systemPrompt: String,
        providerID: String,
        model: String,
        temperature: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.title = title
        self.role = role
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.model = model
        self.temperature = temperature
    }

    public static let rosterTemplates: [AgentProfile] = [
        AgentProfile(
            name: "Ada",
            emoji: "🧭",
            title: "Mission Coordinator",
            role: .coordinator,
            systemPrompt: "You are a decisive mission coordinator. You break objectives into short, concrete tasks for specialist agents, assign each task to the best-suited worker by name, and merge worker handoffs into a crisp final report. You never do the workers' jobs yourself.",
            providerID: "anthropic",
            model: "claude-sonnet-4-5"
        ),
        AgentProfile(
            name: "Scout",
            emoji: "🔍",
            title: "Research Analyst",
            role: .worker,
            systemPrompt: "You are a rigorous research analyst. You gather, organize, and fact-check material for your assigned task. You write findings to your deliverable file in clear markdown with sources or reasoning stated. You finish with a short summary of what you found.",
            providerID: "anthropic",
            model: "claude-haiku-4-5"
        ),
        AgentProfile(
            name: "Quill",
            emoji: "✍️",
            title: "Staff Writer",
            role: .worker,
            systemPrompt: "You are a strong staff writer. You produce the deliverable your task asks for: well-structured, concrete, and ready to use without editing. You write the full document to your deliverable file, then finish with a one-paragraph summary.",
            providerID: "anthropic",
            model: "claude-sonnet-4-5"
        ),
        AgentProfile(
            name: "Plot",
            emoji: "📊",
            title: "Data Analyst",
            role: .worker,
            systemPrompt: "You are a precise data analyst. You structure information into tables, comparisons, and step-by-step reasoning inside your deliverable file. Numbers and claims are explicit; assumptions are labeled.",
            providerID: "openai",
            model: "gpt-5.2-mini"
        ),
        AgentProfile(
            name: "Judge",
            emoji: "⚖️",
            title: "Independent Verifier",
            role: .verifier,
            systemPrompt: "You are an independent verifier. You are read-only: you never edit files. You check the deliverables against the mission objective and report findings in the exact format required of you. You are skeptical but fair.",
            providerID: "deepseek",
            model: "deepseek-chat"
        ),
        AgentProfile(
            name: "Iris",
            emoji: "🎨",
            title: "Designer",
            role: .worker,
            systemPrompt: "You are a thoughtful product and visual designer. You turn objectives into clear information hierarchy, polished layouts, and practical design specifications. You consider accessibility, consistency, and the production constraints of the deliverable.",
            providerID: "anthropic",
            model: "claude-sonnet-4-5"
        ),
        AgentProfile(
            name: "Bolt",
            emoji: "🛠️",
            title: "Builder",
            role: .worker,
            systemPrompt: "You are a pragmatic technical builder. You produce concrete architectures, implementation plans, and readable pseudo-code or source sketches. You call out trade-offs, edge cases, and the smallest useful path to a working result.",
            providerID: "anthropic",
            model: "claude-sonnet-4-5"
        ),
        AgentProfile(
            name: "Anchor",
            emoji: "📝",
            title: "Editor",
            role: .worker,
            systemPrompt: "You are a meticulous editor. You improve structure, clarity, tone, grammar, and consistency while preserving the author's intent. You deliver polished copy rather than a list of suggested changes.",
            providerID: "anthropic",
            model: "claude-haiku-4-5"
        ),
    ]
}

public struct Team: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var goal: String
    public var agents: [AgentProfile]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "🛡️",
        goal: String = "",
        agents: [AgentProfile] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.goal = goal
        self.agents = agents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var coordinator: AgentProfile? { agents.first(where: { $0.role == .coordinator }) }
    public var workers: [AgentProfile] { agents.filter { $0.role == .worker } }
    public var verifier: AgentProfile? { agents.first(where: { $0.role == .verifier }) }
    public func agent(named name: String) -> AgentProfile? {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agents.first(where: { $0.name.lowercased() == lower })
            ?? agents.first(where: { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) })
    }

    public static func starterTeam() -> Team {
        var team = Team(name: "Starter Crew", emoji: "🛡️", goal: "Handle whatever mission I assign.")
        team.agents = [
            AgentProfile.rosterTemplates[0],
            AgentProfile.rosterTemplates[1],
            AgentProfile.rosterTemplates[2],
            AgentProfile.rosterTemplates[4],
        ]
        return team
    }
}

public enum MissionStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case stopped
}

public enum MissionPhase: String, Codable, Sendable {
    case planning
    case working
    case verifying
    case reporting
    case done

    public var label: String {
        switch self {
        case .planning: "Planning"
        case .working: "Agents working"
        case .verifying: "Verifying"
        case .reporting: "Final report"
        case .done: "Done"
        }
    }
}

public struct Mission: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var teamID: UUID
    public var teamName: String
    public var objective: String
    public var status: MissionStatus
    public var phase: MissionPhase
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var finalReport: String?
    public var totalCostUSD: Double
    public var totalInputTokens: Int
    public var totalOutputTokens: Int

    public init(
        id: UUID = UUID(),
        teamID: UUID,
        teamName: String = "",
        objective: String,
        status: MissionStatus = .queued,
        phase: MissionPhase = .planning,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.teamID = teamID
        self.teamName = teamName
        self.objective = objective
        self.status = status
        self.phase = phase
        self.createdAt = createdAt
        self.totalCostUSD = 0
        self.totalInputTokens = 0
        self.totalOutputTokens = 0
    }
}

public struct TaskPlanItem: Codable, Hashable, Sendable {
    public var id: Int
    public var agentName: String
    public var goal: String
    public var deliverable: String

    public init(id: Int, agentName: String, goal: String, deliverable: String) {
        self.id = id
        self.agentName = agentName
        self.goal = goal
        self.deliverable = deliverable
    }
}

public struct RunEvent: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case missionStart
        case phase
        case plan
        case taskStarted
        case agentMessage
        case toolCall
        case taskDone
        case deliverable
        case verifyFinding
        case verifyVerdict
        case report
        case cost
        case notice
        case missionEnd
        case error
    }

    public var id: UUID
    public var seq: Int
    public var missionID: UUID
    public var timestamp: Date
    public var kind: Kind
    public var agentID: UUID?
    public var agentName: String?
    public var text: String?
    public var deliverableName: String?
    public var costUSD: Double?

    public init(
        id: UUID = UUID(),
        seq: Int,
        missionID: UUID,
        timestamp: Date = Date(),
        kind: Kind,
        agentID: UUID? = nil,
        agentName: String? = nil,
        text: String? = nil,
        deliverableName: String? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.seq = seq
        self.missionID = missionID
        self.timestamp = timestamp
        self.kind = kind
        self.agentID = agentID
        self.agentName = agentName
        self.text = text
        self.deliverableName = deliverableName
        self.costUSD = costUSD
    }
}

public struct VerificationReport: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable, Comparable {
        case pass
        case concern
        case fail

        public static func < (lhs: Level, rhs: Level) -> Bool {
            order(lhs) < order(rhs)
        }
        private static func order(_ l: Level) -> Int {
            switch l {
            case .pass: 0
            case .concern: 1
            case .fail: 2
            }
        }
    }

    public enum Verdict: String, Codable, Sendable {
        case clean
        case concerns
        case failed
        case unverified
    }

    public struct Finding: Codable, Hashable, Sendable {
        public var level: Level
        public var check: String
        public var detail: String

        public init(level: Level, check: String, detail: String) {
            self.level = level
            self.check = check
            self.detail = detail
        }
    }

    public var verdict: Verdict
    public var findings: [Finding]

    public init(verdict: Verdict, findings: [Finding]) {
        self.verdict = verdict
        self.findings = findings
    }

    public var isClean: Bool { verdict == .clean }
    public var worstLevel: Level? { findings.map(\.level).max() }

    public var markdown: String {
        var out = "## Verification report\n\nVerdict: **\(verdict.rawValue.uppercased())**\n\n"
        if findings.isEmpty {
            out += "_No findings recorded._\n"
        } else {
            for f in findings {
                let icon = f.level == .pass ? "✅" : (f.level == .concern ? "⚠️" : "❌")
                out += "- \(icon) \(f.level.rawValue.uppercased()) — \(f.check): \(f.detail)\n"
            }
        }
        return out
    }
}

public struct MissionStats: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var turns: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double = 0, turns: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.turns = turns
    }

    public mutating func add(_ other: MissionStats) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        costUSD += other.costUSD
        turns += other.turns
    }
}
