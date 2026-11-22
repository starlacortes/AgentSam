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
    let conversations: ConversationStore
    let memory: WorkspaceMemoryStore
    let knowledge: WorkspaceKnowledgeStore
    let chatWorkspace: ChatWorkspaceStore
    let conversationEngine: ConversationEngine
    let keyRing: CompositeKeyRing
    let prompts: PromptStore
    let token: String
    let dataDir: URL
    let maloon: MaloonIntegration
    let connectors: ConnectorHub
    let access: ConversationAccess
    let oauthStates: OAuthStateStore
    let accounts: AccountStore
    let sessions: SessionStore
    let throttle: LoginThrottle
    let provisioning: ProvisioningStore
    let provisioningRunner: ProvisioningRunner
    let scheduler: ConversationScheduler
    let knowledgeScheduler: WorkspaceKnowledgeScheduler
    /// Ada's skills: built-ins plus custom ones, including teams converted from before skills existed.
    let skills: SkillStore
    /// Compared against when an email isn't found, so failed logins take the same time either way.
    let dummyPasswordHash: String
    /// Phone and browser alerts for approval requests.
    let push: WebPushCenter
    /// Ada's live browser on the SSH workstation, when the server operator turned it on.
    let browser: BrowserLink?
    /// The VNC password of the browser's display, handed only to admins who open the live window.
    let browserPassword: String

    static func make() throws -> ServerContext {
        let raw = Environment.get("AGENTSAM_DATA") ?? "data"
        let store = MissionStore(root: URL(fileURLWithPath: raw))
        let fileRing = FileKeyRing(url: store.root.appendingPathComponent("keys.json"))
        let keyRing = CompositeKeyRing(fileRing: fileRing)
        let google = GoogleOAuth(
            clientID: Environment.get("AGENTSAM_GOOGLE_CLIENT_ID") ?? "",
            clientSecret: Environment.get("AGENTSAM_GOOGLE_CLIENT_SECRET") ?? "",
            rs256Signer: GoogleRS256.sign
        )
        let connectors = ConnectorHub(store: store, keyRing: keyRing, google: google)
        let accounts = AccountStore(dataDir: store.root)
        let workstationConfig = WorkstationConfig.fromEnvironment()
        let access = ConversationAccess(
            root: store.root,
            workstation: workstationConfig.enabled ? Workstation(config: workstationConfig, dataDir: store.root) : nil,
            workstationOwner: { owner in
                // Ada's machine is the server itself, so only admins (and the shared server token) may use it.
                if owner == "shared-server-token" { return true }
                guard let id = UUID(uuidString: owner), let user = await accounts.user(id: id) else { return false }
                return user.role == .admin && !user.disabled
            },
            mcp: MCPRegistry(root: store.root, keyRing: keyRing)
        )
        if let problem = workstationConfig.problem { print(problem) }
        let browserConfig = BrowserConfig.fromEnvironment(workstation: workstationConfig)
        if let problem = browserConfig.problem { print(problem) }
        let browser = browserConfig.enabled ? access.workstation.map { BrowserLink(config: browserConfig, workstation: $0) } : nil
        if browser != nil { print("Ada's browser is on: admins can open a live window on \(workstationConfig.ssh?.destination ?? "the workstation").") }
        if let ssh = workstationConfig.ssh, workstationConfig.enabled {
            print("Workstation access is on: Ada can run approved commands on \(ssh.destination) over SSH.")
        } else if workstationConfig.enabled {
            print("Workstation access is on: Ada can run approved commands on this machine (home \(workstationConfig.home.path)).")
        }
        let prompts = PromptStore(
            builtins: PromptStore.builtins,
            fileURL: store.root.appendingPathComponent("prompts.json")
        )
        let engine = MissionEngine(
            store: store,
            keyRing: keyRing,
            connectors: connectors,
            config: MissionEngine.Config(maxParallel: 4, maxSteps: 24, verifyWithAgent: true),
            promptStore: prompts,
            connectorWrite: { missionID, call, scope in
                guard let owner = await access.actions.owner(missionID: missionID) else {
                    return .failure("This mission is not linked to a user-owned conversation. No external write was performed.")
                }
                switch await access.permissions.decide(ownerID: owner, toolName: call.function.name, arguments: AgentTools.arguments(of: call)) {
                case .deny(let reason):
                    return .failure(reason)
                case .allow:
                    let outcome = await connectors.run(call: call, scope: scope, approved: true)
                    let record = AgentActionRequest(
                        ownerID: owner, conversationID: await access.actions.conversation(missionID: missionID) ?? UUID(), missionID: missionID, kind: .connectorWrite,
                        title: "Ran \(call.function.name) automatically", detail: "A mission worker's write was allowed by your standing permission for this tool.",
                        toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))]), toolScope: scope
                    )
                    await access.actions.recordAutomatic(record, result: outcome.resultText, succeeded: outcome.succeeded)
                    return outcome
                case .ask:
                    break
                }
                let lifetime = await access.permissions.approvalLifetime(ownerID: owner)
                let decision = await access.actions.awaitConnectorApproval(missionID: missionID, call: call, scope: scope, lifetime: lifetime)
                guard decision.hasPrefix("approved:"), let id = UUID(uuidString: String(decision.dropFirst("approved:".count))) else {
                    return .failure(decision)
                }
                let outcome = await connectors.run(call: call, scope: scope, approved: true)
                await access.actions.finish(ownerID: owner, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
                return outcome
            }
        )
        let conversations = ConversationStore(root: store.root)
        let memory = WorkspaceMemoryStore(root: store.root)
        let skills = SkillStore(root: store.root)
        let knowledge = WorkspaceKnowledgeStore(store: store, conversations: conversations, connectors: connectors, keyRing: keyRing, includeExtendedTools: true, skills: skills)
        let chatWorkspace = ChatWorkspaceStore(root: store.root)
        let conversationEngine = ConversationEngine(
            store: store,
            conversations: conversations,
            memory: memory,
            workspace: chatWorkspace,
            keyRing: keyRing,
            connectors: connectors,
            missions: engine,
            promptStore: prompts,
            access: access,
            knowledge: knowledge,
            skills: skills
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
        let provisioning = ProvisioningStore(
            dataDir: store.root,
            secrets: keyRing,
            maxBatchSize: Environment.get("AGENTSAM_PROVISIONING_MAX_BATCH").flatMap(Int.init) ?? 50,
            dailyLimit: Environment.get("AGENTSAM_PROVISIONING_DAILY_LIMIT").flatMap(Int.init) ?? 200
        )
        let provisioningRunner = ProvisioningRunner(store: provisioning, accounts: accounts)
        let scheduler = ConversationScheduler(conversations: conversations, engine: conversationEngine) { [connectors] query, seen in
            guard connectors.isConfigured(.gmail) else { throw ConnectorError("Gmail is not connected.") }
            return try await GmailConnector().recentEmails(query: query, seen: seen, runtime: connectors.runtime)
        }
        let knowledgeScheduler = WorkspaceKnowledgeScheduler(knowledge: knowledge)
        return ServerContext(
            store: store,
            engine: engine,
            conversations: conversations,
            memory: memory,
            knowledge: knowledge,
            chatWorkspace: chatWorkspace,
            conversationEngine: conversationEngine,
            keyRing: keyRing,
            prompts: prompts,
            token: token,
            dataDir: store.root,
            maloon: MaloonIntegration(),
            connectors: connectors,
            access: access,
            oauthStates: OAuthStateStore(),
            accounts: accounts,
            sessions: SessionStore(dataDir: store.root, lifetime: AuthConfig.sessionLifetime),
            throttle: LoginThrottle(),
            provisioning: provisioning,
            provisioningRunner: provisioningRunner,
            scheduler: scheduler,
            knowledgeScheduler: knowledgeScheduler,
            skills: skills,
            dummyPasswordHash: (try? Bcrypt.hash(Secrets.randomToken())) ?? "",
            push: WebPushCenter(dataDir: store.root, contact: Self.pushContact()),
            browser: browser,
            browserPassword: Environment.get("AGENTSAM_BROWSER_VNC_PASSWORD") ?? ""
        )
    }

    /// The VAPID "sub" claim: a contact push services can reach about this server.
    static func pushContact() -> String {
        if let contact = Environment.get("AGENTSAM_PUSH_CONTACT"), !contact.isEmpty { return contact }
        if let url = Environment.get("AGENTSAM_PUBLIC_URL"), url.hasPrefix("https://") { return url }
        return "mailto:ada@example.invalid"
    }

    /// Sends a phone alert to the owner's devices whenever Ada asks for an approval.
    func startPushAlerts() async {
        let push = self.push
        await access.actions.setNotifier { action in
            await push.notify(ownerID: action.ownerID)
        }
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
        // Teams are backend-only now. The starter team is still seeded because the legacy coordinator
        // chat API (/api/chats) runs on a team; it is covered by the built-in Research skill, so the
        // migration below skips it. Any other team saved before skills existed becomes a custom skill.
        if await store.loadTeams().isEmpty {
            await store.saveTeam(Team.starterTeam())
        }
        await skills.migrate(teams: await store.loadTeams(), skipping: [ConversationEngine.soloTeamID])
        prompts.ensureSeedFile()
    }

    func reconcileInterruptedMissions() async {
        try? await conversations.reconcileInterrupted()
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
        await conversationEngine.shutdown()
        await provisioningRunner.shutdown()
        await scheduler.shutdown()
        await knowledgeScheduler.shutdown()
        for missionID in await engine.activeMissionIDs {
            await engine.stop(missionID: missionID)
        }
    }

    func saveTeam(_ team: Team) async {
        var team = team
        team.updatedAt = Date()
        await store.saveTeam(team)
    }

    func upsertTeam(input: TeamInput, id: UUID?, lang: String = "en") async throws -> Team {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw Abort(.badRequest, reason: SrvL10n.t("srv.teamNameLength", lang: lang)) }
        guard (input.agents ?? []).count <= 16 else { throw Abort(.badRequest, reason: SrvL10n.t("srv.teamAgentLimit", lang: lang)) }
        let teamID = id ?? input.id ?? UUID()
        var createdAt = Date()
        if let existing = await store.team(id: teamID) {
            createdAt = existing.createdAt
        }
        let team = Team(
            id: teamID,
            name: name,
            emoji: input.emoji ?? "🛡️",
            goal: input.goal ?? "",
            agents: input.agents ?? [],
            toolScope: id == nil ? .readOnly : await store.team(id: teamID)?.toolScope,
            createdAt: createdAt,
            updatedAt: Date()
        )
        await saveTeam(team)
        return team
    }

    func startMission(
        teamID: UUID?,
        objective rawObjective: String?,
        workflowID: String? = nil,
        launchedBy: String? = nil,
        language: String? = nil
    ) async throws -> Mission {
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
            var mission = await store.createMission(
                team: team,
                objective: objective,
                sourceName: MaloonIntegration.sourceName,
                workflowID: workflowID,
                inputContext: snapshot,
                outputLanguage: lang
            )
            if let launchedBy {
                mission.launchedBy = launchedBy
                await store.saveMission(mission)
            }
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
        var mission = await store.createMission(team: team, objective: objective, outputLanguage: lang)
        if let launchedBy {
            mission.launchedBy = launchedBy
            await store.saveMission(mission)
        }
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
