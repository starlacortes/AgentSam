import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Receives text as a model produces it. Called from a network thread; keep it cheap.
public typealias TextDeltaHandler = @Sendable (String) -> Void

/// One server-sent event: the optional `event:` name and the joined `data:` lines.
struct SSEEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

/// Incremental server-sent-events parser. Feed it bytes as they arrive; it returns complete events.
struct SSEParser {
    private var buffer = Data()
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(where: { $0 == 0x0A }) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(SSEEvent(event: event, data: dataLines.joined(separator: "\n")))
                }
                event = nil
                dataLines = []
            } else if line.hasPrefix(":") {
                continue
            } else {
                let name: String
                var value: String
                if let colon = line.firstIndex(of: ":") {
                    name = String(line[..<colon])
                    value = String(line[line.index(after: colon)...])
                    if value.hasPrefix(" ") { value.removeFirst() }
                } else {
                    name = line
                    value = ""
                }
                switch name {
                case "event": event = value
                case "data": dataLines.append(value)
                default: break
                }
            }
        }
        return events
    }
}

/// A non-2xx answer to a streaming request, with the response body for diagnostics.
struct StreamHTTPError: Error {
    var status: Int
    var body: Data
}

/// A streaming attempt that failed, classified the same way the non-streaming path classifies HTTP errors.
struct StreamFailure: Error {
    var error: LLMError
    var retryable: Bool
    /// The connection dropped, which is worth trying again at once rather than after a long wait.
    var dropped = false

    /// A connection that failed before any text arrived is tried again: with connections kept open
    /// between calls, one the provider has since closed must not cost the reply. A timeout is not
    /// retried, and neither is a failure once part of the answer has been shown.
    static func network(_ error: Error, delivered: Bool) -> StreamFailure {
        var dropped = false
        if !delivered, let code = (error as? URLError)?.code {
            dropped = code != URLError.Code.timedOut && code != URLError.Code.cancelled
        }
        return StreamFailure(error: LLMError(message: "Network error: \(error.localizedDescription)"), retryable: dropped, dropped: dropped)
    }

    static func http(_ failure: StreamHTTPError) -> StreamFailure {
        if OpenAICompatClient.isContextOverflow(status: failure.status, body: failure.body) {
            return StreamFailure(error: LLMError(message: "Conversation exceeded the model's context window.", isContextOverflow: true), retryable: false)
        }
        let error = LLMError(message: "HTTP \(failure.status): " + LLMClient.snippet(of: failure.body), statusCode: failure.status)
        return StreamFailure(error: error, retryable: failure.status == 429 || failure.status >= 500)
    }
}

/// Runs streamed requests on one long-lived session, so the connection to a provider stays open
/// between the calls of a reply instead of being set up again for every tool round. Built on a
/// data-task delegate rather than `URLSession.bytes`, which does not exist in
/// swift-corelibs-foundation (Linux).
final class SSETransport: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let router = SSERouter()
    private let lock = NSLock()
    private var session: URLSession?

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    deinit {
        // The session holds its delegate until it is invalidated.
        session?.finishTasksAndInvalidate()
    }

    /// The shared session, made on first use so a client that never streams opens nothing.
    private func sharedSession() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let session { return session }
        let made = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
        session = made
        return made
    }

    /// Runs a request and yields its server-sent events as they arrive.
    func events(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let session = sharedSession()
        let router = self.router
        return AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            router.add(task.taskIdentifier, continuation: continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}

/// The shared session's delegate: hands each task's bytes to that task's own stream.
private final class SSERouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
        var parser = SSEParser()
        var status = 0
        var errorBody = Data()
    }

    private let lock = NSLock()
    private var streams: [Int: Pending] = [:]

    func add(_ id: Int, continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation) {
        lock.lock(); streams[id] = Pending(continuation: continuation); lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        streams[dataTask.taskIdentifier]?.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var stream = streams[dataTask.taskIdentifier] else { lock.unlock(); return }
        var events: [SSEEvent] = []
        if (200..<300).contains(stream.status) {
            events = stream.parser.feed(data)
        } else if stream.errorBody.count < 16_384 {
            stream.errorBody.append(data)
        }
        streams[dataTask.taskIdentifier] = stream
        lock.unlock()
        for event in events { stream.continuation.yield(event) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let stream = streams.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let stream else { return }
        if let error {
            stream.continuation.finish(throwing: error)
        } else if !(200..<300).contains(stream.status) {
            stream.continuation.finish(throwing: StreamHTTPError(status: stream.status, body: stream.errorBody))
        } else {
            stream.continuation.finish()
        }
    }
}

/// Turns Anthropic streaming events into the same shape a non-streaming reply has.
struct AnthropicStreamAccumulator {
    private struct Block {
        var type: String
        var text = ""
        var id: String?
        var name: String?
        var json = ""
    }

    private var blocks: [Int: Block] = [:]
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cachedInputTokens = 0
    private(set) var errorMessage: String?

