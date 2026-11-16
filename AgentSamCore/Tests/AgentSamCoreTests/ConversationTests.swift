import XCTest
@testable import AgentSamCore

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

    private func engine(_ store: MissionStore, _ conversations: ConversationStore, _ memory: WorkspaceMemoryStore, keys: FileKeyRing, completion: @escaping ConversationEngine.Completion, missionRunner: ConversationEngine.MissionRunner? = nil) -> ConversationEngine {
        let missions = MissionEngine(store: store, keyRing: keys)
        return ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, missions: missions, completion: completion, missionRunner: missionRunner)
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
        let hub = ConnectorHub(store: store, keyRing: keys, session: URLSession(configuration: configuration), google: GoogleOAuth(clientID: "", clientSecret: ""))
        CapturingURLProtocol.handler = { request in
            XCTFail("An external connector ran before approval: \(request.url?.absoluteString ?? "")")
            return (HTTPURLResponse(url: try! XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        defer { CapturingURLProtocol.handler = nil }
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let access = ConversationAccess(root: directory)
        let missions = MissionEngine(store: store, keyRing: keys)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, connectors: hub, missions: missions, access: access, completion: { _, _, _, system, messages, _ in
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
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, workspace: workspace, keyRing: keys, missions: MissionEngine(store: store, keyRing: keys), access: access, completion: { _, _, _, system, messages, _ in
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
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, workspace: workspace, keyRing: keys, missions: MissionEngine(store: store, keyRing: keys), access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if messages.allSatisfy({ $0.role != "tool" }) {
                let calls = (0..<5).map { index in
                    APIToolCall(id: "terminal-\(index)", function: .init(name: "run_terminal", arguments: #"{"command":"true"}"#))
                } + [APIToolCall(id: "files", function: .init(name: "project_list_files", arguments: "{}"))]
                return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: calls), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let outputs = messages.filter { $0.role == "tool" }.compactMap(\.content)
            XCTAssertEqual(outputs.count, 6)
            XCTAssertTrue(outputs[4].contains("run limit reached"), outputs[4])
            XCTAssertTrue(outputs[5].contains("shared project workspace is empty"), outputs[5])
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

    func testActivityRemainsStableBetweenMissionEventUpdates() async throws {
        actor Recorder {
            var snapshots: [[AgentActivity]] = []
            func record(_ activity: [AgentActivity]) { snapshots.append(activity) }
        }
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let research = team("Research")
        await store.saveTeam(research)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant("{\"action\":\"ROUTE_TEAM\",\"teamIDs\":[\"\(research.id.uuidString)\"]}"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("One answer."), inputTokens: 0, outputTokens: 0, model: "stub")
        }, missionRunner: { team, objective, _, _, _ in
            var mission = await store.createMission(team: team, objective: objective)
            mission.status = .running
            await store.saveMission(mission)
            await store.appendEvent(mission.id, kind: .taskStarted, agent: team.workers[0], text: "Reviewing the evidence")
            let missionID = mission.id
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard var finished = await store.mission(id: missionID) else { return }
                finished.status = .completed
                finished.phase = .done
                finished.finalReport = "Findings"
                await store.saveMission(finished)
            }
            return mission
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Investigate", launchedBy: "Owner", language: "en")
        let recorder = Recorder()
        for _ in 0..<35 {
            if let current = try await conversations.get(id: conversation.id, ownerID: "owner") {
                await recorder.record(current.messages.last?.activity ?? [])
                if current.messages.last?.status != .running { break }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let snapshots = await recorder.snapshots
        XCTAssertTrue(snapshots.contains(where: { activity in activity.contains(where: { $0.agentName == "Scout" && $0.summary == "Reviewing the evidence" && $0.state == "working" }) }))
        XCTAssertFalse(snapshots.contains(where: { activity in activity.contains(where: { $0.agentName == "Scout" && $0.summary == "Waiting for an assignment" && $0.state == "idle" }) }))
        _ = try await finishedConversation(conversations, id: conversation.id)
        await engine.shutdown()
    }

    func testMultipleTeamsProduceOneConsolidatedMessage() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let teams = [team("Research"), team("Writing")]
        for team in teams { await store.saveTeam(team) }
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let ids = teams.map(\.id)
        let root = directory!
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                let json = "{\"action\":\"ROUTE_TEAM\",\"teamIDs\":[\"\(ids[0].uuidString)\",\"\(ids[1].uuidString)\"]}"
                return LLMReply(message: .assistant(json), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("compacted workspace Markdown memory") {
                return LLMReply(message: .assistant("## Projects\n- A shared project."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("One answer from Ada."), inputTokens: 0, outputTokens: 0, model: "stub")
        }, missionRunner: { team, objective, _, _, _ in
            let store = MissionStore(root: root)
            var mission = await store.createMission(team: team, objective: objective)
            mission.status = .completed
            mission.phase = .done
            mission.finalReport = "\(team.name) findings"
            await store.saveMission(mission)
            return mission
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Research and summarize this", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(result.messages.last?.text, "One answer from Ada.")
        XCTAssertEqual(result.messages.last?.missionIDs.count, 2)
        XCTAssertEqual(result.messages.last?.teamIDs, ids)
        await engine.shutdown()
    }

    func testProposalIsValidatedWithoutMutatingTeam() throws {
        let existing = team("Research")
        let draft = TeamProposalDraft(baseTeamID: existing.id, name: "Research v2", goal: "Deeper research", agents: existing.agents)
        let proposal = try TeamProposalValidation.make(draft: draft, teams: [existing], providers: [provider])
        let validated = try TeamProposalValidation.validate(proposal, teams: [existing], providers: [provider])
        XCTAssertEqual(validated.id, existing.id)
        XCTAssertEqual(validated.createdAt, existing.createdAt)
        XCTAssertEqual(validated.toolScope?.permissions.sendEmail, false)
        let bad = TeamProposalDraft(name: "Invalid", goal: "Unknown models", agents: [AgentProfile(name: "Ada", emoji: "•", title: "Lead", role: .coordinator, systemPrompt: "Lead", providerID: "test", model: "not-configured"), agent("Worker", role: .worker)])
        XCTAssertThrowsError(try TeamProposalValidation.make(draft: bad, teams: [], providers: [provider]))
    }

    func testProposalRejectsDuplicateAgentIDs() throws {
        let existing = team("Research")
        var agents = existing.agents
        agents[1].id = agents[0].id
        let draft = TeamProposalDraft(baseTeamID: existing.id, name: "Research v2", goal: existing.goal, agents: agents)
        XCTAssertThrowsError(try TeamProposalValidation.make(draft: draft, teams: [existing], providers: [provider])) { error in
            XCTAssertEqual((error as? ConversationError)?.errorDescription, "The coordinator must be named Ada, and agent names and IDs must remain unique.")
        }
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
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
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

    func testSoloRunsAsAMissionWithAdaAsWorkerAndProducesFiles() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let root = directory!
        let engine = engine(store, conversations, memory, keys: keys, completion: { _, _, _, system, messages, _ in
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"SOLO"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.contains(where: { ($0.content ?? "").contains("Produce one unified response") }) {
                return LLMReply(message: .assistant("Here is what I made."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("planning"), inputTokens: 0, outputTokens: 0, model: "stub")
        }, missionRunner: { team, objective, _, _, _ in
            // The solo team: Ada as coordinator and her worker copy, exactly one worker.
            XCTAssertEqual(team.workers.count, 1)
            XCTAssertEqual(team.coordinator?.name, "Ada")
            XCTAssertEqual(team.workers.first?.name, "Ada")
            XCTAssertEqual(team.id, ConversationEngine.soloTeamID)
            // The solo team is persisted so its missions resolve in the UI.
            let saved = await store.team(id: team.id)
            XCTAssertNotNil(saved)
            let store = MissionStore(root: root)
            var mission = await store.createMission(team: team, objective: objective)
            mission.status = .completed
            mission.phase = .done
            mission.finalReport = "Solo report"
            await store.saveMission(mission)
            return mission
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Build and verify a page yourself", launchedBy: "Owner", language: "en")
        let result = try await finishedConversation(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "Here is what I made.")
        XCTAssertEqual(answer.missionIDs.count, 1)
        XCTAssertEqual(answer.teamIDs, [ConversationEngine.soloTeamID])
        // The solo mission is linked and its activity shows Ada doing the work.
        XCTAssertTrue(answer.activity.contains { $0.agentName == "Ada" && $0.summary == "Work completed" })
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
        await store.saveTeam(ConversationEngine.soloTeam(coordinator: ada, language: "en"))
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
                XCTAssertTrue(system.contains("Project: Website"))
                XCTAssertTrue(system.contains("site/index.html — 12"))
                XCTAssertTrue(system.contains(missionID.uuidString))
                XCTAssertTrue(system.contains("Recurring hourly"))
                XCTAssertTrue(ada.systemPrompt.contains("smallest action"))
                XCTAssertFalse(system.contains("Team-only persona"))
                XCTAssertFalse(system.contains("Revise the saved page"))
                XCTAssertEqual(messages.last?.content, "Revise the saved page")
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
        XCTAssertTrue(edited.contains("Project: Personal"))
    }

    func testDirectAnswerCompactsLargeExecutedToolPayloads() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let large = String(repeating: "x", count: 90_000)
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
