import Foundation

/// Where the engine writes its operational log lines (model calls, pricing warnings). The server
/// points this at its own logger; with nothing set, lines go to standard error.
public enum EngineLog {
    public enum Level: String, Sendable {
        case info
        case warning
    }

    public typealias Sink = @Sendable (_ level: Level, _ line: String) -> Void

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: Sink?

        func get() -> Sink? {
            lock.lock(); defer { lock.unlock() }
            return sink
        }

        func set(_ new: Sink?) {
            lock.lock(); sink = new; lock.unlock()
        }
    }

    private static let state = State()

    /// Sends every later line to `sink`. Pass nil to go back to standard error.
    public static func setSink(_ sink: Sink?) {
        state.set(sink)
    }

    public static func write(_ level: Level, _ line: String) {
        if let sink = state.get() {
            sink(level, line)
        } else {
            FileHandle.standardError.write(Data("[\(level.rawValue)] \(line)\n".utf8))
        }
    }
}
