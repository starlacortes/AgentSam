import XCTest
@testable import AgentSamCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ConversationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-conversation-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    private func agent(_ name: String, role: AgentProfile.Role) -> AgentProfile {
        AgentProfile(name: name, emoji: "•", title: "Specialist", role: role, systemPrompt: "Do careful, focused work.", providerID: "test", model: "stub")
    }

    private func team(_ name: String) -> Team {
        Team(name: name, goal: "Research and write", agents: [agent("Ada", role: .coordinator), agent("Scout", role: .worker), agent("Judge", role: .verifier)])
    }

    private func engine(_ store: MissionStore, _ conversations: ConversationStore, _ memory: WorkspaceMemoryStore, keys: FileKeyRing, routing: Bool = true, completion: @escaping ConversationEngine.Completion) -> ConversationEngine {
        return ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, routing: routing, completion: completion)
    }

    private func finishedConversation(_ conversations: ConversationStore, id: UUID, owner: String = "owner") async throws -> Conversation {
        for _ in 0..<150 {
            if let conversation = try await conversations.get(id: id, ownerID: owner), conversation.messages.last?.status != .running { return conversation }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Conversation did not finish")
        return try await conversations.get(id: id, ownerID: owner)!
    }

    func testDirectConnectorWriteRequestsApprovalWithoutCallingProvider() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        try keys.set("test-cloudflare-token", for: CloudflareConnector.tokenAccount)
        await store.saveConnectorConfigs([ConnectorConfig(id: .cloudflare, enabled: true, permissions: ConnectorPermissions(dnsWrite: true))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let hub = ConnectorHub(store: store, keyRing: keys, session: URLSession(configuration: configuration), google: GoogleOAuth(clientID: "", clientSecret: ""), hiddenConnectors: [])
        CapturingURLProtocol.handler = { request in
            XCTFail("An external connector ran before approval: \(request.url?.absoluteString ?? "")")
            return (HTTPURLResponse(url: try! XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        defer { CapturingURLProtocol.handler = nil }
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, connectors: hub, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "write", function: .init(name: "cloudflare_dns_create", arguments: #"{"zone_id":"example.test","type":"TXT","name":"test","content":"sample"}"#))]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            XCTAssertTrue(messages.contains(where: { $0.role == "tool" && ($0.content ?? "").contains("Approval requested") }))
            return LLMReply(message: .assistant("Approval is required; no external change was made."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Create a DNS record", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.kind, .connectorWrite)
        XCTAssertTrue(action.arguments.objectValue?["raw"]?.stringValue?.contains("example.test") == true)
        let denied = await access.actions.resolve(ownerID: "owner", id: action.id, approve: false)
        let consumed = await access.actions.consumeApproved(ownerID: "owner", id: action.id)
        XCTAssertEqual(denied?.status, .denied)
        XCTAssertNil(consumed)
        await engine.shutdown()
    }

    func testUnknownToolNamesFailWithoutCreatingApprovalCards() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let toolResults = LockedStrings()
        let flagged = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, connectors: hub, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "made-up", function: .init(name: "web_browse", arguments: #"{"url":"https://example.test"}"#)),
                    APIToolCall(id: "mission", function: .init(name: "mission_read_file", arguments: #"{"mission_id":"x","path":"a.md"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            toolResults.append(contentsOf: messages.filter { $0.role == "tool" }.compactMap(\.content))
            flagged.append(contentsOf: messages.filter { $0.role == "tool" && $0.is_error == true }.compactMap(\.tool_call_id))
            return LLMReply(message: .assistant("That tool is not available."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Browse example.test", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        XCTAssertTrue(actions.isEmpty, "A made-up tool created an approval card: \(actions.map(\.toolName))")
        let results = toolResults.values
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.hasPrefix("Unknown tool:") }, results.joined(separator: "\n"))
        XCTAssertTrue(results[0].contains("web_browse"))
        // The model is told these calls failed, not just given text.
        XCTAssertEqual(flagged.values, ["made-up", "mission"])
        await engine.shutdown()
    }

    func testToolResultsWarnWhenRoundsRunLow() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let toolTexts = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, completion: { _, _, _, system, messages, tools in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            guard tools != nil else { return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if let last = messages.last, last.role == "tool" { toolTexts.append(contentsOf: [last.content ?? ""]) }
            let round = messages.filter { $0.role == "tool" }.count
            return LLMReply(message: APIMessage(role: "assistant", tool_calls: [APIToolCall(id: "r\(round)", function: .init(name: "chat_list_files", arguments: "{}"))]), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Keep listing", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        let texts = toolTexts.values
        XCTAssertEqual(texts.filter { $0.contains("tool round") }.count, 2, texts.joined(separator: "\n---\n"))
        XCTAssertTrue(texts.contains { $0.hasSuffix("[2 tool rounds left in this reply; finish or say what is still missing.]") })
        XCTAssertTrue(texts.contains { $0.hasSuffix("[1 tool round left in this reply; finish or say what is still missing.]") })
        await engine.shutdown()
    }

    func testMissingSandboxPointsAdaAtTheWorkstation() {
        let refusal = ToolOutcome.failure("No program was run: running programs needs the OS sandbox (bubblewrap on Linux, sandbox-exec on macOS), and it is not available on this server (bwrap: Creating new namespace failed: Permission denied). Tell the user; do not try to work around it.")
        let withWorkstation = ConversationEngine.workstationFallback(toolName: "run_program", outcome: refusal, hasWorkstation: true)
        XCTAssertFalse(withWorkstation.succeeded)
        XCTAssertTrue(withWorkstation.resultText.contains("workstation_run"))
        XCTAssertTrue(withWorkstation.resultText.contains("git"))
        XCTAssertFalse(withWorkstation.resultText.contains("do not try to work around it"))
        XCTAssertTrue(withWorkstation.resultText.contains("Permission denied"))
        // Without a workstation, or for other failures, nothing changes.
        XCTAssertEqual(ConversationEngine.workstationFallback(toolName: "run_program", outcome: refusal, hasWorkstation: false).resultText, refusal.resultText)
        let other = ToolOutcome.failure("Unsupported language: ruby.")
        XCTAssertEqual(ConversationEngine.workstationFallback(toolName: "run_program", outcome: other, hasWorkstation: true).resultText, other.resultText)
        XCTAssertEqual(ConversationEngine.workstationFallback(toolName: "chat_read_file", outcome: refusal, hasWorkstation: true).resultText, refusal.resultText)
    }

    func testLongListsAndOutputSayWhatWasLeftOut() {
        let list = (1...100).map { "file\($0).md — 10" }.joined(separator: "\n")
        let clipped = ConversationPromptContext.clipList(list, limit: 200)
        XCTAssertTrue(clipped.hasSuffix("more entries not shown; use the list tool to see them all]"), clipped)
        XCTAssertFalse(clipped.contains("file100"))
        let shown = clipped.components(separatedBy: "\n").count - 1
        XCTAssertTrue(clipped.contains("[\(100 - shown) more entries"), clipped)
        XCTAssertEqual(ConversationPromptContext.clipList("a\nb", limit: 200), "a\nb")

        let output = (1...2_000).map { "line \($0)" }.joined(separator: "\n") + "\nTraceback: boom"
        let kept = CodeRunner.headAndTail(output, limit: 3_000)
        XCTAssertTrue(kept.hasPrefix("line 1\n"))
        XCTAssertTrue(kept.hasSuffix("Traceback: boom"), "The end of the output, where errors are, must survive")
        XCTAssertTrue(kept.contains("omitted from the middle of the output"))
        XCTAssertLessThan(kept.count, 3_200)
    }

    func testOfferedToolsDecideFamiliesAndAvailability() {
        let connector = APIToolDef(name: "gmail_search", description: "", parameters: .object([]))
        let full = OfferedTools.direct(connectorTools: [connector], hasLinkedMissions: true, hasExtendedAccess: true)
        XCTAssertEqual(full.family(of: "gmail_search"), .connector)
        XCTAssertEqual(full.family(of: "chat_read_file"), .chat)
        XCTAssertEqual(full.family(of: "run_program"), .chat)
        XCTAssertEqual(full.family(of: "chat_patch_file"), .extended)
        XCTAssertEqual(full.family(of: "host_read_file"), .extended)
        XCTAssertEqual(full.family(of: "mission_read_file"), .mission)
        XCTAssertEqual(full.family(of: "skill_save"), .skill)
        XCTAssertNil(full.family(of: "web_browse"))
        XCTAssertEqual(full.definitions.count, full.names.count, "Each tool is offered once")

        let basic = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false)
        XCTAssertNil(basic.family(of: "project_write_file"), "Extended tools need workspace access")
        XCTAssertNil(basic.family(of: "mission_read_file"), "Mission tools need a linked mission")
        XCTAssertEqual(basic.family(of: "chat_write_file"), .chat)
    }

    func testToolLogIsKeptWithTheReplyAndSentWithLaterTurns() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let histories = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, completion: { _, _, _, system, messages, tools in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            guard tools != nil else { return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub") }
            histories.append(contentsOf: [messages.compactMap(\.content).joined(separator: "\n")])
            if messages.last?.role == "user", messages.last?.content?.contains("Save a note") == true {
                return LLMReply(message: APIMessage(role: "assistant", tool_calls: [
                    APIToolCall(id: "w", function: .init(name: "chat_write_file", arguments: #"{"path":"note.md","content":"hi"}"#)),
                    APIToolCall(id: "r", function: .init(name: "chat_read_file", arguments: #"{"path":"missing.md"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Saved."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Save a note", launchedBy: "Owner", language: "en")
        let first = try await finishedConversation(conversations, id: conversation.id)
        let reply = try XCTUnwrap(first.messages.last)
        XCTAssertEqual(reply.toolLog.count, 2, reply.toolLog.joined(separator: "\n"))
        XCTAssertTrue(reply.toolLog[0].hasPrefix(#"chat_write_file {"path":"note.md","content":"hi"} → ok"#), reply.toolLog[0])
        XCTAssertTrue(reply.toolLog[1].hasPrefix("chat_read_file") && reply.toolLog[1].contains("→ failed: "), reply.toolLog[1])

        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "What did you do?", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        let later = try XCTUnwrap(histories.values.last)
        XCTAssertTrue(later.contains("[Tools used in this reply: chat_write_file"), later)
        await engine.shutdown()
    }

    func testUnknownToolMessageSuggestsClosestTools() {
        let message = ConversationEngine.unknownToolMessage("chat_read", offered: ["chat_read_file", "chat_write_file", "run_program"])
        XCTAssertTrue(message.contains("Closest available: chat_read_file, chat_write_file."), message)
        XCTAssertFalse(message.contains("run_program"), message)
        let none = ConversationEngine.unknownToolMessage("teleport", offered: ["run_program"])
        XCTAssertFalse(none.contains("Closest"), none)
    }

    func testContextListsRecentApprovalOutcomes() throws {
        let now = Date()
        func action(_ tool: String, _ status: AgentActionRequest.Status, result: String? = nil, age: TimeInterval = 60) -> AgentActionRequest {
            var action = AgentActionRequest(ownerID: "owner", conversationID: UUID(), kind: .connectorWrite, title: "Approve", detail: "", toolName: tool, arguments: .object([("raw", .string(#"{"to":"a@example.test"}"#))]))
            action.status = status
            action.result = result
            action.createdAt = now.addingTimeInterval(-age)
            return action
        }
        let approvals = [
            action("gmail_send", .completed, result: "Sent message 123."),
            action("cloudflare_dns_create", .denied),
            action("github_create_issue", .expired),
            action("old_write", .completed, age: 2 * 24 * 3600),
        ]
        let context = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false, now: now, approvals: approvals)
        let data = context.workspaceData
        XCTAssertTrue(data.contains("gmail_send"), data)
        XCTAssertTrue(data.contains("approved and done; result: Sent message 123."), data)
        XCTAssertTrue(data.contains("cloudflare_dns_create"), data)
        XCTAssertTrue(data.contains("denied by the person; nothing was done"), data)
        XCTAssertTrue(data.contains("expired without a decision"), data)
        XCTAssertFalse(data.contains("old_write"), "Approvals older than a day are left out")

        let none = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        XCTAssertTrue(none.workspaceData.contains("Approval requests from this conversation (last 24 hours, newest first):\nNone."), none.workspaceData)
    }

    func testDecidedApprovalReachesTheNextTurn() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let turns = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            turns.append(contentsOf: [messages.last(where: { $0.role == "user" })?.content ?? ""])
            return LLMReply(message: .assistant("Noted."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        let request = AgentActionRequest(ownerID: "owner", conversationID: conversation.id, kind: .fileDelete, title: "Delete?", detail: "", toolName: "chat_delete_file", arguments: .object([("path", .string("old.md"))]))
        let saved = await access.actions.request(request)
        _ = await access.actions.resolve(ownerID: "owner", id: saved.id, approve: false)

        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Did the delete happen?", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        // Other calls (such as memory compaction) also pass through the stub; pick the chat turn.
        let turn = try XCTUnwrap(turns.values.first { $0.contains("<workspace_data>") }, turns.values.joined(separator: "\n---\n"))
        XCTAssertTrue(turn.contains(#"chat_delete_file {"path":"old.md"}"#), turn)
        XCTAssertTrue(turn.contains("denied by the person"), turn)
        await engine.shutdown()
    }

    func testContextGivesCurrentTimeInThePersonsTimeZone() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T13:10:00Z"))
        let schedule = ConversationSchedule(prompt: "Refresh", intervalMinutes: 60, nextRunAt: now.addingTimeInterval(3_600))
        let local = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: schedule, scheduled: false, now: now, timeZoneID: "America/Los_Angeles", personName: "star")
        XCTAssertTrue(local.promptBlock.contains("Current time for the person: Thursday, 19 November 2026, 05:10 (America/Los_Angeles, UTC-08:00); 2026-11-19T13:10:00Z in UTC."), local.promptBlock)
        XCTAssertTrue(local.promptBlock.contains("Person: star"), local.promptBlock)
        XCTAssertTrue(local.promptBlock.contains("next run Thursday, 19 November 2026, 06:10 (America/Los_Angeles"), local.promptBlock)

        let unknown = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: true, now: now)
        XCTAssertTrue(unknown.promptBlock.contains("13:10 (UTC, UTC+00:00). The person's time zone is unknown"), unknown.promptBlock)
        XCTAssertTrue(unknown.promptBlock.contains("Person: not given"), unknown.promptBlock)
    }

    func testTimeZoneIsStoredOnlyWhenValid() async throws {
        let conversations = ConversationStore(root: directory)
        let conversation = try await conversations.create(ownerID: "owner")
        let invalid = try await conversations.setTimeZone(id: conversation.id, ownerID: "owner", timeZone: "Mars/Olympus_Mons")
        XCTAssertNil(invalid)
        _ = try await conversations.setTimeZone(id: conversation.id, ownerID: "owner", timeZone: "Europe/Madrid")
        let stored = try await conversations.get(id: conversation.id, ownerID: "owner")
        XCTAssertEqual(stored?.timeZone, "Europe/Madrid")
    }

    func testScheduleToolReportsFirstRunInLocalTime() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let outcome = await ChatWorkspaceTools.run(
            call: APIToolCall(id: "s", function: .init(name: "chat_schedule_run", arguments: #"{"prompt":"Refresh","intervalMinutes":60}"#)),
            workspace: workspace,
            conversationID: UUID(),
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        ) { $0 }
        XCTAssertTrue(outcome.resultText.contains("hourly. The first run is at"), outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("(Asia/Tokyo, UTC+09:00)"), outcome.resultText)
    }

    func testScheduleIntervalSchemaUsesIntegerEnum() throws {
        let tool = try XCTUnwrap(ChatWorkspaceTools.definitions.first { $0.function.name == "chat_schedule_run" })
        let interval = tool.function.parameters.objectValue?["properties"]?.objectValue?["intervalMinutes"]?.objectValue
        XCTAssertEqual(interval?["type"]?.stringValue, "integer")
        guard case .array(let values)? = interval?["enum"] else { return XCTFail("intervalMinutes has no enum") }
        XCTAssertEqual(values.compactMap(\.numberValue), [15, 30, 60, 360, 720, 1440])
    }

    func testDeleteToolOnlyRequestsApprovalUntilDenied() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let workspace = ChatWorkspaceStore(root: directory)
        let conversation = try await conversations.create(ownerID: "owner")
        _ = await workspace.write(conversationID: conversation.id, name: "keep.txt", content: "not deleted")
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, workspace: workspace, keyRing: keys, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "delete", function: .init(name: "chat_delete_file", arguments: #"{"path":"keep.txt"}"#))]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Please review the deletion request."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Delete keep.txt", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.kind, .fileDelete)
        _ = await access.actions.resolve(ownerID: "owner", id: action.id, approve: false)
        let kept = await workspace.read(conversationID: conversation.id, name: "keep.txt")
        XCTAssertEqual(kept, "not deleted")
        await engine.shutdown()
    }

    func testTerminalLimitDoesNotBlockOrdinaryFileTools() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let workspace = ChatWorkspaceStore(root: directory)
        let conversation = try await conversations.create(ownerID: "owner")
        let probe = await access.terminal.run(command: "true", root: workspace.directory(conversation.id), key: "probe", requestedDirectory: nil)
        if probe.resultText.contains("terminal is unavailable") { throw XCTSkip(probe.resultText) }
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, workspace: workspace, keyRing: keys, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.allSatisfy({ $0.role != "tool" }) {
                let limit = ChatWorkspaceTools.maxRunsPerTurn
                let calls = (0...limit).map { index in
                    APIToolCall(id: "terminal-\(index)", function: .init(name: "run_terminal", arguments: #"{"command":"true"}"#))
                } + [APIToolCall(id: "files", function: .init(name: "project_list_files", arguments: "{}"))]
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: calls), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let outputs = messages.filter { $0.role == "tool" }.compactMap(\.content)
            let limit = ChatWorkspaceTools.maxRunsPerTurn
            XCTAssertEqual(outputs.count, limit + 2)
            XCTAssertTrue(outputs[limit].contains("run limit reached"), outputs[limit])
            XCTAssertTrue(outputs[limit + 1].contains("shared project workspace is empty"), outputs[limit + 1])
            return LLMReply(message: .assistant("The execution cap leaves file tools available."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Run checks and inspect the project", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.status, .complete)
        XCTAssertEqual(result.messages.last?.text, "The execution cap leaves file tools available.")
        await engine.shutdown()
    }

    func testDecisionParserRequiresStructuredContract() throws {
        let decision = try XCTUnwrap(ConversationDecision.parse("```json\n{\"action\":\"ROUTE_TEAM\",\"teamIDs\":[\"B556E20F-6A57-4661-9DD8-624E193382B7\"]}\n```"))
        XCTAssertEqual(decision.action, .routeTeam)
        XCTAssertEqual(decision.teamIDs?.count, 1)
        XCTAssertNil(ConversationDecision.parse("I will use a team."))
        XCTAssertNil(ConversationDecision.parse("{\"action\":\"DELETE_EVERYTHING\"}"))
    }

    func testAdaAnswersDirectlyWithoutLaunchingAgents() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, _, tools in
            if system.contains("memory") && system.contains("Summarize only durable") {
                return LLMReply(message: .assistant("## Preferences\n- Prefers concise replies."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant("{\"action\":\"DIRECT\"}"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            // Direct answers see Ada's workspace tools even with no connectors configured.
            XCTAssertTrue(tools?.map(\.function.name).contains("chat_write_file") ?? false)
            return LLMReply(message: .assistant("A direct answer."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "What is a coordinator?", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages.last?.text, "A direct answer.")
        XCTAssertTrue(result.messages.last?.missionIDs.isEmpty == true)
        XCTAssertEqual(result.title, "What is a coordinator?")
        await engine.shutdown()
    }

    func testStopImmediatelyFinishesThePendingResponseWithoutRecordingMemory() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return LLMReply(message: .assistant("Too late"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Take your time", launchedBy: "Owner", language: "es")
        await engine.stop(conversationID: conversation.id, ownerID: "owner", language: "es")
        let stopped = try await conversations.get(id: conversation.id, ownerID: "owner")
        XCTAssertEqual(stopped?.messages.last?.status, .failed)
        XCTAssertEqual(stopped?.messages.last?.text, "Respuesta detenida.")
        XCTAssertTrue(stopped?.messages.last?.activity.isEmpty == true)
        let memoryState = await memory.state(ownerID: "owner")
        XCTAssertTrue(memoryState.sources.isEmpty)
        await engine.shutdown()
    }

    func testRoutedTeamsRunAsHelperTasksAndProduceOneConsolidatedMessage() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let teams = [team("Research"), team("Writing")]
        for team in teams { await store.saveTeam(team) }
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let ids = teams.map(\.id)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                let json = "{\"action\":\"ROUTE_TEAM\",\"teamIDs\":[\"\(ids[0].uuidString)\",\"\(ids[1].uuidString)\"]}"
                return LLMReply(message: .assistant(json), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("compacted workspace Markdown memory") {
                return LLMReply(message: .assistant("## Projects\n- A shared project."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("One answer from Ada."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Research and summarize this", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(result.messages.last?.text, "One answer from Ada.")
        // Each saved team became a skill, and each skill ran as its own helper task.
        let missionIDs = result.messages.last?.missionIDs ?? []
        XCTAssertEqual(missionIDs.count, 2)
        var names: [String] = []
        for id in missionIDs {
            let loaded = await store.mission(id: id)
            let mission = try XCTUnwrap(loaded)
            XCTAssertEqual(mission.teamID, TaskTools.teamID)
            names.append(mission.teamName)
        }
        XCTAssertEqual(names, ["Research", "Writing"])
        XCTAssertEqual(result.messages.last?.teamIDs, [])
        await engine.shutdown()
    }

    func testMemoryCompactionRetainsProvenanceAndGuideResetIsIsolated() async throws {
        let store = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let conversation = try await store.create(ownerID: "owner")
        let user = ConversationMessage(role: .user, text: "Remember my launch date")
        let assistant = ConversationMessage(role: .assistant, text: "Your launch date is Friday.")
        let pending = try await memory.record(conversationID: conversation.id, ownerID: "owner", userMessage: user, assistantMessage: assistant)
        let job = try XCTUnwrap(pending)
        let result = try await memory.finishCompaction(job, markdown: "## Open loops\n- Launch is Friday.\n## Sources\n- forged source")
        XCTAssertTrue(result.markdown.contains("Launch is Friday"))
        XCTAssertFalse(result.markdown.contains("forged source"))
        XCTAssertTrue(result.markdown.contains(user.id.uuidString))
        XCTAssertEqual(result.sources.first?.conversationID, conversation.id)
        _ = try await store.saveGuide(ownerID: "owner", completed: true)
        _ = try await store.saveGuide(ownerID: "owner", completed: false)
        let persisted = try await store.get(id: conversation.id, ownerID: "owner")
        XCTAssertEqual(persisted?.id, conversation.id)
        let compacted = await memory.state(ownerID: "owner")
        XCTAssertEqual(compacted.compactionCount, 1)
        _ = try await memory.setEnabled(ownerID: "owner", false)
        let paused = try await memory.record(conversationID: conversation.id, ownerID: "owner", userMessage: user, assistantMessage: assistant)
        XCTAssertNil(paused)
        let pausedState = await memory.state(ownerID: "owner")
        XCTAssertEqual(pausedState.pendingEntries, 0)
    }

    func testConnectorReadOnlyAndTeamScopesAreEnforcedAtExecution() async throws {
        let store = MissionStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("token", for: CloudflareConnector.tokenAccount)
        await store.saveConnectorConfigs([ConnectorConfig(id: .cloudflare, enabled: true, permissions: ConnectorPermissions(dnsWrite: true))])
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""), hiddenConnectors: [])
        let readNames = await hub.toolDefs(readOnly: true).map(\.function.name)
        XCTAssertEqual(Set(readNames.filter { $0.hasPrefix("cloudflare_") }), ["cloudflare_zones", "cloudflare_dns_list"])
        XCTAssertTrue(readNames.contains("web_fetch"))
        let allNames = await hub.toolDefs().map(\.function.name)
        XCTAssertTrue(allNames.contains("cloudflare_dns_create"))
        let denied = await hub.run(call: APIToolCall(id: "1", function: .init(name: "cloudflare_dns_create", arguments: "{}")), readOnly: true)
        XCTAssertTrue(denied.resultText.contains("read-only"))
        let scoped = await hub.toolDefs(scope: ToolScope(connectorIDs: []))
        XCTAssertTrue(scoped.isEmpty)
        let outOfScope = await hub.run(call: APIToolCall(id: "2", function: .init(name: "cloudflare_zones", arguments: "{}")), scope: ToolScope(connectorIDs: []))
        XCTAssertTrue(outOfScope.resultText.contains("does not have access"))
        XCTAssertFalse(denied.succeeded)
        XCTAssertFalse(outOfScope.succeeded)
        let invalid = await hub.run(call: APIToolCall(id: "3", function: .init(name: "cloudflare_dns_create", arguments: "{}")), approved: true)
        XCTAssertFalse(invalid.succeeded)
        XCTAssertTrue(invalid.resultText.contains("requires zone_id"))
    }

    func testDirectChatFollowsConnectionsWriteToggles() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var tools: [String] = []
            var system = ""
        }
        for dnsWrite in [false, true] {
            let root = directory.appendingPathComponent("toggle-\(dnsWrite)")
            let store = MissionStore(root: root)
            await store.saveProviders([provider])
            let keys = FileKeyRing(url: root.appendingPathComponent("keys.json"))
            try keys.set("test-key", for: provider.keyAccount)
            try keys.set("token", for: CloudflareConnector.tokenAccount)
            await store.saveConnectorConfigs([ConnectorConfig(id: .cloudflare, enabled: true, permissions: ConnectorPermissions(dnsWrite: dnsWrite))])
            let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""), hiddenConnectors: [])
            let conversations = ConversationStore(root: root)
            let memory = WorkspaceMemoryStore(root: root)
            let seen = Seen()
            let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, connectors: hub, access: ConversationAccess(root: root)) { _, _, _, system, _, tools in
                if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
                if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
                if let tools {
                    seen.lock.lock(); seen.tools = tools.map(\.function.name); seen.system = system; seen.lock.unlock()
                }
                return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let conversation = try await conversations.create(ownerID: "owner")
            _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Add a DNS record", launchedBy: "Owner", language: "en")
            _ = try await finishedConversation(conversations, id: conversation.id)
            seen.lock.lock(); let tools = seen.tools; let system = seen.system; seen.lock.unlock()
            XCTAssertTrue(tools.contains("cloudflare_dns_list"))
            XCTAssertEqual(tools.contains("cloudflare_dns_create"), dnsWrite)
            XCTAssertEqual(system.contains("Connector write tools: cloudflare_dns_create"), dnsWrite)
            XCTAssertEqual(system.contains("Calling one creates an approval card"), dnsWrite)
            await engine.shutdown()
        }
    }

    func testHiddenConnectorsAreNotListedOrOffered() async throws {
        XCTAssertTrue(ConnectorID.hiddenByDefault.contains(.cloudflare))
        let store = MissionStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("token", for: CloudflareConnector.tokenAccount)
        await store.saveConnectorConfigs([ConnectorConfig(id: .cloudflare, enabled: true, permissions: ConnectorPermissions(dnsWrite: true))])
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""), hiddenConnectors: [.cloudflare])
        XCTAssertFalse(hub.visibleConnectorIDs.contains(.cloudflare))
        let names = await hub.toolDefs().map(\.function.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("cloudflare_") })
    }

    func testOlderMessagesDecodeWithoutInteractiveFields() throws {
        let json = #"{"id":"B556E20F-6A57-4661-9DD8-624E193382B7","role":"assistant","text":"Hi","createdAt":0,"status":"complete","missionIDs":[],"teamIDs":[],"activity":[]}"#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.text, "Hi")
        XCTAssertTrue(message.steps.isEmpty)
        XCTAssertTrue(message.quickReplies.isEmpty)
        XCTAssertNil(message.completedAt)
    }

    func testSuggestionsAreSplitFromTheVisibleAnswer() {
        let split = ConversationPrompts.extractSuggestions("Here is the plan.\n\n```suggestions\n- Make it shorter\n2. Add a pricing table\nMake it shorter\n\n```\n")
        XCTAssertEqual(split.text, "Here is the plan.")
        XCTAssertEqual(split.suggestions, ["Make it shorter", "Add a pricing table"])
        let untouched = ConversationPrompts.extractSuggestions("```html\n<p>hi</p>\n```")
        XCTAssertEqual(untouched.text, "```html\n<p>hi</p>\n```")
        XCTAssertTrue(untouched.suggestions.isEmpty)
    }

    func testQuickRepliesAreCleanedAndCapped() {
        let long = String(repeating: "x", count: 81)
        let cleaned = ConversationMessage.cleanQuickReplies(["  Yes  ", "yes", "", long, "No", "Maybe", "Later", "Never"])
        XCTAssertEqual(cleaned, ["Yes", "No", "Maybe", "Later"])
    }

    func testClarifyOptionsBecomeQuickRepliesAndStepsSettle() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"CLARIFY","message":"Which audience?","options":["Customers","Investors","Customers"]}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Write a pitch", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "Which audience?")
        XCTAssertEqual(answer.quickReplies, ["Customers", "Investors"])
        XCTAssertFalse(answer.steps.isEmpty)
        XCTAssertTrue(answer.steps.allSatisfy { $0.state == "done" && $0.finishedAt != nil })
        XCTAssertNotNil(answer.completedAt)
        await engine.shutdown()
    }

    func testDirectAnswerRecordsStepsAndSuggestions() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, _, _ in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("A page.\n```suggestions\nAdd a contact form\n```"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Make a page", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "A page.")
        XCTAssertEqual(answer.quickReplies, ["Add a contact form"])
        XCTAssertEqual(answer.steps.map(\.label), ["Choosing how to help", "Writing the answer"])
        await engine.shutdown()
    }

    func testAdaHandsWorkToATaskThatRunsOnHelpersAndIsChecked() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, messages, tools in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            let names = Set((tools ?? []).map(\.function.name))
            let toolResults = messages.filter { $0.role == "tool" }.compactMap(\.content)
            if system.contains("planning a task that your helpers") {
                XCTAssertEqual(names, ["plan_steps"])
                XCTAssertTrue(messages.first?.content?.contains("Review all 40 files") == true)
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "p", function: .init(name: "plan_steps", arguments: #"{"steps":[{"function":"research","task":"Read every file and list the problems"},{"function":"write","task":"Write review.md from the research","tools":["files"]}]}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are researchAda") {
                XCTAssertFalse(names.contains("chat_write_file"))
                XCTAssertFalse(names.contains("start_task"), "helpers cannot start tasks")
                return LLMReply(message: .assistant("Read 40 files; three have problems."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are writeAda") {
                XCTAssertTrue(messages.first?.content?.contains("Read 40 files; three have problems.") == true, "a step sees the reports before it")
                if toolResults.isEmpty {
                    return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                        APIToolCall(id: "w", function: .init(name: "chat_write_file", arguments: ##"{"path":"review.md","content":"# Review"}"##)),
                    ]), inputTokens: 0, outputTokens: 0, model: "stub")
                }
                return LLMReply(message: .assistant("Wrote review.md."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are judgeAda") {
                XCTAssertFalse(names.contains("chat_write_file"), "the check is read-only")
                XCTAssertTrue(messages.first?.content?.contains("review.md") == true)
                return LLMReply(message: .assistant("PASS: review.md covers the three problems.\nVERDICT: PASS"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if toolResults.isEmpty {
                XCTAssertTrue(names.contains("start_task"))
                // A bad skill name fails and lists what exists; then Ada plans it herself.
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "t1", function: .init(name: "start_task", arguments: #"{"objective":"Review all 40 files and write review.md","skill":"no-such-skill"}"#)),
                    APIToolCall(id: "t2", function: .init(name: "start_task", arguments: #"{"objective":"Review all 40 files and write review.md","reason":"This needs a full review"}"#)),
                    APIToolCall(id: "t3", function: .init(name: "start_task", arguments: #"{"objective":"One more"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            XCTAssertTrue(toolResults[0].contains("No enabled skill"), toolResults[0])
            XCTAssertTrue(toolResults[1].contains("Task finished"), toolResults[1])
            XCTAssertTrue(toolResults[1].contains("Wrote review.md."), toolResults[1])
            XCTAssertTrue(toolResults[1].contains("Check by judgeAda: CLEAN"), toolResults[1])
            XCTAssertTrue(toolResults[1].contains("Files it produced: review.md"), toolResults[1])
            XCTAssertTrue(toolResults[2].contains("Task limit reached"), toolResults[2])
            return LLMReply(message: .assistant("The review is done: see review.md."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Review every file in this project", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.status, .complete)
        XCTAssertEqual(answer.text, "The review is done: see review.md.")
        XCTAssertEqual(answer.missionIDs.count, 1, "the task's record is linked to the reply")
        XCTAssertEqual(answer.fileIDs, ["review.md"])
        XCTAssertTrue(answer.steps.contains { $0.label == "This needs a full review" })
        XCTAssertEqual(answer.activity.filter { $0.teamName == HelperTools.activityLabel }.map(\.agentName), ["researchAda", "writeAda", "judgeAda"])

        let stored = await store.mission(id: answer.missionIDs[0])
        let mission = try XCTUnwrap(stored)
        XCTAssertEqual(mission.status, .completed)
        XCTAssertEqual(mission.teamID, TaskTools.teamID)
        XCTAssertEqual(mission.launchedBy, "Owner")
        let deliverables = Set(await store.deliverables(missionID: mission.id))
        XCTAssertTrue(deliverables.isSuperset(of: ["review.md", "final-report.md", "verification.md"]), "\(deliverables)")
        let events = await store.events(missionID: mission.id, afterSeq: 0)
        XCTAssertTrue(events.first { $0.kind == .plan }?.text?.contains("Task 1 — researchAda: Read every file") == true)
        XCTAssertEqual(events.filter { $0.kind == .taskDone }.compactMap(\.agentName), ["researchAda", "writeAda"])
        XCTAssertEqual(events.first { $0.kind == .verifyVerdict }?.text, "CLEAN")
        XCTAssertEqual(events.last?.kind, .missionEnd)
        let teams = await store.loadTeams()
        XCTAssertTrue(teams.isEmpty, "a task saves no team")
        await engine.shutdown()
    }

    func testLaunchedTaskRunsInItsOwnConversationWithItsContextFile() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, messages, _ in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.contains(where: { ($0.content ?? "").contains("Produce one unified response") }) {
                return LLMReply(message: .assistant("Done from the API."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are judgeAda") { return LLMReply(message: .assistant("VERDICT: PASS"), inputTokens: 0, outputTokens: 0, model: "stub") }
            return LLMReply(message: .assistant("Followed up on 3 quotes."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let mission = try await engine.launchTask(ownerID: "owner", launchedBy: "Owner", objective: "Follow up on open quotes", attachment: (name: "snapshot.md", content: "# Quotes\n- 3 open"), language: "en", sourceName: "Maloon", workflowID: "quote-follow-ups")
        XCTAssertEqual(mission.teamID, TaskTools.teamID)
        XCTAssertEqual(mission.sourceName, "Maloon")
        XCTAssertEqual(mission.workflowID, "quote-follow-ups")
        XCTAssertEqual(mission.inputContext, "# Quotes\n- 3 open")
        XCTAssertEqual(mission.status, .running)
        let list = try await conversations.list(ownerID: "owner")
        let conversationID = try XCTUnwrap(list.first?.id)
        let workspace = ChatWorkspaceStore(root: directory)
        let saved = await workspace.read(conversationID: conversationID, name: "snapshot.md")
        XCTAssertTrue(saved?.contains("3 open") == true)
        let result = try await finishedConversation(conversations, id: conversationID)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.messages[0].text.contains("snapshot.md"), "the task says where its context is")
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.status, .complete)
        XCTAssertEqual(answer.text, "Done from the API.")
        XCTAssertEqual(answer.missionIDs, [mission.id])
        let loaded = await store.mission(id: mission.id)
        let finished = try XCTUnwrap(loaded)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertTrue(finished.finalReport?.contains("Followed up on 3 quotes.") == true)
        let stillRunning = await engine.isTaskRunning(missionID: mission.id)
        XCTAssertFalse(stillRunning)
        await engine.shutdown()
    }

    func testLaunchedTaskCanBeStoppedFromItsMission() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return LLMReply(message: .assistant("late"), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let mission = try await engine.launchTask(ownerID: "owner", launchedBy: "Owner", objective: "A long job", language: "en")
        let running = await engine.isTaskRunning(missionID: mission.id)
        XCTAssertTrue(running)
        let stopped = await engine.stopTask(missionID: mission.id, language: "en")
        XCTAssertTrue(stopped)
        var status: MissionStatus?
        for _ in 0..<150 {
            status = await store.mission(id: mission.id)?.status
            if status == .stopped { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(status, .stopped)
        let list = try await conversations.list(ownerID: "owner")
        let conversation = try await conversations.get(id: try XCTUnwrap(list.first?.id), ownerID: "owner")
        XCTAssertEqual(conversation?.messages.last?.status, .failed)
        let missing = await engine.stopTask(missionID: UUID(), language: "en")
        XCTAssertFalse(missing)
        await engine.shutdown()
    }

    func testTaskPlansAndVerdictsAreReadSafely() {
        let call = APIToolCall(id: "p", function: .init(name: "plan_steps", arguments: #"{"steps":[{"function":"research","task":"a"},{"function":"","task":"b"},{"function":"write","task":"c","tools":["files","bogus"]},{"function":"x","task":"d"},{"function":"y","task":"e"},{"function":"z","task":"f"}]}"#))
        let steps = try? XCTUnwrap(TaskTools.steps(from: call))
        XCTAssertEqual(steps?.map(\.name), ["researchAda", "writeAda", "xAda", "yAda"], "unnamed steps are dropped and the plan is capped")
        XCTAssertEqual(steps?[1].groups, [.read, .files])
        XCTAssertNil(TaskTools.steps(from: APIToolCall(id: "p", function: .init(name: "plan_steps", arguments: #"{"steps":[]}"#))))
        XCTAssertEqual(TaskTools.fallbackPlan(objective: "Do it").map(\.name), ["buildAda"])
        XCTAssertEqual(TaskTools.verdict(in: "Looks fine.\nVERDICT: PASS"), .clean)
        XCTAssertEqual(TaskTools.verdict(in: "VERDICT: CONCERN, one gap"), .concerns)
        XCTAssertEqual(TaskTools.verdict(in: "**Verdict: FAIL**"), .failed)
        XCTAssertEqual(TaskTools.verdict(in: "No verdict line here, PASS"), .unverified)
    }

    func testAdaDelegatesToHelpersWithScopedToolsAndGetsTheirReports() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, messages, tools in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            let names = Set((tools ?? []).map(\.function.name))
            if system.contains("You are researchAda") {
                XCTAssertTrue(system.contains("SKILL: Research"), "the skill's procedure reaches the helper")
                // Read-only: it can look at files, but not write them, delegate, or schedule.
                XCTAssertTrue(names.contains("chat_read_file"))
                XCTAssertFalse(names.contains("chat_write_file"))
                XCTAssertFalse(names.contains("delegate"))
                XCTAssertFalse(names.contains("start_task"))
                XCTAssertFalse(names.contains("memory_remember"))
                if messages.contains(where: { $0.role == "tool" }) {
                    return LLMReply(message: .assistant("Found three sources."), inputTokens: 0, outputTokens: 0, model: "stub")
                }
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "h1", function: .init(name: "chat_list_files", arguments: "{}")),
                    // A tool the helper was not given must not run.
                    APIToolCall(id: "h2", function: .init(name: "chat_write_file", arguments: #"{"path":"x.md","content":"x"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are priceCheckAda") {
                XCTAssertTrue(system.contains("Compare vendor prices"), "the brief reaches the helper")
                XCTAssertTrue(names.contains("chat_write_file"))
                if messages.contains(where: { $0.role == "tool" }) {
                    return LLMReply(message: .assistant("Wrote prices.md."), inputTokens: 0, outputTokens: 0, model: "stub")
                }
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "p1", function: .init(name: "chat_write_file", arguments: ##"{"path":"prices.md","content":"# Prices"}"##)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let results = messages.filter { $0.role == "tool" }.compactMap(\.content)
            if results.isEmpty {
                XCTAssertTrue(names.contains("delegate"))
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [
                    APIToolCall(id: "d1", function: .init(name: "delegate", arguments: #"{"function":"research","task":"Find sources on battery recycling","skill":"research"}"#)),
                    APIToolCall(id: "d2", function: .init(name: "delegate", arguments: #"{"function":"price check","brief":"Compare vendor prices","task":"Write prices.md","tools":["files"]}"#)),
                    APIToolCall(id: "d3", function: .init(name: "delegate", arguments: #"{"function":"research","task":"x","tools":["teleport"]}"#)),
                    APIToolCall(id: "d4", function: .init(name: "delegate", arguments: #"{"function":"research","task":"x","skill":"nope"}"#)),
                ]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            XCTAssertTrue(results[0].contains("researchAda finished"), results[0])
            XCTAssertTrue(results[0].contains("Found three sources."), results[0])
            XCTAssertTrue(results[0].contains("chat_write_file"), "the refused write is in the helper's log: \(results[0])")
            XCTAssertTrue(results[1].contains("priceCheckAda finished"), results[1])
            XCTAssertTrue(results[1].contains("prices.md"), results[1])
            XCTAssertTrue(results[2].contains("Unknown tool group"), results[2])
            XCTAssertTrue(results[3].contains("No enabled skill \"nope\""), results[3])
            return LLMReply(message: .assistant("Both helpers reported."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Look into battery recycling and prices", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.status, .complete)
        XCTAssertEqual(answer.text, "Both helpers reported.")
        XCTAssertEqual(answer.fileIDs, ["prices.md"], "a file a helper wrote shows on the reply")
        XCTAssertTrue(answer.steps.contains { $0.label == "researchAda is working" })
        let helpers = answer.activity.filter { $0.teamName == HelperTools.activityLabel }
        XCTAssertEqual(helpers.map(\.agentName), ["researchAda", "priceCheckAda"], "helpers stay on the finished reply")
        XCTAssertEqual(helpers.map(\.state), ["done", "done"])
        XCTAssertEqual(helpers.first?.summary, "Found three sources.")
        await engine.shutdown()
    }

    func testWithoutRoutingAdaAnswersInOneLoopWithDelegateAndTasksOffered() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, routing: false) { _, _, _, system, _, tools in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            XCTAssertFalse(system.contains("Decide how to handle"), "no routing call")
            let names = Set((tools ?? []).map(\.function.name))
            XCTAssertTrue(names.contains("delegate"))
            XCTAssertTrue(names.contains("start_task"))
            return LLMReply(message: .assistant("Straight answer."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Research the market and write a report", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "Straight answer.")
        XCTAssertEqual(result.messages.last?.steps.map(\.label), ["Thinking it through", "Writing the answer"])
        await engine.shutdown()
    }

    func testHelperNamesAndToolGroups() {
        XCTAssertEqual(HelperTools.name(for: "research"), "researchAda")
        XCTAssertEqual(HelperTools.name(for: "Price check"), "priceCheckAda")
        XCTAssertEqual(HelperTools.name(for: "judgeAda"), "judgeAda")
        XCTAssertNil(HelperTools.name(for: "   "))
        XCTAssertNil(HelperTools.name(for: String(repeating: "a", count: 40)))
        let read: Set<HelperTools.Group> = [.read]
        XCTAssertTrue(HelperTools.allows(name: "chat_read_file", family: .chat, groups: read))
        XCTAssertTrue(HelperTools.allows(name: "gmail_search", family: .connector, groups: read))
        XCTAssertFalse(HelperTools.allows(name: "gmail_send", family: .connector, groups: read))
        XCTAssertTrue(HelperTools.allows(name: "gmail_send", family: .connector, groups: [.read, .write]))
        XCTAssertFalse(HelperTools.allows(name: "chat_write_file", family: .chat, groups: read))
        XCTAssertTrue(HelperTools.allows(name: "chat_write_file", family: .chat, groups: [.files]))
        XCTAssertFalse(HelperTools.allows(name: "run_program", family: .chat, groups: [.files]))
        XCTAssertTrue(HelperTools.allows(name: "run_program", family: .chat, groups: [.run]))
        XCTAssertFalse(HelperTools.allows(name: "chat_schedule_run", family: .chat, groups: Set(HelperTools.Group.allCases)))
        XCTAssertFalse(HelperTools.allows(name: "workstation_run", family: .workstation, groups: [.files, .run, .write]))
        XCTAssertTrue(HelperTools.allows(name: "workstation_run", family: .workstation, groups: [.workstation]))
        for family in [ToolFamily.task, .trigger, .skill, .memory, .selfReview, .delegate] {
            XCTAssertFalse(HelperTools.allows(name: "anything", family: family, groups: Set(HelperTools.Group.allCases)), "\(family)")
        }
    }

    func testSoloRunsAsAHelperTaskWithoutTheSoloTeam() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, messages, _ in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"SOLO"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.contains(where: { ($0.content ?? "").contains("Produce one unified response") }) {
                return LLMReply(message: .assistant("Here is what I made."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("You are judgeAda") {
                return LLMReply(message: .assistant("VERDICT: PASS\nThe page is there."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Built the page."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Build and verify a page yourself", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "Here is what I made.")
        XCTAssertEqual(answer.missionIDs.count, 1)
        XCTAssertTrue(answer.teamIDs.isEmpty)
        let loaded = await store.mission(id: answer.missionIDs[0])
        let mission = try XCTUnwrap(loaded)
        XCTAssertEqual(mission.teamID, TaskTools.teamID)
        XCTAssertEqual(mission.status, .completed)
        XCTAssertTrue(mission.finalReport?.contains("Built the page.") == true)
        // No solo team is saved any more, and the helpers who worked stay on the reply.
        let solo = await store.team(id: ConversationEngine.soloTeamID)
        XCTAssertNil(solo)
        XCTAssertTrue(answer.activity.contains { $0.teamName == HelperTools.activityLabel })
        await engine.shutdown()
    }

    func testSoloTeamIsExcludedFromRoutingRoster() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        // Seed the solo team, as a previous SOLO run would have.
        let ada = AgentProfile.rosterTemplates[0]
        await store.saveTeam(Team(id: ConversationEngine.soloTeamID, name: "Ada (solo)", agents: [ada, { var worker = ada; worker.id = UUID(); worker.role = .worker; return worker }()]))
        var seenRoster = false
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                seenRoster = true
                // The roster section lists teams by ID; the solo team must not appear.
                XCTAssertFalse(system.contains(ConversationEngine.soloTeamID.uuidString))
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("ok"), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Hello", launchedBy: "Owner", language: "en")
        _ = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertTrue(seenRoster)
        await engine.shutdown()
    }

    func testDirectAnswerCanWriteWorkspaceFiles() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, messages, tools in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            // First response turn writes a file; the tool result comes back and the final answer lands.
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(
                    message: APIMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [APIToolCall(id: "w1", function: .init(name: "chat_write_file", arguments: #"{"path":"index.html","content":"<h1>Jelly</h1>"}"#))]
                    ),
                    inputTokens: 0, outputTokens: 0, model: "stub"
                )
            }
            XCTAssertTrue(messages.contains { $0.role == "tool" && ($0.content ?? "").contains("Wrote index.html") })
            XCTAssertTrue(tools?.map(\.function.name).contains("chat_write_file") ?? false)
            XCTAssertTrue(tools?.map(\.function.name).contains("chat_read_file") ?? false)
            XCTAssertTrue(tools?.map(\.function.name).contains("run_program") ?? false)
            return LLMReply(message: .assistant("I wrote index.html for you."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Build a page", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "I wrote index.html for you.")
        XCTAssertEqual(answer.fileIDs, ["index.html"])
        await engine.shutdown()
    }

    func testWebDeliverablesAreReadableButBinaryAndEscapesAreNot() async throws {
        let store = MissionStore(root: directory)
        let missionID = UUID()
        let folder = store.deliverablesDirectory(missionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<h1>Hi</h1>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: folder.appendingPathComponent("styles.css"))
        try Data([0x89, 0x50]).write(to: folder.appendingPathComponent("logo.png"))
        let html = await store.deliverable(missionID: missionID, name: "index.html")
        let css = await store.deliverable(missionID: missionID, name: "styles.css")
        let png = await store.deliverable(missionID: missionID, name: "logo.png")
        let escape = await store.deliverable(missionID: missionID, name: "../../keys.json")
        XCTAssertEqual(html, "<h1>Hi</h1>")
        XCTAssertEqual(css, "body{}")
        XCTAssertNil(png)
        XCTAssertNil(escape)
    }

    func testSharedContextIncludesWorkspaceProjectScheduleAndLinkedMissionWithoutDuplicatingCurrentUser() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        var custom = team("Custom")
        custom.agents[0].systemPrompt = "Team-only persona"
        await store.saveTeam(custom)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let workspace = ChatWorkspaceStore(root: directory)
        let conversation = try await conversations.create(ownerID: "owner", projectName: "Website")
        await workspace.write(conversationID: conversation.id, name: "site/index.html", content: "<h1>Old</h1>")
        var mission = await store.createMission(team: custom, objective: "Build the first page")
        mission.status = .completed
        await store.saveMission(mission)
        let missionID = mission.id
        await store.writeDeliverable(missionID: missionID, name: "final-report.md", content: "Done")
        _ = try await conversations.append(id: conversation.id, ownerID: "owner", message: ConversationMessage(role: .assistant, text: "The first page is ready.", missionIDs: [missionID]))
        _ = try await conversations.setSchedule(id: conversation.id, ownerID: "owner", schedule: ConversationSchedule(prompt: "Refresh", intervalMinutes: 60))
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, ada, system, messages, _ in
            if system.contains("Summarize only durable") {
                return LLMReply(message: .assistant("## Projects\n- Website"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("Decide how to handle") {
                // The changing context rides at the start of the newest user turn, not in the system prompt.
                let turn = messages.last?.content ?? ""
                XCTAssertTrue(turn.contains("Project: Website"))
                XCTAssertTrue(turn.contains("site/index.html — 12"))
                XCTAssertTrue(turn.contains(missionID.uuidString))
                XCTAssertTrue(turn.contains("Recurring hourly"))
                XCTAssertTrue(turn.hasSuffix("<user_message>\nRevise the saved page\n</user_message>"))
                XCTAssertFalse(system.contains("Project: Website"))
                XCTAssertFalse(system.contains(missionID.uuidString))
                XCTAssertTrue(ada.systemPrompt.contains("smallest action"))
                XCTAssertFalse(system.contains("Team-only persona"))
                XCTAssertFalse(system.contains("Revise the saved page"))
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Updated."), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Revise the saved page", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "Updated.")
        await engine.shutdown()
    }

    func testDirectAndConsolidationPromptsHaveDistinctVersionedCapabilities() {
        let prompts = PromptStore(builtins: PromptStore.builtins)
        let context = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        let ada = AgentProfile.rosterTemplates[0]
        let direct = ConversationPrompts.directResponseSystem(coordinator: ada, context: context, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en")
        let consolidation = ConversationPrompts.consolidationSystem(coordinator: ada, context: context, store: prompts, language: "en")
        XCTAssertTrue(direct.contains("chat_write_file"))
        XCTAssertFalse(direct.contains("Available read-only tools"))
        XCTAssertFalse(consolidation.contains("chat_write_file"))
        XCTAssertTrue(consolidation.contains("No tools or workspace writes"))
        XCTAssertNotNil(prompts.currentVersions()["ada_direct_system"])
        prompts.update(id: "ada_direct_system", text: "Custom direct prompt\n{{conversation_context}}")
        let edited = ConversationPrompts.directResponseSystem(coordinator: ada, context: context, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en")
        XCTAssertTrue(edited.hasPrefix("Custom direct prompt"))
        XCTAssertTrue(edited.contains("<workspace_data>"), "an edited template still learns where the context is")
        XCTAssertFalse(edited.contains("Project: Personal"))
    }

    func testChatSystemPromptsStayIdenticalAcrossTurns() {
        let prompts = PromptStore(builtins: PromptStore.builtins)
        let ada = AgentProfile.rosterTemplates[0]
        let first = ConversationPromptContext(projectName: "Personal", history: [], memory: "Prefers short replies.", workspaceManifest: "a.md — 10", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false, now: Date(timeIntervalSince1970: 0))
        let second = ConversationPromptContext(
            projectName: "Personal",
            history: [ConversationMessage(role: .user, text: "Hi"), ConversationMessage(role: .assistant, text: "Hello")],
            memory: "Prefers short replies. Lives in Madrid.",
            workspaceManifest: "a.md — 10\nb.md — 20",
            missionReferences: "",
            missionIDs: [],
            schedule: ConversationSchedule(prompt: "Refresh", intervalMinutes: 60),
            scheduled: false,
            now: Date(timeIntervalSince1970: 3_600)
        )
        XCTAssertEqual(
            ConversationPrompts.directResponseSystem(coordinator: ada, context: first, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en"),
            ConversationPrompts.directResponseSystem(coordinator: ada, context: second, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en")
        )
        XCTAssertEqual(
            ConversationPrompts.routingSystem(coordinator: ada, skills: "- research: use when", context: first, store: prompts, language: "en"),
            ConversationPrompts.routingSystem(coordinator: ada, skills: "- research: use when", context: second, store: prompts, language: "en")
        )
        let turn = second.userTurn("What's new?")
        XCTAssertTrue(turn.hasPrefix("<about_user>\n"))
        XCTAssertTrue(turn.contains("Lives in Madrid."))
        XCTAssertTrue(turn.contains("b.md — 20"))
        XCTAssertTrue(turn.contains("Current time: Thursday, 1 January 1970, 01:00 (UTC, UTC+00:00)"), turn)
        XCTAssertTrue(turn.hasSuffix("<user_message>\nWhat's new?\n</user_message>"))
        // Memory holds the user's own preferences, so it is no longer filed under untrusted data.
        let about = turn.components(separatedBy: "</about_user>")[0]
        XCTAssertFalse(about.contains("untrusted"))
    }

    func testChatPromptsLeaveHistoryToMessagesButMissionHandoffKeepsIt() {
        let prompts = PromptStore(builtins: PromptStore.builtins)
        let history = [
            ConversationMessage(role: .user, text: "Plan the alpaca newsletter"),
            ConversationMessage(role: .assistant, text: "Here is a draft outline."),
        ]
        let context = ConversationPromptContext(projectName: "Personal", history: history, memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        let ada = AgentProfile.rosterTemplates[0]
        // Chat calls already send the history as real messages, so the system prompt must not repeat it.
        let direct = ConversationPrompts.directResponseSystem(coordinator: ada, context: context, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en")
        let routing = ConversationPrompts.routingSystem(coordinator: ada, skills: "", context: context, store: prompts, language: "en")
        for system in [direct, routing] {
            XCTAssertFalse(system.contains("Plan the alpaca newsletter"))
            XCTAssertFalse(system.contains("Recent conversation"))
        }
        // Missions get no chat turns, so their handoff carries the recent conversation as text.
        XCTAssertTrue(context.missionHandoff.contains("User: Plan the alpaca newsletter"))
        XCTAssertTrue(context.missionHandoff.contains("Ada: Here is a draft outline."))
    }

    func testSpokenRepliesAreNotAskedToCiteIDs() {
        let prompts = PromptStore(builtins: PromptStore.builtins)
        let tools = [APIToolDef(name: "gmail_search", description: "Search Gmail", parameters: .object(["type": .string("object")]))]
        let ada = AgentProfile.rosterTemplates[0]
        let typed = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        var spoken = typed
        spoken.spoken = true
        let text = ConversationPrompts.directResponseSystem(coordinator: ada, context: typed, connectorTools: tools, hasLinkedMissions: false, store: prompts, language: "en")
        let voice = ConversationPrompts.directResponseSystem(coordinator: ada, context: spoken, connectorTools: tools, hasLinkedMissions: false, store: prompts, language: "en")
        XCTAssertTrue(text.contains("Cite relevant message"))
        XCTAssertFalse(voice.contains("Cite relevant message"))
        XCTAssertTrue(voice.contains("gmail_search"))
    }

    func testEveryDirectToolHasAFriendlyStepLabel() {
        let names = (ChatWorkspaceTools.definitions + TriggerTools.definitions + TaskTools.definitions(catalog: "") + ExtendedWorkspaceTools.definitions + ConversationMissionTools.definitions + WorkstationTools.definitions).map(\.function.name)
            + ConnectorHub.readOnlyToolNames.filter { !$0.hasPrefix("cloudflare_") }
            + ["gmail_draft", "gmail_send", "github_write_file", "github_comment", "googleads_set_status", "googleads_set_budget", "googleads_mutate"]
        for name in names {
            for language in ["en", "es"] {
                let label = ConversationPrompts.toolStepLabel(name, language: language)
                XCTAssertFalse(label.contains(name), "\(name) has no \(language) step label")
            }
        }
    }

    func testEveryToolHasOneCatalogEntryWithTheRightAccess() {
        let everything = ConnectorPermissions(sendEmail: true, createDraft: true, dnsWrite: true, githubWrite: true, adsWrite: true)
        let connectorNames = Set(ConnectorHub.providers.flatMap { $0.toolDefs(permissions: everything) }.map(\.function.name))
        let workspaceNames = Set((ChatWorkspaceTools.definitions + TriggerTools.definitions + TaskTools.definitions(catalog: "") + HelperTools.definitions(hasWorkstation: true, hasMCP: true, canSave: true) + ExtendedWorkspaceTools.definitions + ConversationMissionTools.definitions + SkillTools.definitions + MemoryTools.definitions + SelfReviewTools.definitions + WorkstationTools.definitions + BrowserTools.definitions + AgentTools.workerTools).map(\.function.name))
        let catalogNames = ToolCatalog.specs.map(\.name)
        XCTAssertEqual(catalogNames.count, Set(catalogNames).count, "a tool is listed twice in the catalog")
        XCTAssertEqual(Set(catalogNames), connectorNames.union(workspaceNames), "the catalog and the tool definitions disagree")
        let connectorReads = Set(connectorNames.filter { ToolCatalog.spec($0)?.access == .read })
        XCTAssertEqual(connectorReads, ConnectorHub.readOnlyToolNames)
        for name in connectorNames.subtracting(ConnectorHub.readOnlyToolNames) {
            XCTAssertEqual(ToolCatalog.spec(name)?.access, .approval, "\(name) writes outside the workspace without an approval")
        }
        XCTAssertEqual(ToolCatalog.spec("chat_delete_file")?.access, .approval)
        XCTAssertEqual(ConversationPrompts.toolStepLabel("gmail_send", language: "es"), "Preparando un correo")
        XCTAssertEqual(ConversationPrompts.toolStepLabel("unknown_tool", language: "en"), "Using unknown_tool")
    }

    func testDirectAnswerCompactsLargeExecutedToolPayloads() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let large = String(repeating: "x", count: 400_000) // ≈100k tokens, past the default model budget
        let arguments = #"{"path":"large.txt","content":""}"#.replacingOccurrences(of: "\"content\":\"\"", with: "\"content\":\"\(large)\"")
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, messages, _ in
            if system.contains("Summarize only durable") {
                return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.allSatisfy({ $0.role != "tool" }) {
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "large", function: .init(name: "chat_write_file", arguments: arguments))]), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let payloads = messages.flatMap { $0.tool_calls ?? [] }.map(\.function.arguments)
            XCTAssertTrue(payloads.contains { $0.contains("__trimmed__") })
            return LLMReply(message: .assistant("Saved."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Save a large file", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "Saved.")
        await engine.shutdown()
    }

    func testLinkedMissionToolsReadOnlyAuthorizedMissionAndSupportRanges() async throws {
        let store = MissionStore(root: directory)
        let team = team("Research")
        let mission = await store.createMission(team: team, objective: "Write lines")
        await store.writeDeliverable(missionID: mission.id, name: "notes.md", content: "one\ntwo\nthree")
        let call = APIToolCall(id: "read", function: .init(name: "mission_read_file", arguments: #"{"mission_id":""# + mission.id.uuidString + #"","path":"notes.md","start_line":2}"#))
        let read = await ConversationMissionTools.run(call: call, store: store, allowedMissionIDs: [mission.id])
        XCTAssertEqual(read.resultText, "two\nthree")
        let denied = await ConversationMissionTools.run(call: call, store: store, allowedMissionIDs: [])
        XCTAssertTrue(denied.resultText.contains("not found"))
    }

    func testWorkspaceMemoryIsolatedByOwner() async throws {
        let store = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let first = try await store.create(ownerID: "owner-a")
        let second = try await store.create(ownerID: "owner-b")
        let userA = ConversationMessage(role: .user, text: "My private launch is Friday")
        let adaA = ConversationMessage(role: .assistant, text: "Noted Friday.")
        let pendingA = try await memory.record(conversationID: first.id, ownerID: "owner-a", userMessage: userA, assistantMessage: adaA)
        let jobA = try XCTUnwrap(pendingA)
        _ = try await memory.finishCompaction(jobA, markdown: "## Open loops\n- Owner A launches Friday.")
        let emptyB = await memory.state(ownerID: "owner-b")
        XCTAssertFalse(emptyB.markdown.contains("Owner A"))
        let userB = ConversationMessage(role: .user, text: "My private launch is Monday")
        let adaB = ConversationMessage(role: .assistant, text: "Noted Monday.")
        let pendingB = try await memory.record(conversationID: second.id, ownerID: "owner-b", userMessage: userB, assistantMessage: adaB)
        let jobB = try XCTUnwrap(pendingB)
        XCTAssertFalse(jobB.prompt.contains("Owner A"))
        _ = try await memory.finishCompaction(jobB, markdown: "## Open loops\n- Owner B launches Monday.")
        let stateA = await memory.state(ownerID: "owner-a")
        let stateB = await memory.state(ownerID: "owner-b")
        XCTAssertTrue(stateA.markdown.contains("Owner A"))
        XCTAssertFalse(stateA.markdown.contains("Owner B"))
        XCTAssertTrue(stateB.markdown.contains("Owner B"))
        XCTAssertFalse(stateB.markdown.contains("Owner A"))
    }

    // MARK: Schedules

    func testScheduleValidationAcceptsAllowedIntervalsAndRejectsOthers() throws {
        let valid = ConversationSchedule.validate(prompt: "  Refresh the list from Gmail and update the snapshot. ", intervalMinutes: 60)
        XCTAssertEqual(valid?.prompt, "Refresh the list from Gmail and update the snapshot.")
        XCTAssertEqual(valid?.intervalMinutes, 60)
        XCTAssertEqual(valid?.intervalLabel, "hourly")
        XCTAssertEqual(valid?.language, "en")
        XCTAssertNil(ConversationSchedule.validate(prompt: "Refresh", intervalMinutes: 45))
        XCTAssertNil(ConversationSchedule.validate(prompt: "", intervalMinutes: 60))
        XCTAssertNil(ConversationSchedule.validate(prompt: String(repeating: "x", count: 4_001), intervalMinutes: 60))
        XCTAssertEqual(ConversationSchedule(prompt: "Digest", intervalMinutes: 1440, language: "ES").language, "es")
        XCTAssertEqual(ConversationSchedule(prompt: "Digest", intervalMinutes: 1440).intervalLabel, "daily")
        XCTAssertEqual(ConversationSchedule(prompt: "Digest", intervalMinutes: 720).intervalLabel, "every 12 hours")
        XCTAssertEqual(ConversationSchedule(prompt: "Digest", intervalMinutes: 30).intervalLabel, "every 30 minutes")
    }

    func testSchedulePersistsWithConversationAndDueScanFindsOnlyDueOnes() async throws {
        let store = ConversationStore(root: directory)
        let conversation = try await store.create(ownerID: "owner")
        // No schedule on a new conversation; old conversations decode without one.
        XCTAssertNil(conversation.schedule)
        let past = ConversationSchedule(prompt: "Due already", intervalMinutes: 15, nextRunAt: Date().addingTimeInterval(-60))
        let future = ConversationSchedule(prompt: "Not yet", intervalMinutes: 15, nextRunAt: Date().addingTimeInterval(3_600))
        let second = try await store.create(ownerID: "owner")
        _ = try await store.setSchedule(id: conversation.id, ownerID: "owner", schedule: past)
        _ = try await store.setSchedule(id: second.id, ownerID: "owner", schedule: future)
        let due = try await store.dueSchedules()
        XCTAssertEqual(due.map(\.conversationID), [conversation.id])
        XCTAssertEqual(due.first?.schedule.prompt, "Due already")
        // Marking a run advances nextRunAt by the interval.
        let run = try await store.markScheduleRun(id: conversation.id, ownerID: "owner")
        XCTAssertNotNil(run.schedule?.lastRunAt)
        let afterMark = try await store.dueSchedules()
        XCTAssertTrue(afterMark.isEmpty)
        // Clearing removes it.
        _ = try await store.setSchedule(id: conversation.id, ownerID: "owner", schedule: nil)
        let cleared = try await store.get(id: conversation.id, ownerID: "owner")
        XCTAssertNil(cleared?.schedule)
    }

    func testSchedulerFiresDuePromptAsAScheduledMessageAndAdvancesIt() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, _, _ in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Refreshed with 3 new messages."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        // Make the schedule due now.
        _ = try await conversations.setSchedule(id: conversation.id, ownerID: "owner", schedule: ConversationSchedule(prompt: "Refresh the list", intervalMinutes: 60, nextRunAt: Date().addingTimeInterval(-1)))
        let scheduler = ConversationScheduler(conversations: conversations, engine: engine)
        await scheduler.tick()
        let result = try await finishedConversation(conversations, id: conversation.id)
        // The scheduled user message is flagged so the UI labels it, and Ada answered normally.
        let scheduledMessage = try XCTUnwrap(result.messages.first { $0.role == .user })
        XCTAssertTrue(scheduledMessage.scheduled)
        XCTAssertEqual(scheduledMessage.text, "Refresh the list")
        XCTAssertEqual(result.messages.last?.text, "Refreshed with 3 new messages.")
        // The schedule advanced: not due again until the next interval.
        let after = try await conversations.get(id: conversation.id, ownerID: "owner")
        XCTAssertNotNil(after?.schedule?.lastRunAt)
        let dueAgain = try await conversations.dueSchedules()
        XCTAssertTrue(dueAgain.filter { $0.conversationID == conversation.id }.isEmpty)
        await engine.shutdown()
        await scheduler.shutdown()
    }

    func testAdaCanScheduleAndCancelThroughWorkspaceTools() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys) { _, _, _, system, messages, tools in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.allSatisfy({ $0.role != "tool" }) {
                XCTAssertTrue(tools?.map(\.function.name).contains("chat_schedule_run") ?? false)
                return LLMReply(
                    message: APIMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [APIToolCall(id: "s1", function: .init(name: "chat_schedule_run", arguments: #"{"prompt":"Refresh the list","intervalMinutes":60}"#))]
                    ),
                    inputTokens: 0, outputTokens: 0, model: "stub"
                )
            }
            if messages.contains(where: { $0.role == "tool" && ($0.content ?? "").contains("Schedule set") })
                && messages.allSatisfy({ $0.role != "tool" || !($0.content ?? "").contains("Schedule cancelled") }) {
                return LLMReply(
                    message: APIMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [APIToolCall(id: "s2", function: .init(name: "chat_schedule_cancel", arguments: "{}"))]
                    ),
                    inputTokens: 0, outputTokens: 0, model: "stub"
                )
            }
            return LLMReply(message: .assistant("Set, then cancelled."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Run the refresh every hour", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "Set, then cancelled.")
        // The cancel cleared what the run set; the persisted schedule is gone.
        XCTAssertNil(result.schedule)
        await engine.shutdown()
    }

    func testScheduleToolValidatesIntervalBeforeSaving() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        actor Recorder {
            var saved: [ConversationSchedule?] = []
            func record(_ next: ConversationSchedule?) -> ConversationSchedule? {
                saved.append(next)
                return next
            }
            func snapshot(_ block: ([ConversationSchedule?]) -> Void) {
                block(saved)
            }
        }
        let recorder = Recorder()
        let sink: @Sendable (ConversationSchedule?) async -> ConversationSchedule? = { next in
            await recorder.record(next)
        }
        let bad = await ChatWorkspaceTools.run(
            call: APIToolCall(id: "b", function: .init(name: "chat_schedule_run", arguments: #"{"prompt":"Refresh","intervalMinutes":45}"#)),
            workspace: workspace,
            conversationID: conversationID,
            schedule: sink
        )
        XCTAssertTrue(bad.resultText.contains("Invalid schedule"))
        var savedAfterBad: [ConversationSchedule?] = []
        await recorder.snapshot { savedAfterBad = $0 }
        XCTAssertTrue(savedAfterBad.isEmpty)
        let good = await ChatWorkspaceTools.run(
            call: APIToolCall(id: "g", function: .init(name: "chat_schedule_run", arguments: #"{"prompt":"Refresh","intervalMinutes":60}"#)),
            workspace: workspace,
            conversationID: conversationID,
            schedule: sink
        )
        XCTAssertTrue(good.resultText.contains("hourly"))
        var savedAfterGood: [ConversationSchedule?] = []
        await recorder.snapshot { savedAfterGood = $0 }
        XCTAssertEqual(savedAfterGood.count, 1)
        let cancel = await ChatWorkspaceTools.run(
            call: APIToolCall(id: "c", function: .init(name: "chat_schedule_cancel", arguments: "{}")),
            workspace: workspace,
            conversationID: conversationID,
            schedule: sink
        )
        XCTAssertEqual(cancel.resultText, "Schedule cancelled.")
        var savedAfterCancel: [ConversationSchedule?] = []
        await recorder.snapshot { savedAfterCancel = $0 }
        XCTAssertEqual(savedAfterCancel.count, 2)
        XCTAssertNil(savedAfterCancel.last ?? nil)
    }
}

/// Collects strings from a @Sendable completion stub.
final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(contentsOf strings: [String]) { lock.withLock { items += strings } }
    var values: [String] { lock.withLock { items } }
}
