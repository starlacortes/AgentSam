import XCTest
@testable import AgentSamCore

final class SelfReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-self-review-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    func testCorrectionMarkers() {
        XCTAssertTrue(SelfReviewTools.looksLikeCorrection("No, I meant the Austin office"))
        XCTAssertTrue(SelfReviewTools.looksLikeCorrection("That's wrong, use the other template"))
        XCTAssertTrue(SelfReviewTools.looksLikeCorrection("eso no, te dije el martes"))
        XCTAssertFalse(SelfReviewTools.looksLikeCorrection("Nothing else, thanks"))
        XCTAssertFalse(SelfReviewTools.looksLikeCorrection("Notes look great"))
        XCTAssertFalse(SelfReviewTools.looksLikeCorrection(""))
    }

    func testReportCountsFailuresCorrectionsApprovalsAndMissions() {
        let now = Date()
        let recent = now.addingTimeInterval(-3_600)
        let old = now.addingTimeInterval(-5 * 86_400)
        let messages = [
            ConversationMessage(role: .user, text: "Find the invoice from Acme", createdAt: recent),
            ConversationMessage(role: .assistant, text: "Here it is.", createdAt: recent, toolLog: [
                #"gmail_search {"q":"acme"} → failed: Gmail is not connected"#,
                #"chat_read_file {"path":"a.md"} → ok"#,
            ]),
            ConversationMessage(role: .user, text: "No, I meant the March one", createdAt: recent),
            ConversationMessage(role: .assistant, text: "I used all the tool steps for this reply before finishing.", createdAt: recent),
            ConversationMessage(role: .user, text: "Try again", createdAt: recent, scheduled: true),
            ConversationMessage(role: .assistant, text: "", createdAt: recent, status: .failed),
            ConversationMessage(role: .user, text: "No, that's old", createdAt: old),
            ConversationMessage(role: .assistant, text: "Old reply", createdAt: old, toolLog: [#"web_fetch {} → failed: timeout"#]),
        ]
        let conversation = Conversation(ownerID: "owner", title: "Invoices", messages: messages)
        var denied = AgentActionRequest(ownerID: "owner", conversationID: conversation.id, kind: .connectorWrite, title: "Approve", detail: "", toolName: "gmail_send", arguments: .object([]))
        denied.status = .denied
        var auto = AgentActionRequest(ownerID: "owner", conversationID: conversation.id, kind: .connectorWrite, title: "Approve", detail: "", toolName: "gmail_draft", arguments: .object([]))
        auto.status = .failed
        auto.automatic = true

        let text = SelfReviewTools.report(.init(conversations: [conversation], actions: [denied, auto], missions: [], spendTodayUSD: 0.42), days: 1, since: now.addingTimeInterval(-86_400), now: now)
        XCTAssertTrue(text.contains("3 replies in 1 chat; 1 failed; 1 ran out of tool steps; 1 failed tool call; 1 possible correction"), text)
        XCTAssertTrue(text.contains("0 approved, 1 denied, 0 expired, 0 failed"), text)
        XCTAssertTrue(text.contains("gmail_search failed 1×"), text)
        XCTAssertTrue(text.contains("\"No, I meant the March one\""), text)
        XCTAssertTrue(text.contains("gmail_send denied, chat \"Invoices\""), text)
        XCTAssertTrue(text.contains("$0.42"), text)
        XCTAssertFalse(text.contains("web_fetch"), "older than the window")
        XCTAssertFalse(text.contains("before finishing.\", the user wrote \"Try again\""), "scheduled messages are not corrections")
        XCTAssertTrue(text.contains("reply failed after the user wrote \"Try again\""), text)
    }

    func testEmptyPeriodSaysSo() {
        let text = SelfReviewTools.report(.init(conversations: []), days: 3, since: Date().addingTimeInterval(-3 * 86_400))
        XCTAssertTrue(text.contains("last 3 days"), text)
        XCTAssertTrue(text.contains("Nothing to review in this period."), text)
    }

    func testDaysAreClamped() {
        func call(_ args: String) -> APIToolCall { APIToolCall(id: "c", function: .init(name: "self_review_recent", arguments: args)) }
        XCTAssertEqual(SelfReviewTools.days(from: call("{}")), 1)
        XCTAssertEqual(SelfReviewTools.days(from: call(#"{"days":7}"#)), 7)
        XCTAssertEqual(SelfReviewTools.days(from: call(#"{"days":90}"#)), SelfReviewTools.maxDays)
        XCTAssertEqual(SelfReviewTools.days(from: call(#"{"days":0}"#)), 1)
    }

    func testToolIsOfferedAsReadOnly() {
        let offered = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false)
        XCTAssertEqual(offered.family(of: "self_review_recent"), .selfReview)
        XCTAssertEqual(ToolCatalog.spec("self_review_recent")?.access, .read)
    }

    func testReviewReplyCannotSaveMemoryOrSkills() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let results = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, completion: { _, _, _, system, messages, tools in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            guard tools != nil else { return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.last?.role == "user" {
                return LLMReply(message: APIMessage(role: "assistant", tool_calls: [
                    APIToolCall(id: "r", function: .init(name: "self_review_recent", arguments: #"{"days":1}"#)),
                    APIToolCall(id: "m", function: .init(name: "memory_remember", arguments: #"{"fact":"Always use the March invoice"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            results.append(contentsOf: messages.filter { $0.role == "tool" }.compactMap(\.content))
            return LLMReply(message: .assistant("1. Remember to check the month."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Review yourself", launchedBy: "Owner", language: "en")
        for _ in 0..<150 {
            if let current = try await conversations.get(id: conversation.id, ownerID: "owner"), current.messages.last?.status != .running { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let tools = results.values
        XCTAssertTrue(tools.contains { $0.hasPrefix("Self-review data for the last 1 day") }, tools.joined(separator: "\n---\n"))
        XCTAssertTrue(tools.contains { $0.contains(SelfReviewTools.applyLaterMessage) }, tools.joined(separator: "\n---\n"))
        let state = await memory.state(ownerID: "owner")
        XCTAssertTrue(state.pinned.isEmpty, "a self-review reply saved a memory")
        await engine.shutdown()
    }
}
