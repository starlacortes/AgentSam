import Foundation
import XCTest
@testable import AgentSamCore

final class ModelCallLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-calllog-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        EngineLog.setSink(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    func testTraceNumbersCallsAndAddsTokens() {
        let id = UUID()
        let trace = ReplyTrace(conversationID: id)
        XCTAssertEqual(trace.conversation, String(id.uuidString.prefix(8)).lowercased())
        XCTAssertNil(trace.snapshot.setupMilliseconds)
        // The spoken acknowledgement runs beside the reply and does not end the setup time.
        XCTAssertEqual(trace.beginCall(purpose: ModelCallLog.acknowledgement), 1)
        XCTAssertNil(trace.snapshot.setupMilliseconds)
        XCTAssertEqual(trace.beginCall(purpose: "reply"), 2)
        XCTAssertNotNil(trace.snapshot.setupMilliseconds)
        trace.record(LLMReply(message: .assistant("a"), inputTokens: 100, outputTokens: 10, model: "m", cachedInputTokens: 60))
        trace.record(LLMReply(message: .assistant("b"), inputTokens: 200, outputTokens: 20, model: "m", cachedInputTokens: 150))
        let totals = trace.snapshot
        XCTAssertEqual(totals.calls, 2)
        XCTAssertEqual(totals.inputTokens, 300)
        XCTAssertEqual(totals.cachedInputTokens, 210)
        XCTAssertEqual(totals.outputTokens, 30)
        let line = trace.summaryLine(costUSD: 0.0123)
        XCTAssertTrue(line.hasPrefix("reply conv=\(trace.conversation) calls=2 in=300 cached=210 out=30 setup_ms="), line)
        XCTAssertTrue(line.hasSuffix("cost_usd=0.012300"), line)
    }

    func testCallLineCarriesTokensTimingAndCost() {
        let reply = LLMReply(message: .assistant("secret answer"), inputTokens: 1200, outputTokens: 80, model: "deepseek-v4-pro", cachedInputTokens: 900)
        let line = ModelCallLog.line(conversation: "abcd1234", call: 3, purpose: "reply", provider: "deepseek", reply: reply, messages: 7, tools: 42, firstWordMilliseconds: nil, totalMilliseconds: 1500, costUSD: 0.5)
        XCTAssertEqual(line, "model-call conv=abcd1234 n=3 purpose=reply provider=deepseek model=deepseek-v4-pro in=1200 cached=900 out=80 msgs=7 tools=42 first_word_ms=- total_ms=1500 cost_usd=0.500000")
        XCTAssertFalse(line.contains("secret"))
    }

    func testFailureLineNamesTheKindOfFailure() {
        let overflow = ModelCallLog.failureLine(conversation: "-", call: 0, purpose: "helper", provider: "p", model: "m", error: LLMError(message: "too long", isContextOverflow: true), totalMilliseconds: 5)
        XCTAssertTrue(overflow.hasSuffix("failed=context-overflow total_ms=5"), overflow)
        let http = ModelCallLog.failureLine(conversation: "-", call: 0, purpose: "helper", provider: "p", model: "m", error: LLMError(message: "HTTP 429: slow down", statusCode: 429), totalMilliseconds: 5)
        XCTAssertTrue(http.contains("failed=http-429"), http)
        XCTAssertFalse(http.contains("slow down"))
        let cancelled = ModelCallLog.failureLine(conversation: "-", call: 0, purpose: "helper", provider: "p", model: "m", error: CancellationError(), totalMilliseconds: 5)
        XCTAssertTrue(cancelled.contains("failed=cancelled"), cancelled)
    }

    func testAReplyWritesOneLinePerCallAndOneForTheReply() async throws {
        let lines = LockedLines()
        EngineLog.setSink { level, line in
            if level == .info { lines.append(line) }
        }
        let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, routing: false, completion: { _, _, _, _, _, _ in
            LLMReply(message: .assistant("Hello there."), inputTokens: 1000, outputTokens: 50, model: "claude-sonnet-4-5", cachedInputTokens: 400)
        })
        let conversation = try await conversations.create(ownerID: "owner")
        let tag = "conv=" + String(conversation.id.uuidString.prefix(8)).lowercased() + " "
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Hi", launchedBy: "Owner", language: "en")
        var mine: [String] = []
        for _ in 0..<250 {
            mine = lines.values.filter { $0.contains(tag) }
            if mine.contains(where: { $0.hasPrefix("reply ") }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let calls = mine.filter { $0.hasPrefix("model-call ") }
        XCTAssertEqual(calls.count, 1, mine.joined(separator: "\n"))
        XCTAssertTrue(calls.first?.contains("n=1 purpose=reply provider=test model=claude-sonnet-4-5 in=1000 cached=400 out=50") == true, calls.first ?? "")
        // 600 fresh tokens at $3 and 400 cached at $0.30 per million, plus 50 out at $15.
        XCTAssertTrue(calls.first?.hasSuffix("cost_usd=0.002670") == true, calls.first ?? "")
        let summary = mine.first { $0.hasPrefix("reply ") }
        XCTAssertTrue(summary?.contains("calls=1 in=1000 cached=400 out=50") == true, mine.joined(separator: "\n"))
        XCTAssertTrue(summary?.hasSuffix("cost_usd=0.002670") == true, summary ?? "")
        await engine.shutdown()
    }

    private final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }
}
