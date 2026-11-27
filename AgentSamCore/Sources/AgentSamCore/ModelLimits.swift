import Foundation

/// How much conversation Ada may send to a model. Context windows differ by orders of magnitude
/// between models, so one fixed budget either wastes a large window or overflows a small one.
public enum ModelLimits {
    /// Window used for models not listed here; most current hosted models offer at least this.
    public static let defaultWindowTokens = 128_000
    /// Ada's own budget never exceeds this, however big the window: very long prompts cost more,
    /// answer slower, and models follow them less well.
    public static let maxBudgetTokens = 150_000
    public static let minBudgetTokens = 20_000

    /// The model's context window in tokens (best known value).
    public static func contextWindow(model: String) -> Int {
        let name = model.lowercased()
        let table: [(marker: String, tokens: Int)] = [
            ("claude", 200_000), ("gemini", 1_000_000), ("gpt-5", 400_000), ("gpt-4.1", 1_000_000),
            ("gpt-4o", 128_000), ("deepseek-v4", 1_000_000), ("deepseek-flash", 1_000_000), ("deepseek", 128_000), ("kimi", 256_000),
            ("glm", 128_000), ("qwen3", 128_000), ("gpt-oss", 128_000),
            ("llama-3", 128_000), ("llama3", 128_000), ("mixtral", 32_000),
        ]
        return table.first(where: { name.contains($0.marker) })?.tokens ?? defaultWindowTokens
    }

    /// Tokens of conversation to send: most of the window, leaving room for the system prompt,
    /// tool definitions and the reply, capped for cost and quality.
    public static func conversationBudget(model: String) -> Int {
        let window = contextWindow(model: model)
        return min(maxBudgetTokens, max(minBudgetTokens, window * 6 / 10))
    }
}

/// A model chosen to look at photos when they are attached, separate from the one Ada talks with.
public struct VisionModelSetting: Codable, Hashable, Sendable {
    public var providerID: String
    public var model: String

    public init(providerID: String, model: String) {
        self.providerID = providerID
        self.model = model
    }
}
