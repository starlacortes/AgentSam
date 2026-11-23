@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

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

    func testArchiveHidesRestoresAndPurgesPastRetention() async throws {
        let kept = try await createConversation()
        let archived = try await createConversation()
        let id = archived.id.uuidString

        // Nothing configured yet: the web app asks the first time.
        try await app.test(.GET, "api/workspace/archive", beforeRequest: authorize, afterResponse: { res async throws in
            let settings = try res.content.decode(ArchiveSettings.self)
            XCTAssertFalse(settings.configured)
            XCTAssertNil(settings.retentionDays)
        })
        try await app.test(.POST, "api/conversations/\(id)/archive", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertNotNil(try res.content.decode(Conversation.self).archivedAt)
        })
        try await app.test(.GET, "api/conversations", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self).map(\.id), [kept.id])
        })
        try await app.test(.GET, "api/conversations?archived=1", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self).map(\.id), [archived.id])
        })

        // Restore puts it back in the sidebar list.
        try await app.test(.DELETE, "api/conversations/\(id)/archive", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertNil(try res.content.decode(Conversation.self).archivedAt)
        })
        try await app.test(.GET, "api/conversations?archived=true", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self), [])
        })

        // Retention must be one of the offered choices.
        try await app.test(.PUT, "api/workspace/archive", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ArchiveSettingsBody(retentionDays: 12), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        // "Never delete" keeps even an old archive.
        let store = ConversationStore(root: directory)
        try await store.setArchived(id: archived.id, ownerID: "shared-server-token", archived: true, now: Date().addingTimeInterval(-40 * 86_400))
        try await app.test(.PUT, "api/workspace/archive", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ArchiveSettingsBody(retentionDays: nil), as: .json)
        }, afterResponse: { res async throws in
            let settings = try res.content.decode(ArchiveSettings.self)
            XCTAssertTrue(settings.configured)
            XCTAssertNil(settings.retentionDays)
        })
        try await app.test(.GET, "api/conversations?archived=1", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self).map(\.id), [archived.id])
        })

        // 30 days: the 40-day-old archive is deleted, with its folder; the live chat stays.
        let folder = directory.appendingPathComponent("conversations/\(id)/files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await app.test(.PUT, "api/workspace/archive", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ArchiveSettingsBody(retentionDays: 30), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode(ArchiveSettings.self).retentionDays, 30)
        })
        try await app.test(.GET, "api/conversations?archived=1", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self), [])
        })
        try await app.test(.GET, "api/conversations/\(id)", beforeRequest: authorize, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
        try await app.test(.GET, "api/conversations", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([ConversationSummary].self).map(\.id), [kept.id])
        })
    }

    func testWritingInAnArchivedChatRestoresIt() async throws {
        let conversation = try await createConversation()
        let store = ConversationStore(root: directory)
        try await store.setArchived(id: conversation.id, ownerID: "shared-server-token", archived: true)
        let updated = try await store.append(id: conversation.id, ownerID: "shared-server-token", message: ConversationMessage(role: .user, text: "Back to this"))
        XCTAssertNil(updated.archivedAt)
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

    func testSetTimeSchedulesAndTriggerRoutes() async throws {
        let conversation = try await createConversation()
        let id = conversation.id.uuidString
        try await app.test(.PUT, "api/conversations/\(id)/schedule", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ScheduleSetBody(prompt: "Morning digest", at: "08:00", days: "weekdays", timeZone: "Europe/Madrid"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let saved = try res.content.decode(Conversation.self)
            XCTAssertEqual(saved.schedule?.at?.label, "weekdays at 08:00")
            XCTAssertEqual(saved.timeZone, "Europe/Madrid")
        })
        try await app.test(.PUT, "api/conversations/\(id)/schedule", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(ScheduleSetBody(prompt: "Morning digest", at: "8am"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        // Gmail triggers need Gmail connected.
        try await app.test(.POST, "api/conversations/\(id)/triggers", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(TriggerAddBody(kind: "gmail", prompt: "File it", query: "from:billing@example.com"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        var token = ""
        var triggerID = ""
        try await app.test(.POST, "api/conversations/\(id)/triggers", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(TriggerAddBody(kind: "webhook", prompt: "Tell me how the deploy went"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let trigger = try XCTUnwrap(try res.content.decode(Conversation.self).triggers.first)
            token = try XCTUnwrap(trigger.token)
            triggerID = trigger.id.uuidString
        })
        // The webhook needs no login, only the secret address.
        try await app.test(.POST, "api/hooks/\(String(repeating: "a", count: 64))", afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        try await app.test(.POST, "api/hooks/\(token)", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: #"{"status":"ok"}"#)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .accepted, res.body.string)
        })
        try await app.test(.GET, "api/conversations/\(id)", beforeRequest: authorize, afterResponse: { res async throws in
            let stored = try res.content.decode(Conversation.self)
            let run = try XCTUnwrap(stored.messages.first { $0.role == .user })
            XCTAssertEqual(run.text, "Tell me how the deploy went")
            XCTAssertTrue(run.trigger?.data.contains(#"{"status":"ok"}"#) ?? false)
        })
        try await app.test(.DELETE, "api/conversations/\(id)/triggers/\(triggerID)", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertTrue(try res.content.decode(Conversation.self).triggers.isEmpty)
        })
        try await app.test(.POST, "api/hooks/\(token)", afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
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

    func testStandingPermissionsAreAdminEditableAndOwnerScoped() async throws {
        try await app.test(.GET, "api/access/permissions", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let view = try res.content.decode(PermissionsView.self)
            XCTAssertTrue(view.canEdit)
            XCTAssertTrue(view.policy.rules.isEmpty)
            XCTAssertTrue(view.tools.contains("gmail_send"))
            XCTAssertFalse(view.workstation, "the workstation is off unless AGENTSAM_WORKSTATION=1")
            XCTAssertFalse(view.tools.contains("workstation_run"))
        })
        let policy = PermissionPolicy(rules: ["gmail_draft": PermissionRule(mode: .allow, maxPerDay: 5), "run_terminal": PermissionRule(mode: .allow)], approvalMinutes: 720)
        try await app.test(.PUT, "api/access/permissions", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(policy, as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let view = try res.content.decode(PermissionsView.self)
            XCTAssertEqual(view.policy.rules["gmail_draft"], PermissionRule(mode: .allow, maxPerDay: 5))
            XCTAssertNil(view.policy.rules["run_terminal"], "only write tools can have a rule")
            XCTAssertEqual(view.policy.approvalMinutes, 720)
        })
        let accounts = try XCTUnwrap(app.storage[ServerContextKey.self]).accounts
        let member = try await accounts.createUser(email: "member-perms@example.com", name: "Member", role: .member, passwordHash: try await Passwords.hash("member test password"))
        let (_, memberToken) = try await accounts.createAPIToken(userID: member.id, name: "Member token")
        try await app.test(.GET, "api/access/permissions", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let view = try res.content.decode(PermissionsView.self)
            XCTAssertFalse(view.canEdit)
            XCTAssertTrue(view.policy.rules.isEmpty, "rules belong to the admin who set them")
        })
        try await app.test(.PUT, "api/access/permissions", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            try req.content.encode(policy, as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden) })
    }

    func testMCPServersAndWorkstationAreAdminOnly() async throws {
        try await app.test(.GET, "api/mcp/servers", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode([MCPServerView].self).count, 0)
        })
        try await app.test(.POST, "api/mcp/servers", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(MCPServerAddBody(name: "x", url: "http://example.test/mcp", token: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest, "plain HTTP to another machine is refused")
        })
        try await app.test(.GET, "api/mcp/catalog", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let catalog = try res.content.decode([MCPSuggestionView].self)
            XCTAssertEqual(catalog.count, MCPSuggestion.catalog.count)
            XCTAssertTrue(catalog.allSatisfy { !$0.added && $0.url.hasPrefix("https://") })
        })
        try await app.test(.GET, "api/access/workstation", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertFalse(try res.content.decode(WorkstationView.self).enabled)
        })
        let accounts = try XCTUnwrap(app.storage[ServerContextKey.self]).accounts
        let member = try await accounts.createUser(email: "member-mcp@example.com", name: "Member", role: .member, passwordHash: try await Passwords.hash("member test password"))
        let (_, memberToken) = try await accounts.createAPIToken(userID: member.id, name: "Member token")
        for path in ["api/mcp/servers", "api/mcp/catalog", "api/access/workstation"] {
            try await app.test(.GET, path, beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            }, afterResponse: { res async in XCTAssertEqual(res.status, .forbidden, path) })
        }
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
