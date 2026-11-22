import Foundation

/// Deterministic conversation trimming so agent loops survive the context
/// window instead of failing the task when the provider rejects the request.
///
/// A conversation is a sequence of turns: an assistant message (possibly
/// with tool calls) followed by its tool results. Chat APIs require that
/// pairing to stay intact, so compaction drops whole middle turns, keeps the
/// leading prompt messages and the most recent turns, and tells the model
/// what happened. If even the newest turn is too large, oversized tool
/// results are truncated and already-executed tool-call payloads are replaced
/// with tiny stubs (their files live in the workspace).
public enum ConversationCompactor {
    /// Rough token estimate used for budgeting: ~4 characters per token.
    public static func estimateTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// Budget floor for the retry ladder; below this only per-message
    /// truncation remains.
    public static let minimumBudgetTokens = 12_000

    /// Shown to the model when middle turns were dropped.
    public static let trimmedNotice = """
    [Earlier turns of this conversation were trimmed to fit the context window. \
    Files you already wrote are still in the workspace; re-read one only if you need its contents. \
    Continue from your most recent tool results.]
    """

    // MARK: Summarizing compaction

    /// Writes (or extends) a summary of turns that no longer fit. Returns nil when the model call
    /// fails, in which case compaction falls back to the plain tool-call list.
    public typealias Summarizer = @Sendable (_ previousSummary: String?, _ transcript: String) async -> String?

    /// Remembers the summary of the turns already dropped from one running conversation, so each
    /// new round only summarizes the turns dropped since the last one instead of starting over.
    public final class SummaryState: @unchecked Sendable {
        private let lock = NSLock()
        private var covered = 0
        private var text: String?
        private var fingerprint = ""

        public init() {}

        func snapshot(fingerprint: String) -> (covered: Int, text: String?) {
            lock.lock(); defer { lock.unlock() }
            if self.fingerprint != fingerprint { self.fingerprint = fingerprint; covered = 0; text = nil }
            return (covered, text)
        }

        func store(covered: Int, text: String) {
            lock.lock(); defer { lock.unlock() }
            self.covered = covered
            self.text = text
        }
    }

    /// While summarizing, trim down to this share of the budget, so a trim happens in larger steps
    /// (one summary call per many rounds) instead of on every round.
    static let summarizeTargetShare = 0.7

