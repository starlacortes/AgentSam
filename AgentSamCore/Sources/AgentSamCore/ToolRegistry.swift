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
    /// Handing one piece of work to a helper subagent mid-reply (`HelperTools`).
    case delegate
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
    /// Ada's browser on the workstation (`BrowserTools`): admins only, when the server turns it on.
    case browser
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
///
/// Not every tool that may run is sent to the model on every call, because each definition costs
/// tokens on each of up to 20 calls per reply, and a long list makes wrong picks more likely:
/// - A *held* tool may run, but its definition is sent only once its family is revealed (the
///   fine-grained browser tools wait until Ada has a page open).
/// - A *hidden* tool may run but is never sent: an older name that another tool now covers
///   (`project_read_file` is `chat_read_file` with `location: "project"`). Calls to it still work,
///   from older chats and from habits.
public struct OfferedTools: Sendable {
    public enum Visibility: Sendable, Equatable { case sent, held, hidden }

    private struct Entry: Sendable {
        let definition: APIToolDef
        let family: ToolFamily
        var visibility: Visibility
    }

    private var entries: [Entry]
    private let index: [String: Int]

    /// `holding` names tools of `groups` that are held back; they keep their place in the order, so
    /// once revealed the list is the same as one sent whole from the start.
    public init(_ groups: [(ToolFamily, [APIToolDef])], holding: Set<String> = [], hidden: [(ToolFamily, [APIToolDef])] = []) {
        var entries: [Entry] = []
        var index: [String: Int] = [:]
        for (isHidden, list) in [(false, groups), (true, hidden)] {
            for (family, defs) in list {
                for def in defs where index[def.function.name] == nil {
                    let name = def.function.name
                    index[name] = entries.count
                    entries.append(Entry(definition: def, family: family, visibility: isHidden ? .hidden : (holding.contains(name) ? .held : .sent)))
                }
            }
        }
        self.entries = entries
        self.index = index
    }

    /// The definitions sent to the model in this call, in a stable order.
    public var definitions: [APIToolDef] { entries.filter { $0.visibility == .sent }.map(\.definition) }

    /// The tools Ada is told about and may call: sent and held, not hidden aliases.
    public var names: Set<String> { Set(entries.filter { $0.visibility != .hidden }.map(\.definition.function.name)) }

    /// The family of a tool that may run in this request, or nil when the name was not offered.
    public func family(of name: String) -> ToolFamily? { index[name].map { entries[$0].family } }

    public func visibility(of name: String) -> Visibility? { index[name].map { entries[$0].visibility } }

    /// Whether any tool of this family is still held back.
    public func holds(_ family: ToolFamily) -> Bool { entries.contains { $0.family == family && $0.visibility == .held } }

    /// The same tools with every held tool of `family` now sent.
    public func revealing(_ family: ToolFamily) -> OfferedTools {
        var copy = self
        for i in copy.entries.indices where copy.entries[i].family == family && copy.entries[i].visibility == .held {
            copy.entries[i].visibility = .sent
        }
        return copy
    }

    /// The same tools with everything held now sent (helpers get their whole set at once).
    public func revealingAll() -> OfferedTools {
        var copy = self
        for i in copy.entries.indices where copy.entries[i].visibility == .held { copy.entries[i].visibility = .sent }
        return copy
    }

    /// Browser tools sent from the start. The rest act on a page, so they wait until one is open.
    public static let browserFirstNames: Set<String> = ["browser_open", "browser_look", "browser_tabs"]

    /// Ada's direct-reply tools. Extended tools need workspace access; mission tools need a linked mission.
    /// `browserOpen` sends every browser tool from the first call, for chats where the browser is already in use.
    public static func direct(connectorTools: [APIToolDef], hasLinkedMissions: Bool, hasExtendedAccess: Bool, hasWorkstation: Bool = false, hasBrowser: Bool = false, browserOpen: Bool = false, mcpTools: [APIToolDef] = [], taskTools: [APIToolDef] = [], delegateTools: [APIToolDef] = []) -> OfferedTools {
        let held = hasBrowser && !browserOpen ? BrowserTools.names.subtracting(browserFirstNames) : []
        return OfferedTools([
            (.connector, connectorTools),
            (.chat, ChatWorkspaceTools.definitions(projectLocation: hasExtendedAccess)),
            (.trigger, TriggerTools.definitions),
            (.task, taskTools),
            (.delegate, delegateTools),
            (.extended, hasExtendedAccess ? ExtendedWorkspaceTools.definitions : []),
            (.mission, hasLinkedMissions ? ConversationMissionTools.definitions : []),
            (.skill, SkillTools.definitions),
            (.memory, MemoryTools.definitions),
            (.selfReview, SelfReviewTools.definitions),
            (.workstation, hasWorkstation ? WorkstationTools.definitions : []),
            (.browser, hasBrowser ? BrowserTools.definitions : []),
            (.mcp, mcpTools),
        ], holding: held, hidden: [
            (.extended, hasExtendedAccess ? ExtendedWorkspaceTools.projectAliases : []),
        ])
    }

