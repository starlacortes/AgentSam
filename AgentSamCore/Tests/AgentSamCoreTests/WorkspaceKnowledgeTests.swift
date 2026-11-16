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
