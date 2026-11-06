import Vapor
import Foundation
import AgentSamCore

/// Lets the coordinator chat act on missions through the server's own store and engine.
struct ServerChatMissionControl: ChatMissionControl {
    let ctx: ServerContext

    func teams() async -> [Team] { await ctx.store.loadTeams() }
    func missions(limit: Int) async -> [Mission] { await ctx.store.listMissions(limit: limit) }
    func mission(id: UUID) async -> Mission? { await ctx.store.mission(id: id) }
    func isRunning(missionID: UUID) async -> Bool { await ctx.engine.isRunning(missionID: missionID) }

    func recentEvents(missionID: UUID, limit: Int) async -> [RunEvent] {
        Array(await ctx.store.events(missionID: missionID, afterSeq: 0).suffix(limit))
    }

    func deliverable(missionID: UUID, name: String) async -> String? {
        await ctx.store.deliverable(missionID: missionID, name: name)
    }

    func startMission(team: Team, objective: String, language: String) async throws -> Mission {
        try await ctx.startMission(teamID: team.id, objective: objective, launchedBy: "Coordinator chat", language: language)
    }

    func stopMission(id: UUID) async { await ctx.engine.stop(missionID: id) }
}

struct ChatCreateBody: Decodable {
    var teamID: UUID?
}

struct ChatMessageBody: Decodable {
    var text: String
}

struct ChatConfirmBody: Decodable {
    var approve: Bool
}

struct ChatSettingsBody: Decodable {
    var defaultTeamID: UUID?
}

struct ChatSettingsResponse: Encodable {
    var defaultTeamID: UUID?
    /// The team actually used when a chat is started without one: the default, or the first team.
    var effectiveTeamID: UUID?
}

extension Principal {
    /// Chats are personal: each user sees only their own. The shared server token counts as one owner.
    var chatOwnerID: String {
        userID?.uuidString ?? "server-token"
    }
}

/// Coordinator chat: `/api/chats` and `/api/chat-settings`.
func chatRoutes(_ api: RoutesBuilder, admin adminAPI: RoutesBuilder, ctx: ServerContext) {
    let chats = ChatStore(root: ctx.dataDir)
    let engine = CoordinatorChatEngine(
        store: chats,
        missions: ServerChatMissionControl(ctx: ctx),
        keyRing: ctx.keyRing,
        providers: { await ctx.store.loadProviders() }
    )

    @Sendable func effectiveTeamID() async -> UUID? {
        let teams = await ctx.store.loadTeams()
        let settings = await chats.loadSettings()
        if let id = settings.defaultTeamID, teams.contains(where: { $0.id == id }) { return id }
        return teams.first?.id
    }

    @Sendable func ownedChat(_ req: Request) async throws -> CoordinatorChat {
        let lang = SrvL10n.lang(for: req)
        let principal = try req.requirePrincipal()
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString),
              let chat = await chats.chat(id: id), chat.ownerID == principal.chatOwnerID else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.chatNotFound", lang: lang))
        }
        return chat
    }

    @Sendable func respond(_ req: Request, _ result: () async throws -> CoordinatorChat?) async throws -> Response {
        do {
            guard let chat = try await result() else {
                throw Abort(.notFound, reason: SrvL10n.t("srv.chatNotFound", lang: SrvL10n.lang(for: req)))
            }
            return try req.json(chat.publicRepresentation)
        } catch CoordinatorChatError.busy {
            throw Abort(.conflict, reason: SrvL10n.t("srv.chatBusy", lang: SrvL10n.lang(for: req)))
        }
    }

    api.get("chat-settings") { req async throws -> Response in
        let settings = await chats.loadSettings()
        return try req.json(ChatSettingsResponse(defaultTeamID: settings.defaultTeamID, effectiveTeamID: await effectiveTeamID()))
    }

    adminAPI.put("chat-settings") { req async throws -> Response in
        let body = try req.decodeJSON(ChatSettingsBody.self)
        if let id = body.defaultTeamID, await ctx.store.team(id: id) == nil {
            throw Abort(.notFound, reason: SrvL10n.t("srv.teamNotFound", lang: SrvL10n.lang(for: req)))
        }
        await chats.saveSettings(ChatSettings(defaultTeamID: body.defaultTeamID))
        return try req.json(ChatSettingsResponse(defaultTeamID: body.defaultTeamID, effectiveTeamID: await effectiveTeamID()))
    }

    api.get("chats") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        return try req.json(await chats.list(ownerID: principal.chatOwnerID))
    }

    api.post("chats") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let principal = try req.requirePrincipal()
        let body = (try? req.decodeJSON(ChatCreateBody.self)) ?? ChatCreateBody()
        let teamID: UUID?
        if let requested = body.teamID {
            teamID = requested
        } else {
            teamID = await effectiveTeamID()
        }
        guard let teamID, let team = await ctx.store.team(id: teamID) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.teamNotFound", lang: lang))
        }
        let chat = CoordinatorChat(ownerID: principal.chatOwnerID, team: team, language: lang)
        await chats.save(chat)
        return try req.json(chat.publicRepresentation, status: .created)
    }

    api.get("chats", ":id") { req async throws -> Response in
        try req.json(try await ownedChat(req).publicRepresentation)
    }

    api.post("chats", ":id", "messages") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let chat = try await ownedChat(req)
        let body = try req.decodeJSON(ChatMessageBody.self)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8_000 else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.chatMessageLength", lang: lang))
        }
        return try await respond(req) { try await engine.send(chatID: chat.id, text: text) }
    }

    api.post("chats", ":id", "confirm") { req async throws -> Response in
        let chat = try await ownedChat(req)
        let body = try req.decodeJSON(ChatConfirmBody.self)
        return try await respond(req) { try await engine.resolvePending(chatID: chat.id, approve: body.approve) }
    }

    api.delete("chats", ":id") { req async throws -> Response in
        let chat = try await ownedChat(req)
        await chats.delete(id: chat.id)
        return try req.json(AckResult(ok: true, detail: nil))
    }
}