    /// The offered tools that `allow` accepts, each still dispatched by the family it was offered
    /// from and kept as sent, held or hidden.
    public func restricted(_ allow: (String, ToolFamily) -> Bool) -> OfferedTools {
        OfferedTools(entries: entries.filter { allow($0.definition.function.name, $0.family) })
    }

    private init(entries: [Entry]) {
        self.entries = entries
        var index: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where index[entry.definition.function.name] == nil { index[entry.definition.function.name] = i }
        self.index = index
    }

    /// A call to a tool with a `location` argument, turned into the tool that serves that location:
    /// `chat_read_file` with `location: "project"` runs as `project_read_file`. Other calls are unchanged.
    public func resolved(_ call: APIToolCall) -> APIToolCall {
        guard let target = ExtendedWorkspaceTools.projectAlias[call.function.name],
              index[target] != nil,
              AgentTools.arguments(of: call)["location"]?.stringValue?.lowercased() == "project"
        else { return call }
        var routed = call
        routed.function.name = target
        return routed
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
        ToolSpec("googleads_recommendations", .read, en: "Reading Google Ads recommendations", es: "Revisando recomendaciones de Google Ads"),
        ToolSpec("googleads_validate", .read, en: "Checking Google Ads changes", es: "Validando cambios en Google Ads"),
        ToolSpec("cloudflare_zones", .read, en: "Reading Cloudflare zones", es: "Leyendo zonas de Cloudflare"),
        ToolSpec("cloudflare_dns_list", .read, en: "Reading DNS records", es: "Leyendo registros DNS"),
        ToolSpec("web_search", .read, en: "Searching the web", es: "Buscando en la web"),
        ToolSpec("web_fetch", .read, en: "Reading a web page", es: "Leyendo una página web"),
        ToolSpec("chat_write_file", .write, en: "Writing a file", es: "Escribiendo un archivo"),
        ToolSpec("chat_read_file", .read, en: "Reading a workspace file", es: "Leyendo un archivo del espacio"),
        ToolSpec("chat_list_files", .read, en: "Listing workspace files", es: "Revisando los archivos del espacio"),
        ToolSpec("mission_list_files", .read, en: "Listing a job's files", es: "Revisando archivos del trabajo"),
        ToolSpec("mission_read_file", .read, en: "Reading a job's file", es: "Leyendo un archivo del trabajo"),
        ToolSpec("run_program", .write, en: "Running the program", es: "Ejecutando el programa"),
        ToolSpec("chat_schedule_run", .write, en: "Scheduling recurring work", es: "Programando el trabajo recurrente"),
        ToolSpec("chat_schedule_cancel", .write, en: "Cancelling the schedule", es: "Cancelando la programación"),
        ToolSpec("delegate", .write, en: "Asking a specialist", es: "Consultando a un especialista"),
        ToolSpec("helper_save", .approval, en: "Proposing a specialist role", es: "Proponiendo un rol de especialista"),
        ToolSpec("start_task", .write, en: "Starting a job", es: "Iniciando un trabajo"),
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
        ToolSpec("googleads_apply_recommendations", .approval, en: "Preparing to apply Google Ads recommendations", es: "Preparando la aplicación de recomendaciones de Google Ads"),
        ToolSpec("googleads_dismiss_recommendations", .approval, en: "Preparing to dismiss Google Ads recommendations", es: "Preparando el descarte de recomendaciones de Google Ads"),
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
        ToolSpec("browser_open", .write, en: "Opening a page in my browser", es: "Abriendo una página en mi navegador"),
        ToolSpec("browser_look", .read, en: "Reading the page", es: "Leyendo la página"),
        ToolSpec("browser_click", .write, en: "Clicking in the browser", es: "Haciendo clic en el navegador"),
        ToolSpec("browser_type", .write, en: "Typing in the browser", es: "Escribiendo en el navegador"),
        ToolSpec("browser_select", .write, en: "Choosing an option", es: "Eligiendo una opción"),
        ToolSpec("browser_key", .write, en: "Pressing a key in the browser", es: "Pulsando una tecla en el navegador"),
        ToolSpec("browser_scroll", .write, en: "Scrolling the page", es: "Desplazando la página"),
        ToolSpec("browser_go", .write, en: "Moving between pages", es: "Cambiando de página"),
        ToolSpec("browser_tabs", .read, en: "Checking the browser tabs", es: "Revisando las pestañas"),
        ToolSpec("browser_wait", .read, en: "Waiting for the page", es: "Esperando a la página"),
        ToolSpec("browser_paste", .write, en: "Pasting text in the browser", es: "Pegando texto en el navegador"),
        ToolSpec("browser_upload_file", .write, en: "Uploading a file in the browser", es: "Subiendo un archivo en el navegador"),
        ToolSpec("browser_click_at", .write, en: "Clicking on the screen", es: "Haciendo clic en la pantalla"),
        ToolSpec("browser_drag", .write, en: "Dragging with the mouse", es: "Arrastrando con el ratón"),
        ToolSpec("browser_hover", .write, en: "Moving the mouse", es: "Moviendo el ratón"),
        ToolSpec("browser_screenshot", .read, en: "Looking at the screen", es: "Mirando la pantalla"),
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
        if let spec = spec(name) { return spec.label(language: language) }
        // A connected MCP server's tool: "mcp_ads_list_campaigns" reads as "Using ads list campaigns".
        let shown = name.hasPrefix(MCPRegistry.toolPrefix)
            ? name.dropFirst(MCPRegistry.toolPrefix.count).replacingOccurrences(of: "_", with: " ")
            : name
        return language == "es" ? "Usando \(shown)" : "Using \(shown)"
    }

