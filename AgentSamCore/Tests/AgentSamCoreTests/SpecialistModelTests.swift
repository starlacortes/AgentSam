import XCTest
@testable import AgentSamCore

/// Which model Ada's specialists run on, and when judgeAda's check is skipped.
final class SpecialistModelTests: XCTestCase {
    private var directory: URL!
    private let deepseek = ProviderConfig(id: "deepseek", name: "DeepSeek", kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1", models: ["deepseek-v4-pro", "deepseek-chat"], defaultModel: "deepseek-v4-pro")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("specialist-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func ada(_ provider: String, _ model: String) -> AgentProfile {
        var profile = AgentProfile.rosterTemplates[0]
        profile.providerID = provider
        profile.model = model
        return profile
    }

    func testSpecialistsUseTheProvidersFlashModelAndTheJudgeKeepsAdasModel() {
        let main = ada("deepseek", "deepseek-v4-pro")
        // DeepSeek's own API: its flash model, even when the saved model list predates it.
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "research", providers: [deepseek], override: nil).model, "deepseek-flash")
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "price check", providers: [deepseek], override: nil).providerID, "deepseek")
        // The built-in provider lists the flash model.
        XCTAssertTrue(ProviderConfig.builtin.first { $0.id == "deepseek" }?.models.contains(ConversationEngine.deepSeekFlashModel) == true)
        // judgeAda checks with Ada's own model, however the function is written.
        for function in ["judge", "Judge", "judgeAda"] {
            XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: function, providers: [deepseek], override: nil), main)
        }
        // Another provider with a flash model in its list uses that one.
        let greenpt = ProviderConfig.builtin.first { $0.id == "greenpt" }!
        XCTAssertEqual(ConversationEngine.specialistProfile(for: ada("greenpt", "glm-5.3"), function: "write", providers: [greenpt], override: nil).model, "glm-5.3-flash")
        // A provider with no flash model, an unknown provider, or Ada already on flash: no change.
        let anthropic = ProviderConfig.builtin.first { $0.id == "anthropic" }!
        XCTAssertEqual(ConversationEngine.specialistProfile(for: ada("anthropic", "claude-sonnet-4-5"), function: "research", providers: [anthropic], override: nil).model, "claude-sonnet-4-5")
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "research", providers: [], override: nil), main)
        XCTAssertEqual(ConversationEngine.specialistProfile(for: ada("deepseek", "deepseek-flash"), function: "research", providers: [deepseek], override: nil).model, "deepseek-flash")
        // A proxy that only looks like DeepSeek by ID is not assumed to know the flash name.
        let proxy = ProviderConfig(id: "deepseek", name: "Proxy", kind: .openAICompatible, baseURL: "https://llm.example.com/v1", models: ["deepseek-v4-pro"], defaultModel: "deepseek-v4-pro")
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "research", providers: [proxy], override: nil).model, "deepseek-v4-pro")
        // The server setting wins: "main" keeps Ada's model, anything else names the model. Never for the judge.
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "research", providers: [deepseek], override: "main").model, "deepseek-v4-pro")
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "research", providers: [deepseek], override: "deepseek-chat").model, "deepseek-chat")
        XCTAssertEqual(ConversationEngine.specialistProfile(for: main, function: "judge", providers: [deepseek], override: "deepseek-chat").model, "deepseek-v4-pro")
        // The flash model has the large window, so a long specialist run is not trimmed early.
        XCTAssertEqual(ModelLimits.contextWindow(model: "deepseek-flash"), 1_000_000)
    }

    func testOnlyAPlannedOneStepJobSkipsTheJudge() {
        XCTAssertFalse(TaskTools.needsJudge(planned: true, steps: 1))
        XCTAssertTrue(TaskTools.needsJudge(planned: true, steps: 2))
        XCTAssertTrue(TaskTools.needsJudge(planned: true, steps: 4))
        // Planning failed and one specialist does everything: that is not a small job, so it is checked.
        XCTAssertTrue(TaskTools.needsJudge(planned: false, steps: 1))
        let skipped = TaskTools.finalReport(objective: "Do it", reports: [("writeAda", "Wrote it.")], verdict: nil, check: "", files: ["a.md"])
        XCTAssertTrue(skipped.contains("Not checked by judgeAda"), skipped)
        XCTAssertFalse(skipped.contains("Check by judgeAda:"), skipped)
        let checked = TaskTools.finalReport(objective: "Do it", reports: [("writeAda", "Wrote it.")], verdict: .clean, check: "All good.", files: [])
        XCTAssertTrue(checked.contains("## Check by judgeAda: CLEAN\n\nAll good."), checked)
    }

    /// The models each kind of call ran on, recorded by the stubbed provider.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [String: [String]] = [:]
        func add(_ who: String, _ model: String) { lock.withLock { models[who, default: []].append(model) } }
        func models(_ who: String) -> [String] { lock.withLock { models[who] ?? [] } }
    }

    private func who(_ system: String) -> String {
        for name in ["researchAda", "writeAda", "judgeAda"] where system.contains("You are \(name)") { return name }
        if system.contains("planning a") { return "plan" }
        if system.contains("Summarize only durable") { return "memory" }
        return "ada"
    }

    private func makeEngine(completion: @escaping ConversationEngine.Completion) async throws -> (ConversationEngine, ConversationStore, MissionStore) {
        let store = MissionStore(root: directory)
        await store.saveProviders([deepseek])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: deepseek.keyAccount)
        let conversations = ConversationStore(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, routing: false, completion: completion)
        return (engine, conversations, store)
    }

    private func finished(_ conversations: ConversationStore, id: UUID) async throws -> Conversation {
        for _ in 0..<250 {
            if let conversation = try await conversations.get(id: id, ownerID: "owner"), conversation.messages.last?.status != .running { return conversation }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Conversation did not finish")
        return try await conversations.get(id: id, ownerID: "owner")!
    }

    private func reply(_ text: String) -> LLMReply { LLMReply(message: .assistant(text), inputTokens: 0, outputTokens: 0, model: "stub") }
    private func calling(_ name: String, _ arguments: String) -> LLMReply {
        LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: UUID().uuidString, function: .init(name: name, arguments: arguments))]), inputTokens: 0, outputTokens: 0, model: "stub")
    }

    func testAJobRunsItsSpecialistsOnFlashAndItsJudgeOnAdasModel() async throws {
        let seen = Seen()
        let (engine, conversations, store) = try await makeEngine { [self] _, _, profile, system, messages, _ in
            let name = who(system)
            seen.add(name, profile.model)
            let toolResults = messages.filter { $0.role == "tool" }
            switch name {
            case "memory": return reply("## Notes")
            case "plan": return calling("plan_steps", #"{"steps":[{"function":"research","task":"Find the facts"},{"function":"write","task":"Write them up"}]}"#)
            case "researchAda": return reply("Found three facts.")
            case "writeAda": return reply("Wrote them up.")
            case "judgeAda": return reply("PASS\nVERDICT: PASS")
            default:
                if toolResults.isEmpty { return calling("start_task", #"{"objective":"Research and write a brief"}"#) }
                return reply("Here is the brief.")
            }
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Research and write a brief", launchedBy: "Owner", language: "en")
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "Here is the brief.")
        XCTAssertEqual(seen.models("ada"), ["deepseek-v4-pro", "deepseek-v4-pro"])
        XCTAssertEqual(seen.models("plan"), ["deepseek-v4-pro"])
        XCTAssertEqual(seen.models("researchAda"), ["deepseek-flash"])
        XCTAssertEqual(seen.models("writeAda"), ["deepseek-flash"])
        XCTAssertEqual(seen.models("judgeAda"), ["deepseek-v4-pro"], "the check keeps Ada's model")
        let missionID = try XCTUnwrap(result.messages.last?.missionIDs.first)
        let events = await store.events(missionID: missionID, afterSeq: 0)
        XCTAssertEqual(events.first { $0.kind == .verifyVerdict }?.text, "CLEAN")
        await engine.shutdown()
    }

    func testAOneStepJobSkipsTheJudge() async throws {
        let seen = Seen()
        let (engine, conversations, store) = try await makeEngine { [self] _, _, profile, system, messages, _ in
            let name = who(system)
            seen.add(name, profile.model)
            let toolResults = messages.filter { $0.role == "tool" }.compactMap(\.content)
            switch name {
            case "memory": return reply("## Notes")
            case "plan": return calling("plan_steps", #"{"steps":[{"function":"write","task":"Write the note"}]}"#)
            case "writeAda": return reply("Wrote the note.")
            case "judgeAda":
                XCTFail("a one-step job is not checked by judgeAda")
                return reply("VERDICT: PASS")
            default:
                if toolResults.isEmpty { return calling("start_task", #"{"objective":"Write a short note"}"#) }
                XCTAssertTrue(toolResults[0].contains("Wrote the note."), toolResults[0])
                XCTAssertTrue(toolResults[0].contains("Not checked by judgeAda"), toolResults[0])
                return reply("The note is written.")
            }
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Write a short note", launchedBy: "Owner", language: "en")
        let result = try await finished(conversations, id: conversation.id)
        let answer = try XCTUnwrap(result.messages.last)
        XCTAssertEqual(answer.text, "The note is written.")
        XCTAssertTrue(seen.models("judgeAda").isEmpty)
        XCTAssertEqual(answer.activity.filter { $0.teamName == HelperTools.activityLabel }.map(\.agentName), ["writeAda"])
        let missionID = try XCTUnwrap(answer.missionIDs.first)
        let stored = await store.mission(id: missionID)
        XCTAssertEqual(stored?.status, .completed)
        let events = await store.events(missionID: missionID, afterSeq: 0)
        XCTAssertNil(events.first { $0.kind == .verifyVerdict })
        XCTAssertTrue(events.contains { $0.kind == .notice && $0.text?.contains("One-step job") == true })
        XCTAssertEqual(events.last?.kind, .missionEnd)
        let deliverables = Set(await store.deliverables(missionID: missionID))
        XCTAssertTrue(deliverables.contains("final-report.md"))
        XCTAssertFalse(deliverables.contains("verification.md"))
        await engine.shutdown()
    }

    func testASpecialistFallsBackToAdasModelWhenTheProviderRefusesFlash() async throws {
        let seen = Seen()
        let (engine, conversations, _) = try await makeEngine { [self] _, _, profile, system, messages, _ in
            let name = who(system)
            seen.add(name, profile.model)
            switch name {
            case "memory": return reply("## Notes")
            case "researchAda":
                if profile.model == "deepseek-flash" { throw LLMError(message: "HTTP 400: Model Not Exist", statusCode: 400) }
                return reply("Found it on the main model.")
            default:
                let toolResults = messages.filter { $0.role == "tool" }.compactMap(\.content)
                if toolResults.isEmpty { return calling("delegate", #"{"function":"research","task":"Find the launch date"}"#) }
                XCTAssertTrue(toolResults[0].contains("Found it on the main model."), toolResults[0])
                return reply("It launched in May.")
            }
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "When did it launch?", launchedBy: "Owner", language: "en")
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "It launched in May.")
        XCTAssertEqual(seen.models("researchAda"), ["deepseek-flash", "deepseek-v4-pro"])
        await engine.shutdown()
    }
}
