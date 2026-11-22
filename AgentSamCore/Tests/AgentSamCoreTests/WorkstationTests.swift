import XCTest
@testable import AgentSamCore

final class WorkstationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-workstation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func machine(enabled: Bool = true) -> Workstation {
        Workstation(config: WorkstationConfig(enabled: enabled, home: directory), dataDir: directory.appendingPathComponent("data"))
    }

    func testConfigIsOffUnlessTurnedOn() {
        XCTAssertFalse(WorkstationConfig.fromEnvironment([:]).enabled)
        XCTAssertTrue(WorkstationConfig.fromEnvironment(["AGENTSAM_WORKSTATION": "1", "AGENTSAM_WORKSTATION_HOME": "/srv/ada"]).enabled)
        XCTAssertEqual(WorkstationConfig.fromEnvironment(["AGENTSAM_WORKSTATION": "1", "AGENTSAM_WORKSTATION_HOME": "/srv/ada"]).home.path, "/srv/ada")
    }

    func testCommandPrefixesMatchWholeWordsAndOneCommandOnly() {
        let prefixes = ["pacman -Q", "systemctl status"]
        XCTAssertTrue(WorkstationTools.matchesPrefix("pacman -Q", prefixes: prefixes))
        XCTAssertTrue(WorkstationTools.matchesPrefix("systemctl status nginx", prefixes: prefixes))
        XCTAssertFalse(WorkstationTools.matchesPrefix("pacman -Qu", prefixes: prefixes), "a prefix is a whole word")
        XCTAssertFalse(WorkstationTools.matchesPrefix("pacman -Syu", prefixes: prefixes))
        for sneaky in ["pacman -Q; rm -rf ~", "pacman -Q && reboot", "pacman -Q | sh", "pacman -Q $(reboot)", "pacman -Q `reboot`", "pacman -Q > /etc/passwd", "pacman -Q\nreboot"] {
            XCTAssertFalse(WorkstationTools.matchesPrefix(sneaky, prefixes: prefixes), sneaky)
        }
    }

    func testStandingPermissionWithPrefixesAllowsOnlyMatchingCommands() async {
        let permissions = PermissionStore(root: directory)
        XCTAssertTrue(PermissionStore.ruleTools.contains("workstation_run"))
        XCTAssertTrue(PermissionStore.ruleTools.contains("workstation_start_job"))
        await permissions.save(ownerID: "owner", policy: PermissionPolicy(rules: ["workstation_run": PermissionRule(mode: .allow, commandPrefixes: [" pacman -Q ", ""])]))
        let saved = await permissions.policy(ownerID: "owner").rules["workstation_run"]?.commandPrefixes
        XCTAssertEqual(saved, ["pacman -Q"])
        let allowed = await permissions.decide(ownerID: "owner", toolName: "workstation_run", arguments: ["command": .string("pacman -Q linux")])
        XCTAssertEqual(allowed, .allow("allowed by your workstation_run rule"))
        let asked = await permissions.decide(ownerID: "owner", toolName: "workstation_run", arguments: ["command": .string("pacman -Rns linux")])
        guard case .ask(let reason) = asked else { return XCTFail("expected ask, got \(asked)") }
        XCTAssertTrue(reason?.contains("allowed prefix") == true)
    }

    func testOffMachineRunsNothing() async {
        let off = machine(enabled: false)
        let outcome = await off.run(command: "touch should-not-exist", directory: nil, timeout: 5)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
    }

    func testRunsCommandsWithAScrubbedEnvironment() async throws {
        #if os(Linux) || os(macOS)
        setenv("AGENTSAM_WORKSTATION_TEST_SECRET", "do-not-leak", 1)
        defer { unsetenv("AGENTSAM_WORKSTATION_TEST_SECRET") }
        let outcome = await machine().run(command: "echo hello-from-ada; env", directory: nil, timeout: 10)
        XCTAssertTrue(outcome.succeeded, outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("hello-from-ada"))
        XCTAssertFalse(outcome.resultText.contains("do-not-leak"), "server secrets never reach a command")
        let missing = await machine().run(command: "true", directory: "/no/such/dir", timeout: 5)
        XCTAssertFalse(missing.succeeded)
        #endif
    }

    func testBackgroundJobsFinishAndStop() async throws {
        #if os(Linux) || os(macOS)
        let ws = machine()
        let started = await ws.startJob(command: "echo job-output", directory: nil, label: "echo")
        XCTAssertTrue(started.succeeded, started.resultText)
        var jobs = await ws.listJobs()
        var job = try XCTUnwrap(jobs.first)
        for _ in 0..<100 where job.state == .running {
            try await Task.sleep(nanoseconds: 50_000_000)
            jobs = await ws.listJobs()
            job = try XCTUnwrap(jobs.first)
        }
        XCTAssertEqual(job.state, .exited)
        XCTAssertEqual(job.exitCode, 0)
        let shown = await ws.job(id: job.id)
        XCTAssertTrue(shown.resultText.contains("job-output"), shown.resultText)

        _ = await ws.startJob(command: "sleep 60", directory: nil, label: "sleeper")
        jobs = await ws.listJobs()
        let sleeper = try XCTUnwrap(jobs.first { $0.label == "sleeper" })
        let stopped = await ws.stopJob(id: sleeper.id)
        XCTAssertTrue(stopped.resultText.contains("Stopped"), stopped.resultText)
        jobs = await ws.listJobs()
        XCTAssertEqual(jobs.first { $0.id == sleeper.id }?.state, .stopped)
        #endif
    }

    func testToolsAreOfferedOnlyWithTheWorkstation() {
        let without = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: true)
        XCTAssertNil(without.family(of: "workstation_run"))
        let with = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: true, hasWorkstation: true)
        for name in WorkstationTools.names { XCTAssertEqual(with.family(of: name), .workstation, name) }
        for def in WorkstationTools.definitions { XCTAssertNotNil(ToolCatalog.spec(def.function.name), def.function.name) }
    }

    // MARK: Through the conversation engine

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    private func engine(command: String, ownerAllowed: Bool, rule: PermissionRule? = nil) async throws -> (ConversationEngine, ConversationStore, ConversationAccess, LockedStrings) {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let access = ConversationAccess(root: directory, workstation: machine(), workstationOwner: { _ in ownerAllowed })
        if let rule { await access.permissions.save(ownerID: "owner", policy: PermissionPolicy(rules: ["workstation_run": rule])) }
        let conversations = ConversationStore(root: directory)
        let results = LockedStrings()
        let arguments = String(data: try JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, missions: MissionEngine(store: store, keyRing: keys), access: access, completion: { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if let tool = messages.last(where: { $0.role == "tool" }) {
                results.append(contentsOf: [tool.content ?? ""])
                return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "ws", function: .init(name: "workstation_run", arguments: arguments))]), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        return (engine, conversations, access, results)
    }

    private func send(_ engine: ConversationEngine, _ conversations: ConversationStore) async throws -> UUID {
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Check the machine", launchedBy: "Owner", language: "en")
        for _ in 0..<250 {
            if let current = try await conversations.get(id: conversation.id, ownerID: "owner"), current.messages.last?.status != .running { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return conversation.id
    }

    func testWorkstationCommandsNeedApprovalByDefault() async throws {
        let (engine, conversations, access, results) = try await engine(command: "touch approved-only", ownerAllowed: true)
        let id = try await send(engine, conversations)
        XCTAssertTrue(results.values.first?.contains("Approval requested") == true, results.values.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("approved-only").path), "nothing runs before approval")
        let actions = await access.actions.list(ownerID: "owner", conversationID: id)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.kind, .workstation)
        XCTAssertEqual(action.status, .pending)
        await engine.shutdown()
    }

    func testStandingPermissionRunsMatchingCommands() async throws {
        #if os(Linux) || os(macOS)
        let (engine, conversations, access, results) = try await engine(command: "echo allowed-run", ownerAllowed: true, rule: PermissionRule(mode: .allow, commandPrefixes: ["echo"]))
        let id = try await send(engine, conversations)
        XCTAssertTrue(results.values.first?.contains("allowed-run") == true, results.values.description)
        let actions = await access.actions.list(ownerID: "owner", conversationID: id)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.automatic, true)
        XCTAssertEqual(action.status, .completed)
        await engine.shutdown()
        #endif
    }

    func testNonAdminsAreNotOfferedTheWorkstation() async throws {
        let (engine, conversations, access, results) = try await engine(command: "touch never", ownerAllowed: false)
        let id = try await send(engine, conversations)
        XCTAssertFalse(results.values.first?.contains("Approval requested") == true, results.values.description)
        let actions = await access.actions.list(ownerID: "owner", conversationID: id)
        XCTAssertTrue(actions.isEmpty)
        await engine.shutdown()
    }
}
