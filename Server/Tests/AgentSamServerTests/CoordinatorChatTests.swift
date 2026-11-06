import XCTest
import Foundation
import AgentSamCore

/// A fake host for the chat: records launches and stops, keeps missions in memory.
private actor FakeMissions: ChatMissionControl {
    let team: Team
    private(set) var launched: [Mission] = []
    private(set) var stopped: [UUID] = []

    init(team: Team) { self.team = team }

    func teams() async -> [Team] { [team] }
    func missions(limit: Int) async -> [Mission] { Array(launched.prefix(limit)) }
    func mission(id: UUID) async -> Mission? { launched.first(where: { $0.id == id }) }
    func isRunning(missionID: UUID) async -> Bool { launched.contains(where: { $0.id == missionID }) && !stopped.contains(missionID) }
    func recentEvents(missionID: UUID, limit: Int) async -> [RunEvent] { [] }
    func deliverable(missionID: UUID, name: String) async -> String? { nil }

    func startMission(team: Team, objective: String, language: String) async throws -> Mission {
        let mission = Mission(teamID: team.id, teamName: team.name, objective: objective)
        launched.append(mission)
        return mission
    }

    func stopMission(id: UUID) async { stopped.append(id) }
}

/// Plays back scripted model replies, one per call.
private actor Script {
    private var replies: [APIMessage]
    private(set) var calls = 0

    init(_ replies: [APIMessage]) { self.replies = replies }

    func next() -> APIMessage {
        calls += 1
        return replies.isEmpty ? .assistant("(no more script)") : replies.removeFirst()
    }
}

private struct StaticKeys: KeyRing {
    func get(_ account: String) -> String? { "test-key" }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) {}
}

final class CoordinatorChatTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-chat-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func toolCall(_ name: String, _ args: String = "{}") -> APIMessage {
        APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: UUID().uuidString, function: .init(name: name, arguments: args))])
    }

    private func makeEngine(_ script: Script, missions: FakeMissions) -> (CoordinatorChatEngine, ChatStore) {
        let store = ChatStore(root: dir)
        let engine = CoordinatorChatEngine(
            store: store,
            missions: missions,
            keyRing: StaticKeys(),
            providers: { ProviderConfig.builtin },
            complete: { _, _, model, _, _, _, _ in
                LLMReply(message: await script.next(), inputTokens: 10, outputTokens: 5, model: model)
            }
        )
        return (engine, store)
    }

    func testMissionNeedsConfirmationInALaterMessage() async throws {
        let team = Team.starterTeam()
        let missions = FakeMissions(team: team)
        let script = Script([
            // Turn 1: the model proposes and immediately tries to confirm. The confirm must be refused.
            toolCall("start_mission", #"{"objective":"Research competitor pricing"}"#),
            toolCall("confirm_pending_action"),
            .assistant("Want me to launch it?"),
            // Turn 2: the person said yes, so the confirm goes through.
            toolCall("confirm_pending_action"),
            .assistant("Launched."),
        ])
        let (engine, store) = makeEngine(script, missions: missions)
        let chat = CoordinatorChat(ownerID: "u1", team: team)
        await store.save(chat)

        let afterFirst = try await engine.send(chatID: chat.id, text: "Can the team research competitor pricing?")
        XCTAssertNotNil(afterFirst?.pendingAction)
        let launchedEarly = await missions.launched
        XCTAssertTrue(launchedEarly.isEmpty, "A mission must not start in the same turn it was proposed")

        let afterSecond = try await engine.send(chatID: chat.id, text: "Yes, go ahead")
        XCTAssertNil(afterSecond?.pendingAction)
        let launched = await missions.launched
        XCTAssertEqual(launched.map(\.objective), ["Research competitor pricing"])
        XCTAssertEqual(afterSecond?.lines.last?.text, "Launched.")
        XCTAssertGreaterThan(afterSecond?.totalInputTokens ?? 0, 0)
    }

    func testCancelButtonDropsThePendingAction() async throws {
        let team = Team.starterTeam()
        let missions = FakeMissions(team: team)
        let script = Script([
            toolCall("start_mission", #"{"objective":"Write a launch plan"}"#),
            .assistant("Shall I start it?"),
        ])
        let (engine, store) = makeEngine(script, missions: missions)
        let chat = CoordinatorChat(ownerID: "u1", team: team)
        await store.save(chat)

        _ = try await engine.send(chatID: chat.id, text: "Plan the launch")
        let resolved = try await engine.resolvePending(chatID: chat.id, approve: false)
        XCTAssertNil(resolved?.pendingAction)
        let launched = await missions.launched
        XCTAssertTrue(launched.isEmpty)
    }

    func testConfirmButtonLaunches() async throws {
        let team = Team.starterTeam()
        let missions = FakeMissions(team: team)
        let script = Script([
            toolCall("start_mission", #"{"objective":"Summarize customer feedback"}"#),
            .assistant("Shall I start it?"),
        ])
        let (engine, store) = makeEngine(script, missions: missions)
        let chat = CoordinatorChat(ownerID: "u1", team: team)
        await store.save(chat)

        _ = try await engine.send(chatID: chat.id, text: "Summarize feedback")
        let resolved = try await engine.resolvePending(chatID: chat.id, approve: true)
        XCTAssertNil(resolved?.pendingAction)
        let launched = await missions.launched
        XCTAssertEqual(launched.count, 1)
        XCTAssertEqual(resolved?.lines.last?.missionID, launched.first?.id)
    }

    func testStoreListsOnlyTheOwnersChatsWithoutTranscripts() async throws {
        let team = Team.starterTeam()
        let store = ChatStore(root: dir)
        var mine = CoordinatorChat(ownerID: "u1", team: team)
        mine.transcript = [.user("hello")]
        await store.save(mine)
        await store.save(CoordinatorChat(ownerID: "u2", team: team))

        let listed = await store.list(ownerID: "u1")
        XCTAssertEqual(listed.map(\.id), [mine.id])
        XCTAssertTrue(listed[0].transcript.isEmpty)
        let reloaded = await store.chat(id: mine.id)
        XCTAssertEqual(reloaded?.transcript.count, 1)
    }
}
