import Vapor
import Foundation
import AgentSamCore

struct TokenMiddleware: AsyncMiddleware {
    let token: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let header = request.headers.first(name: .authorization)?
            .trimmingCharacters(in: .whitespaces)
        var provided: String?
        if let header, header.lowercased().hasPrefix("bearer") {
            provided = String(header.dropFirst("bearer".count)).trimmingCharacters(in: .whitespaces)
        }
        if provided == nil {
            provided = request.query[String.self, at: "token"]
        }
        guard let provided, provided == token, !token.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing or invalid token")
        }
        return try await next.respond(to: request)
    }
}

extension Request {
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
        let data = try Self.jsonEncoder.encode(value)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        try content.decode(type)
    }
}

struct MissionStartBody: Decodable {
    var teamID: UUID
    var objective: String
}

struct KeyBody: Decodable {
    var key: String
}

struct TeamInput: Decodable {
    var id: UUID?
    var name: String
    var emoji: String?
    var goal: String?
    var agents: [AgentProfile]?
}

struct MissionDetail: Encodable {
    var mission: Mission
    var events: [RunEvent]
    var deliverables: [String]
    var running: Bool
}

struct ProviderStatus: Encodable {
    var provider: ProviderConfig
    var hasKey: Bool
}

struct ProviderTestResult: Encodable {
    var ok: Bool
    var message: String
}

struct ServerInfo: Encodable {
    var name: String
    var teams: Int
    var missions: Int
    var runningMissions: [UUID]
}

struct AckResult: Encodable {
    var ok: Bool
    var detail: String?
}
