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

    /// Writes binary data (a screenshot) into the conversation's workspace.
    @discardableResult
    public func writeData(conversationID: UUID, name: String, data: Data) -> String? {
        guard let url = AgentTools.resolve(name, in: directory(conversationID)), data.count <= AgentTools.maxFileBytes else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return AgentTools.normalized(name)
        } catch {
            return nil
        }
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
    public static let maxRunsPerTurn = 12
    public static let maxSourceBytes = 60_000
    public static let maxStdinBytes = 10_000
    public static let runTimeout: TimeInterval = 60
    /// Seconds a terminal command may run.
    public static let terminalTimeout: TimeInterval = 120
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
                Run code in a fresh, OS-sandboxed folder and return its output. The program can read this \
                conversation's workspace files at ../<path> but cannot change them, and it cannot see the home \
                folder or server data. Nothing it writes is saved; use chat_write_file for files. Languages: "js" \
                (Node.js), "python", and "c" (compiled and run with gcc). Limits: 60-second timeout, 60,000-character source, 12,000 characters of output, and 12 program or \
                terminal runs per reply. Use it to compute, verify, or demonstrate: run the program you wrote, or a \
                quick check, and report the actual output.
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
                description: "Schedule this conversation to run a prompt automatically, either every N minutes or at a set local time on chosen days (\"weekdays at 08:00\"), so work you would otherwise repeat on request (an hourly refresh, a morning digest, a periodic check) happens without the user asking each time. The platform sends the prompt for the user; you run it with your normal tools each time it fires. A chat has one schedule; setting it again replaces it. It pauses itself after 3 failed runs in a row. To react to new email or a webhook instead, use chat_trigger_add.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("prompt", .object([("type", .string("string")), ("description", .string("The instruction to run each time, written as the user would phrase it, e.g. \"Refresh the list and update the saved file with anything new\""))])),
                        ("intervalMinutes", .object([
                            ("type", .string("integer")),
                            ("enum", .array([.number(15), .number(30), .number(60), .number(360), .number(720), .number(1440)])),
                            ("description", .string("How often to run: 15 or 30 minutes, 60 (hourly), 360 (every 6 hours), 720 (every 12 hours), or 1440 (daily). Leave out when you give `at`")),
                        ])),
                        ("at", .object([("type", .string("string")), ("description", .string("A local time of day in 24-hour HH:MM, e.g. \"08:00\", in the user's time zone. Use this instead of intervalMinutes for set times"))])),
                        ("days", .object([("type", .string("string")), ("description", .string("With `at`: \"every day\" (default), \"weekdays\", \"weekends\", or days such as \"mon,wed,fri\""))])),
                    ])),
                    ("required", .array([.string("prompt")])),
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


    /// Runs one workspace tool call against `workspace`. Files written are reported back so the
    /// engine can show them in the reply. `schedule` receives schedule changes from the
    /// `chat_schedule_*` tools (the engine wires it to the conversation's store).
    public static func run(
        call: APIToolCall,
        workspace: ChatWorkspaceStore,
        conversationID: UUID,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!,
        schedule: (@Sendable (ConversationSchedule?) async -> ConversationSchedule?)? = nil
    ) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        switch call.function.name {
        case "chat_schedule_run":
            let rawInterval = args["intervalMinutes"]?.numberValue.map({ Int($0) }) ?? args["intervalMinutes"]?.stringValue.flatMap(Int.init)
            let rawAt = args["at"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            guard let prompt = args["prompt"]?.stringValue, rawInterval != nil || rawAt != nil else {
                return .failure("chat_schedule_run requires prompt and either intervalMinutes or at.")
            }
            var at: ScheduleTime?
            if let rawAt {
                guard let parsed = ScheduleTime.parse(time: rawAt, days: args["days"]?.stringValue) else {
                    return .failure("Invalid schedule time. Give at as 24-hour HH:MM (e.g. 08:00) and days as every day, weekdays, weekends, or a list like mon,wed,fri.")
                }
                at = parsed
            }
            guard let next = ConversationSchedule.validate(prompt: prompt, intervalMinutes: rawInterval, at: at, timeZone: timeZone) else {
                return .failure("Invalid schedule. The prompt must be non-empty (under 4,000 characters) and intervalMinutes must be one of \(ConversationSchedule.allowedIntervals.map(String.init).joined(separator: ", ")).")
            }
            guard let sink = schedule else {
                return .failure("Scheduling is not available in this context.")
            }
            guard let saved = await sink(next), saved == next else {
                return .failure("The schedule could not be saved.")
            }
            return ToolOutcome(resultText: "Schedule set: \"\(next.prompt)\", \(next.intervalLabel). The first run is at \(ConversationPromptContext.describe(next.nextRunAt, in: timeZone)).")
        case "chat_schedule_cancel":
            guard let sink = schedule else {
                return .failure("Scheduling is not available in this context.")
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
                return .failure("chat_read_file requires a path.")
            }
            let startLine = args["start_line"]?.numberValue.map(Int.init) ?? 1
            guard startLine >= 1,
                  let text = await workspace.read(conversationID: conversationID, name: rawPath, startLine: startLine) else {
                return .failure("File not found, invalid start_line, or not a readable text file: \(rawPath)")
            }
            return ToolOutcome(resultText: AgentTools.clip(text, startLine: startLine))

        case "chat_write_file":
            guard let rawPath = args["path"]?.stringValue,
                  let content = args["content"]?.stringValue else {
                return .failure("chat_write_file requires path and content.")
            }
            guard content.utf8.count <= AgentTools.maxFileBytes else {
                return .failure("That file is too large to write (over 200 KB).")
            }
            guard let written = await workspace.write(conversationID: conversationID, name: rawPath, content: content) else {
                return .failure("Invalid path: \(rawPath). Use a simple relative path with no .. or absolute paths.")
            }
            return ToolOutcome(resultText: "Wrote \(written) (\(content.utf8.count) bytes).", wroteFiles: [written])

        case "run_program":
            guard let language = args["language"]?.stringValue?.lowercased(),
                  let source = args["source"]?.stringValue else {
                return .failure("run_program requires language and source.")
            }
            let stdin = args["stdin"]?.stringValue ?? ""
            let filename = args["filename"]?.stringValue
            #if canImport(Darwin) && !os(iOS) || canImport(Glibc)
            return CodeRunner.run(
                language: language,
                source: source,
                stdin: stdin,
                filename: filename,
                sandbox: workspace.directory(conversationID),
                protecting: workspace.root
            )
            #else
            return .failure("Running programs is not supported on this device.")
            #endif

        default:
            return .failure("Unknown tool: \(call.function.name).")
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


    public static func run(call: APIToolCall, store: MissionStore, allowedMissionIDs: Set<UUID>) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        guard let rawID = args["mission_id"]?.stringValue,
              let missionID = UUID(uuidString: rawID),
              allowedMissionIDs.contains(missionID) else {
            return .failure("Mission not found in this conversation's linked mission references.")
        }
        switch call.function.name {
        case "mission_list_files":
            let files = await store.deliverables(missionID: missionID)
            return ToolOutcome(resultText: files.isEmpty ? "The mission workspace is empty." : files.joined(separator: "\n"))
        case "mission_read_file":
            guard let path = args["path"]?.stringValue else {
                return .failure("mission_read_file requires a path.")
            }
            let startLine = args["start_line"]?.numberValue.map(Int.init) ?? 1
            guard startLine >= 1, let text = await store.deliverable(missionID: missionID, name: path) else {
                return .failure("File not found (or not a readable text file): \(path)")
            }
            let lines = text.components(separatedBy: "\n")
            guard startLine <= lines.count else {
                return .failure("start_line \(startLine) is beyond the end of \(path).")
            }
            let slice = lines[(startLine - 1)...].joined(separator: "\n")
            return ToolOutcome(resultText: AgentTools.clip(slice, startLine: startLine))
        default:
            return .failure("Unknown tool: \(call.function.name).")
        }
    }
}

