import Vapor
import AgentSamCore
import Foundation

/// The curated team templates, served to the web app. Mirrors AppShared/TeamTemplateCatalog.swift
/// (the native apps keep their own SwiftUI copy, which also carries cover colors as SwiftUI values).
struct ServerTeamTemplate: Codable, Sendable {
    var id: String
    var name: String
    var emoji: String
    var goal: String
    var summary: String
    var capabilities: [String]
    var example: String
    var memberNames: [String]
    var lowCost: Bool
    /// Two hex colors for the card's cover gradient.
    var coverColors: [String]

    /// Builds the team, pointing each agent at a configured provider and a model it offers.
    func makeTeam(providers: [ProviderConfig]) -> Team {
        let agents = memberNames.compactMap { name in
            AgentProfile.rosterTemplates.first(where: { $0.name == name })
        }.map { original -> AgentProfile in
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
}

struct TemplateWithAgents: Codable, Sendable {
    var template: ServerTeamTemplate
    var agents: [AgentProfile]
}

struct TemplateCatalogResponse: Codable, Sendable {
    var templates: [TemplateWithAgents]
    var missionIdeas: [String]
}

enum ServerTemplateCatalog {
    static let all: [ServerTeamTemplate] = [
        ServerTeamTemplate(
            id: "research", name: "Research Crew", emoji: "🔎",
            goal: "Find facts, cite sources, and deliver defensible research briefs.",
            summary: "Finds facts, cites sources, and hands you a clean, defensible brief.",
            capabilities: ["fact-checked", "sources cited"],
            example: "What’s actually new in solid-state batteries this quarter?",
            memberNames: ["Ada", "Scout", "Quill", "Judge"], lowCost: true,
            coverColors: ["#0F2E20", "#0A1B14"]
        ),
        ServerTeamTemplate(
            id: "studio", name: "Content Studio", emoji: "✒️",
            goal: "Brainstorm, draft, design, and polish on-brand content.",
            summary: "A small creative agency—brainstorms, drafts, designs, and ships copy daily.",
            capabilities: ["brand voice", "headline variants"],
            example: "Launch email sequence for our new oat-milk line.",
            memberNames: ["Ada", "Quill", "Iris", "Anchor"], lowCost: false,
            coverColors: ["#2B2210", "#171105"]
        ),
        ServerTeamTemplate(
            id: "datalab", name: "Data Lab", emoji: "📈",
            goal: "Turn tables and data into clear, carefully checked analysis.",
            summary: "Drop in data; walk out with comparisons, flagged outliers, and a plain-English verdict.",
            capabilities: ["table-native", "stat-skeptic"],
            example: "Why did trial conversions dip in March?",
            memberNames: ["Ada", "Plot", "Bolt", "Judge"], lowCost: true,
            coverColors: ["#0D2824", "#081815"]
        ),
        ServerTeamTemplate(
            id: "newsdesk", name: "News Desk", emoji: "🗞️",
            goal: "Scan topics, rank what matters, and write concise briefings.",
            summary: "A morning briefing desk—scans your topics, ranks what matters, writes it tight.",
            capabilities: ["daily digest", "no fluff"],
            example: "Everything worth knowing about the chip market, 8am daily.",
            memberNames: ["Ada", "Scout", "Anchor", "Judge"], lowCost: true,
            coverColors: ["#14290F", "#0C180A"]
        ),
        ServerTeamTemplate(
            id: "foundry", name: "Startup Foundry", emoji: "🚀",
            goal: "Pressure-test ideas with market research and candid analysis.",
            summary: "Pressure-tests ideas—market research, holes poked, one-pager drafted.",
            capabilities: ["candid", "deck-ready"],
            example: "Pressure-test my idea: task-running for elderly care.",
            memberNames: ["Ada", "Scout", "Plot", "Quill"], lowCost: false,
            coverColors: ["#26300F", "#141808"]
        ),
        ServerTeamTemplate(
            id: "reading", name: "Reading Room", emoji: "📚",
            goal: "Read long material thoroughly and summarize it honestly.",
            summary: "Slow and thorough—reads the whole document, disagrees politely, summarizes honestly.",
            capabilities: ["long-form", "polite dissent"],
            example: "Summarize this thesis and flag weak claims.",
            memberNames: ["Ada", "Quill", "Judge"], lowCost: true,
            coverColors: ["#2A2118", "#15100B"]
        ),
    ]

    static let missionIdeas = [
        "What’s new in AI this week",
        "Plan a 3-day Kyoto trip",
        "Explain the chip shortage simply",
        "7-day meal plan on a budget",
    ]
}

func templateRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    api.get("templates") { req async throws -> Response in
        let providers = await ctx.store.loadProviders()
        let templates = ServerTemplateCatalog.all.map {
            TemplateWithAgents(template: $0, agents: $0.makeTeam(providers: providers).agents)
        }
        return try req.json(TemplateCatalogResponse(templates: templates, missionIdeas: ServerTemplateCatalog.missionIdeas))
    }

    /// Creates a new team from a template on the server.
    api.post("templates", ":id", "hire") { req async throws -> Response in
        guard let id = req.parameters.get("id"),
              let template = ServerTemplateCatalog.all.first(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Unknown template")
        }
        let team = template.makeTeam(providers: await ctx.store.loadProviders())
        await ctx.saveTeam(team)
        return try req.json(team, status: .created)
    }
}
