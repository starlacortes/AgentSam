@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

/// Missions belong to the account whose chat started them. Another account must not list them,
/// read their events or files, stop them, or watch their live stream.
final class MissionIsolationTests: XCTestCase {
    private let token = "mission-isolation-token"
    private var directory: URL!
    private var app: Application!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-mission-isolation-\(UUID().uuidString)")
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

    private func signIn(email: String, name: String, password: String, role: UserRole) async throws -> (id: UUID, cookie: String) {
        let accounts = try XCTUnwrap(app.storage[ServerContextKey.self]).accounts
        let user = try await accounts.createUser(email: email, name: name, role: role, passwordHash: try await Passwords.hash(password))
        var cookie = ""
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            cookie = try XCTUnwrap(res.headers.setCookie?[AuthConfig.cookieName]?.string)
        })
        return (user.id, cookie)
    }

    private func saveMission(_ ctx: ServerContext, owner: String?, objective: String) async -> Mission {
        var mission = Mission(teamID: TaskTools.teamID, teamName: "Ada's job", objective: objective, status: .completed, phase: .done)
        mission.ownerID = owner
        try? FileManager.default.createDirectory(at: ctx.store.missionDirectory(mission.id), withIntermediateDirectories: true)
        await ctx.store.saveMission(mission)
        await ctx.store.appendEvent(mission.id, kind: .missionStart, text: objective)
        await ctx.store.writeDeliverable(missionID: mission.id, name: "final-report.md", content: "Report: \(objective)")
        return mission
    }

    func testMissionsAreVisibleOnlyToTheirOwner() async throws {
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let alice = try await signIn(email: "alice@example.com", name: "Alice", password: "alice test password", role: .member)
        let bob = try await signIn(email: "bob@example.com", name: "Bob", password: "bob test password long", role: .member)
        func cookie(_ value: String) -> (inout XCTHTTPRequest) -> Void {
            { req in
                req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(value)")
                req.headers.replaceOrAdd(name: AuthConfig.csrfHeader, value: "1")
            }
        }

        let secret = await saveMission(ctx, owner: alice.id.uuidString, objective: "Alice's private plan")
        let mine = await saveMission(ctx, owner: bob.id.uuidString, objective: "Bob's own task")

        // A mission saved before owners were recorded belongs to the owner of the chat that links it.
        let legacy = await saveMission(ctx, owner: nil, objective: "Alice's older task")
        let chat = try await ctx.conversations.create(ownerID: alice.id.uuidString)
        _ = try await ctx.conversations.append(id: chat.id, ownerID: alice.id.uuidString, message: ConversationMessage(role: .assistant, text: "Started.", missionIDs: [legacy.id]))
        // One that no chat links is kept for admins only.
        let orphan = await saveMission(ctx, owner: nil, objective: "Nobody's old task")

        // Bob sees only his own mission, and Alice's ids look like they do not exist.
        try await app.test(.GET, "api/missions", beforeRequest: cookie(bob.cookie), afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([IDOnly].self).map(\.id), [mine.id])
        })
        for path in ["", "/events", "/deliverables/final-report.md"] {
            try await app.test(.GET, "api/missions/\(secret.id.uuidString)\(path)", beforeRequest: cookie(bob.cookie), afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound, "GET \(path)")
            })
            try await app.test(.GET, "api/missions/\(legacy.id.uuidString)\(path)", beforeRequest: cookie(bob.cookie), afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound, "legacy GET \(path)")
            })
            try await app.test(.GET, "api/missions/\(orphan.id.uuidString)\(path)", beforeRequest: cookie(bob.cookie), afterResponse: { res async in
                XCTAssertEqual(res.status, .notFound, "orphan GET \(path)")
            })
        }
        try await app.test(.POST, "api/missions/\(secret.id.uuidString)/stop", beforeRequest: cookie(bob.cookie), afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.GET, "api/info", beforeRequest: cookie(bob.cookie), afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode(InfoCount.self).missions, 1)
        })

        // Alice reads hers, including the one saved before owners were recorded.
        try await app.test(.GET, "api/missions", beforeRequest: cookie(alice.cookie), afterResponse: { res async throws in
            XCTAssertEqual(Set(try res.content.decode([IDOnly].self).map(\.id)), [secret.id, legacy.id])
        })
        try await app.test(.GET, "api/missions/\(secret.id.uuidString)/deliverables/final-report.md", beforeRequest: cookie(alice.cookie), afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("Alice's private plan"))
        })
        try await app.test(.GET, "api/missions/\(legacy.id.uuidString)", beforeRequest: cookie(alice.cookie), afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        // The shared server token is an admin that owns none of these, so it sees only the unlinked old one.
        try await app.test(.GET, "api/missions", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: self.token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([IDOnly].self).map(\.id), [orphan.id])
        })
    }

    private struct IDOnly: Decodable { var id: UUID }
    private struct InfoCount: Decodable { var missions: Int }
}
