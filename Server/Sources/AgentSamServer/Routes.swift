import Vapor
import AgentSamCore
import Foundation

public func configure(_ app: Application) async throws {
    let ctx = ServerContext.make()
    await ctx.seedIfEmpty()
    try? await app.storage.setWithAsyncShutdown(ServerContextKey.self, to: ctx)

    if Environment.get("AGENTSAM_BIND_ALL") != nil || Environment.get("AGENTSAM_HOST") != nil {
        app.http.server.configuration.hostname = Environment.get("AGENTSAM_HOST") ?? "0.0.0.0"
    }
    if let portText = Environment.get("AGENTSAM_PORT"), let port = Int(portText) {
        app.http.server.configuration.port = port
    }

    routes(app, ctx: ctx)

    let dataPath = await ctx.dataDir.path
    app.logger.info("AgentSam server running. Data directory: \(dataPath)")
}

struct ServerContextKey: StorageKey {
    typealias Value = ServerContext
}

func routes(_ app: Application, ctx: ServerContext) {
    app.get("healthz") { _ async -> String in
        "ok"
    }

    let api = app.grouped("api").grouped(TokenMiddleware(token: ctx.token))

    api.get("info") { req async throws -> Response in
        let teams = await ctx.store.loadTeams()
        let missions = await ctx.store.listMissions(limit: 500)
        let running = await ctx.engine.activeMissionIDs
        let info = ServerInfo(
            name: "AgentSam Server",
            teams: teams.count,
            missions: missions.count,
            runningMissions: running
        )
        return try req.json(info)
    }

    // MARK: Teams

    api.get("teams") { req async throws -> Response in
        let teams = await ctx.store.loadTeams()
        return try req.json(teams)
    }

    api.get("teams", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad team id")
        }
        guard let team = await ctx.store.team(id: id) else {
            throw Abort(.notFound, reason: "Team not found")
        }
        return try req.json(team)
    }

    api.post("teams") { req async throws -> Response in
        let input = try req.decodeJSON(TeamInput.self)
        let team = try await ctx.upsertTeam(input: input, id: nil)
        return try req.json(team, status: .created)
    }

    api.put("teams", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad team id")
        }
        let input = try req.decodeJSON(TeamInput.self)
        let team = try await ctx.upsertTeam(input: input, id: id)
        return try req.json(team)
    }

    api.delete("teams", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad team id")
        }
        guard await ctx.store.team(id: id) != nil else {
            throw Abort(.notFound, reason: "Team not found")
        }
        await ctx.store.deleteTeam(id: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    // MARK: Providers

    api.get("providers") { req async throws -> Response in
        let providers = await ctx.store.loadProviders()
        var statuses: [ProviderStatus] = []
        for provider in providers {
            let key = await ctx.keyRing.get(provider.keyAccount)
            statuses.append(ProviderStatus(provider: provider, hasKey: key != nil))
        }
        return try req.json(statuses)
    }

    api.post("providers") { req async throws -> Response in
        let provider = try req.decodeJSON(ProviderConfig.self)
        var providers = await ctx.store.loadProviders()
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        await ctx.store.saveProviders(providers)
        return try req.json(provider, status: .created)
    }

    api.post("providers", ":id", "key") { req async throws -> Response in
        guard let idString = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing provider id")
        }
        let providers = await ctx.store.loadProviders()
        guard let provider = providers.first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: "Unknown provider: \(idString)")
        }
        let body = try req.decodeJSON(KeyBody.self)
        try await ctx.keyRing.set(body.key, for: provider.keyAccount)
        return try req.json(AckResult(ok: true, detail: "Key stored for \(provider.name)"))
    }

    api.post("providers", ":id", "test") { req async throws -> Response in
        guard let idString = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing provider id")
        }
        let providers = await ctx.store.loadProviders()
        guard let provider = providers.first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: "Unknown provider: \(idString)")
        }
        guard let key = await ctx.keyRing.get(provider.keyAccount) else {
            return try req.json(ProviderTestResult(ok: false, message: "No API key saved for \(provider.name)."))
        }
        let result = await LLMClient().testConnection(provider: provider, key: key)
        return try req.json(ProviderTestResult(ok: result.ok, message: result.message))
    }

    // MARK: Missions

    api.post("missions") { req async throws -> Response in
        let body = try req.decodeJSON(MissionStartBody.self)
        let mission = try await ctx.startMission(teamID: body.teamID, objective: body.objective)
        return try req.json(mission, status: .created)
    }

    api.get("missions") { req async throws -> Response in
        let limit = req.query[Int.self, at: "limit"] ?? 100
        let missions = await ctx.store.listMissions(limit: limit)
        return try req.json(missions)
    }

    api.get("missions", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad mission id")
        }
        guard let mission = await ctx.store.mission(id: id) else {
            throw Abort(.notFound, reason: "Mission not found")
        }
        let events = await ctx.store.events(missionID: id, afterSeq: 0)
        let deliverables = await ctx.store.deliverables(missionID: id)
        let running = await ctx.engine.isRunning(missionID: id)
        return try req.json(MissionDetail(mission: mission, events: events, deliverables: deliverables, running: running))
    }

    api.get("missions", ":id", "events") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad mission id")
        }
        let afterSeq = req.query[Int.self, at: "afterSeq"] ?? 0
        let events = await ctx.store.events(missionID: id, afterSeq: afterSeq)
        return try req.json(events)
    }

    api.get("missions", ":id", "deliverables", ":name") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad mission id")
        }
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing deliverable name")
        }
        guard let content = await ctx.store.deliverable(missionID: id, name: name) else {
            throw Abort(.notFound, reason: "Deliverable not found")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    api.post("missions", ":id", "stop") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad mission id")
        }
        await ctx.engine.stop(missionID: id)
        return try req.json(AckResult(ok: true, detail: "Stop requested."))
    }

    api.delete("missions", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: "Bad mission id")
        }
        await ctx.engine.stop(missionID: id)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await ctx.store.deleteMission(id: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    // MARK: Live updates

    api.webSocket("missions", ":id", "live") { req, ws in
        let missionID: UUID
        if let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) {
            missionID = id
        } else {
            Task { try? await ws.close(code: .goingAway) }
            return
        }
        var liveTask: Task<Void, Never>!
        liveTask = Task {
            let stream = await ctx.store.subscribe(missionID: missionID)
            for await event in stream {
                if let data = try? Request.jsonEncoder.encode(event),
                   let text = String(data: data, encoding: .utf8) {
                    try? await ws.send(text)
                }
                if event.kind == .missionEnd {
                    try? await ws.close()
                    break
                }
            }
        }
        ws.onClose.whenComplete { _ in
            liveTask.cancel()
        }
    }
}
