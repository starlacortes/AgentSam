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
    /// Google's Google Ads MCP server, run next to Ada when AGENTSAM_GOOGLE_ADS_MCP is on.
    let googleAdsMCP: GoogleAdsMCPRunner?

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
        let workstation = workstationConfig.enabled ? Workstation(config: workstationConfig, dataDir: store.root) : nil
        // People an admin gave a workstation get an account of their own on the SSH machine.
        let pool = workstationConfig.ssh == nil ? nil : workstation.map { WorkstationPool(operatorMachine: $0, dataDir: store.root) }
        let browserConfig = BrowserConfig.fromEnvironment(workstation: workstationConfig)
        let browserPassword = (Environment.get("AGENTSAM_BROWSER_VNC_PASSWORD") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The agent that drives the browser accepts the same password as its display.
        let browser = browserConfig.enabled ? workstation.map { BrowserLink(config: browserConfig, workstation: $0, token: browserPassword) } : nil
        // People an admin gave a workstation get a browser of their own, running as their own account.
        let browserPool = browserConfig.enabled && pool != nil ? workstation.map { BrowserPool(config: browserConfig, operatorMachine: $0) } : nil
        let access = ConversationAccess(
            root: store.root,
            workstation: workstation,
            workstationOwner: { owner in
                // Ada's machine is the server itself, so only admins (and the shared server token) may use it.
                if owner == "shared-server-token" { return true }
                guard let id = UUID(uuidString: owner), let user = await accounts.user(id: id) else { return false }
                return user.role == .admin && !user.disabled
            },
            sharedAccountsOwner: { owner in
                // Gmail, Ads, GitHub, Cloudflare, Maloon and MCP use one set of server credentials: admins
                // (and the shared server token) always may; a member only when an admin allowed it.
                if owner == "shared-server-token" { return true }
                guard let id = UUID(uuidString: owner), let user = await accounts.user(id: id), !user.disabled else { return false }
                return user.mayUseSharedAccounts
            },
            workstationFor: { owner in
                guard let workstation else { return nil }
                // Admins and the shared server token work as the operator account, as before.
                if owner == "shared-server-token" { return workstation }
                guard let id = UUID(uuidString: owner), let user = await accounts.user(id: id), !user.disabled else { return nil }
                if user.role == .admin { return workstation }
                guard user.mayUseWorkstation, let pool else { return nil }
                switch await pool.machine(ownerID: owner) {
                case .success(let machine): return machine
                case .failure(let problem):
                    print("Workstation for \(owner): \(problem.message)")
                    return nil
                }
            },
            mcp: MCPRegistry(root: store.root, keyRing: keyRing),
            browser: browser,
            browserFor: { owner in
                guard let browser else { return nil }
                if owner == "shared-server-token" { return browser }
                guard let id = UUID(uuidString: owner), let user = await accounts.user(id: id), !user.disabled else { return nil }
                if user.role == .admin { return browser }
                guard user.mayUseWorkstation, let pool, let browserPool, let account = WorkstationPool.unixName(ownerID: owner) else { return nil }
                switch await pool.machine(ownerID: owner) {
                case .failure(let problem):
                    print("Browser for \(owner): \(problem.message)")
                    return nil
                case .success(let machine):
                    switch await browserPool.link(account: account, machine: machine) {
                    case .success(let link): return link
                    case .failure(let problem):
                        print("Browser for \(owner): \(problem.message)")
                        return nil
                    }
                }
            }
        )
        if let problem = workstationConfig.problem { print(problem) }
        if let problem = browserConfig.problem { print(problem) }
        let googleAdsMCPConfig = GoogleAdsMCPConfig.fromEnvironment()
        let googleAdsMCP = googleAdsMCPConfig.enabled ? access.mcp.map { GoogleAdsMCPRunner(config: googleAdsMCPConfig, keyRing: keyRing, oauth: google, registry: $0) } : nil
        if browser != nil { print("Ada's browser is on: admins can open a live window on \(workstationConfig.ssh?.destination ?? "the workstation")\(browserPool == nil ? "" : ", and people with a workstation get a browser of their own").") }
        if let ssh = workstationConfig.ssh, workstationConfig.enabled {
            print("Workstation access is on: Ada can run approved commands on \(ssh.destination) over SSH.")
        } else if workstationConfig.enabled {
            print("Workstation access is on: Ada can run approved commands on this machine (home \(workstationConfig.home.path)).")
        }
        let prompts = PromptStore(
            builtins: PromptStore.builtins,
            fileURL: store.root.appendingPathComponent("prompts.json")
        )
        let conversations = ConversationStore(root: store.root)
        let memory = WorkspaceMemoryStore(root: store.root)
        let skills = SkillStore(root: store.root)
        let knowledge = WorkspaceKnowledgeStore(store: store, conversations: conversations, connectors: connectors, keyRing: keyRing, includeExtendedTools: true, skills: skills,
            machines: WorkspaceMachines(workstation: workstationConfig, browser: browserConfig, browserDrivable: browser?.drivable ?? false, mayUse: access.workstationOwner, permissions: access.permissions,
                personalAccount: { owner in
                    guard workstationConfig.ssh != nil, let id = UUID(uuidString: owner), let user = await accounts.user(id: id),
                          !user.disabled, user.role != .admin, user.mayUseWorkstation else { return nil }
                    return WorkstationPool.unixName(ownerID: owner)
                })
        )
        let chatWorkspace = ChatWorkspaceStore(root: store.root)
        let conversationEngine = ConversationEngine(
            store: store,
            conversations: conversations,
            memory: memory,
            workspace: chatWorkspace,
            keyRing: keyRing,
            connectors: connectors,
            promptStore: prompts,
            access: access,
            knowledge: knowledge,
            skills: skills,
            // The routing call is off by default: Ada answers in one loop and delegates when she needs to.
            // AGENTSAM_ROUTING=1 brings it back for one release, in case a model under-delegates.
            routing: ["1", "true", "on", "yes"].contains((Environment.get("AGENTSAM_ROUTING") ?? "").lowercased())
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
        let scheduler = ConversationScheduler(conversations: conversations, engine: conversationEngine, mayUseGmail: access.sharedAccountsOwner) { [connectors] query, seen in
            guard connectors.isConfigured(.gmail) else { throw ConnectorError("Gmail is not connected.") }
            return try await GmailConnector().recentEmails(query: query, seen: seen, runtime: connectors.runtime)
        }
        let knowledgeScheduler = WorkspaceKnowledgeScheduler(knowledge: knowledge)
        return ServerContext(
            store: store,
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
            browserPassword: browserPassword,
            googleAdsMCP: googleAdsMCP
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
        // Teams are backend-only records of who worked on a mission; nothing is seeded any more.
        // A team saved before skills existed becomes a custom skill (the starter team is covered
        // by the built-in Research skill, so the migration skips it).
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

    /// Starts, restarts or stops the Google Ads MCP server to match the Google Ads connection.
    /// Runs in the background: the server takes a few seconds to answer.
    func syncGoogleAdsMCP() {
        guard let googleAdsMCP else { return }
        Task { await googleAdsMCP.sync() }
    }

    func shutdown() async {
        await googleAdsMCP?.stop()
        await conversationEngine.shutdown()
        await provisioningRunner.shutdown()
        await scheduler.shutdown()
        await knowledgeScheduler.shutdown()
    }

    /// Whether this caller owns the mission. A mission records its owner when it starts. One saved
    /// before that is matched to the chat that links it; one no chat links belongs to admins only.
    func owns(_ mission: Mission, _ principal: Principal) async -> Bool {
        let owner = principal.conversationOwnerID
        if let recorded = mission.ownerID { return recorded == owner }
        if let linked = await conversations.ownerOfMission(mission.id) { return linked == owner }
        return principal.isAdmin
    }

    /// A mission, only for the account that owns it. Anyone else gets nil, as if it did not exist.
    func mission(id: UUID, for principal: Principal) async -> Mission? {
        guard let mission = await store.mission(id: id), await owns(mission, principal) else { return nil }
        return mission
    }

    /// The caller's own missions, newest first.
    func visibleMissions(to principal: Principal, limit: Int) async -> [Mission] {
        var visible: [Mission] = []
        for mission in await store.listMissions(limit: 100_000) {
            guard await owns(mission, principal) else { continue }
            visible.append(mission)
            if visible.count >= limit { break }
        }
        return visible
    }

    func saveTeam(_ team: Team) async {
        var team = team
        team.updatedAt = Date()
        await store.saveTeam(team)
    }

    /// Starts a task from the missions API. It runs on helpers in a conversation of its own, with
    /// the same tools, approvals and budgets as a task Ada starts in chat. A Maloon workflow passes
    /// the business snapshot as a file in that conversation. Older clients (and Run again on an
    /// older team mission) send a team ID: the skill migrated from that team, if any, guides the task.
    func startMission(
        ownerID: String,
        teamID: UUID?,
        objective rawObjective: String?,
        workflowID: String? = nil,
        skillID: String? = nil,
        launchedBy: String? = nil,
        language: String? = nil
    ) async throws -> Mission {
        let lang = (language ?? "en").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("es") ? "es" : "en"
        let launcher = launchedBy ?? "Ada"
        do {
            if workflowID != nil, !(await access.sharedAccountsOwner(ownerID)) {
                throw Abort(.forbidden, reason: "Ask an admin to let you use the shared business accounts.")
            }
            if let workflowID {
                let workflow = try maloon.workflow(id: workflowID, lang: lang)
                let notes = (rawObjective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard notes.count <= 4_000 else {
                    throw Abort(.badRequest, reason: SrvL10n.t("srv.ownerNotesLimit", lang: lang))
                }
                let snapshot = try await maloon.snapshot(lang: lang)
                let objective = workflow.objective + (notes.isEmpty ? "" : "\n\nOwner notes:\n\(notes)")
                return try await conversationEngine.launchTask(
                    ownerID: ownerID, launchedBy: launcher, objective: objective,
                    attachment: (name: "maloon-snapshot.md", content: snapshot),
                    language: lang, sourceName: MaloonIntegration.sourceName, workflowID: workflowID
                )
            }

            let objective = (rawObjective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                throw Abort(.badRequest, reason: SrvL10n.t("srv.objectiveRequired", lang: lang))
            }
            guard objective.count <= 20_000 else {
                throw Abort(.badRequest, reason: SrvL10n.t("srv.objectiveLimit", lang: lang))
            }
            var skill = skillID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if skill?.isEmpty != false { skill = nil }
            if skill == nil, let teamID {
                skill = await skills.enabled(for: ownerID).first(where: { $0.teamID == teamID })?.id
            }
            return try await conversationEngine.launchTask(ownerID: ownerID, launchedBy: launcher, objective: objective, skillID: skill, language: lang)
        } catch let error as ConversationError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
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
