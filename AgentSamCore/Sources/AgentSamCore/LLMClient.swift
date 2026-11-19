import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderRegistry: Sendable {
    public var providers: [ProviderConfig]

    public init(providers: [ProviderConfig] = ProviderConfig.builtin) {
        self.providers = providers
    }

    public func provider(id: String) -> ProviderConfig? {
        providers.first(where: { $0.id == id })
    }
}

public struct LLMClient: Sendable {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
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
        // Some models (DeepSeek in particular) write tool calls into the text as DSML markup. Keep that markup
        // off the screen while it streams, and turn it into real tool calls once the reply is complete.
        let filtered = onDelta.map { DSMLStreamFilter(downstream: $0).handler }
        var reply: LLMReply
        switch provider.kind {
        case .anthropic:
            reply = try await AnthropicClient(session: session).complete(
                provider: provider, key: key, model: model, system: system,
                messages: messages, tools: tools, temperature: temperature,
                maxTokens: maxTokens, onDelta: filtered
            )
        case .openAICompatible:
            reply = try await OpenAICompatClient(session: session).complete(
                provider: provider, key: key, model: model, system: system,
                messages: messages, tools: tools, temperature: temperature,
                maxTokens: maxTokens, onDelta: filtered
            )
        }
        reply.message = DSMLToolCalls.normalize(reply.message, toolsOffered: !(tools ?? []).isEmpty)
        return reply
    }

    public func testConnection(provider: ProviderConfig, key: String) async -> (ok: Bool, message: String) {
        do {
            var request = URLRequest(url: URL(string: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (provider.kind == .anthropic ? "/v1/models" : "/models"))!)
            request.httpMethod = "GET"
            if provider.kind == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if let decoded = try? JSONDecoder().decode(ModelsList.self, from: data),
                   let names = decoded.data?.compactMap(\.id), !names.isEmpty {
                    return (true, "Connected — \(names.count) models visible.")
                }
                return (true, "Connected.")
            }
            return (false, "HTTP \(status): " + Self.snippet(of: data))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    public struct ModelsList: Decodable {
        public struct Model: Decodable { public var id: String? }
        public var data: [Model]?
    }

    /// OpenAI-style APIs have no error flag on a tool result, so a failed result says so in its text.
    static func wireContent(_ message: APIMessage) -> String? {
        guard message.role == "tool", message.is_error == true, let content = message.content else { return message.content }
        return "ERROR: " + content
    }

    static func snippet(of data: Data, limit: Int = 240) -> String {
        let text = String(data: data.prefix(4096), encoding: .utf8) ?? ""
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(limit))
    }
}

public struct OpenAICompatClient: Sendable {
    let session: URLSession

    struct ChatRequest: Encodable {
        var model: String
        var messages: [WireMessage]
        var tools: [APIToolDef]?
        var tool_choice: String?
        var temperature: Double?
        var max_tokens: Int?
        var stream: Bool?
    }

    struct WireMessage: Encodable {
        var role: String
        var content: WireContent?
        var tool_calls: [APIToolCall]?
        var tool_call_id: String?

        init(role: String, content: String?, images: [APIImage]? = nil, tool_calls: [APIToolCall]? = nil, tool_call_id: String? = nil) {
            self.role = role
            if let images, !images.isEmpty {
                // OpenAI-style multimodal content: text part, then one image_url part per photo.
                let text = content ?? ""
                self.content = .parts((text.isEmpty ? [] : [.text(text)]) + images.map { .image($0.dataURL) })
            } else {
                self.content = content.map(WireContent.text)
            }
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
        }
    }

    /// A plain string, or a list of text and image parts when the turn carries photos.
    enum WireContent: Encodable {
        case text(String)
        case parts([WirePart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    enum WirePart: Encodable {
        case text(String)
        case image(String)

        private enum CodingKeys: String, CodingKey { case type, text, image_url }
        private struct ImageURL: Encodable { var url: String }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: url), forKey: .image_url)
            }
        }
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            var message: APIMessage
        }
        struct Usage: Decodable {
            struct Details: Decodable { var cached_tokens: Int? }
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var prompt_tokens_details: Details?
            /// DeepSeek's name for the cached part of the prompt.
            var prompt_cache_hit_tokens: Int?
            var cached: Int { prompt_tokens_details?.cached_tokens ?? prompt_cache_hit_tokens ?? 0 }
        }
        var choices: [Choice]?
        var usage: Usage?
        var error: WireError?
    }

    struct WireError: Decodable {
        var message: String?
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
        let wire = [WireMessage(role: "system", content: system)]
            + messages.map { WireMessage(role: $0.role, content: LLMClient.wireContent($0), images: $0.role == "user" ? $0.images : nil, tool_calls: $0.tool_calls, tool_call_id: $0.tool_call_id) }
        let body = ChatRequest(
            model: model,
            messages: wire,
            tools: tools?.isEmpty == true ? nil : tools,
            tool_choice: tools == nil ? nil : "auto",
            temperature: temperature ?? 0.3,
            max_tokens: maxTokens,
            stream: onDelta == nil ? nil : true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(body)

        var backoff: [UInt64] = [4, 10]
        var lastError: LLMError = LLMError(message: "No attempts made.")
        for _ in 0..<3 {
            var request = URLRequest(url: URL(string: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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

            if Self.isContextOverflow(status: status, body: data) {
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
                let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                if let error = decoded.error {
                    throw LLMError(message: error.message ?? "Provider error.")
                }
                guard let message = decoded.choices?.first?.message else {
                    throw LLMError(message: "Empty response from provider.")
                }
                return LLMReply(
                    message: message,
                    inputTokens: decoded.usage?.prompt_tokens ?? 0,
                    outputTokens: decoded.usage?.completion_tokens ?? 0,
                    model: model,
                    cachedInputTokens: decoded.usage?.cached ?? 0
                )
            } catch let error as LLMError {
                throw error
            } catch {
                throw LLMError(message: "Could not decode response: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private func streamReply(request: URLRequest, model: String, onDelta: TextDeltaHandler) async throws -> LLMReply {
        var accumulator = OpenAIStreamAccumulator()
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

    static func isContextOverflow(status: Int, body: Data) -> Bool {
        guard status == 400 || status == 413 || status == 429 else { return false }
        let text = String(data: body.prefix(8192), encoding: .utf8)?.lowercased() ?? ""
        let markers = ["context length", "context window", "too many tokens", "maximum context", "input length exceeded", "prompt is too long"]
        return markers.contains(where: { text.contains($0) })
    }
}
