import Foundation
import XCTest
@testable import AgentSamCore

final class PricingTests: XCTestCase {
    /// A Thursday at 02:30 UTC (peak) and the same day at 12:00 UTC (off-peak).
    private let peak = Date(timeIntervalSince1970: 1_795_660_200)
    private let offPeak = Date(timeIntervalSince1970: 1_795_694_400)

    override func tearDown() {
        EngineLog.setSink(nil)
        super.tearDown()
    }

    func testEveryModelABuiltInProviderOffersHasAPrice() {
        for provider in ProviderConfig.builtin where !provider.isLocal {
            for model in provider.models + [provider.defaultModel].compactMap({ $0 }) {
                XCTAssertNotNil(Pricing.price(for: model), "\(provider.id) offers \(model), which has no price in Pricing.table")
            }
        }
        for template in AgentProfile.rosterTemplates {
            XCTAssertNotNil(Pricing.price(for: template.model), "\(template.name) defaults to \(template.model), which has no price")
        }
    }

    func testOnlyTheLocalProviderIsLocal() {
        XCTAssertEqual(ProviderConfig.builtin.filter(\.isLocal).map(\.id), ["ollama"])
    }

    func testDeepSeekPeakHours() {
        XCTAssertTrue(Pricing.isDeepSeekPeak(peak))
        XCTAssertFalse(Pricing.isDeepSeekPeak(offPeak))
        // 04:00 to 06:00 UTC sits between the two peak windows.
        XCTAssertFalse(Pricing.isDeepSeekPeak(peak.addingTimeInterval(2 * 3600)))
        XCTAssertTrue(Pricing.isDeepSeekPeak(peak.addingTimeInterval(4 * 3600)))
        // The same hour on the Sunday after is off-peak.
        XCTAssertFalse(Pricing.isDeepSeekPeak(peak.addingTimeInterval(3 * 86_400)))
    }

    func testDeepSeekProIsPricedWithCacheHitsAndOffPeakHalf() {
        // 1M fresh input, 1M cached input, 1M output at peak: 1.32 + 0.044 + 3.96.
        let atPeak = Pricing.estimate(model: "deepseek-v4-pro", inputTokens: 2_000_000, outputTokens: 1_000_000, cachedInputTokens: 1_000_000, at: peak)
        XCTAssertEqual(atPeak, 5.324, accuracy: 0.0001)
        let later = Pricing.estimate(model: "deepseek-v4-pro", inputTokens: 2_000_000, outputTokens: 1_000_000, cachedInputTokens: 1_000_000, at: offPeak)
        XCTAssertEqual(later, 2.662, accuracy: 0.0001)
        XCTAssertEqual(Pricing.estimate(model: "deepseek-flash", inputTokens: 1_000_000, outputTokens: 1_000_000, at: peak), 1.5, accuracy: 0.0001)
    }

    func testLongerMarkerWins() {
        XCTAssertEqual(Pricing.price(for: "gpt-5.2-mini")?.input, 0.25)
        XCTAssertEqual(Pricing.price(for: "gpt-4o-mini-2024")?.input, 0.15)
        XCTAssertEqual(Pricing.price(for: "glm-5.3-flash")?.input, 0.14)
        XCTAssertEqual(Pricing.price(for: "anthropic/claude-sonnet-4.5")?.output, 15)
        // GreenPT's own flash model is not DeepSeek's deepseek-flash.
        XCTAssertEqual(Pricing.price(for: "deepseek-v4.1-flash")?.input, 0.44)
        XCTAssertEqual(Pricing.price(for: "deepseek-v4.1-flash")?.halfOffPeak, false)
    }

    func testCachedInputWithoutACachePriceCostsFullInput() {
        let cost = Pricing.estimate(model: "llama-3.3-70b-versatile", inputTokens: 1_000_000, outputTokens: 0, cachedInputTokens: 600_000)
        XCTAssertEqual(cost, 0.59, accuracy: 0.0001)
    }

    func testCachedTokensNeverExceedInput() {
        let cost = Pricing.estimate(model: "claude-sonnet-4-5", inputTokens: 1_000_000, outputTokens: 0, cachedInputTokens: 5_000_000)
        XCTAssertEqual(cost, 0.3, accuracy: 0.0001)
    }

    func testUnknownModelCountsAtTheFallbackAndIsLoggedOnce() {
        let lines = LockedLines()
        EngineLog.setSink { level, line in lines.append("\(level.rawValue) \(line)") }
        let model = "brand-new-model-\(UUID().uuidString)"
        let cost = Pricing.estimate(model: model, inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(cost, Pricing.fallback.input + Pricing.fallback.output, accuracy: 0.0001)
        XCTAssertGreaterThan(Pricing.estimate(model: model, inputTokens: 1_000, outputTokens: 0), 0)
        let mine = lines.values.filter { $0.contains(model) }
        XCTAssertEqual(mine.count, 1, mine.joined(separator: "\n"))
        XCTAssertTrue(mine.first?.hasPrefix("warning pricing: no price") == true, mine.first ?? "")
    }

    func testUnknownModelOnALocalProviderIsFree() {
        XCTAssertEqual(Pricing.estimate(model: "my-own-model", inputTokens: 1_000_000, outputTokens: 1_000_000, local: true), 0)
        // A listed model keeps its price even behind a local address (a proxy, for example).
        XCTAssertGreaterThan(Pricing.estimate(model: "claude-sonnet-4-5", inputTokens: 1_000_000, outputTokens: 0, local: true), 0)
    }

    func testCostMeterCountsCachedInputAtTheCachePrice() {
        let meter = CostMeter()
        let reply = LLMReply(message: .assistant("ok"), inputTokens: 1_000_000, outputTokens: 0, model: "claude-sonnet-4-5", cachedInputTokens: 1_000_000)
        XCTAssertEqual(meter.add(reply), 0.3, accuracy: 0.0001)
        XCTAssertEqual(meter.total, 0.3, accuracy: 0.0001)
    }

    private final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }
}
