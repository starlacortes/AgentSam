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
    private var hostDirectory: URL?

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
        if let hostDirectory { try? FileManager.default.removeItem(at: hostDirectory) }
        hostDirectory = nil
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

    func testChatWorkspaceFilesAreServedOnlyToTheirConversation() async throws {
        let conversation = try await createConversation()
        let workspace = ChatWorkspaceStore(root: URL(fileURLWithPath: directory.path))
        _ = await workspace.write(conversationID: conversation.id, name: "site/index.html", content: "<h1>Jelly</h1>")
        _ = await workspace.write(conversationID: conversation.id, name: "plan.md", content: "# Plan")

        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)/files", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let names = try res.content.decode([String].self)
            XCTAssertEqual(names, ["plan.md", "site/index.html"])
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)/files/site%2Findex.html", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "<h1>Jelly</h1>")
            XCTAssertEqual(res.headers.contentType?.description, "text/plain; charset=utf-8")
        })
        // A different conversation (and a different owner) sees nothing.
        let other = try await createConversation()
        try await app.test(.GET, "api/conversations/\(other.id.uuidString)/files", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(try res.content.decode([String].self), [])
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)/files/..%2Fkeys.json", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.GET, "api/conversations/\(conversation.id.uuidString)/files", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
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
        _ = try await memory.setEnabled(ownerID: "shared-server-token", true)
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

    func testScheduleRoutesValidatePersistAndClear() async throws {
        let conversation = try await createConversation()
        let id = conversation.id.uuidString
        try await app.test(.PUT, "api/conversations/\(id)/schedule", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ScheduleSetBody(prompt: "Refresh the list", intervalMinutes: 45, language: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        try await app.test(.PUT, "api/conversations/\(id)/schedule", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ScheduleSetBody(prompt: "Refresh the list", intervalMinutes: 60, language: nil), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let scheduled = try res.content.decode(Conversation.self)
            XCTAssertEqual(scheduled.schedule?.prompt, "Refresh the list")
            XCTAssertEqual(scheduled.schedule?.intervalMinutes, 60)
            XCTAssertEqual(scheduled.schedule?.language, "en")
        })
        // Cookie writes need the CSRF header; bearer-token writes do not (above).
        try await app.test(.DELETE, "api/conversations/\(id)/schedule", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.DELETE, "api/conversations/\(id)/schedule", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertNil(try res.content.decode(Conversation.self).schedule)
        })
    }

    func testConversationVoiceUsesPersistentConversationOwnership() async throws {
        let conversation = try await createConversation()
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/transcribe", beforeRequest: { req in
            self.authorize(&req)
            req.headers.contentType = HTTPMediaType(type: "audio", subType: "webm")
            req.body = ByteBuffer(bytes: [1, 2, 3])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .conflict, res.body.string)
        })
        try await app.test(.POST, "api/conversations/\(UUID().uuidString)/transcribe", beforeRequest: { req in
            self.authorize(&req)
            req.headers.contentType = HTTPMediaType(type: "audio", subType: "webm")
            req.body = ByteBuffer(bytes: [1, 2, 3])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
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

    func testProjectUploadDownloadAndOwnerIsolation() async throws {
        let conversation = try await createConversation()
        let id = conversation.id.uuidString
        try await app.test(.POST, "api/conversations/\(id)/project/uploads", beforeRequest: { req in
            self.authorize(&req)
            req.headers.replaceOrAdd(name: "X-AgentSam-Path", value: "assets%2Fsample.bin")
            req.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
            req.body = ByteBuffer(bytes: [0, 1, 2, 255])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created, res.body.string)
            XCTAssertEqual(try res.content.decode(UploadedProjectFile.self).path, "project:assets/sample.bin")
        })
        try await app.test(.POST, "api/conversations/\(id)/project/uploads", beforeRequest: { req in
            self.authorize(&req)
            req.headers.replaceOrAdd(name: "X-AgentSam-Path", value: "index.html")
            req.body = ByteBuffer(string: "<h1>Shared</h1>")
        }, afterResponse: { res async in XCTAssertEqual(res.status, .created, res.body.string) })
        try await app.test(.GET, "api/conversations/\(id)/project/files/assets%2Fsample.bin", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.GET, "api/conversations/\(id)/project/files/index.html", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "<h1>Shared</h1>")
        })
        try await app.test(.GET, "api/conversations/\(id)/project/download/assets%2Fsample.bin", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Array(res.body.readableBytesView), [0, 1, 2, 255])
        })
        let sameProject = try await createConversation()
        try await app.test(.GET, "api/conversations/\(sameProject.id.uuidString)/project/files", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([String].self), ["assets/sample.bin", "index.html"])
        })
        let otherOwner = try await ConversationStore(root: directory).create(ownerID: "another-owner", projectName: "Launch")
        try await app.test(.GET, "api/conversations/\(otherOwner.id.uuidString)/project/files", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.POST, "api/conversations/\(id)/project/uploads", beforeRequest: { req in
            self.authorize(&req)
            req.headers.replaceOrAdd(name: "X-AgentSam-Path", value: "..%2Fescape.txt")
            req.body = ByteBuffer(string: "no")
        }, afterResponse: { res async in XCTAssertEqual(res.status, .badRequest) })
    }

    func testFileDeletionApprovalExecutesOnlyOnce() async throws {
        let conversation = try await createConversation()
        let workspace = ChatWorkspaceStore(root: directory)
        _ = await workspace.write(conversationID: conversation.id, name: "remove.txt", content: "remove after approval")
        _ = await workspace.write(conversationID: conversation.id, name: "keep.txt", content: "keep after denial")
        let access = try XCTUnwrap(app.storage[ServerContextKey.self]).access
        let deletion = await access.actions.request(AgentActionRequest(ownerID: conversation.ownerID, conversationID: conversation.id, kind: .fileDelete, title: "Delete remove.txt?", detail: "Test", toolName: "chat_delete_file", arguments: .object([("path", .string("remove.txt"))]), fileScope: .conversation))
        let denied = await access.actions.request(AgentActionRequest(ownerID: conversation.ownerID, conversationID: conversation.id, kind: .fileDelete, title: "Delete keep.txt?", detail: "Test", toolName: "chat_delete_file", arguments: .object([("path", .string("keep.txt"))]), fileScope: .conversation))
        let before = await workspace.read(conversationID: conversation.id, name: "remove.txt")
        XCTAssertEqual(before, "remove after approval")
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/actions/\(deletion.id.uuidString)", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ActionDecisionBody(approve: true), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode([AgentActionRequest].self).first(where: { $0.id == deletion.id })?.status, .completed)
        })
        let removed = await workspace.read(conversationID: conversation.id, name: "remove.txt")
        XCTAssertNil(removed)
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/actions/\(deletion.id.uuidString)", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ActionDecisionBody(approve: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .conflict) })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/actions/\(denied.id.uuidString)", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ActionDecisionBody(approve: false), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([AgentActionRequest].self).first(where: { $0.id == denied.id })?.status, .denied)
        })
        let kept = await workspace.read(conversationID: conversation.id, name: "keep.txt")
        XCTAssertEqual(kept, "keep after denial")
    }

    func testConnectorApprovalIsSingleUseAndDoesNotCallDisabledProvider() async throws {
        let conversation = try await createConversation()
        let context = try XCTUnwrap(app.storage[ServerContextKey.self])
        var cloudflare = await context.connectors.config(for: .cloudflare)
        cloudflare.enabled = false
        await context.connectors.setConfig(cloudflare)
        let access = context.access
        let action = await access.actions.request(AgentActionRequest(ownerID: conversation.ownerID, conversationID: conversation.id, kind: .connectorWrite, title: "Approve Cloudflare write", detail: "Test", toolName: "cloudflare_dns_create", arguments: .object([("raw", .string("{}"))])))
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/actions/\(action.id.uuidString)", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ActionDecisionBody(approve: true), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let saved = try XCTUnwrap(try res.content.decode([AgentActionRequest].self).first(where: { $0.id == action.id }))
            XCTAssertEqual(saved.status, .failed)
            XCTAssertTrue(saved.result?.contains("disabled") == true)
        })
        try await app.test(.POST, "api/conversations/\(conversation.id.uuidString)/actions/\(action.id.uuidString)", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ActionDecisionBody(approve: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .conflict) })
    }

    func testHostGrantRoutesAreAdminOnlyAndRevocable() async throws {
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-host-grant-\(UUID().uuidString)")
        hostDirectory = host
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        var grant: HostFolderGrant?
        try await app.test(.POST, "api/access/host-grants", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(HostGrantBody(path: host.path, canWrite: false), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created, res.body.string)
            grant = try res.content.decode(HostFolderGrant.self)
        })
        let id = try XCTUnwrap(grant?.id)
        try await app.test(.GET, "api/access/host-grants", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([HostFolderGrant].self).map(\.id), [id])
        })
        let accounts = try XCTUnwrap(app.storage[ServerContextKey.self]).accounts
        let member = try await accounts.createUser(email: "member@example.com", name: "Member", role: .member, passwordHash: try await Passwords.hash("member test password"))
        let (_, memberToken) = try await accounts.createAPIToken(userID: member.id, name: "Member token")
        try await app.test(.GET, "api/access/host-grants", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
        try await app.test(.POST, "api/access/host-grants", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            try req.content.encode(HostGrantBody(path: host.path, canWrite: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
        try await app.test(.POST, "api/access/host-grants", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(HostGrantBody(path: directory.path, canWrite: true), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .badRequest) })
        try await app.test(.DELETE, "api/access/host-grants/\(id.uuidString)", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })
    }

    func testWorkspaceKnowledgeDiscoversRefreshesAndExportsDocuments() async throws {
        _ = try await createConversation()
        try await app.test(.GET, "api/workspace/knowledge", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "api/workspace/knowledge", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let knowledge = try res.content.decode(WorkspaceKnowledge.self)
            XCTAssertEqual(knowledge.status, .ready)
            XCTAssertEqual(knowledge.refreshCount, 1)
            XCTAssertEqual(knowledge.documents.map(\.id), WorkspaceKnowledgeDocumentID.allCases)
            XCTAssertTrue(knowledge.documents.first { $0.id == .projects }?.markdown.contains("Launch") == true)
            XCTAssertFalse(knowledge.promptSummary.contains(token))
        })
        try await app.test(.POST, "api/workspace/knowledge/refresh", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode(WorkspaceKnowledge.self).refreshCount, 2)
        })
        try await app.test(.GET, "api/workspace/knowledge/connections/export", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "text/markdown; charset=utf-8")
            XCTAssertTrue(res.body.string.contains("# Workspace connections"))
            XCTAssertTrue(res.body.string.contains("Gmail"))
        })
        try await app.test(.GET, "api/workspace/knowledge/not-a-document/export", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
