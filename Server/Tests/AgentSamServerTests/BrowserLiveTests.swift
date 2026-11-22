@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore
import WebSocketKit
import NIOCore

/// Opens the live window against a real listening server. A stand-in `ssh` stands for the workstation:
/// it echoes what it is sent, or exits at once when `/tmp/sshmode` says `die`. Without the stand-in
/// (set `AGENTSAM_FAKE_SSH=1` where it is installed) these tests are skipped.
final class BrowserLiveTests: XCTestCase {
    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tests-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        setenv("AGENTSAM_BROWSER", "1", 1)
        setenv("AGENTSAM_WORKSTATION", "1", 1)
        setenv("AGENTSAM_WORKSTATION_SSH", "ada@127.0.0.1", 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        unsetenv("AGENTSAM_BROWSER"); unsetenv("AGENTSAM_WORKSTATION"); unsetenv("AGENTSAM_WORKSTATION_SSH")
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func openLive(port: Int) async throws -> Bool {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTSAM_FAKE_SSH"] == "1", "needs the stand-in ssh")
        var cookie = ""
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(SetupBody(setupToken: self.serverToken, email: "admin@example.com", name: "Admin", password: "correct horse battery"), as: .json)
        }, afterResponse: { res async in
            cookie = res.headers.setCookie?[AuthConfig.cookieName]?.string ?? ""
        })
        XCTAssertFalse(cookie.isEmpty)
        try await app.server.start(address: .hostname("127.0.0.1", port: port))

        var headers = HTTPHeaders()
        headers.add(name: .cookie, value: "\(AuthConfig.cookieName)=\(cookie)")
        headers.add(name: .origin, value: "http://127.0.0.1:\(port)")
        let echoed = expectation(description: "bytes came back")
        echoed.assertForOverFulfill = false
        let sockets = SocketBox()
        try await WebSocket.connect(to: "ws://127.0.0.1:\(port)/api/browser/live", headers: headers, on: app.eventLoopGroup.next()) { ws in
            ws.onBinary { _, buffer in
                if buffer.readableBytes > 0 { echoed.fulfill() }
            }
            // A VNC viewer waits for the server's greeting first, so the relay is set up by then.
            ws.eventLoop.scheduleTask(in: .milliseconds(500)) {
                ws.send(raw: Array("RFB 003.008\n".utf8), opcode: .binary)
            }
            sockets.set(ws)
        }.get()
        let echo = await XCTWaiter.fulfillment(of: [echoed], timeout: 5)
        // Hang up from our side, as a viewer closing the window does.
        try await sockets.get()?.close().get()
        try await Task.sleep(nanoseconds: 300_000_000)
        await app.server.shutdown()
        return echo == .completed
    }

    func testLiveWindowRelaysBytesBothWays() async throws {
        try "echo".write(toFile: "/tmp/sshmode", atomically: true, encoding: .utf8)
        let result = try await openLive(port: 18765)
        XCTAssertTrue(result, "what the viewer sends comes back through the relay")
    }

    func testLiveWindowSurvivesTheRelayEndingAtOnce() async throws {
        try "die".write(toFile: "/tmp/sshmode", atomically: true, encoding: .utf8)
        let result = try await openLive(port: 18766)
        XCTAssertFalse(result)
        // Reaching this line at all is the test: the server must not stop when the relay does.
    }
}

private final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: WebSocket?
    func set(_ value: WebSocket) { lock.lock(); socket = value; lock.unlock() }
    func get() -> WebSocket? { lock.lock(); defer { lock.unlock() }; return socket }
}
