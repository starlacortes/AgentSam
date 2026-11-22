@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore

final class BrowserRouteTests: XCTestCase {
    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tests-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        unsetenv("AGENTSAM_BROWSER")
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

    func testBrowserRoutesNeedSignIn() async throws {
        try await app.test(.GET, "api/browser", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.POST, "api/browser/start", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testBrowserIsUnavailableUnlessTheServerTurnsItOn() async throws {
        try await app.test(.GET, "api/browser", beforeRequest: bearer, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let view = try res.content.decode(BrowserView.self)
            XCTAssertFalse(view.available)
            XCTAssertNil(view.state)
        })
        for path in ["start", "stop"] {
            try await app.test(.POST, "api/browser/\(path)", beforeRequest: bearer, afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound, path)
            })
        }
    }

    func testOnlyAnAdminSessionFromAdasOwnPagesMayWatch() {
        let session = Principal.Source.session(token: "cookie")
        let admin = Principal(userID: UUID(), name: "Star", email: nil, role: .admin, source: session)
        XCTAssertNil(browserViewerProblem(principal: admin, origin: "https://ada.example.com", host: "ada.example.com"))
        XCTAssertNil(browserViewerProblem(principal: admin, origin: "http://localhost:5173", host: "localhost:8080"), "the port is not part of the check, as for other requests")

        let member = Principal(userID: UUID(), name: "Maloon", email: nil, role: .member, source: session)
        XCTAssertNotNil(browserViewerProblem(principal: member, origin: "https://ada.example.com", host: "ada.example.com"))

        let serverToken = Principal(userID: nil, name: "Server token", email: nil, role: .admin, source: .serverToken)
        XCTAssertNotNil(browserViewerProblem(principal: serverToken, origin: "https://ada.example.com", host: "ada.example.com"))
        let appToken = Principal(userID: UUID(), name: "Star", email: nil, role: .admin, source: .apiToken)
        XCTAssertNotNil(browserViewerProblem(principal: appToken, origin: "https://ada.example.com", host: "ada.example.com"))

        XCTAssertNotNil(browserViewerProblem(principal: admin, origin: "https://evil.example", host: "ada.example.com"))
        XCTAssertNotNil(browserViewerProblem(principal: admin, origin: nil, host: "ada.example.com"), "a request with no origin is not from a page")
        XCTAssertNotNil(browserViewerProblem(principal: admin, origin: "https://ada.example.com", host: nil))
    }
}
