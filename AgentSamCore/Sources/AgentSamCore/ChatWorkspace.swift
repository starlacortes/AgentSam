import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Storage

/// The chat's workspace: a per-conversation folder under the data root that Ada reads and writes
/// through the `chat_*` tools. Everything lands in `conversations/<uuid>/files/`, the same tree that
/// holds `conversations/<uuid>.json`, and paths are resolved with the same jail as mission
/// deliverables (`AgentTools.resolve`): relative paths only, no `..`, no absolute paths.
public actor ChatWorkspaceStore {
    public nonisolated let root: URL

    public init(root: URL) {
        self.root = root
    }

    public nonisolated func directory(_ conversationID: UUID) -> URL {
        root
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    /// Lists workspace files recursively, as relative paths, so nested writes like
    /// `site/index.html` are visible alongside flat ones. Sandbox scratch directories (`.run-*`)
    /// are skipped: they exist only while a program is running.
    public func files(conversationID: UUID) -> [String] {
        let base = directory(conversationID)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var names: [String] = []
        for item in items {
            if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory {
                let nested = Self.nestedFiles(in: item, relativeTo: base)
                names.append(contentsOf: nested)
            } else {
                names.append(item.lastPathComponent)
            }
        }
        return names.sorted()
    }

    public func manifest(conversationID: UUID) -> [String] {
        files(conversationID: conversationID).map { name in
            guard let url = AgentTools.resolve(name, in: directory(conversationID)),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return name }
            return "\(name) — \(size)"
        }
    }

    public func copyFiles(conversationID: UUID, to destination: URL) -> [String] {
        ScopedFiles.copy(from: directory(conversationID), to: destination)
    }

    public nonisolated func projectDirectory(_ scope: ProjectScope) -> URL {
        root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(Self.storageKey(scope.ownerID), isDirectory: true)
            .appendingPathComponent(Self.storageKey(scope.projectName.lowercased()), isDirectory: true)
    }

    public func projectManifest(_ scope: ProjectScope) -> String {
        ScopedFiles.manifest(in: projectDirectory(scope))
    }

    public func projectFiles(_ scope: ProjectScope) -> [String] {
        ScopedFiles.files(in: projectDirectory(scope))
    }

    public func copyProject(_ scope: ProjectScope, to destination: URL) -> [String] {
        ScopedFiles.copy(from: projectDirectory(scope), to: destination, prefix: "project/")
    }

    public func importMission(_ mission: MissionStore, missionID: UUID, to scope: ProjectScope) async -> [String] {
        var imported: [String] = []
        for name in await mission.deliverables(missionID: missionID) {
            guard let text = await mission.deliverable(missionID: missionID, name: name) else { continue }
            let destination = name.hasPrefix("project/") ? String(name.dropFirst("project/".count)) : name
            if ScopedFiles.write(destination, content: text, in: projectDirectory(scope)) != nil { imported.append(destination) }
        }
        return imported.sorted()
    }

    public func upload(_ scope: ProjectScope, name: String, data: Data) -> String? {
        ScopedFiles.upload(name, data: data, in: projectDirectory(scope))
    }

    private static func storageKey(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func nestedFiles(in folder: URL, relativeTo base: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var names: [String] = []
        for item in items {
            let relative = relativePath(item, to: base)
            if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory {
                names.append(contentsOf: nestedFiles(in: item, relativeTo: base))
            } else {
                names.append(relative)
            }
        }
        return names
    }

    /// `item` relative to `base`, tolerating symlinked roots (e.g. macOS `/tmp` → `/private/tmp`).
    private static func relativePath(_ item: URL, to base: URL) -> String {
        let prefix = base.standardizedFileURL.path + "/"
        let path = item.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : item.lastPathComponent
    }
    /// credentials someone might drop in the workspace (`.env`, `.pem`) never leave the server.
    public func read(conversationID: UUID, name: String, startLine: Int = 1) -> String? {
        guard startLine >= 1,
              let url = AgentTools.resolve(name, in: directory(conversationID)),
              MissionStore.readableDeliverableExtensions.contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url) else { return nil }
        guard data.count <= AgentTools.maxFileBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard startLine <= lines.count else { return nil }
        return lines[(startLine - 1)...].joined(separator: "\n")
    }

    @discardableResult
    public func write(conversationID: UUID, name: String, content: String) -> String? {
        guard let url = AgentTools.resolve(name, in: directory(conversationID)) else { return nil }
        guard content.utf8.count <= AgentTools.maxFileBytes else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: [.atomic])
            return AgentTools.normalized(name)
        } catch {
            return nil
        }
    }
}

