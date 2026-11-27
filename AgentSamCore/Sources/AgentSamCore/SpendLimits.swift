import Foundation

/// Estimated model spend for one reply, carried as a task-local so every model call made for that
/// reply (routing, tool rounds, consolidation) adds to the same total.
public final class CostMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    public init() {}

    public var total: Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func add(_ usd: Double) {
        guard usd.isFinite, usd > 0 else { return }
        lock.lock(); value += usd; lock.unlock()
    }

    /// Adds one model call. `local` is true for a provider that runs on this machine, where a model
    /// without a listed price is free. Returns the estimated cost of the call.
    @discardableResult
    public func add(_ reply: LLMReply, local: Bool = false) -> Double {
        let usd = Pricing.estimate(model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cachedInputTokens: reply.cachedInputTokens, local: local)
        add(usd)
        return usd
    }

    @TaskLocal public static var current: CostMeter?
}

/// Owner-scoped estimated spend per UTC day, for the daily spending cap.
public actor SpendLedger {
    private struct Day: Codable {
        var day: String
        var usd: Double
    }

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        directory = root.appendingPathComponent("permissions", isDirectory: true)
        self.now = now
    }

    /// Estimated spend so far today (UTC), in US dollars.
    public func today(ownerID: String) -> Double {
        let current = load(ownerID)
        return current.day == PermissionStore.dayKey(now()) ? current.usd : 0
    }

    public func add(ownerID: String, usd: Double) {
        guard usd.isFinite, usd > 0 else { return }
        var current = load(ownerID)
        let day = PermissionStore.dayKey(now())
        if current.day != day { current = Day(day: day, usd: 0) }
        current.usd += usd
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: url(ownerID), options: .atomic)
        }
    }

    private func url(_ ownerID: String) -> URL {
        directory.appendingPathComponent("\(PermissionStore.safe(ownerID)).spend.json")
    }

    private func load(_ ownerID: String) -> Day {
        guard let data = try? Data(contentsOf: url(ownerID)), let day = try? JSONDecoder().decode(Day.self, from: data) else {
            return Day(day: PermissionStore.dayKey(now()), usd: 0)
        }
        return day
    }
}
