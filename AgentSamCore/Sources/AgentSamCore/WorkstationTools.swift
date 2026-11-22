import Foundation

/// Ada's tools for her own machine. `WorkstationTools.run` handles the calls that need no approval;
/// `workstation_run` and `workstation_start_job` go through the owner's standing permissions first
/// (see `ConversationEngine`), and an approved card runs through `execute`.
public enum WorkstationTools {
    public static let names: Set<String> = ["workstation_status", "workstation_run", "workstation_start_job", "workstation_job", "workstation_jobs", "workstation_stop_job"]
    /// The calls that change the machine and so go through permissions and approval cards.
    public static let approvalNames: Set<String> = ["workstation_run", "workstation_start_job"]

    public static var definitions: [APIToolDef] {
        let command: (String, JSONValue) = ("command", .object([("type", .string("string")), ("description", .string("The shell command, run with /bin/sh -c. Use non-interactive flags (pacman --noconfirm, systemctl --no-pager). sudo never prompts: it fails if a password would be needed."))]))
        let directory: (String, JSONValue) = ("directory", .object([("type", .string("string")), ("description", .string("Optional working directory: absolute, or relative to the workstation home."))]))
        let jobID: (String, JSONValue) = ("job_id", .object([("type", .string("string")), ("description", .string("The job ID workstation_start_job returned."))]))
        return [
            APIToolDef(
                name: "workstation_status",
                description: "See the state of your Linux workstation (capabilities.md says which machine it is): OS, uptime, disk, memory, failed services, package counts and whether sudo works without a password. Runs at once and changes nothing.",
                parameters: .object([("type", .string("object")), ("properties", .object([]))])
            ),
            APIToolDef(
                name: "workstation_run",
                description: """
                Run a shell command on your own Linux workstation, outside the sandbox, as the workstation's user: \
                install or update packages, manage systemd services, edit config, check logs. It changes a real \
                machine, so unless a standing permission allows the command it creates an approval card and \
                nothing runs until the user approves; the output then appears under approval requests on a later \
                turn. Do not retry while a card is pending. Prefer one clear command per call. For anything that \
                takes more than a couple of minutes, use workstation_start_job.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        command, directory,
                        ("timeout_seconds", .object([("type", .string("integer")), ("description", .string("Optional time limit, 1 to 600 seconds (default 120)."))])),
                    ])),
                    ("required", .array([.string("command")])),
                ])
            ),
            APIToolDef(
                name: "workstation_start_job",
                description: "Start a long-running command on your workstation in the background (a build, a big upgrade, a server). Needs approval like workstation_run unless a standing permission allows it. Check progress with workstation_job.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        command, directory,
                        ("label", .object([("type", .string("string")), ("description", .string("A short name for the job."))])),
                    ])),
                    ("required", .array([.string("command")])),
                ])
            ),
            APIToolDef(
                name: "workstation_job",
                description: "Show one background job on your workstation: its state, exit code and the end of its output.",
                parameters: .object([("type", .string("object")), ("properties", .object([jobID])), ("required", .array([.string("job_id")]))])
            ),
            APIToolDef(
                name: "workstation_jobs",
                description: "List recent background jobs on your workstation.",
                parameters: .object([("type", .string("object")), ("properties", .object([]))])
            ),
            APIToolDef(
                name: "workstation_stop_job",
                description: "Stop a running background job on your workstation, and everything it started.",
                parameters: .object([("type", .string("object")), ("properties", .object([jobID])), ("required", .array([.string("job_id")]))])
            ),
        ]
    }

    /// Runs the calls that need no approval. Approval tools are refused here; they go through `execute`.
    public static func run(call: APIToolCall, workstation: Workstation) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        switch call.function.name {
        case "workstation_status":
            return await workstation.status()
        case "workstation_job":
            guard let id = (args["job_id"]?.stringValue).flatMap(UUID.init(uuidString:)) else { return .failure("A valid job_id is required.") }
            return await workstation.job(id: id)
        case "workstation_jobs":
            guard await workstation.enabled else { return .failure("Ada's workstation access is off on this server.") }
            let jobs = await workstation.listJobs()
            if jobs.isEmpty { return ToolOutcome(resultText: "No background jobs yet.") }
            return ToolOutcome(resultText: jobs.map(Workstation.describe).joined(separator: "\n"))
        case "workstation_stop_job":
            guard let id = (args["job_id"]?.stringValue).flatMap(UUID.init(uuidString:)) else { return .failure("A valid job_id is required.") }
            return await workstation.stopJob(id: id)
        case "workstation_run", "workstation_start_job":
            return .failure("This command needs the standing-permission check first; it did not run.")
        default:
            return .failure("Unknown workstation tool.")
        }
    }

    /// Runs an approval tool that a person or a standing permission has allowed.
    public static func execute(toolName: String, rawArguments: String, workstation: Workstation) async -> ToolOutcome {
        let args = AgentTools.arguments(of: APIToolCall(id: "approved", function: .init(name: toolName, arguments: rawArguments)))
        let command = args["command"]?.stringValue ?? ""
        let directory = args["directory"]?.stringValue
        switch toolName {
        case "workstation_run":
            let timeout = args["timeout_seconds"]?.numberValue ?? args["timeout_seconds"]?.stringValue.flatMap(Double.init)
            return await workstation.run(command: command, directory: directory, timeout: timeout)
        case "workstation_start_job":
            return await workstation.startJob(command: command, directory: directory, label: args["label"]?.stringValue)
        default:
            return .failure("Unknown workstation tool.")
        }
    }

    /// Characters that let one command become several, or redirect into files. A command with any of
    /// them never matches a "commands starting with" rule, so the prefix cannot be stretched.
    static let shellControl: [String] = [";", "&", "|", "`", "$(", ">", "<", "\n", "\r"]

    /// True when the command is exactly a prefix or starts with one followed by a space, and is a single plain command.
    public static func matchesPrefix(_ raw: String, prefixes: [String]) -> Bool {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !shellControl.contains(where: { command.contains($0) }) else { return false }
        return prefixes.contains { prefix in
            let prefix = prefix.trimmingCharacters(in: .whitespaces)
            return !prefix.isEmpty && (command == prefix || command.hasPrefix(prefix + " "))
        }
    }
}
