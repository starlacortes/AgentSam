import Foundation

public enum ExtendedWorkspaceTools {
    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object([("type", .string(type)), ("description", .string(description))])
    }

    private static func schema(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(required.map(JSONValue.string))),
        ])
    }

    private static let path = ("path", prop("string", "Relative file path inside the selected workspace"))
    private static let content = ("content", prop("string", "Complete UTF-8 file content, at most 200 KB"))
    private static let grant = ("grant_id", prop("string", "UUID of a folder explicitly granted by the user in Settings"))

    public static var definitions: [APIToolDef] {
        var definitions: [APIToolDef] = []
        for prefix in ["chat", "project"] {
            let scope = prefix == "chat" ? "this conversation's private workspace" : "the shared project workspace"
            definitions += [
                APIToolDef(name: "\(prefix)_patch_file", description: "Replace one exact, unique text passage in a file in \(scope). Read the file first.", parameters: schema([
                    path, ("old_string", prop("string", "Exact existing text to replace")), ("new_string", prop("string", "Replacement text")),
                ], required: ["path", "old_string", "new_string"])),
                APIToolDef(name: "\(prefix)_move_file", description: "Move or rename a file in \(scope), without replacing an existing destination.", parameters: schema([
                    path, ("destination", prop("string", "New relative file path")),
                ], required: ["path", "destination"])),
                APIToolDef(name: "\(prefix)_delete_file", description: "Request deletion of one file in \(scope). This only creates a user approval request; never claim the file is deleted until the user approves.", parameters: schema([path], required: ["path"])),
            ]
        }
        definitions += [
            APIToolDef(name: "project_list_files", description: "List files shared by all of this user's chats and missions in the current project.", parameters: schema([])),
            APIToolDef(name: "project_read_file", description: "Read a UTF-8 file from the shared project workspace. Use start_line after a clipped read.", parameters: schema([path, ("start_line", prop("integer", "Optional 1-based starting line"))], required: ["path"])),
            APIToolDef(name: "project_write_file", description: "Create or fully replace a UTF-8 file in the shared project workspace, making it available to other chats and future missions.", parameters: schema([path, content], required: ["path", "content"])),
            APIToolDef(name: "run_terminal", description: "Run a shell command in an OS-sandboxed persistent session rooted at this conversation's private workspace. The working directory and files persist across calls. No host home-folder access or writes outside this workspace. Do not use destructive recursive deletion.", parameters: schema([
                ("command", prop("string", "Shell command to execute")), ("cwd", prop("string", "Optional relative directory inside the workspace")),
            ], required: ["command"])),
            APIToolDef(name: "project_terminal", description: "Run a shell command in an OS-sandboxed persistent session rooted at the shared project workspace. Use this for builds, tests, package scripts, and code verification. The working directory and files persist across calls. Do not use destructive recursive deletion.", parameters: schema([
                ("command", prop("string", "Shell command to execute")), ("cwd", prop("string", "Optional relative directory inside the workspace")),
            ], required: ["command"])),
            APIToolDef(name: "host_list_grants", description: "List the host folders the user has explicitly granted to Ada, with their UUIDs and read/write access. No other host folders are accessible.", parameters: schema([])),
            APIToolDef(name: "host_list_files", description: "Recursively list files in one explicitly granted host folder. There is no host shell access.", parameters: schema([grant], required: ["grant_id"])),
            APIToolDef(name: "host_read_file", description: "Read a text file in one explicitly granted host folder. Secret-file names such as .env and private keys are refused.", parameters: schema([
                grant, path, ("start_line", prop("integer", "Optional 1-based starting line")),
            ], required: ["grant_id", "path"])),
            APIToolDef(name: "host_write_file", description: "Create or fully replace a text file in an explicitly granted read/write host folder. Read an existing file first and report what changed.", parameters: schema([grant, path, content], required: ["grant_id", "path", "content"])),
        ]
        return definitions
    }

    public static func owns(_ name: String) -> Bool {
        name.hasPrefix("project_") || name.hasPrefix("host_") || name == "run_terminal"
            || name == "chat_patch_file" || name == "chat_move_file" || name == "chat_delete_file"
    }

    public static func run(
        call: APIToolCall,
        workspace: ChatWorkspaceStore,
        conversationID: UUID,
        project: ProjectScope,
        terminal: WorkspaceTerminal,
        hosts: HostAccessStore?,
        actions: AgentActionCenter?,
        audit: AccessAuditLog?
    ) async -> ToolOutcome {
        let name = call.function.name
        let args = AgentTools.arguments(of: call)
        let root = name.hasPrefix("project_") ? workspace.projectDirectory(project) : workspace.directory(conversationID)
        let path = args["path"]?.stringValue ?? ""
        let fileScope: AgentActionRequest.FileScope = name.hasPrefix("project_") ? .project : .conversation
        switch name {
        case "project_list_files":
            let files = await workspace.projectFiles(project)
            return ToolOutcome(resultText: files.isEmpty ? "The shared project workspace is empty." : files.joined(separator: "\n"))
        case "project_read_file":
            let start = args["start_line"]?.numberValue.map(Int.init) ?? 1
            guard let text = ScopedFiles.read(path, in: root, startLine: start) else { return ToolOutcome(resultText: "File not found, invalid start_line, or not readable UTF-8 text: \(path)") }
            return ToolOutcome(resultText: AgentTools.clip(text, startLine: start))
        case "project_write_file":
            guard let written = ScopedFiles.write(path, content: args["content"]?.stringValue ?? "", in: root) else {
                return ToolOutcome(resultText: "Invalid path or content over 200 KB.")
            }
            await audit?.record(ownerID: project.ownerID, action: "project.write", detail: "\(project.projectName): \(written)")
            return ToolOutcome(resultText: "Wrote shared project file \(written).", wroteFiles: ["project:\(written)"])
        case "chat_patch_file", "project_patch_file":
            guard let old = args["old_string"]?.stringValue, let new = args["new_string"]?.stringValue,
                  let patched = ScopedFiles.patch(path, old: old, new: new, in: root) else {
                return ToolOutcome(resultText: "Patch failed. The old text must occur exactly once and the result must remain readable text under 200 KB.")
            }
            await audit?.record(ownerID: project.ownerID, action: "file.patch", detail: patched)
            return ToolOutcome(resultText: "Patched \(patched).", wroteFiles: [fileScope == .project ? "project:\(patched)" : patched])
        case "chat_move_file", "project_move_file":
            guard let requestedDestination = args["destination"]?.stringValue, ScopedFiles.move(path, to: requestedDestination, in: root) else {
                return ToolOutcome(resultText: "Move failed. Both paths must be inside the workspace and the destination must not already exist.")
            }
            await audit?.record(ownerID: project.ownerID, action: "file.move", detail: "\(path) → \(requestedDestination)")
            let destination = AgentTools.normalized(requestedDestination)
            return ToolOutcome(resultText: "Moved \(path) to \(destination).", wroteFiles: [fileScope == .project ? "project:\(destination)" : destination])
        case "chat_delete_file", "project_delete_file":
            guard !path.isEmpty, ScopedFiles.resolve(path, in: root) != nil, FileManager.default.fileExists(atPath: ScopedFiles.resolve(path, in: root)!.path),
                  let actions else { return ToolOutcome(resultText: "File not found, or approvals are not available.") }
            let action = AgentActionRequest(
                ownerID: project.ownerID, conversationID: conversationID, kind: .fileDelete,
                title: "Delete \(path)?", detail: "Ada requested deletion from the \(fileScope == .project ? "shared project" : "conversation") workspace. This cannot be undone.",
                toolName: name, arguments: .object([("path", .string(path))]), fileScope: fileScope, projectName: project.projectName
            )
            let saved = await actions.request(action)
            return ToolOutcome(resultText: "Approval requested (\(saved.id.uuidString)). Do not retry the deletion. Tell the user to review the approval card; no file has been deleted.")
        case "run_terminal", "project_terminal":
            guard let command = args["command"]?.stringValue else { return ToolOutcome(resultText: "A shell command is required.") }
            let key = "\(conversationID.uuidString):\(fileScope.rawValue)"
            await audit?.record(ownerID: project.ownerID, action: "terminal.run", detail: "\(fileScope.rawValue): \(String(command.prefix(500)))")
            return await terminal.run(command: command, root: root, key: key, requestedDirectory: args["cwd"]?.stringValue)
        case "host_list_grants":
            guard let hosts else { return ToolOutcome(resultText: "Host folder access is not available on this server.") }
            let grants = await hosts.list(ownerID: project.ownerID)
            return ToolOutcome(resultText: grants.isEmpty ? "No host folders have been granted. The user can add one in Settings." : grants.map { "ID: \($0.id.uuidString); \($0.path); \($0.canWrite ? "read/write" : "read only")" }.joined(separator: "\n"))
        case "host_list_files", "host_read_file", "host_write_file":
            guard let hosts, let idString = args["grant_id"]?.stringValue, let id = UUID(uuidString: idString) else {
                return ToolOutcome(resultText: "A valid grant_id from host_list_grants is required.")
            }
            if name == "host_list_files" {
                guard let root = await hosts.root(ownerID: project.ownerID, id: id) else { return ToolOutcome(resultText: "Folder grant not found or no longer available.") }
                return ToolOutcome(resultText: ScopedFiles.manifest(in: root))
            }
            if name == "host_read_file" {
                guard let text = await hosts.read(ownerID: project.ownerID, id: id, path: path, startLine: args["start_line"]?.numberValue.map(Int.init) ?? 1) else {
                    return ToolOutcome(resultText: "File not found, outside the grant, secret-like, binary, or over 200 KB.")
                }
                return ToolOutcome(resultText: AgentTools.clip(text, startLine: args["start_line"]?.numberValue.map(Int.init) ?? 1))
            }
            guard let written = await hosts.write(ownerID: project.ownerID, id: id, path: path, content: args["content"]?.stringValue ?? "") else {
                return ToolOutcome(resultText: "Write refused. The grant must allow writes, and the file must be safe relative UTF-8 text under 200 KB.")
            }
            return ToolOutcome(resultText: "Wrote \(written) in the granted host folder.")
        default:
            return ToolOutcome(resultText: "Unknown extended workspace tool: \(name)")
        }
    }
}
