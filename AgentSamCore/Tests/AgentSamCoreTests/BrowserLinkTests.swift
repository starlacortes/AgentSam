import XCTest
@testable import AgentSamCore

/// Records the scripts a `BrowserLink` runs and answers them like the workstation would.
private actor FakeMachine {
    private(set) var scripts: [String] = []
    private var active = false
    var reachable = true

    func setReachable(_ value: Bool) { reachable = value }

    func run(_ script: String) -> ToolOutcome {
        scripts.append(script)
        guard reachable else { return .failure("ssh: connect to host kokofast port 22: Connection timed out") }
        if script.contains("systemctl start") { active = true; return ToolOutcome(resultText: BrowserLink.onMarker) }
        if script.contains("systemctl stop") { active = false; return ToolOutcome(resultText: BrowserLink.offMarker) }
        return ToolOutcome(resultText: active ? BrowserLink.onMarker : BrowserLink.offMarker)
    }
}

final class BrowserLinkTests: XCTestCase {
    private let sshWorkstation = WorkstationConfig(enabled: true, home: URL(fileURLWithPath: "/"), ssh: SSHTarget(destination: "ada@kokofast.example"))

    private func link(_ machine: FakeMachine, idleSeconds: TimeInterval = 600) -> BrowserLink {
        BrowserLink(config: BrowserConfig(enabled: true, idleSeconds: idleSeconds), run: { await machine.run($0) })
    }

    func testConfigIsOffUnlessTurnedOnWithAnSSHWorkstation() {
        XCTAssertFalse(BrowserConfig.fromEnvironment([:], workstation: sshWorkstation).enabled)
        let on = BrowserConfig.fromEnvironment(["AGENTSAM_BROWSER": "1"], workstation: sshWorkstation)
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.vncPort, 5977)
        XCTAssertEqual(on.service, "ada-browser.service")

        let local = WorkstationConfig(enabled: true, home: URL(fileURLWithPath: "/"))
        let refused = BrowserConfig.fromEnvironment(["AGENTSAM_BROWSER": "1"], workstation: local)
        XCTAssertFalse(refused.enabled, "the browser never runs on the server's own machine")
        XCTAssertNotNil(refused.problem)
    }

    func testConfigReadsPortAndRefusesOddServiceNames() {
        let custom = BrowserConfig.fromEnvironment(["AGENTSAM_BROWSER": "1", "AGENTSAM_BROWSER_VNC_PORT": "5901", "AGENTSAM_BROWSER_SERVICE": "browser@ada.service"], workstation: sshWorkstation)
        XCTAssertEqual(custom.vncPort, 5901)
        XCTAssertEqual(custom.service, "browser@ada.service")
        XCTAssertEqual(BrowserConfig.fromEnvironment(["AGENTSAM_BROWSER": "1", "AGENTSAM_BROWSER_VNC_PORT": "99999"], workstation: sshWorkstation).vncPort, 5977)
        for bad in ["x; reboot", "--now", "a b", "$(id)"] {
            let config = BrowserConfig.fromEnvironment(["AGENTSAM_BROWSER": "1", "AGENTSAM_BROWSER_SERVICE": bad], workstation: sshWorkstation)
            XCTAssertFalse(config.enabled, bad)
        }
    }

    func testStartStopAndState() async {
        let machine = FakeMachine()
        let browser = link(machine)
        var state = await browser.state()
        XCTAssertEqual(state, .stopped)
        let started = await browser.start()
        XCTAssertTrue(started.succeeded)
        state = await browser.state()
        XCTAssertEqual(state, .running)
        let stopped = await browser.stop()
        XCTAssertTrue(stopped.succeeded)
        state = await browser.state()
        XCTAssertEqual(state, .stopped)
        let scripts = await machine.scripts
        XCTAssertTrue(scripts.contains { $0.contains("sudo systemctl start 'ada-browser.service'") })
        XCTAssertTrue(scripts.contains { $0.contains("sudo systemctl stop 'ada-browser.service'") })
    }

    func testUnreachableWorkstationIsReportedNotGuessed() async {
        let machine = FakeMachine()
        await machine.setReachable(false)
        let browser = link(machine)
        let state = await browser.state()
        XCTAssertEqual(state, .unreachable)
        let started = await browser.start()
        XCTAssertFalse(started.succeeded)
    }

    func testOffBrowserRunsNothing() async {
        let machine = FakeMachine()
        let browser = BrowserLink(config: BrowserConfig(enabled: false), run: { await machine.run($0) })
        let started = await browser.start()
        XCTAssertFalse(started.succeeded)
        let command = await browser.relayCommand()
        XCTAssertNil(command)
        let scripts = await machine.scripts
        XCTAssertTrue(scripts.isEmpty)
    }

    func testStopsWhenNobodyWatchesAndStaysWhileSomebodyDoes() async throws {
        let machine = FakeMachine()
        let browser = link(machine, idleSeconds: 0.2)
        _ = await browser.start()
        await browser.viewerJoined()
        try await Task.sleep(nanoseconds: 500_000_000)
        var state = await browser.state()
        XCTAssertEqual(state, .running, "a watched browser keeps running")
        await browser.viewerLeft()
        try await Task.sleep(nanoseconds: 700_000_000)
        state = await browser.state()
        XCTAssertEqual(state, .stopped, "an unwatched browser stops after the idle time")
    }

    #if os(Linux) || os(macOS)
    func testLoopbackCommandForwardsOnePortWithThePinnedKeyOptions() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let config = WorkstationConfig(enabled: true, home: URL(fileURLWithPath: "/"), ssh: SSHTarget(destination: "ada@kokofast.example", port: 2222, hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"))
        let machine = Workstation(config: config, dataDir: data)
        guard let command = await machine.loopbackCommand(port: 5977) else { throw XCTSkip("ssh-keygen is not installed here") }
        XCTAssertEqual(Array(command.arguments.suffix(5)), ["-T", "-W", "127.0.0.1:5977", "--", "ada@kokofast.example"])
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(command.arguments.contains("2222"))
        XCTAssertFalse(command.arguments.contains { $0.hasPrefix("sh -c") }, "the relay runs no command on the workstation")
        XCTAssertNil(command.environment["AGENTSAM_TOKEN"])

        let local = Workstation(config: WorkstationConfig(enabled: true, home: URL(fileURLWithPath: "/")), dataDir: data)
        let none = await local.loopbackCommand(port: 5977)
        XCTAssertNil(none, "without an SSH workstation there is nothing to relay to")
    }

    func testRelayCarriesBytesBothWaysAndEndsOnce() async throws {
        let received = Collector()
        let ended = expectation(description: "relay ended")
        // `cat` stands in for ssh: what goes in comes back.
        let relay = try BrowserRelay(
            command: BrowserRelayCommand(executable: "/bin/cat", arguments: [], environment: [:]),
            onData: { received.append($0) },
            onEnd: { ended.fulfill() }
        )
        relay.send(Data("RFB 003.008\n".utf8))
        relay.send(Data([0, 1, 2, 255]))
        let expected = Data("RFB 003.008\n".utf8) + Data([0, 1, 2, 255])
        for _ in 0..<100 where received.data != expected { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(received.data, expected)
        relay.close()
        relay.close()
        await fulfillment(of: [ended], timeout: 5)
        relay.send(Data("late".utf8))
    }
    #endif
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