// MARK: - Code runner

/// Runs one short program in a fresh sandbox under the conversation's workspace folder.
///
/// Each run gets a throwaway directory inside the conversation's files tree and runs inside the OS
/// sandbox (`OSSandbox`: bubblewrap on Linux, sandbox-exec on macOS), which lets it write only to that
/// directory and hides the home folder and the AgentSam data folder (keys, other conversations). Runs
/// also have a hard wall-clock timeout, an output cap, and a minimal environment so nothing from the
/// server's environment (tokens, keys) leaks into the child. Without an OS sandbox nothing runs. Only
/// the server runs programs; the package also builds for iOS, where `Process` does not exist.
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

    /// `protecting` is a folder the program must never see, normally the AgentSam data folder.
    static func run(language rawLanguage: String, source: String, stdin: String, filename: String?, sandbox baseURL: URL, protecting: URL? = nil) -> ToolOutcome {
        let language = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let makePlan = plans[language] else {
            return .failure("Unsupported language: \(language). Available: js, python, c.")
        }
        guard source.count <= ChatWorkspaceTools.maxSourceBytes else {
            return .failure("The program is too long (over 60,000 characters).")
        }
        guard stdin.count <= ChatWorkspaceTools.maxStdinBytes else {
            return .failure("The standard input is too long (over 10,000 characters).")
        }
        let rawName = (filename ?? defaultFilenames[language] ?? "program.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = AgentTools.resolve(rawName, in: baseURL),
              resolved.deletingLastPathComponent().path.hasPrefix(baseURL.path) else {
            return .failure("Invalid filename: \(rawName).")
        }
        let sourceName = resolved.lastPathComponent
        let plan = makePlan(sourceName)

        // The run directory is created inside the conversation's files tree and removed after the
        // run, so nothing the program writes survives in the workspace listing. The OS sandbox lets
        // the program write only there and hides the home and data folders.
        let sandbox = baseURL.appendingPathComponent(".run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        do {
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: sandbox.appendingPathComponent(plan.fileToWrite), options: [.atomic])
            guard let sandboxed = OSSandbox.wrap(executable: plan.executable, arguments: plan.arguments, writable: sandbox, directory: sandbox, readable: baseURL, protecting: protecting) else {
                return .failure(sandboxUnavailable(OSSandbox.unavailableReason))
            }
            return try execute(sandboxed, in: sandbox, stdin: stdin, environment: environment(sandbox: sandbox))
        } catch {
            return .failure("Could not run the program: \(error.localizedDescription)")
        }
    }

    static func sandboxUnavailable(_ reason: String?) -> String {
        "No program was run: running programs needs the OS sandbox (bubblewrap on Linux, sandbox-exec on macOS), and it is not available on this server (\(reason ?? "unknown reason")). Tell the user; do not try to work around it."
    }

    /// Only what the toolchains need. Nothing from the server's environment (tokens, keys) is passed on.
    static func environment(sandbox: URL) -> [String: String] {
        [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": sandbox.path,
            "TMPDIR": sandbox.path,
            "LANG": "C.UTF-8",
        ]
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

        // stdin is written from its own thread once the program starts. A writeabilityHandler that
        // clears itself deadlocks swift-corelibs-foundation on Linux, and the write may block until
        // the program reads, so it cannot happen here either.
        let stdinData = Data(stdin.utf8)

        // One termination handler signals the exit. Several threads blocking in waitUntilExit on
        // the same Process race inside swift-corelibs-foundation and can crash on Linux.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            for reader in readers { reader.readabilityHandler = nil }
            throw CodeRunnerError.toolchainMissing(languageHint: plan.arguments.first ?? plan.executable)
        }
        let writer = stdinPipe.fileHandleForWriting
        if stdinData.isEmpty {
            try? writer.close()
        } else {
            // A program that exits without reading closes the pipe; ignore SIGPIPE for this write.
            Thread {
                signal(SIGPIPE, SIG_IGN)
                try? writer.write(contentsOf: stdinData)
                try? writer.close()
            }.start()
        }

        // Foundation may already have put the child in its own group, in which case setpgid fails
        // after exec; the group still belongs to the child.
        let pid = process.processIdentifier
        let processGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid ? pid : -1
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            // The child can inherit a signal mask that blocks SIGTERM (Swift concurrency's worker
            // threads block it on Linux), so SIGKILL always follows. Killing bubblewrap's outer
            // process also ends everything inside the sandbox (--die-with-parent).
            if processGroup > 0 { kill(-processGroup, SIGTERM) } else { process.terminate() }
            if exited.wait(timeout: .now() + 3) == .timedOut {
                if processGroup > 0 { kill(-processGroup, SIGKILL) }
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        // A stray grandchild that escaped the group could hold the pipes open forever.
        if group.wait(timeout: .now() + (timedOut ? 2 : 10)) == .timedOut {
            for reader in readers { reader.readabilityHandler = nil; try? reader.close() }
        }
        for reader in readers { reader.readabilityHandler = nil }

        let output = String(data: collected, encoding: .utf8) ?? ""
        let clipped = headAndTail(output, limit: ChatWorkspaceTools.maxOutputCharacters)
        let seconds = Int(timeout.rounded())
        if timedOut {
            return .failure("Timed out after \(seconds)s and was stopped. Partial output:\n\(clipped)")
        }
        let status = process.terminationStatus
        if status == 0 {
            return ToolOutcome(resultText: "Exit code 0. Output:\n\(clipped.isEmpty ? "(no output)" : clipped)")
        }
        let reason = process.terminationReason == .uncaughtSignal ? "the program was stopped" : "exit code \(status)"
        return .failure("Failed (\(reason)). Output:\n\(clipped.isEmpty ? "(no output)" : clipped)")
    }
}

extension CodeRunner {
    /// Keeps the start and the end of long output, where errors and final results usually are,
    /// and says how much was dropped from the middle. The terminal's working-directory marker is
    /// the last line, so it survives too.
    static func headAndTail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headCount = limit / 3
        let tailCount = limit - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        let dropped = text.dropFirst(headCount).dropLast(tailCount)
        let lines = dropped.reduce(into: 0) { count, character in if character == "\n" { count += 1 } }
        return head + "\n…[\(dropped.count) characters (\(lines) lines) omitted from the middle of the output]…\n" + tail
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
