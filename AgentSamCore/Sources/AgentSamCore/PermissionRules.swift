import Foundation

/// What happens when Ada calls a tool that changes something outside her workspace.
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    /// Show an approval card and wait for a person (the default for every write).
    case ask
    /// Run at once, as long as the rule's limits hold. Anything outside the limits falls back to `ask`.
    case allow
    /// Never run, and never ask.
    case never
}

/// A person's standing rule for one write tool, with optional limits that keep "allow" narrow.
public struct PermissionRule: Codable, Sendable, Equatable {
    public var mode: PermissionMode
    /// At most this many automatic runs per UTC day. Nil means no daily limit.
    public var maxPerDay: Int?
    /// `googleads_set_budget`: the largest daily budget, in account currency, that runs without asking.
    public var maxAmount: Double?
    /// `github_write_file`: only branches that start with this prefix run without asking (for example "claude/").
    public var branchPrefix: String?
    /// `gmail_send`: only these recipients (exact addresses, or "@domain.com") run without asking.
    public var allowedRecipients: [String]?

    public init(mode: PermissionMode, maxPerDay: Int? = nil, maxAmount: Double? = nil, branchPrefix: String? = nil, allowedRecipients: [String]? = nil) {
        self.mode = mode
        self.maxPerDay = maxPerDay
        self.maxAmount = maxAmount
        self.branchPrefix = branchPrefix
        self.allowedRecipients = allowedRecipients
    }

    /// Cleans what a client sent: drops empty or nonsensical limits.
    func normalized() -> PermissionRule {
        var rule = self
        if let max = rule.maxPerDay, max < 1 { rule.maxPerDay = nil }
        if let max = rule.maxPerDay { rule.maxPerDay = min(max, 1_000) }
        if let amount = rule.maxAmount, !(amount.isFinite && amount > 0) { rule.maxAmount = nil }
        rule.branchPrefix = rule.branchPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.branchPrefix?.isEmpty == true { rule.branchPrefix = nil }
        let recipients = (rule.allowedRecipients ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        rule.allowedRecipients = recipients.isEmpty ? nil : Array(recipients.prefix(50))
        return rule
    }
}

/// One owner's standing permissions.
public struct PermissionPolicy: Codable, Sendable, Equatable {
    /// "Pause all": every rule acts as `ask` until this is turned off. `never` rules still refuse.
    public var paused: Bool
    /// Rules keyed by tool name. A tool without a rule is `ask`.
    public var rules: [String: PermissionRule]
    /// How long an approval card stays open, in minutes (15 to 1,440).
    public var approvalMinutes: Int
    /// Estimated model spend, in US dollars, after which Ada stops starting new replies for the UTC day.
    public var dailySpendCapUSD: Double?
    /// Estimated model spend, in US dollars, after which one reply stops using tools and wraps up.
    public var replySpendCapUSD: Double?

    public static let defaultApprovalMinutes = 15
    public static let allowedApprovalMinutes = [15, 60, 240, 720, 1_440]

    public init(paused: Bool = false, rules: [String: PermissionRule] = [:], approvalMinutes: Int = PermissionPolicy.defaultApprovalMinutes, dailySpendCapUSD: Double? = nil, replySpendCapUSD: Double? = nil) {
        self.paused = paused
        self.rules = rules
        self.approvalMinutes = approvalMinutes
        self.dailySpendCapUSD = dailySpendCapUSD
        self.replySpendCapUSD = replySpendCapUSD
    }

    enum CodingKeys: String, CodingKey { case paused, rules, approvalMinutes, dailySpendCapUSD, replySpendCapUSD }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        rules = try container.decodeIfPresent([String: PermissionRule].self, forKey: .rules) ?? [:]
        approvalMinutes = try container.decodeIfPresent(Int.self, forKey: .approvalMinutes) ?? Self.defaultApprovalMinutes
        dailySpendCapUSD = try container.decodeIfPresent(Double.self, forKey: .dailySpendCapUSD)
        replySpendCapUSD = try container.decodeIfPresent(Double.self, forKey: .replySpendCapUSD)
    }

    /// Keeps only rules for tools that can have one, with clean limits.
    func normalized() -> PermissionPolicy {
        var policy = self
        policy.rules = rules.filter { PermissionStore.ruleTools.contains($0.key) }.mapValues { $0.normalized() }
        if !Self.allowedApprovalMinutes.contains(policy.approvalMinutes) { policy.approvalMinutes = Self.defaultApprovalMinutes }
        if let cap = policy.dailySpendCapUSD, !(cap.isFinite && cap > 0) { policy.dailySpendCapUSD = nil }
        if let cap = policy.replySpendCapUSD, !(cap.isFinite && cap > 0) { policy.replySpendCapUSD = nil }
        return policy
    }
}

/// The result of checking a write against the owner's rules.
public enum PermissionDecision: Sendable, Equatable {
    /// Run now without a card. The string says which rule allowed it, for the audit log.
    case allow(String)
    /// Show an approval card. The string is why, when a rule was set but a limit did not hold (nil for the default).
    case ask(String?)
    /// Refuse without asking.
    case deny(String)
}

