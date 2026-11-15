import Foundation
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
    public func read(conversationID: UUID, name: String) -> String? {
        guard let url = AgentTools.resolve(name, in: directory(conversationID)),
              MissionStore.readableDeliverableExtensions.contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url) else { return nil }
        guard data.count <= AgentTools.maxFileBytes else { return nil }
        return String(data: data, encoding: .utf8)
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
                description: "Read a file from this conversation's workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path"))])),
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
        ]
    }

    /// True when `call` is one of Ada's workspace tools.
    public static func owns(_ name: String) -> Bool {
        name == "chat_write_file" || name == "chat_read_file" || name == "chat_list_files" || name == "run_program"
    }

    /// Runs one workspace tool call against `workspace`. Files written are reported back so the
    /// engine can show them in the reply.
    public static func run(call: APIToolCall, workspace: ChatWorkspaceStore, conversationID: UUID) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        switch call.function.name {
        case "chat_list_files":
            let names = await workspace.files(conversationID: conversationID)
            return ToolOutcome(resultText: names.isEmpty ? "The workspace is empty." : names.joined(separator: "\n"))

        case "chat_read_file":
            guard let rawPath = args["path"]?.stringValue else {
                return ToolOutcome(resultText: "chat_read_file requires a path.")
            }
            guard let text = await workspace.read(conversationID: conversationID, name: rawPath) else {
                return ToolOutcome(resultText: "File not found (or not a readable text file): \(rawPath)")
            }
            return ToolOutcome(resultText: AgentTools.clip(text))

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

    private static func execute(_ plan: Plan, in sandbox: URL, stdin: String) throws -> ToolOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = sandbox
        // A PATH-only environment: system locations just, so no AGENTSAM_* variables, tokens, or
        // keys leak into the child while the language toolchains still resolve.
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"]
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

        // Hard wall-clock timeout: the process is killed and reported as timed out.
        let timedOut = !waitWithTimeout(process, seconds: ChatWorkspaceTools.runTimeout)
        if timedOut {
            process.terminate()
            // Give the kill a moment to take effect, then clean up the handlers.
            _ = waitForExit(process, seconds: 3)
        }
        group.wait()
        for reader in readers { reader.readabilityHandler = nil }
        stdinPipe.fileHandleForWriting.writeabilityHandler = nil

        let output = String(data: collected, encoding: .utf8) ?? ""
        let clipped = AgentTools.clip(String(output.prefix(ChatWorkspaceTools.maxOutputCharacters)))
        let seconds = Int(ChatWorkspaceTools.runTimeout.rounded())
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
