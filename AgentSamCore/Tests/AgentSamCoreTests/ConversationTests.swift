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
            XCTAssertTrue(tools?.isEmpty ?? true)
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
        let memoryState = await memory.state()
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
            if system.contains("platform-wide Markdown memory") {
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
        let compacted = await memory.state()
        XCTAssertEqual(compacted.compactionCount, 1)
        _ = try await memory.setEnabled(false)
        let paused = try await memory.record(conversationID: conversation.id, ownerID: "owner", userMessage: user, assistantMessage: assistant)
        XCTAssertNil(paused)
        let pausedState = await memory.state()
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
    }
}
