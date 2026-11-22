import Vapor
import AgentSamCore
import Foundation

struct MCPToolView: Content {
    var name: String
    var exposedName: String
    var description: String
    var readOnlyHint: Bool
    var read: Bool
}

/// An MCP server as admins see it. The token never leaves the server.
struct MCPServerView: Content {
    var id: UUID
    var name: String
    var slug: String
    var url: String
    var enabled: Bool
    var hasToken: Bool
    var tools: [MCPToolView]
    var lastRefreshed: Date?
    var lastError: String?
}

struct MCPServerAddBody: Content {
    var name: String?
    var url: String
    var token: String?
}

struct MCPServerUpdateBody: Content {
    var name: String?
    var enabled: Bool?
    var readTools: [String]?
    /// A new token; an empty string removes it.
    var token: String?
}

func mcpRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    @Sendable func admin(_ req: Request) throws -> Principal {
        let principal = try req.requirePrincipal()
        // A connected server's tools are offered to everyone's Ada, so only admins choose them.
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can manage MCP servers.") }
        return principal
    }
    @Sendable func registry() throws -> MCPRegistry {
        guard let mcp = ctx.access.mcp else { throw Abort(.notFound, reason: "MCP servers are not available on this server.") }
        return mcp
    }
    @Sendable func view(_ server: MCPServerConfig, _ mcp: MCPRegistry) async -> MCPServerView {
        MCPServerView(
            id: server.id, name: server.name, slug: server.slug, url: server.url, enabled: server.enabled,
            hasToken: await mcp.hasToken(server.id),
            tools: server.tools.map { MCPToolView(name: $0.name, exposedName: MCPRegistry.exposedName(slug: server.slug, tool: $0.name), description: String($0.description.prefix(300)), readOnlyHint: $0.readOnlyHint, read: server.readTools.contains($0.name)) },
            lastRefreshed: server.lastRefreshed, lastError: server.lastError
        )
    }
    @Sendable func serverID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("serverID"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid MCP server ID.") }
        return id
    }

    api.get("mcp", "servers") { req async throws -> Response in
        _ = try admin(req)
        let mcp = try registry()
        var views: [MCPServerView] = []
        for server in await mcp.list() { views.append(await view(server, mcp)) }
        return try req.json(views)
    }

    api.post("mcp", "servers") { req async throws -> Response in
        let principal = try admin(req)
        let mcp = try registry()
        let body = try req.decodeJSON(MCPServerAddBody.self)
        do {
            let server = try await mcp.add(name: body.name ?? "", url: body.url, token: body.token)
            await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "mcp.added", detail: "\(server.name): \(server.tools.count) tools")
            return try req.json(await view(server, mcp), status: .created)
        } catch let error as MCPError {
            throw Abort(.badRequest, reason: error.errorDescription ?? "The MCP server could not be added.")
        } catch {
            throw Abort(.badGateway, reason: "The MCP server could not be reached: \(error.localizedDescription)")
        }
    }

    api.put("mcp", "servers", ":serverID") { req async throws -> Response in
        let principal = try admin(req)
        let mcp = try registry()
        let id = try serverID(req)
        let body = try req.decodeJSON(MCPServerUpdateBody.self)
        do {
            let server = try await mcp.update(id: id, name: body.name, enabled: body.enabled, readTools: body.readTools, token: body.token)
            await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "mcp.updated", detail: "\(server.name): enabled=\(server.enabled); reads=\(server.readTools.joined(separator: ","))")
            return try req.json(await view(server, mcp))
        } catch {
            throw Abort(.notFound, reason: "No MCP server has that ID.")
        }
    }

    api.post("mcp", "servers", ":serverID", "refresh") { req async throws -> Response in
        _ = try admin(req)
        let mcp = try registry()
        guard let server = await mcp.refresh(id: try serverID(req)) else { throw Abort(.notFound, reason: "No MCP server has that ID.") }
        return try req.json(await view(server, mcp))
    }

    api.delete("mcp", "servers", ":serverID") { req async throws -> Response in
        let principal = try admin(req)
        let mcp = try registry()
        let id = try serverID(req)
        guard await mcp.remove(id: id) else { throw Abort(.notFound, reason: "No MCP server has that ID.") }
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "mcp.removed", detail: id.uuidString)
        return Response(status: .noContent)
    }
}
