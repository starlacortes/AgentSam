import Vapor
import AgentSamCore
import Foundation

extension ConversationError: AbortError {
    public var status: HTTPResponseStatus {
        switch self {
        case .notFound: .notFound
        case .alreadyRunning: .conflict
        case .persistence: .internalServerError
        case .emptyMessage, .messageTooLong, .noProvider, .missingProviderKey: .badRequest
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
    /// The browser's IANA time zone, e.g. "America/Los_Angeles".
    var timeZone: String?
}

/// `retentionDays` is 7, 30, 90, or 365; null (or absent) keeps archived chats forever.
struct ArchiveSettingsBody: Content {
    var retentionDays: Int?
}

struct MemoryPinBody: Content {
    var text: String
}

struct MemoryForgetBody: Content {
    var about: String
}

struct MemoryForgetView: Content {
    var result: MemoryForgetResult
    var memory: WorkspaceMemory
}

struct MemoryPatchBody: Content {
    var enabled: Bool
}

struct GuidePatchBody: Content {
    var completed: Bool
}

struct ScheduleSetBody: Content {
    var prompt: String
    var intervalMinutes: Int?
    var language: String?
    /// A local time, 24-hour "HH:MM". With it, the schedule runs at that time instead of on an interval.
    var at: String?
    /// With `at`: "every day", "weekdays", "weekends", or "mon,wed,fri".
    var days: String?
    var timeZone: String?
}

struct TriggerAddBody: Content {
    var kind: String
    var prompt: String
    var query: String?
    var language: String?
}

func conversationRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    conversationVoiceRoutes(api, ctx: ctx)

    api.get("conversations") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let archived = ["1", "true"].contains(req.query[String.self, at: "archived"]?.lowercased() ?? "")
        // The archive view sweeps expired chats first, so it never shows one past its retention.
        if archived { _ = try? await ctx.conversations.purgeExpiredArchives(ownerID: owner) }
        return try req.json(await ctx.conversations.list(ownerID: owner, archived: archived))
    }

