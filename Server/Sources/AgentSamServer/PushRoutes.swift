import Vapor
import AgentSamCore
import Foundation

struct PushKeyView: Content {
    var publicKey: String
    var devices: Int
}

struct PushSubscribeBody: Content {
    var endpoint: String
    var label: String?
}

struct PushTestResult: Content {
    var delivered: Int
}

/// What the service worker shows when a push arrives. The push itself carries nothing.
struct PushLatestView: Content {
    var title: String
    var body: String
    var url: String
}

/// Remembers recent test alerts so the service worker can say "alerts work" instead of "nothing waiting".
actor PushTestMarks {
    private var marks: [String: Date] = [:]
    func mark(_ owner: String) { marks[owner] = Date() }
    func recent(_ owner: String) -> Bool { marks[owner].map { Date().timeIntervalSince($0) < 120 } ?? false }
}

func pushRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    let tests = PushTestMarks()

    api.get("push", "key") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(PushKeyView(publicKey: await ctx.push.publicKey(), devices: await ctx.push.subscriptions(ownerID: owner).count))
    }

    api.post("push", "subscribe") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(PushSubscribeBody.self)
        guard await ctx.push.subscribe(ownerID: owner, endpoint: body.endpoint, label: body.label) else {
            throw Abort(.badRequest, reason: "This browser's push service is not supported.")
        }
        await ctx.access.audit.record(ownerID: owner, action: "push.subscribed", detail: URL(string: body.endpoint)?.host ?? "")
        return try req.json(PushKeyView(publicKey: await ctx.push.publicKey(), devices: await ctx.push.subscriptions(ownerID: owner).count))
    }

    api.post("push", "unsubscribe") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(PushSubscribeBody.self)
        await ctx.push.unsubscribe(ownerID: owner, endpoint: body.endpoint)
        return try req.json(PushKeyView(publicKey: await ctx.push.publicKey(), devices: await ctx.push.subscriptions(ownerID: owner).count))
    }

    api.post("push", "test") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        await tests.mark(owner)
        return try req.json(PushTestResult(delivered: await ctx.push.notify(ownerID: owner)))
    }

    api.get("push", "latest") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        let owner = principal.conversationOwnerID
        let language = req.headers.first(name: .acceptLanguage)?.lowercased().hasPrefix("es") == true ? "es" : "en"
        let es = language == "es"
        let pending = await ctx.access.actions.pending(ownerID: owner)
        if let newest = pending.first {
            let more = pending.count > 1 ? (es ? " (y \(pending.count - 1) más)" : " (and \(pending.count - 1) more)") : ""
            return try req.json(PushLatestView(
                title: es ? "Ada necesita tu aprobación" : "Ada needs your approval",
                body: "\(newest.toolName)\(more)",
                url: "/chats/\(newest.conversationID.uuidString)"
            ))
        }
        if await tests.recent(owner) {
            return try req.json(PushLatestView(title: es ? "Las alertas funcionan" : "Alerts are working", body: es ? "Ada te avisará aquí cuando necesite tu aprobación." : "Ada will tell you here when she needs your approval.", url: "/"))
        }
        return try req.json(PushLatestView(title: "Ada", body: es ? "No hay nada pendiente ahora mismo." : "Nothing is waiting right now.", url: "/"))
    }
}
