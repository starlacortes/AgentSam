@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

/// Skills and helper roles are private to the person whose Ada saved them. Only an admin can share
/// one of their own skills with everyone.
final class SkillSharingTests: XCTestCase {
    private let token = "skill-sharing-token"
    private var directory: URL!
    private var app: Application!

    private struct ListedSkill: Decodable {
        var id: String
        var general: Bool
        var sharedCopy: Bool
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-skill-sharing-\(UUID().uuidString)")
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

    func testSkillsAndRolesArePrivateAndOnlyAdminsShareSkills() async throws {
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let hash = try await Passwords.hash("member test password")
        let member = try await ctx.accounts.createUser(email: "member@example.com", name: "Member", role: .member, passwordHash: hash)
        let memberOwner = member.id.uuidString
        let adminOwner = "shared-server-token"

        try await ctx.skills.save(Skill(id: "admin-report", name: "Admin report", whenToUse: "Admin reports.", procedure: ["One"], origin: .ada), ownerID: adminOwner)
        try await ctx.skills.save(Skill(id: "member-notes", name: "Member notes", whenToUse: "Member notes.", procedure: ["One"], origin: .ada), ownerID: memberOwner)
        let helpers = HelperStore(root: ctx.dataDir)
        _ = try await helpers.save(function: "price check", role: "Compare three vendors and cite each price.", groups: [], reason: "member", ownerID: memberOwner)

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
        func asAdmin(_ req: inout XCTHTTPRequest) {
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
        }
        func skills(_ authorize: @escaping (inout XCTHTTPRequest) -> Void) async throws -> [ListedSkill] {
            var listed: [ListedSkill] = []
            try await app.test(.GET, "api/skills", beforeRequest: { req in authorize(&req) }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok, res.body.string)
                listed = try res.content.decode([ListedSkill].self)
            })
            return listed
        }

        var memberSees = try await skills(asMember).map(\.id)
        XCTAssertTrue(memberSees.contains("member-notes"))
        XCTAssertFalse(memberSees.contains("admin-report"), "the admin's skill is private until shared")
        XCTAssertTrue(memberSees.contains("research"), "built-ins are for everyone")
        let adminSees = try await skills(asAdmin).map(\.id)
        XCTAssertFalse(adminSees.contains("member-notes"), "admins do not see members' private skills")

        // Members cannot share, not even their own skills.
        try await app.test(.POST, "api/skills/member-notes/share", beforeRequest: { req in
            asMember(&req)
            try req.content.encode(SkillShareBody(general: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
        // An admin cannot share someone else's skill.
        try await app.test(.POST, "api/skills/member-notes/share", beforeRequest: { req in
            asAdmin(&req)
            try req.content.encode(SkillShareBody(general: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .badRequest) })

        // The admin shares their own skill: members see the general copy, the admin keeps theirs.
        try await app.test(.POST, "api/skills/admin-report/share", beforeRequest: { req in
            asAdmin(&req)
            try req.content.encode(SkillShareBody(general: true), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let own = try res.content.decode([ListedSkill].self).first { $0.id == "admin-report" }
            XCTAssertEqual(own?.general, false)
            XCTAssertEqual(own?.sharedCopy, true)
        })
        let shared = try await skills(asMember).first { $0.id == "admin-report" }
        XCTAssertEqual(shared?.general, true)

        try await app.test(.POST, "api/skills/admin-report/share", beforeRequest: { req in
            asAdmin(&req)
            try req.content.encode(SkillShareBody(general: false), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok, res.body.string) })
        memberSees = try await skills(asMember).map(\.id)
        XCTAssertFalse(memberSees.contains("admin-report"))
        let audit = await ctx.access.audit.entries(ownerID: adminOwner).map(\.action)
        XCTAssertTrue(audit.contains("skill.shared"))
        XCTAssertTrue(audit.contains("skill.unshared"))

        // Helper roles: each person lists only their own (and general ones).
        try await app.test(.GET, "api/helpers", beforeRequest: asMember, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([SavedHelper].self).map(\.name), ["priceCheckAda"])
        })
        try await app.test(.GET, "api/helpers", beforeRequest: asAdmin, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([SavedHelper].self).map(\.name), [])
        })
    }
}
