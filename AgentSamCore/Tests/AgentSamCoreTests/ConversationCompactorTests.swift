import XCTest
@testable import AgentSamCore

final class ConversationCompactorTests: XCTestCase {
    // MARK: - Helpers

    private func msg(_ role: String, content: String? = nil, calls: [APIToolCall] = [], toolID: String? = nil) -> APIMessage {
        APIMessage(role: role, content: content, tool_calls: calls.isEmpty ? nil : calls, tool_call_id: toolID)
    }

    private func turn(
        callID: String,
        toolContent: String,
        callName: String = "read_file",
        callArguments: String = #"{"path":"a.md"}"#
    ) -> [APIMessage] {
        [
            msg("assistant", calls: [APIToolCall(id: callID, function: .init(name: callName, arguments: callArguments))]),
            msg("tool", content: toolContent, toolID: callID),
        ]
    }

    private func repeating(_ text: String, count: Int) -> String {
        String(repeating: text, count: count)
    }

    /// The chat APIs require each assistant tool call to be immediately
    /// followed by tool results carrying its id. Compaction must preserve that.
    private func assertValidPairing(_ messages: [APIMessage], file: StaticString = #filePath, line: UInt = #line) {
        var i = 0
        while i < messages.count {
            if messages[i].role == "assistant", let calls = messages[i].tool_calls {
                let ids = Set(calls.map(\.id))
                var seen: Set<String> = []
                var j = i + 1
                while j < messages.count, messages[j].role == "tool", let toolID = messages[j].tool_call_id, ids.contains(toolID) {
                    seen.insert(toolID)
                    j += 1
                }
                XCTAssertEqual(seen, ids, "tool results must immediately follow their assistant call", file: file, line: line)
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: - Estimation and no-ops

    func testEstimateTokensIsCharsOverFour() {
        XCTAssertEqual(ConversationCompactor.estimateTokens(""), 0)
        XCTAssertEqual(ConversationCompactor.estimateTokens("abcd"), 1)
        XCTAssertEqual(ConversationCompactor.estimateTokens("abc"), 1)
        XCTAssertEqual(ConversationCompactor.estimateTokens("12345"), 2)
    }

    func testCompactLeavesSmallConversationsAlone() {
        let messages = [msg("user", content: "Write a file.")] + turn(callID: "c1", toolContent: "short result")
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 10_000)
        XCTAssertFalse(outcome.trimmed)
        XCTAssertEqual(outcome.messages, messages)
        XCTAssertNil(outcome.notice)
    }

    func testCompactKeepsEverythingWhenBudgetIsHuge() {
        let messages = [msg("user", content: "task")] + turn(callID: "c1", toolContent: repeating("x", count: 4_000))
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_000_000)
        XCTAssertFalse(outcome.trimmed)
        XCTAssertEqual(outcome.messages.count, messages.count)
    }

    func testCompactHandlesEmptyConversation() {
        let outcome = ConversationCompactor.compact(messages: [], budgetTokens: 100)
        XCTAssertFalse(outcome.trimmed)
        XCTAssertTrue(outcome.messages.isEmpty)
    }

    // MARK: - Turn trimming

    func testCompactDropsMiddleTurnsAndKeepsTaskPromptAndLatestTurn() {
        let filler = repeating("f", count: 4_000) // ≈ 1,000 tokens per tool result
        var messages = [msg("user", content: "YOUR TASK: write notes.md")]
        for i in 0..<6 {
            messages += turn(callID: "c\(i)", toolContent: filler)
        }
        // Each turn is ≈1,006 tokens; head + 2 turns fit in 2,100, +3 do not.
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 2_100)
        XCTAssertTrue(outcome.trimmed)
        let kept = outcome.messages
        // The task prompt survives, with the trim notice merged into it.
        XCTAssertTrue(kept.first?.content?.hasPrefix("YOUR TASK: write notes.md") == true)
        XCTAssertTrue(kept.first?.content?.contains(ConversationCompactor.trimmedNotice) == true)
        assertValidPairing(kept)
        // Only the last two turns survive.
        XCTAssertTrue(kept.contains { $0.tool_call_id == "c4" })
        XCTAssertTrue(kept.contains { $0.tool_call_id == "c5" })
        XCTAssertFalse(kept.contains { $0.tool_call_id == "c0" })
        XCTAssertTrue(outcome.notice?.contains("dropped 4 of 6") == true)
    }

