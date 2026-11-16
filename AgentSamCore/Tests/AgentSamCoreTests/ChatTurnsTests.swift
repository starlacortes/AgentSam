import XCTest
@testable import AgentSamCore

final class ChatTurnsTests: XCTestCase {
    func testTurnsAlternateAndExcludeLatestUserMessage() {
        let history = [
            ConversationMessage(role: .user, text: "a"),
            ConversationMessage(role: .user, text: "b"),
            ConversationMessage(role: .assistant, text: "c"),
            ConversationMessage(role: .user, text: "latest"),
        ]
        let turns = ConversationEngine.chatTurns(from: history)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        XCTAssertEqual(turns[0].content, "a\n\nb")
    }

    func testTurnsStartWithUserAndCapLength() {
        let history = [
            ConversationMessage(role: .assistant, text: "orphan"),
            ConversationMessage(role: .user, text: String(repeating: "x", count: 10_000)),
            ConversationMessage(role: .assistant, text: "ok"),
        ]
        let turns = ConversationEngine.chatTurns(from: history)
        XCTAssertEqual(turns.first?.role, "user")
        XCTAssertEqual(turns.first?.content?.count, 6_000)
    }
}
