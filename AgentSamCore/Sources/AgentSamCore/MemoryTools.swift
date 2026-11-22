import Foundation

/// A fact Ada was explicitly asked to remember. Kept word for word, outside the compacted summary.
public struct PinnedMemory: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable { case ada, person }

    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var origin: Origin

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), origin: Origin) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.origin = origin
    }

    public static let maxCount = 100
    public static let maxLength = 500

    /// Cleans a fact, or returns why it cannot be saved.
    static func clean(_ raw: String) -> Result<String, MemoryEditError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maxLength else { return .failure(.tooLong) }
        guard !looksSecret(text) else { return .failure(.secret) }
        return .success(text)
    }

    /// Passwords, keys and tokens never go into memory, even when asked.
    static func looksSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let words = ["password", "passcode", "contraseña", "api key", "api_key", "apikey", "secret key", "private key", "access token", "bearer ", "otp code", "2fa code", "pin code"]
        if words.contains(where: { lowered.contains($0) }) { return true }
        let patterns = [#"sk-[A-Za-z0-9_\-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"AKIA[0-9A-Z]{16}"#, #"xox[abposr]-[A-Za-z0-9\-]{10,}"#, #"asam_[A-Za-z0-9_\-]{16,}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

public enum MemoryEditError: Error, Equatable, Sendable, LocalizedError {
    case empty, tooLong, secret, full, disabled

    public var errorDescription: String? {
        switch self {
        case .empty: "There is nothing to remember."
        case .tooLong: "A remembered fact can be at most \(PinnedMemory.maxLength) characters."
        case .secret: "That looks like a password, key or token. Ada never keeps secrets in memory."
        case .full: "Memory already holds \(PinnedMemory.maxCount) remembered facts. Forget some first."
        case .disabled: "Workspace memory is turned off in Settings, so nothing was remembered."
        }
    }
}

/// What a forget removed.
public struct MemoryForgetResult: Codable, Sendable, Equatable {
    public var pinnedRemoved: Int
    public var summaryLinesRemoved: Int
    public var pendingRemoved: Int

    public var total: Int { pinnedRemoved + summaryLinesRemoved + pendingRemoved }
}

/// Ada's tools for remembering and forgetting on request.
public enum MemoryTools {
    public static let names: Set<String> = ["memory_remember", "memory_forget"]

    public static var definitions: [APIToolDef] {
        [
            APIToolDef(
                name: "memory_remember",
                description: """
                Remember one fact about the user or their work across all their chats, word for word: a \
                preference, a name, a standing detail ("my business is in Austin", "I prefer short replies"). \
                Use it when the user asks you to remember something, or states a lasting preference. Never store \
                passwords, keys, tokens or other secrets. For how to handle a kind of request, use skill_save instead.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("fact", .object([("type", .string("string")), ("description", .string("The fact, as one short sentence in the user's terms (at most 500 characters)."))])),
                    ])),
                    ("required", .array([.string("fact")])),
                ])
            ),
            APIToolDef(
                name: "memory_forget",
                description: """
                Forget what you remember about something, when the user asks you to forget it or says it is no \
                longer true. Removes remembered facts and summary lines that contain the given words. Say what \
                was removed.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("about", .object([("type", .string("string")), ("description", .string("Words that identify what to forget, e.g. a name or topic (at least 3 characters)."))])),
                    ])),
                    ("required", .array([.string("about")])),
                ])
            ),
        ]
    }

    public static func run(call: APIToolCall, memory: WorkspaceMemoryStore, ownerID: String?) async -> ToolOutcome {
        guard let ownerID else { return .failure("Memory needs a signed-in user; nothing was changed.") }
        let args = AgentTools.arguments(of: call)
        switch call.function.name {
        case "memory_remember":
            do {
                let pinned = try await memory.pin(ownerID: ownerID, text: args["fact"]?.stringValue ?? "", origin: .ada)
                return ToolOutcome(resultText: "Remembered: \(pinned.text)\nThe user can see and remove it in Settings > Memory & knowledge.")
            } catch let error as MemoryEditError {
                return .failure(error.errorDescription ?? "Nothing was remembered.")
            } catch {
                return .failure("Memory could not be saved; nothing was remembered.")
            }
        case "memory_forget":
            let about = (args["about"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard about.count >= 3 else { return .failure("Give at least 3 characters that identify what to forget.") }
            do {
                let result = try await memory.forget(ownerID: ownerID, matching: about)
                if result.total == 0 { return ToolOutcome(resultText: "Nothing in memory mentions \"\(about)\". Nothing was removed.") }
                return ToolOutcome(resultText: "Forgot \(result.pinnedRemoved) remembered fact(s), \(result.summaryLinesRemoved) summary line(s) and \(result.pendingRemoved) not-yet-summarized exchange(s) mentioning \"\(about)\".")
            } catch {
                return .failure("Memory could not be updated; nothing was removed.")
            }
        default:
            return .failure("Unknown memory tool.")
        }
    }
}
