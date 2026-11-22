import XCTest
@testable import AgentSamCore

final class WorkspaceKnowledgeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-knowledge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstDiscoveryRefreshesChangesAndKeepsOwnersAndSecretsIsolated() async throws {
        let store = MissionStore(root: directory)
        let conversations = ConversationStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        let provider = ProviderConfig(id: "test", name: "Test Provider", kind: .openAICompatible, baseURL: "https://private.example/v1", models: ["stub"], defaultModel: "stub")
        await store.saveProviders([provider])
        try keys.set("never-document-this-key", for: provider.keyAccount)
        let agent = AgentProfile(name: "Scout", emoji: "S", title: "Researcher", role: .worker, systemPrompt: "never-document-this-prompt", providerID: "test", model: "stub")
        await store.saveTeam(Team(name: "Research", goal: "Investigate evidence", agents: [agent]))
        _ = try await conversations.create(ownerID: "owner", projectName: "Launch")
        _ = try await conversations.create(ownerID: "someone-else", projectName: "Other private project")
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
        let knowledge = WorkspaceKnowledgeStore(store: store, conversations: conversations, connectors: hub, keyRing: keys, includeExtendedTools: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let initial = await knowledge.state(ownerID: "owner")
        XCTAssertEqual(initial.status, .pending)
        let first = await knowledge.refresh(ownerID: "owner", now: now)
        XCTAssertEqual(first.status, .ready)
        XCTAssertEqual(first.refreshCount, 1)
        XCTAssertEqual(first.discoveredAt, now)
        XCTAssertEqual(first.documents.map(\.id), WorkspaceKnowledgeDocumentID.allCases)
        let capabilities = try XCTUnwrap(first.documents.first { $0.id == .capabilities }?.markdown)
        XCTAssertTrue(capabilities.contains("Research"))
        XCTAssertTrue(capabilities.contains("Test Provider"))
        XCTAssertTrue(capabilities.contains("project_read_file"))
        XCTAssertFalse(capabilities.contains("never-document-this-key"))
        XCTAssertFalse(capabilities.contains("never-document-this-prompt"))
        XCTAssertFalse(capabilities.contains("private.example"))
        let projects = try XCTUnwrap(first.documents.first { $0.id == .projects }?.markdown)
        XCTAssertTrue(projects.contains("Launch"))
        XCTAssertFalse(projects.contains("Other private project"))
        let connections = try XCTUnwrap(first.documents.first { $0.id == .connections }?.markdown)
        XCTAssertTrue(connections.contains("Gmail"))
        XCTAssertTrue(connections.contains("web_fetch"))
        // Tool descriptions already come with the tool definitions, so the knowledge lists names only.
        for tool in ChatWorkspaceTools.definitions + ExtendedWorkspaceTools.definitions {
            XCTAssertFalse(capabilities.contains(tool.function.description), "\(tool.function.name) is described twice")
        }
        XCTAssertTrue(first.promptSummary.contains("capabilities.md"))

        let unchanged = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(30))
        XCTAssertEqual(unchanged.refreshCount, 1)
        await store.saveTeam(Team(name: "Writing", goal: "Write reports", agents: [agent]))
        let scheduler = WorkspaceKnowledgeScheduler(knowledge: knowledge)
        await scheduler.tick(now: now.addingTimeInterval(60))
        let changed = await knowledge.state(ownerID: "owner")
        XCTAssertEqual(changed.refreshCount, 2)
        XCTAssertTrue(changed.documents.first { $0.id == .capabilities }?.markdown.contains("Writing") == true)