    // Archive hides a chat from the sidebar; restore brings it back. Archives older than the
    // owner's retention (see `workspace/archive`) are deleted by the scheduler.
    api.post("conversations", ":id", "archive") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(try await ctx.conversations.setArchived(id: req.conversationID, ownerID: owner, archived: true))
    }

    api.delete("conversations", ":id", "archive") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(try await ctx.conversations.setArchived(id: req.conversationID, ownerID: owner, archived: false))
    }

    api.get("workspace", "archive") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await ctx.conversations.archiveSettings(ownerID: owner))
    }

    api.put("workspace", "archive") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(ArchiveSettingsBody.self)
        if let days = body.retentionDays, !ArchiveSettings.allowedRetentionDays.contains(days) {
            throw Abort(.badRequest, reason: "Keep archived chats for \(ArchiveSettings.allowedRetentionDays.map(String.init).joined(separator: ", ")) days, or never delete them.")
        }
        let settings = try await ctx.conversations.saveArchiveSettings(ownerID: owner, retentionDays: body.retentionDays)
        _ = try? await ctx.conversations.purgeExpiredArchives(ownerID: owner)
        return try req.json(settings)
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
            spoken: body.spoken ?? false,
            timeZone: body.timeZone.map { String($0.prefix(64)) }
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

    // Facts kept word for word, and forgetting on request.
    api.post("workspace", "memory", "pinned") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(MemoryPinBody.self)
        do {
            _ = try await ctx.memory.pin(ownerID: owner, text: body.text, origin: .person)
        } catch let error as MemoryEditError {
            throw Abort(.badRequest, reason: error.errorDescription ?? "Nothing was remembered.")
        }
        return try req.json(await ctx.memory.state(ownerID: owner), status: .created)
    }

    api.delete("workspace", "memory", "pinned", ":pinID") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        guard let raw = req.parameters.get("pinID"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid memory ID.") }
        return try req.json(try await ctx.memory.unpin(ownerID: owner, id: id))
    }

    api.post("workspace", "memory", "forget") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(MemoryForgetBody.self)
        guard body.about.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { throw Abort(.badRequest, reason: "Give at least 3 characters that identify what to forget.") }
        let result = try await ctx.memory.forget(ownerID: owner, matching: body.about)
        return try req.json(MemoryForgetView(result: result, memory: await ctx.memory.state(ownerID: owner)))
    }

    api.get("workspace", "memory", "export") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let memory = await ctx.memory.state(ownerID: owner)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=ada-memory.md")
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
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=ada-\(id.rawValue).md")
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
        if let zone = body.timeZone { _ = try await ctx.conversations.setTimeZone(id: id, ownerID: owner, timeZone: zone) }
        guard let current = try await ctx.conversations.get(id: id, ownerID: owner) else { throw Abort(.notFound) }
        var at: ScheduleTime?
        if let raw = body.at, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ScheduleTime.parse(time: raw, days: body.days) else {
                throw Abort(.badRequest, reason: "Give the time as 24-hour HH:MM and the days as every day, weekdays, weekends, or a list like mon,wed,fri.")
            }
            at = parsed
        }
        guard let schedule = ConversationSchedule.validate(
            prompt: body.prompt,
            intervalMinutes: body.intervalMinutes,
            language: body.language ?? SrvL10n.lang(for: req),
            at: at,
            timeZone: current.zone
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

    // MARK: Triggers — new email or a webhook call wakes the conversation.

    api.post("conversations", ":id", "triggers") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        let body = try req.decodeJSON(TriggerAddBody.self)
        guard let kind = ConversationTrigger.Kind(rawValue: body.kind.lowercased()) else {
            throw Abort(.badRequest, reason: "kind must be gmail or webhook.")
        }
        if kind == .gmail && !ctx.connectors.isConfigured(.gmail) {
            throw Abort(.badRequest, reason: "Connect Gmail in Settings > Connections first.")
        }
        let trigger: ConversationTrigger
        switch ConversationTrigger.validate(kind: kind, prompt: body.prompt, query: body.query, language: body.language ?? SrvL10n.lang(for: req)) {
        case .failure(let error): throw Abort(.badRequest, reason: error.message)
        case .success(let valid): trigger = valid
        }
        if case .failure(let error) = try await ctx.conversations.addTrigger(id: id, ownerID: owner, trigger: trigger) {
            throw Abort(.badRequest, reason: error.message)
        }
        guard let conversation = try await ctx.conversations.get(id: id, ownerID: owner) else { throw Abort(.notFound) }
        return try req.json(conversation)
    }

    api.delete("conversations", ":id", "triggers", ":trigger") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        let triggerID = req.parameters.get("trigger") ?? ""
        guard UUID(uuidString: triggerID) != nil, case .success = try await ctx.conversations.removeTrigger(id: id, ownerID: owner, triggerID: triggerID) else {
            throw Abort(.notFound, reason: TriggerError.notFound.message)
        }
        guard let conversation = try await ctx.conversations.get(id: id, ownerID: owner) else { throw Abort(.notFound) }
        return try req.json(conversation)
    }

    api.post("conversations", ":id", "triggers", ":trigger", "resume") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try req.conversationID
        guard let triggerID = req.parameters.get("trigger").flatMap(UUID.init(uuidString:)),
              let conversation = try await ctx.conversations.resumeTrigger(id: id, ownerID: owner, triggerID: triggerID) else {
            throw Abort(.notFound, reason: TriggerError.notFound.message)
        }
        return try req.json(conversation)
    }
}

/// The public webhook address of a chat's trigger. Not behind login: the secret token in the path
/// is the credential. The request body becomes the run's event data; Ada sees it as untrusted.
func webhookRoutes(_ app: Application, ctx: ServerContext) {
    app.on(.POST, "api", "hooks", ":token", body: .collect(maxSize: "64kb")) { req async throws -> Response in
        guard let token = req.parameters.get("token"),
              let found = try await ctx.conversations.webhookTrigger(token: token) else {
            throw Abort(.notFound, reason: "Unknown webhook.")
        }
        var data = "Webhook call"
        if let type = req.headers.contentType?.serialize() { data += " (Content-Type: \(type))" }
        if let buffer = req.body.data, buffer.readableBytes > 0 {
            let text = String(decoding: buffer.readableBytesView.prefix(TriggerEvent.maxDataCharacters), as: UTF8.self)
            data += ":\n" + text
        } else {
            data += " with an empty body."
        }
        let result = await ctx.scheduler.fire(conversationID: found.conversationID, ownerID: found.ownerID, triggerID: found.trigger.id, data: data)
        let status: HTTPResponseStatus
        let message: String
        switch result {
        case .started: (status, message) = (.accepted, "Ada is on it.")
        case .busy: (status, message) = (.conflict, "The chat is busy with another reply. Try again in a minute.")
        case .rateLimited: (status, message) = (.tooManyRequests, "This trigger already ran \(ConversationTrigger.maxFiresPerHour) times in the last hour.")
        case .paused: (status, message) = (.locked, "This trigger is paused. Resume it in the chat's Automation panel.")
        case .notFound: (status, message) = (.notFound, "Unknown webhook.")
        }
        let response = Response(status: status)
        try response.content.encode(["status": message])
        return response
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
