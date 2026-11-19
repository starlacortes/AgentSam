import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicClient: Sendable {
    let session: URLSession

    struct WireRequest: Encodable {
        var model: String
        var system: [SystemBlock]?
        var messages: [WireMessage]
        var tools: [WireTool]?
        var max_tokens: Int
        var temperature: Double?
        var stream: Bool?
    }

    struct WireMessage: Encodable {
        var role: String
        var content: [ContentBlock]
    }

    /// Marks the end of a prompt prefix that Anthropic may cache and reuse on the next call.
    struct CacheControl: Encodable, Equatable {
        var type = "ephemeral"
    }

    struct SystemBlock: Encodable {
        var type = "text"
        var text: String
        var cache_control: CacheControl?
    }

    /// The system prompt as one cached block, or nil when it is empty (Anthropic rejects empty text).
    /// The breakpoint covers the tool definitions too, since they come before the system prompt.
    static func systemBlocks(_ system: String) -> [SystemBlock]? {
        system.isEmpty ? nil : [SystemBlock(text: system, cache_control: CacheControl())]
    }

    indirect enum ContentBlock: Encodable {
        case text(String)
        case image(mediaType: String, data: String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(id: String, content: String, isError: Bool = false)
        /// The wrapped block with a cache breakpoint after it.
        case cached(ContentBlock)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case id
            case name
            case input
            case tool_use_id
            case is_error
            case content
            case source
            case cache_control
        }

        private struct ImageSource: Encodable {
            var type = "base64"
            var media_type: String
            var data: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let mediaType, let data):
                try container.encode("image", forKey: .type)
                try container.encode(ImageSource(media_type: mediaType, data: data), forKey: .source)
            case .toolUse(let id, let name, let input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case .toolResult(let id, let content, let isError):
                try container.encode("tool_result", forKey: .type)
                try container.encode(id, forKey: .tool_use_id)
                try container.encode(content, forKey: .content)
                if isError { try container.encode(true, forKey: .is_error) }
            case .cached(let inner):
                try inner.encode(to: encoder)
                try container.encode(CacheControl(), forKey: .cache_control)
            }
        }
    }

    struct WireTool: Encodable {
        var name: String
        var description: String
        var input_schema: JSONValue
    }

    struct WireResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
            var id: String?
            var name: String?
            var input: JSONValue?
        }
        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation_input_tokens: Int?
        }
        var content: [Block]?
        var usage: Usage?
        var stop_reason: String?
        var error: WireError?
    }

    struct WireError: Decodable {
        struct Inner: Decodable { var message: String? }
        var message: String?
        var type: String?
    }

    public func complete(
        provider: ProviderConfig,
        key: String,
        model: String,
        system: String,
        messages: [APIMessage],
        tools: [APIToolDef]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        onDelta: TextDeltaHandler? = nil
    ) async throws -> LLMReply {
        let wireMessages = Self.withCacheBreakpoint(Self.translate(messages: messages))
        let body = WireRequest(
            model: model,
            system: Self.systemBlocks(system),
            messages: wireMessages,
            tools: tools?.map { WireTool(name: $0.function.name, description: $0.function.description, input_schema: $0.function.parameters) },
            max_tokens: maxTokens ?? 16384,
            temperature: temperature ?? 0.3,
            stream: onDelta == nil ? nil : true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(body)

        var backoff: [UInt64] = [4, 10]
        var lastError: LLMError = LLMError(message: "No attempts made.")
        for _ in 0..<3 {
            var request = URLRequest(url: URL(string: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            if let onDelta {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    return try await streamReply(request: request, model: model, onDelta: onDelta)
                } catch let failure as StreamFailure {
                    if failure.retryable {
                        lastError = failure.error
                        let delay = backoff.isEmpty ? 15 : backoff.removeFirst()
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        continue
                    }
                    throw failure.error
                }
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw LLMError(message: "Network error: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if OpenAICompatClient.isContextOverflow(status: status, body: data) {
                throw LLMError(message: "Conversation exceeded the model's context window.", isContextOverflow: true)
            }
            if status == 429 || status >= 500 {
                lastError = LLMError(message: "HTTP \(status): " + LLMClient.snippet(of: data), statusCode: status)
                let delay = backoff.isEmpty ? 15 : backoff.removeFirst()
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                continue
            }
            guard (200..<300).contains(status) else {
                throw LLMError(message: "HTTP \(status): " + LLMClient.snippet(of: data), statusCode: status)
            }
            do {
                let decoded = try JSONDecoder().decode(WireResponse.self, from: data)
                if let error = decoded.error {
                    throw LLMError(message: error.message ?? error.type ?? "Provider error.")
                }
                let text = decoded.content?.compactMap(\.text).joined(separator: "\n") ?? ""
                let calls = decoded.content?.compactMap { block -> APIToolCall? in
                    guard block.type == "tool_use", let id = block.id, let name = block.name else { return nil }
                    let argsData = (try? JSONEncoder().encode(block.input ?? .null)) ?? Data("{}".utf8)
                    let args = String(data: argsData, encoding: .utf8) ?? "{}"
                    return APIToolCall(id: id, function: .init(name: name, arguments: args))
                } ?? []
                let message = APIMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : text,
                    tool_calls: calls.isEmpty ? nil : calls
                )
                // Anthropic's input_tokens leaves out cached tokens; add them back so inputTokens stays the total.
                let cacheRead = decoded.usage?.cache_read_input_tokens ?? 0
                let cacheWrite = decoded.usage?.cache_creation_input_tokens ?? 0
                return LLMReply(
                    message: message,
                    inputTokens: (decoded.usage?.input_tokens ?? 0) + cacheRead + cacheWrite,
                    outputTokens: decoded.usage?.output_tokens ?? 0,
                    model: model,
                    cachedInputTokens: cacheRead
                )
            } catch let error as LLMError {
                throw error
            } catch {
                throw LLMError(message: "Could not decode response: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// Streams one reply. Failures before any text was delivered may be retried; later ones may not,
    /// because the caller has already shown the partial answer.
    private func streamReply(request: URLRequest, model: String, onDelta: TextDeltaHandler) async throws -> LLMReply {
        var accumulator = AnthropicStreamAccumulator()
        var delivered = false
        do {
            for try await event in streamEvents(session: session, request: request) {
                if let text = accumulator.consume(event.data) {
                    delivered = true
                    onDelta(text)
                }
                if let message = accumulator.errorMessage {
                    throw StreamFailure(error: LLMError(message: message), retryable: !delivered)
                }
            }
        } catch let failure as StreamFailure {
            throw failure
        } catch let http as StreamHTTPError {
            throw StreamFailure.http(http)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StreamFailure(error: LLMError(message: "Network error: \(error.localizedDescription)"), retryable: false)
        }
        return LLMReply(message: accumulator.message(), inputTokens: accumulator.inputTokens, outputTokens: accumulator.outputTokens, model: model, cachedInputTokens: accumulator.cachedInputTokens)
    }

    /// Puts a cache breakpoint on the last block of the last message, so the next call in a tool loop
    /// or the next chat turn can reuse everything up to here.
    static func withCacheBreakpoint(_ messages: [WireMessage]) -> [WireMessage] {
        var messages = messages
        guard let last = messages.indices.last, let block = messages[last].content.last else { return messages }
        if case .cached = block { return messages }
        messages[last].content[messages[last].content.count - 1] = .cached(block)
        return messages
    }

    static func translate(messages: [APIMessage]) -> [WireMessage] {
        var wire: [WireMessage] = []
        var pendingToolResults: [ContentBlock] = []

        func flushResults() {
            guard !pendingToolResults.isEmpty else { return }
            wire.append(WireMessage(role: "user", content: pendingToolResults))
            pendingToolResults = []
        }

        for message in messages {
            switch message.role {
            case "system":
                continue
            case "user":
                flushResults()
                // Images go before the text, as Anthropic recommends.
                var blocks: [ContentBlock] = (message.images ?? []).map { .image(mediaType: $0.mediaType, data: $0.data) }
                let text = message.content ?? ""
                if !text.isEmpty || blocks.isEmpty { blocks.append(.text(text)) }
                wire.append(WireMessage(role: "user", content: blocks))
            case "assistant":
                flushResults()
                var blocks: [ContentBlock] = []
                if let text = message.content, !text.isEmpty {
                    blocks.append(.text(text))
                }
                for call in message.tool_calls ?? [] {
                    let input: JSONValue
                    if let data = call.function.arguments.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        input = decoded
                    } else {
                        input = .object([:])
                    }
                    blocks.append(.toolUse(id: call.id, name: call.function.name, input: input))
                }
                if !blocks.isEmpty {
                    wire.append(WireMessage(role: "assistant", content: blocks))
                }
            case "tool":
                pendingToolResults.append(.toolResult(id: message.tool_call_id ?? "", content: message.content ?? "", isError: message.is_error == true))
            default:
                continue
            }
        }
        flushResults()
        if wire.isEmpty {
            wire.append(WireMessage(role: "user", content: [.text("Begin.")]))
        }
        if wire.first?.role != "user" {
            wire.insert(WireMessage(role: "user", content: [.text("Begin.")]), at: 0)
        }
        return wire
    }
}
