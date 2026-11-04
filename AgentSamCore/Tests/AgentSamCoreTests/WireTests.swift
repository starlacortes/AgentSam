import Foundation
import XCTest
@testable import AgentSamCore

/// Captures request bodies so the wire contract can be asserted without a
/// live provider.
final class CapturingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WireTests: XCTestCase {
    override func tearDown() {
        CapturingURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func bodyJSON(of request: URLRequest) -> JSONValue? {
        var data: Data?
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data?.append(buffer, count: read)
            }
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - max_tokens across providers

    func testAnthropicSendsDefaultMaxTokens() async throws {
        var captured: JSONValue?
        CapturingURLProtocol.handler = { request in
            captured = self.bodyJSON(of: request)
            return (Self.okResponse(for: request), Self.anthropicResponse)
        }
        let client = AnthropicClient(session: makeSession())
        _ = try await client.complete(
            provider: .init(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", models: []),
            key: "k", model: "claude-sonnet-4-5", system: "sys",
            messages: [.user("hi")]
        )
        XCTAssertEqual(captured?.objectValue?["max_tokens"]?.numberValue ?? -1, 16384)
    }

    func testAnthropicSendsConfiguredMaxTokens() async throws {
        var captured: JSONValue?
        CapturingURLProtocol.handler = { request in
            captured = self.bodyJSON(of: request)
            return (Self.okResponse(for: request), Self.anthropicResponse)
        }
        let client = AnthropicClient(session: makeSession())
        _ = try await client.complete(
            provider: .init(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", models: []),
            key: "k", model: "claude-sonnet-4-5", system: "sys",
            messages: [.user("hi")], maxTokens: 4096
        )
        XCTAssertEqual(captured?.objectValue?["max_tokens"]?.numberValue ?? -1, 4096)
    }

    func testOpenAIOmitsMaxTokensByDefault() async throws {
        var captured: JSONValue?
        CapturingURLProtocol.handler = { request in
            captured = self.bodyJSON(of: request)
            return (Self.okResponse(for: request), Self.openAIResponse)
        }
        let client = OpenAICompatClient(session: makeSession())
        _ = try await client.complete(
            provider: .init(id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", models: []),
            key: "k", model: "gpt-4o", system: "sys",
            messages: [.user("hi")]
        )
        XCTAssertNil(captured?.objectValue?["max_tokens"])
    }

    func testOpenAISendsMaxTokensWhenConfigured() async throws {
        var captured: JSONValue?
        CapturingURLProtocol.handler = { request in
            captured = self.bodyJSON(of: request)
            return (Self.okResponse(for: request), Self.openAIResponse)
        }
        let client = OpenAICompatClient(session: makeSession())
        _ = try await client.complete(
            provider: .init(id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", models: []),
            key: "k", model: "gpt-4o", system: "sys",
            messages: [.user("hi")], maxTokens: 4096
        )
        XCTAssertEqual(captured?.objectValue?["max_tokens"]?.numberValue ?? -1, 4096)
    }

    // MARK: - translate

    func testTranslateBatchesToolResultsIntoOneUserMessage() {
        let messages: [APIMessage] = [
            .user("Read the files."),
            APIMessage(role: "assistant", tool_calls: [
                APIToolCall(id: "a", function: .init(name: "read_file", arguments: #"{"path":"x.md"}"#)),
                APIToolCall(id: "b", function: .init(name: "read_file", arguments: #"{"path":"y.md"}"#)),
            ]),
            .tool(id: "a", content: "contents of x"),
            .tool(id: "b", content: "contents of y"),
            .assistant("Done."),
        ]
        let wire = AnthropicClient.translate(messages: messages)
        XCTAssertEqual(wire.map(\.role), ["user", "assistant", "user", "assistant"])
    }

    func testTranslateDropsSystemMessagesAndEnsuresUserFirst() {
        let wire = AnthropicClient.translate(messages: [
            .system("ignored"),
            .assistant("started without a user turn"),
        ])
        XCTAssertEqual(wire.map(\.role), ["user", "assistant"])
    }

    func testTranslateEmptyInputYieldsBeginMessage() {
        let wire = AnthropicClient.translate(messages: [])
        XCTAssertEqual(wire.map(\.role), ["user"])
    }

    func testTranslatePreservesToolUseIDsAndArguments() {
        let messages: [APIMessage] = [
            .user("go"),
            APIMessage(role: "assistant", tool_calls: [
                APIToolCall(id: "call-1", function: .init(name: "write_file", arguments: #"{"path":"n.md","content":"hi"}"#)),
            ]),
            .tool(id: "call-1", content: "Wrote n.md."),
        ]
        let wire = AnthropicClient.translate(messages: messages)
        XCTAssertEqual(wire.count, 3)

        let assistantBlocks = wire[1].content
        guard assistantBlocks.count == 1, case .toolUse(let id, let name, let input)? = assistantBlocks.first else {
            return XCTFail("expected one tool_use block")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "write_file")
        XCTAssertEqual(input.objectValue?["path"]?.stringValue, "n.md")

        let resultBlocks = wire[2].content
        guard resultBlocks.count == 1, case .toolResult(let resultID, let content)? = resultBlocks.first else {
            return XCTFail("expected one tool_result block")
        }
        XCTAssertEqual(resultID, "call-1")
        XCTAssertEqual(content, "Wrote n.md.")
    }

    // MARK: - Stub responses

    private static let anthropicResponse = Data(#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
    private static let openAIResponse = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)

    private static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
}
