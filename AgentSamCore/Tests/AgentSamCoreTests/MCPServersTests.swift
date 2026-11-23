import XCTest
@testable import AgentSamCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A tiny MCP server behind a URLProtocol: answers initialize, tools/list and tools/call.
final class FakeMCPProtocol: URLProtocol {
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var authorization: [String] = []
    nonisolated(unsafe) static var eventStream = false
    nonisolated(unsafe) static var expireSessionOnce = false
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let message = (try? JSONDecoder().decode(JSONValue.self, from: Self.body(of: request)))?.objectValue ?? [:]
        let method = message["method"]?.stringValue ?? ""
        let id = message["id"] ?? .null
        Self.lock.withLock {
            Self.calls.append(method)
            Self.authorization.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        var status = 200
        var headers = ["Content-Type": Self.eventStream ? "text/event-stream" : "application/json"]
        var result: JSONValue = .object([:])
        switch method {
        case "initialize":
            headers["Mcp-Session-Id"] = "session-1"
            result = .object([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([:])), ("serverInfo", .object([("name", .string("fake"))]))])
        case "notifications/initialized":
            status = 202
        case "tools/list":
            result = .object([("tools", .array([
                .object([("name", .string("search_notes")), ("description", .string("Search notes.")), ("inputSchema", .object([("type", .string("object")), ("properties", .object([("q", .object([("type", .string("string"))]))]))])), ("annotations", .object([("readOnlyHint", .bool(true))]))]),
                .object([("name", .string("create.note")), ("description", .string("Create a note.")), ("inputSchema", .object([("$schema", .string("http://json-schema.org/draft-07/schema#")), ("properties", .object([("text", .object([("type", .string("string"))]))]))]))]),
            ]))])
        case "tools/call":
            let shouldExpire = Self.lock.withLock { () -> Bool in
                if Self.expireSessionOnce { Self.expireSessionOnce = false; return true }
                return false
            }
            if shouldExpire { status = 404; break }
            let params = message["params"]?.objectValue ?? [:]
            let text = "called \(params["name"]?.stringValue ?? "") with \(params["arguments"]?.objectValue?["text"]?.stringValue ?? params["arguments"]?.objectValue?["q"]?.stringValue ?? "")"
            result = .object([("content", .array([.object([("type", .string("text")), ("text", .string(text))])]))])
        default:
            status = 400
        }
        let reply = JSONValue.object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
        var data = (try? JSONEncoder().encode(reply)) ?? Data()
        if Self.eventStream { data = Data("event: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n".utf8) }
        if status != 200 { data = Data() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class MCPServersTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FakeMCPProtocol.calls = []
        FakeMCPProtocol.authorization = []
        FakeMCPProtocol.eventStream = false
        FakeMCPProtocol.expireSessionOnce = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func registry() -> (MCPRegistry, FileKeyRing) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeMCPProtocol.self]
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        return (MCPRegistry(root: directory, keyRing: keys, session: URLSession(configuration: configuration)), keys)
    }

    func testAddingAServerListsToolsAndStartsFromReadOnlyHints() async throws {
        let (mcp, keys) = registry()
        let server = try await mcp.add(name: "Notes!", url: "https://notes.example.test/mcp", token: "secret-token")
        XCTAssertEqual(server.slug, "notes")
        XCTAssertEqual(server.tools.map(\.name), ["search_notes", "create.note"])
        XCTAssertEqual(server.readTools, ["search_notes"])
        XCTAssertEqual(FakeMCPProtocol.calls, ["initialize", "notifications/initialized", "tools/list"])
        XCTAssertTrue(FakeMCPProtocol.authorization.allSatisfy { $0 == "Bearer secret-token" })
        XCTAssertEqual(keys.get(MCPRegistry.tokenAccount(server.id)), "secret-token")
        let saved = try String(contentsOf: directory.appendingPathComponent("mcp-servers.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("secret-token"), "tokens live in the key store, not the config file")

        let defs = await mcp.toolDefs()
        XCTAssertEqual(defs.map(\.function.name), ["mcp_notes_search_notes", "mcp_notes_create_note"])
        XCTAssertTrue(defs[0].function.description.contains("untrusted"))
        XCTAssertNil(defs[1].function.parameters.objectValue?["$schema"])
        XCTAssertEqual(defs[1].function.parameters.objectValue?["type"]?.stringValue, "object")
        let readOnly = await mcp.isReadOnly("mcp_notes_search_notes")
        let writeNames = await mcp.writeToolNames()
        XCTAssertTrue(readOnly)
        XCTAssertEqual(writeNames, ["mcp_notes_create_note"])
    }

    func testCallsWorkOverEventStreamsAndRecoverAnExpiredSession() async throws {
        let (mcp, _) = registry()
        _ = try await mcp.add(name: "notes", url: "https://notes.example.test/mcp", token: nil)
        FakeMCPProtocol.eventStream = true
        FakeMCPProtocol.expireSessionOnce = true
        let outcome = await mcp.call("mcp_notes_create_note", rawArguments: #"{"text":"buy milk"}"#)
        XCTAssertTrue(outcome.succeeded, outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("called create.note with buy milk"), outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("untrusted"))
        XCTAssertEqual(FakeMCPProtocol.calls.suffix(4), ["tools/call", "initialize", "notifications/initialized", "tools/call"])
    }

    func testManagedServersReconnectWithANewTokenAndKeepTheAdminsChoices() async throws {
        let (mcp, keys) = registry()
        let first = try await mcp.connectManaged(name: "Google Ads MCP", url: "http://127.0.0.1:8765/mcp", token: "token-one")
        XCTAssertEqual(first.slug, "googleadsmcp")
        _ = try await mcp.update(id: first.id, name: nil, enabled: false, readTools: [], token: nil)

        let again = try await mcp.connectManaged(name: "Google Ads MCP", url: "http://127.0.0.1:8765/mcp", token: "token-two")
        let all = await mcp.list()
        XCTAssertEqual(all.count, 1, "the same URL reconnects the existing entry")
        XCTAssertEqual(again.id, first.id)
        XCTAssertFalse(again.enabled, "an admin's off switch survives a restart")
        XCTAssertEqual(again.readTools, [])
        XCTAssertEqual(keys.get(MCPRegistry.tokenAccount(first.id)), "token-two")
        XCTAssertEqual(FakeMCPProtocol.authorization.last, "Bearer token-two")
    }

    func testOnlySafeURLsAreAccepted() async {
        XCTAssertNotNil(MCPRegistry.validURL("https://example.test/mcp"))
        XCTAssertNotNil(MCPRegistry.validURL("http://127.0.0.1:3000/mcp"))
        XCTAssertNil(MCPRegistry.validURL("http://example.test/mcp"), "plain HTTP only for this machine")
        XCTAssertNil(MCPRegistry.validURL("https://user:pass@example.test/mcp"))
        XCTAssertNil(MCPRegistry.validURL("file:///etc/passwd"))
        let (mcp, _) = registry()
        do {
            _ = try await mcp.add(name: "x", url: "http://example.test/mcp", token: nil)
            XCTFail("added a plain-HTTP remote server")
        } catch {
            XCTAssertEqual(error as? MCPError, .badURL)
        }
    }

    func testAdminChoicesSurviveARefreshAndDisabledServersOfferNothing() async throws {
        let (mcp, _) = registry()
        let server = try await mcp.add(name: "notes", url: "https://notes.example.test/mcp", token: nil)
        _ = try await mcp.update(id: server.id, name: nil, enabled: nil, readTools: ["create.note", "not-a-tool"], token: nil)
        let refreshed = await mcp.refresh(id: server.id)
        XCTAssertEqual(refreshed?.readTools, ["create.note"], "the admin unmarked search_notes and marked create.note; unknown names drop")
        _ = try await mcp.update(id: server.id, name: nil, enabled: false, readTools: nil, token: nil)
        let defs = await mcp.toolDefs()
        let owns = await mcp.owns("mcp_notes_create_note")
        XCTAssertTrue(defs.isEmpty)
        XCTAssertFalse(owns)
        let removed = await mcp.remove(id: server.id)
        XCTAssertTrue(removed)
    }

    func testStandingPermissionsKeepMCPRules() async {
        let permissions = PermissionStore(root: directory)
        await permissions.save(ownerID: "owner", policy: PermissionPolicy(rules: ["mcp_notes_create_note": PermissionRule(mode: .allow, maxPerDay: 3)]))
        let rules = await permissions.policy(ownerID: "owner").rules
        XCTAssertEqual(rules["mcp_notes_create_note"]?.maxPerDay, 3)
    }

    // MARK: Through the conversation engine

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    private func run(tool: String, arguments: String, rule: PermissionRule? = nil) async throws -> (results: [String], actions: [AgentActionRequest]) {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let (mcp, _) = registry()
        _ = try await mcp.add(name: "notes", url: "https://notes.example.test/mcp", token: nil)
        let access = ConversationAccess(root: directory, mcp: mcp)
        if let rule { await access.permissions.save(ownerID: "owner", policy: PermissionPolicy(rules: [tool: rule])) }
        let conversations = ConversationStore(root: directory)
        let results = LockedStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if let result = messages.last(where: { $0.role == "tool" }) {
                results.append(contentsOf: [result.content ?? ""])
                return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "m", function: .init(name: tool, arguments: arguments))]), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Use my notes", launchedBy: "Owner", language: "en")
        for _ in 0..<250 {
            if let current = try await conversations.get(id: conversation.id, ownerID: "owner"), current.messages.last?.status != .running { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let actions = await access.actions.list(ownerID: "owner", conversationID: conversation.id)
        await engine.shutdown()
        return (results.values, actions)
    }

    func testReadToolsRunAtOnceAndWritesWaitForApproval() async throws {
        let read = try await run(tool: "mcp_notes_search_notes", arguments: #"{"q":"milk"}"#)
        XCTAssertTrue(read.results.first?.contains("called search_notes with milk") == true, read.results.description)
        XCTAssertTrue(read.actions.isEmpty)

        FakeMCPProtocol.calls = []
        let write = try await run(tool: "mcp_notes_create_note", arguments: #"{"text":"buy milk"}"#)
        XCTAssertTrue(write.results.first?.contains("Approval requested") == true, write.results.description)
        XCTAssertFalse(FakeMCPProtocol.calls.contains("tools/call"), "nothing is sent before approval")
        XCTAssertEqual(write.actions.first?.kind, .mcpCall)
        XCTAssertEqual(write.actions.first?.status, .pending)
    }

    func testStandingPermissionRunsAnMCPWrite() async throws {
        let write = try await run(tool: "mcp_notes_create_note", arguments: #"{"text":"buy milk"}"#, rule: PermissionRule(mode: .allow))
        XCTAssertTrue(write.results.first?.contains("called create.note with buy milk") == true, write.results.description)
        XCTAssertEqual(write.actions.first?.automatic, true)
    }
}
