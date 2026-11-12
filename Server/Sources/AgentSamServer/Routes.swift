import Vapor
import AgentSamCore
import Foundation

public func configure(_ app: Application) async throws {
    let ctx = try ServerContext.make()
    await ctx.seedIfEmpty()
    await ctx.reconcileInterruptedMissions()
    await ctx.provisioningRunner.start()
    await app.storage.setWithAsyncShutdown(ServerContextKey.self, to: ctx) { context in
        await context.shutdown()
    }

    if Environment.get("AGENTSAM_BIND_ALL") != nil || Environment.get("AGENTSAM_HOST") != nil {
        app.http.server.configuration.hostname = Environment.get("AGENTSAM_HOST") ?? "0.0.0.0"
    }
    if let portText = Environment.get("AGENTSAM_PORT") ?? Environment.get("PORT"), let port = Int(portText) {
        app.http.server.configuration.port = port
    }

    app.middleware.use(SecurityHeadersMiddleware())
    let webDir = WebApp.directory()
    if let webDir {
        app.middleware.use(FileMiddleware(publicDirectory: webDir, defaultFile: "index.html"))
    }

    routes(app, ctx: ctx)
    WebApp.registerFallback(app, directory: webDir)

    let dataPath = ctx.dataDir.path
    app.logger.info("AgentSam server running. Data directory: \(dataPath)")
}

struct ServerContextKey: StorageKey {
    typealias Value = ServerContext
}

