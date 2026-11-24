@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

/// Gmail, Google Ads, GitHub, Cloudflare, Maloon and MCP use one set of server credentials, so a
/// member reaches them only when an admin allowed it.
final class SharedAccountsTests: XCTestCase {
    private let token = "shared-accounts-token"
    private var directory: URL!
    private var app: Application!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-shared-accounts-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", directory.path, 1)
        setenv("AGENTSAM_TOKEN", token, 1)
        setenv("AGENTSAM_WEB_DIR", directory.appendingPathComponent("none").path, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testMembersNeedAnAdminsGrantAndAdminsAlwaysHaveIt() async throws {
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let hash = try await Passwords.hash("member test password")
        let member = try await ctx.accounts.createUser(email: "member@example.com", name: "Member", role: .member, passwordHash: hash)
        let admin = try await ctx.accounts.createUser(email: "admin@example.com", name: "Admin", role: .admin, passwordHash: hash)
        let allowed = ctx.access.sharedAccountsOwner

        let memberAllowed = await allowed(member.id.uuidString)
        let adminAllowed = await allowed(admin.id.uuidString)
        let tokenAllowed = await allowed("shared-server-token")
        let strangerAllowed = await allowed(UUID().uuidString)
        XCTAssertFalse(memberAllowed, "members start without shared accounts")
        XCTAssertTrue(adminAllowed)
        XCTAssertTrue(tokenAllowed)
        XCTAssertFalse(strangerAllowed)

        // A member cannot start a Maloon workflow (it reads the business accounts) without the grant.
        var memberCookie = ""
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: "member@example.com", password: "member test password"), as: .json)
        }, afterResponse: { res async throws in
            memberCookie = try XCTUnwrap(res.headers.setCookie?[AuthConfig.cookieName]?.string)
        })
        func asMember(_ req: inout XCTHTTPRequest) {
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(memberCookie)")
            req.headers.replaceOrAdd(name: AuthConfig.csrfHeader, value: "1")
        }
        try await app.test(.POST, "api/missions", beforeRequest: { req in
            asMember(&req)
            try req.content.encode(["workflowID": "any-workflow"], as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        // Members cannot grant themselves access.
        try await app.test(.PATCH, "api/users/\(member.id.uuidString)", beforeRequest: { req in
            asMember(&req)
            try req.content.encode(["sharedAccounts": true], as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        let stillBlocked = await allowed(member.id.uuidString)
        XCTAssertFalse(stillBlocked)

        // An admin grants it, and can take it back.
        try await app.test(.PATCH, "api/users/\(member.id.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
            try req.content.encode(["sharedAccounts": true], as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertTrue(try res.content.decode(PublicUser.self).sharedAccounts)
        })
        let granted = await allowed(member.id.uuidString)
        XCTAssertTrue(granted)
        try await app.test(.PATCH, "api/users/\(member.id.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
            try req.content.encode(["sharedAccounts": false], as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })
        let revoked = await allowed(member.id.uuidString)
        XCTAssertFalse(revoked)

        // A disabled account never has it.
        _ = try await ctx.accounts.update(id: member.id, role: nil, disabled: true, name: nil, sharedAccounts: true)
        let disabled = await allowed(member.id.uuidString)
        XCTAssertFalse(disabled)
    }

    func testWorkstationGrantIsAdminSetAndNeedsAWorkstation() async throws {
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let hash = try await Passwords.hash("member test password")
        let member = try await ctx.accounts.createUser(email: "member2@example.com", name: "Member", role: .member, passwordHash: hash)
        XCTAssertFalse(PublicUser(member).workstation, "members start without a workstation")
        try await app.test(.PATCH, "api/users/\(member.id.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
            try req.content.encode(["workstation": true], as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertTrue(try res.content.decode(PublicUser.self).workstation)
        })
        // This test server has no workstation, so even a granted person gets none, and nobody shares one.
        let granted = await ctx.access.workstationFor(member.id.uuidString)
        XCTAssertNil(granted)
        let stranger = await ctx.access.workstationFor(UUID().uuidString)
        XCTAssertNil(stranger)
    }

    func testAnAdminCanChooseAWorkspaceOfTheirOwn() async throws {
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let hash = try await Passwords.hash("admin test password")
        let admin = try await ctx.accounts.createUser(email: "admin2@example.com", name: "Admin", role: .admin, passwordHash: hash)
        XCTAssertFalse(PublicUser(admin).ownWorkspace, "admins start in the shared operator account")
        let shared = await ctx.access.workstationOwner(admin.id.uuidString)
        XCTAssertTrue(shared)

        try await app.test(.PATCH, "api/users/\(admin.id.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
            try req.content.encode(["ownWorkspace": true], as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertTrue(try res.content.decode(PublicUser.self).ownWorkspace)
        })
        let own = await ctx.access.workstationOwner(admin.id.uuidString)
        XCTAssertFalse(own, "with a workspace of their own, the admin no longer works as the shared account")
        let tokenStillShared = await ctx.access.workstationOwner("shared-server-token")
        XCTAssertTrue(tokenStillShared)
        let fetched = await ctx.accounts.user(id: admin.id)
        let record = try XCTUnwrap(fetched)
        XCTAssertFalse(record.usesOperatorWorkstation)
        XCTAssertTrue(record.mayUseWorkstation)

        // Turning it off puts them back in the shared account.
        try await app.test(.PATCH, "api/users/\(admin.id.uuidString)", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
            try req.content.encode(["ownWorkspace": false], as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok, res.body.string) })
        let back = await ctx.access.workstationOwner(admin.id.uuidString)
        XCTAssertTrue(back)
    }
}
