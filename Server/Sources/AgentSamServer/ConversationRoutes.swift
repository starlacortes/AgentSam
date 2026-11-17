import Vapor
import AgentSamCore
import Foundation

extension ConversationError: AbortError {
    public var status: HTTPResponseStatus {
        switch self {
        case .notFound: .notFound
        case .alreadyRunning: .conflict
        case .persistence: .internalServerError
        case .emptyMessage, .messageTooLong, .invalidProposal, .proposalHandled, .noProvider, .missingProviderKey: .badRequest
        }
    }

    public var reason: String { errorDescription ?? "The conversation request could not be completed." }
}

extension Principal {
    var conversationOwnerID: String { userID?.uuidString ?? "shared-server-token" }
}

struct ConversationCreateBody: Content {
    var projectName: String?
}

struct ConversationMessageBody: Content {
    var text: String?
    var language: String?
    /// Photos uploaded first with `POST conversations/:id/photos`.
    var photoIDs: [String]?
    /// True when the user spoke this message in voice mode.
    var spoken: Bool?
}

struct MemoryPatchBody: Content {
    var enabled: Bool
}

struct GuidePatchBody: Content {
    var completed: Bool
}

struct ScheduleSetBody: Content {
    var prompt: String
    var intervalMinutes: Int
    var language: String?
}

struct ProposalApplication: Encodable {
    var team: Team
    var conversation: Conversation
}

func conversationRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    conversationVoiceRoutes(api, ctx: ctx)

    api.get("conversations") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.conversations.list(ownerID: owner))
    }

    api.post("conversations") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(ConversationCreateBody.self)
        let conversation = try await ctx.conversations.create(ownerID: owner, projectName: body.projectName ?? "Personal")
        return try req.json(conversation, status: .created)
    }

    api.get("conversations", ":id") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner) else { throw ConversationError.notFound }
        return try req.json(conversation)
    }

    api.post("conversations", ":id", "messages") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let body = try req.decodeJSON(ConversationMessageBody.self)
        let id = try req.conversationID
        let ids = body.photoIDs ?? []
        guard ids.count <= ConversationPhotoStore.maxPerMessage else {
            throw Abort(.badRequest, reason: "Attach at most \(ConversationPhotoStore.maxPerMessage) photos to one message.")
        }
        let photoStore = ConversationPhotoStore(root: ctx.store.root)
        let photos = try ids.map { photoID in
            guard let photo = photoStore.attachment(conversationID: id, id: photoID) else {
                throw Abort(.badRequest, reason: "A photo is missing. Remove it and add it again.")
            }
            return photo
        }
        let conversation = try await ctx.conversationEngine.send(
            conversationID: id,
            ownerID: principal.conversationOwnerID,
            text: body.text ?? "",
            launchedBy: principal.name,
            language: body.language ?? SrvL10n.lang(for: req),
            photos: photos,
            spoken: body.spoken ?? false
        )
        return try req.json(conversation, status: .accepted)
    }

    // Photos are uploaded one at a time as raw bytes (the browser has already shrunk them),
    // then referenced by id when the message is sent.
    api.on(.POST, "conversations", ":id", "photos", body: .collect(maxSize: ByteCount(value: ConversationPhotoStore.maxBytes))) { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard try await ctx.conversations.get(id: id, ownerID: owner) != nil else { throw ConversationError.notFound }
        guard let buffer = req.body.data, buffer.readableBytes > 0,
              let photo = ConversationPhotoStore(root: ctx.store.root).save(conversationID: id, data: Data(buffer.readableBytesView)) else {
            throw Abort(.badRequest, reason: "Choose a JPEG, PNG, WebP, or GIF photo of at most 5 MB.")
        }
        return try req.json(photo, status: .created)
    }

    api.get("conversations", ":id", "photos", ":photoID") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard try await ctx.conversations.get(id: id, ownerID: owner) != nil,
              let photoID = req.parameters.get("photoID"),
              let photo = ConversationPhotoStore(root: ctx.store.root).load(conversationID: id, id: photoID) else {
            throw Abort(.notFound, reason: "Photo not found.")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: photo.mediaType)
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        // A photo never changes once uploaded.
        headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=86400, immutable")
        return Response(status: .ok, headers: headers, body: .init(data: photo.data))
    }

    api.post("conversations", ":id", "stop") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard let conversation = try await ctx.conversations.get(id: id, ownerID: owner) else { throw ConversationError.notFound }
        for message in conversation.messages {
            for missionID in message.missionIDs { await ctx.engine.stop(missionID: missionID) }
        }
        await ctx.conversationEngine.stop(conversationID: id, ownerID: owner, language: SrvL10n.lang(for: req))
        return try req.json(AckResult(ok: true, detail: nil), status: .accepted)
    }

    api.delete("conversations", ":id") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        try await ctx.conversations.delete(id: id, ownerID: owner)
        ConversationPhotoStore(root: ctx.store.root).removeAll(conversationID: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    api.post("conversations", ":id", "proposals", ":proposalID", "apply") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard let proposalID = req.parameters.get("proposalID").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Invalid team proposal ID.")
        }
        guard let conversation = try await ctx.conversations.get(id: id, ownerID: owner),
              let proposal = conversation.messages.compactMap(\.proposal).first(where: { $0.id == proposalID }) else {
            throw ConversationError.notFound
        }
        guard proposal.status == .pending else { throw ConversationError.proposalHandled }
        let teams = await ctx.store.loadTeams()
        let providers = await ctx.store.loadProviders()
        let team = try TeamProposalValidation.validate(proposal, teams: teams, providers: providers)
        await ctx.saveTeam(team)
        let updated = try await ctx.conversations.updateProposal(id: id, ownerID: owner, proposalID: proposalID, status: .applied)
        return try req.json(ProposalApplication(team: team, conversation: updated))
    }

    api.post("conversations", ":id", "proposals", ":proposalID", "dismiss") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard let proposalID = req.parameters.get("proposalID").flatMap(UUID.init(uuidString:)) else {
            throw Abort(.badRequest, reason: "Invalid team proposal ID.")
        }
        let conversation = try await ctx.conversations.updateProposal(id: id, ownerID: owner, proposalID: proposalID, status: .dismissed)
        return try req.json(conversation)
    }

    api.get("workspace", "memory") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.memory.state(ownerID: owner))
    }

    // Ada's per-conversation workspace: files she wrote with the chat tools.
    api.get("conversations", ":id", "files") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner) else {
            throw ConversationError.notFound
        }
        return try req.json(await ctx.chatWorkspace.files(conversationID: conversation.id))
    }

    api.get("conversations", ":id", "files", ":name") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner) else {
            throw ConversationError.notFound
        }
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "A file name is required.")
        }
        guard let content = await ctx.chatWorkspace.read(conversationID: conversation.id, name: name) else {
            throw Abort(.notFound, reason: "File not found.")
        }
        var headers = HTTPHeaders()
        // Always plain text: workspace HTML is previewed in a sandboxed frame, never rendered from this origin.
        headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    api.patch("workspace", "memory") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(MemoryPatchBody.self)
        return try req.json(try await ctx.memory.setEnabled(ownerID: owner, body.enabled))
    }

    api.get("workspace", "memory", "export") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let memory = await ctx.memory.state(ownerID: owner)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=agentsam-memory.md")
        return Response(status: .ok, headers: headers, body: .init(string: memory.markdown))
    }

    api.get("workspace", "knowledge") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.knowledge.refresh(ownerID: owner))
    }

    api.post("workspace", "knowledge", "refresh") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.knowledge.refresh(ownerID: owner, force: true))
    }

    api.get("workspace", "knowledge", ":id", "export") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let id = req.parameters.get("id").flatMap(WorkspaceKnowledgeDocumentID.init(rawValue:)) else {
            throw Abort(.notFound, reason: "Unknown workspace knowledge document.")
        }
        let knowledge = await ctx.knowledge.refresh(ownerID: owner)
        guard let document = knowledge.documents.first(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Workspace knowledge document not found.")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=agentsam-\(id.rawValue).md")
        return Response(status: .ok, headers: headers, body: .init(string: document.markdown))
    }

    api.get("workspace", "guide") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.conversations.guide(ownerID: owner))
    }

    api.patch("workspace", "guide") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(GuidePatchBody.self)
        return try req.json(try await ctx.conversations.saveGuide(ownerID: owner, completed: body.completed))
    }

    // MARK: Recurring schedules — the platform wakes the conversation so Ada can run on a timer.

    api.put("conversations", ":id", "schedule") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        let body = try req.decodeJSON(ScheduleSetBody.self)
        guard let schedule = ConversationSchedule.validate(
            prompt: body.prompt,
            intervalMinutes: body.intervalMinutes,
            language: body.language ?? SrvL10n.lang(for: req)
        ) else {
            throw Abort(.badRequest, reason: "The schedule needs a prompt and one of these intervals in minutes: \(ConversationSchedule.allowedIntervals.map(String.init).joined(separator: ", ")).")
        }
        let conversation = try await ctx.conversations.setSchedule(id: id, ownerID: owner, schedule: schedule)
        return try req.json(conversation)
    }

    api.delete("conversations", ":id", "schedule") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        let conversation = try await ctx.conversations.setSchedule(id: id, ownerID: owner, schedule: nil)
        return try req.json(conversation)
    }
}

extension Request {
    var conversationID: UUID {
        get throws {
            guard let id = parameters.get("id").flatMap(UUID.init(uuidString:)) else {
                throw Abort(.badRequest, reason: "Invalid conversation ID.")
            }
            return id
        }
    }
}
