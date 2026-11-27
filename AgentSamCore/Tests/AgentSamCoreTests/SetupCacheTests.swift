import Foundation
import XCTest
@testable import AgentSamCore

/// The work done before a reply's first model call: what is kept between messages, and when it is
/// looked up again.
final class SetupCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-setup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func provider(_ id: String, models: [String] = ["stub"]) -> ProviderConfig {
        ProviderConfig(id: id, name: id.capitalized, kind: .openAICompatible, baseURL: "https://\(id).example/v1", models: models, defaultModel: models.first)
    }

    func testProvidersAreReadAgainOnlyWhenTheFileChanges() async throws {
        let store = MissionStore(root: directory)
        let builtin = await store.loadProviders()
        XCTAssertEqual(builtin, ProviderConfig.builtin, "no file yet")

        await store.saveProviders([provider("one")])
        let first = await store.loadProviders()
        XCTAssertEqual(first.map(\.id), ["one"])
        let again = await store.loadProviders()
        XCTAssertEqual(again, first)

        // A save through the same store shows at once.
        await store.saveProviders([provider("one"), provider("two")])
        let saved = await store.loadProviders()
        XCTAssertEqual(saved.map(\.id), ["one", "two"])

        // So does a change made by something else (another store on the same folder).
        let other = MissionStore(root: directory)
        await other.saveProviders([provider("three", models: ["a", "b", "c"])])
        let changed = await store.loadProviders()
        XCTAssertEqual(changed.map(\.id), ["three"])
        XCTAssertEqual(changed.first?.models, ["a", "b", "c"])

        // And the file going away.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("providers.json"))
        let gone = await store.loadProviders()
        XCTAssertEqual(gone, ProviderConfig.builtin)
    }

    func testFreshKnowledgeIsReusedWithoutLookingAtTheWorkspaceAgain() async throws {
        let store = MissionStore(root: directory)
        let conversations = ConversationStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        let agent = AgentProfile(name: "Scout", emoji: "S", title: "Researcher", role: .worker, systemPrompt: "Look things up.", providerID: "test", model: "stub")
        await store.saveTeam(Team(name: "Research", goal: "Investigate evidence", agents: [agent]))
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
        let knowledge = WorkspaceKnowledgeStore(store: store, conversations: conversations, connectors: hub, keyRing: keys, includeExtendedTools: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Nothing written yet: the first message always looks.
        let first = await knowledge.refresh(ownerID: "owner", now: now, freshFor: 300)
        XCTAssertEqual(first.refreshCount, 1)

        await store.saveTeam(Team(name: "Writing", goal: "Write reports", agents: [agent]))
        // A message 30 seconds later reuses what was written.
        let reused = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(30), freshFor: 300)
        XCTAssertEqual(reused.refreshCount, 1)
        XCTAssertEqual(reused.status, .ready)
        XCTAssertEqual(reused.documents.count, 3)
        XCTAssertFalse(reused.documents.first { $0.id == .capabilities }?.markdown.contains("Writing") == true)

        // Once the window has passed, the change is picked up.
        let later = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(301), freshFor: 300)
        XCTAssertEqual(later.refreshCount, 2)
        XCTAssertTrue(later.documents.first { $0.id == .capabilities }?.markdown.contains("Writing") == true)

        // A look that finds nothing new also starts the window: the next message does not look again.
        let same = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(700), freshFor: 300)
        XCTAssertEqual(same.refreshCount, 2)
        await store.saveTeam(Team(name: "Design", goal: "Draw things", agents: [agent]))
        let stillReused = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(720), freshFor: 300)
        XCTAssertEqual(stillReused.refreshCount, 2)
        XCTAssertFalse(stillReused.documents.first { $0.id == .capabilities }?.markdown.contains("Design") == true)

        // A forced refresh, and one that gives no window, always look.
        let forced = await knowledge.refresh(ownerID: "owner", force: true, now: now.addingTimeInterval(730), freshFor: 300)
        XCTAssertEqual(forced.refreshCount, 3)
        XCTAssertTrue(forced.documents.first { $0.id == .capabilities }?.markdown.contains("Design") == true)
        await store.saveTeam(Team(name: "Sales", goal: "Sell things", agents: [agent]))
        let plain = await knowledge.refresh(ownerID: "owner", now: now.addingTimeInterval(740))
        XCTAssertEqual(plain.refreshCount, 4)
    }
}
