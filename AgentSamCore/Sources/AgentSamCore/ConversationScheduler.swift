import Foundation

/// Fires each conversation's recurring schedule when it comes due: the server, not Ada, wakes
/// the conversation. Each due prompt is sent through the normal `ConversationEngine.send` —
/// Ada receives it exactly as if the user had typed it (a user message flagged `scheduled`),
/// routes and runs it with her full tools, and her reply lands in the chat like any other.
///
/// The loop is deliberately lazy: a single ticker task wakes every 30 seconds, scans the store
/// for due schedules, dispatches one run per due conversation, and skips anything already
/// running. Persisted `nextRunAt` survives restarts; on boot, overdue schedules fire promptly
/// (one catch-up run each, no backlog pile-up).
public actor ConversationScheduler {
    public static let tickSeconds: TimeInterval = 30

    private let conversations: ConversationStore
    private let engine: ConversationEngine
    private var ticker: Task<Void, Never>?

    public init(conversations: ConversationStore, engine: ConversationEngine) {
        self.conversations = conversations
        self.engine = engine
    }

    public func start() {
        ensureTicker()
    }

    public func shutdown() async {
        ticker?.cancel()
        await ticker?.value
        ticker = nil
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
        guard let due = try? await conversations.dueSchedules(now: now) else { return }
        for item in due {
            // Mark first, dispatch second: a crash mid-run still counts as the run happening,
            // and `send` refusing (already running) leaves the schedule advanced — it fires
            // again next interval instead of retry-looping against a busy conversation.
            _ = try? await conversations.markScheduleRun(id: item.conversationID, ownerID: item.ownerID)
            _ = try? await engine.send(
                conversationID: item.conversationID,
                ownerID: item.ownerID,
                text: item.schedule.prompt,
                launchedBy: "Schedule",
                language: item.schedule.language,
                scheduled: true
            )
        }
    }
}
