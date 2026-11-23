import Foundation

public struct ToolOutcome: Sendable {
    public var resultText: String
    public var wroteFiles: [String]
    public var finished: Bool
    public var finishSummary: String?
    public var succeeded: Bool

    public init(resultText: String, wroteFiles: [String] = [], finished: Bool = false, finishSummary: String? = nil, succeeded: Bool = true) {
        self.resultText = resultText
        self.wroteFiles = wroteFiles
        self.finished = finished
        self.finishSummary = finishSummary
        self.succeeded = succeeded
    }

    public static func success(_ resultText: String) -> ToolOutcome {
        ToolOutcome(resultText: resultText)
    }

    public static func failure(_ resultText: String) -> ToolOutcome {
        ToolOutcome(resultText: resultText, succeeded: false)
    }
}

public enum AgentTools {
    public static let resultClip = 15_000
    public static let maxFileBytes = 200_000

    public static var workerTools: [APIToolDef] {
        [
            APIToolDef(
                name: "write_file",
                description: "Write (create or fully replace) a file in your workspace. Paths are relative to the mission workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path, e.g. findings.md"))])),
                        ("content", .object([("type", .string("string")), ("description", .string("Full file content"))])),
                    ])),
                    ("required", .array([.string("path"), .string("content")])),
                ])
            ),
            APIToolDef(
                name: "read_file",
                description: "Read a file from your workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path"))])),
                        ("start_line", .object([("type", .string("integer")), ("description", .string("Optional 1-based start line"))])),
                    ])),
                    ("required", .array([.string("path")])),
                ])
            ),
            APIToolDef(
                name: "list_dir",
                description: "List files currently in the mission workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([:])),
                ])
            ),
            APIToolDef(
                name: "run_program",
                description: "Run code in a fresh, OS-sandboxed folder and see its output. The program can read mission workspace files at ../<path> but cannot change them, and it cannot see server data. Languages: \"js\" (Node.js), \"python\", \"c\" (compiled with gcc). 60-second timeout. Nothing is saved; use write_file for deliverables. Run the program you wrote to verify it actually works before finishing.",
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
                        ("filename", .object([("type", .string("string")), ("description", .string("Optional name for the source file. Defaults by language"))])),
                    ])),
                    ("required", .array([.string("language"), .string("source")])),
                ])
            ),
            APIToolDef(
                name: "finish",
                description: "Call this when your task is complete. Provide a short summary of what you produced for the coordinator.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("summary", .object([("type", .string("string")), ("description", .string("One short paragraph summarizing what you did and produced"))])),
                    ])),
                    ("required", .array([.string("summary")])),
                ])
            ),
        ]
    }

    public static var readTools: [APIToolDef] {
        [
            APIToolDef(
                name: "read_file",
                description: "Read a file from the mission workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("path", .object([("type", .string("string")), ("description", .string("Relative file path"))])),
                    ])),
                    ("required", .array([.string("path")])),
                ])
            ),
            APIToolDef(
                name: "list_dir",
                description: "List files in the mission workspace.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([:])),
                ])
            ),
        ]
    }

    public static func run(call: APIToolCall, workspace: URL, readOnly: Bool = false, protecting: URL? = nil) -> ToolOutcome {
        let args = arguments(of: call)

        switch call.function.name {
        case "finish":
            if let summary = args["summary"]?.stringValue {
                return ToolOutcome(resultText: "Task complete.", finished: true, finishSummary: summary)
            }
            return ToolOutcome(resultText: "finish requires a summary string.", finished: true, finishSummary: "Finished without a summary.")

        case "list_dir":
            let listing = listWorkspace(workspace)
            return ToolOutcome(resultText: listing.isEmpty ? "Workspace is empty." : listing.joined(separator: "\n"))

        case "read_file":
            guard let rawPath = args["path"]?.stringValue else {
                return .failure("read_file requires a path.")
            }
            guard let url = resolve(rawPath, in: workspace), let data = try? Data(contentsOf: url) else {
                return .failure("File not found: \(rawPath)")
            }
            guard var text = utf8Prefix(data, maxBytes: maxFileBytes) else {
                return .failure("Can't read \(rawPath): it is not UTF-8 text.")
            }
            if data.count > maxFileBytes {
                text += "\n…[the file is \(data.count) bytes; only the first \(maxFileBytes) were read]"
            }
            if let start = args["start_line"], let line = start.numberValue, line > 1 {
                let lines = text.components(separatedBy: "\n")
                let idx = Int(line) - 1
                if idx >= 0 && idx < lines.count {
                    text = " lines \(idx + 1)+\n" + lines[idx...].joined(separator: "\n")
                }
            }
            return ToolOutcome(resultText: clip(text))

        case "write_file":
            if readOnly {
                return .failure("This agent is read-only and cannot write files.")
            }
            guard let rawPath = args["path"]?.stringValue,
                  let content = args["content"]?.stringValue else {
                return .failure("write_file requires path and content.")
            }
            guard let url = resolve(rawPath, in: workspace) else {
                return .failure("Invalid path: \(rawPath). Use a simple relative path with no .. or absolute paths.")
            }
            guard content.utf8.count <= maxFileBytes else {
                return .failure("Can't write \(rawPath): it is \(content.utf8.count) bytes and the limit is \(maxFileBytes). Split it into smaller files.")
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: [.atomic])
                return ToolOutcome(
                    resultText: "Wrote \(rawPath) (\(content.utf8.count) bytes).",
                    wroteFiles: [normalized(rawPath)]
                )
            } catch {
                return .failure("Could not write \(rawPath): \(error.localizedDescription)")
            }

        case "run_program":
            guard let language = args["language"]?.stringValue,
                  let source = args["source"]?.stringValue else {
                return .failure("run_program requires language and source.")
            }
            let stdin = args["stdin"]?.stringValue ?? ""
            let filename = args["filename"]?.stringValue
            return CodeRunner.run(language: language, source: source, stdin: stdin, filename: filename, sandbox: workspace, protecting: protecting)

        default:
            return .failure("Unknown tool: \(call.function.name).")
        }
    }

    public static func arguments(of call: APIToolCall) -> [String: JSONValue] {
        guard let data = call.function.arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = decoded.objectValue else {
            return [:]
        }
        return object
    }

    public static func resolve(_ rawPath: String, in workspace: URL) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") { return nil }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)
        var stack: [String] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else if part != "" {
                stack.append(part)
            }
        }
        guard !stack.isEmpty else { return workspace }
        return workspace.appendingPathComponent(stack.joined(separator: "/"))
    }

    public static func normalized(_ rawPath: String) -> String {
        rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").joined(separator: "/")
    }

    /// Decodes up to `maxBytes` of UTF-8, stepping back to a character boundary so a cut through a
    /// multi-byte character does not make the whole file look binary. Nil when the bytes are not UTF-8.
    static func utf8Prefix(_ data: Data, maxBytes: Int) -> String? {
        let head = data.prefix(maxBytes)
        for trim in 0...min(3, head.count) {
            if let text = String(data: head.dropLast(trim), encoding: .utf8) { return text }
            if head.count < maxBytes { break }
        }
        return nil
    }

    public static func clip(_ text: String) -> String {
        if text.count <= resultClip { return text }
        let cut = text.index(text.startIndex, offsetBy: resultClip)
        return text[..<cut] + "\n…[clipped at \(resultClip) characters — continue reading with start_line]"
    }

    public static func clip(_ text: String, startLine: Int) -> String {
        if text.count <= resultClip { return text }
        let cut = text.index(text.startIndex, offsetBy: resultClip)
        let clipped = String(text[..<cut])
        let nextLine = startLine + clipped.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        return clipped + "\n…[clipped at \(resultClip) characters — continue reading with start_line \(nextLine)]"
    }

    public static func listWorkspace(_ workspace: URL) -> [String] {
        func walk(_ directory: URL) -> [String] {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return items.flatMap { item -> [String] in
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    return walk(item)
                }
                let prefix = workspace.standardizedFileURL.path + "/"
                let path = item.standardizedFileURL.path
                let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : item.lastPathComponent
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ["\(name) — \(size) bytes"]
            }
        }
        return walk(workspace).sorted()
    }
}
