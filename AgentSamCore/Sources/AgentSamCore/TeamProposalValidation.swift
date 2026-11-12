import Foundation

public enum TeamProposalValidation {
    public static func make(draft: TeamProposalDraft, teams: [Team], providers: [ProviderConfig]) throws -> TeamProposal {
        let base = try draft.baseTeamID.map { id in
            guard let team = teams.first(where: { $0.id == id }) else { throw ConversationError.invalidProposal("The team Ada suggested modifying no longer exists.") }
            return team
        }
        let scope = draft.toolScope ?? .readOnly
        let team = Team(
            id: base?.id ?? UUID(),
            name: draft.name,
            emoji: draft.emoji ?? "✦",
            goal: draft.goal,
            agents: draft.agents,
            toolScope: scope,
            createdAt: base?.createdAt ?? Date(),
            updatedAt: Date()
        )
        let proposal = TeamProposal(baseTeamID: base?.id, team: team, rationale: draft.rationale ?? "A specialist team for this work.", toolScope: scope)
        _ = try validate(proposal, teams: teams, providers: providers)
        return proposal
    }

    public static func validate(_ proposal: TeamProposal, teams: [Team], providers: [ProviderConfig]) throws -> Team {
        var team = proposal.team
        if let baseID = proposal.baseTeamID {
            guard let base = teams.first(where: { $0.id == baseID }) else {
                throw ConversationError.invalidProposal("The team being modified no longer exists.")
            }
            team.id = base.id
            team.createdAt = base.createdAt
        }
        team.name = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
        team.goal = team.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.name.isEmpty, team.name.count <= 80 else {
            throw ConversationError.invalidProposal("The proposed team needs a name of 1 to 80 characters.")
        }
        guard team.goal.count <= 12_000, team.emoji.count <= 8 else {
            throw ConversationError.invalidProposal("The proposed team description is too long.")
        }
        guard !team.agents.isEmpty, team.agents.count <= 16,
              team.agents.filter({ $0.role == .coordinator }).count == 1,
              !team.workers.isEmpty, team.agents.filter({ $0.role == .verifier }).count <= 1 else {
            throw ConversationError.invalidProposal("A team needs one coordinator, at least one worker, and at most one verifier (16 agents maximum).")
        }
        let names = team.agents.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
            throw ConversationError.invalidProposal("Every agent needs a unique name of 1 to 80 characters.")
        }
        let baseAgents = proposal.baseTeamID.flatMap { id in teams.first(where: { $0.id == id }) }?.agents ?? []
        team.agents = try team.agents.map { agent in
            var agent = agent
            agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            agent.title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if agent.role == .coordinator { agent.name = "Ada" }
            guard let existing = baseAgents.first(where: { $0.id == agent.id || $0.name.caseInsensitiveCompare(agent.name) == .orderedSame }) else {
                agent.id = UUID()
                return try validateAgent(agent, providers: providers)
            }
            agent.id = existing.id
            return try validateAgent(agent, providers: providers)
        }
        guard team.agents.filter({ $0.role == .coordinator }).count == 1,
              Set(team.agents.map { $0.name.lowercased() }).count == team.agents.count,
              Set(team.agents.map(\.id)).count == team.agents.count else {
            throw ConversationError.invalidProposal("The coordinator must be named Ada, and agent names and IDs must remain unique.")
        }
        team.toolScope = ToolScope(connectorIDs: Array(Set(proposal.toolScope.connectorIDs)).sorted { $0.rawValue < $1.rawValue }, permissions: proposal.toolScope.permissions)
        team.updatedAt = Date()
        return team
    }

    private static func validateAgent(_ agent: AgentProfile, providers: [ProviderConfig]) throws -> AgentProfile {
        guard !agent.title.isEmpty, agent.title.count <= 160, agent.emoji.count <= 8,
              !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              agent.systemPrompt.count <= 20_000 else {
            throw ConversationError.invalidProposal("Every agent needs an emoji, title, and a system prompt within the allowed length.")
        }
        guard let provider = providers.first(where: { $0.id == agent.providerID }) else {
            throw ConversationError.invalidProposal("The proposed provider \(agent.providerID) is not configured.")
        }
        guard provider.models.contains(agent.model) else {
            throw ConversationError.invalidProposal("The model \(agent.model) is not available from \(provider.name).")
        }
        if let temperature = agent.temperature, !temperature.isFinite || temperature < 0 || temperature > 2 {
            throw ConversationError.invalidProposal("Agent temperatures must be between 0 and 2.")
        }
        return agent
    }
}
