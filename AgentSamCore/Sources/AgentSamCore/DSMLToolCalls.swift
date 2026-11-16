import Foundation

/// DeepSeek models sometimes write their tool calls into the reply text using the DSML markup from their
/// chat template instead of the provider's structured `tool_calls` field:
///
///     <｜DSML｜function_calls>
///     <｜DSML｜invoke name="googleads_query">
///     <｜DSML｜parameter name="customer_id" string="true">7569116792</｜DSML｜parameter>
///     </｜DSML｜invoke>
///     </｜DSML｜function_calls>
///
/// This happens most on long, tool-heavy turns, and also when no tools were offered on the request. Left alone,
/// the markup is shown to the user as the answer and the tool never runs. This type finds that markup, turns
/// every complete `invoke` into a real tool call, and removes the markup from the visible text.
enum DSMLToolCalls {
    /// Any DSML tag, opening or closing. The bars are the full-width `｜` DeepSeek uses, or ASCII `|`, and the
    /// tag name varies by model version (`function_calls`, `calls`, `tool_calls`, `invoke`, `parameter`).
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<\s*(/?)\s*[｜|]+\s*DSML\s*[｜|]+\s*([A-Za-z_]+)([^>]*)>"#
    )
    private static let markerPattern = try! NSRegularExpression(pattern: #"<\s*/?\s*[｜|]+\s*DSML"#)
    private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z_]+)\s*=\s*"([^"]*)""#)

    /// Cheap check before running the parser.
    static func mayContain(_ text: String) -> Bool {
        text.contains("DSML")
    }

    /// The range of the first DSML tag start in `text`, if any.
    static func firstMarker(in text: String) -> Range<String.Index>? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let match = markerPattern.firstMatch(in: text, range: ns) else { return nil }
        return Range(match.range, in: text)
    }

    /// True when `tail` (text starting at a `<`) could still grow into a DSML tag, so a stream should hold it back.
    static func couldStartMarker<S: StringProtocol>(_ tail: S) -> Bool {
        guard tail.first == "<", !tail.contains(">"), tail.count <= 24 else { return false }
        var rest = Substring(tail.dropFirst())
        rest = rest.drop(while: { $0.isWhitespace || $0 == "/" })
        rest = rest.drop(while: { $0 == "｜" || $0 == "|" || $0.isWhitespace })
        if rest.isEmpty { return true }
        return "DSML".hasPrefix(rest) || (rest.hasPrefix("DSML") && rest.dropFirst(4).allSatisfy { $0 == "｜" || $0 == "|" || $0.isWhitespace })
    }

    struct Extraction: Equatable {
        /// The reply text with all DSML markup removed.
        var text: String
        /// One call per complete `invoke` block, in order.
        var calls: [APIToolCall]
    }

    private struct Tag {
        var closing: Bool
        var name: String
        var attributes: [String: String]
        var range: Range<String.Index>
    }

    /// Parses DSML markup out of `text`. Returns nil when there is none. An `invoke` cut off before its closing
    /// tag (a reply that hit the output limit) is dropped rather than run with partial arguments.
    static func extract(from text: String) -> Extraction? {
        guard mayContain(text) else { return nil }
        let tags = scanTags(in: text)
        guard let first = tags.first else { return nil }

        var calls: [APIToolCall] = []
        var invokeName: String?
        var arguments: [(String, Any)] = []
        var parameter: (name: String, isString: Bool, start: String.Index)?

        for tag in tags {
            switch (tag.name.lowercased(), tag.closing) {
            case ("invoke", false):
                invokeName = tag.attributes["name"]
                arguments = []
                parameter = nil
            case ("parameter", false):
                guard invokeName != nil, let name = tag.attributes["name"] else { continue }
                parameter = (name, tag.attributes["string"]?.lowercased() != "false", tag.range.upperBound)
            case ("parameter", true):
                guard let open = parameter, open.start <= tag.range.lowerBound else { continue }
                let raw = String(text[open.start..<tag.range.lowerBound])
                arguments.append((open.name, value(raw, isString: open.isString)))
                parameter = nil
            case ("invoke", true):
                if let name = invokeName, !name.isEmpty, parameter == nil {
                    calls.append(APIToolCall(id: "dsml_\(calls.count)_" + UUID().uuidString.prefix(8).lowercased(), function: .init(name: name, arguments: encode(arguments))))
                }
                invokeName = nil
                arguments = []
                parameter = nil
            default:
                continue
            }
        }

        // Everything from the first DSML tag to the end of the last one is markup. A block cut off mid-way leaves
        // only markup and argument text after its first tag, so it is dropped to the end of the reply.
        let last = tags[tags.count - 1]
        let isTruncated = invokeName != nil || parameter != nil
        let end = isTruncated ? text.endIndex : last.range.upperBound
        let before = text[..<first.range.lowerBound]
        let after = text[end...]
        let visible = (before.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + after.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(text: visible, calls: calls)
    }

    /// Removes DSML markup from text without producing calls, e.g. for history that will be sent back to a model.
    static func strip(_ text: String) -> String {
        extract(from: text)?.text ?? text
    }

    /// Moves DSML calls in an assistant message into `tool_calls`. Structured calls from the provider win: when
    /// the message already has them, the markup is only removed. Calls are only produced when the request offered
    /// tools, because a reply to a tool-less request has nowhere to send them.
    static func normalize(_ message: APIMessage, toolsOffered: Bool) -> APIMessage {
        guard let content = message.content, let extraction = extract(from: content) else { return message }
        var result = message
        result.content = extraction.text.isEmpty ? nil : extraction.text
        if toolsOffered, (message.tool_calls ?? []).isEmpty, !extraction.calls.isEmpty {
            result.tool_calls = extraction.calls
        }
        return result
    }

    private static func scanTags(in text: String) -> [Tag] {
        let ns = NSRange(text.startIndex..., in: text)
        return tagPattern.matches(in: text, range: ns).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let slash = Range(match.range(at: 1), in: text),
                  let name = Range(match.range(at: 2), in: text),
                  let attrs = Range(match.range(at: 3), in: text) else { return nil }
            return Tag(closing: !text[slash].isEmpty, name: String(text[name]), attributes: attributes(in: String(text[attrs])), range: range)
        }
    }

    private static func attributes(in text: String) -> [String: String] {
        let ns = NSRange(text.startIndex..., in: text)
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: text, range: ns) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[key]).lowercased()] = String(text[value])
        }
        return result
    }

    /// `string="true"` values are taken as written; anything else is JSON (numbers, booleans, arrays, objects),
    /// falling back to the text when it does not parse.
    private static func value(_ raw: String, isString: Bool) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isString { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return parsed
        }
        return trimmed
    }

    private static func encode(_ arguments: [(String, Any)]) -> String {
        var object: [String: Any] = [:]
        for (key, value) in arguments { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Sits between a provider stream and the UI so DSML tool-call markup is never shown while it streams in.
/// Text before the markup passes through; from the first DSML tag on, nothing more is forwarded. A trailing
/// `<` that could be the start of a tag is held back until the next chunk shows what it is.
final class DSMLStreamFilter: @unchecked Sendable {
    private let lock = NSLock()
    private let downstream: TextDeltaHandler
    private var held = ""
    private var suppressed = false

    init(downstream: @escaping TextDeltaHandler) {
        self.downstream = downstream
    }

    var handler: TextDeltaHandler {
        { [self] delta in push(delta) }
    }

    func push(_ delta: String) {
        let out: String = lock.withLock {
            if suppressed { return "" }
            let text = held + delta
            if let marker = DSMLToolCalls.firstMarker(in: text) {
                suppressed = true
                held = ""
                return String(text[..<marker.lowerBound])
            }
            if let open = text.lastIndex(of: "<"), DSMLToolCalls.couldStartMarker(text[open...]) {
                held = String(text[open...])
                return String(text[..<open])
            }
            held = ""
            return text
        }
        if !out.isEmpty { downstream(out) }
    }
}
