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

    // MARK: One account per person

    func testPeopleGetTheirOwnAccountKeyAndJobs() async throws {
        #if os(Linux) || os(macOS)
        let operatorMachine = try sshMachine()
        let data = directory.appendingPathComponent("data")
        let alice = "1A2B3C4D-5E6F-4000-8000-000000000001"
        let bob = "9F8E7D6C-5B4A-4000-8000-000000000002"
        let aliceName = try XCTUnwrap(WorkstationPool.unixName(ownerID: alice))
        let bobName = try XCTUnwrap(WorkstationPool.unixName(ownerID: bob))
        XCTAssertEqual(aliceName, "adau1a2b3c4d5e6f")
        XCTAssertNil(WorkstationPool.unixName(ownerID: "shared-server-token"))
        XCTAssertTrue(WorkstationPool.validUnixName(aliceName))
        XCTAssertFalse(WorkstationPool.validUnixName("root"))
        XCTAssertFalse(WorkstationPool.validPublicKey("ssh-ed25519 AAAA ada@x; rm -rf /"))
        // Each person has their own key; ssh-keygen may be missing where tests run, so they are made here.
        for name in [aliceName, bobName] {
            let keys = data.appendingPathComponent("workstation/people/\(name)/workstation/ssh")
            try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
            try "fake key".write(to: keys.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
            try "ssh-ed25519 AAAA\(name) ada@agentsam".write(to: keys.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        }
        let log = directory.appendingPathComponent("provisioned.log")
        let pool = WorkstationPool(operatorMachine: operatorMachine, dataDir: data, provisionCommand: "echo >> \(Workstation.quoted(log.path))")

        guard case .success(let aliceMachine) = await pool.machine(ownerID: alice) else { return XCTFail("alice has no machine") }
        guard case .success(let again) = await pool.machine(ownerID: alice) else { return XCTFail("alice lost her machine") }
        XCTAssertTrue(aliceMachine === again)
        guard case .success(let bobMachine) = await pool.machine(ownerID: bob) else { return XCTFail("bob has no machine") }
        XCTAssertFalse(aliceMachine === bobMachine)

        // Set up once per person, as their own account with their own key.
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines, ["\(aliceName) ssh-ed25519 AAAA\(aliceName) ada@agentsam", "\(bobName) ssh-ed25519 AAAA\(bobName) ada@agentsam"])
        let arguments = await aliceMachine.sshArguments(try XCTUnwrap(aliceMachine.config.ssh), script: "true")
        XCTAssertTrue(arguments.contains("\(aliceName)@kokoro.example.com"), arguments.description)
        XCTAssertTrue(arguments.contains(where: { $0.hasSuffix("people/\(aliceName)/workstation/ssh/id_ed25519") }), arguments.description)

        // Everything a person's account creates is private to it.
        let umask = await aliceMachine.run(command: "umask", directory: nil, timeout: 10)
        XCTAssertTrue(umask.resultText.contains("0077") || umask.resultText.contains("077"), umask.resultText)

        // One person's jobs are not in another's list, and cannot be stopped from there.
        let started = await aliceMachine.startJob(command: "sleep 30", directory: nil, label: "alice-job")
        XCTAssertTrue(started.succeeded, started.resultText)
        let aliceJobs = await aliceMachine.listJobs()
        let job = try XCTUnwrap(aliceJobs.first)
        let bobJobs = await bobMachine.listJobs()
        XCTAssertTrue(bobJobs.isEmpty)
        let operatorJobs = await operatorMachine.listJobs()
        XCTAssertTrue(operatorJobs.isEmpty)
        let refused = await bobMachine.stopJob(id: job.id)
        XCTAssertFalse(refused.succeeded)
        _ = await aliceMachine.stopJob(id: job.id)

        // When the account cannot be set up, the person gets no machine.
        let failing = WorkstationPool(operatorMachine: operatorMachine, dataDir: data, provisionCommand: "false")
        guard case .failure = await failing.machine(ownerID: alice) else { return XCTFail("a failed setup must not hand out a machine") }
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
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, access: access, completion: { _, _, _, system, messages, _ in
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
