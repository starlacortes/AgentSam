@testable import AgentSamServer
import XCTVapor
import Foundation

final class PromptCardTests: XCTestCase {
    private let serverToken = "test-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-tests-\(UUID().uuidString)")
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

    private func bearer(_ req: inout XCTHTTPRequest) {
        req.headers.replaceOrAdd(name: .authorization, value: "Bearer \(serverToken)")
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testPromptCardsNeedSignIn() async throws {
        try await app.test(.GET, "api/prompt-cards", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testAddEditAndDeleteACard() async throws {
        try await app.test(.GET, "api/prompt-cards", beforeRequest: bearer, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(try decoder().decode([PromptCard].self, from: Data(buffer: res.body)), [])
        })
        var created: PromptCard?
        try await app.test(.POST, "api/prompt-cards", beforeRequest: { req in
            bearer(&req)
            try req.content.encode(PromptCardBody(title: "  Weekly report ", text: "  Summarize this week's jobs.  "))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created)
            created = try decoder().decode(PromptCard.self, from: Data(buffer: res.body))
        })
        let card = try XCTUnwrap(created)
        XCTAssertEqual(card.title, "Weekly report")
        XCTAssertEqual(card.text, "Summarize this week's jobs.")

        try await app.test(.PUT, "api/prompt-cards/\(card.id.uuidString)", beforeRequest: { req in
            bearer(&req)
            try req.content.encode(PromptCardBody(title: nil, text: "Draft a reply to the newest client email"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let updated = try decoder().decode(PromptCard.self, from: Data(buffer: res.body))
            XCTAssertEqual(updated.id, card.id)
            XCTAssertEqual(updated.title, "Draft a reply to the newest client email", "an empty title is named after the prompt")
        })

        try await app.test(.DELETE, "api/prompt-cards/\(card.id.uuidString)", beforeRequest: bearer, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })
        try await app.test(.DELETE, "api/prompt-cards/\(card.id.uuidString)", beforeRequest: bearer, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testEmptyPromptsAreRefused() async throws {
        try await app.test(.POST, "api/prompt-cards", beforeRequest: { req in
            bearer(&req)
            try req.content.encode(PromptCardBody(title: "Nothing", text: "   "))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCardsAreKeptPerPersonAndSurviveARestart() async throws {
        let store = PromptCardStore(dataDir: dataDir)
        _ = try await store.add(ownerID: "a", title: nil, text: String(repeating: "word ", count: 20))
        let reopened = PromptCardStore(dataDir: dataDir)
        let cards = await reopened.cards(ownerID: "a")
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cards[0].title.count, 48)
        let others = await reopened.cards(ownerID: "b")
        XCTAssertTrue(others.isEmpty)
    }
}
