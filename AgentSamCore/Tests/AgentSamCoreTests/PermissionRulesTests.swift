import XCTest
@testable import AgentSamCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PermissionRulesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-permissions-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testToolsWithoutARuleAsk() async {
        let store = PermissionStore(root: directory)
        let decision = await store.decide(ownerID: "owner", toolName: "gmail_send", arguments: [:])
        XCTAssertEqual(decision, .ask(nil))
    }

    func testAllowNeverAndPause() async {
        let store = PermissionStore(root: directory)
        await store.save(ownerID: "owner", policy: PermissionPolicy(rules: [
            "gmail_draft": PermissionRule(mode: .allow),
            "cloudflare_dns_delete": PermissionRule(mode: .never),
        ]))
        guard case .allow = await store.decide(ownerID: "owner", toolName: "gmail_draft", arguments: [:]) else { return XCTFail("draft should be allowed") }
        guard case .deny = await store.decide(ownerID: "owner", toolName: "cloudflare_dns_delete", arguments: [:]) else { return XCTFail("delete should be refused") }
        // Rules are per owner.
        let other = await store.decide(ownerID: "someone-else", toolName: "gmail_draft", arguments: [:])
        XCTAssertEqual(other, .ask(nil))

        var paused = await store.policy(ownerID: "owner")
        paused.paused = true
        await store.save(ownerID: "owner", policy: paused)
        guard case .ask(let why) = await store.decide(ownerID: "owner", toolName: "gmail_draft", arguments: [:]) else { return XCTFail("paused rules should ask") }
        XCTAssertNotNil(why)
        // Pause never loosens a "never" rule.
        guard case .deny = await store.decide(ownerID: "owner", toolName: "cloudflare_dns_delete", arguments: [:]) else { return XCTFail("never must still refuse") }
    }

    func testDailyLimitCountsAutomaticRuns() async {
        let store = PermissionStore(root: directory)
        await store.save(ownerID: "owner", policy: PermissionPolicy(rules: ["github_comment": PermissionRule(mode: .allow, maxPerDay: 2)]))
        for _ in 0..<2 {
            guard case .allow = await store.decide(ownerID: "owner", toolName: "github_comment", arguments: [:]) else { return XCTFail("under the limit") }
        }
        guard case .ask(let why) = await store.decide(ownerID: "owner", toolName: "github_comment", arguments: [:]) else { return XCTFail("over the limit should ask") }
        XCTAssertTrue(why?.contains("daily limit") == true)
        let usage = await store.usageToday(ownerID: "owner")
        XCTAssertEqual(usage["github_comment"], 2)
    }

    func testDailyLimitResetsOnANewDay() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = PermissionStore(root: directory, now: { clock.now })
        await store.save(ownerID: "owner", policy: PermissionPolicy(rules: ["gmail_draft": PermissionRule(mode: .allow, maxPerDay: 1)]))
        guard case .allow = await store.decide(ownerID: "owner", toolName: "gmail_draft", arguments: [:]) else { return XCTFail() }
        guard case .ask = await store.decide(ownerID: "owner", toolName: "gmail_draft", arguments: [:]) else { return XCTFail() }
        clock.now = clock.now.addingTimeInterval(86_400)
        guard case .allow = await store.decide(ownerID: "owner", toolName: "gmail_draft", arguments: [:]) else { return XCTFail("a new day resets the count") }
    }

    func testArgumentLimits() async {
        let store = PermissionStore(root: directory)
        await store.save(ownerID: "owner", policy: PermissionPolicy(rules: [
            "googleads_set_budget": PermissionRule(mode: .allow, maxAmount: 20),
            "github_write_file": PermissionRule(mode: .allow, branchPrefix: "claude/"),
            "gmail_send": PermissionRule(mode: .allow, allowedRecipients: ["Me@Example.com", "@team.test"]),
        ]))
        func decide(_ tool: String, _ args: [String: JSONValue]) async -> Bool {
            if case .allow = await store.decide(ownerID: "owner", toolName: tool, arguments: args) { return true }
            return false
        }
        let small = await decide("googleads_set_budget", ["amount": .number(15)])
        let big = await decide("googleads_set_budget", ["amount": .number(50)])
        let missing = await decide("googleads_set_budget", [:])
        XCTAssertTrue(small)
        XCTAssertFalse(big)
        XCTAssertFalse(missing)
        let own = await decide("github_write_file", ["branch": .string("claude/fix")])
        let main = await decide("github_write_file", ["branch": .string("main")])
        XCTAssertTrue(own)
        XCTAssertFalse(main)
        let me = await decide("gmail_send", ["to": .string("me@example.com")])
        let team = await decide("gmail_send", ["to": .string("a@team.test, b@team.test")])
        let stranger = await decide("gmail_send", ["to": .string("me@example.com, x@else.test")])
        XCTAssertTrue(me)
        XCTAssertTrue(team)
        XCTAssertFalse(stranger)
    }

    func testNormalizingDropsUnknownToolsAndBadLimits() async {
        let store = PermissionStore(root: directory)
        let saved = await store.save(ownerID: "owner", policy: PermissionPolicy(rules: [
            "run_terminal": PermissionRule(mode: .allow),
            "gmail_draft": PermissionRule(mode: .allow, maxPerDay: 0, maxAmount: -1, branchPrefix: "  ", allowedRecipients: [" "]),
        ], approvalMinutes: 7))
        XCTAssertNil(saved.rules["run_terminal"])
        XCTAssertEqual(saved.rules["gmail_draft"], PermissionRule(mode: .allow))
        XCTAssertEqual(saved.approvalMinutes, 15)
        let reloaded = await PermissionStore(root: directory).policy(ownerID: "owner")
        XCTAssertEqual(reloaded, saved)
    }

    func testApprovalLifetimeFollowsThePolicy() async {
        let store = PermissionStore(root: directory)
        await store.save(ownerID: "owner", policy: PermissionPolicy(approvalMinutes: 720))
        let lifetime = await store.approvalLifetime(ownerID: "owner")
        XCTAssertEqual(lifetime, 720 * 60)
        let action = AgentActionRequest(ownerID: "owner", conversationID: UUID(), kind: .connectorWrite, title: "", detail: "", toolName: "gmail_send", arguments: .object([]), lifetime: lifetime)
        XCTAssertEqual(action.expiresAt.timeIntervalSince(action.createdAt), 720 * 60, accuracy: 1)
    }

    func testAllowedWriteRunsWithoutACardAndIsRecorded() async throws {
        let (engine, conversations, access, calls) = try await cloudflareEngine(rule: PermissionRule(mode: .allow))
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Create a DNS record", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(calls.values.count, 1, "the allowed write should reach Cloudflare once")
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        let record = try XCTUnwrap(actions.first)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(record.automatic, true)
        XCTAssertNotEqual(record.status, .pending)
        // It cannot be approved again.
        let resolved = await access.actions.resolve(ownerID: "owner", id: record.id, approve: true)
        XCTAssertNil(resolved)
        await engine.shutdown()
    }

    func testNeverRuleRefusesWithoutACard() async throws {
        let (engine, conversations, access, calls) = try await cloudflareEngine(rule: PermissionRule(mode: .never))
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Create a DNS record", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertTrue(calls.values.isEmpty)
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        XCTAssertTrue(actions.isEmpty)
        await engine.shutdown()
    }

    func testDailySpendingCapStopsNewRepliesBeforeAnyModelCall() async throws {
        let (engine, conversations, access, store, calls) = try await countingEngine()
        _ = store
        await access.permissions.save(ownerID: "owner", policy: PermissionPolicy(dailySpendCapUSD: 1))
        await access.spend.add(ownerID: "owner", usd: 1.5)
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Do some research", launchedBy: "Owner", language: "en")
        let finished = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(calls.values.count, 0, "no model call should run past the daily cap")
        XCTAssertTrue(finished.messages.last?.text.contains("spending limit") == true, finished.messages.last?.text ?? "")
        XCTAssertEqual(finished.messages.last?.status, .complete)
        await engine.shutdown()
    }

    func testReplySpendingCapEndsToolRoundsAndRecordsSpend() async throws {
        let (engine, conversations, access, _, calls) = try await countingEngine()
        await access.permissions.save(ownerID: "owner", policy: PermissionPolicy(replySpendCapUSD: 1))
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Keep listing files", launchedBy: "Owner", language: "en")
        let finished = try await finishedConversation(conversations, id: conversation.id)
        // Routing, one tool round (which crosses the $1 cap), then the final answer without tools.
        XCTAssertEqual(calls.values.filter { $0 == "tools" }.count, 1, calls.values.joined(separator: ","))
        XCTAssertEqual(calls.values.last, "final")
        XCTAssertEqual(finished.messages.last?.status, .complete)
        var spent = 0.0
        for _ in 0..<50 {
            spent = await access.spend.today(ownerID: "owner")
            if spent > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(spent, 1, "the reply's estimated cost is added to today's spend")
        await engine.shutdown()
    }

    // MARK: Helpers

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ date: Date) { value = date }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    private func cloudflareEngine(rule: PermissionRule) async throws -> (ConversationEngine, ConversationStore, ConversationAccess, LockedStrings) {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        try keys.set("test-cloudflare-token", for: CloudflareConnector.tokenAccount)
        await store.saveConnectorConfigs([ConnectorConfig(id: .cloudflare, enabled: true, permissions: ConnectorPermissions(dnsWrite: true))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let hub = ConnectorHub(store: store, keyRing: keys, session: URLSession(configuration: configuration), google: GoogleOAuth(clientID: "", clientSecret: ""), hiddenConnectors: [])
        let calls = LockedStrings()
        CapturingURLProtocol.handler = { request in
            calls.append(contentsOf: [request.url?.absoluteString ?? ""])
            let body = #"{"success":true,"errors":[],"result":{"id":"rec1","type":"TXT","name":"test.example.test","content":"sample"}}"#
            return (HTTPURLResponse(url: try! XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        addTeardownBlock { CapturingURLProtocol.handler = nil }
        let access = ConversationAccess(root: directory)
        await access.permissions.save(ownerID: "owner", policy: PermissionPolicy(rules: ["cloudflare_dns_create": rule]))
        let conversations = ConversationStore(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, connectors: hub, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "write", function: .init(name: "cloudflare_dns_create", arguments: #"{"zone_id":"example.test","type":"TXT","name":"test","content":"sample"}"#))]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        return (engine, conversations, access, calls)
    }

    private func countingEngine() async throws -> (ConversationEngine, ConversationStore, ConversationAccess, MissionStore, LockedStrings) {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let access = ConversationAccess(root: directory)
        let conversations = ConversationStore(root: directory)
        let calls = LockedStrings()
        // A priced model, so each call costs a known amount: 1M input tokens of claude-sonnet-4-5 is $3.
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, access: access, completion: { _, _, _, system, _, tools in
            if system.contains("Decide how to handle") {
                calls.append(contentsOf: ["route"])
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 10, outputTokens: 10, model: "claude-sonnet-4-5")
            }
            if tools == nil {
                calls.append(contentsOf: ["final"])
                return LLMReply(message: .assistant("Here is what I have so far."), inputTokens: 10, outputTokens: 10, model: "claude-sonnet-4-5")
            }
            calls.append(contentsOf: ["tools"])
            return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: UUID().uuidString, function: .init(name: "chat_list_files", arguments: "{}"))]), inputTokens: 1_000_000, outputTokens: 0, model: "claude-sonnet-4-5")
        })
        return (engine, conversations, access, store, calls)
    }

    private func finishedConversation(_ conversations: ConversationStore, id: UUID) async throws -> Conversation {
        for _ in 0..<150 {
            if let conversation = try await conversations.get(id: id, ownerID: "owner"), conversation.messages.last?.status != .running { return conversation }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Conversation did not finish")
        return try await conversations.get(id: id, ownerID: "owner")!
    }
}
