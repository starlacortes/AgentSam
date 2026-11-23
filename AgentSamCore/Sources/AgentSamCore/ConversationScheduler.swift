import Foundation

/// Fires each conversation's recurring schedule when it comes due, and its triggers when
/// something happens: the server, not Ada, wakes the conversation. Each run is sent through the
/// normal `ConversationEngine.send` — Ada receives it exactly as if the user had typed it (a
/// user message flagged `scheduled`), routes and runs it with her full tools, and her reply
/// lands in the chat like any other. A trigger's run also carries what happened as event data.
///
/// The loop is deliberately lazy: a single ticker task wakes every 30 seconds, scans the store
/// for due schedules, dispatches one run per due conversation, and skips anything already
/// running. Persisted `nextRunAt` survives restarts; on boot, overdue schedules fire promptly
/// (one catch-up run each, no backlog pile-up). Gmail triggers are checked every five minutes.
///
/// Every run's outcome is recorded once it finishes: a schedule or trigger that fails
/// `pauseAfterFailures` times in a row pauses itself until the person resumes it.
public actor ConversationScheduler {
    public static let tickSeconds: TimeInterval = 30

    /// Looks up recent emails for a Gmail search. Details are only needed for IDs not in the
    /// seen set; nil means this is the first check. Throws when Gmail isn't connected.
    public typealias GmailSearch = @Sendable (_ query: String, _ seen: Set<String>?) async throws -> [TriggerEmail]

    private let conversations: ConversationStore
    private let engine: ConversationEngine
    private let gmail: GmailSearch?
    private var ticker: Task<Void, Never>?
    private var outcomes: [UUID: Task<Void, Never>] = [:]
    /// Expired archives are swept at most this often (and on the first tick after boot).
    public static let archivePurgeSeconds: TimeInterval = 3_600
    private var lastArchivePurge: Date?

    /// Whether an owner may use the server's shared Gmail; triggers of other owners are skipped.
    private let mayUseGmail: (@Sendable (String) async -> Bool)?

    public init(conversations: ConversationStore, engine: ConversationEngine, mayUseGmail: (@Sendable (String) async -> Bool)? = nil, gmail: GmailSearch? = nil) {
        self.mayUseGmail = mayUseGmail
        self.conversations = conversations
        self.engine = engine
        self.gmail = gmail
    }

    public func start() {
        ensureTicker()
    }

    public func shutdown() async {
        ticker?.cancel()
        await ticker?.value
        ticker = nil
        for task in outcomes.values { task.cancel() }
        outcomes = [:]
    }

    /// Waits until every run this scheduler started has finished and its outcome is recorded. For tests.
    public func settle() async {
        // Each task removes itself from `outcomes` before it ends.
        while let task = outcomes.values.first { await task.value }
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                await tick()
            } catch is CancellationError {
                return
            } catch {
                // A failed tick (disk error, engine refusal) must not stop the loop.
            }
        }
    }

    /// One scan-and-dispatch pass, public for tests: due schedules fire, not-due ones don't,
    /// and already-running conversations are left alone.
    public func tick(now: Date = Date()) async {
        if lastArchivePurge.map({ now.timeIntervalSince($0) >= Self.archivePurgeSeconds }) ?? true {
            lastArchivePurge = now
            _ = try? await conversations.purgeExpiredArchives(now: now)
        }
        if let due = try? await conversations.dueSchedules(now: now) {
            for item in due {
                // Mark first, dispatch second: a crash mid-run still counts as the run happening,
                // and `send` refusing (already running) leaves the schedule advanced — it fires
                // again next interval instead of retry-looping against a busy conversation.
                _ = try? await conversations.markScheduleRun(id: item.conversationID, ownerID: item.ownerID, now: now)
                guard let sent = try? await engine.send(
                    conversationID: item.conversationID,
                    ownerID: item.ownerID,
                    text: item.schedule.prompt,
                    launchedBy: "Schedule",
                    language: item.schedule.language,
                    scheduled: true
                ), let responseID = sent.messages.last?.id else { continue }
                follow(conversationID: item.conversationID, ownerID: item.ownerID, responseID: responseID) { conversations, succeeded in
                    _ = try? await conversations.recordScheduleOutcome(id: item.conversationID, ownerID: item.ownerID, succeeded: succeeded)
                }
            }
        }
        await checkGmail(now: now)
    }

    // MARK: Triggers

    public enum FireResult: Equatable, Sendable {
        case started
        case busy
        case rateLimited
        case paused
        case notFound
    }

    /// Starts a trigger's run with `event` attached. The webhook route and the Gmail check call this.
    public func fire(conversationID: UUID, ownerID: String, triggerID: UUID, data: String, now: Date = Date()) async -> FireResult {
        guard let conversation = try? await conversations.get(id: conversationID, ownerID: ownerID),
              conversation.archivedAt == nil,
              let trigger = conversation.triggers.first(where: { $0.id == triggerID }) else { return .notFound }
        if trigger.isPaused { return .paused }
        guard trigger.canFire(now: now) else { return .rateLimited }
        let event = TriggerEvent(triggerID: trigger.id, kind: trigger.kind, data: data)
        let sent: Conversation
        do {
            sent = try await engine.send(
                conversationID: conversationID,
                ownerID: ownerID,
                text: trigger.prompt,
                launchedBy: "Trigger",
                language: trigger.language,
                scheduled: true,
                trigger: event
            )
        } catch ConversationError.alreadyRunning {
            return .busy
        } catch {
            return .notFound
        }
        _ = try? await conversations.updateTrigger(id: conversationID, ownerID: ownerID, triggerID: triggerID) { $0.recordFire(now: now) }
        if let responseID = sent.messages.last?.id {
            follow(conversationID: conversationID, ownerID: ownerID, responseID: responseID) { conversations, succeeded in
                _ = try? await conversations.updateTrigger(id: conversationID, ownerID: ownerID, triggerID: triggerID) { $0.recordOutcome(succeeded: succeeded, now: Date()) }
            }
        }
        return .started
    }

    /// Looks for new mail for each Gmail trigger that is due a check. The first check of a
    /// trigger only records what is already there. New mail that can't run yet (the chat is busy
    /// or hit its hourly limit) stays unseen and is picked up by a later check.
    public func checkGmail(now: Date = Date()) async {
        guard let gmail, let triggers = try? await conversations.gmailTriggers() else { return }
        for item in triggers {
            let trigger = item.trigger
            if let mayUseGmail, !(await mayUseGmail(item.ownerID)) { continue }
            if let last = trigger.lastCheckedAt, now.timeIntervalSince(last) < ConversationTrigger.gmailPollSeconds { continue }
            guard let query = trigger.query, let emails = try? await gmail(query, trigger.seenIDs.map(Set.init)) else { continue }
            guard let seen = trigger.seenIDs else {
                _ = try? await conversations.updateTrigger(id: item.conversationID, ownerID: item.ownerID, triggerID: trigger.id) {
                    $0.seenIDs = Array(emails.map(\.id).prefix(ConversationTrigger.maxSeenIDs))
                    $0.lastCheckedAt = now
                }
                continue
            }
            let known = Set(seen)
            let fresh = emails.filter { !known.contains($0.id) }
            var result: FireResult?
            if !fresh.isEmpty {
                result = await fire(conversationID: item.conversationID, ownerID: item.ownerID, triggerID: trigger.id, data: Self.describe(fresh), now: now)
            }
            _ = try? await conversations.updateTrigger(id: item.conversationID, ownerID: item.ownerID, triggerID: trigger.id) {
                $0.lastCheckedAt = now
                if result == .started {
                    $0.seenIDs = Array((fresh.map(\.id) + seen).prefix(ConversationTrigger.maxSeenIDs))
                }
            }
        }
    }

    static func describe(_ emails: [TriggerEmail]) -> String {
        let shown = emails.prefix(10)
        var lines = ["\(emails.count) new email\(emails.count == 1 ? "" : "s") matched (read one with gmail_read and its message ID):"]
        for email in shown {
            lines.append("- ID \(email.id) | From: \(email.from.prefix(200)) | Subject: \(email.subject.prefix(300)) | \(email.snippet.prefix(400))")
        }
        if emails.count > shown.count { lines.append("…and \(emails.count - shown.count) more.") }
        return lines.joined(separator: "\n")
    }

    /// Records the outcome of a run once Ada's reply finishes.
    private func follow(conversationID: UUID, ownerID: String, responseID: UUID, record: @escaping @Sendable (ConversationStore, Bool) async -> Void) {
        let engine = engine
        let conversations = conversations
        let key = UUID()
        outcomes[key] = Task {
            let status = await engine.waitForReply(conversationID: conversationID, ownerID: ownerID, responseID: responseID)
            if !Task.isCancelled, let status { await record(conversations, status == .complete) }
            await self.forget(key)
        }
    }

    private func forget(_ key: UUID) { outcomes[key] = nil }
}
