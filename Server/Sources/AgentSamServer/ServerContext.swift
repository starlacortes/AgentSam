import Vapor
import AgentSamCore
import Foundation

struct CompositeKeyRing: KeyRing {
    let fileRing: FileKeyRing

    func get(_ account: String) -> String? {
        if let fromFile = fileRing.get(account) { return fromFile }
        return EnvKeyRing().get(account)
    }

    func set(_ value: String, for account: String) throws {
        try fileRing.set(value, for: account)
    }

    func remove(_ account: String) {
        fileRing.remove(account)
    }
}

struct ServerContext: Sendable {
    let store: MissionStore
    let engine: MissionEngine
    let keyRing: CompositeKeyRing
    let token: String
    let dataDir: URL

    static func make() -> ServerContext {
        let raw = Environment.get("AGENTSAM_DATA") ?? "data"
        let store = MissionStore(root: URL(fileURLWithPath: raw))
        let fileRing = FileKeyRing(url: store.root.appendingPathComponent("keys.json"))
        let keyRing = CompositeKeyRing(fileRing: fileRing)
        let engine = MissionEngine(
            store: store,
            keyRing: keyRing,
            config: MissionEngine.Config(maxParallel: 4, maxSteps: 14, verifyWithAgent: true)
        )

        var token = Environment.get("AGENTSAM_TOKEN") ?? ""
        if token.isEmpty {
            token = UUID().uuidString
            print("=================================================================")
            print(" No AGENTSAM_TOKEN set. Ephemeral token for this run:")
            print("     \(token)")
            print(" Set AGENTSAM_TOKEN to pin a token for the iPhone app.")
            print("=================================================================")
        }
        return ServerContext(
            store: store,
            engine: engine,
            keyRing: keyRing,
            token: token,
            dataDir: store.root
        )
    }

    func seedIfEmpty() async {
        let providersURL = store.root.appendingPathComponent("providers.json")
        if !FileManager.default.fileExists(atPath: providersURL.path) {
            await store.saveProviders(ProviderConfig.builtin)
        }
        if await store.loadTeams().isEmpty {
            await store.saveTeam(Team.starterTeam())
        }
    }

    func saveTeam(_ team: Team) async {
        var team = team
        team.updatedAt = Date()
        await store.saveTeam(team)
    }

    func upsertTeam(input: TeamInput, id: UUID?) async throws -> Team {
        let teamID = id ?? input.id ?? UUID()
        var createdAt = Date()
        if let existing = await store.team(id: teamID) {
            createdAt = existing.createdAt
        }
        let team = Team(
            id: teamID,
            name: input.name,
            emoji: input.emoji ?? "🛡️",
            goal: input.goal ?? "",
            agents: input.agents ?? [],
            createdAt: createdAt,
            updatedAt: Date()
        )
        await saveTeam(team)
        return team
    }

    func startMission(teamID: UUID, objective: String) async throws -> Mission {
        guard let team = await store.team(id: teamID) else {
            throw Abort(.notFound, reason: "Team not found")
        }
        let mission = await store.createMission(team: team, objective: objective)
        await engine.launch(missionID: mission.id, team: team)
        return mission
    }
}
