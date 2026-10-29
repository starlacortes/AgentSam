import Foundation

public indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(pairs, uniquingKeysWith: { a, _ in a }))
    }
    public static func emptyObject() -> JSONValue { .object([:]) }
    public static func str(_ s: String) -> JSONValue { .string(s) }
    public static func optStr(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    public static func int(_ i: Int) -> JSONValue { .number(Double(i)) }
}

public struct APIToolCall: Codable, Hashable, Sendable {
    public struct Function: Codable, Hashable, Sendable {
        public var name: String
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var id: String
    public var type: String?
    public var function: Function

    public init(id: String, function: Function, type: String? = "function") {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct APIMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String?
    public var tool_calls: [APIToolCall]?
    public var tool_call_id: String?

    public init(role: String, content: String? = nil, tool_calls: [APIToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    public static func system(_ text: String) -> APIMessage { .init(role: "system", content: text) }
    public static func user(_ text: String) -> APIMessage { .init(role: "user", content: text) }
    public static func assistant(_ text: String) -> APIMessage { .init(role: "assistant", content: text) }
    public static func tool(id: String, content: String) -> APIMessage {
        .init(role: "tool", content: content, tool_call_id: id)
    }
}

public struct APIToolDef: Encodable, Hashable, Sendable {
    public struct Function: Encodable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var parameters: JSONValue

        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public var type: String
    public var function: Function

    public init(name: String, description: String, parameters: JSONValue) {
        self.type = "function"
        self.function = .init(name: name, description: description, parameters: parameters)
    }
}

public struct LLMError: Error, Sendable {
    public var message: String
    public var statusCode: Int?
    public var isContextOverflow: Bool

    public init(message: String, statusCode: Int? = nil, isContextOverflow: Bool = false) {
        self.message = message
        self.statusCode = statusCode
        self.isContextOverflow = isContextOverflow
    }
}

public struct LLMReply: Sendable {
    public var message: APIMessage
    public var inputTokens: Int
    public var outputTokens: Int
    public var model: String

    public init(message: APIMessage, inputTokens: Int, outputTokens: Int, model: String) {
        self.message = message
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
    }
}

public enum Pricing {
    public static let perMillionTokens: [String: (input: Double, output: Double)] = [
        "claude-opus-4-5": (5, 25),
        "claude-sonnet-4-5": (3, 15),
        "claude-haiku-4-5": (0.8, 4),
        "claude-opus-4-1": (15, 75),
        "claude-sonnet-4": (3, 15),
        "claude-3-5-haiku": (0.8, 4),
        "gpt-5.2": (1.25, 10),
        "gpt-5.2-mini": (0.25, 2),
        "gpt-5": (1.25, 10),
        "gpt-4o": (2.5, 10),
        "gpt-4o-mini": (0.15, 0.6),
        "deepseek-chat": (0.27, 1.1),
        "deepseek-reasoner": (0.55, 2.19),
        "llama-3.3-70b": (0.59, 0.79),
    ]

    public static func estimate(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let lowered = model.lowercased()
        for (prefix, price) in perMillionTokens.sorted(by: { $0.key.count > $1.key.count }) {
            if lowered.contains(prefix) {
                return Double(inputTokens) / 1_000_000 * price.input
                    + Double(outputTokens) / 1_000_000 * price.output
            }
        }
        return 0
    }
}