    /// The live step label for one call: what Ada is doing and, where the arguments say it, with what
    /// ("Searching the web for “flights to Lima”", "Reading example.com"). Falls back to the plain label.
    public static func label(for call: APIToolCall, language: String) -> String {
        let name = call.function.name
        let args = AgentTools.arguments(of: call)
        let es = language == "es"
        func text(_ key: String, limit: Int = 60) -> String? { clip(args[key]?.stringValue, limit: limit) }
        func file(_ key: String = "path") -> String? {
            clip(args[key]?.stringValue.map { ($0 as NSString).lastPathComponent }, limit: 48)
        }
        switch name {
        case "gmail_search":
            if let query = text("query") { return es ? "Buscando en Gmail “\(query)”" : "Searching Gmail for “\(query)”" }
        case "web_search":
            if let query = text("query") { return es ? "Buscando en la web “\(query)”" : "Searching the web for “\(query)”" }
        case "github_search":
            if let query = text("query") { return es ? "Buscando en GitHub “\(query)”" : "Searching GitHub for “\(query)”" }
        case "github_issues":
            if let repo = text("repo") { return es ? "Revisando incidencias de \(repo)" : "Checking issues in \(repo)" }
        case "github_read":
            if let path = file() { return es ? "Leyendo \(path) en GitHub" : "Reading \(path) on GitHub" }
        case "web_fetch":
            if let site = site(args["url"]?.stringValue) { return es ? "Leyendo \(site)" : "Reading \(site)" }
        case "browser_open":
            if let site = site(args["url"]?.stringValue) { return es ? "Abriendo \(site) en mi navegador" : "Opening \(site) in my browser" }
        case "browser_look":
            if let query = text("query", limit: 40) { return es ? "Buscando “\(query)” en la página" : "Looking for “\(query)” on the page" }
        case "browser_key":
            if let key = text("key", limit: 16) { return es ? "Pulsando \(key) en el navegador" : "Pressing \(key) in the browser" }
        case "browser_scroll":
            if args["direction"]?.stringValue == "up" { return es ? "Subiendo por la página" : "Scrolling up the page" }
            return es ? "Bajando por la página" : "Scrolling down the page"
        case "browser_go":
            switch args["action"]?.stringValue {
            case "back": return es ? "Volviendo a la página anterior" : "Going back a page"
            case "forward": return es ? "Avanzando a la página siguiente" : "Going forward a page"
            case "reload": return es ? "Recargando la página" : "Reloading the page"
            default: break
            }
        case "chat_write_file", "project_write_file", "host_write_file", "write_file":
            if let path = file() { return es ? "Escribiendo \(path)" : "Writing \(path)" }
        case "chat_read_file", "project_read_file", "host_read_file", "mission_read_file", "read_file":
            if let path = file() { return es ? "Leyendo \(path)" : "Reading \(path)" }
        case "chat_patch_file", "project_patch_file":
            if let path = file() { return es ? "Editando \(path)" : "Editing \(path)" }
        case "run_terminal", "project_terminal":
            if let command = firstLine(args["command"]?.stringValue) { return es ? "Ejecutando: \(command)" : "Running: \(command)" }
        case "workstation_run", "workstation_start_job":
            if let command = firstLine(args["command"]?.stringValue) { return "\(label(name, language: language)): \(command)" }
        case "gmail_send":
            if let to = text("to", limit: 48) { return es ? "Preparando un correo para \(to)" : "Preparing an email to \(to)" }
        case "gmail_draft":
            if let to = text("to", limit: 48) { return es ? "Preparando un borrador para \(to)" : "Preparing a draft for \(to)" }
        default:
            break
        }
        return label(name, language: language)
    }

    /// One line of plain text, shortened to fit a status line; nil when there is nothing to show.
    static func clip(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let clean = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.count > limit ? String(clean.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : clean
    }

    /// The first line of a command, shortened.
    static func firstLine(_ text: String?) -> String? {
        clip(text?.split(whereSeparator: \.isNewline).first.map(String.init), limit: 48)
    }

    /// The site of a web address without "www.": "https://www.example.com/a?b" reads as "example.com".
    static func site(_ address: String?) -> String? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        let full = address.contains("://") ? address : "https://" + address
        guard let host = URLComponents(string: full)?.host, !host.isEmpty else { return nil }
        return clip(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, limit: 48)
    }
}
