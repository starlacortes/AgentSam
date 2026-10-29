import Foundation

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
        temperature: Double? = nil
    ) async throws -> LLMReply {
        switch provider.kind {
        case .anthropic:
            return try await AnthropicClient(session: session).complete(
                provider: provider, key: key, model: model, system: system,
                messages: messages, tools: tools, temperature: temperature
            )
        case .openAICompatible:
            return try await OpenAICompatClient(session: session).complete(
                provider: provider, key: key, model: model, system: system,
                messages: messages, tools: tools, temperature: temperature
            )
        }
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
    }

    struct WireMessage: Encodable {
        var role: String
        var content: String?
        var tool_calls: [APIToolCall]?
        var tool_call_id: String?
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            var message: APIMessage
        }
        struct Usage: Decodable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
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
        temperature: Double? = nil
    ) async throws -> LLMReply {
        let wire = [WireMessage(role: "system", content: system)]
            + messages.map { WireMessage(role: $0.role, content: $0.content, tool_calls: $0.tool_calls, tool_call_id: $0.tool_call_id) }
        let body = ChatRequest(
            model: model,
            messages: wire,
            tools: tools?.isEmpty == true ? nil : tools,
            tool_choice: tools == nil ? nil : "auto",
            temperature: temperature ?? 0.3
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
                    model: model
                )
            } catch let error as LLMError {
                throw error
            } catch {
                throw LLMError(message: "Could not decode response: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    static func isContextOverflow(status: Int, body: Data) -> Bool {
        guard status == 400 || status == 413 || status == 429 else { return false }
        let text = String(data: body.prefix(8192), encoding: .utf8)?.lowercased() ?? ""
        let markers = ["context length", "context window", "too many tokens", "maximum context", "input length exceeded", "prompt is too long"]
        return markers.contains(where: { text.contains($0) })
    }
}
