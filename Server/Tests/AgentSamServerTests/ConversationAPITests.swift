@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

private struct AppliedProposal: Decodable {
    var team: Team
    var conversation: Conversation
}

final class ConversationAPITests: XCTestCase {
    private let token = "conversation-test-token"
    private var directory: URL!
    private var app: Application!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-conversation-api-\(UUID().uuidString)")
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

    private func authorize(_ req: inout XCTHTTPRequest) {
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
    }

    private func createConversation() async throws -> Conversation {
        var created: Conversation?
        try await app.test(.POST, "api/conversations", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ConversationCreateBody(projectName: "Launch"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created, res.body.string)
            created = try res.content.decode(Conversation.self)
        })
        return try XCTUnwrap(created)
    }

    func testConversationPersistenceValidationAndAuthentication() async throws {
        try await app.test(.GET, "api/conversations", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        let conversation = try await createConversation()
        XCTAssertEqual(conversation.projectName, "Launch")
        try await app.test(.GET, "api/conversations", beforeRequest: authorize, afterResponse: { res async throws in
            let list = try res.content.decode([ConversationSummary].self)
            XCTAssertEqual(list.map(\.id), [conversation.id])
        })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/messages", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ConversationMessageBody(text: " ", language: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        try await app.test(.GET, "api/conversations/\(UUID().uuidString)", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testProposalOnlyMutatesAfterApprovalAndCannotBeAppliedTwice() async throws {
        let conversation = try await createConversation()
        var seeded: Team?
        try await app.test(.GET, "api/teams", beforeRequest: authorize, afterResponse: { res async throws in
            seeded = try res.content.decode([Team].self).first
        })
        let original = try XCTUnwrap(seeded)
        var agents = original.agents
        for index in agents.indices {
            agents[index].providerID = "anthropic"
            agents[index].model = "claude-sonnet-4-5"
        }
        let draft = TeamProposalDraft(baseTeamID: original.id, name: "Approved research", goal: original.goal, agents: agents)
        let proposal = try TeamProposalValidation.make(draft: draft, teams: [original], providers: ProviderConfig.builtin)
        let store = ConversationStore(root: directory)
        _ = try await store.append(id: conversation.id, ownerID: "shared-server-token", message: ConversationMessage(role: .assistant, text: "Review this draft", proposal: proposal))
        try await app.test(.GET, "api/teams/\(original.id.uuidString)", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode(Team.self).name, original.name)
        })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/proposals/\(proposal.id.uuidString)/apply", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode(AppliedProposal.self).team.name, "Approved research")
        })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/proposals/\(proposal.id.uuidString)/apply", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        try await app.test(.GET, "api/teams/\(original.id.uuidString)", beforeRequest: authorize, afterResponse: { res async throws in
            let team = try res.content.decode(Team.self)
            XCTAssertEqual(team.name, "Approved research")
            XCTAssertEqual(team.id, original.id)
            XCTAssertEqual(team.toolScope?.permissions.sendEmail, false)
        })
    }

    func testGuideResetDoesNotChangeWorkspaceData() async throws {
        let conversation = try await createConversation()
        let memory = WorkspaceMemoryStore(root: directory)
        _ = try await memory.setEnabled(true)
        try await app.test(.PATCH, "api/workspace/guide", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(GuidePatchBody(completed: true), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertTrue(try res.content.decode(GuideState.self).completed)
        })
        try await app.test(.PATCH, "api/workspace/guide", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(GuidePatchBody(completed: false), as: .json)
        }, afterResponse: { res async throws in
            let guide = try res.content.decode(GuideState.self)
            XCTAssertFalse(guide.completed)
            XCTAssertNotNil(guide.resetAt)
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.GET, "api/teams", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([Team].self).count, 1)
        })
        try await app.test(.GET, "api/workspace/memory", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertTrue(try res.content.decode(WorkspaceMemory.self).enabled)
        })
    }

    func testMemberCannotReadAnotherUsersConversationAndWritesNeedCSRF() async throws {
        var cookie = ""
        var adminID: UUID?
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(SetupBody(setupToken: token, email: "owner@example.com", name: "Owner", password: "a long test password"), as: .json)
        }, afterResponse: { res async throws in
            cookie = try XCTUnwrap(res.headers.setCookie?[AuthConfig.cookieName]?.string)
        })
        try await app.test(.GET, "api/auth/me", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(cookie)")
        }, afterResponse: { res async throws in
            adminID = try res.content.decode(MeResponse.self).user?.id
        })
        let owner = try XCTUnwrap(adminID?.uuidString)
        let store = ConversationStore(root: directory)
        let conversation = try await store.create(ownerID: owner)
        let accounts = try XCTUnwrap(app.storage[ServerContextKey.self]).accounts
        let passwordHash = try await Passwords.hash("member test password")
        let created = try await accounts.createUser(email: "member@example.com", name: "Member", role: .member, passwordHash: passwordHash)
        let passwordVerified = await Passwords.verify("member test password", hash: passwordHash)
        XCTAssertTrue(passwordVerified)
        let persisted = await accounts.user(email: "member@example.com")
        XCTAssertEqual(persisted?.id, created.id)
        XCTAssertEqual(persisted?.passwordHash, passwordHash)
        let reloaded = await AccountStore(dataDir: directory).user(email: "member@example.com")
        XCTAssertEqual(reloaded?.passwordHash, passwordHash)
        var memberCookie = ""
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: "member@example.com", password: "member test password"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            memberCookie = try XCTUnwrap(res.headers.setCookie?[AuthConfig.cookieName]?.string)
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(memberCookie)")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/messages", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(cookie)")
            try req.content.encode(ConversationMessageBody(text: "Hello", language: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)", beforeRequest: { req in
            req.headers.replaceOrAdd(name: .cookie, value: "\(AuthConfig.cookieName)=\(cookie)")
        }, afterResponse: { res async throws in
            XCTAssertTrue(try res.content.decode(Conversation.self).messages.isEmpty)
        })
    }
}
