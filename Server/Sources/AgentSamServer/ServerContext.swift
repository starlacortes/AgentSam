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

enum ServerConfigurationError: LocalizedError {
    case tokenRequired

    var errorDescription: String? {
        "AGENTSAM_TOKEN must be set to a long random token in the production container."
    }
}

struct ServerContext: Sendable {
    let store: MissionStore
    let engine: MissionEngine
    let keyRing: CompositeKeyRing
    let token: String
    let dataDir: URL
    let maloon: MaloonIntegration
    let connectors: ConnectorHub
    let oauthStates: OAuthStateStore

    static func make() throws -> ServerContext {
        let raw = Environment.get("AGENTSAM_DATA") ?? "data"
        let store = MissionStore(root: URL(fileURLWithPath: raw))
        let fileRing = FileKeyRing(url: store.root.appendingPathComponent("keys.json"))
        let keyRing = CompositeKeyRing(fileRing: fileRing)
        let google = GoogleOAuth(
            clientID: Environment.get("AGENTSAM_GOOGLE_CLIENT_ID") ?? "",
            clientSecret: Environment.get("AGENTSAM_GOOGLE_CLIENT_SECRET") ?? ""
        )
        let connectors = ConnectorHub(store: store, keyRing: keyRing, google: google)
        let engine = MissionEngine(
            store: store,
            keyRing: keyRing,
            connectors: connectors,
            config: MissionEngine.Config(maxParallel: 4, maxSteps: 14, verifyWithAgent: true)
        )

        var token = (Environment.get("AGENTSAM_TOKEN") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            if Environment.get("AGENTSAM_REQUIRE_TOKEN") == "1" {
                throw ServerConfigurationError.tokenRequired
            }
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
            dataDir: store.root,
            maloon: MaloonIntegration(),
            connectors: connectors,
            oauthStates: OAuthStateStore()
        )
    }

    func seedIfEmpty() async {
        let providersURL = store.root.appendingPathComponent("providers.json")
        if !FileManager.default.fileExists(atPath: providersURL.path) {
            await store.saveProviders(ProviderConfig.builtin)
        }
        let connectorsURL = store.root.appendingPathComponent("connectors.json")
        if !FileManager.default.fileExists(atPath: connectorsURL.path) {
            await store.saveConnectorConfigs(ConnectorConfig.defaults())
        }
        if await store.loadTeams().isEmpty {
            await store.saveTeam(Team.starterTeam())
        }
    }

    func reconcileInterruptedMissions() async {
        for var mission in await store.listMissions(limit: 100_000) where mission.status == .queued || mission.status == .running {
            mission.status = .stopped
            mission.phase = .done
            mission.finishedAt = Date()
            await store.saveMission(mission)
            let message = SrvL10n.t("srv.interrupted", lang: CoreL10n.language(for: mission))
            await store.appendEvent(mission.id, kind: .error, text: message)
            await store.appendEvent(mission.id, kind: .missionEnd, text: message)
        }
    }

    func shutdown() async {
        for missionID in await engine.activeMissionIDs {
            await engine.stop(missionID: missionID)
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

    func startMission(teamID: UUID?, objective rawObjective: String?, workflowID: String?, language: String? = nil) async throws -> Mission {
        let lang = (language ?? "en").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("es") ? "es" : "en"
        if let workflowID {
            let workflow = try maloon.workflow(id: workflowID, lang: lang)
            let team = try await maloon.ownerTeam(store: store, keyRing: keyRing, lang: lang)
            let notes = (rawObjective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard notes.count <= 4_000 else {
                throw Abort(.badRequest, reason: SrvL10n.t("srv.ownerNotesLimit", lang: lang))
            }
            let snapshot = try await maloon.snapshot(lang: lang)
            let objective = workflow.objective + (notes.isEmpty ? "" : "\n\nOwner notes:\n\(notes)")
            let mission = await store.createMission(
                team: team,
                objective: objective,
                sourceName: MaloonIntegration.sourceName,
                workflowID: workflowID,
                inputContext: snapshot,
                outputLanguage: lang
            )
            await engine.launch(missionID: mission.id, team: team)
            return mission
        }

        let objective = (rawObjective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.objectiveRequired", lang: lang))
        }
        guard objective.count <= 20_000 else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.objectiveLimit", lang: lang))
        }
        guard let teamID, let team = await store.team(id: teamID) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.teamNotFound", lang: lang))
        }
        let mission = await store.createMission(team: team, objective: objective, outputLanguage: lang)
        await engine.launch(missionID: mission.id, team: team)
        return mission
    }
}

/// Short-lived, single-use OAuth state tokens for the Google connector flows.
actor OAuthStateStore {
    struct Entry {
        let connectorID: ConnectorID
        let redirectURI: String
        let clientKind: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    func issue(connectorID: ConnectorID, redirectURI: String, clientKind: String) -> String {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        entries[state] = Entry(
            connectorID: connectorID,
            redirectURI: redirectURI,
            clientKind: clientKind,
            expiresAt: Date().addingTimeInterval(600)
        )
        return state
    }

    func consume(_ state: String) -> Entry? {
        guard let entry = entries[state] else { return nil }
        entries[state] = nil
        guard entry.expiresAt > Date() else { return nil }
        return entry
    }
}
