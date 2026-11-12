@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore

/// Regression: constant connector paths (e.g. `connectors/googleads/credentials`) shadowed the
/// `connectors/:id/...` POST routes for that connector, so every Google Ads POST returned 404
/// while Gmail's worked. Vapor prefers constants over parameters and does not backtrack.
final class ConnectorRouteTests: XCTestCase {
    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tests-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func bearer(_ req: inout XCTHTTPRequest) {
        req.headers.replaceOrAdd(name: .authorization, value: "Bearer \(serverToken)")
    }

    func testGoogleAdsPostRoutesAreNotShadowed() async throws {
        for path in ["authorize", "test", "disconnect", "credentials"] {
            try await app.test(.POST, "api/connectors/googleads/\(path)", afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized, "googleads/\(path) must route to its handler, not 404")
            })
        }
    }

    func testConnectorSpecificRoutesRejectOtherConnectorIDs() async throws {
        for path in ["gmail/credentials", "googleads/key", "googleads/token", "web/credentials"] {
            try await app.test(.POST, "api/connectors/\(path)", beforeRequest: bearer, afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound, "\(path) should stay unknown")
            })
        }
    }
}