        let reloaded = WorkspaceKnowledgeStore(store: store, conversations: conversations, connectors: hub, keyRing: keys, includeExtendedTools: true)
        let persisted = await reloaded.state(ownerID: "owner")
        XCTAssertEqual(persisted.refreshCount, 2)
        XCTAssertEqual(persisted.documents.count, 3)
        let daily = await reloaded.refresh(ownerID: "owner", now: now.addingTimeInterval(90_000))
        XCTAssertEqual(daily.refreshCount, 3)
    }

    private func capabilities(_ knowledge: WorkspaceKnowledgeStore, owner: String) async throws -> String {
        let state = await knowledge.refresh(ownerID: owner, force: true)
        return try XCTUnwrap(state.documents.first { $0.id == .capabilities }?.markdown)
    }

    private func knowledgeStore(machines: WorkspaceMachines?) -> WorkspaceKnowledgeStore {
        let store = MissionStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
        return WorkspaceKnowledgeStore(store: store, conversations: ConversationStore(root: directory), connectors: hub, keyRing: keys, includeExtendedTools: true, machines: machines)
    }

    func testCapabilitiesSayWorkstationAndBrowserAreOffWhenTheServerHasNone() async throws {
        let machines = WorkspaceMachines(workstation: WorkstationConfig(enabled: false, home: directory), browser: BrowserConfig(enabled: false), mayUse: { _ in true })
        let text = try await capabilities(knowledgeStore(machines: machines), owner: "admin")
        XCTAssertTrue(text.contains("## Workstation\n- Off on this server."))
        XCTAssertTrue(text.contains("## Browser\n- Off on this server."))
        XCTAssertFalse(text.contains("workstation_status"))
    }

    func testCapabilitiesDescribeTheSSHWorkstationAndLiveBrowserForAdmins() async throws {
        let ssh = SSHTarget(destination: "ada@kokofast.example", port: 2222, hostKey: "ssh-ed25519 AAAAnever-document-this-host-key")
        let workstation = WorkstationConfig(enabled: true, home: directory, ssh: ssh)
        let env = ["AGENTSAM_BROWSER": "1", "AGENTSAM_BROWSER_VNC_PASSWORD": "never-document-this-password"]
        let browser = BrowserConfig.fromEnvironment(env, workstation: workstation)
        XCTAssertTrue(browser.enabled)
        let permissions = PermissionStore(root: directory)
        _ = await permissions.save(ownerID: "admin", policy: PermissionPolicy(rules: [
            "workstation_run": PermissionRule(mode: .allow, commandPrefixes: ["pacman -Q", "systemctl status"]),
        ]))
        let machines = WorkspaceMachines(workstation: workstation, browser: browser, mayUse: { $0 == "admin" }, permissions: permissions)
        let knowledge = knowledgeStore(machines: machines)

        let text = try await capabilities(knowledge, owner: "admin")
        XCTAssertTrue(text.contains("`ada@kokofast.example` (port 2222), reached over SSH"))
        XCTAssertTrue(text.contains("create files, run programs and publish to git"))
        XCTAssertTrue(text.contains("cat ~/GIT.md"))
        XCTAssertTrue(text.contains("open a pull request"))
        XCTAssertTrue(text.contains("Missions have it too"))
        XCTAssertFalse(text.lowercased().contains("deploy key"), "her git access is a GitHub App now, not a deploy key")
        for tool in WorkstationTools.names { XCTAssertTrue(text.contains("`\(tool)`"), tool) }
        XCTAssertTrue(text.contains("`workstation_run`: runs without a card only for single commands starting with `pacman -Q`, `systemctl status`"))
        XCTAssertTrue(text.contains("`workstation_start_job`: asks every time"))
        XCTAssertTrue(text.contains("## Browser\n- On: a real Chromium window"))
        XCTAssertTrue(text.contains("`ada-browser.service`"))
        XCTAssertTrue(text.contains("Open Ada’s browser"))
        XCTAssertTrue(text.contains("stops after 15 minutes"))
        XCTAssertTrue(text.contains("Ada cannot drive it yet"))
        XCTAssertFalse(text.contains("never-document-this"))
        // The prompt cuts each document; the machines must survive the cut.
        let summary = await knowledge.state(ownerID: "admin").promptSummary
        XCTAssertTrue(summary.contains("Ada cannot drive it yet"))

        let member = try await capabilities(knowledge, owner: "member")
        XCTAssertTrue(member.contains("only admins can use them"))
        XCTAssertFalse(member.contains("kokofast"))
        XCTAssertFalse(member.contains("workstation_run"))
    }

    func testCapabilitiesSayWhyTheBrowserIsOffOnAnSSHWorkstation() async throws {
        let workstation = WorkstationConfig(enabled: true, home: directory, ssh: SSHTarget(destination: "ada@kokofast.example"))
        let machines = WorkspaceMachines(workstation: workstation, browser: BrowserConfig(enabled: false), mayUse: { _ in true })
        let text = try await capabilities(knowledgeStore(machines: machines), owner: "admin")
        XCTAssertTrue(text.contains("`ada@kokofast.example`, reached over SSH"))
        XCTAssertTrue(text.contains("`workstation_run`: asks every time"))
        XCTAssertTrue(text.contains("Off on this server (AGENTSAM_BROWSER is not set)"))
    }

    func testPromptContextCarriesKnowledgeIntoMissionHandoff() {
        let context = ConversationPromptContext(
            projectName: "Launch",
            history: [],
            memory: "Preferences",
            workspaceManifest: "",
            missionReferences: "",
            missionIDs: [],
            schedule: nil,
            scheduled: false,
            knowledge: "Document capabilities.md:\n- web_fetch"
        )
        XCTAssertTrue(context.promptBlock.contains("capabilities.md"))
        XCTAssertTrue(context.promptBlock.contains("web_fetch"))
        XCTAssertTrue(context.missionHandoff.contains("Maintained workspace knowledge"))
    }
}
