import Foundation

/// Call counts, tokens and timing for one reply, carried as a task-local (like `CostMeter`) so
/// every model call made for that reply is numbered and added to the same totals.
public final class ReplyTrace: @unchecked Sendable {
    public struct Totals: Sendable, Equatable {
        public var calls = 0
        public var inputTokens = 0
        public var cachedInputTokens = 0
        public var outputTokens = 0
        /// Time from the start of the reply to its first model call, the quick spoken
        /// acknowledgement aside. Nil when the reply made no model call.
        public var setupMilliseconds: Int?
    }

    /// A short name for the conversation, enough to follow one chat through the log.
    public let conversation: String
    private let started: UInt64
    private let lock = NSLock()
    private var totals = Totals()

    public init(conversationID: UUID? = nil) {
        conversation = conversationID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "-"
        started = ModelCallLog.now()
    }

    @TaskLocal public static var current: ReplyTrace?

    /// Numbers the next model call of this reply, starting at 1.
    func beginCall(purpose: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        totals.calls += 1
        if totals.setupMilliseconds == nil, purpose != ModelCallLog.acknowledgement {
            totals.setupMilliseconds = ModelCallLog.milliseconds(since: started)
        }
        return totals.calls
    }

    func record(_ reply: LLMReply) {
        lock.lock(); defer { lock.unlock() }
        totals.inputTokens += reply.inputTokens
        totals.cachedInputTokens += reply.cachedInputTokens
        totals.outputTokens += reply.outputTokens
    }

    public var snapshot: Totals {
        lock.lock(); defer { lock.unlock() }
        return totals
    }

    /// One line for the whole reply, written when it ends.
    public func summaryLine(costUSD: Double) -> String {
        let totals = snapshot
        return "reply conv=\(conversation) calls=\(totals.calls) in=\(totals.inputTokens) cached=\(totals.cachedInputTokens) out=\(totals.outputTokens)"
            + " setup_ms=\(totals.setupMilliseconds.map(String.init) ?? "-") total_ms=\(ModelCallLog.milliseconds(since: started))"
            + " cost_usd=\(ModelCallLog.dollars(costUSD))"
    }
}

/// The log line written for every model call: which model, how many tokens, how long. No message
/// text is ever logged.
enum ModelCallLog {
    /// The purpose of the quick spoken acknowledgement, which runs beside the reply's real work.
    static let acknowledgement = "ack"

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func milliseconds(since start: UInt64) -> Int {
        let now = now()
        return now > start ? Int((now - start) / 1_000_000) : 0
    }

    static func dollars(_ usd: Double) -> String { String(format: "%.6f", usd) }

    /// Remembers when the first words of a streamed answer arrived.
    final class FirstWord: @unchecked Sendable {
        private let lock = NSLock()
        private let started: UInt64
        private var elapsed: Int?

        init(started: UInt64) { self.started = started }

        func mark() {
            lock.lock(); defer { lock.unlock() }
            if elapsed == nil { elapsed = ModelCallLog.milliseconds(since: started) }
        }

        var milliseconds: Int? {
            lock.lock(); defer { lock.unlock() }
            return elapsed
        }
    }

    static func line(conversation: String, call: Int, purpose: String, provider: String, reply: LLMReply, messages: Int, tools: Int, firstWordMilliseconds: Int?, totalMilliseconds: Int, costUSD: Double) -> String {
        "model-call conv=\(conversation) n=\(call) purpose=\(purpose) provider=\(provider) model=\(reply.model)"
            + " in=\(reply.inputTokens) cached=\(reply.cachedInputTokens) out=\(reply.outputTokens)"
            + " msgs=\(messages) tools=\(tools)"
            + " first_word_ms=\(firstWordMilliseconds.map(String.init) ?? "-") total_ms=\(totalMilliseconds)"
            + " cost_usd=\(dollars(costUSD))"
    }

    static func failureLine(conversation: String, call: Int, purpose: String, provider: String, model: String, error: Error, totalMilliseconds: Int) -> String {
        let reason: String
        if error is CancellationError {
            reason = "cancelled"
        } else if let failure = error as? LLMError {
            reason = failure.isContextOverflow ? "context-overflow" : failure.statusCode.map { "http-\($0)" } ?? "provider-error"
        } else {
            reason = "error"
        }
        return "model-call conv=\(conversation) n=\(call) purpose=\(purpose) provider=\(provider) model=\(model) failed=\(reason) total_ms=\(totalMilliseconds)"
    }
}
