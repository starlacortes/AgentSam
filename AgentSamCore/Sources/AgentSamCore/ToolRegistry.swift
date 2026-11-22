import Foundation

/// Where a tool Ada can call comes from, which decides how a call to it runs.
public enum ToolFamily: Sendable, Equatable {
    /// The conversation's private workspace, programs and schedules (`ChatWorkspaceTools`).
    case chat
    /// Patch, move and delete, the shared project, the terminal and host folders (`ExtendedWorkspaceTools`).
    case extended
    /// Files of missions linked to this conversation (`ConversationMissionTools`).
    case mission
    /// Handing a larger job to a background mission mid-reply (`TaskTools`).
    case task
    /// Events that wake the conversation: new email, webhook calls (`TriggerTools`).
    case trigger
    /// Saving procedures as skills (`SkillTools`).
    case skill
    /// Remembering and forgetting facts on request (`MemoryTools`).
    case memory
    /// Ada's read-only look back at her own recent work (`SelfReviewTools`).
    case selfReview
    /// Ada's own Linux machine (`WorkstationTools`): admins only, when the server turns it on.
    case workstation
    /// Tools of MCP servers an admin connected (`MCPRegistry`). Reads the admin marked run at once; the rest need approval.
    case mcp
    /// External services through `ConnectorHub`. Reads run at once; writes need an approval.
    case connector
    /// A mission worker's files, programs and `finish` in the mission workspace (`AgentTools`).
    case worker
}

/// The tools offered in one request, with the family each name belongs to.
///
/// This is the single place that decides which tools Ada is offered and how each one runs. Every
/// call is looked up here, so a name that was not offered in this request cannot run, and a tool
/// is dispatched by the list it was offered from rather than by name patterns.
public struct OfferedTools: Sendable {
    public let definitions: [APIToolDef]
    private let families: [String: ToolFamily]

    public init(_ groups: [(ToolFamily, [APIToolDef])]) {
        var definitions: [APIToolDef] = []
        var families: [String: ToolFamily] = [:]
        for (family, defs) in groups {
            for def in defs where families[def.function.name] == nil {
                families[def.function.name] = family
                definitions.append(def)
            }
        }
        self.definitions = definitions
        self.families = families
    }

    public var names: Set<String> { Set(families.keys) }

    /// The family of a tool offered in this request, or nil when the name was not offered.
    public func family(of name: String) -> ToolFamily? { families[name] }

    /// Ada's direct-reply tools. Extended tools need workspace access; mission tools need a linked mission.
    public static func direct(connectorTools: [APIToolDef], hasLinkedMissions: Bool, hasExtendedAccess: Bool, hasWorkstation: Bool = false, mcpTools: [APIToolDef] = [], taskTools: [APIToolDef] = []) -> OfferedTools {
        OfferedTools([
            (.connector, connectorTools),
            (.chat, ChatWorkspaceTools.definitions),
            (.trigger, TriggerTools.definitions),
            (.task, taskTools),
            (.extended, hasExtendedAccess ? ExtendedWorkspaceTools.definitions : []),
            (.mission, hasLinkedMissions ? ConversationMissionTools.definitions : []),
            (.skill, SkillTools.definitions),
            (.memory, MemoryTools.definitions),
            (.selfReview, SelfReviewTools.definitions),
            (.workstation, hasWorkstation ? WorkstationTools.definitions : []),
            (.mcp, mcpTools),
        ])
    }

    /// A mission worker's tools: its workspace tools, then the connectors its team's scope allows.
    public static func worker(connectorTools: [APIToolDef]) -> OfferedTools {
        OfferedTools([
            (.worker, AgentTools.workerTools),
            (.connector, connectorTools),
        ])
    }
}

/// What a tool call does to the world, which decides how carefully it runs.
public enum ToolAccess: Sendable, Equatable {
    /// Only reads. Safe to run at once, also in read-only contexts.
    case read
    /// Changes the conversation's or project's own files, programs or schedules, inside the sandbox.
    case write
    /// Changes something the user owns or that leaves the workspace. It only creates an approval request.
    case approval
}

/// One entry in the tool catalog: what a tool does and how its live step is labelled.
public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let access: ToolAccess
    public let labelEN: String
    public let labelES: String

    public init(_ name: String, _ access: ToolAccess, en: String, es: String) {
        self.name = name
        self.access = access
        self.labelEN = en
        self.labelES = es
    }

    public func label(language: String) -> String { language == "es" ? labelES : labelEN }
}

