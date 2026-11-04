@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore

final class AuthTests: XCTestCase {
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

    // MARK: Helpers

    private struct Me: Decodable {
        struct User: Decodable { var id: UUID; var email: String; var role: String }
        var user: User?
        var role: String
    }

    private func sessionCookie(_ res: XCTHTTPResponse) -> String? {
        res.headers.setCookie?[AuthConfig.cookieName]?.string
    }

    private func setupAdmin() async throws -> String {
        var cookie: String?
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(SetupBody(setupToken: self.serverToken, email: "Admin@Example.com", name: "Admin", password: "correct horse battery"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            cookie = self.sessionCookie(res)
        })
        return try XCTUnwrap(cookie)
    }

    private func withSession(_ cookie: String, csrf: Bool = true) -> (inout XCTHTTPRequest) throws -> Void {
        { req in
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(cookie)")
            if csrf { req.headers.replaceOrAdd(name: AuthConfig.csrfHeader, value: "1") }
        }
    }

    // MARK: Tests

    func testStatusReportsSetupNeededUntilFirstAdmin() async throws {
        try await app.test(.GET, "api/auth/status") { res async in
            XCTAssertTrue(res.body.string.contains("\"needsSetup\":true"))
        }
        _ = try await setupAdmin()
        try await app.test(.GET, "api/auth/status") { res async in
            XCTAssertTrue(res.body.string.contains("\"needsSetup\":false"))
        }
    }

