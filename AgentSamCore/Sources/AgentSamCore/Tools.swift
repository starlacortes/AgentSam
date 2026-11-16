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
                description: "Run code in a fresh throwaway sandbox and see its output. Languages: \"js\" (Node.js), \"python\", \"c\" (compiled with gcc). Nothing is saved; use write_file for deliverables. Run the program you wrote to verify it actually works before finishing.",
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

    /// The coordinator's only tool during planning: submit the task plan as
    /// structured JSON instead of free-form text (see `StructuredOutput.plan`).
    public static var submitPlanTool: APIToolDef {
        APIToolDef(
            name: "submit_plan",
            description: "Submit the final task plan. Call this once when your plan is ready.",
            parameters: .object([
                ("type", .string("object")),
                ("properties", .object([
                    ("tasks", .object([
                        ("type", .string("array")),
                        ("description", .string("The tasks, one per worker")),
                        ("items", .object([
                            ("type", .string("object")),
                            ("properties", .object([
                                ("agent", .object([("type", .string("string")), ("description", .string("Worker name, exactly as listed"))])),
                                ("goal", .object([("type", .string("string")), ("description", .string("One-sentence task goal"))])),
                                ("deliverable", .object([("type", .string("string")), ("description", .string("Output markdown filename, lowercase and hyphenated, ending in .md"))])),
                            ])),
                            ("required", .array([.string("agent"), .string("goal"), .string("deliverable")])),
                        ])),
                    ])),
                ])),
                ("required", .array([.string("tasks")])),
            ])
        )
    }

    /// The verifier's submission tool: findings plus a verdict as structured
    /// JSON (see `StructuredOutput.review`).
    public static var submitReviewTool: APIToolDef {
        APIToolDef(
            name: "submit_review",
            description: "Submit your review findings and verdict. Call this once when your review is complete.",
            parameters: .object([
                ("type", .string("object")),
                ("properties", .object([
                    ("verdict", .object([
                        ("type", .string("string")),
                        ("enum", .array([.string("clean"), .string("concerns"), .string("failed")])),
                        ("description", .string("Overall verdict on the deliverables")),
                    ])),
                    ("findings", .object([
                        ("type", .string("array")),
                        ("maxItems", .number(8)),
                        ("items", .object([
                            ("type", .string("object")),
                            ("properties", .object([
                                ("level", .object([
                                    ("type", .string("string")),
                                    ("enum", .array([.string("pass"), .string("concern"), .string("fail")])),
                                ])),
                                ("area", .object([("type", .string("string")), ("description", .string("Short label for what was checked"))])),
                                ("detail", .object([("type", .string("string")), ("description", .string("One sentence about the finding"))])),
                            ])),
                            ("required", .array([.string("level"), .string("detail")])),
                        ])),
                    ])),
                ])),
                ("required", .array([.string("verdict"), .string("findings")])),
            ])
        )
    }

    /// Tools offered to the coordinator during the planning phase.
    public static var planTools: [APIToolDef] { [submitPlanTool] }

    /// Tools offered to the verifier: read-only workspace access plus the
    /// structured review submission.
    public static var verifierTools: [APIToolDef] { readTools + [submitReviewTool] }

    public static func run(call: APIToolCall, workspace: URL, readOnly: Bool = false) -> ToolOutcome {
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
                return ToolOutcome(resultText: "read_file requires a path.")
            }
            guard let url = resolve(rawPath, in: workspace), let data = try? Data(contentsOf: url) else {
                return ToolOutcome(resultText: "File not found: \(rawPath)")
            }
            var text = String(data: data.prefix(maxFileBytes), encoding: .utf8) ?? "(binary file)"
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
                return ToolOutcome(resultText: "This agent is read-only and cannot write files.")
            }
            guard let rawPath = args["path"]?.stringValue,
                  let content = args["content"]?.stringValue else {
                return ToolOutcome(resultText: "write_file requires path and content.")
            }
            guard let url = resolve(rawPath, in: workspace) else {
                return ToolOutcome(resultText: "Invalid path: \(rawPath). Use a simple relative path with no .. or absolute paths.")
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: [.atomic])
                return ToolOutcome(
                    resultText: "Wrote \(rawPath) (\(content.utf8.count) bytes).",
                    wroteFiles: [normalized(rawPath)]
                )
            } catch {
                return ToolOutcome(resultText: "Could not write \(rawPath): \(error.localizedDescription)")
            }

        case "run_program":
            guard let language = args["language"]?.stringValue,
                  let source = args["source"]?.stringValue else {
                return ToolOutcome(resultText: "run_program requires language and source.")
            }
            let stdin = args["stdin"]?.stringValue ?? ""
            let filename = args["filename"]?.stringValue
            return CodeRunner.run(language: language, source: source, stdin: stdin, filename: filename, sandbox: workspace)

        default:
            return ToolOutcome(resultText: "Unknown tool: \(call.function.name).")
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
