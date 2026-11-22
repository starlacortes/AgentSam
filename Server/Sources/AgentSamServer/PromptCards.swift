import Vapor
import Foundation

/// A prompt the person saved to reuse: a short title on the card and the text it puts in the composer.
struct PromptCard: Content, Equatable {
    var id: UUID
    var title: String
    var text: String
    var createdAt: Date
}

struct PromptCardBody: Content {
    var title: String?
    var text: String
}

/// Each person's saved prompt cards, kept in one small file so they follow them across devices.
actor PromptCardStore {
    static let maxPerOwner = 30
    static let maxTitle = 80
    static let maxText = 4000

    enum Problem: Error { case empty, tooLong, full, missing }

    private let url: URL
    private var cache: [String: [PromptCard]]?

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("prompt-cards.json")
    }

    func cards(ownerID: String) -> [PromptCard] {
        load()[ownerID] ?? []
    }

    func add(ownerID: String, title: String?, text: String) throws -> PromptCard {
        var all = load()
        var mine = all[ownerID] ?? []
        guard mine.count < Self.maxPerOwner else { throw Problem.full }
        let card = PromptCard(id: UUID(), title: "", text: "", createdAt: Date())
        let filled = try Self.fill(card, title: title, text: text)
        mine.append(filled)
        all[ownerID] = mine
        save(all)
        return filled
    }

    func update(ownerID: String, id: UUID, title: String?, text: String) throws -> PromptCard {
        var all = load()
        var mine = all[ownerID] ?? []
        guard let index = mine.firstIndex(where: { $0.id == id }) else { throw Problem.missing }
        let filled = try Self.fill(mine[index], title: title, text: text)
        mine[index] = filled
        all[ownerID] = mine
        save(all)
        return filled
    }

    func remove(ownerID: String, id: UUID) throws {
        var all = load()
        var mine = all[ownerID] ?? []
        guard let index = mine.firstIndex(where: { $0.id == id }) else { throw Problem.missing }
        mine.remove(at: index)
        all[ownerID] = mine.isEmpty ? nil : mine
        save(all)
    }

    /// Trims the text and title. A card with no title is named after the start of its text.
    static func fill(_ card: PromptCard, title: String?, text: String) throws -> PromptCard {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Problem.empty }
        guard body.count <= maxText else { throw Problem.tooLong }
        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
            name = firstLine.count > 48 ? String(firstLine.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : firstLine
        }
        guard name.count <= maxTitle else { throw Problem.tooLong }
        var copy = card
        copy.title = name
        copy.text = body
        return copy
    }

    private func load() -> [String: [PromptCard]] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: [PromptCard]].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    private func save(_ all: [String: [PromptCard]]) {
        cache = all
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private func promptCardProblem(_ error: Error) -> Abort {
    switch error as? PromptCardStore.Problem {
    case .empty: return Abort(.badRequest, reason: "Write the prompt the card should put in the chat.")
    case .tooLong: return Abort(.badRequest, reason: "Keep the title under \(PromptCardStore.maxTitle) characters and the prompt under \(PromptCardStore.maxText).")
    case .full: return Abort(.badRequest, reason: "You can keep up to \(PromptCardStore.maxPerOwner) prompt cards. Delete one to add another.")
    case .missing: return Abort(.notFound, reason: "That prompt card no longer exists.")
    case nil: return Abort(.internalServerError)
    }
}

private func promptCardID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)) else { throw Abort(.badRequest, reason: "Missing prompt card id.") }
    return id
}

func promptCardRoutes(_ api: RoutesBuilder, ctx: ServerContext) {
    let store = PromptCardStore(dataDir: ctx.dataDir)

    api.get("prompt-cards") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        return try req.json(await store.cards(ownerID: owner))
    }

    api.post("prompt-cards") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let body = try req.decodeJSON(PromptCardBody.self)
        do {
            return try req.json(try await store.add(ownerID: owner, title: body.title, text: body.text), status: .created)
        } catch { throw promptCardProblem(error) }
    }

    api.put("prompt-cards", ":id") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try promptCardID(req)
        let body = try req.decodeJSON(PromptCardBody.self)
        do {
            return try req.json(try await store.update(ownerID: owner, id: id, title: body.title, text: body.text))
        } catch { throw promptCardProblem(error) }
    }

    api.delete("prompt-cards", ":id") { req async throws -> Response in
        let owner = try req.requirePrincipal().conversationOwnerID
        let id = try promptCardID(req)
        do {
            try await store.remove(ownerID: owner, id: id)
            return Response(status: .noContent)
        } catch { throw promptCardProblem(error) }
    }
}