    func testSetupRequiresServerToken() async throws {
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(SetupBody(setupToken: "wrong", email: "a@example.com", name: "A", password: "correct horse battery"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testSetupOnlyOnce() async throws {
        _ = try await setupAdmin()
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(SetupBody(setupToken: self.serverToken, email: "b@example.com", name: "B", password: "correct horse battery"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .conflict)
        })
    }

    func testLoginAndMe() async throws {
        _ = try await setupAdmin()
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: "admin@example.com", password: "wrong password!!"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        var cookie: String?
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: " ADMIN@example.com ", password: "correct horse battery"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            cookie = self.sessionCookie(res)
            let setCookie = res.headers.first(name: .setCookie) ?? ""
            XCTAssertTrue(setCookie.contains("HttpOnly"))
            XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        })
        try await app.test(.GET, "api/auth/me", beforeRequest: withSession(try XCTUnwrap(cookie))) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let me = try res.content.decode(Me.self)
            XCTAssertEqual(me.user?.email, "admin@example.com")
            XCTAssertEqual(me.role, "admin")
        }
    }

    func testUnauthenticatedRequestsAreRefused() async throws {
        try await app.test(.GET, "api/teams") { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testServerTokenStillWorksForApps() async throws {
        try await app.test(.GET, "api/teams", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.serverToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testCookieWritesNeedCSRFHeader() async throws {
        let cookie = try await setupAdmin()
        let body = ["name": "Team", "emoji": "x", "goal": "g"]
        try await app.test(.POST, "api/teams", beforeRequest: { req in
            try self.withSession(cookie, csrf: false)(&req)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        try await app.test(.POST, "api/teams", beforeRequest: { req in
            try self.withSession(cookie)(&req)
            req.headers.replaceOrAdd(name: .host, value: "agentsam.example")
            req.headers.replaceOrAdd(name: .origin, value: "https://evil.example")
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        try await app.test(.POST, "api/teams", beforeRequest: { req in
            try self.withSession(cookie)(&req)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .created)
        })
    }

    func testInviteFlowCreatesMemberWithoutAdminRights() async throws {
        let admin = try await setupAdmin()
        var path = ""
        try await app.test(.POST, "api/invites", beforeRequest: { req in
            try self.withSession(admin)(&req)
            try req.content.encode(InviteBody(email: "member@example.com", role: .member), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created)
            struct Created: Decodable { var path: String }
            path = try res.content.decode(Created.self).path
        })
        let secret = String(try XCTUnwrap(path.split(separator: "#").last))

        try await app.test(.GET, "api/auth/invite/\(secret)") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("member@example.com"))
        }

        var member: String?
        try await app.test(.POST, "api/auth/accept-invite", beforeRequest: { req in
            try req.content.encode(AcceptInviteBody(secret: secret, name: "Member", password: "another long password"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            member = self.sessionCookie(res)
        })
        let memberCookie = try XCTUnwrap(member)

        // The invite is single use.
        try await app.test(.POST, "api/auth/accept-invite", beforeRequest: { req in
            try req.content.encode(AcceptInviteBody(secret: secret, name: "Again", password: "another long password"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .gone)
        })

        // Members can read teams but can't manage keys or users.
        try await app.test(.GET, "api/teams", beforeRequest: withSession(memberCookie)) { res async in
            XCTAssertEqual(res.status, .ok)
        }
        try await app.test(.POST, "api/providers/anthropic/key", beforeRequest: { req in
            try self.withSession(memberCookie)(&req)
            try req.content.encode(["key": "sk-test"], as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        try await app.test(.GET, "api/users", beforeRequest: withSession(memberCookie)) { res async in
            XCTAssertEqual(res.status, .forbidden)
        }
    }

    func testLastAdminCannotBeDemoted() async throws {
        let admin = try await setupAdmin()
        var adminID: UUID?
        try await app.test(.GET, "api/auth/me", beforeRequest: withSession(admin)) { res async throws in
            adminID = try res.content.decode(Me.self).user?.id
        }
        let id = try XCTUnwrap(adminID)
        try await app.test(.PATCH, "api/users/\(id)", beforeRequest: { req in
            try self.withSession(admin)(&req)
            try req.content.encode(UserPatchBody(role: .member, disabled: nil, name: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .conflict)
        })
    }

    func testLogoutRevokesSession() async throws {
        let admin = try await setupAdmin()
        try await app.test(.POST, "api/auth/logout", beforeRequest: withSession(admin)) { res async in
            XCTAssertEqual(res.status, .ok)
        }
        try await app.test(.GET, "api/auth/me", beforeRequest: withSession(admin)) { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testSecurityHeadersPresent() async throws {
        try await app.test(.GET, "api/auth/status") { res async in
            XCTAssertNotNil(res.headers.first(name: "Content-Security-Policy"))
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
        }
    }

    func testSecretsHelpers() {
        XCTAssertTrue(Secrets.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(Secrets.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(Secrets.constantTimeEquals("abc", "abcd"))
        XCTAssertEqual(Secrets.randomToken().count, 43)
    }
}

final class TemplateTests: XCTestCase {
    func testTemplatesResolveToConfiguredProviders() {
        let team = ServerTemplateCatalog.all[0].makeTeam(providers: ProviderConfig.builtin)
        XCTAssertEqual(team.agents.count, ServerTemplateCatalog.all[0].memberNames.count)
        for agent in team.agents {
            let provider = ProviderConfig.builtin.first { $0.id == agent.providerID }
            XCTAssertNotNil(provider)
            XCTAssertTrue(provider?.models.contains(agent.model) ?? false)
        }
    }

    func testEveryTemplateMemberExistsInRoster() {
        for template in ServerTemplateCatalog.all {
            for name in template.memberNames {
                XCTAssertNotNil(AgentProfile.rosterTemplates.first { $0.name == name }, "\(template.id): \(name)")
            }
        }
    }
}

final class APITokenTests: XCTestCase {
    func testPersonalTokenAuthenticatesAsItsUser() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountStore(dataDir: dir)
        let user = try await store.createUser(email: "m@example.com", name: "M", role: .member, passwordHash: "x")
        let (record, raw) = try await store.createAPIToken(userID: user.id, name: "iPhone")
        XCTAssertTrue(raw.hasPrefix(AccountStore.apiTokenPrefix))
        XCTAssertNotEqual(record.tokenHash, raw)
        let found = await store.user(apiToken: raw)
        XCTAssertEqual(found?.id, user.id)
        let wrong = await store.user(apiToken: raw + "x")
        XCTAssertNil(wrong)

        // Survives a reload from disk, and revocation works.
        let reloaded = AccountStore(dataDir: dir)
        let again = await reloaded.user(apiToken: raw)
        XCTAssertEqual(again?.id, user.id)
        try await reloaded.revokeAPIToken(id: record.id, userID: user.id)
        let revoked = await reloaded.user(apiToken: raw)
        XCTAssertNil(revoked)
    }

    func testDisabledUsersTokensStopWorking() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountStore(dataDir: dir)
        _ = try await store.createUser(email: "a@example.com", name: "A", role: .admin, passwordHash: "x")
        let member = try await store.createUser(email: "m@example.com", name: "M", role: .member, passwordHash: "x")
        let (_, raw) = try await store.createAPIToken(userID: member.id, name: "script")
        _ = try await store.update(id: member.id, role: nil, disabled: true, name: nil)
        let found = await store.user(apiToken: raw)
        XCTAssertNil(found)
    }
}
