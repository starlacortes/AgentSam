import Foundation

/// What one model costs, in US dollars per million tokens.
public struct ModelPrice: Sendable, Equatable {
    public var input: Double
    /// Input the provider served from its prompt cache. Nil means cached input is charged as fresh input.
    public var cachedInput: Double?
    public var output: Double
    /// The rates above are peak rates, and the provider charges half outside its peak hours (DeepSeek).
    public var halfOffPeak: Bool

    public init(input: Double, cachedInput: Double? = nil, output: Double, halfOffPeak: Bool = false) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.halfOffPeak = halfOffPeak
    }
}

/// Estimated cost of model calls. The spending limits and the per-call log both read from here,
/// so a model that is missing from the table must never count as free.
public enum Pricing {
    /// Prices by a marker found in the model name. Where two markers match, the longer one wins.
    public static let table: [String: ModelPrice] = [
        // Anthropic. Cache reads cost a tenth of fresh input.
        "claude-opus-4-5": ModelPrice(input: 5, cachedInput: 0.5, output: 25),
        "claude-sonnet-4-5": ModelPrice(input: 3, cachedInput: 0.3, output: 15),
        "claude-sonnet-4.5": ModelPrice(input: 3, cachedInput: 0.3, output: 15),
        "claude-haiku-4-5": ModelPrice(input: 1, cachedInput: 0.1, output: 5),
        "claude-opus-4-1": ModelPrice(input: 15, cachedInput: 1.5, output: 75),
        "claude-sonnet-4": ModelPrice(input: 3, cachedInput: 0.3, output: 15),
        "claude-3-5-haiku": ModelPrice(input: 0.8, cachedInput: 0.08, output: 4),
        // OpenAI.
        "gpt-5.2": ModelPrice(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-5.2-mini": ModelPrice(input: 0.25, cachedInput: 0.025, output: 2),
        "gpt-5": ModelPrice(input: 1.25, cachedInput: 0.125, output: 10),
        "gpt-4o": ModelPrice(input: 2.5, cachedInput: 1.25, output: 10),
        "gpt-4o-mini": ModelPrice(input: 0.15, cachedInput: 0.075, output: 0.6),
        // DeepSeek, from api-docs.deepseek.com/quick_start/pricing on 2026-11-27. These are the peak
        // rates; off-peak is half. The older v4-flash names are served and billed as deepseek-flash.
        "deepseek-v4-pro": ModelPrice(input: 1.32, cachedInput: 0.044, output: 3.96, halfOffPeak: true),
        "deepseek-flash": ModelPrice(input: 0.3, cachedInput: 0.006, output: 1.2, halfOffPeak: true),
        "deepseek-v4-flash": ModelPrice(input: 0.3, cachedInput: 0.006, output: 1.2, halfOffPeak: true),
        // No longer on DeepSeek's price list; kept at their last listed prices.
        "deepseek-chat": ModelPrice(input: 0.27, output: 1.1),
        "deepseek-reasoner": ModelPrice(input: 0.55, output: 2.19),
        // GreenPT (EU endpoint), from docs.greenpt.ai/pricing on 2026-11-27. Listed in euros and
        // counted here at 1.20 dollars to the euro, rounded up so the estimate stays on the high side.
        "glm-5.3": ModelPrice(input: 1.32, cachedInput: 0.33, output: 5.28),
        "glm-5.3-flash": ModelPrice(input: 0.14, cachedInput: 0.03, output: 0.53),
        "deepseek-v4.1-flash": ModelPrice(input: 0.44, cachedInput: 0.05, output: 1.74),
        "kimi-k3": ModelPrice(input: 3.96, cachedInput: 0.99, output: 19.8),
        // Others.
        "gemini-3-pro": ModelPrice(input: 2, output: 12),
        "llama-3.3-70b": ModelPrice(input: 0.59, output: 0.79),
        "mixtral-8x7b": ModelPrice(input: 0.24, output: 0.24),
    ]

    /// Used for a model with no entry in the table: priced like the dearest current default model,
    /// so the spending limits still stop a new or mistyped model.
    public static let fallback = ModelPrice(input: 5, output: 25)

    private static let markers: [(marker: String, price: ModelPrice)] = table
        .map { (marker: $0.key, price: $0.value) }
        .sorted { $0.marker.count != $1.marker.count ? $0.marker.count > $1.marker.count : $0.marker < $1.marker }

    /// The table's price for a model, or nil when the model is not listed.
    public static func price(for model: String) -> ModelPrice? {
        let lowered = model.lowercased()
        return markers.first(where: { lowered.contains($0.marker) })?.price
    }

    /// Estimated cost in US dollars. `cachedInputTokens` is the part of `inputTokens` served from the
    /// provider's cache. An unlisted model counts at the fallback price, except on a provider that
    /// runs on this machine (`local`), which is free.
    public static func estimate(model: String, inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0, local: Bool = false, at date: Date = Date()) -> Double {
        let price: ModelPrice
        if let listed = Self.price(for: model) {
            price = listed
        } else if local {
            return 0
        } else {
            price = fallback
            warnUnpriced(model)
        }
        let cached = min(max(cachedInputTokens, 0), max(inputTokens, 0))
        let fresh = max(inputTokens, 0) - cached
        let usd = Double(fresh) / 1_000_000 * price.input
            + Double(cached) / 1_000_000 * (price.cachedInput ?? price.input)
            + Double(max(outputTokens, 0)) / 1_000_000 * price.output
        return price.halfOffPeak && !isDeepSeekPeak(date) ? usd / 2 : usd
    }

    /// DeepSeek's peak hours: 01:00 to 04:00 and 06:00 to 10:00 UTC, Monday to Friday. Chinese public
    /// holidays are off-peak too, but are not tracked here, so those days are counted at the peak rate.
    public static func isDeepSeekPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, (2...6).contains(weekday) else { return false }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    private static let warned = WarnedModels()

    /// Says once per model that it has no price, so the table can be completed.
    private static func warnUnpriced(_ model: String) {
        guard warned.insert(model) else { return }
        EngineLog.write(.warning, "pricing: no price for model \"\(model)\"; counting it at the fallback of $\(fallback.input) in and $\(fallback.output) out per million tokens")
    }

    private final class WarnedModels: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []

        func insert(_ model: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return seen.insert(model).inserted
        }
    }
}
