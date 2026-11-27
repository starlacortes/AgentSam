@testable import AgentSamServer
import XCTVapor
import Foundation
import NIOCore

/// Replies are compressed for clients that ask for it. Needs a real listening server: the
/// in-memory test client does not go through the HTTP pipeline.
final class CompressionTests: XCTestCase {
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tests-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", "test-server-token-0123456789", 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testJSONRepliesAreCompressedWhenTheClientAsks() async throws {
        let port = 18771
        try await app.server.start(address: .hostname("127.0.0.1", port: port))
        let url = URI(string: "http://127.0.0.1:\(port)/api/auth/status")

        let asked = try await app.client.get(url, headers: ["Accept-Encoding": "gzip"])
        XCTAssertEqual(asked.status, .ok)
        XCTAssertEqual(asked.headers.first(name: .contentEncoding), "gzip")

        let plain = try await app.client.get(url)
        XCTAssertEqual(plain.status, .ok)
        XCTAssertNil(plain.headers.first(name: .contentEncoding))
        XCTAssertTrue(plain.body.map { String(buffer: $0) }?.contains("{") == true)

        await app.server.shutdown()
    }
}