    private struct Envelope: Decodable {
        struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int?; var cache_read_input_tokens: Int?; var cache_creation_input_tokens: Int? }
        struct Message: Decodable { var usage: Usage? }
        struct ContentBlock: Decodable { var type: String; var id: String?; var name: String? }
        struct Delta: Decodable { var type: String?; var text: String?; var partial_json: String? }
        struct Failure: Decodable { var type: String?; var message: String? }
        var type: String
        var index: Int?
        var message: Message?
        var content_block: ContentBlock?
        var delta: Delta?
        var usage: Usage?
        var error: Failure?
    }

    /// Consumes one event's JSON payload and returns any text it adds to the answer.
    mutating func consume(_ data: String) -> String? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(data.utf8)) else { return nil }
        switch envelope.type {
        case "message_start":
            if let usage = envelope.message?.usage {
                // input_tokens leaves out cached tokens; add them back so inputTokens stays the total.
                cachedInputTokens = usage.cache_read_input_tokens ?? 0
                inputTokens = (usage.input_tokens ?? 0) + cachedInputTokens + (usage.cache_creation_input_tokens ?? 0)
            }
            outputTokens = envelope.message?.usage?.output_tokens ?? outputTokens
        case "content_block_start":
            if let index = envelope.index, let block = envelope.content_block {
                blocks[index] = Block(type: block.type, id: block.id, name: block.name)
            }
        case "content_block_delta":
            guard let index = envelope.index, var block = blocks[index], let delta = envelope.delta else { return nil }
            if let text = delta.text, block.type == "text" {
                block.text += text
                blocks[index] = block
                return text
            }
            if let partial = delta.partial_json {
                block.json += partial
                blocks[index] = block
            }
        case "message_delta":
            outputTokens = envelope.usage?.output_tokens ?? outputTokens
        case "error":
            errorMessage = envelope.error?.message ?? envelope.error?.type ?? "Provider error."
        default:
            break
        }
        return nil
    }

    func message() -> APIMessage {
        let ordered = blocks.sorted { $0.key < $1.key }.map(\.value)
        let text = ordered.filter { $0.type == "text" }.map(\.text).joined(separator: "\n")
        let calls = ordered.compactMap { block -> APIToolCall? in
            guard block.type == "tool_use", let id = block.id, let name = block.name else { return nil }
            return APIToolCall(id: id, function: .init(name: name, arguments: block.json.isEmpty ? "{}" : block.json))
        }
        return APIMessage(role: "assistant", content: text.isEmpty ? nil : text, tool_calls: calls.isEmpty ? nil : calls)
    }
}

/// Turns OpenAI-compatible streaming chunks into a complete assistant message.
struct OpenAIStreamAccumulator {
    private struct Call {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var text = ""
    private var calls: [Int: Call] = [:]
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cachedInputTokens = 0
    private(set) var errorMessage: String?

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable { var name: String?; var arguments: String? }
                    var index: Int?
                    var id: String?
                    var function: Function?
                }
                var content: String?
                var tool_calls: [ToolCall]?
            }
            var delta: Delta?
        }
        struct Usage: Decodable {
            struct Details: Decodable { var cached_tokens: Int? }
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var prompt_tokens_details: Details?
            /// DeepSeek's name for the cached part of the prompt.
            var prompt_cache_hit_tokens: Int?
            var cached: Int? { prompt_tokens_details?.cached_tokens ?? prompt_cache_hit_tokens }
        }
        struct Failure: Decodable { var message: String? }
        var choices: [Choice]?
        var usage: Usage?
        var error: Failure?
    }

    mutating func consume(_ data: String) -> String? {
        guard data != "[DONE]", let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(data.utf8)) else { return nil }
        if let error = chunk.error { errorMessage = error.message ?? "Provider error." }
        inputTokens = chunk.usage?.prompt_tokens ?? inputTokens
        outputTokens = chunk.usage?.completion_tokens ?? outputTokens
        cachedInputTokens = chunk.usage?.cached ?? cachedInputTokens
        guard let delta = chunk.choices?.first?.delta else { return nil }
        for call in delta.tool_calls ?? [] {
            let index = call.index ?? 0
            var current = calls[index] ?? Call()
            if let id = call.id { current.id = id }
            if let name = call.function?.name { current.name += name }
            if let arguments = call.function?.arguments { current.arguments += arguments }
            calls[index] = current
        }
        if let content = delta.content, !content.isEmpty {
            text += content
            return content
        }
        return nil
    }

    func message() -> APIMessage {
        let toolCalls = calls.sorted { $0.key < $1.key }.compactMap { _, call -> APIToolCall? in
            guard !call.name.isEmpty else { return nil }
            return APIToolCall(id: call.id, function: .init(name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments))
        }
        return APIMessage(role: "assistant", content: text.isEmpty ? nil : text, tool_calls: toolCalls.isEmpty ? nil : toolCalls)
    }
}