/// Every tool Ada can be offered, with its access and step label, in one table.
///
/// Tool definitions stay with the code that runs them; this table holds what the engine and the
/// app need to know about each name. A test checks that every defined tool has an entry here.
public enum ToolCatalog {
    public static let specs: [ToolSpec] = [
        ToolSpec("gmail_search", .read, en: "Searching Gmail", es: "Buscando en Gmail"),
        ToolSpec("gmail_read", .read, en: "Reading an email", es: "Leyendo un correo"),
        ToolSpec("googleads_accounts", .read, en: "Checking Google Ads accounts", es: "Revisando cuentas de Google Ads"),
        ToolSpec("googleads_campaigns", .read, en: "Reviewing campaigns", es: "Revisando campañas"),
        ToolSpec("googleads_query", .read, en: "Querying Google Ads", es: "Consultando Google Ads"),
        ToolSpec("googleads_validate", .read, en: "Checking Google Ads changes", es: "Validando cambios en Google Ads"),
        ToolSpec("cloudflare_zones", .read, en: "Reading Cloudflare zones", es: "Leyendo zonas de Cloudflare"),
        ToolSpec("cloudflare_dns_list", .read, en: "Reading DNS records", es: "Leyendo registros DNS"),
        ToolSpec("web_search", .read, en: "Searching the web", es: "Buscando en la web"),
        ToolSpec("web_fetch", .read, en: "Reading a web page", es: "Leyendo una página web"),
        ToolSpec("chat_write_file", .write, en: "Writing a file", es: "Escribiendo un archivo"),
        ToolSpec("chat_read_file", .read, en: "Reading a workspace file", es: "Leyendo un archivo del espacio"),
        ToolSpec("chat_list_files", .read, en: "Listing workspace files", es: "Revisando los archivos del espacio"),
        ToolSpec("mission_list_files", .read, en: "Listing mission files", es: "Revisando archivos de la misión"),
        ToolSpec("mission_read_file", .read, en: "Reading a mission file", es: "Leyendo un archivo de la misión"),
        ToolSpec("run_program", .write, en: "Running the program", es: "Ejecutando el programa"),
        ToolSpec("chat_schedule_run", .write, en: "Scheduling recurring work", es: "Programando el trabajo recurrente"),
        ToolSpec("chat_schedule_cancel", .write, en: "Cancelling the schedule", es: "Cancelando la programación"),
        ToolSpec("start_task", .write, en: "Handing this to a task", es: "Pasando esto a una tarea"),
        ToolSpec("chat_trigger_add", .write, en: "Setting up a trigger", es: "Configurando un disparador"),
        ToolSpec("chat_trigger_remove", .write, en: "Removing a trigger", es: "Quitando un disparador"),
        ToolSpec("chat_patch_file", .write, en: "Editing a file", es: "Editando un archivo"),
        ToolSpec("project_patch_file", .write, en: "Editing a file", es: "Editando un archivo"),
        ToolSpec("chat_move_file", .write, en: "Moving a file", es: "Moviendo un archivo"),
        ToolSpec("project_move_file", .write, en: "Moving a file", es: "Moviendo un archivo"),
        ToolSpec("chat_delete_file", .approval, en: "Asking to delete a file", es: "Pidiendo borrar un archivo"),
        ToolSpec("project_delete_file", .approval, en: "Asking to delete a file", es: "Pidiendo borrar un archivo"),
        ToolSpec("project_list_files", .read, en: "Listing project files", es: "Revisando los archivos del proyecto"),
        ToolSpec("project_read_file", .read, en: "Reading a project file", es: "Leyendo un archivo del proyecto"),
        ToolSpec("project_write_file", .write, en: "Writing a project file", es: "Escribiendo un archivo del proyecto"),
        ToolSpec("run_terminal", .write, en: "Running a command", es: "Ejecutando un comando"),
        ToolSpec("project_terminal", .write, en: "Running a command", es: "Ejecutando un comando"),
        ToolSpec("host_list_grants", .read, en: "Checking shared folders", es: "Revisando las carpetas compartidas"),
        ToolSpec("host_list_files", .read, en: "Listing a shared folder", es: "Revisando una carpeta compartida"),
        ToolSpec("host_read_file", .read, en: "Reading a file on your computer", es: "Leyendo un archivo de tu equipo"),
        ToolSpec("host_write_file", .write, en: "Writing a file on your computer", es: "Escribiendo un archivo en tu equipo"),
        ToolSpec("github_repos", .read, en: "Checking GitHub repositories", es: "Revisando repositorios de GitHub"),
        ToolSpec("github_read", .read, en: "Reading a GitHub file", es: "Leyendo un archivo de GitHub"),
        ToolSpec("github_search", .read, en: "Searching GitHub", es: "Buscando en GitHub"),
        ToolSpec("github_issues", .read, en: "Checking GitHub issues", es: "Revisando incidencias de GitHub"),
        ToolSpec("github_issue", .read, en: "Reading a GitHub issue", es: "Leyendo una incidencia de GitHub"),
        ToolSpec("github_write_file", .approval, en: "Preparing a GitHub change", es: "Preparando un cambio en GitHub"),
        ToolSpec("github_comment", .approval, en: "Preparing a GitHub comment", es: "Preparando un comentario en GitHub"),
        ToolSpec("gmail_draft", .approval, en: "Preparing a draft", es: "Preparando un borrador"),
        ToolSpec("gmail_send", .approval, en: "Preparing an email", es: "Preparando un correo"),
        ToolSpec("googleads_set_status", .approval, en: "Preparing a Google Ads change", es: "Preparando un cambio en Google Ads"),
        ToolSpec("googleads_set_budget", .approval, en: "Preparing a Google Ads change", es: "Preparando un cambio en Google Ads"),
        ToolSpec("googleads_mutate", .approval, en: "Preparing a Google Ads change", es: "Preparando un cambio en Google Ads"),
        ToolSpec("skill_save", .write, en: "Saving a procedure", es: "Guardando un procedimiento"),
        ToolSpec("memory_remember", .write, en: "Remembering that", es: "Recordándolo"),
        ToolSpec("memory_forget", .write, en: "Forgetting that", es: "Olvidándolo"),
        ToolSpec("self_review_recent", .read, en: "Looking back at my recent work", es: "Revisando mi trabajo reciente"),
        ToolSpec("workstation_status", .read, en: "Checking the workstation", es: "Revisando la estación de trabajo"),
        ToolSpec("workstation_run", .approval, en: "Preparing a workstation command", es: "Preparando un comando en la estación"),
        ToolSpec("workstation_start_job", .approval, en: "Preparing a workstation job", es: "Preparando una tarea en la estación"),
        ToolSpec("workstation_job", .read, en: "Checking a workstation job", es: "Revisando una tarea de la estación"),
        ToolSpec("workstation_jobs", .read, en: "Listing workstation jobs", es: "Revisando las tareas de la estación"),
        ToolSpec("workstation_stop_job", .write, en: "Stopping a workstation job", es: "Deteniendo una tarea de la estación"),
        ToolSpec("cloudflare_dns_create", .approval, en: "Preparing a DNS change", es: "Preparando un cambio de DNS"),
        ToolSpec("cloudflare_dns_update", .approval, en: "Preparing a DNS change", es: "Preparando un cambio de DNS"),
        ToolSpec("cloudflare_dns_delete", .approval, en: "Preparing a DNS change", es: "Preparando un cambio de DNS"),
        ToolSpec("write_file", .write, en: "Writing a file", es: "Escribiendo un archivo"),
        ToolSpec("read_file", .read, en: "Reading a file", es: "Leyendo un archivo"),
        ToolSpec("list_dir", .read, en: "Listing files", es: "Revisando los archivos"),
        ToolSpec("finish", .read, en: "Finishing the task", es: "Terminando la tarea"),
        ToolSpec("cloudflare_purge_cache", .approval, en: "Preparing a cache purge", es: "Preparando una limpieza de caché"),
    ]

    private static let byName: [String: ToolSpec] = Dictionary(specs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    public static func spec(_ name: String) -> ToolSpec? { byName[name] }

    /// The live step label for a call, or a generic one for a tool without an entry.
    public static func label(_ name: String, language: String) -> String {
        spec(name)?.label(language: language) ?? (language == "es" ? "Usando \(name)" : "Using \(name)")
    }
}
