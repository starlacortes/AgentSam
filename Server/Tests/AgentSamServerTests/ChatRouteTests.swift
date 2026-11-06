@testable import AgentSamServer
import XCTVapor
import Foundation
import AgentSamCore

final class ChatRouteTests: XCTestCase {
    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-chat-routes-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: dataDir)
    }

    private struct Settings: Decodable { var defaultTeamID: UUID?; var effectiveTeamID: UUID? }
    private struct Chat: Decodable { var id: UUID; var teamID: UUID; var lines: [Line] }
    private struct Line: Decodable { var kind: String; var text: String }
    private struct TeamRow: Decodable { var id: UUID }

    private func authed(_ req: inout XCTHTTPRequest) {
        req.headers.bearerAuthorization = BearerAuthorization(token: serverToken)
    }

    func testChatsNeedSignIn() async throws {
        try await app.test(.GET, "api/chats") { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testNewChatUsesTheDefaultTeam() async throws {
        var teams: [TeamRow] = []
        try await app.test(.GET, "api/teams", beforeRequest: { authed(&$0) }) { res async throws in
            teams = try res.content.decode([TeamRow].self)
        }
        let starter = try XCTUnwrap(teams.first)

        try await app.test(.GET, "api/chat-settings", beforeRequest: { authed(&$0) }) { res async throws in
            let settings = try res.content.decode(Settings.self)
            XCTAssertNil(settings.defaultTeamID)
            XCTAssertEqual(settings.effectiveTeamID, starter.id)
        }

        var chatID: UUID?
        try await app.test(.POST, "api/chats", beforeRequest: { authed(&$0) }) { res async throws in
            XCTAssertEqual(res.status, .created)
            let chat = try res.content.decode(Chat.self)
            XCTAssertEqual(chat.teamID, starter.id)
            chatID = chat.id
        }

        try await app.test(.GET, "api/chats", beforeRequest: { authed(&$0) }) { res async throws in
            XCTAssertEqual(try res.content.decode([Chat].self).map(\.id), [try XCTUnwrap(chatID)])
        }

        try await app.test(.PUT, "api/chat-settings", beforeRequest: { req in
            authed(&req)
            try req.content.encode(["defaultTeamID": UUID().uuidString], as: .json)
        }) { res async in
            XCTAssertEqual(res.status, .notFound, "An unknown team can't be the default")
        }
    }

    func testEmptyMessageIsRefused() async throws {
        var chatID = UUID()
        try await app.test(.POST, "api/chats", beforeRequest: { authed(&$0) }) { res async throws in
            chatID = try res.content.decode(Chat.self).id
        }
        try await app.test(.POST, "api/chats/\(chatID)/messages", beforeRequest: { req in
            authed(&req)
            try req.content.encode(["text": "   "], as: .json)
        }) { res async in
            XCTAssertEqual(res.status, .badRequest)
        }
    }
}
