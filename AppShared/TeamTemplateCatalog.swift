import SwiftUI
import AgentSamCore

struct TeamTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let goal: String
    let summary: String
    let capabilities: [String]
    let example: String
    let memberNames: [String]
    let lowCost: Bool
    let coverColors: [Color]

    func makeTeam(providers: [ProviderConfig]) -> Team {
        let agents = memberNames.compactMap { name in
            AgentProfile.rosterTemplates.first(where: { $0.name == name })
        }.map { original in
            var agent = original
            agent.id = UUID()
            let originalProvider = providers.first(where: { $0.id == original.providerID })
            let provider = originalProvider ?? providers.first(where: { $0.id == "anthropic" }) ?? providers.first
            agent.providerID = provider?.id ?? ""
            if let provider {
                if originalProvider == nil || !provider.models.contains(original.model) {
                    agent.model = provider.defaultModel ?? provider.models.first ?? ""
                }
            } else {
                agent.model = ""
            }
            return agent
        }
        return Team(name: name, emoji: emoji, goal: goal, agents: agents)
    }

    func agents(providers: [ProviderConfig]) -> [AgentProfile] {
        makeTeam(providers: providers).agents
    }
}

enum TeamTemplateCatalog {
    static let all: [TeamTemplate] = [
        TeamTemplate(
            id: "research", name: "Research Crew", emoji: "🔎",
            goal: "Find facts, cite sources, and deliver defensible research briefs.",
            summary: "Finds facts, cites sources, and hands you a clean, defensible brief.",
            capabilities: ["fact-checked", "sources cited"],
            example: "What’s actually new in solid-state batteries this quarter?",
            memberNames: ["Ada", "Scout", "Quill", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x0F2E20), Color(agentSamHex: 0x0A1B14)]
        ),
        TeamTemplate(
            id: "studio", name: "Content Studio", emoji: "✒️",
            goal: "Brainstorm, draft, design, and polish on-brand content.",
            summary: "A small creative agency—brainstorms, drafts, designs, and ships copy daily.",
            capabilities: ["brand voice", "headline variants"],
            example: "Launch email sequence for our new oat-milk line.",
            memberNames: ["Ada", "Quill", "Iris", "Anchor"], lowCost: false,
            coverColors: [Color(agentSamHex: 0x2B2210), Color(agentSamHex: 0x171105)]
        ),
        TeamTemplate(
            id: "datalab", name: "Data Lab", emoji: "📈",
            goal: "Turn tables and data into clear, carefully checked analysis.",
            summary: "Drop in data; walk out with comparisons, flagged outliers, and a plain-English verdict.",
            capabilities: ["table-native", "stat-skeptic"],
            example: "Why did trial conversions dip in March?",
            memberNames: ["Ada", "Plot", "Bolt", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x0D2824), Color(agentSamHex: 0x081815)]
        ),
        TeamTemplate(
            id: "newsdesk", name: "News Desk", emoji: "🗞️",
            goal: "Scan topics, rank what matters, and write concise briefings.",
            summary: "A morning briefing desk—scans your topics, ranks what matters, writes it tight.",
            capabilities: ["daily digest", "no fluff"],
            example: "Everything worth knowing about the chip market, 8am daily.",
            memberNames: ["Ada", "Scout", "Anchor", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x14290F), Color(agentSamHex: 0x0C180A)]
        ),
        TeamTemplate(
            id: "foundry", name: "Startup Foundry", emoji: "🚀",
            goal: "Pressure-test ideas with market research and candid analysis.",
            summary: "Pressure-tests ideas—market research, holes poked, one-pager drafted.",
            capabilities: ["candid", "deck-ready"],
            example: "Pressure-test my idea: task-running for elderly care.",
            memberNames: ["Ada", "Scout", "Plot", "Quill"], lowCost: false,
            coverColors: [Color(agentSamHex: 0x26300F), Color(agentSamHex: 0x141808)]
        ),
        TeamTemplate(
            id: "reading", name: "Reading Room", emoji: "📚",
            goal: "Read long material thoroughly and summarize it honestly.",
            summary: "Slow and thorough—reads the whole document, disagrees politely, summarizes honestly.",
            capabilities: ["long-form", "polite dissent"],
            example: "Summarize this thesis and flag weak claims.",
            memberNames: ["Ada", "Quill", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x2A2118), Color(agentSamHex: 0x15100B)]
        )
    ]

    static let missionIdeas = [
        "What’s new in AI this week",
        "Plan a 3-day Kyoto trip",
        "Explain the chip shortage simply",
        "7-day meal plan on a budget"
    ]
}