/// Owner-scoped standing permissions for Ada's write tools, with daily usage counts.
public actor PermissionStore {
    /// The tools a rule can be set for: every connector write in the tool catalog. File deletion
    /// keeps its one-use card.
    public static let ruleTools: Set<String> = Set(
        ToolCatalog.specs.filter { $0.access == .approval && !$0.name.hasSuffix("_delete_file") }.map(\.name)
    )

    private struct Usage: Codable {
        var day: String
        var counts: [String: Int]
    }

    private let directory: URL
    private let audit: AccessAuditLog?
    private let now: @Sendable () -> Date

    public init(root: URL, audit: AccessAuditLog? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        directory = root.appendingPathComponent("permissions", isDirectory: true)
        self.audit = audit
        self.now = now
    }

    public func policy(ownerID: String) -> PermissionPolicy {
        guard let data = try? Data(contentsOf: policyURL(ownerID)),
              let policy = try? JSONDecoder().decode(PermissionPolicy.self, from: data) else { return PermissionPolicy() }
        return policy.normalized()
    }

    @discardableResult
    public func save(ownerID: String, policy: PermissionPolicy) -> PermissionPolicy {
        let clean = policy.normalized()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(clean) {
            try? data.write(to: policyURL(ownerID), options: .atomic)
        }
        var summary = clean.rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.mode.rawValue)" }.joined(separator: ", ")
        if summary.isEmpty { summary = "all ask" }
        if let cap = clean.dailySpendCapUSD { summary += "; daily cap $\(cap)" }
        if let cap = clean.replySpendCapUSD { summary += "; reply cap $\(cap)" }
        Task { [audit, summary] in await audit?.record(ownerID: ownerID, action: "permissions.updated", detail: "paused=\(clean.paused); \(summary)") }
        return clean
    }

    /// How long a new approval card for this owner stays open.
    public func approvalLifetime(ownerID: String) -> TimeInterval {
        TimeInterval(policy(ownerID: ownerID).approvalMinutes * 60)
    }

    /// Checks one call against the owner's rules. An `.allow` is counted toward today's limit at
    /// once, in the same actor step, so parallel calls cannot both slip under the limit.
    public func decide(ownerID: String, toolName: String, arguments: [String: JSONValue]) -> PermissionDecision {
        let policy = policy(ownerID: ownerID)
        guard let rule = policy.rules[toolName] else { return .ask(nil) }
        switch rule.mode {
        case .ask:
            return .ask(nil)
        case .never:
            return .deny("Your permission settings never allow \(toolName). Nothing was sent or changed, and no approval was requested.")
        case .allow:
            if policy.paused { return .ask("Automatic actions are paused, so this needs your approval.") }
            if let max = rule.maxPerDay, (usageToday(ownerID: ownerID)[toolName] ?? 0) >= max {
                return .ask("The daily limit of \(max) automatic \(toolName) runs is used up, so this one needs your approval.")
            }
            if let reason = Self.limitFailure(rule: rule, toolName: toolName, arguments: arguments) {
                return .ask(reason)
            }
            recordAutomaticRun(ownerID: ownerID, toolName: toolName)
            return .allow("allowed by your \(toolName) rule")
        }
    }

    /// Counts one automatic run toward today's limit and writes it to the audit log.
    private func recordAutomaticRun(ownerID: String, toolName: String) {
        var current = loadUsage(ownerID: ownerID)
        let today = Self.dayKey(now())
        if current.day != today { current = Usage(day: today, counts: [:]) }
        current.counts[toolName, default: 0] += 1
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: usageURL(ownerID), options: .atomic)
        }
        Task { [audit] in await audit?.record(ownerID: ownerID, action: "permissions.auto_run", detail: toolName) }
    }

    /// Automatic runs of each tool so far today.
    public func usageToday(ownerID: String) -> [String: Int] {
        let current = loadUsage(ownerID: ownerID)
        return current.day == Self.dayKey(now()) ? current.counts : [:]
    }

    // MARK: Limits

    static func limitFailure(rule: PermissionRule, toolName: String, arguments: [String: JSONValue]) -> String? {
        if let maxAmount = rule.maxAmount, toolName == "googleads_set_budget" {
            let amount = arguments["amount"]?.numberValue ?? arguments["amount"]?.stringValue.flatMap(Double.init)
            guard let amount, amount <= maxAmount else {
                return "This budget is above the \(Self.format(maxAmount)) a day your rule allows, so it needs your approval."
            }
        }
        if let prefix = rule.branchPrefix, toolName == "github_write_file" {
            let branch = arguments["branch"]?.stringValue ?? ""
            guard branch.hasPrefix(prefix) else {
                return "Your rule only allows automatic commits to branches starting with \(prefix), so this one needs your approval."
            }
        }
        if let recipients = rule.allowedRecipients, toolName == "gmail_send" {
            let to = (arguments["to"]?.stringValue ?? "").split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let ok = !to.isEmpty && to.allSatisfy { address in
                recipients.contains { $0.hasPrefix("@") ? address.hasSuffix($0) : address == $0 }
            }
            guard ok else { return "Your rule only sends automatically to approved recipients, so this email needs your approval." }
        }
        return nil
    }

    private static func format(_ amount: Double) -> String {
        amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2f", amount)
    }

    // MARK: Storage

    private func policyURL(_ ownerID: String) -> URL {
        directory.appendingPathComponent("\(Self.safe(ownerID)).json")
    }

    private func usageURL(_ ownerID: String) -> URL {
        directory.appendingPathComponent("\(Self.safe(ownerID)).usage.json")
    }

    private func loadUsage(ownerID: String) -> Usage {
        guard let data = try? Data(contentsOf: usageURL(ownerID)),
              let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return Usage(day: Self.dayKey(now()), counts: [:]) }
        return usage
    }

    /// Base64url of the owner ID, like the other owner-scoped stores, so different IDs never share a file.
    static func safe(_ ownerID: String) -> String {
        Data(ownerID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
