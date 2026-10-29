import Foundation

public struct ToolOutcome: Sendable {
    public var resultText: String
    public var wroteFiles: [String]
    public var finished: Bool
    public var finishSummary: String?

    public init(resultText: String, wroteFiles: [String] = [], finished: Bool = false, finishSummary: String? = nil) {
        self.resultText = resultText
        self.wroteFiles = wroteFiles
        self.finished = finished
        self.finishSummary = finishSummary
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

    public static func run(call: APIToolCall, workspace: URL, readOnly: Bool = false) -> ToolOutcome {
        let args: [String: JSONValue]
        if let data = call.function.arguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = decoded.objectValue {
            args = object
        } else {
            args = [:]
        }

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
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: [.atomic])
                return ToolOutcome(
                    resultText: "Wrote \(rawPath) (\(content.utf8.count) bytes).",
                    wroteFiles: [normalized(rawPath)]
                )
            } catch {
                return ToolOutcome(resultText: "Could not write \(rawPath): \(error.localizedDescription)")
            }

        default:
            return ToolOutcome(resultText: "Unknown tool: \(call.function.name).")
        }
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

    public static func listWorkspace(_ workspace: URL) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> String in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(url.lastPathComponent) — \(size) bytes"
            }
    }
}
