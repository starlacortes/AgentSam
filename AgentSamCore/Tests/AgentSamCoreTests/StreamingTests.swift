import XCTest
@testable import AgentSamCore

final class StreamingTests: XCTestCase {
    func testSSEParserHandlesSplitChunksAndCRLF() {
        var parser = SSEParser()
        var events = parser.feed(Data("event: content_block_delta\r\ndata: {\"a\"".utf8))
        XCTAssertTrue(events.isEmpty)
        events = parser.feed(Data(":1}\r\n\r\n: keep-alive\n\ndata: [DONE]\n\n".utf8))
        XCTAssertEqual(events, [
            SSEEvent(event: "content_block_delta", data: "{\"a\":1}"),
            SSEEvent(event: nil, data: "[DONE]"),
        ])
    }

    func testSSEParserJoinsMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.feed(Data("data: one\ndata: two\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "one\ntwo")])
    }

    func testAnthropicAccumulatorBuildsTextAndToolCall() {
        var accumulator = AnthropicStreamAccumulator()
        var streamed = ""
        let payloads = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"web_search"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#,
            #"{"type":"message_delta","usage":{"output_tokens":9}}"#,
            #"{"type":"ping"}"#,
        ]
        for payload in payloads { if let text = accumulator.consume(payload) { streamed += text } }
        let message = accumulator.message()
        XCTAssertEqual(streamed, "Hello")
        XCTAssertEqual(message.content, "Hello")
        XCTAssertEqual(message.tool_calls?.first?.id, "t1")
        XCTAssertEqual(message.tool_calls?.first?.function.name, "web_search")
        XCTAssertEqual(message.tool_calls?.first?.function.arguments, #"{"q":"swift"}"#)
        XCTAssertEqual(accumulator.inputTokens, 12)
        XCTAssertEqual(accumulator.outputTokens, 9)
    }

    func testAnthropicAccumulatorReportsMidStreamError() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.consume(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertEqual(accumulator.errorMessage, "Overloaded")
    }

    func testOpenAIAccumulatorBuildsTextAndToolCall() {
        var accumulator = OpenAIStreamAccumulator()
        var streamed = ""
        let payloads = [
            #"{"choices":[{"delta":{"role":"assistant","content":"Hi "}}]}"#,
            #"{"choices":[{"delta":{"content":"there"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"web_fetch","arguments":"{\"url\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"x\"}"}}]}}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#,
            "[DONE]",
        ]
        for payload in payloads { if let text = accumulator.consume(payload) { streamed += text } }
        let message = accumulator.message()
        XCTAssertEqual(streamed, "Hi there")
        XCTAssertEqual(message.content, "Hi there")
        XCTAssertEqual(message.tool_calls?.first?.function.name, "web_fetch")
        XCTAssertEqual(message.tool_calls?.first?.function.arguments, #"{"url":"x"}"#)
        XCTAssertEqual(accumulator.inputTokens, 5)
        XCTAssertEqual(accumulator.outputTokens, 7)
    }

    func testPartialTextStreamDeliversLatestTextAfterBurst() async throws {
        let received = Received()
        let stream = PartialTextStream(interval: 0.02) { text in await received.add(text) }
        for piece in ["a", "b", "c", "d"] { stream.handler(piece) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let all = await received.values
        XCTAssertEqual(all.last, "abcd")
        XCTAssertLessThan(all.count, 4, "a burst should be coalesced")
    }
}

private actor Received {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

/// Serves canned bytes in small chunks so the delegate path sees events split mid-line.
private final class ChunkedSSEProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var chunks: [String] = []
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class StreamingClientTests: XCTestCase {
    private func client() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedSSEProtocol.self]
        return AnthropicClient(session: URLSession(configuration: config))
    }

    private let provider = ProviderConfig(id: "a", name: "A", kind: .anthropic, baseURL: "https://example.test", models: ["m"])

    func testAnthropicStreamsDeltasAndReturnsFullReply() async throws {
        ChunkedSSEProtocol.status = 200
        ChunkedSSEProtocol.chunks = [
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_bl",
            "ock_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\", world\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":4}}\n\n",
        ]
        let deltas = Received()
        let reply = try await client().complete(provider: provider, key: "k", model: "m", system: "s", messages: [.user("hi")], onDelta: { delta in
            Task { await deltas.add(delta) }
        })
        XCTAssertEqual(reply.message.content, "Hello, world")
        XCTAssertEqual(reply.inputTokens, 3)
        XCTAssertEqual(reply.outputTokens, 4)
        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await deltas.values.sorted()
        XCTAssertEqual(seen, [", world", "Hello"])
        let body = String(decoding: ChunkedSSEProtocol.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"stream\":true"))
    }

    func testNonStreamingRequestDoesNotAskForStream() async throws {
        let wire = AnthropicClient.WireRequest(model: "m", system: "s", messages: [], tools: nil, max_tokens: 1, temperature: nil, stream: nil)
        let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        XCTAssertFalse(json.contains("stream"))
    }

    func testStreamingHTTPErrorSurfacesWithoutRetryForClientErrors() async {
        ChunkedSSEProtocol.status = 401
        ChunkedSSEProtocol.chunks = ["{\"error\":{\"message\":\"bad key\"}}"]
        do {
            _ = try await client().complete(provider: provider, key: "k", model: "m", system: "s", messages: [.user("hi")], onDelta: { _ in })
            XCTFail("expected an error")
        } catch let error as LLMError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.message.contains("bad key"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
