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

struct PermissionsView: Content {
    var policy: PermissionPolicy
    var usageToday: [String: Int]
    var tools: [String]
    var canEdit: Bool
    var spentTodayUSD: Double
    /// True when the workstation is on and this person may use it, so its rules are shown.
    var workstation: Bool
}

/// The workstation as admins see it: where it runs and the public key to install there.
struct WorkstationView: Content {
    var enabled: Bool
    var location: String
    var ssh: String?
    var publicKey: String?
}

struct WorkstationTestView: Content {
    var ok: Bool
    var output: String
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
            throw Abort(.badRequest, reason: "Choose an existing, specific absolute folder on the server. The filesystem root, your home folder, and Ada's data folder cannot be granted.")
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

    @Sendable func permissionsView(owner: String, canEdit: Bool) async -> PermissionsView {
        var workstation = false
        if let machine = ctx.access.workstation, await machine.enabled { workstation = await ctx.access.workstationOwner(owner) }
        return PermissionsView(
            policy: await ctx.access.permissions.policy(ownerID: owner),
            usageToday: await ctx.access.permissions.usageToday(ownerID: owner),
            tools: PermissionStore.ruleTools.sorted().filter { workstation || !WorkstationTools.names.contains($0) } + (await ctx.access.mcp?.writeToolNames() ?? []),
            canEdit: canEdit,
            spentTodayUSD: await ctx.access.spend.today(ownerID: owner),
            workstation: workstation
        )
    }

    // Standing permissions: which write tools Ada may run without an approval card, within limits.
    api.get("access", "permissions") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        return try req.json(await permissionsView(owner: principal.conversationOwnerID, canEdit: principal.isAdmin))
    }

    api.put("access", "permissions") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        // Connector accounts are shared by the whole server, so only admins may let Ada act on them unasked.
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can change Ada's standing permissions.") }
        let policy = try req.decodeJSON(PermissionPolicy.self)
        await ctx.access.permissions.save(ownerID: principal.conversationOwnerID, policy: policy)
        return try req.json(await permissionsView(owner: principal.conversationOwnerID, canEdit: true))
    }

    api.get("access", "workstation") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can see Ada's workstation.") }
        guard let machine = ctx.access.workstation, await machine.enabled else {
            return try req.json(WorkstationView(enabled: false, location: "", ssh: nil, publicKey: nil))
        }
        return try req.json(WorkstationView(enabled: true, location: await machine.location, ssh: machine.config.ssh?.destination, publicKey: await machine.publicKey()))
    }

    api.post("access", "workstation", "test") { req async throws -> Response in
        let principal = try req.requirePrincipal()
        guard principal.isAdmin else { throw Abort(.forbidden, reason: "Only admins can test Ada's workstation.") }
        guard let machine = ctx.access.workstation, await machine.enabled else { throw Abort(.notFound, reason: "Workstation access is off on this server.") }
        let outcome = await machine.status()
        await ctx.access.audit.record(ownerID: principal.conversationOwnerID, action: "workstation.test", detail: outcome.succeeded ? "ok" : "failed")
        return try req.json(WorkstationTestView(ok: outcome.succeeded, output: String(outcome.resultText.prefix(8_000))))
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
                guard await ctx.access.sharedAccountsOwner(conversation.ownerID) else {
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: "You no longer have access to the shared accounts. Nothing ran.", succeeded: false)
                    break
                }
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The connector action could not be started.")
                }
                let call = APIToolCall(id: action.id.uuidString, function: .init(name: action.toolName, arguments: raw))
                let outcome = await ctx.connectors.run(call: call, scope: action.toolScope, approved: true)
                await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
            case .workstation:
                guard let machine = ctx.access.workstation, await ctx.access.workstationOwner(conversation.ownerID) else {
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: "Workstation access is off on this server. Nothing ran.", succeeded: false)
                    break
                }
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The workstation command could not be started.")
                }
                // Commands can take minutes, so they finish in the background; the card shows "executing" until then.
                let owner = conversation.ownerID
                let actions = ctx.access.actions
                let tool = action.toolName
                Task {
                    let outcome = await WorkstationTools.execute(toolName: tool, rawArguments: raw, workstation: machine)
                    await actions.finish(ownerID: owner, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
                }
            case .browser:
                // A browser action that signs in, submits, pays, sends, deletes or changes security.
                // The agent runs it only if the page and element still match what was approved.
                guard let link = ctx.access.browser, await ctx.access.workstationOwner(conversation.ownerID) else {
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: "Ada's browser is off on this server. Nothing was done.", succeeded: false)
                    break
                }
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The browser action could not be started.")
                }
                let outcome = await BrowserTools.execute(rawArguments: raw, link: link)
                await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
                await ctx.access.audit.record(ownerID: conversation.ownerID, action: "browser.approved-action", detail: "\(action.title.prefix(200)): \(outcome.succeeded ? "done" : "not done")")
            case .mcpCall:
                guard await ctx.access.sharedAccountsOwner(conversation.ownerID) else {
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: "You no longer have access to the shared accounts. Nothing ran.", succeeded: false)
                    break
                }
                guard let mcp = ctx.access.mcp,
                      await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The MCP tool call could not be started.")
                }
                let outcome = await mcp.call(action.toolName, rawArguments: raw)
                await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
            case .helperSave:
                // Ada's proposed role for one of her helpers. It only writes helpers.json.
                guard await ctx.access.actions.consumeApproved(ownerID: conversation.ownerID, id: id) != nil,
                      let raw = action.arguments.objectValue?["raw"]?.stringValue else {
                    throw Abort(.conflict, reason: "The helper change could not be applied.")
                }
                let call = APIToolCall(id: action.id.uuidString, function: .init(name: action.toolName, arguments: raw))
                switch HelperTools.saveRequest(from: call) {
                case .failure(let error):
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: error.message, succeeded: false)
                case .success(let request):
                    let outcome = await HelperTools.apply(request, to: HelperStore(root: ctx.dataDir))
                    await ctx.access.actions.finish(ownerID: conversation.ownerID, id: id, result: outcome.resultText, succeeded: outcome.succeeded)
                    await ctx.access.audit.record(ownerID: conversation.ownerID, action: request.undo ? "helper.undone" : "helper.saved", detail: "\(request.name): \(outcome.resultText.prefix(200))")
                }
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