    /// Like `compact`, but summarizes the turns it drops with `summarizer`. Falls back to the
    /// tool-call list if the summary call fails.
    public static func compact(messages: [APIMessage], budgetTokens: Int, summarizer: Summarizer, state: SummaryState) async -> Outcome {
        guard size(messages) > budgetTokens else {
            return Outcome(messages: messages, trimmed: false, notice: nil)
        }
        let target = min(budgetTokens, max(minimumBudgetTokens / 2, Int(Double(budgetTokens) * summarizeTargetShare)))
        let (head, turns) = units(messages)
        guard turns.count > 1 else { return compact(messages: messages, budgetTokens: budgetTokens) }
        var keptSize = size(head) + size(turns[turns.count - 1])
        var firstKept = turns.count - 1
        while firstKept > 0, keptSize + size(turns[firstKept - 1]) <= target {
            firstKept -= 1
            keptSize += size(turns[firstKept])
        }
        guard firstKept > 0 else { return compact(messages: messages, budgetTokens: budgetTokens) }

        let known = state.snapshot(fingerprint: fingerprint(of: turns))
        var summary = known.text
        if known.covered < firstKept {
            let transcript = render(Array(turns[known.covered..<firstKept]))
            if let next = await summarizer(known.text, transcript), !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summary = String(next.prefix(6_000))
                state.store(covered: firstKept, text: summary ?? next)
            }
        }
        var outcome = compact(messages: messages, budgetTokens: target, summary: summary)
        if summary != nil, outcome.trimmed {
            outcome.notice = "Conversation compacted: summarized \(firstKept) of \(turns.count) earlier turns to fit the context window."
        }
        return outcome
    }

    /// Identifies a conversation by its first turn, so a state reused for another one starts clean.
    static func fingerprint(of turns: [[APIMessage]]) -> String {
        guard let first = turns.first?.first else { return "" }
        return String((first.content ?? "").prefix(120)) + "|" + (first.tool_calls?.first?.id ?? "")
    }

    /// The dropped turns as plain text for the summarizer, newest part kept when it is long.
    static func render(_ turns: [[APIMessage]], maxCharacters: Int = 60_000) -> String {
        var lines: [String] = []
        for message in turns.flatMap({ $0 }) {
            switch message.role {
            case "tool":
                lines.append("RESULT: " + String((message.content ?? "").replacingOccurrences(of: "\n", with: " ").prefix(500)))
            default:
                if let text = message.content, !text.isEmpty { lines.append("\(message.role.uppercased()): " + String(text.prefix(1_200))) }
                for call in message.tool_calls ?? [] {
                    lines.append("CALL \(call.function.name): " + String(call.function.arguments.replacingOccurrences(of: "\n", with: " ").prefix(300)))
                }
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters { text = "…\n" + String(text.suffix(maxCharacters)) }
        return text
    }

    public static let summarySystem = """
    You compress the older part of an agent's working conversation so it can keep going with less context. \
    Write a faithful, compact summary (at most 350 words) of what happened: the goal, what was done and found, \
    files written or changed (with names), decisions and their reasons, errors hit, and what is still open. \
    Keep exact names, paths, numbers and identifiers. Do not invent anything and do not address the reader.
    """

    public static func summaryRequest(previous: String?, transcript: String) -> String {
        let base = previous.map { "Summary so far:\n\($0)\n\nNew activity since that summary:\n" } ?? "Activity to summarize:\n"
        return base + transcript + "\n\nWrite the updated summary."
    }

    /// One line per dropped tool call, so the model still knows what it already did.
    static func digest(of dropped: [[APIMessage]], maxLines: Int = 25) -> String {
        var lines: [String] = []
        for message in dropped.flatMap({ $0 }) {
            for call in message.tool_calls ?? [] {
                let arguments = call.function.arguments.replacingOccurrences(of: "\n", with: " ")
                lines.append("- \(call.function.name) \(arguments.count > 80 ? String(arguments.prefix(80)) + "…" : arguments)")
            }
        }
        guard !lines.isEmpty else { return "" }
        let shown = lines.suffix(maxLines)
        let omitted = lines.count - shown.count
        return "\nTool calls already made in the trimmed turns" + (omitted > 0 ? " (last \(shown.count) of \(lines.count))" : "") + ":\n" + shown.joined(separator: "\n")
    }

    /// Valid-JSON stand-in for the arguments of an already-executed tool call.
    static let stubbedArguments = #"{"__trimmed__":"see the file in the workspace"}"#

    public struct Outcome: Sendable {
        public var messages: [APIMessage]
        public var trimmed: Bool
        public var notice: String?
    }

    /// Estimated size of the whole conversation, in the same token units
    /// as `budgetTokens`.
    static func size(_ messages: [APIMessage]) -> Int {
        messages.reduce(0) { total, message in total + size(of: message) }
    }

    /// Estimated size of one message: its text plus any tool-call payloads.
    private static func size(of message: APIMessage) -> Int {
        // A photo resized for upload costs roughly 1,600 input tokens on vision models.
        var total = estimateTokens(message.content ?? "") + (message.images?.count ?? 0) * 1_600
        for call in message.tool_calls ?? [] {
            total += estimateTokens(call.function.name) + estimateTokens(call.function.arguments)
        }
        return total
    }

    /// Splits the conversation into leading prompt messages (`head`) and turn
    /// units. A turn is one assistant message plus the tool results that
    /// immediately follow it — a pairing the chat APIs require, so turns are
    /// always dropped whole.
    static func units(_ messages: [APIMessage]) -> (head: [APIMessage], turns: [[APIMessage]]) {
        var head: [APIMessage] = []
        var turns: [[APIMessage]] = []
        var index = 0
        while index < messages.count {
            if messages[index].role == "assistant" || messages[index].role == "tool" { break }
            head.append(messages[index])
            index += 1
        }
        while index < messages.count {
            guard messages[index].role == "assistant" else {
                // A stray non-turn message mid-conversation (e.g. a replan
                // prompt): small and structural, so it always stays.
                head.append(messages[index])
                index += 1
                continue
            }
            var turn: [APIMessage] = [messages[index]]
            index += 1
            while index < messages.count, messages[index].role == "tool" {
                turn.append(messages[index])
                index += 1
            }
            turns.append(turn)
        }
        return (head, turns)
    }

    public static func compact(messages: [APIMessage], budgetTokens: Int, summary: String? = nil) -> Outcome {
        guard size(messages) > budgetTokens else {
            return Outcome(messages: messages, trimmed: false, notice: nil)
        }

        let (head, turns) = units(messages)
        guard !turns.isEmpty else {
            return truncate(messages: messages, budgetTokens: budgetTokens)
        }

        // Keep the newest turn plus as many preceding turns as fit the budget.
        var keptSize = size(head) + (turns.last.map { size($0) } ?? 0)
        var firstKept = turns.count - 1
        while firstKept > 0, keptSize + size(turns[firstKept - 1]) <= budgetTokens {
            firstKept -= 1
            keptSize += size(turns[firstKept])
        }

        var result = head
        if firstKept > 0 {
            // The extra text only gets the room the kept turns leave under the budget.
            let room = max(0, budgetTokens - keptSize - estimateTokens(trimmedNotice)) * 4
            let extra = summary.map { "\nSummary of the trimmed turns:\n" + $0 } ?? digest(of: Array(turns[..<firstKept]))
            let notice = trimmedNotice + (extra.count <= room ? extra : "")
            // Merge the notice into the last kept user message: Anthropic
            // rejects consecutive same-role messages.
            if let lastIndex = result.indices.last, result[lastIndex].role == "user" {
                let existing = result[lastIndex].content ?? ""
                result[lastIndex].content = existing + (existing.isEmpty ? "" : "\n\n") + notice
            } else {
                result.append(.user(notice))
            }
        }
        for turn in turns[firstKept...] {
            result.append(contentsOf: turn)
        }

        if size(result) <= budgetTokens {
            return Outcome(
                messages: result,
                trimmed: firstKept > 0,
                notice: firstKept > 0
                    ? "Conversation trimmed: dropped \(firstKept) of \(turns.count) earlier turns to fit the context window."
                    : nil
            )
        }

        // Even head + the newest turn exceeds the budget: truncate the largest
        // message payloads until it fits.
        let truncated = truncate(messages: result, budgetTokens: budgetTokens)
        let notice: String?
        if firstKept > 0 {
            notice = truncated.trimmed
                ? "Trimmed \(firstKept) earlier turns, then truncated oversized tool results to fit the context window."
                : "Trimmed \(firstKept) earlier turns to fit the context window."
        } else {
            notice = truncated.notice
        }
        return Outcome(messages: truncated.messages, trimmed: firstKept > 0 || truncated.trimmed, notice: notice)
    }

    /// Repeatedly shrinks the largest message payload until the conversation
    /// fits: already-executed tool-call arguments become tiny JSON stubs, and
    /// oversized tool results are halved with a marker appended.
    static func truncate(messages: [APIMessage], budgetTokens: Int) -> Outcome {
        var messages = messages
        var changed = false
        var iterations = 0
        while size(messages) > budgetTokens, iterations < 64 {
            iterations += 1
            guard let target = largestTextualIndex(in: messages) else { break }

            if var calls = messages[target].tool_calls, !calls.isEmpty {
                guard let callIndex = calls.indices.max(by: { calls[$0].function.arguments.count < calls[$1].function.arguments.count }) else { break }
                if calls[callIndex].function.arguments != stubbedArguments {
                    calls[callIndex].function.arguments = stubbedArguments
                    messages[target].tool_calls = calls
                    changed = true
                    continue
                }
                // All payloads already stubbed; fall through to the text.
            }
            guard var content = messages[target].content, !content.isEmpty else { break }
            let keep = max(1, content.count / 2)
            content = String(content.prefix(keep)) + "\n…[trimmed to fit the context window]"
            messages[target].content = content
            changed = true
        }
        return Outcome(
            messages: messages,
            trimmed: changed,
            notice: changed ? "Truncated oversized tool results to fit the context window." : nil
        )
    }

    /// Index of the message carrying the most text (tool results or
    /// tool-call payloads).
    private static func largestTextualIndex(in messages: [APIMessage]) -> Int? {
        var bestIndex: Int?
        var bestWeight = 0
        for index in messages.indices {
            let contentWeight = messages[index].content?.count ?? 0
            let callsWeight = messages[index].tool_calls?.reduce(0) { $0 + $1.function.arguments.count } ?? 0
            let weight = max(contentWeight, callsWeight)
            if weight > bestWeight {
                bestWeight = weight
                bestIndex = index
            }
        }
        return bestIndex
    }
}

/// Summary states for the agents of running missions, one per mission and agent.
final class SummaryStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ConversationCompactor.SummaryState] = [:]

    func state(missionID: UUID, agent: String) -> ConversationCompactor.SummaryState {
        lock.lock(); defer { lock.unlock() }
        let key = "\(missionID.uuidString)|\(agent)"
        if let existing = states[key] { return existing }
        let created = ConversationCompactor.SummaryState()
        states[key] = created
        return created
    }
}
