import Vapor
import AgentSamCore
import Foundation

struct HostGrantBody: Content {
    var path: String
    var canWrite: Bool
}

struct ActionDecisionBody: Content {
    var approve: Bool
}

struct UploadedProjectFile: Content {
    var path: String
    var bytes: Int
}

func accessRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    @Sendable func conversation(_ req: Request) async throws -> Conversation {
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let conversation = try await ctx.conversations.get(id: req.conversationID, ownerID: owner) else { throw ConversationError.notFound }
        return conversation
    }

    api.get("conversations", ":id", "project", "files") { req async throws -> Response in
        let conversation = try await conversation(req)
        let scope = ProjectScope(ownerID: conversation.ownerID, projectName: conversation.projectName)
        return try req.json(await ctx.chatWorkspace.projectFiles(scope))
    }

    api.get("conversations", ":id", "project", "files", ":name") { req async throws -> Response in
        let conversation = try await conversation(req)
        guard let name = req.parameters.get("name"),
              let content = ScopedFiles.read(name, in: ctx.chatWorkspace.projectDirectory(ProjectScope(ownerID: conversation.ownerID, projectName: conversation.projectName))) else {
            throw Abort(.notFound, reason: "Project file not found or not readable text.")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    api.on(.POST, "conversations", ":id", "project", "uploads", body: .collect(maxSize: ByteCount(value: 5_000_000))) { req async throws -> Response in
        let conversation = try await conversation(req)
        guard let encoded = req.headers.first(name: "X-AgentSam-Path")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let path = encoded.removingPercentEncoding, !path.isEmpty,
              let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Choose a non-empty file of at most 5 MB and provide its safe relative path.")
        }
        let scope = ProjectScope(ownerID: conversation.ownerID, projectName: conversation.projectName)
        guard let written = await ctx.chatWorkspace.upload(scope, name: path, data: Data(buffer.readableBytesView)) else {
            throw Abort(.badRequest, reason: "The upload must have a safe relative path, at most 5 MB, and no secret-like filename.")
        }
        await ctx.access.audit.record(ownerID: conversation.ownerID, action: "project.upload", detail: "\(conversation.projectName): \(written)")
        return try req.json(UploadedProjectFile(path: "project:\(written)", bytes: buffer.readableBytes), status: .created)
    }

    api.get("conversations", ":id", "project", "download", ":name") { req async throws -> Response in
        let conversation = try await conversation(req)
        guard let name = req.parameters.get("name"),
              let url = ScopedFiles.resolve(name, in: ctx.chatWorkspace.projectDirectory(ProjectScope(ownerID: conversation.ownerID, projectName: conversation.projectName))),
              !ScopedFiles.isSensitive(url.lastPathComponent),
              let data = try? Data(contentsOf: url), data.count <= 5_000_000 else {
            throw Abort(.notFound, reason: "Project file not found.")
        }
        var headers = HTTPHeaders()
        let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    api.get("access", "host-grants") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can grant host folders.") }
        return try req.json(await ctx.access.hosts.list(ownerID: principal.conversationOwnerID))
    }

    api.post("access", "host-grants") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can grant host folders.") }
        let body = try req.decodeJSON(HostGrantBody.self)
        guard let grant = await ctx.access.hosts.grant(ownerID: principal.conversationOwnerID, path: body.path, canWrite: body.canWrite) else {
            throw Abort(.badRequest, reason: "Choose an existing, specific absolute folder on the server. The filesystem root, your home folder, and the AgentSam data folder cannot be granted.")
        }
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "host.grant", detail: "\(grant.path); write=\(grant.canWrite)")
        return try req.json(grant, status: .created)
    }

    api.delete("access", "host-grants", ":grantID") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can revoke host folders.") }
        guard let rawID = req.parameters.get("grantID"), let id = UUID(uuidString: rawID),
              await ctx.access.hosts.revoke(ownerID: principal.conversationOwnerID, id: id) else {
            throw Abort(.notFound, reason: "Host folder grant not found.")
        }
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "host.revoke", detail: id.uuidString)
        return try req.json(AckResult(ok: true, detail: "Host folder access revoked. Existing files are unchanged."))
    }

    api.get("access", "audit") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.access.audit.entries(ownerID: owner))
    }

    api.get("conversations", ":id", "actions") { req async throws -> Response in
        let conversation = try await conversation(req)
        return try req.json(await ctx.access.actions.list(ownerID: conversation.ownerID, conversationID: conversation.id))
    }

    api.post("conversations", ":id", "actions", ":actionID") { req async throws -> Response in
        let conversation = try await conversation(req)
        guard let rawID = req.parameters.get("actionID"), let id = UUID(uuidString: rawID) else { throw Abort(.badRequest, reason: "Invalid action ID.") }
        let body = try req.decodeJSON(ActionDecisionBody.self)
        guard let requested = await ctx.access.actions.get(ownerID: conversation.ownerID, id: id), requested.conversationID == conversation.id else {
            throw Abort(.notFound, reason: "Action not found in this conversation.")
        }
        guard let action = await ctx.access.actions.resolve(ownerID: conversation.ownerID, id: id, approve: body.approve) else {
            throw Abort(.conflict, reason: "This action is missing, expired, or has already been handled.")
        }
        if body.approve {
            switch action.kind {
            case .connectorWrite:
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The connector action could not be started.")
                }
                let call = APIToolCall(id: action.id.uuidString, function: .init(name: action.toolName, arguments: raw))
                let outcome = await ctx.connectors.run(call: call, scope: action.toolScope, approved: true)
                await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
            case .fileDelete:
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let scope = action.fileScope,
                      let path = action.arguments.objectValue?["path"]?.stringValue else {
                    throw Abort(.conflict, reason: "The file deletion could not be started.")
                }
                let root = scope == .project
                    ? ctx.chatWorkspace.projectDirectory(ProjectScope(ownerID: conversation.ownerID, projectName: action.projectName ?? conversation.projectName))
                    : ctx.chatWorkspace.directory(conversation.id)
                let deleted: Bool
                if let target = ScopedFiles.resolve(path, in: root),
                   (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    deleted = ScopedFiles.delete(path, in: root)
                } else { deleted = false }
                let message = deleted ? "Deleted \(path)." : "The file no longer exists or is not a regular file."
                await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: message, succeeded: deleted)
                await ctx.access.audit.record(ownerID: conversation.ownerID, action: "file.delete", detail: "\(scope.rawValue): \(path); deleted=\(deleted)")
            }
        }
        return try req.json(await ctx.access.actions.list(ownerID: conversation.ownerID, conversationID: conversation.id))
    }
}