func routes(_ app: Application, ctx: ServerContext) {
    app.get("healthz") { _ async -> String in
        "ok"
    }

    // Google OAuth callback — deliberately NOT token-protected: Google redirects the browser here.
    app.get("api", "connectors", ":id", "callback") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: lang))
        }
        guard let state = req.query[String.self, at: "state"], let entry = await ctx.oauthStates.consume(state) else {
            return oauthResultPage(title: SrvL10n.t("srv.connectionFailed", lang: lang), message: SrvL10n.t("srv.oauthSessionExpired", lang: lang))
        }
        guard entry.connectorID == connectorID else {
            return oauthResultPage(title: SrvL10n.t("srv.connectionFailed", lang: lang), message: SrvL10n.t("srv.oauthMismatch", lang: lang))
        }
        guard let code = req.query[String.self, at: "code"], !code.isEmpty else {
            return oauthResultPage(title: SrvL10n.t("srv.connectionFailed", lang: lang), message: SrvL10n.t("srv.oauthNoCode", lang: lang))
        }
        do {
            let result = try await ctx.connectors.google.exchangeCode(code: code, redirectURI: entry.redirectURI)
            guard let refreshToken = result.refreshToken, !refreshToken.isEmpty else {
                return oauthResultPage(title: SrvL10n.t("srv.connectionFailed", lang: lang), message: SrvL10n.t("srv.oauthNoRefreshToken", lang: lang))
            }
            try ctx.keyRing.set(refreshToken, for: GoogleTokenProvider.refreshAccount(for: connectorID))
            ctx.keyRing.remove(GoogleTokenProvider.cacheAccount(for: connectorID))
            // Back to the web app's Connectors page, which shows the new connection.
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .location, value: "/connectors?connected=\(connectorID.rawValue)")
            return Response(status: .seeOther, headers: headers, body: .init())
        } catch {
            return oauthResultPage(title: SrvL10n.t("srv.connectionFailed", lang: lang), message: error.localizedDescription)
        }
    }

    let api = app.grouped("api").grouped(AuthMiddleware(ctx: ctx))
    let adminAPI = api.grouped(RequireAdminMiddleware())

    authRoutes(app, ctx: ctx, authed: api)
    provisioningRoutes(app, ctx: ctx, admin: adminAPI)
    templateRoutes(api, ctx: ctx)
    conversationRoutes(api, ctx: ctx)
    chatRoutes(api, admin: adminAPI, ctx: ctx)

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
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badTeamID", lang: lang))
        }
        guard let team = await ctx.store.team(id: id) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.teamNotFound", lang: lang))
        }
        return try req.json(team)
    }

    api.post("teams") { req async throws -> Response in
        let input = try req.decodeJSON(TeamInput.self)
        let team = try await ctx.upsertTeam(input: input, id: nil, lang: SrvL10n.lang(for: req))
        return try req.json(team, status: .created)
    }

    api.put("teams", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badTeamID", lang: lang))
        }
        let input = try req.decodeJSON(TeamInput.self)
        let team = try await ctx.upsertTeam(input: input, id: id, lang: lang)
        return try req.json(team)
    }

    api.delete("teams", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badTeamID", lang: lang))
        }
        guard await ctx.store.team(id: id) != nil else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.teamNotFound", lang: lang))
        }
        await ctx.store.deleteTeam(id: id)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    // MARK: Providers

    api.get("providers") { req async throws -> Response in
        let providers = await ctx.store.loadProviders()
        var statuses: [ProviderStatus] = []
        for provider in providers {
            let key = ctx.keyRing.get(provider.keyAccount)
            statuses.append(ProviderStatus(provider: provider, hasKey: key != nil))
        }
        return try req.json(statuses)
    }

    adminAPI.post("providers") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        var provider = try req.decodeJSON(ProviderConfig.self)
        provider.models = provider.models.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !provider.id.isEmpty, provider.id.count <= 40,
              provider.id.unicodeScalars.allSatisfy(idAllowed.contains) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.providerIDInvalid", lang: lang))
        }
        guard !provider.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.providerNeedsName", lang: lang))
        }
        guard let url = URL(string: provider.baseURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.providerBadURL", lang: lang))
        }
        guard !provider.models.isEmpty else { throw Abort(.badRequest, reason: SrvL10n.t("srv.providerNeedsModels", lang: lang)) }
        var providers = await ctx.store.loadProviders()
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        await ctx.store.saveProviders(providers)
        return try req.json(provider, status: .created)
    }

    adminAPI.post("providers", ":id", "key") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.missingProviderID", lang: lang))
        }
        let providers = await ctx.store.loadProviders()
        guard let provider = providers.first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: SrvL10n.tf("srv.unknownProvider", idString, lang: lang))
        }
        let body = try req.decodeJSON(KeyBody.self)
        try ctx.keyRing.set(body.key, for: provider.keyAccount)
        return try req.json(AckResult(ok: true, detail: SrvL10n.tf("srv.keyStored", provider.name, lang: lang)))
    }

    adminAPI.delete("providers", ":id", "key") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id") else {
            throw Abort(.notFound, reason: SrvL10n.tf("srv.unknownProvider", "", lang: lang))
        }
        guard let provider = await ctx.store.loadProviders().first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: SrvL10n.tf("srv.unknownProvider", idString, lang: lang))
        }
        ctx.keyRing.remove(provider.keyAccount)
        return try req.json(AckResult(ok: true, detail: SrvL10n.tf("srv.keyRemoved", provider.name, lang: lang)))
    }

    adminAPI.delete("providers", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id") else { throw Abort(.badRequest, reason: SrvL10n.t("srv.missingProviderID", lang: lang)) }
        var providers = await ctx.store.loadProviders()
        guard let provider = providers.first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: SrvL10n.tf("srv.unknownProvider", idString, lang: lang))
        }
        providers.removeAll { $0.id == idString }
        guard !providers.isEmpty else { throw Abort(.conflict, reason: SrvL10n.t("srv.keepProvider", lang: lang)) }
        await ctx.store.saveProviders(providers)
        ctx.keyRing.remove(provider.keyAccount)
        return try req.json(AckResult(ok: true, detail: nil))
    }

    adminAPI.post("providers", ":id", "test") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.missingProviderID", lang: lang))
        }
        let providers = await ctx.store.loadProviders()
        guard let provider = providers.first(where: { $0.id == idString }) else {
            throw Abort(.notFound, reason: SrvL10n.tf("srv.unknownProvider", idString, lang: lang))
        }
        guard let key = ctx.keyRing.get(provider.keyAccount) else {
            return try req.json(ProviderTestResult(ok: false, message: SrvL10n.tf("srv.noAPIKey", provider.name, lang: lang)))
        }
        let result = await LLMClient().testConnection(provider: provider, key: key)
        return try req.json(ProviderTestResult(ok: result.ok, message: result.message))
    }

    // MARK: Integrations

    api.get("integrations") { req async throws -> Response in
        try req.json([ctx.maloon.status(lang: SrvL10n.lang(for: req))])
    }

    api.post("integrations", "maloon", "test") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard ctx.maloon.isConfigured else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonNotConfigured", lang: lang))
        }
        return try req.json(await ctx.maloon.test(lang: lang))
    }

    // MARK: Connectors

    api.get("connectors") { req async throws -> Response in
        var statuses: [ConnectorStatus] = []
        for connectorID in ConnectorID.allCases {
            statuses.append(await ctx.connectors.status(for: connectorID))
        }
        return try req.json(statuses)
    }

    api.get("connectors", ":id") { req async throws -> Response in
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: SrvL10n.lang(for: req)))
        }
        return try req.json(await ctx.connectors.status(for: connectorID))
    }

    adminAPI.patch("connectors", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: lang))
        }
        let body = try req.decodeJSON(ConnectorPatchBody.self)
        var config = await ctx.connectors.config(for: connectorID)
        if let enabled = body.enabled { config.enabled = enabled }
        if let permissions = body.permissions { config.permissions = permissions }
        await ctx.connectors.setConfig(config)
        return try req.json(await ctx.connectors.status(for: connectorID))
    }

    adminAPI.post("connectors", ":id", "disconnect") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: lang))
        }
        ctx.connectors.disconnect(connectorID)
        return try req.json(AckResult(ok: true, detail: SrvL10n.tf("srv.disconnected", connectorID.displayName, lang: lang)))
    }

    adminAPI.post("connectors", ":id", "test") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: lang))
        }
        let result = await ctx.connectors.test(connectorID)
        return try req.json(ConnectorTestResult(ok: result.ok, message: result.message))
    }

    adminAPI.post("connectors", "cloudflare", "token") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let body = try req.decodeJSON(KeyBody.self)
        let token = body.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.cloudflareTokenRequired", lang: lang))
        }
        let verified = await CloudflareConnector.verifyToken(token, session: ctx.connectors.session)
        guard verified.ok else {
            throw Abort(.badRequest, reason: verified.message)
        }
        try ctx.keyRing.set(token, for: CloudflareConnector.tokenAccount)
        return try req.json(AckResult(ok: true, detail: SrvL10n.t("srv.cloudflareStored", lang: lang)))
    }

    adminAPI.post("connectors", "web", "key") { req async throws -> Response in
        let body = try req.decodeJSON(KeyBody.self)
        let key = body.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw Abort(.badRequest, reason: "Paste a Brave Search API key.")
        }
        let verified = await WebConnector.verifyBraveKey(key, session: ctx.connectors.session)
        guard verified.ok else {
            throw Abort(.badRequest, reason: verified.message)
        }
        try ctx.keyRing.set(key, for: WebConnector.braveKeyAccount)
        return try req.json(AckResult(ok: true, detail: verified.message))
    }

    adminAPI.post("connectors", "googleads", "credentials") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        let body = try req.decodeJSON(GoogleAdsCredentialsBody.self)
        if let developerToken = body.developerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !developerToken.isEmpty {
            try ctx.keyRing.set(developerToken, for: GoogleAdsConnector.developerTokenAccount)
        }
        if let customerId = body.customerId?.trimmingCharacters(in: .whitespacesAndNewlines), !customerId.isEmpty {
            let normalized = customerId
                .replacingOccurrences(of: "customers/", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            try ctx.keyRing.set(normalized, for: GoogleAdsConnector.customerIdAccount)
        }
        return try req.json(AckResult(ok: true, detail: SrvL10n.t("srv.adsStored", lang: lang)))
    }

    adminAPI.post("connectors", ":id", "authorize") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let connectorID = ConnectorID(rawValue: idString) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.unknownConnector", lang: lang))
        }
        guard connectorID == .gmail || connectorID == .googleads else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.notGoogleOAuth", lang: lang))
        }
        guard ctx.connectors.google.isConfigured else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.googleOAuthNotConfigured", lang: lang))
        }
        let body = try req.decodeJSON(OAuthAuthorizeBody.self)
        let clientKind = (body.clientKind ?? "browser").lowercased() == "app" ? "app" : "browser"
        let redirectURI = try connectorRedirectURI(for: req, connector: connectorID)
        let config = await ctx.connectors.config(for: connectorID)
        let scopes = connectorID == .gmail
            ? GmailConnector.scopes(permissions: config.permissions)
            : [GoogleAdsConnector.oauthScope]
        let state = await ctx.oauthStates.issue(connectorID: connectorID, redirectURI: redirectURI, clientKind: clientKind)
        guard let url = ctx.connectors.google.authorizeURL(redirectURI: redirectURI, state: state, scopes: scopes, prompt: "consent") else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.googleAuthURLFailed", lang: lang))
        }
        return try req.json(OAuthStartResult(url: url.absoluteString))
    }

    // MARK: Missions

    api.post("missions") { req async throws -> Response in
        let body = try req.decodeJSON(MissionStartBody.self)
        let language = body.language ?? SrvL10n.lang(for: req)
        let mission = try await ctx.startMission(
            teamID: body.teamID,
            objective: body.objective,
            workflowID: body.workflowID,
            launchedBy: req.principal?.name,
            language: language
        )
        return try req.json(mission.publicRepresentation, status: .created)
    }

    api.get("missions") { req async throws -> Response in
        let requested = req.query[Int.self, at: "limit"] ?? 100
        let limit = min(500, max(1, requested))
        let missions = await ctx.store.listMissions(limit: limit)
        return try req.json(missions.map(\.publicRepresentation))
    }

    api.get("missions", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badMissionID", lang: lang))
        }
        guard let mission = await ctx.store.mission(id: id) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.missionNotFound", lang: lang))
        }
        let events = await ctx.store.events(missionID: id, afterSeq: 0)
        let deliverables = await ctx.store.deliverables(missionID: id)
        let running = await ctx.engine.isRunning(missionID: id)
        return try req.json(MissionDetail(mission: mission.publicRepresentation, events: events, deliverables: deliverables, running: running))
    }

    api.get("missions", ":id", "events") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badMissionID", lang: lang))
        }
        let afterSeq = req.query[Int.self, at: "afterSeq"] ?? 0
        let events = await ctx.store.events(missionID: id, afterSeq: afterSeq)
        return try req.json(events)
    }

    api.get("missions", ":id", "deliverables", ":name") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badMissionID", lang: lang))
        }
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.missingDeliverable", lang: lang))
        }
        guard let content = await ctx.store.deliverable(missionID: id, name: name) else {
            throw Abort(.notFound, reason: SrvL10n.t("srv.deliverableNotFound", lang: lang))
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    api.post("missions", ":id", "stop") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badMissionID", lang: lang))
        }
        await ctx.engine.stop(missionID: id)
        return try req.json(AckResult(ok: true, detail: SrvL10n.t("srv.stopRequested", lang: lang)))
    }

    adminAPI.delete("missions", ":id") { req async throws -> Response in
        let lang = SrvL10n.lang(for: req)
        guard let idString = req.parameters.get("id"), let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.badMissionID", lang: lang))
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

/// The registered Google OAuth redirect URI for a connector: AGENTSAM_PUBLIC_URL when set, otherwise derived from the request.
func connectorRedirectURI(for req: Request, connector: ConnectorID) throws -> String {
    let path = "/api/connectors/\(connector.rawValue)/callback"
    if let publicURL = Environment.get("AGENTSAM_PUBLIC_URL"), !publicURL.isEmpty {
        return publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
    }
    let scheme = req.headers.first(name: "x-forwarded-proto") ?? (req.url.scheme ?? "https")
    guard let host = req.headers.first(name: "x-forwarded-host") ?? req.headers.first(name: .host) else {
        throw Abort(.badRequest, reason: SrvL10n.t("srv.publicURLUnknown", lang: SrvL10n.lang(for: req)))
    }
    return "\(scheme)://\(host)\(path)"
}

func oauthResultPage(title: String, message: String) -> Response {
    let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>AgentSam</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0A100D;color:#F2F7F2;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center;padding:32px;max-width:420px}h1{color:#4AD99E;font-size:24px;margin:0 0 12px}p{color:#93A89A;font-size:14px;line-height:1.5;margin:0}</style>
    </head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
    """
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    return Response(status: .ok, headers: headers, body: .init(string: html))
}