    func testCompactMergesNoticeIntoLastUserMessage() {
        let filler = repeating("f", count: 4_000)
        var messages = [msg("user", content: "Task prompt."), msg("user", content: "A later prompt.")]
        messages += turn(callID: "c1", toolContent: filler)
        messages += turn(callID: "c2", toolContent: filler)
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_500)
        XCTAssertTrue(outcome.trimmed)
        // The notice is merged into the second prompt, not appended as a new
        // user message (Anthropic rejects consecutive same-role messages).
        XCTAssertEqual(outcome.messages.filter { $0.role == "user" }.count, 2)
        XCTAssertTrue(outcome.messages[1].content?.contains(ConversationCompactor.trimmedNotice) == true)
        assertValidPairing(outcome.messages)
    }

    func testCompactPreservesMidConversationUserPrompts() {
        let filler = repeating("f", count: 4_000)
        var messages = [msg("user", content: "task")]
        messages += turn(callID: "c1", toolContent: filler)
        messages.append(msg("user", content: "Replan prompt."))
        messages += turn(callID: "c2", toolContent: filler)
        messages += turn(callID: "c3", toolContent: filler)
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_300)
        XCTAssertTrue(outcome.trimmed)
        XCTAssertTrue(outcome.messages.contains { $0.content?.hasPrefix("Replan prompt.") == true })
        assertValidPairing(outcome.messages)
        XCTAssertLessThanOrEqual(ConversationCompactor.size(outcome.messages), 1_300)
    }

    // MARK: - Payload truncation

    func testCompactTruncatesOversizedToolResultsInNewestTurn() {
        let big = repeating("d", count: 8_000)
        let messages = [msg("user", content: "task")]
            + turn(callID: "c1", toolContent: big)
            + turn(callID: "c2", toolContent: big)
            + turn(callID: "c3", toolContent: big)
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_000)
        XCTAssertTrue(outcome.trimmed)
        XCTAssertLessThanOrEqual(ConversationCompactor.size(outcome.messages), 1_000)
        assertValidPairing(outcome.messages)
        // The newest tool result survived, truncated with a marker.
        XCTAssertTrue(outcome.messages.contains {
            $0.tool_call_id == "c3" && ($0.content?.contains("trimmed to fit the context window") ?? false)
        })
    }

    func testCompactStubsExecutedWriteCallArguments() {
        let fileContent = repeating("y", count: 12_000)
        let args = "{\"path\":\"notes.md\",\"content\":\"\(fileContent)\"}"
        let messages = [msg("user", content: "task")] + turn(
            callID: "c1",
            toolContent: "Wrote notes.md (12000 bytes).",
            callName: "write_file",
            callArguments: args
        )
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_000)
        XCTAssertTrue(outcome.trimmed)
        XCTAssertLessThanOrEqual(ConversationCompactor.size(outcome.messages), 1_000)
        let assistant = outcome.messages.first { $0.role == "assistant" }
        let stubbed = assistant?.tool_calls?.first?.function.arguments ?? ""
        XCTAssertNotEqual(stubbed, args)
        // The stub is valid JSON, so nothing downstream chokes on it.
        XCTAssertNotNil(try? JSONDecoder().decode(JSONValue.self, from: Data(stubbed.utf8)))
        assertValidPairing(outcome.messages)
    }

    func testCompactTruncatesUserContentWhenNoTurnsExist() {
        let messages = [msg("user", content: repeating("z", count: 8_000))]
        let outcome = ConversationCompactor.compact(messages: messages, budgetTokens: 1_000)
        XCTAssertTrue(outcome.trimmed)
        XCTAssertLessThanOrEqual(ConversationCompactor.size(outcome.messages), 1_000)
    }
}
