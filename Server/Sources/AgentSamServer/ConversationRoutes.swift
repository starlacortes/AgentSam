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
    var text: String
    var language: String?
}

struct MemoryPatchBody: Content {
    var enabled: Bool
}

struct GuidePatchBody: Content {
    var completed: Bool
}

struct ProposalApplication: Encodable {
    var team: Team
    var conversation: Conversation
}

func conversationRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
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
        let conversation = try await ctx.conversationEngine.send(
            conversationID: req.conversationID,
            ownerID: principal.conversationOwnerID,
            text: body.text,
            launchedBy: principal.name,
            language: body.language ?? SrvL10n.lang(for: req)
        )
        return try req.json(conversation, status: .accepted)
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
        try await ctx.conversations.delete(id: req.conversationID, ownerID: owner)
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
        try req.json(await ctx.memory.state())
    }

    api.patch("workspace", "memory") { req async throws -> Response in
        let body = try req.decodeJSON(MemoryPatchBody.self)
        return try req.json(try await ctx.memory.setEnabled(body.enabled))
    }

    api.get("workspace", "memory", "export") { req async throws -> Response in
        let memory = await ctx.memory.state()
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=agentsam-memory.md")
        return Response(status: .ok, headers: headers, body: .init(string: memory.markdown))
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
