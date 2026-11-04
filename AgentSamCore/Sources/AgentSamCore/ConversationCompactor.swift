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
        var total = estimateTokens(message.content ?? "")
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

    public static func compact(messages: [APIMessage], budgetTokens: Int) -> Outcome {
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
            // Merge the notice into the last kept user message: Anthropic
            // rejects consecutive same-role messages.
            if let lastIndex = result.indices.last, result[lastIndex].role == "user" {
                let existing = result[lastIndex].content ?? ""
                result[lastIndex].content = existing + (existing.isEmpty ? "" : "\n\n") + trimmedNotice
            } else {
                result.append(.user(trimmedNotice))
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
