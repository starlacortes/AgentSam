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
            id: "research", name: String(localized: "Research Crew"), emoji: "🔎",
            goal: String(localized: "Find facts, cite sources, and deliver defensible research briefs."),
            summary: String(localized: "Finds facts, cites sources, and hands you a clean, defensible brief."),
            capabilities: [String(localized: "fact-checked"), String(localized: "sources cited")],
            example: String(localized: "What's actually new in solid-state batteries this quarter?"),
            memberNames: ["Ada", "Scout", "Quill", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x0F2E20), Color(agentSamHex: 0x0A1B14)]
        ),
        TeamTemplate(
            id: "studio", name: String(localized: "Content Studio"), emoji: "✒️",
            goal: String(localized: "Brainstorm, draft, design, and polish on-brand content."),
            summary: String(localized: "A small creative agency—brainstorms, drafts, designs, and ships copy daily."),
            capabilities: [String(localized: "brand voice"), String(localized: "headline variants")],
            example: String(localized: "Launch email sequence for our new oat-milk line."),
            memberNames: ["Ada", "Quill", "Iris", "Anchor"], lowCost: false,
            coverColors: [Color(agentSamHex: 0x2B2210), Color(agentSamHex: 0x171105)]
        ),
        TeamTemplate(
            id: "datalab", name: String(localized: "Data Lab"), emoji: "📈",
            goal: String(localized: "Turn tables and data into clear, carefully checked analysis."),
            summary: String(localized: "Drop in data; walk out with comparisons, flagged outliers, and a plain-English verdict."),
            capabilities: [String(localized: "table-native"), String(localized: "stat-skeptic")],
            example: String(localized: "Why did trial conversions dip in March?"),
            memberNames: ["Ada", "Plot", "Bolt", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x0D2824), Color(agentSamHex: 0x081815)]
        ),
        TeamTemplate(
            id: "newsdesk", name: String(localized: "News Desk"), emoji: "🗞️",
            goal: String(localized: "Scan topics, rank what matters, and write concise briefings."),
            summary: String(localized: "A morning briefing desk—scans your topics, ranks what matters, writes it tight."),
            capabilities: [String(localized: "daily digest"), String(localized: "no fluff")],
            example: String(localized: "Everything worth knowing about the chip market, 8am daily."),
            memberNames: ["Ada", "Scout", "Anchor", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x14290F), Color(agentSamHex: 0x0C180A)]
        ),
        TeamTemplate(
            id: "foundry", name: String(localized: "Startup Foundry"), emoji: "🚀",
            goal: String(localized: "Pressure-test ideas with market research and candid analysis."),
            summary: String(localized: "Pressure-tests ideas—market research, holes poked, one-pager drafted."),
            capabilities: [String(localized: "candid"), String(localized: "deck-ready")],
            example: String(localized: "Pressure-test my idea: task-running for elderly care."),
            memberNames: ["Ada", "Scout", "Plot", "Quill"], lowCost: false,
            coverColors: [Color(agentSamHex: 0x26300F), Color(agentSamHex: 0x141808)]
        ),
        TeamTemplate(
            id: "reading", name: String(localized: "Reading Room"), emoji: "📚",
            goal: String(localized: "Read long material thoroughly and summarize it honestly."),
            summary: String(localized: "Slow and thorough—reads the whole document, disagrees politely, summarizes honestly."),
            capabilities: [String(localized: "long-form"), String(localized: "polite dissent")],
            example: String(localized: "Summarize this thesis and flag weak claims."),
            memberNames: ["Ada", "Quill", "Judge"], lowCost: true,
            coverColors: [Color(agentSamHex: 0x2A2118), Color(agentSamHex: 0x15100B)]
        )
    ]

    static let missionIdeas = [
        String(localized: "What's new in AI this week"),
        String(localized: "Plan a 3-day Kyoto trip"),
        String(localized: "Explain the chip shortage simply"),
        String(localized: "7-day meal plan on a budget")
    ]
}
