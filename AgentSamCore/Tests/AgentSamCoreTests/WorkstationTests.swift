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

    // MARK: Over SSH

    func testSSHDestinationsAreOnlyPlainUserAtHost() {
        XCTAssertTrue(SSHTarget.valid("ada@kokoro.example.com"))
        XCTAssertTrue(SSHTarget.valid("arch@203.0.113.5"))
        for bad in ["kokoro", "-oProxyCommand=x@host", "ada@-host", "ada@host;reboot", "a b@host", "@host", "ada@"] {
            XCTAssertFalse(SSHTarget.valid(bad), bad)
        }
        let config = WorkstationConfig.fromEnvironment(["AGENTSAM_WORKSTATION_SSH": "ada@kokoro.example.com", "AGENTSAM_WORKSTATION_SSH_PORT": "2222"])
        XCTAssertTrue(config.enabled, "naming a machine turns the workstation on")
        XCTAssertEqual(config.ssh?.port, 2222)
        let bad = WorkstationConfig.fromEnvironment(["AGENTSAM_WORKSTATION_SSH": "-oProxyCommand=evil", "AGENTSAM_WORKSTATION": "1"])
        XCTAssertFalse(bad.enabled)
        XCTAssertNotNil(bad.problem)
    }

    func testSSHArgumentsPinTheHostKey() async {
        let data = directory.appendingPathComponent("data")
        let target = SSHTarget(destination: "ada@kokoro.example.com", port: 2222, hostKey: "ssh-ed25519 AAAAC3Nza")
        let pinned = Workstation(config: WorkstationConfig(enabled: true, home: directory, ssh: target), dataDir: data)
        let args = await pinned.sshArguments(target, script: "echo 'hi'")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(Array(args.suffix(3)), ["--", "ada@kokoro.example.com", "sh -c " + Workstation.quoted("echo 'hi'")])
        let known = try? String(contentsOf: data.appendingPathComponent("workstation/ssh/known_hosts"), encoding: .utf8)
        XCTAssertEqual(known, "[kokoro.example.com]:2222 ssh-ed25519 AAAAC3Nza\n")
        let firstUse = await pinned.sshArguments(SSHTarget(destination: "ada@kokoro.example.com"), script: "true")
        XCTAssertTrue(firstUse.contains("StrictHostKeyChecking=accept-new"), "without a pinned key, the first one seen is remembered")
    }

    /// A stand-in for ssh that runs the remote script here, with its own home folder.
    private func sshMachine() throws -> Workstation {
        let remoteHome = directory.appendingPathComponent("remote-home")
        try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        let fake = directory.appendingPathComponent("fake-ssh")
        let script = [
            "#!/bin/bash",
            // Like sshd, hand the remote command no descriptors but stdin, stdout and stderr.
            "for fd in $(ls /proc/$$/fd 2>/dev/null); do [ \"$fd\" -gt 2 ] && eval \"exec $fd>&-\" 2>/dev/null; done",
            "while [ \"$1\" != \"--\" ]; do shift; done",
            "shift; shift",
            "export HOME=\(Workstation.quoted(remoteHome.path))",
            "cd \"$HOME\"",
            "exec sh -c \"$1\"",
        ].joined(separator: "\n") + "\n"
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let data = directory.appendingPathComponent("data")
        let keyDirectory = data.appendingPathComponent("workstation/ssh")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        try "fake key".write(to: keyDirectory.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAAfake ada@agentsam".write(to: keyDirectory.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        return Workstation(config: WorkstationConfig(enabled: true, home: directory, ssh: SSHTarget(destination: "ada@kokoro.example.com", binary: fake.path)), dataDir: data)
    }

    func testRunsAndJobsOverSSH() async throws {
        #if os(Linux) || os(macOS)
        let ws = try sshMachine()
        let publicKey = await ws.publicKey()
        XCTAssertEqual(publicKey, "ssh-ed25519 AAAAfake ada@agentsam")
        let run = await ws.run(command: "echo remote-$((1+1)); pwd", directory: nil, timeout: 10)
        XCTAssertTrue(run.succeeded, run.resultText)
        XCTAssertTrue(run.resultText.contains("remote-2"), run.resultText)
        XCTAssertTrue(run.resultText.contains("remote-home"), run.resultText)
        XCTAssertTrue(run.resultText.contains("ada@kokoro.example.com over SSH"))
        let missing = await ws.run(command: "true", directory: "/no/such/dir", timeout: 5)
        XCTAssertFalse(missing.succeeded)
        XCTAssertTrue(missing.resultText.contains("does not exist"), missing.resultText)

        let started = await ws.startJob(command: "echo remote-job; exit 3", directory: nil, label: "remote")
        XCTAssertTrue(started.succeeded, started.resultText)
        var jobs = await ws.listJobs()
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.remote, true)
        var shown = await ws.job(id: job.id)
        for _ in 0..<100 where shown.resultText.contains("· running") {
            try await Task.sleep(nanoseconds: 50_000_000)
            shown = await ws.job(id: job.id)
        }
        XCTAssertTrue(shown.resultText.contains("exited, exit code 3"), shown.resultText)
        XCTAssertTrue(shown.resultText.contains("remote-job"), shown.resultText)

        _ = await ws.startJob(command: "sleep 60", directory: nil, label: "remote-sleeper")
        jobs = await ws.listJobs()
        let sleeper = try XCTUnwrap(jobs.first { $0.label == "remote-sleeper" })
        let stopped = await ws.stopJob(id: sleeper.id)
        XCTAssertTrue(stopped.resultText.contains("Stopped"), stopped.resultText)
        let gone = await ws.run(command: "if \(Workstation.alive(sleeper.pid)); then echo still-alive; else echo really-stopped; fi", directory: nil, timeout: 5)
        XCTAssertTrue(gone.resultText.contains("really-stopped"), gone.resultText)
        #endif
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

    // MARK: Mission workers

    func testMissionWorkersAreOfferedTheWorkstationOnlyWhenAvailable() {
        let without = OfferedTools.worker(connectorTools: [])
        XCTAssertTrue(without.names.isDisjoint(with: WorkstationTools.names))
        let with = OfferedTools.worker(connectorTools: [], hasWorkstation: true)
        for name in WorkstationTools.names { XCTAssertEqual(with.family(of: name), .workstation, name) }
        XCTAssertEqual(with.family(of: "write_file"), .worker)
    }

    func testWorkerSystemExplainsTheWorkstationAndGitOnlyWhenOffered() {
        let team = Team.starterTeam()
        let mission = Mission(teamID: team.id, teamName: team.name, objective: "Publish the fix")
        let builder = PromptBuilder(store: PromptStore(builtins: PromptStore.builtins))
        let plain = builder.workerSystem(agent: team.workers[0], team: team, mission: mission)
        XCTAssertFalse(plain.contains("workstation_run"))
        let system = builder.workerSystem(agent: team.workers[0], team: team, mission: mission, hasWorkstation: true)
        XCTAssertTrue(system.contains("workstation_run"))
        XCTAssertTrue(system.contains("cat ~/GIT.md"))
        XCTAssertTrue(system.contains("pull request"))
        XCTAssertFalse(system.lowercased().contains("deploy key"))
    }

    func testWorkerRunProgramFailurePointsToTheWorkstation() {
        let failed = ToolOutcome.failure("bwrap: Permission denied")
        XCTAssertTrue(MissionEngine.workerWorkstationFallback(toolName: "run_program", outcome: failed, hasWorkstation: true).resultText.contains("workstation_run"))
        XCTAssertEqual(MissionEngine.workerWorkstationFallback(toolName: "run_program", outcome: failed, hasWorkstation: false).resultText, failed.resultText)
        let ok = ToolOutcome(resultText: "done")
        XCTAssertEqual(MissionEngine.workerWorkstationFallback(toolName: "run_program", outcome: ok, hasWorkstation: true).resultText, "done")
    }

    func testMissionActionWaitsForTheApprovedRunAndReturnsItsResult() async throws {
        let access = ConversationAccess(root: directory)
        let mission = UUID(), conversation = UUID()
        await access.actions.link(missionID: mission, conversationID: conversation, ownerID: "owner")
        let call = APIToolCall(id: "c1", function: .init(name: "workstation_run", arguments: #"{"command":"git push"}"#))
        let actions = access.actions
        // Stands in for the approve route: approve the card, run it, record the result.
        let approver = Task {
            while true {
                if let card = await actions.list(ownerID: "owner", conversationID: conversation).first(where: { $0.status == .pending }) {
                    _ = await actions.resolve(ownerID: "owner", id: card.id, approve: true)
                    _ = await actions.consumeApproved(ownerID: "owner", id: card.id)
                    await actions.finish(ownerID: "owner", id: card.id, result: "pushed fix/branch", succeeded: true)
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let outcome = await actions.awaitMissionAction(missionID: mission, kind: .workstation, call: call, title: "Run", detail: "d", pollInterval: 0.02)
        _ = try await approver.value
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.resultText.contains("pushed fix/branch"))
        let cards = await actions.list(ownerID: "owner", conversationID: conversation)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.missionID, mission)
        XCTAssertEqual(card.kind, .workstation)
    }

    func testMissionActionReportsADenialAndNeedsALinkedConversation() async throws {
        let access = ConversationAccess(root: directory)
        let call = APIToolCall(id: "c1", function: .init(name: "workstation_run", arguments: #"{"command":"ls"}"#))
        let unlinked = await access.actions.awaitMissionAction(missionID: UUID(), kind: .workstation, call: call, title: "Run", detail: "d")
        XCTAssertFalse(unlinked.succeeded)

        let mission = UUID(), conversation = UUID()
        await access.actions.link(missionID: mission, conversationID: conversation, ownerID: "owner")
        let actions = access.actions
        let denier = Task {
            while true {
                if let card = await actions.list(ownerID: "owner", conversationID: conversation).first(where: { $0.status == .pending }) {
                    _ = await actions.resolve(ownerID: "owner", id: card.id, approve: false)
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let outcome = await actions.awaitMissionAction(missionID: mission, kind: .workstation, call: call, title: "Run", detail: "d", pollInterval: 0.02)
        _ = try await denier.value
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.resultText.contains("denied"))
    }

    // MARK: Mission review

    func testTeamsWithoutAVerifierAreReviewedByTheirCoordinator() {
        let ada = AgentProfile.rosterTemplates[0]
        let solo = ConversationEngine.soloTeam(coordinator: { var a = ada; a.role = .coordinator; return a }(), language: "en")
        XCTAssertNil(solo.verifier)
        let reviewer = MissionEngine.reviewer(for: solo)
        XCTAssertEqual(reviewer?.role, .verifier)
        let starter = Team.starterTeam()
        XCTAssertEqual(MissionEngine.reviewer(for: starter)?.id, starter.verifier?.id)
    }

    func testVerifyPromptCarriesHandoffsAndJudgesOutsideGoalsFromEvidence() {
        let builder = PromptBuilder(store: PromptStore(builtins: PromptStore.builtins))
        let text = builder.verifyPrompt(deliverables: ["report.md"], handoffs: ["Ada — report.md: opened https://github.com/o/r/pull/7"])
        XCTAssertTrue(text.contains("pull/7"))
        XCTAssertTrue(text.contains("clean verdict"))
        XCTAssertFalse(text.contains("{{"))
    }
}