// MARK: - Tool definitions

/// File and code tools Ada can use directly in chat. Files land in the conversation's private
/// workspace; code runs in a fresh sandbox under the conversation's folder with a hard timeout.
public enum ChatWorkspaceTools {
    public static let maxRunsPerTurn = 4
    public static let maxSourceBytes = 60_000
    public static let maxStdinBytes = 10_000
    public static let runTimeout: TimeInterval = 20
    public static let maxOutputCharacters = 12_000

    public static var definitions: [APIToolDef] {
        [
            APIToolDef(
                name: "chat_write_file",
                description: "Write (create or fully replace) a file in this conversation's private workspace. Use it when the user wants files they can open, preview, or download.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path, e.g. index.html or notes/plan.md"))])),
                        ("content", .object([("type", .string("string")), ("description", .string("Full file content"))])),
                    ])),
                    ("required", .array([.string("path"), .string("content")])),
                ])
            ),
            APIToolDef(
                name: "chat_read_file",
                description: "Read a file from this conversation's workspace. Use start_line to continue a clipped read.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path"))])),
                        ("start_line", .object([("type", .string("integer")), ("description", .string("Optional 1-based first line to return"))])),
                    ])),
                    ("required", .array([.string("path")])),
                ])
            ),
            APIToolDef(
                name: "chat_list_files",
                description: "List the files in this conversation's workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([:])),
                ])
            ),
            APIToolDef(
                name: "run_program",
                description: """
                Run code in a fresh throwaway sandbox and return its output. Nothing is saved unless you write it \
                with chat_write_file. Languages: "js" (Node.js), "python", and "c" (compiled and run with gcc). \
                Use it to compute, verify, or demonstrate — run the program you wrote, or a quick check, and \
                report the actual output.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("language", .object([
                            ("type", .string("string")),
                            ("enum", .array([.string("js"), .string("python"), .string("c")])),
                            ("description", .string("Language of the source code")),
                        ])),
                        ("source", .object([("type", .string("string")), ("description", .string("The program to run"))])),
                        ("stdin", .object([("type", .string("string")), ("description", .string("Optional text piped to the program's standard input"))])),
                        ("filename", .object([("type", .string("string")), ("description", .string("Optional name for the source file, e.g. main.c. Defaults by language"))])),
                    ])),
                    ("required", .array([.string("language"), .string("source")])),
                ])
            ),
            APIToolDef(
                name: "chat_schedule_run",
                description: "Schedule this conversation to run a prompt automatically on a timer, so work you would otherwise repeat on request (an hourly refresh, a daily digest, a periodic check) happens without the user asking each time. The platform sends the prompt for the user; you run it with your normal tools each time it fires.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("prompt", .object([("type", .string("string")), ("description", .string("The instruction to run each time, written as the user would phrase it, e.g. \"Refresh the list and update the saved file with anything new\""))])),
                        ("intervalMinutes", .object([
                            ("type", .string("integer")),
                            ("enum", .array([.string("15"), .string("30"), .string("60"), .string("360"), .string("720"), .string("1440")])),
                            ("description", .string("How often to run: 15 or 30 minutes, 60 (hourly), 360 (every 6 hours), 720 (every 12 hours), or 1440 (daily)")),
                        ])),
                    ])),
                    ("required", .array([.string("prompt"), .string("intervalMinutes")])),
                ])
            ),
            APIToolDef(
                name: "chat_schedule_cancel",
                description: "Cancel this conversation's automatic schedule, if one is set.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([:])),
                ])
            ),
        ]
    }

    /// True when `call` is one of Ada's workspace tools.
    public static func owns(_ name: String) -> Bool {
        name == "chat_write_file" || name == "chat_read_file" || name == "chat_list_files" || name == "run_program"
            || name == "chat_schedule_run" || name == "chat_schedule_cancel"
    }

    /// Runs one workspace tool call against `workspace`. Files written are reported back so the
    /// engine can show them in the reply. `schedule` receives schedule changes from the
    /// `chat_schedule_*` tools (the engine wires it to the conversation's store).
    public static func run(
        call: APIToolCall,
        workspace: ChatWorkspaceStore,
        conversationID: UUID,
        schedule: (@Sendable (ConversationSchedule?) async -> ConversationSchedule?)? = nil
    ) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        switch call.function.name {
        case "chat_schedule_run":
            guard let prompt = args["prompt"]?.stringValue,
                  let rawInterval = args["intervalMinutes"]?.numberValue.map({ Int($0) }) ?? args["intervalMinutes"]?.stringValue.flatMap(Int.init) else {
                return ToolOutcome(resultText: "chat_schedule_run requires prompt and intervalMinutes.")
            }
            guard let next = ConversationSchedule.validate(prompt: prompt, intervalMinutes: rawInterval) else {
                return ToolOutcome(resultText: "Invalid schedule. The prompt must be non-empty (under 4,000 characters) and intervalMinutes must be one of \(ConversationSchedule.allowedIntervals.map(String.init).joined(separator: ", ")).")
            }
            guard let sink = schedule else {
                return ToolOutcome(resultText: "Scheduling is not available in this context.")
            }
            guard let saved = await sink(next), saved == next else {
                return ToolOutcome(resultText: "The schedule could not be saved.")
            }
            return ToolOutcome(resultText: "Schedule set: \"\(next.prompt)\" every \(next.intervalLabel). The first run fires at the next interval boundary.")
        case "chat_schedule_cancel":
            guard let sink = schedule else {
                return ToolOutcome(resultText: "Scheduling is not available in this context.")
            }
            let cleared = await sink(nil)
            return ToolOutcome(resultText: cleared == nil
                ? "Schedule cancelled."
                : "No schedule was set, so nothing changed.")
        case "chat_list_files":
            let names = await workspace.files(conversationID: conversationID)
            return ToolOutcome(resultText: names.isEmpty ? "The workspace is empty." : names.joined(separator: "\n"))

        case "chat_read_file":
            guard let rawPath = args["path"]?.stringValue else {
                return ToolOutcome(resultText: "chat_read_file requires a path.")
            }
            let startLine = args["start_line"]?.numberValue.map(Int.init) ?? 1
            guard startLine >= 1,
                  let text = await workspace.read(conversationID: conversationID, name: rawPath, startLine: startLine) else {
                return ToolOutcome(resultText: "File not found, invalid start_line, or not a readable text file: \(rawPath)")
            }
            return ToolOutcome(resultText: AgentTools.clip(text, startLine: startLine))

        case "chat_write_file":
            guard let rawPath = args["path"]?.stringValue,
                  let content = args["content"]?.stringValue else {
                return ToolOutcome(resultText: "chat_write_file requires path and content.")
            }
            guard content.utf8.count <= AgentTools.maxFileBytes else {
                return ToolOutcome(resultText: "That file is too large to write (over 200 KB).")
            }
            guard let written = await workspace.write(conversationID: conversationID, name: rawPath, content: content) else {
                return ToolOutcome(resultText: "Invalid path: \(rawPath). Use a simple relative path with no .. or absolute paths.")
            }
            return ToolOutcome(resultText: "Wrote \(written) (\(content.utf8.count) bytes).", wroteFiles: [written])

        case "run_program":
            guard let language = args["language"]?.stringValue?.lowercased(),
                  let source = args["source"]?.stringValue else {
                return ToolOutcome(resultText: "run_program requires language and source.")
            }
            let stdin = args["stdin"]?.stringValue ?? ""
            let filename = args["filename"]?.stringValue
            #if canImport(Darwin) && !os(iOS) || canImport(Glibc)
            return CodeRunner.run(
                language: language,
                source: source,
                stdin: stdin,
                filename: filename,
                sandbox: workspace.directory(conversationID)
            )
            #else
            return ToolOutcome(resultText: "Running programs is not supported on this device.")
            #endif

        default:
            return ToolOutcome(resultText: "Unknown tool: \(call.function.name).")
        }
    }
}

// MARK: - Linked mission files

public enum ConversationMissionTools {
    private static func schema(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(required.map(JSONValue.string))),
        ])
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object([("type", .string(type)), ("description", .string(description))])
    }

    public static var definitions: [APIToolDef] {
        [
            APIToolDef(
                name: "mission_list_files",
                description: "List deliverables from a mission linked to this conversation.",
                parameters: schema([("mission_id", prop("string", "Full mission UUID from the conversation context"))], required: ["mission_id"])
            ),
            APIToolDef(
                name: "mission_read_file",
                description: "Read a text deliverable from a mission linked to this conversation. Use start_line to continue a clipped read.",
                parameters: schema([
                    ("mission_id", prop("string", "Full mission UUID from the conversation context")),
                    ("path", prop("string", "Relative deliverable path")),
                    ("start_line", prop("integer", "Optional 1-based first line to return")),
                ], required: ["mission_id", "path"])
            ),
        ]
    }

    public static func owns(_ name: String) -> Bool {
        name == "mission_list_files" || name == "mission_read_file"
    }

    public static func run(call: APIToolCall, store: MissionStore, allowedMissionIDs: Set<UUID>) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        guard let rawID = args["mission_id"]?.stringValue,
              let missionID = UUID(uuidString: rawID),
              allowedMissionIDs.contains(missionID) else {
            return ToolOutcome(resultText: "Mission not found in this conversation's linked mission references.")
        }
        switch call.function.name {
        case "mission_list_files":
            let files = await store.deliverables(missionID: missionID)
            return ToolOutcome(resultText: files.isEmpty ? "The mission workspace is empty." : files.joined(separator: "\n"))
        case "mission_read_file":
            guard let path = args["path"]?.stringValue else {
                return ToolOutcome(resultText: "mission_read_file requires a path.")
            }
            let startLine = args["start_line"]?.numberValue.map(Int.init) ?? 1
            guard startLine >= 1, let text = await store.deliverable(missionID: missionID, name: path) else {
                return ToolOutcome(resultText: "File not found (or not a readable text file): \(path)")
            }
            let lines = text.components(separatedBy: "\n")
            guard startLine <= lines.count else {
                return ToolOutcome(resultText: "start_line \(startLine) is beyond the end of \(path).")
            }
            let slice = lines[(startLine - 1)...].joined(separator: "\n")
            return ToolOutcome(resultText: AgentTools.clip(slice, startLine: startLine))
        default:
            return ToolOutcome(resultText: "Unknown tool: \(call.function.name).")
        }
    }
}

// MARK: - Code runner

/// Runs one short program in a fresh sandbox under the conversation's workspace folder.
///
/// The sandbox is a throwaway directory inside the conversation's files tree; nothing outside it is
/// reachable because every run is a plain `Process` with `currentDirectoryURL` set there. The
/// language toolchains are jail-free: they run as the server's own (unprivileged) user, with a hard
/// wall-clock timeout, an output cap, and a PATH-only environment so nothing from the server's
/// environment (tokens, keys) leaks into the child. Only the server runs programs; the package also
/// builds for iOS, where `Process` does not exist and running code is unsupported.
#if canImport(Darwin) && !os(iOS) || canImport(Glibc)
enum CodeRunner {
    struct Plan: Sendable {
        var executable: String
        var arguments: [String]
        var fileToWrite: String
    }

    static let plans: [String: (String) -> Plan] = [
        "js": { name in
            Plan(executable: "/usr/bin/env", arguments: ["node", "--no-warnings", name], fileToWrite: name)
        },
        "javascript": { name in
            Plan(executable: "/usr/bin/env", arguments: ["node", "--no-warnings", name], fileToWrite: name)
        },
        "python": { name in
            Plan(executable: "/usr/bin/env", arguments: ["python3", "-I", name], fileToWrite: name)
        },
        "py": { name in
            Plan(executable: "/usr/bin/env", arguments: ["python3", "-I", name], fileToWrite: name)
        },
        "c": { name in
            Plan(executable: "/usr/bin/env", arguments: ["sh", "-c", "gcc -std=c17 -O1 -o program \(shellQuoted(name)) && ./program"], fileToWrite: name)
        },
    ]

    /// Quoted for the embedded `sh -c` line in the C plan (and only there).
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultFilenames: [String: String] = [
        "js": "program.js", "javascript": "program.js",
        "python": "program.py", "py": "program.py", "c": "main.c",
    ]

    static func run(language rawLanguage: String, source: String, stdin: String, filename: String?, sandbox baseURL: URL) -> ToolOutcome {
        let language = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let makePlan = plans[language] else {
            return ToolOutcome(resultText: "Unsupported language: \(language). Available: js, python, c.")
        }
        guard source.count <= ChatWorkspaceTools.maxSourceBytes else {
            return ToolOutcome(resultText: "The program is too long (over 60,000 characters).")
        }
        guard stdin.count <= ChatWorkspaceTools.maxStdinBytes else {
            return ToolOutcome(resultText: "The standard input is too long (over 10,000 characters).")
        }
        let rawName = (filename ?? defaultFilenames[language] ?? "program.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = AgentTools.resolve(rawName, in: baseURL),
              resolved.deletingLastPathComponent().path.hasPrefix(baseURL.path) else {
            return ToolOutcome(resultText: "Invalid filename: \(rawName).")
        }
        let sourceName = resolved.lastPathComponent
        let plan = makePlan(sourceName)

        // The sandbox directory is created inside the conversation's files tree and removed after
        // the run, so nothing the program writes survives in the workspace listing.
        let sandbox = baseURL.appendingPathComponent(".run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        do {
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: sandbox.appendingPathComponent(plan.fileToWrite), options: [.atomic])
            return try execute(plan, in: sandbox, stdin: stdin)
        } catch {
            return ToolOutcome(resultText: "Could not run the program: \(error.localizedDescription)")
        }
    }

    static func execute(_ plan: Plan, in sandbox: URL, stdin: String, environment: [String: String]? = nil, timeout: TimeInterval = ChatWorkspaceTools.runTimeout) throws -> ToolOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = sandbox
        process.environment = environment ?? ["PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let group = DispatchGroup()
        var collected = Data()
        let lock = NSLock()
        let cap = ChatWorkspaceTools.maxOutputCharacters * 4
        let readers = [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
        for reader in readers {
            group.enter()
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                lock.lock()
                if collected.count < cap { collected.append(chunk) }
                lock.unlock()
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                }
            }
        }

        if stdin.isEmpty {
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            let writer = stdinPipe.fileHandleForWriting
            writer.writeabilityHandler = { handle in
                handle.writeabilityHandler = nil
                handle.write(Data(stdin.utf8))
                try? handle.close()
            }
        }

        do {
            try process.run()
        } catch {
            for reader in readers { reader.readabilityHandler = nil }
            throw CodeRunnerError.toolchainMissing(languageHint: plan.arguments.first ?? plan.executable)
        }

        let processGroup = setpgid(process.processIdentifier, process.processIdentifier) == 0 ? process.processIdentifier : -1
        let timedOut = !waitWithTimeout(process, seconds: timeout)
        if timedOut {
            if processGroup > 0 { kill(-processGroup, SIGTERM) } else { process.terminate() }
            _ = waitForExit(process, seconds: 3)
            if processGroup > 0, process.isRunning { kill(-processGroup, SIGKILL) }
        }
        group.wait()
        for reader in readers { reader.readabilityHandler = nil }
        stdinPipe.fileHandleForWriting.writeabilityHandler = nil

        let output = String(data: collected, encoding: .utf8) ?? ""
        let clipped = AgentTools.clip(String(output.prefix(ChatWorkspaceTools.maxOutputCharacters)))
        let seconds = Int(timeout.rounded())
        if timedOut {
            return ToolOutcome(resultText: "Timed out after \(seconds)s and was stopped. Partial output:\n\(clipped)")
        }
        let status = process.terminationStatus
        if status == 0 {
            return ToolOutcome(resultText: "Exit code 0. Output:\n\(clipped.isEmpty ? "(no output)" : clipped)")
        }
        let reason = process.terminationReason == .uncaughtSignal ? "the program was stopped" : "exit code \(status)"
        return ToolOutcome(resultText: "Failed (\(reason)). Output:\n\(clipped.isEmpty ? "(no output)" : clipped)")
    }

    /// Waits for the process to exit, returning false when `seconds` elapse first. A background
    /// thread blocks in `waitUntilExit` and signals; if it never does, the caller kills the process
    /// and the thread's wait returns on its own.
    private static func waitWithTimeout(_ process: Process, seconds: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let watcher = Thread {
            process.waitUntilExit()
            sem.signal()
        }
        watcher.start()
        return sem.wait(timeout: .now() + seconds) == .success
    }

    /// Same shape as `waitWithTimeout` but for a short, bounded cleanup wait.
    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let watcher = Thread {
            process.waitUntilExit()
            sem.signal()
        }
        watcher.start()
        return sem.wait(timeout: .now() + seconds) == .success
    }
}

enum CodeRunnerError: Error, LocalizedError {
    case toolchainMissing(languageHint: String)

    var errorDescription: String? {
        switch self {
        case .toolchainMissing(let hint):
            "No toolchain found for that language (looked for \(hint)). It may not be installed on this server."
        }
    }
}
#endif
